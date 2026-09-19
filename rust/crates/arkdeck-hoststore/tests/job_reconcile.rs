//! Replays the Swift restart and reconcile oracle
//! (`rust/tests/fixtures/job-reconcile-analyzer`, produced by
//! `JobRunAnalyzerOracleContractTests.testSwiftRecoversAndReconcilesTheParkedAnalyzerJobs`)
//! against the Rust runner, recovery and reconciler composed with the
//! publication writer, as the standalone Swift daemon is: the same sources
//! and admissions; two Jobs parked by a signal death (the second's source
//! payload then removed), one run to success and one only admitted; the store
//! they leave; two daemon starts over it; then every `job.reconcile` request
//! in order over one store, every read, and everything left. Every answer and
//! every snapshot must be Swift's byte for byte, once each Job record's
//! volume, device, inode and claim generation are read as labels. The runs
//! spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobReconciler, JobResultReader,
    JobRunner, JobStore, SessionPublisher, SessionStore, StorageClaims, recover_active_jobs,
};
use serde_json::{Map, Value, json};
use std::fs;
use support::{OracleProbe, assert_store, exclusive, fixed_now, fixed_precise_now};

/// A control answer as the oracle records it: a refusal carries details only
/// when it has any.
fn answer(outcome: Result<Value, WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    }
}

/// The removed source payload as the rebuilt root needs it: the oracle's
/// `removed.json` path, and the mode of the Job whose source it was.
fn removed_sources(jobs: &[Value], removed: &[Value]) -> Vec<Value> {
    removed
        .iter()
        .map(|path| {
            let path = path.as_str().unwrap();
            let lease = format!("lease-v1:{}", path.replacen('/', ":", 1));
            let job = jobs
                .iter()
                .find(|job| {
                    let request: Value =
                        serde_json::from_str(job["submit"]["requestJson"].as_str().unwrap())
                            .unwrap();
                    request["inputs"]["sourceArtifactRef"] == lease.as_str()
                })
                .unwrap();
            json!({"removesSourcePayload": path, "mode": job["mode"]})
        })
        .collect()
}

#[test]
fn rust_recovers_and_reconciles_the_swift_jobs() {
    let _lock = exclusive();
    let fixture = support::fixture("job-reconcile-analyzer");
    let provenance = support::document(&fixture, "provenance.json");
    let jobs_document = support::document(&fixture, "jobs.json");
    let recorded_jobs = jobs_document.as_array().unwrap();
    let removed = support::document(&fixture, "removed.json");
    let removed = removed.as_array().unwrap();
    let root = support::rebuild(
        &fixture,
        &["job-oracle-source", "job-oracle-source-removed"],
        &removed_sources(recorded_jobs, removed),
    );
    let artifact_store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    profile.timeout_seconds = provenance["timeoutSeconds"].as_i64().unwrap();
    let probe = OracleProbe::new(&provenance);
    let state = root.join("jobs-state");

    // The first daemon: every admission, then the runs.
    {
        let jobs = JobStore::open_owner(&state).unwrap();
        let sessions =
            SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
        for job in recorded_jobs {
            let accepted = JobAdmitter {
                planner: JobPlanner {
                    imports: None,
                    artifacts: Some(&artifact_store),
                    analyzer: Some(&profile),
                    state_root: &root,
                    hdc: None,
                },
                jobs: &jobs,
                now: fixed_now,
                authority: None,
            }
            .handle(job["submit"].as_object().unwrap())
            .unwrap();
            assert_eq!(accepted["jobId"], job["jobId"], "{}", job["name"]);
        }
        let claims = StorageClaims::default();
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &probe,
        };
        let runner = JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &artifact_store,
            analyzer: Some(&profile),
            quota: provenance["quotaBytes"].as_u64().unwrap(),
            home: provenance["home"].as_str().unwrap(),
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: None,
        };
        let runs = support::document(&fixture, "runs.json");
        let mut ran = runs.as_array().unwrap().iter();
        for job in recorded_jobs.iter().filter(|job| job["runs"] == true) {
            let params = Map::from_iter([("jobId".into(), job["jobId"].clone())]);
            let actual = answer(runner.handle(&params).map_err(|refusal| WireError {
                code: refusal.code.into(),
                message: refusal.message,
                details: Some(refusal.details),
            }));
            let recorded = ran.next().unwrap();
            assert_eq!(recorded["name"], job["name"]);
            assert_eq!(actual, recorded["response"], "{}", job["name"]);
        }
        assert!(ran.next().is_none());
        // The parked Job's source payload goes once its run has parked it.
        for path in removed {
            fs::remove_file(root.join("artifacts").join(path.as_str().unwrap())).unwrap();
        }
        assert_store(&fixture, "before", &state);
    }

    // The daemon starts again over the same root, and then once more; the
    // last start serves every request that follows.
    let starts = support::document(&fixture, "starts.json");
    let mut jobs = None;
    for start in starts.as_array().unwrap() {
        drop(jobs.take());
        let reopened = JobStore::open_owner(&state).unwrap();
        let recovered = recover_active_jobs(&reopened, None, fixed_now).unwrap();
        assert!(recovered.quarantined.is_empty() && recovered.refused.is_empty());
        assert_eq!(
            json!(recovered.statuses),
            start["recovered"],
            "{}",
            start["name"]
        );
        assert_store(&fixture, start["name"].as_str().unwrap(), &state);
        jobs = Some(reopened);
    }
    let jobs = jobs.unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let reconciler = JobReconciler {
        jobs: &jobs,
        artifacts: &artifact_store,
        imports: None,
        now: fixed_now,
        sessions: Some(&publisher),
        hdc: None,
        capabilities: None,
    };
    let mut differences = Vec::new();
    for case in support::document(&fixture, "cases.json")
        .as_array()
        .unwrap()
    {
        let name = case["name"].as_str().unwrap();
        let actual = answer(reconciler.handle(case["params"].as_object().unwrap()));
        if actual != case["response"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                case["response"]
            ));
        }
        assert_store(&fixture, &format!("steps/{name}"), &state);
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));

    // How the Rust readers then read each Job, its result and its evidence:
    // the Job whose reconcile failed is read as it stands in memory.
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifact_store,
    };
    let reads = support::document(&fixture, "reads.json");
    for (job, answers) in reads.as_object().unwrap() {
        for (method, recorded) in answers.as_object().unwrap() {
            let params = Map::from_iter([("jobId".into(), json!(job))]);
            let actual = answer(
                if matches!(method.as_str(), "job.result" | "job.evidence") {
                    reader.handle(method, &params)
                } else {
                    jobs.handle_resource(method, &params)
                },
            );
            assert_eq!(&actual, recorded, "{job} {method}");
        }
    }
    drop(jobs);
    drop(sessions);
    support::assert_leftovers(&fixture, &root);
    fs::remove_dir_all(&root).unwrap();
}
