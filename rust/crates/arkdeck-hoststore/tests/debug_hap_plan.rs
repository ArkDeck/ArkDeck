//! Exact replay of native DebugHapOracleContractTests plans. Fixture data
//! is isolated host evidence, never a real-device acceptance result.
#![cfg(target_os = "macos")]
mod support;
use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactReadStore, CapabilityStore, DeviceHolds, HdcComposition, JobAdmitter, JobPlanner,
    JobStore, MutationAuthority, TargetStore,
};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::json;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{chmod, fixed_now};
struct NoDispatch;
impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("plan/admission dispatched {:?}", plan.arguments)
    }
}
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// Serializes every user of the fixed root, Swift producers included.
pub fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    // The Artifacts the oracle published before any request, as a Job
    // publishes them: each payload sealed, its index owner-only.
    for input in fs::read_dir(fixture.join("artifacts"))
        .into_iter()
        .flatten()
    {
        let input = input.unwrap().path();
        let name = input.file_name().unwrap().to_owned();
        if !name.to_string_lossy().starts_with("job-input-") {
            continue;
        }
        let destination = root.join("artifacts").join(&name);
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(&input).unwrap() {
            let file = file.unwrap().path();
            let file_name = file.file_name().unwrap();
            fs::copy(&file, destination.join(file_name)).unwrap();
            chmod(
                &destination.join(file_name),
                if file_name == "index.json" {
                    0o600
                } else {
                    0o400
                },
            );
        }
    }
    root
}

#[test]
fn native_swift_plans_match_but_hap_admission_remains_closed() {
    let _lock = exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let root = rebuild(&fixture);
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let capabilities = CapabilityStore::open(&root.join("jobs-state/capabilities")).unwrap();
    let holds = DeviceHolds::default();
    let digest = sha256_hex(&fs::read(fixture.join("hdc")).unwrap());
    let hdc = HdcComposition {
        targets: &targets,
        dispatch: &NoDispatch,
        tool_sha256: &digest,
        now: fixed_now,
    };
    let planner = || JobPlanner {
        artifacts: Some(&artifacts),
        imports: None,
        analyzer: None,
        state_root: &root,
        hdc: Some(&hdc),
    };
    let admitter = JobAdmitter {
        planner: planner(),
        jobs: &jobs,
        now: fixed_now,
        authority: Some(MutationAuthority {
            capabilities: &capabilities,
            holds: &holds,
        }),
    };
    let before = tree_bytes(&root.join("jobs-state"));
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
                let refused = admitter.handle(params).unwrap_err();
                assert_eq!(refused.code, "rejected");
                assert_eq!(
                    refused.message,
                    "debug.hap@1 is not materialized by the Rust Runtime yet"
                );
                assert_eq!(
                    tree_bytes(&root.join("jobs-state")),
                    before,
                    "submit must not write Jobs, capabilities or reservations"
                );
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
        assert_eq!(tree_bytes(&root.join("jobs-state")), before, "{name}");
    }
    assert_eq!((count, positive), (13, 8));
    assert!(
        fs::read(root.join("hdc-invocations.log"))
            .unwrap()
            .is_empty()
    );
}

fn tree_bytes(root: &Path) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
    fn visit(root: &Path, path: &Path, out: &mut std::collections::BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                visit(root, &path, out);
            } else {
                out.insert(
                    path.strip_prefix(root).unwrap().to_owned(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut out = std::collections::BTreeMap::new();
    visit(root, root, &mut out);
    out
}

#[test]
fn entry_and_additional_imports_are_held_until_success_or_preflight_refusal() {
    use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk};
    use arkdeck_hoststore::{ImportBinding, ImportUploadFault, ImportUploadStore};
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
    let _lock = exclusive();
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
    for should_succeed in [true, false] {
        let root = rebuild(&fixture);
        let targets = TargetStore::open(&root.join("targets-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        let digest = sha256_hex(&fs::read(fixture.join("hdc")).unwrap());
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &NoDispatch,
            tool_sha256: &digest,
            now: fixed_now,
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
        let binding = |intent: &ImportIntent| -> Result<ImportBinding, WireError> {
            Ok(ImportBinding {
                target_id: intent.target_id.clone(),
                binding_revision: target["bindingRevision"].as_u64(),
                stable_identity_sha256: Some(
                    target["stablePhysicalIdentitySHA256"]
                        .as_str()
                        .unwrap()
                        .into(),
                ),
            })
        };
        let now = fixed_now().unwrap();
        let mut receipts = Vec::new();
        for name in ["entry", "additional"] {
            // Deliberate structural HAP fixture, not a signed application or hardware evidence.
            let bytes = format!("PK\u{3}\u{4}isolated-{name}").into_bytes();
            let begin = imports.handle_resource("artifact.import.begin", json!({
                "schemaVersion": "arkdeck.import-intent/1", "importRequestId": format!("hap-hold-{name}"),
                "kind": "hap", "targetId": target["targetID"], "bindingRevision": "1", "deviceProfile": null,
                "name": format!("{name}.hap"), "byteCount": bytes.len().to_string(), "sha256": sha256_hex(&bytes)
            }).as_object().unwrap(), &now, false, binding).unwrap();
            let id = begin["importId"].as_str().unwrap();
            imports.handle_resource("artifact.import.append", json!({"importId": id, "generation": "1", "offset": "0",
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(&bytes), "base64": encode_import_chunk(&bytes).unwrap()
            }).as_object().unwrap(), &now, false, binding).unwrap();
            receipts.push(
                imports
                    .commit(
                        json!({"importId": id, "generation": "1"})
                            .as_object()
                            .unwrap(),
                        &now,
                        false,
                        &artifacts,
                        1024 * 1024,
                        binding,
                    )
                    .unwrap(),
            );
        }
        let mut request = original.clone();
        request["inputs"]["hapArtifactLease"] = receipts[0]["receipt"]["lease"].clone();
        let additional = receipts[1]["receipt"]["lease"].clone();
        request["inputs"]["additionalHapArtifactLeases"] = if should_succeed {
            json!([additional])
        } else {
            json!([additional.clone(), additional])
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
            assert_eq!(result.is_ok(), should_succeed, "{result:?}");
        });
        for receipt in &receipts {
            let id = &receipt["importId"];
            assert_eq!(
                lifecycle("inspection", json!({"importId": id})).unwrap()["references"]["activeMaterializationCount"],
                "0"
            );
            lifecycle("release", json!({"importId": id, "generation": "2"})).unwrap();
        }
        assert!(
            fs::read(root.join("hdc-invocations.log"))
                .unwrap()
                .is_empty()
        );
    }
}
