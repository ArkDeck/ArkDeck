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

#[cfg(any(target_os = "macos", windows))]
pub use process::ToolLaunchIdentity;
#[cfg(target_os = "macos")]
pub use process::{ManagedServer, VerifiedNamespace, VerifiedResource, VerifiedSource};
// The analyzer runner on macOS and Windows (TASK-XPA-011).
#[cfg(any(target_os = "macos", windows))]
pub use process::{AnalyzerExecution, AnalyzerLimits, AnalyzerRunError, AnalyzerTermination};
#[cfg(any(target_os = "macos", windows))]
pub use process::{
    DeviceShellAnswer, DeviceShellChannel, DeviceShellChannelError, PtyError, PtyExecution,
    PtyFailureCategory, PtyInteraction, PtyRequest, ToolExecution, ToolLimits, ToolRequest,
    ToolRunError, ToolTermination,
};
pub use process::{ProcessLimits, ProcessOutput, VerifiedTool};
#[cfg(any(target_os = "macos", windows))]
mod server_identity;
#[cfg(any(target_os = "macos", windows))]
pub use server_identity::{
    ProvedProcessEnd, ServerExit, ServerIdentityReceipt, ServerLaunch, ServerStop,
};
#[cfg(unix)]
mod account;
#[cfg(unix)]
pub use account::{
    FileMeasureError, application_support_directory, arkdeck_application_support_root,
    effective_user_id, executable_by_caller, measure_unchanged_file, runtime_home,
};
#[cfg(unix)]
mod temporary_directory;
#[cfg(unix)]
pub use temporary_directory::foundation_temporary_directory;
mod secret;
#[cfg(target_os = "macos")]
mod terminal_secret;
pub use secret::{Secret, wipe};
#[cfg(target_os = "macos")]
pub use terminal_secret::{TerminalSecretError, read_terminal_secret};
// The Windows console reader and Credential Manager store (TASK-XPA-011, G13)
// with the macOS surface, and `trusted_daemon_fingerprint` over the daemon's
// Authenticode signer and bytes.
#[cfg(windows)]
pub use windows::{
    CREDENTIAL_NOT_FOUND, DAEMON_KEYCHAIN_ACCESS_GROUP, KeychainError, KeychainItems,
    KeychainPresence, TerminalSecretError, read_terminal_secret, trusted_daemon_fingerprint,
    with_credential_manager_turn,
};
// The Windows counterpart of the `/.vol`-bound source (a held file and
// namespace) and the signing layer's private entries (TASK-XPA-011).
#[cfg(windows)]
pub use windows::{
    VerifiedSource, create_private_directories, create_private_directory, create_private_file,
};
mod tool_shim;
#[cfg(target_os = "macos")]
pub use tool_shim::resolve as resolve_tool_shim;
pub use tool_shim::{
    XCODE_TOOL_SHIM_IDENTIFIER, bytes_are_tool_shim, is_tool_shim, signing_identifiers,
};
#[cfg(feature = "allocation-meter")]
mod allocation_meter;
#[cfg(feature = "allocation-meter")]
pub use allocation_meter::{AllocationMeter, peak_allocation};
#[cfg(target_os = "macos")]
mod keychain;
#[cfg(target_os = "macos")]
pub use keychain::{
    DAEMON_KEYCHAIN_ACCESS_GROUP, KeychainError, KeychainItems, KeychainPresence,
    trusted_daemon_fingerprint,
};
#[cfg(target_os = "macos")]
mod host_signature;
#[cfg(target_os = "macos")]
mod host_url;
#[cfg(target_os = "macos")]
mod update_http;
#[cfg(target_os = "macos")]
pub use host_signature::{
    HostUpdateSigningError, NativeCodeSignature, inspect_deveco_publisher_signature,
    inspect_native_code_signature, running_update_team, validate_running_update_code,
    validate_update_code,
};
#[cfg(target_os = "macos")]
pub use host_url::{
    HostDiagnosticLevel, HostUpdateContext, HostUrlParts, host_diagnostic_log, host_file_url,
    host_update_context, host_update_record_attempt, host_update_reveal, host_url_with_query,
    host_url_without_query_names, inspect_host_url,
};
#[cfg(all(unix, not(target_os = "macos")))]
pub use unix::LoopbackServerLease;
#[cfg(unix)]
pub use unix::{
    ConnectionCloser, ListenerLock, LocalConnection, LocalListener, Readiness,
    default_user_endpoint,
};
#[cfg(target_os = "macos")]
pub use update_http::{UpdateHttpError, UpdateHttpEvents, UpdateHttpRequest, stream_update_http};
#[cfg(unix)]
mod stop_signal;
#[cfg(unix)]
pub use stop_signal::{Latch, StopSignal};
#[cfg(target_os = "macos")]
mod macos_server;
#[cfg(target_os = "macos")]
pub use macos_server::{
    LoopbackServerLease, end_proved_process, process_argument_record, process_arguments,
    verifies_managed_process,
};
#[cfg(windows)]
pub use windows::{
    ConnectionCloser, DetachedDaemon, GuardAcquisition, GuardObject, ImagePin, InstanceScope,
    Latch, ListenerLock, LocalConnection, LocalListener, LoopbackServerLease, ManagedServer,
    OWNER_ONLY_REMEDY, OwnerLock, PortHolder, Readiness, SingleInstanceGuard, StarterLock,
    StateRoot, StopSignal, await_pipe_instance, default_user_endpoint, end_proved_process,
    pipe_present, pipe_server_pid, port_holders, send_console_break, verify_daemon_image,
};

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

