//! The bundle index's references against Swift `BootstrapBundleRegistry`'s
//! rules (`acquire`, `retainOnly`, `releaseAll`) over fresh private stores.
//! Bundles are registered through the store itself under a stand-in helper
//! policy (their canonical path, or a refusal), never a production signature:
//! these fixtures certify no trust.
use super::*;
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

const NOW: &str = "2026-09-26T00:00:00Z";

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/bundle-references-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(path.join("store"))
            .unwrap();
        Self(path)
    }
    fn store_path(&self) -> PathBuf {
        self.0.join("store")
    }
    /// The store under the stand-in policy: a Bundle's canonical path.
    fn store(&self) -> BundleRegistryReadStore {
        BundleRegistryReadStore::open_existing(&self.store_path())
            .unwrap()
            .with_bundle_validator(Arc::new(|path: &Path| path.canonicalize()))
    }
    /// A helper Bundle outside the store; `payload` makes its content unique.
    fn bundle(&self, name: &str, payload: &str) -> PathBuf {
        let bundle = self.0.join(format!("{name}.app"));
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(bundle.join("Contents/MacOS"))
            .unwrap();
        fs::write(
            bundle.join("Contents/Info.plist"),
            br#"<plist><dict><key>CFBundleIdentifier</key><string>com.arkdeck.agentd</string><key>CFBundleExecutable</key><string>arkdeck-agentd</string></dict></plist>"#,
        )
        .unwrap();
        let daemon = bundle.join("Contents/MacOS/arkdeck-agentd");
        fs::write(&daemon, format!("#!/bin/sh\n# {payload}\nexit 0\n")).unwrap();
        fs::set_permissions(&daemon, fs::Permissions::from_mode(0o700)).unwrap();
        bundle
    }
    /// A Bundle retained and recorded as registration leaves it: its bytes
    /// copied owner-only under `bundle-<digest>.app`, its record available at
    /// generation 1. (Registration itself captures only a production-signed
    /// helper, which no fixture is.)
    fn register(&self, name: &str) -> String {
        retain(&self.store_path(), &self.bundle(name, name))
    }
    fn index(&self) -> Value {
        serde_json::from_slice(&fs::read(self.store_path().join("bundles.json")).unwrap()).unwrap()
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(self.store_path().join("bundles.json")).unwrap()
    }
    fn inode(&self) -> u64 {
        fs::metadata(self.store_path().join("bundles.json"))
            .unwrap()
            .ino()
    }
    fn references(&self, reference: &str) -> Value {
        self.index()["records"]
            .as_array()
            .unwrap()
            .iter()
            .find(|record| record["reference"] == reference)
            .unwrap()["references"]
            .clone()
    }
}

/// Copies a Bundle as registration copies it: directories 0700, files 0600
/// or, when executable, 0700.
fn copy_bundle(source: &Path, destination: &Path) {
    fs::DirBuilder::new()
        .mode(0o700)
        .create(destination)
        .unwrap();
    for entry in fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        let target = destination.join(entry.file_name());
        let metadata = entry.metadata().unwrap();
        if metadata.is_dir() {
            copy_bundle(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).unwrap();
            let mode = if metadata.permissions().mode() & 0o111 == 0 {
                0o600
            } else {
                0o700
            };
            fs::set_permissions(&target, fs::Permissions::from_mode(mode)).unwrap();
        }
    }
}

