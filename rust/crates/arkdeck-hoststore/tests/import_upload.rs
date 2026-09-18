#![cfg(target_os = "macos")]
use arkdeck_contract::{
    ImportIntent, ImportProjection, WireError, encode_import_chunk, sha256_hex,
};
use arkdeck_hoststore::{ImportBinding, ImportUploadFault, ImportUploadStore};
use serde_json::{Value, json};
use std::os::unix::fs::{DirBuilderExt, symlink};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::Arc,
};
const NOW: &str = "2026-09-12T00:00:00Z";
struct Fixture {
    root: PathBuf,
    artifacts: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "rust-import-upload-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let artifacts = root.join("artifacts");
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&artifacts)
            .unwrap();
        Self { root, artifacts }
    }
    fn store(&self) -> ImportUploadStore {
        ImportUploadStore::open(&self.artifacts).unwrap()
    }
    fn imports(&self) -> PathBuf {
        self.artifacts.join(".imports-v1")
    }
    fn record(&self, request: &str) -> PathBuf {
        self.imports()
            .join(format!("records/{}.json", sha256_hex(request.as_bytes())))
    }
    fn stage(&self, id: &str) -> PathBuf {
        self.imports().join(format!("payloads/{id}.stage"))
    }
    fn identity(&self, id: &str) -> PathBuf {
        self.imports().join(format!("identities/{id}.json"))
    }
    fn metadata(&self, request: &str, bytes: &[u8]) -> Value {
        json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,"kind":"hap","targetId":"TGT-fixture","bindingRevision":"7","deviceProfile":null,"name":"fixture.hap","byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes)})
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn binding(intent: &ImportIntent) -> Result<ImportBinding, WireError> {
    Ok(ImportBinding {
        target_id: intent.target_id.clone(),
        binding_revision: (intent.kind != "workspace-patch").then_some(intent.binding_revision),
        stable_identity_sha256: (intent.kind != "workspace-patch").then(|| "a".repeat(64)),
    })
}
fn unavailable(_: &ImportIntent) -> Result<ImportBinding, WireError> {
    Err(WireError {
        code: "operationUnavailable".into(),
        message: "fixture has no Target owner".into(),
        details: None,
    })
}
fn call(store: &ImportUploadStore, verb: &str, params: Value) -> Result<Value, WireError> {
    store.handle_resource(
        &format!("artifact.import.{verb}"),
        params.as_object().unwrap(),
        NOW,
        false,
        binding,
    )
}
fn append(
    store: &ImportUploadStore,
    id: &str,
    offset: u64,
    bytes: &[u8],
) -> Result<Value, WireError> {
    call(
        store,
        "append",
        json!({"importId":id,"generation":"1","offset":offset.to_string(),"byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes),"base64":encode_import_chunk(bytes).unwrap()}),
    )
}
fn read(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}
fn names(path: &Path) -> Vec<String> {
    let mut names = fs::read_dir(path)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect::<Vec<_>>();
    names.sort();
    names
}

#[test]
fn exact_upload_identity_survives_restart_and_append_retry_without_changing_generation() {
    let fixture = Fixture::new();
    let payload = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let metadata = fixture.metadata("upload-restart", payload);
    let store = fixture.store();
    let initial = call(&store, "begin", metadata.clone()).unwrap();
    let id = initial["importId"].as_str().unwrap();
    let first = append(&store, id, 0, &payload[..8]).unwrap();
    assert_eq!(first["generation"], "1");
    assert_eq!(first["nextOffset"], "8");
    let checkpoint = fs::read(fixture.record("upload-restart")).unwrap();
    assert_eq!(append(&store, id, 0, &payload[..8]).unwrap(), first);
    assert_eq!(
        fs::read(fixture.record("upload-restart")).unwrap(),
        checkpoint
    );
    assert_eq!(
        append(&store, id, 1, b"wrong").unwrap_err().code,
        "resourceConflict"
    );
    assert_eq!(
        append(&store, id, 9, b"gap").unwrap_err().code,
        "resourceConflict"
    );
    drop(store);
    let restarted = fixture.store();
    let discovered = restarted
        .handle_resource(
            "artifact.import.begin",
            metadata.as_object().unwrap(),
            NOW,
            false,
            unavailable,
        )
        .unwrap();
    assert_eq!(
        discovered, first,
        "an existing request does not need a new binding resolution"
    );
    let complete = append(&restarted, id, 8, &payload[8..]).unwrap();
    ImportProjection::parse(&complete).unwrap();
    assert_eq!(complete["nextOffset"], payload.len().to_string());
    assert_eq!(fs::read(fixture.stage(id)).unwrap(), payload);
    let record = read(&fixture.record("upload-restart"));
    assert_eq!(record["generation"], 1);
    assert_eq!(record["binding"]["bindingRevision"], 7);
    assert!(record["intent"].get("schemaVersion").is_none());
    assert!(record["intent"].get("deviceProfile").is_none());
    assert!(record.get("receipt").is_none());
    assert_eq!(record["appOwned"], false);
    for verb in ["commit", "release", "inspection"] {
        assert_eq!(
            call(&restarted, verb, json!({"importId":id,"generation":"1"}))
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
    }
    assert_eq!(fs::read(fixture.stage(id)).unwrap(), payload);
}
#[test]
fn begin_requires_runtime_binding_and_conflicting_metadata_never_changes_existing_owner() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let metadata = fixture.metadata("one-owner", b"payload");
    let denied = store
        .handle_resource(
            "artifact.import.begin",
            metadata.as_object().unwrap(),
            NOW,
            false,
            unavailable,
        )
        .unwrap_err();
    assert_eq!(denied.code, "operationUnavailable");
    assert!(names(&fixture.imports().join("records")).is_empty());
    assert!(names(&fixture.imports().join("payloads")).is_empty());
    for (revision, identity) in [
        (None, Some("a".repeat(64))),
        (Some(8), Some("a".repeat(64))),
        (Some(7), None),
    ] {
        let denied = store
            .handle_resource(
                "artifact.import.begin",
                metadata.as_object().unwrap(),
                NOW,
                false,
                |intent| {
                    Ok(ImportBinding {
                        target_id: intent.target_id.clone(),
                        binding_revision: revision,
                        stable_identity_sha256: identity,
                    })
                },
            )
            .unwrap_err();
        assert_eq!(denied.code, "resourceConflict");
        assert!(names(&fixture.imports().join("records")).is_empty());
        assert!(names(&fixture.imports().join("payloads")).is_empty());
    }
    let initial = call(&store, "begin", metadata.clone()).unwrap();
    let before = fs::read(fixture.record("one-owner")).unwrap();
    let mut other = metadata.clone();
    other["sha256"] = json!("b".repeat(64));
    assert_eq!(
        call(&store, "begin", other).unwrap_err().code,
        "idempotencyConflict"
    );
    let app = store
        .handle_resource(
            "artifact.import.begin",
            metadata.as_object().unwrap(),
            NOW,
            true,
            binding,
        )
        .unwrap_err();
    assert_eq!(app.code, "admissionDenied");
    assert_eq!(fs::read(fixture.record("one-owner")).unwrap(), before);
    assert_eq!(initial["nextOffset"], "0");
    let mut injected = metadata;
    injected["appOwned"] = json!(true);
    assert_eq!(
        call(&store, "begin", injected).unwrap_err().code,
        "invalidInput"
    );
}
#[test]
fn workspace_patch_keeps_the_owner_resolved_nullable_binding_snapshot() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let mut metadata = fixture.metadata("patch-binding", b"diff");
    metadata["kind"] = json!("workspace-patch");
    metadata["name"] = json!("fixture.patch");
    let result = store
        .handle_resource(
            "artifact.import.begin",
            metadata.as_object().unwrap(),
            NOW,
            false,
            |intent| {
                assert_eq!(intent.binding_revision, 7);
                Ok(ImportBinding {
                    target_id: intent.target_id.clone(),
                    binding_revision: None,
                    stable_identity_sha256: None,
                })
            },
        )
        .unwrap();
    assert_eq!(result["metadata"]["bindingRevision"], "7");
    assert_eq!(
        read(&fixture.record("patch-binding"))["binding"],
        json!({"targetID":"TGT-fixture"})
    );
}
#[test]
fn partial_and_synced_chunks_recover_only_the_uncommitted_suffix() {
    for point in [
        ImportUploadFault::AfterPartialChunk,
        ImportUploadFault::AfterChunkSync,
        ImportUploadFault::AfterAppendCheckpoint,
    ] {
        let fixture = Fixture::new();
        let payload = vec![0x5au8; 48];
        let store = fixture.store();
        let first = call(&store, "begin", fixture.metadata("crash-window", &payload)).unwrap();
        let id = first["importId"].as_str().unwrap();
        append(&store, id, 0, &payload[..8]).unwrap();
        drop(store);
        let fault = Arc::new(move |at| {
            if at == point {
                Err(io::Error::other("fixture crash window"))
            } else {
                Ok(())
            }
        });
        let store = ImportUploadStore::open_with_fault(&fixture.artifacts, fault).unwrap();
        assert_eq!(
            append(&store, id, 8, &payload[8..24]).unwrap_err().code,
            "recordUnreadable"
        );
        drop(store);
        let expected = if point == ImportUploadFault::AfterAppendCheckpoint {
            24
        } else {
            8
        };
        let record = read(&fixture.record("crash-window"));
        assert_eq!(record["nextOffset"], expected);
        let restarted = fixture.store();
        let current = call(&restarted, "inspect", json!({"importId":id})).unwrap();
        assert_eq!(current["nextOffset"], expected.to_string());
        assert_eq!(fs::read(fixture.stage(id)).unwrap(), payload[..expected]);
        append(&restarted, id, expected as u64, &payload[expected..]).unwrap();
        assert_eq!(fs::read(fixture.stage(id)).unwrap(), payload);
    }
}
#[test]
fn begin_and_abort_crash_windows_remain_discoverable_and_cannot_resurrect_an_upload() {
    let fixture = Fixture::new();
    let metadata = fixture.metadata("begin-abort", b"abcdefgh");
    let store = ImportUploadStore::open_with_fault(
        &fixture.artifacts,
        Arc::new(|p| {
            if p == ImportUploadFault::AfterBeginCheckpoint {
                Err(io::Error::other("fixture"))
            } else {
                Ok(())
            }
        }),
    )
    .unwrap();
    assert!(call(&store, "begin", metadata.clone()).is_err());
    let id = read(&fixture.record("begin-abort"))["importID"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!fixture.identity(&id).exists());
    drop(store);
    let store = fixture.store();
    let current = call(&store, "inspect", json!({"importId":id})).unwrap();
    assert_eq!(current["nextOffset"], "0");
    assert!(fixture.identity(&id).exists());
    append(&store, &id, 0, b"abcdefgh").unwrap();
    drop(store);
    let store = ImportUploadStore::open_with_fault(
        &fixture.artifacts,
        Arc::new(|p| {
            if p == ImportUploadFault::AfterAbortCheckpoint {
                Err(io::Error::other("fixture"))
            } else {
                Ok(())
            }
        }),
    )
    .unwrap();
    assert!(
        call(
            &store,
            "abort",
            json!({"importRequestId":"begin-abort","generation":"1"})
        )
        .is_err()
    );
    assert!(fixture.stage(&id).exists());
    drop(store);
    let store = fixture.store();
    let aborted = call(&store, "inspect", json!({"importRequestId":"begin-abort"})).unwrap();
    assert_eq!(aborted["state"], "aborted");
    assert_eq!(aborted["generation"], "2");
    assert!(!fixture.stage(&id).exists());
    assert_eq!(
        call(
            &store,
            "abort",
            json!({"importRequestId":"begin-abort","generation":"1"})
        )
        .unwrap(),
        aborted
    );
    assert_eq!(call(&store, "begin", metadata).unwrap(), aborted);
    assert_eq!(
        append(&store, &id, 0, b"a").unwrap_err().code,
        "resourceConflict"
    );
    assert!(!fixture.stage(&id).exists());
}
#[test]
fn staging_quota_is_declared_capacity_and_never_evicts_an_existing_owner() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let mut full = fixture.metadata("full-quota", b"x");
    full["kind"] = json!("flash-bundle");
    full["name"] = json!("images.tar.gz");
    full["deviceProfile"] = json!("dayu200");
    full["byteCount"] = json!("8589934592");
    let current = call(&store, "begin", full.clone()).unwrap();
    let id = current["importId"].as_str().unwrap();
    assert_eq!(fs::metadata(fixture.stage(id)).unwrap().len(), 0);
    let before = fs::read(fixture.record("full-quota")).unwrap();
    assert_eq!(
        call(&store, "begin", fixture.metadata("overflow", b"small"))
            .unwrap_err()
            .code,
        "quotaExceeded"
    );
    assert_eq!(fs::read(fixture.record("full-quota")).unwrap(), before);
    assert_eq!(call(&store, "begin", full).unwrap(), current);
    assert_eq!(names(&fixture.imports().join("records")).len(), 1);
}
#[test]
fn one_owner_and_private_directory_bindings_prevent_foreign_writes() {
    let fixture = Fixture::new();
    let store = fixture.store();
    assert!(
        matches!(ImportUploadStore::open(&fixture.artifacts),Err(e) if e.kind()==io::ErrorKind::WouldBlock)
    );
    let started = call(&store, "begin", fixture.metadata("one-process", b"payload")).unwrap();
    let id = started["importId"].as_str().unwrap();
    fs::rename(
        fixture.imports().join("payloads"),
        fixture.imports().join("held-payloads"),
    )
    .unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(fixture.imports().join("payloads"))
        .unwrap();
    assert_eq!(
        append(&store, id, 0, b"payload").unwrap_err().code,
        "recordUnreadable"
    );
    assert!(names(&fixture.imports().join("payloads")).is_empty());
    assert_eq!(
        fs::read(fixture.imports().join(format!("held-payloads/{id}.stage"))).unwrap(),
        b""
    );
}
#[test]
fn linked_or_corrupt_staging_and_foreign_identity_maps_fail_without_touching_raw_bytes() {
    for attack in ["symlink", "hardlink", "prefix", "mapping"] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let begun = call(&store, "begin", fixture.metadata("protected", b"abcdefgh")).unwrap();
        let id = begun["importId"].as_str().unwrap();
        append(&store, id, 0, b"abcd").unwrap();
        let raw = fixture.root.join("raw-artifact");
        fs::write(&raw, b"immutable evidence").unwrap();
        match attack {
            "symlink" => {
                fs::remove_file(fixture.stage(id)).unwrap();
                symlink(&raw, fixture.stage(id)).unwrap();
            }
            "hardlink" => {
                fs::remove_file(fixture.stage(id)).unwrap();
                fs::hard_link(&raw, fixture.stage(id)).unwrap();
            }
            "prefix" => {
                fs::write(fixture.stage(id), b"bad!").unwrap();
            }
            _ => {
                fs::write(
                    fixture.identity(id),
                    br#"{"importRequestId":"not-the-owner"}"#,
                )
                .unwrap();
            }
        }
        assert_eq!(
            call(&store, "inspect", json!({"importId":id}))
                .unwrap_err()
                .code,
            "recordUnreadable",
            "{attack}"
        );
        assert_eq!(fs::read(&raw).unwrap(), b"immutable evidence");
    }
}
#[test]
fn strict_records_refuse_unknown_fields_bad_chunk_state_and_linked_checkpoints() {
    for mutation in [
        "extra",
        "fingerprint",
        "chunks",
        "generation",
        "identity",
        "hardlink",
    ] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let begun = call(&store, "begin", fixture.metadata("strict", b"abcdefgh")).unwrap();
        let id = begun["importId"].as_str().unwrap();
        let path = fixture.record("strict");
        let mut record = read(&path);
        match mutation {
            "extra" => record["extra"] = json!(true),
            "fingerprint" => record["intentFingerprint"] = json!("b".repeat(64)),
            "chunks" => record["nextOffset"] = json!(1),
            "generation" => record["generation"] = json!(2),
            "identity" => record["binding"]["targetID"] = json!("TGT-other"),
            _ => {
                fs::hard_link(&path, fixture.root.join("linked-record")).unwrap();
            }
        }
        if mutation != "hardlink" {
            fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        }
        assert_eq!(
            call(&store, "inspect", json!({"importId":id}))
                .unwrap_err()
                .code,
            "recordUnreadable",
            "{mutation}"
        );
        assert_eq!(fs::metadata(fixture.stage(id)).unwrap().len(), 0);
    }
}

