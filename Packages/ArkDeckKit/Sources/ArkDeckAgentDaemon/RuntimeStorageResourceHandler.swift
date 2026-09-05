import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Current v1 projection of the Runtime's two distinct storage domains.
///
/// Session output configuration and measurement come from one daemon-owned
/// durable owner. Immutable Runtime Artifacts retain their existing owner and
/// quota policy; the aggregate keeps both domains separate rather than adding
/// unlike byte counts together.
struct RuntimeStorageResourceHandler {
  let sessions: RuntimeSessionStorageStore?
  let artifacts: RuntimeArtifactStore?

  func response(_ request: AgentWireProtocol.Request) async -> AgentWireProtocol.Response {
    func failed(_ code: String, _ message: String) -> AgentWireProtocol.Response {
      .init(
        id: request.id, ok: false, result: nil,
        error: .init(
          code: code, message: message,
          details: [
            "phase": .string("runtimeStorageOwner"),
            "newDispatchCount": .integer(0),
          ]))
    }
    do {
      guard let sessions, let artifacts else {
        return failed("operationUnavailable", "Runtime storage owners are not configured")
      }
      // Measure the independent Artifact domain before any Session mutation.
      // A failed aggregate read therefore cannot hide a completed policy/root
      // write behind a generic read error and tempt a caller to replay it.
      let used = try await artifacts.totalBytesUsed()
      let total = await artifacts.quotaTotalBytes
      let fields = request.params ?? [:]
      let sessionStatus: RuntimeSessionStorageStatus
      switch request.method {
      case "runtime.storage.status":
        guard fields.isEmpty else {
          return failed("invalidInput", "Runtime storage status accepts no parameters")
        }
        sessionStatus = try sessions.status()

      case "runtime.storage.policy":
        guard Set(fields.keys) == [
          "expectedGeneration", "totalQuotaBytes", "safetyMarginBytes", "retentionDays",
        ] else {
          return failed("invalidInput", "Runtime storage policy requires one closed policy document")
        }
        sessionStatus = try sessions.updatePolicy(
          RuntimeSessionStoragePolicy(
            totalQuotaBytes: try positive(fields["totalQuotaBytes"], label: "totalQuotaBytes"),
            safetyMarginBytes: try positive(
              fields["safetyMarginBytes"], label: "safetyMarginBytes"),
            retentionDays: try positive(fields["retentionDays"], label: "retentionDays")),
          expectedGeneration: try positive(
            fields["expectedGeneration"], label: "expectedGeneration"))

      case "runtime.storage.root":
        guard fields.keys.contains("expectedGeneration"),
          Set(fields.keys).isSubset(of: ["expectedGeneration", "rootPath", "resetToDefault"])
        else {
          return failed("invalidInput", "Runtime storage root requires a generation and one selection")
        }
        let path: String?
        if let value = fields["rootPath"] {
          guard case .string(let candidate) = value else {
            return failed("invalidInput", "rootPath must be a string")
          }
          path = candidate
        } else {
          path = nil
        }
        let reset: Bool
        if let value = fields["resetToDefault"] {
          guard case .bool(let flag) = value, flag else {
            return failed("invalidInput", "resetToDefault must be true when present")
          }
          reset = flag
        } else {
          reset = false
        }
        sessionStatus = try sessions.updateRoot(
          path: path, resetToDefault: reset,
          expectedGeneration: try positive(
            fields["expectedGeneration"], label: "expectedGeneration"))

      default:
        return failed("unknownMethod", "Runtime storage method is not published")
      }
      return .init(
        id: request.id, ok: true,
        result: .object([
          "schemaVersion": .string("arkdeck.runtime-storage/1"),
          "sessionDomain": sessionStatus.projection,
          "artifactDomain": .object([
            "schemaVersion": .string("arkdeck.artifact-storage-status/1"),
            "rootReference": .string("arkdeck-runtime://artifacts"),
            "policy": .string("refuseNewWorkNeverEvict"),
            "totalBytes": .string(String(total)),
            "usedBytes": .string(String(used)),
            "remainingBytes": .string(String(max(0, total - used))),
          ]),
        ]),
        error: nil)
    } catch let failure as RuntimeSessionStorageFailure {
      return failed(failure.code, failure.message)
    } catch {
      return failed("recordUnreadable", "Runtime storage state is unreadable")
    }
  }

  private func positive(_ value: JSONValue?, label: String) throws -> UInt64 {
    guard case .string(let text)? = value,
      !text.isEmpty, text.first != "0",
      text.utf8.allSatisfy({ (48...57).contains($0) }),
      let parsed = UInt64(text), parsed <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "\(label) must be a canonical positive integer")
    }
    return parsed
  }
}
