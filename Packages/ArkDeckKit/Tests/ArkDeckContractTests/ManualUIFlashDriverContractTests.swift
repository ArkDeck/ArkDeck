import Foundation
import XCTest

final class ManualUIFlashDriverContractTests: XCTestCase {
  private func driverSource() throws -> String {
    var repositoryRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      repositoryRoot.deleteLastPathComponent()
    }
    return try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("scripts/rockchip_component/manual_ui_flash.swift"),
      encoding: .utf8)
  }

  func testDriverUsesThePublishedOneClickFlashSurface() throws {
    let source = try driverSource()
    let legacyControls = [
      "flash.execute.review",
      "flash.confirm.destructivePhrase",
      "flash.confirm.userdataPhrase",
      "flash.confirm.accept",
      "flash.execute.mutationDispatchCount",
    ]
    for control in legacyControls {
      XCTAssertFalse(source.contains(control), "legacy UI control remains: \(control)")
    }

    XCTAssertTrue(
      source.contains("try driver.waitForEnabled(\"flash.execute.submit\", timeout: 30)"))
    XCTAssertTrue(source.contains("try driver.assertNoFlashSubmission()"))
    XCTAssertTrue(source.contains("try driver.submit(\"flash.execute.submit\")"))
  }

  func testNavigationHasNativeActionFallbackWhenAXOmitsTheFrame() throws {
    let source = try driverSource()
    let startMarker =
      "  private func click(_ element: AXUIElement, identifier: String) throws {"
    let endMarker = "\n  func setValue("
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
    let implementation = source[start..<end]
    XCTAssertTrue(implementation.contains("kAXPressAction"))
    XCTAssertTrue(implementation.contains("kAXSelectedAttribute"))
  }
}
