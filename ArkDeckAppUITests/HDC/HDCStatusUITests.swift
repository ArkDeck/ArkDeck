import AppKit
import XCTest

@MainActor
final class HDCStatusUITests: XCTestCase {
  // TEST-AC-HDC-001-02 / toolchainDiagnosticsContract
  func testDiagnosticsShowEveryToolchainFieldAndExplicitUnverifiedState() {
    let app = launch(arguments: [])

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
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.criticalGate"],
      equals:
        "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary.")
    let confirmation = app.buttons["hdc.lifecycle.confirmImpactPreview"]
    XCTAssertTrue(confirmation.exists)
    confirmation.tap()
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.confirmed"],
      equals: "Recovery impact confirmed for generation 7. Dispatch remains separately gated.")
    XCTAssertFalse(app.buttons["hdc.lifecycle.dispatch"].exists)
  }

  // TEST-AC-HDC-003-01 / productionSessionCompositionUI
  func testNormalLaunchUsesDurableSessionDiagnosticsAndFailsClosedWithoutHostInventory() {
    let app = launch(
      arguments: [
        "--ui-test-reset-hdc-selection",
        "--arkdeck-hdc-user-configured-path",
        "/usr/bin/true",
      ],
      fixture: false)

    let configuredPath = app.staticTexts["hdc.toolchain.path"]
    assertDisplayedValue(configuredPath, equals: "/usr/bin/true")
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.exists)
    request.tap()
    assertDisplayedValue(
      app.staticTexts["hdc.lifecycle.recoveryUnavailable"],
      equals:
        "Lifecycle mutation is unavailable because no complete App-root HDC Job/Device critical-state inventory is attached.",
      timeout: 5)
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

    assertDisplayedValue(
      app.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
    app.terminate()

    let reopened = launch(arguments: [], fixture: false)
    assertDisplayedValue(
      reopened.staticTexts["hdc.toolchain.path"], equals: fakeExecutable.path, timeout: 15)
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
    XCTAssertTrue(
      app.staticTexts["hdc.toolchain.path"].waitForExistence(timeout: 15),
      "ArkDeck must render an accessible HDC diagnostics root before assertions")
    return app
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
