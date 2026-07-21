import ArkDeckCore
import CryptoKit
import Foundation

// MARK: - Reboot and capture gates

public enum TraceRebootRecoveryEvaluation: Equatable, Sendable {
  case autoRebindRequiresDurablePersistence(DeviceRebindCandidate)
  case awaitingRebindConfirmation(
    reason: DeviceRebindAwaitingReason,
    candidates: [DeviceRebindCandidate]
  )

  public var jobState: JobState {
    switch self {
    case .autoRebindRequiresDurablePersistence:
      // Core eligibility is not durable binding authority. Capture remains waiting until the
      // journal adapter returns a DurableCurrentDeviceBinding receipt.
      .waitingForDevice
    case .awaitingRebindConfirmation:
      .awaitingRebindConfirmation
    }
  }
}

public enum TraceRebootRecovery {
  public static func evaluate(_ context: DeviceRebindContext) -> TraceRebootRecoveryEvaluation {
    switch DeviceRebindPolicy.evaluate(
      transport: context.transport,
      disconnected: context.disconnected,
      endpointExplicitlyAdded: context.endpointExplicitlyAdded,
      expectedModeTransition: context.expectedModeTransition,
      candidates: context.candidates,
      profile: context.profile)
    {
    case .autoRebindEligible(let candidate):
      return .autoRebindRequiresDurablePersistence(candidate)
    case .awaitingRebindConfirmation(let reason, let candidates):
      return .awaitingRebindConfirmation(reason: reason, candidates: candidates)
    }
  }
}

public enum TraceRebootCaptureGate: Equatable, Sendable {
  case notRequired
  case pending(TraceRebootRecoveryEvaluation)
  case bindingDurablyConfirmed(DurableCurrentDeviceBinding)
}

public enum TraceCaptureBlockReason: Equatable, Sendable {
  case adapterCapabilitiesChanged(unsupportedTags: [String], bufferUnitChanged: Bool)
  case duplicateParameterMutation(String)
  case parameterVerificationFailed([TraceParameterAuditEvent])
  case parameterVerificationIncomplete(expectedCount: Int, verifiedCount: Int)
  case rebootRecoveryRequired
  case rebootRecoveryIncomplete(TraceRebootRecoveryEvaluation)
}

/// Capability required to materialize capture/receive steps. Its initializer is private so a
/// caller cannot skip configuration acceptance, parameter read-back or reboot binding recovery.
public struct TraceCaptureAuthorization: Equatable, Sendable {
  public let configuration: TraceExecutableConfiguration
  public let verifiedParameterMutations: [TraceVerifiedParameterMutation]
  public let adapterCapabilities: TraceAdapterCapabilities
  public let rebootRequired: Bool

  fileprivate init(
    configuration: TraceExecutableConfiguration,
    verifiedParameterMutations: [TraceVerifiedParameterMutation],
    adapterCapabilities: TraceAdapterCapabilities,
    rebootRequired: Bool
  ) {
    self.configuration = configuration
    self.verifiedParameterMutations = verifiedParameterMutations
    self.adapterCapabilities = adapterCapabilities
    self.rebootRequired = rebootRequired
  }
}

public enum TraceCaptureGateDecision: Equatable, Sendable {
  case authorized(TraceCaptureAuthorization)
  case blocked(reason: TraceCaptureBlockReason, deviceCaptureDispatchCount: Int)

  public var deviceCaptureDispatchCount: Int {
    switch self {
    case .authorized: 0
    case .blocked(_, let count): count
    }
  }
}

