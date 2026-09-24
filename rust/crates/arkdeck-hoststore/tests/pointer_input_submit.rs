//! Replays the submissions of the Swift pointer-input oracle
//! (`rust/tests/fixtures/pointer-input`, recorded by
//! `PointerInputOracleContractTests` over the shared fake HDC) against the
//! Rust admitter, which issues the Runtime capability each gesture is
//! authorized with. Nothing runs, so the replay covers what depends on
//! admission alone:
//! - every case's plan and submission but `afterUnknown`'s, each answered as
//!   Swift answered it, with the capabilities installed as Swift installed
//!   them and each Job's request and original submission as Swift persisted
//!   them;
//! - `afterUnknown`'s submission over the capability store the oracle left,
//!   whose unresolved use refuses it before anything is issued;
//! - another client's gesture while a control session holds the device.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    AdmissionRefusal, ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter,
    JobPlanner, JobStore, MutationAuthority, TargetStore,
};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use support::{chmod, fixed_now};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";

/// Admission dispatches nothing; a call here fails the replay.
struct NoDispatch;

impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("admission dispatched {:?}", plan.arguments)
    }
}

/// A private scratch root under the canonical temporary directory, with the
/// Target the oracle adopted and the owners' directories. The capability
/// store is made beside the Job state once the Job owner holds it, as the
/// daemon makes it: a new Job repository takes only an empty directory.
fn scratch(fixture: &Path, label: &str) -> PathBuf {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-pointer-submit-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("jobs-state"),
    ] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
    }
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    root
}

/// The control plane's answer: a refusal before the admission point proves
/// zero dispatch.
fn answer(outcome: Result<Value, AdmissionRefusal>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(refusal) => json!({"ok": false, "error": {
            "code": refusal.code,
            "message": refusal.message,
            "details": if refusal.proven {
                json!({"newDispatchCount": 0, "phase": "preAdmission"})
            } else {
                json!({})
            },
        }}),
    }
}

/// The owners one replay admits with.
struct Owners {
    root: PathBuf,
    targets: TargetStore,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    holds: DeviceHolds,
    digest: String,
    default_root: PathBuf,
}

impl Owners {
    fn open(fixture: &Path, label: &str) -> Self {
        let root = scratch(fixture, label);
        Self {
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs: JobStore::open_owner(&root.join("jobs-state")).unwrap(),
            capabilities: CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap(),
            holds: DeviceHolds::default(),
            digest: sha256_hex(&fs::read(fixture.join("hdc")).unwrap()),
            default_root: root.join("jobs-state"),
            root,
        }
    }

    fn hdc(&self) -> HdcComposition<'_> {
        HdcComposition {
            targets: &self.targets,
            dispatch: &NoDispatch,
            receive_root: None,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
            workspace: None,
        }
    }

    fn admitter<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(MutationAuthority {
                default_root: &self.default_root,
                sessions: None,
                capabilities: &self.capabilities,
                holds: &self.holds,
            }),
        }
    }
}

