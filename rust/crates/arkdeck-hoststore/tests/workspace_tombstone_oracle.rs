//! Replays the Swift oracle of a workspace project removed after its presets
//! (`rust/tests/fixtures/workspace-tombstone-oracle`, recorded by
//! `WorkspaceTombstoneOracleContractTests` once the Swift owner accepted a
//! removed preset whose project is gone) against the Rust registration owner
//! over the same fixed root and clock: every answer must be Swift's, byte for
//! byte, and admitted by the published method schemas — the store reads again
//! after the removal, a tombstone damaged in the file is still refused, and
//! the restored file reads again.
//!
//! `before-fix-frames.jsonl` is the same exchange recorded before the fix, the
//! defect's evidence: every read after the removal refused, for good.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{WorkspaceProjectStore, WorkspaceReference};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::PathBuf;
use support::chmod;

/// The recording's fixed root: the registration pins the project's root.
const ROOT: &str = "/private/tmp/arkdeck-workspace-tombstone-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-tombstone-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";

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
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/workspace-tombstone-oracle")
}

fn frames(name: &str) -> Vec<Value> {
    fs::read_to_string(oracle().join(name))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// The fixed root, rebuilt; removed when the test ends.
struct Root(PathBuf);

impl Root {
    fn fixed() -> Self {
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        for directory in [
            root.clone(),
            root.join("project"),
            root.join("state"),
            root.join("state/workspace-projects"),
        ] {
            fs::create_dir(&directory).unwrap();
            chmod(&directory, 0o700);
        }
        Self(root)
    }

    fn document(&self) -> PathBuf {
        self.0.join("state/workspace-projects/projects.json")
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The Rust owner's answer to one recorded request, as the control plane
/// frames it; no Job exists, so the census finds none.
fn answer(store: &WorkspaceProjectStore, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let params: Map<String, Value> = frame["params"].as_object().cloned().unwrap_or_default();
    let census = |_: WorkspaceReference<'_>| -> Result<(), WireError> { Ok(()) };
    let answer = match store.handle(method, &params, &|| TIMESTAMP.to_owned(), &census) {
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
    answer
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

#[test]
fn a_project_removed_after_its_presets_leaves_a_store_that_reads_as_swift_s() {
    // Taken first, so the root is removed before the lock is released.
    let _lock = exclusive();
    let root = Root::fixed();
    let store = WorkspaceProjectStore::open(&root.0.join("state/workspace-projects")).unwrap();
    let recording = frames("frames.jsonl");
    let methods: Vec<&str> = recording
        .iter()
        .map(|frame| frame["method"].as_str().unwrap())
        .collect();
    assert_eq!(
        methods,
        [
            "workspace.project.register",
            "workspace.preset.register",
            "workspace.preset.remove",
            "workspace.project.remove",
            "workspace.preset.remove",
            "workspace.project.list",
            "workspace.project.show",
            "workspace.preset.list",
            "workspace.project.register",
            "workspace.project.list",
            "workspace.preset.list",
            "workspace.preset.register",
            "workspace.project.list",
            "workspace.preset.list",
            "workspace.project.list",
        ]
    );
    let mut original = Vec::new();
    for (index, frame) in recording.iter().enumerate() {
        if index == 12 {
            // The tombstone's last mutation digest altered in the file.
            original = fs::read(root.document()).unwrap();
            let text = String::from_utf8(original.clone()).unwrap();
            let document: Value = serde_json::from_str(&text).unwrap();
            let digest = document["presets"][0]["lastMutationDigest"]
                .as_str()
                .unwrap()
                .to_owned();
            assert_eq!(text.matches(&digest).count(), 1);
            fs::write(root.document(), text.replace(&digest, &"0".repeat(64))).unwrap();
        }
        if index == 14 {
            fs::write(root.document(), &original).unwrap();
        }
        assert_eq!(
            answer(&store, frame),
            recorded(frame),
            "frame {index}: {}",
            frame["method"]
        );
    }
    // The evidence: the same exchange before the fix, every answer after the
    // removal refused.
    let before = frames("before-fix-frames.jsonl");
    assert_eq!(before.len(), recording.len());
    for (index, frame) in before.iter().enumerate().skip(4) {
        assert_eq!(frame["error"]["code"], "recordUnreadable", "frame {index}");
        assert_eq!(
            frame["error"]["message"],
            "workspace preset store record is inconsistent"
        );
    }
}
