//! Current native deployment observation and publication over the unchanged
//! Swift fixture inputs. Five scenarios retain all 225 original native
//! transport calls; a separate typed prefix supplies genuine synthetic
//! target/model/firmware readbacks before capability consumption and send.
//! Complete success and known failure/rollback paths publish their whole
//! Session and finalize once. Confirmed native cleanup failure remains a
//! failed executed step and a known failed Job, with its debt intact.
//! Fault tests preserve failed and unknown restoration/cleanup outcomes.
//! Synthetic transport only; no device or hardware acceptance is claimed.
#![cfg(any(target_os = "macos", windows))]

mod support;

use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::time::Duration;
use support::debug_hap;
use support::hdc_oracle::{self, Owners, exchange};
use support::native_observation::Observed;

/// Every call Swift's runs and its continuation made.
const CALLS: usize = 225;
#[test]
fn native_deployments_preserve_frozen_transport_and_publish_current_sessions() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("deploy-native-library");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let dispatch = Observed::new(&owners.dispatch);
    let hdc = owners.hdc(&dispatch);
    let publisher = owners.publisher();
    let runner = owners.runner(&hdc, &publisher, true);
    let imports =
        arkdeck_hoststore::ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
    let unrelated = debug_hap::import_package(
        &imports,
        &owners.artifacts,
        "native-publication-census",
        "TGT-ISOLATED-IMPORT",
        1,
        &"a".repeat(64),
        &support::fixed_now().unwrap(),
    );
    for name in [
        "deployed",
        "loaderFailure",
        "targetAbsent",
        "unattested",
        "cleanupFailure",
    ] {
        owners
            .admitter(&hdc, &owners.default_root)
            .handle(
                exchange(&cases, &format!("{name}.submit"))["params"]
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        owners.mode(name);
        let status = runner
            .handle(
                exchange(&cases, &format!("{name}.run"))["params"]
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        assert_eq!(
            status["state"],
            if name == "cleanupFailure" {
                json!("failed")
            } else {
                exchange(&cases, &format!("{name}.run"))["answer"]["result"]["state"].clone()
            }
        );
        assert_eq!(status["outcomeUnknown"], false);
        let job = cases["jobs"][name].as_str().unwrap();
        let record = owners.record(job);
        support::native_observation::assert_observation(&record, &owners.digest);
        if name == "cleanupFailure" {
            assert_eq!(status["outstandingResidueCount"], 1);
            assert!(
                owners.root.join("device-published").exists(),
                "verified replacement retained"
            );
            assert!(!record["timeline"].as_array().unwrap().iter().any(|line| {
                line.as_str().is_some_and(|line| {
                    line.contains("native deployment failure restored")
                        || line.starts_with("skipped cleanup-staging")
                })
            }));
        }
        assert_eq!(
            record["sessionPublicationRecord"]["phase"], "catalogPublished",
            "{name}: {}",
            record["sessionPublicationRecord"]
        );
        support::native_observation::assert_session(&owners, &record);
        let journal: Vec<Value> = fs::read_to_string(owners.job_file(job, "journal.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            journal
                .iter()
                .filter(|row| row["kind"] == "finalized")
                .count(),
            1
        );
        assert!(journal.iter().all(|row| row["jobId"] == job));
        // The complete owner census is clear, including known failed/rolled-back Jobs.
        let inspection = imports
            .lifecycle_resource(
                &owners.artifacts,
                &owners.jobs,
                "artifact.import.inspection",
                json!({"importId":unrelated["importId"]})
                    .as_object()
                    .unwrap(),
                &support::fixed_now().unwrap(),
            )
            .unwrap();
        assert_eq!(inspection["references"]["state"], "clear");
        assert!(
            inspection["references"]["activeJobIds"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let before = owners.calls();
        assert!(
            runner
                .handle(json!({"jobId":job}).as_object().unwrap())
                .is_err()
        );
        assert_eq!(owners.calls(), before, "no terminal native replay");
    }
    owners.mode("deployed");
    runner
        .continue_cleanup_debt(
            exchange(&cases, "debt.continuePath")["params"]
                .as_object()
                .unwrap(),
        )
        .unwrap();
    assert_eq!(dispatch.reads.load(std::sync::atomic::Ordering::SeqCst), 15);
    let actual = support::oracle_fake::oracle_spelling(&owners.calls(), &owners.root);
    let expected = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    assert_eq!(expected.lines().count(), CALLS);
    assert_eq!(
        actual, expected,
        "all frozen native send/publish/rollback/cleanup calls unchanged"
    );
}

struct CorruptDebt<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
    path: std::path::PathBuf,
    directory: bool,
    settled: Option<Value>,
}

impl HdcDispatch for CorruptDebt<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.inner.mutation_identity_current()
    }
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let result = self.inner.dispatch(plan);
        if plan.arguments.get(3).map(String::as_str) == Some("rmdir") && !self.path.exists() {
            if self.directory {
                fs::create_dir(&self.path).unwrap();
            } else if let Some(settled) = &self.settled {
                fs::write(&self.path, serde_json::to_vec(settled).unwrap()).unwrap();
            } else {
                fs::write(&self.path, b"not-json").unwrap();
            }
        }
        result
    }
}

