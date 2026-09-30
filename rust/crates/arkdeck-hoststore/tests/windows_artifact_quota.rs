//! Replays the shared Artifact quota oracle (`rust/tests/fixtures/
//! artifact-quota`, produced by `ArtifactQuotaOracleContractTests`) against
//! the Windows Artifact owner's `artifact.quota` (TASK-XPA-005): each
//! scenario's root rebuilt on NTFS as Swift found it, the quota answered as
//! Swift answered it (T0 for every answer, T1 for a refusal: its code and
//! its store error, with the host's error number in place of Swift's
//! `errno`), and the root left exactly as it was.
//!
//! What NTFS spells differently, and how the rebuild spells it:
//! - Every entry inherits the owner-only Artifact root's DACL, so a
//!   payload's `0400`, `0600` or `0644` is the owner-only file the Windows
//!   Artifact owner writes. `unreadablePayload`'s `0000` is a DACL with no
//!   entry.
//! - A link is a junction: a file symbolic link needs a privilege an
//!   unelevated account does not hold. A junction in a directory's, the
//!   index's or a payload's place is a reparse point the walk does not
//!   follow, as Swift's `O_NOFOLLOW` does not follow a link, and one whose
//!   target is absent is dangling, as `danglingIndexLink`'s link is.
#![cfg(windows)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use arkdeck_hoststore::ArtifactUsage;
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/artifact-quota")
}

fn document(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

fn plain(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(text) => PathBuf::from(text),
        None => path,
    }
}

fn scratch() -> PathBuf {
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let path = plain(std::env::temp_dir().canonicalize().unwrap())
        .join(format!("ad-winquota-{nonce:032x}"));
    fs::create_dir(&path).unwrap();
    path
}

fn run(program: &str, arguments: &[&std::ffi::OsStr]) {
    let status = Command::new(program)
        .args(arguments)
        .stdout(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "{program} {arguments:?}");
}

fn junction(link: &Path, target: &Path) {
    run(
        "cmd",
        &[
            "/C".as_ref(),
            "mklink".as_ref(),
            "/J".as_ref(),
            link.as_os_str(),
            target.as_os_str(),
        ],
    );
}

/// The root as Swift found it before its read, on NTFS; the files nobody may
/// read.
fn rebuild(root: &Path, scenario: &str, before: &Value) -> Vec<PathBuf> {
    let mut unreadable = Vec::new();
    HostDirectory::open_or_create_private(root).unwrap();
    for entry in before.as_array().unwrap() {
        let relative = entry["path"].as_str().unwrap();
        let path = relative
            .split('/')
            .fold(root.to_path_buf(), |path, part| path.join(part));
        match entry["kind"].as_str().unwrap() {
            "directory" => fs::create_dir(&path).unwrap(),
            "file" => {
                let source = fixture().join("stores").join(scenario).join(relative);
                fs::write(&path, fs::read(source).unwrap()).unwrap();
                if entry["mode"] == "0" {
                    // No access entry at all: nobody may read it.
                    run("icacls", &[path.as_os_str(), "/inheritance:r".as_ref()]);
                    unreadable.push(path);
                }
            }
            "symlink" => {
                let target = path
                    .parent()
                    .unwrap()
                    .join(entry["target"].as_str().unwrap());
                // A junction names a directory: a link to a file names the
                // directory beside it instead, which is as much not a
                // regular file as the linked file is not a real one.
                let target = if target.is_file() || before_is_file(before, relative, &target) {
                    path.parent().unwrap().to_path_buf()
                } else {
                    target
                };
                junction(&path, &target);
            }
            other => panic!("{scenario}: unexpected entry kind {other}"),
        }
    }
    unreadable
}

/// Whether the oracle's link names a file of the scenario (made later in
/// the tree's order, or absent from it and so dangling).
fn before_is_file(before: &Value, relative: &str, target: &Path) -> bool {
    let name = target.file_name().unwrap().to_str().unwrap();
    let parent = Path::new(relative).parent().unwrap();
    let wanted = parent.join(name).to_str().unwrap().replace('\\', "/");
    before
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["path"] == wanted.as_str() && entry["kind"] == "file")
}

