import Foundation

/// Product control records have their own intent identity. Neither a wire
/// request ID nor any resolved observation participates in this fingerprint.
package struct HDCControlActionIntent: Equatable, Sendable {
  package let actionRequestID: String
  package let endpointReference: String
  package let expectedGeneration: UInt64

  package init(_ fields: [String: JSONValue]) throws {
    guard Set(fields.keys) == ["actionRequestId", "action", "serverEndpointRef", "expectedServerGeneration"],
      fields["action"] == .string("restart"),
      case .string(let request)? = fields["actionRequestId"], HDCControlValue.identifier(request),
      case .string(let endpoint)? = fields["serverEndpointRef"], endpoint.hasPrefix("hdc-endpoint:"),
      HDCControlValue.digest(String(endpoint.dropFirst("hdc-endpoint:".count))),
      case .string(let generation)? = fields["expectedServerGeneration"],
      let parsed = HDCControlValue.generation(generation)
    else { throw HDCControlValue.failure("invalidInput", "an exact restart intent and request identity are required") }
    actionRequestID = request; endpointReference = endpoint; expectedGeneration = parsed
  }

  package var request: [String: JSONValue] {
    ["actionRequestId": .string(actionRequestID), "action": .string("restart"),
      "serverEndpointRef": .string(endpointReference), "expectedServerGeneration": .string(String(expectedGeneration))]
  }

  package var canonicalIntent: JSONValue {
    .object(["schemaVersion": .string("arkdeck.hdc-control-intent/1"), "kind": .string("hdcLifecycle"),
      "action": .string("restart"), "serverEndpointRef": .string(endpointReference),
      "expectedServerGeneration": .string(String(expectedGeneration))])
  }

  package var fingerprint: String { get throws { try HDCControlValue.hash(canonicalIntent) } }
}

