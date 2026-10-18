use super::*;

fn history(jobs: &JobStore, id: &str) -> String {
    let path = jobs.job_directory(id).unwrap();
    let root = HostDirectory::open(&path).unwrap();
    for name in [
        "job-record.json",
        "journal.jsonl",
        crate::job_owner::arkforge_job_state::FILE,
    ] {
        root.create_document(name, b"synthetic immutable history")
            .unwrap();
    }
    source_digest(&jobs.root, id).unwrap()
}

fn first(jobs: &JobStore, consumed: bool) -> Allocation {
    let mut candidate = candidate();
    candidate.source_sha256 = history(jobs, &candidate.source_job_id);
    history(jobs, &candidate.recovery_job_id);
    let allocation = jobs
        .reserve_recommission(candidate, "2026-10-01T00:00:00Z")
        .unwrap();
    if consumed {
        jobs.consume_recommission(&allocation, "2026-10-01T00:01:00Z")
            .unwrap();
    }
    allocation
}

fn next(jobs: &JobStore, first: &Allocation) -> Allocation {
    let mut next = first.clone();
    next.recovery_job_id = "job-controlled-retry".into();
    next.request_fingerprint_sha256 = "6".repeat(64);
    next.materialized_plan_sha256 = "7".repeat(64);
    next.controlled_retry = Some(ControlledRetry {
        failed_job_id: first.recovery_job_id.clone(),
        failed_source_sha256: source_digest(&jobs.root, &first.recovery_job_id).unwrap(),
        first_allocation_sha256: first.sha256(),
        program_sha256: "8".repeat(64),
    });
    next
}

#[test]
fn explicit_second_allocation_preserves_first_history_and_never_allows_a_third() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let first = first(&jobs, true);
    let before: serde_json::Value =
        serde_json::from_slice(&jobs.root.read(DOCUMENT, LIMIT).unwrap()).unwrap();
    let retry = next(&jobs, &first);
    assert!(
        jobs.reserve_recommission(retry.clone(), "2026-10-01T00:29:59Z")
            .is_err()
    );
    let allocated = jobs
        .reserve_recommission(retry.clone(), "2026-10-01T00:30:00Z")
        .unwrap();
    assert_eq!(
        allocated.expires_at_epoch_ms - allocated.reserved_at_epoch_ms,
        BUDGET_MS
    );
    assert_eq!(
        source_digest(&jobs.root, &first.source_job_id).unwrap(),
        first.source_sha256
    );
    assert_eq!(
        jobs.reserve_recommission(retry, "2026-10-01T00:31:00Z")
            .unwrap(),
        allocated
    );
    jobs.consume_recommission(&allocated, "2026-10-01T00:32:00Z")
        .unwrap();
    let after: serde_json::Value =
        serde_json::from_slice(&jobs.root.read(DOCUMENT, LIMIT).unwrap()).unwrap();
    assert_eq!(before["allocations"][0], after["allocations"][0]);
    assert_eq!(after["allocations"].as_array().unwrap().len(), 2);
    drop(jobs);
    let jobs = JobStore::open_owner(&root.0).unwrap();
    for mut third in [next(&jobs, &first), allocated.clone()] {
        third.recovery_job_id = "job-third".into();
        assert!(
            jobs.reserve_recommission(third, "2026-10-01T02:00:00Z")
                .is_err()
        );
    }
    assert!(
        jobs.consume_recommission(&allocated, "2026-10-01T00:33:00Z")
            .is_err()
    );
}

#[test]
fn controlled_retry_rejects_unconsumed_first_allocation_and_every_link_or_identity_drift() {
    for fault in 0..9 {
        let root = Root::new();
        let jobs = JobStore::open_owner(&root.0).unwrap();
        let first = first(&jobs, fault != 0);
        let before = jobs.root.read(DOCUMENT, LIMIT).unwrap();
        let mut retry = next(&jobs, &first);
        match fault {
            0 => (),
            1 => retry.controlled_retry = None,
            2 => {
                retry
                    .controlled_retry
                    .as_mut()
                    .unwrap()
                    .first_allocation_sha256 = "0".repeat(64)
            }
            3 => retry.controlled_retry.as_mut().unwrap().failed_job_id = "job-different".into(),
            4 => retry.source_sha256 = "0".repeat(64),
            5 => retry.identity_chain.hardware_serial_sha256 = "0".repeat(64),
            6 => retry.identity_chain.usb_topology = "84".into(),
            7 => {
                retry
                    .controlled_retry
                    .as_mut()
                    .unwrap()
                    .failed_source_sha256 = "0".repeat(64)
            }
            _ => retry
                .controlled_retry
                .as_mut()
                .unwrap()
                .program_sha256
                .clear(),
        }
        assert!(
            jobs.reserve_recommission(retry, "2026-10-01T01:00:00Z")
                .is_err(),
            "fault {fault}"
        );
        assert_eq!(
            jobs.root.read(DOCUMENT, LIMIT).unwrap(),
            before,
            "fault {fault}"
        );
    }
}

#[test]
fn changed_failed_history_cannot_consume_an_already_reserved_retry() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let first = first(&jobs, true);
    let allocated = jobs
        .reserve_recommission(next(&jobs, &first), "2026-10-01T00:30:00Z")
        .unwrap();
    let path = jobs.job_directory(&first.recovery_job_id).unwrap();
    HostDirectory::open(&path)
        .unwrap()
        .replace_document("journal.jsonl", b"changed synthetic history", LIMIT)
        .unwrap();
    assert_eq!(
        jobs.consume_recommission(&allocated, "2026-10-01T00:31:00Z")
            .unwrap_err(),
        "recommission.historicalBytesDrifted"
    );
    let ledger = load(&jobs.root).unwrap();
    assert!(!ledger.allocations[1].consumed);
}
