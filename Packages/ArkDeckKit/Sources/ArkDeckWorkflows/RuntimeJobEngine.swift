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
    /// Steps that did not run. A downstream step whose upstream is here
    /// must not run either - otherwise a failed capture could still
    /// "receive" a product and the run would look complete.
    var skippedStepIDs: Set<String> = []
  }

  private let configuration: Configuration
  private let providers: DeviceProviderRegistry
  private let dispatcher: any RuntimeProcessDispatching
  private let capabilityStore: RuntimeCapabilityStore
  private let artifactStore: RuntimeArtifactStore?
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
    artifactStore: RuntimeArtifactStore? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.configuration = configuration
    self.providers = providers
    self.dispatcher = dispatcher
    self.capabilityStore = capabilityStore
    self.artifactStore = artifactStore
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

    // Authorization must reflect what this request will actually do, not
    // the operation's floor. capture.diagnostics@1 is readOnly until the
    // inputs select the remote-file trace and its cleanup, at which point
    // it mutates the device and needs an E1 capability. Charging the
    // minimum effect here would let a mutating plan through on the default
    // read-only policy.
    let effectiveEffect = Self.effectiveEffect(
      descriptor: descriptor, inputs: request.inputs)
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

    let isMutation =
      Self.effectiveEffect(
        descriptor: descriptor, inputs: runtime.record.request.inputs) >= .deviceMutation
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
        // The state graph routes every terminal outcome through
        // finalizing: a job always gets its wrap-up phase, success or not.
        try transition(&current, from: .running, to: .finalizing, reason: reason)
        try transition(&current, from: .finalizing, to: .failed, reason: reason)
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
      jobs[jobID] = current
      try await publishFinalizeArtifacts(jobID: jobID, descriptor: descriptor)
      current = jobs[jobID] ?? current
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
    for step in descriptor.steps {
      if jobs[jobID].map({ cancellationRequests.contains($0.record.jobID) }) == true {
        return  // safe boundary between steps; run() records the transitions
      }
      switch step.kind {
      case .preflightHostStorage, .postprocessArtifact, .finalizeSession, .hashFile,
        .verifyArtifact, .requestConfirmation:
        // Engine-internal host steps: no provider dispatch yet; their real
        // implementations land with the operations that need them.
        appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        continue
      default:
        break
      }
      // Optional steps are the partial-success surface: when one cannot
      // run or fails, the job continues and the products it owned are
      // recorded as missing with a reason. A required step failing still
      // fails the job.
      if step.isOptional, !isOptionalStepSelected(step, jobID: jobID, descriptor: descriptor) {
        // Name the real cause: "its upstream failed" and "you did not ask
        // for it" are different facts, and evidence must not blur them.
        let reason: String
        if let upstream = Self.optionalStepUpstream[descriptor.reference]?[step.stepID],
          let upstreamReason = jobs[jobID]?.record.skipReasons[upstream]
        {
          reason = "upstream \(upstream) did not run: \(upstreamReason)"
        } else {
          reason = "step not selected by the request inputs"
        }
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor, reason: reason)
        continue
      }
      let action: TypedProviderAction
      do {
        action = try provider.action(
          for: step, operation: descriptor,
          inputs: jobs[jobID]?.record.request.inputs ?? [:])
      } catch where step.isOptional {
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor,
          reason: "provider has no action for this step")
        continue
      }
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: jobs[jobID]?.record.request.target.targetID ?? "",
        bindingRevision: jobs[jobID]?.record.request.target.expectedBindingRevision,
        nowUTC: nowUTC())
      let plan = try provider.lower(action: action, context: context)
      do {
        try await dispatchWithWAL(
          jobID: jobID, step: step, action: action, plan: plan, provider: provider,
          context: context, descriptor: descriptor)
      } catch let failure as RuntimeDispatchFailure {
        // An unknown outcome always halts, optional or not: we cannot
        // continue past an effect whose result we do not know.
        if case .outcomeUnknown = failure { throw failure }
        guard step.isOptional else { throw failure }
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor, reason: "\(failure)")
      }
    }
  }

  /// The effect this request will actually reach: the maximum effect over
  /// the steps its inputs select. Optional steps that will not run do not
  /// raise the bar, and steps that will run cannot duck under it.
  static func effectiveEffect(
    descriptor: CatalogOperationDescriptor, inputs: [String: JSONValue]
  ) -> WorkflowEffect {
    var effect = descriptor.minimumEffect
    for step in descriptor.steps {
      if step.isOptional && !optionalStepIsSelected(step, descriptor: descriptor, inputs: inputs) {
        continue
      }
      if step.effect > effect { effect = step.effect }
    }
    return effect
  }

  /// Pure selection rule, shared by authorization (before a job exists)
  /// and execution (after it does), so the two can never disagree about
  /// which steps count.
  static func optionalStepIsSelected(
    _ step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> Bool {
    switch step.stepID {
    case "capture-trace", "receive-trace-artifact", "cleanup-remote-temp":
      if case .array(let categories)? = inputs["traceCategories"] {
        return !categories.isEmpty
      }
      return false
    case "capture-ui-dump":
      if case .bool(let enabled)? = inputs["uiDump"] { return enabled }
      return true  // the catalog default
    default:
      return true
    }
  }

  /// Steps whose success is decided by a paired readback rather than by
  /// their own result. The readback step is required, so nothing here can
  /// let an unverified mutation pass as success - it only moves the
  /// judgement to the step that can actually make it.
  static func awaitsReadback(
    step: CatalogStepDescriptor, descriptor: CatalogOperationDescriptor
  ) -> Bool {
    guard let readbackStepID = readbackPairs[descriptor.reference]?[step.stepID] else {
      return false
    }
    return descriptor.steps.contains { $0.stepID == readbackStepID && !$0.isOptional }
  }

  static let readbackPairs: [String: [String: String]] = [
    "debug.hap@1": [
      "install-hap": "package-readback",
      "start-ability": "process-readback",
    ]
  ]

  /// Optional steps are selected by the inputs that make them meaningful -
  /// e.g. a trace capture only runs when trace categories were requested.
  private func isOptionalStepSelected(
    _ step: CatalogStepDescriptor, jobID: String, descriptor: CatalogOperationDescriptor
  ) -> Bool {
    // A step whose upstream never ran cannot run either: receiving a trace
    // that was never captured would publish a product out of thin air and
    // make a partial run look whole.
    if let upstream = Self.optionalStepUpstream[descriptor.reference]?[step.stepID],
      jobs[jobID]?.skippedStepIDs.contains(upstream) == true
    {
      return false
    }
    let inputs = jobs[jobID]?.record.request.inputs ?? [:]
    return Self.optionalStepIsSelected(step, descriptor: descriptor, inputs: inputs)
  }

  /// Which optional step depends on which. Kept explicit rather than
  /// inferred from step order so a reordering cannot silently change what
  /// runs after a failure.
  static let optionalStepUpstream: [String: [String: String]] = [
    "capture.diagnostics@1": [
      "receive-trace-artifact": "capture-trace",
      "cleanup-remote-temp": "capture-trace",
    ]
  ]

  /// Records every product an unrun optional step owned as missing, with
  /// the reason. This is what keeps a partial capture honest.
  private func recordSkippedOptionalStep(
    jobID: String, step: CatalogStepDescriptor, descriptor: CatalogOperationDescriptor,
    reason: String
  ) async throws {
    appendTimeline(jobID: jobID, entry: "skipped \(step.stepID): \(reason)")
    if var runtime = jobs[jobID] {
      runtime.skippedStepIDs.insert(step.stepID)
      runtime.record.skipReasons[step.stepID] = reason
      jobs[jobID] = runtime
    }
    guard let artifactStore, let runtime = jobs[jobID],
      let names = Self.artifactMapping[descriptor.reference]?[step.stepID]
    else { return }
    let binding = ArtifactBindingSnapshot(
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      stableIdentitySHA256: nil)
    for name in names {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      _ = try? await artifactStore.recordMissing(
        jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID, name: name,
        mediaType: declaration.mediaType, privacy: declaration.privacy,
        retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference,
        providerID: descriptor.provider.rawValue, bindingSnapshot: binding, reason: reason)
    }
  }

  private func dispatchWithWAL(
    jobID: String,
    step: CatalogStepDescriptor,
    action: TypedProviderAction,
    plan: TypedProcessPlan,
    provider: any DeviceProvider,
    context: ProviderExecutionContext,
    descriptor: CatalogOperationDescriptor
  ) async throws {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: runtime.record.request.inputs)
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
      try await publishDeclaredArtifacts(
        jobID: jobID, step: step, summary: summary, receipt: receipt)
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
      // A mutation whose truth is delegated to a paired readback is not an
      // unknown *external outcome*: the effect either happened or did not,
      // and the very next required step is about to determine which. The
      // job continues to that readback; if the readback fails, the job
      // fails. Any other unknown still halts with zero replay.
      if Self.awaitsReadback(step: step, descriptor: descriptor) {
        try current.journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
            sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
            stepID: step.stepID, attempt: 1,
            correlatesToIntentEventID: intentEventID,
            result: "succeeded", outcomeCertainty: .confirmed))
        current.nextSequence += 1
        current.record.timeline.append("dispatched \(step.stepID); awaiting readback")
        jobs[jobID] = current
        return
      }
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

  /// Publishes the products a verified step is responsible for. The
  /// mapping is declared in the catalog, so a step cannot invent an
  /// artifact and a declared artifact cannot silently vanish - anything
  /// the step could not produce is recorded with its reason instead.
  private func publishDeclaredArtifacts(
    jobID: String,
    step: CatalogStepDescriptor,
    summary: [String: String],
    receipt: ProviderProcessReceipt
  ) async throws {
    guard let artifactStore, let runtime = jobs[jobID],
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.operationReference)
    else { return }
    guard let mapping = Self.artifactMapping[descriptor.reference]?[step.stepID] else {
      return  // this step owns no declared product
    }
    let binding = ArtifactBindingSnapshot(
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      stableIdentitySHA256: nil)
    for name in mapping {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      let contents = Self.artifactContents(
        name: name, summary: summary, receipt: receipt, descriptor: descriptor,
        record: runtime.record)
      do {
        let metadata = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
            name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
            retentionClass: declaration.retentionClass,
            sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
            bindingSnapshot: binding, contents: contents))
        appendTimeline(jobID: jobID, entry: "artifact \(name) -> \(metadata.artifactID)")
      } catch {
        // A publication failure is recorded, never swallowed: the index
        // keeps the declared product with its reason.
        _ = try? await artifactStore.recordMissing(
          jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
          name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
          retentionClass: declaration.retentionClass,
          sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
          bindingSnapshot: binding, reason: "\(error)")
        appendTimeline(jobID: jobID, entry: "artifact \(name) missing: \(error)")
      }
    }
  }

  /// Which step produces which declared artifact. Kept beside the engine
  /// rather than in the catalog schema because it is an implementation
  /// detail of the orchestration, not part of the published contract.
  static let artifactMapping: [String: [String: [String]]] = [
    "observe.device@1": [
      "probe-host-tool": ["tool-facts.json"],
      "probe-device": ["device-facts.json", "binding-snapshot.json"],
    ],
    "capture.diagnostics@1": [
      "capture-hilog": ["hilog.txt"],
      "capture-ui-dump": ["ui-dump.json"],
      "receive-trace-artifact": ["trace.htrace"],
    ],
    "debug.hap@1": [
      "package-readback": ["install-readback.json"],
      "process-readback": ["process-readback.json"],
      "capture-diagnostics": ["debug-hilog.txt"],
    ],
  ]

  /// Products the engine synthesises at finalize time rather than from a
  /// single step: the index and summary describe the run as a whole.
  static let finalizeArtifacts: [String: [String]] = [
    "capture.diagnostics@1": ["artifact-index.json", "capture-summary.json"]
  ]

  /// Writes the run-level index and summary. The summary states every
  /// declared product and its final status, so a caller reading only the
  /// summary still learns that (say) the trace is missing - a partial
  /// capture can never present itself as complete.
  private func publishFinalizeArtifacts(
    jobID: String, descriptor: CatalogOperationDescriptor
  ) async throws {
    guard let artifactStore, let runtime = jobs[jobID],
      let names = Self.finalizeArtifacts[descriptor.reference]
    else { return }
    let binding = ArtifactBindingSnapshot(
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      stableIdentitySHA256: nil)

    // Backstop: every declared product that never reached the index gets
    // recorded as missing here, whichever step should have produced it.
    // Relying on the step->artifact map alone would let a product vanish
    // silently when an upstream step is the one that failed.
    var recorded = (try? await artifactStore.list(jobID: jobID)) ?? []
    for declaration in descriptor.artifacts
    where !names.contains(declaration.name)
      && !recorded.contains(where: { $0.name == declaration.name })
    {
      _ = try? await artifactStore.recordMissing(
        jobID: jobID, sessionID: runtime.record.sessionID, stepID: "finalize-session",
        name: declaration.name, mediaType: declaration.mediaType,
        privacy: declaration.privacy, retentionClass: declaration.retentionClass,
        sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
        bindingSnapshot: binding,
        reason: "no step produced this declared artifact")
    }
    recorded = (try? await artifactStore.list(jobID: jobID)) ?? []

    var perArtifact: [String: JSONValue] = [:]
    for declaration in descriptor.artifacts where !names.contains(declaration.name) {
      let match = recorded.first { $0.name == declaration.name }
      let state: String
      var detail: String?
      switch match?.status {
      case .some(.published): state = "published"
      case .some(.missing(let reason)):
        state = "missing"
        detail = reason
      case .some(.truncated(let atBytes)):
        state = "truncated"
        detail = "at \(atBytes) bytes"
      case nil:
        state = "missing"
        detail = "never produced"
      }
      var entry: [String: JSONValue] = [
        "status": .string(state),
        "required": .bool(declaration.isRequired),
      ]
      if let detail { entry["detail"] = .string(detail) }
      if let match, match.status.isPublished {
        entry["artifactId"] = .string(match.artifactID)
        entry["byteCount"] = .integer(Int64(match.byteCount))
      }
      perArtifact[declaration.name] = .object(entry)
    }

    let missingRequired = descriptor.artifacts.filter { declaration in
      guard declaration.isRequired, !names.contains(declaration.name) else { return false }
      return recorded.first { $0.name == declaration.name }?.status.isPublished != true
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]

    for name in names {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      let payload: [String: JSONValue]
      if name.contains("index") {
        payload = [
          "operation": .string(descriptor.reference),
          "jobId": .string(jobID),
          "artifacts": .object(perArtifact),
        ]
      } else {
        payload = [
          "operation": .string(descriptor.reference),
          "jobId": .string(jobID),
          "completeness": .string(missingRequired.isEmpty ? "complete" : "incomplete"),
          "missingRequired": .array(missingRequired.map { .string($0.name) }),
          "artifacts": .object(perArtifact),
        ]
      }
      _ = try? await artifactStore.publish(
        RuntimeArtifactPublicationRequest(
          jobID: jobID, sessionID: runtime.record.sessionID, stepID: "finalize-session",
          name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
          retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference,
          providerID: descriptor.provider.rawValue, bindingSnapshot: binding,
          contents: (try? encoder.encode(payload)) ?? Data("{}".utf8)))
    }
    if !missingRequired.isEmpty {
      appendTimeline(
        jobID: jobID,
        entry: "incomplete: missing required \(missingRequired.map(\.name).sorted())")
    }
  }

  private static func artifactContents(
    name: String,
    summary: [String: String],
    receipt: ProviderProcessReceipt,
    descriptor: CatalogOperationDescriptor,
    record: RuntimeJobRecord
  ) -> Data {
    var fields: [String: JSONValue] = [
      "artifact": .string(name),
      "operation": .string(descriptor.reference),
      "jobId": .string(record.jobID),
      "catalogDigest": .string(record.catalogDigest),
    ]
    for (key, value) in summary {
      fields[key] = .string(value)
    }
    if name == "binding-snapshot.json" {
      fields["targetId"] = .string(record.request.target.targetID)
      if let revision = record.request.target.expectedBindingRevision {
        fields["expectedBindingRevision"] = .integer(Int64(revision))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return (try? encoder.encode(fields)) ?? Data("{}".utf8)
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
  static func journalStep(
    for step: CatalogStepDescriptor, jobID: String, inputs: [String: JSONValue] = [:]
  ) throws -> WorkflowStep {
    var bundleName: String?
    if case .string(let value)? = inputs["bundleName"] { bundleName = value }
    var abilityName: String?
    if case .string(let value)? = inputs["abilityName"] { abilityName = value }
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
    case .preflightDeviceStorage:
      arguments = [
        "remotePath": .string("/data/local/tmp/arkdeck"),
        "requiredBytes": .integer(1_048_576),
      ]
    case .captureRemoteStdout:
      arguments = [
        "catalogId": .string("arkui-ui-dump"),
        "actionId": .string(step.stepID == "capture-ui-dump" ? "elementTree" : "nodeSummary"),
        "parameters": .object([:]),
        "artifactId": .string("artifact-\(step.stepID)"),
      ]
    case .captureRemoteFile:
      arguments = [
        "catalogId": .string("trace-presets"),
        "actionId": .string("arkuiDeep"),
        "parameters": .object([:]),
        "artifactId": .string("artifact-\(step.stepID)"),
        "ownedRemotePath": .string("/data/local/tmp/arkdeck/\(jobID)/\(step.stepID)"),
      ]
    case .receiveFile:
      arguments = [
        "remotePath": .string("/data/local/tmp/arkdeck/\(jobID)/capture-trace"),
        "artifactId": .string("artifact-\(step.stepID)"),
        "localRelativePath": .string("artifacts/raw/trace.htrace"),
      ]
    case .cleanupOwnedRemotePath:
      arguments = [
        "remotePath": .string("/data/local/tmp/arkdeck/\(jobID)"),
        "ownershipEvidenceId": .string("owned-\(jobID)"),
      ]
    case .sendFile:
      arguments = [
        "sourceArtifactId": .string("hap-artifact"),
        "remotePath": .string("/data/local/tmp/arkdeck/\(jobID)/\(step.stepID)"),
        "sourceSha256": .string(String(repeating: "0", count: 64)),
      ]
    case .installPackage:
      arguments = [
        "packageArtifactId": .string("hap-artifact"),
        "packageName": .string(bundleName ?? "com.example.app"),
        "replacePolicy": .string("allow"),
      ]
    case .uninstallPackage:
      arguments = ["packageName": .string(bundleName ?? "com.example.app")]
    case .startApplication, .stopApplication:
      arguments = [
        "bundleName": .string(bundleName ?? "com.example.app"),
        "abilityName": .string(abilityName ?? "EntryAbility"),
      ]
    case .runApprovedRemoteRead:
      arguments = [
        "catalogId": .string("arkdeck-remote-operations"),
        "actionId": .string("packageInfo"),
        "parameters": .object([:]),
        "artifactId": .string("artifact-\(step.stepID)"),
      ]
    case .verifyRemoteState:
      arguments = [
        "probeId": .string("process-state"),
        "expectedState": .string("running"),
      ]
    default:
      throw RuntimeJobEngineError.internalFailure(
        "no journal argument table for \(step.kind.rawValue)")
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
  /// Why a step did not run, keyed by step id, so a downstream skip can
  /// cite the original cause instead of restating its own condition.
  public var skipReasons: [String: String] = [:]

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
