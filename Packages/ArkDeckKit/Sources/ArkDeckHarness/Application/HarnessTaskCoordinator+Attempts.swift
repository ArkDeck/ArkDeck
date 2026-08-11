// Strategy Attempt wiring (CHG-2026-055, TASK-HFA-004).

import ArkDeckCore
import CryptoKit
import Foundation

enum HarnessAttemptAdmissionError: Error, Equatable, Sendable {
  case duplicateStrategy(String)
  case actionRetryBudgetExhausted(attemptID: String, retries: Int)
  case strategyAttemptBudgetExhausted(limit: Int)

  var reasonCode: String {
    switch self {
    case .duplicateStrategy(let attemptID):
      return "DUPLICATE_STRATEGY:\(attemptID)"
    case .actionRetryBudgetExhausted(let attemptID, let retries):
      return "maxActionRetriesPerRunExhausted:\(attemptID):\(retries)"
    case .strategyAttemptBudgetExhausted(let limit):
      return "maxEvolutionAttemptsExhausted:\(limit)"
    }
  }
}

extension HarnessTaskCoordinator {
  /// Every executable task starts with one Harness-owned journey Attempt, so
  /// even pre-repair deterministic operations have a durable active identity.
  /// A later patch proposal supersedes it with the existing source-repair
  /// Attempt. Tasks that already have Attempt history are never backfilled.
  func ensureInitialJourneyAttempt(_ snapshot: HarnessTaskSnapshot) async throws {
    let attempts = try await store.attempts(snapshot.htaskID)
    guard attempts.isEmpty else { return }
    let digest = SHA256.hash(data: Data("task-journey|\(snapshot.htaskID)".utf8))
      .map { String(format: "%02X", $0) }.joined()
    let desiredBaseRevision: String?
    if case .string(let value)? = snapshot.goal.desiredState["baseWorkspaceRevision"],
      value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    {
      desiredBaseRevision = value
    } else {
      desiredBaseRevision = nil
    }
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "taskJourney",
      selectedOperationFamily: "harness.\(snapshot.type.rawValue)",
      patchFingerprint: HarnessStrategyDescriptor.notApplicableDigest,
      baseWorkspaceRevision:
        desiredBaseRevision ?? HarnessStrategyDescriptor.notApplicableDigest,
      artifactSourceSet: snapshot.artifactRefs,
      prerequisiteSet: snapshot.successCriteria.map { "criterion:\($0.criterionID)" },
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: snapshot.target.targetID,
        toolchainProfile: "task-orchestrated",
        expectedNextObservation: "TASK_JOURNEY_PROGRESS"))
    let now = nowUTC()
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-\(digest.prefix(16))", htaskID: snapshot.htaskID,
      ordinal: 1, hypothesis: "Execute the bounded task journey.", strategy: strategy,
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(
      attempt, kind: .created, reasonCode: "initialTaskJourney")
  }

  func beginStrategyAttempt(
    decision: HarnessDecision,
    proposal: HarnessPatchProposal,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessAttempt {
    let strategy = try await strategyDescriptor(
      decision: decision, proposal: proposal, snapshot: snapshot)
    var attempts = try await store.attempts(snapshot.htaskID)
    if let policy = snapshot.evolutionPolicy {
      let strategyAttempts = attempts.filter { $0.strategy.hypothesisClass != "taskJourney" }
      guard strategyAttempts.count < policy.maxAttempts else {
        throw HarnessAttemptAdmissionError.strategyAttemptBudgetExhausted(
          limit: policy.maxAttempts)
      }
    }
    if let same = attempts.last(where: { $0.strategyFingerprint == strategy.fingerprint }) {
      // A crash after the Attempt event but before the first ActionRun may
      // resume that empty Attempt. Once an action exists, rewording the
      // hypothesis cannot mint another try.
      if same.outcome == .active, same.actionRunIDs.isEmpty {
        if let workspace = same.evolutionWorkspace {
          guard let evolutionWorkspacePort else {
            throw HarnessCoordinatorError.evolutionWorkspaceUnavailable
          }
          try await evolutionWorkspacePort.prepareAttemptDirectory(
            workspace: workspace, attemptID: same.attemptID,
            ordinal: same.ordinal, createdAtUTC: same.createdAtUTC)
        }
        return same
      }
      throw HarnessAttemptAdmissionError.duplicateStrategy(same.attemptID)
    }
    if let active = attempts.last(where: { $0.outcome == .active }) {
      let closed = active.closing(.superseded, atUTC: nowUTC())
      try await store.recordAttempt(
        closed, kind: .closed, reasonCode: "newStrategySupersededActiveAttempt")
      attempts = try await store.attempts(snapshot.htaskID)
    }
    let now = nowUTC()
    let ordinal = (attempts.map(\.ordinal).max() ?? 0) + 1
    let attemptID: String
    if snapshot.requiresWorkspaceIsolation {
      let material = Data(
        "\(snapshot.htaskID)|\(ordinal)|\(strategy.fingerprint)".utf8)
      let digest = SHA256.hash(data: material).map { String(format: "%02X", $0) }.joined()
      attemptID = "ATTEMPT-\(digest.prefix(16))"
    } else {
      attemptID = attemptIDFactory()
    }
    if let workspace = snapshot.evolutionWorkspace {
      guard let evolutionWorkspacePort else {
        throw HarnessCoordinatorError.evolutionWorkspaceUnavailable
      }
      try await evolutionWorkspacePort.prepareAttemptDirectory(
        workspace: workspace, attemptID: attemptID, ordinal: ordinal,
        createdAtUTC: now)
    }
    let attempt = HarnessAttempt(
      attemptID: attemptID, htaskID: snapshot.htaskID,
      ordinal: ordinal,
      hypothesis: decision.hypothesis, strategy: strategy,
      evolutionWorkspace: snapshot.evolutionWorkspace,
      createdAtUTC: now, updatedAtUTC: now)
    try await store.recordAttempt(
      attempt, kind: .created, reasonCode: "strategyAccepted")
    return attempt
  }

  func strategyDescriptor(
    decision: HarnessDecision,
    proposal: HarnessPatchProposal,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessStrategyDescriptor {
    var prerequisites = snapshot.successCriteria.map { "criterion:\($0.criterionID)" }
    if let evaluationID = snapshot.latestEvaluationID,
      let evaluation = try await store.evaluation(snapshot.htaskID, evaluationID: evaluationID)
    {
      prerequisites += evaluation.criterionResults.compactMap { result in
        result.verdict == .fail ? "failed:\(result.criterionID)" : nil
      }
    }
    let buildPreset: String
    if case .string(let declared)? = snapshot.goal.desiredState["buildPresetRef"] {
      buildPreset = declared
    } else {
      buildPreset = "arkdeck-debug"
    }
    return try HarnessStrategyDescriptor(
      hypothesisClass: decision.kind.rawValue,
      selectedOperationFamily: String(
        DebugCrashTaskHandler.applyPatch.split(separator: "@", maxSplits: 1)[0]),
      patchFingerprint: proposal.patchSHA256,
      baseWorkspaceRevision: proposal.baseWorkspaceRevision,
      artifactSourceSet: decision.requiredArtifacts.isEmpty
        ? snapshot.artifactRefs : decision.requiredArtifacts,
      prerequisiteSet: prerequisites,
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: snapshot.target.targetID,
        toolchainProfile: buildPreset,
        expectedNextObservation: decision.expectedObservation ?? "PATCH_APPLIED"))
  }

  func activeAttempt(_ taskID: String) async throws -> HarnessAttempt? {
    try await store.attempts(taskID).last(where: { $0.outcome == .active })
  }

  func activeAttemptSupportsActionRetry(_ taskID: String) async throws -> Bool {
    guard let attempt = try await activeAttempt(taskID) else { return false }
    // The initial journey Attempt supplies the mandatory execution identity;
    // it does not broaden the legacy retry policy for diagnostic operations.
    return attempt.strategy.hypothesisClass != "taskJourney"
  }

  /// A human resolution continues the same strategy; it does not mint a new
  /// Attempt or erase the ActionRuns and evaluations already attached to it.
  /// Reactivate the durable Attempt before the task becomes runnable so a
  /// failed task-state commit can never leave an untracked running repair.
  func reactivateHumanRequiredAttempt(_ taskID: String) async throws {
    guard let attempt = try await store.attempts(taskID).last,
      attempt.outcome == .humanRequired
    else { return }
    try await store.recordAttempt(
      attempt.closing(.active, atUTC: nowUTC()), kind: .resumed,
      reasonCode: "humanResolutionReactivatedAttempt")
  }

  /// Associate a fresh runtime request with the active strategy before its
  /// dispatch intent can reach the engine. The pending intent is already
  /// durable, so a crash before this append can recover the same ActionRun
  /// and idempotency key rather than minting a confirmed retry.
  func recordAttemptActionRun(
    snapshot: HarnessTaskSnapshot,
    operationReference: String,
    inputsDigest: String,
    actionRunID: String
  ) async throws {
    guard let attempt = try await activeAttempt(snapshot.htaskID) else { return }
    if attempt.actionRunIDs.contains(actionRunID) { return }
    // The initial Attempt is an execution identity for the bounded journey,
    // not a source-repair strategy. Repeated observations are normal product
    // progress and must not enter patch deduplication or retry accounting.
    if attempt.strategy.hypothesisClass == "taskJourney" {
      try await store.recordAttempt(
        attempt.recordingActionRun(actionRunID, atUTC: nowUTC()),
        kind: .actionRunRecorded, reasonCode: "taskJourneyActionPlanned")
      return
    }
    // Verification explicitly requires multiple independent samples. The
    // capture inputs are intentionally identical, but each invocation is a
    // new observation in the same repair Attempt, not a replay of a failed
    // ActionRun and not a second repair strategy.
    if operationReference == DebugCrashTaskHandler.captureDiagnostics,
      snapshot.phase == .verifying,
      snapshot.repairAttempt?.deployedDigest != nil,
      snapshot.observed.latestVerdict == .inconclusive
    {
      try await store.recordAttempt(
        attempt.recordingActionRun(actionRunID, atUTC: nowUTC()),
        kind: .actionRunRecorded, reasonCode: "verificationSamplePlanned")
      return
    }
    let intents = try await store.intents(snapshot.htaskID)
    let identical = intents.filter {
      attempt.actionRunIDs.contains($0.requestID)
        && $0.operationReference == operationReference
        && $0.inputsDigestSHA256 == inputsDigest
    }
    let failure: HarnessFailureFingerprint?
    if let digest = attempt.failureFingerprint {
      failure = try await store.failureRecord(digest: digest)?.fingerprint
    } else {
      failure = nil
    }
    let route = HarnessAttemptPlanner.classify(
      attempts: [attempt],
      candidateStrategyFingerprint: attempt.strategyFingerprint,
      identicalActionRunCount: identical.count,
      failure: failure,
      retrySafe:
        Self.isActionRetrySafe(operationReference)
        || Self.isConfirmedDeploymentPreflightRetry(
          operationReference: operationReference, failure: failure),
      maxActionRetriesPerRun: snapshot.budgets.maxActionRetriesPerRun)
    switch route {
    case .continueAttempt, .actionRetry:
      let updated = attempt.recordingActionRun(actionRunID, atUTC: nowUTC())
      try await store.recordAttempt(
        updated, kind: .actionRunRecorded,
        reasonCode: identical.isEmpty ? "actionRunPlanned" : "confirmedActionRetry")
    case .duplicateStrategy(let attemptID):
      throw HarnessAttemptAdmissionError.duplicateStrategy(attemptID)
    case .actionRetryBudgetExhausted(let attemptID, let retries):
      throw HarnessAttemptAdmissionError.actionRetryBudgetExhausted(
        attemptID: attemptID, retries: retries)
    case .crashReplay, .newAttempt:
      // `newAttempt` cannot occur because the active attempt itself was
      // supplied. `crashReplay` belongs only to unresolved-intent recovery.
      throw HarnessAttemptAdmissionError.duplicateStrategy(attempt.attemptID)
    }
  }

  func recordAttemptPatchRevision(_ revision: String, taskID: String) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingPatchRevision(revision, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .patchRevisionObserved, reasonCode: "patchRevisionReadback")
  }

  func recordAttemptFailure(
    taskID: String,
    fingerprint: HarnessFailureFingerprint,
    outcome: HarnessAttemptOutcome
  ) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingFailure(
      fingerprint.digest, outcome: outcome, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .failureRecorded,
      reasonCode: fingerprint.retryDisposition.rawValue)
  }

  func recordAttemptEvaluation(
    taskID: String,
    evaluation: HarnessEvaluation,
    outcome: HarnessAttemptOutcome? = nil
  ) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let confirmed = evaluation.criterionResults.compactMap {
      $0.verdict == .pass ? "\($0.criterionID)=pass" : nil
    }
    let disproved = evaluation.criterionResults.compactMap {
      $0.verdict == .fail ? "\($0.criterionID)=fail" : nil
    }
    let updated = attempt.recordingEvaluation(
      evaluation.evaluationID, confirmedFacts: confirmed, disprovedFacts: disproved,
      verdict: evaluation.verdict, outcome: outcome, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .evaluationRecorded,
      reasonCode: "evaluation:\(evaluation.verdict.rawValue)")
  }

  func recordAttemptCandidatePatch(
    _ candidate: HarnessCandidatePatch, taskID: String
  ) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingCandidatePatch(candidate, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .candidatePatchRecorded, reasonCode: "candidatePatchPublished")
  }

  func recordAttemptBuildArtifacts(_ artifactIDs: [String], taskID: String) async throws {
    guard !artifactIDs.isEmpty, let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingBuildArtifacts(artifactIDs, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .buildArtifactsRecorded, reasonCode: "buildArtifactsPublished")
  }

  func recordAttemptRuntimeArtifacts(_ artifactIDs: [String], taskID: String) async throws {
    guard !artifactIDs.isEmpty, let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingRuntimeArtifacts(artifactIDs, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .runtimeArtifactsRecorded, reasonCode: "runtimeArtifactsVerified")
  }

  func recordAttemptPromotion(
    _ promotion: HarnessPromotionCandidate, taskID: String
  ) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let updated = attempt.recordingPromotion(promotion, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .promotionRecorded, reasonCode: "promotionCandidateReady")
  }

  func closeAttemptForNoProgress(_ taskID: String, rounds: Int) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    // A journey identity is not itself the repeated strategy. Keep it active
    // long enough for the policy guard to compare the next typed action with
    // the previous one and issue the existing bounded no-progress stop.
    guard attempt.strategy.hypothesisClass != "taskJourney" else { return }
    let closed = attempt.closing(.noProgress, atUTC: nowUTC())
    try await store.recordAttempt(
      closed, kind: .closed, reasonCode: "maxNoProgressRounds:\(rounds)")
  }

  func closeAttempt(_ taskID: String, outcome: HarnessAttemptOutcome, reason: String) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
    let closed = attempt.closing(outcome, atUTC: nowUTC())
    try await store.recordAttempt(closed, kind: .closed, reasonCode: reason)
  }

  static func isActionRetrySafe(_ operationReference: String) -> Bool {
    guard let descriptor = RuntimeOperationCatalog.descriptor(reference: operationReference) else {
      return false
    }
    // Mutations with unknown or failed outcomes are reconciled/read back;
    // they are never confirmed retries under a new key.
    return descriptor.minimumEffect <= .readOnly
      && ![
        DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
        DebugCrashTaskHandler.revertPatch, DebugCrashTaskHandler.deployHAP,
      ]
      .contains(operationReference)
  }

  /// A device mutation is not generally retry-safe. This one closed case is
  /// different: the protected Runtime reconciled the previous Job to a
  /// terminal, known outcome and durably proved that the target-confirmation
  /// preflight did not execute. A subsequent ActionRun therefore is neither
  /// a replay nor a continuation of unknown intent; it is a new bounded Job
  /// admitted against fresh target facts.
  static func isConfirmedDeploymentPreflightRetry(
    operationReference: String,
    failure: HarnessFailureFingerprint?
  ) -> Bool {
    operationReference == DebugCrashTaskHandler.deployHAP
      && failure?.errorClassification == deploymentPreflightNotExecutedClassification
  }
}
