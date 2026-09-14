//! Replays the Swift running-cancellation oracle
//! (`rust/tests/fixtures/job-cancel-running-analyzer`, produced by
//! `JobRunAnalyzerOracleContractTests.testSwiftCancelsRunningAnalyzerJobs`)
//! against the Rust runner and its cancellation, composed with the
//! publication writer as the standalone Swift daemon is: a Job cancelled once
//! its analyzer intent is durable and its `hold` child runs, released only
//! once its run has answered; one whose request waited for its run at the
//! last boundary before the intent; and one cancelled after its success
//! commit. Every answer, every read and everything the runs leave must be
//! Swift's byte for byte, once each Job record's volume, device, inode and
//! claim generation are read as labels. The runs spawn children, so this
//! binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobResultReader, JobRunner,
    JobStore, RunCancellation, SessionPublisher, SessionStore, StorageClaims, cancel_running,
};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use support::{OracleProbe, exclusive, fixed_now, fixed_precise_now};

/// What every case's run shares: the owners and the analyzer, as the
/// standalone daemon composes them.
struct Composition<'a> {
    jobs: &'a JobStore,
    artifacts: &'a ArtifactReadStore,
    profile: &'a AnalyzerProfile,
    publisher: &'a SessionPublisher<'a>,
    quota: u64,
    home: &'a str,
}

impl Composition<'_> {
    /// One case's runner: its own cancellation and, where the case needs
    /// one, the success commit's hook.
    fn runner<'b>(
        &'b self,
        cancellation: &'b RunCancellation,
        after_commit: Option<&'b (dyn Fn(&str) + Sync)>,
    ) -> JobRunner<'b> {
        JobRunner {
            jobs: self.jobs,
            artifacts: self.artifacts,
            analyzer: Some(self.profile),
            quota: self.quota,
            home: self.home,
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(self.publisher),
            cancellation: Some(cancellation),
            after_commit,
            hdc: None,
        }
    }
}

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

/// A run's answer as the control layer frames it.
fn run_answer(runner: &JobRunner<'_>, params: &Map<String, Value>) -> Value {
    answer(runner.handle(params).map_err(|refusal| WireError {
        code: refusal.code.into(),
        message: refusal.message,
        details: Some(refusal.details),
    }))
}

/// A cancellation's answer once the run has answered it.
fn cancel_answer(cancellation: &RunCancellation) -> Value {
    answer(Ok(
        cancel_running(cancellation).expect("the run answered the request")
    ))
}

/// Waits, as the oracle does, until the Job's analyzer intent is durable, so
/// its child is the thing the cancellation stops.
fn wait_for_intent(jobs_state: &Path, job: &str) {
    let journal = jobs_state.join("jobs").join(job).join("journal.jsonl");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !fs::read_to_string(&journal).is_ok_and(|text| text.contains("\"kind\":\"stepIntent\"")) {
        assert!(Instant::now() < deadline, "{job} never recorded its intent");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Waits until the canceller's request is the run's to act on.
fn wait_for_request(cancellation: &RunCancellation) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !cancellation.pending() {
        assert!(
            Instant::now() < deadline,
            "the request never reached the run"
        );
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn rust_cancels_the_swift_running_jobs() {
    let _lock = exclusive();
    let fixture = support::fixture("job-cancel-running-analyzer");
    let provenance = support::document(&fixture, "provenance.json");
    let root = support::rebuild(&fixture, &["job-oracle-source"], &[]);
    let artifact_store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    profile.timeout_seconds = provenance["timeoutSeconds"].as_i64().unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let cases = support::document(&fixture, "cases.json");
    let cases = cases.as_array().unwrap();
    for case in cases {
        let accepted = JobAdmitter {
            planner: JobPlanner {
                artifacts: Some(&artifact_store),
                analyzer: Some(&profile),
                state_root: &root,
                hdc: None,
            },
            jobs: &jobs,
            now: fixed_now,
        }
        .handle(case["submit"].as_object().unwrap())
        .unwrap();
        assert_eq!(accepted["jobId"], case["jobId"], "{}", case["name"]);
    }
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let composition = Composition {
        jobs: &jobs,
        artifacts: &artifact_store,
        profile: &profile,
        publisher: &publisher,
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
    };
    let mut differences = Vec::new();
    for case in cases {
        let job = case["jobId"].as_str().unwrap();
        let params = Map::from_iter([("jobId".into(), json!(job))]);
        let cancellation = RunCancellation::default();
        let (run, cancel) = match case["cancelWhen"].as_str().unwrap() {
            // The request already waits when the run reaches its last
            // boundary before the intent.
            "beforeDispatchInstall" => std::thread::scope(|scope| {
                let canceller = scope.spawn(|| cancel_answer(&cancellation));
                wait_for_request(&cancellation);
                let run = run_answer(&composition.runner(&cancellation, None), &params);
                cancellation.end();
                (run, canceller.join().unwrap())
            }),
            // The request reaches the run while its `hold` child runs, which
            // answers only once released. As the oracle does, the replay
            // releases it only once the run has answered, so no stall here
            // lets the child finish before the cancellation.
            "childRunning" => std::thread::scope(|scope| {
                let running =
                    scope.spawn(|| run_answer(&composition.runner(&cancellation, None), &params));
                wait_for_intent(&root.join("jobs-state"), job);
                let cancel = cancel_answer(&cancellation);
                let run = running.join().unwrap();
                cancellation.end();
                fs::write(root.join("release"), b"").unwrap();
                (run, cancel)
            }),
            // The request is made from the success commit's hook, once the
            // child has finished and its answer is verified.
            "afterCommitLinearization" => {
                let committed = Mutex::new(None);
                let hook: &(dyn Fn(&str) + Sync) = &|id: &str| {
                    if id == job {
                        *committed.lock().unwrap() = Some(cancel_answer(&cancellation));
                    }
                };
                let run = run_answer(&composition.runner(&cancellation, Some(hook)), &params);
                cancellation.end();
                let cancel = committed.lock().unwrap().take().expect("the hook ran");
                (run, cancel)
            }
            other => panic!("unknown cancellation point {other}"),
        };
        for (what, actual) in [("run", run), ("cancel", cancel)] {
            if actual != case[what] {
                differences.push(format!(
                    "{} {what}:\n  swift {}\n  rust  {actual}",
                    case["name"], case[what]
                ));
            }
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
