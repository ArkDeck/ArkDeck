//! The Windows daemon's Job planner and admitter (TASK-XPA-005, GJ-1): the
//! `job.plan` and `job.submit` hops of `observe.device@1`, as the real daemon
//! composes them over an isolated development root.
//!
//! The test's development root names no registered Windows HDC, so the
//! daemon composes no HDC provider, and no
//! workspace or analyzer provider either. The planner and the admitter are
//! the macOS code with those owners absent, so:
//!
//! * a plan or a new submission of `observe.device@1` is refused before
//!   admission with zero dispatch, as macOS refuses it without an HDC
//!   provider (`provider hdc is not registered`), and nothing is admitted:
//!   the index, the Job directories and `job.list` are unchanged;
//! * the admission's own order still holds: the typed request, the Catalog
//!   and its inputs are judged first, and the idempotency lookup comes
//!   before materialization, so a retry of a recorded Swift submission is
//!   answered with the recorded Job (`deduplicated`), exactly the acceptance
//!   Swift answered, and a changed request under its key is an idempotency
//!   conflict, both with nothing materialized or dispatched;
//! * all of it is answered the same after a restart;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `windows_job_store_process.rs` signs one), `job plan` and `job submit`
//!   report the same. Without that variable this test says so and checks
//!   nothing.
//!
//! The recorded Swift `observe.device@1` Jobs (`rust/tests/fixtures/
//! observe-device/store`) are recorded into `jobs-state` by the Job store
//! owner before the daemon starts, as the Job store's own test does. Every
//! daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but its
//! development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, no HDC is configured, and no device
//! or `hdc` is involved.
#![cfg(windows)]

use arkdeck_hoststore::{AdmissionVerdict, JobRecord, JobStore};
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
/// The recorded `observe.device@1` Job that observed its device.
const OBSERVED: &str = "job-0f77f8c52864d676372962eccb17389c";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device/store")
        .join(name)
}

/// The Swift submission the observed Job was admitted from.
fn recorded_submission() -> Value {
    let record: Value = serde_json::from_slice(
        &std::fs::read(fixture("jobs").join(OBSERVED).join("job-record.json")).unwrap(),
    )
    .unwrap();
    record["originalSubmissionRequest"].clone()
}

