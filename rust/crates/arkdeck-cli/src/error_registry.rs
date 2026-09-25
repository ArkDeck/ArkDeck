//! Swift `CLIErrorCode` and `CLIExitCategory` (`CLIErrorRegistry.swift`): the
//! §8.4 error registry and the §9 exit-code contract.
//!
//! `error.code` is what a caller branches on, so a code, its exit status and
//! whether its control request may be retried are spelled once, here.

/// Swift `CLIErrorRegistryVersion.current`.
pub const VERSION: &str = "arkdeck.cli.error-registry/1";

/// Swift `CLIExitCategory`: the coarse process contract a shell script sees.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitCategory {
    Ok,
    OperationFailed,
    IntegrityFailed,
    LegacyAttention,
    Usage,
    InvalidData,
    Unavailable,
    InternalFailure,
    Io,
    AttentionRequired,
    AdmissionDenied,
    ClientInterrupted,
}

impl ExitCategory {
    /// Every category, in Swift's order.
    pub const ALL: [Self; 12] = [
        Self::Ok,
        Self::OperationFailed,
        Self::IntegrityFailed,
        Self::LegacyAttention,
        Self::Usage,
        Self::InvalidData,
        Self::Unavailable,
        Self::InternalFailure,
        Self::Io,
        Self::AttentionRequired,
        Self::AdmissionDenied,
        Self::ClientInterrupted,
    ];

    pub fn exit_code(self) -> u8 {
        match self {
            Self::Ok => 0,
            Self::OperationFailed => 1,
            Self::IntegrityFailed => 2,
            Self::LegacyAttention => 4,
            Self::Usage => 64,
            Self::InvalidData => 65,
            Self::Unavailable => 69,
            Self::InternalFailure => 70,
            Self::Io => 74,
            Self::AttentionRequired => 75,
            Self::AdmissionDenied => 77,
            Self::ClientInterrupted => 130,
        }
    }

    /// The name a machine consumer reads: `internal`, so it does not collide
    /// with the `internalError` code.
    pub fn machine_name(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::OperationFailed => "operationFailed",
            Self::IntegrityFailed => "integrityFailed",
            Self::LegacyAttention => "legacyAttention",
            Self::Usage => "usage",
            Self::InvalidData => "invalidData",
            Self::Unavailable => "unavailable",
            Self::InternalFailure => "internal",
            Self::Io => "io",
            Self::AttentionRequired => "attentionRequired",
            Self::AdmissionDenied => "admissionDenied",
            Self::ClientInterrupted => "clientInterrupted",
        }
    }
}

/// Swift `CLIErrorCode.allCases`, in Swift's order, each with its category.
pub const CODES: [(&str, ExitCategory); 45] = {
    use ExitCategory::*;
    [
        // argv grammar: zero dispatch
        ("invalidCommand", Usage),
        ("invalidOption", Usage),
        ("commandRemoved", Usage),
        // input, cursor, identity and resource conflicts: zero new dispatch
        ("invalidInput", InvalidData),
        ("inputTooLarge", InvalidData),
        ("invalidCursor", InvalidData),
        ("idempotencyConflict", InvalidData),
        ("reviewedPlanMismatch", InvalidData),
        ("resourceConflict", InvalidData),
        ("resourceNotFound", InvalidData),
        ("workspaceReferenceNotFound", InvalidData),
        // the Runtime, a provider, a tool or a product surface is unavailable
        ("protocolVersionUnsupported", Unavailable),
        ("controlMethodUnavailable", Unavailable),
        ("runtimeUnavailable", Unavailable),
        ("operationUnavailable", Unavailable),
        ("unsupportedOnPlatform", Unavailable),
        ("quotaExceeded", Unavailable),
        ("blockedByProductDefect", Unavailable),
        ("healthRequirementFailed", Unavailable),
        // a person, a readback or a fresh preview is needed first
        ("targetSelectionRequired", AttentionRequired),
        ("targetAmbiguous", AttentionRequired),
        ("targetTrustPending", AttentionRequired),
        ("humanActionRequired", AttentionRequired),
        ("humanActionExpired", AttentionRequired),
        ("resultNotReady", AttentionRequired),
        ("clientTimeout", AttentionRequired),
        ("eventHistoryUnavailable", AttentionRequired),
        ("orchestrationBudgetExpired", AttentionRequired),
        ("outcomeUnknown", AttentionRequired),
        ("reconcileRequired", AttentionRequired),
        ("previewExpired", AttentionRequired),
        // identity, facts or authority refused the request, with zero dispatch
        ("orchestrationClockUntrusted", AdmissionDenied),
        ("fileIdentityChanged", AdmissionDenied),
        ("bindingRevisionStale", AdmissionDenied),
        ("factsDrifted", AdmissionDenied),
        ("previewDrifted", AdmissionDenied),
        ("admissionDenied", AdmissionDenied),
        ("sensitiveAccessDenied", AdmissionDenied),
        // the work itself failed, or a record could not be trusted
        ("operationFailed", OperationFailed),
        ("artifactIntegrityFailed", IntegrityFailed),
        ("recordUnreadable", IntegrityFailed),
        ("ioFailure", Io),
        // the local control plane or the CLI itself failed
        ("protocolMalformed", InternalFailure),
        ("internalError", InternalFailure),
        ("clientInterrupted", ClientInterrupted),
    ]
};

/// The code's static name, if the registry has it.
pub fn code(name: &str) -> Option<&'static str> {
    CODES
        .iter()
        .find(|(code, _)| *code == name)
        .map(|(code, _)| *code)
}

/// The code's category, if the registry has it.
pub fn category(code: &str) -> Option<ExitCategory> {
    CODES
        .iter()
        .find(|(name, _)| *name == code)
        .map(|(_, category)| *category)
}

/// Swift `isControlRequestRetryable`: whether the caller may send *this
/// control request* again. It never authorises a new Job, a rerun or an
/// intent replayed; an unknown outcome is not retryable.
pub fn control_request_retryable(code: &str) -> bool {
    matches!(
        code,
        "clientTimeout" | "resultNotReady" | "runtimeUnavailable"
    )
}

/// Swift `requiresAttention`: whether a person has to look before anything
/// else happens.
pub fn requires_attention(code: &str) -> bool {
    matches!(
        category(code),
        Some(
            ExitCategory::AttentionRequired
                | ExitCategory::AdmissionDenied
                | ExitCategory::IntegrityFailed
        )
    )
}
