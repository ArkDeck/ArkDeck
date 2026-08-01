// Strategy Attempt contract tests (CHG-2026-055, TASK-HFA-004).
//
// Registered acceptance: HFA-AC-9 (rewording cannot bypass duplicate
// strategy rejection) and HFA-AC-10 (Action Retry is distinct from Attempt,
// crash replay reuses the original action, and no-progress is task-bounded).

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private actor AttemptJobPort: HarnessRuntimeJobPort {
  private var submissions = 0
  private var nextOrdinal = 1
  private var submittedOperations: [String] = []
  private var observations: [String: HarnessJobObservation] = [:]

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submissions += 1
    submittedOperations.append(request.operation.reference)
    let jobID = "JOB-ATTEMPT-\(nextOrdinal)"
    nextOrdinal += 1
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: [])
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}
  func observe(jobID: String) async throws -> HarnessJobObservation {
    guard let observation = observations[jobID] else {
      throw HarnessJobPortError.unknownJob(jobID)
    }
    return observation
  }
  func requestCancel(jobID: String) async throws {}
  func count() -> Int { submissions }
  func operations() -> [String] { submittedOperations }
  func finish(_ jobID: String, succeeded: Bool, state: String) {
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: state, isTerminal: true, succeeded: succeeded,
      outcomeUnknown: false, waitingForHuman: false, timeline: [state])
  }
}

private actor AttemptGateway: HarnessDecisionGateway {
  let producerID = "attempt-fixture-model"
  private var responses: [Data]

  init(responses: [Data]) { self.responses = responses }

  func propose(_ context: HarnessDecisionContext) async throws -> Data {
    guard !responses.isEmpty else { throw HarnessDecisionGatewayError.transportFailure("empty") }
    return responses.removeFirst()
  }
}

private struct AttemptRepairPort: HarnessRepairPort {
  let patchRevision: String

  func currentWorkspaceRevision(
    relativePaths: [String], projectRef: String, task: HarnessTaskSnapshot
  ) async throws -> String {
    if let revision = task.repairAttempt?.patchRevision { return revision }
    if case .string(let revision)? = task.goal.desiredState["baseWorkspaceRevision"] {
      return revision
    }
    return String(repeating: "1", count: 64)
  }

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    HarnessPreparedPatch(
      inputs: [
        "projectRef": .string(projectRef),
        "patchArtifactRef": .string("lease-v1:patch:ART-attempt"),
        "allowedFileGlobs": .array(proposal.touchedFiles.map(JSONValue.string)),
      ], artifactLease: "lease-v1:patch:ART-attempt")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    HarnessAppliedPatchReadback(
      patchAttemptRef: "patch-attempt-fixture", patchRevision: patchRevision)
  }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    HarnessBuildReadback(
      sourceRevision: patchRevision, outputDigest: String(repeating: "e", count: 64),
      outputArtifactLease: "lease-v1:build:ART-attempt")
  }

  func deployedArtifactDigest(jobID: String) async throws -> String {
    String(repeating: "e", count: 64)
  }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback { .stillUnknown }
}

/// A grant a maintainer issued: the harness may ask for it and name it, and
/// may do nothing else with it (CHG-2026-055, TASK-HFA-009 r2).
private struct AttemptWorkspaceGrant: HarnessCapabilityPort {
  let covered: Set<String>
  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    covered.contains(operationReference)
  }
  func standingCapabilityID(operationReference: String, targetID: String) async -> String? {
    covered.contains(operationReference) ? "CAP-RT-WORKSPACE-FIXTURE" : nil
  }
}

private let attemptWorkspaceMutations: Set<String> = [
  "workspace.apply-patch@1", "workspace.build-openharmony@1", "workspace.run-tests@1",
  "workspace.revert-patch@1", "workspace.create-checkpoint@1",
]