impl Drop for Owners {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn read(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[test]
fn rust_admits_the_swift_gestures_under_the_capabilities_swift_issued() {
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture, "admit");
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let mut differences = Vec::new();
    let mut submissions = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        // A run's unknown outcome is what refuses `afterUnknown`.
        if name.starts_with("afterUnknown.") {
            continue;
        }
        let params = exchange["params"].as_object().unwrap();
        let actual = match exchange["method"].as_str().unwrap() {
            "job.plan" => answer(
                owners
                    .planner(&hdc)
                    .handle(params)
                    .map_err(AdmissionRefusal::from),
            ),
            "job.submit" => {
                submissions += 1;
                answer(admitter.handle(params))
            }
            _ => continue,
        };
        let actual = support::legacy_plan_answer(actual);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                exchange["answer"]
            ));
        }
    }
    assert_eq!(submissions, 7, "every submission but afterUnknown's");
    // The capabilities Swift issued at those submissions, in install order;
    // their uses came with the runs this replay does not make.
    let envelopes = |document: &Value| -> Vec<Value> {
        document["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|record| record["capability"].clone())
            .collect()
    };
    let issued = read(&owners.root.join("jobs-state/capabilities").join(CHECKPOINT));
    let swift = read(&fixture.join("store/capabilities").join(CHECKPOINT));
    if envelopes(&issued) != envelopes(&swift) {
        differences.push(format!(
            "capabilities:\n  swift {}\n  rust  {}",
            json!(envelopes(&swift)),
            json!(envelopes(&issued))
        ));
    }
    assert!(
        issued["records"]
            .as_array()
            .unwrap()
            .iter()
            .all(|record| record["consumptions"] == json!([])),
        "admission consumes no use"
    );
    // Each Job runs the request naming its capability; the caller's own is
    // its original submission.
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let job = job.as_str().unwrap();
        let ours = read(
            &owners
                .root
                .join("jobs-state/jobs")
                .join(job)
                .join("job-record.json"),
        );
        let swift = read(&fixture.join("store/jobs").join(job).join("job-record.json"));
        for member in [
            "request",
            "originalSubmissionRequest",
            "operationReference",
            "catalogDigest",
            "actualEffect",
            "materializedPlanDigest",
            "materializedStableTargetIdentitySHA256",
            "materializedBindingRevision",
        ] {
            if ours[member] != swift[member] {
                differences.push(format!(
                    "{case} {member}:\n  swift {}\n  rust  {}",
                    swift[member], ours[member]
                ));
            }
        }
        assert!(
            ours.get("admissionEvidence").is_none(),
            "{case}: no use is consumed at admission"
        );
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

#[test]
fn a_gesture_after_an_unknown_outcome_is_refused_before_anything_is_issued() {
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture, "unknown");
    // The capability store as the oracle left it: use 3 of the tap's
    // capability ended with an unknown outcome.
    let store = owners.root.join("jobs-state/capabilities");
    for name in [CHECKPOINT, LEDGER] {
        fs::copy(
            fixture.join("store/capabilities").join(name),
            store.join(name),
        )
        .unwrap();
        chmod(&store.join(name), 0o600);
    }
    let hdc = owners.hdc();
    let exchange = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "afterUnknown.submit")
        .unwrap();
    assert_eq!(
        answer(
            owners
                .admitter(&hdc)
                .handle(exchange["params"].as_object().unwrap())
        ),
        exchange["answer"]
    );
    for name in [CHECKPOINT, LEDGER] {
        assert_eq!(
            fs::read(store.join(name)).unwrap(),
            fs::read(fixture.join("store/capabilities").join(name)).unwrap(),
            "{name} is untouched"
        );
    }
    assert!(
        !owners.root.join("jobs-state/jobs").exists()
            || fs::read_dir(owners.root.join("jobs-state/jobs"))
                .unwrap()
                .next()
                .is_none(),
        "no Job is admitted"
    );
}

#[test]
fn another_client_is_refused_while_a_control_session_holds_the_device() {
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture, "hold");
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let tap = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "tap.submit")
        .unwrap()["params"]["requestJson"]
        .as_str()
        .unwrap()
        .to_owned();
    let submit = |client: &str, key: &str| {
        let mut request: Value = serde_json::from_str(&tap).unwrap();
        request["idempotencyKey"] = json!(key);
        request["requestId"] = json!(format!("req-{key}"));
        request["clientContext"] = json!({"clientName": client});
        let params = json!({"requestJson": request.to_string()});
        answer(admitter.handle(params.as_object().unwrap()))
    };
    assert_eq!(submit("first", "idem-first-1")["ok"], true);
    assert_eq!(
        submit("second", "idem-second-1"),
        json!({"ok": false, "error": {
            "code": "resourceConflict",
            "message": "a control session opened by first holds this device since \
                        2026-09-14T00:00:00Z; it was not queued behind that session",
            "details": {"newDispatchCount": 0, "phase": "preAdmission"},
        }})
    );
    // The session's own client goes on, under the same capability.
    assert_eq!(submit("first", "idem-first-2")["ok"], true);
    let issued = read(&owners.root.join("jobs-state/capabilities").join(CHECKPOINT));
    assert_eq!(issued["records"].as_array().unwrap().len(), 1);
}

#[test]
fn selected_state_root_override_cannot_issue_mutation_authority() {
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let mut owners = Owners::open(&fixture, "override-refused");
    owners.default_root = owners.root.join("fixed-installed-runtime-root");
    let hdc = owners.hdc();
    let params = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == "tap.submit")
        .unwrap()["params"]
        .as_object()
        .unwrap();
    let refusal = owners.admitter(&hdc).handle(params).unwrap_err();
    assert_eq!(refusal.code, "admissionDenied");
    assert!(
        !owners
            .root
            .join("jobs-state/capabilities/runtime-capabilities.json")
            .exists()
    );
    assert!(
        !owners
            .root
            .join("jobs-state/capabilities/runtime-capabilities.ledger")
            .exists()
    );
}
