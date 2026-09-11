#![cfg(target_os = "macos")]
use arkdeck_hoststore::{BundleRegistryReadStore, DevEcoRegistryReadStore, ToolRegistryStore};
use arkdeck_platform::HostDirectory;
use serde_json::json;
use std::{
    fs, io,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/bootstrap-missing-lock-{nonce:032x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, bytes: &[u8]) {
        fs::write(self.0.join(name), bytes).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn snapshot(&self) -> std::collections::BTreeMap<std::ffi::OsString, Vec<u8>> {
        fs::read_dir(&self.0)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (entry.file_name(), fs::read(entry.path()).unwrap())
            })
            .collect()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

macro_rules! missing_lock_test {
    ($name:ident, $store:ty, $prefix:literal, $index:literal, $schema:literal) => {
        #[test]
        fn $name() {
            let root = Root::new();
            let directory = HostDirectory::open(&root.0).unwrap();
            let store = <$store>::open_existing(&root.0).unwrap();
            let reference = format!("{}{}", $prefix, "0".repeat(64));
            let unreadable = || {
                let before = root.snapshot();
                assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::InvalidData);
                assert_eq!(store.inspect(&reference).unwrap_err().kind(), io::ErrorKind::InvalidData);
                assert_eq!(root.snapshot(), before);
            };
            // The compatibility API keeps its old semantics, while Bootstrap
            // can distinguish an uninitialized store from active contention.
            assert!(directory.try_lock_existing(".lock").unwrap().is_none());
            assert_eq!(directory.try_lock_existing_strict(".lock").err().unwrap().kind(), io::ErrorKind::NotFound);
            unreadable();
            assert!(root.snapshot().is_empty());
            root.write(".lock", b"");
            unreadable(); // Missing shared bundle index.
            root.write("bundles.json", &serde_json::to_vec(&json!({
                "schemaVersion":"arkdeck.bootstrap-bundles/1", "records":[]
            })).unwrap());
            if $index != "bundles.json" {
                unreadable(); // Missing selected-family index.
                root.write($index, &serde_json::to_vec(&json!({
                    "schemaVersion":$schema, "records":[]
                })).unwrap());
            }
            let before = root.snapshot();
            assert!(store.list().unwrap().is_empty());
            assert_eq!(store.inspect(&reference).unwrap_err().kind(), io::ErrorKind::NotFound);
            let guard = directory.try_lock_existing_strict(".lock").unwrap().unwrap();
            assert_eq!(store.list().unwrap_err().kind(), io::ErrorKind::WouldBlock);
            assert_eq!(store.inspect(&reference).unwrap_err().kind(), io::ErrorKind::WouldBlock);
            drop(guard);
            assert_eq!(root.snapshot(), before);
            // Swift opens the existing Bootstrap lock O_RDWR even for reads.
            // Honor the same OS refusal when its owner-write access is removed.
            fs::set_permissions(root.0.join(".lock"), fs::Permissions::from_mode(0o400)).unwrap();
            if fs::OpenOptions::new().write(true).open(root.0.join(".lock")).is_err() {
                unreadable();
            }
            fs::set_permissions(root.0.join(".lock"), fs::Permissions::from_mode(0o600)).unwrap();
            fs::remove_file(root.0.join(".lock")).unwrap();
            unreadable(); // An otherwise complete registry still needs its lock.
            assert!(!root.0.join(".lock").exists());
        }
    };
}
missing_lock_test!(
    bundle_missing_lock_and_index_differ_from_contention,
    BundleRegistryReadStore,
    "bundle:sha256:",
    "bundles.json",
    "arkdeck.bootstrap-bundles/1"
);
missing_lock_test!(
    tool_missing_lock_and_index_differ_from_contention,
    ToolRegistryStore,
    "tool:sha256:",
    "tools.json",
    "arkdeck.bootstrap-tools/2"
);
missing_lock_test!(
    deveco_missing_lock_and_index_differ_from_contention,
    DevEcoRegistryReadStore,
    "toolchain:sha256:",
    "deveco-toolchains.json",
    "arkdeck.bootstrap-deveco-toolchains/1"
);
