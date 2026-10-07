//! Replays the Swift debug-hap oracle (`rust/tests/fixtures/debug-hap`,
//! recorded by `DebugHapOracleContractTests` over the shared fake HDC) through
//! the production Rust planner, admitter, runner, result reader and capability
//! reads, under the durable mutation authority the pointer and port-rule
//! replays run under: the account-fixed Job root, each Job's one capability
//! use consumed before its first mutation's intent and continued by every
//! later mutation and compensation of the same run, and the use settled once
//! the Job is terminal or parked. Every exchange answers as Swift answered
//! it, message included:
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
//!   cleanup debt ledger with the exact action that failed, and
//!   `cleanupDebt.list` lists both;
//! - an empty HiLog capture, which parks its Job with its intent outstanding;
//! - the continuations, with the fake answering normally: the bundle's then
//!   the path's. Each Job is loaded as restart recovery loads it (its record
//!   marked `recovered: journal clean`), the readback finds the residue still
//!   there, the one retry is made durable and uninstalls or removes it under
//!   the use the Job consumed, and the debt is settled and the list empty.
//!
//! The fake receives Swift's 108 calls in order, and everything the replay
//! leaves below the root is Swift's byte for byte.
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
#![cfg(any(target_os = "macos", windows))]

mod support;

use arkdeck_hoststore::{HdcComposition, JobRecord};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use support::debug_hap;
use support::fixed_now;
use support::hdc_oracle::FakeDispatch;
use support::hdc_oracle::{self, Owners, exchange};

/// Every call Swift's runs and continuations made.
const CALLS: usize = 108;

#[test]
fn historical_terminal_digest_never_authorizes_run_or_compensation() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&debug_hap::NoDispatch);
    owners
        .admitter(&hdc, &owners.default_root)
        .handle(
            exchange(&cases, "stillRunning.submit")["params"]
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let job = cases["jobs"]["stillRunning"].as_str().unwrap();
    let mut record = support::document(&fixture, &format!("store/jobs/{job}/job-record.json"));
    record["admissionEvidence"]["runtimeCapabilityCorrelation"]["stepSetDigestSHA256"] =
        json!("e498f179320e17d223c85768dabed4a5d8719768b55ecf2ce8e70c1f83f9ac44");
    let decoded = JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap();
    owners
        .jobs
        .persist(&decoded, &fixed_now().unwrap())
        .unwrap();
    let record_before = fs::read(owners.job_file(job, "job-record.json")).unwrap();
    let journal_before = fs::read(owners.job_file(job, "journal.jsonl")).unwrap();
    let capability_before = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
    let publisher = owners.publisher();
    let refusal = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap_err();
    assert_eq!(refusal.code, "resourceConflict");
    assert!(refusal.message.contains("failed, not runnable"));
    assert!(owners.calls().is_empty());
    assert_eq!(
        fs::read(owners.job_file(job, "job-record.json")).unwrap(),
        record_before
    );
    assert_eq!(
        fs::read(owners.job_file(job, "journal.jsonl")).unwrap(),
        journal_before
    );
    assert_eq!(
        debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
        capability_before
    );
}

