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
import ArkDeckRuntime
import Foundation

public enum HarnessReconcileAction: String, Sendable, Codable {
  case terminal
  case paused
  case awaitingHuman
  case admitted
  case recoveredIntent
  case waitedForActiveJob
  case reconcileInProgress
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
  /// A model call made for the handler's bounded patch question did not
  /// produce a usable answer. The call is charged and recorded, but the task
  /// stays running so a later wake can try again within `maxModelCalls`.
  case proposalRetryScheduled
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
  case malformedPatchProposal(String)
  case patchProposalNotAllowed(String)
  case patchProposalMismatch
  /// The assembled context failed the identity screen, so it may not be
  /// handed to any producer - external ones included. Carries marker names,
  /// never values.
  case contextNotExportable(String)
  case evolutionWorkspaceUnavailable
  case missingDecisionRecord(round: Int)
  case malformedRequest(String)
}

public actor HarnessTaskCoordinator {
  static let deploymentPreflightNotExecutedClassification =
    "DEPLOYMENT_PREFLIGHT_NOT_EXECUTED"

  /// Swift actors are reentrant at `await`: without an explicit gate, several
  /// concurrent wakes can all plan from the same version and submit distinct
  /// idempotency keys before only one wins the optimistic state commit.
  var reconcilingTaskIDs: Set<String> = []
  let reconcileLeaseHolderID = "HCOORD-\(UUID().uuidString)"
  let store: HarnessTaskStore
  let jobPort: any HarnessRuntimeJobPort
  /// Absent means no evidence can be read, so no task can ever be judged.
  /// The loop then stops honestly at the handler's "evaluation unavailable"
  /// step instead of pretending a verdict.
  let artifactPort: (any HarnessArtifactPort)?
  /// Absent means source repair is unavailable in this composition. It never
  /// falls back to opening workspace paths in the coordinator.
  let repairPort: (any HarnessRepairPort)?
  /// Evolution isolation is a Workspace lifecycle extension. Absent keeps
  /// Normal Mode unchanged and makes Evolution admission fail closed.
  let evolutionWorkspacePort: (any HarnessEvolutionWorkspacePort)?
  let handlers: [HarnessTaskType: any HarnessTaskHandler]
  let nowUTC: @Sendable () -> String
  let taskIDFactory: @Sendable () -> String
  let decisionIDFactory: @Sendable () -> String
  let evaluationIDFactory: @Sendable () -> String
  let actionIDFactory: @Sendable () -> String
  let memoryIDFactory: @Sendable () -> String
  let modelRunIDFactory: @Sendable () -> String
  let attemptIDFactory: @Sendable () -> String
  let promotionCandidateIDFactory: @Sendable () -> String
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
    repairPort: (any HarnessRepairPort)? = nil,
    evolutionWorkspacePort: (any HarnessEvolutionWorkspacePort)? = nil,
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
    attemptIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshAttemptID()
    },
    promotionCandidateIDFactory: @escaping @Sendable () -> String = {
      HarnessTaskCoordinator.freshPromotionCandidateID()
    },
    policyGuard: HarnessPolicyGuard = HarnessPolicyGuard(),
    decisionGateway: (any HarnessDecisionGateway)? = nil,
    egressPolicy: HarnessEgressPolicy = .deniedByDefault,
    sensitiveEvidenceAllowList: Set<String> = []
  ) {
    self.store = store
    self.jobPort = jobPort
    self.artifactPort = artifactPort
    self.repairPort = repairPort
    self.evolutionWorkspacePort = evolutionWorkspacePort
    self.handlers = Dictionary(
      handlers.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
    self.nowUTC = nowUTC
    self.taskIDFactory = taskIDFactory
    self.decisionIDFactory = decisionIDFactory
    self.evaluationIDFactory = evaluationIDFactory
    self.actionIDFactory = actionIDFactory
    self.memoryIDFactory = memoryIDFactory
    self.modelRunIDFactory = modelRunIDFactory
    self.attemptIDFactory = attemptIDFactory
    self.promotionCandidateIDFactory = promotionCandidateIDFactory
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

  public static func freshAttemptID() -> String {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return "ATTEMPT-\(hex.prefix(12))"
  }

  public static func freshPromotionCandidateID() -> String {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    return "PROMOTION-\(hex.prefix(12))"
  }

  // MARK: - Task lifecycle

  public func submit(_ submission: HarnessTaskSubmission) async throws -> HarnessTaskSnapshot {
    guard let handler = handlers[submission.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(submission.type)
    }
    try submission.validate(permittedOperations: handler.permittedOperations)
    let requiredE1Mutations = handler.requiredE1MutationBudget(
      goal: submission.goal, policy: submission.policy)
    if submission.budgets.maxE1Mutations > 0,
      submission.budgets.maxE1Mutations < requiredE1Mutations
    {
      throw HarnessTaskSubmissionError.insufficientE1MutationBudget(
        required: requiredE1Mutations, actual: submission.budgets.maxE1Mutations)
    }
    let now = nowUTC()
    let htaskID = taskIDFactory()
    let evolutionWorkspace: HarnessEvolutionWorkspace?
    if let policy = submission.evolutionPolicy {
      guard let port = evolutionWorkspacePort,
        let sourceProjectRef = submission.projectRef
      else { throw HarnessCoordinatorError.evolutionWorkspaceUnavailable }
      evolutionWorkspace = try await port.prepareWorkspace(
        htaskID: htaskID, sourceProjectRef: sourceProjectRef,
        policy: policy, createdAtUTC: now)
    } else {
      evolutionWorkspace = nil
    }
    let snapshot = HarnessTaskSnapshot(
      htaskID: htaskID,
      type: submission.type,
      intakeDescription: submission.intakeDescription,
      projectRef: submission.projectRef,
      target: submission.target,
      goal: submission.goal,
      successCriteria: submission.successCriteria.isEmpty
        ? handler.defaultSuccessCriteria() : submission.successCriteria,
      budgets: submission.budgets,
      policy: submission.policy,
      evolutionPolicy: submission.evolutionPolicy,
      evolutionWorkspace: evolutionWorkspace,
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

  /// Destroys the isolated trees of terminal evolution tasks per `retention`.
  /// The store is the only authority on lifecycle: the port receives exactly
  /// the workspaces the store can vouch for, and terminal lifecycles are
  /// absorbing, so nothing active can be swept. Audit metadata survives on
  /// the provider side; no host path enters or leaves this call.
  public func sweepEvolutionWorkspaces(
    retention: HarnessEvolutionWorkspaceRetention
  ) async throws -> [HarnessEvolutionWorkspaceGCFinding] {
    guard let port = evolutionWorkspacePort else {
      throw HarnessCoordinatorError.evolutionWorkspaceUnavailable
    }
    let references = try await store.list().compactMap { snapshot in
      snapshot.evolutionWorkspace.map {
        HarnessEvolutionWorkspaceGCTaskReference(
          workspaceID: $0.workspaceID, htaskID: snapshot.htaskID,
          lifecycle: snapshot.lifecycle, updatedAtUTC: snapshot.updatedAtUTC)
      }
    }
    return try await port.sweepTerminalWorkspaces(
      tasks: references, retention: retention, nowUTC: nowUTC())
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

  /// Strategy-level attempts, distinct from runtime ActionRuns/dispatches.
  public func attempts(_ taskID: String) async throws -> [HarnessAttempt] {
    _ = try await load(taskID)
    return try await store.attempts(taskID)
  }

  public func result(_ taskID: String) async throws -> HarnessTaskResult? {
    try await load(taskID).result
  }

  /// Record a typed target/binding observation without moving the product
  /// stage. A changed binding is deliberately UNKNOWN until an operator or
  /// runtime capability confirms it; the version increment also invalidates
  /// every decision made on the previous binding facts.
  public func recordTargetObservation(
    _ taskID: String,
    currentBindingRevision: Int?,
    deviceReady: Bool,
    evidenceArtifactIDs: [String] = []
  ) async throws -> HarnessTaskSnapshot {
    let snapshot = try await load(taskID)
    guard !snapshot.status.isTerminal, snapshot.status != .humanRequired else {
      return snapshot
    }
    let expected = snapshot.target.expectedBindingRevision
    let bindingMatches =
      currentBindingRevision != nil
      && (expected == nil || expected == currentBindingRevision)
    let target = HarnessTaskCondition(
      name: .targetResolved,
      state: currentBindingRevision == nil ? .falseValue : .trueValue,
      reasonCode: currentBindingRevision == nil ? "targetUnavailable" : "targetResolved",
      message: "observed binding revision \(currentBindingRevision.map(String.init) ?? "none")",
      evidenceArtifactIDs: evidenceArtifactIDs, observedAt: nowUTC(),
      observedRevision: snapshot.version + 1)
    let bound = HarnessTaskCondition(
      name: .deviceBound, state: bindingMatches ? .trueValue : .unknown,
      reasonCode: bindingMatches ? "bindingRevisionMatched" : "bindingRevisionUnconfirmed",
      message:
        "expected \(expected.map(String.init) ?? "any"), observed "
        + "\(currentBindingRevision.map(String.init) ?? "none")",
      evidenceArtifactIDs: evidenceArtifactIDs, observedAt: nowUTC(),
      observedRevision: snapshot.version + 1)
    let readyState: HarnessTriState =
      bindingMatches
      ? (deviceReady ? .trueValue : .falseValue) : .unknown
    let ready = HarnessTaskCondition(
      name: .deviceReady, state: readyState,
      reasonCode: bindingMatches
        ? (deviceReady ? "deviceReady" : "deviceUnavailable")
        : "bindingRevisionUnconfirmed",
      message:
        "expected \(expected.map(String.init) ?? "any"), observed "
        + "\(currentBindingRevision.map(String.init) ?? "none")",
      evidenceArtifactIDs: evidenceArtifactIDs, observedAt: nowUTC(),
      observedRevision: snapshot.version + 1)
    let conditions = HarnessTaskConditionSet.replacing(
      snapshot.conditions, with: [target, bound, ready])

    let lifecycle: HarnessTaskLifecycle
    let waitReason: HarnessTaskWaitReason?
    if snapshot.lifecycle == .created {
      lifecycle = .created
      waitReason = nil
    } else if snapshot.waitReason == .userSuspended {
      lifecycle = .waiting
      waitReason = .userSuspended
    } else if snapshot.activeJobID != nil {
      lifecycle = .waiting
      waitReason = bindingMatches && deviceReady ? .activeJob : .deviceUnavailable
    } else if bindingMatches && deviceReady {
      lifecycle = .running
      waitReason = nil
    } else {
      lifecycle = .waiting
      waitReason = .deviceUnavailable
    }
    return try await commit(
      snapshot,
      transition(
        snapshot, causation: .conditionObserved,
        reasonCode: bindingMatches
          ? (deviceReady ? "deviceObservationReady" : "deviceObservationUnavailable")
          : "bindingRevisionUnconfirmed",
        status: lifecycle, activeJob: .unchanged, waitReason: waitReason,
        conditions: conditions))
  }

  public func pause(_ taskID: String) async throws -> HarnessTaskSnapshot {
    let snapshot = try await load(taskID)
    guard
      snapshot.status == .running || snapshot.status == .created
        || (snapshot.status == .waiting && snapshot.waitReason != .userSuspended)
    else {
      throw HarnessCoordinatorError.notPausable(snapshot.status)
    }
    // Pausing does not abandon an in-flight job: it stops the harness from
    // starting anything new. The active job stays owned by the engine and
    // is observed on resume.
    return try await commit(
      snapshot,
      transition(
        snapshot, causation: .pauseRequested, reasonCode: "operatorPause", status: .waiting,
        activeJob: .unchanged, waitReason: .userSuspended))
  }

  public func resume(_ taskID: String, resolution: String) async throws -> HarnessTaskSnapshot {
    let trimmed = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw HarnessCoordinatorError.emptyResolution }
    let snapshot = try await load(taskID)
    switch snapshot.status {
    case .waiting where snapshot.waitReason == .userSuspended:
      return try await commit(
        snapshot,
        transition(
          snapshot, causation: .resumeRequested, reasonCode: trimmed,
          status: snapshot.activeJobID == nil ? .running : .waiting,
          waitReason: snapshot.activeJobID == nil ? nil : .activeJob))
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
      try await reactivateHumanRequiredAttempt(snapshot.htaskID)
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
      try await closeAttempt(
        snapshot.htaskID, outcome: .cancelled, reason: "operatorCancel")
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
        status: .waiting, activeJob: .set(activeJobID), cancelRequested: true,
        waitReason: .activeJob))
    try? await jobPort.requestCancel(jobID: activeJobID)
    return marked
  }

  /// Daemon start: resolve dispatch intents whose outcome was lost, and
  /// nothing else. Recovery does not start new work - that needs an
  /// explicit reconcile, so a restart can never turn into a burst of
  /// unattended dispatches.
  /// Re-registers the isolated workspaces of tasks this process did not start.
  ///
  /// Their trees are on disk but their identities were registered by whichever
  /// process created them, so without this a restart leaves every
  /// `evolution-…` reference unresolvable. Covers every non-terminal task with
  /// a workspace, not only those with unresolved intents: a task parked
  /// waiting for a human has no intent outstanding and needs its workspace
  /// back just the same.
  ///
  /// Returns what it could not adopt instead of throwing, so one unadoptable
  /// workspace cannot stop the rest — and so a caller can say it at startup
  /// rather than let it surface as a stale decision several rounds later.
  @discardableResult
  public func adoptPersistedEvolutionWorkspaces() async throws
    -> [(htaskID: String, reason: String)]
  {
    guard let port = evolutionWorkspacePort else { return [] }
    var unadopted: [(htaskID: String, reason: String)] = []
    for snapshot in try await store.list() where !snapshot.status.isTerminal {
      guard let workspace = snapshot.evolutionWorkspace,
        let policy = snapshot.evolutionPolicy
      else { continue }
      do {
        try await port.adoptPersistedWorkspace(workspace, policy: policy)
      } catch {
        unadopted.append((htaskID: snapshot.htaskID, reason: "\(error)"))
      }
    }
    return unadopted
  }

  public func recoverTasks() async throws -> [HarnessTaskSnapshot] {
    // Before any intent is resolved: resolving one may dispatch a workspace
    // operation, and that needs the isolated identity already restored.
    try await adoptPersistedEvolutionWorkspaces()
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
    guard reconcilingTaskIDs.insert(taskID).inserted else {
      let snapshot = try await load(taskID)
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .reconcileInProgress,
        reasonCode: "reconcileInProgress")
    }
    defer { reconcilingTaskIDs.remove(taskID) }
    guard
      try await store.acquireReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
    else {
      let snapshot = try await load(taskID)
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .reconcileInProgress,
        reasonCode: "reconcileLeaseHeld")
    }
    do {
      let outcome = try await reconcileWithLease(taskID)
      try? await store.releaseReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
      return outcome
    } catch {
      try? await store.releaseReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
      throw error
    }
  }

  private func reconcileWithLease(_ taskID: String) async throws -> HarnessReconcileOutcome {
    var snapshot = try await load(taskID)

    if snapshot.status.isTerminal {
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .terminal, reasonCode: snapshot.status.rawValue)
    }
    if snapshot.status == .waiting, snapshot.waitReason == .userSuspended {
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
      var observation = try await jobPort.observe(jobID: activeJobID)
      // Runtime recovery is a mechanical proof path, not a new operation.
      // Automatically use it only when Runtime itself persisted an exact
      // hostOnly/readOnly effect. Unknown, mutation and destructive effects
      // retain the existing waiting/fail-closed behavior, and no original
      // intent is ever replayed through this port.
      let isUnattemptedRecovery =
        observation.state == JobState.waitingForRecovery.rawValue
        && !observation.timeline.contains(where: { $0.hasPrefix("reconcile started ") })
      let isInterruptedRecovery = observation.state == JobState.reconciling.rawValue
      if (isUnattemptedRecovery || isInterruptedRecovery),
        observation.outcomeUnknown,
        let actualEffect = observation.actualEffect,
        actualEffect <= .readOnly
      {
        observation = try await jobPort.reconcile(jobID: activeJobID)
      }
      guard observation.isTerminal else {
        let waiting = try await recordRuntimeWait(observation, snapshot: snapshot)
        return HarnessReconcileOutcome(
          snapshot: waiting, action: .waitedForActiveJob, reasonCode: observation.state)
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
    try await ensureInitialJourneyAttempt(snapshot)
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
    let proposal: PlannedProposal
    if let prepared = try await preparedPatchProposal(snapshot) {
      proposal = prepared
    } else {
      proposal = await plannedProposal(snapshot, handler: handler, basis: basis)
    }
    if let rejection = proposal.rejection,
      proposal.modelCallsSpent > 0,
      proposal.step.decision.kind == .requestHuman,
      proposal.step.decision.reasonCode == "patchProposalRequired"
    {
      // The deterministic step here means "a patch must be proposed"; it
      // does not mean one malformed response, timeout, or provider error has
      // proved that a human is required. The task already owns a bounded
      // model-call budget, so that budget - not an incidental response shape
      // - is the autonomous-debug boundary. Calls refused before transport
      // (privacy, identity screening, context ceiling) have
      // `modelCallsSpent == 0` and deliberately keep the existing human stop.
      return try await schedulePatchProposalRetry(
        snapshot, reasonCode: rejection, modelCallsSpent: proposal.modelCallsSpent)
    }
    let currentAttemptID = try await activeAttempt(snapshot.htaskID)?.attemptID
    let proposedDecision = proposal.step.decision
    let step = HarnessPlannedStep(
      decision: proposedDecision.stamped(
        with: basis,
        attemptID: currentAttemptID,
        expectedWorkspaceRevision: expectedWorkspaceRevision(
          for: proposedDecision, snapshot: snapshot),
        expectedDeployedArtifactDigest: expectedDeployedArtifactDigest(
          for: proposedDecision, snapshot: snapshot),
        expectedBindingRevision: expectedBindingRevision(
          for: proposedDecision, snapshot: snapshot)),
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
      try await closeAttempt(
        snapshot.htaskID, outcome: .humanRequired,
        reason: step.decision.reasonCode)
      // The other route into `humanRequired` — `recordBlock` — writes this
      // first and then transitions. This one used to transition and write
      // nothing, so a task stopped here left `task humanActions` empty: the
      // loop was waiting for a person, and the surface that tells a person
      // what is wanted had nothing in it. The hypothesis did reach
      // `result.summary`, but that is not where anyone is told to look.
      try await store.putHumanAction(
        HarnessHumanActionFactory.make(
          actionID: actionIDFactory(),
          snapshot: snapshot,
          block: .producerProposalRequired,
          reasonCode: step.decision.reasonCode,
          round: snapshot.activeRound,
          jobID: nil,
          requestID: step.decision.decisionID,
          evidenceRefs: snapshot.artifactRefs,
          nowUTC: nowUTC()))
      let blocked = try await commit(
        snapshot,
        transition(
          snapshot, causation: .humanBlocked, reasonCode: step.decision.reasonCode,
          status: .humanRequired, activeJob: .cleared,
          consumedBudget: charging(
            snapshot.consumedBudget, modelCalls: proposal.modelCallsSpent),
          result: HarnessTaskResult(
            outcome: .humanRequired, reasonCode: step.decision.reasonCode,
            summary: step.decision.hypothesis, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: blocked, action: .stoppedForHuman, reasonCode: step.decision.reasonCode)
    case .noSafeAction:
      try await closeAttempt(
        snapshot.htaskID, outcome: .failed,
        reason: step.decision.reasonCode)
      let stopped = try await commit(
        snapshot,
        transition(
          snapshot, causation: .noSafeAction, reasonCode: step.decision.reasonCode,
          status: .failed, activeJob: .cleared,
          consumedBudget: charging(
            snapshot.consumedBudget, modelCalls: proposal.modelCallsSpent),
          result: HarnessTaskResult(
            outcome: .failed, reasonCode: step.decision.reasonCode,
            summary: step.decision.hypothesis, artifactRefs: snapshot.artifactRefs)))
      return HarnessReconcileOutcome(
        snapshot: stopped, action: .stoppedNoSafeAction, reasonCode: step.decision.reasonCode)
    case .proposePatch:
      return try await dispatchPatch(
        step, snapshotAtPlanning: snapshot, handler: handler,
        modelCallsSpent: proposal.modelCallsSpent)
    case .invokeOperation:
      let outcome = try await dispatch(
        step, snapshotAtPlanning: snapshot, handler: handler,
        modelCallsSpent: proposal.modelCallsSpent)
      guard let rejection = proposal.rejection, outcome.action == .dispatched else {
        return outcome
      }
      return HarnessReconcileOutcome(
        snapshot: outcome.snapshot, action: outcome.action,
        dispatchedJobID: outcome.dispatchedJobID,
        reasonCode: "\(outcome.reasonCode)|\(rejection)")
    }
  }

  /// A model call is spent whatever came back, so every path out of a wake
  /// that made one has to charge it (CHG-2026-055, TASK-HFA-011). Folding it
  /// into the transition's budget keeps the single write path intact.
  func charging(
    _ budget: HarnessConsumedBudget, modelCalls: Int
  ) -> HarnessConsumedBudget {
    guard modelCalls > 0 else { return budget }
    return HarnessConsumedBudget(
      rounds: budget.rounds, wallClockSeconds: budget.wallClockSeconds,
      artifactBytes: budget.artifactBytes, e1Mutations: budget.e1Mutations,
      modelCalls: budget.modelCalls + modelCalls)
  }

  /// Keep a pre-dispatch Agent repair failure inside the task that already
  /// owns its policy and budgets. Callers use this only after proving no
  /// Runtime intent or external effect was created. Human-authored patches
  /// and pre-transport privacy refusals never reach this helper.
  private func schedulePatchProposalRetry(
    _ snapshot: HarnessTaskSnapshot,
    reasonCode: String,
    modelCallsSpent: Int
  ) async throws -> HarnessReconcileOutcome {
    precondition(modelCallsSpent > 0)
    let retrying = try await commit(
      snapshot,
      transition(
        snapshot, causation: .proposalRejected, reasonCode: reasonCode,
        status: .running,
        consumedBudget: charging(
          snapshot.consumedBudget, modelCalls: modelCallsSpent)))
    return HarnessReconcileOutcome(
      snapshot: retrying, action: .proposalRetryScheduled, reasonCode: reasonCode)
  }

  private func expectedWorkspaceRevision(
    for decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) -> String? {
    if let proposal = decision.patchProposal { return proposal.baseWorkspaceRevision }
    let workspaceOperations: Set<String> = [
      DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
      DebugCrashTaskHandler.buildOpenHarmony,
      DebugCrashTaskHandler.runTests, DebugCrashTaskHandler.revertPatch,
      DebugCrashTaskHandler.deployHAP,
    ]
    guard let operation = decision.operationReference, workspaceOperations.contains(operation)
    else { return nil }
    return snapshot.repairAttempt?.patchRevision
      ?? snapshot.repairAttempt?.proposal.baseWorkspaceRevision
  }

  private func expectedDeployedArtifactDigest(
    for decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) -> String? {
    guard decision.operationReference != DebugCrashTaskHandler.deployHAP else { return nil }
    return snapshot.repairAttempt?.deployedDigest
  }

  private func expectedBindingRevision(
    for decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) -> Int? {
    guard let operation = decision.operationReference,
      let descriptor = RuntimeOperationCatalog.descriptor(reference: operation),
      descriptor.binding != .none
    else { return nil }
    return snapshot.target.expectedBindingRevision
  }

  private func executionFacts(
    for decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) async -> HarnessDecisionExecutionFacts {
    let attemptID = try? await activeAttempt(snapshot.htaskID)?.attemptID
    // Every way this can fail to produce a number used to become `nil`, and a
    // `nil` was then read as "the workspace is at a different revision" — a
    // claim about a reading that never happened. Each branch now says which
    // one it is, and only a number that was actually read can contradict the
    // decision.
    var workspaceRevision: HarnessWorkspaceRevisionReading = .notRequired
    if decision.expectedWorkspaceRevision != nil {
      if repairPort == nil {
        workspaceRevision = .unmeasurable(reason: "repairPortUnavailable")
      } else if snapshot.executionProjectRef == nil {
        workspaceRevision = .unmeasurable(reason: "executionProjectRefUnavailable")
      } else if let repairPort, let projectRef = snapshot.executionProjectRef {
        let proposal = decision.patchProposal ?? snapshot.repairAttempt?.proposal
        if let proposal {
          do {
            workspaceRevision = .measured(
              try await repairPort.currentWorkspaceRevision(
                relativePaths: proposal.touchedFiles, projectRef: projectRef,
                task: snapshot))
          } catch {
            workspaceRevision = .unmeasurable(reason: "\(error)")
          }
        } else {
          workspaceRevision = .unmeasurable(reason: "noPatchProposalToMeasureAgainst")
        }
      }
    }
    let run: HarnessModelRun?
    if let modelRunID = decision.modelRunID {
      run = (try? await store.modelRuns(snapshot.htaskID))?.first {
        $0.modelRunID == modelRunID
      }
    } else {
      run = nil
    }
    return HarnessDecisionExecutionFacts(
      activeAttemptID: attemptID,
      workspaceRevision: workspaceRevision,
      deployedArtifactDigest: snapshot.repairAttempt?.deployedDigest,
      bindingRevision: snapshot.target.expectedBindingRevision,
      modelRunID: run?.modelRunID,
      modelContextDigest: run?.contextDigest,
      modelDecisionID: run?.outcome.decisionID)
  }

  private func decisionStaleness(
    _ decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler
  ) async -> HarnessDecisionStaleness? {
    if decision.kind == .invokeOperation, decision.attemptID == nil {
      return .attemptChanged(observed: nil, current: nil)
    }
    let basis = HarnessDecisionBasis(
      snapshot: snapshot, offeredOperations: offeredOperations(snapshot, handler: handler))
    let facts = await executionFacts(for: decision, snapshot: snapshot)
    return HarnessDecisionFreshness.staleness(
      of: decision, against: basis, executionFacts: facts)
  }

  /// Resume an already prepared patch route before asking any producer for a
  /// new decision. The current round owns checkpoint; the following round
  /// owns apply. Both records are durable before checkpoint can reach the
  /// runtime, so daemon recovery never republishes patch bytes or skips the
  /// checkpoint ActionRun.
  private func preparedPatchProposal(
    _ snapshot: HarnessTaskSnapshot
  ) async throws -> PlannedProposal? {
    let round = snapshot.activeRound + 1
    guard let current = try await store.decision(snapshot.htaskID, round: round),
      current.kind == .proposePatch, current.patchProposal != nil
    else { return nil }
    let preparedApply = try await store.decision(snapshot.htaskID, round: round + 1)
    // In the narrow crash window after the future apply write but before the
    // current proposal is replaced by checkpoint, `current` still carries
    // the superseded journey Attempt. The future decision owns the repair
    // Attempt and is validated against that live identity in `dispatchPatch`.
    let hasPreparedApply =
      preparedApply.map { candidate in
        candidate.kind == .proposePatch
          && candidate.operationReference == DebugCrashTaskHandler.applyPatch
          && candidate.patchProposal == current.patchProposal
          && (current.operationReference == nil
            || candidate.attemptID == current.attemptID)
          && !candidate.inputs.isEmpty
      } ?? false

    let resumesPreparedRoute: Bool
    switch snapshot.phase {
    case .analyzing:
      resumesPreparedRoute =
        snapshot.observed.latestVerdict == .fail
        && (hasPreparedApply
          || (current.operationReference == DebugCrashTaskHandler.applyPatch
            && !current.inputs.isEmpty))
    case .patching:
      resumesPreparedRoute =
        snapshot.repairAttempt?.checkpointJobID != nil
        && snapshot.repairAttempt?.patchAttemptRef == nil
        && current.operationReference == DebugCrashTaskHandler.applyPatch
        && current.patchProposal == snapshot.repairAttempt?.proposal
        && !current.inputs.isEmpty
    default:
      resumesPreparedRoute = false
    }
    guard resumesPreparedRoute else { return nil }
    return PlannedProposal(
      step: HarnessPlannedStep(decision: current, phaseOnDispatch: .patching),
      producer: current.producer, rejection: nil)
  }

  // MARK: - Dispatch and recovery

  func dispatchPatch(
    _ step: HarnessPlannedStep,
    snapshotAtPlanning: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler,
    modelCallsSpent: Int = 0
  ) async throws -> HarnessReconcileOutcome {
    let proposalDecision = step.decision
    let snapshot = try await load(snapshotAtPlanning.htaskID)
    if let staleness = await decisionStaleness(
      proposalDecision, snapshot: snapshot, handler: handler)
    {
      return try await recordStale(
        proposalDecision, staleness: staleness, snapshot: snapshot,
        modelCallsSpent: modelCallsSpent)
    }
    if proposalDecision.operationReference == DebugCrashTaskHandler.createCheckpoint {
      guard
        let preparedApply = try await store.decision(
          snapshot.htaskID, round: proposalDecision.round + 1),
        preparedApply.operationReference == DebugCrashTaskHandler.applyPatch,
        preparedApply.patchProposal == proposalDecision.patchProposal,
        preparedApply.attemptID == proposalDecision.attemptID,
        !preparedApply.inputs.isEmpty
      else {
        throw HarnessCoordinatorError.malformedRequest("preparedApplyDecisionUnavailable")
      }
      return try await dispatch(
        HarnessPlannedStep(decision: proposalDecision, phaseOnDispatch: .patching),
        snapshotAtPlanning: snapshot, handler: handler,
        modelCallsSpent: modelCallsSpent)
    }
    if proposalDecision.operationReference == DebugCrashTaskHandler.applyPatch,
      snapshot.repairAttempt?.checkpointJobID != nil,
      snapshot.repairAttempt?.proposal == proposalDecision.patchProposal
    {
      return try await dispatch(
        HarnessPlannedStep(decision: proposalDecision, phaseOnDispatch: .patching),
        snapshotAtPlanning: snapshot, handler: handler,
        modelCallsSpent: modelCallsSpent)
    }
    guard let proposal = proposalDecision.patchProposal,
      let projectRef = snapshot.executionProjectRef,
      let repairPort
    else {
      let reason = "patchProposalUnavailable"
      let blocked = try await recordBlock(
        snapshot, block: .environmentUnavailable, reasonCode: reason,
        round: proposalDecision.round, jobID: nil, requestID: nil,
        modelCallsSpent: modelCallsSpent)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
    }
    let futureRound = proposalDecision.round + 1
    let storedApply = try await store.decision(snapshot.htaskID, round: futureRound)
    let reusableApply = storedApply.flatMap { candidate -> HarnessDecision? in
      guard candidate.kind == .proposePatch,
        candidate.operationReference == DebugCrashTaskHandler.applyPatch,
        candidate.patchProposal == proposal, !candidate.inputs.isEmpty
      else { return nil }
      return candidate
    }
    let attempt: HarnessAttempt
    if let preparedAttemptID = reusableApply?.attemptID,
      let active = try await activeAttempt(snapshot.htaskID),
      active.attemptID == preparedAttemptID
    {
      attempt = active
    } else if proposalDecision.operationReference == DebugCrashTaskHandler.applyPatch,
      let decisionAttemptID = proposalDecision.attemptID,
      let active = try await activeAttempt(snapshot.htaskID),
      active.attemptID == decisionAttemptID
    {
      // Forward migration for a prepared apply Decision persisted before the
      // checkpoint leg existed. Keep its lease and strategy identity, but
      // interpose checkpoint before it can reach the runtime.
      attempt = active
    } else if reusableApply != nil {
      throw HarnessCoordinatorError.malformedRequest("preparedApplyAttemptMismatch")
    } else {
      do {
        attempt = try await beginStrategyAttempt(
          decision: proposalDecision, proposal: proposal, snapshot: snapshot)
      } catch let error as HarnessAttemptAdmissionError {
        if case .duplicateStrategy = error, modelCallsSpent > 0 {
          return try await schedulePatchProposalRetry(
            snapshot, reasonCode: error.reasonCode, modelCallsSpent: modelCallsSpent)
        }
        let blocked = try await recordBlock(
          snapshot, block: .strategyExhausted, reasonCode: error.reasonCode,
          round: proposalDecision.round, jobID: nil,
          requestID: proposalDecision.decisionID, modelCallsSpent: modelCallsSpent)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: error.reasonCode)
      }
    }
    let preparedInputs: [String: JSONValue]
    var newlyPreparedPatch: HarnessPreparedPatch?
    if let reusableApply {
      preparedInputs = reusableApply.inputs
    } else if proposalDecision.operationReference == DebugCrashTaskHandler.applyPatch,
      !proposalDecision.inputs.isEmpty
    {
      preparedInputs = proposalDecision.inputs
    } else {
      do {
        let prepared = try await repairPort.preparePatch(
          proposal, projectRef: projectRef, task: snapshot,
          decisionID: proposalDecision.decisionID)
        preparedInputs = prepared.inputs
        newlyPreparedPatch = prepared
      } catch let error as HarnessRepairPortError {
        if modelCallsSpent > 0 {
          try await closeAttempt(
            snapshot.htaskID, outcome: .failed, reason: error.reasonCode)
          return try await schedulePatchProposalRetry(
            snapshot, reasonCode: error.reasonCode, modelCallsSpent: modelCallsSpent)
        }
        let print = fingerprint(
          snapshot, operationReference: DebugCrashTaskHandler.applyPatch,
          inputsDigest: proposal.patchSHA256,
          errorClassification: error.reasonCode == "WORKSPACE_REVISION_CONFLICT"
            ? "WORKSPACE_REVISION_CONFLICT" : "patchProposalRejected",
          semanticErrorCode: error.reasonCode)
        let record = try await recordFailure(
          snapshot, fingerprint: print, reasonCode: error.reasonCode,
          jobID: nil, requestID: nil)
        try await recordAttemptFailure(
          taskID: snapshot.htaskID, fingerprint: record.fingerprint,
          outcome: .failed)
        let blocked = try await recordBlock(
          snapshot, block: .environmentUnavailable, reasonCode: error.reasonCode,
          round: proposalDecision.round, jobID: nil, requestID: nil)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: error.reasonCode)
      }
    }

    if snapshot.requiresWorkspaceIsolation, attempt.candidatePatch == nil {
      guard let evolutionPolicy = snapshot.evolutionPolicy,
        case .string(let artifactLease)? = preparedInputs["patchArtifactRef"]
      else {
        let reason = "candidatePatchArtifactUnavailable"
        let blocked = try await recordBlock(
          snapshot, block: .environmentUnavailable, reasonCode: reason,
          round: proposalDecision.round, jobID: nil,
          requestID: proposalDecision.decisionID, modelCallsSpent: modelCallsSpent)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
      }
      let leaseParts = artifactLease.split(separator: ":", omittingEmptySubsequences: false)
      let prepared =
        newlyPreparedPatch
        ?? HarnessPreparedPatch(
          inputs: preparedInputs, artifactLease: artifactLease,
          artifactID: leaseParts.count == 3 ? String(leaseParts[2]) : nil)
      do {
        let creator: HarnessCandidatePatchCreator =
          proposalDecision.producer == Self.humanPatchProducer ? .human : .agent
        let candidate = try await repairPort.candidatePatch(
          proposal: proposal, prepared: prepared, task: snapshot,
          attemptID: attempt.attemptID, createdBy: creator,
          createdAtUTC: nowUTC())
        try evolutionPolicy.validate(candidate: candidate)
        try await recordAttemptCandidatePatch(candidate, taskID: snapshot.htaskID)
      } catch {
        let reason = "candidatePatchRejected:\(error)"
        if modelCallsSpent > 0 {
          try await closeAttempt(
            snapshot.htaskID, outcome: .failed, reason: reason)
          return try await schedulePatchProposalRetry(
            snapshot, reasonCode: reason, modelCallsSpent: modelCallsSpent)
        }
        let blocked = try await recordBlock(
          snapshot, block: .strategyExhausted, reasonCode: reason,
          round: proposalDecision.round, jobID: nil,
          requestID: proposalDecision.decisionID)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
      }
    }

    // Persist apply in the following product round before checkpoint can be
    // dispatched. A crash after this write can recover the immutable lease;
    // a crash after checkpoint submission recovers its original intent/key.
    let preparedApply =
      reusableApply
      ?? HarnessDecision(
        decisionID: decisionIDFactory(),
        htaskID: proposalDecision.htaskID,
        round: futureRound,
        kind: .proposePatch,
        operationReference: DebugCrashTaskHandler.applyPatch,
        inputs: preparedInputs,
        patchProposal: proposal,
        requiredArtifacts: proposalDecision.requiredArtifacts,
        expectedObservation: proposalDecision.expectedObservation,
        hypothesis: proposalDecision.hypothesis,
        reasonCode: proposalDecision.reasonCode,
        producer: proposalDecision.producer,
        createdAtUTC: proposalDecision.createdAtUTC,
        attemptID: attempt.attemptID,
        expectedWorkspaceRevision: proposal.baseWorkspaceRevision,
        expectedDeployedArtifactDigest: proposalDecision.expectedDeployedArtifactDigest,
        expectedBindingRevision: proposalDecision.expectedBindingRevision)
    try await store.putDecision(preparedApply)

    let checkpoint = HarnessDecision(
      decisionID: proposalDecision.decisionID,
      htaskID: proposalDecision.htaskID,
      round: proposalDecision.round,
      kind: .proposePatch,
      operationReference: DebugCrashTaskHandler.createCheckpoint,
      inputs: [
        "projectRef": .string(projectRef),
        "expectedWorkspaceRevision": .string(proposal.baseWorkspaceRevision),
        // Non-Git production workspaces seal exactly the files named by the
        // already-validated patch proposal. Git profiles may ignore this
        // additive field while preserving the same decision identity.
        "checkpointFilePaths": .array(proposal.touchedFiles.map(JSONValue.string)),
      ],
      patchProposal: proposal,
      requiredArtifacts: proposalDecision.requiredArtifacts,
      expectedObservation: proposalDecision.expectedObservation,
      hypothesis: proposalDecision.hypothesis,
      reasonCode: proposalDecision.reasonCode,
      producer: proposalDecision.producer,
      createdAtUTC: proposalDecision.createdAtUTC,
      observedStateVersion: proposalDecision.observedStateVersion,
      basisDigest: proposalDecision.basisDigest,
      attemptID: attempt.attemptID,
      modelRunID: proposalDecision.modelRunID,
      contextDigest: proposalDecision.contextDigest,
      expectedWorkspaceRevision: proposal.baseWorkspaceRevision,
      expectedDeployedArtifactDigest: proposalDecision.expectedDeployedArtifactDigest,
      expectedBindingRevision: proposalDecision.expectedBindingRevision)
    try await store.putDecision(checkpoint)
    return try await dispatch(
      HarnessPlannedStep(decision: checkpoint, phaseOnDispatch: .patching),
      snapshotAtPlanning: snapshot, handler: handler, modelCallsSpent: modelCallsSpent)
  }

  func dispatch(
    _ step: HarnessPlannedStep,
    snapshotAtPlanning: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler,
    modelCallsSpent: Int = 0
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
    if let staleness = await decisionStaleness(
      decision, snapshot: snapshot, handler: handler)
    {
      return try await recordStale(
        decision, staleness: staleness, snapshot: snapshot, modelCallsSpent: modelCallsSpent)
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
      attemptID: decision.attemptID,
      modelRunID: decision.modelRunID,
      operationReference: operationReference,
      targetID: snapshot.target.targetID,
      expectedBindingRevision: decision.expectedBindingRevision,
      expectedWorkspaceRevision: decision.expectedWorkspaceRevision,
      expectedDeployedArtifactDigest: decision.expectedDeployedArtifactDigest,
      inputsDigestSHA256: digest,
      requestID: identity.requestID,
      idempotencyKey: identity.idempotencyKey,
      state: .pending,
      jobID: nil,
      createdAtUTC: now,
      updatedAtUTC: now)
    // The pending intent is written before the Attempt link. If the process
    // dies between them, recovery has the complete typed operation and the
    // original key needed to append the missing link without guessing.
    try await store.putIntent(intent)
    do {
      try await recordAttemptActionRun(
        snapshot: snapshot, operationReference: operationReference,
        inputsDigest: digest, actionRunID: identity.requestID)
    } catch let error as HarnessAttemptAdmissionError {
      // Harness admission happened before any engine submission. Close the
      // intent so recovery cannot later turn this refusal into an effect.
      try await store.putIntent(intent.withState(.rejected, atUTC: nowUTC()))
      switch error {
      case .duplicateStrategy, .strategyAttemptBudgetExhausted:
        let blocked = try await recordBlock(
          snapshot, block: .strategyExhausted, reasonCode: error.reasonCode,
          round: decision.round, jobID: nil, requestID: decision.decisionID)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: error.reasonCode)
      case .actionRetryBudgetExhausted:
        try await closeAttempt(
          snapshot.htaskID, outcome: .failed, reason: error.reasonCode)
        return try await stop(
          snapshot, refusal: .budgetExhausted(.actionRetriesPerRun),
          round: decision.round, requestID: decision.decisionID, jobID: nil,
          decisionID: decision.decisionID)
      }
    }
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
          status: .waiting, phase: step.phaseOnDispatch ?? snapshot.phase,
          activeRound: decision.round, activeJob: .set(accepted.jobID),
          consumedBudget: charging(
            HarnessConsumedBudget(
              rounds: max(snapshot.consumedBudget.rounds, decision.round),
              wallClockSeconds: snapshot.consumedBudget.wallClockSeconds,
              artifactBytes: snapshot.consumedBudget.artifactBytes,
              e1Mutations: snapshot.consumedBudget.e1Mutations
                + (Self.consumesHarnessE1Budget(
                  operationReference, inputs: decision.inputs) ? 1 : 0),
              modelCalls: snapshot.consumedBudget.modelCalls),
            modelCalls: modelCallsSpent),
          jobID: accepted.jobID, waitReason: .activeJob,
          conditions: conditionsAfterDispatch(
            operationReference, snapshot: snapshot)))
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
    snapshot: HarnessTaskSnapshot,
    modelCallsSpent: Int = 0
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
        status: .running,
        consumedBudget: charging(
          snapshot.consumedBudget, modelCalls: modelCallsSpent)))
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
        try await jobPort.submit(requestJSON: try await requestBytes(intent, decision, snapshot)))
    } catch HarnessJobPortError.rejected(let message) {
      // Admission refused. Zero side effect, and an identical retry would be
      // refused identically - so the intent is closed as `rejected`, the
      // failure is fingerprinted so a later task inherits the knowledge, and
      // the task stops for a human instead of spinning.
      try await store.putIntent(intent.withState(.rejected, atUTC: nowUTC()))
      let semanticCode = Self.semanticCode(from: message)
      let print = fingerprint(
        snapshot, operationReference: intent.operationReference,
        inputsDigest: intent.inputsDigestSHA256, errorClassification: "admissionRejected",
        semanticErrorCode: semanticCode)
      let record = try await recordFailure(
        snapshot, fingerprint: print, reasonCode: "submissionRejected", jobID: nil,
        requestID: intent.requestID)
      try await recordAttemptFailure(
        taskID: snapshot.htaskID, fingerprint: record.fingerprint,
        outcome: .humanRequired)
      // Authorization is not an unavailable environment. It maps exactly to
      // the closed impact-approval HumanActionRequired category, and the
      // operation reference is the minimum durable context a maintainer needs
      // to prepare the matching typed grant. Keep other admission failures on
      // the existing environment-unavailable path.
      //
      // Family membership, not equality with the generic code: a revoked or
      // exhausted grant is still an authorization block, and testing for the
      // one code would route every specific denial to the wrong category the
      // moment the runtime learned to name it.
      let isAuthorization = semanticCode.hasPrefix("authorization")
      let block: HarnessHumanBlock =
        isAuthorization ? .authorizationApproval : .environmentUnavailable
      let blockReason =
        isAuthorization
        ? "submissionRejected:\(semanticCode):\(intent.operationReference)"
        : "submissionRejected:\(semanticCode)"
      let blocked = try await recordBlock(
        snapshot, block: block,
        reasonCode: blockReason,
        round: intent.round, jobID: nil, requestID: intent.requestID)
      return .rejected(
        HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: isAuthorization ? blockReason : "submissionRejected"))
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
    let v2AssociationsMatch =
      decision.envelopeVersion == HarnessDecision.envelopeVersion
      && intent.schemaVersion == HarnessDispatchIntent.schemaVersion
      && decision.attemptID == intent.attemptID
      && decision.modelRunID == intent.modelRunID
      && decision.expectedBindingRevision == intent.expectedBindingRevision
      && decision.expectedWorkspaceRevision == intent.expectedWorkspaceRevision
      && decision.expectedDeployedArtifactDigest == intent.expectedDeployedArtifactDigest
    guard decision.decisionID == intent.decisionID,
      decision.htaskID == intent.htaskID,
      decision.round == intent.round,
      decision.operationReference == intent.operationReference,
      HarnessRequestIdentity.inputsDigest(decision.inputs) == intent.inputsDigestSHA256,
      v2AssociationsMatch
    else {
      throw HarnessTaskStoreError.corrupt(
        "intent \(intent.requestID) no longer matches decision \(intent.decisionID)")
    }
    if intent.state == .pending {
      guard let handler = handlers[snapshot.type] else {
        throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
      }
      if let staleness = await decisionStaleness(
        decision, snapshot: snapshot, handler: handler)
      {
        // Pending proves the request never crossed the engine boundary. Close
        // it durably, record a stale wake, and replan on the next reconcile.
        try await store.putIntent(intent.withState(.stale, atUTC: nowUTC()))
        // The v2 Intent carries the exact model association. Counting every
        // run in the round would double-charge an earlier stale replan that
        // reused the same product round.
        let modelCallsSpent = intent.modelRunID == nil ? 0 : 1
        return try await recordStale(
          decision, staleness: staleness, snapshot: snapshot,
          modelCallsSpent: modelCallsSpent)
      }
    }
    // A pending intent may be the crash window between intent persistence
    // and Attempt association. Replaying this append is idempotent and keeps
    // the original ActionRun/key; it is not a confirmed retry.
    if intent.state == .pending {
      do {
        try await recordAttemptActionRun(
          snapshot: snapshot, operationReference: intent.operationReference,
          inputsDigest: intent.inputsDigestSHA256, actionRunID: intent.requestID)
      } catch let error as HarnessAttemptAdmissionError {
        try await store.putIntent(intent.withState(.rejected, atUTC: nowUTC()))
        switch error {
        case .duplicateStrategy, .strategyAttemptBudgetExhausted:
          let blocked = try await recordBlock(
            snapshot, block: .strategyExhausted, reasonCode: error.reasonCode,
            round: intent.round, jobID: nil, requestID: intent.requestID)
          return HarnessReconcileOutcome(
            snapshot: blocked.snapshot, action: .stoppedForHuman,
            reasonCode: error.reasonCode)
        case .actionRetryBudgetExhausted:
          try await closeAttempt(
            snapshot.htaskID, outcome: .failed, reason: error.reasonCode)
          return try await stop(
            snapshot, refusal: .budgetExhausted(.actionRetriesPerRun),
            round: intent.round, requestID: intent.requestID, jobID: nil,
            decisionID: intent.decisionID)
        }
      }
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
          status: .waiting, activeRound: max(snapshot.activeRound, intent.round),
          activeJob: .set(accepted.jobID),
          consumedBudget: HarnessConsumedBudget(
            rounds: max(snapshot.consumedBudget.rounds, intent.round),
            wallClockSeconds: snapshot.consumedBudget.wallClockSeconds,
            artifactBytes: snapshot.consumedBudget.artifactBytes,
            e1Mutations: snapshot.consumedBudget.e1Mutations
              + (Self.consumesHarnessE1Budget(
                intent.operationReference, inputs: decision.inputs) ? 1 : 0),
            modelCalls: snapshot.consumedBudget.modelCalls),
          jobID: accepted.jobID, waitReason: .activeJob,
          conditions: conditionsAfterDispatch(
            intent.operationReference, snapshot: snapshot)))
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
      if operationReference == DebugCrashTaskHandler.applyPatch,
        let decision = try await store.decision(snapshot.htaskID, round: snapshot.activeRound),
        let proposal = decision.patchProposal,
        let repairPort
      {
        let readback = try await repairPort.reconcileUnknownPatch(
          jobID: observation.jobID, proposal: proposal)
        if case .patchApplied = readback {
          let confirmed = HarnessJobObservation(
            jobID: observation.jobID, state: "PATCH_APPLIED", isTerminal: true,
            succeeded: true, outcomeUnknown: false, waitingForHuman: false,
            timeline: observation.timeline + ["patch readback -> PATCH_APPLIED"])
          return try await applyRepairSuccess(
            confirmed, operationReference: operationReference,
            decision: decision, snapshot: snapshot)
        }
        let classification: String
        switch readback {
        case .patchApplied: classification = "PATCH_APPLIED"
        case .patchNotApplied: classification = "PATCH_NOT_APPLIED"
        case .stillUnknown: classification = "STILL_UNKNOWN"
        case .partiallyApplied: classification = "PARTIALLY_APPLIED"
        }
        // Every non-completed four-state result is a human stop. In
        // particular PATCH_NOT_APPLIED is not permission to send the same
        // mutation again: an unknown execution outcome owns this round.
        let reason = "patchOutcomeReadback:\(classification)"
        try await closeAttempt(
          snapshot.htaskID, outcome: .humanRequired, reason: reason)
        let blocked = try await recordBlock(
          snapshot, block: .outcomeUnknown, reasonCode: reason,
          round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
      }
      // The one rule that has no exception: an unknown outcome stops the task
      // and never re-sends the side effect (HTP-INV-5). It is also the case
      // the closed human-action vocabulary describes exactly, so a typed
      // HumanActionRequired is produced with it.
      let reason = "outcomeUnknown:\(operationReference)"
      try await closeAttempt(
        snapshot.htaskID, outcome: .humanRequired, reason: reason)
      let blocked = try await recordBlock(
        snapshot, block: .outcomeUnknown, reasonCode: reason, round: snapshot.activeRound,
        jobID: observation.jobID, requestID: nil)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
    }

    if snapshot.cancelRequested {
      try await closeAttempt(
        snapshot.htaskID, outcome: .cancelled,
        reason: "cancelCompletedAfterActiveJob")
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
      let deploymentPreflightNotExecuted =
        operationReference == DebugCrashTaskHandler.deployHAP
        && Self.isConfirmedDeploymentPreflightNonExecution(observation)
      let failureClassification: String
      switch operationReference {
      case DebugCrashTaskHandler.buildOpenHarmony:
        failureClassification = "BUILD_SEMANTIC_FAILURE"
      case DebugCrashTaskHandler.runTests:
        failureClassification = "TEST_FAILURE"
      case DebugCrashTaskHandler.deployHAP where deploymentPreflightNotExecuted:
        failureClassification = Self.deploymentPreflightNotExecutedClassification
      default:
        failureClassification = "operationFailed"
      }
      let digest =
        (try? await store.intent(snapshot.htaskID, round: snapshot.activeRound))?
        .inputsDigestSHA256 ?? HarnessRequestIdentity.inputsDigest([:])
      let print = fingerprint(
        snapshot, operationReference: operationReference, inputsDigest: digest,
        errorClassification: failureClassification, semanticErrorCode: observation.state)
      let record = try await recordFailure(
        snapshot, fingerprint: print, reasonCode: reason, jobID: observation.jobID)
      let attemptOutcome: HarnessAttemptOutcome
      if operationReference == DebugCrashTaskHandler.deployHAP,
        snapshot.repairAttempt != nil
      {
        // The same Attempt remains open until its required rollback is read
        // back; closing it now would orphan that ActionRun.
        attemptOutcome = .active
      } else if operationReference == DebugCrashTaskHandler.createCheckpoint
        || operationReference == DebugCrashTaskHandler.applyPatch
        || operationReference == DebugCrashTaskHandler.revertPatch
      {
        attemptOutcome = .humanRequired
      } else if record.fingerprint.retryDisposition == .actionRetryAllowed,
        Self.isActionRetrySafe(operationReference),
        try await activeAttemptSupportsActionRetry(snapshot.htaskID)
      {
        attemptOutcome = .active
      } else {
        attemptOutcome = .failed
      }
      try await recordAttemptFailure(
        taskID: snapshot.htaskID, fingerprint: record.fingerprint,
        outcome: attemptOutcome)
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
      if operationReference == DebugCrashTaskHandler.buildOpenHarmony
        || operationReference == DebugCrashTaskHandler.runTests
      {
        let classification =
          operationReference == DebugCrashTaskHandler.buildOpenHarmony
          ? "BUILD_SEMANTIC_FAILURE" : "TEST_FAILURE"
        let alternative = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved,
            reasonCode: "\(classification):ALTERNATIVE_REQUIRED",
            status: .running, phase: .analyzing, activeJob: .cleared,
            jobID: observation.jobID))
        return HarnessReconcileOutcome(
          snapshot: alternative, action: .observedJob,
          reasonCode: "\(classification):ALTERNATIVE_REQUIRED")
      }
      if operationReference == DebugCrashTaskHandler.deployHAP,
        deploymentPreflightNotExecuted,
        let repair = snapshot.repairAttempt
      {
        var observed = snapshot.observedState
        observed[HarnessRepairAttempt.observedStateKey] =
          repair.updating(rollbackRequired: false).json
        observed[DebugCrashTaskHandler.deploymentPreflightRetryKey] = .bool(true)
        let reason =
          "\(Self.deploymentPreflightNotExecutedClassification):ACTION_RETRY_ALLOWED"
        let retryable = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved, reasonCode: reason,
            status: .running, activeJob: .cleared,
            jobID: observation.jobID, observedState: observed))
        return HarnessReconcileOutcome(
          snapshot: retryable, action: .observedJob, reasonCode: reason)
      }
      if operationReference == DebugCrashTaskHandler.deployHAP,
        let repair = snapshot.repairAttempt
      {
        var observed = snapshot.observedState
        observed[HarnessRepairAttempt.observedStateKey] =
          repair.updating(
            rollbackRequired: true
          ).json
        let rollbackPending = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved,
            reasonCode: "deploymentFailed:rollbackRequired",
            status: .running, activeJob: .cleared, jobID: observation.jobID,
            observedState: observed))
        return HarnessReconcileOutcome(
          snapshot: rollbackPending, action: .observedJob,
          reasonCode: "deploymentFailed:rollbackRequired")
      }
      if operationReference == DebugCrashTaskHandler.createCheckpoint
        || operationReference == DebugCrashTaskHandler.applyPatch
        || operationReference == DebugCrashTaskHandler.revertPatch
      {
        let blocked = try await recordBlock(
          snapshot, block: .outcomeUnknown,
          reasonCode: "mutationFailedNoAutomaticReplay:\(operationReference)",
          round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman,
          reasonCode: blocked.action.reasonCode)
      }
      if record.fingerprint.retryDisposition == .actionRetryAllowed,
        Self.isActionRetrySafe(operationReference),
        try await activeAttemptSupportsActionRetry(snapshot.htaskID)
      {
        let retryable = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved,
            reasonCode: "TRANSIENT:ACTION_RETRY_ALLOWED",
            status: .running, activeJob: .cleared, jobID: observation.jobID))
        return HarnessReconcileOutcome(
          snapshot: retryable, action: .observedJob,
          reasonCode: "TRANSIENT:ACTION_RETRY_ALLOWED")
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
    if operationReference == DebugCrashTaskHandler.deployHAP,
      snapshot.repairAttempt == nil
    {
      // The first deployment is the declared crash fixture, not a repair
      // output. The runtime operation already enforced the immutable lease,
      // target binding and install/process readbacks. Keep the task in
      // `reproducing` and let the next capture judge only ledger entries newer
      // than the baseline; routing this through `applyRepairSuccess` would
      // falsely require a build digest that cannot exist before a patch.
      try await appendTaskMemory(
        snapshot, kind: .observation,
        summary: "baseline crash fixture deployed with typed runtime readback",
        confidence: .observed,
        evidence: HarnessMemoryEvidence(jobIDs: [observation.jobID]))
      var observed = snapshot.observedState
      observed[DebugCrashTaskHandler.baselineDeploymentMarker] = .bool(true)
      let advanced = try await commit(
        snapshot,
        transition(
          snapshot, causation: .jobObserved,
          reasonCode: "baselineCrashFixtureDeployed",
          status: .running, phase: .reproducing, activeJob: .cleared,
          jobID: observation.jobID, observedState: observed,
          conditions: conditionsAfterSuccess(
            operationReference, snapshot: snapshot)))
      return HarnessReconcileOutcome(
        snapshot: advanced, action: .observedJob, reasonCode: observation.state)
    }
    if [
      DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
      DebugCrashTaskHandler.buildOpenHarmony,
      DebugCrashTaskHandler.signOpenHarmonyHAP, DebugCrashTaskHandler.runTests,
      DebugCrashTaskHandler.deployHAP,
      DebugCrashTaskHandler.revertPatch,
    ].contains(operationReference),
      let decision = try await store.decision(snapshot.htaskID, round: snapshot.activeRound)
    {
      return try await applyRepairSuccess(
        observation, operationReference: operationReference,
        decision: decision, snapshot: snapshot)
    }
    if operationReference == DebugCrashTaskHandler.captureDiagnostics,
      let artifactPort
    {
      // A raw Faultlogger listing is a source Artifact, not an evaluator
      // input. Persist its ID-only lease and let the next deterministic step
      // run the pinned analyzer. If the optional capture product is absent,
      // evaluate the collection blocker normally so another bounded capture
      // may supply it; a published Artifact whose lease cannot be minted is
      // an integrity stop, not permission to parse it in-process.
      let inventory = (try? await artifactPort.inventory(jobID: observation.jobID)) ?? []
      if let source = inventory.first(where: {
        $0.name == HarnessObservationBuilder.crashIndexArtifact && $0.published
      }) {
        let lease: String?
        do {
          lease = try await artifactPort.leaseReference(
            jobID: observation.jobID, artifactID: source.artifactID)
        } catch HarnessArtifactPortError.unavailable(let reason)
          where reason == "artifact leases are unavailable in this composition"
        {
          // Forward-readable test/legacy compositions predate analyzer
          // leases. Production RuntimeArtifactStoreHarnessPort always
          // implements this method and never reaches this fallback.
          lease = nil
        } catch HarnessArtifactPortError.unavailable(let reason)
          where reason == "sensitive analyzer source is not opted in: \(source.name)"
        {
          // Preserve the privacy gate as an actionable, closed reason without
          // exposing artifact bytes or an implementation error. The artifact
          // name is already part of the published inventory; naming it tells
          // the operator which exact opt-in is missing while the task remains
          // fail-closed with zero analyzer dispatch.
          let reasonCode = "artifactSensitiveNotOptedIn:\(source.name)"
          let blocked = try await recordBlock(
            snapshot, block: .evidenceIntegrity, reasonCode: reasonCode,
            round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
          return HarnessReconcileOutcome(
            snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reasonCode)
        } catch {
          let reason = "analyzerSourceLeaseUnavailable"
          let blocked = try await recordBlock(
            snapshot, block: .evidenceIntegrity, reasonCode: reason,
            round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
          return HarnessReconcileOutcome(
            snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
        }
        if let lease {
          var observed = snapshot.observedState
          observed[DebugCrashTaskHandler.pendingAnalysisSourceJobKey] =
            .string(observation.jobID)
          observed[DebugCrashTaskHandler.pendingAnalysisSourceArtifactKey] =
            .string(source.artifactID)
          observed[DebugCrashTaskHandler.pendingAnalysisSourceLeaseKey] = .string(lease)
          observed[DebugCrashTaskHandler.pendingAnalysisReturnPhaseKey] =
            .string(Self.analysisReturnPhase(after: snapshot).rawValue)
          try await appendTaskMemory(
            snapshot, kind: .observation,
            summary: "captured crash ledger queued for deterministic analyzer",
            confidence: .observed,
            evidence: HarnessMemoryEvidence(
              jobIDs: [observation.jobID], artifactIDs: [source.artifactID]))
          let staged = try await commit(
            snapshot,
            transition(
              snapshot, causation: .jobObserved,
              reasonCode: "crashLedgerAwaitingDerivedAnalysis",
              status: .running,
              phase: handler.phase(
                afterSuccessOf: operationReference, in: snapshot.phase),
              activeJob: .cleared,
              jobID: observation.jobID, observedState: observed,
              conditions: conditionsAfterSuccess(
                operationReference, snapshot: snapshot,
                evidenceArtifactIDs: [source.artifactID])))
          return HarnessReconcileOutcome(
            snapshot: staged, action: .observedJob, reasonCode: observation.state)
        }
      }
    }
    let sourceEvidenceJobID: String?
    let sourceArtifactID: String?
    let analysisReturnPhase: HarnessTaskPhase?
    if operationReference == DebugCrashTaskHandler.analyzeCrashLedger {
      if case .string(let job)? = snapshot.observedState[
        DebugCrashTaskHandler.pendingAnalysisSourceJobKey],
        case .string(let artifact)? = snapshot.observedState[
          DebugCrashTaskHandler.pendingAnalysisSourceArtifactKey],
        case .string(let rawPhase)? = snapshot.observedState[
          DebugCrashTaskHandler.pendingAnalysisReturnPhaseKey],
        let returnPhase = HarnessTaskPhase(rawValue: rawPhase),
        [.collecting, .analyzing, .verifying].contains(returnPhase)
      {
        sourceEvidenceJobID = job
        sourceArtifactID = artifact
        analysisReturnPhase = returnPhase
      } else {
        let reason = "analyzerSourceObservationUnavailable"
        let blocked = try await recordBlock(
          snapshot, block: .evidenceIntegrity, reasonCode: reason,
          round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
        return HarnessReconcileOutcome(
          snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
      }
    } else {
      sourceEvidenceJobID = nil
      sourceArtifactID = nil
      analysisReturnPhase = nil
    }
    let nextPhase =
      analysisReturnPhase
      ?? handler.phase(afterSuccessOf: operationReference, in: snapshot.phase)
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
        status: .running, phase: nextPhase, activeJob: .cleared, jobID: observation.jobID,
        conditions: conditionsAfterSuccess(
          operationReference, snapshot: snapshot,
          evidenceArtifactIDs: sourceArtifactID.map { [$0] } ?? [])))
    // Evidence exists now, so it gets judged now: the evaluator is the only
    // component that may end this task successfully, and it runs on the bytes
    // the job just published rather than on the decision that asked for them.
    switch try await evaluate(
      advanced, jobID: observation.jobID,
      sourceEvidenceJobID: sourceEvidenceJobID,
      expectedSourceArtifactID: sourceArtifactID
    ) {
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

  /// Recognises only the protected Runtime's durable proof that the exact
  /// read-only target-confirmation step did not execute. Absence of a success
  /// marker is not proof: any capability consumption or install intent keeps
  /// the ordinary rollback/fail-closed path in force.
  static func isConfirmedDeploymentPreflightNonExecution(
    _ observation: HarnessJobObservation
  ) -> Bool {
    guard observation.isTerminal, !observation.succeeded,
      !observation.outcomeUnknown, !observation.waitingForHuman,
      observation.timeline.contains(
        "reconciled: confirmed not executed confirm-evidence-target")
    else { return false }
    return !observation.timeline.contains("capability consumed before first mutation")
      && !observation.timeline.contains { event in
        event == "intent install-hap" || event.hasPrefix("verified install-hap")
      }
  }

  private func applyRepairSuccess(
    _ observation: HarnessJobObservation,
    operationReference: String,
    decision: HarnessDecision,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessReconcileOutcome {
    guard let repairPort else {
      let reason = "repairReadbackUnavailable"
      let blocked = try await recordBlock(
        snapshot, block: .environmentUnavailable, reasonCode: reason,
        round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman, reasonCode: reason)
    }

    var nextAttempt = snapshot.repairAttempt
    var nextPhase = snapshot.phase
    do {
      switch operationReference {
      case DebugCrashTaskHandler.createCheckpoint:
        guard let proposal = decision.patchProposal,
          let preparedApply = try await store.decision(
            snapshot.htaskID, round: decision.round + 1),
          preparedApply.operationReference == DebugCrashTaskHandler.applyPatch,
          preparedApply.patchProposal == proposal,
          preparedApply.attemptID == decision.attemptID,
          !preparedApply.inputs.isEmpty
        else {
          throw HarnessRepairPortError.malformedReadback("preparedApplyDecision")
        }
        nextAttempt = HarnessRepairAttempt(
          proposal: proposal, checkpointJobID: observation.jobID,
          // Reverting a source patch does not change the device. Preserve the
          // last deployment observation across candidate replacement so the
          // apply Decision is checked against the fact it was planned on;
          // the next verified deploy readback replaces this value.
          deployedDigest: snapshot.repairAttempt?.deployedDigest)
        nextPhase = .patching

      case DebugCrashTaskHandler.applyPatch:
        guard let proposal = decision.patchProposal,
          let current = snapshot.repairAttempt,
          current.checkpointJobID != nil, current.proposal == proposal
        else {
          throw HarnessRepairPortError.malformedReadback("checkpointAttempt")
        }
        let readback = try await repairPort.appliedPatchReadback(
          jobID: observation.jobID, proposal: proposal)
        nextAttempt = current.updating(
          patchAttemptRef: readback.patchAttemptRef,
          patchRevision: readback.patchRevision)
        try await recordAttemptPatchRevision(
          readback.patchRevision, taskID: snapshot.htaskID)
        nextPhase = .building

      case DebugCrashTaskHandler.buildOpenHarmony:
        guard let current = snapshot.repairAttempt,
          case .string(let preset)? = decision.inputs["buildPresetRef"]
        else {
          throw HarnessRepairPortError.malformedReadback("buildAttempt")
        }
        let readback = try await repairPort.buildReadback(
          jobID: observation.jobID, attempt: current,
          buildPresetRef: preset, task: snapshot)
        try HarnessRepairStageGate.requireEqual(
          stage: "buildSourceRevision", expected: current.patchRevision ?? "",
          actual: readback.sourceRevision)
        nextAttempt = current.updating(
          buildSourceRevision: readback.sourceRevision,
          buildOutputDigest: readback.outputDigest,
          buildOutputArtifactLease: readback.outputArtifactLease)
        let leaseParts = readback.outputArtifactLease.split(
          separator: ":", omittingEmptySubsequences: false)
        if leaseParts.count == 3 {
          try await recordAttemptBuildArtifacts(
            [String(leaseParts[2])], taskID: snapshot.htaskID)
        }

      case DebugCrashTaskHandler.runTests:
        guard let current = snapshot.repairAttempt,
          current.buildSourceRevision == current.patchRevision,
          current.buildOutputDigest != nil
        else {
          throw HarnessRepairPortError.stageGateMismatch(
            stage: "testSourceRevision", expected: snapshot.repairAttempt?.patchRevision ?? "-",
            actual: snapshot.repairAttempt?.buildSourceRevision ?? "-")
        }
        nextAttempt = current.updating(testsPassed: true)

      case DebugCrashTaskHandler.signOpenHarmonyHAP:
        guard let current = snapshot.repairAttempt,
          current.testsPassed,
          !current.buildOutputSigned,
          case .string(let unsignedLease)? = decision.inputs["unsignedHapArtifactLease"],
          unsignedLease == current.buildOutputArtifactLease
        else {
          throw HarnessRepairPortError.malformedReadback("signingAttempt")
        }
        let readback = try await repairPort.signedHAPReadback(
          jobID: observation.jobID, unsignedArtifactLease: unsignedLease, task: snapshot)
        nextAttempt = current.updating(
          buildOutputDigest: readback.outputDigest,
          buildOutputArtifactLease: readback.outputArtifactLease,
          buildOutputSigned: true)
        let leaseParts = readback.outputArtifactLease.split(
          separator: ":", omittingEmptySubsequences: false)
        if leaseParts.count == 3 {
          try await recordAttemptBuildArtifacts(
            [String(leaseParts[2])], taskID: snapshot.htaskID)
        }

      case DebugCrashTaskHandler.deployHAP:
        guard let current = snapshot.repairAttempt,
          let expected = current.buildOutputDigest
        else {
          throw HarnessRepairPortError.malformedReadback("buildOutputDigest")
        }
        let actual = try await repairPort.deployedArtifactDigest(jobID: observation.jobID)
        try HarnessRepairStageGate.requireEqual(
          stage: "deploymentArtifactDigest", expected: expected, actual: actual)
        nextAttempt = current.updating(deployedDigest: actual)
        nextPhase = .verifying

      case DebugCrashTaskHandler.revertPatch:
        guard let current = snapshot.repairAttempt else {
          throw HarnessRepairPortError.malformedReadback("revertAttempt")
        }
        nextAttempt = current.updating(rollbackRequired: false, reverted: true)
        try await closeAttempt(
          snapshot.htaskID, outcome: .reverted,
          reason: "repairRollbackReadback")
        nextPhase = .analyzing

      default:
        throw HarnessRepairPortError.unavailable(operationReference)
      }
    } catch let error as HarnessRepairPortError {
      if operationReference == DebugCrashTaskHandler.buildOpenHarmony
        || operationReference == DebugCrashTaskHandler.runTests
      {
        let classification =
          error.reasonCode == "WORKSPACE_REVISION_CONFLICT"
            || error.reasonCode.hasPrefix("stageGateMismatch")
          ? "WORKSPACE_REVISION_CONFLICT"
          : (operationReference == DebugCrashTaskHandler.buildOpenHarmony
            ? "BUILD_SEMANTIC_FAILURE" : "TEST_FAILURE")
        let digest = HarnessRequestIdentity.inputsDigest(decision.inputs)
        let print = fingerprint(
          snapshot, operationReference: operationReference, inputsDigest: digest,
          errorClassification: classification, semanticErrorCode: error.reasonCode)
        let record = try await recordFailure(
          snapshot, fingerprint: print,
          reasonCode: "\(classification):ALTERNATIVE_REQUIRED",
          jobID: observation.jobID)
        try await recordAttemptFailure(
          taskID: snapshot.htaskID, fingerprint: record.fingerprint,
          outcome: .failed)
        let alternative = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved,
            reasonCode: "\(classification):ALTERNATIVE_REQUIRED",
            status: .running, phase: .analyzing, activeJob: .cleared,
            jobID: observation.jobID))
        return HarnessReconcileOutcome(
          snapshot: alternative, action: .observedJob,
          reasonCode: "\(classification):ALTERNATIVE_REQUIRED")
      }
      if operationReference == DebugCrashTaskHandler.deployHAP,
        let current = snapshot.repairAttempt
      {
        var observed = snapshot.observedState
        observed[HarnessRepairAttempt.observedStateKey] =
          current.updating(
            rollbackRequired: true
          ).json
        let rollbackPending = try await commit(
          snapshot,
          transition(
            snapshot, causation: .jobObserved,
            reasonCode: "\(error.reasonCode):rollbackRequired",
            status: .running, activeJob: .cleared, jobID: observation.jobID,
            observedState: observed))
        return HarnessReconcileOutcome(
          snapshot: rollbackPending, action: .observedJob,
          reasonCode: "\(error.reasonCode):rollbackRequired")
      }
      let blocked = try await recordBlock(
        snapshot, block: .outcomeUnknown, reasonCode: error.reasonCode,
        round: snapshot.activeRound, jobID: observation.jobID, requestID: nil)
      return HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedForHuman,
        reasonCode: error.reasonCode)
    }

    guard let nextAttempt else {
      throw HarnessCoordinatorError.malformedRequest("repair attempt did not advance")
    }
    var observed =
      operationReference == DebugCrashTaskHandler.deployHAP
      ? Self.verificationEpochObservedState(snapshot)
      : snapshot.observedState
    if operationReference == DebugCrashTaskHandler.createCheckpoint {
      // The replacement candidate now has its own durable Attempt and exact
      // checkpoint. The prior promotion failure has done its routing job and
      // must not steer a later build/test failure around the normal rollback
      // path.
      observed.removeValue(forKey: DebugCrashTaskHandler.promotionRetryReasonKey)
    }
    if operationReference == DebugCrashTaskHandler.deployHAP {
      observed.removeValue(forKey: DebugCrashTaskHandler.deploymentPreflightRetryKey)
    }
    observed[HarnessRepairAttempt.observedStateKey] = nextAttempt.json
    try await appendTaskMemory(
      snapshot, kind: .observation,
      summary: "\(operationReference) passed its structural repair-stage readback",
      confidence: .observed,
      evidence: HarnessMemoryEvidence(jobIDs: [observation.jobID]))
    let advanced = try await commit(
      snapshot,
      transition(
        snapshot, causation: .jobObserved,
        reasonCode: "repairStageSucceeded:\(operationReference)",
        status: .running, phase: nextPhase, activeJob: .cleared,
        jobID: observation.jobID, observedState: observed,
        noProgressRounds:
          operationReference == DebugCrashTaskHandler.applyPatch
          || operationReference == DebugCrashTaskHandler.deployHAP ? 0 : nil,
        conditions: conditionsAfterSuccess(
          operationReference, snapshot: snapshot)))

    // `debug.hap@1` proves that the exact built digest was installed; it is
    // not a crash observation and publishes none of the evaluator's required
    // evidence.  After that gate succeeds, begin a new verification epoch and
    // let a real capture provide every sample.  Evaluating the install receipt
    // here would both invent an irrelevant missing-evidence round and retain
    // the injected crash's cumulative counter forever.
    return HarnessReconcileOutcome(
      snapshot: advanced, action: .observedJob, reasonCode: observation.state)
  }

  /// Keep device-local correlation such as the cumulative ledger watermark,
  /// but clear every criterion's cumulative value and sample count after the
  /// verified repair is deployed.  The injected failure belongs to the
  /// reproduction epoch; carrying its `matchingCrashCount == 1` into
  /// verification would make five later zero-increment captures add up to one
  /// and render PASS mathematically unreachable.
  private static func verificationEpochObservedState(
    _ snapshot: HarnessTaskSnapshot
  ) -> [String: JSONValue] {
    var measurements: [String: JSONValue] = [:]
    if let watermark = snapshot.observed.measurements[
      HarnessObservationBuilder.watermarkMetric]
    {
      measurements[HarnessObservationBuilder.watermarkMetric] = watermark
    }
    let epoch = HarnessObservedState(
      measurements: measurements, samples: [:], latestVerdict: nil,
      blockers: [], latestVerifiedEvidence: [])
    var observed = snapshot.observedState
    for key in [
      HarnessObservedState.measurementsKey, HarnessObservedState.samplesKey,
      HarnessObservedState.verdictKey, HarnessObservedState.blockersKey,
      HarnessObservedState.evidenceNamesKey,
    ] {
      observed.removeValue(forKey: key)
    }
    for (key, value) in epoch.asJSON { observed[key] = value }
    return observed
  }

  /// The analyzer is a transient execution stage; its conclusion returns to
  /// the product stage that requested it. Before fixture deployment, a first
  /// readable ledger establishes the baseline in `collecting`. Once the
  /// fixture has been injected, its next conclusion belongs to repair
  /// analysis. After a verified repair deployment, every conclusion remains
  /// in `verifying` until the evaluator passes or stops safely.
  private static func analysisReturnPhase(
    after snapshot: HarnessTaskSnapshot
  ) -> HarnessTaskPhase {
    if snapshot.phase == .verifying || snapshot.repairAttempt?.deployedDigest != nil {
      return .verifying
    }
    if snapshot.observedState[DebugCrashTaskHandler.baselineDeploymentMarker] == .bool(true) {
      return .analyzing
    }
    return .collecting
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
    jobID: String,
    sourceEvidenceJobID: String? = nil,
    expectedSourceArtifactID: String? = nil
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
      requiredEvidence: required, crashLedgerWatermark: watermark,
      sourceEvidenceJobID: sourceEvidenceJobID,
      expectedSourceArtifactID: expectedSourceArtifactID,
      expectedBindingRevision: snapshot.target.expectedBindingRevision,
      expectedDeployedArtifactDigest: snapshot.repairAttempt?.deployedDigest)

    let merged = snapshot.observed.merging(round)
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: snapshot.successCriteria, observed: merged, round: round,
      evaluationID: evaluationIDFactory(), htaskID: snapshot.htaskID, nowUTC: nowUTC())
    try await store.putEvaluation(evaluation)
    let observedState = merged.recording(verdict: evaluation.verdict, blockers: evaluation.blockers)
    var observedStateJSON = observedState.asJSON
    // Criteria projection owns its metric keys, but must not erase the
    // evidence-derived repair attempt that the stage gates just wrote.
    if let repair = snapshot.observedState[HarnessRepairAttempt.observedStateKey] {
      observedStateJSON[HarnessRepairAttempt.observedStateKey] = repair
    }
    if let baseline = snapshot.observedState[DebugCrashTaskHandler.baselineDeploymentMarker] {
      observedStateJSON[DebugCrashTaskHandler.baselineDeploymentMarker] = baseline
    }

    let artifactRefs = Self.mergedArtifactRefs(snapshot, round)
    if snapshot.requiresWorkspaceIsolation {
      try await recordAttemptRuntimeArtifacts(
        round.evidence.filter(\.verified).map(\.artifactID),
        taskID: snapshot.htaskID)
    }
    let evaluationConditions = conditionsAfterEvaluation(
      evaluation.verdict, snapshot: snapshot, evidenceArtifactIDs: artifactRefs)
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
      e1Mutations: snapshot.consumedBudget.e1Mutations,
      modelCalls: snapshot.consumedBudget.modelCalls)
    switch evaluation.verdict {
    case .pass:
      if snapshot.requiresWorkspaceIsolation {
        return try await finishEvolutionEvaluation(
          snapshot: snapshot, evaluation: evaluation, consumed: consumed,
          artifactRefs: artifactRefs, observedState: observedStateJSON,
          conditions: evaluationConditions)
      }
      try await recordAttemptEvaluation(
        taskID: snapshot.htaskID, evaluation: evaluation, outcome: .succeeded)
      let succeeded = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaPassed",
          status: .succeeded, activeJob: .cleared, consumedBudget: consumed,
          evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedStateJSON,
          noProgressRounds: 0,
          result: HarnessTaskResult(
            outcome: .succeeded, reasonCode: "criteriaPassed",
            summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs),
          conditions: evaluationConditions))
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
      try await recordAttemptEvaluation(
        taskID: snapshot.htaskID, evaluation: evaluation, outcome: .humanRequired)
      let recorded = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: reason, status: .running,
          consumedBudget: consumed, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedStateJSON,
          conditions: evaluationConditions))
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
        try await recordAttemptEvaluation(
          taskID: snapshot.htaskID, evaluation: evaluation,
          outcome: escalation == .failTask ? .failed : .humanRequired)
        let stopped = try await commit(
          snapshot,
          transition(
            snapshot, causation: .evaluation, reasonCode: reason, status: terminalStatus,
            activeJob: .cleared, consumedBudget: consumed,
            evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs, observedState: observedStateJSON,
            result: HarnessTaskResult(
              outcome: terminalStatus, reasonCode: reason,
              summary: Self.summary(of: evaluation), evaluationID: evaluation.evaluationID,
              artifactRefs: artifactRefs),
            conditions: evaluationConditions))
        return .ended(
          HarnessReconcileOutcome(
            snapshot: stopped,
            action: terminalStatus == .failed ? .stoppedNoSafeAction : .stoppedForHuman,
            reasonCode: reason))
      case .collectMoreEvidence, .none:
        try await recordAttemptEvaluation(
          taskID: snapshot.htaskID, evaluation: evaluation)
        let noProgress = Self.nextNoProgressRounds(
          before: snapshot, after: observedState, artifactRefs: artifactRefs)
        let updated = try await commit(
          snapshot,
          transition(
            snapshot, causation: .evaluation, reasonCode: "inconclusive:collectMoreEvidence",
            status: .running, consumedBudget: consumed,
            evaluationID: evaluation.evaluationID,
            artifactRefs: artifactRefs, observedState: observedStateJSON,
            noProgressRounds: noProgress, conditions: evaluationConditions))
        if noProgress >= snapshot.budgets.maxNoProgressRounds,
          snapshot.repairAttempt?.deployedDigest == nil
        {
          try await closeAttemptForNoProgress(snapshot.htaskID, rounds: noProgress)
        }
        return .continues(updated)
      }
    case .fail:
      // A real, evidence-backed failure: keep the task running so this wake
      // can plan against it, bounded by the budget.
      try await recordAttemptEvaluation(
        taskID: snapshot.htaskID, evaluation: evaluation)
      let noProgress = Self.nextNoProgressRounds(
        before: snapshot, after: observedState, artifactRefs: artifactRefs)
      let updated = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: "criteriaFailed", status: .running,
          consumedBudget: consumed, evaluationID: evaluation.evaluationID,
          artifactRefs: artifactRefs, observedState: observedStateJSON,
          noProgressRounds: noProgress, conditions: evaluationConditions))
      if noProgress >= snapshot.budgets.maxNoProgressRounds,
        snapshot.repairAttempt?.deployedDigest == nil
      {
        try await closeAttemptForNoProgress(snapshot.htaskID, rounds: noProgress)
      }
      return .continues(updated)
    }
  }

  private func finishEvolutionEvaluation(
    snapshot: HarnessTaskSnapshot,
    evaluation: HarnessEvaluation,
    consumed: HarnessConsumedBudget,
    artifactRefs: [String],
    observedState: [String: JSONValue],
    conditions: [HarnessTaskCondition]
  ) async throws -> EvaluationStep {
    try await recordAttemptEvaluation(taskID: snapshot.htaskID, evaluation: evaluation)
    let history = try await store.attempts(snapshot.htaskID)
    guard let attempt = history.last(where: { $0.outcome == .active }) else {
      return try await stopForPromotionIntegrity(
        snapshot: snapshot, evaluation: evaluation, consumed: consumed,
        artifactRefs: artifactRefs, observedState: observedState, conditions: conditions,
        reasonCode: "promotionGateRejected:activeAttemptMissing")
    }
    guard let candidate = attempt.candidatePatch else {
      return try await handlePromotionGateFailure(
        .candidatePatchMissing, snapshot: snapshot, attempt: attempt,
        evaluation: evaluation, consumed: consumed, artifactRefs: artifactRefs,
        observedState: observedState, conditions: conditions)
    }
    let promotion: HarnessPromotionCandidate
    do {
      guard let repairPort, let projectRef = snapshot.executionProjectRef,
        let repair = snapshot.repairAttempt, let patchRevision = repair.patchRevision
      else { throw HarnessPromotionGateFailure.stalePatch }
      let liveRevision = try await repairPort.currentWorkspaceRevision(
        relativePaths: candidate.files, projectRef: projectRef, task: snapshot)
      guard liveRevision == patchRevision else {
        throw HarnessPromotionGateFailure.stalePatch
      }
      promotion = try HarnessPromotionGate.evaluate(
        snapshot: snapshot, attempt: attempt, evaluation: evaluation,
        promotionCandidateID: promotionCandidateIDFactory(), createdAtUTC: nowUTC())
    } catch let failure as HarnessPromotionGateFailure {
      return try await handlePromotionGateFailure(
        failure, snapshot: snapshot, attempt: attempt, evaluation: evaluation,
        consumed: consumed, artifactRefs: artifactRefs,
        observedState: observedState, conditions: conditions)
    } catch {
      // A failed live-workspace readback is not a rejected candidate. Without
      // that trusted fact the coordinator cannot prove which source tree it
      // would repair, so this remains a typed integrity boundary.
      return try await stopForPromotionIntegrity(
        snapshot: snapshot, evaluation: evaluation, consumed: consumed,
        artifactRefs: artifactRefs, observedState: observedState, conditions: conditions,
        reasonCode: "promotionGateRejected:workspaceFactUnavailable")
    }
    try await recordAttemptPromotion(promotion, taskID: snapshot.htaskID)
    try await closeAttempt(
      snapshot.htaskID, outcome: .succeeded, reason: "promotionCandidateReady")
    let promotedArtifacts = Array(Set(artifactRefs + promotion.artifactIDs)).sorted()
    let succeeded = try await commit(
      snapshot,
      transition(
        snapshot, causation: .evaluation, reasonCode: "promotionCandidateReady",
        status: .succeeded, activeJob: .cleared, consumedBudget: consumed,
        evaluationID: evaluation.evaluationID,
        artifactRefs: promotedArtifacts, observedState: observedState,
        noProgressRounds: 0,
        result: HarnessTaskResult(
          outcome: .succeeded, reasonCode: "promotionCandidateReady",
          summary: "Evaluation passed; candidate is ready for a normal PR.",
          evaluationID: evaluation.evaluationID, artifactRefs: promotedArtifacts),
        conditions: conditions))
    try await promoteProjectMemory(succeeded, evaluation: evaluation)
    return .ended(
      HarnessReconcileOutcome(
        snapshot: succeeded, action: .evaluatedSucceeded,
        reasonCode: "promotionCandidateReady"))
  }

  /// Route a closed promotion failure without a catch-all terminal default.
  /// The disposition switch is exhaustive in `HarnessEvolution.swift`, so a
  /// future gate case cannot compile until its autonomous-debug boundary is
  /// chosen deliberately.
  private func handlePromotionGateFailure(
    _ failure: HarnessPromotionGateFailure,
    snapshot: HarnessTaskSnapshot,
    attempt: HarnessAttempt,
    evaluation: HarnessEvaluation,
    consumed: HarnessConsumedBudget,
    artifactRefs: [String],
    observedState: [String: JSONValue],
    conditions: [HarnessTaskCondition]
  ) async throws -> EvaluationStep {
    let reason = "promotionGateRejected:\(failure)"
    switch failure.coordinatorDisposition {
    case .retryCandidate:
      var retryObserved = observedState
      retryObserved[DebugCrashTaskHandler.promotionRetryReasonKey] = .string(reason)
      if let repair = snapshot.repairAttempt,
        repair.patchAttemptRef != nil, !repair.reverted
      {
        // The gate itself has no external effect, but the rejected candidate
        // may already be applied. Keep its Attempt active until the published
        // exact revert is read back; only then may a new strategy begin.
        retryObserved[HarnessRepairAttempt.observedStateKey] =
          repair.updating(rollbackRequired: true).json
      } else {
        try await closeAttempt(snapshot.htaskID, outcome: .failed, reason: reason)
      }
      try await appendTaskMemory(
        snapshot, kind: .attempt,
        summary: "promotion rejected the candidate; autonomous retry scheduled: \(reason)",
        confidence: .observed,
        evidence: HarnessMemoryEvidence(
          requestIDs: [attempt.attemptID], artifactIDs: artifactRefs))
      let retrying = try await commit(
        snapshot,
        transition(
          snapshot, causation: .evaluation, reasonCode: reason, status: .running,
          activeJob: .cleared, consumedBudget: consumed,
          evaluationID: evaluation.evaluationID, artifactRefs: artifactRefs,
          observedState: retryObserved, conditions: conditions))
      return .continues(retrying)
    case .evidenceIntegrityBlock:
      return try await stopForPromotionIntegrity(
        snapshot: snapshot, evaluation: evaluation, consumed: consumed,
        artifactRefs: artifactRefs, observedState: observedState, conditions: conditions,
        reasonCode: reason)
    }
  }

  private func stopForPromotionIntegrity(
    snapshot: HarnessTaskSnapshot,
    evaluation: HarnessEvaluation,
    consumed: HarnessConsumedBudget,
    artifactRefs: [String],
    observedState: [String: JSONValue],
    conditions: [HarnessTaskCondition],
    reasonCode: String
  ) async throws -> EvaluationStep {
    let recorded = try await commit(
      snapshot,
      transition(
        snapshot, causation: .evaluation, reasonCode: reasonCode, status: .running,
        activeJob: .cleared, consumedBudget: consumed,
        evaluationID: evaluation.evaluationID, artifactRefs: artifactRefs,
        observedState: observedState, conditions: conditions))
    let blocked = try await recordBlock(
      recorded, block: .evidenceIntegrity, reasonCode: reasonCode,
      round: recorded.activeRound, jobID: nil, requestID: nil)
    return .ended(
      HarnessReconcileOutcome(
        snapshot: blocked.snapshot, action: .stoppedEvidenceIntegrity,
        reasonCode: reasonCode))
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

  /// Marker the runtime prefixes to the machine-readable half of a capability
  /// rejection. Its counterpart is `RuntimeJobEngine.capabilityDenialMarker`;
  /// the two planes are deliberately decoupled and cannot share a constant, so
  /// a contract test pins them to each other instead.
  static let capabilityDenialMarker = "[denial:"

  /// Collapse a runtime rejection message into a stable, identifier-shaped
  /// semantic code so a fingerprint does not vary with prose.
  static func semanticCode(from message: String) -> String {
    // The runtime's own denial code outranks every heuristic below, because
    // those can only recognise that authorization was *involved*. Reporting a
    // revoked, expired and exhausted grant all as "authorization required"
    // describes none of them: each needs a different maintainer action, and
    // the task retries into the same wall until a human reads runtime logs.
    if let denial = capabilityDenialCode(in: message) { return denial }
    // The engine states its own typed rejection code, so reading it is not a
    // heuristic and outranks every guess below.
    //
    // The guesses could only ever see that a word appeared *somewhere* in a
    // sentence, and the engine's own preflight failure reads "typed plan
    // preflight failed before authorization: ...". So a rejected *input* -
    // a stale revision, a path outside the declared scopes - was reported as
    // an authorization block and stopped the task for a maintainer who had
    // nothing to approve and no grant that could have helped.
    if let typed = runtimeRejectionCode(in: message) { return typed }
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

  /// The engine's own `RuntimeOperationErrorCode`, read from the rejection it
  /// threw. `RuntimeJobEngineError.rejected` interpolates as
  /// `rejected(ArkDeckRuntime.RuntimeOperationErrorCode.<case>, "<message>")`,
  /// so the case name is present verbatim and needs no interpretation.
  ///
  /// `authorizationRequired` is one of those cases, which is what keeps a real
  /// authorization refusal on the approval path: the family test below is
  /// `hasPrefix("authorization")` and the runtime's own spelling satisfies it.
  static func runtimeRejectionCode(in message: String) -> String? {
    guard let marker = message.range(of: "RuntimeOperationErrorCode.") else { return nil }
    let token = message[marker.upperBound...].prefix(while: {
      $0.isASCII && ($0.isLetter || $0.isNumber)
    })
    guard (1...48).contains(token.count) else { return nil }
    return String(token)
  }

  /// The runtime's typed capability denial in this file's vocabulary. The
  /// `authorization` prefix is load-bearing: it keeps the whole family on the
  /// approval path below, where only the single generic code used to live.
  /// A token that is not identifier-shaped is prose that reached here by
  /// accident, and degrades to the family code rather than entering a
  /// fingerprint and splintering one failure into many.
  static func capabilityDenialCode(in message: String) -> String? {
    guard let marker = message.range(of: capabilityDenialMarker),
      let close = message[marker.upperBound...].firstIndex(of: "]")
    else { return nil }
    let token = message[marker.upperBound..<close]
    guard (1...48).contains(token.count),
      token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return "authorizationRequired" }
    return "authorization" + token.prefix(1).uppercased() + token.dropFirst()
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

  private func observedCondition(
    _ name: HarnessTaskConditionName,
    state: HarnessTriState,
    reasonCode: String,
    snapshot: HarnessTaskSnapshot,
    evidenceArtifactIDs: [String] = []
  ) -> HarnessTaskCondition {
    let previous = snapshot.condition(name)
    if previous.state == state, previous.reasonCode == reasonCode,
      previous.evidenceArtifactIDs == evidenceArtifactIDs
    {
      return previous
    }
    return HarnessTaskCondition(
      name: name, state: state, reasonCode: reasonCode,
      evidenceArtifactIDs: evidenceArtifactIDs, observedAt: nowUTC(),
      observedRevision: snapshot.version + 1)
  }

  private func replacingConditions(
    _ snapshot: HarnessTaskSnapshot,
    _ observations: [(HarnessTaskConditionName, HarnessTriState, String)]
  ) -> [HarnessTaskCondition] {
    HarnessTaskConditionSet.replacing(
      snapshot.conditions,
      with: observations.map {
        observedCondition(
          $0.0, state: $0.1, reasonCode: $0.2, snapshot: snapshot)
      })
  }

  private func conditionsAfterDispatch(
    _ operationReference: String,
    snapshot: HarnessTaskSnapshot
  ) -> [HarnessTaskCondition] {
    var observations: [(HarnessTaskConditionName, HarnessTriState, String)] = []
    let admitted = "runtimeAdmissionAccepted"
    if [
      DebugCrashTaskHandler.captureDiagnostics, DebugCrashTaskHandler.deployHAP,
    ].contains(operationReference) {
      observations += [
        (.targetResolved, .trueValue, admitted),
        (.deviceBound, .trueValue, admitted),
        (.deviceReady, .trueValue, admitted),
      ]
    }
    if [
      DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
      DebugCrashTaskHandler.buildOpenHarmony,
      DebugCrashTaskHandler.signOpenHarmonyHAP, DebugCrashTaskHandler.runTests,
      DebugCrashTaskHandler.revertPatch,
    ].contains(operationReference) {
      observations.append((.workspaceReady, .trueValue, admitted))
    }
    switch operationReference {
    case DebugCrashTaskHandler.createCheckpoint:
      observations += [
        (.reproductionConfirmed, .trueValue, "verifiedCriteriaFailure"),
        (.analysisReady, .trueValue, "boundedPatchDecision"),
        (.patchProposalReady, .trueValue, "preparedPatchLease"),
      ]
    case DebugCrashTaskHandler.applyPatch:
      observations += [
        (.reproductionConfirmed, .trueValue, "verifiedCriteriaFailure"),
        (.analysisReady, .trueValue, "boundedPatchDecision"),
        (.patchProposalReady, .trueValue, "preparedPatchLease"),
      ]
    case DebugCrashTaskHandler.buildOpenHarmony:
      observations.append((.patchApplied, .trueValue, "patchReadbackMatched"))
    case DebugCrashTaskHandler.signOpenHarmonyHAP:
      observations.append((.buildOutputsReady, .trueValue, "unsignedBuildArtifactResolved"))
    case DebugCrashTaskHandler.runTests:
      observations.append((.buildOutputsReady, .trueValue, "buildReadbackMatched"))
    case DebugCrashTaskHandler.deployHAP:
      if snapshot.repairAttempt != nil {
        observations += [
          (.patchApplied, .trueValue, "patchReadbackMatched"),
          (.buildPassed, .trueValue, "testsPassed"),
          (.buildOutputsReady, .trueValue, "buildReadbackMatched"),
        ]
      }
    case DebugCrashTaskHandler.revertPatch:
      observations += [
        (.artifactsReady, .trueValue, "verifiedFailureTriggeredRollback"),
        (.verificationEvidenceReady, .trueValue, "verifiedFailureTriggeredRollback"),
      ]
    case DebugCrashTaskHandler.analyzeCrashLedger:
      observations.append((.artifactsReady, .trueValue, "verifiedAnalyzerSourceLease"))
    default:
      break
    }
    return replacingConditions(snapshot, observations)
  }

  private func conditionsAfterSuccess(
    _ operationReference: String,
    snapshot: HarnessTaskSnapshot,
    evidenceArtifactIDs: [String] = []
  ) -> [HarnessTaskCondition] {
    var observations: [(HarnessTaskConditionName, HarnessTriState, String)] = []
    switch operationReference {
    case DebugCrashTaskHandler.observeDevice:
      observations = [
        (.targetResolved, .trueValue, "targetObservationSucceeded"),
        (.deviceBound, .trueValue, "targetObservationSucceeded"),
        (.deviceReady, .trueValue, "targetObservationSucceeded"),
      ]
    case DebugCrashTaskHandler.captureDiagnostics:
      observations = [
        (.targetResolved, .trueValue, "diagnosticCaptureSucceeded"),
        (.deviceBound, .trueValue, "diagnosticCaptureSucceeded"),
        (.deviceReady, .trueValue, "diagnosticCaptureSucceeded"),
        (.artifactsReady, .trueValue, "diagnosticArtifactsPublished"),
      ]
    case DebugCrashTaskHandler.analyzeCrashLedger:
      observations = [
        (.artifactsReady, .trueValue, "derivedArtifactVerified"),
        (.analysisReady, .trueValue, "deterministicAnalysisSucceeded"),
        (.verificationEvidenceReady, .trueValue, "derivedArtifactVerified"),
      ]
    case DebugCrashTaskHandler.createCheckpoint:
      observations = [
        (.workspaceReady, .trueValue, "checkpointPublished"),
        (.patchProposalReady, .trueValue, "preparedPatchLease"),
      ]
    case DebugCrashTaskHandler.applyPatch:
      observations = [
        (.workspaceReady, .trueValue, "patchReadbackMatched"),
        (.patchProposalReady, .trueValue, "preparedPatchLease"),
        (.patchApplied, .trueValue, "patchReadbackMatched"),
      ]
    case DebugCrashTaskHandler.buildOpenHarmony:
      observations = [
        (.workspaceReady, .trueValue, "buildReadbackMatched"),
        (.patchApplied, .trueValue, "buildSourceRevisionMatched"),
        (.buildOutputsReady, .trueValue, "buildOutputPublished"),
      ]
    case DebugCrashTaskHandler.signOpenHarmonyHAP:
      observations = [
        (.workspaceReady, .trueValue, "signingPresetVerified"),
        (.buildPassed, .trueValue, "testsPassed"),
        (.buildOutputsReady, .trueValue, "signedBuildOutputVerified"),
      ]
    case DebugCrashTaskHandler.runTests:
      observations = [
        (.workspaceReady, .trueValue, "testReadbackMatched"),
        (.buildPassed, .trueValue, "testsPassed"),
        (.buildOutputsReady, .trueValue, "buildOutputPublished"),
      ]
    case DebugCrashTaskHandler.deployHAP:
      observations = [
        (.targetResolved, .trueValue, "deploymentReadbackMatched"),
        (.deviceBound, .trueValue, "deploymentReadbackMatched"),
        (.deviceReady, .trueValue, "deploymentReadbackMatched"),
        (.deploymentObserved, .trueValue, "deploymentReadbackMatched"),
      ]
    case DebugCrashTaskHandler.revertPatch:
      observations = [
        (.workspaceReady, .trueValue, "rollbackReadbackMatched"),
        (.patchApplied, .falseValue, "rollbackReadbackMatched"),
      ]
    default:
      break
    }
    let replacements = observations.map {
      observedCondition(
        $0.0, state: $0.1, reasonCode: $0.2, snapshot: snapshot,
        evidenceArtifactIDs: evidenceArtifactIDs)
    }
    return HarnessTaskConditionSet.replacing(snapshot.conditions, with: replacements)
  }

  private func conditionsAfterEvaluation(
    _ verdict: HarnessEvaluationVerdict,
    snapshot: HarnessTaskSnapshot,
    evidenceArtifactIDs: [String]
  ) -> [HarnessTaskCondition] {
    let observations: [(HarnessTaskConditionName, HarnessTriState, String)]
    switch verdict {
    case .pass:
      observations = [
        (.analysisReady, .trueValue, "criteriaEvaluated"),
        (.verificationEvidenceReady, .trueValue, "criteriaEvidenceVerified"),
        (.criteriaSatisfied, .trueValue, "criteriaPassed"),
      ]
    case .fail:
      observations = [
        (.reproductionConfirmed, .trueValue, "criteriaFailedOnVerifiedEvidence"),
        (.analysisReady, .trueValue, "criteriaEvaluated"),
        (.verificationEvidenceReady, .trueValue, "criteriaEvidenceVerified"),
        (.criteriaSatisfied, .falseValue, "criteriaFailed"),
      ]
    case .inconclusive:
      observations = [
        (.analysisReady, .trueValue, "criteriaEvaluated"),
        (.verificationEvidenceReady, .falseValue, "criteriaEvidenceIncomplete"),
        (.criteriaSatisfied, .unknown, "criteriaInconclusive"),
      ]
    case .error:
      observations = [
        (.analysisReady, .falseValue, "criteriaEvidenceIntegrityError"),
        (.verificationEvidenceReady, .falseValue, "criteriaEvidenceIntegrityError"),
        (.criteriaSatisfied, .unknown, "criteriaEvidenceIntegrityError"),
      ]
    }
    let replacements = observations.map {
      observedCondition(
        $0.0, state: $0.1, reasonCode: $0.2, snapshot: snapshot,
        evidenceArtifactIDs: evidenceArtifactIDs)
    }
    return HarnessTaskConditionSet.replacing(snapshot.conditions, with: replacements)
  }

  private func recordRuntimeWait(
    _ observation: HarnessJobObservation,
    snapshot: HarnessTaskSnapshot
  ) async throws -> HarnessTaskSnapshot {
    let waitReason: HarnessTaskWaitReason
    let conditions: [HarnessTaskCondition]
    switch observation.state {
    case JobState.waitingForDevice.rawValue:
      waitReason = .deviceUnavailable
      conditions = replacingConditions(
        snapshot, [(.deviceReady, .falseValue, "runtimeDeviceDisconnected")])
    case JobState.awaitingRebindConfirmation.rawValue:
      waitReason = .deviceUnavailable
      conditions = replacingConditions(
        snapshot,
        [
          (.deviceBound, .unknown, "bindingRevisionRequiresConfirmation"),
          (.deviceReady, .unknown, "bindingRevisionRequiresConfirmation"),
        ])
    case JobState.waitingForRecovery.rawValue:
      waitReason = .observationWindow
      conditions = snapshot.conditions
    default:
      waitReason = .activeJob
      conditions = snapshot.conditions
    }
    guard
      snapshot.status != .waiting || snapshot.waitReason != waitReason
        || snapshot.conditions != conditions
    else {
      return snapshot
    }
    return try await commit(
      snapshot,
      transition(
        snapshot, causation: .jobObserved, reasonCode: observation.state,
        status: .waiting, activeJob: .set(observation.jobID), jobID: observation.jobID,
        waitReason: waitReason, conditions: conditions))
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
    result: HarnessTaskResult? = nil,
    waitReason: HarnessTaskWaitReason? = nil,
    conditions: [HarnessTaskCondition]? = nil
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
      atUTC: nowUTC(),
      waitReason: status == .waiting ? (waitReason ?? snapshot.waitReason) : nil,
      conditions: conditions ?? snapshot.conditions)
  }

  /// Charge the effect of the exact Catalog steps selected by the typed
  /// request. Workspace mutations and device deployment share this one
  /// bounded E1 ledger; rejected or stale requests never reach this point.
  static func consumesHarnessE1Budget(
    _ operationReference: String, inputs: [String: JSONValue]
  ) -> Bool {
    guard let descriptor = RuntimeOperationCatalog.descriptor(reference: operationReference)
    else {
      // Dispatch rejects an unknown operation elsewhere. If that invariant
      // ever regresses, accounting must not make the unknown plan cheaper.
      return true
    }
    return CatalogOperationEffectResolver.effectiveEffect(
      descriptor: descriptor, inputs: inputs) >= .deviceMutation
  }

  private func requestBytes(
    _ intent: HarnessDispatchIntent,
    _ decision: HarnessDecision,
    _ snapshot: HarnessTaskSnapshot
  ) async throws -> Data {
    let parts = intent.operationReference.split(separator: "@")
    guard parts.count == 2, let version = Int(parts[1]) else {
      throw HarnessCoordinatorError.malformedRequest(intent.operationReference)
    }
    do {
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: intent.operationReference)
      var authorizationReference: RuntimeCapabilityReference?
      if let descriptor, descriptor.minimumEffect >= .deviceMutation,
        let capabilityID = await policyGuard.capabilityPort?.standingCapabilityID(
          operationReference: intent.operationReference,
          targetID: intent.targetID,
          expectedBindingRevision: descriptor.binding == WorkflowBindingRequirement.none
            ? nil : intent.expectedBindingRevision,
          inputs: decision.inputs) ?? nil
      {
        authorizationReference = RuntimeCapabilityReference(capabilityID: capabilityID)
      }
      let request = try RuntimeOperationRequest(
        requestID: intent.requestID,
        idempotencyKey: intent.idempotencyKey,
        target: DurableTargetReference(
          targetID: intent.targetID,
          expectedBindingRevision: descriptor?.binding == WorkflowBindingRequirement.none
            ? nil : intent.expectedBindingRevision),
        operation: RuntimeOperationReference(id: String(parts[0]), version: version),
        inputs: decision.inputs,
        requestedOutputs: [.rawArtifacts, .derivedArtifacts],
        // Names an installed grant when the step needs one (CHG-2026-055,
        // TASK-HFA-009 r2). The harness still never mints, drafts or widens a
        // capability — it points at one a maintainer issued, and the engine
        // re-checks scope, revision, expiry and plan before consuming it. An
        // E0 step names nothing, which is why this is nil far more often than
        // not.
        authorization: authorizationReference,
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
