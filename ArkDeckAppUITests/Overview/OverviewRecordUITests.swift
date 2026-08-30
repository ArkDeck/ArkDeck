import AppKit
import XCTest

/// The Overview's record, against the real view hierarchy.
///
/// The projections are unit-tested in ArkDeckKit; what only a launched app can
/// answer is whether the page renders the next action without duplicating the
/// sidebar, keeps target/server scope explicit, and pins a run needing a
/// person where someone will see it.
///
/// Every record assertion used to cost its own launch. They all read the same
/// read-only fixture, so one launched instance walks them as named phases,
/// the way the HDC sweep and the AppShell History session already do; phases
/// that navigate away return through the sidebar, the same route a person
/// takes. The one launch that stays separate declares a different fixture.
@MainActor
final class OverviewRecordUITests: XCTestCase {
  /// One presentation-only App instance for every default-fixture assertion
  /// group. Ordering is part of the design: the phases that end on History
  /// run last, and the sheet phase closes its sheet before handing over.
  func testOverviewRecordContinuousSession() throws {
    let app = launch()
    let processes = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.arkdeck.desktop")
    XCTAssertEqual(processes.count, 1, "the session must have exactly one App process")
    let processID = try XCTUnwrap(processes.first?.processIdentifier)

    runRecordPhase("Next step focus without sidebar duplicates", in: app, processID: processID) {
      XCTAssertTrue(
        element(app, "overview.record.device.name").waitForExistenceFast(timeout: 30),
        "the Overview record must render on the default landing page")

      XCTAssertTrue(element(app, "overview.record.next").exists)
      XCTAssertTrue(element(app, "overview.record.remoteServer").exists)
      XCTAssertFalse(
        element(app, "overview.record.device.picker").exists,
        "an adopted target that is absent from the live device observation must not appear")

      // Viewer, Trace, Debug, Flash and Device are already one click away in
      // the sidebar, so Overview must not render a second launch grid.
      for kind in ["uiDump", "trace", "debugHAP", "flash", "device"] {
        XCTAssertFalse(element(app, "overview.record.start.\(kind)").exists)
      }
    }

    runRecordPhase("A run needing a person is pinned", in: app, processID: processID) {
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

    runRecordPhase("Continue separates navigation from preparation", in: app, processID: processID) {
      let again = element(app, "overview.record.run.job-fixture-0001.again")
      XCTAssertTrue(again.waitForExistenceFast(timeout: 15))
      clickRecentRunAction(again, in: app)
      let explanation = element(app, "overview.resume.explanation")
      XCTAssertTrue(explanation.waitForExistenceFast(timeout: 10))
      XCTAssertTrue(
        [explanation.label, explanation.value as? String].compactMap { $0 }
          .contains { $0.contains("Preparing never submits") })
      XCTAssertFalse(element(app, "overview.resume.prepare").isEnabled)
      XCTAssertTrue(element(app, "overview.resume.prepare.reason").exists)
      XCTAssertEqual(element(app, "overview.resume.open").label, "Open Workspace")
      element(app, "overview.resume.cancel").click()
      XCTAssertTrue(
        explanation.waitForNonExistenceFast(timeout: 5),
        "cancelling must close the sheet before the next phase")
    }

    runRecordPhase("Viewing a run selects that exact History record", in: app, processID: processID) {
      let open = element(app, "overview.record.run.job-fixture-0001.open")
      XCTAssertTrue(open.waitForExistenceFast(timeout: 15))
      clickRecentRunAction(open, in: app)
      let job = element(app, "history.detail.job")
      XCTAssertTrue(job.waitForExistenceFast(timeout: 15))
      XCTAssertTrue([job.label, job.value as? String].contains("job-fixture-0001"))
      returnToOverview(in: app)
    }

    // The record has to reach History, which owns the full archive; the
    // Overview deliberately shows only the most recent lines.
    runRecordPhase("The record links to the full archive", in: app, processID: processID) {
      let all = element(app, "overview.record.recent.all")
      XCTAssertTrue(all.waitForExistenceFast(timeout: 15))
      all.click()
      XCTAssertTrue(
        element(app, "history.readOnlyNote").waitForExistenceFast(timeout: 15)
          || element(app, "runtime.history").waitForExistenceFast(timeout: 5),
        "the archive link must land on History")
    }
  }

  /// This one cannot join the session: it declares the diagnostics fixture at
  /// launch, and its submit spends the continuation, so the phase would not be
  /// repeatable inside a shared instance.
  func testReadOnlyContinuationShowsTypedInputsAndThreadBeforeAnySubmission() {
    let app = launch(arguments: ["--ui-test-diagnostics-session"], offlineTarget: false)
    let again = element(app, "overview.record.run.job-fixture-diagnostics.again")
    XCTAssertTrue(again.waitForExistenceFast(timeout: 30))
    clickRecentRunAction(again, in: app)
    let prepare = element(app, "overview.resume.prepare")
    XCTAssertTrue(prepare.waitForExistenceFast(timeout: 10))
    let enabled = NSPredicate(format: "enabled == true")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: prepare)], timeout: 10), .completed)
    prepare.click()
    let inputs = element(app, "overview.continuation.inputs")
    XCTAssertTrue(inputs.waitForExistenceFast(timeout: 10))
    XCTAssertTrue(displayedText(inputs).contains("durationSeconds"))
    XCTAssertTrue(displayedText(inputs).contains("false"), "typed booleans must not become display strings")
    XCTAssertEqual(displayedText(element(app, "overview.continuation.thread")), "t-diagnostics-fixture")
    XCTAssertFalse(element(app, "overview.continuation.openJob").exists, "preparing must not create a Job")
    let submit = element(app, "overview.continuation.submit")
    XCTAssertTrue(submit.isEnabled)
    submit.click()
    let result = element(app, "overview.continuation.result")
    XCTAssertTrue(result.waitForExistenceFast(timeout: 10))
    XCTAssertEqual(displayedText(result), "fixture_continuation_not_dispatched")
    XCTAssertFalse(submit.isEnabled, "an unconfirmed request must not be repeated implicitly")
    XCTAssertFalse(element(app, "overview.continuation.openJob").exists)
  }

  // MARK: - Support

  /// The AppShell History session's continuity contract, applied here: a
  /// phase must run in the very App process the session launched, so a crash
  /// or accidental relaunch cannot silently pass as a fresh instance.
  private func runRecordPhase(
    _ name: String, in app: XCUIApplication, processID: pid_t, body: () -> Void
  ) {
    XCTContext.runActivity(named: name) { _ in
      let before = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").map(\.processIdentifier)
      guard app.state != .notRunning, before == [processID] else {
        XCTFail("App process changed before \(name): expected \(processID), got \(before)")
        return
      }
      app.activate()
      body()
      let after = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.arkdeck.desktop").map(\.processIdentifier)
      XCTAssertEqual(after, [processID], "a phase must not relaunch the App")
    }
  }

  /// Phases that navigated to History come back the way a person does — over
  /// the sidebar — and prove the record rendered before handing over.
  private func returnToOverview(in app: XCUIApplication) {
    element(app, "app.navigation.overview").click()
    XCTAssertTrue(
      element(app, "overview.record.device.name").waitForExistenceFast(timeout: 10),
      "the sidebar must lead back to the Overview record")
  }

  /// Identifiers are asserted across element types: SwiftUI decides whether a
  /// labelled container publishes as a button, a group or a static text, and
  /// this suite is about the identifier being reachable at all.
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func displayedText(_ element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty { return value }
    return element.label
  }

  /// Recent runs may be below the visible fold when the recovery banner is
  /// present. Scroll their actual content view before clicking; translating a
  /// NavigationSplitView AX offset alone can still click below the window.
  private func clickRecentRunAction(_ action: XCUIElement, in app: XCUIApplication) {
    let content = app.scrollViews.containing(.any, identifier: action.identifier).firstMatch
    guard content.waitForExistenceFast(timeout: 5) else {
      XCTFail("the recent run must belong to the Overview scroll view")
      return
    }
    for _ in 0..<6 {
      if content.frame.insetBy(dx: 4, dy: 12).contains(action.frame) {
        action.click()
        return
      }
      content.scroll(byDeltaX: 0, deltaY: action.frame.midY > content.frame.midY ? -260 : 260)
    }
    XCTFail("the recent run action did not enter the visible Overview")
  }

  private func launch(arguments: [String] = [], offlineTarget: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-hdc-diagnostics", "--ui-test-devices", "--ui-test-auto-update-idle",
      "--ui-test-runtime-history",
      "--ui-test-reset-shell-selection",
      "-AppleLanguages", "(en)",
    ] + arguments
    if offlineTarget { app.launchArguments.append("--ui-test-overview-offline-target") }
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
