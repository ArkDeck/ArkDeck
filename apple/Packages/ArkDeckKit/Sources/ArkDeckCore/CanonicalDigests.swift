import CryptoKit
import Foundation

/// The single spelling for the lowercase-hex SHA-256 strings used as identity
/// material across the package. Every module already depends on ArkDeckCore,
/// so digest formatting must not be re-derived per call site: a second
/// spelling is how two components silently disagree about the same identity.
package enum SHA256Hex {
  private static let lowercaseDigits = Array("0123456789abcdef".utf8)

  package static func string(of data: Data) -> String {
    hexString(SHA256.hash(data: data))
  }

  package static func hexString(_ digest: SHA256.Digest) -> String {
    lowercaseHex(digest)
  }

  /// Encodes arbitrary bytes without routing through C varargs. Keeping the
  /// spelling here lets native-boundary callers share the same memory-safe
  /// lowercase representation as SHA-256 identities.
  package static func lowercaseHex<Bytes: Sequence>(_ bytes: Bytes) -> String
  where Bytes.Element == UInt8 {
    var encoded: [UInt8] = []
    encoded.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
      encoded.append(lowercaseDigits[Int(byte >> 4)])
      encoded.append(lowercaseDigits[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  /// True exactly for 64 lowercase hexadecimal characters — the closed wire
  /// shape shared by artifact, archive, capability and binding digests.
  package static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }
}

/// Factories for the two canonical `JSONEncoder` configurations used for
/// digest input and durable documents. Sites that hash encoder output must
/// take the encoder from here so the byte form (and therefore the digest)
/// cannot drift between call sites. Callers may add further configuration
/// (date strategies etc.) on the returned instance.
package enum CanonicalJSONEncoders {
  /// `[.sortedKeys, .withoutEscapingSlashes]` — the package-wide canonical form.
  package static func canonical() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  /// The canonical form plus `.prettyPrinted`, for human-facing durable
  /// documents whose digests are computed over the pretty bytes.
  package static func canonicalPretty() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return encoder
  }
}

/// Fallback parsing for the two ISO-8601 spellings ArkDeck reads back
/// (with and without fractional seconds). The accepted set is identical
/// regardless of probe order and unchanged from the per-call-formatter
/// spelling this replaced.
package enum ISO8601Timestamps {
  private static let plain = Date.ISO8601FormatStyle()
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  package static func parse(_ value: String) -> Date? {
    (try? fractional.parse(value)) ?? (try? plain.parse(value))
  }

  package static func parseCanonicalPlain(_ value: String) -> Date? {
    guard let date = try? plain.parse(value), plain.format(date) == value else { return nil }
    return date
  }

  package static func string(
    from date: Date,
    includingFractionalSeconds: Bool = false
  ) -> String {
    if includingFractionalSeconds {
      return fractional.format(date)
    }
    return plain.format(date)
  }
}
