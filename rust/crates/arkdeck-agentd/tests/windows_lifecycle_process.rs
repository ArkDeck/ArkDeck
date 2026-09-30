//! The Windows daemon's lifecycle, as the real daemon runs it over an
//! isolated development root (TASK-XPA-002 S5, GJ-1's restart hop): it
//! starts and serves its pipe, a second start is answered `already running`,
//! a stop request drains and stops it, a restart reads back the state its
//! predecessor left, and a successor of a daemon that died holding its guard
//! finds the guard abandoned and starts as after a crash.
//!
//! Every daemon here runs with every `ARKDECK_` and `OHOS_HDC_` input
//! removed but its development root, a fresh directory below the temporary
//! directory: nothing installed is read or written, the account's
//! `%LOCALAPPDATA%\ArkDeck` included, and no HDC is configured. The test
//! reaches the pipe with a plain pipe handle: the product client's daemon
//! identity check (an installed, signed daemon) is not what this hop proves,
//! and nothing here relaxes it. Each daemon this test starts is stopped by
//! its own stop request, or ended by this test if it outlives a failed
//! assertion; no other process is touched.
#![cfg(windows)]

use arkdeck_platform::{GuardAcquisition, GuardObject, StateRoot};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: each starts daemons whose guards and pipes are
/// named after its own root, but a child `std::process::Command` spawns
/// inherits every inheritable handle of this process while it starts.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir().join(format!("ad-winlife-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn instance(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.0.join("instance.json")).unwrap()).unwrap()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(root: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy().into_owned();
        if key.to_ascii_uppercase().starts_with("ARKDECK_")
            || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
        {
            command.env_remove(key);
        }
    }
    command
        .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// A running daemon, its stdout read line by line as it comes.
struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl Daemon {
    fn start(root: &Path) -> Self {
        let mut child = daemon(root).spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self {
            child: Some(child),
            lines,
            seen: Vec::new(),
        }
    }

    fn pid(&self) -> u32 {
        self.child.as_ref().unwrap().id()
    }

    /// Every line up to the first that starts with `prefix`, which is returned.
    fn line_starting(&mut self, prefix: &str) -> String {
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(line) => {
                    self.seen.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(error) => {
                    let stderr = self.stderr();
                    panic!(
                        "no line starting {prefix:?} ({error}); stdout so far {:?}, stderr {stderr:?}",
                        self.seen
                    )
                }
            }
        }
    }

    fn stderr(&mut self) -> String {
        let Some(child) = self.child.as_mut() else {
            return String::new();
        };
        if child.try_wait().ok().flatten().is_none() {
            return "(still running)".into();
        }
        let mut text = String::new();
        if let Some(stderr) = child.stderr.as_mut() {
            let _ = stderr.read_to_string(&mut text);
        }
        text
    }

    /// Serving: its pipe, from the line it announces it with.
    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    /// Asks it to stop, by its root's scope and its pid, and waits for its
    /// end; everything it wrote after what was already read is returned.
    fn stop(&mut self, root: &Path) -> Vec<String> {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(self.pid()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let status = wait(self.child.take().unwrap());
        assert!(status.success(), "{status:?}");
        std::mem::take(&mut self.seen)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// The child's end, within the deadline.
fn wait(mut child: Child) -> std::process::ExitStatus {
    let (sender, receiver) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let status = child.wait();
        let _ = sender.send(());
        (child, status)
    });
    receiver
        .recv_timeout(DEADLINE)
        .expect("the daemon did not end within the deadline");
    waiter.join().unwrap().1.unwrap()
}

/// A plain handle on the daemon's pipe.
fn open_pipe(pipe: &str) -> std::fs::File {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .unwrap()
}

/// One health exchange on an open pipe handle.
fn health(pipe: &mut std::fs::File, id: &str) -> Value {
    let request = serde_json::json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": id,
        "method": "health",
    });
    let mut frame = serde_json::to_vec(&request).unwrap();
    frame.push(b'\n');
    pipe.write_all(&frame).unwrap();
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while byte[0] != b'\n' {
        assert_eq!(pipe.read(&mut byte).unwrap(), 1, "the reply ended early");
        reply.push(byte[0]);
    }
    serde_json::from_slice(&reply).unwrap()
}

