import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class FlashApplicationFacadeContractTests: XCTestCase {
  func testRuntimeAvailabilityAndTargetFactsDecodeWithoutInventingDefaults() throws {
    let operations = try response([
      [
        "reference": "flash.dayu200@1",
        "availability": "available",
        "reasons": [],
      ]
    ])
    let targets = try response([
      [
        "targetId": "target-dayu200-a",
        "bindingRevision": 4,
        "toolVersion": "3.2.0f",
        "adoptedAtUtc": "2026-08-06T08:00:00Z",
      ]
    ])

    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(operations),
      targetResponse: .success(targets))

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(
      presentation.targets,
      [
        FlashTargetPresentation(
          id: "target-dayu200-a",
          bindingRevision: 4,
          toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ])
    XCTAssertNil(presentation.targetLoadFailure)
  }

  func testUnavailableOperationKeepsRuntimeReasonsVisible() throws {
    let operations = try response([
      [
        "reference": "flash.dayu200@1",
        "availability": "unavailable",
        "reasons": ["provider_not_registered", "target facts are incomplete"],
      ]
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(operations),
      targetResponse: .success(try response([])))

    XCTAssertEqual(
      presentation.availability,
      .unavailable(reasons: ["provider_not_registered", "target facts are incomplete"]))
    XCTAssertTrue(presentation.targets.isEmpty)
  }

  func testMalformedTargetFailsClosedInsteadOfRenderingAnUnboundChoice() throws {
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200@1", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(
        try response([
          ["targetId": "target-without-binding-revision"]
        ])))

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertTrue(presentation.targets.isEmpty)
    XCTAssertEqual(
      presentation.targetLoadFailure,
      "Runtime returned a target without complete binding facts")
  }

  func testPlanPresentationPreservesEveryTypedStepAndMarksPlanOnlyAsNotExecuted() throws {
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .planOnly, archiveValidation: .valid, planNonce: "ui-test")
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")

    let presentation = FlashPlanPresentationBuilder.presentation(
      plan: plan,
      profile: profile,
      target: target,
      imageFileName: "dayu200_img.tar.gz")

    XCTAssertEqual(presentation.steps.count, plan.steps.count)
    XCTAssertEqual(presentation.steps.map(\.id), plan.steps.map(\.id))
    XCTAssertTrue(presentation.steps.allSatisfy { $0.disposition == .planned })
    XCTAssertTrue(presentation.steps.contains { $0.effect == .destructive })
    XCTAssertEqual(presentation.target, target)
    XCTAssertEqual(presentation.profileReference, profile.catalogReference)
    XCTAssertEqual(
      presentation.toolchainFingerprint,
      RockchipFlashProfile.pinnedToolchainFingerprint)
    XCTAssertEqual(presentation.archiveSHA256, plan.archiveSHA256)
    XCTAssertEqual(presentation.planDigestSHA256, plan.planDigestSHA256)
    XCTAssertEqual(
      presentation.dataImpact,
      [
        .mappedPartitionsOverwritten(count: 9),
        .userDataDestroyed,
        .forbiddenAreasPreserved,
      ])
    XCTAssertEqual(presentation.partitions.count, profile.mappedPartitions.count)
    XCTAssertEqual(
      presentation.partitions.map(\.partitionName),
      profile.mappedPartitions.map(\.partitionName))
    XCTAssertEqual(
      presentation.writeForbiddenMemberNames,
      profile.writeForbiddenMemberNames.sorted())
    XCTAssertEqual(
      Set(presentation.prerequisites.map(\.identifier)),
      Set(profile.prerequisites.keys))
  }

  func testExecutePresentationRemainsReviewOnlyUntilRuntimeSubmission() throws {
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid, planNonce: "ui-test")
    let presentation = FlashPlanPresentationBuilder.presentation(
      plan: plan,
      profile: profile,
      target: nil,
      imageFileName: "dayu200_img.tar.gz")

    XCTAssertFalse(presentation.steps.isEmpty)
    XCTAssertTrue(presentation.steps.allSatisfy { $0.disposition == .executionLocked })
  }

  func testExecuteReviewUsesTheRuntimeCanonicalPlan() throws {
    let provider = RockchipRockUSBFlashProvider(
      profile: RockchipFlashProfile.dayu200OpenHarmony70035)
    let reviewedPlan = try FlashPlanPresentationBuilder.materializePlan(
      provider: provider,
      mode: .execute,
      archiveValidation: .valid)
    let campaignPlan = try provider.makePlan(
      mode: .execute,
      archiveValidation: .valid)

    XCTAssertEqual(reviewedPlan.planDigestSHA256, campaignPlan.planDigestSHA256)
    XCTAssertEqual(reviewedPlan.stepSetDigestSHA256, campaignPlan.stepSetDigestSHA256)
    XCTAssertEqual(reviewedPlan.steps.map(\.id), campaignPlan.steps.map(\.id))
  }

  func testPreviewModesCannotReuseExecutableStepIdentities() throws {
    let provider = RockchipRockUSBFlashProvider(
      profile: RockchipFlashProfile.dayu200OpenHarmony70035)
    let executePlan = try FlashPlanPresentationBuilder.materializePlan(
      provider: provider,
      mode: .execute,
      archiveValidation: .valid)

    for mode in [RockchipFlashExecutionMode.planOnly, .simulated] {
      let preview = try FlashPlanPresentationBuilder.materializePlan(
        provider: provider,
        mode: mode,
        archiveValidation: .valid)
      XCTAssertNotEqual(preview.stepSetDigestSHA256, executePlan.stepSetDigestSHA256)
      XCTAssertNotEqual(preview.steps.map(\.id), executePlan.steps.map(\.id))
    }
  }

  func testExactDoubleConfirmationProducesOnlyAZeroDispatchHumanHandoff() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let presentation = try executePresentation(target: target)
    let phrase = FlashManualConfirmationValidator.destructivePhrase(for: presentation)

    let result = FlashManualConfirmationValidator.confirm(
      currentPlan: presentation,
      reviewedPlan: presentation,
      currentTarget: target,
      destructivePhrase: phrase,
      userdataPhrase: FlashManualConfirmationValidator.userdataPhrase,
      confirmedAtUTC: "2026-08-06T12:00:00Z")

    guard case .accepted(let handoff) = result else {
      return XCTFail("exact confirmation should produce a human handoff: \(result)")
    }
    XCTAssertEqual(handoff.target, target)
    XCTAssertEqual(handoff.planDigestSHA256, presentation.planDigestSHA256)
    XCTAssertEqual(handoff.archiveSHA256, presentation.archiveSHA256)
    XCTAssertEqual(handoff.destructiveConfirmationPhrase, phrase)
    XCTAssertEqual(handoff.deviceMutationDispatchCount, 0)
  }

  func testConfirmationFailsClosedOnEveryPhrasePlanAndTargetMismatch() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let reviewed = try executePresentation(target: target)
    let phrase = FlashManualConfirmationValidator.destructivePhrase(for: reviewed)

    func confirm(
      currentPlan: FlashExactPlanPresentation? = nil,
      currentTarget: FlashTargetPresentation? = nil,
      destructivePhrase: String? = nil,
      userdataPhrase: String? = nil
    ) -> FlashManualConfirmationResult {
      FlashManualConfirmationValidator.confirm(
        currentPlan: currentPlan ?? reviewed,
        reviewedPlan: reviewed,
        currentTarget: currentTarget ?? target,
        destructivePhrase: destructivePhrase ?? phrase,
        userdataPhrase: userdataPhrase ?? FlashManualConfirmationValidator.userdataPhrase,
        confirmedAtUTC: "2026-08-06T12:00:00Z")
    }

    XCTAssertEqual(
      confirm(destructivePhrase: "FLASH wrong"),
      .rejected(.destructivePhraseMismatch))
    XCTAssertEqual(
      confirm(userdataPhrase: "ERASE USERDATA"),
      .rejected(.userdataPhraseMismatch))
    XCTAssertEqual(
      confirm(
        currentTarget: FlashTargetPresentation(
          id: target.id,
          bindingRevision: target.bindingRevision + 1,
          toolVersion: target.toolVersion,
          adoptedAtUTC: target.adoptedAtUTC)),
      .rejected(.missingOrStaleTarget))
    XCTAssertEqual(
      FlashManualConfirmationValidator.confirm(
        currentPlan: reviewed,
        reviewedPlan: reviewed,
        currentTarget: nil,
        destructivePhrase: phrase,
        userdataPhrase: FlashManualConfirmationValidator.userdataPhrase,
        confirmedAtUTC: "2026-08-06T12:00:00Z"),
      .rejected(.missingOrStaleTarget))
    XCTAssertEqual(
      FlashManualConfirmationValidator.confirm(
        currentPlan: nil,
        reviewedPlan: reviewed,
        currentTarget: target,
        destructivePhrase: phrase,
        userdataPhrase: FlashManualConfirmationValidator.userdataPhrase,
        confirmedAtUTC: "2026-08-06T12:00:00Z"),
      .rejected(.stalePlan))

    let stale = FlashExactPlanPresentation(
      mode: reviewed.mode,
      target: reviewed.target,
      profileReference: reviewed.profileReference,
      toolchainFingerprint: reviewed.toolchainFingerprint,
      imageFileName: "different-images.tar.gz",
      runtimeBuildVersion: reviewed.runtimeBuildVersion,
      archiveSizeBytes: reviewed.archiveSizeBytes,
      archiveSHA256: reviewed.archiveSHA256,
      mappedPartitionCount: reviewed.mappedPartitionCount,
      planDigestSHA256: reviewed.planDigestSHA256,
      stepSetDigestSHA256: reviewed.stepSetDigestSHA256,
      steps: reviewed.steps,
      dataImpact: reviewed.dataImpact,
      partitions: reviewed.partitions,
      writeForbiddenMemberNames: reviewed.writeForbiddenMemberNames,
      prerequisites: reviewed.prerequisites)
    XCTAssertEqual(confirm(currentPlan: stale), .rejected(.stalePlan))

    let nonExecute = FlashExactPlanPresentation(
      mode: .planOnly,
      target: reviewed.target,
      profileReference: reviewed.profileReference,
      toolchainFingerprint: reviewed.toolchainFingerprint,
      imageFileName: reviewed.imageFileName,
      runtimeBuildVersion: reviewed.runtimeBuildVersion,
      archiveSizeBytes: reviewed.archiveSizeBytes,
      archiveSHA256: reviewed.archiveSHA256,
      mappedPartitionCount: reviewed.mappedPartitionCount,
      planDigestSHA256: reviewed.planDigestSHA256,
      stepSetDigestSHA256: reviewed.stepSetDigestSHA256,
      steps: reviewed.steps,
      dataImpact: reviewed.dataImpact,
      partitions: reviewed.partitions,
      writeForbiddenMemberNames: reviewed.writeForbiddenMemberNames,
      prerequisites: reviewed.prerequisites)
    XCTAssertEqual(
      FlashManualConfirmationValidator.confirm(
        currentPlan: nonExecute,
        reviewedPlan: nonExecute,
        currentTarget: target,
        destructivePhrase: phrase,
        userdataPhrase: FlashManualConfirmationValidator.userdataPhrase,
        confirmedAtUTC: "2026-08-06T12:00:00Z"),
      .rejected(.notExecutePlan))
  }

  private func executePresentation(
    target: FlashTargetPresentation
  ) throws -> FlashExactPlanPresentation {
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid, planNonce: "ui-confirmation-test")
    return FlashPlanPresentationBuilder.presentation(
      plan: plan,
      profile: profile,
      target: target,
      imageFileName: "dayu200_img.tar.gz")
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": result])
  }
}
