//! The Windows daemon's Target owners (TASK-XPA-004), as the real daemon
//! composes them over an isolated development root: GJ-1's Target hops up
//! to the point where a registered Windows HDC tuple is needed.
//!
//! * Over its pipe, with a plain pipe handle (no signer needed):
//!   `target.list`, `target.show` and `target.display-name.set|clear`
//!   answer from `targets-state` — the same `targets.json` bytes as macOS,
//!   under `.targets.lock` — and what they wrote is read back after a
//!   restart; `device.display-name.set` and `target.adopt` are refused
//!   before admission with no new dispatch, and nothing is observed; a
//!   Target directory that is not owner-only refuses the start.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one): the same hops as the CLI
//!   verifies the daemon's image and signer and prints them. Without that
//!   variable this test says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, no HDC is configured, and no device
//! or `hdc` is involved. Each daemon is stopped by its own stop request, or
//! ended by this test if it outlives a failed assertion.
#![cfg(windows)]

use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// One test at a time: a child spawned while another test's daemon starts
/// would inherit that daemon's inheritable handles.
static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

const DEADLINE: Duration = Duration::from_secs(60);
/// The Swift adoption oracle's device and Target.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const TARGET: &str = "TGT-3ba3f5f43b92";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/target-adoption")
        .join(name)
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-wintargets-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn targets_state(&self) -> PathBuf {
        self.0.join("targets-state")
    }
    /// The Target store the oracle's adoption left: its `targets.json`, in a
    /// private `targets-state` the store itself creates.
    fn with_oracle_target(self) -> Self {
        HostDirectory::open_or_create_private(&self.targets_state()).unwrap();
        std::fs::copy(
            fixture("targets-state/targets.json"),
            self.targets_state().join("targets.json"),
        )
        .unwrap();
        self
    }
    fn targets(&self) -> Vec<u8> {
        std::fs::read(self.targets_state().join("targets.json")).unwrap()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn daemon(executable: &Path, root: &Path) -> Command {
    let mut command = Command::new(executable);
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
    fn start(executable: &Path, root: &Path) -> Self {
        let mut child = daemon(executable, root).spawn().unwrap();
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
                Err(error) => panic!(
                    "no line starting {prefix:?} ({error}); stdout so far {:?}",
                    self.seen
                ),
            }
        }
    }

    /// Serving: its pipe, from the line it announces it with.
    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    /// Asks it to stop, by its root's scope and its pid, and waits for its end.
    fn stop(&mut self, root: &Path) {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(self.pid()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let status = wait(self.child.take().unwrap());
        assert!(status.success(), "{status:?}");
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

/// One request on a fresh plain handle of the daemon's pipe.
fn request(pipe: &str, method: &str, params: Value) -> Value {
    let mut connection = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": method,
        "method": method,
        "params": params,
    }))
    .unwrap();
    frame.push(b'\n');
    connection.write_all(&frame).unwrap();
    let mut reply = Vec::new();
    let mut byte = [0u8; 1];
    while byte[0] != b'\n' {
        assert_eq!(
            connection.read(&mut byte).unwrap(),
            1,
            "the reply ended early"
        );
        reply.push(byte[0]);
    }
    serde_json::from_slice(&reply).unwrap()
}

fn answered(pipe: &str, method: &str, params: Value) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], true, "{method}: {reply}");
    reply["result"].clone()
}

/// A refusal with the zero-dispatch proof in its details.
fn refused(pipe: &str, method: &str, params: Value, code: &str, phase: &str) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], false, "{method}: {reply}");
    assert_eq!(reply["error"]["code"], code, "{method}: {reply}");
    assert_eq!(
        reply["error"]["details"]["phase"], phase,
        "{method}: {reply}"
    );
    assert_eq!(
        reply["error"]["details"]["newDispatchCount"], 0,
        "{method}: {reply}"
    );
    reply
}

fn adoption() -> Value {
    json!({"candidate": KEY, "observationId": "obs-00000000-0000-4000-8000-000000000000",
        "observationGeneration": "1"})
}