public enum TraceCaptureGate {
  public static func evaluate(
    configuration: TraceExecutableConfiguration,
    parameterResults: [TraceParameterReadbackResult],
    expectedParameterMutations: [TraceAuthorizedParameterMutation] = [],
    adapterCapabilities: TraceAdapterCapabilities,
    reboot: TraceRebootCaptureGate = .notRequired
  ) -> TraceCaptureGateDecision {
    let nowUnsupported = configuration.tags.filter {
      !adapterCapabilities.supportedTags.contains($0)
    }
    let bufferUnitChanged =
      configuration.bufferValue != nil
      && configuration.confirmedBufferUnit != adapterCapabilities.confirmedBufferUnit
    guard nowUnsupported.isEmpty, !bufferUnitChanged else {
      return .blocked(
        reason: .adapterCapabilitiesChanged(
          unsupportedTags: nowUnsupported,
          bufferUnitChanged: bufferUnitChanged),
        deviceCaptureDispatchCount: 0)
    }

    var seenParameterNames: Set<String> = []
    for mutation in expectedParameterMutations
    where !seenParameterNames.insert(mutation.request.name).inserted {
      return .blocked(
        reason: .duplicateParameterMutation(mutation.request.name),
        deviceCaptureDispatchCount: 0)
    }

    let audits = parameterResults.compactMap { result -> TraceParameterAuditEvent? in
      guard case .blocked(let audit, _) = result else { return nil }
      return audit
    }
    guard audits.isEmpty else {
      return .blocked(
        reason: .parameterVerificationFailed(audits),
        deviceCaptureDispatchCount: 0)
    }
    let verified = parameterResults.compactMap(\.verifiedMutation)
    guard verified.map(\.authorization) == expectedParameterMutations else {
      return .blocked(
        reason: .parameterVerificationIncomplete(
          expectedCount: expectedParameterMutations.count,
          verifiedCount: verified.count),
        deviceCaptureDispatchCount: 0)
    }

    if !expectedParameterMutations.isEmpty,
      adapterCapabilities.parameterChangesRequireReboot,
      reboot == .notRequired
    {
      return .blocked(reason: .rebootRecoveryRequired, deviceCaptureDispatchCount: 0)
    }

    switch reboot {
    case .pending(let evaluation):
      return .blocked(
        reason: .rebootRecoveryIncomplete(evaluation),
        deviceCaptureDispatchCount: 0)
    case .notRequired:
      return .authorized(
        TraceCaptureAuthorization(
          configuration: configuration,
          verifiedParameterMutations: verified,
          adapterCapabilities: adapterCapabilities,
          rebootRequired: false))
    case .bindingDurablyConfirmed:
      return .authorized(
        TraceCaptureAuthorization(
          configuration: configuration,
          verifiedParameterMutations: verified,
          adapterCapabilities: adapterCapabilities,
          rebootRequired: true))
    }
  }
}

// MARK: - Typed workflow plan

public enum TraceWorkflowPlanError: Error, Equatable, Sendable {
  case invalidIdentifier(String)
  case bufferUnitNotConfirmed
}

private enum TraceParameterStepIdentity {
  static func catalogIndex(for name: String) -> Int {
    // Callers reach this helper only through catalog-validated names.
    TraceDebugParameterCatalog.index(of: name)!
  }

  static func snapshotID(for name: String) -> String {
    "trace-param-\(catalogIndex(for: name))-snapshot"
  }

  static func confirmationStepID(for name: String) -> String {
    "trace-param-\(catalogIndex(for: name))-confirmation-step"
  }

  static func generatedConfirmationID(for name: String) -> String {
    "trace-param-\(catalogIndex(for: name))-confirmation"
  }

  static func setStepID(for name: String) -> String {
    "trace-param-\(catalogIndex(for: name))-set"
  }

  static func restoreID(for name: String, suffix: String) -> String {
    "trace-param-\(catalogIndex(for: name))-restore-\(suffix)"
  }
}

/// Snapshot steps are their own phase because mode authorization depends on their typed result.
public struct TraceParameterSnapshotPlan: Equatable, Sendable {
  public let steps: [WorkflowStep]

  public init(steps: [WorkflowStep]) {
    self.steps = steps
  }
}

public enum TraceParameterSnapshotPlanBuilder {
  public static func makePlan(parameterNames: [String]) throws -> TraceParameterSnapshotPlan {
    var seen: Set<String> = []
    let steps = try parameterNames.map { name in
      guard TraceDebugParameterCatalog.definition(named: name) != nil else {
        throw TraceParameterPolicyError.parameterOutsideAttachmentDebugProfile(name)
      }
      guard seen.insert(name).inserted else {
        throw TraceParameterPolicyError.duplicateParameter(name)
      }
      return try WorkflowStep(
        id: TraceParameterStepIdentity.snapshotID(for: name),
        kind: .snapshotParameter,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["name": .string(name)])
    }
    return TraceParameterSnapshotPlan(steps: steps)
  }
}

