//! Swift `CLIControlFailureMapper` and `CLIControlMethodRegistry.effect(of:)`:
//! the §8.4 code a control failure maps to, for every method.
//!
//! An ambiguous failure — a lost or malformed reply, the client's own
//! deadline, a Runtime refusal without proof — is resolved only by what the
//! method can do and by the evidence its owner published. A method that can
//! leave something behind never reads as "nothing happened" without proof.
use serde_json::{Map, Value};

/// Swift `CLIControlMethodRegistry.boundedReadOnlyMethods`: the methods whose
/// handler only observes and reports. Any other method is mutation-capable,
/// as Swift treats one it has not classified.
pub const BOUNDED_READ_ONLY_METHODS: [&str; 53] = [
    "health",
    "doctor",
    "runtime.hdc.status",
    "runtime.storage.status",
    "runtime.tool.inspect",
    "runtime.bundle.inspect",
    "runtime.tool.list",
    "runtime.bundle.list",
    "session.list",
    "session.show",
    "operation.list",
    "operation.describe",
    "device.observations",
    "target.list",
    "target.show",
    "agent.status",
    "agent.list",
    "human-action.list",
    "human-action.show",
    "history.filter.list",
    "workspace.project.list",
    "workspace.project.show",
    "workspace.preset.list",
    "workspace.preset.show",
    "target.availability",
    "trace.cache.status",
    "trace.inspect",
    "trace.probe",
    "debug.probe",
    "debug.status",
    "recovery.flash-invocation.list",
    "capability.list",
    "capability.inspect",
    "job.plan",
    "job.list",
    "job.status",
    "job.events",
    "job.show",
    "job.result",
    "job.timeline",
    "job.evidence",
    "cleanupDebt.list",
    "artifact.quota",
    "artifact.import.list",
    "artifact.import.inspect",
    "artifact.import.inspection",
    "artifact.list",
    "artifact.inspect",
    "artifact.read",
    "flash.prerequisites",
    "flash.device-access",
    "flash.bootloader-status",
    "flash.lanePlanPreview",
];

/// Whether `method`'s handler only observes and reports.
pub fn bounded_read_only(method: &str) -> bool {
    BOUNDED_READ_ONLY_METHODS.contains(&method)
}

/// Swift `CLITransportFailure`: what happened to the connection rather than
/// inside a handler.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    /// The connection never opened, so no request left the process.
    ConnectFailed,
    /// A frame arrived but did not parse as a response.
    MalformedResponse,
    /// The peer closed before a response completed.
    LostResponse,
    /// The client stopped waiting. It says nothing about the request.
    ClientTimeout,
}

/// Swift `CLIControlFailureMapper.code(forTransportFailure:method:)`.
pub fn transport_code(failure: Transport, method: &str) -> &'static str {
    let read_only = bounded_read_only(method);
    match failure {
        // Nothing was ever sent, so nothing was accepted, whatever the method.
        Transport::ConnectFailed => "runtimeUnavailable",
        Transport::MalformedResponse if read_only => "protocolMalformed",
        Transport::LostResponse if read_only => "runtimeUnavailable",
        Transport::ClientTimeout if read_only => "clientTimeout",
        _ => "outcomeUnknown",
    }
}

