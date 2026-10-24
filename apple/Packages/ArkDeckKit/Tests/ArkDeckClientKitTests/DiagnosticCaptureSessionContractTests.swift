import ArkDeckCore
import Foundation
import Testing
@testable import ArkDeckClientKit

@MainActor
struct DiagnosticCaptureSessionContractTests {
  private let target = DeviceTargetPresentation(id: "TGT-fixture", bindingRevision: 1, displayName: "Fixture")

  @Test func recordingRequiresRuntimeReadinessAndControlsStayOnOriginalTarget() async throws {
    let provider = CaptureFixture()
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    await session.start(target: target, durationSeconds: 60)
    #expect(!session.canStart)
    #expect(!session.canMark)
    #expect(session.canCancelPreparation)
    await provider.recording()
    await session.refresh()
    #expect(session.canMark && session.canStop)
    session.selectionChanged(to: .init(id: "another-target", bindingRevision: 2, displayName: "Other"))
    await session.mark()
    #expect(session.snapshot?.markers.count == 1)
    #expect(await provider.markTargets == ["TGT-fixture"])
    await session.stop()
    #expect(session.snapshot?.stopRequested == true)
    #expect(!session.canMark && !session.canStop)
    await session.start(target: target, durationSeconds: 60)
    #expect(await provider.submissions == 1)
  }

  @Test func lostMarkerReplyReadsBackOnceAndNeverResends() async throws {
    let provider = CaptureFixture()
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    await session.start(target: target, durationSeconds: 60)
    await provider.recording(loseMarkerReply: true)
    await session.refresh()
    await session.mark()
    #expect(await provider.marks == 1)
    #expect(session.snapshot?.markers.count == 1)
    #expect(session.phase == .active)
  }

  @Test func uncertainSubmissionBlocksAnotherStartAndNeverRunsUnknownJob() async {
    let provider = CaptureFixture(loseSubmitReply: true)
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    await session.start(target: target, durationSeconds: 60)
    #expect(session.phase == .uncertain && !session.canStart)
    await session.start(target: target, durationSeconds: 60)
    #expect(await provider.submissions == 1)
    #expect(await provider.runs == 0)
  }

  @Test func changedBindingInvalidatesPreflightBeforeSubmission() async {
    let provider = CaptureFixture(holdPreflight: true)
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    let starting = Task { await session.start(target: target, durationSeconds: 60) }
    await provider.awaitPreflight()
    session.selectionChanged(to: .init(id: target.id, bindingRevision: 2, displayName: target.displayName))
    await provider.releasePreflight()
    await starting.value
    #expect(session.phase == .idle)
    #expect(await provider.submissions == 0)
  }

  @Test func mismatchedRuntimeReplyDisablesAllControls() async {
    let provider = CaptureFixture()
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    await session.start(target: target, durationSeconds: 60)
    await provider.recording(wrongTarget: true)
    await session.refresh()
    #expect(session.phase == .uncertain)
    #expect(!session.canStart && !session.canMark && !session.canStop)
  }

  @Test func sessionRequestUsesExactBindingAndAdmittedBudgets() throws {
    let request = try DiagnosticCaptureFacade.request(target: target, durationSeconds: 30, nonce: "one")
    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
    let inputs = value["inputs"] as! [String: Any]
    #expect(inputs["durationSeconds"] as? Int == 30)
    #expect(inputs["maximumMarkers"] as? Int == 50)
    #expect(inputs["totalArtifactByteBudget"] as? Int == 128 * 1024 * 1024)
    #expect(inputs["markers"] == nil && inputs["captureHilog"] == nil)
    #expect(value["authorization"] == nil)
    #expect((value["target"] as? [String: Any])?["expectedBindingRevision"] as? Int == 1)
    #expect(throws: DiagnosticCaptureFailure.self) {
      try DiagnosticCaptureFacade.request(target: target, durationSeconds: 121, nonce: "two")
    }
  }

  @Test func terminalSessionOpensItsOwnHistoryOnceAfterSelectionChanges() async {
    let provider = CaptureFixture()
    let session = DiagnosticCaptureSession(provider: provider, pause: { throw CancellationError() })
    await session.start(target: target, durationSeconds: 60)
    session.selectionChanged(to: .init(id: "another-target", bindingRevision: 2, displayName: "Other"))
    await provider.finish()
    await session.refresh()
    await session.refresh()
    #expect(session.completedContext?.jobID == "job-fixture")
    #expect(session.completedContext?.targetID == target.id)
    #expect(session.completedContext?.operationReference == DiagnosticCaptureFacade.operationReference)
    #expect(await provider.historyReads == 1)
    #expect(session.phase == .finished && session.canStart)
  }
}

