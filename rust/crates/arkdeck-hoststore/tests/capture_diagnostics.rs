//! Replays the Swift `capture.diagnostics@1` oracles against the Rust
//! planner, admitter, runner and result reader over the shared fake HDC,
//! dispatched as the daemon dispatches it: the adopted Target as Swift wrote
//! it, then every recorded request in order, each run while the fake answers
//! in the mode the oracle names.
//!
//! - `capture-diagnostics` (`CaptureDiagnosticsOracleContractTests`): the
//!   runbook's default request — a capture that succeeds, one the device's
//!   free space refuses, one on another device, and one whose HiLog drain
//!   comes back empty and parks.
//! - `capture-diagnostics-read-legs`
//!   (`CaptureDiagnosticsReadLegsOracleContractTests`): the legs that only
//!   read the device — the component detail dump, the Faultlogger index and
//!   one entry of it, the application liveness readback with its derived
//!   document, the host's marks and a ring-buffered request's coverage record
//!   — succeeding, failing a leg the Job survives (not text, no such entry, a
//!   ledger past the read's bound), failing the Job at publication (past the
//!   request's own byte budget) and parking it on an outcome nothing can
//!   observe (an entry without its header, a read that outlives its budget, a
//!   read whose process dies on a signal); and five requests refused before
//!   admission. This composition names no host receive root: none of these
//!   legs lands a file.
//! - `capture-diagnostics-file-legs`
//!   (`CaptureDiagnosticsFileLegsOracleContractTests`): the component tree and
//!   the screenshot, each written to a provider-owned path, read back,
//!   received under the oracle's host receive root and removed, under the
//!   durable mutation authority the screen-sequence replay runs under — a
//!   capability the Runtime issues by its default policy, consumed after the
//!   storage preflight and before the first write, a screenshot-only request
//!   scoped to the control session and carrying the session's model and
//!   firmware readback; a zero-byte tree, a still that is not the PNG it
//!   claims, an empty landing and a refused cleanup (which owes a cleanup
//!   debt) each losing a leg the Job survives; a capture readback, a receive
//!   and a cleanup whose outcomes nothing can observe, each parking its Job
//!   and blocking its device's automatic capability lineage, which refuses
//!   the next request for it; the cleanup debts and the capability store.
//!
//! Every answer's code, details and result must be Swift's; a refusal's
//! message is Swift's own wording and is reported, not compared (T2). Each
//! call the fake received and everything the Jobs leave (the Job index and
//! files, every Artifact and missing product, every file of the Sessions root
//! and the storage owner, every entry's kind and mode) must be Swift's byte
//! for byte, once each Job record's volume, device, inode and claim
//! generation are read as labels, as is the revision of an `artifact.list`
//! page. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobResultReader, JobRunner, JobStore, MutationAuthority, MutationExecution, SessionPublisher,
    SessionStore, StorageClaims, TargetStore, list_cleanup_debt,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::ProcessDispatch;
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{OracleProbe, chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

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
/// Swift oracle's adoption wrote.
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
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
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

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

/// The answer without a refusal's message, which is Swift's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

/// A plan request for the adopted Target with these inputs.
fn plan_request(key: &str, inputs: Value) -> Map<String, Value> {
    let request = json!({
        "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
        "requestId": format!("req-{key}"), "idempotencyKey": key,
        "operation": {"id": "capture.diagnostics", "version": 1},
        "target": {"targetId": "TGT-3ba3f5f43b92", "expectedBindingRevision": 1},
        "inputs": inputs,
    });
    Map::from_iter([("requestJson".into(), json!(request.to_string()))])
}

/// A plan's answer as the planner gives it: the plan, or the refusal's code
/// and message.
type Plan<'a> = &'a dyn Fn(&str, Value) -> Result<Value, (&'static str, String)>;

/// Replays the oracle `name` over the owners a daemon composes (without a
/// host receive root), then hands `after` the planner over the same owners,
/// then compares everything the replay left with what Swift left.
fn replay(name: &str, after: impl FnOnce(Plan<'_>)) {
    let _lock = exclusive();
    let fixture = support::fixture(name);
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
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
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let planner = || JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
        workspace: None,
    };
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: Some(&publisher),
        cancellation: None,
        after_commit: None,
        hdc: Some(&hdc),
        workspace: None,
    };
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let (mut differences, mut wording) = (Vec::new(), Vec::new());
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match planner().handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(proven())),
            },
            "job.submit" => match (JobAdmitter {
                planner: planner(),
                jobs: &jobs,
                now: fixed_now,
                authority: None,
            })
            .handle(params)
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    refusal.message,
                    Some(if refusal.proven { proven() } else { Map::new() }),
                ),
            },
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
                }
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
                }
            }
            "job.result" | "job.evidence" => match reader.handle(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(&error.code, error.message, error.details),
            },
            "artifact.list" => {
                match artifacts.handle_list(params, |job| jobs.read_snapshot(job).map(|_| ())) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            other => panic!("{name}: the oracle sent {other}"),
        };
        let actual = support::legacy_plan_answer(actual);
        let recorded = &exchange["answer"];
        if semantic(&actual) != semantic(recorded) {
            differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
        } else if actual != *recorded {
            wording.push(format!(
                "{name}: swift {:?}, rust {:?}",
                recorded["error"]["message"], actual["error"]["message"]
            ));
        }
    }
    for note in &wording {
        eprintln!("refusal wording (T2): {note}");
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(
        String::from_utf8(fs::read(root.join("hdc-invocations.log")).unwrap()).unwrap(),
        String::from_utf8(fs::read(fixture.join("hdc-invocations.log")).unwrap()).unwrap(),
        "the fake's calls"
    );
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    let plan = |key: &str, inputs: Value| {
        planner()
            .handle(&plan_request(key, inputs))
            .map_err(|refusal| (refusal.code, refusal.message))
    };
    after(&plan);
    drop(jobs);
    support::assert_leftovers(&fixture, &root);
}

