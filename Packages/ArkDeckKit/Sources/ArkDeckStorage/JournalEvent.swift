import ArkDeckCore
import CryptoKit
import Foundation

public enum JournalEventKind: String, CaseIterable, Codable, Sendable {
  case jobCreated
  case stateTransition
  case stepIntent
  case stepOutcome
  case compensationIntent
  case compensationOutcome
  case bindingCandidate
  case bindingConfirmed
  case bindingRejected
  case serverGenerationChanged
  case sleep
  case wake
  case reconcileStarted
  case reconcileOutcome
  case abandonIntent
  case abandonOutcome
  case warning
  case error
  case finalized
}

public enum JournalOutcomeCertainty: String, Codable, Sendable {
  case confirmed
  case outcomeUnknown
}

public enum JournalEventValidationError: Error, Equatable, Sendable {
  case malformedEnvelope(String)
  case malformedPayload(kind: JournalEventKind, detail: String)
  case invalidSequenceCorrelation(String)
  case canonicalArgumentsHashMismatch(stepID: String)
}

public struct JournalEvent: Equatable, Sendable {
  public static let schemaVersion = "1.0.0"

  public let eventID: String
  public let sequence: Int
  public let sessionID: String
  public let jobID: String
  public let timestamp: String
  public let accumulatedElapsedDurationNanoseconds: Int?
  public let accumulatedActiveDurationNanoseconds: Int?
  public let kind: JournalEventKind
  public let stepID: String?
  public let attempt: Int?
  public let bindingRevision: Int?
  public let argumentsHash: String?
  public let payload: [String: JSONValue]

  public init(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    accumulatedElapsedDurationNanoseconds: Int? = nil,
    accumulatedActiveDurationNanoseconds: Int? = nil,
    kind: JournalEventKind,
    stepID: String? = nil,
    attempt: Int? = nil,
    bindingRevision: Int? = nil,
    argumentsHash: String? = nil,
    payload: [String: JSONValue]
  ) throws {
    self.eventID = eventID
    self.sequence = sequence
    self.sessionID = sessionID
    self.jobID = jobID
    self.timestamp = timestamp
    self.accumulatedElapsedDurationNanoseconds = accumulatedElapsedDurationNanoseconds
    self.accumulatedActiveDurationNanoseconds = accumulatedActiveDurationNanoseconds
    self.kind = kind
    self.stepID = stepID
    self.attempt = attempt
    self.bindingRevision = bindingRevision
    self.argumentsHash = argumentsHash
    self.payload = payload
    try JournalEventSemanticValidator.validate(self)
  }

  public var correlatedIntentEventID: String? {
    switch kind {
    case .stepOutcome, .compensationOutcome:
      return payload.string("correlatesToIntentEventId")
    default:
      return nil
    }
  }

  public var workflowStep: WorkflowStep? {
    guard kind == .stepIntent, let value = payload["step"] else { return nil }
    return try? JournalCanonicalJSON.decodeWorkflowStep(value)
  }

  public var stepEffect: WorkflowEffect? { workflowStep?.effect }

  public var stateTransition: JobStateTransition? {
    guard kind == .stateTransition,
      let fromRaw = payload.string("from"), let from = JobState(rawValue: fromRaw),
      let toRaw = payload.string("to"), let to = JobState(rawValue: toRaw)
    else { return nil }
    return JobStateTransition(from: from, to: to)
  }

