//! `arkdeck-agentd --analyze-crash-ledger`, replayed against what the Swift
//! daemon answered (`rust/tests/fixtures/crash-ledger-analyzer/oracle.json`,
//! recorded by `CrashLedgerAnalyzerOracleContractTests`): every case through
//! the built daemon with an empty environment and no stdin, as the Runtime
//! runs its analyzer child, answered with the same exit status, stdout and
//! stderr byte for byte, and a read failure's line by Swift's prefix. Then the
//! daemon as its own analyzer: an isolated Runtime whose
//! `ARKDECK_ANALYZER_PATH` names it runs `analyzer.extract-crash-signature@1`
//! and publishes Swift's analysis beside the source's identity, the source
//! untouched. Host only: no HDC, no Swift daemon, no device.
#![cfg(target_os = "macos")]

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
const FAILED: &str = "crash-ledger analysis failed: ";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn oracle() -> Value {
    serde_json::from_slice(&fs::read(fixture("crash-ledger-analyzer/oracle.json")).unwrap())
        .unwrap()
}

fn case<'a>(oracle: &'a Value, name: &str) -> &'a Value {
    oracle["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == name)
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
            "/private/tmp/arkdeck-crash-ledger-{tag}-{:032x}",
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

    /// Every entry below the directory, by relative path.
    fn entries(&self) -> Vec<PathBuf> {
        let mut entries = Vec::new();
        let mut pending = vec![self.0.clone()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    pending.push(path.clone());
                }
                entries.push(path.strip_prefix(&self.0).unwrap().to_path_buf());
            }
        }
        entries.sort();
        entries
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

#[test]
fn every_case_is_answered_as_the_swift_daemon_answered_it() {
    let oracle = oracle();
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
        let input = directory.join("crash-index.txt");
        let mut volume = String::new();
        if let Some(bytes) = case["input"].as_str() {
            fs::write(&input, unbase64(bytes)).unwrap();
            let metadata = fs::metadata(&input).unwrap();
            volume = format!("/.vol/{}/{}", metadata.dev(), metadata.ino());
            let mode = case["inputMode"].as_u64().unwrap() as u32;
            fs::set_permissions(&input, fs::Permissions::from_mode(mode)).unwrap();
        }
        let arguments: Vec<String> = case["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| {
                argument
                    .as_str()
                    .unwrap()
                    .replace("{inputVolume}", &volume)
                    .replace("{input}", &text(&input))
                    .replace("{directory}", &text(&directory))
                    .replace("{missing}", &text(&directory.join("absent.txt")))
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
        let stderr = String::from_utf8(output.stderr).unwrap();
        if case["stderrIsPrefix"] == true {
            // Swift's Foundation text goes on to name the path; this line
            // names only the error.
            let error = stderr.strip_prefix(case["stderr"].as_str().unwrap());
            assert!(
                error.is_some_and(|error| error.len() > 1
                    && error.ends_with('\n')
                    && error.lines().count() == 1),
                "{name}: {stderr}"
            );
            assert!(!stderr.contains(&text(&scratch.0)), "{name}: {stderr}");
        } else {
            assert_eq!(stderr, case["stderr"].as_str().unwrap(), "{name}");
        }
        fs::set_permissions(&input, fs::Permissions::from_mode(0o600)).ok();
        replayed += 1;
    }
    assert!(replayed >= 77, "{replayed}");
}

#[test]
fn the_mode_is_answered_before_anything_a_daemon_does() {
    let oracle = oracle();
    let expected = case(&oracle, "one-native-crash");
    let scratch = Scratch::new("first");
    let home = scratch.directory("home");
    let input = scratch.0.join("crash-index.txt");
    fs::write(&input, unbase64(expected["input"].as_str().unwrap())).unwrap();
    let before = scratch.entries();

    // Whatever composition the environment would ask for, and under the
    // facade's name too, the mode answers first and nothing else happens.
    let facade = scratch.0.join("arkdeck-facade");
    fs::hard_link(DAEMON, &facade)
        .or_else(|_| fs::copy(DAEMON, &facade).map(drop))
        .unwrap();
    let before = {
        let mut entries = before;
        entries.push(PathBuf::from("arkdeck-facade"));
        entries.sort();
        entries
    };
    for executable in [Path::new(DAEMON), facade.as_path()] {
        let output = analyzer(executable)
            .arg("--analyze-crash-ledger")
            .arg(&input)
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("ARKDECK_RUNTIME_COMPOSITION", "production")
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", "relative")
            .env("ARKDECK_ENDPOINT", scratch.0.join("control.sock"))
            .env("ARKDECK_SWIFT_DAEMON", "/nonexistent")
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert_eq!(
            std::str::from_utf8(&output.stdout).unwrap(),
            expected["stdout"].as_str().unwrap()
        );
        assert!(output.stderr.is_empty(), "{output:?}");
        assert_eq!(scratch.entries(), before);
    }

    // An argument that only resembles the mode is the daemon's to refuse,
    // before it reads or composes anything.
    for arguments in [
        vec![text(&input), "--analyze-crash-ledger".to_owned()],
        vec!["--analyze-crash-ledgers".to_owned(), text(&input)],
        vec!["--ANALYZE-CRASH-LEDGER".to_owned(), text(&input)],
    ] {
        let output = analyzer(Path::new(DAEMON))
            .args(&arguments)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        assert!(output.stdout.is_empty());
        assert!(
            String::from_utf8(output.stderr)
                .unwrap()
                .contains("takes no device, command, path or authority arguments")
        );
        assert_eq!(scratch.entries(), before);
    }
}

