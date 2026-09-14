//! HDC observation parsers and the bounded, existing-server read-only provider.
//!
//! The command-result parser, candidate list and registered presence feed are
//! separate families. In particular, an Offline candidate is a valid list row;
//! it is not a failed command or proof that the candidate is authorized.

#![forbid(unsafe_code)]

#[cfg(target_os = "macos")]
mod dispatch;
mod observation;
mod operation;
mod presence;
mod provider;
mod semantic;

#[cfg(target_os = "macos")]
pub use dispatch::{ProcessDispatch, SERVER_PORT_VARIABLE};
pub use observation::{
    DeviceCandidate, ParseError, ServerCheck, parse_client_version, parse_server_check,
    parse_target_list,
};
pub use operation::{
    Action, DispatchFailure, Expected, FixtureDispatch, HdcDispatch, Outcome, ProcessPlan,
    Property, Receipt, property_value, stable_identity_sha256,
};
pub use presence::{
    ObservationFailure, ObservationInput, ObservationTermination, PresenceSnapshot,
    parse_registered_presence,
};
pub use provider::HdcReadOnlyProvider;
pub use semantic::{CommandFailure, CommandOutcome, SemanticOutputParser};
