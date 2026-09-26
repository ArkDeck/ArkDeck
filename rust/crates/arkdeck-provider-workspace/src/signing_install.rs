//! Explicit maintenance installation. Passwords enter only as wiped buffers;
//! the Runtime's read-only secret interface gains no write methods.
use crate::secret_envelope::{SecretPair, encode_envelope, validate_secret};
use crate::signing_preset::{
    DEFAULT_PRESET_ID, KEYCHAIN_ACCESS_SCHEMA, RECEIPT_FILE, RECEIPT_SCHEMA, SIGNING_ALGORITHM,
    SigningPresetReceipt, SigningPresetStore, SigningSecrets, is_identifier, is_key_alias, is_uuid,
};
use crate::{SigningError, measure};
use arkdeck_platform::HostDirectory;
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

fn envelope_account(account: &str) -> bool {
    account
        .strip_prefix(&format!("{DEFAULT_PRESET_ID}|secret-envelope-"))
        .is_some_and(is_uuid)
}

fn new_envelope_account() -> Result<String, SigningError> {
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

/// Only the credential owner may call this, after persisting `replacing`.
pub(crate) fn install_preset(
    store: &SigningPresetStore,
    directory: &HostDirectory,
    configuration: &SigningPresetConfiguration,
    passwords: &SecretPair,
    secrets: &dyn SigningSecretInstallation,
    installed_at_utc: &str,
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
    let previous = match directory.read(RECEIPT_FILE, 1024 * 1024) {
        Ok(bytes) => crate::signing_removal::decode_for_maintenance(&bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => {
            return Err(SigningError::unsafe_file(
                "signing receipt cannot be read safely for installation",
            ));
        }
    };
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
    superseded.remove(account);
    if !superseded.is_empty() {
        receipt.superseded_envelope_accounts = Some(superseded.into_iter().collect());
    }
    let envelope = encode_envelope(passwords.keystore.as_bytes(), passwords.key.as_bytes());
    let previous_secret = reusable.and_then(|account| secrets.read(account).ok());
    let bytes = crate::canonical_json::encode(
        &serde_json::to_value(&receipt)
            .map_err(|_| SigningError::io("signing receipt cannot be encoded"))?,
    )
    .ok_or_else(|| SigningError::io("signing receipt cannot be encoded"))?;
    let restore = || {
        if let Some(previous) = &previous_secret {
            let _ = secrets.set_envelope(account, previous.as_bytes());
        } else {
            let _ = secrets.remove_envelope(account);
        }
    };
    if let Err(error) = secrets.set_envelope(account, envelope.as_bytes()) {
        restore();
        return Err(error);
    }
    let publish = || {
        let root = store
            .root()
            .canonicalize()
            .map_err(|_| SigningError::unsafe_file("signing preset directory identity changed"))?;
        directory
            .validate_path(&root)
            .map_err(|_| SigningError::unsafe_file("signing preset directory identity changed"))?;
        directory
            .publish_document(RECEIPT_FILE, &bytes, 1024 * 1024)
            .map_err(|_| SigningError::io("cannot durably publish signing receipt"))
    };
    if let Err(error) = publish() {
        // Swift restores the old envelope (or removes the new account) on
        // every receipt-write error. If a new receipt did land, subsequent
        // admission still requires the real envelope; cleanup tracking is
        // retained in that receipt and the owner recovers only what exists.
        restore();
        return Err(error);
    }
    Ok(receipt)
}
