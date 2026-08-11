// Typed PROPOSE_PATCH contracts at the human boundary (TASK-HFA-005), and
// the external producer lane over the same boundary: `task.context` export
// plus the closed producer label set.

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime

private actor HumanPatchJobPort: HarnessRuntimeJobPort {
  private var rejectAuthorization: Bool
  private var submittedRequests: [RuntimeOperationRequest] = []
  private var ordinal = 1

  init(rejectAuthorization: Bool = false) {
    self.rejectAuthorization = rejectAuthorization
  }

  func acceptAuthorization() { rejectAuthorization = false }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submittedRequests.append(request)
    guard !rejectAuthorization else {
      throw HarnessJobPortError.rejected("authorization required")
    }
    let jobID = "JOB-HUMAN-PATCH-\(ordinal)"
    ordinal += 1
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["running"])
  }

  func requestCancel(jobID: String) async throws {}

  func requests() -> [RuntimeOperationRequest] { submittedRequests }
}

private actor DeduplicatingHumanPatchJobPort: HarnessRuntimeJobPort {
  private var acceptedByKey: [String: String] = [:]
  private var submittedRequests: [RuntimeOperationRequest] = []

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submittedRequests.append(request)
    if let jobID = acceptedByKey[request.idempotencyKey] {
      return HarnessJobAcceptance(jobID: jobID, deduplicated: true)
    }
    acceptedByKey[request.idempotencyKey] = "JOB-HUMAN-PATCH-DEDUP"
    throw HarnessJobPortError.transportFailure("answer lost after engine acceptance")
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["running"])
  }

  func requestCancel(jobID: String) async throws {}

  func requests() -> [RuntimeOperationRequest] { submittedRequests }
}

private actor CheckpointSequenceJobPort: HarnessRuntimeJobPort {
  private let checkpointOutcomeUnknown: Bool
  private var submittedRequests: [RuntimeOperationRequest] = []
  private var requestsByJobID: [String: RuntimeOperationRequest] = [:]

  init(checkpointOutcomeUnknown: Bool = false) {
    self.checkpointOutcomeUnknown = checkpointOutcomeUnknown
  }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submittedRequests.append(request)
    let jobID = "JOB-HUMAN-SEQUENCE-\(submittedRequests.count)"
    requestsByJobID[jobID] = request
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    guard let request = requestsByJobID[jobID] else {
      throw HarnessJobPortError.unknownJob(jobID)
    }
    if request.operation.reference == DebugCrashTaskHandler.createCheckpoint {
      return HarnessJobObservation(
        jobID: jobID,
        state: checkpointOutcomeUnknown ? "outcomeUnknown" : "succeeded",
        isTerminal: true, succeeded: !checkpointOutcomeUnknown,
        outcomeUnknown: checkpointOutcomeUnknown, waitingForHuman: false,
        timeline: ["checkpoint terminal"])
    }
    return HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["running"])
  }

  func requestCancel(jobID: String) async throws {}

  func requests() -> [RuntimeOperationRequest] { submittedRequests }
}

private actor HumanPatchRepairPort: HarnessRepairPort {
  private var prepareCount = 0

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    prepareCount += 1
    return HarnessPreparedPatch(
      inputs: [
        "projectRef": .string(projectRef),
        "patchArtifactRef": .string("lease-v1:patch:ART-human-patch"),
        "allowedFileGlobs": .array(proposal.touchedFiles.map(JSONValue.string)),
      ],
      artifactLease: "lease-v1:patch:ART-human-patch")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    HarnessAppliedPatchReadback(
      patchAttemptRef: "patch-human", patchRevision: String(repeating: "a", count: 64))
  }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    HarnessBuildReadback(
      sourceRevision: String(repeating: "a", count: 64),
      outputDigest: String(repeating: "b", count: 64),
      outputArtifactLease: "lease-v1:build:ART-human-build")
  }

  func deployedArtifactDigest(jobID: String) async throws -> String {
    String(repeating: "b", count: 64)
  }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback { .stillUnknown }

  func preparations() -> Int { prepareCount }
}

private actor HumanPatchGrant: HarnessCapabilityPort {
  private var covered: Set<String>

  init(enabled: Bool) {
    covered = enabled
      ? [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch] : []
  }

  func setEnabled(_ value: Bool) {
    covered = value
      ? [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch] : []
  }

  func setCovered(_ operations: Set<String>) { covered = operations }

  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    covered.contains(operationReference)
  }

  func standingCapabilityID(
    operationReference: String, targetID: String,
    expectedBindingRevision: Int?, inputs: [String: JSONValue]
  ) async -> String? {
    covered.contains(operationReference)
      ? "CAP-RT-WORKSPACE-HUMAN-PATCH" : nil
  }
}

