//! Replays the shared Artifact quota oracle (`rust/tests/fixtures/
//! artifact-quota`, produced by `ArtifactQuotaOracleContractTests`) against
//! the Rust quota reader: each scenario's root rebuilt as Swift found it, the
//! quota answered as Swift answered it with the root spelled by the oracle's
//! label, and the root left exactly as it was. Swift's read may reseal a
//! payload and write payload-verification caches; the Rust read writes
//! nothing, and the second test pins that those are Swift's only writes.
#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};

use arkdeck_hoststore::ArtifactUsage;
use serde_json::{Value, json};

const CACHE: &str = ".payload-verification-v1.json";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/artifact-quota")
}

fn document(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

/// A private scratch root under the canonical temporary directory, as a
/// host store requires its path to be.
fn scratch() -> PathBuf {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-artifact-quota-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    root
}

fn mode(entry: &Value) -> u32 {
    u32::from_str_radix(entry["mode"].as_str().unwrap(), 8).unwrap()
}

/// The root as Swift found it before its read.
fn rebuild(root: &Path, scenario: &str, before: &Value) {
    fs::DirBuilder::new().mode(0o700).create(root).unwrap();
    for entry in before.as_array().unwrap() {
        let relative = entry["path"].as_str().unwrap();
        let path = root.join(relative);
        match entry["kind"].as_str().unwrap() {
            "directory" => {
                fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(mode(entry))).unwrap();
            }
            "file" => {
                let source = fixture().join("stores").join(scenario).join(relative);
                fs::write(&path, fs::read(source).unwrap()).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(mode(entry))).unwrap();
            }
            "symlink" => symlink(entry["target"].as_str().unwrap(), &path).unwrap(),
            other => panic!("{scenario}: unexpected entry kind {other}"),
        }
    }
}

/// Every entry under `root` as the oracle records it.
fn entries(root: &Path) -> Value {
    fn walk(root: &Path, relative: &str, paths: &mut Vec<String>) {
        let directory = if relative.is_empty() {
            root.to_path_buf()
        } else {
            root.join(relative)
        };
        for entry in fs::read_dir(directory).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            let child = if relative.is_empty() {
                name
            } else {
                format!("{relative}/{name}")
            };
            let is_directory = fs::symlink_metadata(root.join(&child)).unwrap().is_dir();
            paths.push(child.clone());
            if is_directory {
                walk(root, &child, paths);
            }
        }
    }
    let mut paths = Vec::new();
    walk(root, "", &mut paths);
    paths.sort();
    Value::Array(
        paths
            .into_iter()
            .map(|path| {
                let full = root.join(&path);
                let metadata = fs::symlink_metadata(&full).unwrap();
                let mode = format!("{:o}", metadata.permissions().mode() & 0o7777);
                if metadata.is_symlink() {
                    json!({"path": path, "kind": "symlink",
                        "target": fs::read_link(&full).unwrap().to_str().unwrap()})
                } else if metadata.is_dir() {
                    json!({"path": path, "kind": "directory", "mode": mode})
                } else if metadata.is_file() && full.file_name().unwrap() == CACHE {
                    json!({"path": path, "kind": "file", "mode": mode})
                } else if metadata.is_file() {
                    json!({"path": path, "kind": "file", "mode": mode, "size": metadata.len()})
                } else {
                    json!({"path": path, "kind": "other"})
                }
            })
            .collect(),
    )
}

#[test]
fn rust_quota_reproduces_the_swift_oracle() {
    let cases = document("cases.json");
    let trees = document("tree.json");
    let provenance = document("provenance.json");
    let label = provenance["rootLabel"].as_str().unwrap().to_owned();
    let quota = provenance["quotaBytes"].as_u64().unwrap();
    let root = scratch();
    let mut differences = Vec::new();
    for case in cases.as_array().unwrap() {
        let scenario = case["scenario"].as_str().unwrap();
        let directory = root.join(scenario);
        rebuild(&directory, scenario, &trees[scenario]["before"]);
        let before = entries(&directory);
        if before != trees[scenario]["before"] {
            differences.push(format!("{scenario}: the rebuilt root differs from Swift's"));
        }
        let spelled = directory.to_str().unwrap().to_owned();
        let actual = match ArtifactUsage::open(&directory, quota).unwrap().quota() {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(message) => json!({"ok": false, "error": {
                "code": "internalError", "message": message.replace(&spelled, &label),
            }}),
        };
        if actual != case["response"] {
            differences.push(format!(
                "{scenario}:\n  swift {}\n  rust  {actual}",
                case["response"]
            ));
        }
        if entries(&directory) != before {
            differences.push(format!("{scenario}: the Rust read changed the root"));
        }
    }
    // Restore write access so the scratch root can be removed.
    let _ = std::process::Command::new("chmod")
        .args(["-R", "u+rwX"])
        .arg(&root)
        .status();
    let _ = fs::remove_dir_all(&root);
    assert!(
        differences.is_empty(),
        "{} of {} scenarios differ:\n{}",
        differences.len(),
        cases.as_array().unwrap().len(),
        differences.join("\n")
    );
}

/// What Swift's read wrote that the Rust read does not: per scenario, the
/// entries whose kind, mode or size changed or that appeared.
fn swift_writes(trees: &Value) -> BTreeMap<String, Vec<String>> {
    let index = |entries: &Value| -> BTreeMap<String, Value> {
        entries
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| (entry["path"].as_str().unwrap().to_owned(), entry.clone()))
            .collect()
    };
    let mut writes = BTreeMap::new();
    for (scenario, tree) in trees.as_object().unwrap() {
        let before = index(&tree["before"]);
        let after = index(&tree["after"]);
        assert!(
            before.keys().all(|path| after.contains_key(path)),
            "{scenario}: Swift's read removed an entry"
        );
        let changed: Vec<String> = after
            .iter()
            .filter(|(path, entry)| before.get(*path) != Some(*entry))
            .map(|(path, entry)| match before.get(path) {
                Some(old) => format!("{path}: mode {} -> {}", old["mode"], entry["mode"]),
                None => format!("{path}: written"),
            })
            .collect();
        if !changed.is_empty() {
            writes.insert(scenario.clone(), changed);
        }
    }
    writes
}

#[test]
fn swift_writes_only_reseals_and_verification_caches() {
    let trees = document("tree.json");
    for (scenario, changes) in swift_writes(&trees) {
        for change in changes {
            let cache = change.ends_with(&format!("/{CACHE}: written"));
            let reseal = change.contains(": mode ") && change.ends_with("-> \"400\"");
            assert!(cache || reseal, "{scenario}: {change}");
        }
    }
}