/// Every recorded request, answered in order by the Rust owners. Every
/// answer must be Swift's, its message included, and so must each call the
/// fake received, the Target document and everything the replay leaves below
/// the root.
#[test]
fn rust_runs_every_swift_debug_hap_as_swift_does() {
    // The immutable Swift recipe, re-recorded under the current full Catalog.
    // Historical terminal/held authority remains separately refused above.
    hdc_oracle::assert_replays(hdc_oracle::hap_current::fixture_name(), 63, CALLS);
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
    // Swift's evidence in this host's plan digest and capability (the same
    // on macOS; see `debug_hap::HostLabels`).
    let mut labels = debug_hap::HostLabels::default();
    labels.learn_keys(&record, &swift, &["materializedPlanDigest", "capabilityId"]);
    record["admissionEvidence"] = labels.host_json(&swift["admissionEvidence"]);
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
    inner: &'a FakeDispatch,
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
    // A second run continues the lane as Swift's does, under the use the Job
    // holds; the tool still cannot be proved, so again nothing is
    // dispatched, the refusal is thrown past the lane and the Job stays
    // `finalizing` with its use pending.
    let calls = owners.calls();
    let again = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap_err();
    assert_eq!(
        (again.code, again.message.as_str()),
        (
            "internalError",
            "the Runtime could not complete the Job lifecycle request"
        )
    );
    assert_eq!(owners.calls(), calls);
    assert_eq!(owners.record(&job)["state"], "finalizing");
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    assert!(!journal.contains("compensationIntent"), "{journal}");
    assert_eq!(uses(&owners), 1, "no second use is consumed");
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
    inner: &'a FakeDispatch,
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
    _lock: debug_hap::Exclusive,
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
    assert_eq!(
        status["sessionPublication"]["state"], "published",
        "{status}"
    );
    let manifest: Value = serde_json::from_slice(
        &fs::read(
            owners
                .root
                .join("Sessions/2026/09")
                .join(format!("session-{job}"))
                .join("manifest.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["status"], "failed");
    assert_eq!(manifest["executionAuthority"], "standardAgent");
    assert_eq!(manifest["toolchain"]["kind"], "runtimeProvider");
    assert_eq!(manifest.get("runtimeAuthority"), Some(&Value::Null));
    assert!(manifest["compensations"].as_array().unwrap().is_empty());
    assert_eq!(manifest["steps"].as_array().unwrap().len(), 3);
}

/// Reproduce the previously deployed producer's retained pre-consume failure
/// entirely in the isolated oracle store. The original Job remains failed;
/// only its proved unbound publication is retried, never the provider.
fn retained_preconsume_failure(owners: &Owners, cases: &Value) -> String {
    let hdc = owners.hdc(&owners.dispatch);
    let publisher = owners.publisher();
    let job = admitted(owners, &hdc, cases, "normal");
    let mut runner = owners.runner(&hdc, &publisher, false);
    runner.sessions = None;
    assert_eq!(
        runner
            .handle(json!({"jobId": job}).as_object().unwrap())
            .unwrap()["state"],
        "failed"
    );
    let mut record = owners.record(&job);
    record["sessionPublicationRecord"] = json!({
        "sessionID": format!("session-{job}"), "catalogDigest": arkdeck_contract::CATALOG_DIGEST,
        "policyGeneration": "0", "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
        "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
        "failure": {"code": "sourceIntegrityFailed", "certainty": "confirmed", "detail": "isolated pre-consume fixture"},
    });
    owners
        .jobs
        .persist(
            &JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
            &fixed_now().unwrap(),
        )
        .unwrap();
    job
}

fn publication_reconcile(owners: &Owners, job: &str) -> Result<Value, arkdeck_contract::WireError> {
    let publisher = owners.publisher();
    arkdeck_hoststore::JobReconciler {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
        imports: None,
        now: fixed_now,
        sessions: Some(&publisher),
        hdc: None,
        capabilities: None,
        runner: None,
    }
    .handle(json!({"jobId": job}).as_object().unwrap())
}

#[test]
fn retained_preconsume_hap_failure_republishes_without_provider_or_authority_writes() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let job = retained_preconsume_failure(&owners, &cases);
    let imports =
        arkdeck_hoststore::ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
    let target =
        support::document(&fixture.join("targets-state"), "targets.json")["targets"][0].clone();
    let receipt = debug_hap::import_package(
        &imports,
        &owners.artifacts,
        "independent",
        target["targetID"].as_str().unwrap(),
        1,
        target["stablePhysicalIdentitySHA256"].as_str().unwrap(),
        &fixed_now().unwrap(),
    );
    let inspection = || {
        imports.lifecycle_resource(
            &owners.artifacts,
            &owners.jobs,
            "artifact.import.inspection",
            json!({"importId": receipt["importId"]})
                .as_object()
                .unwrap(),
            &fixed_now().unwrap(),
        )
    };
    assert_eq!(inspection().unwrap_err().code, "recordUnreadable");
    let journal_before = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
    let record_before = owners.record(&job);
    let calls_before = owners.calls();
    let capabilities_before = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
    let status = publication_reconcile(&owners, &job).unwrap();
    assert_eq!(status["state"], "failed");
    assert_eq!(
        status["sessionPublication"]["state"], "published",
        "{status}"
    );
    let after = owners.record(&job);
    for key in [
        "request",
        "admissionEvidence",
        "operationFailure",
        "outcomeUnknown",
        "residues",
        "evidenceObservation",
    ] {
        assert_eq!(after[key], record_before[key], "{key}");
    }
    let journal_after = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
    assert!(journal_after.starts_with(&journal_before));
    let appended = &journal_after[journal_before.len()..];
    let finalized: Value = serde_json::from_slice(appended.strip_suffix(b"\n").unwrap()).unwrap();
    assert_eq!(finalized["kind"], "finalized");
    assert_eq!(finalized["payload"]["terminalStatus"], "failed");
    assert_eq!(inspection().unwrap()["references"]["state"], "clear");
    let persisted = fs::read(owners.job_file(&job, "job-record.json")).unwrap();
    assert_eq!(publication_reconcile(&owners, &job).unwrap(), status);
    assert_eq!(
        fs::read(owners.job_file(&job, "journal.jsonl")).unwrap(),
        journal_after
    );
    assert_eq!(
        fs::read(owners.job_file(&job, "job-record.json")).unwrap(),
        persisted
    );
    assert_eq!(owners.calls(), calls_before);
    assert_eq!(
        debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
        capabilities_before
    );
    assert_eq!(uses(&owners), 0);
}

#[test]
fn retained_preconsume_publication_refuses_changed_owners_and_unproved_journals() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    for scenario in [
        "diskDrift",
        "keptJobRecord",
        "torn",
        "foreign",
        "mutation",
        "partialPreflight",
        "failedPreflight",
        "observation",
        "toolDrift",
        "observationTime",
        "confirmedTime",
        "recovery",
        "proposal",
        "receipt",
    ] {
        let owners = Owners::open(&fixture);
        let job = retained_preconsume_failure(&owners, &cases);
        let mut record = owners.record(&job);
        let path = owners.job_file(&job, "journal.jsonl");
        let mut events: Vec<Value> = fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        match scenario {
            "diskDrift" => {
                record["timeline"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!("contradictory disk owner"));
                fs::write(
                    owners.job_file(&job, "job-record.json"),
                    serde_json::to_vec(&record).unwrap(),
                )
                .unwrap();
            }
            "keptJobRecord" => {
                fs::hard_link(
                    owners.job_file(&job, "job-record.json"),
                    owners.job_file(&job, ".job-record.json.replaced"),
                )
                .unwrap();
            }
            "torn" => {
                use std::io::Write;
                fs::OpenOptions::new()
                    .append(true)
                    .open(&path)
                    .unwrap()
                    .write_all(b"{torn")
                    .unwrap();
            }
            "foreign" => {
                for event in &mut events {
                    event["jobId"] = json!("job-foreign");
                    event["sessionId"] = json!("session-job-foreign");
                }
            }
            "mutation" => {
                events[3]["payload"]["step"]["effect"] = json!("deviceMutation");
            }
            "partialPreflight" => {
                events.drain(5..9);
            }
            "failedPreflight" => {
                events[6]["payload"]["result"] = json!("failed");
            }
            "observation" => {
                record["evidenceObservation"]["toolSHA256"] = json!("not-a-digest");
            }
            "toolDrift" => {
                record["evidenceObservation"]["toolSHA256"] = json!("a".repeat(64));
            }
            "observationTime" => {
                record["evidenceObservation"]["preflightSteps"][0]["outcomeAtUTC"] =
                    json!("2026-09-14T00:00:01Z");
            }
            "confirmedTime" => {
                record["evidenceObservation"]["confirmedAtUTC"] = json!("2026-09-14T00:00:01Z");
            }
            "recovery" => {
                record["recoveryStepID"] = json!("confirm-evidence-target");
            }
            "proposal" => {
                fs::write(
                    owners.job_file(&job, "session-manifest.proposal.json"),
                    b"{}",
                )
                .unwrap();
            }
            "receipt" => {
                record["sessionPublicationRecord"]["receipt"] = json!({"manifestSHA256": "a".repeat(64), "catalogGeneration": "1", "publishedAtUTC": fixed_now().unwrap()});
            }
            _ => unreachable!(),
        }
        if ["foreign", "mutation", "partialPreflight", "failedPreflight"].contains(&scenario) {
            for (sequence, event) in events.iter_mut().enumerate() {
                event["sequence"] = json!(sequence);
            }
            fs::write(
                &path,
                events
                    .iter()
                    .map(|event| format!("{}\n", serde_json::to_string(event).unwrap()))
                    .collect::<String>(),
            )
            .unwrap();
        }
        if [
            "observation",
            "toolDrift",
            "observationTime",
            "confirmedTime",
            "recovery",
            "receipt",
        ]
        .contains(&scenario)
        {
            owners
                .jobs
                .persist(
                    &JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
                    &fixed_now().unwrap(),
                )
                .unwrap();
        }
        let record_before = fs::read(owners.job_file(&job, "job-record.json")).unwrap();
        let journal_before = fs::read(&path).unwrap();
        let job_tree_before =
            debug_hap::tree_bytes(owners.job_file(&job, "job-record.json").parent().unwrap());
        let calls_before = owners.calls();
        let capabilities_before = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
        let answer = publication_reconcile(&owners, &job);
        assert!(
            match &answer {
                Err(_) => true,
                Ok(status) =>
                    status["sessionPublication"]["state"] != "published" || scenario == "receipt",
            },
            "{scenario}: {answer:?}"
        );
        assert_eq!(
            fs::read(owners.job_file(&job, "job-record.json")).unwrap(),
            record_before,
            "{scenario}"
        );
        assert_eq!(fs::read(&path).unwrap(), journal_before, "{scenario}");
        assert_eq!(
            debug_hap::tree_bytes(owners.job_file(&job, "job-record.json").parent().unwrap()),
            job_tree_before,
            "{scenario}"
        );
        assert_eq!(owners.calls(), calls_before, "{scenario}");
        assert_eq!(
            debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
            capabilities_before,
            "{scenario}"
        );
        assert!(
            !owners
                .root
                .join("Sessions/2026/09")
                .join(format!("session-{job}"))
                .exists(),
            "{scenario}"
        );
    }
}

#[test]
fn retained_preconsume_publication_requires_whole_unconsumed_capability_history() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    for scenario in [
        "pending",
        "settled",
        "torn",
        "malformed",
        "missingCheckpoint",
        "missingLock",
        "keptCheckpoint",
        "keptLedger",
    ] {
        let owners = Owners::open(&fixture);
        let job = retained_preconsume_failure(&owners, &cases);
        let store = owners.default_root.join("capabilities");
        if ["pending", "settled"].contains(&scenario) {
            let record = owners.record(&job);
            assert!(record["admissionEvidence"].is_null());
            let checkpoint: Value =
                serde_json::from_slice(&fs::read(store.join("runtime-capabilities.json")).unwrap())
                    .unwrap();
            let capability = &checkpoint["records"][0]["capability"];
            let query = arkdeck_hoststore::CapabilityQuery {
                operation_id: "debug.hap".into(),
                operation_version: Some(1),
                effect: arkdeck_hoststore::WorkflowEffect::DeviceMutation,
                target_stable_identity_sha256:
                    record["evidenceObservation"]["stableIdentitySHA256"]
                        .as_str()
                        .map(str::to_owned),
                target_binding_revision: Some(1),
                plan_digest: record["materializedPlanDigest"].as_str().map(str::to_owned),
                inputs: capability["exactInputs"].as_object().unwrap().clone(),
                artifact_facts: capability["exactArtifactFacts"]
                    .as_object()
                    .map(|facts| {
                        facts
                            .iter()
                            .map(|(name, value)| (name.clone(), value.as_str().unwrap().to_owned()))
                            .collect()
                    })
                    .unwrap_or_default(),
                workspace_identity_sha256: None,
                workspace_revision: None,
                workspace_file_scopes_digest: None,
            };
            let consumed = owners
                .capabilities
                .consume(
                    capability["capabilityID"].as_str().unwrap(),
                    record["request"]["idempotencyKey"].as_str().unwrap(),
                    Some(&job),
                    &query,
                    &fixed_now().unwrap(),
                )
                .unwrap();
            if scenario == "settled" {
                owners
                    .capabilities
                    .record_outcome(
                        &consumed.capability_id,
                        &consumed.reservation_id,
                        &job,
                        arkdeck_hoststore::CapabilityUseOutcome::SafeToReflash,
                        "failed",
                        &fixed_now().unwrap(),
                    )
                    .unwrap();
            }
        } else {
            match scenario {
                "torn" => fs::write(store.join("runtime-capabilities.ledger"), b"{torn").unwrap(),
                "malformed" => {
                    fs::write(store.join("runtime-capabilities.ledger"), b"{}\n").unwrap()
                }
                "missingCheckpoint" => {
                    fs::remove_file(store.join("runtime-capabilities.json")).unwrap()
                }
                "missingLock" => fs::remove_file(store.join(".runtime-capabilities.lock")).unwrap(),
                "keptCheckpoint" => {
                    fs::hard_link(
                        store.join("runtime-capabilities.json"),
                        store.join(".runtime-capabilities.json.replaced"),
                    )
                    .unwrap();
                }
                "keptLedger" => {
                    fs::write(store.join("runtime-capabilities.ledger"), b"").unwrap();
                    fs::hard_link(
                        store.join("runtime-capabilities.ledger"),
                        store.join(".runtime-capabilities.ledger.replaced"),
                    )
                    .unwrap();
                }
                _ => unreachable!(),
            }
        }
        let record_before = fs::read(owners.job_file(&job, "job-record.json")).unwrap();
        let journal_before = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
        let calls_before = owners.calls();
        let capability_before = debug_hap::tree_bytes(&store);
        assert!(publication_reconcile(&owners, &job).is_err(), "{scenario}");
        assert_eq!(
            fs::read(owners.job_file(&job, "job-record.json")).unwrap(),
            record_before,
            "{scenario}"
        );
        assert_eq!(
            fs::read(owners.job_file(&job, "journal.jsonl")).unwrap(),
            journal_before,
            "{scenario}"
        );
        assert_eq!(owners.calls(), calls_before, "{scenario}");
        assert_eq!(
            debug_hap::tree_bytes(&store),
            capability_before,
            "{scenario}"
        );
    }
}

