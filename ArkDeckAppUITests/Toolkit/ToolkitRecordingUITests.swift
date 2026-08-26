import XCTest

/// The recording pane, driven end to end over a real device archive
/// (TASK-IDC-002, recorded gap 2 of 5, App leg).
///
/// The provider is replaced by `ToolkitRecordingFixture`, which replays frames
/// a device actually produced. What that covers is everything on this side:
/// the four states, composing the movie, validating it by reading the written
/// file back, and the result bar. What it deliberately does not cover is the
/// device leg - submit, receive and cleanup are pinned by
/// `ScreenSequenceCaptureContractTests` and by the hardware runs recorded with
/// it.
///
/// Opt-in, because it needs an archive on disk and an adopted device for the
/// workspace to have a target at all.
final class ToolkitRecordingUITests: XCTestCase {
  private static let archiveKey = "ARKDECK_UI_TEST_FRAME_ARCHIVE"

  /// Which state the pane is showing, for a failure message that says what
  /// went wrong rather than only that something did. Queried without
  /// `firstMatch` on a missing identifier, which throws rather than reporting.
  static func visibleStage(of app: XCUIApplication) -> String {
    for identifier in [
      "toolkit.record.failed", "toolkit.record.refused", "toolkit.record.headroomUnknown",
      "toolkit.record.stage", "toolkit.record.ready",
    ] where app.descendants(matching: .any).matching(identifier: identifier).count > 0 {
      return identifier
    }
    return "no recognisable state"
  }

  private func launch(archive: String, headroomBytes: Int? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle",
      "--ui-test-toolkit-recording=\(archive)",
    ]
    if let headroomBytes {
      app.launchArguments.append("--ui-test-toolkit-recording-headroom=\(headroomBytes)")
    }
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    let row = app.descendants(matching: .any)["app.navigation.toolkit"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    return app
  }

  /// A run there is no room to keep is refused before it starts, and the
  /// refusal names both numbers and offers a run that would fit
  /// (TASK-IDC-002, gap 3; IDC-AC-8 "开始前配额 preflight 失败即阻断").
  func testARunWithNoRoomIsBlockedBeforeItStarts() throws {
    guard let archive = ProcessInfo.processInfo.environment[Self.archiveKey],
      FileManager.default.fileExists(atPath: archive)
    else {
      throw XCTSkip("Set \(Self.archiveKey) to a frames.tar from a real capture")
    }
    // Two mebibytes holds a handful of frames and nothing like a full run.
    let app = launch(archive: archive, headroomBytes: 2 << 20)

    let start = app.buttons["toolkit.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    guard XCTWaiter().wait(for: [enabled], timeout: 30) == .completed else {
      throw XCTSkip("no single adopted device is observed, so the pane has no target")
    }
    start.click()

    let refused = app.descendants(matching: .any)["toolkit.record.refused"]
    XCTAssertTrue(
      refused.waitForExistence(timeout: 20),
      "the run must be blocked; the pane is in " + Self.visibleStage(of: app))
    // Nothing was composed, so nothing is offered.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "toolkit.record.ready").count, 0,
      "a refused run has no result to show")

