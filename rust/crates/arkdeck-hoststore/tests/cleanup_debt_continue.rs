//! What the oracles do not record of `cleanupDebt.continue`, each on a debt a
//! Job of the native-library oracle owes after running as Swift ran it over
//! the shared fake HDC (`rust/tests/fixtures/deploy-native-library`):
//! - a residue already gone is settled by its readback alone, never retried;
//! - a retry already begun, or one whose outcome was lost, forbids any
//!   resend, and a lost one keeps its outcome unknown;
//! - a retry the device refutes stays owed, clears its attempt, and may be
//!   retried;
//! - a readback that cannot run leaves the debt owed and sends nothing;
//! - a Job whose outcome is unknown is answered without a write;
//! - the parameters and the debt are proven before anything is read or
//!   sent, and without the mutation owner nothing is recovered or sent.
//!
//! The oracle replays (`debug_hap_run.rs`, `native_library_run.rs`) hold
//! every continuation Swift recorded. Every transport byte comes from the
//! shared fake HDC; none of this is hardware acceptance. The runs spawn the
//! fake, so this binary is theirs.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::list_cleanup_debt;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use support::debug_hap;
use support::hdc_oracle::{self, Owners, exchange};

/// What the continuation's transport does to the one command it names.
#[derive(Clone, Copy, PartialEq)]
enum Fault {
    None,
    /// Every `ls` is refused before it launches.
    ReadbackRefused,
    /// The first `rm` launches and its outcome is lost.
    RetryUnobserved,
    /// A compensation's `rmdir` launches and its outcome is lost.
    CompensationUnobserved,
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
        match (self.fault, plan.arguments.get(3).map(String::as_str)) {
            (Fault::ReadbackRefused, Some("ls")) => Err(DispatchFailure::Refused(
                "dispatch refused: the readback was not launched".into(),
            )),
            (Fault::RetryUnobserved, Some("rm")) => Err(DispatchFailure::Unobservable(
                "dispatch outcome unobservable: the removal was lost".into(),
            )),
            (Fault::CompensationUnobserved, Some("rmdir")) => Err(DispatchFailure::Unobservable(
                "dispatch outcome unobservable: the staging removal was lost".into(),
            )),
            _ => self.inner.dispatch(plan),
        }
    }
}

/// A Job of the oracle that owes its staging path, with the fixed root's
/// lock the caller keeps while it reads.
struct Owed {
    _lock: fs::File,
    owners: Owners,
    job: String,
    staging: String,
}

/// The oracle's `case` Job, admitted as Swift admitted it and run while the
/// fake answers in `mode`, with `fault` on its run.
fn owed_by(case: &str, mode: &str, fault: Fault) -> (Owed, Value) {
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
            exchange(&cases, &format!("{case}.submit"))["params"]
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let job = cases["jobs"][case].as_str().unwrap().to_owned();
    owners.mode(mode);
    let status = owners
        .runner(&hdc, &publisher, true)
        .handle(&Map::from_iter([("jobId".into(), json!(job))]))
        .unwrap();
    let staging = format!(
        "/data/app/el2/100/base/com.example.demo/haps/entry/files/arkdeck-native/{job}/\
         libexample.so.staging"
    );
    let owed = Owed {
        _lock: lock,
        owners,
        job,
        staging,
    };
    (owed, status)
}

/// The oracle's `cleanupFailure` Job: a cleanup that removed nothing, owed
/// by a Job that succeeded.
fn owed() -> Owed {
    let (owed, status) = owed_by("cleanupFailure", "cleanupFailure", Fault::None);
    assert_eq!(status["state"], "succeeded");
    owed
}

impl Owed {
    fn params(&self) -> Value {
        json!({"jobId": self.job, "remotePath": self.staging})
    }

    /// The debt continued while the fake answers in `mode` over what the
    /// runs left, with `fault` on the continuation's transport.
    fn continue_with(
        &self,
        mode: &str,
        fault: Fault,
        params: Value,
        owned: bool,
    ) -> Result<Value, WireError> {
        self.owners.set_mode(mode);
        let dispatch = Faulted {
            inner: &self.owners.dispatch,
            fault,
        };
        let hdc = self.owners.hdc(&dispatch);
        let publisher = self.owners.publisher();
        let answer = self
            .owners
            .runner(&hdc, &publisher, owned)
            .continue_cleanup_debt(params.as_object().unwrap());
        hdc_oracle::assert_conforms(
            "cleanupDebt.continue",
            &match &answer {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(error) => json!({"ok": false, "error": error}),
            },
        );
        answer
    }

    fn continued(&self, mode: &str, fault: Fault) -> Value {
        self.continue_with(mode, fault, self.params(), true)
            .unwrap()
    }

    fn answer(&self, state: &str, detail: &str) -> Value {
        json!({"jobId": self.job, "identity": self.staging, "state": state, "detail": detail})
    }

