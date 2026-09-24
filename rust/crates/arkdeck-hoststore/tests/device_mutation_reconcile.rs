//! Replays the Swift oracle of the reconcile and resume of parked device
//! mutations (`rust/tests/fixtures/device-mutation-reconcile`, recorded by
//! `DeviceMutationReconcileOracleContractTests`) through the Rust admitter,
//! runner, recovery, reconciler, cleanup debt continuation and readers over
//! the shared fake HDC, composed as the standalone daemon composes them,
//! scenario by scenario and step by step:
//! - `portRule`: a create whose `fport` dies after writing the rule parks;
//!   reconcile reads it back and confirms it completed; a start carries the
//!   confirmed boundary; `job.run` resumes the Job there — the journal's
//!   confirmed steps skipped, the rule read back once more — and settles its
//!   use, so the next create is admitted and runs;
//! - `debugHap`: an install killed before it installs is read back absent,
//!   confirmed not executed, and the Job's failure finalization removes its
//!   staging under the use it consumed; a Job parked on its read-only HiLog
//!   capture is confirmed not executed and every declared compensation runs;
//!   an install killed after it installs is read back present, and the
//!   resumed Job starts, observes, stops, uninstalls and cleans up under its
//!   use, consuming no second one;
//! - `nativeLibrary`: a publish killed after it published is read back as
//!   the new library and the resumed Job restarts, verifies and cleans up;
//!   one killed before is read back as the old library, which a publish never
//!   proves not executed, so the Job stays parked, `job.run` refuses it and
//!   its lineage refuses the next request;
//! - `screenSequence`: a receive killed is read-only and confirmed not
//!   executed; a capture parked on its missing archive fails its reconcile as
//!   Swift's does (its kind is unknown to Swift's materialization), leaving
//!   the Journal `reconciling` and the record resident ahead of its file;
//! - `captureFileLegs`: a component tree capture killed before writing reads
//!   back absent, one killed after reads back present and is resumed through
//!   its receive and cleanup, and a refused cleanup's debt is continued.
//!
//! Every answer, every snapshot the oracle took (Job index and files,
//! capability store, the fake's calls so far) and everything the replay
//! leaves must be Swift's byte for byte, once each Job record's volume,
//! device, inode and claim generation are read as labels.
//!
//! Three scenarios start from a daemon that died mid-run, which a child of
//! this test binary reproduces by exiting where Swift's oracle copied its
//! root: `tapBeforeConsume` and `tapAfterConsume` (an `input.tap@1` that
//! dies before its capability is consumed, or once the use and its evidence
//! are durable and before the gesture's intent), resumed from `running` by
//! `job.run` — the first consuming its use, the second continuing under the
//! one it holds — and `hapFinalizing` (a debug HAP whose start fails and
//! whose daemon dies as its failure finalization begins), whose finalization
//! `job.run` continues. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;
use support::debug_hap;
use support::reconcile::Daemon;

const FIXTURE: &str = "device-mutation-reconcile";

/// One recorded exchange answered by the Rust owner that serves it: a start,
/// a run with the device state it clears first, or any other request.
fn answer(daemon: &mut Daemon, exchange: &Value) -> Value {
    match exchange["method"].as_str().unwrap() {
        "recoverActiveJobs" => json!(daemon.restart().statuses),
        method => {
            if method == "job.run" {
                for state in exchange["cleared"].as_array().into_iter().flatten() {
                    let _ = fs::remove_file(daemon.root.join(state.as_str().unwrap()));
                }
            }
            daemon.answer(&daemon.timed(), exchange)
        }
    }
}

