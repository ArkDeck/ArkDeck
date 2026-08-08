import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class OverviewCapabilityApplicationFacadeContractTests: XCTestCase {
  func testFixtureProjectsTheFourActualCapabilityRows() async {
    let provider = OverviewCapabilityApplicationFacade.make(
      arguments: ["ArkDeck", "--ui-test-hdc-diagnostics"])
    let presentation = await provider.refresh()

    XCTAssertEqual(presentation.targetID, "ui-fixture-target")
    XCTAssertEqual(
      presentation.items.map(\.id),
      ["hidumper", "hitrace", "bytrace", "rockusb-flash"])
    XCTAssertEqual(presentation.items.first(where: { $0.id == "hitrace" })?.state, .available)
    XCTAssertEqual(presentation.items.first(where: { $0.id == "bytrace" })?.state, .unknown)
  }

  func testProductionSourceUsesIndependentFactsAndThePublishedFlashOperation() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("method: \"trace.probe\""))
    XCTAssertTrue(source.contains("method: \"debug.template.run\""))
    XCTAssertTrue(source.contains("flash.dayu200@1"))
    XCTAssertFalse(source.contains("flashd"))
    XCTAssertTrue(source.contains("TraceRuntimeToolDisposition"))
  }
}
