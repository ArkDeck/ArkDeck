import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Foundation

public struct RockchipFlashExecutionRequest: Sendable, Equatable {
  public let authorizationID: String
  public let archiveURL: URL
  public let targetLocationSelector: String

  public init(
    authorizationID: String,
    archiveURL: URL,
    targetLocationSelector: String
  ) throws {
    guard RockchipStandingAuthorizationIdentifier.isValid(authorizationID) else {
      throw RockchipFlashExecutionError.invalidRequest("authorizationId")
    }
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/") else {
      throw RockchipFlashExecutionError.invalidRequest("archiveURL")
    }
    guard !targetLocationSelector.isEmpty,
      targetLocationSelector.utf8.allSatisfy({ (48...57).contains($0) }),
      targetLocationSelector == "0" || targetLocationSelector.first != "0"
    else { throw RockchipFlashExecutionError.invalidRequest("targetLocationSelector") }
    self.authorizationID = authorizationID
    self.archiveURL = archiveURL.standardizedFileURL
    self.targetLocationSelector = targetLocationSelector
  }
}

public enum RockchipFlashExecutionStatus: String, Sendable, Equatable {
  case succeeded
  case waitingForRecovery
}

public enum RockchipExecutionEvidenceClass: String, Sendable, Equatable {
  case production
  case contractFake
}

public struct RockchipFlashExecutionResult: Sendable, Equatable {
  public let sessionID: String
  public let jobID: String
  public let status: RockchipFlashExecutionStatus
  public let evidenceClass: RockchipExecutionEvidenceClass
  public let manifestURL: URL?
}

public enum RockchipFlashExecutionError: Error, Sendable, Equatable, LocalizedError {
  case invalidRequest(String)
  case productionConfigurationUnavailable(String)
  case admissionRejected(String)
  case authorizationGateRejected(String)
  case authorizationConsumptionRejected(String)
  case storageRejected(String)
  case stagingRejected(String)
  case loweringRejected(String)
  case executableIdentityDrift
  case persistenceRejected(String)
  case semanticFailure(stepID: String, detail: String)
  case recoveryRequired(stepID: String, detail: String)
  case postflightMismatch
  case cancelledAtSafeBoundary

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let field): "invalid execution request: \(field)"
    case .productionConfigurationUnavailable(let detail):
      "product execution configuration unavailable: \(detail)"
    case .admissionRejected(let detail): "trusted admission rejected: \(detail)"
    case .authorizationGateRejected(let detail): "authorization gate rejected: \(detail)"
    case .authorizationConsumptionRejected(let detail):
      "one-shot authorization consumption rejected: \(detail)"
    case .storageRejected(let detail): "storage admission rejected: \(detail)"
    case .stagingRejected(let detail): "archive staging rejected: \(detail)"
    case .loweringRejected(let detail): "typed lowering rejected: \(detail)"
    case .executableIdentityDrift: "executable descriptor identity drifted from admission"
    case .persistenceRejected(let detail): "durable persistence rejected: \(detail)"
    case .semanticFailure(let stepID, let detail): "step \(stepID) failed: \(detail)"
    case .recoveryRequired(let stepID, let detail):
      "step \(stepID) has an unknown destructive outcome: \(detail)"
    case .postflightMismatch: "postflight identity or reconnect observation mismatched"
    case .cancelledAtSafeBoundary: "execution cancelled at a critical-write safe boundary"
    }
  }
}

struct RockchipExecutionAdmission: @unchecked Sendable {
  enum Backing: @unchecked Sendable {
    case production(RockchipAuthorizedAgentAdmission)
    case contractFake
  }

  let backing: Backing
  let plan: RockchipFlashPlan
  let authorizationReference: AuthorizationReference
  let usageReservationID: String
  let targetID: String
  let bindingRevision: Int
  let targetDigestSHA256: String
  let serialDigestSHA256: String
  let usbTopology: String
  let executableIdentity: ProcessExecutableIdentityReceipt
  let evidenceClass: RockchipExecutionEvidenceClass
}

