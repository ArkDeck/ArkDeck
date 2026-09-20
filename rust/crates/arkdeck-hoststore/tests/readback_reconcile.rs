//! Replays the Swift dedicated-readback reconcile oracle
//! (`rust/tests/fixtures/readback-reconcile`, recorded by
//! `ReadbackReconcileOracleContractTests.testSwiftReconcilesParkedPortRulesByTheirDedicatedReadback`)
//! through the Rust admitter, runner, recovery, reconciler and readers over
//! the shared fake HDC, composed as the standalone daemon composes them, step
//! by step:
//! - a `port-forward.create@1` whose `fport` dies on SIGKILL before it writes
//!   the rule parks unknown; two starts carry it; `job.reconcile` reads the
//!   rule back once (`fport ls`), finds none, confirms the create not
//!   executed, fails the Job and resolves its use `safeToReflash`, and a
//!   second reconcile writes nothing;
//! - the capability store is put back as it stood when the Job parked (the
//!   crash window between the terminal record and the outcome append, which
//!   is not a request): a reconcile repairs the lineage from the journal's
//!   proof with no dispatch, and, put back once more, the next submission
//!   repairs it before it materializes;
//! - that create, killed after it wrote its rule, parks; after a start its
//!   readback lists the rule, so it is confirmed completed and waits at its
//!   confirmed safe boundary, its use still unknown; a third create is
//!   refused by the lineage.
//!
//! Every answer, every snapshot the oracle took (Job index and files,
//! capability store, the fake's calls so far) and everything the replay
//! leaves must be Swift's byte for byte, once each Job record's volume,
//! device, inode and claim generation are read as labels. The runs spawn the
//! fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::RunCancellation;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use support::debug_hap;
use support::reconcile::Daemon;

#[test]
fn rust_reconciles_the_swift_port_rules_by_their_dedicated_readback() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open("readback-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    let steps: Vec<&str> = cases["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| step.as_str().unwrap())
        .collect();
    let mut differences = Vec::new();
    let mut snapshots = steps.iter();
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        let actual = match exchange["method"].as_str().unwrap() {
            "recoverActiveJobs" => json!(daemon.restart().statuses),
            // The capability store's files put back as they stood when the
            // Job parked: the oracle's own recreation of the crash window.
            "restoreParkedCapabilityStore" => {
                let parked = daemon.fixture.join("steps/killedBefore.run/capabilities");
                for file in exchange["answer"].as_array().unwrap() {
                    let file = file.as_str().unwrap();
                    fs::write(
                        daemon.default_root.join("capabilities").join(file),
                        fs::read(parked.join(file)).unwrap(),
                    )
                    .unwrap();
                }
                exchange["answer"].clone()
            }
            _ => daemon.answer(&daemon.dispatch, exchange),
        };
        if actual != exchange["answer"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
        // The oracle recorded the store after every step, and only then.
        if snapshots.as_slice().first() == Some(&name) {
            daemon.assert_snapshot(&format!("steps/{name}"));
            snapshots.next();
        }
    }
    assert!(
        snapshots.next().is_none(),
        "every recorded step was replayed"
    );
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    daemon.assert_leftovers();
}