#[test]
fn unconfirmed_native_cleanup_debt_never_finalizes_or_replays_a_failed_dispatch() {
    for compensation in [false, true] {
        for damage in ["corrupt", "directory", "settled"] {
            let _lock = debug_hap::exclusive();
            let fixture = support::fixture("deploy-native-library");
            let cases = support::document(&fixture, "cases.json");
            let owners = Owners::open(&fixture);
            let case = if compensation {
                "loaderFailure"
            } else {
                "cleanupFailure"
            };
            let job = cases["jobs"][case].as_str().unwrap();
            let settled = (damage == "settled").then(|| {
                let old = support::document(&fixture, "artifacts/cleanup-debt.json");
                let old_job = old[0]["jobID"].as_str().unwrap();
                let mut record: Value = serde_json::from_str(
                    &serde_json::to_string(&old[0])
                        .unwrap()
                        .replace(old_job, job),
                )
                .unwrap();
                record["stepID"] = json!(if compensation {
                    "cleanup-native-library-compensation"
                } else {
                    "cleanup-staging-and-backup"
                });
                json!([record])
            });
            let observed = Observed::new(&owners.dispatch);
            let fault = Faulted {
                inner: &observed,
                fault: if compensation {
                    Fault::CleanupIneffective
                } else {
                    Fault::None
                },
            };
            let dispatch = CorruptDebt {
                inner: &fault,
                path: owners.root.join("artifacts/cleanup-debt.json"),
                directory: damage == "directory",
                settled: settled.clone(),
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
            owners.mode(case);
            let runner = owners.runner(&hdc, &publisher, true);
            let status = runner
                .handle(json!({"jobId":job}).as_object().unwrap())
                .unwrap();
            assert_eq!(status["state"], "waitingForRecovery");
            assert_eq!(status["outcomeUnknown"], true);
            let record = owners.record(job);
            assert_eq!(record["operationFailure"]["code"], "executionFailed");
            assert_ne!(
                record["sessionPublicationRecord"]["phase"],
                "catalogPublished"
            );
            let rows: Vec<Value> = fs::read_to_string(owners.job_file(job, "journal.jsonl"))
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            let step = if compensation {
                "cleanup-native-library-compensation"
            } else {
                "cleanup-staging-and-backup"
            };
            let outcome = rows
                .iter()
                .find(|row| row["stepId"] == step && row["kind"] == "stepOutcome")
                .unwrap();
            assert_eq!(outcome["payload"]["result"], "failed");
            assert_eq!(outcome["payload"]["outcomeCertainty"], "confirmed");
            assert!(!rows.iter().any(|row| row["kind"] == "finalized"));
            if compensation {
                assert!(record["timeline"].as_array().unwrap().iter().any(|line| {
                    line.as_str()
                        .is_some_and(|line| line.contains(LOADER_FAILURE))
                }));
            }
            let calls = owners.calls();
            assert!(
                runner
                    .handle(json!({"jobId":job}).as_object().unwrap())
                    .is_err()
            );
            assert_eq!(owners.calls(), calls);
            if damage == "directory" {
                assert!(dispatch.path.is_dir());
            } else if let Some(settled) = settled {
                assert_eq!(
                    fs::read(&dispatch.path).unwrap(),
                    serde_json::to_vec(&settled).unwrap()
                );
            } else {
                assert_eq!(fs::read(&dispatch.path).unwrap(), b"not-json");
            }
            let root = owners.root.clone();
            let state_root = owners.default_root.clone();
            let digest = owners.digest.clone();
            let journal_path = owners.job_file(job, "journal.jsonl");
            let record_path = owners.job_file(job, "job-record.json");
            let journal_bytes = fs::read(&journal_path).unwrap();
            let record_bytes = fs::read(&record_path).unwrap();
            drop(owners);
            let jobs = arkdeck_hoststore::JobStore::open_owner(&state_root).unwrap();
            let params = json!({"jobId":job});
            let restored = jobs
                .handle_resource("job.status", params.as_object().unwrap())
                .unwrap();
            assert_eq!(restored["state"], "waitingForRecovery");
            assert_eq!(restored["outcomeUnknown"], true);
            let artifacts =
                arkdeck_hoststore::ArtifactReadStore::open(&root.join("artifacts")).unwrap();
            let targets =
                arkdeck_hoststore::TargetStore::open(&root.join("targets-state")).unwrap();
            let capabilities =
                arkdeck_hoststore::CapabilityStore::open(&state_root.join("capabilities")).unwrap();
            let hdc = arkdeck_hoststore::HdcComposition {
                targets: &targets,
                dispatch: &debug_hap::NoDispatch,
                receive_root: None,
                tool_sha256: &digest,
                now: support::fixed_now,
                code_sign_helper: None,
            };
            let refusal = arkdeck_hoststore::JobReconciler {
                jobs: &jobs,
                artifacts: &artifacts,
                imports: None,
                now: support::fixed_now,
                sessions: None,
                hdc: Some(&hdc),
                capabilities: Some(&capabilities),
                runner: None,
            }
            .handle(params.as_object().unwrap())
            .unwrap_err();
            assert!(
                refusal
                    .message
                    .contains("unknown outcome has no persisted exact typed action"),
                "storage uncertainty has no published device-action recovery: {refusal:?}"
            );
            assert_eq!(fs::read(&journal_path).unwrap(), journal_bytes);
            assert_eq!(fs::read(&record_path).unwrap(), record_bytes);
            assert_eq!(
                fs::read_to_string(root.join("hdc-invocations.log")).unwrap(),
                calls
            );
        }
    }
}

#[test]
fn native_preflight_refuses_missing_firmware_or_wrong_target_before_any_mutation() {
    for missing_firmware in [true, false] {
        let _lock = debug_hap::exclusive();
        let fixture = support::fixture("deploy-native-library");
        let cases = support::document(&fixture, "cases.json");
        let owners = Owners::open(&fixture);
        let mut dispatch = Observed::new(&owners.dispatch);
        dispatch.missing_firmware = missing_firmware;
        dispatch.mismatched_target = !missing_firmware;
        let hdc = owners.hdc(&dispatch);
        let publisher = owners.publisher();
        owners
            .admitter(&hdc, &owners.default_root)
            .handle(
                exchange(&cases, "deployed.submit")["params"]
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        let status = owners
            .runner(&hdc, &publisher, true)
            .handle(
                exchange(&cases, "deployed.run")["params"]
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        assert_eq!(
            status["state"],
            if missing_firmware {
                "waitingForRecovery"
            } else {
                "failed"
            }
        );
        assert_eq!(status["outcomeUnknown"], missing_firmware);
        assert!(
            owners.calls().is_empty(),
            "no send/publish/rollback on incomplete observation"
        );
        let record = owners.record(cases["jobs"]["deployed"].as_str().unwrap());
        assert!(record.get("evidenceObservation").is_none());
        assert!(
            !record["timeline"]
                .as_array()
                .unwrap()
                .iter()
                .any(|line| line == "capability consumed before first mutation")
        );
        if missing_firmware {
            assert_eq!(record["recoveryStepID"], "read-evidence-firmware");
            let before_reads = dispatch.reads.load(std::sync::atomic::Ordering::SeqCst);
            assert!(
                owners
                    .runner(&hdc, &publisher, true)
                    .handle(
                        exchange(&cases, "deployed.run")["params"]
                            .as_object()
                            .unwrap()
                    )
                    .is_err()
            );
            assert_eq!(
                dispatch.reads.load(std::sync::atomic::Ordering::SeqCst),
                before_reads,
                "unknown firmware observation never replays"
            );
        } else {
            assert_eq!(
                record["sessionPublicationRecord"]["failure"]["code"],
                "sourceIntegrityFailed"
            );
        }
    }
}

/// What a fault does to the one command it names: a rollback's move that
/// never happens, or a staging directory's removal that never happens or
/// whose outcome is lost.
#[derive(Clone, Copy)]
enum Fault {
    None,
    RollbackIneffective,
    RollbackUnobserved,
    CleanupIneffective,
    CleanupUnobserved,
}

/// The fake HDC with one command faulted; every other command reaches it.
struct Faulted<'a> {
    inner: &'a (dyn HdcDispatch + Sync),
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
            (Fault::RollbackUnobserved, Some("mv")) => Err(DispatchFailure::Unobservable(
                "dispatch outcome unobservable: the native restore was lost".into(),
            )),
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
    _lock: debug_hap::Exclusive,
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
    let observed = Observed::new(&owners.dispatch);
    let dispatch = Faulted {
        inner: &observed,
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

#[test]
fn confirmed_native_restore_is_public_and_durable_without_another_dispatch() {
    let Run {
        _lock,
        owners,
        job,
        status,
        ..
    } = loader_failure_with(Fault::None);
    assert_eq!(status["state"], "failed");
    assert_eq!(status["outcomeUnknown"], false);
    assert_eq!(status["outstandingResidueCount"], 0);
    let record = owners.record(&job);
    let proofs =
        hdc_oracle::native_readback::timeline_proofs(record["timeline"].as_array().unwrap());
    assert_eq!(proofs.len(), 2);
    assert_eq!(proofs[0].0, "backup");
    assert_eq!(proofs[1].0, "rollback");
    assert_eq!(proofs[0].1["backupSha256"], proofs[1].1["restoredSha256"]);
    assert_ne!(proofs[1].1["inputSha256"], proofs[1].1["restoredSha256"]);
    let journal = fs::read(owners.job_file(&job, "journal.jsonl")).unwrap();
    let rows: Vec<Value> = String::from_utf8(journal.clone())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    for (step, phase) in [
        ("backup-current-version", "backup"),
        ("rollback-native-library", "rollback"),
    ] {
        let outcome = rows
            .iter()
            .find(|row| row["eventId"] == format!("outcome-{step}"))
            .unwrap();
        assert_eq!(outcome["payload"]["result"], "succeeded");
        assert_eq!(outcome["payload"]["outcomeCertainty"], "confirmed");
        let summary: Value =
            serde_json::from_str(outcome["payload"]["summary"].as_str().unwrap()).unwrap();
        assert_eq!(summary, hdc_oracle::native_readback::expected(phase));
    }
    let before_calls = owners.calls();
    let params = Map::from_iter([
        ("jobId".into(), json!(job)),
        ("pageSize".into(), json!(1000)),
    ]);
    let page = owners
        .jobs
        .handle_resource("job.timeline", &params)
        .unwrap();
    assert_eq!(page["hasMore"], false);
    hdc_oracle::assert_conforms("job.timeline", &json!({"ok":true,"result":page}));
    let texts: Vec<Value> = page["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["text"].clone())
        .collect();
    assert_eq!(hdc_oracle::native_readback::timeline_proofs(&texts), proofs);
    assert_eq!(owners.calls(), before_calls);
    let root = owners.default_root.clone();
    let job_file = owners.job_file(&job, "journal.jsonl");
    drop(owners);
    let reopened = arkdeck_hoststore::JobStore::open_owner(&root).unwrap();
    let again = reopened.handle_resource("job.timeline", &params).unwrap();
    assert_eq!(again["items"], page["items"]);
    assert_eq!(fs::read(job_file).unwrap(), journal);
}

#[test]
fn historical_native_comparison_refuses_missing_duplicate_or_changed_readback_proofs() {
    let backup = hdc_oracle::native_readback::expected("backup");
    let rollback = hdc_oracle::native_readback::expected("rollback");
    let original = json!({"timeline":[
        "verified backup-current-version [\"backupPath\", \"backupSha256\"]",
        "verified rollback-native-library [\"processIds\", \"restored\", \"restoredSha256\"]",
    ]});
    let mut extended = original.clone();
    extended["timeline"].as_array_mut().unwrap().extend([
        json!(format!("native-readback backup-current-version {backup}")),
        json!(format!(
            "native-readback rollback-native-library {rollback}"
        )),
    ]);
    let projected: Value = serde_json::from_slice(&hdc_oracle::native_readback::historical_bytes(
        &serde_json::to_vec(&extended).unwrap(),
    ))
    .unwrap();
    assert_eq!(projected, original);
    let mut changed = rollback.clone();
    changed["restoredSha256"] = json!("f".repeat(64));
    let mut future = rollback;
    future["unrecognizedProof"] = json!(true);
    for invalid in [
        original,
        json!({"timeline":[
            "verified rollback-native-library [\"processIds\", \"restored\", \"restoredSha256\"]",
            format!("native-readback rollback-native-library {changed}"),
        ]}),
        json!({"timeline":[
            "verified rollback-native-library [\"processIds\", \"restored\", \"restoredSha256\"]",
            format!("native-readback rollback-native-library {future}"),
        ]}),
        json!({"timeline":[
            "verified backup-current-version [\"backupPath\", \"backupSha256\"]",
            format!("native-readback backup-current-version {backup}"),
            format!("native-readback backup-current-version {backup}"),
        ]}),
        json!({"timeline":[format!("native-readback unknown-step {backup}")]}),
    ] {
        assert!(
            std::panic::catch_unwind(|| hdc_oracle::native_readback::historical_bytes(
                &serde_json::to_vec(&invalid).unwrap(),
            ))
            .is_err(),
            "invalid proof must never be erased: {invalid}"
        );
    }
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
    let record = owners.record(&job);
    assert_eq!(
        hdc_oracle::native_readback::timeline_proofs(record["timeline"].as_array().unwrap()).len(),
        1
    );
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    let rollback_outcome: Value = journal
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|row| row["eventId"] == "outcome-rollback-native-library")
        .unwrap();
    assert_eq!(rollback_outcome["payload"]["result"], "failed");
    assert!(rollback_outcome["payload"].get("summary").is_none());
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

#[test]
fn an_unobserved_restore_has_no_readback_proof_or_confirmed_outcome() {
    let Run {
        _lock,
        owners,
        job,
        status,
        ..
    } = loader_failure_with(Fault::RollbackUnobserved);
    assert_eq!(status["state"], "waitingForRecovery");
    assert_eq!(status["outcomeUnknown"], true);
    let record = owners.record(&job);
    let proofs =
        hdc_oracle::native_readback::timeline_proofs(record["timeline"].as_array().unwrap());
    assert_eq!(proofs.len(), 1);
    assert_eq!(proofs[0].0, "backup");
    assert_eq!(record["recoveryStepID"], "rollback-native-library");
    let journal = fs::read_to_string(owners.job_file(&job, "journal.jsonl")).unwrap();
    let rows: Vec<Value> = journal
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(
        rows.iter()
            .any(|row| row["eventId"] == "intent-rollback-native-library")
    );
    assert!(
        !rows
            .iter()
            .any(|row| row["eventId"] == "outcome-rollback-native-library")
    );
    assert!(!owners.calls().contains("rmdir"));
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
