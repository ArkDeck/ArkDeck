#![cfg(target_os = "macos")]
use arkdeck_platform::HostDirectory;
use arkdeck_soak::{Configuration, run, verify_state};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let suffix: String = arkdeck_platform::random_bytes::<12>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("adksoak-{suffix}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn production_workload_reopens_and_verifies_all_outputs_and_refuses_corruption() {
    let root = Root::new();
    let config = Configuration {
        state_directory: root.0.clone(),
        duration_seconds: 1,
        restart_interval_seconds: 1,
        jobs_per_cycle: 10,
    };
    let metrics = run(&config).unwrap();
    assert!(metrics.cycle >= 1);
    assert_eq!(metrics.schema_version, "arkdeck-runtime-soak/v1");
    assert_eq!(metrics.phase, "completed");
    assert_eq!(metrics.job_states["cancelled"], metrics.cycle);
    assert_eq!(metrics.job_states["succeeded"], 9 * metrics.cycle);
    assert_eq!(
        metrics.recovered_this_cycle, 1,
        "final fresh owner must run the retained preflight Job"
    );
    assert_eq!(metrics.active_job_count, 0);
    assert_eq!(metrics.terminal_job_count, 10 * metrics.cycle);
    assert_eq!(
        metrics.verified_artifact_evidence_job_count,
        Some(9 * metrics.cycle)
    );
    assert_eq!(metrics.fake_provider_child_process_count, 0);
    assert!(metrics.fake_provider_commands_this_cycle > 0);
    assert!(metrics.journal_count >= metrics.terminal_job_count);
    assert!(metrics.artifact_file_count > 0);
    assert!(metrics.max_resident_set_bytes > 0);
    assert!(metrics.resident_set_growth_bytes <= 32 * 1024 * 1024);
    assert!(metrics.open_file_descriptor_growth <= 16);
    assert_eq!(metrics.outstanding_cleanup_debt_count, 0);
    let snapshot: Value =
        serde_json::from_slice(&fs::read(root.0.join("runtime-soak-metrics.json")).unwrap())
            .unwrap();
    assert_eq!(snapshot["processID"], std::process::id());
    assert_eq!(snapshot["phase"], "completed");
    assert!(snapshot["generatedAtUTC"].is_string());
    assert!(snapshot["runID"].is_string());
    assert_eq!(verify_state(&root.0).unwrap(), 9 * metrics.cycle);

    let job = fs::read_dir(root.0.join("jobs-state/jobs"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let journal = job.join("journal.jsonl");
    let original = fs::read(&journal).unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&journal)
        .unwrap()
        .write_all(b"{torn")
        .unwrap();
    let torn = fs::read(&journal).unwrap();
    assert!(verify_state(&root.0).unwrap_err().contains("torn"));
    assert_eq!(
        fs::read(&journal).unwrap(),
        torn,
        "verification must never repair a torn tail"
    );
    fs::write(&journal, original).unwrap();

    let payload = fs::read_dir(root.0.join("artifacts"))
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().unwrap().is_dir())
        .flat_map(|e| fs::read_dir(e.path()).unwrap().filter_map(|e| e.ok()))
        .find(|e| e.file_name().to_string_lossy().starts_with("ART-"))
        .expect("published payload")
        .path();
    let original = fs::read(&payload).unwrap();
    // Fault injection into this test-owned simulated artifact only. Production
    // publication correctly made the payload read-only; keep that final mode.
    let permissions = fs::metadata(&payload).unwrap().permissions();
    fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&payload, b"corrupt").unwrap();
    fs::set_permissions(&payload, permissions.clone()).unwrap();
    assert!(verify_state(&root.0).unwrap_err().contains("Artifact"));
    fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&payload, original).unwrap();
    fs::set_permissions(&payload, permissions).unwrap();

    let ledger = json!([{"jobID":"orphan-job", "stepID":"orphan-step", "remotePath":"/fixture-only",
        "reason":"test census", "recordedAtUTC":"2026-09-19T00:00:00Z"}]);
    HostDirectory::open(&root.0.join("artifacts"))
        .unwrap()
        .publish_document(
            "cleanup-debt.json",
            &serde_json::to_vec(&ledger).unwrap(),
            1024 * 1024,
        )
        .unwrap();
    assert!(
        verify_state(&root.0).unwrap_err().contains("cleanup debt"),
        "unindexed debt cannot disappear from the census"
    );
}