#[test]
fn concurrent_appends_have_one_committed_prefix_and_trusted_app_provenance_stays_scoped() {
    let fixture = Fixture::new();
    let store = Arc::new(fixture.store());
    let metadata = fixture.metadata("concurrent", b"abcdefgh");
    let began = call(&store, "begin", metadata.clone()).unwrap();
    let id = began["importId"].as_str().unwrap().to_owned();
    let mut workers = Vec::new();
    for bytes in [b"abcd", b"wxyz"] {
        let store = Arc::clone(&store);
        let id = id.clone();
        workers.push(std::thread::spawn(move || append(&store, &id, 0, bytes)));
    }
    let results = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results.into_iter().find_map(Result::err).unwrap().code,
        "resourceConflict"
    );
    assert_eq!(
        call(&store, "inspect", json!({"importId":id})).unwrap()["nextOffset"],
        "4"
    );
    let request = json!({"importId":id,"generation":"1","offset":"4","byteCount":"4","sha256":sha256_hex(b"efgh"),"base64":"ZWZnaA=="});
    assert_eq!(
        store
            .handle_resource(
                "artifact.import.append",
                request.as_object().unwrap(),
                NOW,
                true,
                unavailable
            )
            .unwrap_err()
            .code,
        "admissionDenied"
    );
    assert_eq!(
        store
            .handle_resource(
                "artifact.import.abort",
                json!({"importRequestId":"concurrent","generation":"1"})
                    .as_object()
                    .unwrap(),
                NOW,
                true,
                unavailable
            )
            .unwrap_err()
            .code,
        "admissionDenied"
    );
    let app_metadata = fixture.metadata("app-owner", b"abcdefgh");
    let app = store
        .handle_resource(
            "artifact.import.begin",
            app_metadata.as_object().unwrap(),
            NOW,
            true,
            binding,
        )
        .unwrap();
    drop(store);
    let store = fixture.store();
    let mut request = request;
    request["importId"] = app["importId"].clone();
    request["offset"] = json!("0");
    assert_eq!(
        store
            .handle_resource(
                "artifact.import.append",
                request.as_object().unwrap(),
                NOW,
                true,
                unavailable
            )
            .unwrap()["nextOffset"],
        "4"
    );
    assert_eq!(
        store
            .handle_resource(
                "artifact.import.abort",
                json!({"importRequestId":"app-owner","generation":"1"})
                    .as_object()
                    .unwrap(),
                NOW,
                true,
                unavailable
            )
            .unwrap()["state"],
        "aborted"
    );
}

