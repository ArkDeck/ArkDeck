//! Swift `OpenHarmonySigningCredentialOwner`: the path-free identity of the
//! one installed signing credential and the ledger of the workspace presets
//! that pin it (TASK-XPA-015, M3).
//!
//! The ledger, `credential-owner-v1.json`, lives beside the receipt in the
//! private preset root, under the owner's lock. A workspace signing preset
//! names the credential by its content reference —
//! `credential:sha256-<digest of the receipt's file identities>` — and the
//! Runtime resolves a preset's credential only while the ledger names that
//! very reference and the preset among its owners, and the receipt still
//! measures as recorded. A ledger that does not match the installed receipt
//! is refused, never repaired from a guess.
//!
//! The Runtime resolves and pins credentials here. Explicit CLI removal also
//! holds this owner lock and refuses credentials with active preset owners.
use crate::SigningError;
use crate::signing_preset::{
    DEFAULT_PRESET_ID, SigningPresetReceipt, SigningPresetStore, SigningSecrets,
};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::io;
use std::path::PathBuf;
use std::time::Duration;

pub const LEDGER_FILE: &str = "credential-owner-v1.json";
const LOCK_FILE: &str = ".credential-owner.lock";
const LEDGER_SCHEMA: &str = "arkdeck.signing-credential-owner/1";
const CONTENT_SCHEMA: &str = "arkdeck.signing-credential-content/1";
const MAX_LEDGER_BYTES: usize = 256 * 1024;
const MAX_OWNERS: usize = 4_096;

/// Swift `OpenHarmonySigningCredentialResource`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CredentialResource {
    pub credential_ref: String,
    pub project_ref: String,
    pub preset_id: String,
    pub installed_at_utc: String,
    pub reference_count: usize,
}

/// Swift's private `Ledger`, key for key; a stable owner of no credential
/// omits the reference, as Swift's synthesized encoding does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ledger {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    state: String,
    #[serde(
        rename = "credentialRef",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    credential_ref: Option<String>,
    #[serde(rename = "presetOwners")]
    preset_owners: Vec<String>,
    #[serde(
        rename = "pendingEnvelopeAccounts",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pending_envelope_accounts: Vec<String>,
    #[serde(
        rename = "pendingMaterialDirectories",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pending_material_directories: Vec<String>,
}

impl Ledger {
    fn stable(credential_ref: Option<String>, preset_owners: Vec<String>) -> Self {
        Self {
            schema_version: LEDGER_SCHEMA.into(),
            state: "stable".into(),
            credential_ref,
            preset_owners,
            pending_envelope_accounts: Vec::new(),
            pending_material_directories: Vec::new(),
        }
    }

    /// Swift's `CanonicalJSONEncoders.canonical()` spelling: sorted keys, no
    /// whitespace, the solidus unescaped.
    fn encode(&self) -> Result<Vec<u8>, SigningError> {
        let value = serde_json::to_value(self)
            .map_err(|_| SigningError::io("signing credential ledger cannot be encoded"))?;
        crate::canonical_json::encode_compact(&value)
            .ok_or_else(|| SigningError::io("signing credential ledger cannot be encoded"))
    }
}

/// Swift `AgentExecutionIntent.validIdentifier`.
fn valid_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// Swift `OpenHarmonySigningCredentialOwner.reference(for:)`: the content
/// reference of an installed receipt — its installation, preset, project,
/// every pinned file's digest and length, key alias and algorithm, never a
/// path or a Keychain account.
pub fn credential_reference(receipt: &SigningPresetReceipt) -> Result<String, SigningError> {
    let identity = json!({
        "schemaVersion": CONTENT_SCHEMA,
        "installedAtUTC": receipt.installed_at_utc,
        "presetID": receipt.preset_id,
        "projectRef": receipt.project_ref,
        "javaSHA256": receipt.java_executable.sha256,
        "javaByteCount": receipt.java_executable.byte_count,
        "signerJARSHA256": receipt.signer_jar.sha256,
        "signerJARByteCount": receipt.signer_jar.byte_count,
        "keystoreSHA256": receipt.keystore.sha256,
        "keystoreByteCount": receipt.keystore.byte_count,
        "appCertificateSHA256": receipt.app_certificate.sha256,
        "appCertificateByteCount": receipt.app_certificate.byte_count,
        "signedProfileSHA256": receipt.signed_profile.sha256,
        "signedProfileByteCount": receipt.signed_profile.byte_count,
        "keyAlias": receipt.key_alias,
        "signingAlgorithm": receipt.signing_algorithm,
    });
    let bytes = crate::canonical_json::encode_compact(&identity)
        .ok_or_else(|| SigningError::io("signing credential identity cannot be encoded"))?;
    Ok(format!(
        "credential:sha256-{}",
        crate::file_identity::hex(&Sha256::digest(bytes))
    ))
}

