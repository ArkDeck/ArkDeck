//! Real Import, Target, Artifact and Job owners behind the App boundary, with
//! a synthetic kernel-origin peer. No signed XPC peer, device or installed
//! Runtime is represented, and no HDC server is started. The reads, Trace
//! maintenance and Debug probe over the production owners, whose probe runs a
//! fake HDC, are `tests/spawning`'s (see `app_ingress_fake_hdc.rs` there).
use super::*;
use arkdeck_contract::{
    Request, WireError, canonical_json, encode_import_chunk, sha256_hex, validate_method_value,
};
use arkdeck_hoststore::{
    ArtifactReadStore, ImportUploadFault, ImportUploadStore, JobStore, TargetStore,
};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

/// A ZIP-headed HAP, the content the Import owner's HAP validator accepts.
const HAP: &[u8] = b"PK\x03\x04app-owned upload through the App ingress";

type Reached = Arc<Mutex<Vec<ImportUploadFault>>>;
/// The production Host's Import, Target, Artifact and Job owners over `root`. Every
/// write step the Import owner reaches is recorded; `fail` loses that step's
/// answer after its durable effect, as a crash or lost reply would.
fn compose(
    root: &Root,
    fail: Option<ImportUploadFault>,
) -> (Arc<Control<crate::host::Host>>, Reached) {
    let reached = Reached::default();
    let seen = reached.clone();
    let imports = ImportUploadStore::open_with_fault(
        &root.0.join("artifacts"),
        Arc::new(move |point| {
            seen.lock().unwrap().push(point);
            if Some(point) == fail {
                Err(std::io::Error::other("the answer after this step is lost"))
            } else {
                Ok(())
            }
        }),
    )
    .unwrap();
    let host = crate::host::Host::from_environment()
        .with_targets(TargetStore::open(&root.0.join("targets")).unwrap())
        .with_imports(imports)
        .with_artifacts(ArtifactReadStore::open(&root.0.join("artifacts")).unwrap())
        .with_jobs(JobStore::open_owner(&root.0.join("jobs")).unwrap());
    (Arc::new(Control::new(host).unwrap()), reached)
}
/// What ClientKit `RuntimeAppArtifactUpload` sends to begin an upload.
fn begin(request: &str, kind: &str) -> Value {
    let (name, profile, bytes) = match kind {
        "native-library" => ("libfixture.so", Value::Null, [b'a'; 64].to_vec()),
        "flash-bundle" => ("images.tar.gz", json!("dayu200"), HAP.to_vec()),
        "workspace-patch" => ("fixture.patch", Value::Null, HAP.to_vec()),
        _ => ("fixture.hap", Value::Null, HAP.to_vec()),
    };
    json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,"kind":kind,
        "targetId":TARGET,"bindingRevision":"1","deviceProfile":profile,"name":name,
        "byteCount":bytes.len().to_string(),"sha256":sha256_hex(&bytes)})
}
fn append(id: &str) -> Value {
    json!({"importId":id,"generation":"1","offset":"0","byteCount":HAP.len().to_string(),
        "sha256":sha256_hex(HAP),"base64":encode_import_chunk(HAP).unwrap()})
}
fn selector(id: &str) -> Value {
    json!({"importId":id,"generation":"1"})
}
fn record(root: &Root, request: &str) -> Value {
    let path = root
        .0
        .join("artifacts/.imports-v1/records")
        .join(format!("{}.json", sha256_hex(request.as_bytes())));
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}
/// Every directory and file under `path`, with the bytes of each file.
fn tree(path: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut entries = BTreeMap::new();
    let mut pending = vec![path.to_owned()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                pending.push(entry.path());
                entries.insert(entry.path(), Vec::new());
            } else {
                entries.insert(entry.path(), fs::read(entry.path()).unwrap());
            }
        }
    }
    entries
}

