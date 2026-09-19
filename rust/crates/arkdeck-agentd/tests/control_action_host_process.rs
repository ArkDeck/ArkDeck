//! The isolated daemon with its managed HDC server (TASK-XPA-014), over its
//! socket: `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` composes the HDC
//! control-action owner in `hdc-control-actions` under the union owner.
//! `runtime.hdc.impact-preview` makes a durable action and observes it once;
//! the fake HDC answers `list targets -v` with nothing (exit 23), so the
//! device observation fails and the action is `previewDrifted` with
//! `hdc.impactObservationUnavailable` and no preview, as Swift's daemon
//! answers over that HDC. The reads show, reconcile and page it, a restart
//! stays unavailable, and a new daemon start reads the same final action.
//! Host-only: the HDC is the fake the managed server tests compile from C;
//! no real HDC, device, installed state or Swift daemon is used.
#![cfg(target_os = "macos")]
use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex, validate_method_value,
};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const FAKE_HDC: &str = include_str!("../../../tests/fixtures/managed-hdc/fake-hdc.c");
const INTENT_REQUIRED: &str = "an exact restart intent and request identity are required";

mod loopback_ports {
    include!("../../../tests/support/loopback_ports.rs");
}
use loopback_ports::free_port;

fn reachable(port: u16) -> bool {
    TcpStream::connect_timeout(
        &SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)),
        Duration::from_millis(100),
    )
    .is_ok()
}

struct Runtime {
    root: PathBuf,
    port: u16,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-control-action-host-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [root.clone(), root.join("state"), root.join("tools")] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
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

