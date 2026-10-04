//! The ArkTrace profile facts every host reads (TASK-XPA-011): the two
//! ArkTrace analyzers' names, the loader's reasons, and the files and trees
//! an analyzer profile pins. The loader, its trust checker and its doctor
//! (`arktrace_profile.rs`) stay macOS-only; on Windows no ArkTrace profile
//! loads, and these facts are all the analyzer composition reads of it.

pub const SUMMARY_REF: &str = "trace-summary@1";
pub const ANALYSIS_REF: &str = "trace-analysis@1";

/// Swift `ArkTraceSummaryProfileError`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArkTraceProfileError {
    NotFound,
    DescriptorInvalid,
    ManifestDrift,
    ContractMismatch,
    ToolDrift,
    ParserDrift,
    SelfTestFailed,
}

impl ArkTraceProfileError {
    pub fn reason(self) -> &'static str {
        match self {
            Self::NotFound => "analyzer.arktraceNotFound",
            Self::DescriptorInvalid => "analyzer.arktraceDescriptorInvalid",
            Self::ManifestDrift => "analyzer.arktraceManifestDrift",
            Self::ContractMismatch => "analyzer.arktraceContractMismatch",
            Self::ToolDrift => "analyzer.arktraceToolDrift",
            Self::ParserDrift => "analyzer.arktraceParserDrift",
            Self::SelfTestFailed => "analyzer.arktraceSelfTestFailed",
        }
    }
}

/// Swift `AnalyzerPinnedFile`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedFile {
    pub path: String,
    pub sha256: String,
    pub byte_count: u64,
    pub require_executable: bool,
}

/// Swift `AnalyzerPinnedTree`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedTree {
    pub path: String,
    pub sha256: String,
}
