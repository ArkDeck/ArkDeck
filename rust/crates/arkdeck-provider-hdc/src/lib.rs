//! HDC observation parsers and the bounded, existing-server read-only provider.
//!
//! The command-result parser, candidate list and registered presence feed are
//! separate families. In particular, an Offline candidate is a valid list row;
//! it is not a failed command or proof that the candidate is authorized.

#![forbid(unsafe_code)]

#[cfg(target_os = "macos")]
mod dispatch;
mod host_diagnostics;
#[cfg(target_os = "macos")]
mod lifecycle;
mod live_mode;
#[cfg(target_os = "macos")]
mod managed_server;
mod observation;
mod operation;
mod presence;
mod provider;
mod rockchip_hdc;
mod rockchip_loader;
mod semantic;

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
pub use managed_server::{ManagedHdcServer, StartBudget, StartFailure};
pub use observation::{
    DeviceCandidate, ParseError, ServerCheck, parse_client_version, parse_server_check,
    parse_target_list,
};
pub use operation::{
    Action, DispatchFailure, Expected, HdcDispatch, Outcome, ProcessPlan, Property, Receipt,
    property_value, stable_identity_sha256,
};
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
