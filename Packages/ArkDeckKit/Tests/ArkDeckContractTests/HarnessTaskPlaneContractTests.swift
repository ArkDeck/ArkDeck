// Harness task plane contract tests (CHG-2026-054, TASK-HTP-001).
//
// Registered acceptance: HTP-AC-1 (one effectful job per wake), HTP-AC-2
// (dispatch-intent crash recovery with zero duplicate side effects),
// HTP-AC-3 (state changes only through the reducer, every transition
// recorded), HTP-AC-4 (timeline survives a restart verbatim).
//
// The fake port counts *side effects by idempotency key*, not submit calls:
// that is the property recovery has to preserve, and counting calls would
// pass while duplicating effects.

import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private struct SubmittedRequest: Equatable {
  let requestID: String
  let idempotencyKey: String
  let operationReference: String
  let targetID: String
  let provenance: [String: String]
  let hasAuthorization: Bool
  let rawJSON: String
}

private enum PortBehaviour: Equatable {
  case accept
  /// The engine received the submit; the answer was lost on the way back.
  case loseAnswerAfterEngineReceived
  /// The submit never reached the engine.
  case failBeforeEngineReceived
  case reject(String)
}

private final class RecordingJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var effects: [String: String] = [:]
  private var observations: [String: HarnessJobObservation] = [:]
  private var submissions: [SubmittedRequest] = []
  private var runs: [String] = []
  private var cancels: [String] = []
  private var behaviourValue: PortBehaviour = .accept
  private var nextJobOrdinal = 1

  var behaviour: PortBehaviour {
    get { lock.withLock { behaviourValue } }
    set { lock.withLock { behaviourValue = newValue } }
  }
  var submittedRequests: [SubmittedRequest] { lock.withLock { submissions } }
  var distinctEffectKeys: [String] { lock.withLock { effects.keys.sorted() } }
  var startedRuns: [String] { lock.withLock { runs } }
  var cancelRequests: [String] { lock.withLock { cancels } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let decoded = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    let record = SubmittedRequest(
      requestID: decoded.requestID,
      idempotencyKey: decoded.idempotencyKey,
      operationReference: decoded.operation.reference,
      targetID: decoded.target.targetID,
      provenance: decoded.clientContext?.provenance ?? [:],
      hasAuthorization: decoded.authorization != nil,
      rawJSON: String(data: requestJSON, encoding: .utf8) ?? "")
    return try lock.withLock {
      submissions.append(record)
      switch behaviourValue {
      case .failBeforeEngineReceived:
        throw HarnessJobPortError.transportFailure("socket closed before the engine saw it")
      case .reject(let message):
        throw HarnessJobPortError.rejected(message)
      case .accept, .loseAnswerAfterEngineReceived:
        let existing = effects[decoded.idempotencyKey]
        let jobID = existing ?? "JOB-\(nextJobOrdinal)"
        if existing == nil {
          nextJobOrdinal += 1
          effects[decoded.idempotencyKey] = jobID
          observations[jobID] = HarnessJobObservation(
            jobID: jobID, state: "running", isTerminal: false, succeeded: false,
            outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
        }
        if behaviourValue == .loseAnswerAfterEngineReceived {
          throw HarnessJobPortError.transportFailure("answer lost after the engine accepted")
        }
        return HarnessJobAcceptance(jobID: jobID, deduplicated: existing != nil)
      }
    }
  }

  func startRun(jobID: String) async throws {
    lock.withLock { runs.append(jobID) }
  }

  func observe(jobID: String) async throws -> HarnessJobObservation {
    try lock.withLock {
      guard let observation = observations[jobID] else {
        throw HarnessJobPortError.unknownJob(jobID)
      }
      return observation
    }
  }

  func requestCancel(jobID: String) async throws {
    lock.withLock { cancels.append(jobID) }
  }

  // MARK: - Test controls

  func finish(_ jobID: String, state: String = "succeeded", outcomeUnknown: Bool = false) {
    lock.withLock {
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
        outcomeUnknown: outcomeUnknown, waitingForHuman: false,
        timeline: ["queued", "running", state])
    }
  }
}

/// The daemon-surface tests never reach the engine's dispatch port: the
/// harness talks to the fake job port above, and a dispatcher that refuses
/// makes an accidental real dispatch a failure rather than a surprise.
private struct NeverDispatchingPort: RuntimeProcessDispatching {
  let reason: String

  func unavailableReason(providerID: String) -> String? { reason }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed(reason)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

final class HarnessTaskPlaneContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - Helpers

