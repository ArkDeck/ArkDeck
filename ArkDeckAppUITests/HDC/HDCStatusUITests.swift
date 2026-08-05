import AppKit
import XCTest

@MainActor
final class HDCStatusUITests: XCTestCase {
  // TEST-AC-HDC-001-02 / toolchainDiagnosticsContract
  func testDiagnosticsShowEveryToolchainFieldAndExplicitUnverifiedState() {
    let app = launch(arguments: [])
    expandAdvancedDiagnostics(app)

    XCTAssertTrue(app.staticTexts["hdc.toolchain.path"].waitForExistence(timeout: 5))
    assertDisplayedValue(app.staticTexts["hdc.toolchain.path"], equals: "/Applications/DevEco/hdc")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.source"], equals: "devecoSDK")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.hash"], equals: "fixture-sha256")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.trust"], equals: "unverified (UI fixture)")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.clientVersion"], equals: "3.2.0d")
    assertDisplayedValue(app.staticTexts["hdc.toolchain.serverVersion"], equals: "3.2.0d")
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.daemonVersion"], equals: "unknown (not exposed by checkserver)"
    )
    assertDisplayedValue(app.staticTexts["hdc.endpoint"], equals: "127.0.0.1:18710")
    assertDisplayedValue(app.staticTexts["hdc.health"], equals: "healthy")
    assertDisplayedValue(app.staticTexts["hdc.generation"], equals: "7")
    assertDisplayedValue(app.staticTexts["hdc.ownership"], equals: "external")
    assertDisplayedValue(app.staticTexts["hdc.authorization"], equals: "ready")
    assertDisplayedValue(
      app.staticTexts["hdc.channelProtection"], equals: "unverified; assumed unprotected")
    assertDisplayedValue(
      app.staticTexts["hdc.tcp.warning"],
      equals: "Channel protection is unverified. Use TCP only on a trusted, isolated network.")
    XCTAssertTrue(app.buttons["hdc.lifecycle.requestImpactPreview"].exists)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.previewRequirement"],
      equals:
        "Server recovery is host-wide: it requires an impact preview, an exact-generation user confirmation, and a dispatch-time recheck."
    )
  }

  // OPENHARMONY-HDC-READONLY-PROBES@1.0.0 unsupported key-family disposition.
  func testUnsupportedKeyAccessRemainsADiagnosticWithoutLifecycleControl() {
    let app = launch(arguments: ["--ui-test-hdc-key-access-denied"])

    XCTAssertTrue(app.staticTexts["hdc.authorization"].waitForExistence(timeout: 5))
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"],
      equals:
        "unavailable — key access diagnostics unsupported without a user-approved locator")
    assertDisplayedValue(
      app.staticTexts["hdc.keyAccessError"],
      equals: "Key access diagnostics are unsupported; no key path was read or modified."
    )
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  // TEST-AC-HDC-007-02 / authorizationFaultInjection
  func testDeniedAuthorizationOffersOnlyTheExplicitNonDestructiveRetryPath() {
    let app = launch(arguments: ["--ui-test-hdc-denied"])
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"],
      equals: "denied — The device declined trust; retry is non-destructive")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  // TEST-AC-HDC-007-02 / authorizationFaultInjection
  func testTimedOutAuthorizationOffersOnlyTheExplicitNonDestructiveRetryPath() {
    let app = launch(arguments: ["--ui-test-hdc-timed-out"])
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"], equals: "timed out — retry is non-destructive")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  // TEST-AC-HDC-008-01 / securityStateContract plus the registered
  // unsupported subserver-family disposition (not AC-HDC-009 capability evidence).
  func testAuthorizedTCPStillShowsUnverifiedProtectionWarningAndReadOnlySubserver() {
    let app = launch(arguments: [])

    assertDisplayedValue(app.staticTexts["hdc.authorization"], equals: "ready")
    assertDisplayedValue(
      app.staticTexts["hdc.channelProtection"], equals: "unverified; assumed unprotected")
    assertDisplayedValue(
      app.staticTexts["hdc.tcp.warning"],
      equals: "Channel protection is unverified. Use TCP only on a trusted, isolated network.")
    assertDisplayedValue(
      app.staticTexts["hdc.subserver"],
      equals: "unsupported")
    XCTAssertFalse(app.buttons["hdc.subserver.spawn"].exists)
    XCTAssertFalse(app.buttons["hdc.subserver.killall"].exists)
  }

  // TEST-AC-HDC-003-01 / lifecycleCallCounter,
  // TEST-AC-HDC-010-01 / lifecycleCriticalGateContract,
  // TEST-AC-HDC-010-02 / lifecycleAuditContract
  func testImpactPreviewShowsHostWideScopeConfirmationRequirementAndCriticalGate() {
    let app = launch(arguments: ["--ui-test-hdc-impact-preview", "--ui-test-hdc-critical-gate"])

    // The critical gate stays on the page itself, before any review sheet opens.
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.criticalGate"],
      equals:
        "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary.")

    // A preview is requested explicitly; the impact review is a sheet, not an
    // inline block that could be mistaken for a confirmed state.
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.waitForExistence(timeout: 5))
    request.click()

    XCTAssertTrue(app.staticTexts["hdc.lifecycle.impactPreview"].waitForExistence(timeout: 5))
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

    // The confirmation names the exact generation it confirms, and cancelling
    // it is the default. Confirming closes the review without dispatching.
    XCTAssertTrue(app.buttons["hdc.lifecycle.cancelImpactPreview"].exists)
    let confirmation = app.buttons["hdc.lifecycle.confirmImpactPreview"]
    XCTAssertTrue(confirmation.exists)
    XCTAssertEqual(confirmation.label, "Confirm Generation 7")
    confirmation.click()

    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.confirmed"],
      equals: "Recovery impact confirmed for generation 7. Dispatch remains separately gated.")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
    XCTAssertFalse(
      app.staticTexts["hdc.lifecycle.impactPreview"].exists,
      "confirming must close the review sheet")
  }

  // DONE-05: cancelling the review is a zero-dispatch, zero-confirmation exit,
  // and Esc reaches the same cancel path.
  func testCancellingTheImpactReviewLeavesNoConfirmationAndNoDispatch() {
    let app = launch(arguments: ["--ui-test-hdc-impact-preview"])

    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.waitForExistence(timeout: 5))
    request.click()
    XCTAssertTrue(app.staticTexts["hdc.lifecycle.impactPreview"].waitForExistence(timeout: 5))

    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

    XCTAssertTrue(
      app.staticTexts["hdc.lifecycle.impactPreview"].waitForNonExistence(timeout: 5),
      "Esc must close the review sheet")
    XCTAssertFalse(app.staticTexts["hdc.lifecycle.confirmed"].exists)
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
    XCTAssertTrue(app.buttons["hdc.lifecycle.requestImpactPreview"].exists)
  }

  // TEST-AC-HDC-003-01 / productionSessionCompositionUI
  // TASK-PI-001 / TEST-PI-HDC-INVENTORY-002:registry-fed 空-完备 inventory 满足
  // participant 门,unavailable 理由收敛为 server-identity/endpoint 前置。
  func testNormalLaunchUsesDurableSessionDiagnosticsWithRegistryFedInventory() {
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection",
        "--arkdeck-hdc-user-configured-path",
        "/usr/bin/true",
      ],
      fixture: false)
    expandAdvancedDiagnostics(app)

    let configuredPath = app.staticTexts["hdc.toolchain.path"]
    assertDisplayedValue(configuredPath, equals: "/usr/bin/true", timeout: 15)
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryUnavailable"],
      equals: "No recovery impact preview has been requested",
      timeout: 15)
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.exists)
    request.click()
    // participant 门已由 App-root registry 的空-完备 inventory 满足;剩余阻断
    // 只能来自 server-identity/endpoint 前置(/usr/bin/true 非 pinned 3.2.0d)。
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryBlocked"],
      equals: "impactCannotBeReliablyDetermined",
      timeout: 5)
    XCTAssertFalse(
      app.staticTexts["hdc.lifecycle.recoveryUnavailable"].exists,
      "the inventory-unavailable wording must be gone from the production launch path")
    XCTAssertFalse(
      app.staticTexts["hdc.lifecycle.impactPreview"].exists,
      "a request that cannot produce an impact must not open a review sheet")
  }

  // M1-006 safety gate: a non-pinned fake cannot be executed merely because
  // it was explicitly selected. The commandless registry precondition wins.
  func testProductionSandboxRejectsRepositoryFakeBeforeAnyHDCProbe() {
    let fakeExecutable = repositoryFakeHDCExecutable()
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection", "--arkdeck-hdc-user-configured-path",
        fakeExecutable.path,
      ], fixture: false)
    expandAdvancedDiagnostics(app)

    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.clientVersion"],
      equals: "unknown (registered client probe requires an existing server identity)",
      timeout: 15)
  }

  // PORT-FILE-ACCESS-001 / signed Sandbox picker and bookmark reopen.
  func testUserPickerPersistsBookmarkAcrossRelaunch() throws {
    let pickerExecutable = pickerFakeHDCExecutable()
    let fakeExecutable = pickerExecutable.resolvingSymlinksInPath().standardizedFileURL
    let repositoryFake = repositoryFakeHDCExecutable()
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: fakeExecutable.path),
      "swift test must build the repository fake before the signed UI gate")
    XCTAssertEqual(
      try Data(contentsOf: pickerExecutable), try Data(contentsOf: repositoryFake),
      "the visible picker fixture must be byte-identical to the repository fake")

    let app = launch(arguments: ["--ui-test-reset-hdc-selection"], fixture: false)
    let choose = app.buttons["hdc.toolchain.chooseExecutable"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    choose.tap()

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
    app.typeKey(.return, modifierFlags: [])

    expandAdvancedDiagnostics(app)
    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
    app.terminate()

    let reopened = launch(arguments: [], fixture: false)
    expandAdvancedDiagnostics(reopened)
    assertDisplayedValue(
      reopened.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
  }

  // OBS-APPFACE-001 / AP1: the complete observation summary is stable,
  // accessible static text and renders the exact fixture presentation.
  func testOBSAPP1_ObservationSummaryFieldsAreAccessibleStaticText() {
    let app = launch(arguments: [])
    expandAdvancedDiagnostics(app)
    let expectedEvents =
      "2026-07-28T00:00:00.000Z appeared redacted-device-0123456789abcdef01234567"

    assertDisplayedValue(app.staticTexts["hdc.counters.autoLifecycle"], equals: "0")
    assertDisplayedValue(app.staticTexts["hdc.counters.autoSubserver"], equals: "0")
    assertDisplayedValue(app.staticTexts["hdc.endpoint.source"], equals: "unknown")
    assertDisplayedValue(app.staticTexts["hdc.ownership.basis"], equals: "unavailable")
    assertDisplayedValue(app.staticTexts["hdc.devices.events"], equals: expectedEvents)
  }

  // OBS-APPFACE-001 / AP2: public device events preserve source order and
  // expose only timestamps, closed kinds, and redacted identifiers.
  func testOBSAPP2_DeviceEventsPreserveOrderShapeAndRedaction() {
    let app = launch(arguments: [])
    app.buttons["hdc.devices.refresh"].tap()
    let events =
      displayedValues(for: app.staticTexts["hdc.devices.events"])
      .first(where: { $0.contains(" appeared ") })
      ?? displayedText(for: app.staticTexts["hdc.devices.events"])
    let appeared = "2026-07-28T00:00:00.000Z appeared"
    let disappeared = "2026-07-28T00:00:01.000Z disappeared"
    let identifier = "redacted-device-0123456789abcdef01234567"

    guard let appearedRange = events.range(of: appeared),
      let disappearedRange = events.range(of: disappeared)
    else {
      XCTFail("Device events must contain both exact UTC fractional RFC 3339 transitions")
      return
    }
    XCTAssertLessThan(appearedRange.lowerBound, disappearedRange.lowerBound)
    XCTAssertEqual(occurrenceCount(of: identifier, in: events), 2)
    XCTAssertNotNil(
      events.range(
        of:
          #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z appeared redacted-device-[0-9a-f]{24} \| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z disappeared redacted-device-[0-9a-f]{24}$"#,
        options: .regularExpression))
    XCTAssertFalse(events.contains("connectKey"))
    XCTAssertFalse(events.contains("Optional("))
    XCTAssertFalse(events.contains("internal reason"))
  }

  // OBS-APPFACE-001 / AP3: production launch renders its own fail-closed
  // presentation and cannot inherit the deterministic UI fixture events.
  func testOBSAPP3_ProductionLaunchContainsNoFixtureObservationValues() {
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection",
        "--arkdeck-hdc-user-configured-path",
        "/usr/bin/true",
      ],
      fixture: false)
    let eventsElement = app.staticTexts["hdc.devices.events"]
    XCTAssertTrue(eventsElement.waitForExistence(timeout: 15))
    let events = displayedText(for: eventsElement)

    XCTAssertFalse(events.contains("2026-07-28T00:00:00.000Z"))
    XCTAssertFalse(events.contains("2026-07-28T00:00:01.000Z"))
    XCTAssertFalse(events.contains("redacted-device-0123456789abcdef01234567"))
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  // OBS-APPFACE-001 / AP4: the App consumes presentation-only values and
  // cannot import or construct the underlying observation/process boundary.
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

  // HOR-UI-001: the English control is visible through the real App wiring
  // and one user action advances the deterministic presentation.
  func testHORUI1_EnglishRefreshIsAccessibleAndAdvancesPresentation() {
    let app = launch(arguments: ["-AppleLanguages", "(en)"])
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 5))
    XCTAssertEqual(refresh.label, "Refresh Devices")
    XCTAssertTrue(refresh.isEnabled)
    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"],
      equals: appearedFixtureEvent)

    refresh.tap()

    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"],
      equals: appearedAndDisappearedFixtureEvents)
  }

  // HOR-UI-001: Simplified Chinese is complete and the keyboard shortcut
  // reaches the same App callback.
  func testHORUI2_SimplifiedChineseKeyboardRefreshAdvancesPresentation() {
    let app = launch(arguments: ["-AppleLanguages", "(zh-Hans)"])
    let refresh = app.buttons["hdc.devices.refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 5))
    XCTAssertEqual(refresh.label, "刷新设备")
    XCTAssertTrue(refresh.isEnabled)

    app.typeKey("r", modifierFlags: .command)

    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"],
      equals: appearedAndDisappearedFixtureEvents)
  }

  // HOR-BOUNDED-001: admission is synchronous, both executable reselection
  // and refresh are disabled in flight, and a duplicate shortcut never
  // reaches the fixture's deliberately visible third transition.
  func testHORBOUNDED1_InFlightDuplicateIsRejectedWithoutThirdTransition() {
    let app = launch(arguments: ["--ui-test-hdc-refresh-delay"])
    let refresh = app.buttons["hdc.devices.refresh"]
    let chooser = app.buttons["hdc.toolchain.chooseExecutable"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 5))
    XCTAssertTrue(chooser.exists)

    refresh.tap()

    XCTAssertFalse(refresh.isEnabled)
    XCTAssertFalse(chooser.isEnabled)
    app.typeKey("r", modifierFlags: .command)
    assertDisplayedValue(
      app.staticTexts["hdc.devices.events"],
      equals: appearedAndDisappearedFixtureEvents,
      timeout: 15)
    assertEnabled(refresh, equals: true)
    assertEnabled(chooser, equals: true)
    Thread.sleep(forTimeInterval: 1)
    let events = displayedText(for: app.staticTexts["hdc.devices.events"])
    XCTAssertFalse(events.contains("observationUnknown"))
    XCTAssertFalse(events.contains("2026-07-28T00:00:02.000Z"))
  }

  private func launch(arguments: [String], fixture: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning {
      app.terminate()
    }
    app.launchArguments =
      [
        "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      ] + (fixture ? ["--ui-test-hdc-diagnostics"] : []) + arguments
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    if !fixture,
      let configuredPathIndex = arguments.firstIndex(
        of: "--arkdeck-hdc-user-configured-path"),
      arguments.indices.contains(configuredPathIndex + 1)
    {
      app.launchEnvironment["ARKDECK_HDC_USER_CONFIGURED_PATH"] = arguments[configuredPathIndex + 1]
    }
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 2) {
      // A fresh macOS launch can restore an intentionally empty window set
      // even with state restoration disabled. Exercise the standard
      // WindowGroup command instead of treating that OS state as an HDC
      // composition failure.
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
    _ app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let toggle = app.buttons["overview.advanced.toggle"]
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 15),
      "Overview must expose the Advanced Diagnostics disclosure", file: file, line: line)
    guard !app.staticTexts["hdc.toolchain.path"].exists else { return }
    toggle.click()
    XCTAssertTrue(
      app.staticTexts["hdc.toolchain.path"].waitForExistence(timeout: 5),
      "expanding Advanced Diagnostics must reveal the raw toolchain facts",
      file: file, line: line)
  }

  private func displayedText(for element: XCUIElement) -> String {
    [element.label, element.value as? String]
      .compactMap { $0 }
      .joined(separator: " ")
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

  private func displayedValues(for element: XCUIElement) -> [String] {
    [element.label, element.value as? String].compactMap { $0 }
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

  private func pickerFakeHDCExecutable() -> URL {
    if let explicit = ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_EXECUTABLE"] {
      return URL(fileURLWithPath: explicit).standardizedFileURL
    }
    let root = repositoryRoot()
    let visibleHardLink = root.appending(path: "ArkDeckFakeHDCFixture-M1-006")
    if FileManager.default.fileExists(atPath: visibleHardLink.path) {
      return visibleHardLink
    }
    return
      root
      .appending(path: "Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture")
      .standardizedFileURL
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
