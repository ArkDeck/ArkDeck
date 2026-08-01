// Bounded-execution contract tests (CHG-2026-054, TASK-HTP-003).
//
// Registered acceptance: HTP-AC-8 (a budget is a stop), HTP-AC-9 (failure
// fingerprints and no-progress convergence), HTP-AC-10 (outcomeUnknown stops
// with a structured HumanActionRequired and resumes only on a typed
// resolution), HTP-AC-11 (E2 is never automated, E1 only with an existing
// capability, and nothing is authorized for an unavailable plan).

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private func digestHex(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// An empty Faultlogger ledger in the device's own words: the tool answered
/// and there is nothing, which is the only shape that may support a verdict
/// of "no crash" (CHG-2026-055, TASK-HFA-001).
private let emptyLedgerBytes = """
  Fault log list:
  ******
  ******
  """

private final class StubAvailabilityPort: HarnessOperationAvailabilityPort, @unchecked Sendable {
  private let lock = NSLock()
  private var unavailable: [String: String]
  private var asked: [String] = []

  init(unavailable: [String: String] = [:]) {
    self.unavailable = unavailable
  }

  var askedReferences: [String] { lock.withLock { asked } }

  func availability(of reference: String) async -> (available: Bool, reason: String) {
    lock.withLock {
      asked.append(reference)
      if let reason = unavailable[reference] { return (false, reason) }
      return (true, "available")
    }
  }
}

private final class StubCapabilityPort: HarnessCapabilityPort, @unchecked Sendable {
  private let lock = NSLock()
  private var held: Set<String>
  private var asked: [String] = []

  init(held: Set<String> = []) {
    self.held = held
  }

  var askedReferences: [String] { lock.withLock { asked } }

  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    lock.withLock {
      asked.append(operationReference)
      return held.contains(operationReference)
    }
  }
}

private final class BoundsJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: HarnessJobObservation] = [:]
  private var submissions: [String] = []
  private var nextOrdinal = 1
  var rejectionMessage: String?

  var submittedOperations: [String] { lock.withLock { submissions } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    return try lock.withLock {
      submissions.append(request.operation.reference)
      if let rejectionMessage {
        throw HarnessJobPortError.rejected(rejectionMessage)
      }
      let jobID = "JOB-\(nextOrdinal)"
      nextOrdinal += 1
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: "running", isTerminal: false, succeeded: false,
        outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
      return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
    }
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    try lock.withLock {
      guard let observation = observations[jobID] else {
        throw HarnessJobPortError.unknownJob(jobID)
      }
      return observation
    }
  }

  func requestCancel(jobID: String) async throws {}

  func finish(_ jobID: String, state: String = "succeeded", outcomeUnknown: Bool = false) {
    lock.withLock {
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
        outcomeUnknown: outcomeUnknown, waitingForHuman: false,
        timeline: ["queued", "running", state])
    }
  }
}

private final class BoundsArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private let lock = NSLock()
  private var staged: [String: [(HarnessArtifactDescriptor, Data)]] = [:]

  func stage(jobID: String, name: String, text: String, sha256Override: String? = nil) {
    let data = Data(text.utf8)
    let descriptor = HarnessArtifactDescriptor(
      artifactID: "ART-\(jobID)-\(name)", name: name, mediaType: "text/plain",
      byteCount: data.count,
      sha256: sha256Override
        ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      published: true, sensitive: false)
    lock.withLock { staged[jobID, default: []].append((descriptor, data)) }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    lock.withLock { (staged[jobID] ?? []).map(\.0) }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      guard let match = (staged[jobID] ?? []).first(where: { $0.0.artifactID == artifactID })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return match.1.prefix(maximumBytes)
    }
  }
}

