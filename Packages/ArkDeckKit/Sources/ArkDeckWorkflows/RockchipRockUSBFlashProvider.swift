import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

// Typed RockUSB Provider for the DAYU200 forward-flash path. The published
// plan enters Loader, verifies the observed partition table, writes and reads
// back every mapped partition, resets, then verifies the bound postflight.
// This Provider never dispatches a device command itself: it produces typed plans,
// prerequisite/authorization verdicts, the GJ-4 manual recovery fallback and
// honest outcome assessments. Runtime E2 dispatch, after the protected Runtime issues and
// durably reserves an exact RuntimeCapability, belongs exclusively to the merged broker;
// this Provider remains incapable of direct dispatch (POL-AGENT-002).

public enum RockchipFlashProviderError: Error, Equatable, Sendable {
  case archiveNotValidated([RockchipArchiveViolation])
  case invalidPlanNonce(String)
  case planAssemblyFailed(String)
}

// MARK: - Probe (AC-FLASH-001-01)

package struct RockchipProbeEvidence: Equatable, Sendable {
  package static let rockUSBVendorID: UInt16 = 0x2207
  package static let dayu200LoaderProductID: UInt16 = 0x350a

  package let usbVendorID: UInt16
  package let usbProductID: UInt16
  /// Mode string reported by ArkForge native discovery, e.g. "Loader" or "Maskrom".
  package let reportedMode: String

  public init(usbVendorID: UInt16, usbProductID: UInt16, reportedMode: String) {
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.reportedMode = reportedMode
  }
}

package enum RockchipProbeBlockReason: Equatable, Sendable, CustomStringConvertible {
  case deviceNotRockUSB(vendorID: UInt16, productID: UInt16)
  case maskromModeNotSupportedByThisProvider
  case unrecognizedDeviceMode(String)

  public var description: String {
    switch self {
    case .deviceNotRockUSB(let vendorID, let productID):
      String(
        format: "device %04x:%04x is not the RockUSB DAYU200 Loader target; preflight blocked",
        vendorID, productID)
    case .maskromModeNotSupportedByThisProvider:
      "device is in Maskrom mode; this Provider only supports the verified native Loader "
        + "path and will not infer a similar operation (Maskrom rescue is separate)"
    case .unrecognizedDeviceMode(let mode):
      "unrecognized device mode \"\(mode)\"; preflight blocked"
    }
  }
}

package enum RockchipProbeVerdict: Equatable, Sendable {
  case applicableLoaderMode
  case blocked(RockchipProbeBlockReason)

  package var blocksPreflight: Bool {
    if case .blocked = self { return true }
    return false
  }
}

// MARK: - Prerequisites (AC-FLASH-002-01)

public struct RockchipPrerequisiteObservation: Equatable, Sendable {
  public let identifier: RockchipPrerequisiteIdentifier
  public let status: RockchipPrerequisiteStatus

  public init(identifier: RockchipPrerequisiteIdentifier, status: RockchipPrerequisiteStatus) {
    self.identifier = identifier
    self.status = status
  }
}

package struct RockchipPrerequisiteViolation: Equatable, Sendable, CustomStringConvertible {
  public let identifier: RockchipPrerequisiteIdentifier
  public let requirement: RockchipPrerequisiteRequirement
  public let status: RockchipPrerequisiteStatus

  public var description: String {
    "required prerequisite \(identifier.rawValue) is \(status.rawValue); "
      + "the execute branch cannot begin"
  }
}

package enum RockchipPrerequisiteGateResult: Equatable, Sendable {
  case cleared
  /// Blocks before the destructive confirmation is even offered (REQ-FLASH-002).
  case blockedBeforeDestructiveConfirmation([RockchipPrerequisiteViolation])

  package var blocksExecuteBranch: Bool {
    if case .blockedBeforeDestructiveConfirmation = self { return true }
    return false
  }
}

// MARK: - Execution modes (AC-FLASH-004-01)

