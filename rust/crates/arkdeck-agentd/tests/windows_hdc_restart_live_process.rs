//! A confirmed HDC restart on Windows with the registered HDC (CHG-2026-074
//! TASK-XPA-005 over CHG-2026-078): the real daemon, over an isolated
//! development root, composes the registered DevEco Studio 26.0.0.43
//! `hdc.exe` (`3.2.0g`) as its managed server, and is asked through its pipe
//! for the restart's impact preview and the restart, which requests the
//! impact approval and restarts nothing until a human answers it at the
//! foreground console (`windows_hdc_restart_tests.rs` runs that answer). No
//! board is needed: a restart only addresses the server.
//!
//! It needs `ARKDECK_LIVE_WINDOWS_HDC`, the path of the registered `hdc.exe`;
//! without it it says so and checks nothing. Nothing else may listen on
//! `127.0.0.1:8710`: the daemon starts and owns the server there and stops
//! it (and a replacement its restart proved) before it ends; an existing
//! server is never adopted or stopped.
#![cfg(windows)]

use arkdeck_platform::StateRoot;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

const DEADLINE: Duration = Duration::from_secs(90);
const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winhdcrestart-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Daemon {
    child: Option<Child>,
    lines: Receiver<String>,
    seen: Vec<String>,
}

impl Daemon {
    fn start(root: &Path, hdc: &Path) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let key = key.to_string_lossy().into_owned();
            if key.to_ascii_uppercase().starts_with("ARKDECK_")
                || key.to_ascii_uppercase().starts_with("OHOS_HDC_")
            {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .env("ARKDECK_DEVELOPMENT_HDC_PATH", hdc)
            .env("ARKDECK_DEVELOPMENT_HDC_SERVER", "managed")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
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
                Err(error) => panic!(
                    "no line starting {prefix:?} ({error}); stdout so far {:?}",
                    self.seen
                ),
            }
        }
    }

    fn serving(&mut self) -> String {
        self.line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned()
    }

    fn stop(&mut self, root: &Path) {
        let child = self.child.take().unwrap();
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(child.id()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        let mut child = child;
        let deadline = Instant::now() + DEADLINE;
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "{status:?}");
                return;
            }
            assert!(Instant::now() < deadline, "the daemon did not end");
            std::thread::sleep(Duration::from_millis(100));
        }
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

/// One exchange on a fresh plain handle of the daemon's pipe.
fn call(pipe: &str, method: &str, params: Value) -> Value {
    let mut connection = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .unwrap();
    let request = json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": method,
        "method": method,
        "params": params,
    });
    let mut frame = serde_json::to_vec(&request).unwrap();
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

fn endpoint_free() -> bool {
    std::net::TcpStream::connect_timeout(
        &"127.0.0.1:8710".parse().unwrap(),
        Duration::from_millis(300),
    )
    .is_err()
}

#[test]
fn a_confirmed_restart_of_the_registered_windows_hdc() {
    let Some(hdc) = std::env::var_os("ARKDECK_LIVE_WINDOWS_HDC").filter(|v| !v.is_empty()) else {
        eprintln!(
            "SKIPPED: ARKDECK_LIVE_WINDOWS_HDC does not name the registered hdc.exe (DevEco Studio \
             26.0.0.43's toolchains hdc.exe); nothing was checked"
        );
        return;
    };
    let hdc = PathBuf::from(hdc);
    assert_eq!(
        arkdeck_contract::sha256_hex(&std::fs::read(&hdc).unwrap()),
        C2_SHA256,
        "{} is not the registered hdc.exe",
        hdc.display()
    );
    assert!(
        endpoint_free(),
        "something already listens on 127.0.0.1:8710; this test never stops a server it did \
         not start"
    );
    let root = Root::new();
    let mut daemon = Daemon::start(&root.0, &hdc);
    let pipe = daemon.serving();
    // A fresh 3.2.0g server lists `[Empty]` for its first ~1.3 s, which the
    // registry does not admit yet (CHG-2026-078 r3, #2484, settles past it).
    std::thread::sleep(Duration::from_secs(3));

    let status = call(&pipe, "runtime.hdc.status", json!({}));
    eprintln!("status: {status}");
    let status = &status["result"];
    let preview = call(
        &pipe,
        "runtime.hdc.impact-preview",
        json!({
            "action": "restart",
            "actionRequestId": "live-restart",
            "expectedServerGeneration": status["generation"].clone(),
            "serverEndpointRef": status["serverEndpointRef"].clone(),
        }),
    );
    eprintln!("impact-preview: {preview}");
    let result = &preview["result"];
    let restart = call(
        &pipe,
        "runtime.hdc.restart",
        json!({
            "controlAction": result["controlActionId"].clone(),
            "previewId": result["preview"]["previewId"].clone(),
            "previewDigest": result["preview"]["previewDigest"].clone(),
        }),
    );
    eprintln!("restart: {restart}");
    // The preview proves the server healthy and this daemon's, and the
    // restart asks for the impact approval: nothing restarts before a
    // human answers it at the foreground console.
    assert_eq!(result["blockerReasonCode"], Value::Null, "{preview}");
    assert_eq!(result["preview"]["serverHealth"], "healthy", "{preview}");
    assert_eq!(
        result["preview"]["serverOwnership"], "arkDeckManaged",
        "{preview}"
    );
    assert_eq!(result["preview"]["serverVersion"], "3.2.0g", "{preview}");
    let har = &restart["result"]["humanAction"];
    assert_eq!(har["category"], "impactApproval", "{restart}");
    assert_eq!(har["status"], "waiting", "{restart}");
    let after = call(&pipe, "runtime.hdc.status", json!({}));
    eprintln!("status after: {after}");
    assert_eq!(
        after["result"]["generation"], status["generation"],
        "{after}"
    );
    assert_eq!(after["result"]["processId"], status["processId"], "{after}");
    daemon.stop(&root.0);
    assert!(endpoint_free(), "the daemon stopped the server it started");
}
