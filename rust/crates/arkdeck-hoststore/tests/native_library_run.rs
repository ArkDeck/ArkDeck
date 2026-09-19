//! Replays the Swift native-library oracle
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC) through the
//! production Rust planner, admitter, runner, result reader and capability
//! reads, under the durable mutation authority the pointer, port-rule and
//! debug HAP replays run under, and its cleanup debt list, up to its cleanup
//! debt continuation (`cleanupDebt.continue`, not served by this Runtime).
//! Every exchange but it and the list after it answers as Swift answered it,
//! message included:
//! - the deployments. The library is verified on the host, sent into the
//!   Job's owned staging with the code-sign helper and believed only through
//!   its staging readback, backed up, published by the helper with its
//!   fs-verity attestation or, replacing a library that had none, without
//!   one, the application restarted and the library found in its maps, then
//!   the staging and the backup removed;
//! - the failures. A library the loader does not map is rolled back from its
//!   backup, and a target without its app-owned directory fails at the backup
//!   with nothing to roll back. Each Job then removes what it staged and
//!   fails with its original failure;
//! - the debt. A cleanup that removes nothing is skipped and owed in the
//!   cleanup debt ledger with the exact action that failed, and its Job
//!   succeeds with the residue counted; `cleanupDebt.list` lists it.
//!
//! Each Job consumes its one capability use before its send, every later
//! mutation and the compensations run under it, and it is settled with the
//! Job. The fake receives Swift's first 210 calls in order (the rest are the
//! continuation's), and everything the replay leaves below the root is
//! Swift's byte for byte: the four Jobs the continuation does not touch with
//! their persist counts, the one it settles as it stood before it, and the
//! ledger without its settlement members.
//!
//! Three more tests fault what no oracle records, each on the loader failure
//! the oracle does record: a rollback that does not restore the previous
//! library fails its Job with the rollback's failure and removes nothing
//! more, a compensation cleanup that leaves the staging owes its debt while
//! the Job fails with its original failure, and one whose outcome is lost
//! owes its debt and parks the Job with its intent outstanding. Every
//! transport byte comes from the shared fake HDC; none of this is hardware
//! acceptance. The runs spawn the fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::time::Duration;
use support::debug_hap;
use support::hdc_oracle::{self, Owners, exchange};

/// The fake's calls Swift's runs made before its continuation.
const CALLS: usize = 210;
/// The run whose debt the continuation settles.
const CONTINUED: [&str; 1] = ["cleanupFailure"];
/// Every exchange but the continuation and the list after it: nine plans,
/// five submissions, five runs and a refused rerun, the three reads of each
/// Job, the list of the debt, and the two capability reads.
const EXCHANGES: usize = 38;

#[test]
fn rust_runs_every_swift_native_library_deployment_as_swift_does() {
    hdc_oracle::assert_replays_before_continuations(
        "deploy-native-library",
        &CONTINUED,
        EXCHANGES,
        CALLS,
    );
}

/// What a fault does to the one command it names: a rollback's move that
/// never happens, or a staging directory's removal that never happens or
/// whose outcome is lost.
#[derive(Clone, Copy)]
enum Fault {
    RollbackIneffective,
    CleanupIneffective,
    CleanupUnobserved,
}

/// The fake HDC with one command faulted; every other command reaches it.
struct Faulted<'a> {
    inner: &'a ProcessDispatch,
    fault: Fault,
}

impl HdcDispatch for Faulted<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let receipt = |exit_status| Receipt {
            exit_status,
            stdout: Vec::new(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::ZERO,
        };
        match (self.fault, plan.arguments.get(3).map(String::as_str)) {
            (Fault::RollbackIneffective, Some("mv")) => Ok(receipt(1)),
            (Fault::CleanupIneffective, Some("rmdir")) => Ok(receipt(0)),
            (Fault::CleanupUnobserved, Some("rmdir")) => Err(DispatchFailure::Unobservable(
                "dispatch outcome unobservable: the staging removal was lost".into(),
            )),
            _ => self.inner.dispatch(plan),
        }
    }
}

/// What a faulted loader-failure run leaves: the fixed root's lock, which
/// the caller keeps while it reads, the owners, the Job, its status and its
/// timeline from the loader's failure on.
struct Run {
    _lock: fs::File,
    owners: Owners,
    job: String,
    status: Value,
    tail: Vec<String>,
}

const LOADER_FAILURE: &str =
    "nativeLibraryNotLoaded: target process maps do not contain the published app-owned library";

/// The oracle's `loaderFailure` Job, admitted as Swift admitted it and run
/// while the fake answers in its mode, with `fault` on its compensation.
fn loader_failure_with(fault: Fault) -> Run {
    let lock = debug_hap::exclusive();
    let fixture = support::fixture("deploy-native-library");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = Faulted {
        inner: &owners.dispatch,
        fault,
    };
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    owners
        .admitter(&hdc, &owners.default_root)
        .handle(
            exchange(&cases, "loaderFailure.submit")["params"]
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let job = cases["jobs"]["loaderFailure"].as_str().unwrap().to_owned();
    owners.mode("loaderFailure");
    let status = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    let timeline: Vec<String> = owners.record(&job)["timeline"]
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line.as_str().unwrap().to_owned())
        .collect();
    let failed = format!("failed verify-loaded-library: {LOADER_FAILURE}");
    let from = timeline.iter().position(|line| *line == failed).unwrap();
    Run {
        _lock: lock,
        tail: timeline[from..].to_vec(),
        owners,
        job,
        status,
    }
}