#[test]
fn app_uploads_publish_once_as_app_owned_and_keep_their_owner_across_restart() {
    let root = uploads();
    let (control, reached) = compose(&root, None);
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    let began = result(
        &call("artifact.import.begin", begin("app-upload", "hap")),
        "artifact.import.begin",
    );
    assert_eq!(
        (&began["state"], &began["generation"], &began["nextOffset"]),
        (&json!("inProgress"), &json!("1"), &json!("0"))
    );
    let id = began["importId"].as_str().unwrap().to_owned();
    // Provenance is the owner's own durable record, written with the Import.
    assert_eq!(record(&root, "app-upload")["appOwned"], true);
    let appended = result(
        &call("artifact.import.append", append(&id)),
        "artifact.import.append",
    );
    assert_eq!(appended["nextOffset"], HAP.len().to_string());
    let committed = result(
        &call("artifact.import.commit", selector(&id)),
        "artifact.import.commit",
    );
    assert_eq!(
        (&committed["state"], &committed["generation"]),
        (&json!("committed"), &json!("2"))
    );
    let receipt = &committed["receipt"];
    let artifact = receipt["artifactId"].as_str().unwrap();
    assert_eq!(receipt["lease"], format!("lease-v1:{id}:{artifact}"));
    assert_eq!(
        receipt["validation"],
        json!({"kind":"hap","container":"zip"})
    );
    assert_eq!(
        fs::read(root.0.join("artifacts").join(&id).join(artifact)).unwrap(),
        HAP
    );
    // Three requests, three owner calls, one publication.
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 3);
    assert_eq!(
        reached
            .lock()
            .unwrap()
            .iter()
            .filter(|point| **point == ImportUploadFault::AfterPublication)
            .count(),
        1
    );
    // A local client reads the same Import; the App cannot (not admitted,
    // Swift's App transport refusal).
    let inspect = frame("artifact.import.inspect", json!({"importId":id}));
    assert_eq!(
        result(&control.handle_frame(&inspect), "artifact.import.inspect")["state"],
        "committed"
    );
    assert_eq!(
        code(&ingress.handle(&inspect, root.peer())),
        "methodNotAllowlisted"
    );
    // A native library upload left in progress stays the App's across a restart.
    let native = result(
        &call(
            "artifact.import.begin",
            begin("app-native", "native-library"),
        ),
        "artifact.import.begin",
    );
    assert_eq!(native["state"], "inProgress");
    assert_eq!(record(&root, "app-native")["appOwned"], true);
    drop(ingress);
    drop(control);
    let (control, _) = compose(&root, None);
    let reopened = AppIngress::new(control, root.peer().euid);
    let aborted = result(
        &reopened.handle(
            &frame(
                "artifact.import.abort",
                json!({"importRequestId":"app-native","generation":"1"}),
            ),
            root.peer(),
        ),
        "artifact.import.abort",
    );
    assert_eq!(
        (&aborted["state"], &aborted["importId"]),
        (&json!("aborted"), &native["importId"])
    );
    assert_eq!(reopened.dispatches.load(Ordering::Relaxed), 1);
}

/// One of the synthetic DAYU200 bundles of the Swift archive oracle.
fn bundle(name: &str) -> Vec<u8> {
    fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/flash-archive/archives")
            .join(name),
    )
    .unwrap()
}

/// check-contracts' published view: this build with the contract inputs of
/// the merge base, whose Import schemas predate the flash bundle's views.
fn published_view() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development" && inputs.get("commit").is_some()
}

/// A flash bundle's Import view: its result, which the current contract must
/// publish, or none in the published view, where the control layer refuses
/// it as not conforming to the older schema.
fn flash_view(bytes: &[u8], method: &str) -> Option<Value> {
    match decode_response(bytes.trim_ascii_end(), "request-1", method)
        .unwrap()
        .outcome
    {
        Ok(result) => Some(result),
        Err(error) if published_view() && error.code == "internalError" => None,
        Err(error) => panic!("{method}: {error:?}"),
    }
}

