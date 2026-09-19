//! Swift `OpenHarmonySigningPresetStore`: the one published signing preset,
//! `openharmony-release@1`, recorded as `preset-v1.json`
//! (`arkdeck-openharmony-signing/v1`) under the private preset root. The
//! receipt pins the Java launcher, hap-sign-tool, keystore, certificate chain
//! and signed profile by path, SHA-256 and length; both passwords live in one
//! Data Protection Keychain envelope named by the receipt.
//!
//! The receipt is a durable format read after the cutover (T0): it decodes
//! with exactly Swift's `CodingKeys`, and a document with one more key is
//! refused rather than silently narrowed. Only reading and validation are
//! here; the install, re-key and uninstall writers stay with the maintenance
//! CLI until it is ported.
use crate::SigningError;
use crate::secret_envelope::{SecretPair, decode_envelope, validate_secret};
use arkdeck_platform::Secret;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const RECEIPT_SCHEMA: &str = "arkdeck-openharmony-signing/v1";
pub const RECEIPT_FILE: &str = "preset-v1.json";
pub const DEFAULT_PRESET_ID: &str = "openharmony-release@1";
pub const KEYCHAIN_SERVICE: &str = "dev.arkdeck.openharmony-local-signing";
pub const KEYCHAIN_ACCESS_SCHEMA: &str = "data-protection-access-group-v1";
pub const SIGNING_ALGORITHM: &str = "SHA256withECDSA";
const MAX_RECEIPT_BYTES: usize = 1024 * 1024;

/// Swift `OpenHarmonySigningFileIdentity`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SigningFileIdentity {
    pub path: String,
    pub sha256: String,
    #[serde(rename = "byteCount")]
    pub byte_count: u64,
}

/// Swift `OpenHarmonySigningPresetReceipt`, key for key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SigningPresetReceipt {
    #[serde(rename = "schemaVersion")]
    pub schema_version: String,
    #[serde(rename = "installedAtUTC")]
    pub installed_at_utc: String,
    #[serde(rename = "presetID")]
    pub preset_id: String,
    #[serde(rename = "projectRef")]
    pub project_ref: String,
    #[serde(rename = "javaExecutable")]
    pub java_executable: SigningFileIdentity,
    #[serde(rename = "signerJAR")]
    pub signer_jar: SigningFileIdentity,
    pub keystore: SigningFileIdentity,
    #[serde(rename = "appCertificate")]
    pub app_certificate: SigningFileIdentity,
    #[serde(rename = "signedProfile")]
    pub signed_profile: SigningFileIdentity,
    #[serde(rename = "keyAlias")]
    pub key_alias: String,
    #[serde(rename = "signingAlgorithm")]
    pub signing_algorithm: String,
    #[serde(rename = "keystorePasswordAccount")]
    pub keystore_password_account: String,
    #[serde(rename = "keyPasswordAccount")]
    pub key_password_account: String,
    #[serde(
        rename = "secretEnvelopeAccount",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub secret_envelope_account: Option<String>,
    #[serde(
        rename = "supersededEnvelopeAccounts",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub superseded_envelope_accounts: Option<Vec<String>>,
    #[serde(
        rename = "trustedDaemonApplicationSHA256",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub trusted_daemon_application_sha256: Option<String>,
    #[serde(
        rename = "keychainAccessSchema",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub keychain_access_schema: Option<String>,
    #[serde(
        rename = "managedMaterialDirectory",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub managed_material_directory: Option<String>,
}

/// Decodes a receipt document with Swift's exact key set.
pub fn decode_receipt(bytes: &[u8]) -> Result<SigningPresetReceipt, SigningError> {
    if bytes.len() > MAX_RECEIPT_BYTES {
        return Err(SigningError::receipt("signing receipt is unbounded"));
    }
    serde_json::from_slice(bytes).map_err(|error| SigningError::receipt(error.to_string()))
}

impl SigningPresetReceipt {
    /// Swift `isManagedSDKReleasePreset`: the official SDK's release material,
    /// whose password is published with the SDK.
    pub fn is_managed_sdk_release(&self) -> bool {
        let Some(managed) = &self.managed_material_directory else {
            return false;
        };
        self.key_alias == "openharmony application release"
            && self.keystore.path == format!("{managed}/OpenHarmony.p12")
            && self.app_certificate.path == format!("{managed}/OpenHarmonyApplicationRelease.pem")
            && self.signed_profile.path == format!("{managed}/release-profile.p7b")
            && self
                .signer_jar
                .path
                .ends_with("/toolchains/lib/hap-sign-tool.jar")
    }