private actor CaptureFixture: DiagnosticCaptureProviding {
  var submissions = 0
  var runs = 0
  var marks = 0
  var markTargets: [String] = []
  var historyReads = 0
  private var finished = false
  private let loseSubmitReply: Bool
  private let holdPreflight: Bool
  private var loseMarkerReply = false
  private var wrongTarget = false
  private var ready = false
  private var stopped = false
  private var markerIDs: [String] = []
  private var preflightStarted = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var preflightWaiter: CheckedContinuation<Void, Never>?

  init(loseSubmitReply: Bool = false, holdPreflight: Bool = false) {
    self.loseSubmitReply = loseSubmitReply
    self.holdPreflight = holdPreflight
  }
  func preflight(target: DeviceTargetPresentation) async throws {
    preflightStarted = true
    startWaiter?.resume(); startWaiter = nil
    if holdPreflight { await withCheckedContinuation { preflightWaiter = $0 } }
  }
  func awaitPreflight() async {
    if !preflightStarted { await withCheckedContinuation { startWaiter = $0 } }
  }
  func releasePreflight() { preflightWaiter?.resume(); preflightWaiter = nil }
  func submit(target: DeviceTargetPresentation, durationSeconds: Int) throws -> String {
    submissions += 1
    if loseSubmitReply { throw DiagnosticCaptureFailure("lost submit reply", uncertain: true) }
    return "job-fixture"
  }
  func run(jobID: String) { runs += 1 }
  func recording(loseMarkerReply: Bool = false, wrongTarget: Bool = false) {
    ready = true
    self.loseMarkerReply = loseMarkerReply
    self.wrongTarget = wrongTarget
  }
  func status(jobID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
    try snapshot(jobID: jobID, target: target)
  }
  func mark(jobID: String, markerID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
    marks += 1; markerIDs.append(markerID); markTargets.append(target.id)
    if loseMarkerReply { throw DiagnosticCaptureFailure("lost mark reply", uncertain: true) }
    return try snapshot(jobID: jobID, target: target)
  }
  func stop(jobID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
    stopped = true
    return try snapshot(jobID: jobID, target: target)
  }
  func cancelPreparation(jobID: String) { stopped = true }
  func finish() { finished = true }
  func history(jobID: String, target: DeviceTargetPresentation) throws -> RuntimeHistoryWorkspaceContext {
    historyReads += 1
    let job = RuntimeJobSummaryPresentation(
      id: jobID, operationReference: DiagnosticCaptureFacade.operationReference,
      targetID: target.id, state: "succeeded", waitingForHuman: false,
      outcomeUnknown: false, outstandingResidueCount: 0, timeline: [], workspaceKind: .diagnostics)
    let detail = RuntimeJobDetailPresentation(jobID: jobID, timelineAvailability: .available,
      timeline: [], evidenceAvailability: .available, evidence: nil,
      artifactAvailability: .available, artifacts: [], correlationAvailability: .available, correlation: nil)
    return RuntimeHistoryWorkspaceContext(job: job, detail: detail)!
  }
  private func snapshot(jobID: String, target: DeviceTargetPresentation) throws -> DiagnosticCaptureSnapshot {
    let value: [String: Any] = [
      "schemaVersion": "1.0.0", "jobId": jobID,
      "targetId": wrongTarget ? "wrong-target" : target.id, "bindingRevision": target.bindingRevision ?? 0,
      "state": finished ? "closed" : stopped ? "finalizing" : ready ? "recording" : "preparing", "jobState": finished ? "succeeded" : "running",
      "outcomeUnknown": false, "controlAvailable": ready, "maximumSeconds": 60, "maximumMarkers": 50,
      "elapsedMs": 100, "stopRequested": stopped,
      "armedAtHostUTC": ready ? "2026-10-04T00:00:00Z" : NSNull(), "endedAtHostUTC": NSNull(),
      "markers": markerIDs.map { ["markerId": $0, "atHostUTC": "2026-10-04T00:00:01Z", "offsetMs": 1000] as [String: Any] },
    ]
    return try JSONDecoder().decode(DiagnosticCaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
  }
}
