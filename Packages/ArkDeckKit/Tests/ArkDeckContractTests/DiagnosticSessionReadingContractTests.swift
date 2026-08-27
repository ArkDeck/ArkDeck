import Foundation
import XCTest

@testable import ArkDeckCore
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
  func testPlainTextPreviewDisclosesInvalidUTF8WithoutChangingTheArtifact() throws {
    let bytes = Data([0x61, 0xFF, 0x62, 0xC3, 0xA9])
    let digest = SHA256Hex.string(of: bytes)
    let preview = try XCTUnwrap(DiagnosticArtifactTextPreview(bytes: bytes, mediaType: "text/plain"))
    XCTAssertEqual(preview.text, "a\u{FFFD}bé")
    XCTAssertTrue(preview.replacedInvalidUTF8)
    XCTAssertFalse(preview.wasClipped)
    XCTAssertEqual(SHA256Hex.string(of: bytes), digest)
    XCTAssertNil(DiagnosticArtifactTextPreview(bytes: bytes, mediaType: "application/json"),
      "structured evidence must never be silently repaired")
  }

  func testTextPreviewKeepsValidUnicodeAndClipsOnlyTheDisplay() throws {
    let bytes = Data("日志😀\n下一行".utf8)
    let full = try XCTUnwrap(DiagnosticArtifactTextPreview(bytes: bytes, mediaType: "text/plain"))
    XCTAssertEqual(full.text, "日志😀\n下一行")
    XCTAssertFalse(full.replacedInvalidUTF8)
    let clipped = try XCTUnwrap(DiagnosticArtifactTextPreview(
      bytes: bytes, mediaType: "text/plain", maximumCharacters: 3))
    XCTAssertEqual(clipped.text, "日志😀")
    XCTAssertTrue(clipped.wasClipped)
    XCTAssertFalse(clipped.replacedInvalidUTF8)
    XCTAssertNil(DiagnosticArtifactTextPreview(bytes: bytes, mediaType: "image/png"))
    XCTAssertNil(DiagnosticArtifactTextPreview(bytes: bytes, mediaType: "text/plain", maximumCharacters: 0))
    XCTAssertNil(DiagnosticArtifactTextPreview(
      bytes: Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1), mediaType: "text/plain"))
  }

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

  // MARK: - What the host could actually observe

  /// The host cannot see the shutter open; it sees the interval it was
  /// dispatching in. When that interval is wider than the rule consuming it,
  /// nothing here can decide whether the picture is this moment - and saying
  /// so is different from saying the picture is not this moment.
  ///
  /// This is not hypothetical: taking a screenshot on the device occupies
  /// about 550 ms, against a 150 ms rule.
  func testAShutterWindowWiderThanTheRuleIsSaidToBeUndecidable() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.300Z")]),
      observedScreenshots: [
        .init(
          artifactName: "screenshot.png",
          windowStartUTC: "2026-08-26T10:00:00.000Z",
          windowEndUTC: "2026-08-26T10:00:00.550Z")
      ])
    XCTAssertNil(reading.marks[0].screenshot)
    XCTAssertEqual(
      reading.marks[0].screenshotAbsence, .shutterWindowWiderThanTheRule(windowMs: 550))
  }

  /// A window inside the rule decides normally, and the offset is measured
  /// from where the window opened - the earliest the shutter can have been.
  func testATightShutterWindowStandsForTheMark() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:00.000Z")]),
      observedScreenshots: [
        .init(
          artifactName: "screenshot.png",
          windowStartUTC: "2026-08-26T10:00:00.040Z",
          windowEndUTC: "2026-08-26T10:00:00.120Z")
      ])
    XCTAssertEqual(reading.marks[0].screenshot?.artifactName, "screenshot.png")
    XCTAssertEqual(reading.marks[0].screenshot?.takenAfterMarkMs, 40)
  }

  /// A mark outside the window entirely is not undecidable - there is simply
  /// no capture at it.
  func testAMarkOutsideEveryObservedWindowHasNoCapture() {
    let reading = DiagnosticSessionReading.make(
      markersDocument: markers([manual("2026-08-26T10:00:09.000Z")]),
      observedScreenshots: [
        .init(
          artifactName: "screenshot.png",
          windowStartUTC: "2026-08-26T10:00:00.000Z",
          windowEndUTC: "2026-08-26T10:00:00.550Z")
      ])
    XCTAssertEqual(reading.marks[0].screenshotAbsence, .notCaptured)
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

  func testPublishedSessionLoadsWithoutInventingClockOrAutomaticMarkerTime() async throws {
    let fixture = try SessionFixture()
    let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
    guard case .loaded(let session) = result else { return XCTFail("\(result)") }
    XCTAssertFalse(session.reading.isPartial, "unselected optional trace is not a failed capture")
    XCTAssertEqual(session.reading.marks.count, 2)
    XCTAssertEqual(session.reading.marks[1].atHostUTC, "")
    XCTAssertTrue(session.reading.marks.allSatisfy { $0.screenshot == nil })
    guard case .cannotAlign = session.reading.alignment else { return XCTFail("no calibration exists") }
    XCTAssertEqual(session.reading.notDerived, ["frameDeadline"])
    let reads = await fixture.provider.readNames()
    XCTAssertEqual(reads, ["artifact-index.json", "capture-summary.json", "markers.json"])
  }

  func testRequestedMissingTraceMakesSessionPartialEvenWhenSummaryRequiredFieldsAreComplete() async throws {
    let fixture = try SessionFixture(traceRequested: true)
    let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
    guard case .loaded(let session) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(session.reading.missingProducts.map(\.name), ["trace.htrace"])
  }

  func testWrongMarkerIdentitySchemaSummaryAndMalformedInputsAreRejected() async throws {
    for defect in ["markerJob", "markerSchema", "summary", "corruptBytes", "captureHilogType", "traceCategoriesType", "screenshotImageType"] {
      let fixture = try SessionFixture(defect: defect)
      let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
      guard case .unavailable = result else { return XCTFail("accepted \(defect): \(result)") }
    }
  }

  func testPublishedJPEGSatisfiesScreenshotChannelWithoutInventingATimestamp() async throws {
    let fixture = try SessionFixture(defect: "jpegOnly")
    let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
    guard case .loaded(let session) = result else { return XCTFail("\(result)") }
    XCTAssertFalse(session.reading.isPartial)
    XCTAssertTrue(session.artifacts.contains(where: { $0.name == "screenshot.jpeg" }))
    XCTAssertTrue(session.reading.marks.allSatisfy { $0.screenshot == nil })
    let reads = await fixture.provider.readNames()
    XCTAssertFalse(reads.contains("screenshot.jpeg"), "navigation must not read sensitive image bytes")
  }

  func testMissingScreenshotNamesTheRequestedJPEGEncoding() async throws {
    let fixture = try SessionFixture(defect: "jpegMissing")
    let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
    guard case .loaded(let session) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(session.reading.missingProducts.map(\.name), ["screenshot.jpeg"])
    XCTAssertEqual(session.reading.missingProducts.first?.reason, "capture failed")
  }

  func testFreshTargetMismatchDoesNotReadAnyArtifactBytes() async throws {
    let fixture = try SessionFixture(defect: "target")
    let result = await DiagnosticSessionApplicationReader(provider: fixture.provider).load(fixture.context)
    XCTAssertEqual(result, .unavailable("diagnostics_job_correlation_unavailable"))
    let reads = await fixture.provider.readNames()
    XCTAssertTrue(reads.isEmpty)
  }
}

