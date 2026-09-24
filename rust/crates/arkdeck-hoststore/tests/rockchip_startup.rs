//! The Swift start-up oracle (`rust/tests/fixtures/rockchip-startup`,
//! recorded by `RockchipStartupReconcileOracleContractTests`) replayed: each
//! scenario's `ArkDeck` root rebuilt file for file with Swift's modes, then
//! `reconcile_rockchip_startup` run once per start Swift's daemon made, each
//! over a Target store opened afresh. Every start's lines, Loader recovery
//! proof and stopping error, and the Target document it leaves, must be
//! Swift's byte for byte.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{TargetStore, reconcile_rockchip_startup};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/rockchip-startup")
}

/// Every scenario's roots, below one owner-only directory removed afterwards.
struct Base(PathBuf);

impl Base {
    fn new() -> Self {
        let base = PathBuf::from("/private/tmp").join(format!(
            "arkdeck-rockchip-startup-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&base).unwrap();
        Self(base)
    }
}

impl Drop for Base {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
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
        fs::set_permissions(&file, fs::Permissions::from_mode(mode)).unwrap();
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
    for (case, damage) in [
        ("link", "a link to its own copy"),
        ("directory", "a directory"),
        ("malformed", "a malformed second record"),
    ] {
        let (_, state) = rebuild(&base, complete, case);
        let journal = state.join("jobs/job-11111111111111111111111111111111/journal.jsonl");
        let bytes = fs::read(&journal).unwrap();
        fs::remove_file(&journal).unwrap();
        let expected = match case {
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
