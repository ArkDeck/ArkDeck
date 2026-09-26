//! Swift's answers to `artifact.import.*` refusals, replayed against this
//! owner as the daemon routes each method (TASK-XPA-013):
//! - `rust/tests/fixtures/import-refusal-oracle`, which Swift's
//!   `ImportRefusalOracleContractTests` recorded for the refusals the
//!   ControlFrames corpus holds no frame of;
//! - the corpus's own Import refusal frames that this owner answers.
//!
//! Each answer's code, message and details are Swift's, byte for byte.
use super::*;
use crate::job_owner::import_references::ImportReference;
use crate::{ArtifactReadStore, JobRecord, JobStore, OperationRequest, TargetStore};
use arkdeck_contract::encode_import_chunk;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

const NOW: &str = "2026-09-12T00:00:00Z";
/// The one Target of `tests/fixtures/import-target-current/direct`, at binding
/// revision 1 as the Target the Swift oracle adopted.
const TARGET: &str = "TGT-dddddddddddd";

struct Fixture {
    root: PathBuf,
    store: ImportUploadStore,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    targets: TargetStore,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "import-refusal-oracle-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for name in ["artifacts", "targets", "jobs-state"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(name))
                .unwrap();
        }
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/import-target-current/direct");
        for name in ["targets.json", "target-display-names.json"] {
            let path = root.join("targets").join(name);
            fs::copy(source.join(name), &path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        Self {
            store: ImportUploadStore::open(&root.join("artifacts")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
            targets: TargetStore::open(&root.join("targets")).unwrap(),
            root,
        }
    }
    /// The daemon's routing of an Import method to its owner
    /// (`arkdeck-agentd` `Host::imports_for`), with the real Target owner.
    fn call(&self, method: &str, params: &Value) -> Result<Value, WireError> {
        let params = params.as_object().unwrap();
        let resolve = |intent: &ImportIntent| self.targets.resolve_import_binding(intent);
        match method {
            "artifact.import.release"
            | "artifact.import.inspection"
            | "artifact.import.inspect" => {
                self.store
                    .lifecycle_resource(&self.artifacts, &self.jobs, method, params, NOW)
            }
            "artifact.import.list" => self.store.list_with_artifacts(params, &self.artifacts),
            "artifact.import.commit" => {
                self.store
                    .commit(params, NOW, false, &self.artifacts, u64::MAX, resolve)
            }
            _ => self
                .store
                .handle_resource(method, params, NOW, false, resolve),
        }
    }
    /// A queued analyzer Job whose input is the committed Import's lease, the
    /// `index`th of its kind.
    fn admit_referencing_job(&self, lease: &str, index: usize) {
        let request = OperationRequest::decode(&serde_json::to_vec(&json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0","requestId":format!("req-oracle-reference-{index}"),"idempotencyKey":format!("idem-oracle-reference-{index}"),"target":{"targetId":"TGT-fixture"},"operation":{"id":"analyzer.extract-crash-signature","version":1},"inputs":{"sourceArtifactRef":lease}})).unwrap()).unwrap();
        let value = json!({"jobID":format!("job-oracle-reference-{index}"),"request":request.canonical_value(),"originalSubmissionRequest":request.canonical_value(),"operationReference":"analyzer.extract-crash-signature@1","catalogDigest":arkdeck_contract::CATALOG_DIGEST,"providerID":"analyzer","createdAtUTC":NOW,"state":"queued","outcomeUnknown":false,"timeline":[],"actualStepKinds":[],"skipReasons":{}});
        let record = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        self.jobs.admit(&record, &request.fingerprint()).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

/// The oracle's HAP: the ZIP magic, then 4,092 bytes of `a`.
fn hap() -> Vec<u8> {
    let mut bytes = b"PK\x03\x04".to_vec();
    bytes.resize(4096, b'a');
    bytes
}
fn metadata(request: &str, bytes: &[u8]) -> Value {
    json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,"kind":"hap","targetId":TARGET,"bindingRevision":"1","deviceProfile":null,"name":"fixture.hap","byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes)})
}
fn chunk(id: &str, bytes: &[u8], offset: usize, generation: &str) -> Value {
    json!({"importId":id,"generation":generation,"offset":offset.to_string(),"byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes),"base64":encode_import_chunk(bytes).unwrap()})
}
fn answer(result: Result<Value, WireError>) -> Value {
    match result {
        Ok(value) => json!({ "ok": value }),
        Err(error) => json!({"code":error.code,"message":error.message,"details":error.details}),
    }
}
/// A recorded runtime identity, as this fixture's.
fn substituted(value: &Value, names: &[(&str, &str)]) -> Value {
    match value {
        Value::String(text) => names
            .iter()
            .find(|(name, _)| name == text)
            .map_or_else(|| value.clone(), |(_, actual)| json!(actual)),
        Value::Object(fields) => Value::Object(
            fields
                .iter()
                .map(|(key, value)| (key.clone(), substituted(value, names)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(|v| substituted(v, names)).collect()),
        _ => value.clone(),
    }
}
/// An upload with the first half of the HAP and a committed one, as the
/// oracle recorded them: their Import identities and the committed lease.
fn uploads(fixture: &Fixture) -> (String, String, String) {
    let bytes = hap();
    let live = fixture
        .call("artifact.import.begin", &metadata("oracle-live", &bytes))
        .unwrap()["importId"]
        .as_str()
        .unwrap()
        .to_owned();
    fixture
        .call(
            "artifact.import.append",
            &chunk(&live, &bytes[..2048], 0, "1"),
        )
        .unwrap();
    let staged = fixture
        .call(
            "artifact.import.begin",
            &metadata("oracle-committed", &bytes),
        )
        .unwrap()["importId"]
        .as_str()
        .unwrap()
        .to_owned();
    fixture
        .call("artifact.import.append", &chunk(&staged, &bytes, 0, "1"))
        .unwrap();
    let committed = fixture
        .call(
            "artifact.import.commit",
            &json!({"importId":staged,"generation":"1"}),
        )
        .unwrap();
    assert_eq!(committed["state"], "committed");
    let lease = committed["receipt"]["lease"].as_str().unwrap().to_owned();
    (live, staged, lease)
}

#[test]
fn swift_recorded_refusals_the_corpus_lacks_are_answered_in_swift_s_words() {
    let fixture = Fixture::new();
    let (live, committed, lease) = uploads(&fixture);
    let names = [
        ("$liveImportId", live.as_str()),
        ("$committedImportId", committed.as_str()),
        ("$targetId", TARGET),
    ];
    let oracle: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/import-refusal-oracle/cases.json"
    ))
    .unwrap();
    assert_eq!(oracle["schemaVersion"], "arkdeck.import-refusal-oracle/1");
    let cases = oracle["wire"].as_array().unwrap();
    assert_eq!(cases.len(), 40);
    let targets = fixture.root.join("targets/targets.json");
    let mut hold = None;
    for case in cases {
        let name = case["case"].as_str().unwrap();
        let method = case["method"].as_str().unwrap();
        let params = substituted(&case["params"], &names);
        // The states Swift recorded these in: a materialization of the
        // committed Import, then a Job referencing it, then a Target store
        // that cannot be read, restored afterwards.
        let saved = match name {
            "release.activeMaterialization" => {
                let reference = ImportReference::parse(&lease).unwrap().unwrap();
                hold = fixture
                    .store
                    .acquire_inputs(&fixture.artifacts, &[reference])
                    .unwrap();
                assert!(hold.is_some());
                None
            }
            "release.activeJob" => {
                drop(hold.take());
                fixture.admit_referencing_job(&lease, 0);
                None
            }
            "begin.targetStoreUnreadable" => {
                let saved = fs::read(&targets).unwrap();
                fs::write(&targets, b"{").unwrap();
                Some(saved)
            }
            _ => None,
        };
        let actual = answer(fixture.call(method, &params));
        if let Some(saved) = saved {
            fs::write(&targets, saved).unwrap();
        }
        assert_eq!(actual, case["error"], "{name}");
    }
}

/// Swift's recorded refusal of `method` with this code and message.
fn corpus_refusal(method: &str, code: &str, message: &str) -> Value {
    recorded_refusal(method, code, message)
        .unwrap_or_else(|| panic!("no Swift frame of {method} answers {code}: {message}"))
}

/// check-contracts' published view: this checkout's code with the merge
/// base's contract inputs, the corpus among them.
fn published_view() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// The Import owner's refusal with this code and message, which a corpus
/// frame TASK-XPA-017 appended records. Wherever this view's corpus holds the
/// frame, the answer is that frame, byte for byte. The published view's corpus
/// is the merge base's and may predate it: only there may the frame be
/// missing, and the owner is held to the same answer without its witness.
fn appended_refusal(method: &str, code: &str, message: &str) -> Value {
    let answer = json!({"code":code,"message":message,
        "details":{"newDispatchCount":0,"phase":"importOwner"}});
    match recorded_refusal(method, code, message) {
        Some(swift) => assert_eq!(swift, answer, "{method} {code}"),
        None => assert!(
            published_view(),
            "no Swift frame of {method} answers {code}: {message}"
        ),
    }
    answer
}

/// Swift's recorded refusal of `method` with this code and message, if this
/// view's corpus holds one.
fn recorded_refusal(method: &str, code: &str, message: &str) -> Option<Value> {
    let corpus = match method {
        "artifact.import.abort" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.abort.jsonl"
        ),
        "artifact.import.append" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.append.jsonl"
        ),
        "artifact.import.begin" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.begin.jsonl"
        ),
        "artifact.import.inspect" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.inspect.jsonl"
        ),
        "artifact.import.inspection" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.inspection.jsonl"
        ),
        "artifact.import.list" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.list.jsonl"
        ),
        "artifact.import.release" => include_str!(
            "../../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.release.jsonl"
        ),
        _ => unreachable!("{method}"),
    };
    corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|frame| {
            frame["ok"] == false
                && frame["error"]["code"] == code
                && frame["error"]["message"] == message
        })
        .map(|frame| frame["error"].clone())
}

