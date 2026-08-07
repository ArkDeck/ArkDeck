import AppKit
import XCTest

/// HDC diagnostics, lifecycle safety and device observation.
///
/// Every fault injection used to cost its own launch, so a run relaunched the
/// app once per test. The fixture now re-reads its state on each refresh, so
/// one launched instance walks every fault below; language is a property of a
/// run rather than of a test, so there is one sweep per language and no other
/// fixture launch. What still launches separately does so for a reason that is
/// stated where it happens.
@MainActor
final class HDCStatusUITests: XCTestCase {
  override class func setUp() {
    super.setUp()
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    KeyboardInputSourcePin.restoreWhenTheRunFinishes()
  }

  // MARK: - One fixture launch per language

  /// TEST-AC-HDC-001-02 toolchainDiagnosticsContract, TEST-AC-HDC-007-02
  /// authorizationFaultInjection, TEST-AC-HDC-008-01 securityStateContract,
  /// TEST-AC-HDC-003-01 / 010-01 / 010-02 lifecycle contracts, and
  /// OBS-APPFACE-001 AP1/AP2 — all against one launched instance.
  func testSimplifiedChineseFixtureSweep() {
    let app = launchSweep(language: "(zh-Hans)")
    walkEveryDiagnosticState(app)
    // HOR-UI-001: Simplified Chinese is complete and the keyboard path reaches
    // the same App callback as the button.
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertEqual(refresh.label, "刷新设备")
    XCTAssertTrue(refresh.isEnabled)
    app.typeKey("r", modifierFlags: .command)
    // A sweep has already driven several refreshes, so the fixture is past the
    // two-event state the standalone test pinned. What the keyboard path has
    // to show is that it reached the same callback: the disappeared
    // transition is present, in order, behind the appeared one.
    let events = displayedText(for: app.staticTexts["hdc.devices.events"])
    guard let appeared = events.range(of: appearedFixtureEvent),
      let disappeared = events.range(of: "2026-07-28T00:00:01.000Z disappeared")
    else {
      XCTFail("the keyboard refresh must advance the presentation: \(events)")
      return
    }
    XCTAssertLessThan(appeared.lowerBound, disappeared.lowerBound)
  }

