// Test-only compatibility for two Swift 6.4 DecodingError renderings.
// CHG-2026-074 design G.1 r11: message/debug rendering is T2. Everything
// outside the two known error-message spellings remains byte-exact.
import CryptoKit
import Foundation

@testable import ArkDeckCore

enum OracleSDKDiagnosticCompatibility {
  enum Family {
    case artifactQuota, capabilityRead, jobPlanAnalyzer

    var newline: Bool { self == .jobPlanAnalyzer }
  }

  enum Failure: Error {
    case unexpectedEncoding(String)
    case invalidProvenance
  }

  static func comparableFiles(_ raw: [String: Data], family: Family) throws -> [String: Data] {
    guard let cases = raw["cases.json"] else { throw Failure.unexpectedEncoding("cases.json") }
    let decoded = try decodeExact(cases, path: "cases.json", newline: family.newline)
    var result = raw
    result["cases.json"] = try encode(normalizeCases(decoded, family: family), newline: family.newline)
    if family == .jobPlanAnalyzer {
      guard let provenance = raw["provenance.json"],
        case .object(var fields) = try decodeExact(provenance, path: "provenance.json", newline: true),
        case .object(var hashes)? = fields["files"], hashes["cases.json"] != nil
      else { throw Failure.invalidProvenance }
      // Validate each original digest against that side's original bytes
      // before deriving the comparison-only digest. A corrupt provenance is
      // never repaired by normalization.
      for (path, value) in hashes {
        guard let bytes = raw[path], value == .string(sha256(bytes)) else {
          throw Failure.invalidProvenance
        }
      }
      hashes["cases.json"] = .string(sha256(result["cases.json"]!))
      fields["files"] = .object(hashes)
      result["provenance.json"] = try encode(.object(fields), newline: true)
    }
    return result
  }

  private static func decodeExact(_ data: Data, path: String, newline: Bool) throws -> JSONValue {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    // Parsing must not silently discard whitespace, key order, duplicate
    // keys, number spellings, or the file's required trailing newline.
    guard try encode(value, newline: newline) == data else {
      throw Failure.unexpectedEncoding(path)
    }
    return value
  }

  private static func encode(_ value: JSONValue, newline: Bool) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    return try encoder.encode(value) + (newline ? Data("\n".utf8) : Data())
  }

  private static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func normalizeCases(_ value: JSONValue, family: Family) -> JSONValue {
    guard case .array(let rows) = value else { return value }
    return .array(rows.map { row in
      guard case .object(var fields) = row else { return row }
      if family == .capabilityRead, case .array(let exchanges)? = fields["exchanges"] {
        fields["exchanges"] = .array(exchanges.map(normalizeResponse))
        return .object(fields)
      }
      return normalizeResponse(row)
    })
  }

  private static func normalizeResponse(_ value: JSONValue) -> JSONValue {
    guard case .object(var row) = value,
      case .object(var response)? = row["response"],
      case .object(var error)? = response["error"],
      case .string(let message)? = error["message"]
    else { return value }
    error["message"] = .string(normalizeMessage(message))
    response["error"] = .object(error)
    row["response"] = .object(response)
    return .object(row)
  }

  private static func normalizeMessage(_ message: String) -> String {
    // Limit compatibility to the two SDK fragments actually observed in
    // these three corpora, including their published expected type names.
    let types = ["Int", "String", "ArtifactStatus", "Dictionary<String, Any>", "Array<Any>"]
    var text = message
    for type in types {
      text = text.replacingOccurrences(
        of: "DecodingError.typeMismatch: Expected value of type \(type).",
        with: "DecodingError.typeMismatch: expected value of type \(type).")
      if text.contains("found null value instead") {
        for separator in [" Path:", " Debug description:"] {
          text = text.replacingOccurrences(
            of: "DecodingError.valueNotFound: Expected value of type \(type).\(separator)",
            with: "DecodingError.valueNotFound: Expected value of type \(type) but found null instead.\(separator)")
        }
      }
    }
    return text
  }
}