/// Installation-owned daemon identity. Windows requires the image path and one
/// of: an exact MSIX package family (MSIX daemon), a publisher identity (xcopy
/// daemon signed by Artifact Signing: subject organisation and identity EKU,
/// both or neither, under the pinned Microsoft root), or a trusted signing
/// certificate SHA256 (development signer). These are installation inputs,
/// not values returned by the untrusted pipe.
#[derive(Clone, Debug)]
pub struct ServerIdentity {
    pub executable: PathBuf,
    pub authenticode_sha256: Option<String>,
    pub package_family: Option<String>,
    /// The signer leaf's exact subject `O=` (maintainer ruling 17).
    pub publisher_organization: Option<String>,
    /// The Artifact Signing certificate-profile identity EKU,
    /// `1.3.6.1.4.1.311.97.<profile>` (maintainer ruling 17).
    pub publisher_eku: Option<String>,
}

impl ServerIdentity {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            authenticode_sha256: None,
            package_family: None,
            publisher_organization: None,
            publisher_eku: None,
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
    DocumentPublishError, ExclusiveOutcome, ExportPublishError, ExportStaging, FileExportStaging,
    HostDiagnosticWriter, HostDirectory, HostDirectoryFacts, HostDocument, HostDocumentPass,
    HostEntryKind, HostExportCapacity, HostFileIdentity, HostImportSource, HostJournal,
    HostJournalAppender, HostReadLock, HostUpdateDownload, HostUploadFile, HostUploadReader,
    JournalAppendError, JournalWritePoint, OwnerOnlyReadFailure, PayloadCheck, PayloadVerification,
    PreparedSessionRemoval, PreparedTraceRemoval, UpdateDownloadError, UploadChunkCheckpoint,
    UploadWritePoint,
};

