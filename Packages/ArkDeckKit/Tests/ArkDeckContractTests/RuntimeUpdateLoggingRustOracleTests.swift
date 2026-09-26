import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class RuntimeUpdateLoggingRustOracleTests: XCTestCase {
  private struct Clock: DiagnosticAuditClock {
    let nowUTC: Date
  }
  private struct SilentUnified: UnifiedDiagnosticLogging {
    func log(_: RedactedDiagnosticRecord) {}
  }

  func testActualSwiftUpdateLoggingAndRotationForRust() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-update-log-oracle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = "2026-09-26T00:00:00.123Z"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let clock = Clock(nowUTC: try XCTUnwrap(formatter.date(from: now)))
    let store = try StructuredDiagnosticLogStore(
      directory: directory,
      configuration: StructuredDiagnosticLogConfiguration(
        quotaBytes: 1024, segmentBytes: 400, maximumRecordBytes: 400))
    let logger = SystemAutoUpdateEventLogger(logger: SystemLogger(
      structuredStore: store, unifiedLogger: SilentUnified(), auditClock: clock))
    let events: [AutoUpdateLogEvent] = [
      .checkStarted, .available, .noUpdate, .downloadStarted,
      .verificationStarted, .failed, .cancelled, .handedOff,
    ]
    var cases: [JSONValue] = []
    for event in events {
      logger.record(event)
      let snapshot = try store.snapshot()
      let files: [JSONValue] = try snapshot.files.map { file in
        let records: [JSONValue] = try file.data.split(separator: 0x0a).map { line in
          let value = try JSONDecoder().decode(JSONValue.self, from: Data(line))
          guard case .object(var fields) = value else { throw CocoaError(.fileReadCorruptFile) }
          if case .string(let correlation) = fields["correlationId"] {
            XCTAssertTrue(correlation.hasPrefix("corr-"))
            XCTAssertEqual(correlation.count, 37)
          } else { XCTFail("missing correlation") }
          fields["correlationId"] = .string("<correlation>")
          return .object(fields)
        }
        return .object(["name": .string(file.name), "records": .array(records)])
      }
      cases.append(.object([
        "event": .string(String(describing: event)), "files": .array(files),
        "totalBytes": .integer(Int64(snapshot.totalBytes)),
      ]))
    }
    let base = floor(clock.nowUTC.timeIntervalSince1970)
    let timestampCases: [JSONValue] = [0.0, 0.001, 0.123, 0.5, 0.999, 1.0].map { fraction in
      let value = base + fraction
      return .object([
        "unixSeconds": .string(String(value)),
        "timestamp": .string(ISO8601Timestamps.string(
          from: Date(timeIntervalSince1970: value), includingFractionalSeconds: true)),
      ])
    }
    let output = try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object([
      "producer": .string("RuntimeUpdateLoggingRustOracleTests"), "now": .string(now),
      "unixSeconds": .string(String(clock.nowUTC.timeIntervalSince1970)),
      "timestampCases": .array(timestampCases),
      "cases": .array(cases),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if ProcessInfo.processInfo.environment["ARKDECK_RUST_UPDATE_LOGGING_RECORD"] != nil {
      try HDCOracleHarness.recordOrCompare(
        ["logging.json": output], variable: "ARKDECK_RUST_UPDATE_LOGGING_RECORD",
        oracle: repository.appending(path: "rust/tests/fixtures/runtime-update"))
    } else {
      XCTAssertEqual(output, try Data(contentsOf:
        repository.appending(path: "rust/tests/fixtures/runtime-update/logging.json")))
    }
  }
}
