//! The Windows daemon's cleanup debt owner (`cleanupDebt.list` and
//! `cleanupDebt.continue`), as the real daemon composes it over an isolated
//! development root: the Artifact owner's `cleanup-debt.json` and the Job
//! store, through the runner `job.run` uses on Windows.
//!
//! The root holds Swift's recorded debug HAP ledger
//! (`rust/tests/fixtures/debug-hap/artifacts/cleanup-debt.json`) as it stood
//! before its continuations settled it (both debts owed, no retry begun), and
//! the two recorded Jobs that owe them, admitted into `jobs-state` by the Job
//! store owner while the daemon is stopped.
//!
//! * Over its pipe, with a plain pipe handle (no signer needed), across a
//!   restart: `cleanupDebt.list` answers the committed control-frame
//!   corpus's recorded list of this ledger exactly; the corpus's refusal of a
//!   continuation naming no debt is answered as recorded, and a debt the
//!   ledger does not owe is refused. No Windows HDC tuple is registered, so a
//!   continuation of either owed debt is refused (`rejected`, the HDC provider
//!   unavailable) after the ledger and the Job are read and before any
//!   readback or retry: the ledger's bytes never change.
//! * Through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `recovery cleanup list` and its alias `cleanup-debt list` answer the
//!   same rows, which then count as Windows `implemented`, and `recovery
//!   cleanup continue` reports the refusal. Without that variable this test
//!   says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, and no HDC or device is involved.
#![cfg(windows)]

use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore, OperationRequest};
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
const LEDGER: &str = "cleanup-debt.json";
/// The recorded Jobs that owe the ledger's debts: a bundle left installed,
/// and a staged HAP left on the device.
const BUNDLE_JOB: &str = "job-fef1a0e4c7231791a53842cbdbc7afb0";
const PATH_JOB: &str = "job-aab111522c0cbfb47e6694c029d517fa";
const STAGED: &str =
    "/data/local/tmp/arkdeck-job-aab111522c0cbfb47e6694c029d517fa-send-hap-owned.hap";
const UNAVAILABLE: &str = "internalFailure(\"provider hdc is unavailable\")";

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/debug-hap")
        .join(path)
}

/// A fresh development root holding the recorded ledger and its Jobs,
/// removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-windebt-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let root = Self(path);
        root.owe();
        for job in [BUNDLE_JOB, PATH_JOB] {
            root.with_recorded_job(job);
        }
        root.with_recorded_capabilities();
        root
    }
    fn ledger(&self) -> Vec<u8> {
        std::fs::read(self.0.join("artifacts").join(LEDGER)).unwrap()
    }
    /// Swift's ledger before its continuations: each record without the
    /// settlement and the retry they wrote, in Swift's encoding (sorted,
    /// pretty, escaped solidus).
    fn owe(&self) {
        let mut records: Vec<Value> =
            serde_json::from_slice(&std::fs::read(fixture("artifacts/cleanup-debt.json")).unwrap())
                .unwrap();
        for record in &mut records {
            let record = record.as_object_mut().unwrap();
            record.remove("settledAtUTC");
            record.remove("retryAttemptStartedAtUTC");
        }
        let bytes = serde_json::to_string_pretty(&records)
            .unwrap()
            .replace("\": ", "\" : ")
            .replace('/', "\\/");
        let directory = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        directory.create_document(LEDGER, bytes.as_bytes()).unwrap();
    }
    /// Swift's capability store after those Jobs, which consumed their
    /// capabilities: beside the Job state, where this daemon keeps it
    /// (`jobs-state\capabilities`). Continuing a terminal Job's debt loads
    /// the Job as restart recovery does, which proves its authorization
    /// lineage here.
    fn with_recorded_capabilities(&self) {
        let state = self.0.join("jobs-state");
        HostDirectory::open_or_create_private(&state).unwrap();
        HostDirectory::open_or_create_private(&state.join("capabilities")).unwrap();
        for name in [
            ".runtime-capabilities.lock",
            "runtime-capabilities.json",
            "runtime-capabilities.ledger",
        ] {
            std::fs::copy(
                fixture(&format!("store/capabilities/{name}")),
                state.join("capabilities").join(name),
            )
            .unwrap();
        }
    }
    /// The recorded Job, admitted by the Job store owner as Swift admitted
    /// it (in `preflight`), then persisted as it ended, with its recorded
    /// Journal beside it.
    fn with_recorded_job(&self, job: &str) {
        HostDirectory::open_or_create_private(&self.0.join("jobs-state")).unwrap();
        let store = JobStore::open_owner(&self.0.join("jobs-state")).unwrap();
        let recorded: Value = serde_json::from_slice(
            &std::fs::read(fixture(&format!("store/jobs/{job}/job-record.json"))).unwrap(),
        )
        .unwrap();
        let hash = OperationRequest::decode(
            &serde_json::to_vec(&recorded["originalSubmissionRequest"]).unwrap(),
        )
        .unwrap()
        .fingerprint();
        let mut admitted = recorded.clone();
        admitted["state"] = json!("preflight");
        let decode = |record: &Value| {
            JobRecord::decode(&serde_json::to_vec_pretty(record).unwrap()).unwrap()
        };
        assert_eq!(
            store.admit(&decode(&admitted), &hash).unwrap(),
            AdmissionVerdict::Admitted
        );
        store
            .persist(&decode(&recorded), "2026-09-14T00:00:00Z")
            .unwrap();
        std::fs::copy(
            fixture(&format!("store/jobs/{job}/journal.jsonl")),
            self.0
                .join("jobs-state")
                .join("jobs")
                .join(job)
                .join("journal.jsonl"),
        )
        .unwrap();
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

fn corpus(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// A refusal: its code and message, and no details.
fn refused(pipe: &str, method: &str, params: Value, code: &str, message: &str) {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], false, "{method}: {reply}");
    assert_eq!(
        reply["error"],
        json!({"code": code, "message": message}),
        "{method}: {reply}"
    );
}