#[test]
fn the_target_owners_answer_over_the_pipe_and_survive_a_restart() {
    let _turn = turn();
    let root = Root::new().with_oracle_target();
    let before = root.targets();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first
            .seen
            .contains(&"arkdeck-agentd owners: targets, artifacts, workspaceProjects".to_owned()),
        "{:?}",
        first.seen
    );
    let listed = answered(&pipe, "target.list", json!({}));
    assert_eq!(
        listed,
        json!([{"targetId": TARGET, "bindingRevision": 1, "toolVersion": "3.2.0d",
            "adoptedAtUtc": "2026-09-14T00:00:00Z", "displayName": null,
            "displayNameGeneration": "1"}])
    );
    let shown = answered(&pipe, "target.show", json!({"targetId": TARGET}));
    assert_eq!(
        shown["stablePhysicalIdentitySha256"],
        arkdeck_contract::sha256_hex(KEY.as_bytes()),
        "{shown}"
    );
    assert_eq!(shown["connectKey"], KEY);
    // The Target's availability: its durable binding, no presence observed.
    let availability = answered(&pipe, "target.availability", json!({"targetId": TARGET}));
    assert_eq!(availability["targetId"], TARGET, "{availability}");
    assert_eq!(availability["binding"]["state"], "ready", "{availability}");
    assert_eq!(availability["binding"]["bindingRevision"], 1);
    assert_eq!(availability["presence"]["state"], "unresolved");
    let set = answered(
        &pipe,
        "target.display-name.set",
        json!({"targetId": TARGET, "expectedGeneration": "1", "name": "Bench e\u{301}"}),
    );
    assert_eq!(set["generation"], "2", "{set}");
    // A stale generation is refused and changes nothing.
    let stale = request(
        &pipe,
        "target.display-name.clear",
        json!({"targetId": TARGET, "expectedGeneration": "1"}),
    );
    assert_eq!(stale["error"]["code"], "resourceConflict", "{stale}");

    // No HDC is registered: nothing is observed, no candidate is named, and
    // the adoption is refused before admission with no new dispatch.
    let observed = request(&pipe, "device.observations", json!({}));
    assert_eq!(observed["error"]["code"], "rejected", "{observed}");
    assert_eq!(observed["error"]["message"], "hdc.notConfigured");
    refused(
        &pipe,
        "device.display-name.set",
        json!({"candidate": KEY, "observationId": "obs-00000000-0000-4000-8000-000000000000",
            "observationGeneration": "1", "name": "Bench"}),
        "resourceConflict",
        "candidateDisplayNameOwner",
    );
    let adopt = refused(
        &pipe,
        "target.adopt",
        adoption(),
        "operationUnavailable",
        "preAdmission",
    );
    assert_eq!(
        adopt["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0})
    );
    refused(
        &pipe,
        "target.adopt",
        json!({}),
        "invalidInput",
        "preAdmission",
    );
    assert_eq!(root.targets(), before, "no Target was adopted or rewritten");
    first.stop(&root.0);

    // Restarted over the same root: the name is read back, then cleared.
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    let listed = answered(&pipe, "target.list", json!({}));
    assert_eq!(listed[0]["displayName"], "Bench e\u{301}", "{listed}");
    assert_eq!(listed[0]["displayNameGeneration"], "2");
    let cleared = answered(
        &pipe,
        "target.display-name.clear",
        json!({"targetId": TARGET, "expectedGeneration": "2"}),
    );
    assert_eq!(cleared["generation"], "3", "{cleared}");
    assert!(cleared["name"].is_null());
    second.stop(&root.0);

    let mut third = Daemon::start(executable, &root.0);
    let pipe = third.serving();
    let shown = answered(&pipe, "target.show", json!({"targetId": TARGET}));
    assert!(shown["displayName"].is_null(), "{shown}");
    assert_eq!(shown["displayNameGeneration"], "3");
    // `doctor` reads the Target store and counts the adopted Target.
    let doctor = answered(&pipe, "doctor", json!({}));
    assert_eq!(
        doctor["checks"]["target"],
        json!({"adoptedTargetCount": 1, "bootstrapConfigured": false, "configured": true}),
        "{doctor}"
    );
    third.stop(&root.0);
    assert_eq!(
        root.targets(),
        before,
        "names never touch the binding bytes"
    );
}

