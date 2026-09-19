//! Replays the Swift debug-hap oracle (`rust/tests/fixtures/debug-hap`,
//! recorded by `DebugHapOracleContractTests` over the shared fake HDC) through
//! the production Rust planner, admitter, runner, result reader and capability
//! reads, under the durable mutation authority the pointer and port-rule
//! replays run under: the account-fixed Job root, each Job's one capability
//! use consumed before its first mutation's intent and continued by every
//! later mutation and compensation of the same run, and the use settled once
//! the Job is terminal or parked. Every exchange before the cleanup debt
//! continuations (`cleanupDebt.*`, not served by this Runtime) answers as
//! Swift answered it, message included:
//! - the success lanes: a HAP debugged on its own and with an additional
//!   package, sent into the Job's owned staging, installed and started as
//!   dispatches the package and process readbacks believe, its HiLog read,
//!   then stopped, uninstalled and its staging removed;
//! - the failure lanes: a package the readback does not list, an ability that
//!   does not start and a stop that leaves it running each fail their Job with
//!   its original failure once the compensations its succeeded steps declared
//!   have run, the latest first; a cleanup that already ran is never sent
//!   again;
//! - the debts: an uninstall that leaves the bundle, as an optional cleanup,
//!   and a staging cleanup that fails as a required one are each owed in the
//!   cleanup debt ledger with the exact action that failed;
//! - an empty HiLog capture, which parks its Job with its intent outstanding.
//!
//! The fake receives Swift's first 103 calls in order, and everything the
//! replay leaves below the root is Swift's byte for byte. For the two Jobs
//! whose debts the continuations later settle, that is their record and index
//! row as they stood before (the continuation's recovery load appends
//! `recovered: journal clean`, and its two persists count the settled
//! residue), and the ledger without its two settlement members.
//!
//! More tests take what no oracle records. Four hold the runner to its
//! authority: evidence a run did not consume itself is never continued, a
//! compensation whose tool can no longer be proved is never dispatched and
//! leaves its Job `finalizing`, an optional cleanup refused its authority
//! stops the run, and without the mutation owner nothing is admitted or
//! changed. Two fault a compensation: one that fails is owed
//! under its own identity, one whose outcome is lost parks its Job. Every
//! transport byte comes from the shared fake HDC; none of this is hardware
//! acceptance. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{HdcComposition, JobRecord};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use support::debug_hap;
use support::fixed_now;
use support::hdc_oracle::{self, Owners, exchange};

/// The fake's calls Swift's runs made before its continuations.
const CALLS: usize = 103;
/// The runs whose debts the continuations settle.
const CONTINUED: [&str; 2] = ["stillInstalled", "cleanupDebt"];

/// Every recorded request but the continuations, answered in order by the
/// Rust owners. Every answer must be Swift's, its message included, and so
/// must each call the fake received, the Target document and everything the
/// replay leaves below the root.
#[test]
fn rust_runs_every_swift_debug_hap_as_swift_does() {
    hdc_oracle::assert_replays_before_continuations("debug-hap", &CONTINUED, 59, CALLS);
}

/// The installed case admitted as Swift admitted it, with the fake in `mode`.
fn admitted(owners: &Owners, hdc: &HdcComposition<'_>, cases: &Value, mode: &str) -> String {
    owners
        .admitter(hdc, &owners.default_root)
        .handle(
            exchange(cases, "installed.submit")["params"]
                .as_object()
                .unwrap(),
        )
        .unwrap();
    owners.mode(mode);
    cases["jobs"]["installed"].as_str().unwrap().to_owned()
}

