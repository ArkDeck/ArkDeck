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

  func testDriverRaisesTheExactAppBeforeDeliveringPointerOrKeyboardInput() throws {
    let source = try driverSource()
    XCTAssertTrue(
      source.contains(
        "runningApplication.activate(options: [.activateAllWindows])"))
    XCTAssertTrue(source.contains("kAXFocusedWindowAttribute"))
    XCTAssertTrue(source.contains("kAXFrontmostAttribute"))
    XCTAssertTrue(source.contains("kAXRaiseAction"))
    XCTAssertTrue(source.contains("runningApplication.isActive"))
    XCTAssertTrue(source.contains("observedFrontmost == true"))
    XCTAssertFalse(source.contains("guard raised == .success"))
    XCTAssertTrue(source.contains("try activateApplication()"))
  }

  func testDriverObservesExecuteModeAndUsesPointerForTheSwiftUIFileButton() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("try driver.waitForSelected(\"flash.mode.execute\", timeout: 5)"))
    XCTAssertTrue(source.contains("try driver.chooseFileIfNeeded(options.archiveURL)"))
    XCTAssertTrue(source.contains("element(identifier: \"flash.image.value\")"))
    XCTAssertTrue(source.contains("== url.lastPathComponent"))
    XCTAssertTrue(source.contains("try click(\"flash.image.choose\")"))
    XCTAssertFalse(source.contains("try press(\"flash.image.choose\")"))
  }

  func testTargetPickerRequiresTheRequestedValueToBecomeObservable() throws {
    let source = try driverSource()
    let startMarker =
      "  func selectPickerValue(_ value: String, identifier: String) throws {"
    let endMarker = "\n  func waitForFacts("
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
    let implementation = source[start..<end]

    XCTAssertTrue(implementation.contains("kAXPopUpButtonRole"))
    XCTAssertTrue(implementation.contains("observesPickerValue"))
    XCTAssertTrue(implementation.contains("did not select"))
    XCTAssertFalse(implementation.contains("if direct == .success { return }"))
  }
}
