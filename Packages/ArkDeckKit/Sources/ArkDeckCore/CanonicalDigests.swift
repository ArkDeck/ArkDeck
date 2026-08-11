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

