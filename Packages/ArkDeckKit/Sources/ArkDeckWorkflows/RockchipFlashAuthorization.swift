import ArkDeckCore
import ArkDeckStorage
import Foundation

// TASK-RF-002. REQ-FLASH-015 Agent/CI destructive boundary and the REQ-FLASH-007/008
// safety gates for the RockUSB Provider. Nothing in this file can dispatch a device
// command: its public output is either a human handoff document or a fail-closed decision.
// The internal AI path accepts only a one-shot admission minted by AuthorizationAdmissionService;
// it never accepts caller-provided authorization bytes/context and never returns command strings.
// The dispatch monitor exists to make the in-process zero visible in evidence.

// MARK: - Dispatch instrumentation

public enum RockchipObservedDispatchKind: String, CaseIterable, Codable, Equatable, Sendable {
  case destructiveDeviceDispatch
  case nonDestructiveDeviceDispatch
  case externalProcessDispatch
}

public struct RockchipDispatchSnapshot: Codable, Equatable, Sendable {
  public let destructiveDeviceDispatchCount: Int
  public let nonDestructiveDeviceDispatchCount: Int
  public let externalProcessDispatchCount: Int

  public var totalDispatchCount: Int {
    destructiveDeviceDispatchCount + nonDestructiveDeviceDispatchCount
      + externalProcessDispatchCount
  }
}

/// Counts dispatch attempts. The RF-002 codebase intentionally contains no code path that
/// records into it — contract tests snapshot it after every branch to prove the invariant
/// "Agent/CI destructive dispatch is always 0" is structural, not situational.
public actor RockchipFlashDispatchMonitor {
  private var counts: [RockchipObservedDispatchKind: Int] = [:]

  public init() {}

  public func record(_ kind: RockchipObservedDispatchKind) {
    counts[kind, default: 0] += 1
  }

  public func snapshot() -> RockchipDispatchSnapshot {
    RockchipDispatchSnapshot(
      destructiveDeviceDispatchCount: counts[.destructiveDeviceDispatch, default: 0],
      nonDestructiveDeviceDispatchCount: counts[.nonDestructiveDeviceDispatch, default: 0],
      externalProcessDispatchCount: counts[.externalProcessDispatch, default: 0])
  }
}

// MARK: - Execution authority and binding

public enum RockchipExecutionAuthority: String, CaseIterable, Codable, Equatable, Sendable {
  case standardAgent
  case ordinaryCI
  case humanOperator
}

/// Fail-closed authority resolution for the CLI. `humanOperator` requires both an explicit
/// operator identity and an interactive standard input; an environment override can only
/// downgrade, never claim human authority (REQ-FLASH-015: a Task or CI cannot self-upgrade).
public enum RockchipExecutionAuthorityResolver {
  public static func resolve(
    operatorProvided: Bool,
    standardInputIsInteractive: Bool,
    environmentOverride: String?
  ) -> RockchipExecutionAuthority {
    switch environmentOverride {
    case "ordinaryCI", "ci":
      return .ordinaryCI
    case "standardAgent", "agent":
      return .standardAgent
    default:
      break
    }
    if operatorProvided && standardInputIsInteractive {
      return .humanOperator
    }
    return .standardAgent
  }
}

public struct RockchipRealDeviceBinding: Equatable, Sendable {
  public let usbVendorID: UInt16
  public let usbProductID: UInt16
  public let usbLocationID: String

  public init(usbVendorID: UInt16, usbProductID: UInt16, usbLocationID: String) {
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.usbLocationID = usbLocationID
  }

  public var identityDigestSHA256: String {
    RockchipRockUSBFlashProvider.sha256Hex(
      Data(
        String(
          format: "rockusb|%04x:%04x|location=%@",
          usbVendorID, usbProductID, usbLocationID
        ).utf8))
  }
}

public enum RockchipDeviceBindingState: Equatable, Sendable {
  case none
  case realDevice(RockchipRealDeviceBinding)
}

// MARK: - Manual confirmation (AC-FLASH-015-02)

public struct RockchipManualFlashConfirmation: Equatable, Sendable {
  public let operatorIdentity: String
  public let targetBindingDigestSHA256: String
  public let firmwareArchiveSHA256: String
  public let transport: String
  public let toolchainFingerprint: String
  public let providerIdentity: String
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let confirmedAtTimestamp: String

