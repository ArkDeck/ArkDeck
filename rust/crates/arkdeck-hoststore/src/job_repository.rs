//! Current v1 SQLite admission index, opened without recovering or rewriting
//! existing state. Read snapshots never perform admission or journal recovery.
use arkdeck_platform::{HostDirectory, HostReadLock, HostSqlite, SqliteValue};
use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const DATABASE: &str = "runtime-jobs.sqlite3";
const LOCK: &str = ".rust-job-owner.lock";
const SCHEMA: &[&str] = &[
    "CREATE TABLE runtime_job(job_id TEXT PRIMARY KEY, idempotency_key TEXT NOT NULL UNIQUE, request_hash TEXT NOT NULL, state TEXT NOT NULL, admission_sequence INTEGER NOT NULL, created_at_utc TEXT NOT NULL, created_at_order_key TEXT NOT NULL, updated_at_utc TEXT NOT NULL, version INTEGER NOT NULL CHECK(version >= 1), initial_record_json BLOB)",
    "CREATE INDEX runtime_job_updated_idx ON runtime_job(updated_at_utc DESC, job_id)",
    "CREATE INDEX runtime_job_created_idx ON runtime_job(created_at_order_key, job_id COLLATE BINARY)",
    "CREATE UNIQUE INDEX runtime_job_admission_sequence_idx ON runtime_job(admission_sequence)",
];

pub(super) struct JobRepository {
    root: HostDirectory,
    path: PathBuf,
    lock: HostReadLock,
    identity: (u64, u64),
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

impl JobRepository {
    pub fn open(path: &Path) -> io::Result<Self> {
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
                if root
                    .names(3)?
                    .iter()
                    .any(|name| ![LOCK, "jobs"].contains(&name.as_str()))
                {
                    return Err(corrupt());
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
        // Always inspect existing databases through a read-only connection.
        // Refusing a future layout must not checkpoint its WAL as a side effect.
        let mut db = HostSqlite::open(&path.join(DATABASE), true, false)?;
        current_layout(&mut db)?;
        root.validate_path(path)?;
        lock.mark_catalog_initialized(&root, LOCK)?;
        let metadata = root.document_metadata(DATABASE)?;
        Ok(Self {
            root,
            path: path.into(),
            lock,
            identity: (metadata.dev(), metadata.ino()),
            db: Mutex::new(db),
        })
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
        self.validate()?;
        let mut db = self.db.lock().map_err(|_| corrupt())?;
        // Query and schema belong to one SQLite snapshot. Schema changes or
        // malformed rows never disappear from a supposedly complete inventory.
        db.execute("BEGIN", &[])?;
        let result = (|| {
            current_layout(&mut db)?;
            let sql = "SELECT job_id, idempotency_key, request_hash, state, created_at_utc, updated_at_utc, version, initial_record_json, created_at_order_key, admission_sequence FROM runtime_job";
            let rows = if let Some(id) = id {
                db.query(
                    &format!("{sql} WHERE job_id = ?"),
                    &[SqliteValue::Text(id.into())],
                    17 * 1024 * 1024,
                )?
            } else {
                db.query(
                    &format!("{sql} ORDER BY created_at_order_key, job_id COLLATE BINARY"),
                    &[],
                    64 * 1024 * 1024,
                )?
            };
            rows.into_iter()
                .map(|row| {
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
                    Ok(row)
                })
                .collect::<io::Result<Vec<_>>>()
        })();
        let end = db.execute("ROLLBACK", &[]);
        self.validate()?;
        end?;
        result
    }
}
