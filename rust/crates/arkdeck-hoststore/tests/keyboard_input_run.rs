//! Synthetic host owners only. The fake transport cannot reach a device.
#![cfg(any(target_os = "macos", windows))]
mod support;
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::*;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Map, Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use support::{OracleProbe, fixed_now, fixed_precise_now, fixture_fs};

const TARGET: &str = "TGT-3ba3f5f43b92";
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const PRIVATE_TEXT: &str = "private-fixture-你好-$()-'";
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let root = fixture_fs::temporary_root().join(format!(
            "keyboard-owner-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fixture_fs::private_dir(&root);
        for child in ["artifacts", "targets", "store", "Sessions", "session-owner"] {
            fixture_fs::private_dir(&root.join(child));
        }
        fs::write(
            root.join("targets/targets.json"),
            include_bytes!("../../../tests/fixtures/pointer-input/targets-state/targets.json"),
        )
        .unwrap();
        fixture_fs::owner_only(&root.join("targets/targets.json"));
        Self(root)
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Clone, Copy)]
enum Reply {
    Accepted,
    MissingAck,
    Unobservable,
    Refused,
}
struct Fake {
    reply: Reply,
    keyboard_calls: AtomicUsize,
    calls: Mutex<Vec<Vec<String>>>,
}
impl HdcDispatch for Fake {
    fn mutation_identity_current(&self) -> bool {
        true
    }
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.calls.lock().unwrap().push(plan.arguments.clone());
        let argv: Vec<_> = plan.arguments.iter().map(String::as_str).collect();
        let stdout = match argv.as_slice() {
            ["list", "targets", "-v"] => format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"),
            ["-t", KEY, "shell", "param", "get", "const.product.name"] => {
                "OpenHarmony Reference Device\n".into()
            }
            ["-t", KEY, "shell", "param", "get", "const.ohos.fullname"] => {
                "OpenHarmony-4.1-release\n".into()
            }
            ["-t", KEY, "shell", "uitest", "uiInput", "text", _] => {
                self.keyboard_calls.fetch_add(1, Ordering::SeqCst);
                match self.reply {
                    Reply::Accepted => "No Error\n".into(),
                    Reply::MissingAck => format!("unobserved {PRIVATE_TEXT}"),
                    Reply::Unobservable => {
                        return Err(DispatchFailure::Unobservable(PRIVATE_TEXT.into()));
                    }
                    Reply::Refused => return Err(DispatchFailure::Refused(PRIVATE_TEXT.into())),
                }
            }
            _ => {
                return Err(DispatchFailure::Refused(
                    "unregistered synthetic transport action".into(),
                ));
            }
        };
        Ok(Receipt {
            exit_status: 0,
            stdout: stdout.into_bytes(),
            stderr: vec![],
            truncated: false,
            duration: Duration::ZERO,
        })
    }
}
fn binding(intent: &ImportIntent) -> Result<ImportBinding, WireError> {
    Ok(ImportBinding {
        target_id: intent.target_id.clone(),
        binding_revision: Some(intent.binding_revision),
        stable_identity_sha256: Some(arkdeck_provider_hdc::stable_identity_sha256(KEY)),
    })
}
fn record(method: &str, params: &Value, result: &Value) {
    arkdeck_contract::validate_method_value(method, "request", params).unwrap();
    arkdeck_contract::validate_method_value(method, "result", result).unwrap();
    let Some(root) = std::env::var_os("ARKDECK_KEYBOARD_RECORD") else {
        return;
    };
    static LOCK: Mutex<()> = Mutex::new(());
    let _lock = LOCK.lock().unwrap();
    use std::io::Write;
    fs::create_dir_all(&root).unwrap();
    let frame = json!({"protocolVersion":"1.0.0","method":method,"params":params,"ok":true,"result":result});
    let mut bytes = serde_json::to_vec(&frame).unwrap();
    bytes.push(b'\n');
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(Path::new(&root).join(format!("{method}.jsonl")))
        .unwrap()
        .write_all(&bytes)
        .unwrap();
}
fn import(owner: &ImportUploadStore, artifacts: &ArtifactReadStore) -> Value {
    let bytes =
        serde_json::to_vec(&json!({"kind":"text","text":PRIVATE_TEXT,"allowDeviceClipboard":true}))
            .unwrap();
    let metadata = json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":"keyboard-fixture","kind":"keyboard-input", "targetId":TARGET,"bindingRevision":"1","deviceProfile":null,"name":"keyboard-input.json","byteCount":bytes.len().to_string(),"sha256":sha256_hex(&bytes)});
    let begin = owner
        .handle_resource(
            "artifact.import.begin",
            metadata.as_object().unwrap(),
            &fixed_now().unwrap(),
            true,
            binding,
        )
        .unwrap();
    record("artifact.import.begin", &metadata, &begin);
    let append = json!({"importId":begin["importId"],"generation":"1","offset":"0","byteCount":bytes.len().to_string(),"sha256":sha256_hex(&bytes),"base64":encode_import_chunk(&bytes).unwrap()});
    let advanced = owner
        .handle_resource(
            "artifact.import.append",
            append.as_object().unwrap(),
            &fixed_now().unwrap(),
            true,
            binding,
        )
        .unwrap();
    record("artifact.import.append", &append, &advanced);
    let params = json!({"importId":begin["importId"],"generation":"1"});
    let committed = owner
        .commit(
            params.as_object().unwrap(),
            &fixed_now().unwrap(),
            true,
            artifacts,
            u64::MAX,
            binding,
        )
        .unwrap();
    record("artifact.import.commit", &params, &committed);
    assert_eq!(committed["receipt"]["privacy"], "sensitive");
    assert!(!committed.to_string().contains(PRIVATE_TEXT));
    committed["receipt"].clone()
}
fn request(lease: &Value, epoch: &str, binding_revision: i64) -> Map<String, Value> {
    let cases = support::document(&support::fixture("pointer-input"), "cases.json");
    let params = &cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "tap.submit")
        .unwrap()["params"];
    let mut doc: Value = serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
    doc["operation"] = json!({"id":"input.keyboard","version":1});
    doc["inputs"] = json!({"keyboardArtifactLease":lease,"inputEpochUtc":epoch});
    doc["target"]["expectedBindingRevision"] = json!(binding_revision);
    Map::from_iter([("requestJson".into(), json!(doc.to_string()))])
}
fn collect(path: &Path) -> Vec<Vec<u8>> {
    let mut bytes = vec![];
    for entry in fs::read_dir(path).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            bytes.extend(collect(&path));
        } else {
            bytes.push(fs::read(path).unwrap());
        }
    }
    bytes
}

