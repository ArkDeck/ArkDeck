//! The Windows daemon's start-up Artifact retention sweep and its device
//! mutation authority (TASK-XPA-005), as the real daemon composes them over
//! an isolated development root.
//!
//! The root holds the recorded Swift `observe.device@1` store
//! (`rust/tests/fixtures/observe-device`) and its Artifacts as the macOS
//! Runtime published them, their retention lapsed on 2026-09-21. Then, over
//! the daemon's pipe (a plain pipe handle, no signer needed):
//!
//! * the start recovers the recorded Jobs (the parked one marked), then
//!   sweeps: the two terminal Jobs
//!   whose Sessions were published lose their four lapsed Artifacts (index
//!   rows and payloads); the failed Job whose Session publication failed and
//!   the Job its unknown outcome parked, which the census cannot prove
//!   settled, keep theirs;
//! * `job.result` of a swept Job answers with no Artifact, and
//!   `artifact.quota` counts only what is kept;
//! * the census names the mutation authority (`mutationAuthority`): the
//!   capability store beside the Job state and the root a device mutation
//!   proves its state continuity against. A development root names the
//!   account's Job state, which its own Job store never is, so the state is
//!   never proved here and nothing of the account's root is read;
//!   `capability.list` answers from the store;
//! * a restart sweeps nothing more and changes nothing;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`):
//!   `artifact list`, `artifact quota` and `capability list` report the
//!   same; `capability list` is Windows `implemented` in the coverage
//!   manifest the CLI renders (`WINDOWS_MEASURED_LEAVES`). Without that
//!   variable this test says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory;
//! no device or `hdc` is involved.
#![cfg(windows)]

