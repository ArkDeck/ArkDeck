//! The Windows daemon's Artifact read and export owner (TASK-XPA-006), as
//! the real daemon composes it over an isolated development root beside its
//! Job store, holding a Job recorded by the macOS Runtime
//! (`rust/tests/fixtures/agent-execution`, `job-73b1…`): its Artifacts in the
//! root's `artifacts`, and the Job itself recorded into `jobs-state` by the
//! Job store owner before the daemon starts (admitted and advanced to its
//! recorded version, its Journal beside it), as nothing admits a Job on
//! Windows yet:
//!
//! * over its pipe, with a plain pipe handle (no signer needed): the Job
//!   owner proves the Artifacts' Job, and `artifact.list`, `inspect` and
//!   `read` answer exactly what the owner answers in process (a list's
//!   snapshot revision is fresh on every read), before and after a restart;
//!   `artifact.export` publishes the recorded bytes under the Artifact's
//!   name. A Job the Job owner does not hold is refused before anything is
//!   read (`resourceNotFound`, phase `artifactOwner`, no new dispatch), and
//!   the recorded Job's Artifacts stay byte for byte as they were. An
//!   `artifacts` directory that is not owner-only refuses the start (it is
//!   never re-permissioned);
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one): `artifact list`, `inspect`,
//!   `read` and `export` answer the same, with the CLI verifying the
//!   daemon's image and signer. Without that variable this test says so and
//!   checks nothing.
//!
//! The recorded bytes and digests themselves, and every export refusal, are
//! proved at the owner (`arkdeck-hoststore/tests/windows_artifact_owners.rs`).
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, no HDC is configured, and no device
//! or `hdc` is involved. Each daemon is stopped by its own stop request, or
//! ended by this test if it outlives a failed assertion.
#![cfg(windows)]

use arkdeck_hoststore::{AdmissionVerdict, ArtifactReadStore, JobRecord, JobStore};
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
const JOB: &str = "job-73b1cb9a96d12a0ea736a065afdf5abd";
const ARTIFACT: &str = "ART-5ab8ddce1b835cb95173c1a4b08a7e5d";
/// A Job no owner holds.
const ABSENT: &str = "job-00000000000000000000000000000000";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/agent-execution")
}

