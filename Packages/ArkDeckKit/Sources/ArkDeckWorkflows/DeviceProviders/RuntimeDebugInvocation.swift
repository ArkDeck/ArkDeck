// Protected Runtime-owned Flash debug invocation and Provider repair envelope
// (CHG-2026-056 r10).
//
// An isolated candidate can return only RuntimeCandidateDecision. This actor
// pins the original typed request, maps a reviewed decision to bounded
// provider tuning, and drives every real attempt through RuntimeJobEngine.
// It never accepts authority, target, inputs, a plan, argv or trusted facts
// from the candidate.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import CryptoKit
import Foundation

public enum RuntimeDebugInvocationError: Error, Equatable, Sendable {
  case invalidSeedRequest(String)
  case invalidCandidate(String)
  case repairSurfaceInsufficient(String)
  case invalidProvenance(String)
  case invocationNotFound(String)
  case invocationNotActive(String)
  case invocationExpired
  case epochBudgetExhausted
  case candidateNotMateriallyDistinct
  case evaluationAlreadyRunning
  case predecessorBlocksContinuation(String)
  case persistenceFailure(String)
}

public enum RuntimeDebugExecutionOutcome: String, Codable, Equatable, Sendable {
  case succeeded
  case safeToReflash
  case outcomeUnknown
  case failedKnown
  case refused
}

public struct RuntimeDebugDriverResult: Codable, Equatable, Sendable {
  public let jobID: String?
  public let outcome: RuntimeDebugExecutionOutcome
  public let detail: String

  public init(jobID: String?, outcome: RuntimeDebugExecutionOutcome, detail: String) {
    self.jobID = jobID
    self.outcome = outcome
    self.detail = detail
  }
}

/// Testable seam at the protected Runtime boundary. Production uses
/// RuntimeJobEngineDebugAttemptDriver; fake implementations are mechanical
/// contract evidence and can never be reported as device evidence.
public protocol RuntimeDebugAttemptDriving: Sendable {
  func prepare(_ requestData: Data) async throws -> RuntimePlanOnlyPreview
  func execute(_ requestData: Data) async -> RuntimeDebugDriverResult
}

public struct RuntimeDebugCandidateProvenance: Codable, Equatable, Sendable {
  public let sourceSHA256: String
  public let buildSHA256: String

  public init(sourceSHA256: String, buildSHA256: String) throws {
    guard Self.isSHA256(sourceSHA256), Self.isSHA256(buildSHA256) else {
      throw RuntimeDebugInvocationError.invalidProvenance(
        "candidate source and build provenance must be lowercase SHA-256")
    }
    self.sourceSHA256 = sourceSHA256
    self.buildSHA256 = buildSHA256
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }
}

public struct RuntimeDebugObservation: Codable, Equatable, Sendable {
  public let observationID: String
  public let materializedPlanDigest: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let dispatchDisposition: String
}

public struct RuntimeDebugEvaluation: Codable, Equatable, Sendable {
  public let ordinal: Int
  public let destructiveEpoch: Int?
  public let candidateSourceSHA256: String
  public let candidateBuildSHA256: String
  public let decisionSHA256: String
  public let decisionKind: String
  public let requestID: String?
  public let idempotencyKey: String?
  public let jobID: String?
  public let outcome: RuntimeDebugExecutionOutcome?
  public let disposition: String
  public let detail: String
  public let evaluatedAtUTC: String
  public let observation: RuntimeDebugObservation?
}

public struct RuntimeDebugInvocationStatus: Codable, Equatable, Sendable {
  public let invocationID: String
  public let state: String
  public let operationReference: String
  public let targetID: String
  public let bindingRevision: Int?
  public let seedRequestFingerprintSHA256: String
  public let baselineMaterializedPlanDigest: String
  public let createdAtUTC: String
  public let expiresAtUTC: String
  public let destructiveEpochsUsed: Int
  public let maximumDestructiveEpochs: Int
  public let evaluations: [RuntimeDebugEvaluation]
}

