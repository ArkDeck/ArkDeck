import ArkDeckCore
import Foundation

/// What one local control method can do, and therefore what an ambiguous
/// failure from it is allowed to mean.
///
/// The wire vocabulary is coarse: `rejected` is returned for pre-admission
/// refusals, for read-only execution failures, for resource mutations and for
/// paths that may already have dispatched, so it cannot be read as "nothing
/// happened". §8.4 resolves that by never guessing from the message and
/// instead asking two closed questions — what does structured phase/effect
/// evidence prove, and what is this method able to do at all.
///
/// This table answers the second one. It is hand-written and mechanically held
/// exhaustive against the daemon's own method switch by
/// `CLIControlFailureMappingContractTests`: a method the daemon adds without
/// classifying it here fails that test rather than defaulting to something
/// convenient. Generating it from a language-neutral control contract is §14
/// work; until then the exhaustiveness test is what keeps the two in step.
enum CLIControlMethodEffect: Equatable {
  /// Proven to create, change or destroy no Runtime resource, no durable
  /// lifecycle state and no device state. A failure from one of these did not
  /// leave an effect behind.
  case boundedReadOnly
  /// Anything else. The default for an unknown method, because the cost of
  /// being wrong here is telling a caller that a mutation did not happen.
  case mutationCapable
}

enum CLIControlMethodRegistry {

  /// Read-only methods, each because its handler observes and reports.
  ///
  /// `job.plan` is here on the strength of the engine's own statement that
  /// plan-only writes no lineage or ledger row; `device.observations` on its
  /// owner's, which observes the physical relation without adopting it. The device probes (`trace.probe`,
  /// `debug.probe`, the three `flash.*` observations) read device and host
  /// facts without changing either — §8.4's test is mutation, not contact.
  private static let boundedReadOnlyMethods: Set<String> = [
    "health",
    "doctor",
    "runtime.hdc.status",
    "runtime.storage.status",
    "session.list",
    "session.show",
    "operation.list",
    "operation.describe",
    // The object-shaped sibling §6.1 needs. Observes and reports: it reads the
    // discovery snapshot and mints identity for it, and creates no binding.
    "device.observations",
    "target.list",
    "target.show",
    "agent.status",
    "agent.list",
    "human-action.list",
    "human-action.show",
    "history.filter.list",
    // Read the registered configuration and report. They create nothing and
    // touch no device, so an ambiguous failure from one is a plain failure.
    "workspace.project.list",
    "workspace.project.show",
    "workspace.preset.list",
    "workspace.preset.show",
    // Observes and reports. §5.1 admits it as a bounded read-only aggregate:
    // it creates no Job, writes no evidence, and deliberately runs no device
    // workflow — the warm candidate snapshot is read, never refreshed.
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
    // Registered permanent refusals. Their entire contract is that capability
    // administration is not caller-facing and has zero management effect, so
    // nothing can be left behind by one. They would map to `admissionDenied`
    // rather than `operationFailed` if the handler published the structured
    // pre-admission evidence §8.4 asks for; giving it to them is a daemon-side
    // change, not a classification change.
  ]