/// The refusals a Runtime owner may name, each for the methods it owns and
/// only with its own zero-dispatch evidence (Swift's per-owner branches, in
/// Swift's order).
const OWNER_REFUSALS: [(&[&str], &str, &[&str]); 16] = [
    (
        &[
            "artifact.list",
            "artifact.inspect",
            "artifact.read",
            "artifact.export",
        ],
        "artifactOwner",
        &[
            "resourceConflict",
            "invalidInput",
            "operationUnavailable",
            "inputTooLarge",
            "invalidCursor",
            "resourceNotFound",
            "artifactIntegrityFailed",
            "sensitiveAccessDenied",
            "operationFailed",
            "recordUnreadable",
        ],
    ),
    (
        &[
            "artifact.import.begin",
            "artifact.import.append",
            "artifact.import.commit",
            "artifact.import.inspection",
            "artifact.import.abort",
            "artifact.import.inspect",
            "artifact.import.list",
            "artifact.import.release",
        ],
        "importOwner",
        &[
            "resourceConflict",
            "invalidInput",
            "operationUnavailable",
            "inputTooLarge",
            "invalidCursor",
            "idempotencyConflict",
            "resourceNotFound",
            "artifactIntegrityFailed",
            "quotaExceeded",
        ],
    ),
    (
        &["runtime.tool.register", "runtime.bundle.register"],
        "bootstrapRegistryOwner",
        &[
            "invalidInput",
            "fileIdentityChanged",
            "resourceConflict",
            "admissionDenied",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
            "operationUnavailable",
        ],
    ),
    (
        &["runtime.tool.list"],
        "bootstrapRegistryOwner",
        &[
            "invalidInput",
            "invalidCursor",
            "resourceConflict",
            "admissionDenied",
            "recordUnreadable",
            "operationUnavailable",
            "inputTooLarge",
            "fileIdentityChanged",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &["runtime.bundle.list"],
        "bootstrapRegistryOwner",
        &[
            "invalidInput",
            "invalidCursor",
            "resourceConflict",
            "admissionDenied",
            "recordUnreadable",
            "operationUnavailable",
            "inputTooLarge",
        ],
    ),
    (
        &["runtime.tool.remove"],
        "bootstrapRegistryOwner",
        &[
            "invalidInput",
            "resourceNotFound",
            "resourceConflict",
            "admissionDenied",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "fileIdentityChanged",
            "inputTooLarge",
            "outcomeUnknown",
            "operationUnavailable",
        ],
    ),
    (
        &["runtime.bundle.remove"],
        "bootstrapRegistryOwner",
        &[
            "invalidInput",
            "resourceNotFound",
            "resourceConflict",
            "admissionDenied",
            "recordUnreadable",
            "quotaExceeded",
            "outcomeUnknown",
            "operationUnavailable",
        ],
    ),
    (
        &["target.display-name.set", "target.display-name.clear"],
        "targetDisplayNameOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "resourceNotFound",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &["device.display-name.set", "device.display-name.clear"],
        "candidateDisplayNameOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &[
            "history.filter.list",
            "history.filter.save",
            "history.filter.delete",
        ],
        "historyFilterOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "resourceNotFound",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &[
            "runtime.storage.status",
            "runtime.storage.policy",
            "runtime.storage.root",
        ],
        "runtimeStorageOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "operationUnavailable",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &[
            "session.list",
            "session.show",
            "session.pin",
            "session.unpin",
            "session.cleanup.preview",
            "session.cleanup.apply",
            "session.export.preview",
            "session.export.apply",
        ],
        "sessionOwner",
        &[
            "invalidInput",
            "invalidCursor",
            "resourceConflict",
            "resourceNotFound",
            "operationUnavailable",
            "inputTooLarge",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "outcomeUnknown",
        ],
    ),
    (
        &[
            "workspace.project.list",
            "workspace.project.show",
            "workspace.project.register",
            "workspace.project.update",
            "workspace.project.remove",
        ],
        "workspaceProjectOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "workspaceReferenceNotFound",
            "idempotencyConflict",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "factsDrifted",
            "outcomeUnknown",
            "operationUnavailable",
        ],
    ),
    (
        &[
            "workspace.preset.list",
            "workspace.preset.show",
            "workspace.preset.register",
            "workspace.preset.update",
            "workspace.preset.remove",
        ],
        "workspacePresetOwner",
        &[
            "invalidInput",
            "resourceConflict",
            "workspaceReferenceNotFound",
            "idempotencyConflict",
            "recordUnreadable",
            "quotaExceeded",
            "ioFailure",
            "factsDrifted",
            "outcomeUnknown",
            "operationUnavailable",
            "resourceNotFound",
            "admissionDenied",
        ],
    ),
    (
        &["trace.cache.status", "trace.cache.purge"],
        "traceCacheOwner",
        &["recordUnreadable", "outcomeUnknown"],
    ),
    (
        &["trace.inspect"],
        "traceInspectionOwner",
        &[
            "invalidInput",
            "operationUnavailable",
            "resourceNotFound",
            "artifactIntegrityFailed",
            "recordUnreadable",
            "operationFailed",
        ],
    ),
];