/// Parameter mutation is materialized only after the snapshot phase authorizes the requested
/// modes. Capture remains a later phase until every set step has an exact read-back result.
public struct TraceParameterSetupPlan: Equatable, Sendable {
  public let steps: [WorkflowStep]

  public init(steps: [WorkflowStep]) {
    self.steps = steps
  }
}

public enum TraceParameterSetupPlanBuilder {
  public static func makePlan(
    mutations: [TraceAuthorizedParameterMutation]
  ) throws -> TraceParameterSetupPlan {
    var steps: [WorkflowStep] = []
    var seen: Set<String> = []
    for mutation in mutations {
      guard seen.insert(mutation.request.name).inserted else {
        throw TraceParameterPolicyError.duplicateParameter(mutation.request.name)
      }
      let snapshotID = TraceParameterStepIdentity.snapshotID(for: mutation.request.name)
      let confirmationID =
        mutation.persistentConfirmationID
        ?? TraceParameterStepIdentity.generatedConfirmationID(for: mutation.request.name)
      let scopeHash = sha256(
        "\(mutation.request.name)\u{0}\(mutation.request.value)"
          + "\u{0}\(mutation.request.mode.rawValue)")

      steps.append(
        try WorkflowStep(
          id: TraceParameterStepIdentity.confirmationStepID(for: mutation.request.name),
          kind: .requestConfirmation,
          declaredEffect: .hostOnly,
          declaredCancellation: .immediate,
          declaredBindingRequirement: .none,
          arguments: [
            "confirmationId": .string(confirmationID),
            "promptKey": .string("trace.parameter.mutation"),
            "riskClass": .string("deviceMutation"),
            "scopeHash": .string(scopeHash),
          ]))

      let restoreArguments: [String: JSONValue] = [
        "name": .string(mutation.request.name),
        "snapshotStepId": .string(snapshotID),
        "restorePolicy": .string(
          mutation.request.mode == .temporaryRestore
            ? "restoreKnownValue" : "persistentChangeNoRestore"),
      ]
      var compensations: [CompensationDescriptor] = []
      if mutation.request.mode == .temporaryRestore {
        for trigger in [CompensationTrigger.onFailure, .onCancel] {
          compensations.append(
            try CompensationDescriptor(
              id: TraceParameterStepIdentity.restoreID(
                for: mutation.request.name,
                suffix: trigger.rawValue),
              kind: .restoreParameter,
              declaredEffect: .deviceMutation,
              declaredCancellation: .atSafeBoundary,
              declaredBindingRequirement: .confirmedDevice,
              trigger: trigger,
              arguments: restoreArguments,
              argumentsHash: try argumentsHash(restoreArguments)))
        }
      }
      steps.append(
        try WorkflowStep(
          id: TraceParameterStepIdentity.setStepID(for: mutation.request.name),
          kind: .setParameter,
          declaredEffect: .deviceMutation,
          declaredCancellation: .atSafeBoundary,
          declaredBindingRequirement: .confirmedDevice,
          arguments: [
            "name": .string(mutation.request.name),
            "value": .string(mutation.request.value),
            "readbackPolicy": .string("required"),
          ],
          compensationDescriptors: compensations))
    }
    return TraceParameterSetupPlan(steps: steps)
  }

  private static func argumentsHash(_ arguments: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(JSONValue.object(arguments)))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Reboot is also a separate pre-capture phase. After these typed steps run, Core rebind policy
/// and durable binding persistence must close `TraceRebootCaptureGate` before capture planning.
public struct TraceRebootPlan: Equatable, Sendable {
  public let steps: [WorkflowStep]

  public init(steps: [WorkflowStep]) {
    self.steps = steps
  }
}

public enum TraceRebootPlanBuilder {
  public static func makePlan() throws -> TraceRebootPlan {
    TraceRebootPlan(steps: [
      try WorkflowStep(
        id: "trace-reboot",
        kind: .rebootDevice,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "targetMode": .string("normal"),
          "reason": .string("traceParameterProfile"),
        ]),
      try WorkflowStep(
        id: "trace-wait-disconnect",
        kind: .waitForDisconnect,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "deadlineMilliseconds": .integer(120_000),
          "reason": .string("traceParameterReboot"),
        ]),
      try WorkflowStep(
        id: "trace-wait-reconnect",
        kind: .waitForReconnect,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "deadlineMilliseconds": .integer(300_000),
          "reason": .string("traceParameterReboot"),
        ]),
    ])
  }
}

