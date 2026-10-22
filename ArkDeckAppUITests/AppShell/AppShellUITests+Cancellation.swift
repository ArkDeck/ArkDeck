import AppKit
import XCTest

extension AppShellUITests {
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

  func assertDefaultWindowGeometry(
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
  func sweep(
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
    // The periodic read keeps the last verdict visible while disabling this
    // action. A matching verdict alone does not mean that read has finished.
    XCTAssertTrue(
      waitUntil(timeout: 10) { recheck.exists && recheck.isEnabled },
      "Re-check must become enabled after the current observation finishes",
      file: file, line: line)
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
    // The fixture answers every candidate read from its state file, and the
    // App re-reads the candidates on its own every ten seconds (its one live
    // device observation). A flip written before the retry let such a tick
    // publish Connected first, and a Connected device has no retry to click.
    // So the retry starts on the Unauthorized device, and the device flips
    // only while the retried wait is polling.
    beginWait.click()
    XCTAssertTrue(
      element("device.wait.polling", in: app).waitForExistenceFast(timeout: 5),
      "retrying must restart the countdown", file: file, line: line)
    XCTAssertFalse(
      element("device.wait.timedOut", in: app).exists,
      "the retried wait replaces the closed window's verdict", file: file, line: line)
    writeFixtureState("--ui-test-device-authorized", in: app, file: file, line: line)
    XCTAssertTrue(
      element("device.trust.ready", in: app).waitForExistenceFast(timeout: 10),
      "an authorized device ends the wait as ready", file: file, line: line)
    // A Connected device shows neither the countdown nor a verdict, and a
    // live tick can publish Connected before the wait's own probe does, so
    // what the wait left is read back on an Unauthorized device. Re-check
    // stays disabled while the wait polls, so enabled means the wait has
    // returned; resetting the fixture and re-checking then shows what is left.
    // No countdown and no verdict remain: the wait ended ready, and a read
    // that showed the device Connected would have ended any verdict anyway.
    XCTAssertTrue(
      waitUntil(timeout: 10) { recheck.exists && recheck.isEnabled },
      "the retried wait must return once the device is authorized", file: file, line: line)
    writeFixtureState("", in: app, file: file, line: line)
    recheck.click()
    // Fifteen seconds spans one live tick: a tick that read the file just
    // before the reset can publish Connected once more, and the next one
    // reads Unauthorized.
    assertDisplayed(
      element("device.fact.state", in: app), equals: "Unauthorized", timeout: 15,
      file: file, line: line)
    XCTAssertFalse(
      element("device.wait.timedOut", in: app).exists,
      "no timed-out verdict remains after the device read Connected", file: file, line: line)
    XCTAssertFalse(element("device.wait.polling", in: app).exists, file: file, line: line)
    XCTAssertFalse(element("device.wait.unavailable", in: app).exists, file: file, line: line)
    XCTAssertTrue(beginWait.isEnabled, file: file, line: line)
    // A verdict describes the device as its wait left it. Time a wait out
    // once more, then let the device be trusted without a retry and bring it
    // back to Unauthorized: the Connected read in between ends the old
    // verdict, so the device offers a fresh start instead of a timed-out
    // banner from a wait that no longer applies.
    beginWait.click()
    XCTAssertTrue(
      element("device.wait.timedOut", in: app).waitForExistenceFast(timeout: 15),
      "the second wait must time out on the Unauthorized device", file: file, line: line)
    XCTAssertTrue(
      waitUntil(timeout: 10) { recheck.exists && recheck.isEnabled }, file: file, line: line)
    writeFixtureState("--ui-test-device-authorized", in: app, file: file, line: line)
    recheck.click()
    // Fifteen seconds: a click that met a live tick in flight finds Re-check
    // disabled, and the next tick reads the flip instead.
    XCTAssertTrue(
      element("device.trust.ready", in: app).waitForExistenceFast(timeout: 15),
      "the trusted device must read Connected", file: file, line: line)
    XCTAssertTrue(
      waitUntil(timeout: 10) { recheck.exists && recheck.isEnabled }, file: file, line: line)
    writeFixtureState("", in: app, file: file, line: line)
    recheck.click()
    assertDisplayed(
      element("device.fact.state", in: app), equals: "Unauthorized", timeout: 15,
      file: file, line: line)
    XCTAssertFalse(
      element("device.wait.timedOut", in: app).exists,
      "the Connected read ended the timed-out verdict; it must not come back",
      file: file, line: line)
    XCTAssertFalse(
      app.buttons["device.wait.openOverviewRecovery"].exists, file: file, line: line)
    XCTAssertTrue(beginWait.isEnabled, file: file, line: line)
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
    // The pane renders only once the Runtime storage owner has answered, and
    // under this launch that owner must be the fixture. A developer machine's
    // daemon answers the same request and would hide a fixture that was never
    // installed - which is how the nightly runner, with no daemon, showed an
    // empty pane after a green local run. The fixture publishes a policy no
    // product default matches, and the editable fields carry it in GiB and
    // days. The root path would be the natural witness, but a selectable fact
    // row's text is not readable by UI automation on macOS.
    assertDisplayed(app.textFields["settings.storage.quota"], equals: "12")
    assertDisplayed(app.textFields["settings.storage.margin"], equals: "3")
    assertDisplayed(app.textFields["settings.storage.retention"], equals: "45")
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
  func localizedSweep(
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
  func walkExactFlashPlanRunAction(
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

  func writeFixtureState(
    _ token: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try token.write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
    }
  }

}
