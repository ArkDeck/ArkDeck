//! `arkdeck runtime signing …` and its deprecated `signing …` spelling:
//! Swift `RuntimeCLI.runSigning` over the workspace provider's signing preset
//! store and credential owner (`arkdeck-provider-workspace`).
//!
//! `status` is a diagnostic probe, not an authorization ceremony: it reads the
//! Keychain without user interaction, never reads a secret's value, and
//! reports readiness as the LaunchAgent would find it.
#[cfg(target_os = "macos")]
use serde_json::{Value, json};

/// Whether `command` is a signing leaf this CLI serves.
pub fn serves(command: &str) -> bool {
    matches!(command, "runtime.signing.status" | "signing.status")
}

/// Swift `OpenHarmonySigningCredentialResource.projection`.
#[cfg(target_os = "macos")]
fn projection(
    resource: &arkdeck_provider_workspace::credential_owner::CredentialResource,
) -> Value {
    json!({"schemaVersion": "arkdeck.signing-credential/1",
        "credentialRef": resource.credential_ref, "kind": "openharmony-signing",
        "projectRef": resource.project_ref, "presetId": resource.preset_id,
        "installedAtUtc": resource.installed_at_utc,
        "referenceCount": resource.reference_count, "state": "available"})
}

/// Swift's `status` leaf over the preset store at `root`: whether a preset is
/// installed, whether it validates with its secrets present
/// (`OpenHarmonySigningPresetStore.status()`), and the credential the owner
/// ledger names.
#[cfg(target_os = "macos")]
pub fn status_document(
    root: &std::path::Path,
    secrets: &dyn arkdeck_provider_workspace::signing_preset::SigningSecrets,
) -> Value {
    use arkdeck_provider_workspace::credential_owner::CredentialOwner;
    use arkdeck_provider_workspace::signing_preset::{DEFAULT_PRESET_ID, SigningPresetStore};
    let store = SigningPresetStore::new(root);
    // Foundation's `fileExists(atPath:)` follows a final symbolic link.
    let installed = store.receipt_path().exists();
    let validated = installed
        && store
            .load_validated(DEFAULT_PRESET_ID, true, secrets)
            .is_ok();
    let mut diagnostics = Vec::new();
    if !validated {
        diagnostics.push(if installed {
            "signingCredentialUnavailable"
        } else {
            "signingCredentialNotInstalled"
        });
    }
    let resource = CredentialOwner::new(store).current().ok();
    if resource.is_none() && installed {
        diagnostics.push("signingCredentialOwnerUnavailable");
    }
    json!({"schemaVersion": "arkdeck.signing-credential-status/1", "installed": installed,
        "ready": validated && resource.is_some(),
        "credential": resource.as_ref().map_or(Value::Null, projection),
        "diagnostics": diagnostics})
}

/// A secret source that could answer nothing: every item unreadable, no
/// daemon identity provable.
#[cfg(target_os = "macos")]
struct Unanswerable;

#[cfg(target_os = "macos")]
impl arkdeck_provider_workspace::signing_preset::SigningSecrets for Unanswerable {
    fn read(
        &self,
        _: &str,
    ) -> Result<arkdeck_platform::Secret, arkdeck_provider_workspace::SigningError> {
        Err(arkdeck_provider_workspace::SigningError::SecretUnavailable(
            "the signing Keychain could not be opened".into(),
        ))
    }

    fn presence(&self, _: &str) -> arkdeck_provider_workspace::signing_preset::SecretPresence {
        arkdeck_provider_workspace::signing_preset::SecretPresence::Unreadable
    }

    fn trusted_daemon_fingerprint(
        &self,
    ) -> Result<Option<String>, arkdeck_provider_workspace::SigningError> {
        Err(arkdeck_provider_workspace::SigningError::SecretUnavailable(
            "the signing Keychain could not be opened".into(),
        ))
    }
}

/// `runtime signing status`: the production preset root and the Data
/// Protection Keychain the LaunchAgent reads, bound to the installed daemon.
/// `None` where this account has no Application Support directory.
#[cfg(target_os = "macos")]
pub fn status() -> Option<Value> {
    use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
    use arkdeck_provider_workspace::signing_preset::SigningPresetStore;
    let root = SigningPresetStore::default_root()?;
    let daemon = KeychainSigningSecrets::default_daemon_executable()?;
    Some(match KeychainSigningSecrets::installed(daemon) {
        Ok(secrets) => status_document(&root, &secrets),
        Err(_) => status_document(&root, &Unanswerable),
    })
}
