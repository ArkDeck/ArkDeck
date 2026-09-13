#![cfg(target_os = "macos")]
//! The Rust Job owner writes the SQLite admission index and `job-record.json`
//! as Swift RuntimeAdmissionService and RuntimeJobRecord.persist do, checked
//! against the oracle Swift JobStoreRustWriterParityContractTests records in
//! rust/tests/fixtures/job-store-writer.
use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore, JobWriteError};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::os::unix::fs::PermissionsExt;
use std::{
    fs,
    path::{Path, PathBuf},
};

fn oracle(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/job-store-writer")
        .join(name)
}
fn value(name: &str) -> Value {
    serde_json::from_slice(&fs::read(oracle(name)).unwrap()).unwrap()
}
fn record(name: &str) -> JobRecord {
    JobRecord::decode(&fs::read(oracle(name)).unwrap()).unwrap()
}

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = arkdeck_platform::random_bytes::<8>().unwrap();
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-job-writer-{}-{:x}",
            std::process::id(),
            u64::from_ne_bytes(nonce)
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn verdict(value: &Value) -> AdmissionVerdict {
    match value.as_str() {
        Some("admitted") => AdmissionVerdict::Admitted,
        Some("conflict") => AdmissionVerdict::Conflict,
        _ => AdmissionVerdict::Duplicate(value["duplicate"].as_str().unwrap().into()),
    }
}

/// Apply the Swift scenario to a Rust owner store.
fn replay(path: &Path) {
    let store = JobStore::open_owner(path).unwrap();
    for step in value("scenario.json").as_array().unwrap() {
        let text = |key: &str| step[key].as_str().unwrap();
        match text("op") {
            "admit" => assert_eq!(
                store
                    .admit(&record(text("record")), text("requestHash"))
                    .unwrap(),
                verdict(&step["verdict"]),
                "{step}"
            ),
            "lookup" => assert_eq!(
                store
                    .lookup(text("idempotencyKey"), text("requestHash"))
                    .unwrap(),
                verdict(&step["verdict"]),
                "{step}"
            ),
            "persist" => store.persist(&record(text("record")), text("at")).unwrap(),
            other => panic!("unknown scenario step {other}"),
        }
    }
}

/// The facts the Swift oracle records, read through a read-only connection.
/// A Job without a record file reads as null.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), true, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(bytes)),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let mut records = Map::new();
    for row in &rows {
        let id = row["jobId"].as_str().unwrap();
        let file = fs::read(path.join("jobs").join(id).join("job-record.json"));
        records.insert(
            id.into(),
            file.map_or(Value::Null, |bytes| {
                json!(arkdeck_contract::sha256_hex(&bytes))
            }),
        );
    }
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows,
        "jobRecords": records})
}

