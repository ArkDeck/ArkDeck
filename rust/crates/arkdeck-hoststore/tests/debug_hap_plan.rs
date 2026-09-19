//! Exact replay of native DebugHapOracleContractTests plans. Fixture data
//! is isolated host evidence, never a real-device acceptance result. The
//! submissions of the same oracle are replayed by `debug_hap_submit.rs`.
#![cfg(target_os = "macos")]
mod support;
use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{ArtifactReadStore, HdcComposition, JobPlanner, JobStore, TargetStore};
use serde_json::json;
use std::fs;
use support::debug_hap::{self, NoDispatch};
use support::fixed_now;

#[test]
fn native_swift_plans_match_with_nothing_admitted_or_dispatched() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let root = debug_hap::rebuild(&fixture);
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
    let planner = || JobPlanner {
        artifacts: Some(&artifacts),
        imports: None,
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
    };
    let mut count = 0;
    let mut positive = 0;
    for exchange in cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["method"] == "job.plan")
    {
        count += 1;
        let params = exchange["params"].as_object().unwrap();
        let actual = match planner().handle(params) {
            Ok(result) => {
                positive += 1;
                json!({"ok": true, "result": result})
            }
            Err(refusal) => {
                json!({"ok": false, "error": {"code": refusal.code, "message": refusal.message,
                "details": {"newDispatchCount": 0, "phase": "preAdmission"}}})
            }
        };
        assert_eq!(actual, exchange["answer"], "{}", exchange["name"]);
    }
    let valid = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["method"] == "job.plan" && row["answer"]["ok"] == true)
        .unwrap();
    let original: serde_json::Value =
        serde_json::from_str(valid["params"]["requestJson"].as_str().unwrap()).unwrap();
    let lease = original["inputs"]["hapArtifactLease"].clone();
    for (name, additional) in [
        ("duplicate entry package", json!([lease.clone()])),
        ("above package set bound", json!(vec![lease.clone(); 17])),
        ("malformed additional lease", json!([42])),
        (
            "unresolved additional package",
            json!(["lease-v1:job-missing:ART-00000000000000000000000000000000"]),
        ),
    ] {
        let mut request = original.clone();
        request["inputs"]["additionalHapArtifactLeases"] = additional;
        let refusal = planner()
            .plan(&serde_json::to_vec(&request).unwrap())
            .unwrap_err();
        assert!(
            matches!(refusal.code, "invalidInput" | "rejected"),
            "{name}: {refusal:?}"
        );
    }
    assert_eq!((count, positive), (15, 10));
    // A plan admits no Job, installs no capability and dispatches nothing.
    assert!(debug_hap::tree_bytes(&root.join("store")).is_empty());
    assert!(debug_hap::invocations(&root).is_empty());
}

