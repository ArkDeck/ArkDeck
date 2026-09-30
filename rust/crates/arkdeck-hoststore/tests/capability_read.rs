//! Replays the shared capability read oracle (`rust/tests/fixtures/
//! capability-read`, produced by `CapabilityReadOracleContractTests`) against
//! the Rust capability reader: each scenario's store rebuilt as Swift left
//! it, every read answered as Swift answered it with the store's directory
//! spelled by the oracle's label, and the store left as Swift left it.
//!
//! On Windows the same oracle is replayed over the host store's owner-only
//! directories: a file created in one is owner-only as the oracle's `0600`
//! files are, and permission bits, which NTFS does not have, are not
//! compared.
#![cfg(any(target_os = "macos", windows))]

use std::fs;
#[cfg(target_os = "macos")]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
#[cfg(windows)]
use std::os::windows::fs::symlink_file as symlink;
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
    private_directory(&root);
    root
}

/// A directory only its owner can use: `0700` on macOS, the host store's
/// owner-only descriptor on Windows.
fn private_directory(path: &Path) {
    #[cfg(target_os = "macos")]
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
    #[cfg(windows)]
    arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
}

/// The store directory as Swift found it before the reads.
fn rebuild(directory: &Path, scenario: &str, before: &Value) {
    private_directory(directory);
    for entry in before.as_array().unwrap() {
        let path = directory.join(entry["path"].as_str().unwrap());
        match entry["kind"].as_str().unwrap() {
            "file" => {
                let source = fixture()
                    .join("stores")
                    .join(scenario)
                    .join(entry["path"].as_str().unwrap());
                fs::write(&path, fs::read(source).unwrap()).unwrap();
                #[cfg(target_os = "macos")]
                {
                    let mode = u32::from_str_radix(entry["mode"].as_str().unwrap(), 8).unwrap();
                    fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
                }
            }
            "symlink" => symlink(entry["target"].as_str().unwrap(), &path).unwrap(),
            other => panic!("{scenario}: unexpected entry kind {other}"),
        }
    }
}

/// A file as the oracle records it: its permission bits on macOS; NTFS has
/// none to compare.
#[cfg(target_os = "macos")]
fn file_entry(name: &str, metadata: &fs::Metadata) -> Value {
    json!({
        "path": name, "kind": "file",
        "mode": format!("{:o}", metadata.permissions().mode() & 0o7777),
        "size": metadata.len(),
    })
}
#[cfg(windows)]
fn file_entry(name: &str, metadata: &fs::Metadata) -> Value {
    json!({"path": name, "kind": "file", "size": metadata.len()})
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
                    file_entry(&name, &metadata)
                } else {
                    json!({"path": name, "kind": "other"})
                }
            })
            .collect(),
    )
}

/// A refusal's message with the store's directory spelled by the oracle's
/// label. On Windows the directory is a `\\?\` path whose separators the
/// message may also quote Swift's way, once or twice (each quoting doubles
/// every backslash); a file in it is spelled `<label>/<name>`, as on macOS.
fn labelled(message: &str, spelled: &str, label: &str) -> String {
    #[cfg(windows)]
    {
        let mut message = message.to_owned();
        for depth in (0..3).rev() {
            let mut path = spelled.to_owned();
            let mut separator = "\\".to_owned();
            for _ in 0..depth {
                path = path.replace('\\', "\\\\");
                separator = separator.replace('\\', "\\\\");
            }
            message = message
                .replace(&format!("{path}{separator}"), &format!("{label}/"))
                .replace(&path, label);
        }
        message
    }
    #[cfg(target_os = "macos")]
    message.replace(spelled, label)
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
                    "message": labelled(&refusal.message, &spelled, &label),
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
        #[cfg_attr(target_os = "macos", allow(unused_mut))]
        let mut after = trees[scenario]["after"].clone();
        // NTFS has no permission bits to compare.
        #[cfg(windows)]
        for entry in after.as_array_mut().unwrap() {
            entry.as_object_mut().unwrap().remove("mode");
        }
        if entries(&directory) != after {
            differences.push(format!(
                "{scenario} tree:\n  swift {}\n  rust  {}",
                after,
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
