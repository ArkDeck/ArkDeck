//! Replays the Swift Session publication oracle
//! (`rust/tests/fixtures/job-publication-analyzer`, produced by
//! `JobRunAnalyzerOracleContractTests.testSwiftPublishesTheSharedAnalyzerSessions`)
//! against the Rust runner composed with the publication writer, as the
//! standalone Swift daemon is: the same sources and admissions, then every run
//! in order over one store, a Sessions root and a storage owner, with a probe
//! that reports the volume full where the oracle's did. Every answer, every
//! read and everything the runs leave (the Job index and files, every Artifact,
//! every file of the Sessions root and the storage owner, and every entry's
//! kind and mode) must be Swift's byte for byte, once each Job record's
//! volume, device, inode and claim generation are read as labels. The runs
//! spawn children, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    AnalyzerProfile, ArtifactReadStore, JobAdmitter, JobPlanner, JobRunner, JobStore,
    SessionPublisher, SessionStore, StorageClaims,
};
use serde_json::{Map, Value, json};
use std::fs;
use support::{OracleProbe, chmod, exclusive, fixed_now, fixed_precise_now};

const SOURCES: [&str; 2] = ["job-oracle-source", "job-oracle-source-removed"];

#[test]
fn rust_publishes_the_swift_sessions() {
    let _lock = exclusive();
    let fixture = support::fixture("job-publication-analyzer");
    let cases = support::document(&fixture, "cases.json");
    let cases = cases.as_array().unwrap();
    let provenance = support::document(&fixture, "provenance.json");
    let root = support::rebuild(&fixture, &SOURCES, cases);
    let artifact_store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let mut profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    profile.timeout_seconds = provenance["timeoutSeconds"].as_i64().unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    for case in cases {
        let accepted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifact_store),
                analyzer: Some(&profile),
                state_root: &root,
                hdc: None,
                workspace: None,
            },
            jobs: &jobs,
            now: fixed_now,
            authority: None,
        }
        .handle(case["submit"].as_object().unwrap())
        .unwrap();
        assert_eq!(
            accepted["jobId"], case["params"]["jobId"],
            "{}",
            case["name"]
        );
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
        workspace: None,
    };
    let mut differences = Vec::new();
    for case in cases {
        let job = case["params"]["jobId"].as_str().unwrap();
        if let Some(removed) = case["removesSourcePayload"].as_str() {
            fs::remove_file(root.join("artifacts").join(removed)).unwrap();
        }
        if case["presetsSession"] == true {
            // Something else already holds this Job's Session path.
            let mut path = root.join("Sessions");
            for part in ["2026", "09", &format!("session-{job}")] {
                path.push(part);
                if !path.exists() {
                    fs::create_dir(&path).unwrap();
                    chmod(&path, 0o700);
                }
            }
        }
        probe.exhaust(case["exhaustsStorage"] == true);
        let actual = match runner.handle(case["params"].as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => json!({"ok": false, "error": {"code": refusal.code,
                "message": refusal.message, "details": Value::Object(refusal.details)}}),
        };
        probe.exhaust(false);
        if actual != case["response"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                case["name"], case["response"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    // How the Rust reader then reads each Job's status and details.
    let reads = support::document(&fixture, "reads.json");
    for (job, answers) in reads.as_object().unwrap() {
        for (method, recorded) in answers.as_object().unwrap() {
            let actual = match jobs
                .handle_resource(method, &Map::from_iter([("jobId".into(), json!(job))]))
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => json!({"ok": false, "error": {"code": error.code,
                    "message": error.message}}),
            };
            assert_eq!(&actual, recorded, "{job} {method}");
        }
    }
    drop(jobs);
    support::assert_leftovers(&fixture, &root);
    fs::remove_dir_all(&root).unwrap();
}
