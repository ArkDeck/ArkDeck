use super::*;
use arkdeck_hoststore::{ArtifactUsage, SessionStore};

fn control(root: &Root) -> Arc<Control<crate::host::Host>> {
    for name in ["state", "sessions", "artifacts"] {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root.0.join(name))
            .unwrap();
    }
    Arc::new(
        Control::new(crate::host::Host::from_environment().with_storage(
            SessionStore::open(&root.0.join("state"), &root.0.join("sessions")).unwrap(),
            ArtifactUsage::open(&root.0.join("artifacts"), 1024).unwrap(),
        ))
        .unwrap(),
    )
}
fn domain(bytes: &[u8], method: &str) -> Value {
    result(bytes, method)["sessionDomain"].clone()
}
fn policy(generation: &str) -> Value {
    json!({"expectedGeneration":generation,"totalQuotaBytes":"1048576","safetyMarginBytes":"1024","retentionDays":"7"})
}

#[test]
fn storage_settings_use_the_runtime_owner_once_and_persist_across_reopen() {
    let root = Root::new();
    let shared = control(&root);
    let ingress = AppIngress::new(shared.clone(), root.peer().euid);
    let call = |method, params| ingress.handle(&frame(method, params), root.peer());
    let status = domain(
        &call("runtime.storage.status", json!({})),
        "runtime.storage.status",
    );
    assert_eq!(status["generation"], "1");
    let saved = domain(
        &call("runtime.storage.policy", policy("1")),
        "runtime.storage.policy",
    );
    assert_eq!(saved["generation"], "2");
    assert_eq!(saved["policy"]["retentionDays"], "7");
    assert_eq!(
        domain(
            &shared.handle_frame(&frame("runtime.storage.status", json!({}))),
            "runtime.storage.status"
        ),
        saved
    );
    let before = fs::read(root.0.join("state/session-storage.json")).unwrap();
    assert_eq!(
        code(&call("runtime.storage.policy", policy("1"))),
        "resourceConflict"
    );
    assert_eq!(
        fs::read(root.0.join("state/session-storage.json")).unwrap(),
        before
    );
    let mut invalid = policy("2");
    invalid["safetyMarginBytes"] = json!("1048576");
    assert_eq!(
        code(&call("runtime.storage.policy", invalid)),
        "invalidInput"
    );
    assert_eq!(
        fs::read(root.0.join("state/session-storage.json")).unwrap(),
        before
    );
    let custom = root.0.join("custom");
    fs::DirBuilder::new().mode(0o700).create(&custom).unwrap();
    let selected = domain(
        &call(
            "runtime.storage.root",
            json!({"expectedGeneration":"2","rootPath":custom}),
        ),
        "runtime.storage.root",
    );
    assert_eq!(selected["generation"], "3");
    assert_eq!(selected["rootPath"], json!(custom));
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 5);
    drop(ingress);
    drop(shared);
    let reopened = AppIngress::new(control(&root), root.peer().euid);
    assert_eq!(
        domain(
            &reopened.handle(&frame("runtime.storage.status", json!({})), root.peer()),
            "runtime.storage.status"
        ),
        selected
    );
    let reset = domain(
        &reopened.handle(
            &frame(
                "runtime.storage.root",
                json!({"expectedGeneration":"3","resetToDefault":true}),
            ),
            root.peer(),
        ),
        "runtime.storage.root",
    );
    assert_eq!(reset["generation"], "4");
    assert_eq!(reset["rootKind"], "default");
    assert_eq!(reset["policy"], saved["policy"]);
    assert_eq!(reopened.dispatches.load(Ordering::Relaxed), 2);
}

#[test]
fn malformed_settings_and_foreign_peers_never_enter_the_owner() {
    let root = Root::new();
    let ingress = AppIngress::new(control(&root), root.peer().euid);
    for key in [
        "expectedGeneration",
        "totalQuotaBytes",
        "safetyMarginBytes",
        "retentionDays",
    ] {
        for bad in [
            json!(0),
            json!("0"),
            json!("01"),
            json!("+1"),
            json!("9223372036854775808"),
            Value::Null,
        ] {
            let mut params = policy("1");
            params[key] = bad;
            assert_eq!(
                code(&ingress.handle(&frame("runtime.storage.policy", params), root.peer())),
                "invalidParams"
            );
        }
        let mut params = policy("1");
        params.as_object_mut().unwrap().remove(key);
        assert_eq!(
            code(&ingress.handle(&frame("runtime.storage.policy", params), root.peer())),
            "invalidParams"
        );
    }
    for params in [
        json!({"expectedGeneration":"1"}),
        json!({"expectedGeneration":"1","resetToDefault":false}),
        json!({"expectedGeneration":"1","rootPath":"/tmp","resetToDefault":true}),
        json!({"expectedGeneration":"1","rootPath":true}),
        json!({"expectedGeneration":"1","resetToDefault":true,"authorization":{}}),
    ] {
        assert_eq!(
            code(&ingress.handle(&frame("runtime.storage.root", params), root.peer())),
            "invalidParams"
        );
    }
    for method in ["runtime.storage.policy", "runtime.storage.root"] {
        assert_eq!(
            code(&ingress.handle(
                &frame(method, policy("1")),
                PeerOrigin {
                    euid: root.peer().euid.wrapping_add(1),
                    ..root.peer()
                }
            )),
            "rejected"
        );
    }
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 0);
    assert!(!root.0.join("state/session-storage.json").exists());
}

#[test]
fn unsafe_roots_and_unreadable_storage_fail_without_fallback() {
    let root = Root::new();
    let ingress = AppIngress::new(control(&root), root.peer().euid);
    let invalid = ingress.handle(
        &frame(
            "runtime.storage.root",
            json!({"expectedGeneration":"1","rootPath":"relative"}),
        ),
        root.peer(),
    );
    assert_eq!(code(&invalid), "invalidInput");
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 1);
    fs::write(root.0.join("state/session-storage.json"), b"broken").unwrap();
    assert_eq!(
        code(&ingress.handle(&frame("runtime.storage.policy", policy("1")), root.peer())),
        "recordUnreadable"
    );
    assert_eq!(
        fs::read(root.0.join("state/session-storage.json")).unwrap(),
        b"broken"
    );
    assert_eq!(ingress.dispatches.load(Ordering::Relaxed), 2);
}