#[test]
fn the_apps_flash_bundle_upload_is_validated_as_swifts_policy_validates_it() {
    let root = uploads();
    let (control, _) = compose(&root, None);
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    // What `FlashApplicationFacade` uploads before it plans a Flash: the
    // archive, bound to the board's Target, under the one DAYU200 profile.
    let begin = |request: &str, bytes: &[u8]| {
        let began = result(
            &call(
                "artifact.import.begin",
                json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,
                    "kind":"flash-bundle","targetId":TARGET,"bindingRevision":"1",
                    "deviceProfile":"dayu200","name":"images.tar.gz",
                    "byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes)}),
            ),
            "artifact.import.begin",
        );
        assert_eq!(record(&root, request)["appOwned"], true);
        began["importId"].as_str().unwrap().to_owned()
    };
    let upload = |request: &str, bytes: &[u8]| {
        let id = begin(request, bytes);
        result(
            &call(
                "artifact.import.append",
                json!({"importId":id,"generation":"1","offset":"0",
                    "byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes),
                    "base64":encode_import_chunk(bytes).unwrap()}),
            ),
            "artifact.import.append",
        );
        (id.clone(), call("artifact.import.commit", selector(&id)))
    };
    let local = |method, params| control.handle_frame(&frame(method, params));
    let complete = bundle("complete.tar.gz");
    let (id, committed) = upload("app-flash", &complete);
    let committed = result(&committed, "artifact.import.commit");
    assert_eq!(committed["state"], "committed");
    let receipt = &committed["receipt"];
    let facts = json!({"kind":"flash-bundle","deviceProfile":"dayu200"});
    assert_eq!(receipt["validation"], facts);
    assert_eq!(
        fs::read(
            root.0
                .join("artifacts")
                .join(&id)
                .join(receipt["artifactId"].as_str().unwrap())
        )
        .unwrap(),
        complete
    );
    // Every view of it the local client reads carries the profile and its
    // facts, as Swift's daemon answers them.
    let params = json!({"importId": id});
    if let Some(inspected) = flash_view(
        &local("artifact.import.inspect", params.clone()),
        "artifact.import.inspect",
    ) {
        assert_eq!(inspected["metadata"]["deviceProfile"], "dayu200");
        assert_eq!(inspected["receipt"]["validation"], facts);
    }
    if let Some(inspection) = flash_view(
        &local("artifact.import.inspection", params),
        "artifact.import.inspection",
    ) {
        assert_eq!(inspection["import"]["receipt"]["validation"], facts);
    }
    if let Some(listed) = flash_view(
        &local("artifact.import.list", json!({})),
        "artifact.import.list",
    ) {
        assert_eq!(listed["items"][0]["metadata"]["deviceProfile"], "dayu200");
    }
    // A bundle that does not fit the board is refused by the owner, as Swift
    // refuses it, and stays in progress with nothing published; the App may
    // abort its own.
    let (unfit, refused) = upload("app-flash-unfit", &bundle("nonconforming.tar.gz"));
    let error = refusal(&refused, "artifact.import.commit");
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "invalidInput",
            "Import content failed its registered format validator"
        )
    );
    assert_eq!(record(&root, "app-flash-unfit")["state"], "inProgress");
    assert!(!root.0.join("artifacts").join(&unfit).exists());
    if let Some(aborted) = flash_view(
        &call(
            "artifact.import.abort",
            json!({"importRequestId":"app-flash-unfit","generation":"1"}),
        ),
        "artifact.import.abort",
    ) {
        assert_eq!(aborted["state"], "aborted");
        assert_eq!(aborted["metadata"]["deviceProfile"], "dayu200");
    }
}

#[test]
fn the_app_operates_no_import_it_did_not_begin_and_writes_nothing_trying() {
    let root = uploads();
    let (control, reached) = compose(&root, None);
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    // The CLI's path: the same Control over the local control socket.
    let local = |method, params| control.handle_frame(&frame(method, params));
    let began = result(
        &local("artifact.import.begin", begin("cli-upload", "hap")),
        "artifact.import.begin",
    );
    let id = began["importId"].as_str().unwrap().to_owned();
    assert_eq!(record(&root, "cli-upload")["appOwned"], false);
    result(
        &local("artifact.import.append", append(&id)),
        "artifact.import.append",
    );
    let before = tree(&root.0);
    let steps = reached.lock().unwrap().len();
    for (method, params) in [
        // Replaying the CLI's request identity adopts nothing.
        ("artifact.import.begin", begin("cli-upload", "hap")),
        ("artifact.import.append", append(&id)),
        (
            "artifact.import.abort",
            json!({"importRequestId":"cli-upload","generation":"1"}),
        ),
        ("artifact.import.commit", selector(&id)),
    ] {
        let error = refusal(&ingress.handle(&frame(method, params), root.peer()), method);
        // Swift's Import owner's words: begin finds the CLI's Import, the
        // others an Import outside the App's uploads.
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (
                "admissionDenied",
                if method == "artifact.import.begin" {
                    "Import was not created by the App transport"
                } else {
                    "Import is outside this App upload scope"
                }
            ),
            "{method}"
        );
        assert_eq!(
            error.details,
            json!({"phase":"importOwner","newDispatchCount":0})
                .as_object()
                .cloned(),
            "{method}"
        );
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 4);
    // The owner refused on its record, before any write step.
    assert_eq!(reached.lock().unwrap().len(), steps);
    assert_eq!(tree(&root.0), before);
    // The CLI's upload is intact and still its own to finish.
    assert_eq!(
        result(
            &local("artifact.import.commit", selector(&id)),
            "artifact.import.commit"
        )["state"],
        "committed"
    );
}

