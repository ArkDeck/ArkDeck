import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeJobEngineContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var artifactStore: RuntimeArtifactStore!

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
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
        executionConnectKey: String(repeating: "a", count: 32),
        deviceModel: nil, deviceMode: "hdc",
        buildFingerprint: nil, transport: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z",
        sourceObservedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  /// Counting dispatcher with per-action scripted receipts.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    enum Script {
      case observationHappy
      case outcomeUnknownOnDeviceProbe
      case outcomeUnknownOnHAPSend
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
      case (.outcomeUnknownOnHAPSend, .hdc(.sendArtifactToStaging)):
        throw RuntimeDispatchFailure.outcomeUnknown(
          "dispatcher lost the HAP send child process")
      case (_, .hdc(.observeTool)):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.observeServer)):
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.observeDevice)), (_, .hdc(.listDeviceCandidates)):
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.queryProperty(.productModel))):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("DAYU200\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.queryProperty(.fullBuildVersion))):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("OpenHarmony-4.1-release\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      default:
        throw RuntimeDispatchFailure.failed("unscripted action")
      }
    }
  }

  private func makeEngine(
    dispatcher: ScriptedDispatcher,
    nowUTC: String = "2026-07-29T00:00:00Z"
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { nowUTC })
    self.artifactStore = artifactStore
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { nowUTC })
    return (engine, capabilityStore)
  }

  private func observeRequest(
    idempotencyKey: String = "idem-observe-0001", requestID: String = "req-1"
  ) -> Data {
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "\(requestID)",
        "idempotencyKey": "\(idempotencyKey)",
        "target": { "targetId": "TGT-DAYU200-01", "expectedBindingRevision": 7 },
        "operation": { "id": "observe.device", "version": 1 }
      }
      """.utf8)
  }

  private func publishHAPLease() async throws -> String {
    let hapArtifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap",
        stepID: "publish-hap", name: "demo.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-01", bindingRevision: 1,
          stableIdentitySHA256: nil),
        contents: Data("signed-hap-fixture".utf8)))
    return try await artifactStore.leaseReference(
      jobID: hapArtifact.jobID, artifactID: hapArtifact.artifactID)
  }

  private func hapRequest(
    lease: String,
    requestID: String,
    idempotencyKey: String,
    capabilityID: String? = nil
  ) -> Data {
    let authorization =
      capabilityID.map {
        """
        ,
        "authorization": { "capabilityId": "\($0)" }
        """
      } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "\(requestID)",
        "idempotencyKey": "\(idempotencyKey)",
        "target": {
          "targetId": "TGT-DAYU200-01",
          "expectedBindingRevision": 7
        },
        "operation": { "id": "debug.hap", "version": 1 },
        "inputs": {
          "hapArtifactLease": "\(lease)",
          "bundleName": "com.example.demo",
          "abilityName": "EntryAbility"
        }\(authorization)
      }
      """.utf8)
  }

  private func installHAPCapability(
    _ store: RuntimeCapabilityStore,
    capabilityID: String,
    maximumUses: Int
  ) async throws {
    try await store.install(
      try RuntimeCapability(
        capabilityID: capabilityID,
        targetScope: .stablePhysicalIdentity(
          sha256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"),
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: maximumUses,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
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
    XCTAssertEqual(dispatcher.dispatchCount, 5, "three evidence preflight steps are dispatched")
    XCTAssertTrue(status.timeline.contains("jobCreated"))
    XCTAssertTrue(status.timeline.contains("queued->preflight"))
    XCTAssertTrue(status.timeline.contains("intent probe-host-tool"))
    XCTAssertTrue(status.timeline.contains { $0.hasPrefix("verified confirm-evidence-target") })
    XCTAssertTrue(status.timeline.contains("running->finalizing"))
    XCTAssertTrue(status.timeline.contains("finalizing->succeeded"))
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.actualEffect, "readOnly")
    XCTAssertEqual(evidence.authority?.kind, .defaultReadOnlyPolicy)
    XCTAssertEqual(evidence.authority?.reference, "default-read-only-policy")
    XCTAssertEqual(evidence.observation?.bindingRevision, 7)
    XCTAssertEqual(evidence.observation?.model, "DAYU200")
    XCTAssertEqual(evidence.observation?.firmware, "OpenHarmony-4.1-release")
    XCTAssertTrue(evidence.actualStepKinds.contains("probeDevice"))
    XCTAssertNotNil(evidence.startedAtUTC)
    XCTAssertNotNil(evidence.finishedAtUTC)
    // The journal itself carries the intents: replay sees a clean history.
    let journalURL =
      stateDirectory
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

  func testMutationWithoutAuthorizationGetsDurableAutomaticE1Capability() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease()
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-auto",
        idempotencyKey: "idem-hap-auto-0001"))

    XCTAssertEqual(dispatcher.dispatchCount, 0, "submit materializes but never dispatches")
    let submittedStatus = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(submittedStatus.state, "preflight")
    let statuses = try await capabilityStore.list()
    XCTAssertEqual(statuses.count, 1)
    let status = try XCTUnwrap(statuses.first)
    XCTAssertTrue(status.capability.capabilityID.hasPrefix("CAP-RT-POLICY-"))
    XCTAssertEqual(status.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(status.capability.effectCeiling, .deviceMutation)
    XCTAssertEqual(status.capability.exactBindingRevision, 7)
    XCTAssertEqual(
      status.capability.exactInputs,
      [
        "hapArtifactLease": .string(lease),
        "bundleName": .string("com.example.demo"),
        "abilityName": .string("EntryAbility"),
      ])
    XCTAssertEqual(status.remainingUses, 10_000)
    XCTAssertEqual(status.consumptionCount, 0)

    let record = try RuntimeJobRecord.load(
      from: stateDirectory.appendingPathComponent(
        "jobs/\(acceptance.jobID)", isDirectory: true))
    XCTAssertEqual(
      record.request.authorization?.capabilityID,
      status.capability.capabilityID,
      "the daemon-owned reference must survive restart in the persisted typed request")
  }

  func testAutomaticE1CapabilityRenewsWithoutHumanAuthorization() async throws {
    let (firstEngine, firstStore) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy),
      nowUTC: "2026-07-29T00:00:00Z")
    let lease = try await publishHAPLease()
    _ = try await firstEngine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-auto-renew-1",
        idempotencyKey: "idem-hap-auto-renew-1"))
    let firstStatuses = try await firstStore.list()
    XCTAssertEqual(firstStatuses.map(\.capability.capabilityID).count, 1)
    XCTAssertEqual(
      firstStatuses.first?.capability.expiresAtUTC,
      "2026-08-28T00:00:00Z")

    let (renewedEngine, renewedStore) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy),
      nowUTC: "2026-09-01T00:00:00Z")
    _ = try await renewedEngine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-auto-renew-2",
        idempotencyKey: "idem-hap-auto-renew-2"))
    let renewedStatuses = try await renewedStore.list()
    XCTAssertEqual(renewedStatuses.count, 2)
    XCTAssertEqual(
      renewedStatuses.map(\.capability.issuer.kind),
      [.runtimeDefaultPolicy, .runtimeDefaultPolicy])
    XCTAssertTrue(
      renewedStatuses.contains {
        $0.capability.capabilityID.hasSuffix("-G2")
          && $0.capability.issuedAtUTC == "2026-09-01T00:00:00Z"
      })
  }

  func testExplicitMissingCapabilityIsRejectedAndE1CapabilityAdmits() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let hapArtifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap",
        stepID: "publish-hap", name: "demo.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-01", bindingRevision: 1,
          stableIdentitySHA256: nil),
        contents: Data("signed-hap-fixture".utf8)))
    let lease = try await artifactStore.leaseReference(
      jobID: hapArtifact.jobID, artifactID: hapArtifact.artifactID)
    let hapRequest = Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-hap",
        "idempotencyKey": "idem-hap-0001",
        "target": {
          "targetId": "TGT-DAYU200-01",
          "expectedBindingRevision": 7
        },
        "operation": { "id": "debug.hap", "version": 1 },
        "inputs": {
          "hapArtifactLease": "\(lease)",
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
    // Install a matching E1 capability: submit is admitted (no taskID
    // anywhere), but the use is deferred until journaled target preflight
    // completes and the first mutation is ready to dispatch.
    try await capabilityStore.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-ENGINE-001",
        targetScope: .stablePhysicalIdentity(
          sha256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"),
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
    let beforeRun = try await capabilityStore.inspect(capabilityID: "CAP-RT-ENGINE-001")
    XCTAssertEqual(beforeRun?.remainingUses, 5)
    let beforeEvidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertNil(beforeEvidence.authority)

    _ = try await engine.run(jobID: acceptance.jobID)
    let afterRun = try await capabilityStore.inspect(capabilityID: "CAP-RT-ENGINE-001")
    XCTAssertEqual(afterRun?.remainingUses, 4)
    XCTAssertEqual(afterRun?.lineage.first?.outcome, .confirmed)
    XCTAssertTrue(afterRun?.lineageAllowsNewExecution == true)
    let afterEvidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertNotNil(afterEvidence.authority?.consumptionFingerprintSHA256)

    // A different execution ID of the same typed plan reuses the reviewed
    // envelope. Its real Job-owned remote path differs, while the
    // authorization plan template digest remains stable.
    let secondRequest = Data(
      String(decoding: hapRequest, as: UTF8.self)
        .replacingOccurrences(of: "\"req-hap\"", with: "\"req-hap-2\"")
        .replacingOccurrences(
          of: "\"idem-hap-0001\"", with: "\"idem-hap-0002\"").utf8)
    let second = try await engine.submit(secondRequest)
    _ = try await engine.run(jobID: second.jobID)
    let afterSecond = try await capabilityStore.inspect(
      capabilityID: "CAP-RT-ENGINE-001")
    XCTAssertEqual(afterSecond?.remainingUses, 3)
    XCTAssertEqual(afterSecond?.lineage.map(\.ordinal), [1, 2])
    XCTAssertEqual(
      afterSecond?.lineage[1].previousLineageSHA256,
      afterSecond?.lineage[0].lineageTipSHA256)
  }

  func testMutationOutcomeUnknownBlocksNewExecutionAcrossDaemonRecovery() async throws {
    let dispatcher = ScriptedDispatcher(script: .outcomeUnknownOnHAPSend)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease()
    let firstRequest = hapRequest(
      lease: lease, requestID: "req-hap-unknown-1",
      idempotencyKey: "idem-hap-unknown-1")
    let first = try await engine.submit(firstRequest)
    let automaticStatuses = try await capabilityStore.list()
    let automaticCapabilityID = try XCTUnwrap(
      automaticStatuses.first?.capability.capabilityID)
    let parked = try await engine.run(jobID: first.jobID)
    XCTAssertTrue(parked.outcomeUnknown)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    let dispatchCountAtPark = dispatcher.dispatchCount
    let lineage = try await capabilityStore.inspect(
      capabilityID: automaticCapabilityID)
    XCTAssertEqual(lineage?.lineage.first?.outcome, .outcomeUnknown)
    XCTAssertEqual(lineage?.remainingUses, 9_999)

    let secondRequest = Data(
      String(
        decoding: hapRequest(
          lease: lease, requestID: "req-hap-unknown-2",
          idempotencyKey: "idem-hap-unknown-2"),
        as: UTF8.self
      ).replacingOccurrences(
        of: "com.example.demo",
        with: "com.example.changed"
      ).utf8)
    do {
      _ = try await engine.submit(secondRequest)
      XCTFail("outcomeUnknown must block a new Job before dispatch")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, let detail) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
      XCTAssertTrue(detail.contains("outcomeUnknown"))
    }
    XCTAssertEqual(dispatcher.dispatchCount, dispatchCountAtPark)

    let recoveredDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (recoveredEngine, recoveredStore) = try makeEngine(
      dispatcher: recoveredDispatcher)
    let recovered = try await recoveredEngine.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.jobID), [first.jobID])
    XCTAssertTrue(try XCTUnwrap(recovered.first).outcomeUnknown)
    do {
      _ = try await recoveredEngine.submit(secondRequest)
      XCTFail("restart must preserve the unknown-outcome lineage block")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, _) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
    }
    XCTAssertEqual(recoveredDispatcher.dispatchCount, 0)
    let recoveredCapability = try await recoveredStore.inspect(
      capabilityID: automaticCapabilityID)
    XCTAssertEqual(recoveredCapability?.remainingUses, 9_999)
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

  func testCleanCrashResumesAfterLastConfirmedTypedProviderAction() async throws {
    let originalDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (original, _) = try makeEngine(dispatcher: originalDispatcher)
    let acceptance = try await original.submit(
      observeRequest(idempotencyKey: "idem-clean-resume-01"))
    let completed = try await original.run(jobID: acceptance.jobID)
    XCTAssertEqual(completed.state, "succeeded")

    // Recreate the exact durable bytes of a process loss immediately
    // after the last provider outcome, before running->finalizing.
    let journalURL =
      stateDirectory
      .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl")
    let fullReplay = try DurableJournalRecovery.inspect(url: journalURL)
    let boundary = try XCTUnwrap(
      fullReplay.events.last {
        $0.kind == .stepOutcome && $0.stepID == "read-evidence-firmware"
      }?.sequence)
    let lines = try String(contentsOf: journalURL, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
    let durablePrefix = lines.prefix(boundary + 1).joined(separator: "\n") + "\n"
    try Data(durablePrefix.utf8).write(to: journalURL)

    let resumedDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (recoveredEngine, _) = try makeEngine(dispatcher: resumedDispatcher)
    let recovered = try await recoveredEngine.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.state), ["running"])
    XCTAssertFalse(try XCTUnwrap(recovered.first).outcomeUnknown)

    let resumed = try await recoveredEngine.run(jobID: acceptance.jobID)
    XCTAssertEqual(resumed.state, "succeeded", resumed.timeline.joined(separator: " | "))
    XCTAssertEqual(
      resumedDispatcher.dispatchCount, 0,
      "journal-confirmed typed provider actions must not be dispatched again")
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