  /// Methods that can leave something behind: durable resources, lifecycle
  /// transitions, device dispatch, or host files.
  ///
  /// `artifact.export` is here because it writes into a host directory, which
  /// is a mutation even though no device is touched. The import methods are
  /// here as a family: a `begin`/`append`/`commit` that fails ambiguously may
  /// have left staging state that only the import's own status can settle.
  private static let mutationCapableMethods: Set<String> = [
    "artifact.import.begin", "artifact.import.append", "artifact.import.commit", "artifact.import.abort", "artifact.import.release",
    // Preview publication, expiry invalidation and snapshot persistence can
    // survive a lost response even though lifecycle dispatch remains zero.
    "runtime.hdc.impact-preview",
    "runtime.hdc.restart",
    "runtime.tool.select",
    "control-action.list",
    "control-action.show",
    "control-action.reconcile",

    "device.display-name.clear",
    "device.display-name.set",
    "target.adopt",
    "target.display-name.clear",
    "target.display-name.set",
    "history.filter.delete",
    "history.filter.save",
    "runtime.storage.policy",
    "runtime.storage.root",
    "session.cleanup.apply",
    "session.cleanup.preview",
    "session.export.apply",
    "session.export.preview",
    "session.pin",
    "session.unpin",
    "workspace.project.register",
    "workspace.project.update",
    "workspace.project.remove",
    "workspace.preset.register",
    "workspace.preset.update",
    "workspace.preset.remove",
    // Lease-aware local deletion of inactive derived Trace databases. A lost
    // response cannot prove which entries were removed, so callers reconcile
    // through trace.cache.status before making another explicit request.
    "trace.cache.purge",
    "agent.run",
    "agent.resume",
    "agent.abandon",
    "human-action.resume",
    "flash.bind-current-loader",
    "debug.start",
    "debug.evaluate",
    "debug.template.run",
    "job.submit",
    "job.run",
    "job.cancel",
    "job.reconcile",
    "cleanupDebt.continue",
    "artifact.export",
  ]

  /// Every classified method, for the exhaustiveness test.
  static var classifiedMethods: Set<String> {
    boundedReadOnlyMethods.union(mutationCapableMethods)
  }

  /// An unclassified method is treated as mutation-capable. Failing closed is
  /// the only safe default: the alternative reports "nothing happened" about a
  /// method nobody has looked at.
  static func effect(of method: String) -> CLIControlMethodEffect {
    boundedReadOnlyMethods.contains(method) ? .boundedReadOnly : .mutationCapable
  }
}

/// Structured evidence a handler may attach to a failure, and the only thing
/// besides the method registry that is allowed to sharpen an ambiguous code.
///
/// Nothing here is inferred from the wire message. A handler that does not
/// publish this evidence leaves the failure ambiguous, which is the honest
/// outcome rather than a convenient one.
struct CLIControlFailureEvidence: Equatable {
  /// `"preAdmission"` when the handler proved it refused before admitting.
  var phase: String?
  /// The number of new dispatches this request caused.
  var newDispatchCount: Int?

  var provesZeroDispatchBeforeAdmission: Bool {
    phase == "preAdmission" && newDispatchCount == 0
  }

  /// Reads the evidence out of a daemon failure payload, if it published any.
  static func read(from details: JSONValue?) -> CLIControlFailureEvidence {
    guard case .object(let fields)? = details else { return CLIControlFailureEvidence() }
    var evidence = CLIControlFailureEvidence()
    if case .string(let phase)? = fields["phase"] { evidence.phase = phase }
    switch fields["newDispatchCount"] {
    case .integer(let count)?: evidence.newDispatchCount = Int(exactly: count)
    case .unsignedInteger(let count)?: evidence.newDispatchCount = Int(exactly: count)
    default: break
    }
    return evidence
  }
}

/// Maps a local control failure onto the §8.4 registry.
///
/// The closed part of the map is a lookup. The ambiguous part — legacy
/// `rejected`, legacy `internalError`, an unclassifiable wire error, a
/// malformed or lost response, a disconnect, a client timeout — is resolved by
/// the two questions above and nothing else. There is no default branch that
/// picks a comfortable code, because every comfortable code here is a claim
/// about whether a device was touched.
enum CLIControlFailureMapper {