public struct TraceWorkflowPlanRequest: Equatable, Sendable {
  public let jobID: String
  public let rawArtifactID: String
  public let derivedArtifactID: String?

  public init(jobID: String, rawArtifactID: String, derivedArtifactID: String? = nil) throws {
    for identifier in [jobID, rawArtifactID] + (derivedArtifactID.map { [$0] } ?? [])
    where !Self.isSafeIdentifier(identifier) {
      throw TraceWorkflowPlanError.invalidIdentifier(identifier)
    }
    self.jobID = jobID
    self.rawArtifactID = rawArtifactID
    self.derivedArtifactID = derivedArtifactID
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
      }
  }
}

public struct TraceWorkflowPlan: Equatable, Sendable {
  public let steps: [WorkflowStep]
  public let ownedRemotePath: String
  public let hostPartialRelativePath: String

  public init(steps: [WorkflowStep], ownedRemotePath: String, hostPartialRelativePath: String) {
    self.steps = steps
    self.ownedRemotePath = ownedRemotePath
    self.hostPartialRelativePath = hostPartialRelativePath
  }
}

public enum TraceWorkflowPlanBuilder {
  public static func makePlan(
    request: TraceWorkflowPlanRequest,
    authorization: TraceCaptureAuthorization
  ) throws -> TraceWorkflowPlan {
    var steps: [WorkflowStep] = []
    var normalRestoreSteps: [WorkflowStep] = []

    for mutation in authorization.verifiedParameterMutations {
      let snapshotID = TraceParameterStepIdentity.snapshotID(
        for: mutation.authorization.request.name)
      let restoreArguments: [String: JSONValue] = [
        "name": .string(mutation.authorization.request.name),
        "snapshotStepId": .string(snapshotID),
        "restorePolicy": .string(
          mutation.authorization.request.mode == .temporaryRestore
            ? "restoreKnownValue" : "persistentChangeNoRestore"),
      ]
      if mutation.authorization.request.mode == .temporaryRestore {
        normalRestoreSteps.append(
          try WorkflowStep(
            id: TraceParameterStepIdentity.restoreID(
              for: mutation.authorization.request.name,
              suffix: "success"),
            kind: .restoreParameter,
            declaredEffect: .deviceMutation,
            declaredCancellation: .atSafeBoundary,
            declaredBindingRequirement: .confirmedDevice,
            arguments: restoreArguments))
      }
    }

    let remoteDirectory = "/data/local/tmp/arkdeck/\(request.jobID)"
    let remotePath = "\(remoteDirectory)/raw.trace"
    let partialPath = "artifacts/raw/\(request.rawArtifactID).partial"
    let captureStepID = "trace-capture"
    let stopArguments: [String: JSONValue] = [
      "captureStepId": .string(captureStepID),
      "stopPolicy": .string("adapterTypedStop"),
    ]
    var captureCompensations: [CompensationDescriptor] = []
    if authorization.adapterCapabilities.supportsTypedStop {
      for trigger in [CompensationTrigger.onFailure, .onCancel] {
        captureCompensations.append(
          try CompensationDescriptor(
            id: "trace-stop-\(trigger.rawValue)",
            kind: .stopRemoteCapture,
            declaredEffect: .deviceMutation,
            declaredCancellation: .atSafeBoundary,
            declaredBindingRequirement: .confirmedDevice,
            trigger: trigger,
            arguments: stopArguments,
            argumentsHash: try argumentsHash(stopArguments)))
      }
    }

    var captureParameters: [String: JSONValue] = [
      "tags": .array(authorization.configuration.tags.map(JSONValue.string)),
      "durationMilliseconds": .integer(Int64(authorization.configuration.durationMilliseconds)),
    ]
    if let bufferValue = authorization.configuration.bufferValue {
      guard let bufferUnit = authorization.configuration.confirmedBufferUnit else {
        throw TraceWorkflowPlanError.bufferUnitNotConfirmed
      }
      captureParameters["bufferValue"] = .integer(Int64(bufferValue))
      captureParameters["bufferUnit"] = .string(bufferUnit)
    }

    steps.append(
      try WorkflowStep(
        id: captureStepID,
        kind: .captureRemoteFile,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "catalogId": .string(TraceCatalogContract.presetCatalogID),
          "actionId": .string(authorization.configuration.presetID.rawValue),
          "parameters": .object(captureParameters),
          "artifactId": .string(request.rawArtifactID),
          "ownedRemotePath": .string(remotePath),
        ],
        compensationDescriptors: captureCompensations))
    steps.append(
      try WorkflowStep(
        id: "trace-receive",
        kind: .receiveFile,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "remotePath": .string(remotePath),
          "artifactId": .string(request.rawArtifactID),
          "localRelativePath": .string(partialPath),
        ]))
    steps.append(
      try WorkflowStep(
        id: "trace-validate",
        kind: .verifyArtifact,
        declaredEffect: .hostOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .none,
        arguments: [
          "artifactId": .string(request.rawArtifactID),
          "validationPolicy": .string("nonemptyTraceFormat"),
        ]))
    steps.append(
      try WorkflowStep(
        id: "trace-hash",
        kind: .hashFile,
        declaredEffect: .hostOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .none,
        arguments: ["artifactId": .string(request.rawArtifactID)]))
    if let derivedArtifactID = request.derivedArtifactID {
      steps.append(
        try WorkflowStep(
          id: "trace-postprocess",
          kind: .postprocessArtifact,
          declaredEffect: .hostOnly,
          declaredCancellation: .immediate,
          declaredBindingRequirement: .none,
          arguments: [
            "inputArtifactIds": .array([.string(request.rawArtifactID)]),
            "outputArtifactId": .string(derivedArtifactID),
            "processorId": .string("traceFilter"),
            "parameters": .object(["preserveFtraceHeader": .bool(true)]),
          ]))
    }
    steps.append(
      try WorkflowStep(
        id: "trace-cleanup-owned-remote",
        kind: .cleanupOwnedRemotePath,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "remotePath": .string(remotePath),
          "ownershipEvidenceId": .string(request.jobID),
        ]))
    steps.append(contentsOf: normalRestoreSteps)

    return TraceWorkflowPlan(
      steps: steps, ownedRemotePath: remotePath, hostPartialRelativePath: partialPath)
  }

  private static func argumentsHash(_ arguments: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(JSONValue.object(arguments)))
      .map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Receive isolation and atomic publication

