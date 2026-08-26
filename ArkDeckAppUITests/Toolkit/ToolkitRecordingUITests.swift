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
    // measurements said it would: about 1.8 frames a second.
    let summary = "\(ready.value ?? "")"
    XCTAssertTrue(summary.contains("fps"), summary)
    let rate = summary.split(separator: " ").compactMap { Double($0) }.first { $0 > 0 && $0 < 60 }
    XCTAssertNotNil(rate, summary)
    XCTAssertEqual(try XCTUnwrap(rate), 1.84, accuracy: 0.1, summary)

    // Where it went, and the three things a person can do with it.
    let location = app.descendants(matching: .any)["toolkit.record.location"]
    XCTAssertTrue(location.exists, "a recording nobody can find is not delivered")
    XCTAssertTrue("\(location.value ?? "")".hasSuffix(".mov"), "\(location.value ?? "")")
    for control in ["toolkit.record.reveal", "toolkit.record.saveAs", "toolkit.record.again"] {
      XCTAssertTrue(app.buttons[control].exists, control)
    }

    // Recording again returns the pane to where a second run starts from.
    app.buttons["toolkit.record.again"].click()
    XCTAssertTrue(
      ready.waitForNonExistence(timeout: 10),
      "the previous result must not stand while a new run is offered")
    XCTAssertTrue(app.buttons["toolkit.record.start"].isEnabled)
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
