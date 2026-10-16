//! The one place this Runtime's Loader binding declares a difference from
//! Swift's: Swift's handler settles a DAYU200 flash Job whose enter-Loader
//! transition awaits the binding, after binding; this Runtime does not settle
//! it yet, so such a Job refuses the binding before anything is written, and
//! intent stays unresolved. Other unsettled Flash work on the same Target,
//! including a delegated plan or a terminal unknown at an older revision,
//! must also preserve the binding until its recovery obligation is proved.
//!
//! On Windows (TASK-XPA-010) the root is a plain-spelled directory below the
//! temporary directory, every level of it the store's private directory, and
//! each file inherits its owner-only access.
#![cfg(any(target_os = "macos", windows))]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{BindingSnapshot, JobRecord, JobStore, LoaderBinding, TargetStore};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{LoaderIdentity, LoaderObserver};
use serde_json::{Value, json};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;

const TARGET: &str = "TGT-BOARD-A";
const HDC: &str = "1501ffff00000000000000000000cafe";
const LOADER: &str = "loader-serial-0451";

/// The Application Support root, not below `/private` (the reactivation
/// records' root must be its own standardized path), with the Job state and
/// the Target store below it.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        #[cfg(unix)]
        let temporary = PathBuf::from("/tmp");
        #[cfg(windows)]
        let temporary = support::fixture_fs::temporary_root();
        let root = temporary.join(format!(
            "arkdeck-loader-binding-jobs-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in ["state/targets", "jobs-state"] {
            #[cfg(unix)]
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(directory))
                .unwrap();
            #[cfg(windows)]
            arkdeck_platform::HostDirectory::open_or_create_private(&root.join(directory)).unwrap();
        }
        Self(root)
    }

    fn write(&self, name: &str, bytes: &[u8]) {
        let path = self.0.join(name);
        fs::write(&path, bytes).unwrap();
        #[cfg(unix)]
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Confirmed;

impl LoaderObserver for Confirmed {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        Ok(LoaderIdentity {
            serial_digest_sha256: stable_identity_sha256.into(),
            topology: expected_usb_topology.unwrap_or_default().into(),
        })
    }
}

/// Board A's Target at revision 1 and the binding installed while it was in
/// its normal personality; the board attached in its Loader personality.
fn scene() -> (Root, TargetStore, LoaderBinding) {
    let root = Root::new();
    root.write(
        "state/targets/targets.json",
        &serde_json::to_vec(&json!({"schemaVersion": "1.0.0", "targets": [{
            "targetID": TARGET, "stablePhysicalIdentitySHA256": sha256_hex(HDC.as_bytes()),
            "bindingRevision": 1, "connectKey": HDC, "toolVersion": "3.2.0f",
            "adoptedAtUTC": "2026-09-01T00:00:00Z"}]}))
        .unwrap(),
    );
    root.write(
        "rockchip-binding.json",
        &BindingSnapshot {
            revision: 1,
            serial: HDC.into(),
            usb_topology: "18874368".into(),
            evidence: vec![
                "product:e0-iokit-single-dayu200-readback".into(),
                "usb:vendor=8711,profile=dayu200-cross-mode".into(),
                format!("identity:serial-sha256={}", sha256_hex(HDC.as_bytes())),
            ],
        }
        .encode(),
    );
    let targets = TargetStore::open(&root.0.canonicalize().unwrap().join("state/targets")).unwrap();
    let binding = LoaderBinding::new(
        &root.0,
        || -> Result<Vec<UsbHostDevice>, RegistryUnavailable> {
            Ok(vec![UsbHostDevice {
                serial: LOADER.into(),
                vendor_id: 0x2207,
                product_id: 0x350a,
                topology: "17956864".into(),
                product_name: None,
                registry_entry_id: None,
            }])
        },
        Confirmed,
    );
    (root, targets, binding)
}

