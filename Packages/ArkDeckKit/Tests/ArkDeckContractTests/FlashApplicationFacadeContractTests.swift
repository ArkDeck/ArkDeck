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
    XCTAssertEqual(presentation.archiveSHA256, plan.archiveSHA256)
    XCTAssertEqual(presentation.planDigestSHA256, plan.planDigestSHA256)
    XCTAssertEqual(
      presentation.dataImpact,
      [
        .mappedPartitionsOverwritten(count: 9),
        .userDataDestroyed,
        .forbiddenAreasPreserved,
      ])
  }

  func testExecutePresentationStaysLockedEvenThoughTheExactPlanCanBeReviewed() throws {
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

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": result])
  }
}