  private func makeCoordinator(
    port: RecordingJobPort,
    clock: @escaping @Sendable () -> String = { "2026-07-30T00:00:00Z" }
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: port, nowUTC: clock)
    return (coordinator, store)
  }

  private func submission(
    maxRounds: Int = 8,
    allowedOperations: [String]? = nil
  ) -> HarnessTaskSubmission {
    HarnessTaskSubmission(
      type: .debugCrash,
      intakeDescription: "WaterFlow crashes when scrolled to the end.",
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7", expectedBindingRevision: 7),
      goal: HarnessTaskGoal(summary: "No SIGABRT in WaterFlow::RecoverBack across five runs."),
      budgets: HarnessTaskBudgets(
        maxRounds: maxRounds, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 0),
      policy: allowedOperations.map(HarnessTaskPolicy.init(allowedOperations:))
        ?? HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
  }

  private func dispatchedEvents(_ events: [HarnessTaskEvent]) -> [HarnessTaskEvent] {
    events.filter { $0.causation == .jobDispatched }
  }

  // MARK: - HTP-AC-1

  func testOneWakeDispatchesAtMostOneEffectfulJob() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())

    let first = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(first.action, .dispatched)
    XCTAssertEqual(first.dispatchedJobID, "JOB-1")
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
    XCTAssertEqual(port.startedRuns, ["JOB-1"])

    // The active job owns the round: further wakes must not start anything.
    for _ in 0..<3 {
      let outcome = try await coordinator.reconcile(task.htaskID)
      XCTAssertEqual(outcome.action, .waitedForActiveJob)
      XCTAssertNil(outcome.dispatchedJobID)
    }
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
    XCTAssertEqual(port.submittedRequests.count, 1)
    let events = try await coordinator.events(task.htaskID)
    XCTAssertEqual(dispatchedEvents(events).count, 1)
  }

  func testConcurrentWakesStillDispatchOnce() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())

    // Six callers racing the same task: the actor serialises them, and the
    // active-job guard makes every wake after the first a no-op.
    await withTaskGroup(of: HarnessReconcileAction?.self) { group in
      for _ in 0..<6 {
        group.addTask { try? await coordinator.reconcile(task.htaskID).action }
      }
      var actions: [HarnessReconcileAction] = []
      for await action in group { if let action { actions.append(action) } }
      XCTAssertEqual(actions.filter { $0 == .dispatched }.count, 1)
    }
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
    let events = try await coordinator.events(task.htaskID)
    XCTAssertEqual(dispatchedEvents(events).count, 1)
  }

  // MARK: - HTP-AC-2

  func testRecoveryReusesTheKeyWhenTheEngineAlreadyReceivedTheSubmit() async throws {
    let port = RecordingJobPort()
    port.behaviour = .loseAnswerAfterEngineReceived
    let (coordinator, store) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())

    do {
      _ = try await coordinator.reconcile(task.htaskID)
      XCTFail("a lost submit answer must propagate, not be swallowed")
    } catch {}

    // Window B: the intent records that the engine may already have it.
    let unresolved = try await store.unresolvedIntents(task.htaskID)
    XCTAssertEqual(unresolved.count, 1)
    XCTAssertEqual(unresolved[0].state, .submitted)
    XCTAssertNil(unresolved[0].jobID)
    let originalKey = unresolved[0].idempotencyKey
    let midSnapshot = try await coordinator.status(task.htaskID)
    XCTAssertNil(midSnapshot.activeJobID)
    let midEvents = try await coordinator.events(task.htaskID)
    XCTAssertEqual(dispatchedEvents(midEvents).count, 0)

    port.behaviour = .accept
    let recovered = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(recovered.action, .recoveredIntent)
    XCTAssertEqual(recovered.reasonCode, "deduplicated")
    XCTAssertEqual(recovered.dispatchedJobID, "JOB-1")
    XCTAssertEqual(port.submittedRequests.map(\.idempotencyKey), [originalKey, originalKey])
    // The only property that matters: one side effect, not two.
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
    let snapshot = try await coordinator.status(task.htaskID)
    XCTAssertEqual(snapshot.activeJobID, "JOB-1")
    let remaining = try await store.unresolvedIntents(task.htaskID)
    XCTAssertEqual(remaining.count, 0)
  }

  func testRecoveryResubmitsTheSameKeyWhenTheEngineNeverReceivedIt() async throws {
    let port = RecordingJobPort()
    port.behaviour = .failBeforeEngineReceived
    let (coordinator, store) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())

    do {
      _ = try await coordinator.reconcile(task.htaskID)
      XCTFail("a failed submit must propagate")
    } catch {}
    XCTAssertEqual(port.distinctEffectKeys.count, 0)
    let pending = try await store.unresolvedIntents(task.htaskID)
    let key = pending[0].idempotencyKey

    port.behaviour = .accept
    let recovered = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(recovered.action, .recoveredIntent)
    XCTAssertEqual(recovered.reasonCode, "fresh")
    XCTAssertEqual(port.submittedRequests.map(\.idempotencyKey), [key, key])
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
  }

  func testANewCoordinatorRecoversTheLostDispatchIntent() async throws {
    let port = RecordingJobPort()
    port.behaviour = .loseAnswerAfterEngineReceived
    let (first, _) = try makeCoordinator(port: port)
    let task = try await first.submit(submission())
    do {
      _ = try await first.reconcile(task.htaskID)
      XCTFail("expected the lost answer to propagate")
    } catch {}

    // Process death: a brand new store object and coordinator over the same
    // directory, exactly what the daemon does on restart.
    port.behaviour = .accept
    let (second, store) = try makeCoordinator(port: port)
    let recovered = try await second.recoverTasks()
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recovered[0].activeJobID, "JOB-1")
    XCTAssertEqual(port.distinctEffectKeys.count, 1)
    let leftover = try await store.unresolvedIntents(task.htaskID)
    XCTAssertEqual(leftover.count, 0)
    let recoveredEvents = try await second.events(task.htaskID)
    XCTAssertEqual(
      dispatchedEvents(recoveredEvents).first?.reasonCode,
      "recoveredDispatchIntent:deduplicated")
  }

  func testRejectedAdmissionIsNotRetriedByRecovery() async throws {
    let port = RecordingJobPort()
    port.behaviour = .reject("operation is unavailable: provider_not_registered")
    let (coordinator, store) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "submissionRejected")
    let unresolvedAfterReject = try await store.unresolvedIntents(task.htaskID)
    XCTAssertEqual(unresolvedAfterReject.count, 0)
    let allIntents = try await store.intents(task.htaskID)
    XCTAssertEqual(allIntents.map(\.state), [.rejected])
    XCTAssertEqual(port.distinctEffectKeys.count, 0)

    // A human block does not resolve itself, and nothing re-submits.
    let again = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(again.action, .awaitingHuman)
    XCTAssertEqual(port.submittedRequests.count, 1)
  }

  func testOutcomeUnknownStopsAndNeverResendsTheSideEffect() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)
    port.finish("JOB-1", state: "waitingForRecovery", outcomeUnknown: true)

    let stopped = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(stopped.action, .stoppedForHuman)
    XCTAssertTrue(stopped.reasonCode.hasPrefix("outcomeUnknown:"))
    XCTAssertEqual(stopped.snapshot.status, .humanRequired)
    XCTAssertNil(stopped.snapshot.activeJobID)

    for _ in 0..<2 {
      let idle = try await coordinator.reconcile(task.htaskID)
      XCTAssertEqual(idle.action, .awaitingHuman)
    }
    XCTAssertEqual(port.submittedRequests.count, 1, "outcomeUnknown must never re-send")
  }

  // MARK: - HTP-AC-3

  func testReducerRejectsIllegalTransitions() throws {
    let base = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: nil, target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "goal"), successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: ["observe.device@1"]),
      createdAtUTC: "2026-07-30T00:00:00Z", updatedAtUTC: "2026-07-30T00:00:00Z",
      status: .running, phase: .initializing)

    func transition(
      _ causation: HarnessTaskCausation,
      status: HarnessTaskStatus,
      phase: HarnessTaskPhase = .initializing,
      activeJobID: String? = nil,
      jobID: String? = nil,
      evaluationID: String? = nil,
      round: Int = 0,
      artifactRefs: [String] = [],
      cancelRequested: Bool = false,
      consumed: HarnessConsumedBudget = HarnessConsumedBudget(),
      result: HarnessTaskResult? = nil
    ) -> HarnessTaskTransition {
      HarnessTaskTransition(
        causation: causation, reasonCode: "test", status: status, phase: phase,
        activeRound: round, activeJobID: activeJobID, consumedBudget: consumed, jobID: jobID,
        evaluationID: evaluationID, artifactRefs: artifactRefs,
        cancelRequested: cancelRequested, result: result, atUTC: "2026-07-30T00:01:00Z",
        waitReason: status == .waiting
          ? (causation == .pauseRequested ? .userSuspended : .activeJob) : nil,
        conditions: base.conditions)
    }

    // Success is unreachable without an evaluation: this is the structural
    // form of "only the evaluator may declare success".
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(
          .jobObserved, status: .succeeded,
          result: HarnessTaskResult(outcome: .succeeded, reasonCode: "fixed", summary: "done")),
        to: base)
    ) { error in
      XCTAssertEqual(
        error as? HarnessTaskTransitionError, .successRequiresEvaluation)
    }

    // Phase graph: no jumping from initializing straight to verifying.
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(.jobObserved, status: .running, phase: .verifying), to: base)
    ) { error in
      XCTAssertEqual(
        error as? HarnessTaskTransitionError,
        .illegalPhase(from: .initializing, to: .verifying))
    }

    // A second effectful job while one is active.
    let busy = base.applying(
      HarnessTaskProjection(
        status: .waiting, phase: .initializing, activeRound: 1, activeJobID: "JOB-1",
        consumedBudget: HarnessConsumedBudget(rounds: 1), artifactRefs: [],
        cancelRequested: false, result: nil, version: 2, waitReason: .activeJob),
      atUTC: "2026-07-30T00:00:30Z")
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(
          .jobDispatched, status: .waiting, activeJobID: "JOB-2", jobID: "JOB-2", round: 2,
          consumed: HarnessConsumedBudget(rounds: 2)),
        to: busy)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .jobAlreadyActive("JOB-1"))
    }

    // Budget and artifact records only move forward.
    let advanced = base.applying(
      HarnessTaskProjection(
        status: .running, phase: .initializing, activeRound: 2,
        activeJobID: nil, consumedBudget: HarnessConsumedBudget(rounds: 2),
        artifactRefs: ["ART-1"], cancelRequested: false, result: nil, version: 2),
      atUTC: "2026-07-30T00:00:30Z")
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(.jobObserved, status: .running, round: 2, artifactRefs: ["ART-1"]),
        to: advanced)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .budgetRegressed)
    }
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(
          .jobObserved, status: .running, round: 2, artifactRefs: [],
          consumed: HarnessConsumedBudget(rounds: 2)),
        to: advanced)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .artifactRefsShrank)
    }

    // A recorded cancel cannot be withdrawn, and no dispatch may follow it.
    let cancelling = base.applying(
      HarnessTaskProjection(
        status: .running, phase: .initializing, activeRound: 1, activeJobID: nil,
        consumedBudget: HarnessConsumedBudget(rounds: 1), artifactRefs: [],
        cancelRequested: true, result: nil, version: 2),
      atUTC: "2026-07-30T00:00:30Z")
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(
          .jobDispatched, status: .running, activeJobID: "JOB-9", jobID: "JOB-9", round: 2,
          cancelRequested: true, consumed: HarnessConsumedBudget(rounds: 2)),
        to: cancelling)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .cancelPending)
    }
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(
          .jobObserved, status: .running, round: 1,
          consumed: HarnessConsumedBudget(rounds: 1)),
        to: cancelling)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .cancelRequestWithdrawn)
    }

    // Terminal is terminal.
    let finished = base.applying(
      HarnessTaskProjection(
        status: .failed, phase: .initializing, activeRound: 1, activeJobID: nil,
        consumedBudget: HarnessConsumedBudget(rounds: 1), artifactRefs: [],
        cancelRequested: false,
        result: HarnessTaskResult(outcome: .failed, reasonCode: "x", summary: "y"), version: 2),
      atUTC: "2026-07-30T00:00:30Z")
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        transition(.humanResolved, status: .running, round: 1), to: finished)
    ) { error in
      XCTAssertEqual(error as? HarnessTaskTransitionError, .terminal(.failed))
    }
  }

  func testReducerAllowsLedgerBaselineToEnterCrashReproduction() throws {
    let base = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash,
      intakeDescription: nil, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
      goal: HarnessTaskGoal(summary: "inject crash after baseline"),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 60, maxArtifactBytes: 1024,
        maxE1Mutations: 3),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z",
      status: .running, phase: .collecting,
      conditions: HarnessTaskConditionSet.replacing(
        HarnessTaskConditionSet.unknown(),
        with: [.targetResolved, .deviceBound, .deviceReady].map {
          HarnessTaskCondition(name: $0, state: .trueValue, reasonCode: "fixture")
        }))
    let transition = HarnessTaskTransition(
      causation: .jobDispatched, reasonCode: "deployBaselineCrashFixture",
      status: .waiting, phase: .reproducing, activeRound: 3,
      activeJobID: "JOB-BASELINE", consumedBudget: HarnessConsumedBudget(
        rounds: 3, e1Mutations: 1), jobID: "JOB-BASELINE",
      artifactRefs: [], cancelRequested: false,
      atUTC: "2026-07-31T00:00:01Z", waitReason: .activeJob,
      conditions: base.conditions)

    let (advanced, _) = try HarnessTaskStateReducer.apply(transition, to: base)
    XCTAssertEqual(advanced.phase, .reproducing)
    XCTAssertEqual(advanced.activeJobID, "JOB-BASELINE")
  }

  func testStaleVersionCommitIsRejected() async throws {
    let port = RecordingJobPort()
    let (coordinator, store) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)
    let current = try await store.load(task.htaskID)

    let (updated, event) = try HarnessTaskStateReducer.apply(
      HarnessTaskTransition(
        causation: .pauseRequested, reasonCode: "stale", status: .waiting, phase: current.phase,
        activeRound: current.activeRound, activeJobID: current.activeJobID,
        consumedBudget: current.consumedBudget, artifactRefs: current.artifactRefs,
        cancelRequested: current.cancelRequested, atUTC: "2026-07-30T00:02:00Z",
        waitReason: .userSuspended, conditions: current.conditions),
      to: current)
    do {
      // Version 1 was the created state; the task has advanced past it.
      try await store.commit(event: event, snapshot: updated, expectedVersion: 1)
      XCTFail("a stale expected version must not be able to overwrite a task")
    } catch let error as HarnessTaskStoreError {
      XCTAssertEqual(error, .versionConflict(expected: 1, actual: current.version))
    }
  }

  func testEveryTransitionCarriesCausationAndJoinsItsVersion() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)
    port.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)

    let events = try await coordinator.events(task.htaskID)
    XCTAssertFalse(events.isEmpty)
    var expectedSequence = 1
    for event in events {
      XCTAssertEqual(event.sequence, expectedSequence)
      XCTAssertEqual(event.resulting.version, event.sequence + 1)
      XCTAssertFalse(event.reasonCode.isEmpty)
      XCTAssertEqual(event.htaskID, task.htaskID)
      if event.causation == .jobDispatched {
        XCTAssertEqual(event.jobID, event.resulting.activeJobID)
        XCTAssertNotNil(event.jobID)
      }
      expectedSequence += 1
    }
    XCTAssertEqual(events.map(\.causation).prefix(3), [.admitted, .jobDispatched, .jobObserved])
  }

  // MARK: - HTP-AC-4

  func testTaskTimelineSurvivesARestartVerbatim() async throws {
    let port = RecordingJobPort()
    let (first, _) = try makeCoordinator(port: port)
    let task = try await first.submit(submission())
    _ = try await first.reconcile(task.htaskID)  // observe.device dispatched
    port.finish("JOB-1")
    _ = try await first.reconcile(task.htaskID)  // observed -> capture dispatched
    port.finish("JOB-2")
    // Observed -> collecting, and the same wake asks for the next step: with
    // no evaluator the handler stops honestly instead of judging evidence.
    let blocked = try await first.reconcile(task.htaskID)
    XCTAssertEqual(blocked.action, .stoppedForHuman)
    XCTAssertEqual(blocked.reasonCode, "evaluationEngineUnavailable")

    let before = try await first.events(task.htaskID)
    let beforeSnapshot = try await first.status(task.htaskID)
    let logURL = rootURL.appendingPathComponent("tasks/\(task.htaskID)/events.jsonl")
    let logBytes = try XCTUnwrap(FileManager.default.contents(atPath: logURL.path))

    // Restart: new store, new coordinator, same directory.
    let (second, store) = try makeCoordinator(port: port)
    let after = try await second.events(task.htaskID)
    XCTAssertEqual(before, after)
    let afterSnapshot = try await second.status(task.htaskID)
    XCTAssertEqual(afterSnapshot, beforeSnapshot)
    let afterResult = try await second.result(task.htaskID)
    XCTAssertEqual(afterResult?.reasonCode, "evaluationEngineUnavailable")
    XCTAssertEqual(
      FileManager.default.contents(atPath: logURL.path), logBytes,
      "reading a task must not rewrite its log")

    // The snapshot is a cache of the log: roll task.json back to the first
    // version and the replay must reproduce the same observable state.
    let snapshotURL = rootURL.appendingPathComponent("tasks/\(task.htaskID)/task.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(task).write(to: snapshotURL)
    let replayed = try await store.load(task.htaskID)
    XCTAssertEqual(replayed, beforeSnapshot)
  }

  // MARK: - Bounded stops and cancel

  func testRoundBudgetExhaustionStopsTheTask() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission(maxRounds: 1))
    _ = try await coordinator.reconcile(task.htaskID)
    port.finish("JOB-1")

    // The wake that observes the finished job also decides what is next, and
    // the round budget is already spent, so this is where it stops.
    let stopped = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(stopped.action, .stoppedBudgetExhausted)
    XCTAssertEqual(stopped.reasonCode, "maxRoundsExhausted")
    XCTAssertEqual(stopped.snapshot.status, .failed)
    XCTAssertEqual(port.submittedRequests.count, 1)
    XCTAssertEqual(stopped.snapshot.result?.reasonCode, "maxRoundsExhausted")
  }

  func testCancelWithAnActiveJobCompletesOnlyAfterTheJobIsTerminal() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)

    let marked = try await coordinator.cancel(task.htaskID)
    XCTAssertEqual(marked.status, .waiting, "a cancel cannot claim an in-flight effect stopped")
    XCTAssertEqual(marked.waitReason, .activeJob)
    XCTAssertTrue(marked.cancelRequested)
    XCTAssertEqual(port.cancelRequests, ["JOB-1"])
    let whileCancelling = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(whileCancelling.action, .waitedForActiveJob)

    port.finish("JOB-1", state: "cancelled")
    let finished = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(finished.action, .cancelled)
    XCTAssertEqual(finished.snapshot.status, .cancelled)
    XCTAssertEqual(port.submittedRequests.count, 1)
  }

  func testPauseStopsNewWorkAndResumeNeedsATypedResolution() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)  // observe.device dispatched
    port.finish("JOB-1")
    // This wake observes the finished job and dispatches the capture in the
    // same boundary: still one effectful dispatch per wake.
    _ = try await coordinator.reconcile(task.htaskID)
    let submittedBeforePause = port.submittedRequests.count
    XCTAssertEqual(submittedBeforePause, 2)

    let paused = try await coordinator.pause(task.htaskID)
    XCTAssertEqual(paused.status, .waiting)
    XCTAssertEqual(paused.waitReason, .userSuspended)
    XCTAssertEqual(
      paused.activeJobID, "JOB-2",
      "pausing stops new work; it does not abandon the job the engine already owns")
    let pausedWake = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(pausedWake.action, .paused)
    XCTAssertEqual(
      port.submittedRequests.count, submittedBeforePause,
      "a paused task must not start anything new")

    do {
      _ = try await coordinator.resume(task.htaskID, resolution: "   ")
      XCTFail("an empty resolution must be refused")
    } catch {
      XCTAssertEqual(error as? HarnessCoordinatorError, .emptyResolution)
    }
    let resumed = try await coordinator.resume(task.htaskID, resolution: "operator resumed")
    XCTAssertEqual(resumed.status, .waiting)
    XCTAssertEqual(resumed.waitReason, .activeJob)
    XCTAssertEqual(resumed.activeJobID, "JOB-2")

    port.finish("JOB-2")
    let afterResume = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(afterResume.action, .stoppedForHuman)
    XCTAssertEqual(afterResume.reasonCode, "evaluationEngineUnavailable")
  }

  func testFailedOperationStopsWithTheRealReason() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)
    port.finish("JOB-1", state: "failed")

    let stopped = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(stopped.action, .stoppedJobFailed)
    XCTAssertEqual(stopped.reasonCode, "operationFailed:observe.device@1:failed")
    XCTAssertEqual(stopped.snapshot.status, .failed)
    XCTAssertEqual(port.submittedRequests.count, 1, "a failed operation is not retried blindly")
  }

  // MARK: - Typed request surface

  func testSubmittedRequestsCarryCorrelationOnlyAndNoRawSurface() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let task = try await coordinator.submit(submission())
    _ = try await coordinator.reconcile(task.htaskID)

    let request = try XCTUnwrap(port.submittedRequests.first)
    XCTAssertEqual(request.operationReference, "observe.device@1")
    XCTAssertEqual(request.targetID, "TGT-958780b2ffb7")
    XCTAssertEqual(request.provenance["harnessTaskId"], task.htaskID)
    XCTAssertEqual(request.provenance["harnessRound"], "1")
    XCTAssertFalse(
      request.hasAuthorization, "an E0-only task type must not carry a capability reference")
    for forbidden in [
      "changeId", "taskId", "approvalPR", "mainCommitOID", "executable", "argv", "shell",
      "hdc", "/data/local/tmp",
    ] {
      XCTAssertFalse(
        request.rawJSON.contains(forbidden),
        "the harness request surface must not carry \(forbidden)")
    }
  }

  func testSubmissionValidationRejectsOutOfPolicyAndUnboundedInput() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)

    do {
      _ = try await coordinator.submit(submission(allowedOperations: ["flash.dayu200@1"]))
      XCTFail("an operation outside the task type's closed set must be refused")
    } catch {
      XCTAssertEqual(
        error as? HarnessTaskSubmissionError,
        .operationNotPermittedForType("flash.dayu200@1"))
    }
    do {
      _ = try await coordinator.submit(submission(maxRounds: 0))
      XCTFail("a zero round budget must be refused")
    } catch {
      XCTAssertEqual(
        error as? HarnessTaskSubmissionError, .budgetOutOfRange("maxRounds"))
    }
    do {
      _ = try await coordinator.submit(
        HarnessTaskSubmission(
          type: .debugCrash,
          target: HarnessTaskTargetReference(targetID: "../../etc/passwd"),
          goal: HarnessTaskGoal(summary: "goal"),
          budgets: HarnessTaskBudgets(
            maxRounds: 2, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
          policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash)))
      XCTFail("a path-shaped target id must be refused")
    } catch {
      XCTAssertEqual(error as? HarnessTaskSubmissionError, .malformedTargetID)
    }
  }

  func testStoreRefusesTaskIdentifiersThatAreNotItsOwnGrammar() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    for candidate in ["../escape", "HTASK-../x", "htask-lowercase", "HTASK-ZZZZ", "HTASK-"] {
      do {
        _ = try await store.load(candidate)
        XCTFail("\(candidate) must not resolve to a task directory")
      } catch let error as HarnessTaskStoreError {
        XCTAssertEqual(error, .malformedTaskID(candidate))
      }
    }
  }

  // MARK: - Daemon surface

  func testTaskMethodsAreServedByTheControlPlane() async throws {
    let port = RecordingJobPort()
    let (coordinator, store) = try makeCoordinator(port: port)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: rootURL.appendingPathComponent("capabilities", isDirectory: true))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: rootURL.appendingPathComponent("engine", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: NeverDispatchingPort(reason: "tests never dispatch through the engine here"),
      capabilityStore: capabilityStore,
      artifactStore: nil,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore, providerIDs: [],
      nowUTC: { "2026-07-30T00:00:00Z" }, harnessCoordinator: coordinator)

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
      let request = AgentWireProtocol.Request(id: "1", method: method, params: params)
      let response = await handler.handleFrame(try JSONEncoder().encode(request))
      XCTAssertTrue(response.ok, "\(method) failed: \(response.error?.message ?? "-")")
      return try XCTUnwrap(response.result)
    }
    func field(_ value: JSONValue, _ key: String) -> JSONValue? {
      guard case .object(let fields) = value else { return nil }
      return fields[key]
    }

    let submitted = try await call(
      "task.submit",
      [
        "targetId": .string("TGT-958780b2ffb7"),
        "goal": .string("No SIGABRT in WaterFlow::RecoverBack across five runs."),
        "projectRef": .string("demo-app"),
        "crashSignature": .string("SIGABRT+WaterFlowCrashProbe_RecoverBack"),
        "bundleName": .string("com.example.waterflowdemo"),
        "abilityName": .string("EntryAbility"),
        "processName": .string("com.example.waterflowdemo:entry"),
        "baselineHapArtifactLease": .string("lease-v1:input-hap:ART-crash-fixture"),
        "buildPresetRef": .string("waterflow-debug"),
        "testPresetRef": .string("waterflow-tests"),
        "deviceProfile": .string("dayu200@1"),
        "baseWorkspaceRevision": .string(String(repeating: "c", count: 64)),
        "component": .string("WaterFlow.RecoverBack"),
        "maxRounds": .integer(3),
        "maxE1Mutations": .integer(3),
        "maxModelCalls": .integer(4),
      ])
    let taskID = try XCTUnwrap({ () -> String? in
      if case .string(let value)? = field(submitted, "htaskId") { return value }
      return nil
    }())
    XCTAssertEqual(field(submitted, "status"), .string("created"))
    XCTAssertEqual(field(submitted, "lifecycle"), .string("created"))
    XCTAssertEqual(field(submitted, "stage"), .string("initializing"))
    XCTAssertEqual(field(submitted, "waitReason"), .null)
    if case .array(let conditions)? = field(submitted, "conditions") {
      XCTAssertEqual(conditions.count, HarnessTaskConditionName.allCases.count)
    } else {
      XCTFail("task.submit must expose the complete condition set")
    }
    XCTAssertEqual(field(submitted, "projectRef"), .string("demo-app"))
    XCTAssertEqual(
      field(submitted, "desiredState"),
      .object([
        "crashSignature": .string("SIGABRT+WaterFlowCrashProbe_RecoverBack"),
        "bundleName": .string("com.example.waterflowdemo"),
        "abilityName": .string("EntryAbility"),
        "processName": .string("com.example.waterflowdemo:entry"),
        "baselineHapArtifactLease": .string("lease-v1:input-hap:ART-crash-fixture"),
        "buildPresetRef": .string("waterflow-debug"),
        "testPresetRef": .string("waterflow-tests"),
        "deviceProfile": .string("dayu200@1"),
        "baseWorkspaceRevision": .string(String(repeating: "c", count: 64)),
        "component": .string("WaterFlow.RecoverBack"),
      ]))
    guard case .object(let submittedBudgets)? = field(submitted, "budgets") else {
      return XCTFail("task.submit must echo the admitted budgets")
    }
    XCTAssertEqual(submittedBudgets["maxE1Mutations"], .integer(3))
    XCTAssertEqual(submittedBudgets["maxModelCalls"], .integer(4))
    XCTAssertEqual(
      field(submitted, "allowedOperations"),
      .array([
        .string("analyzer.extract-crash-signature@1"),
        .string("capture.diagnostics@1"), .string("debug.hap@1"),
        .string("observe.device@1"), .string("workspace.apply-patch@1"),
        .string("workspace.build-openharmony@1"), .string("workspace.revert-patch@1"),
        .string("workspace.run-tests@1"),
      ]))

    let reconciled = try await call("task.reconcile", ["htaskId": .string(taskID)])
    XCTAssertEqual(field(reconciled, "action"), .string("dispatched"))
    XCTAssertEqual(field(reconciled, "dispatchedJobId"), .string("JOB-1"))
    let statusResult = try await call("task.status", ["htaskId": .string(taskID)])
    XCTAssertEqual(field(statusResult, "phase"), .string("initializing"))
    XCTAssertEqual(field(statusResult, "lifecycle"), .string("waiting"))
    XCTAssertEqual(field(statusResult, "stage"), .string("initializing"))
    XCTAssertEqual(field(statusResult, "waitReason"), .string("ACTIVE_JOB"))
    if case .array(let listed) = try await call("task.list") {
      XCTAssertEqual(listed.count, 1)
    } else {
      XCTFail("task.list must return an array")
    }
    if case .array(let events) = try await call("task.events", ["htaskId": .string(taskID)]) {
      XCTAssertEqual(events.count, 2)
    } else {
      XCTFail("task.events must return an array")
    }
    let storedAttempts = try await store.attempts(taskID)
    let attempt = try XCTUnwrap(storedAttempts.first)
    if case .array(let attempts) = try await call(
      "task.attempts", ["htaskId": .string(taskID)])
    {
      XCTAssertEqual(attempts.count, 1)
      guard case .object(let fields) = attempts[0] else {
        return XCTFail("task.attempts entries must be objects")
      }
      XCTAssertEqual(fields["attemptId"], .string(attempt.attemptID))
      XCTAssertEqual(fields["strategyFingerprint"], .string(attempt.strategyFingerprint))
    } else {
      XCTFail("task.attempts must return an array")
    }

    // A human block is only left through a recorded decision: the daemon
    // refuses a resume that carries none.
    let missingResolution = await handler.handleFrame(
      try JSONEncoder().encode(
        AgentWireProtocol.Request(
          id: "2", method: "task.resume", params: ["htaskId": .string(taskID)])))
    XCTAssertFalse(missingResolution.ok)
    XCTAssertEqual(missingResolution.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let unknown = await handler.handleFrame(
      try JSONEncoder().encode(
        AgentWireProtocol.Request(
          id: "3", method: "task.status", params: ["htaskId": .string("HTASK-000000000000")])))
    XCTAssertFalse(unknown.ok)
    XCTAssertEqual(unknown.error?.code, AgentDaemonErrorCode.notFound.rawValue)
  }

  func testTaskSubmitRejectsMalformedDeploymentInputsAndModelBudget() async throws {
    let port = RecordingJobPort()
    let (coordinator, _) = try makeCoordinator(port: port)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: rootURL.appendingPathComponent("wire-capabilities", isDirectory: true))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: rootURL.appendingPathComponent("wire-engine", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: NeverDispatchingPort(reason: "wire rejection must not dispatch"),
      capabilityStore: capabilityStore, artifactStore: nil,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore, providerIDs: [],
      nowUTC: { "2026-07-30T00:00:00Z" }, harnessCoordinator: coordinator)

    func submit(_ fields: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      await handler.handleFrame(
        try JSONEncoder().encode(
          AgentWireProtocol.Request(id: UUID().uuidString, method: "task.submit", params: fields)))
    }
    let base: [String: JSONValue] = [
      "targetId": .string("TGT-958780b2ffb7"), "goal": .string("repair crash")
    ]
    let missingBundle = try await submit(
      base.merging(["abilityName": .string("EntryAbility")]) { _, new in new })
    XCTAssertFalse(missingBundle.ok)
    XCTAssertEqual(missingBundle.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let processWithoutBundle = try await submit(
      base.merging(["processName": .string("com.example.demo")]) { _, new in new })
    XCTAssertFalse(processWithoutBundle.ok)
    XCTAssertEqual(
      processWithoutBundle.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let commandShapedProcess = try await submit(
      base.merging([
        "bundleName": .string("com.example.demo"),
        "processName": .string("1;pidof.other"),
      ]) { _, new in new })
    XCTAssertFalse(commandShapedProcess.ok)
    XCTAssertEqual(
      commandShapedProcess.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let malformedBaselineLease = try await submit(
      base.merging([
        "bundleName": .string("com.example.demo"),
        "abilityName": .string("EntryAbility"),
        "baselineHapArtifactLease": .string("lease-v1:missing-artifact"),
      ]) { _, new in new })
    XCTAssertFalse(malformedBaselineLease.ok)
    XCTAssertEqual(
      malformedBaselineLease.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let baselineWithoutComponent = try await submit(
      base.merging([
        "baselineHapArtifactLease": .string("lease-v1:input:ART-fixture")
      ]) { _, new in new })
    XCTAssertFalse(baselineWithoutComponent.ok)
    XCTAssertEqual(
      baselineWithoutComponent.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let unboundedModel = try await submit(
      base.merging(["maxModelCalls": .integer(129)]) { _, new in new })
    XCTAssertFalse(unboundedModel.ok)
    XCTAssertEqual(unboundedModel.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)

    let malformedMemoryRevision = try await submit(
      base.merging(["baseWorkspaceRevision": .string("main")]) { _, new in new })
    XCTAssertFalse(malformedMemoryRevision.ok)
    XCTAssertEqual(
      malformedMemoryRevision.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)
  }

  func testTaskMethodsFailClosedWhenTheHarnessIsNotConfigured() async throws {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: rootURL.appendingPathComponent("capabilities-2", isDirectory: true))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: rootURL.appendingPathComponent("engine-2", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: NeverDispatchingPort(reason: "no dispatch in this composition"),
      capabilityStore: capabilityStore,
      artifactStore: nil,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore, providerIDs: [],
      nowUTC: { "2026-07-30T00:00:00Z" })

    let response = await handler.handleFrame(
      try JSONEncoder().encode(AgentWireProtocol.Request(id: "1", method: "task.list")))
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.error?.code, AgentDaemonErrorCode.rejected.rawValue)
  }
}
