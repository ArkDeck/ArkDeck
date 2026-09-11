use super::*;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
};

// Every fixture is newly created under the physical temporary root and retained.
// These metadata/negative tests do not establish a positive signing identity.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("bundle-list-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, bytes: &[u8]) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn store(&self) -> BundleRegistryReadStore {
        BundleRegistryReadStore::open_existing(&self.0).unwrap()
    }
    fn index(&self) {
        self.write(
            "bundles.json",
            br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1"}"#,
        );
    }
    fn snapshot(&self, page: &Value) -> Value {
        serde_json::from_slice(
            &fs::read(self.0.join("bundle-snapshots").join(format!(
                "snapshot-{}.json",
                page["snapshotRevision"].as_str().unwrap()
            )))
            .unwrap(),
        )
        .unwrap()
    }
}
fn error_code(result: Result<Value, WireError>, code: &str) {
    let error = result.unwrap_err();
    assert_eq!(error.code, code, "{error:?}");
    assert_eq!(
        error.details.as_ref().unwrap()["phase"],
        "bootstrapRegistryOwner"
    );
    assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
}

#[test]
fn first_list_initializes_empty_registry_but_existing_readers_do_not() {
    let root = Root::new();
    let store = root.store();
    assert!(store.list().is_err());
    assert!(
        store
            .inspect(&format!("bundle:sha256:{}", "0".repeat(64)))
            .is_err()
    );
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
    let page = store.list_page(100, None).unwrap();
    assert_eq!(page["schemaVersion"], "arkdeck.cli.page/1");
    assert_eq!(page["pageKind"], "snapshot");
    assert_eq!(page["order"], "bundleRef:asc");
    assert_eq!(page["items"], json!([]));
    assert_eq!(page["hasMore"], false);
    assert_eq!(page["nextCursor"], Value::Null);
    assert_eq!(
        decode_bundles(&fs::read(root.0.join("bundles.json")).unwrap())
            .unwrap()
            .projection,
        json!([])
    );
    assert_eq!(
        fs::metadata(root.0.join(".lock"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.0.join("bundle-snapshots"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    let snapshot = root.snapshot(&page);
    let cursor = snapshot["tokens"][0].as_str().unwrap();
    let index_before = fs::metadata(root.0.join("bundles.json")).unwrap();
    assert_eq!(root.store().list_page(100, Some(cursor)).unwrap(), page);
    assert!(same_document(
        &index_before,
        &fs::metadata(root.0.join("bundles.json")).unwrap()
    ));
    error_code(store.list_page(1, Some(cursor)), "invalidCursor");
}

#[test]
fn optional_leaf_constructor_does_not_initialize_metadata_or_follow_links() {
    let parent = Root::new();
    let leaf = parent.0.join("bootstrap");
    let store = BundleRegistryReadStore::open_or_create(&leaf).unwrap();
    assert_eq!(fs::read_dir(&leaf).unwrap().count(), 0);
    assert!(store.list().is_err());
    store.list_page(1, None).unwrap();
    let alias = parent.0.join("alias");
    symlink(&leaf, &alias).unwrap();
    assert!(BundleRegistryReadStore::open_or_create(&alias).is_err());
    assert!(BundleRegistryReadStore::open_or_create(&parent.0.join("missing/nested")).is_err());
}

#[test]
fn missing_index_beside_retained_state_is_never_initialized() {
    for name in [
        "tool-existing.hdc",
        "bundle-snapshots",
        "tools.json",
        "unknown",
    ] {
        let root = Root::new();
        root.write(name, b"existing-content");
        error_code(root.store().list_page(100, None), "recordUnreadable");
        assert!(!root.0.join("bundles.json").exists());
        assert_eq!(fs::read(root.0.join(name)).unwrap(), b"existing-content");
    }
}

#[test]
fn validation_precedes_page_bounds_and_cursor_including_existing_snapshot() {
    let root = Root::new();
    let store = root.store();
    let page = store.list_page(1, None).unwrap();
    let snapshot = root.snapshot(&page);
    let cursor = snapshot["tokens"][0].as_str().unwrap();
    for size in [0, 1001, usize::MAX] {
        error_code(store.list_page(size, None), "invalidInput");
    }
    error_code(store.list_page(1, Some("bad")), "invalidCursor");
    root.write(
        "bundles.json",
        br#"{"records":[],"schemaVersion":"arkdeck.bootstrap-bundles/1","extra":true}"#,
    );
    for cursor in [None, Some(cursor), Some("bad")] {
        error_code(store.list_page(0, cursor), "recordUnreadable");
    }
    // A valid index that names missing content must also fail before paging;
    // no fabricated signature is used to satisfy the native verifier.
    root.write(
        "bundles.json",
        &serde_json::to_vec(&json!({
            "schemaVersion":"arkdeck.bootstrap-bundles/1", "records":[{
                "reference":format!("bundle:sha256:{}", "0".repeat(64)), "digest":"0".repeat(64),
                "registeredAtUTC":"2026-09-11T00:00:00Z", "byteCount":0, "entryCount":1,
                "generation":1, "state":"available", "references":[]
            }]
        }))
        .unwrap(),
    );
    error_code(store.list_page(1, Some(cursor)), "recordUnreadable");
    error_code(store.list_page(0, Some("bad")), "recordUnreadable");
}

#[test]
fn bootstrap_lock_covers_both_pager_success_and_failure() {
    let root = Root::new();
    let store = root.store();
    store.list_page(1, None).unwrap();
    for cursor in [None, Some("bad")] {
        let result = store.list_page_with_checkpoint(1, cursor, |_| {
            assert!(
                root.store()
                    .root
                    .try_lock_existing_strict(".lock")
                    .unwrap()
                    .is_none()
            );
        });
        if cursor.is_some() {
            error_code(result, "invalidCursor");
        } else {
            result.unwrap();
        }
        assert!(
            root.store()
                .root
                .try_lock_existing_strict(".lock")
                .unwrap()
                .is_some()
        );
    }
    let lock = store.root.lock_document(".lock").unwrap();
    error_code(store.list_page(0, Some("bad")), "resourceConflict");
    drop(lock);
    let snapshots = store.root.child("bundle-snapshots").unwrap();
    let _snapshot_lock = snapshots.lock_document(".snapshots.lock").unwrap();
    error_code(store.list_page(1, None), "resourceConflict");
}

#[test]
fn changed_registry_or_lock_after_pager_overrides_success_and_cursor_error() {
    for cursor in [None, Some("bad")] {
        for replacement in ["index", "lock", "root", "snapshots"] {
            let root = Root::new();
            let store = root.store();
            store.list_page(1, None).unwrap();
            let result = store.list_page_with_checkpoint(1, cursor, |phase| {
                if phase != "afterPager" {
                    return;
                }
                match replacement {
                    "index" => {
                        fs::rename(
                            root.0.join("bundles.json"),
                            root.0.join("retained-index.json"),
                        )
                        .unwrap();
                        root.index(); // Exact same bytes, different inode.
                    }
                    "lock" => {
                        fs::rename(root.0.join(".lock"), root.0.join("retained-lock")).unwrap();
                        root.write(".lock", b"");
                    }
                    "root" => {
                        fs::rename(&root.0, root.0.with_extension("retained")).unwrap();
                        fs::DirBuilder::new().mode(0o700).create(&root.0).unwrap();
                    }
                    "snapshots" => {
                        fs::rename(
                            root.0.join("bundle-snapshots"),
                            root.0.join("retained-snapshots"),
                        )
                        .unwrap();
                        fs::DirBuilder::new()
                            .mode(0o700)
                            .create(root.0.join("bundle-snapshots"))
                            .unwrap();
                    }
                    _ => unreachable!(),
                }
            });
            error_code(result, "recordUnreadable");
        }
    }
}

#[test]
fn unsafe_index_and_snapshot_locations_are_not_repaired() {
    let root = Root::new();
    root.index();
    fs::set_permissions(
        root.0.join("bundles.json"),
        fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    error_code(root.store().list_page(1, None), "recordUnreadable");
    assert!(!root.0.join("bundle-snapshots").exists());
    fs::set_permissions(
        root.0.join("bundles.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let outside = Root::new();
    symlink(&outside.0, root.0.join("bundle-snapshots")).unwrap();
    error_code(root.store().list_page(0, Some("bad")), "recordUnreadable");
    assert_eq!(fs::read_dir(outside.0).unwrap().count(), 0);
}

#[test]
#[ignore = "requires explicit temporary native registry and actual Swift page receipts"]
fn native_swift_cursor_and_reopened_rust_pages_preserve_registered_content() {
    use std::{collections::BTreeMap, io::Write, os::unix::fs::OpenOptionsExt};
    fn explicit_temp(variable: &str, existing: bool) -> PathBuf {
        let path = PathBuf::from(std::env::var_os(variable).expect(variable));
        let system_temp = std::env::temp_dir().canonicalize().unwrap();
        assert!(path.starts_with("/private/tmp") || path.starts_with(system_temp));
        if existing {
            assert_eq!(path.canonicalize().unwrap(), path);
        } else {
            assert_eq!(
                path.parent().unwrap().canonicalize().unwrap(),
                path.parent().unwrap()
            );
            assert!(fs::symlink_metadata(&path).is_err());
        }
        path
    }
    fn capture(root: &Path) -> BTreeMap<PathBuf, (Metadata, Option<String>)> {
        fn walk(
            path: &Path,
            relative: &Path,
            output: &mut BTreeMap<PathBuf, (Metadata, Option<String>)>,
        ) {
            let metadata = fs::symlink_metadata(path).unwrap();
            assert!(!metadata.file_type().is_symlink());
            let digest = if metadata.is_file() {
                Some(arkdeck_contract::sha256_hex(&fs::read(path).unwrap()))
            } else {
                assert!(metadata.is_dir());
                None
            };
            output.insert(relative.into(), (metadata.clone(), digest));
            if metadata.is_dir() {
                for entry in fs::read_dir(path).unwrap() {
                    let entry = entry.unwrap();
                    if relative.as_os_str().is_empty() && entry.file_name() == "bundle-snapshots" {
                        continue;
                    }
                    walk(&entry.path(), &relative.join(entry.file_name()), output);
                }
            }
        }
        let mut output = BTreeMap::new();
        walk(root, Path::new(""), &mut output);
        output
    }
    let root = explicit_temp("ARKDECK_BUNDLE_LIST_NATIVE_ROOT", true);
    let swift_path = explicit_temp("ARKDECK_BUNDLE_LIST_SWIFT_PAGES", true);
    let output_path = explicit_temp("ARKDECK_BUNDLE_LIST_RUST_PAGES", false);
    let swift: Value = serde_json::from_slice(&fs::read(swift_path).unwrap()).unwrap();
    assert_eq!(swift["first"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(swift["second"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(swift["first"]["hasMore"], true);
    assert_eq!(swift["second"]["hasMore"], false);
    // This test generates one small snapshot. Stay below published retention
    // limits so this native compatibility run cannot reclaim an existing page.
    let snapshot_entries = fs::read_dir(root.join("bundle-snapshots"))
        .unwrap()
        .map(|entry| entry.unwrap())
        .collect::<Vec<_>>();
    assert!(snapshot_entries.len() < 24);
    let prior_pages: BTreeMap<_, _> = snapshot_entries
        .iter()
        .map(|entry| {
            assert!(entry.file_type().unwrap().is_file());
            (entry.file_name(), fs::read(entry.path()).unwrap())
        })
        .collect();
    assert!(prior_pages.values().map(|bytes| bytes.len()).sum::<usize>() < 48 * 1024 * 1024);
    let before = capture(&root);
    let store = BundleRegistryReadStore::open_existing(&root).unwrap();
    let consumed = store
        .list_page(1, swift["first"]["nextCursor"].as_str())
        .unwrap();
    assert_eq!(consumed, swift["second"]);
    let first = store.list_page(1, None).unwrap();
    assert_eq!(first["items"], swift["first"]["items"]);
    let cursor = first["nextCursor"].as_str().unwrap();
    drop(store);
    let second = BundleRegistryReadStore::open_existing(&root)
        .unwrap()
        .list_page(1, Some(cursor))
        .unwrap();
    assert_eq!(second["items"], swift["second"]["items"]);
    assert_eq!(second["snapshotRevision"], first["snapshotRevision"]);
    assert_eq!(second["hasMore"], false);
    assert_eq!(second["nextCursor"], Value::Null);
    let after = capture(&root);
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>()
    );
    for (path, (metadata, digest)) in &before {
        assert!(
            same_document(metadata, &after[path].0),
            "metadata changed: {path:?}"
        );
        assert_eq!(digest, &after[path].1, "content changed: {path:?}");
    }
    for (name, bytes) in prior_pages {
        assert_eq!(
            fs::read(root.join("bundle-snapshots").join(name)).unwrap(),
            bytes
        );
    }
    let receipt =
        json!({"bootstrapRoot":root, "first":first, "second":second, "deviceAcceptance":false});
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&output_path)
        .unwrap();
    output
        .write_all(&serde_json::to_vec(&receipt).unwrap())
        .unwrap();
    output.write_all(b"\n").unwrap();
    output.sync_all().unwrap();
    println!(
        "nativeBundleListReceipt={}",
        json!({"bootstrapRoot":root,"cursor":cursor,"receiptPath":output_path})
    );
}