final class HarnessHumanPatchContractTests: XCTestCase {
  private var rootURL: URL!
  private let now = "2026-07-31T01:00:00Z"
  private let taskID = "HTASK-0123456789AB"

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-human-patch-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  func testProposalDispatchesOnlyThroughPreparedTypedInputs() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    let blocked = try await coordinator.reconcile(taskID)
    XCTAssertEqual(blocked.action, .stoppedForHuman)
    XCTAssertEqual(blocked.reasonCode, "patchProposalRequired")

    let outcome = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let requests = await jobs.requests()
    let storedCheckpoint = try await store.decision(taskID, round: 2)
    let storedApply = try await store.decision(taskID, round: 3)
    let prepareCount = await repair.preparations()
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(outcome.snapshot.phase, .patching)
    XCTAssertEqual(outcome.snapshot.consumedBudget.modelCalls, 0)
    XCTAssertEqual(outcome.snapshot.consumedBudget.e1Mutations, 1)
    XCTAssertEqual(prepareCount, 1)
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(
      requests[0].operation.reference, DebugCrashTaskHandler.createCheckpoint)
    XCTAssertEqual(
      requests[0].authorization?.capabilityID, "CAP-RT-WORKSPACE-HUMAN-PATCH")
    XCTAssertEqual(
      requests[0].inputs["expectedWorkspaceRevision"],
      .string(proposal.baseWorkspaceRevision))
    XCTAssertEqual(
      requests[0].inputs["checkpointFilePaths"],
      .array(proposal.touchedFiles.map(JSONValue.string)))
    XCTAssertEqual(
      storedApply?.inputs["patchArtifactRef"],
      .string("lease-v1:patch:ART-human-patch"))
    XCTAssertNil(requests[0].inputs["patchArtifactRef"])
    XCTAssertEqual(storedCheckpoint?.producer, HarnessTaskCoordinator.humanPatchProducer)
    XCTAssertEqual(storedCheckpoint?.patchProposal, proposal)
    XCTAssertEqual(storedApply?.producer, HarnessTaskCoordinator.humanPatchProducer)
    XCTAssertEqual(storedApply?.patchProposal, proposal)
  }

  func testCheckpointSuccessDispatchesPreparedApplyAsTheNextActionRun() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = CheckpointSequenceJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    let checkpoint = try await coordinator.proposePatch(
      taskID, proposalJSON: proposalJSON(proposal))
    XCTAssertEqual(checkpoint.action, .dispatched)
    XCTAssertEqual(checkpoint.snapshot.consumedBudget.e1Mutations, 1)

    let applied = try await coordinator.reconcile(taskID)
    let requests = await jobs.requests()
    let prepareCount = await repair.preparations()
    let attempts = try await store.attempts(taskID)
    XCTAssertEqual(applied.action, .dispatched)
    XCTAssertEqual(applied.snapshot.phase, .patching)
    XCTAssertEqual(applied.snapshot.consumedBudget.e1Mutations, 2)
    XCTAssertEqual(applied.snapshot.repairAttempt?.checkpointJobID, "JOB-HUMAN-SEQUENCE-1")
    XCTAssertNil(applied.snapshot.repairAttempt?.patchAttemptRef)
    XCTAssertEqual(
      requests.map(\.operation.reference),
      [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch])
    XCTAssertNil(requests[0].inputs["patchArtifactRef"])
    XCTAssertEqual(
      requests[1].inputs["patchArtifactRef"],
      .string("lease-v1:patch:ART-human-patch"))
    XCTAssertEqual(prepareCount, 1)
    XCTAssertEqual(attempts.last?.actionRunIDs.count, 2)
  }

  func testCheckpointOutcomeUnknownStopsBeforeApplyWithoutReplay() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = CheckpointSequenceJobPort(checkpointOutcomeUnknown: true)
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    _ = try await coordinator.proposePatch(
      taskID, proposalJSON: proposalJSON(proposal))
    let stopped = try await coordinator.reconcile(taskID)
    let stillStopped = try await coordinator.reconcile(taskID)
    let requests = await jobs.requests()

    XCTAssertEqual(stopped.action, .stoppedForHuman)
    XCTAssertEqual(
      stopped.reasonCode,
      "outcomeUnknown:\(DebugCrashTaskHandler.createCheckpoint)")
    XCTAssertEqual(stopped.snapshot.consumedBudget.e1Mutations, 1)
    XCTAssertNil(stopped.snapshot.repairAttempt)
    XCTAssertEqual(stillStopped.action, .awaitingHuman)
    XCTAssertEqual(requests.map(\.operation.reference), [DebugCrashTaskHandler.createCheckpoint])
  }

  func testApplyAuthorizationRetryReusesThePreparedPostCheckpointDecision() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: false)
    await grant.setCovered([DebugCrashTaskHandler.createCheckpoint])
    let jobs = CheckpointSequenceJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    _ = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let blockedApply = try await coordinator.reconcile(taskID)
    let storedBefore = try await store.decision(taskID, round: 3)
    let applyBefore = try XCTUnwrap(storedBefore)
    XCTAssertEqual(blockedApply.action, .stoppedForHuman)
    XCTAssertTrue(blockedApply.reasonCode.contains(DebugCrashTaskHandler.applyPatch))
    XCTAssertEqual(blockedApply.snapshot.consumedBudget.e1Mutations, 1)

    await grant.setEnabled(true)
    let retried = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let storedAfter = try await store.decision(taskID, round: 3)
    let applyAfter = try XCTUnwrap(storedAfter)
    let requests = await jobs.requests()
    let prepareCount = await repair.preparations()
    XCTAssertEqual(retried.action, .dispatched)
    XCTAssertEqual(retried.snapshot.consumedBudget.e1Mutations, 2)
    XCTAssertEqual(applyBefore.decisionID, applyAfter.decisionID)
    XCTAssertEqual(applyBefore.inputs, applyAfter.inputs)
    XCTAssertEqual(
      requests.map(\.operation.reference),
      [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch])
    XCTAssertEqual(prepareCount, 1)
  }

  func testMethodSurfaceRequiresProposalJSON() async throws {
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)
    let service = HarnessTaskMethodService(
      coordinator: coordinator,
      applicationReferenceValidator: { _, _ in })

    let response = await service.handle(
      "task.proposePatch", requestID: "human-patch-missing-document",
      params: ["htaskId": .string(taskID)])
    XCTAssertEqual(response.errorCode, .invalidParams)
    XCTAssertEqual(response.errorMessage, "proposalJson is required")
  }

  func testPersistedHumanBoundaryWithoutAttemptBackfillsJourneyIdentity() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let historical = snapshot(
      status: .humanRequired,
      result: HarnessTaskResult(
        outcome: .humanRequired, reasonCode: "patchProposalRequired",
        summary: "A bounded source patch must be supplied."))
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant,
      initialSnapshot: historical)

    let outcome = try await coordinator.proposePatch(
      taskID, proposalJSON: proposalJSON(proposal))
    let attempts = try await store.attempts(taskID)
    let stored = try await store.decision(taskID, round: 2)

    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(attempts.map(\.ordinal), [1, 2])
    XCTAssertEqual(stored?.attemptID, attempts.last?.attemptID)
    XCTAssertEqual(stored?.expectedWorkspaceRevision, proposal.baseWorkspaceRevision)
  }

  func testExpiredInitialProposalStopsBeforeAttemptDecisionPreparationOrDispatch() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let historical = snapshot(
      status: .humanRequired,
      result: HarnessTaskResult(
        outcome: .humanRequired, reasonCode: "patchProposalRequired",
        summary: "A bounded source patch must be supplied."),
      createdAtUTC: "2026-07-31T00:00:00Z")
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant,
      initialSnapshot: historical)

    let outcome = try await coordinator.proposePatch(
      taskID, proposalJSON: proposalJSON(proposal))
    let prepareCount = await repair.preparations()
    let requests = await jobs.requests()
    let stored = try await store.decision(taskID, round: 2)
    let attempts = try await store.attempts(taskID)

    XCTAssertEqual(outcome.action, .stoppedBudgetExhausted)
    XCTAssertEqual(outcome.reasonCode, "maxWallClockExhausted")
    XCTAssertEqual(outcome.snapshot.status, .failed)
    XCTAssertEqual(prepareCount, 0)
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNil(stored)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testPolicyAuthorizationRetryReusesDecisionAndPreparedLease() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: false)
    let jobs = HumanPatchJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    let first = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let firstStored = try await store.decision(taskID, round: 2)
    let firstDecision = try XCTUnwrap(firstStored)
    let firstPrepareCount = await repair.preparations()
    let firstRequests = await jobs.requests()
    XCTAssertEqual(first.action, .stoppedForHuman)
    XCTAssertTrue(first.reasonCode.contains("authorizationRequired"))
    XCTAssertEqual(firstPrepareCount, 1)
    XCTAssertTrue(firstRequests.isEmpty)

    await grant.setEnabled(true)
    let retried = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let retriedStored = try await store.decision(taskID, round: 2)
    let retriedDecision = try XCTUnwrap(retriedStored)
    let requests = await jobs.requests()
    let retriedPrepareCount = await repair.preparations()
    XCTAssertEqual(retried.action, .dispatched)
    XCTAssertEqual(retriedPrepareCount, 1, "retry must not republish patch bytes")
    XCTAssertEqual(firstDecision.decisionID, retriedDecision.decisionID)
    XCTAssertEqual(firstDecision.inputs, retriedDecision.inputs)
    XCTAssertEqual(requests.count, 1)
  }

  func testExpiredAuthorizationRetryDoesNotResumePrepareOrDispatch() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: false)
    let jobs = HumanPatchJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    let first = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    XCTAssertEqual(first.action, .stoppedForHuman)
    let decisionBefore = try await store.decision(taskID, round: 2)
    let attemptsBefore = try await store.attempts(taskID)

    await grant.setEnabled(true)
    let expiredCoordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, repairPort: repair,
      nowUTC: { "2026-07-31T02:00:00Z" },
      policyGuard: HarnessPolicyGuard(capabilities: grant))
    let retried = try await expiredCoordinator.proposePatch(
      taskID, proposalJSON: bytes)
    let prepareCount = await repair.preparations()
    let requests = await jobs.requests()
    let decisionAfter = try await store.decision(taskID, round: 2)
    let attemptsAfter = try await store.attempts(taskID)

    XCTAssertEqual(retried.action, .stoppedBudgetExhausted)
    XCTAssertEqual(retried.reasonCode, "maxWallClockExhausted")
    XCTAssertEqual(retried.snapshot.status, .failed)
    XCTAssertEqual(prepareCount, 1)
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(decisionAfter, decisionBefore)
    XCTAssertEqual(attemptsAfter, attemptsBefore)
  }

  func testRuntimeAuthorizationRejectionRetriesTheSameRequestIdentity() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort(rejectAuthorization: true)
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    let first = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let firstRequests = await jobs.requests()
    XCTAssertEqual(first.action, .stoppedForHuman)
    XCTAssertEqual(
      first.reasonCode,
      "submissionRejected:authorizationRequired:\(DebugCrashTaskHandler.createCheckpoint)")
    XCTAssertEqual(firstRequests.count, 1)
    XCTAssertEqual(first.snapshot.consumedBudget.e1Mutations, 0)

    await jobs.acceptAuthorization()
    let retried = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    let allRequests = await jobs.requests()
    let prepareCount = await repair.preparations()
    XCTAssertEqual(retried.action, .dispatched)
    XCTAssertEqual(retried.snapshot.consumedBudget.e1Mutations, 1)
    XCTAssertEqual(allRequests.count, 2)
    XCTAssertEqual(allRequests[0].requestID, allRequests[1].requestID)
    XCTAssertEqual(allRequests[0].idempotencyKey, allRequests[1].idempotencyKey)
    XCTAssertEqual(allRequests[0].inputs, allRequests[1].inputs)
    XCTAssertEqual(prepareCount, 1)
  }

  func testDeduplicatedPatchRecoveryChargesTheAcceptedEffectOnce() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = DeduplicatingHumanPatchJobPort()
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    do {
      _ = try await coordinator.proposePatch(
        taskID, proposalJSON: proposalJSON(proposal))
      XCTFail("the first engine answer is deliberately lost")
    } catch {
      XCTAssertEqual(
        error as? HarnessJobPortError,
        .transportFailure("answer lost after engine acceptance"))
    }
    let unresolved = try await coordinator.status(taskID)
    XCTAssertEqual(unresolved.consumedBudget.e1Mutations, 0)

    let recovered = try await coordinator.reconcile(taskID)
    XCTAssertEqual(recovered.action, .recoveredIntent)
    XCTAssertEqual(recovered.reasonCode, "deduplicated")
    XCTAssertEqual(recovered.snapshot.consumedBudget.e1Mutations, 1)
    let waiting = try await coordinator.reconcile(taskID)
    XCTAssertEqual(waiting.action, .waitedForActiveJob)
    XCTAssertEqual(waiting.snapshot.consumedBudget.e1Mutations, 1)

    let requests = await jobs.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
  }

  func testWrongStateAndChangedAuthorizationRetryHaveNoEffect() async throws {
    let proposal = try makeProposal()
    let bytes = try proposalJSON(proposal)
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: false)
    let jobs = HumanPatchJobPort()
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    do {
      _ = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
      XCTFail("a running task must not accept human patch bytes")
    } catch {
      XCTAssertEqual(
        error as? HarnessCoordinatorError, .patchProposalNotAllowed("running"))
    }
    let wrongStatePrepareCount = await repair.preparations()
    XCTAssertEqual(wrongStatePrepareCount, 0)

    _ = try await coordinator.reconcile(taskID)
    _ = try await coordinator.proposePatch(taskID, proposalJSON: bytes)
    var changed = try JSONDecoder().decode(JSONValue.self, from: bytes)
    guard case .object(var fields) = changed else {
      return XCTFail("proposal must be an object")
    }
    fields["hypothesis"] = .string("Use different patch evidence.")
    changed = .object(fields)
    do {
      _ = try await coordinator.proposePatch(
        taskID, proposalJSON: JSONEncoder().encode(changed))
      XCTFail("authorization retry must match the prepared decision")
    } catch {
      XCTAssertEqual(error as? HarnessCoordinatorError, .patchProposalMismatch)
    }
    let status = try await coordinator.status(taskID)
    let finalPrepareCount = await repair.preparations()
    let finalRequests = await jobs.requests()
    XCTAssertEqual(status.status, .humanRequired)
    XCTAssertEqual(finalPrepareCount, 1)
    XCTAssertTrue(finalRequests.isEmpty)
  }

  // MARK: - External producer lane

  func testDecisionContextExportsWithoutGatewayOrEgress() async throws {
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    let blocked = try await coordinator.reconcile(taskID)
    XCTAssertEqual(blocked.reasonCode, "patchProposalRequired")
    let versionBefore = try await coordinator.status(taskID).version
    let eventsBefore = try await store.events(taskID).count

    let export = try await coordinator.decisionContext(taskID)
    XCTAssertEqual(export.context.requestedDecision, "proposePatch")
    XCTAssertEqual(export.contextDigest, export.context.transmittedDigest)
    XCTAssertEqual(export.contextBytes, export.context.transmittedByteCount)
    XCTAssertEqual(
      export.context.targetPseudonym,
      HarnessDecisionContext.pseudonym(forTargetID: "TGT-1"))
    let canonical = String(decoding: export.context.transmittedBytes, as: UTF8.self)
    XCTAssertFalse(canonical.contains("TGT-1"))

    // Exporting is a read: no state movement, no events, no budget charged.
    let after = try await coordinator.status(taskID)
    let eventsAfter = try await store.events(taskID).count
    XCTAssertEqual(after.version, versionBefore)
    XCTAssertEqual(eventsAfter, eventsBefore)
    XCTAssertEqual(after.consumedBudget.modelCalls, 0)
    XCTAssertEqual(after.status, .humanRequired)
  }

  func testDecisionContextRefusesIdentityMarkedContext() async throws {
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant,
      initialSnapshot: snapshot(
        goalSummary: "repair crash logged under /Users/operator/logs"))

    do {
      _ = try await coordinator.decisionContext(taskID)
      XCTFail("a context carrying a host path must not be exported")
    } catch {
      XCTAssertEqual(
        error as? HarnessCoordinatorError, .contextNotExportable("/Users/"))
    }
  }

  func testExternalAgentProducerIsRecordedOnEveryPreparedDecision() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, store) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    let outcome = try await coordinator.proposePatch(
      taskID, proposalJSON: proposalJSON(proposal),
      producer: HarnessTaskCoordinator.externalAgentPatchProducer)
    let storedCheckpoint = try await store.decision(taskID, round: 2)
    let storedApply = try await store.decision(taskID, round: 3)
    let events = try await store.events(taskID)
    XCTAssertEqual(outcome.action, .dispatched)
    // The label changes the ledger, never the validation chain or budgets.
    XCTAssertEqual(outcome.snapshot.consumedBudget.modelCalls, 0)
    XCTAssertEqual(outcome.snapshot.consumedBudget.e1Mutations, 1)
    XCTAssertEqual(
      storedCheckpoint?.producer, HarnessTaskCoordinator.externalAgentPatchProducer)
    XCTAssertEqual(
      storedApply?.producer, HarnessTaskCoordinator.externalAgentPatchProducer)
    XCTAssertTrue(
      events.contains { $0.reasonCode == "externalAgentPatchProposalAccepted" },
      "the resolution must say an external agent answered, not a person")
  }

  func testUnknownProducerIsRefusedBeforeAnyEffect() async throws {
    let proposal = try makeProposal()
    let repair = HumanPatchRepairPort()
    let grant = HumanPatchGrant(enabled: true)
    let jobs = HumanPatchJobPort()
    let (coordinator, _) = try await makeStack(
      jobs: jobs, repair: repair, capabilities: grant)

    _ = try await coordinator.reconcile(taskID)
    do {
      _ = try await coordinator.proposePatch(
        taskID, proposalJSON: proposalJSON(proposal), producer: "vendor-x")
      XCTFail("a producer outside the closed set must be refused")
    } catch {
      XCTAssertEqual(
        error as? HarnessCoordinatorError,
        .malformedPatchProposal("unknownPatchProducer:vendor-x"))
    }
    let status = try await coordinator.status(taskID)
    let prepareCount = await repair.preparations()
    let requests = await jobs.requests()
    XCTAssertEqual(status.status, .humanRequired)
    XCTAssertEqual(prepareCount, 0)
    XCTAssertTrue(requests.isEmpty)
  }

  private func makeProposal() throws -> HarnessPatchProposal {
    let diff = """
      diff --git a/Sources/A.swift b/Sources/A.swift
      --- a/Sources/A.swift
      +++ b/Sources/A.swift
      @@ -1 +1 @@
      -let value = 0
      +let value = 1
      """
    let digest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return try HarnessPatchProposal(
      baseWorkspaceRevision: String(repeating: "1", count: 64),
      patchSHA256: digest, unifiedDiff: diff, touchedFiles: ["Sources/A.swift"],
      expectedChangedSymbols: ["value"])
  }

  private func proposalJSON(_ proposal: HarnessPatchProposal) throws -> Data {
    try JSONEncoder().encode(
      JSONValue.object([
        "kind": .string("proposePatch"),
        "hypothesis": .string("Change the bounded source branch."),
        "reasonCode": .string("humanPatchProposal"),
        "baseWorkspaceRevision": .string(proposal.baseWorkspaceRevision),
        "patchSha256": .string(proposal.patchSHA256),
        "unifiedDiff": .string(proposal.unifiedDiff),
        "touchedFiles": .array(proposal.touchedFiles.map(JSONValue.string)),
        "expectedChangedSymbols": .array(
          proposal.expectedChangedSymbols.map(JSONValue.string)),
      ]))
  }

  private func makeStack(
    jobs: any HarnessRuntimeJobPort,
    repair: HumanPatchRepairPort,
    capabilities: HumanPatchGrant,
    initialSnapshot: HarnessTaskSnapshot? = nil
  ) async throws -> (HarnessTaskCoordinator, HarnessTaskStore) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(initialSnapshot ?? snapshot())
    let fixedNow = now
    return (
      HarnessTaskCoordinator(
        store: store, jobPort: jobs, repairPort: repair, nowUTC: { fixedNow },
        policyGuard: HarnessPolicyGuard(capabilities: capabilities)),
      store
    )
  }

  private func snapshot(
    status: HarnessTaskStatus = .running,
    result: HarnessTaskResult? = nil,
    createdAtUTC: String? = nil,
    goalSummary: String = "repair crash"
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: taskID, type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
      goal: HarnessTaskGoal(
        summary: goalSummary,
        desiredState: [
          "buildPresetRef": .string("demo-build"),
          "testPresetRef": .string("demo-tests"),
          "bundleName": .string("com.example.demo"),
          "abilityName": .string("EntryAbility"),
          "baseWorkspaceRevision": .string(String(repeating: "1", count: 64)),
          "baselineHapArtifactLease": .string("lease-v1:input-hap:ART-crash-fixture"),
        ]),
      successCriteria: DebugCrashTaskHandler().defaultSuccessCriteria(),
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 7),
      policy: HarnessTaskPolicy(
        allowedOperations: DebugCrashTaskHandler().permittedOperations.sorted()),
      observedState: HarnessObservedState(latestVerdict: .fail).asJSON,
      createdAtUTC: createdAtUTC ?? now, updatedAtUTC: now,
      status: status, phase: .analyzing,
      activeRound: 1, activeJobID: nil,
      consumedBudget: HarnessConsumedBudget(rounds: 1), result: result)
  }
}
