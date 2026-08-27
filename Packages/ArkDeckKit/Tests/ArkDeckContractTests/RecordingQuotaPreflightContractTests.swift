import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// A run that cannot be published must be refused before it starts
/// (TASK-IDC-002, recorded gap 3 of 5).
///
/// "Before it starts" is the whole requirement. A 300-frame run takes about
/// three minutes on this hardware, and finding out at the end that there was
/// never room to publish it wastes all of it - and, worse, leaves a person
/// believing they recorded something. The quota rule is refuse-never-evict, so
/// a full store cannot make room by discarding what somebody already captured.
final class RecordingQuotaPreflightContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-quota-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private func engine(
    quotaBytes: Int, dispatcher: WitnessDispatcher
  ) throws -> RuntimeJobEngine {
    try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: QuotaFactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: stateDirectory.appending(path: "cap", directoryHint: .isDirectory)),
      artifactStore: try RuntimeArtifactStore(
        rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
        quota: ArtifactQuota(totalBytes: quotaBytes),
        nowUTC: { "2026-08-26T12:00:00Z" }),
      nowUTC: { "2026-08-26T12:00:00Z" })
  }

  private func request(frames: Int, budget: Int) throws -> Data {
    try JSONEncoder().encode(
      RuntimeOperationRequest(
      requestID: "req-quota", idempotencyKey: "idem-\(UUID().uuidString)",
        target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
      operation: RuntimeOperationReference(id: "capture.screen-sequence", version: 1),
      inputs: [
        "frameCount": .integer(Int64(frames)),
        "totalArtifactByteBudget": .integer(Int64(budget)),
      ],
        clientContext: RuntimeClientContext(clientName: "ArkDeckApp.Device")))
  }

  /// The published step order is the load-bearing part: the host storage
  /// preflight is first, so a refusal cannot arrive after frames were taken.
  func testTheHostStoragePreflightIsTheOperationsFirstStep() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.screen-sequence@1"))
    XCTAssertEqual(descriptor.steps.first?.kind, .preflightHostStorage)
    let capture = try XCTUnwrap(
      descriptor.steps.firstIndex { $0.stepID == "capture-screen-sequence" })
    XCTAssertLessThan(
      0, capture,
      "nothing may reach the device before the store has said it can hold the result")
  }

  /// A run whose result the store could never publish is refused, and the
  /// device is never touched.
  func testARunThatCannotBePublishedNeverReachesTheDevice() async throws {
    let witness = WitnessDispatcher()
    let engine = try engine(quotaBytes: 1 << 20, dispatcher: witness)
    let submitted = try await engine.submit(try request(frames: 300, budget: 64 << 20))
    let terminal = try await engine.run(jobID: submitted.jobID)
    XCTAssertEqual(terminal.state, "failed")
    let reached = await witness.dispatched()
    XCTAssertTrue(
      reached.isEmpty,
      "the device saw \(reached) after a refusal that must precede it")
  }

  /// The refusal says how much was asked for and how much is left, because
  /// "no room" that names no number cannot be acted on.
  func testTheRefusalNamesTheNumbers() async throws {
    let store = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "named", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: 1000), nowUTC: { "2026-08-26T12:00:00Z" })
    do {
      try await store.preflightAdditionalBytes(4096)
      XCTFail("4096 bytes cannot fit in a 1000-byte store")
    } catch let error as RuntimeArtifactError {
      guard case .quotaExceeded(let requested, let remaining) = error else {
        return XCTFail("expected quotaExceeded, got \(error)")
      }
      XCTAssertEqual(requested, 4096)
      XCTAssertEqual(remaining, 1000)
    }
  }

  /// Refuse, never evict. A full store does not make room by discarding what
  /// somebody already captured - the recording they still have is worth more
  /// than the one they are asking for.
  func testAFullStoreRefusesRatherThanDiscardingWhatIsAlreadyThere() async throws {
    let store = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "full", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: 4096), nowUTC: { "2026-08-26T12:00:00Z" })
    let existing = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-earlier", sessionID: "session-earlier", stepID: "receive-screen-sequence",
        name: "frames.tar", mediaType: "application/x-tar",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "capture.screen-sequence", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 1,
          stableIdentitySHA256: String(repeating: "a", count: 64)),
        contents: Data(repeating: 7, count: 3000)))

    var refused = false
    do { try await store.preflightAdditionalBytes(3000) } catch { refused = true }
    XCTAssertTrue(refused, "3000 more bytes cannot fit beside 3000 already used in 4096")
    let stillThere = try await store.list(jobID: "job-earlier")
    XCTAssertEqual(stillThere.count, 1)
    XCTAssertEqual(stillThere.first?.artifactID, existing.artifactID)
    let used = try await store.totalBytesUsed()
    XCTAssertEqual(used, 3000, "nothing was evicted to make room for what was refused")
  }

  // MARK: - The workspace's own preflight

  /// The number the workspace checks must be the number the runtime checks.
  ///
  /// The operation's host storage preflight reads `totalArtifactByteBudget`
  /// straight off the request. A workspace that estimated its own figure and
  /// sent a different one would have two answers to one question: it could
  /// pass its own check and still be refused, which is the outcome this whole
  /// gap exists to prevent.
  func testTheWorkspaceSendsTheSameBudgetItPreflighted() throws {
    let target = DeviceTargetPresentation(
      id: "TGT-1", bindingRevision: 1, displayName: "DAYU200")
    for frames in [2, 40, 120, 300] {
      let request = try DeviceControlFacade.recordingRequest(
        frameCount: frames, target: target, nonce: "n")
      guard case .integer(let sent)? = request.inputs["totalArtifactByteBudget"] else {
        return XCTFail("a recording request must carry the budget it preflighted")
      }
      XCTAssertEqual(
        Int(sent), DeviceRecordingBudget.bytes(frameCount: frames),
        "\(frames) frames: the workspace preflighted one number and sent another")
    }
  }

  /// And that number has to be one the runtime's own preflight will accept as
  /// a request at all - the catalog floors it at a mebibyte.
  func testTheBudgetStaysInsideTheCatalogSBounds() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.screen-sequence@1"))
    let field = try XCTUnwrap(
      descriptor.inputs.first { $0.name == "totalArtifactByteBudget" })
    for frames in [2, 300] {
      let budget = DeviceRecordingBudget.bytes(frameCount: frames)
      if let minimum = field.minimum {
        XCTAssertGreaterThanOrEqual(budget, minimum, "\(frames) frames")
      }
      if let maximum = field.maximum {
        XCTAssertLessThanOrEqual(budget, maximum, "\(frames) frames")
      }
    }
  }

  /// The estimate must not undershoot what a run really publishes.
  ///
  /// Two runs measured on hardware on 2026-08-26: 20 frames came back as an
  /// 851,456-byte archive, 120 frames as 5,059,584. The 120-frame figure is
  /// the one that matters here - at 20 frames the mebibyte floor dominates and
  /// would hide an estimate that had drifted low.
  func testTheEstimateCoversWhatMeasuredRunsActuallyProduced() {
    XCTAssertGreaterThan(
      DeviceRecordingBudget.bytes(frameCount: 20), 851_456,
      "under-estimating lets a run start that the runtime will refuse")
    XCTAssertGreaterThan(
      DeviceRecordingBudget.bytes(frameCount: 120), 5_059_584,
      "the 120-frame measurement is above the floor, so this is the estimate "
        + "itself rather than the floor standing in for it")
    XCTAssertGreaterThan(
      DeviceRecordingBudget.bytes(frameCount: 120), 1 << 20,
      "if the floor still dominated at this length, neither assertion above "
        + "would be measuring the estimate")
  }

  /// A refusal names both numbers and offers the longest run that would fit,
  /// because "no room" that offers nothing cannot be acted on.
  func testARefusalNamesBothNumbersAndOffersARunThatFits() throws {
    let remaining = DeviceRecordingBudget.bytes(frameCount: 30)
    let refusal = try XCTUnwrap(
      DeviceRecordingBudget.refusal(frameCount: 200, remainingBytes: remaining))
    XCTAssertEqual(refusal.remainingBytes, remaining)
    XCTAssertEqual(refusal.neededBytes, DeviceRecordingBudget.bytes(frameCount: 200))
    XCTAssertGreaterThanOrEqual(refusal.framesThatWouldFit, 2)
    XCTAssertLessThanOrEqual(
      DeviceRecordingBudget.bytes(frameCount: refusal.framesThatWouldFit), remaining,
      "the run it offers has to actually fit")
    XCTAssertGreaterThan(
      DeviceRecordingBudget.bytes(frameCount: refusal.framesThatWouldFit + 1), remaining,
      "and it has to be the longest one that does")
  }

  /// A run that fits is not refused. A preflight that fired on everything
  /// would be worse than none.
  func testARunThatFitsIsNotRefused() {
    XCTAssertNil(
      DeviceRecordingBudget.refusal(
        frameCount: 40, remainingBytes: DeviceRecordingBudget.bytes(frameCount: 40)))
    XCTAssertNil(DeviceRecordingBudget.refusal(frameCount: 300, remainingBytes: 1 << 30))
  }

  /// An empty store offers nothing, and says so rather than offering a run of
  /// zero frames that the operation would refuse as out of bounds anyway.
  func testAStoreWithNoRoomOffersNoRun() throws {
    let refusal = try XCTUnwrap(
      DeviceRecordingBudget.refusal(frameCount: 40, remainingBytes: 0))
    XCTAssertEqual(refusal.framesThatWouldFit, 0)
  }

private struct QuotaFactsPort: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f",
      toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
      targetID: targetID, bindingRevision: 1,
      deviceIdentitySHA256: String(repeating: "a", count: 64),
      executionConnectKey: "150100424a544e4600",
      deviceMode: nil, buildFingerprint: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: "2026-08-26T12:00:00Z")
  }
}
}

/// Records whether anything reached a device at all.
private actor WitnessDispatcher: RuntimeProcessDispatching {
  private var seen: [String] = []

  func dispatched() -> [String] { seen }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    seen.append("\(plan.action)")
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 0)
  }
}