  public init(
    operatorIdentity: String,
    targetBindingDigestSHA256: String,
    firmwareArchiveSHA256: String,
    transport: String,
    toolchainFingerprint: String,
    providerIdentity: String,
    planDigestSHA256: String,
    stepSetDigestSHA256: String,
    confirmedAtTimestamp: String
  ) {
    self.operatorIdentity = operatorIdentity
    self.targetBindingDigestSHA256 = targetBindingDigestSHA256.lowercased()
    self.firmwareArchiveSHA256 = firmwareArchiveSHA256.lowercased()
    self.transport = transport
    self.toolchainFingerprint = toolchainFingerprint
    self.providerIdentity = providerIdentity
    self.planDigestSHA256 = planDigestSHA256.lowercased()
    self.stepSetDigestSHA256 = stepSetDigestSHA256.lowercased()
    self.confirmedAtTimestamp = confirmedAtTimestamp
  }
}

// MARK: - Human handoff

/// The only executable artifact this codebase produces for a real flash: an exact,
/// human-readable command sequence on the closed design §0 surface. A human operator runs
/// these commands personally; ArkDeck never does.
public struct RockchipHumanHandoff: Equatable, Sendable {
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let commandLines: [String]
  public let confirmationRequirements: [String]
  public let recoveryPathSummary: String

  public static func make(
    plan: RockchipFlashPlan,
    profile: RockchipFlashProfile,
    noteMissingStandingAuthorization: Bool = false
  ) -> RockchipHumanHandoff {
    var commandLines: [String] = [
      "sudo rkdeveloptool ld",
      "sudo rkdeveloptool ppt",
    ]
    for partition in profile.mappedPartitions {
      commandLines.append(
        "sudo rkdeveloptool wlx \(partition.partitionName) \(partition.imageMemberName)")
    }
    commandLines.append("sudo rkdeveloptool rd")
    var requirements: [String] = []
    if noteMissingStandingAuthorization {
      requirements.append(
        "No valid standing authorization carrier covers this plan (CHG-2026-025): either a "
          + "maintainer merges an AUTH-*.json readiness carrier for unattended agent "
          + "execution, or a human operator executes the commands personally.")
    }
    requirements.append(contentsOf: [
      "Execution requires either a human operator running every command personally, or a "
        + "standing authorization approved by a maintainer-merged PR whose pins match "
        + "this plan exactly (REQ-FLASH-015).",
      "Before the first real device step, the authorizing record (human manual "
        + "confirmation, or the standing authorization pins for an unattended run) must "
        + "exactly match this plan: target identity, firmware archive SHA-256, transport, "
        + "toolchain fingerprint, Provider identity, plan and step-set digest.",
      "`ld` must report 0x2207:0x350a Loader before anything else (mode gate).",
      "`ppt` output must match the FA-001 §2 15-row baseline before any wlx write; "
        + "the `wl <BeginSec>` fallback sector values come from the Profile, never from "
        + "manual arithmetic.",
      "Every wlx write must end with \"\(RockchipRockUSBFlashProvider.writeSuccessMarker)\" "
        + "and exit 0; any deviation stops the sequence (fail closed).",
    ])
    return RockchipHumanHandoff(
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      commandLines: commandLines,
      confirmationRequirements: requirements,
      recoveryPathSummary:
        "CHG-2026-016 verified Loader-mode wlx recovery route (attempt #5): re-enter Loader, "
        + "ppt baseline compare, wlx the 9 mapped partitions from a validated archive, rd.")
  }
}

// MARK: - Authorization gate (AC-FLASH-002-01 / AC-FLASH-007-01 / AC-FLASH-015-01/-02)

public enum RockchipEvidenceEligibility: String, Codable, Equatable, Sendable {
  /// This in-process run can never produce realHardware evidence by itself.
  case notEligible
  /// The gate passed for a human operator; the human-executed run (and only it) may
  /// produce realHardware evidence.
  case humanExecutedRunMayProduceRealHardwareEvidence
  /// A verifier-minted admission passed the plan-binding check. TASK-AIN-006 still has no
  /// executor, so this is admission-only and cannot by itself produce realHardware evidence.
  case authorizedAgentAdmissionOnly
}

