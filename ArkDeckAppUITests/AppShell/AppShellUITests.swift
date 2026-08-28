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
  private static let realDeviceStartupEnvironmentKey =
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

  func testHistorySavedFilterRestoresActivityAndExposesOneFilterSet() {
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "-AppleLanguages", "(en)",
      ])
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

  func testHistoryActivityFilterSurvivesNarrowWindowAndSavedFilter() {
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "-AppleLanguages", "(en)",
      ])
    // macOS can preserve the last frame even with persistence disabled,
    // especially after an interrupted run. Establish the viewport we test.
    Self.resizeHistoryWindow(in: app, to: 1180)
    addTeardownBlock {
      await MainActor.run {
        if app.windows.firstMatch.exists {
          Self.resizeHistoryWindow(in: app, to: 1180)
        }
      }
    }
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

  func testHistoryReopensExactFixtureContextWithoutReplay() {
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "-AppleLanguages", "(en)",
      ])
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

  func testRecoveryBannerOpensExactJobInBothLanguages() {
    for language in ["(en)", "(zh-Hans)"] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "-AppleLanguages", language,
      ])
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
      app.terminate()
    }
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
    element("device.record.shrink", in: app).click()
    XCTAssertTrue(app.staticTexts["22 frames"].exists)
    XCTAssertFalse(element("device.record.stage", in: app).exists)
    assertDisplayed(start, equals: "Record")
    app.terminate()
  }

  // MARK: - One launch per language

  func testWorkspaceNamesAndEmptyStatesInBothLanguages() {
    for (language, capture, emptyTitle, diagnosticsEmptyTitle) in [
      ("(en)", "Get screenshot", "No screenshot yet", "No session open"),
      ("(zh-Hans)", "获取截图", "尚未获取截图", "尚无诊断会话"),
    ] {
      let app = launch(
        arguments: [
          "--ui-test-runtime-history", "--ui-test-devices", "-AppleLanguages", language,
        ], resetDeviceNames: false)
      let device = element("app.navigation.device", in: app)
      assertDisplayed(device, equals: "Device")
      select("app.navigation.device", in: app)
      XCTAssertTrue(element("device.screen.empty", in: app).waitForExistenceFast(timeout: 10))
      XCTAssertTrue(app.staticTexts[emptyTitle].exists)
      assertDisplayed(app.buttons["device.capture"], equals: capture)
      XCTAssertFalse(element("device.screen.surface", in: app).exists)
      XCTAssertFalse(app.staticTexts["Toolkit"].exists)

      let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      screenshot.name = "Device workspace \(language)"
      screenshot.lifetime = .keepAlways
      add(screenshot)

      assertDisplayed(element("app.navigation.diagnostics", in: app), equals: "Diagnostics")
      select("app.navigation.diagnostics", in: app)
      assertDisplayed(app.staticTexts["diagnostics.workspace.title"], equals: "Diagnostics")
      XCTAssertTrue(element("diagnostics.session.empty", in: app).exists)
      XCTAssertTrue(app.staticTexts[diagnosticsEmptyTitle].exists)
      // The fixture has an adopted device. That fact alone cannot turn a
      // disconnected recorder into a running session or save host markers.
      XCTAssertFalse(app.buttons["diagnostics.capture.arm"].isEnabled)
      XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
      XCTAssertTrue(element("diagnostics.capture.unavailable", in: app).exists)
      XCTAssertTrue(app.staticTexts["diagnostic_session_capture_not_connected"].exists)
      XCTAssertFalse(element("diagnostics.capture.markCount", in: app).exists)

      let diagnosticsScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      diagnosticsScreenshot.name = "Diagnostics workspace \(language)"
      diagnosticsScreenshot.lifetime = .keepAlways
      add(diagnosticsScreenshot)
      app.terminate()
    }
  }

  func testEnglishSweepOfEveryWorkspace() {
    sweep(
      language: "(en)",
      overview: Overview(
        server: "Healthy", trust: "Ready", channel: "Unverified", attention: "1 item",
        attentionNone: "None",
        attentionClear: "Nothing needs attention in the current diagnostics."),
      flash: Flash(
        availability: "AVAILABLE — Runtime can materialize flash.full-restore@1",
        modeBadge: "PLANNED — no deviceMutation or destructive dispatch",
        target: "target-fixture-dayu200",
        emptyPlan: "No exact plan yet",
        prepareAction: "Prepare exact plan",
        imageBlocker: "Choose an image bundle before preparing a plan.",
        runtimeState: "Interrupted",
        runtimeResult:
          "Device effect is unknown. Do not treat this Job as finished or start another flash.",
        runtimeRecovery:
          "The device effect is unknown. Keep the current device state unchanged when possible. "
          + "Do not start another flash until the outstanding step has been reconciled through "
          + "an approved Runtime path.",
        noSubmission:
          "Plan only: every deviceMutation and destructive step remains "
          + "notExecuted(planned). No operation was submitted.",
        runtimeRunningState: "Running",
        runtimeRunningResult:
          "Runtime is still processing this Job. Progress is stage-based; "
          + "no percentage is fabricated.",
        runtimeSucceededState: "Succeeded",
        runtimeSucceededResult:
          "Runtime reports success after the Flash and postflight checks."),
      workspaces: Workspaces(
        inspectorShow: "Show job inspector",
        inspectorRuntimeFacts: "Runtime facts",
        debugPanels: [
          "Build Artifact", "Bounded HiLog capture", "HAP package", "Forward / reverse rules",
          "Provider invocation disclosure",
        ],
        viewerEmptyTitle: "No verified capture",
        traceAvailable: "Ready",
        traceUnavailable: "Unavailable",
        settingsPanes: [
          "General", "Toolchains", "Servers", "Storage", "Updates", "Diagnostics", "Trace",
        ]),
      history: History(
        readOnlyNote:
          "History only reads Runtime state. Opening a related tool never submits, cancels, or retries this Job.",
        outcomeUnknown: "Outcome unknown — this Job's effect on the device was never confirmed.",
        waitingForHuman: "Waiting for a person to act.",
        interruptedRowState: "Interrupted · outcome unknown",
        emptyTitle: "No Runtime Jobs Yet",
        emptyDescription: "ArkDeck Runtime has recorded no Jobs on this host.",
        residue: "2 outstanding residue items."))
  }

  func testSimplifiedChineseLocalizationSweep() {
    localizedSweep(
      language: "(zh-Hans)",
      overview: Overview(
        server: "正常", trust: "已就绪", channel: "未验证", attention: "1 项",
        attentionNone: "无",
        attentionClear: "当前诊断中没有需要处理的事项。"),
      flash: Flash(
        availability: "AVAILABLE — Runtime 可生成 flash.full-restore@1 计划",
        modeBadge: "PLANNED — 不派发 deviceMutation 或 destructive 步骤",
        target: "target-fixture-dayu200",
        emptyPlan: "尚未生成精确计划",
        prepareAction: "生成精确计划",
        imageBlocker: "请先选择镜像包，再生成计划。",
        runtimeState: "已中断",
        runtimeResult: "设备影响未知。不要把此 Job 视为完成，也不要开始下一次刷机。",
        runtimeRecovery:
          "设备影响未知。条件允许时请保持设备当前状态；在通过已批准的 Runtime 路径核对未决步骤前，"
          + "不要开始下一次刷机。",
        noSubmission:
          "仅计划：所有 deviceMutation 与 destructive 步骤均保持 notExecuted(planned)，"
          + "未提交任何操作。",
        runtimeRunningState: "正在执行",
        runtimeRunningResult: "Runtime 仍在处理此 Job。进度按真实阶段展示，不生成虚假百分比。",
        runtimeSucceededState: "成功",
        runtimeSucceededResult: "Runtime 报告刷机及 postflight 检查成功。"),
      workspaces: Workspaces(
        inspectorShow: "展开 Job 检查器",
        inspectorRuntimeFacts: "Runtime 事实",
        debugPanels: [
          "编译产物", "有界 HiLog 采集", "HAP 安装包", "Forward / reverse 规则",
          "Provider 调用披露",
        ],
        viewerEmptyTitle: "没有已验证的 capture",
        traceAvailable: "可以抓取",
        traceUnavailable: "暂时无法抓取",
        settingsPanes: ["通用", "工具链", "服务器", "存储", "更新", "诊断", "跟踪"]),
      history: History(
        readOnlyNote: "History 只读取 Runtime 状态。打开相关工具不会提交、取消或重试此 Job。",
        outcomeUnknown: "结果未知——此 Job 对设备的影响从未被确认。",
        waitingForHuman: "等待人工处理。",
        interruptedRowState: "已中断 · 结果未知",
        emptyTitle: "尚无 Runtime Job",
        emptyDescription: "ArkDeck Runtime 在本机尚未记录任何 Job。",
        residue: "有 2 项未清理残留。"))
  }

  func testReferenceLayoutsInEnglishAndSimplifiedChinese() {
    for (language, localeName) in [("(en)", "en"), ("(zh-Hans)", "zh-Hans")] {
      try? "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(
        arguments: [
          "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
          "--ui-test-device-poll-fast", "--ui-test-fixture-state",
          fixtureStateFileURL.path, "-AppleLanguages", language,
        ])
      let adoptedDevice = element("device.row.150100469346864", in: app)
      XCTAssertTrue(adoptedDevice.waitForExistenceFast(timeout: 10))
      assertDeviceDetailLayout(
        in: app, adoptedDevice: adoptedDevice, localeName: localeName,
        file: #filePath, line: #line)

      if localeName == "en" {
        assertFlashLayout(in: app, file: #filePath, line: #line)
      }
      app.terminate()
    }
  }

  func testApplicationIconSwitchesFromSettings() {
    let app = launch(arguments: ["-AppleLanguages", "(en)"])

    openGeneralSettings(in: app)
    let keycapIcon = element("settings.general.appIcon.keycap", in: app)
    let waveformIcon = element("settings.general.appIcon.waveform", in: app)
    XCTAssertTrue(keycapIcon.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(waveformIcon.exists)

    keycapIcon.click()
    XCTAssertEqual(
      keycapIcon.value as? String, "Selected",
      "Selecting an icon must expose its state")

    app.terminate()
    let reopened = launch(arguments: ["-AppleLanguages", "(en)"])
    openGeneralSettings(in: reopened)
    let persistedKeycap = element("settings.general.appIcon.keycap", in: reopened)
    XCTAssertTrue(persistedKeycap.waitForExistenceFast(timeout: 10))
    XCTAssertEqual(
      persistedKeycap.value as? String, "Selected",
      "The selected icon must persist across launches")

    let restoredWaveform = element("settings.general.appIcon.waveform", in: reopened)
    restoredWaveform.click()
    XCTAssertEqual(restoredWaveform.value as? String, "Selected")
  }

  func testRemoteBuildSourceSettingsSurfaceIsReachableAndFailClosed() {
    let app = launch(arguments: ["-AppleLanguages", "(en)"])
    openSettings(in: app)

    let servers = app.buttons["Servers"]
    XCTAssertTrue(servers.waitForExistenceFast(timeout: 10))
    servers.click()
    XCTAssertTrue(app.buttons["settings.remoteSources.add"].waitForExistenceFast(timeout: 10))
    XCTAssertTrue(app.buttons["settings.remoteSources.refresh"].exists)

    app.buttons["settings.remoteSources.add"].click()
    XCTAssertTrue(
      element("settings.remoteSources.field.host", in: app).waitForExistenceFast(timeout: 10))
    XCTAssertTrue(element("settings.remoteSources.field.root", in: app).exists)
    let authentication = element("settings.remoteSources.field.authentication", in: app)
    XCTAssertTrue(authentication.exists)
    authentication.click()
    let privateKey = app.menuItems["OpenSSH private key"]
    XCTAssertTrue(privateKey.waitForExistenceFast(timeout: 5))
    privateKey.click()
    XCTAssertTrue(
      app.staticTexts["System default (id_rsa → id_ed25519)"].waitForExistenceFast(timeout: 5),
      "private-key authentication should not require selecting a replacement key")
    XCTAssertTrue(app.buttons["settings.remoteSources.choosePrivateKey"].exists)
    XCTAssertTrue(app.buttons["settings.remoteSources.testConnection"].exists)
    XCTAssertFalse(
      app.buttons["settings.remoteSources.save"].isEnabled,
      "an unverified server must not be saved")
    app.buttons["settings.remoteSources.cancel"].click()
  }

  func testTraceSettingsCacheAndLicensesAreReachableInBothLanguages() {
    for (language, title) in [("(en)", "Trace"), ("(zh-Hans)", "跟踪")] {
      let app = launch(arguments: ["-AppleLanguages", language])
      openSettings(in: app)
      assertTraceSettings(in: app, title: title)
      app.terminate()
    }
  }

  func testTraceViewerAndShortcutHelpUseBothLanguages() {
    for (language, emptyTitle, openTitle, helpTitle, timelineTitle, searchTitle) in [
      ("(en)", "Open a trace", "Open Trace…", "Trace Keyboard Shortcuts", "Timeline", "Search TID, thread, or slice"),
      ("(zh-Hans)", "打开 Trace", "打开 Trace…", "Trace 键盘快捷键", "时间轴", "搜索 TID、线程或 slice"),
    ] {
      let app = launch(arguments: ["-AppleLanguages", language])
      select("app.navigation.trace", in: app)
      let openViewer = app.buttons["trace.openViewer"]
      XCTAssertTrue(openViewer.waitForExistenceFast(timeout: 10))
      scrollIntoView(openViewer, in: app)
      openViewer.click()
      let viewer = app.windows["Trace Viewer"]
      XCTAssertTrue(viewer.waitForExistenceFast(timeout: 10))
      XCTAssertTrue(viewer.staticTexts[emptyTitle].waitForExistenceFast(timeout: 10))
      XCTAssertTrue(viewer.buttons[openTitle].exists)
      let search = viewer.textFields[searchTitle]
      XCTAssertTrue(search.exists, "search has a localized accessibility label")
      XCTAssertEqual(search.placeholderValue, searchTitle)
      let empty = XCTAttachment(screenshot: viewer.screenshot())
      empty.name = "Native Trace Viewer empty \(language)"
      empty.lifetime = .keepAlways
      add(empty)

      let helpMenu = app.menuBars.menuBarItems.matching(
        NSPredicate(format: "title IN %@", ["Help", "帮助"])).firstMatch
      XCTAssertTrue(helpMenu.waitForExistenceFast(timeout: 5))
      helpMenu.click()
      let shortcuts = helpMenu.menuItems[helpTitle]
      XCTAssertTrue(shortcuts.waitForExistenceFast(timeout: 5))
      shortcuts.click()
      let help = app.windows[helpTitle]
      XCTAssertTrue(help.waitForExistenceFast(timeout: 10))
      assertDisplayed(
        help.staticTexts["trace.shortcuts.section.Timeline"], equals: timelineTitle)
      let reference = XCTAttachment(screenshot: help.screenshot())
      reference.name = "Native Trace shortcut catalog \(language)"
      reference.lifetime = .keepAlways
      add(reference)
      app.terminate()
    }
  }

  func testDeviceContextMenuRenamesAndRefreshesDeviceState() {
    try? "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    let fixtureArguments = [
      "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
      "--ui-test-device-poll-fast", "--ui-test-fixture-state",
      fixtureStateFileURL.path,
    ]
    let app = launch(arguments: fixtureArguments + ["-AppleLanguages", "(en)"])
    let adoptedDevice = element("device.row.150100469346864", in: app)
    let unauthorizedDevice = element("device.row.7f2c091a445e21", in: app)
    XCTAssertTrue(adoptedDevice.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(unauthorizedDevice.exists)

    adoptedDevice.rightClick()
    let renameMenuItem = app.menuItems["Rename…"]
    let recheckMenuItem = app.menuItems["Re-check"]
    XCTAssertTrue(renameMenuItem.waitForExistenceFast(timeout: 5))
    XCTAssertTrue(recheckMenuItem.exists)
    renameMenuItem.click()

    // SwiftUI's native alert preserves the field's visible localized label,
    // but AppKit does not forward its SwiftUI accessibility identifier.
    let deviceName = app.textFields.firstMatch
    XCTAssertTrue(deviceName.waitForExistenceFast(timeout: 5))
    deviceName.click()
    deviceName.typeKey("a", modifierFlags: .command)
    deviceName.typeText("Lab DAYU200")
    let commitRename = app.buttons["device.rename.commit"]
    XCTAssertTrue(commitRename.isEnabled)
    commitRename.click()
    XCTAssertTrue(
      displayedText(for: adoptedDevice).contains("Lab DAYU200"),
      "renaming must update the device's visible label")

    // The custom display name survives an App relaunch while the stable row
    // identity remains the connect key. Test launches reset aliases by default;
    // this one deliberately preserves the value written above.
    app.terminate()
    let reopened = launch(
      arguments: fixtureArguments + ["-AppleLanguages", "(zh-Hans)"],
      resetDeviceNames: false)
    let persistedDevice = element("device.row.150100469346864", in: reopened)
    XCTAssertTrue(persistedDevice.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(displayedText(for: persistedDevice).contains("Lab DAYU200"))
    persistedDevice.rightClick()
    XCTAssertTrue(reopened.menuItems["重命名…"].waitForExistenceFast(timeout: 5))
    XCTAssertTrue(reopened.menuItems["重新检测"].exists)
    reopened.typeKey(.escape, modifierFlags: [])

    let refreshedUnauthorized = element("device.row.7f2c091a445e21", in: reopened)
    assertDisplayed(refreshedUnauthorized, equals: "需要信任")
    writeFixtureState("--ui-test-device-authorized", in: reopened)
    refreshedUnauthorized.rightClick()
    let refreshAfterStateChange = reopened.menuItems["重新检测"]
    XCTAssertTrue(refreshAfterStateChange.waitForExistenceFast(timeout: 5))
    XCTAssertTrue(refreshAfterStateChange.isEnabled)
    refreshAfterStateChange.click()
    assertDisplayed(refreshedUnauthorized, equals: "已授权 · 未接管", timeout: 10)
  }

  private struct Overview {
    let server: String
    let trust: String
    let channel: String
    let attention: String
    let attentionNone: String
    let attentionClear: String
  }

  private struct Workspaces {
    let inspectorShow: String
    let inspectorRuntimeFacts: String
    let debugPanels: [String]
    let viewerEmptyTitle: String
    let traceAvailable: String
    let traceUnavailable: String
    let settingsPanes: [String]
  }

  private struct Flash {
    let availability: String
    let modeBadge: String
    let target: String
    let emptyPlan: String
    let prepareAction: String
    let imageBlocker: String
    let runtimeState: String
    let runtimeResult: String
    let runtimeRecovery: String
    let noSubmission: String
    let runtimeRunningState: String
    let runtimeRunningResult: String
    let runtimeSucceededState: String
    let runtimeSucceededResult: String
  }

  private struct History {
    let readOnlyNote: String
    let outcomeUnknown: String
    let waitingForHuman: String
    let interruptedRowState: String
    let emptyTitle: String
    let emptyDescription: String
    let residue: String
  }

  /// The history fixture reads its state from this file for the same reason
  /// the HDC one does: a sweep has to walk more than one Runtime state without
  /// spending another launch on it.
  private var fixtureStateFileURL: URL {
    let name = "arkdeck-appshell-fixture-state-\(ProcessInfo.processInfo.processIdentifier).txt"
    return FileManager.default.temporaryDirectory.appending(path: name)
  }

  func testDefaultWindowReportsNativeGeometryAndDoesNotOpenAtMinimumSize() {
    let app = launch(arguments: ["-AppleLanguages", "(en)"])
    assertDefaultWindowGeometry(in: app)
  }

  /// Presentation fixture only. A prepared plan does not keep execution
  /// available after the Runtime reports a closed hardware qualification gate.
  func testFlashAvailabilityRefreshBlocksACachedPlanInBothLanguages() throws {
    let emptyHistory = "--ui-test-runtime-history-empty"
    for language in ["(en)", "(zh-Hans)"] {
      try emptyHistory.write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(arguments: [
        "--ui-test-flash", "--ui-test-flash-plan",
        "--ui-test-runtime-history", "--ui-test-runtime-history-empty", "--ui-test-devices",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
      ])
      select("app.navigation.flash", in: app)
      let submit = element("flash.execute.submit", in: app)
      XCTAssertTrue(submit.waitForExistenceFast(timeout: 15))
      XCTAssertTrue(submit.isEnabled)
      let image = element("flash.image.value", in: app)
      let selectedImage = displayedText(for: image)
      toggleFlashDetails(in: app, file: #filePath, line: #line)
      writeFixtureState("\(emptyHistory)\n--ui-test-flash-hardware-gated", in: app)
      app.buttons["flash.refresh"].click()
      let blocker = element("flash.execute.prerequisiteBlocker", in: app)
      XCTAssertTrue(blocker.waitForExistenceFast(timeout: 10))
      XCTAssertFalse(submit.exists, "the cached plan must not retain its destructive action")
      XCTAssertTrue(displayedText(for: blocker).contains("hardwareGated"))
      XCTAssertEqual(displayedText(for: image), selectedImage)
      XCTAssertFalse(element("flash.execute.terminal", in: app).exists)
      let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      attachment.name = "flash-hardware-gated-cached-plan-\(language)"
      attachment.lifetime = .keepAlways
      add(attachment)

      writeFixtureState(emptyHistory, in: app)
      app.buttons["flash.refresh"].click()
      XCTAssertTrue(submit.waitForExistenceFast(timeout: 10))
      XCTAssertTrue(submit.isEnabled)
      XCTAssertFalse(blocker.exists)
      app.terminate()
    }
  }

  /// Canonical records must drive the same read-only activity, progress and
  /// unknown-outcome protections as retained compatibility history.
  func testCanonicalFlashHistoryStatesInBothLanguages() throws {
    let canonical = "--ui-test-runtime-flash-canonical"
    for language in ["(en)", "(zh-Hans)"] {
      try "\(canonical)\n--ui-test-runtime-flash-newer-observe".write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(arguments: [
        "--ui-test-flash", "--ui-test-runtime-history", "--ui-test-devices",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
      ])
      select("app.navigation.flash", in: app)
      XCTAssertTrue(element("flash.runtime.attention", in: app).waitForExistenceFast(timeout: 10))
      XCTAssertFalse(element("flash.execute.submit", in: app).exists)
      app.buttons["flash.runtime.openHistory"].click()
      assertDisplayed(element("history.detail.job", in: app), equals: "job-fixture-0002")
      select("app.navigation.flash", in: app)
      toggleFlashDetails(in: app, file: #filePath, line: #line)
      assertDisplayed(element("flash.runtime.jobID", in: app), equals: "job-fixture-0002")

      writeFixtureState("\(canonical)\n--ui-test-runtime-flash-running", in: app)
      app.buttons["flash.refresh"].click()
      XCTAssertTrue(element("flash.workspace.progress", in: app).waitForExistenceFast(timeout: 10))
      XCTAssertFalse(element("flash.runtime.attention", in: app).exists)
      assertDisplayed(element("flash.runtime.jobID", in: app), equals: "job-fixture-flash-running")

      writeFixtureState(
        "\(canonical)\n--ui-test-runtime-flash-succeeded\n--ui-test-runtime-flash-retained-history",
        in: app)
      app.buttons["flash.refresh"].click()
      assertDisplayed(element("flash.runtime.jobID", in: app), equals: "job-fixture-flash-succeeded")
      XCTAssertFalse(element("flash.workspace.progress", in: app).exists)
      XCTAssertFalse(element("flash.runtime.attention", in: app).exists)
      XCTAssertTrue(element("flash.image.choose", in: app).exists)
      scrollIntoView(element("flash.runtime.jobID", in: app), in: app)
      let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      attachment.name = "canonical-flash-history-\(language)"
      attachment.lifetime = .keepAlways
      add(attachment)
      let openRecord = app.buttons["flash.runtime.openHistory"]
      scrollIntoView(openRecord, in: app)
      openRecord.click()
      assertDisplayed(
        element("history.detail.job", in: app), equals: "job-fixture-flash-succeeded")
      XCTAssertTrue(
        element("history.row.state.job-fixture-flash-alias-resolved", in: app).exists,
        "the old unknown must remain inspectable in History")
      app.terminate()
    }
  }

  /// The in-process submit/run fixture never contacts Runtime or a device.
  /// Its detail reader rejects the old alias exactly as production correlation
  /// does, and unverified evidence must not turn matching fields into success.
  func testCanonicalFlashPostflightRequiresVerifiedEvidenceInBothLanguages() throws {
    let state = "--ui-test-flash-loader-unbound\n--ui-test-flash-plan\n--ui-test-runtime-history-empty"
    for (language, success, stopped) in [
      ("(en)", "Flash succeeded", "Flash stopped"),
      ("(zh-Hans)", "刷机成功", "刷机已停止"),
    ] {
      for unverified in [false, true] {
        try state.write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
        var arguments = [
          "--ui-test-flash", "--ui-test-flash-plan", "--ui-test-runtime-history", "--ui-test-devices",
          "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
        ]
        if unverified { arguments.append("--ui-test-flash-postflight-unverified") }
        let app = launch(arguments: arguments)
        select("app.navigation.flash", in: app)
        let submit = element("flash.execute.submit", in: app)
        XCTAssertTrue(submit.waitForExistenceFast(timeout: 15))
        XCTAssertTrue(submit.isEnabled)
        submit.click()
        let terminal = element("flash.execute.terminal", in: app)
        assertDisplayed(terminal, equals: unverified ? stopped : success, timeout: 15)
        assertDisplayed(element("flash.execute.jobId", in: app), equals: "job-ui-fixture-flash")
        XCTAssertTrue(element("flash.postflight.build.match", in: app).exists)
        XCTAssertTrue(element("flash.postflight.binding.match", in: app).exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "canonical-flash-postflight-\(language)-unverified-\(unverified)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
      }
    }
  }

  /// Read-only presentation fixtures: a successful empty RockUSB discovery
  /// must remain distinct from an unreachable Runtime. No device is contacted.
  func testFlashDeviceAccessAbsentAndUnavailableInBothLanguages() throws {
    for (language, absent, unavailable, ready) in [
      ("(en)", "Device is offline or not in Loader mode", "ArkForge RockUSB discovery is unavailable", "Loader device access is ready"),
      ("(zh-Hans)", "设备离线或未进入 Loader 模式", "ArkForge RockUSB 探测不可用", "Loader 设备访问就绪"),
    ] {
      for failed in [false, true] {
        let flag = failed ? "--ui-test-flash-device-access-unavailable" : "--ui-test-flash-device-access-absent"
        try "--ui-test-runtime-history-empty\n\(flag)".write(
          to: fixtureStateFileURL, atomically: true, encoding: .utf8)
        let app = launch(arguments: [
          "--ui-test-flash", "--ui-test-runtime-history", "--ui-test-devices", flag,
          "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
        ])
        select("app.navigation.flash", in: app)
        toggleFlashDetails(in: app)
        let status = element(failed ? "flash.deviceAccess.unavailable" : "flash.deviceAccess.verdict", in: app)
        assertDisplayed(status, equals: failed ? unavailable : absent, timeout: 10)
        XCTAssertFalse(app.staticTexts[ready].exists)
        let reprobe = element("flash.deviceAccess.reprobe", in: app)
        scrollIntoView(reprobe, in: app)
        reprobe.click()
        assertDisplayed(status, equals: failed ? unavailable : absent, timeout: 10)
        scrollIntoView(status, in: app)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "flash-device-access-\(language)-unavailable-\(failed)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
      }
    }
  }

  /// File-picker UI only: these are deliberately not installable packages and
  /// the test never presses Import and run. Device execution has separate evidence.
  func testDebugHAPSelectionAddsHSPRejectsDuplicatesAndClearsInBothLanguages() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-hap-picker-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath().standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let entry = directory.appending(path: "entry.hap")
    let shared = directory.appending(path: "shared.hsp")
    for file in [entry, shared] { try Data("UI selection fixture only".utf8).write(to: file) }

    for language in ["(en)", "(zh-Hans)"] {
      let app = launch(arguments: ["--ui-test-devices", "-AppleLanguages", language])
      select("app.navigation.debug", in: app)
      app.buttons["debug.tab.apps"].click()
      let cleanup = app.popUpButtons["debug.apps.cleanupPolicy"]
      let postRun = app.popUpButtons["debug.apps.postRun"]
      func openPolicyMenu(_ picker: XCUIElement) {
        app.activate()
        scrollIntoView(picker, in: app)
        // On macOS 26, click() synthesized a hit point 21pt above the
        // visible picker. Use its current frame centre; the menu labels
        // and every policy assertion below remain unchanged.
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
      }
      XCTAssertTrue(postRun.waitForExistenceFast(timeout: 15))
      let policyHint = element("debug.apps.runningCleanupHint", in: app)
      XCTAssertFalse(policyHint.exists)
      openPolicyMenu(postRun)
      app.menuItems[language == "(en)" ? "Leave running" : "保持运行"].click()
      XCTAssertTrue(policyHint.waitForExistenceFast(timeout: 5))
      openPolicyMenu(cleanup)
      app.menuItems[language == "(en)" ? "Retain installed app" : "保留已安装应用"].click()
      XCTAssertFalse(policyHint.exists)
      openPolicyMenu(postRun)
      app.menuItems[language == "(en)" ? "Stop Ability" : "停止 Ability"].click()
      XCTAssertFalse(policyHint.exists)
      openPolicyMenu(postRun)
      app.menuItems[language == "(en)" ? "Leave running" : "保持运行"].click()
      XCTAssertFalse(policyHint.exists)
      openPolicyMenu(cleanup)
      app.menuItems[language == "(en)" ? "Uninstall after run" : "运行后卸载"].click()
      XCTAssertTrue(policyHint.waitForExistenceFast(timeout: 5))
      openPolicyMenu(postRun)
      app.menuItems[language == "(en)" ? "Stop Ability" : "停止 Ability"].click()
      XCTAssertFalse(policyHint.exists)
      let addPackage = app.buttons["debug.apps.additional.add"]
      XCTAssertTrue(addPackage.waitForExistenceFast(timeout: 15))
      XCTAssertFalse(addPackage.isEnabled, "an entry HAP must be selected first")
      app.buttons["debug.apps.entry.choose"].click()
      chooseDebugPackage(entry, in: app)
      assertDisplayed(element("debug.apps.entry.name", in: app), equals: "entry.hap")
      XCTAssertTrue(
        app.staticTexts["debug.apps.entry.name"].exists,
        "the selected filename must retain its static-text accessibility role")
      XCTAssertTrue(addPackage.isEnabled)
      scrollIntoView(addPackage, in: app)
      addPackage.click()
      chooseDebugPackage(shared, in: app)
      let remove = app.buttons["debug.apps.additional.remove.0"]
      XCTAssertTrue(remove.waitForExistenceFast(timeout: 10), "the .hsp selection must be retained")
      XCTAssertTrue(remove.label.contains("shared.hsp"))
      assertDisplayed(element("debug.apps.additional.file.0", in: app), equals: "shared.hsp")
      scrollIntoView(addPackage, in: app)
      addPackage.click()
      chooseDebugPackage(shared, in: app)
      let error = element("debug.apps.selection.error", in: app)
      XCTAssertTrue(error.waitForExistenceFast(timeout: 10))
      XCTAssertFalse(app.buttons["debug.apps.additional.remove.1"].exists)
      XCTAssertFalse(app.buttons["debug.apps.run"].isEnabled)
      scrollIntoView(error, in: app)
      let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      screenshot.name = "HAP HSP selection and duplicate refusal \(language)"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      scrollIntoView(remove, in: app)
      remove.click()
      XCTAssertFalse(remove.exists)
      XCTAssertFalse(error.exists)
      app.buttons["debug.apps.packages.clear"].click()
      XCTAssertFalse(addPackage.isEnabled)
      XCTAssertFalse(app.buttons["debug.apps.packages.clear"].exists)
      app.terminate()
    }
  }

  private func chooseDebugPackage(_ file: URL, in app: XCUIApplication) {
    let panel = app.sheets.firstMatch
    guard panel.waitForExistenceFast(timeout: 10) else { return XCTFail("file picker did not open") }
    app.typeKey("g", modifierFlags: [.command, .shift])
    let path = panel.textFields.firstMatch
    guard path.waitForExistenceFast(timeout: 10) else { return XCTFail("Go to Folder did not open") }
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    path.typeKey("a", modifierFlags: .command)
    path.typeText(file.path)
    path.typeKey(.return, modifierFlags: [])
    let selected = panel.textFields.matching(
      NSPredicate(format: "value == %@", file.lastPathComponent)).firstMatch
    guard selected.waitForExistenceFast(timeout: 10) else { return XCTFail("package was not selected") }
    selected.click()
    let open = panel.buttons["OKButton"]
    guard open.waitForExistenceFast(timeout: 5), open.isEnabled else {
      return XCTFail("package picker did not enable Open")
    }
    open.click()
    XCTAssertTrue(panel.waitForNonExistenceFast(timeout: 10))
  }

  func testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment() {
    for (language, alignment, missingTime) in [
      ("(en)", "Cannot align", "Time not reported"),
      ("(zh-Hans)", "无法对齐", "未记录时刻"),
    ] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-diagnostics-session", "--ui-test-devices",
        "-AppleLanguages", language,
      ])
      select("app.navigation.history", in: app)
      let open = app.buttons["history.openWorkspace"]
      XCTAssertTrue(open.waitForExistenceFast(timeout: 20))
      open.click()
      assertDisplayed(element("diagnostics.session.job", in: app), equals: "job-fixture-diagnostics", timeout: 15)
      assertDisplayed(element("diagnostics.alignment", in: app), equals: alignment)
      assertDisplayed(element("diagnostics.mark.time.1", in: app), equals: missingTime)
      XCTAssertFalse(element("diagnostics.partial", in: app).exists, "an unselected trace channel is not a partial failure")
      XCTAssertFalse(app.buttons["diagnostics.capture.arm"].isEnabled)
      XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
      XCTAssertFalse(element("diagnostics.preview.text", in: app).exists, "raw bytes must not be read on navigation")
      let sessionScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      sessionScreenshot.name = "Diagnostics session and missing calibration \(language)"
      sessionScreenshot.lifetime = .keepAlways
      add(sessionScreenshot)
      let read = app.buttons["diagnostics.artifact.read.hilog.txt"]
      XCTAssertTrue(read.waitForExistenceFast(timeout: 10))
      scrollIntoView(read, in: app)
      read.click()
      let preview = element("diagnostics.preview.text", in: app)
      XCTAssertTrue(preview.waitForExistenceFast(timeout: 10))
      XCTAssertTrue(displayedText(for: preview).contains("UI fixture only: bounded HiLog sample"))
      scrollIntoView(preview, in: app)
      let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      screenshot.name = "Diagnostics published-artifact UI fixture \(language)"
      screenshot.lifetime = .keepAlways
      add(screenshot)

      app.buttons["jobInspector.toggle"].click()
      let log = app.buttons["jobInspector.readLog.fixture-capture.log"]
      XCTAssertTrue(log.waitForExistenceFast(timeout: 10))
      scrollIntoView(log, in: app)
      log.click()
      let logText = element("jobInspector.log.text", in: app)
      XCTAssertTrue(logText.waitForExistenceFast(timeout: 10))
      XCTAssertTrue(displayedText(for: logText).contains("UI fixture only"))
      XCTAssertFalse(app.buttons["jobInspector.cancel"].exists, "a terminal Job cannot be cancelled")
      let record = app.buttons["jobInspector.openRecord"]
      scrollIntoView(record, in: app)
      record.click()
      assertDisplayed(element("history.detail.job", in: app), equals: "job-fixture-diagnostics")
      app.terminate()
    }
  }

  /// The Job is created by the signed headless Runtime before this test.
  /// Only its exact ID is supplied; every byte and identity is still read
  /// through production XPC. No device/History/Trace fixture is installed.
  func testRealDeviceDiagnosticsReopensExactCaptureAndItsTraceInBothLanguages() throws {
    guard let jobID = ProcessInfo.processInfo.environment["ARKDECK_REAL_DEVICE_DIAGNOSTICS_JOB_ID"],
      jobID.hasPrefix("job-"), jobID.count > 4
    else { throw XCTSkip("Supply a real bounded diagnostic capture Job ID for this read-only acceptance") }

    for (language, alignment, timelineLabel, searchLabel) in [
      ("(en)", "Cannot align", "Trace Timeline", "Search TID, thread, or slice"),
      ("(zh-Hans)", "无法对齐", "Trace 时间轴", "搜索 TID、线程或 slice"),
    ] {
      let app = XCUIApplication()
      if app.state != .notRunning { app.terminate() }
      app.launchArguments = [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection",
        "-AppleLanguages", language,
      ]
      app.launch()
      app.activate()
      XCTAssertTrue(app.windows.firstMatch.waitForExistenceFast(timeout: 15))
      select("app.navigation.history", in: app)
      let search = app.textFields["history.filter.search"]
      XCTAssertTrue(search.waitForExistenceFast(timeout: 30))
      search.click()
      search.typeKey("a", modifierFlags: .command)
      search.typeText(jobID)
      assertDisplayed(element("history.detail.job", in: app), equals: jobID, timeout: 30)
      assertDisplayed(element("history.detail.operation", in: app), equals: "capture.diagnostics@1")
      let open = app.buttons["history.openDiagnostics"]
      XCTAssertTrue(open.waitForExistenceFast(timeout: 20), "a multi-channel Viewer/Trace capture must also open in Diagnostics")
      open.click()
      let session = element("diagnostics.session.job", in: app)
      guard session.waitForExistenceFast(timeout: 30) else {
        let evidence = XCTAttachment(string: app.debugDescription)
        evidence.name = "Real Diagnostics load failure"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTFail("the production reader failed: " + displayedText(for: element("diagnostics.session.failed", in: app)))
        return
      }
      assertDisplayed(session, equals: jobID)
      XCTAssertTrue(displayedText(for: element("history.context.job", in: app)).contains(jobID))
      assertDisplayed(element("diagnostics.alignment", in: app), equals: alignment)
      XCTAssertFalse(element("diagnostics.partial", in: app).exists, "the required complete capture must remain complete in the App")
      XCTAssertFalse(element("diagnostics.preview.text", in: app).exists, "navigation must not read raw device text")
      let summary = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      summary.name = "Real Diagnostics session \(language)"
      summary.lifetime = .keepAlways
      add(summary)

      let read = app.buttons["diagnostics.artifact.read.hilog.txt"]
      XCTAssertTrue(read.waitForExistenceFast(timeout: 10))
      scrollIntoView(read, in: app)
      read.click()
      let preview = element("diagnostics.preview.text", in: app)
      XCTAssertTrue(preview.waitForExistenceFast(timeout: 20), "explicit local reading must load the verified real HiLog")
      XCTAssertFalse(displayedText(for: preview).isEmpty)

      let trace = app.buttons["diagnostics.artifacts.openTrace"]
      XCTAssertTrue(trace.exists)
      scrollIntoView(trace, in: app)
      trace.click()
      let viewer = app.windows["Trace Viewer"]
      XCTAssertTrue(viewer.waitForExistenceFast(timeout: 30))
      let timeline = viewer.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", timelineLabel)).firstMatch
      XCTAssertTrue(timeline.waitForExistenceFast(timeout: 90), "the same real trace must parse and render its timeline")
      XCTAssertEqual(viewer.textFields[searchLabel].placeholderValue, searchLabel)
      let sourceBytesLabel = language == "(en)" ? "Source bytes" : "源文件大小"
      let schemaLabel = language == "(en)" ? "Schema" : "Schema 指纹"
      XCTAssertTrue(viewer.staticTexts[sourceBytesLabel].exists)
      XCTAssertTrue(viewer.staticTexts[schemaLabel].exists)
      let loaded = XCTAttachment(screenshot: viewer.screenshot())
      loaded.name = "Real Trace loaded from Diagnostics \(language)"
      loaded.lifetime = .keepAlways
      add(loaded)
      app.terminate()
    }
  }

  func testGlobalCancellationFixtureRefusesWithoutChangingTheJobOutcome() {
    let app = launch(arguments: [
      "--ui-test-runtime-history", "--ui-test-runtime-flash-running", "--ui-test-devices",
      "-AppleLanguages", "(en)",
    ])
    let toggle = app.buttons["jobInspector.toggle"]
    XCTAssertTrue(toggle.waitForExistenceFast(timeout: 20))
    toggle.click()
    let cancel = app.buttons["jobInspector.cancel"]
    XCTAssertTrue(cancel.waitForExistenceFast(timeout: 10))
    cancel.click()
    let result = element("jobInspector.cancel.result", in: app)
    XCTAssertTrue(result.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(displayedText(for: result).contains("fixture_cancellation_not_dispatched"))
    XCTAssertTrue(cancel.exists, "a refused cancellation must not fabricate a terminal state")
    XCTAssertFalse(app.buttons["jobInspector.retry"].exists)
  }

  private func assertDefaultWindowGeometry(
    in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let geometry = app.staticTexts["uiTest.windowGeometry"]
    let available = NSPredicate { _, _ in
      guard geometry.exists, let value = geometry.value as? String,
        let data = value.data(using: .utf8),
        let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
      else { return false }
      return (facts["contentWidth"] ?? 0) > 900
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: nil)], timeout: 10),
      .completed, "the actual window must publish its geometry", file: file, line: line)
    guard let value = geometry.value as? String, let data = value.data(using: .utf8),
      let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
      let frameWidth = facts["frameWidth"], let frameHeight = facts["frameHeight"],
      let layoutWidth = facts["layoutWidth"], let layoutHeight = facts["layoutHeight"]
    else { return XCTFail("window geometry is missing", file: file, line: line) }
    let windowFrame = app.windows.firstMatch.frame
    let evidence = XCTAttachment(string: "AppKit window facts: \(value); AX frame: \(windowFrame)")
    evidence.name = "Actual window frame and content layout"
    evidence.lifetime = .keepAlways
    add(evidence)
    XCTAssertEqual(windowFrame.width, frameWidth, accuracy: 1, file: file, line: line)
    XCTAssertEqual(windowFrame.height, frameHeight, accuracy: 1, file: file, line: line)
    XCTAssertGreaterThan(layoutWidth, 900, "window opened at its minimum", file: file, line: line)
    XCTAssertLessThanOrEqual(layoutHeight, frameHeight, file: file, line: line)
    let nativeChromeHeight = frameHeight - layoutHeight
    if let visible = NSScreen.main?.visibleFrame,
      visible.width >= 1180, visible.height >= 760 + nativeChromeHeight
    {
      XCTAssertEqual(frameWidth, 1180, accuracy: 1, file: file, line: line)
      // `.defaultSize` is a SwiftUI proposal, not an AX frame contract. The
      // unified title/toolbar may extend the outer frame or overlap content.
      // Bound it by the observed native chrome, without a fixed title-bar
      // correction. This still catches a regression to the 600pt floor and
      // retains the exact frame/content/layout facts in the attachment.
      XCTAssertGreaterThanOrEqual(frameHeight, 760, file: file, line: line)
      XCTAssertLessThanOrEqual(frameHeight, 760 + nativeChromeHeight, file: file, line: line)
    }
  }

  /// DONE-01 / DONE-02 / DONE-03 / DONE-07 in one pass.
  private func sweep(
    language: String, overview: Overview, flash: Flash, workspaces: Workspaces, history: History,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    try? "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "--ui-test-device-poll-fast",
        "--ui-test-fixture-state",
        fixtureStateFileURL.path,
        "-AppleLanguages", language,
      ])

    // The window opens at the size the App declares, not at its 900x600
    // floor. A root view's ideal size does not size a WindowGroup, so before
    // `.defaultSize` every workspace opened at its tightest — History's table
    // was 340pt wide with all three of its columns truncated. A display too
    // small for the declared size clamps the window, so only the exact check
    // is conditional; opening at the floor is a failure on any display.
    assertDefaultWindowGeometry(in: app, file: file, line: line)

    // Overview answers its four questions on the first screen.
    XCTAssertTrue(
      element("overview.status.server.value", in: app).waitForExistenceFast(timeout: 15),
      file: file, line: line)
    assertDisplayed(element("overview.status.server.value", in: app), equals: overview.server)
    assertDisplayed(element("overview.status.trust.value", in: app), equals: overview.trust)
    assertDisplayed(element("overview.status.channel.value", in: app), equals: overview.channel)
    assertDisplayed(
      element("overview.status.needsAttention.value", in: app), equals: overview.attention)
    // The four environment sections are no longer on the first screen. Overview
    // was focused on the next device action (TASK-AIN-021, #1549) and they now
    // sit behind a collapsed disclosure, so asserting them here asserted the
    // old design - which is what turned the nightly red.
    //
    // Assert the collapsed entry first. The empty-attention branch below opens
    // it explicitly, then restores collapse for the keyboard route at the end.
    XCTAssertTrue(
      element("overview.advanced.toggle", in: app).waitForExistenceFast(timeout: 10),
      "Overview must offer a way into the environment detail", file: file, line: line)
    for section in [
      "overview.section.serverToolchain", "overview.section.deviceChannel",
      "overview.section.capabilities", "overview.section.needsAttention",
    ] {
      XCTAssertFalse(
        element(section, in: app).exists,
        "\(section) is behind the disclosure now; the first screen is the next "
          + "device action", file: file, line: line)
    }

    // A workspace that has nothing to report has to say so, not go blank. The
    // default fixture always carries the unprotected-TCP warning, so this
    // branch was unreachable until the fixture gained a verified channel.
    do {
      try "--ui-test-hdc-channel-verified".write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
      return
    }
    app.buttons["hdc.devices.refresh"].click()
    app.typeKey("d", modifierFlags: [.command, .shift])
    let attentionClear = app.staticTexts["overview.attention.clear"]
    XCTAssertTrue(attentionClear.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(attentionClear, equals: overview.attentionClear)
    assertDisplayed(
      app.staticTexts["overview.status.needsAttention.value"], equals: overview.attentionNone)
    app.typeKey("d", modifierFlags: [.command, .shift])

    // Update settings live in the Settings scene, not the main window.
    XCTAssertFalse(app.buttons["update.checkNow"].exists, file: file, line: line)
    XCTAssertFalse(app.checkBoxes["update.automaticChecks"].exists, file: file, line: line)

    // The sidebar lists real device candidates: one adopted ready device and
    // one that still needs the on-device trust prompt. Choosing the
    // unauthorized row opens its authorization guidance — a detail, not a
    // workspace — and re-checking is an enabled, plain read.
    let unauthorizedDevice = element("device.row.7f2c091a445e21", in: app)
    let adoptedDevice = element("device.row.150100469346864", in: app)
    XCTAssertTrue(unauthorizedDevice.waitForExistenceFast(timeout: 10), file: file, line: line)
    XCTAssertTrue(adoptedDevice.exists, file: file, line: line)
    // The adopted row names what its last observation recorded — firmware and
    // transport — as raw domain strings, identical in every language.
    XCTAssertTrue(
      displayedText(for: adoptedDevice).contains("OpenHarmony 5.0.0.71"),
      "the adopted device row must carry its observed firmware",
      file: file, line: line)
    clickCorrectingNavigationSplitAXOffset(
      element("device.row.7f2c091a445e21", in: app), in: app)
    XCTAssertTrue(
      element("device.trust.steps", in: app).waitForExistenceFast(timeout: 10),
      "the unauthorized device must show its trust steps", file: file, line: line)
    assertDisplayed(element("device.fact.state", in: app), equals: "Unauthorized")
    let recheck = element("device.action.recheck", in: app)
    XCTAssertTrue(recheck.exists, file: file, line: line)
    XCTAssertTrue(recheck.isEnabled, file: file, line: line)
    XCTAssertFalse(
      app.buttons["device.action.adopt"].exists,
      "the App must not offer adoption", file: file, line: line)

    // The bounded trust wait, walked to both verdicts under the shrunken
    // test window. First the honest close: the window ends with the device
    // still Unauthorized, the countdown strip goes away, and the secondary
    // action leads to Overview's recovery flow instead of restarting
    // anything from here. Then the success: a retried wait sees the fixture
    // flip to Connected and the wait dissolves without a verdict banner.
    let beginWait = element("device.action.beginWait", in: app)
    XCTAssertTrue(beginWait.waitForExistenceFast(timeout: 5), file: file, line: line)
    beginWait.click()
    XCTAssertTrue(
      element("device.wait.polling", in: app).waitForExistenceFast(timeout: 5),
      "starting the wait must show the countdown strip", file: file, line: line)
    XCTAssertFalse(beginWait.isEnabled, "polling disables the start action", file: file, line: line)
    XCTAssertTrue(
      element("device.wait.timedOut", in: app).waitForExistenceFast(timeout: 15),
      "the domain-owned wait must publish its timeout", file: file, line: line)
    XCTAssertTrue(
      app.buttons["device.wait.openOverviewRecovery"].exists,
      "the closed window offers the Overview recovery path, not a restart here",
      file: file, line: line)
    XCTAssertTrue(beginWait.isEnabled, file: file, line: line)
    writeFixtureState("--ui-test-device-authorized", in: app, file: file, line: line)
    beginWait.click()
    XCTAssertTrue(
      element("device.trust.ready", in: app).waitForExistenceFast(timeout: 10),
      "an authorized device ends the wait as ready", file: file, line: line)
    XCTAssertFalse(element("device.wait.timedOut", in: app).exists, file: file, line: line)
    writeFixtureState("", in: app, file: file, line: line)
    select("app.navigation.overview", in: app)
    XCTAssertTrue(
      app.staticTexts["overview.status.server.value"].waitForExistenceFast(timeout: 10),
      "leaving the device detail returns to a workspace", file: file, line: line)

    // Flash is a real production planning workspace. Its fixture provides only
    // the same immutable Runtime facts the production XPC reader consumes; it
    // has no submit/run/authorization surface and cannot touch a device.
    select("app.navigation.flash", in: app)
    XCTAssertTrue(element("flash.workspace.title", in: app).waitForExistenceFast(timeout: 10))
    XCTAssertTrue(element("flash.workspace.currentDevice", in: app).exists)
    XCTAssertTrue(element("flash.workspace.readiness", in: app).exists)
    XCTAssertFalse(
      element("flash.mode", in: app).exists,
      "Flash exposes only real execution; plan-only and simulated are not page controls")
    XCTAssertTrue(element("flash.runtime.attention", in: app).exists, file: file, line: line)
    XCTAssertTrue(app.buttons["flash.runtime.openHistory"].exists, file: file, line: line)
    XCTAssertTrue(
      element("flash.workspace.details", in: app).exists,
      "Flash keeps Runtime and exact-plan facts in one disclosure", file: file, line: line)
    XCTAssertFalse(
      element("flash.target", in: app).exists,
      "Flash details are collapsed by default", file: file, line: line)
    toggleFlashDetails(in: app, file: file, line: line)
    assertDisplayed(element("flash.availability.status", in: app), equals: flash.availability)
    assertDisplayed(element("flash.target", in: app), equals: flash.target)
    assertDisplayed(app.staticTexts["flash.runtime.jobID"], equals: "job-fixture-0002")
    assertDisplayed(app.staticTexts["flash.runtime.state"], equals: flash.runtimeState)
    assertDisplayed(element("flash.runtime.result", in: app), equals: flash.runtimeResult)
    XCTAssertFalse(app.buttons["flash.execute.submit"].exists, file: file, line: line)

    // Debug is a complete native workspace with five distinct panels. The
    // production App read channel has no target in this fixture, so every
    // mutation stays disabled while its exact form remains inspectable.
    // The page title lives in the window toolbar; the content area carries
    // only the scope line, so that is what proves the workspace rendered.
    select("app.navigation.debug", in: app)
    XCTAssertTrue(
      element("debug.scope", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertTrue(element("debug.target", in: app).exists, file: file, line: line)
    XCTAssertTrue(app.buttons["debug.refresh"].exists, file: file, line: line)
    let debugTabs = element("debug.tabs", in: app)
    XCTAssertTrue(debugTabs.exists, file: file, line: line)
    let artifactPreview = app.buttons["debug.artifacts.preview"]
    XCTAssertTrue(artifactPreview.exists, file: file, line: line)
    XCTAssertFalse(artifactPreview.isEnabled, file: file, line: line)
    XCTAssertEqual(workspaces.debugPanels.count, 5, file: file, line: line)
    let debugTabIDs = ["artifacts", "logs", "apps", "network", "commands"]
    for (tabID, panelTitle) in zip(debugTabIDs, workspaces.debugPanels) {
      let tab = element("debug.tab.\(tabID)", in: app)
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5), file: file, line: line)
      clickCorrectingNavigationSplitAXOffset(tab, in: app)
      XCTAssertTrue(
        app.staticTexts[panelTitle].waitForExistenceFast(timeout: 5),
        "Debug panel \(tabID) did not render", file: file, line: line)
    }
    let artifactsTab = element("debug.tab.artifacts", in: app)
    let logsTab = element("debug.tab.logs", in: app)
    let commandsTab = element("debug.tab.commands", in: app)
    artifactsTab.click()
    artifactsTab.typeKey(.end, modifierFlags: [])
    XCTAssertTrue(commandsTab.isSelected, file: file, line: line)
    commandsTab.typeKey(.home, modifierFlags: [])
    XCTAssertTrue(artifactsTab.isSelected, file: file, line: line)
    artifactsTab.typeKey(.rightArrow, modifierFlags: [])
    XCTAssertTrue(logsTab.isSelected, file: file, line: line)
    logsTab.typeKey(.leftArrow, modifierFlags: [])
    XCTAssertTrue(artifactsTab.isSelected, file: file, line: line)
    clickCorrectingNavigationSplitAXOffset(element("debug.tab.logs", in: app), in: app)
    // The sweep asserts the workspace renders its controls, not whether this
    // one can be pressed: starting a log capture needs the Runtime to report
    // capture.diagnostics available, which a developer machine has and a
    // hosted runner has not. Asserting either state makes this test pass in
    // one environment and fail in the other — it did both, in that order.
    // Enablement belongs in a Debug test that controls that availability.
    let debugStart = app.buttons["debug.logs.start"]
    XCTAssertTrue(debugStart.exists, file: file, line: line)
    // Pausing is a viewport action that exists only while a capture runs; in
    // this read-only build nothing captures, so the button stays disabled.
    let pauseViewport = app.buttons["debug.logs.pauseViewport"]
    XCTAssertTrue(pauseViewport.exists, file: file, line: line)
    XCTAssertFalse(pauseViewport.isEnabled, file: file, line: line)

    // Viewer keeps its capture scope, its search field and its explicit
    // "no verified capture" state visible when Runtime has published nothing.
    // Both pane titles come from the Viewer's strings catalog, so this also
    // proves the page is localized rather than rendering hardcoded English.
    select("app.navigation.uiDump", in: app)
    XCTAssertTrue(
      element("viewer.target", in: app).waitForExistenceFast(timeout: 10),
      "Viewer must expose its exact-target picker", file: file, line: line)
    XCTAssertTrue(
      element("viewer.search", in: app).exists,
      "Viewer must expose its component search field", file: file, line: line)
    XCTAssertTrue(
      element("viewer.recapture", in: app).exists,
      "Viewer must expose its Recapture action", file: file, line: line)
    // With no verified capture there are no panes to title, so the empty
    // state is the surface that must speak — and it must speak the sweep's
    // language, which is what proves the page reads its strings catalog.
    XCTAssertTrue(
      app.staticTexts[workspaces.viewerEmptyTitle].waitForExistenceFast(timeout: 10),
      "Viewer must name its empty state in the sweep's language",
      file: file, line: line)
    XCTAssertFalse(app.staticTexts["app.unavailable.title"].exists, file: file, line: line)

    // Trace keeps only the ArkTrace-style capture inputs and viewer entry in
    // the primary workspace. Runtime capability facts still lock the action.
    select("app.navigation.trace", in: app)
    let traceAvailability = element("trace.availability.status", in: app)
    assertDisplayed(
      traceAvailability,
      oneOf: [workspaces.traceAvailable, workspaces.traceUnavailable], timeout: 10)
    for identifier in [
      "trace.profile.picker", "trace.duration.input", "trace.duration.unit",
      "trace.duration.quick", "trace.openViewer",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).exists, "\(identifier) missing",
        file: file, line: line)
    }
    let traceHasEmptyTarget = element("trace.target.empty", in: app).exists
    XCTAssertTrue(
      traceHasEmptyTarget || element("trace.target.picker", in: app).exists,
      "Trace must expose either a selected Runtime target or its explicit empty state",
      file: file, line: line)
    let traceStart = app.buttons["trace.start"]
    XCTAssertTrue(traceStart.exists, file: file, line: line)
    XCTAssertTrue(
      traceStart.isEnabled,
      "Start capture must remain actionable so validation is visible instead of hidden in a disabled control",
      file: file, line: line)
    XCTAssertFalse(app.staticTexts["app.unavailable.title"].exists, file: file, line: line)
    for removedControl in [
      "trace.configuration.mode", "trace.buffer", "trace.parameters.table",
      "trace.filter.createFileAsset",
    ] {
      XCTAssertFalse(
        element(removedControl, in: app).exists,
        "advanced Trace control \(removedControl) must stay out of the simplified workspace",
        file: file, line: line)
    }

    // History renders real Runtime facts and offers no way to submit.
    select("app.navigation.history", in: app)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(app.staticTexts["history.readOnlyNote"], equals: history.readOnlyNote)
    for category in [
      "all", "flash", "viewer", "trace", "diagnostics", "debug", "device", "other",
    ] {
      XCTAssertTrue(
        element("history.activity.\(category)", in: app).exists,
        "History activity category \(category) missing", file: file, line: line)
    }
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists, "\(forbidden) must not exist", file: file, line: line)
    }

    // The newest visible Job is selected automatically, so the workspace is
    // immediately useful and never pauses on an obsolete empty prompt.
    XCTAssertTrue(app.staticTexts["history.detail.select"].waitForNonExistenceFast(timeout: 5))
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0002")

    // An unknown outcome is stated, never folded into the terminal state.
    // The table's own text is not clickable; the row is. Reach it through the
    // per-row state identifier, which is the only identifier the row carries.
    let interruptedRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    XCTAssertTrue(interruptedRow.waitForExistenceFast(timeout: 10), file: file, line: line)
    // An unknown outcome is part of the row's text, not a detail-only fact:
    // "已中断" alone would read as a mere variant of failure.
    assertDisplayed(
      app.staticTexts["history.row.state.job-fixture-0002"],
      equals: history.interruptedRowState)
    interruptedRow.click()
    XCTAssertTrue(
      app.staticTexts["history.detail.select"].waitForNonExistenceFast(timeout: 5),
      "a selected job replaces the prompt", file: file, line: line)
    assertDisplayed(
      app.staticTexts["history.detail.outcomeUnknown"], equals: history.outcomeUnknown)
    assertDisplayed(
      app.staticTexts["history.detail.waitingForHuman"], equals: history.waitingForHuman)
    // Outstanding residue is a fact a reader acts on, and every timeline
    // entry remains individually accessible in order.
    assertDisplayed(app.staticTexts["history.detail.residue"], equals: history.residue)
    assertTimeline(["queued", "running", "interrupted"], in: app)

    // Reopening restores the exact immutable record context. It must take the
    // operator to the related typed workspace without replaying this Job.
    let openWorkspace = app.buttons["history.openWorkspace"]
    XCTAssertTrue(openWorkspace.exists, file: file, line: line)
    openWorkspace.click()
    XCTAssertTrue(
      element("flash.workspace.title", in: app).waitForExistenceFast(timeout: 10),
      "a Flash history must reopen the Flash workspace", file: file, line: line)
    XCTAssertTrue(
      element("history.context", in: app).waitForExistenceFast(timeout: 10),
      "the destination must retain visible History provenance", file: file, line: line)
    XCTAssertTrue(
      displayedText(for: element("history.context.job", in: app)).contains("job-fixture-0002"),
      file: file, line: line)
    XCTAssertTrue(
      displayedText(for: element("history.context.target", in: app)).contains("target-fixture-b"),
      file: file, line: line)
    XCTAssertTrue(
      displayedText(for: element("history.context.operation", in: app)).contains("flash.dayu200"),
      file: file, line: line)
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists, "navigation must not expose \(forbidden)",
        file: file, line: line)
    }
    select("app.navigation.history", in: app)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistenceFast(timeout: 10), file: file, line: line)

    // The succeeded job is the control: every one of those is conditional on
    // the job, and on this one none of them may appear. Without it the four
    // assertions above would also pass if the view rendered them for anything.
    let succeededRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0001").firstMatch
    XCTAssertTrue(succeededRow.waitForExistenceFast(timeout: 10), file: file, line: line)
    succeededRow.click()
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0001")
    assertTimeline(["queued", "running", "succeeded"], in: app)
    for absent in [
      "history.detail.residue", "history.detail.outcomeUnknown", "history.detail.waitingForHuman",
    ] {
      XCTAssertFalse(
        app.staticTexts[absent].exists, "\(absent) must not render for a clean job",
        file: file, line: line)
    }

    // A Runtime that is reachable and has run nothing is its own presentation.
    // The domain has always kept it apart from a history it could not read,
    // but nothing rendered it until now, so this branch of the workspace —
    // the one a new install opens on — had never been seen.
    do {
      try "--ui-test-runtime-history-empty".write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
      return
    }
    app.buttons["history.refresh"].click()
    let emptyTitle = app.staticTexts["history.empty.title"]
    XCTAssertTrue(emptyTitle.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(emptyTitle, equals: history.emptyTitle)
    assertDisplayed(app.staticTexts["history.empty.description"], equals: history.emptyDescription)
    // It is neither a history that could not be read nor a table with no rows,
    // and it still offers nothing to submit.
    XCTAssertFalse(
      app.staticTexts["history.unavailable.title"].exists,
      "an empty history is not an unreadable one", file: file, line: line)
    XCTAssertFalse(
      element("history.table", in: app).exists, "an empty history shows no table",
      file: file, line: line)
    XCTAssertFalse(
      app.staticTexts["history.readOnlyNote"].exists, file: file, line: line)
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists, "\(forbidden) must not exist", file: file, line: line)
    }

    select("app.navigation.flash", in: app)
    toggleFlashDetails(in: app, file: file, line: line)
    XCTAssertTrue(
      app.staticTexts["flash.runtime.empty"].waitForExistenceFast(timeout: 10),
      "Flash must distinguish a reachable empty Runtime history",
      file: file, line: line)

    // Runtime activity is stage-based and terminal states carry their own
    // sentences. Walked here through the same state file instead of a
    // separate launch: running first, a historical recovery relation, then
    // succeeded.
    writeFixtureState("--ui-test-runtime-flash-running", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      element("flash.workspace.progress", in: app).waitForExistenceFast(timeout: 10),
      "a running Flash replaces the image picker with progress",
      file: file, line: line)
    assertDisplayed(
      app.staticTexts["flash.runtime.state"], equals: flash.runtimeRunningState, timeout: 10)
    assertDisplayed(
      element("flash.runtime.result", in: app), equals: flash.runtimeRunningResult)
    XCTAssertTrue(element("flash.runtime.progress", in: app).exists, file: file, line: line)
    XCTAssertFalse(element("flash.runtime.attention", in: app).exists, file: file, line: line)
    writeFixtureState(
      "--ui-test-runtime-flash-resolved-recovery", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      app.buttons["flash.image.choose"].waitForExistenceFast(timeout: 10),
      "a historical waitingForRecovery Job with an established current epoch must stay idle",
      file: file, line: line)
    XCTAssertFalse(
      element("flash.workspace.progress", in: app).exists,
      "resolved recovery history must not look like an automatically started Flash",
      file: file, line: line)
    XCTAssertFalse(element("flash.runtime.progress", in: app).exists, file: file, line: line)
    XCTAssertFalse(element("flash.runtime.attention", in: app).exists, file: file, line: line)
    writeFixtureState("--ui-test-runtime-flash-succeeded", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      app.buttons["flash.image.choose"].waitForExistenceFast(timeout: 10),
      "historical success must not replace the next Flash action with a stale dashboard",
      file: file, line: line)
    assertDisplayed(
      app.staticTexts["flash.runtime.state"], equals: flash.runtimeSucceededState, timeout: 10)
    assertDisplayed(
      element("flash.runtime.result", in: app), equals: flash.runtimeSucceededResult)
    XCTAssertFalse(element("flash.runtime.progress", in: app).exists, file: file, line: line)
    XCTAssertFalse(element("flash.runtime.attention", in: app).exists, file: file, line: line)

    // A history that could not be read must never look like an empty history,
    // and Flash states the same unavailability instead of a false empty.
    // The reason is the fixture's raw string, identical in every language.
    writeFixtureState(
      "--ui-test-runtime-history-unreachable", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      app.staticTexts["flash.runtime.unavailable"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertFalse(app.staticTexts["flash.runtime.empty"].exists, file: file, line: line)
    select("app.navigation.history", in: app)
    XCTAssertTrue(
      app.staticTexts["history.unavailable.title"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    assertDisplayed(
      app.staticTexts["history.unavailable.reason"],
      equals: "ArkDeck Runtime is not reachable: fixture")
    XCTAssertFalse(
      element("history.table", in: app).exists, "an unreadable history shows no table",
      file: file, line: line)
    XCTAssertFalse(
      app.staticTexts["history.empty.title"].exists, "it is not an empty history",
      file: file, line: line)

    // The exact-plan run action asserts English strings; the flow itself is
    // language-independent, so one language carries it.
    if language == "(en)" {
      walkExactFlashPlanRunAction(in: app, file: file, line: line)
    }

    do {
      try "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot restore the Runtime fixture: \(error)", file: file, line: line)
      return
    }
    app.buttons["jobInspector.refresh"].click()

    select("app.navigation.overview", in: app)

    // Job inspection is global rather than another navigation destination.
    // It renders the same Runtime fixture as History. The selected unknown
    // outcome has only facts and recovery guidance, never cancel or replay.
    // Keep it at the end because AppKit may retain the expanded split view's AX
    // offset after collapse; no later sidebar navigation should depend on it.
    XCTAssertTrue(
      element("jobRecovery.banner", in: app).waitForExistenceFast(timeout: 10),
      "an unknown Runtime outcome must remain visible above every workspace",
      file: file, line: line)
    let inspectorToggle = app.buttons["jobInspector.toggle"]
    XCTAssertTrue(inspectorToggle.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(inspectorToggle, equals: workspaces.inspectorShow)
    inspectorToggle.click()
    XCTAssertTrue(
      element("jobInspector.list", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    assertDisplayed(
      element("jobInspector.runtimeFacts", in: app), equals: workspaces.inspectorRuntimeFacts)
    let inspectorReference = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    inspectorReference.name = "Global Job inspector fixture \(workspaces.inspectorRuntimeFacts)"
    inspectorReference.lifetime = .keepAlways
    add(inspectorReference)
    XCTAssertTrue(element("jobInspector.attention", in: app).exists, file: file, line: line)
    XCTAssertTrue(
      element("jobInspector.timeline.entries", in: app).exists,
      file: file, line: line)
    for forbidden in ["jobInspector.submit", "jobInspector.cancel", "jobInspector.retry"] {
      XCTAssertFalse(app.buttons[forbidden].exists, file: file, line: line)
    }
    app.buttons["jobInspector.toggle"].click()
    XCTAssertTrue(
      element("jobInspector.list", in: app).waitForNonExistenceFast(timeout: 5),
      file: file, line: line)

    // Finish on Advanced Diagnostics for the same AX-cache reason.
    let toggle = app.buttons["overview.advanced.toggle"]
    XCTAssertTrue(toggle.waitForExistenceFast(timeout: 10), file: file, line: line)
    XCTAssertFalse(app.staticTexts["hdc.toolchain.path"].exists, file: file, line: line)
    app.typeKey("d", modifierFlags: [.command, .shift])
    assertDisplayed(app.staticTexts["hdc.toolchain.path"], equals: "/Applications/DevEco/hdc")
    assertDisplayed(app.staticTexts["hdc.counters.autoLifecycle"], equals: "0")

    // The Settings scene is its own window, so it comes after every sidebar
    // interaction. Both languages verify all seven panes and the safe controls;
    // the update state machine asserts English status strings, so English
    // carries that walk.
    openSettings(in: app)
    for pane in workspaces.settingsPanes {
      XCTAssertTrue(
        app.buttons[pane].waitForExistenceFast(timeout: 10),
        "Settings must expose the \(pane) pane", file: file, line: line)
    }
    assertTraceSettings(in: app, title: workspaces.settingsPanes[6], file: file, line: line)
    settingsPane(workspaces.settingsPanes[1], in: app).click()
    XCTAssertTrue(
      app.buttons["settings.toolchains.choose"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertTrue(app.buttons["settings.toolchains.refresh"].exists, file: file, line: line)
    settingsPane(workspaces.settingsPanes[2], in: app).click()
    XCTAssertTrue(
      app.buttons["settings.remoteSources.add"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertTrue(app.buttons["settings.remoteSources.refresh"].exists, file: file, line: line)
    app.buttons["settings.remoteSources.add"].click()
    XCTAssertTrue(
      element("settings.remoteSources.field.host", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertTrue(
      element("settings.remoteSources.field.root", in: app).exists,
      file: file, line: line)
    XCTAssertFalse(
      app.buttons["settings.remoteSources.save"].isEnabled,
      "an unverified server must not be saved", file: file, line: line)
    app.buttons["settings.remoteSources.cancel"].click()
    settingsPane(workspaces.settingsPanes[3], in: app).click()
    for identifier in [
      "settings.storage.chooseRoot", "settings.storage.quota", "settings.storage.margin",
      "settings.storage.retention", "settings.storage.save",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).waitForExistenceFast(timeout: 10),
        "\(identifier) missing", file: file, line: line)
    }
    settingsPane(workspaces.settingsPanes[5], in: app).click()
    XCTAssertTrue(
      app.buttons["settings.diagnostics.preview"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertFalse(app.buttons["settings.diagnostics.export"].exists, file: file, line: line)
    settingsPane(workspaces.settingsPanes[4], in: app).click()
    XCTAssertTrue(
      app.staticTexts["update.status"].waitForExistenceFast(timeout: 10),
      "the Updates pane must render its status", file: file, line: line)
    if language == "(en)" {
      // The controls the main window must not carry are the ones this scene
      // owns; a checkbox reports its state as a number, not text.
      let automaticChecks = app.checkBoxes["update.automaticChecks"]
      XCTAssertTrue(automaticChecks.exists, file: file, line: line)
      XCTAssertEqual(
        (automaticChecks.value as? NSNumber)?.intValue, 1,
        "automatic checks default to on", file: file, line: line)
      // Idle, available, failed, then awaiting-consent last: it is the one
      // state that disables Check Now, so it cannot be walked out of.
      for state in [
        UpdateState(
          flag: "--ui-test-auto-update-idle",
          status: "Ready to check for updates.",
          enabled: ["update.checkNow"], attention: nil),
        UpdateState(
          flag: "--ui-test-auto-update-available",
          status: "An update is available. Download requires your action.",
          enabled: ["update.checkNow", "update.download"], attention: "Update Available"),
        UpdateState(
          flag: "--ui-test-auto-update-failed",
          status: "Update verification failed. Nothing was installed or replaced.",
          enabled: ["update.checkNow"], attention: "Update Failed"),
        UpdateState(
          flag: "--ui-test-auto-update-awaiting-consent",
          status: "The DMG passed signature and Team verification. Confirm once more to reveal it.",
          enabled: ["update.reveal"], attention: "Update Awaiting Confirmation"),
      ] {
        assertUpdateState(state, in: app)
      }
    }
  }

  /// Renders every second-locale expectation while leaving behavioral matrix
  /// ownership with the English sweep. This keeps localization coverage at
  /// the UI boundary without paying twice for device wait windows, recovery
  /// state machines, destructive-plan review, window geometry, or forbidden
  /// control checks whose result cannot vary by locale.
  private func localizedSweep(
    language: String, overview: Overview, flash: Flash, workspaces: Workspaces, history: History,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot initialize the fixture state: \(error)", file: file, line: line)
      return
    }
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "--ui-test-device-poll-fast", "--ui-test-fixture-state",
        fixtureStateFileURL.path, "-AppleLanguages", language,
      ])

    XCTAssertTrue(
      element("overview.status.server.value", in: app).waitForExistenceFast(timeout: 15),
      file: file, line: line)
    assertDisplayed(element("overview.status.server.value", in: app), equals: overview.server)
    assertDisplayed(element("overview.status.trust.value", in: app), equals: overview.trust)
    assertDisplayed(element("overview.status.channel.value", in: app), equals: overview.channel)
    assertDisplayed(
      element("overview.status.needsAttention.value", in: app), equals: overview.attention)

    // The Chinese HDC control and its keyboard route used to own another full
    // diagnostics launch. The shell is already rendering the same production
    // control, so assert both here before changing fixture state.
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistenceFast(timeout: 10), file: file, line: line)
    XCTAssertEqual(refresh.label, "刷新设备", file: file, line: line)
    XCTAssertTrue(refresh.isEnabled, file: file, line: line)
    app.typeKey("d", modifierFlags: [.command, .shift])
    app.typeKey("r", modifierFlags: .command)
    assertDisplayed(
      app.staticTexts["hdc.devices.events"],
      equals:
        "2026-07-28T00:00:00.000Z appeared redacted-device-0123456789abcdef01234567"
        + " | 2026-07-28T00:00:01.000Z disappeared "
        + "redacted-device-0123456789abcdef01234567",
      timeout: 10, file: file, line: line)

    writeFixtureState("--ui-test-hdc-channel-verified", in: app, file: file, line: line)
    refresh.click()
    assertDisplayed(
      app.staticTexts["overview.attention.clear"], equals: overview.attentionClear,
      timeout: 10, file: file, line: line)
    assertDisplayed(
      app.staticTexts["overview.status.needsAttention.value"], equals: overview.attentionNone,
      file: file, line: line)
    app.typeKey("d", modifierFlags: [.command, .shift])
    writeFixtureState("", in: app, file: file, line: line)

    select("app.navigation.flash", in: app, file: file, line: line)
    XCTAssertTrue(element("flash.workspace.title", in: app).waitForExistenceFast(timeout: 10))
    XCTAssertTrue(element("flash.workspace.currentDevice", in: app).exists)
    XCTAssertTrue(element("flash.workspace.readiness", in: app).exists)
    XCTAssertFalse(element("flash.mode", in: app).exists, file: file, line: line)
    XCTAssertTrue(element("flash.runtime.attention", in: app).exists, file: file, line: line)
    let details = element("flash.workspace.details", in: app)
    XCTAssertTrue(details.exists, file: file, line: line)
    toggleFlashDetails(in: app, file: file, line: line)
    assertDisplayed(element("flash.availability.status", in: app), equals: flash.availability)
    assertDisplayed(element("flash.target", in: app), equals: flash.target)
    assertDisplayed(app.staticTexts["flash.runtime.state"], equals: flash.runtimeState)
    assertDisplayed(element("flash.runtime.result", in: app), equals: flash.runtimeResult)

    select("app.navigation.debug", in: app, file: file, line: line)
    for (tabID, panelTitle) in zip(
      ["artifacts", "logs", "apps", "network", "commands"], workspaces.debugPanels
    ) {
      let tab = element("debug.tab.\(tabID)", in: app)
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5), file: file, line: line)
      clickCorrectingNavigationSplitAXOffset(tab, in: app)
      XCTAssertTrue(
        app.staticTexts[panelTitle].waitForExistenceFast(timeout: 5),
        "localized Debug panel \(tabID) did not render", file: file, line: line)
    }

    select("app.navigation.uiDump", in: app, file: file, line: line)
    XCTAssertTrue(
      app.staticTexts[workspaces.viewerEmptyTitle].waitForExistenceFast(timeout: 10),
      "localized Viewer empty state did not render", file: file, line: line)
    select("app.navigation.trace", in: app, file: file, line: line)
    assertDisplayed(
      element("trace.availability.status", in: app),
      oneOf: [workspaces.traceAvailable, workspaces.traceUnavailable],
      timeout: 10, file: file, line: line)

    select("app.navigation.history", in: app, file: file, line: line)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(app.staticTexts["history.readOnlyNote"], equals: history.readOnlyNote)
    assertDisplayed(
      app.staticTexts["history.row.state.job-fixture-0002"],
      equals: history.interruptedRowState)
    let interruptedRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    interruptedRow.click()
    assertDisplayed(
      app.staticTexts["history.detail.outcomeUnknown"], equals: history.outcomeUnknown)
    assertDisplayed(
      app.staticTexts["history.detail.waitingForHuman"], equals: history.waitingForHuman)
    assertDisplayed(app.staticTexts["history.detail.residue"], equals: history.residue)

    writeFixtureState("--ui-test-runtime-history-empty", in: app, file: file, line: line)
    app.buttons["history.refresh"].click()
    assertDisplayed(
      app.staticTexts["history.empty.title"], equals: history.emptyTitle,
      timeout: 10, file: file, line: line)
    assertDisplayed(
      app.staticTexts["history.empty.description"], equals: history.emptyDescription,
      file: file, line: line)

    select("app.navigation.flash", in: app, file: file, line: line)
    toggleFlashDetails(in: app, file: file, line: line)
    writeFixtureState("--ui-test-runtime-flash-running", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      element("flash.workspace.progress", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    assertDisplayed(
      app.staticTexts["flash.runtime.state"], equals: flash.runtimeRunningState,
      timeout: 10, file: file, line: line)
    assertDisplayed(element("flash.runtime.result", in: app), equals: flash.runtimeRunningResult)
    writeFixtureState("--ui-test-runtime-flash-succeeded", in: app, file: file, line: line)
    app.buttons["flash.refresh"].click()
    XCTAssertTrue(
      app.buttons["flash.image.choose"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    assertDisplayed(
      app.staticTexts["flash.runtime.state"], equals: flash.runtimeSucceededState,
      timeout: 10, file: file, line: line)
    assertDisplayed(element("flash.runtime.result", in: app), equals: flash.runtimeSucceededResult)

    writeFixtureState("", in: app, file: file, line: line)
    app.buttons["jobInspector.refresh"].click()
    select("app.navigation.overview", in: app, file: file, line: line)
    let inspectorToggle = app.buttons["jobInspector.toggle"]
    XCTAssertTrue(inspectorToggle.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(inspectorToggle, equals: workspaces.inspectorShow)
    inspectorToggle.click()
    XCTAssertTrue(
      element("jobInspector.list", in: app).waitForExistenceFast(timeout: 10),
      file: file, line: line)
    assertDisplayed(
      element("jobInspector.runtimeFacts", in: app), equals: workspaces.inspectorRuntimeFacts)

    openSettings(in: app)
    for pane in workspaces.settingsPanes {
      XCTAssertTrue(
        app.buttons[pane].waitForExistenceFast(timeout: 10),
        "Settings must expose localized pane \(pane)", file: file, line: line)
    }
  }

  /// The exact-plan fixture is presentation-only: it bypasses the system file
  /// picker so this flow can walk the complete inline review inside the
  /// sweep's launch. Clicking its enabled one-click Flash action exercises
  /// the one-click Loader-bind + Flash handoff only
  /// against the in-process presentation fixture; no device transport exists.
  private func walkExactFlashPlanRunAction(
    in app: XCUIApplication, file: StaticString, line: UInt
  ) {
    writeFixtureState(
      "--ui-test-flash-loader-unbound\n--ui-test-flash-plan\n--ui-test-runtime-history-empty",
      in: app, file: file, line: line)
    select("app.navigation.flash", in: app)
    app.buttons["flash.refresh"].click()
    XCTAssertFalse(element("flash.mode", in: app).exists, file: file, line: line)
    XCTAssertFalse(app.buttons["flash.bootloader.bind"].exists, file: file, line: line)
    let details = element("flash.workspace.details", in: app)
    XCTAssertTrue(details.waitForExistenceFast(timeout: 10), file: file, line: line)
    toggleFlashDetails(in: app, file: file, line: line)
    // The earlier History walk deliberately pinned a different, now missing
    // target. The product must not silently select another device for it.
    let target = app.popUpButtons["flash.target"]
    scrollWorkspaceUntilExists(target, in: app, deltaY: -400, file: file, line: line)
    scrollIntoView(target, in: app)
    XCTAssertTrue(element("flash.target.historyMissing", in: app).exists, file: file, line: line)
    target.click()
    app.menuItems["target-fixture-dayu200"].click()
    XCTAssertTrue(
      element("flash.plan.steps", in: app).waitForExistenceFast(timeout: 15),
      "the fixture must materialize an exact execute plan", file: file, line: line)
    XCTAssertTrue(
      element("flash.workspace.plan.stages", in: app).exists,
      "Flash summarizes Exact Plan as four readable stages", file: file, line: line)

    // Read the details from top to bottom. SwiftUI omits far-offscreen children
    // from the AX tree, so use the visible prerequisite verdict as the scroll
    // sentinel instead of relying on its layout container becoming an AX node.
    let prerequisiteVerdict = app.staticTexts["Unknown"].firstMatch
    scrollWorkspaceUntilExists(
      prerequisiteVerdict, in: app, deltaY: -600, file: file, line: line)
    scrollIntoView(prerequisiteVerdict, in: app)
    XCTAssertTrue(
      prerequisiteVerdict.waitForExistenceFast(timeout: 5),
      file: file, line: line)

    let partitions = element("flash.plan.partitions.disclosure", in: app)
    XCTAssertTrue(partitions.exists, file: file, line: line)
    scrollIntoView(partitions, in: app)
    partitions.click()
    XCTAssertTrue(
      element("flash.plan.partition.system", in: app).waitForExistenceFast(timeout: 5),
      "mapped partition details must be inspectable", file: file, line: line)
    partitions.click()

    let submit = element("flash.execute.submit", in: app)
    XCTAssertTrue(submit.exists, file: file, line: line)
    scrollIntoView(submit, in: app)
    XCTAssertTrue(submit.isEnabled, file: file, line: line)
    XCTAssertEqual(submit.label, "Erase data and start flashing", file: file, line: line)
    XCTAssertFalse(element("flash.confirm.sheet", in: app).exists, file: file, line: line)
    XCTAssertFalse(element("flash.execute.terminal", in: app).exists, file: file, line: line)
    submit.click()
    XCTAssertTrue(
      element("flash.bootloader.bound", in: app).waitForExistenceFast(timeout: 10),
      "the single Flash click must bind the Loader without a confirmation sheet",
      file: file, line: line)
    XCTAssertTrue(
      element("flash.execute.terminal", in: app).waitForExistenceFast(timeout: 10),
      "the same Flash click must continue into the fixture execution",
      file: file, line: line)
    XCTAssertTrue(
      element("flash.execute.jobId", in: app).waitForExistenceFast(timeout: 5),
      "the result card must expose the durable Runtime Job identifier",
      file: file, line: line)
  }

  private func writeFixtureState(
    _ token: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try token.write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
    }
  }

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
  private struct UpdateState {
    let flag: String
    let status: String
    /// Exactly which of the three actions this state offers. Naming only the
    /// enabled ones would pass for a scene that enabled all of them.
    let enabled: [String]
    let attention: String?
  }

  private func assertUpdateState(
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
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private static func resizeHistoryWindow(
    in app: XCUIApplication, to width: CGFloat,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let window = app.windows.firstMatch
    if abs(window.frame.width - width) <= 2 { return }
    let origin = window.coordinate(withNormalizedOffset: .zero)
    let edge = origin.withOffset(CGVector(dx: window.frame.width - 1, dy: 150))
    edge.click(
      forDuration: 0.1,
      thenDragTo: origin.withOffset(CGVector(dx: width - 1, dy: 150)))
    XCTAssertEqual(window.frame.width, width, accuracy: 2, file: file, line: line)
  }

  /// Lightweight visual regression for the current device detail layout. Native
  /// materials, accent, fonts and antialiasing remain system-owned, so this
  /// pins structure and keeps an artifact for review instead of comparing raw
  /// pixels across macOS versions.
  private func assertDeviceDetailLayout(
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

  private func assertFlashLayout(
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

  // MARK: - Helpers

  /// Flash exposes one full-label disclosure button, matching the established
  /// Job Inspector interaction instead of macOS's arrow-only hit region.
  private func toggleFlashDetails(
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
  private func select(
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
  private func clickCorrectingNavigationSplitAXOffset(
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

  private func assertDisplayed(
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

  private func assertTimeline(
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
  private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
    let targetX = element.frame.midX
    let hosts = app.scrollViews.allElementsBoundByIndex.filter { host in
      let frame = host.frame
      return frame.width > 0 && frame.minX <= targetX && targetX <= frame.maxX
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
  private func scrollWorkspaceUntilExists(
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

  private func launch(
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

  private func openGeneralSettings(in app: XCUIApplication) {
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
  private func assertTraceSettings(
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
  private func settingsPane(
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

  private func openSettings(in app: XCUIApplication) {
    let settings = element("app.toolbar.openSettings", in: app)
    XCTAssertTrue(settings.waitForExistenceFast(timeout: 10))
    settings.click()
  }
}
