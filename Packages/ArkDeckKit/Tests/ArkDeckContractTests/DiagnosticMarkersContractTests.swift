import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The marks on a capture (TASK-IDC-003 stage 2).
///
/// A manual mark is an annotation on host time that reaches no device. An
/// automatic one is derived at finalization from facts the run already
/// established. What the runtime did *not* look for is stated in the document,
/// because a reader who finds no frame marker must be able to tell "nothing
/// looked" from "nothing happened".
final class DiagnosticMarkersContractTests: XCTestCase {
  private func document(
    inputs: [String: JSONValue], recorded: [RuntimeArtifactMetadata] = [],
    timeline: [String] = []
  ) throws -> [String: Any] {
    var record = RuntimeJobRecord(
      jobID: "job-markers-1",
      request: try RuntimeOperationRequest(
        requestID: "req-markers", idempotencyKey: "idem-markers",
        target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
        operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
        inputs: inputs),
      operationReference: "capture.diagnostics@1",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: "hdc",
      createdAtUTC: "2026-08-25T10:00:00Z",
      actualEffect: "readOnly",
      materializedPlanDigest: nil,
      materializedStableTargetIdentitySHA256: nil,
      materializedBindingRevision: 1)
    record.timeline = timeline
    let data = try RuntimeArtifactService.markersDocument(record: record, recorded: recorded)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func artifact(
    name: String, byteCount: Int, status: ArtifactStatus = .published
  ) -> RuntimeArtifactMetadata {
    RuntimeArtifactMetadata(
      artifactID: "ART-\(name.filter(\.isLetter))",
      jobID: "job-markers-1", sessionID: "session-markers-1", stepID: "capture-step",
      name: name, mediaType: "application/octet-stream", byteCount: byteCount,
      sha256: String(repeating: "a", count: 64), createdAtUTC: "2026-08-25T10:00:01Z",
      providerID: "hdc", sourceOperation: "capture.diagnostics@1",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-1", bindingRevision: 1, stableIdentitySHA256: nil),
      privacy: .standard,
      retention: ArtifactRetention(retentionClass: .default, deadlineUTC: nil),
      status: status, redactionApplied: false)
  }

  private func marks(_ document: [String: Any]) throws -> [[String: Any]] {
    try XCTUnwrap(document["markers"] as? [[String: Any]])
  }

  func testAManualMarkKeepsItsInstantAndItsLabel() throws {
    let parsed = try marks(
      try document(inputs: [
        "markers": .array([
          .string("2026-08-25T10:00:00Z#animation stalled"),
          .string("2026-08-25T10:00:04.250Z"),
        ])
      ]))
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0]["kind"] as? String, "manual")
    XCTAssertEqual(parsed[0]["atHostUTC"] as? String, "2026-08-25T10:00:00Z")
    XCTAssertEqual(parsed[0]["label"] as? String, "animation stalled")
    XCTAssertEqual(parsed[1]["atHostUTC"] as? String, "2026-08-25T10:00:04.250Z")
    XCTAssertNil(parsed[1]["label"], "a mark without a label does not get an empty one")
  }

  /// A capture with nothing marked on it still publishes the document. An
  /// absent artifact and an artifact saying "no marks" are different facts.
  func testACaptureWithNoMarksStillSaysSo() throws {
    let empty = try document(inputs: [:])
    XCTAssertEqual(try marks(empty).count, 0)
    XCTAssertEqual(empty["documentType"] as? String, "arkdeck-diagnostic-markers")
    XCTAssertEqual(empty["jobId"] as? String, "job-markers-1")
  }

  /// Derived from what the run already knows, not from reopening the file.
  func testACrashLogThatArrivedWithBytesBecomesAnAutomaticMark() throws {
    let crash = artifact(name: "crash-log.txt", byteCount: 4_096)
    let quiet = artifact(name: "crash-log.txt", byteCount: 0)

    let withCrash = try marks(try document(inputs: [:], recorded: [crash]))
    XCTAssertEqual(withCrash.count, 1)
    XCTAssertEqual(withCrash[0]["kind"] as? String, "auto")
    XCTAssertEqual(withCrash[0]["trigger"] as? String, "crashLogCaptured")
    XCTAssertEqual(withCrash[0]["evidenceArtifact"] as? String, "crash-log.txt")

    XCTAssertEqual(
      try marks(try document(inputs: [:], recorded: [quiet])).count, 0,
      "an empty crash log is not a crash")
  }

  func testAFailedStepBecomesAnAutomaticMark() throws {
    let parsed = try marks(
      try document(
        inputs: [:],
        timeline: ["intent capture-trace", "failed capture-trace: the device said no"]))
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0]["trigger"] as? String, "stepFailed")
    XCTAssertEqual(
      parsed[0]["detail"] as? String, "failed capture-trace: the device said no")
  }

  /// The absence of a marker kind must not read as the absence of the thing.
  func testTheDocumentNamesWhatNothingLookedFor() throws {
    let notDerived = try XCTUnwrap(
      try document(inputs: [:])["notDerived"] as? [[String: Any]])
    XCTAssertEqual(
      notDerived.compactMap { $0["kind"] as? String }.sorted(),
      ["frameDeadline", "logKeyword"])
    for entry in notDerived {
      let reason = try XCTUnwrap(entry["reason"] as? String)
      XCTAssertFalse(reason.isEmpty, "a kind nothing looked for has to say why")
    }
  }

  /// A ring capture records the anchor and where to check it. It does not
  /// claim the check passed: finalization never opened the trace.
  func testARingCaptureRecordsItsAnchorWithoutClaimingCoverage() throws {
    let trace = artifact(name: "trace.htrace", byteCount: 9_001)
    let coverage = try XCTUnwrap(
      try document(inputs: ["ringBuffered": .bool(true)], recorded: [trace])["coverage"]
        as? [String: Any])
    XCTAssertEqual(
      coverage["anchor"] as? String,
      HDCTraceCaptureRequest.anchor(sessionID: "job-markers-1", stepID: "capture-trace"))
    XCTAssertEqual(coverage["checkAgainst"] as? String, "trace.htrace")
    XCTAssertEqual(coverage["traceStatus"] as? String, "published")
    let how = try XCTUnwrap(coverage["how"] as? String)
    XCTAssertTrue(how.contains("string search"), how)

    let absent = try XCTUnwrap(
      try document(inputs: ["ringBuffered": .bool(true)])["coverage"] as? [String: Any])
    XCTAssertEqual(
      absent["traceStatus"] as? String, "absent",
      "an anchor with no trace to check it against says the trace is absent")
  }

  func testABlockingCaptureCarriesNoCoverageClaimAtAll() throws {
    XCTAssertNil(
      try document(inputs: [:])["coverage"],
      "a capture that armed no ring has no anchor to offer")
  }
}
