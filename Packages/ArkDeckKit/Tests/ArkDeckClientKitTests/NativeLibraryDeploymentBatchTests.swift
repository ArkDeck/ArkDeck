import Foundation
import Testing

@testable import ArkDeckClientKit

@MainActor
struct NativeLibraryDeploymentBatchTests {
  private let target = DebugTargetPresentation(
    id: "target-a", bindingRevision: 3, toolVersion: "fixture", adoptedAtUTC: "fixture")
  private let sources: [NativeLibraryDeploymentSource] = [
    .file(URL(filePath: "/build/libfirst.so")),
    .ssh(sourceID: UUID(), sourceName: "WSL build", relativePath: "out/libsecond.so"),
  ]

  @Test func reviewDoesNotDispatchAndSuccessAdvancesSerially() async {
    let provider = BatchProvider()
    let batch = NativeLibraryDeploymentBatch(provider: provider)
    await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
    #expect(batch.phase == .review)
    #expect(await provider.calls == ["prepare:libfirst.so", "prepare:libsecond.so"])
    await batch.submitReviewed()
    #expect(batch.phase == .succeeded)
    #expect(batch.rows.allSatisfy { $0.state == .succeeded })
    #expect(await provider.calls == [
      "prepare:libfirst.so", "prepare:libsecond.so", "submit:libfirst.so", "run:job-libfirst.so",
      "submit:libsecond.so", "run:job-libsecond.so",
    ])
  }

  @Test func failureOrUnknownNeverSubmitsTheNextLibrary() async {
    for outcome in [BatchProvider.Outcome.unknown, .failed, .wrongJob] {
      let provider = BatchProvider(outcome: outcome)
      let batch = NativeLibraryDeploymentBatch(provider: provider)
      await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
      await batch.submitReviewed()
      #expect(batch.phase == .failed)
      #expect(batch.rows[0].state == .failed)
      #expect(batch.rows[0].jobID == "job-libfirst.so")
      #expect(batch.rows[1].jobID == nil)
      #expect(await provider.calls.filter { $0.hasPrefix("submit:") } == ["submit:libfirst.so"])
    }
  }

  @Test func lostSubmissionReplyIsNotRetriedOrFollowedByAnotherJob() async {
    let provider = BatchProvider(outcome: .lostSubmission)
    let batch = NativeLibraryDeploymentBatch(provider: provider)
    await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
    await batch.submitReviewed()
    await batch.submitReviewed()
    #expect(batch.phase == .failed)
    #expect(await provider.calls == [
      "prepare:libfirst.so", "prepare:libsecond.so", "submit:libfirst.so",
    ])
  }

  @Test func stopDuringSubmissionRetainsCurrentJobReceiptAndStopsTheQueue() async {
    let provider = BatchProvider(pause: "submit")
    let batch = NativeLibraryDeploymentBatch(provider: provider)
    await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
    let task = Task { await batch.submitReviewed() }
    await provider.waitUntilPaused()
    batch.stop()
    #expect(batch.isBusy)
    await batch.submitReviewed()
    await provider.release()
    await task.value
    #expect(batch.phase == .stopped)
    #expect(!batch.isBusy)
    #expect(batch.rows[0].state == .succeeded)
    #expect(batch.rows[0].jobID == "job-libfirst.so")
    #expect(batch.rows[1].jobID == nil)
    #expect(await provider.calls.last == "run:job-libfirst.so")
  }

  @Test func changedSelectionCannotPublishLatePlansOrStartAnotherPreparation() async {
    let provider = BatchProvider(pause: "prepare")
    let batch = NativeLibraryDeploymentBatch(provider: provider)
    let task = Task {
      await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
    }
    await provider.waitUntilPaused()
    batch.invalidate()
    await provider.release()
    await task.value
    #expect(batch.phase == .stopped)
    #expect(batch.rows.allSatisfy { $0.preparation == nil })
    await batch.submitReviewed()
    #expect(await provider.calls == ["prepare:libfirst.so"])
  }

  @Test func mismatchedPlanAndDuplicateDestinationAreRefusedBeforeSubmission() async {
    let provider = BatchProvider(outcome: .wrongPlan)
    let batch = NativeLibraryDeploymentBatch(provider: provider)
    await batch.prepare(sources: sources, target: target, targetBundle: "com.example.app")
    #expect(batch.phase == .failed)
    #expect(await provider.calls == ["prepare:libfirst.so"])
    let empty = BatchProvider()
    let collision = NativeLibraryDeploymentBatch(provider: empty)
    await collision.prepare(
      sources: [.file(URL(filePath: "/one/libsame.so")), .file(URL(filePath: "/two/libsame.so"))],
      target: target, targetBundle: "com.example.app")
    #expect(collision.phase == .failed)
    #expect(await empty.calls.isEmpty)
  }

  @Test func directoryScanIncludesNestedLibrariesButDoesNotFollowLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appending(path: "out")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appending(path: "libexample.so"))
    try Data().write(to: root.appending(path: "readme.txt"))
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "liblinked.so"), withDestinationURL: nested.appending(path: "libexample.so"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "loop"), withDestinationURL: root)
    let found = try await NativeLibraryDirectorySource.libraries(in: [root])
    #expect(found.map(\.name) == ["libexample.so"])
    #expect(!NativeLibraryDirectorySource.contains(root.appending(path: "liblinked.so"), in: root))
    #expect(!NativeLibraryDirectorySource.contains(root.appending(path: "../libescape.so"), in: root))
  }

  @Test func directoryScanRefusesOversizedRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    for index in 0..<501 { try Data().write(to: root.appending(path: "file-\(index)")) }
    await #expect(throws: NativeLibraryDirectorySource.Failure.self) {
      try await NativeLibraryDirectorySource.libraries(in: [root])
    }
  }
}

