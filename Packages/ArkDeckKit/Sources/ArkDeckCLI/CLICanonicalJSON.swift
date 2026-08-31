import ArkDeckCore
import Foundation

/// `arkdeck.cli.canonical-json/1` — RFC 8785 JSON Canonicalization Scheme.
///
/// §8.2 pins this so that two implementations of the CLI, in two languages,
/// produce the same bytes for the same value. Foundation's `.sortedKeys` is
/// close enough to read but is not the scheme: it orders keys by Unicode
/// scalar, and JCS orders them by UTF-16 code unit. The two disagree for any
/// key containing a character above the basic plane, because such a character's
/// surrogate pair begins at U+D800 — *below* the U+E000…U+FFFF range that sorts
/// after it by scalar. A digest computed over "close enough" bytes is a digest
/// two implementations will disagree about exactly when the input gets
/// interesting.
///
/// Scope, from §8.2: only a field whose schema declares `sha256-jcs` is hashed
/// over these bytes. Catalog digests, materialized plan hashes, artifact
/// digests and capability/facts digests keep their own accepted
/// canonicalization and travel through the CLI as opaque values — recomputing
/// one here would invent a second identity for something that already has one.
enum CLICanonicalJSON {
  static let version = "arkdeck.cli.canonical-json/1"

  enum Failure: Error, Equatable {
    /// JCS has no representation for these, and I-JSON does not admit them.
    case nonFiniteNumber
    /// An integer outside the range a binary64 can carry exactly. §8.2 requires
    /// such a field to be a canonical decimal *string* rather than a number, so
    /// that it survives a JavaScript reader.
    case integerBeyondExactRange(String)
    /// A lone surrogate cannot be encoded as UTF-8 and is not valid I-JSON.
    case unpairedSurrogate
  }

  /// The canonical UTF-8 bytes. No BOM, no insignificant whitespace, and no
  /// trailing newline — a frame delimiter is the caller's business and is not
  /// part of the canonical form or of any digest over it.
  static func canonicalBytes(_ value: JSONValue) throws -> Data {
    var output = String()
    try append(value, to: &output)
    return Data(output.utf8)
  }

  static func canonicalString(_ value: JSONValue) throws -> String {
    String(decoding: try canonicalBytes(value), as: UTF8.self)
  }

  // MARK: Serialization

  private static func append(_ value: JSONValue, to output: inout String) throws {
    switch value {
    case .null:
      output += "null"
    case .bool(let flag):
      output += flag ? "true" : "false"
    case .integer(let number):
      try appendExactInteger(String(number), magnitude: UInt64(number.magnitude), to: &output)
    case .unsignedInteger(let number):
      try appendExactInteger(String(number), magnitude: number, to: &output)
    case .number(let number):
      output += try serialize(number)
    case .string(let text):
      try appendString(text, to: &output)
    case .array(let items):
      output += "["
      for (offset, item) in items.enumerated() {
        if offset > 0 { output += "," }
        try append(item, to: &output)
      }
      output += "]"
    case .object(let fields):
      output += "{"
      for (offset, key) in try sortedKeys(of: fields).enumerated() {
        if offset > 0 { output += "," }
        try appendString(key, to: &output)
        output += ":"
        try append(fields[key] ?? .null, to: &output)
      }
      output += "}"
    }
  }

  /// §8.2's exact-integer rule. `9007199254740992` is the first integer a
  /// binary64 cannot distinguish from its neighbour, so emitting it as a JSON
  /// number would hand a JavaScript reader a value one away from the truth.
  /// Refusing is the honest answer; the schema is expected to declare the field
  /// a canonical decimal string instead.
  private static let exactIntegerLimit: UInt64 = 9_007_199_254_740_991

  private static func appendExactInteger(
    _ rendered: String, magnitude: UInt64, to output: inout String
  ) throws {
    guard magnitude <= exactIntegerLimit else {
      throw Failure.integerBeyondExactRange(rendered)
    }
    output += rendered
  }

  /// ECMAScript `Number::toString`, which is what JCS specifies for numbers.
  static func serialize(_ number: Double) throws -> String {
    guard number.isFinite else { throw Failure.nonFiniteNumber }
    // JCS canonicalizes negative zero to `0`: the two are numerically equal, so
    // letting the sign through would give one value two canonical forms.
    if number == 0 { return "0" }
    // An integral double prints without a fraction in ECMAScript — `1`, not
    // `1.0` — and Swift's description does the opposite.
    if number.rounded() == number, abs(number) < 1e21,
      let exact = Int64(exactly: number.rounded())
    {
      guard exact.magnitude <= exactIntegerLimit else {
        throw Failure.integerBeyondExactRange(String(exact))
      }
      return String(exact)
    }
    // Swift's `description` is the shortest representation that round-trips,
    // which is the same choice ECMAScript makes.
    var rendered = "\(number)"
    // Swift writes `1e-07`; ECMAScript writes `1e-7`.
    if let exponent = rendered.firstIndex(where: { $0 == "e" }) {
      let mantissa = rendered[..<exponent]
      var suffix = rendered[rendered.index(after: exponent)...]
      var sign = ""
      if suffix.first == "+" || suffix.first == "-" {
        sign = String(suffix.removeFirst())
      }
      while suffix.count > 1, suffix.first == "0" { suffix.removeFirst() }
      rendered = "\(mantissa)e\(sign)\(suffix)"
    }
    return rendered
  }

