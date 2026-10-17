use super::*;
use crate::test_private::{create_private_directory, temporary_root};
use std::path::PathBuf;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = temporary_root().join(format!(
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
