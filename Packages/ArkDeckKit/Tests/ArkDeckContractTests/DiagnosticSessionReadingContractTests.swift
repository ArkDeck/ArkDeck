import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// What a session may be shown to say (TASK-IDC-003 stage 4).
///
/// The reader's job is mostly refusal. A screenshot taken 400 ms after a mark
/// is a picture of a different moment; a session with no calibration cannot
/// line anything up against device time; a capture missing its trace is not a
/// whole session. Each of those has to reach the person reading it, because
/// the alternative - a plausible picture beside a mark - is how a debugging
/// session goes wrong quietly.
final class DiagnosticSessionReadingContractTests: XCTestCase {
  private func markers(_ entries: [[String: Any]], notDerived: [String] = []) -> [String: Any] {
    [
      "documentType": "arkdeck-diagnostic-markers",
      "jobId": "job-reader-1",
      "markers": entries,
      "notDerived": notDerived.map { ["kind": $0, "reason": "nothing looked"] },
    ]
  }

  private func manual(_ at: String, label: String? = nil) -> [String: Any] {
    var entry: [String: Any] = ["kind": "manual", "atHostUTC": at]
    if let label { entry["label"] = label }
    return entry
  }

  // MARK: - What may stand beside a mark

  /// A screenshot stands for the moment the shutter opened, never for the
  /// moment it was asked for, so the offset is part of the reading.
  func testAScreenshotTakenNearAMarkCarriesHowLateItWas() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z", label: "stutter")]),
      screenshots: [("screenshot.png", "2026-08-26T10:00:00.120Z")])
    let mark = reading.marks[0]
    XCTAssertEqual(mark.label, "stutter")
    XCTAssertEqual(mark.screenshot?.takenAfterMarkMs, 120)
    XCTAssertNil(mark.screenshotAbsence)
  }

  /// Past the window it is a picture of a different moment. The reader says
  /// how far off rather than showing it anyway.
  func testAScreenshotTakenTooLateIsNotShownForThatMark() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z")]),
      screenshots: [("screenshot.png", "2026-08-26T10:00:00.400Z")])
    XCTAssertNil(reading.marks[0].screenshot)
    XCTAssertEqual(
      reading.marks[0].screenshotAbsence, .takenTooFarFromTheMark(offsetMs: 400))
  }

  /// A capture that failed keeps the mark and says why. The design is explicit
  /// that nothing is filled in with an older frame or a placeholder.
  func testAFailedCaptureKeepsTheMarkAndTheReason() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z", label: "froze")]),
      failedScreenshots: [("2026-08-26T10:00:00.050Z", "the surface is secure")])
    XCTAssertEqual(reading.marks[0].label, "froze")
    XCTAssertNil(reading.marks[0].screenshot)
    XCTAssertEqual(
      reading.marks[0].screenshotAbsence, .captureFailed(reason: "the surface is secure"))
  }

  func testAMarkWithNoCaptureAtAllSaysThatRatherThanNothing() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z")]))
    XCTAssertEqual(reading.marks[0].screenshotAbsence, .notCaptured)
  }

  /// With several captures the nearest one decides, so a later screenshot
  /// cannot displace the one actually taken at the mark.
  func testTheNearestCaptureIsTheOneThatStandsForTheMark() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z")]),
      screenshots: [
        ("late.png", "2026-08-26T10:00:00.140Z"),
        ("near.png", "2026-08-26T10:00:00.020Z"),
      ])
    XCTAssertEqual(reading.marks[0].screenshot?.artifactName, "near.png")
    XCTAssertEqual(reading.marks[0].screenshot?.takenAfterMarkMs, 20)
  }

  // MARK: - Alignment

  /// Without a calibration fact, nothing in the session may be lined up
  /// against device time. Defaulting to "same clock" would make every reading
  /// below it quietly unsound, so the default is the refusal.
  func testASessionWithNoCalibrationCannotAlign() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00Z")]))
    guard case .cannotAlign(let reason) = reading.alignment else {
      return XCTFail("expected cannotAlign, got \(reading.alignment)")
    }
    XCTAssertFalse(reason.isEmpty, "a refusal has to say what is missing")
  }

  func testACalibratedSessionCarriesItsTolerance() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00Z")]),
      calibration: .calibrated(toleranceMs: 12))
    XCTAssertEqual(reading.alignment, .calibrated(toleranceMs: 12))
  }

  // MARK: - Partial

  /// A session missing a product it declared is Partial, and names what is
  /// missing. A reader who cannot see the trace must learn that there is no
  /// trace, not that this session had nothing to say about it.
  func testASessionMissingAProductReadsAsPartialAndNamesIt() {
    let whole = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00Z")]))
    XCTAssertFalse(whole.isPartial)

    let partial = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00Z")]),
      declaredButMissing: [
        .init(name: "trace.htrace", reason: "the device wrote a zero-byte file")
      ])
    XCTAssertTrue(partial.isPartial)
    XCTAssertEqual(partial.missingProducts.first?.name, "trace.htrace")
    XCTAssertFalse(partial.missingProducts[0].reason.isEmpty)
  }

  /// What nothing looked for travels from the capture into the reading, so a
  /// reader who sees no frame marker learns that nothing looked.
  func testWhatNothingLookedForReachesTheReader() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([], notDerived: ["frameDeadline", "logKeyword"]))
    XCTAssertEqual(reading.notDerived, ["frameDeadline", "logKeyword"])
  }

  func testAnAutomaticMarkIsDistinguishableAndCarriesItsTrigger() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([
        manual("2026-08-26T10:00:00Z"),
        ["kind": "auto", "atHostUTC": "2026-08-26T10:00:05Z", "trigger": "crashLogCaptured"],
      ]))
    XCTAssertFalse(reading.marks[0].isAutomatic)
    XCTAssertTrue(reading.marks[1].isAutomatic)
    XCTAssertEqual(reading.marks[1].trigger, "crashLogCaptured")
    XCTAssertEqual(reading.marks.map(\.ordinal), [1, 2])
  }

  // MARK: - Selection

  /// Reading a stutter means looking at an event and then at the log lines
  /// around it. Losing the event because the eye went to a log line would make
  /// that impossible, so moving the cursor never changes the selection.
  func testASelectedEventSurvivesTheCursorMovingAway() {
    var selection = DiagnosticReaderSelection(cursorUTC: "2026-08-26T10:00:00.000Z")
    selection.select(
      .init(identity: "evt-1", name: "doComposition", startUTC: "2026-08-26T10:00:01.000Z"))
    XCTAssertEqual(selection.cursorUTC, "2026-08-26T10:00:01.000Z")

    selection.moveCursor(to: "2026-08-26T10:00:01.966Z")
    XCTAssertEqual(selection.event?.identity, "evt-1", "a log line must not clear the event")
    XCTAssertEqual(selection.cursorOffsetFromEventMs(), 966)
  }

  func testChoosingAnotherEventIsWhatChangesTheSelection() {
    var selection = DiagnosticReaderSelection(cursorUTC: "2026-08-26T10:00:00.000Z")
    selection.select(.init(identity: "evt-1", name: "a", startUTC: "2026-08-26T10:00:01.000Z"))
    selection.select(.init(identity: "evt-2", name: "b", startUTC: "2026-08-26T10:00:02.000Z"))
    XCTAssertEqual(selection.event?.identity, "evt-2")
    XCTAssertEqual(selection.cursorOffsetFromEventMs(), 0)
  }

  func testWithNothingSelectedTheReaderHasOnlyATimePoint() {
    let selection = DiagnosticReaderSelection(cursorUTC: "2026-08-26T10:00:00.000Z")
    XCTAssertNil(selection.event)
    XCTAssertNil(selection.cursorOffsetFromEventMs())
  }
}
