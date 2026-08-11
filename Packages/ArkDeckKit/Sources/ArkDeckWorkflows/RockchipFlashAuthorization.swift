import ArkDeckCore
import ArkDeckStorage
import Foundation

// TASK-RF-002. REQ-FLASH-015 Agent/CI destructive boundary and the REQ-FLASH-007/008
// safety gates for the RockUSB Provider. This package-scoped GJ-4 manual handoff contract is a
// fail-closed fallback fixture, not a second product execution stack:
// nothing in this file can dispatch a device command, mint campaign authority, or impersonate
// the Runtime broker. Its output is a human handoff document or a fail-closed decision;
// autonomous dispatch uses the engine lane with fresh capability reservation/readback instead.
// The dispatch monitor makes this manual route's in-process zero visible in evidence.

// MARK: - Dispatch instrumentation

package enum RockchipObservedDispatchKind: String, CaseIterable, Codable, Equatable, Sendable {
  case destructiveDeviceDispatch
  case nonDestructiveDeviceDispatch
  case externalProcessDispatch
}

package struct RockchipDispatchSnapshot: Codable, Equatable, Sendable {
  package let destructiveDeviceDispatchCount: Int
  package let nonDestructiveDeviceDispatchCount: Int
  package let externalProcessDispatchCount: Int

  package var totalDispatchCount: Int {
    destructiveDeviceDispatchCount + nonDestructiveDeviceDispatchCount
      + externalProcessDispatchCount
  }
}

/// Counts dispatch attempts in the GJ-4 manual fallback only. It deliberately has no
/// recording path; this says nothing about the separately brokered Runtime E2 lane.
package actor RockchipFlashDispatchMonitor {
  private var counts: [RockchipObservedDispatchKind: Int] = [:]

  package init() {}

  package func record(_ kind: RockchipObservedDispatchKind) {
    counts[kind, default: 0] += 1
  }

  package func snapshot() -> RockchipDispatchSnapshot {
    RockchipDispatchSnapshot(
      destructiveDeviceDispatchCount: counts[.destructiveDeviceDispatch, default: 0],
      nonDestructiveDeviceDispatchCount: counts[.nonDestructiveDeviceDispatch, default: 0],
      externalProcessDispatchCount: counts[.externalProcessDispatch, default: 0])
  }
}

// MARK: - Execution authority and binding

package enum RockchipExecutionAuthority: String, CaseIterable, Codable, Equatable, Sendable {
  case standardAgent
  case ordinaryCI
  case humanOperator
}

