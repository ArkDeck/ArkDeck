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
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    do {
      try duplicateValidator.validate()
    } catch let error as StrictJSONError {
      switch error {
      case .duplicateMemberName(let path):
        throw RockchipStandingAuthorizationParseError.invalidJSON(
          "duplicate JSON member at \(path)")
      case .malformed(let reason):
        throw RockchipStandingAuthorizationParseError.invalidJSON(reason)
      }
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
