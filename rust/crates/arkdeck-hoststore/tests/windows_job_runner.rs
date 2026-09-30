//! The Job runner's owners on Windows (TASK-XPA-005, GJ-1): what a Job's
//! run, cancellation and result come to over the NTFS host store, against
//! the recorded Swift `observe.device@1` corpus
//! (`rust/tests/fixtures/observe-device`) and the Swift cancellation oracle
//! (`rust/tests/fixtures/job-cancel-analyzer`).
//!
//! * `job.result` and `job.evidence` of the four recorded Jobs, read from
//!   their records, journals and Artifacts laid down as Swift left them,
//!   answer as Swift answered (T0 but a refusal's wording, T2);
//! * a queued `observe.device@1` Job, admitted here in process over an HDC
//!   composition whose dispatcher fails the test if called, is cancelled
//!   before it runs: the same three transitions, reasons and failure as
//!   Swift's cancelled-before-run Job, zero dispatch, its Session published
//!   through the Session owner, and a later `job.run` refused as terminal;
//! * without an HDC composition — the Windows daemon's, no Windows HDC tuple
//!   being registered — a queued device Job is refused before its run with
//!   zero dispatch, and stays queued.
//!
//! The restart and recovery paths run on Windows in `job_recovery.rs`.
#![cfg(windows)]

use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobCanceller, JobPlanner, JobRecord,
    JobResultReader, JobRunner, JobStore, SessionPublisher, SessionStore, StorageClaims,
    SystemStorageProbe, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
}

/// A dispatcher nothing here may reach.
struct NoDispatch;
impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("dispatched {:?}", plan.arguments)
    }
}