#[test]
fn an_answer_that_cannot_be_delivered_fails_with_a_line() {
    let oracle = oracle();
    let expected = case(&oracle, "one-native-crash");
    let scratch = Scratch::new("stdout");
    let input = scratch.0.join("crash-index.txt");
    fs::write(&input, unbase64(expected["input"].as_str().unwrap())).unwrap();
    // A stdout opened only for reading, and a pipe nobody reads: every write
    // to either fails.
    let unwritable = scratch.0.join("stdout");
    fs::write(&unwritable, b"").unwrap();
    let (reader, writer) = std::io::pipe().unwrap();
    drop(reader);
    for stdout in [
        Stdio::from(fs::File::open(&unwritable).unwrap()),
        Stdio::from(writer),
    ] {
        let output = analyzer(Path::new(DAEMON))
            .arg("--analyze-crash-ledger")
            .arg(&input)
            .stdout(stdout)
            .stderr(Stdio::piped())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(
            stderr.starts_with(FAILED) && stderr.ends_with('\n') && stderr.lines().count() == 1,
            "{stderr}"
        );
        assert!(!stderr.contains(&text(&scratch.0)), "{stderr}");
    }
    assert_eq!(fs::read(&unwritable).unwrap(), b"");
}

// MARK: - The daemon as its own analyzer

/// The isolated daemon over `root`, its own executable named as the analyzer.
struct Runtime(Child);

