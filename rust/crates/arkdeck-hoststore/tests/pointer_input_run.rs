//! Actual Swift pointer-input oracle replay through production Rust admission,
//! mutation consumption, WAL, Provider verification and durable outcome owners.
//! All transport bytes come from the shared fake HDC; never hardware acceptance.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobResultReader, JobRunner,
    JobStore, SessionPublisher, SessionStore, StorageClaims, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::cell::Cell;
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
        root.join("store"),
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

#[derive(Clone, Copy, PartialEq)]
enum Fault {
    None,
    NoOwner,
    StaleTool,
    PersistAfterConsume,
    CrashAfterConsume,
    CrashAfterIntent,
    Concurrent,
    CancelBeforeConsume,
    CancelAfterConsume,
}

thread_local! { static FAIL_PERSIST: Cell<bool> = const { Cell::new(false) }; static CRASH_CONSUME: Cell<bool> = const { Cell::new(false) }; }
thread_local! { static CANCEL_AFTER: std::cell::RefCell<Option<std::sync::Arc<arkdeck_hoststore::RunCancellation>>> = const { std::cell::RefCell::new(None) }; }
fn request_cancel(signal: &std::sync::Arc<arkdeck_hoststore::RunCancellation>) {
    let other = signal.clone();
    std::thread::spawn(move || {
        other.request();
    });
    while !signal.pending() {
        std::thread::yield_now();
    }
}
fn fault_clock() -> Option<String> {
    CANCEL_AFTER.with(|slot| {
        if slot.borrow().is_some()
            && fs::read_to_string(
                Path::new(ROOT).join("store/capabilities/runtime-capabilities.ledger"),
            )
            .unwrap_or_default()
            .contains("\"consumption\"")
        {
            request_cancel(&slot.borrow_mut().take().unwrap());
        }
    });
    if FAIL_PERSIST.get() || CRASH_CONSUME.get() {
        let ledger = fs::read_to_string(
            Path::new(ROOT).join("store/capabilities/runtime-capabilities.ledger"),
        )
        .unwrap_or_default();
        if ledger.contains("\"consumption\"") {
            if CRASH_CONSUME.get() {
                std::process::exit(73);
            }
            FAIL_PERSIST.set(false);
            chmod(
                &Path::new(ROOT).join("store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc"),
                0o500,
            );
        }
    }
    fixed_now()
}
struct CheckedDispatch {
    inner: ProcessDispatch,
    stale: bool,
    cancel: Option<std::sync::Arc<arkdeck_hoststore::RunCancellation>>,
    crash_intent: bool,
    gate: Option<std::sync::Arc<std::sync::Barrier>>,
    gated: std::sync::atomic::AtomicBool,
}
impl HdcDispatch for CheckedDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        if self.crash_intent && plan.arguments.iter().any(|a| a == "uinput") {
            std::process::exit(74);
        }
        if plan.arguments.iter().any(|a| a == "uinput")
            && let Some(gate) = &self.gate
            && !self.gated.swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            gate.wait();
            gate.wait();
        }
        self.inner.dispatch(plan)
    }
    fn mutation_identity_current(&self) -> bool {
        if let Some(cancel) = &self.cancel
            && !cancel.pending()
        {
            request_cancel(cancel);
        }
        !self.stale && self.inner.mutation_identity_current()
    }
}

#[test]
fn rust_executes_the_swift_pointer_oracle_without_replaying_unknown() {
    replay(Fault::None);
}
#[test]
fn unavailable_mutation_owner_never_consumes_or_dispatches_pointer() {
    replay(Fault::NoOwner);
}
#[test]
fn changed_tool_identity_never_consumes_or_dispatches_pointer() {
    replay(Fault::StaleTool);
}
#[test]
fn consumed_capability_with_unwritable_job_stays_pending_and_blocks_next_job() {
    replay(Fault::PersistAfterConsume);
}

