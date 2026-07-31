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
  /// The proposal was refused at the dispatch boundary because the facts it
  /// stood on had moved (CHG-2026-055, TASK-HFA-002). Nothing was
  /// submitted; the next wake plans again on current facts.
  case staleDecision
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
  let store: HarnessTaskStore
  let jobPort: any HarnessRuntimeJobPort
  /// Absent means no evidence can be read, so no task can ever be judged.
  /// The loop then stops honestly at the handler's "evaluation unavailable"
  /// step instead of pretending a verdict.
  let artifactPort: (any HarnessArtifactPort)?
  let handlers: [HarnessTaskType: any HarnessTaskHandler]
  let nowUTC: @Sendable () -> String
  let taskIDFactory: @Sendable () -> String
  let decisionIDFactory: @Sendable () -> String
  let evaluationIDFactory: @Sendable () -> String
  let actionIDFactory: @Sendable () -> String
  let memoryIDFactory: @Sendable () -> String
  let modelRunIDFactory: @Sendable () -> String
  let policyGuard: HarnessPolicyGuard
  /// Absent means no model path exists in this composition at all.
  let decisionGateway: (any HarnessDecisionGateway)?
  /// Denied by default: enabling egress is an explicit per-project act.
  let egressPolicy: HarnessEgressPolicy
  /// Privacy-sensitive artifact names an operator allowed this composition to
  /// measure. Empty by default; see `HarnessObservationBuilder`.
  let sensitiveEvidenceAllowList: Set<String>

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
    },
    actionIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshActionID()
    },
    memoryIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshMemoryID()
    },
    modelRunIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshModelRunID()
    },
    policyGuard: HarnessPolicyGuard = HarnessPolicyGuard(),
    decisionGateway: (any HarnessDecisionGateway)? = nil,
    egressPolicy: HarnessEgressPolicy = .deniedByDefault,
    sensitiveEvidenceAllowList: Set<String> = []
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
    self.actionIDFactory = actionIDFactory
    self.memoryIDFactory = memoryIDFactory
    self.modelRunIDFactory = modelRunIDFactory
    self.policyGuard = policyGuard
    self.decisionGateway = decisionGateway
    self.egressPolicy = egressPolicy
    self.sensitiveEvidenceAllowList = sensitiveEvidenceAllowList
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

  public static func freshActionID() -> String {
    "har-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))"
  }

  public static func freshMemoryID() -> String {
    "mem-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))"
  }

  /// Uppercase hex, like an evaluation id: the value becomes a file name,
  /// and the store's grammar check is what keeps it inside its own task
  /// directory (TASK-HFA-002).
  public static func freshModelRunID() -> String {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return "MRUN-\(hex.prefix(12))"
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
      // A typed resolution is the only way out of a human block. The open
      // block record is closed by the same decision, and when it holds a
      // HumanActionRequired that document's own state machine performs the
      // transition - so a resolution its rules reject cannot be recorded.
      let open = (try? await store.humanActions(snapshot.htaskID))?.last { $0.isOpen }
      if let open {
        let resolved = try HarnessHumanActionFactory.resolve(
          open, resolution: trimmed, probeReceiptID: "\(open.actionID)-resolution",
          nowUTC: nowUTC())
        try await store.putHumanAction(resolved)
      }
      return try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanResolved, reasonCode: trimmed, status: .running,
          // A human decision clears the patience counter: the next round is
          // acting on new information, not repeating the old one.
          noProgressRounds: 0))
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

    // 3. Budgets. Exhaustion is a stop, never a "try once more", and it is
    //    checked before planning so an exhausted task cannot spend a decision.
    if let refusal = HarnessPolicyGuard.budgetRefusal(
      snapshot, elapsedSeconds: elapsedSeconds(since: snapshot.createdAtUTC))
    {
      return try await stop(
        snapshot, refusal: refusal, round: snapshot.activeRound, requestID: nil, jobID: nil)
    }

    // 4. One step from the handler, validated before it can become a job.
    guard let handler = handlers[snapshot.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
    }
    // One proposal per wake, from the model path when it is enabled and
    // healthy, otherwise from the deterministic handler - and the record says
    // which, and why (TASK-HTP-004).
    //
    // The basis is taken *before* the proposal, from the snapshot the
    // producer is about to read, and stamped onto whatever comes back. A
    // producer therefore cannot claim facts it did not see, and the
    // dispatch boundary can check the claim (TASK-HFA-002).
    let basis = HarnessDecisionBasis(
      snapshot: snapshot, offeredOperations: offeredOperations(snapshot, handler: handler))
    let proposal = await plannedProposal(snapshot, handler: handler, basis: basis)
    let step = HarnessPlannedStep(
      decision: proposal.step.decision.stamped(with: basis),
      phaseOnDispatch: proposal.step.phaseOnDispatch)
    try await store.putDecision(step.decision)
    if let rejection = proposal.rejection {
      // Visible, not swallowed: the fallback is narrower than the model path,
      // but a reader must be able to see that it happened and why.
      try await appendTaskMemory(
        snapshot, kind: .attempt,
        summary:
          "decision producer fell back to \(step.decision.producer): \(rejection)",
        confidence: .observed,
        evidence: HarnessMemoryEvidence(requestIDs: [step.decision.decisionID]))
    }

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
      let outcome = try await dispatch(
        step, snapshotAtPlanning: snapshot, handler: handler)
      guard let rejection = proposal.rejection, outcome.action == .dispatched else {
        return outcome
      }
      return HarnessReconcileOutcome(
        snapshot: outcome.snapshot, action: outcome.action,
        dispatchedJobID: outcome.dispatchedJobID,
        reasonCode: "\(outcome.reasonCode)|\(rejection)")
    }
  }

  // MARK: - Dispatch and recovery

  private func dispatch(
    _ step: HarnessPlannedStep,
    snapshotAtPlanning: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler
  ) async throws -> HarnessReconcileOutcome {
    let decision = step.decision

    // Freshness before anything that writes (TASK-HFA-002). Planning
    // suspends this actor - the model call is a network round trip - so
    // `resume`, `pause` and `cancel` can land in between. Reload, rebuild
    // the basis, and refuse the step if either moved. The optimistic lock
    // in `commit` would also catch it, but only after the job had been
    // submitted: the side effect would already exist and only the
    // bookkeeping would fail.
    let snapshot = try await load(snapshotAtPlanning.htaskID)
    let currentBasis = HarnessDecisionBasis(
      snapshot: snapshot, offeredOperations: offeredOperations(snapshot, handler: handler))
    if let staleness = HarnessDecisionFreshness.staleness(of: decision, against: currentBasis) {
      return try await recordStale(decision, staleness: staleness, snapshot: snapshot)
    }

    guard let operationReference = decision.operationReference else {
      // Fail closed rather than throwing: a proposal with no operation is a
      // stop condition for this task, not a daemon fault.
      return try await stop(
        snapshot, refusal: .operationNotPermitted("-"), round: decision.round,
        requestID: nil, jobID: nil, decisionID: decision.decisionID)
    }

    let digest = HarnessRequestIdentity.inputsDigest(decision.inputs)

    // Everything that can refuse this step, in one ordered pass: budgets,
    // the closed allow-set, runtime availability, raw-surface screening,
    // effect ceiling and authorization, failure memory, progress and the
    // single-active-job rule (TASK-HTP-003).
    let fingerprintForStep = fingerprint(
      snapshot, operationReference: operationReference, inputsDigest: digest,
      errorClassification: "operationFailed", semanticErrorCode: "priorAttempt")
    let priorFailure = await failureRecord(for: fingerprintForStep)
    let previousIntent = try? await store.intent(snapshot.htaskID, round: snapshot.activeRound)
    let previousStrategy = previousIntent.map { intent in
      HarnessStrategySignature(
        operationReference: intent.operationReference, inputsDigest: intent.inputsDigestSHA256,
        phase: snapshot.phase)
    }
    let verdict = await policyGuard.evaluate(
      HarnessGuardInput(
        snapshot: snapshot,
        operationReference: operationReference,
        inputs: decision.inputs,
        inputsDigest: digest,
        permittedOperations: handler.permittedOperations,
        failureRecord: priorFailure,
        previousStrategy: previousStrategy,
        consecutiveNoProgressRounds: snapshot.noProgressRounds,
        elapsedSeconds: elapsedSeconds(since: snapshot.createdAtUTC)))
    if case .refuse(let refusal) = verdict {
      return try await stop(
        snapshot, refusal: refusal, round: decision.round, requestID: nil, jobID: nil,
        decisionID: decision.decisionID)
    }
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

  /// A stale proposal costs the model call that produced it and nothing
  /// else: no failure fingerprint, no no-progress round, no budget movement
  /// (TASK-HFA-002). Charging it as a strategy failure would let an
  /// operator's own resolution walk a task toward `strategyExhausted`.
  private func recordStale(
    _ decision: HarnessDecision,
    staleness: HarnessDecisionStaleness,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessReconcileOutcome {
    // The task may already have moved somewhere a transition is illegal -
    // a cancel that landed during planning leaves it terminal. There is
    // nothing to record on the task then; the refusal still stands.
    guard snapshot.status == .running else {
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .staleDecision, reasonCode: staleness.reasonCode)
    }
    let updated = try await commit(
      snapshot,
      transition(
        snapshot, causation: .decisionStale, reasonCode: staleness.reasonCode,
        status: .running))
    try await appendTaskMemory(
      updated, kind: .attempt,
      summary:
        "decision \(decision.decisionID) was not dispatched: \(staleness.reasonCode)",
      confidence: .observed,
      evidence: HarnessMemoryEvidence(requestIDs: [decision.decisionID]))
    return HarnessReconcileOutcome(
      snapshot: updated, action: .staleDecision, reasonCode: staleness.reasonCode)
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
      // Admission refused. Zero side effect, and an identical retry would be
      // refused identically - so the intent is closed as `rejected`, the
      // failure is fingerprinted so a later task inherits the knowledge, and
      // the task stops for a human instead of spinning.
      try await store.putIntent(intent.withState(.rejected, atUTC: nowUTC()))
      let print = fingerprint(
        snapshot, operationReference: intent.operationReference,
        inputsDigest: intent.inputsDigestSHA256, errorClassification: "admissionRejected",
        semanticErrorCode: Self.semanticCode(from: message))
      _ = try await recordFailure(
        snapshot, fingerprint: print, reasonCode: "submissionRejected", jobID: nil,
        requestID: intent.requestID)
      let blocked = try await recordBlock(
        snapshot, block: .environmentUnavailable,
        reasonCode: "submissionRejected:\(Self.semanticCode(from: message))",
        round: intent.round, jobID: nil, requestID: intent.requestID)
      return .rejected(
        HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: "submissionRejected"))
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
      // The one rule that has no exception: an unknown outcome stops the task
      // and never re-sends the side effect (HTP-INV-5). It is also the case
      // the closed human-action vocabulary describes exactly, so a typed
      // HumanActionRequired is produced with it.
      let reason = "outcomeUnknown:\(operationReference)"
      let blocked = try await recordBlock(
        snapshot, block: .outcomeUnknown, reasonCode: reason, round: snapshot.activeRound,
        jobID: observation.jobID, requestID: nil)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
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
      // A failed operation is fingerprinted before anything else: the record
      // is what stops the same attempt from being made a third time, in this
      // task or the next one.
      let reason = "operationFailed:\(operationReference):\(observation.state)"
      let digest =
        (try? await store.intent(snapshot.htaskID, round: snapshot.activeRound))?
        .inputsDigestSHA256 ?? HarnessRequestIdentity.inputsDigest([:])
      let print = fingerprint(
        snapshot, operationReference: operationReference, inputsDigest: digest,
        errorClassification: "operationFailed", semanticErrorCode: observation.state)
      let record = try await recordFailure(
        snapshot, fingerprint: print, reasonCode: reason, jobID: observation.jobID)
      if record.stance == .prohibited {
        // Third time: the loop has nothing new to try, so it stops for a
        // human rather than burning the rest of the budget on repetition.
        let blocked = try await recordBlock(
          snapshot, block: .strategyExhausted,
          reasonCode: "repeatedFailureProhibited:\(record.digest):\(record.occurrences)",
          round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: blocked.action.reasonCode)
      }
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobObserved, reasonCode: reason, status: .failed,
          activeJob: .cleared, jobID: observation.jobID,
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: reason,
            summary:
              "Job \(observation.jobID) ended in \(observation.state); failure fingerprint "
              + "\(record.digest) at \(record.occurrences) occurrence(s).",
            evaluationID: snapshot.latestEvaluationID, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedJobFailed, reasonCode: reason)
    }

    guard let handler = handlers[snapshot.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
    }
    let nextPhase = handler.phase(afterSuccessOf: operationReference, in: snapshot.phase)
    try await appendTaskMemory(
      snapshot, kind: .observation,
      summary: "\(operationReference) succeeded in phase \(snapshot.phase.rawValue)",
      confidence: .observed,
      evidence: HarnessMemoryEvidence(
        jobIDs: [observation.jobID], artifactIDs: snapshot.artifactRefs))
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
    let builder = HarnessObservationBuilder(
      artifacts: artifactPort, sensitiveEvidenceAllowList: sensitiveEvidenceAllowList)
    var declaredSignature: String?
    if case .string(let value)? = snapshot.goal.desiredState["crashSignature"] {
      declaredSignature = value
    }
    let required = Set(snapshot.successCriteria.flatMap(\.evidenceRequirements))
    // The crash ledger is cumulative device state, so the builder is told
    // what this task has already accounted for. Absent on the first round
    // with a readable ledger, which is what makes that round a baseline.
    var watermark: String?
    if case .string(let mark)? = snapshot.observed.measurements[
      HarnessObservationBuilder.watermarkMetric]
    {
      watermark = mark
    }
    let round = try await builder.observe(
      round: snapshot.activeRound, jobID: jobID, declaredCrashSignature: declaredSignature,
      requiredEvidence: required, crashLedgerWatermark: watermark)

    let merged = snapshot.observed.merging(round)
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: snapshot.successCriteria, observed: merged, round: round,
      evaluationID: evaluationIDFactory(), htaskID: snapshot.htaskID, nowUTC: nowUTC())
    try await store.putEvaluation(evaluation)
    let observedState = merged.recording(verdict: evaluation.verdict, blockers: evaluation.blockers)

    let artifactRefs = Self.mergedArtifactRefs(snapshot, round)
    // Evidence costs budget: only bytes the harness actually verified and read
    // are charged, and only once per artifact.
    let newlyChargedBytes = round.evidence
      .filter { $0.verified && !snapshot.artifactRefs.contains($0.artifactID) }
      .reduce(0) { $0 + $1.byteCount }
    let consumed = HarnessConsumedBudget(
      rounds: snapshot.consumedBudget.rounds,
      wallClockSeconds: elapsedSeconds(since: snapshot.createdAtUTC)
        ?? snapshot.consumedBudget.wallClockSeconds,
      artifactBytes: snapshot.consumedBudget.artifactBytes + newlyChargedBytes,
      e1Mutations: snapshot.consumedBudget.e1Mutations)
    switch evaluation.verdict {
    case .pass:
      let succeeded = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaPassed",
          status: .succeeded, activeJob: .cleared, consumedBudget: consumed,
          evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedState.asJSON,
          noProgressRounds: 0,
          result: HarnessTaskResult(
            outcome: .succeeded, reasonCode: "criteriaPassed",
            summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs)))
      // Promotion happens only here, behind a passing evaluation: project
      // memory never receives an unverified belief (HTP-INV-1).
      try await promoteProjectMemory(succeeded, evaluation: evaluation)
      return .ended(
        HarnessReconcileOutcome(
          snapshot: succeeded, action: .evaluatedSucceeded, reasonCode: "criteriaPassed"))
    case .error:
      // Unverifiable evidence is not a product verdict. Record the observation
      // and stop for a human instead of letting a hash mismatch look like a
      // failing fix.
      let reason = "evidenceIntegrity:\(evaluation.blockers.first ?? "unknown")"
      let recorded = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: reason, status: .running,
          consumedBudget: consumed, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedState.asJSON))
      let blocked = try await recordBlock(
        recorded, block: .evidenceIntegrity, reasonCode: reason, round: recorded.activeRound,
        jobID: jobID, requestID: nil)
      return .ended(
        HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedEvidenceIntegrity, reasonCode: reason))
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
            activeJob: .cleared, consumedBudget: consumed,
            evaluationID: evaluation.evaluationID,
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
            status: .running, consumedBudget: consumed,
            evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs, observedState: observedState.asJSON,
            noProgressRounds: Self.nextNoProgressRounds(before: snapshot, after: observedState,
              artifactRefs: artifactRefs)))
        return .continues(updated)
      }
    case .fail:
      // A real, evidence-backed failure: keep the task running so this wake
      // can plan against it, bounded by the budget.
      let updated = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaFailed", status: .running,
          consumedBudget: consumed, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedState.asJSON,
          noProgressRounds: Self.nextNoProgressRounds(before: snapshot, after: observedState,
            artifactRefs: artifactRefs)))
      return .continues(updated)
    }
  }

  /// A round that added no verified evidence, no sample and no verdict change
  /// increments the no-progress counter; anything measurable resets it.
  static func nextNoProgressRounds(
    before: HarnessTaskSnapshot,
    after: HarnessObservedState,
    artifactRefs: [String]
  ) -> Int {
    let previous = before.observed
    let sampleDelta = after.samples.values.reduce(0, +) - previous.samples.values.reduce(0, +)
    let newEvidence = Set(artifactRefs).subtracting(Set(before.artifactRefs)).count
    let verdictChanged = previous.latestVerdict != after.latestVerdict
    let progressed = sampleDelta > 0 || newEvidence > 0 || verdictChanged
    return progressed ? 0 : before.noProgressRounds + 1
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

  /// Collapse a runtime rejection message into a stable, identifier-shaped
  /// semantic code so a fingerprint does not vary with prose.
  static func semanticCode(from message: String) -> String {
    let lowered = message.lowercased()
    if lowered.contains("has not been adopted") { return "targetNotAdopted" }
    if lowered.contains("runtime unavailable") || lowered.contains("unavailable") {
      return "operationUnavailable"
    }
    if lowered.contains("authorization") || lowered.contains("capability") {
      return "authorizationRequired"
    }
    if lowered.contains("binding") { return "bindingMismatch" }
    return "rejected"
  }

  static func summary(of evaluation: HarnessEvaluation) -> String {
    let parts = evaluation.criterionResults.map { result in
      "\(result.criterionID)=\(result.verdict.rawValue)"
        + (result.blockers.isEmpty ? "" : "(\(result.blockers.joined(separator: ";")))")
    }
    return "verdict=\(evaluation.verdict.rawValue) " + parts.joined(separator: " ")
  }

  // MARK: - Clock

  func elapsedSeconds(since startUTC: String) -> Int? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let start = formatter.date(from: startUTC),
      let now = formatter.date(from: nowUTC())
    else { return nil }
    return Int(now.timeIntervalSince(start))
  }

  // MARK: - Transition plumbing

  func load(_ taskID: String) async throws -> HarnessTaskSnapshot {
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
  func commit(
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
  enum ActiveJobChange {
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

  func transition(
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
    noProgressRounds: Int? = nil,
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
      noProgressRounds: noProgressRounds,
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