/// Only the Runtime constructs impact values. Parsing a preview or knowing its
/// digest never grants a lifecycle lease or an accepted Supervisor confirmation.
package struct HDCControlImpact: Equatable, Sendable {
  package let value: [String: JSONValue]

  package init(_ source: [String: JSONValue]) throws {
    let expected: Set<String> = ["serverEndpointRef", "endpoint", "serverOwnership", "serverGeneration",
      "tool", "serverHealth", "serverVersion", "affectedTargetIds", "affectedJobIds", "detectedOtherClientIds",
      "otherClientsMayExist", "affectedDeviceObservations", "criticalJobGate", "interruption", "recovery"]
    guard Set(source.keys) == expected,
      case .string(let reference)? = source["serverEndpointRef"], reference.hasPrefix("hdc-endpoint:"),
      HDCControlValue.digest(String(reference.dropFirst("hdc-endpoint:".count))),
      case .string(let endpoint)? = source["endpoint"], (1...128).contains(endpoint.utf8.count),
      endpoint.utf8.allSatisfy({ (33...126).contains($0) }),
      reference == "hdc-endpoint:" + SHA256Hex.string(of: Data(endpoint.utf8)),
      HDCControlValue.oneOf(source["serverOwnership"], ["arkDeckManaged", "external", "unknown"]),
      HDCControlValue.optionalGeneration(source["serverGeneration"]),
      HDCControlValue.oneOf(source["serverHealth"], ["healthy", "unavailable", "unknown"]),
      HDCControlValue.optionalText(source["serverVersion"], maximumBytes: 128),
      source["otherClientsMayExist"] == .bool(true),
      source["interruption"] == .object(["kind": .string("hdcEndpointUnavailable"), "affectsAllParticipants": .bool(true)]),
      source["recovery"] == .object(["kind": .string("statusThenReconcile"), "replayAllowed": .bool(false)])
    else { throw HDCControlValue.failure("factsDrifted", "impact facts do not match the closed lifecycle schema") }
    try Self.validateTool(source["tool"])
    var fields = source
    for key in ["affectedTargetIds", "affectedJobIds", "detectedOtherClientIds"] {
      fields[key] = try HDCControlValue.ids(source[key])
    }
    fields["affectedDeviceObservations"] = try HDCControlValue.rows(source["affectedDeviceObservations"], key: { row in
      guard Set(row.keys) == ["observationId", "generation", "authorization", "health"],
        case .string(let id)? = row["observationId"], HDCControlValue.identifier(id),
        case .string(let generation)? = row["generation"], HDCControlValue.generation(generation) != nil,
        HDCControlValue.oneOf(row["authorization"], ["authorized", "unauthorized", "unknown"]),
        HDCControlValue.oneOf(row["health"], ["connected", "offline", "unknown"])
      else { throw HDCControlValue.failure("factsDrifted", "device observation has no exact lifecycle identity") }
      return [id]
    })
    guard case .object(var gate)? = source["criticalJobGate"], Set(gate.keys) == ["state", "blocking", "reasonCode"],
      HDCControlValue.oneOf(gate["state"], ["clear", "blocked", "unknown"]),
      HDCControlValue.optionalIdentifier(gate["reasonCode"])
    else { throw HDCControlValue.failure("factsDrifted", "critical Job gate is incomplete") }
    gate["blocking"] = try HDCControlValue.rows(gate["blocking"], key: { row in
      guard Set(row.keys) == ["jobId", "stepId", "state", "safeBoundary", "recovery"],
        case .string(let job)? = row["jobId"], HDCControlValue.identifier(job),
        HDCControlValue.optionalIdentifier(row["stepId"]),
        case .string(let state)? = row["state"], HDCControlValue.identifier(state),
        HDCControlValue.oneOf(row["safeBoundary"], ["blocked", "unknown"]),
        HDCControlValue.oneOf(row["recovery"], ["waitForJob", "reconcileJob", "continueCleanup", "inspectJob"])
      else { throw HDCControlValue.failure("factsDrifted", "critical Job blocker is incomplete") }
      let step: String
      if case .string(let text)? = row["stepId"] { step = text } else { step = "" }
      return [job, step]
    })
    guard case .array(let blockers)? = gate["blocking"],
      (gate["state"] != .string("clear") || (blockers.isEmpty && gate["reasonCode"] == .null)),
      (gate["state"] == .string("clear") || gate["reasonCode"] != .null),
      (gate["state"] != .string("blocked") || !blockers.isEmpty),
      case .array(let jobValues)? = fields["affectedJobIds"]
    else { throw HDCControlValue.failure("factsDrifted", "critical Job gate contradicts its blockers") }
    let jobs = Set(jobValues.compactMap { if case .string(let id) = $0 { id } else { nil } })
    guard blockers.allSatisfy({ row in
      guard case .object(let row) = row, case .string(let job)? = row["jobId"] else { return false }
      return jobs.contains(job)
    }) else { throw HDCControlValue.failure("factsDrifted", "a critical Job is absent from the impact inventory") }
    fields["criticalJobGate"] = .object(gate)
    guard try PortableCanonicalJSON.canonicalBytes(.object(fields)).count <= 512 * 1024 else {
      throw HDCControlValue.failure("inputTooLarge", "lifecycle impact exceeds its bounded record")
    }
    value = fields
  }

  package var criticalGateIsClear: Bool {
    guard case .object(let gate)? = value["criticalJobGate"] else { return false }
    return gate["state"] == .string("clear")
  }

  private static func validateTool(_ value: JSONValue?) throws {
    guard case .object(let tool)? = value,
      Set(tool.keys) == ["reference", "executablePath", "source", "sha256", "signature", "version", "trust"],
      HDCControlValue.optionalText(tool["reference"], maximumBytes: 256),
      HDCControlValue.optionalText(tool["executablePath"], maximumBytes: 4096),
      HDCControlValue.oneOf(tool["source"], ["runtimeConfiguration", "bootstrapRegistry", "unknown"]),
      HDCControlValue.optionalDigest(tool["sha256"]),
      HDCControlValue.optionalText(tool["version"], maximumBytes: 128),
      HDCControlValue.oneOf(tool["trust"], ["unverified", "verified", "unknown"])
    else { throw HDCControlValue.failure("factsDrifted", "selected tool facts are incomplete") }
    if tool["signature"] == .null { return }
    guard case .object(let signature)? = tool["signature"],
      Set(signature.keys) == ["state", "identifier", "teamIdentifier", "platformTrust", "executionAssessment"],
      HDCControlValue.oneOf(signature["state"], ["unsigned", "adHoc", "verified"]),
      HDCControlValue.optionalText(signature["identifier"], maximumBytes: 256),
      HDCControlValue.optionalText(signature["teamIdentifier"], maximumBytes: 256),
      signature["platformTrust"] == .string("unverified"), signature["executionAssessment"] == .string("notPerformed")
    else { throw HDCControlValue.failure("factsDrifted", "selected signature facts are incomplete") }
  }
}

