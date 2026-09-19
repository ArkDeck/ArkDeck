//! HDC observation parsers and the bounded, existing-server read-only provider.
//!
//! The command-result parser, candidate list and registered presence feed are
//! separate families. In particular, an Offline candidate is a valid list row;
//! it is not a failed command or proof that the candidate is authorized.

#![forbid(unsafe_code)]

mod capture_files;
mod debug_hap;
#[cfg(target_os = "macos")]
mod dispatch;
mod host_diagnostics;
#[cfg(target_os = "macos")]
mod lifecycle;
mod live_mode;
#[cfg(target_os = "macos")]
mod managed_server;
mod native_elf;
mod native_library;
mod observation;
mod operation;
mod pointer_input;
mod port_forward;
mod presence;
mod provider;
mod rockchip_hdc;
mod rockchip_loader;
mod semantic;
#[cfg(target_os = "macos")]
mod status;
mod target_observation;

pub use capture_files::{
    DirectoryPurpose, FaultLogName, FileAction, FileActionError, FilePlan, FileReceipt,
    HostLanding, ImageType, Invocation, JFIF_MAGIC, Landed, LivenessRequest, OwnedRemoteDirectory,
    OwnedRemotePath, PNG_MAGIC, RECEIVE_MAXIMUM_BYTES, ReceiveArtifact, STDOUT_BUDGET,
    ScreenSequenceRequest, TraceRequest, fault_log_entries, file_producer_step_id, host_landing,
    path_presence, remote_regular_file_byte_count, run, screenshot_image_type,
};
pub use debug_hap::{
    AbilityReference, BundleReference, HapAction, ResolvedArtifact, StagedArtifact, StagedPackage,
    StagedPackageSet, append_native_library_facts, bounded_process_diagnostic,
    install_dispatch_outcome, package_presence, process_presence,
};
#[cfg(target_os = "macos")]
pub use dispatch::{ProcessDispatch, SERVER_PORT_VARIABLE};
pub use host_diagnostics::{DIAGNOSTIC_REPORTS_DIRECTORY, signal_death, signal_number};
#[cfg(target_os = "macos")]
pub use lifecycle::{
    LifecycleAction, LifecycleBudget, LifecycleCommand, LifecycleOutcome, LifecycleReceipt,
    PostDispatchObservation, PreparedLifecycle, generation,
};
pub use live_mode::{
    DeviceMode, HdcIdentity, LiveModeFailure, LiveModeObservation, LiveModeProbe, LoaderIdentity,
    LoaderObserver, UsbProbe,
};
#[cfg(target_os = "macos")]
pub use managed_server::{EndpointSelection, ManagedHdcServer, StartBudget, StartFailure};
pub use native_elf::{
    CodeSignFacts, MAXIMUM_LIBRARY_BYTES, NativeAbi, NativeLibraryFacts, ValidationError,
    is_static_executable, validate_elf,
};
pub use native_library::{
    Attestation, CodeSignHelper, CodeSignHelperFacts, Deployment, ExactPaths, Inspection,
    NativeAction, NativeFileIdentity, Reconcile, RestartProfile, RollbackPolicy,
    VerificationProfile, attestation_at_least_replaced, code_sign_digest, is_directory_listing,
    is_regular_file_listing, maps_contain, native_file_identity, process_ids, process_is_absent,
    published_without_attestation, readback_attestation, sha256_token,
};
pub use observation::{
    DeviceCandidate, ParseError, ServerCheck, parse_client_version, parse_server_check,
    parse_target_list,
};
pub use operation::{
    Action, DispatchFailure, Expected, HdcDispatch, Outcome, ProcessPlan, Property, Receipt,
    property_value, stable_identity_sha256,
};
pub use operation::{DEFAULT_HILOG_BUDGET, Persisted, RequestError, STORAGE_ROOT};
pub use pointer_input::{
    DEFAULT_LONG_PRESS_MS, DISPLAY_MAXIMUM, DURATION_MAXIMUM_MS, DURATION_MINIMUM_MS,
    FRAME_FRESHNESS_BUDGET_MS, Gesture, PointerAction, PointerInput,
};
pub use port_forward::{Direction, PORT_MAXIMUM, PORT_MINIMUM, PortAction, PortRule};
pub use presence::{
    ObservationFailure, ObservationInput, ObservationTermination, PresenceSnapshot,
    parse_registered_presence,
};
pub use provider::HdcReadOnlyProvider;
pub use rockchip_hdc::{
    BuildReadback, Clock, POST_FLASH_BUILD_PROPERTIES_COMMAND, ReconnectExpectation,
    RockchipHdcFailure, RockchipHdcObserver, SystemClock, VerifiedBuild, WaitBudget,
    bound_reconnect_summary, hdc_normal_usb_summary, hdc_state_summary, output_excerpt,
    parse_build_properties,
};
pub use rockchip_loader::{
    ENTER_LOADER_TIMEOUT, FlashRuntimeDiagnostic, LoaderTransition, LoaderTransitionFailure,
    ReadbackBudget, RockchipLoaderTransition, Transition, TransitionRequest, enter_loader_plan,
    loader_summary, rebind_summary, transition_evidence_summary,
};
pub use semantic::{CommandFailure, CommandOutcome, SemanticOutputParser};
#[cfg(target_os = "macos")]
pub use status::{
    CommandlessIdentity, HdcStatusObserver, IdentityObservation, IdentityObserver, ManagedLaunch,
    ManagedProcessVerifier, NativeSignature, STATUS_SCHEMA_VERSION, SignatureInspector,
    StartupDiagnostics, StatusExecutable, SupervisedServer, SupervisorState, SystemManagedProcess,
    published_client_version, server_endpoint_ref, unconfigured_status,
};
pub use target_observation::{
    BootstrapFailure, DAYU200_NORMAL_PRODUCT_ID, NoUsbRelations, ObservedCandidate,
    ROCKUSB_VENDOR_ID, Reading, UsbRelation, UsbRelations, adoption_holds, list_candidates,
    observe_device_identity, observe_tool_version, stable_identity_sha256_for_serial,
    usable_relations,
};
