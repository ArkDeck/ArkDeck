//! `ProcessDispatch` on the verified tool runner (SPK-6, TASK-XPA-016): what a
//! device-scoped HDC plan gets back for each way a child can end, judged as
//! Swift's `DescriptorBoundProcessDispatcher` judges it, and what a child is
//! told. Every child is a shell script under a scratch directory or the shared
//! fake HDC driver; no HDC is launched. Spawning children, these tests keep a
//! binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{
    DispatchFailure, HdcDispatch, ProcessDispatch, ProcessPlan, SERVER_PORT_VARIABLE,
};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-dispatch-{name}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path.canonicalize().unwrap())
    }

    fn tool(&self, body: &str) -> VerifiedTool {
        let path = self.0.join("tool");
        let bytes = format!("#!/bin/sh\n{body}\n");
        fs::write(&path, &bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        VerifiedTool::open(path, &format!("{:x}", Sha256::digest(bytes.as_bytes()))).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn plan(arguments: &[&str], timeout: Duration, capture_bytes: usize) -> ProcessPlan {
    ProcessPlan {
        arguments: arguments.iter().map(|value| (*value).to_string()).collect(),
        timeout,
        capture_bytes,
    }
}

fn budget() -> Duration {
    Duration::from_secs(10)
}

#[test]
fn the_receipt_is_the_child_exit_status_and_both_streams() {
    let scratch = Scratch::new("receipt");
    let dispatch = ProcessDispatch::new(
        scratch.tool(r#"printf 'out %s' "$1"; printf 'err' >&2; exit 3"#),
        None,
    );
    let receipt = dispatch.dispatch(&plan(&["x"], budget(), 1024)).unwrap();
    assert_eq!(receipt.exit_status, 3);
    assert_eq!(receipt.stdout, b"out x");
    assert_eq!(receipt.stderr, b"err");
    assert!(!receipt.truncated);
    assert!(receipt.duration > Duration::ZERO);
}

#[test]
fn a_stream_past_the_capture_is_truncated_with_the_real_exit_status() {
    let scratch = Scratch::new("truncated");
    let dispatch = ProcessDispatch::new(
        scratch.tool("head -c 8192 /dev/zero | tr '\\0' a; exit 4"),
        None,
    );
    let receipt = dispatch.dispatch(&plan(&[], budget(), 4096)).unwrap();
    assert_eq!(receipt.exit_status, 4);
    assert!(receipt.truncated);
    assert_eq!(receipt.stdout.len(), 4096);
    assert!(receipt.stdout.iter().all(|byte| *byte == b'a'));

    let scratch = Scratch::new("truncated-stderr");
    let dispatch = ProcessDispatch::new(
        scratch.tool("head -c 8192 /dev/zero | tr '\\0' b >&2; printf ok"),
        None,
    );
    let receipt = dispatch.dispatch(&plan(&[], budget(), 4096)).unwrap();
    assert_eq!(receipt.exit_status, 0);
    assert!(receipt.truncated);
    assert_eq!(receipt.stdout, b"ok");
    assert_eq!(receipt.stderr.len(), 4096);
}

#[test]
fn a_timeout_leaves_the_outcome_unobservable() {
    let scratch = Scratch::new("timeout");
    let dispatch = ProcessDispatch::new(scratch.tool("sleep 30"), None);
    let started = Instant::now();
    let error = dispatch
        .dispatch(&plan(&[], Duration::from_secs(2), 1024))
        .unwrap_err();
    assert_eq!(
        error,
        DispatchFailure::Unobservable("process timed out before completion".into())
    );
    assert!(started.elapsed() < Duration::from_secs(15));
}

#[test]
fn a_child_killed_by_a_signal_is_a_host_fault() {
    let scratch = Scratch::new("signal");
    let dispatch = ProcessDispatch::new(scratch.tool("kill -KILL $$"), None);
    let error = dispatch.dispatch(&plan(&[], budget(), 1024)).unwrap_err();
    let DispatchFailure::Unobservable(message) = error else {
        panic!("a signalled child is unobservable, not refused: {error:?}");
    };
    assert_eq!(
        message,
        "process died on signal 9; the child never reached its own semantic boundary. \
         Its crash report is in ~/Library/Logs/DiagnosticReports/ (look for a same-second \
         entry named after the executable)."
    );
}

#[test]
fn a_refused_budget_dispatches_nothing() {
    let scratch = Scratch::new("refused");
    let witness = scratch.0.join("ran");
    let dispatch = ProcessDispatch::new(
        scratch.tool(&format!("printf ran > '{}'", witness.display())),
        None,
    );
    let error = dispatch
        .dispatch(&plan(&[], Duration::ZERO, 1024))
        .unwrap_err();
    let DispatchFailure::Refused(message) = error else {
        panic!("a budget refusal dispatches nothing: {error:?}");
    };
    assert!(message.starts_with("dispatch refused: "), "{message}");
    assert!(!witness.exists());
}

#[test]
fn only_a_valid_inherited_server_port_reaches_the_child() {
    let scratch = Scratch::new("port");
    let tool = || {
        scratch.tool(&format!(
            "printf '%s' \"${{{SERVER_PORT_VARIABLE}-unset}}\""
        ))
    };
    let answer = |port: Option<&str>| {
        ProcessDispatch::new(tool(), port)
            .dispatch(&plan(&[], budget(), 1024))
            .unwrap()
            .stdout
    };
    assert_eq!(answer(Some("8710")), b"8710");
    assert_eq!(answer(Some("+8710")), b"8710");
    assert_eq!(answer(Some("0")), b"unset");
    assert_eq!(answer(Some("65536")), b"unset");
    assert_eq!(answer(Some("port")), b"unset");
    assert_eq!(answer(None), b"unset");
    assert!(ProcessDispatch::new(tool(), None).environment().is_empty());
}

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

fn observe_fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/observe-device")
}

/// The shared fake HDC driver of the Swift oracles, at its fixed root, answers
/// the observe fixture's `list targets -v` through the runner exactly as the
/// oracle recorded it, and logs the argv it was given.
#[test]
fn the_shared_fake_driver_answers_through_the_runner() {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    let fixture = observe_fixture();
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    fs::set_permissions(root.join("hdc"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    File::create(root.join("hdc-invocations.log")).unwrap();
    let digest = format!("{:x}", Sha256::digest(fs::read(root.join("hdc")).unwrap()));
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
    assert_eq!(dispatch.tool_sha256(), digest);
    let receipt = dispatch
        .dispatch(&plan(
            &["list", "targets", "-v"],
            Duration::from_secs(15),
            8 * 1024 * 1024,
        ))
        .unwrap();
    assert_eq!(receipt.exit_status, 0);
    assert_eq!(
        receipt.stdout,
        b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n"
    );
    assert!(receipt.stderr.is_empty());
    assert!(!receipt.truncated);
    assert_eq!(
        fs::read(root.join("hdc-invocations.log")).unwrap(),
        b"list\x1ftargets\x1f-v\x1f\n"
    );
    let _ = fs::remove_dir_all(&root);
}