/// Retains `bundle` in the store at `store` and records it, measured under
/// the stand-in policy, as registration would; answers its reference.
fn retain(store: &Path, bundle: &Path) -> String {
    let staged = store.join(".fixture-staging.app");
    copy_bundle(bundle, &staged);
    let content = crate::bundle_content::inspect_bundle_content_with(&staged, &|path: &Path| {
        path.canonicalize()
    })
    .unwrap();
    fs::rename(
        &staged,
        store.join(format!("bundle-{}.app", content.digest)),
    )
    .unwrap();
    let reference = format!("bundle:sha256:{}", content.digest);
    let path = store.join("bundles.json");
    let mut index: Value = fs::read(&path).map_or_else(
        |_| json!({"schemaVersion": "arkdeck.bootstrap-bundles/1", "records": []}),
        |bytes| serde_json::from_slice(&bytes).unwrap(),
    );
    let mut record = json!({"reference": reference, "digest": content.digest,
        "registeredAtUTC": NOW, "byteCount": content.byte_count,
        "entryCount": content.entry_count, "generation": 1, "state": "available",
        "references": []});
    if let Some(version) = content.version {
        record["version"] = json!(version);
    }
    let records = index["records"].as_array_mut().unwrap();
    records.push(record);
    records.sort_by(|a, b| a["reference"].as_str().cmp(&b["reference"].as_str()));
    fs::write(&path, arkdeck_contract::canonical_json(&index).unwrap()).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    reference
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn code(result: Result<impl std::fmt::Debug, WireError>, expected: &str, message: &str) {
    let error = result.unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (expected, message),
        "{error:?}"
    );
    let details = error.details.unwrap();
    assert_eq!(details["phase"], "bootstrapRegistryOwner");
    assert_eq!(details["newDispatchCount"], 0);
}

fn installation() -> ReferenceOwner {
    ReferenceOwner::service_installation()
}

#[test]
fn owners_are_swifts_closed_kinds_and_bounded_identifiers() {
    for kind in KINDS {
        assert!(ReferenceOwner::new(kind, "owner-1").is_ok(), "{kind}");
    }
    let long = "a".repeat(129);
    for (kind, id) in [
        ("installations", "owner"),
        ("installation", ""),
        ("installation", "-leading"),
        ("installation", "has space"),
        ("installation", long.as_str()),
    ] {
        code(
            ReferenceOwner::new(kind, id),
            "invalidInput",
            "invalid bundle reference owner",
        );
    }
    assert_eq!(
        ReferenceOwner::new("installation", "runtime-service-installation").unwrap(),
        installation()
    );
}

#[test]
fn acquire_pins_the_exact_available_generation_once_and_answers_its_content() {
    let root = Root::new();
    let reference = root.register("First");
    let digest = &reference["bundle:sha256:".len()..];
    let before = root.bytes();
    let store = root.store();
    // Refusals publish nothing.
    code(
        store.acquire("bundle:sha256:aa", "1", &installation()),
        "invalidInput",
        "expected a content-addressed daemon bundle reference",
    );
    code(
        store.acquire(
            &format!("bundle:sha256:{}", "0".repeat(64)),
            "1",
            &installation(),
        ),
        "resourceNotFound",
        "bundle reference does not exist",
    );
    for generation in ["2", "0", "01", ""] {
        code(
            store.acquire(&reference, generation, &installation()),
            "resourceConflict",
            "bundle is removed or its generation changed",
        );
    }
    assert_eq!(root.bytes(), before);
    // The pin, sorted beside another owner's.
    let rollback = ReferenceOwner::new("rollback", "previous").unwrap();
    store.acquire(&reference, "1", &rollback).unwrap();
    let content = store.acquire(&reference, "1", &installation()).unwrap();
    assert_eq!(
        content,
        root.store_path().join(format!("bundle-{digest}.app"))
    );
    assert_eq!(
        root.references(&reference),
        json!([{"kind": "installation", "id": "runtime-service-installation"},
            {"kind": "rollback", "id": "previous"}])
    );
    // Swift's canonical bytes: sorted keys, no whitespace.
    let bytes = root.bytes();
    assert_eq!(
        bytes,
        arkdeck_contract::canonical_json(&serde_json::from_slice::<Value>(&bytes).unwrap())
            .unwrap()
    );
    // Held already: nothing published again.
    let inode = root.inode();
    assert_eq!(
        store.acquire(&reference, "1", &installation()).unwrap(),
        content
    );
    assert_eq!(root.inode(), inode);
    assert_eq!(root.bytes(), bytes);
}