final class HarnessAttemptContractTests: XCTestCase {
  private var rootURL: URL!
  private let now = "2026-07-31T12:00:00Z"

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-attempt-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  func testStrategyFingerprintUsesTheSevenCanonicalElementsButNotHypothesisProse() throws {
    let original = try strategy()
    let first = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: "HTASK-000000000001", ordinal: 1,
      hypothesis: "Fix the state transition.", strategy: original,
      createdAtUTC: now, updatedAtUTC: now)
    let reworded = HarnessAttempt(
      attemptID: "ATTEMPT-000000000002", htaskID: "HTASK-000000000001", ordinal: 2,
      hypothesis: "Rewrite the transition so it no longer fails.", strategy: original,
      createdAtUTC: now, updatedAtUTC: now)
    XCTAssertEqual(first.strategyFingerprint, reworded.strategyFingerprint)

    let mutations: [HarnessStrategyDescriptor] = [
      try strategy(hypothesisClass: "differentClass"),
      try strategy(operationFamily: "workspace.other"),
      try strategy(patch: String(repeating: "b", count: 64)),
      try strategy(base: String(repeating: "c", count: 64)),
      try strategy(artifacts: ["ART-other"]),
      try strategy(prerequisites: ["failed:DC-other"]),
      try strategy(
        expectation: HarnessStrategyExecutionExpectation(
          targetProfile: "TGT-other", toolchainProfile: "release",
          expectedNextObservation: "PATCH_APPLIED")),
    ]
    for mutation in mutations {
      XCTAssertNotEqual(original.fingerprint, mutation.fingerprint)
      XCTAssertEqual(
        HarnessAttemptPlanner.classify(
          attempts: [first], candidateStrategyFingerprint: mutation.fingerprint,
          identicalActionRunCount: 0, failure: nil, retrySafe: false,
          maxActionRetriesPerRun: 2),
        .newAttempt(ordinal: 2),
        "changing any canonical strategy element must admit a new Attempt")
    }
    XCTAssertEqual(
      try JSONDecoder().decode(
        HarnessStrategyDescriptor.self, from: original.canonicalJSON), original)
  }

  func testAttemptEventsAreDurableAndRejectRegression() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let snapshot = taskSnapshot()
    try await store.create(snapshot)
    let original = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: snapshot.htaskID, ordinal: 1,
      hypothesis: "bounded repair", strategy: try strategy(),
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(original, kind: .created, reasonCode: "strategyAccepted")
    let withAction = original.recordingActionRun("htask-action-1", atUTC: now)
    try await store.recordAttempt(
      withAction, kind: .actionRunRecorded, reasonCode: "actionRunPlanned")
    let failed = withAction.recordingFailure(
      "FAIL-000000000001", outcome: .failed, atUTC: now)
    try await store.recordAttempt(failed, kind: .failureRecorded, reasonCode: "failed")

    let reopened = failed.closing(.active, atUTC: now)
    await XCTAssertThrowsErrorAsync {
      try await store.recordAttempt(reopened, kind: .closed, reasonCode: "illegalReopen")
    }

    let reopenedStore = try HarnessTaskStore(rootURL: rootURL)
    let reopenedAttempts = try await reopenedStore.attempts(snapshot.htaskID)
    XCTAssertEqual(reopenedAttempts, [failed])
    let events = try await reopenedStore.attemptEvents(snapshot.htaskID)
    XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(events.map(\.kind), [.created, .actionRunRecorded, .failureRecorded])
  }

  func testHumanResolutionReactivatesTheSameAttemptWithoutLosingItsHistory() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let snapshot = taskSnapshot(status: .humanRequired)
    try await store.create(snapshot)
    let active = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: snapshot.htaskID, ordinal: 1,
      hypothesis: "bounded repair", strategy: try strategy(),
      actionRunIDs: ["htask-action-1"], evaluationIDs: ["EVAL-000000000001"],
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(active, kind: .created, reasonCode: "strategyAccepted")
    try await store.recordAttempt(
      active.closing(.humanRequired, atUTC: now), kind: .closed,
      reasonCode: "humanActionRequired")
    let timestamp = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: AttemptJobPort(), nowUTC: { timestamp })

    let resumed = try await coordinator.resume(
      snapshot.htaskID, resolution: "continue the same verified repair")
    XCTAssertEqual(resumed.status, .running)
    let attempts = try await coordinator.attempts(snapshot.htaskID)
    let attempt = try XCTUnwrap(attempts.last)
    XCTAssertEqual(attempt.outcome, .active)
    XCTAssertEqual(attempt.actionRunIDs, ["htask-action-1"])
    XCTAssertEqual(attempt.evaluationIDs, ["EVAL-000000000001"])
    let events = try await store.attemptEvents(snapshot.htaskID)
    XCTAssertEqual(events.last?.kind, .resumed)
  }

  func testRepeatedVerificationCapturesAreSamplesNotDuplicateStrategies() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let patch = try proposal()
    var observed = HarnessObservedState(latestVerdict: .inconclusive).asJSON
    observed[HarnessRepairAttempt.observedStateKey] = HarnessRepairAttempt(
      proposal: patch, patchAttemptRef: "patch-fixture",
      deployedDigest: String(repeating: "d", count: 64)).json
    let snapshot = taskSnapshot(phase: .verifying, observedState: observed)
    try await store.create(snapshot)
    let active = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: snapshot.htaskID, ordinal: 1,
      hypothesis: "bounded repair", strategy: try strategy(),
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(active, kind: .created, reasonCode: "strategyAccepted")
    let timestamp = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: AttemptJobPort(), nowUTC: { timestamp })
    let inputs = DebugCrashTaskHandler.typedInputs(
      for: DebugCrashTaskHandler.captureDiagnostics, snapshot: snapshot)
    let digest = HarnessRequestIdentity.inputsDigest(inputs)

    try await coordinator.recordAttemptActionRun(
      snapshot: snapshot, operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputsDigest: digest, actionRunID: "htask-sample-1")
    try await coordinator.recordAttemptActionRun(
      snapshot: snapshot, operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputsDigest: digest, actionRunID: "htask-sample-2")

    let attempts = try await coordinator.attempts(snapshot.htaskID)
    let attempt = try XCTUnwrap(attempts.last)
    XCTAssertEqual(attempt.actionRunIDs, ["htask-sample-1", "htask-sample-2"])
    XCTAssertEqual(attempt.outcome, .active)
  }

  func testPendingIntentCrashWindowRestoresOriginalActionRunBeforeDispatch() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let snapshot = taskSnapshot(phase: .collecting)
    try await store.create(snapshot)
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: snapshot.htaskID, ordinal: 1,
      hypothesis: "collect one more bounded observation", strategy: try strategy(),
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(attempt, kind: .created, reasonCode: "strategyAccepted")

    let inputs = DebugCrashTaskHandler.typedInputs(
      for: DebugCrashTaskHandler.captureDiagnostics, snapshot: snapshot)
    let digest = HarnessRequestIdentity.inputsDigest(inputs)
    let basis = HarnessDecisionBasis(
      snapshot: snapshot,
      offeredOperations: [DebugCrashTaskHandler.captureDiagnostics])
    let decision = HarnessDecision(
      decisionID: "dec-recover", htaskID: snapshot.htaskID, round: 1,
      kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputs: inputs, hypothesis: "collect the diagnostic artifact",
      reasonCode: "captureDiagnostics", producer: "fixture-model",
      createdAtUTC: now
    ).stamped(
      with: basis, attemptID: attempt.attemptID,
      expectedBindingRevision: snapshot.target.expectedBindingRevision)
    try await store.putDecision(decision)
    let identity = HarnessRequestIdentity.derive(
      htaskID: snapshot.htaskID, round: decision.round,
      decisionID: decision.decisionID,
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      targetID: snapshot.target.targetID, inputsDigest: digest)
    let pending = HarnessDispatchIntent(
      htaskID: snapshot.htaskID, round: decision.round,
      decisionID: decision.decisionID,
      attemptID: attempt.attemptID,
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      targetID: snapshot.target.targetID,
      expectedBindingRevision: snapshot.target.expectedBindingRevision,
      inputsDigestSHA256: digest, requestID: identity.requestID,
      idempotencyKey: identity.idempotencyKey, state: .pending,
      jobID: nil, createdAtUTC: now, updatedAtUTC: now)
    // Simulate a process exit after pending intent persistence but before
    // the Attempt event is appended.
    try await store.putIntent(pending)

    let jobs = AttemptJobPort()
    let timestamp = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { timestamp })
    let recovered = try await coordinator.reconcile(snapshot.htaskID)
    XCTAssertEqual(recovered.action, .recoveredIntent)
    let storedIntent = try await store.intent(snapshot.htaskID, round: decision.round)
    let linked = try XCTUnwrap(storedIntent)
    XCTAssertEqual(linked.idempotencyKey, identity.idempotencyKey)
    XCTAssertEqual(linked.requestID, identity.requestID)
    XCTAssertEqual(linked.state, .linked)
    let restored = try await coordinator.attempts(snapshot.htaskID)
    XCTAssertEqual(restored[0].actionRunIDs, [identity.requestID])
    let submissionCount = await jobs.count()
    XCTAssertEqual(submissionCount, 1)
  }

  func testRewordedFailedPatchIsRejectedBeforeAnotherAttemptOrDispatch() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let snapshot = taskSnapshot()
    try await store.create(snapshot)
    let jobs = AttemptJobPort()
    let timestamp = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { timestamp },
      attemptIDFactory: { "ATTEMPT-000000000001" })
    let patch = try proposal()
    let firstDecision = decision(
      id: "dec-1", hypothesis: "Change the failing branch.", proposal: patch)
    _ = try await coordinator.beginStrategyAttempt(
      decision: firstDecision, proposal: patch, snapshot: snapshot)
    try await coordinator.recordAttemptActionRun(
      snapshot: snapshot, operationReference: DebugCrashTaskHandler.applyPatch,
      inputsDigest: patch.patchSHA256, actionRunID: "htask-action-1")
    let failure = HarnessFailureFingerprint(
      operationReference: DebugCrashTaskHandler.buildOpenHarmony,
      phase: .building, providerID: "workspace", targetProfile: snapshot.target.targetID,
      normalizedInputsSHA256: String(repeating: "d", count: 64),
      errorClassification: "BUILD_SEMANTIC_FAILURE", semanticErrorCode: "compileFailed")
    try await coordinator.recordAttemptFailure(
      taskID: snapshot.htaskID, fingerprint: failure, outcome: .failed)

    let reworded = decision(
      id: "dec-2", hypothesis: "Use different words for the same branch change.",
      proposal: patch)
    do {
      _ = try await coordinator.beginStrategyAttempt(
        decision: reworded, proposal: patch, snapshot: snapshot)
      XCTFail("the same strategy must not become a second Attempt")
    } catch let error as HarnessAttemptAdmissionError {
      XCTAssertEqual(error, .duplicateStrategy("ATTEMPT-000000000001"))
      XCTAssertEqual(error.reasonCode, "DUPLICATE_STRATEGY:ATTEMPT-000000000001")
    }
    let attemptCount = try await store.attempts(snapshot.htaskID).count
    let submissionCount = await jobs.count()
    XCTAssertEqual(attemptCount, 1)
    XCTAssertEqual(submissionCount, 0, "duplicate strategy must dispatch no runtime job")
  }

  func testCoordinatorRejectsRewordedPatchAfterBuildFailureWithoutSecondApply() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let failing = taskSnapshot(
      observedState: HarnessObservedState(
        latestVerdict: .fail, blockers: ["DC-1 failed"]).asJSON)
    try await store.create(failing)
    let patch = try proposal()
    let patchBytes = try proposalBytes(
      proposal: patch, hypothesis: "Change the failing branch.")
    let buildBytes = try JSONEncoder().encode(
      JSONValue.object([
        "kind": .string("invokeOperation"),
        "operationRef": .string(DebugCrashTaskHandler.buildOpenHarmony),
        "inputs": .object([
          "projectRef": .string("fixture-project"),
          "buildPresetRef": .string("arkdeck-debug"),
        ]),
        "hypothesis": .string("Build the exact applied patch."),
        "reasonCode": .string("buildPatchedWorkspace"),
      ]))
    let rewordedBytes = try proposalBytes(
      proposal: patch,
      hypothesis: "Describe the same source edit with different prose.")
    let gateway = AttemptGateway(responses: [patchBytes, buildBytes, rewordedBytes])
    let jobs = AttemptJobPort()
    let timestamp = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs,
      repairPort: AttemptRepairPort(patchRevision: String(repeating: "f", count: 64)),
      nowUTC: { timestamp },
      attemptIDFactory: { "ATTEMPT-000000000001" },
      policyGuard: HarnessPolicyGuard(
        capabilities: AttemptWorkspaceGrant(covered: attemptWorkspaceMutations)),
      decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(enabledProjects: ["fixture-project"]))

    let checkpointed = try await coordinator.reconcile(failing.htaskID)
    XCTAssertEqual(checkpointed.action, .dispatched)
    XCTAssertEqual(checkpointed.reasonCode, "patchModelProposal")
    let checkpointJob = try XCTUnwrap(checkpointed.dispatchedJobID)
    await jobs.finish(checkpointJob, succeeded: true, state: "succeeded")

    let applied = try await coordinator.reconcile(failing.htaskID)
    XCTAssertEqual(applied.action, .dispatched)
    let applyJob = try XCTUnwrap(applied.dispatchedJobID)
    await jobs.finish(applyJob, succeeded: true, state: "succeeded")

    let built = try await coordinator.reconcile(failing.htaskID)
    XCTAssertEqual(built.action, .dispatched)
    let buildJob = try XCTUnwrap(built.dispatchedJobID)
    await jobs.finish(buildJob, succeeded: false, state: "compileFailed")

    let stale = try await coordinator.reconcile(failing.htaskID)
    XCTAssertEqual(stale.action, .staleDecision)
    XCTAssertTrue(stale.reasonCode.contains("workspaceRevisionChanged"))
    let operations = await jobs.operations()
    XCTAssertEqual(
      operations,
      [
        DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
        DebugCrashTaskHandler.buildOpenHarmony,
      ])
    let attempts = try await coordinator.attempts(failing.htaskID)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[0].outcome, .superseded)
    XCTAssertEqual(attempts[1].outcome, .failed)
    XCTAssertNotNil(attempts[1].failureFingerprint)
  }

  func testActionRetryCrashReplayAndSemanticAlternativeAreDifferentRoutes() throws {
    let active = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: "HTASK-000000000001", ordinal: 1,
      hypothesis: "repair", strategy: try strategy(), actionRunIDs: ["run-1"],
      createdAtUTC: now, updatedAtUTC: now)
    let transient = HarnessFailureFingerprint(
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      phase: .collecting, providerID: "hdc", targetProfile: "TGT-1",
      normalizedInputsSHA256: String(repeating: "d", count: 64),
      errorClassification: "TRANSIENT", semanticErrorCode: "transport")
    XCTAssertEqual(
      HarnessAttemptPlanner.classify(
        attempts: [active], candidateStrategyFingerprint: active.strategyFingerprint,
        identicalActionRunCount: 1, failure: transient, retrySafe: true,
        maxActionRetriesPerRun: 2),
      .actionRetry(attemptID: active.attemptID, retryOrdinal: 1))
    XCTAssertEqual(
      HarnessAttemptPlanner.classify(
        attempts: [active], candidateStrategyFingerprint: active.strategyFingerprint,
        identicalActionRunCount: 1, failure: transient, retrySafe: true,
        originalUnresolvedActionRunID: "run-1", maxActionRetriesPerRun: 2),
      .crashReplay(attemptID: active.attemptID, actionRunID: "run-1"))

    let semantic = HarnessFailureFingerprint(
      operationReference: DebugCrashTaskHandler.buildOpenHarmony,
      phase: .building, providerID: "workspace", targetProfile: "TGT-1",
      normalizedInputsSHA256: String(repeating: "e", count: 64),
      errorClassification: "BUILD_SEMANTIC_FAILURE", semanticErrorCode: "compile")
    XCTAssertEqual(
      HarnessAttemptPlanner.classify(
        attempts: [active], candidateStrategyFingerprint: active.strategyFingerprint,
        identicalActionRunCount: 1, failure: semantic, retrySafe: true,
        maxActionRetriesPerRun: 2),
      .duplicateStrategy(attemptID: active.attemptID))
    XCTAssertEqual(
      HarnessAttemptPlanner.classify(
        attempts: [active], candidateStrategyFingerprint: active.strategyFingerprint,
        identicalActionRunCount: 3, failure: transient, retrySafe: true,
        maxActionRetriesPerRun: 2),
      .actionRetryBudgetExhausted(attemptID: active.attemptID, retries: 2))
  }

  func testProgressIgnoresPlanningEvaluationAndPhaseButCountsANewPatchRevision() throws {
    let before = taskSnapshot(phase: .collecting)
    let analysisOnly = taskSnapshot(
      phase: .analyzing, latestEvaluationID: "EVAL-000000000001", version: 2)
    let vector = HarnessTaskCoordinator.progress(
      before: before, after: analysisOnly, newFailures: 0)
    XCTAssertTrue(vector.phaseChanged)
    XCTAssertTrue(vector.evaluationRecorded)
    XCTAssertFalse(vector.isProgress)

    let proposal = try proposal()
    let withPatch = taskSnapshot(
      phase: .building,
      observedState: [
        HarnessRepairAttempt.observedStateKey: HarnessRepairAttempt(
          proposal: proposal, patchRevision: String(repeating: "f", count: 64)).json
      ], version: 3)
    let patched = HarnessTaskCoordinator.progress(
      before: before, after: withPatch, newFailures: 0)
    XCTAssertTrue(patched.workspaceRevisionChanged)
    XCTAssertTrue(patched.isProgress)
    let sameRevision = HarnessTaskCoordinator.progress(
      before: withPatch,
      after: taskSnapshot(
        phase: .analyzing, observedState: withPatch.observedState, version: 4),
      newFailures: 0)
    XCTAssertFalse(sameRevision.workspaceRevisionChanged)
    XCTAssertFalse(sameRevision.isProgress)
  }

  func testBudgetFieldsDecodeHistoricalTasksStrictlyAndValidateNewBounds() throws {
    let historical = Data(
      """
      {"maxRounds":8,"maxWallClockSeconds":60,"maxArtifactBytes":1024,"maxE1Mutations":0}
      """.utf8)
    let decoded = try JSONDecoder().decode(HarnessTaskBudgets.self, from: historical)
    XCTAssertEqual(decoded.maxNoProgressRounds, 2)
    XCTAssertEqual(decoded.maxActionRetriesPerRun, 2)

    let invalid = HarnessTaskSubmission(
      type: .debugCrash, target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "goal"),
      budgets: HarnessTaskBudgets(
        maxRounds: 2, maxWallClockSeconds: 60, maxArtifactBytes: 1024,
        maxE1Mutations: 0, maxNoProgressRounds: 0, maxActionRetriesPerRun: 1),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    XCTAssertThrowsError(
      try invalid.validate(permittedOperations: DebugCrashTaskHandler().permittedOperations)) {
        XCTAssertEqual(
          $0 as? HarnessTaskSubmissionError, .budgetOutOfRange("maxNoProgressRounds"))
      }
  }

  func testNoProgressBudgetRefusesOnlyTheSameStrategy() async {
    let snapshot = taskSnapshot(noProgressRounds: 1, maxNoProgressRounds: 1)
    let inputs = DebugCrashTaskHandler.typedInputs(
      for: DebugCrashTaskHandler.captureDiagnostics, snapshot: snapshot)
    let digest = HarnessRequestIdentity.inputsDigest(inputs)
    let same = HarnessStrategySignature(
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputsDigest: digest, phase: snapshot.phase)
    let guardrail = HarnessPolicyGuard()
    let refused = await guardrail.evaluate(
      HarnessGuardInput(
        snapshot: snapshot,
        operationReference: DebugCrashTaskHandler.captureDiagnostics,
        inputs: inputs, inputsDigest: digest,
        permittedOperations: DebugCrashTaskHandler().permittedOperations,
        failureRecord: nil, previousStrategy: same,
        consecutiveNoProgressRounds: snapshot.noProgressRounds,
        elapsedSeconds: 1))
    XCTAssertEqual(refused, .refuse(.noProgress(rounds: 1)))

    let changed = await guardrail.evaluate(
      HarnessGuardInput(
        snapshot: snapshot,
        operationReference: DebugCrashTaskHandler.captureDiagnostics,
        inputs: inputs, inputsDigest: digest,
        permittedOperations: DebugCrashTaskHandler().permittedOperations,
        failureRecord: nil,
        previousStrategy: HarnessStrategySignature(
          operationReference: DebugCrashTaskHandler.observeDevice,
          inputsDigest: digest, phase: snapshot.phase),
        consecutiveNoProgressRounds: snapshot.noProgressRounds,
        elapsedSeconds: 1))
    XCTAssertEqual(changed, .allow, "a genuinely different strategy may replace the closed one")
  }

  private func strategy(
    hypothesisClass: String = "patchModelProposal",
    operationFamily: String = "workspace.repair",
    patch: String = String(repeating: "a", count: 64),
    base: String = String(repeating: "1", count: 64),
    artifacts: [String] = ["ART-crash"],
    prerequisites: [String] = ["failed:DC-1"],
    expectation: HarnessStrategyExecutionExpectation = HarnessStrategyExecutionExpectation(
      targetProfile: "TGT-1", toolchainProfile: "arkdeck-debug",
      expectedNextObservation: "PATCH_APPLIED")
  ) throws -> HarnessStrategyDescriptor {
    try HarnessStrategyDescriptor(
      hypothesisClass: hypothesisClass, selectedOperationFamily: operationFamily,
      patchFingerprint: patch, baseWorkspaceRevision: base,
      artifactSourceSet: artifacts, prerequisiteSet: prerequisites,
      executionExpectation: expectation)
  }

  private func proposal() throws -> HarnessPatchProposal {
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
      patchSHA256: digest, unifiedDiff: diff,
      touchedFiles: ["Sources/A.swift"], expectedChangedSymbols: ["value"])
  }

  private func decision(
    id: String, hypothesis: String, proposal: HarnessPatchProposal
  ) -> HarnessDecision {
    HarnessDecision(
      decisionID: id, htaskID: "HTASK-000000000001", round: 1,
      kind: .proposePatch, patchProposal: proposal,
      requiredArtifacts: ["ART-crash"], expectedObservation: "PATCH_APPLIED",
      hypothesis: hypothesis, reasonCode: "patchModelProposal",
      producer: "fixture-model", createdAtUTC: now)
  }

  private func proposalBytes(
    proposal: HarnessPatchProposal, hypothesis: String
  ) throws -> Data {
    try JSONEncoder().encode(
      JSONValue.object([
        "kind": .string("proposePatch"),
        "hypothesis": .string(hypothesis),
        "reasonCode": .string("patchModelProposal"),
        "baseWorkspaceRevision": .string(proposal.baseWorkspaceRevision),
        "patchSha256": .string(proposal.patchSHA256),
        "unifiedDiff": .string(proposal.unifiedDiff),
        "touchedFiles": .array(proposal.touchedFiles.map(JSONValue.string)),
        "expectedChangedSymbols": .array(
          proposal.expectedChangedSymbols.map(JSONValue.string)),
        "expectedObservation": .string("PATCH_APPLIED"),
      ]))
  }

  private func taskSnapshot(
    phase: HarnessTaskPhase = .analyzing,
    observedState: [String: JSONValue] = [:],
    status: HarnessTaskStatus = .running,
    latestEvaluationID: String? = nil,
    noProgressRounds: Int = 0,
    maxNoProgressRounds: Int = 2,
    version: Int = 1
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-000000000001", type: .debugCrash,
      intakeDescription: nil, projectRef: "fixture-project",
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(
        summary: "repair", desiredState: ["buildPresetRef": .string("arkdeck-debug")]),
      successCriteria: [
        HarnessSuccessCriterion(
          criterionID: "DC-1", metric: "matchingCrashCount", comparator: .equalTo,
          expected: .integer(0))
      ],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 60, maxArtifactBytes: 1024,
        maxE1Mutations: 7, maxNoProgressRounds: maxNoProgressRounds,
        maxActionRetriesPerRun: 2),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      observedState: observedState, createdAtUTC: now, updatedAtUTC: now,
      status: status, phase: phase,
      latestEvaluationID: latestEvaluationID, noProgressRounds: noProgressRounds,
      cancelRequested: false, version: version)
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("expected error", file: file, line: line)
  } catch {}
}