/// The exchange `name` of the readback oracle.
fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// How a test answers a port rule's readback, `fport ls`; every other call
/// reaches the fake.
#[derive(Clone)]
enum Readback {
    Fake,
    Refused(&'static str),
    Unobservable(&'static str),
    Exited(i32),
}

/// A canceller of the run: its request, and the thread that waits for the
/// run to answer it.
struct Canceller {
    signal: Arc<RunCancellation>,
    waiting: Mutex<Option<thread::JoinHandle<()>>>,
}

/// The fake as the oracle drives it, but for `fport ls`, answered as
/// `readback` says, and counted. A canceller, when given, is sent the moment
/// a rule is created and the create waits until the run holds the request.
struct Dispatch<'a> {
    inner: &'a ProcessDispatch,
    readback: Readback,
    reads: AtomicUsize,
    cancel: Option<Canceller>,
}

impl<'a> Dispatch<'a> {
    fn new(inner: &'a ProcessDispatch, readback: Readback) -> Self {
        Self {
            inner,
            readback,
            reads: AtomicUsize::new(0),
            cancel: None,
        }
    }
}

impl HdcDispatch for Dispatch<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let names = |command: [&str; 2]| plan.arguments.windows(2).any(|pair| pair == command);
        if names(["fport", "ls"]) {
            self.reads.fetch_add(1, Ordering::SeqCst);
            match self.readback {
                Readback::Fake => {}
                Readback::Refused(reason) => return Err(DispatchFailure::Refused(reason.into())),
                Readback::Unobservable(reason) => {
                    return Err(DispatchFailure::Unobservable(reason.into()));
                }
                Readback::Exited(status) => {
                    return Ok(Receipt {
                        exit_status: status,
                        stdout: Vec::new(),
                        stderr: Vec::new(),
                        truncated: false,
                        duration: Duration::ZERO,
                    });
                }
            }
        }
        if let Some(canceller) = &self.cancel
            && plan
                .arguments
                .iter()
                .any(|argument| argument.starts_with("tcp:"))
            && !names(["fport", "rm"])
        {
            let request = canceller.signal.clone();
            *canceller.waiting.lock().unwrap() = Some(thread::spawn(move || {
                request.request();
            }));
            while !canceller.signal.pending() {
                thread::yield_now();
            }
        }
        self.inner.dispatch(plan)
    }
}

fn job(cases: &Value, name: &str) -> Map<String, Value> {
    Map::from_iter([("jobId".into(), cases["jobs"][name].clone())])
}