public enum RockchipFlashExecutionMode: String, CaseIterable, Codable, Equatable, Sendable {
  case execute
  case planOnly
  case simulated
}

package enum RockchipPostFlashVerificationLevel: String, CaseIterable, Codable, Equatable,
  Sendable
{
  case basic
  case full
}

// MARK: - Plan

package struct RockchipFlashPlan: Equatable, Sendable {
  public let executionMode: RockchipFlashExecutionMode
  public let steps: [WorkflowStep]
  package let confirmationID: String
  package let destructiveStepIDs: [String]
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let archiveSHA256: String
  public let archiveSizeBytes: Int64
  package let postFlashVerification: RockchipPostFlashVerificationLevel
  public let dataImpact: [String]

  package var containsDestructiveSteps: Bool { !destructiveStepIDs.isEmpty }
}

package struct RockchipFlashPlanDocument: Codable, Equatable, Sendable {
  package static let schemaVersion = "1.0.0"

  public let executionMode: RockchipFlashExecutionMode
  package let providerIdentity: String
  package let providerVersion: String
  package let profileIdentity: String
  package let profileVersion: String
  package let targetDeviceModel: String
  public let archiveSHA256: String
  public let archiveSizeBytes: Int64
  package let postFlashVerification: RockchipPostFlashVerificationLevel
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let dataImpact: [String]
  public let steps: [WorkflowStep]

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .schemaVersion) == Self.schemaVersion else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "unsupported plan document schema version"))
    }
    executionMode = try container.decode(RockchipFlashExecutionMode.self, forKey: .executionMode)
    providerIdentity = try container.decode(String.self, forKey: .providerIdentity)
    providerVersion = try container.decode(String.self, forKey: .providerVersion)
    profileIdentity = try container.decode(String.self, forKey: .profileIdentity)
    profileVersion = try container.decode(String.self, forKey: .profileVersion)
    targetDeviceModel = try container.decode(String.self, forKey: .targetDeviceModel)
    archiveSHA256 = try container.decode(String.self, forKey: .archiveSHA256)
    archiveSizeBytes = try container.decode(Int64.self, forKey: .archiveSizeBytes)
    postFlashVerification =
      try container.decodeIfPresent(
        RockchipPostFlashVerificationLevel.self, forKey: .postFlashVerification) ?? .full
    planDigestSHA256 = try container.decode(String.self, forKey: .planDigestSHA256)
    stepSetDigestSHA256 = try container.decode(String.self, forKey: .stepSetDigestSHA256)
    dataImpact = try container.decode([String].self, forKey: .dataImpact)
    steps = try container.decode([WorkflowStep].self, forKey: .steps)
  }

  fileprivate init(
    executionMode: RockchipFlashExecutionMode,
    providerIdentity: String,
    providerVersion: String,
    profileIdentity: String,
    profileVersion: String,
    targetDeviceModel: String,
    archiveSHA256: String,
    archiveSizeBytes: Int64,
    postFlashVerification: RockchipPostFlashVerificationLevel,
    planDigestSHA256: String,
    stepSetDigestSHA256: String,
    dataImpact: [String],
    steps: [WorkflowStep]
  ) {
    self.executionMode = executionMode
    self.providerIdentity = providerIdentity
    self.providerVersion = providerVersion
    self.profileIdentity = profileIdentity
    self.profileVersion = profileVersion
    self.targetDeviceModel = targetDeviceModel
    self.archiveSHA256 = archiveSHA256
    self.archiveSizeBytes = archiveSizeBytes
    self.postFlashVerification = postFlashVerification
    self.planDigestSHA256 = planDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.dataImpact = dataImpact
    self.steps = steps
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(providerIdentity, forKey: .providerIdentity)
    try container.encode(providerVersion, forKey: .providerVersion)
    try container.encode(profileIdentity, forKey: .profileIdentity)
    try container.encode(profileVersion, forKey: .profileVersion)
    try container.encode(targetDeviceModel, forKey: .targetDeviceModel)
    try container.encode(archiveSHA256, forKey: .archiveSHA256)
    try container.encode(archiveSizeBytes, forKey: .archiveSizeBytes)
    try container.encode(postFlashVerification, forKey: .postFlashVerification)
    try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
    try container.encode(stepSetDigestSHA256, forKey: .stepSetDigestSHA256)
    try container.encode(dataImpact, forKey: .dataImpact)
    try container.encode(steps, forKey: .steps)
  }

  package func canonicalData() throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(self)
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case executionMode
    case providerIdentity
    case providerVersion
    case profileIdentity
    case profileVersion
    case targetDeviceModel
    case archiveSHA256 = "archiveSha256"
    case archiveSizeBytes
    case postFlashVerification
    case planDigestSHA256 = "planDigestSha256"
    case stepSetDigestSHA256 = "stepSetDigestSha256"
    case dataImpact
    case steps
  }
}

