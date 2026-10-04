//! `diagnostics export` on Windows (TASK-XPA-018), as the real daemon
//! serves it over an isolated development root: a `capture.diagnostics@1`
//! Job the macOS Runtime recorded (`rust/tests/fixtures/
//! capture-diagnostics-trace`), admitted into `jobs-state` by the Job store
//! owner and its Artifacts laid down in `artifacts`, as a Windows daemon
//! cannot run the capture itself without a registered HDC tuple.
//!
//! Through the real CLI against a copy of the daemon signed with the
//! host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`): the
//! capture's summary, and its sensitive Trace with the explicit permission,
//! are exported with the recorded bytes, and an Artifact of a recorded Job
//! that is not a diagnostics capture is refused (`invalidInput`) before
//! anything is written; the leaf is then Windows `implemented`. Without that
//! variable this test says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root: nothing installed is read or written, and no HDC
//! or device is involved.
#![cfg(windows)]

use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore};
use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
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
/// A diagnostics capture that published its Trace, and the Trace.
const CAPTURE: &str = "job-1c209bf5f7b1537cbd2406f5640e0ab8";
const TRACE: &str = "ART-148c3168fc02b640a96d452463b2a8d7";
/// Its `capture-summary.json`, a standard Artifact.
const SUMMARY: &str = "ART-254a229f7471f2bbe3d18b818b1fb8d1";
/// A recorded Job that is not a diagnostics capture, and its Artifact.
const OTHER: &str = "job-73b1cb9a96d12a0ea736a065afdf5abd";
fn other_artifact() -> &'static str {
    static INDEX: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    let index = INDEX.get_or_init(|| {
        serde_json::from_slice(
            &std::fs::read(
                fixture("agent-execution")
                    .join("artifacts")
                    .join(OTHER)
                    .join("index.json"),
            )
            .unwrap(),
        )
        .unwrap()
    });
    let rows: Vec<_> = index["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["name"] == "tool-facts.json")
        .collect();
    assert_eq!(rows.len(), 1);
    rows[0]["artifactID"].as_str().unwrap()
}

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(path)
}

/// A recorded Artifact index with each retention deadline a century later:
/// the daemon's start-up retention sweep reclaims a settled Job's lapsed
/// Artifacts, as Swift's does.
fn unexpired(bytes: &[u8]) -> Vec<u8> {
    let mut index: Value = serde_json::from_slice(bytes).unwrap();
    for row in index["artifacts"].as_array_mut().unwrap() {
        if let Some(deadline) = row["retention"]["deadlineUTC"].as_str() {
            let (year, rest) = deadline.split_at(4);
            let later = format!("{}{rest}", year.parse::<u32>().unwrap() + 100);
            row["retention"]["deadlineUTC"] = json!(later);
        }
    }
    serde_json::to_vec_pretty(&index).unwrap()
}

/// A fresh development root in its plain drive spelling, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-windiag-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
    fn state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// A recorded Job (`store` names the fixture's Runtime state), admitted
    /// by the Job store owner and advanced to its recorded version, its
    /// Journal beside it; and its Artifacts as the macOS Runtime published
    /// them: the index owner-only, each payload sealed.
    fn with_recorded_job(self, fixture_root: &str, job: &str) -> Self {
        HostDirectory::open_or_create_private(&self.state()).unwrap();
        let store = JobStore::open_owner(&self.state()).unwrap();
        let recorded = fixture(fixture_root);
        let index: Value =
            serde_json::from_slice(&std::fs::read(recorded.join("store/index.json")).unwrap())
                .unwrap();
        let row = index["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["jobId"] == job)
            .unwrap();
        let directory = recorded.join("store/jobs").join(job);
        let record =
            JobRecord::decode(&std::fs::read(directory.join("job-record.json")).unwrap()).unwrap();
        assert_eq!(
            store
                .admit(&record, row["requestHash"].as_str().unwrap())
                .unwrap(),
            AdmissionVerdict::Admitted
        );
        for _ in 1..row["version"].as_i64().unwrap() {
            store
                .persist(&record, row["updatedAtUTC"].as_str().unwrap())
                .unwrap();
        }
        std::fs::copy(
            directory.join("journal.jsonl"),
            self.state().join("jobs").join(job).join("journal.jsonl"),
        )
        .unwrap();
        let artifacts = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        let target = artifacts.create_private_child(job).unwrap();
        let source = recorded.join("artifacts").join(job);
        for entry in std::fs::read_dir(&source).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            let bytes = std::fs::read(source.join(&name)).unwrap();
            let bytes = if name == "index.json" {
                unexpired(&bytes)
            } else {
                bytes
            };
            target.create_document(&name, &bytes).unwrap();
            if name != "index.json" {
                target.seal_document(&name).unwrap();
            }
        }
        self
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

/// Every coverage entry for each of `leaves` is Windows `implemented` in the
/// manifest this CLI renders.
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

#[test]
fn diagnostics_export_runs_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new()
        .with_recorded_job("capture-diagnostics-trace", CAPTURE)
        .with_recorded_job("agent-execution", OTHER);
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
    let exports = root.0.join("exports");
    std::fs::create_dir(&exports).unwrap();
    let exports_text = exports.to_str().unwrap().to_owned();

    let mut running = Daemon::start(&daemon, &root.0);
    let pipe = running.serving();
    // The capture's summary, and its sensitive Trace with the explicit
    // permission, each exported with its recorded bytes.
    for (artifact, sensitive) in [(SUMMARY, false), (TRACE, true)] {
        let mut arguments = vec![
            "diagnostics",
            "export",
            "--job",
            CAPTURE,
            "--artifact",
            artifact,
            "--destination",
            &exports_text,
        ];
        if sensitive {
            arguments.push("--allow-sensitive");
        }
        let (status, envelope) = cli(&daemon, &pin, &pipe, &arguments);
        assert_eq!(status, Some(0), "{artifact}: {envelope}");
        let exported = PathBuf::from(envelope["result"]["exportedPath"].as_str().unwrap());
        assert_eq!(exported.parent().unwrap(), exports.as_path(), "{envelope}");
        assert_eq!(
            std::fs::read(&exported).unwrap(),
            std::fs::read(fixture(&format!(
                "capture-diagnostics-trace/artifacts/{CAPTURE}/{artifact}"
            )))
            .unwrap()
        );
    }
    // Another Job's Artifact is not a diagnostics capture's: refused before
    // anything is written.
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "diagnostics",
            "export",
            "--job",
            OTHER,
            "--artifact",
            other_artifact(),
            "--destination",
            &exports_text,
        ],
    );
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(envelope["error"]["code"], "invalidInput", "{envelope}");
    assert_eq!(std::fs::read_dir(&exports).unwrap().count(), 2);
    running.stop(&root.0);
    assert_measured(&["diagnostics.export"]);
}