/// Every exchange of the scenario from `first` on, answered in order, each
/// recorded snapshot compared where the oracle took it; the differences.
fn replay_from(daemon: &mut Daemon, scenario: &str, first: usize) -> Vec<String> {
    let cases = support::document(&daemon.fixture, "cases.json");
    let steps: Vec<&str> = cases["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| step.as_str().unwrap())
        .filter(|step| *step != "crash")
        .collect();
    let mut snapshots = steps.iter().peekable();
    let mut differences = Vec::new();
    for exchange in &cases["exchanges"].as_array().unwrap()[first..] {
        let name = exchange["name"].as_str().unwrap();
        let actual = answer(daemon, exchange);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{scenario} {name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
        // The oracle recorded the store after every step that writes one.
        if snapshots.peek() == Some(&&name) {
            daemon.assert_snapshot(&format!("steps/{name}"));
            snapshots.next();
        }
    }
    assert!(
        snapshots.next().is_none(),
        "{scenario}: every recorded step was replayed"
    );
    differences
}

fn replay(scenario: &str) {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/{scenario}"));
    let differences = replay_from(&mut daemon, scenario, 0);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    daemon.assert_leftovers();
}

#[test]
fn a_port_rule_confirmed_by_its_readback_is_resumed_as_swift_resumes_it() {
    replay("portRule");
}

#[test]
fn a_debug_hap_is_reconciled_finalized_and_resumed_as_swift_does() {
    replay("debugHap");
}

#[test]
fn a_native_deployment_is_resumed_or_kept_parked_as_swift_decides() {
    replay("nativeLibrary");
}

#[test]
fn a_screen_sequence_is_reconciled_as_swift_reconciles_it() {
    replay("screenSequence");
}

#[test]
fn a_capture_file_leg_is_read_back_resumed_and_its_debt_continued_as_swift_does() {
    replay("captureFileLegs");
}

/// A resumed Job continues only the use the capability store still holds
/// unsettled for it (a stricter check than Swift's, which reads the Job's
/// record alone): with that use settled behind its back, `job.run` of the
/// Job at its confirmed safe boundary is refused with the zero-dispatch
/// proof, and nothing is dispatched or written.
#[test]
fn a_resumed_job_continues_only_the_unsettled_use_it_holds() {
    let _lock = debug_hap::exclusive();
    let mut daemon = Daemon::open(&format!("{FIXTURE}/portRule"));
    let cases = support::document(&daemon.fixture, "cases.json");
    for exchange in cases["exchanges"].as_array().unwrap() {
        let actual = answer(&mut daemon, exchange);
        assert_eq!(actual, exchange["answer"], "{}", exchange["name"]);
        if exchange["name"] == "reconcile" {
            break;
        }
    }
    let job = cases["jobs"]["create"].as_str().unwrap();
    let directory = daemon.default_root.join("jobs").join(job);
    let record: Value =
        serde_json::from_slice(&fs::read(directory.join("job-record.json")).unwrap()).unwrap();
    assert_eq!(record["state"], "resumeAtConfirmedSafeBoundary");
    daemon
        .stores()
        .capabilities
        .record_outcome(
            record["admissionEvidence"]["reference"].as_str().unwrap(),
            record["request"]["idempotencyKey"].as_str().unwrap(),
            job,
            arkdeck_hoststore::CapabilityUseOutcome::Confirmed,
            "succeeded",
            &support::fixed_now().unwrap(),
        )
        .unwrap();
    let files = |name: &str| fs::read(directory.join(name)).unwrap();
    let before = (
        files("job-record.json"),
        files("journal.jsonl"),
        daemon.calls(),
    );
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    assert_eq!(
        daemon.run(&daemon.dispatch, &params, None),
        json!({"ok": false, "error": {"code": "rejected",
            "message": format!(
                "job {job}'s capability use is not an unsettled use the store holds for it; \
                 the Rust Runtime does not continue it and nothing was dispatched"
            ),
            "details": {"jobId": job, "newDispatchCount": 0, "phase": "preAdmission"}}})
    );
    assert_eq!(
        (
            files("job-record.json"),
            files("journal.jsonl"),
            daemon.calls()
        ),
        before
    );
}

// --- the scenarios whose daemon died mid-run -------------------------------

/// Each crashed scenario: the mode its Job ran in, and the exit code of the
/// child that dies at its window.
const CRASHES: [(&str, &str, i32); 3] = [
    ("tapBeforeConsume", "normal", 91),
    ("tapAfterConsume", "normal", 92),
    ("hapFinalizing", "startFailed", 93),
];
const CHILD: &str = "ARKDECK_DEVICE_MUTATION_CRASH_CHILD";

fn crash(scenario: &str) -> (&'static str, &'static str, i32) {
    *CRASHES
        .iter()
        .find(|(name, _, _)| *name == scenario)
        .unwrap()
}

/// The fake's dispatcher, which dies where Swift's `beforeConsume` window
/// copied the root: at the tool identity check that opens the consume, once
/// the last evidence step's outcome is durable.
struct Dying<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    before_consume: bool,
    journal: PathBuf,
}

impl HdcDispatch for Dying<'_> {
    fn mutation_identity_current(&self) -> bool {
        if self.before_consume
            && fs::read_to_string(&self.journal)
                .is_ok_and(|journal| journal.contains("\"outcome-read-evidence-firmware\""))
        {
            std::process::exit(crash("tapBeforeConsume").2);
        }
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.inner.dispatch(plan)
    }
}

