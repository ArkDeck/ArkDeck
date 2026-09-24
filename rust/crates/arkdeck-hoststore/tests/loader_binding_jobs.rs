//! The one place this Runtime's Loader binding declares a difference from
//! Swift's: Swift's handler settles a DAYU200 flash Job whose enter-Loader
//! transition awaits the binding, after binding; this Runtime does not settle
//! it yet, so such a Job refuses the binding before anything is written, and
//! the Job's intent stays unresolved. A Job that awaits another Target or
//! revision, or is not parked at that intent, does not stand in the way.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{BindingSnapshot, JobRecord, JobStore, LoaderBinding, TargetStore};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{LoaderIdentity, LoaderObserver};
use serde_json::{Value, json};
use std::fs;
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
        let root = PathBuf::from("/tmp").join(format!(
            "arkdeck-loader-binding-jobs-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in ["state/targets", "jobs-state"] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(directory))
                .unwrap();
        }
        Self(root)
    }

    fn write(&self, name: &str, bytes: &[u8]) {
        let path = self.0.join(name);
        fs::write(&path, bytes).unwrap();
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
fn a_job_awaiting_something_else_does_not_stand_in_the_way() {
    let (root, targets, binding) = scene();
    let jobs = JobStore::open_owner(&root.0.canonicalize().unwrap().join("jobs-state")).unwrap();
    // Another Target, another revision, another state, another intent.
    park(
        &jobs,
        "job-00000000000000000000000000000b01",
        "TGT-OTHER",
        1,
        "waitingForRecovery",
        "enter-loader-mode",
    );
    park(
        &jobs,
        "job-00000000000000000000000000000b02",
        TARGET,
        2,
        "waitingForRecovery",
        "enter-loader-mode",
    );
    park(
        &jobs,
        "job-00000000000000000000000000000b03",
        TARGET,
        1,
        "running",
        "enter-loader-mode",
    );
    park(
        &jobs,
        "job-00000000000000000000000000000b04",
        TARGET,
        1,
        "waitingForRecovery",
        "flash-partitions",
    );
    let receipt: Value = binding.bind(&targets, Some(&jobs), TARGET, 1).unwrap();
    assert_eq!(receipt["updated"], true);
    assert_eq!(receipt["previousBindingRevision"], 1);
    assert_eq!(receipt["bindingRevision"], 2);
    assert_eq!(receipt["settledJobId"], Value::Null);
}