    // Both numbers, and a run that would fit rather than only a refusal.
    let summary = refused.label.isEmpty ? "\(refused.value ?? "")" : refused.label
    XCTAssertTrue(summary.contains("MB") || summary.contains("KB"), summary)
    XCTAssertTrue(
      app.descendants(matching: .any)["toolkit.record.shrink"].exists,
      "a refusal that offers nothing cannot be acted on")
  }

  /// Both notices must survive everything a person can do to the workspace
  /// (TASK-IDC-002, recorded gap 4 of 5; IDC-AC-8 names them together).
  ///
  /// Non-removable is the whole requirement, and it is not the same as
  /// present-on-launch. A notice that goes away once somebody has been
  /// working for a while is absent exactly when it matters: they have been
  /// capturing, the device's load has moved, and what they are reading has
  /// moved with it - measured on hardware, a 30-frame run took the
  /// one-minute load average from 2.00 to 2.24.
  func testNeitherNoticeCanBeGotRidOf() throws {
    guard let archive = ProcessInfo.processInfo.environment[Self.archiveKey],
      FileManager.default.fileExists(atPath: archive)
    else {
      throw XCTSkip("Set \(Self.archiveKey) to a frames.tar from a real capture")
    }
    let app = launch(archive: archive)

    let performance = app.descendants(matching: .any)["toolkit.performance"]
    let boundary = app.descendants(matching: .any)["toolkit.boundary"]
    XCTAssertTrue(performance.waitForExistence(timeout: 10))
    XCTAssertTrue(boundary.exists)

    // Nothing offers to close either of them. A dismiss control that exists
    // is a dismiss control somebody will use.
    for notice in ["toolkit.performance", "toolkit.boundary"] {
      let element = app.descendants(matching: .any)[notice]
      XCTAssertFalse(
        element.buttons.element(boundBy: 0).exists,
        "\(notice) must carry nothing that gets rid of it")
    }

    // And they survive the workspace being used: a run composed, validated
    // and offered is the longest thing a person does here.
    let start = app.buttons["toolkit.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    if XCTWaiter().wait(for: [enabled], timeout: 30) == .completed {
      start.click()
      _ = app.descendants(matching: .any)["toolkit.record.ready"].waitForExistence(timeout: 180)
    }
    XCTAssertTrue(performance.exists, "the notice went away while the workspace was used")
    XCTAssertTrue(boundary.exists, "the boundary went away while the workspace was used")

    // Including after leaving Toolkit and coming back, which is where a
    // dismissed-state bug would otherwise hide.
    app.descendants(matching: .any)["app.navigation.overview"].firstMatch.click()
    app.descendants(matching: .any)["app.navigation.toolkit"].firstMatch.click()
    XCTAssertTrue(
      performance.waitForExistence(timeout: 10),
      "the notice must come back with the workspace")
    XCTAssertTrue(boundary.exists)
  }

  func testARecordingIsComposedValidatedAndOffered() throws {
    guard let archive = ProcessInfo.processInfo.environment[Self.archiveKey],
      FileManager.default.fileExists(atPath: archive)
    else {
      throw XCTSkip("Set \(Self.archiveKey) to a frames.tar from a real capture")
    }

    let app = launch(archive: archive)

    let start = app.buttons["toolkit.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    // The pane refuses without exactly one adopted device, and a click on a
    // disabled button is silently nothing - which would read as a composition
    // that never finished rather than as a gate that fired.
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    guard XCTWaiter().wait(for: [enabled], timeout: 30) == .completed else {
      throw XCTSkip("no single adopted device is observed, so the pane has no target")
    }
    start.click()

    // The pane must actually be recording. A quota answer it cannot read
    // stops it before it starts, which is how a fixture that reported no
    // headroom silently made every run impossible - it looked like a
    // composition that never finished.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "toolkit.record.headroomUnknown")
        .count, 0,
      "the run never started: the pane could not read the store's headroom")

    let ready = app.descendants(matching: .any)["toolkit.record.ready"]
    XCTAssertTrue(
      ready.waitForExistence(timeout: 180),
      "composing and validating must finish; the pane is in "
        + Self.visibleStage(of: app))

    // The rate is measured, not promised, and it lands where the device
    // measurements said it would: about 1.8 frames a second. A combined
    // element carries its text as the label.
    let summary = ready.label.isEmpty ? "\(ready.value ?? "")" : ready.label
    XCTAssertTrue(summary.contains("fps"), summary)
    // The number immediately before "fps" - not merely the first number in the
    // line, which is the frame count and would pass for the wrong reason.
    let beforeFps = summary.components(separatedBy: "fps")[0]
      .split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
    let rate = beforeFps.last.flatMap { Double($0) }
    XCTAssertNotNil(rate, summary)
    XCTAssertEqual(
      try XCTUnwrap(rate), 1.84, accuracy: 0.1,
      "the rate is measured off the movie's own span, and the device's readback "
        + "puts it near 1.8: \(summary)")

    // Where it went, and the three things a person can do with it.
    let location = app.descendants(matching: .any)["toolkit.record.location"]
    XCTAssertTrue(location.exists, "a recording nobody can find is not delivered")
    XCTAssertTrue("\(location.value ?? "")".hasSuffix(".mov"), "\(location.value ?? "")")
    // Link-styled controls are not `buttons` in the accessibility tree, so the
    // query is by identifier rather than by element type.
    for control in ["toolkit.record.reveal", "toolkit.record.saveAs", "toolkit.record.again"] {
      XCTAssertTrue(
        app.descendants(matching: .any)[control].exists,
        "the result bar must offer \(control)")
    }

    // Recording again returns the pane to where a second run starts from.
    app.descendants(matching: .any)["toolkit.record.again"].firstMatch.click()
    XCTAssertTrue(
      ready.waitForNonExistence(timeout: 10),
      "the previous result must not stand while a new run is offered")
    XCTAssertTrue(start.isEnabled, "a second run must be offered")
  }
}

extension XCUIElement {
  fileprivate func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !exists { return true }
      Thread.sleep(forTimeInterval: 0.3)
    }
    return !exists
  }
}