/// A DAYU200 flash Job for `target` at `revision`, parked in `state` with its
/// outcome unknown at the `step` intent, admitted and recorded as the Rust
/// runner records a Job.
fn park(jobs: &JobStore, id: &str, target: &str, revision: i64, state: &str, step: &str) {
    let base = JobRecord::decode(
        &fs::read(support::fixture(
            "job-reconcile-analyzer/before/jobs/job-082b8363fce0462b4571a62147751099/job-record.json",
        ))
        .unwrap(),
    )
    .unwrap();
    let mut value = base.value().unwrap();
    value["jobID"] = json!(id);
    value["operationReference"] = json!("flash.full-restore@1");
    value["request"]["operation"] = json!({"id": "flash.full-restore", "version": 1});
    value["request"]["target"] = json!({"targetId": target, "expectedBindingRevision": revision});
    value["request"]["idempotencyKey"] = json!(format!("idem-{id}"));
    value["request"]["requestId"] = json!(format!("req-{id}"));
    value["originalSubmissionRequest"] = value["request"].clone();
    let admitted = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.admit(&admitted, &"a".repeat(64)).unwrap();
    value["state"] = json!(state);
    value["outcomeUnknown"] = json!(true);
    value["recoveryStepID"] = json!(step);
    value["recoveryIntentEventID"] = json!(format!("intent-{step}"));
    let parked = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.persist(&parked, "2026-09-25T00:00:00Z").unwrap();
}

fn files(root: &Root) -> (Vec<u8>, Vec<u8>) {
    (
        fs::read(root.0.join("rockchip-binding.json")).unwrap(),
        fs::read(root.0.join("state/targets/targets.json")).unwrap(),
    )
}

#[test]
fn loader_first_adoption_cannot_hide_an_unsettled_flash_under_a_new_target() {
    for state in ["waitingForRecovery", "failed"] {
        let (root, targets, _) = scene();
        let jobs =
            JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
        let id = "job-00000000000000000000000000000f01";
        park(
            &jobs,
            id,
            "TGT-UNPROVED-NORMAL",
            4,
            state,
            "flash-partitions",
        );
        let binding = LoaderBinding::new(
            &root.0,
            || panic!("unsettled census must precede USB observation"),
            Confirmed,
        );
        let before = files(&root);
        let job = jobs.read_snapshot(id).unwrap().value().unwrap();
        let error = binding.adopt_current_loader(&targets, &jobs).unwrap_err();
        assert!(
            error.message.contains("first Loader adoption cannot"),
            "{error:?}"
        );
        assert_eq!(files(&root), before);
        assert_eq!(jobs.read_snapshot(id).unwrap().value().unwrap(), job);
    }
}

#[test]
fn a_job_awaiting_the_binding_refuses_it_before_anything_is_written() {
    let (root, targets, binding) = scene();
    let jobs = JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
    let awaiting = "job-00000000000000000000000000000a01";
    park(
        &jobs,
        awaiting,
        TARGET,
        1,
        "waitingForRecovery",
        "enter-loader-mode",
    );
    let before = files(&root);
    let refused = binding.bind(&targets, Some(&jobs), TARGET, 1).unwrap_err();
    assert_eq!(refused.code, "rejected");
    assert_eq!(
        refused.message,
        format!(
            "Rockchip Loader binding was refused: jobNotRunnable(\"Job {awaiting} awaits this \
             Loader binding to settle its enter-Loader transition, which this Runtime does not \
             settle yet; nothing was written\")"
        )
    );
    assert_eq!(files(&root), before);
    assert!(!root.0.join(".rockchip-binding.lock").exists());

    // Swift refuses two as ambiguous, before either is looked at further.
    park(
        &jobs,
        "job-00000000000000000000000000000a02",
        TARGET,
        1,
        "waitingForRecovery",
        "enter-loader-mode",
    );
    assert_eq!(
        binding
            .bind(&targets, Some(&jobs), TARGET, 1)
            .unwrap_err()
            .message,
        "Rockchip Loader binding was refused: jobNotRunnable(\"multiple unresolved Loader \
         transitions cover target TGT-BOARD-A\")"
    );
    assert_eq!(files(&root), before);
}