#[test]
fn maximum_chunk_checkpoint_refuses_more_metadata_and_preserves_staged_bytes() {
    let fixture = Fixture::new();
    let bytes = vec![b'a'; 16_385];
    let store = fixture.store();
    let began = call(&store, "begin", fixture.metadata("chunk-quota", &bytes)).unwrap();
    let id = began["importId"].as_str().unwrap();
    drop(store);
    let mut record = read(&fixture.record("chunk-quota"));
    record["chunks"] = json!(
        (0..16_384)
            .map(|offset| json!({"offset":offset,"byteCount":1,"sha256":sha256_hex(b"a")}))
            .collect::<Vec<_>>()
    );
    record["nextOffset"] = json!(16_384);
    fs::write(
        fixture.record("chunk-quota"),
        serde_json::to_vec(&record).unwrap(),
    )
    .unwrap();
    fs::write(fixture.stage(id), &bytes[..16_384]).unwrap();
    let before = fs::read(fixture.record("chunk-quota")).unwrap();
    let store = fixture.store();
    assert_eq!(
        append(&store, id, 16_384, b"a").unwrap_err().code,
        "quotaExceeded"
    );
    assert_eq!(fs::read(fixture.record("chunk-quota")).unwrap(), before);
    assert_eq!(fs::read(fixture.stage(id)).unwrap(), bytes[..16_384]);
}

#[test]
fn native_swift_upload_snapshot_reopens_and_resumes_without_rewriting_prior_records() {
    use std::os::unix::fs::PermissionsExt;
    fn copy(source: &Path, destination: &Path) {
        for entry in fs::read_dir(source).unwrap() {
            let entry = entry.unwrap();
            let dest = destination.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                fs::DirBuilder::new().mode(0o700).create(&dest).unwrap();
                copy(&entry.path(), &dest);
            } else {
                fs::copy(entry.path(), &dest).unwrap();
                fs::set_permissions(&dest, fs::Permissions::from_mode(0o600)).unwrap();
            }
        }
    }
    let fixture = Fixture::new();
    let native =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/import-upload-current");
    copy(&native.join("artifacts"), &fixture.artifacts);
    let samples: Vec<Value> =
        serde_json::from_slice(&fs::read(native.join("swift-results.json")).unwrap()).unwrap();
    let expected = &samples
        .iter()
        .find(|sample| sample["method"] == "artifact.import.inspect")
        .unwrap()["result"];
    let aborted = &samples
        .iter()
        .find(|sample| sample["method"] == "artifact.import.abort")
        .unwrap()["result"];
    let before = fs::read(fixture.record("rust-import-upload")).unwrap();
    let store = fixture.store();
    let actual = call(
        &store,
        "inspect",
        json!({"importRequestId":"rust-import-upload"}),
    )
    .unwrap();
    assert_eq!(&actual, expected);
    assert_eq!(
        call(&store, "inspect", json!({"importId":expected["importId"]})).unwrap(),
        actual
    );
    assert_eq!(
        call(&store, "begin", expected["metadata"].clone()).unwrap(),
        actual
    );
    assert_eq!(
        call(
            &store,
            "inspect",
            json!({"importRequestId":"rust-import-aborted"})
        )
        .unwrap(),
        *aborted
    );
    assert_eq!(
        fs::read(fixture.record("rust-import-upload")).unwrap(),
        before
    );
    let id = expected["importId"].as_str().unwrap();
    let bytes = fs::read(native.join("fixture.hap")).unwrap();
    assert_eq!(fs::read(fixture.stage(id)).unwrap(), &bytes[..2048]);
    let result = append(&store, id, 2048, &bytes[2048..]).unwrap();
    assert_eq!(result["nextOffset"], "4096");
    assert_eq!(result["generation"], "1");
    assert_eq!(result["metadata"], expected["metadata"]);
    assert_eq!(fs::read(fixture.stage(id)).unwrap(), bytes);
    let saved: Value = read(&fixture.record("rust-import-upload"));
    assert_eq!(saved["schemaVersion"], "arkdeck.runtime-import/1");
    assert_eq!(
        saved["intent"],
        read(&native.join(format!(
            "artifacts/.imports-v1/records/{}.json",
            sha256_hex(b"rust-import-upload")
        )))["intent"]
    );
    let records = fs::read(fixture.record("rust-import-upload")).unwrap();
    for verb in ["commit", "release", "inspection"] {
        assert_eq!(
            call(&store, verb, json!({"importId":id,"generation":"1"}))
                .unwrap_err()
                .code,
            "operationUnavailable"
        );
        assert_eq!(
            fs::read(fixture.record("rust-import-upload")).unwrap(),
            records
        );
    }
    drop(store);
    assert_eq!(
        call(&fixture.store(), "inspect", json!({"importId":id})).unwrap(),
        result
    );
}

