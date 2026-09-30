//! The Windows daemon's Job store (TASK-XPA-005), as the real daemon
//! composes it over an isolated development root: GJ-1's Job-record hops
//! (index, `job-record.json`, Journal, restart readback) for the recorded
//! Swift `observe.device@1` Jobs.
//!
//! Nothing admits a Job on Windows yet (no planner, admitter or runner and
//! no registered HDC), so the Jobs are recorded into `jobs-state` by the Job
//! store owner itself before the daemon starts: each recorded Swift record
//! admitted and advanced to its recorded version, its recorded Journal
//! beside it. Then:
//!
//! * over the daemon's pipe, with a plain pipe handle (no signer needed):
//!   `job.status`, `job.show`, `job.events` and a one-page `job.list`
//!   answer exactly what the store answers in process (a list's snapshot
//!   revision and the sealed `jec1` cursors are fresh on every read), before
//!   and after a restart, and a cursor handed out before the restart reads
//!   on after it; `job.timeline` and a list of more than one page are
//!   refused as the read-only foundation refuses a method it lacks
//!   (`rejected`: the snapshot pager is not built on Windows yet); a Job
//!   directory that is not owner-only refuses the start;
//! * through the real CLI against a copy of the daemon signed with the
//!   host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, as
//!   `rust/scripts/check-readonly.py` signs one): `job status`, `job show`,
//!   `job events` and `job list` print the same answers after a restart, and
//!   `job timeline` reports the refusal. Without that variable this test
//!   says so and checks nothing.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root, a fresh directory below the temporary directory:
//! nothing installed is read or written, no HDC is configured, and no device
//! or `hdc` is involved. Each daemon is stopped by its own stop request, or
//! ended by this test if it outlives a failed assertion.
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
/// The reads this build answers on Windows from the Job store, each Job's
/// and the list of them all (one page).
const READS: [&str; 3] = ["job.status", "job.show", "job.events"];
const LIST: &str = "job.list";

/// A read's parameters: the Job's identity, or none for the list.
fn params(id: &str, method: &str) -> Value {
    if method == LIST {
        json!({})
    } else {
        json!({"jobId": id})
    }
}

