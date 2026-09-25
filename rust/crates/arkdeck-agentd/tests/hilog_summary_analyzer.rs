//! `arkdeck-agentd --summarize-hilog`, replayed against what the Swift daemon
//! answered (`rust/tests/fixtures/hilog-summary-analyzer/oracle.json`,
//! recorded by `HilogSummaryAnalyzerOracleContractTests`): every case through
//! the built daemon with an empty environment and no stdin, as the Runtime
//! runs its analyzer child, over the same files, links and FIFO Swift was
//! given, answered with the same exit status, stdout and stderr byte for
//! byte. Then the mode is shown to come before anything a daemon does. Host
//! only: no HDC, no Swift daemon, no device.
#![cfg(target_os = "macos")]

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt, symlink};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
const READ_FAILED: &str = "analyzer.hilogReadFailed\n";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn oracle() -> Value {
    serde_json::from_slice(&fs::read(fixture("hilog-summary-analyzer/oracle.json")).unwrap())
        .unwrap()
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

/// A private directory below `/private/tmp`, removed with what it holds.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-hilog-summary-{tag}-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }

    fn directory(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The daemon with no environment and no stdin, as the Runtime runs its
/// analyzer child.
fn analyzer(executable: &Path) -> Command {
    let mut command = Command::new(executable);
    command.env_clear().stdin(Stdio::null());
    command
}

fn text(path: &Path) -> String {
    path.to_str().unwrap().to_owned()
}

/// A FIFO beside the input, owner read-write, as Swift's `mkfifo` makes it.
fn fifo(path: &Path) {
    let status = Command::new("/usr/bin/mkfifo")
        .arg("-m")
        .arg("600")
        .arg(path)
        .status()
        .unwrap();
    assert!(status.success(), "{}", path.display());
}

#[test]
fn every_case_is_answered_as_the_swift_daemon_answered_it() {
    let oracle = oracle();
    assert_eq!(
        oracle["schemaVersion"],
        "arkdeck.hilog-summary-analyzer-oracle/1"
    );
    let scratch = Scratch::new("replay");
    // A process running as root reads a file whatever its mode.
    let privileged = arkdeck_platform::effective_user_id() == 0;
    let mut replayed = 0;
    for (index, case) in oracle["cases"].as_array().unwrap().iter().enumerate() {
        let name = case["name"].as_str().unwrap();
        if privileged && name == "read-unreadable-file" {
            continue;
        }
        let directory = scratch.directory(&format!("case-{index}"));
        let input = directory.join("hilog.txt");
        let (mut device, mut inode) = (String::new(), String::new());
        if let Some(bytes) = case["input"].as_str() {
            fs::write(&input, unbase64(bytes)).unwrap();
            let metadata = fs::metadata(&input).unwrap();
            device = (metadata.dev() as u32).to_string();
            inode = metadata.ino().to_string();
            let mode = case["inputMode"].as_u64().unwrap() as u32;
            fs::set_permissions(&input, fs::Permissions::from_mode(mode)).unwrap();
        }
        let listed = fs::metadata(&directory).unwrap();
        if case["extras"] == true {
            symlink("hilog.txt", directory.join("link.txt")).unwrap();
            fifo(&directory.join("fifo"));
        }
        let substitutions = [
            ("{inputVolume}", format!("/.vol/{device}/{inode}")),
            (
                "{inputViaTmp}",
                text(&input).strip_prefix("/private").unwrap().to_owned(),
            ),
            ("{input}", text(&input)),
            ("{device}", device.clone()),
            ("{inode}", inode.clone()),
            ("{directoryDevice}", (listed.dev() as u32).to_string()),
            ("{directoryInode}", listed.ino().to_string()),
            ("{directory}", text(&directory)),
            ("{missing}", text(&directory.join("absent.txt"))),
            ("{link}", text(&directory.join("link.txt"))),
            ("{fifo}", text(&directory.join("fifo"))),
        ];
        let arguments: Vec<String> = case["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| {
                substitutions
                    .iter()
                    .fold(argument.as_str().unwrap().to_owned(), |text, (from, to)| {
                        text.replace(from, to)
                    })
            })
            .collect();
        let output = analyzer(Path::new(DAEMON))
            .args(&arguments)
            .output()
            .unwrap();
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
        fs::set_permissions(&input, fs::Permissions::from_mode(0o600)).ok();
        replayed += 1;
    }
    assert!(replayed >= 60, "{replayed}");
}

#[test]
fn the_mode_is_answered_before_anything_a_daemon_does() {
    let oracle = oracle();
    let expected = oracle["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "mixed-document")
        .unwrap();
    let scratch = Scratch::new("first");
    let home = scratch.directory("home");
    let input = scratch.0.join("hilog.txt");
    fs::write(&input, unbase64(expected["input"].as_str().unwrap())).unwrap();
    let entries = || {
        let mut entries: Vec<PathBuf> = walk(&scratch.0);
        entries.sort();
        entries
    };
    let facade = scratch.0.join("arkdeck-facade");
    fs::hard_link(DAEMON, &facade)
        .or_else(|_| fs::copy(DAEMON, &facade).map(drop))
        .unwrap();
    let before = entries();
    // Whatever composition the environment would ask for, and under the
    // facade's name too, the mode answers first and nothing else happens.
    for executable in [Path::new(DAEMON), facade.as_path()] {
        let output = analyzer(executable)
            .arg("--summarize-hilog")
            .arg(&input)
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("ARKDECK_RUNTIME_COMPOSITION", "production")
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", "relative")
            .env("ARKDECK_ENDPOINT", scratch.0.join("control.sock"))
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert_eq!(
            std::str::from_utf8(&output.stdout).unwrap(),
            expected["stdout"].as_str().unwrap()
        );
        assert!(output.stderr.is_empty(), "{output:?}");
        assert_eq!(entries(), before);
    }
    // An answer that cannot be delivered fails with the mode's one line.
    let unwritable = scratch.0.join("unwritable");
    fs::write(&unwritable, b"").unwrap();
    let output = analyzer(Path::new(DAEMON))
        .arg("--summarize-hilog")
        .arg(&input)
        .stdout(fs::File::open(&unwritable).unwrap())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    assert_eq!(output.stderr, READ_FAILED.as_bytes());
}

fn walk(root: &Path) -> Vec<PathBuf> {
    let mut entries = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path.clone());
            }
            entries.push(path.strip_prefix(root).unwrap().to_path_buf());
        }
    }
    entries
}

