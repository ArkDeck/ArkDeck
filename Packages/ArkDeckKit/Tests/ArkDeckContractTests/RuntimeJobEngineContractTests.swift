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
    nowUTC: String = "2026-07-29T00:00:00Z",
    admissionFaultInjector: RuntimeAdmissionFaultInjector = .none
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { nowUTC })
    self.artifactStore = artifactStore
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory,
        admissionFaultInjector: admissionFaultInjector),
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

  func testFreshStateAdmissionCreatesEveryDurableProjectionAndSurvivesRestart() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let accepted = try await engine.submit(observeRequest(idempotencyKey: "idem-fresh-state-01"))
    let jobDirectory = stateDirectory
      .appendingPathComponent("jobs/\(accepted.jobID)", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: jobDirectory.appendingPathComponent("journal.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: jobDirectory.appendingPathComponent("job-record.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: stateDirectory.appendingPathComponent(RuntimeJobRepository.filename).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("idempotency.json").path),
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
    let first = try await engine.listJobs(pageSize: 2)
    XCTAssertEqual(first.jobs.map(\.jobID), accepted.prefix(2).map(\.jobID))
    XCTAssertNotNil(first.nextCursor)
    let second = try await engine.listJobs(pageSize: 2, cursor: first.nextCursor)
    XCTAssertEqual(second.jobs.map(\.jobID), accepted.suffix(1).map(\.jobID))
    XCTAssertNil(second.nextCursor)

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let historical = try await reopened.listJobs(pageSize: 3)
    XCTAssertEqual(historical.jobs.map(\.jobID), accepted.map(\.jobID))
    let status = try await reopened.status(jobID: accepted[2].jobID)
    XCTAssertEqual(status.state, "preflight")
  }

  func testDaemonRecoveryReopensOnlyActiveJobsWhileTerminalHistoryStaysQueryable() async throws {
    let (engine, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let terminal = try await engine.submit(
      observeRequest(idempotencyKey: "idem-terminal-history-01", requestID: "req-terminal-history-01"))
    let terminalCompletion = try await engine.run(jobID: terminal.jobID)
    XCTAssertEqual(terminalCompletion.state, "succeeded")
    let active = try await engine.submit(
      observeRequest(idempotencyKey: "idem-active-history-01", requestID: "req-active-history-01"))
    let listedBeforeRestart = Set((await engine.listJobs()).map(\.jobID))
    XCTAssertEqual(listedBeforeRestart, Set([terminal.jobID, active.jobID]))

    let (reopened, _) = try makeEngine(dispatcher: ScriptedDispatcher(script: .observationHappy))
    let recovered = try await reopened.recoverActiveJobs()
    XCTAssertEqual(recovered.map(\.jobID), [active.jobID])
    XCTAssertEqual(recovered.map(\.state), ["preflight"])

    // Terminal history remains visible through the normal list surface, but
    // recovery above has reopened only the active job; the completed job was
    // never replayed or given a fresh JobRuntime allocation.
    let listedJobs = await reopened.listJobs()
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

  /// Startup must be driven by the active-job index, not by total terminal
  /// history.  Seeding the repository directly keeps this focused on the
  /// durable SQLite/recovery boundary: executing 10,000 provider plans would
  /// turn a startup-scaling check into a device-provider throughput test.
  func testTenThousandTerminalHistoryDoesNotExpandRestartRecovery() async throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUN_TEN_THOUSAND_HISTORY_TESTS"] == "1" else {
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
  }

  func testAdmissionCrashMatrixRecoversCommittedJobWithoutDuplicateExecution() async throws {
    struct SimulatedProcessLoss: Error {}
    let root = stateDirectory!
    defer { stateDirectory = root }
    for point in RuntimeAdmissionFaultPoint.allCases {
      stateDirectory = root.appendingPathComponent(point.rawValue, isDirectory: true)
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
    // without it: the readback established that a step never ran, the campaign
    // usage terminal did not say so, and a campaign burned as `unsafePartial`
    // with the disproof sitting in its own journal (TASK-AIN-020).
    //
    // Pinned here on the read-only route because it is the one that needs no
    // real archive; the branch is shared with the mutating route, which is
    // where the consequence lands.
    let replay = try DurableJournalRecovery.inspect(
      url: stateDirectory.appendingPathComponent("jobs", isDirectory: true)
        .appendingPathComponent(acceptance.jobID, isDirectory: true)
        .appendingPathComponent("journal.jsonl"))
    let reconciledOutcome = try XCTUnwrap(
      replay.events.last { $0.kind == .stepOutcome && $0.eventID.hasPrefix("reconciled-outcome-") },
      "reconciliation must journal its own correlated outcome")
    XCTAssertEqual(reconciledOutcome.payload["result"], .string("failed"))
    XCTAssertEqual(
      reconciledOutcome.payload["semanticCode"], .string("confirmedNotExecuted"),
      "a proven non-execution that is not labelled as one is evidence nothing can read")
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
        .appendingPathComponent("arkdeck-engine-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: stateDirectory) }

      let originalDispatcher = ScriptedDispatcher(script: .observationHappy)
      let (original, _) = try makeEngine(dispatcher: originalDispatcher)
      let acceptance = try await original.submit(
        observeRequest(idempotencyKey: "idem-quiet-\(window.name)"))
      if window.cancelBeforeRun {
        try await original.requestCancel(jobID: acceptance.jobID)
        let cancelled = try await original.run(jobID: acceptance.jobID)
        XCTAssertEqual(cancelled.state, "cancelled", window.name)
      } else {
        let completed = try await original.run(jobID: acceptance.jobID)
        XCTAssertEqual(completed.state, "succeeded", window.name)
      }

      // Recreate the exact durable bytes of a process loss immediately after
      // the transition into the window's state became durable.
      let journalURL =
        stateDirectory
        .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl")
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