public enum TraceHostArtifactState: Equatable, Sendable {
  case absent
  case partial(relativePath: String)
  case published(relativePath: String, sha256: String)
}

public enum TraceOwnedRemoteState: Equatable, Sendable {
  case ownedPresent
  case cleanupEligible
  case cleaned
}

public enum TraceReceiveTrackerError: Error, Equatable, Sendable {
  case receiveAlreadyStarted
  case receiveNotStarted
  case artifactNotVerified
  case cleanupNotEligible
}

public struct TraceReceiveValidation: Equatable, Sendable {
  public let byteCount: UInt64
  public let formatRecognized: Bool
  public let checksumMatches: Bool
  public let sha256: String

  public init(
    byteCount: UInt64,
    formatRecognized: Bool,
    checksumMatches: Bool,
    sha256: String
  ) {
    self.byteCount = byteCount
    self.formatRecognized = formatRecognized
    self.checksumMatches = checksumMatches
    self.sha256 = sha256
  }

  public var isValid: Bool {
    byteCount > 0 && formatRecognized && checksumMatches
      && sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression)
        == sha256.startIndex..<sha256.endIndex
  }
}

public struct TraceReceiveTracker: Equatable, Sendable {
  public private(set) var hostArtifactState: TraceHostArtifactState = .absent
  public private(set) var ownedRemoteState: TraceOwnedRemoteState = .ownedPresent
  public private(set) var diagnosticCodes: [String] = []

  public init() {}

  public mutating func begin(partialRelativePath: String) throws {
    guard hostArtifactState == .absent else {
      throw TraceReceiveTrackerError.receiveAlreadyStarted
    }
    hostArtifactState = .partial(relativePath: partialRelativePath)
  }

  public mutating func recordInterruption() throws {
    guard case .partial = hostArtifactState else {
      throw TraceReceiveTrackerError.receiveNotStarted
    }
    diagnosticCodes.append("trace-receive-interrupted")
    // The host partial remains inspectable and the owned remote file remains the retry source.
    ownedRemoteState = .ownedPresent
  }

