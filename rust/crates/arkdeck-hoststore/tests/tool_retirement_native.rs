#![cfg(target_os = "macos")]
use arkdeck_hoststore::{DevEcoRegistryStore, ToolRegistryStore};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs, os::unix::fs::MetadataExt, path::Path};
type PreservedTree = BTreeMap<String, (Vec<u8>, u64, u64, u32, i64, i64)>;
fn preserved(root: &Path) -> PreservedTree {
    fn walk(base: &Path, path: &Path, out: &mut PreservedTree) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            let relative = path
                .strip_prefix(base)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned();
            if relative == "tools.json" || relative == "deveco-toolchains.json" {
                continue;
            }
            let meta = fs::symlink_metadata(&path).unwrap();
            assert!(!meta.file_type().is_symlink());
            out.insert(
                relative,
                (
                    if meta.is_file() {
                        fs::read(&path).unwrap()
                    } else {
                        Vec::new()
                    },
                    meta.dev(),
                    meta.ino(),
                    meta.mode(),
                    meta.mtime(),
                    meta.mtime_nsec(),
                ),
            );
            if meta.is_dir() {
                walk(base, &path, out);
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}
fn source_roles(root: &Path) -> Vec<(arkdeck_platform::DevEcoFileFacts, Vec<u8>)> {
    use arkdeck_platform::{DevEcoRole, DevEcoRoot};
    let root = DevEcoRoot::open(root).unwrap();
    [
        DevEcoRole::ProductManifest,
        DevEcoRole::SdkManifest,
        DevEcoRole::Node,
        DevEcoRole::Hvigor,
        DevEcoRole::SignedResourceEnvelope,
    ]
    .into_iter()
    .map(|role| {
        let value = root.read_role(role).unwrap();
        (value.facts, value.bytes)
    })
    .collect()
}
#[test]
#[ignore = "requires explicitly selected fresh Swift-produced native host registry; performs metadata retirement"]
fn actual_swift_registry_retires_both_families_without_touching_content() {
    let root_string =
        std::env::var("ARKDECK_RETIRE_NATIVE_ROOT").expect("explicit isolated registry");
    assert!(root_string.starts_with("/private/tmp/xpa012-tool-retirement-native-"));
    let root = Path::new(&root_string);
    let receipt_path = std::env::var("ARKDECK_RETIRE_NATIVE_SWIFT_RECEIPT").unwrap();
    let swift: Value = serde_json::from_slice(&fs::read(&receipt_path).unwrap()).unwrap();
    let before = preserved(root);
    let source_path = Path::new("/Applications/DevEco-Studio.app/Contents");
    let source_before = source_roles(source_path);
    let hdc = ToolRegistryStore::open_existing(root).unwrap();
    let deveco = DevEcoRegistryStore::open_existing(root).unwrap();
    let hdc_ref = swift["rustAvailableHDC"]["toolRef"].as_str().unwrap();
    let deveco_ref = swift["rustAvailableDevEco"]["toolRef"].as_str().unwrap();
    assert_eq!(hdc.inspect(hdc_ref).unwrap(), swift["rustAvailableHDC"]);
    assert_eq!(
        deveco.inspect(deveco_ref).unwrap(),
        swift["rustAvailableDevEco"]
    );
    assert_eq!(
        hdc.inspect(swift["swiftRetiredHDC"]["toolRef"].as_str().unwrap())
            .unwrap(),
        swift["swiftRetiredHDC"]
    );
    let tools_before: Value =
        serde_json::from_slice(&fs::read(root.join("tools.json")).unwrap()).unwrap();
    let deveco_before: Value =
        serde_json::from_slice(&fs::read(root.join("deveco-toolchains.json")).unwrap()).unwrap();
    let retired_hdc = hdc.retire(hdc_ref, "1").unwrap();
    let retired_deveco = deveco.retire(deveco_ref, "1").unwrap();
    let mut expected_hdc = swift["rustAvailableHDC"].clone();
    expected_hdc["generation"] = json!("2");
    expected_hdc["state"] = json!("removed");
    assert_eq!(retired_hdc, expected_hdc);
    assert_eq!(retired_deveco, swift["swiftRetiredDevEco"]);
    for (name, mut expected, target) in [
        ("tools.json", tools_before, hdc_ref),
        ("deveco-toolchains.json", deveco_before, deveco_ref),
    ] {
        let record = expected["records"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|r| r["reference"] == target)
            .unwrap();
        record["state"] = json!("removed");
        record["generation"] = json!(2);
        let bytes = fs::read(root.join(name)).unwrap();
        let actual: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(actual, expected);
    }
    let tools_after = fs::read(root.join("tools.json")).unwrap();
    let deveco_after = fs::read(root.join("deveco-toolchains.json")).unwrap();
    assert_eq!(
        ToolRegistryStore::open_existing(root)
            .unwrap()
            .retire(hdc_ref, "1")
            .unwrap(),
        retired_hdc
    );
    assert_eq!(
        DevEcoRegistryStore::open_existing(root)
            .unwrap()
            .retire(deveco_ref, "1")
            .unwrap(),
        retired_deveco
    );
    assert_eq!(
        hdc.retire(hdc_ref, "2").unwrap_err().code,
        "resourceConflict"
    );
    assert_eq!(
        deveco.retire(deveco_ref, "2").unwrap_err().code,
        "resourceConflict"
    );
    assert_eq!(fs::read(root.join("tools.json")).unwrap(), tools_after);
    assert_eq!(
        fs::read(root.join("deveco-toolchains.json")).unwrap(),
        deveco_after
    );
    assert_eq!(preserved(root), before);
    assert_eq!(source_roles(source_path), source_before);
    let output = Path::new(&receipt_path).with_file_name("actual-rust-retirement.json");
    assert!(!output.exists());
    use std::io::Write;
    fs::OpenOptions::new().write(true).create_new(true).open(&output).unwrap().write_all(&serde_json::to_vec(&json!({"rustRetiredHDC":retired_hdc,"rustRetiredDevEco":retired_deveco,"newDispatchCount":0})).unwrap()).unwrap();
    eprintln!(
        "native host metadata retirement verified; receipt={}",
        output.display()
    );
}
