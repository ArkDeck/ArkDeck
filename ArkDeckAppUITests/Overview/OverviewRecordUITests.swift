import XCTest

/// The Overview's record, against the real view hierarchy.
///
/// The projections are unit-tested in ArkDeckKit; what only a launched app can
/// answer is whether the page renders them — that the entries exist in their
/// fixed order, that a capability nothing probed is refused *and says why*
/// rather than silently disabled, and that a run needing a person is pinned
/// where someone will see it.
@MainActor
final class OverviewRecordUITests: XCTestCase {
  func testTheRecordShowsWhatCanBeStartedAndWhatAlreadyRan() {
    let app = launch()
    XCTAssertTrue(
      element(app, "overview.record.device.name").waitForExistenceFast(timeout: 30),
      "the Overview record must render on the default landing page")

    // The entries keep a fixed order so their positions are learned once.
    for kind in ["uiDump", "trace", "debugHAP", "flash", "toolkit"] {
      XCTAssertTrue(
        element(app, "overview.record.start.\(kind)").exists,
        "\(kind) must be listed whether or not it can be used")
    }

    // The rule the page exists to hold: nothing probes HAP debugging or device
    // control yet, so both are refused with their own stated reason — never
    // shown as unavailable, and never disabled in silence.
    for kind in ["debugHAP", "toolkit"] {
      let entry = element(app, "overview.record.start.\(kind)")
      XCTAssertFalse(entry.isEnabled, "\(kind) has no probe, so it cannot open")
      XCTAssertTrue(
        element(app, "overview.record.start.\(kind).reason").exists,
        "\(kind) must say why it cannot open")
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
      "--ui-test-hdc-diagnostics", "--ui-test-auto-update-idle", "--ui-test-runtime-history",
    ]
    app.launchEnvironment["ApplePersistenceIgnoreState"] = "YES"
    app.launchEnvironment["NSQuitAlwaysKeepsWindows"] = "NO"
    app.launch()
    return app
  }
}

