//! The Windows CLI's client-started daemon (TASK-XPA-002, CHG-2026-074 r12
//! decision 11) as the `arkdeck` process answers, over isolated development
//! roots, with no daemon identity configured: a command that needs the
//! Runtime starts nothing and says why in `details.daemonStart`; the service
//! leaves answer in the macOS leaves' envelopes; the LaunchAgent-only leaves
//! stay `unsupportedOnPlatform`. The positive paths (a signed daemon started,
//! verified and restarted) are `arkdeck-agentd`'s
//! `tests/windows_client_start_process.rs`, which has the daemon binary.
#![cfg(windows)]

use serde_json::Value;
use std::path::PathBuf;
use std::process::{Command, Output};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir().join(format!("ad-cli-service-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `arkdeck` over `root` with no ArkDeck or HDC input but the root, and the
/// daemon beside it (never launched: no identity is configured).
fn arkdeck(root: &Root, arguments: &[&str]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck"));
    for (key, _) in std::env::vars_os() {
        let upper = key.to_string_lossy().to_ascii_uppercase();
        if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
            command.env_remove(key);
        }
    }
    command
        .env("ARKDECK_DEVELOPMENT_STATE_ROOT", &root.0)
        .args(arguments)
        .output()
        .unwrap()
}

fn document(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout).unwrap_or_else(|error| panic!("{error}: {output:?}"))
}

#[test]
fn a_command_that_needs_the_runtime_starts_nothing_without_an_identity() {
    let root = Root::new();
    let output = arkdeck(&root, &["--output", "json", "doctor"]);
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let answer = document(&output);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"]["code"], "runtimeUnavailable", "{answer}");
    assert_eq!(
        answer["error"]["details"]["daemonStart"]["outcome"], "launchRefused",
        "{answer}"
    );
    assert!(
        answer["error"]["details"]["daemonStart"]
            .get("pid")
            .is_none()
    );
    assert!(!root.0.join("instance.json").exists());
}

#[test]
fn verify_and_status_report_an_unverified_image_and_start_nothing() {
    let root = Root::new();
    let verify = arkdeck(&root, &["--output", "json", "runtime", "service", "verify"]);
    assert_eq!(verify.status.code(), Some(69), "{verify:?}");
    let answer = document(&verify);
    let result = &answer["result"];
    assert_eq!(result["runtimeVerified"], false, "{answer}");
    assert_eq!(result["runtime"], Value::Null);
    let service = &result["daemonService"];
    assert_eq!(service["startMode"], "clientStarted");
    assert_eq!(service["ready"], false);
    assert_eq!(service["daemonImage"]["verified"], false);
    assert_eq!(service["stateRoot"]["kind"], "development");
    assert_eq!(service["stateRoot"]["present"], true);
    assert_eq!(service["socketPresent"], false);
    assert!(
        String::from_utf8_lossy(&verify.stderr).contains("daemon service is not ready"),
        "{verify:?}"
    );

    let status = arkdeck(&root, &["--output", "json", "runtime", "service", "status"]);
    assert_eq!(status.status.code(), Some(0), "{status:?}");
    let answer = document(&status);
    assert_eq!(answer["result"]["daemonHealth"]["status"], "socket_absent");
    assert!(!root.0.join("instance.json").exists());
}

#[test]
fn restart_refuses_a_service_that_is_not_ready_and_an_option_out_of_range() {
    let root = Root::new();
    let refused = arkdeck(&root, &["runtime", "service", "restart"]);
    assert_eq!(refused.status.code(), Some(69), "{refused:?}");
    assert!(refused.stdout.is_empty());
    let range = arkdeck(
        &root,
        &[
            "runtime",
            "service",
            "restart",
            "--maximum-wait-seconds",
            "301",
        ],
    );
    // The parser refuses it before the leaf runs, as on macOS.
    assert_eq!(range.status.code(), Some(64), "{range:?}");
    assert!(range.stdout.is_empty());
}

#[test]
fn the_launch_agent_leaves_and_verify_s_job_options_stay_macos_only() {
    let root = Root::new();
    for arguments in [
        &["--output", "json", "runtime", "service", "update"][..],
        &[
            "--output", "json", "runtime", "service", "verify", "--job", "job-1",
        ][..],
    ] {
        let output = arkdeck(&root, arguments);
        let answer = document(&output);
        assert_eq!(
            answer["error"]["code"], "unsupportedOnPlatform",
            "{arguments:?}: {answer}"
        );
        assert_eq!(output.status.code(), Some(69), "{arguments:?}");
    }
}

/// With no daemon running there is nothing to stop: `uninstall` answers what
/// it kept, starts nothing and needs no verified image.
#[test]
fn uninstall_with_no_daemon_running_stops_and_starts_nothing() {
    let root = Root::new();
    let output = arkdeck(
        &root,
        &["--output", "json", "runtime", "service", "uninstall"],
    );
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    let answer = document(&output);
    let uninstall = &answer["result"]["uninstall"];
    assert_eq!(
        uninstall["schemaVersion"],
        "arkdeck-windows-daemon-uninstall/v1"
    );
    assert_eq!(uninstall["stoppedPid"], Value::Null, "{answer}");
    assert_eq!(uninstall["drain"], Value::Null, "{answer}");
    assert_eq!(uninstall["removedRegistration"], false, "{answer}");
    assert_eq!(
        uninstall["preservedStateDirectory"],
        root.0.to_str().unwrap(),
        "{answer}"
    );
    assert_eq!(answer["result"]["daemonService"]["socketPresent"], false);
    assert!(
        !root.0.join("instance.json").exists(),
        "nothing was started"
    );
}
