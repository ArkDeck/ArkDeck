//! Actual Swift CLI states, cache effects and failures, replayed with an
//! isolated CFFIXED_USER_HOME. The Python parent holds real cross-process
//! flock leases for the live-operation scenarios; no device or network runs.
#![cfg(target_os = "macos")]
use std::path::Path;
use std::process::Command;

#[test]
fn swift_update_lifecycle_process_oracle_replays() {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/record-runtime-update-oracle.py");
    let output = Command::new("python3")
        .arg(script)
        .args(["--replay-cli", env!("CARGO_BIN_EXE_arkdeck")])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("Replayed 20 actual Swift CLI cases"));
}
