import XCTest

/// Shell-level routing, window structure, Settings placement and History.
///
/// Language is a property of a *run*, not of a test. Relaunching the app to
/// check one string at a time cost roughly a minute per language and made the
/// host switch input sources over and over; each sweep below therefore drives
/// every locale-dependent assertion inside a single launch. Tests that need a
/// different fixture still launch separately, but they assert raw domain
/// strings, which read the same in every language and pin no locale.
///
/// Every launch here uses the presentation-only UI fixtures. Nothing in this
/// file observes a device, submits an operation, or may be recorded as
/// hardware evidence.
@MainActor
final class AppShellUITests: XCTestCase {
  override class func setUp() {
    super.setUp()
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    KeyboardInputSourcePin.restoreWhenTheRunFinishes()
  }

  // MARK: - One launch per language

  func testEnglishSweepOfEveryWorkspace() {
    sweep(
      language: "(en)",
      overview: Overview(
        server: "Healthy", trust: "Ready", channel: "Unverified", attention: "1 item"),
      unavailable: Unavailable(
        titles: ["Flash", "Debug", "ArkUI UI Dump", "Trace"],
        reason: "This workspace is not connected to ArkDeck Runtime in this build.",
        noOperation: "No operation was submitted."),
      history: History(
        readOnlyNote:
          "This workspace reads Runtime state. It cannot submit, cancel or retry anything.",
        outcomeUnknown: "Outcome unknown — this job's effect on the device was never confirmed.",
        waitingForHuman: "Waiting for a person to act."))
  }

  func testSimplifiedChineseSweepOfEveryWorkspace() {
    sweep(
      language: "(zh-Hans)",
      overview: Overview(server: "正常", trust: "已就绪", channel: "未验证", attention: "1 项"),
      unavailable: Unavailable(
        titles: ["刷机", "调试", "ArkUI UI 导出", "追踪"],
        reason: "此版本尚未将该工作区连接到 ArkDeck Runtime。",
        noOperation: "未提交任何操作。"),
      history: History(
        readOnlyNote: "此工作区只读取 Runtime 状态，不能提交、取消或重试任何操作。",
        outcomeUnknown: "结果未知——本 Job 对设备的影响从未被确认。",
        waitingForHuman: "等待人工处理。"))
  }

  private struct Overview {
    let server: String
    let trust: String
    let channel: String
    let attention: String
  }

  private struct Unavailable {
    let titles: [String]
    let reason: String
    let noOperation: String
  }

  private struct History {
    let readOnlyNote: String
    let outcomeUnknown: String
    let waitingForHuman: String
  }

  /// DONE-01 / DONE-02 / DONE-03 / DONE-07 in one pass.
  private func sweep(
    language: String, overview: Overview, unavailable: Unavailable, history: History,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let app = launch(arguments: ["--ui-test-runtime-history", "-AppleLanguages", language])

    // Overview answers its four questions on the first screen.
    XCTAssertTrue(
      app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 15),
      file: file, line: line)
    assertDisplayed(app.staticTexts["overview.status.server.value"], equals: overview.server)
    assertDisplayed(app.staticTexts["overview.status.trust.value"], equals: overview.trust)
    assertDisplayed(app.staticTexts["overview.status.channel.value"], equals: overview.channel)
    assertDisplayed(
      app.staticTexts["overview.status.needsAttention.value"], equals: overview.attention)
    for section in [
      "overview.section.serverToolchain", "overview.section.deviceChannel",
      "overview.section.capabilities", "overview.section.needsAttention",
    ] {
      XCTAssertTrue(app.staticTexts[section].exists, "\(section) missing", file: file, line: line)
    }

