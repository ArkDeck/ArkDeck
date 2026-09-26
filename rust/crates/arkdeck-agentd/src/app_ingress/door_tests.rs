//! The App transport's door as Swift's answers it
//! (`rust/tests/fixtures/app-ingress-door-oracle`, TASK-XPA-019): frames it
//! cannot decode, the Job requests its typed gate refuses and the Runtime
//! storage requests its closed parameters admit or refuse. A synthetic
//! kernel-origin peer; no signed XPC peer, device or installed Runtime.
use super::*;
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, WireError};
use arkdeck_hoststore::SessionStore;
use std::{collections::BTreeMap, sync::Mutex};

/// The owners a request can reach past the door, recording each call: the
/// actual Session storage owner, and the Job lifecycle, which refuses.
struct Owners {
    sessions: SessionStore,
    calls: Arc<Mutex<Vec<String>>>,
}
impl Owners {
    fn job(&self, method: &str) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push(method.into());
        Err(WireError {
            code: "rejected".into(),
            message: "no Job owner behind this door".into(),
            details: None,
        })
    }
}
impl HostServices for Owners {
    fn observations(&self) -> Result<arkdeck_contract::DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "unused fixture observation".into(),
            details: None,
        })
    }
    fn observed_at(&self) -> String {
        "2026-09-26T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> arkdeck_control::HdcStatus {
        arkdeck_control::HdcStatus::unavailable(deep, "fixture")
    }
    fn job_plan(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.job("job.plan")
    }
    fn job_submit(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.job("job.submit")
    }
    fn job_run(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.job("job.run")
    }
    fn job_cancel(&self, _: &serde_json::Map<String, Value>) -> Result<Value, WireError> {
        self.job("job.cancel")
    }
    fn runtime_storage(
        &self,
        method: &str,
        params: &serde_json::Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.calls.lock().unwrap().push(method.into());
        self.sessions.handle(method, params)
    }
}

/// Every directory and file under `path`, with the bytes of each file.
fn tree(path: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut entries = BTreeMap::new();
    let mut pending = vec![path.to_owned()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                pending.push(entry.path());
                entries.insert(entry.path(), Vec::new());
            } else {
                entries.insert(entry.path(), fs::read(entry.path()).unwrap());
            }
        }
    }
    entries
}

/// Each case of Swift's oracle through this ingress, in the oracle's order:
/// a refusal at the door is Swift's frame byte for byte, and leaves the
/// dispatch count, the owners' calls and the store's files as they were; a
/// request Swift's door lets through reaches the Runtime once, and its owner
/// once.
#[test]
fn the_door_answers_every_frame_as_swift_s_app_transport_does() {
    let root = Root::new();
    for name in ["state", "sessions"] {
        directory(&root.0.join(name));
    }
    let calls = Arc::new(Mutex::new(Vec::new()));
    let ingress = AppIngress::new(
        Arc::new(
            Control::new(Owners {
                sessions: SessionStore::open(&root.0.join("state"), &root.0.join("sessions"))
                    .unwrap(),
                calls: Arc::clone(&calls),
            })
            .unwrap(),
        ),
        root.peer().euid,
    );
    let oracle: Value = serde_json::from_str(include_str!(
        "../../../../tests/fixtures/app-ingress-door-oracle/cases.json"
    ))
    .unwrap();
    assert_eq!(oracle["schemaVersion"], "arkdeck.app-ingress-door-oracle/1");
    let id = oracle["requestId"].as_str().unwrap();
    let cases = oracle["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 64);
    let (mut refused, mut forwarded) = (0, 0);
    for case in cases {
        let name = case["case"].as_str().unwrap();
        let frame = match case["raw"].as_str() {
            Some(raw) => raw
                .replace("$protocolVersion", PROTOCOL_VERSION)
                .replace("$contractIdentity", CONTRACT_IDENTITY)
                .into_bytes(),
            None => serde_json::to_vec(&Request::new(
                id,
                case["method"].as_str().unwrap(),
                case.get("params").and_then(Value::as_object).cloned(),
            ))
            .unwrap(),
        };
        let before = (
            tree(&root.0),
            ingress.dispatches.load(Ordering::Relaxed),
            calls.lock().unwrap().clone(),
        );
        let reply = ingress.handle(&frame, root.peer());
        if case["forwarded"] == true {
            forwarded += 1;
            assert_eq!(
                ingress.dispatches.load(Ordering::Relaxed),
                before.1 + 1,
                "{name} did not reach the Runtime: {}",
                String::from_utf8_lossy(&reply)
            );
            let mut reached = before.2.clone();
            reached.push(case["method"].as_str().unwrap().into());
            assert_eq!(*calls.lock().unwrap(), reached, "{name}");
        } else {
            refused += 1;
            assert_eq!(
                String::from_utf8_lossy(&reply),
                case["received"].as_str().unwrap(),
                "{name}"
            );
            assert_eq!(
                (
                    tree(&root.0),
                    ingress.dispatches.load(Ordering::Relaxed),
                    calls.lock().unwrap().clone(),
                ),
                before,
                "{name} reached the Runtime"
            );
        }
    }
    assert_eq!((refused, forwarded), (55, 9));
}
