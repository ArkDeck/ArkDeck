use super::*;
use arkdeck_contract::{MAX_REQUEST_BYTES, METHODS, decode_response};
use arkdeck_hoststore::HistoryStore;
use serde_json::json;
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, symlink},
    path::PathBuf,
    sync::atomic::Ordering,
};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("app-history-{nonce:x}"));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
    fn control(&self) -> Arc<Control<crate::host::Host>> {
        Arc::new(
            Control::new(
                crate::host::Host::from_environment()
                    .with_history(HistoryStore::open(&self.0).unwrap()),
            )
            .unwrap(),
        )
    }
    fn ingress(&self) -> HistoryIngress<crate::host::Host> {
        HistoryIngress::new(self.control(), fs::metadata(&self.0).unwrap().uid())
    }
    // Synthetic kernel-origin fixture, not evidence of a live signed XPC peer.
    fn peer(&self) -> PeerOrigin {
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
fn frame(method: &str, params: Value) -> Vec<u8> {
    serde_json::to_vec(&Request::new(
        "request-1",
        method,
        params.as_object().cloned(),
    ))
    .unwrap()
}
fn save(generation: &str) -> Value {
    json!({"expectedGeneration":generation,"search":"build","status":"failed","mode":"all","sessionId":null,"targetId":null,"timeRange":"lastDay","activity":"all"})
}
fn result(bytes: &[u8], method: &str) -> Value {
    decode_response(bytes.trim_ascii_end(), "request-1", method)
        .unwrap()
        .outcome
        .unwrap_or_else(|error| panic!("{method}: {error:?}"))
}
fn code(bytes: &[u8]) -> String {
    serde_json::from_slice::<Value>(bytes).unwrap()["error"]["code"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[test]
fn history_uses_shared_control_persists_reopen_and_never_retries_conflict() {
    let root = Root::new();
    let control = root.control();
    let ingress = HistoryIngress::new(Arc::clone(&control), root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    let health = call("health", json!({}));
    arkdeck_contract::validate_health(
        &decode_response(health.trim_ascii_end(), "request-1", "health").unwrap(),
    )
    .unwrap();
    assert_eq!(
        result(
            &call("history.filter.list", json!({})),
            "history.filter.list"
        )["generation"],
        "1"
    );
    assert_eq!(
        result(
            &call("history.filter.save", save("1")),
            "history.filter.save"
        )["generation"],
        "2"
    );
    // The ordinary UDS path calls this exact same Control object, so the save
    // is visible through it without forwarding or opening a second authority.
    let list = frame("history.filter.list", json!({}));
    assert_eq!(
        result(&control.handle_frame(&list), "history.filter.list")["filters"][0]["query"]["search"],
        "build"
    );
    assert_eq!(
        code(&call("history.filter.save", save("1"))),
        "resourceConflict"
    );
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 4);
    drop(ingress);
    drop(control);
    let reopened = root.ingress();
    assert_eq!(
        result(&reopened.handle(&list, root.peer()), "history.filter.list")["generation"],
        "2"
    );
    assert_eq!(
        result(
            &reopened.handle(
                &frame("history.filter.delete", json!({"expectedGeneration":"2"})),
                root.peer()
            ),
            "history.filter.delete"
        )["generation"],
        "3"
    );
    drop(reopened);
    let projection = result(
        &root.ingress().handle(&list, root.peer()),
        "history.filter.list",
    );
    assert_eq!(projection["generation"], "3");
    assert_eq!(projection["filters"], json!([]));
}

#[test]
fn rejected_origins_methods_frames_and_parameters_never_enter_control() {
    let root = Root::new();
    let ingress = root.ingress();
    let valid = frame("history.filter.save", save("1"));
    for peer in [
        PeerOrigin {
            euid: root.peer().euid.wrapping_add(1),
            ..root.peer()
        },
        PeerOrigin {
            pid: 0,
            ..root.peer()
        },
        PeerOrigin {
            foreground_console: true,
            ..root.peer()
        },
    ] {
        assert_eq!(code(&ingress.handle(&valid, peer)), "rejected");
    }
    for method in METHODS {
        if [
            "health",
            "history.filter.list",
            "history.filter.save",
            "history.filter.delete",
            "job.list",
            "job.show",
            "job.timeline",
            "job.evidence",
            "artifact.list",
            "artifact.read",
        ]
        .contains(method)
        {
            continue;
        }
        let reply = ingress.handle(&frame(method, json!({})), root.peer());
        assert_eq!(code(&reply), "rejected", "{method}");
        assert!(
            decode_response(reply.trim_ascii_end(), "request-1", method).is_ok(),
            "refusal must conform for {method}"
        );
    }
    let mut forged: Value = serde_json::from_slice(&valid).unwrap();
    forged["arkdeckOrigin"] = json!({"transport":"appXPC","peerEUID":root.peer().euid});
    let frames = [
        vec![],
        b"{}".to_vec(),
        vec![b' '; MAX_REQUEST_BYTES + 1],
        serde_json::to_vec(&forged).unwrap(),
        b"{\"id\":\"x\",\"id\":\"y\"}".to_vec(),
    ];
    for bad in frames {
        assert_eq!(code(&ingress.handle(&bad, root.peer())), "malformedFrame");
    }
    let mut wrong_version: Value = serde_json::from_slice(&valid).unwrap();
    wrong_version["protocolVersion"] = json!("0.0.0");
    let reply = ingress.handle(&serde_json::to_vec(&wrong_version).unwrap(), root.peer());
    assert_eq!(
        decode_response(reply.trim_ascii_end(), "request-1", "history.filter.save")
            .unwrap()
            .outcome
            .unwrap_err()
            .code,
        "unsupportedProtocolVersion"
    );
    for (method, params) in [
        ("health", json!({"path":"/tmp"})),
        ("history.filter.list", json!({"peerEUID":root.peer().euid})),
        ("history.filter.delete", json!({})),
        ("history.filter.delete", json!({"expectedGeneration":1})),
        ("history.filter.save", json!({})),
        ("job.list", json!({"path":"/tmp/foreign"})),
        ("job.show", json!({"jobId":5})),
        ("job.timeline", json!({"jobId":"JOB-1","pageSize":false})),
        ("job.evidence", json!({"jobId":"JOB-1","authorization":{}})),
        (
            "artifact.list",
            json!({"owner":{"kind":"job","id":"JOB-1","path":"/tmp"}}),
        ),
        (
            "artifact.read",
            json!({"artifactId":"ART-1","allowSensitive":"true"}),
        ),
    ] {
        let reply = ingress.handle(&frame(method, params), root.peer());
        assert_eq!(
            decode_response(reply.trim_ascii_end(), "request-1", method)
                .unwrap()
                .outcome
                .unwrap_err()
                .code,
            "invalidParams"
        );
    }
    let mut extra = save("1");
    extra["path"] = json!("/tmp/foreign");
    assert_eq!(
        code(&ingress.handle(&frame("history.filter.save", extra), root.peer())),
        "invalidParams"
    );
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert_eq!(
        fs::read_dir(&root.0).unwrap().count(),
        0,
        "no owner read, lock or write on refusal"
    );
}

#[test]
fn opt_in_root_is_private_physical_and_separate_from_installed_state() {
    let root = Root::new();
    let home = Root::new();
    assert!(Configuration::isolated(&root.0, &home.0).is_ok());
    let installed = home.0.join("Library/Application Support/ArkDeck/Agentd");
    fs::create_dir_all(&installed).unwrap();
    assert!(Configuration::isolated(&installed, &home.0).is_err());
    let alias = root.0.join("alias");
    symlink(&installed, &alias).unwrap();
    assert!(Configuration::isolated(&alias, &home.0).is_err());
    assert!(Configuration::isolated(Path::new("relative"), &home.0).is_err());
    assert!(Configuration::isolated(&root.0.join("missing"), &home.0).is_err());
    assert!(!root.0.join("missing").exists());
    assert_eq!(fs::read_dir(&installed).unwrap().count(), 0);
}

#[path = "read_tests.rs"]
mod reads;