#[test]
fn entry_and_additional_imports_are_held_until_success_or_preflight_refusal() {
    use arkdeck_hoststore::{ImportUploadFault, ImportUploadStore};
    use std::sync::{
        Arc, Mutex,
        mpsc::{SyncSender, sync_channel},
    };
    use std::time::Duration;
    const WAIT: Duration = Duration::from_secs(10);
    struct ResumeOnDrop(SyncSender<()>);
    impl Drop for ResumeOnDrop {
        fn drop(&mut self) {
            let _ = self.0.try_send(());
        }
    }
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let valid = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["method"] == "job.plan" && row["answer"]["ok"] == true)
        .unwrap();
    let original: serde_json::Value =
        serde_json::from_str(valid["params"]["requestJson"].as_str().unwrap()).unwrap();
    for scenario in ["success", "duplicate", "target", "revision", "identity"] {
        let should_succeed = scenario == "success";
        let root = debug_hap::rebuild(&fixture);
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("store")).unwrap();
        let digest = sha256_hex(&fs::read(fixture.join("hdc")).unwrap());
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &NoDispatch,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let (entered_tx, entered) = sync_channel(1);
        let (resume, resume_rx) = sync_channel(1);
        let resume_rx = Mutex::new(resume_rx);
        let imports = ImportUploadStore::open_with_fault(
            &root.join("artifacts"),
            Arc::new(move |point| {
                if point == ImportUploadFault::AfterInputHold {
                    entered_tx.try_send(()).map_err(std::io::Error::other)?;
                    resume_rx
                        .lock()
                        .map_err(|_| std::io::Error::other("poisoned test handoff"))?
                        .recv_timeout(WAIT)
                        .map_err(std::io::Error::other)?;
                }
                Ok(())
            }),
        )
        .unwrap();
        let target =
            support::document(&fixture.join("targets-state"), "targets.json")["targets"][0].clone();
        let now = fixed_now().unwrap();
        let mut receipts = Vec::new();
        for name in ["entry", "additional"] {
            let mismatch = name == "additional";
            let target_id = if mismatch && scenario == "target" {
                "TGT-fixture-other"
            } else {
                target["targetID"].as_str().unwrap()
            };
            let revision = if mismatch && scenario == "revision" {
                2
            } else {
                1
            };
            let identity = if mismatch && scenario == "identity" {
                "b".repeat(64)
            } else {
                target["stablePhysicalIdentitySHA256"]
                    .as_str()
                    .unwrap()
                    .into()
            };
            receipts.push(debug_hap::import_package(
                &imports, &artifacts, name, target_id, revision, &identity, &now,
            ));
        }
        let mut request = original.clone();
        request["inputs"]["hapArtifactLease"] = receipts[0]["receipt"]["lease"].clone();
        let additional = receipts[1]["receipt"]["lease"].clone();
        request["inputs"]["additionalHapArtifactLeases"] = if scenario == "duplicate" {
            json!([additional.clone(), additional])
        } else {
            json!([additional])
        };
        let request = serde_json::to_vec(&request).unwrap();
        let lifecycle = |verb: &str, fields: serde_json::Value| {
            imports.lifecycle_resource(
                &artifacts,
                &jobs,
                &format!("artifact.import.{verb}"),
                fields.as_object().unwrap(),
                &now,
            )
        };
        std::thread::scope(|scope| {
            // Declared inside scope, so an assertion panic unblocks the worker before join.
            let guard = ResumeOnDrop(resume);
            let planner = JobPlanner {
                artifacts: Some(&artifacts),
                imports: Some(&imports),
                analyzer: None,
                state_root: &root,
                hdc: Some(&hdc),
            };
            let worker = scope.spawn(move || planner.plan(&request));
            entered
                .recv_timeout(WAIT)
                .expect("planner did not reach its complete Import hold");
            for receipt in &receipts {
                let id = &receipt["importId"];
                let inspected = lifecycle("inspection", json!({"importId": id})).unwrap();
                assert_eq!(inspected["references"]["activeMaterializationCount"], "1");
                assert_eq!(
                    lifecycle("release", json!({"importId": id, "generation": "2"}))
                        .unwrap_err()
                        .code,
                    "resourceConflict"
                );
            }
            drop(guard);
            let result = worker.join().unwrap();
            assert_eq!(result.is_ok(), should_succeed, "{scenario}: {result:?}");
            if matches!(scenario, "target" | "revision" | "identity") {
                let refused = result.unwrap_err();
                assert_eq!(refused.code, "invalidInput");
                assert!(
                    refused
                        .message
                        .starts_with("additional HAP Artifact lease is not resolvable:")
                );
                assert!(refused.message.contains(
                    "Artifact lease target/binding/identity does not match the materialized request"
                ));
            }
        });
        for receipt in &receipts {
            let id = &receipt["importId"];
            assert_eq!(
                lifecycle("inspection", json!({"importId": id})).unwrap()["references"]["activeMaterializationCount"],
                "0"
            );
            lifecycle("release", json!({"importId": id, "generation": "2"})).unwrap();
        }
        assert!(debug_hap::invocations(&root).is_empty());
    }
}
