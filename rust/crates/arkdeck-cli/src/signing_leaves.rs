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
    matches!(
        command,
        "runtime.signing.status"
            | "signing.status"
            | "runtime.signing.remove"
            | "signing.remove"
            | "runtime.signing.install"
            | "signing.install"
            | "runtime.signing.migrate-deveco"
            | "signing.migrate-deveco"
    )
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

/// Swift `runSigning`'s removal projection over the same credential owner
/// used by workspace preset registration. Tests inject a remover that never
/// reaches a Keychain; production supplies the fixed ArkDeck service scope.
#[cfg(target_os = "macos")]
pub fn remove_document(
    root: &std::path::Path,
    secrets: &dyn arkdeck_provider_workspace::signing_removal::SigningSecretRemoval,
) -> Result<Value, arkdeck_provider_workspace::SigningError> {
    use arkdeck_provider_workspace::credential_owner::CredentialOwner;
    use arkdeck_provider_workspace::signing_preset::SigningPresetStore;
    let removed = CredentialOwner::new(SigningPresetStore::new(root)).remove(secrets)?;
    Ok(
        json!({"schemaVersion": "arkdeck.signing-credential-removal/1", "state": "removed",
        "removedReceipt": removed.removed_receipt,
        "removedKeystorePassword": removed.removed_keystore_password,
        "removedKeyPassword": removed.removed_key_password,
        "removedManagedMaterial": removed.removed_managed_material,
        "preservedSourceCount": removed.preserved_source_count}),
    )
}

#[cfg(target_os = "macos")]
pub fn run(invocation: &crate::Invocation) -> Result<Value, crate::CliError> {
    let command = invocation.command;
    use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
    use arkdeck_provider_workspace::signing_preset::SigningPresetStore;
    let no_home = || {
        crate::CliError::new(
            "ioFailure",
            "this account has no Application Support directory for the signing preset",
        )
    };
    if matches!(command, "runtime.signing.status" | "signing.status") {
        return status().ok_or_else(no_home);
    }
    if !matches!(
        command,
        "runtime.signing.remove"
            | "signing.remove"
            | "runtime.signing.install"
            | "signing.install"
            | "runtime.signing.migrate-deveco"
            | "signing.migrate-deveco"
    ) {
        return Err(crate::CliError::new(
            "invalidCommand",
            "unsupported signing subcommand",
        ));
    }
    let root = SigningPresetStore::default_root().ok_or_else(no_home)?;
    let daemon = KeychainSigningSecrets::default_daemon_executable().ok_or_else(no_home)?;
    let empty = serde_json::Map::new();
    let options = invocation.params.as_ref().unwrap_or(&empty);
    if matches!(
        command,
        "runtime.signing.migrate-deveco" | "signing.migrate-deveco"
    ) {
        validate_migration_daemon(command, options, &daemon)?;
    }
    let secrets = KeychainSigningSecrets::for_maintenance(daemon).map_err(signing_error)?;
    if matches!(command, "runtime.signing.install" | "signing.install") {
        let empty = serde_json::Map::new();
        install_document(
            &root,
            command,
            invocation.params.as_ref().unwrap_or(&empty),
            &secrets,
            &mut |prompt| {
                arkdeck_platform::read_terminal_secret(prompt).map_err(|error| crate::CliError {
                    plain_exit: Some(error.exit_code),
                    ..crate::CliError::new("ioFailure", error.message)
                })
            },
            &crate::utc_now(),
        )
    } else if matches!(
        command,
        "runtime.signing.migrate-deveco" | "signing.migrate-deveco"
    ) {
        migrate_deveco_document(&root, options, &secrets)
    } else {
        remove_document(&root, &secrets).map_err(signing_error)
    }
}

/// Before changing a service installation, reject an unreadable or drifted
/// preset using public file identities only. This probe creates no owner
/// ledger and never opens or reads the Keychain.
#[cfg(target_os = "macos")]
pub fn validate_refresh(
    root: &std::path::Path,
) -> Result<(), arkdeck_provider_workspace::SigningError> {
    use arkdeck_provider_workspace::signing_preset::{DEFAULT_PRESET_ID, SigningPresetStore};
    SigningPresetStore::new(root)
        .load_validated(DEFAULT_PRESET_ID, false, &Unanswerable)
        .map(|_| ())
}

