//! XPA-AC-7's kill matrix through the Windows daemon (TASK-XPA-005): the
//! daemon starting over the store the Rust runner leaves when it is killed at
//! each of the four crash windows of the Swift crash-window oracle
//! (`rust/tests/fixtures/crash-window`; `arkdeck-hoststore`'s
//! `windows_crash_window.rs` kills the runner there and shows the store is
//! Swift's `crash/` byte for byte), then killed itself, and started again.
//!
//! For each window, a development root holds the Target document Swift's
//! adoption wrote, and the Job store and capability store as the killed run
//! left them (`crash/`). Then:
//!
//! * the daemon's start recovers the Job as Swift's first start did: its
//!   `job.status` is Swift's `restart` status, and the Job's journal, record
//!   and index row and the capability store are Swift's `restart/` snapshot
//!   (the read-only and mutation intents parked `waitingForRecovery` with
//!   `outcomeUnknown` and the use settled `outcomeUnknown` where one was
//!   consumed; a Job with no outstanding intent carried as `running`);
//! * the daemon is terminated (`TerminateProcess`, no drain), and a new one
//!   starts over the root it left, as after a crash: its recovery is Swift's
//!   second start (`secondRestart/`), and nothing is written twice;
//! * every request Swift answered after its death is asked over the pipe.
//!   The Job and capability reads answer as Swift's did. What needs the
//!   Windows HDC tuple, which is not registered, is refused before anything
//!   is written or dispatched: `job.reconcile` of the device-bound Job and a
//!   new tap's `job.submit` (no HDC provider). Those refusals are asserted,
//!   and the store stays Swift's `secondRestart/`;
//! * a third start after a clean stop changes nothing.
//!
//! The Job's index row is laid down by the Job owner from the killed run's
//! record, so its initial-record digest is not Swift's (the row's first
//! record is the one the run admitted). The daemon recovers on its own clock
//! where the oracle's was fixed, so each UTC time it writes reads as the
//! oracle's, and so does each capability ledger record's digest of its own
//! bytes. Every other column, the journal, the record and the capability
//! store are compared byte for byte, each record's machine facts read as
//! labels. No device or `hdc` is involved: the daemon
//! composes no HDC.
#![cfg(windows)]

use arkdeck_hoststore::{JobRecord, JobStore};
use arkdeck_platform::{HostDirectory, HostSqlite, SqliteValue as Sql, StateRoot};
use serde_json::{Value, json};
use std::collections::BTreeMap;
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

const WINDOWS: [&str; 4] = [
    "beforeConsume",
    "afterReadOnlyIntent",
    "afterConsume",
    "afterIntent",
];
const MACHINE_FACTS: [&str; 4] = ["device", "inode", "volumeIdentity", "admissionGeneration"];

fn fixture(window: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/crash-window")
        .join(window)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// A fresh development root, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new(window: &str) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winkill-{window}-{nonce:016x}"));
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
    /// The Target document and the store the run killed at `window` left
    /// (`crash/`): each Job admitted and persisted by the Job owner to its
    /// recorded version, its journal and lock beside it, and the capability
    /// store's files.
    fn with_crash(self, window: &str) -> Self {
        let recorded = fixture(window).join("crash");
        let targets = HostDirectory::open_or_create_private(&self.0.join("targets-state")).unwrap();
        targets
            .create_document(
                "targets.json",
                &std::fs::read(fixture(window).join("targets-state/targets.json")).unwrap(),
            )
            .unwrap();
        let state = self.jobs_state();
        HostDirectory::open_or_create_private(&state).unwrap();
        let store = JobStore::open_owner(&state).unwrap();
        let index = document(recorded.join("index.json"));
        for row in index["rows"].as_array().unwrap() {
            let id = row["jobId"].as_str().unwrap();
            let directory = recorded.join("jobs").join(id);
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
        let capabilities =
            HostDirectory::open_or_create_private(&state.join("capabilities")).unwrap();
        for file in std::fs::read_dir(recorded.join("capabilities")).unwrap() {
            let file = file.unwrap().path();
            capabilities
                .create_document(
                    file.file_name().unwrap().to_str().unwrap(),
                    &std::fs::read(&file).unwrap(),
                )
                .unwrap();
        }
        self
    }
    /// Every file of the Job store and the capability store against the
    /// oracle's snapshot under `prefix`, byte for byte (records
    /// machine-independently): what a serving daemon has written durably.
    fn assert_files(&self, window: &str, prefix: &str) {
        let recorded = fixture(window).join(prefix);
        for part in ["jobs", "capabilities"] {
            let actual = files(&self.jobs_state().join(part));
            let expected = files(&recorded.join(part));
            assert_eq!(
                actual.keys().collect::<Vec<_>>(),
                expected.keys().collect::<Vec<_>>(),
                "{window} {prefix}/{part}"
            );
            for (path, bytes) in &expected {
                assert_eq!(
                    String::from_utf8_lossy(&actual[path]),
                    String::from_utf8_lossy(bytes),
                    "{window} {prefix}/{part}/{path}"
                );
            }
        }
    }
    /// The files and the Job index against the oracle's snapshot under
    /// `prefix`, with no daemon running: every index column but the initial
    /// record's digest, read from a copy of the database and its write-ahead
    /// log as the next start finds them (nothing is checkpointed in place).
    fn assert_snapshot(&self, window: &str, prefix: &str) {
        self.assert_files(window, prefix);
        let without_initial = |mut index: Value| {
            for row in index["rows"].as_array_mut().unwrap() {
                row.as_object_mut().unwrap().remove("recordSHA256");
            }
            index
        };
        let copy = self.0.join("index-copy");
        let _ = std::fs::remove_dir_all(&copy);
        HostDirectory::open_or_create_private(&copy).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            let name = format!("runtime-jobs.sqlite3{suffix}");
            if self.jobs_state().join(&name).exists() {
                std::fs::copy(self.jobs_state().join(&name), copy.join(&name)).unwrap();
            }
        }
        let actual = index(&copy);
        std::fs::remove_dir_all(&copy).unwrap();
        assert_eq!(
            without_initial(actual),
            without_initial(document(fixture(window).join(prefix).join("index.json"))),
            "{window} {prefix}/index.json"
        );
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Every file below `base` by its relative path (forward slashes), a Job
/// record read machine-independently.
fn files(base: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut found = BTreeMap::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        for entry in std::fs::read_dir(base.join(&relative)).unwrap() {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                pending.push(path);
                continue;
            }
            let mut bytes = oracle_clock(&std::fs::read(base.join(&path)).unwrap());
            if path
                .extension()
                .is_some_and(|extension| extension == "ledger")
            {
                bytes = ledger_digests(&bytes);
            }
            let name = path.to_str().unwrap().replace('\\', "/");
            found.insert(
                name,
                if path.file_name().unwrap() == "job-record.json" {
                    machine_independent(&bytes)
                } else {
                    bytes
                },
            );
        }
    }
    found
}

