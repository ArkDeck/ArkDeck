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
fn export_journal_digest_distinguishes_absence_empty_and_unsafe_files() {
    use sha2::{Digest, Sha256};
    let fixture = Fixture::new();
    let root = HostDirectory::open_session_tree(&fixture.0).unwrap();
    assert_eq!(
        root.optional_document_digest("journal.jsonl", 1_073_741_824)
            .unwrap(),
        None
    );
    fixture.file("journal.jsonl", b"");
    assert_eq!(
        root.optional_document_digest("journal.jsonl", 0).unwrap(),
        Some(format!("{:x}", Sha256::digest(b"")))
    );
    let content = vec![b'x'; 256 * 1024 + 17];
    fixture.file("journal.jsonl", &content);
    assert_eq!(
        root.optional_document_digest("journal.jsonl", content.len() as u64)
            .unwrap(),
        Some(format!("{:x}", Sha256::digest(&content)))
    );
    assert!(
        root.optional_document_digest("journal.jsonl", content.len() as u64 - 1)
            .is_err()
    );
    symlink(
        fixture.0.join("journal.jsonl"),
        fixture.0.join("alias.jsonl"),
    )
    .unwrap();
    assert!(
        root.optional_document_digest("alias.jsonl", 1_073_741_824)
            .is_err()
    );
    fs::hard_link(
        fixture.0.join("journal.jsonl"),
        fixture.0.join("hard.jsonl"),
    )
    .unwrap();
    assert!(
        root.optional_document_digest("hard.jsonl", 1_073_741_824)
            .is_err()
    );
    assert_eq!(fs::read(fixture.0.join("journal.jsonl")).unwrap(), content);
}

