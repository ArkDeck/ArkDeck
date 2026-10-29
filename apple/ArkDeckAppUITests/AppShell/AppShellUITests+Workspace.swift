import AppKit
import XCTest

extension AppShellUITests {
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
      // The sidebar names the page and so does the window toolbar; spec §8 does
      // not allow the content area to repeat it, so assert the duplicate is
      // absent rather than pinning it in place. Wait for the page's own content
      // first: the assertion this replaced waited, and a bare `exists` on a
      // negative would race the navigation it follows.
      XCTAssertTrue(element("diagnostics.session.empty", in: app).waitForExistenceFast(timeout: 10))
      XCTAssertFalse(app.staticTexts["diagnostics.workspace.title"].exists)
      XCTAssertTrue(app.staticTexts[diagnosticsEmptyTitle].exists)
      // Start may preflight the adopted target; Mark needs Runtime readiness.
      XCTAssertTrue(app.buttons["diagnostics.capture.arm"].isEnabled)
      XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
      XCTAssertTrue(element("diagnostics.capture.boundary", in: app).exists)
      XCTAssertFalse(app.buttons["diagnostics.capture.stop"].isEnabled)
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
          "Typed Runtime request",
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
          "Typed Runtime 请求",
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
      // This test covers the empty Viewer and shortcut presentation. Native
      // signed-tool startup has separate checks; CI tools are compile-only.
      let app = launch(arguments: ["-AppleLanguages", language, "--ui-test-trace-empty-viewer"])
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

  func testDeviceObservationFailureRemainsInspectableInBothLanguages() throws {
    let reason = "target output line 3: target line is not the registered 5-column family; saw 2 columns; preview \"fixture-device\\tConnected\""
    for language in ["(en)", "(zh-Hans)"] {
      try "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-devices",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
      ])
      defer { app.terminate() }
      let device = element("device.row.150100469346864", in: app)
      XCTAssertTrue(device.waitForExistenceFast(timeout: 10))
      device.click()
      XCTAssertTrue(element("device.detail", in: app).waitForExistenceFast(timeout: 10))
      writeFixtureState("--ui-test-device-observation-unavailable", in: app)
      let recheck = app.buttons["device.action.recheck"]
      XCTAssertTrue(recheck.waitForExistenceFast(timeout: 10))
      recheck.click()
      assertDisplayed(element("app.devices.unavailable.reason", in: app), equals: reason)
      assertDisplayed(element("app.devices.unavailable.detailReason", in: app), equals: reason)
      XCTAssertFalse(element("app.devices.gone", in: app).exists)
      XCTAssertFalse(element("device.detail", in: app).exists)

      // A fresh successful observation restores the same selected device.
      writeFixtureState("", in: app)
      recheck.click()
      XCTAssertTrue(element("device.detail", in: app).waitForExistenceFast(timeout: 10))
      XCTAssertFalse(element("app.devices.unavailable.detailReason", in: app).exists)
      XCTAssertFalse(element("app.devices.gone", in: app).exists)
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

  struct Overview {
    let server: String
    let trust: String
    let channel: String
    let attention: String
    let attentionNone: String
    let attentionClear: String
  }

  struct Workspaces {
    let inspectorShow: String
    let inspectorRuntimeFacts: String
    let debugPanels: [String]
    let viewerEmptyTitle: String
    let traceAvailable: String
    let traceUnavailable: String
    let settingsPanes: [String]
  }

  struct Flash {
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

  struct History {
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
  /// spending another launch on it. FixtureStateLocation says where it lives.
  var fixtureStateFileURL: URL {
    FixtureStateLocation.file(
      named: "arkdeck-appshell-fixture-state-\(ProcessInfo.processInfo.processIdentifier).txt")
  }

  /// Every fixture test hands the App its state through this file, so this
  /// checks what they all rely on, without launching anything: the file lands
  /// outside every app container, where the App reads it without a privacy
  /// prompt, and the runner may still write there. A runner that lost its
  /// entitlement, or a helper pointed back at the temporary directory, fails
  /// here instead of stalling every fixture test at its first device wait.
  func testFixtureStateStaysOutsideEveryAppContainer() throws {
    let url = fixtureStateFileURL
    XCTAssertFalse(
      url.path.contains("/Library/Containers/"),
      "fixture state would be written to \(url.path), inside an app container")
    try "probe".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: url)
  }

