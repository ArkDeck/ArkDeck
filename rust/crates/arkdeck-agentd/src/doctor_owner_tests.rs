//! Doctor discovery follows the composed owners without invoking their tool.
use super::*;
use arkdeck_control::HostServices;
use arkdeck_platform::{HostDirectory, HostSqlite, VerifiedTool};
use arkdeck_provider_hdc::ProcessDispatch;

#[test]
fn doctor_discovery_requires_both_hdc_and_target_owners() {
    let temporary = std::env::temp_dir().canonicalize().unwrap();
    #[cfg(windows)]
    let temporary = temporary
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map_or(temporary.clone(), std::path::PathBuf::from);
    let root = temporary.join(format!("doctor-discovery-{}", fresh_id().unwrap()));
    let directory = HostDirectory::open_or_create_private(&root).unwrap();
    let mut host = Host::from_environment();
    host.provider = None;
    host.hdc = None;
    host.targets = None;
    assert!(!host.doctor_facts(false).discovery);

    // The test image stands in for the retained HDC executable. It is only
    // opened and hashed: no dispatch, server launch, socket or device call.
    let executable = std::env::current_exe().unwrap();
    let digest = arkdeck_contract::sha256_hex(&std::fs::read(&executable).unwrap());
    let dispatch = ProcessDispatch::new(VerifiedTool::open(&executable, &digest).unwrap(), None);
    host.hdc = Some(std::sync::Arc::new(
        crate::managed_hdc::DevelopmentHdc::new(dispatch, None),
    ));
    assert!(!host.doctor_facts(false).discovery, "no Target owner");
    host = host.with_targets(arkdeck_hoststore::TargetStore::open(&root).unwrap());
    let facts = host.doctor_facts(true);
    assert!(facts.discovery, "the composed HDC and Target owners exist");
    assert_eq!(facts.targets, arkdeck_control::TargetStoreFacts::Adopted(0));
    assert_eq!(
        facts.artifacts,
        arkdeck_control::ArtifactStoreFacts::NotConfigured
    );
    assert_eq!(facts.cleanup_debt, None, "no cleanup owners were composed");
    host.hdc = None;
    assert!(!host.doctor_facts(false).discovery, "no HDC owner");
    drop(host);
    drop(directory);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn doctor_preserves_the_job_index_read_refusal_and_does_not_modify_it() {
    let temporary = std::env::temp_dir().canonicalize().unwrap();
    #[cfg(windows)]
    let temporary = temporary
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map_or(temporary.clone(), std::path::PathBuf::from);
    let root = temporary.join(format!("doctor-index-{}", fresh_id().unwrap()));
    let directory = HostDirectory::open_or_create_private(&root).unwrap();
    let jobs = arkdeck_hoststore::JobStore::open_owner(&root).unwrap();
    assert_eq!(jobs.unreadable_records(16), Ok((0, Vec::new())));
    let index = root.join("runtime-jobs.sqlite3");
    let mut database = HostSqlite::open(&index, false, false).unwrap();
    // A real unsupported SQLite layout, after composition. Only this fresh
    // test's store is changed; the doctor must preserve its exact refusal.
    database.execute("PRAGMA user_version=2", &[]).unwrap();
    database
        .query("PRAGMA wal_checkpoint(TRUNCATE)", &[], 1024)
        .unwrap();
    drop(database);
    let before = std::fs::read(&index).unwrap();
    let error = jobs.unreadable_records(16).unwrap_err();
    assert_eq!(error.code, "recordUnreadable");
    let host = Host::from_environment().with_jobs(jobs);
    assert!(host.doctor_facts(false).unreadable_records.is_none());
    for _ in 0..2 {
        assert_eq!(
            host.doctor_facts(true).unreadable_records,
            Some(Err(error.clone()))
        );
        assert_eq!(std::fs::read(&index).unwrap(), before);
    }
    drop(host);
    drop(directory);
    std::fs::remove_dir_all(root).unwrap();
}
