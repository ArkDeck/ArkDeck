//! Synthetic local snapshots exercise real Rust owners through the App boundary.
//! No signed peer, hardware result or installed Runtime is represented here.
use super::*;
use arkdeck_hoststore::{ArtifactReadStore, JobRecord, JobStore};
use std::os::unix::fs::PermissionsExt;

fn directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}
fn write(path: &Path, bytes: &[u8], mode: u32) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}
fn compose(root: &Root) -> Arc<Control<crate::host::Host>> {
    Arc::new(
        Control::new(
            crate::host::Host::from_environment()
                .with_jobs(JobStore::open_owner(&root.0).unwrap())
                .with_artifacts(ArtifactReadStore::open(&root.0.join("artifacts")).unwrap()),
        )
        .unwrap(),
    )
}
fn seed(root: &Root) -> (String, String) {
    let jobs = JobStore::open_owner(&root.0).unwrap();
    for id in ["JOB-1", "JOB-2"] {
        let value = json!({"jobID":id,"request":{"documentType":"runtime-operation-request","schemaVersion":"1.0.0","requestId":format!("req-{id}"),"idempotencyKey":format!("idem-{id}"),"target":{"targetId":"TGT-fixture","expectedBindingRevision":1},"operation":{"id":"observe.device","version":1},"inputs":{},"requestedOutputs":["derivedArtifacts"]},"operationReference":"observe.device@1","catalogDigest":arkdeck_contract::CATALOG_DIGEST,"providerID":"hdc","createdAtUTC":"2026-08-31T12:00:00Z","actualEffect":"readOnly","materializedPlanDigest":"a".repeat(64),"materializedBindingRevision":1,"state":"succeeded","outcomeUnknown":false,"timeline":["created","completed"],"actualStepKinds":[],"skipReasons":{}});
        let record = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        jobs.admit(&record, &arkdeck_contract::sha256_hex(id.as_bytes()))
            .unwrap();
    }
    let artifacts = root.0.join("artifacts");
    directory(&artifacts);
    let owner = artifacts.join("JOB-1");
    directory(&owner);
    let mut rows = Vec::new();
    let mut ids = Vec::new();
    for (name, payload, privacy) in [
        ("public", b"public bytes".as_slice(), "standard"),
        ("private", b"private bytes".as_slice(), "sensitive"),
    ] {
        let digest = arkdeck_contract::sha256_hex(payload);
        let id = format!(
            "ART-{}",
            &arkdeck_contract::sha256_hex(format!("JOB-1\0{name}\0{digest}").as_bytes())[..32]
        );
        write(&owner.join(&id), payload, 0o400);
        rows.push(json!({"artifactID":id,"jobID":"JOB-1","sessionID":"session-JOB-1","stepID":"read","name":name,"mediaType":"application/octet-stream","sha256":digest,"createdAtUTC":"2026-08-31T12:00:00.000Z","providerID":"fixture","sourceOperation":"observe.device","privacy":privacy,"byteCount":payload.len(),"bindingSnapshot":{"targetID":"TGT-fixture","bindingRevision":1},"retention":{"retentionClass":"default","pinned":false},"status":{"published":{}},"redactionApplied":false}));
        ids.push(id);
    }
    write(
        &owner.join("index.json"),
        &serde_json::to_vec(&json!({"schemaVersion":"1.0.0","artifacts":rows})).unwrap(),
        0o600,
    );
    (ids.remove(0), ids.remove(0))
}

#[test]
fn history_reads_use_the_shared_owners_with_paging_and_restart() {
    let root = Root::new();
    let (public, _) = seed(&root);
    let control = compose(&root);
    let ingress = HistoryIngress::new(control.clone(), root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    let list_params = json!({"pageSize":1,"order":"createdAtDescJobIdAsc","includeTimeline":false,"includeCurrent":true});
    let first = result(&call("job.list", list_params.clone()), "job.list");
    assert_eq!(first["items"].as_array().unwrap().len(), 1);
    assert_eq!(first["hasMore"], true);
    let cursor = first["nextCursor"].clone();
    let mut next = list_params;
    next["cursor"] = cursor;
    let last = result(&call("job.list", next.clone()), "job.list");
    assert_eq!(last["items"].as_array().unwrap().len(), 1);
    assert_ne!(first["items"][0]["jobId"], last["items"][0]["jobId"]);
    for (method, params) in [
        ("job.show", json!({"jobId":"JOB-1"})),
        ("job.evidence", json!({"jobId":"JOB-1"})),
        (
            "artifact.read",
            json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":public,"offset":0,"maxBytes":6}),
        ),
    ] {
        let request = frame(method, params);
        let via_app = ingress.handle(&request, root.peer());
        assert_eq!(via_app, control.handle_frame(&request), "{method}");
        let read = result(&via_app, method);
        if method == "artifact.read" {
            assert_eq!(read["base64"], "cHVibGlj");
            assert_eq!(read["nextOffset"], 6);
            assert_eq!(read["eof"], false);
        }
    }
    for (method, identity) in [
        ("job.timeline", json!({"jobId":"JOB-1"})),
        (
            "artifact.list",
            json!({"owner":{"kind":"job","id":"JOB-1"}}),
        ),
    ] {
        let mut params = identity;
        params["pageSize"] = json!(1);
        let first = result(&call(method, params.clone()), method);
        assert_eq!(first["items"].as_array().unwrap().len(), 1);
        params["cursor"] = first["nextCursor"].clone();
        let second = result(&call(method, params), method);
        assert_eq!(second["items"].as_array().unwrap().len(), 1);
        assert_ne!(first["items"], second["items"]);
    }
    assert_eq!(
        code(&call("job.show", json!({"jobId":"JOB-missing"}))),
        "notFound"
    );
    assert_eq!(
        code(&call("job.list", json!({"cursor":"invalid"}))),
        "invalidCursor"
    );
    drop(ingress);
    drop(control);
    let reopened = HistoryIngress::new(compose(&root), root.peer().euid);
    assert_eq!(
        result(
            &reopened.handle(&frame("job.list", next), root.peer()),
            "job.list"
        ),
        last
    );
}

#[test]
fn artifact_sensitive_range_and_integrity_failures_are_preserved() {
    let root = Root::new();
    let (public, sensitive) = seed(&root);
    let control = compose(&root);
    let ingress = HistoryIngress::new(control.clone(), root.peer().euid);
    let params = |id: &str| json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id,"offset":0,"maxBytes":6});
    let assert_failure = |params: Value, expected: &str| {
        let request = frame("artifact.read", params);
        let reply = ingress.handle(&request, root.peer());
        assert_eq!(reply, control.handle_frame(&request));
        let decoded =
            decode_response(reply.trim_ascii_end(), "request-1", "artifact.read").unwrap();
        assert_eq!(decoded.outcome.unwrap_err().code, expected);
        assert!(!String::from_utf8(reply).unwrap().contains("private bytes"));
    };
    assert_failure(params(&sensitive), "sensitiveAccessDenied");
    let mut permitted = params(&sensitive);
    permitted["allowSensitive"] = json!(true);
    let read = result(
        &ingress.handle(&frame("artifact.read", permitted), root.peer()),
        "artifact.read",
    );
    assert_eq!(read["base64"], "cHJpdmF0");
    let mut range = params(&public);
    range["offset"] = json!(9999);
    assert_failure(range, "invalidInput");
    fs::set_permissions(
        root.0.join("artifacts/JOB-1").join(&public),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    write(
        &root.0.join("artifacts/JOB-1").join(&public),
        b"tampered",
        0o400,
    );
    assert_failure(params(&public), "artifactIntegrityFailed");
}
