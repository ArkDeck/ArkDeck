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

fn publication_marker() -> Value {
    json!({"sessionID":"session-job-private", "catalogDigest":arkdeck_contract::CATALOG_DIGEST,
        "policyGeneration":"0", "root":{"path":"/private/fixture-session-root","device":"0","inode":"0","volumeIdentity":""},
        "relativeSessionPath":"", "claims":[], "phase":"awaitingStorage"})
}

#[test]
fn native_swift_publication_snapshots_preserve_records_and_public_results() {
    let fixtures = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/job-publication-current");
    for name in ["published", "failed"] {
        let bytes = fs::read(fixtures.join(name).join("job-record.json")).unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        let expected: Value =
            serde_json::from_slice(&fs::read(fixtures.join(name).join("show.json")).unwrap())
                .unwrap();
        let record = arkdeck_hoststore::JobRecord::decode(&bytes).unwrap();
        assert_eq!(record.value().unwrap(), value, "{name}");
        let id = value["jobID"].as_str().unwrap();
        let date = value["createdAtUTC"].as_str().unwrap();
        assert_eq!(date, "2026-07-29T00:00:00Z");
        let seconds = arkdeck_platform::host_gregorian_seconds(2026, 7, 29, 0, 0, 0).unwrap();
        let key = format!("{:016x}", seconds.to_bits() ^ (1 << 63));
        let root = Root::initialized();
        root.db()
            .execute(
                "INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    Sql::Text(id.into()),
                    Sql::Text(value["request"]["idempotencyKey"].as_str().unwrap().into()),
                    Sql::Text(arkdeck_contract::sha256_hex(
                        &serde_json::to_vec(&value["request"]).unwrap(),
                    )),
                    Sql::Text(value["state"].as_str().unwrap().into()),
                    Sql::Integer(1),
                    Sql::Text(date.into()),
                    Sql::Text(key),
                    Sql::Text(date.into()),
                    Sql::Integer(1),
                    Sql::Blob(bytes.clone()),
                ],
            )
            .unwrap();
        let before = fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap();
        let store = JobStore::open(&root.0).unwrap();
        assert_eq!(store.read_snapshot(id).unwrap().value().unwrap(), value);
        let result = handle(&store, "job.show", json!({"jobId":id})).unwrap();
        assert_eq!(result, expected, "native {name} projection");
        assert_eq!(result["job"]["state"], "succeeded");
        assert_eq!(result["job"]["sessionPublication"]["state"], name);
        drop(store);
        assert_eq!(
            fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap(),
            before
        );
        assert_eq!(
            fs::read(fixtures.join(name).join("job-record.json")).unwrap(),
            bytes
        );
        let mut changed = value;
        changed["sessionPublicationRecord"]["root"]["unexpected"] = json!(true);
        assert!(
            arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(&changed).unwrap()).is_err()
        );
    }
}

#[test]
fn historical_capability_correlation_is_checked_without_granting_execution() {
    let mut value = record("job-private", "waitingForRecovery");
    value["originalSubmissionRequest"] = value["request"].clone();
    value["request"]["authorization"] = json!({"capabilityId":"CAP-RT-SNAPSHOT-FIXTURE"});
    value["admissionEvidence"] = json!({"kind":"runtimeCapability","reference":"CAP-RT-SNAPSHOT-FIXTURE",
        "admittedAtUTC":"2026-08-31T12:00:00Z","validUntilUTC":"2026-08-31T12:05:00Z",
        "consumptionFingerprintSHA256":"c".repeat(64),"runtimeCapabilityCorrelation":{
            "reservationID":"idem-job-private","useOrdinal":1,"planDigestSHA256":"a".repeat(64),
            "stepSetDigestSHA256":"d".repeat(64),"targetBindingDigestSHA256":arkdeck_contract::sha256_hex(b"-\n1")}});
    let decode = |v: &Value| arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(v).unwrap());
    assert_eq!(decode(&value).unwrap().value().unwrap(), value);
    for mutation in [
        "original",
        "authorization",
        "reservation",
        "ordinal",
        "plan",
        "binding",
        "fingerprint",
        "kind",
        "nested",
    ] {
        let mut changed = value.clone();
        match mutation {
            "original" => {
                changed
                    .as_object_mut()
                    .unwrap()
                    .remove("originalSubmissionRequest");
            }
            "authorization" => {
                changed["request"]["authorization"]["capabilityId"] = json!("CAP-RT-OTHER")
            }
            "reservation" => {
                changed["admissionEvidence"]["runtimeCapabilityCorrelation"]["reservationID"] =
                    json!("other")
            }
            "ordinal" => {
                changed["admissionEvidence"]["runtimeCapabilityCorrelation"]["useOrdinal"] =
                    json!(0)
            }
            "plan" => {
                changed["admissionEvidence"]["runtimeCapabilityCorrelation"]["planDigestSHA256"] =
                    json!("e".repeat(64))
            }
            "binding" => {
                changed["admissionEvidence"]["runtimeCapabilityCorrelation"]["targetBindingDigestSHA256"] =
                    json!("e".repeat(64))
            }
            "fingerprint" => {
                changed["admissionEvidence"]["consumptionFingerprintSHA256"] = Value::Null
            }
            "kind" => changed["admissionEvidence"]["kind"] = json!("defaultReadOnlyPolicy"),
            "nested" => {
                changed["admissionEvidence"]["runtimeCapabilityCorrelation"]["futureAuthority"] =
                    json!(true)
            }
            _ => unreachable!(),
        }
        assert!(decode(&changed).is_err(), "{mutation}");
    }
}

