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

public enum RuntimeEvidenceAuthorityKind: String, Sendable, Equatable, Codable {
  case defaultReadOnlyPolicy
  case runtimeCapability
  case standingAuthorization
}

/// The admission decision actually consumed by this job. This record is
/// audit provenance only: reading or projecting it cannot mint an
/// authority or reach the dispatch port.
public struct RuntimeAdmissionEvidence: Sendable, Equatable, Codable {
  public let kind: RuntimeEvidenceAuthorityKind
  public let reference: String
  public let admittedAtUTC: String
  public let validUntilUTC: String?
  public let consumptionFingerprintSHA256: String?

  public init(
    kind: RuntimeEvidenceAuthorityKind,
    reference: String,
    admittedAtUTC: String,
    validUntilUTC: String?,
    consumptionFingerprintSHA256: String?
  ) {
    self.kind = kind
    self.reference = reference
    self.admittedAtUTC = admittedAtUTC
    self.validUntilUTC = validUntilUTC
    self.consumptionFingerprintSHA256 = consumptionFingerprintSHA256
  }
}

public struct RuntimeEvidencePreflightStep: Sendable, Equatable, Codable {
  public let stepID: String
  public let stepKind: String
  public let outcomeAtUTC: String

  public init(stepID: String, stepKind: String, outcomeAtUTC: String) {
    self.stepID = stepID
    self.stepKind = stepKind
    self.outcomeAtUTC = outcomeAtUTC
  }
}

/// Facts assembled only from the three independently journaled, verified
/// typed preflight outcomes belonging to this same job.
public struct RuntimeEvidenceObservation: Sendable, Equatable, Codable {
  public let targetID: String?
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let model: String?
  public let firmware: String?
  public let transport: String?
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let confirmedAtUTC: String?
  public let confirmationMethod: String
  public let preflightSteps: [RuntimeEvidencePreflightStep]

  public init(
    targetID: String?,
    bindingRevision: Int?,
    stableIdentitySHA256: String?,
    model: String?,
    firmware: String?,
    transport: String?,
    providerID: String,
    toolVersion: String,
    toolSHA256: String,
    confirmedAtUTC: String?,
    confirmationMethod: String,
    preflightSteps: [RuntimeEvidencePreflightStep]
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.model = model
    self.firmware = firmware
    self.transport = transport
    self.providerID = providerID
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.confirmedAtUTC = confirmedAtUTC
    self.confirmationMethod = confirmationMethod
    self.preflightSteps = preflightSteps
  }
}

/// Durable, job-local assembly state. It is never exported as evidence
/// until all three fragments are present and correlated.
public struct RuntimeEvidencePreflightAccumulator: Sendable, Equatable, Codable {
  public let targetID: String
  public let bindingRevision: Int
  public let stableIdentitySHA256: String
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public var transport: String?
  public var confirmedAtUTC: String?
  public var model: String?
  public var firmware: String?
  public var steps: [RuntimeEvidencePreflightStep]

  public var isComplete: Bool {
    transport != nil && confirmedAtUTC != nil && model != nil && firmware != nil
      && steps.map(\.stepID)
        == ["confirm-evidence-target", "read-evidence-model", "read-evidence-firmware"]
  }
}