/// Production `beforeBootstrap`: bind the still-installed credential to the
/// freshly verified, installed helper. Identity comes from the platform's
/// code-signature check, never from the caller's JSON or a supplied digest.
#[cfg(target_os = "macos")]
pub fn refresh_installed_identity(
    root: &std::path::Path,
    daemon: &std::path::Path,
) -> Result<(), String> {
    use arkdeck_provider_workspace::credential_owner::CredentialOwner;
    use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
    use arkdeck_provider_workspace::signing_preset::SigningPresetStore;
    let secrets =
        KeychainSigningSecrets::installed(daemon.to_owned()).map_err(|e| e.to_string())?;
    CredentialOwner::new(SigningPresetStore::new(root))
        .refresh_daemon_identity(&secrets)
        .map_err(|e| e.to_string())
}

#[cfg(target_os = "macos")]
fn signing_error(error: arkdeck_provider_workspace::SigningError) -> crate::CliError {
    crate::CliError {
        plain_exit: Some(1),
        ..crate::CliError::new("ioFailure", error.to_string())
    }
}

/// Explicit CLI installation. Secret readers are injected only at this Rust
/// boundary for fixtures; public argv/JSON never accepts plaintext passwords.
#[cfg(target_os = "macos")]
pub fn install_document(
    root: &std::path::Path,
    command: &str,
    options: &serde_json::Map<String, Value>,
    secrets: &dyn arkdeck_provider_workspace::signing_install::SigningSecretInstallation,
    read_secret: &mut dyn FnMut(&str) -> Result<arkdeck_platform::Secret, crate::CliError>,
    now: &str,
) -> Result<Value, crate::CliError> {
    use arkdeck_provider_workspace::{
        credential_owner::CredentialOwner, deveco_password::decode_if_needed,
        secret_envelope::SecretPair, signing_install::SigningPresetConfiguration,
        signing_preset::SigningPresetStore,
    };
    use std::path::{Path, PathBuf};
    let spelling = command.replace('.', " ");
    let required = |key: &str, flag: &str| {
        options
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| crate::CliError::plain_usage(format!("{spelling} requires {flag}")))
    };
    let java = required("java", "--java")?;
    let jar = required("jar", "--jar")?;
    let keystore = required("keystore", "--keystore")?;
    let certificate = required("certificate", "--certificate")?;
    let profile = required("profile", "--profile")?;
    for (flag, path) in [
        ("--java", java),
        ("--jar", jar),
        ("--keystore", keystore),
        ("--certificate", certificate),
        ("--profile", profile),
    ] {
        if !path.starts_with('/') {
            return Err(crate::CliError::plain_usage(format!(
                "{spelling} {flag} must be an absolute path"
            )));
        }
    }
    let (keystore_password, key_password) =
        if let Some(path) = options.get("buildProfile").and_then(Value::as_str) {
            if !path.starts_with('/') {
                return Err(crate::CliError::plain_usage(format!(
                    "{spelling} --build-profile must be an absolute path"
                )));
            }
            let material = crate::signing_inputs::read_deveco_profile(Path::new(path))?;
            // Compare standardized paths without following symlinks, as Swift's
            // CLI does before binding the adjacent DevEco material.
            if lexical_absolute(&material.store_file) != lexical_absolute(Path::new(keystore)) {
                return Err(crate::CliError::plain_usage(format!(
                    "{spelling} --build-profile names a different storeFile than --keystore"
                )));
            }
            (material.keystore, material.key)
        } else {
            (
                read_secret("Keystore password: ")?,
                read_secret("Key password: ")?,
            )
        };
    let passwords = SecretPair {
        keystore: decode_if_needed(keystore_password.as_bytes(), Path::new(keystore))
            .map_err(signing_error)?,
        key: decode_if_needed(key_password.as_bytes(), Path::new(keystore))
            .map_err(signing_error)?,
    };
    let configuration = SigningPresetConfiguration {
        project_ref: options
            .get("projectRef")
            .and_then(Value::as_str)
            .unwrap_or("demo-app")
            .into(),
        java_executable: PathBuf::from(java),
        signer_jar: PathBuf::from(jar),
        keystore: PathBuf::from(keystore),
        app_certificate: PathBuf::from(certificate),
        signed_profile: PathBuf::from(profile),
        key_alias: required("keyAlias", "--key-alias")?.into(),
        managed_material_directory: None,
    };
    CredentialOwner::new(SigningPresetStore::new(root))
        .install(&configuration, &passwords, secrets, now)
        .map(|resource| projection(&resource))
        .map_err(signing_error)
}

