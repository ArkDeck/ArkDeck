import XCTest

/// HDC diagnostics, lifecycle safety and device observation.
///
/// Every fault injection used to cost its own launch, so a run relaunched the
/// app once per test. The fixture now re-reads its state on each refresh, so
/// one launched instance walks every fault below. The fault values are raw
/// domain strings, so the behavior matrix runs once; the AppShell localization
/// sweep covers the second-language control. What still launches separately
/// does so for a reason that is stated where it happens.
@MainActor
final class HDCStatusUITests: XCTestCase {
  override class func setUp() {
    super.setUp()
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    KeyboardInputSourcePin.restoreWhenTheRunFinishes()
  }

  // MARK: - One full diagnostic fixture sweep

  /// TEST-AC-HDC-001-02 toolchainDiagnosticsContract, TEST-AC-HDC-007-02
  /// authorizationFaultInjection, TEST-AC-HDC-008-01 securityStateContract,
  /// TEST-AC-HDC-003-01 / 010-01 / 010-02 lifecycle contracts, and
  /// OBS-APPFACE-001 AP1/AP2 — all against one launched instance. These
  /// assertions are raw domain values and therefore run once; AppShell's
  /// localized sweep covers the Chinese refresh label and keyboard route.

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
    XCTAssertTrue(confirmation.waitForExistenceFast(timeout: 5))
    XCTAssertEqual(confirmation.label, "Confirm Generation 7")
    confirmation.click()
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.confirmed"],
      equals: "Recovery impact confirmed for generation 7. Dispatch remains separately gated.")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  /// Every assertion here reads a raw domain string, which is identical in
  /// every language, so one sweep owns the complete behavior matrix.
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
      app.staticTexts["hdc.lifecycle.impactPreview"].waitForNonExistenceFast(timeout: 5),
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
      app.staticTexts["overview.attention.clear"].waitForExistenceFast(timeout: 5),
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
    guard writeFixtureState(["--ui-test-hdc-refresh-delay"]) else { return }
    defer { try? FileManager.default.removeItem(at: fixtureStateFileURL) }
    let app = launch(arguments: ["--ui-test-fixture-state", fixtureStateFileURL.path])
    let refresh = app.buttons["hdc.devices.refresh"]
    let chooser = app.buttons["hdc.toolchain.chooseExecutable"]
    XCTAssertTrue(refresh.waitForExistenceFast(timeout: 15))
    XCTAssertTrue(chooser.exists)

    refresh.click()

    XCTAssertTrue(app.staticTexts["overview.status.refreshing"].waitForExistenceFast(timeout: 5))
    assertDisplayedValue(app.staticTexts["hdc.endpoint"], equals: "127.0.0.1:18710", timeout: 2)
    XCTAssertFalse(refresh.isEnabled)
    XCTAssertFalse(chooser.isEnabled)
    app.typeKey("r", modifierFlags: .command)
    guard writeFixtureState([]) else { return }
    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"], equals: appearedAndDisappearedFixtureEvents,
      timeout: 15)
    XCTAssertTrue(
      app.staticTexts["overview.status.refreshing"].waitForNonExistenceFast(timeout: 5))
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
        "--ui-test-reset-hdc-selection", "--ui-test-hdc-local-production-presentation",
        "--arkdeck-hdc-user-configured-path", "/usr/bin/true",
      ],
      fixture: false)
    expandAdvancedDiagnostics(app)
    assertDisplayedValue(
      element("hdc.toolchain.path", in: app), equals: "/usr/bin/true", timeout: 15)
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
        "--ui-test-reset-hdc-selection", "--ui-test-hdc-local-production-presentation",
        "--arkdeck-hdc-user-configured-path", fakeExecutable.path,
      ], fixture: false)
    expandAdvancedDiagnostics(app)

    assertDisplayedValue(
      element("hdc.toolchain.path", in: app), equals: fakeExecutable.path, timeout: 15)
    assertDisplayedValue(
      element("hdc.toolchain.clientVersion", in: app),
      equals: "unknown (registered client probe requires an existing server identity)",
      timeout: 15)
  }

  /// PORT-FILE-ACCESS-001. The relaunch *is* the assertion — the bookmark has
  /// to survive it — so this one deliberately launches twice.
  func testUserPickerPersistsBookmarkAcrossRelaunch() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-hdc-picker-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath().standardizedFileURL
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let pickerExecutable = fixtureRoot.appending(path: "hdc-picker-fixture")
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: pickerExecutable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: pickerExecutable.path)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: pickerExecutable.path))

    let selected = launch(
      arguments: [
        "--ui-test-reset-hdc-selection", "--ui-test-hdc-local-production-presentation",
      ], fixture: false)
    expandAdvancedDiagnostics(selected)
    let chooseExecutable = element("hdc.toolchain.chooseExecutable", in: selected)
    XCTAssertTrue(chooseExecutable.waitForExistenceFast(timeout: 5))
    assertEnabled(chooseExecutable, equals: true, timeout: 15)
    chooseExecutable.click()

    let openPanel = selected.sheets.firstMatch
    guard openPanel.waitForExistenceFast(timeout: 5) else {
      XCTFail("Open panel must become interactive")
      return
    }
    selected.typeKey("g", modifierFlags: [.command, .shift])
    let pathField = openPanel.textFields.firstMatch
    guard pathField.waitForExistenceFast(timeout: 5) else {
      XCTFail("Open panel must expose Go to Folder")
      return
    }
    // macOS can restore a per-window input source when the remote Open Panel
    // text field takes focus. Re-select the already-enabled plain layout here
    // so a third-party candidate window cannot consume the path or Return key.
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    // Go to Folder gives PathTextField keyboard focus. Asking XCUITest to
    // click this remote-service element on macOS 26.6 can instead try to
    // scroll the browser behind it and fail before sending any input.
    pathField.typeKey("a", modifierFlags: .command)
    pathField.typeText(pickerExecutable.path)
    pathField.typeKey(.return, modifierFlags: [])
    let selectedFile = openPanel.textFields.matching(
      NSPredicate(format: "value == %@", pickerExecutable.lastPathComponent)
    ).firstMatch
    guard selectedFile.waitForExistenceFast(timeout: 10) else {
      XCTFail("Open panel must select the requested executable")
      return
    }
    selectedFile.click()
    let openButton = openPanel.buttons["OKButton"]
    guard openButton.waitForExistenceFast(timeout: 5) else {
      XCTFail("Open panel must expose its final Open button")
      return
    }
    assertEnabled(openButton, equals: true, timeout: 10)
    openButton.click()
    XCTAssertTrue(
      openPanel.waitForNonExistenceFast(timeout: 10),
      "the open panel must close before its selection is asserted")

    let selectionError = element("hdc.toolchain.configurationError", in: selected)
    if selectionError.waitForExistenceFast(timeout: 3) {
      XCTFail("HDC picker returned an error: \(displayedText(for: selectionError))")
      selected.terminate()
      return
    }
    assertDisplayedValue(
      element("hdc.toolchain.path", in: selected), equals: pickerExecutable.path, timeout: 15)
    selected.terminate()

    let reopened = launch(
      arguments: ["--ui-test-hdc-local-production-presentation"], fixture: false)
    expandAdvancedDiagnostics(reopened)
    assertDisplayedValue(
      element("hdc.toolchain.path", in: reopened), equals: pickerExecutable.path, timeout: 15)
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
    guard writeFixtureState(faults, file: file, line: line) else { return }
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistenceFast(timeout: 10), file: file, line: line)
    assertEnabled(refresh, equals: true, file: file, line: line)
    refresh.click()
  }

  @discardableResult
  private func writeFixtureState(
    _ faults: [String],
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    do {
      try faults.joined(separator: "\n").write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      return true
    } catch {
      XCTFail("cannot write the fixture state: \(error)", file: file, line: line)
      return false
    }
  }

  private func enterImpactReview(_ app: XCUIApplication) {
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    guard request.waitForExistenceFast(timeout: 5) else { return }
    request.click()
    _ = app.staticTexts["hdc.lifecycle.impactPreview"].waitForExistenceFast(timeout: 5)
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
    if !app.windows.firstMatch.waitForExistenceFast(timeout: 2) {
      app.typeKey("n", modifierFlags: .command)
    }
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistenceFast(timeout: 5), "ArkDeck must create a test window")
    // The absolute path now lives in the collapsed Advanced Diagnostics
    // section, so readiness is anchored on a field the Overview always shows.
    XCTAssertTrue(
      element("hdc.endpoint", in: app).waitForExistenceFast(timeout: 15),
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
      toggle.waitForExistenceFast(timeout: 15),
      "Overview must expose the Advanced Diagnostics disclosure", file: file, line: line)
    guard !element("hdc.toolchain.path", in: app).exists else { return }
    // NavigationSplitView accessibility geometry is unreliable on macOS 26;
    // the product's public shortcut reaches the same action without spending
    // up to 25 AppKit scroll/idle cycles or risking a click on the Job bar.
    app.typeKey("d", modifierFlags: [.command, .shift])
    XCTAssertTrue(
      element("hdc.toolchain.path", in: app).waitForExistenceFast(timeout: 5),
      "expanding Advanced Diagnostics must reveal the raw toolchain facts",
      file: file, line: line)
  }

  private func displayedText(for element: XCUIElement) -> String {
    [element.label, element.value as? String]
      .compactMap { $0 }
      .joined(separator: " ")
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
    if displayedValues(for: element).contains(expectedText) { return }
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
    if element.isEnabled == expected { return }
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

  private func repositoryRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func repositoryFakeHDCExecutable() -> URL {
    repositoryRoot()
      .appending(path: "Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture")
      .resolvingSymlinksInPath().standardizedFileURL
  }

}