protocol RockchipExecutionAdmissionPort: Sendable {
  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID: String,
    jobID: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission
  func authorizeAndConsume(_ admission: RockchipExecutionAdmission) async throws
  func closeUsage(
    admission: RockchipExecutionAdmission,
    status: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs: [String]
  ) throws
}

struct RockchipExecutionAttempt: Sendable {
  let execution: ProcessExecutionResult
  let semantic: RockchipCommandSemanticResult
  let executableIdentity: ProcessExecutableIdentityReceipt
}

final class RockchipPreparedCommand: @unchecked Sendable {
  let executableIdentity: ProcessExecutableIdentityReceipt
  private let operation: @Sendable () async throws -> RockchipExecutionAttempt

  init(
    executableIdentity: ProcessExecutableIdentityReceipt,
    operation: @escaping @Sendable () async throws -> RockchipExecutionAttempt
  ) {
    self.executableIdentity = executableIdentity
    self.operation = operation
  }

  func launch(criticalNonInterruptible: Bool) async throws -> RockchipExecutionAttempt {
    guard criticalNonInterruptible else { return try await operation() }
    // A parent cancellation must never reach FoundationProcessExecutor while a wlx child is in
    // flight. The detached task reaches the semantic boundary; the caller then blocks all later
    // steps through RockchipCriticalWriteBoundary.
    return try await Task.detached(priority: nil, operation: operation).value
  }
}

protocol RockchipExecutionProcessPort: Sendable {
  func prepare(
    command: RockchipClosedCommand,
    admissionIdentity: ProcessExecutableIdentityReceipt
  ) throws -> RockchipPreparedCommand
}

struct RockchipPostflightReceipt: Sendable, Equatable {
  let connected: Bool
  let serialDigestSHA256: String
  let usbTopology: String
}

protocol RockchipExecutionPostflightPort: Sendable {
  func probe(expectedTopology: String) async throws -> RockchipPostflightReceipt
}

protocol RockchipPowerActivityLease: Sendable {
  func end()
}

protocol RockchipPowerActivityPort: Sendable {
  func acquire(reason: String) throws -> any RockchipPowerActivityLease
}

enum RockchipExecutionLifecycleEventKind: Sendable, Equatable {
  case sleep
  case wake
}

struct RockchipExecutionLifecycleEvent: Sendable, Equatable {
  let eventID: String
  let kind: RockchipExecutionLifecycleEventKind
  let sleepEventID: String?
  let elapsedDurationNanoseconds: Int64
  let activeDurationNanoseconds: Int64
}

protocol RockchipExecutionLifecyclePort: Sendable {
  func start(
    handler: @escaping @Sendable (RockchipExecutionLifecycleEvent) -> Void
  ) throws
  func stop()
}

private final class RockchipInertExecutionLifecyclePort: @unchecked Sendable,
  RockchipExecutionLifecyclePort
{
  func start(handler _: @escaping @Sendable (RockchipExecutionLifecycleEvent) -> Void) throws {}
  func stop() {}
}

protocol RockchipExecutionPersistence: Sendable {
  var sessionRoot: URL { get }
  func appendJobCreated(admission: RockchipExecutionAdmission) throws
  func appendRunning() throws
  func appendIntent(
    step: WorkflowStep,
    admission: RockchipExecutionAdmission,
    isDestructive: Bool
  ) throws -> String
  func appendOutcome(
    step: WorkflowStep,
    intentEventID: String,
    admission: RockchipExecutionAdmission,
    result: String,
    certainty: JournalOutcomeCertainty,
    semanticCode: String,
    execution: ProcessExecutionResult?
  ) throws
  func appendWaitingForRecovery(stepID: String, reason: String) throws
  func appendLifecycleEvent(_ event: RockchipExecutionLifecycleEvent) throws
  func finishSucceeded(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) async throws -> URL
}