public enum RockchipAuthorizationOutcome: Equatable, Sendable {
  case allowedNonExecuteBranch
  case blockedByPrerequisites([RockchipPrerequisiteViolation])
  case blockedDestructiveConfirmationDeclined
  /// Agent/CI credential with an execute plan and no covering standing authorization:
  /// Job is marked policyBlocked and a controlled handoff is produced that names the
  /// missing authorization carrier (AC-FLASH-015-01).
  case policyBlocked(handoff: RockchipHumanHandoff)
  case blockedMissingManualConfirmation
  case blockedManualConfirmationMismatch(fields: [String])
  case blockedTargetBindingUnconfirmed
  /// Standing authorization exists but is past validUntil, over its run ceiling, or its
  /// validity inputs are unparseable (AC-FLASH-015-02, fail closed).
  case blockedStandingAuthorizationExpiredOrExhausted(reason: String)
  /// Standing authorization pins differ from the plan/environment on the listed fields
  /// (AC-FLASH-015-02).
  case blockedStandingAuthorizationMismatch(fields: [String])
  /// Pre-dispatch device identity readback is missing or does not match the authorized
  /// target (AC-FLASH-015-02, machine physical-target confirmation).
  case blockedDeviceIdentityReadbackMismatch(fields: [String])
  case authorizedForHumanExecution(handoff: RockchipHumanHandoff)
  /// Internal admission pass for TASK-AIN-007. This carries audit identity only, not commands,
  /// external-process arguments, a serializable capability or a durable workflow intent.
  case authorizedAgentAdmissionAccepted(reservationID: String)
}

public struct RockchipAuthorizationDecision: Equatable, Sendable {
  public let outcome: RockchipAuthorizationOutcome
  public let evidenceEligibility: RockchipEvidenceEligibility
  /// Journal/job marker; "policyBlocked" matches the vocabulary already used by the
  /// device-binding journal adapter.
  public let jobMarker: String
  public let dispatchSnapshot: RockchipDispatchSnapshot
  /// Set only when an internal verifier-minted admission was supplied. This typed reference is
  /// audit identity and cannot reconstruct the non-Codable one-shot admission capability.
  public let authorizationRef: AuthorizationReference?

  init(
    outcome: RockchipAuthorizationOutcome,
    evidenceEligibility: RockchipEvidenceEligibility,
    jobMarker: String,
    dispatchSnapshot: RockchipDispatchSnapshot,
    authorizationRef: AuthorizationReference? = nil
  ) {
    self.outcome = outcome
    self.evidenceEligibility = evidenceEligibility
    self.jobMarker = jobMarker
    self.dispatchSnapshot = dispatchSnapshot
    self.authorizationRef = authorizationRef
  }
}

public struct RockchipFlashAuthorizationGate: Sendable {
  public let profile: RockchipFlashProfile

  public init(profile: RockchipFlashProfile = .dayu200) {
    self.profile = profile
  }