/// Durable per-attempt provenance consumed by RuntimeJobEngine while it
/// materializes and executes the exact generated request. The file is not an
/// authority: it cannot mint a capability or bypass normal admission.
struct RuntimeDebugAttemptTuningRecord: Codable, Equatable, Sendable {
  static let schemaVersion = "1.0.0"
  let schemaVersion: String
  let invocationID: String
  let idempotencyKey: String
  let requestFingerprintSHA256: String
  let decisionSHA256: String
  let tuning: AgentAuthorityCampaignExecutionTuning
}

enum RuntimeDebugAttemptTuningStore {
  static func persist(
    stateDirectory: URL,
    invocationID: String,
    request: RuntimeOperationRequest,
    decisionSHA256: String,
    tuning: AgentAuthorityCampaignExecutionTuning
  ) throws {
    let encodedRequest = try canonicalEncode(request)
    let record = RuntimeDebugAttemptTuningRecord(
      schemaVersion: RuntimeDebugAttemptTuningRecord.schemaVersion,
      invocationID: invocationID,
      idempotencyKey: request.idempotencyKey,
      requestFingerprintSHA256: sha256(encodedRequest),
      decisionSHA256: decisionSHA256,
      tuning: tuning)
    try DurableFileWriter.createOrReplaceAtomically(
      destination: url(stateDirectory: stateDirectory, idempotencyKey: request.idempotencyKey),
      data: try canonicalEncode(record))
  }

  static func loadExact(
    stateDirectory: URL, request: RuntimeOperationRequest, nowUTC: String? = nil
  ) throws -> RuntimeDebugAttemptTuningRecord? {
    let location = url(stateDirectory: stateDirectory, idempotencyKey: request.idempotencyKey)
    guard FileManager.default.fileExists(atPath: location.path) else { return nil }
    let record = try JSONDecoder().decode(
      RuntimeDebugAttemptTuningRecord.self, from: Data(contentsOf: location))
    guard request.campaignReservation == nil, request.clientContext == nil else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Runtime debug attempt cannot gain campaign or client provenance")
    }
    // Submit persists the Runtime-minted capability reference on the Job.
    // It is deliberately removed only for this fingerprint comparison; the
    // capability is still validated, reserved and consumed by the ordinary
    // Job path. Every candidate-controlled request field remains exact.
    let unsigned = try RuntimeOperationRequest(
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      target: request.target,
      operation: request.operation,
      inputs: request.inputs,
      requestedOutputs: request.requestedOutputs)
    guard record.schemaVersion == RuntimeDebugAttemptTuningRecord.schemaVersion,
      record.idempotencyKey == request.idempotencyKey,
      record.requestFingerprintSHA256 == sha256(try canonicalEncode(unsigned))
    else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Runtime debug attempt provenance does not match the typed request")
    }
    if let nowUTC {
      let invocationURL = stateDirectory
        .appendingPathComponent("runtime-debug-invocations", isDirectory: true)
        .appendingPathComponent("\(record.invocationID).json")
      let invocation = try JSONDecoder().decode(
        RuntimeDebugInvocationDocument.self, from: Data(contentsOf: invocationURL))
      let formatter = ISO8601DateFormatter()
      guard invocation.schemaVersion == RuntimeDebugInvocationDocument.schemaVersion,
        invocation.invocationID == record.invocationID,
        invocation.state == "active",
        invocation.destructiveEpochsUsed <= RuntimeDebugInvocationController.maximumDestructiveEpochs,
        let now = formatter.date(from: nowUTC),
        let expiry = formatter.date(from: invocation.expiresAtUTC),
        now <= expiry,
        invocation.evaluations.contains(where: {
          $0.disposition == "executing"
            && $0.idempotencyKey == request.idempotencyKey
            && $0.decisionSHA256 == record.decisionSHA256
            && $0.destructiveEpoch != nil
        })
      else {
        throw RuntimeDebugInvocationError.persistenceFailure(
          "Runtime debug attempt has no active, in-budget invocation dispatch permit")
      }
    }
    return record
  }

  private static func url(stateDirectory: URL, idempotencyKey: String) -> URL {
    stateDirectory
      .appendingPathComponent("runtime-debug-attempts", isDirectory: true)
      .appendingPathComponent("\(idempotencyKey).json")
  }

  static func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct RuntimeDebugInvocationDocument: Codable, Equatable, Sendable {
  static let schemaVersion = "1.0.0"
  let schemaVersion: String
  let invocationID: String
  var state: String
  let seedRequest: RuntimeOperationRequest
  let seedRequestFingerprintSHA256: String
  let baselineMaterializedPlanDigest: String
  let createdAtUTC: String
  let expiresAtUTC: String
  var destructiveEpochsUsed: Int
  var evaluations: [RuntimeDebugEvaluation]
}

