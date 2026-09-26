//! Explicit signing maintenance over temporary receipts and recording secret
//! removers. No test deletes or reads a real Keychain item. CLI process tests
//! reach only the owner-pin refusal, before any secret-removal call.
#![cfg(target_os = "macos")]

use arkdeck_cli::signing_leaves::remove_document;
use arkdeck_provider_workspace::SigningError;
use arkdeck_provider_workspace::signing_removal::SigningSecretRemoval;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const ENVELOPE: &str = "openharmony-release@1|secret-envelope-5d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f";
const OLD_ENVELOPE: &str =
    "openharmony-release@1|secret-envelope-6d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f";

struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let path = PathBuf::from(format!(
            "/private/tmp/arkdeck-sign-remove-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn root(&self) -> PathBuf {
        self.0
            .join("Library/Application Support/ArkDeck/Signing/OpenHarmony")
    }
    fn write(&self, name: &str, value: &Value) {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(self.root())
            .unwrap();
        let path = self.root().join(name);
        fs::write(&path, serde_json::to_vec(value).unwrap()).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn ledger(&self) -> Value {
        serde_json::from_slice(&fs::read(self.root().join("credential-owner-v1.json")).unwrap())
            .unwrap()
    }
    fn receipt(&self, managed: Option<&Path>) -> Value {
        let identity = |name: &str| json!({"path": self.0.join(name), "sha256": "a".repeat(64), "byteCount": 1});
        let mut receipt = json!({"schemaVersion": "arkdeck-openharmony-signing/v1",
            "installedAtUTC": "2026-09-26T00:00:00Z", "presetID": "openharmony-release@1",
            "projectRef": "demo-app", "javaExecutable": identity("java"),
            "signerJAR": identity("signer.jar"), "keystore": identity("source.p12"),
            "appCertificate": identity("source.pem"), "signedProfile": identity("source.p7b"),
            "keyAlias": "release", "signingAlgorithm": "SHA256withECDSA",
            "keystorePasswordAccount": "openharmony-release@1|keystore",
            "keyPasswordAccount": "openharmony-release@1|key", "secretEnvelopeAccount": ENVELOPE,
            "supersededEnvelopeAccounts": [OLD_ENVELOPE, OLD_ENVELOPE],
            "keychainAccessSchema": "data-protection-access-group-v1"});
        if let Some(managed) = managed {
            receipt["managedMaterialDirectory"] = json!(managed);
        }
        receipt
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct Secrets {
    calls: Mutex<Vec<(String, String)>>,
    fail: bool,
    absent: bool,
    owner_root: Option<PathBuf>,
}
impl SigningSecretRemoval for Secrets {
    fn remove_current(&self, account: &str) -> Result<bool, SigningError> {
        if let Some(root) = &self.owner_root {
            let ledger: Value =
                serde_json::from_slice(&fs::read(root.join("credential-owner-v1.json")).unwrap())
                    .unwrap();
            assert_eq!(
                ledger["state"], "removing",
                "intent must precede the external delete"
            );
        }
        self.calls
            .lock()
            .unwrap()
            .push(("current".into(), account.into()));
        Ok(!self.absent)
    }
    fn remove_legacy(&self, account: &str) -> Result<bool, SigningError> {
        self.calls
            .lock()
            .unwrap()
            .push(("legacy".into(), account.into()));
        if self.fail {
            Err(SigningError::SecretUnavailable(
                "recording store refused removal".into(),
            ))
        } else {
            Ok(!self.absent)
        }
    }
}

#[test]
fn removal_clears_both_scopes_once_and_preserves_private_source_material() {
    let home = Home::new();
    for name in ["source.p12", "source.pem", "source.p7b"] {
        fs::write(home.0.join(name), b"fixture material").unwrap();
    }
    let mut receipt = home.receipt(None);
    receipt["additionalMetadata"] = json!("ignored by Swift's uninstall decoder");
    receipt["keystore"]["additionalMetadata"] = json!(true);
    home.write("preset-v1.json", &receipt);
    let secrets = Secrets::default();
    assert_eq!(
        remove_document(&home.root(), &secrets).unwrap(),
        json!({
        "schemaVersion": "arkdeck.signing-credential-removal/1", "state": "removed",
        "removedReceipt": true, "removedKeystorePassword": true, "removedKeyPassword": true,
        "removedManagedMaterial": false, "preservedSourceCount": 3})
    );
    let calls = secrets.calls.lock().unwrap();
    assert_eq!(calls.len(), 8);
    assert_eq!(calls.iter().collect::<BTreeSet<_>>().len(), 8);
    assert!(calls.contains(&("current".into(), ENVELOPE.into())));
    assert!(calls.contains(&("legacy".into(), ENVELOPE.into())));
    drop(calls);
    for name in ["source.p12", "source.pem", "source.p7b"] {
        assert_eq!(fs::read(home.0.join(name)).unwrap(), b"fixture material");
    }
    assert!(!home.root().join("preset-v1.json").exists());
    assert_eq!(
        home.ledger(),
        json!({"schemaVersion": "arkdeck.signing-credential-owner/1",
        "state": "stable", "presetOwners": []})
    );
}

#[test]
fn only_managed_material_immediately_below_the_preset_root_is_removed() {
    let home = Home::new();
    let managed = home.root().join("managed-material");
    home.write("preset-v1.json", &home.receipt(Some(&managed)));
    fs::create_dir(&managed).unwrap();
    fs::write(managed.join("fixture.p12"), b"fixture").unwrap();
    let result = remove_document(&home.root(), &Secrets::default()).unwrap();
    assert_eq!(result["removedManagedMaterial"], true);
    assert_eq!(result["preservedSourceCount"], 0);
    assert!(!managed.exists());

    let escaped = home.0.join("user-material");
    fs::create_dir(&escaped).unwrap();
    fs::write(escaped.join("keep"), b"keep").unwrap();
    home.write("preset-v1.json", &home.receipt(Some(&escaped)));
    let secrets = Secrets::default();
    assert!(
        remove_document(&home.root(), &secrets)
            .unwrap_err()
            .to_string()
            .contains("outside the preset root")
    );
    assert!(secrets.calls.lock().unwrap().is_empty());
    assert_eq!(fs::read(escaped.join("keep")).unwrap(), b"keep");
    assert!(home.root().join("preset-v1.json").exists());
}

#[test]
fn active_or_invalid_owner_records_refuse_before_any_secret_or_receipt_change() {
    for (state, owners) in [
        ("stable", json!(["preset-a"])),
        ("replacing", json!(["preset-a"])),
        ("unknown", json!([])),
        ("stable", json!(["preset-a", "preset-a"])),
    ] {
        let home = Home::new();
        home.write("preset-v1.json", &json!({"broken": true}));
        let ledger = json!({"schemaVersion": "arkdeck.signing-credential-owner/1", "state": state,
            "credentialRef": "credential:sha256-unreadable", "presetOwners": owners});
        home.write("credential-owner-v1.json", &ledger);
        let receipt = fs::read(home.root().join("preset-v1.json")).unwrap();
        let secrets = Secrets::default();
        assert!(remove_document(&home.root(), &secrets).is_err());
        assert!(secrets.calls.lock().unwrap().is_empty());
        assert_eq!(home.ledger(), ledger);
        assert_eq!(
            fs::read(home.root().join("preset-v1.json")).unwrap(),
            receipt
        );
    }
}

#[test]
fn interrupted_removal_of_an_unreadable_receipt_can_be_completed_explicitly() {
    let home = Home::new();
    home.write("preset-v1.json", &json!({"broken": true}));
    let failing = Secrets {
        fail: true,
        owner_root: Some(home.root()),
        ..Secrets::default()
    };
    assert!(remove_document(&home.root(), &failing).is_err());
    assert_eq!(home.ledger()["state"], "removing");
    assert!(home.root().join("preset-v1.json").exists());
    let result = remove_document(&home.root(), &Secrets::default()).unwrap();
    assert_eq!(result["removedReceipt"], true);
    assert_eq!(home.ledger()["state"], "stable");
    let again = remove_document(&home.root(), &Secrets::default()).unwrap();
    assert_eq!(again["removedReceipt"], false);
    assert_eq!(again["preservedSourceCount"], 0);
}

#[test]
fn an_absent_preset_reports_no_removed_material_or_passwords() {
    let home = Home::new();
    let secrets = Secrets {
        absent: true,
        owner_root: Some(home.root()),
        ..Secrets::default()
    };
    assert_eq!(
        remove_document(&home.root(), &secrets).unwrap(),
        json!({
        "schemaVersion": "arkdeck.signing-credential-removal/1", "state": "removed",
        "removedReceipt": false, "removedKeystorePassword": false, "removedKeyPassword": false,
        "removedManagedMaterial": false, "preservedSourceCount": 0})
    );
    assert_eq!(secrets.calls.lock().unwrap().len(), 4);
}

#[test]
fn an_unsafe_tracking_receipt_refuses_without_losing_its_envelope_accounts() {
    let home = Home::new();
    home.write("preset-v1.json", &home.receipt(None));
    let path = home.root().join("preset-v1.json");
    let before = fs::read(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o666)).unwrap();
    let secrets = Secrets::default();
    assert!(
        remove_document(&home.root(), &secrets)
            .unwrap_err()
            .to_string()
            .contains("cannot be read safely")
    );
    assert!(secrets.calls.lock().unwrap().is_empty());
    assert_eq!(fs::read(path).unwrap(), before);
}

#[test]
fn both_cli_spellings_preserve_swifts_plain_pinned_credential_refusal() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/signing-remove/cases.json");
    let cases: Vec<Value> = serde_json::from_slice(&fs::read(fixture).unwrap()).unwrap();
    assert_eq!(cases.len(), 6);
    for case in cases {
        let home = Home::new();
        home.write("credential-owner-v1.json", &case["ledger"]);
        let argv: Vec<&str> = case["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|arg| arg.as_str().unwrap())
            .collect();
        let result = std::process::Command::new(env!("CARGO_BIN_EXE_arkdeck"))
            .args(&argv)
            .env_clear()
            .env("CFFIXED_USER_HOME", &home.0)
            .env("HOME", &home.0)
            .output()
            .unwrap();
        assert_eq!(
            result.status.code(),
            case["exit"].as_i64().map(|code| code as i32),
            "{argv:?}"
        );
        assert_eq!(
            String::from_utf8(result.stdout).unwrap(),
            case["stdout"].as_str().unwrap(),
            "{argv:?}"
        );
        assert_eq!(
            String::from_utf8(result.stderr).unwrap(),
            case["stderr"].as_str().unwrap(),
            "{argv:?}"
        );
        assert_eq!(home.ledger(), case["ledger"]);
    }
}

#[test]
fn removal_accepts_no_paths_secrets_or_runtime_endpoint() {
    for extra in [
        vec!["--socket", "/tmp/untrusted"],
        vec!["--password", "not-a-secret"],
        vec!["--daemon", "/tmp/helper"],
        vec!["--control-request-id", "request-a"],
    ] {
        let args: Vec<String> = [vec!["runtime", "signing", "remove"], extra]
            .concat()
            .into_iter()
            .map(str::to_owned)
            .collect();
        assert!(arkdeck_cli::parse(&args).is_err());
    }
}
