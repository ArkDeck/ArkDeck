//! The Swift start-up oracle (`rust/tests/fixtures/rockchip-startup`,
//! recorded by `RockchipStartupReconcileOracleContractTests`) replayed: each
//! scenario's `ArkDeck` root rebuilt file for file with Swift's modes, then
//! `reconcile_rockchip_startup` run once per start Swift's daemon made, each
//! over a Target store opened afresh. Every start's lines, Loader recovery
//! proof and stopping error, and the Target document it leaves, must be
//! Swift's byte for byte.
//!
//! On Windows (TASK-XPA-010) the roots are rebuilt below the temporary
//! directory: an owner-only (0600/0700) entry is the host store's private
//! one, and the one wider (0644) file gives the local Users group read
//! access, as its mode would on macOS.
#![cfg(any(target_os = "macos", windows))]

#[path = "fixture_fs/mod.rs"]
mod fixture_fs;

use arkdeck_hoststore::{TargetStore, reconcile_rockchip_startup};
use serde_json::{Value, json};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/rockchip-startup")
}

/// Every scenario's roots, below one owner-only directory removed afterwards.
struct Base(PathBuf);

impl Base {
    fn new() -> Self {
        #[cfg(unix)]
        let temporary = PathBuf::from("/private/tmp");
        #[cfg(windows)]
        let temporary = fixture_fs::temporary_root();
        let base = temporary.join(format!(
            "arkdeck-rockchip-startup-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fixture_fs::private_dir(&base);
        Self(base)
    }
}

impl Drop for Base {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

/// Every missing level created as the host store's private directory.
#[cfg(windows)]
fn directory(path: &Path) {
    arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
}

/// A recorded file's mode: on Windows owner-only is the private DACL the
/// file inherits; a wider mode gives the local Users group read access.
#[cfg(unix)]
fn set_mode(file: &Path, mode: u32) {
    fs::set_permissions(file, fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(windows)]
fn set_mode(file: &Path, mode: u32) {
    if mode & 0o077 != 0 {
        let status = std::process::Command::new("icacls")
            .arg(file)
            .args(["/grant", "*S-1-5-32-545:(R)"])
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "icacls {}", file.display());
    }
}

/// The scenario's `ArkDeck` root as Swift's stores left it, below `name`:
/// the root, the state directory and its Target store owner-only, then every
/// recorded file with its mode.
fn rebuild(base: &Base, scenario: &Value, name: &str) -> (PathBuf, PathBuf) {
    let recorded = scenario["name"].as_str().unwrap();
    let root = base.0.join(name).join("ArkDeck");
    let state = root.join(scenario["stateDirectory"].as_str().unwrap());
    for path in [&root, &state, &state.join("targets")] {
        directory(path);
    }
    for input in scenario["inputs"].as_array().unwrap() {
        let path = input["path"].as_str().unwrap();
        let file = root.join(path);
        directory(file.parent().unwrap());
        fs::write(
            &file,
            fs::read(fixtures().join("inputs").join(recorded).join(path)).unwrap(),
        )
        .unwrap();
        let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
        set_mode(&file, mode);
    }
    (root, state)
}

#[test]
fn every_start_up_is_swifts() {
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap();
    let base = Base::new();
    let scenarios = cases["scenarios"].as_array().unwrap();
    assert_eq!(scenarios.len(), 18);
    for scenario in scenarios {
        let name = scenario["name"].as_str().unwrap();
        let (_, state) = rebuild(&base, scenario, name);
        for (index, run) in scenario["runs"].as_array().unwrap().iter().enumerate() {
            let context = format!("{name} start {}", index + 1);
            let targets = TargetStore::open(&state.join("targets")).unwrap();
            let (lines, recovery, failure) = match reconcile_rockchip_startup(&targets, &state) {
                Ok(startup) => (
                    startup.lines,
                    startup.recovery.map_or(Value::Null, |(target, proof)| {
                        json!({
                            "targetId": target,
                            "previousRevision": proof.previous_revision,
                            "currentRevision": proof.current_revision,
                            "selectionEvidenceSha256": proof.selection_evidence_sha256,
                        })
                    }),
                    Value::Null,
                ),
                Err(error) => (Vec::new(), Value::Null, json!(error)),
            };
            assert_eq!(json!(lines), run["lines"], "{context}");
            assert_eq!(recovery, run["recovery"], "{context}");
            assert_eq!(failure, run["failure"], "{context}");
            let document = state.join("targets/targets.json");
            match run["targets"].as_str() {
                Some(recorded) => assert_eq!(
                    String::from_utf8(fs::read(&document).unwrap()).unwrap(),
                    String::from_utf8(fs::read(fixtures().join(recorded)).unwrap()).unwrap(),
                    "{context}"
                ),
                None => assert!(!document.exists(), "{context}"),
            }
        }
    }
}

/// The establishing Flash's journal is read as Swift's
/// `DurableJournalRecovery.inspect(url:)` reads it: through no link, as one
/// regular file, every completed record decoded. Each refusal keeps the alias
/// gate closed, with Swift's `DurableFileError` as its daemon prints it, and
/// appends nothing.
#[test]
fn a_journal_that_is_a_link_a_directory_or_malformed_keeps_the_alias_closed() {
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap();
    let complete = cases["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|scenario| scenario["name"] == "alias.complete")
        .unwrap();
    let base = Base::new();
    // A file symbolic link needs a privilege on Windows, so the link case is
    // macOS's; a directory in the journal's place is refused on both.
    #[cfg(unix)]
    let cases = [
        ("link", "a link to its own copy"),
        ("directory", "a directory"),
        ("malformed", "a malformed second record"),
    ];
    #[cfg(windows)]
    let cases = [
        ("directory", "a directory"),
        ("malformed", "a malformed second record"),
    ];
    for (case, damage) in cases {
        let (_, state) = rebuild(&base, complete, case);
        let journal = state.join("jobs/job-11111111111111111111111111111111/journal.jsonl");
        let bytes = fs::read(&journal).unwrap();
        fs::remove_file(&journal).unwrap();
        let expected: String = match case {
            #[cfg(unix)]
            "link" => {
                let copy = journal.with_file_name("journal-copy.jsonl");
                fs::write(&copy, &bytes).unwrap();
                std::os::unix::fs::symlink(&copy, &journal).unwrap();
                format!(
                    "openFailed(path: {:?}, errno: {})",
                    journal.to_str().unwrap(),
                    libc::ELOOP
                )
            }
            "directory" => {
                directory(&journal);
                "sequenceViolation(\"journal snapshot must be a bounded regular file\")".into()
            }
            _ => {
                let first = bytes.iter().position(|b| *b == b'\n').unwrap() + 1;
                let mut damaged = bytes[..first].to_vec();
                damaged.extend_from_slice(b"{\"not\":\"an event\"}\n");
                damaged.extend_from_slice(&bytes[first..]);
                fs::write(&journal, damaged).unwrap();
                "malformedCompletedRecord(line: 2)".into()
            }
        };
        let document = state.join("targets/targets.json");
        let before = fs::read(&document).unwrap();
        let targets = TargetStore::open(&state.join("targets")).unwrap();
        let startup = reconcile_rockchip_startup(&targets, &state).unwrap();
        assert_eq!(
            startup.lines,
            [format!(
                "Rockchip target alias remains fail-closed: {expected}"
            )],
            "{damage}"
        );
        assert_eq!(fs::read(&document).unwrap(), before, "{damage}");
    }
}
