import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class FlashApplicationFacadeContractTests: XCTestCase {
  func testRuntimeAvailabilityAndTargetFactsDecodeWithoutInventingDefaults() throws {
    let operations = try response([
      [
        "reference": "flash.dayu200",
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
        "reference": "flash.dayu200",
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
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
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

  func testBootloaderStatusProjectsUnboundLoaderWithoutRawIdentityFacts() throws {
    let bootloader = try JSONSerialization.data(withJSONObject: [
      "id": "bootloader", "ok": true,
      "result": [
        "disposition": "unbound",
        "observationCount": 1,
        "mode": "loader",
        "targetId": NSNull(),
        "bindingRevision": NSNull(),
      ],
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(try response([])),
      bootloaderResponse: .success(bootloader))

    XCTAssertEqual(
      presentation.bootloaderStatus,
      RockchipBootloaderStatus(
        disposition: .unbound,
        observationCount: 1,
        mode: "loader",
        targetID: nil,
        bindingRevision: nil))
  }

  func testBootloaderStatusProjectsSelectedTargetThatNeedsFreshAttestation() throws {
    let bootloader = try JSONSerialization.data(withJSONObject: [
      "id": "bootloader", "ok": true,
      "result": [
        "disposition": "targetBindingUnprepared",
        "observationCount": 1,
        "mode": "loader",
        "targetId": "target-dayu200-a",
        "bindingRevision": 2,
      ],
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(
        try response([
          [
            "targetId": "target-dayu200-a",
            "bindingRevision": 2,
            "toolVersion": "3.2.0f",
            "adoptedAtUtc": "2026-08-06T08:00:00Z",
          ]
        ])),
      bootloaderResponse: .success(bootloader))

    XCTAssertEqual(
      presentation.bootloaderStatus,
      RockchipBootloaderStatus(
        disposition: .targetBindingUnprepared,
        observationCount: 1,
        mode: "loader",
        targetID: "target-dayu200-a",
        bindingRevision: 2))
  }

  func testPlanPresentationPreservesEveryTypedStepAndMarksPlanOnlyAsNotExecuted() throws {
    let profile = RockchipFlashProfile.dayu200
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
    XCTAssertTrue(presentation.prerequisites.allSatisfy { $0.status == .unknown })
    XCTAssertEqual(
      Set(presentation.blockingRequiredPrerequisites.map(\.identifier)),
      Set([.loader, .recoveryPath, .unlocked]))

    let ready = presentation.withPrerequisiteObservations(
      RockchipPrerequisiteIdentifier.allCases.map {
        RockchipPrerequisiteObservation(
          identifier: $0,
          status: $0 == .stablePower ? .unknown : .satisfied)
      })
    XCTAssertTrue(ready.blockingRequiredPrerequisites.isEmpty)
  }

  func testExecutePresentationRemainsReviewOnlyUntilRuntimeSubmission() throws {
    let profile = RockchipFlashProfile.dayu200
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
      profile: RockchipFlashProfile.dayu200)
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
      profile: RockchipFlashProfile.dayu200)
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

  func testPlanPresentationPreservesCriticalCancellationSemantics() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let presentation = try executePresentation(target: target)

    XCTAssertEqual(
      presentation.steps.first(where: { $0.kind == "flashPartition" })?.cancellation,
      .criticalNonInterruptible)
  }

  func testPrerequisiteResponsePinsTargetBindingProfileAndClosedVocabulary() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 4, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let rows = RockchipPrerequisiteIdentifier.allCases.map {
      ["identifier": $0.rawValue, "status": "satisfied"]
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "id": "test", "ok": true,
      "result": [
        "targetId": target.id,
        "bindingRevision": target.bindingRevision,
        "profileReference": "dayu200",
        "observations": rows,
      ],
    ])

    let decoded = FlashPrerequisiteResponseDecoding.observations(
      .success(data), target: target, profileReference: "dayu200")
    guard case .success(let observations) = decoded else {
      return XCTFail("matching Runtime prerequisite facts must decode")
    }
    XCTAssertEqual(Set(observations.map(\.identifier)), Set(RockchipPrerequisiteIdentifier.allCases))

    let wrongBinding = FlashTargetPresentation(
      id: target.id, bindingRevision: 5, toolVersion: target.toolVersion,
      adoptedAtUTC: target.adoptedAtUTC)
    guard case .failure = FlashPrerequisiteResponseDecoding.observations(
      .success(data), target: wrongBinding, profileReference: "dayu200")
    else { return XCTFail("stale binding facts must fail closed") }
  }

  private func executePresentation(
    target: FlashTargetPresentation
  ) throws -> FlashExactPlanPresentation {
    let profile = RockchipFlashProfile.dayu200
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
