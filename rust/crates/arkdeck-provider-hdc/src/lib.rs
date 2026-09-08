//! HDC observation parsers and the bounded, existing-server read-only provider.
//!
//! The command-result parser, candidate list and registered presence feed are
//! separate families. In particular, an Offline candidate is a valid list row;
//! it is not a failed command or proof that the candidate is authorized.

#![forbid(unsafe_code)]

mod observation;
mod presence;
mod provider;
mod semantic;

pub use observation::{
    DeviceCandidate, ParseError, ServerCheck, parse_client_version, parse_server_check,
    parse_target_list,
};
pub use presence::{
    ObservationFailure, ObservationInput, ObservationTermination, PresenceSnapshot,
    parse_registered_presence,
};
pub use provider::HdcReadOnlyProvider;
pub use semantic::{CommandFailure, CommandOutcome, SemanticOutputParser};