  @discardableResult
  public mutating func verifyAndAtomicallyPublish(
    finalRelativePath: String,
    validation: TraceReceiveValidation
  ) throws -> Bool {
    guard case .partial = hostArtifactState else {
      throw TraceReceiveTrackerError.receiveNotStarted
    }
    guard validation.isValid else {
      diagnosticCodes.append("trace-receive-validation-failed")
      ownedRemoteState = .ownedPresent
      return false
    }
    hostArtifactState = .published(
      relativePath: finalRelativePath,
      sha256: validation.sha256)
    ownedRemoteState = .cleanupEligible
    return true
  }

  public func makeCleanupStep(remotePath: String, ownershipEvidenceID: String) throws
    -> WorkflowStep
  {
    guard ownedRemoteState == .cleanupEligible else {
      throw TraceReceiveTrackerError.cleanupNotEligible
    }
    return try WorkflowStep(
      id: "trace-cleanup-owned-remote",
      kind: .cleanupOwnedRemotePath,
      declaredEffect: .deviceMutation,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "remotePath": .string(remotePath),
        "ownershipEvidenceId": .string(ownershipEvidenceID),
      ])
  }

  public mutating func recordCleanupSucceeded() throws {
    guard ownedRemoteState == .cleanupEligible else {
      throw TraceReceiveTrackerError.cleanupNotEligible
    }
    ownedRemoteState = .cleaned
  }
}

// MARK: - Honest progress

public enum TraceWorkflowStage: String, CaseIterable, Codable, Equatable, Sendable {
  case configuration
  case reboot
  case waitingForDevice
  case capture
  case finalize
  case receive
  case validate
  case postprocess
  case cleanup
  case restore
}

public enum TraceProgressTotal: Equatable, Sendable {
  case unknown
  case reliable(totalBytes: UInt64)
}

public enum TraceProgressMeter: Equatable, Sendable {
  case indeterminate(elapsedMilliseconds: UInt64)
  case determinate(
    completedBytes: UInt64,
    totalBytes: UInt64,
    fractionComplete: Double,
    elapsedMilliseconds: UInt64
  )
}

public struct TraceProgressReport: Equatable, Sendable {
  public let stage: TraceWorkflowStage
  public let meter: TraceProgressMeter

  public static func make(
    stage: TraceWorkflowStage,
    completedBytes: UInt64,
    total: TraceProgressTotal,
    elapsedMilliseconds: UInt64
  ) -> TraceProgressReport {
    switch total {
    case .unknown:
      return TraceProgressReport(
        stage: stage,
        meter: .indeterminate(elapsedMilliseconds: elapsedMilliseconds))
    case .reliable(let totalBytes) where totalBytes > 0:
      let boundedCompleted = min(completedBytes, totalBytes)
      return TraceProgressReport(
        stage: stage,
        meter: .determinate(
          completedBytes: boundedCompleted,
          totalBytes: totalBytes,
          fractionComplete: Double(boundedCompleted) / Double(totalBytes),
          elapsedMilliseconds: elapsedMilliseconds))
    case .reliable:
      // A zero total is not reliable evidence of progress and cannot produce a percentage.
      return TraceProgressReport(
        stage: stage,
        meter: .indeterminate(elapsedMilliseconds: elapsedMilliseconds))
    }
  }

  public var percentage: Double? {
    guard case .determinate(_, _, let fractionComplete, _) = meter else { return nil }
    return fractionComplete * 100
  }
}

// MARK: - Artifact validation and manifest contract

public enum TraceArtifactDiagnosticCode: String, Codable, Equatable, Sendable {
  case processFailed
  case emptyTrace
  case unrecognizedTraceFormat
  case checksumUnavailableOrInvalid
}

public struct TraceArtifactDiagnostic: Equatable, Sendable {
  public let code: TraceArtifactDiagnosticCode
  public let processExitCode: Int32
  public let byteCount: UInt64
  public let summary: String
}

public struct TraceArtifactObservation: Equatable, Sendable {
  public let processExitCode: Int32
  public let byteCount: UInt64
  public let formatRecognized: Bool
  public let sha256: String?

