//! The analyzer provider on Windows (TASK-XPA-011, GJ-5): the daemon's two
//! analyzer modes and the Runtime running the daemon as its own analyzer.
//!
//! * `arkdeck-agentd --analyze-crash-ledger` and `--summarize-hilog`,
//!   replayed against what the Swift daemon answered
//!   (`rust/tests/fixtures/crash-ledger-analyzer/oracle.json`,
//!   `hilog-summary-analyzer/oracle.json`): every recorded case whose one
//!   argument is the input file, and the usage refusals that read no path,
//!   through the built daemon with an empty environment and no stdin, as the
//!   Runtime runs its analyzer child, answered with the same exit status,
//!   stdout and stderr byte for byte. The cases that name a `/.vol` alias, a
//!   POSIX path's own spelling, a link, a FIFO or an unreadable mode are the
//!   macOS replay's (`crash_ledger_analyzer.rs`, `hilog_summary_analyzer.rs`).
//! * The real daemon over an isolated development root whose
//!   `ARKDECK_ANALYZER_PATH` names the daemon itself, holding a recorded
//!   Swift source Job's Artifacts: `analyzer.extract-crash-signature@1` and
//!   `analyzer.summarize-hilog@1` are available, submitted and run, and each
//!   publishes Swift's analysis of the source beside its identity as the
//!   derived Artifact; after a restart the Job and its Artifact read back
//!   and a resubmission is the same Job; the source is never rewritten. The
//!   ArkTrace analyzers are unavailable (no ArkTrace distribution loads on
//!   Windows, TASK-XPA-021). An analyzer path that is no executable refuses
//!   the start.
//!
//! Every daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root and its analyzer: nothing installed is read or
//! written, no HDC is configured, and no device or `hdc` is involved.
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

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn unbase64(text: &str) -> Vec<u8> {
    let digit = |byte: u8| match byte {
        b'A'..=b'Z' => byte - b'A',
        b'a'..=b'z' => byte - b'a' + 26,
        b'0'..=b'9' => byte - b'0' + 52,
        b'+' => 62,
        b'/' => 63,
        _ => panic!("not base64: {byte}"),
    };
    let mut bytes = Vec::new();
    for group in text.as_bytes().chunks(4) {
        let digits: Vec<u32> = group
            .iter()
            .filter(|byte| **byte != b'=')
            .map(|byte| u32::from(digit(*byte)))
            .collect();
        let value = digits
            .iter()
            .enumerate()
            .fold(0, |value, (index, digit)| value | digit << (18 - 6 * index));
        bytes.extend(&value.to_be_bytes()[1..digits.len()]);
    }
    bytes
}

