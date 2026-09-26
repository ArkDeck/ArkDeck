//! Explicit maintenance installation. Passwords enter only as wiped buffers;
//! the Runtime's read-only secret interface gains no write methods.
use crate::secret_envelope::{SecretPair, encode_envelope, validate_secret};
use crate::signing_preset::{
    DEFAULT_PRESET_ID, KEYCHAIN_ACCESS_SCHEMA, RECEIPT_FILE, RECEIPT_SCHEMA, SIGNING_ALGORITHM,
    SigningPresetReceipt, SigningPresetStore, SigningSecrets, is_identifier, is_key_alias, is_uuid,
};
use crate::{SigningError, measure};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use std::{collections::BTreeSet, path::PathBuf};

pub trait SigningSecretInstallation: SigningSecrets {
    fn set_envelope(&self, account: &str, bytes: &[u8]) -> Result<(), SigningError>;
    fn remove_envelope(&self, account: &str) -> Result<bool, SigningError>;
}

/// Public configuration; no password, arbitrary Keychain scope or daemon
/// fingerprint can be supplied through this document.
pub struct SigningPresetConfiguration {
    pub project_ref: String,
    pub java_executable: PathBuf,
    pub signer_jar: PathBuf,
    pub keystore: PathBuf,
    pub app_certificate: PathBuf,
    pub signed_profile: PathBuf,
    pub key_alias: String,
    pub managed_material_directory: Option<PathBuf>,
}

pub(crate) fn envelope_account(account: &str) -> bool {
    account
        .strip_prefix(&format!("{DEFAULT_PRESET_ID}|secret-envelope-"))
        .is_some_and(is_uuid)
}

