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
//! Only the Runtime's side is here — resolution and the pins a preset's
//! registration takes and releases. Replacing and removing the credential
//! stay with the maintenance CLI.
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
}

impl Ledger {
    fn stable(credential_ref: Option<String>, preset_owners: Vec<String>) -> Self {
        Self {
            schema_version: LEDGER_SCHEMA.into(),
            state: "stable".into(),
            credential_ref,
            preset_owners,
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
        held.directory
            .publish_document(LEDGER_FILE, &bytes, MAX_LEDGER_BYTES)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(_) => {
                    SigningError::io("cannot write signing credential transaction")
                }
                DocumentPublishError::OutcomeUnknown(_) => SigningError::io(
                    "signing credential transaction could not be published durably",
                ),
            })?;
        self.revalidate(held)
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
