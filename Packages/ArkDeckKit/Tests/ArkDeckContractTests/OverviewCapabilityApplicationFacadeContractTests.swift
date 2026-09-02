import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class OverviewCapabilityApplicationFacadeContractTests: XCTestCase {
  func testFixtureProjectsTheFourActualCapabilityRows() async {
    let provider = OverviewCapabilityApplicationFacade.make(
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh(targetID: nil)

    XCTAssertEqual(presentation.targetID, "target-fixture-dayu200")
    XCTAssertEqual(
      presentation.items.map(\.id),
      ["hidumper", "hitrace", "bytrace", "rockusb-flash"])
    XCTAssertEqual(presentation.items.first(where: { $0.id == "hitrace" })?.state, .available)
    XCTAssertEqual(presentation.items.first(where: { $0.id == "bytrace" })?.state, .unknown)
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-fixture-dayu200"])
  }

  /// A target the operator did not choose is never described. The fixture
  /// stands in for the production rule: an unknown selection reports what is
  /// adopted instead of quietly answering about something else.
  func testAnUnadoptedSelectionIsRefusedRatherThanSubstituted() async {
    let provider = OverviewCapabilityApplicationFacade.make(
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh(targetID: "some-other-target")

    XCTAssertNil(presentation.targetID)
    XCTAssertTrue(presentation.items.isEmpty)
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-fixture-dayu200"])
    XCTAssertEqual(
      presentation.failure, "The selected target is no longer adopted: some-other-target")
  }

  func testOverviewOnlineProjectionOmitsOfflineAndStaleAdoptedTargets() {
    let capabilities = OverviewCapabilityMatrixPresentation(
      targetID: "target-offline", bindingRevision: 2,
      items: [
        OverviewCapabilityItemPresentation(
          id: "hidumper", name: "hidumper", state: .available, evidence: "old target"),
        OverviewCapabilityItemPresentation(
          id: "rockusb-flash", name: "RockUSB Flash", state: .available,
          evidence: "catalog"),
      ],
      adoptedTargets: [
        OverviewCapabilityTarget(id: "target-online", bindingRevision: 4),
        OverviewCapabilityTarget(id: "target-offline", bindingRevision: 2),
        OverviewCapabilityTarget(id: "target-stale", bindingRevision: 1),
      ])
    let devices = DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "online", state: "Connected",
          adoptedTargetID: "target-online", bindingRevision: 4),
        DeviceCandidatePresentation(
          connectKey: "offline", state: "Offline",
          adoptedTargetID: "target-offline", bindingRevision: 2),
        DeviceCandidatePresentation(
          connectKey: "stale", state: "Connected",
          adoptedTargetID: "target-stale", bindingRevision: 1,
          stateObservationHealth: .stale),
      ])

    let presentation = OverviewOnlineTargetProjection.presentation(
      from: capabilities, devices: devices, preferredTargetID: "target-offline")

    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["target-online"])
    XCTAssertEqual(presentation.targetID, "target-online")
    XCTAssertEqual(presentation.bindingRevision, 4)
    XCTAssertEqual(presentation.items.map(\.id), ["rockusb-flash"])
  }

  /// The defect this replaced: the matrix bound `targets.first`, so on a host
  /// with several adopted devices it described an arbitrary one and the page
  /// could not say whose capabilities the reader was looking at.
  func testSeveralAdoptedTargetsAreReportedInsteadOfProbingAnArbitraryOne() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift"),
      encoding: .utf8)

    XCTAssertFalse(
      source.contains("targets.first"),
      "resolving a target by position is the defect, not an implementation detail")
    XCTAssertTrue(source.contains("adopted targets are available; choose which one"))
    XCTAssertTrue(source.contains("adoptedTargets: adopted"))
  }

  func testProductionSourceUsesIndependentFactsAndThePublishedFlashOperation() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("method: \"trace.probe\""))
    XCTAssertTrue(source.contains("DebugTemplateJobExecution.run("))
    XCTAssertFalse(source.contains("method: \"debug.template.run\""))
    XCTAssertTrue(source.contains("debug.template@1 Job succeeded"))
    XCTAssertTrue(source.contains("ArkForgeFlashOperation.canonicalReference"))
    XCTAssertFalse(source.contains("flash.dayu200"))
    XCTAssertFalse(source.contains("flashd"))
    XCTAssertTrue(source.contains("TraceRuntimeToolDisposition"))
  }
}