fn commit(
    store: &ImportUploadStore,
    artifacts: &arkdeck_hoststore::ArtifactReadStore,
    id: &str,
) -> Result<Value, WireError> {
    store.commit(
        json!({"importId":id,"generation":"1"}).as_object().unwrap(),
        NOW,
        false,
        artifacts,
        1024 * 1024,
        binding,
    )
}
#[test]
fn publication_preserves_exact_bytes_receipt_identity_and_restart() {
    let fixture = Fixture::new();
    let bytes = b"PK\x03\x04token=must-not-redact";
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let initial = call(&store, "begin", fixture.metadata("publication", bytes)).unwrap();
    let id = initial["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let result = commit(&store, &artifacts, id).unwrap();
    assert_eq!(result["state"], "committed");
    assert_eq!(result["generation"], "2");
    let receipt = &result["receipt"];
    assert_eq!(
        fs::read(
            fixture
                .artifacts
                .join(id)
                .join(receipt["artifactId"].as_str().unwrap())
        )
        .unwrap(),
        bytes
    );
    let params = json!({"owner":{"kind":"import","id":id},"artifactId":receipt["artifactId"]});
    let inspected = store
        .artifact_resource(
            &artifacts,
            "artifact.inspect",
            params.as_object().unwrap(),
            &fixture.root.join("snapshots"),
        )
        .unwrap();
    assert_eq!(inspected["owner"]["kind"], "import");
    assert_eq!(inspected["redactionApplied"], false);
    assert_eq!(commit(&store, &artifacts, id).unwrap(), result);
    drop(store);
    let restarted = fixture.store();
    assert_eq!(commit(&restarted, &artifacts, id).unwrap(), result);
    assert!(!fixture.stage(id).exists());
}
#[test]
fn interrupted_publication_requires_receipt_and_recovers_same_identity() {
    for fault in [
        ImportUploadFault::AfterCommitIntent,
        ImportUploadFault::AfterPayloadPublication,
        ImportUploadFault::AfterPublication,
        ImportUploadFault::AfterReceiptCheckpoint,
    ] {
        let fixture = Fixture::new();
        let store = ImportUploadStore::open_with_fault(
            &fixture.artifacts,
            Arc::new(move |point| {
                if point == fault {
                    Err(io::Error::other("crash fixture"))
                } else {
                    Ok(())
                }
            }),
        )
        .unwrap();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let bytes = b"PK\x03\x04immutable";
        let initial = call(&store, "begin", fixture.metadata("interrupted", bytes)).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        assert_eq!(
            commit(&store, &artifacts, id).unwrap_err().code,
            "recordUnreadable"
        );
        if fault == ImportUploadFault::AfterPublication {
            let params = json!({"owner":{"kind":"import","id":id}});
            assert_eq!(
                store
                    .artifact_resource(
                        &artifacts,
                        "artifact.list",
                        params.as_object().unwrap(),
                        &fixture.root.join("snapshots")
                    )
                    .unwrap_err()
                    .code,
                "recordUnreadable"
            );
        }
        drop(store);
        let restarted = fixture.store();
        let done = restarted
            .commit(
                json!({"importId":id,"generation":"1"}).as_object().unwrap(),
                NOW,
                false,
                &artifacts,
                1024 * 1024,
                unavailable,
            )
            .unwrap();
        assert_eq!(done["state"], "committed");
        assert_eq!(names(&fixture.artifacts.join(id)).len(), 2);
        assert!(!fixture.stage(id).exists());
    }
}
#[test]
fn patch_publication_is_exact_and_sensitive_with_path_escape_refusal() {
    for (bytes, valid) in [
        (
            b"diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n+secret=unredacted\n"
                .as_slice(),
            true,
        ),
        (b"diff --git a/../escape b/../escape\n".as_slice(), false),
    ] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let mut metadata = fixture.metadata("patch", bytes);
        metadata["kind"] = json!("workspace-patch");
        metadata["name"] = json!("change.patch");
        let initial = call(&store, "begin", metadata).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        let result = commit(&store, &artifacts, id);
        if !valid {
            assert_eq!(result.unwrap_err().code, "invalidInput");
            continue;
        }
        let result = result.unwrap();
        let mut params =
            json!({"owner":{"kind":"import","id":id},"artifactId":result["receipt"]["artifactId"]});
        assert_eq!(
            store
                .artifact_resource(
                    &artifacts,
                    "artifact.read",
                    params.as_object().unwrap(),
                    &fixture.root.join("snapshots")
                )
                .unwrap_err()
                .code,
            "sensitiveAccessDenied"
        );
        params["allowSensitive"] = json!(true);
        let read = store
            .artifact_resource(
                &artifacts,
                "artifact.read",
                params.as_object().unwrap(),
                &fixture.root.join("snapshots"),
            )
            .unwrap();
        assert_eq!(read["base64"], encode_import_chunk(bytes).unwrap());
    }
}

