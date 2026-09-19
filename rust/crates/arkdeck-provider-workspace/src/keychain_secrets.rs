//! Swift `LoginKeychainSigningSecretStore` as a [`SigningSecrets`] source:
//! the preset's envelope in the Data Protection Keychain under the helpers'
//! shared access group, read without user interaction, and the installed
//! daemon's code identity that a receipt is bound to.
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

    /// A source over any Keychain scope, bound to no daemon identity — for a
    /// fixture keychain.
    pub fn over(items: KeychainItems) -> Self {
        Self {
            items,
            daemon: None,
        }
    }

    /// Swift `OpenHarmonyLocalSigning.defaultAgentDaemonURL()`.
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
