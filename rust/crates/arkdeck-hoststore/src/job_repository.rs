//! Current v1 SQLite admission index. Read snapshots open without recovering
//! or rewriting existing state and never perform admission or journal
//! recovery. The Rust Job owner's connection adds exactly Swift
//! RuntimeJobRepository's admission and state updates.
use arkdeck_platform::{HostDirectory, HostReadLock, HostSqlite, SqliteValue};
use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const DATABASE: &str = "runtime-jobs.sqlite3";
const LOCK: &str = ".rust-job-owner.lock";
// Swift RuntimeJobRepository.schemaStatements byte for byte: SQLite keeps this
// text in sqlite_schema, so a store created here reads back as Swift's own.
const SCHEMA: &[&str] = &[
    concat!(
        "CREATE TABLE runtime_job(\n",
        "  job_id TEXT PRIMARY KEY,\n",
        "  idempotency_key TEXT NOT NULL UNIQUE,\n",
        "  request_hash TEXT NOT NULL,\n",
        "  state TEXT NOT NULL,\n",
        "  admission_sequence INTEGER NOT NULL,\n",
        "  created_at_utc TEXT NOT NULL,\n",
        "  created_at_order_key TEXT NOT NULL,\n",
        "  updated_at_utc TEXT NOT NULL,\n",
        "  version INTEGER NOT NULL CHECK(version >= 1),\n",
        "  initial_record_json BLOB\n",
        ")"
    ),
    "CREATE INDEX runtime_job_updated_idx ON runtime_job(updated_at_utc DESC, job_id)",
    "CREATE INDEX runtime_job_created_idx ON runtime_job(created_at_order_key, job_id COLLATE BINARY)",
    "CREATE UNIQUE INDEX runtime_job_admission_sequence_idx ON runtime_job(admission_sequence)",
];

/// Swift RuntimeJobAdmissionVerdict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdmissionVerdict {
    Admitted,
    Duplicate(String),
    Conflict,
}

