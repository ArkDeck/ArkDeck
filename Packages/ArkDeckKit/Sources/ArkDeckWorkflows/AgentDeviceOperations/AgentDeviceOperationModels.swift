import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Foundation

public enum AgentDeviceOperationID: String, CaseIterable, Codable, Sendable {
  case observeDevice
  case captureHilog
  case captureUIDump
  case captureTrace
  case installHAP
  case uninstallHAP
  case deployNativeLibrary
  case startApplication
  case stopApplication
  case sendOwnedFile
  case receiveOwnedFile
  case createPortForward
  case removePortForward
  case rebootDevice
  case flash
}

public enum AgentDeviceOperationExecutionMode: String, CaseIterable, Codable, Sendable {
  case execute
  case planOnly
  case simulated
}

public enum AgentDeviceOperationRequestedOutput: String, CaseIterable, Codable, Sendable {
  case rawArtifacts
  case derivedArtifacts
  case analysisReport
  case hardwareEvidence
}

public struct AgentDeviceOperationSelector: Equatable, Sendable, Codable {
  public let id: AgentDeviceOperationID
  public let profileID: String
  public let configurationID: String
  public let configurationSHA256: String
  public let artifactLeaseIDs: [String]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case profileID = "profileId"
    case configurationID = "configurationId"
    case configurationSHA256 = "configurationSha256"
    case artifactLeaseIDs = "artifactLeaseIds"
  }

  public init(from decoder: Decoder) throws {
    try AgentDocumentValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(AgentDeviceOperationID.self, forKey: .id)
    profileID = try container.decode(String.self, forKey: .profileID)
    configurationID = try container.decode(String.self, forKey: .configurationID)
    configurationSHA256 = try container.decode(String.self, forKey: .configurationSHA256)
    artifactLeaseIDs =
      try container.decodeIfPresent(
        [String].self, forKey: .artifactLeaseIDs) ?? []
    try AgentDocumentValidation.identifier(profileID, path: "$.operation.profileId")
    try AgentDocumentValidation.identifier(
      configurationID, path: "$.operation.configurationId")
    try AgentDocumentValidation.sha256(
      configurationSHA256, path: "$.operation.configurationSha256")
    guard artifactLeaseIDs.count <= 32,
      Set(artifactLeaseIDs).count == artifactLeaseIDs.count
    else {
      throw AgentDeviceOperationSubmissionError.malformed("$.operation.artifactLeaseIds")
    }
    for identifier in artifactLeaseIDs {
      try AgentDocumentValidation.identifier(
        identifier, path: "$.operation.artifactLeaseIds")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(profileID, forKey: .profileID)
    try container.encode(configurationID, forKey: .configurationID)
    try container.encode(configurationSHA256, forKey: .configurationSHA256)
    if !artifactLeaseIDs.isEmpty {
      try container.encode(artifactLeaseIDs, forKey: .artifactLeaseIDs)
    }
  }
}

public struct AgentDeviceOperationRequest: Equatable, Sendable, Codable {
  public static let documentType = "request"
  public static let schemaVersion = "1.0.0"

