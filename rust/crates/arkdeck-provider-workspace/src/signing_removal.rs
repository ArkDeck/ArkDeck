//! Explicit maintenance-CLI removal, matching Swift's preset-store removal.
//! Runtime secret readers acquire no write interface through `SigningSecrets`.
use crate::SigningError;
use crate::signing_preset::{DEFAULT_PRESET_ID, RECEIPT_FILE, SigningPresetStore, decode_receipt};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

/// Only the explicit maintenance path receives this interface. It never
/// reads a secret value and clears both the supported and legacy scopes.
pub trait SigningSecretRemoval {
    fn remove_current(&self, account: &str) -> Result<bool, SigningError>;
    fn remove_legacy(&self, account: &str) -> Result<bool, SigningError>;
}

#[derive(Debug, PartialEq, Eq)]
pub struct SigningPresetRemoval {
    pub removed_receipt: bool,
    pub removed_keystore_password: bool,
    pub removed_key_password: bool,
    pub removed_managed_material: bool,
    pub preserved_source_count: usize,
}

/// Called only while the credential owner holds its mutation lock and has
/// durably recorded `removing`. A malformed receipt does not trap uninstall;
/// it still removes the two fixed legacy accounts and the unusable receipt.
pub(crate) fn remove_preset(
    store: &SigningPresetStore,
    secrets: &dyn SigningSecretRemoval,
) -> Result<SigningPresetRemoval, SigningError> {
    let receipt_path = store.receipt_path();
    let directory = arkdeck_platform::HostDirectory::open(store.root())
        .map_err(|_| SigningError::unsafe_file("signing preset root is unsafe"))?;
    let receipt = match directory.read(RECEIPT_FILE, 1024 * 1024) {
        Ok(bytes) => decode_for_removal(&bytes),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        // Do not destroy the tracking receipt if its bytes cannot be read
        // safely: that could strand live envelope items under unknown names.
        Err(_) => {
            return Err(SigningError::unsafe_file(
                "signing receipt cannot be read safely for removal",
            ));
        }
    };
    let managed = receipt
        .as_ref()
        .and_then(|r| r.managed_material_directory.as_deref());
    if let Some(path) = managed
        && (!crate::signing_action::is_standard_path(path)
            || Path::new(path).parent() != Some(store.root()))
    {
        return Err(SigningError::receipt(
            "managed signing material path drifted outside the preset root",
        ));
    }
    let keystore = format!("{DEFAULT_PRESET_ID}|keystore");
    let key = format!("{DEFAULT_PRESET_ID}|key");
    let mut accounts = BTreeSet::from([keystore.clone(), key.clone()]);
    if let Some(receipt) = &receipt {
        accounts.extend(receipt.secret_envelope_account.iter().cloned());
        accounts.extend(
            receipt
                .superseded_envelope_accounts
                .iter()
                .flatten()
                .cloned(),
        );
    }
    let mut removed = BTreeSet::new();
    for account in accounts {
        let current = secrets.remove_current(&account)?;
        // Do not short-circuit: a legacy copy must also be removed.
        let legacy = secrets.remove_legacy(&account)?;
        if current || legacy {
            removed.insert(account);
        }
    }
    let envelope_removed = receipt
        .as_ref()
        .and_then(|r| r.secret_envelope_account.as_ref())
        .map(|account| removed.contains(account));
    let removed_receipt = remove_file_if_present(&receipt_path)?;
    let mut removed_managed_material = false;
    if let Some(path) = managed {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                // remove_dir_all does not follow a symlink; a symlink or
                // regular entry is unlinked, as FileManager.removeItem does.
                let result = if metadata.is_dir() {
                    fs::remove_dir_all(path)
                } else {
                    fs::remove_file(path)
                };
                result.map_err(|_| SigningError::io("cannot remove managed signing material"))?;
                removed_managed_material = true;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(SigningError::io("cannot inspect managed signing material")),
        }
    }
    Ok(SigningPresetRemoval {
        removed_receipt,
        removed_keystore_password: envelope_removed.unwrap_or_else(|| removed.contains(&keystore)),
        removed_key_password: envelope_removed.unwrap_or_else(|| removed.contains(&key)),
        removed_managed_material,
        preserved_source_count: usize::from(receipt.is_some() && managed.is_none()) * 3,
    })
}

/// Swift's uninstall uses JSONDecoder directly, which ignores extra keys.
/// Keep that behavior only at explicit cleanup: the Runtime's strict receipt
/// decoder and all signing/admission validation remain unchanged.
fn decode_for_removal(bytes: &[u8]) -> Option<crate::signing_preset::SigningPresetReceipt> {
    if bytes.len() > 1024 * 1024 {
        return None;
    }
    let mut value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let object = value.as_object_mut()?;
    object.retain(|key, _| {
        matches!(
            key.as_str(),
            "schemaVersion"
                | "installedAtUTC"
                | "presetID"
                | "projectRef"
                | "javaExecutable"
                | "signerJAR"
                | "keystore"
                | "appCertificate"
                | "signedProfile"
                | "keyAlias"
                | "signingAlgorithm"
                | "keystorePasswordAccount"
                | "keyPasswordAccount"
                | "secretEnvelopeAccount"
                | "supersededEnvelopeAccounts"
                | "trustedDaemonApplicationSHA256"
                | "keychainAccessSchema"
                | "managedMaterialDirectory"
        )
    });
    for name in [
        "javaExecutable",
        "signerJAR",
        "keystore",
        "appCertificate",
        "signedProfile",
    ] {
        object
            .get_mut(name)?
            .as_object_mut()?
            .retain(|key, _| matches!(key.as_str(), "path" | "sha256" | "byteCount"));
    }
    decode_receipt(&serde_json::to_vec(&value).ok()?).ok()
}

fn remove_file_if_present(path: &Path) -> Result<bool, SigningError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err(SigningError::io("cannot remove signing receipt")),
    }
}
