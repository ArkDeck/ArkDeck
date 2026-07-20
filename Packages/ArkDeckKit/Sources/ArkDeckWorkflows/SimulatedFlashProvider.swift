import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

public enum SimulatedFlashProviderError: Error, Equatable, Sendable {
  case emptyIdentity(String)
  case identityTooLong(String)
  case invalidIdentity(String)
  case invalidTimestamp
  case delayOutOfRange
  case sessionAlreadyStarted
  case invalidReceipt(String)
  case invalidReopenedSession(String)
}

/// A fixture-only identity. Its shape deliberately has no real binding or connect-key field.
public struct SimulatedFlashFixtureIdentity: Encodable, Equatable, Hashable, Sendable {
  public let fixtureIdentity: String
  public let syntheticDeviceIdentity: String

  public init(fixtureIdentity: String, syntheticDeviceIdentity: String) throws {
    try Self.validate(fixtureIdentity, field: "fixtureIdentity")
    try Self.validate(syntheticDeviceIdentity, field: "syntheticDeviceIdentity")
    self.fixtureIdentity = fixtureIdentity
    self.syntheticDeviceIdentity = syntheticDeviceIdentity
  }

  /// Strict JSON entry point. Keeping the type Encodable-only prevents callers from bypassing
  /// duplicate-member validation through Foundation's last-member-wins JSONDecoder behavior.
  public init(data: Data) throws {
    let object: [String: JSONValue]
    do {
      object = try SimulatedFlashStrictJSON.object(from: data)
    } catch {
      throw SimulatedFlashProviderError.invalidIdentity("invalid fixture JSON")
    }
    guard Set(object.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
      case .string(let fixtureIdentity)? = object[CodingKeys.fixtureIdentity.rawValue],
      case .string(let syntheticDeviceIdentity)? =
        object[CodingKeys.syntheticDeviceIdentity.rawValue]
    else {
      throw SimulatedFlashProviderError.invalidIdentity("unknown or missing fixture field")
    }
    try self.init(
      fixtureIdentity: fixtureIdentity,
      syntheticDeviceIdentity: syntheticDeviceIdentity)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(fixtureIdentity, forKey: .fixtureIdentity)
    try container.encode(syntheticDeviceIdentity, forKey: .syntheticDeviceIdentity)
  }

  public var syntheticTargetID: String {
    let digest = SHA256.hash(data: Data(syntheticDeviceIdentity.utf8))
    return "simulated-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func validate(_ value: String, field: String) throws {
    guard !value.isEmpty else { throw SimulatedFlashProviderError.emptyIdentity(field) }
    guard value.utf8.count <= 256 else {
      throw SimulatedFlashProviderError.identityTooLong(field)
    }
    guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      throw SimulatedFlashProviderError.invalidIdentity(field)
    }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case fixtureIdentity
    case syntheticDeviceIdentity
  }
}

public enum SimulatedFlashPhase: String, CaseIterable, Codable, Equatable, Sendable {
  case enterUpdater
  case writeSystemPartition
  case postflight
}

public enum SimulatedFlashDisconnectTiming: String, Codable, Equatable, Sendable {
  case beforeStep
  case afterStep
}

/// Closed fault vocabulary for deterministic simulation. Cancellation is supplied by Swift Task.
public enum SimulatedFlashScenario: Equatable, Sendable {
  case success(delayNanoseconds: UInt64 = 0)
  case failure(phase: SimulatedFlashPhase, delayNanoseconds: UInt64 = 0)
  case disconnect(
    phase: SimulatedFlashPhase,
    timing: SimulatedFlashDisconnectTiming,
    delayNanoseconds: UInt64 = 0
  )
  case outcomeUnknown(phase: SimulatedFlashPhase, delayNanoseconds: UInt64 = 0)

  public var identity: String {
    switch self {
    case .success(let delay):
      "success-delay-\(delay)"
    case .failure(let phase, let delay):
      "failure-\(phase.rawValue)-delay-\(delay)"
    case .disconnect(let phase, let timing, let delay):
      "disconnect-\(timing.rawValue)-\(phase.rawValue)-delay-\(delay)"
    case .outcomeUnknown(let phase, let delay):
      "outcome-unknown-\(phase.rawValue)-delay-\(delay)"
    }
  }

  fileprivate var delayNanoseconds: UInt64 {
    switch self {
    case .success(let delay), .failure(_, let delay), .disconnect(_, _, let delay),
      .outcomeUnknown(_, let delay):
      delay
    }
  }

  fileprivate func fails(at phase: SimulatedFlashPhase) -> Bool {
    if case .failure(let configured, _) = self { return configured == phase }
    return false
  }

  fileprivate func becomesUnknown(at phase: SimulatedFlashPhase) -> Bool {
    if case .outcomeUnknown(let configured, _) = self { return configured == phase }
    return false
  }

  fileprivate func disconnects(
    at phase: SimulatedFlashPhase,
    timing: SimulatedFlashDisconnectTiming
  ) -> Bool {
    if case .disconnect(let configuredPhase, let configuredTiming, _) = self {
      return configuredPhase == phase && configuredTiming == timing
    }
    return false
  }
}

public protocol SimulatedFlashVirtualDelaying: Sendable {
  func delay(nanoseconds: UInt64) async throws
}

public struct TaskSimulatedFlashVirtualDelayer: SimulatedFlashVirtualDelaying {
  public init() {}

