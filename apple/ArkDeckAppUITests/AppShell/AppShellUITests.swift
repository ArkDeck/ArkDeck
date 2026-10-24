import AppKit
import XCTest

/// Shell-level routing, window structure, Settings placement and History.
///
/// Language is a property of a *run*, not of a test. Relaunching the app to
/// check one string at a time cost roughly a minute per language and made the
/// host switch input sources over and over. English owns the complete behavior
/// sweep; the second locale renders and asserts every localized expectation
/// without replaying language-independent state machines. Tests that need a
/// different fixture still launch separately, but they assert raw domain
/// strings, which read the same in every language and pin no locale.
///
/// Default regression launches use presentation-only UI fixtures. The one
/// explicitly opted-in cold-start acceptance below opens the production app
/// and may be recorded as hardware evidence; it remains skipped unless the
/// caller names the real-device environment gate. No test submits an
/// operation.
@MainActor
final class AppShellUITests: XCTestCase {
  static let realDeviceStartupEnvironmentKey =
    "ARKDECK_REAL_DEVICE_STARTUP_ACCEPTANCE"

  override class func setUp() {
    super.setUp()
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    KeyboardInputSourcePin.restoreWhenTheRunFinishes()
  }

  /// Opt-in hardware acceptance for GJ-1. The query deliberately matches the
  /// presentation identifier rather than a serial number, so no device
  /// identity is embedded in source or test output.
  func testRealDeviceColdStartShowsConnectedDeviceWithinTwoSeconds() throws {
    guard
      ProcessInfo.processInfo.environment[
        Self.realDeviceStartupEnvironmentKey
      ] == "1"
    else {
      throw XCTSkip(
        "Set \(Self.realDeviceStartupEnvironmentKey)=1 for real-device startup acceptance")
    }

    let app = XCUIApplication()
    app.launchEnvironment["ARKDECK_UI_TEST_STARTUP_EVIDENCE_PATH"] = "accessibility-value"
    app.launch()

    let deviceRow = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
        "device.row.", "device.row.observed.")
    )
    .firstMatch
    let appeared = deviceRow.waitForExistence(timeout: 10)
    XCTAssertTrue(appeared, "The connected-device row never appeared")
    let evidenceText = try XCTUnwrap(deviceRow.value as? String)
      .replacingOccurrences(of: "startup-seconds:", with: "")
    let elapsed = try XCTUnwrap(
      TimeInterval(evidenceText), "The App did not publish its internal startup timing")

    let evidence = XCTAttachment(
      string: String(format: "connected device row visible after %.3f seconds", elapsed))
    evidence.name = "GJ-1 real-device cold-start timing"
    evidence.lifetime = .keepAlways
    add(evidence)

    XCTAssertLessThanOrEqual(
      elapsed, 2,
      "Cold start took \(String(format: "%.3f", elapsed)) seconds to show the device row")
  }

  /// Opt-in History acceptance against production Runtime state. The device
  /// operation is executed headlessly before this test; this UI leg proves
  /// that the resulting verified Job is discoverable and can reopen its
  /// related workspace without replaying it.
  func testRealDeviceHistoryReopensExactViewerCapture() throws {
    guard
      ProcessInfo.processInfo.environment[
        Self.realDeviceStartupEnvironmentKey
      ] == "1"
    else {
      throw XCTSkip(
        "Set \(Self.realDeviceStartupEnvironmentKey)=1 for real-device History acceptance")
    }
    guard let jobID = ProcessInfo.processInfo.environment["ARKDECK_REAL_DEVICE_VIEWER_JOB_ID"],
      jobID.hasPrefix("job-"), jobID.count > 4
    else { throw XCTSkip("Supply the exact real Viewer capture Job ID; newest history may be an analyzer Job") }

    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

    select("app.navigation.history", in: app)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistenceFast(timeout: 30),
      "production Runtime history did not render")
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
    search.click()
    search.typeKey("a", modifierFlags: .command)
    search.typeText(jobID)
    XCTAssertTrue(
      app.staticTexts["history.detail.select"].waitForNonExistenceFast(timeout: 10),
      "the requested production capture was not selected")
    assertDisplayed(element("history.detail.job", in: app), equals: jobID, timeout: 30)
    assertDisplayed(
      app.staticTexts["history.detail.operation"], equals: "capture.diagnostics@1", timeout: 30)
    XCTAssertTrue(
      element("history.artifacts", in: app).waitForExistenceFast(timeout: 30),
      "the verified capture artifacts did not load")

    let openWorkspace = app.buttons["history.openWorkspace"]
    XCTAssertTrue(openWorkspace.waitForExistence(timeout: 10))
    openWorkspace.click()
    XCTAssertTrue(
      element("history.context", in: app).waitForExistenceFast(timeout: 10),
      "the Viewer destination did not retain its exact History context")
    XCTAssertTrue(
      displayedText(for: element("history.context.operation", in: app))
        .contains("capture.diagnostics@1"))
    XCTAssertTrue(
      element("viewer.pane.screenshot", in: app).waitForExistenceFast(timeout: 30),
      "the historical screenshot Artifact did not reopen in Viewer")
    XCTAssertTrue(
      element("viewer.tree.scroll", in: app).waitForExistenceFast(timeout: 30),
      "the historical component-tree Artifact did not reopen in Viewer")

    let evidence = XCTAttachment(
      string: "The exact requested Runtime Viewer capture was visible with verified artifacts and reopened its screenshot and component tree without replay.")
    evidence.name = "History real-device activity acceptance"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  /// Reads an existing production Flash record whose typed steps are unknown.
  /// No reconcile, replay or device action is requested by this presentation test.
  func testRealRuntimeHistoryKeepsUnknownFlashEvidenceInspectableInBothLanguages() throws {
    guard let jobID = ProcessInfo.processInfo.environment["ARKDECK_REAL_RUNTIME_UNKNOWN_FLASH_JOB_ID"],
      jobID.hasPrefix("job-"), jobID.count > 4
    else { throw XCTSkip("Supply an existing unknown Flash Job with unreported typed steps") }

    for (language, unreported) in [("(en)", "Not reported"), ("(zh-Hans)", "未报告")] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection",
        "-AppleLanguages", language,
      ]
      app.launch()
      app.activate()
      defer { app.terminate() }
      XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
      select("app.navigation.history", in: app)
      XCTAssertTrue(element("history.table", in: app).waitForExistenceFast(timeout: 30))
      let search = app.textFields["history.filter.search"]
      XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
      search.click()
      search.typeKey("a", modifierFlags: .command)
      search.typeText(jobID)
      assertDisplayed(element("history.detail.job", in: app), equals: jobID, timeout: 30)
      assertDisplayed(
        element("history.detail.operation", in: app), equals: "flash.full-restore@1", timeout: 30)
      XCTAssertTrue(element("history.detail.outcomeUnknown", in: app).waitForExistenceFast(timeout: 10))
      assertDisplayed(element("history.evidence.provider", in: app), equals: "arkforge", timeout: 30)
      let unknownSteps = element("history.evidence.steps.unreported", in: app)
      XCTAssertTrue(unknownSteps.waitForExistenceFast(timeout: 10))
      scrollIntoView(unknownSteps, in: app)
      assertDisplayed(unknownSteps, equals: unreported)
      XCTAssertFalse(element("history.evidence.steps", in: app).exists)
      let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      evidence.name = "Unknown Flash evidence retained in History \(language)"
      evidence.lifetime = .keepAlways
      add(evidence)
    }
  }

  /// Compares the production Settings scene with a saved read-only CLI result.
  /// Cancelling the folder picker must preserve the current Runtime settings.
  func testRealRuntimeStorageSettingsMatchReadbackInBothLanguages() throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_REAL_RUNTIME_STORAGE_STATUS"]
    else { throw XCTSkip("Supply the current runtime storage status JSON result") }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertLessThan(bytes.count, 32_768)
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(envelope["command"] as? String, "runtime.storage.status")
    XCTAssertEqual(envelope["ok"] as? Bool, true)
    let result = try XCTUnwrap(envelope["result"] as? [String: Any])
    let session = try XCTUnwrap(result["sessionDomain"] as? [String: Any])
    let rootPath = try XCTUnwrap(session["rootPath"] as? String)
    let policy = try XCTUnwrap(session["policy"] as? [String: String])
    let quota = try XCTUnwrap(policy["totalQuotaBytes"].flatMap(UInt64.init))
    let margin = try XCTUnwrap(policy["safetyMarginBytes"].flatMap(UInt64.init))
    let retention = try XCTUnwrap(policy["retentionDays"])

    for (language, storageTitle, cancelTitle) in [
      ("(en)", "Storage", "Cancel"), ("(zh-Hans)", "存储", "取消"),
    ] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection",
        "-AppleLanguages", language,
      ]
      app.launch()
      app.activate()
      defer { app.terminate() }
      XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
      openSettings(in: app)
      settingsPane(storageTitle, in: app).click()
      let chooseRoot = app.buttons["settings.storage.chooseRoot"]
      XCTAssertTrue(chooseRoot.waitForExistenceFast(timeout: 30))
      XCTAssertTrue(app.staticTexts[rootPath].waitForExistenceFast(timeout: 10))
      assertDisplayed(app.textFields["settings.storage.quota"], equals: String(quota / 1_073_741_824))
      assertDisplayed(app.textFields["settings.storage.margin"], equals: String(margin / 1_073_741_824))
      assertDisplayed(app.textFields["settings.storage.retention"], equals: retention)
      XCTAssertFalse(element("settings.error.refresh", in: app).exists)

      chooseRoot.click()
      let cancel = app.sheets.buttons[cancelTitle].firstMatch
      XCTAssertTrue(cancel.waitForExistenceFast(timeout: 10))
      cancel.click()
      XCTAssertTrue(cancel.waitForNonExistenceFast(timeout: 10))
      XCTAssertTrue(app.staticTexts[rootPath].exists)
      assertDisplayed(app.textFields["settings.storage.quota"], equals: String(quota / 1_073_741_824))
      let evidence = XCTAttachment(
        screenshot: app.windows["com_apple_SwiftUI_Settings_window"].screenshot())
      evidence.name = "Production storage settings and cancelled folder selection \(language)"
      evidence.lifetime = .keepAlways
      add(evidence)
    }
  }

  /// One presentation-only App instance per language, with named activities
  /// instead of a fresh process for each History/recovery assertion group.
  /// Fixture state changes use the existing read-only provider and normal
  /// refresh controls; no Runtime or device operation is submitted.
  func testHistoryAndRecoveryContinuousSessionInBothLanguages() throws {
    try Self.requireDisplay(fitting: Self.recoveryReferenceSize)
    for language in ["(en)", "(zh-Hans)"] {
      try "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
        // Establish the reference viewport at launch: the frame autosave
        // survives `-ApplePersistenceIgnoreState`, and a frame inherited from
        // an earlier desktop or display arrangement can sit too low for the
        // interactive resizes below to ever reach 783pt.
        "--ui-test-window-frame=\(Int(Self.recoveryReferenceSize.width))x\(Int(Self.recoveryReferenceSize.height))",
      ])
      defer {
        if app.state != .notRunning {
          if app.windows.firstMatch.exists {
            Self.resizeRecoveryWindow(in: app, to: Self.recoveryReferenceSize)
          }
          app.terminate()
        }
        try? FileManager.default.removeItem(at: fixtureStateFileURL)
      }
      XCTAssertTrue(
        app.windows.firstMatch.waitForFrameSize(Self.recoveryReferenceSize, timeout: 5),
        "the launch must establish the declared \(Self.recoveryReferenceSize) frame, "
          + "got \(app.windows.firstMatch.frame)")
      let processes = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop")
      XCTAssertEqual(processes.count, 1, "the session must have exactly one App process")
      let processID = try XCTUnwrap(processes.first?.processIdentifier)

      // Exercise the previously clipped narrow-window targets first, then
      // continue the other rounds in this very same App process.
      runHistorySessionPhase(
        "Five recovery states, wide and narrow", language: language, in: app, processID: processID
      ) {
        prepareHistorySessionPhase(in: app, recoveryFamily: true)
        checkRecoveryFamilyKeepsWorkspaceUsable(in: app, language: language)
      }

      // These behavior-only checks formerly used three independent English
      // launches. Keep their coverage and cleanup while sharing this session.
      if language == "(en)" {
        runHistorySessionPhase(
          "Exact immutable provenance", language: language, in: app, processID: processID
        ) {
          prepareHistorySessionPhase(in: app)
          checkHistoryReopensExactFixtureContextWithoutReplay(in: app)
        }
        runHistorySessionPhase(
          "Wide saved filter", language: language, in: app, processID: processID
        ) {
          prepareHistorySessionPhase(in: app)
          checkHistorySavedFilterRestoresActivityAndExposesOneFilterSet(in: app)
        }
        runHistorySessionPhase(
          "Narrow filter and keyboard", language: language, in: app, processID: processID
        ) {
          prepareHistorySessionPhase(in: app)
          checkHistoryActivityFilterSurvivesNarrowWindowAndSavedFilter(in: app)
        }
      }
      runHistorySessionPhase(
        "Exact recovery route, two rounds", language: language, in: app, processID: processID
      ) {
        prepareHistorySessionPhase(in: app)
        checkRecoveryBannerOpensExactJob(in: app, language: language)
      }
      runHistorySessionPhase(
        "Canonical Flash history transitions", language: language, in: app, processID: processID
      ) {
        Self.resizeRecoveryWindow(in: app, to: CGSize(width: 1180, height: 783))
        checkCanonicalFlashHistoryStates(in: app, language: language)
      }
    }
  }

  func runHistorySessionPhase(
    _ name: String, language: String, in app: XCUIApplication, processID: pid_t,
    body: () -> Void
  ) {
    XCTContext.runActivity(named: "\(language) / \(name)") { activity in
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
      let evidence = XCTAttachment(
        string: "language=\(language)\nphase=\(name)\nexpectedPID=\(processID)\nbefore=\(before)\nafter=\(after)")
      evidence.name = "App instance continuity"
      evidence.lifetime = .keepAlways
      activity.add(evidence)
    }
  }

  func prepareHistorySessionPhase(in app: XCUIApplication, recoveryFamily: Bool = false) {
    writeFixtureState(recoveryFamily ? "--ui-test-runtime-recovery-family" : "", in: app)
    Self.resizeRecoveryWindow(in: app, to: CGSize(width: 1180, height: 783))
    let dismissContext = app.buttons["history.context.dismiss"]
    if dismissContext.exists { dismissContext.click() }
    // Reset page-local filters/selection through normal navigation BETWEEN
    // phases. Exact-route rounds deliberately stay on the same History page.
    select("app.navigation.overview", in: app)
    select("app.navigation.history", in: app)
    XCTAssertTrue(element("history.table", in: app).waitForExistenceFast(timeout: 10))
    app.buttons["history.refresh"].click()
    assertDisplayed(
      app.staticTexts["history.detail.job"],
      equals: recoveryFamily ? "job-fixture-recovery-waiting" : "job-fixture-0002")
    XCTAssertEqual(app.textFields["history.filter.search"].value as? String, "")
  }

  /// Presentation-only regression: opening a cross-workspace panel must not
  /// recreate History or discard either pane's selected record.
  func testHistoryAndJobSelectionSurviveInspectorToggle() {
    let app = launch(arguments: [
      "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
      "--ui-test-window-frame=1180x783", "-AppleLanguages", "(en)",
    ])
    defer { app.terminate() }
    XCTAssertTrue(
      app.windows.firstMatch.waitForFrameSize(CGSize(width: 1180, height: 783), timeout: 5))
    select("app.navigation.history", in: app)
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
    search.click()
    search.typeText("job-fixture")
    element("history.activity.viewer", in: app).click()
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0001")
    let flashRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    XCTAssertTrue(flashRow.waitForNonExistenceFast(timeout: 5))

    let toggle = app.buttons["jobInspector.toggle"]
    toggle.click()
    let inspectorList = element("jobInspector.list", in: app)
    XCTAssertTrue(inspectorList.waitForExistenceFast(timeout: 10))
    XCTAssertEqual(search.value as? String, "job-fixture")
    XCTAssertFalse(flashRow.exists, "opening the inspector must preserve the unsaved Viewer filter")
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0001")

    // The row identifier propagates to its text descendants. Select the
    // native List cell, not the first matching StaticText's clipped frame.
    let inspectedJob = app.cells.containing(
      .staticText, identifier: "jobInspector.row.job-fixture-0001").firstMatch
    XCTAssertTrue(inspectedJob.waitForExistenceFast(timeout: 5))
    inspectedJob.click()
    XCTAssertTrue(
      element("jobInspector", in: app).staticTexts["job-fixture-0001"]
        .waitForExistenceFast(timeout: 5))
    XCTAssertFalse(app.buttons["jobInspector.cancel"].exists)

    toggle.click()
    XCTAssertTrue(inspectorList.waitForNonExistenceFast(timeout: 5))
    XCTAssertEqual(search.value as? String, "job-fixture")
    XCTAssertFalse(flashRow.exists)
    toggle.click()
    XCTAssertTrue(inspectorList.waitForExistenceFast(timeout: 5))
    XCTAssertEqual(search.value as? String, "job-fixture")
    XCTAssertFalse(flashRow.exists)
    XCTAssertTrue(
      element("jobInspector.attention", in: app).waitForNonExistenceFast(timeout: 5),
      "reopening must retain the selected successful Job, not reset to the attention Job")
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0001")
  }

  func testHistoryKeyboardCommandsFollowVisibleWorkspace() {
    for language in ["(en)", "(zh-Hans)"] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-diagnostics-session", "--ui-test-devices",
        "--ui-test-window-frame=1180x783", "-AppleLanguages", language,
      ])
      select("app.navigation.history", in: app)
      let search = app.textFields["history.filter.search"]
      XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
      app.typeKey("f", modifierFlags: .command)
      app.typeText("job-fixture-diagnostics")
      XCTAssertEqual(search.value as? String, "job-fixture-diagnostics")
      assertDisplayed(element("history.detail.job", in: app), equals: "job-fixture-diagnostics")
      app.typeKey("a", modifierFlags: .command)
      app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

      app.typeKey("j", modifierFlags: [.command, .shift])
      let read = app.buttons["jobInspector.readLog.fixture-capture.log"]
      XCTAssertTrue(read.waitForExistenceFast(timeout: 10))
      scrollIntoView(read, in: app)
      read.click()
      let log = element("jobInspector.log.text", in: app)
      XCTAssertTrue(log.waitForExistenceFast(timeout: 10))
      app.typeKey("r", modifierFlags: .command)
      XCTAssertTrue(log.waitForNonExistenceFast(timeout: 10),
        "Cmd-R must refresh History even when focus is inside Job Inspector")
      app.typeKey("j", modifierFlags: [.command, .shift])

      let findTitle = language == "(en)" ? "Search History" : "搜索历史记录"
      // Opening the menu moves focus out of the search field; the scene's
      // command must remain available until the actual workspace changes.
      app.menuBars.menuBarItems.matching(
        NSPredicate(format: "title IN %@", ["Edit", "编辑"])).firstMatch.click()
      XCTAssertTrue(app.menuItems[findTitle].waitForExistenceFast(timeout: 5))
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
      select("app.navigation.device", in: app)
      app.menuBars.menuBarItems.matching(
        NSPredicate(format: "title IN %@", ["Edit", "编辑"])).firstMatch.click()
      XCTAssertFalse(app.menuItems[findTitle].exists,
        "a hidden History page must not retain the window's Find command")
      app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
      select("app.navigation.history", in: app)
      XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
      app.typeKey("f", modifierFlags: .command)
      app.typeText("job-fixture-diagnostics")
      XCTAssertEqual(search.value as? String, "job-fixture-diagnostics")
      app.terminate()
    }
  }

  /// A refresh outside the inspector must invalidate its independently loaded
  /// detail, even when job.list returns exactly the same summary.
  func testInspectorReloadsAfterHistoryRefreshInBothLanguages() {
    for language in ["(en)", "(zh-Hans)"] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-diagnostics-session", "--ui-test-devices",
        "--ui-test-window-frame=1180x783", "-AppleLanguages", language,
        language == "(en)" ? "--ui-test-appearance=light" : "--ui-test-appearance=dark",
      ])
      let geometry = app.staticTexts["uiTest.windowGeometry"]
      let expectedDark = language == "(en)" ? 0.0 : 1.0
      let appearanceMatches = NSPredicate { _, _ in
        guard let value = geometry.value as? String, let data = value.data(using: .utf8),
          let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return false }
        return facts["isDark"] == expectedDark
      }
      XCTAssertEqual(
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: appearanceMatches, object: nil)],
          timeout: 5), .completed, "the native window must use the requested test appearance")
      select("app.navigation.history", in: app)
      app.buttons["jobInspector.toggle"].click()
      let read = app.buttons["jobInspector.readLog.fixture-capture.log"]
      XCTAssertTrue(read.waitForExistenceFast(timeout: 10))
      scrollIntoView(read, in: app)
      read.click()
      let log = element("jobInspector.log.text", in: app)
      XCTAssertTrue(log.waitForExistenceFast(timeout: 10))
      app.buttons["history.refresh"].click()
      XCTAssertTrue(log.waitForNonExistenceFast(timeout: 10),
        "a refreshed History snapshot must invalidate the inspector's old detail and log")
      XCTAssertTrue(read.waitForExistenceFast(timeout: 10))
      scrollIntoView(read, in: app)
      read.click()
      XCTAssertTrue(log.waitForExistenceFast(timeout: 10))
      let open = app.buttons["jobInspector.openRecord"]
      scrollIntoView(open, in: app)
      open.click()
      assertDisplayed(element("history.detail.job", in: app), equals: "job-fixture-diagnostics")
      let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      screenshot.name = "Inspector refreshed exact record \(language)"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      app.buttons["jobInspector.toggle"].click()
      for size in [CGSize(width: 1180, height: 600), CGSize(width: 900, height: 600)] {
        Self.resizeRecoveryWindow(in: app, to: size)
        select("app.navigation.device", in: app)
        XCTAssertTrue(element("device.screen.empty", in: app).waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.buttons["device.capture"].isHittable)
        let performance = element("device.performance", in: app)
        scrollIntoView(performance, in: app)
        XCTAssertTrue(performance.isHittable, "the full Device inspector must remain scrollable")
        let deviceShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        deviceShot.name = "Device scrollable inspector \(language) \(Int(size.width))"
        deviceShot.lifetime = .keepAlways
        add(deviceShot)
      }
      app.terminate()
    }
  }

  /// Debug currently composes a production read provider even when the
  /// History and device presentation fixtures are selected. Keep this path
  /// separate so fixture-only runs never query the installed Runtime.
  func testDebugAvailabilityAtMinimumWindowInBothLanguages() throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_REAL_RUNTIME_DEBUG_READONLY_ACCEPTANCE"] == "1"
    else {
      throw XCTSkip("Select installed Debug integration only with a compatible Runtime and target; fixture-only run")
    }
    for language in ["(en)", "(zh-Hans)"] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-devices",
        "--ui-test-window-frame=1180x783", "-AppleLanguages", language,
        language == "(en)" ? "--ui-test-appearance=light" : "--ui-test-appearance=dark",
      ])
      defer { app.terminate() }
      for size in [CGSize(width: 1180, height: 600), CGSize(width: 900, height: 600)] {
        Self.resizeRecoveryWindow(in: app, to: size)
        select("app.navigation.debug", in: app)
        let commands = app.buttons["debug.tab.commands"]
        XCTAssertTrue(commands.waitForExistenceFast(timeout: 10))
        commands.click()
        XCTAssertTrue(app.buttons["debug.refresh"].isHittable)
        let debugShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        debugShot.name = "Debug availability \(language) \(Int(size.width))"
        debugShot.lifetime = .keepAlways
        add(debugShot)
      }
    }
  }

  func checkHistorySavedFilterRestoresActivityAndExposesOneFilterSet(in app: XCUIApplication) {
    Self.resizeHistoryWindow(in: app, to: 1180)
    select("app.navigation.history", in: app)
    XCTAssertTrue(element("history.table", in: app).waitForExistenceFast(timeout: 10))

    for identifier in [
      "history.filter.status", "history.filter.mode", "history.filter.session",
      "history.filter.device", "history.filter.time",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).exists,
        "the wide activity-center layout must expose \(identifier)")
    }
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "history.filter.search").count,
      1,
      "wide and compact composition must share one search control")

    let flashFilter = element("history.activity.flash", in: app)
    XCTAssertTrue(flashFilter.waitForExistenceFast(timeout: 5))
    // The row's padding is part of its hit target, not only its text and icon.
    flashFilter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).click()
    let viewerRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0001").firstMatch
    XCTAssertTrue(viewerRow.waitForNonExistenceFast(timeout: 5))

    element("history.filter.saved", in: app).click()
    let save = app.menuItems["Save current filter"]
    XCTAssertTrue(save.waitForExistenceFast(timeout: 5))
    save.click()
    XCTAssertTrue(save.waitForNonExistenceFast(timeout: 5))

    element("history.activity.all", in: app)
      .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).click()
    XCTAssertTrue(viewerRow.waitForExistenceFast(timeout: 5))
    element("history.filter.saved", in: app).click()
    let apply = app.menuItems["Apply saved filter"]
    XCTAssertTrue(apply.waitForExistenceFast(timeout: 5))
    apply.click()
    XCTAssertTrue(
      viewerRow.waitForNonExistenceFast(timeout: 5),
      "applying the saved filter must restore the activity category")

    // Leave persistent AppStorage clean for the language sweeps.
    element("history.filter.saved", in: app).click()
    let delete = app.menuItems["Delete saved filter"]
    if delete.waitForExistenceFast(timeout: 2) { delete.click() }
  }

  func checkHistoryActivityFilterSurvivesNarrowWindowAndSavedFilter(in app: XCUIApplication) {
    // macOS can preserve the last frame even with persistence disabled,
    // especially after an interrupted run. Establish the viewport we test.
    Self.resizeHistoryWindow(in: app, to: 1180)
    defer { Self.resizeHistoryWindow(in: app, to: 1180) }
    select("app.navigation.history", in: app)
    let wideFlash = element("history.activity.flash", in: app)
    XCTAssertTrue(wideFlash.waitForExistenceFast(timeout: 10))
    wideFlash.click()
    element("history.filter.saved", in: app).click()
    app.menuItems["Save current filter"].click()

    Self.resizeHistoryWindow(in: app, to: 900)
    let activity = element("history.filter.activity", in: app)
    XCTAssertTrue(activity.waitForExistenceFast(timeout: 5))
    XCTAssertFalse(wideFlash.exists, "the test must actually enter the compact layout")
    XCTAssertTrue(activity.isHittable, "category selection must remain reachable at minimum width")
    assertDisplayed(activity, equals: "Flashed images")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "history.filter.search").count, 1)

    let viewerRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0001").firstMatch
    let flashRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    XCTAssertFalse(viewerRow.exists)
    activity.click()
    app.menuItems["All records"].click()
    XCTAssertTrue(viewerRow.waitForExistenceFast(timeout: 5))

    element("history.filter.saved", in: app).click()
    app.menuItems["Apply saved filter"].click()
    XCTAssertTrue(viewerRow.waitForNonExistenceFast(timeout: 5))
    assertDisplayed(activity, equals: "Flashed images")

    // The native picker keeps its keyboard menu behavior in the compact layout.
    activity.click()
    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    assertDisplayed(activity, equals: "Viewer and observe")
    XCTAssertTrue(viewerRow.waitForExistenceFast(timeout: 5))
    XCTAssertTrue(flashRow.waitForNonExistenceFast(timeout: 5))

    let filters = app.buttons["history.filter.show"]
    filters.click()
    let status = element("history.filter.status", in: app)
    XCTAssertTrue(status.waitForExistenceFast(timeout: 5))
    status.click()
    app.menuItems["Failed"].click()
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(viewerRow.waitForNonExistenceFast(timeout: 5))
    assertDisplayed(activity, equals: "Viewer and observe")
    filters.click()
    assertDisplayed(status, equals: "Failed")
    status.click()
    app.menuItems["All states"].click()
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(viewerRow.waitForExistenceFast(timeout: 5))

    Self.resizeHistoryWindow(in: app, to: 1180)
    XCTAssertTrue(wideFlash.waitForExistenceFast(timeout: 5))
    XCTAssertFalse(activity.exists)
    XCTAssertTrue(viewerRow.exists, "expanding must preserve the compact category selection")
    XCTAssertFalse(flashRow.exists)
    element("history.activity.all", in: app).click()
    XCTAssertTrue(flashRow.waitForExistenceFast(timeout: 5))
    element("history.filter.saved", in: app).click()
    app.menuItems["Delete saved filter"].click()
  }

  func checkHistoryReopensExactFixtureContextWithoutReplay(in app: XCUIApplication) {
    select("app.navigation.history", in: app)
    XCTAssertTrue(element("history.table", in: app).waitForExistenceFast(timeout: 10))
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0002", timeout: 10)

    let openWorkspace = app.buttons["history.openWorkspace"]
    XCTAssertTrue(openWorkspace.waitForExistenceFast(timeout: 10))
    app.buttons["history.detail.reload"].click()
    XCTAssertTrue(openWorkspace.waitForExistenceFast(timeout: 10))
    app.buttons["history.refresh"].click()
    XCTAssertTrue(
      openWorkspace.waitForExistenceFast(timeout: 10),
      "refreshing unchanged history must reload the selected Job's detail")
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0002", timeout: 10)
    openWorkspace.click()

    XCTAssertTrue(
      element("flash.workspace.title", in: app).waitForExistenceFast(timeout: 10),
      "a Flash history must reopen the related workspace")
    XCTAssertTrue(
      element("history.context", in: app).waitForExistenceFast(timeout: 10),
      "the destination must retain visible immutable History provenance")
    XCTAssertTrue(
      displayedText(for: element("history.context.job", in: app)).contains("job-fixture-0002"))
    XCTAssertTrue(
      displayedText(for: element("history.context.target", in: app)).contains("target-fixture-b"))
    XCTAssertTrue(
      displayedText(for: element("history.context.operation", in: app)).contains("flash.dayu200"))
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists,
        "opening immutable History context must not expose the legacy \(forbidden) action")
    }
  }

  func checkRecoveryBannerOpensExactJob(in app: XCUIApplication, language: String) {
    Self.resizeHistoryWindow(in: app, to: 1180)
    select("app.navigation.history", in: app)
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
    // Stay in History: recreating the page through another workspace would
    // coincidentally select this fixture's newest Job and hide the bug.
    let review = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "jobRecovery.openHistory")
    ).firstMatch
    XCTAssertTrue(review.waitForExistenceFast(timeout: 10))
    for _ in 0..<2 {
      search.click()
      search.typeText("job-fixture-0001")
      assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0001")
      review.click()
      assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0002")
      XCTAssertEqual(search.value as? String, "", "the exact Job must escape the previous filter")
      XCTAssertTrue(
        element("history.row.state.job-fixture-0002", in: app).isHittable,
        "the requested Job row must be visible, not left above the old scroll position")
    }
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(app.buttons[forbidden].exists)
    }
    let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    evidence.name = "Recovery exact History \(language)"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  func checkRecoveryFamilyKeepsWorkspaceUsable(in app: XCUIApplication, language: String) {
    select("app.navigation.history", in: app)
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistenceFast(timeout: 10))
    for size in [CGSize(width: 900, height: 650), CGSize(width: 1180, height: 783)] {
      Self.resizeRecoveryWindow(in: app, to: size)
      let recovery = app.scrollViews["jobRecovery.list"]
      XCTAssertTrue(recovery.waitForExistenceFast(timeout: 5))
      recovery.scroll(byDeltaX: 0, deltaY: 2000)
      assertDisplayed(
        app.staticTexts["jobRecovery.count"],
        equals: language == "(en)" ? "5 records need review" : "5 条记录待检查")
      XCTAssertLessThanOrEqual(recovery.frame.height, size.height * 0.45)
      let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      let actualSize = app.windows.firstMatch.frame.size
      evidence.name = "Recovery family \(language) \(Int(actualSize.width))x\(Int(actualSize.height))"
      evidence.lifetime = .keepAlways
      add(evidence)
      XCTAssertTrue(search.isHittable, "recovery records must not displace the workspace controls")
      let table = element("history.table", in: app)
      XCTAssertGreaterThan(table.frame.height, 180, "History must retain usable vertical space")
      XCTAssertLessThanOrEqual(table.frame.maxY, app.windows.firstMatch.frame.maxY)
      if size.width == 900 {
        app.buttons["history.filter.show"].click()
        let panel = app.popovers.firstMatch
        guard panel.waitForExistenceFast(timeout: 5) else {
          let hierarchy = XCTAttachment(string: app.debugDescription)
          hierarchy.name = "History filter popover hierarchy"
          hierarchy.lifetime = .keepAlways
          add(hierarchy)
          XCTFail("the native filter popover must be exposed")
          return
        }
        for filter in ["status", "mode", "session", "device", "time"] {
          let picker = element("history.filter.\(filter)", in: app)
          XCTAssertTrue(picker.isHittable)
          XCTAssertTrue(
            panel.frame.contains(picker.frame),
            "filter \(filter): \(picker.frame), popover \(panel.frame)")
        }
        let filters = XCTAttachment(screenshot: panel.screenshot())
        filters.name = "Recovery History filters \(language)"
        filters.lifetime = .keepAlways
        add(filters)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(element("history.filter.status", in: app).waitForNonExistenceFast(timeout: 5))
        XCTAssertTrue(search.isHittable)
      }
      for kind in ["unknown", "human", "waiting", "safe", "archive"] {
        let jobID = "job-fixture-recovery-\(kind)"
        let review = app.buttons["jobRecovery.openHistory.\(jobID)"]
        // AppKit may report clipped scroll content as hittable. Only click
        // after the actual button frame is inside the recovery viewport.
        var reviewIsVisible = false
        for attempt in 0...20 {
          let viewport = recovery.frame
          let buttonFrame = review.frame
          reviewIsVisible = review.exists && viewport.contains(buttonFrame) && review.isHittable
          if reviewIsVisible || attempt == 20 { break }
          let step = min(180, viewport.height / 2)
          let direction: CGFloat = buttonFrame.midY < viewport.midY ? 1 : -1
          recovery.scroll(byDeltaX: 0, deltaY: direction * step)
        }
        // Reuse the final observation: each AX frame query is a round trip.
        // Keep the same full-frame/hit-test condition and 20-scroll bound.
        XCTAssertTrue(reviewIsVisible, "every unresolved record must remain reachable: \(kind)")
        if reviewIsVisible {
          search.click()
          search.typeText("unrelated")
          XCTAssertTrue(element("history.filter.empty", in: app).waitForExistenceFast(timeout: 5))
          review.click()
          assertDisplayed(app.staticTexts["history.detail.job"], equals: jobID)
          XCTAssertEqual(search.value as? String, "")
          let row = element("history.row.state.\(jobID)", in: app)
          // The click scrolls History to the requested row. The detail pane
          // updates before that reveal settles, and in the 190pt-tall narrow
          // viewport the lazy row may not even be realised yet — so wait for
          // the settled state instead of sampling the animation. This
          // tolerates only timing: a reveal that never fits still fails.
          let rowSettled = NSPredicate { _, _ in
            table.frame.contains(row.frame) && row.isHittable
          }
          let revealResult = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: rowSettled, object: nil)], timeout: 5)
          // Use the observation that fulfilled the expectation. Re-querying
          // AX after a successful wait races subsequent List layout passes
          // and can turn an observed, hittable reveal into a false failure.
          let rowIsVisible = revealResult == .completed
          if !rowIsVisible {
            let failure = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            failure.name = "Requested History row missing \(jobID)"
            failure.lifetime = .keepAlways
            add(failure)
          }
          XCTAssertTrue(
            rowIsVisible,
            "requested History row \(jobID): row \(row.frame), viewport \(table.frame)")
        }
      }
      for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
        XCTAssertFalse(app.buttons[forbidden].exists)
      }
      let selected = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      selected.name = "Recovery exact final \(language) \(Int(actualSize.width))x\(Int(actualSize.height))"
      selected.lifetime = .keepAlways
      add(selected)
    }
    Self.resizeRecoveryWindow(in: app, to: CGSize(width: 1180, height: 783))
  }

  /// The quota query suspends before capture. It must already own the record
  /// controls during that await, not leave a second request or new frame count
  /// available. No archive is read: the fixture refuses before capture.
  func testDeviceRecordingLocksControlsWhileCheckingStorage() {
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-devices", "-AppleLanguages", "(en)",
        "--ui-test-device-recording=/unused-preflight-fixture.tar",
        "--ui-test-device-recording-headroom=1500000",
        "--ui-test-device-recording-headroom-delay-ms=10000",
      ], resetDeviceNames: false)
    select("app.navigation.device", in: app)
    let start = app.buttons["device.record.start"]
    XCTAssertTrue(start.waitForExistenceFast(timeout: 10))
    scrollIntoView(start, in: app)
    start.click()

    XCTAssertFalse(start.isEnabled, "the quota await must reject another recording")
    XCTAssertFalse(
      element("device.record.frames", in: app).isEnabled,
      "the requested frame count must stay fixed during the quota await")
    let phase = element("device.record.stage", in: app)
    guard phase.waitForExistenceFast(timeout: 2) else {
      XCTFail("the pending quota query must have a visible stage")
      return
    }
    assertDisplayed(phase, equals: "Checking storage", timeout: 2)
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "Device recording storage preflight"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    XCTAssertTrue(element("device.record.refused", in: app).waitForExistenceFast(timeout: 15))
    XCTAssertTrue(start.isEnabled, "a refusal must release the recording controls")
    XCTAssertTrue(element("device.record.frames", in: app).isEnabled)
    XCTAssertFalse(element("device.record.ready", in: app).exists)
    // The keyboard pane can put this link below the inspector viewport.
    // AX existence does not prove a click will reach it through the Job bar.
    let shrink = element("device.record.shrink", in: app)
    scrollIntoView(shrink, in: app)
    XCTAssertTrue(shrink.isHittable, "the shrink action must be visible before clicking")
    shrink.click()
    scrollIntoView(element("device.record.frames", in: app), in: app)
    XCTAssertTrue(app.staticTexts["22 frames"].exists)
    XCTAssertFalse(element("device.record.stage", in: app).exists)
    assertDisplayed(start, equals: "Record")
    app.terminate()
  }

  func testDevicePreviewStopsBeforeKeyboardInputAndUnknownStaysStale() {
    let app = launch(arguments: [
      "--ui-test-runtime-history", "--ui-test-devices", "--ui-test-device-interaction",
      "--ui-test-device-input-unknown", "-AppleLanguages", "(en)",
    ], resetDeviceNames: false)
    select("app.navigation.device", in: app)
    let preview = app.buttons["device.preview.toggle"]
    XCTAssertTrue(preview.waitForExistenceFast(timeout: 10))
    preview.click()
    XCTAssertTrue(element("device.screen.image", in: app).waitForExistenceFast(timeout: 10))
    XCTAssertFalse(app.buttons["device.capture"].isEnabled)
    XCTAssertFalse(app.buttons["device.record.start"].isEnabled)
    XCTAssertFalse(app.buttons["device.keyboard.tap"].isEnabled)
    preview.click()
    let focus = app.buttons["device.keyboard.focus"]
    let ready = NSPredicate(format: "enabled == true")
    expectation(for: ready, evaluatedWith: focus)
    waitForExpectations(timeout: 10)
    scrollIntoView(focus, in: app)
    focus.click()
    XCTAssertTrue(element("device.screen.surface", in: app).isHittable)
    XCTAssertLessThanOrEqual(
      element("device.screen.surface", in: app).frame.maxY,
      element("device.frame.age", in: app).frame.minY,
      "The whole picture must fit above the footer when keyboard focus returns to it")
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    assertDisplayed(element("device.keyboard.position", in: app), equals: "X 561 · Y 960")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(element("device.stale.badge", in: app).waitForExistenceFast(timeout: 5))
    XCTAssertFalse(app.buttons["device.keyboard.tap"].isEnabled)
    XCTAssertTrue(element("device.log.entry", in: app).exists)
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = "Device keyboard input unknown after stopped preview"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
  }

  // MARK: - One launch per language

  // MARK: - Helpers

  /// Flash exposes one full-label disclosure button, matching the established
  /// Job Inspector interaction instead of macOS's arrow-only hit region.
  func toggleFlashDetails(
    in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if element("flash.availability.status", in: app).exists { return }
    let details = element("flash.workspace.details", in: app)
    XCTAssertTrue(details.exists, file: file, line: line)
    XCTAssertGreaterThan(details.frame.height, 1, file: file, line: line)
    details.click()
    XCTAssertTrue(
      element("flash.availability.status", in: app).waitForExistenceFast(timeout: 5),
      "Flash details must expand after one full-label activation", file: file, line: line)
  }

  /// Sidebar rows expose one full-width native navigation element. Its name,
  /// identifier and pointer frame stay together even after selection, so
  /// assistive technology can activate the same target a person sees.
  func select(
    _ identifier: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let row = element(identifier, in: app)
    XCTAssertTrue(
      row.waitForExistenceFast(timeout: 10), "sidebar must expose \(identifier)",
      file: file, line: line)
    XCTAssertGreaterThan(
      row.frame.width, 1, "sidebar target must have a clickable width", file: file, line: line)
    XCTAssertGreaterThan(
      row.frame.height, 1, "sidebar target must have a clickable height", file: file, line: line)
    let windowFrame = app.windows.firstMatch.frame
    let toolbar = app.toolbars.firstMatch
    let contentMinY = toolbar.exists ? toolbar.frame.maxY : windowFrame.minY
    let contentFrame = CGRect(
      x: windowFrame.minX, y: contentMinY,
      width: windowFrame.width, height: max(0, windowFrame.maxY - contentMinY))
    let visibleFrame = row.frame.intersection(contentFrame)
    if !visibleFrame.isNull, visibleFrame.height > 1 {
      let normalizedY = (visibleFrame.midY - row.frame.minY) / row.frame.height
      row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)).click()
      return
    }

    // macOS 26 can report NavigationSplitView's AX child at its unconstrained
    // ideal height even though the AppKit window and rendered sidebar remain
    // correctly clipped. Focus the visible first row, then use the List's
    // native keyboard selection instead of synthesizing an off-window click.
    let items = [
      "app.navigation.overview", "app.navigation.flash", "app.navigation.debug",
      "app.navigation.uiDump", "app.navigation.trace", "app.navigation.device",
      "app.navigation.diagnostics", "app.navigation.history",
    ]
    guard let index = items.firstIndex(of: identifier) else {
      XCTFail("unknown sidebar item \(identifier)", file: file, line: line)
      return
    }
    let overviewRow = element("app.navigation.overview", in: app)
    XCTAssertTrue(overviewRow.exists, file: file, line: line)
    let focusPoint = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: overviewRow.frame.midX - windowFrame.minX,
          dy: contentMinY - windowFrame.minY + 35))
    focusPoint.click()
    for _ in items {
      app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
    }
    for _ in 0..<index {
      app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    }
  }

  /// NavigationSplitView occasionally reports every internal element at its
  /// unconstrained ideal-height origin. Horizontal coordinates remain exact;
  /// the visible Overview row gives us the vertical translation back into the
  /// real window without hard-coding a screen position for the target.
  func clickCorrectingNavigationSplitAXOffset(
    _ element: XCUIElement, in app: XCUIApplication
  ) {
    // Coordinate clicks must target this App even if another desktop window
    // became foreground between assertions. Do not close or alter that app.
    app.activate()
    let window = app.windows.firstMatch
    let windowFrame = window.frame
    let toolbar = app.toolbars.firstMatch
    let contentMinY = toolbar.exists ? toolbar.frame.maxY : windowFrame.minY
    // A row with a context menu is exposed as a native menu-bearing element
    // rather than an AXCell on current macOS. Its stable identifier and frame
    // are still the correct anchor, so do not depend on the private nesting.
    let overviewCell = self.element("app.navigation.overview", in: app)
    XCTAssertTrue(overviewCell.exists)
    let expectedOverviewMidY = contentMinY + 35
    let verticalCorrection = expectedOverviewMidY - overviewCell.frame.midY
    window.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: element.frame.midX - windowFrame.minX,
          dy: element.frame.midY + verticalCorrection - windowFrame.minY)
      )
      .click()
  }

  /// SwiftUI renders most of these strings into the accessibility *value*, and
  /// section headings into the label, so both are considered.
  func displayedValues(for element: XCUIElement) -> [String] {
    // A filtered detail can leave the hierarchy before its replacement is
    // inserted. Reading label/value on a missing element raises an XCTest
    // snapshot failure before assertDisplayed can evaluate its predicate.
    guard element.exists else { return [] }
    return [element.label, element.value as? String].compactMap { $0 }
  }

  func displayedText(for element: XCUIElement) -> String {
    displayedValues(for: element).joined(separator: " ")
  }

  func assertDisplayed(
    _ element: XCUIElement, equals expected: String,
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
  ) {
    // Most callers assert a snapshot that is already stable. XCTWaiter polls
    // on a coarse cadence even when the first accessibility read matches, so
    // take the synchronous fast path and reserve polling for real transitions.
    if displayedValues(for: element).contains(expected) { return }
    let matches = NSPredicate { [weak self] _, _ in
      self?.displayedValues(for: element).contains(expected) ?? false
    }
    let result = XCTWaiter.wait(
      for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
    XCTAssertTrue(
      result == .completed || displayedValues(for: element).contains(expected),
      "expected \(expected), got: \(displayedText(for: element))", file: file, line: line)
  }

  func assertDisplayed(
    _ element: XCUIElement, oneOf expected: [String],
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line
  ) {
    if expected.contains(where: { displayedValues(for: element).contains($0) }) { return }
    let matches = NSPredicate { [weak self] _, _ in
      guard let self else { return false }
      let actual = displayedValues(for: element)
      return expected.contains(where: actual.contains)
    }
    let result = XCTWaiter.wait(
      for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
    XCTAssertTrue(
      result == .completed
        || expected.contains(where: { displayedValues(for: element).contains($0) }),
      "expected one of \(expected), got: \(displayedText(for: element))",
      file: file, line: line)
  }

  func assertTimeline(
    _ expected: [String], in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let entries = app.staticTexts
      .matching(identifier: "history.detail.timeline.entries")
      .allElementsBoundByIndex
    let actual = entries.compactMap { entry -> String? in
      if let value = entry.value as? String, !value.isEmpty { return value }
      return entry.label.isEmpty ? nil : entry.label
    }
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  /// `isHittable` is true for a control whose centre is barely inside a scroll
  /// view even when the control is clipped by the toolbar or global Job bar.
  /// Pick the scroll view in the target's horizontal lane and require the full
  /// frame to sit inside a padded viewport before clicking it.
  func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
    let targetX = element.frame.midX
    let hosts = app.scrollViews.allElementsBoundByIndex.filter { host in
      let frame = host.frame
      // Require a height as well as a width. The tie-break below is smallest
      // area, so a zero-height scroll view does not merely compete for the
      // host slot — it always wins it, at area zero, and then cannot be
      // scrolled or hit. F59 recorded one such host on an older main
      // ({{252.0, 441.0}, {648.0, 0.0}}), surfacing as "Unable to find hit
      // point for ScrollView", which reads like a product defect and is not.
      //
      // This is a guard, not a repair of anything currently observable: no
      // collapsed candidate reproduces on today's main, and adding the check
      // changes no measured outcome. It is here because the selection rule is
      // wrong on its own terms, not because a test is red today.
      guard frame.width > 0, frame.height > 0 else { return false }
      guard frame.minX <= targetX && targetX <= frame.maxX else { return false }
      // Recovery banners, workspace content and the global inspector can
      // share an x range. Scroll the target's ancestor, not a smaller,
      // unrelated viewport above it.
      guard !element.identifier.isEmpty else { return true }
      return host.descendants(matching: .any)
        .matching(identifier: element.identifier).firstMatch.exists
    }
    guard
      let host = hosts.min(by: { lhs, rhs in
        lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
      })
    else { return }

    // Large steps: every scroll spends a full idle-wait + snapshot round
    // trip, so fewer, bigger deltas are what make this affordable.
    var attempts = 0
    while attempts < 12 {
      let target = element.frame
      let viewport = host.frame
        .intersection(app.windows.firstMatch.frame)
        .insetBy(dx: 0, dy: 60)
      if target.minY >= viewport.minY && target.maxY <= viewport.maxY && element.isHittable {
        return
      }
      let overshoot = target.maxY - viewport.maxY
      host.scroll(byDeltaX: 0, deltaY: overshoot > 0 ? -max(160, min(overshoot, 600)) : 160)
      attempts += 1
    }
  }

  /// SwiftUI omits far-offscreen children of the Flash ScrollView from the AX
  /// snapshot. Scroll the workspace first, then use the frame-aware helper
  /// once the stable identifier has entered the accessibility tree.
  func scrollWorkspaceUntilExists(
    _ element: XCUIElement, in app: XCUIApplication, deltaY: CGFloat,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if element.exists { return }
    let window = app.windows.firstMatch.frame
    let hosts = app.scrollViews.allElementsBoundByIndex.filter {
      $0.frame.width > window.width * 0.5 && $0.frame.minX > window.minX + 200
    }
    guard let host = hosts.min(by: { $0.frame.width < $1.frame.width }) else {
      XCTFail("Flash workspace ScrollView is missing", file: file, line: line)
      return
    }
    for _ in 0..<6 {
      host.scroll(byDeltaX: 0, deltaY: deltaY)
      if element.exists { return }
    }
    XCTFail("offscreen Flash element did not enter the AX tree", file: file, line: line)
  }

  func launch(
    arguments: [String] = [], resetDeviceNames: Bool = true
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning {
      app.terminate()
    }
    var launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-hdc-diagnostics",
      // Without this the App builds the real updater and decides what to
      // show by checking for updates, which is neither deterministic nor
      // free of network effects. A test that wants a different update state
      // passes its own argument; this only makes the default one declared.
      "--ui-test-auto-update-idle",
      // Scene storage survives `-ApplePersistenceIgnoreState`, so without this
      // a sweep lands on whichever workspace the previous run left selected
      // and its Overview assertions fail against, say, Trace.
      "--ui-test-reset-shell-selection",
    ]
    if resetDeviceNames { launchArguments.append("--ui-test-reset-device-names") }
    app.launchArguments = launchArguments + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launchArguments += ["--ui-test-window-geometry"]
    app.launch()
    app.activate()
    let openedInitialWindow = app.windows.firstMatch.waitForExistenceFast(timeout: 2)
    if !openedInitialWindow {
      app.typeKey("n", modifierFlags: .command)
      XCTAssertTrue(
        app.windows.firstMatch.waitForExistenceFast(timeout: 5), "ArkDeck must create a test window"
      )
    }
    return app
  }

  func openGeneralSettings(in app: XCUIApplication) {
    openSettings(in: app)
    let general = app.buttons["General"]
    XCTAssertTrue(general.waitForExistenceFast(timeout: 10))
    if !element("settings.general.appIcon.keycap", in: app).exists {
      general.click()
    }
    XCTAssertTrue(
      element("settings.general.appIcon.keycap", in: app).waitForExistenceFast(timeout: 10))
  }

  /// Trace's embedded sections use their own table in both locales.
  func assertTraceSettings(
    in app: XCUIApplication, title: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    settingsPane(title, in: app).click()
    XCTAssertTrue(
      element("settings.trace.section", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    let chinese = title == "跟踪"
    let cache = app.radioButtons[chinese ? "缓存" : "Cache"].firstMatch
    XCTAssertTrue(cache.waitForExistenceFast(timeout: 10), file: file, line: line)
    cache.click()
    XCTAssertTrue(
      app.staticTexts[chinese ? "按内容寻址的缓存" : "Content-addressed Cache"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    let licenses = app.radioButtons[chinese ? "许可证" : "Licenses"].firstMatch
    XCTAssertTrue(licenses.waitForExistenceFast(timeout: 10), file: file, line: line)
    licenses.click()
    XCTAssertTrue(
      app.staticTexts[chinese ? "开源许可证" : "Open Source Licenses"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
  }

  /// A Settings pane button, addressed inside the Settings window.
  ///
  /// `app.buttons["Diagnostics"]` used to be unambiguous. It stopped being so
  /// when the shell gained a Diagnostics sidebar item with the same title:
  /// XCUITest then refuses the click rather than guessing which window meant
  /// it. Scope to the Settings window without requiring a private Toolbar AX
  /// ancestor; window ownership remains stable across native tab layouts.
  func settingsPane(
    _ title: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) -> XCUIElement {
    let window = app.windows["com_apple_SwiftUI_Settings_window"]
    XCTAssertTrue(
      window.waitForExistenceFast(timeout: 10), "Settings window must be open",
      file: file, line: line)
    let pane = window.buttons[title]
    XCTAssertTrue(
      pane.waitForExistenceFast(timeout: 10), "Settings pane \(title) must exist",
      file: file, line: line)
    return pane
  }

  func openSettings(in app: XCUIApplication) {
    let settings = element("app.toolbar.openSettings", in: app)
    XCTAssertTrue(settings.waitForExistenceFast(timeout: 10))
    settings.click()
  }
}