#[test]
fn a_lost_commit_answer_reaches_the_owner_once_and_is_never_rewritten() {
    let root = uploads();
    let (control, reached) = compose(&root, Some(ImportUploadFault::AfterReceiptCheckpoint));
    let ingress = AppIngress::new(control, root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    let began = result(
        &call("artifact.import.begin", begin("app-lost-answer", "hap")),
        "artifact.import.begin",
    );
    let id = began["importId"].as_str().unwrap().to_owned();
    result(
        &call("artifact.import.append", append(&id)),
        "artifact.import.append",
    );
    let error = refusal(
        &call("artifact.import.commit", selector(&id)),
        "artifact.import.commit",
    );
    // The receipt is durable but its answer was lost inside the owner. The
    // App gets the owner's own uncertainty: not success, not pre-admission.
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "recordUnreadable",
            "Import state or immutable content is unreadable"
        )
    );
    assert_eq!(error.details.unwrap()["phase"], "importOwner");
    let durable = record(&root, "app-lost-answer");
    assert_eq!(durable["state"], "committed");
    assert!(durable["receipt"].is_object());
    // One commit, one publication, one receipt: nothing was retried.
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 3);
    let reached = reached.lock().unwrap();
    for point in [
        ImportUploadFault::AfterCommitIntent,
        ImportUploadFault::AfterPublication,
        ImportUploadFault::AfterReceiptCheckpoint,
    ] {
        assert_eq!(
            reached.iter().filter(|seen| **seen == point).count(),
            1,
            "{point:?}"
        );
    }
    let published = fs::read_dir(root.0.join("artifacts").join(&id))
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("ART-")
        })
        .count();
    assert_eq!(published, 1);
}