/// The refusals any handler may name: each keeps its code only with the
/// pre-admission zero-dispatch proof.
const NAMED_REFUSALS: [&str; 15] = [
    "resourceConflict",
    "factsDrifted",
    "admissionDenied",
    "targetTrustPending",
    "invalidInput",
    "operationUnavailable",
    "inputTooLarge",
    "invalidCursor",
    "idempotencyConflict",
    "reviewedPlanMismatch",
    "resourceNotFound",
    "humanActionExpired",
    "orchestrationBudgetExpired",
    "orchestrationClockUntrusted",
    "bindingRevisionStale",
];

/// Where this CLI stays more cautious than Swift's mapper, for a
/// mutation-capable method only (declared differences, the hub's rulings of
/// 2026-09-25):
///
/// - `resultNotReady` is retryable, and retrying a mutation is the replay
///   POL-RECOVERY-001 forbids. §8.4's fixed fallback table does not name it,
///   so Swift passing it through for every method is not the spec's; without
///   proof a mutation-capable refusal is `outcomeUnknown` (§8.4), and with the
///   pre-admission proof `internalError`.
/// - The Runtime's own `outcomeUnknown` stays `outcomeUnknown` whatever
///   evidence comes with it. Swift reads it with the pre-admission proof as
///   `internalError`, which §8.4 reserves for an error proven to leave no
///   uncertain mutation; a Runtime that does not know the outcome proves no
///   such thing.
fn fail_closed(wire: &str, method: &str, phase: Option<&str>, zero: bool) -> Option<&'static str> {
    if bounded_read_only(method) {
        return None;
    }
    let proof = phase == Some("preAdmission") && zero;
    match wire {
        "resultNotReady" => Some(if proof {
            "internalError"
        } else {
            "outcomeUnknown"
        }),
        "outcomeUnknown" => Some("outcomeUnknown"),
        _ => None,
    }
}

/// Swift `CLIControlFailureMapper.code(forWireCode:method:evidence:)`, the
/// evidence read from `details` as `CLIControlFailureEvidence.read` reads it:
/// a string `phase` and an integer `newDispatchCount`.
pub fn wire_code(wire: &str, method: &str, details: Option<&Map<String, Value>>) -> &'static str {
    let phase = details
        .and_then(|details| details.get("phase"))
        .and_then(Value::as_str);
    let zero = details
        .and_then(|details| details.get("newDispatchCount"))
        .and_then(Value::as_i64)
        == Some(0);
    if let Some(code) = fail_closed(wire, method, phase, zero) {
        return code;
    }
    for (methods, owner, codes) in OWNER_REFUSALS {
        if methods.contains(&method)
            && phase == Some(owner)
            && zero
            && let Some(code) = codes.iter().find(|code| **code == wire)
        {
            return code;
        }
    }
    let proof = phase == Some("preAdmission") && zero;
    let read_only = bounded_read_only(method);
    if let Some(code) = NAMED_REFUSALS.iter().find(|code| **code == wire) {
        return if proof {
            code
        } else if read_only {
            "internalError"
        } else {
            "outcomeUnknown"
        };
    }
    match wire {
        "unsupportedProtocolVersion" => "protocolVersionUnsupported",
        "malformedFrame" => "protocolMalformed",
        "unknownMethod" => "controlMethodUnavailable",
        "invalidParams" => "invalidInput",
        "conflict" => "resourceConflict",
        "notFound" => "resourceNotFound",
        "resultNotReady" => "resultNotReady",
        "workspaceReferenceNotFound" => "workspaceReferenceNotFound",
        "recordUnreadable" => "recordUnreadable",
        // Only a closed handler contract proving both halves may say the
        // request was refused before it could do anything.
        "rejected" if proof => "admissionDenied",
        "rejected" if read_only => "operationFailed",
        // `internalError`, and a valid wire error nobody has classified, are
        // exactly as uncertain as each other.
        _ if read_only || proof => "internalError",
        _ => "outcomeUnknown",
    }
}
