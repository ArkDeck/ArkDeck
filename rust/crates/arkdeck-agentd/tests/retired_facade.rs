//! The retired transport facade (TASK-XPA-017): the daemon no longer forwards
//! to a Swift authority. Under the facade's executable name, or handed a Swift
//! daemon or its pin to pair, it refuses to start before it binds a socket or
//! opens a store. Temporary directories only; no launchd, device or installed
//! state is touched.
#![cfg(target_os = "macos")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "arkdeck-retired-facade-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        Self(root.canonicalize().unwrap())
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Runs `executable` with only `environment`, killing it if it has not ended
/// on its own: a daemon that started serving would never end.
fn run(executable: &Path, home: &Path, environment: &[(&str, &str)]) -> Output {
    let mut child = Command::new(executable)
        .env_clear()
        .env("HOME", home)
        .env("CFFIXED_USER_HOME", home)
        .envs(environment.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let output = child.wait_with_output().unwrap();
            panic!("the daemon kept running: {output:?}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().unwrap()
}

fn entries(root: &Path) -> Vec<PathBuf> {
    let mut entries = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if fs::symlink_metadata(&path).unwrap().is_dir() {
                pending.push(path.clone());
            }
            entries.push(path);
        }
    }
    entries.sort();
    entries
}

#[test]
fn the_facade_mode_is_retired_under_its_name_and_its_pairing() {
    let scratch = Scratch::new();
    let home = scratch.0.join("home");
    fs::create_dir(&home).unwrap();
    let facade = scratch.0.join("arkdeck-facade");
    fs::hard_link(DAEMON, &facade)
        .or_else(|_| fs::copy(DAEMON, &facade).map(drop))
        .unwrap();
    // A Swift sibling the facade would once have paired with, never run.
    let swift = scratch.0.join("arkdeck-agentd");
    fs::write(&swift, b"#!/bin/sh\nexit 97\n").unwrap();
    let endpoint = scratch.0.join("agentd.sock");
    let endpoint = endpoint.to_str().unwrap();
    let before = entries(&scratch.0);

    for (executable, environment, reason) in [
        (
            facade.as_path(),
            vec![("ARKDECK_ENDPOINT", endpoint)],
            "arkdeck-facade no longer pairs",
        ),
        (
            Path::new(DAEMON),
            vec![
                ("ARKDECK_ENDPOINT", endpoint),
                ("ARKDECK_SWIFT_DAEMON", swift.to_str().unwrap()),
            ],
            "takes no ARKDECK_SWIFT_DAEMON",
        ),
        (
            Path::new(DAEMON),
            vec![
                ("ARKDECK_ENDPOINT", endpoint),
                ("ARKDECK_SWIFT_SHA256", "0000"),
            ],
            "takes no ARKDECK_SWIFT_SHA256",
        ),
        // The production composition names the pairing as another
        // composition's input, and the facade's name as not its own.
        (
            Path::new(DAEMON),
            vec![
                ("ARKDECK_RUNTIME_COMPOSITION", "production"),
                ("ARKDECK_SWIFT_DAEMON", swift.to_str().unwrap()),
            ],
            "production composition takes no ARKDECK_SWIFT_DAEMON",
        ),
        (
            facade.as_path(),
            vec![("ARKDECK_RUNTIME_COMPOSITION", "production")],
            "facade executable does not run the production composition",
        ),
    ] {
        let output = run(executable, &home, &environment);
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        assert!(output.stdout.is_empty(), "{output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(stderr.contains(reason), "{stderr}");
        // Nothing was bound, created or run.
        assert_eq!(entries(&scratch.0), before);
    }
}
