import XCTest

/// The Overview's record, against the real view hierarchy.
///
/// The projections are unit-tested in ArkDeckKit; what only a launched app can
/// answer is whether the page renders the next action without duplicating the
/// sidebar, keeps target/server scope explicit, and pins a run needing a
/// person where someone will see it.
@MainActor
final class OverviewRecordUITests: XCTestCase {
  func testOverviewFocusesTheNextStepAndDoesNotDuplicateSidebarShortcuts() {
    let app = launch()
    XCTAssertTrue(
      element(app, "overview.record.device.name").waitForExistenceFast(timeout: 30),
      "the Overview record must render on the default landing page")

    XCTAssertTrue(element(app, "overview.record.next").exists)
    XCTAssertTrue(element(app, "overview.record.remoteServer").exists)
    XCTAssertFalse(
      element(app, "overview.record.device.picker").exists,
      "an adopted target that is absent from the live device observation must not appear")

    // Viewer, Trace, Debug, Flash and Toolkit are already one click away in
    // the sidebar, so Overview must not render a second launch grid.
    for kind in ["uiDump", "trace", "debugHAP", "flash", "toolkit"] {
      XCTAssertFalse(element(app, "overview.record.start.\(kind)").exists)
    }
  }

  func testARunNeedingAPersonIsPinnedAndOffersNoReplay() {
    let app = launch()
    XCTAssertTrue(element(app, "overview.record.device.name").waitForExistenceFast(timeout: 30))

    // job-fixture-0002 is an interrupted flash with an unknown outcome. It must
    // reach the page, be marked as needing a person, and offer no way to repeat
    // it — an unknown intent is never replayed.
    let outcome = element(app, "overview.record.run.job-fixture-0002.outcome")
    XCTAssertTrue(outcome.waitForExistenceFast(timeout: 15))
    XCTAssertTrue(
      element(app, "overview.record.run.job-fixture-0002.refusal").exists,
      "an unknown outcome must state its refusal in place of a repeat control")
    XCTAssertFalse(
      element(app, "overview.record.run.job-fixture-0002.again").exists,
      "an unknown outcome must not offer a repeat at all")

    // The read-only fixture run is the one that may be repeated, and it carries
    // a thread, so it renders inside a grouped line.
    XCTAssertTrue(
      element(app, "overview.record.run.job-fixture-0001").waitForExistenceFast(timeout: 15))
    XCTAssertTrue(element(app, "overview.record.thread.thread:t-fixture0001").exists)
  }

  /// The record has to reach History, which owns the full archive; the Overview
  /// deliberately shows only the most recent lines.
  func testTheRecordLinksToTheFullArchive() {
    let app = launch()
    let all = element(app, "overview.record.recent.all")
    XCTAssertTrue(all.waitForExistenceFast(timeout: 30))
    all.click()
    XCTAssertTrue(
      element(app, "history.readOnlyNote").waitForExistenceFast(timeout: 15)
        || element(app, "runtime.history").waitForExistenceFast(timeout: 5),
      "the archive link must land on History")
  }

  // MARK: - Support

  /// Identifiers are asserted across element types: SwiftUI decides whether a
  /// labelled container publishes as a button, a group or a static text, and
  /// this suite is about the identifier being reachable at all.
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-hdc-diagnostics", "--ui-test-devices", "--ui-test-auto-update-idle",
      "--ui-test-runtime-history",
      "--ui-test-overview-offline-target",
      "--ui-test-reset-shell-selection",
    ]
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    app.activate()
    // macOS can restore the process with no windows even when persistence is
    // ignored. Use the product's New Window command, as the shell and Viewer
    // suites do, so a missing window is not reported as a missing Overview.
    if !app.windows.firstMatch.waitForExistenceFast(timeout: 5) {
      app.typeKey("n", modifierFlags: .command)
      XCTAssertTrue(
        app.windows.firstMatch.waitForExistenceFast(timeout: 10),
        "ArkDeck must create a test window")
    }
    return app
  }
}