#[test]
fn corpus_import_refusals_are_answered_as_swift_s_daemon_answered_them() {
    let fixture = Fixture::new();
    let (live, committed, _) = uploads(&fixture);
    let bytes = hap();
    let mut misnamed = metadata("oracle-misnamed", &bytes);
    misnamed["name"] = json!("fixture.txt");
    let mut corrupt = chunk(&live, &bytes[2048..], 2048, "1");
    corrupt["sha256"] = json!(sha256_hex(b"other"));
    for (method, params, code, message) in [
        (
            "artifact.import.begin",
            json!({}),
            "invalidInput",
            "Import requires registered metadata and exact target/binding references",
        ),
        (
            "artifact.import.begin",
            misnamed,
            "invalidInput",
            "Import requires registered metadata and exact target/binding references",
        ),
        (
            "artifact.import.append",
            json!({}),
            "invalidInput",
            "Import control parameters are closed",
        ),
        (
            "artifact.import.append",
            chunk(&live, &bytes[4000..], 4000, "1"),
            "resourceConflict",
            "Import chunk does not start at the committed offset",
        ),
        (
            "artifact.import.append",
            corrupt,
            "artifactIntegrityFailed",
            "Import chunk size or digest is invalid",
        ),
        (
            "artifact.import.append",
            chunk(
                "imp-00000000-0000-4000-8000-000000000001",
                &bytes[2048..],
                2048,
                "1",
            ),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            "artifact.import.abort",
            json!({}),
            "invalidInput",
            "Import control parameters are closed",
        ),
        (
            "artifact.import.abort",
            json!({"importRequestId":"missing-import","generation":"1"}),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            "artifact.import.abort",
            json!({"importRequestId":"oracle-live","generation":"9"}),
            "resourceConflict",
            "Import commit or another generation owns this upload",
        ),
        (
            "artifact.import.inspect",
            json!({}),
            "invalidInput",
            "exactly one Import selector is required",
        ),
        (
            "artifact.import.inspect",
            json!({"importRequestId":"view-hap"}),
            "resourceNotFound",
            "Import does not exist",
        ),
        (
            "artifact.import.inspection",
            json!({}),
            "invalidInput",
            "exactly one Import selector is required",
        ),
        (
            "artifact.import.list",
            json!({"pageSize":0}),
            "invalidInput",
            "invalid pageSize",
        ),
        (
            "artifact.import.list",
            json!({"state":"unknown"}),
            "invalidInput",
            "Import filter is invalid",
        ),
        (
            "artifact.import.release",
            json!({}),
            "invalidInput",
            "Import control parameters are closed",
        ),
        (
            "artifact.import.release",
            json!({"importId":committed,"generation":"3"}),
            "resourceConflict",
            "release requires the exact committed Import generation",
        ),
    ] {
        assert_eq!(
            answer(fixture.call(method, &params)),
            corpus_refusal(method, code, message),
            "{method} {params}"
        );
    }
    // An Import this Runtime never began, by either selector, and its
    // release (TASK-XPA-017).
    for (method, params) in [
        (
            "artifact.import.inspection",
            json!({"importId":"imp-00000000-0000-0000-0000-000000000001"}),
        ),
        (
            "artifact.import.inspection",
            json!({"importRequestId":"never-began"}),
        ),
        (
            "artifact.import.release",
            json!({"importId":"imp-00000000-0000-0000-0000-000000000001","generation":"2"}),
        ),
    ] {
        assert_eq!(
            answer(fixture.call(method, &params)),
            appended_refusal(method, "resourceNotFound", "Import does not exist"),
            "{method} {params}"
        );
    }
}

