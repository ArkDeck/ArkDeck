//! Swift `LoginKeychainSigningSecretStore` as a [`SigningSecrets`] source:
//! the preset's envelope in the Data Protection Keychain under the helpers'
//! shared access group, read without user interaction by Runtime composition,
//! with a separate interactive maintenance constructor, and the installed
//! daemon's code identity that a receipt is bound to.
//!
//! On Windows (TASK-XPA-011) the same items live in Credential Manager
//! (`arkdeck_platform::KeychainItems`, the same item identity), and the
//! daemon's code identity is its Authenticode signer and bytes
//! (`arkdeck_platform::trusted_daemon_fingerprint`). Where the Windows daemon
//! is installed is the caller's to say (the CLI's installation inputs), so
//! `KeychainSigningSecrets::default_daemon_executable` stays macOS-only.
use crate::SigningError;
use crate::signing_preset::{KEYCHAIN_SERVICE, SecretPresence, SigningSecrets};
use arkdeck_platform::{
    DAEMON_KEYCHAIN_ACCESS_GROUP, KeychainError, KeychainItems, KeychainPresence, Secret,
};
use std::path::{Path, PathBuf};

pub struct KeychainSigningSecrets {
    items: KeychainItems,
    daemon: Option<PathBuf>,
}

impl KeychainSigningSecrets {
    /// The production source: the Data Protection Keychain and the daemon
    /// executable a receipt's identity is checked against.
    pub fn installed(daemon_executable: PathBuf) -> Result<Self, SigningError> {
        Ok(Self {
            items: KeychainItems::data_protection(KEYCHAIN_SERVICE, DAEMON_KEYCHAIN_ACCESS_GROUP)
                .map_err(keychain_failure("Keychain"))?,
            daemon: Some(daemon_executable),
        })
    }

    /// Explicit maintenance CLI's interactive Keychain policy. Runtime
    /// composition continues to call `installed`, which never prompts.
    pub fn for_maintenance(daemon_executable: PathBuf) -> Result<Self, SigningError> {
        Ok(Self {
            items: KeychainItems::data_protection_for_maintenance(
                KEYCHAIN_SERVICE,
                DAEMON_KEYCHAIN_ACCESS_GROUP,
            )
            .map_err(keychain_failure("Keychain"))?,
            daemon: Some(daemon_executable),
        })
    }

    /// A source over any Keychain scope, bound to no daemon identity — for a
    /// fixture keychain.
    pub fn over(items: KeychainItems) -> Self {
        Self {
            items,
            daemon: None,
        }
    }

    /// The same source bound to the daemon executable a receipt's identity
    /// is checked against — for a fixture keychain and a fixture daemon.
    pub fn bound_to(self, daemon_executable: PathBuf) -> Self {
        Self {
            daemon: Some(daemon_executable),
            ..self
        }
    }

    /// Swift `OpenHarmonyLocalSigning.defaultAgentDaemonURL()`.
    #[cfg(target_os = "macos")]
    pub fn default_daemon_executable() -> Option<PathBuf> {
        arkdeck_platform::arkdeck_application_support_root()
            .map(|root| root.join("Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"))
    }

    pub fn items(&self) -> &KeychainItems {
        &self.items
    }

    pub fn daemon(&self) -> Option<&Path> {
        self.daemon.as_deref()
    }
}

fn keychain_failure(operation: &'static str) -> impl Fn(KeychainError) -> SigningError {
    move |error| match error {
        KeychainError::Status(status) => {
            SigningError::secret(format!("{operation} status {status}"))
        }
        KeychainError::Refused(reason) => SigningError::secret(format!("{operation}: {reason}")),
    }
}

impl SigningSecrets for KeychainSigningSecrets {
    fn read(&self, account: &str) -> Result<Secret, SigningError> {
        self.items
            .read(account)
            .map_err(keychain_failure("Keychain read"))
    }

    fn presence(&self, account: &str) -> SecretPresence {
        match self.items.presence(account) {
            KeychainPresence::Present => SecretPresence::Present,
            KeychainPresence::Absent => SecretPresence::Absent,
            KeychainPresence::Unreadable(_) => SecretPresence::Unreadable,
        }
    }

    fn trusted_daemon_fingerprint(&self) -> Result<Option<String>, SigningError> {
        let Some(daemon) = &self.daemon else {
            return Ok(None);
        };
        arkdeck_platform::trusted_daemon_fingerprint(daemon)
            .map(Some)
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::PermissionDenied => {
                    SigningError::unsafe_file("installed arkdeck-agentd helper is absent or unsafe")
                }
                _ => SigningError::secret(error.to_string()),
            })
    }
}

impl crate::signing_removal::SigningSecretRemoval for KeychainSigningSecrets {
    fn remove_current(&self, account: &str) -> Result<bool, SigningError> {
        self.items
            .remove(account)
            .map_err(keychain_failure("Keychain removal"))
    }

    fn remove_legacy(&self, account: &str) -> Result<bool, SigningError> {
        KeychainItems::outside_data_protection(KEYCHAIN_SERVICE)
            .map_err(keychain_failure("legacy Keychain"))?
            .remove(account)
            .map_err(keychain_failure("legacy Keychain removal"))
    }
}

impl crate::signing_install::SigningSecretInstallation for KeychainSigningSecrets {
    fn set_envelope(&self, account: &str, bytes: &[u8]) -> Result<(), SigningError> {
        self.items
            .set(account, bytes)
            .map_err(keychain_failure("Keychain write"))
    }

    fn remove_envelope(&self, account: &str) -> Result<bool, SigningError> {
        self.items
            .remove(account)
            .map_err(keychain_failure("Keychain removal"))
    }
}