public actor RuntimeDebugInvocationController {
  public static let maximumDestructiveEpochs = 16
  public static let maximumDurationSeconds: TimeInterval = 4 * 60 * 60

  private let stateDirectory: URL
  private let driver: any RuntimeDebugAttemptDriving
  private let nowUTC: @Sendable () -> String
  private var activeEvaluations: Set<String> = []

  public init(
    stateDirectory: URL,
    driver: any RuntimeDebugAttemptDriving,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.stateDirectory = stateDirectory
    self.driver = driver
    self.nowUTC = nowUTC
    try FileManager.default.createDirectory(
      at: stateDirectory.appendingPathComponent(
        "runtime-debug-invocations", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  public func start(seedRequestData: Data) async throws -> RuntimeDebugInvocationStatus {
    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationCodec.decodeRequest(seedRequestData)
    } catch {
      throw RuntimeDebugInvocationError.invalidSeedRequest("\(error)")
    }
    guard request.operation.reference == "flash.dayu200",
      request.target.expectedBindingRevision != nil,
      request.authorization == nil,
      request.campaignReservation == nil,
      request.clientContext == nil
    else {
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "debug invocation requires one unprivileged, binding-pinned flash.dayu200 request")
    }
    let preview = try await driver.prepare(seedRequestData)
    guard preview.operationReference == request.operation.reference,
      preview.targetID == request.target.targetID,
      preview.bindingRevision == request.target.expectedBindingRevision,
      preview.inputs == request.inputs,
      !preview.jobAdmitted,
      preview.dispatchDisposition == "notDispatched"
    else {
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "Runtime plan-only preview drifted from the pinned seed request")
    }
    let canonicalRequest = try RuntimeDebugAttemptTuningStore.canonicalEncode(request)
    let created = try currentDate()
    let invocationID = "debug-\(UUID().uuidString.lowercased())"
    let document = RuntimeDebugInvocationDocument(
      schemaVersion: RuntimeDebugInvocationDocument.schemaVersion,
      invocationID: invocationID,
      state: "active",
      seedRequest: request,
      seedRequestFingerprintSHA256: RuntimeDebugAttemptTuningStore.sha256(canonicalRequest),
      baselineMaterializedPlanDigest: preview.materializedPlanDigest,
      createdAtUTC: format(created),
      expiresAtUTC: format(created.addingTimeInterval(Self.maximumDurationSeconds)),
      destructiveEpochsUsed: 0,
      evaluations: [])
    try persist(document)
    return status(document)
  }

  public func status(invocationID: String) throws -> RuntimeDebugInvocationStatus {
    status(try load(invocationID))
  }

  public func evaluate(
    invocationID: String,
    candidateData: Data,
    provenance: RuntimeDebugCandidateProvenance
  ) async throws -> RuntimeDebugInvocationStatus {
    guard !activeEvaluations.contains(invocationID) else {
      throw RuntimeDebugInvocationError.evaluationAlreadyRunning
    }
    activeEvaluations.insert(invocationID)
    defer { activeEvaluations.remove(invocationID) }

    var document = try load(invocationID)
    guard document.state == "active" else {
      throw RuntimeDebugInvocationError.invocationNotActive(document.state)
    }
    guard try currentDate() <= parse(document.expiresAtUTC) else {
      document.state = "expired"
      try persist(document)
      throw RuntimeDebugInvocationError.invocationExpired
    }

    let decision: RuntimeCandidateDecision
    do {
      decision = try RuntimeCandidateDecisionCodec.decode(
        candidateData, envelope: Self.dayu200Envelope)
    } catch let error as RuntimeCandidateDecisionError {
      switch error {
      case .alternativeNotPublished(let value), .observationNotPublished(let value),
        .timingNotPublished(let value):
        throw RuntimeDebugInvocationError.repairSurfaceInsufficient(value)
      default:
        throw RuntimeDebugInvocationError.invalidCandidate("\(error)")
      }
    } catch {
      throw RuntimeDebugInvocationError.invalidCandidate("\(error)")
    }
    let canonicalDecision = try Self.canonicalDecisionData(decision)
    let decisionSHA256 = RuntimeDebugAttemptTuningStore.sha256(canonicalDecision)
    if let index = document.evaluations.indices.last,
      document.evaluations[index].disposition == "executing"
    {
      let interrupted = document.evaluations[index]
      guard interrupted.decisionSHA256 == decisionSHA256,
        interrupted.candidateSourceSHA256 == provenance.sourceSHA256,
        interrupted.candidateBuildSHA256 == provenance.buildSHA256,
        let requestID = interrupted.requestID,
        let idempotencyKey = interrupted.idempotencyKey
      else {
        throw RuntimeDebugInvocationError.predecessorBlocksContinuation(
          "an interrupted attempt must resume its exact candidate and provenance")
      }
      let resumed = try RuntimeOperationRequest(
        requestID: requestID,
        idempotencyKey: idempotencyKey,
        target: document.seedRequest.target,
        operation: document.seedRequest.operation,
        inputs: document.seedRequest.inputs,
        requestedOutputs: document.seedRequest.requestedOutputs)
      try RuntimeDebugAttemptTuningStore.persist(
        stateDirectory: stateDirectory,
        invocationID: invocationID,
        request: resumed,
        decisionSHA256: decisionSHA256,
        tuning: try Self.tuning(for: decision))
      let result = await driver.execute(
        try RuntimeDebugAttemptTuningStore.canonicalEncode(resumed))
      return try finish(result, at: index, document: &document)
    }
    if document.evaluations.contains(where: {
      $0.decisionSHA256 == decisionSHA256
    }) {
      throw RuntimeDebugInvocationError.candidateNotMateriallyDistinct
    }

    let ordinal = document.evaluations.count + 1
    switch decision {
    case .stop(let reasonCode):
      document.state = "stopped"
      document.evaluations.append(
        evaluation(
          ordinal: ordinal, epoch: nil, provenance: provenance,
          decisionSHA256: decisionSHA256, kind: "stop", disposition: "stopped",
          detail: reasonCode))
      try persist(document)
      return status(document)

    case .requestPublishedObservation(let observationID):
      let seed = try RuntimeDebugAttemptTuningStore.canonicalEncode(document.seedRequest)
      let preview = try await driver.prepare(seed)
      let observation = RuntimeDebugObservation(
        observationID: observationID,
        materializedPlanDigest: preview.materializedPlanDigest,
        targetID: preview.targetID,
        bindingRevision: preview.bindingRevision,
        stableIdentitySHA256: preview.stableIdentitySHA256,
        dispatchDisposition: preview.dispatchDisposition)
      document.evaluations.append(
        evaluation(
          ordinal: ordinal, epoch: nil, provenance: provenance,
          decisionSHA256: decisionSHA256, kind: "requestPublishedObservation",
          disposition: "observed", detail: "fresh Runtime plan-only observation",
          observation: observation))
      try persist(document)
      return status(document)

    case .usePublishedDefaults, .selectPublishedAlternative, .boundedTiming:
      break
    }

    if let predecessor = document.evaluations.last, predecessor.destructiveEpoch != nil {
      switch predecessor.outcome {
      case .safeToReflash, .outcomeUnknown:
        break
      case .none where predecessor.disposition == "executing":
        guard predecessor.decisionSHA256 == decisionSHA256 else {
          throw RuntimeDebugInvocationError.predecessorBlocksContinuation(
            "an interrupted attempt must resume its exact candidate")
        }
      default:
        throw RuntimeDebugInvocationError.predecessorBlocksContinuation(
          predecessor.outcome?.rawValue ?? predecessor.disposition)
      }
    }
    guard document.destructiveEpochsUsed < Self.maximumDestructiveEpochs else {
      throw RuntimeDebugInvocationError.epochBudgetExhausted
    }

    let tuning = try Self.tuning(for: decision)
    let epoch = document.destructiveEpochsUsed + 1
    let requestID = "debug-\(String(invocationID.suffix(12)))-e\(epoch)"
    let idempotencyKey = "runtime-debug-\(String(invocationID.suffix(12)))-e\(epoch)-\(decisionSHA256.prefix(12))"
    let generated: RuntimeOperationRequest
    do {
      generated = try RuntimeOperationRequest(
        requestID: requestID,
        idempotencyKey: idempotencyKey,
        target: document.seedRequest.target,
        operation: document.seedRequest.operation,
        inputs: document.seedRequest.inputs,
        requestedOutputs: document.seedRequest.requestedOutputs)
    } catch {
      throw RuntimeDebugInvocationError.invalidSeedRequest("cannot derive attempt request: \(error)")
    }
    try RuntimeDebugAttemptTuningStore.persist(
      stateDirectory: stateDirectory,
      invocationID: invocationID,
      request: generated,
      decisionSHA256: decisionSHA256,
      tuning: tuning)
    let generatedData = try RuntimeDebugAttemptTuningStore.canonicalEncode(generated)

    document.destructiveEpochsUsed = epoch
    document.evaluations.append(
      evaluation(
        ordinal: ordinal, epoch: epoch, provenance: provenance,
        decisionSHA256: decisionSHA256, kind: Self.kind(of: decision),
        requestID: requestID, idempotencyKey: idempotencyKey,
        disposition: "executing", detail: "Runtime attempt durably prepared"))
    try persist(document)

    let result = await driver.execute(generatedData)
    guard let index = document.evaluations.indices.last else {
      throw RuntimeDebugInvocationError.persistenceFailure("prepared evaluation disappeared")
    }
    return try finish(result, at: index, document: &document)
  }

  private func finish(
    _ result: RuntimeDebugDriverResult,
    at index: Int,
    document: inout RuntimeDebugInvocationDocument
  ) throws -> RuntimeDebugInvocationStatus {
    let disposition: String
    switch result.outcome {
    case .succeeded:
      disposition = "succeeded"
      document.state = "succeeded"
    case .safeToReflash:
      disposition = "nextCandidateAllowed"
    case .outcomeUnknown:
      disposition = "awaitingRuntimeRecoveryProof"
    case .failedKnown:
      disposition = "blockedKnownFailure"
      document.state = "blocked"
    case .refused:
      disposition = "refusedBeforeDispatch"
      document.destructiveEpochsUsed -= 1
    }
    let prepared = document.evaluations[index]
    document.evaluations[index] = RuntimeDebugEvaluation(
      ordinal: prepared.ordinal,
      destructiveEpoch: result.jobID == nil ? nil : prepared.destructiveEpoch,
      candidateSourceSHA256: prepared.candidateSourceSHA256,
      candidateBuildSHA256: prepared.candidateBuildSHA256,
      decisionSHA256: prepared.decisionSHA256,
      decisionKind: prepared.decisionKind,
      requestID: prepared.requestID,
      idempotencyKey: prepared.idempotencyKey,
      jobID: result.jobID,
      outcome: result.outcome,
      disposition: disposition,
      detail: result.detail,
      evaluatedAtUTC: nowUTC(),
      observation: nil)
    try persist(document)
    return status(document)
  }

  private var invocationDirectory: URL {
    stateDirectory.appendingPathComponent("runtime-debug-invocations", isDirectory: true)
  }

  private func url(_ invocationID: String) -> URL {
    invocationDirectory.appendingPathComponent("\(invocationID).json")
  }

  private func load(_ invocationID: String) throws -> RuntimeDebugInvocationDocument {
    guard invocationID.utf8.count <= 128,
      invocationID.range(
        of: #"^[a-z][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil
    else {
      throw RuntimeDebugInvocationError.invocationNotFound(invocationID)
    }
    do {
      let document = try JSONDecoder().decode(
        RuntimeDebugInvocationDocument.self, from: Data(contentsOf: url(invocationID)))
      guard document.schemaVersion == RuntimeDebugInvocationDocument.schemaVersion,
        document.invocationID == invocationID,
        document.destructiveEpochsUsed >= 0,
        document.destructiveEpochsUsed <= Self.maximumDestructiveEpochs
      else {
        throw RuntimeDebugInvocationError.persistenceFailure("invalid invocation document")
      }
      return document
    } catch let error as RuntimeDebugInvocationError {
      throw error
    } catch {
      throw RuntimeDebugInvocationError.invocationNotFound(invocationID)
    }
  }

  private func persist(_ document: RuntimeDebugInvocationDocument) throws {
    do {
      try DurableFileWriter.createOrReplaceAtomically(
        destination: url(document.invocationID),
        data: try RuntimeDebugAttemptTuningStore.canonicalEncode(document))
    } catch {
      throw RuntimeDebugInvocationError.persistenceFailure("\(error)")
    }
  }

  private func status(_ document: RuntimeDebugInvocationDocument) -> RuntimeDebugInvocationStatus {
    RuntimeDebugInvocationStatus(
      invocationID: document.invocationID,
      state: document.state,
      operationReference: document.seedRequest.operation.reference,
      targetID: document.seedRequest.target.targetID,
      bindingRevision: document.seedRequest.target.expectedBindingRevision,
      seedRequestFingerprintSHA256: document.seedRequestFingerprintSHA256,
      baselineMaterializedPlanDigest: document.baselineMaterializedPlanDigest,
      createdAtUTC: document.createdAtUTC,
      expiresAtUTC: document.expiresAtUTC,
      destructiveEpochsUsed: document.destructiveEpochsUsed,
      maximumDestructiveEpochs: Self.maximumDestructiveEpochs,
      evaluations: document.evaluations)
  }

  private func evaluation(
    ordinal: Int,
    epoch: Int?,
    provenance: RuntimeDebugCandidateProvenance,
    decisionSHA256: String,
    kind: String,
    requestID: String? = nil,
    idempotencyKey: String? = nil,
    disposition: String,
    detail: String,
    observation: RuntimeDebugObservation? = nil
  ) -> RuntimeDebugEvaluation {
    RuntimeDebugEvaluation(
      ordinal: ordinal, destructiveEpoch: epoch,
      candidateSourceSHA256: provenance.sourceSHA256,
      candidateBuildSHA256: provenance.buildSHA256,
      decisionSHA256: decisionSHA256, decisionKind: kind,
      requestID: requestID, idempotencyKey: idempotencyKey, jobID: nil,
      outcome: nil, disposition: disposition, detail: detail,
      evaluatedAtUTC: nowUTC(), observation: observation)
  }

  private func currentDate() throws -> Date {
    try parse(nowUTC())
  }

  private func parse(_ value: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
      throw RuntimeDebugInvocationError.persistenceFailure("Runtime clock is not ISO-8601")
    }
    return date
  }

  private func format(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static let dayu200Envelope: RuntimeCandidateRepairEnvelope = {
    try! RuntimeCandidateRepairEnvelope(
      alternativeIDs: [
        "balancedDefaults", "fastLoaderDetection", "patientModeTransition",
        "extendedPostflight",
      ],
      observationIDs: ["freshPlan", "currentTarget", "postflightReadiness"],
      timingBounds: [
        "loaderDiscoveryTimeoutSeconds": try RuntimeCandidateTimingBounds(
          minimum: 15, maximum: 120),
        "loaderPollIntervalMilliseconds": try RuntimeCandidateTimingBounds(
          minimum: 100, maximum: 2_000),
        "hdcCommandTimeoutSeconds": try RuntimeCandidateTimingBounds(
          minimum: 5, maximum: 60),
        "readOnlyCommandTimeoutSeconds": try RuntimeCandidateTimingBounds(
          minimum: 5, maximum: 60),
      ])
  }()

  private static func tuning(
    for decision: RuntimeCandidateDecision
  ) throws -> AgentAuthorityCampaignExecutionTuning {
    var values = (loader: 120, poll: 500, hdc: 20, readOnly: 15)
    switch decision {
    case .usePublishedDefaults:
      break
    case .selectPublishedAlternative(let identifier):
      switch identifier {
      case "balancedDefaults": break
      case "fastLoaderDetection": values = (60, 250, 20, 15)
      case "patientModeTransition": values = (120, 1_000, 30, 20)
      case "extendedPostflight": values = (120, 500, 45, 60)
      default:
        throw RuntimeDebugInvocationError.invalidCandidate("unpublished alternative")
      }
    case .boundedTiming(let parameter, let value):
      switch parameter {
      case "loaderDiscoveryTimeoutSeconds": values.loader = value
      case "loaderPollIntervalMilliseconds": values.poll = value
      case "hdcCommandTimeoutSeconds": values.hdc = value
      case "readOnlyCommandTimeoutSeconds": values.readOnly = value
      default:
        throw RuntimeDebugInvocationError.invalidCandidate("unpublished timing")
      }
    case .requestPublishedObservation, .stop:
      throw RuntimeDebugInvocationError.invalidCandidate("decision does not execute")
    }
    return try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: values.loader,
      loaderPollIntervalMilliseconds: values.poll,
      hdcCommandTimeoutSeconds: values.hdc,
      readOnlyCommandTimeoutSeconds: values.readOnly)
  }

  private static func kind(of decision: RuntimeCandidateDecision) -> String {
    switch decision {
    case .usePublishedDefaults: return "usePublishedDefaults"
    case .selectPublishedAlternative: return "selectPublishedAlternative"
    case .boundedTiming: return "boundedTiming"
    case .requestPublishedObservation: return "requestPublishedObservation"
    case .stop: return "stop"
    }
  }

  private static func canonicalDecisionData(_ decision: RuntimeCandidateDecision) throws -> Data {
    var object: [String: JSONValue] = [
      "schemaVersion": .string(RuntimeCandidateDecisionCodec.schemaVersion),
      "kind": .string(kind(of: decision)),
    ]
    switch decision {
    case .usePublishedDefaults: break
    case .selectPublishedAlternative(let identifier):
      object["alternativeId"] = .string(identifier)
    case .boundedTiming(let parameter, let value):
      object["parameter"] = .string(parameter)
      object["value"] = .integer(Int64(value))
    case .requestPublishedObservation(let identifier):
      object["observationId"] = .string(identifier)
    case .stop(let reasonCode):
      object["reasonCode"] = .string(reasonCode)
    }
    return try RuntimeDebugAttemptTuningStore.canonicalEncode(object)
  }
}

