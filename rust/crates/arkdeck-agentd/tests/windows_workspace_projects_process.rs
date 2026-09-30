//! The Windows daemon's workspace project owner (TASK-XPA-015), as the real
//! daemon composes it over an isolated development root.
//!
//! * Over its pipe, with a plain pipe handle (no signer needed):
//!   `workspace.project.register|list|show` and `workspace.preset.list|show`
//!   answer from `workspace-projects` (`projects.json` under
//!   `.projects.lock`), a symbol preset registers, and what they wrote is
//!   read back after a restart; a project or preset mutation is refused with
//!   no new dispatch, because the Job owner's census of the workspace Jobs
//!   that name one is not on Windows yet, so nothing proves that none does; a store directory that is not owner-only, or a
//!   document the owner cannot read, refuses the start.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one): the same hops as the CLI
//!   verifies the daemon's image and signer and prints them. Without that
//!   variable this test says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, and no toolchain, device or `hdc`
//! is involved. Each daemon is stopped by its own stop request, or ended by
//! this test if it outlives a failed assertion.
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
const SOURCE_MAP: &str = "entry/build/sourceMaps.map";

/// A fresh development root named as the disk names it (a workspace root
/// must be that spelling), with two project directories, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let temporary = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let temporary = temporary.to_str().unwrap();
        let temporary = temporary.strip_prefix(r"\\?\").unwrap_or(temporary);
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = Path::new(temporary).join(format!("ad-winprojects-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        for name in ["first", "second"] {
            std::fs::create_dir_all(path.join("sources").join(name)).unwrap();
        }
        Self(path)
    }
    fn project(&self, name: &str) -> String {
        self.0
            .join("sources")
            .join(name)
            .to_str()
            .unwrap()
            .to_owned()
    }
    fn store(&self) -> PathBuf {
        self.0.join("workspace-projects")
    }
    fn document(&self) -> Vec<u8> {
        std::fs::read(self.store().join("projects.json")).unwrap()
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

/// A refusal of the workspace owner, with the zero-dispatch proof: under
/// the preset owner's phase for a preset method, as Swift answers it.
fn refused(pipe: &str, method: &str, params: Value, code: &str) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], false, "{method}: {reply}");
    assert_eq!(reply["error"]["code"], code, "{method}: {reply}");
    let phase = if method.starts_with("workspace.preset.") {
        "workspacePresetOwner"
    } else {
        "workspaceProjectOwner"
    };
    assert_eq!(
        reply["error"]["details"],
        json!({"phase": phase, "newDispatchCount": 0}),
        "{method}: {reply}"
    );
    reply
}

fn registration(request: &str, root: &str) -> Value {
    json!({"registrationRequestId": request, "kind": "openharmony", "root": root})
}

fn symbol_preset(project: &Value) -> Value {
    json!({"registrationRequestId": "preset-one", "projectRef": project, "kind": "symbol",
        "templateRef": "openharmony.arkts-symbol@1", "timeoutSeconds": "600",
        "relativeSourceMap": SOURCE_MAP})
}