  public func delay(nanoseconds: UInt64) async throws {
    guard nanoseconds <= UInt64(Int64.max) else {
      throw SimulatedFlashProviderError.delayOutOfRange
    }
    try Task.checkCancellation()
    if nanoseconds > 0 {
      try await Task<Never, Never>.sleep(for: .nanoseconds(Int64(nanoseconds)))
    }
    try Task.checkCancellation()
  }
}

public enum SimulatedFlashObservedOperation: Sendable {
  case journalAppend
  case sessionAuditAppend
  case manifestPublicationAttempt
  case virtualDelay
  case simulatedPhase
  case simulatedDisconnect
  case hardwareSupportVerifiedWrite
  case realConnectKeyAccepted
  case externalProcessDispatch
  case networkDispatch
  case hdcDispatch
  case deviceDispatch
  case destructiveDispatch
}

public struct SimulatedFlashIsolationSnapshot: Codable, Equatable, Sendable {
  public let journalAppendCount: Int
  public let sessionAuditAppendCount: Int
  public let manifestPublicationAttemptCount: Int
  public let virtualDelayCount: Int
  public let simulatedPhaseCount: Int
  public let simulatedDisconnectCount: Int
  public let hardwareSupportVerifiedWriteCount: Int
  public let realConnectKeyAcceptedCount: Int
  public let externalProcessDispatchCount: Int
  public let networkDispatchCount: Int
  public let hdcDispatchCount: Int
  public let deviceDispatchCount: Int
  public let destructiveDispatchCount: Int

  public var forbiddenOperationCount: Int {
    hardwareSupportVerifiedWriteCount + realConnectKeyAcceptedCount
      + externalProcessDispatchCount + networkDispatchCount + hdcDispatchCount
      + deviceDispatchCount + destructiveDispatchCount
  }
}

/// Instrumentation shared by contract tests and headless runs. It cannot dispatch any operation.
public actor SimulatedFlashIsolationMonitor {
  private var counts: [String: Int] = [:]

  public init() {}

  public func record(_ operation: SimulatedFlashObservedOperation) {
    counts[key(operation), default: 0] += 1
  }

  public func snapshot() -> SimulatedFlashIsolationSnapshot {
    SimulatedFlashIsolationSnapshot(
      journalAppendCount: value(.journalAppend),
      sessionAuditAppendCount: value(.sessionAuditAppend),
      manifestPublicationAttemptCount: value(.manifestPublicationAttempt),
      virtualDelayCount: value(.virtualDelay),
      simulatedPhaseCount: value(.simulatedPhase),
      simulatedDisconnectCount: value(.simulatedDisconnect),
      hardwareSupportVerifiedWriteCount: value(.hardwareSupportVerifiedWrite),
      realConnectKeyAcceptedCount: value(.realConnectKeyAccepted),
      externalProcessDispatchCount: value(.externalProcessDispatch),
      networkDispatchCount: value(.networkDispatch),
      hdcDispatchCount: value(.hdcDispatch),
      deviceDispatchCount: value(.deviceDispatch),
      destructiveDispatchCount: value(.destructiveDispatch)
    )
  }

  private func value(_ operation: SimulatedFlashObservedOperation) -> Int {
    counts[key(operation), default: 0]
  }

  private func key(_ operation: SimulatedFlashObservedOperation) -> String {
    String(describing: operation)
  }
}

public enum SimulatedFlashEvidenceClass: String, Codable, Sendable {
  case simulated
}

public enum SimulatedFlashTargetKind: String, Codable, Sendable {
  case synthetic
}

public enum SimulatedFlashToolchainKind: String, Codable, Sendable {
  case none
}

