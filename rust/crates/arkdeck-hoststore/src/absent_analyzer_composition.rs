//! The analyzers on Windows, as a trait nothing implements (TASK-XPA-005).
//!
//! The Job planner and runner read the analyzers a host composed through
//! `AnalyzerComposition` (`analyzer_composition.rs`), whose profiles pin
//! ArkTrace's trace_streamer distribution, which Windows does not have. Until
//! a Windows analyzer exists, the planner is the same code with
//! `analyzer: None`: an analyzer operation is refused as macOS refuses it
//! without a profile. `operation.list` answers from the same operation facts
//! (`analyzer_operations.rs`) and the answers below, which are macOS's with
//! no composition.
pub(crate) use crate::analyzer_operations::EXECUTED;

/// The analyzers a host composed; none on Windows yet.
pub trait AnalyzerComposition: Sync {}

/// Swift's reason for an analyzer the host gave one for: without a
/// composition there is none, as on macOS.
pub(crate) fn host_unavailable_reason(
    _composition: Option<&dyn AnalyzerComposition>,
    _reference: &str,
) -> Option<(&'static str, String)> {
    None
}

/// Swift `AnalyzerProvider.runtimeAvailability` without a composition: an
/// analyzer operation has no profile, anything else is not an analyzer's.
pub(crate) fn runtime_availability(
    _composition: Option<&dyn AnalyzerComposition>,
    reference: &str,
) -> Result<(), (&'static str, String)> {
    if crate::analyzer_operations::analyzer_for_operation(reference).is_none() {
        return Err((
            "operation_not_supported",
            "analyzer.unsupportedOperation".into(),
        ));
    }
    Err((
        "provider_tool_unavailable",
        "analyzer.profileUnavailable".into(),
    ))
}
