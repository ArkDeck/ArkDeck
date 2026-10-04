//! `runtime.tool.list` on Windows names a registered HDC's identity by the
//! store's own published identities (the daemon composes the registered
//! Windows tuples), as its inspection and retirement do: a row whose digest
//! a tuple names reads `registeredIdentity: true` and the tuple's version;
//! without such an identity the row is the one `decode_tools` projects. A
//! `System32` program stands in for `hdc.exe` under an injected fixture
//! identity; nothing is run.
#![cfg(windows)]

use arkdeck_hoststore::{BootstrapListPage, ToolRegistryStore, decode_tools};
use serde_json::{Value, json};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn the_tool_list_names_the_stores_registered_identity() {
    let base = arkdeck_platform::application_support_directory()
        .unwrap()
        .canonicalize()
        .unwrap();
    let base = base.to_str().unwrap();
    let scratch = Scratch(
        PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-test-tool-list-identity-{:032x}",
            u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
        )),
    );
    arkdeck_platform::create_private_directory(&scratch.0).unwrap();
    let sdk = scratch.0.join("sdk");
    arkdeck_platform::create_private_directory(&sdk).unwrap();
    let bytes = std::fs::read(
        PathBuf::from(std::env::var_os("SystemRoot").unwrap())
            .join("System32")
            .join("whoami.exe"),
    )
    .unwrap();
    let hdc = sdk.join("hdc.exe");
    arkdeck_platform::create_private_file(&hdc)
        .unwrap()
        .write_all(&bytes)
        .unwrap();
    let store_path = scratch.0.join("bootstrap");
    arkdeck_platform::create_private_directory(&store_path).unwrap();
    let expected = arkdeck_contract::sha256_hex(&bytes);
    let identities: arkdeck_hoststore::PublishedIdentities = Arc::new(move |sha256: &str| {
        (sha256 == expected).then(|| json!({"version": "3.2.0g", "profileReferences": []}))
    });
    let store = ToolRegistryStore::open_existing(&store_path)
        .unwrap()
        .with_published_identities(identities.clone());
    let registered = store.register(&hdc, "2026-10-05T00:00:00Z").unwrap();
    assert_eq!(registered["trust"]["registeredIdentity"], true);

    let page = store.list_page(10, None).unwrap();
    let rows = page["items"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{page}");
    assert_eq!(rows[0], registered, "the listed row is the registered one");
    assert_eq!(rows[0]["trust"]["registeredIdentity"], true);
    assert_eq!(rows[0]["trust"]["toolVersion"], "3.2.0g");
    assert_eq!(
        store
            .inspect(registered["toolRef"].as_str().unwrap())
            .unwrap(),
        rows[0]
    );

    // A store composed without that identity lists the row `decode_tools`
    // projects, with no registered identity.
    let plain = ToolRegistryStore::open_existing(&store_path).unwrap();
    let page = plain.list_page(10, None).unwrap();
    let index = std::fs::read(store_path.join("tools.json")).unwrap();
    let decoded = decode_tools(&index).unwrap();
    assert_eq!(page["items"], decoded.projection);
    assert_eq!(page["items"][0]["trust"]["registeredIdentity"], false);
    assert_eq!(page["items"][0]["trust"]["toolVersion"], Value::Null);
}
