//! The bundled OpenHarmony code-sign helper on the Windows daemon
//! (TASK-XPA-009), as the real daemon composes it: a copy of the daemon
//! with the helper resource beside it in the layout the Windows packages
//! ship (`ArkDeckKit_ArkDeckWorkflows.bundle\OpenHarmonyNativeCodeSign\
//! arkdeck-code-sign-enable`, the checked-in resource), over an isolated
//! development root.
//!
//! * The checked-in helper verifies as Swift verifies the bundled one and is
//!   composed: the census names `codeSignHelper` in its macOS position.
//!   `deploy.native-library.app-owned@1` still answers
//!   `provider_not_registered`: no Windows HDC tuple is registered, and the
//!   helper stands ready behind that gate.
//! * A helper that does not verify is reported ("native deployment stays
//!   unavailable: …"), is not composed, and the daemon serves; without a
//!   helper beside it nothing is reported and nothing is composed.
//! * A helper the caller names (`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`) is
//!   refused before anything starts: on macOS only a development HDC's
//!   admission names one, and no Windows HDC can be registered yet.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root; nothing installed is read or written, and no device
//! or `hdc` is involved.
#![cfg(windows)]

use arkdeck_platform::StateRoot;
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
const BUNDLE: [&str; 3] = [
    "ArkDeckKit_ArkDeckWorkflows.bundle",
    "OpenHarmonyNativeCodeSign",
    "arkdeck-code-sign-enable",
];
const CENSUS: &str = "arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, \
     artifacts, imports, storage, history, workspaceProjects, planning, agentExecutions, humanActions, \
     traceCache";

/// The checked-in helper resource, the one both packages ship.
fn resource() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign")
        .join("arkdeck-code-sign-enable")
}

/// A fresh directory below the temporary directory, removed afterwards.
struct Scratch(PathBuf);
impl Scratch {
    fn new(prefix: &str) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("{prefix}-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        // The canonical spelling without `\\?\`, as the daemon names its root.
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A copy of the daemon in a directory of its own, with `helper`'s bytes
/// beside it in the packages' layout when there are any.
fn installed(helper: Option<&[u8]>) -> (Scratch, PathBuf) {
    let directory = Scratch::new("ad-winhelper-bin");
    let executable = directory.0.join("arkdeck-agentd.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-agentd"), &executable).unwrap();
    if let Some(bytes) = helper {
        let path = BUNDLE
            .iter()
            .fold(directory.0.clone(), |path, component| path.join(component));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
    (directory, executable)
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
                    let mut stderr = String::new();
                    if let Some(child) = self.child.as_mut()
                        && child.try_wait().ok().flatten().is_some()
                        && let Some(pipe) = child.stderr.as_mut()
                    {
                        let _ = pipe.read_to_string(&mut stderr);
                    }
                    panic!(
                        "no line starting {prefix:?} ({error}); stdout so far {:?}, stderr {stderr:?}",
                        self.seen
                    )
                }
            }
        }
    }

    /// Every line up to the listening one, and the pipe it names.
    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    fn stop(&mut self, root: &Path) {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope
            .request_stop(self.child.as_ref().unwrap().id())
            .unwrap();
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

/// `deploy.native-library.app-owned@1` as `operation.list` reports it.
fn native_deployment(pipe: &str) -> Value {
    let list = request(pipe, "operation.list", json!({}));
    assert_eq!(list["ok"], true, "{list}");
    list["result"]
        .as_array()
        .unwrap()
        .iter()
        .find(|operation| operation["reference"] == "deploy.native-library.app-owned@1")
        .cloned()
        .expect("the native deployment is listed")
}

/// Starts the daemon at `executable` over a fresh root and returns the
/// lines before it listened, its census and the native deployment's
/// availability.
fn started(executable: &Path) -> (Vec<String>, String, Value) {
    let root = Scratch::new("ad-winhelper");
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    let census = daemon
        .seen
        .iter()
        .find(|line| line.starts_with("arkdeck-agentd owners: "))
        .cloned()
        .expect("the census is reported");
    let deployment = native_deployment(&pipe);
    daemon.stop(&root.0);
    (daemon.seen.clone(), census, deployment)
}

#[test]
fn the_bundled_helper_is_verified_composed_and_waits_behind_the_hdc_gate() {
    let _turn = turn();
    let bytes = std::fs::read(resource()).unwrap();
    let (_directory, executable) = installed(Some(&bytes));
    let (seen, census, deployment) = started(&executable);
    assert_eq!(census, format!("{CENSUS}, codeSignHelper"), "{seen:?}");
    assert!(
        !seen
            .iter()
            .any(|line| line.starts_with("native deployment")),
        "{seen:?}"
    );
    assert_eq!(deployment["availability"], "unavailable", "{deployment}");
    assert_eq!(
        deployment["reasonCodes"],
        json!(["provider_not_registered"]),
        "{deployment}"
    );
}

#[test]
fn a_helper_that_does_not_verify_is_reported_and_the_daemon_serves_without_it() {
    let _turn = turn();
    for (name, bytes) in [
        ("not an ELF", b"not an ELF".to_vec()),
        (
            "a truncated helper",
            std::fs::read(resource()).unwrap()[..4096].to_vec(),
        ),
    ] {
        let (_directory, executable) = installed(Some(&bytes));
        let (seen, census, deployment) = started(&executable);
        assert!(
            seen.iter()
                .any(|line| line.starts_with("native deployment stays unavailable: ")),
            "{name}: {seen:?}"
        );
        assert_eq!(census, CENSUS, "{name}");
        assert_eq!(
            deployment["reasonCodes"],
            json!(["provider_not_registered"]),
            "{name}: {deployment}"
        );
    }
    // Without a helper beside it nothing is reported or composed.
    let (_directory, executable) = installed(None);
    let (seen, census, _) = started(&executable);
    assert!(
        !seen
            .iter()
            .any(|line| line.starts_with("native deployment")),
        "{seen:?}"
    );
    assert_eq!(census, CENSUS);
}

#[test]
fn a_helper_the_caller_names_is_refused_before_anything_starts() {
    let _turn = turn();
    let (_directory, executable) = installed(None);
    let root = Scratch::new("ad-winhelper");
    let output = daemon(&executable, &root.0)
        .env("ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER", resource())
        .output()
        .unwrap();
    assert!(!output.status.success(), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER")
            && stderr.contains("nothing was started"),
        "{stderr}"
    );
    // Nothing of the root was composed.
    assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 0);
    // Without a development root it is refused too, as the macOS standalone
    // and production daemons refuse it. Measured with a private endpoint,
    // which owns no state, so even a regression reads nothing installed.
    let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
    let output = daemon(&executable, &root.0)
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env(
            "ARKDECK_ENDPOINT",
            format!(r"\\.\pipe\arkdeck-helper-test-{nonce:016x}"),
        )
        .env("ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER", resource())
        .output()
        .unwrap();
    assert!(!output.status.success(), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains(
            "a development code-sign helper is named only for an isolated development root"
        ),
        "{stderr}"
    );
}
