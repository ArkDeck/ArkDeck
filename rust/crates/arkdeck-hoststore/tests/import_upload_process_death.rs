#![cfg(target_os = "macos")]
//! Import upload recovery after an actual SIGKILL at each durable write point.
//!
//! These tests spawn child processes, so they have their own test binary: a
//! child spawned while another test thread closes and reopens an owner lock
//! briefly holds that thread's closed flock descriptor, and the non-blocking
//! reopen then fails with WouldBlock.
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ImportBinding, ImportUploadStore};
use serde_json::{Value, json};
use std::os::unix::fs::DirBuilderExt;
use std::{
    fs,
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
        // The helper's startup and durable writes are real work that a loaded
        // host can stretch past any tight budget, so the wait ends on its
        // marker or its exit; the bound only keeps a hung helper from hanging
        // the test.
        let deadline = Instant::now() + Duration::from_secs(60);
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