/// Swift's frame of one of `artifact.import.commit`'s refusals, as the
/// method's recorded corpus holds it: `DurableImportContractTests
/// .testCommitRefusalsCarryTheImportOwnersCodeMessageAndEvidence` records
/// Swift's daemon answering each with the Import owner's code, message and
/// zero-dispatch evidence.
/// The App oracle's HAP: the ZIP magic, then 4,092 bytes of `a`.
fn oracle_hap() -> Vec<u8> {
    let mut bytes = b"PK\x03\x04".to_vec();
    bytes.resize(4096, b'a');
    bytes
}
fn oracle_metadata(request: &str, bytes: &[u8]) -> Value {
    json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,"kind":"hap",
        "targetId":TARGET,"bindingRevision":"1","deviceProfile":null,"name":"fixture.hap",
        "byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes)})
}
fn oracle_chunk(id: &str, bytes: &[u8]) -> Value {
    json!({"importId":id,"generation":"1","offset":"0","byteCount":bytes.len().to_string(),
        "sha256":sha256_hex(bytes),"base64":encode_import_chunk(bytes).unwrap()})
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

/// What the App receives from Swift for the Import requests its transport
/// refuses, or that the Runtime refuses without its Import owners
/// (`rust/tests/fixtures/import-app-refusal-oracle`, "app"): the frame, byte
/// for byte (TASK-XPA-013, X3, X4). A refusal at the door reaches no owner
/// and writes nothing.
#[test]
fn app_transport_refusals_are_the_frames_swift_s_app_receives() {
    let root = uploads();
    let (control, reached) = compose(&root, None);
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    let unowned = AppIngress::new(
        Arc::new(Control::new(crate::host::Host::from_environment()).unwrap()),
        root.peer().euid,
    );
    let local = |method, params| control.handle_frame(&frame(method, params));
    let bytes = oracle_hap();
    let live = result(
        &local(
            "artifact.import.begin",
            oracle_metadata("oracle-live", &bytes),
        ),
        "artifact.import.begin",
    )["importId"]
        .as_str()
        .unwrap()
        .to_owned();
    result(
        &local(
            "artifact.import.append",
            oracle_chunk(&live, &bytes[..2048]),
        ),
        "artifact.import.append",
    );
    let staged = result(
        &local(
            "artifact.import.begin",
            oracle_metadata("oracle-committed", &bytes),
        ),
        "artifact.import.begin",
    )["importId"]
        .as_str()
        .unwrap()
        .to_owned();
    result(
        &local("artifact.import.append", oracle_chunk(&staged, &bytes)),
        "artifact.import.append",
    );
    let committed = result(
        &local("artifact.import.commit", selector(&staged)),
        "artifact.import.commit",
    );
    assert_eq!(committed["state"], "committed");
    let names = [
        ("$liveImportId", live.as_str()),
        ("$committedImportId", staged.as_str()),
        ("$targetId", TARGET),
    ];
    let oracle: Value = serde_json::from_str(include_str!(
        "../../../../tests/fixtures/import-app-refusal-oracle/cases.json"
    ))
    .unwrap();
    let cases = oracle["app"].as_array().unwrap();
    assert_eq!(cases.len(), 11);
    for case in cases {
        let name = case["case"].as_str().unwrap();
        let method = case["method"].as_str().unwrap();
        let params = substituted(&case["params"], &names);
        let request = serde_json::to_vec(&Request::new(
            "import-app-oracle",
            method,
            params.as_object().cloned(),
        ))
        .unwrap();
        let before = (
            tree(&root.0),
            ingress.dispatches.load(Ordering::Relaxed),
            reached.lock().unwrap().len(),
        );
        let reply = if case["owners"] == true {
            ingress.handle(&request, root.peer())
        } else {
            unowned.handle(&request, root.peer())
        };
        if name == "app.append.missingImport" {
            // X5, a declared difference (#2132): the Rust owner, not a
            // gateway read, judges App scope, and it has no such Import.
            assert_eq!(code(&reply), "resourceNotFound", "{name}");
            continue;
        }
        assert_eq!(
            reply.trim_ascii_end(),
            canonical_json(&case["received"]).unwrap().as_slice(),
            "{name}: {}",
            String::from_utf8_lossy(&reply)
        );
        if case["received"]["error"]["code"] == "methodNotAllowlisted" {
            assert_eq!(
                (
                    tree(&root.0),
                    ingress.dispatches.load(Ordering::Relaxed),
                    reached.lock().unwrap().len(),
                ),
                before,
                "{name} reached the Runtime"
            );
        }
    }
}

/// This ingress answers every request outside its allowlist with Swift's
/// App transport refusal, and with nothing else: the code and its words, no
/// details, whatever the method, an Import method or not (TASK-XPA-013, X3).
#[test]
fn a_request_outside_the_app_allowlist_gets_swift_s_transport_refusal_and_nothing_else() {
    let root = uploads();
    let (control, reached) = compose(&root, None);
    let ingress = AppIngress::new(control, root.peer().euid);
    for method in [
        "artifact.import.list",
        "artifact.import.inspect",
        "artifact.import.inspection",
        "artifact.import.release",
        // Swift's App transport admits these three; this ingress does not.
        "artifact.inspect",
        "job.status",
        "session.list",
        // Neither admits these.
        "target.adopt",
        "workspace.project.list",
        "runtime.tool.list",
    ] {
        let reply = ingress.handle(&frame(method, json!({})), root.peer());
        let value: Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(
            value.as_object().unwrap().keys().collect::<Vec<_>>(),
            ["error", "id", "ok"],
            "{method}"
        );
        assert_eq!(
            value["error"]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            ["code", "message"],
            "{method}"
        );
        assert_eq!(
            value,
            json!({"id":"request-1","ok":false,"error":{"code":"methodNotAllowlisted",
                "message":"Runtime transport refused this request"}}),
            "{method}"
        );
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert!(reached.lock().unwrap().is_empty());
}

/// Swift's recorded refusal of `method` with this code and message.
fn swift_refusal(method: &str, code: &str, message: &str) -> WireError {
    let corpus = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    )))
    .unwrap();
    corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|row| {
            row["ok"] == false && row["error"]["code"] == code && row["error"]["message"] == message
        })
        .map(|row| serde_json::from_value(row["error"].clone()).unwrap())
        .unwrap_or_else(|| panic!("no Swift frame of {method} answers {code}: {message}"))
}

/// Swift's `RuntimeImportControlHandler` without its Artifact or Target owner
/// refuses every Import method in the words the corpus recorded; so does a
/// Host composed without the Import owners (TASK-XPA-013).
#[test]
fn a_host_without_the_import_owners_refuses_as_swift_s_handler_does() {
    let control = Control::new(crate::host::Host::from_environment()).unwrap();
    for method in [
        "artifact.import.begin",
        "artifact.import.append",
        "artifact.import.abort",
        "artifact.import.commit",
        "artifact.import.inspect",
        "artifact.import.inspection",
        "artifact.import.release",
    ] {
        let params = json!({"importId":"imp-00000000-0000-4000-8000-000000000001"});
        let error = refusal(&control.handle_frame(&frame(method, params)), method);
        let swift = swift_refusal(
            method,
            "operationUnavailable",
            "Import owner services are unavailable",
        );
        assert_eq!(
            (error.code, error.message, error.details),
            (swift.code, swift.message, swift.details),
            "{method}"
        );
    }
}

