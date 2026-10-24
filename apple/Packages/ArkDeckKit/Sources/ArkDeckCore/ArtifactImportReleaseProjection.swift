import Foundation

package struct ArtifactImportReleaseProjection: Sendable {
  package let value: JSONValue
  package let importID: String
  package let artifactID: String
  package let lease: String
  package let deadline: String

  package init(_ value: JSONValue) throws {
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "importId", "importRequestId", "owner", "artifactId", "lease", "releasedGeneration", "generation", "state", "releasedAtUtc", "retention"],
      fields["schemaVersion"] == .string("arkdeck.import-release/1"), fields["state"] == .string("released"),
      case .string(let id)? = fields["importId"], id.hasPrefix("imp-"),
      let uuid = UUID(uuidString: String(id.dropFirst(4))), "imp-" + uuid.uuidString.lowercased() == id,
      case .string(let request)? = fields["importRequestId"], AgentExecutionIntent.validIdentifier(request),
      fields["owner"] == .object(["kind": .string("import"), "id": .string(id)]),
      case .string(let artifact)? = fields["artifactId"], AgentExecutionIntent.validIdentifier(artifact),
      case .string(let lease)? = fields["lease"], lease == "lease-v1:\(id):\(artifact)",
      fields["releasedGeneration"] == .string("2"), fields["generation"] == .string("3"),
      case .string(let released)? = fields["releasedAtUtc"], let releasedAt = ISO8601Timestamps.parse(released),
      case .object(let retention)? = fields["retention"], Set(retention.keys) == ["class", "pinned", "deadlineUtc"],
      retention["class"] == .string("default"), retention["pinned"] == .bool(false),
      case .string(let deadline)? = retention["deadlineUtc"], let expires = ISO8601Timestamps.parse(deadline), expires > releasedAt else {
      throw AgentExecutionControlFailure("recordUnreadable", "Import release receipt is malformed")
    }
    self.value = value; importID = id; artifactID = artifact; self.lease = lease; self.deadline = deadline
  }
}
