import ArkDeckCore
import Foundation

/// App uploads use the same typed, generation-bound import resource as CLI.
/// Lives in ClientKit because the Debug and Flash facades both drive it and the
/// Debug facade is a ClientKit type; it needs only ArkDeckCore.
/// The caller retains local file access; only bounded bytes cross transport.
package enum RuntimeAppArtifactUpload {
  package typealias Send = @Sendable (String, [String: JSONValue]) async throws -> Data

  /// Reads, hashes and encodes the whole file chunk by chunk, so it runs on
  /// the concurrent pool rather than on its caller's actor.
  @concurrent
  package static func upload(
    fileURL: URL, kind: String, targetID: String, bindingRevision: Int,
    name: String, byteCount: Int, sha256: String, send: Send
  ) async throws -> [String: JSONValue] {
    try await uploadSource(
      fileURL: fileURL, data: nil, kind: kind, targetID: targetID,
      bindingRevision: bindingRevision, name: name, byteCount: byteCount,
      sha256: sha256, send: send)
  }

  /// A small private input need not first be copied to an App temporary file.
  @concurrent
  package static func uploadKeyboard(
    data: Data, targetID: String, bindingRevision: Int, send: Send
  ) async throws -> [String: JSONValue] {
    guard !data.isEmpty, data.count <= 4096 else {
      throw AgentExecutionControlFailure("invalidInput", "Keyboard input exceeds its bounded format")
    }
    return try await uploadSource(
      fileURL: nil, data: data, kind: "keyboard-input", targetID: targetID,
      bindingRevision: bindingRevision, name: "keyboard-input.json", byteCount: data.count,
      sha256: SHA256Hex.string(of: data), send: send)
  }

  @concurrent
  private static func uploadSource(
    fileURL: URL?, data: Data?, kind: String, targetID: String, bindingRevision: Int,
    name: String, byteCount: Int, sha256: String, send: Send
  ) async throws -> [String: JSONValue] {
    let requestID = "app-import-\(UUID().uuidString.lowercased())"
    let fields: [String: JSONValue] = [
      "schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(requestID), "kind": .string(kind),
      "targetId": .string(targetID), "bindingRevision": .string(String(bindingRevision)),
      "deviceProfile": kind == "flash-bundle" ? .string("dayu200") : .null,
      "name": .string(name), "byteCount": .string(String(byteCount)), "sha256": .string(sha256),
    ]
    let intent = try ArtifactImportIntent(fields)
    func invalid(_ message: String) -> AgentExecutionControlFailure {
      .init("recordUnreadable", message)
    }
    func call(_ method: String, _ params: [String: JSONValue]) async throws -> ArtifactImportProjection {
      let bytes = try await send(method, params)
      let line = bytes.last == 0x0A ? Data(bytes.dropLast()) : bytes
      let response = try ControlFrameJSON.decodeObject(line, maximumBytes: ArkDeckControlProtocol.maximumResponseFrameBytes)
      guard response["ok"] == .bool(true), let result = response["result"] else {
        if case .object(let error)? = response["error"], case .string(let message)? = error["message"] {
          throw invalid(message)
        }
        throw invalid("Runtime returned no Import resource")
      }
      let projection = try ArtifactImportProjection(result)
      guard projection.intent == intent else { throw invalid("Runtime Import metadata changed") }
      return projection
    }
    let began: ArtifactImportProjection
    do {
      began = try await call("artifact.import.begin", fields)
    } catch {
      // Begin may have persisted before its reply was lost. The exact App
      // request identity can only abort its own still-in-progress generation.
      _ = try? await send("artifact.import.abort", [
        "importRequestId": .string(requestID), "generation": .string("1"),
      ])
      throw error
    }
    guard began.state == "inProgress", began.generation == 1, began.nextOffset == 0 else {
      throw invalid("Runtime did not start the requested Import")
    }
    let selector: [String: JSONValue] = [
      "importId": .string(began.id), "generation": .string(String(began.generation)),
    ]
    do {
      let file = try fileURL.map { try FileHandle(forReadingFrom: $0) }
      defer { try? file?.close() }
      var offset = 0
      while offset < byteCount {
        try Task.checkCancellation()
        let limit = min(began.maximumChunkBytes, 512 * 1024)
        let chunk: Data
        if let data {
          chunk = data.subdata(in: offset..<min(data.count, offset + limit))
        } else {
          chunk = try file?.read(upToCount: limit) ?? Data()
        }
        guard !chunk.isEmpty, chunk.count <= byteCount - offset else {
          throw invalid("Selected file changed during Import")
        }
        var append = selector
        append["offset"] = .string(String(offset))
        append["byteCount"] = .string(String(chunk.count))
        append["sha256"] = .string(SHA256Hex.string(of: chunk))
        append["base64"] = .string(chunk.base64EncodedString())
        let advanced = try await call("artifact.import.append", append)
        guard advanced.id == began.id, advanced.generation == began.generation,
          advanced.state == "inProgress", advanced.nextOffset == offset + chunk.count else {
          throw invalid("Runtime Import offset or generation changed")
        }
        offset = advanced.nextOffset
      }
      guard (try file?.read(upToCount: 1) ?? Data()).isEmpty else {
        throw invalid("Selected file changed during Import")
      }
      try Task.checkCancellation()
    } catch {
      _ = try? await send("artifact.import.abort", [
        "importRequestId": .string(requestID), "generation": .string(String(began.generation)),
      ])
      throw error
    }
    // A lost commit reply remains an unknown host publication. No new upload
    // or retry is sent; immutable committed content stays in Runtime storage.
    let committed = try await call("artifact.import.commit", selector)
    guard committed.id == began.id, committed.state == "committed",
      case .object(let resource) = committed.value,
      case .object(let receipt)? = resource["receipt"] else {
      throw invalid("Runtime returned no committed Import receipt")
    }
    return receipt
  }
}
