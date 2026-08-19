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
        "device.row.", "device.row.observed."))
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

  // MARK: - One launch per language

  func testEnglishSweepOfEveryWorkspace() {
    sweep(
      language: "(en)",
      overview: Overview(
        server: "Healthy", trust: "Ready", channel: "Unverified", attention: "1 item",
        attentionNone: "None",
        attentionClear: "Nothing needs attention in the current diagnostics."),
      flash: Flash(
        availability: "AVAILABLE — Runtime can materialize flash.dayu200",
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
        inspectorReadOnly: "Read-only Runtime facts",
        debugPanels: [
          "Bounded HiLog capture", "HAP package", "Forward / reverse rules",
          "Provider invocation disclosure",
        ],
        uiDumpAvailable: "Runtime operation is available",
        uiDumpUnavailable: "Runtime operation is unavailable",
        traceAvailable: "Diagnostics operation is available",
        traceUnavailable: "Diagnostics operation is unavailable",
        settingsPanes: ["General", "Toolchains", "Storage", "Updates", "Diagnostics"]),
      history: History(
        readOnlyNote:
          "This workspace reads Runtime state. It cannot submit, cancel, or retry anything.",
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
        availability: "AVAILABLE — Runtime 可生成 flash.dayu200 计划",
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
        inspectorReadOnly: "只读 Runtime 事实",
        debugPanels: [
          "有界 HiLog 采集", "HAP 安装包", "Forward / reverse 规则", "Provider 调用披露",
        ],
        uiDumpAvailable: "Runtime 操作可用",
        uiDumpUnavailable: "Runtime 操作不可用",
        traceAvailable: "诊断操作可用",
        traceUnavailable: "诊断操作不可用",
        settingsPanes: ["通用", "工具链", "存储", "更新", "诊断"]),
      history: History(
        readOnlyNote: "此工作区只读取 Runtime 状态，不能提交、取消或重试任何操作。",
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
    let inspectorReadOnly: String
    let debugPanels: [String]
    let uiDumpAvailable: String
    let uiDumpUnavailable: String
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
    let windowFrame = app.windows.firstMatch.frame
    XCTAssertGreaterThan(
      windowFrame.width, 900, "the window opened at its minimum", file: file, line: line)
    if let visible = NSScreen.main?.visibleFrame, visible.width >= 1180, visible.height >= 760 {
      XCTAssertEqual(windowFrame.width, 1180, accuracy: 1, file: file, line: line)
      XCTAssertEqual(windowFrame.height, 760, accuracy: 1, file: file, line: line)
    }

    // Overview answers its four questions on the first screen.
    XCTAssertTrue(
      element("overview.status.server.value", in: app).waitForExistenceFast(timeout: 15),
      file: file, line: line)
    assertDisplayed(element("overview.status.server.value", in: app), equals: overview.server)
    assertDisplayed(element("overview.status.trust.value", in: app), equals: overview.trust)
    assertDisplayed(element("overview.status.channel.value", in: app), equals: overview.channel)
    assertDisplayed(
      element("overview.status.needsAttention.value", in: app), equals: overview.attention)
    for section in [
      "overview.section.serverToolchain", "overview.section.deviceChannel",
      "overview.section.capabilities", "overview.section.needsAttention",
    ] {
      XCTAssertTrue(element(section, in: app).exists, "\(section) missing", file: file, line: line)
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
    let attentionClear = app.staticTexts["overview.attention.clear"]
    XCTAssertTrue(attentionClear.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(attentionClear, equals: overview.attentionClear)
    assertDisplayed(
      app.staticTexts["overview.status.needsAttention.value"], equals: overview.attentionNone)

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

    // Debug is a complete native workspace with four distinct panels. The
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
    let debugStart = app.buttons["debug.logs.start"]
    XCTAssertTrue(debugStart.exists, file: file, line: line)
    XCTAssertFalse(debugStart.isEnabled, file: file, line: line)
    // Pausing is a viewport action that exists only while a capture runs; in
    // this read-only build nothing captures, so the button stays disabled.
    let pauseViewport = app.buttons["debug.logs.pauseViewport"]
    XCTAssertTrue(pauseViewport.exists, file: file, line: line)
    XCTAssertFalse(pauseViewport.isEnabled, file: file, line: line)
    XCTAssertEqual(workspaces.debugPanels.count, 4, file: file, line: line)
    let debugTabIDs = ["logs", "apps", "network", "commands"]
    for (tabID, panelTitle) in zip(debugTabIDs, workspaces.debugPanels) {
      let tab = element("debug.tab.\(tabID)", in: app)
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5), file: file, line: line)
      clickCorrectingNavigationSplitAXOffset(tab, in: app)
      XCTAssertTrue(
        app.staticTexts[panelTitle].waitForExistenceFast(timeout: 5),
        "Debug panel \(tabID) did not render", file: file, line: line)
    }

    // UI Dump presents its canonical recipes, artifact contract and locked
    // run action even when Runtime has not published the required operation.
    select("app.navigation.uiDump", in: app)
    assertDisplayed(
      element("uiDump.availability.status", in: app),
      oneOf: [workspaces.uiDumpAvailable, workspaces.uiDumpUnavailable], timeout: 10)
    XCTAssertTrue(
      element("uiDump.target.empty", in: app).exists
        || element("uiDump.target.picker", in: app).exists,
      "UI Dump must expose either a selected Runtime target or its explicit empty state",
      file: file, line: line)
    XCTAssertTrue(
      element("uiDump.recipe.fullDefaultTree", in: app).exists,
      file: file, line: line)
    // elementTree is the default recipe; the section's live echo proves it by
    // showing its exact hidumper arguments, in any language.
    XCTAssertTrue(
      displayedText(for: element("uiDump.recipe.liveArguments", in: app))
        .contains("-element -c"),
      "the live argument echo must reflect the default elementTree recipe",
      file: file, line: line)
    XCTAssertTrue(element("uiDump.artifacts.table", in: app).exists, file: file, line: line)
    let uiDumpRun = app.buttons["uiDump.run"]
    XCTAssertTrue(uiDumpRun.exists, file: file, line: line)
    XCTAssertFalse(uiDumpRun.isEnabled, file: file, line: line)
    XCTAssertFalse(app.staticTexts["app.unavailable.title"].exists, file: file, line: line)

    // Trace likewise keeps the bounded configuration visible and its start
    // action locked while production capability facts are unavailable.
    select("app.navigation.trace", in: app)
    let traceAvailability = element("trace.availability.status", in: app)
    assertDisplayed(
      traceAvailability,
      oneOf: [workspaces.traceAvailable, workspaces.traceUnavailable], timeout: 10)
    for identifier in [
      "trace.configuration.mode", "trace.preset.picker", "trace.duration", "trace.buffer",
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
    if traceHasEmptyTarget
      || displayedValues(for: traceAvailability).contains(workspaces.traceUnavailable)
    {
      XCTAssertFalse(traceStart.isEnabled, file: file, line: line)
    }
    XCTAssertFalse(app.staticTexts["app.unavailable.title"].exists, file: file, line: line)

    // Custom is another entry to the same request: it arrives carrying the
    // current preset's tag family instead of an empty selection, and the
    // members render as individually toggleable chips with a count.
    element("trace.configuration.mode.custom", in: app).click()
    XCTAssertTrue(
      element("trace.custom.count", in: app).waitForExistenceFast(timeout: 5),
      "custom mode must arrive with the preset's tags selected",
      file: file, line: line)
    XCTAssertTrue(
      element("trace.custom.tag.ace", in: app).exists,
      "preset members must be visible as toggles", file: file, line: line)
    element("trace.configuration.mode.preset", in: app).click()

    // History renders real Runtime facts and offers no way to submit.
    select("app.navigation.history", in: app)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistenceFast(timeout: 10), file: file, line: line)
    assertDisplayed(app.staticTexts["history.readOnlyNote"], equals: history.readOnlyNote)
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
    // It renders the same Runtime fixture as History and remains read-only:
    // expanding it exposes facts and recovery guidance, never lifecycle actions.
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
      app.staticTexts[workspaces.inspectorReadOnly], equals: workspaces.inspectorReadOnly)
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
    // interaction. Both languages verify the five panes and the safe controls;
    // the update state machine asserts English status strings, so English
    // carries that walk.
    openSettings(in: app)
    for pane in workspaces.settingsPanes {
      XCTAssertTrue(
        app.buttons[pane].waitForExistenceFast(timeout: 10),
        "Settings must expose the \(pane) pane", file: file, line: line)
    }
    app.buttons[workspaces.settingsPanes[1]].click()
    XCTAssertTrue(
      app.buttons["settings.toolchains.choose"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertTrue(app.buttons["settings.toolchains.refresh"].exists, file: file, line: line)
    app.buttons[workspaces.settingsPanes[2]].click()
    for identifier in [
      "settings.storage.chooseRoot", "settings.storage.quota", "settings.storage.margin",
      "settings.storage.retention", "settings.storage.save",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).waitForExistenceFast(timeout: 10),
        "\(identifier) missing", file: file, line: line)
    }
    app.buttons[workspaces.settingsPanes[4]].click()
    XCTAssertTrue(
      app.buttons["settings.diagnostics.preview"].waitForExistenceFast(timeout: 10),
      file: file, line: line)
    XCTAssertFalse(app.buttons["settings.diagnostics.export"].exists, file: file, line: line)
    app.buttons[workspaces.settingsPanes[3]].click()
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
      ["logs", "apps", "network", "commands"], workspaces.debugPanels
    ) {
      let tab = element("debug.tab.\(tabID)", in: app)
      XCTAssertTrue(tab.waitForExistenceFast(timeout: 5), file: file, line: line)
      clickCorrectingNavigationSplitAXOffset(tab, in: app)
      XCTAssertTrue(
        app.staticTexts[panelTitle].waitForExistenceFast(timeout: 5),
        "localized Debug panel \(tabID) did not render", file: file, line: line)
    }

    select("app.navigation.uiDump", in: app, file: file, line: line)
    assertDisplayed(
      element("uiDump.availability.status", in: app),
      oneOf: [workspaces.uiDumpAvailable, workspaces.uiDumpUnavailable],
      timeout: 10, file: file, line: line)
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
      app.staticTexts[workspaces.inspectorReadOnly], equals: workspaces.inspectorReadOnly)

    openSettings(in: app)
    for pane in workspaces.settingsPanes {
      XCTAssertTrue(
        app.buttons[pane].waitForExistenceFast(timeout: 10),
        "Settings must expose localized pane \(pane)", file: file, line: line)
    }
  }

  /// The exact-plan fixture is presentation-only: it bypasses the system file
  /// picker so this flow can walk the complete inline review inside the
  /// sweep's launch. The enabled one-click Flash action is never clicked, so
  /// the fixture run exercises the one-click Loader-bind + Flash handoff only
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
      "app.navigation.uiDump", "app.navigation.trace", "app.navigation.history",
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
    ]
    if resetDeviceNames { launchArguments.append("--ui-test-reset-device-names") }
    app.launchArguments = launchArguments + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
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

  private func openSettings(in app: XCUIApplication) {
    let settings = element("app.toolbar.openSettings", in: app)
    XCTAssertTrue(settings.waitForExistenceFast(timeout: 10))
    settings.click()
  }
}