impl Runtime {
    fn start(root: &Path) -> Self {
        let mut command = Command::new(DAEMON);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_ENDPOINT", root.join("control.sock"))
            .env("ARKDECK_ANALYZER_PATH", DAEMON)
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

/// One control frame, answered with its result.
fn request(root: &Path, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(root.join("control.sock")).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(120)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "crash-ledger-analyzer", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    let answer: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(answer["ok"], true, "{method}: {answer}");
    answer["result"].clone()
}

/// The reconcile oracle's analyzer source, seeded as the Swift engine
/// published it, and the Job Swift's run analyzed to success.
struct Seeded {
    submit: Value,
    lease: String,
    target: String,
    source_id: String,
    raw: PathBuf,
    raw_bytes: Vec<u8>,
}

fn seed(scratch: &Scratch, expected: &Value) -> Seeded {
    let source = fixture("job-reconcile-analyzer/artifacts/job-oracle-source");
    let artifacts = scratch.directory("artifacts");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(artifacts.join("job-oracle-source"))
        .unwrap();
    for file in fs::read_dir(&source).unwrap() {
        let file = file.unwrap().path();
        let name = file.file_name().unwrap();
        let copied = artifacts.join("job-oracle-source").join(name);
        let mut bytes = fs::read(&file).unwrap();
        if name == "index.json" {
            // The recorded retention deadlines have passed, and a start sweeps
            // lapsed Artifacts: the seeded copy's move to a year no run
            // reaches, at their recorded length (`fixture-deadlines.py`).
            let recorded = String::from_utf8(bytes).unwrap();
            let moved = recorded.replace("\"deadlineUTC\" : \"2026-", "\"deadlineUTC\" : \"2099-");
            assert_ne!(moved, recorded);
            bytes = moved.into_bytes();
        }
        fs::write(&copied, bytes).unwrap();
        let mode = if name == "index.json" { 0o600 } else { 0o400 };
        fs::set_permissions(&copied, fs::Permissions::from_mode(mode)).unwrap();
    }
    scratch.directory("jobs-state");
    let jobs: Value =
        serde_json::from_slice(&fs::read(fixture("job-reconcile-analyzer/jobs.json")).unwrap())
            .unwrap();
    // The Job whose source Swift's run analyzed to success.
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
        .unwrap()
        .to_owned();
    let target = request_json["target"]["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let source_id = lease.rsplit(':').next().unwrap().to_owned();
    let raw = artifacts.join("job-oracle-source").join(&source_id);
    let raw_bytes = fs::read(&raw).unwrap();
    assert_eq!(raw_bytes, unbase64(expected["input"].as_str().unwrap()));
    Seeded {
        submit,
        lease,
        target,
        source_id,
        raw,
        raw_bytes,
    }
}

impl Seeded {
    /// The Job's derived Artifact is Swift's analysis of these bytes, with
    /// the identity of the bytes it read, and the raw source is read, never
    /// rewritten.
    fn assert_published(&self, root: &Path, job: &str, expected: &Value) {
        let owner = json!({"kind": "job", "id": job});
        let listed = request(root, "artifact.list", json!({"owner": owner}));
        let derived = listed["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["name"] == "crash-signature.json")
            .unwrap_or_else(|| panic!("{listed}"));
        let read = request(
            root,
            "artifact.read",
            json!({"owner": owner, "artifactId": derived["artifactId"]}),
        );
        assert_eq!(read["eof"], true);
        let envelope: Value =
            serde_json::from_slice(&unbase64(read["base64"].as_str().unwrap())).unwrap();
        let analysis = expected["stdout"].as_str().unwrap();
        assert_eq!(
            envelope,
            json!({
                "schemaVersion": "1.0.0",
                "analyzerRef": "crash-signature@1",
                "analyzerVersion": "arkdeck-fault-log-ledger@1",
                "sourceArtifactID": self.source_id,
                "sourceSHA256": arkdeck_contract::sha256_hex(&self.raw_bytes),
                "sourceByteCount": self.raw_bytes.len(),
                "analyzerOutputSHA256": arkdeck_contract::sha256_hex(analysis.as_bytes()),
                "analyzerOutputByteCount": analysis.len(),
                "result": serde_json::from_str::<Value>(analysis).unwrap(),
            })
        );
        assert_eq!(fs::read(&self.raw).unwrap(), self.raw_bytes);
        assert_eq!(
            fs::metadata(&self.raw).unwrap().permissions().mode() & 0o777,
            0o400
        );
    }
}

#[test]
fn the_runtime_runs_the_daemon_as_its_own_crash_ledger_analyzer() {
    let oracle = oracle();
    let expected = case(&oracle, "runtime-fixture-source");
    let scratch = Scratch::new("runtime");
    let root = &scratch.0;
    let seeded = seed(&scratch, expected);

    let _runtime = Runtime::start(root);
    let accepted = request(root, "job.submit", seeded.submit.clone());
    let job = accepted["jobId"].as_str().unwrap().to_owned();
    let finished = request(root, "job.run", json!({"jobId": job}));
    assert_eq!(finished["state"], "succeeded", "{finished}");
    seeded.assert_published(root, &job, expected);
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
        "id": "crash-ledger-analyzer", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// An agent execution of the analyzer runs its owned Job to its end, as
/// Swift's `startJob` runs it with the engine that admitted it: the
/// background run is composed with the same analyzer as the admission, so the
/// execution completes instead of owning a Job no run can finish (its journal
/// already past `steps-start`, its record still `preflight`, so no later
/// `job.run` could take it either).
#[test]
fn an_agent_execution_of_the_analyzer_runs_its_job_to_the_end() {
    let oracle = oracle();
    let expected = case(&oracle, "runtime-fixture-source");
    let scratch = Scratch::new("agent");
    let root = &scratch.0;
    let seeded = seed(&scratch, expected);

    let _runtime = Runtime::start(root);
    let execution = "analyzer-execution";
    let owned = request(
        root,
        "agent.run",
        json!({
            "schemaVersion": "arkdeck.agent-execution-request/1",
            "executionId": execution,
            "operation": "analyzer.extract-crash-signature@1",
            "inputs": {"sourceArtifactRef": seeded.lease},
            "target": {"targetId": seeded.target},
            "maximumWaitMilliseconds": "300000",
        }),
    );
    assert_eq!(owned["state"], "jobOwned", "{owned}");
    let job = owned["jobId"].as_str().unwrap().to_owned();
    // The execution's durable record ends once the run reports the Job's
    // end (Swift `finishJob`). A client reading the execution waits for
    // that end, so an end that never comes keeps `agent run` waiting
    // forever: the wait here is bounded instead.
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
        assert!(
            Instant::now() < deadline,
            "the execution never ended; its Job is {}: {}",
            exchange(root, "job.status", json!({"jobId": job}))["result"]["state"],
            stored
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(stored["state"], "completed", "{stored}");
    assert_eq!(stored["jobID"], job.as_str(), "{stored}");
    assert_eq!(stored["jobState"], "succeeded", "{stored}");
    assert_eq!(stored["outcomeUnknown"], false, "{stored}");
    let status = request(root, "job.status", json!({"jobId": job}));
    assert_eq!(status["state"], "succeeded", "{status}");
    assert_eq!(status["outcomeUnknown"], false, "{status}");
    seeded.assert_published(root, &job, expected);
    // The finished Job is never run again.
    let refused = exchange(root, "job.run", json!({"jobId": job}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "resourceConflict", "{refused}");
}