#[test]
fn concurrent_preconsume_retries_keep_one_receipt_and_restart_does_not_republish() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let job = retained_preconsume_failure(&owners, &cases);
    let calls_before = owners.calls();
    let barrier = std::sync::Barrier::new(2);
    let (left, right) = std::thread::scope(|scope| {
        let run = || {
            barrier.wait();
            publication_reconcile(&owners, &job).unwrap()
        };
        let left = scope.spawn(run);
        let right = scope.spawn(run);
        (left.join().unwrap(), right.join().unwrap())
    });
    assert_eq!(left, right);
    assert_eq!(left["sessionPublication"]["state"], "published");
    let before = debug_hap::tree_bytes(&owners.root.join("Sessions"));
    let journal = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
    assert_eq!(
        String::from_utf8_lossy(&journal)
            .matches("\"kind\":\"finalized\"")
            .count(),
        1
    );
    assert_eq!(owners.calls(), calls_before);
    let root = owners.root.clone();
    let state = owners.default_root.clone();
    drop(owners);
    let jobs = arkdeck_hoststore::JobStore::open_owner(&state).unwrap();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let answer = arkdeck_hoststore::JobReconciler {
        jobs: &jobs,
        artifacts: &artifacts,
        imports: None,
        now: fixed_now,
        sessions: None,
        hdc: None,
        capabilities: None,
        runner: None,
    }
    .handle(json!({"jobId": job}).as_object().unwrap())
    .unwrap();
    assert_eq!(answer, left);
    assert_eq!(debug_hap::tree_bytes(&root.join("Sessions")), before);
    assert_eq!(
        fs::read(state.join("jobs").join(&job).join("journal.jsonl")).unwrap(),
        journal
    );
    assert_eq!(
        fs::read_to_string(root.join("hdc-invocations.log")).unwrap(),
        calls_before
    );
}

