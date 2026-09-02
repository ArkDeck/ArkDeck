import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation

/// The one canonical time form the execution store writes and reads:
/// `yyyy-MM-ddTHH:mm:ss.SSSZ`, millisecond precision.
///
/// The value is rounded to the millisecond *before* it is formatted, and a
/// parsed value is rounded the same way before it is compared back. Formatting
/// a raw `Date` through the fractional ISO 8601 style truncates whatever lies
/// below the millisecond, and a parsed `.002` is a binary double just under
/// two milliseconds — so the old round trip disagreed with itself for about
/// half of all timestamps, which surfaced as `orchestrationClockUntrusted`
/// ("orchestration time cannot be represented") at execution creation and
/// would have made stored records unreadable by their own reader.
package enum RuntimeAgentTime {
  package static func format(_ date: Date) -> String {
    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
    let wholeSeconds = (milliseconds / 1000).rounded(.down)
    let fraction = Int(milliseconds - wholeSeconds * 1000)
    let seconds = Date(timeIntervalSince1970: wholeSeconds)
      .formatted(Date.ISO8601FormatStyle())
    return String(seconds.dropLast()) + String(format: ".%03dZ", fraction)
  }

  package static func parse(_ value: String) -> Date? {
    guard let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    else { return nil }
    let normalized = Date(
      timeIntervalSince1970: (parsed.timeIntervalSince1970 * 1000).rounded() / 1000)
    guard format(normalized) == value else { return nil }
    return normalized
  }
}

package struct AgentObservedCandidate: Codable, Equatable, Sendable {
  let candidate: String
  let observationID: String
  let generation: UInt64

  init(_ row: TargetDeviceObservation, generation: UInt64) {
    candidate = row.candidate.connectKey
    observationID = row.observationID
    self.generation = generation
  }

  var reference: TargetObservationReference {
    .init(candidate: candidate, observationID: observationID, generation: generation)
  }
}

package struct AgentCandidateSelection: Codable, Equatable, Sendable {
  let reference: String
  let observation: AgentObservedCandidate
}

package struct RuntimeAgentHumanAction: Codable, Equatable, Sendable {
  let actionID: String
  let executionID: String
  let resumeReference: String
  let kind: AgentPhysicalActionKind
  let createdAt: String
  let expiresAt: String
  var status: String
  var resolvedSelection: String?
  let observation: AgentObservedCandidate?
  let selections: [AgentCandidateSelection]

  var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.human-action/1"),
      "actionId": .string(actionID),
      "owner": .object(["kind": .string("agentExecution"), "id": .string(executionID)]),
      "resumeReference": .string(resumeReference), "category": .string(kind.category),
      "reasonCode": .string(kind.reasonCode), "minimumAction": .string(kind.minimumAction),
      "createdAt": .string(createdAt), "expiresAt": .string(expiresAt), "status": .string(status),
      "newDispatchCount": .integer(0),
      "selectionSchema": selections.isEmpty ? .null : .object([
        "type": .string("string"), "enum": .array(selections.map { .string($0.reference) }),
      ]),
      "choices": .array(selections.map {
        .object(["value": .string($0.reference), "candidateKey": .string($0.observation.candidate)])
      }),
    ])
  }

  var nextAction: JSONValue {
    .object([
      "kind": .string("humanAction"),
      "owner": .object(["kind": .string("agentExecution"), "id": .string(executionID)]),
      "resource": .object(["kind": .string("humanAction"), "id": .string(actionID)]),
      "reasonCode": .string(kind.reasonCode), "resumeReference": .string(resumeReference),
      "expiresAt": .string(expiresAt),
    ])
  }
}

package struct AgentResolvedTarget: Codable, Equatable, Sendable {
  let targetID: String
  let bindingRevision: Int?
}

