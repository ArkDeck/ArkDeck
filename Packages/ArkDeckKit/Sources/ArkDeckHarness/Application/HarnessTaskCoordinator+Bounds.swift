// Bounded-execution wiring for the coordinator (CHG-2026-054, TASK-HTP-003).
//
// The reconcile loop lives in HarnessTaskCoordinator.swift; the parts that
// decide *not* to proceed live here so the loop body stays readable:
//
//   * guard refusals turned into task stops, with the right reason code and,
//     where the closed vocabulary covers it, a typed HumanActionRequired;
//   * failure memory writes and lookups (the same failure twice forces a new
//     strategy, three times stops);
//   * progress accounting (a round with no new evidence, no verdict change and
//     no phase move did not make progress);
//   * task and project memory writes, with evidence attached to every entry.

import ArkDeckCore
import ArkDeckRuntime
import Foundation

extension HarnessTaskCoordinator {
  // MARK: - Guard refusals

  /// Turn a refusal into the task stop it implies. Budget and policy refusals
  /// end the task; environment, authorization and exhausted-strategy refusals
  /// stop for a human with a durable block record.
  func stop(
    _ snapshot: HarnessTaskSnapshot,
    refusal: HarnessGuardRefusal,
    round: Int?,
    requestID: String?,
    jobID: String?,
    decisionID: String? = nil
  ) async throws -> HarnessReconcileOutcome {
    let reason = refusal.reasonCode
    // A refused step is still an attempt: "we were going to do X and did not,
    // because Y" belongs in the task's memory for the same reason a failed job
    // does. Without this, guard refusals were the one class of non-event the
    // record could not explain afterwards.
    if let evidenceID = decisionID ?? requestID ?? jobID {
      try await appendTaskMemory(
        snapshot, kind: .attempt,
        summary: "guard refused the proposed step: \(reason)",
        confidence: .observed,
        evidence: HarnessMemoryEvidence(
          jobIDs: [jobID].compactMap { $0 }, requestIDs: [evidenceID],
          artifactIDs: snapshot.artifactRefs))
    }
    if let blockKind = refusal.humanCategory {
      let blocked = try await recordBlock(
        snapshot, block: blockKind, reasonCode: reason, round: round, jobID: jobID,
        requestID: requestID)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
    }
    switch refusal {
    case .budgetExhausted:
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .budgetExhausted, reasonCode: reason, status: .failed,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: reason,
            summary: "Stopped: \(reason) before the criteria were met.",
            evaluationID: snapshot.latestEvaluationID, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedBudgetExhausted, reasonCode: reason)
    default:
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .noSafeAction, reasonCode: reason, status: .failed,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: reason,
            summary: "The guard refused the only proposed step: \(reason).",
            evaluationID: snapshot.latestEvaluationID, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedNoSafeAction, reasonCode: reason)
    }
  }

  /// Persist a human block and move the task to `humanRequired`.
  func recordBlock(
    _ snapshot: HarnessTaskSnapshot,
    block: HarnessHumanBlock,
    reasonCode: String,
    round: Int?,
    jobID: String?,
    requestID: String?,
    modelCallsSpent: Int = 0
  ) async throws -> (snapshot: HarnessTaskSnapshot, action: HarnessStoredHumanAction) {
    try await closeAttempt(
      snapshot.htaskID, outcome: .humanRequired, reason: reasonCode)
    let now = nowUTC()
    let action = HarnessHumanActionFactory.make(
      actionID: actionIDFactory(),
      snapshot: snapshot,
      block: block,
      reasonCode: reasonCode,
      round: round,
      jobID: jobID,
      requestID: requestID,
      evidenceRefs: snapshot.artifactRefs,
      nowUTC: now)
    try await store.putHumanAction(action)
    let updated = try await commit(
      snapshot,
      transition(
        snapshot, causation: .humanBlocked, reasonCode: reasonCode, status: .humanRequired,
        activeJob: .cleared,
        consumedBudget: charging(
          snapshot.consumedBudget, modelCalls: modelCallsSpent),
        jobID: jobID,
        result: HarnessTaskResult(
          outcome: .humanRequired, reasonCode: reasonCode,
          summary: Self.summary(of: action), evaluationID: snapshot.latestEvaluationID,
          artifactRefs: snapshot.artifactRefs)))
    return (updated, action)
  }

  static func summary(of action: HarnessStoredHumanAction) -> String {
    let documentNote =
      action.document == nil
      ? "no closed HumanActionRequired category describes this block"
      : "typed HumanActionRequired recorded"
    return
      "\(action.block.rawValue): \(action.reasonCode) (\(documentNote); resume in "
      + "\(action.resumePhase.rawValue))"
  }

  // MARK: - Failure memory

  func fingerprint(
    _ snapshot: HarnessTaskSnapshot,
    operationReference: String,
    inputsDigest: String,
    errorClassification: String,
    semanticErrorCode: String
  ) -> HarnessFailureFingerprint {
    HarnessFailureFingerprint(
      operationReference: operationReference,
      phase: snapshot.phase,
      // The provider is the one the catalog binds this operation to; reading
      // it from the descriptor keeps the fingerprint honest when the same
      // operation id is served by a different provider in a later revision.
      providerID: RuntimeOperationCatalog.descriptor(reference: operationReference)?
        .provider.rawValue ?? "unknown",
      targetProfile: snapshot.target.targetID,
      normalizedInputsSHA256: inputsDigest,
      errorClassification: errorClassification,
      semanticErrorCode: semanticErrorCode)
  }

  func recordFailure(
    _ snapshot: HarnessTaskSnapshot,
    fingerprint: HarnessFailureFingerprint,
    reasonCode: String,
    jobID: String?,
    requestID: String? = nil
  ) async throws -> HarnessFailureRecord {
    let now = nowUTC()
    let existing = try await store.failureRecord(digest: fingerprint.digest)
    let updated =
      existing?.recording(taskID: snapshot.htaskID, reasonCode: reasonCode, atUTC: now)
      ?? HarnessFailureRecord(
        fingerprint: fingerprint, occurrences: 1, firstSeenUTC: now, lastSeenUTC: now,
        lastReasonCode: reasonCode, observedByTasks: [snapshot.htaskID])
    try await store.putFailureRecord(updated)
    // Not `try?`: a memory write that cannot happen is a storage problem worth
    // failing on, and swallowing it is how the first version recorded failures
    // nobody could later read.
    try await appendTaskMemory(
      snapshot, kind: .attempt,
      summary:
        "\(fingerprint.operationReference) failed (\(reasonCode)); fingerprint "
        + "\(updated.digest) now at \(updated.occurrences) occurrence(s), stance "
        + "\(updated.stance.rawValue)",
      confidence: .observed,
      evidence: HarnessMemoryEvidence(
        jobIDs: [jobID].compactMap { $0 },
        requestIDs: [requestID].compactMap { $0 },
        artifactIDs: snapshot.artifactRefs))
    return updated
  }

  func failureRecord(for fingerprint: HarnessFailureFingerprint) async -> HarnessFailureRecord? {
    try? await store.failureRecord(digest: fingerprint.digest)
  }

  // MARK: - Progress

  /// Compare the state before and after a round. Only measurable change
  /// counts; a new hypothesis is not progress.
  static func progress(
    before: HarnessTaskSnapshot,
    after: HarnessTaskSnapshot,
    newFailures: Int
  ) -> HarnessProgressVector {
    let beforeObserved = before.observed
    let afterObserved = after.observed
    let sampleDelta =
      afterObserved.samples.values.reduce(0, +) - beforeObserved.samples.values.reduce(0, +)
    let newEvidence = Set(after.artifactRefs).subtracting(Set(before.artifactRefs)).count
    return HarnessProgressVector(
      verdictChanged: beforeObserved.latestVerdict != afterObserved.latestVerdict,
      evaluationRecorded: before.latestEvaluationID != after.latestEvaluationID,
      newVerifiedEvidenceCount: newEvidence,
      sampleDelta: sampleDelta,
      phaseChanged: before.phase != after.phase,
      newFailureCount: newFailures,
      resolvedFailureCount: 0,
      workspaceRevisionChanged:
        before.repairAttempt?.patchRevision != after.repairAttempt?.patchRevision)
  }

  // MARK: - Task and project memory

  func appendTaskMemory(
    _ snapshot: HarnessTaskSnapshot,
    kind: HarnessMemoryKind,
    summary: String,
    confidence: HarnessMemoryConfidence,
    evidence: HarnessMemoryEvidence
  ) async throws {
    let entry = try HarnessMemoryEntry(
      memoryID: memoryIDFactory(),
      scope: .task,
      kind: kind,
      htaskID: snapshot.htaskID,
      projectRef: snapshot.projectRef,
      round: snapshot.activeRound,
      summary: summary,
      confidence: confidence,
      evidence: evidence,
      createdAtUTC: nowUTC())
    try await store.appendMemory(entry)
  }

  /// Promotion to project memory. Only reachable from a passing evaluation:
  /// the entry model itself refuses an `observed` confidence in project scope,
  /// so an unverified guess cannot become long-lived knowledge.
  func promoteProjectMemory(
    _ snapshot: HarnessTaskSnapshot,
    evaluation: HarnessEvaluation
  ) async throws {
    guard evaluation.verdict == .pass, let projectRef = snapshot.projectRef else { return }
    func desiredText(_ key: String) -> String? {
      guard case .string(let value)? = snapshot.goal.desiredState[key] else { return nil }
      return value
    }
    let attempts = try await store.attempts(snapshot.htaskID)
    let lastAttempt = attempts.last
    let revision = snapshot.repairAttempt?.patchRevision ?? lastAttempt?.patchRevision
      ?? lastAttempt?.applicableBaseRevision ?? desiredText("baseWorkspaceRevision")
    let deviceProfiles = [desiredText("deviceProfile")].compactMap { $0 }
    let toolchainProfiles = [
      lastAttempt?.strategy.executionExpectation.toolchainProfile,
      desiredText("buildPresetRef"), desiredText("testPresetRef"),
    ].compactMap { $0 }
    // PASS without exact revision/device/toolchain facts remains task-local.
    // Promoting it cross-task would turn missing scope into a wildcard.
    guard let revision, !deviceProfiles.isEmpty, !toolchainProfiles.isEmpty else { return }
    let criteria = evaluation.criterionResults.map { "\($0.criterionID)=\($0.verdict.rawValue)" }
      .joined(separator: " ")
    let applicability = HarnessMemoryApplicability(
      component: desiredText("component") ?? snapshot.type.rawValue,
      symbols: snapshot.repairAttempt?.proposal.expectedChangedSymbols ?? [],
      filePaths: snapshot.repairAttempt?.proposal.touchedFiles ?? [],
      failureFingerprints: attempts.compactMap(\.failureFingerprint),
      operationReferences: attempts.map { $0.strategy.selectedOperationFamily },
      revisionScope: HarnessMemoryRevisionScope(exactRevision: revision),
      deviceProfiles: deviceProfiles,
      toolchainProfiles: toolchainProfiles)
    let invalidationConditions = [
      HarnessMemoryInvalidationCondition(
        kind: .revisionLeavesScope, expectedValues: [revision]),
      HarnessMemoryInvalidationCondition(
        kind: .deviceProfileLeavesScope, expectedValues: deviceProfiles),
      HarnessMemoryInvalidationCondition(
        kind: .toolchainProfileLeavesScope, expectedValues: toolchainProfiles),
      HarnessMemoryInvalidationCondition(
        kind: .evidenceUnavailable, expectedValues: [evaluation.evaluationID]),
    ]
    let now = nowUTC()
    let entry = try HarnessMemoryEntry(
      memoryID: memoryIDFactory(),
      scope: .project,
      kind: .verifiedKnowledge,
      htaskID: snapshot.htaskID,
      projectRef: projectRef,
      round: snapshot.activeRound,
      summary:
        "Goal met on verified evidence: \(snapshot.goal.summary) [\(criteria)]",
      confidence: .evaluated,
      evidence: HarnessMemoryEvidence(
        jobIDs: [],
        artifactIDs: evaluation.evidence.filter(\.verified).map(\.artifactID),
        evaluationID: evaluation.evaluationID,
        workspaceRevision: revision),
      lifecycle: .verified,
      applicability: applicability,
      invalidationConditions: invalidationConditions,
      verification: HarnessMemoryVerification(
        source: .evaluatorPass, evidenceID: evaluation.evaluationID,
        verifiedAtUTC: now),
      createdAtUTC: now)
    try await store.appendMemory(entry)
  }

  public func taskMemory(_ taskID: String) async throws -> [HarnessMemoryEntry] {
    let snapshot = try await status(taskID)
    var entries = try await store.memory(scope: .task, key: taskID)
    if let projectRef = snapshot.projectRef {
      entries += try await store.memory(scope: .project, key: projectRef)
        .filter { $0.htaskID == taskID }
    }
    return HarnessMemorySelector.collapse(entries)
  }

  public func projectMemory(_ projectRef: String) async throws -> [HarnessMemoryEntry] {
    try await store.memory(scope: .project, key: projectRef)
  }

  public func humanActions(_ taskID: String) async throws -> [HarnessStoredHumanAction] {
    _ = try await status(taskID)
    return try await store.humanActions(taskID)
  }
}
