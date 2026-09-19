//! The isolated daemon's own composition, over its socket. It makes
//! `control-action-snapshots` beside its other owners and never
//! `hdc-control-actions`, answers the HDC control-action methods as Swift's
//! daemon without a managed HDC server does, keeps a page as one owner-only
//! snapshot that it reads again after a restart, admits no Job and never runs
//! the development HDC it is given. Host-only: that HDC is a sentinel script;
//! no device, installed state or Swift daemon is used.
#![cfg(target_os = "macos")]
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, validate_method_value};
use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const IDENTITY: &str = "control-action-5f0c1a52-0b4e-4c8a-9d2e-2b7f3c6a9e10";

struct Runtime {
    root: PathBuf,
    child: Option<Child>,
}

impl Runtime {
    fn new() -> Self {
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-control-action-process-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for directory in [root.clone(), root.join("state"), root.join("tools")] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .unwrap();
        }
        // If the daemon ever runs its development HDC, the sentinel shows it.
        let hdc = root.join("tools/hdc");
        fs::write(
            &hdc,
            format!(
                "#!/bin/sh\ntouch '{}'\nexit 93\n",
                root.join("DISPATCHED").display()
            ),
        )
        .unwrap();
        fs::set_permissions(&hdc, fs::Permissions::from_mode(0o700)).unwrap();
        Self { root, child: None }
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
            let key_text = key.to_string_lossy();
            if key_text.starts_with("ARKDECK_") || key_text.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        self.child = Some(
            command
                .env("ARKDECK_DEVELOPMENT_STATE_ROOT", self.state())
                .env("ARKDECK_ENDPOINT", self.socket())
                .env("ARKDECK_DEVELOPMENT_HDC_PATH", self.root.join("tools/hdc"))
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        // Only an upper bound on the daemon's startup. The socket is bound
        // before the owners are composed, so startup ends at an answer.
        let deadline = Instant::now() + Duration::from_secs(30);
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

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// One current request frame over a new connection, and its answer.
    fn call(&self, method: &str, params: Value) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut frame = serde_json::to_vec(&json!({
            "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
            "id": "control-action-process", "method": method, "params": params,
        }))
        .unwrap();
        frame.push(b'\n');
        stream.write_all(&frame).unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'), "no answer to {method}: {line:?}");
        serde_json::from_str(&line).unwrap()
    }

    fn snapshots(&self) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(self.state().join("control-action-snapshots"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    /// The page the daemon answers for a listing it holds nothing for.
    fn empty_page(&self, params: Value) -> String {
        let answer = self.call("control-action.list", params);
        assert_eq!(answer["ok"], true, "{answer}");
        let revision = answer["result"]["snapshotRevision"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            answer["result"],
            json!({
                "schemaVersion": "arkdeck.cli.page/1", "pageKind": "snapshot", "items": [],
                "order": "createdAtThenControlActionId", "snapshotRevision": revision,
                "hasMore": false, "nextCursor": null,
            })
        );
        revision
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop();
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn the_isolated_daemon_answers_without_a_managed_hdc_server_and_keeps_its_pages() {
    let mut runtime = Runtime::new();
    runtime.start();
    let state = runtime.state();
    let snapshots = state.join("control-action-snapshots");
    let metadata = fs::symlink_metadata(&snapshots).unwrap();
    assert!(metadata.is_dir());
    assert_eq!(metadata.permissions().mode() & 0o7777, 0o700);
    assert!(runtime.snapshots().is_empty());
    assert!(fs::symlink_metadata(state.join("hdc-control-actions")).is_err());

    let refusal = |code: &str, message: &str| json!({"code": code, "message": message, "details": {"newDispatchCount": 0}});
    for method in ["runtime.hdc.impact-preview", "runtime.hdc.restart"] {
        let answer = runtime.call(method, json!({}));
        assert_eq!(
            answer["error"],
            refusal(
                "operationUnavailable",
                "the Runtime HDC control-action owner is unavailable"
            ),
            "{answer}"
        );
    }
    for method in ["control-action.show", "control-action.reconcile"] {
        let answer = runtime.call(method, json!({"controlAction": IDENTITY}));
        // A view whose schemas predate the no-host frames does not publish it.
        let expected =
            if validate_method_value(method, "errorCode", &json!("resourceNotFound")).is_ok() {
                refusal("resourceNotFound", "control action does not exist")
            } else {
                json!({"code": "internalError",
                "message": "the result does not conform to the current contract"})
            };
        assert_eq!(answer["error"], expected, "{answer}");
    }
    assert!(runtime.snapshots().is_empty());

    let revision = runtime.empty_page(json!({}));
    let name = format!("snapshot-{revision}.json");
    assert_eq!(runtime.snapshots(), std::slice::from_ref(&name));
    let file = snapshots.join(&name);
    assert_eq!(
        fs::symlink_metadata(&file).unwrap().permissions().mode() & 0o7777,
        0o600
    );
    let snapshot: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    let token = snapshot["tokens"][0].as_str().unwrap().to_owned();

    // The restarted daemon reads the stored page through its token and
    // stores nothing new.
    runtime.stop();
    runtime.start();
    assert_eq!(runtime.empty_page(json!({"cursor": token})), revision);
    assert_eq!(runtime.snapshots(), [name]);

    let jobs = runtime.call("job.list", json!({}));
    assert_eq!(jobs["ok"], true, "{jobs}");
    assert_eq!(jobs["result"]["items"], json!([]), "no Job was admitted");
    runtime.stop();
    assert!(fs::symlink_metadata(state.join("hdc-control-actions")).is_err());
    assert!(
        !runtime.root.join("DISPATCHED").exists(),
        "the daemon ran its development HDC"
    );
}