final class HarnessBoundsContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-bounds-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - Fixtures

  private func snapshot(
    phase: HarnessTaskPhase = .reproducing,
    allowed: [String] = [
      DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics,
    ],
    budgets: HarnessTaskBudgets = HarnessTaskBudgets(
      maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 0),
    consumed: HarnessConsumedBudget = HarnessConsumedBudget(),
    noProgressRounds: Int = 0,
    activeJobID: String? = nil
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app", target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "goal"), successCriteria: [], budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: allowed),
      createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z",
      status: .running, phase: phase, activeRound: 1, activeJobID: activeJobID,
      consumedBudget: consumed, noProgressRounds: noProgressRounds)
  }

  private func guardInput(
    _ snapshot: HarnessTaskSnapshot,
    operation: String = DebugCrashTaskHandler.captureDiagnostics,
    inputs: [String: JSONValue] = [:],
    inputsDigest: String = digestHex("{}"),
    permitted: Set<String> = [
      DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics,
      "debug.hap@1", "flash.dayu200@1",
    ],
    failure: HarnessFailureRecord? = nil,
    previousStrategy: HarnessStrategySignature? = nil,
    noProgress: Int = 0,
    elapsed: Int? = 10
  ) -> HarnessGuardInput {
    HarnessGuardInput(
      snapshot: snapshot, operationReference: operation, inputs: inputs,
      inputsDigest: inputsDigest, permittedOperations: permitted, failureRecord: failure,
      previousStrategy: previousStrategy, consecutiveNoProgressRounds: noProgress,
      elapsedSeconds: elapsed)
  }

  private func failureRecord(occurrences: Int) -> HarnessFailureRecord {
    HarnessFailureRecord(
      fingerprint: HarnessFailureFingerprint(
        operationReference: DebugCrashTaskHandler.captureDiagnostics, phase: .reproducing,
        providerID: "hdc", targetProfile: "TGT-1", normalizedInputsSHA256: digestHex("{}"),
        errorClassification: "operationFailed", semanticErrorCode: "failed"),
      occurrences: occurrences, firstSeenUTC: "2026-07-31T00:00:00Z",
      lastSeenUTC: "2026-07-31T00:00:10Z", lastReasonCode: "operationFailed",
      observedByTasks: ["HTASK-0123456789AB"])
  }

  private func makeStack(
    jobs: BoundsJobPort,
    artifacts: BoundsArtifactPort? = nil,
    clock: @escaping @Sendable () -> String = { "2026-07-31T00:00:00Z" },
    budgets: HarnessTaskBudgets = HarnessTaskBudgets(
      maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 0),
    criteria: [HarnessSuccessCriterion] = [],
    desiredState: [String: JSONValue] = [:]
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, artifactPort: artifacts, nowUTC: clock)
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "No WaterFlow SIGABRT", desiredState: desiredState),
      successCriteria: criteria,
      budgets: budgets,
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, store, submission)
  }

  // MARK: - HTP-AC-8: budgets are stops

  func testEveryBudgetKindStopsTheTask() {
    let base = snapshot()
    XCTAssertNil(HarnessPolicyGuard.budgetRefusal(base, elapsedSeconds: 10))

    let rounds = snapshot(consumed: HarnessConsumedBudget(rounds: 8))
    XCTAssertEqual(
      HarnessPolicyGuard.budgetRefusal(rounds, elapsedSeconds: 10), .budgetExhausted(.rounds))

    XCTAssertEqual(
      HarnessPolicyGuard.budgetRefusal(base, elapsedSeconds: 901), .budgetExhausted(.wallClock))

    let bytes = snapshot(consumed: HarnessConsumedBudget(artifactBytes: 1 << 20))
    XCTAssertEqual(
      HarnessPolicyGuard.budgetRefusal(bytes, elapsedSeconds: 10),
      .budgetExhausted(.artifactBytes))

    let mutations = snapshot(
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 2),
      consumed: HarnessConsumedBudget(e1Mutations: 2))
    XCTAssertEqual(
      HarnessPolicyGuard.budgetRefusal(mutations, elapsedSeconds: 10),
      .budgetExhausted(.e1Mutations))

    for kind in HarnessBudgetKind.allCases {
      XCTAssertFalse(kind.reasonCode.isEmpty, "every budget kind needs a machine-readable stop")
    }
  }

  func testWallClockExhaustionStopsBeforeDispatchingAnything() async throws {
    let jobs = BoundsJobPort()
    // The clock jumps past the wall-clock budget between the submit and the
    // first wake, which is exactly the case a rounds-only check would miss.
    let times = ["2026-07-31T00:00:00Z", "2026-07-31T02:00:00Z"]
    let index = Counter()
    let (coordinator, _, submission) = try makeStack(
      jobs: jobs,
      clock: { times[min(index.next(), times.count - 1)] },
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 60, maxArtifactBytes: 1 << 20, maxE1Mutations: 0))
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .stoppedBudgetExhausted)
    XCTAssertEqual(outcome.reasonCode, "maxWallClockExhausted")
    XCTAssertEqual(outcome.snapshot.status, .failed)
    XCTAssertEqual(jobs.submittedOperations, [], "an exhausted budget dispatches nothing")
  }

  func testArtifactBytesAreChargedOncePerVerifiedArtifact() async throws {
    let jobs = BoundsJobPort()
    let artifacts = BoundsArtifactPort()
    let payload =
      #"{"documentType":"arkdeck-application-liveness","schemaVersion":"1.0.0","applicationRef":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"HEALTHY","reasonCode":"targetProcessRunning","abilityState":"UNKNOWN","processState":"RUNNING","pidObserved":true,"sourceRuntimeJobId":"JOB-2","sourceOperationRef":"capture.diagnostics@1","observationWindow":{"startedAtUtc":"2026-07-31T00:00:00Z","endedAtUtc":"2026-07-31T00:00:00Z"},"observedAtUtc":"2026-07-31T00:00:00Z"}"#
    let byteBudget = payload.utf8.count
    let (coordinator, _, submission) = try makeStack(
      jobs: jobs, artifacts: artifacts,
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: byteBudget,
        maxE1Mutations: 0),
      criteria: [
        HarnessSuccessCriterion(
          criterionID: "B-1", metric: "applicationLiveness", comparator: .equalTo,
          expected: .string("healthy"), minimumSamples: 3,
          evidenceRequirements: ["application-liveness.json"])
      ])
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    artifacts.stage(jobID: "JOB-2", name: "application-liveness.json", text: payload)
    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-2")

    // One wake charges the verified bytes and then hits the budget check on
    // the way to planning the next capture: three samples were required, the
    // first one already spent the byte budget, so the loop stops there.
    let charged = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(charged.snapshot.consumedBudget.artifactBytes, byteBudget)
    XCTAssertEqual(charged.action, .stoppedBudgetExhausted)
    XCTAssertEqual(charged.reasonCode, "maxArtifactBytesExhausted")
    XCTAssertEqual(charged.snapshot.status, .failed)
    XCTAssertEqual(
      charged.snapshot.observed.samples["applicationLiveness"], 1,
      "the sample it did collect is still on the record")
    XCTAssertEqual(jobs.submittedOperations.count, 2, "no capture is dispatched after the stop")
  }

  // MARK: - HTP-AC-9: fingerprints and progress

  func testSecondIdenticalStrategyIsRefusedAndThirdIsProhibited() async {
    let policyGuard = HarnessPolicyGuard()
    let strategy = HarnessStrategySignature(
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputsDigest: digestHex("{}"), phase: .reproducing)

    // First occurrence: the same strategy may be tried again.
    let first = await policyGuard.evaluate(
      guardInput(snapshot(), failure: failureRecord(occurrences: 1), previousStrategy: strategy))
    XCTAssertEqual(first, .allow)

    // Second: an identical decision is refused.
    let second = await policyGuard.evaluate(
      guardInput(snapshot(), failure: failureRecord(occurrences: 2), previousStrategy: strategy))
    XCTAssertEqual(
      second,
      .refuse(
        .repeatedFailureNeedsNewStrategy(
          digest: failureRecord(occurrences: 2).digest, occurrences: 2)))

    // Second, but with different typed inputs: that is a new strategy.
    let changed = await policyGuard.evaluate(
      guardInput(
        snapshot(), inputs: ["durationSeconds": .integer(15)],
        inputsDigest: digestHex("{\"durationSeconds\":15}"),
        failure: failureRecord(occurrences: 2), previousStrategy: strategy))
    XCTAssertEqual(changed, .allow, "changing typed inputs is a new strategy")

    // Third: no variation is accepted at all.
    let third = await policyGuard.evaluate(
      guardInput(
        snapshot(), inputs: ["durationSeconds": .integer(15)],
        inputsDigest: digestHex("{\"durationSeconds\":15}"),
        failure: failureRecord(occurrences: 3), previousStrategy: strategy))
    XCTAssertEqual(
      third,
      .refuse(
        .repeatedFailureProhibited(
          digest: failureRecord(occurrences: 3).digest, occurrences: 3)))
  }

  func testStanceTableMatchesTheThreeStrikeRule() {
    XCTAssertEqual(HarnessRetryStance.stance(forOccurrences: 1), .allowSameStrategy)
    XCTAssertEqual(HarnessRetryStance.stance(forOccurrences: 2), .requireNewStrategy)
    XCTAssertEqual(HarnessRetryStance.stance(forOccurrences: 3), .prohibited)
    XCTAssertEqual(HarnessRetryStance.stance(forOccurrences: 9), .prohibited)
  }

  func testFailureMemoryIsCrossTaskAndDrivesTheThirdStrikeStop() async throws {
    let jobs = BoundsJobPort()
    let (coordinator, store, submission) = try makeStack(jobs: jobs)

    // Three tasks, each hitting the same capture failure: the record follows
    // the fingerprint, not the task.
    var digest = ""
    for attempt in 1...3 {
      let task = try await coordinator.submit(submission)
      _ = try await coordinator.reconcile(task.htaskID)  // observe.device
      jobs.finish("JOB-\((attempt - 1) * 2 + 1)")
      _ = try await coordinator.reconcile(task.htaskID)  // capture dispatched
      jobs.finish("JOB-\((attempt - 1) * 2 + 2)", state: "failed")
      let outcome = try await coordinator.reconcile(task.htaskID)

      let records = try await store.memory(scope: .task, key: task.htaskID)
      XCTAssertTrue(
        records.contains { $0.kind == .attempt && $0.summary.contains("FAIL-") },
        "a failed attempt is recorded in task memory with its fingerprint")

      if attempt < 3 {
        XCTAssertEqual(outcome.action, .stoppedJobFailed)
        XCTAssertEqual(outcome.snapshot.status, .failed)
      } else {
        // Third occurrence of the same fingerprint: the loop stops for a
        // human instead of letting another task try it again.
        XCTAssertEqual(outcome.action, .stoppedForHuman)
        XCTAssertEqual(outcome.snapshot.status, .humanRequired)
        XCTAssertTrue(outcome.reasonCode.hasPrefix("repeatedFailureProhibited:"))
        let actions = try await coordinator.humanActions(task.htaskID)
        XCTAssertEqual(actions.last?.block, .strategyExhausted)
        XCTAssertNil(
          actions.last?.document,
          "no closed category describes an exhausted strategy, so no document is invented")
      }
      digest = try XCTUnwrap(
        outcome.snapshot.result?.reasonCode.split(separator: ":").dropFirst().first.map(String.init)
          ?? outcome.reasonCode.split(separator: ":").dropFirst().first.map(String.init))
    }

    let loaded = try await store.failureRecord(digest: digest)
    let record = try XCTUnwrap(loaded)
    XCTAssertEqual(record.occurrences, 3)
    XCTAssertEqual(record.observedByTasks.count, 3, "one record, three tasks")
    XCTAssertEqual(record.stance, .prohibited)
  }

  func testNoProgressRoundsAccumulateAndStopTheLoop() async throws {
    let jobs = BoundsJobPort()
    let artifacts = BoundsArtifactPort()
    // The capture publishes nothing, so every round is evidence-free: no new
    // samples, no verdict change, no phase move.
    let (coordinator, _, submission) = try makeStack(
      jobs: jobs, artifacts: artifacts,
      criteria: [
        HarnessSuccessCriterion(
          criterionID: "B-1", metric: "matchingCrashCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 2, evidenceRequirements: ["hilog.txt"])
      ])
    let task = try await coordinator.submit(submission)

    var lastOutcome: HarnessReconcileOutcome?
    for round in 1...6 {
      let outcome = try await coordinator.reconcile(task.htaskID)
      lastOutcome = outcome
      if ![HarnessTaskLifecycle.running, .waiting, .created].contains(
        outcome.snapshot.lifecycle)
      { break }
      jobs.finish("JOB-\(round)")
    }
    let outcome = try XCTUnwrap(lastOutcome)
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
    XCTAssertTrue(
      outcome.reasonCode.hasPrefix("noProgressRounds:"),
      "expected a no-progress stop, got \(outcome.reasonCode)")
    XCTAssertGreaterThanOrEqual(outcome.snapshot.noProgressRounds, 2)

    // The counter is durable: a fresh coordinator reads the same patience.
    let store = try HarnessTaskStore(rootURL: rootURL)
    let reread = try await store.load(task.htaskID)
    XCTAssertEqual(reread.noProgressRounds, outcome.snapshot.noProgressRounds)
  }

  func testProgressVectorIgnoresProseAndCountsEvidence() {
    let before = snapshot()
    let unchanged = HarnessTaskCoordinator.progress(
      before: before, after: before, newFailures: 0)
    XCTAssertFalse(unchanged.isProgress, "the same state twice is not progress")

    let afterEvidence = before.applying(
      HarnessTaskProjection(
        status: .running, phase: before.phase, activeRound: 2, activeJobID: nil,
        consumedBudget: before.consumedBudget, artifactRefs: ["ART-1"],
        observedState: HarnessObservedState(samples: ["matchingCrashCount": 1]).asJSON,
        latestEvaluationID: "EVAL-000000000001", noProgressRounds: 0, cancelRequested: false,
        result: nil, version: before.version + 1),
      atUTC: "2026-07-31T00:01:00Z")
    let progressed = HarnessTaskCoordinator.progress(
      before: before, after: afterEvidence, newFailures: 0)
    XCTAssertTrue(progressed.isProgress)
    XCTAssertEqual(progressed.newVerifiedEvidenceCount, 1)
    XCTAssertEqual(progressed.sampleDelta, 1)
  }

  // MARK: - HTP-AC-10: outcomeUnknown

  func testOutcomeUnknownProducesATypedHumanActionAndResumesOnlyOnAResolution() async throws {
    let jobs = BoundsJobPort()
    let (coordinator, _, submission) = try makeStack(jobs: jobs)
    let task = try await coordinator.submit(submission)
    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1", state: "waitingForRecovery", outcomeUnknown: true)

    let blocked = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(blocked.action, .stoppedForHuman)
    XCTAssertEqual(blocked.snapshot.status, .humanRequired)
    XCTAssertNil(blocked.snapshot.activeJobID)

    let actions = try await coordinator.humanActions(task.htaskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .outcomeUnknown)
    XCTAssertEqual(action.jobID, "JOB-1")
    XCTAssertEqual(action.resumePhase, blocked.snapshot.phase)
    XCTAssertTrue(action.isOpen)

    // The typed document is the existing closed model, filled by the model's
    // own mapping rather than by the harness.
    let document = try HarnessHumanActionFactory.decode(try XCTUnwrap(action.document))
    XCTAssertEqual(document.category, .outcomeUnknownDecision)
    XCTAssertEqual(document.reasonCode, "recovery.outcomeUnknown")
    XCTAssertEqual(document.minimumActionKey, "human.reconcileOrAbandon")
    XCTAssertEqual(document.prohibitedAutomation, [.outcomeGuess])
    XCTAssertEqual(document.resumeProbeOperationID, .reconcileOutcome)
    XCTAssertEqual(document.status, .waiting)
    XCTAssertEqual(document.jobID, "JOB-1")

    // No automatic escape, and no re-sent side effect.
    let idle = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(idle.action, .awaitingHuman)
    XCTAssertEqual(jobs.submittedOperations.count, 1)

    do {
      _ = try await coordinator.resume(task.htaskID, resolution: "  ")
      XCTFail("an empty resolution must be refused")
    } catch {
      XCTAssertEqual(error as? HarnessCoordinatorError, .emptyResolution)
    }

    let resumed = try await coordinator.resume(
      task.htaskID, resolution: "operator reconciled the job by hand and abandoned it")
    XCTAssertEqual(resumed.status, .running)
    XCTAssertEqual(resumed.phase, blocked.snapshot.phase, "a resolution does not rewind the phase")
    XCTAssertEqual(resumed.noProgressRounds, 0)

    let reopened = try await coordinator.humanActions(task.htaskID)
    let closed = try XCTUnwrap(reopened.last)
    XCTAssertFalse(closed.isOpen)
    XCTAssertEqual(closed.resolution, "operator reconciled the job by hand and abandoned it")
    let resolvedDocument = try HarnessHumanActionFactory.decode(try XCTUnwrap(closed.document))
    XCTAssertEqual(
      resolvedDocument.status, .resolvedByFreshProbe,
      "the document's own state machine performed the transition")
  }

  func testResolvingAnAlreadyResolvedBlockIsRefused() throws {
    let stored = HarnessHumanActionFactory.make(
      actionID: "har-000000000001", snapshot: snapshot(), block: .outcomeUnknown,
      reasonCode: "outcomeUnknown:capture.diagnostics@1", round: 1, jobID: "JOB-1",
      requestID: nil, evidenceRefs: [], nowUTC: "2026-07-31T00:00:00Z")
    let resolved = try HarnessHumanActionFactory.resolve(
      stored, resolution: "done", probeReceiptID: "har-000000000001-resolution",
      nowUTC: "2026-07-31T00:01:00Z")
    XCTAssertFalse(resolved.isOpen)
    XCTAssertThrowsError(
      try HarnessHumanActionFactory.resolve(
        resolved, resolution: "again", probeReceiptID: "har-000000000001-resolution",
        nowUTC: "2026-07-31T00:02:00Z")
    ) { error in
      XCTAssertEqual(error as? HumanActionRequiredError, .invalidTransition)
    }
  }

  // MARK: - HTP-AC-11: E2 never, E1 only with an existing capability

  func testDestructiveOperationsAreNeverAutomated() async {
    let capabilities = StubCapabilityPort(held: ["flash.dayu200@1"])
    let policyGuard = HarnessPolicyGuard(
      availability: StubAvailabilityPort(), capabilities: capabilities)
    let generous = snapshot(
      allowed: ["flash.dayu200@1"],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 8))

    let verdict = await policyGuard.evaluate(
      guardInput(generous, operation: "flash.dayu200@1"))
    XCTAssertEqual(
      verdict, .refuse(.destructiveEffectNeverAutomated(reference: "flash.dayu200@1")),
      "a budget and a capability do not make E2 automatable")
    XCTAssertFalse(
      HarnessTaskCoordinator.defaultPolicy(for: .debugCrash).allowedOperations.contains(
        "flash.dayu200@1"))
  }

  func testDeviceMutationNeedsBudgetAndAnExistingCapability() async {
    let availability = StubAvailabilityPort()
    let withoutCapability = HarnessPolicyGuard(
      availability: availability, capabilities: StubCapabilityPort())
    let e1Allowed = snapshot(
      allowed: ["debug.hap@1"],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 2))

    // No budget for mutations at all.
    let noBudget = await withoutCapability.evaluate(
      guardInput(snapshot(allowed: ["debug.hap@1"]), operation: "debug.hap@1"))
    XCTAssertEqual(
      noBudget,
      .refuse(.authorizationRequired(reference: "debug.hap@1", effect: "deviceMutation")))

    // Budget, but no capability the maintainer issued.
    let noCapability = await withoutCapability.evaluate(
      guardInput(e1Allowed, operation: "debug.hap@1"))
    XCTAssertEqual(
      noCapability,
      .refuse(.authorizationRequired(reference: "debug.hap@1", effect: "deviceMutation")))

    // Budget and an existing capability: the guard steps aside and lets the
    // engine's admission be the authority.
    let held = HarnessPolicyGuard(
      availability: availability, capabilities: StubCapabilityPort(held: ["debug.hap@1"]))
    let allowed = await held.evaluate(guardInput(e1Allowed, operation: "debug.hap@1"))
    XCTAssertEqual(allowed, .allow)
  }

  func testAnUnavailableOperationIsRefusedBeforeAuthorizationIsConsulted() async {
    let capabilities = StubCapabilityPort(held: ["debug.hap@1"])
    let policyGuard = HarnessPolicyGuard(
      availability: StubAvailabilityPort(unavailable: ["debug.hap@1": "provider_not_registered"]),
      capabilities: capabilities)
    let e1Allowed = snapshot(
      allowed: ["debug.hap@1"],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 2))

    let verdict = await policyGuard.evaluate(guardInput(e1Allowed, operation: "debug.hap@1"))
    XCTAssertEqual(
      verdict,
      .refuse(
        .operationUnavailable(reference: "debug.hap@1", reason: "provider_not_registered")))
    XCTAssertEqual(
      capabilities.askedReferences, [],
      "capability must not even be consulted for an unavailable plan (PRODUCT-LOOP §8)")
  }

  func testReadOnlyCeilingOperationsAreLeftToTheEngine() async {
    // `capture.diagnostics@1` permits deviceMutation on its remote-trace path
    // but its floor is readOnly: refusing on the ceiling would make the
    // ordinary E0 capture unusable, so the guard passes it to the engine.
    let capabilities = StubCapabilityPort()
    let policyGuard = HarnessPolicyGuard(
      availability: StubAvailabilityPort(), capabilities: capabilities)
    let verdict = await policyGuard.evaluate(guardInput(snapshot()))
    XCTAssertEqual(verdict, .allow)
    XCTAssertEqual(capabilities.askedReferences, [])
  }

  func testRawCommandSurfaceIsRefusedInTypedInputs() async {
    let policyGuard = HarnessPolicyGuard(availability: StubAvailabilityPort())
    let argv = await policyGuard.evaluate(
      guardInput(snapshot(), inputs: ["argv": .array([.string("hdc"), .string("shell")])]))
    XCTAssertEqual(argv, .refuse(.rawCommandSurface(field: "argv")))

    let remotePath = await policyGuard.evaluate(
      guardInput(snapshot(), inputs: ["destination": .string("/data/local/tmp/x.hap")]))
    XCTAssertEqual(
      remotePath, .refuse(.rawCommandSurface(field: "destination=/data/local/tmp")))

    let clean = await policyGuard.evaluate(
      guardInput(snapshot(), inputs: ["durationSeconds": .integer(15)]))
    XCTAssertEqual(clean, .allow)
  }

  func testAnActiveJobBlocksASecondDispatch() async {
    let policyGuard = HarnessPolicyGuard(availability: StubAvailabilityPort())
    let busy = snapshot(activeJobID: "JOB-7")
    let verdict = await policyGuard.evaluate(guardInput(busy))
    XCTAssertEqual(verdict, .refuse(.activeJobConflict("JOB-7")))
  }

  func testARefusedAdmissionIsRecordedInTaskMemoryWithTheIntentIdentity() async throws {
    let jobs = BoundsJobPort()
    jobs.rejectionMessage = "observe.device@1 is runtime unavailable: provider_not_registered"
    let (coordinator, store, submission) = try makeStack(jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)

    // A rejection produces no job and no artifact; the durable dispatch intent
    // is the evidence, and the memory must be readable because of it.
    let memory = try await store.memory(scope: .task, key: task.htaskID)
    let attempt = try XCTUnwrap(memory.first { $0.kind == .attempt })
    XCTAssertEqual(attempt.evidence.jobIDs, [])
    XCTAssertEqual(attempt.evidence.requestIDs.count, 1)
    XCTAssertTrue(attempt.evidence.requestIDs[0].hasPrefix("htask-"))
    XCTAssertTrue(attempt.summary.contains("FAIL-"))

    let actions = try await coordinator.humanActions(task.htaskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .environmentUnavailable)
    XCTAssertEqual(action.requestID, attempt.evidence.requestIDs[0])
    XCTAssertNil(
      action.document,
      "no closed category describes an unavailable environment, so none is invented")
  }

  func testAuthorizationAdmissionRejectionProducesTypedApprovalAction() async throws {
    let jobs = BoundsJobPort()
    jobs.rejectionMessage =
      "authorizationRequired: mutation has no runtime capability reference"
    let (coordinator, _, submission) = try makeStack(jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    let expectedReason =
      "submissionRejected:authorizationRequired:observe.device@1"
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, expectedReason)
    XCTAssertEqual(outcome.snapshot.result?.reasonCode, expectedReason)

    let actions = try await coordinator.humanActions(task.htaskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .authorizationApproval)
    XCTAssertEqual(action.reasonCode, expectedReason)
    XCTAssertTrue(action.requestID?.hasPrefix("htask-") == true)
    let document = try HarnessHumanActionFactory.decode(try XCTUnwrap(action.document))
    XCTAssertEqual(document.category, .impactApproval)
    XCTAssertEqual(document.jobID, action.requestID)
  }

  func testAGuardRefusalIsRecordedInTaskMemory() async throws {
    // A step the guard refused never reaches the engine, so nothing else would
    // record it: without this the task's memory could not explain the stop.
    let jobs = BoundsJobPort()
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:00Z" },
      policyGuard: HarnessPolicyGuard(
        availability: StubAvailabilityPort(
          unavailable: [DebugCrashTaskHandler.observeDevice: "provider_not_registered"])))
    let task = try await coordinator.submit(
      HarnessTaskSubmission(
        type: .debugCrash, projectRef: "demo-app",
        target: HarnessTaskTargetReference(targetID: "TGT-1"),
        goal: HarnessTaskGoal(summary: "goal"),
        budgets: HarnessTaskBudgets(
          maxRounds: 4, maxWallClockSeconds: 900, maxArtifactBytes: 1024, maxE1Mutations: 0),
        policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash)))

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "operationUnavailable:observe.device@1")
    XCTAssertEqual(jobs.submittedOperations, [], "a refused step never reaches the engine")

    let memory = try await store.memory(scope: .task, key: task.htaskID)
    let attempt = try XCTUnwrap(memory.first { $0.kind == .attempt })
    XCTAssertTrue(attempt.summary.contains("guard refused"))
    XCTAssertTrue(attempt.summary.contains("operationUnavailable:observe.device@1"))
    XCTAssertFalse(attempt.evidence.requestIDs.isEmpty)
  }

  // MARK: - Memory promotion

  func testProjectMemoryOnlyAcceptsVerifiedKnowledge() throws {
    XCTAssertThrowsError(
      try HarnessMemoryEntry(
        memoryID: "mem-1", scope: .project, kind: .verifiedKnowledge, htaskID: "HTASK-1",
        projectRef: "demo-app", round: 1, summary: "probably fixed", confidence: .observed,
        evidence: HarnessMemoryEvidence(jobIDs: ["JOB-1"]),
        createdAtUTC: "2026-07-31T00:00:00Z")
    ) { error in
      XCTAssertEqual(
        error as? HarnessMemoryError, .promotionRequiresVerifiedConfidence(.observed))
    }

    XCTAssertThrowsError(
      try HarnessMemoryEntry(
        memoryID: "mem-2", scope: .task, kind: .fact, htaskID: "HTASK-1", projectRef: nil,
        round: 1, summary: "no receipt", confidence: .observed,
        evidence: HarnessMemoryEvidence(), createdAtUTC: "2026-07-31T00:00:00Z")
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .evidenceRequired(.task))
    }
  }

  func testPassingEvaluationPromotesProjectMemoryWithItsEvidence() async throws {
    let jobs = BoundsJobPort()
    let artifacts = BoundsArtifactPort()
    let (coordinator, _, submission) = try makeStack(
      jobs: jobs, artifacts: artifacts,
      criteria: [
        HarnessSuccessCriterion(
          criterionID: "B-1", metric: "matchingCrashCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 1,
          evidenceRequirements: ["crash-index.txt"])
      ],
      desiredState: [
        "baseWorkspaceRevision": .string(String(repeating: "a", count: 64)),
        "deviceProfile": .string("dayu200@1"),
        "buildPresetRef": .string("waterflow-debug@1"),
      ])
    let task = try await coordinator.submit(submission)
    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)
    // The first readable ledger baselines; the second is counted against it.
    artifacts.stage(jobID: "JOB-2", name: "crash-index.txt", text: emptyLedgerBytes)
    jobs.finish("JOB-2")
    _ = try await coordinator.reconcile(task.htaskID)
    artifacts.stage(jobID: "JOB-3", name: "crash-index.txt", text: emptyLedgerBytes)
    jobs.finish("JOB-3")
    let succeeded = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(succeeded.snapshot.status, .succeeded)

    let project = try await coordinator.projectMemory("demo-app")
    let entry = try XCTUnwrap(project.last)
    XCTAssertEqual(entry.scope, .project)
    XCTAssertEqual(entry.kind, .verifiedKnowledge)
    XCTAssertEqual(entry.lifecycle, .verified)
    XCTAssertEqual(entry.confidence, .evaluated)
    XCTAssertEqual(entry.evaluationID, succeeded.snapshot.latestEvaluationID)
    XCTAssertFalse(entry.evidence.artifactIDs.isEmpty)

    let taskMemory = try await coordinator.taskMemory(task.htaskID)
    XCTAssertTrue(taskMemory.contains { $0.kind == .observation })
    XCTAssertTrue(taskMemory.allSatisfy { !$0.evidence.isEmpty })
  }
}

/// Monotonic counter for a deterministic, advancing test clock.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = -1

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

extension HarnessMemoryEntry {
  fileprivate var evaluationID: String? { evidence.evaluationID }
}
