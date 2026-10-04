//! Isolated host fixtures only. No HDC, authority record or hardware evidence.
use super::*;
use std::fs;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-diagnostic-control-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        crate::test_private::create_private_directory(&path);
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn record(duration: u64, maximum_markers: usize) -> JobRecord {
    JobRecord::decode(&serde_json::to_vec(&json!({
        "jobID":"job-diagnostic-fixture", "request":{
            "documentType":"runtime-operation-request", "schemaVersion":"1.0.0",
            "requestId":"req-diagnostic-fixture", "idempotencyKey":"idem-diagnostic-fixture",
            "operation":{"id":"capture.diagnostic-session", "version":1},
            "target":{"targetId":"TGT-fixture", "expectedBindingRevision":1},
            "inputs":{"durationSeconds":duration, "maximumMarkers":maximum_markers, "traceCategories":["ohos"]},
            "requestedOutputs":["derivedArtifacts"]},
        "operationReference":OPERATION, "catalogDigest":arkdeck_contract::CATALOG_DIGEST,
        "providerID":"hdc", "createdAtUTC":"2026-10-04T00:00:00Z", "actualEffect":"deviceMutation",
        "materializedPlanDigest":"a".repeat(64), "materializedBindingRevision":1,
        "state":"running", "outcomeUnknown":false, "timeline":["fixture"], "actualStepKinds":[], "skipReasons":{}
    })).unwrap()).unwrap()
}

fn seeded(root: &Root, duration: u64, maximum_markers: usize) -> (JobStore, JobRecord) {
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let record = record(duration, maximum_markers);
    jobs.admit(&record, &"b".repeat(64)).unwrap();
    jobs.publish_record_file(&record).unwrap();
    (jobs, record)
}

fn call(jobs: &JobStore, leaf: &str, extra: Value) -> Result<Value, WireError> {
    let method = format!("diagnostic.session.{leaf}");
    let mut params = extra.as_object().unwrap().clone();
    params.insert("jobId".into(), json!("job-diagnostic-fixture"));
    let result = jobs.diagnostic_session_control(&method, &params);
    if let Some(path) = std::env::var_os("ARKDECK_DIAGNOSTIC_CONTRACT_RECORD") {
        use std::io::Write;
        let mut frame = json!({"method":method, "protocolVersion":"1.0.0", "params":params, "ok":result.is_ok()});
        match &result {
            Ok(value) => {
                frame["result"] = value.clone();
            }
            Err(error) => {
                frame["error"] = json!({"code":error.code, "message":error.message});
                if let Some(details) = &error.details {
                    frame["error"]["details"] = json!(details);
                }
            }
        }
        fs::create_dir_all(&path).unwrap();
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(PathBuf::from(path).join(format!("{method}.jsonl")))
            .unwrap();
        file.lock().unwrap();
        writeln!(file, "{}", serde_json::to_string(&frame).unwrap()).unwrap();
    }
    result
}

fn await_recording(session: &LiveSession) {
    let state = session.state.lock().unwrap();
    let (state, timeout) = session
        .changed
        .wait_timeout_while(state, Duration::from_secs(5), |state| {
            state.document.phase == "preparing"
        })
        .unwrap();
    assert!(!timeout.timed_out(), "Runtime did not publish readiness");
    assert_eq!(state.document.phase, "recording");
}

