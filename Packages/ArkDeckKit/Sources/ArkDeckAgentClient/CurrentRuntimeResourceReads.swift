import ArkDeckCore
import Foundation

/// Shared decoding for the executor and persisted headless verification.
/// Resource reads never retry, submit, run or reconcile an operation.
enum CurrentRuntimeResourceReads {
  static func artifactInventory(client: AgentClient, jobID: String, timeoutSeconds: Int = 30) throws -> [JSONValue] {
    let owner = try ArtifactOwnerReference(.object(["kind": .string("job"), "id": .string(jobID)]))
    let bounded = try client.bounded(by: AgentClientWaitDeadline(milliseconds: min(timeoutSeconds, 86400) * 1000))
    var cursor: String?
    var revision: JSONValue?
    var seenCursors = Set<String>()
    var previous: ArtifactResourceProjection?
    var rows: [JSONValue] = []
    repeat {
      var params: [String: JSONValue] = ["owner": owner.value, "pageSize": .integer(1000)]
      if let cursor { params["cursor"] = .string(cursor) }
      let page = try bounded.request(method: "artifact.list", params: params)
      try ArtifactResourceProjection.validatePage(page, owner: owner, pageSize: 1000)
      guard case .object(let fields) = page, case .array(let items)? = fields["items"],
        revision == nil || revision == fields["snapshotRevision"] else { throw malformed("Artifact snapshot changed between pages") }
      revision = fields["snapshotRevision"]
      for row in items {
        let item = try ArtifactResourceProjection(row)
        guard previous.map({ $0.createdAt > item.createdAt ||
          ($0.createdAt == item.createdAt && $0.id.utf8.lexicographicallyPrecedes(item.id.utf8)) }) ?? true else {
          throw malformed("Artifact inventory order or identity repeated")
        }
        previous = item
        rows.append(row)
      }
      if case .string(let next)? = fields["nextCursor"] {
        guard seenCursors.insert(next).inserted else { throw malformed("Artifact inventory repeated a cursor") }
        cursor = next
      } else { cursor = nil }
    } while cursor != nil
    return rows
  }

  static func evidence(_ value: JSONValue) throws -> RuntimeHardwareEvidenceTrustedFacts {
    guard case .object(var fields) = value,
      fields["schemaVersion"] == .string("arkdeck.job-evidence/1"),
      case .array(let artifacts)? = fields["artifacts"] else { throw malformed("Job evidence is not the current resource") }
    // The wire uses canonical decimal strings. The internal evidence model
    // stores counts as integers; this conversion accepts only that wire form.
    fields["artifacts"] = .array(try artifacts.map { item in
      guard case .object(var row) = item, case .string(let text)? = row["byteCount"],
        let count = Int64(text), count >= 0, String(count) == text else { throw malformed("Evidence Artifact count is not canonical") }
      row["byteCount"] = .integer(count)
      return .object(row)
    })
    return try JSONDecoder().decode(RuntimeHardwareEvidenceTrustedFacts.self,
      from: CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields)))
  }

  private static func malformed(_ text: String) -> RuntimeAgentExecutorError { .malformedResponse(text) }
}