  static func code(
    forWireCode wireCode: String,
    method: String,
    evidence: CLIControlFailureEvidence = CLIControlFailureEvidence()
  ) -> CLIErrorCode {
    // Artifact export distinguishes known pre-publication refusals from an
    // uncertain publication itself. Its owner explicitly reports the latter
    // as outcomeUnknown; zero device dispatch never hides a host write.
    if ["artifact.list", "artifact.inspect", "artifact.read", "artifact.export"].contains(method),
      evidence.phase == "artifactOwner", evidence.newDispatchCount == 0,
      ["resourceConflict", "invalidInput", "operationUnavailable", "inputTooLarge", "invalidCursor",
        "resourceNotFound", "artifactIntegrityFailed", "sensitiveAccessDenied", "operationFailed", "recordUnreadable"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    // Import owners never dispatch a device operation. Their typed refusal
    // still permits already-durable upload state; it is not preAdmission.
    if ["artifact.import.begin", "artifact.import.append", "artifact.import.commit", "artifact.import.inspection",
        "artifact.import.abort", "artifact.import.inspect", "artifact.import.list", "artifact.import.release"].contains(method),
      evidence.phase == "importOwner", evidence.newDispatchCount == 0,
      ["resourceConflict", "invalidInput", "operationUnavailable", "inputTooLarge",
        "invalidCursor", "idempotencyConflict", "resourceNotFound", "artifactIntegrityFailed", "quotaExceeded"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    // Target display names are a Runtime-owned local resource. The owner can
    // prove exact CAS and validation failures without claiming that a lost
    // publication response is safe to retry.
    if ["target.display-name.set", "target.display-name.clear"].contains(method),
      evidence.phase == "targetDisplayNameOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "resourceNotFound", "recordUnreadable",
        "quotaExceeded", "ioFailure", "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["device.display-name.set", "device.display-name.clear"].contains(method),
      evidence.phase == "candidateDisplayNameOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "recordUnreadable", "quotaExceeded", "ioFailure",
        "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["history.filter.list", "history.filter.save", "history.filter.delete"].contains(method),
      evidence.phase == "historyFilterOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "resourceNotFound", "recordUnreadable",
        "quotaExceeded", "ioFailure", "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["runtime.storage.status", "runtime.storage.policy", "runtime.storage.root"].contains(method),
      evidence.phase == "runtimeStorageOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "operationUnavailable", "recordUnreadable",
        "quotaExceeded", "ioFailure", "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["session.list", "session.show", "session.pin", "session.unpin",
        "session.cleanup.preview", "session.cleanup.apply", "session.export.preview",
        "session.export.apply"].contains(method),
      evidence.phase == "sessionOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "invalidCursor", "resourceConflict", "resourceNotFound",
        "operationUnavailable", "inputTooLarge", "recordUnreadable", "quotaExceeded",
        "ioFailure", "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["workspace.project.list", "workspace.project.show", "workspace.project.register",
        "workspace.project.update", "workspace.project.remove"].contains(method),
      evidence.phase == "workspaceProjectOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "workspaceReferenceNotFound", "idempotencyConflict",
        "recordUnreadable", "quotaExceeded", "ioFailure", "factsDrifted", "outcomeUnknown",
        "operationUnavailable"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["workspace.preset.list", "workspace.preset.show", "workspace.preset.register",
        "workspace.preset.update", "workspace.preset.remove"].contains(method),
      evidence.phase == "workspacePresetOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "resourceConflict", "workspaceReferenceNotFound", "idempotencyConflict",
        "recordUnreadable", "quotaExceeded", "ioFailure", "factsDrifted", "outcomeUnknown",
        "operationUnavailable", "resourceNotFound", "admissionDenied"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if ["trace.cache.status", "trace.cache.purge"].contains(method),
      evidence.phase == "traceCacheOwner", evidence.newDispatchCount == 0,
      ["recordUnreadable", "outcomeUnknown"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    if method == "trace.inspect",
      evidence.phase == "traceInspectionOwner", evidence.newDispatchCount == 0,
      ["invalidInput", "operationUnavailable", "resourceNotFound", "artifactIntegrityFailed",
        "recordUnreadable", "operationFailed"].contains(wireCode),
      let code = CLIErrorCode(rawValue: wireCode) { return code }
    switch wireCode {
    case "resourceConflict", "factsDrifted", "admissionDenied", "targetTrustPending", "invalidInput",
      "operationUnavailable", "inputTooLarge", "invalidCursor", "idempotencyConflict",
      "reviewedPlanMismatch", "resourceNotFound", "humanActionExpired", "orchestrationBudgetExpired",
      "orchestrationClockUntrusted", "bindingRevisionStale":
      // Target adoption's named refusals carry proof from its Runtime owner.
      // A legacy or malformed reply without that proof remains ambiguous.
      if evidence.provesZeroDispatchBeforeAdmission, let code = CLIErrorCode(rawValue: wireCode) {
        return code
      }
      return CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly
        ? .internalError : .outcomeUnknown
    case "unsupportedProtocolVersion": return .protocolVersionUnsupported
    case "malformedFrame": return .protocolMalformed
    case "unknownMethod": return .controlMethodUnavailable
    case "invalidParams": return .invalidInput
    case "conflict": return .resourceConflict
    case "notFound": return .resourceNotFound
    // §7.9's own code. Distinct from `notFound` because it sends a caller
    // somewhere different: not a durable record that is missing, but a
    // reference that is not registered on this host — answered by
    // `workspace project list`, not by a different identity.
    case "resultNotReady": return .resultNotReady
    case "workspaceReferenceNotFound": return .workspaceReferenceNotFound
    case "recordUnreadable": return .recordUnreadable
    case "rejected":
      // Only a closed handler contract proving both halves may say the
      // request was refused before it could do anything.
      if evidence.provesZeroDispatchBeforeAdmission { return .admissionDenied }
      if CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly {
        return .operationFailed
      }
      return .outcomeUnknown
    case "internalError":
      if CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly { return .internalError }
      if evidence.provesZeroDispatchBeforeAdmission { return .internalError }
      return .outcomeUnknown
    default:
      // A valid wire error nobody has classified is exactly as uncertain as an
      // unclassified internal failure, and is treated the same way.
      if CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly { return .internalError }
      if evidence.provesZeroDispatchBeforeAdmission { return .internalError }
      return .outcomeUnknown
    }
  }

  /// A failure that happened to the connection rather than inside a handler:
  /// the socket would not open, the peer went away, the frame did not parse,
  /// or the client stopped waiting.
  ///
  /// The same rule applies. "It looked like a network problem" is not evidence
  /// that the request was never accepted, so a mutation-capable method whose
  /// response was lost is reported as an unknown outcome rather than as a
  /// transport error the caller might retry into a second dispatch.
  static func code(forTransportFailure failure: CLITransportFailure, method: String)
    -> CLIErrorCode
  {
    let isReadOnly = CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly
    switch failure {
    case .connectFailed:
      // Nothing was ever sent, so nothing was accepted, whatever the method.
      return .runtimeUnavailable
    case .malformedResponse:
      return isReadOnly ? .protocolMalformed : .outcomeUnknown
    case .lostResponse:
      // The frame never completed, which is an availability problem rather
      // than a schema violation: `protocolMalformed` is reserved for a frame
      // that arrived and broke the current shape.
      return isReadOnly ? .runtimeUnavailable : .outcomeUnknown
    case .clientTimeout:
      return isReadOnly ? .clientTimeout : .outcomeUnknown
    case .interrupted:
      return isReadOnly ? .clientInterrupted : .outcomeUnknown
    }
  }
}

/// The transport-level failures the CLI can observe, named by what they prove
/// rather than by the errno that produced them.
enum CLITransportFailure: Equatable {
  /// The connection never opened, so no request left the process.
  case connectFailed
  /// A frame arrived but did not parse as a response.
  case malformedResponse
  /// The peer closed, or the frame exceeded the bound, before a response
  /// completed.
  case lostResponse
  /// The client stopped waiting. It says nothing about the request.
  case clientTimeout
  /// The user interrupted the client. It does not cancel anything.
  case interrupted
}

/// The version of the §8.4 registry this build publishes. It moves whenever a
/// code is added, removed or re-mapped, independently of the CLI product
/// version and of the control protocol (§12).
enum CLIErrorRegistryVersion {
  static let current = "arkdeck.cli.error-registry/1"
}
