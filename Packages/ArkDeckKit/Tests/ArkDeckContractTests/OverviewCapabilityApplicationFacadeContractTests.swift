import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class OverviewCapabilityApplicationFacadeContractTests: XCTestCase {
  func testFixtureProjectsTheFourActualCapabilityRows() async {
    let provider = OverviewCapabilityApplicationFacade.make(
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh(targetID: nil)

    XCTAssertEqual(presentation.targetID, "ui-fixture-target")
    XCTAssertEqual(
      presentation.items.map(\.id),
      ["hidumper", "hitrace", "bytrace", "rockusb-flash"])
    XCTAssertEqual(presentation.items.first(where: { $0.id == "hitrace" })?.state, .available)
    XCTAssertEqual(presentation.items.first(where: { $0.id == "bytrace" })?.state, .unknown)
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["ui-fixture-target"])
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
    XCTAssertEqual(presentation.adoptedTargets.map(\.id), ["ui-fixture-target"])
    XCTAssertEqual(
      presentation.failure, "The selected target is no longer adopted: some-other-target")
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
    XCTAssertTrue(source.contains("method: \"debug.template.run\""))
    XCTAssertTrue(source.contains("ArkForgeFlashOperation.canonicalReference"))
    XCTAssertFalse(source.contains("flash.dayu200"))
    XCTAssertFalse(source.contains("flashd"))
    XCTAssertTrue(source.contains("TraceRuntimeToolDisposition"))
  }
}