/// The outcome the Job's one use was settled with.
fn settled(owners: &Owners, job: &str) -> (Value, Value) {
    let record = owners.record(job);
    let capability = record["admissionEvidence"]["reference"].as_str().unwrap();
    let inspected = owners
        .capabilities
        .handle(
            "capability.inspect",
            &Map::from_iter([("capabilityId".into(), json!(capability))]),
        )
        .unwrap();
    let outcome = &inspected["lineage"][0]["outcomeHistory"][0];
    (outcome["outcome"].clone(), outcome["terminalState"].clone())
}

/// A rollback that does not restore the previous library is the Job's
/// failure: nothing more is removed, and nothing is owed.
#[test]
fn a_rollback_that_fails_fails_its_job_and_removes_nothing_more() {
    let Run {
        _lock,
        owners,
        job,
        status,
        tail,
    } = loader_failure_with(Fault::RollbackIneffective);
    assert_eq!(status["state"], "failed");
    let rollback = tail
        .iter()
        .find_map(|line| line.strip_prefix("failed rollback-native-library: "))
        .unwrap()
        .to_owned();
    assert!(
        rollback.starts_with("nativeRollbackVerificationFailed: "),
        "{rollback}"
    );
    let quoted = serde_json::to_string(&rollback).unwrap();
    assert_eq!(
        tail,
        [
            format!("failed verify-loaded-library: {LOADER_FAILURE}"),
            "intent rollback-native-library".into(),
            format!("failed rollback-native-library: {rollback}"),
            format!("native rollback failed closed: failed({quoted})"),
            "running->finalizing".into(),
            format!("reason: {rollback}"),
            "finalizing->failed".into(),
            format!("reason: {rollback}"),
        ]
    );
    let calls = owners.calls();
    assert!(!calls.contains("rmdir"), "{calls}");
    assert!(!owners.root.join("artifacts/cleanup-debt.json").exists());
    assert_eq!(
        settled(&owners, &job),
        (json!("confirmed"), json!("failed"))
    );
}

/// A compensation cleanup that leaves the staging is owed in the ledger with
/// the exact action that failed, the residue is counted, and the Job fails
/// with its original failure.
#[test]
fn a_compensation_cleanup_that_fails_is_owed_and_its_job_keeps_its_failure() {
    let Run {
        _lock,
        owners,
        job,
        status,
        tail,
    } = loader_failure_with(Fault::CleanupIneffective);
    assert_eq!(
        (&status["state"], &status["outstandingResidueCount"]),
        (&json!("failed"), &json!(1))
    );
    let debt = "cleanupDebt: native staging or backup path remains after cleanup";
    let owed = format!("failed({})", serde_json::to_string(debt).unwrap());
    assert_eq!(
        tail[tail.len() - 8..],
        [
            "intent cleanup-native-library-compensation".to_owned(),
            format!("failed cleanup-native-library-compensation: {debt}"),
            format!("native compensation cleanup debt: {owed}"),
            format!("native deployment failed: {LOADER_FAILURE}"),
            "running->finalizing".into(),
            format!("reason: {LOADER_FAILURE}"),
            "finalizing->failed".into(),
            format!("reason: {LOADER_FAILURE}"),
        ]
    );
    assert!(tail.contains(&"native deployment failure restored previous library".to_owned()));
    let ledger: Value =
        serde_json::from_slice(&fs::read(owners.root.join("artifacts/cleanup-debt.json")).unwrap())
            .unwrap();
    let records = ledger.as_array().unwrap();
    assert_eq!(records.len(), 1);
    let staging = format!(
        "/data/app/el2/100/base/com.example.demo/haps/entry/files/arkdeck-native/{job}/libexample.so.staging"
    );
    assert_eq!(
        (
            &records[0]["jobID"],
            &records[0]["stepID"],
            &records[0]["remotePath"],
            &records[0]["reason"],
            &records[0]["persistedAction"]["kind"],
        ),
        (
            &json!(job),
            &json!("cleanup-native-library-compensation"),
            &json!(staging),
            &json!(owed),
            &json!("hdc.cleanupNativeLibrary"),
        )
    );
    assert_eq!(
        settled(&owners, &job),
        (json!("confirmed"), json!("failed"))
    );
}

/// A compensation cleanup whose outcome is lost is owed, and its Job parks
/// with the cleanup's intent outstanding, never resent.
#[test]
fn a_compensation_cleanup_whose_outcome_is_lost_parks_its_job() {
    let Run {
        _lock,
        owners,
        job,
        status,
        tail,
    } = loader_failure_with(Fault::CleanupUnobserved);
    assert_eq!(
        (&status["state"], &status["outcomeUnknown"]),
        (&json!("waitingForRecovery"), &json!(true))
    );
    let lost = "dispatch outcome unobservable: the staging removal was lost";
    let owed = format!("outcomeUnknown({})", serde_json::to_string(lost).unwrap());
    assert_eq!(
        tail[tail.len() - 5..],
        [
            "intent cleanup-native-library-compensation".to_owned(),
            "outcomeUnknown cleanup-native-library-compensation; durable intent left outstanding"
                .into(),
            format!("native compensation cleanup debt: {owed}"),
            "running->waitingForRecovery".into(),
            format!("reason: outcomeUnknown: {lost}"),
        ]
    );
    let record = owners.record(&job);
    assert_eq!(
        record["recoveryStepID"],
        "cleanup-native-library-compensation"
    );
    let ledger: Value =
        serde_json::from_slice(&fs::read(owners.root.join("artifacts/cleanup-debt.json")).unwrap())
            .unwrap();
    assert_eq!(ledger[0]["reason"], json!(owed));
    assert_eq!(
        settled(&owners, &job),
        (json!("outcomeUnknown"), json!("waitingForRecovery"))
    );
}