#[test]
fn native_import_requires_registered_code_sign_structure_and_preserves_validation() {
    let signed=fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397")).unwrap();
    let mut unsigned = signed.clone();
    let trailer = unsigned.len() - 32;
    unsigned[trailer] = b'x';
    assert!(arkdeck_provider_hdc::validate_elf(&unsigned, None, false).is_ok());
    for bytes in [signed.as_slice(), unsigned.as_slice()] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let mut metadata = fixture.metadata("native", bytes);
        metadata["kind"] = json!("native-library");
        metadata["name"] = json!("libentry.so");
        let initial = call(&store, "begin", metadata).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        let result = commit(&store, &artifacts, id);
        if bytes == unsigned {
            assert_eq!(result.unwrap_err().code, "invalidInput");
            assert!(!fixture.artifacts.join(id).exists());
        } else {
            let result = result.unwrap();
            assert_eq!(result["receipt"]["validation"]["abi"], "arm64-v8a");
            assert_eq!(
                result["receipt"]["validation"]["buildId"],
                "00112233445566778899aabbccddeeff10213243"
            );
        }
    }
}
#[test]
fn publication_refuses_partial_digest_binding_and_quota_without_a_receipt() {
    for case in ["partial", "digest", "binding", "quota", "format"] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let bytes = if case == "format" {
            b"BAD!payload".as_slice()
        } else {
            b"PK\x03\x04payload".as_slice()
        };
        let mut metadata = fixture.metadata("refusal", bytes);
        if case == "digest" {
            metadata["sha256"] = json!("0".repeat(64));
        }
        let initial = call(&store, "begin", metadata).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(
            &store,
            id,
            0,
            if case == "partial" {
                &bytes[..4]
            } else {
                bytes
            },
        )
        .unwrap();
        let error = store
            .commit(
                json!({"importId":id,"generation":"1"}).as_object().unwrap(),
                NOW,
                false,
                &artifacts,
                if case == "quota" { 1 } else { 1024 },
                |intent| {
                    let mut b = binding(intent)?;
                    if case == "binding" {
                        b.binding_revision = Some(8);
                    }
                    Ok(b)
                },
            )
            .unwrap_err();
        assert_eq!(
            error.code,
            match case {
                "partial" | "binding" => "resourceConflict",
                "digest" => "artifactIntegrityFailed",
                "quota" => "quotaExceeded",
                _ => "invalidInput",
            },
            "{case}"
        );
        let inspected = call(&store, "inspect", json!({"importId":id})).unwrap();
        assert!(inspected["receipt"].is_null());
    }
}
#[test]
fn import_discovery_snapshot_export_and_receipt_metadata_poisoning() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let bytes = b"PK\x03\x04exact";
    let initial = call(&store, "begin", fixture.metadata("first", bytes)).unwrap();
    let id = initial["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let pending = store
        .list(json!({"state":"inProgress"}).as_object().unwrap())
        .unwrap();
    assert_eq!(pending["items"].as_array().unwrap().len(), 1);
    let done = commit(&store, &artifacts, id).unwrap();
    let aid = done["receipt"]["artifactId"].as_str().unwrap();
    let list = store
        .list(
            json!({"state":"committed","target":"TGT-fixture"})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    assert_eq!(list["items"][0], done);
    assert!(
        store
            .list(json!({"state":"bogus"}).as_object().unwrap())
            .is_err()
    );
    let output = fixture.root.join("export");
    fs::DirBuilder::new().mode(0o700).create(&output).unwrap();
    let exported=store.artifact_resource(&artifacts,"artifact.export",json!({"owner":{"kind":"import","id":id},"artifactId":aid,"destinationDirectory":output}).as_object().unwrap(),&fixture.root.join("snapshots")).unwrap();
    assert_eq!(exported["owner"]["kind"], "import");
    assert_eq!(
        fs::read(output.join(format!("{aid}-fixture.hap"))).unwrap(),
        bytes
    );
    let index = fixture.artifacts.join(id).join("index.json");
    let mut document = read(&index);
    document["artifacts"][0]["sourceOperation"] = json!("artifact.import-native-library");
    fs::write(index, serde_json::to_vec(&document).unwrap()).unwrap();
    assert_eq!(
        store
            .artifact_resource(
                &artifacts,
                "artifact.inspect",
                json!({"owner":{"kind":"import","id":id},"artifactId":aid})
                    .as_object()
                    .unwrap(),
                &fixture.root.join("snapshots")
            )
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
}

#[test]
fn receipt_identity_digest_generation_and_validation_corruption_cannot_supply_bytes() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let bytes = b"PK\x03\x04exact";
    let initial = call(&store, "begin", fixture.metadata("receipt", bytes)).unwrap();
    let id = initial["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let done = commit(&store, &artifacts, id).unwrap();
    let path = fixture.record("receipt");
    let original = read(&path);
    for (key, value) in [
        (
            "importId",
            json!("imp-00000000-0000-0000-0000-000000000000"),
        ),
        ("importRequestId", json!("other")),
        ("owner", json!({"kind":"job","id":id})),
        ("artifactId", json!("ART-other")),
        ("artifactDigest", json!("0".repeat(64))),
        ("generation", json!("3")),
        ("validation", json!({"kind":"hap","container":"other"})),
        ("bindingRevision", json!("8")),
    ] {
        let mut changed = original.clone();
        changed["receipt"][key] = value;
        fs::write(&path, serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_eq!(store.artifact_resource(&artifacts,"artifact.read",json!({"owner":{"kind":"import","id":id},"artifactId":done["receipt"]["artifactId"]}).as_object().unwrap(),&fixture.root.join("snapshots")).unwrap_err().code,"recordUnreadable","{key}");
    }
}
#[test]
fn import_list_pagination_keeps_snapshot_and_rejects_foreign_query_cursor() {
    let fixture = Fixture::new();
    let store = fixture.store();
    for request in ["one", "two"] {
        call(&store, "begin", fixture.metadata(request, b"PK\x03\x04")).unwrap();
    }
    let first = store
        .list(json!({"pageSize":1}).as_object().unwrap())
        .unwrap();
    assert_eq!(first["items"].as_array().unwrap().len(), 1);
    assert_eq!(first["hasMore"], true);
    call(&store, "begin", fixture.metadata("three", b"PK\x03\x04")).unwrap();
    let cursor = &first["nextCursor"];
    let second = store
        .list(json!({"pageSize":1,"cursor":cursor}).as_object().unwrap())
        .unwrap();
    assert_eq!(second["items"].as_array().unwrap().len(), 1);
    assert_eq!(second["hasMore"], false);
    assert_eq!(
        store
            .list(
                json!({"pageSize":1,"cursor":cursor,"state":"inProgress"})
                    .as_object()
                    .unwrap()
            )
            .unwrap_err()
            .code,
        "invalidCursor"
    );
    for invalid in [
        json!({"pageSize":1.5}),
        json!({"pageSize":0}),
        json!({"target":"../path"}),
        json!({"cursor":null}),
        json!({"extra":true}),
    ] {
        assert!(store.list(invalid.as_object().unwrap()).is_err());
    }
}

#[test]
fn unfinished_copy_is_reclaimed_but_linked_copy_never_touches_external_bytes() {
    use std::os::unix::fs::PermissionsExt;
    for linked in [false, true] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let bytes = b"PK\x03\x04exact";
        let initial = call(&store, "begin", fixture.metadata("copy", bytes)).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        let digest = sha256_hex(format!("{id}\0fixture.hap\0{}", sha256_hex(bytes)).as_bytes());
        let aid = format!("ART-{}", &digest[..32]);
        let dir = fixture.artifacts.join(id);
        fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let temporary = dir.join(format!(".{aid}.{}.tmp", "0".repeat(32)));
        let outside = fixture.root.join("outside");
        fs::write(&outside, b"keep").unwrap();
        if linked {
            symlink(&outside, &temporary).unwrap();
        } else {
            fs::write(&temporary, b"partial copy").unwrap();
            fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let result = commit(&store, &artifacts, id);
        if linked {
            assert_eq!(result.unwrap_err().code, "recordUnreadable");
            assert_eq!(fs::read(outside).unwrap(), b"keep");
        } else {
            result.unwrap();
            assert!(!temporary.exists());
            assert_eq!(fs::read(dir.join(aid)).unwrap(), bytes);
        }
    }
}

#[test]
fn published_but_unreceipted_missing_or_corrupt_payload_cannot_finish_commit() {
    use std::os::unix::fs::PermissionsExt;
    for missing in [true, false] {
        let fixture = Fixture::new();
        let store = ImportUploadStore::open_with_fault(
            &fixture.artifacts,
            Arc::new(|point| {
                if point == ImportUploadFault::AfterPublication {
                    Err(io::Error::other("interruption"))
                } else {
                    Ok(())
                }
            }),
        )
        .unwrap();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let bytes = b"PK\x03\x04exact";
        let initial = call(&store, "begin", fixture.metadata("poison", bytes)).unwrap();
        let id = initial["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        assert!(commit(&store, &artifacts, id).is_err());
        drop(store);
        let index = read(&fixture.artifacts.join(id).join("index.json"));
        let payload = fixture
            .artifacts
            .join(id)
            .join(index["artifacts"][0]["artifactID"].as_str().unwrap());
        if missing {
            fs::remove_file(&payload).unwrap();
        } else {
            fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
            fs::write(&payload, b"BAD!exact").unwrap();
            fs::set_permissions(&payload, fs::Permissions::from_mode(0o400)).unwrap();
        }
        let restarted = fixture.store();
        assert_eq!(
            commit(&restarted, &artifacts, id).unwrap_err().code,
            "recordUnreadable"
        );
        let state = call(&restarted, "inspect", json!({"importId":id})).unwrap();
        assert_eq!(state["state"], "committing");
        assert!(state["receipt"].is_null());
        assert_eq!(fs::read(fixture.stage(id)).unwrap(), bytes);
    }
}

fn lifecycle(
    store: &ImportUploadStore,
    artifacts: &arkdeck_hoststore::ArtifactReadStore,
    jobs: &arkdeck_hoststore::JobStore,
    method: &str,
    params: Value,
) -> Result<Value, WireError> {
    store.lifecycle_resource(
        artifacts,
        jobs,
        &format!("artifact.import.{method}"),
        params.as_object().unwrap(),
        NOW,
    )
}
fn jobs(fixture: &Fixture) -> arkdeck_hoststore::JobStore {
    let root = fixture.root.join("jobs-state");
    if !root.exists() {
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    }
    arkdeck_hoststore::JobStore::open_owner(&root).unwrap()
}
#[test]
fn release_is_durable_idempotent_and_preserves_historical_artifact_reads() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04host-only-lifecycle";
    let begin = call(&store, "begin", fixture.metadata("lifecycle", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id})
        )
        .unwrap()["references"]["state"],
        "clear"
    );
    let release = lifecycle(
        &store,
        &artifacts,
        &jobs,
        "release",
        json!({"importId":id,"generation":"2"}),
    )
    .unwrap();
    assert_eq!(release["retention"]["pinned"], false);
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap(),
        release
    );
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"3"})
        )
        .unwrap_err()
        .code,
        "resourceConflict"
    );
    let snapshots = fixture.root.join("snapshots");
    let request =
        json!({"owner":{"kind":"import","id":id},"artifactId":committed["receipt"]["artifactId"]});
    let inspected = store
        .artifact_resource(
            &artifacts,
            "artifact.inspect",
            request.as_object().unwrap(),
            &snapshots,
        )
        .unwrap();
    assert_eq!(inspected["lease"], Value::Null);
    assert_eq!(inspected["retention"]["pinned"], false);
    assert_eq!(
        fs::read(
            fixture
                .artifacts
                .join(id)
                .join(committed["receipt"]["artifactId"].as_str().unwrap())
        )
        .unwrap(),
        bytes
    );
    drop(store);
    let restarted = fixture.store();
    assert_eq!(
        lifecycle(
            &restarted,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap(),
        release
    );
}
#[test]
fn release_crash_windows_recover_the_same_deadline_without_reviving_a_pin() {
    for fault in [
        ImportUploadFault::AfterReleaseCheckpoint,
        ImportUploadFault::AfterReleaseUnpin,
    ] {
        let fixture = Fixture::new();
        let store = ImportUploadStore::open_with_fault(
            &fixture.artifacts,
            Arc::new(move |point| {
                if point == fault {
                    Err(io::Error::other("crash window"))
                } else {
                    Ok(())
                }
            }),
        )
        .unwrap();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let jobs = jobs(&fixture);
        let bytes = b"PK\x03\x04release-crash";
        let begin = call(&store, "begin", fixture.metadata("release-crash", bytes)).unwrap();
        let id = begin["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        commit(&store, &artifacts, id).unwrap();
        assert!(
            lifecycle(
                &store,
                &artifacts,
                &jobs,
                "release",
                json!({"importId":id,"generation":"2"})
            )
            .is_err()
        );
        let durable = read(&fixture.record("release-crash"));
        assert_eq!(durable["state"], "released");
        let receipt = durable["releaseReceipt"].clone();
        drop(store);
        let restarted = fixture.store();
        assert_eq!(
            lifecycle(
                &restarted,
                &artifacts,
                &jobs,
                "release",
                json!({"importId":id,"generation":"2"})
            )
            .unwrap(),
            receipt
        );
        assert_eq!(
            read(&fixture.artifacts.join(id).join("index.json"))["artifacts"][0]["retention"]["deadlineUTC"],
            receipt["retention"]["deadlineUtc"]
        );
    }
}

fn analyzer_request(lease: &Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0","requestId":"req-import-lifecycle","idempotencyKey":"idem-import-lifecycle","target":{"targetId":"TGT-fixture"},"operation":{"id":"analyzer.extract-crash-signature","version":1},"inputs":{"sourceArtifactRef":lease}})).unwrap()
}
#[test]
fn materialization_hold_blocks_release_and_failed_planning_drops_it() {
    use std::sync::Barrier;
    let fixture = Fixture::new();
    let entered = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let (worker_enter, worker_resume) = (entered.clone(), resume.clone());
    let store = ImportUploadStore::open_with_fault(
        &fixture.artifacts,
        Arc::new(move |point| {
            if point == ImportUploadFault::AfterInputHold {
                worker_enter.wait();
                worker_resume.wait();
            }
            Ok(())
        }),
    )
    .unwrap();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04hold";
    let begin = call(&store, "begin", fixture.metadata("hold", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    let request = analyzer_request(&committed["receipt"]["lease"]);
    std::thread::scope(|scope| {
        let planner = arkdeck_hoststore::JobPlanner {
            imports: Some(&store),
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &fixture.root,
            hdc: None,
        };
        let thread = scope.spawn(move || planner.plan(&request));
        entered.wait();
        let inspection = lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id}),
        )
        .unwrap();
        assert_eq!(inspection["references"]["activeMaterializationCount"], "1");
        assert_eq!(
            lifecycle(
                &store,
                &artifacts,
                &jobs,
                "release",
                json!({"importId":id,"generation":"2"})
            )
            .unwrap_err()
            .code,
            "resourceConflict"
        );
        resume.wait();
        assert!(thread.join().unwrap().is_err());
    });
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id})
        )
        .unwrap()["references"]["activeMaterializationCount"],
        "0"
    );
    lifecycle(
        &store,
        &artifacts,
        &jobs,
        "release",
        json!({"importId":id,"generation":"2"}),
    )
    .unwrap();
    let planner = arkdeck_hoststore::JobPlanner {
        imports: Some(&store),
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &fixture.root,
        hdc: None,
    };
    assert!(
        planner
            .plan(&analyzer_request(&committed["receipt"]["lease"]))
            .is_err()
    );
}
#[test]
fn admitted_import_is_retained_across_restart_and_retries_without_new_hold() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04admitted";
    let begin = call(&store, "begin", fixture.metadata("admitted", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    use std::os::unix::fs::PermissionsExt;
    let analyzer = fixture.root.join("analyzer");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/job-submit-analyzer/analyzer"),
        &analyzer,
    )
    .unwrap();
    fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
    let profile = arkdeck_hoststore::AnalyzerProfile::crash_signature(&analyzer).unwrap();
    let request = analyzer_request(&committed["receipt"]["lease"]);
    let admit = arkdeck_hoststore::JobAdmitter {
        planner: arkdeck_hoststore::JobPlanner {
            imports: Some(&store),
            artifacts: Some(&artifacts),
            analyzer: Some(&profile),
            state_root: &fixture.root,
            hdc: None,
        },
        jobs: &jobs,
        now: || Some(NOW.into()),
    };
    let accepted = admit.submit(&request).unwrap();
    fs::write(
        &analyzer,
        b"changed tool must not rematerialize an idempotent retry",
    )
    .unwrap();
    assert_eq!(admit.submit(&request).unwrap()["jobId"], accepted["jobId"]);
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap_err()
        .code,
        "resourceConflict"
    );
    drop(jobs);
    drop(store);
    let store = fixture.store();
    let jobs = crate::jobs(&fixture);
    let inspection = lifecycle(
        &store,
        &artifacts,
        &jobs,
        "inspection",
        json!({"importId":id}),
    )
    .unwrap();
    assert_eq!(
        inspection["references"]["activeJobIds"],
        json!([accepted["jobId"]])
    );
    assert_eq!(inspection["references"]["activeMaterializationCount"], "0");
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap_err()
        .code,
        "resourceConflict"
    );
    let snapshot = fixture
        .root
        .join("jobs-state/jobs")
        .join(accepted["jobId"].as_str().unwrap())
        .join("job-record.json");
    let original = fs::read(&snapshot).unwrap();
    let mut drifted: Value = serde_json::from_slice(&original).unwrap();
    drifted["request"]["inputs"]["sourceArtifactRef"] =
        json!("lease-v1:job-other:ART-00000000000000000000000000000000");
    fs::write(&snapshot, serde_json::to_vec(&drifted).unwrap()).unwrap();
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap_err()
        .code,
        "recordUnreadable"
    );
    fs::write(&snapshot, original).unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(fixture.root.join("jobs-state/jobs/job-orphan"))
        .unwrap();
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id})
        )
        .unwrap_err()
        .code,
        "recordUnreadable"
    );
}

