import ArkDeckCore
import Foundation

/// Closed inputs for immutable Job discovery. List filters select records;
/// they never cause an operation, target lookup, adoption or implicit run.
package struct RuntimeJobListQuery: Sendable {
  package let order: String
  package let includeCurrent: Bool
  package let includeTimeline: Bool
  package let pageSize: Int
  package let cursor: String?
  package let filters: [String: JSONValue]

  package init(_ fields: [String: JSONValue]) throws {
    guard Set(fields.keys).isSubset(of: ["order", "includeCurrent", "includeTimeline", "pageSize", "cursor", "state", "operation", "target", "thread"])
    else { throw AgentExecutionControlFailure("invalidInput", "job.list options are closed") }
    func bool(_ name: String) throws -> Bool {
      guard let value = fields[name] else { return false }
      guard case .bool(let result) = value else { throw AgentExecutionControlFailure("invalidInput", "\(name) must be a boolean") }
      return result
    }
    includeCurrent = try bool("includeCurrent")
    includeTimeline = try bool("includeTimeline")
    if let value = fields["order"] {
      guard case .string(let order) = value, ["createdAtDescJobIdAsc", "createdAtAscJobIdAsc"].contains(order) else {
        throw AgentExecutionControlFailure("invalidInput", "order must name a published complete Job order")
      }
      self.order = order
    } else { order = "createdAtDescJobIdAsc" }
    if let value = fields["pageSize"] {
      guard case .integer(let count) = value, (1...1000).contains(count) else {
        throw AgentExecutionControlFailure("invalidInput", "pageSize must be between 1 and 1000")
      }
      pageSize = Int(count)
    } else { pageSize = 100 }
    if let value = fields["cursor"] {
      guard case .string(let token) = value, !token.isEmpty, token.utf8.count <= 2048 else {
        throw AgentExecutionControlFailure("invalidCursor", "cursor must be a bounded snapshot token")
      }
      cursor = token
    } else { cursor = nil }
    var filters: [String: JSONValue] = [
      "includeCurrent": .bool(includeCurrent), "includeTimeline": .bool(includeTimeline),
    ]
    for key in ["state", "operation", "target", "thread"] {
      guard let value = fields[key] else { continue }
      guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 256,
        !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      else { throw AgentExecutionControlFailure("invalidInput", "\(key) must be a bounded query value") }
      if key == "state", JobState(rawValue: text) == nil {
        throw AgentExecutionControlFailure("invalidInput", "state is not a published Job state")
      }
      filters[key] = value
    }
    self.filters = filters
  }

  package func matches(_ status: RuntimeJobStatus) -> Bool {
    [("state", status.state), ("operation", status.operationReference), ("target", status.targetID),
      ("thread", status.threadID ?? "")].allSatisfy { key, value in
        filters[key] == nil || filters[key] == .string(value)
      }
  }
}

