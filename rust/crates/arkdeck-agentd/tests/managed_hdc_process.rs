//! The isolated daemon with its managed HDC server (TASK-XPA-016 R2), over
//! its socket: `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` starts the
//! development HDC as `hdc -s <endpoint> -m` before the daemon serves,
//! `runtime.hdc.status` and `target.availability` answer from it, and SIGTERM
//! drains the daemon, stops the server and ends the daemon with status 0,
//! leaving nothing on the endpoint. Host-only: the HDC is a fake compiled
//! here from C (a shell script cannot own a TCP listener); the Target is the
//! adoption fixture's, copied. No real HDC, device, installed state or Swift
//! daemon is used. Spawning children, these tests keep a binary of their own.
#![cfg(target_os = "macos")]
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex, validate_method_value};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");
const TARGET: &str = "TGT-3ba3f5f43b92";

/// A loopback port no other test of this binary was handed.
fn free_port() -> u16 {
    static ISSUED: Mutex<BTreeSet<u16>> = Mutex::new(BTreeSet::new());
    loop {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        if ISSUED.lock().unwrap().insert(port) {
            return port;
        }
    }
}

fn reachable(port: u16) -> bool {
    TcpStream::connect_timeout(
        &SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
        Duration::from_millis(100),
    )
    .is_ok()
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

struct Runtime {
    root: PathBuf,
    port: u16,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-managed-hdc-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [
            root.clone(),
            root.join("state"),
            root.join("state/targets-state"),
            root.join("tools"),
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
        let targets = root.join("state/targets-state/targets.json");
        fs::copy(
            fixture("target-adoption/targets-state/targets.json"),
            &targets,
        )
        .unwrap();
        fs::set_permissions(&targets, fs::Permissions::from_mode(0o600)).unwrap();
        let source = root.join("tools/fake-hdc.c");
        fs::write(&source, FAKE_HDC).unwrap();
        let output = Command::new("cc")
            .arg("-O0")
            .arg("-o")
            .arg(root.join("tools/hdc"))
            .arg(&source)
            .output()
            .expect("cc from the developer tools compiles the fake");
        assert!(
            output.status.success(),
            "fake hdc did not compile: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fs::set_permissions(root.join("tools/hdc"), fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            root,
            port: free_port(),
            child: None,
        }
    }

    fn hdc(&self) -> PathBuf {
        self.root.join("tools/hdc")
    }

    fn state(&self) -> PathBuf {
        self.root.join("state")
    }

    fn socket(&self) -> PathBuf {
        self.state().join("control.sock")
    }

    fn command(&self, environment: &[(&str, &str)]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let key_text = key.to_string_lossy();
            if key_text.starts_with("ARKDECK_") || key_text.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.state())
            .env("ARKDECK_ENDPOINT", self.socket())
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.hdc())
            .envs(environment.iter().copied());
        command
    }

    /// The daemon with its managed server, answering health.
    fn start(&mut self) {
        let port = self.port.to_string();
        self.child = Some(
            self.command(&[
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", &port),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
        );
        // Only an upper bound on the daemon's startup, which includes the
        // managed server's readiness.
        let deadline = Instant::now() + Duration::from_secs(60);
        while UnixStream::connect(self.socket()).is_err() {
            assert!(
                self.child.as_mut().unwrap().try_wait().unwrap().is_none(),
                "daemon exited"
            );
            assert!(Instant::now() < deadline, "daemon startup timeout");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(self.call("health", json!({}))["ok"], true);
    }

    /// A startup the daemon refuses: its status and what it wrote.
    fn refused(&self, environment: &[(&str, &str)]) -> Output {
        let output = self
            .command(environment)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(69), "{output:?}");
        output
    }

    /// One current request frame over a new connection, and its answer.
    fn call(&self, method: &str, params: Value) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        stream.write_all(&frame(method, params)).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'), "no answer to {method}: {line:?}");
        serde_json::from_str(&line).unwrap()
    }

    /// The Rust CLI against this daemon's socket, as the daemon it names.
    fn cli(&self, arguments: &[&str]) -> std::process::ExitStatus {
        // Cargo builds both binary packages before running workspace tests.
        let cli = Path::new(env!("CARGO_BIN_EXE_arkdeck-agentd")).with_file_name("arkdeck");
        let mut command = Command::new(cli);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("ARKDECK_") {
                command.env_remove(key);
            }
        }
        command
            .args(arguments)
            .args(["--output", "json", "--socket"])
            .arg(self.socket())
            .env("ARKDECK_DAEMON_PATH", env!("CARGO_BIN_EXE_arkdeck-agentd"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
    }

    /// SIGTERM, then the daemon's end within `within`: its status and stdout.
    fn terminate(&mut self, within: Duration) -> (std::process::ExitStatus, String) {
        let mut child = self.child.take().unwrap();
        let status = Command::new("/bin/kill")
            .args(["-TERM", &child.id().to_string()])
            .status()
            .unwrap();
        assert!(status.success());
        let deadline = Instant::now() + within;
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not end within {within:?} of SIGTERM");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut stdout = String::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut stdout)
            .unwrap();
        (status, stdout)
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // A server this test left behind would keep its port: end it first.
        let _ = Command::new("/usr/bin/pkill")
            .args(["-KILL", "-f", &self.hdc().to_string_lossy()])
            .status();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn frame(method: &str, params: Value) -> Vec<u8> {
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": "managed-hdc-process", "method": method, "params": params,
    }))
    .unwrap();
    frame.push(b'\n');
    frame
}

