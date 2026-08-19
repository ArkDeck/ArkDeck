import ArkDeckWorkflows
import ArkDeckRuntime
import Foundation
import XCTest

final class HumanActionRequiredContractTests: XCTestCase {
  func testEightHumanBoundariesHaveExactClosedMappings() throws {
    let cases:
      [(
        HumanActionCategory,
        String,
        String,
        HumanActionResumeProbeOperation,
        [HumanActionProhibitedAutomation]
      )] = [
        (
          .physicalConnection, "device.notObserved", "human.connectOrPowerDevice",
          .observeDevice, [.physicalActuation]
        ),
        (
          .deviceTrustPrompt, "device.trustPending", "human.acceptDeviceTrustPrompt",
          .observeDevice, [.trustPromptAcceptance]
        ),
        (
          .osPermission, "host.permissionOrDriverRequired", "human.configureHostPermission",
          .probeHostConfiguration,
          [.privilegeEscalation, .driverOrHelperInstall, .systemRuleMutation]
        ),
        (
          .credentialProvisioning, "host.credentialRequired", "human.provisionCredential",
          .probeHostConfiguration, [.credentialExtraction]
        ),
        (
          .ambiguousIdentity, "device.identityAmbiguous", "human.confirmDeviceIdentity",
          .observeDevice, [.identityGuess]
        ),
        (
          .impactApproval, "policy.impactApprovalRequired", "human.reviewImpact",
          .probeImpactApproval, [.selfApproval]
        ),
        (
          .outcomeUnknownDecision, "recovery.outcomeUnknown", "human.reconcileOrAbandon",
          .reconcileOutcome, [.outcomeGuess]
        ),
        (
          .governanceApproval, "governance.approvalRequired", "human.mergeRequiredApproval",
          .probeGovernanceApproval, [.selfApproval]
        ),
      ]
    for (offset, item) in cases.enumerated() {
      let action = try HumanActionRequired(
        actionID: "action-\(offset)", jobID: "job-\(offset)", category: item.0,
        generatedAtUTC: "2026-07-28T10:00:00Z")
      XCTAssertEqual(action.reasonCode, item.1)
      XCTAssertEqual(action.minimumActionKey, item.2)
      XCTAssertEqual(action.resumeProbeOperationID, item.3)
      XCTAssertEqual(action.prohibitedAutomation, item.4)
      XCTAssertEqual(action.status, .waiting)
      XCTAssertNil(action.resolution)
      XCTAssertEqual(
        try HumanActionRequiredCodec.decode(HumanActionRequiredCodec.encode(action)),
        action)
    }
  }

  func testOnlyMatchingFreshTrustedProbeCanResolve() throws {
    let action = try HumanActionRequired(
      actionID: "action-trust", jobID: "job-trust", stepID: "probe-step",
      category: .deviceTrustPrompt, generatedAtUTC: "2026-07-28T10:00:00Z",
      expiresAtUTC: "2026-07-28T10:05:00Z")
    let wrong = try HumanActionFreshProbeReceipt(
      probeOperationID: .probeHostConfiguration, probeReceiptID: "receipt-wrong",
      observedAtUTC: "2026-07-28T10:01:00Z")
    XCTAssertThrowsError(try action.resolving(with: wrong))

    let stale = try HumanActionFreshProbeReceipt(
      probeOperationID: .observeDevice, probeReceiptID: "receipt-stale",
      observedAtUTC: "2026-07-28T09:59:59Z")
    XCTAssertThrowsError(try action.resolving(with: stale))

    let fresh = try HumanActionFreshProbeReceipt(
      probeOperationID: .observeDevice, probeReceiptID: "receipt-fresh",
      observedAtUTC: "2026-07-28T10:01:00Z")
    let resolved = try action.resolving(with: fresh)
    XCTAssertEqual(resolved.status, .resolvedByFreshProbe)
    XCTAssertEqual(resolved.resolution?.probeReceiptID, "receipt-fresh")
    XCTAssertThrowsError(try resolved.resolving(with: fresh))
  }

  func testCodecRejectsDuplicateUnknownDriftAndTextOnlyResolution() throws {
    let valid = """
      {"documentType":"humanActionRequired","schemaVersion":"1.0.0","actionId":"action-1","jobId":"job-1","category":"physicalConnection","reasonCode":"device.notObserved","minimumActionKey":"human.connectOrPowerDevice","prohibitedAutomation":["physicalActuation"],"resumeProbeOperationId":"observeDevice","generatedAtUtc":"2026-07-28T10:00:00Z","status":"waiting"}
      """
    XCTAssertNoThrow(try HumanActionRequiredCodec.decode(Data(valid.utf8)))
    let vectors = [
      valid.replacingOccurrences(
        of: #""actionId":"action-1""#,
        with: #""actionId":"action-1","action\u0049d":"action-2""#),
      valid.replacingOccurrences(
        of: #""status":"waiting""#, with: #""status":"waiting","text":"done""#),
      valid.replacingOccurrences(
        of: #""reasonCode":"device.notObserved""#,
        with: #""reasonCode":"device.trustPending""#),
      valid.replacingOccurrences(
        of: #""status":"waiting""#,
        with: #""status":"resolvedByFreshProbe""#),
    ]
    for vector in vectors {
      XCTAssertThrowsError(try HumanActionRequiredCodec.decode(Data(vector.utf8)))
    }
    print(
      "TEST-AIN-HUMAN-001 PASS categories=8 resume_probes=5 prohibited_automation=9 "
        + "text_resume=blocked authority_elevation=0")
  }
}
