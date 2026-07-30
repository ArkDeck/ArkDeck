// The reconcile loop (CHG-2026-054, TASK-HTP-001).
//
// One wake does at most one thing that can have an effect:
//
//   load snapshot
//     -> resolve an unresolved dispatch intent (recovery) and return
//     -> observe the active job; if it is still running, return
//     -> check budgets; if exhausted, stop
//     -> ask the handler for one step, validate it, dispatch it, return
//
// There is deliberately no `while` here. A loop that kept asking and
// executing inside one wake would have no safe boundary for a daemon
// restart, a device disconnect or a cancel, which is the failure mode this
// plane exists to bound (PRODUCT-LOOP §6 GJ-5, CHG-2026-054 HTP-INV-3).
//
// The coordinator is an actor, so wakes for the same task serialise. That
// is what makes "at most one effectful job per wake" hold under concurrent
// callers rather than only under a polite one.

import ArkDeckCore
import ArkDeckStorage
import Foundation

public enum HarnessReconcileAction: String, Sendable, Codable {
  case terminal
  case paused
  case awaitingHuman
  case admitted
  case recoveredIntent
  case waitedForActiveJob
  case observedJob
  case dispatched
  case cancelled
  case stoppedForHuman
  case stoppedNoSafeAction
  case stoppedBudgetExhausted
  case stoppedJobFailed
  case evaluatedSucceeded
  case evaluatedFailedCriteria
  case evaluatedInconclusive
  case stoppedEvidenceIntegrity
}

public struct HarnessReconcileOutcome: Sendable, Equatable {
  public let snapshot: HarnessTaskSnapshot
  public let action: HarnessReconcileAction
  public let dispatchedJobID: String?
  public let reasonCode: String

  public init(
    snapshot: HarnessTaskSnapshot,
    action: HarnessReconcileAction,
    dispatchedJobID: String? = nil,
    reasonCode: String
  ) {
    self.snapshot = snapshot
    self.action = action
    self.dispatchedJobID = dispatchedJobID
    self.reasonCode = reasonCode
  }
}

public enum HarnessCoordinatorError: Error, Equatable, Sendable {
  case unsupportedTaskType(HarnessTaskType)
  case notFound(String)
  case notPausable(HarnessTaskStatus)
  case notResumable(HarnessTaskStatus)
  case emptyResolution
  case missingDecisionRecord(round: Int)
  case malformedRequest(String)
}

