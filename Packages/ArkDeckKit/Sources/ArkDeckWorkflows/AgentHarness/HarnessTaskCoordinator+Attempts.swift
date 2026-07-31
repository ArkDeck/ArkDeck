// Strategy Attempt wiring (CHG-2026-055, TASK-HFA-004).

import ArkDeckCore
import ArkDeckStorage
import Foundation

enum HarnessAttemptAdmissionError: Error, Equatable, Sendable {
  case duplicateStrategy(String)
  case actionRetryBudgetExhausted(attemptID: String, retries: Int)

  var reasonCode: String {
    switch self {
    case .duplicateStrategy(let attemptID):
      return "DUPLICATE_STRATEGY:\(attemptID)"
    case .actionRetryBudgetExhausted(let attemptID, let retries):
      return "maxActionRetriesPerRunExhausted:\(attemptID):\(retries)"
    }
  }
}

extension HarnessTaskCoordinator {
  func beginStrategyAttempt(
    decision: HarnessDecision,
    proposal: HarnessPatchProposal,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessAttempt {
    let strategy = try await strategyDescriptor(
      decision: decision, proposal: proposal, snapshot: snapshot)
    var attempts = try await store.attempts(snapshot.htaskID)
    if let same = attempts.last(where: { $0.strategyFingerprint == strategy.fingerprint }) {
      // A crash after the Attempt event but before the first ActionRun may
      // resume that empty Attempt. Once an action exists, rewording the
      // hypothesis cannot mint another try.
      if same.outcome == .active, same.actionRunIDs.isEmpty { return same }
      throw HarnessAttemptAdmissionError.duplicateStrategy(same.attemptID)
    }
    if let active = attempts.last(where: { $0.outcome == .active }) {
      let closed = active.closing(.superseded, atUTC: nowUTC())
      try await store.recordAttempt(
        closed, kind: .closed, reasonCode: "newStrategySupersededActiveAttempt")
      attempts = try await store.attempts(snapshot.htaskID)
    }
    let now = nowUTC()
    let attempt = HarnessAttempt(
      attemptID: attemptIDFactory(), htaskID: snapshot.htaskID,
      ordinal: (attempts.map(\.ordinal).max() ?? 0) + 1,
      hypothesis: decision.hypothesis, strategy: strategy,
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
      retrySafe: Self.isActionRetrySafe(operationReference),
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
      outcome: outcome, atUTC: nowUTC())
    try await store.recordAttempt(
      updated, kind: .evaluationRecorded,
      reasonCode: "evaluation:\(evaluation.verdict.rawValue)")
  }

  func closeAttemptForNoProgress(_ taskID: String, rounds: Int) async throws {
    guard let attempt = try await activeAttempt(taskID) else { return }
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
      && ![DebugCrashTaskHandler.applyPatch, DebugCrashTaskHandler.revertPatch,
        DebugCrashTaskHandler.deployHAP].contains(operationReference)
  }
}
