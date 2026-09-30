//! The Session storage owner on Windows (TASK-XPA-005/014), against the
//! Swift oracle of the Session storage requests made while a storage lock is
//! held (`rust/tests/fixtures/storage-lock-wait-oracle`, recorded by
//! `StorageLockWaitOracleContractTests`; the macOS replay is
//! `storage_lock_wait_oracle.rs`): over an owner-only root of the same shape
//! on NTFS, holding the oracle's retained Session in the root the requests
//! select, `runtime.storage.status`, `.policy` and `.root`, `session.list`
//! and `session.pin`, each sent while this test holds
//! `.session-storage.lock`, and a status read sent while it holds the
//! selected root's `.arkdeck-retention-catalog.lock`. Each is still waiting
//! while its lock is held and, once it is released, answers Swift's Session
//! domain byte for byte (the Session roots read as the oracle's paths, a
//! snapshot revision as its label), admitted by the published method
//! schemas; a final status read with both locks free answers the state the
//! requests left.
//!
//! Not replayed here: the answers' Artifact domain (the Artifact usage owner
//! is still macOS-only) and `session.export.preview` (the Session export is
//! still macOS-only).
#![cfg(windows)]

use arkdeck_hoststore::SessionStore;
use arkdeck_platform::{HostDirectory, HostReadLock};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

/// The recording's root, as its answers name the Session roots.
const RECORDED_ROOT: &str = "/tmp/arkdeck-storage-lock-wait-oracle";
const SESSION: &str = "session-fixture";

fn oracle() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/storage-lock-wait-oracle")
}

fn frames() -> Vec<Value> {
    std::fs::read_to_string(oracle().join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// A fresh owner-only root in its canonical spelling, rebuilt with the
/// oracle's retained Session in the root the requests select; removed when
/// the test ends.
struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let path = temporary.join(format!("ad-winstorage-{nonce:032x}"));
        let root = HostDirectory::open_or_create_private(&path).unwrap();
        for name in ["session-state", "sessions"] {
            root.create_private_child(name).unwrap();
        }
        let session = root
            .create_private_child("custom")
            .unwrap()
            .create_private_child("2026")
            .unwrap()
            .create_private_child("09")
            .unwrap()
            .create_private_child(SESSION)
            .unwrap();
        session
            .create_document(
                ".session-identity.json",
                br#"{"jobId":"job-fixture","schemaVersion":"1.0.0","sessionId":"session-fixture"}"#,
            )
            .unwrap();
        session
            .create_document(
                "manifest.json",
                &std::fs::read(oracle().join("manifest.json")).unwrap(),
            )
            .unwrap();
        session.create_document("payload.bin", &[0x53; 48]).unwrap();
        Self(path)
    }

    /// A request's parameters with the recording's paths spelled below this
    /// root.
    fn params(&self, frame: &Value) -> Map<String, Value> {
        let mut params: Map<String, Value> =
            frame["params"].as_object().cloned().unwrap_or_default();
        if let Some(path) = params.get_mut("rootPath") {
            let relative = path
                .as_str()
                .unwrap()
                .strip_prefix("/private/tmp/arkdeck-storage-lock-wait-oracle/")
                .unwrap();
            *path = json!(self.0.join(relative).to_str().unwrap());
        }
        params
    }

    /// An answer with this root's paths spelled as the recording's, and its
    /// snapshot revision as the oracle's label.
    fn labelled(&self, mut answer: Value) -> Value {
        if let Some(result) = answer.get_mut("result").and_then(Value::as_object_mut) {
            if let Some(root) = result.get_mut("rootPath")
                && let Some(path) = root.as_str()
            {
                let relative = Path::new(path).strip_prefix(&self.0).unwrap();
                *root = json!(format!(
                    "{RECORDED_ROOT}/{}",
                    relative.to_str().unwrap().replace('\\', "/")
                ));
            }
            if let Some(value) = result.get_mut("snapshotRevision") {
                *value = json!("<snapshotRevision>");
            }
        }
        answer
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The Session owner's answer to one recorded request: the Session domain
/// `arkdeck-agentd`'s `runtime_storage` wraps, or its Session resource route.
fn answer(root: &Root, sessions: &SessionStore, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let params = root.params(frame);
    let answered = match method {
        "session.list" | "session.pin" => sessions.handle_resource(method, &params),
        _ => sessions.handle(method, &params),
    };
    let answer = match answered {
        Ok(result) => {
            if method.starts_with("session.") {
                arkdeck_contract::validate_method_value(method, "result", &result).unwrap();
            }
            json!({"ok": true, "result": result})
        }
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    };
    root.labelled(answer)
}

/// The recorded answer: a Session resource's result, or the Session domain
/// of a storage answer.
fn recorded(frame: &Value) -> Value {
    let mut expected = json!({"ok": frame["ok"]});
    if frame["ok"] == true {
        let result = &frame["result"];
        expected["result"] = if frame["method"]
            .as_str()
            .unwrap()
            .starts_with("runtime.storage.")
        {
            result["sessionDomain"].clone()
        } else {
            result.clone()
        };
    } else {
        expected["error"] = frame["error"].clone();
    }
    expected
}

/// `name` in `directory`, held as another holder would hold it.
fn held(directory: &Path, name: &str) -> HostReadLock {
    HostDirectory::open(directory)
        .unwrap()
        .lock_document(name)
        .unwrap()
}

#[test]
fn storage_requests_made_while_a_storage_lock_is_held_answer_as_swift_s() {
    let root = Root::new();
    let owner = root.0.join("session-state");
    let sessions = SessionStore::open(&owner, &root.0.join("sessions")).unwrap();
    let recording = frames();
    let methods: Vec<&str> = recording
        .iter()
        .map(|frame| frame["method"].as_str().unwrap())
        .collect();
    assert_eq!(
        methods,
        [
            "runtime.storage.status",
            "runtime.storage.policy",
            "runtime.storage.root",
            "session.list",
            "session.pin",
            "runtime.storage.status",
            "session.export.preview",
            "runtime.storage.status",
        ]
    );
    for (index, frame) in recording.iter().enumerate() {
        let lock = match index {
            // The Session export is still macOS-only; its preview changes
            // no storage state the next status reads.
            6 => continue,
            5 => Some(held(
                &root.0.join("custom"),
                ".arkdeck-retention-catalog.lock",
            )),
            7 => None,
            _ => Some(held(&owner, ".session-storage.lock")),
        };
        let Some(lock) = lock else {
            assert_eq!(
                answer(&root, &sessions, frame),
                recorded(frame),
                "frame {index}"
            );
            continue;
        };
        let (sender, receiver) = mpsc::channel();
        std::thread::scope(|scope| {
            let (root, sessions) = (&root, &sessions);
            scope.spawn(move || sender.send(answer(root, sessions, frame)).unwrap());
            // A refusal is immediate. The bound only lets one arrive; the
            // answer never depends on it.
            if let Ok(early) = receiver.recv_timeout(Duration::from_millis(200)) {
                panic!(
                    "frame {index}: {} answered while its lock was held: {early}",
                    frame["method"]
                );
            }
            drop(lock);
            assert_eq!(
                receiver.recv_timeout(Duration::from_secs(30)).unwrap(),
                recorded(frame),
                "frame {index}: {}",
                frame["method"]
            );
        });
    }
}
