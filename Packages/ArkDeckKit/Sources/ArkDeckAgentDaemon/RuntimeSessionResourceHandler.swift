import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Protocol-2 Session discovery and pinning over the daemon-owned storage
/// resource. The caller supplies only an opaque Session identity, pagination
/// token or catalog generation; no local path crosses this boundary.
struct RuntimeSessionResourceHandler {
  let storage: RuntimeSessionStorageStore?
  let activeSessionIDs: @Sendable () async -> Set<String>

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    func failed(_ code: String, _ message: String) -> AgentWireProtocol.Response {
      .init(
        id: request.id, ok: false, result: nil,
        error: .init(
          code: code, message: message,
          details: [
            "phase": .string("sessionOwner"),
            "newDispatchCount": .integer(0),
          ]))
    }

    guard request.protocolVersion == ArkDeckControlProtocol.targetVersion else {
      return failed("unknownMethod", "Session resources require protocol 2")
    }
    guard let storage else {
      return failed("operationUnavailable", "Runtime Session storage is not configured")
    }

    do {
      let fields = request.params ?? [:]
      let result: JSONValue
      switch request.method {
      case "session.cleanup.preview":
        guard fields.isEmpty else {
          return failed("invalidInput", "Session cleanup preview accepts no caller facts")
        }
        result = try storage.previewSessionCleanup(
          activeSessionIDs: await activeSessionIDs())

      case "session.cleanup.apply":
        guard Set(fields.keys) == ["previewId", "previewDigest"],
          case .string(let previewID)? = fields["previewId"],
          case .string(let previewDigest)? = fields["previewDigest"]
        else {
          return failed("invalidInput", "Session cleanup apply requires one preview tuple")
        }
        result = try storage.applySessionCleanup(
          previewID: previewID, previewDigest: previewDigest,
          activeSessionIDs: await activeSessionIDs())

      case "session.export.preview":
        guard Set(fields.keys) == ["sessionId", "destinationPath", "allowSensitive"],
          case .string(let sessionID)? = fields["sessionId"],
          case .string(let destinationPath)? = fields["destinationPath"],
          case .bool(let allowSensitive)? = fields["allowSensitive"]
        else {
          return failed(
            "invalidInput",
            "Session export preview requires one Session, one destination and one privacy choice")
        }
        result = try storage.previewSessionExport(
          sessionID: sessionID, destinationPath: destinationPath,
          allowSensitive: allowSensitive)

      case "session.export.apply":
        guard Set(fields.keys) == ["previewId", "previewDigest"],
          case .string(let previewID)? = fields["previewId"],
          case .string(let previewDigest)? = fields["previewDigest"]
        else {
          return failed("invalidInput", "Session export apply requires one preview tuple")
        }
        result = try storage.applySessionExport(
          previewID: previewID, previewDigest: previewDigest)

      case "session.list":
        guard Set(fields.keys).isSubset(of: ["pageSize", "cursor"]) else {
          return failed("invalidInput", "Session list options are closed")
        }
        let pageSize: Int
        if let value = fields["pageSize"] {
          guard case .integer(let count) = value, (1...1_000).contains(count) else {
            return failed("invalidInput", "pageSize must be between 1 and 1000")
          }
          pageSize = Int(count)
        } else {
          pageSize = 100
        }
        let cursor: String?
        if let value = fields["cursor"] {
          guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 2_048 else {
            return failed("invalidCursor", "Session cursor is malformed")
          }
          cursor = text
        } else {
          cursor = nil
        }
        result = try storage.listSessions(pageSize: pageSize, cursor: cursor)

      case "session.show":
        guard Set(fields.keys) == ["sessionId"],
          case .string(let sessionID)? = fields["sessionId"]
        else {
          return failed("invalidInput", "Session show requires one Session identity")
        }
        result = try storage.showSession(sessionID: sessionID)

      case "session.pin", "session.unpin":
        guard Set(fields.keys) == ["sessionId", "expectedGeneration"],
          case .string(let sessionID)? = fields["sessionId"],
          let generation = canonicalGeneration(fields["expectedGeneration"])
        else {
          return failed(
            "invalidInput", "Session pin transition requires an identity and catalog generation")
        }
        result = try storage.updateSessionPin(
          sessionID: sessionID, isPinned: request.method == "session.pin",
          expectedGeneration: generation)

      default:
        return failed("unknownMethod", "Session resource method is not published")
      }
      return .init(id: request.id, ok: true, result: result, error: nil)
    } catch let failure as RuntimeSessionStorageFailure {
      return failed(failure.code, failure.message)
    } catch let failure as AgentExecutionControlFailure {
      return failed(failure.code, failure.message)
    } catch {
      let mutation = request.method == "session.pin" || request.method == "session.unpin"
        || request.method == "session.cleanup.apply"
        || request.method == "session.export.apply"
      return failed(
        mutation ? "outcomeUnknown" : "recordUnreadable",
        mutation
          ? "Session pin publication outcome is unknown"
          : "Session catalog is unreadable")
    }
  }

  private func canonicalGeneration(_ value: JSONValue?) -> UInt64? {
    guard case .string(let text)? = value, !text.isEmpty,
      text.utf8.allSatisfy({ (48...57).contains($0) }),
      text == "0" || text.first != "0",
      let parsed = UInt64(text), parsed <= UInt64(Int64.max)
    else { return nil }
    return parsed
  }
}
