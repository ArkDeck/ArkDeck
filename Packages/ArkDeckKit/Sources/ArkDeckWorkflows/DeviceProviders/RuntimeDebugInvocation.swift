// Protected Runtime-owned Flash debug invocation and effect broker
// (CHG-2026-056 r12).
//
// An isolated candidate may change arbitrary non-kernel product code. Its
// only interaction with the protected Runtime is one effect-level action:
// observe the pinned request, execute it through RuntimeJobEngine, or stop.
// The broker never accepts authority, target, inputs, a plan, argv, timing
// controls or trusted facts from candidate code.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation

public enum RuntimeDebugInvocationError: Error, Equatable, Sendable {
  case invalidSeedRequest(String)
  case invalidCandidate(String)
  case invalidProvenance(String)
  case invocationNotFound(String)
  case invocationNotActive(String)
  case invocationExpired
  case epochBudgetExhausted
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
  package let sourceSHA256: String
  package let buildSHA256: String

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

/// The effect-level boundary between arbitrary candidate orchestration and
/// protected-main Runtime. These are not repair kinds: a new product failure
/// does not require a new case. `executePinnedRequest` can only ask the broker
/// to re-materialize the exact seed request; `observePinnedRequest` is
/// plan-only and dispatch-free.
package enum RuntimeDebugCandidateAction: Equatable, Sendable {
  case observePinnedRequest
  case executePinnedRequest
  case stop(reasonCode: String)
}

public enum RuntimeDebugCandidateActionError: Error, Equatable, Sendable {
  case invalidDocument
  case unsupportedSchemaVersion
  case unsupportedAction
  case closedShapeViolation
  case invalidReasonCode
}

package enum RuntimeDebugCandidateActionCodec {
  package static let schemaVersion = "1.0.0"
  package static let maximumDocumentBytes = 8 * 1_024

  package static func decode(_ data: Data) throws -> RuntimeDebugCandidateAction {
    guard !data.isEmpty, data.count <= maximumDocumentBytes else {
      throw RuntimeDebugCandidateActionError.invalidDocument
    }
    let object: [String: JSONValue]
    do {
      object = try strictObject(from: data)
    } catch {
      throw RuntimeDebugCandidateActionError.invalidDocument
    }
    guard case .string(let version)? = object["schemaVersion"],
      version == schemaVersion
    else {
      throw RuntimeDebugCandidateActionError.unsupportedSchemaVersion
    }
    guard case .string(let action)? = object["action"] else {
      throw RuntimeDebugCandidateActionError.unsupportedAction
    }
    switch action {
    case "observePinnedRequest":
      try requireKeys(object, exactly: ["schemaVersion", "action"])
      return .observePinnedRequest
    case "executePinnedRequest":
      try requireKeys(object, exactly: ["schemaVersion", "action"])
      return .executePinnedRequest
    case "stop":
      try requireKeys(object, exactly: ["schemaVersion", "action", "reasonCode"])
      guard case .string(let reason)? = object["reasonCode"],
        reason.utf8.count <= 128,
        reason.range(of: #"^[a-z][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil
      else {
        throw RuntimeDebugCandidateActionError.invalidReasonCode
      }
      return .stop(reasonCode: reason)
    default:
      throw RuntimeDebugCandidateActionError.unsupportedAction
    }
  }

  private static func requireKeys(
    _ object: [String: JSONValue], exactly expected: Set<String>
  ) throws {
    guard Set(object.keys) == expected else {
      throw RuntimeDebugCandidateActionError.closedShapeViolation
    }
  }

  /// Preserve duplicate members until ArkDeckStorage's strict raw-byte
  /// validator rejects them. JSONDecoder alone would silently collapse them.
  private static func strictObject(from data: Data) throws -> [String: JSONValue] {
    var wrapper = Data(
      #"{"schemaVersion":"1.0.0","recordId":"candidate-action","auditId":"candidate-action","correlationId":"candidate-action","sessionId":"candidate-action","jobId":"candidate-action","category":"preview","timestamp":"2026-08-09T00:00:00Z","details":"#
        .utf8)
    wrapper.append(data)
    wrapper.append(UInt8(ascii: "}"))
    return try SessionAuditCodec.decode(wrapper).details
  }
}

public struct RuntimeDebugObservation: Codable, Equatable, Sendable {
  package let observationID: String
  package let materializedPlanDigest: String
  public let targetID: String
  public let bindingRevision: Int?
  package let stableIdentitySHA256: String?
  package let dispatchDisposition: String
}

public struct RuntimeDebugEvaluation: Codable, Equatable, Sendable {
  package let ordinal: Int
  package let destructiveEpoch: Int?
  package let candidateSourceSHA256: String
  package let candidateBuildSHA256: String
  package let candidateActionSHA256: String
  package let candidateAction: String
  package let requestID: String?
  package let idempotencyKey: String?
  public let jobID: String?
  public let outcome: RuntimeDebugExecutionOutcome?
  public let disposition: String
  public let detail: String
  package let evaluatedAtUTC: String
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
struct RuntimeDebugAttemptPermitRecord: Codable, Equatable, Sendable {
  static let schemaVersion = "2.0.0"
  let schemaVersion: String
  let invocationID: String
  let idempotencyKey: String
  let requestFingerprintSHA256: String
  let candidateActionSHA256: String
}

enum RuntimeDebugAttemptPermitStore {
  static func persist(
    stateDirectory: URL,
    invocationID: String,
    request: RuntimeOperationRequest,
    candidateActionSHA256: String
  ) throws {
    let encodedRequest = try canonicalEncode(request)
    let record = RuntimeDebugAttemptPermitRecord(
      schemaVersion: RuntimeDebugAttemptPermitRecord.schemaVersion,
      invocationID: invocationID,
      idempotencyKey: request.idempotencyKey,
      requestFingerprintSHA256: sha256(encodedRequest),
      candidateActionSHA256: candidateActionSHA256)
    try DurableFileWriter.createOrReplaceAtomically(
      destination: url(stateDirectory: stateDirectory, idempotencyKey: request.idempotencyKey),
      data: try canonicalEncode(record))
  }

  static func loadExact(
    stateDirectory: URL, request: RuntimeOperationRequest, nowUTC: String? = nil
  ) throws -> RuntimeDebugAttemptPermitRecord? {
    let location = url(stateDirectory: stateDirectory, idempotencyKey: request.idempotencyKey)
    guard FileManager.default.fileExists(atPath: location.path) else { return nil }
    let record = try JSONDecoder().decode(
      RuntimeDebugAttemptPermitRecord.self, from: Data(contentsOf: location))
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
    guard record.schemaVersion == RuntimeDebugAttemptPermitRecord.schemaVersion,
      record.idempotencyKey == request.idempotencyKey,
      record.requestFingerprintSHA256 == sha256(try canonicalEncode(unsigned))
    else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Runtime debug attempt provenance does not match the typed request")
    }
    if let nowUTC {
      let invocationURL =
        stateDirectory
        .appending(path: "runtime-debug-invocations", directoryHint: .isDirectory)
        .appending(path: "\(record.invocationID).json")
      let invocation = try JSONDecoder().decode(
        RuntimeDebugInvocationDocument.self, from: Data(contentsOf: invocationURL))
      guard invocation.schemaVersion == RuntimeDebugInvocationDocument.schemaVersion,
        invocation.invocationID == record.invocationID,
        invocation.state == "active",
        invocation.destructiveEpochsUsed
          <= RuntimeDebugInvocationController.maximumDestructiveEpochs,
        let now = ISO8601Timestamps.parse(nowUTC),
        let expiry = ISO8601Timestamps.parse(invocation.expiresAtUTC),
        now <= expiry,
        invocation.evaluations.contains(where: {
          $0.disposition == "executing"
            && $0.idempotencyKey == request.idempotencyKey
            && $0.candidateActionSHA256 == record.candidateActionSHA256
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
      .appending(path: "runtime-debug-attempts", directoryHint: .isDirectory)
      .appending(path: "\(idempotencyKey).json")
  }

  static func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(value)
  }

  static func sha256(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}

private struct RuntimeDebugInvocationDocument: Codable, Equatable, Sendable {
  static let schemaVersion = "2.0.0"
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
  private static let maximumInvocationRecords = 4_096
  private static let maximumInvocationDocumentBytes = 16 * 1_024 * 1_024

  private let stateDirectory: URL
  private let driver: any RuntimeDebugAttemptDriving
  private let nowUTC: @Sendable () -> String
  private let pages: RuntimeSnapshotPager
  private var activeEvaluations: Set<String> = []

  public init(
    stateDirectory: URL,
    driver: any RuntimeDebugAttemptDriving,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.stateDirectory = stateDirectory
    self.driver = driver
    self.nowUTC = nowUTC
    pages = try RuntimeSnapshotPager(
      directory: stateDirectory.appending(
        path: "runtime-debug-invocation-snapshots", directoryHint: .isDirectory))
    let invocationDirectory = stateDirectory.appending(
      path: "runtime-debug-invocations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: invocationDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Self.validateInvocationDirectory(invocationDirectory)
  }

  public func start(seedRequestData: Data) async throws -> RuntimeDebugInvocationStatus {
    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationCodec.decodeRequest(seedRequestData)
    } catch {
      throw RuntimeDebugInvocationError.invalidSeedRequest("\(error)")
    }
    guard request.authorization == nil,
      request.campaignReservation == nil,
      request.clientContext == nil
    else {
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "debug invocation requires one unprivileged typed request without caller provenance")
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
    let isDestructiveRecovery = preview.steps.contains {
      $0.effect == WorkflowEffect.destructive.rawValue
    }
    guard isDestructiveRecovery else {
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "Runtime debug is the protected destructive-recovery broker; "
          + "ordinary Agent debugging is an external agent driving the published job surface")
    }
    guard request.target.expectedBindingRevision != nil else {
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "destructive recovery requires a binding-pinned target")
    }
    let canonicalRequest = try RuntimeDebugAttemptPermitStore.canonicalEncode(request)
    let created = try currentDate()
    let invocationID = "debug-\(UUID().uuidString.lowercased())"
    let document = RuntimeDebugInvocationDocument(
      schemaVersion: RuntimeDebugInvocationDocument.schemaVersion,
      invocationID: invocationID,
      state: "active",
      seedRequest: request,
      seedRequestFingerprintSHA256: RuntimeDebugAttemptPermitStore.sha256(canonicalRequest),
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

  /// Fixed-snapshot discovery for receipt recovery. The compact rows omit the
  /// seed request, candidate provenance, evaluations and free-form details;
  /// callers use `status` after selecting one exact invocation identity.
  public func list(pageSize: Int, cursor: String?) throws -> JSONValue {
    try pages.page(
      method: "recovery.flash-invocation.list", filters: [:],
      order: "createdAtDescInvocationIdAsc", pageSize: pageSize, cursor: cursor
    ) {
      try Self.validateInvocationDirectory(invocationDirectory)
      let names = try FileManager.default.contentsOfDirectory(atPath: invocationDirectory.path)
      guard names.count <= Self.maximumInvocationRecords else {
        throw AgentExecutionControlFailure(
          "operationUnavailable", "Flash invocation inventory exceeds its resource bound")
      }
      var rows: [(createdAt: String, invocationID: String, value: JSONValue)] = []
      rows.reserveCapacity(names.count)
      for name in names {
        guard name.hasSuffix(".json") else {
          throw RuntimeDebugInvocationError.persistenceFailure(
            "Flash invocation directory contains an unknown entry")
        }
        let invocationID = String(name.dropLast(".json".count))
        guard Self.validInvocationID(invocationID) else {
          throw RuntimeDebugInvocationError.persistenceFailure(
            "Flash invocation directory contains an invalid identity")
        }
        let document = try load(invocationID)
        rows.append(
          (
            document.createdAtUTC, invocationID,
            .object([
              "schemaVersion": .string("arkdeck.recovery.flash-invocation-summary/1"),
              "invocationId": .string(invocationID),
              "state": .string(document.state),
              "operationReference": .string(document.seedRequest.operation.reference),
              "targetId": .string(document.seedRequest.target.targetID),
              "bindingRevision": document.seedRequest.target.expectedBindingRevision.map {
                .integer(Int64($0))
              } ?? .null,
              "createdAtUtc": .string(document.createdAtUTC),
              "expiresAtUtc": .string(document.expiresAtUTC),
              "destructiveEpochsUsed": .integer(Int64(document.destructiveEpochsUsed)),
              "maximumDestructiveEpochs": .integer(Int64(Self.maximumDestructiveEpochs)),
            ])))
      }
      return rows.sorted {
        $0.createdAt == $1.createdAt
          ? $0.invocationID < $1.invocationID : $0.createdAt > $1.createdAt
      }.map(\.value)
    }
  }

  public func evaluate(
    invocationID: String,
    actionData: Data,
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

    let action: RuntimeDebugCandidateAction
    do {
      action = try RuntimeDebugCandidateActionCodec.decode(actionData)
    } catch {
      throw RuntimeDebugInvocationError.invalidCandidate("\(error)")
    }
    let canonicalAction = try Self.canonicalActionData(action)
    let actionSHA256 = RuntimeDebugAttemptPermitStore.sha256(canonicalAction)
    let candidateRevisionSHA256 = try Self.candidateRevisionSHA256(
      actionData: canonicalAction, provenance: provenance)
    if let index = document.evaluations.indices.last,
      document.evaluations[index].disposition == "executing"
    {
      let interrupted = document.evaluations[index]
      guard interrupted.candidateActionSHA256 == actionSHA256,
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
      try RuntimeDebugAttemptPermitStore.persist(
        stateDirectory: stateDirectory,
        invocationID: invocationID,
        request: resumed,
        candidateActionSHA256: actionSHA256)
      let result = await driver.execute(
        try RuntimeDebugAttemptPermitStore.canonicalEncode(resumed))
      return try finish(result, at: index, document: &document)
    }

    let ordinal = document.evaluations.count + 1
    switch action {
    case .stop(let reasonCode):
      document.state = "stopped"
      document.evaluations.append(
        evaluation(
          ordinal: ordinal, epoch: nil, provenance: provenance,
          actionSHA256: actionSHA256, action: "stop", disposition: "stopped",
          detail: reasonCode))
      try persist(document)
      return status(document)

    case .observePinnedRequest:
      let seed = try RuntimeDebugAttemptPermitStore.canonicalEncode(document.seedRequest)
      let preview = try await driver.prepare(seed)
      let observation = RuntimeDebugObservation(
        observationID: "pinnedRequest",
        materializedPlanDigest: preview.materializedPlanDigest,
        targetID: preview.targetID,
        bindingRevision: preview.bindingRevision,
        stableIdentitySHA256: preview.stableIdentitySHA256,
        dispatchDisposition: preview.dispatchDisposition)
      document.evaluations.append(
        evaluation(
          ordinal: ordinal, epoch: nil, provenance: provenance,
          actionSHA256: actionSHA256, action: "observePinnedRequest",
          disposition: "observed", detail: "fresh Runtime plan-only observation",
          observation: observation))
      try persist(document)
      return status(document)

    case .executePinnedRequest:
      break
    }

    if let predecessor = document.evaluations.last(where: { $0.destructiveEpoch != nil }) {
      switch predecessor.outcome {
      case .safeToReflash, .outcomeUnknown:
        break
      case .none where predecessor.disposition == "executing":
        guard predecessor.candidateActionSHA256 == actionSHA256,
          predecessor.candidateSourceSHA256 == provenance.sourceSHA256,
          predecessor.candidateBuildSHA256 == provenance.buildSHA256
        else {
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

    let epoch = document.destructiveEpochsUsed + 1
    let requestID = "debug-\(String(invocationID.suffix(12)))-e\(epoch)"
    let idempotencyKey =
      "runtime-debug-\(String(invocationID.suffix(12)))-e\(epoch)-"
      + String(candidateRevisionSHA256.prefix(12))
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
      throw RuntimeDebugInvocationError.invalidSeedRequest(
        "cannot derive attempt request: \(error)")
    }
    try RuntimeDebugAttemptPermitStore.persist(
      stateDirectory: stateDirectory,
      invocationID: invocationID,
      request: generated,
      candidateActionSHA256: actionSHA256)
    let generatedData = try RuntimeDebugAttemptPermitStore.canonicalEncode(generated)

    document.destructiveEpochsUsed = epoch
    document.evaluations.append(
      evaluation(
        ordinal: ordinal, epoch: epoch, provenance: provenance,
        actionSHA256: actionSHA256, action: "executePinnedRequest",
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
      candidateActionSHA256: prepared.candidateActionSHA256,
      candidateAction: prepared.candidateAction,
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
    stateDirectory.appending(path: "runtime-debug-invocations", directoryHint: .isDirectory)
  }

  private func url(_ invocationID: String) -> URL {
    invocationDirectory.appending(path: "\(invocationID).json")
  }

  private func load(_ invocationID: String) throws -> RuntimeDebugInvocationDocument {
    guard Self.validInvocationID(invocationID) else {
      throw RuntimeDebugInvocationError.invocationNotFound(invocationID)
    }
    do {
      let document = try JSONDecoder().decode(
        RuntimeDebugInvocationDocument.self, from: try readInvocation(invocationID))
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

  private static func validInvocationID(_ value: String) -> Bool {
    value.utf8.count <= 128
      && value.range(
        of: #"^[a-z][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil
  }

  private static func validateInvocationDirectory(_ directory: URL) throws {
    var status = stat()
    guard lstat(directory.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0
    else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Flash invocation store is not a private Runtime directory")
    }
  }

  private func readInvocation(_ invocationID: String) throws -> Data {
    try Self.validateInvocationDirectory(invocationDirectory)
    let descriptor = open(url(invocationID).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno == ENOENT {
      throw RuntimeDebugInvocationError.invocationNotFound(invocationID)
    }
    guard descriptor >= 0 else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Flash invocation document cannot be opened")
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
      status.st_nlink == 1,
      status.st_size > 0, status.st_size <= Self.maximumInvocationDocumentBytes
    else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Flash invocation document failed identity or size validation")
    }
    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw RuntimeDebugInvocationError.persistenceFailure(
          "Flash invocation document read failed")
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= Self.maximumInvocationDocumentBytes else {
        throw RuntimeDebugInvocationError.persistenceFailure(
          "Flash invocation document exceeded its size bound")
      }
    }
    guard data.count == Int(status.st_size) else {
      throw RuntimeDebugInvocationError.persistenceFailure(
        "Flash invocation document changed while it was read")
    }
    return data
  }

  private func persist(_ document: RuntimeDebugInvocationDocument) throws {
    do {
      try DurableFileWriter.createOrReplaceAtomically(
        destination: url(document.invocationID),
        data: try RuntimeDebugAttemptPermitStore.canonicalEncode(document))
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
    actionSHA256: String,
    action: String,
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
      candidateActionSHA256: actionSHA256, candidateAction: action,
      requestID: requestID, idempotencyKey: idempotencyKey, jobID: nil,
      outcome: nil, disposition: disposition, detail: detail,
      evaluatedAtUTC: nowUTC(), observation: observation)
  }

  private func currentDate() throws -> Date {
    try parse(nowUTC())
  }

  private func parse(_ value: String) throws -> Date {
    guard let date = ISO8601Timestamps.parse(value) else {
      throw RuntimeDebugInvocationError.persistenceFailure("Runtime clock is not ISO-8601")
    }
    return date
  }

  private func format(_ date: Date) -> String {
    ISO8601Timestamps.string(from: date)
  }

  private static func canonicalActionData(
    _ action: RuntimeDebugCandidateAction
  ) throws -> Data {
    var object: [String: JSONValue] = [
      "schemaVersion": .string(RuntimeDebugCandidateActionCodec.schemaVersion)
    ]
    switch action {
    case .observePinnedRequest:
      object["action"] = .string("observePinnedRequest")
    case .executePinnedRequest:
      object["action"] = .string("executePinnedRequest")
    case .stop(let reasonCode):
      object["action"] = .string("stop")
      object["reasonCode"] = .string(reasonCode)
    }
    return try RuntimeDebugAttemptPermitStore.canonicalEncode(object)
  }

  private static func candidateRevisionSHA256(
    actionData: Data, provenance: RuntimeDebugCandidateProvenance
  ) throws -> String {
    let object: [String: JSONValue] = [
      "actionSha256": .string(RuntimeDebugAttemptPermitStore.sha256(actionData)),
      "buildSha256": .string(provenance.buildSHA256),
      "sourceSha256": .string(provenance.sourceSHA256),
    ]
    return RuntimeDebugAttemptPermitStore.sha256(
      try RuntimeDebugAttemptPermitStore.canonicalEncode(object))
  }
}

package struct RuntimeJobEngineDebugAttemptDriver: RuntimeDebugAttemptDriving {
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