#[test]
fn the_managed_server_answers_status_and_availability_and_stops_with_the_daemon() {
    let mut runtime = Runtime::new();
    let digest = sha256_hex(&fs::read(runtime.hdc()).unwrap());
    runtime.start();
    assert!(reachable(runtime.port), "the managed server listens");

    // runtime.hdc.status: the managed server's live facts. The fake's digest
    // has no published commandless identity family, so the identity is not
    // observed and ownership stays unproven, as Swift's observer answers.
    let status = runtime.call("runtime.hdc.status", json!({}));
    assert_eq!(status["ok"], true, "{status}");
    let result = &status["result"];
    validate_method_value("runtime.hdc.status", "result", result).unwrap();
    let endpoint = format!("127.0.0.1:{}", runtime.port);
    for (member, expected) in [
        ("schemaVersion", json!("arkdeck.runtime-hdc-status/1")),
        ("availability", json!("unavailable")),
        ("reasonCode", json!("hdc.identityFamilyUnavailable")),
        ("executablePath", json!(runtime.hdc().to_string_lossy())),
        ("executableSource", json!("runtimeConfiguration")),
        ("configuredExecutableSHA256", json!(digest)),
        ("executableSHA256", json!(digest)),
        ("clientVersion", Value::Null),
        ("clientVersionSource", Value::Null),
        ("serverVersion", Value::Null),
        ("daemonVersion", Value::Null),
        ("endpoint", json!(endpoint)),
        ("endpointSource", json!("inheritedEnvironment")),
        (
            "serverEndpointRef",
            json!(format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes()))),
        ),
        ("ownership", json!("unknown")),
        ("generation", Value::Null),
        ("processId", Value::Null),
        ("serverHealth", json!("unknown")),
        ("newDispatchCount", json!(0)),
        (
            "startupVersions",
            json!({"client": "3.2.0d", "server": "3.2.0d"}),
        ),
    ] {
        assert_eq!(result[member], expected, "{member}: {result}");
    }
    assert!(result["signature"].is_object(), "{result}");

    // target.availability: the tool leg is the managed server's startup facts.
    let availability = runtime.call("target.availability", json!({"targetId": TARGET}));
    assert_eq!(availability["ok"], true, "{availability}");
    validate_method_value("target.availability", "result", &availability["result"]).unwrap();
    assert_eq!(
        availability["result"]["tool"],
        json!({
            "state": "ready", "toolSha256": digest, "clientVersion": "3.2.0d",
            "serverVersion": "3.2.0d", "endpointSource": "inheritedEnvironment",
        })
    );

    // doctor: standard mode does not observe the identity, and the report is
    // ready (degraded only by the Session output owner Swift does not
    // publish). Deep mode observes it: the fake's digest has no commandless
    // identity family, so the identity is a blocker naming why.
    let standard = runtime.call("doctor", json!({}));
    let report = &standard["result"];
    validate_method_value("doctor", "result", report).unwrap();
    assert_eq!(report["ready"], true, "{report}");
    assert_eq!(report["overall"], "degraded");
    assert_eq!(report["checks"]["hdc"]["configured"], true);
    assert_eq!(
        report["checks"]["hdc"]["reasonCode"],
        "doctor.deepNotRequested"
    );
    assert_eq!(report["checks"]["target"]["adoptedTargetCount"], 1);
    assert_eq!(report["checks"]["target"]["bootstrapConfigured"], true);
    let deep = runtime.call("doctor", json!({"deep": true}));
    let report = &deep["result"];
    validate_method_value("doctor", "result", report).unwrap();
    assert_eq!(report["ready"], false, "{report}");
    let blockers: Vec<_> = report["findings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|finding| finding["severity"] == "blocker")
        .map(|finding| finding["summary"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(
        blockers,
        [
            "the selected HDC server identity is unavailable or not Runtime-managed: \
          hdc.identityFamilyUnavailable"
        ]
    );
    assert_eq!(
        report["checks"]["recovery"],
        json!({"checked": true, "outstandingCleanupCount": 0})
    );
    assert_eq!(
        report["checks"]["storage"]["runtimeArtifacts"]["checked"],
        true
    );
    // The CLI's gate over those reports: `--require-healthy` passes the
    // standard report and refuses the deep one with 69.
    assert_eq!(
        runtime.cli(&["doctor", "--require-healthy"]).code(),
        Some(0)
    );
    assert_eq!(
        runtime
            .cli(&["doctor", "--deep", "--require-healthy"])
            .code(),
        Some(69)
    );

    // An idle connection is ended by the drain, not left to its read timeout.
    let mut idle = UnixStream::connect(runtime.socket()).unwrap();
    idle.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    idle.write_all(&frame("health", json!({}))).unwrap();
    let mut idle = BufReader::new(idle);
    let mut line = String::new();
    idle.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");

    let started = Instant::now();
    let (status, stdout) = runtime.terminate(Duration::from_secs(15));
    assert_eq!(status.code(), Some(0), "{status:?}");
    assert_eq!(stdout, "arkdeck-agentd stopped\n");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "{:?}",
        started.elapsed()
    );
    let mut rest = Vec::new();
    idle.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty());
    assert!(!runtime.socket().exists(), "the socket's name is removed");
    assert!(
        !reachable(runtime.port),
        "no server is left on the endpoint"
    );
}

