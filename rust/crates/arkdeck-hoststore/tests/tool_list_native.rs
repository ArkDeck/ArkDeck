#![cfg(target_os = "macos")]
use arkdeck_hoststore::ToolRegistryStore;
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs, os::unix::fs::MetadataExt, path::Path};
type Preserved = BTreeMap<String, (Vec<u8>, u64, u64, u32, i64, i64, i64, i64)>;
fn preserved(root: &Path) -> Preserved {
    fn walk(base: &Path, path: &Path, out: &mut Preserved) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            let relative = path
                .strip_prefix(base)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            if relative == "tool-snapshots" {
                continue;
            }
            let m = fs::symlink_metadata(&path).unwrap();
            assert!(!m.file_type().is_symlink());
            out.insert(
                relative,
                (
                    if m.is_file() {
                        fs::read(&path).unwrap()
                    } else {
                        vec![]
                    },
                    m.dev(),
                    m.ino(),
                    m.mode(),
                    m.mtime(),
                    m.mtime_nsec(),
                    m.ctime(),
                    m.ctime_nsec(),
                ),
            );
            if m.is_dir() {
                walk(base, &path, out);
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}
#[test]
#[ignore = "requires a fresh raw-xattr-preserving copy of actual Swift/Rust-retired host inventory"]
fn actual_native_combined_inventory_matches_both_swift_and_rust_receipts() {
    let root_text = std::env::var("ARKDECK_LIST_NATIVE_ROOT").expect("explicit root");
    assert!(root_text.starts_with("/private/tmp/tool-list-native-"));
    let root = Path::new(&root_text);
    let swift_path = std::env::var("ARKDECK_LIST_NATIVE_SWIFT_RECEIPT").unwrap();
    let swift: Value = serde_json::from_slice(&fs::read(&swift_path).unwrap()).unwrap();
    let rust: Value = serde_json::from_slice(
        &fs::read(Path::new(&swift_path).with_file_name("actual-rust-retirement.json")).unwrap(),
    )
    .unwrap();
    let mut expected = vec![
        swift["swiftRetiredHDC"].clone(),
        rust["rustRetiredHDC"].clone(),
        rust["rustRetiredDevEco"].clone(),
    ];
    expected.sort_by(|a, b| a["toolRef"].as_str().cmp(&b["toolRef"].as_str()));
    let before = preserved(root);
    let owner = ToolRegistryStore::open_existing(root).unwrap();
    let first = owner.list_page(1, None).unwrap();
    let revision = first["snapshotRevision"].clone();
    let mut pages = vec![first.clone()];
    let mut rows = first["items"].as_array().unwrap().clone();
    let mut next = first["nextCursor"].as_str().map(str::to_owned);
    while let Some(cursor) = next {
        let page = ToolRegistryStore::open_existing(root)
            .unwrap()
            .list_page(1, Some(&cursor))
            .unwrap();
        assert_eq!(page["snapshotRevision"], revision);
        assert_eq!(owner.list_page(1, Some(&cursor)).unwrap(), page);
        assert_eq!(
            owner.list_page(2, Some(&cursor)).unwrap_err().code,
            "invalidCursor"
        );
        rows.extend(page["items"].as_array().unwrap().clone());
        next = page["nextCursor"].as_str().map(str::to_owned);
        pages.push(page);
    }
    assert_eq!(rows, expected);
    assert_eq!(pages.len(), 3);
    for page in &pages {
        assert_eq!(page["schemaVersion"], "arkdeck.cli.page/1");
        assert_eq!(page["order"], "toolRef:asc");
        assert_eq!(page["pageKind"], "snapshot");
    }
    let all = owner.list_page(100, None).unwrap();
    assert_eq!(all["items"], json!(expected));
    assert_eq!(all["hasMore"], false);
    assert_eq!(preserved(root), before);
    let output = Path::new(&swift_path).with_file_name("actual-rust-tool-list.json");
    use std::io::Write;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output)
        .unwrap()
        .write_all(
            &serde_json::to_vec(
                &json!({"root":root_text,"pages":pages,"all":all,"newDispatchCount":0}),
            )
            .unwrap(),
        )
        .unwrap();
    eprintln!(
        "native combined host inventory verified; receipt={}",
        output.display()
    );
}
