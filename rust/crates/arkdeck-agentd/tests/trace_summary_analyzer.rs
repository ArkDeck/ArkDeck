//! The daemon's own composition of the ArkTrace analyzers from
//! `ARKDECK_ARKTRACE_DESCRIPTOR`: a descriptor that does not load leaves both
//! unavailable for the loader's reason, and — on a host with a reviewed,
//! signed and notarized distribution (`ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR`)
//! and Swift's recording of its summary of the repository's `zlib.htrace`
//! (`ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT`, from
//! `ArkTraceReviewedDistributionOracleContractTests`) — a descriptor that
//! loads makes `analyzer.summarize-trace@1` available, and a Job of it, run
//! directly and through an agent execution, publishes the bytes Swift
//! published. Host only: no HDC, no Swift daemon, no device.
#![cfg(target_os = "macos")]

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");

/// A private directory below `/private/tmp`, removed with what it holds.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-trace-summary-{tag}-{:032x}",
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

/// The isolated daemon over `root`, with `descriptor` named as its ArkTrace
/// distribution descriptor and no analyzer executable.
struct Runtime(Child);

impl Runtime {
    fn start(root: &Path, descriptor: &Path) -> Self {
        let mut command = Command::new(DAEMON);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_ENDPOINT", root.join("control.sock"))
            .env("ARKDECK_ARKTRACE_DESCRIPTOR", descriptor)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        // A descriptor that loads runs the reviewed CLI's self-test first.
        let deadline = Instant::now() + Duration::from_secs(60);
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
        "id": "trace-summary-analyzer", "method": method, "params": params}))
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

/// A named descriptor is read and loaded at the start: a malformed one
/// leaves both ArkTrace analyzers unavailable as `analyzer.arktraceDescriptorInvalid`,
/// not as the `analyzer.arktraceNotFound` of a daemon that names none.
#[test]
fn a_named_descriptor_that_does_not_load_names_the_loader_s_reason() {
    let scratch = Scratch::new("malformed");
    let root = &scratch.0;
    let descriptor = root.join("arktrace-descriptor.json");
    fs::write(&descriptor, "{}").unwrap();
    fs::set_permissions(&descriptor, fs::Permissions::from_mode(0o600)).unwrap();
    let _runtime = Runtime::start(root, &descriptor);
    for reference in ["analyzer.summarize-trace@1", "analyzer.analyze-trace@1"] {
        let described = request(root, "operation.describe", json!({"reference": reference}));
        assert_eq!(described["availability"], "unavailable", "{described}");
        assert_eq!(
            described["availabilityReasons"],
            json!(["analyzer.arktraceDescriptorInvalid"]),
            "{described}"
        );
    }
}

/// The source Swift published, with retention deadlines no start sweeps.
fn seed(scratch: &Scratch, recorded: &Path) {
    let artifacts = scratch.directory("artifacts");
    let seeded = artifacts.join("job-reviewed-source");
    fs::DirBuilder::new().mode(0o700).create(&seeded).unwrap();
    for file in fs::read_dir(recorded.join("artifacts/job-reviewed-source")).unwrap() {
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

/// The published `trace-summary.json` of `job`: its bytes as a read of it
/// answers them.
fn published(root: &Path, job: &str) -> Vec<u8> {
    let owner = json!({"kind": "job", "id": job});
    let listed = request(root, "artifact.list", json!({"owner": owner}));
    let derived = listed["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == "trace-summary.json")
        .unwrap_or_else(|| panic!("{listed}"));
    let read = request(
        root,
        "artifact.read",
        json!({"owner": owner, "artifactId": derived["artifactId"]}),
    );
    unbase64(read["base64"].as_str().unwrap())
}

#[test]
fn a_reviewed_distribution_summarizes_the_fixture_trace_on_the_daemon_as_swift_did() {
    let (Some(descriptor), Some(recorded)) = (
        std::env::var_os("ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"),
        std::env::var_os("ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT"),
    ) else {
        eprintln!(
            "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_JOB_SWIFT"
        );
        return;
    };
    let recorded = PathBuf::from(recorded);
    let scratch = Scratch::new("reviewed");
    let root = &scratch.0;
    seed(&scratch, &recorded);
    let _runtime = Runtime::start(root, Path::new(&descriptor));
    let described = request(
        root,
        "operation.describe",
        json!({"reference": "analyzer.summarize-trace@1"}),
    );
    assert_eq!(described["availability"], "available", "{described}");
    // Swift's product: the one Artifact of its summary Job.
    let swift = fs::read_dir(recorded.join("artifacts"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|directory| !directory.ends_with("job-reviewed-source"))
        .flat_map(|directory| fs::read_dir(directory).unwrap())
        .map(|entry| entry.unwrap().path())
        .find(|path| path.file_name().unwrap() != "index.json")
        .map(|path| fs::read(path).unwrap())
        .unwrap();
    let requests: Value =
        serde_json::from_slice(&fs::read(recorded.join("requests.json")).unwrap()).unwrap();
    let submit = requests["job.plan"].clone();
    let accepted = request(root, "job.submit", submit.clone());
    let job = accepted["jobId"].as_str().unwrap().to_owned();
    let finished = request(root, "job.run", json!({"jobId": job}));
    assert_eq!(finished["state"], "succeeded", "{finished}");
    assert_eq!(published(root, &job), swift);

    // The same request through an agent execution runs its Job to the end.
    let request_json: Value =
        serde_json::from_str(submit["requestJson"].as_str().unwrap()).unwrap();
    let execution = "trace-summary-execution";
    let owned = request(
        root,
        "agent.run",
        json!({
            "schemaVersion": "arkdeck.agent-execution-request/1",
            "executionId": execution,
            "operation": "analyzer.summarize-trace@1",
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
    let deadline = Instant::now() + Duration::from_secs(120);
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
    assert_eq!(published(root, &job), swift);
}
