import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// A historical digest identifies old data; it cannot authorize a new run.
final class HistoricalHAPRecordContractTests: XCTestCase {
  func testSwiftReadsTerminalHAPFromBeforeCompensationDigestWithoutChangingIt() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let bytes = try Data(contentsOf: repository.appending(
      path: "rust/tests/fixtures/debug-hap/store/jobs/job-e79d1b4e261f4a13d0bfb58a97fbf163/job-record.json"))
    var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let request = object["request"] as! [String: Any]
    let inputs = request["inputs"] as! [String: Any]
    XCTAssertEqual(inputs["captureDiagnostics"] as? Bool, true)
    XCTAssertEqual(inputs["cleanupPolicy"] as? String, "uninstall")
    XCTAssertEqual(inputs["postRunAbilityState"] as? String, "stopped")
    let original = try JSONDecoder().decode(RuntimeJobRecord.self, from: bytes)
    XCTAssertEqual(original.state, "failed")
    XCTAssertFalse(original.outcomeUnknown)
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    // Exact published producer before 2fbcaa7c8 (#1773): this fixture requests
    // all fourteen normal steps, with diagnostics, stopped ability, uninstall.
    XCTAssertEqual(descriptor.steps.count, 14)
    let lines = descriptor.steps.map {
      "\($0.stepID)|\($0.kind.rawValue)|\($0.effect.rawValue)|"
        + "\($0.cancellation.rawValue)|\($0.binding.rawValue)"
    }
    let historical = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(historical, "e498f179320e17d223c85768dabed4a5d8719768b55ecf2ce8e70c1f83f9ac44")
    XCTAssertNotEqual(
      historical, original.admissionEvidence?.runtimeCapabilityCorrelation?.stepSetDigestSHA256)
    var admission = object["admissionEvidence"] as! [String: Any]
    var correlation = admission["runtimeCapabilityCorrelation"] as! [String: Any]
    correlation["stepSetDigestSHA256"] = historical
    admission["runtimeCapabilityCorrelation"] = correlation
    object["admissionEvidence"] = admission
    let historicalBytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(RuntimeJobRecord.self, from: historicalBytes)
    XCTAssertEqual(
      try JSONDecoder().decode(JSONValue.self, from: decoded.durableData()),
      try JSONDecoder().decode(JSONValue.self, from: historicalBytes))
  }
}