#[test]
fn a_stopped_daemon_restarts_over_its_root_and_reads_back_its_state() {
    let _turn = turn();
    let root = Root::new();

    // Start: the root is taken and the pipe answers the control protocol.
    let mut first = Daemon::start(&root.0);
    let pipe = first.serving();
    let first_pid = first.pid();
    assert!(
        pipe.starts_with(r"\\.\pipe\arkdeck-agentd-dev-S-1-5-5-"),
        "{pipe}"
    );
    assert!(
        first
            .seen
            .iter()
            .all(|line| !line.starts_with("arkdeck-agentd previous instance")),
        "a fresh root has no predecessor: {:?}",
        first.seen
    );
    let written = root.instance();
    assert_eq!(written["pid"], first_pid);
    assert_eq!(written["socketPath"], pipe.as_str());
    assert_eq!(
        written["protocolVersion"],
        arkdeck_contract::PROTOCOL_VERSION
    );
    let mut connection = open_pipe(&pipe);
    let answer = health(&mut connection, "gj1-first");
    assert_eq!(answer["id"], "gj1-first");
    assert_eq!(answer["ok"], true, "{answer}");

    // A second daemon over the same root is refused before it composes
    // anything: Swift's second instance's answer, exit 0.
    let second = daemon(&root.0).output().unwrap();
    assert!(second.status.success(), "{second:?}");
    assert_eq!(
        String::from_utf8(second.stdout).unwrap(),
        format!(
            "arkdeck-agentd already running: pid {first_pid}, socket {pipe}, protocol {}\n",
            arkdeck_contract::PROTOCOL_VERSION
        )
    );
    assert_eq!(root.instance(), written, "the refused start wrote nothing");

    // Stop: the drain ends the connection still open (idle), then the
    // daemon lets go of its root and ends with 0.
    let tail = first.stop(&root.0);
    assert_eq!(
        tail.last().map(String::as_str),
        Some("arkdeck-agentd stopped")
    );
    let mut rest = Vec::new();
    connection.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty(), "{rest:?}");
    assert!(
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&pipe)
            .is_err(),
        "a stopped daemon's pipe refuses a client"
    );

    // Start again: the same root, the same pipe, and the state the first
    // daemon left read back before it is replaced.
    let mut restarted = Daemon::start(&root.0);
    assert_eq!(restarted.serving(), pipe);
    let previous = format!(
        "arkdeck-agentd previous instance: pid {first_pid}, started {}",
        written["startedAtUTC"].as_str().unwrap()
    );
    assert!(restarted.seen.contains(&previous), "{:?}", restarted.seen);
    assert!(
        restarted
            .seen
            .iter()
            .all(|line| !line.contains("single-instance guard")),
        "a clean stop leaves no abandoned guard: {:?}",
        restarted.seen
    );
    assert_eq!(root.instance()["pid"], restarted.pid());
    let answer = health(&mut open_pipe(&pipe), "gj1-restarted");
    assert_eq!(answer["ok"], true, "{answer}");
    restarted.stop(&root.0);
}

#[test]
fn the_successor_of_a_daemon_that_died_holding_its_guard_starts_as_after_a_crash() {
    let _turn = turn();
    let root = Root::new();
    let mut first = Daemon::start(&root.0);
    first.serving();
    let first_pid = first.pid();
    let scope = StateRoot::development(&root.0).unwrap().scope().unwrap();
    // A successor handed over to waits on the guard, as decision 11's
    // client-started daemon will: here a thread of this test. It has the
    // guard object open before the daemon dies.
    let object = GuardObject::open(&scope).unwrap();
    let successor = mpsc::channel();
    let waiter = {
        let successor = successor.0;
        std::thread::spawn(move || {
            let acquired = object.acquire(DEADLINE).unwrap();
            let GuardAcquisition::Owned { guard, abandoned } = acquired else {
                panic!("the waiting successor never took the guard");
            };
            successor.send(abandoned).unwrap();
            // It ends holding the guard, as a daemon that dies does: the
            // object stays open (the handle is not closed) and abandoned.
            std::mem::forget(guard);
        })
    };
    // The daemon dies without draining: this test ends the process it started.
    let mut child = first.child.take().unwrap();
    child.kill().unwrap();
    wait(child);
    assert!(
        successor.1.recv_timeout(DEADLINE).unwrap(),
        "a daemon killed holding its guard leaves it abandoned"
    );
    waiter.join().unwrap();

    // The next daemon finds the guard abandoned, says so, and starts as
    // after a crash over the state its killed predecessor left.
    let mut next = Daemon::start(&root.0);
    next.serving();
    assert!(
        next.seen.iter().any(|line| line
            == "arkdeck-agentd: the previous daemon of this state root ended holding its \
                single-instance guard; starting as after a crash"),
        "{:?}",
        next.seen
    );
    assert!(
        next.seen.iter().any(|line| line.starts_with(&format!(
            "arkdeck-agentd previous instance: pid {first_pid},"
        ))),
        "{:?}",
        next.seen
    );
    next.stop(&root.0);
    // Its clean stop released the guard: the one after it finds it free.
    let mut after = Daemon::start(&root.0);
    after.serving();
    assert!(
        after
            .seen
            .iter()
            .all(|line| !line.contains("single-instance guard")),
        "{:?}",
        after.seen
    );
    after.stop(&root.0);
}

#[test]
fn a_development_root_names_its_own_endpoint() {
    let _turn = turn();
    let root = Root::new();
    let refused = daemon(&root.0)
        .env("ARKDECK_ENDPOINT", r"\\.\pipe\arkdeck-agentd-not-this-root")
        .output()
        .unwrap();
    assert_eq!(refused.status.code(), Some(69), "{refused:?}");
    let stderr = String::from_utf8(refused.stderr).unwrap();
    assert!(
        stderr.starts_with("arkdeck-agentd: a development root's endpoint is named after the root: \\\\.\\pipe\\arkdeck-agentd-dev-"),
        "{stderr}"
    );
    assert!(!root.0.join("instance.json").exists());
}