package struct RuntimeAgentExecutionRecord: Codable, Sendable {
  let schemaVersion: String
  let intent: AgentExecutionIntent
  let intentFingerprintSHA256: String
  let catalogDigest: String
  let createdAt: String
  let deadline: String
  var lastObservedAt: String
  var generation: Int64
  var state: AgentExecutionState
  var target: AgentResolvedTarget?
  var submissionRequest: Data?
  var jobID: String?
  var jobState: String?
  var outcomeUnknown: Bool
  var failureCode: String?
  var actions: [RuntimeAgentHumanAction]

  var waitingAction: RuntimeAgentHumanAction? { actions.last.flatMap { $0.status == "waiting" ? $0 : nil } }

  var projection: JSONValue {
    var fields: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.agent-execution/1"),
      "executionId": .string(intent.executionID), "generation": .string(String(generation)),
      "operation": .string(intent.operationReference), "catalogDigest": .string(catalogDigest),
      "createdAt": .string(createdAt), "deadline": .string(deadline),
      "lastObservedAt": .string(lastObservedAt), "state": .string(state.rawValue),
      "targetId": target.map { .string($0.targetID) } ?? .null,
      "bindingRevision": target?.bindingRevision.map { .integer(Int64($0)) } ?? .null,
      "jobId": jobID.map(JSONValue.string) ?? .null, "jobState": jobState.map(JSONValue.string) ?? .null,
      "outcomeUnknown": .bool(outcomeUnknown), "failureCode": failureCode.map(JSONValue.string) ?? .null,
      "humanAction": waitingAction?.projection ?? .null,
      "nextAction": .null,
    ]
    if let action = waitingAction, state == .waitingForHuman {
      fields["nextAction"] = action.nextAction
    } else if let jobID {
      let kind = outcomeUnknown ? "reconcile" : state == .completed ? "readResult" : "wait"
      var action: [String: JSONValue] = [
        "kind": .string(kind),
        "owner": .object(["kind": .string("job"), "id": .string(jobID)]),
        "resource": .object(["kind": .string("job"), "id": .string(jobID)]),
        "reasonCode": .string(outcomeUnknown ? "recovery.outcomeUnknown" : state == .completed ? "job.resultAvailable" : "job.running"),
      ]
      if kind == "wait" { action["retryAfter"] = .string("250ms") }
      fields["nextAction"] = .object(action)
    } else if !state.isTerminal {
      fields["nextAction"] = .object([
        "kind": .string("wait"),
        "owner": .object(["kind": .string("agentExecution"), "id": .string(intent.executionID)]),
        "resource": .object(["kind": .string("agentExecution"), "id": .string(intent.executionID)]),
        "reasonCode": .string("agent.orchestrationPending"), "retryAfter": .string("250ms"),
      ])
    }
    return .object(fields)
  }
}

