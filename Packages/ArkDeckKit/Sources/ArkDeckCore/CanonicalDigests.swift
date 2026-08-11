import CryptoKit
import Foundation

/// The single spelling for the lowercase-hex SHA-256 strings used as identity
/// material across the package. Every module already depends on ArkDeckCore,
/// so digest formatting must not be re-derived per call site: a second
/// spelling is how two components silently disagree about the same identity.
package enum SHA256Hex {
  package static func string(of data: Data) -> String {
    hexString(SHA256.hash(data: data))
  }

  package static func hexString(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
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
/// regardless of probe order; a fresh formatter per call matches the
/// pre-consolidation behaviour and keeps the API thread-safe.
package enum ISO8601Timestamps {
  package static func parse(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }
}