/// A deterministic one-second boundary between fresh evidence and the actual
/// capability consumption. Only the in-process oracle is used on Windows.
static PUBLICATION_ADMITTED: AtomicBool = AtomicBool::new(false);

fn publication_now() -> Option<String> {
    Some(
        if PUBLICATION_ADMITTED.load(Ordering::SeqCst) {
            "2026-09-14T00:00:01Z"
        } else {
            "2026-09-14T00:00:00Z"
        }
        .into(),
    )
}

fn consumed_publication_reconcile(
    owners: &Owners,
    job: &str,
) -> Result<Value, arkdeck_contract::WireError> {
    let publisher = owners.publisher();
    arkdeck_hoststore::JobReconciler {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
        imports: None,
        now: publication_now,
        sessions: Some(&publisher),
        hdc: None,
        capabilities: None,
        runner: None,
    }
    .handle(json!({"jobId": job}).as_object().unwrap())
}

struct PublicationClockDispatch<'a>(&'a FakeDispatch);

impl HdcDispatch for PublicationClockDispatch<'_> {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.0.dispatch(plan)
    }

    fn mutation_identity_current(&self) -> bool {
        let current = self.0.mutation_identity_current();
        PUBLICATION_ADMITTED.store(true, Ordering::SeqCst);
        current
    }
}