    fn ledger(&self) -> Vec<u8> {
        fs::read(self.owners.root.join("artifacts/cleanup-debt.json")).unwrap()
    }

    fn debt(&self) -> Value {
        let ledger: Vec<Value> = serde_json::from_slice(&self.ledger()).unwrap();
        ledger
            .into_iter()
            .find(|record| record["jobID"] == self.job.as_str())
            .unwrap()
    }

    fn calls(&self) -> Vec<String> {
        self.owners.calls().lines().map(str::to_owned).collect()
    }

    /// The fake's calls a continuation made after `before` of them.
    fn sent_since(&self, before: usize) -> Vec<String> {
        self.calls()[before..].to_vec()
    }

    fn record_bytes(&self) -> Vec<u8> {
        fs::read(self.owners.job_file(&self.job, "job-record.json")).unwrap()
    }
}

/// The program a recorded call ran on the device, with its one flag
/// (`ls -ld`, `rm -f`, `rmdir`): the fake records each argument after a unit
/// separator.
fn program(call: &str) -> String {
    let parts: Vec<&str> = call.split('\u{1f}').collect();
    let Some(shell) = parts.iter().position(|part| *part == "shell") else {
        return String::new();
    };
    match parts.get(shell + 1).copied() {
        Some("rmdir") => "rmdir".into(),
        Some(program) => format!(
            "{program}{}",
            parts.get(shell + 2).copied().unwrap_or_default()
        ),
        None => String::new(),
    }
}

fn programs(calls: &[String]) -> Vec<String> {
    calls.iter().map(|call| program(call)).collect()
}

const READBACK: [&str; 5] = ["ls-ld"; 5];
const RETRY: [&str; 10] = [
    "rm-f", "rm-f", "rmdir", "rm-f", "rm-f", "ls-ld", "ls-ld", "ls-ld", "ls-ld", "ls-ld",
];

#[test]
fn a_residue_already_gone_is_settled_by_its_readback_alone() {
    let owed = owed();
    // Every path the Job owned is gone from the device.
    for entry in fs::read_dir(&owed.owners.root).unwrap() {
        let name = entry.unwrap().file_name().into_string().unwrap();
        if name.starts_with("device-path-") && name.contains(&owed.job) {
            fs::remove_file(owed.owners.root.join(name)).unwrap();
        }
    }
    let before = owed.calls().len();
    assert_eq!(
        owed.continued("normal", Fault::None),
        owed.answer(
            "settled",
            "readback confirmed the owned path is already absent"
        )
    );
    assert_eq!(programs(&owed.sent_since(before)), READBACK);
    let debt = owed.debt();
    assert_eq!(debt["settledAtUTC"], "2026-09-14T00:00:00Z");
    assert!(debt.get("retryAttemptStartedAtUTC").is_none());
    let record = owed.owners.record(&owed.job);
    assert_eq!(record["outstandingResidueCount"], 0);
    assert_eq!(
        record["timeline"].as_array().unwrap().last().unwrap(),
        "recovered: journal clean"
    );
    assert_eq!(
        list_cleanup_debt(&owed.owners.artifacts).unwrap(),
        json!([])
    );
}

#[test]
fn an_earlier_retry_forbids_any_resend() {
    let owed = owed();
    let mut ledger: Vec<Value> = serde_json::from_slice(&owed.ledger()).unwrap();
    ledger[0]["retryAttemptStartedAtUTC"] = json!("2026-09-14T00:00:00Z");
    fs::write(
        owed.owners.root.join("artifacts/cleanup-debt.json"),
        serde_json::to_vec(&ledger).unwrap(),
    )
    .unwrap();
    let before = owed.calls().len();
    assert_eq!(
        owed.continued("normal", Fault::None),
        owed.answer(
            "outcomeUnknown",
            "earlier cleanup retry is outcomeUnknown; mutation resend is forbidden"
        )
    );
    assert_eq!(programs(&owed.sent_since(before)), READBACK);
    assert!(owed.debt().get("settledAtUTC").is_none());
    assert_eq!(
        list_cleanup_debt(&owed.owners.artifacts).unwrap()[0]["retryOutcomeUnknown"],
        true
    );
}

#[test]
fn a_retry_the_device_refutes_stays_owed_and_may_be_retried() {
    let owed = owed();
    let before = owed.calls().len();
    assert_eq!(
        owed.continued("cleanupFailure", Fault::None),
        owed.answer(
            "outstanding",
            "cleanupDebt: native staging or backup path remains after cleanup"
        )
    );
    let sent = owed.sent_since(before);
    assert_eq!(programs(&sent[..5]), READBACK);
    assert_eq!(programs(&sent[5..]), RETRY);
    // The attempt concluded: cleared, and its outcome known.
    let debt = owed.debt();
    assert_eq!(debt["retryOutcomeUnknown"], false);
    assert!(debt.get("retryAttemptStartedAtUTC").is_none());
    assert!(debt.get("settledAtUTC").is_none());
    assert_eq!(owed.owners.record(&owed.job)["outstandingResidueCount"], 1);
    // A refuted retry may be retried.
    assert_eq!(
        owed.continued("normal", Fault::None),
        owed.answer("settled", "exact typed cleanup completed")
    );
    assert_eq!(owed.owners.record(&owed.job)["outstandingResidueCount"], 0);
}

