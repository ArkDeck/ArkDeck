import AppKit
import XCTest

extension AppShellUITests {
  // MARK: - Fixture-specific launches (locale-independent assertions)

  // A history that could not be read must never look like an empty history.
  // The exact-plan fixture is presentation-only: it bypasses the system file
  // picker so UI automation can walk every review state, but its provider has
  // no transport and the one-click Flash action remains untouched.
  /// The Settings scene, which nothing had ever opened.
  ///
  /// The update surface was the only one in the App with no fixture, so this
  /// scene had never been drawn by a test and the suite ran the real updater
  /// to decide what it would have shown. The fixture supplies only the domain
  /// state; the mapping to a status, an enabled button and a toolbar item is
  /// the App's own, so what is asserted here is the product's real behaviour.
  ///
  /// One launch walks every state through the App's own check path. The status
  /// strings are English because the state, not the language, is what had no
  /// coverage; the shell sweeps carry the per-language obligation.
  /// Every Settings module pane is reachable in the system Settings scene.
  /// This test deliberately avoids file panels, policy writes and exports.
  struct UpdateState {
    let flag: String
    let status: String
    /// Exactly which of the three actions this state offers. Naming only the
    /// enabled ones would pass for a scene that enabled all of them.
    let enabled: [String]
    let attention: String?
  }