fn swift_commit_refusal(code: &str, message: &str) -> Option<WireError> {
    let corpus = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.import.commit.jsonl",
    ))
    .unwrap();
    corpus
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|row| {
            row["ok"] == false && row["error"]["code"] == code && row["error"]["message"] == message
        })
        .map(|row| serde_json::from_value(row["error"].clone()).unwrap())
}

/// Each commit refusal the production Host's Import owner answers reaches the
/// local client and the App as Swift's daemon answers it, wherever this
/// build's commit schema publishes its code. check-contracts' published view
/// compiles the merge base's schema, which predates the owner's four codes;
/// there the control layer still rewrites them as `internalError`. (A full
/// Artifact store's refusal is the owner's own test: this Host's quota is
/// eight gigabytes.)
#[test]
fn commit_refusals_reach_the_local_client_and_the_app_as_swifts_daemon_answers_them() {
    let root = uploads();
    let (control, _) = compose(&root, None);
    let ingress = AppIngress::new(Arc::clone(&control), root.peer().euid);
    let local = |method, params| control.handle_frame(&frame(method, params));
    let app = |method, params| ingress.handle(&frame(method, params), root.peer());
    let answered = |reply: Vec<u8>, code: &str, message: &str| {
        let error = refusal(&reply, "artifact.import.commit");
        if validate_method_value("artifact.import.commit", "errorCode", &json!(code)).is_ok() {
            let swift = swift_commit_refusal(code, message)
                .unwrap_or_else(|| panic!("no Swift frame answers {code}: {message}"));
            assert_eq!(error, swift);
        } else {
            assert!(
                published_view(),
                "only the merge base's schema predates {code}"
            );
            assert_eq!(
                (error.code.as_str(), error.message.as_str()),
                (
                    "internalError",
                    "the result does not conform to the current contract"
                )
            );
        }
    };
    let begun = |reply: Vec<u8>| {
        result(&reply, "artifact.import.begin")["importId"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    // The one adopted Target of the fixture, as its owner will next read it.
    let rebind = |change: &dyn Fn(&mut Value)| {
        let path = root.0.join("targets/targets.json");
        let mut document: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        change(&mut document["targets"][0]);
        fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
    };

    // An Import this Runtime never began.
    answered(
        local(
            "artifact.import.commit",
            selector("imp-00000000-0000-0000-0000-000000000001"),
        ),
        "resourceNotFound",
        "Import does not exist",
    );
    // The App's upload, whose bytes have not all arrived.
    let incomplete = begun(app("artifact.import.begin", begin("app-incomplete", "hap")));
    answered(
        app("artifact.import.commit", selector(&incomplete)),
        "resourceConflict",
        "Import is incomplete or no longer uploadable",
    );
    // The App's complete upload, whose bytes are not the ones it named.
    let mut mismatched = begin("app-digest", "hap");
    mismatched["sha256"] = json!(sha256_hex(&[b'b'; HAP.len()]));
    let digest = begun(app("artifact.import.begin", mismatched));
    result(
        &app("artifact.import.append", append(&digest)),
        "artifact.import.append",
    );
    answered(
        app("artifact.import.commit", selector(&digest)),
        "artifactIntegrityFailed",
        "Import source digest does not match its metadata",
    );
    // A complete upload whose Target the owner now proves through another
    // connect key: the binding it began under names another identity.
    let rebound = begun(local("artifact.import.begin", begin("cli-rebound", "hap")));
    result(
        &local("artifact.import.append", append(&rebound)),
        "artifact.import.append",
    );
    rebind(&|target| target["connectKey"] = json!("another-hdc-address"));
    answered(
        local("artifact.import.commit", selector(&rebound)),
        "resourceConflict",
        "target binding changed during Import",
    );
    // A complete upload whose Target binding has since advanced.
    let advanced = begun(local("artifact.import.begin", begin("cli-advanced", "hap")));
    result(
        &local("artifact.import.append", append(&advanced)),
        "artifact.import.append",
    );
    rebind(&|target| target["bindingRevision"] = json!(2));
    answered(
        local("artifact.import.commit", selector(&advanced)),
        "resourceConflict",
        "the exact target binding is no longer current",
    );
    // Each stays in progress, and nothing was published for it.
    for request in [
        "app-incomplete",
        "app-digest",
        "cli-rebound",
        "cli-advanced",
    ] {
        let durable = record(&root, request);
        assert_eq!(durable["state"], "inProgress", "{request}");
        let id = durable["importID"].as_str().unwrap();
        assert!(!root.0.join("artifacts").join(id).exists(), "{request}");
    }
}

#[test]
fn malformed_uploads_other_kinds_and_foreign_peers_never_enter_the_owner() {
    let root = uploads();
    let (control, reached) = compose(&root, None);
    let ingress = AppIngress::new(control, root.peer().euid);
    let before = tree(&root.0);
    let valid = [
        ("artifact.import.begin", begin("app-closed", "hap")),
        (
            "artifact.import.append",
            append("imp-00000000-0000-4000-8000-000000000000"),
        ),
        (
            "artifact.import.abort",
            json!({"importRequestId":"app-closed","generation":"1"}),
        ),
        (
            "artifact.import.commit",
            selector("imp-00000000-0000-4000-8000-000000000000"),
        ),
    ];
    let mut malformed = Vec::new();
    for (method, params) in &valid {
        for key in params.as_object().unwrap().keys() {
            let mut missing = params.clone();
            missing.as_object_mut().unwrap().remove(key);
            malformed.push((*method, missing));
            let mut typed = params.clone();
            typed[key] = json!(7);
            malformed.push((*method, typed));
        }
        // The recorded schema admits owner/artifactId; the App never sends them.
        for (key, value) in [
            ("owner", json!({"kind":"import","id":"imp-x"})),
            ("artifactId", json!("ART-1")),
            ("appOwned", json!(true)),
            ("peerEUID", json!(root.peer().euid)),
        ] {
            let mut extra = params.clone();
            extra[key] = value;
            malformed.push((*method, extra));
        }
    }
    for (method, key) in [
        ("artifact.import.begin", "bindingRevision"),
        ("artifact.import.begin", "byteCount"),
        ("artifact.import.append", "generation"),
        ("artifact.import.append", "offset"),
        ("artifact.import.append", "byteCount"),
        ("artifact.import.abort", "generation"),
        ("artifact.import.commit", "generation"),
    ] {
        let params = &valid.iter().find(|(name, _)| *name == method).unwrap().1;
        let zero = if key == "offset" { vec![] } else { vec!["0"] };
        for bad in ["01", "+1", "-1", "1.0", " 1", "9223372036854775808"]
            .into_iter()
            .chain(zero)
        {
            let mut noncanonical = params.clone();
            noncanonical[key] = json!(bad);
            malformed.push((method, noncanonical));
        }
    }
    let mut profile = begin("app-closed", "hap");
    profile["deviceProfile"] = json!(true);
    malformed.push(("artifact.import.begin", profile));
    for (method, params) in malformed {
        let reply = ingress.handle(&frame(method, params.clone()), root.peer());
        // Swift's App transport refuses a begin whose metadata is not a
        // complete, valid Import intent at its door; the other uploads'
        // closed shapes are this ingress's own.
        let expected = if method == "artifact.import.begin" {
            "methodNotAllowlisted"
        } else {
            "invalidParams"
        };
        assert_eq!(code(&reply), expected, "{method} {params}");
    }
    // Swift's App transport refuses other kinds at its door, in its words.
    for kind in ["workspace-patch", "fixture"] {
        let method = "artifact.import.begin";
        let reply = ingress.handle(&frame(method, begin("app-kind", kind)), root.peer());
        assert_eq!(
            serde_json::from_slice::<Value>(&reply).unwrap(),
            json!({"id":"request-1","ok":false,"error":{"code":"methodNotAllowlisted",
                "message":"Runtime transport refused this request"}}),
            "{kind}"
        );
    }
    for peer in [
        PeerOrigin {
            euid: root.peer().euid.wrapping_add(1),
            ..root.peer()
        },
        PeerOrigin {
            pid: 1,
            ..root.peer()
        },
        PeerOrigin {
            foreground_console: true,
            ..root.peer()
        },
    ] {
        for (method, params) in &valid {
            assert_eq!(
                code(&ingress.handle(&frame(method, params.clone()), peer)),
                "rejected"
            );
        }
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert!(reached.lock().unwrap().is_empty());
    assert_eq!(tree(&root.0), before);
}

#[test]
fn every_admitted_request_reaches_its_one_owner_exactly_once() {
    type Calls = Arc<Mutex<Vec<(String, Value)>>>;
    struct Owners(Calls);
    impl Owners {
        fn called(&self, method: &str, params: Value) {
            self.0.lock().unwrap().push((method.into(), params));
        }
    }
    fn uncertain(code: &str, phase: &str) -> WireError {
        let mut details = serde_json::Map::from_iter([
            ("phase".into(), json!(phase)),
            ("newDispatchCount".into(), json!(0)),
        ]);
        if phase == "traceCacheOwner" {
            details.insert("purgeScope".into(), json!("inactiveDerivedDatabases"));
        }
        WireError {
            code: code.into(),
            message: "the owner's own uncertain answer".into(),
            details: Some(details),
        }
    }
    impl HostServices for Owners {
        fn observed_at(&self) -> String {
            "2026-09-24T00:00:00Z".into()
        }
        fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
            arkdeck_control::HdcStatus::unavailable(deep, "fixture")
        }
        fn observations(&self) -> Result<arkdeck_contract::DeviceObservationsResult, WireError> {
            panic!("an App upload or read observed devices")
        }
        fn import_resource(
            &self,
            method: &str,
            _: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            panic!("the App frame {method} reached the local Import owner")
        }
        fn app_import_resource(
            &self,
            method: &str,
            params: &serde_json::Map<String, Value>,
        ) -> Result<Value, WireError> {
            self.called(method, Value::Object(params.clone()));
            Err(uncertain("recordUnreadable", "importOwner"))
        }
        fn artifact_quota(&self) -> Result<Value, WireError> {
            self.called("artifact.quota", json!({}));
            Ok(json!({"totalBytes":10,"usedBytes":4,"remainingBytes":6}))
        }
        fn trace_cache_status(&self) -> Result<Value, WireError> {
            self.called("trace.cache.status", json!({}));
            Ok(
                json!({"schemaVersion":"arkdeck.trace-cache-status/1","entryCount":0,"totalByteCount":"0",
                "activeEntryCount":0,"inactiveEntryCount":0,"purgeScope":"inactiveDerivedDatabases"}),
            )
        }
        fn trace_cache_purge(&self) -> Result<Value, WireError> {
            self.called("trace.cache.purge", json!({}));
            Err(uncertain("outcomeUnknown", "traceCacheOwner"))
        }
        fn debug_read(&self, target: &str, template: Option<&str>) -> Result<Value, WireError> {
            self.called(
                "debug.probe",
                json!({"targetId":target,"templateId":template}),
            );
            Ok(
                json!({"schemaVersion":"arkdeck.debug-probe/1","targetId":target,"bindingRevision":1,
                "packages":[],"portRules":[],"warnings":[]}),
            )
        }
    }
    let root = Root::new();
    let calls = Calls::default();
    let ingress = AppIngress::new(
        Arc::new(Control::new(Owners(calls.clone())).unwrap()),
        root.peer().euid,
    );
    let id = "imp-00000000-0000-4000-8000-000000000000";
    let requests = [
        ("artifact.quota", json!({})),
        ("trace.cache.status", json!({})),
        ("trace.cache.purge", json!({})),
        ("debug.probe", json!({"targetId":TARGET})),
        ("artifact.import.begin", begin("app-once", "native-library")),
        ("artifact.import.append", append(id)),
        (
            "artifact.import.abort",
            json!({"importRequestId":"app-once","generation":"1"}),
        ),
        ("artifact.import.commit", selector(id)),
    ];
    for (index, (method, params)) in requests.iter().enumerate() {
        let reply = ingress.handle(&frame(method, params.clone()), root.peer());
        let decoded = decode_response(reply.trim_ascii_end(), "request-1", method).unwrap();
        // An uncertain owner answer crosses unchanged: never success, never
        // a pre-admission claim, never a second call.
        if let Err(error) = decoded.outcome {
            assert_eq!(
                error.message, "the owner's own uncertain answer",
                "{method}"
            );
            assert_ne!(error.details.unwrap()["phase"], "preAdmission");
        }
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), index + 1, "{method}");
        let expected = if *method == "debug.probe" {
            json!({"targetId":TARGET,"templateId":null})
        } else {
            params.clone()
        };
        assert_eq!(calls[index], ((*method).to_owned(), expected));
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), requests.len());
}