/// A refused or uncertain Job index or record write. `Invalid` and `Refused`
/// changed nothing. `OutcomeUnknown` began a durable change whose result is not
/// established; the caller rereads the index (a retried admission finds its own
/// row by idempotency key) before acting on it.
#[derive(Debug)]
pub enum JobWriteError {
    Invalid(&'static str),
    Refused(io::Error),
    OutcomeUnknown(io::Error),
}

pub(super) struct JobRepository {
    root: HostDirectory,
    path: PathBuf,
    lock: HostReadLock,
    identity: (u64, u64),
    writable: bool,
    db: Mutex<HostSqlite>,
}

#[derive(Debug)]
pub(super) struct JobRow {
    pub id: String,
    pub idempotency_key: String,
    pub request_hash: String,
    pub state: String,
    pub created: String,
    pub updated: String,
    pub version: i64,
    pub record: Vec<u8>,
    pub order_key: String,
}

fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Runtime Job repository is missing, unsafe, or does not match its current layout",
    )
}
fn normalize(sql: &str) -> String {
    sql.chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect()
}
pub(super) fn identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-._".contains(&c))
}
pub(super) fn order_key(timestamp: &str) -> io::Result<String> {
    let mut seconds = crate::session_time::session_timestamp(timestamp).ok_or_else(corrupt)?;
    if seconds == 0.0 {
        seconds = 0.0;
    }
    if !seconds.is_finite() {
        return Err(corrupt());
    }
    let bits = seconds.to_bits();
    Ok(format!(
        "{:016x}",
        if bits >> 63 == 0 {
            bits ^ (1 << 63)
        } else {
            !bits
        }
    ))
}
fn validate_files(root: &HostDirectory) -> io::Result<()> {
    for name in [
        DATABASE,
        "runtime-jobs.sqlite3-wal",
        "runtime-jobs.sqlite3-shm",
        "runtime-jobs.sqlite3-journal",
    ] {
        match root.owned_kind_and_size(name) {
            Ok((arkdeck_platform::HostEntryKind::Regular, _)) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound && name != DATABASE => (),
            _ => return Err(corrupt()),
        }
    }
    Ok(())
}
/// Swift RuntimeJobRepository's connection choice. A read-only connection
/// cannot create the shared-memory index a write-ahead log is read through, and
/// that index exists whenever the log may hold pages. With it, inspect through a
/// read-only connection, so refusing a future layout never checkpoints the log.
/// Without it there is nothing to replay: a write connection reads, then closes
/// without a checkpoint and leaves the database bytes identical. A log or
/// rollback journal with content but no index would be replayed by that
/// connection, so it is refused.
fn inspection(root: &HostDirectory, path: &Path) -> io::Result<(HostSqlite, bool)> {
    let indexed = match root.owned_kind_and_size("runtime-jobs.sqlite3-shm") {
        Ok(_) => true,
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => return Err(error),
    };
    if !indexed {
        for name in ["runtime-jobs.sqlite3-wal", "runtime-jobs.sqlite3-journal"] {
            match root.owned_kind_and_size(name) {
                Ok((_, 0)) => (),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                _ => return Err(corrupt()),
            }
        }
    }
    Ok((
        HostSqlite::open(&path.join(DATABASE), indexed, false)?,
        indexed,
    ))
}
fn current_layout(db: &mut HostSqlite) -> io::Result<()> {
    if db.query("PRAGMA user_version", &[], 1024)? != vec![vec![SqliteValue::Integer(1)]] {
        return Err(corrupt());
    }
    let objects = db.query(
        "SELECT name, sql FROM sqlite_schema ORDER BY name",
        &[],
        64 * 1024,
    )?;
    let mut definitions = BTreeSet::new();
    let mut indexes = BTreeSet::new();
    for row in objects {
        match row.as_slice() {
            [SqliteValue::Text(_), SqliteValue::Text(sql)] => {
                definitions.insert(normalize(sql));
            }
            [SqliteValue::Text(name), SqliteValue::Null] => {
                indexes.insert(name.clone());
            }
            _ => return Err(corrupt()),
        }
    }
    if definitions != SCHEMA.iter().map(|s| normalize(s)).collect()
        || indexes
            != [
                "sqlite_autoindex_runtime_job_1".into(),
                "sqlite_autoindex_runtime_job_2".into(),
            ]
            .into()
    {
        return Err(corrupt());
    }
    Ok(())
}
/// Swift requireCurrentLayout's row pass: logical ordering is part of the
/// durable contract, not a migration.
fn validate_rows(db: &mut HostSqlite) -> io::Result<()> {
    let mut after = String::new();
    loop {
        let rows = db.query(
            "SELECT job_id, created_at_utc, created_at_order_key, admission_sequence, version FROM runtime_job WHERE job_id COLLATE BINARY > ? ORDER BY job_id COLLATE BINARY LIMIT 256",
            &[SqliteValue::Text(after.clone())],
            1024 * 1024,
        )?;
        if rows.is_empty() {
            return Ok(());
        }
        for row in rows {
            let [
                SqliteValue::Text(id),
                SqliteValue::Text(created),
                SqliteValue::Text(key),
                SqliteValue::Integer(sequence),
                SqliteValue::Integer(version),
            ] = row.as_slice()
            else {
                return Err(corrupt());
            };
            if !identifier(id) || *key != order_key(created)? || *sequence <= 0 || *version <= 0 {
                return Err(corrupt());
            }
            after.clone_from(id);
        }
    }
}
/// The row a Job's idempotency key already owns, as Swift admission reads it.
fn admitted(
    db: &mut HostSqlite,
    idempotency_key: &str,
    request_hash: &str,
) -> io::Result<Option<AdmissionVerdict>> {
    let rows = db.query(
        "SELECT job_id, request_hash FROM runtime_job WHERE idempotency_key = ? LIMIT 1",
        &[SqliteValue::Text(idempotency_key.into())],
        16 * 1024,
    )?;
    match rows.as_slice() {
        [] => Ok(None),
        [row] => match row.as_slice() {
            [SqliteValue::Text(id), SqliteValue::Text(stored)] => {
                Ok(Some(if stored == request_hash {
                    AdmissionVerdict::Duplicate(id.clone())
                } else {
                    AdmissionVerdict::Conflict
                }))
            }
            _ => Err(corrupt()),
        },
        _ => Err(corrupt()),
    }
}
/// A record may only advance the row that indexes it: Rust readers refuse a
/// row whose record names another request or creation time.
fn describes(
    db: &mut HostSqlite,
    id: &str,
    idempotency_key: &str,
    created: &str,
) -> io::Result<()> {
    let rows = db.query(
        "SELECT idempotency_key, created_at_utc FROM runtime_job WHERE job_id = ?",
        &[SqliteValue::Text(id.into())],
        16 * 1024,
    )?;
    if rows
        != [vec![
            SqliteValue::Text(idempotency_key.into()),
            SqliteValue::Text(created.into()),
        ]]
    {
        return Err(corrupt());
    }
    Ok(())
}

