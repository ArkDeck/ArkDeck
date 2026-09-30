//! `artifact.export` of a sensitive Artifact without `allowSensitive`, on
//! macOS and Windows: the Artifact owner refuses it `sensitiveAccessDenied`
//! (phase `artifactOwner`, no new dispatch), as Swift's
//! `RuntimeArtifactResourceHandler` did (#1663), and the published contract
//! admits that refusal, so the control layer no longer replaces it with
//! `internalError` "the result does not conform to the current contract".
//! With the permission the same Artifact is exported and the receipt
//! conforms. Nothing is written by the refusal.
//!
//! The Artifacts are a `capture.diagnostics@1` Job the macOS Runtime
//! recorded (`rust/tests/fixtures/capture-diagnostics-trace`): its Trace is
//! sensitive, its summary standard.
#![cfg(any(target_os = "macos", windows))]

mod fixture_fs;

use arkdeck_contract::{WireError, validate_method_value};
use arkdeck_hoststore::ArtifactReadStore;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

const JOB: &str = "job-1c209bf5f7b1537cbd2406f5640e0ab8";
const TRACE: &str = "ART-148c3168fc02b640a96d452463b2a8d7";
const SUMMARY: &str = "ART-254a229f7471f2bbe3d18b818b1fb8d1";

fn recorded() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/capture-diagnostics-trace/artifacts")
        .join(JOB)
}

/// A recorded Artifact index with each retention deadline a century later.
fn unexpired(bytes: &[u8]) -> Vec<u8> {
    let mut index: Value = serde_json::from_slice(bytes).unwrap();
    for row in index["artifacts"].as_array_mut().unwrap() {
        if let Some(deadline) = row["retention"]["deadlineUTC"].as_str() {
            let (year, rest) = deadline.split_at(4);
            let later = format!("{}{rest}", year.parse::<u32>().unwrap() + 100);
            row["retention"]["deadlineUTC"] = json!(later);
        }
    }
    serde_json::to_vec_pretty(&index).unwrap()
}

/// The recorded Job's Artifacts as the Runtime published them: a private
/// Artifact root and Job directory, the index owner-only, each payload
/// sealed; and an ordinary export destination beside them.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let root = fixture_fs::temporary_root().join(format!("export-sensitive-{nonce:016x}"));
        std::fs::create_dir(&root).unwrap();
        let artifacts = root.join("artifacts");
        fixture_fs::private_dir(&artifacts);
        let job = artifacts.join(JOB);
        fixture_fs::private_dir(&job);
        for entry in std::fs::read_dir(recorded()).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            let bytes = std::fs::read(recorded().join(&name)).unwrap();
            if name == "index.json" {
                std::fs::write(job.join(&name), unexpired(&bytes)).unwrap();
                fixture_fs::owner_only(&job.join(&name));
            } else {
                std::fs::write(job.join(&name), &bytes).unwrap();
                fixture_fs::owner_only(&job.join(&name));
                fixture_fs::rewrite_sealed(&job.join(&name), &bytes);
            }
        }
        std::fs::create_dir(root.join("exports")).unwrap();
        Self(root)
    }
    fn store(&self) -> ArtifactReadStore {
        ArtifactReadStore::open(&self.0.join("artifacts")).unwrap()
    }
    fn exports(&self) -> PathBuf {
        self.0.join("exports")
    }
    fn export(&self, artifact: &str, allow_sensitive: Option<bool>) -> Result<Value, WireError> {
        let mut params = Map::from_iter([
            ("owner".into(), json!({"kind": "job", "id": JOB})),
            ("artifactId".into(), json!(artifact)),
            (
                "destinationDirectory".into(),
                json!(self.exports().to_str().unwrap()),
            ),
        ]);
        if let Some(allow) = allow_sensitive {
            params.insert("allowSensitive".into(), json!(allow));
        }
        self.store()
            .handle_resource("artifact.export", &params, |_| Ok(()))
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// check-contracts' published view compiles this build against the merge
/// base's contract, which does not publish the code yet.
fn published_view_without_the_code() -> bool {
    let inputs =
        arkdeck_contract::strict_json(arkdeck_contract::CONTRACT_INPUTS.as_bytes()).unwrap();
    inputs["kind"] == "development"
        && inputs.get("commit").is_some()
        && validate_method_value(
            "artifact.export",
            "errorCode",
            &json!("sensitiveAccessDenied"),
        )
        .is_err()
}

#[test]
fn a_sensitive_export_without_permission_is_refused_as_the_contract_publishes() {
    let root = Root::new();
    let published_view = published_view_without_the_code();
    for allow in [None, Some(false)] {
        let refusal = root.export(TRACE, allow).unwrap_err();
        assert_eq!(refusal.code, "sensitiveAccessDenied", "{refusal:?}");
        let details = Value::Object(refusal.details.clone().unwrap());
        assert_eq!(
            details,
            json!({"phase": "artifactOwner", "newDispatchCount": 0})
        );
        if !published_view {
            validate_method_value("artifact.export", "errorCode", &json!(refusal.code)).unwrap();
        }
        validate_method_value("artifact.export", "errorDetails", &details).unwrap();
        assert_eq!(
            std::fs::read_dir(root.exports()).unwrap().count(),
            0,
            "nothing was exported"
        );
    }
    // With the permission the Trace is exported, and so is the standard
    // summary without it; both receipts conform.
    for (artifact, allow) in [(TRACE, Some(true)), (SUMMARY, None)] {
        let receipt = root.export(artifact, allow).unwrap();
        validate_method_value("artifact.export", "result", &receipt).unwrap();
        assert_eq!(
            std::fs::read(receipt["exportedPath"].as_str().unwrap()).unwrap(),
            std::fs::read(recorded().join(artifact)).unwrap()
        );
    }
}