#[test]
fn a_removed_bundle_or_one_failing_its_trust_or_content_is_never_pinned() {
    let root = Root::new();
    let reference = root.register("First");
    let removed = root.register("Removed");
    root.store().retire(&removed, "1").unwrap();
    code(
        root.store().acquire(&removed, "1", &installation()),
        "resourceConflict",
        "bundle is removed or its generation changed",
    );
    code(
        root.store().acquire(&removed, "2", &installation()),
        "resourceConflict",
        "bundle is removed or its generation changed",
    );
    let before = root.bytes();
    let refusing = BundleRegistryReadStore::open_existing(&root.store_path())
        .unwrap()
        .with_bundle_validator(Arc::new(|_: &Path| {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "not the production helper",
            ))
        }));
    code(
        refusing.acquire(&reference, "1", &installation()),
        "admissionDenied",
        "registered bundle failed the production helper trust policy",
    );
    let digest = &reference["bundle:sha256:".len()..];
    let daemon = root
        .store_path()
        .join(format!("bundle-{digest}.app/Contents/MacOS/arkdeck-agentd"));
    fs::write(&daemon, b"#!/bin/sh\nexit 1\n").unwrap();
    code(
        root.store().acquire(&reference, "1", &installation()),
        "recordUnreadable",
        "registered bundle content failed integrity validation",
    );
    assert_eq!(root.bytes(), before);
}

#[test]
fn retain_only_keeps_the_installed_bundle_and_releases_the_owners_other_pins() {
    let root = Root::new();
    let first = root.register("First");
    let second = root.register("Second");
    let store = root.store();
    let rollback = ReferenceOwner::new("rollback", "previous").unwrap();
    store.acquire(&first, "1", &installation()).unwrap();
    store.acquire(&first, "1", &rollback).unwrap();
    // Not pinned for this owner: refused, nothing published.
    let before = root.bytes();
    code(
        store.retain_only(&second, &installation()),
        "resourceConflict",
        "installed bundle does not hold its durable installation reference",
    );
    assert_eq!(root.bytes(), before);
    store.acquire(&second, "1", &installation()).unwrap();
    store.retain_only(&second, &installation()).unwrap();
    // Only the owner's other pin went; another owner's stays.
    assert_eq!(
        root.references(&first),
        json!([{"kind": "rollback", "id": "previous"}])
    );
    assert_eq!(
        root.references(&second),
        json!([{"kind": "installation", "id": "runtime-service-installation"}])
    );
    // Always published, even with nothing left to release.
    let inode = root.inode();
    let bytes = root.bytes();
    store.retain_only(&second, &installation()).unwrap();
    assert_ne!(root.inode(), inode);
    assert_eq!(root.bytes(), bytes);
    // A removed selection cannot be kept.
    code(
        store.retain_only(
            &format!("bundle:sha256:{}", "0".repeat(64)),
            &installation(),
        ),
        "resourceNotFound",
        "bundle reference does not exist",
    );
}

#[test]
fn retain_only_and_release_all_verify_every_record_before_publishing() {
    let root = Root::new();
    let first = root.register("First");
    let second = root.register("Second");
    let store = root.store();
    store.acquire(&first, "1", &installation()).unwrap();
    store.acquire(&second, "1", &installation()).unwrap();
    let before = root.bytes();
    let digest = &first["bundle:sha256:".len()..];
    fs::write(
        root.store_path()
            .join(format!("bundle-{digest}.app/Contents/Info.plist")),
        b"<plist><dict></dict></plist>",
    )
    .unwrap();
    code(
        store.retain_only(&second, &installation()),
        "recordUnreadable",
        "registered bundle content failed integrity validation",
    );
    code(
        store.release_all(&installation()),
        "recordUnreadable",
        "registered bundle content failed integrity validation",
    );
    assert_eq!(root.bytes(), before);
}

