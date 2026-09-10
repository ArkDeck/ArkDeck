import XCTest

/// Opt-in read-only smoke against the installed signed service, run once for
/// the facade and once for its same-release Swift rollback. No fixture mode.
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
      string: "Installed \(backend): production Overview and exact persisted History Job rendered without submitting an operation.")
    evidence.name = "AC-9 installed service App smoke"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
