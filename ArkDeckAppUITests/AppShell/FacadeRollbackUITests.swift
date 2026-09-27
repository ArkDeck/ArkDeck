import XCTest

/// Opt-in installed-service acceptance. AC-9 is read-only for the facade and
/// same-release Swift rollback; the separate Rust case restores its local
/// filter preference write. Neither uses fixtures or device mutations.
/// Overview may run its normal approved read-only capability probe.
@MainActor
final class FacadeRollbackUITests: XCTestCase {
  override class func setUp() {
    super.setUp()
    KeyboardInputSourcePin.pinPlainKeyboardLayout()
    KeyboardInputSourcePin.restoreWhenTheRunFinishes()
  }

  func testOverviewAndExactHistoryJobThroughInstalledService() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let backend = environment["ARKDECK_FACADE_ROLLBACK_BACKEND"],
      ["facade", "swift-rollback"].contains(backend),
      let jobID = environment["ARKDECK_FACADE_ROLLBACK_JOB_ID"],
      jobID.hasPrefix("job-"), jobID.count > 4
    else {
      throw XCTSkip("Supply the installed backend and an existing Runtime Job ID for AC-9")
    }

    let app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle", "--ui-test-reset-shell-selection",
    ]
    app.launch()
    defer { app.terminate() }
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

    let overview = element("app.navigation.overview", in: app)
    XCTAssertTrue(overview.waitForExistence(timeout: 10))
    overview.click()
    XCTAssertTrue(element("overview.status.server.value", in: app).waitForExistence(timeout: 30))

    let history = element("app.navigation.history", in: app)
    XCTAssertTrue(history.waitForExistence(timeout: 10))
    history.click()
    XCTAssertTrue(element("history.table", in: app).waitForExistence(timeout: 30))
    let search = app.textFields["history.filter.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeKey("a", modifierFlags: .command)
    search.typeText(jobID)
    let detail = element("history.detail.job", in: app)
    XCTAssertTrue(detail.waitForExistence(timeout: 30))
    let exactJob = NSPredicate(format: "label == %@ OR value == %@", jobID, jobID)
    expectation(for: exactJob, evaluatedWith: detail)
    waitForExpectations(timeout: 30)

    let evidence = XCTAttachment(
      string: "Installed \(backend): production Overview and exact persisted History Job rendered through the installed service.")
    evidence.name = "AC-9 installed service App smoke"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Separate from AC-9: this runs a pinned signed App URL, never the test
  /// target's ad-hoc App. The helper proves the installed pure-Rust owner and
  /// keeps a private, CAS-restorable snapshot before any UI preference write.
  func testInstalledPureRustHistoryFilterRoundTrip() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ARKDECK_INSTALLED_RUST_UI"] == "1" else {
      throw XCTSkip("Explicit installed pure-Rust UI acceptance opt-in required")
    }
    let evidence = try XCTUnwrap(environment["ARKDECK_INSTALLED_RUST_EVIDENCE"])
    let prepared = try installedHelper("prepare", evidence: evidence)
    let appURL = URL(fileURLWithPath: try XCTUnwrap(prepared["app"] as? String))
    let marker = try XCTUnwrap(prepared["search"] as? String)
    let app = XCUIApplication(url: appURL)
    // No --ui-test-* flags: all factories use their production providers.
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
      "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    defer {
      app.terminate()
      do {
        let restored = try installedHelper("restore", evidence: evidence)
        XCTAssertEqual(restored["restored"] as? Bool, true)
        let attachment = XCTAttachment(string: "Original saved-filter query/state restored with CAS. Private evidence: \(evidence)")
        attachment.name = "Installed Rust filter restoration"
        attachment.lifetime = .keepAlways
        add(attachment)
      } catch {
        XCTFail("Filter restoration failed; private snapshot retained at \(evidence): \(error)")
      }
    }
    app.launch()
    try openInstalledHistory(in: app)
    try resetInstalledFilters(in: app)
    let search = app.textFields["history.filter.search"]
    try requireInstalledElement(search)
    search.click()
    search.typeKey("a", modifierFlags: .command)
    search.typeText(marker)
    _ = try installedHelper("verify-original", evidence: evidence)
    try installedFilterAction("history.filter.save", in: app)
    // Applying is offered only after the saved resource has been read back.
    try installedFilterAction("history.filter.applySaved", in: app)
    _ = try installedHelper("verify-save", evidence: evidence)

    app.terminate()
    app.launch()
    try openInstalledHistory(in: app)
    let relaunchedSearch = app.textFields["history.filter.search"]
    try requireInstalledElement(relaunchedSearch)
    relaunchedSearch.click()
    relaunchedSearch.typeKey("a", modifierFlags: .command)
    relaunchedSearch.typeText("unsaved-ui-search")
    try installedFilterAction("history.filter.applySaved", in: app)
    let applied = NSPredicate(format: "value == %@", marker)
    guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: applied, object: relaunchedSearch)], timeout: 10) == .completed else {
      throw NSError(domain: "InstalledRustUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Production UI did not apply the persisted filter after relaunch"])
    }
    _ = try installedHelper("verify-save", evidence: evidence)
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "Signed App installed Rust History filter applied"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func requireInstalledElement(_ element: XCUIElement) throws {
    let ready = NSPredicate(format: "exists == true AND enabled == true")
    guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 30) == .completed else {
      throw NSError(domain: "InstalledRustUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Required production UI control is unavailable"])
    }
  }

  private func openInstalledHistory(in app: XCUIApplication) throws {
    app.activate()
    let history = element("app.navigation.history", in: app)
    try requireInstalledElement(history)
    history.click()
  }

  private func installedFilterAction(_ identifier: String, in app: XCUIApplication) throws {
    let menu = element("history.filter.saved", in: app)
    try requireInstalledElement(menu)
    menu.click()
    let action = element(identifier, in: app)
    try requireInstalledElement(action)
    action.click()
  }

  private func resetInstalledFilters(in app: XCUIApplication) throws {
    let activity = element("history.filter.activity", in: app)
    if activity.exists {
      try requireInstalledElement(activity)
      activity.click()
      let all = app.menuItems["All records"].firstMatch
      try requireInstalledElement(all)
      all.click()
    } else {
      let all = element("history.activity.all", in: app)
      try requireInstalledElement(all)
      all.click()
    }
    let compact = app.buttons["history.filter.show"]
    if compact.exists { compact.click() }
    for (identifier, title) in [
      ("history.filter.status", "All states"), ("history.filter.mode", "All modes"),
      ("history.filter.session", "All Sessions"), ("history.filter.device", "All devices"),
      ("history.filter.time", "Any time"),
    ] {
      let picker = element(identifier, in: app)
      try requireInstalledElement(picker)
      picker.click()
      let choice = app.menuItems[title].firstMatch
      try requireInstalledElement(choice)
      choice.click()
    }
    if compact.exists { app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: []) }
  }

  private func installedHelper(_ stage: String, evidence: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", root.appendingPathComponent("scripts/ci/installed_rust_ui.py").path, stage, evidence]
    let pipe = Pipe()
    process.standardOutput = pipe
    // The helper emits a bounded redacted result; do not attach subprocess diagnostics.
    process.standardError = FileHandle.nullDevice
    try process.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "InstalledRustUI", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result["reason"] as? String ?? "Installed service check failed"])
    }
    return result
  }
}
