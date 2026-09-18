//! Negative startup checks only: every case refuses before any listener or
//! store is opened. No launchd registration, signature fixture or device runs.
#![cfg(target_os = "macos")]

use std::process::Command;

#[test]
fn app_ingress_invalid_activation_never_starts_a_listener() {
    for (environment, message) in [
        (
            vec![("ARKDECK_APP_INGRESS", "all")],
            "standalone history composition",
        ),
        (
            vec![("ARKDECK_APP_INGRESS", "history")],
            "isolated state root",
        ),
        (
            vec![
                ("ARKDECK_APP_INGRESS", "history"),
                ("ARKDECK_SWIFT_DAEMON", "/nonexistent-swift-authority"),
            ],
            "standalone history composition",
        ),
        (
            vec![
                ("ARKDECK_APP_INGRESS", "history"),
                ("CFFIXED_USER_HOME", "/nonexistent-account"),
            ],
            "cannot override the account home",
        ),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_arkdeck-agentd"))
            .env_clear()
            .envs(environment)
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8(output.stderr).unwrap().contains(message));
    }
}
