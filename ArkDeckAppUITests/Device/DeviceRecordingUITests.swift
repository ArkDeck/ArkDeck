import XCTest

/// The recording pane, driven end to end over a real device archive
/// (TASK-IDC-002, recorded gap 2 of 5, App leg).
///
/// The provider is replaced by `DeviceRecordingFixture`, which replays frames
/// a device actually produced. What that covers is everything on this side:
/// the four states, composing the movie, validating it by reading the written
/// file back, and the result bar. What it deliberately does not cover is the
/// device leg - submit, receive and cleanup are pinned by
/// `ScreenSequenceCaptureContractTests` and by the hardware runs recorded with
/// it.
///
/// The separate real-device case uses the installed Runtime, with no archive,
/// quota or device fixture. Its evidence must not be conflated with replay.
final class DeviceRecordingUITests: XCTestCase {
  private static let archiveKey = "ARKDECK_UI_TEST_FRAME_ARCHIVE"

  /// Which state the pane is showing, for a failure message that says what
  /// went wrong rather than only that something did. Queried without
  /// `firstMatch` on a missing identifier, which throws rather than reporting.
  static func visibleStage(of app: XCUIApplication) -> String {
    for identifier in [
      "device.record.failed", "device.record.refused", "device.record.headroomUnknown",
      "device.record.stage", "device.record.ready",
    ] where app.descendants(matching: .any).matching(identifier: identifier).count > 0 {
      return identifier
    }
    return "no recognisable state"
  }

  private func launch(archive: String? = nil, headroomBytes: Int? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    if app.state != .notRunning { app.terminate() }
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
      "--ui-test-auto-update-idle",
      "--ui-test-reset-shell-selection", "-AppleLanguages", "(en)",
    ]
    if let archive { app.launchArguments.append("--ui-test-device-recording=\(archive)") }
    if let headroomBytes {
      app.launchArguments.append("--ui-test-device-recording-headroom=\(headroomBytes)")
    }
    app.launch()
    app.activate()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    let row = app.descendants(matching: .any)["app.navigation.device"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    return app
  }