struct RockchipFlashExecutionDependencies: Sendable {
  let admission: any RockchipExecutionAdmissionPort
  let process: any RockchipExecutionProcessPort
  let postflight: any RockchipExecutionPostflightPort
  let power: any RockchipPowerActivityPort
  let lifecycle: any RockchipExecutionLifecyclePort
  let makePersistence:
    @Sendable (String, String, RockchipFlashPlan) async throws -> any RockchipExecutionPersistence
  let stage: @Sendable (URL, URL, RockchipFlashProfile) throws -> [String: StagedRockchipImage]
  let profile: RockchipFlashProfile
  let makeID: @Sendable (String) -> String

  init(
    admission: any RockchipExecutionAdmissionPort,
    process: any RockchipExecutionProcessPort,
    postflight: any RockchipExecutionPostflightPort,
    power: any RockchipPowerActivityPort,
    makePersistence:
      @escaping @Sendable (String, String, RockchipFlashPlan) async throws
      -> any RockchipExecutionPersistence,
    stage:
      @escaping @Sendable (URL, URL, RockchipFlashProfile) throws
      -> [String: StagedRockchipImage] = { archive, root, profile in
        try RockchipFlashExecutionStager.stage(
          archiveURL: archive, sessionRoot: root, profile: profile)
      },
    profile: RockchipFlashProfile = .dayu200,
    lifecycle: any RockchipExecutionLifecyclePort = RockchipInertExecutionLifecyclePort(),
    makeID: @escaping @Sendable (String) -> String = { prefix in
      "\(prefix)-\(UUID().uuidString.lowercased())"
    }
  ) {
    self.admission = admission
    self.process = process
    self.postflight = postflight
    self.power = power
    self.lifecycle = lifecycle
    self.makePersistence = makePersistence
    self.stage = stage
    self.profile = profile
    self.makeID = makeID
  }
}

private final class RockchipLifecycleInterruptionGate: @unchecked Sendable {
  private let lock = NSLock()
  private let persistence: any RockchipExecutionPersistence
  private var firstEvent: RockchipExecutionLifecycleEvent?
  private var persistenceFailure: String?

  init(persistence: any RockchipExecutionPersistence) {
    self.persistence = persistence
  }

  func record(_ event: RockchipExecutionLifecycleEvent) {
    lock.lock()
    defer { lock.unlock() }
    if firstEvent == nil { firstEvent = event }
    do {
      try persistence.appendLifecycleEvent(event)
    } catch {
      if persistenceFailure == nil { persistenceFailure = String(describing: error) }
    }
  }

  var interruptionDetail: String? {
    lock.lock()
    defer { lock.unlock() }
    guard let firstEvent else { return nil }
    let event = firstEvent.kind == .sleep ? "sleep" : "wake"
    if let persistenceFailure {
      return "\(event) journal failure: \(persistenceFailure)"
    }
    return "system \(event) observed"
  }
}

