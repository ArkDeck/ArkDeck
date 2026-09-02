import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeJobEngineContractTests: XCTestCase {
  func testFlashArchiveProfileCacheReadsOneExactLeaseOnlyOnce() throws {
    let board = RockchipFlashProfile.dayu200
    let first = ProviderResolvedInputArtifact(
      artifactID: "ART-flash",
      fileURL: URL(filePath: "/tmp/arkdeck-flash.imgs"),
      sha256: board.archiveSHA256,
      byteCount: Int(board.archiveSizeBytes))
    var cache = RuntimeFlashArchiveProfileCache()
    var reads = 0

    let initial = try cache.resolve(
      artifactLeaseID: "lease-v1:import:ART-flash", artifact: first, board: board
    ) {
      reads += 1
      return board
    }
    let repeated = try cache.resolve(
      artifactLeaseID: "lease-v1:import:ART-flash", artifact: first, board: board
    ) {
      reads += 1
      XCTFail("an exact lease cache hit must not describe the archive again")
      return board
    }

    XCTAssertEqual(initial.runtimeBuildVersion, board.runtimeBuildVersion)
    XCTAssertEqual(repeated.archiveSHA256, initial.archiveSHA256)
    XCTAssertEqual(reads, 1)

    let refreshed = try cache.resolve(
      artifactLeaseID: "lease-v1:replacement:ART-flash",
      artifact: first, board: board
    ) {
      reads += 1
      return board
    }
    XCTAssertEqual(refreshed.archiveSHA256, board.archiveSHA256)
    XCTAssertEqual(reads, 2)
  }

  func testFlashArchiveProfileCacheNeverStoresLeaseDrift() {
    let board = RockchipFlashProfile.dayu200
    let artifact = ProviderResolvedInputArtifact(
      artifactID: "ART-invalid-flash",
      fileURL: URL(filePath: "/tmp/invalid-flash.imgs"),
      sha256: String(repeating: "c", count: 64),
      byteCount: 64)
    var cache = RuntimeFlashArchiveProfileCache()
    var reads = 0

    for _ in 0..<2 {
      XCTAssertThrowsError(
        try cache.resolve(
          artifactLeaseID: "lease-v1:import:ART-invalid-flash",
          artifact: artifact, board: board
        ) {
          reads += 1
          return board
        }
      ) { error in
        guard case RuntimeDispatchFailure.failed(let detail) = error else {
          return XCTFail("expected definite exact-lease refusal, got \(error)")
        }
        XCTAssertTrue(detail.contains("drifted from its exact Artifact lease"), detail)
      }
    }
    XCTAssertEqual(reads, 2, "a drifted profile must never become a reusable cache entry")
  }

  private var stateDirectory: URL!
  private var artifactStore: RuntimeArtifactStore!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-engine-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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

  private actor BlockingFactsPort: HDCObservationFactsPort {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      if !reached {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
          await withCheckedContinuation { releaseWaiters.append($0) }
        }
      }
      return try await FactsPort().currentFacts(targetID: targetID)
    }

    func waitUntilReached() async {
      if reached { return }
      await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
      released = true
      let waiters = releaseWaiters
      releaseWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  /// Counting dispatcher with per-action scripted receipts.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    enum Script {
      case observationHappy
      case knownFailureOnDeviceProbe
      case outcomeUnknownOnDeviceProbe
      case outcomeUnknownOnHAPSend
    }

    private let script: Script
    private let beforeDispatch: (@Sendable () -> Void)?
    private let lock = NSLock()
    private(set) var dispatchCount = 0

    init(script: Script, beforeDispatch: (@Sendable () -> Void)? = nil) {
      self.script = script
      self.beforeDispatch = beforeDispatch
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      beforeDispatch?()
      lock.withLock { dispatchCount += 1 }
      switch (script, plan.action) {
      case (.knownFailureOnDeviceProbe, .hdc(.observeDevice)):
        throw RuntimeDispatchFailure.failed("new pre-effect product failure")
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
      case (_, .hdc(.queryProperty(.productName))):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("OpenHarmony Reference Device\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.queryProperty(.fullBuildVersion))):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("OpenHarmony-4.1-release\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case (_, .hdc(.readOwnedPathPresence)):
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("ls: /data/local/tmp/arkdeck/missing: No such file or directory\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
      default:
        throw RuntimeDispatchFailure.failed("unscripted action")
      }
    }
  }

  private final class BlockingHAPSendDispatcher:
    RuntimeProcessDispatching, @unchecked Sendable
  {
    private let delegate = ScriptedDispatcher(script: .observationHappy)
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Never>?

    var observedCancellation: Bool { lock.withLock { cancelled } }

    func waitUntilStarted() async {
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock { () -> Bool in
          if started { return true }
          startWaiters.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }

    func release() {
      let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        released = true
        defer { operationContinuation = nil }
        return operationContinuation
      }
      continuation?.resume()
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      guard case .hdc(.sendArtifactToStaging) = plan.action else {
        return try await delegate.dispatch(plan)
      }
      let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        started = true
        let captured = startWaiters
        startWaiters.removeAll()
        return captured
      }
      waiters.forEach { $0.resume() }
      try await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let resumeNow = lock.withLock { () -> Bool in
            if released || cancelled { return true }
            operationContinuation = continuation
            return false
          }
          if resumeNow { continuation.resume() }
        }
        try Task.checkCancellation()
      } onCancel: {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
          self.cancelled = true
          defer { self.operationContinuation = nil }
          return self.operationContinuation
        }
        continuation?.resume()
      }
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    }
  }

  private actor EngineAsyncBarrier {
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitAtBoundary() async {
      reached = true
      let waiters = reachedWaiters
      reachedWaiters.removeAll()
      waiters.forEach { $0.resume() }
      if released { return }
      await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilReached() async {
      if reached { return }
      await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
      released = true
      let waiters = releaseWaiters
      releaseWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0

    func nowUTC() -> String {
      lock.withLock {
        defer { tick += 1 }
        return String(format: "2026-07-29T00:00:%02dZ", min(tick, 59))
      }
    }

    var callCount: Int {
      lock.withLock { tick }
    }
  }

  private func makeEngine(
    dispatcher: any RuntimeProcessDispatching,
    factsPort: any HDCObservationFactsPort = FactsPort(),
    nowUTC: String = "2026-07-29T00:00:00Z",
    engineNowUTC: (@Sendable () -> String)? = nil,
    admissionFaultInjector: RuntimeAdmissionFaultInjector = .none,
    powerActivityController: PowerActivityController? = nil,
    stateRoot: URL? = nil,
    testHooks: RuntimeJobEngine.Configuration.TestHooks = .none
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore) {
    let stateRoot = stateRoot ?? self.stateDirectory!
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateRoot.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateRoot.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { nowUTC })
    self.artifactStore = artifactStore
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateRoot,
        admissionFaultInjector: admissionFaultInjector,
        testHooks: testHooks),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: factsPort)
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      powerActivityController: powerActivityController,
      nowUTC: engineNowUTC ?? { nowUTC })
    return (engine, capabilityStore)
  }

  func testHDCLifecycleInterlockClosesAlreadyMaterializingJobAdmissionRace()
    async throws
  {
    let facts = BlockingFactsPort()
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, _) = try makeEngine(dispatcher: dispatcher, factsPort: facts)
    let request = observeRequest(
      idempotencyKey: "idem-hdc-interlock-race-01",
      requestID: "req-hdc-interlock-race")
    let submitting = Task { try await engine.submit(request) }

    await facts.waitUntilReached()
    let lease = try await engine.acquireHDCLifecycleInterlock()
    await facts.release()
    do {
      _ = try await submitting.value
      XCTFail("materializing Job crossed the final HDC lifecycle interlock")
    } catch RuntimeJobEngineError.rejected(let code, let message) {
      XCTAssertEqual(code, .conflict)
      XCTAssertTrue(message.contains("blocks new Job admission"), message)
    }
    let blockedJobs = try await engine.listJobs()
    XCTAssertTrue(blockedJobs.isEmpty)

    try await engine.releaseHDCLifecycleInterlock(lease)
    let accepted = try await engine.submit(request)
    XCTAssertFalse(accepted.deduplicated)
    let acceptedJobs = try await engine.listJobs()
    XCTAssertEqual(acceptedJobs.map(\.jobID), [accepted.jobID])

    do {
      _ = try await engine.acquireHDCLifecycleInterlock()
      XCTFail("current Job did not block the HDC lifecycle interlock")
    } catch let failure as AgentExecutionControlFailure {
      XCTAssertEqual(failure.code, "factsDrifted")
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testActiveJobOwnsIdleSleepLeaseAcrossDispatchAndEveryTerminal() async throws {
    let backend = EnginePowerActivityBackend()
    let controller = PowerActivityController(backend: backend)
    let observation = LockedPowerObservation()
    let dispatcher = ScriptedDispatcher(
      script: .observationHappy,
      beforeDispatch: {
        observation.record(activeLeaseCount: controller.activeLeaseCount)
      })
    let (engine, _) = try makeEngine(
      dispatcher: dispatcher, powerActivityController: controller)
    let acceptance = try await engine.submit(
      observeRequest(idempotencyKey: "idem-power-success-01"))
    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, JobState.succeeded.rawValue)
    XCTAssertTrue(observation.everyDispatchWasProtected)
    XCTAssertGreaterThan(observation.dispatchCount, 0)
    XCTAssertEqual(backend.beginCount, 1)
    XCTAssertEqual(backend.endCount, 1)
    XCTAssertEqual(controller.activeLeaseCount, 0)

    let unknownBackend = EnginePowerActivityBackend()
    let unknownController = PowerActivityController(backend: unknownBackend)
    let unknownDispatcher = ScriptedDispatcher(script: .outcomeUnknownOnDeviceProbe)
    let unknownRoot = stateDirectory.appending(path: "unknown-power", directoryHint: .isDirectory)
    let (unknownEngine, _) = try makeEngine(
      dispatcher: unknownDispatcher, powerActivityController: unknownController,
      stateRoot: unknownRoot)
    let unknownAcceptance = try await unknownEngine.submit(
      observeRequest(idempotencyKey: "idem-power-unknown-01"))
    let unknown = try await unknownEngine.run(jobID: unknownAcceptance.jobID)
    XCTAssertEqual(unknown.state, JobState.waitingForRecovery.rawValue)
    XCTAssertEqual(unknownBackend.beginCount, 1)
    XCTAssertEqual(unknownBackend.endCount, 1)
    XCTAssertEqual(unknownController.activeLeaseCount, 0)

    let cancelledBackend = EnginePowerActivityBackend()
    let cancelledController = PowerActivityController(backend: cancelledBackend)
    let cancelledDispatcher = ScriptedDispatcher(script: .observationHappy)
    let cancelledRoot = stateDirectory.appending(
      path:
        "cancelled-power", directoryHint: .isDirectory)
    let (cancelledEngine, _) = try makeEngine(
      dispatcher: cancelledDispatcher, powerActivityController: cancelledController,
      stateRoot: cancelledRoot)
    let cancelledAcceptance = try await cancelledEngine.submit(
      observeRequest(idempotencyKey: "idem-power-cancelled-01"))
    try await cancelledEngine.requestCancel(jobID: cancelledAcceptance.jobID)
    let cancelled = try await cancelledEngine.status(jobID: cancelledAcceptance.jobID)
    XCTAssertEqual(cancelled.state, JobState.cancelled.rawValue)
    XCTAssertEqual(cancelledDispatcher.dispatchCount, 0)
    XCTAssertEqual(cancelledBackend.beginCount, 0)
    XCTAssertEqual(cancelledBackend.endCount, 0)
    XCTAssertEqual(cancelledController.activeLeaseCount, 0)
  }

  func testIdleSleepAssertionFailureLeavesJobAtSafeBoundaryWithZeroDispatch() async throws {
    let backend = EnginePowerActivityBackend()
    backend.failNextBegin = true
    let controller = PowerActivityController(backend: backend)
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, _) = try makeEngine(
      dispatcher: dispatcher, powerActivityController: controller)
    let acceptance = try await engine.submit(
      observeRequest(idempotencyKey: "idem-power-refusal-01"))

    do {
      _ = try await engine.run(jobID: acceptance.jobID)
      XCTFail("a missing idle-sleep assertion must refuse before dispatch")
    } catch let error as RuntimeJobEngineError {
      guard case .jobNotRunnable(let detail) = error else {
        return XCTFail("unexpected Runtime error: \(error)")
      }
      XCTAssertTrue(detail.contains("idle-system-sleep assertion unavailable"))
      XCTAssertTrue(detail.contains("zero dispatch"))
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let refusedStatus = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(refusedStatus.state, JobState.preflight.rawValue)
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.beginAttemptCount, 1)
    XCTAssertEqual(backend.endCount, 0)

    let retried = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(retried.state, JobState.succeeded.rawValue)
    XCTAssertGreaterThan(dispatcher.dispatchCount, 0)
    XCTAssertEqual(backend.beginAttemptCount, 2)
    XCTAssertEqual(backend.beginCount, 1)
    XCTAssertEqual(backend.endCount, 1)
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
          targetID: "TGT-DAYU200-01", bindingRevision: 7,
          stableIdentitySHA256:
            "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"),
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
    XCTAssertEqual(status.executionMode, "execute")
    XCTAssertEqual(status.sessionID, "session-\(acceptance.jobID)")
    XCTAssertEqual(status.actualEffect, "readOnly")
    XCTAssertNotNil(status.createdAtUTC)
    XCTAssertNotNil(status.startedAtUTC)
    XCTAssertNotNil(status.finishedAtUTC)
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
    XCTAssertEqual(evidence.observation?.model, "OpenHarmony Reference Device")
    XCTAssertEqual(evidence.observation?.firmware, "OpenHarmony-4.1-release")
    XCTAssertTrue(evidence.actualStepKinds.contains("probeDevice"))
    XCTAssertNotNil(evidence.startedAtUTC)
    XCTAssertNotNil(evidence.finishedAtUTC)
    // The journal itself carries the intents: replay sees a clean history.
    let journalURL =
      stateDirectory
      .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl")
    let inspection = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertTrue(inspection.outstandingIntents.isEmpty)
    XCTAssertTrue(inspection.unknownOutcomes.isEmpty)
  }

  func testDebugOutcomeUsesDurableEffectIntentInsteadOfFailureVocabulary() async throws {
    let dispatcher = ScriptedDispatcher(script: .knownFailureOnDeviceProbe)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(observeRequest())
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed")

    let outcome = try await engine.runtimeDebugExecutionOutcome(jobID: acceptance.jobID)
    XCTAssertEqual(outcome, .safeToReflash)
    let replay = try DurableJournalRecovery.inspect(
      url: stateDirectory.appending(
        path:
          "jobs/\(acceptance.jobID)/journal.jsonl"))
    XCTAssertFalse(
      replay.events.contains {
        $0.kind == .stepIntent && $0.stepEffect.map { $0 >= .deviceMutation } == true
      },
      "a new known failure is retryable because durable effects are absent, not because its name is listed"
    )
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

  func testIdempotencyKeyCannotAttachAJobFromAnotherCatalogDigest() async throws {
    let request = observeRequest(idempotencyKey: "idem-stale-catalog-0001")
    let (engine, _) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy))
    let accepted = try await engine.submit(request)

    let repository = try RuntimeJobRepository(stateDirectory: stateDirectory)
    let saved = try XCTUnwrap(repository.job(jobID: accepted.jobID))
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(saved.initialRecordData))
        as? [String: Any])
    document["catalogDigest"] = String(repeating: "0", count: 64)
    let staleRecord = try JSONSerialization.data(withJSONObject: document)
    try repository.updateJobState(
      jobID: saved.jobID, state: saved.state,
      updatedAtUTC: saved.updatedAtUTC, recordData: staleRecord)

    let (reopened, _) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy))
    do {
      _ = try await reopened.submit(request)
      XCTFail("an unchanged request must not deduplicate across Catalog digests")
    } catch let error as RuntimeJobEngineError {
      guard case .idempotencyConflict(let message) = error else {
        return XCTFail("expected idempotencyConflict, got \(error)")
      }
      XCTAssertTrue(message.contains("different Catalog digest"))
    }
  }

  func testFreshStateAdmissionCreatesEveryDurableProjectionAndSurvivesRestart() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let accepted = try await engine.submit(observeRequest(idempotencyKey: "idem-fresh-state-01"))
    let jobDirectory =
      stateDirectory
      .appending(path: "jobs/\(accepted.jobID)", directoryHint: .isDirectory)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: jobDirectory.appending(path: "journal.jsonl").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: jobDirectory.appending(path: "job-record.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: stateDirectory.appending(path: RuntimeJobRepository.filename).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: stateDirectory.appending(path: "idempotency.json").path),
      "new Runtime state must not retain JSON as the idempotency authority")

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let recovered = try await reopened.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.jobID), [accepted.jobID])
    let status = try await reopened.status(jobID: accepted.jobID)
    XCTAssertEqual(status.state, "preflight")
  }

  func testPagedJobHistoryReadsSQLiteWithoutReloadingEveryJobIntoMemory() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    var accepted: [RuntimeJobAcceptance] = []
    for index in 1...3 {
      accepted.append(
        try await engine.submit(
          observeRequest(
            idempotencyKey: "idem-history-page-\(index)", requestID: "req-history-page-\(index)")))
    }
    let orderedIDs = accepted.map(\.jobID).sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    let first = try await engine.listJobs(pageSize: 2)
    XCTAssertEqual(first.jobs.map(\.jobID), Array(orderedIDs.prefix(2)))
    XCTAssertNotNil(first.nextCursor)
    let second = try await engine.listJobs(pageSize: 2, cursor: first.nextCursor)
    XCTAssertEqual(second.jobs.map(\.jobID), Array(orderedIDs.suffix(1)))
    XCTAssertNil(second.nextCursor)

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let historical = try await reopened.listJobs(pageSize: 3)
    XCTAssertEqual(historical.jobs.map(\.jobID), orderedIDs)
    let status = try await reopened.status(jobID: accepted[2].jobID)
    XCTAssertEqual(status.state, "preflight")
  }

  func testNewestFirstHistoryKeepsOldCurrentJobsOutsideThePageVisible() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    var accepted: [RuntimeJobAcceptance] = []
    for index in 1...3 {
      accepted.append(
        try await engine.submit(
          observeRequest(
            idempotencyKey: "idem-current-history-\(index)",
            requestID: "req-current-history-\(index)")))
    }
    try await engine.requestCancel(jobID: accepted[2].jobID)
    let orderedIDs = accepted.map(\.jobID).sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }

    let first = try await engine.listJobs(pageSize: 1, newestFirst: true)
    XCTAssertEqual(first.jobs.map(\.jobID), [orderedIDs[0]])
    XCTAssertNotNil(first.nextCursor)
    let second = try await engine.listJobs(
      pageSize: 1, cursor: first.nextCursor, newestFirst: true)
    XCTAssertEqual(second.jobs.map(\.jobID), [orderedIDs[1]])

    let current = try await engine.listCurrentJobs()
    XCTAssertEqual(Set(current.map(\.jobID)), Set(accepted.prefix(2).map(\.jobID)))
    XCTAssertTrue(
      current.contains { $0.jobID == accepted[0].jobID },
      "an older non-terminal Job must not disappear behind the newest page")
  }

  func testRepositoryPagesByParsedCreationInstantThenASCIIJobIDAcrossRestart() throws {
    let repository = try RuntimeJobRepository(stateDirectory: stateDirectory)
    let record = Data("{}".utf8)
    for (jobID, timestamp) in [
      ("job-z", "2026-08-03T00:00:00.100Z"),
      ("job-earlier", "2026-08-03T00:00:00Z"),
      ("job-a", "2026-08-03T00:00:00.100+00:00"),
    ] {
      XCTAssertEqual(
        try repository.admit(
          jobID: jobID, idempotencyKey: "idem-\(jobID)", requestHash: "hash-\(jobID)",
          initialState: JobState.preflight.rawValue, createdAtUTC: timestamp,
          initialRecordData: record),
        .admitted)
    }

    let oldestFirst = try repository.listJobs(pageSize: 1, cursor: nil)
    XCTAssertEqual(oldestFirst.jobs.map(\.jobID), ["job-earlier"])
    let oldestCursor = try XCTUnwrap(oldestFirst.nextCursor)
    XCTAssertFalse(oldestCursor.contains("job-earlier"), "the logical key must remain opaque")

    let reopened = try RuntimeJobRepository(stateDirectory: stateDirectory)
    let secondOldest = try reopened.listJobs(pageSize: 1, cursor: oldestCursor)
    XCTAssertEqual(secondOldest.jobs.map(\.jobID), ["job-a"])
    let lastOldest = try reopened.listJobs(
      pageSize: 1, cursor: try XCTUnwrap(secondOldest.nextCursor))
    XCTAssertEqual(lastOldest.jobs.map(\.jobID), ["job-z"])
    XCTAssertNil(lastOldest.nextCursor)

    let newestFirst = try reopened.listJobs(pageSize: 1, cursor: nil, newestFirst: true)
    XCTAssertEqual(newestFirst.jobs.map(\.jobID), ["job-a"])
    let newestCursor = try XCTUnwrap(newestFirst.nextCursor)
    let secondNewest = try reopened.listJobs(
      pageSize: 1, cursor: newestCursor, newestFirst: true)
    XCTAssertEqual(secondNewest.jobs.map(\.jobID), ["job-z"])
    let lastNewest = try reopened.listJobs(
      pageSize: 1, cursor: try XCTUnwrap(secondNewest.nextCursor), newestFirst: true)
    XCTAssertEqual(lastNewest.jobs.map(\.jobID), ["job-earlier"])
    XCTAssertNil(lastNewest.nextCursor)

    XCTAssertThrowsError(
      try reopened.listJobs(pageSize: 1, cursor: newestCursor, newestFirst: false)
    ) { error in
      guard case RuntimeJobRepositoryError.corrupt(let detail) = error else {
        return XCTFail("expected corrupt cursor, got \(error)")
      }
      XCTAssertTrue(detail.contains("cursor"), detail)
    }
  }

  func testSchemaV1HistoryMigratesToLogicalCreationOrderIncludingLegacyRows() throws {
    do {
      let repository = try RuntimeJobRepository(stateDirectory: stateDirectory)
      XCTAssertEqual(
        try repository.admit(
          jobID: "job-current", idempotencyKey: "idem-current", requestHash: "hash-current",
          initialState: JobState.preflight.rawValue,
          createdAtUTC: "2026-08-03T00:00:00.100Z", initialRecordData: Data("{}".utf8)),
        .admitted)
      XCTAssertEqual(
        try repository.admit(
          jobID: "job-legacy", idempotencyKey: "idem-legacy", requestHash: "hash-legacy",
          initialState: JobState.succeeded.rawValue,
          createdAtUTC: RuntimePersistedJob.legacyCreatedAtUTC,
          initialRecordData: Data(
            #"{"createdAtUTC":"2026-08-03T00:00:00Z"}"#.utf8)),
        .admitted)
    }
    try RuntimeJobSQLiteTestSupport.rewriteAsSchemaV1(stateDirectory: stateDirectory)

    let migrated = try RuntimeJobRepository(stateDirectory: stateDirectory)
    let page = try migrated.listJobs(pageSize: 10, cursor: nil)
    XCTAssertEqual(page.jobs.map(\.jobID), ["job-legacy", "job-current"])
    XCTAssertEqual(page.jobs.first?.createdAtUTC, RuntimePersistedJob.legacyCreatedAtUTC)
    XCTAssertNil(page.nextCursor)

    XCTAssertEqual(
      try migrated.admit(
        jobID: "job-after", idempotencyKey: "idem-after", requestHash: "hash-after",
        initialState: JobState.preflight.rawValue,
        createdAtUTC: "2026-08-03T00:00:01Z", initialRecordData: Data("{}".utf8)),
      .admitted)
    let legacyFirst = try migrated.listLegacyJobs(pageSize: 2, cursor: nil)
    XCTAssertEqual(legacyFirst.jobs.map(\.jobID), ["job-current", "job-legacy"])
    let legacyLast = try migrated.listLegacyJobs(
      pageSize: 2, cursor: try XCTUnwrap(legacyFirst.nextCursor))
    XCTAssertEqual(legacyLast.jobs.map(\.jobID), ["job-after"])
    XCTAssertNil(legacyLast.nextCursor)
  }

  func testUnreadablePersistedRecordIsDistinctFromMissingAcrossHistoryReads() async throws {
    let jobID: String
    do {
      let (engine, _) = try makeEngine(
        dispatcher: ScriptedDispatcher(script: .observationHappy))
      let accepted = try await engine.submit(
        observeRequest(
          idempotencyKey: "idem-unreadable-history-01",
          requestID: "req-unreadable-history-01"))
      jobID = accepted.jobID
      let completion = try await engine.run(jobID: jobID)
      XCTAssertEqual(completion.state, "succeeded")
    }
    try RuntimeJobSQLiteTestSupport.replaceInitialRecord(
      stateDirectory: stateDirectory, jobID: jobID, data: Data("not-json".utf8))

    let (reopened, _) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy))
    do {
      _ = try await reopened.status(jobID: jobID)
      XCTFail("a corrupt persisted record must not be presented as missing")
    } catch let error as RuntimeJobEngineError {
      XCTAssertEqual(error, .jobRecordUnreadable(jobID))
    }
    do {
      _ = try await reopened.listJobs()
      XCTFail("the unpaged history surface must fail loudly on a corrupt record")
    } catch let error as RuntimeJobEngineError {
      XCTAssertEqual(error, .jobRecordUnreadable(jobID))
    }
    do {
      _ = try await reopened.listJobs(pageSize: 100)
      XCTFail("the paged history surface must use the same corrupt-record error")
    } catch let error as RuntimeJobEngineError {
      XCTAssertEqual(error, .jobRecordUnreadable(jobID))
    }
    do {
      _ = try await reopened.status(jobID: "job-that-never-existed")
      XCTFail("a genuinely missing job must still use jobNotFound")
    } catch let error as RuntimeJobEngineError {
      XCTAssertEqual(error, .jobNotFound("job-that-never-existed"))
    }
  }

  func testDaemonRecoveryReopensOnlyActiveJobsWhileTerminalHistoryStaysQueryable() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let terminal = try await engine.submit(
      observeRequest(
        idempotencyKey: "idem-terminal-history-01", requestID: "req-terminal-history-01"))
    let terminalCompletion = try await engine.run(jobID: terminal.jobID)
    XCTAssertEqual(terminalCompletion.state, "succeeded")
    let active = try await engine.submit(
      observeRequest(idempotencyKey: "idem-active-history-01", requestID: "req-active-history-01"))
    let listedBeforeRestart = Set((try await engine.listJobs()).map(\.jobID))
    XCTAssertEqual(listedBeforeRestart, Set([terminal.jobID, active.jobID]))

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let recovered = try await reopened.recoverActiveJobs()
    XCTAssertEqual(recovered.map(\.jobID), [active.jobID])
    XCTAssertEqual(recovered.map(\.state), ["preflight"])

    // Terminal history remains visible through the normal list surface, but
    // recovery above has reopened only the active job; the completed job was
    // never replayed or given a fresh JobRuntime allocation.
    let listedJobs = try await reopened.listJobs()
    XCTAssertEqual(Set(listedJobs.map(\.jobID)), Set([terminal.jobID, active.jobID]))
    let terminalStatus = try await reopened.status(jobID: terminal.jobID)
    XCTAssertEqual(terminalStatus.state, "succeeded")
    let history = try await reopened.listJobs(pageSize: 10)
    XCTAssertEqual(Set(history.jobs.map(\.jobID)), Set([terminal.jobID, active.jobID]))
  }

  /// A repeatable long-run simulation for the macOS Runtime.  It deliberately
  /// keeps the default contract suite short; the slow lane runs this with
  /// `ARKDECK_RUN_LONG_RUNTIME_TESTS=1` before a release or a soak window.
  ///
  /// Each batch creates durable jobs and completes a small terminal slice;
  /// the test then recreates the Runtime from disk.  This proves that restart
  /// recovery reopens only active work while the growing terminal history
  /// remains queryable through SQLite pagination rather than daemon memory.
  func testLongRunSimulationKeepsTerminalHistoryOutOfRecoveryMemory() async throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUN_LONG_RUNTIME_TESTS"] == "1" else {
      throw XCTSkip("set ARKDECK_RUN_LONG_RUNTIME_TESTS=1 to run the 1,000-job Runtime simulation")
    }

    let cycles = 10
    let jobsPerCycle = 100
    let completedPerCycle = 10
    let expectedJobCount = cycles * jobsPerCycle
    let expectedTerminalCount = cycles * completedPerCycle
    var expectedActiveIDs = Set<String>()
    var expectedTerminalIDs = Set<String>()

    // One daemon accepts the full workload, then exits once.  This reflects
    // the production lifetime more accurately than retaining a chain of
    // short-lived test actors in one XCTest process.
    do {
      let dispatcher = ScriptedDispatcher(script: .observationHappy)
      let (engine, _) = try makeEngine(dispatcher: dispatcher)
      for cycle in 0..<cycles {
        for offset in 0..<jobsPerCycle {
          let index = cycle * jobsPerCycle + offset
          let accepted = try await engine.submit(
            observeRequest(
              idempotencyKey: "idem-long-run-\(index)", requestID: "req-long-run-\(index)"))
          if offset < completedPerCycle {
            let completion = try await engine.run(jobID: accepted.jobID)
            XCTAssertEqual(completion.state, "succeeded")
            expectedTerminalIDs.insert(accepted.jobID)
          } else {
            expectedActiveIDs.insert(accepted.jobID)
          }
        }
      }
      let firstHistoryPage = try await engine.listJobs(pageSize: 97)
      XCTAssertEqual(firstHistoryPage.jobs.count, 97)
    }

    // Simulate a clean daemon process loss and restart.  Recovery must not
    // redispatch terminal work, nor allocate an in-memory runtime for it.
    let restartDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (restarted, _) = try makeEngine(dispatcher: restartDispatcher)
    let recovered = try await restarted.recoverActiveJobs()
    XCTAssertEqual(Set(recovered.map(\.jobID)), expectedActiveIDs)
    XCTAssertTrue(recovered.allSatisfy { $0.state == "preflight" })
    XCTAssertEqual(restartDispatcher.dispatchCount, 0)

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    var cursor: String?
    var historyIDs = Set<String>()
    repeat {
      let page = try await reopened.listJobs(pageSize: 97, cursor: cursor)
      historyIDs.formUnion(page.jobs.map(\.jobID))
      cursor = page.nextCursor
    } while cursor != nil

    XCTAssertEqual(historyIDs.count, expectedJobCount)
    XCTAssertEqual(historyIDs, expectedActiveIDs.union(expectedTerminalIDs))
    XCTAssertEqual(expectedTerminalIDs.count, expectedTerminalCount)
    XCTAssertEqual(expectedActiveIDs.count, expectedJobCount - expectedTerminalCount)
  }

  /// Upgrade regression for the retired idempotency ledger generation. Its
  /// importer never deleted the file, so residue whose keys the SQLite table
  /// already carries must keep opening; a key the table has never admitted
  /// means unconsumed history and must block admission outright — silently
  /// ignoring it could replay a used key as a fresh device mutation.
  func testRetiredIdempotencyLedgerBlocksOnlyUnconsumedKeys() throws {
    let root = stateDirectory.appending(
      path:
        "retired-ledger-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ledgerURL = root.appending(path: "idempotency.json")

    // Consumed residue: the previous release imported this key into SQLite
    // and left the file behind. The repository must keep opening.
    do {
      let repository = try RuntimeJobRepository(stateDirectory: root)
      XCTAssertEqual(
        try repository.admit(
          jobID: "job-legacy-1", idempotencyKey: "idem-legacy-1",
          requestHash: "hash-1", initialState: JobState.preflight.rawValue,
          createdAtUTC: "2026-08-11T00:00:00Z", initialRecordData: Data("{}".utf8)),
        .admitted)
    }
    try Data(
      #"{"entries":[{"idempotencyKey":"idem-legacy-1","jobID":"job-legacy-1","requestFingerprintSHA256":"hash-1"}]}"#
        .utf8
    ).write(to: ledgerURL)
    XCTAssertNoThrow(try RuntimeJobRepository(stateDirectory: root))

    // Unconsumed key: never admitted by this database. Must refuse to open.
    try Data(
      #"{"entries":[{"idempotencyKey":"idem-never-imported","jobID":"job-x","requestFingerprintSHA256":"hash-x"}]}"#
        .utf8
    ).write(to: ledgerURL)
    XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: root)) { error in
      guard case RuntimeJobRepositoryError.corrupt(let detail) = error else {
        return XCTFail("expected corrupt, got \(error)")
      }
      XCTAssertTrue(detail.contains("idem-never-imported"), detail)
    }

    // Undecodable ledger: consumption cannot be proven. Must refuse to open.
    try Data("not json".utf8).write(to: ledgerURL)
    XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: root)) { error in
      guard case RuntimeJobRepositoryError.corrupt(let detail) = error else {
        return XCTFail("expected corrupt, got \(error)")
      }
      XCTAssertTrue(detail.contains("undecodable"), detail)
    }

    try FileManager.default.removeItem(at: ledgerURL)
    XCTAssertNoThrow(try RuntimeJobRepository(stateDirectory: root))
  }

  /// Startup must be driven by the active-job index, not by total terminal
  /// history.  Seeding the repository directly keeps this focused on the
  /// durable SQLite/recovery boundary: executing 10,000 provider plans would
  /// turn a startup-scaling check into a device-provider throughput test.
  func testTenThousandTerminalHistoryDoesNotExpandRestartRecovery() async throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUN_TEN_THOUSAND_HISTORY_TESTS"] == "1"
    else {
      throw XCTSkip(
        "set ARKDECK_RUN_TEN_THOUSAND_HISTORY_TESTS=1 to run the 10,000-job history test")
    }

    let repository = try RuntimeJobRepository(stateDirectory: stateDirectory)
    let terminalRecord = Data("{}".utf8)
    for index in 0..<10_000 {
      let jobID = String(format: "job-history-%05d", index)
      let idempotencyKey = String(format: "idem-history-%05d", index)
      XCTAssertEqual(
        try repository.admit(
          jobID: jobID, idempotencyKey: idempotencyKey,
          requestHash: "hash-\(index)", initialState: JobState.preflight.rawValue,
          createdAtUTC: "2026-08-03T00:00:00Z", initialRecordData: terminalRecord),
        .admitted)
      try repository.updateJobState(
        jobID: jobID, state: JobState.succeeded.rawValue,
        updatedAtUTC: "2026-08-03T00:00:01Z", recordData: terminalRecord)
    }

    let started = DispatchTime.now().uptimeNanoseconds
    let (restarted, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let recovered = try await restarted.recoverActiveJobs()
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    XCTAssertTrue(recovered.isEmpty)
    XCTAssertLessThan(
      elapsedSeconds, 5,
      "terminal history must not be replayed during macOS Runtime startup")

    var cursor: String?
    var listed = 0
    repeat {
      let page = try repository.listJobs(pageSize: 997, cursor: cursor)
      listed += page.jobs.count
      cursor = page.nextCursor
    } while cursor != nil
    XCTAssertEqual(listed, 10_000)

    let newest = try repository.listJobs(
      pageSize: 3, cursor: nil, newestFirst: true)
    XCTAssertEqual(
      newest.jobs.map(\.jobID),
      ["job-history-00000", "job-history-00001", "job-history-00002"])
    let older = try repository.listJobs(
      pageSize: 3, cursor: newest.nextCursor, newestFirst: true)
    XCTAssertEqual(
      older.jobs.map(\.jobID),
      ["job-history-00003", "job-history-00004", "job-history-00005"])
  }

  func testAdmissionCrashMatrixRecoversCommittedJobWithoutDuplicateExecution() async throws {
    struct SimulatedProcessLoss: Error {}
    let root = stateDirectory!
    defer { stateDirectory = root }
    for point in RuntimeAdmissionFaultPoint.allCases {
      stateDirectory = root.appending(path: point.rawValue, directoryHint: .isDirectory)
      let injector = RuntimeAdmissionFaultInjector { observed in
        if observed == point { throw SimulatedProcessLoss() }
      }
      let (faulty, _) = try makeEngine(
        dispatcher: ScriptedDispatcher(script: .observationHappy),
        admissionFaultInjector: injector)
      let request = observeRequest(
        idempotencyKey: "idem-admission-crash-\(point.rawValue)",
        requestID: "req-admission-crash-\(point.rawValue)")
      do {
        _ = try await faulty.submit(request)
        XCTFail("\(point.rawValue): fault injection must stop submit")
      } catch is SimulatedProcessLoss {
        // Simulate an abrupt process loss by abandoning this engine and
        // reopening all state through a fresh Runtime instance below.
      }

      let dispatcher = ScriptedDispatcher(script: .observationHappy)
      let (reopened, _) = try makeEngine(dispatcher: dispatcher)
      let recovered = try await reopened.recoverPersistedJobs()
      let retry = try await reopened.submit(request)
      switch point {
      case .beforeAdmission:
        XCTAssertTrue(recovered.isEmpty, "\(point.rawValue): no job may be admitted")
        XCTAssertFalse(retry.deduplicated, "\(point.rawValue): retry must create the job")
      case .afterAdmission, .beforeJournalAppend, .afterJournalAppend,
        .beforeRecordPersist, .afterRecordPersist, .beforeResponse:
        XCTAssertEqual(recovered.count, 1, "\(point.rawValue): committed job must recover")
        XCTAssertTrue(retry.deduplicated, "\(point.rawValue): retry must reuse the committed job")
        XCTAssertEqual(retry.jobID, recovered[0].jobID)
        let status = try await reopened.status(jobID: retry.jobID)
        XCTAssertEqual(status.state, "preflight")
      }
      XCTAssertEqual(dispatcher.dispatchCount, 0, "\(point.rawValue): recovery must not execute")
    }
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
      from: stateDirectory.appending(
        path:
          "jobs/\(acceptance.jobID)", directoryHint: .isDirectory))
    XCTAssertEqual(
      record.request.authorization?.capabilityID,
      status.capability.capabilityID,
      "the daemon-owned reference must survive restart in the persisted typed request")
  }

  func testCancelMutationBeforeRunDoesNotConsumeOrFabricateCapabilityLineage() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease()
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-cancel-before-run",
        idempotencyKey: "idem-hap-cancel-before-run"))
    let capabilityStatuses = try await capabilityStore.list()
    let capabilityID = try XCTUnwrap(
      capabilityStatuses.first?.capability.capabilityID)

    try await engine.requestCancel(jobID: acceptance.jobID)

    let status = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, JobState.cancelled.rawValue)
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let capability = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(capability?.remainingUses, 10_000)
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertTrue(capability?.lineage.isEmpty == true)
    XCTAssertTrue(capability?.lineageAllowsNewExecution == true)
  }

  func testAutomaticCapabilityValidationUsesFreshClockAfterIssuance() async throws {
    let clock = AdvancingClock()
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(
      dispatcher: dispatcher,
      engineNowUTC: { clock.nowUTC() })
    let lease = try await publishHAPLease()

    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-auto-fresh-clock",
        idempotencyKey: "idem-hap-auto-fresh-clock"))

    let job = try await engine.status(jobID: acceptance.jobID)
    let capabilities = try await capabilityStore.list()
    let capability = try XCTUnwrap(capabilities.first?.capability)
    XCTAssertGreaterThanOrEqual(job.createdAtUTC ?? "", capability.issuedAtUTC)
    XCTAssertGreaterThanOrEqual(clock.callCount, 4)
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
          targetID: "TGT-DAYU200-01", bindingRevision: 7,
          stableIdentitySHA256:
            "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"),
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
    XCTAssertEqual(afterEvidence.inputs?["bundleName"], .string("com.example.demo"))
    XCTAssertEqual(afterEvidence.inputs?["abilityName"], .string("EntryAbility"))
    XCTAssertEqual(afterEvidence.inputs?["hapArtifactLease"], .string(lease))

    // A different execution ID of the same typed plan reuses the reviewed
    // envelope. Its real Job-owned remote path differs, while the
    // authorization plan template digest remains stable.
    let secondRequest = Data(
      String(decoding: hapRequest, as: UTF8.self)
        .replacingOccurrences(of: "\"req-hap\"", with: "\"req-hap-2\"")
        .replacingOccurrences(
          of: "\"idem-hap-0001\"", with: "\"idem-hap-0002\""
        ).utf8)
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

    let recoveryMarker =
      "recovered: outstanding intents or unknown outcomes; no redispatch"
    XCTAssertEqual(
      try XCTUnwrap(recovered.first).timeline.filter { $0 == recoveryMarker }.count, 1)

    // A parked Job remains in the active SQLite index and is replayed by each
    // fresh daemon. Repeating that read-only recovery must not grow its
    // persisted timeline when no durable event intervened.
    let secondRecoveredDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (secondRecoveredEngine, _) = try makeEngine(
      dispatcher: secondRecoveredDispatcher)
    let recoveredAgain = try await secondRecoveredEngine.recoverPersistedJobs()
    XCTAssertEqual(recoveredAgain.map(\.jobID), [first.jobID])
    XCTAssertEqual(
      try XCTUnwrap(recoveredAgain.first).timeline.filter { $0 == recoveryMarker }.count, 1)
    XCTAssertEqual(secondRecoveredDispatcher.dispatchCount, 0)
  }

  // MARK: - plan-only answers what a submit would need

  /// `capture.diagnostics@1` is `readOnly` at its floor and mutates the device
  /// once inputs select a file-producing leg, so the authorization a caller
  /// needs depends on inputs it chose rather than on the operation it named.
  /// Before this, the only way to find that out was to submit.
  ///
  /// The plan preview reports the effect these exact inputs select and the
  /// policy the catalog attaches to it, and acquires nothing to do so.
  func testPlanOnlyReportsTheEscalationItsOwnInputsCauseWithoutAcquiringAnything()
    async throws
  {
    let (engine, capabilityStore) = try makeEngine(
      dispatcher: ScriptedDispatcher(script: .observationHappy))

    func preview(inputs: String) async throws -> RuntimePlanOnlyPreview {
      try await engine.planOnly(
        Data(
          """
          {
            "documentType": "runtime-operation-request",
            "schemaVersion": "2.0.0",
            "requestId": "req-plan-effect",
            "idempotencyKey": "idem-plan-effect-01",
            "target": { "targetId": "TGT-DAYU200-01", "expectedBindingRevision": 7 },
            "operation": { "id": "capture.diagnostics", "version": 1 },
            "inputs": { "durationSeconds": 5\(inputs) }
          }
          """.utf8))
    }

    let readOnly = try await preview(inputs: "")
    XCTAssertEqual(readOnly.effectiveEffect, WorkflowEffect.readOnly.rawValue)
    XCTAssertEqual(
      readOnly.authorizationPolicy,
      RuntimeOperationAuthorizationPolicy.defaultReadOnly.rawValue,
      "a bounded read is admitted by the default policy, and the caller can see that")

    let mutating = try await preview(
      inputs: ", \"traceCategories\": [\"sched\"]")
    XCTAssertEqual(
      mutating.effectiveEffect, WorkflowEffect.deviceMutation.rawValue,
      "selecting the remote-file trace leg escalates the effect, and the preview says so")
    XCTAssertNotEqual(
      mutating.authorizationPolicy, readOnly.authorizationPolicy,
      "the same operation now needs a different authorization; that is the whole answer")

    // Nothing was acquired to answer the question. Asserted on the store's
    // durable state rather than on call counts: if the preview had issued,
    // reserved or consumed anything, a capability would exist here.
    let issued = try await capabilityStore.list()
    XCTAssertEqual(
      issued, [],
      "plan-only must remain free of authorization side effects; found \(issued)")
    XCTAssertFalse(readOnly.jobAdmitted)
    XCTAssertFalse(mutating.jobAdmitted)
    XCTAssertEqual(mutating.dispatchDisposition, "notDispatched")
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

  func testFlashSingletonPersistedAliasKeepsRecoveryJournalSchema() throws {
    for (index, operationReference) in ["flash.dayu200", "flash.dayu200@1"].enumerated() {
      let request = try RuntimeOperationRequest(
        requestID: "req-schema-\(index)",
        idempotencyKey: "idem-schema-\(index)",
        target: DurableTargetReference(
          targetID: "TGT-DAYU200-01", expectedBindingRevision: 7),
        operation: RuntimeOperationReference(id: "flash.dayu200", version: 1))
      let record = RuntimeJobRecord(
        jobID: "job-schema-\(index)", request: request,
        operationReference: operationReference,
        catalogDigest: RuntimeOperationCatalog.catalogDigest,
        providerID: "rockchip", createdAtUTC: "2026-08-08T00:00:00Z",
        actualEffect: WorkflowEffect.destructive.rawValue,
        admissionEvidence: nil, materializedPlanDigest: nil,
        materializedStableTargetIdentitySHA256: nil,
        materializedBindingRevision: 7)

      XCTAssertTrue(RuntimeJobEngine.isDayu200Flash(record))
      XCTAssertEqual(
        RuntimeJobEngine.journalSchemaVersion(of: record),
        JournalEvent.completeOverwriteRecoverySchemaVersion)

      let journalURL = stateDirectory.appending(
        path:
          "flash-schema-\(index)-journal.jsonl")
      let journal = try FileDurableJournal(url: journalURL)
      let schemaVersion = RuntimeJobEngine.journalSchemaVersion(of: record)
      try journal.appendAndSynchronize(
        try JournalEvent.jobCreated(
          eventID: "created", sequence: 0, sessionID: record.sessionID,
          jobID: record.jobID, timestamp: record.createdAtUTC,
          executionMode: "execute", schemaVersion: schemaVersion))
      try journal.appendAndSynchronize(
        try JournalEvent.stateTransition(
          eventID: "preflight", sequence: 1, sessionID: record.sessionID,
          jobID: record.jobID, timestamp: record.createdAtUTC,
          from: .queued, to: .preflight, reason: "fixture",
          schemaVersion: schemaVersion))
      let replay = try DurableJournalRecovery.inspect(url: journalURL)
      XCTAssertEqual(replay.schemaVersion, JournalEvent.completeOverwriteRecoverySchemaVersion)
      XCTAssertTrue(
        replay.events.allSatisfy {
          $0.schemaVersion == JournalEvent.completeOverwriteRecoverySchemaVersion
        })
    }
  }

  func testOutcomeUnknownParksAndReconcileClears() async throws {
    let dispatcher = ScriptedDispatcher(script: .outcomeUnknownOnDeviceProbe)
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(observeRequest(idempotencyKey: "idem-unknown-01"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "waitingForRecovery")
    XCTAssertTrue(status.outcomeUnknown)
    XCTAssertFalse(
      status.waitingForHuman,
      "an unknown outcome is a machine-classified recovery blocker, not an approval question"
    )
    let dispatchesAtPark = dispatcher.dispatchCount

    // No automatic replay: status queries do not redispatch.
    _ = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAtPark)

    // Reconcile through the provider (read-only family: safely resolvable).
    let reconciled = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAtPark, "reconcile never redispatches")

    // The proof reconciliation just established must be *recognizable* as one.
    // `mutationIntentEvidence` identifies a proven non-execution by this
    // semantic code alone, and until r17 the reconciled outcome was written
    // without it: the readback established that a step never ran, but the
    // historical usage terminal did not carry that proof and remained
    // `unsafePartial` with the disproof sitting in its own journal
    // (TASK-AIN-020).
    //
    // Pinned here on the read-only route because it is the one that needs no
    // real archive; the branch is shared with the mutating route, which is
    // where the consequence lands.
    let replay = try DurableJournalRecovery.inspect(
      url: stateDirectory.appending(path: "jobs", directoryHint: .isDirectory)
        .appending(path: acceptance.jobID, directoryHint: .isDirectory)
        .appending(path: "journal.jsonl"))
    let reconciledOutcome = try XCTUnwrap(
      replay.events.last { $0.kind == .stepOutcome && $0.eventID.hasPrefix("reconciled-outcome-") },
      "reconciliation must journal its own correlated outcome")
    XCTAssertEqual(reconciledOutcome.payload["result"], .string("failed"))
    XCTAssertEqual(
      reconciledOutcome.payload["semanticCode"], .string("confirmedNotExecuted"),
      "a proven non-execution that is not labelled as one is evidence nothing can read")
  }

  func testTerminalLineageRepairsWithoutRedispatchForReconcileAndNextSubmit() async throws {
    let dispatcher = ScriptedDispatcher(script: .outcomeUnknownOnHAPSend)
    let (engine, capabilityStore) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease()
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease, requestID: "req-terminal-lineage-repair",
        idempotencyKey: "idem-terminal-lineage-repair"))
    let capabilities = try await capabilityStore.list()
    let capabilityID = try XCTUnwrap(
      capabilities.first?.capability.capabilityID)

    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(parked.state, JobState.waitingForRecovery.rawValue)
    XCTAssertTrue(parked.outcomeUnknown)
    let capabilityDirectory =
      stateDirectory
      .appending(path: "capabilities", directoryHint: .isDirectory)
    let capabilityURL = capabilityDirectory.appending(path: "runtime-capabilities.json")
    // A use is recorded by appending it, so the durable state of a capability
    // is the document *and* the events appended since. Capturing only one of
    // them would recreate a window that cannot happen.
    let ledgerURL = capabilityDirectory.appending(path: "runtime-capabilities.ledger")
    let parkedCapabilityBytes = try Data(contentsOf: capabilityURL)
    let parkedLedgerBytes = (try? Data(contentsOf: ledgerURL)) ?? Data()

    let firstReconcile = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertEqual(firstReconcile.state, JobState.failed.rawValue)
    XCTAssertFalse(firstReconcile.outcomeUnknown)
    let dispatchesAfterProof = dispatcher.dispatchCount
    let firstLineage = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(
      firstLineage?.lineage.first?.outcomeHistory.map(\.outcome),
      [.outcomeUnknown, .safeToReflash])

    // Recreate the production crash/failure window: journal + terminal Job
    // are durable, while the independently durable capability store still has
    // only its earlier outcomeUnknown node.
    try parkedCapabilityBytes.write(to: capabilityURL, options: .atomic)
    try parkedLedgerBytes.write(to: ledgerURL, options: .atomic)
    let rolledBackLineage = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(
      rolledBackLineage?.lineage.first?.outcomeHistory.map(\.outcome),
      [.outcomeUnknown])

    let repaired = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertEqual(repaired.state, JobState.failed.rawValue)
    XCTAssertFalse(repaired.outcomeUnknown)
    XCTAssertEqual(
      dispatcher.dispatchCount, dispatchesAfterProof,
      "terminal lineage repair must not repeat readback or original mutation")
    let repairedLineage = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(
      repairedLineage?.lineage.first?.outcomeHistory.map(\.outcome),
      [.outcomeUnknown, .safeToReflash])

    // Recreate the production ENOSPC/process-loss window more exactly: the
    // capability use was consumed, but no outcome append became durable.
    // With uses appended rather than rewritten, that window is exactly a
    // ledger whose consume event is durable and whose outcome append never
    // landed - which is what dropping the outcome events leaves behind.
    try parkedCapabilityBytes.write(to: capabilityURL, options: .atomic)
    let consumeOnlyLedger =
      parkedLedgerBytes
      .split(separator: 0x0A, omittingEmptySubsequences: true)
      .filter { !String(decoding: $0, as: UTF8.self).contains("\"kind\":\"outcome\"") }
      .reduce(into: Data()) { $0.append(Data($1)); $0.append(0x0A) }
    XCTAssertLessThan(
      consumeOnlyLedger.count, parkedLedgerBytes.count,
      "fixture assumption: the parked ledger carries at least one outcome append")
    try consumeOnlyLedger.write(to: ledgerURL, options: .atomic)
    let pendingLineage = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(pendingLineage?.lineage.first?.outcome, .pending)

    let dispatchesBeforeNextSubmit = dispatcher.dispatchCount
    let next = try await engine.submit(
      hapRequest(
        lease: lease, requestID: "req-terminal-lineage-next-submit",
        idempotencyKey: "idem-terminal-lineage-next-submit"))
    XCTAssertNotEqual(next.jobID, acceptance.jobID)
    XCTAssertEqual(
      dispatcher.dispatchCount, dispatchesBeforeNextSubmit,
      "submit may close proven lineage bookkeeping but must not dispatch a Provider action")
    let submitRepairedLineage = try await capabilityStore.inspect(capabilityID: capabilityID)
    XCTAssertEqual(
      submitRepairedLineage?.lineage.first?.outcomeHistory.map(\.outcome),
      [.safeToReflash])
  }

  // MARK: - Cancel

  func testCancelBeforeRunClosesDurablyWithZeroDispatch() async throws {
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let root = stateDirectory!
    let (engine, _) = try makeEngine(dispatcher: dispatcher, stateRoot: root)
    let acceptance = try await engine.submit(observeRequest(idempotencyKey: "idem-cancel-01"))
    try await engine.requestCancel(jobID: acceptance.jobID)
    let status = try await engine.status(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "cancelled")
    XCTAssertNotNil(status.finishedAtUTC)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    XCTAssertTrue(status.timeline.contains("preflight->cancelRequested"))
    XCTAssertTrue(status.timeline.contains("cancelRequested->cancellingAtSafeBoundary"))
    XCTAssertTrue(status.timeline.contains("cancellingAtSafeBoundary->cancelled"))

    let restartedDispatcher = ScriptedDispatcher(script: .observationHappy)
    let (restarted, _) = try makeEngine(
      dispatcher: restartedDispatcher, stateRoot: root)
    let recoveredActiveJobs = try await restarted.recoverActiveJobs()
    XCTAssertTrue(recoveredActiveJobs.isEmpty)
    let afterRestart = try await restarted.status(jobID: acceptance.jobID)
    XCTAssertEqual(afterRestart.state, "cancelled")
    XCTAssertEqual(afterRestart.timeline, status.timeline)
    XCTAssertEqual(restartedDispatcher.dispatchCount, 0)
  }

  func testCancellationDoesNotInterruptAnAtSafeBoundaryMutation() async throws {
    let dispatcher = BlockingHAPSendDispatcher()
    let (engine, _) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease()
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-in-flight-safe-boundary-cancel",
        idempotencyKey: "idem-hap-in-flight-safe-boundary-cancel"))
    let run = Task { try await engine.run(jobID: acceptance.jobID) }

    await dispatcher.waitUntilStarted()
    try await engine.requestCancel(jobID: acceptance.jobID)
    await Task.yield()
    XCTAssertFalse(
      dispatcher.observedCancellation,
      "atSafeBoundary device mutation must finish its active process before cancellation")
    dispatcher.release()

    let status = try await run.value
    XCTAssertEqual(status.state, JobState.cancelled.rawValue)
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertFalse(dispatcher.observedCancellation)
    XCTAssertTrue(status.timeline.contains("running->cancelRequested"))
    XCTAssertTrue(status.timeline.contains("cancelRequested->cancellingAtSafeBoundary"))
    XCTAssertTrue(status.timeline.contains("cancellingAtSafeBoundary->cancelled"))
  }

  func testCancellationAtFinalCapabilityBoundaryConsumesNothingAndDispatchesNothingElse()
    async throws
  {
    let barrier = EngineAsyncBarrier()
    let dispatcher = ScriptedDispatcher(script: .observationHappy)
    let (engine, capabilityStore) = try makeEngine(
      dispatcher: dispatcher,
      testHooks: .init(
        beforeMutationCapabilityCommit: { _ in await barrier.waitAtBoundary() }))
    let lease = try await publishHAPLease()
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease,
        requestID: "req-hap-capability-boundary-cancel",
        idempotencyKey: "idem-hap-capability-boundary-cancel"))
    let run = Task { try await engine.run(jobID: acceptance.jobID) }

    await barrier.waitUntilReached()
    let dispatchesAtBoundary = dispatcher.dispatchCount
    let capabilitiesBefore = try await capabilityStore.list()
    let capabilityBefore = try XCTUnwrap(capabilitiesBefore.first)
    let journalURL = stateDirectory.appending(
      path: "jobs/\(acceptance.jobID)/journal.jsonl")
    let intentsAtBoundary = try DurableJournalRecovery.inspect(url: journalURL)
      .events.filter { $0.kind == .stepIntent }.count

    try await engine.requestCancel(jobID: acceptance.jobID)
    await barrier.release()
    let status = try await run.value

    XCTAssertEqual(status.state, JobState.cancelled.rawValue)
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAtBoundary)
    let inspectedAfter = try await capabilityStore.inspect(
      capabilityID: capabilityBefore.capability.capabilityID)
    let capabilityAfter = try XCTUnwrap(inspectedAfter)
    XCTAssertEqual(capabilityAfter.remainingUses, capabilityBefore.remainingUses)
    XCTAssertTrue(capabilityAfter.lineage.isEmpty)
    XCTAssertEqual(
      try DurableJournalRecovery.inspect(url: journalURL)
        .events.filter { $0.kind == .stepIntent }.count,
      intentsAtBoundary)
  }

  // MARK: - Crash windows (process-level fixture)

  func testCrashWindowsPreserveUnknownOutcomeAndNeverRedispatch() async throws {
    let fixtureURL = productsDirectory.appending(path: "ArkDeckEngineCrashFixture")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
      throw XCTSkip("ArkDeckEngineCrashFixture binary not built")
    }
    for window in ["afterIntentBeforeDispatch", "afterDispatchBeforeOutcome"] {
      let directory = stateDirectory.appending(path: window, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let process = Process()
      process.executableURL = fixtureURL
      process.arguments = [window, directory.path]
      try process.run()
      let ready = directory.appending(path: "ready")
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

      let effectMarker = directory.appending(path: "external-effect-marker")
      let markerExists = FileManager.default.fileExists(atPath: effectMarker.path)
      XCTAssertEqual(
        markerExists, window == "afterDispatchBeforeOutcome",
        "\(window): effect marker must reflect the crash window exactly")

      // Recovery in this process over the fixture's state: parked, no redispatch.
      let capabilityStore = try RuntimeCapabilityStore(
        directoryURL: directory.appending(path: "capabilities", directoryHint: .isDirectory))
      let dispatcher = ScriptedDispatcher(script: .observationHappy)
      let engine = try RuntimeJobEngine(
        configuration: .init(stateDirectory: directory.appending(path: "engine-state")),
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
      .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl")
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

  func testQuietCrashInLanelessStatesRecoversToHonestTerminalState() async throws {
    // The quiet crash window: a process killed between one durable event and
    // the next leaves a clean journal — no torn tail, no outstanding intent,
    // no unknown outcome — whose final state never advances on its own. For
    // preflight/running/resumeAtConfirmedSafeBoundary that is the designed
    // explicit resume lane (see the clean-crash test above). But
    // cancelRequested, cancellingAtSafeBoundary and finalizing have no
    // post-restart lane at all: `run` rejects them and `reconcile` is a no-op
    // without an unknown outcome. Recovery must finish the already-durable
    // decision journal-only instead of presenting the job as healthy
    // in-flight forever.
    struct Window {
      let name: String
      let cancelBeforeRun: Bool
      let truncateAfterTransitionTo: JobState
      let expectedTerminalState: String
      let expectedTimelineEntry: String
    }
    let windows: [Window] = [
      Window(
        name: "cancelRequested",
        cancelBeforeRun: true,
        truncateAfterTransitionTo: .cancelRequested,
        expectedTerminalState: "cancelled",
        expectedTimelineEntry:
          "recovered: completed durable cancellation at journal-confirmed safe boundary; no redispatch"
      ),
      Window(
        name: "cancellingAtSafeBoundary",
        cancelBeforeRun: true,
        truncateAfterTransitionTo: .cancellingAtSafeBoundary,
        expectedTerminalState: "cancelled",
        expectedTimelineEntry:
          "recovered: completed durable cancellation at journal-confirmed safe boundary; no redispatch"
      ),
      Window(
        name: "finalizing",
        cancelBeforeRun: false,
        truncateAfterTransitionTo: .finalizing,
        expectedTerminalState: "failed",
        expectedTimelineEntry:
          "recovered: finalization interrupted before terminal transition; failed without redispatch"
      ),
    ]
    for window in windows {
      stateDirectory = FileManager.default.temporaryDirectory
        .appending(path: "arkdeck-engine-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: stateDirectory) }

      let originalDispatcher = ScriptedDispatcher(script: .observationHappy)
      let (original, _) = try makeEngine(dispatcher: originalDispatcher)
      let acceptance = try await original.submit(
        observeRequest(idempotencyKey: "idem-quiet-\(window.name)"))
      if window.cancelBeforeRun {
        try await original.requestCancel(jobID: acceptance.jobID)
        let cancelled = try await original.status(jobID: acceptance.jobID)
        XCTAssertEqual(cancelled.state, "cancelled", window.name)
      } else {
        let completed = try await original.run(jobID: acceptance.jobID)
        XCTAssertEqual(completed.state, "succeeded", window.name)
      }

      // Recreate the exact durable bytes of a process loss immediately after
      // the transition into the window's state became durable.
      let journalURL =
        stateDirectory
        .appending(path: "jobs/\(acceptance.jobID)/journal.jsonl")
      let fullReplay = try DurableJournalRecovery.inspect(url: journalURL)
      let boundary = try XCTUnwrap(
        fullReplay.events.first {
          $0.kind == .stateTransition
            && $0.stateTransition?.to == window.truncateAfterTransitionTo
        }?.sequence, window.name)
      let lines = try String(contentsOf: journalURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
      let durablePrefix = lines.prefix(boundary + 1).joined(separator: "\n") + "\n"
      try Data(durablePrefix.utf8).write(to: journalURL)

      // The window really is quiet: nothing dangling, nothing unknown — only
      // a non-terminal state that nothing will ever advance.
      let truncated = try DurableJournalRecovery.inspect(url: journalURL)
      XCTAssertEqual(truncated.currentState, window.truncateAfterTransitionTo, window.name)
      XCTAssertFalse(truncated.hasTornTail, window.name)
      XCTAssertTrue(truncated.outstandingIntents.isEmpty, window.name)
      XCTAssertTrue(truncated.unknownOutcomes.isEmpty, window.name)

      let recoveredDispatcher = ScriptedDispatcher(script: .observationHappy)
      let (recoveredEngine, _) = try makeEngine(dispatcher: recoveredDispatcher)
      let recovered = try await recoveredEngine.recoverPersistedJobs()
      XCTAssertEqual(recovered.count, 1, window.name)
      let status = try XCTUnwrap(recovered.first, window.name)
      XCTAssertEqual(
        status.state, window.expectedTerminalState,
        "\(window.name): a clean journal stranded in a state with no resume "
          + "lane must recover to its honest terminal, not present as healthy")
      XCTAssertFalse(status.outcomeUnknown, window.name)
      XCTAssertTrue(
        status.timeline.contains(window.expectedTimelineEntry),
        "\(window.name): \(status.timeline.joined(separator: " | "))")
      XCTAssertEqual(
        recoveredDispatcher.dispatchCount, 0,
        "\(window.name): recovery must never redispatch")

      // The resolution is durable in the journal, not only in the record.
      let resolved = try DurableJournalRecovery.inspect(url: journalURL)
      XCTAssertEqual(
        resolved.currentState?.rawValue, window.expectedTerminalState, window.name)

      // A second restart over the resolved state is a stable no-op.
      let secondDispatcher = ScriptedDispatcher(script: .observationHappy)
      let (secondEngine, _) = try makeEngine(dispatcher: secondDispatcher)
      let second = try await secondEngine.recoverPersistedJobs()
      XCTAssertEqual(second.map(\.state), [window.expectedTerminalState], window.name)
      XCTAssertEqual(secondDispatcher.dispatchCount, 0, window.name)
      let stable = try DurableJournalRecovery.inspect(url: journalURL)
      XCTAssertEqual(stable.lastDurableSequence, resolved.lastDurableSequence, window.name)
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

private final class EnginePowerActivityBackend: PowerActivityBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var beginAttempts = 0
  private var begins = 0
  private var ends = 0
  var failNextBegin = false

  func beginIdleSleepPrevention(reason _: String) throws -> AnyObject {
    lock.lock()
    beginAttempts += 1
    let shouldFail = failNextBegin
    failNextBegin = false
    if !shouldFail { begins += 1 }
    lock.unlock()
    if shouldFail { throw RuntimeJobEngineError.internalFailure("power backend refused") }
    return NSObject()
  }

  func endIdleSleepPrevention(_: AnyObject) {
    lock.lock()
    ends += 1
    lock.unlock()
  }

  var beginAttemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return beginAttempts
  }

  var beginCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return begins
  }

  var endCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return ends
  }
}

private final class LockedPowerObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [Int] = []

  func record(activeLeaseCount: Int) {
    lock.lock()
    counts.append(activeLeaseCount)
    lock.unlock()
  }

  var everyDispatchWasProtected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !counts.isEmpty && counts.allSatisfy { $0 == 1 }
  }

  var dispatchCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return counts.count
  }
}