#[test]
fn rust_captures_diagnostics_of_the_swift_fake_device() {
    replay("capture-diagnostics", |plan| {
        // A file leg lands a file on the host, so a composition without a
        // host receive root plans none of them, and a HiLog filter Swift's
        // request refuses is refused as Swift refuses it; nothing is planned,
        // admitted or dispatched.
        for (key, inputs, code, message) in [
            (
                "idem-capture-screenshot",
                json!({"durationSeconds": 5, "uiScreenshot": true}),
                "rejected",
                "capture.diagnostics@1 is not materialized by the Rust Runtime without a host \
                 receive root",
            ),
            (
                "idem-capture-filter",
                json!({"durationSeconds": 5, "hilogFilters": ["tag;rm"]}),
                "invalidInput",
                "typed plan preflight failed before authorization: malformed(field: \"filters\", \
                 detail: \"filter tokens are bounded ASCII, no shell fragments\")",
            ),
        ] {
            assert_eq!(plan(key, inputs), Err((code, message.into())));
        }
        // The capture legs Swift's default selects are what a plan without
        // them runs: the HiLog drain is skippable, and its absence is a
        // recorded one.
        let planned = plan(
            "idem-capture-no-hilog",
            json!({"durationSeconds": 5, "captureHilog": false}),
        )
        .unwrap();
        let steps: Vec<&str> = planned["steps"]
            .as_array()
            .unwrap()
            .iter()
            .map(|step| step["stepId"].as_str().unwrap())
            .collect();
        assert!(!steps.contains(&"capture-hilog") && steps.contains(&"capture-ui-dump"));
    });
}

#[test]
fn rust_captures_the_read_legs_of_the_swift_fake_device() {
    replay("capture-diagnostics-read-legs", |_| {});
}