#[test]
fn an_unsettled_job_on_another_target_does_not_stand_in_the_way() {
    let (root, targets, binding) = scene();
    let jobs = JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
    // Another Target does not share this binding's recovery obligation.
    park(
        &jobs,
        "job-00000000000000000000000000000b01",
        "TGT-OTHER",
        1,
        "waitingForRecovery",
        "enter-loader-mode",
    );
    let receipt: Value = binding.bind(&targets, Some(&jobs), TARGET, 1).unwrap();
    assert_eq!(receipt["updated"], true);
    assert_eq!(receipt["previousBindingRevision"], 1);
    assert_eq!(receipt["bindingRevision"], 2);
    assert_eq!(receipt["settledJobId"], Value::Null);
}

#[test]
fn unsettled_flash_keeps_the_binding_even_outside_the_enter_loader_boundary() {
    for (revision, expected, state, step, unknown, residues) in [
        (1, 1, "waitingForRecovery", "flash-partitions", true, 0),
        (1, 1, "running", "enter-loader-mode", false, 0),
        (1, 1, "preflight", "flash-partitions", false, 0),
        (1, 1, "failed", "flash-partitions", true, 0),
        (1, 1, "failed", "flash-partitions", false, 1),
        (1, 2, "waitingForRecovery", "flash-partitions", true, 0),
        (2, 1, "waitingForRecovery", "flash-partitions", true, 0),
    ] {
        let (root, targets, binding) = scene();
        let jobs =
            JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
        let id = "job-00000000000000000000000000000c01";
        park(&jobs, id, TARGET, revision, state, step);
        let mut current = jobs.read_snapshot(id).unwrap().value().unwrap();
        current["outcomeUnknown"] = json!(unknown);
        current["outstandingResidueCount"] = json!(residues);
        jobs.persist(
            &JobRecord::decode(&serde_json::to_vec(&current).unwrap()).unwrap(),
            "2026-09-25T00:00:00Z",
        )
        .unwrap();
        let before = files(&root);
        let record = jobs.read_snapshot(id).unwrap().value().unwrap();
        let refused = binding
            .bind(&targets, Some(&jobs), TARGET, expected)
            .unwrap_err();
        assert_eq!(refused.code, "rejected");
        assert!(
            refused.message.contains("retains unsettled Flash state"),
            "{}",
            refused.message
        );
        assert_eq!(files(&root), before);
        assert_eq!(jobs.read_snapshot(id).unwrap().value().unwrap(), record);
        assert!(!root.0.join(".rockchip-binding.lock").exists());
    }
}

#[test]
fn a_confirmed_terminal_flash_does_not_block_binding() {
    let (root, targets, binding) = scene();
    let jobs = JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
    let id = "job-00000000000000000000000000000d01";
    park(&jobs, id, TARGET, 1, "succeeded", "flash-partitions");
    let mut value = jobs.read_snapshot(id).unwrap().value().unwrap();
    value["outcomeUnknown"] = json!(false);
    value["outstandingResidueCount"] = json!(0);
    value.as_object_mut().unwrap().remove("recoveryStepID");
    value
        .as_object_mut()
        .unwrap()
        .remove("recoveryIntentEventID");
    let settled = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
    jobs.persist(&settled, "2026-09-25T00:00:00Z").unwrap();
    assert_eq!(
        binding.bind(&targets, Some(&jobs), TARGET, 1).unwrap()["updated"],
        true
    );
}