  /// Both panes that render from the Runtime-backed presentation used to fall
  /// back to a spinner that nothing would stop: the refresh ran once, when the
  /// Settings scene appeared, so a Runtime unreachable at that moment stayed
  /// unreachable until the window was closed and reopened. The design's error
  /// row has always carried a Refresh action. This walks it from unreachable
  /// to recovered without a relaunch, through the fixture's shared switch.
  func testSettingsOfferRefreshWhileTheRuntimeIsUnreachableAndRecoverThroughIt() {
    do {
      try "--ui-test-runtime-history-unreachable".write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      return XCTFail("cannot write the fixture state: \(error)")
    }
    let app = launch(arguments: [
      "--ui-test-runtime-history", "--ui-test-fixture-state", fixtureStateFileURL.path,
      "-AppleLanguages", "(en)",
    ])
    openSettings(in: app)

    // General renders its build facts from the same presentation: Refresh and
    // the notice, no spinner.
    settingsPane("General", in: app).click()
    let generalRefresh = app.buttons["settings.general.refresh"]
    XCTAssertTrue(
      generalRefresh.waitForExistenceFast(timeout: 10),
      "General must offer Refresh while the Runtime is unreachable")
    XCTAssertTrue(element("settings.error.refresh", in: app).exists)

    settingsPane("Storage", in: app).click()
    let storageRefresh = app.buttons["settings.storage.refresh"]
    XCTAssertTrue(
      storageRefresh.waitForExistenceFast(timeout: 10),
      "Storage must offer Refresh while the Runtime is unreachable")
    XCTAssertTrue(element("settings.error.refresh", in: app).exists)
    XCTAssertFalse(element("settings.storage.chooseRoot", in: app).exists)

    // Refreshing while the Runtime is still unreachable reports again rather
    // than resting on the spinner: the entry point stays open.
    storageRefresh.click()
    XCTAssertTrue(
      storageRefresh.waitForExistenceFast(timeout: 10),
      "a refresh that fails must leave the Refresh action in place")
    XCTAssertFalse(element("settings.storage.chooseRoot", in: app).exists)

    // The Runtime comes back. The same action recovers the pane in place.
    writeFixtureState("", in: app)
    storageRefresh.click()
    XCTAssertTrue(
      element("settings.storage.chooseRoot", in: app).waitForExistenceFast(timeout: 10),
      "Refresh must recover the pane once the Runtime answers")
    assertDisplayed(app.textFields["settings.storage.quota"], equals: "12")
    XCTAssertFalse(storageRefresh.exists)
    XCTAssertFalse(element("settings.error.refresh", in: app).exists)

    // One presentation serves both panes, so General recovered with it.
    settingsPane("General", in: app).click()
    XCTAssertTrue(
      element("settings.general.appIcon.keycap", in: app).waitForExistenceFast(timeout: 10))
    XCTAssertFalse(generalRefresh.exists)
    XCTAssertFalse(element("settings.error.refresh", in: app).exists)
    app.terminate()
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
      // The visually elided, selectable archive hash must expose its complete
      // native accessible value without recursively resolving an AX label.
      let archiveHash = "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e"
      let hashName = language == "(en)" ? "Archive SHA-256" : "归档 SHA-256"
      XCTAssertTrue(app.staticTexts[hashName].exists)
      let hashText = app.staticTexts[archiveHash].firstMatch
      XCTAssertTrue(hashText.exists)
      XCTAssertEqual(hashText.value as? String, archiveHash)
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
  func checkCanonicalFlashHistoryStates(in app: XCUIApplication, language: String) {
    let canonical = "--ui-test-runtime-flash-canonical"
    writeFixtureState("\(canonical)\n--ui-test-runtime-flash-newer-observe", in: app)
    select("app.navigation.flash", in: app)
    app.buttons["flash.refresh"].click()
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
      // A bare click here was the whole of audit F56's "Debug HAP" flake: on a
      // failing run the App was still on Artifacts, Debug's default tab, and
      // the 15s wait below was waiting for a control that only exists on Apps.
      // Every other Debug tab switch in this suite goes through the corrected
      // click; this one did not. Switch, then confirm the switch took.
      let appsTab = element("debug.tab.apps", in: app)
      XCTAssertTrue(appsTab.waitForExistenceFast(timeout: 10))
      let cleanup = app.popUpButtons["debug.apps.cleanupPolicy"]
      let postRun = app.popUpButtons["debug.apps.postRun"]
      for _ in 0..<3 where !postRun.exists {
        clickCorrectingNavigationSplitAXOffset(appsTab, in: app)
        _ = postRun.waitForExistenceFast(timeout: 5)
      }
      XCTAssertTrue(postRun.exists, "the Debug Apps tab never became active")
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

  func chooseDebugPackage(_ file: URL, in app: XCUIApplication) {
    let panel = app.sheets.firstMatch
    guard panel.waitForExistenceFast(timeout: 10) else { return XCTFail("file picker did not open") }
    // Pin the layout before the first synthesized keystroke, not after it:
    // ⌘⇧G itself has to register for Go to Folder to open at all.
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    app.typeKey("g", modifierFlags: [.command, .shift])
    // The open panel publishes text fields of its own, so binding to
    // `panel.textFields.firstMatch` can grab one that already existed and type
    // the path into it — the panel then selects nothing and the failure reads
    // "package was not selected" (audit F56). Go to Folder is a sheet on the
    // panel, so prefer its own field and only fall back if that is not how
    // this macOS build exposes it.
    let goToFolder = panel.sheets.firstMatch
    let path =
      goToFolder.waitForExistenceFast(timeout: 5)
      ? goToFolder.textFields.firstMatch : panel.textFields.firstMatch
    guard path.waitForExistenceFast(timeout: 10) else { return XCTFail("Go to Folder did not open") }
    path.typeKey("a", modifierFlags: .command)
    path.typeText(file.path)
    path.typeKey(.return, modifierFlags: [])
    let selected = panel.textFields.matching(
      NSPredicate(format: "value == %@", file.lastPathComponent)).firstMatch
    guard selected.waitForExistenceFast(timeout: 10) else {
      // Leave evidence rather than another bare failure: this path has now
      // failed three different ways across runs and the panel's own structure
      // is the thing nobody has looked at.
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Open panel hierarchy when \(file.lastPathComponent) was not selected"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      return XCTFail("package was not selected")
    }
    selected.click()
    let open = panel.buttons["OKButton"]
    guard open.waitForExistenceFast(timeout: 5), open.isEnabled else {
      return XCTFail("package picker did not enable Open")
    }
    open.click()
    XCTAssertTrue(panel.waitForNonExistenceFast(timeout: 10))
  }

  func testDiagnosticsStartsMarksAndStopsExactSession() {
    let app = launch(arguments: [
      "--ui-test-runtime-history", "--ui-test-devices", "--ui-test-diagnostic-capture",
      "-AppleLanguages", "(en)",
    ])
    select("app.navigation.diagnostics", in: app)
    let start = app.buttons["diagnostics.capture.arm"]
    XCTAssertTrue(start.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(start.isEnabled)
    XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
    start.click()
    assertDisplayed(element("diagnostics.capture.state", in: app), equals: "Recording", timeout: 10)
    XCTAssertFalse(start.isEnabled)
    app.buttons["diagnostics.capture.mark"].click()
    assertDisplayed(element("diagnostics.capture.markCount", in: app), equals: "Markers: 1 / 50")
    app.buttons["diagnostics.capture.stop"].click()
    assertDisplayed(element("diagnostics.capture.state", in: app), equals: "Session ended")
    XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
    XCTAssertFalse(app.buttons["diagnostics.capture.stop"].isEnabled)
    assertDisplayed(element("diagnostics.capture.job", in: app), equals: "job-ui-diagnostic-capture")
    assertDisplayed(element("diagnostics.alignment", in: app), equals: "Cannot align")
    app.terminate()
  }

  func testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment() throws {
    for (language, alignment, missingTime) in [
      ("(en)", "Cannot align", "Time not reported"),
      ("(zh-Hans)", "无法对齐", "未记录时刻"),
    ] {
      let app = launch(arguments: [
        "--ui-test-runtime-history", "--ui-test-diagnostics-session", "--ui-test-hilog-summaries", "--ui-test-devices",
        "-AppleLanguages", language,
      ])
      let processID = try XCTUnwrap(NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").first?.processIdentifier)
      openExactHistoryRecord("job-fixture-diagnostics", in: app)
      let open = app.buttons["history.openWorkspace"]
      XCTAssertTrue(open.waitForExistenceFast(timeout: 20))
      open.click()
      assertDisplayed(element("diagnostics.session.job", in: app), equals: "job-fixture-diagnostics", timeout: 15)
      assertDisplayed(element("diagnostics.alignment", in: app), equals: alignment)
      assertDisplayed(element("diagnostics.mark.time.1", in: app), equals: missingTime)
      XCTAssertFalse(element("diagnostics.partial", in: app).exists, "an unselected trace channel is not a partial failure")
      XCTAssertTrue(app.buttons["diagnostics.capture.arm"].isEnabled)
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
      app.buttons["jobInspector.toggle"].click()
      for variant in ["complete", "partial", "unrecognized", "empty", "corrupt", "complete"] {
        runHistorySessionPhase("HiLog \(variant)", language: language, in: app, processID: processID) {
          openExactHistoryRecord("job-fixture-hilog-\(variant)", in: app)
          app.buttons["history.openWorkspace"].click()
          if variant == "corrupt" {
            XCTAssertTrue(element("diagnostics.session.failed", in: app).waitForExistenceFast(timeout: 15))
            XCTAssertFalse(element("diagnostics.hilog.summary", in: app).exists,
              "a failed read must clear the preceding successful summary")
            app.buttons[language == "(en)" ? "Retry reading" : "重新读取"].click()
            XCTAssertTrue(element("diagnostics.session.failed", in: app).waitForExistenceFast(timeout: 15))
            XCTAssertFalse(element("diagnostics.hilog.summary", in: app).exists,
              "retrying corrupt bytes must not restore an earlier summary")
          } else {
            assertDisplayed(element("diagnostics.hilog.job", in: app), equals: "job-fixture-hilog-\(variant)", timeout: 15)
            assertDisplayed(element("diagnostics.hilog.coverage", in: app), equals: hilogCoverageTitle(variant, language: language))
            let expectedI = variant == "complete" || variant == "partial" ? "1" : "0"
            assertDisplayed(element("diagnostics.hilog.count.I", in: app), equals: expectedI)
            assertDisplayed(element("diagnostics.hilog.count.E", in: app), equals: variant == "complete" ? "1" : "0")
            XCTAssertTrue(element("diagnostics.hilog.boundary", in: app).exists)
            XCTAssertFalse(element("diagnostics.preview.text", in: app).exists)
            XCTAssertFalse(element("diagnostics.alignment", in: app).exists,
              "a line-count summary has no clock alignment claim")
            XCTAssertFalse(app.buttons["diagnostics.capture.arm"].exists)
            app.buttons["diagnostics.session.reload"].click()
            assertDisplayed(element("diagnostics.hilog.job", in: app), equals: "job-fixture-hilog-\(variant)", timeout: 15)
            if variant == "partial" {
              Self.resizeRecoveryWindow(in: app, to: CGSize(width: 900, height: 650))
              let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
              shot.name = "HiLog partial summary narrow \(language)"
              shot.lifetime = .keepAlways
              add(shot)
              Self.resizeRecoveryWindow(in: app, to: CGSize(width: 1180, height: 783))
            }
          }
        }
      }
      runHistorySessionPhase("Return to captured session", language: language, in: app, processID: processID) {
        openExactHistoryRecord("job-fixture-diagnostics", in: app)
        app.buttons["history.openWorkspace"].click()
        assertDisplayed(element("diagnostics.session.job", in: app), equals: "job-fixture-diagnostics", timeout: 15)
        assertDisplayed(element("diagnostics.alignment", in: app), equals: alignment)
        assertDisplayed(element("diagnostics.mark.time.1", in: app), equals: missingTime)
        XCTAssertFalse(element("diagnostics.hilog.summary", in: app).exists,
          "returning to capture must replace the summary reader")
        XCTAssertFalse(element("diagnostics.preview.text", in: app).exists,
          "returning to capture must not restore an earlier sensitive preview")
        XCTAssertTrue(app.buttons["diagnostics.artifact.read.hilog.txt"].exists)
        XCTAssertTrue(app.buttons["diagnostics.capture.arm"].isEnabled)
        XCTAssertFalse(app.buttons["diagnostics.capture.mark"].isEnabled)
      }
      app.terminate()
    }
  }

  func openExactHistoryRecord(_ jobID: String, in app: XCUIApplication) {
    select("app.navigation.history", in: app)
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistenceFast(timeout: 30))
    search.click()
    search.typeKey("a", modifierFlags: .command)
    search.typeText(jobID)
    assertDisplayed(element("history.detail.job", in: app), equals: jobID, timeout: 30)
  }

  func hilogCoverageTitle(_ coverage: String, language: String) -> String {
    let labels = [
      "complete": ("All nonblank line headers recognized", "全部非空行的行首已识别"),
      "partial": ("Some line headers unrecognized", "部分行首未识别"),
      "unrecognized": ("No line headers recognized", "没有识别到行首"),
      "empty": ("No nonblank lines", "没有非空行"),
    ]
    guard let label = labels[coverage] else { return "unsupported coverage" }
    return language == "(en)" ? label.0 : label.1
  }

  /// Three Jobs come from a previously completed headless real capture and
  /// analysis. This UI leg only reads those exact records through production
  /// XPC. One App launch per language covers every record and reload.
  func testRealDeviceHilogSummariesReopenInOneSessionPerLanguage() throws {
    struct ExpectedSummary: Decodable {
      let jobID: String
      let sourceArtifactID: String
      let headerCoverage: String
      let lineCount: Int
      let levelCounts: [String: Int]
    }
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_REAL_DEVICE_HILOG_EXPECTATIONS"],
      path.hasPrefix("/")
    else { throw XCTSkip("Supply private expectations from completed real HiLog analysis Jobs") }
    let data = try Data(contentsOf: URL(filePath: path))
    XCTAssertLessThan(data.count, 32 * 1024)
    let expected = try JSONDecoder().decode([ExpectedSummary].self, from: data)
    guard expected.count == 3, Set(expected.map(\.jobID)).count == 3,
      expected.allSatisfy({ $0.jobID.hasPrefix("job-") && $0.sourceArtifactID.hasPrefix("ART-") })
    else { return XCTFail("three distinct real Runtime Jobs are required") }
    for language in ["(en)", "(zh-Hans)"] {
      let app = XCUIApplication()
      if app.state != .notRunning { app.terminate() }
      app.launchArguments = [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
        "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection", "-AppleLanguages", language,
      ]
      app.launch()
      app.activate()
      defer { app.terminate() }
      let processID = try XCTUnwrap(NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").first?.processIdentifier)
      for (index, item) in expected.enumerated() {
        runHistorySessionPhase("Real HiLog record", language: language, in: app, processID: processID) {
          openExactHistoryRecord(item.jobID, in: app)
          app.buttons["history.openWorkspace"].click()
          assertDisplayed(element("diagnostics.hilog.job", in: app), equals: item.jobID, timeout: 30)
          assertDisplayed(element("diagnostics.hilog.coverage", in: app), equals: hilogCoverageTitle(item.headerCoverage, language: language))
          assertDisplayed(element("diagnostics.hilog.count.lines", in: app), equals: String(item.lineCount))
          for level in ["D", "I", "W", "E", "F"] {
            assertDisplayed(element("diagnostics.hilog.count.\(level)", in: app), equals: String(item.levelCounts[level] ?? -1))
          }
          assertDisplayed(element("diagnostics.hilog.sourceArtifact", in: app), equals: item.sourceArtifactID)
          XCTAssertFalse(element("diagnostics.preview.text", in: app).exists)
          XCTAssertFalse(element("diagnostics.alignment", in: app).exists)
          app.buttons["diagnostics.session.reload"].click()
          assertDisplayed(element("diagnostics.hilog.job", in: app), equals: item.jobID, timeout: 30)
          let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
          screenshot.name = "Real HiLog summary \(language) record \(index + 1)"
          screenshot.lifetime = .keepAlways
          add(screenshot)
        }
      }
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

}
