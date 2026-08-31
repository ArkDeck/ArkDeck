import Foundation

/// Version-neutral, unary bootstrap. It selects a wire format, never authority.
/// The v2 method allowlist grows only when a complete target handler is published.
package enum ControlProtocolNegotiation {
  package enum Failure: Error, Equatable {
    case malformed
    case unsupported
  }

  private struct Version: Comparable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64

    init?(_ text: String) {
      let parts = text.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3 else { return nil }
      let values = parts.compactMap { part -> UInt64? in
        guard !part.isEmpty, part == "0" || part.first != "0",
          part.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return UInt64(part)
      }
      guard values.count == 3 else { return nil }
      major = values[0]
      minor = values[1]
      patch = values[2]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
  }

  package static func validateVersions(_ versions: [String]) throws {
    guard !versions.isEmpty else { throw Failure.malformed }
    let parsed = versions.compactMap(Version.init)
    guard parsed.count == versions.count,
      zip(parsed, parsed.dropFirst()).allSatisfy({ $0 > $1 })
    else { throw Failure.malformed }
  }

  package static func select(
    client: [String], daemon: [String], requiredMajor: Int
  ) throws -> String {
    try validateVersions(client)
    try validateVersions(daemon)
    guard requiredMajor > 0 else { throw Failure.malformed }
    guard
      let selected = client.first(where: {
        Version($0)?.major == UInt64(requiredMajor) && daemon.contains($0)
      })
    else { throw Failure.unsupported }
    return selected
  }

  package static func request(id: String, requiredMajor: Int) throws -> Data {
    guard validID(id), requiredMajor > 0 else { throw Failure.malformed }
    return try encode([
      "bootstrapVersion": .string(ArkDeckControlProtocol.bootstrapVersion),
      "id": .string(id),
      "method": .string(ArkDeckControlProtocol.bootstrapMethod),
      "supportedExactVersions": .array(
        ArkDeckControlProtocol.supportedExactVersions.map(JSONValue.string)),
      "requiredMajor": .integer(Int64(requiredMajor)),
    ])
  }

  /// `nil` identifies a domain frame, which remains on its existing table.
  package static func responseIfBootstrap(_ data: Data) -> Data? {
    guard let object = try? decodeObject(data, maximumBytes: 4 * 1024 * 1024),
      object["method"] == .string(ArkDeckControlProtocol.bootstrapMethod)
    else { return nil }
    let id = string(object["id"]).flatMap { validID($0) ? $0 : nil } ?? "-"
    var response: [String: JSONValue] = [
      "bootstrapVersion": .string(ArkDeckControlProtocol.bootstrapVersion),
      "id": .string(id),
      "daemonSupportedExactVersions": .array(
        ArkDeckControlProtocol.supportedExactVersions.map(JSONValue.string)),
    ]
    do {
      guard data.count + 1 <= ArkDeckControlProtocol.maximumBootstrapFrameBytes,
        Set(object.keys)
          == Set([
            "bootstrapVersion", "id", "method", "supportedExactVersions", "requiredMajor",
          ]), object["bootstrapVersion"] == .string(ArkDeckControlProtocol.bootstrapVersion),
        string(object["id"]) == id, validID(id),
        let versions = strings(object["supportedExactVersions"]),
        case .integer(let major)? = object["requiredMajor"], let requiredMajor = Int(exactly: major)
      else { throw Failure.malformed }
      let selected = try select(
        client: versions, daemon: ArkDeckControlProtocol.supportedExactVersions,
        requiredMajor: requiredMajor)
      response["ok"] = .bool(true)
      response["selectedExactVersion"] = .string(selected)
    } catch {
      response["ok"] = .bool(false)
      response["error"] = .object([
        "code": .string(
          error as? Failure == .unsupported
            ? "protocolVersionUnsupported" : "protocolMalformed")
      ])
    }
    return try? encode(response)
  }

  package static func selectedVersion(
    response data: Data, id: String, requiredMajor: Int
  ) throws -> String {
    let object = try decodeObject(
      data, maximumBytes: ArkDeckControlProtocol.maximumBootstrapFrameBytes)
    let common: Set<String> = ["bootstrapVersion", "id", "ok", "daemonSupportedExactVersions"]
    guard object["bootstrapVersion"] == .string(ArkDeckControlProtocol.bootstrapVersion),
      object["id"] == .string(id), let daemon = strings(object["daemonSupportedExactVersions"])
    else { throw Failure.malformed }
    try validateVersions(daemon)
    if object["ok"] == .bool(true) {
      guard Set(object.keys) == common.union(["selectedExactVersion"]),
        let selected = string(object["selectedExactVersion"])
      else { throw Failure.malformed }
      guard
        let expected = try? select(
          client: ArkDeckControlProtocol.supportedExactVersions, daemon: daemon,
          requiredMajor: requiredMajor)
      else { throw Failure.malformed }
      guard selected == expected else { throw Failure.malformed }
      return selected
    }
    guard object["ok"] == .bool(false), Set(object.keys) == common.union(["error"]),
      case .object(let error)? = object["error"], Set(error.keys) == ["code"],
      let code = string(error["code"])
    else { throw Failure.malformed }
    if code == "protocolVersionUnsupported" {
      do {
        _ = try select(
          client: ArkDeckControlProtocol.supportedExactVersions, daemon: daemon,
          requiredMajor: requiredMajor)
      } catch Failure.unsupported { throw Failure.unsupported }
      throw Failure.malformed
    }
    throw Failure.malformed
  }

  /// The only pre-bootstrap refusal accepted for a legacy health fallback.
  /// A timeout, invalid response or unknown outcome is never a downgrade hint.
  package static func isPreBootstrapRefusal(_ data: Data) -> Bool {
    guard
      let object = try? decodeObject(
        data, maximumBytes: ArkDeckControlProtocol.maximumBootstrapFrameBytes),
      object["id"] == .string("-"), object["ok"] == .bool(false),
      Set(object.keys).isSubset(of: ["id", "ok", "result", "error"]),
      object["result"] == nil || object["result"] == .null,
      case .object(let error)? = object["error"],
      Set(error.keys) == ["code", "message"],
      error["code"] == .string("malformedFrame"), string(error["message"]) != nil
    else { return false }
    return true
  }

  package static func decodeObject(_ data: Data, maximumBytes: Int) throws -> [String: JSONValue] {
    guard data.count + 1 <= maximumBytes,
      String(data: data, encoding: .utf8) != nil,
      !data.contains(0x0A), !data.contains(0x0D)
    else { throw Failure.malformed }
    var validator = StrictJSONDuplicateValidator(data: data)
    try validator.validate()
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
  }

  private static func encode(_ object: [String: JSONValue]) throws -> Data {
    let data = try CanonicalJSONEncoders.canonical().encode(object)
    guard data.count + 1 <= ArkDeckControlProtocol.maximumBootstrapFrameBytes else {
      throw Failure.malformed
    }
    return data
  }

  private static func validID(_ id: String) -> Bool {
    (1...128).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { $0.value >= 0x20 }
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }

  private static func strings(_ value: JSONValue?) -> [String]? {
    guard case .array(let values)? = value else { return nil }
    let strings = values.compactMap { string($0) }
    return strings.count == values.count ? strings : nil
  }
}
