import Foundation

/// The §8.4 error registry and the §9 exit-code contract.
///
/// `error.code` is the cross-platform branching contract: a caller decides what
/// to do next from this string, never from the message. So the code, its exit
/// status, and whether the request may be retried are spelled once, here.
/// Deciding an exit status at the throw site is how the same reason ends up
/// exiting two ways, and deciding retryability per call site is how a caller
/// gets told it may retry something that already dispatched.
///
/// Adding a code is a contract change: it has to enter this registry and the
/// macOS/Windows fixtures together. A synonym, a spelling fix or a message the
/// caller has to match is not a compatible substitute.
enum CLIErrorCode: String, CaseIterable {
  // argv grammar — zero dispatch
  case invalidCommand
  case invalidOption
  case commandRemoved

  // input, cursor, identity and resource conflicts — zero new dispatch
  case invalidInput
  case inputTooLarge
  case invalidCursor
  case idempotencyConflict
  case reviewedPlanMismatch
  case resourceConflict
  case resourceNotFound
  case workspaceReferenceNotFound

  // the local Runtime, a provider, a tool or a typed product surface is not
  // available for this request
  case protocolVersionUnsupported
  case controlMethodUnavailable
  case runtimeUnavailable
  case operationUnavailable
  case unsupportedOnPlatform
  case quotaExceeded
  case blockedByProductDefect
  case healthRequirementFailed

  // a human, a readback or a fresh preview is needed before anything continues
  case targetSelectionRequired
  case targetAmbiguous
  case targetTrustPending
  case humanActionRequired
  case humanActionExpired
  case resultNotReady
  case clientTimeout
  case eventHistoryUnavailable
  case orchestrationBudgetExpired
  case outcomeUnknown
  case reconcileRequired
  case previewExpired

  // identity, facts or authority refused the request, with zero dispatch
  case orchestrationClockUntrusted
  case fileIdentityChanged
  case bindingRevisionStale
  case factsDrifted
  case previewDrifted
  case admissionDenied
  case sensitiveAccessDenied

  // the work itself failed, or a record could not be trusted
  case operationFailed
  case artifactIntegrityFailed
  case recordUnreadable
  case ioFailure

  // the local control plane or the CLI itself failed
  case protocolMalformed
  case internalError
  case clientInterrupted

  var exitCode: Int32 { category.exitCode }

  var category: CLIExitCategory {
    switch self {
    case .invalidCommand, .invalidOption, .commandRemoved:
      return .usage
    case .invalidInput, .inputTooLarge, .invalidCursor, .idempotencyConflict,
      .reviewedPlanMismatch, .resourceConflict, .resourceNotFound, .workspaceReferenceNotFound:
      return .invalidData
    case .protocolVersionUnsupported, .controlMethodUnavailable, .runtimeUnavailable,
      .operationUnavailable, .unsupportedOnPlatform, .quotaExceeded, .blockedByProductDefect,
      .healthRequirementFailed:
      return .unavailable
    case .targetSelectionRequired, .targetAmbiguous, .targetTrustPending, .humanActionRequired,
      .humanActionExpired, .resultNotReady, .clientTimeout, .eventHistoryUnavailable,
      .orchestrationBudgetExpired, .outcomeUnknown, .reconcileRequired, .previewExpired:
      return .attentionRequired
    case .orchestrationClockUntrusted, .fileIdentityChanged, .bindingRevisionStale, .factsDrifted,
      .previewDrifted, .admissionDenied, .sensitiveAccessDenied:
      return .admissionDenied
    case .operationFailed:
      return .operationFailed
    case .artifactIntegrityFailed, .recordUnreadable:
      return .integrityFailed
    case .ioFailure:
      return .io
    case .protocolMalformed, .internalError:
      return .internalFailure
    case .clientInterrupted:
      return .clientInterrupted
    }
  }

  /// §8.2: whether the caller may retry *this control request*.
  ///
  /// It never authorises creating a new Job, running one again, or replaying an
  /// intent. Deliberately narrow: an unknown outcome is not retryable even
  /// though the caller may go on to read the owner's status, because retrying
  /// the request that produced it is exactly what POL-RECOVERY-001 forbids.
  var isControlRequestRetryable: Bool {
    switch self {
    case .clientTimeout, .resultNotReady, .runtimeUnavailable:
      return true
    default:
      return false
    }
  }

  /// Whether a person has to look at this before anything else happens.
  var requiresAttention: Bool {
    switch category {
    case .attentionRequired, .admissionDenied, .integrityFailed:
      return true
    default:
      return false
    }
  }
}

/// §9. The coarse process contract. Branching belongs to `error.code`, Job
/// state and `outcomeUnknown`; this is what a shell script can see.
enum CLIExitCategory: String, CaseIterable {
  case ok
  case operationFailed
  case integrityFailed
  case legacyAttention
  case usage
  case invalidData
  case unavailable
  case internalFailure
  case io
  case attentionRequired
  case admissionDenied
  case clientInterrupted

  var exitCode: Int32 {
    switch self {
    case .ok: return 0
    case .operationFailed: return 1
    case .integrityFailed: return 2
    case .legacyAttention: return 4
    case .usage: return 64
    case .invalidData: return 65
    case .unavailable: return 69
    case .internalFailure: return 70
    case .io: return 74
    case .attentionRequired: return 75
    case .admissionDenied: return 77
    case .clientInterrupted: return 130
    }
  }

  /// The name a machine consumer reads, which is not always the Swift case
  /// name: `internalFailure` avoids colliding with the `internalError` code.
  var machineCategory: String {
    self == .internalFailure ? "internal" : rawValue
  }
}