#[test]
fn private_snapshot_fields_roundtrip_but_do_not_escape_job_show() {
    let root = Root::initialized();
    root.seed("job-private", "succeeded", 1);
    let mut value = record("job-private", "succeeded");
    value["sessionPublicationRecord"] = publication_marker();
    value["recoveryStepID"] = json!("private-step");
    value["recoveryIntentEventID"] = json!("private-intent");
    value["recoveryAction"] =
        json!({"kind":"hdc.observeTool","arguments":{"privateArgument":"private-value"}});
    value["evidenceObservation"] = json!({"providerID":"hdc","toolVersion":"fixture","toolSHA256":"c".repeat(64),
        "confirmationMethod":"machineReadback","preflightSteps":[{"stepID":"inspect","stepKind":"observe","outcomeAtUTC":"2026-08-31T12:00:00Z"}]});
    value["traceProbeBefore"] = json!({"targetID":"TGT-fixture","bindingRevision":1,"adapterDisposition":"unavailable",
        "supportedTags":[],"tools":[{"tool":"fixture","disposition":"probeFailed"}],"parameters":[{"name":"private-param","state":"unreadable"}]});
    let encoded = serde_json::to_vec(&value).unwrap();
    root.db()
        .execute(
            "UPDATE runtime_job SET initial_record_json = ?",
            &[Sql::Blob(encoded)],
        )
        .unwrap();
    let before = fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap();
    let store = JobStore::open(&root.0).unwrap();
    assert_eq!(
        store.read_snapshot("job-private").unwrap().value().unwrap(),
        value
    );
    let show = handle(&store, "job.show", json!({"jobId":"job-private"})).unwrap();
    assert_eq!(show["job"]["sessionPublication"]["state"], "pending");
    assert_eq!(
        show["job"]["sessionPublication"]["reasonCode"],
        "waitingForStorage"
    );
    let wire = serde_json::to_string(&show).unwrap();
    for private in [
        "private-step",
        "private-intent",
        "privateArgument",
        "private-param",
        "/private/fixture-session-root",
        "sessionPublicationRecord",
        "evidenceObservation",
    ] {
        assert!(!wire.contains(private), "{private}");
    }
    drop(store);
    assert_eq!(
        fs::read(root.0.join("runtime-jobs.sqlite3")).unwrap(),
        before
    );
    for pointer in [
        "/sessionPublicationRecord/root",
        "/recoveryAction",
        "/evidenceObservation/preflightSteps/0",
        "/traceProbeBefore/tools/0",
        "/traceProbeBefore/parameters/0",
    ] {
        let mut changed = value.clone();
        changed
            .pointer_mut(pointer)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert("unknownField".into(), json!(true));
        assert!(
            arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(&changed).unwrap()).is_err(),
            "{pointer}"
        );
    }
}

#[test]
fn publication_receipt_precedes_failure_and_uncertainty_never_becomes_failure() {
    let root = Root::initialized();
    root.seed("job-private", "succeeded", 1);
    let mut marker = publication_marker();
    marker["failure"] = json!({"code":"sourceIntegrityFailed","certainty":"confirmed","detail":"private diagnostic"});
    let mut cases = vec![(marker.clone(), "failed", json!("sourceIntegrityFailed"))];
    marker["failure"]["certainty"] = json!("outcomeUnknown");
    cases.push((
        marker.clone(),
        "outcomeUnknown",
        json!("publicationUncertain"),
    ));
    marker["receipt"] = json!({"manifestSHA256":"d".repeat(64),"catalogGeneration":u64::MAX.to_string(),"publishedAtUTC":"2026-08-31T12:00:00Z"});
    cases.push((marker.clone(), "published", Value::Null));
    marker["receipt"]["catalogGeneration"] = json!("018");
    cases.push((marker, "outcomeUnknown", json!("publicationUncertain")));
    for (marker, state, reason) in cases {
        let mut value = record("job-private", "succeeded");
        value["sessionPublicationRecord"] = marker;
        root.db()
            .execute(
                "UPDATE runtime_job SET initial_record_json = ?",
                &[Sql::Blob(serde_json::to_vec(&value).unwrap())],
            )
            .unwrap();
        let store = JobStore::open(&root.0).unwrap();
        let status = handle(&store, "job.status", json!({"jobId":"job-private"})).unwrap();
        assert_eq!(status["sessionPublication"]["state"], state);
        assert_eq!(status["sessionPublication"]["reasonCode"], reason);
        assert_eq!(status["nextAction"]["kind"], "readResult");
        drop(store);
    }
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
