import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// §8.2's canonical-JSON profile, including its published vector table.
///
/// The point of pinning RFC 8785 is that two implementations of this CLI, in
/// two languages, produce the same bytes for the same value. Every case here is
/// a place where a plausible shortcut produces different bytes.
final class CLICanonicalJSONContractTests: XCTestCase {

  private func canonical(_ value: JSONValue) throws -> String {
    try CLICanonicalJSON.canonicalString(value)
  }

  // MARK: The published vectors (§8.2)

  func testPropertiesAreSorted() throws {
    XCTAssertEqual(
      try canonical(.object(["b": .integer(1), "a": .integer(2)])), #"{"a":2,"b":1}"#)
  }

  /// `"a\/b"` and `"a/b"` are the same string, so only one of them can be
  /// canonical. RFC 8785 does not escape the solidus.
  func testTheSolidusIsNotEscaped() throws {
    XCTAssertEqual(try canonical(.object(["s": .string("a/b")])), #"{"s":"a/b"}"#)
  }

  /// Negative zero equals zero, so letting the sign through would give one
  /// value two canonical forms.
  func testNegativeZeroBecomesZero() throws {
    XCTAssertEqual(try canonical(.object(["n": .number(-0.0)])), #"{"n":0}"#)
    XCTAssertEqual(try canonical(.number(0.0)), "0")
  }

  func testANumberKeepsItsShortestRoundTripForm() throws {
    XCTAssertEqual(
      try canonical(.object(["n": .number(333_333_333.333_333_29)])),
      #"{"n":333333333.3333333}"#)
  }

  /// §11.3: a legal human string keeps its exact scalar sequence. Normalizing
  /// would merge two values a caller deliberately kept apart.
  ///
  /// The comparison has to be on bytes. Swift's `String` equality is canonical
  /// equivalence, so `"\u{00E9}" == "e\u{0301}"` is *true* in Swift — which
  /// means a test written with `XCTAssertNotEqual` on the rendered strings
  /// passes for the wrong reason and would keep passing if the encoder started
  /// normalizing. The bytes are what a digest is taken over, so the bytes are
  /// what this asserts.
  func testComposedAndDecomposedFormsStayDifferentBytes() throws {
    let composed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    XCTAssertEqual(composed, decomposed, "Swift compares these as equal; the bytes do not")
    XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))

    let left = try CLICanonicalJSON.canonicalBytes(.object(["s": .string(composed)]))
    let right = try CLICanonicalJSON.canonicalBytes(.object(["s": .string(decomposed)]))
    XCTAssertNotEqual(left, right, "canonicalization must not normalize")
    XCTAssertEqual(left.count + 1, right.count, "the decomposed form is one scalar longer")
    XCTAssertEqual(left, Data("{\"s\":\"\u{00E9}\"}".utf8))
  }

  /// `9007199254740992` is the first integer a binary64 cannot tell from its
  /// neighbour, so emitting it as a JSON number hands a JavaScript reader a
  /// value one away from the truth. §8.2 requires the schema to carry it as a
  /// decimal string instead.
  func testAnIntegerBeyondExactRangeIsRefusedRatherThanRounded() throws {
    XCTAssertThrowsError(try canonical(.object(["n": .integer(9_007_199_254_740_992)]))) {
      XCTAssertEqual(
        $0 as? CLICanonicalJSON.Failure,
        .integerBeyondExactRange("9007199254740992"))
    }
    XCTAssertThrowsError(try canonical(.object(["n": .integer(-9_007_199_254_740_992)])))
    // The last exactly representable integer is fine, and the string form of
    // the refused one is always fine.
    XCTAssertEqual(
      try canonical(.object(["n": .integer(9_007_199_254_740_991)])),
      #"{"n":9007199254740991}"#)
    XCTAssertEqual(
      try canonical(.object(["n": .string("9007199254740992")])),
      #"{"n":"9007199254740992"}"#)
  }

  func testNonFiniteNumbersHaveNoCanonicalForm() throws {
    for value in [Double.nan, .infinity, -.infinity] {
      XCTAssertThrowsError(try canonical(.object(["n": .number(value)]))) {
        XCTAssertEqual($0 as? CLICanonicalJSON.Failure, .nonFiniteNumber)
      }
    }
  }

  // MARK: Where `.sortedKeys` and JCS disagree

  /// Foundation orders keys by Unicode scalar; JCS orders them by UTF-16 code
  /// unit. A character above the basic plane is a surrogate pair starting at
  /// U+D800, which is *below* the U+E000…U+FFFF range that sorts after it by
  /// scalar — so the two orders differ, and a digest over "close enough" bytes
  /// is one two implementations disagree about.
  func testKeysAreOrderedByUtf16CodeUnitNotByScalar() throws {
    let astral = "\u{1F600}"  // surrogate pair D83D DE00
    let basic = "\u{FF00}"  // one code unit, above D83D
    let rendered = try canonical(.object([astral: .integer(1), basic: .integer(2)]))
    XCTAssertTrue(
      rendered.hasPrefix("{\"\(astral)\""),
      "JCS orders by UTF-16 code unit: \(rendered)")
    // Scalar order would have put U+FF00 first, which is what Foundation does.
    XCTAssertEqual(
      [astral, basic].sorted().first, basic, "the two orders really do differ")
  }

  func testControlCharactersUseTheShortEscapesAndThenHex() throws {
    XCTAssertEqual(try canonical(.string("\n\t\"\\")), #""\n\t\"\\""#)
    XCTAssertEqual(try canonical(.string("\u{08}\u{0C}\r")), #""\b\f\r""#)
    // Anything else below U+0020 has no short escape and becomes \u00xx.
    XCTAssertEqual(try canonical(.string("\u{01}")), #""\u0001""#)
    XCTAssertEqual(try canonical(.string("\u{1F}")), #""\u001f""#)
  }

  func testTheCanonicalFormHasNoWhitespaceOrTrailingNewline() throws {
    let rendered = try canonical(
      .object(["a": .array([.integer(1), .integer(2)]), "b": .object(["c": .bool(true)])]))
    XCTAssertEqual(rendered, #"{"a":[1,2],"b":{"c":true}}"#)
    XCTAssertFalse(rendered.hasSuffix("\n"), "a frame delimiter is not part of the value")
  }

  func testIntegralDoublesPrintWithoutAFraction() throws {
    XCTAssertEqual(try canonical(.number(1)), "1")
    XCTAssertEqual(try canonical(.number(-3)), "-3")
    XCTAssertEqual(try canonical(.number(1.5)), "1.5")
  }

  /// The canonical bytes must still be JSON. A canonicalizer that produced
  /// something only it could read would be a private format with a public name.
  func testTheCanonicalBytesParseBackToTheSameValue() throws {
    let value = JSONValue.object([
      "b": .array([.integer(1), .string("two"), .bool(false), .null]),
      "a": .object(["nested": .number(2.5)]),
      "é": .string("a/b"),
    ])
    let bytes = try CLICanonicalJSON.canonicalBytes(value)
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bytes), value)
  }
}

/// §5.3/§8.2's strict input decoding.
final class CLIStrictJSONContractTests: XCTestCase {

  private func decode(_ text: String) throws -> JSONValue {
    try CLIStrictJSON.decode(Data(text.utf8))
  }

  /// `JSONDecoder` keeps the last of a repeated key and says nothing, so which
  /// value survives depends on the decoder rather than on the document. I-JSON
  /// forbids it; so does this.
  func testARepeatedKeyIsRefusedRatherThanSilentlyResolved() {
    XCTAssertThrowsError(try decode(#"{"target":"a","target":"b"}"#)) {
      XCTAssertEqual($0 as? CLIStrictJSON.Failure, .duplicateKey("target"))
    }
    XCTAssertThrowsError(try decode(#"{"a":{"k":1,"k":2}}"#)) {
      XCTAssertEqual($0 as? CLIStrictJSON.Failure, .duplicateKey("k"))
    }
  }

  /// The same key in two *different* objects is not a duplicate, and neither is
  /// a value that merely looks like a key.
  func testDistinctObjectsAndStringValuesAreNotDuplicates() throws {
    XCTAssertNoThrow(try decode(#"{"a":{"k":1},"b":{"k":2}}"#))
    XCTAssertNoThrow(try decode(#"{"a":"k","k":1}"#))
    XCTAssertNoThrow(try decode(#"{"a":[{"k":1},{"k":2}]}"#))
    // A brace or a quote inside a string must not be read as structure.
    XCTAssertNoThrow(try decode(#"{"a":"}{\"k\":1,\"k\":2}"}"#))
  }

  func testAByteOrderMarkAndNonUtf8AreRefused() {
    var withMark = Data([0xEF, 0xBB, 0xBF])
    withMark.append(Data(#"{"a":1}"#.utf8))
    XCTAssertThrowsError(try CLIStrictJSON.decode(withMark)) {
      XCTAssertEqual($0 as? CLIStrictJSON.Failure, .byteOrderMark)
    }
    XCTAssertThrowsError(try CLIStrictJSON.decode(Data([0xFF, 0xFE, 0x00]))) {
      XCTAssertEqual($0 as? CLIStrictJSON.Failure, .notUTF8)
    }
  }

  func testMalformedInputIsRefused() {
    XCTAssertThrowsError(try decode("{")) {
      XCTAssertEqual($0 as? CLIStrictJSON.Failure, .malformed)
    }
  }

  func testAValidDocumentDecodes() throws {
    XCTAssertEqual(try decode(#"{"a":1}"#), .object(["a": .integer(1)]))
  }
}