fn replay(fault: Fault) {
    let _lock = (std::env::var_os("ARKDECK_POINTER_CRASH_CHILD").is_none()).then(exclusive);
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("store")).unwrap();
    let capabilities =
        arkdeck_hoststore::CapabilityStore::open(&root.join("store/capabilities")).unwrap();
    let holds = arkdeck_hoststore::DeviceHolds::default();
    let default_root = root.join("store");
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let cancellation = std::sync::Arc::new(arkdeck_hoststore::RunCancellation::default());
    let dispatch = CheckedDispatch {
        inner: ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None),
        stale: fault == Fault::StaleTool,
        cancel: (fault == Fault::CancelBeforeConsume).then(|| cancellation.clone()),
        crash_intent: fault == Fault::CrashAfterIntent,
        gate: (fault == Fault::Concurrent).then(|| std::sync::Arc::new(std::sync::Barrier::new(2))),
        gated: std::sync::atomic::AtomicBool::new(false),
    };
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
    };
    let authority = arkdeck_hoststore::MutationAuthority {
        capabilities: &capabilities,
        holds: &holds,
        default_root: &default_root,
        sessions: Some(&sessions),
    };
    let runner = JobRunner {
        imports: None,
        mutation: (fault != Fault::NoOwner).then_some(arkdeck_hoststore::MutationExecution {
            authority,
            state_root: &root,
        }),
        jobs: &jobs,
        artifacts: &artifacts,
        analyzer: None,
        quota: provenance["quotaBytes"].as_u64().unwrap(),
        home: provenance["home"].as_str().unwrap(),
        now: fault_clock,
        precise_now: fixed_precise_now,
        sessions: Some(&publisher),
        cancellation: Some(&cancellation),
        after_commit: None,
        hdc: Some(&hdc),
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
                authority: Some(authority),
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
                if fault == Fault::Concurrent {
                    let next = cases["exchanges"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|e| e["name"] == "longPress.submit")
                        .unwrap()["params"]
                        .as_object()
                        .unwrap();
                    let second = JobAdmitter {
                        planner: planner(),
                        jobs: &jobs,
                        now: fixed_now,
                        authority: Some(authority),
                    }
                    .handle(next)
                    .unwrap();
                    let jobs_ref = &jobs;
                    let artifacts_ref = &artifacts;
                    let targets_ref = &targets;
                    let digest_ref = &digest;
                    let dispatch_ref = &dispatch;
                    let root_ref = &root;
                    std::thread::scope(|scope| {
                        let first = scope.spawn(move || {
                            let thread_hdc = HdcComposition {
                                targets: targets_ref,
                                dispatch: dispatch_ref,
                                receive_root: None,
                                tool_sha256: digest_ref,
                                now: fixed_now,
                                code_sign_helper: None,
                            };
                            JobRunner {
                                imports: None,
                                mutation: Some(arkdeck_hoststore::MutationExecution {
                                    authority,
                                    state_root: root_ref,
                                }),
                                jobs: jobs_ref,
                                artifacts: artifacts_ref,
                                analyzer: None,
                                quota: 128 * 1024 * 1024,
                                home: "/private/tmp",
                                now: fixed_now,
                                precise_now: fixed_precise_now,
                                sessions: None,
                                cancellation: None,
                                after_commit: None,
                                hdc: Some(&thread_hdc),
                            }
                            .handle(params)
                        });
                        dispatch.gate.as_ref().unwrap().wait();
                        let second_result = runner
                            .handle(&Map::from_iter([("jobId".into(), second["jobId"].clone())]));
                        dispatch.gate.as_ref().unwrap().wait();
                        let first_result = first.join().unwrap().unwrap();
                        assert_eq!(first_result["state"], "succeeded");
                        assert_eq!(second_result.unwrap()["state"], "failed");
                    });
                    let calls = fs::read_to_string(root.join("hdc-invocations.log")).unwrap();
                    assert_eq!(
                        calls.lines().filter(|line| line.contains("uinput")).count(),
                        1,
                        "{calls}"
                    );
                    return;
                }
                FAIL_PERSIST.set(fault == Fault::PersistAfterConsume);
                CRASH_CONSUME.set(fault == Fault::CrashAfterConsume);
                CANCEL_AFTER.with(|slot| {
                    *slot.borrow_mut() =
                        (fault == Fault::CancelAfterConsume).then(|| cancellation.clone())
                });
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
                match artifacts.handle_list(params, &jobs.snapshot_directory(), |job| {
                    jobs.read_snapshot(job).map(|_| ())
                }) {
                    // The pager's revision is its own; the oracle labels it.
                    Ok(mut result) => {
                        result["snapshotRevision"] = json!("<snapshotRevision>");
                        json!({"ok": true, "result": result})
                    }
                    Err(error) => refused(&error.code, error.message, error.details),
                }
            }
            "capability.list" | "capability.inspect" => match capabilities.handle(method, params) {
                Ok(result) => json!({"ok":true,"result":result}),
                Err(error) => refused(error.code, error.message, None),
            },
            other => panic!("{name}: the oracle sent {other}"),
        };
        if fault != Fault::None && name == "tap.run" {
            FAIL_PERSIST.set(false);
            chmod(
                &root.join("store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc"),
                0o700,
            );
            let invocations = fs::read_to_string(root.join("hdc-invocations.log")).unwrap();
            assert!(!invocations.contains("uinput"), "{invocations}");
            let journal = fs::read_to_string(
                root.join("store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc/journal.jsonl"),
            )
            .unwrap();
            assert!(
                !journal.contains("intent-inject-pointer-input"),
                "{journal}"
            );
            let ledger =
                fs::read_to_string(root.join("store/capabilities/runtime-capabilities.ledger"))
                    .unwrap_or_default();
            if fault == Fault::PersistAfterConsume {
                assert_eq!(actual["ok"], false, "{actual}");
                assert!(ledger.contains("\"consumption\""), "{ledger}");
                assert!(!ledger.contains("\"outcome\""), "{ledger}");
                let retry = runner.handle(params);
                assert!(retry.is_err(), "running Job must never replay");
                let next = cases["exchanges"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|e| e["name"] == "longPress.submit")
                    .unwrap()["params"]
                    .as_object()
                    .unwrap()
                    .clone();

                let refusal = JobAdmitter {
                    planner: planner(),
                    jobs: &jobs,
                    now: fixed_now,
                    authority: Some(authority),
                }
                .handle(&next)
                .unwrap_err();
                assert_eq!(refusal.code, "admissionDenied");
            } else {
                let cancelled = matches!(
                    fault,
                    Fault::CancelBeforeConsume | Fault::CancelAfterConsume
                );
                assert_eq!(
                    actual["result"]["state"],
                    if cancelled { "cancelled" } else { "failed" },
                    "{actual}"
                );
                assert_eq!(
                    ledger.contains("\"consumption\""),
                    fault == Fault::CancelAfterConsume,
                    "{ledger}"
                );
            }
            if fault == Fault::CancelAfterConsume {
                let outcomes: Vec<Value> = ledger
                    .lines()
                    .map(|line| serde_json::from_str::<Value>(line).unwrap())
                    .filter(|row| row["kind"] == "outcome")
                    .collect();
                assert_eq!(outcomes.len(), 1);
                assert_eq!(outcomes[0]["outcome"]["outcome"], "confirmed");
                assert_eq!(outcomes[0]["outcome"]["terminalState"], "cancelled");
            }
            assert_eq!(
                invocations,
                fs::read_to_string(root.join("hdc-invocations.log")).unwrap()
            );
            if fault == Fault::PersistAfterConsume {
                drop(jobs);
                let reopened = JobStore::open_owner(&default_root).unwrap();
                let reopened_runner = JobRunner {
                    imports: None,
                    mutation: Some(arkdeck_hoststore::MutationExecution {
                        authority,
                        state_root: &root,
                    }),
                    jobs: &reopened,
                    artifacts: &artifacts,
                    analyzer: None,
                    quota: provenance["quotaBytes"].as_u64().unwrap(),
                    home: provenance["home"].as_str().unwrap(),
                    now: fixed_now,
                    precise_now: fixed_precise_now,
                    sessions: None,
                    cancellation: None,
                    after_commit: None,
                    hdc: Some(&hdc),
                };
                assert!(reopened_runner.handle(params).is_err());
                assert_eq!(
                    invocations,
                    fs::read_to_string(root.join("hdc-invocations.log")).unwrap()
                );
                assert_eq!(
                    ledger,
                    fs::read_to_string(root.join("store/capabilities/runtime-capabilities.ledger"))
                        .unwrap()
                );
            }
            return;
        }
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
    drop(jobs);
    support::assert_leftovers_at(&fixture, &root, &default_root);
}

