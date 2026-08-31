import Foundation

/// Protocol-2 Artifact owners are resources, never interchangeable namespaces.
package struct ArtifactOwnerReference: Equatable, Sendable {
  package let kind: String
  package let id: String
  package var value: JSONValue { .object(["kind": .string(kind), "id": .string(id)]) }

  package init(_ value: JSONValue) throws {
    guard case .object(let fields) = value, Set(fields.keys) == ["kind", "id"],
      case .string(let kind)? = fields["kind"], ["job", "import"].contains(kind),
      case .string(let id)? = fields["id"], AgentExecutionIntent.validIdentifier(id) else {
      throw AgentExecutionControlFailure("invalidInput", "Artifact requires one exact tagged Job or Import owner")
    }
    if kind == "import" {
      guard id.hasPrefix("imp-"), let uuid = UUID(uuidString: String(id.dropFirst(4))),
        id == "imp-" + uuid.uuidString.lowercased() else {
        throw AgentExecutionControlFailure("invalidInput", "Import owner identity is malformed")
      }
    } else if id.hasPrefix("imp-") {
      throw AgentExecutionControlFailure("invalidInput", "an Import identity cannot select a Job")
    }
    self.kind = kind; self.id = id
  }
}

/// The same bounded, digest-bound range is used for JSON and raw stdout.
package struct ArtifactReadProjection: Sendable {
  package static let maximumBytes = 4_194_304
  package static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
  package let value: JSONValue
  package let artifactID: String
  package let digest: String
  package let offset: Int
  package let nextOffset: Int
  package let totalByteCount: Int
  package let bytes: Data

  package init(_ value: JSONValue) throws {
    func invalid() -> AgentExecutionControlFailure {
      .init("recordUnreadable", "Artifact range identity, bounds or bytes are malformed")
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["artifactId", "artifactDigest", "offset", "nextOffset", "totalByteCount", "eof", "byteCount", "base64"],
      case .string(let id)? = fields["artifactId"], AgentExecutionIntent.validIdentifier(id),
      case .string(let digest)? = fields["artifactDigest"], SHA256Hex.isLowercaseSHA256(digest),
      let offset = Self.count(fields["offset"]), let next = Self.count(fields["nextOffset"]),
      let total = Self.count(fields["totalByteCount"]), let count = Self.count(fields["byteCount"]),
      offset <= total, next >= offset, next <= total, count == next - offset, count <= Self.maximumBytes,
      fields["eof"] == .bool(next == total), count > 0 || next == total,
      case .string(let encoded)? = fields["base64"], encoded.utf8.count <= ((Self.maximumBytes + 2) / 3) * 4,
      let bytes = Data(base64Encoded: encoded), bytes.count == count,
      bytes.base64EncodedString() == encoded else { throw invalid() }
    self.value = value; artifactID = id; self.digest = digest; self.offset = offset
    nextOffset = next; totalByteCount = total; self.bytes = bytes
  }

  package static func count(_ value: JSONValue?) -> Int? {
    guard case .integer(let count)? = value, count >= 0, count <= maximumSafeInteger else { return nil }
    return Int(exactly: count)
  }
}

package struct ArtifactResourceProjection: Sendable {
  package let value: JSONValue
  package let owner: ArtifactOwnerReference
  package let id: String
  package let byteCount: Int
  package let digest: String?
  package let createdAt: Date

  package init(_ value: JSONValue) throws {
    func invalid() -> AgentExecutionControlFailure { .init("recordUnreadable", "Artifact metadata is malformed") }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "owner", "artifactId", "name", "mediaType", "privacy", "byteCount", "artifactDigest", "status", "lease", "createdAtUtc", "retention", "sourceOperation", "providerId", "binding", "redactionApplied", "observationWindow"],
      fields["schemaVersion"] == .string("arkdeck.artifact/1"),
      let ownerValue = fields["owner"], let owner = try? ArtifactOwnerReference(ownerValue),
      let id = Self.text(fields["artifactId"]), AgentExecutionIntent.validIdentifier(id),
      let name = Self.text(fields["name"]), !name.isEmpty, name.utf8.count <= 1024,
      let media = Self.text(fields["mediaType"]), !media.isEmpty, media.utf8.count <= 256,
      let privacy = Self.text(fields["privacy"]), CatalogArtifactPrivacy(rawValue: privacy) != nil,
      let count = ArtifactReadProjection.count(fields["byteCount"]),
      let status = Self.text(fields["status"]), ["published", "missing", "truncated"].contains(status),
      let created = Self.text(fields["createdAtUtc"]).flatMap(ISO8601Timestamps.parse),
      let operation = Self.text(fields["sourceOperation"]), !operation.isEmpty, operation.utf8.count <= 256,
      let provider = Self.text(fields["providerId"]), !provider.isEmpty, provider.utf8.count <= 128,
      case .bool? = fields["redactionApplied"],
      case .object(let binding)? = fields["binding"], Set(binding.keys) == ["targetId", "bindingRevision", "stableIdentitySha256"],
      let target = Self.text(binding["targetId"]), AgentExecutionIntent.validIdentifier(target),
      binding["bindingRevision"] == .null || (ArtifactReadProjection.count(binding["bindingRevision"]) ?? 0) > 0,
      binding["stableIdentitySha256"] == .null || Self.text(binding["stableIdentitySha256"]).map(SHA256Hex.isLowercaseSHA256) == true,
      case .object(let retention)? = fields["retention"], Set(retention.keys) == ["class", "pinned", "deadlineUtc"],
      let retentionClass = Self.text(retention["class"]), CatalogArtifactRetentionClass(rawValue: retentionClass) != nil,
      case .bool? = retention["pinned"],
      retention["deadlineUtc"] == .null || Self.text(retention["deadlineUtc"]).flatMap(ISO8601Timestamps.parse) != nil
    else { throw invalid() }
    let digest = Self.text(fields["artifactDigest"])
    guard digest.map(SHA256Hex.isLowercaseSHA256) == true || (status != "published" && fields["artifactDigest"] == .null),
      fields["lease"] == .null || (status == "published" && fields["lease"] == .string("lease-v1:\(owner.id):\(id)")) else { throw invalid() }
    if fields["observationWindow"] != .null {
      guard case .object(let window)? = fields["observationWindow"], Set(window.keys) == ["startUtc", "endUtc"],
        let start = Self.text(window["startUtc"]).flatMap(ISO8601Timestamps.parse),
        let end = Self.text(window["endUtc"]).flatMap(ISO8601Timestamps.parse), end >= start else { throw invalid() }
    }
    self.value = value; self.owner = owner; self.id = id; byteCount = count; self.digest = digest; createdAt = created
  }

  package static func validatePage(_ value: JSONValue, owner: ArtifactOwnerReference, pageSize: Int) throws {
    func invalid() -> AgentExecutionControlFailure { .init("recordUnreadable", "Artifact inventory page is malformed") }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
      fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("snapshot"),
      fields["order"] == .string("createdAtDescArtifactIdAsc"),
      let revision = text(fields["snapshotRevision"]), let uuid = UUID(uuidString: revision), uuid.uuidString.lowercased() == revision,
      case .array(let rows)? = fields["items"], rows.count <= pageSize, rows.count <= 1000,
      case .bool(let more)? = fields["hasMore"], !more || !rows.isEmpty,
      more ? (text(fields["nextCursor"]).map { $0.hasPrefix(revision + ".") && $0.utf8.count <= 2048 } == true) : fields["nextCursor"] == .null else { throw invalid() }
    var previous: ArtifactResourceProjection?
    var seen = Set<String>()
    for row in rows {
      let current = try Self(row)
      guard current.owner == owner, seen.insert(current.id).inserted,
        previous.map({ $0.createdAt > current.createdAt || ($0.createdAt == current.createdAt && $0.id.utf8.lexicographicallyPrecedes(current.id.utf8)) }) ?? true else { throw invalid() }
      previous = current
    }
  }

  private static func text(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }; return text
  }
}