fn recorded() -> PathBuf {
    fixture().join("artifacts").join(JOB)
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winartifacts-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        let path = match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(text) => PathBuf::from(text),
            None => path,
        };
        Self(path)
    }
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    /// The recorded Job's Artifacts as the macOS Runtime published them: a
    /// private Artifact root, the index owner-only, each payload sealed; and
    /// the Job, recorded by the Job store owner into a private `jobs-state`:
    /// admitted and advanced to its recorded version, its Journal beside it.
    fn with_recorded_job(self) -> Self {
        let state = self.0.join("jobs-state");
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let index: Value =
            serde_json::from_slice(&std::fs::read(fixture().join("store/index.json")).unwrap())
                .unwrap();
        let row = index["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["jobId"] == JOB)
            .unwrap();
        let directory = fixture().join("store/jobs").join(JOB);
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
            state.join("jobs").join(JOB).join("journal.jsonl"),
        )
        .unwrap();
        let root = HostDirectory::open_or_create_private(&self.artifacts()).unwrap();
        let job = root.create_private_child(JOB).unwrap();
        for entry in std::fs::read_dir(recorded()).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            job.create_document(&name, &std::fs::read(recorded().join(&name)).unwrap())
                .unwrap();
            if name != "index.json" {
                job.seal_document(&name).unwrap();
            }
        }
        self
    }
    /// Every entry below `path` with its bytes.
    fn tree(path: &Path) -> Vec<(PathBuf, Option<Vec<u8>>)> {
        let mut entries: Vec<_> = std::fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        entries.sort();
        let mut tree = Vec::new();
        for entry in entries {
            if entry.is_dir() {
                tree.push((entry.clone(), None));
                tree.extend(Self::tree(&entry));
            } else {
                tree.push((entry.clone(), Some(std::fs::read(&entry).unwrap())));
            }
        }
        tree
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

/// Refused by the Artifact owner before anything is read or dispatched.
fn refused(pipe: &str, method: &str, params: Value, code: &str) -> Value {
    let reply = request(pipe, method, params);
    assert_eq!(reply["ok"], false, "{method}: {reply}");
    assert_eq!(reply["error"]["code"], code, "{method}: {reply}");
    reply
}

fn owner() -> Value {
    json!({"kind": "job", "id": JOB})
}

/// Every recorded Artifact's `artifact.list`, `inspect` and `read` (sensitive
/// ones allowed), as their method, parameters and what the Artifact owner
/// answers in process over this root, with the Job proved.
fn expected_reads(root: &Root) -> Vec<(&'static str, Value, Value)> {
    let store = ArtifactReadStore::open(&root.artifacts()).unwrap();
    let index: Value =
        serde_json::from_slice(&std::fs::read(recorded().join("index.json")).unwrap()).unwrap();
    let mut reads = vec![("artifact.list", json!({"owner": owner()}))];
    for row in index["artifacts"].as_array().unwrap() {
        let id = row["artifactID"].as_str().unwrap();
        reads.push((
            "artifact.inspect",
            json!({"owner": owner(), "artifactId": id}),
        ));
        reads.push((
            "artifact.read",
            json!({"owner": owner(), "artifactId": id, "allowSensitive": true}),
        ));
    }
    reads
        .into_iter()
        .map(|(method, params)| {
            let map = params.as_object().unwrap();
            let answer = if method == "artifact.list" {
                store.handle_list(map, |_| Ok(()))
            } else {
                store.handle_resource(method, map, |_| Ok(()))
            }
            .unwrap_or_else(|error| panic!("{method} {params}: {}", error.message));
            arkdeck_contract::validate_method_value(method, "result", &answer).unwrap();
            (method, params, labelled(answer))
        })
        .collect()
}

/// An answer with its snapshot revision as a label: fresh on every list.
fn labelled(mut answer: Value) -> Value {
    if answer["snapshotRevision"].is_string() {
        answer["snapshotRevision"] = json!("<revision>");
    }
    answer
}

/// Every recorded read answered over the pipe as the owner answers it.
fn assert_reads(pipe: &str, expected: &[(&'static str, Value, Value)]) {
    for (method, params, answer) in expected {
        let reply = request(pipe, method, params.clone());
        assert_eq!(reply["ok"], true, "{method} {params}: {reply}");
        assert_eq!(
            &labelled(reply["result"].clone()),
            answer,
            "{method} {params}"
        );
    }
}

#[test]
fn the_artifact_owner_answers_for_the_job_the_job_owner_holds_across_a_restart() {
    let _turn = turn();
    let root = Root::new().with_recorded_job();
    let exports = root.exports();
    let job_artifacts = Root::tree(&root.artifacts().join(JOB));
    let expected = expected_reads(&root);
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    assert!(
        daemon.seen.contains(
            &"arkdeck-agentd owners: jobs, capabilities, targets, artifacts, storage, workspaceProjects, planning, agentExecutions, humanActions, traceCache"
                .to_owned()
        ),
        "{:?}",
        daemon.seen
    );
    assert_reads(&pipe, &expected);
    // The export publishes the recorded bytes under the Artifact's name.
    let reply = request(
        &pipe,
        "artifact.export",
        json!({"owner": owner(), "artifactId": ARTIFACT,
            "destinationDirectory": exports.to_str().unwrap()}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let receipt = &reply["result"];
    arkdeck_contract::validate_method_value("artifact.export", "result", receipt).unwrap();
    let bytes = std::fs::read(recorded().join(ARTIFACT)).unwrap();
    let file = exports.join(format!("{ARTIFACT}-tool-facts.json"));
    assert_eq!(receipt["exportedPath"], file.to_str().unwrap(), "{receipt}");
    assert_eq!(
        receipt["artifactDigest"],
        arkdeck_contract::sha256_hex(&bytes)
    );
    assert_eq!(std::fs::read(&file).unwrap(), bytes);
    // A Job the Job owner does not hold is refused before anything is read.
    for (method, params) in [
        (
            "artifact.list",
            json!({"owner": {"kind": "job", "id": ABSENT}}),
        ),
        (
            "artifact.inspect",
            json!({"owner": {"kind": "job", "id": ABSENT}, "artifactId": ARTIFACT}),
        ),
    ] {
        let reply = refused(&pipe, method, params, "resourceNotFound");
        assert_eq!(
            reply["error"],
            json!({"code": "resourceNotFound",
                "message": "Artifact Job owner does not exist",
                "details": {"phase": "artifactOwner", "newDispatchCount": 0}}),
            "{method}: {reply}"
        );
    }
    // A destination that is not a local drive's absolute path is refused as
    // the request is read, before the Job is asked for.
    let reply = refused(
        &pipe,
        "artifact.export",
        json!({"owner": owner(), "artifactId": ARTIFACT,
            "destinationDirectory": r"\\localhost\c$\exports"}),
        "invalidInput",
    );
    assert_eq!(reply["error"]["details"]["phase"], "artifactOwner");
    // An Import's Artifacts need the Import owner, which is not composed.
    refused(
        &pipe,
        "artifact.inspect",
        json!({"owner": {"kind": "import", "id": "imp-00000000-0000-4000-8000-000000000000"},
            "artifactId": ARTIFACT}),
        "operationUnavailable",
    );
    daemon.stop(&root.0);

    // After a restart the same answers.
    let mut daemon = Daemon::start(executable, &root.0);
    let pipe = daemon.serving();
    assert_reads(&pipe, &expected);
    daemon.stop(&root.0);
    assert_eq!(
        Root::tree(&root.artifacts().join(JOB)),
        job_artifacts,
        "the recorded Job's Artifacts are as they were"
    );
}

#[test]
fn an_artifact_directory_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: its DACL
    // inherited, granting others access. The daemon never rewrites it.
    std::fs::create_dir(root.artifacts()).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the Artifact store") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(
        !String::from_utf8(output.stdout)
            .unwrap()
            .contains("listening on"),
        "nothing served"
    );
    assert!(
        Root::tree(&root.artifacts()).is_empty(),
        "nothing was created in it"
    );
}

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
fn gj1_artifact_commands_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let root = Root::new().with_recorded_job();
    let exports = root.exports();
    let job_artifacts = Root::tree(&root.artifacts().join(JOB));
    let expected = expected_reads(&root);
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
    for (method, params, answer) in &expected {
        let mut arguments = vec![
            "artifact".to_owned(),
            method.trim_start_matches("artifact.").to_owned(),
            "--job".to_owned(),
            JOB.to_owned(),
        ];
        if let Some(id) = params["artifactId"].as_str() {
            arguments.extend(["--artifact".to_owned(), id.to_owned()]);
        }
        if *method == "artifact.read" {
            arguments.push("--allow-sensitive".to_owned());
        }
        let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let (status, envelope) = cli(&daemon, &pin, &pipe, &arguments);
        assert_eq!(status, Some(0), "{arguments:?}: {envelope}");
        assert_eq!(
            &labelled(envelope["result"].clone()),
            answer,
            "{arguments:?}"
        );
    }
    let exports_text = exports.to_str().unwrap().to_owned();
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &[
            "artifact",
            "export",
            "--job",
            JOB,
            "--artifact",
            ARTIFACT,
            "--destination",
            &exports_text,
        ],
    );
    assert_eq!(status, Some(0), "{envelope}");
    let file = exports.join(format!("{ARTIFACT}-tool-facts.json"));
    assert_eq!(
        envelope["result"]["exportedPath"],
        file.to_str().unwrap(),
        "{envelope}"
    );
    assert_eq!(
        std::fs::read(&file).unwrap(),
        std::fs::read(recorded().join(ARTIFACT)).unwrap()
    );
    running.stop(&root.0);
    assert_eq!(Root::tree(&root.artifacts().join(JOB)), job_artifacts);
}