/// A fresh owner-only root below the temporary directory, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        // The canonical spelling without `\\?\`, as the Session owner
        // compares roots.
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winrunner-{nonce:016x}"));
        HostDirectory::open_or_create_private(&path).unwrap();
        for owner in [
            "targets-state",
            "artifacts",
            "jobs-state",
            "session-owner",
            "Sessions",
        ] {
            HostDirectory::open_or_create_private(&path.join(owner)).unwrap();
        }
        Self(path)
    }
    fn jobs_state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// The Target document Swift's adoption wrote (owner-only: it inherits
    /// the directory's descriptor).
    fn with_target(self) -> Self {
        fs::write(
            self.0.join("targets-state/targets.json"),
            fs::read(fixture("observe-device/targets-state/targets.json")).unwrap(),
        )
        .unwrap();
        self
    }
    /// The recorded Jobs: admitted and advanced to their recorded version by
    /// the Job owner, each Journal beside its record, and their Artifacts as
    /// the macOS Runtime published them (index owner-only, payloads sealed).
    fn with_recorded_jobs(self) -> Self {
        let store = JobStore::open_owner(&self.jobs_state()).unwrap();
        let recorded = fixture("observe-device/store");
        let index = document(recorded.join("index.json"));
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = recorded.join("jobs").join(id);
            let record =
                JobRecord::decode(&fs::read(directory.join("job-record.json")).unwrap()).unwrap();
            store
                .admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap();
            for _ in 1..row["version"].as_i64().unwrap() {
                store
                    .persist(&record, row["updatedAtUTC"].as_str().unwrap())
                    .unwrap();
            }
            fs::copy(
                directory.join("journal.jsonl"),
                self.jobs_state()
                    .join("jobs")
                    .join(id)
                    .join("journal.jsonl"),
            )
            .unwrap();
        }
        let artifacts = HostDirectory::open(&self.0.join("artifacts")).unwrap();
        for job in fs::read_dir(fixture("observe-device/artifacts")).unwrap() {
            let job = job.unwrap().path();
            let owned = artifacts
                .create_private_child(job.file_name().unwrap().to_str().unwrap())
                .unwrap();
            for file in fs::read_dir(&job).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap().to_str().unwrap().to_owned();
                owned
                    .create_document(&name, &fs::read(&file).unwrap())
                    .unwrap();
                if name != "index.json" {
                    owned.seal_document(&name).unwrap();
                }
            }
        }
        self
    }
    fn journal(&self, id: &str) -> Vec<Value> {
        fs::read_to_string(
            self.jobs_state()
                .join("jobs")
                .join(id)
                .join("journal.jsonl"),
        )
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// An answer as the oracles record it, a refusal's wording aside (T2).
fn semantic(answer: Result<Value, arkdeck_contract::WireError>) -> Value {
    match answer {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    }
}

fn recorded_semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

#[test]
fn recorded_results_and_evidence_read_as_swift_answered() {
    let root = Root::new().with_recorded_jobs();
    let jobs = JobStore::open(&root.jobs_state()).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let cases = document(fixture("observe-device/cases.json"));
    let (mut replayed, mut differences) = (0, Vec::new());
    for exchange in cases["exchanges"].as_array().unwrap() {
        let method = exchange["method"].as_str().unwrap();
        if !matches!(method, "job.result" | "job.evidence") {
            continue;
        }
        replayed += 1;
        let actual = semantic(reader.handle(method, exchange["params"].as_object().unwrap()));
        let expected = recorded_semantic(&exchange["answer"]);
        if actual != expected {
            differences.push(format!(
                "{}:\n  swift {expected}\n  rust  {actual}",
                exchange["name"]
            ));
        }
    }
    assert_eq!(replayed, 8);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// Swift's cancelled-before-run Job: the transitions its cancellation
/// journaled, by from, to and reason, and the failure it recorded.
fn swift_cancellation() -> (Vec<(String, String, String)>, Value, Value) {
    let store = fixture("job-cancel-analyzer/store/jobs/job-96d4f821b85e0645362763736ffa1906");
    let transitions = fs::read_to_string(store.join("journal.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|event| event["kind"] == "stateTransition")
        .skip(1)
        .map(|event| transition(&event))
        .collect();
    let record = document(store.join("job-record.json"));
    (
        transitions,
        record["operationFailure"].clone(),
        record["sessionPublicationRecord"].clone(),
    )
}

fn transition(event: &Value) -> (String, String, String) {
    let payload = &event["payload"];
    (
        payload["from"].as_str().unwrap().into(),
        payload["to"].as_str().unwrap().into(),
        payload["reason"].as_str().unwrap().into(),
    )
}

#[test]
fn a_queued_job_is_cancelled_before_it_runs_as_swift_cancels_one() {
    let root = Root::new().with_target();
    let targets = TargetStore::open(&root.0.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.jobs_state()).unwrap();
    let sessions =
        SessionStore::open(&root.0.join("session-owner"), &root.0.join("Sessions")).unwrap();
    let provenance = document(fixture("observe-device/provenance.json"));
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &NoDispatch,
        receive_root: None,
        tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
        now: fixed_now,
        code_sign_helper: None,
    };
    let cases = document(fixture("observe-device/cases.json"));
    let submitted = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &root.0,
            hdc: Some(&hdc),
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    }
    .handle(cases["exchanges"][1]["params"].as_object().unwrap())
    .unwrap();
    let id = submitted["jobId"].as_str().unwrap().to_owned();
    assert_eq!(submitted, cases["exchanges"][1]["answer"]["result"]);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &SystemStorageProbe,
    };
    let canceller = JobCanceller {
        jobs: &jobs,
        now: fixed_now,
        sessions: Some(&publisher),
    };
    let params = Map::from_iter([("jobId".into(), json!(id))]);
    assert_eq!(
        canceller.handle(&params).unwrap(),
        json!({"cancelRequested": true})
    );
    let (transitions, failure, publication) = swift_cancellation();
    let journaled: Vec<_> = root
        .journal(&id)
        .iter()
        .filter(|event| event["kind"] == "stateTransition")
        .skip(1)
        .map(transition)
        .collect();
    assert_eq!(journaled, transitions);
    let record = jobs.read_snapshot(&id).unwrap();
    assert_eq!(record.state, "cancelled");
    let value = record.value().unwrap();
    assert_eq!(value["operationFailure"], failure);
    // Its Session is published as Swift published its cancelled Job's: the
    // catalog reached, a confirmed cancelled proposal, the same record
    // fields (the seals and roots are this host's).
    let published = &value["sessionPublicationRecord"];
    let keys = |record: &Value| {
        record
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>()
    };
    assert_eq!(keys(published), keys(&publication), "{published}");
    assert_eq!(published["phase"], publication["phase"], "{published}");
    for field in ["terminalStatus", "outcomeCertainty", "completedAtUTC"] {
        assert_eq!(
            published["proposal"][field], publication["proposal"][field],
            "{published}"
        );
    }
    // A second request changes nothing, and a run meets a terminal Job.
    assert_eq!(
        canceller.handle(&params).unwrap(),
        json!({"cancelRequested": true})
    );
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: 8 << 30,
        home: "",
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: Some(&publisher),
        cancellation: None,
        after_commit: None,
        hdc: Some(&hdc),
        workspace: None,
    };
    let refused = runner.handle(&params).unwrap_err();
    assert_eq!(refused.code, "resourceConflict", "{}", refused.message);
    assert_eq!(
        refused.details,
        Map::from_iter([
            ("phase".into(), json!("preAdmission")),
            ("newDispatchCount".into(), json!(0)),
            ("jobId".into(), json!(id)),
        ])
    );
}

#[test]
fn without_an_hdc_composition_a_queued_device_job_is_not_run() {
    let root = Root::new().with_target();
    let targets = TargetStore::open(&root.0.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.jobs_state()).unwrap();
    let provenance = document(fixture("observe-device/provenance.json"));
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &NoDispatch,
        receive_root: None,
        tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
        now: fixed_now,
        code_sign_helper: None,
    };
    let cases = document(fixture("observe-device/cases.json"));
    let id = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &root.0,
            hdc: Some(&hdc),
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    }
    .handle(cases["exchanges"][1]["params"].as_object().unwrap())
    .unwrap()["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let before = root.journal(&id);
    // The Windows daemon's runner: no HDC composition.
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: 8 << 30,
        home: "",
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: None,
        cancellation: None,
        after_commit: None,
        hdc: None,
        workspace: None,
    };
    let refused = runner
        .handle(&Map::from_iter([("jobId".into(), json!(id))]))
        .unwrap_err();
    assert_eq!(
        (refused.code, refused.message.as_str()),
        (
            "rejected",
            format!("job {id} runs observe.device@1, which the Rust Runtime does not execute yet")
                .as_str()
        )
    );
    assert_eq!(
        refused.details,
        Map::from_iter([
            ("phase".into(), json!("preAdmission")),
            ("newDispatchCount".into(), json!(0)),
        ])
    );
    assert_eq!(root.journal(&id), before);
    assert_eq!(jobs.read_snapshot(&id).unwrap().state, "preflight");
}