/// Run a real fixture through the production admission and fake provider,
/// retaining only its failed publication as an older producer did. The
/// consumed capability record is never edited or reconstructed.
fn retained_consumed_hap(owners: &Owners, cases: &Value, mode: &str) -> String {
    PUBLICATION_ADMITTED.store(false, Ordering::SeqCst);
    let dispatch = PublicationClockDispatch(&owners.dispatch);
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let job = admitted(owners, &hdc, cases, mode);
    let mut runner = owners.runner(&hdc, &publisher, true);
    runner.now = publication_now;
    runner.sessions = None;
    let status = runner
        .handle(json!({"jobId": job}).as_object().unwrap())
        .unwrap();
    assert_eq!(
        status["state"],
        if mode == "normal" {
            "succeeded"
        } else {
            "failed"
        },
        "{status}"
    );
    assert_eq!(status["outcomeUnknown"], false);
    let mut record = owners.record(&job);
    assert_eq!(
        record["evidenceObservation"]["confirmedAtUTC"],
        "2026-09-14T00:00:00Z"
    );
    assert_eq!(
        record["admissionEvidence"]["admittedAtUTC"],
        "2026-09-14T00:00:01Z"
    );
    record["sessionPublicationRecord"] = json!({
        "sessionID": format!("session-{job}"), "catalogDigest": record["catalogDigest"],
        "policyGeneration": "0", "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
        "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
        "failure": {"code": "sourceIntegrityFailed", "certainty": "confirmed", "detail": "isolated consumed HAP publication fixture"},
    });
    owners
        .jobs
        .persist(
            &JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
            &publication_now().unwrap(),
        )
        .unwrap();
    job
}