#[test]
fn refuses_unowned_nonempty_state_and_invalid_flags() {
    let root = Root::new();
    fs::write(root.0.join("unrelated-state"), b"retain").unwrap();
    let config = Configuration {
        state_directory: root.0.clone(),
        duration_seconds: 1,
        restart_interval_seconds: 1,
        jobs_per_cycle: 1,
    };
    assert!(run(&config).unwrap_err().contains("empty root"));
    assert_eq!(fs::read(root.0.join("unrelated-state")).unwrap(), b"retain");
    assert!(!root.0.join("jobs-state").exists());
    let before: Vec<_> = fs::read_dir(&root.0)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert!(verify_state(&root.0).is_err());
    let after: Vec<_> = fs::read_dir(&root.0)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(
        before, after,
        "inspection of unmarked state creates nothing"
    );
    assert!(!root.0.join("jobs-state").exists());
    for args in [
        vec!["--state-directory", "relative"],
        vec!["--duration-seconds", "0"],
        vec!["--unknown", "1"],
    ] {
        assert!(Configuration::parse(args.into_iter().map(str::to_owned)).is_err());
    }
}

#[test]
fn recovery_seed_is_exact_fresh_and_replayed_by_production_owner() {
    use arkdeck_hoststore::{JobStore, inspect_journal, recover_active_jobs};
    let root = Root::new();
    let manifest = arkdeck_soak::recovery::seed(&root.0, "journal", 20).unwrap();
    assert_eq!(manifest["journalEventCount"], 20);
    assert!(arkdeck_soak::recovery::seed(&root.0, "journal", 20).is_err());
    let jobs = JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
    let recovered = recover_active_jobs(&jobs, None, arkdeck_hoststore::runtime_now).unwrap();
    assert_eq!(recovered.statuses.len(), 1);
    assert!(recovered.quarantined.is_empty());
    assert!(recovered.refused.is_empty());
    let record = jobs.read_snapshot("job-recovery-00000").unwrap();
    assert_eq!(record.timeline, ["recovered: journal clean"]);
    assert_eq!(record.state, "preflight");
    assert_eq!(
        inspect_journal(&root.0.join("jobs-state/jobs/job-recovery-00000"))
            .unwrap()
            .event_count,
        20
    );
    let history = Root::new();
    arkdeck_soak::recovery::seed(&history.0, "history", 20).unwrap();
    let jobs = JobStore::open_owner(&history.0.join("jobs-state")).unwrap();
    assert!(
        recover_active_jobs(&jobs, None, arkdeck_hoststore::runtime_now)
            .unwrap()
            .statuses
            .is_empty()
    );
    let page = jobs
        .handle_resource("job.list", &serde_json::Map::new())
        .unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 20);
}

#[test]
fn recovery_seed_refuses_bad_workload_without_writing() {
    let root = Root::new();
    for (kind, count) in [("unknown", 20), ("journal", 0), ("history", 10001)] {
        assert!(arkdeck_soak::recovery::seed(&root.0, kind, count).is_err());
        assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
    }
}

#[test]
fn recovery_seed_refuses_foreign_root_and_final_symlink() {
    let root = Root::new();
    fs::write(root.0.join("foreign"), b"preserve").unwrap();
    assert!(arkdeck_soak::recovery::seed(&root.0, "history", 2).is_err());
    assert_eq!(fs::read(root.0.join("foreign")).unwrap(), b"preserve");
    let empty = Root::new();
    let link = root.0.join("linked");
    std::os::unix::fs::symlink(&empty.0, &link).unwrap();
    assert!(arkdeck_soak::recovery::seed(&link, "journal", 2).is_err());
    assert_eq!(fs::read_dir(&empty.0).unwrap().count(), 0);
}