/// A fresh directory below the temporary directory in its plain canonical
/// spelling, removed with what it holds.
struct Root(PathBuf);
impl Root {
    fn new(tag: &str) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winanalyzer-{tag}-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    /// A recorded Swift source Job's Artifacts, as the Swift engine published
    /// them: a private Artifact root, the index owner-only, each payload
    /// sealed; the recorded retention deadlines, which have passed, moved to
    /// a year no run reaches at their recorded length.
    fn with_source(self, recorded: &str) -> Self {
        let artifacts = HostDirectory::open_or_create_private(&self.0.join("artifacts")).unwrap();
        let job = artifacts.create_private_child("job-oracle-source").unwrap();
        for entry in std::fs::read_dir(fixture(recorded)).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_str().unwrap().to_owned();
            let mut bytes = std::fs::read(&path).unwrap();
            if name == "index.json" {
                let text = String::from_utf8(bytes).unwrap();
                let moved = text.replace("\"deadlineUTC\" : \"2026-", "\"deadlineUTC\" : \"2099-");
                assert_ne!(moved, text);
                bytes = moved.into_bytes();
            }
            job.create_document(&name, &bytes).unwrap();
            if name != "index.json" {
                job.seal_document(&name).unwrap();
            }
        }
        self
    }
    fn source(&self, artifact: &str) -> PathBuf {
        self.0
            .join("artifacts")
            .join("job-oracle-source")
            .join(artifact)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The daemon as the Runtime runs its analyzer child: no environment, no
/// stdin.
fn analyzer_child(arguments: &[String]) -> std::process::Output {
    Command::new(DAEMON)
        .env_clear()
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

/// Every recorded Swift case of `oracle` whose one argument is the input
/// file itself (on Windows its canonical path), and the usage refusals that
/// read no path, answered with Swift's exit status, stdout and stderr byte
/// for byte. The cases that name a `/.vol` alias, a POSIX path's own
/// spelling (a trailing solidus, `/`, combining marks), a link, a FIFO or an
/// unreadable mode are the macOS replay's.
fn replay(oracle: &Value, flag: &str, file: &str) -> usize {
    let root = Root::new("replay");
    let mut replayed = 0;
    for (index, case) in oracle["cases"].as_array().unwrap().iter().enumerate() {
        let name = case["name"].as_str().unwrap();
        let arguments: Vec<&str> = case["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| argument.as_str().unwrap())
            .collect();
        let readable = case["inputMode"]
            .as_u64()
            .is_none_or(|mode| mode & 0o400 != 0);
        // The macOS Runtime hands its child the input's `/.vol` alias
        // (`{inputVolume}`); on Windows it hands the canonical path.
        let reads_input = (arguments == [flag, "{input}"] || arguments == [flag, "{inputVolume}"])
            && case["input"].is_string()
            && readable;
        let usage = matches!(
            arguments.as_slice(),
            [only] if *only == flag
        ) || arguments == [flag, ""]
            || arguments == [flag, "{input}", "{input}"];
        if !(reads_input || usage) || case.get("extras") == Some(&json!(true)) {
            continue;
        }
        let directory = root.0.join(format!("case-{index}"));
        std::fs::create_dir(&directory).unwrap();
        let input = directory.join(file);
        if let Some(bytes) = case["input"].as_str() {
            std::fs::write(&input, unbase64(bytes)).unwrap();
        }
        let arguments: Vec<String> = arguments
            .iter()
            .map(|argument| {
                argument
                    .replace("{inputVolume}", input.to_str().unwrap())
                    .replace("{input}", input.to_str().unwrap())
            })
            .collect();
        let output = analyzer_child(&arguments);
        assert_eq!(
            output.status.code().map(i64::from),
            case["exitStatus"].as_i64(),
            "{name}: {output:?}"
        );
        assert_eq!(
            std::str::from_utf8(&output.stdout).unwrap(),
            case["stdout"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(
            std::str::from_utf8(&output.stderr).unwrap(),
            case["stderr"].as_str().unwrap(),
            "{name}"
        );
        replayed += 1;
    }
    replayed
}

#[test]
fn the_crash_ledger_mode_answers_every_recorded_listing_as_swift_s_daemon_did() {
    let oracle = document(fixture("crash-ledger-analyzer/oracle.json"));
    let replayed = replay(&oracle, "--analyze-crash-ledger", "crash-index.txt");
    assert_eq!(replayed, 67);
}

#[test]
fn the_hilog_summary_mode_answers_every_recorded_log_as_swift_s_daemon_did() {
    let oracle = document(fixture("hilog-summary-analyzer/oracle.json"));
    assert_eq!(
        oracle["schemaVersion"],
        "arkdeck.hilog-summary-analyzer-oracle/1"
    );
    let replayed = replay(&oracle, "--summarize-hilog", "hilog.txt");
    assert_eq!(replayed, 40);
}

/// The daemon over `root`, its own executable named as the analyzer.
fn start(root: &Path) -> Daemon {
    let mut command = daemon(Path::new(DAEMON), root);
    command.env("ARKDECK_ANALYZER_PATH", DAEMON);
    Daemon::spawn(command)
}

fn answered(pipe: &str, method: &str, params: Value) -> Value {
    let reply = request(pipe, method, params.clone());
    assert_eq!(reply["ok"], true, "{method} {params}: {reply}");
    reply["result"].clone()
}

/// The derived Artifact `name` of `job`, read whole.
fn derived(pipe: &str, job: &str, name: &str) -> Value {
    let owner = json!({"kind": "job", "id": job});
    let listed = answered(pipe, "artifact.list", json!({"owner": owner}));
    let item = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == name)
        .unwrap_or_else(|| panic!("{listed}"))
        .clone();
    let read = answered(
        pipe,
        "artifact.read",
        json!({"owner": owner, "artifactId": item["artifactId"]}),
    );
    assert_eq!(read["eof"], true, "{read}");
    serde_json::from_slice(&unbase64(read["base64"].as_str().unwrap())).unwrap()
}

#[test]
fn the_runtime_runs_the_daemon_as_its_own_crash_ledger_analyzer_across_a_restart() {
    let _turn = turn();
    let oracle = document(fixture("crash-ledger-analyzer/oracle.json"));
    let expected = oracle["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "runtime-fixture-source")
        .unwrap()
        .clone();
    let root = Root::new("crash").with_source("job-reconcile-analyzer/artifacts/job-oracle-source");
    let jobs = document(fixture("job-reconcile-analyzer/jobs.json"));
    let submit = jobs
        .as_array()
        .unwrap()
        .iter()
        .find(|job| job["name"] == "succeeded")
        .unwrap()["submit"]
        .clone();
    let request_json: Value =
        serde_json::from_str(submit["requestJson"].as_str().unwrap()).unwrap();
    let lease = request_json["inputs"]["sourceArtifactRef"]
        .as_str()
        .unwrap();
    let source_id = lease.rsplit(':').next().unwrap().to_owned();
    let raw = root.source(&source_id);
    let raw_bytes = std::fs::read(&raw).unwrap();
    assert_eq!(raw_bytes, unbase64(expected["input"].as_str().unwrap()));

    let mut first = start(&root.0);
    let pipe = first.serving();
    let described = answered(
        &pipe,
        "operation.describe",
        json!({"reference": "analyzer.extract-crash-signature@1"}),
    );
    assert_eq!(described["availability"], "available", "{described}");
    let accepted = answered(&pipe, "job.submit", submit.clone());
    let job = accepted["jobId"].as_str().unwrap().to_owned();
    let finished = answered(&pipe, "job.run", json!({"jobId": job}));
    assert_eq!(finished["state"], "succeeded", "{finished}");
    let analysis = expected["stdout"].as_str().unwrap();
    let envelope = json!({
        "schemaVersion": "1.0.0",
        "analyzerRef": "crash-signature@1",
        "analyzerVersion": "arkdeck-fault-log-ledger@1",
        "sourceArtifactID": source_id,
        "sourceSHA256": arkdeck_contract::sha256_hex(&raw_bytes),
        "sourceByteCount": raw_bytes.len(),
        "analyzerOutputSHA256": arkdeck_contract::sha256_hex(analysis.as_bytes()),
        "analyzerOutputByteCount": analysis.len(),
        "result": serde_json::from_str::<Value>(analysis).unwrap(),
    });
    assert_eq!(derived(&pipe, &job, "crash-signature.json"), envelope);
    first.stop(&root.0);

    // After a restart: the Job's state and its derived Artifact read back,
    // and a resubmission is the recorded Job.
    let mut second = start(&root.0);
    let pipe = second.serving();
    let status = answered(&pipe, "job.status", json!({"jobId": job}));
    assert_eq!(status["state"], "succeeded", "{status}");
    assert_eq!(derived(&pipe, &job, "crash-signature.json"), envelope);
    let again = answered(&pipe, "job.submit", submit);
    assert_eq!(again["jobId"], json!(job), "{again}");
    second.stop(&root.0);
    // The source was read, never rewritten.
    assert_eq!(std::fs::read(&raw).unwrap(), raw_bytes);
}

#[test]
fn the_runtime_runs_the_daemon_as_its_own_hilog_summary_analyzer() {
    let _turn = turn();
    let root = Root::new("hilog").with_source("job-run-hilog/artifacts/job-oracle-source");
    let cases = document(fixture("job-run-hilog/cases.json"));
    let case = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "answered")
        .unwrap();
    let recorded_job = case["params"]["jobId"].as_str().unwrap();
    let directory = fixture("job-run-hilog/artifacts").join(recorded_job);
    let payload = std::fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.file_name().unwrap() != "index.json")
        .unwrap();
    let summary = document(payload)["result"].clone();

    let mut daemon = start(&root.0);
    let pipe = daemon.serving();
    let described = answered(
        &pipe,
        "operation.describe",
        json!({"reference": "analyzer.summarize-hilog@1"}),
    );
    assert_eq!(described["availability"], "available", "{described}");
    let accepted = answered(&pipe, "job.submit", case["submit"].clone());
    let job = accepted["jobId"].as_str().unwrap().to_owned();
    let finished = answered(&pipe, "job.run", json!({"jobId": job}));
    assert_eq!(finished["state"], "succeeded", "{finished}");
    let printed = serde_json::to_vec(&summary).unwrap();
    assert_eq!(
        derived(&pipe, &job, "hilog-summary.json"),
        json!({
            "sourceArtifactID": "ART-bfdf1c6973a8e0f2917400119782e8c5",
            "analyzerExecutableSHA256": arkdeck_contract::sha256_hex(&std::fs::read(DAEMON).unwrap()),
            "analyzerOutputSHA256": arkdeck_contract::sha256_hex(&printed),
            "analyzerOutputByteCount": printed.len(),
            "result": summary,
        })
    );
    // The two ArkTrace analyzers are unavailable: no ArkTrace distribution
    // loads on Windows (TASK-XPA-021).
    for reference in ["analyzer.summarize-trace@1", "analyzer.analyze-trace@1"] {
        let described = answered(&pipe, "operation.describe", json!({"reference": reference}));
        assert_ne!(described["availability"], "available", "{described}");
    }
    daemon.stop(&root.0);
}

#[test]
fn an_analyzer_path_that_is_no_executable_refuses_the_start() {
    let _turn = turn();
    let root = Root::new("refused");
    let not_executable = root.0.join("analyzer.txt");
    std::fs::write(&not_executable, b"not a program").unwrap();
    let mut command = daemon(Path::new(DAEMON), &root.0);
    command.env("ARKDECK_ANALYZER_PATH", &not_executable);
    let output = command.output().unwrap();
    assert_eq!(output.status.code(), Some(69), "{output:?}");
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(
        stderr.contains("ARKDECK_ANALYZER_PATH") && stderr.contains("nothing was started"),
        "{stderr}"
    );
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
    #[allow(dead_code)]
    fn start(executable: &Path, root: &Path) -> Self {
        Self::spawn(daemon(executable, root))
    }

    fn spawn(mut command: Command) -> Self {
        let mut child = command.spawn().unwrap();
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
