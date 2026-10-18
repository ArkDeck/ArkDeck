use super::*;
#[path = "retry_tests.rs"]
mod retry_tests;
use crate::test_private::{create_private_directory, temporary_root};
use std::path::PathBuf;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        Self::under(&temporary_root())
    }
    fn under(parent: &std::path::Path) -> Self {
        let path = parent.join(format!(
            "arkdeck-recommission-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        create_private_directory(&path);
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn startup_without_an_allocation_keeps_a_pristine_job_repository() {
    let state = Root::new();
    let targets_root = Root::new();
    let targets = crate::TargetStore::open(&targets_root.0).unwrap();
    reconcile_bindings(&state.0, &targets).unwrap();
    assert_eq!(std::fs::read_dir(&state.0).unwrap().count(), 0);
    assert!(JobStore::open_owner(&state.0).is_ok());
}

#[test]
fn startup_never_treats_a_malformed_or_unsafe_ledger_as_absent() {
    for variant in 0..3 {
        let state = Root::new();
        let targets_root = Root::new();
        let targets = crate::TargetStore::open(&targets_root.0).unwrap();
        let root = HostDirectory::open(&state.0).unwrap();
        match variant {
            0 => root.create_document(DOCUMENT, b"{}").unwrap(),
            1 => drop(root.private_child(DOCUMENT).unwrap()),
            _ => {
                root.create_document("linked.json", b"{}").unwrap();
                crate::test_private::link(&state.0.join("linked.json"), &state.0.join(DOCUMENT));
            }
        }
        assert!(reconcile_bindings(&state.0, &targets).is_err());
        if variant == 0 {
            assert_eq!(root.read_without_repair(DOCUMENT, LIMIT).unwrap(), b"{}");
        } else {
            assert!(!state.0.join(LOCK).exists());
        }
    }
}

fn archive_marker(root: &Root) -> serde_json::Value {
    let directory = HostDirectory::open(&root.0).unwrap();
    let session = directory
        .private_child("2026")
        .unwrap()
        .private_child("10")
        .unwrap()
        .private_child("session-job-retained")
        .unwrap();
    let bytes = br#"{"jobId":"job-retained"}"#;
    session.create_document("manifest.json", bytes).unwrap();
    let facts = directory.export_facts().unwrap();
    json!({
        "root": {"path": root.0.to_str().unwrap(), "device": facts.device.to_string(),
            "inode": facts.inode.to_string(), "volumeIdentity": facts.volume_identity},
        "relativeSessionPath": "2026/10/session-job-retained",
        "receipt": {"manifestSHA256": sha256_hex(bytes)},
        "proposal": {"manifestSHA256": sha256_hex(bytes)}
    })
}

#[test]
fn published_archive_requires_the_original_root_and_manifest() {
    let root = Root::new();
    let marker = archive_marker(&root);
    assert_eq!(
        published_manifest(&marker, "job-retained").unwrap()["jobId"],
        "job-retained"
    );
    for field in ["device", "inode", "volumeIdentity"] {
        let mut changed = marker.clone();
        changed["root"][field] = json!("changed");
        assert!(published_manifest(&changed, "job-retained").is_err());
    }
    for field in ["receipt", "proposal"] {
        let mut changed = marker.clone();
        changed[field]["manifestSHA256"] = json!("0".repeat(64));
        assert!(published_manifest(&changed, "job-retained").is_err());
    }
    let replacement = Root::new();
    archive_marker(&replacement);
    let mut changed = marker;
    changed["root"]["path"] = json!(replacement.0.to_str().unwrap());
    assert!(published_manifest(&changed, "job-retained").is_err());
}

#[cfg(target_os = "macos")]
#[test]
fn foundation_archive_alias_requires_the_same_canonical_private_root() {
    let parent = std::path::Path::new("/tmp").canonicalize().unwrap();
    let root = Root::under(&parent);
    let mut marker = archive_marker(&root);
    let short = format!(
        "/{}",
        root.0.to_str().unwrap().strip_prefix("/private/").unwrap()
    );
    marker["root"]["path"] = json!(short);
    assert!(HostDirectory::open(std::path::Path::new(&short)).is_err());
    assert_eq!(
        published_manifest(&marker, "job-retained").unwrap()["jobId"],
        "job-retained"
    );

    let replacement = Root::under(&parent);
    archive_marker(&replacement);
    marker["root"]["path"] = json!(format!(
        "/{}",
        replacement
            .0
            .to_str()
            .unwrap()
            .strip_prefix("/private/")
            .unwrap()
    ));
    assert!(published_manifest(&marker, "job-retained").is_err());

    let link_parent = Root::under(&parent);
    let link = link_parent.0.join("alias");
    std::os::unix::fs::symlink(&root.0, &link).unwrap();
    marker["root"]["path"] = json!(link.to_str().unwrap());
    assert!(published_manifest(&marker, "job-retained").is_err());
    marker["root"]["path"] = json!(format!(
        "/{}",
        link.to_str().unwrap().strip_prefix("/private/").unwrap()
    ));
    assert!(published_manifest(&marker, "job-retained").is_err());
}

fn candidate() -> Allocation {
    Allocation {
        source_job_id: "job-retained".into(),
        source_sha256: "1".repeat(64),
        recovery_job_id: "job-recommission".into(),
        request_fingerprint_sha256: "2".repeat(64),
        materialized_plan_sha256: "3".repeat(64),
        artifact_sha256: "4".repeat(64),
        uncertain_effect_set_sha256: "5".repeat(64),
        reserved_at_epoch_ms: 0,
        expires_at_epoch_ms: 0,
        controlled_retry: None,
        identity_chain: IdentityChain {
            target_id: "TGT-test".into(),
            binding_revision: 1,
            normal_identity_sha256: "a".repeat(64),
            hardware_serial_sha256: "b".repeat(64),
            loader_serial_sha256: "c".repeat(64),
            connector_sha256: "d".repeat(64),
            usb_topology: "42".into(),
            provider_sha256: "e".repeat(64),
            binding_snapshot_sha256: "f".repeat(64),
        },
    }
}

#[test]
fn exact_reservation_survives_restart_and_new_ids_cannot_allocate_again() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let allocated = jobs
        .reserve_recommission(candidate(), "2026-10-01T00:00:00Z")
        .unwrap();
    assert_eq!(
        allocated.expires_at_epoch_ms - allocated.reserved_at_epoch_ms,
        BUDGET_MS
    );
    drop(jobs);
    let jobs = JobStore::open_owner(&root.0).unwrap();
    assert_eq!(
        jobs.reserve_recommission(candidate(), "2026-10-01T00:01:00Z")
            .unwrap(),
        allocated
    );
    for changed in 0..5 {
        let mut altered = candidate();
        match changed {
            0 => altered.recovery_job_id = "job-other".into(),
            1 => altered.source_job_id = "job-new-unknown".into(),
            2 => altered.source_sha256 = "9".repeat(64),
            3 => altered.identity_chain.hardware_serial_sha256 = "9".repeat(64),
            _ => altered.request_fingerprint_sha256 = "9".repeat(64),
        }
        assert_eq!(
            jobs.reserve_recommission(altered, "2026-10-01T00:01:00Z")
                .unwrap_err(),
            "recommission.independentEpochAlreadyAllocated"
        );
    }
    assert!(
        verified_identity_chain(&root.0, "TGT-test", &"a".repeat(64))
            .unwrap()
            .is_none()
    );
    jobs.consume_recommission(&allocated, "2026-10-01T00:02:00Z")
        .unwrap();
    assert!(
        jobs.consume_recommission(&allocated, "2026-10-01T00:02:00Z")
            .is_err()
    );
    assert!(
        jobs.reserve_recommission(candidate(), "2026-10-01T00:02:00Z")
            .is_err()
    );
    assert!(jobs.require_recommission_postflight(&allocated).is_err());
    assert!(
        verified_identity_chain(&root.0, "TGT-test", &"a".repeat(64))
            .unwrap()
            .is_none()
    );
}

#[test]
fn deadline_or_backward_clock_closes_the_durable_budget_even_after_restart() {
    for stop in ["2026-10-01T00:30:00Z", "2026-10-01T00:00:59Z"] {
        let root = Root::new();
        let jobs = JobStore::open_owner(&root.0).unwrap();
        let allocation = jobs
            .reserve_recommission(candidate(), "2026-10-01T00:00:00Z")
            .unwrap();
        jobs.reserve_recommission(candidate(), "2026-10-01T00:01:00Z")
            .unwrap();
        assert_eq!(
            jobs.consume_recommission(&allocation, stop).unwrap_err(),
            "recommission.independentBudgetExpired"
        );
        drop(jobs);
        let jobs = JobStore::open_owner(&root.0).unwrap();
        assert!(
            jobs.consume_recommission(&allocation, "2026-10-01T00:02:00Z")
                .is_err()
        );
        assert!(
            jobs.reserve_recommission(candidate(), "2026-10-01T00:02:00Z")
                .is_err()
        );
        let ledger = load(&jobs.root).unwrap();
        assert_eq!(ledger.allocations.len(), 1);
        assert!(ledger.allocations[0].budget_closed);
        assert!(!ledger.allocations[0].consumed);
        assert_eq!(ledger.allocations[0].allocation, allocation);
    }
}

#[test]
fn concurrent_candidates_share_exactly_one_allocation() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let results = std::thread::scope(|scope| {
        let left = scope.spawn(|| jobs.reserve_recommission(candidate(), "2026-10-01T00:00:00Z"));
        let right = scope.spawn(|| {
            let mut second = candidate();
            second.recovery_job_id = "job-second".into();
            jobs.reserve_recommission(second, "2026-10-01T00:00:00Z")
        });
        [left.join().unwrap(), right.join().unwrap()]
    });
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| result
                .as_ref()
                .is_err_and(|reason| reason == "recommission.independentEpochAlreadyAllocated"))
            .count(),
        1
    );
}

#[test]
fn malformed_or_duplicate_ledgers_never_reset_a_budget() {
    for duplicate in [false, true] {
        let root = Root::new();
        let jobs = JobStore::open_owner(&root.0).unwrap();
        jobs.reserve_recommission(candidate(), "2026-10-01T00:00:00Z")
            .unwrap();
        let mut value: serde_json::Value =
            serde_json::from_slice(&jobs.root.read(DOCUMENT, LIMIT).unwrap()).unwrap();
        if duplicate {
            let entry = value["allocations"][0].clone();
            value["allocations"].as_array_mut().unwrap().push(entry);
        } else {
            value["allocations"][0]["allocation"]["expiresAtEpochMs"] = json!(0);
        }
        jobs.root
            .replace_document(DOCUMENT, &serde_json::to_vec(&value).unwrap(), LIMIT)
            .unwrap();
        let bytes = jobs.root.read(DOCUMENT, LIMIT).unwrap();
        assert!(
            jobs.reserve_recommission(candidate(), "2026-10-01T00:01:00Z")
                .is_err()
        );
        assert_eq!(jobs.root.read(DOCUMENT, LIMIT).unwrap(), bytes);
    }
}