#[cfg(target_os = "macos")]
fn lexical_absolute(path: &std::path::Path) -> std::path::PathBuf {
    let mut result = std::path::PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                result.pop();
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

/// Reject caller-selected daemons before opening the maintenance Keychain.
#[cfg(target_os = "macos")]
pub fn validate_migration_daemon(
    command: &str,
    options: &serde_json::Map<String, Value>,
    installed: &std::path::Path,
) -> Result<(), crate::CliError> {
    let spelling = command.replace('.', " ");
    let profile = options
        .get("buildProfile")
        .and_then(Value::as_str)
        .unwrap_or("");
    let daemon = options.get("daemon").and_then(Value::as_str).unwrap_or("");
    if !profile.starts_with('/') || !daemon.starts_with('/') {
        return Err(crate::CliError::plain_usage(format!(
            "{spelling} requires --build-profile and --daemon absolute paths"
        )));
    }
    if lexical_absolute(std::path::Path::new(daemon)) != installed
        || arkdeck_provider_workspace::foundation_resolved_path(daemon).as_deref()
            != installed.to_str()
    {
        return Err(crate::CliError::plain_usage(format!(
            "{spelling} --daemon must name the canonical installed LaunchAgent daemon"
        )));
    }
    Ok(())
}

/// The authenticated build-profile's adjacent material is the decryption
/// anchor; only a measured match to the installed keystore may replace it.
#[cfg(target_os = "macos")]
pub fn migrate_deveco_document(
    root: &std::path::Path,
    options: &serde_json::Map<String, Value>,
    secrets: &dyn arkdeck_provider_workspace::signing_install::SigningSecretInstallation,
) -> Result<Value, crate::CliError> {
    use arkdeck_provider_workspace::{
        credential_owner::CredentialOwner,
        deveco_password::decode_if_needed,
        secret_envelope::SecretPair,
        signing_preset::{DEFAULT_PRESET_ID, SigningPresetStore},
    };
    let store = SigningPresetStore::new(root);
    let receipt = store
        .load_validated(DEFAULT_PRESET_ID, false, secrets)
        .map_err(signing_error)?;
    let profile = options
        .get("buildProfile")
        .and_then(Value::as_str)
        .ok_or_else(|| crate::CliError::plain_usage("migrate-deveco requires --build-profile"))?;
    let material = crate::signing_inputs::read_deveco_profile(std::path::Path::new(profile))?;
    let source = arkdeck_provider_workspace::measure(
        material.store_file.to_str().unwrap(),
        "DevEco build-profile keystore",
        false,
        true,
    )
    .map_err(signing_error)?;
    if source.sha256 != receipt.keystore.sha256 || source.byte_count != receipt.keystore.byte_count
    {
        return Err(signing_error(
            arkdeck_provider_workspace::SigningError::IdentityDrift(
                "DevEco build-profile keystore does not match the installed preset".into(),
            ),
        ));
    }
    let passwords = SecretPair {
        keystore: decode_if_needed(material.keystore.as_bytes(), &material.store_file)
            .map_err(signing_error)?,
        key: decode_if_needed(material.key.as_bytes(), &material.store_file)
            .map_err(signing_error)?,
    };
    let (created, resource) = CredentialOwner::new(store)
        .replace_secret_envelope(
            &receipt,
            &passwords,
            options.get("keyAlias").and_then(Value::as_str),
            secrets,
        )
        .map_err(signing_error)?;
    Ok(
        json!({"schemaVersion":"arkdeck.signing-credential-maintenance/1",
        "operation":"migrate-deveco", "credential":projection(&resource),
        "createdEnvelopeItem":created}),
    )
}
