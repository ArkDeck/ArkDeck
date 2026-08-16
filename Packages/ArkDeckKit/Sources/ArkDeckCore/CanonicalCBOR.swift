import Foundation

/// Deterministic CBOR (RFC 8949 §4.2.1), restricted to the shapes a
/// `StepPermit` signing body can contain.
///
/// This exists because a permit's integrity tag covers *bytes*, and the bytes
/// have to be the same ones ArkForge produces or the tag verifies against a
/// different permit than the one this authority meant to sign. The encoder is
/// therefore not a general CBOR library and should not become one: every shape
/// it cannot express is a shape a permit must not contain.
///
/// What is deliberately absent, matching ArkForge's `arkforge-core::digest::cbor`:
///
/// - **no floating point** — a digest model with floats has no single spelling
///   for a value (ArkForge `architecture.md` 15.4 forbids them outright);
/// - **no tags** (major type 6) and **no indefinite-length** containers — both
///   give one value more than one encoding, which is the property canonical
///   form exists to remove;
/// - **no negative integers** — nothing in a permit is negative, and an unused
///   branch is an untested branch.
///
/// The cross-validation vectors in
/// `openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md`
/// are what prove this agrees with the Rust side. If they ever disagree, the
/// difference is almost always map key ordering or a non-shortest integer.
package enum CanonicalCBOR {
  /// The value shapes a permit body may contain.
  package enum Value: Sendable, Equatable {
    case unsigned(UInt64)
    case bytes([UInt8])
    case text(String)
    case bool(Bool)
    /// Key order here is irrelevant: `encoded` sorts by the encoded key, so a
    /// caller cannot produce a non-canonical map by listing fields in a
    /// convenient order.
    case map([(String, Value)])

    package static func == (lhs: Value, rhs: Value) -> Bool {
      switch (lhs, rhs) {
      case let (.unsigned(left), .unsigned(right)): return left == right
      case let (.bytes(left), .bytes(right)): return left == right
      case let (.text(left), .text(right)): return left == right
      case let (.bool(left), .bool(right)): return left == right
      case let (.map(left), .map(right)):
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
      default: return false
      }
    }
  }

  /// Encodes a value in deterministic form.
  package static func encoded(_ value: Value) -> [UInt8] {
    var out: [UInt8] = []
    append(value, to: &out)
    return out
  }

  /// Convenience for the common case of hashing or MACing the result.
  package static func encodedData(_ value: Value) -> Data {
    Data(encoded(value))
  }

  private static func append(_ value: Value, to out: inout [UInt8]) {
    switch value {
    case .unsigned(let number):
      appendHead(major: 0, argument: number, to: &out)
    case .bytes(let payload):
      appendHead(major: 2, argument: UInt64(payload.count), to: &out)
      out.append(contentsOf: payload)
    case .text(let string):
      let utf8 = Array(string.utf8)
      appendHead(major: 3, argument: UInt64(utf8.count), to: &out)
      out.append(contentsOf: utf8)
    case .bool(let flag):
      // Major type 7, simple values 20 (false) and 21 (true). A bool encoded
      // as the integer 0 or 1 is the single most common way a second
      // implementation drifts from the first.
      out.append(flag ? 0xf5 : 0xf4)
    case .map(let entries):
      // RFC 8949 §4.2.1: sort by the *encoded* key, bytewise lexicographic.
      // Not by the Swift string ordering — "z" sorts before "aa" here,
      // because a shorter encoding sorts first.
      var encodedEntries: [([UInt8], [UInt8])] = entries.map { key, entryValue in
        var encodedKey: [UInt8] = []
        append(.text(key), to: &encodedKey)
        var encodedValue: [UInt8] = []
        append(entryValue, to: &encodedValue)
        return (encodedKey, encodedValue)
      }
      encodedEntries.sort { lexicographicallyPrecedes($0.0, $1.0) }
      appendHead(major: 5, argument: UInt64(encodedEntries.count), to: &out)
      for (key, entryValue) in encodedEntries {
        out.append(contentsOf: key)
        out.append(contentsOf: entryValue)
      }
    }
  }

  /// Shortest-form head: the argument goes in the five low bits when it fits,
  /// and otherwise in the smallest of the 1/2/4/8-byte follow-ons. Encoding
  /// `23` as `0x17` rather than `0x1817` is the rule; a longer form is still
  /// valid CBOR and still a different permit.
  private static func appendHead(major: UInt8, argument: UInt64, to out: inout [UInt8]) {
    let prefix = major << 5
    switch argument {
    case ..<24:
      out.append(prefix | UInt8(argument))
    case ..<0x100:
      out.append(prefix | 24)
      out.append(UInt8(argument))
    case ..<0x1_0000:
      out.append(prefix | 25)
      out.append(contentsOf: bigEndianBytes(UInt16(argument)))
    case ..<0x1_0000_0000:
      out.append(prefix | 26)
      out.append(contentsOf: bigEndianBytes(UInt32(argument)))
    default:
      out.append(prefix | 27)
      out.append(contentsOf: bigEndianBytes(argument))
    }
  }

  /// Big-endian bytes by arithmetic rather than by reinterpreting memory:
  /// ArkDeckCore builds under `strictMemorySafety`, and a raw-pointer view of
  /// an integer is exactly what that setting is there to keep out.
  private static func bigEndianBytes<Integer: FixedWidthInteger & UnsignedInteger>(
    _ value: Integer
  ) -> [UInt8] {
    let width = Integer.bitWidth / 8
    return (0..<width).map { index in
      UInt8(truncatingIfNeeded: value >> Integer((width - 1 - index) * 8))
    }
  }

  private static func lexicographicallyPrecedes(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    for (a, b) in zip(left, right) where a != b {
      return a < b
    }
    return left.count < right.count
  }
}
