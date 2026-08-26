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

  func testARecordingIsComposedValidatedAndOffered() throws {
    guard let archive = ProcessInfo.processInfo.environment[Self.archiveKey],
      FileManager.default.fileExists(atPath: archive)
    else {
      throw XCTSkip("Set \(Self.archiveKey) to a frames.tar from a real capture")
    }

    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle",
      "--ui-test-toolkit-recording=\(archive)",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

    let row = app.descendants(matching: .any)["app.navigation.toolkit"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()

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

    let ready = app.descendants(matching: .any)["toolkit.record.ready"]
    XCTAssertTrue(
      ready.waitForExistence(timeout: 180),
      "composing and validating must finish, or say why: "
        + (app.descendants(matching: .any)["toolkit.record.failed"].value as? String ?? "-"))

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