fn journal(daemon: &Daemon, job: &Map<String, Value>) -> Vec<Value> {
    let path = daemon
        .default_root
        .join("jobs")
        .join(job["jobId"].as_str().unwrap())
        .join("journal.jsonl");
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Everything a refused reconcile must leave as it was: the Job's files, its
/// index row, the capability store and the fake's calls.
fn untouched(daemon: &Daemon, job: &Map<String, Value>) -> Vec<Vec<u8>> {
    let directory = daemon
        .default_root
        .join("jobs")
        .join(job["jobId"].as_str().unwrap());
    let capabilities = daemon.default_root.join("capabilities");
    vec![
        fs::read(directory.join("job-record.json")).unwrap(),
        fs::read(directory.join("journal.jsonl")).unwrap(),
        serde_json::to_vec(&support::index(&daemon.default_root)).unwrap(),
        fs::read(capabilities.join("runtime-capabilities.json")).unwrap(),
        fs::read(capabilities.join("runtime-capabilities.ledger")).unwrap(),
        daemon.calls().into_bytes(),
    ]
}

/// A create killed before it wrote its rule, parked and carried by a start,
/// as the oracle leaves it before its first reconcile.
fn parked_create() -> (Daemon, Value) {
    let mut daemon = Daemon::open("readback-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    for name in ["killedBefore.submit", "killedBefore.run"] {
        let exchange = exchange(&cases, name);
        assert_eq!(
            daemon.answer(&daemon.dispatch, exchange),
            exchange["answer"],
            "{name}"
        );
    }
    daemon.restart();
    daemon.assert_snapshot("steps/restart");
    (daemon, cases)
}

/// A readback that cannot conclude leaves the create parked: one `fport ls`
/// was sent, never the create, the decision is journaled unknown with the
/// reason, and the use stays `outcomeUnknown`. A later readback the device
/// answers still concludes it.
#[test]
fn a_readback_that_cannot_conclude_leaves_the_create_parked_and_never_resends_it() {
    let _lock = debug_hap::exclusive();
    let (daemon, cases) = parked_create();
    let job = job(&cases, "killedBefore");
    let calls = daemon.calls();
    let ledger = fs::read(
        daemon
            .default_root
            .join("capabilities/runtime-capabilities.ledger"),
    )
    .unwrap();
    for (readback, reason) in [
        (
            Readback::Refused("dispatch refused: the retained executable changed"),
            "dedicated readback failed: failed(\"dispatch refused: the retained executable \
             changed\"); original not resent",
        ),
        (
            Readback::Unobservable("process timed out before completion"),
            "dedicated readback failed: outcomeUnknown(\"process timed out before \
             completion\"); original not resent",
        ),
        (
            Readback::Exited(1),
            "dedicated readback did not produce a definite presence",
        ),
    ] {
        let before = journal(&daemon, &job).len();
        let dispatch = Dispatch::new(&daemon.dispatch, readback);
        let answer = daemon.reconcile(Some(&dispatch), &job);
        assert_eq!(
            (
                &answer["result"]["state"],
                &answer["result"]["outcomeUnknown"]
            ),
            (&json!("waitingForRecovery"), &json!(true)),
            "{answer}"
        );
        assert_eq!(dispatch.reads.load(Ordering::SeqCst), 1, "{reason}");
        let events = journal(&daemon, &job);
        let decided = &events[before..];
        let kinds: Vec<&str> = decided
            .iter()
            .map(|event| event["kind"].as_str().unwrap())
            .collect();
        assert_eq!(
            kinds,
            [
                "stateTransition",
                "reconcileStarted",
                "reconcileOutcome",
                "stateTransition"
            ]
        );
        assert_eq!(
            (&decided[2]["payload"], &decided[2]["bindingRevision"]),
            (
                &json!({"evidence": [reason], "nextState": "waitingForRecovery",
                    "outcomeCertainty": "outcomeUnknown",
                    "recoveryAttemptId": decided[1]["payload"]["recoveryAttemptId"],
                    "result": "waitingForRecovery", "safeBoundaryConfirmed": false}),
                &Value::Null
            )
        );
        assert_eq!(
            decided[3]["payload"]["reason"],
            format!("persist exact typed reconcile decision: {reason}")
        );
        let status = daemon.answer(
            &daemon.dispatch,
            &json!({"method": "job.status", "params": job}),
        );
        assert_eq!(status, answer, "the reconcile answers the Job's status");
    }
    assert_eq!(daemon.calls(), calls, "the create was resent");
    assert_eq!(
        fs::read(
            daemon
                .default_root
                .join("capabilities/runtime-capabilities.ledger")
        )
        .unwrap(),
        ledger,
        "an unknown decision settled the use"
    );

    // Answered by the device, the readback concludes the create: one more
    // call, `fport ls`, and never the create.
    let answer = daemon.reconcile(Some(&daemon.dispatch), &job);
    assert_eq!(answer["result"]["state"], "failed", "{answer}");
    let now = daemon.calls();
    let added: Vec<&str> = now[calls.len()..].lines().collect();
    assert_eq!(
        added,
        ["-t\u{1f}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{1f}fport\u{1f}ls\u{1f}"]
    );
}

/// What this Runtime does not reconcile is refused before anything is
/// written or dispatched: a device-bound Job without an HDC composition to
/// resolve its facts through, and a Job parked on its rule's readback
/// (`readPortForwardPresence`, whose reconcile Swift journals with its own
/// rendering of the action).
#[test]
fn what_is_not_reconciled_is_refused_with_nothing_written() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open("readback-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    let submit = exchange(&cases, "killedBefore.submit");
    assert_eq!(daemon.answer(&daemon.dispatch, submit), submit["answer"]);
    let job = job(&cases, "killedBefore");
    // The create succeeds; its readback is never observed, so the run parks
    // on the readback's intent.
    let unobserved = Readback::Unobservable("process timed out before completion");
    {
        let parking = Dispatch::new(&daemon.dispatch, unobserved.clone());
        let parked = daemon.run(&parking, &job, None);
        assert_eq!(parked["result"]["state"], "waitingForRecovery", "{parked}");
        assert_eq!(
            parking.reads.load(Ordering::SeqCst),
            1,
            "the run's readback"
        );
    }
    daemon.restart();
    let record: Value = serde_json::from_slice(
        &fs::read(
            daemon
                .default_root
                .join("jobs")
                .join(job["jobId"].as_str().unwrap())
                .join("job-record.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        record["recoveryAction"]["kind"],
        "hdc.readPortForwardPresence"
    );
    let before = untouched(&daemon, &job);
    let id = job["jobId"].as_str().unwrap();
    let parking = Dispatch::new(&daemon.dispatch, unobserved);
    for (dispatch, message) in [
        (
            None,
            format!(
                "job {id} runs port-forward.create@1, and this owner holds no HDC composition \
                 to reconcile it; nothing was dispatched or written"
            ),
        ),
        (
            Some(&parking as &(dyn HdcDispatch + Sync)),
            format!(
                "job {id} waits on hdc.readPortForwardPresence, which the Rust Runtime does not \
                 reconcile yet; nothing was dispatched or written"
            ),
        ),
    ] {
        assert_eq!(
            daemon.reconcile(dispatch, &job),
            json!({"ok": false, "error": {"code": "rejected", "message": message}})
        );
        assert_eq!(untouched(&daemon, &job), before);
    }
    assert_eq!(
        parking.reads.load(Ordering::SeqCst),
        0,
        "a refusal read back"
    );
}

/// Swift `repairTerminalCancelledLineageIfNeeded`: a Job cancelled after it
/// consumed its use, whose outcome a crash lost (the ledger's last append),
/// settles that use `confirmed` on reconcile, exactly as its run would have,
/// with nothing dispatched; a second reconcile changes nothing.
#[test]
fn a_cancelled_job_whose_outcome_was_lost_settles_its_use_confirmed() {
    let _lock = debug_hap::exclusive();
    let daemon = Daemon::open("readback-reconcile");
    let cases = support::document(&daemon.fixture, "cases.json");
    let submit = exchange(&cases, "killedBefore.submit");
    assert_eq!(daemon.answer(&daemon.dispatch, submit), submit["answer"]);
    let job = job(&cases, "killedBefore");
    let signal = Arc::new(RunCancellation::default());
    let mut cancelling = Dispatch::new(&daemon.dispatch, Readback::Fake);
    cancelling.cancel = Some(Canceller {
        signal: signal.clone(),
        waiting: Mutex::new(None),
    });
    let cancelled = daemon.run(&cancelling, &job, Some(&signal));
    signal.end();
    if let Some(canceller) = &cancelling.cancel
        && let Some(waiting) = canceller.waiting.lock().unwrap().take()
    {
        waiting.join().unwrap();
    }
    assert_eq!(cancelled["result"]["state"], "cancelled", "{cancelled}");
    let ledger = daemon
        .default_root
        .join("capabilities/runtime-capabilities.ledger");
    let settled = fs::read_to_string(&ledger).unwrap();
    let lines: Vec<&str> = settled.lines().collect();
    assert_eq!(lines.len(), 2, "the use, then its outcome");
    assert!(
        lines[1].contains("\"outcome\":\"confirmed\"")
            && lines[1].contains("\"terminalState\":\"cancelled\""),
        "{}",
        lines[1]
    );
    // The crash window: the terminal record durable, the outcome not.
    fs::write(&ledger, format!("{}\n", lines[0])).unwrap();
    let calls = daemon.calls();
    for _ in 0..2 {
        let answer = daemon.reconcile(Some(&daemon.dispatch), &job);
        assert_eq!(answer["result"]["state"], "cancelled", "{answer}");
        assert_eq!(fs::read_to_string(&ledger).unwrap(), settled);
    }
    assert_eq!(daemon.calls(), calls, "a repair dispatched");
}
