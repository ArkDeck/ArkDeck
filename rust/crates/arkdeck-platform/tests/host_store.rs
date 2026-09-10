#![cfg(target_os = "macos")]
use arkdeck_platform::{HostDirectory, random_bytes};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::{fs, path::PathBuf, process::Command};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-host-store-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }
    fn file(&self, name: &str, bytes: &[u8]) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn bounded_reads_and_enumeration_never_create_a_missing_lock() {
    let fixture = Fixture::new();
    fixture.file("record.json", b"{\"generation\":2}");
    let root = HostDirectory::open(&fixture.0).unwrap();
    let before = root.names(1).unwrap();
    assert_eq!(root.read("record.json", 16).unwrap(), b"{\"generation\":2}");
    assert!(root.read("record.json", 15).is_err());
    assert!(root.names(0).is_err());
    assert!(root.try_lock_existing("missing.lock").unwrap().is_none());
    assert_eq!(root.names(1).unwrap(), before);
    assert_eq!(
        root.names(1).unwrap(),
        before,
        "each enumeration has its own offset"
    );
    assert!(root.read("../record.json", 100).is_err());
    assert!(root.child("..").is_err());
}

#[test]
fn symlinks_hardlinks_and_public_permissions_are_refused_without_rewriting() {
    let fixture = Fixture::new();
    fixture.file("record.json", b"fixture");
    let root = HostDirectory::open(&fixture.0).unwrap();
    symlink(fixture.0.join("record.json"), fixture.0.join("alias.json")).unwrap();
    assert!(root.read("alias.json", 100).is_err());
    fs::hard_link(fixture.0.join("record.json"), fixture.0.join("hard.json")).unwrap();
    assert!(root.read("hard.json", 100).is_err());
    fs::remove_file(fixture.0.join("hard.json")).unwrap();
    fs::set_permissions(
        fixture.0.join("record.json"),
        fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    assert!(root.read("record.json", 100).is_err());
    assert_eq!(fs::read(fixture.0.join("record.json")).unwrap(), b"fixture");
    fs::set_permissions(&fixture.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(HostDirectory::open(&fixture.0).is_err());
}

#[test]
fn existing_lock_excludes_another_process_and_releases_on_drop() {
    let fixture = Fixture::new();
    fixture.file("store.lock", b"");
    let root = HostDirectory::open(&fixture.0).unwrap();
    let held = root.try_lock_existing("store.lock").unwrap().unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "child_lock_probe", "--nocapture"])
        .env("ARKDECK_SHADOW_LOCK_FIXTURE_ROOT", &fixture.0)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(root.try_lock_existing("store.lock").unwrap().is_none());
    drop(held);
    assert!(root.try_lock_existing("store.lock").unwrap().is_some());
    assert_eq!(fs::read(fixture.0.join("store.lock")).unwrap(), b"");
}

#[test]
fn child_lock_probe() {
    let Some(root) = std::env::var_os("ARKDECK_SHADOW_LOCK_FIXTURE_ROOT") else {
        return;
    };
    let root = HostDirectory::open(&PathBuf::from(root)).unwrap();
    assert!(root.try_lock_existing("store.lock").unwrap().is_none());
}

#[test]
fn snapshot_root_replacement_and_permission_changes_are_refused() {
    let fixture = Fixture::new();
    let path = fixture.0.join("sessions");
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let root = HostDirectory::open_session_tree(&path).unwrap();
    root.validate_path(&path).unwrap();
    let original = fixture.0.join("original");
    fs::rename(&path, &original).unwrap();
    assert!(root.validate_path(&path).is_err());
    fs::create_dir(&path).unwrap();
    assert!(root.validate_path(&path).is_err());
    fs::remove_dir(&path).unwrap();
    symlink(&original, &path).unwrap();
    assert!(root.validate_path(&path).is_err());
    fs::remove_file(&path).unwrap();
    fs::rename(&original, &path).unwrap();
    root.validate_path(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o770)).unwrap();
    assert!(root.validate_path(&path).is_err());
}

#[test]
fn held_lock_replacement_is_refused_even_when_the_new_lock_is_available() {
    let fixture = Fixture::new();
    fixture.file("store.lock", b"");
    let root = HostDirectory::open(&fixture.0).unwrap();
    let held = root.try_lock_existing("store.lock").unwrap().unwrap();
    held.validate_link(&root, "store.lock").unwrap();
    fs::rename(fixture.0.join("store.lock"), fixture.0.join("old.lock")).unwrap();
    assert!(held.validate_link(&root, "store.lock").is_err());
    fixture.file("store.lock", b"");
    let replacement = root.try_lock_existing("store.lock").unwrap().unwrap();
    assert!(held.validate_link(&root, "store.lock").is_err());
    replacement.validate_link(&root, "store.lock").unwrap();
    fs::set_permissions(
        fixture.0.join("store.lock"),
        fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    assert!(replacement.validate_link(&root, "store.lock").is_err());
}

#[test]
fn session_tree_accepts_read_permissions_but_refuses_writable_or_linked_content() {
    let fixture = Fixture::new();
    fixture.file("record.json", b"session fixture");
    fs::set_permissions(&fixture.0, fs::Permissions::from_mode(0o750)).unwrap();
    fs::set_permissions(
        fixture.0.join("record.json"),
        fs::Permissions::from_mode(0o640),
    )
    .unwrap();
    assert!(HostDirectory::open(&fixture.0).is_err());
    let root = HostDirectory::open_session_tree(&fixture.0).unwrap();
    assert_eq!(root.read("record.json", 100).unwrap(), b"session fixture");
    assert_eq!(root.owned_kind_and_size("record.json").unwrap().1, 15);
    fs::create_dir(fixture.0.join("child")).unwrap();
    fs::set_permissions(fixture.0.join("child"), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(root.child("child").is_ok());
    symlink(fixture.0.join("record.json"), fixture.0.join("alias")).unwrap();
    assert!(root.owned_kind_and_size("alias").is_err());
    assert!(root.read("alias", 100).is_err());
    fs::hard_link(fixture.0.join("record.json"), fixture.0.join("hard")).unwrap();
    assert!(root.owned_kind_and_size("hard").is_err());
    fs::remove_file(fixture.0.join("hard")).unwrap();
    for mode in [0o660, 0o606] {
        fs::set_permissions(
            fixture.0.join("record.json"),
            fs::Permissions::from_mode(mode),
        )
        .unwrap();
        assert!(root.owned_kind_and_size("record.json").is_err());
        assert!(root.read("record.json", 100).is_err());
    }
    fs::set_permissions(&fixture.0, fs::Permissions::from_mode(0o770)).unwrap();
    assert!(HostDirectory::open_session_tree(&fixture.0).is_err());
    assert_eq!(
        fs::read(fixture.0.join("record.json")).unwrap(),
        b"session fixture"
    );
}
