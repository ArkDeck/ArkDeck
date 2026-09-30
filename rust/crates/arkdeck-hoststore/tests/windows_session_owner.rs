//! The Session storage, cleanup and export owner and the Artifact usage owner
//! on Windows (TASK-XPA-005/014), against the Swift oracle of the Session
//! storage requests made while a storage lock is held
//! (`rust/tests/fixtures/storage-lock-wait-oracle`, recorded by
//! `StorageLockWaitOracleContractTests`; the macOS replay is
//! `storage_lock_wait_oracle.rs`): over an owner-only root of the same shape
//! on NTFS, holding the oracle's retained Session in the root the requests
//! select, `runtime.storage.status`, `.policy` and `.root`, `session.list`,
//! `session.pin` and `session.export.preview`, each sent while this test
//! holds `.session-storage.lock`, and a status read sent while it holds the
//! selected root's `.arkdeck-retention-catalog.lock`. Each is still waiting
//! while its lock is held and, once it is released, answers Swift's answer
//! byte for byte, its Artifact domain included (the roots and the export
//! destination read as the oracle's paths; its random and host values as the
//! oracle's labels), admitted by the published method schemas; a final
//! status read with both locks free answers the state the requests left.
#![cfg(windows)]

use arkdeck_hoststore::{ArtifactUsage, SessionStore};
use arkdeck_platform::{HostDirectory, HostReadLock};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

/// The recording's root, as its answers name the Session roots.
const RECORDED_ROOT: &str = "/tmp/arkdeck-storage-lock-wait-oracle";
const SESSION: &str = "session-fixture";
/// The Rust daemon's Artifact quota (`arkdeck-agentd`'s `ARTIFACT_QUOTA`),
/// which the oracle's Artifact store is given.
const ARTIFACT_QUOTA: u64 = 8 * 1024 * 1024 * 1024;
/// The oracle's clock, 2026-09-26T00:00:00Z, in seconds since 2001 as the
/// daemon hands it to an export preview.
const NOW: f64 = 1_790_380_800.0 - 978_307_200.0;

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
        for name in ["session-state", "sessions", "artifacts"] {
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
        for key in ["rootPath", "destinationPath"] {
            if let Some(path) = params.get_mut(key) {
                let relative = path
                    .as_str()
                    .unwrap()
                    .strip_prefix("/private/tmp/arkdeck-storage-lock-wait-oracle/")
                    .unwrap();
                *path = json!(self.0.join(relative).to_str().unwrap());
            }
        }
        params
    }

    /// `path` below this root, spelled as the recording spells it.
    fn recorded_path(&self, path: &str, prefix: &str) -> Value {
        let relative = Path::new(path).strip_prefix(&self.0).unwrap();
        json!(format!(
            "{prefix}/{}",
            relative.to_str().unwrap().replace('\\', "/")
        ))
    }

    /// An answer with this root's paths spelled as the recording's, and its
    /// snapshot revision as the oracle's label.
    fn labelled(&self, mut answer: Value) -> Value {
        if let Some(result) = answer.get_mut("result").and_then(Value::as_object_mut) {
            if let Some(root) = result
                .get_mut("sessionDomain")
                .and_then(|domain| domain.get_mut("rootPath"))
                && let Some(path) = root.as_str()
            {
                *root = self.recorded_path(path, RECORDED_ROOT);
            }
            if let Some(path) = result
                .get_mut("destination")
                .and_then(|destination| destination.get_mut("path"))
                && let Some(text) = path.as_str()
            {
                *path = self.recorded_path(text, "/private/tmp/arkdeck-storage-lock-wait-oracle");
            }
            for key in ["snapshotRevision", "previewId", "previewDigest"] {
                if let Some(value) = result.get_mut(key) {
                    *value = json!(format!("<{key}>"));
                }
            }
            for (name, keys) in [
                (
                    "destination",
                    &["parentDevice", "parentInode", "volumeIdentity"][..],
                ),
                (
                    "source",
                    &[
                        "rootDevice",
                        "rootInode",
                        "sessionDevice",
                        "sessionInode",
                        "volumeIdentity",
                    ][..],
                ),
            ] {
                if let Some(nested) = result.get_mut(name).and_then(Value::as_object_mut) {
                    for key in keys {
                        if let Some(value) = nested.get_mut(*key) {
                            *value = json!(format!("<{key}>"));
                        }
                    }
                }
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

/// The Rust daemon's answer to one recorded request, as `arkdeck-agentd`'s
/// `runtime_storage` and its Session resource routes compose it.
fn answer(root: &Root, sessions: &SessionStore, artifacts: &ArtifactUsage, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let params = root.params(frame);
    let answered = match method {
        "session.list" | "session.pin" => sessions.handle_resource(method, &params),
        "session.export.preview" => sessions.preview_export(
            params["sessionId"].as_str().unwrap(),
            params["destinationPath"].as_str().unwrap(),
            params["allowSensitive"].as_bool().unwrap(),
            NOW,
        ),
        _ => {
            let artifact = artifacts.status().unwrap();
            sessions.handle(method, &params).map(|session| {
                json!({"schemaVersion": "arkdeck.runtime-storage/1",
                    "sessionDomain": session, "artifactDomain": artifact})
            })
        }
    };
    let answer = match answered {
        Ok(result) => {
            arkdeck_contract::validate_method_value(method, "result", &result).unwrap();
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

fn recorded(frame: &Value) -> Value {
    let mut expected = json!({"ok": frame["ok"]});
    if frame["ok"] == true {
        expected["result"] = frame["result"].clone();
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
    let artifacts = ArtifactUsage::open(&root.0.join("artifacts"), ARTIFACT_QUOTA).unwrap();
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
            5 => Some(held(
                &root.0.join("custom"),
                ".arkdeck-retention-catalog.lock",
            )),
            7 => None,
            _ => Some(held(&owner, ".session-storage.lock")),
        };
        let Some(lock) = lock else {
            assert_eq!(
                answer(&root, &sessions, &artifacts, frame),
                recorded(frame),
                "frame {index}"
            );
            continue;
        };
        let (sender, receiver) = mpsc::channel();
        std::thread::scope(|scope| {
            let (root, sessions, artifacts) = (&root, &sessions, &artifacts);
            scope.spawn(move || {
                sender
                    .send(answer(root, sessions, artifacts, frame))
                    .unwrap()
            });
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