/// The `job.plan` / `job.submit` parameters for a request document.
fn request_json(request: &Value) -> Value {
    json!({"requestJson": serde_json::to_string(request).unwrap()})
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winadmit-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn jobs_state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// The recorded Swift `observe.device@1` Jobs, recorded by the Job store
    /// owner into a private `jobs-state`: admitted in admission order and
    /// advanced to their recorded version, each Journal beside its record.
    fn with_recorded_jobs(&self) {
        let state = self.jobs_state();
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let index: Value =
            serde_json::from_slice(&std::fs::read(fixture("index.json")).unwrap()).unwrap();
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        for row in &rows {
            let id = row["jobId"].as_str().unwrap();
            let directory = fixture("jobs").join(id);
            let record =
                JobRecord::decode(&std::fs::read(directory.join("job-record.json")).unwrap())
                    .unwrap();
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
                state.join("jobs").join(id).join("journal.jsonl"),
            )
            .unwrap();
        }
    }
    /// Every file below `jobs-state` with its bytes, the SQLite index's
    /// companions (their bytes follow the connection, not the rows) and the
    /// snapshot pages `job.list` stores aside.
    fn snapshot(&self) -> Vec<(PathBuf, Vec<u8>)> {
        fn walk(directory: &Path, into: &mut Vec<(PathBuf, Vec<u8>)>) {
            let mut entries: Vec<_> = std::fs::read_dir(directory)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            entries.sort();
            for path in entries {
                if path.is_dir() {
                    // A `job.list`'s stored snapshot pages are the read's,
                    // not the Job records'.
                    if path
                        .file_name()
                        .is_some_and(|name| name == "cli-job-snapshots")
                    {
                        continue;
                    }
                    walk(&path, into);
                } else {
                    let name = path.file_name().unwrap().to_string_lossy().into_owned();
                    if !name.starts_with("runtime-jobs.sqlite3") && !name.starts_with('.') {
                        into.push((path.clone(), std::fs::read(&path).unwrap()));
                    }
                }
            }
        }
        let mut files = Vec::new();
        walk(&self.jobs_state(), &mut files);
        files
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

/// The Job store's files as they were: the same paths with the same bytes.
fn assert_unchanged(before: &[(PathBuf, Vec<u8>)], after: &[(PathBuf, Vec<u8>)]) {
    let paths = |files: &[(PathBuf, Vec<u8>)]| {
        files
            .iter()
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(paths(after), paths(before), "the Job store's files changed");
    for ((path, was), (_, is)) in before.iter().zip(after) {
        assert!(
            was == is,
            "{} changed:
{}",
            path.display(),
            String::from_utf8_lossy(is)
        );
    }
}

/// A refusal before admission: its code and message, and the zero-dispatch
/// proof macOS attaches to it.
fn assert_refused(reply: &Value, code: &str, message: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], code, "{reply}");
    assert_eq!(reply["error"]["message"], message, "{reply}");
    assert_eq!(
        reply["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0}),
        "{reply}"
    );
}

/// A fresh `observe.device@1` submission: the recorded one under a new key.
fn fresh_submission() -> Value {
    let mut request = recorded_submission();
    request["idempotencyKey"] = json!("idem-windows-observe-fresh");
    request["requestId"] = json!("req-windows-observe-fresh");
    request
}

/// Every answer this build gives to the planner and the admitter, checked
/// against the macOS answers without the owners Windows lacks.
fn assert_admission(pipe: &str) {
    let not_registered = "provider hdc is not registered";
    // `job.plan` and a new submission materialize against no HDC provider.
    for method in ["job.plan", "job.submit"] {
        assert_refused(
            &request(pipe, method, request_json(&fresh_submission())),
            "invalidInput",
            not_registered,
        );
    }
    // The recorded submission retried: the idempotency lookup answers with
    // the recorded Job before anything is materialized, as Swift answered it.
    let retry = request(pipe, "job.submit", request_json(&recorded_submission()));
    assert_eq!(
        retry,
        json!({"id": "job.submit", "ok": true, "result": {
            "schemaVersion": "arkdeck.job-acceptance/1",
            "jobId": OBSERVED,
            "deduplicated": true,
            "newDispatchCount": 0,
        }}),
        "{retry}"
    );
    // A changed request under that key conflicts, again before anything is
    // materialized.
    let mut changed = recorded_submission();
    changed["requestId"] = json!("req-observe-observed-changed");
    changed["target"]["expectedBindingRevision"] = json!(2);
    assert_refused(
        &request(pipe, "job.submit", request_json(&changed)),
        "idempotencyConflict",
        "idempotency key reuse with a different request",
    );
    // The request, the Catalog and its inputs come first.
    let mut unknown = fresh_submission();
    unknown["operation"] = json!({"id": "observe.nothing", "version": 1});
    assert_refused(
        &request(pipe, "job.submit", request_json(&unknown)),
        "operationUnavailable",
        "operation observe.nothing@1 is not in the catalog",
    );
    let mut capability = fresh_submission();
    capability["authorization"] = json!({"capabilityId": "CAP-RT-windows"});
    assert_refused(
        &request(pipe, "job.plan", request_json(&capability)),
        "invalidInput",
        "planOnly does not accept or consume a Runtime capability",
    );
    let malformed = request(pipe, "job.submit", json!({"requestJson": ""}));
    assert_refused(
        &malformed,
        "invalidInput",
        "requestJson must be a non-empty typed request document",
    );
}

#[test]
fn observe_device_is_refused_before_admission_without_a_registered_hdc() {
    let _turn = turn();
    let root = Root::new();
    root.with_recorded_jobs();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    // The start's Job recovery has marked the recorded Job its unknown
    // outcome parked, as Swift's start marks it; nothing below writes.
    let before = root.snapshot();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, imports, storage, history, workspaceProjects, workspaceOperations, bootstrap, planning, agentExecutions, humanActions, controlActions, traceCache, flashAliasReconciler, flashInvocations, flashHostFacts, deviceAccess, loaderBinding"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );
    let listed = request(&pipe, "job.list", json!({}));
    assert_admission(&pipe);
    // Nothing was admitted: the same four Jobs listed, the same files.
    let after = request(&pipe, "job.list", json!({}));
    assert_eq!(
        after["result"]["items"], listed["result"]["items"],
        "{after}"
    );
    assert_eq!(listed["result"]["items"].as_array().unwrap().len(), 4);
    first.stop(&root.0);
    assert_unchanged(&before, &root.snapshot());

    // A restart answers the same, and still admits nothing.
    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    assert_admission(&pipe);
    let again = request(&pipe, "job.list", json!({}));
    assert_eq!(
        again["result"]["items"], listed["result"]["items"],
        "{again}"
    );
    second.stop(&root.0);
    assert_unchanged(&before, &root.snapshot());
}

#[test]
fn a_fresh_root_admits_nothing_and_lists_no_job() {
    let _turn = turn();
    let root = Root::new();
    let mut daemon = Daemon::start(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0);
    let pipe = daemon.serving();
    for method in ["job.plan", "job.submit"] {
        assert_refused(
            &request(&pipe, method, request_json(&recorded_submission())),
            "invalidInput",
            "provider hdc is not registered",
        );
    }
    // The other providers are absent too: a workspace operation's provider
    // is not registered and an analyzer has no profile.
    let mut workspace = fresh_submission();
    workspace["operation"] = json!({"id": "workspace.inspect-source", "version": 1});
    workspace["inputs"] = json!({});
    let reply = request(&pipe, "job.plan", request_json(&workspace));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(
        reply["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0}),
        "{reply}"
    );
    let listed = request(&pipe, "job.list", json!({}));
    assert_eq!(listed["result"]["items"], json!([]), "{listed}");
    daemon.stop(&root.0);
}

/// The Swift debug-hap oracle's recorded `debug.hap@1` submissions
/// (`rust/tests/fixtures/debug-hap`), by case: each one's request.
fn recorded_hap_requests() -> Vec<(String, Value)> {
    let cases: Value = serde_json::from_slice(
        &std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-hap/cases.json"),
        )
        .unwrap(),
    )
    .unwrap();
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|exchange| exchange["method"] == "job.submit")
        .map(|exchange| {
            (
                exchange["name"].as_str().unwrap().to_owned(),
                serde_json::from_str(exchange["params"]["requestJson"].as_str().unwrap()).unwrap(),
            )
        })
        .collect()
}

