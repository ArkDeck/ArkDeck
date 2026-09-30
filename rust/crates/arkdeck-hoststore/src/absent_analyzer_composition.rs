//! The analyzers on Windows, as a trait nothing implements (TASK-XPA-005).
//!
//! The Job planner and runner read the analyzers a host composed through
//! `AnalyzerComposition` (`analyzer_composition.rs`), whose profiles pin
//! ArkTrace's trace_streamer distribution, which Windows does not have. Until
//! a Windows analyzer exists, the planner is the same code with
//! `analyzer: None`: an analyzer operation is refused as macOS refuses it
//! without a profile.

/// The analyzers a host composed; none on Windows yet.
pub trait AnalyzerComposition: Sync {}
