//! Replays the planning half of the Swift pointer-input oracle
//! (`rust/tests/fixtures/pointer-input`, recorded by
//! `PointerInputOracleContractTests` over the shared fake HDC) against the
//! Rust planner. It sends every `job.plan` the oracle sent, over the Target
//! the oracle adopted and at the oracle's clock:
//! - the three gestures;
//! - the plans of the rejected, unknown and blocked cases;
//! - the plans Swift refuses: a stale frame, a point outside the frame, a hold
//!   below the catalog's minimum and a swipe without its duration.
//!
//! Every answer must be Swift's, message included. Planning dispatches
//! nothing.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{ArtifactReadStore, HdcComposition, JobPlanner, TargetStore};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::json;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use support::{chmod, fixed_now};

/// A plan dispatches nothing; a call here fails the replay.
struct NoDispatch;

impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("planning dispatched {:?}", plan.arguments)
    }
}

/// A private scratch root under the canonical temporary directory, with the
/// Target and Artifact owners' directories.
fn scratch() -> PathBuf {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-pointer-plan-{}-{}",
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
    ] {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
    }
    root
}

#[test]
fn rust_plans_the_swift_pointer_gestures() {
    let fixture = support::fixture("pointer-input");
    let cases = support::document(&fixture, "cases.json");
    let root = scratch();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let digest = sha256_hex(&fs::read(fixture.join("hdc")).unwrap());
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &NoDispatch,
        tool_sha256: &digest,
        now: fixed_now,
        code_sign_helper: None,
    };
    let planner = JobPlanner {
        imports: None,
        artifacts: Some(&artifacts),
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
    };
    let mut differences = Vec::new();
    let mut plans = 0;
    for exchange in cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|exchange| exchange["method"] == "job.plan")
    {
        let actual = match planner.handle(exchange["params"].as_object().unwrap()) {
            Ok(result) => json!({"ok": true, "result": result}),
            // The daemon proves that a refused plan dispatched nothing.
            Err(refusal) => json!({"ok": false, "error": {
                "code": refusal.code,
                "message": refusal.message,
                "details": {"newDispatchCount": 0, "phase": "preAdmission"},
            }}),
        };
        plans += 1;
        if actual != exchange["answer"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                exchange["name"], exchange["answer"]
            ));
        }
    }
    let _ = fs::remove_dir_all(&root);
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(plans, 10, "every plan the oracle sent");
}
