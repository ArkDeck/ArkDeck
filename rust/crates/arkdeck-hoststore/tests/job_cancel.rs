//! Replays the Swift cancellation oracle
//! (`rust/tests/fixtures/job-cancel-analyzer`, produced by
//! `JobRunAnalyzerOracleContractTests.testSwiftCancelsTheSharedAnalyzerJobs`)
//! against the Rust canceller and runner composed with the publication
//! writer, as the standalone Swift daemon is: the same sources and
//! admissions, then every request in order over one store — a Job cancelled
//! before it runs, cancelled again and then run, Jobs cancelled once they
//! succeeded, failed or parked, and the refusals of an absent Job and of
//! parameters without a string Job identity. Every answer, every read and
//! everything the requests leave must be Swift's byte for byte, once each Job
//! record's volume, device, inode and claim generation are read as labels.
//! The runs spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobCanceller, JobPlanner, JobResultReader,
    JobRunner, JobStore, SessionPublisher, SessionStore, StorageClaims,
};
use serde_json::{Map, Value, json};
use std::fs;
use support::{OracleProbe, exclusive, fixed_now, fixed_precise_now};

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

#[test]
fn rust_cancels_the_swift_jobs() {
    let _lock = exclusive();
    let fixture = support::fixture("job-cancel-analyzer");
    let provenance = support::document(&fixture, "provenance.json");
    let root = support::rebuild(&fixture, &["job-oracle-source"], &[]);
    let artifact_store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    profile.timeout_seconds = provenance["timeoutSeconds"].as_i64().unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    for job in support::document(&fixture, "jobs.json").as_array().unwrap() {
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
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let runner = JobRunner {
        imports: None,
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
    let canceller = JobCanceller {
        jobs: &jobs,
        now: fixed_now,
        sessions: Some(&publisher),
    };
    let mut differences = Vec::new();
    for case in support::document(&fixture, "cases.json")
        .as_array()
        .unwrap()
    {
        let params = case["params"].as_object().unwrap();
        let actual = answer(match case["method"].as_str().unwrap() {
            "job.cancel" => canceller.handle(params),
            _ => runner.handle(params).map_err(|refusal| WireError {
                code: refusal.code.into(),
                message: refusal.message,
                details: Some(refusal.details),
            }),
        });
        if actual != case["response"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                case["name"], case["response"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    // How the Rust readers then read each Job, its result and its evidence.
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
    support::assert_leftovers(&fixture, &root);
    fs::remove_dir_all(&root).unwrap();
}