  public func authorize(
    authority: RockchipExecutionAuthority,
    binding: RockchipDeviceBindingState,
    plan: RockchipFlashPlan,
    prerequisites: RockchipPrerequisiteGateResult,
    destructiveConfirmationAccepted: Bool,
    manualConfirmation: RockchipManualFlashConfirmation?,
    monitor: RockchipFlashDispatchMonitor
  ) async -> RockchipAuthorizationDecision {
    let snapshot = await monitor.snapshot()

    guard plan.executionMode == .execute else {
      // planOnly and simulated are the only branches every credential may take;
      // neither contains a real dispatch path.
      return RockchipAuthorizationDecision(
        outcome: .allowedNonExecuteBranch,
        evidenceEligibility: .notEligible,
        jobMarker: "allowedNonExecuteBranch",
        dispatchSnapshot: snapshot)
    }

    guard authority == .humanOperator else {
      // Caller-supplied authorization bytes/context are not part of this API. AIN-007 must first
      // obtain an internal RockchipAuthorizedAgentAdmission and call the internal overload below.
      return RockchipAuthorizationDecision(
        outcome: .policyBlocked(
          handoff: RockchipHumanHandoff.make(
            plan: plan, profile: profile, noteMissingStandingAuthorization: true)),
        evidenceEligibility: .notEligible,
        jobMarker: "policyBlocked",
        dispatchSnapshot: snapshot)
    }

    if case .blockedBeforeDestructiveConfirmation(let violations) = prerequisites {
      return RockchipAuthorizationDecision(
        outcome: .blockedByPrerequisites(violations),
        evidenceEligibility: .notEligible,
        jobMarker: "prerequisiteBlocked",
        dispatchSnapshot: snapshot)
    }

    guard destructiveConfirmationAccepted else {
      return RockchipAuthorizationDecision(
        outcome: .blockedDestructiveConfirmationDeclined,
        evidenceEligibility: .notEligible,
        jobMarker: "destructiveConfirmationDeclined",
        dispatchSnapshot: snapshot)
    }

    guard case .realDevice(let realBinding) = binding else {
      return RockchipAuthorizationDecision(
        outcome: .blockedTargetBindingUnconfirmed,
        evidenceEligibility: .notEligible,
        jobMarker: "targetBindingUnconfirmed",
        dispatchSnapshot: snapshot)
    }

    guard let confirmation = manualConfirmation else {
      return RockchipAuthorizationDecision(
        outcome: .blockedMissingManualConfirmation,
        evidenceEligibility: .notEligible,
        jobMarker: "manualConfirmationMissing",
        dispatchSnapshot: snapshot)
    }

    var mismatchedFields: [String] = []
    if confirmation.operatorIdentity.trimmingCharacters(in: .whitespaces).isEmpty {
      mismatchedFields.append("operatorIdentity")
    }
    if confirmation.targetBindingDigestSHA256 != realBinding.identityDigestSHA256 {
      mismatchedFields.append("targetBindingDigestSha256")
    }
    if confirmation.firmwareArchiveSHA256 != plan.archiveSHA256.lowercased() {
      mismatchedFields.append("firmwareArchiveSha256")
    }
    if confirmation.transport != "usb" {
      mismatchedFields.append("transport")
    }
    if confirmation.toolchainFingerprint != RockchipFlashProfile.pinnedToolchainFingerprint {
      mismatchedFields.append("toolchainFingerprint")
    }
    if confirmation.providerIdentity != RockchipRockUSBFlashProvider.providerIdentity {
      mismatchedFields.append("providerIdentity")
    }
    if confirmation.planDigestSHA256 != plan.planDigestSHA256.lowercased() {
      mismatchedFields.append("planDigestSha256")
    }
    if confirmation.stepSetDigestSHA256 != plan.stepSetDigestSHA256.lowercased() {
      mismatchedFields.append("stepSetDigestSha256")
    }
    guard mismatchedFields.isEmpty else {
      return RockchipAuthorizationDecision(
        outcome: .blockedManualConfirmationMismatch(fields: mismatchedFields),
        evidenceEligibility: .notEligible,
        jobMarker: "manualConfirmationMismatch",
        dispatchSnapshot: snapshot)
    }

    return RockchipAuthorizationDecision(
      outcome: .authorizedForHumanExecution(
        handoff: RockchipHumanHandoff.make(plan: plan, profile: profile)),
      evidenceEligibility: .humanExecutedRunMayProduceRealHardwareEvidence,
      jobMarker: "authorizedForHumanExecution",
      dispatchSnapshot: snapshot)
  }

  /// Internal bridge for TASK-AIN-007. The trusted fact collector has already checked authority,
  /// provenance, device identity, prerequisites and usage. This final check prevents a caller from
  /// presenting that admission for a different plan. No command surface or intent is returned.
  func authorizeUnattended(
    admission: RockchipAuthorizedAgentAdmission,
    plan: RockchipFlashPlan,
    monitor: RockchipFlashDispatchMonitor
  ) async -> RockchipAuthorizationDecision {
    let snapshot = await monitor.snapshot()
    var mismatchedFields: [String] = []
    if plan.executionMode != .execute { mismatchedFields.append("executionMode") }
    if plan.archiveSHA256 != admission.facts.plan.archiveSHA256 {
      mismatchedFields.append("firmwareArchiveSha256")
    }
    if plan.planDigestSHA256 != admission.facts.plan.planDigestSHA256 {
      mismatchedFields.append("planDigestSha256")
    }
    if plan.stepSetDigestSHA256 != admission.facts.plan.stepSetDigestSHA256 {
      mismatchedFields.append("stepSetDigestSha256")
    }
    guard mismatchedFields.isEmpty else {
      return RockchipAuthorizationDecision(
        outcome: .blockedStandingAuthorizationMismatch(fields: mismatchedFields),
        evidenceEligibility: .notEligible,
        jobMarker: "standingAuthorizationMismatch",
        dispatchSnapshot: snapshot)
    }

    return RockchipAuthorizationDecision(
      outcome: .authorizedAgentAdmissionAccepted(
        reservationID: admission.usageReservation.reservationID),
      evidenceEligibility: .authorizedAgentAdmissionOnly,
      jobMarker: "authorizedAgentAdmissionAccepted",
      dispatchSnapshot: snapshot,
      authorizationRef: admission.authorizationReference)
  }
}