  public static func jobCreated(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    executionMode: String,
    executionAuthority: String = "standardAgent",
    coreBaseline: String = "CORE-2.0.0"
  ) throws -> JournalEvent {
    try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .jobCreated,
      payload: [
        "executionMode": .string(executionMode),
        "executionAuthority": .string(executionAuthority),
        "initialState": .string("queued"),
        "coreBaseline": .string(coreBaseline),
      ])
  }

  public static func stateTransition(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    from: JobState,
    to: JobState,
    reason: String,
    triggerEventID: String? = nil
  ) throws -> JournalEvent {
    var payload: [String: JSONValue] = [
      "from": .string(from.rawValue), "to": .string(to.rawValue), "reason": .string(reason),
    ]
    payload["triggerEventId"] = triggerEventID.map(JSONValue.string) ?? .null
    return try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .stateTransition, payload: payload)
  }

  public static func stepIntent(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    step: WorkflowStep,
    target: JournalTarget,
    attempt: Int,
    bindingRevision: Int?
  ) throws -> JournalEvent {
    let argumentsHash = try JournalCanonicalJSON.argumentsHash(step.arguments)
    return try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .stepIntent, stepID: step.id, attempt: attempt,
      bindingRevision: bindingRevision, argumentsHash: argumentsHash,
      payload: [
        "step": try JournalCanonicalJSON.value(step),
        "target": target.jsonValue,
      ])
  }

  public static func stepOutcome(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    stepID: String,
    attempt: Int,
    correlatesToIntentEventID: String,
    result: String,
    outcomeCertainty: JournalOutcomeCertainty,
    semanticCode: String? = nil,
    summary: String? = nil
  ) throws -> JournalEvent {
    var payload: [String: JSONValue] = [
      "correlatesToIntentEventId": .string(correlatesToIntentEventID),
      "result": .string(result),
      "outcomeCertainty": .string(outcomeCertainty.rawValue),
    ]
    if let semanticCode { payload["semanticCode"] = .string(semanticCode) }
    if let summary { payload["summary"] = .string(summary) }
    return try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .stepOutcome, stepID: stepID, attempt: attempt,
      payload: payload)
  }

  public static func reconcileStarted(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    recoveryAttemptID: String,
    sourceState: JobState,
    lastDurableSequence: Int,
    trigger: String
  ) throws -> JournalEvent {
    try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .reconcileStarted,
      payload: [
        "recoveryAttemptId": .string(recoveryAttemptID),
        "sourceState": .string(sourceState.rawValue),
        "lastDurableSequence": .integer(Int64(lastDurableSequence)),
        "trigger": .string(trigger),
      ])
  }

  public static func reconcileOutcome(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    bindingRevision: Int?,
    recoveryAttemptID: String,
    result: String,
    nextState: JobState,
    outcomeCertainty: JournalOutcomeCertainty,
    safeBoundaryConfirmed: Bool,
    evidence: [String]
  ) throws -> JournalEvent {
    try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .reconcileOutcome, bindingRevision: bindingRevision,
      payload: [
        "recoveryAttemptId": .string(recoveryAttemptID),
        "result": .string(result),
        "nextState": .string(nextState.rawValue),
        "outcomeCertainty": .string(outcomeCertainty.rawValue),
        "safeBoundaryConfirmed": .bool(safeBoundaryConfirmed),
        "evidence": .array(evidence.map(JSONValue.string)),
      ])
  }

  public static func abandonIntent(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    userConfirmationID: String,
    lastConfirmedStep: String?,
    outcomeCertainty: JournalOutcomeCertainty,
    managedProcessState: String,
    deviceHazards: [String]
  ) throws -> JournalEvent {
    try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .abandonIntent,
      payload: [
        "userConfirmationId": .string(userConfirmationID),
        "lastConfirmedStep": lastConfirmedStep.map(JSONValue.string) ?? .null,
        "outcomeCertainty": .string(outcomeCertainty.rawValue),
        "managedProcessState": .string(managedProcessState),
        "deviceHazards": .array(deviceHazards.map(JSONValue.string)),
      ])
  }

  public static func abandonOutcome(
    eventID: String,
    sequence: Int,
    sessionID: String,
    jobID: String,
    timestamp: String,
    correlatesToAbandonIntentEventID: String,
    result: String,
    releaseAuthorized: Bool,
    unresolvedHazards: [String]
  ) throws -> JournalEvent {
    try JournalEvent(
      eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
      timestamp: timestamp, kind: .abandonOutcome,
      payload: [
        "correlatesToAbandonIntentEventId": .string(correlatesToAbandonIntentEventID),
        "result": .string(result),
        "releaseAuthorized": .bool(releaseAuthorized),
        "unresolvedHazards": .array(unresolvedHazards.map(JSONValue.string)),
      ])
  }
}

public struct JournalTarget: Equatable, Sendable {
  public let scope: String
  public let targetID: String
  public let connectKey: String?
  public let identitySnapshotHash: String?

  public init(
    scope: String,
    targetID: String,
    connectKey: String?,
    identitySnapshotHash: String?
  ) {
    self.scope = scope
    self.targetID = targetID
    self.connectKey = connectKey
    self.identitySnapshotHash = identitySnapshotHash
  }

  fileprivate var jsonValue: JSONValue {
    .object([
      "scope": .string(scope),
      "targetId": .string(targetID),
      "connectKey": connectKey.map(JSONValue.string) ?? .null,
      "identitySnapshotHash": identitySnapshotHash.map(JSONValue.string) ?? .null,
    ])
  }
}

public enum JournalCanonicalJSON {
  public static func encode(_ event: JournalEvent) throws -> Data {
    try encoder.encode(JSONValue.object(event.jsonObject))
  }

