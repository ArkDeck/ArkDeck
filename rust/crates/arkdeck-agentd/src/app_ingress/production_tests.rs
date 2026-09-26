//! The production composition's App ingress: the fixed service and Swift's
//! code-signing requirement, as the isolated ingress registers them, over the
//! account's own state root, with the same kernel-origin checks before any
//! frame reaches Control. The listener is a recording seam: no Mach service
//! is registered, and PeerOrigin here is a synthetic fixture, not evidence of
//! a signed peer.
use super::*;
use std::os::unix::fs::PermissionsExt;
use std::sync::Mutex;

type Registered = Arc<Mutex<Option<(String, String, Handler)>>>;

fn registered(root: &Root) -> (Registered, Arc<Control<crate::host::Host>>) {
    let control = root.control();
    let registered = Registered::default();
    let recording = Arc::clone(&registered);
    Configuration::production(&root.0)
        .unwrap()
        .listen_with(
            Arc::clone(&control),
            move |service, requirement, handler| {
                *recording.lock().unwrap() = Some((service.into(), requirement.into(), handler));
                Ok(())
            },
        )
        .unwrap();
    (registered, control)
}

#[test]
fn production_ingress_registers_the_fixed_service_with_the_app_requirement() {
    let root = Root::new();
    let (registered, _control) = registered(&root);
    let guard = registered.lock().unwrap();
    let (service, requirement, handler) = guard.as_ref().unwrap();
    assert_eq!(service, "com.arkdeck.agentd");
    assert_eq!(
        requirement,
        "anchor apple generic and certificate leaf[subject.OU] = \"8AQTYW5FKR\" and identifier \
         \"com.arkdeck.desktop\""
    );
    // The authenticated App peer: the owner's effective UID, a real PID and
    // no console.
    let peer = root.peer();
    let health = frame("health", json!({}));
    arkdeck_contract::validate_health(
        &decode_response(
            handler(&health, peer).trim_ascii_end(),
            "request-1",
            "health",
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        result(
            &handler(&frame("history.filter.list", json!({})), peer),
            "history.filter.list"
        )["generation"],
        "1"
    );
    // Another user's peer, a PID libxpc cannot vouch for, and a console
    // origin are refused before Control reads the frame.
    for refused in [
        PeerOrigin {
            euid: peer.euid.wrapping_add(1),
            ..peer
        },
        PeerOrigin { pid: 1, ..peer },
        PeerOrigin { pid: 0, ..peer },
        PeerOrigin {
            foreground_console: true,
            ..peer
        },
    ] {
        let answer = handler(&frame("history.filter.save", save("1")), refused);
        assert_eq!(code(&answer), "rejected", "{refused:?}");
        assert!(
            String::from_utf8_lossy(&answer).contains("authenticated App transport origin"),
            "{refused:?}"
        );
    }
    // Nothing the refused peers sent was saved.
    assert_eq!(
        result(
            &handler(&frame("history.filter.list", json!({})), peer),
            "history.filter.list"
        )["generation"],
        "1"
    );
    // A method outside the App's allowlist is refused as the isolated
    // ingress refuses it: Swift's App transport refusal.
    assert_eq!(
        code(&handler(
            &frame("runtime.hdc.restart", json!({"expectedGeneration": "1"})),
            peer
        )),
        "methodNotAllowlisted"
    );
}

#[test]
fn production_ingress_requires_the_owners_private_physical_state_root() {
    let root = Root::new();
    assert!(Configuration::production(&root.0).is_ok());
    let alias = root.0.join("alias");
    let state = root.0.join("state");
    fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
    symlink(&state, &alias).unwrap();
    assert!(Configuration::production(&alias).is_err());
    fs::set_permissions(&state, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Configuration::production(&state).is_err());
    assert!(Configuration::production(&root.0.join("missing")).is_err());
    assert!(Configuration::production(Path::new("relative")).is_err());
    assert!(!root.0.join("missing").exists());
}
