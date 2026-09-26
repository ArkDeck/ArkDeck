import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class RuntimeUpdateReplayRustOracleTests: XCTestCase {
  func testActualSwiftReplayWatermarkForRust() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-replay-oracle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileUpdateReplayStore(directory: directory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let a = String(repeating: "a", count: 64)
    let b = String(repeating: "b", count: 64)
    let inputs: [(String, UInt64, String, String)] = [
      ("first", 1, "1.0.0", a), ("identical", 1, "1.0.0", a),
      ("sameSequenceDifferentDigest", 1, "1.0.0", b),
      ("sameSequenceDifferentVersion", 1, "1.0.1", a),
      ("sameVersionHigherSequence", 2, "1.0.0", b),
      ("lowerVersionHigherSequence", 2, "0.9.0", b),
      ("newRelease", 2, "1.1.0", b), ("oldRelease", 1, "1.0.0", a),
      ("maximumSequence", UInt64.max, "2.0.0", a),
      ("maximumRepeated", UInt64.max, "2.0.0", a),
      ("maximumConflict", UInt64.max, "3.0.0", b),
      ("invalidZeroSequence", 0, "3.0.0", a),
      ("invalidDigest", UInt64.max, "3.0.0", "bad"),
      ("invalidVersion", UInt64.max, "03.0.0", a),
    ]
    var cases: [JSONValue] = []
    for (name, sequence, version, digest) in inputs {
      let candidate = UpdateReplayRecord(sequence: sequence, payloadSHA256: digest, version: version)
      let decision: String
      do { decision = String(describing: try store.validateAndCommit(candidate)) }
      catch { decision = String(describing: error) }
      let record = try Data(contentsOf: directory.appending(path: "replay-state-v1.json"))
      let reopened = try FileUpdateReplayStore(directory: directory).loadCurrentRecord()
      XCTAssertNotNil(reopened)
      XCTAssertEqual(try encoder.encode(reopened!), record)
      cases.append(.object([
        "name": .string(name), "candidateBase64": .string(try encoder.encode(candidate).base64EncodedString()),
        "decision": .string(decision), "recordBase64": .string(record.base64EncodedString()),
      ]))
    }
    let output = try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object([
      "producer": .string("RuntimeUpdateReplayRustOracleTests"), "cases": .array(cases),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if ProcessInfo.processInfo.environment["ARKDECK_RUST_UPDATE_REPLAY_RECORD"] != nil {
      try HDCOracleHarness.recordOrCompare(
        ["replay.json": output], variable: "ARKDECK_RUST_UPDATE_REPLAY_RECORD",
        oracle: repository.appending(path: "rust/tests/fixtures/runtime-update"))
    } else {
      XCTAssertEqual(output, try Data(contentsOf:
        repository.appending(path: "rust/tests/fixtures/runtime-update/replay.json")))
    }
  }
}
