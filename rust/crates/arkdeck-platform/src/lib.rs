//! OS boundaries for the read-only Rust walking skeleton.
//!
//! Paths and argv live here and in provider configuration, never in wire contracts.
//! Authentication completes before a connection is returned to a frame consumer.
#![deny(unsafe_op_in_unsafe_fn)]

use std::io;
use std::path::{Path, PathBuf};

mod frame;
mod process;
pub use frame::read_frame;
#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

pub use process::{ProcessLimits, ProcessOutput, VerifiedTool};
#[cfg(target_os = "macos")]
mod host_signature;
#[cfg(target_os = "macos")]
pub use host_signature::{
    NativeCodeSignature, inspect_deveco_publisher_signature, inspect_native_code_signature,
};
#[cfg(unix)]
pub use unix::{LocalConnection, LocalListener, LoopbackServerLease, default_user_endpoint};
#[cfg(windows)]
pub use windows::{LocalConnection, LocalListener, LoopbackServerLease, default_user_endpoint};

/// A local OS endpoint; TCP/HTTP and remote pipe names are not accepted.
#[derive(Clone, Debug)]
pub struct LocalEndpoint(PathBuf);

impl LocalEndpoint {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self(path.into())
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

/// Installation-owned daemon identity. Windows requires a trusted signing
/// certificate SHA256 or an exact MSIX package family, as well as the image path.
/// These are installation inputs, not values returned by the untrusted pipe.
#[derive(Clone, Debug)]
pub struct ServerIdentity {
    pub executable: PathBuf,
    pub authenticode_sha256: Option<String>,
    pub package_family: Option<String>,
}

impl ServerIdentity {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            authenticode_sha256: None,
            package_family: None,
        }
    }
}

pub(crate) fn denied(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

pub(crate) fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

/// OS entropy for non-authoritative request/session identifiers.
pub fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    #[cfg(unix)]
    for chunk in bytes.chunks_mut(256) {
        // SAFETY: writable buffer; getentropy accepts at most 256 bytes.
        if unsafe { libc::getentropy(chunk.as_mut_ptr().cast(), chunk.len()) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    #[cfg(windows)]
    for chunk in bytes.chunks_mut(u32::MAX as usize) {
        use windows_sys::Win32::Security::Cryptography::{
            BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
        };
        // SAFETY: the system-preferred generator needs no algorithm handle;
        // each writable chunk fits the API's u32 length.
        let status = unsafe {
            BCryptGenRandom(
                std::ptr::null_mut(),
                chunk.as_mut_ptr(),
                chunk.len() as u32,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG,
            )
        };
        if status != 0 {
            return Err(io::Error::other(format!(
                "system entropy failed: {status:#x}"
            )));
        }
    }
    Ok(bytes)
}

#[cfg(target_os = "macos")]
mod macos_control;
#[cfg(target_os = "macos")]
pub use macos_control::{PeerOrigin, listen_mach};

#[cfg(target_os = "macos")]
mod host_store;
#[cfg(target_os = "macos")]
pub use host_store::{
    DocumentPublishError, ExportPublishError, ExportStaging, HostDirectory, HostDirectoryFacts,
    HostEntryKind, HostExportCapacity, HostReadLock,
};

#[cfg(target_os = "macos")]
mod host_text;
#[cfg(target_os = "macos")]
pub use host_text::{host_canonical_text, host_control_character, host_whitespace_or_newline};

#[cfg(target_os = "macos")]
mod host_calendar;
#[cfg(target_os = "macos")]
pub use host_calendar::{
    host_gregorian_add_days, host_gregorian_seconds, host_gregorian_timestamp,
};

#[cfg(target_os = "macos")]
mod host_date_formatter;
#[cfg(target_os = "macos")]
pub use host_date_formatter::host_legacy_iso8601;

#[cfg(target_os = "macos")]
mod host_bootstrap_tree;
#[cfg(target_os = "macos")]
pub use host_bootstrap_tree::{
    BootstrapEntry, BootstrapTree, default_bootstrap_registry_root, inspect_bootstrap_tree,
};

#[cfg(target_os = "macos")]
mod bootstrap_tool_capture;
#[cfg(target_os = "macos")]
pub use bootstrap_tool_capture::{
    BootstrapToolCapture, BootstrapToolCaptureError, BootstrapToolPublication,
    BootstrapToolPublishError,
};

#[cfg(target_os = "macos")]
mod host_bundle_signature;
#[cfg(target_os = "macos")]
pub use host_bundle_signature::{bootstrap_bundle_version, validate_production_daemon_bundle};

#[cfg(target_os = "macos")]
mod bootstrap_bundle_capture;
#[cfg(target_os = "macos")]
pub use bootstrap_bundle_capture::{
    BootstrapBundleCapture, BootstrapBundleCaptureError, BootstrapBundlePublication,
    BootstrapBundlePublishError,
};

#[cfg(target_os = "macos")]
mod host_deveco_files;
#[cfg(target_os = "macos")]
pub use host_deveco_files::{
    DevEcoFileFacts, DevEcoFileRead, DevEcoIdentityChanged, DevEcoInputTooLarge, DevEcoRole,
    DevEcoRoot,
};
#[cfg(target_os = "macos")]
mod host_deveco_resources;
#[cfg(target_os = "macos")]
pub use host_deveco_resources::{DEVECO_RESOURCE_PATHS, verify_deveco_resource_envelope};