// MARK: - Critical-write safe boundary (AC-FLASH-008-01)

public enum RockchipCriticalWriteBoundaryError: Error, Equatable, Sendable {
  case criticalSectionAlreadyActive(String)
  case noActiveCriticalSection
  case mismatchedCriticalSection(expected: String, actual: String)
  case subsequentStepsBlocked
}

public enum RockchipExitRequestDisposition: String, Codable, Equatable, Sendable {
  case effectiveImmediately
  case deferredUntilSafeBoundary
}

public struct RockchipExitDeferralRecord: Codable, Equatable, Sendable {
  public let requestID: String
  public let activeCriticalStepID: String?
  public let reason: String
  public let timestamp: String
  public let disposition: RockchipExitRequestDisposition

  /// Durable form of the deferral: callers persist this through the session audit store so
  /// the request survives a crash between "exit requested" and "safe boundary reached".
  public func auditRecord(sessionID: String, jobID: String) throws -> SessionAuditRecord {
    try SessionAuditRecord(
      recordID: requestID,
      auditID: "rockusb-exit-coordination",
      correlationID: "rockusb-flash-run",
      sessionID: sessionID,
      jobID: jobID,
      category: .intent,
      timestamp: timestamp,
      details: [
        "kind": .string("exitRequestDeferral"),
        "activeCriticalStepId": activeCriticalStepID.map(JSONValue.string) ?? .null,
        "reason": .string(reason),
        "disposition": .string(disposition.rawValue),
      ])
  }
}

/// Serializes exit coordination around criticalNonInterruptible partition writes: an exit
/// request during a critical write is recorded and deferred; it takes effect only at the
/// step's safe boundary, and then only by blocking subsequent steps — never by killing the
/// in-flight write (REQ-FLASH-008).
public actor RockchipCriticalWriteBoundary {
  public private(set) var activeCriticalStepID: String?
  public private(set) var pendingExitRequest: RockchipExitDeferralRecord?
  public private(set) var subsequentStepsBlocked = false
  private var requestSequence = 0

  public init() {}

  public func beginCriticalWrite(stepID: String) throws {
    if subsequentStepsBlocked {
      throw RockchipCriticalWriteBoundaryError.subsequentStepsBlocked
    }
    if let activeCriticalStepID {
      throw RockchipCriticalWriteBoundaryError.criticalSectionAlreadyActive(activeCriticalStepID)
    }
    activeCriticalStepID = stepID
  }

  public func requestExit(reason: String, timestamp: String) -> RockchipExitDeferralRecord {
    requestSequence += 1
    let record = RockchipExitDeferralRecord(
      requestID: "rockusb-exit-request-\(requestSequence)",
      activeCriticalStepID: activeCriticalStepID,
      reason: reason,
      timestamp: timestamp,
      disposition: activeCriticalStepID == nil
        ? .effectiveImmediately : .deferredUntilSafeBoundary)
    if activeCriticalStepID == nil {
      subsequentStepsBlocked = true
    } else {
      pendingExitRequest = record
    }
    return record
  }

  public func reachSafeBoundary(stepID: String) throws -> RockchipExitDeferralRecord? {
    guard let activeCriticalStepID else {
      throw RockchipCriticalWriteBoundaryError.noActiveCriticalSection
    }
    guard activeCriticalStepID == stepID else {
      throw RockchipCriticalWriteBoundaryError.mismatchedCriticalSection(
        expected: activeCriticalStepID, actual: stepID)
    }
    self.activeCriticalStepID = nil
    guard let pending = pendingExitRequest else { return nil }
    pendingExitRequest = nil
    subsequentStepsBlocked = true
    return pending
  }

  public func mayStartNextStep() -> Bool {
    !subsequentStepsBlocked && activeCriticalStepID == nil
  }
}
