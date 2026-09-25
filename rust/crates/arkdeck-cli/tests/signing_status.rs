//! `runtime signing status` and its deprecated `signing status` spelling
//! replayed through the CLI process against Swift's recorded runs
//! (`rust/tests/fixtures/signing-status`, `CLISigningStatusOracleContractTests`,
//! whose owners are `RuntimeCLI.runSigning`,
//! `OpenHarmonySigningPresetStore.status` and
//! `OpenHarmonySigningCredentialOwner.current`).
//!
//! Each run gets a private home (`CFFIXED_USER_HOME` and `HOME`) holding the
//! case's preset receipt, if any; no case reaches the Keychain. The CLI must
//! end as Swift's did: the same exit status, in a machine mode the same bytes
//! on stdout and stderr (a generated correlation identity, of Swift's shape,
//! compared as the oracle's `ctl-<uuid>`),
//! in the human rendering the same warning (Swift's outline and this CLI's
//! pretty JSON, T2), and the same files left under the home.
#![cfg(target_os = "macos")]

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;

const PRESET_DIRECTORY: &str = "Library/Application Support/ArkDeck/Signing/OpenHarmony";

fn cases() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/signing-status/cases.json");
    serde_json::from_slice::<Value>(&std::fs::read(path).unwrap())
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// A private home, removed however the test ends.
struct Home(PathBuf);

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn private_home() -> Home {
    let home = std::fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!(
            "arkdeck-cli-signing-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
    std::fs::create_dir(&home).unwrap();
    Home(home)
}

/// Every regular file under `root`, relative, with its bytes as text.
fn files(root: &Path, directory: &Path, found: &mut Vec<(String, String)>) {
    for entry in std::fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        let kind = std::fs::symlink_metadata(&path).unwrap().file_type();
        if kind.is_dir() {
            files(root, &path, found);
        } else if kind.is_file() {
            found.push((
                path.strip_prefix(root)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_owned(),
                String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned(),
            ));
        }
    }
}

/// `text` with each generated correlation identity spelled `ctl-<uuid>`, as
/// the oracle records Swift's (these leaves take none from the caller), once
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

fn replay(case: &Value) -> Result<(), String> {
    let name = case["name"].as_str().unwrap();
    let home = private_home();
    if let Some(receipt) = case["receipt"].as_str() {
        let directory = home.0.join(PRESET_DIRECTORY);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("preset-v1.json"), receipt).unwrap();
    }
    let argv: Vec<&str> = case["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|argument| argument.as_str().unwrap())
        .collect();
    let output = Command::new(env!("CARGO_BIN_EXE_arkdeck"))
        .args(&argv)
        .env("CFFIXED_USER_HOME", &home.0)
        .env("HOME", &home.0)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let context = format!("{name}: stdout {stdout} stderr {stderr}");
    let check = |same: bool, what: &str| {
        if same {
            Ok(())
        } else {
            Err(format!("{what} differs: {context}"))
        }
    };
    check(
        case["exit"].as_i64() == output.status.code().map(i64::from),
        "exit",
    )?;
    let mut left = Vec::new();
    files(&home.0, &home.0, &mut left);
    left.sort();
    let left: Vec<Value> = left
        .into_iter()
        .map(|(path, content)| json!({"path": path, "content": content}))
        .collect();
    check(Value::Array(left) == case["files"], "files left")?;
    if argv.contains(&"--output") || argv.contains(&"--json") {
        check(
            generated(case["stdout"].as_str().unwrap()) == generated(&stdout),
            "stdout",
        )?;
        check(case["stderr"] == stderr.as_str(), "stderr")
    } else {
        // The human rendering is Swift's key-value outline and this CLI's
        // pretty JSON (T2): the same status, warning and files.
        check(
            !stdout.is_empty() && case["stderr"] == stderr.as_str(),
            "human rendering",
        )
    }
}

#[test]
fn every_recorded_run_replays_through_the_cli() {
    let cases = cases();
    let failures: Vec<String> = cases.iter().filter_map(|case| replay(case).err()).collect();
    assert_eq!(cases.len(), 7);
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}
