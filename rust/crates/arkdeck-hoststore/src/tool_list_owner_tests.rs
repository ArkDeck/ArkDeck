use super::*;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::PathBuf,
};
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let n = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/tool-list-{n:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn store(&self) -> ToolRegistryStore {
        ToolRegistryStore::open_existing(&self.0).unwrap()
    }
    fn write(&self, name: &str, value: &Value) {
        self.bytes(name, &serde_json::to_vec(value).unwrap());
    }
    fn bytes(&self, name: &str, bytes: &[u8]) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn empty(&self) {
        self.write(
            BUNDLES,
            &json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}),
        );
        self.write(
            TOOLS,
            &json!({"schemaVersion":"arkdeck.bootstrap-tools/2","records":[]}),
        );
        self.write(
            DEVECO,
            &json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[]}),
        );
    }
    fn snapshot(&self, page: &Value) -> Value {
        serde_json::from_slice(
            &fs::read(self.0.join("tool-snapshots").join(format!(
                "snapshot-{}.json",
                page["snapshotRevision"].as_str().unwrap()
            )))
            .unwrap(),
        )
        .unwrap()
    }
}
// Historical unsigned metadata only; never a positive native trust fixture.
fn removed(digit: &str) -> Value {
    let children=["productManifest","sdkManifest","node","hvigor","signedResourceEnvelope"].map(|role|json!({"role":role,"relativePath":"retired/path","device":1,"inode":1,"byteCount":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0,"sha256":"0".repeat(64),"executable":false}));
    json!({"reference":format!("toolchain:sha256:{}",digit.repeat(64)),"contentDigest":digit.repeat(64),"root":{"path":"/missing.app/Contents","device":1,"inode":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0},"productVersion":"1","buildNumber":"build","sdkVersion":"1","apiVersion":"api","registeredAtUTC":"2026-09-11T00:00:00Z","bundleTrust":{"signature":"unsigned"},"children":children,"generation":2,"state":"removed","references":[]})
}
fn code(result: Result<Value, WireError>, expected: &str) {
    let error = result.unwrap_err();
    assert_eq!(error.code, expected, "{error:?}");
    assert_eq!(
        error.details.as_ref().unwrap()["phase"],
        "bootstrapRegistryOwner"
    );
    assert_eq!(error.details.as_ref().unwrap()["newDispatchCount"], 0);
}
#[test]
fn fresh_list_initializes_only_bounded_metadata_while_existing_readers_remain_readonly() {
    let root = Root::new();
    let store = root.store();
    assert!(store.list().is_err());
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
    let page = store.list_page(100, None).unwrap();
    assert_eq!(page["items"], json!([]));
    assert_eq!(page["order"], "toolRef:asc");
    assert_eq!(page["hasMore"], false);
    assert_eq!(page["nextCursor"], Value::Null);
    assert!(decode_bundles(&fs::read(root.0.join(BUNDLES)).unwrap()).is_ok());
    assert!(decode_tools(&fs::read(root.0.join(TOOLS)).unwrap()).is_ok());
    assert!(deveco_registry::read_index(&fs::read(root.0.join(DEVECO)).unwrap()).is_ok());
    assert_eq!(
        fs::metadata(root.0.join("tool-snapshots")).unwrap().mode() & 0o777,
        0o700
    );
    let snapshot = root.snapshot(&page);
    let cursor = snapshot["tokens"][0].as_str().unwrap();
    assert_eq!(root.store().list_page(100, Some(cursor)).unwrap(), page);
    code(store.list_page(1, Some(cursor)), "invalidCursor");
    let parent = Root::new();
    let leaf = parent.0.join("bootstrap");
    let owner = ToolRegistryStore::open_or_create(&leaf).unwrap();
    assert_eq!(fs::read_dir(&leaf).unwrap().count(), 0);
    owner.list_page(1, None).unwrap();
    symlink(&leaf, parent.0.join("alias")).unwrap();
    assert!(ToolRegistryStore::open_or_create(&parent.0.join("alias")).is_err());
}
#[test]
fn inventory_order_and_missing_index_guards_precede_paging() {
    for name in ["tool-snapshots", "tools.json", "unknown"] {
        let root = Root::new();
        root.bytes(name, b"retained");
        code(root.store().list_page(0, Some("bad")), "recordUnreadable");
        assert!(!root.0.join(BUNDLES).exists());
    }
    for name in ["tool-snapshots", "tool-retained.hdc", ".tool-stage"] {
        let root = Root::new();
        root.write(
            BUNDLES,
            &json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}),
        );
        root.bytes(name, b"retained");
        code(root.store().list_page(0, Some("bad")), "recordUnreadable");
        assert!(!root.0.join(TOOLS).exists());
        assert!(!root.0.join(DEVECO).exists());
    }
    let root = Root::new();
    root.empty();
    root.bytes(TOOLS, b"{}");
    root.bytes(DEVECO, b"{}");
    code(root.store().list_page(0, Some("bad")), "recordUnreadable");
    assert!(!root.0.join("tool-snapshots").exists());
    let root = Root::new();
    root.empty();
    let mut record = removed("0");
    record["state"] = json!("available");
    record["generation"] = json!(1);
    root.write(
        DEVECO,
        &json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[record]}),
    );
    code(
        root.store().list_page(0, Some("bad")),
        "fileIdentityChanged",
    );
    assert!(!root.0.join("tool-snapshots").exists());
}
#[test]
fn immutable_continuation_keeps_removed_deveco_rows_but_revalidates_current_inventory() {
    let root = Root::new();
    root.empty();
    root.write(DEVECO,&json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[removed("0"),removed("1")]}));
    let first = root.store().list_page(1, None).unwrap();
    assert_eq!(first["items"][0]["toolRef"], removed("0")["reference"]);
    let cursor = first["nextCursor"].as_str().unwrap();
    let second = root.store().list_page(1, Some(cursor)).unwrap();
    assert_eq!(second["items"][0]["toolRef"], removed("1")["reference"]);
    root.write(
        DEVECO,
        &json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[]}),
    );
    assert_eq!(root.store().list_page(1, Some(cursor)).unwrap(), second);
    assert_eq!(root.store().list_page(1, None).unwrap()["items"], json!([]));
    root.bytes(DEVECO, b"{}");
    code(root.store().list_page(1, Some(cursor)), "recordUnreadable");
}
#[test]
fn hdc_removed_content_is_verified_before_deveco_and_before_cursor() {
    let root = Root::new();
    root.empty();
    let mut record = json!({"reference":format!("tool:sha256:{}","0".repeat(64)),"contentDigest":"0".repeat(64),"executableSHA256":"f".repeat(64),"byteCount":1,"registeredAt":"2026-09-11T00:00:00Z","trust":{"signature":"unsigned"},"dependencies":[],"relocatable":false,"generation":2,"state":"removed","references":[]});
    root.write(
        TOOLS,
        &json!({"schemaVersion":"arkdeck.bootstrap-tools/2","records":[record.clone()]}),
    );
    root.bytes(DEVECO, b"{}");
    code(root.store().list_page(0, Some("bad")), "recordUnreadable");
    assert!(!root.0.join("tool-snapshots").exists());
    record["generation"] = json!(1);
    record["state"] = json!("available");
    root.write(
        TOOLS,
        &json!({"schemaVersion":"arkdeck.bootstrap-tools/2","records":[record]}),
    );
    code(root.store().list_page(100, None), "recordUnreadable");
}
#[test]
fn shared_lock_spans_both_families_and_pager_and_all_indexes_are_rebound() {
    let root = Root::new();
    root.empty();
    let store = root.store();
    store
        .list_page_checkpoint(1, None, |_| {
            assert_eq!(
                store.root.lock_document(".lock").err().unwrap().kind(),
                io::ErrorKind::WouldBlock
            );
        })
        .unwrap();
    for name in [BUNDLES, TOOLS, DEVECO] {
        let root = Root::new();
        root.empty();
        let store = root.store();
        code(
            store.list_page_checkpoint(1, Some("bad"), |phase| {
                if phase == "beforePager" {
                    root.bytes(name, b"{}");
                }
            }),
            "recordUnreadable",
        );
    }
    let root = Root::new();
    root.empty();
    let store = root.store();
    code(
        store.list_page_checkpoint(1, None, |phase| {
            if phase == "afterPager" {
                fs::rename(
                    root.0.join("tool-snapshots"),
                    root.0.join("retained-snapshots"),
                )
                .unwrap();
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(root.0.join("tool-snapshots"))
                    .unwrap();
            }
        }),
        "recordUnreadable",
    );
    assert!(root.0.join("retained-snapshots").exists());
}
#[test]
fn page_bounds_and_cursor_are_checked_after_valid_empty_inventory() {
    let root = Root::new();
    for size in [0, 1001, usize::MAX] {
        code(root.store().list_page(size, None), "invalidInput");
    }
    code(root.store().list_page(100, Some("bad")), "invalidCursor");
    let lock = root.store().root.lock_document(".lock").unwrap();
    code(root.store().list_page(0, Some("bad")), "resourceConflict");
    drop(lock);
}
