import AppKit
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
        server: "Healthy", trust: "Ready", channel: "Unverified", attention: "1 item",
        attentionNone: "None",
        attentionClear: "Nothing needs attention in the current diagnostics."),
      flash: Flash(
        availability: "AVAILABLE — Runtime can materialize flash.dayu200@1",
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
          + "notExecuted(planned). No operation was submitted."),
      workspaces: Workspaces(
        inspectorShow: "Show job inspector",
        inspectorReadOnly: "Read-only Runtime facts",
        debugPanels: [
          "Bounded HiLog capture", "HAP package", "Forward / reverse rules",
          "Provider invocation disclosure",
        ],
        uiDumpUnavailable: "Runtime operation is unavailable",
        traceUnavailable: "Diagnostics operation is unavailable"),
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

  func testSimplifiedChineseSweepOfEveryWorkspace() {
    sweep(
      language: "(zh-Hans)",
      overview: Overview(
        server: "正常", trust: "已就绪", channel: "未验证", attention: "1 项",
        attentionNone: "无",
        attentionClear: "当前诊断中没有需要处理的事项。"),
      flash: Flash(
        availability: "AVAILABLE — Runtime 可生成 flash.dayu200@1 计划",
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
          + "未提交任何操作。"),
      workspaces: Workspaces(
        inspectorShow: "展开 Job 检查器",
        inspectorReadOnly: "只读 Runtime 事实",
        debugPanels: [
          "有界 HiLog 采集", "HAP 安装包", "Forward / reverse 规则", "Provider 调用披露",
        ],
        uiDumpUnavailable: "Runtime 操作不可用",
        traceUnavailable: "诊断操作不可用"),
      history: History(
        readOnlyNote: "此工作区只读取 Runtime 状态，不能提交、取消或重试任何操作。",
        outcomeUnknown: "结果未知——此 Job 对设备的影响从未被确认。",
        waitingForHuman: "等待人工处理。",
        interruptedRowState: "已中断 · 结果未知",
        emptyTitle: "尚无 Runtime Job",
        emptyDescription: "ArkDeck Runtime 在本机尚未记录任何 Job。",
        residue: "有 2 项未清理残留。"))
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
    let uiDumpUnavailable: String
    let traceUnavailable: String
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
    XCTAssertTrue(attentionClear.waitForExistence(timeout: 10), file: file, line: line)
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
    XCTAssertTrue(unauthorizedDevice.waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertTrue(
      element("device.row.150100469346864", in: app).exists, file: file, line: line)
    // The adopted row names what its last observation recorded — firmware and
    // transport — as raw domain strings, identical in every language.
    XCTAssertTrue(
      displayedText(for: element("device.row.150100469346864", in: app))
        .contains("OpenHarmony 5.0.0.71"),
      "the adopted device row must carry its observed firmware",
      file: file, line: line)
    clickCorrectingNavigationSplitAXOffset(unauthorizedDevice, in: app)
    XCTAssertTrue(
      element("device.trust.steps", in: app).waitForExistence(timeout: 10),
      "the unauthorized device must show its trust steps", file: file, line: line)
    assertDisplayed(app.staticTexts["device.fact.state"], equals: "Unauthorized")
    let recheck = app.buttons["device.action.recheck"]
    XCTAssertTrue(recheck.exists, file: file, line: line)
    XCTAssertTrue(recheck.isEnabled, file: file, line: line)
    XCTAssertFalse(
      app.buttons["device.action.adopt"].exists,
      "the App must not offer adoption", file: file, line: line)
    select("app.navigation.overview", in: app)
    XCTAssertTrue(
      app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 10),
      "leaving the device detail returns to a workspace", file: file, line: line)

    // Flash is a real production planning workspace. Its fixture provides only
    // the same immutable Runtime facts the production XPC reader consumes; it
    // has no submit/run/authorization surface and cannot touch a device.
    select("app.navigation.flash", in: app)
    assertDisplayed(
      app.staticTexts["flash.availability.status"], equals: flash.availability)
    assertDisplayed(app.staticTexts["flash.mode.badge"], equals: flash.modeBadge)
    assertDisplayed(element("flash.target", in: app), equals: flash.target)
    assertDisplayed(element("flash.plan.empty", in: app), equals: flash.emptyPlan)
    assertDisplayed(element("flash.plan.prepare", in: app), equals: flash.prepareAction)
    assertDisplayed(app.staticTexts["flash.runtime.jobID"], equals: "job-fixture-0002")
    assertDisplayed(app.staticTexts["flash.runtime.state"], equals: flash.runtimeState)
    assertDisplayed(element("flash.runtime.result", in: app), equals: flash.runtimeResult)
    assertDisplayed(
      app.staticTexts["flash.runtime.recovery.guidance"],
      equals: flash.runtimeRecovery)
    XCTAssertTrue(element("flash.runtime.attention", in: app).exists, file: file, line: line)
    XCTAssertTrue(app.buttons["flash.runtime.openHistory"].exists, file: file, line: line)
    assertDisplayed(
      app.staticTexts.matching(identifier: "flash.noOperationSubmitted").firstMatch,
      equals: flash.noSubmission)
    XCTAssertTrue(
      app.staticTexts[flash.imageBlocker].exists,
      "the disabled preparation action needs a visible recovery instruction",
      file: file, line: line)

    // Execute can be reviewed only after an exact plan exists, but the App has
    // no E2 submit or authority transport. The locked boundary and disabled
    // review action stay visible, and returning to plan-only has no side effect.
    // Execute is a real, Runtime-owned submission surface now. With no plan
    // prepared the review action renders disabled, and no submit control
    // exists before a confirmed human handoff.
    let executeMode = element("flash.mode.execute", in: app)
    XCTAssertTrue(executeMode.exists, file: file, line: line)
    executeMode.click()
    let reviewImpact = app.buttons["flash.execute.review"]
    XCTAssertTrue(reviewImpact.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertFalse(reviewImpact.isEnabled, file: file, line: line)
    XCTAssertFalse(app.buttons["flash.execute.submit"].exists, file: file, line: line)
    element("flash.mode.planOnly", in: app).click()
    XCTAssertFalse(app.buttons["flash.execute.review"].exists, file: file, line: line)

    // Debug is a complete native workspace with four distinct panels. The
    // production App read channel has no target in this fixture, so every
    // mutation stays disabled while its exact form remains inspectable.
    // The page title lives in the window toolbar; the content area carries
    // only the scope line, so that is what proves the workspace rendered.
    select("app.navigation.debug", in: app)
    XCTAssertTrue(
      element("debug.scope", in: app).waitForExistence(timeout: 10),
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
      XCTAssertTrue(tab.waitForExistence(timeout: 5), file: file, line: line)
      clickCorrectingNavigationSplitAXOffset(tab, in: app)
      XCTAssertTrue(
        app.staticTexts[panelTitle].waitForExistence(timeout: 5),
        "Debug panel \(tabID) did not render", file: file, line: line)
    }

    // UI Dump presents its canonical recipes, artifact contract and locked
    // run action even when Runtime has not published the required operation.
    select("app.navigation.uiDump", in: app)
    assertDisplayed(
      element("uiDump.availability.status", in: app), equals: workspaces.uiDumpUnavailable,
      timeout: 10)
    XCTAssertTrue(element("uiDump.target.empty", in: app).exists, file: file, line: line)
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
    assertDisplayed(
      element("trace.availability.status", in: app), equals: workspaces.traceUnavailable,
      timeout: 10)
    for identifier in [
      "trace.target.empty", "trace.configuration.mode", "trace.preset.picker",
      "trace.duration", "trace.buffer",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).exists, "\(identifier) missing",
        file: file, line: line)
    }
    let traceStart = app.buttons["trace.start"]
    XCTAssertTrue(traceStart.exists, file: file, line: line)
    XCTAssertFalse(traceStart.isEnabled, file: file, line: line)
    XCTAssertFalse(app.staticTexts["app.unavailable.title"].exists, file: file, line: line)

    // Custom is another entry to the same request: it arrives carrying the
    // current preset's tag family instead of an empty selection, and the
    // members render as individually toggleable chips with a count.
    element("trace.configuration.mode.custom", in: app).click()
    XCTAssertTrue(
      element("trace.custom.count", in: app).waitForExistence(timeout: 5),
      "custom mode must arrive with the preset's tags selected",
      file: file, line: line)
    XCTAssertTrue(
      element("trace.custom.tag.ace", in: app).exists,
      "preset members must be visible as toggles", file: file, line: line)
    element("trace.configuration.mode.preset", in: app).click()

    // History renders real Runtime facts and offers no way to submit.
    select("app.navigation.history", in: app)
    XCTAssertTrue(
      element("history.table", in: app).waitForExistence(timeout: 10), file: file, line: line)
    assertDisplayed(app.staticTexts["history.readOnlyNote"], equals: history.readOnlyNote)
    for forbidden in ["history.submit", "history.cancel", "history.retry", "history.run"] {
      XCTAssertFalse(
        app.buttons[forbidden].exists, "\(forbidden) must not exist", file: file, line: line)
    }

    // The newest visible Job is selected automatically, so the workspace is
    // immediately useful and never pauses on an obsolete empty prompt.
    XCTAssertTrue(app.staticTexts["history.detail.select"].waitForNonExistence(timeout: 5))
    assertDisplayed(app.staticTexts["history.detail.job"], equals: "job-fixture-0002")

    // An unknown outcome is stated, never folded into the terminal state.
    // The table's own text is not clickable; the row is. Reach it through the
    // per-row state identifier, which is the only identifier the row carries.
    let interruptedRow = app.cells
      .containing(.staticText, identifier: "history.row.state.job-fixture-0002").firstMatch
    XCTAssertTrue(interruptedRow.waitForExistence(timeout: 10), file: file, line: line)
    // An unknown outcome is part of the row's text, not a detail-only fact:
    // "已中断" alone would read as a mere variant of failure.
    assertDisplayed(
      app.staticTexts["history.row.state.job-fixture-0002"],
      equals: history.interruptedRowState)
    clickCorrectingNavigationSplitAXOffset(interruptedRow, in: app)
    XCTAssertTrue(
      app.staticTexts["history.detail.select"].waitForNonExistence(timeout: 5),
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
    XCTAssertTrue(succeededRow.waitForExistence(timeout: 10), file: file, line: line)
    clickCorrectingNavigationSplitAXOffset(succeededRow, in: app)
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
    XCTAssertTrue(emptyTitle.waitForExistence(timeout: 10), file: file, line: line)
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
    XCTAssertTrue(
      app.staticTexts["flash.runtime.empty"].waitForExistence(timeout: 10),
      "Flash must distinguish a reachable empty Runtime history",
      file: file, line: line)

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
      element("jobRecovery.banner", in: app).waitForExistence(timeout: 10),
      "an unknown Runtime outcome must remain visible above every workspace",
      file: file, line: line)
    let inspectorToggle = app.buttons["jobInspector.toggle"]
    XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 10), file: file, line: line)
    assertDisplayed(inspectorToggle, equals: workspaces.inspectorShow)
    inspectorToggle.click()
    XCTAssertTrue(
      element("jobInspector.list", in: app).waitForExistence(timeout: 10),
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
      element("jobInspector.list", in: app).waitForNonExistence(timeout: 5),
      file: file, line: line)

    // Finish on Advanced Diagnostics for the same AX-cache reason.
    let toggle = app.buttons["overview.advanced.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertFalse(app.staticTexts["hdc.toolchain.path"].exists, file: file, line: line)
    app.typeKey("d", modifierFlags: [.command, .shift])
    assertDisplayed(app.staticTexts["hdc.toolchain.path"], equals: "/Applications/DevEco/hdc")
    assertDisplayed(app.staticTexts["hdc.counters.autoLifecycle"], equals: "0")
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
      arguments: [
        "--ui-test-runtime-history", "--ui-test-runtime-history-unreachable", "--ui-test-flash",
      ])
    select("app.navigation.history", in: app)

    XCTAssertTrue(app.staticTexts["history.unavailable.title"].waitForExistence(timeout: 15))
    assertDisplayed(
      app.staticTexts["history.unavailable.reason"],
      equals: "ArkDeck Runtime is not reachable: fixture")
    XCTAssertFalse(
      element("history.table", in: app).exists, "an unreadable history shows no table")
    XCTAssertFalse(app.staticTexts["history.empty.title"].exists, "it is not an empty history")

    select("app.navigation.flash", in: app)
    XCTAssertTrue(app.staticTexts["flash.runtime.unavailable"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["flash.runtime.empty"].exists)
  }

  // The exact-plan fixture is presentation-only: it bypasses the system file
  // picker so UI automation can walk every review state, but its provider has
  // no transport and the accepted confirmation still creates no Runtime Job.
  func testExactFlashPlanConfirmationStaysPresentationOnly() {
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-runtime-history-empty",
        "--ui-test-flash-plan", "-AppleLanguages", "(en)",
      ])
    select("app.navigation.flash", in: app)

    XCTAssertTrue(
      element("flash.plan.steps", in: app).waitForExistence(timeout: 15),
      "the fixture must materialize an exact execute plan")

    let partitions = element("flash.plan.partitions.disclosure", in: app)
    XCTAssertTrue(partitions.exists)
    scrollIntoView(partitions, in: app)
    partitions.click()
    XCTAssertTrue(
      element("flash.plan.partition.system", in: app).waitForExistence(timeout: 5),
      "mapped partition details must be inspectable")
    partitions.click()

    // Prerequisites are a top-level, always-expanded section before the exact
    // plan — what has to hold is readable without a disclosure click.
    let prerequisites = element("flash.plan.prerequisitesList", in: app)
    XCTAssertTrue(prerequisites.exists)
    scrollIntoView(prerequisites, in: app)
    XCTAssertTrue(app.staticTexts["Runtime check pending"].waitForExistence(timeout: 5))

    let review = app.buttons["flash.execute.review"]
    XCTAssertTrue(review.exists)
    XCTAssertTrue(review.isEnabled)
    scrollIntoView(review, in: app)
    review.click()
    guard displayedValues(for: review).contains("Confirm this exact Flash plan") else {
      return XCTFail("review action state: \(String(describing: review.value))")
    }

    let confirmationSheet = element("flash.confirm.sheet", in: app)
    XCTAssertTrue(confirmationSheet.waitForExistence(timeout: 10))
    let expectedPhrase = app.staticTexts["flash.confirm.expectedDestructivePhrase"]
    XCTAssertTrue(expectedPhrase.waitForExistence(timeout: 5))
    guard let phrase = displayedValues(for: expectedPhrase).first(where: { $0.hasPrefix("FLASH ") })
    else {
      return XCTFail("the confirmation sheet must expose its exact FLASH phrase")
    }

    let destructiveField = app.textFields["flash.confirm.destructivePhrase"]
    destructiveField.click()
    destructiveField.typeText(phrase)
    let userdataField = app.textFields["flash.confirm.userdataPhrase"]
    userdataField.click()
    userdataField.typeText("ERASE-USERDATA")

    let accept = app.buttons["flash.confirm.accept"]
    scrollIntoView(accept, in: app)
    accept.click()
    XCTAssertTrue(
      element("flash.execute.handoff", in: app).waitForExistence(timeout: 10),
      "exact phrases must produce the local human-review receipt")
    // The handoff arms a real submit action now. This test deliberately stops
    // at the receipt: the button must exist and be enabled, and remain
    // unclicked, so the fixture run still submits nothing.
    let submit = app.buttons["flash.execute.submit"]
    XCTAssertTrue(submit.exists)
    XCTAssertTrue(submit.isEnabled)
    XCTAssertFalse(element("flash.execute.terminal", in: app).exists)
    XCTAssertTrue(app.staticTexts["flash.runtime.empty"].exists)
  }

  func testFlashRuntimeActivityUsesRealStagesAndTerminalResult() throws {
    try "--ui-test-runtime-flash-running".write(
      to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-flash", "--ui-test-fixture-state",
        fixtureStateFileURL.path, "-AppleLanguages", "(en)",
      ])
    select("app.navigation.flash", in: app)

    assertDisplayed(app.staticTexts["flash.runtime.state"], equals: "Running", timeout: 15)
    assertDisplayed(
      element("flash.runtime.result", in: app),
      equals:
        "Runtime is still processing this Job. Progress is stage-based; no percentage is fabricated."
    )
    XCTAssertTrue(element("flash.runtime.progress", in: app).exists)
    XCTAssertFalse(element("flash.runtime.attention", in: app).exists)

    try "--ui-test-runtime-flash-succeeded".write(
      to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    app.buttons["flash.refresh"].click()
    assertDisplayed(app.staticTexts["flash.runtime.state"], equals: "Succeeded", timeout: 10)
    assertDisplayed(
      element("flash.runtime.result", in: app),
      equals: "Runtime reports success after the Flash and postflight checks.")
    XCTAssertFalse(element("flash.runtime.progress", in: app).exists)
    XCTAssertFalse(element("flash.runtime.attention", in: app).exists)
  }

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
  func testEverySettingsUpdateStateRendersAndOnlyItsOwnAction() throws {
    try? "--ui-test-auto-update-idle".write(
      to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    let app = launch(
      arguments: [
        "--ui-test-runtime-history", "--ui-test-auto-update-idle",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", "(en)",
      ])
    XCTAssertTrue(app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 15))

    app.typeKey(",", modifierFlags: .command)
    let updatesTab = app.buttons["Updates"]
    XCTAssertTrue(
      updatesTab.waitForExistence(timeout: 10),
      "Command-comma must open the Settings scene")
    updatesTab.click()
    XCTAssertTrue(
      app.staticTexts["update.status"].waitForExistence(timeout: 10),
      "the Updates pane must render its status")
    // The controls the main window must not carry are the ones this scene owns.
    // A checkbox reports its state as a number, not as text, so it is read as
    // one rather than through the string helper the rest of this file uses.
    let automaticChecks = app.checkBoxes["update.automaticChecks"]
    XCTAssertTrue(automaticChecks.exists)
    XCTAssertEqual(
      (automaticChecks.value as? NSNumber)?.intValue, 1, "automatic checks default to on")

    // Idle, available, failed, then awaiting-consent last: it is the one state
    // that disables Check Now, so it cannot be walked out of.
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

  /// Every Settings module pane is reachable in the system Settings scene.
  /// This test deliberately avoids file panels, policy writes and exports.
  func testSettingsHasAllFiveNativePanesAndSafeControls() {
    let app = launch(arguments: ["-AppleLanguages", "(en)"])
    XCTAssertTrue(app.staticTexts["overview.status.server.value"].waitForExistence(timeout: 15))

    app.typeKey(",", modifierFlags: .command)
    for title in ["General", "Toolchains", "Storage", "Updates", "Diagnostics"] {
      XCTAssertTrue(
        app.buttons[title].waitForExistence(timeout: 10),
        "Settings must expose the \(title) pane")
    }

    app.buttons["Toolchains"].click()
    XCTAssertTrue(app.buttons["settings.toolchains.choose"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["settings.toolchains.refresh"].exists)

    app.buttons["Storage"].click()
    for identifier in [
      "settings.storage.chooseRoot", "settings.storage.quota", "settings.storage.margin",
      "settings.storage.retention", "settings.storage.save",
    ] {
      XCTAssertTrue(
        element(identifier, in: app).waitForExistence(timeout: 10),
        "\(identifier) missing")
    }

    app.buttons["Updates"].click()
    XCTAssertTrue(app.staticTexts["update.status"].waitForExistence(timeout: 10))

    app.buttons["Diagnostics"].click()
    XCTAssertTrue(app.buttons["settings.diagnostics.preview"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["settings.diagnostics.export"].exists)
  }

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
        toolbar.waitForExistence(timeout: 5), "\(state.flag) must raise attention",
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
    let windowFrame = app.windows.firstMatch.frame
    let toolbar = app.toolbars.firstMatch
    let contentMinY = toolbar.exists ? toolbar.frame.maxY : windowFrame.minY
    let contentFrame = CGRect(
      x: windowFrame.minX, y: contentMinY,
      width: windowFrame.width, height: max(0, windowFrame.maxY - contentMinY))
    let visibleFrame = cell.frame.intersection(contentFrame)
    if !visibleFrame.isNull, visibleFrame.height > 1 {
      let normalizedY = (visibleFrame.midY - cell.frame.minY) / cell.frame.height
      cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: normalizedY)).click()
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
    let overviewCell = app.outlines.cells
      .containing(.staticText, identifier: "app.navigation.overview").firstMatch
    XCTAssertTrue(overviewCell.exists, file: file, line: line)
    let focusPoint = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: overviewCell.frame.midX - windowFrame.minX,
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
    let overviewCell = app.outlines.cells
      .containing(.staticText, identifier: "app.navigation.overview").firstMatch
    let expectedOverviewMidY = contentMinY + 35
    let verticalCorrection = expectedOverviewMidY - overviewCell.frame.midY
    window.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: element.frame.midX - windowFrame.minX,
          dy: element.frame.midY + verticalCorrection - windowFrame.minY))
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
    let matches = NSPredicate { [weak self] _, _ in
      self?.displayedValues(for: element).contains(expected) ?? false
    }
    let result = XCTWaiter.wait(
      for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
    XCTAssertTrue(
      result == .completed || displayedValues(for: element).contains(expected),
      "expected \(expected), got: \(displayedText(for: element))", file: file, line: line)
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
    guard let host = hosts.min(by: { lhs, rhs in
      lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
    }) else { return }

    var attempts = 0
    while attempts < 25 {
      let target = element.frame
      let viewport = host.frame
        .intersection(app.windows.firstMatch.frame)
        .insetBy(dx: 0, dy: 60)
      if target.minY >= viewport.minY && target.maxY <= viewport.maxY && element.isHittable {
        return
      }
      host.scroll(byDeltaX: 0, deltaY: -120)
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
        // Without this the App builds the real updater and decides what to
        // show by checking for updates, which is neither deterministic nor
        // free of network effects. A test that wants a different update state
        // passes its own argument; this only makes the default one declared.
        "--ui-test-auto-update-idle",
      ] + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    app.activate()
    let openedInitialWindow = app.windows.firstMatch.waitForExistence(timeout: 2)
    if !openedInitialWindow {
      app.typeKey("n", modifierFlags: .command)
      XCTAssertTrue(
        app.windows.firstMatch.waitForExistence(timeout: 5), "ArkDeck must create a test window")
    }
    return app
  }
}
