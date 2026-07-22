import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

// TASK-AIN-006: strict carrier parsing and the public authorization-gate regression. Parsed JSON
// remains inert data; only the internal provenance resolver may mint a grant.
final class StandingAuthorizationContractTests: XCTestCase {
  private let provider = RockchipRockUSBFlashProvider()

  private func document(plan: RockchipFlashPlan) -> [String: Any] {
    [
      "schemaVersion": "1.0.0",
      "authorizationId": "AUTH-2026-025-DAYU200-001",
      "approvedBy": "lvye",
      "carrier": "protected-main PR #296 registry carrier",
      "target": [
        "model": RockchipFlashProfile.targetDeviceModel,
        "serialSHA256": Self.sha256("fixture-serial"),
        "bindingRevision": 1,
      ],
      "firmwareArchiveSHA256": plan.archiveSHA256,
      "transport": "usb",
      "toolchainFingerprint": RockchipFlashProfile.pinnedToolchainFingerprint,
      "providerIdentity": RockchipRockUSBFlashProvider.providerIdentity,
      "planDigestSHA256": plan.planDigestSHA256,
      "stepSetDigestSHA256": plan.stepSetDigestSHA256,
      "recoveryPath": "CHG-2026-016 Loader wlx recovery",
      "validUntil": "2030-08-31T00:00:00Z",
      "maxRuns": 1,
    ]
  }

  private func bytes(_ dictionary: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
  }

  func testStrictCarrierAcceptsOnlyCanonicalClosedDocument() throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let parsed = try RockchipStandingAuthorization.parse(bytes(document(plan: plan)))
    XCTAssertEqual(parsed.authorizationId, "AUTH-2026-025-DAYU200-001")
    XCTAssertEqual(parsed.maxRuns, 1)
    XCTAssertTrue(RockchipStandingAuthorizationIdentifier.isValid(parsed.authorizationId))

    var unknown = document(plan: plan)
    unknown["callerAuthority"] = true
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(unknown)))

    var missing = document(plan: plan)
    missing.removeValue(forKey: "carrier")
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(missing)))

    var uppercase = document(plan: plan)
    uppercase["planDigestSHA256"] = plan.planDigestSHA256.uppercased()
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(uppercase))) { error in
      XCTAssertEqual(
        error as? RockchipStandingAuthorizationParseError,
        .invalidDigest(field: "planDigestSHA256"))
    }

    var badRevision = document(plan: plan)
    var target = try XCTUnwrap(badRevision["target"] as? [String: Any])
    target["bindingRevision"] = 0
    badRevision["target"] = target
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(badRevision)))

    var badTime = document(plan: plan)
    badTime["validUntil"] = "someday"
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(badTime)))

    var noncanonicalTime = document(plan: plan)
    noncanonicalTime["validUntil"] = "2030-08-31T00:00:00+00:00"
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(bytes(noncanonicalTime)))
  }

  func testDuplicateMembersIncludingEscapedNamesFailClosed() throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let canonical = try String(decoding: bytes(document(plan: plan)), as: UTF8.self)
    let direct = Data(canonical.dropLast().appending(",\"maxRuns\":1}").utf8)
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(direct))

    let escaped = Data(canonical.dropLast().appending(",\"max\\u0052uns\":1}").utf8)
    XCTAssertThrowsError(try RockchipStandingAuthorization.parse(escaped))
  }

  func testAuthorizationIdentifierCannotSelectPathsOrAlternateSpellings() {
    for value in [
      "AUTH-OK-001", "AUTH-A1", "AUTH-2026-025-DAYU200-001",
    ] {
      XCTAssertTrue(RockchipStandingAuthorizationIdentifier.isValid(value), value)
    }
    for value in [
      "AUTH-", "auth-A1", "AUTH-A_1", "AUTH-A/1", "AUTH-A..1", "AUTH-A--1", "AUTH-A1-",
      "../AUTH-A1", "AUTH-%2F", "AUTH-设备",
    ] {
      XCTAssertFalse(RockchipStandingAuthorizationIdentifier.isValid(value), value)
    }
  }

  func testPublicGateKeepsAgentAndCIBlockedWithZeroDispatch() async throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    for authority in [RockchipExecutionAuthority.standardAgent, .ordinaryCI] {
      let decision = await RockchipFlashAuthorizationGate().authorize(
        authority: authority,
        binding: .none,
        plan: plan,
        prerequisites: .cleared,
        destructiveConfirmationAccepted: false,
        manualConfirmation: nil,
        monitor: RockchipFlashDispatchMonitor())
      guard case .policyBlocked(let handoff) = decision.outcome else {
        return XCTFail("\(authority) must remain policyBlocked")
      }
      XCTAssertTrue(handoff.confirmationRequirements.joined().contains("standing authorization"))
      XCTAssertEqual(decision.evidenceEligibility, .notEligible)
      XCTAssertNil(decision.authorizationRef)
      XCTAssertEqual(decision.dispatchSnapshot.totalDispatchCount, 0)
    }

    let planOnly = try provider.makePlan(mode: .planOnly, archiveValidation: .valid)
    let nonExecute = await RockchipFlashAuthorizationGate().authorize(
      authority: .standardAgent,
      binding: .none,
      plan: planOnly,
      prerequisites: .cleared,
      destructiveConfirmationAccepted: false,
      manualConfirmation: nil,
      monitor: RockchipFlashDispatchMonitor())
    XCTAssertEqual(nonExecute.outcome, .allowedNonExecuteBranch)
    XCTAssertEqual(nonExecute.dispatchSnapshot.totalDispatchCount, 0)

    print(
      "TEST-AC-FLASH-015-01 PASS agent=policyBlocked ci=policyBlocked "
        + "planOnly=allowed dispatch=0")
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
