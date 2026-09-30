//! The Windows CLI's `runtime service uninstall` (TASK-XPA-002, CHG-2026-074
//! r12 decision 11), through the real `arkdeck` and a copy of the real daemon
//! signed with the host-trusted development signer
//! (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as `rust/scripts/check-readonly.py`
//! signs one), over isolated development roots. The CLI verifies the daemon's
//! image and signer before it sends a frame, and starts the daemon itself as
//! any command that needs the Runtime does (the client-started service):
//!
//! * `doctor` starts the daemon; `runtime service status` names it serving,
//!   `verify` proves it and `restart` replaces it;
//!   `runtime service uninstall` proves its identity on the pipe, reads its
//!   current Jobs (none), asks it to stop through its own stop event and
//!   awaits its single-instance guard: exit 0, the stopped pid is the
//!   instance document's, the drain complete, nothing registered or removed,
//!   the state root kept, and the pipe gone. Uninstalling again with no
//!   daemon running stops nothing and succeeds; the next `doctor` starts a
//!   new daemon over the kept state;
//! * over a root holding Jobs a restart left current (Swift's reconcile
//!   oracle, `rust/tests/fixtures/job-reconcile-analyzer`, `secondRestart`),
//!   `runtime service uninstall` is refused as `restart` is (exit 75, the
//!   current Jobs named) and the daemon keeps serving.
//!
//! Without the signer variable the test says so and checks nothing. Every
//! process here is started by this test or by the CLI it runs, and each
//! daemon is ended by a stop request, never killed unless an assertion
//! failed first; nothing installed is read or written.
#![cfg(windows)]

use arkdeck_hoststore::{JobRecord, JobStore};
use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};

static TURN: Mutex<()> = Mutex::new(());
fn turn() -> MutexGuard<'static, ()> {
    TURN.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A fresh development root below the temporary directory, in the spelling
/// the daemon names it by; on drop, a daemon still serving it is asked to
/// stop, and the root is removed.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winuninstall-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
    fn instance_pid(&self) -> Option<u32> {
        let bytes = std::fs::read(self.0.join("instance.json")).ok()?;
        let instance: Value = serde_json::from_slice(&bytes).ok()?;
        u32::try_from(instance["pid"].as_u64()?).ok()
    }
    /// Swift's second start of its reconcile oracle: the Job store with its
    /// rows admitted and persisted to their recorded versions, and the
    /// Artifacts they read.
    fn with_current_jobs(self) -> Self {
        let recorded = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/job-reconcile-analyzer");
        let state = self.0.join("jobs-state");
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let second = recorded.join("secondRestart");
        let index: Value =
            serde_json::from_slice(&std::fs::read(second.join("index.json")).unwrap()).unwrap();
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = second.join("jobs").join(id);
            let record =
                JobRecord::decode(&std::fs::read(directory.join("job-record.json")).unwrap())
                    .unwrap();
            store
                .admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap();
            for _ in 1..row["version"].as_i64().unwrap() {
                store
                    .persist(&record, row["updatedAtUTC"].as_str().unwrap())
                    .unwrap();
            }
            for file in std::fs::read_dir(&directory).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap();
                if name != "job-record.json" {
                    std::fs::copy(&file, state.join("jobs").join(id).join(name)).unwrap();
                }
            }
        }
        drop(store);
        let artifacts = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        for job in std::fs::read_dir(recorded.join("artifacts")).unwrap() {
            let job = job.unwrap().path();
            let owned = artifacts
                .create_private_child(job.file_name().unwrap().to_str().unwrap())
                .unwrap();
            for file in std::fs::read_dir(&job).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap().to_str().unwrap().to_owned();
                owned
                    .create_document(&name, &std::fs::read(&file).unwrap())
                    .unwrap();
                if name != "index.json" {
                    owned.seal_document(&name).unwrap();
                }
            }
        }
        self
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        if let Some(pid) = self.instance_pid()
            && let Ok(root) = StateRoot::development(&self.0)
            && let Ok(scope) = root.scope()
        {
            let _ = scope.request_stop(pid);
            drop(root);
            // Its guard is released once it has drained.
            if let Ok(guard) = arkdeck_platform::GuardObject::open(&scope) {
                let _ = guard.acquire(std::time::Duration::from_secs(30));
            }
        }
        let _ = std::fs::remove_dir_all(&self.0);
    }
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

/// A copy of the daemon signed with the development signer, and its pin.
fn signed_daemon(directory: &Path, thumbprint: &std::ffi::OsStr) -> (PathBuf, String) {
    std::fs::create_dir(directory).unwrap();
    let daemon = directory.join("arkdeck-agentd.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-agentd"), &daemon).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .arg("sign")
        .arg("-Thumbprint")
        .arg(thumbprint)
        .arg("-Path")
        .arg(&daemon)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(signing.status.success(), "{signing:?}");
    let pin: Value = serde_json::from_slice(&signing.stdout).unwrap();
    (daemon, pin["pin"].as_str().unwrap().to_owned())
}

/// The real CLI beside the daemon, over `root`, trusting `daemon` and its
/// signer `pin` as it trusts an installed daemon; it starts the daemon
/// itself when a command needs the Runtime.
fn cli(root: &Root, daemon: &Path, pin: &str, arguments: &[&str]) -> (Option<i32>, Value) {
    let output = cli_output(root, daemon, pin, arguments);
    let envelope = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|_| panic!("{arguments:?}: {output:?}"));
    (output.status.code(), envelope)
}

