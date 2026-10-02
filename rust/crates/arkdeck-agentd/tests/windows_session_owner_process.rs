//! The Windows daemon's Session owner (TASK-XPA-005/014), as the real
//! daemon composes it over an isolated development root: its Session
//! storage owner in `session-state`, its default Sessions root `sessions`
//! holding the recorded Swift `observe.device@1` Sessions and their catalog
//! (`rust/tests/fixtures/observe-device/sessions`), and the Artifact usage
//! owner over `artifacts`:
//!
//! * over its pipe, with a plain pipe handle (no signer needed):
//!   `runtime.storage.status` pairs the Session domain with the Artifact
//!   domain; `session.list` a page at a time, `show` and `pin` answer from
//!   Swift's catalog; `session.export.preview` and `apply` export a Session's
//!   Manifest into a directory the export creates; a policy the Sessions exceed makes
//!   `session.cleanup.preview` and `apply` reclaim the unpinned Session and
//!   keep the pinned one. After a restart the catalog reads back, the same
//!   cleanup tuple answers the same receipt and nothing is removed again. A
//!   `sessions` directory that is not owner-only refuses the start;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `runtime storage status`, `session list`, `show`, `export preview` and
//!   `apply`; then `session pin`, `runtime storage policy`, `session cleanup
//!   preview` and `apply` reclaim the unpinned Session as over the pipe, and
//!   `session unpin` releases the kept one; `runtime storage root` moves the
//!   Sessions root inside the development root and back to its default. The
//!   measured leaves are Windows
//!   `implemented` in the coverage manifest the CLI renders
//!   (`WINDOWS_MEASURED_LEAVES`). Without that variable this test says so and
//!   checks nothing.
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

/// The recorded Swift Sessions this test serves: `observe.device@1`'s.
fn recorded_sessions() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/observe-device/sessions")
}
const OBSERVED: &str = "session-job-0f77f8c52864d676372962eccb17389c";
const FAILED: &str = "session-job-efd52ab9c633074171a19ddd916fffd9";

