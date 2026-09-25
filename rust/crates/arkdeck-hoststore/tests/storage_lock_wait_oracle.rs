//! Replays the Swift oracle of the Session storage requests made while a
//! storage lock is held (`rust/tests/fixtures/storage-lock-wait-oracle`,
//! recorded by `StorageLockWaitOracleContractTests`) against the Rust Session
//! owner over the same fixed root and the same retained Session:
//! `runtime.storage.status`, `.policy` and `.root`, `session.list`,
//! `session.pin` and `session.export.preview`, each sent while this test
//! holds `.session-storage.lock`, and a status read sent while it holds the
//! selected root's `.arkdeck-retention-catalog.lock`. Each is still waiting
//! while its lock is held and, once it is released, answers Swift's answer
//! byte for byte (its random and host values read as the oracle's labels),
//! admitted by the published method schemas. A final status read with both
//! locks free answers the state the requests left.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{ArtifactUsage, SessionStore};
use arkdeck_platform::{HostDirectory, HostReadLock};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;
use support::chmod;

/// The recording's fixed root: the answers name the Session roots by path.
const ROOT: &str = "/private/tmp/arkdeck-storage-lock-wait-oracle";
const LOCK: &str = "/private/tmp/arkdeck-storage-lock-wait-oracle.lock";
/// The Rust daemon's Artifact quota (`arkdeck-agentd`'s `ARTIFACT_QUOTA`),
/// which the oracle's Artifact store is given.
const ARTIFACT_QUOTA: u64 = 8 * 1024 * 1024 * 1024;
/// The oracle's clock, 2026-09-26T00:00:00Z, in seconds since 2001 as the
/// daemon hands it to an export preview.
const NOW: f64 = 1_790_380_800.0 - 978_307_200.0;
const SESSION: &str = "session-fixture";

/// Serializes every user of the fixed root: another worktree's run of this
/// binary would otherwise remove the root under this one.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

fn oracle() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/storage-lock-wait-oracle")
}

fn frames() -> Vec<Value> {
    fs::read_to_string(oracle().join("frames.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// The fixed root, rebuilt with the oracle's retained Session in the root
/// the requests select; removed when the test ends.
struct Root(PathBuf);

impl Root {
    fn fixed() -> Self {
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        let session = root.join("custom/2026/09").join(SESSION);
        for directory in [
            root.clone(),
            root.join("session-state"),
            root.join("sessions"),
            root.join("custom"),
            root.join("artifacts"),
            root.join("custom/2026"),
            root.join("custom/2026/09"),
            session.clone(),
        ] {
            fs::create_dir(&directory).unwrap();
            chmod(&directory, 0o700);
        }
        let file = |name: &str, bytes: &[u8]| {
            fs::write(session.join(name), bytes).unwrap();
            chmod(&session.join(name), 0o600);
        };
        file(
            ".session-identity.json",
            br#"{"jobId":"job-fixture","schemaVersion":"1.0.0","sessionId":"session-fixture"}"#,
        );
        file(
            "manifest.json",
            &fs::read(oracle().join("manifest.json")).unwrap(),
        );
        file("payload.bin", &[0x53; 48]);
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The oracle's labels for a random or host value, and a Session root under
/// `/private/tmp` read as Swift reads it: `resolvingSymlinksInPath` and
/// `standardizedFileURL` drop `/private` where the path without it exists. A
/// difference this slice leaves as it is; a root outside `/private` shows
/// none.
fn labelled(mut answer: Value) -> Value {
    let Some(result) = answer.get_mut("result").and_then(Value::as_object_mut) else {
        return answer;
    };
    if let Some(root) = result
        .get_mut("sessionDomain")
        .and_then(|domain| domain.get_mut("rootPath"))
        && let Some(path) = root
            .as_str()
            .and_then(|path| path.strip_prefix("/private/tmp/"))
    {
        *root = json!(format!("/tmp/{path}"));
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
    answer
}

/// The Rust daemon's answer to one recorded request, as `arkdeck-agentd`'s
/// `runtime_storage` and its Session resource routes compose it.
fn answer(sessions: &SessionStore, artifacts: &ArtifactUsage, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let params: Map<String, Value> = frame["params"].as_object().cloned().unwrap_or_default();
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
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    };
    support::hdc_oracle::assert_conforms(method, &answer);
    labelled(answer)
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
    // Taken first, so the root is removed before the lock is released.
    let _lock = exclusive();
    let root = Root::fixed();
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
                answer(&sessions, &artifacts, frame),
                recorded(frame),
                "frame {index}"
            );
            continue;
        };
        let (sender, receiver) = mpsc::channel();
        std::thread::scope(|scope| {
            let (sessions, artifacts) = (&sessions, &artifacts);
            scope.spawn(move || sender.send(answer(sessions, artifacts, frame)).unwrap());
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
