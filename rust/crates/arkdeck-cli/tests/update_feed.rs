//! `maintainer update-feed prepare` and its deprecated `update-feed prepare`
//! spelling replayed through the CLI process against Swift's recorded runs
//! (`rust/tests/fixtures/update-feed`, `CLIUpdateFeedOracleContractTests`,
//! whose owners are `RuntimeCLI.prepareUpdateFeed` and
//! `RuntimeCLI.assembleUpdateFeed`).
//!
//! Each prepare run gets the same private root the Swift test made: a release
//! artifact and an empty one, and its arguments as Foundation's `Process`
//! passed them (decomposed). The CLI must end as Swift's did — the same exit
//! status, stdout and stderr (a generated correlation identity, of Swift's
//! shape, compared as the oracle's `ctl-<uuid>`) — and write the same payload
//! and signature input, byte for byte, with the same modes. The recorded
//! `assemble` runs wait for that leaf's port (it verifies an Ed25519
//! signature, a dependency not yet approved); this CLI answers it
//! `blockedByProductDefect`, which `blocked_leaves.rs` holds.
#![cfg(target_os = "macos")]

use serde_json::Value;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;
use std::process::Command;

fn oracle() -> Value {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/update-feed/cases.json");
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// `text` with each generated correlation identity spelled `ctl-<uuid>`, once
/// it is proved Swift's shape: `ctl-` and a lowercase version 4 UUID.
fn generated(text: &str) -> String {
    let mut output = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("\"ctl-") {
        output.push_str(&rest[..at + 5]);
        rest = &rest[at + 5..];
        let uuid = rest.len() >= 36
            && rest.as_bytes()[..36]
                .iter()
                .enumerate()
                .all(|(index, byte)| match index {
                    8 | 13 | 18 | 23 => *byte == b'-',
                    14 => *byte == b'4',
                    19 => b"89ab".contains(byte),
                    _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
                });
        if uuid {
            output.push_str("<uuid>");
            rest = &rest[36..];
        }
    }
    output.push_str(rest);
    output
}

/// `argument` as Foundation's `Process` hands it to the child, in its file
/// system representation (canonically decomposed): what the Swift CLI the
/// oracle recorded actually received. Only the precomposed letter the oracle
/// uses is decomposed here; any other non-ASCII scalar fails the test rather
/// than being passed on unlike Swift's.
fn decomposed(argument: &str) -> String {
    let mut output = String::new();
    for character in argument.chars() {
        match character {
            '\u{e9}' => output.push_str("e\u{301}"),
            '\u{301}' => output.push(character),
            character if character.is_ascii() => output.push(character),
            other => panic!("the replay does not decompose {other:?}"),
        }
    }
    output
}

/// A private root, removed however the test ends.
struct Root(String);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::new();
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                text.push(TABLE[(value >> (18 - 6 * index) & 63) as usize] as char);
            } else {
                text.push('=');
            }
        }
    }
    text
}

#[test]
fn swifts_recorded_prepare_runs_replay_through_the_cli() {
    let oracle = oracle();
    let root = std::fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!(
            "arkdeck-uf-{:016x}",
            u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap())
        ))
        .to_str()
        .unwrap()
        .to_owned();
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .unwrap();
    let root = Root(root);
    std::fs::write(
        format!("{}/ArkDeck-1.2.3.dmg", root.0),
        b"arkdeck release artifact bytes\n",
    )
    .unwrap();
    std::fs::write(format!("{}/empty.dmg", root.0), b"").unwrap();
    let label = |text: &str| text.replace(&root.0, "<root>");
    let mut failures = Vec::new();
    let mut replayed = 0;
    for run in oracle["runs"].as_array().unwrap() {
        let name = run["name"].as_str().unwrap();
        let argv: Vec<String> = run["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| decomposed(&argument.as_str().unwrap().replace("<root>", &root.0)))
            .collect();
        if argv.iter().any(|argument| argument == "assemble") {
            continue;
        }
        replayed += 1;
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .output()
            .unwrap();
        let stdout = generated(&label(&String::from_utf8_lossy(&output.stdout)));
        let stderr = label(&String::from_utf8_lossy(&output.stderr));
        if run["exit"].as_i64() != output.status.code().map(i64::from)
            || run["stdout"] != stdout.as_str()
            || run["stderr"] != stderr.as_str()
        {
            failures.push(format!(
                "{name}: exit {:?} stdout {stdout} stderr {stderr}",
                output.status.code()
            ));
        }
    }
    for file in oracle["files"].as_array().unwrap() {
        let path = format!("{}/{}", root.0, file["path"].as_str().unwrap());
        let metadata = std::fs::symlink_metadata(&path);
        let mode = metadata
            .as_ref()
            .map(|m| i64::from(m.permissions().mode() & 0o777));
        let same = mode.as_ref().ok() == file["mode"].as_i64().as_ref()
            && file.get("base64").is_none_or(|expected| {
                std::fs::read(&path).is_ok_and(|bytes| expected == base64(&bytes).as_str())
            });
        if !same {
            failures.push(format!("{}: mode {mode:?}", file["path"]));
        }
    }
    assert_eq!(replayed, 26);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