  /// JCS orders object keys by their UTF-16 code units, not by Unicode scalar.
  private static func sortedKeys(of fields: [String: JSONValue]) throws -> [String] {
    for key in fields.keys where containsUnpairedSurrogate(key) {
      throw Failure.unpairedSurrogate
    }
    return fields.keys.sorted { left, right in
      var leftUnits = Array(left.utf16)
      var rightUnits = Array(right.utf16)
      let shared = min(leftUnits.count, rightUnits.count)
      for index in 0..<shared where leftUnits[index] != rightUnits[index] {
        return leftUnits[index] < rightUnits[index]
      }
      leftUnits.removeAll()
      rightUnits.removeAll()
      return left.utf16.count < right.utf16.count
    }
  }

  /// A Swift `String` cannot hold an unpaired surrogate, so this can only be
  /// true for a value that arrived through a lossy conversion. Checking is
  /// cheap and makes the refusal explicit rather than implicit in the encoder.
  private static func containsUnpairedSurrogate(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) }
  }

  /// RFC 8785 §3.2.2.2: escape only what JSON requires. In particular the
  /// solidus is *not* escaped — `"a\/b"` and `"a/b"` are the same string, and
  /// only one of them can be canonical. Every other scalar is emitted as
  /// itself, with no Unicode normalization: §11.3 keeps a legal human string as
  /// its exact scalar sequence, so a composed and a decomposed `é` stay two
  /// different values rather than being quietly merged.
  private static func appendString(_ text: String, to output: inout String) throws {
    guard !containsUnpairedSurrogate(text) else { throw Failure.unpairedSurrogate }
    output += "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      default:
        if scalar.value < 0x20 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
  }
}

/// Strict decoding of a caller-supplied JSON document (§5.3, §8.2).
///
/// `JSONDecoder` keeps the last of a repeated key and says nothing, so a
/// document with `{"target":"a","target":"b"}` silently loses one of them —
/// and which one is lost depends on the decoder, not on the document. I-JSON
/// forbids it, so this refuses it.
enum CLIStrictJSON {
  enum Failure: Error, Equatable {
    case byteOrderMark
    case notUTF8
    case malformed
    case duplicateKey(String)
  }

  static func decode(_ data: Data) throws -> JSONValue {
    guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw Failure.byteOrderMark }
    guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
    if let duplicate = firstDuplicateKey(in: text) { throw Failure.duplicateKey(duplicate) }
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw Failure.malformed
    }
    return decoded
  }

  /// Scans for a key repeated within one object.
  ///
  /// Done on the text because the decoded value cannot show it: by the time a
  /// dictionary exists, the duplicate is already gone. The scan tracks string
  /// and escape state so a brace or a quote inside a string cannot be mistaken
  /// for structure.
  static func firstDuplicateKey(in text: String) -> String? {
    var stack: [Set<String>] = []
    var pendingKey: String?
    var current = ""
    var inString = false
    var escaped = false
    var expectingKey = false

    for character in text {
      if inString {
        if escaped {
          current.append(character)
          escaped = false
        } else if character == "\\" {
          current.append(character)
          escaped = true
        } else if character == "\"" {
          inString = false
          if expectingKey { pendingKey = unescaped(current) }
        } else {
          current.append(character)
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
        current = ""
      case "{":
        stack.append([])
        expectingKey = true
      case "}":
        if !stack.isEmpty { stack.removeLast() }
        expectingKey = !stack.isEmpty
      case "[":
        expectingKey = false
      case "]":
        expectingKey = !stack.isEmpty
      case ":":
        if let key = pendingKey, !stack.isEmpty {
          if stack[stack.count - 1].contains(key) { return key }
          stack[stack.count - 1].insert(key)
          pendingKey = nil
        }
        expectingKey = false
      case ",":
        expectingKey = !stack.isEmpty
      default:
        break
      }
    }
    return nil
  }

  /// Only the escapes that can appear inside a key matter here: two keys are
  /// the same key whether or not one spelled a character with `\u`.
  private static func unescaped(_ raw: String) -> String {
    guard raw.contains("\\"),
      let data = "\"\(raw)\"".data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data)
    else { return raw }
    return decoded
  }
}
