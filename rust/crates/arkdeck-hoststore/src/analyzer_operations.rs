//! The analyzer operations and the analyzers they name: the Runtime's fixed
//! mapping, which the planner, the runner and `operation.list` read on every
//! host (moved out of `analyzer_composition.rs`, whose profiles are
//! macOS-only).

pub(crate) const CRASH_SIGNATURE: &str = "analyzer.extract-crash-signature@1";
pub(crate) const HILOG_SUMMARY: &str = "analyzer.summarize-hilog@1";
pub(crate) const TRACE_SUMMARY: &str = "analyzer.summarize-trace@1";
pub(crate) const TRACE_ANALYSIS: &str = "analyzer.analyze-trace@1";

/// The analyzer operations this Runtime plans, admits, runs, reconciles and
/// reads: each one's product is verified and published here.
pub(crate) const EXECUTED: [&str; 4] = [
    CRASH_SIGNATURE,
    HILOG_SUMMARY,
    TRACE_SUMMARY,
    TRACE_ANALYSIS,
];

/// Swift's `publishesBeforeOutcome`: the ArkTrace operations, whose exact
/// validated bytes become durable before the journal can call their step
/// succeeded.
pub(crate) fn publishes_before_outcome(reference: &str) -> bool {
    [TRACE_SUMMARY, TRACE_ANALYSIS].contains(&reference)
}

/// `AnalyzerProvider.analyzerForOperation`: the one analyzer an operation may
/// name. The mapping is the Runtime's; no request chooses another.
pub(crate) fn analyzer_for_operation(reference: &str) -> Option<&'static str> {
    match reference {
        CRASH_SIGNATURE => Some("crash-signature@1"),
        HILOG_SUMMARY => Some("hilog-summary@1"),
        TRACE_SUMMARY => Some("trace-summary@1"),
        TRACE_ANALYSIS => Some("trace-analysis@1"),
        _ => None,
    }
}

/// The one step each analyzer operation declares in the Catalog.
pub(crate) fn step(reference: &str) -> Option<&'static str> {
    match reference {
        CRASH_SIGNATURE => Some("extract-crash-signature"),
        HILOG_SUMMARY => Some("summarize-hilog"),
        TRACE_SUMMARY => Some("summarize-trace"),
        TRACE_ANALYSIS => Some("analyze-trace"),
        _ => None,
    }
}

/// `AnalyzerProvider.derivedArtifactName`.
pub(crate) fn derived_artifact_name(analyzer_ref: &str) -> &'static str {
    match analyzer_ref {
        "crash-signature@1" => "crash-signature.json",
        "hilog-summary@1" => "hilog-summary.json",
        "trace-summary@1" => "trace-summary.json",
        "trace-analysis@1" => "trace-analysis.json",
        _ => "analysis.json",
    }
}
