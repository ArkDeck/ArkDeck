//! `cleanupDebt.list` and `cleanupDebt.continue` through the control layer,
//! against the daemon's own host, as the Swift daemon answers them. Each list
//! frame of the committed corpus is answered from a ledger that owes what the
//! frame lists, in the reverse of the listed order and beside a settled
//! record, so the listing orders and filters it; an undecodable ledger fails
//! the whole list with Swift's store error. The continuation corpus's refusal
//! of a request naming no debt is answered as recorded, and a debt the ledger
//! does not owe is refused before anything is read or sent; its recorded
//! continuations need the Jobs of the device oracles, whose replays in
//! `arkdeck-hoststore` answer them. A host without the owners answers as the
//! read-only foundation. The control layer admits each answer under the
//! compiled method schema. Nothing here writes the ledger.
use arkdeck_contract::{MAX_REQUEST_BYTES, Request, Response, decode_response, encode_frame};
use arkdeck_control::Control;
use arkdeck_hoststore::{ArtifactReadStore, JobStore};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

const LEDGER: &str = "cleanup-debt.json";
const FOUNDATION: &str = "this method is unavailable in the read-only Rust foundation";

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "cleanup-debt-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["artifacts", "jobs"] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(root.join(name))
                .unwrap();
        }
        Self(root)
    }
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    fn control(&self) -> Control<crate::host::Host> {
        Control::new(
            crate::host::Host::from_environment()
                .with_artifacts(ArtifactReadStore::open(&self.artifacts()).unwrap())
                .with_jobs(JobStore::open(&self.0.join("jobs")).unwrap()),
        )
        .unwrap()
    }
    /// The ledger as the Runtime writes it: owner-only, as the host store
    /// reads every file.
    fn owe(&self, records: &[Value]) {
        let ledger = self.artifacts().join(LEDGER);
        fs::write(&ledger, serde_json::to_vec(records).unwrap()).unwrap();
        fs::set_permissions(&ledger, fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn corpus(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn call<H: arkdeck_control::HostServices>(
    control: &Control<H>,
    method: &str,
    params: Value,
) -> Response {
    let request = Request::new("test", method, params.as_object().cloned());
    let frame = encode_frame(&request, MAX_REQUEST_BYTES).unwrap();
    let response = control.handle_frame(&frame[..frame.len() - 1]);
    decode_response(&response[..response.len() - 1], "test", method).unwrap()
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
    let frames = corpus("cleanupDebt.list");
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
        let answer = call(&root.control(), "cleanupDebt.list", params).outcome;
        assert_eq!(answer.unwrap(), recorded["result"], "frame {}", index + 1);
        if rows.is_empty() {
            assert!(
                !root.artifacts().join(LEDGER).exists(),
                "a list writes no ledger"
            );
        }
    }
}

#[test]
fn a_continuation_naming_no_owed_debt_is_refused_as_swift_refuses_it() {
    let refusals: Vec<Value> = corpus("cleanupDebt.continue")
        .into_iter()
        .filter(|recorded| recorded["ok"] == false)
        .collect();
    assert!(!refusals.is_empty());
    let root = Root::new();
    for recorded in refusals {
        let params = recorded.get("params").cloned().unwrap_or(Value::Null);
        let error = call(&root.control(), "cleanupDebt.continue", params)
            .outcome
            .unwrap_err();
        assert_eq!(
            serde_json::to_value(&error).unwrap(),
            recorded["error"],
            "{recorded}"
        );
    }
    // A debt the ledger does not owe is refused before anything is read.
    let error = call(
        &root.control(),
        "cleanupDebt.continue",
        json!({"jobId": "job-a", "remotePath": "/data/local/tmp/a"}),
    )
    .outcome
    .unwrap_err();
    assert_eq!(error.code, "rejected");
    assert_eq!(
        error.message,
        "jobNotFound(\"cleanup-debt:job-a:/data/local/tmp/a\")"
    );
    assert!(error.details.is_none());
    assert!(!root.artifacts().join(LEDGER).exists());
}

#[test]
fn a_host_without_the_owners_or_with_an_undecodable_ledger_answers_neither() {
    let standalone = Control::new(crate::host::Host::from_environment()).unwrap();
    for method in ["cleanupDebt.list", "cleanupDebt.continue"] {
        let refused = call(&standalone, method, json!({})).outcome.unwrap_err();
        assert_eq!(refused.code, "rejected", "{method}");
        assert_eq!(refused.message, FOUNDATION, "{method}");
    }
    let root = Root::new();
    let unreasoned = json!({"jobID": "job-a", "stepID": "cleanup", "remotePath": "/data/a",
        "recordedAtUTC": "2026-09-14T00:00:00Z"});
    root.owe(&[unreasoned]);
    let listed = call(&root.control(), "cleanupDebt.list", json!({}))
        .outcome
        .unwrap_err();
    let continued = call(
        &root.control(),
        "cleanupDebt.continue",
        json!({"jobId": "job-a", "remotePath": "/data/a"}),
    )
    .outcome
    .unwrap_err();
    for failed in [listed, continued] {
        assert_eq!(failed.code, "internalError");
        assert_eq!(
            failed.message,
            "indexCorrupted(\"undecodable cleanup debt ledger: reason\")"
        );
        assert!(failed.details.is_none());
    }
}
