//! The production Rust daemon runs a real SwiftPM test preset on its own
//! isolated copy, keeps the Job result and reads it after restart. Temporary
//! account homes only; no installed service, device or caller-made authority.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(30);

/// A temporary account home, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/adt-{nonce:016x}"));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn state(&self) -> PathBuf {
        self.0.join("Library/Application Support/ArkDeck/Agentd")
    }
    fn socket(&self) -> PathBuf {
        self.state().join("agentd.sock")
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The production daemon over `home`, serving, its stdout read as written.
struct Daemon {
    child: Child,
    lines: mpsc::Receiver<String>,
    stdout: Vec<String>,
}

impl Daemon {
    fn start(home: &Home) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"))
            .env_clear()
            .env("CFFIXED_USER_HOME", &home.0)
            .env("HOME", &home.0)
            .env("ARKDECK_RUNTIME_COMPOSITION", "production")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let (send, lines) = mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if send.send(line).is_err() {
                    return;
                }
            }
        });
        let mut daemon = Self {
            child,
            lines,
            stdout: Vec::new(),
        };
        daemon.line("arkdeck-agentd listening on ");
        daemon
    }

    fn line(&mut self, prefix: &str) -> String {
        if let Some(line) = self.stdout.iter().find(|line| line.starts_with(prefix)) {
            return line.clone();
        }
        let deadline = Instant::now() + DEADLINE;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left.max(Duration::from_millis(1))) {
                Ok(line) => {
                    self.stdout.push(line.clone());
                    if line.starts_with(prefix) {
                        return line;
                    }
                }
                Err(_) => panic!("no line {prefix:?}: stdout {:?}", self.stdout),
            }
        }
    }

    /// SIGTERM and the drain.
    fn stop(mut self) {
        let signalled = Command::new("/bin/kill")
            .arg("-TERM")
            .arg(self.child.id().to_string())
            .status()
            .unwrap();
        assert!(signalled.success());
        self.line("arkdeck-agentd stopped");
        let deadline = Instant::now() + DEADLINE;
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn request(home: &Home, method: &str, params: Value) -> Value {
    let mut stream = UnixStream::connect(home.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(180)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "workspace-tests-process", "method": method, "params": params}))
    .unwrap();
    frame.push(b'\n');
    stream.write_all(&frame).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn answered(home: &Home, method: &str, params: Value) -> Value {
    let answer = request(home, method, params);
    assert_eq!(answer["ok"], true, "{method}: {answer}");
    answer["result"].clone()
}

fn job_request(label: &str, operation: &str, inputs: Value, capability: Option<&str>) -> Value {
    let mut document = json!({
        "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "operation": {"id": operation, "version": 1},
        "target": {"targetId": "workspace-host"},
        "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
    });
    if let Some(capability) = capability {
        document["authorization"] = json!({"capabilityId": capability});
    }
    json!({"requestJson": document.to_string()})
}

const MANIFEST: &str = r#"// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WorkspaceProbe", targets: [
    .testTarget(name: "WorkspaceProbeTests")
])
"#;
const PASSING_TEST: &str = r#"import XCTest
final class WorkspaceProbeTests: XCTestCase {
    func testRuntimeCopy() { XCTAssertEqual(2 + 2, 4) }
}
"#;

fn seed(root: &Path, test: &str) -> String {
    let files = [
        ("Packages/ArkDeckKit/Package.swift", MANIFEST),
        (
            "Packages/ArkDeckKit/Tests/WorkspaceProbeTests/Probe.swift",
            test,
        ),
    ];
    let mut material = "profileVersion\tworkspace-host@1\nhead\tabsent\nindex\tabsent\n".to_owned();
    for (path, contents) in files {
        fs::create_dir_all(root.join(path).parent().unwrap()).unwrap();
        fs::write(root.join(path), contents).unwrap();
        material.push_str(&format!(
            "file\t{path}\t{}\n",
            sha256_hex(contents.as_bytes())
        ));
    }
    sha256_hex(material.as_bytes())
}