  func testEnglishFixtureSweep() {
    let app = launchSweep(language: "(en)")
    walkEveryDiagnosticState(app)
    // HOR-UI-001: the English control is visible through the real App wiring.
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertEqual(refresh.label, "Refresh Devices")
    XCTAssertTrue(refresh.isEnabled)
    // The confirmation names the exact generation it confirms.
    enterImpactReview(app)
    let confirmation = app.buttons["hdc.lifecycle.confirmImpactPreview"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    XCTAssertEqual(confirmation.label, "Confirm Generation 7")
    confirmation.click()
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.confirmed"],
      equals: "Recovery impact confirmed for generation 7. Dispatch remains separately gated.")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  /// Every assertion here reads a raw domain string, which is identical in
  /// every language, so both sweeps run the same walk.
  private func walkEveryDiagnosticState(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    // --- default state: complete toolchain diagnostics -------------------
    expandAdvancedDiagnostics(app)
    assertDisplayedValue(app.staticTexts["hdc.toolchain.path"], equals: "/Applications/DevEco/hdc")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.source"], equals: "devecoSDK")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.hash"], equals: "fixture-sha256")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.trust"], equals: "unverified (UI fixture)")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.clientVersion"], equals: "3.2.0d")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.serverVersion"], equals: "3.2.0d")
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.daemonVersion"],
      equals: "unknown (not exposed by checkserver)")
    assertDisplayedValue(app.staticTexts["hdc.endpoint"], equals: "127.0.0.1:18710")
    assertDisplayedValue(app.staticTexts["hdc.health"], equals: "healthy")
    assertDisplayedValue(app.staticTexts["hdc.generation"], equals: "7")
    assertDisplayedValue(app.staticTexts["hdc.ownership"], equals: "external")
    assertDisplayedValue(app.staticTexts["hdc.authorization"], equals: "ready")
    // OBS-APPFACE-001 / AP1: the observation summary is stable static text.
    assertDisplayedValue(app.staticTexts["hdc.counters.autoLifecycle"], equals: "0")
    assertDisplayedValue(app.staticTexts["hdc.counters.autoSubserver"], equals: "0")
    assertDisplayedValue(app.staticTexts["hdc.endpoint.source"], equals: "unknown")
    assertDisplayedValue(app.staticTexts["hdc.ownership.basis"], equals: "unavailable")

    // TEST-AC-HDC-008-01: authorized TCP still warns, subserver stays read-only.
    assertDisplayedValue(
      app.staticTexts["hdc.channelProtection"], equals: "unverified; assumed unprotected")
    assertDisplayedValue(
      app.staticTexts["hdc.tcp.warning"],
      equals: "Channel protection is unverified. Use TCP only on a trusted, isolated network.")
    assertDisplayedValue(app.staticTexts["hdc.subserver"], equals: "unsupported")
    XCTAssertFalse(app.buttons["hdc.subserver.spawn"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["hdc.subserver.killall"].exists, file: file, line: line)
    XCTAssertTrue(app.buttons["hdc.lifecycle.requestImpactPreview"].exists, file: file, line: line)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.previewRequirement"],
      equals:
        "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck."
    )

    // OBS-APPFACE-001 / AP2: events keep source order, shape and redaction.
    let events =
      displayedValues(for: app.staticTexts["hdc.devices.events"])
      .first(where: { $0.contains(" appeared ") })
      ?? displayedText(for: app.staticTexts["hdc.devices.events"])
    XCTAssertEqual(occurrenceCount(of: "redacted-device-0123456789abcdef01234567", in: events), 1)
    XCTAssertFalse(events.contains("connectKey"), file: file, line: line)
    XCTAssertFalse(events.contains("Optional("), file: file, line: line)
    XCTAssertFalse(events.contains("internal reason"), file: file, line: line)

    // --- denied -----------------------------------------------------------
    applyFixtureState(["--ui-test-hdc-denied"], in: app)
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"],
      equals: "denied — The device declined trust; retry is non-destructive")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists, file: file, line: line)

    // --- timed out --------------------------------------------------------
    applyFixtureState(["--ui-test-hdc-timed-out"], in: app)
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"], equals: "timed out — retry is non-destructive")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists, file: file, line: line)

    // --- unsupported key access ------------------------------------------
    applyFixtureState(["--ui-test-hdc-key-access-denied"], in: app)
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"],
      equals: "unavailable — key access diagnostics unsupported without a user-approved locator")
    assertDisplayedValue(
      app.staticTexts["hdc.keyAccessError"],
      equals: "Key access diagnostics are unsupported; no key path was read or modified.")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists, file: file, line: line)

    // --- critical gate + host-wide impact review --------------------------
    applyFixtureState(["--ui-test-hdc-critical-gate"], in: app)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.criticalGate"],
      equals:
        "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary.")
    enterImpactReview(app)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.impactPreview"], equals: "Server recovery impact preview")
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.action"], equals: "restartConfirmedGeneration")
    assertDisplayedValue(app.staticTexts["hdc.lifecycle.endpoint"], equals: "127.0.0.1:18710")
    assertDisplayedValue(app.staticTexts["hdc.lifecycle.generation"], equals: "7")
    assertDisplayedValue(app.staticTexts["hdc.lifecycle.ownership"], equals: "external")
    assertDisplayedValue(app.staticTexts["hdc.lifecycle.devices"], equals: "device-a, device-b")
    assertDisplayedValue(app.staticTexts["hdc.lifecycle.jobs"], equals: "job-hdc")
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.otherClients"], equals: "detected: DevEco IDE")
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.interruption"],
      equals: "HDC requests using this endpoint will be interrupted.")
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryPath"],
      equals: "Re-probe the shared endpoint and reconcile every affected Job.")
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.confirmationRequired"],
      equals:
        "This preview requires an exact-generation user confirmation before recovery can dispatch.")

    // Cancelling is a zero-dispatch, zero-confirmation exit, and Esc reaches it.
    XCTAssertTrue(app.buttons["hdc.lifecycle.cancelImpactPreview"].exists, file: file, line: line)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(
      app.staticTexts["hdc.lifecycle.impactPreview"].waitForNonExistence(timeout: 5),
      "Esc must close the review sheet", file: file, line: line)
    XCTAssertFalse(app.staticTexts["hdc.lifecycle.confirmed"].exists, file: file, line: line)
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists, file: file, line: line)

    // --- verified channel: the one state with nothing to act on -----------
    // Every other fixture state carries at least the unprotected-TCP warning,
    // so the Overview's "nothing needs attention" branch was unreachable and
    // had never been drawn. Its wording is locale-dependent and belongs to the
    // shell sweeps; what is asserted here is that the state exists at all and
    // that the warning it replaces is gone.
    applyFixtureState(["--ui-test-hdc-channel-verified"], in: app)
    assertDisplayedValue(
      app.staticTexts["hdc.channelProtection"],
      equals: "encrypted verified (fixture-v1, UI fixture)")
    XCTAssertTrue(
      app.staticTexts["overview.attention.clear"].waitForExistence(timeout: 5),
      "a verified channel leaves nothing needing attention", file: file, line: line)
    XCTAssertFalse(app.staticTexts["hdc.tcp.warning"].exists, file: file, line: line)

    // Back to the clean state so the next assertions start from a known place.
    applyFixtureState([], in: app)
    assertDisplayedValue(app.staticTexts["hdc.authorization"], equals: "ready")
    assertDisplayedValue(
      app.staticTexts["hdc.channelProtection"], equals: "unverified; assumed unprotected")
    XCTAssertFalse(app.staticTexts["overview.attention.clear"].exists, file: file, line: line)
  }

  // MARK: - Launches that stay separate, and why

  /// HOR-BOUNDED-001. This one cannot join a sweep: the fixture's delay fires
  /// on the *second* refresh of an instance, which a sweep has long passed.
  func testHORBOUNDED1_InFlightDuplicateIsRejectedWithoutThirdTransition() {
    let app = launch(arguments: ["--ui-test-hdc-refresh-delay"])
    let refresh = app.buttons["hdc.devices.refresh"]
    let chooser = app.buttons["hdc.toolchain.chooseExecutable"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 15))
    XCTAssertTrue(chooser.exists)

    refresh.click()

    XCTAssertFalse(refresh.isEnabled)
    XCTAssertFalse(chooser.isEnabled)
    app.typeKey("r", modifierFlags: .command)
    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"], equals: appearedAndDisappearedFixtureEvents,
      timeout: 15)
    assertEnabled(refresh, equals: true)
    assertEnabled(chooser, equals: true)
    let events = displayedText(for: app.staticTexts["hdc.devices.events"])
    XCTAssertFalse(events.contains("observationUnknown"))
    XCTAssertFalse(events.contains("2026-07-28T00:00:02.000Z"))
  }

  /// TEST-AC-HDC-003-01 productionSessionCompositionUI, TASK-PI-001, and
  /// OBS-APPFACE-001 / AP3. These need the *production* composition, which no
  /// fixture instance can become, so they launch on their own.
  func testProductionLaunchUsesDurableSessionDiagnosticsAndNoFixtureValues() {
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection", "--arkdeck-hdc-user-configured-path", "/usr/bin/true",
      ],
      fixture: false)
    expandAdvancedDiagnostics(app)
    assertDisplayedValue(app.staticTexts["hdc.toolchain.path"], equals: "/usr/bin/true", timeout: 15)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryUnavailable"],
      equals: "No recovery impact preview has been requested", timeout: 15)

    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.exists)
    request.click()
    // participant 门已由 App-root registry 的空-完备 inventory 满足;剩余阻断
    // 只能来自 server-identity/endpoint 前置(/usr/bin/true 非 pinned 3.2.0d)。
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryBlocked"], equals: "impactCannotBeReliablyDetermined",
      timeout: 5)
    XCTAssertFalse(
      app.staticTexts["hdc.lifecycle.recoveryUnavailable"].exists,
      "the inventory-unavailable wording must be gone from the production launch path")
    XCTAssertFalse(
      app.staticTexts["hdc.lifecycle.impactPreview"].exists,
      "a request that cannot produce an impact must not open a review sheet")

    // AP3: the production path renders its own fail-closed presentation and
    // cannot inherit the deterministic fixture events.
    let events = displayedText(for: app.staticTexts["hdc.devices.events"])
    XCTAssertFalse(events.contains("2026-07-28T00:00:00.000Z"))
    XCTAssertFalse(events.contains("2026-07-28T00:00:01.000Z"))
    XCTAssertFalse(events.contains("redacted-device-0123456789abcdef01234567"))
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  /// M1-006 safety gate. A different production selection, so a different
  /// launch: a non-pinned fake must not become executable merely by being
  /// chosen.
  func testProductionSandboxRejectsRepositoryFakeBeforeAnyHDCProbe() {
    let fakeExecutable = repositoryFakeHDCExecutable()
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection", "--arkdeck-hdc-user-configured-path", fakeExecutable.path,
      ], fixture: false)
    expandAdvancedDiagnostics(app)

    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.clientVersion"],
      equals: "unknown (registered client probe requires an existing server identity)",
      timeout: 15)
  }

  /// PORT-FILE-ACCESS-001. The relaunch *is* the assertion — the bookmark has
  /// to survive it — so this one deliberately launches twice.
  func testUserPickerPersistsBookmarkAcrossRelaunch() throws {
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: repositoryFakeHDCExecutable().path),
      "swift test must build the repository fake before the signed UI gate")
    let pickerExecutable = try stagedPickerExecutable()
    let fakeExecutable = pickerExecutable.resolvingSymlinksInPath().standardizedFileURL
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: fakeExecutable.path),
      "staging the picker fixture must keep it executable")

    let app = launch(arguments: ["--ui-test-reset-hdc-selection"], fixture: false)
    let choose = app.buttons["hdc.toolchain.chooseExecutable"]
    XCTAssertTrue(choose.waitForExistence(timeout: 15))
    choose.click()

    let openPanel = app.sheets.firstMatch
    XCTAssertTrue(openPanel.waitForExistence(timeout: 5), "Open panel must become interactive")
    app.typeKey("g", modifierFlags: [.command, .shift])
    let pathField = openPanel.textFields.firstMatch
    XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Open panel must expose Go to Folder")
    pathField.click()
    pathField.typeKey("a", modifierFlags: [.command])
    try withTemporaryGeneralPasteboardString(pickerExecutable.path) {
      pathField.typeKey("v", modifierFlags: [.command])
    }
    pathField.typeKey(.return, modifierFlags: [])
    // Go to Folder resolves asynchronously, so a Return sent straight after it
    // lands before the panel has a selection and is simply dropped. Press the
    // panel's own Open button, once it reports that it has something to open —
    // which also says, in one assertion, whether the panel accepted the path.
    // Two waits by necessity, not by habit: resolving a control inside the
    // remote open-panel service costs seconds per query, but the enabled
    // predicate cannot double as the existence check — isEnabled on an
    // unresolved element is a query failure, not false.
    let openButton = openPanel.buttons["OKButton"]
    XCTAssertTrue(openButton.waitForExistence(timeout: 5), "Open panel must expose its Open button")
    assertEnabled(openButton, equals: true, timeout: 10)
    openButton.click()

    // The open panel has to be gone before anything below the fold can be
    // clicked: while it is up the disclosure is present and on screen but has
    // no hit point, which reports as "unable to find hit point" rather than as
    // an occlusion.
    XCTAssertTrue(
      app.sheets.firstMatch.waitForNonExistence(timeout: 10),
      "the open panel must close before the Overview is driven again")
    expandAdvancedDiagnostics(app)
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
    app.terminate()

    let reopened = launch(arguments: [], fixture: false)
    expandAdvancedDiagnostics(reopened)
    assertDisplayedValue(
      reopened.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
  }

  // OBS-APPFACE-001 / AP4: a source audit, so it launches nothing at all.
  func testOBSAPP4_AppSourceKeepsPresentationOnlyPackageBoundary() throws {
    let sourceURL = repositoryRoot()
      .appending(path: "ArkDeckApp/Features/HDC/HDCStatusView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let productImports = source.split(separator: "\n")
      .map(String.init)
      .filter { $0.hasPrefix("import ArkDeck") }

    XCTAssertEqual(Set(productImports), ["import ArkDeckWorkflows"])
    let forbiddenCapabilities = [
      "ArkDeckOpenHarmony",
      "HDCDeviceObservationSnapshot",
      "HDCDeviceObservationSource",
      "HDCDeviceObservationApplicationSession",
      "HDCDeviceObservationPresentationBridge",
      "HMAC",
      "runner",
      "argv",
      "Process(",
      "2026-07-28T00:00:00.000Z",
      "2026-07-28T00:00:01.000Z",
      "redacted-device-0123456789abcdef01234567",
    ]
    for forbidden in forbiddenCapabilities {
      XCTAssertFalse(
        source.contains(forbidden), "App source contains forbidden capability: \(forbidden)")
    }

    // The unavailable workspace is a new production view on the same
    // boundary: it may not acquire a capability this one is denied, and it
    // owns no model or fixture at all.
    for relativePath in ["ArkDeckApp/Features/Shared/UnavailableFeatureView.swift"] {
      let shellSource = try String(
        contentsOf: repositoryRoot().appending(path: relativePath), encoding: .utf8)
      for forbidden in forbiddenCapabilities {
        XCTAssertFalse(
          shellSource.contains(forbidden),
          "\(relativePath) contains forbidden capability: \(forbidden)")
      }
    }

    let fields = [
      ("hdc.counters.autoLifecycle", "presentation.automaticLifecycleDispatchCount"),
      ("hdc.counters.autoSubserver", "presentation.automaticSubserverDispatchCount"),
      ("hdc.endpoint.source", "presentation.endpointSource"),
      ("hdc.ownership.basis", "presentation.ownershipBasis"),
      ("hdc.devices.events", "presentation.deviceEvents"),
    ]
    for (identifier, presentationField) in fields {
      XCTAssertEqual(occurrenceCount(of: identifier, in: source), 1)
      XCTAssertTrue(source.contains(presentationField))
    }
  }

  // MARK: - Sweep helpers

  private var fixtureStateFileURL: URL {
    FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-ui-fixture-state-\(ProcessInfo.processInfo.processIdentifier).txt")
  }

  private func launchSweep(language: String) -> XCUIApplication {
    try? "".write(to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    return launch(
      arguments: [
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
      ])
  }

  /// Moves the launched fixture to a new state and makes the App re-read it.
  /// The file replaces the previous state rather than adding to it, so a state
  /// can assert the absence of a fault an earlier one set.
  private func applyFixtureState(
    _ faults: [String], in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try faults.joined(separator: "\n").write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
      return
    }
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 10), file: file, line: line)
    assertEnabled(refresh, equals: true, file: file, line: line)
    refresh.click()
  }

  private func enterImpactReview(_ app: XCUIApplication) {
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    guard request.waitForExistence(timeout: 5) else { return }
    request.click()
    _ = app.staticTexts["hdc.lifecycle.impactPreview"].waitForExistence(timeout: 5)
  }

  // MARK: - Helpers

  private func launch(arguments: [String], fixture: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning {
      app.terminate()
    }
    // Deliberately no blanket language override: the sweeps pass their own.
    app.launchArguments =
      [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      ]
      // A fixture launch declares its update state too, so the App does not
      // build the real updater and check for updates to decide what to show.
      + (fixture ? ["--ui-test-hdc-diagnostics", "--ui-test-auto-update-idle"] : [])
      + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    if !fixture,
      let configuredPathIndex = arguments.firstIndex(of: "--arkdeck-hdc-user-configured-path"),
      arguments.indices.contains(configuredPathIndex + 1)
    {
      app.launchEnvironment["ARKDECK_HDC_USER_CONFIGURED_PATH"] = arguments[configuredPathIndex + 1]
    }
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      app.typeKey("n", modifierFlags: .command)
    }
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 5), "ArkDeck must create a test window")
    // The absolute path now lives in the collapsed Advanced Diagnostics
    // section, so readiness is anchored on a field the Overview always shows.
    XCTAssertTrue(
      app.staticTexts["hdc.endpoint"].waitForExistence(timeout: 15),
      "ArkDeck must render an accessible HDC diagnostics root before assertions")
    return app
  }

  /// Advanced Diagnostics is collapsed by default. Expanding it is a user
  /// action, not a fixture: the same raw values stay behind the same
  /// identifiers once the section is open.
  private func expandAdvancedDiagnostics(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let toggle = app.buttons["overview.advanced.toggle"]
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 15),
      "Overview must expose the Advanced Diagnostics disclosure", file: file, line: line)
    guard !app.staticTexts["hdc.toolchain.path"].exists else { return }
    // A control that is only partly inside the viewport may still report
    // `isHittable`, while its click lands in the global Job bar below it.
    scrollIntoView(toggle, in: app)
    if toggle.isHittable {
      toggle.click()
    } else {
      app.typeKey("d", modifierFlags: [.command, .shift])
    }
    XCTAssertTrue(
      app.staticTexts["hdc.toolchain.path"].waitForExistence(timeout: 5),
      "expanding Advanced Diagnostics must reveal the raw toolchain facts",
      file: file, line: line)
  }

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

  private func displayedText(for element: XCUIElement) -> String {
    [element.label, element.value as? String]
      .compactMap { $0 }
      .joined(separator: " ")
  }

  private func displayedValues(for element: XCUIElement) -> [String] {
    [element.label, element.value as? String].compactMap { $0 }
  }

  private func assertDisplayedValue(
    _ element: XCUIElement,
    equals expectedText: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let displayedValue = NSPredicate { [weak self] _, _ in
      self?.displayedValues(for: element).contains(expectedText) ?? false
    }
    let expectation = expectation(for: displayedValue, evaluatedWith: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    let finalValues = displayedValues(for: element)
    XCTAssertTrue(
      result == .completed || finalValues.contains(expectedText),
      "Expected exact displayed value \(expectedText), got: \(displayedText(for: element))",
      file: file, line: line)
  }

  private var appearedFixtureEvent: String {
    "2026-07-28T00:00:00.000Z appeared redacted-device-0123456789abcdef01234567"
  }

  private var appearedAndDisappearedFixtureEvents: String {
    appearedFixtureEvent
      + " | "
      + "2026-07-28T00:00:01.000Z disappeared redacted-device-0123456789abcdef01234567"
  }

  private func assertEnabled(
    _ element: XCUIElement,
    equals expected: Bool,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in element.isEnabled == expected }
    let expectation = expectation(for: predicate, evaluatedWith: element)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    XCTAssertEqual(result, .completed, file: file, line: line)
    XCTAssertEqual(element.isEnabled, expected, file: file, line: line)
  }

  private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
  }

  /// The picker is driven through the system open panel's Go to Folder, and
  /// that will not commit a selection anywhere under this checkout: the panel
  /// navigates to the file and leaves its Open button disabled, so the panel
  /// never closes and every later step of the test is measured against a
  /// window that still has a sheet over it. Until now the test avoided that by
  /// preferring a hard link an operator had created at the repository root by
  /// hand, and silently fell back to `Packages/ArkDeckKit/.build` when that
  /// link was absent — which it is in any fresh clone or worktree.
  ///
  /// It is the location and nothing else. The same bytes, reached the same
  /// way, were measured selectable from the runner's temp and from
  /// `~/Library/Caches`, and refused from the checkout — with a `.build/debug`
  /// copy in temp selectable, the checkout's copy refused whether or not the
  /// path went through that `debug` symlink, and a path of the checkout's own
  /// depth outside it selectable. So it is neither the dot-prefixed directory
  /// nor the symlink nor the depth, which is what the earlier wording implied.
  /// What makes the checkout refuse is not established here; it sits under
  /// `~/Dropbox`, and a copy outside that tree is taken.
  ///
  /// A copy, not a link. Granting the App access through the picker leaves
  /// `com.apple.quarantine` on the chosen file, and a hard link carries that
  /// onto the repository fake's own inode, where it stops every contract test
  /// that spawns the fake — Gatekeeper refuses to launch it and the failures
  /// read as process timeouts. A copy takes the quarantine on a throwaway
  /// inode that teardown deletes.
  private func stagedPickerExecutable() throws -> URL {
    if let explicit = ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_EXECUTABLE"] {
      return URL(fileURLWithPath: explicit).standardizedFileURL
    }
    let source = repositoryFakeHDCExecutable()
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-picker-fixture-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let staged = directory.appending(path: source.lastPathComponent)
    if FileManager.default.fileExists(atPath: staged.path) {
      try FileManager.default.removeItem(at: staged)
    }
    try FileManager.default.copyItem(at: source, to: staged)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return staged.standardizedFileURL
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func repositoryFakeHDCExecutable() -> URL {
    repositoryRoot()
      .appending(path: "Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture")
      .resolvingSymlinksInPath().standardizedFileURL
  }

  private func withTemporaryGeneralPasteboardString(
    _ value: String,
    perform: () -> Void
  ) throws {
    let pasteboard = NSPasteboard.general
    let savedItems = pasteboard.pasteboardItems?.map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy
    }
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer {
      pasteboard.clearContents()
      if let savedItems {
        pasteboard.writeObjects(savedItems)
      }
    }
    perform()
  }
}
