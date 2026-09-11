#![cfg(target_os = "macos")]
use arkdeck_hoststore::{DevEcoRegistryStore, decode_deveco_toolchains};
use serde_json::{Value, json};
use std::{
    fs, io,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let n = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/deveco-read-{n:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, value: &Value) {
        fs::write(self.0.join(name), serde_json::to_vec(value).unwrap()).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn removed() -> Value {
    // Historical, explicitly unsigned metadata fixture. It is never passed as
    // successful live content or publisher evidence.
    let children=["productManifest","sdkManifest","node","hvigor","signedResourceEnvelope"].map(|role|json!({"role":role,"relativePath":"retired/path","device":1,"inode":1,"byteCount":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0,"sha256":"0".repeat(64),"executable":false}));
    json!({"schemaVersion":"arkdeck.bootstrap-deveco-toolchains/1","records":[{"reference":format!("toolchain:sha256:{}","0".repeat(64)),"contentDigest":"0".repeat(64),"root":{"path":"/missing.app/Contents","device":1,"inode":1,"modifiedSeconds":0,"modifiedNanos":0,"changedSeconds":0,"changedNanos":0},"productVersion":"1","buildNumber":"build","sdkVersion":"1","apiVersion":"api","registeredAtUTC":"2026-09-11T00:00:00Z","bundleTrust":{"signature":"unsigned"},"children":children,"generation":2,"state":"removed","references":[]}]})
}
#[test]
fn frozen_metadata_refuses_schema_drift_and_preserves_removed_external_root_semantics() {
    let original = removed();
    let bytes = serde_json::to_vec(&original).unwrap();
    let decoded = decode_deveco_toolchains(&bytes).unwrap();
    let output = serde_json::to_string(&decoded.projection).unwrap();
    assert!(!output.contains("/missing"));
    assert!(!output.contains("retired/path"));
    assert_eq!(decoded.projection[0]["contentRetained"], false);
    assert_eq!(decoded.projection[0]["trust"]["signature"], "unsigned");
    for (pointer, value) in [
        ("/records/0/generation", json!(1)),
        ("/records/0/productVersion", json!("none")),
        ("/records/0/bundleTrust/signature", json!("unpublished")),
        ("/records/0/children/0/role", json!("other")),
        ("/records/0/root/path", json!("relative")),
    ] {
        let mut bad = original.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        assert!(decode_deveco_toolchains(&serde_json::to_vec(&bad).unwrap()).is_err());
    }
    let mut bad = original.clone();
    bad["records"][0]["extra"] = json!(true);
    assert!(decode_deveco_toolchains(&serde_json::to_vec(&bad).unwrap()).is_err());
    let duplicate = String::from_utf8(bytes).unwrap().replacen(
        "\"records\":",
        "\"schemaVersion\":\"duplicate\",\"records\":",
        1,
    );
    assert!(decode_deveco_toolchains(duplicate.as_bytes()).is_err());
}
#[test]
fn existing_owner_does_not_initialize_or_resolve_removed_content_and_shares_lock() {
    let root = Root::new();
    let store = DevEcoRegistryStore::open_existing(&root.0).unwrap();
    assert!(store.list().is_err());
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
    root.write(".lock", &json!(null));
    root.write(
        "bundles.json",
        &json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}),
    );
    assert!(store.list().is_err());
    assert!(!root.0.join("deveco-toolchains.json").exists());
    let doc = removed();
    root.write("deveco-toolchains.json", &doc);
    let reference = doc["records"][0]["reference"].as_str().unwrap();
    let rows = store.list().unwrap();
    assert_eq!(store.inspect(reference).unwrap(), rows[0]);
    assert_eq!(
        store.inspect("bad").unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
    let directory = arkdeck_platform::HostDirectory::open(&root.0).unwrap();
    let lock = directory.try_lock_existing(".lock").unwrap().unwrap();
    assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::WouldBlock);
    drop(lock);
    let mut available = doc.clone();
    available["records"][0]["state"] = json!("available");
    available["records"][0]["generation"] = json!(1);
    root.write("deveco-toolchains.json", &available);
    assert!(store.list().is_err());
    assert_eq!(
        store
            .inspect(&format!("toolchain:sha256:{}", "1".repeat(64)))
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    root.write(
        "bundles.json",
        &json!({"schemaVersion":"wrong","records":[]}),
    );
    root.write("deveco-toolchains.json", &doc);
    assert!(store.list().is_err());
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 3);
}
#[test]
#[ignore = "requires existing real DevEco registration and current Swift CLI; never fake publisher trust"]
fn actual_registered_deveco_matches_swift_inspect_without_index_or_directory_changes() {
    let root = arkdeck_platform::default_bootstrap_registry_root().unwrap();
    let cli =
        PathBuf::from(std::env::var_os("ARKDECK_TEST_SWIFT_CLI").expect("current built Swift CLI"));
    let before = fs::read(root.join("deveco-toolchains.json")).unwrap();
    let bundles = fs::read(root.join("bundles.json")).unwrap();
    let names = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect::<std::collections::BTreeSet<_>>();
    let store = DevEcoRegistryStore::open_existing(&root).unwrap();
    let rows = store.list().unwrap();
    assert!(!rows.is_empty());
    assert!(rows.iter().any(|r| r["state"] == "available"));
    for row in &rows {
        let reference = row["toolRef"].as_str().unwrap();
        let output = std::process::Command::new(&cli)
            .args([
                "runtime", "tool", "inspect", "--tool", reference, "--output", "json",
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let swift: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(swift["command"], "runtime.tool.inspect");
        assert_eq!(swift["result"], *row);
        assert_eq!(store.inspect(reference).unwrap(), *row);
    }
    assert_eq!(
        fs::read(root.join("deveco-toolchains.json")).unwrap(),
        before
    );
    assert_eq!(fs::read(root.join("bundles.json")).unwrap(), bundles);
    assert_eq!(
        fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect::<std::collections::BTreeSet<_>>(),
        names
    );
    println!(
        "{} real DevEco registration(s): fresh Rust list/inspect equal Swift inspect; indexes and directory unchanged",
        rows.len()
    );
}