/// Swift `OpenHarmonySigningCredentialOwner` over one preset store.
pub struct CredentialOwner {
    store: SigningPresetStore,
    root: PathBuf,
}

/// The owner's lock and its root, held for one transaction.
struct Held {
    directory: HostDirectory,
    _lock: arkdeck_platform::HostReadLock,
}

impl CredentialOwner {
    pub fn new(store: SigningPresetStore) -> Self {
        let root = store.root().to_path_buf();
        Self { store, root }
    }

    pub fn store(&self) -> &SigningPresetStore {
        &self.store
    }

    /// Swift `current()`: the installed credential and how many presets pin
    /// it.
    pub fn current(&self) -> Result<CredentialResource, SigningError> {
        self.with_lock(|held| {
            let (ledger, receipt) = self.load_and_recover(held)?;
            let (Some(receipt), Some(reference)) = (receipt, ledger.credential_ref) else {
                return Err(SigningError::receipt("signing credential is not installed"));
            };
            Ok(CredentialResource {
                credential_ref: reference,
                project_ref: receipt.project_ref,
                preset_id: receipt.preset_id,
                installed_at_utc: receipt.installed_at_utc,
                reference_count: ledger.preset_owners.len(),
            })
        })
    }

    /// Swift `resolve(_:owner:requireSecrets:)`: the receipt a stable ledger
    /// names by exactly `reference`, pinned by `owner` when one is named, the
    /// receipt validated again — its secrets present when required.
    pub fn resolve(
        &self,
        reference: &str,
        owner: Option<&str>,
        require_secrets: bool,
        secrets: &dyn SigningSecrets,
    ) -> Result<SigningPresetReceipt, SigningError> {
        self.with_lock(|held| {
            let (ledger, receipt) = self.load_and_recover(held)?;
            let receipt = match receipt {
                Some(receipt)
                    if ledger.state == "stable"
                        && ledger.credential_ref.as_deref() == Some(reference) =>
                {
                    receipt
                }
                _ => {
                    return Err(SigningError::receipt(
                        "signing credential reference is absent or stale",
                    ));
                }
            };
            if let Some(owner) = owner {
                validate_owner(owner)?;
                if !ledger.preset_owners.iter().any(|held| held == owner) {
                    return Err(SigningError::receipt(
                        "workspace preset does not own the signing credential",
                    ));
                }
            }
            let validated =
                self.store
                    .load_validated(&receipt.preset_id, require_secrets, secrets)?;
            self.revalidate(held)?;
            if validated != receipt {
                return Err(SigningError::drift("signing credential receipt"));
            }
            Ok(validated)
        })
    }

    /// Swift `acquire(_:owner:)`: `owner` pins the credential `reference`
    /// names, once its receipt and secrets validate.
    pub fn acquire(
        &self,
        reference: &str,
        owner: &str,
        secrets: &dyn SigningSecrets,
    ) -> Result<(), SigningError> {
        validate_owner(owner)?;
        self.with_lock(|held| {
            let (mut ledger, receipt) = self.load_and_recover(held)?;
            let receipt = match receipt {
                Some(receipt)
                    if ledger.state == "stable"
                        && ledger.credential_ref.as_deref() == Some(reference) =>
                {
                    receipt
                }
                _ => {
                    return Err(SigningError::receipt(
                        "signing credential reference is absent or stale",
                    ));
                }
            };
            self.store
                .load_validated(&receipt.preset_id, true, secrets)?;
            self.revalidate(held)?;
            if !ledger.preset_owners.iter().any(|held| held == owner) {
                if ledger.preset_owners.len() >= MAX_OWNERS {
                    return Err(SigningError::invalid(
                        "signing credential workspace preset reference limit is reached",
                    ));
                }
                ledger.preset_owners.push(owner.to_owned());
                ledger.preset_owners.sort();
                self.save(held, &ledger)?;
            }
            Ok(())
        })
    }

