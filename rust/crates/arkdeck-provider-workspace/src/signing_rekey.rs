//! Explicit maintenance of an existing credential's secret envelope.
use crate::{
    SigningError,
    secret_envelope::{SecretPair, encode_envelope, validate_secret},
    signing_install::{SigningSecretInstallation, new_envelope_account},
    signing_preset::{DEFAULT_PRESET_ID, KEYCHAIN_ACCESS_SCHEMA, SigningPresetStore, is_key_alias},
};
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use std::collections::BTreeSet;

/// Called only while the owner holds its lock and durable `replacingSecrets` marker.
pub(crate) fn replace_secret_envelope(
    store: &SigningPresetStore,
    directory: &HostDirectory,
    passwords: &SecretPair,
    key_alias: Option<&str>,
    secrets: &dyn SigningSecretInstallation,
    prior_pending: &[String],
    track: &mut dyn FnMut(&str) -> Result<(), SigningError>,
) -> Result<bool, SigningError> {
    let previous_bytes = directory
        .read(crate::signing_preset::RECEIPT_FILE, 1024 * 1024)
        .map_err(|_| {
            SigningError::unsafe_file("signing receipt cannot be read safely for replacement")
        })?;
    let mut receipt = store.load_validated(DEFAULT_PRESET_ID, false, secrets)?;
    validate_secret(passwords.keystore.as_bytes())?;
    validate_secret(passwords.key.as_bytes())?;
    if key_alias.is_some_and(|alias| !is_key_alias(alias)) {
        return Err(SigningError::invalid("key alias is malformed"));
    }
    let identity = secrets.trusted_daemon_fingerprint()?;
    let alias = key_alias.unwrap_or(&receipt.key_alias).to_owned();
    let metadata_changed = !prior_pending.is_empty()
        || alias != receipt.key_alias
        || receipt.trusted_daemon_application_sha256 != identity;
    let existing = receipt
        .secret_envelope_account
        .clone()
        .filter(|account| secrets.contains(account));
    let envelope = encode_envelope(passwords.keystore.as_bytes(), passwords.key.as_bytes());
    let account = existing.clone().map_or_else(new_envelope_account, Ok)?;
    if existing.is_none() {
        let mut superseded: BTreeSet<_> = receipt
            .superseded_envelope_accounts
            .take()
            .unwrap_or_default()
            .into_iter()
            .collect();
        if let Some(previous) = receipt.secret_envelope_account.take() {
            superseded.insert(previous);
        }
        receipt.superseded_envelope_accounts = Some(superseded.into_iter().collect());
    }
    let mut superseded: BTreeSet<_> = receipt
        .superseded_envelope_accounts
        .take()
        .unwrap_or_default()
        .into_iter()
        .collect();
    superseded.extend(prior_pending.iter().cloned());
    superseded.remove(&account);
    if !superseded.is_empty() {
        receipt.superseded_envelope_accounts = Some(superseded.into_iter().collect());
    }
    receipt.secret_envelope_account = Some(account.clone());
    receipt.key_alias = alias;
    receipt.trusted_daemon_application_sha256 = identity;
    receipt.keychain_access_schema = Some(KEYCHAIN_ACCESS_SCHEMA.into());
    let publish = || {
        let root = store
            .root()
            .canonicalize()
            .map_err(|_| SigningError::unsafe_file("signing preset directory identity changed"))?;
        directory
            .validate_path(&root)
            .map_err(|_| SigningError::unsafe_file("signing preset directory identity changed"))?;
        let value = serde_json::to_value(&receipt)
            .map_err(|_| SigningError::io("signing receipt cannot be encoded"))?;
        let bytes = crate::canonical_json::encode(&value)
            .ok_or_else(|| SigningError::io("signing receipt cannot be encoded"))?;
        crate::signing_install::publish_receipt(directory, &bytes).map_err(|error| match error {
            DocumentPublishError::BeforePublication(_) => {
                SigningError::io("cannot durably publish signing receipt")
            }
            DocumentPublishError::OutcomeUnknown(_) => SigningError::MaintenanceUncertain(
                "signing receipt publication could not be proved durable".into(),
            ),
        })
    };
    track(&account)?;
    if existing.is_some() {
        // Replacement requires a readable old
        // value: do not destroy the only recovery value when it is unreadable.
        let previous = secrets.read(&account)?;
        let result = secrets
            .set_envelope(&account, envelope.as_bytes())
            .and_then(|()| if metadata_changed { publish() } else { Ok(()) });
        if let Err(error) = result {
            if matches!(error, SigningError::MaintenanceUncertain(_)) {
                return Err(error);
            }
            secrets
                .set_envelope(&account, previous.as_bytes())
                .map_err(|_| {
                    SigningError::MaintenanceUncertain(
                        "signing metadata update failed and Keychain rollback was incomplete"
                            .into(),
                    )
                })?;
            crate::signing_install::prove_receipt_unchanged(directory, Some(&previous_bytes))?;
            return Err(error);
        }
        Ok(false)
    } else {
        if let Err(error) = secrets.set_envelope(&account, envelope.as_bytes()) {
            secrets.remove_envelope(&account).map_err(|_| {
                SigningError::MaintenanceUncertain("cannot prove signing secret restoration".into())
            })?;
            crate::signing_install::prove_receipt_unchanged(directory, Some(&previous_bytes))?;
            return Err(error);
        }
        if let Err(error) = publish() {
            if matches!(error, SigningError::MaintenanceUncertain(_)) {
                return Err(error);
            }
            secrets.remove_envelope(&account).map_err(|_| {
                SigningError::MaintenanceUncertain("cannot prove signing secret restoration".into())
            })?;
            crate::signing_install::prove_receipt_unchanged(directory, Some(&previous_bytes))?;
            return Err(error);
        }
        Ok(true)
    }
}