/// `debug.hap@1` is a device mutation whose HDC composition is the tuple's
/// (TASK-XPA-008): every recorded Swift submission, planned and submitted, is
/// refused before admission with zero dispatch, as macOS refuses it without
/// an HDC provider. Nothing is admitted and no Runtime capability is issued
/// (the Job and capability store are as they were), across a restart too.
#[test]
fn debug_hap_is_refused_before_admission_or_issuance_without_a_registered_hdc() {
    let _turn = turn();
    let root = Root::new();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    let requests = recorded_hap_requests();
    assert_eq!(requests.len(), 8);
    let mut first = None;
    for _ in 0..2 {
        let mut daemon = Daemon::start(executable, &root.0);
        let pipe = daemon.serving();
        let before = root.snapshot();
        for (name, submission) in &requests {
            for method in ["job.plan", "job.submit"] {
                let reply = request(&pipe, method, request_json(submission));
                assert_eq!(
                    reply["error"]["message"], "provider hdc is not registered",
                    "{name} {method}: {reply}"
                );
                assert_refused(&reply, "invalidInput", "provider hdc is not registered");
            }
        }
        let listed = request(&pipe, "job.list", json!({}));
        assert_eq!(listed["result"]["items"], json!([]), "{listed}");
        daemon.stop(&root.0);
        assert_unchanged(&before, &root.snapshot());
        assert_unchanged(first.get_or_insert(before), &root.snapshot());
    }
    // No capability was issued.
    let checkpoint = root
        .jobs_state()
        .join("capabilities")
        .join("runtime-capabilities.json");
    assert!(
        !checkpoint.exists()
            || serde_json::from_slice::<Value>(&std::fs::read(&checkpoint).unwrap()).unwrap()["records"]
                == json!([]),
        "a capability was issued"
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
fn gj1_plan_and_submit_hops_run_through_the_cli_against_a_dev_signed_daemon() {
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
    root.with_recorded_jobs();
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
    let requests = root.0.join("requests");
    std::fs::create_dir(&requests).unwrap();
    let write = |name: &str, request: &Value| {
        let path = requests.join(name);
        std::fs::write(&path, serde_json::to_vec(request).unwrap()).unwrap();
        path.to_str().unwrap().to_owned()
    };
    let fresh = write("fresh.json", &fresh_submission());
    let recorded = write("recorded.json", &recorded_submission());

    let mut first = Daemon::start(&daemon, &root.0);
    first.serving();
    // After the start's Job recovery (see above).
    let before = root.snapshot();
    first.stop(&root.0);
    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    for verb in ["plan", "submit"] {
        let (status, envelope) = cli(
            &daemon,
            &pin,
            &pipe,
            &["job", verb, "--request-file", &fresh],
        );
        assert_ne!(status, Some(0), "{verb}: {envelope}");
        assert_eq!(
            envelope["error"]["details"]["wireCode"], "invalidInput",
            "{verb}: {envelope}"
        );
        assert_eq!(
            envelope["error"]["message"], "provider hdc is not registered",
            "{verb}: {envelope}"
        );
    }
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["job", "submit", "--request-file", &recorded],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["jobId"], OBSERVED, "{envelope}");
    assert_eq!(envelope["result"]["deduplicated"], true, "{envelope}");
    assert_eq!(envelope["result"]["newDispatchCount"], 0, "{envelope}");
    second.stop(&root.0);
    assert_unchanged(&before, &root.snapshot());
}