/// A fresh development root in the plain spelling the Session owner
/// compares, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winsessions-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn sessions(&self) -> PathBuf {
        self.0.join("sessions")
    }
    /// The recorded Swift Sessions and their catalog in the root's default
    /// Sessions root, created owner-only: every file written below the
    /// private `sessions` inherits its owner-only DACL.
    fn with_recorded_sessions(self) -> Self {
        fn copy(from: &Path, to: &Path) {
            for entry in std::fs::read_dir(from).unwrap() {
                let entry = entry.unwrap();
                let target = to.join(entry.file_name());
                if entry.file_type().unwrap().is_dir() {
                    std::fs::create_dir(&target).unwrap();
                    copy(&entry.path(), &target);
                } else {
                    std::fs::copy(entry.path(), &target).unwrap();
                }
            }
        }
        HostDirectory::open_or_create_private(&self.sessions()).unwrap();
        copy(&recorded_sessions(), &self.sessions());
        self
    }
    fn session(&self, id: &str) -> PathBuf {
        self.sessions().join("2026").join("09").join(id)
    }
    fn exports(&self) -> PathBuf {
        let path = self.0.join("exports");
        let _ = std::fs::create_dir(&path);
        path
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

/// One request's result, schema-checked; a refusal fails the test.
fn answered(pipe: &str, method: &str, params: Value) -> Value {
    let reply = request(pipe, method, params.clone());
    assert_eq!(reply["ok"], true, "{method} {params}: {reply}");
    arkdeck_contract::validate_method_value(method, "result", &reply["result"])
        .unwrap_or_else(|error| panic!("{method}: {error}: {reply}"));
    reply["result"].clone()
}

/// The listed Session identities, a page of one at a time.
fn listed(pipe: &str) -> Vec<String> {
    let mut ids = Vec::new();
    let mut cursor = Value::Null;
    loop {
        let mut params = json!({"pageSize": 1});
        if !cursor.is_null() {
            params["cursor"] = cursor.clone();
        }
        let page = answered(pipe, "session.list", params);
        for item in page["items"].as_array().unwrap() {
            ids.push(item["sessionId"].as_str().unwrap().to_owned());
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            return ids;
        }
    }
}

#[test]
fn recorded_sessions_are_served_exported_and_cleaned_up_across_a_restart() {
    let _turn = turn();
    let root = Root::new().with_recorded_sessions();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    assert!(
        daemon.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, history, workspaceProjects, bootstrap, planning, agentExecutions, humanActions, traceCache, flashHostFacts, deviceAccess, loaderBinding"
                .to_owned()
        ),
        "{:?}",
        daemon.seen
    );

    // The storage status pairs the Session domain with the Artifact domain.
    let status = answered(&pipe, "runtime.storage.status", json!({}));
    assert_eq!(status["schemaVersion"], "arkdeck.runtime-storage/1");
    assert_eq!(
        status["sessionDomain"]["rootPath"],
        root.sessions().to_str().unwrap()
    );
    assert_eq!(status["sessionDomain"]["usage"]["sessionCount"], "2");
    assert_eq!(status["sessionDomain"]["catalogGeneration"], "2");
    assert_eq!(
        status["artifactDomain"]["schemaVersion"],
        "arkdeck.artifact-storage-status/1"
    );
    // Swift's catalog: both recorded Sessions, a page at a time.
    let mut ids = listed(&pipe);
    ids.sort();
    assert_eq!(ids, [OBSERVED, FAILED]);
    let shown = answered(&pipe, "session.show", json!({"sessionId": OBSERVED}));
    assert_eq!(shown["pinned"], false);
    let pinned = answered(
        &pipe,
        "session.pin",
        json!({"sessionId": OBSERVED, "expectedGeneration": shown["generation"]}),
    );
    assert_eq!(pinned["pinned"], true);

    // An export of the observed Session: its Manifest and Journal, the
    // Session's own bytes, in a directory it creates.
    let destination = root.exports().join("observed");
    let preview = answered(
        &pipe,
        "session.export.preview",
        json!({"sessionId": OBSERVED, "destinationPath": destination.to_str().unwrap(),
            "allowSensitive": false}),
    );
    assert_eq!(
        preview["destination"]["path"],
        destination.to_str().unwrap()
    );
    let tuple =
        json!({"previewId": preview["previewId"], "previewDigest": preview["previewDigest"]});
    let exported = answered(&pipe, "session.export.apply", tuple.clone());
    assert_eq!(exported["exportedPath"], destination.to_str().unwrap());
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(destination.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["sessionId"], OBSERVED);
    assert_eq!(manifest["platformProfile"], "PLATFORM-MACOS@0.2.0");

    // A policy the two Sessions exceed: the cleanup reclaims the unpinned
    // one and keeps the pinned one.
    let policy = answered(
        &pipe,
        "runtime.storage.policy",
        json!({"expectedGeneration": "1", "totalQuotaBytes": "2", "safetyMarginBytes": "1",
            "retentionDays": "1"}),
    );
    assert_eq!(policy["sessionDomain"]["generation"], "2");
    let cleanup = answered(&pipe, "session.cleanup.preview", json!({}));
    let reclaimed: Vec<&str> = cleanup["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|session| session["disposition"] == "reclaim")
        .map(|session| session["sessionId"].as_str().unwrap())
        .collect();
    assert_eq!(reclaimed, [FAILED], "{cleanup}");
    let tuple =
        json!({"previewId": cleanup["previewId"], "previewDigest": cleanup["previewDigest"]});
    let applied = answered(&pipe, "session.cleanup.apply", tuple.clone());
    assert_eq!(applied["removedSessionIds"], json!([FAILED]));
    assert!(!root.session(FAILED).exists());
    assert!(root.session(OBSERVED).join("manifest.json").is_file());
    daemon.stop(&root.0);

    // After a restart: the same catalog, the same receipt for the same
    // tuple, and nothing removed again.
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    assert_eq!(listed(&pipe), [OBSERVED]);
    assert_eq!(answered(&pipe, "session.cleanup.apply", tuple), applied);
    let shown = answered(&pipe, "session.show", json!({"sessionId": OBSERVED}));
    assert_eq!(shown["pinned"], true);
    daemon.stop(&root.0);
    assert!(root.session(OBSERVED).join("manifest.json").is_file());
}

#[test]
fn a_sessions_directory_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the owner refuses and never rewrites.
    std::fs::create_dir(root.sessions()).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the Session store") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(
        !String::from_utf8(output.stdout)
            .unwrap()
            .contains("listening on"),
        "nothing served"
    );
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
fn gj1_session_commands_run_through_the_cli_against_a_dev_signed_daemon() {
    let Some(thumbprint) =
        std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT").filter(|value| !value.is_empty())
    else {
        eprintln!(
            "SKIPPED: ARKDECK_DEV_SIGNER_THUMBPRINT is not set (or empty), so no host-trusted \
             development signer can sign the daemon the CLI must verify \
             (rust/scripts/windows-dev-identity.ps1 create); nothing was checked"
        );
        return;
    };
    let _turn = turn();
    let root = Root::new().with_recorded_sessions();
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

    let mut running = Daemon::start(&daemon, &root.0);
    let pipe = running.serving();
    let run = |arguments: &[&str]| {
        let (status, envelope) = cli(&daemon, &pin, &pipe, arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        envelope["result"].clone()
    };
    let status = run(&["runtime", "storage", "status"]);
    assert_eq!(status["sessionDomain"]["usage"]["sessionCount"], "2");
    let page = run(&["session", "list"]);
    assert_eq!(page["items"].as_array().unwrap().len(), 2, "{page}");
    let shown = run(&["session", "show", "--session", OBSERVED]);
    assert_eq!(shown["sessionId"], OBSERVED);
    let destination = root.exports().join("observed");
    let destination_text = destination.to_str().unwrap().to_owned();
    let preview = run(&[
        "session",
        "export",
        "preview",
        "--session",
        OBSERVED,
        "--destination",
        &destination_text,
    ]);
    let exported = run(&[
        "session",
        "export",
        "apply",
        "--preview-id",
        preview["previewId"].as_str().unwrap(),
        "--preview-digest",
        preview["previewDigest"].as_str().unwrap(),
    ]);
    assert_eq!(exported["exportedPath"], destination_text.as_str());
    assert!(destination.join("manifest.json").is_file());

    // Pinned, a policy the two Sessions exceed, and the cleanup that
    // reclaims the unpinned one and keeps the pinned one; then unpinned.
    let pinned = run(&[
        "session",
        "pin",
        "--session",
        OBSERVED,
        "--expected-generation",
        shown["generation"].as_str().unwrap(),
    ]);
    assert_eq!(pinned["pinned"], true, "{pinned}");
    let policy = run(&[
        "runtime",
        "storage",
        "policy",
        "--expected-generation",
        "1",
        "--total-quota-bytes",
        "2",
        "--safety-margin-bytes",
        "1",
        "--retention-days",
        "1",
    ]);
    assert_eq!(policy["sessionDomain"]["generation"], "2", "{policy}");
    let cleanup = run(&["session", "cleanup", "preview"]);
    let reclaimed: Vec<&str> = cleanup["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|session| session["disposition"] == "reclaim")
        .map(|session| session["sessionId"].as_str().unwrap())
        .collect();
    assert_eq!(reclaimed, [FAILED], "{cleanup}");
    let applied = run(&[
        "session",
        "cleanup",
        "apply",
        "--preview-id",
        cleanup["previewId"].as_str().unwrap(),
        "--preview-digest",
        cleanup["previewDigest"].as_str().unwrap(),
    ]);
    assert_eq!(applied["removedSessionIds"], json!([FAILED]), "{applied}");
    assert!(!root.session(FAILED).exists());
    // The cleanup moved the catalog on: the kept Session is read again.
    let kept = run(&["session", "show", "--session", OBSERVED]);
    assert_eq!(kept["pinned"], true, "{kept}");
    let unpinned = run(&[
        "session",
        "unpin",
        "--session",
        OBSERVED,
        "--expected-generation",
        kept["generation"].as_str().unwrap(),
    ]);
    assert_eq!(unpinned["pinned"], false, "{unpinned}");
    assert!(root.session(OBSERVED).join("manifest.json").is_file());

    // The Sessions root moved to an existing owner-only directory inside the
    // isolated development root, and back to its default.
    let custom = root.0.join("custom-sessions");
    HostDirectory::open_or_create_private(&custom).unwrap();
    let custom_text = custom.to_str().unwrap().to_owned();
    let status = run(&["runtime", "storage", "status"]);
    let moved = run(&[
        "runtime",
        "storage",
        "root",
        "--expected-generation",
        status["sessionDomain"]["generation"].as_str().unwrap(),
        "--root",
        &custom_text,
    ]);
    assert_eq!(
        moved["sessionDomain"]["rootPath"],
        custom_text.as_str(),
        "{moved}"
    );
    assert_ne!(moved["sessionDomain"]["rootKind"], "default", "{moved}");
    let restored = run(&[
        "runtime",
        "storage",
        "root",
        "--expected-generation",
        moved["sessionDomain"]["generation"].as_str().unwrap(),
        "--default",
    ]);
    assert_eq!(
        restored["sessionDomain"]["rootKind"], "default",
        "{restored}"
    );
    assert_eq!(
        restored["sessionDomain"]["rootPath"],
        root.sessions().to_str().unwrap(),
        "{restored}"
    );
    assert!(root.session(OBSERVED).join("manifest.json").is_file());
    running.stop(&root.0);
    assert_measured(&[
        "runtime.storage.status",
        "runtime.storage.policy",
        "runtime.storage.root",
        "session.list",
        "session.show",
        "session.pin",
        "session.unpin",
        "session.export.preview",
        "session.export.apply",
        "session.cleanup.preview",
        "session.cleanup.apply",
    ]);
}

/// What this test measured is what the coverage manifest counts: each
/// leaf's entries are Windows `implemented` in the manifest the CLI renders
/// (`maintainer contracts export`'s product, held to the committed
/// `openspec/contracts/cli-feature-coverage.json` by the CLI's own tests).
fn assert_measured(leaves: &[&str]) {
    let product = arkdeck_cli::machine_contracts::contract_products()
        .into_iter()
        .find(|product| product.relative_path == "cli-feature-coverage.json")
        .expect("the CLI renders its feature coverage");
    let coverage: Value = serde_json::from_slice(&product.bytes).unwrap();
    for leaf in leaves {
        let statuses: Vec<&Value> = coverage["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["feature"] == *leaf)
            .map(|entry| &entry["implementationStatusByPlatform"]["windows"])
            .collect();
        assert!(
            !statuses.is_empty() && statuses.iter().all(|status| *status == "implemented"),
            "{leaf}: {statuses:?}"
        );
    }
}
