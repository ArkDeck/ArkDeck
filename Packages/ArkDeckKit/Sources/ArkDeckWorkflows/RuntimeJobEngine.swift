// Durable Runtime Job Engine (CHG-2026-047, T08).
//
// Reuses the proven primitives - JobStateMachine's transition graph via the
// journal's own cross-validation, FileDurableJournal (F_FULLFSYNC, torn-tail
// semantics), DurableJournalRecovery replay and DeviceMutationLaneCoordinator
// - and adds the three missing pieces: a durable idempotency ledger, the
// WriteAheadIntentGate as the production dispatch path, and restart
// recovery that never blind-redispatches. Unknown outcomes park in
// waitingForRecovery; there is no automatic replay anywhere in this file.

import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

public enum RuntimeJobEngineError: Error, Equatable, Sendable {
  case rejected(RuntimeOperationErrorCode, String)
  case idempotencyConflict(String)
  case jobNotFound(String)
  case jobNotRunnable(String)
  case internalFailure(String)
}

/// Presented status: the persisted JobStateMachine state plus the
/// waitingForHuman view (open human action against a non-terminal job).
/// The persisted 18-state graph is unchanged.
public struct RuntimeJobStatus: Sendable, Equatable, Codable {
  public let jobID: String
  public let operationReference: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let timeline: [String]
}

public struct RuntimeJobAcceptance: Sendable, Equatable {
  public let jobID: String
  public let deduplicated: Bool
}

/// Dispatch port: how a lowered process plan actually runs. Production
/// binds the descriptor-verifying executor (MU-3); tests inject fakes,
/// including crash and hang shapes.
public protocol RuntimeProcessDispatching: Sendable {
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt
}

public enum RuntimeDispatchFailure: Error, Equatable, Sendable {
  /// The dispatcher cannot say whether the external effect happened.
  case outcomeUnknown(String)
  case failed(String)
}

// MARK: - Durable idempotency ledger

struct IdempotencyEntry: Codable, Equatable {
  let idempotencyKey: String
  let jobID: String
  let requestFingerprintSHA256: String
}

private struct IdempotencyDocument: Codable, Equatable {
  var schemaVersion: String
  var entries: [IdempotencyEntry]
}

final class RuntimeIdempotencyLedger: @unchecked Sendable {
  private let url: URL
  private let queue = DispatchQueue(label: "arkdeck.idempotency-ledger")

  init(url: URL) {
    self.url = url
  }

  enum Verdict: Equatable {
    case new
    case duplicate(jobID: String)
    case conflict
  }

  func admit(key: String, jobID: String, fingerprint: String) throws -> Verdict {
    try queue.sync {
      var document = try load()
      if let existing = document.entries.first(where: { $0.idempotencyKey == key }) {
        return existing.requestFingerprintSHA256 == fingerprint
          ? .duplicate(jobID: existing.jobID) : .conflict
      }
      document.entries.append(
        IdempotencyEntry(idempotencyKey: key, jobID: jobID, requestFingerprintSHA256: fingerprint))
      try persist(document)
      return .new
    }
  }

  private func load() throws -> IdempotencyDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return IdempotencyDocument(schemaVersion: "1.0.0", entries: [])
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(IdempotencyDocument.self, from: data)
  }

  private func persist(_ document: IdempotencyDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(document)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".idempotency.tmp.\(getpid())")
    try data.write(to: temporary, options: [])
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }
}

// MARK: - Engine