public struct SimulatedFlashEvidenceReceipt: Encodable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"

  public let evidenceClass: SimulatedFlashEvidenceClass
  public let executionMode: String
  public let targetKind: SimulatedFlashTargetKind
  public let connectKey: String?
  public let toolchainKind: SimulatedFlashToolchainKind
  public let fixtureIdentity: String
  public let scenarioIdentity: String
  public let hardwareSupportEligible: Bool
  public let terminalState: JobState
  public let manifestSHA256: String?

  fileprivate init(
    fixtureIdentity: String,
    scenarioIdentity: String,
    terminalState: JobState,
    manifestSHA256: String?
  ) {
    evidenceClass = .simulated
    executionMode = "simulated"
    targetKind = .synthetic
    connectKey = nil
    toolchainKind = .none
    self.fixtureIdentity = fixtureIdentity
    self.scenarioIdentity = scenarioIdentity
    hardwareSupportEligible = false
    self.terminalState = terminalState
    self.manifestSHA256 = manifestSHA256
  }

  /// Decodes the receipt only after validating the original bytes for duplicate JSON members.
  public init(data: Data) throws {
    let object: [String: JSONValue]
    do {
      object = try SimulatedFlashStrictJSON.object(from: data)
    } catch {
      throw SimulatedFlashProviderError.invalidReceipt("invalid or duplicate JSON member")
    }
    guard Set(object.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
      object[CodingKeys.schemaVersion.rawValue] == .string(Self.schemaVersion),
      object[CodingKeys.evidenceClass.rawValue]
        == .string(SimulatedFlashEvidenceClass.simulated.rawValue),
      object[CodingKeys.executionMode.rawValue] == .string("simulated"),
      object[CodingKeys.targetKind.rawValue]
        == .string(SimulatedFlashTargetKind.synthetic.rawValue),
      object[CodingKeys.connectKey.rawValue] == .null,
      object[CodingKeys.toolchainKind.rawValue]
        == .string(SimulatedFlashToolchainKind.none.rawValue),
      case .string(let decodedFixtureIdentity)? = object[CodingKeys.fixtureIdentity.rawValue],
      case .string(let decodedScenarioIdentity)? = object[CodingKeys.scenarioIdentity.rawValue],
      object[CodingKeys.hardwareSupportEligible.rawValue] == .bool(false),
      case .string(let terminalStateRaw)? = object[CodingKeys.terminalState.rawValue],
      let decodedTerminalState = JobState(rawValue: terminalStateRaw)
    else {
      throw SimulatedFlashProviderError.invalidReceipt("simulation isolation invariant failed")
    }
    try SimulatedFlashFixtureIdentity.validate(
      decodedFixtureIdentity, field: CodingKeys.fixtureIdentity.rawValue)
    try SimulatedFlashFixtureIdentity.validate(
      decodedScenarioIdentity, field: CodingKeys.scenarioIdentity.rawValue)
    let decodedManifestSHA256: String?
    switch object[CodingKeys.manifestSHA256.rawValue] {
    case .null?:
      decodedManifestSHA256 = nil
    case .string(let value)?:
      decodedManifestSHA256 = value
    default:
      throw SimulatedFlashProviderError.invalidReceipt("invalid manifest hash type")
    }
    let terminalStates: Set<JobState> = [.succeeded, .failed, .cancelled]
    guard
      terminalStates.contains(decodedTerminalState) || decodedTerminalState == .waitingForRecovery
    else {
      throw SimulatedFlashProviderError.invalidReceipt("invalid simulated receipt state")
    }
    guard
      decodedTerminalState == .waitingForRecovery
        ? decodedManifestSHA256 == nil : decodedManifestSHA256 != nil
    else {
      throw SimulatedFlashProviderError.invalidReceipt("Manifest hash/state mismatch")
    }
    if let decodedManifestSHA256,
      decodedManifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression)
        != decodedManifestSHA256.startIndex..<decodedManifestSHA256.endIndex
    {
      throw SimulatedFlashProviderError.invalidReceipt("invalid manifest hash")
    }
    evidenceClass = .simulated
    executionMode = "simulated"
    targetKind = .synthetic
    connectKey = nil
    toolchainKind = .none
    fixtureIdentity = decodedFixtureIdentity
    scenarioIdentity = decodedScenarioIdentity
    hardwareSupportEligible = false
    terminalState = decodedTerminalState
    manifestSHA256 = decodedManifestSHA256
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(evidenceClass, forKey: .evidenceClass)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(targetKind, forKey: .targetKind)
    try container.encodeNil(forKey: .connectKey)
    try container.encode(toolchainKind, forKey: .toolchainKind)
    try container.encode(fixtureIdentity, forKey: .fixtureIdentity)
    try container.encode(scenarioIdentity, forKey: .scenarioIdentity)
    try container.encode(hardwareSupportEligible, forKey: .hardwareSupportEligible)
    try container.encode(terminalState, forKey: .terminalState)
    if let manifestSHA256 {
      try container.encode(manifestSHA256, forKey: .manifestSHA256)
    } else {
      try container.encodeNil(forKey: .manifestSHA256)
    }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion
    case evidenceClass
    case executionMode
    case targetKind
    case connectKey
    case toolchainKind
    case fixtureIdentity
    case scenarioIdentity
    case hardwareSupportEligible
    case terminalState
    case manifestSHA256 = "manifestSha256"
  }
}

private enum SimulatedFlashStrictJSON {
  /// SessionAuditCodec is ArkDeckStorage's public strict-JSON boundary. Wrapping the untrusted
  /// object as audit details lets us reuse its raw-byte duplicate-member validator without first
  /// collapsing the object through JSONSerialization or JSONDecoder.
  static func object(from data: Data) throws -> [String: JSONValue] {
    var envelope = Data(
      #"{"schemaVersion":"1.0.0","recordId":"simflash-json","auditId":"simflash-json","correlationId":"simflash-json","sessionId":"simflash-json","jobId":"simflash-json","category":"outcome","timestamp":"2026-07-20T00:00:00Z","details":"#
        .utf8)
    envelope.append(data)
    envelope.append(UInt8(ascii: "}"))
    return try SessionAuditCodec.decode(envelope).details
  }
}

public enum SimulatedFlashPhaseResult: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
  case outcomeUnknown
  case notRun
}

public struct SimulatedFlashPhaseOutcome: Codable, Equatable, Sendable {
  public let phase: SimulatedFlashPhase
  public let result: SimulatedFlashPhaseResult
}

public struct SimulatedFlashRunReceipt: Sendable {
  public let evidence: SimulatedFlashEvidenceReceipt
  public let plannedSteps: [WorkflowStep]
  public let phaseOutcomes: [SimulatedFlashPhaseOutcome]
  public let isolation: SimulatedFlashIsolationSnapshot
  public let journalEventCount: Int
  public let manifest: PublishedSessionManifest?
  public let reconciliation: ReconciliationResult?
}

public struct ReopenedSimulatedFlashSession: Sendable {
  public let replay: JournalReplay
  public let manifest: SessionManifestDocument?
  public let durableReceipts: [SessionAuditRecord]
}

public struct SimulatedFlashRunRequest: Sendable {
  public let layout: SessionLayout
  public let fixture: SimulatedFlashFixtureIdentity
  public let scenario: SimulatedFlashScenario
  public let timestamp: String