  public init(
    processExitCode: Int32,
    byteCount: UInt64,
    formatRecognized: Bool,
    sha256: String?
  ) {
    self.processExitCode = processExitCode
    self.byteCount = byteCount
    self.formatRecognized = formatRecognized
    self.sha256 = sha256
  }
}

public enum TraceArtifactValidationResult: Equatable, Sendable {
  case valid(sha256: String, byteCount: UInt64)
  case invalid(TraceArtifactDiagnostic)

  public var permitsSucceededJobState: Bool {
    if case .valid = self { return true }
    return false
  }
}

public enum TraceArtifactValidator {
  public static func validate(_ observation: TraceArtifactObservation)
    -> TraceArtifactValidationResult
  {
    guard observation.processExitCode == 0 else {
      return diagnostic(
        .processFailed,
        observation,
        "Trace process did not exit successfully.")
    }
    guard observation.byteCount > 0 else {
      return diagnostic(
        .emptyTrace,
        observation,
        "Trace process exited 0 but the produced artifact is empty.")
    }
    guard observation.formatRecognized else {
      return diagnostic(
        .unrecognizedTraceFormat,
        observation,
        "Trace bytes do not match a registered trace format.")
    }
    guard
      let sha256 = observation.sha256,
      sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression)
        == sha256.startIndex..<sha256.endIndex
    else {
      return diagnostic(
        .checksumUnavailableOrInvalid,
        observation,
        "Trace artifact does not have a valid SHA-256 checksum.")
    }
    return .valid(sha256: sha256, byteCount: observation.byteCount)
  }

  private static func diagnostic(
    _ code: TraceArtifactDiagnosticCode,
    _ observation: TraceArtifactObservation,
    _ summary: String
  ) -> TraceArtifactValidationResult {
    .invalid(
      TraceArtifactDiagnostic(
        code: code,
        processExitCode: observation.processExitCode,
        byteCount: observation.byteCount,
        summary: summary))
  }
}

public struct TraceParameterManifestRecord: Equatable, Sendable {
  public let name: String
  public let before: TraceParameterSnapshotState
  public let after: TraceParameterSnapshotState
  public let restored: TraceParameterSnapshotState?

  public init(
    name: String,
    before: TraceParameterSnapshotState,
    after: TraceParameterSnapshotState,
    restored: TraceParameterSnapshotState?
  ) {
    self.name = name
    self.before = before
    self.after = after
    self.restored = restored
  }
}

public struct TraceFilterStatistics: Equatable, Sendable {
  public let processorID: String
  public let removedRecordCount: UInt64

  public init(processorID: String, removedRecordCount: UInt64) {
    self.processorID = processorID
    self.removedRecordCount = removedRecordCount
  }
}

/// Complete host manifest face for succeeded or partial Trace sessions. Raw bytes remain owned by
/// ArkDeckStorage; this record only references immutable artifacts and their observed metadata.
public struct TraceCaptureManifest: Equatable, Sendable {
  public let toolIdentity: String
  public let tags: [String]
  public let durationMilliseconds: Int
  public let bufferValue: Int?
  public let bufferUnit: String?
  public let parameterRecords: [TraceParameterManifestRecord]
  public let startedAt: String
  public let endedAt: String
  public let rawArtifactID: String
  public let rawSHA256: String
  public let derivedArtifactID: String?
  public let captureLogArtifactID: String
  public let filterStatistics: TraceFilterStatistics?

  public init(
    toolIdentity: String,
    tags: [String],
    durationMilliseconds: Int,
    bufferValue: Int?,
    bufferUnit: String?,
    parameterRecords: [TraceParameterManifestRecord],
    startedAt: String,
    endedAt: String,
    rawArtifactID: String,
    rawSHA256: String,
    derivedArtifactID: String?,
    captureLogArtifactID: String,
    filterStatistics: TraceFilterStatistics?
  ) {
    self.toolIdentity = toolIdentity
    self.tags = tags
    self.durationMilliseconds = durationMilliseconds
    self.bufferValue = bufferValue
    self.bufferUnit = bufferUnit
    self.parameterRecords = parameterRecords
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.rawArtifactID = rawArtifactID
    self.rawSHA256 = rawSHA256
    self.derivedArtifactID = derivedArtifactID
    self.captureLogArtifactID = captureLogArtifactID
    self.filterStatistics = filterStatistics
  }
}