/// Fail-closed authority resolution for the CLI. `humanOperator` requires both an explicit
/// operator identity and an interactive standard input; an environment override can only
/// downgrade, never claim human authority (REQ-FLASH-015: a Task or CI cannot self-upgrade).
package enum RockchipExecutionAuthorityResolver {
  package static func resolve(
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

package struct RockchipRealDeviceBinding: Equatable, Sendable {
  package let usbVendorID: UInt16
  package let usbProductID: UInt16
  package let usbLocationID: String

  package init(usbVendorID: UInt16, usbProductID: UInt16, usbLocationID: String) {
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.usbLocationID = usbLocationID
  }

  package var identityDigestSHA256: String {
    RockchipRockUSBFlashProvider.sha256Hex(
      Data(
        String(
          format: "rockusb|%04x:%04x|location=%@",
          usbVendorID, usbProductID, usbLocationID
        ).utf8))
  }
}

package enum RockchipDeviceBindingState: Equatable, Sendable {
  case none
  case realDevice(RockchipRealDeviceBinding)
}

// MARK: - Manual confirmation (AC-FLASH-015-02)

package struct RockchipManualFlashConfirmation: Equatable, Sendable {
  package let operatorIdentity: String
  package let targetBindingDigestSHA256: String
  package let firmwareArchiveSHA256: String
  package let transport: String
  package let toolchainFingerprint: String
  package let providerIdentity: String
  package let planDigestSHA256: String
  package let stepSetDigestSHA256: String
  package let confirmedAtTimestamp: String

  package init(
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

/// GJ-4 manual recovery fallback: an exact human-readable command sequence on the closed design
/// §0 surface. It is never Agent authority and cannot be converted into a Runtime capability,
/// reservation, or broker dispatch.
package struct RockchipHumanHandoff: Equatable, Sendable {
  package let planDigestSHA256: String
  package let stepSetDigestSHA256: String
  package let commandLines: [String]
  package let confirmationRequirements: [String]
  package let recoveryPathSummary: String

  package static func make(
    plan: RockchipFlashPlan,
    profile: RockchipFlashProfile,
    noteMissingRuntimeCapability: Bool = false
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
    if noteMissingRuntimeCapability {
      requirements.append(
        "This manual fallback has no covering Runtime capability. It cannot create authority "
          + "or dispatch: use the protected Runtime broker, or keep the sequence as a "
          + "personally executed recovery handoff.")
    }
    requirements.append(contentsOf: [
      "This manual handoff is not Agent authority. Agent execution must enter the protected "
        + "Runtime broker with an exact RuntimeCapability whose pins match this plan "
        + "(POL-AGENT-002).",
      "Before the first real device step, the authorizing record must exactly match this plan: "
        + "target identity, firmware archive SHA-256, transport, toolchain fingerprint, "
        + "Provider identity, plan and step-set digest.",
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

// MARK: - GJ-4 manual fallback gate (AC-FLASH-002-01 / AC-FLASH-007-01 / AC-FLASH-015-01/-02)

package enum RockchipManualFlashEvidenceEligibility: String, Codable, Equatable, Sendable {
  /// This in-process run can never produce realHardware evidence by itself.
  case notEligible
  /// The GJ-4 manual fallback passed for a human-executed handoff. The result does not
  /// represent brokered Agent E2 evidence.
  case humanExecutedRunMayProduceRealHardwareEvidence
}

package enum RockchipManualFlashFallbackOutcome: Equatable, Sendable {
  case allowedNonExecuteBranch
  case blockedByPrerequisites([RockchipPrerequisiteViolation])
  case blockedDestructiveConfirmationDeclined
  /// The manual route has no covering Runtime capability. It remains policyBlocked and emits
  /// a human handoff; it must not substitute for the protected Runtime broker.
  case policyBlocked(handoff: RockchipHumanHandoff)
  case blockedMissingManualConfirmation
  case blockedManualConfirmationMismatch(fields: [String])
  case blockedTargetBindingUnconfirmed
  /// Pre-dispatch device identity readback is missing or does not match the authorized
  /// target (AC-FLASH-015-02, machine physical-target confirmation).
  case authorizedForHumanExecution(handoff: RockchipHumanHandoff)
}

package struct RockchipManualFlashFallbackDecision: Equatable, Sendable {
  package let outcome: RockchipManualFlashFallbackOutcome
  package let evidenceEligibility: RockchipManualFlashEvidenceEligibility
  /// Journal/job marker; "policyBlocked" matches the vocabulary already used by the
  /// device-binding journal adapter.
  package let jobMarker: String
  package let dispatchSnapshot: RockchipDispatchSnapshot
  init(
    outcome: RockchipManualFlashFallbackOutcome,
    evidenceEligibility: RockchipManualFlashEvidenceEligibility,
    jobMarker: String,
    dispatchSnapshot: RockchipDispatchSnapshot
  ) {
    self.outcome = outcome
    self.evidenceEligibility = evidenceEligibility
    self.jobMarker = jobMarker
    self.dispatchSnapshot = dispatchSnapshot
  }
}

package struct RockchipManualFlashFallbackGate: Sendable {
  package let profile: RockchipFlashProfile

  package init(profile: RockchipFlashProfile = .dayu200) {
    self.profile = profile
  }

  package func authorize(
    authority: RockchipExecutionAuthority,
    binding: RockchipDeviceBindingState,
    plan: RockchipFlashPlan,
    prerequisites: RockchipPrerequisiteGateResult,
    destructiveConfirmationAccepted: Bool,
    manualConfirmation: RockchipManualFlashConfirmation?,
    monitor: RockchipFlashDispatchMonitor
  ) async -> RockchipManualFlashFallbackDecision {
    let snapshot = await monitor.snapshot()

    guard plan.executionMode == .execute else {
      // planOnly and simulated are the only branches every credential may take;
      // neither contains a real dispatch path.
      return RockchipManualFlashFallbackDecision(
        outcome: .allowedNonExecuteBranch,
        evidenceEligibility: .notEligible,
        jobMarker: "allowedNonExecuteBranch",
        dispatchSnapshot: snapshot)
    }

    guard authority == .humanOperator else {
      // Caller-supplied authority is not part of this API. Non-human callers receive an inert
      // handoff and must use the protected Runtime's typed Job lane for execution.
      return RockchipManualFlashFallbackDecision(
        outcome: .policyBlocked(
          handoff: RockchipHumanHandoff.make(
            plan: plan, profile: profile, noteMissingRuntimeCapability: true)),
        evidenceEligibility: .notEligible,
        jobMarker: "policyBlocked",
        dispatchSnapshot: snapshot)
    }

    if case .blockedBeforeDestructiveConfirmation(let violations) = prerequisites {
      return RockchipManualFlashFallbackDecision(
        outcome: .blockedByPrerequisites(violations),
        evidenceEligibility: .notEligible,
        jobMarker: "prerequisiteBlocked",
        dispatchSnapshot: snapshot)
    }

    guard destructiveConfirmationAccepted else {
      return RockchipManualFlashFallbackDecision(
        outcome: .blockedDestructiveConfirmationDeclined,
        evidenceEligibility: .notEligible,
        jobMarker: "destructiveConfirmationDeclined",
        dispatchSnapshot: snapshot)
    }

    guard case .realDevice(let realBinding) = binding else {
      return RockchipManualFlashFallbackDecision(
        outcome: .blockedTargetBindingUnconfirmed,
        evidenceEligibility: .notEligible,
        jobMarker: "targetBindingUnconfirmed",
        dispatchSnapshot: snapshot)
    }

    guard let confirmation = manualConfirmation else {
      return RockchipManualFlashFallbackDecision(
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
      return RockchipManualFlashFallbackDecision(
        outcome: .blockedManualConfirmationMismatch(fields: mismatchedFields),
        evidenceEligibility: .notEligible,
        jobMarker: "manualConfirmationMismatch",
        dispatchSnapshot: snapshot)
    }

    return RockchipManualFlashFallbackDecision(
      outcome: .authorizedForHumanExecution(
        handoff: RockchipHumanHandoff.make(plan: plan, profile: profile)),
      evidenceEligibility: .humanExecutedRunMayProduceRealHardwareEvidence,
      jobMarker: "authorizedForHumanExecution",
      dispatchSnapshot: snapshot)
  }

}

// MARK: - Critical-write safe boundary (AC-FLASH-008-01)

/// Package-only safety primitive. The Runtime owns production cancellation coordination; this
/// state machine remains a contract fixture until a product composition root consumes it.
package enum RockchipCriticalWriteBoundaryError: Error, Equatable, Sendable {
  case criticalSectionAlreadyActive(String)
  case noActiveCriticalSection
  case mismatchedCriticalSection(expected: String, actual: String)
  case subsequentStepsBlocked
}

package enum RockchipExitRequestDisposition: String, Codable, Equatable, Sendable {
  case effectiveImmediately
  case deferredUntilSafeBoundary
}

package struct RockchipExitDeferralRecord: Codable, Equatable, Sendable {
  package let requestID: String
  package let activeCriticalStepID: String?
  package let reason: String
  package let timestamp: String
  package let disposition: RockchipExitRequestDisposition

  /// Durable form of the deferral: callers persist this through the session audit store so
  /// the request survives a crash between "exit requested" and "safe boundary reached".
  package func auditRecord(sessionID: String, jobID: String) throws -> SessionAuditRecord {
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
package actor RockchipCriticalWriteBoundary {
  package private(set) var activeCriticalStepID: String?
  package private(set) var pendingExitRequest: RockchipExitDeferralRecord?
  package private(set) var subsequentStepsBlocked = false
  private var requestSequence = 0

  package init() {}

  package func beginCriticalWrite(stepID: String) throws {
    if subsequentStepsBlocked {
      throw RockchipCriticalWriteBoundaryError.subsequentStepsBlocked
    }
    if let activeCriticalStepID {
      throw RockchipCriticalWriteBoundaryError.criticalSectionAlreadyActive(activeCriticalStepID)
    }
    activeCriticalStepID = stepID
  }

  package func requestExit(reason: String, timestamp: String) -> RockchipExitDeferralRecord {
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

  package func reachSafeBoundary(stepID: String) throws -> RockchipExitDeferralRecord? {
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

  package func mayStartNextStep() -> Bool {
    !subsequentStepsBlocked && activeCriticalStepID == nil
  }
}
