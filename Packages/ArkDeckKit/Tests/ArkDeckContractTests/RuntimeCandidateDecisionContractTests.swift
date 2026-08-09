import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RuntimeCandidateDecisionContractTests: XCTestCase {
  private func envelope() throws -> RuntimeCandidateRepairEnvelope {
    try RuntimeCandidateRepairEnvelope(
      alternativeIDs: ["postflight.uniqueHdcPersonality"],
      observationIDs: ["postflight.hdcCandidates"],
      timingBounds: [
        "hdcReconnectDeadlineMilliseconds": try RuntimeCandidateTimingBounds(
          minimum: 30_000, maximum: 180_000)
      ])
  }

  func testClosedPublishedDecisionsDecode() throws {
    let vectors: [(String, RuntimeCandidateDecision)] = [
      (
        #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults"}"#,
        .usePublishedDefaults
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"postflight.uniqueHdcPersonality"}"#,
        .selectPublishedAlternative("postflight.uniqueHdcPersonality")
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"boundedTiming","parameter":"hdcReconnectDeadlineMilliseconds","value":120000}"#,
        .boundedTiming(parameter: "hdcReconnectDeadlineMilliseconds", value: 120_000)
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"requestPublishedObservation","observationId":"postflight.hdcCandidates"}"#,
        .requestPublishedObservation("postflight.hdcCandidates")
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"stop","reasonCode":"repairSurfaceInsufficient"}"#,
        .stop(reasonCode: "repairSurfaceInsufficient")
      ),
    ]

    for (document, expected) in vectors {
      XCTAssertEqual(
        try RuntimeCandidateDecisionCodec.decode(Data(document.utf8), envelope: envelope()),
        expected)
    }
  }

  func testAuthorityFactAndPlanFieldsAreRejected() throws {
    let forbidden = [
      "operation", "profile", "target", "bindingRevision", "partition", "artifact",
      "step", "effect", "executable", "argv", "capability", "reservation", "outcome",
      "coverageProof",
    ]
    for key in forbidden {
      let document =
        #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults","\#(key)":"forged"}"#
      XCTAssertThrowsError(
        try RuntimeCandidateDecisionCodec.decode(Data(document.utf8), envelope: envelope()),
        "candidate field \(key) must fail closed"
      ) { error in
        XCTAssertEqual(error as? RuntimeCandidateDecisionError, .closedShapeViolation)
      }
    }
  }

  func testDuplicateMemberIsRejectedBeforeDecoding() throws {
    let document =
      #"{"schemaVersion":"1.0.0","kind":"usePublishedDefaults","kind":"stop"}"#
    XCTAssertThrowsError(
      try RuntimeCandidateDecisionCodec.decode(Data(document.utf8), envelope: envelope())
    ) { error in
      XCTAssertEqual(error as? RuntimeCandidateDecisionError, .invalidDocument)
    }
  }

  func testUnpublishedAlternativeObservationAndTimingAreRejected() throws {
    let vectors: [(String, RuntimeCandidateDecisionError)] = [
      (
        #"{"schemaVersion":"1.0.0","kind":"selectPublishedAlternative","alternativeId":"provider.newCommand"}"#,
        .alternativeNotPublished("provider.newCommand")
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"requestPublishedObservation","observationId":"device.rawIdentity"}"#,
        .observationNotPublished("device.rawIdentity")
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"boundedTiming","parameter":"newTimeout","value":1000}"#,
        .timingNotPublished("newTimeout")
      ),
      (
        #"{"schemaVersion":"1.0.0","kind":"boundedTiming","parameter":"hdcReconnectDeadlineMilliseconds","value":180001}"#,
        .timingOutOfBounds("hdcReconnectDeadlineMilliseconds")
      ),
    ]

    for (document, expected) in vectors {
      XCTAssertThrowsError(
        try RuntimeCandidateDecisionCodec.decode(Data(document.utf8), envelope: envelope())
      ) { error in
        XCTAssertEqual(error as? RuntimeCandidateDecisionError, expected)
      }
    }
  }

  func testRepairEnvelopeCannotBeWidenedByMalformedEntries() throws {
    XCTAssertThrowsError(
      try RuntimeCandidateRepairEnvelope(
        alternativeIDs: ["valid", "valid"], observationIDs: [], timingBounds: [:]))
    XCTAssertThrowsError(
      try RuntimeCandidateRepairEnvelope(
        alternativeIDs: ["../../provider"], observationIDs: [], timingBounds: [:]))
    XCTAssertThrowsError(
      try RuntimeCandidateTimingBounds(minimum: -1, maximum: 1))
    XCTAssertThrowsError(
      try RuntimeCandidateTimingBounds(minimum: 10, maximum: 9))
  }
}