#[test]
fn projects_register_over_the_pipe_and_survive_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, targets, artifacts, workspaceProjects, planning, traceCache"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );
    assert_eq!(
        answered(&pipe, "workspace.project.list", json!({})),
        json!({"schemaVersion": "arkdeck.workspace-project-list/1", "projects": []})
    );
    let project = answered(
        &pipe,
        "workspace.project.register",
        registration("request-first", &root.project("first")),
    );
    assert_eq!(
        project["projectRef"],
        format!(
            "project-{}",
            &arkdeck_contract::sha256_hex(b"request-first")[..24]
        )
    );
    assert_eq!(project["configurationStatus"], "runtimeRestartRequired");
    assert_eq!(project["reasonCode"], "workspace_runtime_restart_required");
    assert!(!project.to_string().contains(&root.project("first")));
    let reference = project["projectRef"].clone();
    // A replay answers the same receipt and writes nothing.
    let written = root.document();
    assert_eq!(
        answered(
            &pipe,
            "workspace.project.register",
            registration("request-first", &root.project("first")),
        ),
        project
    );
    assert_eq!(root.document(), written);
    let second = answered(
        &pipe,
        "workspace.project.register",
        registration("request-second", &root.project("second")),
    );
    // The owner's own refusals, before anything is written.
    for (params, code) in [
        (
            registration("request-third", &root.project("first")),
            "resourceConflict",
        ),
        (
            registration("request-first", &root.project("second")),
            "idempotencyConflict",
        ),
        (
            registration("request-third", &root.project("first").replace('\\', "/")),
            "invalidInput",
        ),
        (
            registration("request-third", &root.project("FIRST")),
            "invalidInput",
        ),
        (
            registration("request-third", "/private/tmp/first"),
            "invalidInput",
        ),
    ] {
        refused(&pipe, "workspace.project.register", params, code);
    }
    assert_eq!(
        answered(
            &pipe,
            "workspace.project.show",
            json!({"projectRef": reference})
        ),
        project
    );
    let listed = answered(&pipe, "workspace.project.list", json!({}));
    assert_eq!(listed["projects"].as_array().unwrap().len(), 2, "{listed}");

    // Presets: read, and a symbol preset registered; it pins nothing.
    assert_eq!(
        answered(
            &pipe,
            "workspace.preset.list",
            json!({"projectRef": reference})
        )["presets"],
        json!([])
    );
    let preset = answered(
        &pipe,
        "workspace.preset.register",
        symbol_preset(&reference),
    );
    assert_eq!(preset["configurationStatus"], "runtimeRestartRequired");
    assert_eq!(preset["constraints"]["relativeSourceMap"], SOURCE_MAP);
    let absent = request(
        &pipe,
        "workspace.preset.show",
        json!({"projectRef": reference, "presetRef": "preset-absent"}),
    );
    assert_eq!(
        absent["error"]["code"], "workspaceReferenceNotFound",
        "{absent}"
    );

    // Nothing proves that no workspace Job names the project or the preset
    // (the Job owner's workspace census is still macOS-only): every mutation
    // is refused and nothing is written.
    let written = root.document();
    for (method, params) in [
        (
            "workspace.project.update",
            json!({"projectRef": second["projectRef"], "expectedGeneration": "1",
                "kind": "arkdeck", "root": root.project("second")}),
        ),
        (
            "workspace.project.remove",
            json!({"projectRef": second["projectRef"], "expectedGeneration": "1"}),
        ),
        (
            "workspace.preset.remove",
            json!({"mutationRequestId": "preset-remove", "projectRef": reference,
                "presetRef": preset["presetRef"], "expectedGeneration": "1"}),
        ),
    ] {
        let reply = refused(&pipe, method, params, "recordUnreadable");
        assert_eq!(
            reply["error"]["message"], "workspace Job references cannot be verified",
            "{reply}"
        );
    }
    assert_eq!(root.document(), written);
    first.stop(&root.0);

    // Restarted over the same root: both projects and the preset are read
    // back, still awaiting a composition this daemon does not have.
    let mut restarted = Daemon::start(executable, &root.0);
    let pipe = restarted.serving();
    assert_eq!(answered(&pipe, "workspace.project.list", json!({})), listed);
    assert_eq!(
        answered(
            &pipe,
            "workspace.preset.show",
            json!({"projectRef": reference, "presetRef": preset["presetRef"]})
        ),
        preset
    );
    restarted.stop(&root.0);
    assert_eq!(root.document(), written);
}

#[test]
fn a_store_that_is_not_owner_only_or_unreadable_refuses_the_start() {
    let _turn = turn();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    let refuses = |root: &Root| {
        let output = daemon(executable, &root.0).output().unwrap();
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(
            stderr.contains("the workspace project store")
                && stderr.contains("nothing was started"),
            "{stderr}"
        );
        assert!(
            !String::from_utf8(output.stdout)
                .unwrap()
                .contains("listening on"),
            "nothing served"
        );
    };
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the store refuses and never rewrites.
    let root = Root::new();
    std::fs::create_dir(root.store()).unwrap();
    refuses(&root);
    assert!(!root.store().join("projects.json").exists());

    // A document cut short: not repaired, not rewritten.
    let root = Root::new();
    HostDirectory::open_or_create_private(&root.store()).unwrap();
    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    answered(
        &pipe,
        "workspace.project.register",
        registration("request-first", &root.project("first")),
    );
    first.stop(&root.0);
    let whole = root.document();
    let cut = &whole[..whole.len() / 2];
    // Rewritten in place, so the file keeps its owner-only descriptor.
    std::fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(root.store().join("projects.json"))
        .unwrap()
        .write_all(cut)
        .unwrap();
    refuses(&root);
    assert_eq!(root.document(), cut);
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
fn workspace_project_hops_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new();
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
    let first_root = root.project("first");

    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    let register = [
        "workspace",
        "project",
        "register",
        "--registration-request-id",
        "request-first",
        "--kind",
        "openharmony",
        "--root",
        &first_root,
    ];
    let (status, envelope) = cli(&daemon, &pin, &pipe, &register);
    assert_eq!(status, Some(0), "{envelope}");
    let project = envelope["result"].clone();
    let reference = project["projectRef"].as_str().unwrap().to_owned();
    assert_eq!(
        project["configurationStatus"], "runtimeRestartRequired",
        "{envelope}"
    );
    // The replay is the same receipt.
    let (status, envelope) = cli(&daemon, &pin, &pipe, &register);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"], project);
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["workspace", "project", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["projects"],
        json!([project]),
        "{envelope}"
    );
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["workspace", "preset", "list", "--project", &reference],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["presets"], json!([]), "{envelope}");
    // A mutation is refused before anything is written: the CLI reports the
    // refusal, not an unknown outcome.
    let written = root.document();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "workspace",
            "project",
            "remove",
            "--project",
            &reference,
            "--expected-generation",
            "1",
        ],
    );
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(envelope["error"]["code"], "recordUnreadable", "{envelope}");
    assert_eq!(root.document(), written);
    first.stop(&root.0);

    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["workspace", "project", "show", "--project", &reference],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"], project);
    second.stop(&root.0);
    assert_eq!(root.document(), written);
}
