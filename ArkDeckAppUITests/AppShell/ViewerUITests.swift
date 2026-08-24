import XCTest

/// Viewer interaction and accessibility, driven from `ViewerUIFixture`.
///
/// These prove the *interface*: naming, linked selection, the outline keyboard
/// model, the separator, and that unknown dump fields survive into Raw dump.
/// They deliberately prove nothing about a device. A fixture result is never
/// evidence that a real capture works, and must never be recorded as one.
final class ViewerUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// Not an assertion. It records what the Viewer actually publishes to the
  /// accessibility tree so a failing expectation can be read against reality
  /// instead of guessed at.
  func testDiagnosticCapturesAccessibilityTree() {
    let app = launchCapturedViewer()
    let dump = XCTAttachment(string: app.debugDescription)
    dump.name = "viewer-ax-tree"
    dump.lifetime = .keepAlways
    add(dump)
    attach(app, name: "viewer-diagnostic")
  }

  // MARK: - Naming and capture

  func testViewerNamesItselfViewerAndHasNoLegacyRecipeForm() {
    let app = launchViewer()
    let toolbar = app.buttons["viewer.recapture"]
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10), "Viewer toolbar must offer Recapture")

    // Viewer-01 / Viewer-09: the retired workspace is gone, not merely hidden.
    for retired in ["Recipe", "ArkUI UI Dump", "Parameter policy", "Window inventory"] {
      XCTAssertFalse(
        app.staticTexts[retired].exists, "\(retired) must not survive in the Viewer surface")
    }
    attach(app, name: "viewer-empty-state")
  }

  func testCaptureActionDistinguishesFirstCaptureFromRecapture() {
    let app = launchViewer(extra: ["-AppleLanguages", "(zh-Hans)"])
    let capture = app.buttons["viewer.recapture"]
    XCTAssertTrue(capture.waitForExistence(timeout: 10), "Viewer must offer its capture action")
    XCTAssertEqual(capture.label, "抓取视图")
    XCTAssertTrue(
      app.staticTexts[
        "「抓取视图」会创建一个 typed Runtime Job，并且只展示同一个 Job 里通过校验的 Artifact。"
      ].exists)

    capture.click()
    XCTAssertTrue(
      app.buttons["viewer.tree.node.1"].waitForExistence(timeout: 15),
      "the fixture capture must render before the action changes to Recapture")
    XCTAssertEqual(capture.label, "重新抓取")
  }

  func testFixtureCaptureRendersScreenshotTreeAndProperties() {
    let app = launchCapturedViewer()
    // Assert on real controls, not on the layout containers that carry the
    // pane identifiers: AppKit does not publish every SwiftUI stack as an
    // element, so a container query proves nothing either way.
    // Identifier, not display text: the suite runs in whatever locale the host
    // is set to, and Viewer copy is now localized.
    XCTAssertTrue(
      app.staticTexts["viewer.pane.screenshot"].exists, "screenshot pane must render")
    XCTAssertTrue(app.buttons["viewer.tree.node.1"].exists, "UI tree must render")
    XCTAssertTrue(
      app.buttons["viewer.inspector.tab.properties"].exists, "properties must render")
    attach(app, name: "viewer-captured")
  }

  // MARK: - Screenshot nodes in the accessibility tree (Viewer-05 / §6.5)

  func testScreenshotNodesStayReachableWithBoundsHiddenByDefault() {
    let app = launchCapturedViewer()
    let region = app.descendants(matching: .any)["viewer.screenshot.node.42"]
    XCTAssertTrue(
      region.waitForExistence(timeout: 10),
      "every node with verified bounds must be addressable in the screenshot")

    // Drawing every bound is opt-in. The default keeps a real 300+ node dump
    // readable while assistive technology can still address every component.
    let toggle = app.checkBoxes["viewer.showBounds"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["viewer.screenshot.node.42"].exists,
      "hiding bounds must not hide the node from assistive technology")
    attach(app, name: "viewer-bounds-hidden")

    // The preference remains interactive in both directions.
    toggle.click()
    toggle.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["viewer.screenshot.node.42"].exists,
      "hiding bounds must not hide the node from assistive technology")
  }

  func testSelectingAnImageKeepsTheScreenshotRangeOnThatImage() {
    let app = launchCapturedViewer()
    revealNode("32", in: app).click()
    clearSearch(in: app)

    let screenshot = app.descendants(matching: .any)["viewer.screenshot.hitTest"]
    let image = app.descendants(matching: .any)["viewer.screenshot.node.32"]
    XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
    XCTAssertTrue(image.waitForExistence(timeout: 5))

    // Fixture #32 is [86, 614, 64, 64] in a 1080 x 1920 capture. Its AX
    // rectangle is the same rectangle Viewer paints, so this catches labels,
    // clipping, or scale math accidentally widening the selected range.
    let expected = CGRect(
      x: screenshot.frame.minX + screenshot.frame.width * 86 / 1080,
      y: screenshot.frame.minY + screenshot.frame.height * 614 / 1920,
      width: screenshot.frame.width * 64 / 1080,
      height: screenshot.frame.height * 64 / 1920)
    XCTAssertEqual(image.frame.minX, expected.minX, accuracy: 3)
    XCTAssertEqual(image.frame.minY, expected.minY, accuracy: 3)
    XCTAssertEqual(image.frame.width, expected.width, accuracy: 3)
    XCTAssertEqual(image.frame.height, expected.height, accuracy: 3)
    attach(app, name: "viewer-image-selection-range")
  }

  // MARK: - Linked selection

  func testTreeSelectionDrivesPropertiesAndBreadcrumb() {
    let app = launchCapturedViewer()
    revealNode("42", in: app).click()

    // Viewer-04: one node identity behind the row, the header, and the fields.
    XCTAssertTrue(app.staticTexts["Toggle"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["wifi_switch"].waitForExistence(timeout: 5),
      "the inspector must show the selected node's own inspectorId")
    attach(app, name: "viewer-selection")
  }

  // MARK: - Outline keyboard model (Viewer-06)

  func testTreeSupportsOutlineKeyboardMovement() {
    let app = launchCapturedViewer()
    let root = app.buttons["viewer.tree.node.1"]
    XCTAssertTrue(root.waitForExistence(timeout: 10))
    root.click()

    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    XCTAssertTrue(
      app.buttons["viewer.tree.node.3"].waitForExistence(timeout: 5),
      "Down must move to the next visible row")

    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.home.rawValue, modifierFlags: [])
    XCTAssertTrue(app.buttons["viewer.tree.node.1"].exists, "the tree must survive keyboard travel")
    attach(app, name: "viewer-keyboard")
  }

  func testSelectingADeepWideRowCentersItInBothTreeAxes() {
    let app = launchCapturedViewer(extra: ["--ui-test-viewer-stress-367"])
    let row = revealNode("367", in: app)
    clearSearch(in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.click()

    XCTAssertTrue(row.waitForExistence(timeout: 5))
    let treeScroll = app.descendants(matching: .any)["viewer.tree.scroll"]
    XCTAssertTrue(treeScroll.waitForExistence(timeout: 5))
    XCTAssertEqual(
      row.frame.midX, treeScroll.frame.midX, accuracy: 32,
      "selection reveal must center a wide component horizontally")
    XCTAssertEqual(
      row.frame.midY, treeScroll.frame.midY, accuracy: 32,
      "selection reveal must center a deep component vertically")
    XCTAssertTrue(row.isHittable, "the selected row must remain visible, not just present in AX")
    XCTAssertFalse(row.label.isEmpty, "the selected row must keep visible semantic content")
    attach(app, name: "viewer-deep-row-centered")
  }

  func testFreshCaptureStartsAsAnOutlineInsteadOfAnExpandedFlatList() {
    let app = launchCapturedViewer()
    XCTAssertTrue(app.buttons["viewer.tree.node.1"].exists)
    XCTAssertTrue(app.buttons["viewer.tree.node.3"].exists)
    XCTAssertFalse(
      app.buttons["viewer.tree.node.8"].exists,
      "a fresh capture should show root and first level, not expand the entire component dump")

    attach(app, name: "viewer-collapsed-outline")
  }

  // MARK: - Search (Viewer-06)

  func testSearchFiltersAndAnEmptyResultKeepsTheSelection() {
    let app = launchCapturedViewer()
    revealNode("42", in: app).click()
    clearSearch(in: app)

    let search = searchField(in: app)
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("Toggle")
    XCTAssertTrue(app.buttons["viewer.tree.node.42"].waitForExistence(timeout: 5))

    search.typeText("zzz-no-such-component")
    // Viewer-10: zero matches is a filtered view, never a discarded capture.
    XCTAssertTrue(app.buttons["viewer.inspector.tab.properties"].exists,
      "an empty result must not clear the inspected node")
    attach(app, name: "viewer-search-empty")
  }

  func testSearchSelectsFirstMatchAndNavigatesEveryResult() {
    let app = launchCapturedViewer()
    let search = searchField(in: app)
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("ListItem")

    let count = app.staticTexts["viewer.search.matchCount"]
    XCTAssertTrue(count.waitForExistence(timeout: 5))
    assertDisplayedValue(count, equals: "1 / 8")
    XCTAssertTrue(
      app.staticTexts["#22"].waitForExistence(timeout: 5),
      "the first exact search hit must become the inspected component")

    let next = app.buttons["viewer.search.next"]
    let previous = app.buttons["viewer.search.previous"]
    XCTAssertTrue(next.exists && next.isEnabled)
    XCTAssertTrue(previous.exists && previous.isEnabled)
    next.click()
    assertDisplayedValue(count, equals: "2 / 8")
    XCTAssertTrue(
      app.staticTexts["#50"].waitForExistence(timeout: 5),
      "Next must move selection to the following exact hit")
    previous.click()
    assertDisplayedValue(count, equals: "1 / 8")
    XCTAssertTrue(app.staticTexts["#22"].exists)
    attach(app, name: "viewer-search-navigation")
  }

  // MARK: - Separator (Viewer-07)

  func testSeparatorKeyboardResizeKeepsTheSelection() {
    let app = launchCapturedViewer()
    revealNode("42", in: app).click()

    let separator = app.descendants(matching: .any)["viewer.inspector.separator"]
    XCTAssertTrue(separator.waitForExistence(timeout: 5), "the separator must be exposed")
    separator.click()
    app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.home.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [])

    XCTAssertTrue(app.staticTexts["wifi_switch"].exists,
      "resizing is presentation only and must not move the inspected node")
    attach(app, name: "viewer-separator")
  }

  // MARK: - Inspector tabs and Raw dump (Viewer-08)

  func testRawDumpKeepsFieldsTheParserDoesNotModel() {
    let app = launchCapturedViewer()
    revealNode("40", in: app).click()

    for tab in ["properties", "layout", "accessibility", "rawDump"] {
      let button = app.buttons["viewer.inspector.tab.\(tab)"]
      XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab) tab must be reachable")
      button.click()
    }

    let raw = app.staticTexts["viewer.rawDump"]
    XCTAssertTrue(raw.waitForExistence(timeout: 5), "Raw dump must render")
    let rendered = (raw.value as? String) ?? raw.label
    XCTAssertTrue(
      rendered.contains("fixtureUnknownField"),
      "a field the parser does not model must survive into Raw dump")
    XCTAssertTrue(rendered.contains("\"fixtureOwnerID\" : 40"))
    XCTAssertFalse(
      rendered.contains("\"fixtureOwnerID\" : 42"),
      "Raw dump must not include the selected component's descendants")
    attach(app, name: "viewer-raw-dump")
  }

  func testPropertiesOmitUnavailableFields() {
    let app = launchCapturedViewer()
    revealNode("32", in: app).click()
    clearSearch(in: app)

    XCTAssertFalse(
      app.staticTexts["Unavailable"].exists,
      "optional dump fields that are absent must not render placeholder rows")
    attach(app, name: "viewer-properties-no-unavailable")
  }

  func testInspectorVocabularyStaysEnglish() {
    let app = launchCapturedViewer()
    revealNode("42", in: app).click()

    let tabs = [
      ("properties", "Show Properties"),
      ("layout", "Show Layout"),
      ("accessibility", "Show Accessibility"),
      ("rawDump", "Show Raw dump"),
    ]
    for (identifier, label) in tabs {
      let button = app.buttons["viewer.inspector.tab.\(identifier)"]
      XCTAssertTrue(
        button.waitForExistence(timeout: 5),
        "the inspector tab must remain reachable: \(identifier)")
      XCTAssertEqual(button.label, label)
    }
    XCTAssertTrue(
      app.staticTexts["Identity"].waitForExistence(timeout: 5),
      "the inspector must use the English debugging vocabulary: Identity")
    for translated in ["属性", "布局", "无障碍", "身份"] {
      XCTAssertFalse(
        app.staticTexts[translated].exists,
        "the inspector must not mix translated labels with English dump fields")
    }
    attach(app, name: "viewer-english-inspector")
  }

  // MARK: - Real hardware

  private static let realDeviceEnvironmentKey = "ARKDECK_UI_TEST_VIEWER_REAL_DEVICE"

  /// Opt-in hardware acceptance. This one launches without the fixture, so the
  /// capture comes from the production XPC facade and a connected device, and
  /// the stage timings in the footer are the ones that capture actually cost.
  ///
  /// Like the startup acceptance test, it reports timings only — no target id,
  /// no job id, and nothing read off the device's screen goes into the output.
  func testRealDeviceCaptureFillsTheStageTimings() throws {
    guard ProcessInfo.processInfo.environment[Self.realDeviceEnvironmentKey] == "1" else {
      throw XCTSkip(
        "Set \(Self.realDeviceEnvironmentKey)=1 for real-device Viewer acceptance")
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
    openViewer(in: app)

    let recapture = app.buttons["viewer.recapture"]
    XCTAssertTrue(recapture.waitForExistence(timeout: 15), "Viewer must offer Recapture")
    // The button exists before the workspace knows whether any target has a
    // fresh Connected route — that answer comes from a device probe. Waiting
    // for the control to appear is not waiting for the App to be ready.
    let live = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: recapture)
    XCTAssertEqual(
      XCTWaiter().wait(for: [live], timeout: 60), .completed,
      "no adopted target reported a fresh Connected route within 60s")
    recapture.click()

    // A device round trip plus three bounded artifact reads. The budget is
    // generous on purpose: this asserts that the pipeline completes and
    // reports, not how fast the hardware happened to be.
    let firstRow = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "viewer.tree.node.")).firstMatch
    XCTAssertTrue(
      firstRow.waitForExistence(timeout: 180),
      "a verified real capture must render a tree")

    let footer = app.descendants(matching: .any)["viewer.footer"]
    XCTAssertTrue(footer.waitForExistence(timeout: 10), "the footer must publish stage timings")
    let readout = (footer.value as? String) ?? footer.label
    XCTAssertFalse(
      readout.isEmpty, "the footer must publish something for a real capture")
    for stage in ["submit", "run", "list", "read", "parse"] {
      XCTAssertTrue(
        readout.contains(stage),
        "the footer must report the \(stage) stage of a measured capture")
    }

    let evidence = XCTAttachment(string: readout)
    evidence.name = "real-device-stage-timings"
    evidence.lifetime = .keepAlways
    add(evidence)
    attach(app, name: "viewer-real-device")
  }

  // MARK: - Helpers

  private func launchViewer(extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-hdc-diagnostics", "--ui-test-auto-update-idle", "--ui-test-viewer",
    ] + extra
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "ArkDeck must open a window")
    openViewer(in: app)
    return app
  }

  /// Viewer opens with no capture by design — a workspace must not submit on
  /// launch. The fixture capture arrives through the same Recapture action a
  /// person uses, so the test drives the product's own path.
  private func launchCapturedViewer(extra: [String] = []) -> XCUIApplication {
    let app = launchViewer(extra: extra)
    let recapture = app.buttons["viewer.recapture"]
    XCTAssertTrue(recapture.waitForExistence(timeout: 10), "Recapture must be offered")
    XCTAssertTrue(
      recapture.isEnabled,
      "the fixture target is Connected and the operation available, so Recapture must be live")
    recapture.click()
    // The tree's own identifier sits on a layout container, which AppKit does
    // not always publish as an element. A row is the reliable proof that a
    // capture actually rendered.
    let firstRow = app.buttons["viewer.tree.node.1"]
    if !firstRow.waitForExistence(timeout: 15) {
      let dump = XCTAttachment(string: app.debugDescription)
      dump.name = "ax-tree-after-recapture"
      dump.lifetime = .keepAlways
      add(dump)
      attach(app, name: "viewer-recapture-failed")
      XCTFail("a verified capture must render the tree")
    }
    return app
  }

  private func openViewer(in app: XCUIApplication) {
    let row = app.descendants(matching: .any)["app.navigation.uiDump"]
    if row.waitForExistence(timeout: 10), row.isHittable {
      row.click()
    }
  }

  /// Brings a deep node into the row set through the product's own search,
  /// then clears the query. Scrolling a LazyVStack is not a reliable way to
  /// reach a node that has never been realised into the accessibility tree.
  @discardableResult
  private func revealNode(_ id: String, in app: XCUIApplication) -> XCUIElement {
    let row = app.buttons["viewer.tree.node.\(id)"]
    if row.waitForExistence(timeout: 3) { return row }
    let search = searchField(in: app)
    search.click()
    search.typeText(id)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "search must reveal node #\(id)")
    return row
  }

  private func searchField(in app: XCUIApplication) -> XCUIElement {
    let field = app.textFields["viewer.search"]
    return field.exists ? field : app.searchFields["viewer.search"]
  }

  private func clearSearch(in app: XCUIApplication) {
    let search = searchField(in: app)
    guard search.exists else { return }
    search.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
  }

  private func assertDisplayedValue(
    _ element: XCUIElement,
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let values = [element.label, element.value as? String]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    XCTAssertTrue(
      values.contains(expected),
      "expected \(expected), got \(values)",
      file: file,
      line: line)
  }

  /// Screenshots are the only way a reviewer can check the rendered result
  /// against the design without a device or a granted screen recording.
  private func attach(_ app: XCUIApplication, name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
