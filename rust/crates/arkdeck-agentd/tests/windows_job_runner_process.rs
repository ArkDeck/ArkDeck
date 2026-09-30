//! The Windows daemon's Job runner (TASK-XPA-005, GJ-1): `job.run`,
//! `job.cancel`, `job.result`, `job.evidence`, the start's Job recovery and
//! `operation.list`, as the real daemon composes them over an isolated
//! development root.
//!
//! No Windows HDC tuple is registered, so the daemon composes no HDC
//! provider and no device Job runs: the queued `observe.device@1` Job the
//! test records is admitted in process before the daemon starts — over an
//! HDC composition naming the recorded Target, whose dispatcher fails the
//! test if called — as the daemon would admit it with an HDC. Then, over the
//! daemon's pipe (a plain pipe handle, no signer needed):
//!
//! * the start recovers the recorded Swift Jobs as Swift's start does: the
//!   Job its unknown outcome parked is marked, nothing is dispatched;
//! * `job.result` and `job.evidence` of the recorded Jobs answer as Swift
//!   answered (a refusal's wording aside, T2), the Artifacts read where the
//!   macOS Runtime published them;
//! * `job.run` of the queued Job is refused before its run with zero
//!   dispatch, and `job.cancel` closes it cancelled at once, publishing its
//!   Session through the Session owner; a run then meets a terminal Job;
//! * `operation.list` reports the HDC operations `provider_not_registered`,
//!   as the macOS daemon reports them without an HDC provider;
//! * a restart reads all of it back and changes nothing;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `job run`, `job cancel` and `job result` report the same. Without that
//!   variable this test says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory;
//! no device or `hdc` is involved.
#![cfg(windows)]

use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobRecord, JobStore, TargetStore,
};
use arkdeck_platform::{HostDirectory, StateRoot};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
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
/// The recorded Job its unknown outcome parked.
const PARKED: &str = "job-8adf7b22600ff6ee77e61d7c92b2f790";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

/// A dispatcher the admission may never reach.
struct NoDispatch;
impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("dispatched {:?}", plan.arguments)
    }
}

/// A recorded Artifact index with each retention deadline a century later.
/// The recorded deadlines lapsed long before this run, and the daemon's
/// start-up retention sweep reclaims a settled Job's lapsed Artifacts, as
/// Swift's does; no answer compared here names a deadline but as this root
/// holds it.
fn unexpired(bytes: &[u8]) -> Vec<u8> {
    let mut index: serde_json::Value = serde_json::from_slice(bytes).unwrap();
    for row in index["artifacts"].as_array_mut().unwrap() {
        if let Some(deadline) = row["retention"]["deadlineUTC"].as_str() {
            let (year, rest) = deadline.split_at(4);
            let later = format!("{}{rest}", year.parse::<u32>().unwrap() + 100);
            row["retention"]["deadlineUTC"] = serde_json::json!(later);
        }
    }
    serde_json::to_vec_pretty(&index).unwrap()
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winrun-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        // The canonical spelling without `\\?\`, as the daemon names its root.
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
    fn jobs_state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// The recorded Swift Jobs and their Artifacts, then one queued
    /// `observe.device@1` Job admitted in process over the recorded Target.
    /// Returns the queued Job's identity.
    fn with_jobs(&self) -> String {
        let state = self.jobs_state();
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let index = document(fixture("store/index.json"));
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = fixture("store/jobs").join(id);
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
            std::fs::copy(
                directory.join("journal.jsonl"),
                state.join("jobs").join(id).join("journal.jsonl"),
            )
            .unwrap();
        }
        let artifacts = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        for job in std::fs::read_dir(fixture("artifacts")).unwrap() {
            let job = job.unwrap().path();
            let owned = artifacts
                .create_private_child(job.file_name().unwrap().to_str().unwrap())
                .unwrap();
            for file in std::fs::read_dir(&job).unwrap() {
                let file = file.unwrap().path();
                let name = file.file_name().unwrap().to_str().unwrap().to_owned();
                let bytes = std::fs::read(&file).unwrap();
                let bytes = if name == "index.json" {
                    unexpired(&bytes)
                } else {
                    bytes
                };
                owned.create_document(&name, &bytes).unwrap();
                if name != "index.json" {
                    owned.seal_document(&name).unwrap();
                }
            }
        }
        let targets = self.0.join("targets-state");
        HostDirectory::open_or_create_private(&targets).unwrap();
        std::fs::write(
            targets.join("targets.json"),
            std::fs::read(fixture("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
        let target_store = TargetStore::open(&targets).unwrap();
        let artifact_store = ArtifactReadStore::open(&self.0.join("artifacts")).unwrap();
        let provenance = document(fixture("provenance.json"));
        let hdc = HdcComposition {
            targets: &target_store,
            dispatch: &NoDispatch,
            receive_root: None,
            tool_sha256: provenance["hdcSHA256"].as_str().unwrap(),
            now: fixed_now,
            code_sign_helper: None,
        };
        let mut request = document(fixture(
            "store/jobs/job-0f77f8c52864d676372962eccb17389c/job-record.json",
        ))["originalSubmissionRequest"]
            .clone();
        request["idempotencyKey"] = json!("idem-windows-queued");
        request["requestId"] = json!("req-windows-queued");
        let accepted = JobAdmitter {
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifact_store),
                analyzer: None,
                state_root: &self.0,
                hdc: Some(&hdc),
                workspace: None,
            },
            jobs: &store,
            now: fixed_now,
            authority: None,
        }
        .handle(
            json!({"requestJson": serde_json::to_string(&request).unwrap()})
                .as_object()
                .unwrap(),
        )
        .unwrap();
        accepted["jobId"].as_str().unwrap().to_owned()
    }
    fn record(&self, id: &str) -> Value {
        document(
            self.jobs_state()
                .join("jobs")
                .join(id)
                .join("job-record.json"),
        )
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

/// An answer without the request identity and a refusal's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(object) = answer.as_object_mut() {
        object.remove("id");
    }
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

/// Every recorded `job.result` and `job.evidence` answered as Swift did.
fn assert_results(pipe: &str) {
    let cases = document(fixture("cases.json"));
    let mut replayed = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let method = exchange["method"].as_str().unwrap();
        if !matches!(method, "job.result" | "job.evidence") {
            continue;
        }
        replayed += 1;
        let reply = request(pipe, method, exchange["params"].clone());
        assert_eq!(
            semantic(&reply),
            semantic(&exchange["answer"]),
            "{}",
            exchange["name"]
        );
    }
    assert_eq!(replayed, 8);
}

