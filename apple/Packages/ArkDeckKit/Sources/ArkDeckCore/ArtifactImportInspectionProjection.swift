import Foundation

/// A coherent observation of one Import and its live reference blockers.
/// A clear observation is not a lease, reservation or release authorization.
package struct ArtifactImportInspectionProjection: Sendable {
  package let value: JSONValue
  package let imported: ArtifactImportProjection
  package let activeJobIDs: [String]
  package let outcomeUnknownJobIDs: [String]
  package let activeMaterializationCount: Int

  package init(_ value: JSONValue) throws {
    func invalid() -> AgentExecutionControlFailure {
      .init("recordUnreadable", "Import reference inspection is malformed")
    }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "import", "references"],
      fields["schemaVersion"] == .string("arkdeck.import-inspection/1"),
      let resource = fields["import"],
      case .object(let references)? = fields["references"],
      Set(references.keys) == ["state", "activeJobIds", "outcomeUnknownJobIds", "activeMaterializationCount"],
      let count = ArtifactImportIntent.decimal(references["activeMaterializationCount"]), count <= 1024 else {
      throw invalid()
    }
    func identities(_ key: String) throws -> [String] {
      guard case .array(let values)? = references[key], values.count <= 1000 else { throw invalid() }
      let ids = try values.map { value -> String in
        guard case .string(let id) = value, AgentExecutionIntent.validIdentifier(id), !id.hasPrefix("imp-") else { throw invalid() }
        return id
      }
      guard Set(ids).count == ids.count, ids == ids.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) else { throw invalid() }
      return ids
    }
    let jobs = try identities("activeJobIds")
    let unknown = try identities("outcomeUnknownJobIds")
    guard Set(unknown).isSubset(of: Set(jobs)),
      references["state"] == .string(jobs.isEmpty && count == 0 ? "clear" : "referenced") else { throw invalid() }
    imported = try ArtifactImportProjection(resource)
    self.value = value; activeJobIDs = jobs; outcomeUnknownJobIDs = unknown; activeMaterializationCount = count
  }
}