/// The Job record a dying clock watches, and the window it dies at.
static WATCHED: OnceLock<(PathBuf, &'static str)> = OnceLock::new();

/// The oracle's clock, until the Job record on disk has reached the window:
/// the next read is where the run dies. `tapAfterConsume` dies once the
/// record holds the consumed capability's evidence (the gesture intent's
/// envelope comes next); `hapFinalizing` once the record is `finalizing`
/// with its failure, where Swift's `failureFinalizing` checkpoint sits.
fn dying_clock() -> Option<String> {
    if let Some((record, scenario)) = WATCHED.get()
        && let Ok(text) = fs::read_to_string(record)
    {
        let reached = match *scenario {
            "tapAfterConsume" => text.contains("\"runtimeCapability\""),
            _ => serde_json::from_str::<Value>(&text)
                .is_ok_and(|record| record["state"] == "finalizing"),
        };
        if reached {
            std::process::exit(crash(scenario).2);
        }
    }
    support::fixed_now()
}

/// The Rust daemon's run of a crashed scenario's Job, dying at its window.
/// Run only as the child of the test below.
#[test]
fn device_mutation_crash_child() {
    let Ok(scenario) = std::env::var(CHILD) else {
        return;
    };
    let (scenario, mode, _) = crash(&scenario);
    let daemon = Daemon::open(&format!("{FIXTURE}/{scenario}"));
    let cases = support::document(&daemon.fixture, "cases.json");
    let submit = &cases["exchanges"][0];
    assert_eq!(
        daemon.answer(&daemon.dispatch, submit),
        submit["answer"],
        "{scenario}: {}",
        submit["name"]
    );
    let job = cases["jobs"]
        .as_object()
        .unwrap()
        .values()
        .find(|job| submit["answer"]["result"]["jobId"] == **job)
        .unwrap()
        .as_str()
        .unwrap()
        .to_owned();
    let jobs = daemon.default_root.join("jobs").join(&job);
    let dying = Dying {
        inner: &daemon.dispatch,
        before_consume: scenario == "tapBeforeConsume",
        journal: jobs.join("journal.jsonl"),
    };
    let now: fn() -> Option<String> = if scenario == "tapBeforeConsume" {
        support::fixed_now
    } else {
        WATCHED
            .set((jobs.join("job-record.json"), scenario))
            .unwrap();
        dying_clock
    };
    daemon.mode(mode);
    let params = Map::from_iter([("jobId".into(), json!(job))]);
    let ran = daemon.run_on(&dying, &params, None, now);
    panic!("{scenario}: the run ended without reaching its window: {ran}");
}

/// A crashed scenario: the child dies at the window, the store it left must
/// be Swift's at its death, and every exchange after the submission is
/// answered as Swift answered it — the start first, then the run that
/// resumes or continues the Job.
fn replay_crash(scenario: &str) {
    let _lock = debug_hap::exclusive();
    let (_, _, code) = crash(scenario);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "device_mutation_crash_child", "--nocapture"])
        .env(CHILD, scenario)
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(code),
        "{scenario}: {}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let mut daemon = Daemon::attach(&format!("{FIXTURE}/{scenario}"));
    daemon.mode("normal");
    daemon.assert_snapshot("steps/crash");
    let differences = replay_from(&mut daemon, scenario, 1);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    daemon.assert_leftovers();
}

#[test]
fn a_tap_that_died_before_its_consume_is_resumed_and_consumes_its_use_once() {
    replay_crash("tapBeforeConsume");
}

#[test]
fn a_tap_that_died_after_its_consume_is_resumed_under_the_use_it_holds() {
    replay_crash("tapAfterConsume");
}

#[test]
fn a_debug_hap_failure_finalization_a_restart_left_is_continued_by_its_run() {
    replay_crash("hapFinalizing");
}