/// `operation.list`: every HDC operation reported as the macOS daemon
/// reports it without an HDC provider.
fn assert_operations(pipe: &str) {
    let list = request(pipe, "operation.list", json!({}));
    assert_eq!(list["ok"], true, "{list}");
    for reference in ["observe.device@1", "capture.diagnostics@1", "input.tap@1"] {
        let operation = list["result"]
            .as_array()
            .unwrap()
            .iter()
            .find(|operation| operation["reference"] == reference)
            .unwrap_or_else(|| panic!("{reference} is not listed"));
        assert_eq!(operation["availability"], "unavailable", "{operation}");
        assert_eq!(
            operation["reasonCodes"],
            json!(["provider_not_registered"]),
            "{operation}"
        );
    }
}

#[test]
fn a_queued_job_is_cancelled_and_recorded_jobs_read_as_swift_s_across_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let queued = root.with_jobs();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    assert_eq!(
        root.record(PARKED)["timeline"].as_array().unwrap().len(),
        8,
        "as Swift left it"
    );

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    // The start recovered the active Jobs: the queued one stays queued, the
    // parked one is marked as Swift's start marks it; nothing dispatched.
    assert!(
        first
            .seen
            .contains(&"recovered 2 active job(s); unknown outcomes parked".to_owned()),
        "{:?}",
        first.seen
    );
    assert_eq!(
        root.record(PARKED)["timeline"]
            .as_array()
            .unwrap()
            .last()
            .unwrap(),
        "recovered: outstanding intents or unknown outcomes; no redispatch"
    );
    assert_results(&pipe);
    assert_operations(&pipe);

    // No HDC composed: the queued device Job is not run, and stays queued.
    let run = request(&pipe, "job.run", json!({"jobId": queued}));
    assert_eq!(run["error"]["code"], "rejected", "{run}");
    assert_eq!(
        run["error"]["message"],
        format!("job {queued} runs observe.device@1, which the Rust Runtime does not execute yet")
    );
    assert_eq!(
        run["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0}),
        "{run}"
    );
    let status = request(&pipe, "job.status", json!({"jobId": queued}));
    assert_eq!(status["result"]["state"], "preflight", "{status}");

    // Cancelled before it ever ran: closed at once, its Session published.
    let cancel = request(&pipe, "job.cancel", json!({"jobId": queued}));
    assert_eq!(
        cancel["result"],
        json!({"cancelRequested": true}),
        "{cancel}"
    );
    let status = request(&pipe, "job.status", json!({"jobId": queued}));
    assert_eq!(status["result"]["state"], "cancelled", "{status}");
    assert_eq!(
        status["result"]["sessionPublication"]["state"], "published",
        "{status}"
    );
    let record = root.record(&queued);
    assert_eq!(record["operationFailure"]["code"], "cancelled");
    assert_eq!(
        record["sessionPublicationRecord"]["phase"],
        "catalogPublished"
    );
    assert!(
        root.0
            .join("sessions")
            .join(
                record["sessionPublicationRecord"]["relativeSessionPath"]
                    .as_str()
                    .unwrap()
            )
            .join("manifest.json")
            .is_file()
    );
    let run = request(&pipe, "job.run", json!({"jobId": queued}));
    assert_eq!(run["error"]["code"], "resourceConflict", "{run}");
    first.stop(&root.0);
    let after_first = (root.record(&queued), root.record(PARKED));

    // A restart reads it back and changes nothing: no Job is active now
    // but the parked one, whose marker is not written twice.
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    let status = request(&pipe, "job.status", json!({"jobId": queued}));
    assert_eq!(status["result"]["state"], "cancelled", "{status}");
    let cancel = request(&pipe, "job.cancel", json!({"jobId": queued}));
    assert_eq!(
        cancel["result"],
        json!({"cancelRequested": true}),
        "{cancel}"
    );
    assert_results(&pipe);
    assert_operations(&pipe);
    second.stop(&root.0);
    assert_eq!((root.record(&queued), root.record(PARKED)), after_first);
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
fn gj1_run_cancel_and_result_hops_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let queued = root.with_jobs();
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

    let mut started = Daemon::start(&daemon, &root.0);
    let pipe = started.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "run", "--job", &queued]);
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["error"]["details"]["wireCode"], "rejected",
        "{envelope}"
    );
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "cancel", "--job", &queued]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["cancelRequested"], true, "{envelope}");
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "status", "--job", &queued]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["state"], "cancelled", "{envelope}");
    let observed = "job-0f77f8c52864d676372962eccb17389c";
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "result", "--job", observed]);
    assert_eq!(status, Some(0), "{envelope}");
    let recorded = document(fixture("cases.json"))["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "observed.result")
        .unwrap()["answer"]["result"]
        .clone();
    assert_eq!(envelope["result"], recorded, "{envelope}");
    started.stop(&root.0);
}
