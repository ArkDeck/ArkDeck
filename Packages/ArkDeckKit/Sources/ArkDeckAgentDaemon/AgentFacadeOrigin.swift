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
    guard let object = try? ControlFrameJSON.decodeObject(line, maximumBytes: 1024),
      Set(object.keys) == ["arkdeckPairing", "secret"],
      object["arkdeckPairing"] == .integer(1),
      case .string(let provided)? = object["secret"],
      provided.utf8.count == secret.utf8.count else { return false }
    return zip(provided.utf8, secret.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

struct AgentFacadeOrigin: Sendable {
  let context: RuntimeControlRequestContext
  let frameSHA256: String

  /// Typed private metadata avoids JSONValue's speculative scalar decodes on
  /// every forwarded frame. Duplicate, unknown and malformed fields remain closed.
  private struct Fields: Decodable {
    let arkdeckOrigin: Int
    let transport: String
    let foregroundConsole: Bool
    let peerEUID: Int64
    let peerPID: Int64
    let frameSHA256: String

    private struct Key: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init?(intValue: Int) { return nil }
      init(stringValue: String) { self.stringValue = stringValue }
    }
    init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: Key.self)
      guard Set(fields.allKeys.map(\.stringValue)) == [
        "arkdeckOrigin", "transport", "foregroundConsole", "peerEUID", "peerPID", "frameSHA256"
      ] else { throw ControlFrameJSON.Failure.malformed }
      arkdeckOrigin = try fields.decode(Int.self, forKey: Key(stringValue: "arkdeckOrigin"))
      transport = try fields.decode(String.self, forKey: Key(stringValue: "transport"))
      foregroundConsole = try fields.decode(Bool.self, forKey: Key(stringValue: "foregroundConsole"))
      peerEUID = try fields.decode(Int64.self, forKey: Key(stringValue: "peerEUID"))
      peerPID = try fields.decode(Int64.self, forKey: Key(stringValue: "peerPID"))
      frameSHA256 = try fields.decode(String.self, forKey: Key(stringValue: "frameSHA256"))
    }
  }

  init?(_ line: Data) {
    guard line.count < 1024, String(data: line, encoding: .utf8) != nil,
      !line.contains(0x0A), !line.contains(0x0D) else { return nil }
    var validator = StrictJSONDuplicateValidator(data: line)
    guard (try? validator.validate()) != nil,
      let fields = try? JSONDecoder().decode(Fields.self, from: line),
      fields.arkdeckOrigin == 1, fields.peerEUID == Int64(geteuid()),
      fields.peerPID >= 0, fields.peerPID <= Int32.max,
      fields.frameSHA256.utf8.count == 64,
      fields.frameSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    let pid = fields.peerPID, foreground = fields.foregroundConsole
    switch fields.transport {
    case "unixSocket":
      guard !foreground || pid > 1 else { return nil }
      context = .unixSocket(foregroundConsole: foreground)
    case "appXPC":
      guard !foreground, pid > 1 else { return nil }
      context = .appXPC
    default: return nil
    }
    frameSHA256 = fields.frameSHA256
  }

  func validates(_ frame: Data) -> Bool { SHA256Hex.string(of: frame) == frameSHA256 }
}

extension AgentXPCEndpoint {
  /// Transport adapter only: retain the existing App allowlist and one-shot gate.
  /// Both raw XPC and forwarded appXPC use the same response-frame encoding.
  func responseFrame(_ frame: Data) async -> Data {
    let fields: [String: JSONValue]
    do { fields = try ControlProtocolContract.requestFields(frame) }
    catch {
      let incompatible = (error as? ControlProtocolContract.Failure) == .unsupportedVersion
        || (error as? ControlProtocolContract.Failure) == .contractMismatch
      let decoded = try? ControlFrameJSON.decodeObject(frame,
        maximumBytes: ArkDeckControlProtocol.maximumRequestFrameBytes)
      let id: String
      if incompatible, case .string(let value)? = decoded?["id"] { id = value }
      else { id = "" }
      return Self.transportRefusal(id: id,
        code: incompatible ? "unsupportedProtocolVersion" : "malformedFrame")
    }
    guard case .string(let id)? = fields["id"], case .string(let method)? = fields["method"] else {
      return Self.transportRefusal(id: "", code: "malformedFrame")
    }
    guard ArkDeckControlProtocol.methods.contains(method) else {
      return Self.transportRefusal(id: id, code: "unknownMethod")
    }
    return await withCheckedContinuation { continuation in
      sendRequestFrame(frame) { response, refusal in
        if let response { continuation.resume(returning: response); return }
        continuation.resume(returning: Self.transportRefusal(id: id, code: refusal ?? "malformedFrame"))
      }
    }
  }

  private static func transportRefusal(id: String, code: String) -> Data {
    let value: JSONValue = .object([
      "id": .string(id), "ok": .bool(false),
      "error": .object(["code": .string(code),
        "message": .string("Runtime transport refused this request")])])
    var bytes = (try? CanonicalJSONEncoders.canonical().encode(value)) ?? Data()
    bytes.append(10)
    return bytes
  }
}