#[test]
fn fresh_evidence_before_consumption_publishes_only_the_known_terminal_hap() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    for mode in ["normal", "startFailed"] {
        let owners = Owners::open(&fixture);
        let job = retained_consumed_hap(&owners, &cases, mode);
        let before = owners.record(&job);
        let journal_before = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
        let capabilities = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
        let calls = owners.calls();
        let imports =
            arkdeck_hoststore::ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
        let receipt = debug_hap::import_package(
            &imports,
            &owners.artifacts,
            "publication-census",
            "TGT-ISOLATED-IMPORT",
            1,
            &"a".repeat(64),
            &fixed_now().unwrap(),
        );
        let inspect = || {
            imports.lifecycle_resource(
                &owners.artifacts,
                &owners.jobs,
                "artifact.import.inspection",
                json!({"importId": receipt["importId"]})
                    .as_object()
                    .unwrap(),
                &fixed_now().unwrap(),
            )
        };
        assert_eq!(inspect().unwrap_err().code, "recordUnreadable");
        let status = consumed_publication_reconcile(&owners, &job).unwrap();
        assert_eq!(status["state"], before["state"]);
        assert_eq!(
            status["sessionPublication"]["state"], "published",
            "{status}"
        );
        let mut after = owners.record(&job);
        let published = after["sessionPublicationRecord"].clone();
        after["sessionPublicationRecord"] = before["sessionPublicationRecord"].clone();
        assert_eq!(after, before);
        let session = owners
            .root
            .join("Sessions")
            .join(published["relativeSessionPath"].as_str().unwrap());
        let manifest = support::document(&session, "manifest.json");
        assert_eq!(
            manifest["runtimeAuthority"]["admittedAtUtc"],
            before["admissionEvidence"]["admittedAtUTC"]
        );
        assert_eq!(
            manifest["runtimeAuthority"]["planDigest"],
            before["materializedPlanDigest"]
        );
        let journal_after = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
        assert!(journal_after.starts_with(&journal_before));
        let finalized: Value = serde_json::from_slice(
            journal_after[journal_before.len()..]
                .strip_suffix(b"\n")
                .unwrap(),
        )
        .unwrap();
        assert_eq!(finalized["kind"], "finalized");
        assert_eq!(finalized["timestamp"], publication_now().unwrap());
        assert_eq!(finalized["payload"]["terminalStatus"], before["state"]);
        assert_eq!(inspect().unwrap()["references"]["state"], "clear");
        let persisted = fs::read(owners.job_file(&job, "job-record.json")).unwrap();
        let repeat = consumed_publication_reconcile(&owners, &job);
        if before["state"] == "failed" {
            // Failure lineage repair remains outside the HAP retry lane.
            // The settled Session is retained without touching that authority.
            assert_eq!(repeat.unwrap_err().code, "rejected");
        } else {
            assert_eq!(repeat.unwrap(), status);
        }
        assert_eq!(
            fs::read(owners.job_file(&job, "job-record.json")).unwrap(),
            persisted
        );
        assert_eq!(
            fs::read(owners.job_file(&job, "journal.jsonl")).unwrap(),
            journal_after
        );
        assert_eq!(owners.calls(), calls);
        assert_eq!(
            debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
            capabilities
        );
    }
}