private actor BatchProvider: NativeLibraryDeploymentProviding {
  enum Outcome { case success, unknown, failed, wrongJob, lostSubmission, wrongPlan }
  private let outcome: Outcome
  private var pause: String?
  private var paused = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var calls: [String] = []

  init(outcome: Outcome = .success, pause: String? = nil) {
    self.outcome = outcome
    self.pause = pause
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func release() { continuation?.resume(); continuation = nil }

  private func checkpoint(_ action: String) async {
    guard pause == action else { return }
    pause = nil
    paused = true
    pauseWaiters.forEach { $0.resume() }
    pauseWaiters.removeAll()
    await withCheckedContinuation { continuation = $0 }
  }

  func prepareNativeLibrary(
    target: DebugTargetPresentation, fileURL: URL, targetBundle: String,
    libraryLogicalName: String, verificationProfile: String, rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult {
    calls.append("prepare:\(libraryLogicalName)")
    await checkpoint("prepare")
    return .prepared(DebugNativeLibraryPreparation(
      operationReference: DebugApplicationFacade.nativeLibraryReference,
      targetID: outcome == .wrongPlan ? "different-target" : target.id,
      bindingRevision: target.bindingRevision, libraryName: libraryLogicalName,
      byteCount: 128, sha256: String(repeating: "a", count: 64), abi: "arm64-v8a",
      elfClassBits: 64, machine: 183, buildID: "fixture", targetBundle: targetBundle,
      verificationProfile: verificationProfile, rollbackPolicy: rollbackPolicy,
      planDigest: String(repeating: "b", count: 64), steps: [], requestJSON: "{}"))
  }

  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation, sourceID: UUID, relativePath: String,
    targetBundle: String, libraryLogicalName: String, verificationProfile: String,
    rollbackPolicy: String
  ) async -> DebugNativeLibraryPreparationResult {
    await prepareNativeLibrary(
      target: target, fileURL: URL(filePath: "/unused"), targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName, verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
  }

  func submitNativeLibrary(preparation: DebugNativeLibraryPreparation) async -> DebugLogJobSubmissionResult {
    calls.append("submit:\(preparation.libraryName)")
    await checkpoint("submit")
    if outcome == .lostSubmission { return .failed("reply lost") }
    return .submitted(DebugLogJobAcceptancePresentation(jobID: "job-" + preparation.libraryName))
  }

  func run(jobID: String) async -> DebugLogJobRunResult {
    calls.append("run:\(jobID)")
    return .completed(DebugLogJobTerminalPresentation(
      jobID: outcome == .wrongJob ? "different-job" : jobID,
      state: outcome == .failed ? "failed" : "succeeded",
      outcomeUnknown: outcome == .unknown, timeline: []))
  }
}
