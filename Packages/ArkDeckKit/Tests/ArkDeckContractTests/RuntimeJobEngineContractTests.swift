import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeJobEngineContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-engine-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        deviceIdentitySHA256: nil, deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  /// Counting dispatcher with per-action scripted receipts.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    enum Script {
      case observationHappy
      case outcomeUnknownOnDeviceProbe
    }

    private let script: Script
    private let lock = NSLock()
    private(set) var dispatchCount = 0

    init(script: Script) {
      self.script = script
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      lock.withLock { dispatchCount += 1 }
      switch (script, plan.action) {
      case (.outcomeUnknownOnDeviceProbe, .hdc(.observeDevice)):
        throw RuntimeDispatchFailure.outcomeUnknown("dispatcher lost the child process")
      case (_, .hdc(.observeTool)), (_, .hdc(.observeServer)):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.observeDevice)), (_, .hdc(.listDeviceCandidates)):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("[Empty]\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      default:
        throw RuntimeDispatchFailure.failed("unscripted action")
      }
    }
  }

  private func makeEngine(
    dispatcher: ScriptedDispatcher
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    return (engine, capabilityStore)
  }

  private func observeRequest(
    idempotencyKey: String = "idem-observe-0001", requestID: String = "req-1"
  ) -> Data {
    Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "\(requestID)",
        "idempotencyKey": "\(idempotencyKey)",
        "target": { "targetId": "TGT-DAYU200-01" },
        "operation": { "id": "observe.device", "version": 1 }
      }
      """.utf8)
  }

  // MARK: - Happy path + timeline

  func testObserveDeviceHappyPathProducesFullTimeline() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(observeRequest())
    XCTAssertFalse(acceptance.deduplicated)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, 3, "three provider-dispatched probe steps")
    XCTAssertTrue(status.timeline.contains("jobCreated"))
    XCTAssertTrue(status.timeline.contains("queued->preflight"))
    XCTAssertTrue(status.timeline.contains("intent probe-host-tool"))
    XCTAssertTrue(status.timeline.contains { $0.hasPrefix("verified probe-device") })
    XCTAssertTrue(status.timeline.contains("running->finalizing"))
    XCTAssertTrue(status.timeline.contains("finalizing->succeeded"))
    // The journal itself carries the intents: replay sees a clean history.
    let journalURL = stateDirectory
      .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl")
    let inspection = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertTrue(inspection.outstandingIntents.isEmpty)
    XCTAssertTrue(inspection.unknownOutcomes.isEmpty)
  }

  // MARK: - Idempotency

  func testIdempotencyKeyDedupesDurably() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let first = try await engine.submit(observeRequest())
    let duplicate = try await engine.submit(observeRequest())
    XCTAssertTrue(duplicate.deduplicated)
    XCTAssertEqual(duplicate.jobID, first.jobID)

    // Same key, drifted request: conflict, never a silent overwrite.
    do {
      _ = try await engine.submit(
        observeRequest(idempotencyKey: "idem-observe-0001", requestID: "req-2"))
      XCTFail("drifted idempotency reuse must conflict")
    } catch let error as RuntimeJobEngineError {
      guard case .idempotencyConflict = error else {
        return XCTFail("expected idempotencyConflict, got \(error)")
      }
    }

    // The ledger is durable: a NEW engine over the same state dedupes too.
    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let afterRestart = try await reopened.submit(observeRequest())
    XCTAssertTrue(afterRestart.deduplicated)
    XCTAssertEqual(afterRestart.jobID, first.jobID)
  }

  // MARK: - Authorization

  func testMutationWithoutCapabilityIsRejectedAndE1CapabilityAdmits() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let hapRequest = Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-hap",
        "idempotencyKey": "idem-hap-0001",
        "target": { "targetId": "TGT-DAYU200-01" },
        "operation": { "id": "debug.hap", "version": 1 },
        "inputs": {
          "hapArtifactLease": "lease-1",
          "bundleName": "com.example.demo",
          "abilityName": "EntryAbility"
        },
        "authorization": { "capabilityId": "CAP-RT-ENGINE-001" }
      }
      """.utf8)
    // No such capability installed: authorizationRequired.
    do {
      _ = try await engine.submit(hapRequest)
      XCTFail("mutation without an installed capability must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, _) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
    }
    // Install a matching E1 capability: submit is admitted (no taskID anywhere).
    try await capabilityStore.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-ENGINE-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
    let acceptance = try await engine.submit(hapRequest)
    XCTAssertFalse(acceptance.deduplicated)
    let status = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "preflight")
    // A use was consumed atomically at admission.
    let capabilityStatus = try await capabilityStore.inspect(capabilityID: "CAP-RT-ENGINE-001")
    XCTAssertEqual(capabilityStatus?.remainingUses, 4)
  }

  func testMissingRequiredInputIsRejected() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let bad = Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-bad",
        "idempotencyKey": "idem-bad-0001",
        "target": { "targetId": "TGT-1" },
        "operation": { "id": "capture.diagnostics", "version": 1 }
      }
      """.utf8)
    do {
      _ = try await engine.submit(bad)
      XCTFail("missing durationSeconds must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("durationSeconds"))
    }
  }

  func testUnknownOperationIsRejected() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let unknown = Data(
      String(decoding: observeRequest(), as: UTF8.self)
        .replacingOccurrences(of: "observe.device", with: "observe.galaxy").utf8)
    do {
      _ = try await engine.submit(unknown)
      XCTFail("unknown operation must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.unknownOperation, _) = error else {
        return XCTFail("expected unknownOperation, got \(error)")
      }
    }
  }

  // MARK: - Unknown outcome and reconcile

  func testOutcomeUnknownParksAndReconcileClears() async throws {
    let dispatcher = ScriptedDispatcher(script: .outcomeUnknownOnDeviceProbe)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(observeRequest(idempotencyKey: "idem-unknown-01"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "waitingForRecovery")
    XCTAssertTrue(status.outcomeUnknown)
    XCTAssertTrue(status.waitingForHuman)
    let dispatchesAtPark = dispatcher.dispatchCount

    // No automatic replay: status queries do not redispatch.
    _ = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAtPark)

    // Reconcile through the provider (read-only family: safely resolvable).
    let reconciled = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAtPark, "reconcile never redispatches")
  }

  // MARK: - Cancel

  func testCancelLandsAtSafeBoundary() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(observeRequest(idempotencyKey: "idem-cancel-01"))
    try await engine.requestCancel(jobID: acceptance.jobID)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "cancelled")
    XCTAssertTrue(status.timeline.contains("cancelRequested->cancellingAtSafeBoundary"))
  }

  // MARK: - Crash windows (process-level fixture)

  func testCrashWindowsPreserveUnknownOutcomeAndNeverRedispatch() async throws {
    let fixtureURL = productsDirectory.appendingPathComponent("ArkDeckEngineCrashFixture")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
      throw XCTSkip("ArkDeckEngineCrashFixture binary not built")
    }
    for window in ["afterIntentBeforeDispatch", "afterDispatchBeforeOutcome"] {
      let directory = stateDirectory.appendingPathComponent(window, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let process = Process()
      process.executableURL = fixtureURL
      process.arguments = [window, directory.path]
      try process.run()
      let ready = directory.appendingPathComponent("ready")
      let deadline = Date().addingTimeInterval(30)
      while !FileManager.default.fileExists(atPath: ready.path) {
        if Date() > deadline {
          process.terminate()
          return XCTFail("\(window): fixture never became ready")
        }
        usleep(50_000)
      }
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()

      let effectMarker = directory.appendingPathComponent("external-effect-marker")
      let markerExists = FileManager.default.fileExists(atPath: effectMarker.path)
      XCTAssertEqual(
        markerExists, window == "afterDispatchBeforeOutcome",
        "\(window): effect marker must reflect the crash window exactly")

      // Recovery in this process over the fixture's state: parked, no redispatch.
      let capabilityStore = try RuntimeCapabilityStore(
        directoryURL: directory.appendingPathComponent("capabilities", isDirectory: true))
      let dispatcher = ScriptedDispatcher(script: .observationHappy)
      let engine = try RuntimeJobEngine(
        configuration: .init(stateDirectory: directory.appendingPathComponent("engine-state")),
        providers: DeviceProviderRegistry(providers: [
          HDCObservationProviderAdapter(factsPort: FactsPort())
        ]),
        dispatcher: dispatcher,
        capabilityStore: capabilityStore,
        nowUTC: { "2026-07-29T01:00:00Z" })
      let recovered = try await engine.recoverPersistedJobs()
      XCTAssertEqual(recovered.count, 1, "\(window): one persisted job must be recovered")
      XCTAssertEqual(recovered[0].state, "waitingForRecovery", window)
      XCTAssertTrue(recovered[0].outcomeUnknown, window)
      XCTAssertEqual(dispatcher.dispatchCount, 0, "\(window): recovery must never redispatch")
      XCTAssertEqual(
        markerExists, FileManager.default.fileExists(atPath: effectMarker.path),
        "\(window): recovery must not create or remove external effects")
    }
  }



  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }
}
