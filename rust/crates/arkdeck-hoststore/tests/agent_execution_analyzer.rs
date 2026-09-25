//! Replays the Swift host-only agent execution oracle
//! (`rust/tests/fixtures/agent-execution-analyzer`, produced by
//! `AgentExecutionAnalyzerOracleContractTests`) against the Rust agent
//! execution owner, Job owner and Artifact owner: `agent.run` of
//! `analyzer.extract-crash-signature@1` over a crash listing collected from
//! the adopted Target, its owned Job started in the background as the daemon
//! starts it, held by the oracle analyzer until the replay releases it; then
//! the completed execution read with `agent.status`, the intent sent again,
//! and the Job's result, evidence and Artifacts read. The owned Job binds no
//! device, so its Artifacts and evidence carry no binding revision and no
//! stable identity, as Swift answers. The Job state an accepted run reads
//! while its Job starts is compared by name and must not be terminal.
//! Everything else must be Swift's: every answer, the Target document, and
//! everything the execution, the Job and the Session leave, byte for byte.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, AgentStart, AnalyzerProfile, ArtifactReadStore, JobAdmitter,
    JobPlanner, JobResultReader, JobRunner, JobStore, SessionPublisher, SessionStore,
    StorageClaims, TargetStore,
};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{OracleProbe, chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the oracle analyzer names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";
const TERMINAL: [&str; 6] = [
    "planned",
    "succeeded",
    "recovered",
    "failed",
    "cancelled",
    "interrupted",
];

/// Serializes every user of the fixed root, Swift producers included.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The root as the Swift oracle had it before its first request: the fake
/// and the oracle analyzer, the adopted Target's document, and the collected
/// crash listing.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("artifacts/job-oracle-source"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
        root.join("agent-executions"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    for (name, mode) in [("hdc", 0o700), ("analyzer", 0o700)] {
        fs::copy(fixture.join(name), root.join(name)).unwrap();
        chmod(&root.join(name), mode);
    }
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    chmod(&root.join("targets-state/targets.json"), 0o600);
    for file in fs::read_dir(fixture.join("artifacts/job-oracle-source")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let destination = root.join("artifacts/job-oracle-source").join(name);
        fs::copy(&file, &destination).unwrap();
        chmod(
            &destination,
            if name == "index.json" { 0o600 } else { 0o400 },
        );
    }
    root
}

fn answer(outcome: Result<Value, arkdeck_contract::WireError>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut body = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                body["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": body})
        }
    }
}

/// The answer as the oracle labels it: a pager's revision by name, and,
/// where the oracle labels it, the Job state an accepted run read while its
/// Job started, which must not be terminal.
fn labelled(actual: &Value, recorded: &Value) -> Value {
    let mut actual = actual.clone();
    let Some(result) = actual.get_mut("result").and_then(Value::as_object_mut) else {
        return actual;
    };
    if result.get("snapshotRevision").is_some_and(Value::is_string) {
        result.insert("snapshotRevision".into(), json!("<snapshotRevision>"));
    }
    if recorded["result"]["jobState"] == "<jobState>" {
        let state = result["jobState"].as_str().unwrap_or_default().to_owned();
        assert!(!TERMINAL.contains(&state.as_str()), "{state} is terminal");
        result.insert("jobState".into(), json!("<jobState>"));
        if let Some(job) = result.get_mut("job").and_then(Value::as_object_mut) {
            job.insert("state".into(), json!("<jobState>"));
            job.insert("outcome".into(), json!("<jobState>"));
        }
    }
    actual
}

#[test]
fn rust_completes_the_swift_host_only_agent_execution() {
    let _lock = exclusive();
    let fixture = support::fixture("agent-execution-analyzer");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);

    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: Some(&profile),
            state_root: &root,
            hdc: None,
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    let engine = AgentEngine {
        targets: &targets,
        jobs: &jobs,
        admitter: &admitter,
        observations: None,
        now: fixed_precise_now,
    };
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let quota = provenance["quotaBytes"].as_u64().unwrap();
    let home = provenance["home"].as_str().unwrap();
    // The daemon's background run of an owned Job and its report to the
    // execution (`start_agent_run`), with the analyzer the admission used.
    let run = |start: &AgentStart| {
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &probe,
        };
        let _ = JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: Some(&profile),
            quota,
            home,
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: None,
            workspace: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(start.job))]));
        agents.finish(start, &jobs);
    };

    let mut differences = Vec::new();
    std::thread::scope(|scope| {
        let mut running = Vec::new();
        for exchange in cases["exchanges"].as_array().unwrap() {
            let name = exchange["name"].as_str().unwrap();
            let method = exchange["method"].as_str().unwrap();
            let params = exchange["params"].as_object().unwrap().clone();
            if exchange["mode"] == "held" {
                let _ = fs::remove_file(root.join("released"));
            }
            if exchange["before"] == "release" {
                fs::write(root.join("released"), b"").unwrap();
                for handle in running.drain(..) {
                    let handle: std::thread::ScopedJoinHandle<'_, ()> = handle;
                    handle.join().unwrap();
                }
            }
            let actual = match method {
                "agent.run" | "agent.status" => match agents.advance(method, &params, &engine) {
                    Ok(advanced) => {
                        if let Some(start) = advanced.start {
                            let run = &run;
                            running.push(scope.spawn(move || run(&start)));
                        }
                        answer(AgentExecutionStore::project(advanced.value, &jobs, &reader))
                    }
                    Err(error) => answer(Err(error)),
                },
                "job.result" | "job.evidence" => answer(reader.handle(method, &params)),
                "artifact.list" => answer(artifacts.handle_list(
                    &params,
                    &jobs.snapshot_directory(),
                    |job| jobs.read_snapshot(job).map(|_| ()),
                )),
                other => panic!("{name}: the oracle sent {other}"),
            };
            let recorded = &exchange["answer"];
            let actual = labelled(&actual, recorded);
            if actual != *recorded {
                differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
            }
        }
        for handle in running {
            handle.join().unwrap();
        }
    });
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(fs::read(root.join("hdc-invocations.log")).unwrap(), b"");
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    drop(jobs);
    support::assert_leftovers(&fixture, &root);
    fs::remove_dir_all(&root).unwrap();
}
