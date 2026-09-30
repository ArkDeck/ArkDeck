//! The v1 SQLite Job index as SQL: its schema, its layout check and the
//! admission and state writes, over a [`HostSqlite`] connection. It holds no
//! path, lock or file identity; `job_repository` owns those (the durable
//! host-store primitives) and the Runtime timestamp order key, and calls in
//! here for every statement. Kept apart so the index's SQL semantics are proved
//! on each platform whose SQLite the Runtime links (TASK-XPA-005).
use arkdeck_platform::{HostSqlite, SqliteValue};
use std::collections::BTreeSet;
use std::io;

pub(crate) const DATABASE: &str = "runtime-jobs.sqlite3";
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
/// Every column of a Job's index row, in `job_row`'s order.
pub(crate) const ROWS: &str = "SELECT job_id, idempotency_key, request_hash, state, created_at_utc, updated_at_utc, version, initial_record_json, created_at_order_key, admission_sequence FROM runtime_job";

/// Swift RuntimeJobAdmissionVerdict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdmissionVerdict {
    Admitted,
    Duplicate(String),
    Conflict,
}

pub(crate) fn corrupt() -> io::Error {
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

/// A first index on an empty database: the schema and `user_version` 1 in
/// one IMMEDIATE transaction, as Swift creates it.
pub(crate) fn create(db: &mut HostSqlite) -> io::Result<()> {
    db.execute("BEGIN IMMEDIATE", &[])?;
    for statement in SCHEMA {
        db.execute(statement, &[])?;
    }
    db.execute("PRAGMA user_version=1", &[])?;
    db.execute("COMMIT", &[])?;
    Ok(())
}

/// Swift requireCurrentLayout's schema pass: `user_version` 1 and exactly the
/// v1 objects, their text compared without whitespace or case.
pub(crate) fn current_layout(db: &mut HostSqlite) -> io::Result<()> {
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

/// The owner connection's journal: WAL with FULL synchronization.
pub(crate) fn owner_journal(db: &mut HostSqlite) -> io::Result<()> {
    if db.query("PRAGMA journal_mode=WAL", &[], 1024)?
        != vec![vec![SqliteValue::Text("wal".into())]]
    {
        return Err(io::Error::other("Runtime SQLite WAL mode is unavailable"));
    }
    db.execute("PRAGMA synchronous=FULL", &[])?;
    Ok(())
}

/// The row a Job's idempotency key already owns, as Swift admission reads it.
pub(crate) fn admitted(
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
pub(crate) fn describes(
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

/// A Job to admit, with the order key of its creation time.
pub(crate) struct Admission<'a> {
    pub id: &'a str,
    pub idempotency_key: &'a str,
    pub request_hash: &'a str,
    pub state: &'a str,
    pub created: &'a str,
    pub created_key: &'a str,
    pub record: &'a [u8],
}

/// Swift RuntimeJobRepository.admit inside the caller's IMMEDIATE
/// transaction: an idempotency key already indexed answers with its own Job,
/// or a conflict for a different request. Otherwise the key, Job identity,
/// initial state and exact initial record are indexed at the next admission
/// sequence, version 1.
pub(crate) fn admit(db: &mut HostSqlite, job: &Admission<'_>) -> io::Result<AdmissionVerdict> {
    if let Some(verdict) = admitted(db, job.idempotency_key, job.request_hash)? {
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
    let Some(sequence) = row
        .first()
        .and_then(SqliteValue::integer)
        .filter(|n| *n > 0)
    else {
        return Err(corrupt());
    };
    db.execute(
        "INSERT INTO runtime_job(job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
        &[
            SqliteValue::Text(job.id.into()),
            SqliteValue::Text(job.idempotency_key.into()),
            SqliteValue::Text(job.request_hash.into()),
            SqliteValue::Text(job.state.into()),
            SqliteValue::Integer(sequence),
            SqliteValue::Text(job.created.into()),
            SqliteValue::Text(job.created_key.into()),
            SqliteValue::Text(job.created.into()),
            SqliteValue::Blob(job.record.to_vec()),
        ],
    )?;
    Ok(AdmissionVerdict::Admitted)
}

/// Swift RuntimeJobRepository.updateJobState inside the caller's IMMEDIATE
/// transaction, on the row this record describes.
pub(crate) fn update(
    db: &mut HostSqlite,
    id: &str,
    idempotency_key: &str,
    created: &str,
    state: &str,
    updated: &str,
    record: &[u8],
) -> io::Result<()> {
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
}
