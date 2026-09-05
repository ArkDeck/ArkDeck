import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

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

  /// One ArkForge execution projected through both delegated Runtime steps.
  /// The receipt is the terminal managed-control postflight that production
  /// `ArkForgeLaneHost` exposes only after the daemon plan completes.
  private actor CompletedArkForgeLane: RuntimeJobEngine.ArkForgeLane {
    nonisolated let toolchainSHA256: String
    private let receipt: ArkForgeActionReceiptSummary
    private var started = false
    private var starts = 0
    private var prewarms = 0
    private var callOrder: [String] = []

    init(toolchainSHA256: String) {
      self.toolchainSHA256 = toolchainSHA256
      let facts = [
        ArkForgeKeyValue(key: "const.product.model", value: "DAYU200"),
        ArkForgeKeyValue(key: "const.ohos.fullname", value: "OpenHarmony-7.0.0.fixture"),
        ArkForgeKeyValue(key: "usbTopology", value: "42"),
      ]
      self.receipt = ArkForgeActionReceiptSummary(
        jobID: "JOB-RECOVERY-1", planID: "PLAN-RECOVERY-1", stepID: "STEP-023",
        actionID: "", attemptID: "", permitID: "PERMIT-RECOVERY-23",
        disposition: "semanticSuccess",
        evidenceSHA256: ArkForgeManagedControlPort.canonicalFactsDigest(
          Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0.value) })),
        verificationOutcome: "", verificationStrength: "",
        verifiedRangeStart: 0, verifiedRangeLength: 0,
        typedSkipReason: "", failureClassification: "", facts: facts)
    }

    func prewarmArtifact(
      jobID _: String, artifact: ArkForgeLaneArtifact
    ) async throws -> ArkForgeLaneArtifactPrewarmReceipt {
      prewarms += 1
      callOrder.append("prewarm")
      return ArkForgeLaneArtifactPrewarmReceipt(
        artifactSHA256: artifact.sha256, profileID: artifact.profileID,
        imported: false, durationMilliseconds: 7)
    }

    func finishArtifactPrewarm(jobID _: String) async {}

    func prepareExecution(
      jobID: String, artifact: ArkForgeLaneArtifact,
      binding: ArkForgeLaneDeviceBinding, executionPurpose: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      guard prewarms == 1 else {
        throw RuntimeDispatchFailure.failed(
          "delegated execution reached prepare before its one admitted prewarm")
      }
      if !started {
        started = true
        starts += 1
      }
      return RuntimeArkForgeLaneExecution(
        arkDeckJobID: jobID, daemonJobID: receipt.jobID,
        planID: receipt.planID, planSHA256: String(repeating: "7", count: 64),
        executionPurpose: executionPurpose,
        artifactSHA256: artifact.sha256, artifactProfileID: artifact.profileID,
        targetID: binding.targetID, bindingRevision: binding.bindingRevision,
        stableIdentitySHA256: binding.stableIdentitySHA256,
        usbTopology: binding.usbTopology, observationMode: "loader",
        toolchainSHA256: toolchainSHA256)
    }

    func performPrepared(
      stepID _: String, execution _: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      guard prewarms == 1 else {
        throw RuntimeDispatchFailure.failed(
          "delegated execution reached perform before its one admitted prewarm")
      }
      callOrder.append("perform")
      return receipt
    }

    func observeTerminal(
      execution _: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? {
      .completed(receipts: [receipt])
    }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? {
      started ? receipt : nil
    }

    func startCount() -> Int { starts }
    func prewarmCount() -> Int { prewarms }
    func calls() -> [String] { callOrder }
  }

  private actor RefusingPrewarmArkForgeLane: RuntimeJobEngine.ArkForgeLane {
    private struct StoreUnavailable: Error, CustomStringConvertible {
      var description: String { "fixture ArkForge content store unavailable" }
    }

    nonisolated let toolchainSHA256: String
    private var prewarms = 0
    private var performs = 0

    init(toolchainSHA256: String) {
      self.toolchainSHA256 = toolchainSHA256
    }

    func prewarmArtifact(
      jobID _: String, artifact _: ArkForgeLaneArtifact
    ) async throws -> ArkForgeLaneArtifactPrewarmReceipt {
      prewarms += 1
      throw StoreUnavailable()
    }

    func finishArtifactPrewarm(jobID _: String) async {}

    func prepareExecution(
      jobID _: String, artifact _: ArkForgeLaneArtifact,
      binding _: ArkForgeLaneDeviceBinding, executionPurpose _: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      performs += 1
      throw RuntimeDispatchFailure.failed("prepare must not follow a refused prewarm")
    }

    func performPrepared(
      stepID _: String, execution _: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      performs += 1
      throw RuntimeDispatchFailure.failed("perform must not follow a refused prewarm")
    }

    func observeTerminal(
      execution _: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? { nil }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? { nil }
    func counts() -> (prewarms: Int, performs: Int) { (prewarms, performs) }
  }

  /// Two process generations around the receipt-loss window. Generation one
  /// creates the exact daemon job then loses its terminal; generation two can
  /// only observe that persisted job and intentionally exposes no in-memory
  /// completed-receipt cache.
  private actor RestartingArkForgeLane: RuntimeJobEngine.ArkForgeLane {
    enum Mode { case loseTerminal, observeCompletion }

    nonisolated let toolchainSHA256: String
    private let mode: Mode
    private let stateDirectory: URL?
    private let receipt: ArkForgeActionReceiptSummary
    private var prepares = 0
    private var sawDurableJoinBeforePerform = false

    init(toolchainSHA256: String, mode: Mode, stateDirectory: URL? = nil) {
      self.toolchainSHA256 = toolchainSHA256
      self.mode = mode
      self.stateDirectory = stateDirectory
      let facts = [
        ArkForgeKeyValue(key: "const.product.model", value: "DAYU200"),
        ArkForgeKeyValue(key: "const.ohos.fullname", value: "OpenHarmony-7.0.0.fixture"),
        ArkForgeKeyValue(key: "usbTopology", value: "42"),
      ]
      self.receipt = ArkForgeActionReceiptSummary(
        jobID: "JOB-RESTART-1", planID: "PLAN-RESTART-1", stepID: "STEP-023",
        actionID: "", attemptID: "", permitID: "PERMIT-RESTART-23",
        disposition: "semanticSuccess",
        evidenceSHA256: ArkForgeManagedControlPort.canonicalFactsDigest(
          Dictionary(uniqueKeysWithValues: facts.map { ($0.key, $0.value) })),
        verificationOutcome: "", verificationStrength: "",
        verifiedRangeStart: 0, verifiedRangeLength: 0,
        typedSkipReason: "", failureClassification: "", facts: facts)
    }

    func prewarmArtifact(
      jobID _: String, artifact: ArkForgeLaneArtifact
    ) async throws -> ArkForgeLaneArtifactPrewarmReceipt {
      ArkForgeLaneArtifactPrewarmReceipt(
        artifactSHA256: artifact.sha256, profileID: artifact.profileID,
        imported: false, durationMilliseconds: 0)
    }

    func finishArtifactPrewarm(jobID _: String) async {}

    func prepareExecution(
      jobID: String, artifact: ArkForgeLaneArtifact,
      binding: ArkForgeLaneDeviceBinding, executionPurpose: String
    ) async throws -> RuntimeArkForgeLaneExecution {
      prepares += 1
      return RuntimeArkForgeLaneExecution(
        arkDeckJobID: jobID, daemonJobID: receipt.jobID,
        planID: receipt.planID, planSHA256: String(repeating: "7", count: 64),
        executionPurpose: executionPurpose,
        artifactSHA256: artifact.sha256, artifactProfileID: artifact.profileID,
        targetID: binding.targetID, bindingRevision: binding.bindingRevision,
        stableIdentitySHA256: binding.stableIdentitySHA256,
        usbTopology: binding.usbTopology, observationMode: "loader",
        toolchainSHA256: toolchainSHA256)
    }

    func performPrepared(
      stepID: String, execution: RuntimeArkForgeLaneExecution,
      artifact _: ArkForgeLaneArtifact, binding _: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary {
      if let stateDirectory {
        let directory = stateDirectory.appending(
          path: "jobs/\(execution.arkDeckJobID)", directoryHint: .isDirectory)
        let arkForgeState = try ArkForgeRuntimeJobState.load(from: directory)
        let replay = try DurableJournalRecovery.inspect(
          url: directory.appending(path: "journal.jsonl"))
        sawDurableJoinBeforePerform =
          arkForgeState.execution == execution
          && replay.outstandingIntents.contains(where: { $0.stepID == stepID })
      }
      throw RuntimeDispatchFailure.outcomeUnknown(
        "fixture lost the controller after the daemon accepted the exact job")
    }

    func observeTerminal(
      execution _: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome? {
      mode == .observeCompletion ? .completed(receipts: [receipt]) : nil
    }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? {
      nil
    }

    func prepareCount() -> Int { prepares }
    func observedDurableJoinBeforePerform() -> Bool { sawDurableJoinBeforePerform }
  }

  private struct RecoveryFactsPort: RockchipRuntimeFactsPort {
    let identity: String
    let toolSHA256: String
    var crossModeBinding = TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "arkforge", toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
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

  func testCanonicalAndDAYU200AliasMaterializeTheSameArkForgePlan() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-alias-parity-input", sessionID: "session-alias-parity-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: try recoveryArchive()))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let lane = CompletedArkForgeLane(toolchainSHA256: providerSHA256)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory,
        arkForgeLane: lane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
          factsPort: RecoveryFactsPort(identity: identity, toolSHA256: providerSHA256),
          availability: .available)
      ]),
      dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let alias = try flashRequest(id: "alias-parity", lease: lease)
    let canonical = try RuntimeOperationRequest(
      requestID: alias.requestID, idempotencyKey: alias.idempotencyKey,
      target: alias.target,
      operation: RuntimeOperationReference(id: "flash.full-restore", version: 1),
      inputs: [
        "artifactLease": .string(lease),
        "deviceProfileRef": .string("dayu200"),
        "intent": .string("fullRestore"),
        "verification": .string("full"),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let aliasPreview = try await engine.planOnly(encoder.encode(alias))
    let canonicalPreview = try await engine.planOnly(encoder.encode(canonical))

    XCTAssertEqual(aliasPreview.operationReference, "flash.dayu200")
    XCTAssertEqual(canonicalPreview.operationReference, "flash.full-restore@1")
    XCTAssertEqual(aliasPreview.providerID, "arkforge")
    XCTAssertEqual(aliasPreview.materializedPlanDigest, canonicalPreview.materializedPlanDigest)
    XCTAssertEqual(aliasPreview.steps, canonicalPreview.steps)
    XCTAssertEqual(aliasPreview.effectiveEffect, canonicalPreview.effectiveEffect)
    XCTAssertEqual(aliasPreview.authorizationPolicy, canonicalPreview.authorizationPolicy)
    XCTAssertEqual(aliasPreview.providerAdmissionBlocker, canonicalPreview.providerAdmissionBlocker)
    let dispatches = await dispatchLog.snapshot()
    let capabilities = try await capabilityStore.list()
    XCTAssertEqual(dispatches, [])
    XCTAssertEqual(capabilities, [])
    let planOnlyPrewarms = await lane.prewarmCount()
    XCTAssertEqual(planOnlyPrewarms, 0, "planOnly must not populate ArkForge's store")
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

  func testCompleteLaterFlashHistoryAppendsSupersessionWithoutChangingUnknownJobs() async throws {
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
      finishedAtUTC: "2026-08-08T00:20:00Z", omitSemanticReceiptStepID: nil)

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
      omitSemanticReceiptStepID: "rebind-and-verify-build")

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

  func testCapabilityOnlyUnknownUsesTheFullTypedPartitionPlanAsPossibleEffects()
    async throws
  {
    let store = try await writeCapabilityOnlyUnknownJob(
      jobID: "job-capability-only-unknown", persistJobRecord: true)

    let admission = try await RuntimeRecoveryService(
      stateDirectory: stateDirectory, capabilityStore: store,
      nowUTC: { "2026-08-08T01:00:00Z" }
    ).completeOverwriteAdmission(
      request: try flashRequest(id: "capability-only-recovery"),
      descriptor: try flashDescriptor(), stableIdentitySHA256: identity,
      bindingRevision: 2)

    let covered = try XCTUnwrap(admission.recoveryContext?.coveredIntents.only)
    XCTAssertEqual(covered.jobID, "job-capability-only-unknown")
    XCTAssertTrue(covered.intentEventID.hasPrefix("capability-CAP-RT-RECOVERY-UNKNOWN-use-1"))
    XCTAssertEqual(
      covered.possibleEffects,
      try recoveryPartitions().map { "partition:\($0)" })
    XCTAssertNil(admission.recognizedEpoch)
  }

  func testCapabilityOnlyUnknownWithoutAnExactDurableJobRecordFailsClosed()
    async throws
  {
    let store = try await writeCapabilityOnlyUnknownJob(
      jobID: "job-capability-record-missing", persistJobRecord: false)

    await assertRecoveryBlocked(
      "completeOverwriteRecovery.unboundedCapabilityLineage",
      service: RuntimeRecoveryService(
        stateDirectory: stateDirectory, capabilityStore: store,
        nowUTC: { "2026-08-08T01:00:00Z" }),
      request: try flashRequest(id: "missing-capability-record"))
  }

  func testCleanRunningArkForgeExecutionParksUnknownWithoutRedispatch() async throws {
    // The ArkForge daemon job and its completed-plan receipt cache live in the
    // lane actor, not the Runtime journal. A restart after materialization can
    // therefore look journal-clean while an external execution did start.
    // Recreating the actor and resuming would be a destructive replay.
    let jobID = "job-clean-delegated-execution"
    let timestamp = "2026-08-08T00:00:00Z"
    var record = try makeRecord(
      jobID: jobID, createdAtUTC: timestamp, finishedAtUTC: timestamp)
    record.state = JobState.running.rawValue
    record.finishedAtUTC = nil
    record.timeline.append("capability consumed before first mutation")
    let directory = try jobDirectory(jobID)
    try record.persist(into: directory)
    let journalURL = directory.appending(path: "journal.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    _ = try appendRunningPrefix(
      journal: journal, record: record,
      schemaVersion: JournalEvent.schemaVersion)

    let recovered = try await recoveryService().replay(
      RuntimePersistedJob(
        jobID: jobID, idempotencyKey: record.request.idempotencyKey,
        requestHash: String(repeating: "f", count: 64),
        state: JobState.running.rawValue, createdAtUTC: timestamp,
        updatedAtUTC: timestamp, version: 1, initialRecordData: nil))

    XCTAssertEqual(recovered.record.state, JobState.waitingForRecovery.rawValue)
    XCTAssertTrue(recovered.record.outcomeUnknown)
    XCTAssertEqual(recovered.record.operationFailure?.code, .outcomeUnknown)
    XCTAssertEqual(recovered.record.finishedAtUTC, "2026-08-08T01:00:00Z")
    XCTAssertTrue(
      recovered.record.timeline.contains(
        "recovered: ArkForge execution state was process-owned; parked unknown; no redispatch"))
    let replay = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertEqual(replay.currentState, .waitingForRecovery)
    XCTAssertTrue(replay.outstandingIntents.isEmpty)
    XCTAssertTrue(replay.unknownOutcomes.isEmpty)
    XCTAssertTrue(
      replay.events.contains {
        $0.kind == .stateTransition
          && $0.stateTransition?.from == .running
          && $0.stateTransition?.to == .waitingForRecovery
      })
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
    // A current Runtime creates its admission index before any durable intent.
    _ = try RuntimeJobRepository(stateDirectory: stateDirectory)
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
    let lane = CompletedArkForgeLane(toolchainSHA256: providerSHA256)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory, arkForgeLane: lane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
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
    let admittedPrewarms = await lane.prewarmCount()
    XCTAssertEqual(
      admittedPrewarms, 0,
      "submit may admit the Job but prewarm starts only when the admitted Job is run")
    let issued = try await capabilityStore.list()
    XCTAssertEqual(issued.count, 1)
    XCTAssertEqual(issued.first?.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(issued.first?.consumptionCount, 0)

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, JobState.recovered.rawValue)
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertFalse(status.waitingForHuman)
    XCTAssertNotNil(status.recoveryEpochID)
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    let observation = try XCTUnwrap(evidence.observation)
    XCTAssertEqual(observation.targetID, "TGT-DAYU200-RECOVERY")
    XCTAssertEqual(observation.bindingRevision, 2)
    XCTAssertEqual(observation.stableIdentitySHA256, identity)
    XCTAssertEqual(observation.model, "DAYU200")
    XCTAssertEqual(observation.firmware, "OpenHarmony-7.0.0.fixture")
    XCTAssertEqual(observation.transport, "usb")
    XCTAssertEqual(observation.providerID, "arkforge")
    XCTAssertEqual(observation.toolVersion, ArkForgeNativeRockUSBToolchain.reportedVersion)
    XCTAssertEqual(observation.toolSHA256, providerSHA256)
    XCTAssertEqual(observation.confirmationMethod, "machineReadback")
    XCTAssertEqual(evidence.firstEvidenceStepAtUTC, observation.confirmedAtUTC)
    XCTAssertTrue(
      Set(evidence.actualStepKinds).isSuperset(of: [
        "flashPartition", "verifyRemoteState", "rebootDevice", "waitForReconnect",
        "probeDevice",
      ]),
      "persisted Flash evidence must project every confirmed mandatory WAL step kind")
    XCTAssertEqual(try Data(contentsOf: old.recordURL), originalRecord)
    XCTAssertEqual(try Data(contentsOf: old.journalURL), originalJournal)
    let recoveryDirectory =
      stateDirectory
      .appending(path: "jobs/\(acceptance.jobID)", directoryHint: .isDirectory)
    let recoveryJournalURL = recoveryDirectory.appending(path: "journal.jsonl")
    let recoveryReplay = try DurableJournalRecovery.inspect(url: recoveryJournalURL)
    XCTAssertEqual(
      recoveryReplay.schemaVersion, JournalEvent.schemaVersion)
    XCTAssertTrue(
      recoveryReplay.events.allSatisfy {
        $0.schemaVersion == JournalEvent.schemaVersion
      })
    let requiredRecoverySteps = [
      "flash-partitions", "verify-flash-readback", "reboot-device", "wait-for-hdc",
      "rebind-and-verify-build",
    ]
    for stepID in requiredRecoverySteps {
      XCTAssertTrue(
        recoveryReplay.events.contains {
          $0.kind == .stepOutcome && $0.stepID == stepID
            && $0.payload["result"] == .string("succeeded")
            && $0.payload["outcomeCertainty"] == .string("confirmed")
            && $0.payload["semanticCode"]
              == .string(RuntimeJobEngine.arkForgePlanCompletionSemanticCode)
        },
        "\(stepID) must retain the typed ArkForge completion proof used by epoch finalization")
    }
    XCTAssertThrowsError(
      try JournalEvent.stateTransition(
        eventID: "legacy-recovery-edge", sequence: 0,
        sessionID: "session-legacy", jobID: "job-legacy",
        timestamp: "2026-08-08T01:00:00Z",
        from: .running, to: .recoveringByCompleteOverwrite,
        reason: "retired format must be refused",
        schemaVersion: "3.0.0"))

    let dispatches = await dispatchLog.snapshot()
    XCTAssertEqual(dispatches.filter { $0 == "flash-partitions" }.count, 0)
    XCTAssertEqual(dispatches.filter { $0 == "enter-loader-mode" }.count, 0)
    let laneStarts = await lane.startCount()
    XCTAssertEqual(laneStarts, 1)
    let lanePrewarms = await lane.prewarmCount()
    let laneCalls = await lane.calls()
    XCTAssertEqual(lanePrewarms, 1)
    XCTAssertEqual(
      laneCalls, ["prewarm", "perform"],
      "one prewarm and one correlated drive feed both logical delegated-step projections")
    XCTAssertTrue(
      status.timeline.contains("ArkForge artifact prewarm started after durable admission"))
    let prewarmReady = try XCTUnwrap(
      status.timeline.first {
        $0.hasPrefix("ArkForge artifact prewarm ready (store-hit, total 7 ms, consume wait ")
      })
    let prewarmStartedIndex = try XCTUnwrap(
      status.timeline.firstIndex(of: "ArkForge artifact prewarm started after durable admission"))
    let hostVerificationIndex = try XCTUnwrap(
      status.timeline.firstIndex(of: "host-step verify-image-bundle"))
    let prewarmReadyIndex = try XCTUnwrap(status.timeline.firstIndex(of: prewarmReady))
    XCTAssertLessThan(prewarmStartedIndex, hostVerificationIndex)
    XCTAssertLessThan(
      hostVerificationIndex, prewarmReadyIndex,
      "host-only verification runs inside the archive-prewarm overlap window")
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

  func testRestartReconcilesTheExactDaemonTerminalWithoutStartingOrUsingActorCache() async throws {
    _ = try RuntimeJobRepository(stateDirectory: stateDirectory)
    _ = try writeUnknownJob(
      jobID: "job-original-for-daemon-restart", timestamp: "2026-08-08T00:00:00Z",
      correlatedUnknownOutcome: false)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-restart-input", sessionID: "session-restart-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: try recoveryArchive()))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let firstLane = RestartingArkForgeLane(
      toolchainSHA256: providerSHA256, mode: .loseTerminal,
      stateDirectory: stateDirectory)
    let registry = DeviceProviderRegistry(providers: [
      ArkForgeFlashProviderAdapter(
        factsPort: RecoveryFactsPort(identity: identity, toolSHA256: providerSHA256),
        availability: .available)
    ])
    let firstEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory, arkForgeLane: firstLane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: registry, dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let accepted = try await firstEngine.submit(
      encoder.encode(try flashRequest(id: "daemon-restart", lease: lease)))

    let unknown = try await firstEngine.run(jobID: accepted.jobID)
    XCTAssertEqual(unknown.state, JobState.waitingForRecovery.rawValue)
    XCTAssertTrue(unknown.outcomeUnknown)
    let firstPrepareCount = await firstLane.prepareCount()
    XCTAssertEqual(firstPrepareCount, 1)
    let durableBeforePerform = await firstLane.observedDurableJoinBeforePerform()
    XCTAssertTrue(
      durableBeforePerform,
      "Runtime must persist correlation and step intent before the permit-capable call")
    let jobDirectory = stateDirectory.appending(
      path: "jobs/\(accepted.jobID)", directoryHint: .isDirectory)
    let persistedBeforeRestart = try ArkForgeRuntimeJobState.load(from: jobDirectory)
    XCTAssertEqual(
      persistedBeforeRestart.execution?.daemonJobID, "JOB-RESTART-1")
    XCTAssertNil(persistedBeforeRestart.planCompletionReceipt)

    let recoveredLane = RestartingArkForgeLane(
      toolchainSHA256: providerSHA256, mode: .observeCompletion)
    let recoveredEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory, arkForgeLane: recoveredLane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: registry, dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:01Z" })
    _ = try await recoveredEngine.recoverActiveJobs()

    let reconciled = try await recoveredEngine.reconcile(jobID: accepted.jobID)
    XCTAssertEqual(reconciled.state, JobState.resumeAtConfirmedSafeBoundary.rawValue)
    XCTAssertFalse(reconciled.outcomeUnknown)
    let recoveredPrepareCount = await recoveredLane.prepareCount()
    XCTAssertEqual(
      recoveredPrepareCount, 0,
      "a fresh process must observe the persisted daemon job, not prepare another")
    let persistedAfterReconcile = try ArkForgeRuntimeJobState.load(from: jobDirectory)
    XCTAssertEqual(
      persistedAfterReconcile.planCompletionReceipt?.jobID, "JOB-RESTART-1")

    let completed = try await recoveredEngine.run(jobID: accepted.jobID)
    XCTAssertEqual(
      completed.state, JobState.recovered.rawValue,
      "timeline: \(completed.timeline.joined(separator: " | "))")
    let replay = try DurableJournalRecovery.inspect(
      url: jobDirectory.appending(path: "journal.jsonl"))
    XCTAssertEqual(
      replay.events.filter {
        $0.kind == .stepIntent && $0.stepID == "flash-partitions"
      }.count, 1)
    XCTAssertTrue(
      replay.events.contains {
        $0.kind == .stepOutcome && $0.stepID == "flash-partitions"
          && $0.payload["semanticCode"]
            == .string(RuntimeJobEngine.arkForgePlanCompletionSemanticCode)
      })
  }

  func testUnpreparedCrossModeBindingRejectsBeforeCapabilityAndDispatch() async throws {
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
    let lane = CompletedArkForgeLane(toolchainSHA256: providerSHA256)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory, arkForgeLane: lane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
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

  func testPrewarmFailureIsConfirmedBeforeCapabilityConsumptionOrDeviceDispatch() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-08T01:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-prewarm-failure-input", sessionID: "session-prewarm-failure-input",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-RECOVERY", bindingRevision: 2,
          stableIdentitySHA256: identity),
        contents: try recoveryArchive()))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let lane = RefusingPrewarmArkForgeLane(toolchainSHA256: providerSHA256)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory, arkForgeLane: lane,
        arkForgeDeviceProfileID: "org.openharmony.dayu200@1.0.0"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
          factsPort: RecoveryFactsPort(identity: identity, toolSHA256: providerSHA256),
          availability: .available)
      ]),
      dispatcher: ConfirmingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-08T01:00:00Z" })
    let request = try flashRequest(id: "prewarm-failure", lease: lease)
    let acceptance = try await engine.submit(JSONEncoder().encode(request))
    let capabilitiesBeforeRun = try await capabilityStore.list()
    let beforeRun = try XCTUnwrap(capabilitiesBeforeRun.only)
    XCTAssertEqual(beforeRun.consumptionCount, 0)

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, JobState.failed.rawValue)
    XCTAssertTrue(
      status.timeline.contains {
        $0.contains("artifact prewarm failed before capability consumption")
      })
    XCTAssertFalse(status.timeline.contains { $0.contains("artifact prewarm ready") })
    let counts = await lane.counts()
    XCTAssertEqual(counts.prewarms, 1)
    XCTAssertEqual(counts.performs, 0)
    let dispatches = await dispatchLog.snapshot()
    XCTAssertTrue(dispatches.isEmpty)
    let capabilitiesAfterRun = try await capabilityStore.list()
    let afterRun = try XCTUnwrap(capabilitiesAfterRun.only)
    XCTAssertEqual(afterRun.consumptionCount, 0)
  }

  func testSupersededUnknownPresentationIsTruthfulButNoLongerNeedsAttention() throws {
    let epochID = "recovery-epoch-0123456789abcdef0123456789abcdef"
    let data = try currentJobPageResponse([[
      "jobId": "job-old", "operation": "flash.dayu200", "targetId": "target-1",
      "state": "waitingForRecovery", "waitingForHuman": false, "outcomeUnknown": true,
      "outstandingResidueCount": 0, "timeline": [], "supersededByRecoveryEpochId": epochID,
    ]])
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
    capabilityID: String? = nil,
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
      ], authorization: capabilityID.map { RuntimeCapabilityReference(capabilityID: $0) })
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

  private func writeCapabilityOnlyUnknownJob(
    jobID: String, persistJobRecord: Bool
  ) async throws -> RuntimeCapabilityStore {
    let timestamp = "2026-08-08T00:00:00Z"
    let request = try flashRequest(id: jobID)
    let planDigest = String(repeating: "2", count: 64)
    if persistJobRecord {
      var record = try makeRecord(
        jobID: jobID, createdAtUTC: timestamp, finishedAtUTC: timestamp)
      record.state = JobState.waitingForRecovery.rawValue
      record.outcomeUnknown = true
      let directory = try jobDirectory(jobID)
      try record.persist(into: directory)
      let journal = try FileDurableJournal(
        url: directory.appending(path: "journal.jsonl"))
      let sequence = try appendRunningPrefix(journal: journal, record: record)
      try journal.appendAndSynchronize(
        try JournalEvent.stateTransition(
          eventID: "capability-only-wait-\(jobID)", sequence: sequence,
          sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
          from: .running, to: .waitingForRecovery,
          reason: "capability outcome unknown before a typed step intent was durable"))
    }

    let artifactFacts = ["imageBundleSha256": artifactSHA256]
    let store = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(
        path: "capabilities", directoryHint: .isDirectory))
    try await store.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-RECOVERY-UNKNOWN",
        targetScope: .stablePhysicalIdentity(sha256: identity),
        operationScope: [
          .init(
            operationID: "flash.dayu200",
            version: try flashDescriptor().version)
        ],
        effectCeiling: .destructive,
        exactInputs: request.inputs,
        exactArtifactFacts: artifactFacts,
        issuedAtUTC: timestamp,
        expiresAtUTC: "2026-08-08T04:00:00Z",
        maximumUses: 1,
        issuer: .init(
          kind: .runtimeDefaultPolicy,
          reference: "catalog:flash.dayu200"),
        exactPlanDigest: planDigest,
        exactBindingRevision: 2))
    let query = RuntimeCapabilityAuthorizationQuery(
      operationID: "flash.dayu200",
      operationVersion: try flashDescriptor().version,
      effect: .destructive,
      targetStableIdentitySHA256: identity,
      targetBindingRevision: 2,
      planDigest: planDigest,
      inputs: request.inputs,
      artifactFacts: artifactFacts)
    _ = try await store.consume(
      capabilityID: "CAP-RT-RECOVERY-UNKNOWN",
      reservationID: "reservation-capability-only-unknown",
      jobID: jobID,
      query: query,
      nowUTC: timestamp)
    try await store.recordOutcome(
      capabilityID: "CAP-RT-RECOVERY-UNKNOWN",
      reservationID: "reservation-capability-only-unknown",
      jobID: jobID,
      outcome: .outcomeUnknown,
      terminalState: JobState.waitingForRecovery.rawValue,
      atUTC: "2026-08-08T00:01:00Z")
    return store
  }

  private func writeSuccessfulRecoveryJob(
    jobID: String, createdAtUTC: String, finishedAtUTC: String,
    omitSemanticReceiptStepID: String?
  ) throws {
    var record = try makeRecord(
      jobID: jobID, createdAtUTC: createdAtUTC, finishedAtUTC: finishedAtUTC,
      capabilityID: "CAP-RT-HISTORICAL-FLASH")
    record.originalSubmissionRequest = record.request
    record.state = JobState.succeeded.rawValue
    record.outcomeUnknown = false
    var admission = RuntimeAdmissionEvidence(
      kind: .runtimeCapability, reference: "CAP-RT-HISTORICAL-FLASH",
      admittedAtUTC: createdAtUTC, validUntilUTC: "2026-12-31T00:00:00Z",
      consumptionFingerprintSHA256: String(repeating: "a", count: 64),
      runtimeCapabilityCorrelation: RuntimeCapabilityEvidenceCorrelation(
        reservationID: record.request.idempotencyKey, useOrdinal: 1,
        planDigestSHA256: String(repeating: "2", count: 64),
        stepSetDigestSHA256: String(repeating: "3", count: 64),
        targetBindingDigestSHA256: RuntimeJobRecord.sha256Hex(Data("\(identity)\n2".utf8)),
        artifactSHA256: artifactSHA256))
    admission.recoveryProviderExecutableSHA256 = providerSHA256
    record.admissionEvidence = admission
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
          result: "succeeded", outcomeCertainty: .confirmed,
          semanticCode: stepID == omitSemanticReceiptStepID
            ? nil : RuntimeJobEngine.arkForgePlanCompletionSemanticCode,
          summary: stepID == omitSemanticReceiptStepID
            ? nil
            : "arkforge-plan=PLAN-HISTORICAL; daemon-job=JOB-HISTORICAL; "
              + "terminal-step=STEP-023; evidence-sha256=\(String(repeating: "b", count: 64))"))
      sequence += 1
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
    jobID: String, createdAtUTC: String, finishedAtUTC: String, capabilityID: String? = nil
  ) throws -> RuntimeJobRecord {
    var record = RuntimeJobRecord(
      jobID: jobID, request: try flashRequest(id: jobID, capabilityID: capabilityID),
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
    journal: FileDurableJournal, record: RuntimeJobRecord,
    schemaVersion: String = JournalEvent.schemaVersion
  ) throws -> Int {
    try journal.appendAndSynchronize(
      try JournalEvent.jobCreated(
        eventID: "created-\(record.jobID)", sequence: 0,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, executionMode: "execute",
        schemaVersion: schemaVersion))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "preflight-\(record.jobID)", sequence: 1,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, from: .queued, to: .preflight,
        reason: "fixture", schemaVersion: schemaVersion))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "running-\(record.jobID)", sequence: 2,
        sessionID: record.sessionID, jobID: record.jobID,
        timestamp: record.createdAtUTC, from: .preflight, to: .running,
        reason: "fixture", schemaVersion: schemaVersion))
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

  private func recoveryArchive() throws -> Data {
    let profile = RockchipFlashProfile.dayu200
    let partitionEntries =
      profile.mappedPartitions.enumerated().map {
        "0x1@0x\(String(($0.offset + 1) * 0x2000, radix: 16))(\($0.element.partitionName))"
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
    return try GzipTarTestArchive.makeGzipTar(members: members)
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
