//! What the replays of the Swift native-library oracle share
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC at its fixed
//! root): the root rebuilt as the oracle found it before its first request,
//! with the library it published; the code-sign helper composed as the oracle
//! composed it; and the owners a daemon composes over that root, the Job
//! owner's root being the account-fixed one its mutation authority names.
use super::debug_hap;
use super::{document, fixed_now};
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{
    AdmissionRefusal, ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition,
    ImportBinding, ImportUploadStore, JobAdmitter, JobPlanner, JobStore, MutationAuthority,
    TargetStore,
};
use arkdeck_provider_hdc::{CodeSignHelper, CodeSignHelperFacts, HdcDispatch, NativeAbi};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

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

pub fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// The owners one replay plans and admits with, over the rebuilt root. The
/// capability store is opened inside the Job root once the Job owner holds
/// it, as the daemon opens it (a new Job repository takes only an empty
/// directory).
pub struct Owners {
    pub root: PathBuf,
    pub store: PathBuf,
    pub digest: String,
    pub targets: TargetStore,
    pub artifacts: ArtifactReadStore,
    pub jobs: JobStore,
    pub capabilities: CapabilityStore,
    pub holds: DeviceHolds,
    pub helper: CodeSignHelper,
}

impl Owners {
    /// The owners over the root rebuilt from `fixture`; the caller holds
    /// [`debug_hap::exclusive`].
    pub fn open(fixture: &Path) -> Self {
        let cases = document(fixture, "cases.json");
        let provenance = document(fixture, "provenance.json");
        let root = debug_hap::rebuild(fixture);
        let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
        assert_eq!(provenance["hdcSHA256"], digest.as_str());
        let store = root.join("store");
        let jobs = JobStore::open_owner(&store).unwrap();
        let capabilities = CapabilityStore::open(&store.join("capabilities")).unwrap();
        Self {
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs,
            capabilities,
            holds: DeviceHolds::default(),
            helper: code_sign_helper(&cases, &root),
            digest,
            store,
            root,
        }
    }

    /// The HDC composition over `dispatch`, with the oracle's helper.
    pub fn hdc<'a>(&'a self, dispatch: &'a (dyn HdcDispatch + Sync)) -> HdcComposition<'a> {
        HdcComposition {
            targets: &self.targets,
            dispatch,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: Some(&self.helper),
        }
    }

    pub fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
        }
    }

    /// The Runtime-owned authority over this root's own Job state, which the
    /// mutation state check requires.
    pub fn authority(&self) -> MutationAuthority<'_> {
        MutationAuthority {
            default_root: &self.store,
            sessions: None,
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    pub fn admitter<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority()),
        }
    }
}