    fn start(&mut self) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let text = key.to_string_lossy();
            if text.starts_with("ARKDECK_") || text.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        self.child = Some(
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.state())
                .env("ARKDECK_ENDPOINT", self.socket())
                .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.hdc())
                .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
                .env("OHOS_HDC_SERVER_PORT", self.port.to_string())
                .stdout(Stdio::null())
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
        // The socket is bound before the owners are composed; an answer
        // comes only once the daemon serves.
        assert_eq!(self.call("health", json!({}))["ok"], true);
    }

    /// SIGTERM, then the daemon's end: it drains and stops its server.
    fn stop(&mut self) {
        let mut child = self.child.take().unwrap();
        let status = Command::new("/bin/kill")
            .args(["-TERM", &child.id().to_string()])
            .status()
            .unwrap();
        assert!(status.success());
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "{status:?}");
                return;
            }
            assert!(Instant::now() < deadline, "the daemon did not stop");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// One request over a new connection; the answer must pass the method's
    /// published schema.
    fn call(&self, method: &str, params: Value) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(60)))
            .unwrap();
        let mut frame = serde_json::to_vec(&json!({
            "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
            "id": "control-action-host-process", "method": method, "params": params,
        }))
        .unwrap();
        frame.push(b'\n');
        stream.write_all(&frame).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let answer: Value = serde_json::from_str(&line).unwrap();
        if answer["ok"] == true {
            validate_method_value(method, "result", &answer["result"])
                .unwrap_or_else(|error| panic!("{method}: {error}: {answer}"));
        } else {
            validate_method_value(method, "errorCode", &answer["error"]["code"])
                .unwrap_or_else(|error| panic!("{method}: {error}: {answer}"));
        }
        answer
    }

    fn names(&self, directory: &str) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(self.state().join(directory))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = Command::new("/usr/bin/pkill")
            .args(["-KILL", "-f", &self.hdc().to_string_lossy()])
            .status();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn mode(path: &Path) -> u32 {
    fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

fn refused(answer: &Value, code: &str, message: &str) {
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(
        answer["error"],
        json!({"code": code, "message": message, "details": {"newDispatchCount": 0}})
    );
}

#[test]
fn the_managed_server_previews_into_durable_actions_that_the_reads_page() {
    let mut runtime = Runtime::new();
    runtime.start();
    let endpoint = format!("127.0.0.1:{}", runtime.port);
    let reference = format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes()));
    // The owner's directories, private and empty, beside the union's.
    for directory in [
        "hdc-control-actions",
        "hdc-control-actions/records",
        "hdc-control-actions/snapshots",
        "control-action-snapshots",
    ] {
        assert_eq!(mode(&runtime.state().join(directory)), 0o700, "{directory}");
    }
    assert_eq!(
        runtime.names("hdc-control-actions"),
        ["records", "snapshots"]
    );
    assert!(runtime.names("hdc-control-actions/records").is_empty());

    // The owner reads the intent; the endpoint must be its server's.
    let intent = |request: &str, reference: &str, generation: &str| {
        json!({"action": "restart", "actionRequestId": request,
            "serverEndpointRef": reference, "expectedServerGeneration": generation})
    };
    refused(
        &runtime.call("runtime.hdc.impact-preview", json!({})),
        "invalidInput",
        INTENT_REQUIRED,
    );
    let elsewhere = format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:1"));
    refused(
        &runtime.call(
            "runtime.hdc.impact-preview",
            intent("process-elsewhere", &elsewhere, "1"),
        ),
        "resourceNotFound",
        "the exact HDC endpoint reference is not configured",
    );
    assert_eq!(runtime.names("hdc-control-actions/records"), [".lock"]);

    // A preview: a durable action, observed once. The fake's device list is
    // empty output, so the impact is unavailable and nothing is previewed.
    let answer = runtime.call(
        "runtime.hdc.impact-preview",
        intent("process-preview", &reference, "1"),
    );
    assert_eq!(answer["ok"], true, "{answer}");
    let record = answer["result"].clone();
    let id = record["controlActionId"].as_str().unwrap().to_owned();
    let owner = json!({"kind": "controlAction", "id": id});
    // Created, then invalidated once its observation failed, 300 s before it
    // would expire (the owner's unit tests pin the spelling and the span).
    let created = record["createdAt"].as_str().unwrap();
    let observed = record["lastObservedAt"].as_str().unwrap();
    let expires = record["expiresAt"].as_str().unwrap();
    assert_eq!(created.len(), 24, "{created}");
    assert!(created <= observed && observed < expires, "{record}");
    for (member, expected) in [
        ("schemaVersion", json!("arkdeck.control-action/1")),
        ("actionRequestId", json!("process-preview")),
        ("kind", json!("hdcLifecycle")),
        ("action", json!("restart")),
        ("owner", owner.clone()),
        ("generation", json!("2")),
        ("state", json!("previewDrifted")),
        ("catalogDigest", json!(CATALOG_DIGEST)),
        ("preview", Value::Null),
        (
            "blockerReasonCode",
            json!("hdc.impactObservationUnavailable"),
        ),
        ("humanAction", Value::Null),
        ("dispatchCount", json!(0)),
        ("fingerprintAlgorithm", json!("sha256-jcs")),
        (
            "nextAction",
            json!({"kind": "reconcile", "owner": owner, "resource": owner,
                "reasonCode": "hdc.impactObservationUnavailable"}),
        ),
    ] {
        assert_eq!(record[member], expected, "{member}");
    }
    // One owner-only record named by its request identity; the HDC owner's
    // own pages stay empty.
    let file = format!("action-{}.json", sha256_hex(b"process-preview"));
    assert_eq!(
        runtime.names("hdc-control-actions/records"),
        [".lock".to_owned(), file.clone()]
    );
    assert_eq!(
        mode(
            &runtime
                .state()
                .join("hdc-control-actions/records")
                .join(&file)
        ),
        0o600
    );
    assert!(runtime.names("hdc-control-actions/snapshots").is_empty());

    // The same request is the same action; the same identity cannot name
    // another intent.
    assert_eq!(
        runtime.call(
            "runtime.hdc.impact-preview",
            intent("process-preview", &reference, "1"),
        )["result"],
        record
    );
    refused(
        &runtime.call(
            "runtime.hdc.impact-preview",
            intent("process-preview", &reference, "2"),
        ),
        "idempotencyConflict",
        "the request identity belongs to a different lifecycle intent",
    );

    // Read, reconciled and paged as the one action.
    for method in ["control-action.show", "control-action.reconcile"] {
        assert_eq!(
            runtime.call(method, json!({"controlAction": id}))["result"],
            record,
            "{method}"
        );
    }
    let page = runtime.call("control-action.list", json!({}));
    assert_eq!(page["result"]["items"], json!([record]));
    assert_eq!(page["result"]["hasMore"], false);
    assert_eq!(runtime.names("control-action-snapshots").len(), 1);

    // The impact approval is not here: a restart stays unavailable, and the
    // server stays the one launched.
    refused(
        &runtime.call(
            "runtime.hdc.restart",
            json!({"controlAction": id, "previewId": "preview-1",
                "previewDigest": "d".repeat(64)}),
        ),
        "operationUnavailable",
        "the Runtime HDC control-action owner is unavailable",
    );
    assert!(reachable(runtime.port), "the managed server listens");
    let status = runtime.call("runtime.hdc.status", json!({}));
    assert_eq!(status["result"]["endpoint"], json!(endpoint), "{status}");

    // Another daemon start reads the same final action and observes nothing.
    runtime.stop();
    runtime.start();
    assert_eq!(
        runtime.call("control-action.show", json!({"controlAction": id}))["result"],
        record
    );
    assert_eq!(
        runtime.call(
            "runtime.hdc.impact-preview",
            intent("process-preview", &reference, "1"),
        )["result"],
        record
    );
    assert_eq!(
        runtime.names("hdc-control-actions/records"),
        [".lock".to_owned(), file]
    );
    runtime.stop();
    assert!(
        !reachable(runtime.port),
        "the server stopped with the daemon"
    );
}
