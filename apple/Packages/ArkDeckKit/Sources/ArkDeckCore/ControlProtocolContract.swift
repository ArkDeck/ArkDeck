import Foundation

/// One current control contract. Identity distinguishes prerelease builds that
/// used the same version label; it conveys no Runtime authority.
package enum ControlProtocolContract {
  package enum Failure: Error, Equatable {
    case malformed
    case unsupportedVersion
    case contractMismatch
  }

  package static func requestFields(_ bytes: Data) throws -> [String: JSONValue] {
    let fields = try ControlFrameJSON.decodeObject(
      bytes, maximumBytes: ArkDeckControlProtocol.maximumRequestFrameBytes)
    guard Set(fields.keys).isSubset(of: ["protocolVersion", "contractIdentity", "id", "method", "params"]),
      case .string(let id)? = fields["id"], validID(id),
      case .string(let method)? = fields["method"], !method.isEmpty, method.utf8.count <= 128
    else { throw Failure.malformed }
    guard fields["protocolVersion"] == .string(ArkDeckControlProtocol.currentVersion) else {
      throw Failure.unsupportedVersion
    }
    guard fields["contractIdentity"] == .string(ArkDeckControlProtocol.contractIdentity) else {
      throw Failure.contractMismatch
    }
    if let params = fields["params"] {
      guard case .object = params else { throw Failure.malformed }
    }
    return fields
  }

  package static func responseFields(_ bytes: Data, id: String) throws -> [String: JSONValue] {
    let fields = try ControlFrameJSON.decodeObject(
      bytes, maximumBytes: ArkDeckControlProtocol.maximumResponseFrameBytes)
    guard validID(id), fields["id"] == .string(id) else { throw Failure.malformed }
    if fields["ok"] == .bool(true) {
      guard Set(fields.keys) == ["id", "ok", "result"] else { throw Failure.malformed }
    } else {
      guard fields["ok"] == .bool(false), Set(fields.keys) == ["id", "ok", "error"],
        case .object(let error)? = fields["error"],
        Set(error.keys).isSubset(of: ["code", "message", "details"]),
        case .string(let code)? = error["code"], !code.isEmpty,
        case .string? = error["message"]
      else { throw Failure.malformed }
      if let details = error["details"] {
        guard case .object = details else { throw Failure.malformed }
      }
    }
    return fields
  }

  package static func validateHealth(_ bytes: Data, id: String) throws {
    let response = try responseFields(bytes, id: id)
    guard response["ok"] == .bool(true), case .object(let health)? = response["result"],
      Set(health.keys) == ["status", "protocolVersion", "contractIdentity", "publishedMethods", "catalogDigest", "providers"],
      health["status"] == .string("ok"),
      health["protocolVersion"] == .string(ArkDeckControlProtocol.currentVersion),
      health["contractIdentity"] == .string(ArkDeckControlProtocol.contractIdentity),
      health["publishedMethods"] == .array(ArkDeckControlProtocol.methods.sorted().map(JSONValue.string)),
      case .string(let digest)? = health["catalogDigest"], SHA256Hex.isLowercaseSHA256(digest),
      case .array(let providers)? = health["providers"],
      providers.allSatisfy({ if case .string(let value) = $0 { return !value.isEmpty }; return false })
    else { throw Failure.contractMismatch }
  }

  private static func validID(_ id: String) -> Bool {
    (1...128).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { $0.value >= 0x20 }
  }
}