/// Replays the oracle `name` under the durable mutation authority: the Job
/// owner's root the account-fixed one its authority names, each Job's one
/// capability use consumed before its first write, and received files
/// landing under the oracle's host receive root. Every answer must be
/// Swift's, its message included, and so must each call the fake received
/// (in order, or, where the oracle's calls ran concurrently, each exchange's
/// sorted), the Target document, the cleanup debts and everything the replay
/// leaves below the root, the landings the failed receives left included.
fn replay_under_mutation_authority(name: &str) {
    let _lock = exclusive();
    let fixture = support::fixture(name);
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let default_root = root.join("store");
    fs::create_dir(&default_root).unwrap();
    chmod(&default_root, 0o700);
    // The resources the oracle's answers read beside them.
    if fixture.join("resources").is_dir() {
        fs::create_dir(root.join("resources")).unwrap();
        chmod(&root.join("resources"), 0o700);
        for resource in fs::read_dir(fixture.join("resources")).unwrap() {
            let resource = resource.unwrap().path();
            fs::copy(
                &resource,
                root.join("resources").join(resource.file_name().unwrap()),
            )
            .unwrap();
        }
    }
    let concurrent = fixture.join("hdc-calls.log").is_file();
    let receive_root = PathBuf::from(provenance["receiveRoot"].as_str().unwrap());
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&default_root).unwrap();
    let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &dispatch,
        receive_root: Some(&receive_root),
        tool_sha256: &digest,
        now: fixed_now,
        code_sign_helper: None,
    };
    let holds = DeviceHolds::default();
    let authority = || MutationAuthority {
        default_root: &default_root,
        sessions: Some(&sessions),
        capabilities: &capabilities,
        holds: &holds,
    };
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let planner = || JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
        workspace: None,
    };
    let runner = JobRunner {
        imports: None,
        mutation: Some(MutationExecution {
            authority: authority(),
            state_root: &root,
        }),
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
        now: fixed_now,
        precise_now: fixed_precise_now,
        sessions: Some(&publisher),
        cancellation: None,
        after_commit: None,
        hdc: Some(&hdc),
        workspace: None,
    };
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    let (mut differences, mut calls, mut seen) = (Vec::new(), Vec::new(), 0);
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match planner().handle(params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(proven())),
            },
            "job.submit" => match (JobAdmitter {
                planner: planner(),
                jobs: &jobs,
                now: fixed_now,
                authority: Some(authority()),
            })
            .handle(params)
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    refusal.message,
                    Some(if refusal.proven { proven() } else { Map::new() }),
                ),
            },
            "job.run" => {
                if let Some(mode) = exchange["mode"].as_str() {
                    fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
                }
                // What the oracle's fake keeps of an earlier Job's calls.
                let _ = fs::remove_file(root.join("tag-list-read"));
                match runner.handle(params) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
                }
            }
            "job.result" | "job.evidence" | "job.show" => {
                let answer = if method == "job.show" {
                    jobs.handle_resource(method, params)
                } else {
                    reader.handle(method, params)
                };
                match answer {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            "artifact.list" => {
                match artifacts.handle_list(params, |job| jobs.read_snapshot(job).map(|_| ())) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            "capability.list" | "capability.inspect" => match capabilities.handle(method, params) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => refused(error.code, error.message, None),
            },
            "cleanupDebt.list" => match list_cleanup_debt(&artifacts) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(message) => refused("internalError", message, None),
            },
            other => panic!("{name}: the oracle sent {other}"),
        };
        let actual = support::legacy_plan_answer(actual);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
        if concurrent {
            let log = fs::read_to_string(root.join("hdc-calls.log")).unwrap_or_default();
            let lines: Vec<&str> = log.lines().collect();
            let mut exchange_calls: Vec<&str> = lines[seen..].to_vec();
            exchange_calls.sort_unstable();
            calls.extend(exchange_calls.into_iter().map(|line| format!("{line}\n")));
            seen = lines.len();
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    if concurrent {
        assert_eq!(
            calls.concat(),
            fs::read_to_string(fixture.join("hdc-calls.log")).unwrap(),
            "each exchange's calls"
        );
    } else {
        assert_eq!(
            String::from_utf8(fs::read(root.join("hdc-invocations.log")).unwrap()).unwrap(),
            String::from_utf8(fs::read(fixture.join("hdc-invocations.log")).unwrap()).unwrap(),
            "the fake's calls"
        );
    }
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap(),
        "the Target document"
    );
    drop(jobs);
    support::assert_leftovers_at(&fixture, &root, &default_root);
}

/// `capture-diagnostics-file-legs`: the component tree and the screenshot.
#[test]
fn rust_captures_the_file_legs_of_the_swift_fake_device() {
    replay_under_mutation_authority("capture-diagnostics-file-legs");
}

/// `capture-diagnostics-trace` (`CaptureDiagnosticsTraceOracleContractTests`):
/// the Trace legs, blocking and ring-buffered, bracketed by the Trace
/// Runtime probe's two snapshots — a ring whose readback holds its anchor and
/// one whose does not (with a parameter it cannot read), every leg of the
/// operation in one Job, a zero-byte trace, a refused cleanup's debt, a tag
/// the device does not offer, a first and a second snapshot that cannot be
/// taken, and a trace the readback cannot find parking its Job on a second
/// device; two requests refused before admission; each ring's record read
/// through `job.show`.
#[test]
fn rust_captures_the_trace_legs_of_the_swift_fake_device() {
    replay_under_mutation_authority("capture-diagnostics-trace");
}