/// The daemon recovers on its own clock where the oracle's was fixed: every
/// UTC time it wrote (`2026-09-30T12:55:18Z`, or with milliseconds) reads as
/// the oracle's clock, in the same spelling, so every other byte is compared.
fn oracle_clock(bytes: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    let digits = |slice: &[u8], at: &[usize]| at.iter().all(|&i| slice[i].is_ascii_digit());
    let mut at = 0;
    while at + 20 <= out.len() {
        let candidate = &out[at..];
        let seconds = digits(candidate, &[0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18])
            && candidate[4] == b'-'
            && candidate[7] == b'-'
            && candidate[10] == b'T'
            && candidate[13] == b':'
            && candidate[16] == b':';
        if seconds && candidate[19] == b'Z' {
            out[at..at + 20].copy_from_slice(b"2026-09-14T00:00:00Z");
            at += 20;
        } else if seconds
            && candidate.len() >= 24
            && candidate[19] == b'.'
            && digits(candidate, &[20, 21, 22])
            && candidate[23] == b'Z'
        {
            out[at..at + 24].copy_from_slice(b"2026-09-14T00:00:00.000Z");
            at += 24;
        } else {
            at += 1;
        }
    }
    out
}

/// Each capability ledger record carries the digest of its own bytes
/// (`recordSHA256`), which the daemon's clock enters where the oracle's was
/// fixed; it reads as a label, every other byte of the record compared.
fn ledger_digests(bytes: &[u8]) -> Vec<u8> {
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    let needle = "\"recordSHA256\":\"";
    let mut out = String::new();
    let mut rest = text.as_str();
    while let Some(at) = rest.find(needle) {
        let start = at + needle.len();
        out.push_str(&rest[..start]);
        out.push_str("<recordSHA256>");
        rest = &rest[start + 64..];
    }
    out.push_str(rest);
    out.into_bytes()
}

/// A Job record's publication marker names this machine's volume, device,
/// inode and claim generation; each reads as a fixed label.
fn machine_independent(bytes: &[u8]) -> Vec<u8> {
    let mut text = String::from_utf8(bytes.to_vec()).unwrap();
    for key in MACHINE_FACTS {
        let needle = format!("\"{key}\"");
        let label = format!("<{key}>");
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(at) = rest.find(&needle) {
            let (head, tail) = rest.split_at(at + needle.len());
            out.push_str(head);
            rest = tail;
            let Some(value) = tail
                .trim_start_matches(' ')
                .strip_prefix(':')
                .map(|after| after.trim_start_matches(' '))
                .and_then(|after| after.strip_prefix('"'))
            else {
                continue;
            };
            let Some(end) = value.find('"') else {
                continue;
            };
            out.push_str(&tail[..tail.len() - value.len()]);
            let current = &value[..end];
            out.push_str(if current.is_empty() || current == "0" {
                current
            } else {
                &label
            });
            rest = &value[end..];
        }
        out.push_str(rest);
        text = out;
    }
    text.into_bytes()
}

