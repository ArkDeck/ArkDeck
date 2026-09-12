#![cfg(target_os = "macos")]
use arkdeck_hoststore::JobStore;
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::{fs, path::PathBuf};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = arkdeck_platform::random_bytes::<8>().unwrap();
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-job-owner-{}-{:x}",
            std::process::id(),
            u64::from_ne_bytes(nonce)
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
    fn initialized() -> Self {
        let root = Self::new();
        drop(JobStore::open(&root.0).unwrap());
        root
    }
    fn db(&self) -> HostSqlite {
        HostSqlite::open(&self.0.join("runtime-jobs.sqlite3"), false, false).unwrap()
    }
    fn seed(&self, id: &str, state: &str, sequence: i64) {
        let data = record(id, state);
        let date = "2026-08-31T12:00:00Z";
        let seconds = arkdeck_platform::host_gregorian_seconds(2026, 8, 31, 12, 0, 0).unwrap();
        let key = format!("{:016x}", seconds.to_bits() ^ (1 << 63));
        self.db()
            .execute(
                "INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    Sql::Text(id.into()),
                    Sql::Text(format!("idem-{id}")),
                    Sql::Text("b".repeat(64)),
                    Sql::Text(state.into()),
                    Sql::Integer(sequence),
                    Sql::Text(date.into()),
                    Sql::Text(key),
                    Sql::Text(date.into()),
                    Sql::Integer(1),
                    Sql::Blob(serde_json::to_vec(&data).unwrap()),
                ],
            )
            .unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn record(id: &str, state: &str) -> Value {
    json!({"jobID":id, "request":{"documentType":"runtime-operation-request", "schemaVersion":"1.0.0", "requestId":format!("req-{id}"), "idempotencyKey":format!("idem-{id}"), "target":{"targetId":"TGT-fixture", "expectedBindingRevision":1}, "operation":{"id":"observe.device", "version":1}, "inputs":{"privateInput":"private-input-value"}, "requestedOutputs":["derivedArtifacts"]}, "operationReference":"observe.device@1", "catalogDigest":arkdeck_contract::CATALOG_DIGEST, "providerID":"hdc", "createdAtUTC":"2026-08-31T12:00:00Z", "actualEffect":"readOnly", "materializedPlanDigest":"a".repeat(64), "materializedBindingRevision":1, "state":state, "outcomeUnknown":state=="waitingForRecovery", "timeline":["created", "completed"], "actualStepKinds":[], "skipReasons":{}})
}
fn handle(
    store: &JobStore,
    method: &str,
    params: Value,
) -> Result<Value, arkdeck_contract::WireError> {
    store.handle_resource(method, params.as_object().unwrap())
}