#[test]
fn readiness_idempotency_marker_budget_and_stop_preserve_job_request() {
    let root = Root::new();
    let (jobs, record) = seeded(&root, 60, 2);
    let original = jobs.record_bytes(&record.job_id).unwrap();
    assert_eq!(
        call(&jobs, "status", json!({})).unwrap()["controlAvailable"],
        false
    );
    let owner = jobs.begin_diagnostic_session(&record).unwrap();
    assert_eq!(
        call(&jobs, "status", json!({})).unwrap()["state"],
        "preparing"
    );
    assert!(call(&jobs, "mark", json!({"markerId":"too-early"})).is_err());
    std::thread::scope(|scope| {
        let waiting = scope.spawn(|| owner.session.wait(60));
        await_recording(&owner.session);
        let first = call(
            &jobs,
            "mark",
            json!({"markerId":"mark-one", "label":"Problem occurred"}),
        )
        .unwrap();
        assert_eq!(first["state"], "recording");
        assert_eq!(first["markers"][0]["label"], "Problem occurred");
        assert!(
            first["markers"][0]["atHostUTC"]
                .as_str()
                .unwrap()
                .ends_with('Z')
        );
        let repeat = call(
            &jobs,
            "mark",
            json!({"markerId":"mark-one", "label":"Problem occurred"}),
        )
        .unwrap();
        assert_eq!(first["markers"], repeat["markers"]);
        assert!(
            call(
                &jobs,
                "mark",
                json!({"markerId":"mark-one", "label":"Changed"})
            )
            .is_err()
        );
        call(&jobs, "mark", json!({"markerId":"mark-two"})).unwrap();
        assert!(call(&jobs, "mark", json!({"markerId":"over-budget"})).is_err());
        assert!(
            call(
                &jobs,
                "mark",
                json!({"markerId":"bad-label", "label":"$(shell)"})
            )
            .is_err()
        );
        assert!(
            call(
                &jobs,
                "mark",
                json!({"markerId":"forged-time", "atHostUTC":"2026-01-01T00:00:00Z"})
            )
            .is_err()
        );
        assert_eq!(
            call(&jobs, "stop", json!({})).unwrap()["stopRequested"],
            true
        );
        call(&jobs, "stop", json!({})).unwrap();
        assert!(waiting.join().unwrap().is_ok());
        assert_eq!(
            call(&jobs, "status", json!({})).unwrap()["state"],
            "finalizing"
        );
        // The same acknowledged mark remains idempotent while the live owner
        // drains, including the finalizing response's end timestamp.
        call(
            &jobs,
            "mark",
            json!({"markerId":"mark-one", "label":"Problem occurred"}),
        )
        .unwrap();
        assert!(call(&jobs, "mark", json!({"markerId":"after-stop"})).is_err());
    });
    drop(owner);
    assert!(call(&jobs, "mark", json!({"markerId":"after-owner"})).is_err());
    assert_eq!(jobs.record_bytes(&record.job_id).unwrap(), original);
    let document = jobs.diagnostic_document(&record).unwrap().unwrap();
    assert_eq!(document.markers.len(), 2);
    assert!(document.elapsed_ms < 60_000);
    assert!(
        jobs.begin_diagnostic_session(&record).is_err(),
        "a prior document never resumes a session"
    );
}

#[test]
fn published_controls_cover_unknown_job_refusal() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    for leaf in ["status", "mark", "stop"] {
        assert!(call(&jobs, leaf, json!({"markerId":"mark-missing"})).is_err());
    }
}

#[test]
fn deadline_finishes_without_client_and_rejects_late_marks() {
    let root = Root::new();
    let (jobs, record) = seeded(&root, 1, 200);
    let owner = jobs.begin_diagnostic_session(&record).unwrap();
    owner.session.wait(1).unwrap();
    let status = call(&jobs, "status", json!({})).unwrap();
    assert_eq!(status["state"], "finalizing");
    assert_eq!(status["elapsedMs"], 1_000);
    assert_eq!(status["stopRequested"], false);
    assert!(call(&jobs, "mark", json!({"markerId":"late"})).is_err());
}

#[test]
fn stop_during_arm_does_not_wait_for_the_full_budget() {
    let root = Root::new();
    let (jobs, record) = seeded(&root, 60, 50);
    let owner = jobs.begin_diagnostic_session(&record).unwrap();
    call(&jobs, "stop", json!({})).unwrap();
    let start = Instant::now();
    owner.session.wait(60).unwrap();
    assert!(start.elapsed() < Duration::from_secs(5));
    assert_eq!(
        call(&jobs, "status", json!({})).unwrap()["state"],
        "finalizing"
    );
}

#[test]
fn lost_directory_identity_closes_admission_and_wakes_waiter() {
    let root = Root::new();
    let (jobs, record) = seeded(&root, 60, 50);
    let owner = jobs.begin_diagnostic_session(&record).unwrap();
    std::thread::scope(|scope| {
        let waiting = scope.spawn(|| owner.session.wait(60));
        await_recording(&owner.session);
        fs::rename(&owner.session.path, root.0.join("retained-original-job")).unwrap();
        crate::test_private::create_private_directory(&owner.session.path);
        assert!(owner.session.stop().is_err());
        assert!(waiting.join().unwrap().is_err());
        assert!(owner.session.mark("after-loss", None).is_err());
    });
    assert!(!owner.session.path.join(DOCUMENT).exists());
}

#[test]
fn dropped_owner_and_unreadable_state_cannot_be_reopened() {
    let root = Root::new();
    let (jobs, record) = seeded(&root, 60, 50);
    let owner = jobs.begin_diagnostic_session(&record).unwrap();
    let retained_handle = Arc::clone(&owner.session);
    drop(owner);
    assert_eq!(
        call(&jobs, "status", json!({})).unwrap()["state"],
        "interrupted"
    );
    assert!(retained_handle.mark("stale-handle", None).is_err());
    assert!(retained_handle.stop().is_err());
    assert!(call(&jobs, "stop", json!({})).is_err());
    assert!(jobs.begin_diagnostic_session(&record).is_err());
    fs::write(
        root.0.join("jobs").join(&record.job_id).join(DOCUMENT),
        b"{broken",
    )
    .unwrap();
    assert!(call(&jobs, "status", json!({})).is_err());
}