#[test]
fn release_all_releases_every_pin_of_the_owner_and_always_publishes() {
    let root = Root::new();
    let first = root.register("First");
    let second = root.register("Second");
    let store = root.store();
    let job = ReferenceOwner::new("job", "job-1").unwrap();
    store.acquire(&first, "1", &installation()).unwrap();
    store.acquire(&second, "1", &installation()).unwrap();
    store.acquire(&second, "1", &job).unwrap();
    store.release_all(&installation()).unwrap();
    assert_eq!(root.references(&first), json!([]));
    assert_eq!(
        root.references(&second),
        json!([{"kind": "job", "id": "job-1"}])
    );
    let inode = root.inode();
    let bytes = root.bytes();
    store.release_all(&installation()).unwrap();
    assert_ne!(root.inode(), inode);
    assert_eq!(root.bytes(), bytes);
    // Now the bundle can be retired, as Swift's `remove` requires.
    assert_eq!(store.retire(&first, "1").unwrap()["state"], "removed");
}

#[test]
fn a_fresh_store_is_initialized_and_an_index_missing_beside_state_is_refused() {
    // Swift's `readIndex(create:)`: the empty index published first.
    let root = Root::new();
    root.store().release_all(&installation()).unwrap();
    assert_eq!(
        root.bytes(),
        br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#
    );
    let root = Root::new();
    code(
        root.store().acquire(
            &format!("bundle:sha256:{}", "0".repeat(64)),
            "1",
            &installation(),
        ),
        "resourceNotFound",
        "bundle reference does not exist",
    );
    assert!(root.store_path().join("bundles.json").is_file());
    // Retained state beside no index is never an empty store.
    let root = Root::new();
    fs::write(root.store_path().join("retained"), b"keep").unwrap();
    code(
        root.store().release_all(&installation()),
        "recordUnreadable",
        "bundle index is missing beside retained bootstrap state",
    );
    assert!(!root.store_path().join("bundles.json").exists());
    // An index off its bounded schema is refused, never rewritten.
    let root = Root::new();
    let index = root.store_path().join("bundles.json");
    fs::write(
        &index,
        br#"{"extra":true,"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#,
    )
    .unwrap();
    fs::set_permissions(&index, fs::Permissions::from_mode(0o600)).unwrap();
    code(
        root.store().release_all(&installation()),
        "recordUnreadable",
        "bundle index failed bounded schema and identity validation",
    );
    assert_eq!(
        root.bytes(),
        br#"{"extra":true,"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#
    );
}

#[test]
fn the_store_lock_is_taken_without_waiting() {
    let root = Root::new();
    let reference = root.register("First");
    let held = HostDirectory::open(&root.store_path())
        .unwrap()
        .lock_document(".lock")
        .unwrap();
    let before = root.bytes();
    let busy = "another bootstrap operation holds the store; retry after it completes";
    code(
        root.store().acquire(&reference, "1", &installation()),
        "resourceConflict",
        busy,
    );
    code(
        root.store().retain_only(&reference, &installation()),
        "resourceConflict",
        busy,
    );
    code(
        root.store().release_all(&installation()),
        "resourceConflict",
        busy,
    );
    drop(held);
    assert_eq!(root.bytes(), before);
    root.store()
        .acquire(&reference, "1", &installation())
        .unwrap();
}

#[test]
fn creating_the_store_makes_missing_directories_owner_only_and_refuses_a_link() {
    let root = Root::new();
    let store = root
        .0
        .join("home/Library/Application Support/ArkDeck/Bootstrap/v1");
    crate::create_store(&store).unwrap();
    for directory in [root.0.join("home"), store.clone()] {
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    crate::create_store(&store).unwrap();
    code(
        crate::create_store(Path::new("relative/v1")),
        "invalidInput",
        "bundle and registry locations must be absolute local paths",
    );
    std::os::unix::fs::symlink(&store, root.0.join("linked")).unwrap();
    code(
        crate::create_store(&root.0.join("linked")),
        "fileIdentityChanged",
        "directory is symbolic",
    );
    let public = root.0.join("public");
    fs::DirBuilder::new().mode(0o755).create(&public).unwrap();
    fs::set_permissions(&public, fs::Permissions::from_mode(0o755)).unwrap();
    code(
        crate::create_store(&public),
        "fileIdentityChanged",
        "registry must be owned by the current user with private permissions",
    );
}
