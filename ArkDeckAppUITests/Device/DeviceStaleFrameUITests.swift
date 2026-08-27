import XCTest

/// The stale-frame refusal, end to end on real hardware (TASK-IDC-002).
///
/// `DeviceFrameLivenessContractTests` pins the rule. This pins the wiring:
/// that the guard sits before dispatch, so a second press on a spent picture
/// never reaches the device. Nothing below reads anything off the device's
/// screen — only whether the workspace refused.
///
/// Opt-in, because it needs an adopted device and a real capture.
final class DeviceStaleFrameUITests: XCTestCase {
  private static let realDeviceEnvironmentKey = "ARKDECK_UI_TEST_DEVICE_REAL_DEVICE"

  func testASecondPressOnASpentPictureIsRefusedAndNotSent() throws {
    guard ProcessInfo.processInfo.environment[Self.realDeviceEnvironmentKey] == "1" else {
      throw XCTSkip(
        "Set \(Self.realDeviceEnvironmentKey)=1 for the real-device stale-frame gate")
    }
    // The operator observes a fresh picture before choosing a harmless point.
    // Never guess a window-centre click that could confirm an unrelated action.
    let environment = ProcessInfo.processInfo.environment
    guard let x = environment["ARKDECK_UI_TEST_DEVICE_TAP_UNIT_X"].flatMap(Double.init),
      let y = environment["ARKDECK_UI_TEST_DEVICE_TAP_UNIT_Y"].flatMap(Double.init),
      x.isFinite, y.isFinite, (0.0...1.0).contains(x), (0.0...1.0).contains(y)
    else { throw XCTSkip("Provide an observed safe picture point in DEVICE_TAP_UNIT_X/Y") }

    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle",
      "--ui-test-reset-shell-selection", "-AppleLanguages", "(en)",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

    let row = app.descendants(matching: .any)["app.navigation.device"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()

    let capture = app.buttons["device.capture"]
    XCTAssertTrue(capture.waitForExistence(timeout: 10))
    // The button is disabled until exactly one adopted device is observed, and
    // a click on a disabled button is silently nothing. Waiting for it is what
    // separates "the gate has no device" from "the refusal did not fire".
    let enabledExpectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: capture)
    guard XCTWaiter().wait(for: [enabledExpectation], timeout: 30) == .completed else {
      return XCTFail("real-device validation requires exactly one observed adopted device")
    }

    let empty = app.descendants(matching: .any)["device.screen.empty"]
    capture.click()
    XCTAssertTrue(
      empty.waitForNonExistence(timeout: 90),
      "the gate needs a real capture; without a picture there is nothing to spend")
    let badge = app.descendants(matching: .any)["device.stale.badge"]
    XCTAssertFalse(badge.exists, "a picture that just arrived is the device's current screen")

    let picture = app.images["device.screen.image"]
    XCTAssertTrue(picture.waitForExistence(timeout: 10))
    let point = picture.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    attachScreen(app, name: "Real device fresh picture")

    // First press: aimed at a picture that is still true, so it is sent.
    let logsBeforeFirst = app.descendants(matching: .any)
      .matching(identifier: "device.log.entry").count
    point.click()
    XCTAssertTrue(
      badge.waitForExistence(timeout: 90),
      "the gesture that just landed changed the screen, so the picture it was "
        + "aimed at is marked spent")
    let logsAfterFirst = app.descendants(matching: .any)
      .matching(identifier: "device.log.entry").count
    XCTAssertGreaterThan(
      logsAfterFirst, logsBeforeFirst, "the first press is sent and reports an outcome")
    let outcome = app.descendants(matching: .any)["device.log.entry"].firstMatch
    let outcomeText = outcome.label.isEmpty ? "\(outcome.value ?? "")" : outcome.label
    XCTAssertTrue(outcomeText.contains("confirmed"), outcomeText)
    attachScreen(app, name: "Real device confirmed gesture marks picture stale")

    // Second press: aimed at a picture the device has moved past.
    point.click()
    // A refusal and a successful dispatch both write exactly one row, so a
    // count alone cannot tell them apart - an earlier version of this gate
    // passed with the guard removed for exactly that reason. The refusal is
    // its own kind of row and is asserted as such.
    let refused = app.descendants(matching: .any)["device.log.refused"]
    XCTAssertTrue(
      refused.waitForExistence(timeout: 10),
      "the press must be refused rather than sent")
    // Long enough that a press which had actually been dispatched would have
    // come back with an outcome row of its own by now: a tap on this device
    // settles in well under a second.
    Thread.sleep(forTimeInterval: 8)
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "device.log.entry").count,
      logsAfterFirst,
      "nothing reached the device, so no result row ever arrives")
    XCTAssertTrue(
      badge.exists, "refusing must not clear the mark; only a fresh picture does that")

    // Recapturing is the way back.
    capture.click()
    XCTAssertTrue(
      badge.waitForNonExistence(timeout: 90),
      "a fresh picture is the only thing that restores aim")
    attachScreen(app, name: "Real device recapture clears stale state")
  }

  private func attachScreen(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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
