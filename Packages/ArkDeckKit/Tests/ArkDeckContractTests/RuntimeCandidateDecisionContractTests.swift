import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RuntimeCandidateActionContractTests: XCTestCase {
  func testActionsAreEffectLevelAndDoNotEnumerateRepairKinds() throws {
    let vectors: [(String, RuntimeDebugCandidateAction)] = [
      (
        #"{"schemaVersion":"1.0.0","action":"observePinnedRequest"}"#,
        .observePinnedRequest
      ),
      (
        #"{"schemaVersion":"1.0.0","action":"executePinnedRequest"}"#,
        .executePinnedRequest
      ),
      (
        #"{"schemaVersion":"1.0.0","action":"stop","reasonCode":"budgetExhausted"}"#,
        .stop(reasonCode: "budgetExhausted")
      ),
    ]

    for (document, expected) in vectors {
      XCTAssertEqual(
        try RuntimeDebugCandidateActionCodec.decode(Data(document.utf8)), expected)
    }
  }

  func testCandidateCannotInjectAuthorityTargetPlanArgvOrRepairParameters() {
    for key in [
      "authority", "capability", "target", "binding", "operation", "inputs", "plan",
      "step", "argv", "executable", "timing", "alternativeId", "observationId",
    ] {
      let document =
        #"{"schemaVersion":"1.0.0","action":"executePinnedRequest","\#(key)":"forged"}"#
      XCTAssertThrowsError(
        try RuntimeDebugCandidateActionCodec.decode(Data(document.utf8))
      ) { error in
        XCTAssertEqual(error as? RuntimeDebugCandidateActionError, .closedShapeViolation)
      }
    }
  }

  func testDuplicateMemberAndUnknownActionFailClosed() {
    let duplicate =
      #"{"schemaVersion":"1.0.0","action":"executePinnedRequest","action":"stop"}"#
    XCTAssertThrowsError(
      try RuntimeDebugCandidateActionCodec.decode(Data(duplicate.utf8))
    ) { error in
      XCTAssertEqual(error as? RuntimeDebugCandidateActionError, .invalidDocument)
    }

    let unknown = #"{"schemaVersion":"1.0.0","action":"fixNewestFailure"}"#
    XCTAssertThrowsError(
      try RuntimeDebugCandidateActionCodec.decode(Data(unknown.utf8))
    ) { error in
      XCTAssertEqual(error as? RuntimeDebugCandidateActionError, .unsupportedAction)
    }
  }

  func testStopReasonIsClosedDiagnosticNotAnEffectCarrier() {
    for reason in ["", "UPPER_CASE", "contains space", String(repeating: "a", count: 129)] {
      let encoded = try! JSONSerialization.data(
        withJSONObject: [
          "schemaVersion": "1.0.0", "action": "stop", "reasonCode": reason,
        ], options: [.sortedKeys])
      XCTAssertThrowsError(try RuntimeDebugCandidateActionCodec.decode(encoded))
    }
  }
}