#[test]
fn swift_records_reencode_to_their_exact_bytes() {
    let mut paths: Vec<PathBuf> = fs::read_dir(oracle("records"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    paths.sort();
    assert_eq!(paths.len(), 5);
    let publication =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-publication-current");
    paths.extend([
        publication.join("published/job-record.json"),
        publication.join("failed/job-record.json"),
    ]);
    for path in paths {
        let bytes = fs::read(&path).unwrap();
        let record = JobRecord::decode(&bytes).unwrap();
        assert_eq!(record.durable_bytes().unwrap(), bytes, "{}", path.display());
    }
}

#[test]
fn rust_owner_replays_the_swift_index_scenario() {
    let root = Root::new();
    replay(&root.0);
    assert_eq!(index(&root.0), value("index.json"));
    if let Some(output) = std::env::var_os("ARKDECK_RUST_JOB_STORE_OUTPUT") {
        // Local evidence: Swift JobStoreRustWriterParityContractTests reads it.
        let output = PathBuf::from(output);
        assert!(output.starts_with("/private/tmp/") && !output.exists());
        fs::create_dir(&output).unwrap();
        fs::set_permissions(&output, fs::Permissions::from_mode(0o700)).unwrap();
        replay(&output);
        assert_eq!(index(&output), value("index.json"));
    }
    // A reopened owner still answers the first admission with its own Job,
    // and the readers agree with what the owner wrote.
    let store = JobStore::open_owner(&root.0).unwrap();
    let scenario = value("scenario.json");
    let first = record(scenario[0]["record"].as_str().unwrap());
    assert_eq!(
        store
            .admit(&first, scenario[0]["requestHash"].as_str().unwrap())
            .unwrap(),
        AdmissionVerdict::Duplicate(first.job_id.clone())
    );
    drop(store);
    let reader = JobStore::open(&root.0).unwrap();
    assert_eq!(
        reader
            .read_snapshot(&first.job_id)
            .unwrap()
            .value()
            .unwrap(),
        record("records/published-a.json").value().unwrap()
    );
    assert_eq!(
        reader
            .with_active_sessions(|active| Ok(active.len()))
            .unwrap(),
        2
    );
}

#[test]
fn refused_writes_leave_the_index_and_records_unchanged() {
    let root = Root::new();
    let store = JobStore::open_owner(&root.0).unwrap();
    let admitted = record("records/admitted-a.json");
    let running = record("records/running-a.json");
    assert!(matches!(
        store.admit(&admitted, "not-a-digest"),
        Err(JobWriteError::Invalid(_))
    ));
    // Nothing is persisted for a Job the index does not describe.
    assert!(matches!(
        store.persist(&running, "2026-07-29T00:00:03Z"),
        Err(JobWriteError::Refused(_))
    ));
    assert!(!root.0.join("jobs").join(&running.job_id).exists());
    assert_eq!(
        store.admit(&admitted, &"a".repeat(64)).unwrap(),
        AdmissionVerdict::Admitted
    );
    let before = index(&root.0);
    assert!(matches!(
        store.persist(&running, "yesterday"),
        Err(JobWriteError::Invalid(_))
    ));
    // A record whose creation time is not its row's is refused before its file.
    let mut moved = value("records/running-a.json");
    moved["createdAtUTC"] = json!("2026-07-29T00:00:09Z");
    let moved = JobRecord::decode(&serde_json::to_vec(&moved).unwrap()).unwrap();
    assert!(matches!(
        store.persist(&moved, "2026-07-29T00:00:03Z"),
        Err(JobWriteError::Refused(_))
    ));
    assert!(!root.0.join("jobs").join(&running.job_id).exists());
    assert_eq!(index(&root.0), before);
    drop(store);
    // A store opened for reading never writes.
    let reader = JobStore::open(&root.0).unwrap();
    assert!(matches!(
        reader.admit(&record("records/admitted-b.json"), &"b".repeat(64)),
        Err(JobWriteError::Refused(_))
    ));
    assert!(matches!(
        reader.persist(&running, "2026-07-29T00:00:03Z"),
        Err(JobWriteError::Refused(_))
    ));
    drop(reader);
    assert!(!root.0.join("jobs").join(&running.job_id).exists());
    assert_eq!(index(&root.0), before);
}

#[test]
fn one_owner_holds_the_store() {
    let root = Root::new();
    let owner = JobStore::open_owner(&root.0).unwrap();
    assert!(JobStore::open_owner(&root.0).is_err());
    assert!(JobStore::open(&root.0).is_err());
    drop(owner);
    // A closed owner leaves no log to replay: a reader and an owner reopen it.
    drop(JobStore::open(&root.0).unwrap());
    drop(JobStore::open_owner(&root.0).unwrap());
}

#[test]
fn a_refused_layout_with_a_live_log_is_not_rewritten() {
    let root = Root::new();
    {
        let store = JobStore::open_owner(&root.0).unwrap();
        store
            .admit(&record("records/admitted-a.json"), &"a".repeat(64))
            .unwrap();
    }
    let database = root.0.join("runtime-jobs.sqlite3");
    let log = root.0.join("runtime-jobs.sqlite3-wal");
    let mut live = HostSqlite::open(&database, false, false).unwrap();
    assert_eq!(
        live.query("PRAGMA journal_mode", &[], 1024).unwrap(),
        vec![vec![Sql::Text("wal".into())]]
    );
    live.execute("PRAGMA user_version=2", &[]).unwrap();
    let before = (fs::read(&database).unwrap(), fs::read(&log).unwrap());
    assert!(!before.1.is_empty());
    assert!(JobStore::open_owner(&root.0).is_err());
    assert!(JobStore::open(&root.0).is_err());
    assert_eq!(
        (fs::read(&database).unwrap(), fs::read(&log).unwrap()),
        before
    );
    drop(live);
}
