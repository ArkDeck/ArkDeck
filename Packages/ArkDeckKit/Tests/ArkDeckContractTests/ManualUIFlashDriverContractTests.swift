import Foundation
import XCTest

final class ManualUIFlashDriverContractTests: XCTestCase {
  private func repositorySource(_ path: String) throws -> String {
    var repositoryRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      repositoryRoot.deleteLastPathComponent()
    }
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(path),
      encoding: .utf8)
  }

  private func driverSource() throws -> String {
    try repositorySource("scripts/rockchip_component/manual_ui_flash.swift")
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
    XCTAssertTrue(
      source.contains("try driver.waitForPresence(\"flash.impact.userdata\", timeout: 30)"))
    XCTAssertFalse(source.contains("\"ERASE-USERDATA\","))
    XCTAssertTrue(source.contains("try driver.assertNoFlashSubmission()"))
    XCTAssertTrue(source.contains("try driver.submit(\"flash.execute.submit\")"))
  }

  func testApplicationExposesLocalizedUserdataImpactWithStableAccessibilityIdentity() throws {
    let source = try repositorySource("ArkDeckApp/Features/Flash/FlashWorkspaceView.swift")
    XCTAssertTrue(
      source.contains(".accessibilityIdentifier(dataImpactIdentifier(impact))"))
    XCTAssertTrue(source.contains("return \"flash.impact.userdata\""))
  }

  func testApplicationCanActivateAnExactSelectedTargetFromEitherRegisteredMode() throws {
    let source = try repositorySource("ArkDeckApp/Features/Flash/FlashWorkspaceView.swift")
    XCTAssertTrue(source.contains("willActivateCurrentTargetOnSubmit"))
    XCTAssertTrue(
      source.contains("status.mode == \"loader\" || status.mode == \"hdcNormal\""))
    XCTAssertTrue(source.contains("disposition: .exactBoundTarget"))
    XCTAssertTrue(source.contains("mode: observedMode"))
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
