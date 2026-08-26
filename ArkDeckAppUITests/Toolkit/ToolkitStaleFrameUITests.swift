import XCTest

/// The stale-frame refusal, end to end on real hardware (TASK-IDC-002).
///
/// `ToolkitFrameLivenessContractTests` pins the rule. This pins the wiring:
/// that the guard sits before dispatch, so a second press on a spent picture
/// never reaches the device. Nothing below reads anything off the device's
/// screen — only whether the workspace refused.
///
/// Opt-in, because it needs an adopted device and a real capture.
final class ToolkitStaleFrameUITests: XCTestCase {
  private static let realDeviceEnvironmentKey = "ARKDECK_UI_TEST_TOOLKIT_REAL_DEVICE"

  func testASecondPressOnASpentPictureIsRefusedAndNotSent() throws {
    guard ProcessInfo.processInfo.environment[Self.realDeviceEnvironmentKey] == "1" else {
      throw XCTSkip(
        "Set \(Self.realDeviceEnvironmentKey)=1 for the real-device stale-frame gate")
    }

    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

    let row = app.descendants(matching: .any)["app.navigation.toolkit"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()

    let capture = app.buttons["toolkit.capture"]
    XCTAssertTrue(capture.waitForExistence(timeout: 10))
    // The button is disabled until exactly one adopted device is observed, and
    // a click on a disabled button is silently nothing. Waiting for it is what
    // separates "the gate has no device" from "the refusal did not fire".
    let enabledExpectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: capture)
    guard XCTWaiter().wait(for: [enabledExpectation], timeout: 30) == .completed else {
      throw XCTSkip("no single adopted device is observed, so there is nothing to capture")
    }

    let empty = app.descendants(matching: .any)["toolkit.screen.empty"]
    capture.click()
    XCTAssertTrue(
      empty.waitForNonExistence(timeout: 90),
      "the gate needs a real capture; without a picture there is nothing to spend")
    let badge = app.descendants(matching: .any)["toolkit.stale.badge"]
    XCTAssertFalse(badge.exists, "a picture that just arrived is the device's current screen")

    // The gesture surface is a transparent shape and is not an accessibility
    // element, so the press is aimed by coordinate. The picture sits between
    // the capture button above it and the footer below.
    let point = try pictureCenter(in: app)

    // First press: aimed at a picture that is still true, so it is sent.
    let logsBeforeFirst = app.descendants(matching: .any)
      .matching(identifier: "toolkit.log.entry").count
    point.click()
    XCTAssertTrue(
      badge.waitForExistence(timeout: 90),
      "the gesture that just landed changed the screen, so the picture it was "
        + "aimed at is marked spent")
    let logsAfterFirst = app.descendants(matching: .any)
      .matching(identifier: "toolkit.log.entry").count
    XCTAssertGreaterThan(
      logsAfterFirst, logsBeforeFirst, "the first press is sent and reports an outcome")

    // Second press: aimed at a picture the device has moved past.
    point.click()
    // A refusal and a successful dispatch both write exactly one row, so a
    // count alone cannot tell them apart - an earlier version of this gate
    // passed with the guard removed for exactly that reason. The refusal is
    // its own kind of row and is asserted as such.
    let refused = app.descendants(matching: .any)["toolkit.log.refused"]
    XCTAssertTrue(
      refused.waitForExistence(timeout: 10),
      "the press must be refused rather than sent")
    // Long enough that a press which had actually been dispatched would have
    // come back with an outcome row of its own by now: a tap on this device
    // settles in well under a second.
    Thread.sleep(forTimeInterval: 8)
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "toolkit.log.entry").count,
      logsAfterFirst,
      "nothing reached the device, so no result row ever arrives")
    XCTAssertTrue(
      badge.exists, "refusing must not clear the mark; only a fresh picture does that")

    // Recapturing is the way back.
    capture.click()
    XCTAssertTrue(
      badge.waitForNonExistence(timeout: 90),
      "a fresh picture is the only thing that restores aim")
  }

  /// The centre of the picture, derived from the two elements that bracket it
  /// rather than from a guessed fraction of the window.
  private func pictureCenter(in app: XCUIApplication) throws -> XCUICoordinate {
    let capture = app.buttons["toolkit.capture"]
    let footer = app.descendants(matching: .any)["toolkit.frame.age"]
    XCTAssertTrue(footer.waitForExistence(timeout: 10))
    let window = app.windows.firstMatch
    let above = capture.frame.maxY
    let below = footer.frame.minY
    let left = footer.frame.minX
    let right = capture.frame.maxX
    guard below > above, right > left else {
      throw XCTSkip("the picture pane has no room between the header and the footer")
    }
    return window.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: (left + right) / 2 - window.frame.minX,
          dy: (above + below) / 2 - window.frame.minY))
  }
}

extension XCUIElement {
  fileprivate func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !exists { return true }
      Thread.sleep(forTimeInterval: 0.3)
    }
    return !exists
  }
}