  public let requestID: String
  public let changeID: String
  public let taskID: String
  public let executionMode: AgentDeviceOperationExecutionMode
  public let durableTargetID: String
  public let operation: AgentDeviceOperationSelector
  public let authorizationID: String?
  public let requestedOutputs: [AgentDeviceOperationRequestedOutput]
  public let deadlineUTC: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case requestID = "requestId"
    case changeID = "changeId"
    case taskID = "taskId"
    case executionMode
    case durableTargetID = "durableTargetId"
    case operation
    case authorizationID = "authorizationId"
    case requestedOutputs
    case deadlineUTC = "deadlineUtc"
  }

  public init(from decoder: Decoder) throws {
    try AgentDocumentValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .documentType) == Self.documentType else {
      throw AgentDeviceOperationSubmissionError.malformed("$.documentType")
    }
    guard try container.decode(String.self, forKey: .schemaVersion) == Self.schemaVersion else {
      throw AgentDeviceOperationSubmissionError(
        code: .unsupportedVersion, fieldPath: "$.schemaVersion")
    }
    requestID = try container.decode(String.self, forKey: .requestID)
    changeID = try container.decode(String.self, forKey: .changeID)
    taskID = try container.decode(String.self, forKey: .taskID)
    executionMode = try container.decode(
      AgentDeviceOperationExecutionMode.self, forKey: .executionMode)
    durableTargetID = try container.decode(String.self, forKey: .durableTargetID)
    operation = try container.decode(AgentDeviceOperationSelector.self, forKey: .operation)
    authorizationID = try container.decodeIfPresent(String.self, forKey: .authorizationID)
    requestedOutputs =
      try container.decodeIfPresent(
        [AgentDeviceOperationRequestedOutput].self, forKey: .requestedOutputs) ?? []
    deadlineUTC = try container.decodeIfPresent(String.self, forKey: .deadlineUTC)
    try AgentDocumentValidation.identifier(requestID, path: "$.requestId")
    try AgentDocumentValidation.changeID(changeID, path: "$.changeId")
    try AgentDocumentValidation.taskID(taskID, path: "$.taskId")
    try AgentDocumentValidation.identifier(durableTargetID, path: "$.durableTargetId")
    if let authorizationID {
      try AgentDocumentValidation.authorizationID(
        authorizationID, path: "$.authorizationId")
    }
    guard requestedOutputs.count <= 8,
      Set(requestedOutputs).count == requestedOutputs.count
    else { throw AgentDeviceOperationSubmissionError.malformed("$.requestedOutputs") }
    if let deadlineUTC {
      try AgentDocumentValidation.timestamp(deadlineUTC, path: "$.deadlineUtc")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.documentType, forKey: .documentType)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(changeID, forKey: .changeID)
    try container.encode(taskID, forKey: .taskID)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(durableTargetID, forKey: .durableTargetID)
    try container.encode(operation, forKey: .operation)
    try container.encodeIfPresent(authorizationID, forKey: .authorizationID)
    if !requestedOutputs.isEmpty {
      try container.encode(requestedOutputs, forKey: .requestedOutputs)
    }
    try container.encodeIfPresent(deadlineUTC, forKey: .deadlineUTC)
  }
}

public enum AgentDeviceOperationDisposition: String, CaseIterable, Codable, Sendable {
  case active
  case humanActionRequired
  case policyBlocked
  case terminal
}

public enum AgentDeviceOperationOutcomeCertainty: String, CaseIterable, Codable, Sendable {
  case confirmed
  case unknown
  case notApplicable
}

public struct AgentDeviceOperationExecutor: Equatable, Sendable, Codable {
  public let kind: String
  public let id: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case kind, id
  }

  package init(id: String) {
    kind = "agent"
    self.id = id
  }

  public init(from decoder: Decoder) throws {
    try AgentDocumentValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    id = try container.decode(String.self, forKey: .id)
    guard kind == "agent" else {
      throw AgentDeviceOperationSubmissionError.malformed("$.executor.kind")
    }
    try AgentDocumentValidation.identifier(id, path: "$.executor.id")
  }
}

public struct AgentDeviceOperationArtifactReference: Equatable, Sendable, Codable {
  public let artifactID: String
  public let sha256: String
  public let sizeBytes: Int

  enum CodingKeys: String, CodingKey, CaseIterable {
    case artifactID = "artifactId"
    case sha256
    case sizeBytes
  }

  package init(artifactID: String, sha256: String, sizeBytes: Int) {
    self.artifactID = artifactID
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
  }

  public init(from decoder: Decoder) throws {
    try AgentDocumentValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artifactID = try container.decode(String.self, forKey: .artifactID)
    sha256 = try container.decode(String.self, forKey: .sha256)
    sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
    try AgentDocumentValidation.identifier(artifactID, path: "$.artifacts[].artifactId")
    try AgentDocumentValidation.sha256(sha256, path: "$.artifacts[].sha256")
    guard sizeBytes >= 0 else {
      throw AgentDeviceOperationSubmissionError.malformed("$.artifacts[].sizeBytes")
    }
  }
}

public struct AgentDeviceOperationResult: Equatable, Sendable, Codable {
  public static let documentType = "result"
  public static let schemaVersion = "1.0.0"

