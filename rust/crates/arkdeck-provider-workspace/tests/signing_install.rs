//! Installation transactions over private fixture files and an in-memory
//! secret store. No test uses the account's Keychain or installed Runtime.
#![cfg(target_os = "macos")]
use arkdeck_platform::Secret;
use arkdeck_provider_workspace::{
    SigningError,
    credential_owner::CredentialOwner,
    secret_envelope::{SecretPair, decode_envelope},
    signing_install::{SigningPresetConfiguration, SigningSecretInstallation},
    signing_preset::{SecretPresence, SigningPresetStore, SigningSecrets},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
struct Fixture {
    home: PathBuf,
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let home = PathBuf::from(format!(
            "/private/tmp/arkdeck-install-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&home).unwrap();
        Self {
            root: home.join("preset"),
            home,
        }
    }
    fn configuration(&self) -> SigningPresetConfiguration {
        let file = |name: &str, executable| {
            let path = self.home.join(name);
            fs::write(&path, b"public fixture").unwrap();
            fs::set_permissions(
                &path,
                fs::Permissions::from_mode(if executable { 0o700 } else { 0o600 }),
            )
            .unwrap();
            PathBuf::from(
                arkdeck_provider_workspace::foundation_resolved_path(path.to_str().unwrap())
                    .unwrap(),
            )
        };
        SigningPresetConfiguration {
            project_ref: "demo-app".into(),
            java_executable: file("java", true),
            signer_jar: file("signer.jar", false),
            keystore: file("source.p12", false),
            app_certificate: file("source.pem", false),
            signed_profile: file("source.p7b", false),
            key_alias: "release".into(),
            managed_material_directory: None,
        }
    }
    fn owner(&self) -> CredentialOwner {
        CredentialOwner::new(SigningPresetStore::new(&self.root))
    }
    fn receipt(&self) -> Value {
        serde_json::from_slice(&fs::read(self.root.join("preset-v1.json")).unwrap()).unwrap()
    }
    fn ledger(&self) -> Value {
        serde_json::from_slice(&fs::read(self.root.join("credential-owner-v1.json")).unwrap())
            .unwrap()
    }
    fn secrets(&self) -> Secrets {
        Secrets {
            root: self.root.clone(),
            values: Mutex::new(BTreeMap::new()),
            unreadable: Mutex::new(BTreeSet::new()),
            writes: AtomicUsize::new(0),
            fail_once: AtomicBool::new(false),
            fail_reads: AtomicBool::new(false),
            fail_all_writes: AtomicBool::new(false),
            block_publication: AtomicBool::new(false),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.home);
    }
}
struct Secrets {
    root: PathBuf,
    values: Mutex<BTreeMap<String, Secret>>,
    unreadable: Mutex<BTreeSet<String>>,
    writes: AtomicUsize,
    fail_once: AtomicBool,
    fail_reads: AtomicBool,
    fail_all_writes: AtomicBool,
    block_publication: AtomicBool,
}
impl SigningSecrets for Secrets {
    fn read(&self, account: &str) -> Result<Secret, SigningError> {
        if self.fail_reads.load(Ordering::SeqCst) {
            return Err(SigningError::SecretUnavailable("fixture unreadable".into()));
        }
        self.values
            .lock()
            .unwrap()
            .get(account)
            .map(|v| Secret::new(v.as_bytes().to_vec()))
            .ok_or_else(|| SigningError::SecretUnavailable("fixture absent".into()))
    }
    fn presence(&self, account: &str) -> SecretPresence {
        if self.unreadable.lock().unwrap().contains(account) {
            SecretPresence::Unreadable
        } else if self.values.lock().unwrap().contains_key(account) {
            SecretPresence::Present
        } else {
            SecretPresence::Absent
        }
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(Some("a".repeat(64)))
    }
}
impl SigningSecretInstallation for Secrets {
    fn set_envelope(&self, account: &str, bytes: &[u8]) -> Result<(), SigningError> {
        let ledger: Value =
            serde_json::from_slice(&fs::read(self.root.join("credential-owner-v1.json")).unwrap())
                .unwrap();
        assert_eq!(
            ledger["state"], "replacingSecrets",
            "durable intent precedes every secret write"
        );
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.values
            .lock()
            .unwrap()
            .insert(account.into(), Secret::new(bytes.to_vec()));
        if self.block_publication.swap(false, Ordering::SeqCst) {
            let _ = fs::remove_file(self.root.join("preset-v1.json"));
            fs::create_dir(self.root.join("preset-v1.json")).unwrap();
        }
        if self.fail_once.swap(false, Ordering::SeqCst)
            || self.fail_all_writes.load(Ordering::SeqCst)
        {
            Err(SigningError::SecretUnavailable(
                "fixture write failure".into(),
            ))
        } else {
            Ok(())
        }
    }
    fn remove_envelope(&self, account: &str) -> Result<bool, SigningError> {
        Ok(self.values.lock().unwrap().remove(account).is_some())
    }
}
fn pair(key: &[u8]) -> SecretPair {
    SecretPair {
        keystore: Secret::new(b"fixture-keystore".to_vec()),
        key: Secret::new(key.to_vec()),
    }
}
#[test]
fn installs_one_private_envelope_and_reuses_it_without_exposing_passwords() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let first = owner
        .install(&c, &pair(b"first-key"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let receipt = f.receipt();
    let account = receipt["secretEnvelopeAccount"].as_str().unwrap();
    assert_eq!(f.ledger()["credentialRef"], first.credential_ref);
    assert_eq!(secrets.values.lock().unwrap().len(), 1);
    assert_eq!(first.reference_count, 0);
    let second = owner
        .install(&c, &pair(b"second-key"), &secrets, "2026-09-26T00:01:00Z")
        .unwrap();
    assert_ne!(first.credential_ref, second.credential_ref);
    assert_eq!(f.receipt()["secretEnvelopeAccount"], account);
    let stored = secrets.read(account).unwrap();
    let decoded = decode_envelope(stored.as_bytes()).unwrap();
    assert_eq!(decoded.key.as_bytes(), b"second-key");
    for file in ["preset-v1.json", "credential-owner-v1.json"] {
        let bytes = fs::read(f.root.join(file)).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("second-key"));
    }
    assert_eq!(
        fs::metadata(f.root.join("preset-v1.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(fs::read(&c.keystore).unwrap(), b"public fixture");
}
#[test]
fn pinned_credentials_and_invalid_material_refuse_before_secret_writes() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let resource = owner
        .install(&c, &pair(b"first"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    owner
        .acquire(&resource.credential_ref, "preset-a", &secrets)
        .unwrap();
    let before = f.receipt();
    let writes = secrets.writes.load(Ordering::SeqCst);
    assert!(
        owner
            .install(&c, &pair(b"second"), &secrets, "later")
            .is_err()
    );
    assert_eq!(f.receipt(), before);
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    owner.release(&resource.credential_ref, "preset-a").unwrap();
    fs::set_permissions(&c.keystore, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(
        owner
            .install(&c, &pair(b"second"), &secrets, "later")
            .is_err()
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    assert_eq!(f.receipt(), before);
}
#[test]
fn a_failed_keychain_write_restores_the_previous_envelope_and_receipt() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    owner
        .install(&c, &pair(b"old-key"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let before = f.receipt();
    let ledger = f.ledger();
    let account = before["secretEnvelopeAccount"].as_str().unwrap();
    secrets.fail_once.store(true, Ordering::SeqCst);
    assert!(
        owner
            .install(&c, &pair(b"new-key"), &secrets, "later")
            .is_err()
    );
    assert_eq!(f.receipt(), before);
    assert_eq!(f.ledger(), ledger);
    assert_eq!(
        decode_envelope(secrets.read(account).unwrap().as_bytes())
            .unwrap()
            .key
            .as_bytes(),
        b"old-key"
    );
}
#[test]
fn a_missing_old_envelope_is_replaced_and_retained_for_explicit_cleanup() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let old = f.receipt()["secretEnvelopeAccount"]
        .as_str()
        .unwrap()
        .to_owned();
    secrets.values.lock().unwrap().remove(&old);
    owner
        .install(&c, &pair(b"new"), &secrets, "2026-09-26T00:01:00Z")
        .unwrap();
    assert_ne!(f.receipt()["secretEnvelopeAccount"], old);
    assert_eq!(f.receipt()["supersededEnvelopeAccounts"], json!([old]));
}
#[test]
fn publication_failure_removes_new_envelope_and_retains_recovery_marker() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    secrets.block_publication.store(true, Ordering::SeqCst);
    assert!(
        f.owner()
            .install(&c, &pair(b"new"), &secrets, "2026-09-26T00:00:00Z")
            .is_err()
    );
    assert!(secrets.values.lock().unwrap().is_empty());
    assert_eq!(f.ledger()["state"], "replacingSecrets");
    // A new process refuses the still-unreadable receipt, rather than
    // adopting a credential that was never durably installed.
    assert!(f.owner().current().is_err());
    fs::remove_dir(f.root.join("preset-v1.json")).unwrap();
    f.owner()
        .install(&c, &pair(b"retry"), &secrets, "2026-09-26T00:01:00Z")
        .unwrap();
    assert_eq!(f.ledger()["state"], "stable");
    assert_eq!(secrets.values.lock().unwrap().len(), 1);
}

#[test]
fn symbolic_link_signing_material_is_not_normalized_into_admission() {
    let f = Fixture::new();
    let mut c = f.configuration();
    let secrets = f.secrets();
    let link = f.home.join("linked.p12");
    std::os::unix::fs::symlink(&c.keystore, &link).unwrap();
    c.keystore = PathBuf::from(link.to_str().unwrap().strip_prefix("/private").unwrap());
    assert!(
        f.owner()
            .install(&c, &pair(b"fixture"), &secrets, "2026-09-26T00:00:00Z")
            .is_err()
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), 0);
    assert!(!f.root.join("preset-v1.json").exists());
}

#[test]
fn rekey_reuses_envelope_preserving_receipt_bytes_and_public_reference() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let first = owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let before = fs::read(f.root.join("preset-v1.json")).unwrap();
    let (created, current) = owner
        .replace_secret_envelope(&pair(b"corrected"), None, &secrets)
        .unwrap();
    assert!(!created);
    assert_eq!(first, current);
    assert_eq!(fs::read(f.root.join("preset-v1.json")).unwrap(), before);
    let account = f.receipt()["secretEnvelopeAccount"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        decode_envelope(secrets.read(&account).unwrap().as_bytes())
            .unwrap()
            .key
            .as_bytes(),
        b"corrected"
    );
    let (_, changed) = owner
        .replace_secret_envelope(&pair(b"corrected"), Some("new-alias"), &secrets)
        .unwrap();
    assert_ne!(changed.credential_ref, first.credential_ref);
    assert_eq!(changed.installed_at_utc, first.installed_at_utc);
    assert_eq!(
        f.receipt()["keystore"],
        serde_json::from_slice::<Value>(&before).unwrap()["keystore"]
    );
}

#[test]
fn rekey_missing_envelope_keeps_stale_account_for_cleanup() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let first = owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let old = f.receipt()["secretEnvelopeAccount"].clone();
    secrets.values.lock().unwrap().clear();
    let (created, current) = owner
        .replace_secret_envelope(&pair(b"corrected"), None, &secrets)
        .unwrap();
    assert!(created);
    assert_eq!(current, first);
    assert_ne!(f.receipt()["secretEnvelopeAccount"], old);
    assert_eq!(f.receipt()["supersededEnvelopeAccounts"], json!([old]));
}

#[test]
fn rekey_refuses_pins_and_restores_previous_secret_after_failed_set() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let first = owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    owner
        .acquire(&first.credential_ref, "preset-a", &secrets)
        .unwrap();
    let writes = secrets.writes.load(Ordering::SeqCst);
    assert!(
        owner
            .replace_secret_envelope(&pair(b"bad"), None, &secrets)
            .is_err()
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    owner.release(&first.credential_ref, "preset-a").unwrap();
    let before = f.receipt();
    secrets.fail_once.store(true, Ordering::SeqCst);
    assert!(
        owner
            .replace_secret_envelope(&pair(b"bad"), Some("changed"), &secrets)
            .is_err()
    );
    assert_eq!(before, f.receipt());
    let account = before["secretEnvelopeAccount"].as_str().unwrap();
    assert_eq!(
        decode_envelope(secrets.read(account).unwrap().as_bytes())
            .unwrap()
            .key
            .as_bytes(),
        b"old"
    );
    assert_eq!(f.ledger()["state"], "stable");
}

#[test]
fn rekey_requires_old_value_before_write_and_reports_incomplete_rollback() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    let writes = secrets.writes.load(Ordering::SeqCst);
    secrets.fail_reads.store(true, Ordering::SeqCst);
    assert!(
        owner
            .replace_secret_envelope(&pair(b"new"), None, &secrets)
            .is_err()
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    secrets.fail_reads.store(false, Ordering::SeqCst);
    secrets.fail_all_writes.store(true, Ordering::SeqCst);
    let error = owner
        .replace_secret_envelope(&pair(b"new"), None, &secrets)
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("Keychain rollback was incomplete")
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes + 2);
}

#[test]
fn rekey_receipt_failure_restores_old_value_or_removes_new_item() {
    for missing in [false, true] {
        let f = Fixture::new();
        let c = f.configuration();
        let secrets = f.secrets();
        let owner = f.owner();
        owner
            .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
            .unwrap();
        let account = f.receipt()["secretEnvelopeAccount"]
            .as_str()
            .unwrap()
            .to_owned();
        if missing {
            secrets.values.lock().unwrap().clear();
        }
        secrets.block_publication.store(true, Ordering::SeqCst);
        assert!(
            owner
                .replace_secret_envelope(&pair(b"new"), Some("changed"), &secrets)
                .is_err()
        );
        assert_eq!(f.ledger()["state"], "replacingSecrets");
        if missing {
            assert!(secrets.values.lock().unwrap().is_empty());
        } else {
            assert_eq!(
                decode_envelope(secrets.read(&account).unwrap().as_bytes())
                    .unwrap()
                    .key
                    .as_bytes(),
                b"old"
            );
        }
    }
}

#[test]
fn guarded_replacement_does_not_bypass_existing_preset_pins() {
    let f = Fixture::new();
    let c = f.configuration();
    let secrets = f.secrets();
    let owner = f.owner();
    let resource = owner
        .install(&c, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
        .unwrap();
    owner
        .acquire(&resource.credential_ref, "preset-a", &secrets)
        .unwrap();
    let mut ledger = f.ledger();
    ledger["state"] = json!("replacingSecrets");
    ledger["pendingEnvelopeAccounts"] = json!([f.receipt()["secretEnvelopeAccount"]]);
    let bytes = serde_json::to_vec(&ledger).unwrap();
    fs::write(f.root.join("credential-owner-v1.json"), &bytes).unwrap();
    let writes = secrets.writes.load(Ordering::SeqCst);
    assert!(owner.install(&c, &pair(b"new"), &secrets, "later").is_err());
    assert!(
        owner
            .replace_secret_envelope(&pair(b"new"), None, &secrets)
            .is_err()
    );
    assert_eq!(secrets.writes.load(Ordering::SeqCst), writes);
    assert_eq!(
        fs::read(f.root.join("credential-owner-v1.json")).unwrap(),
        bytes
    );
    assert!(owner.current().is_err());
}
