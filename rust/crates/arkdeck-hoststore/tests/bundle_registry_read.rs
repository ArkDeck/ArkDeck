#![cfg(target_os = "macos")]
use arkdeck_hoststore::BundleRegistryReadStore;
use serde_json::{Value, json};
use std::{
    fs, io,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = arkdeck_platform::random_bytes::<16>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let path = PathBuf::from(format!("/private/tmp/bundle-read-{nonce}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, bytes: &[u8]) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn read_owner_does_not_initialize_and_serializes_with_the_existing_owner() {
    let root = Root::new();
    let store = BundleRegistryReadStore::open_existing(&root.0).unwrap();
    assert!(store.list().is_err());
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 0);
    root.write(".lock", b"");
    assert!(store.list().is_err());
    assert!(!root.0.join("bundles.json").exists());
    let bytes =
        serde_json::to_vec(&json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[]}))
            .unwrap();
    root.write("bundles.json", &bytes);
    assert_eq!(store.list().unwrap(), Vec::<Value>::new());
    assert_eq!(
        store.inspect("bad").unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
    assert_eq!(
        store
            .inspect(&format!("bundle:sha256:{}", "0".repeat(64)))
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    let directory = arkdeck_platform::HostDirectory::open(&root.0).unwrap();
    let lock = directory.try_lock_existing(".lock").unwrap().unwrap();
    assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::WouldBlock);
    drop(lock);
    assert_eq!(fs::read(root.0.join("bundles.json")).unwrap(), bytes);
    assert_eq!(fs::read_dir(&root.0).unwrap().count(), 2);
    // A removed row still claims retained content and must be verified. This
    // deliberately missing-content negative fixture cannot certify any trust.
    let removed = json!({"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[{
        "reference":format!("bundle:sha256:{}","0".repeat(64)),"digest":"0".repeat(64),
        "registeredAtUTC":"2026-09-11T00:00:00Z","byteCount":0,"entryCount":1,
        "generation":2,"state":"removed","references":[]}]});
    root.write("bundles.json", &serde_json::to_vec(&removed).unwrap());
    assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::InvalidData);
    assert_eq!(
        store
            .inspect(&format!("bundle:sha256:{}", "0".repeat(64)))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidData
    );
    assert_eq!(
        store
            .inspect(&format!("bundle:sha256:{}", "1".repeat(64)))
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    root.write(
        "bundles.json",
        br#"{"schemaVersion":"arkdeck.bootstrap-bundles/1","records":[],"extra":true}"#,
    );
    assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::InvalidData);
}
#[test]
#[ignore = "requires the existing real Bootstrap registry and current Swift CLI; no signing fixtures"]
fn actual_current_swift_inspect_matches_rust_list_and_inspect_without_writes() {
    let root = PathBuf::from(
        std::env::var_os("ARKDECK_TEST_BOOTSTRAP_BUNDLE_ROOT").expect("existing Bootstrap root"),
    );
    assert_eq!(
        root,
        arkdeck_platform::default_bootstrap_registry_root().unwrap(),
        "Swift CLI resolves the real current-user root"
    );
    let cli =
        PathBuf::from(std::env::var_os("ARKDECK_TEST_SWIFT_CLI").expect("current built Swift CLI"));
    let before = fs::read(root.join("bundles.json")).unwrap();
    let before_names = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect::<std::collections::BTreeSet<_>>();
    let store = BundleRegistryReadStore::open_existing(&root).unwrap();
    let rows = store.list().unwrap();
    assert!(
        !rows.is_empty(),
        "positive comparison requires actual registered Bundles"
    );
    for row in &rows {
        let reference = row["bundleRef"].as_str().unwrap();
        let output = std::process::Command::new(&cli)
            .args([
                "runtime", "bundle", "inspect", "--bundle", reference, "--output", "json",
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
        assert_eq!(swift["command"], "runtime.bundle.inspect");
        assert_eq!(swift["result"], *row);
        assert_eq!(store.inspect(reference).unwrap(), *row);
    }
    assert_eq!(fs::read(root.join("bundles.json")).unwrap(), before);
    assert_eq!(
        fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect::<std::collections::BTreeSet<_>>(),
        before_names
    );
    println!(
        "{} real signed registered Bundle(s): Rust list/inspect equal actual Swift inspect; index and directory unchanged",
        rows.len()
    );
}
