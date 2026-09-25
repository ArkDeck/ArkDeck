//! `arkdeck-agentd --symbolize-crash <map> <dump>`, the one-shot mode a
//! registered symbol preset runs for `workspace.symbolize-crash@1`, through
//! the built daemon with an empty environment and no stdin, as the Runtime
//! runs a preset's child: every case of the Swift symbolizer oracle
//! (`rust/tests/fixtures/crash-symbolizer-oracle`) answers Swift's report on
//! stdout with exit 0 — or, for a map that is not a JSON object, exit 1 and a
//! line naming the error — and the usage refusals are Swift's line and exit
//! 64, with nothing read. Host only: no store, socket, HDC or device.
#![cfg(target_os = "macos")]

use serde_json::Value;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
const USAGE: &str = "--symbolize-crash requires an absolute source map path and dump path\n";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn unbase64(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = Vec::new();
    let (mut buffer, mut bits) = (0_u32, 0);
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = ALPHABET.iter().position(|a| *a == byte).unwrap() as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    bytes
}

/// A private directory, removed when the test ends.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/arkdeck-symbolize-mode-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(arguments: &[&str]) -> (i32, Vec<u8>, Vec<u8>) {
    let output = Command::new(DAEMON)
        .args(arguments)
        .env_clear()
        .stdin(Stdio::null())
        .output()
        .unwrap();
    (output.status.code().unwrap(), output.stdout, output.stderr)
}

#[test]
fn the_daemon_symbolizes_every_recorded_case_as_swift_reports_it() {
    let scratch = Scratch::new();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture("crash-symbolizer-oracle/cases.json")).unwrap())
            .unwrap();
    for (index, case) in cases.as_array().unwrap().iter().enumerate() {
        let name = case["name"].as_str().unwrap();
        let map = scratch.0.join(format!("{index}.map"));
        let dump = scratch.0.join(format!("{index}.txt"));
        fs::write(&map, unbase64(case["map"].as_str().unwrap())).unwrap();
        fs::write(&dump, unbase64(case["dump"].as_str().unwrap())).unwrap();
        let (status, stdout, stderr) = run(&[
            "--symbolize-crash",
            map.to_str().unwrap(),
            dump.to_str().unwrap(),
        ]);
        if let Some(report) = case.get("report") {
            assert_eq!(status, 0, "{name}: {}", String::from_utf8_lossy(&stderr));
            assert_eq!(stdout, report.as_str().unwrap().as_bytes(), "{name}");
            assert!(stderr.is_empty(), "{name}");
        } else {
            assert_eq!(status, 1, "{name}");
            assert!(stdout.is_empty(), "{name}");
            let line = String::from_utf8(stderr).unwrap();
            assert!(
                line.starts_with("crash symbolization failed: sourceMapUnreadable("),
                "{name}: {line}"
            );
            if case.get("detail").is_some() {
                assert_eq!(
                    line,
                    "crash symbolization failed: sourceMapUnreadable(\"not a JSON object\")\n",
                    "{name}"
                );
            }
        }
    }
}

#[test]
fn a_usage_the_mode_does_not_take_is_refused_before_anything_is_read() {
    let scratch = Scratch::new();
    let map = scratch.0.join("absent.map");
    let text = map.to_str().unwrap();
    for arguments in [
        vec!["--symbolize-crash"],
        vec!["--symbolize-crash", text],
        vec!["--symbolize-crash", text, "relative.txt"],
        vec!["--symbolize-crash", "relative.map", text],
        vec!["--symbolize-crash", text, text, text],
    ] {
        let (status, stdout, stderr) = run(&arguments);
        assert_eq!(status, 64, "{arguments:?}");
        assert!(stdout.is_empty(), "{arguments:?}");
        assert_eq!(stderr, USAGE.as_bytes(), "{arguments:?}");
    }
    // Absolute but unreadable: a read failure, never a usage refusal.
    let (status, stdout, stderr) = run(&["--symbolize-crash", text, text]);
    assert_eq!(status, 1);
    assert!(stdout.is_empty());
    let line = String::from_utf8(stderr).unwrap();
    assert!(line.starts_with("crash symbolization failed: "), "{line}");
    assert!(
        !line.contains(text),
        "the line never names the path: {line}"
    );
}