fn submit_run(home: &Home, request: Value) -> (String, Value) {
    let job = answered(home, "job.submit", request)["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(home, "job.run", json!({"jobId": job}));
    (job, ran)
}

#[test]
fn the_production_daemon_runs_tests_only_in_its_copy_and_keeps_the_result() {
    exercise("succeeded", PASSING_TEST);
    exercise("failed", &PASSING_TEST.replace("2 + 2, 4", "2 + 2, 5"));
}

fn exercise(expected: &str, test_source: &str) {
    let home = Home::new();
    let source = home.0.join("source");
    let revision = seed(&source, test_source);
    let daemon = Daemon::start(&home);
    let project = answered(
        &home,
        "workspace.project.register",
        json!({
            "registrationRequestId": "register-tests", "kind": "arkdeck",
            "root": source.to_str().unwrap()
        }),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();
    let daemon = Daemon::start(&home);

    // A primary project cannot receive the Runtime's isolated-copy policy.
    let primary = request(
        &home,
        "job.submit",
        job_request(
            "primary",
            "workspace.run-tests",
            json!({"projectRef": project,
            "testPresetRef": "arkdeck-tests", "expectedWorkspaceRevision": revision}),
            None,
        ),
    );
    assert_eq!(primary["ok"], false, "{primary}");
    assert_eq!(primary["error"]["code"], "admissionDenied");
    assert_eq!(primary["error"]["details"]["newDispatchCount"], 0);
    assert!(!source.join("Packages/ArkDeckKit/.build").exists());

    let (copy_job, copied) = submit_run(
        &home,
        job_request(
            "copy",
            "workspace.prepare-isolated-copy",
            json!({"projectRef": project,
            "expectedWorkspaceRevision": revision,
            "allowedFileGlobs": ["Packages/ArkDeckKit/**"]}),
            None,
        ),
    );
    assert_eq!(copied["state"], "succeeded", "{copied}");
    let digest = sha256_hex(format!("runtime-{copy_job}|{project}|{revision}").as_bytes());
    let copy = format!("evolution-{}", &digest[..20]);
    let tests = job_request(
        "tests",
        "workspace.run-tests",
        json!({
            "projectRef": copy, "testPresetRef": "arkdeck-tests",
            "expectedWorkspaceRevision": revision
        }),
        None,
    );
    let plan = answered(&home, "job.plan", tests.clone());
    assert_eq!(plan["authorizationPolicy"], "standingCapability");
    let (job, ran) = submit_run(&home, tests);
    assert_eq!(
        ran["state"],
        expected,
        "{ran}\n{}",
        answered(&home, "job.show", json!({"jobId": job}))
    );
    let result = answered(&home, "job.result", json!({"jobId": job}));
    // The existing Swift/Rust Session writer requires device facts for a
    // deviceMutation intent. This host test has none: it keeps the Job and
    // Artifact, but must not claim a published Session (as the patch test).
    assert_eq!(ran["sessionPublication"]["state"], "failed", "{ran}");
    assert_eq!(
        ran["sessionPublication"]["reasonCode"], "sourceIntegrityFailed",
        "{ran}"
    );
    assert_eq!(ran["outcomeUnknown"], false);
    if expected == "failed" {
        assert!(
            answered(&home, "job.show", json!({"jobId": job}))
                .to_string()
                .contains("workspace.testsFailed")
        );
    }
    assert_eq!(result["artifacts"][0]["name"], "test-output.log");
    assert_eq!(result["evidence"]["authority"]["kind"], "runtimeCapability");
    let artifact = result["artifacts"][0]["artifactId"].as_str().unwrap();
    let output = fs::read(home.state().join("artifacts").join(&job).join(artifact)).unwrap();
    assert!(
        String::from_utf8_lossy(&output).contains("testRuntimeCopy"),
        "{}",
        String::from_utf8_lossy(&output)
    );
    assert!(!source.join("Packages/ArkDeckKit/.build").exists());
    daemon.stop();

    let daemon = Daemon::start(&home);
    assert_eq!(answered(&home, "job.result", json!({"jobId": job})), result);
    assert_eq!(
        fs::read(home.state().join("artifacts").join(&job).join(artifact)).unwrap(),
        output
    );
    daemon.stop();
}
