//! Replays the shared post-flash alias oracle (`rust/tests/fixtures/
//! post-flash-alias`, produced by `PostFlashAliasOracleContractTests`)
//! against the Rust store: every step's input applied as Swift applied it,
//! every outcome answered as Swift answered it, and after every step the
//! store's root holding exactly the files Swift left — the same names, modes,
//! sizes and bytes. The root is a scratch directory; nothing touches the
//! installed Application Support tree.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{LiveTarget, ObservedHdc, PostFlashAliasStore, PostFlashBinding};
use arkdeck_platform::random_bytes;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::{fs, io};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/post-flash-alias")
}

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-post-flash-alias-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn text(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} in {value}"))
        .to_owned()
}

/// A record as the oracle spells it (the twelve keys).
fn record_from(value: &Value) -> PostFlashBinding {
    PostFlashBinding {
        schema_version: text(value, "schemaVersion"),
        target_id: text(value, "targetID"),
        binding_revision: value["bindingRevision"].as_i64().unwrap(),
        stable_loader_identity_sha256: text(value, "stableLoaderIdentitySHA256"),
        previous_hdc_identity_sha256: text(value, "previousHDCIdentitySHA256"),
        hdc_identity_sha256: text(value, "hdcIdentitySHA256"),
        hdc_connect_key: text(value, "hdcConnectKey"),
        usb_topology: text(value, "usbTopology"),
        product_model: text(value, "productModel"),
        build_version: text(value, "buildVersion"),
        job_id: text(value, "jobID"),
        established_at_utc: text(value, "establishedAtUTC"),
    }
}

/// The oracle's `plant`: a file written at the name with the store's own
/// bytes for the record, owner-only.
fn plant(root: &Path, name: &str, record: &PostFlashBinding) {
    let path = root.join(name);
    let _ = fs::remove_file(&path);
    fs::write(&path, record.encode().unwrap()).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
}

fn refused<T>(
    result: Result<T, arkdeck_hoststore::PostFlashAliasError>,
    ok: impl FnOnce(T) -> Value,
) -> Value {
    match result {
        Ok(value) => ok(value),
        Err(error) => json!({ "refused": error.detail() }),
    }
}

fn apply(store: &PostFlashAliasStore, root: &Path, input: &Value) -> Value {
    match input {
        Value::Null => refused(
            store.load_if_present(),
            |loaded| json!({ "loaded": loaded.map(|record| record.value()) }),
        ),
        Value::Object(fields) if fields.contains_key("target") => {
            let target = &fields["target"];
            let live = LiveTarget {
                target_id: target["targetID"].as_str().unwrap(),
                stable_identity_sha256: target["stablePhysicalIdentitySHA256"].as_str().unwrap(),
                binding_revision: target["bindingRevision"].as_i64().unwrap(),
            };
            let observed = ObservedHdc {
                identity_sha256: fields["observedHDCIdentitySHA256"].as_str().unwrap(),
                connect_key: fields["observedHDCConnectKey"].as_str().unwrap(),
                usb_topology: fields["observedUSBTopology"].as_str().unwrap(),
            };
            refused(
                store.reconcile_reissued_lineage(
                    &live,
                    &observed,
                    fields["nowUTC"].as_str().unwrap(),
                ),
                |reconciled| {
                    json!({
                        "reconciled": reconciled.map(|outcome| json!({
                            "archivedRevision": outcome.archived_revision,
                            "publishedRevision": outcome.published_revision,
                            "targetID": outcome.target_id,
                            "hdcIdentitySHA256": outcome.hdc_identity_sha256,
                        }))
                    })
                },
            )
        }
        Value::Object(fields) => {
            if let Some(planted) = fields.get("planted") {
                plant(
                    root,
                    planted["name"].as_str().unwrap(),
                    &record_from(&planted["record"]),
                );
            }
            let candidate = record_from(&fields["candidate"]);
            let expected = fields["expectedPreviousHDCIdentitySHA256"]
                .as_str()
                .unwrap();
            refused(
                store.publish(&candidate, expected),
                |published| json!({ "published": published.value() }),
            )
        }
        other => panic!("unexpected input {other}"),
    }
}

fn entries(root: &Path) -> io::Result<BTreeSet<String>> {
    fs::read_dir(root)?
        .map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned()))
        .collect()
}

#[test]
fn the_rust_store_replays_the_swift_oracle_byte_for_byte() {
    let scratch = Scratch::new();
    let root = scratch.0.join("alias");
    let store = PostFlashAliasStore::new(&root);
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let steps = cases.as_array().unwrap();
    assert_eq!(steps.len(), 15);
    for step in steps {
        let index = step["index"].as_i64().unwrap();
        let name = step["step"].as_str().unwrap();
        let label = format!("step {index:02} {name}");

        let outcome = apply(&store, &root, &step["input"]);
        assert_eq!(outcome, step["outcome"], "{label}: outcome");

        let recorded = fixture().join(format!("steps/{index:02}-{name}"));
        let mut expected = BTreeSet::new();
        for entry in step["files"].as_array().unwrap() {
            let path = entry["path"].as_str().unwrap();
            let kind = entry["kind"].as_str().unwrap();
            let mode = u32::from_str_radix(entry["mode"].as_str().unwrap(), 8).unwrap();
            let size = entry["bytes"].as_u64().unwrap();
            let actual = fs::metadata(root.join(path))
                .unwrap_or_else(|error| panic!("{label}: {path}: {error}"));
            assert_eq!(kind, "file", "{label}: {path}");
            assert!(actual.is_file(), "{label}: {path} is not a file");
            assert_eq!(
                actual.permissions().mode() & 0o777,
                mode,
                "{label}: {path} mode"
            );
            assert_eq!(actual.len(), size, "{label}: {path} size");
            assert_eq!(
                fs::read(root.join(path)).unwrap(),
                fs::read(recorded.join(path)).unwrap(),
                "{label}: {path} bytes"
            );
            expected.insert(path.to_owned());
        }
        assert_eq!(
            entries(&root).unwrap(),
            expected,
            "{label}: files in the root"
        );
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700,
            "{label}: root mode"
        );
    }
}

/// The store's root is created owner-only on the first call, a relative
/// root is refused before anything is touched, and the installed
/// Application Support tree is never the subject of a test.
#[test]
fn the_root_is_prepared_owner_only_and_a_relative_root_is_refused() {
    let scratch = Scratch::new();
    let root = scratch.0.join("nested/alias");
    let store = PostFlashAliasStore::new(&root);
    assert_eq!(store.load_if_present().unwrap(), None);
    assert_eq!(
        fs::metadata(&root).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(entries(&root).unwrap(), BTreeSet::new());

    let relative = PostFlashAliasStore::new(Path::new("alias"));
    assert_eq!(
        relative.load_if_present().unwrap_err().detail(),
        "post-flash binding root must be absolute"
    );
    assert_eq!(
        relative.load_if_present().unwrap_err().to_string(),
        "product execution configuration unavailable: post-flash binding root must be absolute"
    );
}