    /// Swift `release(_:owner:)`: `owner`'s pin removed; an absent pin is
    /// left absent.
    pub fn release(&self, reference: &str, owner: &str) -> Result<(), SigningError> {
        validate_owner(owner)?;
        self.with_lock(|held| {
            let (mut ledger, _) = self.load_and_recover(held)?;
            if ledger.state != "stable" || ledger.credential_ref.as_deref() != Some(reference) {
                return Err(SigningError::receipt(
                    "signing credential reference is absent or stale",
                ));
            }
            let before = ledger.preset_owners.len();
            ledger.preset_owners.retain(|held| held != owner);
            if ledger.preset_owners.len() != before {
                self.save(held, &ledger)?;
            }
            Ok(())
        })
    }

    /// Swift `releaseOwners(absentFrom:)`: every owner the workspace preset
    /// store no longer carries is released; the released references come
    /// back.
    pub fn release_owners(
        &self,
        registered: &BTreeSet<String>,
    ) -> Result<Vec<String>, SigningError> {
        self.with_lock(|held| {
            let (mut ledger, _) = self.load_and_recover(held)?;
            let orphaned: Vec<String> = ledger
                .preset_owners
                .iter()
                .filter(|owner| !registered.contains(*owner))
                .cloned()
                .collect();
            if orphaned.is_empty() {
                return Ok(orphaned);
            }
            ledger
                .preset_owners
                .retain(|owner| registered.contains(owner));
            self.save(held, &ledger)?;
            Ok(orphaned)
        })
    }

    /// Swift `remove`: an explicit uninstall may clear a broken receipt,
    /// but must never remove a credential pinned by a workspace preset.
    pub fn remove(
        &self,
        secrets: &dyn crate::signing_removal::SigningSecretRemoval,
    ) -> Result<crate::signing_removal::SigningPresetRemoval, SigningError> {
        self.with_lock(|held| {
            // Intentionally do not validate/adopt the receipt: uninstall is
            // also the exit from an unreadable or interrupted installation.
            let mut ledger = self.ledger_for_mutation(held)?;
            ledger.state = if ledger.pending_envelope_accounts.is_empty()
                && ledger.pending_material_directories.is_empty()
            {
                "removing"
            } else {
                "removingSecrets"
            }
            .into();
            self.save(held, &ledger)?;
            let result = (|| {
                for account in &ledger.pending_envelope_accounts {
                    secrets.remove_current(account)?;
                }
                crate::signing_removal::remove_preset(&self.store, secrets).and_then(
                    |mut removal| {
                        for path in &ledger.pending_material_directories {
                            removal.removed_managed_material |=
                                crate::sdk_release::remove_material(std::path::Path::new(path))?;
                        }
                        self.save(held, &Ledger::stable(None, Vec::new()))?;
                        Ok(removal)
                    },
                )
            })();
            if result.is_err() {
                // Settle only the receipt that actually remains. A receipt
                // that cannot be validated leaves `removing` durable.
                let _ = self.recover_mutation(held, &ledger);
            }
            result
        })
    }