#[test]
fn current_sqlite_records_are_read_after_restart_with_frozen_pages() {
    let root = Root::initialized();
    root.seed("job-b", "succeeded", 1);
    root.seed("job-a", "waitingForRecovery", 2);
    let store = JobStore::open(&root.0).unwrap();
    assert!(
        JobStore::open(&root.0).is_err(),
        "two owners cannot coexist"
    );
    let status = handle(&store, "job.status", json!({"jobId":"job-a"})).unwrap();
    assert_eq!(status["outcome"], "outcomeUnknown");
    assert_eq!(status["nextAction"]["kind"], "reconcile");
    assert_eq!(status["failure"]["schemaVersion"], "1.0.0");
    assert_eq!(status["sessionPublication"]["state"], "unavailable");
    let first = handle(&store, "job.list", json!({"pageSize":1})).unwrap();
    assert_eq!(first["items"][0]["jobId"], "job-a");
    let cursor = first["nextCursor"].clone();
    assert!(cursor.is_string());
    drop(store);
    root.seed("job-0", "succeeded", 3);
    let store = JobStore::open(&root.0).unwrap();
    let continuation = handle(&store, "job.list", json!({"pageSize":1,"cursor":cursor})).unwrap();
    assert_eq!(continuation["items"][0]["jobId"], "job-b");
    assert_eq!(continuation["snapshotRevision"], first["snapshotRevision"]);
    assert_eq!(
        handle(
            &store,
            "job.list",
            json!({"pageSize":1,"cursor":cursor,"state":"succeeded"})
        )
        .unwrap_err()
        .code,
        "invalidCursor"
    );
    let show = handle(&store, "job.show", json!({"jobId":"job-b"})).unwrap();
    assert_eq!(show["actualStepKinds"], json!([]));
    assert_eq!(show["job"]["jobId"], "job-b");
    assert_eq!(
        handle(&store, "job.timeline", json!({"jobId":"job-b"})).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn corrupt_identity_and_unknown_fields_fail_the_complete_list() {
    let root = Root::initialized();
    root.seed("job-a", "succeeded", 1);
    let before = fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap();
    let store = JobStore::open(&root.0).unwrap();
    assert_eq!(
        handle(&store, "job.status", json!({"jobId":"missing"}))
            .unwrap_err()
            .code,
        "notFound"
    );
    assert_eq!(
        handle(&store, "job.status", json!({"jobId":"../job-a"}))
            .unwrap_err()
            .code,
        "invalidInput"
    );
    assert_eq!(
        handle(&store, "job.list", json!({"includeCurrent":"true"}))
            .unwrap_err()
            .code,
        "invalidInput"
    );
    drop(store);
    assert_eq!(
        fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap(),
        before
    );
    for alteration in ["extra", "identity", "null", "nested"] {
        let mut value = record("job-a", "succeeded");
        match alteration {
            "extra" => value["futureField"] = json!(true),
            "identity" => value["request"]["idempotencyKey"] = json!("other"),
            "null" => value["startedAtUTC"] = Value::Null,
            "nested" => value["request"]["operation"]["shell"] = json!("forbidden"),
            _ => unreachable!(),
        }
        root.db()
            .execute(
                "UPDATE runtime_job SET initial_record_json = ?",
                &[Sql::Blob(serde_json::to_vec(&value).unwrap())],
            )
            .unwrap();
        let store = JobStore::open(&root.0).unwrap();
        assert_eq!(
            handle(&store, "job.list", json!({})).unwrap_err().code,
            "recordUnreadable",
            "{alteration}"
        );
    }
}

#[test]
fn unsupported_layout_and_missing_index_are_preserved() {
    let root = Root::initialized();
    root.db()
        .execute("CREATE TABLE future(value TEXT)", &[])
        .unwrap();
    let before = fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap();
    assert!(JobStore::open(&root.0).is_err());
    assert_eq!(
        fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap(),
        before
    );
    let root = Root::initialized();
    fs::remove_file(root.0.join("runtime-jobs.sqlite3")).unwrap();
    assert!(
        JobStore::open(&root.0).is_err(),
        "a lost initialized index must not become empty history"
    );
    assert!(!root.0.join("runtime-jobs.sqlite3").exists());
    let root = Root::new();
    fs::write(root.0.join("unsettled-intent.json"), b"retained").unwrap();
    assert!(JobStore::open(&root.0).is_err());
    assert!(!root.0.join("runtime-jobs.sqlite3").exists());
    assert_eq!(
        fs::read(root.0.join("unsettled-intent.json")).unwrap(),
        b"retained"
    );
}

#[test]
fn active_session_census_retains_unknown_outcomes_and_refuses_unreadable_rows() {
    let root = Root::initialized();
    root.seed("parked", "waitingForRecovery", 1);
    root.seed("finished", "succeeded", 2);
    root.seed("running", "running", 3);
    let store = JobStore::open(&root.0).unwrap();
    store
        .with_active_sessions(|active| {
            assert_eq!(
                active.iter().map(String::as_str).collect::<Vec<_>>(),
                vec!["session-parked", "session-running"]
            );
            Ok(())
        })
        .unwrap();
    drop(store);
    root.db()
        .execute(
            "UPDATE runtime_job SET initial_record_json = ? WHERE job_id = ?",
            &[Sql::Blob(b"{}".to_vec()), Sql::Text("finished".into())],
        )
        .unwrap();
    let store = JobStore::open(&root.0).unwrap();
    let mut invoked = false;
    assert!(
        store
            .with_active_sessions(|_| {
                invoked = true;
                Ok(())
            })
            .is_err()
    );
    assert!(!invoked, "an incomplete census cannot reach cleanup");
}

#[test]
fn activity_census_retains_durable_history_and_refuses_orphaned_or_unsafe_jobs() {
    use std::os::unix::fs::DirBuilderExt;
    let root = Root::initialized();
    root.seed("finished", "succeeded", 1);
    let history = root.0.join("jobs/finished");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&history)
        .unwrap();
    fs::write(history.join("journal.jsonl"), b"unknown retained history").unwrap();
    let store = JobStore::open(&root.0).unwrap();
    store
        .with_active_sessions(|active| {
            assert_eq!(
                active.iter().map(String::as_str).collect::<Vec<_>>(),
                vec!["session-finished"]
            );
            Ok(())
        })
        .unwrap();
    let orphan = root.0.join("jobs/unindexed");
    fs::DirBuilder::new().mode(0o700).create(&orphan).unwrap();
    let mut invoked = false;
    assert_eq!(
        store
            .with_active_sessions(|_| {
                invoked = true;
                Ok(())
            })
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
    assert!(!invoked);
    fs::remove_dir(orphan).unwrap();
    fs::set_permissions(&history, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        store
            .with_active_sessions(|_| {
                invoked = true;
                Ok(())
            })
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
    assert!(!invoked);
    fs::set_permissions(history, fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn sqlite_refuses_symlinks_and_multi_statement_input() {
    let root = Root::initialized();
    assert!(root.db().query("SELECT 1; SELECT 2", &[], 1024).is_err());
    assert!(root.db().query("SELECT ?", &[], 1024).is_err());
    std::os::unix::fs::symlink(
        root.0.join("runtime-jobs.sqlite3"),
        root.0.join("runtime-jobs.sqlite3-wal"),
    )
    .unwrap();
    assert!(JobStore::open(&root.0).is_err());
}