fn cli_output(root: &Root, daemon: &Path, pin: &str, arguments: &[&str]) -> std::process::Output {
    let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck.exe");
    let mut command = Command::new(&cli);
    for (key, _) in std::env::vars_os() {
        let upper = key.to_string_lossy().to_ascii_uppercase();
        if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
            command.env_remove(key);
        }
    }
    command
        .args(["--output", "json"])
        .args(arguments)
        .env("ARKDECK_DEVELOPMENT_STATE_ROOT", &root.0)
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
        })
}

fn thumbprint() -> Option<std::ffi::OsString> {
    let found = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty());
    if found.is_none() {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the daemon the CLI must verify \
             (rust/scripts/windows-dev-identity.ps1 create); nothing was checked"
        );
    }
    found
}

#[test]
fn uninstall_stops_the_client_started_daemon_and_keeps_its_state() {
    let Some(thumbprint) = thumbprint() else {
        return;
    };
    let _turn = turn();
    let root = Root::new();
    let (daemon, pin) = signed_daemon(&root.0.join("signed-bin"), &thumbprint);

    let (status, envelope) = cli(&root, &daemon, &pin, &["doctor"]);
    assert_eq!(status, Some(0), "{envelope}");
    let started = root.instance_pid().expect("doctor started the daemon");
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "status"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["daemonService"]["socketPresent"], true,
        "{envelope}"
    );
    assert_eq!(
        envelope["result"]["daemonService"]["instance"]["pid"], started,
        "{envelope}"
    );

    // `verify` proves the running daemon; `restart` replaces it.
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "verify"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["runtimeVerified"], true, "{envelope}");
    assert_eq!(envelope["result"]["runtime"]["pid"], started, "{envelope}");
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "restart"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["restart"]["stoppedPid"], started,
        "{envelope}"
    );
    let started = root.instance_pid().unwrap();
    assert_eq!(
        envelope["result"]["restart"]["startedPid"], started,
        "{envelope}"
    );

    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "uninstall"]);
    assert_eq!(status, Some(0), "{envelope}");
    let uninstall = &envelope["result"]["uninstall"];
    assert_eq!(
        uninstall["schemaVersion"], "arkdeck-windows-daemon-uninstall/v1",
        "{envelope}"
    );
    assert_eq!(uninstall["stoppedPid"], started, "{envelope}");
    assert_eq!(uninstall["stopRequest"], "stopEvent", "{envelope}");
    assert_eq!(uninstall["drain"], "complete", "{envelope}");
    assert_eq!(uninstall["stoppedInstance"]["pid"], started, "{envelope}");
    assert_eq!(uninstall["jobOwner"], true, "{envelope}");
    assert_eq!(uninstall["removedRegistration"], false, "{envelope}");
    assert_eq!(uninstall["removedDaemon"], false, "{envelope}");
    assert_eq!(
        uninstall["preservedStateDirectory"],
        root.0.to_str().unwrap(),
        "{envelope}"
    );
    assert_eq!(
        envelope["result"]["daemonService"]["socketPresent"], false,
        "{envelope}"
    );
    // The state is kept, and the image the CLI trusts is not touched.
    assert!(root.0.join("jobs-state").is_dir());
    assert!(daemon.is_file());

    // Nothing runs: nothing to stop, and it succeeds.
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "uninstall"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["uninstall"]["stoppedPid"],
        Value::Null,
        "{envelope}"
    );
    assert_eq!(
        envelope["result"]["uninstall"]["drain"],
        Value::Null,
        "{envelope}"
    );

    // The next command that needs the Runtime starts a new daemon over the
    // kept state; the test stops it the same way.
    let (status, envelope) = cli(&root, &daemon, &pin, &["doctor"]);
    assert_eq!(status, Some(0), "{envelope}");
    let again = root.instance_pid().unwrap();
    assert_ne!(again, started);
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "uninstall"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["uninstall"]["stoppedPid"], again);
}

#[test]
fn uninstall_is_refused_while_runtime_jobs_are_current() {
    let Some(thumbprint) = thumbprint() else {
        return;
    };
    let _turn = turn();
    let root = Root::new().with_current_jobs();
    let (daemon, pin) = signed_daemon(&root.0.join("signed-bin"), &thumbprint);

    let (status, envelope) = cli(&root, &daemon, &pin, &["doctor"]);
    assert_eq!(status, Some(0), "{envelope}");
    let started = root.instance_pid().expect("doctor started the daemon");

    // As `restart` answers it: a plain failure, exit 75, naming the Jobs.
    let refused = cli_output(&root, &daemon, &pin, &["runtime", "service", "uninstall"]);
    assert_eq!(refused.status.code(), Some(75), "{refused:?}");
    assert!(refused.stdout.is_empty(), "{refused:?}");
    let stderr = String::from_utf8(refused.stderr.clone()).unwrap();
    assert!(
        stderr.starts_with(
            "arkdeck runtime.service.uninstall: runtime service uninstall refused while Runtime \
             Jobs are active or unclosed: job-"
        ),
        "{stderr}"
    );
    // Refused before any stop: the same daemon still serves.
    let (status, envelope) = cli(&root, &daemon, &pin, &["runtime", "service", "status"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["daemonService"]["instance"]["pid"], started,
        "{envelope}"
    );
    assert_eq!(
        envelope["result"]["daemonService"]["socketPresent"], true,
        "{envelope}"
    );
}
