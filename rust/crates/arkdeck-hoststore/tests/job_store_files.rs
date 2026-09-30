//! The Job index's file checks on this host's durable store (NTFS on
//! Windows): the owner opens only its own single-link regular database and
//! companions (`-wal`, `-shm`, `-journal`), and stops reading an index whose
//! database is no longer the file (volume and file identity) it opened.
#![cfg(any(target_os = "macos", windows))]

mod journal_scratch;

use arkdeck_hoststore::{JobRecord, JobStore};
use journal_scratch::Root;
use serde_json::{Map, Value, json};
use std::fs;
use std::path::Path;

fn record(name: &str) -> JobRecord {
    JobRecord::decode(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/job-store-writer/records")
                .join(name),
        )
        .unwrap(),
    )
    .unwrap()
}

fn status(store: &JobStore, id: &str) -> Result<Value, String> {
    store
        .handle_resource("job.status", &Map::from_iter([("jobId".into(), json!(id))]))
        .map_err(|error| error.code)
}

/// A store holding one admitted Job, its owner closed.
fn admitted() -> (Root, String) {
    let root = Root::new("job-files");
    let store = JobStore::open_owner(&root.0).unwrap();
    let job = record("admitted-a.json");
    store.admit(&job, &"a".repeat(64)).unwrap();
    (root, job.job_id.clone())
}

#[test]
fn an_owner_writes_its_log_and_index_beside_the_database_and_reads_after_a_restart() {
    let (root, id) = admitted();
    // The write-ahead log and its index are the owner's own single-link
    // regular files; a reopened owner and a reader accept them.
    let owner = JobStore::open_owner(&root.0).unwrap();
    assert_eq!(status(&owner, &id).unwrap()["state"], "preflight");
    for name in ["runtime-jobs.sqlite3-wal", "runtime-jobs.sqlite3-shm"] {
        assert!(root.0.join(name).is_file(), "{name}");
    }
    drop(owner);
    let reader = JobStore::open(&root.0).unwrap();
    assert_eq!(status(&reader, &id).unwrap()["jobId"], json!(id));
}

#[test]
fn a_linked_or_foreign_companion_is_refused() {
    for companion in [
        "runtime-jobs.sqlite3-wal",
        "runtime-jobs.sqlite3-shm",
        "runtime-jobs.sqlite3-journal",
    ] {
        // A second link to a companion.
        let (root, _) = admitted();
        let other = root.0.join("other");
        journal_scratch::write_private_file(&other, b"");
        let _ = fs::remove_file(root.0.join(companion));
        fs::hard_link(&other, root.0.join(companion)).unwrap();
        assert!(JobStore::open_owner(&root.0).is_err(), "{companion} link");
        assert!(JobStore::open(&root.0).is_err(), "{companion} link");
        // A directory in its place.
        let (root, _) = admitted();
        let _ = fs::remove_file(root.0.join(companion));
        journal_scratch::private_directories(&root.0.join(companion));
        assert!(
            JobStore::open_owner(&root.0).is_err(),
            "{companion} directory"
        );
        assert!(JobStore::open(&root.0).is_err(), "{companion} directory");
    }
    // A second link to the database itself.
    let (root, _) = admitted();
    fs::hard_link(
        root.0.join("runtime-jobs.sqlite3"),
        root.0.join("database-link"),
    )
    .unwrap();
    assert!(JobStore::open_owner(&root.0).is_err());
    assert!(JobStore::open(&root.0).is_err());
}

#[test]
fn a_replaced_database_is_not_read() {
    let (root, id) = admitted();
    let reader = JobStore::open(&root.0).unwrap();
    assert!(status(&reader, &id).is_ok());
    let database = root.0.join("runtime-jobs.sqlite3");
    let moved = root.0.join("moved.sqlite3");
    let renamed = fs::rename(&database, &moved);
    // macOS: the name now holds another file, which is not read.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        renamed.unwrap();
        fs::copy(&moved, &database).unwrap();
        fs::set_permissions(&database, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(status(&reader, &id), Err("recordUnreadable".into()));
    }
    // Windows: SQLite holds the open database without delete sharing, so it
    // cannot be renamed or replaced while the store reads it.
    #[cfg(windows)]
    {
        assert!(renamed.is_err(), "{renamed:?}");
        assert!(status(&reader, &id).is_ok());
    }
}