#[test]
fn consumed_hap_publication_refuses_late_missing_expired_or_uncertain_authority() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    for scenario in [
        "mutationBeforeAdmission",
        "compensationBeforeAdmission",
        "missingAudit",
        "expired",
        "planDrift",
        "missingReservation",
        "missingFingerprint",
        "unknown",
        "torn",
    ] {
        let owners = Owners::open(&fixture);
        let job = retained_consumed_hap(
            &owners,
            &cases,
            if scenario == "compensationBeforeAdmission" {
                "startFailed"
            } else {
                "normal"
            },
        );
        let path = owners.job_file(&job, "journal.jsonl");
        let mut record = owners.record(&job);
        match scenario {
            "mutationBeforeAdmission" | "compensationBeforeAdmission" => {
                let mut events: Vec<Value> = fs::read_to_string(&path)
                    .unwrap()
                    .lines()
                    .map(|line| serde_json::from_str(line).unwrap())
                    .collect();
                let intent = events
                    .iter_mut()
                    .find(|event| {
                        if scenario == "compensationBeforeAdmission" {
                            event["kind"] == "compensationIntent"
                        } else {
                            event["kind"] == "stepIntent"
                                && event["payload"]["step"]["effect"] == "deviceMutation"
                        }
                    })
                    .unwrap();
                intent["timestamp"] = json!("2026-09-14T00:00:00Z");
                fs::write(
                    &path,
                    events
                        .iter()
                        .map(|event| format!("{}\n", serde_json::to_string(event).unwrap()))
                        .collect::<String>(),
                )
                .unwrap();
            }
            "missingAudit" => {
                record.as_object_mut().unwrap().remove("admissionEvidence");
            }
            "expired" => {
                record["admissionEvidence"]["validUntilUTC"] =
                    record["admissionEvidence"]["admittedAtUTC"].clone();
            }
            "planDrift" => {
                record["admissionEvidence"]["runtimeCapabilityCorrelation"]["planDigestSHA256"] =
                    json!("a".repeat(64));
            }
            "missingReservation" => {
                record["admissionEvidence"]["runtimeCapabilityCorrelation"]["reservationID"] =
                    Value::Null;
            }
            "missingFingerprint" => {
                record["admissionEvidence"]["consumptionFingerprintSHA256"] = Value::Null;
            }
            "unknown" => {
                record["outcomeUnknown"] = json!(true);
            }
            "torn" => {
                use std::io::Write;
                fs::OpenOptions::new()
                    .append(true)
                    .open(&path)
                    .unwrap()
                    .write_all(b"{torn")
                    .unwrap();
            }
            _ => unreachable!(),
        }
        let source_tree = debug_hap::tree_bytes(path.parent().unwrap());
        let source_calls = owners.calls();
        let source_capabilities = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
        let decoded = match JobRecord::decode(&serde_json::to_vec(&record).unwrap()) {
            Ok(record) => record,
            Err(error) => {
                assert!(
                    ["planDrift", "missingReservation", "missingFingerprint"].contains(&scenario),
                    "{scenario}: {error:?}"
                );
                assert_eq!(error.code, "recordUnreadable", "{scenario}");
                assert_eq!(debug_hap::tree_bytes(path.parent().unwrap()), source_tree);
                assert_eq!(owners.calls(), source_calls);
                assert_eq!(
                    debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
                    source_capabilities
                );
                continue;
            }
        };
        owners
            .jobs
            .persist(&decoded, &publication_now().unwrap())
            .unwrap();
        let before = owners.record(&job);
        let journal = fs::read(&path).unwrap();
        let capabilities = debug_hap::tree_bytes(&owners.default_root.join("capabilities"));
        let calls = owners.calls();
        let result = consumed_publication_reconcile(&owners, &job);
        assert!(
            (result.is_err()
                || result
                    .as_ref()
                    .is_ok_and(|status| status["sessionPublication"]["state"] != "published")),
            "{scenario}: {result:?}"
        );
        let mut after = owners.record(&job);
        after["sessionPublicationRecord"] = before["sessionPublicationRecord"].clone();
        assert_eq!(after, before, "{scenario}");
        assert_eq!(fs::read(&path).unwrap(), journal, "{scenario}");
        assert!(
            !owners
                .job_file(&job, "session-manifest.proposal.json")
                .exists(),
            "{scenario}"
        );
        assert_eq!(owners.calls(), calls, "{scenario}");
        assert_eq!(
            debug_hap::tree_bytes(&owners.default_root.join("capabilities")),
            capabilities,
            "{scenario}"
        );
    }
}
