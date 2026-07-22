import ArkDeckCore
import Foundation

// TASK-AIN-006 (CHG-2026-025). This file defines and strictly parses the standing-
// authorization document. Parsed bytes are data, not authority: only
// MaintainerMergedAuthorizationResolver can combine them with protected-main provenance and
// mint a VerifiedAuthorizationGrant.

public enum RockchipStandingAuthorizationParseError: Error, Equatable, Sendable {
  case invalidJSON(String)
  case unsupportedSchemaVersion(String)
  case closedShapeViolation(String)
  case invalidAuthorizationID
  case emptyField(String)
  case invalidDigest(field: String)
  case invalidTimestamp(field: String)
  case invalidNonnegativeValue(field: String)
  case invalidPositiveValue(field: String)
}

/// The only accepted registry identifier syntax. It deliberately excludes filesystem syntax,
/// percent encoding, Unicode equivalence and case folding, so an ID can map to exactly one
/// `<id>.json` path beneath the fixed protected-main registry.
public enum RockchipStandingAuthorizationIdentifier {
  public static func isValid(_ value: String) -> Bool {
    guard (6...128).contains(value.utf8.count), value.hasPrefix("AUTH-"),
      value.first != "-", value.last != "-", !value.contains("--")
    else { return false }
    return value.utf8.allSatisfy {
      (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || $0 == UInt8(ascii: "-")
    }
  }
}

public struct RockchipStandingAuthorizationTarget: Codable, Equatable, Sendable {
  public let model: String
  /// SHA-256 digest of the exact device-serial bytes. Raw serial bytes never enter the
  /// repository or evidence.
  public let serialSHA256: String
  public let bindingRevision: Int
}

/// A decoded maintainer-authored carrier. `approvedBy` and `carrier` are display/cross-check
/// fields only; neither can establish approval without GitHub provenance.
public struct RockchipStandingAuthorization: Codable, Equatable, Sendable {
  public static let supportedSchemaVersion = "1.0.0"

  public let schemaVersion: String
  public let authorizationId: String
  public let approvedBy: String
  public let carrier: String
  public let target: RockchipStandingAuthorizationTarget
  public let firmwareArchiveSHA256: String
  public let transport: String
  public let toolchainFingerprint: String
  public let providerIdentity: String
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let recoveryPath: String
  public let validUntil: String
  public let maxRuns: Int

  public static func parse(_ data: Data) throws -> RockchipStandingAuthorization {
    var duplicateValidator = StandingAuthorizationDuplicateValidator(data: data)
    do {
      try duplicateValidator.validate()
    } catch {
      throw RockchipStandingAuthorizationParseError.invalidJSON(String(describing: error))
    }

    let root: JSONValue
    do {
      root = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw RockchipStandingAuthorizationParseError.invalidJSON(String(describing: error))
    }
    try validateClosedShape(root)

    let decoded: RockchipStandingAuthorization
    do {
      decoded = try JSONDecoder().decode(RockchipStandingAuthorization.self, from: data)
    } catch {
      throw RockchipStandingAuthorizationParseError.invalidJSON(String(describing: error))
    }
    guard decoded.schemaVersion == supportedSchemaVersion else {
      throw RockchipStandingAuthorizationParseError.unsupportedSchemaVersion(
        decoded.schemaVersion)
    }
    guard RockchipStandingAuthorizationIdentifier.isValid(decoded.authorizationId) else {
      throw RockchipStandingAuthorizationParseError.invalidAuthorizationID
    }
    for (field, value) in [
      ("approvedBy", decoded.approvedBy),
      ("carrier", decoded.carrier),
      ("target.model", decoded.target.model),
      ("transport", decoded.transport),
      ("toolchainFingerprint", decoded.toolchainFingerprint),
      ("providerIdentity", decoded.providerIdentity),
      ("recoveryPath", decoded.recoveryPath),
    ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw RockchipStandingAuthorizationParseError.emptyField(field)
    }
    guard decoded.maxRuns >= 0 else {
      throw RockchipStandingAuthorizationParseError.invalidNonnegativeValue(field: "maxRuns")
    }
    guard decoded.target.bindingRevision > 0 else {
      throw RockchipStandingAuthorizationParseError.invalidPositiveValue(
        field: "target.bindingRevision")
    }
    guard Self.isCanonicalTimestamp(decoded.validUntil) else {
      throw RockchipStandingAuthorizationParseError.invalidTimestamp(field: "validUntil")
    }
    for (field, value) in [
      ("target.serialSHA256", decoded.target.serialSHA256),
      ("firmwareArchiveSHA256", decoded.firmwareArchiveSHA256),
      ("planDigestSHA256", decoded.planDigestSHA256),
      ("stepSetDigestSHA256", decoded.stepSetDigestSHA256),
    ] {
      guard Self.isCanonicalSHA256(value) else {
        throw RockchipStandingAuthorizationParseError.invalidDigest(field: field)
      }
    }
    return decoded
  }

