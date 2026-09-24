//! The signing half of Swift's daemon composition root for the workspace
//! provider (TASK-XPA-015, M3): the installed signing preset store, its
//! credential owner and the secret source it reads, as the Runtime composes
//! them — and the credential pins a workspace signing preset's registration
//! takes and releases through the same owner.
//!
//! The installed daemon reads the account's preset store and the Data
//! Protection Keychain, bound to the installed daemon's own code identity.
//! A secret never leaves that source except into the signer's terminal.
use crate::workspace_project::WorkspaceCredentialPinning;
use arkdeck_contract::WireError;
use arkdeck_provider_workspace::credential_owner::CredentialOwner;
use arkdeck_provider_workspace::keychain_secrets::KeychainSigningSecrets;
use arkdeck_provider_workspace::signing_preset::{SigningPresetStore, SigningSecrets};
use std::path::PathBuf;
use std::sync::Arc;

/// What the composition root hands the workspace composition for signing:
/// the preset store's root, the secret source and the attempt store's root.
pub struct SigningSetup {
    pub(crate) store_root: PathBuf,
    pub(crate) secrets: Box<dyn SigningSecrets + Send + Sync>,
    pub(crate) attempts_root: PathBuf,
    /// Swift releases the credential owners no registered preset carries
    /// only when it owns the default state directory.
    pub(crate) releases_orphaned_owners: bool,
}

impl SigningSetup {
    /// The installed daemon's signing: the preset store at `store_root`, the
    /// Data Protection Keychain bound to `daemon_executable`'s identity, and
    /// the attempts below `attempts_root`.
    pub fn keychain(
        store_root: PathBuf,
        attempts_root: PathBuf,
        daemon_executable: PathBuf,
        releases_orphaned_owners: bool,
    ) -> Result<Self, String> {
        let secrets = KeychainSigningSecrets::installed(daemon_executable)
            .map_err(|error| error.to_string())?;
        Ok(Self {
            store_root,
            secrets: Box::new(secrets),
            attempts_root,
            releases_orphaned_owners,
        })
    }

    /// Signing over any secret source (a fixture's).
    pub fn with_secrets(
        store_root: PathBuf,
        attempts_root: PathBuf,
        secrets: Box<dyn SigningSecrets + Send + Sync>,
    ) -> Self {
        Self {
            store_root,
            secrets,
            attempts_root,
            releases_orphaned_owners: false,
        }
    }

    /// The same signing, its composition releasing at start-up the pins no
    /// preset record carries, as the Runtime owning the default state
    /// directory does.
    pub fn releasing_orphaned_owners(mut self) -> Self {
        self.releases_orphaned_owners = true;
        self
    }
}

fn conflict(message: impl Into<String>) -> WireError {
    WireError {
        code: "resourceConflict".into(),
        message: message.into(),
        details: None,
    }
}

/// [`credential_pinning`] over the installed daemon's secret source: the
/// Data Protection Keychain bound to `daemon_executable`'s code identity.
pub fn keychain_credential_pinning(
    store_root: PathBuf,
    daemon_executable: PathBuf,
) -> Result<WorkspaceCredentialPinning, String> {
    let secrets =
        KeychainSigningSecrets::installed(daemon_executable).map_err(|error| error.to_string())?;
    Ok(credential_pinning(store_root, Box::new(secrets)))
}

/// Swift's `RuntimeWorkspaceCredentialPinning` over its
/// `OpenHarmonySigningCredentialOwner`: a signing preset may pin only a
/// credential bound to its own project — checked before the preset store
/// writes its intent and again at the pin — and the pin and its release are
/// the owner's ledger's.
pub fn credential_pinning(
    store_root: PathBuf,
    secrets: Box<dyn SigningSecrets + Send + Sync>,
) -> WorkspaceCredentialPinning {
    let owner = Arc::new(CredentialOwner::new(SigningPresetStore::new(store_root)));
    let secrets: Arc<dyn SigningSecrets + Send + Sync> = Arc::from(secrets);
    let binding = {
        let owner = Arc::clone(&owner);
        let secrets = Arc::clone(&secrets);
        move |reference: &str, project: &str| -> Result<(), WireError> {
            // No owner, no secrets: the binding is on the receipt.
            let credential = owner
                .resolve(reference, None, false, &*secrets)
                .map_err(|_| conflict("signing credential pin could not be validated"))?;
            if credential.project_ref != project {
                return Err(conflict(format!(
                    "signing credential {reference} is bound to project {}, not {project}",
                    credential.project_ref
                )));
            }
            Ok(())
        }
    };
    let binding = Arc::new(binding);
    let acquire_binding = Arc::clone(&binding);
    let acquiring = Arc::clone(&owner);
    let acquire_secrets = Arc::clone(&secrets);
    WorkspaceCredentialPinning {
        validate_binding: Box::new(move |reference, project| binding(reference, project)),
        acquire: Box::new(move |reference, preset, project| {
            acquire_binding(reference, project)?;
            acquiring
                .acquire(reference, preset, &*acquire_secrets)
                .map_err(|_| conflict("signing credential pin could not be validated"))
        }),
        release: Box::new(move |reference, preset| {
            owner
                .release(reference, preset)
                .map_err(|_| conflict("signing credential pin could not be released"))
        }),
    }
}