    /// Swift `replace { store.install(...) }`: preserve a durable mutation
    /// marker until the published receipt validates with its secret present.
    pub fn install(
        &self,
        configuration: &crate::signing_install::SigningPresetConfiguration,
        passwords: &crate::secret_envelope::SecretPair,
        secrets: &dyn crate::signing_install::SigningSecretInstallation,
        installed_at_utc: &str,
    ) -> Result<CredentialResource, SigningError> {
        self.with_lock(|held| {
            let mut ledger = self.ledger_for_mutation(held)?;
            let prior_pending = ledger.pending_envelope_accounts.clone();
            let prior_material = ledger.pending_material_directories.clone();
            ledger.state = "replacingSecrets".into();
            self.save(held, &ledger)?;
            let result = (|| {
                crate::signing_install::install_preset(
                    &self.store,
                    &held.directory,
                    configuration,
                    passwords,
                    secrets,
                    installed_at_utc,
                    crate::signing_install::ReplacementTracking {
                        prior: &prior_pending,
                        stage: &mut |account| {
                            ledger.pending_envelope_accounts.push(account.into());
                            ledger.pending_envelope_accounts.sort();
                            ledger.pending_envelope_accounts.dedup();
                            self.save(held, &ledger)
                        },
                    },
                )?;
                self.revalidate(held)?;
                let receipt = self
                    .store
                    .load_validated(DEFAULT_PRESET_ID, true, secrets)?;
                let reference = credential_reference(&receipt)?;
                self.commit_replacement(held, &ledger, &receipt, &reference)?;
                Ok(CredentialResource {
                    credential_ref: reference,
                    project_ref: receipt.project_ref,
                    preset_id: receipt.preset_id,
                    installed_at_utc: receipt.installed_at_utc,
                    reference_count: 0,
                })
            })();
            if let Err(error) = &result
                && !matches!(error, SigningError::MaintenanceUncertain(_))
                && prior_pending.is_empty()
                && prior_material.is_empty()
            {
                // Only a synchronous, proven restoration may settle this
                // guarded transaction. Crashes leave replacingSecrets and
                // neither Rust nor older Swift auto-adopts it.
                ledger.state = "replacing".into();
                ledger.pending_envelope_accounts.clear();
                let _ = self.recover_mutation(held, &ledger);
            }
            result
        })
    }

    /// Explicit DevEco maintenance retains installation and file identity.
    pub fn replace_secret_envelope(
        &self,
        expected: &SigningPresetReceipt,
        passwords: &crate::secret_envelope::SecretPair,
        key_alias: Option<&str>,
        secrets: &dyn crate::signing_install::SigningSecretInstallation,
    ) -> Result<(bool, CredentialResource), SigningError> {
        self.with_lock(|held| {
            // CLI authenticates/decrypts before entering the owner. Another
            // installation may complete in between; reject that stale input
            // before even writing the mutation marker.
            let actual = self
                .store
                .load_validated(DEFAULT_PRESET_ID, false, secrets)?;
            self.revalidate(held)?;
            if &actual != expected {
                return Err(SigningError::drift(
                    "signing credential changed after DevEco input authentication",
                ));
            }
            let mut ledger = self.ledger_for_mutation(held)?;
            let prior_pending = ledger.pending_envelope_accounts.clone();
            let prior_material = ledger.pending_material_directories.clone();
            ledger.state = "replacingSecrets".into();
            self.save(held, &ledger)?;
            let result = (|| {
                let created = crate::signing_rekey::replace_secret_envelope(
                    &self.store,
                    &held.directory,
                    passwords,
                    key_alias,
                    secrets,
                    &prior_pending,
                    &mut |account| {
                        ledger.pending_envelope_accounts.push(account.into());
                        ledger.pending_envelope_accounts.sort();
                        ledger.pending_envelope_accounts.dedup();
                        self.save(held, &ledger)
                    },
                )?;
                self.revalidate(held)?;
                let receipt = self
                    .store
                    .load_validated(DEFAULT_PRESET_ID, true, secrets)?;
                let reference = credential_reference(&receipt)?;
                self.commit_replacement(held, &ledger, &receipt, &reference)?;
                Ok((
                    created,
                    CredentialResource {
                        credential_ref: reference,
                        project_ref: receipt.project_ref,
                        preset_id: receipt.preset_id,
                        installed_at_utc: receipt.installed_at_utc,
                        reference_count: 0,
                    },
                ))
            })();
            if let Err(error) = &result
                && !matches!(error, SigningError::MaintenanceUncertain(_))
                && prior_pending.is_empty()
                && prior_material.is_empty()
            {
                // Only a synchronous, proven restoration may settle this
                // guarded transaction. Crashes leave replacingSecrets and
                // neither Rust nor older Swift auto-adopts it.
                ledger.state = "replacing".into();
                ledger.pending_envelope_accounts.clear();
                let _ = self.recover_mutation(held, &ledger);
            }
            result
        })
    }