  public static func argumentsHash(_ arguments: [String: JSONValue]) throws -> String {
    let digest = SHA256.hash(data: try encoder.encode(arguments))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }

  static func decodeWorkflowStep(_ value: JSONValue) throws -> WorkflowStep {
    try WorkflowStepDecoder.decodeCoreOrProviderStep(encoder.encode(value))
  }

  static func decodeCompensation(_ value: JSONValue) throws -> CompensationDescriptor {
    try JSONDecoder().decode(CompensationDescriptor.self, from: encoder.encode(value))
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

public enum JournalEventCodec {
  public static func encode(_ event: JournalEvent) throws -> Data {
    try JournalCanonicalJSON.encode(event)
  }

  public static func decode(_ data: Data) throws -> JournalEvent {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let rootValue: JSONValue
    do {
      rootValue = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw JournalEventValidationError.malformedEnvelope("invalid JSON: \(error)")
    }
    guard case .object(let object) = rootValue else {
      throw JournalEventValidationError.malformedEnvelope("event must be an object")
    }
    return try decode(object)
  }

  private static func decode(_ object: [String: JSONValue]) throws -> JournalEvent {
    let kindRaw = try object.requiredString("kind", context: "envelope")
    guard let kind = JournalEventKind(rawValue: kindRaw) else {
      throw JournalEventValidationError.malformedEnvelope("unknown event kind \(kindRaw)")
    }
    try JournalEventSemanticValidator.validateEnvelopeKeys(object, kind: kind)
    guard case .object(let payload)? = object["payload"] else {
      throw JournalEventValidationError.malformedEnvelope("payload must be an object")
    }
    let schemaVersion = try object.requiredString("schemaVersion", context: "envelope")
    guard schemaVersion == JournalEvent.schemaVersion else {
      throw JournalEventValidationError.malformedEnvelope("unsupported schemaVersion")
    }
    return try JournalEvent(
      eventID: try object.requiredString("eventId", context: "envelope"),
      sequence: try object.requiredInt("sequence", context: "envelope"),
      sessionID: try object.requiredString("sessionId", context: "envelope"),
      jobID: try object.requiredString("jobId", context: "envelope"),
      timestamp: try object.requiredString("timestamp", context: "envelope"),
      accumulatedElapsedDurationNanoseconds: try object.optionalInt(
        "accumulatedElapsedDurationNanoseconds", context: "envelope"),
      accumulatedActiveDurationNanoseconds: try object.optionalInt(
        "accumulatedActiveDurationNanoseconds", context: "envelope"),
      kind: kind,
      stepID: try object.optionalString("stepId", context: "envelope"),
      attempt: try object.optionalInt("attempt", context: "envelope"),
      bindingRevision: try object.optionalInt("bindingRevision", context: "envelope"),
      argumentsHash: try object.optionalString("argumentsHash", context: "envelope"),
      payload: payload
    )
  }
}

extension JournalEvent {
  fileprivate var jsonObject: [String: JSONValue] {
    var object: [String: JSONValue] = [
      "schemaVersion": .string(Self.schemaVersion),
      "eventId": .string(eventID),
      "sequence": .integer(Int64(sequence)),
      "sessionId": .string(sessionID),
      "jobId": .string(jobID),
      "timestamp": .string(timestamp),
      "kind": .string(kind.rawValue),
      "payload": .object(payload),
    ]
    if let accumulatedElapsedDurationNanoseconds {
      object["accumulatedElapsedDurationNanoseconds"] = .integer(
        Int64(accumulatedElapsedDurationNanoseconds))
    }
    if let accumulatedActiveDurationNanoseconds {
      object["accumulatedActiveDurationNanoseconds"] = .integer(
        Int64(accumulatedActiveDurationNanoseconds))
    }
    switch kind {
    case .stepIntent, .compensationIntent:
      object["stepId"] = stepID.map(JSONValue.string) ?? .null
      object["attempt"] = attempt.map { .integer(Int64($0)) } ?? .null
      object["bindingRevision"] = bindingRevision.map { .integer(Int64($0)) } ?? .null
      object["argumentsHash"] = argumentsHash.map(JSONValue.string) ?? .null
    case .stepOutcome, .compensationOutcome:
      object["stepId"] = stepID.map(JSONValue.string) ?? .null
      object["attempt"] = attempt.map { .integer(Int64($0)) } ?? .null
    case .bindingConfirmed, .reconcileOutcome:
      object["bindingRevision"] = bindingRevision.map { .integer(Int64($0)) } ?? .null
    default:
      break
    }
    return object
  }
}