#[test]
fn a_target_directory_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the store refuses and never rewrites.
    std::fs::create_dir(root.targets_state()).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the Target store") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(
        !String::from_utf8(output.stdout)
            .unwrap()
            .contains("listening on"),
        "nothing served"
    );
    assert!(!root.targets_state().join("targets.json").exists());
}

/// PowerShell 7, which signs the development daemon.
fn pwsh() -> PathBuf {
    if let Some(found) = std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|directory| directory.join("pwsh.exe"))
            .find(|candidate| candidate.exists())
    }) {
        return found;
    }
    let alias = PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
        .join("Microsoft/WindowsApps/pwsh.exe");
    assert!(
        alias.exists(),
        "PowerShell 7 is required to sign the development daemon"
    );
    alias
}

/// The real CLI beside the daemon, against `pipe`, verifying `daemon` and
/// its signer `pin` as it verifies an installed daemon.
fn cli(daemon: &Path, pin: &str, pipe: &str, arguments: &[&str]) -> (Option<i32>, Value) {
    let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck.exe");
    let mut command = Command::new(&cli);
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("ARKDECK_")
        {
            command.env_remove(key);
        }
    }
    let output = command
        .args(arguments)
        .args(["--output", "json"])
        .env("ARKDECK_ENDPOINT", pipe)
        .env("ARKDECK_DAEMON_PATH", daemon)
        .env("ARKDECK_DAEMON_SIGNER_SHA256", pin)
        .stdin(Stdio::null())
        .output()
        .unwrap_or_else(|error| {
            panic!(
                "the arkdeck CLI beside the daemon ({}): {error}; run the workspace tests, or \
                 `cargo build -p arkdeck-cli` before testing this crate alone",
                cli.display()
            )
        });
    let envelope = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
    (output.status.code(), envelope)
}

#[test]
fn gj1_target_hops_run_through_the_cli_against_a_dev_signed_daemon() {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted development \
             signer can sign the daemon the CLI must verify (rust/scripts/windows-dev-identity.ps1 \
             create); nothing was checked"
        );
        return;
    };
    let _turn = turn();
    let root = Root::new().with_oracle_target();
    let before = root.targets();
    let signed = root.0.join("signed-bin");
    std::fs::create_dir(&signed).unwrap();
    let daemon = signed.join("arkdeck-agentd.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-agentd"), &daemon).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(&thumbprint)
        .arg("-Path")
        .arg(&daemon)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(signing.status.success(), "{signing:?}");
    let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
    let pin = pin["pin"].as_str().unwrap().to_owned();

    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["target", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"][0]["targetId"], TARGET, "{envelope}");
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "target",
            "display-name",
            "set",
            "--target",
            TARGET,
            "--expected-generation",
            "1",
            "--name",
            "Bench",
        ],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["generation"], "2", "{envelope}");
    // Adoption is refused before admission: the CLI reports the refusal,
    // not an unknown outcome, and nothing was dispatched or written.
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "target",
            "adopt",
            "--candidate",
            KEY,
            "--observation",
            "obs-00000000-0000-4000-8000-000000000000",
            "--observation-generation",
            "1",
        ],
    );
    assert_eq!(status, Some(69), "{envelope}");
    assert_eq!(
        envelope["error"]["code"], "operationUnavailable",
        "{envelope}"
    );
    assert_eq!(root.targets(), before);
    first.stop(&root.0);

    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["target", "show", "--target", TARGET],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["displayName"], "Bench", "{envelope}");
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "target",
            "display-name",
            "clear",
            "--target",
            TARGET,
            "--expected-generation",
            "2",
        ],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["generation"], "3", "{envelope}");
    second.stop(&root.0);

    let mut third = Daemon::start(&daemon, &root.0);
    let pipe = third.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["target", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert!(envelope["result"][0]["displayName"].is_null(), "{envelope}");
    assert_eq!(envelope["result"][0]["displayNameGeneration"], "3");
    third.stop(&root.0);
    assert_eq!(root.targets(), before);
}
