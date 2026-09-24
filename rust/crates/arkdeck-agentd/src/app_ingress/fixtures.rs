//! What the App ingress tests share: a private root with its peer, the App
//! boundary's frames and answers, the typed Job requests, and the Import
//! fixture's adopted Target. The binary's unit tests declare it (`tests.rs`),
//! and so does `tests/spawning`, whose App ingress tests drive a production
//! Host over a fake HDC; it therefore names everything from the crate root.
use crate::app_ingress::AppIngress;
use arkdeck_contract::{Request, WireError, decode_response};
use arkdeck_control::Control;
use arkdeck_hoststore::HistoryStore;
use arkdeck_platform::PeerOrigin;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

pub(super) struct Root(pub(super) PathBuf);
impl Root {
    pub(super) fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("app-history-{nonce:x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
    pub(super) fn control(&self) -> Arc<Control<crate::host::Host>> {
        Arc::new(
            Control::new(
                crate::host::Host::from_environment()
                    .with_history(HistoryStore::open(&self.0).unwrap()),
            )
            .unwrap(),
        )
    }
    pub(super) fn ingress(&self) -> AppIngress<crate::host::Host> {
        AppIngress::new(self.control(), fs::metadata(&self.0).unwrap().uid())
    }
    // Synthetic kernel-origin fixture, not evidence of a live signed XPC peer.
    pub(super) fn peer(&self) -> PeerOrigin {
        PeerOrigin {
            euid: fs::metadata(&self.0).unwrap().uid(),
            pid: 123,
            foreground_console: false,
        }
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
pub(super) fn frame(method: &str, params: Value) -> Vec<u8> {
    serde_json::to_vec(&Request::new(
        "request-1",
        method,
        params.as_object().cloned(),
    ))
    .unwrap()
}
pub(super) fn result(bytes: &[u8], method: &str) -> Value {
    decode_response(bytes.trim_ascii_end(), "request-1", method)
        .unwrap()
        .outcome
        .unwrap_or_else(|error| panic!("{method}: {error:?}"))
}
pub(super) fn code(bytes: &[u8]) -> String {
    serde_json::from_slice::<Value>(bytes).unwrap()["error"]["code"]
        .as_str()
        .unwrap()
        .to_owned()
}
pub(super) fn document(client: &str, operation: &str) -> Value {
    json!({"documentType":"runtime-operation-request","schemaVersion":"1.0.0",
        "requestId":"app-request", "idempotencyKey":"app-request",
        "target":{"targetId":"TGT-fixture","expectedBindingRevision":1},
        "operation":{"id":operation,"version":1},"inputs":{},
        "requestedOutputs":["rawArtifacts","derivedArtifacts"],
        "clientContext":{"clientName":client,"provenance":{}}})
}
pub(super) fn submit(document: &Value) -> Vec<u8> {
    frame("job.submit", json!({"requestJson":document.to_string()}))
}
pub(super) fn capture() -> Value {
    document("ArkDeckApp.DebugWorkspace.Logs", "capture.diagnostics")
}
/// The adopted Target of the checked-in Import fixture.
pub(super) const TARGET: &str = "TGT-dddddddddddd";
pub(super) fn directory(path: &Path) {
    fs::DirBuilder::new().mode(0o700).create(path).unwrap();
}
/// The isolated root's Target, Artifact and Job directories, the Target
/// adopted at revision 1 with a direct HDC route.
pub(super) fn uploads() -> Root {
    let root = Root::new();
    for name in ["targets", "artifacts", "jobs"] {
        directory(&root.0.join(name));
    }
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/import-target-current/direct");
    for name in ["targets.json", "target-display-names.json"] {
        let path = root.0.join("targets").join(name);
        fs::copy(source.join(name), &path).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    root
}
pub(super) fn refusal(bytes: &[u8], method: &str) -> WireError {
    decode_response(bytes.trim_ascii_end(), "request-1", method)
        .unwrap()
        .outcome
        .unwrap_err()
}