  func testRealDeviceRecordingCapturesFortyFramesAndOffersALocalMovie() throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_UI_TEST_DEVICE_REAL_DEVICE"] == "1"
    else { throw XCTSkip("Opt in to a real device capture with ARKDECK_UI_TEST_DEVICE_REAL_DEVICE=1") }
    let app = launch()
    let capture = app.buttons["device.capture"]
    XCTAssertTrue(capture.waitForExistence(timeout: 10))
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: capture)
    guard XCTWaiter().wait(for: [connected], timeout: 30) == .completed else {
      return XCTFail("real-device validation requires exactly one observed adopted device")
    }

    let start = app.buttons["device.record.start"]
    XCTAssertTrue(start.isEnabled)
    start.click()
    let ready = app.descendants(matching: .any)["device.record.ready"]
    let failed = app.descendants(matching: .any)["device.record.failed"]
    let refused = app.descendants(matching: .any)["device.record.refused"]
    let terminal = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in ready.exists || failed.exists || refused.exists },
      object: nil)
    guard XCTWaiter().wait(for: [terminal], timeout: 180) == .completed, ready.exists else {
      let detail = failed.exists ? "\(failed.value ?? failed.label)" : Self.visibleStage(of: app)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Device real recording did not finish"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      return XCTFail("real capture/composition failed: " + detail)
    }
    let summary = ready.label.isEmpty ? "\(ready.value ?? "")" : ready.label
    XCTAssertTrue(summary.contains("40 frames"), summary)
    let rateText = summary.components(separatedBy: "fps")[0]
      .split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).last
    let rate = try XCTUnwrap(rateText.flatMap { Double($0) }, summary)
    XCTAssertGreaterThan(rate, 0, "the result shows a measured rate, not a target")
    XCTAssertFalse(app.descendants(matching: .any)["device.record.gap"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["device.record.headroomUnknown"].exists)

    let location = app.descendants(matching: .any)["device.record.location"]
    let path = location.value as? String ?? location.label
    XCTAssertTrue(path.hasSuffix(".mov"), path)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
    let evidence = XCTAttachment(string: "Real Runtime capture: \(summary)\nMovie: \(path)")
    evidence.name = "Real device recording result"
    evidence.lifetime = .keepAlways
    add(evidence)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Device real recording ready"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    for identifier in ["device.record.reveal", "device.record.saveAs", "device.record.again"] {
      XCTAssertTrue(app.descendants(matching: .any)[identifier].exists)
    }
    app.descendants(matching: .any)["device.record.again"].click()
    XCTAssertTrue(ready.waitForNonExistence(timeout: 10))
    XCTAssertTrue(start.isEnabled)
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

    let start = app.buttons["device.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    guard XCTWaiter().wait(for: [enabled], timeout: 30) == .completed else {
      throw XCTSkip("no single adopted device is observed, so the pane has no target")
    }
    start.click()

    let refused = app.descendants(matching: .any)["device.record.refused"]
    XCTAssertTrue(
      refused.waitForExistence(timeout: 20),
      "the run must be blocked; the pane is in " + Self.visibleStage(of: app))
    // Nothing was composed, so nothing is offered.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "device.record.ready").count, 0,
      "a refused run has no result to show")

    // Both numbers, and a run that would fit rather than only a refusal.
    let summary = refused.label.isEmpty ? "\(refused.value ?? "")" : refused.label
    XCTAssertTrue(summary.contains("MB") || summary.contains("KB"), summary)
    XCTAssertTrue(
      app.descendants(matching: .any)["device.record.shrink"].exists,
      "a refusal that offers nothing cannot be acted on")
  }

  /// A store that cannot be asked must not withhold the feature
  /// (TASK-IDC-002 follow-up).
  ///
  /// This shipped as a block, and against a real daemon predating
  /// `artifact.quota` - which answers `unknownMethod` - it made the pane
  /// unable to record at all. IDC-AC-8 blocks on a *failed* preflight, and
  /// "could not ask" is not one: the runtime's own host-storage preflight is
  /// still the operation's first step. The pane's own copy said as much while
  /// the code did the opposite.
  func testAStoreThatCannotBeAskedDoesNotWithholdTheRecording() throws {
    guard let archive = ProcessInfo.processInfo.environment[Self.archiveKey],
      FileManager.default.fileExists(atPath: archive)
    else {
      throw XCTSkip("Set \(Self.archiveKey) to a frames.tar from a real capture")
    }
    // Negative headroom stands in for a store that cannot be asked at all.
    let app = launch(archive: archive, headroomBytes: -1)

    let start = app.buttons["device.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    guard XCTWaiter().wait(for: [enabled], timeout: 30) == .completed else {
      throw XCTSkip("no single adopted device is observed, so the pane has no target")
    }
    start.click()

    XCTAssertTrue(
      app.descendants(matching: .any)["device.record.ready"].waitForExistence(timeout: 180),
      "the run must go ahead; the pane is in " + Self.visibleStage(of: app))
    // And it says the check did not happen, rather than letting a run that was
    // never checked look like one that was.
    XCTAssertTrue(
      app.descendants(matching: .any)["device.record.headroomUnknown"].exists,
      "a run nothing checked must say so")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "device.record.refused").count, 0,
      "not being able to ask is not a refusal")
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

    let performance = app.descendants(matching: .any)["device.performance"]
    let boundary = app.descendants(matching: .any)["device.boundary"]
    XCTAssertTrue(performance.waitForExistence(timeout: 10))
    XCTAssertTrue(boundary.exists)

    // Nothing offers to close either of them. A dismiss control that exists
    // is a dismiss control somebody will use.
    for notice in ["device.performance", "device.boundary"] {
      let element = app.descendants(matching: .any)[notice]
      XCTAssertFalse(
        element.buttons.element(boundBy: 0).exists,
        "\(notice) must carry nothing that gets rid of it")
    }

    // And they survive the workspace being used: a run composed, validated
    // and offered is the longest thing a person does here.
    let start = app.buttons["device.record.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: start)
    if XCTWaiter().wait(for: [enabled], timeout: 30) == .completed {
      start.click()
      _ = app.descendants(matching: .any)["device.record.ready"].waitForExistence(timeout: 180)
    }
    XCTAssertTrue(performance.exists, "the notice went away while the workspace was used")
    XCTAssertTrue(boundary.exists, "the boundary went away while the workspace was used")

    // Including after leaving Device and coming back, which is where a
    // dismissed-state bug would otherwise hide.
    app.descendants(matching: .any)["app.navigation.overview"].firstMatch.click()
    app.descendants(matching: .any)["app.navigation.device"].firstMatch.click()
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

    let start = app.buttons["device.record.start"]
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
      app.descendants(matching: .any).matching(identifier: "device.record.headroomUnknown")
        .count, 0,
      "the run never started: the pane could not read the store's headroom")

    let ready = app.descendants(matching: .any)["device.record.ready"]
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
    let location = app.descendants(matching: .any)["device.record.location"]
    XCTAssertTrue(location.exists, "a recording nobody can find is not delivered")
    XCTAssertTrue("\(location.value ?? "")".hasSuffix(".mov"), "\(location.value ?? "")")
    // Link-styled controls are not `buttons` in the accessibility tree, so the
    // query is by identifier rather than by element type.
    for control in ["device.record.reveal", "device.record.saveAs", "device.record.again"] {
      XCTAssertTrue(
        app.descendants(matching: .any)[control].exists,
        "the result bar must offer \(control)")
    }

    // Recording again returns the pane to where a second run starts from.
    app.descendants(matching: .any)["device.record.again"].firstMatch.click()
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