/// Every entry under `root`: its kind, and a file's size and bytes where the
/// file may be read.
fn entries(root: &Path) -> Value {
    fn walk(root: &Path, relative: &Path, out: &mut Vec<Value>) {
        let mut names: Vec<_> = fs::read_dir(root.join(relative))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        names.sort();
        for name in names {
            let child = relative.join(&name);
            let path = root.join(&child);
            let metadata = fs::symlink_metadata(&path).unwrap();
            let spelled = child.to_str().unwrap().replace('\\', "/");
            if metadata.is_symlink() || metadata.file_type().is_symlink() || is_reparse(&metadata) {
                out.push(json!({"path": spelled, "kind": "link"}));
            } else if metadata.is_dir() {
                out.push(json!({"path": spelled, "kind": "directory"}));
                walk(root, &child, out);
            } else {
                let bytes = fs::read(&path)
                    .ok()
                    .map(|bytes| arkdeck_contract::sha256_hex(&bytes));
                out.push(
                    json!({"path": spelled, "kind": "file", "size": metadata.len(),
                    "sha256": bytes}),
                );
            }
        }
    }
    let mut out = Vec::new();
    walk(root, Path::new(""), &mut out);
    Value::Array(out)
}

fn is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0
}

/// A refusal's store error with the host's error number in place of the
/// number itself: Swift's are Darwin's, these are Windows'.
fn without_error_number(response: &Value) -> Value {
    let mut response = response.clone();
    if let Some(message) = response["error"]["message"].as_str() {
        let mut text = message.to_owned();
        if let Some(start) = text.find("(errno ") {
            let end = start + text[start..].find(')').unwrap();
            text.replace_range(start + 7..end, "_");
        }
        response["error"]["message"] = json!(text);
    }
    response
}

#[test]
fn windows_quota_reproduces_the_swift_oracle() {
    let cases = document("cases.json");
    let trees = document("tree.json");
    let provenance = document("provenance.json");
    let label = provenance["rootLabel"].as_str().unwrap().to_owned();
    let quota = provenance["quotaBytes"].as_u64().unwrap();
    let root = scratch();
    let mut differences = Vec::new();
    let mut unreadable = Vec::new();
    for case in cases.as_array().unwrap() {
        let scenario = case["scenario"].as_str().unwrap();
        let directory = root.join(scenario);
        unreadable.extend(rebuild(&directory, scenario, &trees[scenario]["before"]));
        let before = entries(&directory);
        let spelled = directory.to_str().unwrap().to_owned();
        let actual = match ArtifactUsage::open(&directory, quota).unwrap().quota() {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(message) => json!({"ok": false, "error": {
                "code": "internalError", "message": message.replace(&spelled, &label),
            }}),
        };
        if without_error_number(&actual) != without_error_number(&case["response"]) {
            differences.push(format!(
                "{scenario}:\n  swift   {}\n  windows {actual}",
                case["response"]
            ));
        }
        if entries(&directory) != before {
            differences.push(format!("{scenario}: the read changed the root"));
        }
    }
    // Give the unreadable payloads an access entry again so the scratch
    // root can be removed.
    for path in &unreadable {
        run("icacls", &[path.as_os_str(), "/reset".as_ref()]);
    }
    let _ = fs::remove_dir_all(&root);
    assert!(
        differences.is_empty(),
        "{} of {} scenarios differ:\n{}",
        differences.len(),
        cases.as_array().unwrap().len(),
        differences.join("\n")
    );
}

/// The same answer across a restart of the owner, and nothing written: the
/// walk keeps no total between reads.
#[test]
fn a_reopened_owner_answers_the_same_quota_and_the_read_writes_nothing() {
    let root = scratch();
    let directory = root.join("published");
    rebuild(
        &directory,
        "published",
        &document("tree.json")["published"]["before"],
    );
    let before = entries(&directory);
    let first = ArtifactUsage::open(&directory, 8 << 30)
        .unwrap()
        .quota()
        .unwrap();
    let second = ArtifactUsage::open(&directory, 8 << 30)
        .unwrap()
        .quota()
        .unwrap();
    assert_eq!(first, second);
    assert_eq!(
        first,
        json!({"totalBytes": 8_589_934_592_i64, "usedBytes": 111, "remainingBytes": 8_589_934_481_i64})
    );
    assert_eq!(entries(&directory), before);
    let _ = fs::remove_dir_all(&root);
}