/// A read's answer with each `job.events` cursor labelled: a cursor is the
/// position sealed (AES-GCM) under the store's cursor key with a fresh nonce,
/// so two reads of one page never spell it alike. That a cursor still opens
/// under the key the store keeps is checked by reading on from one.
fn labelled(mut answer: Value) -> Value {
    if let Some(items) = answer["result"]["items"].as_array_mut() {
        for item in items {
            if item["cursor"]
                .as_str()
                .is_some_and(|c| c.starts_with("jec1."))
            {
                item["cursor"] = json!("jec1.<sealed>");
            }
        }
    }
    if answer["result"]["snapshotRevision"].is_string() {
        answer["result"]["snapshotRevision"] = json!("<revision>");
    }
    if answer["result"]["nextCursor"]
        .as_str()
        .is_some_and(|c| c.starts_with("jec1."))
    {
        answer["result"]["nextCursor"] = json!("jec1.<sealed>");
    }
    answer
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device/store")
        .join(name)
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winjobs-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn jobs_state(&self) -> PathBuf {
        self.0.join("jobs-state")
    }
    /// The recorded Swift `observe.device@1` Jobs, recorded by the Job store
    /// owner into a private `jobs-state`: admitted in admission order and
    /// advanced to their recorded version, each Journal beside its record.
    /// Returns every Job identity.
    fn with_recorded_jobs(&self) -> Vec<String> {
        let state = self.jobs_state();
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let index: Value =
            serde_json::from_slice(&std::fs::read(fixture("index.json")).unwrap()).unwrap();
        let mut rows = index["rows"].as_array().unwrap().clone();
        rows.sort_by_key(|row| row["admissionSequence"].as_i64().unwrap());
        let mut ids = Vec::new();
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
            // The Job's private directory exists once its record is
            // published; a file created in it inherits its owner-only DACL.
            std::fs::copy(
                directory.join("journal.jsonl"),
                state.join("jobs").join(id).join("journal.jsonl"),
            )
            .unwrap();
            ids.push(id.to_owned());
        }
        ids
    }
    /// What the store answers in process to every read of every Job, and to
    /// the list of them all.
    fn answers(&self, ids: &[String]) -> Vec<(String, &'static str, Value)> {
        let store = JobStore::open(&self.jobs_state()).unwrap();
        let mut answers = Vec::new();
        let reads = ids
            .iter()
            .flat_map(|id| READS.map(|method| (id.as_str(), method)))
            .chain([("", LIST)]);
        for (id, method) in reads {
            let answer = labelled(
                match store.handle_resource(method, params(id, method).as_object().unwrap()) {
                    Ok(result) => json!({"ok": true, "result": result}),
                    Err(error) => panic!("{id} {method}: {}", error.message),
                },
            );
            answers.push((id.to_owned(), method, answer));
        }
        answers
    }
    fn record(&self, id: &str) -> Vec<u8> {
        std::fs::read(
            self.jobs_state()
                .join("jobs")
                .join(id)
                .join("job-record.json"),
        )
        .unwrap()
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

/// Every recorded read answered over the pipe as the store answers it, and
/// the snapshot-paged reads refused before admission with zero dispatch.
fn assert_reads(pipe: &str, answers: &[(String, &'static str, Value)]) {
    for (id, method, expected) in answers {
        let reply = request(pipe, method, params(id, method));
        let actual = labelled(json!({"ok": reply["ok"], "result": reply["result"]}));
        assert!(
            actual == *expected,
            "{id} {method}:\n  store  {expected}\n  daemon {actual}"
        );
    }
    // The timeline pages through the snapshot pager, not built on Windows.
    let reply = request(pipe, "job.timeline", json!({"jobId": OBSERVED}));
    assert_eq!(reply["error"]["code"], "rejected", "{reply}");
    assert_eq!(
        reply["error"]["message"],
        "the Job snapshot pager is not built on Windows yet; nothing was read",
        "{reply}"
    );
    // A list of more than one page needs it too.
    let reply = request(pipe, "job.list", json!({"pageSize": 1}));
    assert_eq!(reply["error"]["code"], "rejected", "{reply}");
    let absent = request(
        pipe,
        "job.status",
        json!({"jobId": "job-00000000000000000000000000000000"}),
    );
    assert_eq!(absent["error"]["code"], "notFound", "{absent}");
}

#[test]
fn recorded_jobs_are_read_over_the_pipe_and_after_a_restart() {
    let _turn = turn();
    let root = Root::new();
    let ids = root.with_recorded_jobs();
    assert_eq!(ids.len(), 4);
    let answers = root.answers(&ids);
    let recorded: Vec<Vec<u8>> = ids.iter().map(|id| root.record(id)).collect();
    // The observed Job reads as the Swift oracle left it: succeeded, with
    // its 16 Journal records paged by `job.events`.
    let observed = |method: &str| {
        answers
            .iter()
            .find(|(id, m, _)| id == OBSERVED && *m == method)
            .unwrap()
            .2
            .clone()
    };
    assert_eq!(observed("job.status")["result"]["state"], "succeeded");
    assert_eq!(
        observed("job.events")["result"]["items"]
            .as_array()
            .unwrap()
            .len(),
        16,
        "{}",
        observed("job.events")
    );
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));

    let mut first = Daemon::start(executable, &root.0);
    let pipe = first.serving();
    assert!(
        first.seen.contains(
            &"arkdeck-agentd owners: jobs, targets, artifacts, workspaceProjects, traceCache"
                .to_owned()
        ),
        "{:?}",
        first.seen
    );
    assert_reads(&pipe, &answers);
    // A cursor this daemon hands out ...
    let page = request(
        &pipe,
        "job.events",
        json!({"jobId": OBSERVED, "pageSize": 1}),
    );
    assert_eq!(page["result"]["hasMore"], true, "{page}");
    let cursor = page["result"]["items"][0]["cursor"].clone();
    first.stop(&root.0);

    let mut second = Daemon::start(executable, &root.0);
    let pipe = second.serving();
    assert_reads(&pipe, &answers);
    // ... reads on after the restart, under the cursor key the store keeps.
    let rest = request(
        &pipe,
        "job.events",
        json!({"jobId": OBSERVED, "afterCursor": cursor}),
    );
    let events = labelled(observed("job.events"))["result"]["items"]
        .as_array()
        .unwrap()[1..]
        .to_vec();
    assert_eq!(
        labelled(json!({"ok": rest["ok"], "result": rest["result"]}))["result"]["items"],
        json!(events),
        "{rest}"
    );
    second.stop(&root.0);

    // Reading changed no record, and the index still validates.
    let after: Vec<Vec<u8>> = ids.iter().map(|id| root.record(id)).collect();
    assert_eq!(after, recorded);
    assert_eq!(root.answers(&ids), answers);
}

#[test]
fn a_job_directory_that_is_not_owner_only_refuses_the_start() {
    let _turn = turn();
    let root = Root::new();
    // Created as any directory below the temporary directory is: it
    // inherits grants to others, which the store refuses and never rewrites.
    std::fs::create_dir(root.jobs_state()).unwrap();
    let output = daemon(Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")), &root.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("the Job store") && stderr.contains("nothing was started"),
        "{stderr}"
    );
    assert!(
        !String::from_utf8(output.stdout)
            .unwrap()
            .contains("listening on"),
        "nothing served"
    );
    assert!(!root.jobs_state().join("runtime-jobs.sqlite3").exists());
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
fn gj1_job_record_hops_run_through_the_cli_against_a_dev_signed_daemon() {
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
    let ids = root.with_recorded_jobs();
    let answers = root.answers(&ids);
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

    // Recorded before the first start, read after a restart.
    let mut first = Daemon::start(&daemon, &root.0);
    let pipe = first.serving();
    let (status, envelope) = cli(&daemon, &pin, &pipe, &["job", "status", "--job", OBSERVED]);
    assert_eq!(status, Some(0), "{envelope}");
    first.stop(&root.0);

    let mut second = Daemon::start(&daemon, &root.0);
    let pipe = second.serving();
    for (id, method, expected) in &answers {
        let verb = method.trim_start_matches("job.");
        let arguments: &[&str] = if *method == LIST {
            &["job", "list"]
        } else {
            &["job", verb, "--job", id]
        };
        let (status, envelope) = cli(&daemon, &pin, &pipe, arguments);
        assert_eq!(status, Some(0), "{id} {method}: {envelope}");
        assert_eq!(
            labelled(json!({"result": envelope["result"]}))["result"],
            expected["result"],
            "{id} {method}: {envelope}"
        );
    }
    let (status, envelope) = cli(
        &daemon,
        &pin,
        &pipe,
        &["job", "timeline", "--job", OBSERVED],
    );
    assert_ne!(status, Some(0), "{envelope}");
    assert_eq!(envelope["error"]["code"], "operationFailed", "{envelope}");
    assert_eq!(
        envelope["error"]["details"]["wireCode"], "rejected",
        "{envelope}"
    );
    second.stop(&root.0);
}
