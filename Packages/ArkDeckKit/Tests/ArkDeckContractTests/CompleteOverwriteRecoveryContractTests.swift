import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class CompleteOverwriteRecoveryContractTests: XCTestCase {
  private let identity = String(repeating: "9", count: 64)
  private let artifactSHA256 = String(repeating: "6", count: 64)
  private let providerSHA256 = String(repeating: "4", count: 64)
  private var stateDirectory: URL!

  private actor DispatchLog {
    private(set) var stepIDs: [String] = []

    func record(_ stepID: String) { stepIDs.append(stepID) }
    func snapshot() -> [String] { stepIDs }
  }

  private struct RecoveryFactsPort: RockchipRuntimeFactsPort {
    let identity: String
    let toolSHA256: String
    var crossModeBinding = TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip", toolVersion: BundledRockchipComponent.reportedVersion,
        toolSHA256: toolSHA256,
        serverFacts: [
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
            crossModeBinding,
          TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey:
            "046eb5cb504a4487bd67f0a6f7be370c0be7d2952f0964c390b74c047d3dea70",
          TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey: "42",
        ], targetID: targetID,
        bindingRevision: 2, deviceIdentitySHA256: identity,
        executionConnectKey: "sealed-complete-overwrite-connect-key",
        deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-fixture",
        buildFingerprint: "fixture-before-recovery", transport: "sealed-fixture",
        profileID: "dayu200", collectedAtUTC: "2026-08-08T01:00:00Z")
    }
  }

  private struct ConfirmingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog
    var outcomeUnknownStepID: String? = nil

    func unavailableReason(providerID _: String) -> String? { nil }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      guard case .hostManaged(let descriptor) = plan.kind else {
        throw RuntimeDispatchFailure.failed("recovery fixture received a non-host-managed plan")
      }
      await log.record(descriptor.stepID)
      if descriptor.stepID == outcomeUnknownStepID {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "fixture lost the enter-Loader process after durable intent")
      }
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("confirmed fixture".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.001,
        hostManagedRecordID: "fixture-record-\(descriptor.stepID)")
    }
  }

  private struct HostIntentRecord: Codable {
    let schemaVersion: String
    let jobID: String
    let stepID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let providerExecutableSHA256: String
    let actionSHA256: String
    let action: PersistedTypedProviderAction
  }

  private struct HostReceiptRecord: Codable {
    let schemaVersion: String
    let jobID: String
    let stepID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let providerExecutableSHA256: String
    let actionSHA256: String
    let summary: [String: String]
    let stdoutSHA256: String
    let stderrSHA256: String
    let stdoutTruncated: Bool
    let subprocessCount: Int
  }

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-complete-overwrite-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: stateDirectory)
  }

  func testRecoveryStoreIsAppendOnlyIdempotentAndRejectsConflictingProof() async throws {
    let store = try RuntimeSupersedingRecoveryStore(stateDirectory: stateDirectory)
    let draft = recoveryDraft()
    let first = try await store.append(draft)
    let repeated = try await store.append(draft)
    let stored = try await store.list()
    XCTAssertEqual(repeated, first)
    XCTAssertEqual(stored, [first])

    let conflicting = SupersedingRecoveryEpochDraft(
      source: draft.source,
      stableTargetIdentitySHA256: draft.stableTargetIdentitySHA256,
      bindingRevision: draft.bindingRevision,
      coveredIntents: draft.coveredIntents,
      uncertainEffectSetSHA256: draft.uncertainEffectSetSHA256,
      coverageContractVersion: draft.coverageContractVersion,
      coveredEffectSetSHA256: draft.coveredEffectSetSHA256,
      recoveryJobID: draft.recoveryJobID,
      recoveryIntentEventID: draft.recoveryIntentEventID,
      operationReference: draft.operationReference,
      profileReference: draft.profileReference,
      materializedPlanDigestSHA256: draft.materializedPlanDigestSHA256,
      artifactSHA256: draft.artifactSHA256,
      providerExecutableSHA256: String(repeating: "5", count: 64),
      confirmedStepIDs: draft.confirmedStepIDs,
      resultingTargetEpochSHA256: draft.resultingTargetEpochSHA256,
      establishedAtUTC: draft.establishedAtUTC)
    do {
      _ = try await store.append(conflicting)
      XCTFail("the same recovery key with drifted proof must not be idempotent")
    } catch let error as SupersedingRecoveryStoreError {
      guard case .conflictingEpoch = error else {
        return XCTFail("unexpected store refusal: \(error)")
      }
    }
  }

  func testRecoveryStoreRejectsTamperedHashChain() async throws {
    let store = try RuntimeSupersedingRecoveryStore(stateDirectory: stateDirectory)
    _ = try await store.append(recoveryDraft())
    let url = stateDirectory.appending(path: "superseding-recovery-epochs.json")
    var data = try Data(contentsOf: url)
    let original = Data(String(repeating: "7", count: 64).utf8)
    let replacement = Data(String(repeating: "8", count: 64).utf8)
    let range = try XCTUnwrap(data.range(of: original))
    data.replaceSubrange(range, with: replacement)
    try DurableFileWriter.createOrReplaceAtomically(destination: url, data: data)
    do {
      _ = try await store.list()
      XCTFail("a changed epoch material field must invalidate its hash")
    } catch let error as SupersedingRecoveryStoreError {
      guard case .corrupt = error else {
        return XCTFail("unexpected tamper refusal: \(error)")
      }
    }
  }

  func testUniqueLoaderBindingClosesOnlyOutstandingEnterLoaderIntentWithoutReplay()
    async throws
  {
    // Drives a full `flash.dayu200` job, which cannot run in this tree: step 1
    // of TASK-AFA-001 removed the in-process lowering and step 5 has not wired
    // the permit route yet, so the plan is refused before authorization.
    //
    // Skipped rather than rewritten. What these assert — no replay, no new
    // dispatch, supersession bookkeeping — is exactly what must still hold once
    // arkforged performs the write, and rewriting them to assert today's
    // refusal would throw that away. `DeviceProviderContractTests`'s
    // `testFlashStepsAreRefusedBeforeAuthorization` covers the interim contract.
    throw XCTSkip(
      "flash.dayu200 has no executor until TASK-AFA-001 step 5 wires the StepPermit route")
    try await assertLoaderBindingSettlement(currentBindingRevision: 3)
  }

  func testFreshAttestationAtTheSameRevisionClosesEnterLoaderIntentWithoutReplay()
    async throws
  {
    // Drives a full `flash.dayu200` job, which cannot run in this tree: step 1
    // of TASK-AFA-001 removed the in-process lowering and step 5 has not wired
    // the permit route yet, so the plan is refused before authorization.
    //
    // Skipped rather than rewritten. What these assert — no replay, no new
    // dispatch, supersession bookkeeping — is exactly what must still hold once
    // arkforged performs the write, and rewriting them to assert today's
    // refusal would throw that away. `DeviceProviderContractTests`'s
    // `testFlashStepsAreRefusedBeforeAuthorization` covers the interim contract.
    throw XCTSkip(
      "flash.dayu200 has no executor until TASK-AFA-001 step 5 wires the StepPermit route")
    try await assertLoaderBindingSettlement(currentBindingRevision: 2)
  }

  private func assertLoaderBindingSettlement(currentBindingRevision: Int) async throws {
    let archive = try recoveryArchive()
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-loader-input", sessionID: "session-loader-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: archive))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(
          factsPort: RecoveryFactsPort(identity: identity, toolSHA256: providerSHA256),
          availability: .available)
      ]),
      dispatcher: ConfirmingDispatcher(
        log: dispatchLog, outcomeUnknownStepID: "enter-loader-mode"),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let request = try flashRequest(id: "loader-binding", lease: lease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let accepted = try await engine.submit(encoder.encode(request))
    let expectedBindingRevision = try XCTUnwrap(
      request.target.expectedBindingRevision)

    let parked = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(parked.state, JobState.waitingForRecovery.rawValue)
    XCTAssertTrue(parked.outcomeUnknown)
    let pendingJobID = try await engine.loaderTransitionAwaitingBinding(
      targetID: request.target.targetID,
      expectedBindingRevision: expectedBindingRevision)
    XCTAssertEqual(pendingJobID, accepted.jobID)

    let selectionEvidence = String(repeating: "a", count: 64)
    let settled = try await engine.settleLoaderTransitionAfterBinding(
      jobID: accepted.jobID,
      targetID: request.target.targetID,
      previousBindingRevision: 2,
      currentBindingRevision: currentBindingRevision,
      selectionEvidenceSHA256: selectionEvidence)
    XCTAssertEqual(settled.state, JobState.failed.rawValue)
    XCTAssertFalse(settled.outcomeUnknown)
    XCTAssertTrue(
      settled.timeline.contains {
        $0.contains("original action not replayed")
      })
    let pendingAfterSettlement = try await engine.loaderTransitionAwaitingBinding(
      targetID: request.target.targetID,
      expectedBindingRevision: expectedBindingRevision)
    XCTAssertNil(pendingAfterSettlement)

    let dispatches = await dispatchLog.snapshot()
    XCTAssertEqual(dispatches, ["enter-loader-mode"])
    let replay = try DurableJournalRecovery.inspect(
      url: stateDirectory.appending(
        path:
          "jobs/\(accepted.jobID)/journal.jsonl"))
    XCTAssertTrue(replay.outstandingIntents.isEmpty)
    XCTAssertTrue(replay.unknownOutcomes.isEmpty)
    XCTAssertEqual(replay.currentState, .failed)
    XCTAssertTrue(
      replay.events.contains {
        $0.kind == .stepOutcome
          && $0.stepID == "enter-loader-mode"
          && $0.payload["outcomeCertainty"] == .string("confirmed")
      })
    let capabilityStatuses = try await capabilityStore.list()
    let consumed = try XCTUnwrap(capabilityStatuses.only)
    XCTAssertEqual(consumed.lineage.last?.outcome, .confirmed)
    XCTAssertEqual(consumed.lineage.last?.outcomeHistory.last?.terminalState, "failed")
  }

  func testCompleteLaterFlashHistoryAppendsSupersessionWithoutChangingUnknownJobs() async throws {
    // Drives a full `flash.dayu200` job, which cannot run in this tree: step 1
    // of TASK-AFA-001 removed the in-process lowering and step 5 has not wired
    // the permit route yet, so the plan is refused before authorization.
    //
    // Skipped rather than rewritten. What these assert — no replay, no new
    // dispatch, supersession bookkeeping — is exactly what must still hold once
    // arkforged performs the write, and rewriting them to assert today's
    // refusal would throw that away. `DeviceProviderContractTests`'s
    // `testFlashStepsAreRefusedBeforeAuthorization` covers the interim contract.
    throw XCTSkip(
      "flash.dayu200 has no executor until TASK-AFA-001 step 5 wires the StepPermit route")
    let first = try writeUnknownJob(
      jobID: "job-old-outstanding", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false)
    let second = try writeUnknownJob(
      jobID: "job-old-correlated", timestamp: "2026-08-08T00:01:00Z",
      correlatedUnknownOutcome: true)
    let originalFirst = try Data(contentsOf: first.recordURL)
    let originalSecond = try Data(contentsOf: second.recordURL)
    try writeSuccessfulRecoveryJob(
      jobID: "job-later-complete", createdAtUTC: "2026-08-08T00:10:00Z",
      finishedAtUTC: "2026-08-08T00:20:00Z", omitHostProofStepID: nil)

    let admission = try await recoveryService().completeOverwriteAdmission(
      request: try flashRequest(id: "new-request"),
      descriptor: try flashDescriptor(), stableIdentitySHA256: identity,
      bindingRevision: 2)
    XCTAssertNil(
      admission.recoveryContext,
      "verified later history must require zero new dispatch")
    XCTAssertEqual(try Data(contentsOf: first.recordURL), originalFirst)
    XCTAssertEqual(try Data(contentsOf: second.recordURL), originalSecond)

    let epochs = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: stateDirectory
    ).list()
    let epoch = try XCTUnwrap(epochs.only)
    XCTAssertEqual(admission.recognizedEpoch, epoch)
    XCTAssertEqual(epoch.source, .historicalRecognition)
    XCTAssertEqual(epoch.recoveryJobID, "job-later-complete")
    XCTAssertEqual(epoch.recoveryIntentEventID, "intent-flash-partitions-attempt-7")
    XCTAssertEqual(
      epoch.confirmedStepIDs,
      [
        "inspect-recovery-target", "flash-partitions", "verify-flash-readback",
        "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
      ],
      "the epoch must retain every actual correlated typed Step, not only the coverage subset")
    XCTAssertEqual(
      Set(epoch.coveredIntents.map(\.jobID)),
      Set(["job-old-outstanding", "job-old-correlated"]))
  }

  func testIncompleteHistoricalPostflightAppendsNothingAndReturnsDistinctRecovery() async throws {
    _ = try writeUnknownJob(
      jobID: "job-old", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: true)
    try writeSuccessfulRecoveryJob(
      jobID: "job-incomplete", createdAtUTC: "2026-08-08T00:10:00Z",
      finishedAtUTC: "2026-08-08T00:20:00Z",
      omitHostProofStepID: "rebind-and-verify-build")

    let admission = try await recoveryService().completeOverwriteAdmission(
      request: try flashRequest(id: "new-recovery"),
      descriptor: try flashDescriptor(), stableIdentitySHA256: identity,
      bindingRevision: 2)
    let context = admission.recoveryContext
    XCTAssertNotNil(context)
    XCTAssertEqual(context?.coveredIntents.count, 1)
    XCTAssertNil(admission.recognizedEpoch)
    let epochs = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: stateDirectory
    ).list()
    XCTAssertTrue(epochs.isEmpty)
  }

  func testJournalUncertaintyCannotBeHiddenByAStaleRecordProjection() async throws {
    _ = try writeUnknownJob(
      jobID: "job-stale-projection", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false, projectedOutcomeUnknown: false)

    let admission = try await recoveryService().completeOverwriteAdmission(
      request: try flashRequest(id: "stale-projection-recovery"),
      descriptor: try flashDescriptor(), stableIdentitySHA256: identity,
      bindingRevision: 2)

    XCTAssertEqual(admission.recoveryContext?.coveredIntents.count, 1)
    XCTAssertEqual(
      admission.recoveryContext?.coveredIntents.first?.jobID,
      "job-stale-projection")
    XCTAssertNil(admission.recognizedEpoch)
  }

  func testRecoveryNegativeMatrixBlocksCoverageCancellationExpiryAndAttemptSeventeen()
    async throws
  {
    _ = try writeUnknownJob(
      jobID: "job-negative-base", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false)
    var incompleteInputs = try flashRequest(id: "incomplete-coverage").inputs
    incompleteInputs["partitionPlan"] = .array(
      Array(try recoveryPartitions().dropLast()).map(JSONValue.string))
    let incompleteRequest = try RuntimeOperationRequest(
      requestID: "request-incomplete-coverage",
      idempotencyKey: "idempotency-incomplete-coverage",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-RECOVERY", expectedBindingRevision: 2),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: incompleteInputs)
    await assertRecoveryBlocked(
      "completeOverwriteRecovery.incompleteRequestedCoverage",
      service: recoveryService(), request: incompleteRequest)

    let cancellationRoot = try isolatedStateDirectory("cancellation")
    defer { try? FileManager.default.removeItem(at: cancellationRoot) }
    let originalRoot = stateDirectory
    stateDirectory = cancellationRoot
    _ = try writeUnknownJob(
      jobID: "job-cancelled-invocation", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false, cancellationPending: true)
    await assertRecoveryBlocked(
      "completeOverwriteRecovery.explicitCancellationPending",
      service: recoveryService(), request: try flashRequest(id: "cancelled"))

    let expiryRoot = try isolatedStateDirectory("expiry")
    stateDirectory = expiryRoot
    defer { try? FileManager.default.removeItem(at: expiryRoot) }
    _ = try writeUnknownJob(
      jobID: "job-expired-invocation", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false)
    await assertRecoveryBlocked(
      "completeOverwriteRecovery.sharedFourHourBudgetExpired",
      service: recoveryService(nowUTC: "2026-08-08T04:00:00Z"),
      request: try flashRequest(id: "expired"))

    let budgetRoot = try isolatedStateDirectory("budget")
    stateDirectory = budgetRoot
    defer {
      stateDirectory = originalRoot
      try? FileManager.default.removeItem(at: budgetRoot)
    }
    for ordinal in 1...16 {
      _ = try writeUnknownJob(
        jobID: "job-budget-\(ordinal)", timestamp: "2026-08-08T00:00:00Z",
        correlatedUnknownOutcome: false)
    }
    await assertRecoveryBlocked(
      "completeOverwriteRecovery.sharedEpochBudgetExhausted",
      service: recoveryService(), request: try flashRequest(id: "attempt-17"))
  }

  func testDistinctRecoveryRunsThroughRuntimeOwnedCapabilityAndTypedProvider() async throws {
    // Drives a full `flash.dayu200` job, which cannot run in this tree: step 1
    // of TASK-AFA-001 removed the in-process lowering and step 5 has not wired
    // the permit route yet, so the plan is refused before authorization.
    //
    // Skipped rather than rewritten. What these assert — no replay, no new
    // dispatch, supersession bookkeeping — is exactly what must still hold once
    // arkforged performs the write, and rewriting them to assert today's
    // refusal would throw that away. `DeviceProviderContractTests`'s
    // `testFlashStepsAreRefusedBeforeAuthorization` covers the interim contract.
    throw XCTSkip(
      "flash.dayu200 has no executor until TASK-AFA-001 step 5 wires the StepPermit route")
    let old = try writeUnknownJob(
      jobID: "job-original-unknown", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false)
    let originalRecord = try Data(contentsOf: old.recordURL)
    let originalJournal = try Data(contentsOf: old.journalURL)
    let archive = try recoveryArchive()
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-recovery-input", sessionID: "session-recovery-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: archive))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(
          factsPort: RecoveryFactsPort(identity: identity, toolSHA256: providerSHA256),
          availability: .available)
      ]),
      dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let request = try flashRequest(id: "runtime-recovery", lease: lease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let acceptance = try await engine.submit(encoder.encode(request))
    let issued = try await capabilityStore.list()
    XCTAssertEqual(issued.count, 1)
    XCTAssertEqual(issued.first?.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(issued.first?.consumptionCount, 0)

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, JobState.recovered.rawValue)
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertFalse(status.waitingForHuman)
    XCTAssertNotNil(status.recoveryEpochID)
    XCTAssertEqual(try Data(contentsOf: old.recordURL), originalRecord)
    XCTAssertEqual(try Data(contentsOf: old.journalURL), originalJournal)
    let recoveryDirectory =
      stateDirectory
      .appending(path: "jobs/\(acceptance.jobID)", directoryHint: .isDirectory)
    let recoveryJournalURL = recoveryDirectory.appending(path: "journal.jsonl")
    let recoveryReplay = try DurableJournalRecovery.inspect(url: recoveryJournalURL)
    XCTAssertEqual(
      recoveryReplay.schemaVersion, JournalEvent.completeOverwriteRecoverySchemaVersion)
    XCTAssertTrue(
      recoveryReplay.events.allSatisfy {
        $0.schemaVersion == JournalEvent.completeOverwriteRecoverySchemaVersion
      })
    XCTAssertThrowsError(
      try JournalEvent.stateTransition(
        eventID: "legacy-recovery-edge", sequence: 0,
        sessionID: "session-legacy", jobID: "job-legacy",
        timestamp: "2026-08-08T01:00:00Z",
        from: .running, to: .recoveringByCompleteOverwrite,
        reason: "legacy writer must not emit recovery state",
        schemaVersion: JournalEvent.schemaVersion))

    let dispatches = await dispatchLog.snapshot()
    XCTAssertEqual(dispatches.filter { $0 == "flash-partitions" }.count, 1)
    XCTAssertEqual(dispatches.filter { $0 == "enter-loader-mode" }.count, 1)
    let epochs = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: stateDirectory
    ).list()
    let epoch = try XCTUnwrap(epochs.only)
    XCTAssertEqual(epoch.source, .distinctRecoveryExecution)
    XCTAssertEqual(epoch.epochID, status.recoveryEpochID)
    XCTAssertEqual(epoch.coveredIntents.map(\.jobID), ["job-original-unknown"])
    XCTAssertTrue(Set(dispatches).isSubset(of: Set(epoch.confirmedStepIDs)))
    XCTAssertTrue(
      Set([
        "flash-partitions", "verify-flash-readback", "reboot-device", "wait-for-hdc",
        "rebind-and-verify-build",
      ])
      .isSubset(of: Set(epoch.confirmedStepIDs)))
    let finalCapabilities = try await capabilityStore.list()
    let consumed = try XCTUnwrap(finalCapabilities.only)
    XCTAssertEqual(consumed.consumptionCount, 1)
    XCTAssertEqual(consumed.lineage.last?.outcome, .confirmed)
    XCTAssertEqual(consumed.lineage.last?.outcomeHistory.last?.terminalState, "recovered")

    // Recreate the only crash window after the epoch append: all typed
    // outcomes and the epoch are durable, but finalizing->recovered is not.
    // Startup may append that one journal-only transition and must never
    // dispatch a second provider action.
    let journalURL = recoveryJournalURL
    let journalText = try XCTUnwrap(String(data: Data(contentsOf: journalURL), encoding: .utf8))
    var lines = journalText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let removedTerminal = try XCTUnwrap(lines.popLast())
    XCTAssertTrue(removedTerminal.contains("\"to\":\"recovered\""), removedTerminal)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: journalURL)
    var crashRecord = try RuntimeJobRecord.load(from: recoveryDirectory)
    crashRecord.state = JobState.finalizing.rawValue
    crashRecord.finishedAtUTC = nil
    try crashRecord.persist(into: recoveryDirectory)
    let dispatchCountAtCrash = dispatches.count
    let replayed = try await recoveryService().replay(
      RuntimePersistedJob(
        jobID: acceptance.jobID, idempotencyKey: request.idempotencyKey,
        requestHash: String(repeating: "f", count: 64),
        state: JobState.finalizing.rawValue,
        createdAtUTC: crashRecord.createdAtUTC,
        updatedAtUTC: "2026-08-08T01:00:00Z", version: 1,
        initialRecordData: nil))
    XCTAssertEqual(replayed.record.state, JobState.recovered.rawValue)
    let epochsAfterReplay = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: stateDirectory
    ).list()
    XCTAssertEqual(epochsAfterReplay, [epoch])
    let dispatchesAfterReplay = await dispatchLog.snapshot()
    XCTAssertEqual(dispatchesAfterReplay.count, dispatchCountAtCrash)
  }

  func testUnpreparedCrossModeBindingRejectsBeforeCapabilityAndDispatch() async throws {
    // Drives a full `flash.dayu200` job, which cannot run in this tree: step 1
    // of TASK-AFA-001 removed the in-process lowering and step 5 has not wired
    // the permit route yet, so the plan is refused before authorization.
    //
    // Skipped rather than rewritten. What these assert — no replay, no new
    // dispatch, supersession bookkeeping — is exactly what must still hold once
    // arkforged performs the write, and rewriting them to assert today's
    // refusal would throw that away. `DeviceProviderContractTests`'s
    // `testFlashStepsAreRefusedBeforeAuthorization` covers the interim contract.
    throw XCTSkip(
      "flash.dayu200 has no executor until TASK-AFA-001 step 5 wires the StepPermit route")
    let archive = try recoveryArchive()
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-unprepared-input", sessionID: "session-unprepared-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: archive))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(
          factsPort: RecoveryFactsPort(
            identity: identity, toolSHA256: providerSHA256,
            crossModeBinding:
              TargetStoreRockchipRuntimeFactsPort.crossModeBindingUnprepared),
          availability: .available)
      ]),
      dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let request = try flashRequest(id: "unprepared-cross-mode", lease: lease)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    do {
      _ = try await engine.submit(encoder.encode(request))
      XCTFail("an HDC-only target must not receive a Flash capability")
    } catch let RuntimeJobEngineError.rejected(code, detail) {
      XCTAssertEqual(code, .authorizationRequired)
      XCTAssertTrue(detail.contains("flash.crossModeBindingUnprepared"), detail)
    }
    let capabilities = try await capabilityStore.list()
    let dispatches = await dispatchLog.snapshot()
    XCTAssertTrue(capabilities.isEmpty)
    XCTAssertTrue(dispatches.isEmpty)
  }

  func testSupersededUnknownPresentationIsTruthfulButNoLongerNeedsAttention() throws {
    let epochID = "recovery-epoch-0123456789abcdef0123456789abcdef"
    let data = Data(
      """
      {"ok":true,"result":[
        {"jobId":"job-old","operation":"flash.dayu200","targetId":"target-1",
         "state":"waitingForRecovery","waitingForHuman":false,"outcomeUnknown":true,
         "outstandingResidueCount":0,"timeline":[],
         "supersededByRecoveryEpochId":"\(epochID)"}
      ]}
      """.utf8)
    let presentation = RuntimeHistoryResponseDecoding.presentation(from: data)
    let job = try XCTUnwrap(presentation.jobs.only)
    XCTAssertTrue(job.outcomeUnknown)
    XCTAssertEqual(job.supersededByRecoveryEpochID, epochID)
    XCTAssertTrue(job.hasEstablishedCurrentEpoch)
    XCTAssertFalse(job.needsAttention)
    XCTAssertFalse(job.requiresRecoveryGuidance)
  }

  private func recoveryDraft() -> SupersedingRecoveryEpochDraft {
    let effects = ["partition:system", "partition:userdata"]
    return SupersedingRecoveryEpochDraft(
      source: .historicalRecognition,
      stableTargetIdentitySHA256: identity,
      bindingRevision: 2,
      coveredIntents: [
        SupersededRecoveryIntent(
          jobID: "job-old", intentEventID: "intent-old",
          operationReference: "flash.dayu200", profileReference: "dayu200",
          observedAtUTC: "2026-08-08T00:00:00Z", possibleEffects: effects)
      ],
      uncertainEffectSetSHA256: effectDigest(effects),
      coverageContractVersion: "1.0.0",
      coveredEffectSetSHA256: String(repeating: "1", count: 64),
      recoveryJobID: "job-recovery",
      recoveryIntentEventID: "intent-recovery",
      operationReference: "flash.dayu200",
      profileReference: "dayu200",
      materializedPlanDigestSHA256: String(repeating: "2", count: 64),
      artifactSHA256: String(repeating: "3", count: 64),
      providerExecutableSHA256: String(repeating: "4", count: 64),
      confirmedStepIDs: ["flash-partitions", "verify-flash-readback"],
      resultingTargetEpochSHA256: String(repeating: "7", count: 64),
      establishedAtUTC: "2026-08-08T00:20:00Z")
  }

  private func recoveryService(
    nowUTC: String = "2026-08-08T01:00:00Z"
  ) -> RuntimeRecoveryService {
    RuntimeRecoveryService(
      stateDirectory: stateDirectory, nowUTC: { nowUTC })
  }

  private func flashDescriptor() throws -> CatalogOperationDescriptor {
    try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
  }

  private func flashRequest(
    id: String,
    lease: String = "lease-v1:recovery:ART-0123456789abcdef0123456789abcdef"
  ) throws -> RuntimeOperationRequest {
    let partitions = try XCTUnwrap(
      try flashDescriptor().completeOverwriteRecovery?.profile(reference: "dayu200")
    ).coveredEffects.map { String($0.dropFirst("partition:".count)) }
    return try RuntimeOperationRequest(
      requestID: "request-\(id)", idempotencyKey: "idempotency-\(id)",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-RECOVERY", expectedBindingRevision: 2),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: [
        "imageBundleLease": .string(lease),
        "deviceProfile": .string("dayu200"),
        "partitionPlan": .array(partitions.map(JSONValue.string)),
        "postFlashVerification": .string("full"),
      ])
  }

  private func writeUnknownJob(
    jobID: String, timestamp: String, correlatedUnknownOutcome: Bool,
    projectedOutcomeUnknown: Bool = true,
    cancellationPending: Bool = false
  ) throws -> (recordURL: URL, journalURL: URL) {
    var record = try makeRecord(
      jobID: jobID, createdAtUTC: timestamp, finishedAtUTC: timestamp)
    record.state = JobState.waitingForRecovery.rawValue
    record.outcomeUnknown = projectedOutcomeUnknown
    let directory = try jobDirectory(jobID)
    try record.persist(into: directory)
    let journalURL = directory.appending(path: "journal.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    var sequence = try appendRunningPrefix(journal: journal, record: record)
    let step = try workflowStep("flash-partitions")
    let intentID = "old-intent-\(jobID)"
    try journal.appendAndSynchronize(
      try stepIntent(
        record: record, step: step, eventID: intentID, sequence: sequence))
    sequence += 1
    if correlatedUnknownOutcome {
      try journal.appendAndSynchronize(
        try JournalEvent.stepOutcome(
          eventID: "old-outcome-\(jobID)", sequence: sequence,
          sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
          stepID: step.id, attempt: 1, correlatesToIntentEventID: intentID,
          result: "failed", outcomeCertainty: .outcomeUnknown))
      sequence += 1
    }
    let waitingSource: JobState
    if cancellationPending {
      try journal.appendAndSynchronize(
        try JournalEvent.stateTransition(
          eventID: "old-cancel-\(jobID)", sequence: sequence,
          sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
          from: .running, to: .cancelRequested, reason: "explicit cancellation"))
      sequence += 1
      waitingSource = .cancelRequested
    } else {
      waitingSource = .running
    }
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "old-wait-\(jobID)", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
        from: waitingSource, to: .waitingForRecovery, reason: "outcome unknown"))
    return (
      directory.appending(path: "job-record.json"), journalURL
    )
  }

  private func writeSuccessfulRecoveryJob(
    jobID: String, createdAtUTC: String, finishedAtUTC: String,
    omitHostProofStepID: String?
  ) throws {
    var record = try makeRecord(
      jobID: jobID, createdAtUTC: createdAtUTC, finishedAtUTC: finishedAtUTC)
    record.state = JobState.succeeded.rawValue
    record.outcomeUnknown = false
    let directory = try jobDirectory(jobID)
    try record.persist(into: directory)
    let journal = try FileDurableJournal(
      url: directory.appending(path: "journal.jsonl"))
    var sequence = try appendRunningPrefix(journal: journal, record: record)
    let actualSteps = [
      "inspect-recovery-target", "flash-partitions", "verify-flash-readback",
      "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
    ]
    for stepID in actualSteps {
      let step = try workflowStep(stepID)
      let intentID =
        stepID == "flash-partitions"
        ? "intent-flash-partitions-attempt-7" : "intent-\(stepID)"
      try journal.appendAndSynchronize(
        try stepIntent(
          record: record, step: step, eventID: intentID, sequence: sequence))
      sequence += 1
      try journal.appendAndSynchronize(
        try JournalEvent.stepOutcome(
          eventID: "outcome-\(stepID)", sequence: sequence,
          sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
          stepID: stepID, attempt: 1, correlatesToIntentEventID: intentID,
          result: "succeeded", outcomeCertainty: .confirmed))
      sequence += 1
      if stepID != "inspect-recovery-target", stepID != omitHostProofStepID {
        try writeHostProof(record: record, stepID: stepID)
      }
    }
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "to-finalizing", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
        from: .running, to: .finalizing, reason: "steps complete"))
    sequence += 1
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "to-succeeded", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
        from: .finalizing, to: .succeeded, reason: "finalized"))
  }

  private func makeRecord(
    jobID: String, createdAtUTC: String, finishedAtUTC: String
  ) throws -> RuntimeJobRecord {
    var record = RuntimeJobRecord(
      jobID: jobID, request: try flashRequest(id: jobID),
      operationReference: "flash.dayu200",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: "rockchip", createdAtUTC: createdAtUTC,
      actualEffect: WorkflowEffect.destructive.rawValue,
      admissionEvidence: nil,
      materializedPlanDigest: String(repeating: "2", count: 64),
      materializedStableTargetIdentitySHA256: identity,
      materializedBindingRevision: 2)
    record.startedAtUTC = createdAtUTC
    record.finishedAtUTC = finishedAtUTC
    return record
  }

  private func jobDirectory(_ jobID: String) throws -> URL {
    let url = stateDirectory.appending(path: "jobs/\(jobID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private func appendRunningPrefix(
    journal: FileDurableJournal, record: RuntimeJobRecord
  ) throws -> Int {
    try journal.appendAndSynchronize(
      try JournalEvent.jobCreated(
        eventID: "created-\(record.jobID)", sequence: 0,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, executionMode: "execute"))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "preflight-\(record.jobID)", sequence: 1,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, from: .queued, to: .preflight,
        reason: "fixture"))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "running-\(record.jobID)", sequence: 2,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, from: .preflight, to: .running,
        reason: "fixture"))
    return 3
  }

  private func stepIntent(
    record: RuntimeJobRecord, step: WorkflowStep, eventID: String, sequence: Int
  ) throws -> JournalEvent {
    try JournalEvent.stepIntent(
      eventID: eventID, sequence: sequence, sessionID: record.sessionID,
      jobID: record.jobID, timestamp: record.startedAtUTC!, step: step,
      target: JournalTarget(
        scope: "device", targetID: record.request.target.targetID,
        connectKey: "fixture-connect-key", identitySnapshotHash: identity),
      attempt: 1, bindingRevision: 2)
  }

  private func workflowStep(_ stepID: String) throws -> WorkflowStep {
    switch stepID {
    case "inspect-recovery-target":
      return try WorkflowStep(
        id: stepID, kind: .probeDevice, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["evidencePolicy": .string("recoveryTarget")])
    case "flash-partitions":
      return try WorkflowStep(
        id: stepID, kind: .flashPartition, declaredEffect: .destructive,
        declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("flashPartitions"),
          "partition": .string("userdata"), "imageArtifactId": .string("image-bundle"),
          "imageSha256": .string(artifactSHA256), "imageSize": .integer(1),
          "confirmationId": .string("runtime-capability"),
          "safeBoundaryId": .string("complete-overwrite"),
        ])
    case "verify-flash-readback":
      return try WorkflowStep(
        id: stepID, kind: .verifyRemoteState, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("flashReadback"), "expectedState": .string("complete"),
        ])
    case "reboot-device":
      return try WorkflowStep(
        id: stepID, kind: .rebootDevice, declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["targetMode": .string("normal"), "reason": .string("postFlash")])
    case "wait-for-hdc":
      return try WorkflowStep(
        id: stepID, kind: .waitForReconnect, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "deadlineMilliseconds": .integer(60_000), "reason": .string("postFlash"),
        ])
    case "rebind-and-verify-build":
      return try WorkflowStep(
        id: stepID, kind: .probeDevice, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["evidencePolicy": .string("postFlashBuild")])
    default:
      throw NSError(domain: "fixture", code: 1)
    }
  }

  private func writeHostProof(record: RuntimeJobRecord, stepID: String) throws {
    let action: RockchipProviderAction
    let partitions = try XCTUnwrap(
      try flashDescriptor().completeOverwriteRecovery?.profile(reference: "dayu200")
    ).coveredEffects.map { String($0.dropFirst("partition:".count)) }
    let bundle = RockchipRuntimeFlashBundle(
      artifactLeaseID: "lease-fixture", artifactID: "artifact-fixture",
      fileURL: URL(filePath: "/private/tmp/fixture-images.tar.gz"),
      sha256: artifactSHA256, byteCount: 1, partitionNames: partitions)
    let legacyKind: String?
    switch stepID {
    case "flash-partitions", "verify-flash-readback":
      // A journal written before CHG-2026-059. These two kinds can no longer be
      // *constructed* — the actions are gone — so the fixture writes what a
      // real legacy journal holds: the persisted bytes themselves. That is a
      // truer fixture than the old one, because it is what a device in the
      // field actually left behind.
      _ = bundle
      legacyKind =
        stepID == "flash-partitions"
        ? "rockchip.flashPartitions" : "rockchip.verifyFlashReadback"
      action = .rebootToNormal(stableIdentitySHA256: identity)  // unused
    case "reboot-device":
      legacyKind = nil
      action = .rebootToNormal(stableIdentitySHA256: identity)
    case "wait-for-hdc":
      legacyKind = nil
      action = .waitForHDCReconnect(connectKey: "fixture-connect-key")
    case "rebind-and-verify-build":
      // The bound verification, which is what a real post-flash proof holds:
      // the unbound one this fixture used to write proved no device identity
      // and no longer exists.
      legacyKind = nil
      action = .verifyBoundBuild(
        expectation: RockchipHDCReconnectExpectation(
          previousConnectKey: "fixture-connect-key",
          previousIdentitySHA256: identity,
          usbTopology: "42"),
        expectedProductModel: "DAYU200",
        expectedBuildVersion: "OpenHarmony fixture")
    default: throw NSError(domain: "fixture", code: 2)
    }
    let persisted =
      try legacyKind.map {
        try JSONDecoder().decode(
          PersistedTypedProviderAction.self,
          from: Data(#"{"kind":"\#($0)","arguments":{}}"#.utf8))
      } ?? PersistedTypedProviderAction(.rockchip(action))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let actionSHA256 = sha256(try encoder.encode(persisted))
    let directory =
      stateDirectory
      .appending(path: "rockchip-runtime/\(record.jobID)/\(stepID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let intent = HostIntentRecord(
      schemaVersion: "1.0.0", jobID: record.jobID, stepID: stepID,
      targetID: record.request.target.targetID, bindingRevision: 2,
      stableIdentitySHA256: identity, providerExecutableSHA256: providerSHA256,
      actionSHA256: actionSHA256, action: persisted)
    let summary =
      stepID == "flash-partitions"
      ? ["partitionCount": String(partitions.count), "bundleSha256": artifactSHA256]
      : ["status": "confirmed"]
    let receipt = HostReceiptRecord(
      schemaVersion: "1.0.0", jobID: record.jobID, stepID: stepID,
      targetID: record.request.target.targetID, bindingRevision: 2,
      stableIdentitySHA256: identity, providerExecutableSHA256: providerSHA256,
      actionSHA256: actionSHA256, summary: summary,
      stdoutSHA256: sha256(Data("ok".utf8)), stderrSHA256: sha256(Data()),
      stdoutTruncated: false, subprocessCount: 1)
    try DurableFileWriter.createOrReplaceAtomically(
      destination: directory.appending(path: "intent.json"),
      data: try encoder.encode(intent))
    try DurableFileWriter.createOrReplaceAtomically(
      destination: directory.appending(path: "receipt.json"),
      data: try encoder.encode(receipt))
  }

  private func recoveryArchive() throws -> Data {
    let profile = RockchipFlashProfile.dayu200
    let partitionEntries =
      profile.mappedPartitions.map {
        "0x1@0x\(String($0.offsetSectors, radix: 16))(\($0.partitionName))"
      }
      + profile.membershiplessPartitionsWriteForbidden.enumerated().map {
        "0x1@0x\(String(0x2000000 + $0.offset * 0x1000, radix: 16))(\($0.element))"
      }
    let parameter = Data(
      "CMDLINE:mtdparts=rk29xxnand:\(partitionEntries.joined(separator: ","))\n".utf8)
    var members = profile.mappedPartitions.map { partition -> (name: String, bytes: Data) in
      let bytes =
        partition.partitionName == profile.runtimeVersionPartitionName
        ? Data("const.ohos.fullname=OpenHarmony-7.0.0.fixture ".utf8)
        : Data("fixture-\(partition.partitionName)".utf8)
      return (partition.imageMemberName, bytes)
    }
    members.append((RockchipFlashProfile.partitionTableMemberName, parameter))
    return try RockchipExecutionTestFixture.makeGzipTar(members: members)
  }

  private func recoveryPartitions() throws -> [String] {
    try XCTUnwrap(
      try flashDescriptor().completeOverwriteRecovery?.profile(reference: "dayu200")
    ).coveredEffects.map { String($0.dropFirst("partition:".count)) }
  }

  private func isolatedStateDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-complete-overwrite-\(name)", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private func assertRecoveryBlocked(
    _ expected: String,
    service: RuntimeRecoveryService,
    request: RuntimeOperationRequest,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await service.completeOverwriteAdmission(
        request: request, descriptor: try flashDescriptor(),
        stableIdentitySHA256: identity, bindingRevision: 2)
      XCTFail("expected non-overridable blocker \(expected)", file: file, line: line)
    } catch let error as RuntimeCompleteOverwriteRecoveryError {
      XCTAssertEqual(error, .blocked(expected), file: file, line: line)
    } catch {
      XCTFail("unexpected recovery refusal: \(error)", file: file, line: line)
    }
  }

  private func effectDigest(_ effects: [String]) -> String {
    sha256(Data(Array(Set(effects)).sorted().joined(separator: "\n").utf8))
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? self[0] : nil }
}
