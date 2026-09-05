import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Current v1 Artifact resources never synthesize an Import-owned Job.
struct RuntimeArtifactResourceHandler {
  let engine: RuntimeJobEngine
  let artifacts: RuntimeArtifactStore?

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    func failed(_ code: String, _ message: String) -> AgentWireProtocol.Response {
      .init(id: request.id, ok: false, result: nil, error: .init(code: code, message: message,
        details: ["phase": .string("artifactOwner"), "newDispatchCount": .integer(0)]))
    }
    do {
      guard let artifacts else { return failed("operationUnavailable", "Artifact store is unavailable") }
      let fields = request.params ?? [:]
      let allowed: Set<String>
      switch request.method {
      case "artifact.list": allowed = ["owner", "pageSize", "cursor"]
      case "artifact.inspect": allowed = ["owner", "artifactId"]
      case "artifact.read": allowed = ["owner", "artifactId", "offset", "maxBytes", "allowSensitive"]
      case "artifact.export": allowed = ["owner", "artifactId", "destinationDirectory", "overwrite", "allowSensitive"]
      default: return failed("unknownMethod", "Artifact resource method is not published")
      }
      guard Set(fields.keys).isSubset(of: allowed), let ownerValue = fields["owner"] else {
        return failed("invalidInput", "Artifact parameters require one tagged owner and closed options")
      }
      let owner = try ArtifactOwnerReference(ownerValue)
      if owner.kind == "job" { _ = try await engine.jobReadSnapshot(jobID: owner.id) }
      func flag(_ key: String) throws -> Bool {
        guard let value = fields[key] else { return false }
        guard case .bool(let flag) = value else { throw AgentExecutionControlFailure("invalidInput", "Artifact flags must be booleans") }
        return flag
      }
      func count(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = fields[key] else { return fallback }
        guard let number = ArtifactReadProjection.count(value), range.contains(number) else {
          throw AgentExecutionControlFailure("invalidInput", "Artifact integer option is outside its published bound")
        }
        return number
      }
      let result: JSONValue
      if request.method == "artifact.list" {
        var cursor: String?
        if let value = fields["cursor"] {
          guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 2048 else { return failed("invalidCursor", "Artifact cursor is malformed") }
          cursor = text
        }
        result = try await artifacts.artifactInventory(owner: owner, pageSize: count("pageSize", default: 100, range: 1...1000), cursor: cursor)
      } else {
        guard case .string(let artifactID)? = fields["artifactId"], AgentExecutionIntent.validIdentifier(artifactID) else {
          return failed("invalidInput", "exact Artifact identity is required")
        }
        switch request.method {
        case "artifact.inspect": result = try await artifacts.inspectArtifact(owner: owner, artifactID: artifactID)
        case "artifact.read": result = try await artifacts.readArtifact(owner: owner, artifactID: artifactID,
          offset: count("offset", default: 0, range: 0...Int(ArtifactReadProjection.maximumSafeInteger)),
          maximumBytes: count("maxBytes", default: 1_048_576, range: 1...ArtifactReadProjection.maximumBytes), allowSensitive: flag("allowSensitive"))
        case "artifact.export":
          guard case .string(let path)? = fields["destinationDirectory"], path.hasPrefix("/"), path.utf8.count <= 4096 else {
            return failed("invalidInput", "export destination must be an absolute bounded host directory")
          }
          result = try await artifacts.exportArtifact(owner: owner, artifactID: artifactID,
            destinationDirectory: URL(filePath: path, directoryHint: .isDirectory), overwrite: flag("overwrite"), allowSensitive: flag("allowSensitive"))
        default: return failed("unknownMethod", "Artifact resource method is not published")
        }
      }
      return .init(id: request.id, ok: true,
        result: try RuntimeJobReadProjection.bounded(result, maximumBytes: 8 * 1024 * 1024 - 4096), error: nil)
    } catch let error as AgentExecutionControlFailure { return failed(error.code, error.message) }
    catch RuntimeJobEngineError.jobNotFound { return failed("resourceNotFound", "Artifact Job owner does not exist") }
    catch RuntimeArtifactError.artifactNotFound { return failed("resourceNotFound", "Artifact does not exist for this owner") }
    catch RuntimeArtifactError.sensitiveAccessRequiresOptIn { return failed("sensitiveAccessDenied", "sensitive Artifact content requires explicit permission") }
    catch RuntimeArtifactError.indexCorrupted { return failed("artifactIntegrityFailed", "Artifact metadata or immutable content is inconsistent") }
    catch { return failed("recordUnreadable", "Artifact resource is unreadable") }
  }
}
