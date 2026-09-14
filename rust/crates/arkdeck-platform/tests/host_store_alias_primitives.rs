//! The host-store primitives Swift's post-flash HDC alias store needs and the
//! crate did not have (TASK-XPA-016, M4): a private root created and made
//! owner-only in one step, a document created exactly once or compared in
//! place, and an owner-only read that tells absence from every refusal (the
//! waited-for lock the store needs, `wait_lock`, the crate already had). Everything runs against a scratch
//! directory; no store logic is involved.
#![cfg(target_os = "macos")]

use arkdeck_platform::{
    ExclusiveOutcome, HostDirectory, application_support_directory,
    arkdeck_application_support_root, random_bytes, runtime_home,
};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use std::{fs, thread};

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-alias-primitives-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }

    fn file(&self, name: &str, bytes: &[u8], mode: u32) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(mode)).unwrap();
    }

    fn mode(&self, name: &str) -> u32 {
        fs::metadata(self.0.join(name))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_private_root_is_created_owner_only_and_reopened() {
    let scratch = Scratch::new();
    let path = scratch.0.join("alias/root");
    let root = HostDirectory::open_or_create_private(&path).unwrap();
    assert_eq!(scratch.mode("alias"), 0o700);
    assert_eq!(scratch.mode("alias/root"), 0o700);
    root.publish_document("doc.json", b"{}\n", 64).unwrap();
    assert_eq!(
        root.read_owner_only("doc.json", 64).unwrap(),
        Some(b"{}\n".to_vec())
    );

    // An existing root that is too open is made owner-only, not refused.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    let reopened = HostDirectory::open_or_create_private(&path).unwrap();
    assert_eq!(scratch.mode("alias/root"), 0o700);
    assert_eq!(
        reopened.read_owner_only("doc.json", 64).unwrap(),
        Some(b"{}\n".to_vec())
    );

    // A relative path and a path that names a file are refused.
    assert!(HostDirectory::open_or_create_private(Path::new("relative/root")).is_err());
    scratch.file("plain", b"x", 0o600);
    assert!(HostDirectory::open_or_create_private(&scratch.0.join("plain")).is_err());
}

#[test]
fn an_exclusive_document_is_created_once_and_matched_only_byte_for_byte() {
    let scratch = Scratch::new();
    let root = HostDirectory::open(&scratch.0).unwrap();
    let bytes = b"{\"bindingRevision\":3}\n";
    assert_eq!(
        root.create_exclusive_or_match("archive.json", bytes, 64)
            .unwrap(),
        ExclusiveOutcome::Created
    );
    assert_eq!(scratch.mode("archive.json"), 0o600);
    assert_eq!(fs::read(scratch.0.join("archive.json")).unwrap(), bytes);

    assert_eq!(
        root.create_exclusive_or_match("archive.json", bytes, 64)
            .unwrap(),
        ExclusiveOutcome::Matched
    );
    // Same length, different bytes; a different length; an empty occupant —
    // all "different", and the occupant is never touched.
    assert_eq!(
        root.create_exclusive_or_match("archive.json", b"{\"bindingRevision\":4}\n", 64)
            .unwrap(),
        ExclusiveOutcome::Different
    );
    assert_eq!(
        root.create_exclusive_or_match("archive.json", b"{}\n", 64)
            .unwrap(),
        ExclusiveOutcome::Different
    );
    assert_eq!(fs::read(scratch.0.join("archive.json")).unwrap(), bytes);
    scratch.file("empty.json", b"", 0o600);
    assert_eq!(
        root.create_exclusive_or_match("empty.json", b"x\n", 64)
            .unwrap(),
        ExclusiveOutcome::Different
    );

    // Refusals: nothing to write, more than the limit, an occupant that is
    // not owner-only, an occupant above the limit, a link at the name, a
    // name that is not one segment.
    assert!(
        root.create_exclusive_or_match("other.json", b"", 64)
            .is_err()
    );
    assert!(
        root.create_exclusive_or_match("other.json", &[b'x'; 65], 64)
            .is_err()
    );
    assert!(!scratch.0.join("other.json").exists());
    scratch.file("open.json", bytes, 0o644);
    assert!(
        root.create_exclusive_or_match("open.json", bytes, 64)
            .is_err()
    );
    scratch.file("large.json", &[b'y'; 100], 0o600);
    assert!(
        root.create_exclusive_or_match("large.json", bytes, 64)
            .is_err()
    );
    symlink(scratch.0.join("archive.json"), scratch.0.join("link.json")).unwrap();
    assert!(
        root.create_exclusive_or_match("link.json", bytes, 64)
            .is_err()
    );
    assert!(
        root.create_exclusive_or_match("a/b.json", bytes, 64)
            .is_err()
    );
    assert!(root.create_exclusive_or_match("..", bytes, 64).is_err());
}

#[test]
fn an_owner_only_read_tells_absence_from_every_refusal() {
    let scratch = Scratch::new();
    let root = HostDirectory::open(&scratch.0).unwrap();
    assert_eq!(root.read_owner_only("missing.json", 64).unwrap(), None);

    scratch.file("record.json", b"{\"a\":1}\n", 0o600);
    assert_eq!(
        root.read_owner_only("record.json", 64).unwrap(),
        Some(b"{\"a\":1}\n".to_vec())
    );
    assert!(root.read_owner_only("record.json", 7).is_err());

    scratch.file("open.json", b"{}\n", 0o644);
    assert!(root.read_owner_only("open.json", 64).is_err());
    scratch.file("sealed.json", b"{}\n", 0o400);
    assert!(root.read_owner_only("sealed.json", 64).is_err());
    scratch.file("empty.json", b"", 0o600);
    assert!(root.read_owner_only("empty.json", 64).is_err());
    fs::create_dir(scratch.0.join("dir.json")).unwrap();
    assert!(root.read_owner_only("dir.json", 64).is_err());
    symlink(scratch.0.join("record.json"), scratch.0.join("link.json")).unwrap();
    assert!(root.read_owner_only("link.json", 64).is_err());
    assert!(root.read_owner_only("..", 64).is_err());
    assert!(root.read_owner_only("nested/record.json", 64).is_err());
}

#[test]
fn the_existing_waited_lock_is_the_store_s_lock() {
    // Swift's store takes its lock with a blocking `LOCK_EX` and does not
    // synchronize a lock it just created: that is `wait_lock(name, false)`,
    // which the crate already had; nothing new was added for it.
    let scratch = Scratch::new();
    let root = HostDirectory::open(&scratch.0).unwrap();
    let held = root.lock_document("alias.lock").unwrap();
    assert!(root.lock_document("alias.lock").is_err());
    let started = Instant::now();
    let releaser = thread::spawn(move || {
        thread::sleep(Duration::from_millis(300));
        drop(held);
    });
    let waited = root.wait_lock("alias.lock", false).unwrap();
    assert!(
        started.elapsed() >= Duration::from_millis(250),
        "{:?}",
        started.elapsed()
    );
    releaser.join().unwrap();
    drop(waited);
    assert_eq!(scratch.mode("alias.lock"), 0o600);
}

#[test]
fn the_application_support_root_follows_the_runtime_home() {
    let home = runtime_home().expect("a home for the running account");
    assert_eq!(
        application_support_directory().unwrap(),
        PathBuf::from(&home).join("Library/Application Support")
    );
    let root = arkdeck_application_support_root().unwrap();
    assert_eq!(
        root,
        PathBuf::from(&home).join("Library/Application Support/ArkDeck")
    );
    assert!(root.is_absolute());
}
