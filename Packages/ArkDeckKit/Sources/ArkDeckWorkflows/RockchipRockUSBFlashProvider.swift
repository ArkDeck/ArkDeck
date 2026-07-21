import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

// TASK-RF-002. Typed RockUSB Provider for the DAYU200 forward-flash path (REQ-FLASH-001).
// The command surface is the closed design §0 face proven by CHG-2026-016 attempt #5:
// enter Loader → `ld` mode gate → `ppt` precheck → per-partition `wlx` → `rd` → postflight.
// This Provider never dispatches a device command itself: it produces typed plans,
// prerequisite/authorization verdicts, human handoffs and honest outcome assessments;
// real destructive execution belongs to a human operator (REQ-FLASH-015).

public enum RockchipFlashProviderError: Error, Equatable, Sendable {
  case archiveNotValidated([RockchipArchiveViolation])
  case invalidPlanNonce(String)
  case planAssemblyFailed(String)
}

// MARK: - Probe (AC-FLASH-001-01)

public struct RockchipProbeEvidence: Equatable, Sendable {
  public static let rockUSBVendorID: UInt16 = 0x2207
  public static let dayu200LoaderProductID: UInt16 = 0x350a

  public let usbVendorID: UInt16
  public let usbProductID: UInt16
  /// Mode string as reported by `rkdeveloptool ld`, e.g. "Loader" or "Maskrom".
  public let reportedMode: String

  public init(usbVendorID: UInt16, usbProductID: UInt16, reportedMode: String) {
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.reportedMode = reportedMode
  }
}

public enum RockchipProbeBlockReason: Equatable, Sendable, CustomStringConvertible {
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
      "device is in Maskrom mode; this Provider only supports the verified Loader-mode wlx "
        + "path and will not attempt similar commands (a Maskrom branch is a separate Provider)"
    case .unrecognizedDeviceMode(let mode):
      "unrecognized device mode \"\(mode)\"; preflight blocked"
    }
  }
}

public enum RockchipProbeVerdict: Equatable, Sendable {
  case applicableLoaderMode
  case blocked(RockchipProbeBlockReason)

  public var blocksPreflight: Bool {
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

public struct RockchipPrerequisiteViolation: Equatable, Sendable, CustomStringConvertible {
  public let identifier: RockchipPrerequisiteIdentifier
  public let requirement: RockchipPrerequisiteRequirement
  public let status: RockchipPrerequisiteStatus

  public var description: String {
    "required prerequisite \(identifier.rawValue) is \(status.rawValue); "
      + "the execute branch cannot begin"
  }
}

public enum RockchipPrerequisiteGateResult: Equatable, Sendable {
  case cleared
  /// Blocks before the destructive confirmation is even offered (REQ-FLASH-002).
  case blockedBeforeDestructiveConfirmation([RockchipPrerequisiteViolation])

  public var blocksExecuteBranch: Bool {
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

// MARK: - Plan

public struct RockchipFlashPlan: Equatable, Sendable {
  public let executionMode: RockchipFlashExecutionMode
  public let steps: [WorkflowStep]
  public let confirmationID: String
  public let destructiveStepIDs: [String]
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let archiveSHA256: String
  public let archiveSizeBytes: Int64
  public let dataImpact: [String]

  public var containsDestructiveSteps: Bool { !destructiveStepIDs.isEmpty }
}

public struct RockchipFlashPlanDocument: Codable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"

  public let executionMode: RockchipFlashExecutionMode
  public let providerIdentity: String
  public let providerVersion: String
  public let profileIdentity: String
  public let profileVersion: String
  public let targetDeviceModel: String
  public let archiveSHA256: String
  public let archiveSizeBytes: Int64
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
    self.planDigestSHA256 = planDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.dataImpact = dataImpact
    self.steps = steps
  }

  public func encode(to encoder: any Encoder) throws {
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
    try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
    try container.encode(stepSetDigestSHA256, forKey: .stepSetDigestSHA256)
    try container.encode(dataImpact, forKey: .dataImpact)
    try container.encode(steps, forKey: .steps)
  }

  public func canonicalData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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
    case planDigestSHA256 = "planDigestSha256"
    case stepSetDigestSHA256 = "stepSetDigestSha256"
    case dataImpact
    case steps
  }
}

// MARK: - Outcome assessment (AC-FLASH-012-01 / AC-FLASH-013-01)

public struct RockchipPartitionWriteObservation: Equatable, Sendable {
  public let partitionName: String
  public let toolExitCode: Int32
  public let semanticOutput: String