// MARK: - Typed Runtime outcome assessment (AC-FLASH-012-01 / AC-FLASH-013-01)

package enum RockchipObservedStepOutcome: Equatable, Sendable {
  case confirmed
  case failed(String)
  case outcomeUnknown(String)
}

package struct RockchipPartitionWriteObservation: Equatable, Sendable {
  public let partitionName: String
  package let outcome: RockchipObservedStepOutcome

  package init(partitionName: String, outcome: RockchipObservedStepOutcome) {
    self.partitionName = partitionName
    self.outcome = outcome
  }
}

package struct RockchipFlashRunObservation: Equatable, Sendable {
  package let partitionWrites: [RockchipPartitionWriteObservation]
  package let resetOutcome: RockchipObservedStepOutcome
  package let postflightOutcome: RockchipObservedStepOutcome

  package init(
    partitionWrites: [RockchipPartitionWriteObservation],
    resetOutcome: RockchipObservedStepOutcome,
    postflightOutcome: RockchipObservedStepOutcome
  ) {
    self.partitionWrites = partitionWrites
    self.resetOutcome = resetOutcome
    self.postflightOutcome = postflightOutcome
  }
}

package enum RockchipOutcomeCertainty: String, Codable, Equatable, Sendable {
  case confirmed
  case outcomeUnknown
}

package struct RockchipFlashOutcomeAssessment: Equatable, Sendable {
  package let jobState: JobState
  package let certainty: RockchipOutcomeCertainty
  public let failures: [String]
  package let recoveryGuide: RockchipRecoveryGuide?

  package var isSucceeded: Bool { jobState == .succeeded }
}

// MARK: - Recovery (AC-FLASH-013-01)

package struct RockchipRecoveryContext: Equatable, Sendable {
  package let currentPhase: String
  package let lastConfirmedStepID: String?
  /// "unknown" is an acceptable and honest value.
  package let observedDeviceMode: String

  public init(currentPhase: String, lastConfirmedStepID: String?, observedDeviceMode: String) {
    self.currentPhase = currentPhase
    self.lastConfirmedStepID = lastConfirmedStepID
    self.observedDeviceMode = observedDeviceMode
  }
}

package struct RockchipRecoveryGuide: Equatable, Sendable {
  package let currentPhase: String
  package let lastConfirmedStepID: String?
  package let deviceMode: String
  /// A non-authoritative explanation of the Runtime-owned recovery route.
  package let manualRecoverySteps: [String]
  package let disclosures: [String]
  /// Honesty invariant: ArkDeck never guarantees automatic recovery (REQ-FLASH-013).
  package let automaticRecoveryGuaranteed: Bool
}

// MARK: - Provider

