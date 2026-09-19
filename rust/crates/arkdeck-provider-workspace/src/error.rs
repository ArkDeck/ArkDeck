use std::fmt;

/// Swift `OpenHarmonySigningError`: the closed failure classes of the signing
/// layer. The text is diagnostic (T2) and never contains a secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SigningError {
    InvalidConfiguration(String),
    UnsafeFile(String),
    IdentityDrift(String),
    ReceiptUnavailable(String),
    SecretUnavailable(String),
    IoFailure(String),
}

impl SigningError {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidConfiguration(message.into())
    }

    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn unsafe_file(message: impl Into<String>) -> Self {
        Self::UnsafeFile(message.into())
    }

    pub(crate) fn drift(message: impl Into<String>) -> Self {
        Self::IdentityDrift(message.into())
    }

    pub(crate) fn receipt(message: impl Into<String>) -> Self {
        Self::ReceiptUnavailable(message.into())
    }

    pub(crate) fn secret(message: impl Into<String>) -> Self {
        Self::SecretUnavailable(message.into())
    }

    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(crate) fn io(message: impl Into<String>) -> Self {
        Self::IoFailure(message.into())
    }
}

impl fmt::Display for SigningError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfiguration(value) => {
                write!(formatter, "invalid signing configuration: {value}")
            }
            Self::UnsafeFile(value) => write!(formatter, "unsafe signing file: {value}"),
            Self::IdentityDrift(value) => write!(formatter, "signing identity drift: {value}"),
            Self::ReceiptUnavailable(value) => {
                write!(formatter, "signing receipt unavailable: {value}")
            }
            Self::SecretUnavailable(value) => {
                write!(formatter, "signing secret unavailable: {value}")
            }
            Self::IoFailure(value) => write!(formatter, "signing I/O failure: {value}"),
        }
    }
}

impl std::error::Error for SigningError {}
