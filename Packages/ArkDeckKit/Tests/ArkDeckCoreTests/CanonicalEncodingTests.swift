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

  /// The parser shares locked formatter instances across every concurrent
  /// caller (journal, artifact, authorization services), so hammer it from
  /// parallel tasks and require every result to stay correct.
  func testConcurrentParsingStaysCorrectAcrossTasks() async {
    let expectations: [(String, TimeInterval?)] = [
      ("2026-08-11T12:00:00Z", 1_786_449_600),
      ("2026-08-11T12:00:00.250Z", 1_786_449_600.25),
      ("2026-08-11T04:00:00-08:00", 1_786_449_600),
      ("not-a-date", nil),
      ("2026-08-11T12:00:00", nil),
    ]
    let failures = await withTaskGroup(of: Int.self) { group in
      for task in 0..<8 {
        group.addTask {
          var mismatches = 0
          for iteration in 0..<2_000 {
            let (input, expected) = expectations[(task + iteration) % expectations.count]
            let parsed = ISO8601Timestamps.parse(input)
            switch (parsed, expected) {
            case (nil, nil):
              break
            case (let date?, let interval?)
            where abs(date.timeIntervalSince1970 - interval) < 0.001:
              break
            default:
              mismatches += 1
            }
          }
          return mismatches
        }
      }
      return await group.reduce(0, +)
    }
    XCTAssertEqual(failures, 0)
  }
}
