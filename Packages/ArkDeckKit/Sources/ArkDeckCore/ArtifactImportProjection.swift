import Foundation

package struct ArtifactImportProjection: Sendable {
  package let value: JSONValue
  package let intent: ArtifactImportIntent
  package let id: String
  package let generation: Int
  package let state: String
  package let nextOffset: Int
  package let maximumChunkBytes: Int
  package init(_ value: JSONValue) throws {
    func invalid() -> AgentExecutionControlFailure { .init("recordUnreadable", "Runtime returned an invalid Import projection") }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "importId", "importRequestId", "metadata", "metadataFingerprint", "generation", "state", "nextOffset", "maximumChunkBytes", "createdAtUtc", "updatedAtUtc", "receipt"],
      fields["schemaVersion"] == .string("arkdeck.import/1"), case .object(let metadata)? = fields["metadata"],
      let id = Self.string(fields["importId"]), id.hasPrefix("imp-"), let uuid = UUID(uuidString: String(id.dropFirst(4))), "imp-" + uuid.uuidString.lowercased() == id,
      let generation = ArtifactImportIntent.decimal(fields["generation"]), generation > 0,
      let state = Self.string(fields["state"]), ["inProgress", "committing", "committed", "aborted", "released"].contains(state),
      let offset = ArtifactImportIntent.decimal(fields["nextOffset"]),
      let chunk = ArtifactImportIntent.decimal(fields["maximumChunkBytes"]), (1...ArtifactImportIntent.maximumChunkBytes).contains(chunk),
      Self.string(fields["createdAtUtc"]).flatMap(ISO8601Timestamps.parse) != nil,
      Self.string(fields["updatedAtUtc"]).flatMap(ISO8601Timestamps.parse) != nil else { throw invalid() }
    let intent: ArtifactImportIntent
    do { intent = try ArtifactImportIntent(metadata) } catch { throw invalid() }
    guard fields["importRequestId"] == .string(intent.importRequestID), fields["metadataFingerprint"] == .string(try intent.fingerprint), offset <= intent.byteCount else { throw invalid() }
    guard generation == (state == "released" ? 3 : ["committed", "aborted"].contains(state) ? 2 : 1),
      state != "committing" || offset == intent.byteCount else { throw invalid() }
    if ["committed", "released"].contains(state) {
      guard offset == intent.byteCount, case .object(let receipt)? = fields["receipt"],
        Set(receipt.keys) == ["schemaVersion", "importId", "importRequestId", "owner", "artifactId", "artifactDigest", "byteCount", "name", "mediaType", "privacy", "targetId", "bindingRevision", "lease", "generation", "validation"],
        receipt["schemaVersion"] == .string("arkdeck.import-receipt/1"), receipt["importId"] == .string(id),
        receipt["importRequestId"] == .string(intent.importRequestID), receipt["owner"] == .object(["kind": .string("import"), "id": .string(id)]),
        let artifact = Self.string(receipt["artifactId"]), AgentExecutionIntent.validIdentifier(artifact),
        receipt["lease"] == .string("lease-v1:\(id):\(artifact)"), receipt["artifactDigest"] == .string(intent.sha256),
        receipt["byteCount"] == .string(String(intent.byteCount)), receipt["name"] == .string(intent.name),
        receipt["targetId"] == .string(intent.targetID), receipt["bindingRevision"] == .string(String(intent.bindingRevision)),
        receipt["generation"] == .string("2"), case .object(let validation)? = receipt["validation"],
        validation["kind"] == .string(intent.kind),
        receipt["mediaType"] == .string(intent.kind == "hap" ? (intent.name.hasSuffix(".hsp") ? "application/vnd.openharmony.hsp" : "application/vnd.openharmony.hap")
          : intent.kind == "workspace-patch" ? "text/x-diff" : intent.kind == "native-library" ? "application/x-elf" : "application/gzip"),
        receipt["privacy"] == .string(intent.kind == "workspace-patch" ? "sensitive" : "standard") else { throw invalid() }
    } else { guard fields["receipt"] == .null else { throw invalid() } }
    self.value = value; self.intent = intent; self.id = id; self.generation = generation
    self.state = state; nextOffset = offset; maximumChunkBytes = chunk
  }
  package static func validatePage(_ value: JSONValue) throws {
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
      fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("snapshot"),
      fields["order"] == .string("createdAtDescImportIdAsc"), case .array(let items)? = fields["items"], items.count <= 1000,
      let revision = Self.string(fields["snapshotRevision"]), let uuid = UUID(uuidString: revision), uuid.uuidString.lowercased() == revision,
      case .bool(let more)? = fields["hasMore"], !more || !items.isEmpty,
      !more || (Self.string(fields["nextCursor"])?.hasPrefix(revision + ".") == true && (Self.string(fields["nextCursor"])?.utf8.count ?? 2049) <= 2048),
      more ? Self.string(fields["nextCursor"])?.isEmpty == false : fields["nextCursor"] == .null else {
      throw AgentExecutionControlFailure("recordUnreadable", "Runtime returned an invalid Import page")
    }
    var seen = Set<String>()
    var previous: (Date, String)?
    for item in items {
      let row = try ArtifactImportProjection(item)
      guard case .object(let projection) = row.value,
        let date = Self.string(projection["createdAtUtc"]).flatMap(ISO8601Timestamps.parse), seen.insert(row.id).inserted,
        previous.map({ $0.0 > date || ($0.0 == date && $0.1.utf8.lexicographicallyPrecedes(row.id.utf8)) }) ?? true else {
        throw AgentExecutionControlFailure("recordUnreadable", "Import snapshot order or owner identity changed")
      }
      previous = (date, row.id)
    }
  }
  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let value)? = value else { return nil }; return value
  }
}

