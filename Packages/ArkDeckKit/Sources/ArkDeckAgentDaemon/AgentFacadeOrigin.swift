import ArkDeckCore
import Darwin
import Foundation

/// Ephemeral pairing material, delivered on the child's inherited stdin pipe.
/// It is never a client request, RuntimeCapability, or durable Runtime record.
public struct AgentFacadeConfiguration: Sendable {
  public let socketURL: URL
  let secret: String

  public init(socketURL: URL, secret: String) throws {
    guard socketURL.path.hasPrefix("/"), secret.utf8.count == 64,
      secret.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AgentDaemonError.io("invalid private transport pairing") }
    self.socketURL = socketURL
    self.secret = secret
  }

  public static func inherited() throws -> Self? {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_PRIVATE_SOCKET"] else { return nil }
    var bytes = [UInt8]()
    for _ in 0..<65 {
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else {
        throw AgentDaemonError.io("private transport pairing pipe closed")
      }
      bytes.append(byte)
    }
    guard bytes.last == 10, let secret = String(bytes: bytes.dropLast(), encoding: .utf8) else {
      throw AgentDaemonError.io("invalid private transport pairing bytes")
    }
    return try Self(socketURL: URL(filePath: path), secret: secret)
  }

  func authenticates(_ line: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      Set(object.keys) == ["arkdeckPairing", "secret"],
      object["arkdeckPairing"] as? Int == 1,
      let provided = object["secret"] as? String,
      provided.utf8.count == secret.utf8.count else { return false }
    return zip(provided.utf8, secret.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

struct AgentFacadeOrigin: Sendable {
  let context: RuntimeControlRequestContext
  let frameSHA256: String

  init?(_ line: Data) {
    guard line.count <= 1024,
      let fields = try? JSONDecoder().decode([String: JSONValue].self, from: line),
      Set(fields.keys) == ["arkdeckOrigin", "transport", "foregroundConsole", "peerEUID", "peerPID", "frameSHA256"],
      fields["arkdeckOrigin"] == .integer(1),
      fields["peerEUID"] == .integer(Int64(geteuid())),
      case .integer(let pid)? = fields["peerPID"], pid >= 0, pid <= Int32.max,
      case .bool(let foreground)? = fields["foregroundConsole"],
      case .string(let digest)? = fields["frameSHA256"], digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    switch fields["transport"] {
    case .string("unixSocket"):
      guard !foreground || pid > 1 else { return nil }
      context = .unixSocket(foregroundConsole: foreground)
    case .string("appXPC"):
      guard !foreground, pid > 1 else { return nil }
      context = .appXPC
    default: return nil
    }
    frameSHA256 = digest
  }

  func validates(_ frame: Data) -> Bool { SHA256Hex.string(of: frame) == frameSHA256 }
}

extension AgentXPCEndpoint {
  /// Transport adapter only: retain the existing App allowlist and one-shot gate.
  /// Both raw XPC and forwarded appXPC use the same response-frame encoding.
  func responseFrame(_ frame: Data) async -> Data {
    await withCheckedContinuation { continuation in
      sendRequestFrame(frame) { response, refusal in
        if let response { continuation.resume(returning: response); return }
        let id = (try? JSONDecoder().decode(AgentWireProtocol.Request.self, from: frame))?.id ?? ""
        let value: JSONValue = .object([
          "id": .string(id), "ok": .bool(false),
          "error": .object(["code": .string(refusal ?? "malformedFrame"),
            "message": .string("Runtime transport refused this request")])])
        var bytes = (try? CanonicalJSONEncoders.canonical().encode(value)) ?? Data()
        bytes.append(10)
        continuation.resume(returning: bytes)
      }
    }
  }
}