  public let requestID: String
  public let jobID: String
  public let executionMode: AgentDeviceOperationExecutionMode
  public let jobState: JobState
  public let disposition: AgentDeviceOperationDisposition
  public let resolvedEffect: WorkflowEffect
  public let outcomeCertainty: AgentDeviceOperationOutcomeCertainty
  public let executor: AgentDeviceOperationExecutor
  public let manifestID: String?
  public let humanActionID: String?
  public let blockerCode: String?
  public let authorizationReference: AgentExecutionAuthorityReference?
  public let artifacts: [AgentDeviceOperationArtifactReference]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case requestID = "requestId"
    case jobID = "jobId"
    case executionMode
    case jobState
    case disposition
    case resolvedEffect
    case outcomeCertainty
    case executor
    case manifestID = "manifestId"
    case humanActionID = "humanActionId"
    case blockerCode
    case authorizationReference = "authorizationRef"
    case artifacts
  }

  package init(
    requestID: String,
    jobID: String,
    executionMode: AgentDeviceOperationExecutionMode,
    jobState: JobState,
    disposition: AgentDeviceOperationDisposition,
    resolvedEffect: WorkflowEffect,
    outcomeCertainty: AgentDeviceOperationOutcomeCertainty,
    executor: AgentDeviceOperationExecutor,
    manifestID: String? = nil,
    humanActionID: String? = nil,
    blockerCode: String? = nil,
    authorizationReference: AgentExecutionAuthorityReference? = nil,
    artifacts: [AgentDeviceOperationArtifactReference] = []
  ) throws {
    self.requestID = requestID
    self.jobID = jobID
    self.executionMode = executionMode
    self.jobState = jobState
    self.disposition = disposition
    self.resolvedEffect = resolvedEffect
    self.outcomeCertainty = outcomeCertainty
    self.executor = executor
    self.manifestID = manifestID
    self.humanActionID = humanActionID
    self.blockerCode = blockerCode
    self.authorizationReference = authorizationReference
    self.artifacts = artifacts
    try validate()
  }

  public init(from decoder: Decoder) throws {
    try AgentDocumentValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(String.self, forKey: .documentType) == Self.documentType else {
      throw AgentDeviceOperationSubmissionError.malformed("$.documentType")
    }
    guard try container.decode(String.self, forKey: .schemaVersion) == Self.schemaVersion else {
      throw AgentDeviceOperationSubmissionError(
        code: .unsupportedVersion, fieldPath: "$.schemaVersion")
    }
    requestID = try container.decode(String.self, forKey: .requestID)
    jobID = try container.decode(String.self, forKey: .jobID)
    executionMode = try container.decode(
      AgentDeviceOperationExecutionMode.self, forKey: .executionMode)
    jobState = try container.decode(JobState.self, forKey: .jobState)
    disposition = try container.decode(
      AgentDeviceOperationDisposition.self, forKey: .disposition)
    resolvedEffect = try container.decode(WorkflowEffect.self, forKey: .resolvedEffect)
    outcomeCertainty = try container.decode(
      AgentDeviceOperationOutcomeCertainty.self, forKey: .outcomeCertainty)
    executor = try container.decode(AgentDeviceOperationExecutor.self, forKey: .executor)
    manifestID = try container.decodeIfPresent(String.self, forKey: .manifestID)
    humanActionID = try container.decodeIfPresent(String.self, forKey: .humanActionID)
    blockerCode = try container.decodeIfPresent(String.self, forKey: .blockerCode)
    authorizationReference = try container.decodeIfPresent(
      AgentAuthorityReferenceDocument.self, forKey: .authorizationReference)?.value
    artifacts = try container.decode(
      [AgentDeviceOperationArtifactReference].self, forKey: .artifacts)
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.documentType, forKey: .documentType)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(jobState, forKey: .jobState)
    try container.encode(disposition, forKey: .disposition)
    try container.encode(resolvedEffect, forKey: .resolvedEffect)
    try container.encode(outcomeCertainty, forKey: .outcomeCertainty)
    try container.encode(executor, forKey: .executor)
    try container.encodeIfPresent(manifestID, forKey: .manifestID)
    try container.encodeIfPresent(humanActionID, forKey: .humanActionID)
    try container.encodeIfPresent(blockerCode, forKey: .blockerCode)
    if let authorizationReference {
      try container.encode(
        AgentAuthorityReferenceDocument(authorizationReference),
        forKey: .authorizationReference)
    }
    try container.encode(artifacts, forKey: .artifacts)
  }

  private func validate() throws {
    try AgentDocumentValidation.identifier(requestID, path: "$.requestId")
    try AgentDocumentValidation.identifier(jobID, path: "$.jobId")
    if let manifestID {
      try AgentDocumentValidation.identifier(manifestID, path: "$.manifestId")
    }
    guard executor.kind == "agent" else {
      throw AgentDeviceOperationSubmissionError.malformed("$.executor.kind")
    }
    try AgentDocumentValidation.identifier(executor.id, path: "$.executor.id")
    guard artifacts.count <= 1_024 else {
      throw AgentDeviceOperationSubmissionError.malformed("$.artifacts")
    }
    for artifact in artifacts {
      try AgentDocumentValidation.identifier(
        artifact.artifactID, path: "$.artifacts[].artifactId")
      try AgentDocumentValidation.sha256(
        artifact.sha256, path: "$.artifacts[].sha256")
      guard artifact.sizeBytes >= 0 else {
        throw AgentDeviceOperationSubmissionError.malformed("$.artifacts[].sizeBytes")
      }
    }
    let carriesHuman = humanActionID != nil || blockerCode != nil
    guard (disposition == .humanActionRequired) == carriesHuman,
      humanActionID.map({ _ in blockerCode != nil }) ?? (blockerCode == nil)
    else { throw AgentDeviceOperationSubmissionError.malformed("$.disposition") }
    if let humanActionID {
      try AgentDocumentValidation.identifier(humanActionID, path: "$.humanActionId")
    }
    if let blockerCode {
      try AgentDocumentValidation.identifier(blockerCode, path: "$.blockerCode")
    }
    guard (disposition == .terminal) == jobState.isTerminal else {
      throw AgentDeviceOperationSubmissionError.malformed("$.jobState")
    }
    if disposition == .active || disposition == .policyBlocked {
      guard outcomeCertainty == .notApplicable else {
        throw AgentDeviceOperationSubmissionError.malformed("$.outcomeCertainty")
      }
    }
    switch jobState {
    case .planned:
      guard outcomeCertainty == .notApplicable else {
        throw AgentDeviceOperationSubmissionError.malformed("$.outcomeCertainty")
      }
    case .succeeded, .failed, .cancelled:
      guard outcomeCertainty == .confirmed else {
        throw AgentDeviceOperationSubmissionError.malformed("$.outcomeCertainty")
      }
    default:
      break
    }
    if executionMode != .execute || disposition == .policyBlocked {
      guard authorizationReference == nil else {
        throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef")
      }
    }
    if let authorizationReference {
      guard executionMode == .execute, authorizationReference.effect == resolvedEffect else {
        throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef")
      }
    }
  }
}

