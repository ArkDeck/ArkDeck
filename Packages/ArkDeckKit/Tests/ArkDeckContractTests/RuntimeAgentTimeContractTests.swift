import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// `RuntimeAgentTime` is the execution store's only clock representation, and
/// the coordinator refuses to create an execution when the current time does
/// not survive its own format/parse round trip. Formatting a raw `Date`
/// through the fractional ISO 8601 style truncated sub-millisecond bits while
/// a parsed millisecond value lands just below its boundary, so roughly half
/// of all timestamps failed the round trip and `agent run` answered
/// `orchestrationClockUntrusted`. These tests pin the millisecond-canonical
/// form and prove the round trip holds for every timestamp.
final class RuntimeAgentTimeContractTests: XCTestCase {
  func testEveryTimestampSurvivesTheRoundTrip() {
    var failures: [String] = []
    let base = 1_756_800_000.0
    for index in 0..<20_000 {
      let date = Date(timeIntervalSince1970: base + Double(index) * 0.000_137)
      let formatted = RuntimeAgentTime.format(date)
      guard let parsed = RuntimeAgentTime.parse(formatted) else {
        failures.append(formatted)
        continue
      }
      XCTAssertEqual(RuntimeAgentTime.format(parsed), formatted)
      XCTAssertLessThan(abs(parsed.timeIntervalSince1970 - date.timeIntervalSince1970), 0.000_501)
    }
    XCTAssertEqual(failures.count, 0, "round trip failed for \(failures.prefix(3))")
  }

  func testTheCanonicalFormIsMillisecondUTC() {
    XCTAssertEqual(
      RuntimeAgentTime.format(Date(timeIntervalSince1970: 1_756_800_000.001_999_9)),
      "2025-09-02T08:00:00.002Z")
    XCTAssertEqual(
      RuntimeAgentTime.format(Date(timeIntervalSince1970: 1_756_800_000)),
      "2025-09-02T08:00:00.000Z")
    XCTAssertEqual(
      RuntimeAgentTime.format(Date(timeIntervalSince1970: 1_756_800_000.999_6)),
      "2025-09-02T08:00:01.000Z")
  }

  func testOnlyTheCanonicalFormParses() {
    XCTAssertNotNil(RuntimeAgentTime.parse("2025-09-02T08:00:00.002Z"))
    XCTAssertNil(RuntimeAgentTime.parse("2025-09-02T08:00:00Z"), "seconds only is not canonical")
    XCTAssertNil(RuntimeAgentTime.parse("2025-09-02T08:00:00.2Z"), "one fractional digit is not canonical")
    XCTAssertNil(RuntimeAgentTime.parse("2025-09-02T08:00:00.002+00:00"), "offset spelling is not canonical")
    XCTAssertNil(RuntimeAgentTime.parse("2025-09-02 08:00:00.002Z"))
    XCTAssertNil(RuntimeAgentTime.parse(""))
  }

  func testStoredValuesWrittenByTheOldFormatterStillParse() {
    // Records on disk carry the same millisecond strings the old formatter
    // produced; the new reader must accept every one of them.
    for value in ["2026-08-19T13:50:27.651Z", "2026-08-28T03:21:37.000Z", "2026-09-01T23:59:59.999Z"] {
      let parsed = RuntimeAgentTime.parse(value)
      XCTAssertNotNil(parsed, value)
      XCTAssertEqual(parsed.map(RuntimeAgentTime.format), value)
    }
  }
}
