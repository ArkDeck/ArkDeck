//! A DAYU200 flash bundle through the Import owner's commit, validated as
//! Swift's production policy validates it (`RuntimeImportControlHandler.
//! validate` with `FlashBundleImportPolicy.production`). A bundle that reads
//! and fits the board is published with Swift's facts. Any other is refused
//! as Swift's handler refuses it: its own detail is swallowed into the
//! validator's one refusal, and the Import stays in progress with nothing
//! published.
#![cfg(target_os = "macos")]

use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;

const NOW: &str = "2026-09-25T00:00:00Z";

struct Fixture {
    root: PathBuf,
    artifacts: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "rust-flash-bundle-import-{:032x}",
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
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn archive(name: &str) -> Vec<u8> {
    fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/flash-archive/archives")
            .join(name),
    )
    .unwrap()
}

/// A flash bundle's Target binds its physical identity.
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

/// Begins, uploads and commits `bytes` as a flash bundle.
fn upload(
    fixture: &Fixture,
    store: &ImportUploadStore,
    request: &str,
    bytes: &[u8],
) -> (String, Result<Value, WireError>) {
    let begun = call(
        store,
        "begin",
        json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":request,
            "kind":"flash-bundle","targetId":"TGT-board","bindingRevision":"2",
            "deviceProfile":"dayu200","name":"images.tar.gz",
            "byteCount":bytes.len().to_string(),"sha256":sha256_hex(bytes)}),
    )
    .unwrap();
    let id = begun["importId"].as_str().unwrap().to_owned();
    call(
        store,
        "append",
        json!({"importId":id,"generation":"1","offset":"0","byteCount":bytes.len().to_string(),
            "sha256":sha256_hex(bytes),"base64":encode_import_chunk(bytes).unwrap()}),
    )
    .unwrap();
    let artifacts = ArtifactReadStore::open(&fixture.artifacts).unwrap();
    let committed = store.commit(
        json!({"importId":id,"generation":"1"}).as_object().unwrap(),
        NOW,
        false,
        &artifacts,
        1024 * 1024,
        binding,
    );
    (id, committed)
}

#[test]
fn a_bundle_that_fits_the_board_is_published_with_swifts_facts() {
    let fixture = Fixture::new();
    let store = ImportUploadStore::open(&fixture.artifacts).unwrap();
    // A plain bundle, and one carrying every optional gzip header field.
    for (request, name) in [
        ("flash-complete", "complete.tar.gz"),
        ("flash-optional-fields", "gzip-optional-fields.tar.gz"),
    ] {
        let bytes = archive(name);
        let (id, committed) = upload(&fixture, &store, request, &bytes);
        let committed = committed.unwrap();
        assert_eq!(committed["state"], "committed", "{name}");
        let receipt = &committed["receipt"];
        assert_eq!(
            receipt["validation"],
            json!({"kind":"flash-bundle","deviceProfile":"dayu200"}),
            "{name}"
        );
        assert_eq!(
            fs::read(
                fixture
                    .artifacts
                    .join(&id)
                    .join(receipt["artifactId"].as_str().unwrap())
            )
            .unwrap(),
            bytes,
            "{name}"
        );
    }
}

#[test]
fn a_bundle_that_does_not_read_or_fit_is_refused_and_nothing_is_published() {
    let fixture = Fixture::new();
    let store = ImportUploadStore::open(&fixture.artifacts).unwrap();
    for name in [
        "plain.tar",
        "truncated-deflate.tar.gz",
        "bad-checksum.tar.gz",
        "no-version.tar.gz",
        "parameter-crlf.tar.gz",
        "nonconforming.tar.gz",
        "duplicate-member.tar.gz",
    ] {
        let (id, committed) = upload(&fixture, &store, name, &archive(name));
        let refused = committed.unwrap_err();
        assert_eq!(
            (refused.code.as_str(), refused.message.as_str()),
            (
                "invalidInput",
                "Import content failed its registered format validator"
            ),
            "{name}"
        );
        let inspected = call(&store, "inspect", json!({"importId": id})).unwrap();
        assert_eq!(inspected["state"], "inProgress", "{name}");
        assert_eq!(inspected["receipt"], Value::Null, "{name}");
        assert!(!fixture.artifacts.join(&id).exists(), "{name}");
    }
}
