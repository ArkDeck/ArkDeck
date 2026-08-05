import XCTest

/// Shell-level routing, window structure, and Settings placement.
///
/// Every launch here uses the presentation-only UI fixture. Nothing in this
/// file observes a device, submits an operation, or may be recorded as
/// hardware evidence.
@MainActor
final class AppShellUITests: XCTestCase {
  // DONE-01: each sidebar item renders its own workspace. Only Overview shows
  // HDC diagnostics; the other five state an accurate unavailable reason.
  func testEveryUnimplementedWorkspaceStatesItsOwnUnavailableReason() {
    let app = launch()

    for item in Self.unavailableItems {
      select(item.identifier, in: app)

      let title = app.staticTexts["app.unavailable.title"]
      XCTAssertTrue(
        title.waitForExistence(timeout: 5), "\(item.identifier) must render an unavailable page")
      XCTAssertEqual(title.label, item.englishTitle)
      XCTAssertEqual(
        app.staticTexts["app.unavailable.reason"].label,
        "This workspace is not connected to ArkDeck Runtime in this build.")
      XCTAssertEqual(
        app.staticTexts["app.unavailable.noOperationSubmitted"].label,
        "No operation was submitted.")

      XCTAssertFalse(
        app.staticTexts["hdc.endpoint"].exists,
        "\(item.identifier) must not re-render HDC diagnostics")
      XCTAssertFalse(
        app.buttons["hdc.devices.refresh"].exists,
        "\(item.identifier) must not offer the Overview refresh command")
      XCTAssertFalse(
        app.buttons["hdc.lifecycle.requestImpactPreview"].exists,
        "\(item.identifier) must not offer a recovery control")
      XCTAssertFalse(
        app.buttons["update.checkNow"].exists,
        "\(item.identifier) must not embed update settings")
    }

    select("app.navigation.overview", in: app)
    XCTAssertTrue(app.staticTexts["hdc.endpoint"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["app.unavailable.reason"].exists)
  }

  // DONE-03: the four status answers are on the first screen, and the four
  // content sections carry the grouped diagnostics.
  func testOverviewOpensWithTheFourStatusAnswersAndGroupedSections() {
    let app = launch()

    XCTAssertTrue(app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["overview.status.server.value"].label, "Healthy")
    XCTAssertEqual(app.staticTexts["overview.status.trust.value"].label, "Ready")
    XCTAssertEqual(app.staticTexts["overview.status.channel.value"].label, "Unverified")
    // The default fixture is unverified TCP, so exactly one item needs attention.
    XCTAssertEqual(app.staticTexts["overview.status.needsAttention.value"].label, "1 item")

    for section in [
      "overview.section.serverToolchain", "overview.section.deviceChannel",
      "overview.section.capabilities", "overview.section.needsAttention",
    ] {
      XCTAssertTrue(app.staticTexts[section].exists, "\(section) must be visible on first screen")
    }
    XCTAssertTrue(app.buttons["overview.advanced.toggle"].exists)
  }

  // DONE-03: Advanced Diagnostics is collapsed by default, and every field it
  // holds stays reachable with its established identifier and complete value.
  func testAdvancedDiagnosticsHidesRawFactsUntilExpandedAndKeepsCompleteValues() {
    let app = launch()

    XCTAssertTrue(app.buttons["overview.advanced.toggle"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["hdc.toolchain.path"].exists)
    XCTAssertFalse(app.staticTexts["hdc.counters.autoLifecycle"].exists)

    app.buttons["overview.advanced.toggle"].click()

    XCTAssertTrue(app.staticTexts["hdc.toolchain.path"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["hdc.toolchain.path"].label, "/Applications/DevEco/hdc")
    XCTAssertEqual(app.staticTexts["hdc.toolchain.hash"].label, "fixture-sha256")
    XCTAssertEqual(app.staticTexts["hdc.generation"].label, "7")
    XCTAssertEqual(app.staticTexts["hdc.counters.autoLifecycle"].label, "0")
    XCTAssertEqual(app.staticTexts["hdc.counters.autoSubserver"].label, "0")
  }

  // DONE-04: an in-flight refresh keeps the previous snapshot visible, shows
  // progress, and rejects a duplicate request.
  func testRefreshKeepsThePreviousSnapshotVisibleAndRejectsADuplicate() {
    let app = launch(arguments: ["--ui-test-hdc-refresh-delay"])
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 5))

    refresh.click()

    XCTAssertTrue(app.staticTexts["overview.status.refreshing"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.staticTexts["hdc.endpoint"].label, "127.0.0.1:18710",
      "the previous snapshot must stay readable while a refresh is in flight")
    XCTAssertFalse(refresh.isEnabled)

    // The duplicate must not reach the fixture's deliberately visible third transition.
    app.typeKey("r", modifierFlags: .command)
    XCTAssertTrue(
      app.staticTexts["overview.status.refreshing"].waitForNonExistence(timeout: 20))
    XCTAssertFalse(
      displayedText(for: app.staticTexts["hdc.devices.events"]).contains("observationUnknown"))
  }

  // DONE-02 / DONE-05: update settings left the main window, and the system
  // Settings scene still owns the complete update flow.
  func testUpdateSettingsAreOnlyReachableThroughTheSettingsScene() {
    let app = launch()
    XCTAssertTrue(app.staticTexts["hdc.endpoint"].waitForExistence(timeout: 5))

    XCTAssertFalse(app.buttons["update.checkNow"].exists)
    XCTAssertFalse(app.buttons["update.download"].exists)
    XCTAssertFalse(app.checkBoxes["update.automaticChecks"].exists)

    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(
      app.checkBoxes["update.automaticChecks"].waitForExistence(timeout: 10),
      "the Settings scene must still present the full update flow")
    XCTAssertTrue(app.buttons["update.checkNow"].exists)
  }

  // DONE-06: no status is readable by colour alone — every one of them keeps a
  // symbol and a text value the automation layer can read.
  func testStatusValuesAreTextNotColourAlone() {
    let app = launch(arguments: ["--ui-test-hdc-denied", "--ui-test-hdc-critical-gate"])

    XCTAssertTrue(app.staticTexts["overview.status.trust.value"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["overview.status.trust.value"].label, "Denied")
    XCTAssertEqual(app.staticTexts["overview.status.needsAttention.value"].label, "3 items")
    XCTAssertEqual(
      app.staticTexts["hdc.lifecycle.criticalGate"].label,
      "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary.")
  }

  // DONE-07: Simplified Chinese is complete for the new shell, and long
  // Chinese labels do not displace the primary control at the minimum window.
  func testSimplifiedChineseShellIsCompleteAtTheMinimumWindowSize() {
    let app = launch(arguments: ["-AppleLanguages", "(zh-Hans)"])

    XCTAssertTrue(app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["overview.status.server.value"].label, "正常")
    XCTAssertEqual(app.staticTexts["overview.status.trust.value"].label, "已就绪")
    XCTAssertEqual(app.staticTexts["overview.status.channel.value"].label, "未验证")
    XCTAssertEqual(app.staticTexts["overview.section.needsAttention"].label, "需处理事项")
    XCTAssertEqual(app.buttons["hdc.devices.refresh"].label, "刷新设备")
    XCTAssertTrue(app.buttons["hdc.devices.refresh"].isHittable)

    select("app.navigation.flash", in: app)
    XCTAssertTrue(app.staticTexts["app.unavailable.title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["app.unavailable.title"].label, "刷机")
    XCTAssertEqual(
      app.staticTexts["app.unavailable.noOperationSubmitted"].label, "未提交任何操作。")
  }

  // MARK: - Helpers

  private struct NavigationCase {
    let identifier: String
    let englishTitle: String
  }

  private static let unavailableItems = [
    NavigationCase(identifier: "app.navigation.flash", englishTitle: "Flash"),
    NavigationCase(identifier: "app.navigation.debug", englishTitle: "Debug"),
    NavigationCase(identifier: "app.navigation.uiDump", englishTitle: "ArkUI UI Dump"),
    NavigationCase(identifier: "app.navigation.trace", englishTitle: "Trace"),
    NavigationCase(identifier: "app.navigation.history", englishTitle: "History"),
  ]

  private func select(_ identifier: String, in app: XCUIApplication) {
    let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "sidebar must expose \(identifier)")
    row.click()
  }

  private func displayedText(for element: XCUIElement) -> String {
    [element.label, element.value as? String]
      .compactMap { $0 }
      .joined(separator: " ")
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