  func assertUpdateState(
    _ state: UpdateState, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try state.flag.write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
      return
    }
    app.buttons["update.checkNow"].click()
    assertDisplayed(app.staticTexts["update.status"], equals: state.status, timeout: 10)
    for action in ["update.checkNow", "update.download", "update.reveal"] {
      XCTAssertEqual(
        app.buttons[action].isEnabled, state.enabled.contains(action),
        "\(action) under \(state.flag)", file: file, line: line)
    }
    // Only a state the user has to act on reaches the main window's toolbar.
    let toolbar = app.buttons["app.toolbar.updateAttention"]
    if let attention = state.attention {
      XCTAssertTrue(
        toolbar.waitForExistenceFast(timeout: 5), "\(state.flag) must raise attention",
        file: file, line: line)
      XCTAssertEqual(toolbar.label, attention, file: file, line: line)
    } else {
      XCTAssertFalse(
        toolbar.exists, "an idle update must not reach the toolbar", file: file, line: line)
    }
  }

  /// SwiftUI's Table lands in the NSTableView family, which XCUITest does not
  /// expose under `app.tables` here — the sidebar List surfaces as an outline
  /// for the same reason. Ask by identifier and let the type be whatever it is.
  func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  static let recoveryReferenceSize = CGSize(width: 1180, height: 783)

  /// The reference viewport must actually fit on this host's display. An
  /// interactive edge drag can only reach the visible area's boundary, so on
  /// a too-small display every window size in the test is silently capped and
  /// the failures surface later, as viewport assertions about unrelated
  /// content. A small display is a host condition, not a product one.
  static func requireDisplay(fitting size: CGSize) throws {
    guard let visible = NSScreen.screens.first?.visibleFrame else { return }
    if visible.width < size.width || visible.height < size.height {
      throw XCTSkip(
        "display visible area \(Int(visible.width))x\(Int(visible.height)) cannot present "
          + "the \(Int(size.width))x\(Int(size.height)) reference viewport")
    }
  }

  /// An interactive edge drag stops at the screen's visible boundary: the
  /// pointer cannot push a window edge past the Dock or the display edge, so
  /// a window that inherited a low or far-right position caps short of the
  /// requested size — observed as 744pt for a 783pt request after a display
  /// change — and the failure then surfaces as viewport assertions about
  /// unrelated content. Name the real limit before dragging.
  ///
  /// XCUIElement frames are top-left based on the primary display; NSScreen
  /// is bottom-left based. Like `assertDefaultWindowGeometry`, this reads the
  /// primary display, which is where these tests place their windows.
  static func assertInteractiveResizeCanReach(
    width: CGFloat? = nil, height: CGFloat? = nil, from frame: CGRect,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let primary = NSScreen.screens.first else { return }
    let visible = primary.visibleFrame
    if let width {
      let reachable = visible.maxX - frame.minX
      XCTAssertGreaterThanOrEqual(
        reachable, width - 2,
        "window left edge x=\(Int(frame.minX)) leaves \(Int(reachable))pt of visible width "
          + "for a \(Int(width))pt resize; establish the frame with --ui-test-window-frame",
        file: file, line: line)
    }
    if let height {
      let visibleBottom = primary.frame.maxY - visible.minY
      let reachable = visibleBottom - frame.minY
      XCTAssertGreaterThanOrEqual(
        reachable, height - 2,
        "window top edge y=\(Int(frame.minY)) leaves \(Int(reachable))pt above the Dock "
          + "boundary y=\(Int(visibleBottom)) for a \(Int(height))pt resize; establish the "
          + "frame with --ui-test-window-frame",
        file: file, line: line)
    }
  }

  static func resizeHistoryWindow(
    in app: XCUIApplication, to width: CGFloat,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let window = app.windows.firstMatch
    if abs(window.frame.width - width) <= 2 { return }
    assertInteractiveResizeCanReach(width: width, from: window.frame, file: file, line: line)
    let origin = window.coordinate(withNormalizedOffset: .zero)
    let edge = origin.withOffset(CGVector(dx: window.frame.width - 1, dy: 150))
    edge.click(
      forDuration: 0.1,
      thenDragTo: origin.withOffset(CGVector(dx: width - 1, dy: 150)))
    XCTAssertEqual(window.frame.width, width, accuracy: 2, file: file, line: line)
  }

  static func resizeRecoveryWindow(in app: XCUIApplication, to size: CGSize) {
    resizeHistoryWindow(in: app, to: size.width)
    let window = app.windows.firstMatch
    if abs(window.frame.height - size.height) > 2 {
      assertInteractiveResizeCanReach(height: size.height, from: window.frame)
      // Rounded window corners are outside the resize hit region. Use the
      // straight bottom edge, as resizeHistoryWindow does for the right edge.
      let origin = window.coordinate(withNormalizedOffset: .zero)
      let middle = window.frame.width / 2
      origin.withOffset(CGVector(dx: middle, dy: window.frame.height - 1))
        .click(forDuration: 0.1,
          thenDragTo: origin.withOffset(CGVector(dx: middle, dy: size.height - 1)))
    }
    XCTAssertEqual(window.frame.width, size.width, accuracy: 2)
    XCTAssertEqual(window.frame.height, size.height, accuracy: 2)
  }

  /// Lightweight visual regression for the current device detail layout. Native
  /// materials, accent, fonts and antialiasing remain system-owned, so this
  /// pins structure and keeps an artifact for review instead of comparing raw
  /// pixels across macOS versions.
  func assertDeviceDetailLayout(
    in app: XCUIApplication, adoptedDevice: XCUIElement, localeName: String,
    file: StaticString, line: UInt
  ) {
    clickCorrectingNavigationSplitAXOffset(adoptedDevice, in: app)
    let status = element("device.detail.statusSection", in: app)
    let facts = element("device.detail.factsSection", in: app)
    XCTAssertTrue(
      status.waitForExistenceFast(timeout: 10), "device status section missing",
      file: file, line: line)
    XCTAssertTrue(facts.exists, "device facts section missing", file: file, line: line)
    XCTAssertFalse(
      element("device.detail.title", in: app).exists,
      "the toolbar title must not be duplicated inside device content",
      file: file, line: line)

    let window = app.windows.firstMatch
    if window.frame.width >= 1_100 {
      XCTAssertLessThan(
        abs(status.frame.minY - facts.frame.minY), 12,
        "the 1180pt reference must align device sections side by side",
        file: file, line: line)
      XCTAssertLessThanOrEqual(
        status.frame.maxX, facts.frame.minX,
        "the wide device sections must not overlap", file: file, line: line)
    } else {
      XCTAssertFalse(
        status.frame.intersects(facts.frame),
        "the clamped layout must not overlap device sections", file: file, line: line)
    }

    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name =
      "device-detail-\(localeName)-\(Int(window.frame.width))x\(Int(window.frame.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func assertFlashLayout(
    in app: XCUIApplication, file: StaticString, line: UInt
  ) {
    writeFixtureState(
      "--ui-test-flash-plan\n--ui-test-runtime-history-empty",
      in: app, file: file, line: line)
    select("app.navigation.flash", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      element("flash.execute.submit", in: app).waitForExistenceFast(timeout: 15),
      "Flash must render the selected image and one real Flash action",
      file: file, line: line)
    let submit = element("flash.execute.submit", in: app)
    XCTAssertTrue(submit.exists, file: file, line: line)
    XCTAssertFalse(element("flash.mode", in: app).exists, file: file, line: line)

    let window = app.windows.firstMatch
    XCTAssertLessThan(
      submit.frame.width, window.frame.width * 0.5,
      "the destructive Flash action must remain content-sized instead of filling the card",
      file: file, line: line)

    let details = element("flash.workspace.details", in: app)
    XCTAssertTrue(details.exists, file: file, line: line)
    toggleFlashDetails(in: app, file: file, line: line)
    XCTAssertTrue(
      element("flash.workspace.plan.stages", in: app).waitForExistenceFast(timeout: 5),
      "Flash details must expose the four-stage Exact Plan summary",
      file: file, line: line)

    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name =
      "flash-en-\(Int(window.frame.width))x\(Int(window.frame.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

}