#[test]
fn a_retry_whose_outcome_is_lost_is_never_resent() {
    let owed = owed();
    let before = owed.calls().len();
    assert_eq!(
        owed.continued("normal", Fault::RetryUnobserved),
        owed.answer(
            "outcomeUnknown",
            "outcomeUnknown(\"dispatch outcome unobservable: the removal was lost\")"
        )
    );
    // The first removal never reached the device.
    assert_eq!(programs(&owed.sent_since(before)), READBACK);
    let debt = owed.debt();
    assert_eq!(debt["retryOutcomeUnknown"], true);
    assert_eq!(debt["retryAttemptStartedAtUTC"], "2026-09-14T00:00:00Z");
    let before = owed.calls().len();
    assert_eq!(
        owed.continued("normal", Fault::None),
        owed.answer(
            "outcomeUnknown",
            "earlier cleanup retry is outcomeUnknown; mutation resend is forbidden"
        )
    );
    assert_eq!(programs(&owed.sent_since(before)), READBACK);
    assert!(owed.debt().get("settledAtUTC").is_none());
}

#[test]
fn a_readback_that_cannot_run_leaves_the_debt_owed() {
    let owed = owed();
    let (ledger, before) = (owed.ledger(), owed.calls().len());
    assert_eq!(
        owed.continued("normal", Fault::ReadbackRefused),
        owed.answer(
            "outstanding",
            "path readback failed: failed(\"dispatch refused: the readback was not launched\")"
        )
    );
    assert!(owed.sent_since(before).is_empty());
    assert_eq!(owed.ledger(), ledger);
}

#[test]
fn a_job_whose_outcome_is_unknown_is_answered_without_a_write() {
    // The loader failure's compensation cleanup is lost: the Job parks, and
    // owes its staging.
    let (owed, status) = owed_by(
        "loaderFailure",
        "loaderFailure",
        Fault::CompensationUnobserved,
    );
    assert_eq!(
        (&status["state"], &status["outcomeUnknown"]),
        (&json!("waitingForRecovery"), &json!(true))
    );
    let (ledger, record, before) = (owed.ledger(), owed.record_bytes(), owed.calls().len());
    assert_eq!(
        owed.continued("normal", Fault::None),
        owed.answer(
            "outcomeUnknown",
            "job has an unresolved outcome; cleanup mutation is not resent"
        )
    );
    assert!(owed.sent_since(before).is_empty());
    assert_eq!(owed.ledger(), ledger);
    assert_eq!(owed.record_bytes(), record);
}

#[test]
fn the_parameters_and_the_debt_are_proven_first() {
    let owed = owed();
    let (ledger, record, before) = (owed.ledger(), owed.record_bytes(), owed.calls().len());
    let refused = |params: Value| {
        let error = owed
            .continue_with("normal", Fault::None, params, true)
            .unwrap_err();
        assert!(error.details.is_none());
        (error.code, error.message)
    };
    let required = (
        "invalidParams".to_owned(),
        "jobId and one of remotePath / bundleName are required".to_owned(),
    );
    assert_eq!(refused(json!({})), required);
    assert_eq!(refused(json!({"jobId": owed.job})), required);
    assert_eq!(
        refused(json!({"jobId": 1, "remotePath": owed.staging})),
        required
    );
    let missing = |identity: &str| {
        (
            "rejected".to_owned(),
            format!("jobNotFound(\"cleanup-debt:{}:{identity}\")", owed.job),
        )
    };
    assert_eq!(
        refused(json!({"jobId": owed.job, "remotePath": "/data/local/tmp/other"})),
        missing("/data/local/tmp/other")
    );
    // A bundle is its own ledger key, never an uninstall target.
    assert_eq!(
        refused(json!({"jobId": owed.job, "bundleName": "com.example.demo"})),
        missing("bundle:com.example.demo")
    );
    assert!(owed.sent_since(before).is_empty());
    assert_eq!(owed.ledger(), ledger);
    assert_eq!(owed.record_bytes(), record);
}

#[test]
fn without_the_mutation_owner_nothing_is_recovered_or_sent() {
    let owed = owed();
    let (ledger, record, before) = (owed.ledger(), owed.record_bytes(), owed.calls().len());
    let error = owed
        .continue_with("normal", Fault::None, owed.params(), false)
        .unwrap_err();
    assert_eq!(error.code, "rejected");
    assert!(
        error.message.contains("no capability store was given"),
        "{}",
        error.message
    );
    assert!(owed.sent_since(before).is_empty());
    assert_eq!(owed.ledger(), ledger);
    assert_eq!(owed.record_bytes(), record);
}