// MARK: - The daemon as its own HiLog analyzer

/// The isolated daemon over `root`, `analyzer` named as its analyzer.
struct Runtime(Child);

impl Runtime {
    fn start(root: &Path, analyzer: &Path) -> Self {
        let mut command = Command::new(DAEMON);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_ENDPOINT", root.join("control.sock"))
            .env("ARKDECK_ANALYZER_PATH", analyzer)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(root.join("control.sock")).is_err() {
            assert!(child.try_wait().unwrap().is_none(), "daemon exited");
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// One control frame, answered as the daemon answered it.
fn exchange(root: &Path, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(root.join("control.sock")).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(120)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "hilog-summary-analyzer", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn request(root: &Path, method: &str, params: Value) -> Value {
    let answer = exchange(root, method, params);
    assert_eq!(answer["ok"], true, "{method}: {answer}");
    answer["result"].clone()
}

/// The HiLog sources of the Swift Job oracle (`job-run-hilog`), seeded as
/// the Swift engine published them, with retention deadlines no start sweeps
/// (`fixture-deadlines.py`).
fn seed(scratch: &Scratch) {
    let artifacts = scratch.directory("artifacts");
    let seeded = artifacts.join("job-oracle-source");
    fs::DirBuilder::new().mode(0o700).create(&seeded).unwrap();
    for file in fs::read_dir(fixture("job-run-hilog/artifacts/job-oracle-source")).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let mut bytes = fs::read(&file).unwrap();
        if name == "index.json" {
            let recorded = String::from_utf8(bytes).unwrap();
            let moved = recorded.replace("\"deadlineUTC\" : \"2026-", "\"deadlineUTC\" : \"2099-");
            assert_ne!(moved, recorded);
            bytes = moved.into_bytes();
        }
        fs::write(seeded.join(name), bytes).unwrap();
        let mode = if name == "index.json" { 0o600 } else { 0o400 };
        fs::set_permissions(seeded.join(name), fs::Permissions::from_mode(mode)).unwrap();
    }
    scratch.directory("jobs-state");
}

/// The Swift oracle's first Job request, and the summary Swift published
/// for its source: the recorded envelope's result.
fn answered() -> (Value, Value) {
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture("job-run-hilog/cases.json")).unwrap()).unwrap();
    let case = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "answered")
        .unwrap();
    let job = case["params"]["jobId"].as_str().unwrap();
    let directory = fixture("job-run-hilog/artifacts").join(job);
    let payload = fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.file_name().unwrap() != "index.json")
        .unwrap();
    let envelope: Value = serde_json::from_slice(&fs::read(payload).unwrap()).unwrap();
    (case["submit"].clone(), envelope["result"].clone())
}