/// How many uses the store holds: those its checkpoint folded and those its
/// ledger appended since.
fn uses(owners: &Owners) -> usize {
    let directory = owners.default_root.join("capabilities");
    let folded = fs::read(directory.join("runtime-capabilities.json")).map_or(0, |bytes| {
        let checkpoint: Value = serde_json::from_slice(&bytes).unwrap();
        checkpoint["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|record| record["consumptions"].as_array().unwrap().len())
            .sum()
    });
    let appended = fs::read_to_string(directory.join("runtime-capabilities.ledger"))
        .unwrap_or_default()
        .lines()
        .filter(|line| serde_json::from_str::<Value>(line).unwrap()["kind"] == "consumed")
        .count();
    folded + appended
}

/// A run continues only the use it consumed itself. Evidence written onto an
/// admitted record, here the very use Swift's run of this Job consumed, is
/// refused at the first mutation: nothing past the read-only preflight is
/// dispatched, no use is consumed or settled, and the Job fails through its
/// failure lane with nothing to compensate.
#[test]
fn evidence_a_run_did_not_consume_is_never_continued() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&owners.dispatch);
    let publisher = owners.publisher();
    let job = admitted(&owners, &hdc, &cases, "normal");
    let mut record = owners.record(&job);
    let swift = support::document(&fixture, &format!("store/jobs/{job}/job-record.json"));
    record["admissionEvidence"] = swift["admissionEvidence"].clone();
    let record = JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap();
    owners.jobs.persist(&record, &fixed_now().unwrap()).unwrap();

    let status = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    assert_eq!(
        (&status["state"], &status["outstandingResidueCount"]),
        (&json!("failed"), &json!(0))
    );
    let timeline = owners.record(&job)["timeline"].clone();
    let refusal = "authorizationRequired: persisted mutation evidence cannot be replayed";
    let tail: Vec<&str> = timeline
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap())
        .skip_while(|line| *line != "evidence-preflight read-evidence-firmware")
        .collect();
    assert_eq!(
        tail,
        [
            "evidence-preflight read-evidence-firmware".to_owned(),
            "running->finalizing".into(),
            format!("reason: {refusal}"),
            "finalizing->failed".into(),
            "reason: original failure retained; declared compensations have confirmed outcomes"
                .into(),
        ]
    );
    let calls = owners.calls();
    assert_eq!(calls.lines().count(), 3, "{calls}");
    assert!(!calls.contains("file\u{1f}send"), "{calls}");
    assert_eq!(uses(&owners), 0, "nothing is consumed or settled");
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    assert!(!journal.contains("intent-send-hap"), "{journal}");
}

/// The fake as the oracle drives it, but with a retained executable that
/// can no longer be proved once a call carrying `after` has been dispatched.
struct UnprovenAfter<'a> {
    inner: &'a ProcessDispatch,
    after: [&'static str; 3],
    seen: AtomicBool,
}

impl HdcDispatch for UnprovenAfter<'_> {
    fn mutation_identity_current(&self) -> bool {
        !self.seen.load(Ordering::SeqCst) && self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let receipt = self.inner.dispatch(plan);
        if plan.arguments.windows(3).any(|window| window == self.after) {
            self.seen.store(true, Ordering::SeqCst);
        }
        receipt
    }
}

/// A compensation is a device mutation too. When the tool can no longer be
/// proved after the readback that failed the Job, no compensation is
/// dispatched: Swift throws the refusal past the lane, so the run answers
/// its internal failure and the Job stays `finalizing` with its use pending,
/// for recovery to settle (L.1 item 13).
#[test]
fn a_compensation_through_an_unproven_tool_is_never_dispatched() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = UnprovenAfter {
        inner: &owners.dispatch,
        after: ["bm", "dump", "-n"],
        seen: AtomicBool::new(false),
    };
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let job = admitted(&owners, &hdc, &cases, "notInstalled");
    let refusal = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        (
            "internalError",
            "the Runtime could not complete the Job lifecycle request"
        )
    );
    let record = owners.record(&job);
    assert_eq!(record["state"], "finalizing");
    assert!(record["recoveryStepID"].is_null(), "{record}");
    let calls = owners.calls();
    assert!(!calls.contains("uninstall"), "{calls}");
    assert!(!calls.contains("rm\u{1f}-f"), "{calls}");
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    assert!(!journal.contains("compensationIntent"), "{journal}");
    let capability = record["admissionEvidence"]["reference"].as_str().unwrap();
    let inspected = owners
        .capabilities
        .handle(
            "capability.inspect",
            &Map::from_iter([("capabilityId".into(), json!(capability))]),
        )
        .unwrap();
    assert_eq!(
        (
            &inspected["lineage"][0]["outcomeHistory"],
            &inspected["lineageBlocker"]
        ),
        (&json!([]), &json!("use 1 is pending")),
        "{inspected}"
    );
    // Swift would continue the lane from here; this Runtime resumes nothing
    // before recovery is ported, and dispatches nothing to say so.
    let calls = owners.calls();
    let again = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap_err();
    assert_eq!(
        (again.code, again.message),
        (
            "resourceConflict",
            format!(
                "job {job} is finalizing; the Rust Runtime resumes no Job before recovery is ported"
            )
        )
    );
    assert_eq!(owners.calls(), calls);
}

/// What the device does to the first `uninstall` a compensation sends.
#[derive(Clone, Copy, PartialEq)]
enum Uninstall {
    /// It answers and leaves the bundle installed (the fake's `stillInstalled`).
    Ineffective,
    /// Its outcome cannot be observed.
    Unobserved,
}