    /// Build and verify managed SDK material under the same replacement
    /// lock and pending-account protocol as explicit credential installation.
    pub fn install_sdk_release(
        &self,
        configuration: &crate::sdk_release::SdkReleaseConfiguration,
        secrets: &dyn crate::signing_install::SigningSecretInstallation,
        installed_at_utc: &str,
        timestamp: i64,
    ) -> Result<CredentialResource, SigningError> {
        self.with_lock(|held| {
            let mut ledger = self.ledger_for_mutation(held)?;
            let prior_pending = ledger.pending_envelope_accounts.clone();
            let prior_material = ledger.pending_material_directories.clone();
            ledger.state = "replacingSecrets".into();
            self.save(held, &ledger)?;
            let mut receipt_attempted = false;
            let result = (|| {
                let mut prepared = crate::sdk_release::prepare(
                    &self.store,
                    configuration,
                    secrets,
                    timestamp,
                    &mut |path| {
                        let path = path.to_str().ok_or_else(|| {
                            SigningError::unsafe_file("SDK material path is not UTF-8")
                        })?;
                        if !self.valid_material_directory(path) {
                            return Err(SigningError::unsafe_file(
                                "SDK material path is outside the managed root",
                            ));
                        }
                        ledger.pending_material_directories.push(path.into());
                        ledger.pending_material_directories.sort();
                        ledger.pending_material_directories.dedup();
                        self.save(held, &ledger)
                    },
                )?;
                prepared.retain_for_transaction();
                receipt_attempted = true;
                let passwords = crate::secret_envelope::SecretPair {
                    keystore: crate::signing_preset::public_sdk_release_password(),
                    key: crate::signing_preset::public_sdk_release_password(),
                };
                crate::signing_install::install_preset(
                    &self.store,
                    &held.directory,
                    &prepared.configuration,
                    &passwords,
                    secrets,
                    installed_at_utc,
                    crate::signing_install::ReplacementTracking {
                        prior: &prior_pending,
                        stage: &mut |account| {
                            ledger.pending_envelope_accounts.push(account.into());
                            ledger.pending_envelope_accounts.sort();
                            ledger.pending_envelope_accounts.dedup();
                            self.save(held, &ledger)
                        },
                    },
                )?;
                self.revalidate(held)?;
                let receipt = self
                    .store
                    .load_validated(DEFAULT_PRESET_ID, true, secrets)?;
                let reference = credential_reference(&receipt)?;
                self.commit_replacement(held, &ledger, &receipt, &reference)?;
                Ok(CredentialResource {
                    credential_ref: reference,
                    project_ref: receipt.project_ref,
                    preset_id: receipt.preset_id,
                    installed_at_utc: receipt.installed_at_utc,
                    reference_count: 0,
                })
            })();
            if result.is_err()
                && !receipt_attempted
                && prior_pending.is_empty()
                && prior_material.is_empty()
                && let Ok(receipt) = self.installed_receipt()
                && self
                    .retire_pending_material(held, &ledger, receipt.as_ref())
                    .is_ok()
            {
                ledger.state = "replacing".into();
                ledger.pending_envelope_accounts.clear();
                ledger.pending_material_directories.clear();
                let _ = self.recover_mutation(held, &ledger);
            }
            result
        })
    }

