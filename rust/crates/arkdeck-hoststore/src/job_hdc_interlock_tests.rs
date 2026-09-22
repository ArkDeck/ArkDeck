use super::*;
use std::os::unix::fs::DirBuilderExt;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-hdc-interlock-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn lifecycle_closes_the_materialization_window_in_both_orders() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    // A submit has passed its first check and is materializing. The
    // lifecycle wins before the final check; final admission must refuse.
    drop(jobs.admission_interlock().unwrap());
    std::thread::scope(|scope| {
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let worker_jobs = &jobs;
        let worker = scope.spawn(move || {
            let lease = worker_jobs.acquire_hdc_lifecycle_interlock().unwrap();
            held_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            drop(lease);
        });
        held_rx.recv().unwrap();
        assert_eq!(
            jobs.admission_interlock().err().unwrap().code,
            "resourceConflict"
        );
        release_tx.send(()).unwrap();
        worker.join().unwrap();
    });
    // Conversely, after the final check a lifecycle cannot acquire the
    // inventory until the admission transaction has finished.
    let admission = jobs.admission_interlock().unwrap();
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                assert_eq!(
                    jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
                    "resourceConflict"
                );
            })
            .join()
            .unwrap();
    });
    drop(admission);
    assert!(jobs.acquire_hdc_lifecycle_interlock().is_ok());
}

#[test]
fn terminal_residue_and_resident_uncertainty_remain_current() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let mut record = JobRecord::decode(include_bytes!(
        "../../../tests/fixtures/job-publication-current/published/job-record.json"
    ))
    .unwrap();
    jobs.admit(&record, &"a".repeat(64)).unwrap();
    assert!(jobs.acquire_hdc_lifecycle_interlock().is_ok());
    record.set_residues(1);
    jobs.persist(&record, "2026-07-29T00:00:01Z").unwrap();
    assert_eq!(
        jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
        "factsDrifted"
    );
    record.set_residues(0);
    jobs.persist(&record, "2026-07-29T00:00:02Z").unwrap();
    assert!(jobs.acquire_hdc_lifecycle_interlock().is_ok());
    record.set_outcome_unknown();
    jobs.hold_resident(record);
    assert_eq!(
        jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
        "factsDrifted"
    );
}

#[test]
fn unwinding_a_lifecycle_poisons_admission_until_owner_restart() {
    let root = Root::new();
    let jobs = JobStore::open_owner(&root.0).unwrap();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _lease = jobs.acquire_hdc_lifecycle_interlock().unwrap();
        panic!("executor unexpectedly unwound");
    }));
    assert!(result.is_err());
    assert_eq!(
        jobs.admission_interlock().err().unwrap().code,
        "internalError"
    );
    assert_eq!(
        jobs.acquire_hdc_lifecycle_interlock().err().unwrap().code,
        "internalError"
    );
}
