import Foundation
import XCTest

@testable import ArkDeckCore

final class CanonicalJSONEncodersTests: XCTestCase {
  private struct Sample: Encodable {
    let zulu: String
    let alpha: String
    let path: String
  }

  func testCanonicalSortsKeysAndDoesNotEscapeSlashes() throws {
    let data = try CanonicalJSONEncoders.canonical().encode(
      Sample(zulu: "z", alpha: "a", path: "a/b/c"))
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self),
      #"{"alpha":"a","path":"a/b/c","zulu":"z"}"#)
  }

  func testCanonicalPrettyKeepsOrderAndSlashSpellingAndPrettyPrints() throws {
    let text = String(
      decoding: try CanonicalJSONEncoders.canonicalPretty().encode(
        Sample(zulu: "z", alpha: "a", path: "a/b/c")),
      as: UTF8.self)
    XCTAssertTrue(text.contains("\n"), "pretty output must be multi-line")
    XCTAssertTrue(text.contains(#""path" : "a\/b\/c""#) == false, "slashes must stay unescaped")
    XCTAssertTrue(text.contains(#"a/b/c"#))
    let alpha = try XCTUnwrap(text.range(of: #""alpha""#))
    let zulu = try XCTUnwrap(text.range(of: #""zulu""#))
    XCTAssertLessThan(alpha.lowerBound, zulu.lowerBound, "keys must be sorted")
  }

  func testEachCallReturnsAFreshInstance() {
    let first = CanonicalJSONEncoders.canonical()
    let second = CanonicalJSONEncoders.canonical()
    first.outputFormatting.insert(.prettyPrinted)
    XCTAssertFalse(second.outputFormatting.contains(.prettyPrinted))
  }
}

final class ISO8601TimestampsTests: XCTestCase {
  func testParsesPlainInternetDateTime() throws {
    let date = try XCTUnwrap(ISO8601Timestamps.parse("2026-08-11T12:00:00Z"))
    XCTAssertEqual(date.timeIntervalSince1970, 1_786_449_600, accuracy: 0.001)
  }

  func testParsesFractionalSeconds() throws {
    let date = try XCTUnwrap(ISO8601Timestamps.parse("2026-08-11T12:00:00.250Z"))
    XCTAssertEqual(date.timeIntervalSince1970, 1_786_449_600.25, accuracy: 0.001)
  }

  func testFractionalAndPlainAgreeOnTheIntegralInstant() throws {
    let plain = try XCTUnwrap(ISO8601Timestamps.parse("2026-08-11T12:00:00Z"))
    let fractional = try XCTUnwrap(ISO8601Timestamps.parse("2026-08-11T12:00:00.000Z"))
    XCTAssertEqual(plain, fractional)
  }

  func testRejectsNonTimestamps() {
    XCTAssertNil(ISO8601Timestamps.parse(""))
    XCTAssertNil(ISO8601Timestamps.parse("not-a-date"))
    XCTAssertNil(ISO8601Timestamps.parse("2026-08-11"))
    XCTAssertNil(ISO8601Timestamps.parse("2026-08-11T12:00:00"))
    XCTAssertNil(ISO8601Timestamps.parse("2026-13-40T99:99:99Z"))
  }
}
