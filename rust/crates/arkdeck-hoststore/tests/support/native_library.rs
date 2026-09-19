//! What the replays of the Swift native-library oracle share
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC at its fixed
//! root): the code-sign helper composed as the oracle composed it, an Import
//! of the oracle's library, and the control plane's answers. The owners a
//! daemon composes over that root, with the helper, are `hdc_oracle`'s.
use super::document;
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{AdmissionRefusal, ArtifactReadStore, ImportBinding, ImportUploadStore};
use arkdeck_provider_hdc::{CodeSignHelper, CodeSignHelperFacts, NativeAbi};
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

pub const FIXTURE: &str = "deploy-native-library";

/// The code-sign helper the oracle composed its provider with: the arm64
/// helper's facts as `cases.json` records them, at the fixed host path its
/// argv names below the root. Its bytes are not in the fixture; the fake
/// never reads them.
pub fn code_sign_helper(cases: &Value, root: &Path) -> CodeSignHelper {
    let recorded = &cases["codeSignHelper"];
    let host_path = root.join("host/arkdeck-code-sign-enable");
    assert_eq!(
        recorded["path"],
        host_path.to_str().unwrap(),
        "the helper path the oracle's argv names"
    );
    CodeSignHelper {
        facts: CodeSignHelperFacts {
            abi: NativeAbi::Arm64,
            build_id: recorded["buildId"].as_str().unwrap().to_owned(),
            sha256: recorded["sha256"].as_str().unwrap().to_owned(),
            byte_count: recorded["byteCount"].as_i64().unwrap(),
        },
        host_path,
    }
}

/// The oracle's library imported under `request_id` (`begin`, one `append`,
/// `commit`) as bound to one Target binding, as GJ-3 hands a library to the
/// Runtime: the commit's answer, whose receipt names its lease. The bytes are
/// the oracle's structural fixture, never a library a device loaded.
pub fn import_library(
    imports: &ImportUploadStore,
    artifacts: &ArtifactReadStore,
    fixture: &Path,
    request_id: &str,
    target: &Value,
    now: &str,
) -> Value {
    let cases = document(fixture, "cases.json");
    let lease = cases["lease"].as_str().unwrap();
    let (job, artifact) = lease
        .strip_prefix("lease-v1:")
        .and_then(|rest| rest.split_once(':'))
        .unwrap();
    let bytes = fs::read(fixture.join("artifacts").join(job).join(artifact)).unwrap();
    let target_id = target["targetID"].as_str().unwrap().to_owned();
    let identity = target["stablePhysicalIdentitySHA256"]
        .as_str()
        .unwrap()
        .to_owned();
    let binding = |intent: &ImportIntent| -> Result<ImportBinding, WireError> {
        Ok(ImportBinding {
            target_id: intent.target_id.clone(),
            binding_revision: Some(1),
            stable_identity_sha256: Some(identity.clone()),
        })
    };
    let begin = imports
        .handle_resource(
            "artifact.import.begin",
            json!({"schemaVersion": "arkdeck.import-intent/1",
                "importRequestId": request_id, "kind": "native-library",
                "targetId": target_id, "bindingRevision": "1", "deviceProfile": null,
                "name": "libexample.so", "byteCount": bytes.len().to_string(),
                "sha256": sha256_hex(&bytes)})
            .as_object()
            .unwrap(),
            now,
            false,
            binding,
        )
        .unwrap();
    let id = begin["importId"].as_str().unwrap();
    imports
        .handle_resource(
            "artifact.import.append",
            json!({"importId": id, "generation": "1", "offset": "0",
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(&bytes),
                "base64": encode_import_chunk(&bytes).unwrap()})
            .as_object()
            .unwrap(),
            now,
            false,
            binding,
        )
        .unwrap();
    imports
        .commit(
            json!({"importId": id, "generation": "1"})
                .as_object()
                .unwrap(),
            now,
            false,
            artifacts,
            1024 * 1024,
            binding,
        )
        .unwrap()
}

/// The zero-dispatch proof of a refusal before the admission point.
pub fn proof() -> Value {
    json!({"newDispatchCount": 0, "phase": "preAdmission"})
}

/// The control plane's answer to a plan or a submission.
pub fn answer(outcome: Result<Value, AdmissionRefusal>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(refusal) => json!({"ok": false, "error": {
            "code": refusal.code,
            "message": refusal.message,
            "details": if refusal.proven { proof() } else { json!({}) },
        }}),
    }
}
