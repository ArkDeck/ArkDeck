//! `ManagedServer` (SPK-6, TASK-XPA-016): a launched process kept without a
//! budget, its launch recorded from the kernel, its streams captured, ended
//! by its owner or on its own. Every child is a shell script under a scratch
//! directory. Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]

use arkdeck_platform::{ManagedServer, ServerExit, VerifiedTool};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "arkdeck-managed-{name}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self(path.canonicalize().unwrap())
    }

    fn tool(&self, body: &str) -> VerifiedTool {
        let path = self.0.join("tool");
        let bytes = format!("#!/bin/sh\n{body}\n");
        std::fs::write(&path, &bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        VerifiedTool::open(path, &format!("{:x}", Sha256::digest(bytes.as_bytes()))).unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

/// A script's own word that it has written what the test reads back: under
/// load `/bin/sh` may take longer to start than any fixed wait, so the test
/// waits for the fact, not the clock.
fn wait_for(marker: &std::path::Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !marker.exists() {
        assert!(
            Instant::now() < deadline,
            "the server never reached {}",
            marker.display()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_launched_server_is_recorded_kept_and_stopped_with_its_output() {
    let scratch = Scratch::new("kept");
    let marker = scratch.0.join("written");
    let tool = scratch.tool(&format!(
        r#"printf 'started %s\n' "$1"; printf 'noted\n' >&2; : > '{}'; sleep 600"#,
        marker.display()
    ));
    let mut server = ManagedServer::launch(&tool, &args(&["x"]), &[], 4096).unwrap();
    let launch = server.launch_record().clone();
    assert!(launch.pid > 0);
    assert!(launch.start_seconds > 0);
    assert!(launch.start_microseconds < 1_000_000);
    assert_eq!(launch.executable_path, scratch.0.join("tool"));
    assert_eq!(launch.executable_sha256, tool.sha256());
    assert_eq!(launch.arguments, args(&["x"]));
    assert!(server.same_birth());
    wait_for(&marker);
    assert_eq!(server.exit().unwrap(), None);
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.stdout, b"started x\n");
    assert_eq!(stopped.stderr, b"noted\n");
    assert!(!stopped.truncated);
    assert!(
        matches!(stopped.exit, ServerExit::Signalled(signal) if signal == libc::SIGTERM || signal == libc::SIGKILL),
        "{:?}",
        stopped.exit
    );
    // The launch's PID no longer carries its birth once the process is gone.
    assert!(!process_alive(launch.pid));
}

#[test]
fn a_server_that_ends_on_its_own_reports_its_exit_once() {
    let scratch = Scratch::new("ended");
    let tool = scratch.tool("printf 'bye'; exit 7");
    let mut server = ManagedServer::launch(&tool, &[], &[], 4096).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let exit = loop {
        if let Some(exit) = server.exit().unwrap() {
            break exit;
        }
        assert!(Instant::now() < deadline, "the server never ended");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(exit, ServerExit::Exited(7));
    assert_eq!(server.exit().unwrap(), Some(exit));
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.exit, ServerExit::Exited(7));
    assert_eq!(stopped.stdout, b"bye");
}

#[test]
fn output_past_the_capture_is_kept_to_the_limit_and_noted() {
    let scratch = Scratch::new("capture");
    let marker = scratch.0.join("written");
    let tool = scratch.tool(&format!(
        "head -c 8192 /dev/zero | tr '\\0' a; : > '{}'; sleep 600",
        marker.display()
    ));
    let mut server = ManagedServer::launch(&tool, &[], &[], 1024).unwrap();
    wait_for(&marker);
    assert_eq!(server.exit().unwrap(), None);
    let stopped = server.stop().unwrap();
    assert_eq!(stopped.stdout.len(), 1024);
    assert!(stopped.truncated);
}

#[test]
fn a_refused_environment_or_capture_launches_nothing() {
    let scratch = Scratch::new("refused");
    let witness = scratch.0.join("ran");
    let tool = scratch.tool(&format!("printf ran > '{}'; sleep 600", witness.display()));
    let path = [(OsString::from("PATH"), OsString::from("/nowhere"))];
    assert!(ManagedServer::launch(&tool, &[], &path, 4096).is_err());
    assert!(ManagedServer::launch(&tool, &[], &[], 0).is_err());
    std::thread::sleep(Duration::from_millis(200));
    assert!(!witness.exists());
}

fn process_alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks whether the PID exists and may be signalled.
    unsafe { libc::kill(pid, 0) == 0 }
}