  static func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  static func isCanonicalTimestamp(_ value: String) -> Bool {
    value.range(
      of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z$"#,
      options: .regularExpression) == value.startIndex..<value.endIndex
      && parseTimestamp(value) != nil
  }

  static func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private static func validateClosedShape(_ root: JSONValue) throws {
    let rootKeys: Set<String> = [
      "schemaVersion", "authorizationId", "approvedBy", "carrier", "target",
      "firmwareArchiveSHA256", "transport", "toolchainFingerprint", "providerIdentity",
      "planDigestSHA256", "stepSetDigestSHA256", "recoveryPath", "validUntil", "maxRuns",
    ]
    let targetKeys: Set<String> = ["model", "serialSHA256", "bindingRevision"]
    guard case .object(let object) = root, Set(object.keys) == rootKeys,
      case .object(let target)? = object["target"], Set(target.keys) == targetKeys
    else {
      throw RockchipStandingAuthorizationParseError.closedShapeViolation(
        "authorization document contains unknown or missing members")
    }
  }
}

private enum StandingAuthorizationStrictJSONError: Error, CustomStringConvertible {
  case duplicateMember(String)
  case malformed(String)

  var description: String {
    switch self {
    case .duplicateMember(let path): "duplicate JSON member at \(path)"
    case .malformed(let reason): reason
    }
  }
}

/// Local duplicate-key validator because the storage target's equivalent parser is intentionally
/// not part of its public API. JSONDecoder alone accepts duplicate members and therefore cannot
/// protect an authorization carrier.
private struct StandingAuthorizationDuplicateValidator {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) { bytes = Array(data) }

  mutating func validate() throws {
    skipWhitespace()
    try parseValue(path: "$", depth: 0)
    skipWhitespace()
    guard index == bytes.count else {
      throw StandingAuthorizationStrictJSONError.malformed("unexpected trailing JSON data")
    }
  }

  private mutating func parseValue(path: String, depth: Int) throws {
    guard depth <= 256, let byte = currentByte else {
      throw StandingAuthorizationStrictJSONError.malformed("missing or over-nested JSON value")
    }
    switch byte {
    case UInt8(ascii: "{"): try parseObject(path: path, depth: depth)
    case UInt8(ascii: "["): try parseArray(path: path, depth: depth)
    case UInt8(ascii: "\""): _ = try parseString()
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try parseNumber()
    case UInt8(ascii: "t"): try parseLiteral(Array("true".utf8))
    case UInt8(ascii: "f"): try parseLiteral(Array("false".utf8))
    case UInt8(ascii: "n"): try parseLiteral(Array("null".utf8))
    default: throw StandingAuthorizationStrictJSONError.malformed("unexpected JSON byte")
    }
  }

  private mutating func parseObject(path: String, depth: Int) throws {
    try consume(UInt8(ascii: "{"))
    skipWhitespace()
    if consumeIfPresent(UInt8(ascii: "}")) { return }
    var names = Set<String>()
    while true {
      let name = try parseString()
      let memberPath = "\(path).\(name)"
      guard names.insert(name).inserted else {
        throw StandingAuthorizationStrictJSONError.duplicateMember(memberPath)
      }
      skipWhitespace()
      try consume(UInt8(ascii: ":"))
      skipWhitespace()
      try parseValue(path: memberPath, depth: depth + 1)
      skipWhitespace()
      if consumeIfPresent(UInt8(ascii: "}")) { return }
      try consume(UInt8(ascii: ","))
      skipWhitespace()
    }
  }

