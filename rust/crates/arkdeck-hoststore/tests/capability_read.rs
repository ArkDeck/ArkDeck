//! Replays the shared capability read oracle (`rust/tests/fixtures/
//! capability-read`, produced by `CapabilityReadOracleContractTests`) against
//! the Rust capability reader: each scenario's store rebuilt as Swift left
//! it, every read answered as Swift answered it with the store's directory
//! spelled by the oracle's label, and the store left as Swift left it.
#![cfg(target_os = "macos")]

use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};

use arkdeck_hoststore::CapabilityStore;
use serde_json::{Value, json};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/capability-read")
}

fn document(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

/// A private scratch root under the canonical temporary directory, as a
/// host store requires its path to be.
fn scratch() -> PathBuf {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-capability-read-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    root
}

/// The store directory as Swift found it before the reads.
fn rebuild(directory: &Path, scenario: &str, before: &Value) {
    fs::DirBuilder::new().mode(0o700).create(directory).unwrap();
    for entry in before.as_array().unwrap() {
        let path = directory.join(entry["path"].as_str().unwrap());
        match entry["kind"].as_str().unwrap() {
            "file" => {
                let source = fixture()
                    .join("stores")
                    .join(scenario)
                    .join(entry["path"].as_str().unwrap());
                fs::write(&path, fs::read(source).unwrap()).unwrap();
                let mode = u32::from_str_radix(entry["mode"].as_str().unwrap(), 8).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
            }
            "symlink" => symlink(entry["target"].as_str().unwrap(), &path).unwrap(),
            other => panic!("{scenario}: unexpected entry kind {other}"),
        }
    }
}

/// Every entry of a store directory as the oracle records it.
fn entries(directory: &Path) -> Value {
    let mut names: Vec<String> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    Value::Array(
        names
            .into_iter()
            .map(|name| {
                let path = directory.join(&name);
                let metadata = fs::symlink_metadata(&path).unwrap();
                if metadata.is_symlink() {
                    json!({
                        "path": name, "kind": "symlink",
                        "target": fs::read_link(&path).unwrap().to_str().unwrap(),
                    })
                } else if metadata.is_file() {
                    json!({
                        "path": name, "kind": "file",
                        "mode": format!("{:o}", metadata.permissions().mode() & 0o7777),
                        "size": metadata.len(),
                    })
                } else {
                    json!({"path": name, "kind": "other"})
                }
            })
            .collect(),
    )
}

#[test]
fn rust_reads_reproduce_the_swift_oracle() {
    let cases = document("cases.json");
    let trees = document("tree.json");
    let label = document("provenance.json")["storeLabel"]
        .as_str()
        .unwrap()
        .to_owned();
    let root = scratch();
    let mut differences = Vec::new();
    let mut exchanges = 0;
    for case in cases.as_array().unwrap() {
        let scenario = case["scenario"].as_str().unwrap();
        let directory = root.join(scenario);
        rebuild(&directory, scenario, &trees[scenario]["before"]);
        let spelled = directory.to_str().unwrap().to_owned();
        let store = CapabilityStore::open(&directory).unwrap();
        for exchange in case["exchanges"].as_array().unwrap() {
            let method = exchange["method"].as_str().unwrap();
            let actual = match store.handle(method, exchange["params"].as_object().unwrap()) {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => json!({"ok": false, "error": {
                    "code": refusal.code,
                    "message": refusal.message.replace(&spelled, &label),
                }}),
            };
            exchanges += 1;
            if actual != exchange["response"] {
                differences.push(format!(
                    "{scenario} {method} {}:\n  swift {}\n  rust  {actual}",
                    exchange["params"], exchange["response"]
                ));
            }
        }
        // The reads write no store document, and leave every entry as
        // Swift's reads left it: at most the lock file is new.
        if entries(&directory) != trees[scenario]["after"] {
            differences.push(format!(
                "{scenario} tree:\n  swift {}\n  rust  {}",
                trees[scenario]["after"],
                entries(&directory)
            ));
        }
        for entry in trees[scenario]["before"].as_array().unwrap() {
            if entry["kind"] == "file" {
                let name = entry["path"].as_str().unwrap();
                let expected =
                    fs::read(fixture().join("stores").join(scenario).join(name)).unwrap();
                if fs::read(directory.join(name)).unwrap() != expected {
                    differences.push(format!("{scenario}/{name} changed"));
                }
            }
        }
    }
    let _ = fs::remove_dir_all(&root);
    assert!(
        differences.is_empty(),
        "{} of {exchanges} reads differ:\n{}",
        differences.len(),
        differences.join("\n")
    );
    assert!(exchanges >= 90, "{exchanges} reads replayed");
}
