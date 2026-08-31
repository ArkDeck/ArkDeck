import Foundation

/// Closed upload metadata. No host path, executable or device command is part
/// of import identity; the Runtime independently resolves the target binding.
package struct ArtifactImportIntent: Codable, Equatable, Sendable {
  package static let schemaVersion = "arkdeck.import-intent/1"
  package static let maximumChunkBytes = 2 * 1024 * 1024
  package let importRequestID: String
  package let kind: String
  package let targetID: String
  package let bindingRevision: Int
  package let deviceProfile: String?
  package let name: String
  package let byteCount: Int
  package let sha256: String

  package init(_ fields: [String: JSONValue]) throws {
    func invalid() -> AgentExecutionControlFailure { .init("invalidInput", "Import requires registered metadata and exact target/binding references") }
    guard Set(fields.keys) == ["schemaVersion", "importRequestId", "kind", "targetId", "bindingRevision", "deviceProfile", "name", "byteCount", "sha256"],
      fields["schemaVersion"] == .string(Self.schemaVersion),
      case .string(let request)? = fields["importRequestId"], AgentExecutionIntent.validIdentifier(request),
      case .string(let kind)? = fields["kind"], ["hap", "workspace-patch", "flash-bundle", "native-library"].contains(kind),
      case .string(let target)? = fields["targetId"], AgentExecutionIntent.validIdentifier(target),
      let revision = Self.decimal(fields["bindingRevision"]), revision > 0,
      case .string(let name)? = fields["name"], name.utf8.count <= 128,
      name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
      let count = Self.decimal(fields["byteCount"]), count > 0,
      case .string(let digest)? = fields["sha256"], SHA256Hex.isLowercaseSHA256(digest)
    else { throw invalid() }
    let profile: String?
    if case .string(let value)? = fields["deviceProfile"] { profile = value }
    else if fields["deviceProfile"] == .null { profile = nil }
    else { throw invalid() }
    switch kind {
    case "hap":
      guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.(hap|hsp)$"#, options: .regularExpression) != nil, count <= 64 * 1024 * 1024, profile == nil else { throw invalid() }
    case "workspace-patch":
      guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.(patch|diff)$"#, options: .regularExpression) != nil,
        count <= 512 * 1024, profile == nil else { throw invalid() }
    case "native-library":
      guard name.range(of: #"^lib[A-Za-z0-9_.-]+\.so$"#, options: .regularExpression) != nil,
        (64...64 * 1024 * 1024).contains(count), profile == nil else { throw invalid() }
    case "flash-bundle":
      guard name == "images.tar.gz", count <= 8 * 1024 * 1024 * 1024, profile == "dayu200" else { throw invalid() }
    default: throw invalid()
    }
    importRequestID = request; self.kind = kind; targetID = target; bindingRevision = revision
    deviceProfile = profile; self.name = name; byteCount = count; sha256 = digest
  }

  package var projection: JSONValue {
    .object(["schemaVersion": .string(Self.schemaVersion), "importRequestId": .string(importRequestID),
      "kind": .string(kind), "targetId": .string(targetID), "bindingRevision": .string(String(bindingRevision)),
      "deviceProfile": deviceProfile.map(JSONValue.string) ?? .null, "name": .string(name),
      "byteCount": .string(String(byteCount)), "sha256": .string(sha256)])
  }
  package var fingerprint: String {
    get throws { SHA256Hex.string(of: try PortableCanonicalJSON.canonicalBytes(projection)) }
  }
  package static func decimal(_ value: JSONValue?) -> Int? {
    guard case .string(let text)? = value, let number = Int(text), number >= 0, String(number) == text else { return nil }
    return number
  }
}