#[test]
fn binding_publication_excludes_new_admission_until_its_readback_finishes() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    let (root, targets, _) = scene();
    let jobs =
        Arc::new(JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap());
    let admitted = JobRecord::decode(
        &fs::read(support::fixture(
            "job-reconcile-analyzer/before/jobs/job-082b8363fce0462b4571a62147751099/job-record.json",
        )).unwrap(),
    ).unwrap();
    let pending = admitted.clone();
    let observed = Arc::new(AtomicBool::new(false));
    let attempted = Arc::clone(&observed);
    let racing_jobs = Arc::clone(&jobs);
    let binding = LoaderBinding::new(
        &root.0,
        move || {
            let error = racing_jobs.admit(&pending, &"a".repeat(64)).unwrap_err();
            assert!(format!("{error:?}").contains("currently blocks new Job admission"));
            attempted.store(true, Ordering::SeqCst);
            Ok(vec![UsbHostDevice {
                serial: LOADER.into(),
                vendor_id: 0x2207,
                product_id: 0x350a,
                topology: "17956864".into(),
                product_name: None,
                registry_entry_id: None,
            }])
        },
        Confirmed,
    );
    assert_eq!(
        binding.bind(&targets, Some(&jobs), TARGET, 1).unwrap()["updated"],
        true
    );
    assert!(observed.load(Ordering::SeqCst));
    jobs.admit(&admitted, &"a".repeat(64)).unwrap();
}

#[test]
fn only_a_supersession_on_the_records_own_binding_releases_its_unknown() {
    use arkdeck_hoststore::{
        RecoveryEpochDraft, RecoverySource, SupersededIntent, append_recovery_epoch,
    };
    use arkdeck_platform::HostDirectory;
    for (identity_matches, revision, released) in
        [(true, 1, true), (false, 1, false), (true, 2, false)]
    {
        let (root, targets, binding) = scene();
        let path = root.0.canonicalize().unwrap().join("jobs-state");
        let jobs = JobStore::open_owner(&path).unwrap();
        let id = "job-00000000000000000000000000000e01";
        park(
            &jobs,
            id,
            TARGET,
            1,
            "waitingForRecovery",
            "flash-partitions",
        );
        let identity = sha256_hex(HDC.as_bytes());
        let mut record = jobs.read_snapshot(id).unwrap().value().unwrap();
        record["materializedStableTargetIdentitySHA256"] = json!(identity);
        record["materializedBindingRevision"] = json!(1);
        record["outstandingResidueCount"] = json!(0);
        jobs.persist(
            &JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
            "2026-09-25T00:00:00Z",
        )
        .unwrap();
        let digest = "a".repeat(64);
        // This is an isolated store fixture, never hardware evidence.
        append_recovery_epoch(
            &HostDirectory::open(&path).unwrap(),
            &RecoveryEpochDraft {
                source: RecoverySource::DistinctRecoveryExecution,
                stable_target_identity_sha256: if identity_matches {
                    identity
                } else {
                    "b".repeat(64)
                },
                binding_revision: revision,
                covered_intents: vec![SupersededIntent {
                    job_id: id.into(),
                    intent_event_id: "intent-flash-partitions".into(),
                    operation_reference: "flash.full-restore@1".into(),
                    profile_reference: "dayu200".into(),
                    observed_at_utc: "2026-09-25T00:00:00Z".into(),
                    possible_effects: vec!["partition:system".into()],
                }],
                uncertain_effect_set_sha256: sha256_hex(b"partition:system"),
                coverage_contract_version: "test-complete-overwrite/1".into(),
                covered_effect_set_sha256: sha256_hex(b"partition:system"),
                recovery_job_id: "job-00000000000000000000000000000e02".into(),
                recovery_intent_event_id: "intent-recovery".into(),
                operation_reference: "flash.full-restore@1".into(),
                profile_reference: "dayu200".into(),
                materialized_plan_digest_sha256: digest.clone(),
                artifact_sha256: digest.clone(),
                provider_executable_sha256: digest.clone(),
                confirmed_step_ids: vec![
                    "flash-partitions".into(),
                    "verify-flash-readback".into(),
                    "reboot-device".into(),
                    "rebind-and-verify-build".into(),
                ],
                resulting_target_epoch_sha256: digest,
                established_at_utc: "2026-09-25T00:10:00Z".into(),
            },
        )
        .unwrap();
        let before = files(&root);
        let result = binding.bind(&targets, Some(&jobs), TARGET, 1);
        assert_eq!(result.is_ok(), released, "{result:?}");
        if !released {
            assert_eq!(files(&root), before);
        }
        assert_eq!(jobs.read_snapshot(id).unwrap().value().unwrap(), record);
    }
}