#[test]
fn a_foreign_listener_on_the_endpoint_never_becomes_the_managed_server() {
    let mut runtime = Runtime::new();
    // Another process's listener on the selected endpoint, held from the
    // moment its port is found: the fake's own `-m` cannot bind, and the
    // listener answering is not its launch.
    let foreign = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    runtime.port = foreign.local_addr().unwrap().port();
    let port = runtime.port.to_string();
    let output = runtime.refused(&[
        ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
        ("OHOS_HDC_SERVER_PORT", &port),
    ]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("the managed HDC server did not start"),
        "{stderr}"
    );
    assert!(output.stdout.is_empty());
    drop(foreign);
    assert!(
        !reachable(runtime.port),
        "no managed server was left behind"
    );
}

#[test]
fn a_managed_server_is_configured_only_as_the_isolated_owner_names_it() {
    let runtime = Runtime::new();
    for (environment, message) in [
        (
            vec![("ARKDECK_DEVELOPMENT_HDC_SERVER", "external")],
            "ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed",
        ),
        (
            vec![
                ("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed"),
                ("OHOS_HDC_SERVER_PORT", "65536"),
            ],
            "OHOS_HDC_SERVER_PORT is not a port in 1...65535",
        ),
    ] {
        let output = runtime.refused(&environment);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(message), "{environment:?}: {stderr}");
    }
    // Without a development HDC, or outside an isolated root, nothing starts.
    let output = runtime
        .command(&[("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH")
    );
    let output = runtime
        .command(&[("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")])
        .env_remove("ARKDECK_DEVELOPMENT_HDC_PATH")
        .env_remove("ARKDECK_DEVELOPMENT_STATE_ROOT")
        .env_remove("ARKDECK_ENDPOINT")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(69));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("a development HDC is configured only for an isolated development root")
    );
}