/// Immutable product preview. Accepted Supervisor hashes remain opaque and
/// separate; this digest uses the CLI-owned RFC 8785 contract only.
package struct HDCControlActionPreview: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let impact: HDCControlImpact

  package init(actionID: String, previewID: String, createdAt: String, expiresAt: String,
    impact: HDCControlImpact) throws {
    var fields = impact.value
    fields.merge(["schemaVersion": .string("arkdeck.hdc-control-preview/1"), "controlActionId": .string(actionID),
      "previewId": .string(previewID), "kind": .string("hdcLifecycle"), "action": .string("restart"),
      "createdAt": .string(createdAt), "expiresAt": .string(expiresAt),
      "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
      "confirmationRequired": .bool(true), "dispatchCount": .integer(0), "digestAlgorithm": .string("sha256-jcs")], uniquingKeysWith: { _, new in new })
    fields["previewDigest"] = .string(try HDCControlValue.hash(.object(fields)))
    try self.init(value: fields)
  }

  package init(value: [String: JSONValue]) throws {
    let metadata: Set<String> = ["schemaVersion", "controlActionId", "previewId", "kind", "action", "createdAt", "expiresAt", "owner",
      "confirmationRequired", "dispatchCount", "digestAlgorithm", "previewDigest"]
    guard value["schemaVersion"] == .string("arkdeck.hdc-control-preview/1"), value["kind"] == .string("hdcLifecycle"),
      value["action"] == .string("restart"), value["confirmationRequired"] == .bool(true), value["dispatchCount"] == .integer(0),
      value["digestAlgorithm"] == .string("sha256-jcs"), case .string(let id)? = value["controlActionId"], HDCControlValue.identifier(id),
      case .string(let preview)? = value["previewId"], HDCControlValue.identifier(preview),
      value["owner"] == .object(["kind": .string("controlAction"), "id": .string(id)]),
      case .string(let created)? = value["createdAt"], let start = HDCControlValue.time(created),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires),
      end > start, end.timeIntervalSince(start) <= 300,
      case .string(let digest)? = value["previewDigest"],
      try digest == HDCControlValue.hash(.object(value.filter { $0.key != "previewDigest" }))
    else { throw HDCControlValue.failure("recordUnreadable", "control-action preview failed identity or digest validation") }
    let impact = try HDCControlImpact(value.filter { !metadata.contains($0.key) })
    guard impact.value == value.filter({ !metadata.contains($0.key) }) else {
      throw HDCControlValue.failure("recordUnreadable", "stored impact collections are not canonical")
    }
    self.value = value; self.impact = impact
  }
}

package enum HDCControlValue {
  package static func failure(
    _ code: String, _ message: String, details: [String: JSONValue] = [:]
  ) -> AgentExecutionControlFailure {
    .init(code, message, details: details)
  }
  package static func identifier(_ text: String) -> Bool {
    (1...128).contains(text.utf8.count) && text.utf8.first.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } == true &&
      text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }
  }
  package static func digest(_ text: String) -> Bool {
    text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  package static func generation(_ text: String) -> UInt64? {
    guard let number = UInt64(text), number > 0, number <= UInt64(Int64.max), String(number) == text else { return nil }
    return number
  }
  package static func optionalGeneration(_ value: JSONValue?) -> Bool {
    if value == .null { return true }; guard case .string(let text)? = value else { return false }; return generation(text) != nil
  }
  package static func optionalIdentifier(_ value: JSONValue?) -> Bool {
    if value == .null { return true }; guard case .string(let text)? = value else { return false }; return identifier(text)
  }
  package static func optionalDigest(_ value: JSONValue?) -> Bool {
    if value == .null { return true }; guard case .string(let text)? = value else { return false }; return digest(text)
  }
  package static func optionalText(_ value: JSONValue?, maximumBytes: Int) -> Bool {
    if value == .null { return true }; guard case .string(let text)? = value else { return false }
    return (1...maximumBytes).contains(text.utf8.count) && text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
  }
  package static func oneOf(_ value: JSONValue?, _ allowed: Set<String>) -> Bool {
    guard case .string(let text)? = value else { return false }; return allowed.contains(text)
  }
  package static func hash(_ value: JSONValue) throws -> String {
    SHA256Hex.string(of: try PortableCanonicalJSON.canonicalBytes(value))
  }
  package static func time(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let result = formatter.date(from: value), formatter.string(from: result) == value else { return nil }
    return result
  }
  static func ids(_ value: JSONValue?) throws -> JSONValue {
    guard case .array(let rows)? = value, rows.count <= 4096 else { throw failure("factsDrifted", "impact ID collection is unavailable or too large") }
    let values = try rows.map { value -> String in
      guard case .string(let id) = value, identifier(id) else { throw failure("factsDrifted", "impact collection has an invalid identity") }
      return id
    }
    return .array(Set(values).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(JSONValue.string))
  }
  static func rows(_ value: JSONValue?, key: ([String: JSONValue]) throws -> [String]) throws -> JSONValue {
    guard case .array(let rows)? = value, rows.count <= 4096 else { throw failure("factsDrifted", "impact row collection is unavailable or too large") }
    var unique: [[String]: JSONValue] = [:]
    for row in rows {
      guard case .object(let fields) = row else { throw failure("factsDrifted", "impact row is not an object") }
      let identity = try key(fields)
      if let old = unique[identity], old != row { throw failure("factsDrifted", "the same impact identity carries conflicting facts") }
      unique[identity] = row
    }
    return .array(unique.keys.sorted { left, right in
      for (a, b) in zip(left, right) where a != b { return a.utf8.lexicographicallyPrecedes(b.utf8) }
      return left.count < right.count
    }.compactMap { unique[$0] })
  }
}
