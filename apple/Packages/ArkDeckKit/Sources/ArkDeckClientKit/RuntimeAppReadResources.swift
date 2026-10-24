import ArkDeckCore
import Foundation

/// Collects validated immutable read pages for App presentation. The assembled
/// values stay local; each transport request still uses the published resource.
package enum RuntimeAppReadResources {
  package typealias Send = @Sendable (String, [String: JSONValue]) async throws -> Data

  package static func result(_ data: Data) throws -> JSONValue {
    let line = data.last == 0x0A ? Data(data.dropLast()) : data
    let fields = try ControlFrameJSON.decodeObject(line, maximumBytes: ArkDeckControlProtocol.maximumResponseFrameBytes)
    guard fields["ok"] == .bool(true), let value = fields["result"] else {
      throw AgentExecutionControlFailure("recordUnreadable", "Runtime read resource is unavailable")
    }
    return value
  }

  package static let recentSummaryParams: [String: JSONValue] = [
    "pageSize": .integer(250), "order": .string("createdAtDescJobIdAsc"), "includeTimeline": .bool(false),
  ]

  package static func recentJobSummaries(_ data: Data) throws -> [[String: Any]] {
    let page = try result(data)
    guard case .object(let fields) = page,
      Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
      fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("snapshot"),
      fields["order"] == .string("createdAtDescJobIdAsc"),
      case .string(let revision)? = fields["snapshotRevision"], UUID(uuidString: revision)?.uuidString.lowercased() == revision,
      case .array(let rows)? = fields["items"], rows.count <= 250, case .bool(let more)? = fields["hasMore"],
      !more || !rows.isEmpty else { throw unreadable() }
    if more {
      guard case .string(let cursor)? = fields["nextCursor"], cursor.hasPrefix(revision + "."), cursor.utf8.count <= 2048 else { throw unreadable() }
    } else if fields["nextCursor"] != .null { throw unreadable() }
    for row in rows {
      guard case .object(let fields) = row, fields["schemaVersion"] == .string("arkdeck.job-summary/1") else { throw unreadable() }
    }
    guard let summaries = try JSONSerialization.jsonObject(with: CanonicalJSONEncoders.canonical().encode(rows)) as? [[String: Any]] else { throw unreadable() }
    return summaries
  }

  package static func statusPresentation(jobID: String, send: Send) async throws -> [String: Any] {
    let detail = try await jobDetail(jobID: jobID, send: send)
    guard case .object(let fields) = detail, case .object(var status)? = fields["job"],
      case .object(let timeline)? = fields["timeline"], case .array(let entries)? = timeline["entries"] else { throw unreadable() }
    status["timeline"] = .array(entries)
    guard let result = try JSONSerialization.jsonObject(with: CanonicalJSONEncoders.canonical().encode(status)) as? [String: Any] else { throw unreadable() }
    return result
  }

  package static func artifactInventory(jobID: String, send: Send) async throws -> [JSONValue] {
    let owner = try ArtifactOwnerReference(.object(["kind": .string("job"), "id": .string(jobID)]))
    var previous: ArtifactResourceProjection?
    return try await pages(method: "artifact.list", params: ["owner": owner.value], send: send) { page in
      try ArtifactResourceProjection.validatePage(page, owner: owner, pageSize: 1000)
      guard case .object(let fields) = page, case .array(let rows)? = fields["items"] else {
        throw unreadable()
      }
      for row in rows {
        let current = try ArtifactResourceProjection(row)
        guard previous.map({ $0.createdAt > current.createdAt ||
          ($0.createdAt == current.createdAt && $0.id.utf8.lexicographicallyPrecedes(current.id.utf8)) }) ?? true else {
          throw unreadable()
        }
        previous = current
      }
    }
  }

  package static func jobDetail(jobID: String, send: Send) async throws -> JSONValue {
    let value = try result(await send("job.show", ["jobId": .string(jobID)]))
    guard case .object(var detail) = value, detail["schemaVersion"] == .string("arkdeck.job/1"),
      case .object(let job)? = detail["job"], job["schemaVersion"] == .string("arkdeck.job-status/1"),
      job["jobId"] == .string(jobID),
      case .object(let timeline)? = detail["timeline"] else { throw unreadable() }
    if timeline["kind"] == .string("inline") {
      guard Set(timeline.keys) == ["kind", "entries"], case .array(let entries)? = timeline["entries"],
        entries.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw unreadable() }
      return value
    }
    guard Set(timeline.keys) == ["kind", "method", "jobId"],
      timeline["kind"] == .string("snapshotPages"), timeline["method"] == .string("job.timeline"),
      timeline["jobId"] == .string(jobID) else { throw unreadable() }
    let rows = try await pages(method: "job.timeline", params: ["jobId": .string(jobID)], send: send) { page in
      guard case .object(let fields) = page, fields["order"] == .string("entryIndexAscPartIndexAsc") else {
        throw unreadable()
      }
    }
    var entries: [JSONValue] = []
    var text = ""
    var part = 0
    for row in rows {
      guard case .object(let fields) = row,
        Set(fields.keys) == ["entryIndex", "partIndex", "text", "lastPart"],
        fields["entryIndex"] == .string(String(entries.count)),
        fields["partIndex"] == .string(String(part)), case .string(let fragment)? = fields["text"],
        case .bool(let last)? = fields["lastPart"] else { throw unreadable() }
      text += fragment
      if last { entries.append(.string(text)); text = ""; part = 0 }
      else { part += 1 }
    }
    guard part == 0 else { throw unreadable() }
    detail["timeline"] = .object(["kind": .string("inline"), "entries": .array(entries)])
    return .object(detail)
  }

  private static func pages(
    method: String, params: [String: JSONValue], send: Send,
    validate: (JSONValue) throws -> Void
  ) async throws -> [JSONValue] {
    var cursor: String?
    var revision: String?
    var cursors = Set<String>()
    var items: [JSONValue] = []
    var byteCount = 0
    repeat {
      try Task.checkCancellation()
      var options = params
      options["pageSize"] = .integer(1000)
      if let cursor { options["cursor"] = .string(cursor) }
      let bytes = try await send(method, options)
      byteCount += bytes.count
      guard byteCount <= 64 * 1024 * 1024 else { throw unreadable() }
      let page = try result(bytes)
      guard case .object(let fields) = page,
        Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
        fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("snapshot"),
        case .string(let currentRevision)? = fields["snapshotRevision"],
        UUID(uuidString: currentRevision)?.uuidString.lowercased() == currentRevision,
        revision == nil || revision == currentRevision,
        case .array(let rows)? = fields["items"], rows.count <= 1000,
        case .bool(let more)? = fields["hasMore"], !more || !rows.isEmpty else { throw unreadable() }
      try validate(page)
      revision = currentRevision
      items += rows
      if more {
        guard case .string(let next)? = fields["nextCursor"], next.hasPrefix(currentRevision + "."),
          next.utf8.count <= 2048, cursors.insert(next).inserted else { throw unreadable() }
        cursor = next
      } else {
        guard fields["nextCursor"] == .null else { throw unreadable() }
        cursor = nil
      }
    } while cursor != nil
    return items
  }

  package static func presentationData(_ value: JSONValue) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(JSONValue.object(["ok": .bool(true), "result": value]))
  }

  private static func unreadable() -> AgentExecutionControlFailure {
    .init("recordUnreadable", "Runtime snapshot pages are incomplete or inconsistent")
  }
}
