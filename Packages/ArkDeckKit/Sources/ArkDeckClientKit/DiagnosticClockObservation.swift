import ArkDeckCore
import Foundation

/// A host interval around the Runtime's trace-anchor write. Its width is not
/// a cross-clock tolerance, and it never changes the session's alignment state.
public struct DiagnosticClockObservation: Equatable, Sendable {
  public enum Status: String, Sendable { case unvalidated, hostClockDiscontinuity }
  public let startedAtHostUTC: String
  public let finishedAtHostUTC: String
  public let elapsedNanoseconds: Int64
  public let status: Status
  public var windowMilliseconds: Int { Int((elapsedNanoseconds + 999_999) / 1_000_000) }

  package static func decode(_ data: Data, jobID: String, anchor: String?) throws -> Self {
    func invalid() -> DiagnosticSessionOfflineInspectorError {
      .invalid("diagnostics_invalid_clock_observation")
    }
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data),
      Set(fields.keys) == ["schemaVersion", "jobId", "anchor", "startedAtHostUTC", "finishedAtHostUTC", "elapsedNanoseconds", "status"],
      fields["schemaVersion"] == .string("arkdeck.trace-clock-observation/1"),
      fields["jobId"] == .string(jobID), let anchor, !anchor.isEmpty,
      fields["anchor"] == .string(anchor),
      case .string(let start)? = fields["startedAtHostUTC"], start.utf8.count == 24, start.hasSuffix("Z"),
      case .string(let end)? = fields["finishedAtHostUTC"], end.utf8.count == 24, end.hasSuffix("Z"),
      let before = Self.milliseconds(start), let after = Self.milliseconds(end),
      case .integer(let nanos)? = fields["elapsedNanoseconds"], (0...120_000_000_000).contains(nanos),
      case .string(let raw)? = fields["status"], let status = Status(rawValue: raw)
    else { throw invalid() }
    let wallNanos = (after - before) * 1_000_000
    let consistent = wallNanos >= 0 && abs(wallNanos - Double(nanos)) <= 2_000_000
    guard status == (consistent ? .unvalidated : .hostClockDiscontinuity) else { throw invalid() }
    return Self(startedAtHostUTC: start, finishedAtHostUTC: end, elapsedNanoseconds: nanos, status: status)
  }

  private static func milliseconds(_ value: String) -> Double? {
    let bytes = Array(value.utf8)
    let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 46, 23: 90]
    guard bytes.count == 24, !value.hasPrefix("0000"),
      bytes.enumerated().allSatisfy({ index, byte in
        separators[index].map { $0 == byte } ?? (48...57).contains(byte)
      }),
      let date = ISO8601Timestamps.parseCanonicalPlain(String(value.prefix(19)) + "Z")
    else { return nil }
    // Parse the exact whole second first. Formatting fractional Date values
    // can truncate a millisecond because of binary floating-point rounding.
    let fraction = Int(bytes[20] - 48) * 100 + Int(bytes[21] - 48) * 10 + Int(bytes[22] - 48)
    return date.timeIntervalSince1970 * 1_000 + Double(fraction)
  }

}