/// Swift's inspection reports at most 1,000 active Jobs referencing an
/// Import, and refuses the inspection of one more referenced than that with
/// the corpus's `inputTooLarge` (`RuntimeAdmissionService.
/// activeImportReferenceJobs`, TASK-XPA-017). This owner holds the same
/// bound: 1,000 are reported, the 1,001st refuses as Swift refused it.
#[test]
fn an_inspection_past_its_job_bound_is_refused_as_swift_s_daemon_refused_it() {
    let fixture = Fixture::new();
    let (_, committed, lease) = uploads(&fixture);
    let inspection = json!({ "importId": committed });
    for index in 0..1000 {
        fixture.admit_referencing_job(&lease, index);
    }
    let reported = fixture
        .call("artifact.import.inspection", &inspection)
        .unwrap();
    assert_eq!(reported["references"]["state"], "referenced");
    assert_eq!(
        reported["references"]["activeJobIds"]
            .as_array()
            .unwrap()
            .len(),
        1000
    );
    fixture.admit_referencing_job(&lease, 1000);
    assert_eq!(
        answer(fixture.call("artifact.import.inspection", &inspection)),
        appended_refusal(
            "artifact.import.inspection",
            "inputTooLarge",
            "Import reference inspection exceeds its Job bound"
        )
    );
}