package struct RockchipRockUSBFlashProvider: Sendable {
  package static let providerIdentity = "arkdeck.rockchip-rockusb-flash-provider"
  package static let providerVersion = "1.0.0"

  public let profile: RockchipFlashProfile

  public init(profile: RockchipFlashProfile = .dayu200) {
    self.profile = profile
  }

  // MARK: Probe

  public func probe(_ evidence: RockchipProbeEvidence) -> RockchipProbeVerdict {
    guard evidence.usbVendorID == RockchipProbeEvidence.rockUSBVendorID,
      evidence.usbProductID == RockchipProbeEvidence.dayu200LoaderProductID
    else {
      return .blocked(
        .deviceNotRockUSB(vendorID: evidence.usbVendorID, productID: evidence.usbProductID))
    }
    switch evidence.reportedMode {
    case "Loader":
      return .applicableLoaderMode
    case "Maskrom":
      return .blocked(.maskromModeNotSupportedByThisProvider)
    default:
      return .blocked(.unrecognizedDeviceMode(evidence.reportedMode))
    }
  }

  // MARK: Prerequisites

  package func evaluatePrerequisites(
    _ observations: [RockchipPrerequisiteObservation]
  ) -> RockchipPrerequisiteGateResult {
    var observedStatus: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteStatus] = [:]
    for observation in observations {
      // A duplicated observation must never upgrade: keep the worst status seen.
      if let existing = observedStatus[observation.identifier], existing != .satisfied {
        continue
      }
      observedStatus[observation.identifier] = observation.status
    }

    var violations: [RockchipPrerequisiteViolation] = []
    for identifier in RockchipPrerequisiteIdentifier.allCases {
      guard let requirement = profile.prerequisites[identifier], requirement == .required else {
        continue
      }
      let status = observedStatus[identifier] ?? .unknown
      if status != .satisfied {
        violations.append(
          RockchipPrerequisiteViolation(
            identifier: identifier, requirement: requirement, status: status))
      }
    }
    return violations.isEmpty ? .cleared : .blockedBeforeDestructiveConfirmation(violations)
  }

  // MARK: Plan

  package func makePlan(
    mode: RockchipFlashExecutionMode,
    archiveValidation: RockchipArchiveValidationVerdict,
    postFlashVerification: RockchipPostFlashVerificationLevel = .full,
    planNonce: String = "rf002"
  ) throws -> RockchipFlashPlan {
    if case .blocked(let violations) = archiveValidation {
      throw RockchipFlashProviderError.archiveNotValidated(violations)
    }
    guard
      planNonce.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,31}$", options: .regularExpression)
        != nil
    else {
      throw RockchipFlashProviderError.invalidPlanNonce(planNonce)
    }

    let confirmationID = "rk-\(planNonce)-destructive-confirmation"
    var flashSteps: [WorkflowStep] = []
    var destructiveStepIDs: [String] = []
    var scopeLines: [String] = []
    for partition in profile.mappedPartitions {
      guard let member = profile.member(named: partition.imageMemberName) else {
        throw RockchipFlashProviderError.planAssemblyFailed(
          "mapped partition \(partition.partitionName) has no archive member")
      }
      let stepID = "rk-\(planNonce)-wlx-\(partition.writeOrder)-\(partition.partitionName)"
      destructiveStepIDs.append(stepID)
      scopeLines.append("\(partition.partitionName)|\(member.sha256.lowercased())")
      flashSteps.append(
        try WorkflowStep(
          id: stepID,
          kind: .flashPartition,
          declaredEffect: .destructive,
          declaredCancellation: .criticalNonInterruptible,
          declaredBindingRequirement: .confirmedDevice,
          arguments: [
            "providerOperationId": .string("rockusb.wl-write"),
            "partition": .string(partition.partitionName),
            "imageArtifactId": .string(member.name),
            "imageSha256": .string(member.sha256.lowercased()),
            "imageSize": .integer(member.sizeBytes),
            "confirmationId": .string(confirmationID),
            "safeBoundaryId": .string(
              "rk-\(planNonce)-safe-boundary-\(partition.writeOrder)-\(partition.partitionName)"),
          ]
        ))
    }
    let scopeHash = Self.sha256Hex(Data(scopeLines.joined(separator: "\n").utf8))

    var steps: [WorkflowStep] = []
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-request-destructive-confirmation",
        kind: .requestConfirmation,
        declaredEffect: .hostOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .none,
        arguments: [
          "confirmationId": .string(confirmationID),
          "promptKey": .string("rockusb-dayu200-forward-flash"),
          "riskClass": .string("destructive"),
          "scopeHash": .string(scopeHash),
        ]
      ))
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-enter-loader",
        kind: .enterUpdater,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("rockusb.enter-loader"),
          "expectedMode": .string("rockusb-loader-0x2207-0x350a"),
          "reconnectDeadlineMilliseconds": .integer(120_000),
        ]
      ))
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-ppt-precheck",
        kind: .verifyRemoteState,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("rockusb-ppt-precheck"),
          "expectedState": .string("existing-partition-table-matches-fa001-section2-15-rows"),
        ]
      ))
    steps.append(contentsOf: flashSteps)
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-verify-flash-readback",
        kind: .verifyRemoteState,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("rockusb-partition-readback"),
          "expectedState": .string("all-mapped-partition-prefix-hashes-match-profile"),
        ]
      ))
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-rd-reset",
        kind: .rebootDevice,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "targetMode": .string("normal"),
          "reason": .string("rockusb-rd-reset-after-flash"),
        ]
      ))
    steps.append(
      try WorkflowStep(
        id: "rk-\(planNonce)-postflight",
        kind: .verifyRemoteState,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("rockusb-postflight-list-targets"),
          "expectedState": .string("device-reconnected-and-reported-connected"),
        ]
      ))

    var stepSetLines: [String] = []
    for (index, step) in steps.enumerated() {
      let argumentsHash = try JournalCanonicalJSON.argumentsHash(step.arguments)
      stepSetLines.append("\(index)|\(step.id)|\(step.kind.rawValue)|\(argumentsHash)")
    }
    let stepSetDigest = Self.sha256Hex(Data(stepSetLines.joined(separator: "\n").utf8))
    let planDigest = Self.sha256Hex(
      Data(
        [
          "mode=\(mode.rawValue)",
          "provider=\(Self.providerIdentity)@\(Self.providerVersion)",
          "profile=\(RockchipFlashProfile.profileIdentity)@\(profile.planDocumentVersion)",
          "archive=\(profile.archiveSHA256)",
          "postFlashVerification=\(postFlashVerification.rawValue)",
          "stepSet=\(stepSetDigest)",
          "target=\(RockchipFlashProfile.targetDeviceModel)",
        ].joined(separator: "\n").utf8))

    return RockchipFlashPlan(
      executionMode: mode,
      steps: steps,
      confirmationID: confirmationID,
      destructiveStepIDs: destructiveStepIDs,
      planDigestSHA256: planDigest,
      stepSetDigestSHA256: stepSetDigest,
      archiveSHA256: profile.archiveSHA256,
      archiveSizeBytes: profile.archiveSizeBytes,
      postFlashVerification: postFlashVerification,
      dataImpact: [
        "all 9 mapped partitions (uboot…userdata) are overwritten from the validated archive",
        "userdata is overwritten: existing user data on the device is destroyed",
        "orphan images, memberless partitions and sector gaps are never written",
      ])
  }

  package func planDocument(for plan: RockchipFlashPlan) -> RockchipFlashPlanDocument {
    RockchipFlashPlanDocument(
      executionMode: plan.executionMode,
      providerIdentity: Self.providerIdentity,
      providerVersion: Self.providerVersion,
      profileIdentity: RockchipFlashProfile.profileIdentity,
      profileVersion: profile.planDocumentVersion,
      targetDeviceModel: RockchipFlashProfile.targetDeviceModel,
      archiveSHA256: plan.archiveSHA256,
      archiveSizeBytes: plan.archiveSizeBytes,
      postFlashVerification: plan.postFlashVerification,
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      dataImpact: plan.dataImpact,
      steps: plan.steps)
  }

  // MARK: Outcome

  package func assessOutcome(
    plan: RockchipFlashPlan,
    observation: RockchipFlashRunObservation
  ) -> RockchipFlashOutcomeAssessment {
    var failures: [String] = []
    var explicitFailure = false

    let writesByPartition = Dictionary(
      observation.partitionWrites.map { ($0.partitionName, $0) },
      uniquingKeysWith: { first, _ in first })
    var lastConfirmedStepID: String?
    var currentPhase = "enterLoader"
    for partition in profile.mappedPartitions {
      let stepID = plan.destructiveStepIDs[partition.writeOrder - 1]
      guard let write = writesByPartition[partition.partitionName] else {
        failures.append("partition \(partition.partitionName): write was not observed")
        currentPhase = "flashPartition:\(partition.partitionName)"
        break
      }
      currentPhase = "flashPartition:\(partition.partitionName)"
      switch write.outcome {
      case .confirmed:
        lastConfirmedStepID = stepID
      case .failed(let detail):
        failures.append("partition \(partition.partitionName): \(detail)")
        explicitFailure = true
        break
      case .outcomeUnknown(let detail):
        failures.append("partition \(partition.partitionName): \(detail)")
        break
      }
      if !failures.isEmpty { break }
    }

    if failures.isEmpty {
      currentPhase = "reset"
      switch observation.resetOutcome {
      case .confirmed:
        break
      case .failed(let detail):
        failures.append("reset: \(detail)")
        explicitFailure = true
      case .outcomeUnknown(let detail):
        failures.append("reset: \(detail)")
      }
    }

    if failures.isEmpty {
      currentPhase = "postflight"
      switch observation.postflightOutcome {
      case .confirmed:
        break
      case .failed(let detail):
        failures.append("postflight: \(detail)")
        explicitFailure = true
      case .outcomeUnknown(let detail):
        failures.append("postflight: \(detail)")
      }
    }

    if failures.isEmpty {
      return RockchipFlashOutcomeAssessment(
        jobState: .succeeded, certainty: .confirmed, failures: [], recoveryGuide: nil)
    }
    let context = RockchipRecoveryContext(
      currentPhase: currentPhase,
      lastConfirmedStepID: lastConfirmedStepID,
      observedDeviceMode: "unknown")
    return RockchipFlashOutcomeAssessment(
      jobState: explicitFailure ? .failed : .waitingForRecovery,
      certainty: explicitFailure ? .confirmed : .outcomeUnknown,
      failures: failures,
      recoveryGuide: recover(context: context))
  }

  // MARK: Recovery

  package func recover(context: RockchipRecoveryContext) -> RockchipRecoveryGuide {
    RockchipRecoveryGuide(
      currentPhase: context.currentPhase,
      lastConfirmedStepID: context.lastConfirmedStepID,
      deviceMode: context.observedDeviceMode,
      manualRecoverySteps: [
        "Keep the original Runtime job and its outcomeUnknown record intact; do not replay "
          + "the interrupted intent or run an external RockUSB command.",
        "Reconnect the exact bound target in Loader mode and let ArkForge native discovery "
          + "re-establish the same topology and stable device identity.",
        "Use the protected Runtime recovery path only when it proves "
          + "safeToSupersedeByCompleteOverwrite for the complete nine-partition plan and the "
          + "same immutable artifact.",
        "Accept recovery only after ArkForge readback, reset, Runtime rebind and postflight "
          + "evidence all reach a confirmed terminal.",
      ],
      disclosures: [
        "Flashing may destroy user data.",
        "The device may fail to boot until recovery completes.",
        "Maskrom rescue is a separate operator procedure and never becomes Runtime authority.",
        "The outcome stays unknown until postflight verification confirms it.",
      ],
      automaticRecoveryGuaranteed: false)
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}