  public init(partitionName: String, toolExitCode: Int32, semanticOutput: String) {
    self.partitionName = partitionName
    self.toolExitCode = toolExitCode
    self.semanticOutput = semanticOutput
  }
}

public struct RockchipFlashRunObservation: Equatable, Sendable {
  public let partitionWrites: [RockchipPartitionWriteObservation]
  public let resetExitCode: Int32?
  public let resetSemanticOutput: String?
  public let reconnectedWithinDeadline: Bool
  public let postflightProbeSemanticOutput: String?

  public init(
    partitionWrites: [RockchipPartitionWriteObservation],
    resetExitCode: Int32?,
    resetSemanticOutput: String?,
    reconnectedWithinDeadline: Bool,
    postflightProbeSemanticOutput: String?
  ) {
    self.partitionWrites = partitionWrites
    self.resetExitCode = resetExitCode
    self.resetSemanticOutput = resetSemanticOutput
    self.reconnectedWithinDeadline = reconnectedWithinDeadline
    self.postflightProbeSemanticOutput = postflightProbeSemanticOutput
  }
}

public enum RockchipOutcomeCertainty: String, Codable, Equatable, Sendable {
  case confirmed
  case outcomeUnknown
}

public struct RockchipFlashOutcomeAssessment: Equatable, Sendable {
  public let jobState: JobState
  public let certainty: RockchipOutcomeCertainty
  public let failures: [String]
  public let recoveryGuide: RockchipRecoveryGuide?

  public var isSucceeded: Bool { jobState == .succeeded }
}

// MARK: - Recovery (AC-FLASH-013-01)

public struct RockchipRecoveryContext: Equatable, Sendable {
  public let currentPhase: String
  public let lastConfirmedStepID: String?
  /// "unknown" is an acceptable and honest value.
  public let observedDeviceMode: String

  public init(currentPhase: String, lastConfirmedStepID: String?, observedDeviceMode: String) {
    self.currentPhase = currentPhase
    self.lastConfirmedStepID = lastConfirmedStepID
    self.observedDeviceMode = observedDeviceMode
  }
}

public struct RockchipRecoveryGuide: Equatable, Sendable {
  public let currentPhase: String
  public let lastConfirmedStepID: String?
  public let deviceMode: String
  /// The CHG-2026-016 verified Loader-mode wlx recovery route, for a human operator.
  public let manualRecoverySteps: [String]
  public let disclosures: [String]
  /// Honesty invariant: ArkDeck never guarantees automatic recovery (REQ-FLASH-013).
  public let automaticRecoveryGuaranteed: Bool
}

// MARK: - Provider

public struct RockchipRockUSBFlashProvider: Sendable {
  public static let providerIdentity = "arkdeck.rockchip-rockusb-flash-provider"
  public static let providerVersion = "1.0.0"

  /// The entire rkdeveloptool vocabulary this Provider may put in front of a human.
  /// `db`/`gpt`/`ul` and every other Maskrom/miniloader-stage command are deliberately
  /// absent: on an inapplicable device the Provider blocks instead of trying anything
  /// similar (AC-FLASH-001-01; #218/#220 evidence).
  public static let closedCommandSurface: [String] = ["ld", "ppt", "wlx", "wl", "rd"]

  public static let writeSuccessMarker = "Write LBA from file (100%)"
  public static let resetSuccessMarker = "Reset Device OK."
  public static let loaderCommandSubsetRejectionMarker =
    "The device does not support this operation!"
  public static let postflightConnectedMarker = "Connected"

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

  public func evaluatePrerequisites(
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

  public func makePlan(
    mode: RockchipFlashExecutionMode,
    archiveValidation: RockchipArchiveValidationVerdict,
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
            "providerOperationId": .string("rockusb.wlx-write"),
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
          "profile=\(RockchipFlashProfile.profileIdentity)@\(RockchipFlashProfile.profileVersion)",
          "archive=\(profile.archiveSHA256)",
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
      dataImpact: [
        "all 9 mapped partitions (uboot…userdata) are overwritten from the validated archive",
        "userdata is overwritten: existing user data on the device is destroyed",
        "orphan images, memberless partitions and sector gaps are never written",
      ])
  }