/// The facts the Swift oracle records of the Job index, from a copy of it.
fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), false, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(String::from_utf8(oracle_clock(text.as_bytes())).unwrap()),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(&machine_independent(bytes))),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows})
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

    /// Terminated at once (`TerminateProcess`), with no drain: what a crash
    /// or a kill leaves.
    fn kill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        let status = wait(child);
        assert!(!status.success(), "{status:?}");
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

/// The Job's status over the pipe, as the start the oracle names recovered it.
fn assert_recovered(pipe: &str, cases: &Value, start: usize, window: &str) {
    let recorded = &cases["starts"][start];
    let job = cases["job"]["jobId"].as_str().unwrap();
    let status = request(pipe, "job.status", json!({"jobId": job}));
    assert_eq!(
        status["result"], recorded["recovered"][0],
        "{window} {}: {status}",
        recorded["name"]
    );
}

/// Every request Swift answered after its death, over the pipe. A reconcile
/// the recorded facts decide answers as Swift's did and leaves Swift's store
/// for that step; one that needs the device's facts (through an HDC
/// composition this daemon does not have) is refused and writes nothing. The
/// tap the run admitted, sent again, is answered from its idempotency record;
/// a new tap is refused before admission (no HDC provider plans it). Every
/// read answers as Swift's did while the reconciles matched Swift's, and
/// answers at all after one was refused. Answers the snapshot the store now
/// matches.
fn assert_requests(pipe: &str, root: &Root, cases: &Value, window: &str) -> String {
    let proof = json!({"phase": "preAdmission", "newDispatchCount": 0});
    let mut current = "secondRestart".to_owned();
    let mut matched = true;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        let reply = request(pipe, method, exchange["params"].clone());
        match method {
            "job.reconcile" if reply["ok"] == true => {
                assert_eq!(
                    semantic(&reply),
                    semantic(&exchange["answer"]),
                    "{window} {name}"
                );
                current = format!("steps/{name}");
            }
            "job.reconcile" => {
                assert_eq!(
                    reply["error"]["code"], "rejected",
                    "{window} {name}: {reply}"
                );
                assert!(
                    reply["error"]["message"]
                        .as_str()
                        .unwrap()
                        .ends_with("holds no HDC composition to reconcile it; nothing was dispatched or written"),
                    "{window} {name}: {reply}"
                );
                matched = false;
            }
            "job.submit" if name == "tap.submit" => {
                assert_eq!(
                    reply["result"],
                    json!({"deduplicated": true, "jobId": cases["job"]["jobId"],
                        "newDispatchCount": 0, "schemaVersion": "arkdeck.job-acceptance/1"}),
                    "{window}: {reply}"
                );
            }
            "job.submit" => {
                assert_eq!(reply["ok"], false, "{window} {name}: {reply}");
                assert_eq!(reply["error"]["details"], proof, "{window}: {reply}");
            }
            _ if matched => {
                assert_eq!(
                    semantic(&reply),
                    semantic(&exchange["answer"]),
                    "{window} {name}"
                );
            }
            _ => assert!(
                reply.get("result").is_some() || reply.get("error").is_some(),
                "{window} {name}: {reply}"
            ),
        }
        root.assert_files(window, &current);
    }
    current
}

#[test]
fn the_daemon_recovers_each_crash_window_across_a_kill_as_swift_does() {
    let _turn = turn();
    let executable = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
    for window in WINDOWS {
        let root = Root::new(window).with_crash(window);
        let cases = document(fixture(window).join("cases.json"));
        root.assert_snapshot(window, "crash");

        // The first start after the run died: Swift's first start.
        let mut first = Daemon::start(executable, &root.0);
        let pipe = first.serving();
        assert_recovered(&pipe, &cases, 0, window);
        root.assert_files(window, "restart");
        // Killed while serving, with nothing drained: what it left is what
        // its start wrote.
        first.kill();
        root.assert_snapshot(window, "restart");

        // The next start over what the killed daemon left: Swift's second.
        let mut second = Daemon::start(executable, &root.0);
        let pipe = second.serving();
        assert!(
            second
                .seen
                .iter()
                .any(|line| line.starts_with("arkdeck-agentd previous instance: ")),
            "{window}: {:?}",
            second.seen
        );
        assert_recovered(&pipe, &cases, 1, window);
        root.assert_files(window, "secondRestart");
        let current = assert_requests(&pipe, &root, &cases, window);
        second.stop(&root.0);
        root.assert_snapshot(window, &current);

        // A clean third start recovers the Job once more, as each start
        // does, and a read after it answers the recorded status.
        let mut third = Daemon::start(executable, &root.0);
        let pipe = third.serving();
        let job = cases["job"]["jobId"].as_str().unwrap();
        let status = request(&pipe, "job.status", json!({"jobId": job}));
        assert_eq!(status["ok"], true, "{window}: {status}");
        third.stop(&root.0);
    }
}