/// Where a Job index lives: in a directory of its own, as the isolated
/// development owner keeps it, or at the Runtime's state root, which it shares
/// with the Runtime's other owners as Swift's
/// `RuntimeJobRepository(stateDirectory:)` does.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Placement {
    Dedicated,
    StateRoot,
}

impl JobRepository {
    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_mode(path, false, Placement::Dedicated)
    }

    /// The Runtime Job owner's writable index. As Swift RuntimeJobRepository,
    /// an existing store is validated through a read-only connection before a
    /// write connection may recover or checkpoint its log; the write
    /// connection then rechecks under a write lock and uses WAL with FULL
    /// synchronization.
    pub fn open_owner(path: &Path) -> io::Result<Self> {
        Self::open_mode(path, true, Placement::Dedicated)
    }

    /// The owner's writable index at the Runtime's state root, where Swift's
    /// daemon keeps `runtime-jobs.sqlite3` and `jobs/` beside every other
    /// owner's entry. An existing index opens as [`Self::open_owner`] opens
    /// one. A first index is created where Swift creates one — no Job history
    /// in `jobs/` — and, beyond Swift, only while this owner's lock is unmarked
    /// and no log or journal of a lost index remains; the other owners'
    /// entries beside it are expected, not orphaned history.
    pub fn open_state_root_owner(path: &Path) -> io::Result<Self> {
        Self::open_mode(path, true, Placement::StateRoot)
    }

    fn open_mode(path: &Path, writable: bool, placement: Placement) -> io::Result<Self> {
        let root = HostDirectory::open(path)?;
        let lock = root.lock_document(LOCK)?;
        match root.owned_kind_and_size("idempotency.json") {
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            _ => return Err(corrupt()),
        }
        match root.owned_kind_and_size(DATABASE) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                // An initialized owner or orphaned Job history cannot be
                // replaced by a fresh empty database to hide pending effects.
                if !root.read(LOCK, 1)?.is_empty() {
                    return Err(corrupt());
                }
                match placement {
                    // A directory of its own holds nothing else before its
                    // first index.
                    Placement::Dedicated => {
                        if root
                            .names(3)?
                            .iter()
                            .any(|name| ![LOCK, "jobs"].contains(&name.as_str()))
                        {
                            return Err(corrupt());
                        }
                    }
                    // The state root holds the other owners' entries; what
                    // this index alone leaves behind — a log, its index or a
                    // rollback journal — is history a fresh one would hide.
                    Placement::StateRoot => {
                        for companion in [
                            "runtime-jobs.sqlite3-wal",
                            "runtime-jobs.sqlite3-shm",
                            "runtime-jobs.sqlite3-journal",
                        ] {
                            match root.owned_kind_and_size(companion) {
                                Err(e) if e.kind() == io::ErrorKind::NotFound => (),
                                _ => return Err(corrupt()),
                            }
                        }
                    }
                }
                match root.child("jobs") {
                    Ok(jobs) if jobs.names(1)?.is_empty() => (),
                    Err(e) if e.kind() == io::ErrorKind::NotFound => (),
                    _ => return Err(corrupt()),
                }
                let file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(path.join(DATABASE))?;
                let mut db = HostSqlite::open(&path.join(DATABASE), false, false)?;
                db.execute("BEGIN IMMEDIATE", &[])?;
                for statement in SCHEMA {
                    db.execute(statement, &[])?;
                }
                db.execute("PRAGMA user_version=1", &[])?;
                db.execute("COMMIT", &[])?;
                drop(db);
                file.sync_all()?;
                File::open(path)?.sync_all()?;
            }
            Ok(_) => (),
            Err(e) => return Err(e),
        }
        validate_files(&root)?;
        let (mut db, read_only) = inspection(&root, path)?;
        current_layout(&mut db)?;
        if writable {
            if read_only {
                validate_rows(&mut db)?;
                drop(db);
                db = HostSqlite::open(&path.join(DATABASE), false, false)?;
            }
            db.execute("BEGIN IMMEDIATE", &[])?;
            let checked = current_layout(&mut db).and_then(|()| validate_rows(&mut db));
            let end = db.execute(
                if checked.is_ok() {
                    "COMMIT"
                } else {
                    "ROLLBACK"
                },
                &[],
            );
            checked?;
            end?;
            if db.query("PRAGMA journal_mode=WAL", &[], 1024)?
                != vec![vec![SqliteValue::Text("wal".into())]]
            {
                return Err(io::Error::other("Runtime SQLite WAL mode is unavailable"));
            }
            db.execute("PRAGMA synchronous=FULL", &[])?;
        }
        root.validate_path(path)?;
        lock.mark_catalog_initialized(&root, LOCK)?;
        let metadata = root.document_metadata(DATABASE)?;
        Ok(Self {
            root,
            path: path.into(),
            lock,
            identity: (metadata.dev(), metadata.ino()),
            writable,
            db: Mutex::new(db),
        })
    }

    pub fn writable(&self) -> bool {
        self.writable
    }

    fn validate(&self) -> io::Result<()> {
        self.root.validate_path(&self.path)?;
        self.lock.validate_link(&self.root, LOCK)?;
        validate_files(&self.root)?;
        let metadata = self.root.document_metadata(DATABASE)?;
        if (metadata.dev(), metadata.ino()) != self.identity {
            return Err(corrupt());
        }
        Ok(())
    }

    pub fn rows(&self, id: Option<&str>) -> io::Result<Vec<JobRow>> {
        self.map_rows(id, Ok)
    }

    /// Project inside the same validated SQLite snapshot, releasing each full
    /// record before reading the next. The original whole-query budget applies.
    pub fn map_rows<T>(
        &self,
        id: Option<&str>,
        mut project: impl FnMut(JobRow) -> io::Result<T>,
    ) -> io::Result<Vec<T>> {
        self.validate()?;
        let mut db = self.db.lock().map_err(|_| corrupt())?;
        // Query and schema belong to one SQLite snapshot. Schema changes or
        // malformed rows never disappear from a supposedly complete inventory.
        db.execute("BEGIN", &[])?;
        let result = (|| {
            current_layout(&mut db)?;
            let sql = "SELECT job_id, idempotency_key, request_hash, state, created_at_utc, updated_at_utc, version, initial_record_json, created_at_order_key, admission_sequence FROM runtime_job";
            let decode = |row: Vec<SqliteValue>| {
                if row.len() != 10 || row[9].integer().is_none_or(|n| n <= 0) {
                    return Err(corrupt());
                }
                let text = |n: usize| {
                    row[n]
                        .text()
                        .filter(|s| s.len() <= 4096)
                        .map(str::to_owned)
                        .ok_or_else(corrupt)
                };
                let row = JobRow {
                    id: text(0)?,
                    idempotency_key: text(1)?,
                    request_hash: text(2)?,
                    state: text(3)?,
                    created: text(4)?,
                    updated: text(5)?,
                    version: row[6].integer().filter(|v| *v > 0).ok_or_else(corrupt)?,
                    record: row[7].blob().ok_or_else(corrupt)?.to_vec(),
                    order_key: text(8)?,
                };
                if !identifier(&row.id) || row.order_key != order_key(&row.created)? {
                    return Err(corrupt());
                }
                project(row)
            };
            if let Some(id) = id {
                db.query_map(
                    &format!("{sql} WHERE job_id = ?"),
                    &[SqliteValue::Text(id.into())],
                    17 * 1024 * 1024,
                    decode,
                )
            } else {
                db.query_map(
                    &format!("{sql} ORDER BY created_at_order_key, job_id COLLATE BINARY"),
                    &[],
                    64 * 1024 * 1024,
                    decode,
                )
            }
        })();
        let end = db.execute("ROLLBACK", &[]);
        self.validate()?;
        end?;
        result
    }

    /// Swift RuntimeJobRepository.lookup.
    pub fn lookup(
        &self,
        idempotency_key: &str,
        request_hash: &str,
    ) -> io::Result<AdmissionVerdict> {
        self.validate()?;
        let mut db = self.db.lock().map_err(|_| corrupt())?;
        let verdict = admitted(&mut db, idempotency_key, request_hash)?;
        drop(db);
        self.validate()?;
        Ok(verdict.unwrap_or(AdmissionVerdict::Admitted))
    }

    /// Swift RuntimeJobRepository.admit: an idempotency key already indexed
    /// answers with its own Job, or a conflict for a different request.
    /// Otherwise the key, Job identity, initial state and exact initial record
    /// commit together at the next admission sequence, version 1.
    pub fn admit(
        &self,
        id: &str,
        idempotency_key: &str,
        request_hash: &str,
        state: &str,
        created: &str,
        record: &[u8],
    ) -> Result<AdmissionVerdict, JobWriteError> {
        let created_key = order_key(created).map_err(|_| {
            JobWriteError::Invalid("The Job creation time is not a Runtime timestamp")
        })?;
        self.write(|db| {
            if let Some(verdict) = admitted(db, idempotency_key, request_hash)? {
                return Ok(verdict);
            }
            let next = db.query(
                "SELECT COALESCE(MAX(admission_sequence), 0) + 1 FROM runtime_job",
                &[],
                1024,
            )?;
            let [row] = next.as_slice() else {
                return Err(corrupt());
            };
            let Some(sequence) = row.first().and_then(SqliteValue::integer).filter(|n| *n > 0)
            else {
                return Err(corrupt());
            };
            db.execute(
                "INSERT INTO runtime_job(job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
                &[
                    SqliteValue::Text(id.into()),
                    SqliteValue::Text(idempotency_key.into()),
                    SqliteValue::Text(request_hash.into()),
                    SqliteValue::Text(state.into()),
                    SqliteValue::Integer(sequence),
                    SqliteValue::Text(created.into()),
                    SqliteValue::Text(created_key.clone()),
                    SqliteValue::Text(created.into()),
                    SqliteValue::Blob(record.to_vec()),
                ],
            )?;
            Ok(AdmissionVerdict::Admitted)
        })
    }

    /// Refuse before a record file changes when no index row describes it.
    pub fn describes(&self, id: &str, idempotency_key: &str, created: &str) -> io::Result<()> {
        self.validate()?;
        let mut db = self.db.lock().map_err(|_| corrupt())?;
        describes(&mut db, id, idempotency_key, created)
    }

    /// Swift RuntimeJobRepository.updateJobState, as one write transaction on
    /// the row this record describes.
    pub fn update(
        &self,
        id: &str,
        idempotency_key: &str,
        created: &str,
        state: &str,
        updated: &str,
        record: &[u8],
    ) -> Result<(), JobWriteError> {
        order_key(updated).map_err(|_| {
            JobWriteError::Invalid("The Job update time is not a Runtime timestamp")
        })?;
        self.write(|db| {
            describes(db, id, idempotency_key, created)?;
            let changed = db.execute(
                "UPDATE runtime_job SET state = ?, updated_at_utc = ?, version = version + 1, initial_record_json = ? WHERE job_id = ?",
                &[
                    SqliteValue::Text(state.into()),
                    SqliteValue::Text(updated.into()),
                    SqliteValue::Blob(record.to_vec()),
                    SqliteValue::Text(id.into()),
                ],
            )?;
            if changed != 1 {
                return Err(corrupt());
            }
            Ok(())
        })
    }

    /// One IMMEDIATE transaction on the owner connection. A failure before
    /// COMMIT is rolled back; a failed COMMIT, or a store that no longer
    /// validates afterwards, leaves the outcome unknown.
    fn write<T>(
        &self,
        body: impl FnOnce(&mut HostSqlite) -> io::Result<T>,
    ) -> Result<T, JobWriteError> {
        if !self.writable {
            return Err(JobWriteError::Refused(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "The Runtime Job repository was opened for reading",
            )));
        }
        self.validate().map_err(JobWriteError::Refused)?;
        let mut db = self
            .db
            .lock()
            .map_err(|_| JobWriteError::Refused(corrupt()))?;
        db.execute("BEGIN IMMEDIATE", &[])
            .map_err(JobWriteError::Refused)?;
        let value = match body(&mut db) {
            Ok(value) => value,
            Err(error) => {
                let _ = db.execute("ROLLBACK", &[]);
                return Err(JobWriteError::Refused(error));
            }
        };
        if let Err(error) = db.execute("COMMIT", &[]) {
            let _ = db.execute("ROLLBACK", &[]);
            return Err(JobWriteError::OutcomeUnknown(error));
        }
        drop(db);
        self.validate().map_err(JobWriteError::OutcomeUnknown)?;
        Ok(value)
    }
}