public struct AgentDeviceOperationBlocker: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case humanActionRequired
    case policyBlocked
  }

  public let kind: Kind
  public let code: String
  public let humanActionID: String?

  package init(kind: Kind, code: String, humanActionID: String? = nil) {
    self.kind = kind
    self.code = code
    self.humanActionID = humanActionID
  }
}

public struct AgentDeviceOperationSubmissionError: Error, Equatable, Sendable {
  public enum Code: String, CaseIterable, Sendable {
    case malformedRequest
    case unsupportedVersion
    case requestTooLarge
    case trustedServiceUnavailable
    case durableAdmissionFailed
  }

  public let code: Code
  public let fieldPath: String

  public init(code: Code, fieldPath: String) {
    self.code = code
    self.fieldPath = fieldPath
  }

  static func malformed(_ fieldPath: String) -> AgentDeviceOperationSubmissionError {
    AgentDeviceOperationSubmissionError(code: .malformedRequest, fieldPath: fieldPath)
  }
}

public enum AgentDeviceOperationCodec {
  public static let maximumDocumentBytes = 1_048_576

  public static func decodeRequest(_ data: Data) throws -> AgentDeviceOperationRequest {
    try decode(AgentDeviceOperationRequest.self, from: data)
  }

  public static func decodeResult(_ data: Data) throws -> AgentDeviceOperationResult {
    try decode(AgentDeviceOperationResult.self, from: data)
  }

  public static func encodeRequest(_ value: AgentDeviceOperationRequest) throws -> Data {
    try encode(value)
  }

