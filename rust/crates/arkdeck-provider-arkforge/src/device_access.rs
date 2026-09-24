//! Swift `ProductRockchipDeviceAccessObserver`: the Rockchip flashing modes
//! the ArkForge lane's daemon sees attached, read through its public,
//! read-only socket with `discoverDevices`.
//!
//! One fresh public session per observation, bounded as a whole, as Swift's
//! `ArkForgePublicClient(socketPath:timeoutSeconds: 15)` is. Nothing here
//! opens the controller surface, and no answer carries a socket path, a
//! provider diagnostic or a USB identity: Swift answers every failure with
//! the same words, and the Runtime does too.

use arkforge_client::PublicClient;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

/// Swift's bound on the whole public session.
pub const DEVICE_ACCESS_TIMEOUT: Duration = Duration::from_secs(15);

/// Swift `RockchipDeviceMode`, spelled as the Runtime answers it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeviceMode {
    Loader,
    Maskrom,
}

impl DeviceMode {
    /// The mode as `flash.device-access` names it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Loader => "Loader",
            Self::Maskrom => "Maskrom",
        }
    }

    /// Swift's reading of an ArkForge mode name: the RockUSB Loader and
    /// MaskROM, under the profile's name or its alias. Any other mode — the
    /// HDC-normal personality, a mode a later profile adds — is no flashing
    /// mode and is left out.
    pub fn from_arkforge(mode: &str) -> Option<Self> {
        match mode {
            "rockusb-loader" | "loader" => Some(Self::Loader),
            "rockusb-maskrom" | "maskrom" => Some(Self::Maskrom),
            _ => None,
        }
    }
}

/// Why an observation failed. It stays inside the Runtime: the method's one
/// refusal names none of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceAccessFailure {
    /// The daemon was unreachable, refused the session, or failed the call;
    /// ArkForge's own code and words.
    Client { code: String, message: String },
    /// No answer within the bound.
    TimedOut,
}

/// Swift `ProductRockchipDeviceAccessObserver(runtimeDirectory:)`: ArkForge's
/// public socket in the lane's runtime directory.
#[derive(Clone, Debug)]
pub struct DeviceAccessObserver {
    runtime_directory: PathBuf,
    timeout: Duration,
}

impl DeviceAccessObserver {
    pub fn new(runtime_directory: impl Into<PathBuf>) -> Self {
        Self {
            runtime_directory: runtime_directory.into(),
            timeout: DEVICE_ACCESS_TIMEOUT,
        }
    }

    /// Another bound on the session, for tests that must not wait 15 s.
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// The directory whose `public.sock` this observer reads.
    pub fn runtime_directory(&self) -> &Path {
        &self.runtime_directory
    }

    /// The handshake, then `discoverDevices`: the flashing modes seen, in
    /// ArkForge's order, repeats kept.
    pub fn observe(&self) -> Result<Vec<DeviceMode>, DeviceAccessFailure> {
        let directory = self.runtime_directory.clone();
        let (sender, receiver) = mpsc::channel();
        // `PublicClient` bounds only its handshake; once acknowledged it waits
        // for an answer as long as it takes. The session therefore runs on a
        // thread of its own and the answer is bounded here. A daemon that
        // never answers keeps that thread until it answers or closes, but no
        // caller waits for it.
        std::thread::Builder::new()
            .name("arkforge-device-access".into())
            .spawn(move || {
                let observed =
                    PublicClient::connect(&directory).and_then(|mut client| client.device_list());
                let _ = sender.send(observed);
            })
            .map_err(|error| DeviceAccessFailure::Client {
                code: "SESSION_UNAVAILABLE".into(),
                message: error.to_string(),
            })?;
        match receiver.recv_timeout(self.timeout) {
            Ok(Ok(observations)) => Ok(observations
                .iter()
                .filter_map(|observation| DeviceMode::from_arkforge(&observation.mode))
                .collect()),
            Ok(Err(error)) => Err(DeviceAccessFailure::Client {
                code: error.code,
                message: error.message,
            }),
            Err(_) => Err(DeviceAccessFailure::TimedOut),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DeviceMode;

    /// Swift's `RockchipDeviceAccessAdvisorContractTests` case, and the
    /// DAYU200 profile's names and aliases.
    #[test]
    fn only_the_rockusb_modes_are_flashing_modes() {
        let modes: Vec<_> = [
            "rockusb-loader",
            "loader",
            "rockusb-maskrom",
            "maskrom",
            "hdcNormal",
            "hdc-normal",
            "normal",
            "Loader",
            "",
        ]
        .iter()
        .filter_map(|mode| DeviceMode::from_arkforge(mode))
        .collect();
        assert_eq!(
            modes,
            [
                DeviceMode::Loader,
                DeviceMode::Loader,
                DeviceMode::Maskrom,
                DeviceMode::Maskrom
            ]
        );
        assert_eq!(
            [DeviceMode::Loader.as_str(), DeviceMode::Maskrom.as_str()],
            ["Loader", "Maskrom"]
        );
    }
}
