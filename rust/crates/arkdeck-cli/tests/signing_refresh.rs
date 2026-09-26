//! Public fingerprint maintenance: fixture files and a secret source whose
//! value reader panics. No real Keychain or installed helper is accessed.
#![cfg(target_os = "macos")]
#[path = "support/signing_fixture.rs"]
mod signing_fixture;
use arkdeck_provider_workspace::{
    SigningError,
    credential_owner::CredentialOwner,
    signing_preset::{SecretPresence, SigningPresetStore, SigningSecrets},
};
use serde_json::{Value, json};
use std::{fs, os::unix::fs::MetadataExt, path::PathBuf};
struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        Self(PathBuf::from(format!(
            "/private/tmp/arkdeck-sign-refresh-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        )))
    }
    fn owner(&self) -> CredentialOwner {
        CredentialOwner::new(SigningPresetStore::new(&self.0))
    }
    fn receipt(&self) -> PathBuf {
        self.0.join("preset-v1.json")
    }
    fn ledger(&self) -> PathBuf {
        self.0.join("credential-owner-v1.json")
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct Secrets {
    presence: SecretPresence,
    identity: Result<Option<String>, SigningError>,
}
impl SigningSecrets for Secrets {
    fn read(&self, _: &str) -> Result<arkdeck_platform::Secret, SigningError> {
        panic!("maintenance must not read passwords")
    }
    fn presence(&self, _: &str) -> SecretPresence {
        self.presence
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        match &self.identity {
            Ok(identity) => Ok(identity.clone()),
            Err(_) => Err(SigningError::SecretUnavailable(
                "fixture untrusted daemon".into(),
            )),
        }
    }
}
#[test]
fn refresh_preserves_pins_and_public_identity_without_reading_secrets() {
    for presence in [SecretPresence::Present, SecretPresence::Unreadable] {
        let home = Home::new();
        let mut expected = signing_fixture::install(&home.0);
        let owner = home.owner();
        let before = owner.current().unwrap();
        let mut ledger: Value = serde_json::from_slice(&fs::read(home.ledger()).unwrap()).unwrap();
        ledger["presetOwners"] = json!(["preset-a"]);
        fs::write(home.ledger(), serde_json::to_vec(&ledger).unwrap()).unwrap();
        let ledger_bytes = fs::read(home.ledger()).unwrap();
        let secrets = Secrets {
            presence,
            identity: Ok(Some("b".repeat(64))),
        };
        owner.refresh_daemon_identity(&secrets).unwrap();
        expected["trustedDaemonApplicationSHA256"] = json!("b".repeat(64));
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(home.receipt()).unwrap()).unwrap(),
            expected
        );
        assert_eq!(fs::metadata(home.receipt()).unwrap().mode() & 0o777, 0o600);
        assert_eq!(fs::read(home.ledger()).unwrap(), ledger_bytes);
        let after = owner.current().unwrap();
        assert_eq!(after.credential_ref, before.credential_ref);
        assert_eq!(after.reference_count, 1);
        let inode = fs::metadata(home.receipt()).unwrap().ino();
        owner.refresh_daemon_identity(&secrets).unwrap();
        assert_eq!(
            fs::metadata(home.receipt()).unwrap().ino(),
            inode,
            "unchanged identity must not rewrite receipt"
        );
    }
}
#[test]
fn absent_envelope_or_untrusted_daemon_cannot_rewrite_receipt() {
    for secrets in [
        Secrets {
            presence: SecretPresence::Absent,
            identity: Ok(Some("b".repeat(64))),
        },
        Secrets {
            presence: SecretPresence::Unreadable,
            identity: Err(SigningError::SecretUnavailable("fixture".into())),
        },
    ] {
        let home = Home::new();
        signing_fixture::install(&home.0);
        let owner = home.owner();
        owner.current().unwrap();
        let receipt = fs::read(home.receipt()).unwrap();
        let ledger = fs::read(home.ledger()).unwrap();
        assert!(owner.refresh_daemon_identity(&secrets).is_err());
        assert_eq!(fs::read(home.receipt()).unwrap(), receipt);
        assert_eq!(fs::read(home.ledger()).unwrap(), ledger);
    }
}
#[test]
fn public_preflight_detects_material_drift_without_creating_owner_state() {
    let home = Home::new();
    signing_fixture::install(&home.0);
    arkdeck_cli::signing_leaves::validate_refresh(&home.0).unwrap();
    assert!(!home.ledger().exists());
    fs::write(home.0.join("source.p12"), b"changed public material").unwrap();
    assert!(arkdeck_cli::signing_leaves::validate_refresh(&home.0).is_err());
    assert!(!home.ledger().exists());
    let secrets = Secrets {
        presence: SecretPresence::Unreadable,
        identity: Ok(Some("b".repeat(64))),
    };
    let receipt = fs::read(home.receipt()).unwrap();
    assert!(home.owner().refresh_daemon_identity(&secrets).is_err());
    assert_eq!(fs::read(home.receipt()).unwrap(), receipt);
}

#[test]
fn invalid_owner_state_refuses_before_probing_secrets_or_rewriting_receipt() {
    struct Never;
    impl SigningSecrets for Never {
        fn read(&self, _: &str) -> Result<arkdeck_platform::Secret, SigningError> {
            panic!("no secret read")
        }
        fn presence(&self, _: &str) -> SecretPresence {
            panic!("invalid owner must refuse before Keychain")
        }
        fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
            panic!("invalid owner must refuse before identity probe")
        }
    }
    let home = Home::new();
    signing_fixture::install(&home.0);
    let owner = home.owner();
    owner.current().unwrap();
    let mut ledger: Value = serde_json::from_slice(&fs::read(home.ledger()).unwrap()).unwrap();
    ledger["credentialRef"] = json!("stale-credential-reference");
    ledger["presetOwners"] = json!(["preset-a"]);
    fs::write(home.ledger(), serde_json::to_vec(&ledger).unwrap()).unwrap();
    let receipt = fs::read(home.receipt()).unwrap();
    let ledger = fs::read(home.ledger()).unwrap();
    assert!(owner.refresh_daemon_identity(&Never).is_err());
    assert_eq!(fs::read(home.receipt()).unwrap(), receipt);
    assert_eq!(fs::read(home.ledger()).unwrap(), ledger);
}
