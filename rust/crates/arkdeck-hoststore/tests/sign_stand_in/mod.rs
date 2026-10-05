//! The stand-in signer of the Swift `workspace.sign-openharmony-hap@1`
//! oracle (`rust/tests/fixtures/workspace-sign-oracle/hap-signer.sh`) on
//! Windows: a test binary run as `java.exe -jar <jar> <command> …` follows
//! `hap-signer.sh`'s protocol exactly — both passwords asked for on the
//! console and never printed, `sign-app` appending the marker to the staged
//! input, `verify-app` writing the two readbacks, and the mode read from the
//! HAP's `mode=` line, with the recorded `/tmp/…` marker path read as the same
//! name below the stand-in's root. Shared by the oracle replay
//! (`windows_workspace_sign_oracle.rs`) and the CLI's signing measurement
//! (`arkdeck-agentd/tests/windows_sign_stand_in.rs`). Test-only.
#![cfg(windows)]
#![allow(dead_code)]

use arkdeck_platform::Secret;
use std::fs;
use std::io::Write;
use std::path::Path;

/// The recording's root, as its receipt and the inputs name it.
pub const SWIFT_ROOT: &str = "/tmp/arkdeck-workspace-sign-oracle";
pub const KEYSTORE_PROMPT: &str = "please input KeystorePwd (timeout 30 seconds):";
pub const KEY_PROMPT: &str = "please input KeyPwd (timeout 30 seconds):";

fn option(arguments: &[String], name: &str) -> String {
    arguments
        .iter()
        .position(|argument| argument == name)
        .and_then(|index| arguments.get(index + 1))
        .cloned()
        .unwrap_or_default()
}

fn say(text: &str) {
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(text.as_bytes()).unwrap();
    stdout.flush().unwrap();
}

/// `IFS= read -r` after a prompt, from the console, echo cleared.
fn ask(prompt: &str) -> Option<Secret> {
    arkdeck_platform::read_terminal_secret(prompt)
        .ok()
        .filter(|secret| !secret.as_bytes().is_empty())
}

/// `hap-signer.sh`, statement for statement. `arguments` starts at `-jar`;
/// `root` is where the recording's `/tmp/…` names are read.
pub fn stand_in(arguments: &[String], root: &Path) -> ! {
    use std::process::exit;
    if arguments.len() < 3 || !Path::new(&arguments[1]).is_file() {
        exit(64);
    }
    let command = arguments[2].as_str();
    let rest = &arguments[3..];
    let input = option(rest, "-inFile");
    let output = option(rest, "-outFile");
    let chain = option(rest, "-outCertChain");
    let profile = option(rest, "-outProfile");
    let Ok(bytes) = fs::read(&input) else {
        exit(64)
    };
    let mode = String::from_utf8_lossy(&bytes)
        .lines()
        .find_map(|line| line.strip_prefix("mode=").map(str::to_owned))
        .unwrap_or_default();
    match command {
        "sign-app" => {
            if output.is_empty() {
                exit(64);
            }
            if mode == "unknown-prompt" {
                say("Password: ");
                std::thread::sleep(std::time::Duration::from_secs(1));
                exit(65);
            }
            let Some(keystore) = ask(KEYSTORE_PROMPT) else {
                exit(66)
            };
            if mode == "repeat-prompt" {
                say(KEYSTORE_PROMPT);
                std::thread::sleep(std::time::Duration::from_secs(1));
                exit(67);
            }
            let Some(_key) = ask(KEY_PROMPT) else {
                exit(68)
            };
            match mode.as_str() {
                "echo-secret" => {
                    say(std::str::from_utf8(keystore.as_bytes()).unwrap());
                    exit(69);
                }
                "sign-failure" => {
                    say(
                        "Incorrect keystore password, please input the correct plaintext \
                         password.",
                    );
                    exit(74);
                }
                _ => {}
            }
            if !input.ends_with(".hap") {
                say("Invalid file format.");
                exit(75);
            }
            if Path::new(&output).exists() {
                exit(71);
            }
            let mut signed = bytes;
            signed.extend_from_slice(b"arkdeck-signed-fixture");
            if fs::write(&output, signed).is_err() {
                exit(70);
            }
            exit(0)
        }
        "verify-app" => {
            if chain.is_empty() || profile.is_empty() || !bytes.starts_with(b"PK\x03\x04") {
                exit(72);
            }
            if mode == "verify-failure" {
                exit(73);
            }
            if let Some(marker) = mode.strip_prefix("verify-once:") {
                let relative = marker
                    .strip_prefix(&format!("{SWIFT_ROOT}/"))
                    .unwrap_or_else(|| exit(72));
                let marker = root.join(relative.replace('/', "\\"));
                if !marker.exists() {
                    fs::write(&marker, b"failed-once").unwrap();
                    exit(73);
                }
            }
            if !Path::new(&chain).exists() {
                fs::write(&chain, b"fixture-certificate-chain").unwrap();
            }
            if !Path::new(&profile).exists() {
                fs::write(&profile, b"fixture-profile").unwrap();
            }
            exit(0)
        }
        _ => exit(64),
    }
}
