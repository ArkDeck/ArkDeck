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
        binding_revision: Some(intent.binding_revision),
        stable_identity_sha256: Some("a".repeat(64)),
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
#[ignore = "subprocess fixture invoked by sigkill_upload_recovery_uses_only_durable_checkpoints"]
fn sigkill_upload_helper() {
    let root = PathBuf::from(std::env::var_os("ARKDECK_IMPORT_KILL_ROOT").unwrap());
    let window = std::env::var("ARKDECK_IMPORT_KILL_WINDOW").unwrap();
    let marker = root.join("ready");
    let desired = window.clone();
    let store = ImportUploadStore::open_with_fault(
        &root.join("artifacts"),
        Arc::new(move |point| {
            if format!("{point:?}") == desired {
                fs::write(&marker, b"ready")?;
                loop {
                    std::thread::park();
                }
            }
            Ok(())
        }),
    )
    .unwrap();
    if window == "AfterBeginCheckpoint" {
        let metadata = json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":"killed-begin","kind":"hap","targetId":"TGT-fixture","bindingRevision":"7","deviceProfile":null,"name":"fixture.hap","byteCount":"8","sha256":sha256_hex(b"abcdefgh")});
        call(&store, "begin", metadata).unwrap();
    } else if window == "AfterAbortCheckpoint" {
        call(
            &store,
            "abort",
            json!({"importRequestId":"killed-upload","generation":"1"}),
        )
        .unwrap();
    } else {
        let current = call(
            &store,
            "inspect",
            json!({"importRequestId":"killed-upload"}),
        )
        .unwrap();
        append(&store, current["importId"].as_str().unwrap(), 4, b"efgh").unwrap();
    }
    panic!("kill checkpoint was not reached");
}

#[test]
fn sigkill_upload_recovery_uses_only_durable_checkpoints() {
    use std::time::{Duration, Instant};
    for window in [
        "AfterBeginCheckpoint",
        "AfterPartialChunk",
        "AfterChunkSync",
        "AfterAppendCheckpoint",
        "AfterAbortCheckpoint",
    ] {
        let fixture = Fixture::new();
        let store = fixture.store();
        let begun = call(
            &store,
            "begin",
            fixture.metadata("killed-upload", b"abcdefgh"),
        )
        .unwrap();
        let id = begun["importId"].as_str().unwrap();
        append(&store, id, 0, b"abcd").unwrap();
        drop(store);
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "sigkill_upload_helper",
                "--ignored",
                "--nocapture",
            ])
            .env("ARKDECK_IMPORT_KILL_ROOT", &fixture.root)
            .env("ARKDECK_IMPORT_KILL_WINDOW", window)
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !fixture.root.join("ready").is_file()
            && Instant::now() < deadline
            && child.try_wait().unwrap().is_none()
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let reached = fixture.root.join("ready").is_file();
        let _ = child.kill();
        let status = child.wait().unwrap();
        assert!(reached, "child failed before {window}: {status}");
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(
            status.signal(),
            Some(9),
            "expected actual SIGKILL at {window}"
        );
        let store = fixture.store();
        let request = if window == "AfterBeginCheckpoint" {
            "killed-begin"
        } else {
            "killed-upload"
        };
        let recovered = call(&store, "inspect", json!({"importRequestId":request})).unwrap();
        let recovered_id = recovered["importId"].as_str().unwrap();
        match window {
            "AfterBeginCheckpoint" => {
                assert_eq!(recovered["nextOffset"], "0");
                assert_eq!(fs::read(fixture.stage(recovered_id)).unwrap(), b"");
            }
            "AfterAppendCheckpoint" => {
                assert_eq!(recovered["nextOffset"], "8");
                assert_eq!(fs::read(fixture.stage(id)).unwrap(), b"abcdefgh");
            }
            "AfterAbortCheckpoint" => {
                assert_eq!(recovered["state"], "aborted");
                assert!(!fixture.stage(id).exists());
            }
            _ => {
                assert_eq!(recovered["nextOffset"], "4");
                assert_eq!(fs::read(fixture.stage(id)).unwrap(), b"abcd");
            }
        }
        assert_eq!(
            read(&fixture.identity(recovered_id))["importRequestId"],
            request
        );
    }
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
