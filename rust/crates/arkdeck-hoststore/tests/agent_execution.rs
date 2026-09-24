//! Replays the Swift agent execution oracle (`rust/tests/fixtures/agent-execution`,
//! produced by `AgentExecutionOracleContractTests`) against the Rust agent
//! execution owner, Job owner and Artifact owner over the shared fake HDC: the
//! adopted Target as Swift wrote it, then every recorded request in order, as
//! the isolated daemon answers `agent.run`, `agent.status`, `artifact.list`,
//! `job.result` and `job.evidence`. A Job an execution comes to own starts in
//! the background, as the daemon starts it. An exchange's `mode` and `before`
//! are the oracle's: a held run removes the fake's release, `heldCall` waits
//! for the held Job's first call, and `release` lets the call go and waits
//! for the Job's end, which the execution records. What the oracle labels is
//! compared by name: a pager's cursors and revision, and the Job state an
//! accepted run reads while its Job starts, which must be one before the
//! held call. A request naming a cursor names the exchange whose page
//! minted it.
//!
//! Both runs are replayed, the observation and the capture. Everything must
//! be Swift's: every answer's code, details and result (a refusal's message
//! is Swift's own wording, reported), each call the fake received, the Target
//! document, and everything the executions and Jobs leave, byte for byte.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, AgentStart, ArtifactReadStore, HdcComposition, JobAdmitter,
    JobPlanner, JobResultReader, JobRunner, JobStore, SessionPublisher, SessionStore,
    StorageClaims, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use support::{OracleProbe, chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
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

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote and the agent execution owner's directory.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
        root.join("agent-executions"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    chmod(&root.join("targets-state/targets.json"), 0o600);
    root
}

fn invocations(root: &Path) -> Vec<u8> {
    fs::read(root.join("hdc-invocations.log")).unwrap()
}

fn refused(code: &str, message: String, details: Option<Map<String, Value>>) -> Value {
    let mut error = json!({"code": code, "message": message});
    if let Some(details) = details {
        error["details"] = Value::Object(details);
    }
    json!({"ok": false, "error": error})
}

/// The answer without a refusal's message, which is Swift's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

/// The answer as the oracle labels it: a pager's revision and next cursor
/// by name, and, where the oracle labels it, the Job state an accepted run
/// read while its Job started, which must not be terminal.
fn labelled(actual: &Value, recorded: &Value) -> Value {
    let mut actual = actual.clone();
    let Some(result) = actual.get_mut("result").and_then(Value::as_object_mut) else {
        return actual;
    };
    for (key, label) in [
        ("snapshotRevision", "<snapshotRevision>"),
        ("nextCursor", "<nextCursor>"),
    ] {
        if result.get(key).is_some_and(Value::is_string) {
            result.insert(key.into(), json!(label));
        }
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

fn wait_for(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "the held Job never called the fake"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn rust_runs_the_swift_agent_executions() {
    let _lock = exclusive();
    let fixture = support::fixture("agent-execution");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let exchanges = cases["exchanges"].as_array().unwrap();

    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &dispatch,
        receive_root: None,
        tool_sha256: &digest,
        now: fixed_now,
        code_sign_helper: None,
    };
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &root,
            hdc: Some(&hdc),
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
    // execution (`start_agent_run`).
    let run = |start: &AgentStart| {
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &probe,
        };
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &dispatch,
            receive_root: None,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let _ = JobRunner {
            imports: None,
            mutation: None,
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota,
            home,
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        }
        .handle(&Map::from_iter([("jobId".into(), json!(start.job))]));
        agents.finish(start, &jobs);
    };

    let (mut answers, mut differences, mut wording) = (BTreeMap::new(), Vec::new(), Vec::new());
    std::thread::scope(|scope| {
        let mut running = Vec::new();
        let mut held_from = 0;
        for exchange in exchanges {
            let name = exchange["name"].as_str().unwrap();
            let method = exchange["method"].as_str().unwrap();
            let mut params = exchange["params"].as_object().unwrap().clone();
            if let Some(mode) = exchange["mode"].as_str() {
                fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
                if mode == "held" {
                    let _ = fs::remove_file(root.join("released"));
                    held_from = invocations(&root).len();
                }
            }
            match exchange["before"].as_str() {
                Some("heldCall") => wait_for(|| invocations(&root).len() > held_from),
                Some("release") => {
                    fs::write(root.join("released"), b"").unwrap();
                    let execution = params["executionId"].as_str().unwrap();
                    if let Some(index) = running
                        .iter()
                        .position(|(start, _): &(AgentStart, _)| start.execution == execution)
                    {
                        let (_, handle): (AgentStart, std::thread::ScopedJoinHandle<'_, ()>) =
                            running.remove(index);
                        handle.join().unwrap();
                    }
                }
                _ => (),
            }
            if let Some(source) = params
                .get("cursor")
                .and_then(Value::as_str)
                .and_then(|cursor| cursor.strip_prefix("<nextCursor of "))
                .and_then(|cursor| cursor.strip_suffix('>'))
            {
                let minted: &Value = &answers[source];
                params.insert("cursor".into(), minted["result"]["nextCursor"].clone());
            }
            let actual = match method {
                "agent.run" | "agent.status" => match agents.advance(method, &params, &engine) {
                    Ok(answer) => {
                        if let Some(start) = answer.start {
                            let background = start.clone();
                            let run = &run;
                            running.push((start, scope.spawn(move || run(&background))));
                        }
                        match AgentExecutionStore::project(answer.value, &jobs, &reader) {
                            Ok(result) => json!({"ok": true, "result": result}),
                            Err(error) => refused(&error.code, error.message, error.details),
                        }
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                },
                "artifact.list" => {
                    match artifacts.handle_list(&params, &jobs.snapshot_directory(), |job| {
                        jobs.read_snapshot(job).map(|_| ())
                    }) {
                        Ok(result) => json!({"ok": true, "result": result}),
                        Err(error) => refused(&error.code, error.message, error.details),
                    }
                }
                "job.result" | "job.evidence" => match reader.handle(method, &params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => refused(&error.code, error.message, error.details),
                },
                other => panic!("{name}: the oracle sent {other}"),
            };
            answers.insert(name.to_owned(), actual.clone());
            let recorded = &exchange["answer"];
            let actual = labelled(&actual, recorded);
            if semantic(&actual) != semantic(recorded) {
                differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
            } else if actual != *recorded {
                wording.push(format!(
                    "{name}: swift {:?}, rust {:?}",
                    recorded["error"]["message"], actual["error"]["message"]
                ));
            }
        }
        for (_, handle) in running {
            handle.join().unwrap();
        }
    });
    for note in &wording {
        eprintln!("refusal wording (T2): {note}");
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(
        String::from_utf8(invocations(&root)).unwrap(),
        String::from_utf8(fs::read(fixture.join("hdc-invocations.log")).unwrap()).unwrap(),
        "the fake's calls"
    );
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    drop(jobs);
    support::assert_leftovers(&fixture, &root);
}