#[test]
fn export_parent_facts_allow_owned_user_directories_and_remain_bound_to_the_descriptor() {
    use std::os::unix::fs::MetadataExt;
    let fixture = Fixture::new();
    let directory = fixture.0.join("destination-parent");
    fs::create_dir(&directory).unwrap();
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(HostDirectory::open(&directory).is_err());
    let parent = HostDirectory::open_export_parent(&directory).unwrap();
    let facts = parent.export_facts().unwrap();
    let metadata = fs::metadata(&directory).unwrap();
    assert_eq!(facts.device, u64::from(metadata.dev() as u32));
    assert_eq!(facts.inode, metadata.ino());
    assert_eq!(
        facts.volume_identity,
        HostDirectory::open(&fixture.0)
            .unwrap()
            .export_facts()
            .unwrap()
            .volume_identity
    );
    assert!(
        facts.volume_identity.starts_with("uuid:")
            || facts.volume_identity == format!("dev-unverified:{}", facts.device)
    );
    assert!(parent.lock_document("forbidden.lock").is_err());
    assert!(
        parent
            .publish_document("forbidden.json", b"{}", 10)
            .is_err()
    );
    assert!(parent.names(1).unwrap().is_empty());
    symlink(&directory, fixture.0.join("alias")).unwrap();
    assert!(HostDirectory::open_export_parent(&fixture.0.join("alias")).is_err());
    fs::rename(&directory, fixture.0.join("held-parent")).unwrap();
    fs::create_dir(&directory).unwrap();
    assert_eq!(parent.export_facts().unwrap(), facts);
    assert!(parent.validate_path(&directory).is_err());
    assert_ne!(
        HostDirectory::open_export_parent(&directory)
            .unwrap()
            .export_facts()
            .unwrap()
            .inode,
        facts.inode
    );
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

#[test]
fn export_staging_publishes_exact_new_files_and_enforces_growth() {
    use arkdeck_platform::ExportStaging;
    let fixture = Fixture::new();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    let capacity = parent.export_capacity().unwrap();
    assert_eq!(capacity.facts, facts);
    assert!(capacity.total_bytes >= capacity.available_bytes);
    assert!(!capacity.read_only);
    let mut stage = ExportStaging::create(&fixture.0, "export", &facts, 6).unwrap();
    stage.write_bytes("nested/payload.bin", b"abc").unwrap();
    assert_eq!(stage.remaining_growth(), 3);
    assert!(stage.write_bytes("never/created", b"abcd").is_err());
    stage.write_bytes("manifest.json", b"{}").unwrap();
    assert!(!fixture.0.join("export").exists());
    let output = stage.publish().unwrap();
    assert_eq!(output, fixture.0.join("export"));
    assert_eq!(fs::read(output.join("nested/payload.bin")).unwrap(), b"abc");
    assert_eq!(fs::read(output.join("manifest.json")).unwrap(), b"{}");
    assert!(!output.join("never").exists());
    assert_eq!(parent.names(10).unwrap(), ["export"]);
}

#[test]
fn export_staging_refuses_existing_destination_and_changed_parent_facts() {
    use arkdeck_platform::ExportStaging;
    let fixture = Fixture::new();
    fixture.file("existing", b"preserve");
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    assert!(ExportStaging::create(&fixture.0, "existing", &facts, 1).is_err());
    assert!(ExportStaging::create(&fixture.0, "missing", &facts, u64::MAX).is_err());
    let mut changed = facts.clone();
    changed.inode += 1;
    assert!(ExportStaging::create(&fixture.0, "missing", &changed, 1).is_err());
    assert_eq!(fs::read(fixture.0.join("existing")).unwrap(), b"preserve");
    assert_eq!(parent.names(10).unwrap(), ["existing"]);
}

#[test]
fn export_staging_drop_reclaims_only_its_created_entries() {
    use arkdeck_platform::ExportStaging;
    let fixture = Fixture::new();
    fixture.file("unrelated", b"preserve");
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    {
        let mut stage = ExportStaging::create(&fixture.0, "export", &facts, 10).unwrap();
        stage.write_bytes("nested/payload", b"abc").unwrap();
    }
    assert_eq!(parent.names(10).unwrap(), ["unrelated"]);
    assert_eq!(fs::read(fixture.0.join("unrelated")).unwrap(), b"preserve");
}

#[test]
fn export_staging_refuses_substituted_content_without_removing_replacement() {
    use arkdeck_platform::{ExportPublishError, ExportStaging};
    let fixture = Fixture::new();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    let mut stage = ExportStaging::create(&fixture.0, "export", &facts, 10).unwrap();
    stage.write_bytes("payload", b"abc").unwrap();
    let staging = parent
        .names(10)
        .unwrap()
        .into_iter()
        .find(|s| s.starts_with(".arkdeck-export-"))
        .unwrap();
    fs::rename(
        fixture.0.join(&staging).join("payload"),
        fixture.0.join("original"),
    )
    .unwrap();
    fixture.file(&format!("{staging}/payload"), b"replacement");
    assert!(matches!(
        stage.publish(),
        Err(ExportPublishError::BeforePublication(_))
    ));
    assert!(!fixture.0.join("export").exists());
    assert_eq!(
        fs::read(fixture.0.join(&staging).join("payload")).unwrap(),
        b"replacement"
    );
    assert_eq!(fs::read(fixture.0.join("original")).unwrap(), b"abc");
}

#[test]
fn export_publication_never_replaces_a_destination_created_after_staging() {
    use arkdeck_platform::{ExportPublishError, ExportStaging};
    let fixture = Fixture::new();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    let mut stage = ExportStaging::create(&fixture.0, "export", &facts, 10).unwrap();
    stage.write_bytes("payload", b"abc").unwrap();
    fixture.file("export", b"concurrent-existing");
    assert!(matches!(
        stage.publish(),
        Err(ExportPublishError::OutcomeUnknown(_))
    ));
    assert_eq!(
        fs::read(fixture.0.join("export")).unwrap(),
        b"concurrent-existing"
    );
    assert_eq!(parent.names(10).unwrap(), ["export"]);
}

#[test]
fn export_staging_parent_replacement_refuses_writes_and_preserves_both_trees() {
    use arkdeck_platform::ExportStaging;
    let fixture = Fixture::new();
    let path = fixture.0.join("parent");
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let parent = HostDirectory::open_export_parent(&path).unwrap();
    let facts = parent.export_facts().unwrap();
    let mut stage = ExportStaging::create(&path, "export", &facts, 10).unwrap();
    stage.write_bytes("payload", b"abc").unwrap();
    fs::rename(&path, fixture.0.join("displaced")).unwrap();
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    fixture.file("parent/replacement", b"preserve");
    assert!(stage.write_bytes("new-file", b"def").is_err());
    assert!(stage.cleanup().is_err());
    drop(stage);
    assert_eq!(fs::read(path.join("replacement")).unwrap(), b"preserve");
    assert_eq!(fs::read_dir(&path).unwrap().count(), 1);
    let staging = parent.names(10).unwrap().into_iter().next().unwrap();
    assert_eq!(
        fs::read(fixture.0.join("displaced").join(staging).join("payload")).unwrap(),
        b"abc"
    );
}

#[test]
fn export_staging_refuses_untracked_content_and_preserves_it_on_cleanup() {
    use arkdeck_platform::{ExportPublishError, ExportStaging};
    let fixture = Fixture::new();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    let mut stage = ExportStaging::create(&fixture.0, "export", &facts, 10).unwrap();
    stage.write_bytes("payload", b"abc").unwrap();
    let staging = parent.names(10).unwrap().into_iter().next().unwrap();
    fixture.file(&format!("{staging}/untracked"), b"preserve");
    assert!(matches!(
        stage.publish(),
        Err(ExportPublishError::BeforePublication(_))
    ));
    assert!(!fixture.0.join("export").exists());
    assert_eq!(
        fs::read(fixture.0.join(staging).join("untracked")).unwrap(),
        b"preserve"
    );
}

#[test]
fn export_stream_copy_preserves_large_identity_free_source_with_fixed_buffers() {
    use arkdeck_platform::ExportStaging;
    use sha2::{Digest, Sha256};
    use std::io::Write;
    let fixture = Fixture::new();
    let mut source_file = fs::File::create(fixture.0.join("source.bin")).unwrap();
    fs::set_permissions(
        fixture.0.join("source.bin"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let block = [b'x'; 64 * 1024];
    let mut digest = Sha256::new();
    for _ in 0..1024 {
        source_file.write_all(&block).unwrap();
        digest.update(block);
    }
    source_file.write_all(b"beyond-64MiB-tail!").unwrap();
    digest.update(b"beyond-64MiB-tail!");
    source_file.sync_all().unwrap();
    let size = source_file.metadata().unwrap().len();
    assert!(size > 64 * 1024 * 1024);
    let digest = format!("{:x}", digest.finalize());
    let source = HostDirectory::open_session_tree(&fixture.0).unwrap();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let facts = parent.export_facts().unwrap();
    let mut stage = ExportStaging::create(&fixture.0, "export", &facts, size).unwrap();
    stage
        .copy_verified(&source, "source.bin", "payload.bin", size, &digest)
        .unwrap();
    assert_eq!(stage.remaining_growth(), 0);
    let result = stage.publish().unwrap();
    HostDirectory::open_session_tree(&result)
        .unwrap()
        .verify_payload("payload.bin", size, &digest)
        .unwrap();
    source.verify_payload("source.bin", size, &digest).unwrap();
}

#[test]
fn failed_export_copy_poisoning_prevents_publication_or_followup_writes() {
    use arkdeck_platform::{ExportPublishError, ExportStaging};
    let fixture = Fixture::new();
    fixture.file("source.bin", b"original");
    let source = HostDirectory::open_session_tree(&fixture.0).unwrap();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let mut stage =
        ExportStaging::create(&fixture.0, "export", &parent.export_facts().unwrap(), 20).unwrap();
    assert!(
        stage
            .copy_verified(&source, "source.bin", "payload.bin", 8, &"0".repeat(64))
            .is_err()
    );
    assert!(stage.write_bytes("after-failure", b"data").is_err());
    assert!(matches!(
        stage.publish(),
        Err(ExportPublishError::BeforePublication(_))
    ));
    assert_eq!(parent.names(10).unwrap(), ["source.bin"]);
    assert_eq!(fs::read(fixture.0.join("source.bin")).unwrap(), b"original");
}

#[test]
fn export_copy_refuses_symlink_and_hardlink_sources_without_changing_them() {
    use arkdeck_platform::ExportStaging;
    use sha2::{Digest, Sha256};
    let fixture = Fixture::new();
    fixture.file("source.bin", b"original");
    symlink("source.bin", fixture.0.join("link.bin")).unwrap();
    fs::hard_link(fixture.0.join("source.bin"), fixture.0.join("alias.bin")).unwrap();
    let source = HostDirectory::open_session_tree(&fixture.0).unwrap();
    let parent = HostDirectory::open_export_parent(&fixture.0).unwrap();
    let mut stage =
        ExportStaging::create(&fixture.0, "export", &parent.export_facts().unwrap(), 20).unwrap();
    let digest = format!("{:x}", Sha256::digest(b"original"));
    assert!(
        stage
            .copy_verified(&source, "link.bin", "symlink-output", 8, &digest)
            .is_err()
    );
    assert!(
        stage
            .copy_verified(&source, "alias.bin", "hardlink-output", 8, &digest)
            .is_err()
    );
    drop(stage);
    assert_eq!(fs::read(fixture.0.join("source.bin")).unwrap(), b"original");
    assert!(!fixture.0.join("export").exists());
    assert_eq!(parent.names(10).unwrap().len(), 3);
}