/// Swift guards concurrent begins of one request identity in memory and
/// refuses all but the first ("Import begin is already in progress"). This
/// owner holds its lock across the lookup, the binding and the durable
/// record, so a concurrent begin waits and is answered as Swift answers a
/// repeated one: the same Import, or `idempotencyConflict` for other
/// metadata. One Import is ever allocated and no half state remains.
#[test]
fn concurrent_begins_of_one_request_allocate_one_import() {
    let fixture = Fixture::new();
    let bytes = hap();
    let rounds = 16;
    let mut allocated = Vec::new();
    for round in 0..rounds {
        let request = format!("oracle-concurrent-{round}");
        let first = metadata(&request, &bytes);
        let mut second = first.clone();
        second["name"] = json!("other.hap");
        let barrier = std::sync::Barrier::new(8);
        let answers: Vec<(Value, Value)> = std::thread::scope(|scope| {
            let threads: Vec<_> = (0..8)
                .map(|thread| {
                    // Odd rounds race two metadata for one request identity.
                    let params = if round % 2 == 1 && thread % 2 == 1 {
                        second.clone()
                    } else {
                        first.clone()
                    };
                    let (barrier, fixture) = (&barrier, &fixture);
                    scope.spawn(move || {
                        barrier.wait();
                        let answer = answer(fixture.call("artifact.import.begin", &params));
                        (params, answer)
                    })
                })
                .collect();
            threads.into_iter().map(|t| t.join().unwrap()).collect()
        });
        let accepted: Vec<&Value> = answers.iter().filter_map(|(_, a)| a.get("ok")).collect();
        assert!(!accepted.is_empty(), "{round}");
        assert!(accepted.iter().all(|a| *a == accepted[0]), "{round}");
        let won = &accepted[0]["metadata"];
        for (params, answer) in &answers {
            if params == won {
                assert_eq!(answer.get("ok"), Some(accepted[0]), "{round}");
            } else {
                assert_eq!(
                    answer,
                    &json!({"code":"idempotencyConflict","message":"Import request identity already names different metadata","details":{"newDispatchCount":0,"phase":"importOwner"}}),
                    "{round}"
                );
            }
        }
        assert_eq!(accepted[0]["state"], "inProgress");
        assert_eq!(accepted[0]["generation"], "1");
        assert_eq!(accepted[0]["nextOffset"], "0");
        allocated.push(accepted[0]["importId"].as_str().unwrap().to_owned());
    }
    // One durable record, one identity and one empty staging file per
    // request, and nothing temporary left behind.
    let imports = fixture.root.join("artifacts/.imports-v1");
    let entries = |name: &str| {
        let mut names: Vec<String> = fs::read_dir(imports.join(name))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    };
    let records = entries("records");
    assert_eq!(records.len(), rounds, "{records:?}");
    for round in 0..rounds {
        let request = format!("oracle-concurrent-{round}");
        assert!(records.contains(&format!("{}.json", sha256_hex(request.as_bytes()))));
    }
    let mut identities: Vec<String> = allocated.iter().map(|id| format!("{id}.json")).collect();
    identities.sort();
    assert_eq!(entries("identities"), identities);
    let mut staged: Vec<String> = allocated.iter().map(|id| format!("{id}.stage")).collect();
    staged.sort();
    assert_eq!(entries("payloads"), staged);
    for name in &staged {
        assert_eq!(
            fs::metadata(imports.join("payloads").join(name))
                .unwrap()
                .len(),
            0
        );
    }
}
