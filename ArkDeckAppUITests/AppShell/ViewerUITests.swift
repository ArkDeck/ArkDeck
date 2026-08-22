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

  func testScreenshotNodesStayReachableWhenBoundsAreHidden() {
    let app = launchCapturedViewer()
    let region = app.descendants(matching: .any)["viewer.screenshot.node.42"]
    XCTAssertTrue(
      region.waitForExistence(timeout: 10),
      "every node with verified bounds must be addressable in the screenshot")

    // Drawing bounds is a visual preference. Turning it off must not remove a
    // node from assistive technology, which addresses elements by name.
    let toggle = app.checkBoxes["viewer.showBounds"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    toggle.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["viewer.screenshot.node.42"].exists,
      "hiding bounds must not hide the node from assistive technology")
    attach(app, name: "viewer-bounds-hidden")
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
    revealNode("42", in: app).click()

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
    attach(app, name: "viewer-raw-dump")
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

  /// Screenshots are the only way a reviewer can check the rendered result
  /// against the design without a device or a granted screen recording.
  private func attach(_ app: XCUIApplication, name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