// The same durable host store on NTFS (TASK-XPA-005): the core document,
// lock, publication and Job journal surface, the import-upload submodule
// (TASK-XPA-008), (TASK-XPA-006) the export, file-export and payload-cache
// submodules and the identity-typed `document_metadata`/`remove_document`,
// (TASK-XPA-021) the trace-removal submodule and (TASK-XPA-005) the Session
// removal. The update and diagnostic-log submodules are not on Windows yet.
#[cfg(windows)]
pub use windows::host_store::{
    DocumentPublishError, ExclusiveOutcome, ExportPublishError, ExportStaging, FileExportStaging,
    HostDirectory, HostDirectoryFacts, HostDocument, HostDocumentPass, HostEntryKind,
    HostExportCapacity, HostFileIdentity, HostImportSource, HostJournal, HostJournalAppender,
    HostReadLock, HostUploadFile, HostUploadReader, JournalAppendError, JournalWritePoint,
    OwnerOnlyReadFailure, PayloadCheck, PayloadVerification, PreparedSessionRemoval,
    PreparedTraceRemoval, UploadChunkCheckpoint, UploadWritePoint,
};
#[cfg(windows)]
pub use windows::{application_support_directory, arkdeck_application_support_root, runtime_home};
// A workspace project root, pinned by the identity it was registered with
// (TASK-XPA-015).
#[cfg(windows)]
pub use windows::InspectedDirectory;

#[cfg(any(target_os = "macos", windows))]
mod host_sqlite;
#[cfg(any(target_os = "macos", windows))]
pub use host_sqlite::{HostSqlite, SqliteValue};

// Portable: pinned Unicode tables in place of CoreFoundation's character sets
// and NFC. The Foundation originals stay as the macOS tests' parity oracle.
mod host_text;
#[cfg(all(test, target_os = "macos"))]
mod host_text_foundation;
pub use host_text::{
    host_alphanumeric, host_canonical_text, host_control_character, host_whitespace_or_newline,
};

#[cfg(target_os = "macos")]
mod host_url_properties;
#[cfg(target_os = "macos")]
pub use host_url_properties::{EntryPresentation, host_entry_presentation};

#[cfg(target_os = "macos")]
mod host_inflate;
#[cfg(target_os = "macos")]
pub use host_inflate::{INFLATE_WINDOW_BYTES, InflateError, RawInflate};
// Windows has no raw DEFLATE decoder of its own; the platform's decoder
// gives the same answers (TASK-XPA-010).
#[cfg(windows)]
pub use windows::{INFLATE_WINDOW_BYTES, InflateError, RawInflate};

// Portable: Foundation's Julian/Gregorian UTC calendar and the legacy
// ISO8601DateFormatter's written shape, with the Foundation originals as the
// macOS tests' parity oracle.
mod host_calendar;
#[cfg(all(test, target_os = "macos"))]
mod host_calendar_foundation;
pub use host_calendar::{
    host_gregorian_add_days, host_gregorian_seconds, host_gregorian_timestamp,
};

mod host_date_formatter;
#[cfg(all(test, target_os = "macos"))]
mod host_date_formatter_foundation;
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
pub use host_bundle_signature::{
    bootstrap_bundle_version, validate_facade_signature, validate_production_daemon_bundle,
};

#[cfg(target_os = "macos")]
pub mod launchd;

#[cfg(target_os = "macos")]
mod property_list;
#[cfg(target_os = "macos")]
pub use property_list::{
    MAX_PROPERTY_LIST_BYTES, PropertyListValue, read_property_list, write_property_list_xml,
};

#[cfg(target_os = "macos")]
mod owner_file;
#[cfg(target_os = "macos")]
pub use owner_file::{OwnerFileRefusal, read_owner_controlled_file};

#[cfg(target_os = "macos")]
mod helper_replace;
#[cfg(target_os = "macos")]
pub use helper_replace::{clone_tree, exchange_paths};

#[cfg(target_os = "macos")]
mod tree_snapshot;
#[cfg(target_os = "macos")]
pub use tree_snapshot::{TreeEntry, TreeEntryKind, snapshot_tree};

#[cfg(target_os = "macos")]
mod profile_file_reader;
#[cfg(target_os = "macos")]
pub use profile_file_reader::{
    ProfilePath, ProfileReadError, ProfileSnapshot, has_no_symlink_component,
    is_physical_directory, open_or_create_owner_private_directory, open_physical_directory,
    open_profile_path, profile_file_matches, read_profile_file, validate_owner_only_authority,
};

#[cfg(target_os = "macos")]
mod static_code;
#[cfg(target_os = "macos")]
pub use static_code::{StaticCodeExpectation, static_code_holds};

