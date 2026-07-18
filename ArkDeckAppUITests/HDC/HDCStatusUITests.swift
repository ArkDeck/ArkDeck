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

  // TEST-AC-HDC-006-01 / platformFileAccessContract
  func testKeyAccessDeniedRemainsADiagnosticWithoutLifecycleControl() {
    let app = launch(arguments: ["--ui-test-hdc-key-access-denied"])

    XCTAssertTrue(app.staticTexts["hdc.authorization"].waitForExistence(timeout: 5))
    assertDisplayedValue(
      app.staticTexts["hdc.authorization"],
      equals: "key access denied — The current HDC process cannot access its managed key")
    assertDisplayedValue(
      app.staticTexts["hdc.keyAccessError"], equals: "HDC key access denied by platform permissions"
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

  // TEST-AC-HDC-008-01 / securityStateContract and
  // TEST-AC-HDC-009-01 / subserverCallCounter
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
      equals: "supported (read-only; no automatic spawn or migration)")
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
  func testNormalLaunchUsesDurableSessionDiagnosticsForAnExplicitCandidate() {
    let app = launch(
      arguments: ["--arkdeck-hdc-user-configured-path", "/usr/bin/true"],
      fixture: false)

    let configuredPath = app.staticTexts["hdc.toolchain.path"]
    assertDisplayedValue(configuredPath, equals: "/usr/bin/true")
    let request = app.buttons["hdc.lifecycle.requestImpactPreview"]
    XCTAssertTrue(request.exists)
    request.tap()
    XCTAssertTrue(
      app.staticTexts["hdc.lifecycle.recoveryBlocked"].waitForExistence(timeout: 5),
      "the normal App path must reach the Session-backed supervisor, not the read-only fixture")
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
    XCTAssertEqual(
      result, .completed,
      "Expected exact displayed value \(expectedText), got: \(displayedText(for: element))",
      file: file, line: line)
  }

  private func displayedValues(for element: XCUIElement) -> [String] {
    [element.label, element.value as? String].compactMap { $0 }
  }
}