  public init(
    layout: SessionLayout,
    fixture: SimulatedFlashFixtureIdentity,
    scenario: SimulatedFlashScenario,
    timestamp: String
  ) {
    self.layout = layout
    self.fixture = fixture
    self.scenario = scenario
    self.timestamp = timestamp
  }
}

public struct SimulatedFlashProvider: Sendable {
  public static let providerIdentity = "arkdeck.simulated-flash-provider"
  public static let profileVersion = "1.0.0"

  private let delayer: any SimulatedFlashVirtualDelaying
  public let monitor: SimulatedFlashIsolationMonitor

  public init(
    delayer: any SimulatedFlashVirtualDelaying = TaskSimulatedFlashVirtualDelayer(),
    monitor: SimulatedFlashIsolationMonitor = SimulatedFlashIsolationMonitor()
  ) {
    self.delayer = delayer
    self.monitor = monitor
  }

  public func makePlan(for fixture: SimulatedFlashFixtureIdentity) throws -> [WorkflowStep] {
    let imageHash = SHA256.hash(data: Data(fixture.fixtureIdentity.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return [
      try WorkflowStep(
        id: "sim-plan-enter-updater",
        kind: .enterUpdater,
        declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("simulated.enter-updater"),
          "expectedMode": .string("synthetic-updater"),
          "reconnectDeadlineMilliseconds": .integer(30_000),
        ]
      ),
      try WorkflowStep(
        id: "sim-plan-flash-system",
        kind: .flashPartition,
        declaredEffect: .destructive,
        declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("simulated.flash-partition"),
          "partition": .string("system"),
          "imageArtifactId": .string("simulated-system-image"),
          "imageSha256": .string(imageHash),
          "imageSize": .integer(1),
          "confirmationId": .string("simulated-plan-only-confirmation"),
          "safeBoundaryId": .string("simulated-write-boundary"),
        ]
      ),
      try WorkflowStep(
        id: "sim-plan-postflight",
        kind: .verifyRemoteState,
        declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("simulated-postflight"),
          "expectedState": .string("synthetic-system-ready"),
        ]
      ),
    ]
  }

  public func run(_ request: SimulatedFlashRunRequest) async throws -> SimulatedFlashRunReceipt {
    guard Self.isTimestamp(request.timestamp) else {
      throw SimulatedFlashProviderError.invalidTimestamp
    }
    guard request.scenario.delayNanoseconds <= UInt64(Int64.max) else {
      throw SimulatedFlashProviderError.delayOutOfRange
    }
    guard !Self.pathExists(request.layout.manifestURL),
      !Self.nonemptyFile(request.layout.journalURL)
    else {
      throw SimulatedFlashProviderError.sessionAlreadyStarted
    }

    let journal = try FileDurableJournal(url: request.layout.journalURL)
    let auditStore = try FileDurableSessionAuditStore(layout: request.layout)
    let plannedSteps = try makePlan(for: request.fixture)
    let envelope = try WorkflowStep(
      id: "simulated-flash-orchestration",
      kind: .finalizeSession,
      declaredEffect: .hostOnly,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .none,
      arguments: [
        "sessionId": .string(request.layout.sessionID),
        "publicationPolicy": .string("atomicAfterValidation"),
      ]
    )
    var sequence = 0

    func eventID(_ value: Int) -> String { "simflash-event-\(value)" }
    func append(_ event: JournalEvent) async throws {
      try journal.appendAndSynchronize(event)
      await monitor.record(.journalAppend)
    }
    func transition(
      from: JobState,
      to: JobState,
      reason: String,
      triggerEventID: String? = nil
    ) async throws {
      let event = try JournalEvent.stateTransition(
        eventID: eventID(sequence), sequence: sequence,
        sessionID: request.layout.sessionID, jobID: request.layout.jobID,
        timestamp: request.timestamp, from: from, to: to, reason: reason,
        triggerEventID: triggerEventID)
      sequence += 1
      try await append(event)
    }

    let created = try JournalEvent.jobCreated(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, executionMode: "simulated")
    sequence += 1
    try await append(created)

    let identitySnapshot: JSONValue = .object([
      "fixtureIdentity": .string(request.fixture.fixtureIdentity),
      "syntheticDeviceIdentity": .string(request.fixture.syntheticDeviceIdentity),
    ])
    let candidate = try JournalEvent(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, kind: .bindingCandidate,
      payload: [
        "candidateId": .string("simulated-fixture-candidate"),
        "connectKey": .null,
        "transport": .string("synthetic"),
        "identitySnapshot": identitySnapshot,
        "evidence": .array([.string("fixture-only")]),
        "ambiguity": .string("unambiguous"),
      ])
    sequence += 1
    try await append(candidate)

    let bindingValue: JSONValue = .object([
      "connectKey": .null,
      "transport": .string("synthetic"),
      "identitySnapshot": identitySnapshot,
      "evidence": .array([.string("simulated-fixture-binding")]),
      "confirmedBy": .string("simulation"),
      "channelProtection": .string("notApplicable"),
    ])
    let binding = try JournalEvent(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, kind: .bindingConfirmed, bindingRevision: 1,
      payload: [
        "candidateEventId": .string(candidate.eventID),
        "binding": bindingValue,
      ])
    sequence += 1
    try await append(binding)

    try await transition(from: .queued, to: .preflight, reason: "simulated preflight")
    try await transition(from: .preflight, to: .running, reason: "begin simulated run")

    let intent = try JournalEvent.stepIntent(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, step: envelope,
      target: JournalTarget(
        scope: "host", targetID: request.fixture.syntheticTargetID,
        connectKey: nil, identitySnapshotHash: nil),
      attempt: 1, bindingRevision: nil)
    sequence += 1
    try await append(intent)

    await monitor.record(.sessionAuditAppend)
    try auditStore.appendAndSynchronize(
      try SessionAuditRecord(
        recordID: "simflash-intent", auditID: "simflash-audit",
        correlationID: "simflash-run", sessionID: request.layout.sessionID,
        jobID: request.layout.jobID, category: .intent, timestamp: request.timestamp,
        details: [
          "executionMode": .string("simulated"),
          "evidenceClass": .string("simulated"),
          "targetKind": .string("synthetic"),
          "connectKey": .null,
          "toolchainKind": .string("none"),
          "fixtureIdentity": .string(request.fixture.fixtureIdentity),
          "scenarioIdentity": .string(request.scenario.identity),
        ]))

    var phaseOutcomes: [SimulatedFlashPhaseOutcome] = []
    var terminal: (state: JobState, journalResult: String, semanticResult: String)?
    var reconciliation: ReconciliationResult?

    phaseLoop: for phase in SimulatedFlashPhase.allCases {
      do {
        try Task.checkCancellation()
        if request.scenario.disconnects(at: phase, timing: .beforeStep) {
          try await persistDisconnect(
            phase: phase, sequence: &sequence, request: request, monitor: monitor,
            append: append)
        }
        if request.scenario.delayNanoseconds > 0 {
          await monitor.record(.virtualDelay)
          try await delayer.delay(nanoseconds: request.scenario.delayNanoseconds)
        }
        try Task.checkCancellation()
      } catch is CancellationError {
        phaseOutcomes.append(.init(phase: phase, result: .cancelled))
        terminal = (.cancelled, "cancelled", "failed")
        break phaseLoop
      }

      await monitor.record(.simulatedPhase)
      if request.scenario.becomesUnknown(at: phase) {
        phaseOutcomes.append(.init(phase: phase, result: .outcomeUnknown))
        terminal = (.waitingForRecovery, "failed", "unknown")
        break phaseLoop
      }
      if request.scenario.fails(at: phase) {
        phaseOutcomes.append(.init(phase: phase, result: .failed))
        terminal = (.failed, "failed", "failed")
        break phaseLoop
      }
      phaseOutcomes.append(.init(phase: phase, result: .succeeded))
      if request.scenario.disconnects(at: phase, timing: .afterStep) {
        try await persistDisconnect(
          phase: phase, sequence: &sequence, request: request, monitor: monitor,
          append: append)
      }
    }
    while phaseOutcomes.count < SimulatedFlashPhase.allCases.count {
      let phase = SimulatedFlashPhase.allCases[phaseOutcomes.count]
      phaseOutcomes.append(.init(phase: phase, result: .notRun))
    }
    if terminal == nil { terminal = (.succeeded, "succeeded", "succeeded") }
    let result = terminal!

    let certainty: JournalOutcomeCertainty =
      result.state == .waitingForRecovery ? .outcomeUnknown : .confirmed
    let outcome = try JournalEvent.stepOutcome(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, stepID: envelope.id, attempt: 1,
      correlatesToIntentEventID: intent.eventID, result: result.journalResult,
      outcomeCertainty: certainty,
      semanticCode: "simulated.\(result.state.rawValue)",
      summary: "fixture-only simulated flash orchestration")
    sequence += 1
    try await append(outcome)

    if result.state == .waitingForRecovery {
      try await transition(
        from: .running, to: .waitingForRecovery,
        reason: "simulated outcome is unknown", triggerEventID: outcome.eventID)
      let descriptor = UnfinishedSessionDescriptor(
        sessionID: request.layout.sessionID, jobID: request.layout.jobID,
        journalURL: request.layout.journalURL, checkpointURL: request.layout.snapshotURL)
      let scanned = try requireScannedSession(descriptor)
      let eventSource = SimulatedFlashEventIDSource()
      reconciliation = try DeterministicRecoveryReconciler(
        journal: journal,
        audit: JournalAuditContext(
          eventID: { eventSource.next() }, timestamp: { request.timestamp })
      ).reconcile(
        session: scanned,
        provider: ProviderRecoveryEvidence(
          disposition: .uncertain, restartSafe: false, safeBoundaryConfirmed: false,
          outcomeCertainty: .outcomeUnknown,
          evidence: ["simulated-provider-outcome-unknown"]),
        binding: RecoveryBindingEvidence(
          confirmed: false, revision: nil, evidence: ["synthetic-binding-not-real-authority"]))
      for _ in reconciliation?.durableEventSequences ?? [] {
        await monitor.record(.journalAppend)
      }
      let evidence = SimulatedFlashEvidenceReceipt(
        fixtureIdentity: request.fixture.fixtureIdentity,
        scenarioIdentity: request.scenario.identity,
        terminalState: .waitingForRecovery,
        manifestSHA256: nil)
      await monitor.record(.sessionAuditAppend)
      let isolation = await monitor.snapshot()
      try auditStore.appendAndSynchronize(
        try receiptAuditRecord(
          evidence: evidence, isolation: isolation, request: request,
          plannedSteps: plannedSteps))
      let replay = try DurableJournalRecovery.inspect(url: request.layout.journalURL)
      return SimulatedFlashRunReceipt(
        evidence: evidence, plannedSteps: plannedSteps, phaseOutcomes: phaseOutcomes,
        isolation: await monitor.snapshot(), journalEventCount: replay.events.count,
        manifest: nil, reconciliation: reconciliation)
    }

    if result.state == .cancelled {
      try await transition(
        from: .running, to: .cancelRequested,
        reason: "simulated cancellation requested", triggerEventID: outcome.eventID)
      try await transition(
        from: .cancelRequested, to: .cancellingAtSafeBoundary,
        reason: "simulated operation reached safe boundary", triggerEventID: outcome.eventID)
      try await transition(
        from: .cancellingAtSafeBoundary, to: .cancelled,
        reason: "simulated cancellation completed", triggerEventID: outcome.eventID)
    } else {
      try await transition(
        from: .running, to: .finalizing,
        reason: "simulated orchestration completed", triggerEventID: outcome.eventID)
      try await transition(
        from: .finalizing, to: result.state,
        reason: "persist simulated terminal result", triggerEventID: outcome.eventID)
    }

    let manifestDocument = try makeManifest(
      request: request, envelope: envelope, semanticResult: result.semanticResult,
      status: result.state.rawValue)
    await monitor.record(.manifestPublicationAttempt)
    let evidence = SimulatedFlashEvidenceReceipt(
      fixtureIdentity: request.fixture.fixtureIdentity,
      scenarioIdentity: request.scenario.identity,
      terminalState: result.state,
      manifestSHA256: manifestDocument.sha256)
    await monitor.record(.sessionAuditAppend)
    let isolation = await monitor.snapshot()
    try auditStore.appendAndSynchronize(
      try receiptAuditRecord(
        evidence: evidence, isolation: isolation, request: request,
        plannedSteps: plannedSteps))

    let finalized = try JournalEvent(
      eventID: eventID(sequence), sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, kind: .finalized,
      payload: [
        "terminalStatus": .string(result.state.rawValue),
        "manifestSha256": .string(manifestDocument.sha256),
        "outcomeCertainty": .string("confirmed"),
      ])
    try await append(finalized)
    let published = try AtomicSessionManifestPublisher(layout: request.layout).publish(
      manifestDocument)
    let replay = try DurableJournalRecovery.inspect(url: request.layout.journalURL)
    return SimulatedFlashRunReceipt(
      evidence: evidence, plannedSteps: plannedSteps, phaseOutcomes: phaseOutcomes,
      isolation: await monitor.snapshot(), journalEventCount: replay.events.count,
      manifest: published, reconciliation: nil)
  }

  public static func reopen(_ layout: SessionLayout) throws -> ReopenedSimulatedFlashSession {
    let replay = try DurableJournalRecovery.inspect(url: layout.journalURL)
    guard replay.executionMode == "simulated" else {
      throw SimulatedFlashProviderError.invalidReopenedSession("executionMode is not simulated")
    }
    let publisher = AtomicSessionManifestPublisher(layout: layout)
    let manifest: SessionManifestDocument? =
      pathExists(layout.manifestURL)
      ? try publisher.load() : nil
    guard (manifest?.executionMode ?? "simulated") == "simulated",
      (manifest?.sessionID ?? layout.sessionID) == layout.sessionID,
      (manifest?.jobID ?? layout.jobID) == layout.jobID
    else {
      throw SimulatedFlashProviderError.invalidReopenedSession("Manifest mode mismatch")
    }
    let auditStore = try FileDurableSessionAuditStore(layout: layout)
    let receipts = try auditStore.replay(correlationID: "simflash-run")
    try validateReopenedEvidence(replay: replay, manifest: manifest, receipts: receipts)
    return ReopenedSimulatedFlashSession(
      replay: replay, manifest: manifest, durableReceipts: receipts)
  }

  private func persistDisconnect(
    phase: SimulatedFlashPhase,
    sequence: inout Int,
    request: SimulatedFlashRunRequest,
    monitor: SimulatedFlashIsolationMonitor,
    append: (JournalEvent) async throws -> Void
  ) async throws {
    await monitor.record(.simulatedDisconnect)
    let waiting = try JournalEvent.stateTransition(
      eventID: "simflash-event-\(sequence)", sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, from: .running, to: .waitingForDevice,
      reason: "synthetic disconnect before/after \(phase.rawValue)")
    sequence += 1
    try await append(waiting)
    let returned = try JournalEvent.stateTransition(
      eventID: "simflash-event-\(sequence)", sequence: sequence,
      sessionID: request.layout.sessionID, jobID: request.layout.jobID,
      timestamp: request.timestamp, from: .waitingForDevice, to: .running,
      reason: "synthetic fixture reconnected", triggerEventID: waiting.eventID)
    sequence += 1
    try await append(returned)
  }

  private func makeManifest(
    request: SimulatedFlashRunRequest,
    envelope: WorkflowStep,
    semanticResult: String,
    status: String
  ) throws -> SessionManifestDocument {
    let stepDeclaration = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(envelope))
    guard case .object(var stepRecord) = stepDeclaration else {
      throw SimulatedFlashProviderError.invalidReceipt("typed Step did not encode as object")
    }
    stepRecord["argumentsHash"] = .string(
      try JournalCanonicalJSON.argumentsHash(envelope.arguments))
    stepRecord["sourceStepId"] = .null
    stepRecord["compensationTrigger"] = .null
    stepRecord["disposition"] = .string("executed")
    stepRecord["outcomeCertainty"] = .string("confirmed")
    stepRecord["bindingRevision"] = .null
    stepRecord["semanticResult"] = .string(semanticResult)

    let identity: JSONValue = .object([
      "fixtureIdentity": .string(request.fixture.fixtureIdentity),
      "syntheticDeviceIdentity": .string(request.fixture.syntheticDeviceIdentity),
    ])
    let failure: JSONValue =
      status == JobState.failed.rawValue
      ? .object([
        "stage": .string("simulatedFlash"),
        "code": .string("simulated.failure"),
        "summary": .string("configured synthetic Flash failure"),
      ]) : .null
    let manifest: JSONValue = .object([
      "schemaVersion": .string("1.0.0"),
      "appVersion": .string("ArkDeckKit-M1-008"),
      "coreSpecBaseline": .string("CORE-2.0.0"),
      "platformProfile": .string("PLATFORM-MACOS@0.1.0"),
      "sessionId": .string(request.layout.sessionID),
      "jobId": .string(request.layout.jobID),
      "status": .string(status),
      "executionMode": .string("simulated"),
      "executionAuthority": .string("standardAgent"),
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(request.timestamp),
      "completedAt": .string(request.timestamp),
      "archivedAt": .null,
      "originalTarget": .object([
        "kind": .string("synthetic"),
        "connectKey": .null,
        "transport": .string("synthetic"),
        "identitySnapshot": identity,
      ]),
      "bindingHistory": .array([
        .object([
          "revision": .integer(1),
          "connectKey": .null,
          "transport": .string("synthetic"),
          "identitySnapshot": identity,
          "evidence": .array([.string("simulated-fixture-binding")]),
          "confirmedBy": .string("simulation"),
          "channelProtection": .string("notApplicable"),
        ])
      ]),
      "toolchain": .object(["kind": .string("none")]),
      "workflow": .object([
        "kind": .string("simulatedFlash"),
        "profileVersion": .string(Self.profileVersion),
        "providerIdentity": .string(Self.providerIdentity),
        "fixtureIdentity": .string(request.fixture.fixtureIdentity),
        "scenarioIdentity": .string(request.scenario.identity),
      ]),
      "steps": .array([.object(stepRecord)]),
      "parameters": .array([]),
      "compensations": .array([]),
      "confirmations": .array([]),
      "artifacts": .array([]),
      "warnings": status == JobState.failed.rawValue
        ? .array([.string("synthetic failure retained as simulated evidence")]) : .array([]),
      "failure": failure,
      "recovery": .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try SessionManifestDocument(data: encoder.encode(manifest))
  }

  private func receiptAuditRecord(
    evidence: SimulatedFlashEvidenceReceipt,
    isolation: SimulatedFlashIsolationSnapshot,
    request: SimulatedFlashRunRequest,
    plannedSteps: [WorkflowStep]
  ) throws -> SessionAuditRecord {
    try SessionAuditRecord(
      recordID: "simflash-outcome", auditID: "simflash-audit",
      correlationID: "simflash-run", sessionID: request.layout.sessionID,
      jobID: request.layout.jobID, category: .outcome, timestamp: request.timestamp,
      details: [
        "schemaVersion": .string(SimulatedFlashEvidenceReceipt.schemaVersion),
        "evidenceClass": .string(evidence.evidenceClass.rawValue),
        "executionMode": .string(evidence.executionMode),
        "targetKind": .string(evidence.targetKind.rawValue),
        "connectKey": .null,
        "toolchainKind": .string(evidence.toolchainKind.rawValue),
        "fixtureIdentity": .string(evidence.fixtureIdentity),
        "scenarioIdentity": .string(evidence.scenarioIdentity),
        "terminalState": .string(evidence.terminalState.rawValue),
        "manifestSha256": evidence.manifestSHA256.map(JSONValue.string) ?? .null,
        "hardwareSupportEligible": .bool(false),
        "plannedStepKinds": .array(plannedSteps.map { .string($0.kind.rawValue) }),
        "isolation": .object([
          "hardwareSupportVerifiedWriteCount": .integer(
            Int64(isolation.hardwareSupportVerifiedWriteCount)),
          "realConnectKeyAcceptedCount": .integer(Int64(isolation.realConnectKeyAcceptedCount)),
          "externalProcessDispatchCount": .integer(
            Int64(isolation.externalProcessDispatchCount)),
          "networkDispatchCount": .integer(Int64(isolation.networkDispatchCount)),
          "hdcDispatchCount": .integer(Int64(isolation.hdcDispatchCount)),
          "deviceDispatchCount": .integer(Int64(isolation.deviceDispatchCount)),
          "destructiveDispatchCount": .integer(Int64(isolation.destructiveDispatchCount)),
        ]),
      ])
  }

  private static func validateReopenedEvidence(
    replay: JournalReplay,
    manifest: SessionManifestDocument?,
    receipts: [SessionAuditRecord]
  ) throws {
    let intentKeys: Set<String> = [
      "executionMode", "evidenceClass", "targetKind", "connectKey", "toolchainKind",
      "fixtureIdentity", "scenarioIdentity",
    ]
    let outcomeKeys: Set<String> = [
      "schemaVersion", "evidenceClass", "executionMode", "targetKind", "connectKey",
      "toolchainKind", "fixtureIdentity", "scenarioIdentity", "terminalState",
      "manifestSha256", "hardwareSupportEligible", "plannedStepKinds", "isolation",
    ]
    let isolation: JSONValue = .object([
      "hardwareSupportVerifiedWriteCount": .integer(0),
      "realConnectKeyAcceptedCount": .integer(0),
      "externalProcessDispatchCount": .integer(0),
      "networkDispatchCount": .integer(0),
      "hdcDispatchCount": .integer(0),
      "deviceDispatchCount": .integer(0),
      "destructiveDispatchCount": .integer(0),
    ])
    guard receipts.count == 2 else {
      throw SimulatedFlashProviderError.invalidReopenedSession(
        "durable receipt cardinality mismatch")
    }
    let intent = receipts[0]
    let outcome = receipts[1]
    guard intent.recordID == "simflash-intent", outcome.recordID == "simflash-outcome",
      intent.auditID == "simflash-audit", outcome.auditID == "simflash-audit",
      intent.correlationID == "simflash-run", outcome.correlationID == "simflash-run",
      intent.category == .intent, outcome.category == .outcome,
      intent.timestamp == outcome.timestamp,
      Set(intent.details.keys) == intentKeys,
      Set(outcome.details.keys) == outcomeKeys,
      intent.details["executionMode"] == .string("simulated"),
      intent.details["evidenceClass"] == .string("simulated"),
      intent.details["targetKind"] == .string("synthetic"),
      intent.details["connectKey"] == .null,
      intent.details["toolchainKind"] == .string("none"),
      outcome.details["schemaVersion"] == .string(SimulatedFlashEvidenceReceipt.schemaVersion),
      outcome.details["executionMode"] == .string("simulated"),
      outcome.details["evidenceClass"] == .string("simulated"),
      outcome.details["targetKind"] == .string("synthetic"),
      outcome.details["connectKey"] == .null,
      outcome.details["toolchainKind"] == .string("none"),
      outcome.details["hardwareSupportEligible"] == .bool(false),
      outcome.details["plannedStepKinds"]
        == .array([
          .string(WorkflowStepKind.enterUpdater.rawValue),
          .string(WorkflowStepKind.flashPartition.rawValue),
          .string(WorkflowStepKind.verifyRemoteState.rawValue),
        ]),
      outcome.details["isolation"] == isolation,
      case .string(let fixtureIdentity)? = outcome.details["fixtureIdentity"],
      case .string(let scenarioIdentity)? = outcome.details["scenarioIdentity"],
      intent.details["fixtureIdentity"] == .string(fixtureIdentity),
      intent.details["scenarioIdentity"] == .string(scenarioIdentity),
      case .string(let terminalStateRaw)? = outcome.details["terminalState"],
      let terminalState = JobState(rawValue: terminalStateRaw),
      replay.currentState == terminalState
    else {
      throw SimulatedFlashProviderError.invalidReopenedSession(
        "durable receipt invariant mismatch")
    }
    do {
      try SimulatedFlashFixtureIdentity.validate(fixtureIdentity, field: "fixtureIdentity")
      try SimulatedFlashFixtureIdentity.validate(scenarioIdentity, field: "scenarioIdentity")
    } catch {
      throw SimulatedFlashProviderError.invalidReopenedSession(
        "durable receipt identity is invalid")
    }

    guard
      let candidate = replay.events.first(where: { $0.kind == .bindingCandidate }),
      case .object(let journalIdentity)? = candidate.payload["identitySnapshot"],
      Set(journalIdentity.keys) == ["fixtureIdentity", "syntheticDeviceIdentity"],
      journalIdentity["fixtureIdentity"] == .string(fixtureIdentity)
    else {
      throw SimulatedFlashProviderError.invalidReopenedSession(
        "durable receipt fixture identity does not match journal")
    }

    if terminalState == .waitingForRecovery {
      guard manifest == nil, !replay.finalized,
        outcome.details["manifestSha256"] == .null
      else {
        throw SimulatedFlashProviderError.invalidReopenedSession(
          "recoverable receipt state mismatch")
      }
      return
    }

    let confirmedTerminalStates: Set<JobState> = [.succeeded, .failed, .cancelled]
    guard confirmedTerminalStates.contains(terminalState), replay.finalized,
      let manifest,
      manifest.status == terminalStateRaw,
      outcome.details["manifestSha256"] == .string(manifest.sha256),
      case .object(let manifestRoot) = try JSONDecoder().decode(
        JSONValue.self, from: manifest.canonicalData),
      case .object(let workflow)? = manifestRoot["workflow"],
      Set(workflow.keys) == [
        "kind", "profileVersion", "providerIdentity", "fixtureIdentity", "scenarioIdentity",
      ],
      workflow["kind"] == .string("simulatedFlash"),
      workflow["profileVersion"] == .string(Self.profileVersion),
      workflow["providerIdentity"] == .string(Self.providerIdentity),
      workflow["fixtureIdentity"] == .string(fixtureIdentity),
      workflow["scenarioIdentity"] == .string(scenarioIdentity),
      case .object(let target)? = manifestRoot["originalTarget"],
      case .object(let manifestIdentity)? = target["identitySnapshot"],
      manifestIdentity == journalIdentity
    else {
      throw SimulatedFlashProviderError.invalidReopenedSession(
        "terminal receipt does not match journal and Manifest")
    }
  }

  private func requireScannedSession(
    _ descriptor: UnfinishedSessionDescriptor
  ) throws -> ScannedRecoverySession {
    guard let scanned = try SessionRecoveryScanner().scan(descriptor) else {
      throw SimulatedFlashProviderError.invalidReopenedSession("recovery scan returned no session")
    }
    return scanned
  }

  private static func pathExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private static func nonemptyFile(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else { return false }
    return size.intValue > 0
  }

  private static func isTimestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }
}

private final class SimulatedFlashEventIDSource: @unchecked Sendable {
  private let lock = NSLock()
  private var nextValue = 0

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    let value = nextValue
    nextValue += 1
    return "simflash-reconcile-\(value)"
  }
}