use arkdeck_hoststore::{JobRecord, JobStore};
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

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// The recorded terminal Jobs whose Sessions were published, whose lapsed
/// Artifacts the sweep reclaims.
const SWEPT: [&str; 2] = [
    "job-0f77f8c52864d676372962eccb17389c",
    "job-efd52ab9c633074171a19ddd916fffd9",
];
/// The recorded failed Job whose Session publication failed: never
/// finalized, so its Artifact is kept.
const UNPUBLISHED: &str = "job-1721f8df101bec4bab91e4619d3f66fa";

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winsweep-{nonce:016x}"));
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
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    /// The recorded Swift Jobs and their Artifacts, as Swift and the macOS
    /// Runtime left them: the retention deadlines as recorded.
    fn with_jobs(self) -> Self {
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
        let artifacts = HostDirectory::open_or_create_private(&self.artifacts()).unwrap();
        for job in std::fs::read_dir(fixture("artifacts")).unwrap() {
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
    /// A Job's Artifact index rows, by identity.
    fn rows(&self, job: &str) -> Vec<String> {
        document(self.artifacts().join(job).join("index.json"))["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["artifactID"].as_str().unwrap().to_owned())
            .collect()
    }
    /// Every entry below the Artifact root, with its bytes.
    fn tree(&self) -> Vec<(PathBuf, Option<Vec<u8>>)> {
        fn walk(path: &Path, into: &mut Vec<(PathBuf, Option<Vec<u8>>)>) {
            let mut entries: Vec<_> = std::fs::read_dir(path)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            entries.sort();
            for entry in entries {
                if entry.is_dir() {
                    into.push((entry.clone(), None));
                    walk(&entry, into);
                } else {
                    into.push((entry.clone(), Some(std::fs::read(&entry).unwrap())));
                }
            }
        }
        let mut entries = Vec::new();
        walk(&self.artifacts(), &mut entries);
        entries
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

/// The recorded Artifacts, by Job, as they were laid down.
fn recorded_rows() -> Vec<(String, Vec<String>)> {
    let mut rows = Vec::new();
    for job in std::fs::read_dir(fixture("artifacts")).unwrap() {
        let job = job.unwrap().path();
        let index = document(job.join("index.json"));
        rows.push((
            job.file_name().unwrap().to_str().unwrap().to_owned(),
            index["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| row["artifactID"].as_str().unwrap().to_owned())
                .collect(),
        ));
    }
    rows
}

#[test]
fn the_start_sweeps_lapsed_artifacts_and_names_the_mutation_authority_across_a_restart() {
    let _turn = turn();
    let root = Root::new().with_jobs();
    let recorded = recorded_rows();
    let swept: usize = recorded
        .iter()
        .filter(|(job, _)| SWEPT.contains(&job.as_str()))
        .map(|(_, rows)| rows.len())
        .sum();
    assert_eq!(swept, 4, "{recorded:?}");
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    for line in [
        "arkdeck-agentd owners: jobs, capabilities, mutationAuthority, targets, artifacts, \
         imports, storage, history, workspaceProjects, planning, agentExecutions, humanActions, traceCache",
        "recovered 1 active job(s); unknown outcomes parked",
        "reclaimed 4 expired artifact(s)",
    ] {
        assert!(
            first.seen.contains(&line.to_owned()),
            "{line}: {:?}",
            first.seen
        );
    }
    // The settled Jobs' rows and payloads are gone; the unsettled Job's kept.
    for (job, rows) in &recorded {
        if SWEPT.contains(&job.as_str()) {
            assert!(root.rows(job).is_empty(), "{job}");
            for artifact in rows {
                assert!(!root.artifacts().join(job).join(artifact).exists());
            }
        } else {
            assert_eq!(job, UNPUBLISHED);
            assert_eq!(&root.rows(job), rows, "{job}");
        }
    }
    let result = request(&pipe, "job.result", json!({"jobId": SWEPT[0]}));
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["result"]["artifacts"], json!([]), "{result}");
    let list = request(
        &pipe,
        "artifact.list",
        json!({"owner": {"kind": "job", "id": UNPUBLISHED}}),
    );
    assert_eq!(
        list["result"]["items"].as_array().unwrap().len(),
        1,
        "{list}"
    );
    let quota = request(&pipe, "artifact.quota", json!({}));
    let kept: u64 = document(root.artifacts().join(UNPUBLISHED).join("index.json"))["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["byteCount"].as_u64().unwrap())
        .sum();
    assert_eq!(quota["result"]["usedBytes"], json!(kept), "{quota}");
    // The capability store beside the Job state answers: nothing issued.
    let capabilities = request(&pipe, "capability.list", json!({}));
    assert_eq!(capabilities["ok"], true, "{capabilities}");
    let unknown = request(
        &pipe,
        "capability.inspect",
        json!({"capabilityId": "cap-00000000-0000-4000-8000-000000000000"}),
    );
    assert_eq!(unknown["ok"], false, "{unknown}");
    first.stop(&root.0);
    let after_first = root.tree();

    // A restart sweeps nothing more and changes nothing.
    let mut second = Daemon::start(executable, &root.0);
    let _ = second.serving();
    assert!(
        !second
            .seen
            .iter()
            .any(|line| line.starts_with("reclaimed ")),
        "{:?}",
        second.seen
    );
    assert!(
        !second.seen.iter().any(|line| line.contains("sweep failed")),
        "{:?}",
        second.seen
    );
    second.stop(&root.0);
    assert_eq!(root.tree(), after_first);
}

#[test]
fn swept_artifacts_and_capabilities_read_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new().with_jobs();
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
    assert!(
        started
            .seen
            .contains(&"reclaimed 4 expired artifact(s)".to_owned()),
        "{:?}",
        started.seen
    );
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["artifact", "list", "--job", SWEPT[0]],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(envelope["result"]["items"], json!([]), "{envelope}");
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["artifact", "list", "--job", UNPUBLISHED],
    );
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"]["items"].as_array().unwrap().len(),
        1,
        "{envelope}"
    );
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["artifact", "quota"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert!(
        envelope["result"]["usedBytes"].as_u64().unwrap() > 0,
        "{envelope}"
    );
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["capability", "list"]);
    assert_eq!(status, Some(0), "{envelope}");
    assert_eq!(
        envelope["result"],
        request(&pipe, "capability.list", json!({}))["result"],
        "{envelope}"
    );
    started.stop(&root.0);
    assert_measured(&["capability.list"]);
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