  public func planDocument(for plan: RockchipFlashPlan) -> RockchipFlashPlanDocument {
    RockchipFlashPlanDocument(
      executionMode: plan.executionMode,
      providerIdentity: Self.providerIdentity,
      providerVersion: Self.providerVersion,
      profileIdentity: RockchipFlashProfile.profileIdentity,
      profileVersion: RockchipFlashProfile.profileVersion,
      targetDeviceModel: RockchipFlashProfile.targetDeviceModel,
      archiveSHA256: plan.archiveSHA256,
      archiveSizeBytes: plan.archiveSizeBytes,
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      dataImpact: plan.dataImpact,
      steps: plan.steps)
  }

  // MARK: Outcome

  public func assessOutcome(
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
      if write.semanticOutput.contains(Self.loaderCommandSubsetRejectionMarker) {
        failures.append(
          "partition \(partition.partitionName): device rejected the write "
            + "(Loader command-subset rejection)")
        explicitFailure = true
        break
      }
      if write.toolExitCode != 0 {
        failures.append(
          "partition \(partition.partitionName): tool exit code \(write.toolExitCode)")
        explicitFailure = true
        break
      }
      guard write.semanticOutput.contains(Self.writeSuccessMarker) else {
        // Exit 0 alone is never success (REQ-FLASH-012): without the semantic marker the
        // write outcome is unknown, not confirmed.
        failures.append(
          "partition \(partition.partitionName): tool exited 0 but semantic marker "
            + "\"\(Self.writeSuccessMarker)\" is absent")
        break
      }
      lastConfirmedStepID = stepID
    }

    if failures.isEmpty {
      currentPhase = "reset"
      if let resetExitCode = observation.resetExitCode,
        let resetOutput = observation.resetSemanticOutput
      {
        if resetExitCode != 0 {
          failures.append("reset: tool exit code \(resetExitCode)")
          explicitFailure = true
        } else if !resetOutput.contains(Self.resetSuccessMarker) {
          failures.append(
            "reset: tool exited 0 but semantic marker \"\(Self.resetSuccessMarker)\" is absent")
        }
      } else {
        failures.append("reset: not observed")
      }
    }

    if failures.isEmpty {
      currentPhase = "postflight"
      if !observation.reconnectedWithinDeadline {
        failures.append("device did not reconnect within the deadline")
      } else if let probeOutput = observation.postflightProbeSemanticOutput {
        if !probeOutput.contains(Self.postflightConnectedMarker) {
          failures.append(
            "postflight probe output does not report \"\(Self.postflightConnectedMarker)\"")
        }
      } else {
        failures.append("postflight probe was not observed")
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

  public func recover(context: RockchipRecoveryContext) -> RockchipRecoveryGuide {
    RockchipRecoveryGuide(
      currentPhase: context.currentPhase,
      lastConfirmedStepID: context.lastConfirmedStepID,
      deviceMode: context.observedDeviceMode,
      manualRecoverySteps: [
        "Re-enter Loader mode using the documented RECOVERY key sequence, then verify with "
          + "`sudo rkdeveloptool ld` that the device reports 0x2207:0x350a in Loader mode.",
        "Read the current partition table with `sudo rkdeveloptool ppt` and compare it row by "
          + "row against the FA-001 §2 baseline (15 rows).",
        "Re-write the 9 mapped partitions with `sudo rkdeveloptool wlx <name> <image>` in "
          + "Profile write order from a validated archive "
          + "(the CHG-2026-016 attempt #5 verified recovery route).",
        "Reset with `sudo rkdeveloptool rd` and confirm the device boots and reconnects.",
      ],
      disclosures: [
        "Flashing may destroy user data.",
        "The device may fail to boot until recovery completes.",
        "Vendor recovery tooling may be required; not every failure is recoverable here.",
        "The outcome stays unknown until postflight verification confirms it.",
      ],
      automaticRecoveryGuaranteed: false)
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