/// The fake as the oracle drives it in `startFailed`, but for its uninstall.
struct FaultedUninstall<'a> {
    inner: &'a ProcessDispatch,
    root: &'a Path,
    fault: Uninstall,
}

impl HdcDispatch for FaultedUninstall<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        if plan
            .arguments
            .iter()
            .any(|argument| argument == "uninstall")
        {
            match self.fault {
                Uninstall::Ineffective => {
                    fs::write(self.root.join("hdc-mode"), "stillInstalled\n").unwrap();
                }
                Uninstall::Unobserved => {
                    return Err(DispatchFailure::Unobservable(
                        "dispatch outcome unobservable: the uninstall was lost".into(),
                    ));
                }
            }
        }
        self.inner.dispatch(plan)
    }
}

/// What a faulted `startFailed` run leaves: the fixed root's lock, which the
/// caller keeps while it reads, the owners, the Job, its status and its
/// timeline from the start's failure on.
struct Faulted {
    _lock: fs::File,
    owners: Owners,
    job: String,
    status: Value,
    tail: Vec<String>,
}

/// `startFailed`'s run with its uninstall compensation faulted.
fn start_failed_with(fault: Uninstall) -> Faulted {
    let lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = FaultedUninstall {
        inner: &owners.dispatch,
        root: &owners.root,
        fault,
    };
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let job = admitted(&owners, &hdc, &cases, "startFailed");
    let status = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    let tail: Vec<String> = owners.record(&job)["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap().to_owned())
        .skip_while(|line| !line.starts_with("failed start-ability"))
        .collect();
    Faulted {
        _lock: lock,
        owners,
        job,
        status,
        tail,
    }
}

/// A compensation that fails is owed under its own identity, with the exact
/// action that failed; the lane goes on to the next, and the Job fails with
/// its original failure and one residue outstanding.
#[test]
fn a_compensation_that_fails_is_owed_under_its_own_identity() {
    let Faulted {
        _lock,
        owners,
        job,
        status,
        tail,
    } = start_failed_with(Uninstall::Ineffective);
    assert_eq!(
        (&status["state"], &status["outstandingResidueCount"]),
        (&json!("failed"), &json!(1))
    );
    let debt = "compensation needsAttention: confirmed compensation failure: cleanup-uninstall";
    assert_eq!(
        tail,
        [
            "failed start-ability: startFailed: start process reported failure",
            "running->finalizing",
            "reason: startFailed: start process reported failure",
            "intent compensation-cleanup-uninstall",
            "failed cleanup-uninstall: uninstallIneffective: com.example.demo is still installed after uninstall",
            debt,
            "intent compensation-cleanup-remote-staging",
            "verified cleanup-remote-staging [\"cleaned\"]",
            "finalizing->failed",
            "reason: original failure retained; declared compensations have confirmed outcomes",
        ]
    );
    let ledger: Value =
        serde_json::from_slice(&fs::read(owners.root.join("artifacts/cleanup-debt.json")).unwrap())
            .unwrap();
    assert_eq!(
        ledger,
        json!([{"jobID": job, "stepID": "compensation-cleanup-uninstall",
            "remotePath": "", "bundleName": "com.example.demo",
            "reason": "confirmed compensation failure: cleanup-uninstall",
            "recordedAtUTC": fixed_now().unwrap(),
            "persistedAction": {"kind": "hdc.uninstallPackage",
                "arguments": {"bundleName": "com.example.demo"}}}])
    );
    let record = owners.record(&job);
    assert_eq!(record["operationFailure"]["code"], "executionFailed");
    assert!(record["recoveryStepID"].is_null(), "{record}");
    let capability = record["admissionEvidence"]["reference"].as_str().unwrap();
    let inspected = owners
        .capabilities
        .handle(
            "capability.inspect",
            &Map::from_iter([("capabilityId".into(), json!(capability))]),
        )
        .unwrap();
    let settled = &inspected["lineage"][0]["outcomeHistory"][0];
    assert_eq!(
        (&settled["outcome"], &settled["terminalState"]),
        (&json!("confirmed"), &json!("failed"))
    );
}

/// A compensation whose outcome cannot be observed parks its Job: its intent
/// stays outstanding, the next compensation is not sent, the Job keeps its
/// original failure, and its use is left `outcomeUnknown` for recovery.
#[test]
fn an_unobserved_compensation_parks_its_job() {
    let Faulted {
        _lock,
        owners,
        job,
        status,
        tail,
    } = start_failed_with(Uninstall::Unobserved);
    assert_eq!(
        (&status["state"], &status["outcomeUnknown"]),
        (&json!("waitingForRecovery"), &json!(true))
    );
    let reason = "compensation outcome unknown: outcomeUnknown(\"dispatch outcome unobservable: the uninstall was lost\")";
    assert_eq!(
        tail,
        [
            "failed start-ability: startFailed: start process reported failure".to_owned(),
            "running->finalizing".into(),
            "reason: startFailed: start process reported failure".into(),
            "intent compensation-cleanup-uninstall".into(),
            "outcomeUnknown cleanup-uninstall; durable intent left outstanding".into(),
            "finalizing->waitingForRecovery".into(),
            format!("reason: {reason}"),
            format!("compensation needsAttention: {reason}"),
        ]
    );
    let record = owners.record(&job);
    assert_eq!(record["operationFailure"]["code"], "executionFailed");
    assert_eq!(record["recoveryStepID"], "compensation-cleanup-uninstall");
    let calls = owners.calls();
    assert!(!calls.contains("rm\u{1f}-f"), "{calls}");
    assert!(!owners.root.join("artifacts/cleanup-debt.json").exists());
    let capability = record["admissionEvidence"]["reference"].as_str().unwrap();
    let inspected = owners
        .capabilities
        .handle(
            "capability.inspect",
            &Map::from_iter([("capabilityId".into(), json!(capability))]),
        )
        .unwrap();
    let settled = &inspected["lineage"][0]["outcomeHistory"][0];
    assert_eq!(
        (&settled["outcome"], &settled["terminalState"]),
        (&json!("outcomeUnknown"), &json!("waitingForRecovery"))
    );
}

/// An optional cleanup refused its authority before any intent has no
/// durable failed outcome to owe a debt for. Swift's step loop then refuses
/// to go on (`cleanup failure lacks its declared durable outcome`): the run
/// answers its internal failure, the uninstall is never sent, and the Job
/// stays `running` with its use pending, for recovery.
#[test]
fn an_optional_cleanup_refused_its_authority_stops_the_run() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = UnprovenAfter {
        inner: &owners.dispatch,
        after: ["aa", "force-stop", "com.example.demo"],
        seen: AtomicBool::new(false),
    };
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let job = admitted(&owners, &hdc, &cases, "normal");
    let refusal = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap_err();
    assert_eq!(refusal.code, "internalError", "{}", refusal.message);
    assert_eq!(owners.record(&job)["state"], "running");
    let calls = owners.calls();
    assert!(!calls.contains("uninstall"), "{calls}");
    // The journal ends with the stop's confirmed outcome: no intent follows.
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    let last: Value = serde_json::from_str(journal.lines().last().unwrap()).unwrap();
    assert_eq!(
        (&last["eventId"], &last["payload"]["result"]),
        (&json!("outcome-stop-ability"), &json!("succeeded"))
    );
    assert!(!owners.root.join("artifacts/cleanup-debt.json").exists());
}