#[test]
fn pointer_crash_child() {
    let Ok(mode) = std::env::var("ARKDECK_POINTER_CRASH_CHILD") else {
        return;
    };
    replay(if mode == "consume" {
        Fault::CrashAfterConsume
    } else {
        Fault::CrashAfterIntent
    });
    panic!("crash point was not reached");
}

#[test]
fn restart_after_consumption_or_intent_never_replays_and_blocks_new_gesture() {
    let _lock = exclusive();
    for (mode, code) in [("consume", 73), ("intent", 74)] {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "pointer_crash_child", "--nocapture"])
            .env("ARKDECK_POINTER_CRASH_CHILD", mode)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(code),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
        let root = PathBuf::from(ROOT);
        let calls = fs::read(root.join("hdc-invocations.log")).unwrap();
        let ledger = fs::read(root.join("store/capabilities/runtime-capabilities.ledger")).unwrap();
        let record: Value = serde_json::from_slice(
            &fs::read(root.join("store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc/job-record.json"))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            record["admissionEvidence"]["kind"] == "runtimeCapability",
            mode == "intent"
        );
        let journal = fs::read_to_string(
            root.join("store/jobs/job-4ac2c3640786ad0e831952ab62bb71bc/journal.jsonl"),
        )
        .unwrap();
        assert_eq!(
            journal.contains("intent-inject-pointer-input"),
            mode == "intent"
        );
        assert!(!journal.contains("outcome-inject-pointer-input"));
        let jobs = JobStore::open_owner(&root.join("store")).unwrap();
        let capabilities =
            arkdeck_hoststore::CapabilityStore::open(&root.join("store/capabilities")).unwrap();
        let holds = arkdeck_hoststore::DeviceHolds::default();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
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
        let default_root = root.join("store");
        let authority = arkdeck_hoststore::MutationAuthority {
            default_root: &default_root,
            sessions: None,
            capabilities: &capabilities,
            holds: &holds,
        };
        let runner = JobRunner {
            imports: None,
            mutation: Some(arkdeck_hoststore::MutationExecution {
                authority,
                state_root: &root,
            }),
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota: u64::MAX,
            home: "/private/tmp",
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
        };
        assert!(
            runner
                .handle(&Map::from_iter([(
                    "jobId".into(),
                    json!("job-4ac2c3640786ad0e831952ab62bb71bc")
                )]))
                .is_err()
        );
        let cases = support::document(&support::fixture("pointer-input"), "cases.json");
        let next = cases["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["name"] == "longPress.submit")
            .unwrap()["params"]
            .as_object()
            .unwrap();
        let refusal = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: &root,
                hdc: Some(&hdc),
            },
            jobs: &jobs,
            now: fixed_now,
            authority: Some(authority),
        }
        .handle(next)
        .unwrap_err();
        assert_eq!(refusal.code, "admissionDenied");
        assert_eq!(calls, fs::read(root.join("hdc-invocations.log")).unwrap());
        assert_eq!(
            ledger,
            fs::read(root.join("store/capabilities/runtime-capabilities.ledger")).unwrap()
        );
    }
}

#[test]
fn concurrent_gestures_cannot_bypass_another_capability_pending_use() {
    replay(Fault::Concurrent);
}

#[test]
fn cancellation_before_consumption_leaves_no_use_or_pointer_intent() {
    replay(Fault::CancelBeforeConsume);
}
#[test]
fn cancellation_after_consumption_settles_without_pointer_intent() {
    replay(Fault::CancelAfterConsume);
}