pub(crate) fn new_envelope_account() -> Result<String, SigningError> {
    let mut bytes = arkdeck_platform::random_bytes::<16>()
        .map_err(|_| SigningError::io("cannot generate signing envelope identity"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{DEFAULT_PRESET_ID}|secret-envelope-{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// Public account tracking, persisted by the owner before secret writes.
pub(crate) struct ReplacementTracking<'a> {
    pub prior: &'a [String],
    pub stage: &'a mut dyn FnMut(&str) -> Result<(), SigningError>,
}

/// Only the credential owner may call this, after persisting `replacingSecrets`.
pub(crate) fn install_preset(
    store: &SigningPresetStore,
    directory: &HostDirectory,
    configuration: &SigningPresetConfiguration,
    passwords: &SecretPair,
    secrets: &dyn SigningSecretInstallation,
    installed_at_utc: &str,
    tracking: ReplacementTracking<'_>,
) -> Result<SigningPresetReceipt, SigningError> {
    if !is_identifier(&configuration.project_ref) || !is_key_alias(&configuration.key_alias) {
        return Err(SigningError::invalid(
            "project reference or key alias is malformed",
        ));
    }
    validate_secret(passwords.keystore.as_bytes())?;
    validate_secret(passwords.key.as_bytes())?;
    let measured = |path: &PathBuf, role: &str, executable, private| {
        let path = path.to_str().ok_or_else(|| {
            SigningError::unsafe_file(format!("{role} path is not canonical absolute"))
        })?;
        measure(path, role, executable, private)
    };
    let mut receipt = SigningPresetReceipt {
        schema_version: RECEIPT_SCHEMA.into(),
        installed_at_utc: installed_at_utc.into(),
        preset_id: DEFAULT_PRESET_ID.into(),
        project_ref: configuration.project_ref.clone(),
        java_executable: measured(&configuration.java_executable, "java", true, false)?,
        signer_jar: measured(&configuration.signer_jar, "signer JAR", false, false)?,
        keystore: measured(&configuration.keystore, "keystore", false, true)?,
        app_certificate: measured(
            &configuration.app_certificate,
            "app certificate",
            false,
            false,
        )?,
        signed_profile: measured(
            &configuration.signed_profile,
            "signed profile",
            false,
            false,
        )?,
        key_alias: configuration.key_alias.clone(),
        signing_algorithm: SIGNING_ALGORITHM.into(),
        keystore_password_account: format!("{DEFAULT_PRESET_ID}|keystore"),
        key_password_account: format!("{DEFAULT_PRESET_ID}|key"),
        secret_envelope_account: Some(new_envelope_account()?),
        superseded_envelope_accounts: None,
        trusted_daemon_application_sha256: None,
        keychain_access_schema: Some(KEYCHAIN_ACCESS_SCHEMA.into()),
        managed_material_directory: configuration
            .managed_material_directory
            .as_ref()
            .map(|p| {
                p.to_str()
                    .map(str::to_owned)
                    .ok_or_else(|| SigningError::invalid("managed material path is not UTF-8"))
            })
            .transpose()?,
    };
    // All public configuration must validate before any external secret write.
    receipt.validate_fields(DEFAULT_PRESET_ID, store.root())?;
    let previous_bytes = match directory.read(RECEIPT_FILE, 1024 * 1024) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => {
            return Err(SigningError::unsafe_file(
                "signing receipt cannot be read safely for installation",
            ));
        }
    };
    let previous = previous_bytes
        .as_deref()
        .and_then(crate::signing_removal::decode_for_maintenance);
    receipt.trusted_daemon_application_sha256 = secrets.trusted_daemon_fingerprint()?;
    let reusable = previous
        .as_ref()
        .filter(|old| {
            old.preset_id == DEFAULT_PRESET_ID
                && old.keychain_access_schema.as_deref() == Some(KEYCHAIN_ACCESS_SCHEMA)
        })
        .and_then(|old| old.secret_envelope_account.as_deref())
        .filter(|account| envelope_account(account) && secrets.contains(account));
    if let Some(account) = reusable {
        receipt.secret_envelope_account = Some(account.into());
    }
    let account = receipt.secret_envelope_account.as_deref().unwrap();
    let mut superseded: BTreeSet<String> = previous
        .as_ref()
        .and_then(|old| old.superseded_envelope_accounts.clone())
        .unwrap_or_default()
        .into_iter()
        .filter(|a| envelope_account(a))
        .collect();
    if let Some(old) = previous
        .as_ref()
        .filter(|old| old.preset_id == DEFAULT_PRESET_ID)
        .and_then(|old| old.secret_envelope_account.as_ref())
        && old != account
        && envelope_account(old)
    {
        superseded.insert(old.clone());
    }
    superseded.extend(tracking.prior.iter().cloned());
    superseded.remove(account);
    if !superseded.is_empty() {
        receipt.superseded_envelope_accounts = Some(superseded.into_iter().collect());
    }
    let envelope = encode_envelope(passwords.keystore.as_bytes(), passwords.key.as_bytes());
    let previous_secret = reusable.map(|account| secrets.read(account)).transpose()?;
    let bytes = crate::canonical_json::encode(
        &serde_json::to_value(&receipt)
            .map_err(|_| SigningError::io("signing receipt cannot be encoded"))?,
    )
    .ok_or_else(|| SigningError::io("signing receipt cannot be encoded"))?;
    (tracking.stage)(account)?;
    let restore = || {
        if let Some(previous) = &previous_secret {
            secrets.set_envelope(account, previous.as_bytes())
        } else {
            secrets.remove_envelope(account).map(|_| ())
        }
        .map_err(|_| {
            SigningError::MaintenanceUncertain("cannot prove signing secret restoration".into())
        })?;
        prove_receipt_unchanged(directory, previous_bytes.as_deref())
    };
    if let Err(error) = secrets.set_envelope(account, envelope.as_bytes()) {
        restore()?;
        return Err(error);
    }
    let publish = || -> Result<(), DocumentPublishError> {
        let root = store.root().canonicalize()?;
        directory.validate_path(&root)?;
        publish_receipt(directory, &bytes)
    };
    if let Err(error) = publish() {
        match error {
            DocumentPublishError::BeforePublication(_) => {
                restore()?;
                return Err(SigningError::io("cannot durably publish signing receipt"));
            }
            DocumentPublishError::OutcomeUnknown(_) => {
                // Never pair a possibly new receipt with restored old secrets,
                // or delete the only envelope it may name. Owner recovery
                // remains guarded until explicit maintenance replaces/removes it.
                return Err(SigningError::MaintenanceUncertain(
                    "signing receipt publication could not be proved durable".into(),
                ));
            }
        }
    }
    Ok(receipt)
}

/// Shared publication boundary keeps the platform's before/after distinction.
pub(crate) fn publish_receipt(
    directory: &HostDirectory,
    bytes: &[u8],
) -> Result<(), DocumentPublishError> {
    #[cfg(test)]
    if PUBLICATION_FAILURE.with(|fail| fail.get()) == 3 {
        PUBLICATION_FAILURE.with(|fail| fail.set(0));
        return Err(DocumentPublishError::BeforePublication(
            std::io::Error::other("fixture temporary write failure"),
        ));
    }
    #[cfg(test)]
    if PUBLICATION_FAILURE.with(|fail| fail.get()) == 2 {
        PUBLICATION_FAILURE.with(|fail| fail.set(0));
        return Err(DocumentPublishError::OutcomeUnknown(std::io::Error::other(
            "fixture rename failure",
        )));
    }
    directory.publish_document(RECEIPT_FILE, bytes, 1024 * 1024)?;
    #[cfg(test)]
    if PUBLICATION_FAILURE.with(|fail| fail.replace(0)) == 1 {
        return Err(DocumentPublishError::OutcomeUnknown(std::io::Error::other(
            "fixture directory synchronization failure",
        )));
    }
    Ok(())
}

#[cfg(test)]
thread_local! {
    pub(crate) static PUBLICATION_FAILURE: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
}

pub(crate) fn prove_receipt_unchanged(
    directory: &HostDirectory,
    previous: Option<&[u8]>,
) -> Result<(), SigningError> {
    let matches = match directory.read(RECEIPT_FILE, 1024 * 1024) {
        Ok(bytes) => previous == Some(bytes.as_slice()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => previous.is_none(),
        Err(_) => false,
    };
    if matches {
        Ok(())
    } else {
        Err(SigningError::MaintenanceUncertain(
            "cannot prove signing receipt restoration".into(),
        ))
    }
}

#[cfg(test)]
mod publication_tests {
    use super::*;
    use crate::{credential_owner::CredentialOwner, signing_preset::SecretPresence};
    use arkdeck_platform::Secret;
    use std::{
        collections::BTreeMap,
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt},
        sync::Mutex,
    };
    #[derive(Default)]
    struct Secrets(Mutex<BTreeMap<String, Secret>>);
    impl SigningSecrets for Secrets {
        fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
            Ok(Some("a".repeat(64)))
        }
        fn read(&self, account: &str) -> Result<Secret, SigningError> {
            self.0
                .lock()
                .unwrap()
                .get(account)
                .cloned()
                .ok_or_else(|| SigningError::secret("absent"))
        }
        fn presence(&self, account: &str) -> SecretPresence {
            if self.0.lock().unwrap().contains_key(account) {
                SecretPresence::Present
            } else {
                SecretPresence::Absent
            }
        }
    }
    impl SigningSecretInstallation for Secrets {
        fn set_envelope(&self, account: &str, value: &[u8]) -> Result<(), SigningError> {
            self.0
                .lock()
                .unwrap()
                .insert(account.into(), Secret::from_slice(value));
            Ok(())
        }
        fn remove_envelope(&self, account: &str) -> Result<bool, SigningError> {
            Ok(self.0.lock().unwrap().remove(account).is_some())
        }
    }
    impl crate::signing_removal::SigningSecretRemoval for Secrets {
        fn remove_current(&self, account: &str) -> Result<bool, SigningError> {
            self.remove_envelope(account)
        }
        fn remove_legacy(&self, _: &str) -> Result<bool, SigningError> {
            Ok(false)
        }
    }
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = PathBuf::from(format!(
                "/private/tmp/arkdeck-signing-outcome-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn configuration(&self) -> SigningPresetConfiguration {
            let file = |name, executable| {
                let path = self.0.join(name);
                fs::write(&path, b"fixture material").unwrap();
                fs::set_permissions(
                    &path,
                    fs::Permissions::from_mode(if executable { 0o700 } else { 0o600 }),
                )
                .unwrap();
                PathBuf::from(crate::foundation_resolved_path(path.to_str().unwrap()).unwrap())
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
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn pair(value: &[u8]) -> SecretPair {
        SecretPair {
            keystore: Secret::from_slice(value),
            key: Secret::from_slice(value),
        }
    }

    #[test]
    fn unknown_publication_quarantines_initial_and_reused_envelopes_until_explicit_repair() {
        for prior_install in [false, true] {
            for failure in [1, 2] {
                let f = Fixture::new();
                let root = f.0.join("preset");
                let mut config = f.configuration();
                let secrets = Secrets::default();
                let owner = CredentialOwner::new(SigningPresetStore::new(&root));
                if prior_install {
                    owner
                        .install(&config, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
                        .unwrap();
                }
                config.key_alias = "replacement".into();
                PUBLICATION_FAILURE.with(|fail| fail.set(failure));
                let error = owner
                    .install(&config, &pair(b"new"), &secrets, "2026-09-26T01:00:00Z")
                    .unwrap_err();
                assert!(matches!(error, SigningError::MaintenanceUncertain(_)));
                let ledger: serde_json::Value = serde_json::from_slice(
                    &fs::read(root.join(crate::credential_owner::LEDGER_FILE)).unwrap(),
                )
                .unwrap();
                assert_eq!(ledger["state"], "replacingSecrets");
                assert_eq!(
                    ledger["pendingEnvelopeAccounts"].as_array().unwrap().len(),
                    1
                );
                assert!(owner.current().is_err());
                assert!(
                    CredentialOwner::new(SigningPresetStore::new(&root))
                        .current()
                        .is_err()
                );
                assert_eq!(secrets.0.lock().unwrap().len(), 1);
                // A subsequent inability to read the receipt cannot turn
                // unknown publication into a successful public adoption.
                if failure == 1 {
                    let receipt_path = root.join(RECEIPT_FILE);
                    let bytes = fs::read(&receipt_path).unwrap();
                    fs::remove_file(&receipt_path).unwrap();
                    fs::create_dir(&receipt_path).unwrap();
                    assert!(owner.current().is_err());
                    fs::remove_dir(&receipt_path).unwrap();
                    fs::write(&receipt_path, bytes).unwrap();
                    fs::set_permissions(&receipt_path, fs::Permissions::from_mode(0o600)).unwrap();
                }
                for value in secrets.0.lock().unwrap().values() {
                    assert_eq!(
                        crate::secret_envelope::decode_envelope(value.as_bytes())
                            .unwrap()
                            .key
                            .as_bytes(),
                        b"new"
                    );
                }
                // Explicit removal can clean even an account whose receipt
                // never landed, using only the durable pending tracking.
                if !prior_install && failure == 2 {
                    owner.remove(&secrets).unwrap();
                    assert!(secrets.0.lock().unwrap().is_empty());
                } else {
                    let recovered = owner
                        .install(
                            &config,
                            &pair(b"repaired"),
                            &secrets,
                            "2026-09-26T02:00:00Z",
                        )
                        .unwrap();
                    assert_eq!(owner.current().unwrap(), recovered);
                    owner.remove(&secrets).unwrap();
                    assert!(secrets.0.lock().unwrap().is_empty());
                }
            }
        }
    }

    #[test]
    fn prepublication_failure_restores_proved_previous_state() {
        for prior_install in [false, true] {
            let f = Fixture::new();
            let root = f.0.join("preset");
            let config = f.configuration();
            let secrets = Secrets::default();
            let owner = CredentialOwner::new(SigningPresetStore::new(&root));
            let prior = if prior_install {
                Some(
                    owner
                        .install(&config, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
                        .unwrap(),
                )
            } else {
                None
            };
            PUBLICATION_FAILURE.with(|fail| fail.set(3));
            assert!(matches!(
                owner.install(&config, &pair(b"new"), &secrets, "2026-09-26T01:00:00Z"),
                Err(SigningError::IoFailure(_))
            ));
            let ledger: serde_json::Value = serde_json::from_slice(
                &fs::read(root.join(crate::credential_owner::LEDGER_FILE)).unwrap(),
            )
            .unwrap();
            assert_eq!(ledger["state"], "stable");
            assert!(ledger.get("pendingEnvelopeAccounts").is_none());
            assert_eq!(owner.current().ok(), prior);
            assert_eq!(secrets.0.lock().unwrap().len(), usize::from(prior_install));
            for value in secrets.0.lock().unwrap().values() {
                assert_eq!(
                    crate::secret_envelope::decode_envelope(value.as_bytes())
                        .unwrap()
                        .key
                        .as_bytes(),
                    b"old"
                );
            }
        }
    }

    #[test]
    fn unknown_rekey_keeps_new_secret_and_blocks_restart_resolution() {
        for failure in [1, 2] {
            let f = Fixture::new();
            let root = f.0.join("preset");
            let config = f.configuration();
            let secrets = Secrets::default();
            let owner = CredentialOwner::new(SigningPresetStore::new(&root));
            owner
                .install(&config, &pair(b"old"), &secrets, "2026-09-26T00:00:00Z")
                .unwrap();
            PUBLICATION_FAILURE.with(|fail| fail.set(failure));
            assert!(matches!(
                owner.replace_secret_envelope(
                    &owner
                        .store()
                        .load_validated("openharmony-release@1", false, &secrets)
                        .unwrap(),
                    &pair(b"new"),
                    Some("changed"),
                    &secrets
                ),
                Err(SigningError::MaintenanceUncertain(_))
            ));
            assert!(owner.current().is_err());
            assert!(
                CredentialOwner::new(SigningPresetStore::new(&root))
                    .current()
                    .is_err()
            );
            let (_, repaired) = owner
                .replace_secret_envelope(
                    &owner
                        .store()
                        .load_validated("openharmony-release@1", false, &secrets)
                        .unwrap(),
                    &pair(b"repaired"),
                    Some("changed"),
                    &secrets,
                )
                .unwrap();
            assert_eq!(owner.current().unwrap(), repaired);
        }
    }
}
