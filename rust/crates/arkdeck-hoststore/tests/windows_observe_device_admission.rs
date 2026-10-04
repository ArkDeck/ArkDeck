//! The Swift `observe.device@1` oracle's `job.plan` and `job.submit`
//! exchanges (`rust/tests/fixtures/observe-device`, produced by
//! `ObserveDeviceOracleContractTests`) replayed on Windows against the Rust
//! planner and admitter, built as the macOS replay (`observe_device.rs`)
//! builds them: over the Target document Swift's adoption wrote, the
//! Artifact and Job owners, and an HDC composition naming the recorded
//! executable's digest, at the oracle's clock.
//!
//! Planning and admission read the Target's facts and dispatch nothing, so
//! the composition's dispatcher is one that refuses to be called: a call
//! fails the test. Every answer's code, details and result must be Swift's
//! (T0: the materialized plan digests, request fingerprints and Job
//! identities included); a refusal's message is Swift's wording (T2) and is
//! not compared, as on macOS. The runs, results and Artifacts of the oracle
//! need the executor and the Session owner on Windows and are not replayed
//! here.
//!
//! This is a host test of the planner and the admitter only. The Windows
//! daemon composes the HDC provider only beside a managed registered HDC;
//! without one, these requests are refused before admission.
#![cfg(windows)]

use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobStore, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::fs;
use std::path::{Path, PathBuf};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/observe-device")
}

fn document(name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture().join(name)).unwrap()).unwrap()
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

/// A dispatcher planning and admission must never reach.
struct NoDispatch;
impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("planning or admission dispatched {:?}", plan.arguments)
    }
}

/// A fresh owner-only root below the temporary directory, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("ad-winobserve-{nonce:016x}"));
        HostDirectory::open_or_create_private(&path).unwrap();
        for owner in ["targets-state", "artifacts", "jobs-state"] {
            HostDirectory::open_or_create_private(&path.join(owner)).unwrap();
        }
        // Owner-only, as the Target owner requires: it inherits the
        // directory's descriptor.
        fs::write(
            path.join("targets-state/targets.json"),
            fs::read(fixture().join("targets-state/targets.json")).unwrap(),
        )
        .unwrap();
        Self(path)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn refused(code: &str, details: Map<String, Value>) -> Value {
    json!({"ok": false, "error": {"code": code, "details": details}})
}

fn proven() -> Map<String, Value> {
    Map::from_iter([
        ("phase".into(), json!("preAdmission")),
        ("newDispatchCount".into(), json!(0)),
    ])
}

/// The answer without a refusal's message, which is Swift's wording (T2).
fn semantic(answer: &Value) -> Value {
    let mut answer = answer.clone();
    if let Some(error) = answer.get_mut("error").and_then(Value::as_object_mut) {
        error.remove("message");
    }
    answer
}

/// A plan as the oracle recorded it: the one field the Rust planner adds
/// since (`stepSetDigestSHA256`, `support::legacy_plan_answer` on macOS),
/// checked against the published `job.plan` result schema and removed.
fn recorded_plan(mut result: Value) -> Value {
    arkdeck_contract::validate_method_value("job.plan", "result", &result).unwrap();
    assert!(
        result
            .as_object_mut()
            .unwrap()
            .remove("stepSetDigestSHA256")
            .is_some_and(|digest| digest.as_str().is_some_and(|digest| digest.len() == 64)),
        "{result}"
    );
    result
}

#[test]
fn rust_plans_and_admits_the_swift_observe_device_requests() {
    let provenance = document("provenance.json");
    let cases = document("cases.json");
    let root = Root::new();
    let targets = TargetStore::open(&root.0.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
    let digest = provenance["hdcSHA256"].as_str().unwrap();
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &NoDispatch,
        receive_root: None,
        tool_sha256: digest,
        now: fixed_now,
        code_sign_helper: None,
    };
    let planner = || JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root.0,
        hdc: Some(&hdc),
        workspace: None,
    };
    let (mut replayed, mut differences) = (0, Vec::new());
    for exchange in cases["exchanges"].as_array().unwrap() {
        let (name, method) = (&exchange["name"], exchange["method"].as_str().unwrap());
        let params = exchange["params"].as_object().unwrap();
        let actual = match method {
            "job.plan" => match planner().handle(params) {
                Ok(result) => json!({"ok": true, "result": recorded_plan(result)}),
                Err(refusal) => refused(refusal.code, proven()),
            },
            "job.submit" => match (JobAdmitter {
                planner: planner(),
                jobs: &jobs,
                now: fixed_now,
                authority: None,
            })
            .handle(params)
            {
                Ok(result) => json!({"ok": true, "result": result}),
                Err(refusal) => refused(
                    refusal.code,
                    if refusal.proven { proven() } else { Map::new() },
                ),
            },
            _ => continue,
        };
        replayed += 1;
        if actual != semantic(&exchange["answer"]) {
            differences.push(format!(
                "{name}:\n  swift {}\n  rust  {actual}",
                semantic(&exchange["answer"])
            ));
        }
    }
    assert!(
        differences.is_empty(),
        "{} of {replayed} differ:\n{}",
        differences.len(),
        differences.join("\n")
    );
    // Four plans and submissions, three plans refused before admission.
    assert_eq!(replayed, 11);
    // The four admitted Jobs wait in `preflight`, as Swift admitted them,
    // and a retry of the first is answered with it.
    let listed = jobs.handle_resource("job.list", &Map::new()).unwrap();
    assert_eq!(listed["items"].as_array().unwrap().len(), 4, "{listed}");
    let first = &cases["exchanges"][1];
    let retry = (JobAdmitter {
        planner: planner(),
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    })
    .handle(first["params"].as_object().unwrap())
    .unwrap();
    assert_eq!(retry["jobId"], first["answer"]["result"]["jobId"]);
    assert_eq!(retry["deduplicated"], true);
}

#[test]
fn without_an_hdc_provider_every_request_is_refused_before_admission() {
    let cases = document("cases.json");
    let root = Root::new();
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
    // The Windows daemon's composition: no HDC provider.
    let planner = || JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root.0,
        hdc: None,
        workspace: None,
    };
    for exchange in cases["exchanges"].as_array().unwrap() {
        let params = exchange["params"].as_object().unwrap();
        let refusal = match exchange["method"].as_str().unwrap() {
            "job.plan" => planner().handle(params).unwrap_err(),
            "job.submit" => {
                let refusal = (JobAdmitter {
                    planner: planner(),
                    jobs: &jobs,
                    now: fixed_now,
                    authority: None,
                })
                .handle(params)
                .unwrap_err();
                assert!(refusal.proven, "{refusal:?}");
                arkdeck_hoststore::PlanRefusal {
                    code: refusal.code,
                    message: refusal.message,
                    swift: None,
                }
            }
            _ => continue,
        };
        assert_eq!(refusal.code, "invalidInput", "{refusal:?}");
        assert_eq!(refusal.message, "provider hdc is not registered");
    }
    let listed = jobs.handle_resource("job.list", &Map::new()).unwrap();
    assert_eq!(listed["items"], json!([]), "{listed}");
    // No Job directory was created.
    let jobs_directory = root.0.join("jobs-state").join("jobs");
    assert!(
        !jobs_directory.exists() || fs::read_dir(&jobs_directory).unwrap().next().is_none(),
        "a Job directory was created"
    );
}