#[test]
fn missing_terminal_job_directory_cannot_clear_import_references() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04admitted";
    let begin = call(&store, "begin", fixture.metadata("admitted", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    use std::os::unix::fs::PermissionsExt;
    let analyzer = fixture.root.join("analyzer");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/job-submit-analyzer/analyzer"),
        &analyzer,
    )
    .unwrap();
    fs::set_permissions(&analyzer, fs::Permissions::from_mode(0o700)).unwrap();
    let profile = arkdeck_hoststore::AnalyzerProfile::crash_signature(&analyzer).unwrap();
    let request = analyzer_request(&committed["receipt"]["lease"]);
    let admit = arkdeck_hoststore::JobAdmitter {
        planner: arkdeck_hoststore::JobPlanner {
            imports: Some(&store),
            artifacts: Some(&artifacts),
            analyzer: Some(&profile),
            state_root: &fixture.root,
            hdc: None,
        },
        jobs: &jobs,
        now: || Some(NOW.into()),
    };
    let accepted = admit.submit(&request).unwrap();
    let job_id = accepted["jobId"].as_str().unwrap();
    for name in ["session-owner", "Sessions"] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(fixture.root.join(name))
            .unwrap();
    }
    let sessions = arkdeck_hoststore::SessionStore::open(
        &fixture.root.join("session-owner"),
        &fixture.root.join("Sessions"),
    )
    .unwrap();
    let claims = arkdeck_hoststore::StorageClaims::default();
    let probe = arkdeck_hoststore::SystemStorageProbe;
    let publisher = arkdeck_hoststore::SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &probe,
    };
    arkdeck_hoststore::JobCanceller {
        jobs: &jobs,
        now: || Some(NOW.into()),
        sessions: Some(&publisher),
    }
    .handle(json!({"jobId":job_id}).as_object().unwrap())
    .unwrap();
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id})
        )
        .unwrap()["references"]["state"],
        "clear"
    );
    let pinned =
        read(&fixture.artifacts.join(id).join("index.json"))["artifacts"][0]["retention"].clone();
    fs::remove_dir_all(fixture.root.join("jobs-state/jobs").join(job_id)).unwrap();
    // Reopen both durable owners: no transient hold supplies this refusal.
    drop(jobs);
    drop(store);
    let jobs = crate::jobs(&fixture);
    let store = fixture.store();
    for method in ["inspection", "release"] {
        let fields = if method == "release" {
            json!({"importId":id,"generation":"2"})
        } else {
            json!({"importId":id})
        };
        assert_eq!(
            lifecycle(&store, &artifacts, &jobs, method, fields)
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
    assert_eq!(
        call(&store, "inspect", json!({"importId":id})).unwrap()["state"],
        "committed"
    );
    assert_eq!(
        read(&fixture.artifacts.join(id).join("index.json"))["artifacts"][0]["retention"],
        pinned
    );
}

#[test]
fn reference_census_checks_submission_hash_history_and_unknown_outcomes() {
    for case in [
        "active",
        "enriched",
        "unknown-terminal",
        "terminal",
        "foreign-catalog",
        "changed-input",
        "changed-original",
        "wrong-fingerprint",
        "broken-unrelated-terminal",
    ] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let jobs = jobs(&fixture);
        let bytes = b"PK\x03\x04census";
        let begin = call(&store, "begin", fixture.metadata("census", bytes)).unwrap();
        let id = begin["importId"].as_str().unwrap();
        append(&store, id, 0, bytes).unwrap();
        let committed = commit(&store, &artifacts, id).unwrap();
        let request = arkdeck_hoststore::OperationRequest::decode(&analyzer_request(
            &committed["receipt"]["lease"],
        ))
        .unwrap();
        let mut value = json!({"jobID":"job-reference","request":request.canonical_value(),"originalSubmissionRequest":request.canonical_value(),"operationReference":"analyzer.extract-crash-signature@1","catalogDigest":arkdeck_contract::CATALOG_DIGEST,"providerID":"analyzer","createdAtUTC":NOW,"state":"queued","outcomeUnknown":false,"timeline":[],"actualStepKinds":[],"skipReasons":{}});
        if case == "enriched" {
            value["request"]["authorization"] = json!({"capabilityId":"CAP-RT-test-enriched"});
        }
        if case == "unknown-terminal" {
            value["state"] = json!("failed");
            value["outcomeUnknown"] = json!(true);
        }
        if case == "terminal" || case == "broken-unrelated-terminal" {
            value["state"] = json!("succeeded");
        }
        if case == "foreign-catalog" {
            value["catalogDigest"] = json!("f".repeat(64));
        }
        if case == "changed-input" {
            value["request"]["inputs"]["sourceArtifactRef"] =
                json!("lease-v1:job-unrelated:ART-00000000000000000000000000000000");
        }
        if case == "changed-original" {
            value["originalSubmissionRequest"]["inputs"]["sourceArtifactRef"] =
                json!("lease-v1:job-unrelated:ART-00000000000000000000000000000000");
        }
        let record =
            arkdeck_hoststore::JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        jobs.admit(
            &record,
            &if case == "wrong-fingerprint" {
                "a".repeat(64)
            } else {
                request.fingerprint()
            },
        )
        .unwrap();
        if case == "broken-unrelated-terminal" {
            let mut db = arkdeck_platform::HostSqlite::open(
                &fixture.root.join("jobs-state/runtime-jobs.sqlite3"),
                false,
                false,
            )
            .unwrap();
            db.execute(
                "UPDATE runtime_job SET initial_record_json = ?",
                &[arkdeck_platform::SqliteValue::Blob(b"{".to_vec())],
            )
            .unwrap();
        }
        let inspection = lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id}),
        );
        let release = lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"}),
        );
        match case {
            "active" | "enriched" | "foreign-catalog" => {
                let inspection = inspection.unwrap();
                assert_eq!(
                    inspection["references"]["activeJobIds"],
                    json!(["job-reference"])
                );
                assert_eq!(release.unwrap_err().code, "resourceConflict");
            }
            _ => {
                assert_eq!(inspection.unwrap_err().code, "recordUnreadable", "{case}");
                assert_eq!(release.unwrap_err().code, "recordUnreadable", "{case}");
            }
        }
    }
}