  private mutating func parseArray(path: String, depth: Int) throws {
    try consume(UInt8(ascii: "["))
    skipWhitespace()
    if consumeIfPresent(UInt8(ascii: "]")) { return }
    var element = 0
    while true {
      try parseValue(path: "\(path)[\(element)]", depth: depth + 1)
      element += 1
      skipWhitespace()
      if consumeIfPresent(UInt8(ascii: "]")) { return }
      try consume(UInt8(ascii: ","))
      skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    try consume(UInt8(ascii: "\""))
    while let byte = currentByte {
      switch byte {
      case UInt8(ascii: "\""):
        index += 1
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch
        { throw StandingAuthorizationStrictJSONError.malformed("invalid JSON string") }
      case UInt8(ascii: "\\"):
        index += 1
        guard let escaped = currentByte else {
          throw StandingAuthorizationStrictJSONError.malformed("unterminated JSON escape")
        }
        if escaped == UInt8(ascii: "u") {
          index += 1
          for _ in 0..<4 {
            guard let hex = currentByte, Self.isHexDigit(hex) else {
              throw StandingAuthorizationStrictJSONError.malformed("invalid Unicode escape")
            }
            index += 1
          }
        } else {
          let simple: Set<UInt8> = [
            UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
            UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
            UInt8(ascii: "r"), UInt8(ascii: "t"),
          ]
          guard simple.contains(escaped) else {
            throw StandingAuthorizationStrictJSONError.malformed("invalid JSON escape")
          }
          index += 1
        }
      case 0x00...0x1F:
        throw StandingAuthorizationStrictJSONError.malformed("JSON control character")
      default: index += 1
      }
    }
    throw StandingAuthorizationStrictJSONError.malformed("unterminated JSON string")
  }

  private mutating func parseLiteral(_ literal: [UInt8]) throws {
    let end = index + literal.count
    guard end <= bytes.count, bytes[index..<end].elementsEqual(literal) else {
      throw StandingAuthorizationStrictJSONError.malformed("invalid JSON literal")
    }
    index = end
  }

  private mutating func parseNumber() throws {
    if consumeIfPresent(UInt8(ascii: "-")), currentByte == nil {
      throw StandingAuthorizationStrictJSONError.malformed("invalid JSON number")
    }
    if consumeIfPresent(UInt8(ascii: "0")) {
      guard currentByte.map(Self.isDigit) != true else {
        throw StandingAuthorizationStrictJSONError.malformed("leading JSON number zero")
      }
    } else {
      guard let byte = currentByte, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(byte)
      else { throw StandingAuthorizationStrictJSONError.malformed("invalid JSON integer") }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
    if consumeIfPresent(UInt8(ascii: ".")) {
      guard currentByte.map(Self.isDigit) == true else {
        throw StandingAuthorizationStrictJSONError.malformed("invalid JSON fraction")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
    if currentByte == UInt8(ascii: "e") || currentByte == UInt8(ascii: "E") {
      index += 1
      if currentByte == UInt8(ascii: "+") || currentByte == UInt8(ascii: "-") { index += 1 }
      guard currentByte.map(Self.isDigit) == true else {
        throw StandingAuthorizationStrictJSONError.malformed("invalid JSON exponent")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
  }

  private mutating func consume(_ expected: UInt8) throws {
    guard consumeIfPresent(expected) else {
      throw StandingAuthorizationStrictJSONError.malformed("unexpected JSON token")
    }
  }

  private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
    guard currentByte == expected else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    while let byte = currentByte, whitespace.contains(byte) { index += 1 }
  }

  private var currentByte: UInt8? { index < bytes.count ? bytes[index] : nil }
  private static func isDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
  private static func isHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
      || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
  }
}
