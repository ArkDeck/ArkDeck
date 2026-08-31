import ArkDeckCore
import ArkDeckWorkflows
import Darwin
import Foundation

struct RuntimeImportControlHandler {
  let artifacts: RuntimeArtifactStore?
  let targets: RuntimeTargetStore?
  let flashPolicy: FlashBundleImportPolicy
  let engine: RuntimeJobEngine

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    do {
      guard request.protocolVersion == ArkDeckControlProtocol.targetVersion else {
        throw AgentExecutionControlFailure("unknownMethod", "durable Import resources require protocol 2")
      }
      guard let artifacts, let targets else { throw AgentExecutionControlFailure("operationUnavailable", "Import owner services are unavailable") }
      let fields = request.params ?? [:]
      func exact(_ keys: Set<String>) throws {
        guard Set(fields.keys) == keys else { throw AgentExecutionControlFailure("invalidInput", "Import control parameters are closed") }
      }
      func string(_ key: String) throws -> String {
        guard case .string(let value)? = fields[key], !value.isEmpty else { throw AgentExecutionControlFailure("invalidInput", "Import identity is required") }
        return value
      }
      func generation() throws -> Int {
        guard let count = ArtifactImportIntent.decimal(fields["generation"]), count > 0 else {
          throw AgentExecutionControlFailure("invalidInput", "exact Import generation is required")
        }
        return count
      }
      let result: JSONValue
      switch request.method {
      case "artifact.import.begin":
        let intent = try ArtifactImportIntent(fields)
        do {
          let existing = try await artifacts.inspectImport(requestID: intent.importRequestID)
          guard existing.intent == intent else { throw AgentExecutionControlFailure("idempotencyConflict", "Import request identity already names different metadata") }
          result = existing.projection
        } catch let failure as AgentExecutionControlFailure where failure.code == "resourceNotFound" {
          let binding = try Self.binding(intent, targets: targets)
          result = try await artifacts.beginImport(intent, binding: binding)
        }
      case "artifact.import.append":
        try exact(["importId", "generation", "offset", "byteCount", "sha256", "base64"])
        guard let offset = ArtifactImportIntent.decimal(fields["offset"]),
          let count = ArtifactImportIntent.decimal(fields["byteCount"]), (1...ArtifactImportIntent.maximumChunkBytes).contains(count),
          case .string(let digest)? = fields["sha256"], SHA256Hex.isLowercaseSHA256(digest),
          case .string(let encoded)? = fields["base64"], encoded.utf8.count <= 4 * 1024 * 1024,
          let chunk = Data(base64Encoded: encoded), chunk.count == count, chunk.base64EncodedString() == encoded else {
          throw AgentExecutionControlFailure("invalidInput", "Import append requires exact bounded bytes, offset and digest")
        }
        result = try await artifacts.appendImport(id: string("importId"), generation: generation(), offset: offset, chunk: chunk, sha256: digest)
      case "artifact.import.commit":
        try exact(["importId", "generation"])
        let policy = flashPolicy
        result = try await artifacts.commitImport(id: string("importId"), generation: generation()) { file, record in
          guard try Self.binding(record.intent, targets: targets) == record.binding else {
            throw AgentExecutionControlFailure("resourceConflict", "target binding changed during Import")
          }
          return try Self.validate(file, record: record, policy: policy)
        }
      case "artifact.import.release":
        try exact(["importId", "generation"])
        result = try await engine.releaseImport(id: string("importId"), generation: generation())
      case "artifact.import.abort":
        try exact(["importRequestId", "generation"])
        result = try await artifacts.abortImport(requestID: string("importRequestId"), generation: generation())
      case "artifact.import.inspect":
        guard Set(fields.keys) == ["importId"] || Set(fields.keys) == ["importRequestId"] else {
          throw AgentExecutionControlFailure("invalidInput", "exactly one Import selector is required")
        }
        result = try await artifacts.inspectImport(id: fields["importId"].map { _ in try string("importId") },
          requestID: fields["importRequestId"].map { _ in try string("importRequestId") }).projection
      case "artifact.import.list": result = try await artifacts.listImports(fields)
      default: throw AgentExecutionControlFailure("unknownMethod", "Import method is not published")
      }
      return .init(id: request.id, ok: true, result: try RuntimeJobReadProjection.bounded(result), error: nil)
    } catch let error as AgentExecutionControlFailure {
      // Zero device dispatch is true even after host upload state has changed;
      // never claim preAdmission for an ambiguous Import write.
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: error.code, message: error.message, details: ["phase": .string("importOwner"), "newDispatchCount": .integer(0)]))
    } catch RuntimeArtifactError.quotaExceeded {
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: "quotaExceeded", message: "Artifact capacity is exhausted; the Import remains discoverable",
          details: ["phase": .string("importOwner"), "newDispatchCount": .integer(0)]))
    } catch {
      return .init(id: request.id, ok: false, result: nil,
        error: .init(code: "recordUnreadable", message: "Import state or immutable content is unreadable",
          details: ["phase": .string("importOwner"), "newDispatchCount": .integer(0)]))
    }
  }

  private static func binding(_ intent: ArtifactImportIntent, targets: RuntimeTargetStore) throws -> ArtifactBindingSnapshot {
    guard let target = try targets.find(targetID: intent.targetID), target.bindingRevision == intent.bindingRevision else {
      throw AgentExecutionControlFailure("resourceConflict", "the exact target binding is no longer current")
    }
    switch intent.kind {
    case "workspace-patch": return .init(targetID: target.targetID, bindingRevision: nil, stableIdentitySHA256: nil)
    case "flash-bundle": return .init(targetID: target.targetID, bindingRevision: target.bindingRevision,
      stableIdentitySHA256: target.stablePhysicalIdentitySHA256)
    default:
      guard let route = try targets.hdcExecutionRoute(targetID: target.targetID), route.bindingRevision == target.bindingRevision else {
        throw AgentExecutionControlFailure("resourceConflict", "Import requires the target's current proven HDC route")
      }
      return .init(targetID: target.targetID, bindingRevision: target.bindingRevision,
        stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: route.connectKey))
    }
  }
  private static func bytes(_ file: URL, maximum: Int) throws -> Data {
    let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "Import payload cannot be opened") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximum else {
      throw AgentExecutionControlFailure("invalidInput", "Import payload exceeds its registered bound")
    }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: min(maximum, 1024 * 1024))
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0, data.count <= maximum - count else { throw AgentExecutionControlFailure("recordUnreadable", "Import payload changed or could not be read") }
      if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }
  private static func validate(_ file: URL, record: RuntimeImportRecord, policy: FlashBundleImportPolicy) throws -> [String: JSONValue] {
    do {
      switch record.intent.kind {
      case "hap":
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentExecutionControlFailure("recordUnreadable", "Import payload cannot be opened") }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: 4)
        guard pread(descriptor, &header, header.count, 0) == 4, header == [0x50, 0x4b, 0x03, 0x04] else {
          throw AgentExecutionControlFailure("invalidInput", "Import is not a ZIP-based HAP/HSP container")
        }
        return ["kind": .string("hap"), "container": .string("zip")]
      case "workspace-patch":
        let paths = try WorkspaceProviderSupport.patchPaths(from: bytes(file, maximum: 512 * 1024))
        return ["kind": .string("workspace-patch"), "touchedFiles": .array(paths.map(JSONValue.string))]
      case "native-library":
        let value = try NativeLibraryArtifactValidator.validate(bytes(file, maximum: 64 * 1024 * 1024), requireOpenHarmonyCodeSignature: true)
        return ["kind": .string("native-library"), "abi": .string(value.abi.rawValue),
          "elfClassBits": .integer(Int64(value.elfClassBits)), "machine": .integer(Int64(value.machine)), "buildId": .string(value.buildID)]
      case "flash-bundle":
        guard record.intent.deviceProfile == "dayu200", let candidate = policy.candidate(byteCount: record.intent.byteCount, sha256: record.intent.sha256) else {
          throw AgentExecutionControlFailure("invalidInput", "Import flash profile is not registered")
        }
        let value = try candidate.validate(file)
        guard value.byteCount == record.intent.byteCount, value.sha256 == record.intent.sha256 else {
          throw AgentExecutionControlFailure("artifactIntegrityFailed", "validated archive does not match Import metadata")
        }
        return ["kind": .string("flash-bundle"), "deviceProfile": .string("dayu200")]
      default: throw AgentExecutionControlFailure("invalidInput", "Import kind is not registered")
      }
    } catch let error as AgentExecutionControlFailure { throw error }
    catch { throw AgentExecutionControlFailure("invalidInput", "Import content failed its registered format validator") }
  }
}