    fn valid_material_directory(&self, path: &str) -> bool {
        let path_object = std::path::Path::new(path);
        crate::signing_action::is_standard_path(path)
            && path_object.parent() == Some(self.store.root())
            && path_object
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_prefix("sdk-release-"))
                .is_some_and(crate::signing_preset::is_uuid)
    }

    fn retire_pending_material(
        &self,
        held: &Held,
        ledger: &Ledger,
        receipt: Option<&SigningPresetReceipt>,
    ) -> Result<(), SigningError> {
        self.revalidate(held)?;
        for path in &ledger.pending_material_directories {
            if !self.valid_material_directory(path) {
                return Err(SigningError::unsafe_file(
                    "pending SDK material path is invalid",
                ));
            }
            if let Some(receipt) = receipt {
                if receipt.managed_material_directory.as_deref() == Some(path.as_str()) {
                    continue;
                }
                if [
                    &receipt.java_executable,
                    &receipt.signer_jar,
                    &receipt.keystore,
                    &receipt.app_certificate,
                    &receipt.signed_profile,
                ]
                .iter()
                .any(|file| std::path::Path::new(&file.path).starts_with(path))
                {
                    return Err(SigningError::MaintenanceUncertain(
                        "replacement still references pending SDK source material".into(),
                    ));
                }
            }
            crate::sdk_release::remove_material(std::path::Path::new(path))?;
        }
        self.revalidate(held)
    }

    fn commit_replacement(
        &self,
        held: &Held,
        ledger: &Ledger,
        receipt: &SigningPresetReceipt,
        reference: &str,
    ) -> Result<(), SigningError> {
        self.retire_pending_material(held, ledger, Some(receipt))?;
        match self.save(held, &Ledger::stable(Some(reference.into()), Vec::new())) {
            Ok(()) => Ok(()),
            Err(SigningError::MaintenanceUncertain(_)) => {
                // The stable rename may be visible. Only a successfully
                // synchronized guard write proves that quarantine is back.
                match self.save(held, ledger) {
                    Ok(()) => Err(SigningError::MaintenanceUncertain("stable signing publication was uncertain; guarded tracking restored".into())),
                    Err(_) => Err(SigningError::MaintenanceUncertain("stable signing publication and guard restoration are both uncertain; retained receipt/material require explicit maintenance".into())),
                }
            }
            Err(_) => {
                // save classifies all failures after possible publication as
                // MaintenanceUncertain; here the prior durable guard remains.
                Err(SigningError::MaintenanceUncertain(
                    "stable signing ledger was not published; guarded tracking retained".into(),
                ))
            }
        }
    }

    /// Both replacement and removal validate pins without adopting a broken
    /// receipt: explicit maintenance is also how such a receipt is repaired.
    fn ledger_for_mutation(&self, held: &Held) -> Result<Ledger, SigningError> {
        let ledger = self.read_ledger(held, false)?;
        let mut sorted = ledger.preset_owners.clone();
        sorted.sort();
        sorted.dedup();
        if ledger.schema_version != LEDGER_SCHEMA
            || ![
                "stable",
                "replacing",
                "removing",
                "replacingSecrets",
                "removingSecrets",
            ]
            .contains(&ledger.state.as_str())
            || ledger.pending_material_directories.len() > MAX_OWNERS
            || !ledger
                .pending_material_directories
                .iter()
                .all(|path| self.valid_material_directory(path))
            || ledger.pending_envelope_accounts.len() > MAX_OWNERS
            || !ledger
                .pending_envelope_accounts
                .iter()
                .all(|account| crate::signing_install::envelope_account(account))
            || ledger.preset_owners.len() > MAX_OWNERS
            || ledger.preset_owners != sorted
            || !ledger
                .preset_owners
                .iter()
                .all(|owner| valid_identifier(owner))
        {
            return Err(SigningError::receipt(
                "signing credential mutation record is invalid",
            ));
        }
        if !ledger.preset_owners.is_empty() {
            return Err(SigningError::invalid(
                "signing credential is referenced by an active workspace preset",
            ));
        }
        Ok(ledger)
    }

    /// Swift `owner.maintain { store.refreshDaemonKeychainIdentity() }`.
    /// A helper update changes only the receipt's daemon fingerprint, never
    /// a password, envelope account or public credential identity. Preset
    /// pins therefore remain valid throughout this locked maintenance.
    pub fn refresh_daemon_identity(
        &self,
        secrets: &dyn SigningSecrets,
    ) -> Result<(), SigningError> {
        self.with_lock(|held| {
            let (ledger, installed) = self.load_and_recover(held)?;
            let Some(mut receipt) = installed else {
                return Ok(());
            };
            let before = credential_reference(&receipt)?;
            let identity = secrets.trusted_daemon_fingerprint()?;
            let envelope = receipt.secret_envelope_account.as_deref().ok_or_else(|| {
                SigningError::secret("Data Protection Keychain envelope is absent")
            })?;
            // Unreadable is not absent. This maintenance process may lack
            // the shared access group; refreshing a public fingerprint does
            // not decrypt/rewrite the envelope or admit a signing operation.
            if secrets.presence(envelope) == crate::signing_preset::SecretPresence::Absent {
                return Err(SigningError::secret(
                    "Data Protection Keychain envelope is absent",
                ));
            }
            if receipt.trusted_daemon_application_sha256 != identity {
                receipt.trusted_daemon_application_sha256 = identity;
                let value = serde_json::to_value(&receipt)
                    .map_err(|_| SigningError::io("signing receipt cannot be encoded"))?;
                let bytes = crate::canonical_json::encode(&value)
                    .ok_or_else(|| SigningError::io("signing receipt cannot be encoded"))?;
                self.revalidate(held)?;
                held.directory
                    .publish_document(crate::signing_preset::RECEIPT_FILE, &bytes, 1024 * 1024)
                    .map_err(|_| SigningError::io("cannot durably refresh signing receipt"))?;
            }
            self.revalidate(held)?;
            let after = self
                .installed_receipt()?
                .as_ref()
                .map(credential_reference)
                .transpose()?;
            self.revalidate(held)?;
            if after.as_deref() != Some(before.as_str()) || ledger.credential_ref != after {
                return Err(SigningError::drift(
                    "signing credential maintenance changed its public identity",
                ));
            }
            Ok(())
        })
    }

    /// Swift `installedReceipt()`: the receipt, or `None` only when the root
    /// positively holds none; one this build cannot honour is an error.
    fn installed_receipt(&self) -> Result<Option<SigningPresetReceipt>, SigningError> {
        if !self.store.receipt_path().exists() {
            return Ok(None);
        }
        // Validation without secrets never consults them.
        self.store
            .load_validated(DEFAULT_PRESET_ID, false, &NoSecrets)
            .map(Some)
    }

    /// Swift `loadAndRecover(rootFD:)`.
    fn load_and_recover(
        &self,
        held: &Held,
    ) -> Result<(Ledger, Option<SigningPresetReceipt>), SigningError> {
        let mut ledger = self.read_ledger(held, true)?;
        if ledger.state != "stable" {
            ledger = self.recover_mutation(held, &ledger)?;
        }
        let receipt = self.installed_receipt()?;
        self.revalidate(held)?;
        let actual = receipt.as_ref().map(credential_reference).transpose()?;
        let mut sorted = ledger.preset_owners.clone();
        sorted.sort();
        let unique: BTreeSet<&String> = ledger.preset_owners.iter().collect();
        if ledger.schema_version != LEDGER_SCHEMA
            || ledger.state != "stable"
            || !ledger.pending_envelope_accounts.is_empty()
            || !ledger.pending_material_directories.is_empty()
            || ledger.preset_owners.len() > MAX_OWNERS
            || ledger.preset_owners != sorted
            || unique.len() != ledger.preset_owners.len()
            || !ledger
                .preset_owners
                .iter()
                .all(|owner| valid_identifier(owner))
            || ledger.credential_ref != actual
        {
            return Err(SigningError::receipt(
                "signing credential owner ledger does not match the installed receipt",
            ));
        }
        Ok((ledger, receipt))
    }

    /// Swift `recoverMutation(rootFD:ledger:)`: an interrupted replace or
    /// removal settled by adopting what actually landed.
    fn recover_mutation(&self, held: &Held, ledger: &Ledger) -> Result<Ledger, SigningError> {
        if !["replacing", "removing"].contains(&ledger.state.as_str())
            || !ledger.preset_owners.is_empty()
            || !ledger.pending_envelope_accounts.is_empty()
            || !ledger.pending_material_directories.is_empty()
        {
            return Err(SigningError::receipt(
                "signing credential mutation record is invalid",
            ));
        }
        let receipt = self.installed_receipt()?;
        let recovered = Ledger::stable(
            receipt.as_ref().map(credential_reference).transpose()?,
            Vec::new(),
        );
        self.save(held, &recovered)?;
        Ok(recovered)
    }

    /// Swift `readLedger(rootFD:adoptingInstalledReceipt:)`: a root with no
    /// ledger yet adopts the installed receipt's exact reference.
    fn read_ledger(&self, held: &Held, adopting: bool) -> Result<Ledger, SigningError> {
        self.revalidate(held)?;
        let bytes = match held.directory.read(LEDGER_FILE, MAX_LEDGER_BYTES) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if !adopting {
                    return Ok(Ledger::stable(None, Vec::new()));
                }
                let receipt = self.installed_receipt()?;
                let ledger = Ledger::stable(
                    receipt.as_ref().map(credential_reference).transpose()?,
                    Vec::new(),
                );
                self.save(held, &ledger)?;
                return Ok(ledger);
            }
            Err(_) => {
                return Err(SigningError::unsafe_file(
                    "signing credential ledger is unsafe",
                ));
            }
        };
        serde_json::from_slice(&bytes).map_err(|_| {
            SigningError::receipt("signing credential ledger failed schema validation")
        })
    }

    /// Swift `save(_:rootFD:)`: the ledger published whole and durably.
    fn save(&self, held: &Held, ledger: &Ledger) -> Result<(), SigningError> {
        self.revalidate(held)?;
        let bytes = ledger.encode()?;
        if bytes.len() > MAX_LEDGER_BYTES {
            return Err(SigningError::io(
                "signing credential ledger exceeds its bound",
            ));
        }
        #[cfg(test)]
        if ledger.state == "stable" && FINAL_LEDGER_FAILURE.with(|failure| failure.get()) == 1 {
            FINAL_LEDGER_FAILURE.with(|failure| failure.set(0));
            return Err(SigningError::io(
                "fixture stable ledger publication failure",
            ));
        }
        held.directory
            .publish_document(LEDGER_FILE, &bytes, MAX_LEDGER_BYTES)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => {
                    SigningError::io("cannot write signing credential transaction")
                }
                DocumentPublishError::OutcomeUnknown(_) => SigningError::MaintenanceUncertain(
                    "signing credential transaction could not be published durably".into(),
                ),
            })?;
        #[cfg(test)]
        if ledger.state == "stable" && FINAL_LEDGER_FAILURE.with(|failure| failure.replace(0)) == 2
        {
            return Err(SigningError::MaintenanceUncertain(
                "fixture stable ledger sync failure after rename".into(),
            ));
        }
        self.revalidate(held).map_err(|_| {
            SigningError::MaintenanceUncertain(
                "signing owner directory changed after ledger publication".into(),
            )
        })
    }

    /// Swift `revalidateOwnerDirectory(_:)`.
    fn revalidate(&self, held: &Held) -> Result<(), SigningError> {
        let canonical = self.canonical_root()?;
        held.directory.validate_path(&canonical).map_err(|_| {
            SigningError::unsafe_file("signing credential owner directory identity changed")
        })
    }

    fn canonical_root(&self) -> Result<PathBuf, SigningError> {
        self.root
            .canonicalize()
            .map_err(|_| SigningError::io("cannot open signing credential owner"))
    }

    /// Swift `withOwnerLock(_:)`: the private root, created when absent, and
    /// its lock, held exclusively — waiting, as Swift's blocking `flock`
    /// waits, while another holder has it.
    fn with_lock<T>(
        &self,
        body: impl FnOnce(&Held) -> Result<T, SigningError>,
    ) -> Result<T, SigningError> {
        let directory = HostDirectory::open_or_create_private(&self.root).map_err(|_| {
            SigningError::unsafe_file("signing credential owner directory is unsafe")
        })?;
        let lock = loop {
            match directory.lock_document(LOCK_FILE) {
                Ok(lock) => break lock,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => {
                    return Err(SigningError::unsafe_file(
                        "signing credential lock is unsafe",
                    ));
                }
            }
        };
        let held = Held {
            directory,
            _lock: lock,
        };
        self.revalidate(&held)?;
        body(&held)
    }
}

fn validate_owner(owner: &str) -> Result<(), SigningError> {
    if !valid_identifier(owner) {
        return Err(SigningError::invalid(
            "workspace preset reference is malformed",
        ));
    }
    Ok(())
}

/// The secret source of a validation that asks for no secret.
struct NoSecrets;

impl SigningSecrets for NoSecrets {
    fn read(&self, _: &str) -> Result<arkdeck_platform::Secret, SigningError> {
        Err(SigningError::secret("no secret is read here"))
    }
    fn presence(&self, _: &str) -> crate::signing_preset::SecretPresence {
        crate::signing_preset::SecretPresence::Unreadable
    }
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        Ok(None)
    }
}

#[cfg(test)]
thread_local! {
    pub(crate) static FINAL_LEDGER_FAILURE: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
}