private struct SessionFixture {
  let context: RuntimeHistoryWorkspaceContext
  let provider: SessionArtifactProvider

  init(traceRequested: Bool = false, defect: String = "") throws {
    let jobID = "job-reader-1"
    let operation = "capture.diagnostics@1"
    func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    func response(_ value: Any) throws -> RuntimeHistoryTransportResult {
      .success(try data(["ok": true, "result": value]))
    }
    var marker: [String: Any] = [
      "documentType": "arkdeck-diagnostic-markers", "schemaVersion": "1.0.0", "jobId": jobID,
      "markers": [
        ["kind": "manual", "atHostUTC": "2026-08-27T08:00:00Z", "label": "stutter"],
        ["kind": "auto", "trigger": "stepFailed", "detail": "failed capture-trace"],
      ],
      "notDerived": [["kind": "frameDeadline", "reason": "not inspected"]],
    ]
    if defect == "markerJob" { marker["jobId"] = "another-job" }
    if defect == "markerSchema" { marker["schemaVersion"] = "9.0.0" }
    var products: [String: Any] = [
      "trace.htrace": ["status": "missing", "required": false, "detail": "never produced"]
    ]
    let jpeg = Data("fixture metadata only; no image decode".utf8)
    if defect == "jpegOnly" {
      products["screenshot.jpeg"] = [
        "status": "published", "required": false, "artifactId": "artifact-screenshot.jpeg",
        "byteCount": jpeg.count, "sha256": SHA256Hex.string(of: jpeg),
      ]
    }
    if defect == "jpegMissing" {
      products["screenshot.jpeg"] = ["status": "missing", "required": false, "detail": "capture failed"]
    }
    let index: [String: Any] = ["jobId": jobID, "operation": operation, "artifacts": products]
    var summary = index
    summary["completeness"] = "complete"
    summary["missingRequired"] = [String]()
    if defect == "summary" { summary["operation"] = "observe.device@1" }
    var documents = [
      "artifact-index.json": try data(index), "capture-summary.json": try data(summary),
      "markers.json": try data(marker),
    ]
    if defect == "jpegOnly" { documents["screenshot.jpeg"] = jpeg }
    let inventory: [[String: Any]] = documents.keys.sorted().map { name in
      let bytes = documents[name]!
      return [
        "jobId": jobID, "artifactId": "artifact-\(name)", "name": name,
        "role": name == "screenshot.jpeg" ? "raw" : "derived",
        "mediaType": name == "screenshot.jpeg" ? "image/jpeg" : "application/json", "byteCount": bytes.count,
        "sha256": SHA256Hex.string(of: bytes), "privacy": name == "screenshot.jpeg" ? "sensitive" : "standard", "status": "published",
        "sourceOperation": operation, "createdAtUtc": "2026-08-27T08:00:00.020Z", "redactionApplied": true,
      ]
    }
    if defect == "corruptBytes" { documents["markers.json"] = Data("{}".utf8) }
    var parameters: [String: Any] = [
      "durationSeconds": 10, "captureHilog": false, "uiDump": false,
      "traceCategories": traceRequested ? ["ace"] : [],
    ]
    if defect == "jpegOnly" { parameters["uiScreenshot"] = true }
    if defect == "jpegMissing" {
      parameters["uiScreenshot"] = true
      parameters["screenshotImageType"] = "jpeg"
    }
    if defect == "screenshotImageType" {
      parameters["uiScreenshot"] = true
      parameters["screenshotImageType"] = "gif"
    }
    if defect == "captureHilogType" { parameters["captureHilog"] = "false" }
    if defect == "traceCategoriesType" { parameters["traceCategories"] = [1] }
    let detail = RuntimeJobDetailResponseDecoding.presentation(
      jobID: jobID, operationReference: operation,
      statusResponse: try response([
        "jobId": jobID, "operation": operation, "targetId": defect == "target" ? "other-target" : "target-1",
        "sessionId": "session-1", "timeline": ["queued", "running", "succeeded"],
      ]),
      evidenceResponse: try response([
        "jobId": jobID, "operationReference": operation, "catalogDigest": String(repeating: "a", count: 64),
        "providerId": "hdc", "executionMode": "execute", "terminalState": "succeeded",
        "parameters": parameters,
      ]),
      artifactResponse: try response(inventory))
    let job = RuntimeJobSummaryPresentation(
      id: jobID, operationReference: operation, targetID: "target-1", state: "succeeded",
      waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0, timeline: [],
      executionMode: "execute", sessionID: "session-1", workspaceKind: .diagnostics)
    context = try XCTUnwrap(RuntimeHistoryWorkspaceContext(job: job, detail: detail))
    provider = SessionArtifactProvider(detail: detail, documents: documents)
  }
}

private actor SessionArtifactProvider: RuntimeJobDetailApplicationProviding {
  let detail: RuntimeJobDetailPresentation
  let documents: [String: Data]
  private var reads: [String] = []
  init(detail: RuntimeJobDetailPresentation, documents: [String: Data]) {
    self.detail = detail
    self.documents = documents
  }
  func readNames() -> [String] { reads }
  func loadJobDetail(jobID: String, operationReference: String) -> RuntimeJobDetailPresentation { detail }
  func exportArtifact(jobID: String, artifact: RuntimeArtifactPresentation, destinationURL: URL, allowSensitive: Bool)
    -> RuntimeArtifactExportResult { .failed("no export in reader tests") }
  func readArtifact(jobID: String, artifact: RuntimeArtifactPresentation, maximumBytes: Int, allowSensitive: Bool)
    -> RuntimeArtifactReadResult {
    reads.append(artifact.name)
    guard !allowSensitive, maximumBytes == 1_024 * 1_024, let data = documents[artifact.name] else {
      return .failed("unexpected artifact read")
    }
    return .loaded(data)
  }
}