#[cfg(target_os = "macos")]
mod diagnostic_bundle;
#[cfg(target_os = "macos")]
pub use diagnostic_bundle::{
    BundleFailure, BundleFaultPoint, BundleParent, bundle_parent, operating_system_version,
    publish_bundle, valid_relative_path,
};

#[cfg(target_os = "macos")]
mod distribution_tree;
#[cfg(target_os = "macos")]
pub use distribution_tree::{
    DistributionTree, TreeError, TreePin, copy_tree_snapshot, open_relative_directory,
    remove_tree_snapshot, rename_exclusive, tree_matches, tree_matches_at, tree_snapshot,
    tree_snapshot_at,
};

// The Windows content tree and Bundle and HDC captures on NTFS (TASK-XPA-012): the
// same API over held directory handles.
#[cfg(windows)]
pub use windows::{
    BootstrapBundleCapture, BootstrapBundleCaptureError, BootstrapBundlePublication,
    BootstrapBundlePublishError, BootstrapEntry, BootstrapToolCapture, BootstrapToolCaptureError,
    BootstrapToolPublication, BootstrapToolPublishError, BootstrapTree, inspect_bootstrap_tree,
};

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
// The same five-role reader over a Windows DevEco Studio directory
// (TASK-XPA-011, G15): four roles, no signed resource envelope (Windows
// binds no manifest to a publisher signature), identities as the host
// store's `HostFileIdentity`. `host_deveco_resources` and `property_list`
// stay macOS-only: Windows DevEco ships no property list.
#[cfg(windows)]
pub use windows::{
    DevEcoFileFacts, DevEcoFileRead, DevEcoIdentityChanged, DevEcoInputTooLarge, DevEcoRole,
    DevEcoRoot,
};
// A pinned file measured through one no-follow handle (`FileIdInfo`, owner
// and DACL, execute right, SHA-256): the signing layer's `measure` on Windows.
#[cfg(windows)]
pub use windows::{
    HostFileMeasure, HostFileMeasureError, host_resolved_path, measure_host_file, read_host_file,
    trusted_write_only_directory,
};
// The system tools a Windows Runtime trusts for workspace operations
// (TASK-XPA-011, maintainer ruling 69): `tar` and `git` by their registered
// absolute path and Authenticode publisher, measured through one handle.
#[cfg(windows)]
pub use windows::{SystemTool, TrustedSystemTool, trusted_system_tool};
// The Authenticode signature of a registered DevEco tool and the DevEco
// launcher's publisher, with the macOS answer type (TASK-XPA-011, G12).
#[cfg(windows)]
pub use windows::{
    DEVECO_PUBLISHER, NativeCodeSignature, inspect_deveco_publisher_signature,
    inspect_native_code_signature, inspect_publisher, same_signer,
};
#[cfg(target_os = "macos")]
mod host_deveco_resources;
#[cfg(target_os = "macos")]
pub use host_deveco_resources::{DEVECO_RESOURCE_PATHS, verify_deveco_resource_envelope};

#[cfg(any(target_os = "macos", windows))]
mod self_resources;
#[cfg(windows)]
pub use self_resources::{SelfMemory, self_memory};
#[cfg(any(target_os = "macos", windows))]
pub use self_resources::{SelfResources, self_resources};

#[cfg(any(target_os = "macos", windows))]
mod continuous_clock;
#[cfg(any(target_os = "macos", windows))]
pub use continuous_clock::ContinuousInstant;

#[cfg(target_os = "macos")]
mod autorelease_pool;

mod usb_registry;
pub use usb_registry::{RegistryEntry, RegistryUnavailable, RegistryValue, UsbHostDevice};
#[cfg(target_os = "macos")]
pub use usb_registry::{registry_census, usb_host_devices};

mod usb_device_nodes;
pub use usb_device_nodes::{
    CENSUS_MAPPING, CensusField, CensusSample, DeviceNode, NodeProperty, NodeValue,
    unconfirmed_census_fields,
};
#[cfg(windows)]
pub use usb_device_nodes::{usb_device_node_census, usb_host_devices};