public actor RuntimeJobEngine {
  public struct Configuration: Sendable {
    public let stateDirectory: URL
    public let defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy

    public init(
      stateDirectory: URL,
      defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy = RuntimeDefaultReadOnlyPolicy()
    ) {
      self.stateDirectory = stateDirectory
      self.defaultReadOnlyPolicy = defaultReadOnlyPolicy
    }
  }

  private struct JobRuntime {
    var record: RuntimeJobRecord
    var journal: FileDurableJournal
    var nextSequence: Int
  }

  private let configuration: Configuration
  private let providers: DeviceProviderRegistry
  private let dispatcher: any RuntimeProcessDispatching
  private let capabilityStore: RuntimeCapabilityStore
  private let mutationLane = DeviceMutationLaneCoordinator()
  private let idempotencyLedger: RuntimeIdempotencyLedger
  private let nowUTC: @Sendable () -> String
  private var jobs: [String: JobRuntime] = [:]
  private var cancellationRequests: Set<String> = []

  public init(
    configuration: Configuration,
    providers: DeviceProviderRegistry,
    dispatcher: any RuntimeProcessDispatching,
    capabilityStore: RuntimeCapabilityStore,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.configuration = configuration
    self.providers = providers
    self.dispatcher = dispatcher
    self.capabilityStore = capabilityStore
    self.nowUTC = nowUTC
    try FileManager.default.createDirectory(
      at: configuration.stateDirectory.appendingPathComponent("jobs", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.idempotencyLedger = RuntimeIdempotencyLedger(
      url: configuration.stateDirectory.appendingPathComponent("idempotency.json"))
  }

  // MARK: Submit

  public func submit(_ requestData: Data) async throws -> RuntimeJobAcceptance {
    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationCodec.decodeRequest(requestData)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw RuntimeJobEngineError.rejected(rejection.code, rejection.message)
    }
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        id: request.operation.id, version: request.operation.version)
    else {
      throw RuntimeJobEngineError.rejected(
        .unknownOperation, "operation \(request.operation.reference) is not in the catalog")
    }
    try validateInputs(request.inputs, against: descriptor)

    let effectiveEffect = descriptor.minimumEffect
    try await authorize(request: request, descriptor: descriptor, effect: effectiveEffect)

    let jobID = "job-\(UUID().uuidString.lowercased())"
    let fingerprint = Self.fingerprint(of: requestData)
    switch try idempotencyLedger.admit(
      key: request.idempotencyKey, jobID: jobID, fingerprint: fingerprint)
    {
    case .duplicate(let existingJobID):
      return RuntimeJobAcceptance(jobID: existingJobID, deduplicated: true)
    case .conflict:
      throw RuntimeJobEngineError.idempotencyConflict(
        "idempotency key reuse with a different request")
    case .new:
      break
    }

    let jobDirectory = configuration.stateDirectory
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
    try FileManager.default.createDirectory(
      at: jobDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let journal = try FileDurableJournal(url: jobDirectory.appendingPathComponent("journal.jsonl"))
    let timestamp = nowUTC()
    var record = RuntimeJobRecord(
      jobID: jobID,
      request: request,
      operationReference: descriptor.reference,
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: descriptor.provider.rawValue,
      createdAtUTC: timestamp)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: record.sessionID, jobID: jobID,
        timestamp: timestamp, executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: record.sessionID, jobID: jobID,
        timestamp: timestamp, from: .queued, to: .preflight, reason: "admitted"))
    record.state = "preflight"
    record.timeline = ["jobCreated", "queued->preflight"]
    try record.persist(into: jobDirectory)
    jobs[jobID] = JobRuntime(record: record, journal: journal, nextSequence: 2)
    return RuntimeJobAcceptance(jobID: jobID, deduplicated: false)
  }

  // MARK: Run

  public func run(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    guard runtime.record.state == "preflight" else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "job \(jobID) is \(runtime.record.state), not preflight")
    }
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.operationReference),
      let provider = providers.provider(id: runtime.record.providerID)
    else {
      throw RuntimeJobEngineError.internalFailure("catalog or provider vanished for \(jobID)")
    }

    try transition(&runtime, from: .preflight, to: .running, reason: "steps-start")

    let isMutation = descriptor.minimumEffect >= .deviceMutation
    let targetID = runtime.record.request.target.targetID
    do {
      if isMutation {
        let capturedJobID = jobID
        try await mutationLane.withMutationLane(deviceID: targetID, requestID: capturedJobID) {
          [weak self] in
          guard let self else { throw RuntimeJobEngineError.internalFailure("engine gone") }
          try await self.executeSteps(
            jobID: capturedJobID, descriptor: descriptor, provider: provider)
        }
      } else {
        try await executeSteps(jobID: jobID, descriptor: descriptor, provider: provider)
      }
    } catch let failure as RuntimeDispatchFailure {
      var current = jobs[jobID] ?? runtime
      switch failure {
      case .outcomeUnknown(let reason):
        try transition(
          &current, from: .running, to: .waitingForRecovery, reason: "outcomeUnknown: \(reason)")
        current.record.outcomeUnknown = true
        try current.record.persist(
          into: jobDirectory(for: jobID))
        jobs[jobID] = current
        return status(of: current.record)
      case .failed(let reason):
        try transition(&current, from: .running, to: .failed, reason: reason)
        try current.record.persist(into: jobDirectory(for: jobID))
        jobs[jobID] = current
        return status(of: current.record)
      }
    }

    var current = jobs[jobID] ?? runtime
    if cancellationRequests.contains(jobID) {
      cancellationRequests.remove(jobID)
      try transition(&current, from: .running, to: .cancelRequested, reason: "client-cancel")
      try transition(
        &current, from: .cancelRequested, to: .cancellingAtSafeBoundary,
        reason: "safe-boundary")
      try transition(
        &current, from: .cancellingAtSafeBoundary, to: .cancelled, reason: "steps-drained")
    } else {
      try transition(&current, from: .running, to: .finalizing, reason: "steps-complete")
      try transition(&current, from: .finalizing, to: .succeeded, reason: "finalized")
    }
    try current.record.persist(into: jobDirectory(for: jobID))
    jobs[jobID] = current
    return status(of: current.record)
  }

  private func executeSteps(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider
  ) async throws {
    for step in descriptor.steps where !step.isOptional {
      if jobs[jobID].map({ cancellationRequests.contains($0.record.jobID) }) == true {
        return  // safe boundary between steps; run() records the transitions
      }
      switch step.kind {
      case .preflightHostStorage, .postprocessArtifact, .finalizeSession, .hashFile,
        .verifyArtifact, .requestConfirmation:
        // Engine-internal host steps: no provider dispatch in MU-2; their
        // real implementations land with the operations that need them.
        appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        continue
      default:
        break
      }
      let action = try provider.action(
        for: step, operation: descriptor,
        inputs: jobs[jobID]?.record.request.inputs ?? [:])
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: jobs[jobID]?.record.request.target.targetID ?? "",
        bindingRevision: jobs[jobID]?.record.request.target.expectedBindingRevision,
        nowUTC: nowUTC())
      let plan = try provider.lower(action: action, context: context)
      try await dispatchWithWAL(
        jobID: jobID, step: step, action: action, plan: plan, provider: provider,
        context: context)
    }
  }

  private func dispatchWithWAL(
    jobID: String,
    step: CatalogStepDescriptor,
    action: TypedProviderAction,
    plan: TypedProcessPlan,
    provider: any DeviceProvider,
    context: ProviderExecutionContext
  ) async throws {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let workflowStep = try Self.journalStep(for: step, jobID: jobID)
    let intentEventID = "intent-\(step.stepID)"
    // Journal target evidence mirrors the step's binding requirement: host
    // steps carry no binding revision, device steps carry the placeholder
    // binding evidence until MU-3 wires real fact resolution.
    let isDeviceBound = step.binding == .confirmedDevice
    let intent = try JournalEvent.stepIntent(
      eventID: intentEventID, sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID, jobID: jobID,
      timestamp: nowUTC(), step: workflowStep,
      target: JournalTarget(
        scope: isDeviceBound ? "device" : "host",
        targetID: runtime.record.request.target.targetID,
        connectKey: isDeviceBound ? "pending-binding" : nil,
        identitySnapshotHash: isDeviceBound ? String(repeating: "0", count: 64) : nil),
      attempt: 1,
      bindingRevision: isDeviceBound
        ? (runtime.record.request.target.expectedBindingRevision ?? 1) : nil)
    // The write-ahead gate is the production dispatch path: the closure is
    // unreachable unless the intent is durable.
    let gate = WriteAheadIntentGate(journal: runtime.journal)
    try gate.dispatch(intent: intent) { () }
    runtime.nextSequence += 1
    runtime.record.timeline.append("intent \(step.stepID)")
    jobs[jobID] = runtime

    let receipt: ProviderProcessReceipt
    do {
      receipt = try await dispatcher.dispatch(plan)
    } catch let failure as RuntimeDispatchFailure {
      // Record the unknown/failed outcome durably before surfacing it; the
      // journal validator forbids further intents after an unknown.
      var current = jobs[jobID] ?? runtime
      let certainty: JournalOutcomeCertainty =
        {
          if case .outcomeUnknown = failure { return .outcomeUnknown }
          return .confirmed
        }()
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed",  // certainty field carries unknown-ness; result vocabulary is closed
          outcomeCertainty: certainty))
      current.nextSequence += 1
      current.record.timeline.append(
        certainty == .outcomeUnknown ? "outcomeUnknown \(step.stepID)" : "failed \(step.stepID)")
      jobs[jobID] = current
      throw failure
    }

    let outcome = try provider.verify(receipt: receipt, action: action, context: context)
    var current = jobs[jobID] ?? runtime
    switch outcome {
    case .verified(let summary):
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "succeeded", outcomeCertainty: .confirmed))
      current.nextSequence += 1
      current.record.timeline.append("verified \(step.stepID) \(summary.keys.sorted())")
      jobs[jobID] = current
    case .failed(let code, let detail):
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed", outcomeCertainty: .confirmed))
      current.nextSequence += 1
      jobs[jobID] = current
      throw RuntimeDispatchFailure.failed("\(code): \(detail)")
    case .unknown(let reason), .unsupported(let reason):
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed", outcomeCertainty: .outcomeUnknown))
      current.nextSequence += 1
      jobs[jobID] = current
      throw RuntimeDispatchFailure.outcomeUnknown(reason)
    }
  }

  // MARK: Cancel / status / recovery

  public func requestCancel(jobID: String) throws {
    guard jobs[jobID] != nil else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    cancellationRequests.insert(jobID)
  }

  public func status(jobID: String) throws -> RuntimeJobStatus {
    guard let runtime = jobs[jobID] else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    return status(of: runtime.record)
  }

  public func listJobs() -> [RuntimeJobStatus] {
    jobs.values.map { status(of: $0.record) }.sorted { $0.jobID < $1.jobID }
  }

  /// Restart recovery: reopen every persisted job, replay its journal and
  /// park unknowns. Never redispatches anything.
  public func recoverPersistedJobs() throws -> [RuntimeJobStatus] {
    let jobsRoot = configuration.stateDirectory.appendingPathComponent("jobs", isDirectory: true)
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: jobsRoot, includingPropertiesForKeys: nil)) ?? []
    var recovered: [RuntimeJobStatus] = []
    for entry in entries where entry.hasDirectoryPath {
      let jobID = entry.lastPathComponent
      if jobs[jobID] != nil { continue }
      guard var record = try? RuntimeJobRecord.load(from: entry) else { continue }
      let journalURL = entry.appendingPathComponent("journal.jsonl")
      let inspection = try DurableJournalRecovery.inspect(url: journalURL)
      if inspection.requiresRecovery || !inspection.outstandingIntents.isEmpty
        || !inspection.unknownOutcomes.isEmpty
      {
        record.state = "waitingForRecovery"
        record.outcomeUnknown = true
        record.timeline.append("recovered: outstanding intents or unknown outcomes; no redispatch")
      } else {
        record.timeline.append("recovered: journal clean")
      }
      try? record.persist(into: entry)
      recovered.append(status(of: record))
      // Reopened jobs are read-only history in MU-2: reconcile drives them
      // forward, run() does not accept them again.
      let journal = try FileDurableJournal(url: journalURL)
      jobs[jobID] = JobRuntime(
        record: record, journal: journal,
        nextSequence: Int((inspection.lastDurableSequence ?? -1) + 1))
    }
    return recovered
  }

  public func reconcile(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    guard runtime.record.outcomeUnknown else { return status(of: runtime.record) }
    guard
      let provider = providers.provider(id: runtime.record.providerID)
    else {
      throw RuntimeJobEngineError.internalFailure("provider vanished for \(jobID)")
    }
    let context = ProviderExecutionContext(
      jobID: jobID, stepID: "reconcile",
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      nowUTC: nowUTC())
    let reference = ProviderDurableIntentReference(
      jobID: jobID, stepID: "reconcile", intentEventID: "reconcile",
      action: .hdc(.observeDevice(connectKey: "reconcile")))
    let outcome = try await provider.reconcile(intent: reference, context: context)
    switch outcome {
    case .confirmedCompleted, .confirmedNotExecuted:
      runtime.record.outcomeUnknown = false
      runtime.record.timeline.append("reconciled: \(outcome)")
    case .stillUnknown(let reason):
      runtime.record.timeline.append("reconcile inconclusive: \(reason)")
    }
    try runtime.record.persist(into: jobDirectory(for: jobID))
    jobs[jobID] = runtime
    return status(of: runtime.record)
  }

  // MARK: Helpers

  private func authorize(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect
  ) async throws {
    if effect <= .readOnly {
      let decision = configuration.defaultReadOnlyPolicy.evaluate(
        effect: effect,
        timeoutSeconds: descriptor.timeoutSeconds,
        outputByteBudget: descriptor.outputByteBudget)
      guard decision == .allowed else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired, "default read-only policy denied: \(decision)")
      }
      return
    }
    guard let authorization = request.authorization else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "effect \(effect.rawValue) requires a runtime capability")
    }
    let query = RuntimeCapabilityAuthorizationQuery(
      operationID: descriptor.id,
      operationVersion: descriptor.version,
      effect: effect,
      targetStableIdentitySHA256: nil,
      planDigest: nil,
      inputs: request.inputs)
    do {
      _ = try await capabilityStore.consume(
        capabilityID: authorization.capabilityID,
        reservationID: request.idempotencyKey,
        query: query,
        nowUTC: nowUTC())
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired, "capability denied: \(error)")
    }
  }

  private func validateInputs(
    _ inputs: [String: JSONValue], against descriptor: CatalogOperationDescriptor
  ) throws {
    let fieldTable = Dictionary(
      uniqueKeysWithValues: descriptor.inputs.map { ($0.name, $0) })
    for field in descriptor.inputs where field.isRequired {
      guard inputs[field.name] != nil else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "required input \(field.name) is absent")
      }
    }
    for (key, value) in inputs {
      // Legacy adapter annotations are tolerated and ignored by execution.
      if key.hasPrefix("legacy") { continue }
      guard let field = fieldTable[key] else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) is not declared by \(descriptor.reference)")
      }
      let matches: Bool
      switch (field.type, value) {
      case (.string, .string), (.artifactLease, .string), (.artifactReference, .string):
        matches = true
      case (.integer, .integer), (.integer, .unsignedInteger):
        matches = true
      case (.boolean, .bool):
        matches = true
      case (.stringArray, .array(let items)):
        matches = items.allSatisfy {
          if case .string = $0 { return true }
          return false
        }
      default:
        matches = false
      }
      guard matches else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) has the wrong type for \(descriptor.reference)")
      }
      if let allowed = field.enumValues, case .string(let raw) = value,
        !allowed.contains(raw)
      {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) value is outside its enum")
      }
    }
  }

  private func transition(
    _ runtime: inout JobRuntime, from: JobState, to: JobState, reason: String
  ) throws {
    try runtime.journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "t-\(runtime.nextSequence)", sequence: runtime.nextSequence,
        sessionID: runtime.record.sessionID, jobID: runtime.record.jobID,
        timestamp: nowUTC(), from: from, to: to, reason: reason))
    runtime.nextSequence += 1
    runtime.record.state = to.rawValue
    runtime.record.timeline.append("\(from.rawValue)->\(to.rawValue)")
    jobs[runtime.record.jobID] = runtime
  }

  private func appendTimeline(jobID: String, entry: String) {
    guard var runtime = jobs[jobID] else { return }
    runtime.record.timeline.append(entry)
    jobs[jobID] = runtime
  }

  private func jobDirectory(for jobID: String) -> URL {
    configuration.stateDirectory
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
  }

  private func status(of record: RuntimeJobRecord) -> RuntimeJobStatus {
    RuntimeJobStatus(
      jobID: record.jobID,
      operationReference: record.operationReference,
      targetID: record.request.target.targetID,
      state: record.state,
      waitingForHuman: record.state == "waitingForRecovery",
      outcomeUnknown: record.outcomeUnknown,
      timeline: record.timeline)
  }

  private static func fingerprint(of data: Data) -> String {
    RuntimeJobRecord.sha256Hex(data)
  }

  /// Journal-grade WorkflowStep for the kinds the engine exercises in MU-2.
  /// Argument tables are the registry's required keys with deterministic,
  /// audit-honest values.
  static func journalStep(for step: CatalogStepDescriptor, jobID: String) throws -> WorkflowStep {
    let arguments: [String: JSONValue]
    switch step.kind {
    case .probeHostTool:
      arguments = [
        "toolIdentity": .string("hdc"),
        "candidatePath": .string("resolved-by-provider"),
      ]
    case .probeHDCServer:
      arguments = [
        "endpoint": .string("resolved-by-provider"),
        "clientIdentity": .string("arkdeck-agentd"),
      ]
    case .probeDevice:
      arguments = ["evidencePolicy": .string("coreMinimum")]
    default:
      throw RuntimeJobEngineError.internalFailure(
        "no journal argument table for \(step.kind.rawValue) in MU-2")
    }
    return try WorkflowStep(
      id: step.stepID,
      kind: step.kind,
      declaredEffect: step.effect,
      declaredCancellation: step.cancellation,
      declaredBindingRequirement: step.binding,
      arguments: arguments)
  }
}

// MARK: - Persisted job record

public struct RuntimeJobRecord: Codable, Sendable, Equatable {
  public let jobID: String
  public let request: RuntimeOperationRequest
  public let operationReference: String
  public let catalogDigest: String
  public let providerID: String
  public let createdAtUTC: String
  public var state: String = "queued"
  public var outcomeUnknown: Bool = false
  public var timeline: [String] = []

  public var sessionID: String { "session-\(jobID)" }

  func persist(into directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(self)
    let url = directory.appendingPathComponent("job-record.json")
    let temporary = directory.appendingPathComponent(".job-record.tmp")
    try data.write(to: temporary, options: [])
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  static func load(from directory: URL) throws -> RuntimeJobRecord {
    let data = try Data(contentsOf: directory.appendingPathComponent("job-record.json"))
    return try JSONDecoder().decode(RuntimeJobRecord.self, from: data)
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
