//! The persistent device shell channel (SPK-6 phase 3, TASK-XPA-016) driven
//! with `/bin/sh` over a pseudo-terminal in place of `hdc shell`: framed
//! answers with the command's own status, bare tokens only, budget and
//! overflow, timeout and client death as unknown outcomes, and the group
//! taken down with the channel. Spawning children, these tests keep a binary
//! of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{DeviceShellChannel, DeviceShellChannelError, VerifiedTool};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::time::{Duration, Instant};

const SH: &str = "/bin/sh";

fn shell() -> VerifiedTool {
    let digest = format!("{:x}", Sha256::digest(std::fs::read(SH).unwrap()));
    VerifiedTool::open(SH, &digest).unwrap()
}

fn open() -> DeviceShellChannel {
    DeviceShellChannel::open(
        &shell(),
        &[OsString::from("-i")],
        &[],
        Duration::from_secs(20),
    )
    .unwrap()
}

#[test]
fn a_framed_command_answers_with_the_devices_own_status_and_nothing_else() {
    let mut channel = open();
    let answer = channel
        .run(&["printf", "hello"], Duration::from_secs(10), 4096)
        .unwrap();
    assert_eq!(answer.stdout, b"hello");
    assert_eq!(answer.device_exit_status, 0);
    assert!(!answer.truncated);
    let failed = channel
        .run(&["false"], Duration::from_secs(10), 4096)
        .unwrap();
    assert_eq!(failed.stdout, b"");
    assert_eq!(failed.device_exit_status, 1);
    let refused = channel
        .run(&["printf", "a;b"], Duration::from_secs(10), 4096)
        .unwrap_err();
    // `;` is not a bare token; the channel refuses rather than quoting.
    assert!(matches!(refused, DeviceShellChannelError::Unavailable(_)));
    let again = channel
        .run(&["printf", "second"], Duration::from_secs(10), 4096)
        .unwrap();
    assert_eq!(again.stdout, b"second");
}

#[test]
fn an_answer_over_budget_is_trimmed_and_marked_but_the_channel_stays_open() {
    let mut channel = open();
    let answer = channel
        .run(&["seq", "1", "200"], Duration::from_secs(10), 16)
        .unwrap();
    assert_eq!(answer.stdout.len(), 16);
    assert!(answer.truncated);
    assert_eq!(answer.device_exit_status, 0);
    let next = channel
        .run(&["printf", "ok"], Duration::from_secs(10), 4096)
        .unwrap();
    assert_eq!(next.stdout, b"ok");
}

#[test]
fn a_command_that_never_frames_its_answer_is_an_unknown_outcome_and_closes_the_channel() {
    let mut channel = open();
    let started = Instant::now();
    let error = channel
        .run(&["sleep", "30"], Duration::from_secs(1), 4096)
        .unwrap_err();
    assert!(
        matches!(&error, DeviceShellChannelError::OutcomeUnknown(reason) if reason.contains("timeout")),
        "{error:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(!channel.is_alive());
    let closed = channel
        .run(&["true"], Duration::from_secs(1), 4096)
        .unwrap_err();
    assert!(matches!(closed, DeviceShellChannelError::Unavailable(_)));
}

#[test]
fn a_flood_past_every_bound_is_an_unknown_outcome() {
    let mut channel = open();
    let error = channel
        .run(&["yes"], Duration::from_secs(30), 1024)
        .unwrap_err();
    assert!(
        matches!(&error, DeviceShellChannelError::OutcomeUnknown(reason) if reason.contains("past every bound")),
        "{error:?}"
    );
    assert!(!channel.is_alive());
}

#[test]
fn a_client_that_exits_leaves_the_channel_unavailable() {
    let mut channel = open();
    let error = channel
        .run(&["exit", "3"], Duration::from_secs(5), 4096)
        .unwrap_err();
    assert!(
        matches!(error, DeviceShellChannelError::OutcomeUnknown(_)),
        "{error:?}"
    );
    assert!(!channel.is_alive());
}

#[test]
fn only_bare_tokens_are_carried() {
    let mut channel = open();
    for command in [
        vec!["printf", "a b"],
        vec!["true;", "false"],
        vec![],
        vec!["$HOME"],
    ] {
        let error = channel
            .run(&command, Duration::from_secs(5), 4096)
            .unwrap_err();
        assert!(
            matches!(error, DeviceShellChannelError::Unavailable(_)),
            "{command:?}"
        );
    }
    assert!(channel.is_alive());
}