#[test]
fn concurrent_releases_share_one_receipt_and_missing_payload_never_reopens_the_lease() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04concurrent-release";
    let begin = call(
        &store,
        "begin",
        fixture.metadata("concurrent-release", bytes),
    )
    .unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    let barrier = std::sync::Barrier::new(3);
    let release = std::thread::scope(|scope| {
        let run = || {
            barrier.wait();
            lifecycle(
                &store,
                &artifacts,
                &jobs,
                "release",
                json!({"importId":id,"generation":"2"}),
            )
            .unwrap()
        };
        let a = scope.spawn(run);
        let b = scope.spawn(run);
        barrier.wait();
        let first = a.join().unwrap();
        assert_eq!(first, b.join().unwrap());
        first
    });
    let aid = committed["receipt"]["artifactId"].as_str().unwrap();
    // Model completed retention reclamation: no metadata/payload are recreated.
    fs::remove_file(fixture.artifacts.join(id).join(aid)).unwrap();
    fs::remove_file(fixture.artifacts.join(id).join("index.json")).unwrap();
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .unwrap(),
        release
    );
    assert!(!fixture.artifacts.join(id).join(aid).exists());
}

#[test]
fn unfinished_or_wrong_artifact_identity_never_acquires_an_input_hold() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04incomplete-input";
    let begin = call(&store, "begin", fixture.metadata("incomplete-input", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    let lease = json!(format!(
        "lease-v1:{id}:ART-00000000000000000000000000000000"
    ));
    let planner = arkdeck_hoststore::JobPlanner {
        imports: Some(&store),
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &fixture.root,
        hdc: None,
    };
    assert!(
        planner
            .plan(&analyzer_request(&lease))
            .unwrap_err()
            .message
            .contains("valid committed import")
    );
    append(&store, id, 0, bytes).unwrap();
    commit(&store, &artifacts, id).unwrap();
    assert!(
        planner
            .plan(&analyzer_request(&lease))
            .unwrap_err()
            .message
            .contains("valid committed import")
    );
    assert_eq!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspection",
            json!({"importId":id})
        )
        .unwrap()["references"]["activeMaterializationCount"],
        "0"
    );
}