    // Advanced Diagnostics is collapsed, and expanding it reveals the raw
    // facts under their established identifiers.
    let toggle = app.buttons["overview.advanced.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertFalse(app.staticTexts["hdc.toolchain.path"].exists, file: file, line: line)
    scrollIntoView(toggle, in: app)
    toggle.click()
    assertDisplayed(app.staticTexts["hdc.toolchain.path"], equals: "/Applications/DevEco/hdc")
    assertDisplayed(app.staticTexts["hdc.counters.autoLifecycle"], equals: "0")

    // Update settings live in the Settings scene, not the main window.
    XCTAssertFalse(app.buttons["update.checkNow"].exists, file: file, line: line)
    XCTAssertFalse(app.checkBoxes["update.automaticChecks"].exists, file: file, line: line)

    // Each unimplemented workspace states its own reason and submits nothing.
    for (identifier, title) in zip(
      [
        "app.navigation.flash", "app.navigation.debug", "app.navigation.uiDump",
        "app.navigation.trace",
      ], unavailable.titles)
    {
      select(identifier, in: app)
      let heading = app.staticTexts["app.unavailable.title"]
      XCTAssertTrue(
        heading.waitForExistence(timeout: 10), "\(identifier) has no unavailable page",
        file: file, line: line)
      assertDisplayed(heading, equals: title)
      assertDisplayed(app.staticTexts["app.unavailable.reason"], equals: unavailable.reason)
      assertDisplayed(
        app.staticTexts["app.unavailable.noOperationSubmitted"], equals: unavailable.noOperation)
      XCTAssertFalse(
        app.staticTexts["hdc.endpoint"].exists, "\(identifier) re-renders diagnostics",
        file: file, line: line)
    }

    // History renders real Runtime facts and offers no way to submit.
    select("app.navigation.history", in: app)
    XCTAssertTrue(element("history.table", in: app).waitForExistence(timeout: 10), file: file, line: line)
    assertDisplayed(app.staticTexts["history.readOnlyNote"], equals: history.readOnlyNote)
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists, "\(forbidden) must not exist", file: file, line: line)
    }

    // An unknown outcome is stated, never folded into the terminal state.
    // The table's own text is not clickable; the row is. Reach it through the
    // per-row state identifier, which is the only identifier the row carries.
    let interruptedRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    XCTAssertTrue(interruptedRow.waitForExistence(timeout: 10), file: file, line: line)
    interruptedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    assertDisplayed(
      app.staticTexts["history.detail.outcomeUnknown"], equals: history.outcomeUnknown)
    assertDisplayed(
      app.staticTexts["history.detail.waitingForHuman"], equals: history.waitingForHuman)
  }

  // MARK: - Fixture-specific launches (locale-independent assertions)

  // DONE-04: an in-flight refresh keeps the previous snapshot visible and
  // rejects a duplicate.
  func testRefreshKeepsThePreviousSnapshotVisibleAndRejectsADuplicate() {
    let app = launch(arguments: ["--ui-test-hdc-refresh-delay"])
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 15))

    refresh.click()

    XCTAssertTrue(app.staticTexts["overview.status.refreshing"].waitForExistence(timeout: 5))
    assertDisplayed(app.staticTexts["hdc.endpoint"], equals: "127.0.0.1:18710", timeout: 2)
    XCTAssertFalse(refresh.isEnabled)

    app.typeKey("r", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["overview.status.refreshing"].waitForNonExistence(timeout: 20))
    XCTAssertFalse(
      displayedText(for: app.staticTexts["hdc.devices.events"]).contains("observationUnknown"))
  }

  // DONE-06: no status is readable by colour alone. These are raw domain
  // strings, identical in every language.
  func testStatusValuesAreTextNotColourAlone() {
    let app = launch(arguments: ["--ui-test-hdc-denied", "--ui-test-hdc-critical-gate"])

    XCTAssertTrue(app.staticTexts["hdc.authorization"].waitForExistence(timeout: 15))
    assertDisplayed(
      app.staticTexts["hdc.authorization"],
      equals: "denied — The device declined trust; retry is non-destructive")
    assertDisplayed(
      app.staticTexts["hdc.lifecycle.criticalGate"],
      equals:
        "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary.")
  }

  // A history that could not be read must never look like an empty history.
  func testAnUnreachableRuntimeStatesItsReasonInsteadOfAnEmptyTable() {
    let app = launch(
      arguments: ["--ui-test-runtime-history", "--ui-test-runtime-history-unreachable"])
    select("app.navigation.history", in: app)

    XCTAssertTrue(app.staticTexts["history.unavailable.title"].waitForExistence(timeout: 15))
    assertDisplayed(
      app.staticTexts["history.unavailable.reason"],
      equals: "ArkDeck Runtime is not reachable: fixture")
    XCTAssertFalse(
      element("history.table", in: app).exists, "an unreadable history shows no table")
    XCTAssertFalse(app.staticTexts["history.empty.title"].exists, "it is not an empty history")
  }


  /// SwiftUI's Table lands in the NSTableView family, which XCUITest does not
  /// expose under `app.tables` here — the sidebar List surfaces as an outline
  /// for the same reason. Ask by identifier and let the type be whatever it is.
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  // MARK: - Helpers

  /// Sidebar rows expose their identifier on the static text inside the cell;
  /// clicking that text does not move List selection, so the enclosing cell is
  /// what must be pressed, by coordinate.
  private func select(
    _ identifier: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // The sidebar is an outline; `app.cells` also matches History's table rows,
    // so the query has to say which list it means.
    let cell = app.outlines.cells.containing(.staticText, identifier: identifier).firstMatch
    XCTAssertTrue(
      cell.waitForExistence(timeout: 10), "sidebar must expose \(identifier)",
      file: file, line: line)
    cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
  }

  /// SwiftUI renders most of these strings into the accessibility *value*, and
  /// section headings into the label, so both are considered.
  private func displayedValues(for element: XCUIElement) -> [String] {
    [element.label, element.value as? String].compactMap { $0 }
  }

  private func displayedText(for element: XCUIElement) -> String {
    displayedValues(for: element).joined(separator: " ")
  }

  private func assertDisplayed(
    _ element: XCUIElement, equals expected: String,
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
  ) {
    let matches = NSPredicate { [weak self] _, _ in
      self?.displayedValues(for: element).contains(expected) ?? false
    }
    let result = XCTWaiter.wait(
      for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
    XCTAssertTrue(
      result == .completed || displayedValues(for: element).contains(expected),
      "expected \(expected), got: \(displayedText(for: element))", file: file, line: line)
  }

  /// `app.scrollViews.firstMatch` is whichever scroll view the tree yields
  /// first — often the sidebar's, which never moves the content. Scroll the
  /// one that actually contains the target.
  /// Which scroll view holds the target is not reliably derivable from the
  /// tree, and guessing wrong scrolls the sidebar while the content stays put.
  /// Scroll every one of them and let the target's own hittability decide.
  private func scrollEverything(in app: XCUIApplication) {
    for host in app.scrollViews.allElementsBoundByIndex {
      host.scroll(byDeltaX: 0, deltaY: -160)
    }
  }

  /// Content below the fold cannot be clicked where it is not drawn: a click at
  /// off-screen coordinates silently does nothing.
  private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
    var attempts = 0
    while !element.isHittable, attempts < 25 {
      scrollEverything(in: app)
      attempts += 1
    }
  }

  private func launch(arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning {
      app.terminate()
    }
    app.launchArguments =
      [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "--ui-test-hdc-diagnostics",
      ] + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.typeKey("n", modifierFlags: .command)
    }
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 5), "ArkDeck must create a test window")
    return app
  }
}
