import AppKit
import XCTest

/// Viewer interaction and accessibility, driven from `ViewerUIFixture`.
///
/// These prove the *interface*: naming, linked selection, the outline keyboard
/// model, the separator, and that unknown dump fields survive into Raw dump.
/// They deliberately prove nothing about a device. A fixture result is never
/// evidence that a real capture works, and must never be recorded as one.
///
/// Every fixture assertion used to cost its own launch, so a run relaunched
/// the app once per test — the single most expensive thing a macOS UI test
/// does. Recapture is the product's own reset action and returns the Viewer
/// to exactly what a fresh capture presents, so one launched instance walks
/// every fixture phase below, the way the HDC sweep and the AppShell History
/// session already do. What still launches separately does so for a reason
/// that is stated where it happens.
@MainActor
final class ViewerUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  /// One presentation-only App instance, with named activities instead of a
  /// fresh process per assertion group. Ordering inside the session is part
  /// of the design: phases that leave the inspector on another tab run after
  /// every phase that reads the default Properties tab, and the separator
  /// phase runs last because moving the separator is the one thing Recapture
  /// does not undo.
  func testViewerContinuousFixtureSession() throws {
    let app = launchViewer()
    let processes = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.arkdeck.desktop")
    XCTAssertEqual(processes.count, 1, "the session must have exactly one App process")
    let processID = try XCTUnwrap(processes.first?.processIdentifier)

    // Before any capture: the workspace names itself and the retired
    // surfaces are gone, not merely hidden (Viewer-01 / Viewer-09).
    runViewerPhase("Named Viewer without legacy surfaces", in: app, processID: processID) {
      let toolbar = app.buttons["viewer.recapture"]
      XCTAssertTrue(
        toolbar.waitForExistenceFast(timeout: 10), "Viewer toolbar must offer Recapture")
      for retired in ["Recipe", "ArkUI UI Dump", "Parameter policy", "Window inventory"] {
        XCTAssertFalse(
          app.staticTexts[retired].exists, "\(retired) must not survive in the Viewer surface")
      }
      attach(app, name: "viewer-empty-state")
    }

    // Viewer opens with no capture by design — a workspace must not submit on
    // launch. The fixture capture arrives through the same Recapture action a
    // person uses, so the session drives the product's own path.
    runViewerPhase("First capture renders the tree", in: app, processID: processID) {
      freshCapture(in: app)
    }

    // Not an assertion. It records what the Viewer actually publishes to the
    // accessibility tree so a failing expectation can be read against reality
    // instead of guessed at.
    runViewerPhase("Diagnostic AX tree", in: app, processID: processID) {
      let dump = XCTAttachment(string: app.debugDescription)
      dump.name = "viewer-ax-tree"
      dump.lifetime = .keepAlways
      add(dump)
      attach(app, name: "viewer-diagnostic")
    }

    runViewerPhase("Captured panes render", in: app, processID: processID) {
      // Assert on real controls, not on the layout containers that carry the
      // pane identifiers: AppKit does not publish every SwiftUI stack as an
      // element, so a container query proves nothing either way.
      // Identifier, not display text: the suite runs in whatever locale the
      // host is set to, and Viewer copy is now localized.
      XCTAssertTrue(
        app.staticTexts["viewer.pane.screenshot"].exists, "screenshot pane must render")
      XCTAssertTrue(app.buttons["viewer.tree.node.1"].exists, "UI tree must render")
      XCTAssertTrue(
        app.buttons["viewer.inspector.tab.properties"].exists, "properties must render")
      attach(app, name: "viewer-captured")
    }

    runViewerPhase("Fresh capture starts as an outline", in: app, processID: processID) {
      XCTAssertTrue(app.buttons["viewer.tree.node.1"].exists)
      XCTAssertTrue(app.buttons["viewer.tree.node.3"].exists)
      XCTAssertFalse(
        app.buttons["viewer.tree.node.8"].exists,
        "a fresh capture should show root and first level, not expand the entire component dump")
      attach(app, name: "viewer-collapsed-outline")
    }

    // Screenshot nodes in the accessibility tree (Viewer-05 / §6.5).
    runViewerPhase("Screenshot nodes reachable with bounds hidden", in: app, processID: processID) {
      freshCapture(in: app)
      let region = app.descendants(matching: .any)["viewer.screenshot.node.42"]
      XCTAssertTrue(
        region.waitForExistenceFast(timeout: 10),
        "every node with verified bounds must be addressable in the screenshot")

      // Drawing every bound is opt-in. The default keeps a real 300+ node dump
      // readable while assistive technology can still address every component.
      let toggle = app.checkBoxes["viewer.showBounds"]
      XCTAssertTrue(toggle.waitForExistenceFast(timeout: 5))
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

    runViewerPhase("Image selection keeps the screenshot range", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("32", in: app).click()
      clearSearch(in: app)

      let screenshot = app.descendants(matching: .any)["viewer.screenshot.hitTest"]
      let image = app.descendants(matching: .any)["viewer.screenshot.node.32"]
      XCTAssertTrue(screenshot.waitForExistenceFast(timeout: 5))
      XCTAssertTrue(image.waitForExistenceFast(timeout: 5))

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

    // Linked selection.
    runViewerPhase("Tree selection drives properties and breadcrumb", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("42", in: app).click()

      // Viewer-04: one node identity behind the row, the header, and the fields.
      XCTAssertTrue(app.staticTexts["Toggle"].waitForExistenceFast(timeout: 5))
      XCTAssertTrue(
        app.staticTexts["wifi_switch"].waitForExistenceFast(timeout: 5),
        "the inspector must show the selected node's own inspectorId")
      attach(app, name: "viewer-selection")
    }

    // Outline keyboard model (Viewer-06).
    runViewerPhase("Outline keyboard movement", in: app, processID: processID) {
      freshCapture(in: app)
      let root = app.buttons["viewer.tree.node.1"]
      XCTAssertTrue(root.waitForExistenceFast(timeout: 10))
      root.click()

      app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
      XCTAssertTrue(
        app.buttons["viewer.tree.node.3"].waitForExistenceFast(timeout: 5),
        "Down must move to the next visible row")

      app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
      app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
      app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [])
      app.typeKey(XCUIKeyboardKey.home.rawValue, modifierFlags: [])
      XCTAssertTrue(
        app.buttons["viewer.tree.node.1"].exists, "the tree must survive keyboard travel")
      attach(app, name: "viewer-keyboard")
    }

    // Search (Viewer-06).
    runViewerPhase("Search filters and an empty result keeps the selection", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("42", in: app).click()
      clearSearch(in: app)

      let search = searchField(in: app)
      XCTAssertTrue(search.waitForExistenceFast(timeout: 5))
      search.click()
      search.typeText("Toggle")
      XCTAssertTrue(app.buttons["viewer.tree.node.42"].waitForExistenceFast(timeout: 5))

      search.typeText("zzz-no-such-component")
      // Viewer-10: zero matches is a filtered view, never a discarded capture.
      XCTAssertTrue(
        app.buttons["viewer.inspector.tab.properties"].exists,
        "an empty result must not clear the inspected node")
      attach(app, name: "viewer-search-empty")
    }

    runViewerPhase("Search selects the first match and navigates every result", in: app, processID: processID) {
      freshCapture(in: app)
      let search = searchField(in: app)
      XCTAssertTrue(search.waitForExistenceFast(timeout: 5))
      search.click()
      search.typeText("ListItem")

      let count = app.staticTexts["viewer.search.matchCount"]
      XCTAssertTrue(count.waitForExistenceFast(timeout: 5))
      assertDisplayedValue(count, equals: "1 / 8")
      XCTAssertTrue(
        app.staticTexts["#22"].waitForExistenceFast(timeout: 5),
        "the first exact search hit must become the inspected component")

      let next = app.buttons["viewer.search.next"]
      let previous = app.buttons["viewer.search.previous"]
      XCTAssertTrue(next.exists && next.isEnabled)
      XCTAssertTrue(previous.exists && previous.isEnabled)
      next.click()
      assertDisplayedValue(count, equals: "2 / 8")
      XCTAssertTrue(
        app.staticTexts["#50"].waitForExistenceFast(timeout: 5),
        "Next must move selection to the following exact hit")
      previous.click()
      assertDisplayedValue(count, equals: "1 / 8")
      XCTAssertTrue(app.staticTexts["#22"].exists)
      attach(app, name: "viewer-search-navigation")
    }

    runViewerPhase("Properties omit unavailable fields", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("32", in: app).click()
      clearSearch(in: app)

      XCTAssertFalse(
        app.staticTexts["Unavailable"].exists,
        "optional dump fields that are absent must not render placeholder rows")
      attach(app, name: "viewer-properties-no-unavailable")
    }

    // Reads the default Properties tab, so it runs before any phase that
    // leaves the inspector on another tab: Recapture rebuilds the tree but
    // deliberately keeps the person's inspector tab choice.
    runViewerPhase("Inspector vocabulary stays English", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("42", in: app).click()

      let tabs = [
        ("properties", "Show Properties"),
        ("layout", "Show Layout"),
        ("accessibility", "Show Accessibility"),
        ("rawDump", "Show Raw dump"),
        ("advancedDump", "Show Advanced Dump"),
      ]
      for (identifier, label) in tabs {
        let button = app.buttons["viewer.inspector.tab.\(identifier)"]
        XCTAssertTrue(
          button.waitForExistenceFast(timeout: 5),
          "the inspector tab must remain reachable: \(identifier)")
        XCTAssertEqual(button.label, label)
      }
      XCTAssertTrue(
        app.staticTexts["Identity"].waitForExistenceFast(timeout: 5),
        "the inspector must use the English debugging vocabulary: Identity")
      for translated in ["属性", "布局", "无障碍", "身份"] {
        XCTAssertFalse(
          app.staticTexts[translated].exists,
          "the inspector must not mix translated labels with English dump fields")
      }
      attach(app, name: "viewer-english-inspector")
    }

    // Inspector tabs and Raw dump (Viewer-08). These phases leave the
    // inspector on a non-default tab, so every Properties-tab reader above
    // has already run.
    runViewerPhase("Raw dump keeps fields the parser does not model", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("40", in: app).click()

      for tab in ["properties", "layout", "accessibility", "rawDump", "advancedDump"] {
        let button = app.buttons["viewer.inspector.tab.\(tab)"]
        XCTAssertTrue(button.waitForExistenceFast(timeout: 5), "\(tab) tab must be reachable")
        button.click()
      }

      // The loop above proves every tab is reachable and leaves the last one
      // selected, so Raw dump is selected again before its content is read.
      // Relying on the walk to end there made this assertion depend on Raw dump
      // being last in the list, which stopped being true when the advanced dump
      // inspector was added after it.
      app.buttons["viewer.inspector.tab.rawDump"].click()

      let raw = app.staticTexts["viewer.rawDump"]
      XCTAssertTrue(raw.waitForExistenceFast(timeout: 5), "Raw dump must render")
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

    runViewerPhase("Advanced dump uses key colon value rows", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("40", in: app).click()

      let tab = app.buttons["viewer.inspector.tab.advancedDump"]
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5), "Advanced Dump tab must be reachable")
      tab.click()

      let advanced = app.descendants(matching: .any)[
        "viewer.advancedDump.field.componentId"]
      XCTAssertTrue(advanced.waitForExistenceFast(timeout: 5), "Advanced Dump must render")
      XCTAssertEqual(advanced.label, "componentId : 40")

      let owner = app.descendants(matching: .any)["viewer.advancedDump.field.hostWindowId"]
      XCTAssertEqual(owner.label, "hostWindowId : 60")
      attach(app, name: "viewer-advanced-dump")
    }

    runViewerPhase("Advanced dump search matches fields and values", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("40", in: app).click()

      let tab = app.buttons["viewer.inspector.tab.advancedDump"]
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5))
      tab.click()

      let component = app.descendants(matching: .any)[
        "viewer.advancedDump.field.componentId"]
      let owner = app.descendants(matching: .any)[
        "viewer.advancedDump.field.hostWindowId"]
      let source = app.descendants(matching: .any)[
        "viewer.advancedDump.field.source"]
      let lastFixtureField = app.descendants(matching: .any)[
        "viewer.advancedDump.field.fixtureField252"]
      let firstFixtureField = app.descendants(matching: .any)[
        "viewer.advancedDump.field.fixtureField000"]
      XCTAssertTrue(component.waitForExistenceFast(timeout: 5))

      let search = app.textFields["viewer.advancedDump.search"]
      XCTAssertTrue(
        search.waitForExistenceFast(timeout: 5), "Advanced Dump must expose field search")
      app.typeKey("f", modifierFlags: .command)
      app.typeText("COMPONENTID")

      XCTAssertTrue(
        component.waitForExistenceFast(timeout: 5), "field names must match case-insensitively")
      XCTAssertTrue(owner.waitForNonExistenceFast(timeout: 5))
      let count = app.staticTexts["viewer.advancedDump.search.matchCount"]
      XCTAssertTrue(count.waitForExistenceFast(timeout: 5))
      assertDisplayedValue(count, equals: "1 / 256")

      app.typeKey("a", modifierFlags: .command)
      let inputStartedAt = Date()
      app.typeText("fixtureField252")
      XCTAssertLessThan(
        Date().timeIntervalSince(inputStartedAt), 2,
        "typing a field query must not block on rebuilding hundreds of rows")
      XCTAssertTrue(lastFixtureField.waitForExistenceFast(timeout: 5))
      assertDisplayedValue(count, equals: "1 / 256")

      // Deleting a narrow query expands the result set back to hundreds of
      // rows. This is the path that regressed when the list was eager and the
      // search query lived in the workspace-wide observable model.
      let deletionStartedAt = Date()
      for _ in 0..<3 {
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
      }
      XCTAssertLessThan(
        Date().timeIntervalSince(deletionStartedAt), 2,
        "deleting into a broad query must not eagerly rebuild every result row")
      XCTAssertTrue(firstFixtureField.waitForExistenceFast(timeout: 5))
      assertDisplayedValue(count, equals: "253 / 256")

      app.typeKey("a", modifierFlags: .command)
      app.typeText("componentdetail")
      XCTAssertTrue(
        source.waitForExistenceFast(timeout: 5), "field values must be searchable")
      XCTAssertTrue(component.waitForNonExistenceFast(timeout: 5))

      app.typeKey("a", modifierFlags: .command)
      app.typeText("no-such-field-or-value")
      XCTAssertTrue(
        app.staticTexts["viewer.advancedDump.search.noResults"].waitForExistenceFast(timeout: 5),
        "a zero-match query must show an explicit empty result")

      app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
      XCTAssertTrue(
        component.waitForExistenceFast(timeout: 5), "Escape must clear the local filter")
      XCTAssertTrue(owner.exists && source.exists)
      attach(app, name: "viewer-advanced-dump-search")
    }

    // Separator (Viewer-07). Last on purpose: moving the separator is the one
    // workspace change Recapture does not undo.
    runViewerPhase("Separator keyboard resize keeps the selection", in: app, processID: processID) {
      freshCapture(in: app)
      revealNode("42", in: app).click()
      // The proof of an unmoved selection is its inspectorId on the
      // Properties tab; the dump phases left another tab selected.
      app.buttons["viewer.inspector.tab.properties"].click()

      let separator = app.descendants(matching: .any)["viewer.inspector.separator"]
      XCTAssertTrue(
        separator.waitForExistenceFast(timeout: 5), "the separator must be exposed")
      separator.click()
      app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
      app.typeKey(XCUIKeyboardKey.home.rawValue, modifierFlags: [])
      app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [])

      XCTAssertTrue(
        app.staticTexts["wifi_switch"].exists,
        "resizing is presentation only and must not move the inspected node")
      attach(app, name: "viewer-separator")
    }
  }

  // MARK: - Launches that stay separate, and why

  /// This one cannot join the session: it asserts the *first* capture action
  /// label against the recapture label, which only an instance that has never
  /// captured can show, and it pins the second locale's strings.
  func testCaptureActionDistinguishesFirstCaptureFromRecapture() {
    let app = launchViewer(extra: ["-AppleLanguages", "(zh-Hans)"])
    let capture = app.buttons["viewer.recapture"]
    XCTAssertTrue(
      capture.waitForExistenceFast(timeout: 10), "Viewer must offer its capture action")
    XCTAssertEqual(capture.label, "抓取视图")
    XCTAssertTrue(
      app.staticTexts[
        "「抓取视图」会创建一个 typed Runtime Job，并且只展示同一个 Job 里通过校验的 Artifact。"
      ].exists)

    capture.click()
    XCTAssertTrue(
      app.buttons["viewer.tree.node.1"].waitForExistenceFast(timeout: 15),
      "the fixture capture must render before the action changes to Recapture")
    XCTAssertEqual(capture.label, "重新抓取")
  }

  /// A different fixture, so a different launch: the 367-node stress dump is
  /// selected by its own launch argument.
  ///
  /// The frame is not the product default on purpose. At 1180x783 the tree
  /// viewport is ~388pt and the reveal's yielded second scroll used to lose
  /// deterministically to the id request, resting the row at the viewport's
  /// lower edge (539 vs 361 on main, identical across four runs). The reveal
  /// now converges through the scroll geometry callback, and this test pins
  /// it at exactly the geometry that used to defeat it.
  func testSelectingADeepWideRowCentersItInBothTreeAxes() {
    let app = launchCapturedViewer(
      extra: ["--ui-test-viewer-stress-367"],
      windowSize: CGSize(width: 1180, height: 783))
    let row = revealNode("367", in: app)
    clearSearch(in: app)
    XCTAssertTrue(row.waitForExistenceFast(timeout: 5))
    row.click()

    XCTAssertTrue(row.waitForExistenceFast(timeout: 5))
    let treeScroll = app.descendants(matching: .any)["viewer.tree.scroll"]
    XCTAssertTrue(treeScroll.waitForExistenceFast(timeout: 5))
    // The reveal resolves over more than one scroll transaction, so give the
    // scroll a bounded window to finish instead of measuring it in flight.
    // This tolerates only timing: if the reveal never centers the row, the
    // wait expires and the assertions below fail with the real geometry.
    let centered = NSPredicate { _, _ in
      abs(row.frame.midX - treeScroll.frame.midX) <= 32
        && abs(row.frame.midY - treeScroll.frame.midY) <= 32
    }
    _ = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: centered, object: nil)], timeout: 5)
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

  // MARK: - Session helpers

  /// The AppShell History session's continuity contract, applied here: a
  /// phase must run in the very App process the session launched, so a crash
  /// or accidental relaunch cannot silently pass as a fresh instance.
  private func runViewerPhase(
    _ name: String, in app: XCUIApplication, processID: pid_t, body: () -> Void
  ) {
    XCTContext.runActivity(named: name) { _ in
      let before = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").map(\.processIdentifier)
      guard app.state != .notRunning, before == [processID] else {
        XCTFail("App process changed before \(name): expected \(processID), got \(before)")
        return
      }
      app.activate()
      body()
      let after = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").map(\.processIdentifier)
      XCTAssertEqual(after, [processID], "a phase must not relaunch the App")
    }
  }

  /// Returns the Viewer to what a fresh capture presents: the collapsed
  /// outline with no search filter. Recapture rebuilds the tree, so a deep
  /// row a previous phase revealed disappearing again is the deterministic
  /// probe that the new capture rendered — the same fact the outline phase
  /// asserts explicitly.
  private func freshCapture(in app: XCUIApplication) {
    clearSearch(in: app)
    let recapture = app.buttons["viewer.recapture"]
    XCTAssertTrue(recapture.waitForExistenceFast(timeout: 10), "Recapture must be offered")
    XCTAssertTrue(
      recapture.isEnabled,
      "the fixture target is Connected and the operation available, so Recapture must be live")
    recapture.click()
    // The tree's own identifier sits on a layout container, which AppKit does
    // not always publish as an element. A row is the reliable proof that a
    // capture actually rendered.
    let firstRow = app.buttons["viewer.tree.node.1"]
    if !firstRow.waitForExistenceFast(timeout: 15) {
      let dump = XCTAttachment(string: app.debugDescription)
      dump.name = "ax-tree-after-recapture"
      dump.lifetime = .keepAlways
      add(dump)
      attach(app, name: "viewer-recapture-failed")
      XCTFail("a verified capture must render the tree")
    }
    XCTAssertTrue(
      app.buttons["viewer.tree.node.8"].waitForNonExistenceFast(timeout: 5),
      "a fresh capture presents the collapsed outline, not the previous expansion")
  }

  // MARK: - Helpers

  /// The product's default window size, established explicitly. The frame
  /// autosave survives `-ApplePersistenceIgnoreState`, so without this every
  /// launch opens at whatever frame the previous test — possibly a different
  /// suite resizing to its own reference viewport — left behind, and the
  /// centering geometry these tests assert would depend on desktop history.
  private static let establishedWindowSize = CGSize(width: 1180, height: 760)

  private func launchViewer(
    extra: [String] = [], windowSize: CGSize = ViewerUITests.establishedWindowSize
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-hdc-diagnostics", "--ui-test-auto-update-idle", "--ui-test-viewer",
      // Scene storage survives `-ApplePersistenceIgnoreState`, so without this
      // the window opens on whichever workspace the previous run left behind.
      "--ui-test-reset-shell-selection",
      "--ui-test-window-frame=\(Int(windowSize.width))x\(Int(windowSize.height))",
    ] + extra
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    app.activate()
    // A relaunch can restore a session that had no open window, and macOS then
    // gives the app back exactly that: a running process with nothing on
    // screen. The App's own New Window command is the recovery, and it is the
    // same one AppShellUITests uses — a launch is not a window.
    if !app.windows.firstMatch.waitForExistenceFast(timeout: 5) {
      app.typeKey("n", modifierFlags: .command)
      XCTAssertTrue(
        app.windows.firstMatch.waitForExistenceFast(timeout: 10),
        "ArkDeck must open a window, and did not reopen one either")
    }
    XCTAssertTrue(
      app.windows.firstMatch.waitForFrameSize(windowSize, timeout: 5),
      "the launch must establish the declared \(windowSize) frame, "
        + "got \(app.windows.firstMatch.frame)")
    openViewer(in: app)
    return app
  }

  /// Viewer opens with no capture by design — a workspace must not submit on
  /// launch. The fixture capture arrives through the same Recapture action a
  /// person uses, so the test drives the product's own path.
  private func launchCapturedViewer(
    extra: [String] = [], windowSize: CGSize = ViewerUITests.establishedWindowSize
  ) -> XCUIApplication {
    let app = launchViewer(extra: extra, windowSize: windowSize)
    let recapture = app.buttons["viewer.recapture"]
    XCTAssertTrue(recapture.waitForExistenceFast(timeout: 10), "Recapture must be offered")
    XCTAssertTrue(
      recapture.isEnabled,
      "the fixture target is Connected and the operation available, so Recapture must be live")
    recapture.click()
    // The tree's own identifier sits on a layout container, which AppKit does
    // not always publish as an element. A row is the reliable proof that a
    // capture actually rendered.
    let firstRow = app.buttons["viewer.tree.node.1"]
    if !firstRow.waitForExistenceFast(timeout: 15) {
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
    if row.waitForExistenceFast(timeout: 10), row.isHittable {
      row.click()
    }
  }

  /// Brings a deep node into the row set through the product's own search,
  /// then clears the query. Scrolling a LazyVStack is not a reliable way to
  /// reach a node that has never been realised into the accessibility tree.
  @discardableResult
  private func revealNode(_ id: String, in app: XCUIApplication) -> XCUIElement {
    let row = app.buttons["viewer.tree.node.\(id)"]
    if row.waitForExistenceFast(timeout: 3) { return row }
    let search = searchField(in: app)
    search.click()
    search.typeText(id)
    XCTAssertTrue(row.waitForExistenceFast(timeout: 10), "search must reveal node #\(id)")
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