/// A HAP changes a device only under the mutation authority: an owner whose
/// account-fixed Job root is elsewhere admits none and issues nothing, and a
/// runner without the mutation owner fails the admitted Job at its send,
/// consuming nothing and sending nothing.
#[test]
fn no_hap_is_sent_without_the_mutation_authority() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&owners.dispatch);
    let publisher = owners.publisher();
    let submit = exchange(&cases, "installed.submit")["params"]
        .as_object()
        .unwrap();
    let elsewhere = owners.root.join("elsewhere");
    let refusal = owners
        .admitter(&hdc, &elsewhere)
        .handle(submit)
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.proven),
        ("admissionDenied", true),
        "{}",
        refusal.message
    );
    let store = owners.default_root.join("capabilities");
    assert!(!store.join("runtime-capabilities.json").exists());
    let job = admitted(&owners, &hdc, &cases, "normal");
    let status = owners
        .runner(&hdc, &publisher, false)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    assert_eq!(status["state"], "failed");
    let record = owners.record(&job);
    assert!(record["admissionEvidence"].is_null(), "{record}");
    assert!(
        record["timeline"].as_array().unwrap().contains(&json!(
            "reason: authorizationRequired: Runtime mutation owner is unavailable"
        )),
        "{record}"
    );
    let calls = owners.calls();
    assert!(!calls.contains("file\u{1f}send"), "{calls}");
    assert!(!store.join("runtime-capabilities.ledger").exists());
    assert_eq!(uses(&owners), 0);
}