/// Runtime-owned stable read models. These contain typed resource data, never
/// provider lowering, executable/argv, recovery actions or mutable App state.
package enum RuntimeJobReadProjection {
  package static func nextAction(_ status: RuntimeJobStatus) throws -> JSONValue {
    guard let state = JobState(rawValue: status.state), !status.waitingForHuman else {
      throw unreadable("Job status has no supported durable next action")
    }
    let uncertain = status.outcomeUnknown || [.waitingForRecovery, .reconciling].contains(state)
    var fields: [String: JSONValue] = [
      "kind": .string(uncertain ? "reconcile" : state.isTerminal ? "readResult" : "wait"),
      "owner": .object(["kind": .string("job"), "id": .string(status.jobID)]),
      "resource": .object(["kind": .string("job"), "id": .string(status.jobID)]),
      "reasonCode": .string(uncertain ? "recovery.outcomeUnknown" : state.isTerminal ? "job.resultAvailable" : "job.running"),
    ]
    if !uncertain && !state.isTerminal { fields["retryAfter"] = .string("250ms") }
    return .object(fields)
  }

  package static func status(_ value: RuntimeJobStatus) throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(value.jobID), let created = value.createdAtUTC,
      ISO8601Timestamps.parse(created) != nil else { throw unreadable("Job identity or creation time is unreadable") }
    var fields: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.job-status/1"), "jobId": .string(value.jobID),
      "operation": .string(value.operationReference), "targetId": .string(value.targetID),
      "state": .string(value.state), "outcome": .string(value.outcomeUnknown ? "outcomeUnknown" : value.state),
      "waitingForHuman": .bool(value.waitingForHuman), "outcomeUnknown": .bool(value.outcomeUnknown),
      "outstandingResidueCount": .integer(Int64(value.outstandingResidueCount ?? 0)),
      "executionMode": value.executionMode.map(JSONValue.string) ?? .null,
      "sessionId": value.sessionID.map(JSONValue.string) ?? .null,
      "threadId": value.threadID.map(JSONValue.string) ?? .null,
      "workspaceKind": value.workspaceKind.map { .string($0.rawValue) } ?? .null,
      "actualEffect": value.actualEffect.map(JSONValue.string) ?? .null,
      "createdAtUtc": .string(created), "startedAtUtc": value.startedAtUTC.map(JSONValue.string) ?? .null,
      "finishedAtUtc": value.finishedAtUTC.map(JSONValue.string) ?? .null,
      "supersededByRecoveryEpochId": value.supersededByRecoveryEpochID.map(JSONValue.string) ?? .null,
      "recoveryEpochId": value.recoveryEpochID.map(JSONValue.string) ?? .null,
      "resolvedByTargetAliasResolutionId": value.resolvedByTargetAliasResolutionID.map(JSONValue.string) ?? .null,
      "nextAction": try nextAction(value),
    ]
    if let failure = value.operationFailure {
      fields["failure"] = .object([
        "schemaVersion": .string(failure.schemaVersion), "code": .string(failure.code.rawValue),
        "category": .string(failure.category.rawValue), "retryability": .string(failure.retryability.rawValue),
        "recovery": .string(failure.recovery.rawValue),
      ])
    } else { fields["failure"] = .null }
    if let progress = value.processProgress {
      fields["processProgress"] = .object([
        "stepId": .string(progress.stepID), "phase": .string(progress.phase.rawValue),
        "unitName": progress.unitName.map(JSONValue.string) ?? .null,
        "completedUnitCount": .integer(Int64(progress.completedUnitCount)),
        "totalUnitCount": .integer(Int64(progress.totalUnitCount)),
        "currentUnitPercent": progress.currentUnitPercent.map { .integer(Int64($0)) } ?? .null,
      ])
    } else { fields["processProgress"] = .null }
    return try bounded(.object(fields))
  }

  package static func history(_ value: RuntimeJobStatus, current: Bool, includeTimeline: Bool) throws -> JSONValue {
    guard case .object(var fields) = try status(value) else { throw unreadable("Job status is unreadable") }
    fields["schemaVersion"] = .string("arkdeck.job-summary/1")
    fields["current"] = .bool(current)
    fields["timeline"] = includeTimeline ? try timeline(value.timeline, jobID: value.jobID) : .null
    return try bounded(.object(fields))
  }

  package static func show(_ record: RuntimeJobRecord, status value: RuntimeJobStatus) throws -> JSONValue {
    try bounded(.object([
      "schemaVersion": .string("arkdeck.job/1"), "job": try status(value),
      "request": try json(record.request), "catalogDigest": .string(record.catalogDigest),
      "providerId": .string(record.providerID),
      "materializedPlanDigest": record.materializedPlanDigest.map(JSONValue.string) ?? .null,
      "materializedBindingRevision": record.materializedBindingRevision.map { .integer(Int64($0)) } ?? .null,
      "materializedStableIdentitySha256": record.materializedStableTargetIdentitySHA256.map(JSONValue.string) ?? .null,
      "actualStepKinds": .array((record.actualStepKinds ?? []).map(JSONValue.string)),
      "timeline": try timeline(record.timeline, jobID: record.jobID),
      "events": .object(["method": .string("job.events"), "jobId": .string(record.jobID)]),
      "evidence": .object(["method": .string("job.evidence"), "jobId": .string(record.jobID)]),
      "ringCoverage": try record.ringCoverage.map { try json($0) } ?? .null,
      "screenSequence": try record.screenSequence.map { try json($0) } ?? .null,
    ]))
  }

  private static func timeline(_ values: [String], jobID: String) throws -> JSONValue {
    // Timeline is explicitly requested historical prose. It is not a durable
    // stream; oversized detail remains addressable through its snapshot page.
    let projection = JSONValue.array(values.map(JSONValue.string))
    if try PortableCanonicalJSON.canonicalBytes(projection).count <= 256 * 1024 {
      return .object(["kind": .string("inline"), "entries": projection])
    }
    return .object(["kind": .string("snapshotPages"), "jobId": .string(jobID), "method": .string("job.timeline")])
  }

  package static func timelineRows(_ values: [String]) -> [JSONValue] {
    var rows: [JSONValue] = []
    for (index, value) in values.enumerated() {
      var part = 0
      var text = ""
      var bytes = 0
      func append(last: Bool) {
        rows.append(.object(["entryIndex": .string(String(index)), "partIndex": .string(String(part)),
          "text": .string(text), "lastPart": .bool(last)]))
        part += 1; text = ""; bytes = 0
      }
      // A single paragraph may exceed the wire bound. Split on Unicode scalar
      // boundaries, preserving every byte even for unusually long graphemes.
      for scalar in value.unicodeScalars {
        let count = scalar.utf8.count
        if bytes + count > 64 * 1024 { append(last: false) }
        text.unicodeScalars.append(scalar); bytes += count
      }
      append(last: true)
    }
    return rows
  }

  package static func bounded(_ value: JSONValue, maximumBytes: Int = 4 * 1024 * 1024) throws -> JSONValue {
    guard try PortableCanonicalJSON.canonicalBytes(value).count <= maximumBytes else {
      throw AgentExecutionControlFailure("inputTooLarge", "Job read projection exceeds its bounded response size")
    }
    return value
  }
  private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: CanonicalJSONEncoders.canonical().encode(value))
  }
  private static func unreadable(_ text: String) -> AgentExecutionControlFailure { .init("recordUnreadable", text) }
}