    /// The field checks of Swift `loadValidatedUnlocked`, in its order, short
    /// of re-measuring the files and asking for secrets.
    pub fn validate_fields(&self, preset_id: &str, root: &Path) -> Result<(), SigningError> {
        if self.schema_version != RECEIPT_SCHEMA || self.preset_id != preset_id {
            return Err(SigningError::receipt("schema or preset mismatch"));
        }
        if self.keychain_access_schema.as_deref() != Some(KEYCHAIN_ACCESS_SCHEMA) {
            return Err(SigningError::receipt(
                "signing preset uses an unsupported credential storage form; reconfigure it with \
                 `arkdeck runtime signing install`",
            ));
        }
        if !is_identifier(&self.project_ref) {
            return Err(SigningError::invalid("projectRef is malformed"));
        }
        let envelope_prefix = format!("{}|secret-envelope-", self.preset_id);
        let is_envelope_account = |account: &str| {
            account
                .strip_prefix(envelope_prefix.as_str())
                .is_some_and(is_uuid)
        };
        let envelope_is_valid = self
            .secret_envelope_account
            .as_deref()
            .is_some_and(is_envelope_account);
        let superseded_are_valid =
            self.superseded_envelope_accounts
                .iter()
                .flatten()
                .all(|account| {
                    is_envelope_account(account)
                        && Some(account.as_str()) != self.secret_envelope_account.as_deref()
                });
        if self.signing_algorithm != SIGNING_ALGORITHM
            || !is_key_alias(&self.key_alias)
            || self.keystore_password_account != format!("{}|keystore", self.preset_id)
            || self.key_password_account != format!("{}|key", self.preset_id)
            || !envelope_is_valid
            || !superseded_are_valid
            || !self.signer_jar.path.ends_with(".jar")
            || !(self.keystore.path.ends_with(".p12") || self.keystore.path.ends_with(".jks"))
            || !(self.app_certificate.path.ends_with(".pem")
                || self.app_certificate.path.ends_with(".cer"))
            || !self.signed_profile.path.ends_with(".p7b")
        {
            return Err(SigningError::receipt(
                "closed preset fields or Keychain accounts drifted",
            ));
        }
        if let Some(managed) = &self.managed_material_directory {
            let root = root.to_str().unwrap_or_default();
            let parent = |path: &str| path.rsplit_once('/').map(|(parent, _)| parent.to_owned());
            if !crate::signing_action::is_standard_path(managed)
                || parent(managed).as_deref() != Some(root)
                || [
                    &self.keystore.path,
                    &self.app_certificate.path,
                    &self.signed_profile.path,
                ]
                .iter()
                .any(|path| parent(path).as_deref() != Some(managed.as_str()))
            {
                return Err(SigningError::receipt(
                    "managed SDK signing material escaped its private preset directory",
                ));
            }
        }
        Ok(())
    }
}

/// What a presence probe established about one Keychain account (Swift
/// `OpenHarmonySigningSecretPresence`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecretPresence {
    Present,
    /// The store positively answered that no such item exists.
    Absent,
    /// No answer: a missing entitlement, a refused interaction, an error.
    Unreadable,
}

/// Swift `OpenHarmonySigningSecretStoring`, the read side the Runtime uses.
pub trait SigningSecrets {
    fn read(&self, account: &str) -> Result<Secret, SigningError>;
    fn presence(&self, account: &str) -> SecretPresence;
    /// `false` for an absent item and for a store this process could not read.
    fn contains(&self, account: &str) -> bool {
        self.presence(account) == SecretPresence::Present
    }
    /// The installed daemon's code identity, or `None` where the store binds
    /// to none.
    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError>;
}

/// Swift `OpenHarmonyLocalSigning.publicSDKReleasePassword()`: the password
/// shipped with the official OpenHarmony SDK release keystore. It has no
/// confidentiality value.
pub fn public_sdk_release_password() -> Secret {
    Secret::from_slice(b"123456")
}

/// The read side of Swift `OpenHarmonySigningPresetStore` over one root.
pub struct SigningPresetStore {
    root: PathBuf,
}

