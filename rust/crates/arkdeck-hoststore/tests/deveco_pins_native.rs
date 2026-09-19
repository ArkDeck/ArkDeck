//! A workspace preset's pin on the installed DevEco Studio, through the Rust
//! registry owner's real content verification (TASK-XPA-015, M3). DevEco is
//! only read: it is registered into a fresh private registry, pinned, found
//! retained by retirement, released and retired, and the registry is removed.
#![cfg(target_os = "macos")]
use arkdeck_hoststore::DevEcoRegistryStore;
use serde_json::json;
use std::{fs, os::unix::fs::DirBuilderExt, path::Path};

#[test]
#[ignore = "requires the installed DevEco Studio; registers it read-only into a fresh private registry"]
fn the_installed_deveco_is_pinned_released_and_then_retired() {
    let contents = Path::new("/Applications/DevEco-Studio.app/Contents");
    assert!(contents.is_dir(), "DevEco Studio is not installed");
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let registry =
        std::path::PathBuf::from(format!("/private/tmp/deveco-pins-native-{nonce:032x}"));
    fs::DirBuilder::new().mode(0o700).create(&registry).unwrap();
    let store = DevEcoRegistryStore::open_existing(&registry).unwrap();
    let registered = store.register(contents, "2026-09-19T00:00:00Z").unwrap();
    let reference = registered["toolRef"].as_str().unwrap().to_owned();

    let pinned = store
        .acquire(&reference, "1", "workspacePreset", "preset-native")
        .unwrap();
    assert_eq!(
        pinned["references"],
        json!([{"kind": "workspacePreset", "id": "preset-native"}])
    );
    assert_eq!(
        store
            .acquire(&reference, "2", "workspacePreset", "preset-native")
            .unwrap_err()
            .code,
        "resourceConflict"
    );
    let retained = store.retire(&reference, "1").unwrap_err();
    assert_eq!(
        (retained.code.as_str(), retained.message.as_str()),
        (
            "resourceConflict",
            "DevEco toolchain is retained by a workspace preset"
        )
    );
    store
        .release(&reference, "workspacePreset", "preset-native")
        .unwrap();
    assert_eq!(store.inspect(&reference).unwrap()["references"], json!([]));
    assert_eq!(store.retire(&reference, "1").unwrap()["state"], "removed");
    fs::remove_dir_all(&registry).unwrap();
}
