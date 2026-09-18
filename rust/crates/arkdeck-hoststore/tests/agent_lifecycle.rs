//! Replays the Swift agent lifecycle oracle (`rust/tests/fixtures/agent-lifecycle`,
//! produced by `AgentLifecycleOracleContractTests`) against the Rust agent
//! execution owner and Job owner over the shared fake HDC: three executions as
//! `agent run` leaves them, then their list page by page and by filter, the
//! list requests the owner and its pager refuse, their abandonment and its
//! refusals, and last the abandoned execution read, run again and listed, each
//! request as the isolated daemon answers `agent.run`, `agent.status`,
//! `agent.list` and `agent.abandon`. The observed run holds its Job's first
//! call (`mode` held), and `before` release lets the call go and waits for the
//! Job's end, which the execution records. A page's revision and next cursor
//! are compared by name, and a request naming `<nextCursor of X>` sends the
//! cursor exchange X's page minted; the page it answers must be of that
//! snapshot.
//!
//! Everything else must be Swift's: every answer's code, details and result
//! (a refusal's message is Swift's own wording, reported), each call the fake
//! received, the Target document, and everything the executions and the Job
//! leave, byte for byte, the six page snapshots by their existence and mode.
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

#[test]
fn rust_lists_and_abandons_the_swift_agent_executions() {
    let _lock = exclusive();
    let fixture = support::fixture("agent-lifecycle");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());

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
        tool_sha256: &digest,
        now: fixed_now,
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
        },
        jobs: &jobs,
        now: fixed_now,
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
            tool_sha256: &digest,
            now: fixed_now,
        };
        let _ = JobRunner {
            imports: None,
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
        }
        .handle(&Map::from_iter([("jobId".into(), json!(start.job))]));
        agents.finish(start, &jobs);
    };

    let (mut answers, mut differences, mut wording) =
        (BTreeMap::<String, Value>::new(), Vec::new(), Vec::new());
    std::thread::scope(|scope| {
        let mut running = Vec::new();
        for exchange in cases["exchanges"].as_array().unwrap() {
            let name = exchange["name"].as_str().unwrap();
            let method = exchange["method"].as_str().unwrap();
            let mut params = exchange["params"].as_object().unwrap().clone();
            if let Some(mode) = exchange["mode"].as_str() {
                fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
                if mode == "held" {
                    let _ = fs::remove_file(root.join("released"));
                }
            }
            match exchange["before"].as_str() {
                None => (),
                Some("release") => {
                    fs::write(root.join("released"), b"").unwrap();
                    let execution = params["executionId"].as_str().unwrap();
                    let index = running
                        .iter()
                        .position(|(start, _): &(AgentStart, _)| start.execution == execution)
                        .unwrap();
                    let (_, handle): (AgentStart, std::thread::ScopedJoinHandle<'_, ()>) =
                        running.remove(index);
                    handle.join().unwrap();
                }
                Some(other) => panic!("{name}: the oracle waits for {other}"),
            }
            let minted = params
                .get("cursor")
                .and_then(Value::as_str)
                .and_then(|cursor| cursor.strip_prefix("<nextCursor of "))
                .and_then(|cursor| cursor.strip_suffix('>'))
                .map(str::to_owned);
            if let Some(source) = &minted {
                params.insert(
                    "cursor".into(),
                    answers[source]["result"]["nextCursor"].clone(),
                );
            }
            let actual = match method {
                "agent.run" | "agent.status" | "agent.list" | "agent.abandon" => {
                    match agents.advance(method, &params, &engine) {
                        Ok(answer) => {
                            if let Some(start) = answer.start {
                                let background = start.clone();
                                let run = &run;
                                running.push((start, scope.spawn(move || run(&background))));
                            }
                            // The daemon projects the owned Job over a run's
                            // and a status read's answer only.
                            let answer = if matches!(method, "agent.run" | "agent.status") {
                                AgentExecutionStore::project(answer.value, &jobs, &reader)
                            } else {
                                Ok(answer.value)
                            };
                            match answer {
                                Ok(result) => json!({"ok": true, "result": result}),
                                Err(error) => refused(&error.code, error.message, error.details),
                            }
                        }
                        Err(error) => refused(&error.code, error.message, error.details),
                    }
                }
                other => panic!("{name}: the oracle sent {other}"),
            };
            if let Some(source) = &minted
                && actual["ok"] == true
            {
                assert_eq!(
                    actual["result"]["snapshotRevision"],
                    answers[source]["result"]["snapshotRevision"],
                    "{name}: a cursor's page is of the snapshot that minted it"
                );
            }
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
        fs::read(root.join("hdc-invocations.log")).unwrap(),
        fs::read(fixture.join("hdc-invocations.log")).unwrap(),
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
