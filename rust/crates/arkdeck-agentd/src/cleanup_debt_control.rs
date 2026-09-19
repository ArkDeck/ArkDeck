//! `cleanupDebt.list` through the control layer, against the daemon's own
//! host, as the Swift daemon answers it. Each frame of the committed corpus is
//! answered from a ledger that owes what the frame lists, in the reverse of
//! the listed order and beside a settled record, so the listing orders and
//! filters it; a host without an Artifact owner answers as the read-only
//! foundation, and an undecodable ledger fails the whole list with Swift's
//! store error. The control layer admits each answer under the compiled method
//! schema. Nothing here writes the ledger.
use arkdeck_contract::{MAX_REQUEST_BYTES, Request, Response, decode_response, encode_frame};
use arkdeck_control::Control;
use arkdeck_hoststore::ArtifactReadStore;
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

const LEDGER: &str = "cleanup-debt.json";

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "cleanup-debt-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
    fn control(&self) -> Control<crate::host::Host> {
        Control::new(
            crate::host::Host::from_environment()
                .with_artifacts(ArtifactReadStore::open(&self.0).unwrap()),
        )
        .unwrap()
    }
    /// The ledger as the Runtime writes it: owner-only, as the host store
    /// reads every file.
    fn owe(&self, records: &[Value]) {
        let ledger = self.0.join(LEDGER);
        fs::write(&ledger, serde_json::to_vec(records).unwrap()).unwrap();
        fs::set_permissions(&ledger, fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn corpus() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/cleanupDebt.list.jsonl",
    );
    fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn list<H: arkdeck_control::HostServices>(control: &Control<H>, params: Value) -> Response {
    let request = Request::new("test", "cleanupDebt.list", params.as_object().cloned());
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let response = control.handle_frame(&frame[..frame.len() - 1]);
    decode_response(&response[..response.len() - 1], "test", "cleanupDebt.list").unwrap()
}

/// The ledger record a listed row was projected from, with no retry begun.
fn owed(row: &Value) -> Value {
    let mut record = json!({
        "jobID": row["jobId"], "stepID": row["stepId"], "remotePath": row["remotePath"],
        "reason": row["reason"], "recordedAtUTC": row["recordedAtUtc"],
    });
    if !row["bundleName"].is_null() {
        record["bundleName"] = row["bundleName"].clone();
    }
    record
}

#[test]
fn every_list_of_the_corpus_is_answered_as_swift_recorded_it() {
    let frames = corpus();
    assert!(frames.len() >= 3, "{} frames", frames.len());
    for (index, recorded) in frames.iter().enumerate() {
        let root = Root::new();
        let rows = recorded["result"].as_array().unwrap();
        if !rows.is_empty() {
            let mut records: Vec<Value> = rows.iter().rev().map(owed).collect();
            let mut settled = owed(&rows[0]);
            settled["remotePath"] = json!("/data/local/tmp/arkdeck-settled");
            settled["settledAtUTC"] = json!("2026-09-14T00:00:01Z");
            records.push(settled);
            root.owe(&records);
        }
        let params = recorded.get("params").cloned().unwrap_or(Value::Null);
        let answer = list(&root.control(), params).outcome;
        assert_eq!(answer.unwrap(), recorded["result"], "frame {}", index + 1);
        if rows.is_empty() {
            assert!(!root.0.join(LEDGER).exists(), "a list writes no ledger");
        }
    }
}

#[test]
fn a_host_without_artifacts_or_with_an_undecodable_ledger_lists_nothing() {
    let standalone = Control::new(crate::host::Host::from_environment()).unwrap();
    let refused = list(&standalone, json!({})).outcome.unwrap_err();
    assert_eq!(refused.code, "rejected");
    assert_eq!(
        refused.message,
        "this method is unavailable in the read-only Rust foundation"
    );
    let root = Root::new();
    let unreasoned = json!({"jobID": "job-a", "stepID": "cleanup", "remotePath": "/data/a",
        "recordedAtUTC": "2026-09-14T00:00:00Z"});
    root.owe(&[unreasoned]);
    let failed = list(&root.control(), json!({})).outcome.unwrap_err();
    assert_eq!(failed.code, "internalError");
    assert_eq!(
        failed.message,
        "indexCorrupted(\"undecodable cleanup debt ledger: reason\")"
    );
    assert!(failed.details.is_none());
}
