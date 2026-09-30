//! Every published control method, asked of the real Windows daemon over an
//! isolated development root, answers in its published contract
//! (TASK-XPA-018): no reply is the control layer's replacement of an answer
//! that does not conform (`internalError` "the result does not conform to
//! the current contract").
//!
//! Each method is sent the requests the committed control-frame corpus
//! records for it (`Packages/ArkDeckKit/Tests/ArkDeckContractTests/
//! Fixtures/ControlFrames`), in order, until one is not refused as malformed,
//! as `rust/scripts/windows-method-census.py` sends them; every reply is
//! checked. The two answers that did not conform before are asserted
//! exactly:
//!
//! * `target.display-name.clear` of a Target that does not exist is the
//!   Target display-name owner's `resourceNotFound`, as Swift's
//!   `clearTargetDisplayName` answers it;
//! * `artifact.import.list` answers the Import owner's page (TASK-XPA-008
//!   composes the owner on Windows; without it the answer is Swift's
//!   `operationUnavailable` "Import owner services are unavailable", phase
//!   `importOwner`, which the contract now publishes).
//!
//! check-contracts' published view compiles this build against the merge
//! base's contract, which may predate the widening of
//! `target.display-name.clear`: there that answer is still replaced, and
//! nothing else may be.
//!
//! The daemon runs with every `ARKDECK_` and `OHOS_HDC_` input removed but
//! its development root; nothing installed is read or written, and no HDC or
//! device is involved. It is stopped by its root's stop request.
#![cfg(windows)]

use arkdeck_platform::{HostDirectory, StateRoot};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

const DEADLINE: Duration = Duration::from_secs(60);
const NON_CONFORMING: &str = "the result does not conform to the current contract";
/// The Swift adoption oracle's Target, and one no root holds.
const TARGET: &str = "TGT-3ba3f5f43b92";
const ABSENT: &str = "TGT-ffffffffffff";

/// A fresh development root holding the oracle's Target, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winconform-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        HostDirectory::open_or_create_private(&path.join("targets-state")).unwrap();
        std::fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/target-adoption/targets-state/targets.json"),
            path.join("targets-state").join("targets.json"),
        )
        .unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The daemon, serving, and every line it writes.
struct Daemon {
    child: Child,
    lines: Receiver<String>,
}

impl Daemon {
    fn start(root: &Path) -> (Self, String) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"));
        for (key, _) in std::env::vars_os() {
            let upper = key.to_string_lossy().to_ascii_uppercase();
            if upper.starts_with("ARKDECK_") || upper.starts_with("OHOS_HDC_") {
                command.env_remove(key);
            }
        }
        let mut child = command
            .env("ARKDECK_DEVELOPMENT_STATE_ROOT", root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
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
        let daemon = Self { child, lines };
        let pipe = daemon
            .line_starting("arkdeck-agentd listening on ")
            .trim_start_matches("arkdeck-agentd listening on ")
            .to_owned();
        (daemon, pipe)
    }

    fn line_starting(&self, prefix: &str) -> String {
        loop {
            let line = self
                .lines
                .recv_timeout(DEADLINE)
                .unwrap_or_else(|error| panic!("no line starting {prefix:?}: {error}"));
            if line.starts_with(prefix) {
                return line;
            }
        }
    }

    fn stop(mut self, root: &Path) {
        let scope = StateRoot::development(root).unwrap().scope().unwrap();
        scope.request_stop(self.child.id()).unwrap();
        self.line_starting("arkdeck-agentd stopped");
        assert!(self.child.wait().unwrap().success());
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One request on a fresh plain handle of the daemon's pipe.
fn request(pipe: &str, id: &str, method: &str, params: &Value) -> Value {
    let mut connection = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe)
        .unwrap();
    let mut frame = serde_json::to_vec(&json!({
        "protocolVersion": arkdeck_contract::PROTOCOL_VERSION,
        "contractIdentity": arkdeck_contract::CONTRACT_IDENTITY,
        "id": id,
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

/// The parameters of every request the corpus records for `method`, each
/// once, in order; none when it records no request.
fn recorded_params(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    let mut params: Vec<Value> = Vec::new();
    if let Ok(text) = std::fs::read_to_string(path) {
        for line in text.lines() {
            let value = serde_json::from_str::<Value>(line).unwrap()["params"].clone();
            let value = if value.is_null() { json!({}) } else { value };
            if !params.contains(&value) {
                params.push(value);
            }
        }
    }
    if params.is_empty() {
        params.push(json!({}));
    }
    params
}

/// Whether this build was compiled against a merge base's contract
/// (check-contracts' published view).
fn published_view() -> bool {
    let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// Whether the compiled contract publishes `code` among `method`'s refusals.
fn publishes(method: &str, code: &str) -> bool {
    arkdeck_contract::validate_method_value(method, "errorCode", &json!(code)).is_ok()
}

#[test]
fn every_method_answers_in_its_published_contract() {
    let root = Root::new();
    let (daemon, pipe) = Daemon::start(&root.0);

    // The two answers that did not conform, exactly.
    let cleared = request(
        &pipe,
        "clear-absent",
        "target.display-name.clear",
        &json!({"targetId": ABSENT, "expectedGeneration": "1"}),
    );
    let listed = request(
        &pipe,
        "import-list",
        "artifact.import.list",
        &json!({"pageSize": 1}),
    );
    if publishes("target.display-name.clear", "resourceNotFound") {
        assert_eq!(cleared["error"]["code"], "resourceNotFound", "{cleared}");
        assert_eq!(
            cleared["error"]["details"],
            json!({"phase": "targetDisplayNameOwner", "newDispatchCount": 0}),
            "{cleared}"
        );
    } else {
        assert!(
            published_view(),
            "target.display-name.clear must publish resourceNotFound"
        );
        assert_eq!(cleared["error"]["message"], NON_CONFORMING, "{cleared}");
    }
    // The Import owner is composed: the list answers its (empty) page.
    assert_eq!(listed["ok"], true, "{listed}");
    arkdeck_contract::validate_method_value("artifact.import.list", "result", &listed["result"])
        .unwrap_or_else(|error| panic!("{error}: {listed}"));
    assert_eq!(listed["result"]["items"], json!([]), "{listed}");
    // The existing Target's clear still answers its result.
    let existing = request(
        &pipe,
        "clear-existing",
        "target.display-name.clear",
        &json!({"targetId": TARGET, "expectedGeneration": "1"}),
    );
    assert_eq!(existing["ok"], true, "{existing}");

    // Every method, with the corpus's requests.
    let mut replaced = Vec::new();
    let mut asked = 0;
    for method in arkdeck_contract::METHODS {
        for (index, params) in recorded_params(method).iter().enumerate() {
            let reply = request(&pipe, &format!("census-{asked}-{index}"), method, params);
            asked += 1;
            if reply["error"]["message"] == NON_CONFORMING {
                replaced.push(format!("{method} {params}"));
            }
            if reply["error"]["code"] != "invalidParams" {
                break;
            }
        }
    }
    let allowed: &[&str] = if published_view() {
        &["target.display-name.clear", "artifact.import.list"]
    } else {
        &[]
    };
    replaced.retain(|entry| {
        !allowed
            .iter()
            .any(|method| entry.starts_with(&format!("{method} ")))
    });
    assert!(
        replaced.is_empty(),
        "answers the control layer replaced as non-conforming: {replaced:#?}"
    );
    assert!(asked >= arkdeck_contract::METHODS.len());
    daemon.stop(&root.0);
}
