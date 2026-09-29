import Foundation
import Testing

@testable import ArkDeckCore

struct CanonicalJSONEncodersTests {
  private struct Sample: Encodable {
    let zulu: String
    let alpha: String
    let path: String
  }

  @Test func canonicalSortsKeysAndDoesNotEscapeSlashes() throws {
    let data = try CanonicalJSONEncoders.canonical().encode(
      Sample(zulu: "z", alpha: "a", path: "a/b/c"))
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"{"alpha":"a","path":"a/b/c","zulu":"z"}"#)
  }

  @Test func canonicalPrettyKeepsOrderAndSlashSpellingAndPrettyPrints() throws {
    let text = String(
      decoding: try CanonicalJSONEncoders.canonicalPretty().encode(
        Sample(zulu: "z", alpha: "a", path: "a/b/c")),
      as: UTF8.self)
    #expect(text.contains("\n"), "pretty output must be multi-line")
    #expect(text.contains(#""path" : "a\/b\/c""#) == false, "slashes must stay unescaped")
    #expect(text.contains(#"a/b/c"#))
    let alpha = try #require(text.range(of: #""alpha""#))
    let zulu = try #require(text.range(of: #""zulu""#))
    #expect(alpha.lowerBound < zulu.lowerBound, "keys must be sorted")
  }

  @Test func eachCallReturnsAFreshInstance() {
    let first = CanonicalJSONEncoders.canonical()
    let second = CanonicalJSONEncoders.canonical()
    first.outputFormatting.insert(.prettyPrinted)
    #expect(!second.outputFormatting.contains(.prettyPrinted))
  }
}

struct ISO8601TimestampsTests {
  @Test func parsesPlainInternetDateTime() throws {
    let date = try #require(ISO8601Timestamps.parse("2026-08-11T12:00:00Z"))
    #expect(abs(date.timeIntervalSince1970 - 1_786_449_600) <= 0.001)
  }

  @Test func parsesFractionalSeconds() throws {
    let date = try #require(ISO8601Timestamps.parse("2026-08-11T12:00:00.250Z"))
    #expect(abs(date.timeIntervalSince1970 - 1_786_449_600.25) <= 0.001)
  }

  @Test func fractionalAndPlainAgreeOnTheIntegralInstant() throws {
    let plain = try #require(ISO8601Timestamps.parse("2026-08-11T12:00:00Z"))
    let fractional = try #require(ISO8601Timestamps.parse("2026-08-11T12:00:00.000Z"))
    #expect(plain == fractional)
  }

  @Test func rejectsNonTimestamps() {
    #expect(ISO8601Timestamps.parse("") == nil)
    #expect(ISO8601Timestamps.parse("not-a-date") == nil)
    #expect(ISO8601Timestamps.parse("2026-08-11") == nil)
    #expect(ISO8601Timestamps.parse("2026-08-11T12:00:00") == nil)
    #expect(ISO8601Timestamps.parse("2026-13-40T99:99:99Z") == nil)
  }

  @Test func formatsCanonicalPlainAndFractionalSpellings() {
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(ISO8601Timestamps.string(from: epoch) == "1970-01-01T00:00:00Z")
    #expect(
      ISO8601Timestamps.string(from: epoch, includingFractionalSeconds: true)
        == "1970-01-01T00:00:00.000Z")
  }

  @Test func canonicalPlainParserRejectsAlternateEquivalentSpellings() {
    #expect(ISO8601Timestamps.parseCanonicalPlain("1970-01-01T00:00:00Z") != nil)
    #expect(ISO8601Timestamps.parseCanonicalPlain("1970-01-01T00:00:00.000Z") == nil)
    #expect(ISO8601Timestamps.parseCanonicalPlain("1969-12-31T16:00:00-08:00") == nil)
  }

  /// The shared format styles are immutable Sendable values, so hammer them
  /// from parallel callers and require every result to stay correct.
  @Test func concurrentParsingStaysCorrectAcrossTasks() async {
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
    #expect(failures == 0)
  }
}