#[test]
fn private_keyboard_owner_publishes_without_payload_and_unknown_never_replays() {
    if arkdeck_contract::operation_catalog::CatalogOperation::lookup("input.keyboard", Some(1))
        .is_none()
    {
        // The published contract view intentionally predates this candidate
        // operation. A current checkout losing the Catalog entry must fail.
        let inputs: Value = serde_json::from_str(arkdeck_contract::CONTRACT_INPUTS).unwrap();
        assert!(inputs.get("commit").is_some());
        return;
    }
    for reply in [
        Reply::Accepted,
        Reply::MissingAck,
        Reply::Unobservable,
        Reply::Refused,
    ] {
        let unknown = matches!(reply, Reply::MissingAck | Reply::Unobservable);
        let root = Root::new();
        let default_root = root.0.join("store");
        let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
        let imports = ImportUploadStore::open(&root.0.join("artifacts")).unwrap();
        let imported = import(&imports, &artifacts);
        let targets = TargetStore::open(&root.0.join("targets")).unwrap();
        let jobs = JobStore::open_owner(&default_root).unwrap();
        let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
        let sessions =
            SessionStore::open(&root.0.join("session-owner"), &root.0.join("Sessions")).unwrap();
        let claims = StorageClaims::default();
        let holds = DeviceHolds::default();
        let probe = OracleProbe::new(&json!({"availableBytes": 16_u64 * 1024 * 1024 * 1024}));
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: &probe,
        };
        let dispatch = Fake {
            reply,
            keyboard_calls: AtomicUsize::new(0),
            calls: Mutex::new(vec![]),
        };
        let digest = "b".repeat(64);
        let hdc = HdcComposition {
            targets: &targets,
            dispatch: &dispatch,
            receive_root: None,
            tool_sha256: &digest,
            now: fixed_now,
            code_sign_helper: None,
        };
        let authority = MutationAuthority {
            default_root: &default_root,
            sessions: Some(&sessions),
            capabilities: &capabilities,
            holds: &holds,
        };
        let planner = || JobPlanner {
            imports: Some(&imports),
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &root.0,
            hdc: Some(&hdc),
            workspace: None,
        };
        for bad in [
            request(&imported["lease"], "2026-09-13T23:59:40Z", 1),
            request(&imported["lease"], "2026-09-14T00:00:00Z", 2),
        ] {
            assert!(planner().handle(&bad).is_err());
            assert!(dispatch.calls.lock().unwrap().is_empty());
        }
        let params = request(&imported["lease"], "2026-09-14T00:00:00Z", 1);
        let preview = planner().handle(&params).unwrap();
        assert!(!preview.to_string().contains(PRIVATE_TEXT));
        assert!(dispatch.calls.lock().unwrap().is_empty());
        let submitted = JobAdmitter {
            planner: planner(),
            jobs: &jobs,
            now: fixed_now,
            authority: Some(authority),
        }
        .handle(&params)
        .unwrap();
        let job = Map::from_iter([("jobId".into(), submitted["jobId"].clone())]);
        let runner = JobRunner {
            imports: Some(&imports),
            mutation: Some(MutationExecution {
                authority,
                state_root: &root.0,
            }),
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota: u64::MAX,
            home: "",
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        };
        let result = runner.handle(&job).unwrap();
        assert_eq!(
            dispatch.keyboard_calls.load(Ordering::SeqCst),
            1,
            "{result}"
        );
        assert_eq!(
            result["state"],
            match reply {
                Reply::Accepted => "succeeded",
                Reply::Refused => "failed",
                _ => "waitingForRecovery",
            },
            "{result}"
        );
        assert!(runner.handle(&job).is_err());
        if unknown {
            let reconciler = JobReconciler {
                jobs: &jobs,
                artifacts: &artifacts,
                imports: Some(&imports),
                now: fixed_now,
                sessions: Some(&publisher),
                hdc: Some(&hdc),
                capabilities: Some(&capabilities),
                runner: Some(&runner),
            };
            let before = dispatch.calls.lock().unwrap().len();
            let _ = reconciler.handle(&job).unwrap();
            assert_eq!(dispatch.calls.lock().unwrap().len(), before);
            assert_eq!(dispatch.keyboard_calls.load(Ordering::SeqCst), 1);
        } else {
            assert!(!collect(&root.0.join("Sessions")).is_empty());
        }
        // Recreate durable owners and the in-memory hold set. A new owner
        // must derive the unresolved hold from the original durable outcome.
        drop(jobs);
        drop(capabilities);
        let jobs = JobStore::open_owner(&default_root).unwrap();
        let capabilities = CapabilityStore::open(&default_root.join("capabilities")).unwrap();
        let holds = DeviceHolds::default();
        let authority = MutationAuthority {
            default_root: &default_root,
            sessions: Some(&sessions),
            capabilities: &capabilities,
            holds: &holds,
        };
        let runner = JobRunner {
            imports: Some(&imports),
            mutation: Some(MutationExecution {
                authority,
                state_root: &root.0,
            }),
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota: u64::MAX,
            home: "",
            now: fixed_now,
            precise_now: fixed_precise_now,
            sessions: Some(&publisher),
            cancellation: None,
            after_commit: None,
            hdc: Some(&hdc),
            workspace: None,
        };
        let before = dispatch.calls.lock().unwrap().len();
        assert!(runner.handle(&job).is_err());
        if unknown {
            let reconciler = JobReconciler {
                jobs: &jobs,
                artifacts: &artifacts,
                imports: Some(&imports),
                now: fixed_now,
                sessions: Some(&publisher),
                hdc: Some(&hdc),
                capabilities: Some(&capabilities),
                runner: Some(&runner),
            };
            let _ = reconciler.handle(&job).unwrap();
            let mut fresh: Value =
                serde_json::from_str(params["requestJson"].as_str().unwrap()).unwrap();
            fresh["requestId"] = json!("req-keyboard-after-restart");
            fresh["idempotencyKey"] = json!("idem-keyboard-after-restart");
            let fresh = Map::from_iter([("requestJson".into(), json!(fresh.to_string()))]);
            let refusal = JobAdmitter {
                planner: planner(),
                jobs: &jobs,
                now: fixed_now,
                authority: Some(authority),
            }
            .handle(&fresh)
            .unwrap_err();
            assert_eq!(refusal.code, "admissionDenied");
        }
        assert_eq!(dispatch.calls.lock().unwrap().len(), before);
        assert_eq!(dispatch.keyboard_calls.load(Ordering::SeqCst), 1);
        // Private bytes belong only to the sensitive Import. Persisted Jobs,
        // journal, capability audit and Session products contain no copy.
        for bytes in collect(&default_root)
            .into_iter()
            .chain(collect(&root.0.join("Sessions")))
        {
            assert!(
                !bytes
                    .windows(PRIVATE_TEXT.len())
                    .any(|slice| slice == PRIVATE_TEXT.as_bytes())
            );
            assert!(!bytes.windows(6).any(|slice| slice == b"\\0160\\"));
        }
    }
}