#[test]
fn release_recovery_refuses_retention_drift_and_keeps_the_closed_lease() {
    let fixture = Fixture::new();
    let store = ImportUploadStore::open_with_fault(
        &fixture.artifacts,
        Arc::new(|point| {
            if point == ImportUploadFault::AfterReleaseCheckpoint {
                Err(io::Error::other("release checkpoint"))
            } else {
                Ok(())
            }
        }),
    )
    .unwrap();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04retention-drift";
    let begin = call(&store, "begin", fixture.metadata("retention-drift", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    let committed = commit(&store, &artifacts, id).unwrap();
    assert!(
        lifecycle(
            &store,
            &artifacts,
            &jobs,
            "release",
            json!({"importId":id,"generation":"2"})
        )
        .is_err()
    );
    drop(store);
    let index = fixture.artifacts.join(id).join("index.json");
    let mut altered = read(&index);
    altered["artifacts"][0]["retention"] =
        json!({"retentionClass":"default","pinned":false,"deadlineUTC":"2027-09-19T00:00:00Z"});
    let bytes = serde_json::to_vec(&altered).unwrap();
    fs::write(&index, &bytes).unwrap();
    let store = fixture.store();
    assert_eq!(
        lifecycle(&store, &artifacts, &jobs, "inspect", json!({"importId":id}))
            .unwrap_err()
            .code,
        "recordUnreadable"
    );
    assert_eq!(fs::read(&index).unwrap(), bytes);
    let planner = arkdeck_hoststore::JobPlanner {
        imports: Some(&store),
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &fixture.root,
        hdc: None,
    };
    assert!(
        planner
            .plan(&analyzer_request(&committed["receipt"]["lease"]))
            .is_err()
    );
    assert_eq!(
        read(&fixture.record("retention-drift"))["state"],
        "released"
    );
}

#[test]
#[ignore = "subprocess fixture invoked by the SIGKILL durability test"]
fn release_sigkill_child() {
    let Some(root) = std::env::var_os("ARKDECK_TEST_IMPORT_RELEASE_CRASH_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    let window = std::env::var("ARKDECK_TEST_IMPORT_RELEASE_CRASH_WINDOW").unwrap();
    let ready = root.join("ready");
    let point = if window == "checkpoint" {
        ImportUploadFault::AfterReleaseCheckpoint
    } else {
        assert_eq!(window, "unpin");
        ImportUploadFault::AfterReleaseUnpin
    };
    let fixture = Fixture {
        artifacts: root.join("artifacts"),
        root,
    };
    let store = ImportUploadStore::open_with_fault(
        &fixture.artifacts,
        Arc::new(move |observed| {
            if observed == point {
                fs::write(&ready, b"durable window").unwrap();
                loop {
                    std::thread::park();
                }
            }
            Ok(())
        }),
    )
    .unwrap();
    let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let jobs = jobs(&fixture);
    let bytes = b"PK\x03\x04sigkill-release";
    let begin = call(&store, "begin", fixture.metadata("sigkill-release", bytes)).unwrap();
    let id = begin["importId"].as_str().unwrap();
    append(&store, id, 0, bytes).unwrap();
    commit(&store, &artifacts, id).unwrap();
    let _ = lifecycle(
        &store,
        &artifacts,
        &jobs,
        "release",
        json!({"importId":id,"generation":"2"}),
    );
    panic!("crash fixture did not reach its requested window");
}
#[test]
fn sigkill_after_release_checkpoint_and_unpin_preserves_the_original_receipt() {
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    for window in ["checkpoint", "unpin"] {
        let fixture = Fixture::new();
        let mut child = Child(
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "release_sigkill_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env("ARKDECK_TEST_IMPORT_RELEASE_CRASH_ROOT", &fixture.root)
                .env("ARKDECK_TEST_IMPORT_RELEASE_CRASH_WINDOW", window)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::inherit())
                .spawn()
                .unwrap(),
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !fixture.root.join("ready").exists() {
            assert!(
                child.0.try_wait().unwrap().is_none(),
                "fixture exited before {window}"
            );
            assert!(
                std::time::Instant::now() < deadline,
                "fixture missed {window}"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        let durable = read(&fixture.record("sigkill-release"));
        let receipt = durable["releaseReceipt"].clone();
        let store = fixture.store();
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&fixture.artifacts).unwrap();
        let jobs = jobs(&fixture);
        let projection = lifecycle(
            &store,
            &artifacts,
            &jobs,
            "inspect",
            json!({"importRequestId":"sigkill-release"}),
        )
        .unwrap();
        assert_eq!(projection["state"], "released");
        assert_eq!(
            lifecycle(
                &store,
                &artifacts,
                &jobs,
                "release",
                json!({"importId":projection["importId"],"generation":"2"})
            )
            .unwrap(),
            receipt
        );
        let index = read(
            &fixture
                .artifacts
                .join(projection["importId"].as_str().unwrap())
                .join("index.json"),
        );
        assert_eq!(
            index["artifacts"][0]["retention"]["deadlineUTC"],
            receipt["retention"]["deadlineUtc"]
        );
        assert_eq!(index["artifacts"][0]["retention"]["pinned"], false);
    }
}