public struct RuntimeJobEngineDebugAttemptDriver: RuntimeDebugAttemptDriving {
  private let engine: RuntimeJobEngine

  public init(engine: RuntimeJobEngine) {
    self.engine = engine
  }

  public func prepare(_ requestData: Data) async throws -> RuntimePlanOnlyPreview {
    try await engine.planOnly(requestData)
  }

  public func execute(_ requestData: Data) async -> RuntimeDebugDriverResult {
    do {
      let acceptance = try await engine.submit(requestData)
      do {
        let status = try await engine.run(jobID: acceptance.jobID)
        let outcome = try await engine.runtimeDebugExecutionOutcome(jobID: acceptance.jobID)
        return RuntimeDebugDriverResult(
          jobID: acceptance.jobID, outcome: outcome,
          detail: "Runtime Job terminal state \(status.state)")
      } catch {
        // Once admission returned a Job ID this is never a pre-dispatch
        // refusal. Preserve the epoch and fail closed if its durable outcome
        // cannot be classified; otherwise a transport/process failure could
        // be mislabeled free and allow an unsafe next attempt.
        let outcome =
          (try? await engine.runtimeDebugExecutionOutcome(jobID: acceptance.jobID))
          ?? .outcomeUnknown
        return RuntimeDebugDriverResult(
          jobID: acceptance.jobID, outcome: outcome,
          detail: "Runtime Job failed after admission: \(error)")
      }
    } catch let error as RuntimeJobEngineError {
      return RuntimeDebugDriverResult(jobID: nil, outcome: .refused, detail: "\(error)")
    } catch {
      return RuntimeDebugDriverResult(jobID: nil, outcome: .refused, detail: "\(error)")
    }
  }
}