impl SigningPresetStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Swift `OpenHarmonyLocalSigning.defaultRootURL()`:
    /// `~/Library/Application Support/ArkDeck/Signing/OpenHarmony`.
    #[cfg(unix)]
    pub fn default_root() -> Option<PathBuf> {
        arkdeck_platform::arkdeck_application_support_root()
            .map(|root| root.join("Signing/OpenHarmony"))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn receipt_path(&self) -> PathBuf {
        self.root.join(RECEIPT_FILE)
    }

    /// Swift `loadValidated(presetID:requireSecrets:)`.
    #[cfg(unix)]
    pub fn load_validated(
        &self,
        preset_id: &str,
        require_secrets: bool,
        secrets: &dyn SigningSecrets,
    ) -> Result<SigningPresetReceipt, SigningError> {
        let bytes = std::fs::read(self.receipt_path())
            .map_err(|error| SigningError::receipt(error.to_string()))?;
        let receipt = decode_receipt(&bytes)?;
        receipt.validate_fields(preset_id, &self.root)?;
        remeasure_for_dispatch(&receipt)?;
        if require_secrets {
            validate_trusted_daemon_identity(&receipt, secrets)?;
            if !receipt
                .secret_envelope_account
                .as_deref()
                .is_some_and(|account| secrets.contains(account))
            {
                return Err(SigningError::secret("required Keychain item is absent"));
            }
        }
        Ok(receipt)
    }

    /// Swift `secretPair(for:)`: the managed SDK release preset answers with
    /// the published password once its envelope is known to be present;
    /// every other preset reads and checks its envelope.
    pub fn secret_pair(
        &self,
        receipt: &SigningPresetReceipt,
        secrets: &dyn SigningSecrets,
    ) -> Result<SecretPair, SigningError> {
        if receipt.is_managed_sdk_release() {
            if receipt.keychain_access_schema.as_deref() != Some(KEYCHAIN_ACCESS_SCHEMA)
                || !receipt
                    .secret_envelope_account
                    .as_deref()
                    .is_some_and(|account| secrets.contains(account))
            {
                return Err(SigningError::secret(
                    "managed SDK release Keychain envelope is absent or stale",
                ));
            }
            validate_trusted_daemon_identity(receipt, secrets)?;
            return Ok(SecretPair {
                keystore: public_sdk_release_password(),
                key: public_sdk_release_password(),
            });
        }
        let account = receipt.secret_envelope_account.as_deref().ok_or_else(|| {
            SigningError::secret(
                "signing preset has no Data Protection Keychain envelope; reconfigure it with \
                 `arkdeck runtime signing install`",
            )
        })?;
        let encoded = secrets.read(account)?;
        let pair = decode_envelope(encoded.as_bytes())?;
        validate_secret(pair.keystore.as_bytes())?;
        validate_secret(pair.key.as_bytes())?;
        Ok(pair)
    }
}

/// Swift `validateTrustedDaemonIdentity`: a receipt that recorded the
/// installed daemon's identity is honoured only by that daemon.
pub fn validate_trusted_daemon_identity(
    receipt: &SigningPresetReceipt,
    secrets: &dyn SigningSecrets,
) -> Result<(), SigningError> {
    let Some(expected) = &receipt.trusted_daemon_application_sha256 else {
        return Ok(());
    };
    let drift =
        || SigningError::drift("installed arkdeck-agentd no longer matches the signing receipt");
    if receipt.keychain_access_schema.as_deref() != Some(KEYCHAIN_ACCESS_SCHEMA) {
        return Err(drift());
    }
    match secrets.trusted_daemon_fingerprint()? {
        Some(actual) if &actual == expected => Ok(()),
        _ => Err(drift()),
    }
}

/// Swift `remeasureForDispatch(_:)`: every pinned file still measures as
/// recorded, the Java launcher executable and the keystore private.
#[cfg(unix)]
pub fn remeasure_for_dispatch(receipt: &SigningPresetReceipt) -> Result<(), SigningError> {
    crate::remeasure(&receipt.java_executable, "java", true, false)?;
    crate::remeasure(&receipt.signer_jar, "signer JAR", false, false)?;
    crate::remeasure(&receipt.keystore, "keystore", false, true)?;
    crate::remeasure(&receipt.app_certificate, "app certificate", false, false)?;
    crate::remeasure(&receipt.signed_profile, "signed profile", false, false)?;
    Ok(())
}

/// Swift `validateIdentifier`: `^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$`.
pub fn is_identifier(value: &str) -> bool {
    closed_name(value, |byte| matches!(byte, b'.' | b'_' | b'@' | b'-'))
}

/// Swift `isValidKeyAlias`: `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$`.
pub fn is_key_alias(value: &str) -> bool {
    closed_name(value, |byte| matches!(byte, b' ' | b'.' | b'_' | b'-'))
}

fn closed_name(value: &str, extra: impl Fn(u8) -> bool) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 128
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || extra(*byte))
}

/// Foundation `UUID(uuidString:)`: 8-4-4-4-12 hexadecimal digits, either case.
pub fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

#[cfg(test)]
mod tests {
    use super::{is_identifier, is_key_alias, is_uuid};

    #[test]
    fn closed_names_follow_the_swift_patterns() {
        assert!(is_identifier("openharmony-release@1"));
        assert!(is_identifier("project-fd677365f7bdefabda66a3c1"));
        assert!(!is_identifier(""));
        assert!(!is_identifier("-leading"));
        assert!(!is_identifier("with space"));
        assert!(!is_identifier("trailing\n"));
        assert!(!is_identifier(&"a".repeat(129)));
        assert!(is_identifier(&"a".repeat(128)));
        assert!(is_key_alias("openharmony application release"));
        assert!(is_key_alias("debugKey"));
        assert!(!is_key_alias("invalid/alias"));
        assert!(!is_key_alias("debugKey\n"));
        assert!(is_uuid("3f2a9c1e-5b7d-4e8a-9c0f-1d2e3a4b5c6d"));
        assert!(is_uuid("3F2A9C1E-5B7D-4E8A-9C0F-1D2E3A4B5C6D"));
        assert!(!is_uuid("3f2a9c1e5b7d4e8a9c0f1d2e3a4b5c6d"));
        assert!(!is_uuid("3f2a9c1e-5b7d-4e8a-9c0f-1d2e3a4b5c6g"));
    }
}
