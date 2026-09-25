//! The production daemon symbolizes a device's crash against a registered
//! project's source map (TASK-XPA-015, M3), through its installed socket as a
//! caller meets it: a symbol preset registered against an OpenHarmony
//! project is composed at the next start into a preset that runs the pinned
//! symbolizer `ARKDECK_ANALYZER_PATH` names — this daemon itself, in its
//! one-shot `--symbolize-crash` mode — over the map below the project's root;
//! the crash log a device capture published is symbolized host-only under
//! the default read-only policy, and the report published is exactly what the
//! mode writes for that map and dump. Without a symbolizer the same preset
//! does not compose, and the operation names its preset unavailable.
//!
//! The daemon runs with its environment cleared and `CFFIXED_USER_HOME`
//! naming a temporary home below `/private/tmp`, as the production composition
//! tests run it: no Mach service, LaunchAgent, installed state, HDC or device
//! is touched. The crash log is the capture the Swift oracle published, laid
//! into the store before the daemon starts.
#![cfg(target_os = "macos")]

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const DAEMON: &str = env!("CARGO_BIN_EXE_arkdeck-agentd");
const DEADLINE: Duration = Duration::from_secs(30);
const MAP: &str = "entry/build/default/outputs/default/mapping/sourceMaps.map";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

fn unbase64(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = Vec::new();
    let (mut buffer, mut bits) = (0_u32, 0);
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = ALPHABET.iter().position(|a| *a == byte).unwrap() as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    bytes
}

/// A temporary account home, removed afterwards.
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = PathBuf::from(format!("/private/tmp/ads-{nonce:016x}"));
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
    fn start(home: &Home, symbolizer: Option<&str>) -> Self {
        let mut command = Command::new(DAEMON);
        command
            .env_clear()
            .env("CFFIXED_USER_HOME", &home.0)
            .env("HOME", &home.0)
            .env("ARKDECK_RUNTIME_COMPOSITION", "production");
        if let Some(symbolizer) = symbolizer {
            command.env("ARKDECK_ANALYZER_PATH", symbolizer);
        }
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
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
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": "workspace-symbolize-process", "method": method, "params": params}))
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

fn job_request(label: &str, inputs: Value) -> Value {
    json!({"requestJson": json!({
        "schemaVersion": "1.0.0", "documentType": "runtime-operation-request",
        "requestId": format!("request-{label}"), "idempotencyKey": format!("idempotency-{label}"),
        "operation": {"id": "workspace.symbolize-crash", "version": 1},
        "target": {"targetId": "workspace-host"},
        "inputs": inputs, "requestedOutputs": ["derivedArtifacts"],
    }).to_string()})
}

/// The capture the oracle published, laid into the store as the device's
/// Job left it; kept, so a retention pass cannot take it mid-test.
fn lay_crash_log(home: &Home) -> (String, Vec<u8>) {
    let source = fixture("workspace-test-symbolize-oracle/artifacts/job-input-crash");
    let directory = home.state().join("artifacts/job-input-crash");
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&directory)
        .unwrap();
    let mut index: Value =
        serde_json::from_slice(&fs::read(source.join("index.json")).unwrap()).unwrap();
    let mut lease = None;
    for row in index["artifacts"].as_array_mut().unwrap() {
        row["retention"] = json!({"pinned": true, "retentionClass": "pinnedUntilVerified"});
        let id = row["artifactID"].as_str().unwrap().to_owned();
        fs::copy(source.join(&id), directory.join(&id)).unwrap();
        fs::set_permissions(directory.join(&id), fs::Permissions::from_mode(0o400)).unwrap();
        if row["name"] == "crash-log.txt" {
            lease = Some((
                format!("lease-v1:job-input-crash:{id}"),
                fs::read(source.join(&id)).unwrap(),
            ));
        }
    }
    fs::write(
        directory.join("index.json"),
        serde_json::to_vec_pretty(&index).unwrap(),
    )
    .unwrap();
    fs::set_permissions(
        directory.join("index.json"),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    lease.unwrap()
}

#[test]
fn the_production_daemon_symbolizes_a_devices_crash_with_its_own_one_shot_mode() {
    let home = Home::new();
    let project = home.0.join("project");
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture("crash-symbolizer-oracle/cases.json")).unwrap())
            .unwrap();
    let device = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == "device")
        .unwrap();
    let map = unbase64(device["map"].as_str().unwrap());
    for (path, bytes) in [
        ("build-profile.json5", b"{}\n".to_vec()),
        ("entry/src/main/module.json5", b"{}\n".to_vec()),
        (
            "entry/src/main/ets/pages/Index.ets",
            b"@Entry\n@Component\nstruct Index {}\n".to_vec(),
        ),
        (MAP, map.clone()),
    ] {
        fs::create_dir_all(project.join(path).parent().unwrap()).unwrap();
        fs::write(project.join(path), bytes).unwrap();
    }
    // Registered with its symbol preset, then composed by the next start.
    let daemon = Daemon::start(&home, None);
    let registered = answered(
        &home,
        "workspace.project.register",
        json!({"registrationRequestId": "workspace-symbolize-process", "kind": "openharmony",
            "root": project.to_str().unwrap()}),
    )["projectRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let preset = answered(
        &home,
        "workspace.preset.register",
        json!({"registrationRequestId": "workspace-symbolize-preset", "projectRef": registered,
            "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
            "timeoutSeconds": "60", "relativeSourceMap": MAP}),
    )["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    daemon.stop();
    let (lease, dump) = lay_crash_log(&home);
    let inputs = json!({"projectRef": registered, "dumpArtifactRef": lease,
        "symbolPresetRef": preset});

    // Without a symbolizer the preset does not compose.
    let daemon = Daemon::start(&home, None);
    let refused = request(
        &home,
        "job.plan",
        job_request("unconfigured", inputs.clone()),
    );
    assert_eq!(refused["error"]["code"], "invalidInput", "{refused}");
    assert_eq!(
        refused["error"]["message"],
        "workspace.symbolize-crash@1 is runtime unavailable: workspace.symbolPresetUnavailable",
        "{refused}"
    );
    daemon.stop();

    // With this daemon as its symbolizer, the device's crash is resolved.
    let daemon = Daemon::start(&home, Some(DAEMON));
    let planned = answered(&home, "job.plan", job_request("symbolize", inputs.clone()));
    assert_eq!(planned["authorizationPolicy"], "defaultReadOnly");
    assert_eq!(planned["effectiveEffect"], "hostOnly");
    let job = answered(&home, "job.submit", job_request("symbolize", inputs))["jobId"]
        .as_str()
        .unwrap()
        .to_owned();
    let ran = answered(&home, "job.run", json!({"jobId": job}));
    assert_eq!(ran["state"], "succeeded", "{ran}");
    let result = answered(&home, "job.result", json!({"jobId": job}));
    let artifact = &result["artifacts"][0];
    assert_eq!(artifact["name"], "symbolized-crash.txt", "{result}");
    assert_eq!(artifact["privacy"], "sensitive", "{result}");
    let stored = fs::read(
        home.state()
            .join("artifacts")
            .join(&job)
            .join(artifact["artifactId"].as_str().unwrap()),
    )
    .unwrap();
    let expected = arkdeck_hoststore::symbolize_crash(&map, &dump).unwrap();
    assert_eq!(String::from_utf8(stored).unwrap(), expected);
    assert!(
        expected.contains("-> entry/src/main/ets/fixture/CrashProbe.ets:30:"),
        "{expected}"
    );
    daemon.stop();
}