/// The corpus's recorded list of this ledger: both debts owed.
fn recorded_list() -> Value {
    corpus("cleanupDebt.list")
        .into_iter()
        .find(|frame| {
            frame["result"]
                .as_array()
                .is_some_and(|rows| rows.len() == 2 && rows[0]["jobId"] == PATH_JOB)
        })
        .expect("the corpus records the debug HAP ledger's list")["result"]
        .clone()
}

#[test]
fn the_recorded_ledger_is_listed_and_no_debt_is_continued_without_an_hdc() {
    let _turn = turn();
    let root = Root::new();
    let before = root.ledger();
    let listed = recorded_list();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    for restart in 0..2 {
        let mut daemon = Daemon::start(executable, &root.0);
        let pipe = daemon.serving();
        let reply = request(&pipe, "cleanupDebt.list", json!({}));
        assert_eq!(reply["result"], listed, "restart {restart}: {reply}");
        // The corpus's refusals, as recorded.
        for frame in corpus("cleanupDebt.continue")
            .iter()
            .filter(|frame| frame["ok"] == false)
        {
            let reply = request(&pipe, "cleanupDebt.continue", frame["params"].clone());
            assert_eq!(reply["error"], frame["error"], "{frame}: {reply}");
        }
        // A debt the ledger does not owe.
        refused(
            &pipe,
            "cleanupDebt.continue",
            json!({"jobId": BUNDLE_JOB, "remotePath": STAGED}),
            "rejected",
            &format!("jobNotFound(\"cleanup-debt:{BUNDLE_JOB}:{STAGED}\")"),
        );
        // Both owed debts: read, then refused before any device work.
        refused(
            &pipe,
            "cleanupDebt.continue",
            json!({"jobId": BUNDLE_JOB, "bundleName": "com.example.demo"}),
            "rejected",
            UNAVAILABLE,
        );
        refused(
            &pipe,
            "cleanupDebt.continue",
            json!({"jobId": PATH_JOB, "remotePath": STAGED}),
            "rejected",
            UNAVAILABLE,
        );
        assert_eq!(root.ledger(), before, "restart {restart}: nothing settled");
        let reply = request(&pipe, "cleanupDebt.list", json!({}));
        assert_eq!(reply["result"], listed, "restart {restart}: {reply}");
        daemon.stop(&root.0);
    }
}

#[test]
fn an_undecodable_ledger_fails_both_methods_as_swift_s_store_does() {
    let _turn = turn();
    let root = Root::new();
    let unreasoned = br#"[{"jobID":"job-a","stepID":"cleanup","remotePath":"/data/a","recordedAtUTC":"2026-09-14T00:00:00Z"}]"#;
    std::fs::remove_file(root.0.join("artifacts").join(LEDGER)).unwrap();
    HostDirectory::open(&root.0.join("artifacts"))
        .unwrap()
        .create_document(LEDGER, unreasoned)
        .unwrap();
    let mut daemon = Daemon::start(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0);
    let pipe = daemon.serving();
    let corrupted = "indexCorrupted(\"undecodable cleanup debt ledger: reason\")";
    refused(
        &pipe,
        "cleanupDebt.list",
        json!({}),
        "internalError",
        corrupted,
    );
    refused(
        &pipe,
        "cleanupDebt.continue",
        json!({"jobId": "job-a", "remotePath": "/data/a"}),
        "internalError",
        corrupted,
    );
    daemon.stop(&root.0);
    assert_eq!(root.ledger(), unreasoned);
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
fn cleanup_debt_runs_through_the_cli_against_a_dev_signed_daemon() {
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
    let before = root.ledger();
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
    let listed = recorded_list();

    for restart in 0..2 {
        let mut running = Daemon::start(&daemon, &root.0);
        let pipe = running.serving();
        for arguments in [
            &["recovery", "cleanup", "list"][..],
            &["cleanup-debt", "list"],
        ] {
            let (status, envelope) = cli(&daemon, &pin, &pipe, arguments);
            assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
            assert_eq!(envelope["result"], listed, "{arguments:?}: {envelope}");
        }
        let (status, envelope) = cli(
            &daemon,
            &pin,
            &pipe,
            &[
                "recovery",
                "cleanup",
                "continue",
                "--job",
                BUNDLE_JOB,
                "--bundle",
                "com.example.demo",
            ],
        );
        // The CLI reports a refused continuation as one whose outcome it
        // cannot claim, naming the daemon's refusal.
        assert_ne!(status, Some(0), "restart {restart}: {envelope}");
        assert_eq!(
            envelope["error"]["details"]["wireCode"], "rejected",
            "{envelope}"
        );
        assert_eq!(envelope["error"]["message"], UNAVAILABLE, "{envelope}");
        assert_eq!(root.ledger(), before);
        running.stop(&root.0);
    }
    assert_measured(&["cleanupDebt.list"]);
}