/// Product-owned durable facts exposed through the daemon's read-only
/// evidence query. It intentionally contains no claim metadata such as
/// evidence ID or Acceptance IDs.
public struct RuntimeJobEvidenceSnapshot: Sendable, Equatable, Codable {
  public let jobID: String
  public let operationReference: String
  public let catalogDigest: String
  public let targetID: String
  public let bindingRevision: Int?
  public let providerID: String
  public let actualEffect: String?
  public let authority: RuntimeAdmissionEvidence?
  public let observation: RuntimeEvidenceObservation?
  public let actualStepKinds: [String]
  public let executionMode: String
  public let terminalState: String
  public let outcomeUnknown: Bool
  public let startedAtUTC: String?
  public let firstEvidenceStepAtUTC: String?
  public let finishedAtUTC: String?
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
    let admission = try await authorize(
      request: request, descriptor: descriptor, effect: effectiveEffect)

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
      createdAtUTC: timestamp,
      actualEffect: effectiveEffect.rawValue,
      admissionEvidence: admission)
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

    runtime.record.startedAtUTC = nowUTC()
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
        current.record.finishedAtUTC = nowUTC()
        try current.record.persist(
          into: jobDirectory(for: jobID))
        jobs[jobID] = current
        return status(of: current.record)
      case .failed(let reason):
        // The state graph routes every terminal outcome through
        // finalizing: a job always gets its wrap-up phase, success or not.
        try transition(&current, from: .running, to: .finalizing, reason: reason)
        try transition(&current, from: .finalizing, to: .failed, reason: reason)
        current.record.finishedAtUTC = nowUTC()
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
    current.record.finishedAtUTC = nowUTC()
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
      let targetID = jobs[jobID]?.record.request.target.targetID ?? ""
      let expectedBinding = jobs[jobID]?.record.request.target.expectedBindingRevision
      var resolvedFacts: ProviderFacts?
      if step.binding == .confirmedDevice {
        do {
          resolvedFacts = try await providers.resolveFacts(
            providerID: descriptor.provider.rawValue, targetID: targetID)
        } catch {
          if Self.requiresEvidencePreflight(descriptor),
            Self.isEvidencePreflightStep(step)
          {
            throw RuntimeDispatchFailure.failed(
              "evidenceIncomplete: descriptor-bound target facts unavailable: \(error)")
          }
          appendTimeline(jobID: jobID, entry: "target facts unavailable: \(error)")
        }
      }
      if Self.requiresEvidencePreflight(descriptor), Self.isEvidencePreflightStep(step) {
        try Self.validateEvidenceFacts(
          resolvedFacts, targetID: targetID, bindingRevision: expectedBinding,
          providerID: descriptor.provider.rawValue)
      } else if Self.requiresEvidencePreflight(descriptor),
        step.binding == .confirmedDevice
      {
        try requireCompleteEvidencePreflight(jobID: jobID, beforeStepID: step.stepID)
      }
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: targetID,
        bindingRevision: expectedBinding,
        connectKey: resolvedFacts?.executionConnectKey,
        expectedIdentitySHA256: resolvedFacts?.deviceIdentitySHA256,
        toolVersion: resolvedFacts?.toolVersion,
        toolSHA256: resolvedFacts?.toolSHA256,
        nowUTC: nowUTC())
      let plan: TypedProcessPlan
      do {
        plan = try provider.lower(action: action, context: context)
      } catch {
        if Self.requiresEvidencePreflight(descriptor),
          Self.isEvidencePreflightStep(step)
        {
          throw RuntimeDispatchFailure.failed(
            "evidenceIncomplete: typed preflight could not be lowered: \(error)")
        }
        throw error
      }
      do {
        try await dispatchWithWAL(
          jobID: jobID, step: step, action: action, plan: plan, provider: provider,
          context: context, descriptor: descriptor, evidenceFacts: resolvedFacts)
      } catch let failure as RuntimeDispatchFailure {
        // An unknown outcome always halts, optional or not: we cannot
        // continue past an effect whose result we do not know.
        if case .outcomeUnknown = failure { throw failure }
        guard step.isOptional else { throw failure }
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor, reason: "\(failure)")
      }
    }
    if Self.requiresEvidencePreflight(descriptor) {
      try requireCompleteEvidencePreflight(
        jobID: jobID, beforeStepID: "finish-operation")
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

  static let evidenceEligibleOperations: Set<String> = [
    "observe.device@1", "capture.diagnostics@1", "debug.hap@1",
  ]

  static func requiresEvidencePreflight(_ descriptor: CatalogOperationDescriptor) -> Bool {
    evidenceEligibleOperations.contains(descriptor.reference)
  }

  static func isEvidencePreflightStep(_ step: CatalogStepDescriptor) -> Bool {
    switch step.stepID {
    case "confirm-evidence-target":
      return step.kind == .probeDevice
    case "read-evidence-model":
      return step.kind == .runApprovedRemoteRead
        && step.actionReference?.catalogID == "arkdeck-remote-operations"
        && step.actionReference?.actionID == "deviceModel"
    case "read-evidence-firmware":
      return step.kind == .runApprovedRemoteRead
        && step.actionReference?.catalogID == "arkdeck-remote-operations"
        && step.actionReference?.actionID == "firmwareBuild"
    default:
      return false
    }
  }

  private static func validateEvidenceFacts(
    _ facts: ProviderFacts?,
    targetID: String,
    bindingRevision: Int?,
    providerID: String
  ) throws {
    guard let facts,
      facts.targetID == targetID,
      let expectedBinding = bindingRevision,
      facts.bindingRevision == expectedBinding,
      facts.providerID == providerID,
      let connectKey = facts.executionConnectKey,
      !connectKey.isEmpty,
      let identity = facts.deviceIdentitySHA256,
      isLowercaseSHA256(identity),
      !facts.toolVersion.isEmpty,
      isLowercaseSHA256(facts.toolSHA256)
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched")
    }
  }

  private func requireCompleteEvidencePreflight(
    jobID: String, beforeStepID: String
  ) throws {
    guard let record = jobs[jobID]?.record,
      record.evidencePreflight?.isComplete == true,
      record.evidenceObservation != nil
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: three-step typed preflight is incomplete before \(beforeStepID)")
    }
  }

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
    let binding = Self.artifactBindingSnapshot(for: runtime.record)
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
    descriptor: CatalogOperationDescriptor,
    evidenceFacts: ProviderFacts?
  ) async throws {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: runtime.record.request.inputs)
    let intentEventID = "intent-\(step.stepID)"
    // Journal target evidence mirrors the descriptor-bound facts without
    // persisting the raw connect key.
    let isDeviceBound = step.binding == .confirmedDevice
    let journalIdentity = context.expectedIdentitySHA256 ?? String(repeating: "0", count: 64)
    let intent = try JournalEvent.stepIntent(
      eventID: intentEventID, sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID, jobID: jobID,
      timestamp: nowUTC(), step: workflowStep,
      target: JournalTarget(
        scope: isDeviceBound ? "device" : "host",
        targetID: runtime.record.request.target.targetID,
        connectKey: isDeviceBound ? "sha256:\(journalIdentity)" : nil,
        identitySnapshotHash: isDeviceBound ? journalIdentity : nil),
      attempt: 1,
      bindingRevision: isDeviceBound
        ? (runtime.record.request.target.expectedBindingRevision ?? 1) : nil)
    // The write-ahead gate is the production dispatch path: the closure is
    // unreachable unless the intent is durable.
    let gate = WriteAheadIntentGate(journal: runtime.journal)
    try gate.dispatch(intent: intent) { () }
    runtime.nextSequence += 1
    runtime.record.timeline.append("intent \(step.stepID)")
    if runtime.record.actualStepKinds?.contains(step.kind.rawValue) != true {
      var kinds = runtime.record.actualStepKinds ?? []
      kinds.append(step.kind.rawValue)
      runtime.record.actualStepKinds = kinds
    }
    if runtime.record.firstEvidenceStepAtUTC == nil,
      step.binding == .confirmedDevice,
      !Self.isEvidencePreflightStep(step)
    {
      runtime.record.firstEvidenceStepAtUTC = context.nowUTC
    }
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
      let outcomeAt = nowUTC()
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: outcomeAt,
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "succeeded", outcomeCertainty: .confirmed))
      current.nextSequence += 1
      current.record.timeline.append("verified \(step.stepID) \(summary.keys.sorted())")
      jobs[jobID] = current
      try captureEvidencePreflightFragmentIfEligible(
        jobID: jobID, step: step, action: action, summary: summary,
        context: context, facts: evidenceFacts, outcomeAtUTC: outcomeAt,
        descriptor: descriptor)
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

  /// Consumes a fragment only after its successful outcome is durable.
  /// Failure to correlate or persist any fragment fails closed before a
  /// capture or mutation can be dispatched.
  private func captureEvidencePreflightFragmentIfEligible(
    jobID: String,
    step: CatalogStepDescriptor,
    action: TypedProviderAction,
    summary: [String: String],
    context: ProviderExecutionContext,
    facts: ProviderFacts?,
    outcomeAtUTC: String,
    descriptor: CatalogOperationDescriptor
  ) throws {
    guard Self.requiresEvidencePreflight(descriptor),
      Self.isEvidencePreflightStep(step)
    else { return }
    try Self.validateEvidenceFacts(
      facts, targetID: context.targetID, bindingRevision: context.bindingRevision,
      providerID: descriptor.provider.rawValue)
    guard let facts,
      let bindingRevision = facts.bindingRevision,
      let identity = facts.deviceIdentitySHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: validated preflight facts disappeared")
    }
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }

    var accumulator =
      runtime.record.evidencePreflight
      ?? RuntimeEvidencePreflightAccumulator(
        targetID: context.targetID,
        bindingRevision: bindingRevision,
        stableIdentitySHA256: identity,
        providerID: facts.providerID,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        transport: nil,
        confirmedAtUTC: nil,
        model: nil,
        firmware: nil,
        steps: [])
    guard accumulator.targetID == context.targetID,
      accumulator.bindingRevision == bindingRevision,
      accumulator.stableIdentitySHA256 == identity,
      accumulator.providerID == facts.providerID,
      accumulator.toolVersion == facts.toolVersion,
      accumulator.toolSHA256 == facts.toolSHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight fragments do not share one target/tool correlation")
    }

    let expectedStepIDs = [
      "confirm-evidence-target", "read-evidence-model", "read-evidence-firmware",
    ]
    guard accumulator.steps.count < expectedStepIDs.count,
      expectedStepIDs[accumulator.steps.count] == step.stepID
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight outcome is duplicated or out of order")
    }
    switch (step.stepID, action) {
    case ("confirm-evidence-target", .hdc(.observeDevice)):
      guard let observedIdentity = summary["deviceIdentitySHA256"],
        observedIdentity == identity,
        let transport = summary["transport"],
        ["usb", "tcp", "uart"].contains(transport)
      else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: target confirmation summary is incomplete or mismatched")
      }
      accumulator.transport = transport
    case ("read-evidence-model", .hdc(.queryProperty(.productModel))):
      guard let value = summary["value"], !value.isEmpty else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: model readback is empty")
      }
      accumulator.model = value
    case ("read-evidence-firmware", .hdc(.queryProperty(.fullBuildVersion))):
      guard let value = summary["value"], !value.isEmpty else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: firmware readback is empty")
      }
      accumulator.firmware = value
      // The evidence confirmation becomes fresh only when the complete
      // required prefix is durable, not when its first fragment was read.
      accumulator.confirmedAtUTC = outcomeAtUTC
    default:
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight action does not match its catalog step")
    }
    accumulator.steps.append(
      RuntimeEvidencePreflightStep(
        stepID: step.stepID, stepKind: step.kind.rawValue, outcomeAtUTC: outcomeAtUTC))
    runtime.record.evidencePreflight = accumulator
    runtime.record.timeline.append("evidence-preflight \(step.stepID)")

    if accumulator.isComplete {
      runtime.record.evidenceObservation = RuntimeEvidenceObservation(
        targetID: accumulator.targetID,
        bindingRevision: accumulator.bindingRevision,
        stableIdentitySHA256: accumulator.stableIdentitySHA256,
        model: accumulator.model,
        firmware: accumulator.firmware,
        transport: accumulator.transport,
        providerID: accumulator.providerID,
        toolVersion: accumulator.toolVersion,
        toolSHA256: accumulator.toolSHA256,
        confirmedAtUTC: accumulator.confirmedAtUTC,
        confirmationMethod: "machineReadback",
        preflightSteps: accumulator.steps)
      // observe.device publishes its evidence-bearing products from the
      // final preflight outcome itself; the other operations set this at
      // their first post-preflight device step.
      if descriptor.reference == "observe.device@1",
        runtime.record.firstEvidenceStepAtUTC == nil
      {
        runtime.record.firstEvidenceStepAtUTC = outcomeAtUTC
      }
    }
    do {
      try runtime.record.persist(into: jobDirectory(for: jobID))
      jobs[jobID] = runtime
    } catch {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: could not persist preflight fragment: \(error)")
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
    let binding = Self.artifactBindingSnapshot(for: runtime.record)
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
      "read-evidence-firmware": ["device-facts.json", "binding-snapshot.json"],
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
    let binding = Self.artifactBindingSnapshot(for: runtime.record)

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
    if let observation = record.evidenceObservation {
      if let model = observation.model { fields["model"] = .string(model) }
      if let firmware = observation.firmware { fields["firmware"] = .string(firmware) }
      if let transport = observation.transport { fields["transport"] = .string(transport) }
      if let identity = observation.stableIdentitySHA256 {
        fields["stableIdentitySha256"] = .string(identity)
      }
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

  private static func artifactBindingSnapshot(
    for record: RuntimeJobRecord
  ) -> ArtifactBindingSnapshot {
    ArtifactBindingSnapshot(
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      stableIdentitySHA256: record.evidenceObservation?.stableIdentitySHA256)
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

  public func evidenceSnapshot(jobID: String) throws -> RuntimeJobEvidenceSnapshot {
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let record = runtime.record
    return RuntimeJobEvidenceSnapshot(
      jobID: record.jobID,
      operationReference: record.operationReference,
      catalogDigest: record.catalogDigest,
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      providerID: record.providerID,
      actualEffect: record.actualEffect,
      authority: record.admissionEvidence,
      observation: record.evidenceObservation,
      actualStepKinds: record.actualStepKinds ?? [],
      executionMode: "execute",
      terminalState: record.outcomeUnknown ? "outcomeUnknown" : record.state,
      outcomeUnknown: record.outcomeUnknown,
      startedAtUTC: record.startedAtUTC,
      firstEvidenceStepAtUTC: record.firstEvidenceStepAtUTC,
      finishedAtUTC: record.finishedAtUTC)
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
  ) async throws -> RuntimeAdmissionEvidence {
    let admittedAt = nowUTC()
    if effect <= .readOnly {
      let decision = configuration.defaultReadOnlyPolicy.evaluate(
        effect: effect,
        timeoutSeconds: descriptor.timeoutSeconds,
        outputByteBudget: descriptor.outputByteBudget)
      guard decision == .allowed else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired, "default read-only policy denied: \(decision)")
      }
      return RuntimeAdmissionEvidence(
        kind: .defaultReadOnlyPolicy,
        reference: "default-read-only-policy",
        admittedAtUTC: admittedAt,
        validUntilUTC: nil,
        consumptionFingerprintSHA256: nil)
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
      let consumption = try await capabilityStore.consume(
        capabilityID: authorization.capabilityID,
        reservationID: request.idempotencyKey,
        query: query,
        nowUTC: admittedAt)
      guard let status = try await capabilityStore.inspect(
        capabilityID: authorization.capabilityID)
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(authorization.capabilityID)
      }
      return RuntimeAdmissionEvidence(
        kind: effect == .destructive ? .standingAuthorization : .runtimeCapability,
        reference: authorization.capabilityID,
        admittedAtUTC: consumption.consumedAtUTC,
        validUntilUTC: status.capability.expiresAtUTC,
        consumptionFingerprintSHA256: consumption.queryFingerprintSHA256)
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

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
      ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
    }
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
      // The action identity comes from the catalog's own actionRef, never
      // from a guess here. CHG-2026-050 exists because an earlier version
      // of this table labelled the HiLog step with a UI-dump action: the
      // journal would then have recorded an intent the step never had,
      // which is fabricated evidence rather than a naming slip.
      guard let reference = step.actionReference else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) captures stdout but declares no catalog action; "
            + "refusing to invent one for the durable intent")
      }
      var parameters: [String: JSONValue] = [:]
      switch reference.actionID {
      case "boundedHilog":
        var duration = 30
        if case .integer(let requested)? = inputs["durationSeconds"] {
          duration = max(1, min(Int(requested), 600))
        } else if case .integer(let requested)? = inputs["diagnosticsDurationSeconds"] {
          duration = max(1, min(Int(requested), 600))
        }
        var filters: [JSONValue] = []
        if case .array(let requested)? = inputs["hilogFilters"] {
          filters = requested.filter {
            if case .string = $0 { return true }
            return false
          }
        }
        var budget = 16 * 1024 * 1024
        if case .integer(let requested)? = inputs["totalArtifactByteBudget"] {
          budget = max(1024, min(Int(requested), 134_217_728))
        }
        parameters = [
          "durationSeconds": .integer(Int64(duration)),
          "filters": .array(Array(filters.prefix(16))),
          "byteBudget": .integer(Int64(budget)),
        ]
      case "componentTree":
        parameters = ["byteBudget": .integer(8 * 1024 * 1024)]
      default:
        throw RuntimeJobEngineError.internalFailure(
          "unregistered stdout action \(reference.actionID) for \(step.stepID)")
      }
      arguments = [
        "catalogId": .string(reference.catalogID),
        "actionId": .string(reference.actionID),
        "parameters": .object(parameters),
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
      guard let reference = step.actionReference,
        reference.catalogID == "arkdeck-remote-operations"
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no arkdeck-remote-operations actionRef")
      }
      arguments = [
        "catalogId": .string(reference.catalogID),
        "actionId": .string(reference.actionID),
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
  public let actualEffect: String?
  public let admissionEvidence: RuntimeAdmissionEvidence?
  public var state: String = "queued"
  public var outcomeUnknown: Bool = false
  public var timeline: [String] = []
  public var evidencePreflight: RuntimeEvidencePreflightAccumulator?
  public var evidenceObservation: RuntimeEvidenceObservation?
  public var actualStepKinds: [String]?
  public var startedAtUTC: String?
  public var firstEvidenceStepAtUTC: String?
  public var finishedAtUTC: String?
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