  public static func encodeResult(_ value: AgentDeviceOperationResult) throws -> Data {
    try encode(value)
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    guard data.count <= maximumDocumentBytes else {
      throw AgentDeviceOperationSubmissionError(
        code: .requestTooLarge, fieldPath: "$")
    }
    do {
      var duplicateValidator = AgentStrictJSONDuplicateValidator(data: data)
      try duplicateValidator.validate()
      return try JSONDecoder().decode(type, from: data)
    } catch let error as AgentDeviceOperationSubmissionError {
      throw error
    } catch let error as AgentStrictJSONError {
      switch error {
      case .duplicateMemberName(let path):
        throw AgentDeviceOperationSubmissionError.malformed(path)
      case .malformed:
        throw AgentDeviceOperationSubmissionError.malformed("$")
      }
    } catch {
      throw AgentDeviceOperationSubmissionError.malformed("$")
    }
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

private struct AgentAuthorityReferenceDocument: Codable {
  let value: AgentExecutionAuthorityReference

  init(_ value: AgentExecutionAuthorityReference) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AgentAuthorityCodingKey.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    let kind = try container.decode(AgentExecutionAuthorityKind.self, forKey: .kind)
    switch kind {
    case .readyTask:
      let expected = Set([
        "kind", "changeId", "taskId", "mainCommitOID", "taskBlobOID", "approvalPRNumber",
      ])
      try AgentDocumentValidation.requireClosedKeys(decoder, allowed: expected)
      guard keys == expected else {
        throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef")
      }
      value = try AgentExecutionAuthorityReference.validatedReadyTask(
        changeID: container.decode(String.self, forKey: .changeID),
        taskID: container.decode(String.self, forKey: .taskID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        taskBlobOID: container.decode(String.self, forKey: .taskBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .deviceCapability:
      let expected = Set([
        "kind", "capabilityId", "mainCommitOID", "capabilityBlobOID", "approvalPRNumber",
      ])
      try AgentDocumentValidation.requireClosedKeys(decoder, allowed: expected)
      guard keys == expected else {
        throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef")
      }
      value = try AgentExecutionAuthorityReference.validatedDeviceCapability(
        capabilityID: container.decode(String.self, forKey: .capabilityID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        capabilityBlobOID: container.decode(String.self, forKey: .capabilityBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .standingAuthorization:
      let expected = Set([
        "kind", "authorizationId", "mainCommitOID", "authorizationBlobOID", "approvalPRNumber",
      ])
      try AgentDocumentValidation.requireClosedKeys(decoder, allowed: expected)
      guard keys == expected else {
        throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef")
      }
      value = try AgentExecutionAuthorityReference.validatedStandingAuthorization(
        authorizationID: container.decode(String.self, forKey: .authorizationID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        authorizationBlobOID: container.decode(String.self, forKey: .authorizationBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .chatConfirmation:
      // This generic operation surface cannot establish the Rockchip-specific live target and
      // invocation facts required by CHG-2026-025 r7. Only the closed Flash host may decode it.
      throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef.kind")
    }
  }

  func encode(to encoder: Encoder) throws {
    guard value.kind != .chatConfirmation else {
      throw AgentDeviceOperationSubmissionError.malformed("$.authorizationRef.kind")
    }
    try value.encode(to: encoder)
  }
}

private enum AgentAuthorityCodingKey: String, CodingKey {
  case kind
  case changeID = "changeId"
  case taskID = "taskId"
  case capabilityID = "capabilityId"
  case authorizationID = "authorizationId"
  case mainCommitOID
  case taskBlobOID
  case capabilityBlobOID
  case authorizationBlobOID
  case approvalPRNumber
}

enum AgentDocumentValidation {
  private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  static func requireClosedKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: DynamicKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw AgentDeviceOperationSubmissionError.malformed("$")
    }
  }

  static func identifier(_ value: String, path: String) throws {
    try match(value, #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, path: path)
  }

  static func changeID(_ value: String, path: String) throws {
    try match(value, #"^CHG-[0-9]{4}-[0-9]{3}$"#, path: path)
  }

  static func taskID(_ value: String, path: String) throws {
    try match(value, #"^TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?$"#, path: path)
  }

  static func authorizationID(_ value: String, path: String) throws {
    try match(value, #"^AUTH-[A-Z0-9]+(?:-[A-Z0-9]+)*$"#, path: path)
  }

  static func sha256(_ value: String, path: String) throws {
    try match(value, #"^[0-9a-f]{64}$"#, path: path)
  }

  static func timestamp(_ value: String, path: String) throws {
    guard
      value.range(
        of:
          #"^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?Z$"#,
        options: .regularExpression) == value.startIndex..<value.endIndex,
      date(value) != .distantPast
    else { throw AgentDeviceOperationSubmissionError.malformed(path) }
  }

  static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      value.contains(".")
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter.date(from: value) ?? .distantPast
  }

  private static func match(_ value: String, _ pattern: String, path: String) throws {
    guard
      value.range(of: pattern, options: .regularExpression)
        == value.startIndex..<value.endIndex
    else { throw AgentDeviceOperationSubmissionError.malformed(path) }
  }
}