/// The daemon owns this store. No client code receives its location or writes
/// its records. A complete record publication is file- and directory-durable
/// before orchestration advances, and an unreadable record is never absence.
package final class RuntimeAgentExecutionStore: @unchecked Sendable {
  private let directory: URL
  private static let maximumRecordBytes = 16 * 1024 * 1024
  private static let maximumRecords = 4096
  private static let maximumStoreBytes: Int64 = 64 * 1024 * 1024

  package init(directory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(directory)
    try DurableFilePrimitives.rejectSymbolicLink(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    self.directory = directory
    try validateDirectory()
  }

  package static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func validateDirectory() throws {
    var status = stat()
    guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0
    else { throw AgentExecutionControlFailure("recordUnreadable", "execution store is not a private Runtime directory") }
  }

  private func url(_ id: String) throws -> URL {
    guard AgentExecutionIntent.validIdentifier(id) else {
      throw AgentExecutionControlFailure("invalidInput", "invalid execution identity")
    }
    return directory.appending(path: "execution-\(Self.fingerprint(Data(id.utf8))).json")
  }

  package func load(_ id: String) throws -> RuntimeAgentExecutionRecord? {
    try validateDirectory()
    let path = try url(id)
    guard let record = try read(path) else { return nil }
    guard record.intent.executionID == id else {
      throw AgentExecutionControlFailure("recordUnreadable", "execution identity does not match its record")
    }
    return record
  }

  private func read(_ url: URL) throws -> RuntimeAgentExecutionRecord? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "cannot open execution record") }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
      status.st_size > 0, status.st_size <= Self.maximumRecordBytes
    else { throw AgentExecutionControlFailure("recordUnreadable", "execution record failed identity or size checks") }
    var bytes = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = Darwin.read(fd, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "execution read failed") }
      if count == 0 { break }
      bytes.append(contentsOf: chunk.prefix(count))
      guard bytes.count <= Self.maximumRecordBytes else {
        throw AgentExecutionControlFailure("recordUnreadable", "execution record grew beyond its bound")
      }
    }
    do {
      let object = try ControlProtocolNegotiation.decodeObject(bytes, maximumBytes: Self.maximumRecordBytes)
      guard Set(object.keys).isSubset(of: [
        "schemaVersion", "intent", "intentFingerprintSHA256", "catalogDigest", "createdAt", "deadline",
        "lastObservedAt", "generation", "state", "target", "submissionRequest", "jobID", "jobState",
        "outcomeUnknown", "failureCode", "actions",
      ]) else { throw AgentExecutionControlFailure("recordUnreadable", "unknown execution record fields") }
      let record = try JSONDecoder().decode(RuntimeAgentExecutionRecord.self, from: bytes)
      try validate(record)
      return record
    } catch {
      throw AgentExecutionControlFailure("recordUnreadable", "execution record cannot be validated")
    }
  }

  private func validate(_ record: RuntimeAgentExecutionRecord) throws {
    guard record.schemaVersion == "arkdeck.runtime-agent-execution/1", record.generation > 0,
      record.intentFingerprintSHA256 == Self.fingerprint(try record.intent.canonicalIntent),
      let created = RuntimeAgentTime.parse(record.createdAt),
      let deadline = RuntimeAgentTime.parse(record.deadline),
      let observed = RuntimeAgentTime.parse(record.lastObservedAt), observed >= created,
      abs(deadline.timeIntervalSince(created) - Double(record.intent.maximumWaitMilliseconds) / 1000) < 0.00001,
      record.actions.count <= 128,
      record.actions.allSatisfy({ $0.executionID == record.intent.executionID
        && ["waiting", "resolvedByFreshProbe", "expired"].contains($0.status) }),
      record.actions.filter({ $0.status == "waiting" }).count <= 1,
      record.state != .waitingForHuman || record.waitingAction != nil,
      record.state != .creatingJob || record.submissionRequest != nil,
      record.state != .abandoned || record.jobID == nil,
      record.jobID == nil || record.submissionRequest != nil
    else { throw AgentExecutionControlFailure("recordUnreadable", "execution record invariants failed") }
    let actions = record.actions
    guard Set(actions.map(\.actionID)).count == actions.count,
      Set(actions.map(\.resumeReference)).count == actions.count,
      actions.allSatisfy({ action in
        guard AgentExecutionIntent.validIdentifier(action.actionID), AgentExecutionIntent.validIdentifier(action.resumeReference),
          let timestamp = RuntimeAgentTime.parse(action.createdAt), timestamp >= created, timestamp <= observed,
          action.expiresAt == record.deadline, action.selections.count <= 1000,
          Set(action.selections.map(\.reference)).count == action.selections.count else { return false }
        if action.kind == .selectDevice {
          guard action.observation == nil, !action.selections.isEmpty else { return false }
        } else if !action.selections.isEmpty || action.resolvedSelection != nil { return false }
        if let selection = action.resolvedSelection, !action.selections.contains(where: { $0.reference == selection }) { return false }
        return action.selections.allSatisfy { AgentExecutionIntent.validIdentifier($0.reference) }
      }), record.waitingAction == nil || record.state == .waitingForHuman,
      record.jobID.map(AgentExecutionIntent.validIdentifier) ?? true,
      record.target.map({ AgentExecutionIntent.validIdentifier($0.targetID) && ($0.bindingRevision.map { $0 > 0 } ?? true) }) ?? true
    else { throw AgentExecutionControlFailure("recordUnreadable", "execution action or target ownership is invalid") }
    if let bytes = record.submissionRequest {
      let request = try RuntimeOperationCodec.decodeRequest(bytes)
      let document = try ControlProtocolNegotiation.decodeObject(bytes, maximumBytes: Self.maximumRecordBytes)
      let seed = Self.fingerprint(Data(record.intent.executionID.utf8))
      guard let target = record.target,
        request.requestID == (record.intent.requestID ?? "agent-request-\(seed)"),
        request.idempotencyKey == (record.intent.idempotencyKey ?? "agent-execution-\(seed)"),
        request.operation.reference == record.intent.operationReference,
        request.target.targetID == target.targetID, request.target.expectedBindingRevision == target.bindingRevision,
        request.authorization?.capabilityID == record.intent.capabilityReference, request.campaignReservation == nil,
        request.requestedOutputs.map(\.rawValue) == (record.intent.requestedOutputs ?? ["derivedArtifacts"]),
        document["reviewedPlanDigest"] == record.intent.reviewedPlanDigest.map(JSONValue.string),
        document["clientContext"] == record.intent.clientContext,
        try PortableCanonicalJSON.canonicalBytes(.object(request.inputs)) == PortableCanonicalJSON.canonicalBytes(.object(record.intent.inputs))
      else { throw AgentExecutionControlFailure("recordUnreadable", "prepared Job request does not match its immutable execution intent") }
    }
  }

  package func save(_ record: RuntimeAgentExecutionRecord, expectedGeneration: Int64?) throws {
    try validateDirectory()
    try validate(record)
    let existing = try load(record.intent.executionID)
    guard existing?.generation == expectedGeneration,
      (expectedGeneration ?? 0) < Int64.max,
      record.generation == (expectedGeneration ?? 0) + 1
    else { throw AgentExecutionControlFailure("resourceConflict", "execution generation changed") }
    if let existing {
      guard existing.intentFingerprintSHA256 == record.intentFingerprintSHA256,
        existing.intent.reviewedPlanDigest == record.intent.reviewedPlanDigest,
        existing.catalogDigest == record.catalogDigest, existing.createdAt == record.createdAt,
        existing.deadline == record.deadline,
        existing.target == nil || existing.target == record.target,
        existing.submissionRequest == nil || existing.submissionRequest == record.submissionRequest,
        existing.jobID == nil || existing.jobID == record.jobID
      else { throw AgentExecutionControlFailure("resourceConflict", "immutable execution identity changed") }
    }
    if existing == nil, try files().count >= Self.maximumRecords {
      throw AgentExecutionControlFailure("operationUnavailable", "execution store reached its resource bound")
    }
    let bytes = try CanonicalJSONEncoders.canonical().encode(record)
    guard bytes.count <= Self.maximumRecordBytes else {
      throw AgentExecutionControlFailure("inputTooLarge", "execution record exceeds its storage bound")
    }
    var total = Int64(bytes.count)
    let destination = try url(record.intent.executionID)
    for file in try files() where file.lastPathComponent != destination.lastPathComponent {
      var metadata = stat()
      guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_size >= 0, metadata.st_size <= Self.maximumRecordBytes else {
        throw AgentExecutionControlFailure("recordUnreadable", "execution store contains an unsafe record")
      }
      total += metadata.st_size
      guard total <= Self.maximumStoreBytes else {
        throw AgentExecutionControlFailure("operationUnavailable", "execution store reached its byte bound")
      }
    }
    try DurableFileWriter.createOrReplaceAtomically(destination: destination, data: bytes)
  }

  private func files() throws -> [URL] {
    try validateDirectory()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("execution-") && $0.pathExtension == "json" }
    guard files.count <= Self.maximumRecords else {
      throw AgentExecutionControlFailure("recordUnreadable", "execution directory exceeds its record bound")
    }
    return files
  }

  package func forEachRecord(_ visit: (RuntimeAgentExecutionRecord) throws -> Void) throws {
    // Project one bounded record at a time; listing metadata must not retain
    // every operation's potentially large input document in memory.
    for file in try files().sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard let record = try read(file), try url(record.intent.executionID).lastPathComponent == file.lastPathComponent else {
        throw AgentExecutionControlFailure("recordUnreadable", "execution record was removed or renamed")
      }
      try visit(record)
    }
  }
}