/// The derived `hilog-summary.json` of `job`: Swift's summary of the source,
/// beside the executable that produced it (this daemon) and the digest of
/// what it printed.
fn assert_published(root: &Path, job: &str, summary: &Value) {
    let owner = json!({"kind": "job", "id": job});
    let listed = request(root, "artifact.list", json!({"owner": owner}));
    let derived = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == "hilog-summary.json")
        .unwrap_or_else(|| panic!("{listed}"));
    let read = request(
        root,
        "artifact.read",
        json!({"owner": owner, "artifactId": derived["artifactId"]}),
    );
    let envelope: Value =
        serde_json::from_slice(&unbase64(read["base64"].as_str().unwrap())).unwrap();
    let printed = serde_json::to_vec(summary).unwrap();
    assert_eq!(
        envelope,
        json!({
            "sourceArtifactID": "ART-bfdf1c6973a8e0f2917400119782e8c5",
            "analyzerExecutableSHA256": arkdeck_contract::sha256_hex(&fs::read(DAEMON).unwrap()),
            "analyzerOutputSHA256": arkdeck_contract::sha256_hex(&printed),
            "analyzerOutputByteCount": printed.len(),
            "result": summary,
        })
    );
}

#[test]
fn the_runtime_runs_the_daemon_as_its_own_hilog_summary_analyzer() {
    let scratch = Scratch::new("runtime");
    let root = &scratch.0;
    seed(&scratch);
    let (submit, summary) = answered();
    let _runtime = Runtime::start(root, Path::new(DAEMON));
    let described = request(
        root,
        "operation.describe",
        json!({"reference": "analyzer.summarize-hilog@1"}),
    );
    assert_eq!(described["availability"], "available", "{described}");
    let accepted = request(root, "job.submit", submit);
    let job = accepted["jobId"].as_str().unwrap().to_owned();
    let finished = request(root, "job.run", json!({"jobId": job}));
    assert_eq!(finished["state"], "succeeded", "{finished}");
    assert_published(root, &job, &summary);

    // The same request through an agent execution runs its Job to the end.
    let request_json: Value =
        serde_json::from_str(answered().0["requestJson"].as_str().unwrap()).unwrap();
    let execution = "hilog-execution";
    let owned = request(
        root,
        "agent.run",
        json!({
            "schemaVersion": "arkdeck.agent-execution-request/1",
            "executionId": execution,
            "operation": "analyzer.summarize-hilog@1",
            "inputs": request_json["inputs"],
            "target": {"targetId": request_json["target"]["targetId"]},
            "maximumWaitMilliseconds": "300000",
        }),
    );
    let job = owned["jobId"].as_str().unwrap().to_owned();
    let record = root.join("agent-executions").join(format!(
        "execution-{}.json",
        arkdeck_contract::sha256_hex(execution.as_bytes())
    ));
    let deadline = Instant::now() + Duration::from_secs(60);
    let stored = loop {
        let stored: Value = serde_json::from_slice(&fs::read(&record).unwrap()).unwrap();
        if stored["state"] != "jobOwned" {
            break stored;
        }
        assert!(Instant::now() < deadline, "{stored}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(stored["state"], "completed", "{stored}");
    assert_eq!(stored["jobState"], "succeeded", "{stored}");
    assert_published(root, &job, &summary);
}

#[test]
fn another_analyzer_executable_is_no_hilog_producer() {
    let scratch = Scratch::new("other");
    let root = &scratch.0;
    seed(&scratch);
    // The crash-ledger analyzer is any executable a host names; the HiLog
    // summary only this daemon's own bytes.
    let other = scratch.0.join("analyzer");
    fs::write(&other, b"#!/bin/sh\nexit 64\n").unwrap();
    fs::set_permissions(&other, fs::Permissions::from_mode(0o700)).unwrap();
    let _runtime = Runtime::start(root, &other);
    let described = request(
        root,
        "operation.describe",
        json!({"reference": "analyzer.summarize-hilog@1"}),
    );
    assert_eq!(described["availability"], "unavailable", "{described}");
    assert_eq!(
        described["availabilityReasons"],
        json!(["analyzer.hilogRequiresCurrentDaemon"])
    );
    let refused = exchange(root, "job.plan", answered().0);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "invalidInput");
    assert_eq!(
        refused["error"]["message"],
        "analyzer.summarize-hilog@1 is runtime unavailable: analyzer.hilogRequiresCurrentDaemon"
    );
    assert!(
        !root.join("jobs-state/jobs").exists()
            || fs::read_dir(root.join("jobs-state/jobs"))
                .unwrap()
                .next()
                .is_none()
    );
}
