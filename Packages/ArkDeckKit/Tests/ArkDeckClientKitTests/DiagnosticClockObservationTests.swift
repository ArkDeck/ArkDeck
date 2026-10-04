import ArkDeckCore
import Foundation
import Testing
@testable import ArkDeckClientKit

struct DiagnosticClockObservationTests {
  private func sample() -> [String: JSONValue] {
    ["schemaVersion": .string("arkdeck.trace-clock-observation/1"), "jobId": .string("job-clock"),
     "anchor": .string("anchor-fixture"), "startedAtHostUTC": .string("2026-10-04T00:00:00.000Z"),
     "finishedAtHostUTC": .string("2026-10-04T00:00:00.010Z"), "elapsedNanoseconds": .integer(10_000_000),
     "status": .string("unvalidated")]
  }
  private func decode(_ fields: [String: JSONValue], job: String = "job-clock", anchor: String? = "anchor-fixture") throws -> DiagnosticClockObservation {
    try DiagnosticClockObservation.decode(JSONEncoder().encode(fields), jobID: job, anchor: anchor)
  }
  @Test func observationRetainsItsWidthWithoutClaimingCalibration() throws {
    let value = try decode(sample())
    #expect(value.status == .unvalidated)
    #expect(value.windowMilliseconds == 10)
    for fraction in ["000", "001", "123", "999"] {
      var instant = sample()
      instant["startedAtHostUTC"] = .string("2026-10-04T00:00:00.\(fraction)Z")
      instant["finishedAtHostUTC"] = instant["startedAtHostUTC"]
      instant["elapsedNanoseconds"] = .integer(0)
      #expect(try decode(instant).status == .unvalidated)
    }
    var boundary = sample()
    boundary["elapsedNanoseconds"] = .integer(12_000_000)
    #expect(try decode(boundary).status == .unvalidated)
    boundary["elapsedNanoseconds"] = .integer(12_000_001)
    boundary["status"] = .string("hostClockDiscontinuity")
    #expect(try decode(boundary).status == .hostClockDiscontinuity)
    var jumped = sample()
    jumped["finishedAtHostUTC"] = .string("2026-10-03T23:59:59.999Z")
    jumped["status"] = .string("hostClockDiscontinuity")
    #expect(try decode(jumped).status == .hostClockDiscontinuity)
  }
  @Test func malformedObservationCannotInventPrecisionOrChangeIdentity() throws {
    let invalid = DiagnosticSessionOfflineInspectorError.invalid("diagnostics_invalid_clock_observation")
    #expect(throws: invalid) { try decode(sample(), job: "other") }
    for anchor: String? in [nil, "", "other"] {
      #expect(throws: invalid) { try decode(sample(), anchor: anchor) }
    }
    let changes: [(String, JSONValue)] = [
      ("status", .string("calibrated")), ("elapsedNanoseconds", .bool(true)),
      ("elapsedNanoseconds", .integer(-1)), ("elapsedNanoseconds", .integer(120_000_000_001)),
      ("finishedAtHostUTC", .string("2026-10-03T23:59:59.999Z")),
      ("finishedAtHostUTC", .string("2026-10-04T00:00:01.000Z")), ("unknown", .integer(1)),
      ("startedAtHostUTC", .string("2026-02-30T00:00:00.000Z")),
      ("startedAtHostUTC", .string("2026-10-04T25:00:00.000Z"))]
    for (key, value) in changes {
      var changed = sample(); changed[key] = value
      #expect(throws: invalid) { try decode(changed) }
    }
  }
}
