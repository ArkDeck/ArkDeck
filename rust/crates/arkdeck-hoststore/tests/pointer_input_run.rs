//! Actual Swift pointer-input oracle replay through production Rust admission,
//! mutation consumption, WAL, Provider verification and durable outcome owners.
//! All transport bytes come from the shared fake HDC; never hardware acceptance.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobResultReader, JobRunner,
    JobStore, PublicationPoint, SessionPublisher, SessionStore, StorageClaims, StorageProbe,
    StorageSnapshot, TargetStore,
};
use arkdeck_platform::{HostDirectory, VerifiedTool};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::cell::Cell;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, mpsc};
use std::time::Duration;
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
}
impl HdcDispatch for CheckedDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        if self.crash_intent && plan.arguments.iter().any(|a| a == "uinput") {
            std::process::exit(74);
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
/// A use consumed while the Job's record cannot be written stays pending and
/// blocks the next gesture; a second run resumes the Job under that one use.
#[test]
fn consumed_capability_with_unwritable_job_stays_pending_until_its_run_resumes() {
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
        workspace: None,
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
                // While its use is pending the lineage refuses every other
                // gesture on the binding.
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
                // A second run resumes the Job from `running`, as Swift's
                // `runOwned` does: its journal holds no intent, so the gesture
                // is sent for the first time, under the one use its
                // reservation already holds (the store answers that receipt
                // again); nothing is consumed twice.
                let resumed = runner.handle(params).unwrap();
                assert_eq!(resumed["state"], "succeeded", "{resumed}");
                let calls = fs::read_to_string(root.join("hdc-invocations.log")).unwrap();
                assert_eq!(
                    calls.lines().filter(|line| line.contains("uinput")).count(),
                    1,
                    "{calls}"
                );
                let settled =
                    fs::read_to_string(root.join("store/capabilities/runtime-capabilities.ledger"))
                        .unwrap();
                let rows: Vec<Value> = settled
                    .lines()
                    .map(|line| serde_json::from_str::<Value>(line).unwrap())
                    .collect();
                assert_eq!(
                    rows.iter().filter(|row| row["kind"] == "consumed").count(),
                    1,
                    "{settled}"
                );
                let outcomes: Vec<&Value> =
                    rows.iter().filter(|row| row["kind"] == "outcome").collect();
                assert_eq!(outcomes.len(), 1, "{settled}");
                assert_eq!(outcomes[0]["outcome"]["outcome"], "confirmed");
                // A terminal Job is never run again, in this owner or another.
                assert!(runner.handle(params).is_err());
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
                    workspace: None,
                };
                assert!(reopened_runner.handle(params).is_err());
                assert_eq!(
                    calls,
                    fs::read_to_string(root.join("hdc-invocations.log")).unwrap()
                );
                assert_eq!(
                    settled,
                    fs::read_to_string(root.join("store/capabilities/runtime-capabilities.ledger"))
                        .unwrap()
                );
                return;
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

/// Where a tap's publication is stopped.
#[derive(Clone, Copy, PartialEq)]
enum StopPoint {
    /// The staged Session's Journal ends at the injection intent: its outcome
    /// is not copied and there is no Manifest. The storage lock is not held.
    Injection,
    /// The staged Session is complete, and the storage lock is held to rename
    /// it to its published name.
    Moving,
    /// The staged Session is complete and not yet renamed: the process dies.
    Crash,
}

/// The oracle's probe, which also stops a publication at `at` until it is told
/// to go on.
struct StopAt {
    oracle: OracleProbe,
    sessions: PathBuf,
    at: StopPoint,
    stopped: Mutex<Option<mpsc::Sender<usize>>>,
    resume: Mutex<mpsc::Receiver<()>>,
}

/// The one Session a publication has staged under `sessions`.
fn staged(sessions: &Path) -> PathBuf {
    let entries: Vec<PathBuf> = fs::read_dir(sessions.join(".staging"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(entries.len(), 1, "{entries:?}");
    entries.into_iter().next().unwrap()
}

impl StorageProbe for StopAt {
    fn snapshot(&self, root: &HostDirectory) -> std::io::Result<StorageSnapshot> {
        self.oracle.snapshot(root)
    }
    fn reached(&self, point: PublicationPoint) {
        let copied = match (self.at, point) {
            (StopPoint::Injection, PublicationPoint::JournalCopied { copied, .. }) => {
                let journal =
                    fs::read_to_string(staged(&self.sessions).join("journal.jsonl")).unwrap();
                let last: Value = serde_json::from_str(journal.lines().last().unwrap()).unwrap();
                if last["eventId"] != "intent-inject-pointer-input" {
                    return;
                }
                copied
            }
            (StopPoint::Moving, PublicationPoint::Moving) => 0,
            (StopPoint::Crash, PublicationPoint::ManifestPublished) => std::process::exit(75),
            _ => return,
        };
        if let Some(stopped) = self.stopped.lock().unwrap().take() {
            stopped.send(copied).unwrap();
            // Told to go on, or the test ended: a failed assertion drops the
            // sender, so the publication never outlives it.
            let _ = self.resume.lock().unwrap().recv();
        }
    }
}

/// A gesture submitted while the previous one's Session is being published
/// (TASK-XPA-014). The publication writes the Session aside, in the Sessions
/// root's `.staging`, which no continuity scan reads, and holds the storage
/// lock only to rename it, whole, to its published name and register it. An
/// admission reads the storage status under that lock, as Swift's does, and
/// scans the Session root without it.
///
/// Stopped while the staged Journal ends at the injection intent, the long
/// press is admitted at once, as Swift admitted it: the lock is not held, and
/// its scan passes the half-written Session over. Stopped with the lock held
/// to rename, a scan answers at once and the Session is not at its name; the
/// long press waits for its status read until the publication goes on.
/// Either way the tap ends as Swift's did and its Session is published whole.
/// No sleeps: each bound only lets an early answer arrive or a stop be
/// reached.
fn tap_publication(at: StopPoint) {
    // A crash child runs under its parent's hold of the fixed root.
    let _lock = (at != StopPoint::Crash).then(exclusive);
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let exchanges = cases["exchanges"].as_array().unwrap();
    let exchange = |name: &str| {
        exchanges
            .iter()
            .find(|exchange| exchange["name"] == name)
            .unwrap()
    };
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("store")).unwrap();
    let capabilities =
        arkdeck_hoststore::CapabilityStore::open(&root.join("store/capabilities")).unwrap();
    let holds = arkdeck_hoststore::DeviceHolds::default();
    let default_root = root.join("store");
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
    let session = root.join("Sessions/2026/09/session-job-4ac2c3640786ad0e831952ab62bb71bc");
    let (stopped, stops) = mpsc::channel();
    let (resume, resumed) = mpsc::channel();
    let probe = StopAt {
        oracle: OracleProbe::new(&provenance),
        sessions: root.join("Sessions"),
        at,
        stopped: Mutex::new(Some(stopped)),
        resume: Mutex::new(resumed),
    };
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let authority = arkdeck_hoststore::MutationAuthority {
        capabilities: &capabilities,
        holds: &holds,
        default_root: &default_root,
        sessions: Some(&sessions),
    };
    let admit = |name: &str| {
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
            authority: Some(authority),
        };
        match admitter.handle(exchange(name)["params"].as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(refusal) => refused(
                refusal.code,
                refusal.message,
                Some(if refusal.proven { proven() } else { Map::new() }),
            ),
        }
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
    let recorded = |name: &str| semantic(&exchange(name)["answer"]);
    assert_eq!(semantic(&admit("tap.submit")), recorded("tap.submit"));
    fs::write(root.join("hdc-mode"), "normal\n").unwrap();
    if at == StopPoint::Crash {
        let _ = runner.handle(exchange("tap.run")["params"].as_object().unwrap());
        panic!("the tap's publication never reached its staged Manifest");
    }
    std::thread::scope(|scope| {
        // Owned here, so that a failed assertion lets the publication go on.
        let resume = resume;
        let tap = scope.spawn(|| {
            match runner.handle(exchange("tap.run")["params"].as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(refusal.code, refusal.message, Some(refusal.details)),
            }
        });
        let copied = stops
            .recv_timeout(Duration::from_secs(120))
            .expect("the tap's publication reaches its stop");
        let staged = staged(&root.join("Sessions"));
        assert!(!session.exists(), "published before its rename");
        let long_press = match at {
            StopPoint::Injection => {
                let journal = fs::read_to_string(staged.join("journal.jsonl")).unwrap();
                assert_eq!(journal.lines().count(), copied);
                assert!(!staged.join("manifest.json").exists());
                // Admitted at once, over the half-written Session.
                let long_press = admit("longPress.submit");
                assert_eq!(semantic(&long_press), recorded("longPress.submit"));
                jobs.require_mutation_state(&default_root, &[root.join("Sessions")])
                    .unwrap();
                resume.send(()).unwrap();
                long_press
            }
            StopPoint::Crash => unreachable!("the crash returns before the scope"),
            StopPoint::Moving => {
                assert!(staged.join("manifest.json").exists());
                // The continuity scan takes no storage lock: it answers while
                // the lock is held to rename, and cannot meet the Session,
                // which is not at its name until the rename, whole.
                let (scanned, scan) = mpsc::channel();
                let (jobs, default_root) = (&jobs, &default_root);
                let sessions = root.join("Sessions");
                scope.spawn(move || {
                    let _ = scanned.send(jobs.require_mutation_state(default_root, &[sessions]));
                });
                scan.recv_timeout(Duration::from_secs(120))
                    .expect("the scan answers while the storage lock is held to rename")
                    .unwrap();
                assert!(!session.exists(), "published before its rename");
                let (sender, receiver) = mpsc::channel();
                scope.spawn(move || sender.send(admit("longPress.submit")).unwrap());
                if let Ok(early) = receiver.recv_timeout(Duration::from_millis(200)) {
                    panic!(
                        "the long press was answered while the tap's Session was renamed: {early}"
                    );
                }
                resume.send(()).unwrap();
                receiver.recv_timeout(Duration::from_secs(120)).unwrap()
            }
        };
        assert_eq!(semantic(&tap.join().unwrap()), recorded("tap.run"));
        assert_eq!(semantic(&long_press), recorded("longPress.submit"));
    });
    assert!(session.join("manifest.json").exists());
    assert!(!root.join("Sessions/.staging").exists());
}

#[test]
fn a_gesture_submitted_while_the_previous_one_writes_its_session_is_admitted_at_once() {
    tap_publication(StopPoint::Injection);
}

#[test]
fn a_gesture_submitted_while_the_previous_one_renames_its_session_waits_for_it() {
    tap_publication(StopPoint::Moving);
}

#[test]
fn pointer_staged_crash_child() {
    if std::env::var_os("ARKDECK_POINTER_STAGED_CRASH_CHILD").is_some() {
        tap_publication(StopPoint::Crash);
    }
}

/// A publication stopped between its staged Session and the rename: the
/// process dies once the staged Manifest is published. At the next start the
/// staged Session, proved this Runtime's, is removed, and nothing is published
/// again, as Swift's restart resumes no publication: the Job's record and
/// Journal are left as the crash left them, and its Session's name stays free.
/// Staged entries nothing proves are kept exactly as they are, and a second
/// start changes nothing.
#[test]
fn a_publication_stopped_before_its_rename_is_removed_at_the_next_start() {
    let _lock = exclusive();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "pointer_staged_crash_child", "--nocapture"])
        .env("ARKDECK_POINTER_STAGED_CRASH_CHILD", "1")
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(75),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    let root = PathBuf::from(ROOT);
    let job = "job-4ac2c3640786ad0e831952ab62bb71bc";
    let session = root.join(format!("Sessions/2026/09/session-{job}"));
    let staged = staged(&root.join("Sessions"));
    assert!(staged.join("manifest.json").exists());
    assert!(!session.exists());
    let job_directory = root.join(format!("store/jobs/{job}"));
    let left = |name: &str| fs::read(job_directory.join(name)).unwrap();
    let (record, journal) = (left("job-record.json"), left("journal.jsonl"));
    let marker: Value = serde_json::from_slice(&record).unwrap();
    assert!(marker.get("sessionPublicationRecord").is_none());
    // What nothing proves this Runtime's is kept as it is.
    let rogue = [
        ("not-a-staged-name", None),
        ("00000000-0000-4000-8000-000000000000", None),
        (
            "11111111-1111-4111-8111-111111111111",
            Some(
                r#"{"jobId":"job-ffffffffffffffffffffffffffffffff","schemaVersion":"1.0.0","sessionId":"session-job-ffffffffffffffffffffffffffffffff"}"#,
            ),
        ),
    ];
    for (name, identity) in rogue {
        let directory = root.join("Sessions/.staging").join(name);
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
        if let Some(identity) = identity {
            fs::write(directory.join(".session-identity.json"), identity).unwrap();
            chmod(&directory.join(".session-identity.json"), 0o600);
        }
    }
    let jobs = JobStore::open_owner(&root.join("store")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let provenance = support::document(&support::fixture("pointer-input"), "provenance.json");
    let probe = OracleProbe::new(&provenance);
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let recovered = publisher.recover_staged(&jobs).unwrap();
    let staged_name = staged.file_name().unwrap().to_str().unwrap();
    assert_eq!(
        recovered.removed,
        [(staged_name.to_owned(), job.to_owned())]
    );
    let kept: std::collections::BTreeSet<&str> = recovered
        .kept
        .iter()
        .map(|(name, _)| name.as_str())
        .collect();
    assert_eq!(
        kept,
        rogue.iter().map(|(name, _)| *name).collect(),
        "{:?}",
        recovered.kept
    );
    assert!(!staged.exists());
    for (name, _) in rogue {
        assert!(root.join("Sessions/.staging").join(name).exists());
    }
    // Nothing is published again, and the Job is left as the crash left it.
    assert!(!session.exists());
    assert_eq!(left("job-record.json"), record);
    assert_eq!(left("journal.jsonl"), journal);
    // A second start changes nothing.
    let again = publisher.recover_staged(&jobs).unwrap();
    assert!(again.removed.is_empty());
    assert_eq!(again.kept, recovered.kept);
    // Once nothing is left in it, staging goes.
    for (name, _) in rogue {
        fs::remove_dir_all(root.join("Sessions/.staging").join(name)).unwrap();
    }
    let empty = publisher.recover_staged(&jobs).unwrap();
    assert_eq!(empty, arkdeck_hoststore::StagedRecovery::default());
    assert!(!root.join("Sessions/.staging").exists());
}

/// The oracle's probe, which also notes where the publication stands and
/// how long each hold of the storage lock lasted.
struct Timed {
    oracle: OracleProbe,
    marks: Mutex<Vec<(&'static str, std::time::Instant)>>,
    holds: Mutex<Vec<Duration>>,
}

impl StorageProbe for Timed {
    fn snapshot(&self, root: &HostDirectory) -> std::io::Result<StorageSnapshot> {
        let snapshot = self.oracle.snapshot(root);
        self.marks
            .lock()
            .unwrap()
            .push(("probed", std::time::Instant::now()));
        snapshot
    }
    fn reached(&self, point: PublicationPoint) {
        let name = match point {
            PublicationPoint::SessionCreated => "created",
            PublicationPoint::JournalCopied { .. } => "copied",
            PublicationPoint::ManifestPublished => "manifest",
            PublicationPoint::Moving => "moving",
            PublicationPoint::StorageReleased { held } => {
                self.holds.lock().unwrap().push(held);
                return;
            }
        };
        self.marks
            .lock()
            .unwrap()
            .push((name, std::time::Instant::now()));
    }
}

/// How long the tap's publication writes its staged Session and holds the
/// Session storage lock. A measurement, not a check: run on a quiet host with
/// `--ignored --nocapture`.
#[test]
#[ignore = "a measurement for a quiet host"]
fn the_tap_publication_holds_the_storage_lock_for() {
    let _lock = exclusive();
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let exchanges = cases["exchanges"].as_array().unwrap();
    let exchange = |name: &str| {
        exchanges
            .iter()
            .find(|exchange| exchange["name"] == name)
            .unwrap()
    };
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("store")).unwrap();
    let capabilities =
        arkdeck_hoststore::CapabilityStore::open(&root.join("store/capabilities")).unwrap();
    let holds = arkdeck_hoststore::DeviceHolds::default();
    let default_root = root.join("store");
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
    let probe = Timed {
        oracle: OracleProbe::new(&provenance),
        marks: Mutex::new(Vec::new()),
        holds: Mutex::new(Vec::new()),
    };
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    let authority = arkdeck_hoststore::MutationAuthority {
        capabilities: &capabilities,
        holds: &holds,
        default_root: &default_root,
        sessions: Some(&sessions),
    };
    JobAdmitter {
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
        authority: Some(authority),
    }
    .handle(exchange("tap.submit")["params"].as_object().unwrap())
    .unwrap();
    fs::write(root.join("hdc-mode"), "normal\n").unwrap();
    JobRunner {
        imports: None,
        mutation: Some(arkdeck_hoststore::MutationExecution {
            authority,
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
    }
    .handle(exchange("tap.run")["params"].as_object().unwrap())
    .unwrap();
    let marks = probe.marks.lock().unwrap().clone();
    let at = |name: &str| marks.iter().find(|(mark, _)| *mark == name).unwrap().1;
    let copied: Vec<_> = marks.iter().filter(|(mark, _)| *mark == "copied").collect();
    println!(
        "tap publication: probed -> created {:?}; {} records copied {:?}; copied -> manifest {:?}; \
         manifest -> moving {:?}; storage lock held {:?}",
        at("created") - at("probed"),
        copied.len(),
        copied.last().unwrap().1 - at("created"),
        at("manifest") - copied.last().unwrap().1,
        at("moving") - at("manifest"),
        probe.holds.lock().unwrap(),
    );
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
fn restart_after_consumption_resumes_once_and_after_intent_never_replays() {
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
            workspace: None,
        };
        let job = Map::from_iter([(
            "jobId".into(),
            json!("job-4ac2c3640786ad0e831952ab62bb71bc"),
        )]);
        if mode == "consume" {
            // The run died once the use was consumed and before the record
            // held its evidence or any gesture intent existed: the journal
            // stands at a boundary its steps confirmed, and a run resumes it
            // there (Swift `runOwned` from `running`). The gesture is sent for
            // the first time, under the one use the reservation already holds.
            let resumed = runner.handle(&job).unwrap();
            assert_eq!(resumed["state"], "succeeded", "{resumed}");
            let now = fs::read_to_string(root.join("hdc-invocations.log")).unwrap();
            let added = &now[calls.len()..];
            assert_eq!(
                added.lines().filter(|line| line.contains("uinput")).count(),
                1,
                "{added}"
            );
            let settled =
                fs::read_to_string(root.join("store/capabilities/runtime-capabilities.ledger"))
                    .unwrap();
            assert_eq!(
                settled
                    .lines()
                    .filter(|line| line.contains("\"consumption\""))
                    .count(),
                1,
                "{settled}"
            );
            assert!(settled.starts_with(std::str::from_utf8(&ledger).unwrap()));
            assert!(
                runner.handle(&job).is_err(),
                "a terminal Job never runs again"
            );
            continue;
        }
        // An intent whose outcome was never observed is never resent.
        assert_eq!(runner.handle(&job).unwrap_err().code, "resourceConflict");
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
                workspace: None,
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
fn cancellation_before_consumption_leaves_no_use_or_pointer_intent() {
    replay(Fault::CancelBeforeConsume);
}
#[test]
fn cancellation_after_consumption_settles_without_pointer_intent() {
    replay(Fault::CancelAfterConsume);
}