public actor HarnessTaskCoordinator {
  private let store: HarnessTaskStore
  private let jobPort: any HarnessRuntimeJobPort
  /// Absent means no evidence can be read, so no task can ever be judged.
  /// The loop then stops honestly at the handler's "evaluation unavailable"
  /// step instead of pretending a verdict.
  private let artifactPort: (any HarnessArtifactPort)?
  private let handlers: [HarnessTaskType: any HarnessTaskHandler]
  private let nowUTC: @Sendable () -> String
  private let taskIDFactory: @Sendable () -> String
  private let decisionIDFactory: @Sendable () -> String
  private let evaluationIDFactory: @Sendable () -> String

  public init(
    store: HarnessTaskStore,
    jobPort: any HarnessRuntimeJobPort,
    artifactPort: (any HarnessArtifactPort)? = nil,
    handlers: [any HarnessTaskHandler] = [DebugCrashTaskHandler()],
    nowUTC: @escaping @Sendable () -> String,
    taskIDFactory: @escaping @Sendable () -> String = { HarnessTaskCoordinator.freshTaskID() },
    decisionIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshDecisionID()
    },
    evaluationIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshEvaluationID()
    }
  ) {
    self.store = store
    self.jobPort = jobPort
    self.artifactPort = artifactPort
    self.handlers = Dictionary(
      handlers.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
    self.nowUTC = nowUTC
    self.taskIDFactory = taskIDFactory
    self.decisionIDFactory = decisionIDFactory
    self.evaluationIDFactory = evaluationIDFactory
  }

  public static func freshTaskID() -> String {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return "HTASK-\(hex.prefix(12))"
  }

  /// The closed operation set a task type permits when a submission does
  /// not narrow it. Narrowing is allowed; widening is not expressible.
  public static func defaultPolicy(for type: HarnessTaskType) -> HarnessTaskPolicy {
    switch type {
    case .debugCrash:
      return HarnessTaskPolicy(
        allowedOperations: DebugCrashTaskHandler().permittedOperations.sorted())
    }
  }

  public static func freshDecisionID() -> String {
    "dec-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))"
  }

  public static func freshEvaluationID() -> String {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return "EVAL-\(hex.prefix(12))"
  }

  // MARK: - Task lifecycle

  public func submit(_ submission: HarnessTaskSubmission) async throws -> HarnessTaskSnapshot {
    guard let handler = handlers[submission.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(submission.type)
    }
    try submission.validate(permittedOperations: handler.permittedOperations)
    let now = nowUTC()
    let snapshot = HarnessTaskSnapshot(
      htaskID: taskIDFactory(),
      type: submission.type,
      intakeDescription: submission.intakeDescription,
      projectRef: submission.projectRef,
      target: submission.target,
      goal: submission.goal,
      successCriteria: submission.successCriteria.isEmpty
        ? handler.defaultSuccessCriteria() : submission.successCriteria,
      budgets: submission.budgets,
      policy: submission.policy,
      createdAtUTC: now,
      updatedAtUTC: now)
    try await store.create(snapshot)
    return snapshot
  }

  public func status(_ taskID: String) async throws -> HarnessTaskSnapshot {
    try await load(taskID)
  }

  public func list() async throws -> [HarnessTaskSnapshot] {
    try await store.list()
  }

  public func events(_ taskID: String) async throws -> [HarnessTaskEvent] {
    _ = try await load(taskID)
    return try await store.events(taskID)
  }

  /// Durable verdict records. A human deciding on a stopped task reads
  /// these, not a summary string.
  public func evaluations(_ taskID: String) async throws -> [HarnessEvaluation] {
    _ = try await load(taskID)
    return try await store.evaluations(taskID)
  }

  public func result(_ taskID: String) async throws -> HarnessTaskResult? {
    try await load(taskID).result
  }

  public func pause(_ taskID: String) async throws -> HarnessTaskSnapshot {
    let snapshot = try await load(taskID)
    guard snapshot.status == .running || snapshot.status == .created else {
      throw HarnessCoordinatorError.notPausable(snapshot.status)
    }
    // Pausing does not abandon an in-flight job: it stops the harness from
    // starting anything new. The active job stays owned by the engine and
    // is observed on resume.
    return try await commit(
      snapshot,
      transition(
        snapshot, causation: .pauseRequested, reasonCode: "operatorPause", status: .paused,
        activeJob: .unchanged))
  }

  public func resume(_ taskID: String, resolution: String) async throws -> HarnessTaskSnapshot {
    let trimmed = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw HarnessCoordinatorError.emptyResolution }
    let snapshot = try await load(taskID)
    switch snapshot.status {
    case .paused:
      return try await commit(
        snapshot,
        transition(
          snapshot, causation: .resumeRequested, reasonCode: trimmed, status: .running))
    case .humanRequired:
      // A typed resolution is the only way out of a human block. It is
      // recorded as the causation of the transition, so "who unblocked
      // this and on what grounds" survives in the event log.
      return try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanResolved, reasonCode: trimmed, status: .running))
    default:
      throw HarnessCoordinatorError.notResumable(snapshot.status)
    }
  }

  public func cancel(_ taskID: String) async throws -> HarnessTaskSnapshot {
    let snapshot = try await load(taskID)
    if snapshot.status.isTerminal { return snapshot }
    guard let activeJobID = snapshot.activeJobID else {
      return try await commit(
        snapshot,
        transition(
          snapshot, causation: .cancelRequested, reasonCode: "operatorCancel",
          status: .cancelled, activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .cancelled, reasonCode: "operatorCancel",
            summary: "Cancelled with no runtime job in flight.",
            artifactRefs: snapshot.artifactRefs)))
    }
    // A job is in flight. Record the request, ask the engine to cancel at
    // its own safe boundary, and let the next wake finalise once the job
    // is observed terminal. Reporting `cancelled` now would claim a side
    // effect had stopped when it may still be running.
    let marked = try await commit(
      snapshot,
      transition(
        snapshot, causation: .cancelRequested, reasonCode: "operatorCancelPendingActiveJob",
        status: .running, activeJob: .set(activeJobID), cancelRequested: true))
    try? await jobPort.requestCancel(jobID: activeJobID)
    return marked
  }

  /// Daemon start: resolve dispatch intents whose outcome was lost, and
  /// nothing else. Recovery does not start new work - that needs an
  /// explicit reconcile, so a restart can never turn into a burst of
  /// unattended dispatches.
  public func recoverTasks() async throws -> [HarnessTaskSnapshot] {
    var recovered: [HarnessTaskSnapshot] = []
    for snapshot in try await store.list() where !snapshot.status.isTerminal {
      let unresolved = try await store.unresolvedIntents(snapshot.htaskID)
      guard !unresolved.isEmpty else { continue }
      recovered.append(try await resolve(unresolved[0], snapshot: snapshot).snapshot)
    }
    return recovered
  }

  // MARK: - Reconcile

  public func reconcile(_ taskID: String) async throws -> HarnessReconcileOutcome {
    var snapshot = try await load(taskID)

    if snapshot.status.isTerminal {
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .terminal, reasonCode: snapshot.status.rawValue)
    }
    if snapshot.status == .paused {
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .paused, reasonCode: "operatorPause")
    }
    if snapshot.status == .humanRequired {
      // No automatic escape from a human block: a typed resolution has to
      // arrive through `resume`.
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .awaitingHuman,
        reasonCode: snapshot.result?.reasonCode ?? "humanActionRequired")
    }
    if snapshot.status == .created {
      snapshot = try await commit(
        snapshot,
        transition(
          snapshot, causation: .admitted, reasonCode: "taskAdmitted", status: .running,
          phase: .initializing))
    }

    // 1. Recovery before anything new. An unresolved intent means a side
    //    effect may already exist without a link to this task.
    let unresolved = try await store.unresolvedIntents(taskID)
    if let intent = unresolved.first {
      return try await resolve(intent, snapshot: snapshot)
    }

    // 2. An active job owns the round until it reaches a terminal state.
    if let activeJobID = snapshot.activeJobID {
      let observation = try await jobPort.observe(jobID: activeJobID)
      guard observation.isTerminal else {
        return HarnessReconcileOutcome(
          snapshot: snapshot, action: .waitedForActiveJob, reasonCode: observation.state)
      }
      let outcome = try await apply(observation, to: snapshot)
      snapshot = outcome.snapshot
      if snapshot.status != .running {
        return outcome
      }
    }

    // 3. Budgets. Exhaustion is a stop, never a "try once more".
    if let exhausted = budgetExhaustion(snapshot) {
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .budgetExhausted, reasonCode: exhausted, status: .failed,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: exhausted,
            summary: "Stopped: \(exhausted) reached before the criteria were met.",
            artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedBudgetExhausted, reasonCode: exhausted)
    }

    // 4. One step from the handler, validated before it can become a job.
    guard let handler = handlers[snapshot.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
    }
    let step = handler.plan(
      for: snapshot, decisionID: decisionIDFactory(), nowUTC: nowUTC())
    try await store.putDecision(step.decision)

    switch step.decision.kind {
    case .requestHuman:
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanBlocked, reasonCode: step.decision.reasonCode,
          status: .humanRequired, activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: step.decision.reasonCode,
            summary: step.decision.hypothesis, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: blocked, action: .stoppedForHuman, reasonCode: step.decision.reasonCode)
    case .noSafeAction:
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .noSafeAction, reasonCode: step.decision.reasonCode,
          status: .failed, activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: step.decision.reasonCode,
            summary: step.decision.hypothesis, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedNoSafeAction, reasonCode: step.decision.reasonCode)
    case .invokeOperation:
      return try await dispatch(step, snapshot: snapshot, handler: handler)
    }
  }

  // MARK: - Dispatch and recovery

  private func dispatch(
    _ step: HarnessPlannedStep,
    snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler
  ) async throws -> HarnessReconcileOutcome {
    let decision = step.decision
    guard let operationReference = decision.operationReference,
      snapshot.policy.allowedOperations.contains(operationReference),
      handler.permittedOperations.contains(operationReference)
    else {
      // Fail closed rather than throwing: an out-of-policy proposal is a
      // stop condition for this task, not a daemon fault.
      let reason = "operationNotPermitted:\(decision.operationReference ?? "-")"
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .noSafeAction, reasonCode: reason, status: .failed,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: reason,
            summary: "The proposed operation is outside this task's allowed set.",
            artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedNoSafeAction, reasonCode: reason)
    }

    let digest = HarnessRequestIdentity.inputsDigest(decision.inputs)
    let identity = HarnessRequestIdentity.derive(
      htaskID: snapshot.htaskID, round: decision.round, decisionID: decision.decisionID,
      operationReference: operationReference, targetID: snapshot.target.targetID,
      inputsDigest: digest)
    let now = nowUTC()
    let intent = HarnessDispatchIntent(
      htaskID: snapshot.htaskID,
      round: decision.round,
      decisionID: decision.decisionID,
      operationReference: operationReference,
      targetID: snapshot.target.targetID,
      expectedBindingRevision: snapshot.target.expectedBindingRevision,
      inputsDigestSHA256: digest,
      requestID: identity.requestID,
      idempotencyKey: identity.idempotencyKey,
      state: .pending,
      jobID: nil,
      createdAtUTC: now,
      updatedAtUTC: now)
    // Intent before effect, in two records: `pending` proves nothing was
    // handed to the engine yet, `submitted` proves it may have been. Both
    // recover through the same key, but the log stays honest about which
    // window a crash landed in.
    try await store.putIntent(intent)
    let submitting = intent.withState(.submitted, atUTC: nowUTC())
    try await store.putIntent(submitting)

    let acceptance = try await submitOrRecord(submitting, decision: decision, snapshot: snapshot)
    switch acceptance {
    case .rejected(let outcome):
      return outcome
    case .accepted(let accepted):
      try await store.putIntent(
        submitting.withState(.linked, jobID: accepted.jobID, atUTC: nowUTC()))
      try await jobPort.startRun(jobID: accepted.jobID)
      let dispatched = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobDispatched, reasonCode: decision.reasonCode,
          status: .running, phase: step.phaseOnDispatch ?? snapshot.phase,
          activeRound: decision.round, activeJob: .set(accepted.jobID),
          consumedBudget: HarnessConsumedBudget(
            rounds: max(snapshot.consumedBudget.rounds, decision.round),
            wallClockSeconds: snapshot.consumedBudget.wallClockSeconds,
            artifactBytes: snapshot.consumedBudget.artifactBytes,
            e1Mutations: snapshot.consumedBudget.e1Mutations),
          jobID: accepted.jobID))
      return HarnessReconcileOutcome(
        snapshot: dispatched, action: .dispatched, dispatchedJobID: accepted.jobID,
        reasonCode: decision.reasonCode)
    }
  }

  private enum SubmitResult {
    case accepted(HarnessJobAcceptance)
    case rejected(HarnessReconcileOutcome)
  }

  private func submitOrRecord(
    _ intent: HarnessDispatchIntent,
    decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) async throws -> SubmitResult {
    do {
      return .accepted(
        try await jobPort.submit(requestJSON: try requestBytes(intent, decision, snapshot)))
    } catch HarnessJobPortError.rejected(let message) {
      // Admission refused. Zero side effect, and an identical retry would
      // be refused identically - so the intent is closed as `rejected` and
      // the task stops for a human instead of spinning.
      try await store.putIntent(intent.withState(.rejected, atUTC: nowUTC()))
      let reason = "submissionRejected"
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanBlocked, reasonCode: reason, status: .humanRequired,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: reason,
            summary: "Runtime admission refused \(intent.operationReference): \(message)",
            artifactRefs: snapshot.artifactRefs)))
      return .rejected(
        HarnessReconcileOutcome(
          snapshot: blocked, action: .stoppedForHuman, reasonCode: reason))
    }
    // Any other failure (transport, unknown) leaves the intent at
    // `submitted` and propagates: the next wake resolves it through the
    // recovery path with the same key. Never a new key, never a guess.
  }

  private func resolve(
    _ intent: HarnessDispatchIntent,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessReconcileOutcome {
    guard let decision = try await store.decision(snapshot.htaskID, round: intent.round) else {
      throw HarnessCoordinatorError.missingDecisionRecord(round: intent.round)
    }
    let submitting =
      intent.state == .pending ? intent.withState(.submitted, atUTC: nowUTC()) : intent
    if intent.state == .pending {
      try await store.putIntent(submitting)
    }
    let acceptance = try await submitOrRecord(submitting, decision: decision, snapshot: snapshot)
    switch acceptance {
    case .rejected(let outcome):
      return outcome
    case .accepted(let accepted):
      try await store.putIntent(
        submitting.withState(.linked, jobID: accepted.jobID, atUTC: nowUTC()))
      try await jobPort.startRun(jobID: accepted.jobID)
      guard snapshot.activeJobID == nil else {
        // The link was already recorded in the task state; only the intent
        // record lagged. Nothing further to transition.
        return HarnessReconcileOutcome(
          snapshot: snapshot, action: .recoveredIntent, dispatchedJobID: accepted.jobID,
          reasonCode: "intentRecordCaughtUp")
      }
      let linked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobDispatched,
          reasonCode: "recoveredDispatchIntent:\(accepted.deduplicated ? "deduplicated" : "fresh")",
          status: .running, activeRound: max(snapshot.activeRound, intent.round),
          activeJob: .set(accepted.jobID),
          consumedBudget: HarnessConsumedBudget(
            rounds: max(snapshot.consumedBudget.rounds, intent.round),
            wallClockSeconds: snapshot.consumedBudget.wallClockSeconds,
            artifactBytes: snapshot.consumedBudget.artifactBytes,
            e1Mutations: snapshot.consumedBudget.e1Mutations),
          jobID: accepted.jobID))
      return HarnessReconcileOutcome(
        snapshot: linked, action: .recoveredIntent, dispatchedJobID: accepted.jobID,
        reasonCode: accepted.deduplicated ? "deduplicated" : "fresh")
    }
  }

  private func apply(
    _ observation: HarnessJobObservation,
    to snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessReconcileOutcome {
    let operationReference =
      (try await store.intent(snapshot.htaskID, round: snapshot.activeRound))?.operationReference
      ?? "-"

    if observation.outcomeUnknown {
      // The one rule that has no exception: an unknown outcome stops the
      // task and never re-sends the side effect (HTP-INV-5).
      let reason = "outcomeUnknown:\(operationReference)"
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanBlocked, reasonCode: reason, status: .humanRequired,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: reason,
            summary:
              "Job \(observation.jobID) ended in state \(observation.state) with an unknown "
              + "outcome; the harness will not re-send the original side effect.",
            artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: blocked, action: .stoppedForHuman, reasonCode: reason)
    }

    if snapshot.cancelRequested {
      let cancelled = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobObserved, reasonCode: "cancelCompletedAfterActiveJob",
          status: .cancelled, activeJob: .cleared, cancelRequested: true,
          jobID: observation.jobID,
          result: HarnessTaskResult(
            outcome: .cancelled, reasonCode: "operatorCancel",
            summary: "Cancelled after job \(observation.jobID) reached \(observation.state).",
            artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: cancelled, action: .cancelled, reasonCode: "operatorCancel")
    }

    guard observation.succeeded else {
      // Retry policy, failure fingerprints and alternative strategies are
      // TASK-HTP-003. Until they exist a failed operation stops the task
      // with the real reason instead of being retried blindly.
      let reason = "operationFailed:\(operationReference):\(observation.state)"
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobObserved, reasonCode: reason, status: .failed,
          activeJob: .cleared, jobID: observation.jobID,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: reason,
            summary: "Job \(observation.jobID) ended in \(observation.state).",
            artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedJobFailed, reasonCode: reason)
    }

    guard let handler = handlers[snapshot.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
    }
    let nextPhase = handler.phase(afterSuccessOf: operationReference, in: snapshot.phase)
    let advanced = try await commit(
      snapshot,
      transition(
        snapshot, causation: .jobObserved, reasonCode: "operationSucceeded:\(operationReference)",
        status: .running, phase: nextPhase, activeJob: .cleared, jobID: observation.jobID))
    // Evidence exists now, so it gets judged now: the evaluator is the only
    // component that may end this task successfully, and it runs on the bytes
    // the job just published rather than on the decision that asked for them.
    switch try await evaluate(advanced, jobID: observation.jobID) {
    case .ended(let outcome):
      return outcome
    case .continues(let evaluated):
      // The evaluation wrote observed state, so the caller must plan against
      // the *new* version. Handing back a stale snapshot here is what made
      // the next commit fail on an optimistic-lock conflict.
      return HarnessReconcileOutcome(
        snapshot: evaluated, action: .observedJob, reasonCode: observation.state)
    }
  }

  // MARK: - Evaluation

  private enum EvaluationStep {
    /// The verdict ended this wake: success, an integrity stop, or an
    /// escalation the loop must not walk past.
    case ended(HarnessReconcileOutcome)
    /// The loop may keep planning this wake, against this snapshot version.
    case continues(HarnessTaskSnapshot)
  }

  private func evaluate(
    _ snapshot: HarnessTaskSnapshot,
    jobID: String
  ) async throws -> EvaluationStep {
    guard let artifactPort else {
      // No evidence port in this composition, so nothing can ever be judged.
      // Stop for a human at the point a verdict would be needed rather than
      // capturing on a loop until the round budget runs out - the reason a
      // task stopped has to be the real one.
      guard [.collecting, .analyzing, .verifying].contains(snapshot.phase) else {
        return .continues(snapshot)
      }
      let reason = "evaluationEngineUnavailable"
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanBlocked, reasonCode: reason, status: .humanRequired,
          activeJob: .cleared,
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: reason,
            summary:
              "Evidence was collected but this composition has no artifact port, so no "
              + "criterion can be judged.",
            artifactRefs: snapshot.artifactRefs)))
      return .ended(
        HarnessReconcileOutcome(
          snapshot: blocked, action: .stoppedForHuman, reasonCode: reason))
    }
    let builder = HarnessObservationBuilder(artifacts: artifactPort)
    var declaredSignature: String?
    if case .string(let value)? = snapshot.goal.desiredState["crashSignature"] {
      declaredSignature = value
    }
    let required = Set(snapshot.successCriteria.flatMap(\.evidenceRequirements))
    let round = try await builder.observe(
      round: snapshot.activeRound, jobID: jobID, declaredCrashSignature: declaredSignature,
      requiredEvidence: required)

    let merged = snapshot.observed.merging(round)
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: snapshot.successCriteria, observed: merged, round: round,
      evaluationID: evaluationIDFactory(), htaskID: snapshot.htaskID, nowUTC: nowUTC())
    try await store.putEvaluation(evaluation)
    let observedState = merged.recording(verdict: evaluation.verdict, blockers: evaluation.blockers)

    let artifactRefs = Self.mergedArtifactRefs(snapshot, round)
    switch evaluation.verdict {
    case .pass:
      let succeeded = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaPassed",
          status: .succeeded, activeJob: .cleared, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedState.asJSON,
          result: HarnessTaskResult(
            outcome: .succeeded, reasonCode: "criteriaPassed",
            summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs)))
      return .ended(
        HarnessReconcileOutcome(
          snapshot: succeeded, action: .evaluatedSucceeded, reasonCode: "criteriaPassed"))
    case .error:
      // Unverifiable evidence is not a product verdict. Stop for a human
      // instead of letting a hash mismatch look like a failing fix.
      let reason = "evidenceIntegrity:\(evaluation.blockers.first ?? "unknown")"
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: reason, status: .humanRequired,
          activeJob: .cleared, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedState.asJSON,
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: reason,
            summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs)))
      return .ended(
        HarnessReconcileOutcome(
          snapshot: blocked, action: .stoppedEvidenceIntegrity, reasonCode: reason))
    case .inconclusive:
      let escalation = HarnessCriteriaEvaluator.escalation(
        for: evaluation, criteria: snapshot.successCriteria)
      switch escalation {
      case .requestHuman, .failTask:
        let terminalStatus: HarnessTaskStatus = escalation == .failTask ? .failed : .humanRequired
        let reason = "inconclusive:\(escalation == .failTask ? "failTask" : "requestHuman")"
        let stopped = try await commit(
          snapshot,
          transition(
            snapshot, causation: .evaluation, reasonCode: reason, status: terminalStatus,
            activeJob: .cleared, evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs, observedState: observedState.asJSON,
            result: HarnessTaskResult(
              outcome: terminalStatus, reasonCode: reason,
              summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
              artifactRefs: artifactRefs)))
        return .ended(
          HarnessReconcileOutcome(
            snapshot: stopped,
            action: terminalStatus == .failed ? .stoppedNoSafeAction : .stoppedForHuman,
            reasonCode: reason))
      case .collectMoreEvidence, .none:
        let updated = try await commit(
          snapshot,
          transition(
            snapshot, causation: .evaluation, reasonCode: "inconclusive:collectMoreEvidence",
            status: .running, evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs, observedState: observedState.asJSON))
        return .continues(updated)
      }
    case .fail:
      // A real, evidence-backed failure: keep the task running so this wake
      // can plan against it, bounded by the budget.
      let updated = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaFailed", status: .running,
          evaluationID: evaluation.evaluationID, artifactRefs: artifactRefs,
          observedState: observedState.asJSON))
      return .continues(updated)
    }
  }

  private static func mergedArtifactRefs(
    _ snapshot: HarnessTaskSnapshot,
    _ round: HarnessRoundObservation
  ) -> [String] {
    var refs = snapshot.artifactRefs
    for record in round.evidence where !refs.contains(record.artifactID) {
      refs.append(record.artifactID)
    }
    return refs
  }

  private static func summary(of evaluation: HarnessEvaluation) -> String {
    let parts = evaluation.criterionResults.map { result in
      "\(result.criterionID)=\(result.verdict.rawValue)"
        + (result.blockers.isEmpty ? "" : "(\(result.blockers.joined(separator: ";")))")
    }
    return "verdict=\(evaluation.verdict.rawValue) " + parts.joined(separator: " ")
  }

  // MARK: - Budgets

  private func budgetExhaustion(_ snapshot: HarnessTaskSnapshot) -> String? {
    if snapshot.consumedBudget.rounds >= snapshot.budgets.maxRounds {
      return "maxRoundsExhausted"
    }
    if let elapsed = elapsedSeconds(since: snapshot.createdAtUTC),
      elapsed >= snapshot.budgets.maxWallClockSeconds
    {
      return "maxWallClockExhausted"
    }
    if snapshot.consumedBudget.artifactBytes >= snapshot.budgets.maxArtifactBytes {
      return "maxArtifactBytesExhausted"
    }
    if snapshot.consumedBudget.e1Mutations >= snapshot.budgets.maxE1Mutations,
      snapshot.budgets.maxE1Mutations > 0
    {
      return "maxE1MutationsExhausted"
    }
    return nil
  }

  private func elapsedSeconds(since startUTC: String) -> Int? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let start = formatter.date(from: startUTC),
      let now = formatter.date(from: nowUTC())
    else { return nil }
    return Int(now.timeIntervalSince(start))
  }

  // MARK: - Transition plumbing

  private func load(_ taskID: String) async throws -> HarnessTaskSnapshot {
    do {
      return try await store.load(taskID)
    } catch HarnessTaskStoreError.notFound(let id) {
      throw HarnessCoordinatorError.notFound(id)
    } catch HarnessTaskStoreError.malformedTaskID(let id) {
      throw HarnessCoordinatorError.notFound(id)
    }
  }

  /// Every state change in this file goes through here, and here calls the
  /// reducer. There is no second write path to audit.
  private func commit(
    _ snapshot: HarnessTaskSnapshot,
    _ transition: HarnessTaskTransition
  ) async throws -> HarnessTaskSnapshot {
    let (updated, event) = try HarnessTaskStateReducer.apply(transition, to: snapshot)
    try await store.commit(
      event: event, snapshot: updated, expectedVersion: snapshot.version)
    return updated
  }

  /// Explicit three-way change so "clear the active job" cannot be
  /// confused with "leave it alone" - a double optional here would make
  /// `nil` mean both.
  private enum ActiveJobChange {
    case unchanged
    case cleared
    case set(String)

    func resolve(_ current: String?) -> String? {
      switch self {
      case .unchanged: return current
      case .cleared: return nil
      case .set(let jobID): return jobID
      }
    }
  }

  private func transition(
    _ snapshot: HarnessTaskSnapshot,
    causation: HarnessTaskCausation,
    reasonCode: String,
    status: HarnessTaskStatus,
    phase: HarnessTaskPhase? = nil,
    activeRound: Int? = nil,
    activeJob: ActiveJobChange = .unchanged,
    consumedBudget: HarnessConsumedBudget? = nil,
    cancelRequested: Bool? = nil,
    jobID: String? = nil,
    evaluationID: String? = nil,
    artifactRefs: [String]? = nil,
    observedState: [String: JSONValue]? = nil,
    result: HarnessTaskResult? = nil
  ) -> HarnessTaskTransition {
    HarnessTaskTransition(
      causation: causation,
      reasonCode: reasonCode,
      status: status,
      phase: phase ?? snapshot.phase,
      activeRound: activeRound ?? snapshot.activeRound,
      activeJobID: activeJob.resolve(snapshot.activeJobID),
      consumedBudget: consumedBudget ?? snapshot.consumedBudget,
      jobID: jobID,
      evaluationID: evaluationID,
      artifactRefs: artifactRefs ?? snapshot.artifactRefs,
      observedState: observedState,
      cancelRequested: cancelRequested ?? snapshot.cancelRequested,
      result: result,
      atUTC: nowUTC())
  }

  private func requestBytes(
    _ intent: HarnessDispatchIntent,
    _ decision: HarnessDecision,
    _ snapshot: HarnessTaskSnapshot
  ) throws -> Data {
    let parts = intent.operationReference.split(separator: "@")
    guard parts.count == 2, let version = Int(parts[1]) else {
      throw HarnessCoordinatorError.malformedRequest(intent.operationReference)
    }
    do {
      let request = try RuntimeOperationRequest(
        requestID: intent.requestID,
        idempotencyKey: intent.idempotencyKey,
        target: DurableTargetReference(
          targetID: snapshot.target.targetID,
          expectedBindingRevision: snapshot.target.expectedBindingRevision),
        operation: RuntimeOperationReference(id: String(parts[0]), version: version),
        inputs: decision.inputs,
        requestedOutputs: [.rawArtifacts, .derivedArtifacts],
        // No authorization reference: this task type is E0 only, and the
        // harness never mints or selects a capability (HTP-INV-6).
        authorization: nil,
        // Correlation only. The runtime derives no authority, scope or
        // identity from provenance, which is exactly why the harness id may
        // travel here and nowhere else (HTP-INV-12).
        clientContext: RuntimeClientContext(
          clientName: "arkdeck-harness",
          provenance: [
            "harnessTaskId": snapshot.htaskID,
            "harnessRound": "\(intent.round)",
            "harnessDecisionId": decision.decisionID,
          ]))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(request)
    } catch let error as HarnessCoordinatorError {
      throw error
    } catch {
      throw HarnessCoordinatorError.malformedRequest("\(error)")
    }
  }
}