actor RockchipFlashExecutor {
  private let dependencies: RockchipFlashExecutionDependencies

  init(dependencies: RockchipFlashExecutionDependencies) {
    self.dependencies = dependencies
  }

  func execute(_ request: RockchipFlashExecutionRequest) async throws
    -> RockchipFlashExecutionResult
  {
    let sessionID = dependencies.makeID("rockchip-session")
    let jobID = dependencies.makeID("rockchip-job")
    let targetID = dependencies.makeID("rockchip-target")
    let admission: RockchipExecutionAdmission
    do {
      admission = try await dependencies.admission.admit(
        request: request, sessionID: sessionID, jobID: jobID, targetID: targetID)
    } catch {
      throw RockchipFlashExecutionError.admissionRejected(String(describing: error))
    }
    guard admission.plan.executionMode == .execute,
      admission.targetID == targetID,
      admission.usbTopology == request.targetLocationSelector
    else { throw RockchipFlashExecutionError.admissionRejected("fact correlation drift") }

    let persistence: any RockchipExecutionPersistence
    do {
      persistence = try await dependencies.makePersistence(sessionID, jobID, admission.plan)
      try persistence.appendJobCreated(admission: admission)
    } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.storageRejected(String(describing: error))
    }

    do { try await dependencies.admission.authorizeAndConsume(admission) } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.authorizationConsumptionRejected(String(describing: error))
    }

    let stagedImages: [String: StagedRockchipImage]
    do {
      stagedImages = try dependencies.stage(
        request.archiveURL, persistence.sessionRoot, dependencies.profile)
    } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.stagingRejected(String(describing: error))
    }
    let commands: [RockchipClosedCommand]
    do {
      commands = try RockchipFlashExecutionLowering.commands(
        plan: admission.plan, stagedImages: stagedImages)
      try persistence.appendRunning()
    } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.loweringRejected(String(describing: error))
    }

    let powerLease: any RockchipPowerActivityLease
    do { powerLease = try dependencies.power.acquire(reason: "Authorized Rockchip flash") } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.storageRejected("idle-sleep activity unavailable")
    }
    defer { powerLease.end() }

    let lifecycleGate = RockchipLifecycleInterruptionGate(persistence: persistence)
    do {
      try dependencies.lifecycle.start { lifecycleGate.record($0) }
    } catch {
      try? dependencies.admission.closeUsage(
        admission: admission, status: .failed, destructiveIntentEventIDs: [])
      throw RockchipFlashExecutionError.storageRejected(
        "sleep/wake observer unavailable: \(error)")
    }
    defer { dependencies.lifecycle.stop() }

    let criticalBoundary = RockchipCriticalWriteBoundary()
    var destructiveIntentIDs: [String] = []
    for command in commands {
      try failIfLifecycleInterrupted(
        lifecycleGate, stepID: command.step.id, persistence: persistence,
        admission: admission, destructiveIntentIDs: destructiveIntentIDs)
      if Task.isCancelled {
        _ = await criticalBoundary.requestExit(
          reason: "task cancellation", timestamp: ISO8601DateFormatter().string(from: Date()))
        try? persistence.appendWaitingForRecovery(
          stepID: command.step.id, reason: "cancelled-before-next-step")
        try? dependencies.admission.closeUsage(
          admission: admission, status: .cancelled,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.cancelledAtSafeBoundary
      }
      if case .writePartition(_, _, let image) = command {
        do { try image.revalidate() } catch {
          try? dependencies.admission.closeUsage(
            admission: admission, status: .failed,
            destructiveIntentEventIDs: destructiveIntentIDs)
          throw RockchipFlashExecutionError.stagingRejected(String(describing: error))
        }
      }
      let prepared: RockchipPreparedCommand
      do {
        prepared = try dependencies.process.prepare(
          command: command, admissionIdentity: admission.executableIdentity)
      } catch {
        try? dependencies.admission.closeUsage(
          admission: admission, status: .failed,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.executableIdentityDrift
      }
      guard Self.sameDescriptor(prepared.executableIdentity, admission.executableIdentity) else {
        try? dependencies.admission.closeUsage(
          admission: admission, status: .failed,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.executableIdentityDrift
      }
      if command.isCriticalWrite {
        do { try await criticalBoundary.beginCriticalWrite(stepID: command.step.id) } catch {
          throw RockchipFlashExecutionError.cancelledAtSafeBoundary
        }
      }
      let intentID: String
      do {
        intentID = try persistence.appendIntent(
          step: command.step, admission: admission,
          isDestructive: command.step.effect == .destructive)
      } catch {
        try? dependencies.admission.closeUsage(
          admission: admission, status: .failed,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.persistenceRejected(String(describing: error))
      }
      if command.step.effect == .destructive { destructiveIntentIDs.append(intentID) }
      let attempt: RockchipExecutionAttempt
      do {
        attempt = try await prepared.launch(criticalNonInterruptible: command.isCriticalWrite)
      } catch {
        try? persistence.appendWaitingForRecovery(
          stepID: command.step.id, reason: "launch-or-outcome-unknown")
        try? dependencies.admission.closeUsage(
          admission: admission, status: .outcomeUnknown,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.recoveryRequired(
          stepID: command.step.id, detail: String(describing: error))
      }
      guard Self.sameDescriptor(attempt.executableIdentity, admission.executableIdentity) else {
        try? persistence.appendWaitingForRecovery(
          stepID: command.step.id, reason: "executable-identity-drift")
        try? dependencies.admission.closeUsage(
          admission: admission, status: .outcomeUnknown,
          destructiveIntentEventIDs: destructiveIntentIDs)
        throw RockchipFlashExecutionError.recoveryRequired(
          stepID: command.step.id, detail: "executable identity drift")
      }
      switch attempt.semantic {
      case .succeeded:
        do {
          try persistence.appendOutcome(
            step: command.step, intentEventID: intentID, admission: admission,
            result: "succeeded", certainty: .confirmed, semanticCode: "rockchip.marker.confirmed",
            execution: attempt.execution)
        } catch {
          try? persistence.appendWaitingForRecovery(
            stepID: command.step.id, reason: "outcome-durability-unknown")
          try? dependencies.admission.closeUsage(
            admission: admission, status: .outcomeUnknown,
            destructiveIntentEventIDs: destructiveIntentIDs)
          throw RockchipFlashExecutionError.recoveryRequired(
            stepID: command.step.id, detail: "outcome durability unknown")
        }
      case .failed(let failure):
        let certainty: JournalOutcomeCertainty =
          command.isCriticalWrite ? .outcomeUnknown : .confirmed
        try? persistence.appendOutcome(
          step: command.step, intentEventID: intentID, admission: admission,
          result: "failed", certainty: certainty,
          semanticCode: "rockchip.semantic.rejected", execution: attempt.execution)
        if command.isCriticalWrite {
          try? persistence.appendWaitingForRecovery(
            stepID: command.step.id, reason: String(describing: failure))
          try? dependencies.admission.closeUsage(
            admission: admission, status: .outcomeUnknown,
            destructiveIntentEventIDs: destructiveIntentIDs)
          throw RockchipFlashExecutionError.recoveryRequired(
            stepID: command.step.id, detail: String(describing: failure))
        }
        try? dependencies.admission.closeUsage(
          admission: admission, status: .failed,
          destructiveIntentEventIDs: destructiveIntentIDs)
        try? persistence.appendWaitingForRecovery(
          stepID: command.step.id, reason: "semantic-preflight-failure")
        throw RockchipFlashExecutionError.semanticFailure(
          stepID: command.step.id, detail: String(describing: failure))
      }
      if command.isCriticalWrite {
        _ = try await criticalBoundary.reachSafeBoundary(stepID: command.step.id)
        let mayStartNextStep = await criticalBoundary.mayStartNextStep()
        if Task.isCancelled || !mayStartNextStep {
          try? persistence.appendWaitingForRecovery(
            stepID: command.step.id, reason: "cancelled-at-safe-boundary")
          try? dependencies.admission.closeUsage(
            admission: admission, status: .cancelled,
            destructiveIntentEventIDs: destructiveIntentIDs)
          throw RockchipFlashExecutionError.cancelledAtSafeBoundary
        }
      }
      try failIfLifecycleInterrupted(
        lifecycleGate, stepID: command.step.id, persistence: persistence,
        admission: admission, destructiveIntentIDs: destructiveIntentIDs)
    }

    guard
      let postflightStep = admission.plan.steps.first(where: {
        $0.kind == .verifyRemoteState
          && $0.arguments["probeId"] == .string("rockusb-postflight-list-targets")
      })
    else { throw RockchipFlashExecutionError.loweringRejected("postflight step missing") }
    try failIfLifecycleInterrupted(
      lifecycleGate, stepID: postflightStep.id, persistence: persistence,
      admission: admission, destructiveIntentIDs: destructiveIntentIDs)
    let postflightIntent: String
    do {
      postflightIntent = try persistence.appendIntent(
        step: postflightStep, admission: admission, isDestructive: false)
    } catch {
      try? persistence.appendWaitingForRecovery(
        stepID: postflightStep.id, reason: "postflight-intent-durability-failure")
      try? dependencies.admission.closeUsage(
        admission: admission, status: .outcomeUnknown,
        destructiveIntentEventIDs: destructiveIntentIDs)
      throw RockchipFlashExecutionError.recoveryRequired(
        stepID: postflightStep.id, detail: "postflight intent durability failure")
    }
    let postflight: RockchipPostflightReceipt
    do {
      postflight = try await dependencies.postflight.probe(expectedTopology: admission.usbTopology)
    } catch {
      try? persistence.appendWaitingForRecovery(
        stepID: postflightStep.id, reason: "postflight-unavailable")
      try? dependencies.admission.closeUsage(
        admission: admission, status: .outcomeUnknown,
        destructiveIntentEventIDs: destructiveIntentIDs)
      throw RockchipFlashExecutionError.postflightMismatch
    }
    try failIfLifecycleInterrupted(
      lifecycleGate, stepID: postflightStep.id, persistence: persistence,
      admission: admission, destructiveIntentIDs: destructiveIntentIDs)
    guard postflight.connected,
      postflight.serialDigestSHA256 == admission.serialDigestSHA256,
      postflight.usbTopology == admission.usbTopology
    else {
      try? persistence.appendOutcome(
        step: postflightStep, intentEventID: postflightIntent, admission: admission,
        result: "failed", certainty: .outcomeUnknown,
        semanticCode: "rockchip.postflight.mismatch", execution: nil)
      try? persistence.appendWaitingForRecovery(
        stepID: postflightStep.id, reason: "postflight-identity-mismatch")
      try? dependencies.admission.closeUsage(
        admission: admission, status: .outcomeUnknown,
        destructiveIntentEventIDs: destructiveIntentIDs)
      throw RockchipFlashExecutionError.postflightMismatch
    }
    try persistence.appendOutcome(
      step: postflightStep, intentEventID: postflightIntent, admission: admission,
      result: "succeeded", certainty: .confirmed,
      semanticCode: "rockchip.postflight.connected", execution: nil)
    dependencies.lifecycle.stop()
    let manifestURL: URL
    do {
      manifestURL = try await persistence.finishSucceeded(
        plan: admission.plan, admission: admission,
        destructiveIntentEventIDs: destructiveIntentIDs)
      try dependencies.admission.closeUsage(
        admission: admission, status: .succeeded,
        destructiveIntentEventIDs: destructiveIntentIDs)
    } catch {
      try? persistence.appendWaitingForRecovery(
        stepID: postflightStep.id, reason: "terminal-publication-incomplete")
      try? dependencies.admission.closeUsage(
        admission: admission, status: .outcomeUnknown,
        destructiveIntentEventIDs: destructiveIntentIDs)
      throw RockchipFlashExecutionError.recoveryRequired(
        stepID: postflightStep.id, detail: "terminal publication incomplete: \(error)")
    }
    return RockchipFlashExecutionResult(
      sessionID: sessionID, jobID: jobID, status: .succeeded,
      evidenceClass: admission.evidenceClass, manifestURL: manifestURL)
  }

  private static func sameDescriptor(
    _ lhs: ProcessExecutableIdentityReceipt,
    _ rhs: ProcessExecutableIdentityReceipt
  ) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.fileSize == rhs.fileSize
      && lhs.mode == rhs.mode && lhs.sha256 == rhs.sha256
  }

  private func failIfLifecycleInterrupted(
    _ gate: RockchipLifecycleInterruptionGate,
    stepID: String,
    persistence: any RockchipExecutionPersistence,
    admission: RockchipExecutionAdmission,
    destructiveIntentIDs: [String]
  ) throws {
    guard let detail = gate.interruptionDetail else { return }
    try? persistence.appendWaitingForRecovery(stepID: stepID, reason: detail)
    try? dependencies.admission.closeUsage(
      admission: admission, status: .outcomeUnknown,
      destructiveIntentEventIDs: destructiveIntentIDs)
    throw RockchipFlashExecutionError.recoveryRequired(stepID: stepID, detail: detail)
  }
}
