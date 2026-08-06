// Stale-decision guard contract tests (CHG-2026-055, TASK-HFA-002).
//
// Registered acceptance: HFA-AC-3 (a stale decision is not executed),
// HFA-AC-4 (staleness costs the model call and nothing else), HFA-AC-5
// (the basis digest is reproducible and every model call is recorded).
//
// The race these tests reproduce is real, not hypothetical. Planning
// suspends the coordinator actor - a model call is a network round trip -
// so `pause`, `resume` and `cancel` land *inside* the window between the
// snapshot a producer read and the moment its step would become a job.
// The gateways below use exactly that window: they call back into the
// coordinator while the harness waits for their answer.

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Runs `interference` while the coordinator waits for a proposal, then
/// answers with a well-formed step the harness would otherwise dispatch.
private actor InterferingGateway: HarnessDecisionGateway {
  private var interference: (@Sendable () async -> Void)?
  private var seen: [HarnessDecisionContext] = []

  nonisolated let producerID = "interfering-gateway@1"

  var seenContexts: [HarnessDecisionContext] { seen }

  func interfere(once body: @escaping @Sendable () async -> Void) {
    interference = body
  }

  func propose(_ context: HarnessDecisionContext) async throws -> Data {
    seen.append(context)
    let pending = interference
    interference = nil
    // The suspension the whole guard exists for.
    await pending?()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(
      JSONValue.object([
        "kind": .string("invokeOperation"),
        "operationRef": .string(DebugCrashTaskHandler.observeDevice),
        "hypothesis": .string("Observe the target before collecting anything."),
        "reasonCode": .string("baselineTargetObservation"),
      ]))) ?? Data()
  }
}

/// Answers with whatever bytes the test scripted, so a refused parse can be
/// asserted on as a model call that still happened.
private actor FixedReplyGateway: HarnessDecisionGateway {
  private let reply: Data
  private var seen: [HarnessDecisionContext] = []

  nonisolated let producerID = "fixed-reply-gateway@1"

  init(reply: Data) { self.reply = reply }

  var seenContexts: [HarnessDecisionContext] { seen }

  func propose(_ context: HarnessDecisionContext) async throws -> Data {
    seen.append(context)
    return reply
  }
}

private actor CountingJobPort: HarnessRuntimeJobPort {
  private var observations: [String: HarnessJobObservation] = [:]
  private var submitted: [String] = []
  private var keys: [String] = []
  private var bindingRevisions: [Int?] = []
  private var ordinal = 1

  var submittedOperations: [String] { submitted }
  var submittedKeys: [String] { keys }
  var submittedBindingRevisions: [Int?] { bindingRevisions }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submitted.append(request.operation.reference)
    keys.append(request.idempotencyKey)
    bindingRevisions.append(request.target.expectedBindingRevision)
    let jobID = "JOB-\(ordinal)"
    ordinal += 1
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
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
}

private struct DriftingWorkspacePort: HarnessRepairPort {
  let liveRevision: String

  func currentWorkspaceRevision(
    relativePaths: [String], projectRef: String, task: HarnessTaskSnapshot
  ) async throws -> String { liveRevision }

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    throw HarnessRepairPortError.unavailable("notExpected")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    throw HarnessRepairPortError.unavailable("notExpected")
  }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    throw HarnessRepairPortError.unavailable("notExpected")
  }

  func deployedArtifactDigest(jobID: String) async throws -> String {
    throw HarnessRepairPortError.unavailable("notExpected")
  }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback {
    throw HarnessRepairPortError.unavailable("notExpected")
  }
}

final class HarnessStaleDecisionContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-stale-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - Helpers

  private func makeStack(
    gateway: any HarnessDecisionGateway,
    jobs: CountingJobPort
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:00Z" },
      decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(enabledProjects: ["demo-app"]))
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
      goal: HarnessTaskGoal(summary: "No WaterFlow SIGABRT"),
      budgets: HarnessTaskBudgets(
        maxRounds: 6, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, store, submission)
  }

  private func snapshot(
    version: Int,
    observedState: [String: JSONValue] = [:],
    activeJobID: String? = nil,
    cancelRequested: Bool = false,
    bindingRevision: Int? = nil
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB",
      type: .debugCrash,
      intakeDescription: nil,
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(
        targetID: "TGT-958780b2ffb7", expectedBindingRevision: bindingRevision),
      goal: HarnessTaskGoal(summary: "No WaterFlow SIGABRT"),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 6, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      observedState: observedState,
      createdAtUTC: "2026-07-31T00:00:00Z",
      updatedAtUTC: "2026-07-31T00:00:00Z",
      status: .running,
      activeJobID: activeJobID,
      cancelRequested: cancelRequested,
      version: version)
  }

  private func decision(
    basis: HarnessDecisionBasis,
    operation: String = DebugCrashTaskHandler.buildOpenHarmony,
    attemptID: String? = "ATTEMPT-000000000001",
    modelRunID: String? = nil,
    contextDigest: String? = nil,
    workspaceRevision: String? = nil,
    deployedDigest: String? = nil,
    bindingRevision: Int? = nil,
    patchProposal: HarnessPatchProposal? = nil
  ) -> HarnessDecision {
    HarnessDecision(
      decisionID: "dec-envelope", htaskID: basis.htaskID, round: basis.activeRound + 1,
      kind: .invokeOperation, operationReference: operation, patchProposal: patchProposal,
      hypothesis: "execute only against exact facts", reasonCode: "envelopeFixture",
      producer: modelRunID == nil ? "deterministic@1" : "model@1",
      createdAtUTC: "2026-07-31T00:00:00Z", modelRunID: modelRunID,
      contextDigest: contextDigest
    ).stamped(
      with: basis, attemptID: attemptID,
      expectedWorkspaceRevision: workspaceRevision,
      expectedDeployedArtifactDigest: deployedDigest,
      expectedBindingRevision: bindingRevision)
  }

  private func proposal(baseRevision: String) throws -> HarnessPatchProposal {
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
      baseWorkspaceRevision: baseRevision, patchSHA256: digest, unifiedDiff: diff,
      touchedFiles: ["Sources/A.swift"], expectedChangedSymbols: ["value"])
  }

  // MARK: - HFA-AC-3: a stale decision is not executed

  func testAHumanResolutionDuringPlanningStopsTheDispatch() async throws {
    let jobs = CountingJobPort()
    let gateway = InterferingGateway()
    let (coordinator, store, submission) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission)

    // An operator pauses and resumes while the model is answering. Both are
    // legitimate; both move the state version the proposal was made on.
    await gateway.interfere {
      _ = try? await coordinator.pause(task.htaskID)
      _ = try? await coordinator.resume(task.htaskID, resolution: "operator checked the device")
    }

    let outcome = try await coordinator.reconcile(task.htaskID)

    XCTAssertEqual(outcome.action, .staleDecision)
    XCTAssertTrue(
      outcome.reasonCode.hasPrefix("STALE_DECISION:taskStateChanged"),
      "expected a state-version staleness, got \(outcome.reasonCode)")
    // The property that matters: nothing was handed to the engine.
    let submitted = await jobs.submittedOperations
    XCTAssertTrue(submitted.isEmpty)

    let events = try await store.events(task.htaskID)
    XCTAssertEqual(events.filter { $0.causation == .decisionStale }.count, 1)
    XCTAssertTrue(events.allSatisfy { $0.causation != .jobDispatched })
  }

  func testACancelDuringPlanningStopsTheDispatch() async throws {
    let jobs = CountingJobPort()
    let gateway = InterferingGateway()
    let (coordinator, _, submission) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission)

    await gateway.interfere {
      _ = try? await coordinator.cancel(task.htaskID)
    }

    let outcome = try await coordinator.reconcile(task.htaskID)

    XCTAssertEqual(outcome.action, .staleDecision)
    let submitted = await jobs.submittedOperations
    XCTAssertTrue(submitted.isEmpty)
    // A cancelled task is terminal: the refusal stands and nothing is
    // written on top of it.
    XCTAssertEqual(outcome.snapshot.status, .cancelled)
  }

  func testADecisionWithoutABasisIsUnverifiableRatherThanFresh() throws {
    // A decision written before this guard existed decodes, so history stays
    // readable - but it cannot be acted on.
    let legacy = Data(
      """
      {"documentType":"harness-decision","decisionId":"dec-legacy","htaskId":"HTASK-0123456789AB",\
      "round":1,"kind":"invokeOperation","operationReference":"observe.device@1","inputs":{},\
      "hypothesis":"legacy record","reasonCode":"legacy","producer":"debug-crash-handler@1",\
      "createdAtUtc":"2026-07-30T00:00:00Z"}
      """.utf8)
    let decoded = try JSONDecoder().decode(HarnessDecision.self, from: legacy)
    XCTAssertEqual(decoded.observedStateVersion, 0)
    XCTAssertEqual(decoded.basisDigest, "")

    let basis = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(HarnessDecisionFreshness.staleness(of: decoded, against: basis), .unverifiable)
  }

  func testAChangedBasisIsStaleEvenWhenTheVersionHeld() {
    // Availability moving under a proposal is the case a version counter
    // alone does not catch: nothing about the task changed, what it may do
    // did.
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 4),
      offeredOperations: [
        DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics,
      ])
    let decision = HarnessDecision(
      decisionID: "dec-1", htaskID: "HTASK-0123456789AB", round: 1, kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.observeDevice, hypothesis: "observe",
      reasonCode: "baselineTargetObservation", producer: "p@1",
      createdAtUTC: "2026-07-31T00:00:00Z"
    ).stamped(with: planned)

    let narrowed = HarnessDecisionBasis(
      snapshot: snapshot(version: 4),
      offeredOperations: [DebugCrashTaskHandler.observeDevice])
    guard case .basisMismatch? = HarnessDecisionFreshness.staleness(
      of: decision, against: narrowed)
    else {
      return XCTFail("a narrowed operation set must read as a changed basis")
    }
    XCTAssertNil(HarnessDecisionFreshness.staleness(of: decision, against: planned))
  }

  func testAnActiveJobAppearingUnderAProposalIsStale() {
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 4), offeredOperations: [DebugCrashTaskHandler.observeDevice])
    let decision = HarnessDecision(
      decisionID: "dec-2", htaskID: "HTASK-0123456789AB", round: 1, kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.observeDevice, hypothesis: "observe",
      reasonCode: "baselineTargetObservation", producer: "p@1",
      createdAtUTC: "2026-07-31T00:00:00Z"
    ).stamped(with: planned)

    let withJob = HarnessDecisionBasis(
      snapshot: snapshot(version: 4, activeJobID: "JOB-9"),
      offeredOperations: [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(of: decision, against: withJob),
      .activeJobAppeared("JOB-9"))
  }

  // MARK: - HFA-AC-4: staleness costs the call, not the strategy

  func testAStaleWakeChargesNoFailureNoProgressAndNoBudget() async throws {
    let jobs = CountingJobPort()
    let gateway = InterferingGateway()
    let (coordinator, store, submission) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission)

    await gateway.interfere {
      _ = try? await coordinator.pause(task.htaskID)
      _ = try? await coordinator.resume(task.htaskID, resolution: "operator checked the device")
    }
    let stale = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(stale.action, .staleDecision)

    // None of the three counters that can stop a task may move: the facts
    // changed, the strategy did not fail.
    XCTAssertEqual(stale.snapshot.noProgressRounds, 0)
    // The one thing staleness *does* cost is the model call that produced
    // the refused proposal: it happened, and it shipped a context off this
    // host (CHG-2026-055, TASK-HFA-011 gave that its own ceiling).
    XCTAssertEqual(stale.snapshot.consumedBudget, HarnessConsumedBudget(modelCalls: 1))
    let failures = try await store.failureRecords()
    XCTAssertTrue(failures.isEmpty)

    // And the loop is not poisoned: the next wake plans on current facts and
    // dispatches normally.
    let next = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(next.action, .dispatched)
    let submitted = await jobs.submittedOperations
    XCTAssertEqual(submitted, [DebugCrashTaskHandler.observeDevice])
  }

  // MARK: - HFA-AC-5: reproducible basis, recorded model call

  func testTheBasisDigestIsReproducibleAndMovesOnlyWithPersistedFacts() {
    let offered = [DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics]
    let first = HarnessDecisionBasis(snapshot: snapshot(version: 2), offeredOperations: offered)
    let again = HarnessDecisionBasis(snapshot: snapshot(version: 2), offeredOperations: offered)
    XCTAssertEqual(first.digest, again.digest)
    XCTAssertEqual(first.digest.count, 64)

    // Order of the offered set is not a fact.
    let reordered = HarnessDecisionBasis(
      snapshot: snapshot(version: 2), offeredOperations: offered.reversed())
    XCTAssertEqual(first.digest, reordered.digest)

    // Observed state is.
    let observed = HarnessDecisionBasis(
      snapshot: snapshot(version: 2, observedState: ["matchingCrashCount": .integer(1)]),
      offeredOperations: offered)
    XCTAssertNotEqual(first.digest, observed.digest)
  }

  func testAnAcceptedProposalRecordsTheModelCallItCameFrom() async throws {
    let jobs = CountingJobPort()
    let gateway = FixedReplyGateway(
      reply: Data(
        """
        {"kind":"invokeOperation","operationRef":"observe.device@1",\
        "hypothesis":"Observe the target first.","reasonCode":"baselineTargetObservation"}
        """.utf8))
    let (coordinator, store, submission) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .dispatched)

    let runs = try await store.modelRuns(task.htaskID)
    XCTAssertEqual(runs.count, 1)
    let run = try XCTUnwrap(runs.first)
    let storedDecision = try await store.decision(task.htaskID, round: 1)
    let decision = try XCTUnwrap(storedDecision)
    let attempts = try await store.attempts(task.htaskID)
    let activeAttempt = try XCTUnwrap(attempts.last)
    let storedIntent = try await store.intent(task.htaskID, round: 1)

    XCTAssertEqual(run.outcome, .accepted(decisionID: decision.decisionID))
    XCTAssertEqual(run.descriptor.provider, gateway.producerID)
    XCTAssertEqual(run.descriptor.modelName, HarnessModelDescriptor.unspecified)
    // The run and the decision it produced stand on the same facts.
    XCTAssertEqual(run.observedStateVersion, decision.observedStateVersion)
    // The digest is of the bytes that left, not of what the harness knew.
    let seen = await gateway.seenContexts
    XCTAssertEqual(run.contextDigest, seen.first?.transmittedDigest)
    XCTAssertEqual(run.contextBytes, seen.first?.transmittedByteCount)
    XCTAssertGreaterThan(run.contextBytes, 0)
    XCTAssertEqual(decision.modelRunID, run.modelRunID)
    XCTAssertEqual(decision.contextDigest, run.contextDigest)
    XCTAssertNotEqual(decision.basisDigest, decision.contextDigest)
    XCTAssertEqual(decision.attemptID, activeAttempt.attemptID)
    XCTAssertEqual(storedIntent?.attemptID, activeAttempt.attemptID)
  }

  func testARefusedProposalStillRecordsTheModelCall() async throws {
    let jobs = CountingJobPort()
    // `verdict` is a field the harness owns; the parser rejects the whole
    // proposal. The call still happened and still shipped a context.
    let gateway = FixedReplyGateway(
      reply: Data(
        """
        {"kind":"invokeOperation","operationRef":"observe.device@1","verdict":"pass",\
        "hypothesis":"Already fixed.","reasonCode":"claimed"}
        """.utf8))
    let (coordinator, store, submission) = try makeStack(gateway: gateway, jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    // The deterministic handler carried the wake instead.
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertTrue(outcome.reasonCode.contains("proposalRejected"))

    let runs = try await store.modelRuns(task.htaskID)
    XCTAssertEqual(runs.count, 1)
    guard case .rejected(let reasonCode)? = runs.first?.outcome else {
      return XCTFail("a refused proposal must be recorded as a rejected model run")
    }
    XCTAssertFalse(reasonCode.isEmpty)
    XCTAssertNil(runs.first?.outcome.decisionID)
  }

  func testAModelRunIdCannotEscapeItsTaskDirectory() throws {
    XCTAssertTrue(HarnessTaskStore.isWellFormed(modelRunID: "MRUN-0123456789AB"))
    for malformed in ["MRUN-../../etc", "MRUN-", "mrun-0123", "MRUN-zzz", "MRUN-01/02"] {
      XCTAssertFalse(
        HarnessTaskStore.isWellFormed(modelRunID: malformed),
        "\(malformed) must not be accepted as a file name")
    }
  }

  // MARK: - WP-02 execution-envelope matrix

  func testTaskStateAndHumanResolutionInvalidateTheEnvelope() {
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(basis: planned, attemptID: nil)
    let resolved = HarnessDecisionBasis(
      snapshot: snapshot(version: 4), offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(of: envelope, against: resolved),
      .taskStateChanged(observed: 3, current: 4))
  }

  func testActiveAttemptChangeInvalidatesInvokeAndProposalStrategies() throws {
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(basis: planned)
    let facts = HarnessDecisionExecutionFacts(activeAttemptID: "ATTEMPT-000000000002")
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned, executionFacts: facts),
      .attemptChanged(
        observed: "ATTEMPT-000000000001", current: "ATTEMPT-000000000002"))
    let patch = HarnessDecision(
      decisionID: "dec-patch-envelope", htaskID: planned.htaskID,
      round: planned.activeRound + 1, kind: .proposePatch,
      patchProposal: try proposal(baseRevision: String(repeating: "a", count: 64)),
      hypothesis: "repair", reasonCode: "patch", producer: "model@1",
      createdAtUTC: "2026-07-31T00:00:00Z"
    ).stamped(with: planned, attemptID: "ATTEMPT-000000000001")
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: patch, against: planned, executionFacts: facts),
      .attemptChanged(
        observed: "ATTEMPT-000000000001", current: "ATTEMPT-000000000002"))
  }

  /// `HFA-AC-25` — a reading that did not happen is not a reading that differs.
  ///
  /// The revision used to arrive as an optional, and `nil` meant both "the
  /// workspace moved" and "nothing answered". On 7.0.0.37 the second happened
  /// three rounds running — the isolated workspace's reference had become
  /// unresolvable after a restart — and every one was reported as
  /// `workspaceRevisionChanged:…->none`, an assertion about an observation
  /// that was never made. The loop then stopped blaming the evidence.
  func testAnUnreadableWorkspaceRevisionIsNotReportedAsAChangedOne() {
    let expected = String(repeating: "1", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.applyPatch])
    let envelope = decision(
      basis: planned, operation: DebugCrashTaskHandler.applyPatch,
      workspaceRevision: expected)
    let facts = HarnessDecisionExecutionFacts(
      activeAttemptID: "ATTEMPT-000000000001",
      workspaceRevision: .unmeasurable(reason: "projectProfileMismatch"))

    let staleness = HarnessDecisionFreshness.staleness(
      of: envelope, against: planned, executionFacts: facts)
    XCTAssertEqual(
      staleness,
      .workspaceRevisionUnmeasurable(
        observed: expected, reason: "projectProfileMismatch"))
    let reason = try? XCTUnwrap(staleness?.reasonCode)
    XCTAssertEqual(
      reason?.contains("workspaceRevisionChanged"), false,
      "an unread revision must not be reported as a changed one: \(reason ?? "nil")")
    XCTAssertEqual(
      reason?.contains("projectProfileMismatch"), true,
      "the stop must name what failed to answer: \(reason ?? "nil")")
  }

  /// `HFA-AC-25` — and the floor is unmoved: a revision that really changed is
  /// still stale. Three-valuing it only pulls "unreadable" out of "changed";
  /// it must never turn "changed" into "unchanged".
  func testAMeasuredMatchingRevisionIsFreshAndAMeasuredDifferentOneIsNot() {
    let expected = String(repeating: "1", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.applyPatch])
    let envelope = decision(
      basis: planned, operation: DebugCrashTaskHandler.applyPatch,
      workspaceRevision: expected)
    XCTAssertNil(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001",
          workspaceRevision: .measured(expected))))
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001",
          workspaceRevision: .measured(String(repeating: "2", count: 64)))),
      .workspaceRevisionChanged(
        observed: expected, current: String(repeating: "2", count: 64)))
  }

  func testOldPatchAndBuildWorkspaceRevisionsAreIndependentlyStale() {
    let old = String(repeating: "1", count: 64)
    let current = String(repeating: "2", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.applyPatch])
    for operation in [DebugCrashTaskHandler.applyPatch, DebugCrashTaskHandler.buildOpenHarmony] {
      let envelope = decision(
        basis: planned, operation: operation, workspaceRevision: old)
      let facts = HarnessDecisionExecutionFacts(
        activeAttemptID: "ATTEMPT-000000000001", workspaceRevision: .measured(current))
      XCTAssertEqual(
        HarnessDecisionFreshness.staleness(
          of: envelope, against: planned, executionFacts: facts),
        .workspaceRevisionChanged(observed: old, current: current), operation)
    }
  }

  func testOldDeploymentAndBindingRevisionsAreStale() {
    let deployed = String(repeating: "a", count: 64)
    let replacement = String(repeating: "b", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.captureDiagnostics])
    let deploymentEnvelope = decision(
      basis: planned, operation: DebugCrashTaskHandler.captureDiagnostics,
      deployedDigest: deployed)
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: deploymentEnvelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001", deployedArtifactDigest: replacement)),
      .deployedArtifactChanged(observed: deployed, current: replacement))

    let bindingEnvelope = decision(
      basis: planned, operation: DebugCrashTaskHandler.captureDiagnostics, bindingRevision: 7)
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: bindingEnvelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001", bindingRevision: 8)),
      .bindingRevisionChanged(observed: 7, current: 8))
  }

  func testModelContextMismatchAndMissingRunFailClosed() {
    let context = String(repeating: "c", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(
      basis: planned, modelRunID: "MRUN-000000000001", contextDigest: context)
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001")),
      .modelRunMissing("MRUN-000000000001"))
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001", modelRunID: "MRUN-000000000001",
          modelContextDigest: String(repeating: "d", count: 64),
          modelDecisionID: envelope.decisionID)),
      .contextMismatch)
  }

  func testDeterministicEnvelopeHasNoModelLinkButStillChecksAttemptAndRevision() {
    let revision = String(repeating: "e", count: 64)
    let planned = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(basis: planned, workspaceRevision: revision)
    XCTAssertNil(envelope.modelRunID)
    XCTAssertNil(envelope.contextDigest)
    XCTAssertNil(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000001", workspaceRevision: .measured(revision))))
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: envelope, against: planned,
        executionFacts: HarnessDecisionExecutionFacts(
          activeAttemptID: "ATTEMPT-000000000002", workspaceRevision: .measured(revision))),
      .attemptChanged(
        observed: "ATTEMPT-000000000001", current: "ATTEMPT-000000000002"))
  }

  func testLegacyEnvelopeIsReadableQueryableAndNeverFresh() throws {
    let legacy = Data(
      """
      {"documentType":"harness-decision","decisionId":"dec-legacy-envelope",\
      "htaskId":"HTASK-0123456789AB","round":1,"kind":"invokeOperation",\
      "operationReference":"observe.device@1","inputs":{},"hypothesis":"legacy",\
      "reasonCode":"legacy","producer":"legacy@1","createdAtUtc":"2026-07-30T00:00:00Z",\
      "observedStateVersion":3,"basisDigest":"\(String(repeating: "f", count: 64))"}
      """.utf8)
    let decoded = try JSONDecoder().decode(HarnessDecision.self, from: legacy)
    XCTAssertEqual(decoded.envelopeVersion, "1.0.0")
    let current = HarnessDecisionBasis(
      snapshot: snapshot(version: 3), offeredOperations: [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(of: decoded, against: current), .unverifiable)
  }

  func testPendingWorkspaceDriftClosesIntentWithoutProviderE1OrNoProgress() async throws {
    let old = String(repeating: "1", count: 64)
    let live = String(repeating: "2", count: 64)
    let current = snapshot(version: 3)
    let basis = HarnessDecisionBasis(
      snapshot: current, offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(
      basis: basis, workspaceRevision: old,
      patchProposal: try proposal(baseRevision: old))
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(current)
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.build-openharmony",
      patchFingerprint: String(repeating: "a", count: 64), baseWorkspaceRevision: old,
      artifactSourceSet: [], prerequisiteSet: [],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: current.target.targetID, toolchainProfile: "debug",
        expectedNextObservation: "BUILD_COMPLETE"))
    try await store.recordAttempt(
      HarnessAttempt(
        attemptID: "ATTEMPT-000000000001", htaskID: current.htaskID, ordinal: 1,
        hypothesis: "build", strategy: strategy,
        createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z"),
      kind: .created, reasonCode: "fixture")
    try await store.putDecision(envelope)
    let intent = HarnessDispatchIntent(
      htaskID: current.htaskID, round: envelope.round, decisionID: envelope.decisionID,
      attemptID: envelope.attemptID,
      operationReference: DebugCrashTaskHandler.buildOpenHarmony,
      targetID: current.target.targetID, expectedBindingRevision: nil,
      expectedWorkspaceRevision: old,
      inputsDigestSHA256: HarnessRequestIdentity.inputsDigest(envelope.inputs),
      requestID: "request-original", idempotencyKey: "idempotency-original",
      state: .pending, jobID: nil, createdAtUTC: "2026-07-31T00:00:00Z",
      updatedAtUTC: "2026-07-31T00:00:00Z")
    try await store.putIntent(intent)
    let jobs = CountingJobPort()
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs,
      repairPort: DriftingWorkspacePort(liveRevision: live),
      nowUTC: { "2026-07-31T00:00:01Z" })

    let outcome = try await coordinator.reconcile(current.htaskID)
    let closedIntent = try await store.intent(current.htaskID, round: 1)
    let submissions = await jobs.submittedOperations
    let failures = try await store.failureRecords()

    XCTAssertEqual(outcome.action, .staleDecision)
    XCTAssertTrue(outcome.reasonCode.contains("workspaceRevisionChanged"))
    XCTAssertEqual(closedIntent?.state, .stale)
    XCTAssertTrue(submissions.isEmpty, "stale intent must call no provider")
    XCTAssertEqual(outcome.snapshot.consumedBudget.e1Mutations, 0)
    XCTAssertEqual(outcome.snapshot.noProgressRounds, 0)
    XCTAssertTrue(failures.isEmpty)
  }

  func testSubmittedIntentUsesOriginalKeyEvenAfterDecisionBecomesStale() async throws {
    let plannedSnapshot = snapshot(version: 3, bindingRevision: 7)
    let current = snapshot(version: 4, bindingRevision: 8)
    let planned = HarnessDecisionBasis(
      snapshot: plannedSnapshot, offeredOperations: [DebugCrashTaskHandler.observeDevice])
    let envelope = decision(
      basis: planned, operation: DebugCrashTaskHandler.observeDevice, attemptID: nil,
      bindingRevision: 7)
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(current)
    try await store.putDecision(envelope)
    let originalKey = "idempotency-key-from-original-submit"
    try await store.putIntent(
      HarnessDispatchIntent(
        htaskID: current.htaskID, round: 1, decisionID: envelope.decisionID,
        operationReference: DebugCrashTaskHandler.observeDevice,
        targetID: current.target.targetID, expectedBindingRevision: 7,
        inputsDigestSHA256: HarnessRequestIdentity.inputsDigest(envelope.inputs),
        requestID: "request-original", idempotencyKey: originalKey,
        state: .submitted, jobID: nil, createdAtUTC: "2026-07-31T00:00:00Z",
        updatedAtUTC: "2026-07-31T00:00:00Z"))
    let replacement = HarnessDecision(
      decisionID: "dec-replacement", htaskID: current.htaskID, round: 1,
      kind: .invokeOperation, operationReference: DebugCrashTaskHandler.observeDevice,
      hypothesis: "replacement", reasonCode: "replacement", producer: "deterministic@1",
      createdAtUTC: "2026-07-31T00:00:01Z"
    ).stamped(with: HarnessDecisionBasis(
      snapshot: current, offeredOperations: [DebugCrashTaskHandler.observeDevice]))
    do {
      try await store.putDecision(replacement)
      XCTFail("an unresolved submitted intent must own its original decision")
    } catch let error as HarnessTaskStoreError {
      guard case .corrupt(let reason) = error else {
        return XCTFail("unexpected store error: \(error)")
      }
      XCTAssertTrue(reason.contains("submitted intent"))
    }
    let sameIDReplacement = HarnessDecision(
      decisionID: envelope.decisionID, htaskID: current.htaskID, round: 1,
      kind: .invokeOperation, operationReference: DebugCrashTaskHandler.observeDevice,
      hypothesis: "same id, different facts", reasonCode: "replacement",
      producer: "deterministic@1", createdAtUTC: "2026-07-31T00:00:01Z"
    ).stamped(
      with: HarnessDecisionBasis(
        snapshot: current, offeredOperations: [DebugCrashTaskHandler.observeDevice]),
      expectedBindingRevision: 8)
    do {
      try await store.putDecision(sameIDReplacement)
      XCTFail("a submitted decision id must not permit content replacement")
    } catch let error as HarnessTaskStoreError {
      guard case .corrupt = error else { return XCTFail("unexpected store error: \(error)") }
    }
    do {
      try await store.putIntent(
        HarnessDispatchIntent(
          htaskID: current.htaskID, round: 1, decisionID: envelope.decisionID,
          operationReference: DebugCrashTaskHandler.observeDevice,
          targetID: current.target.targetID, expectedBindingRevision: 7,
          inputsDigestSHA256: HarnessRequestIdentity.inputsDigest(envelope.inputs),
          requestID: "request-original", idempotencyKey: "replacement-key",
          state: .submitted, jobID: nil, createdAtUTC: "2026-07-31T00:00:00Z",
          updatedAtUTC: "2026-07-31T00:00:01Z"))
      XCTFail("a submitted intent must not permit idempotency-key replacement")
    } catch let error as HarnessTaskStoreError {
      guard case .corrupt = error else { return XCTFail("unexpected store error: \(error)") }
    }
    let jobs = CountingJobPort()
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:01Z" })

    let outcome = try await coordinator.reconcile(current.htaskID)
    let submittedKeys = await jobs.submittedKeys
    let submittedBindings = await jobs.submittedBindingRevisions

    XCTAssertEqual(outcome.action, .recoveredIntent)
    XCTAssertEqual(submittedKeys, [originalKey])
    XCTAssertEqual(submittedBindings, [7], "recovery must not adopt binding revision 8")
    let recovered = try await store.intent(current.htaskID, round: 1)
    XCTAssertEqual(recovered?.state, .linked)
    XCTAssertEqual(recovered?.idempotencyKey, originalKey)
  }

  func testRestartRecoversDecisionModelRunAttemptAndIntentAssociations() async throws {
    let current = snapshot(version: 3)
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(current)
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
      patchFingerprint: String(repeating: "a", count: 64),
      baseWorkspaceRevision: String(repeating: "b", count: 64),
      artifactSourceSet: [], prerequisiteSet: [],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: current.target.targetID, toolchainProfile: "debug",
        expectedNextObservation: "PATCH_APPLIED"))
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: current.htaskID, ordinal: 1,
      hypothesis: "repair", strategy: strategy,
      createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z")
    try await store.recordAttempt(attempt, kind: .created, reasonCode: "fixture")
    let context = String(repeating: "c", count: 64)
    let basis = HarnessDecisionBasis(
      snapshot: current, offeredOperations: [DebugCrashTaskHandler.buildOpenHarmony])
    let envelope = decision(
      basis: basis, modelRunID: "MRUN-000000000001", contextDigest: context,
      workspaceRevision: strategy.baseWorkspaceRevision)
    try await store.putModelRun(
      HarnessModelRun(
        modelRunID: "MRUN-000000000001", htaskID: current.htaskID, round: 1,
        descriptor: HarnessModelDescriptor(provider: "fixture"),
        observedStateVersion: current.version, contextDigest: context,
        contextBytes: 32, responseBytes: 16,
        outcome: .accepted(decisionID: envelope.decisionID),
        startedAtUTC: "2026-07-31T00:00:00Z", finishedAtUTC: "2026-07-31T00:00:01Z"))
    try await store.putDecision(envelope)
    try await store.putIntent(
      HarnessDispatchIntent(
        htaskID: current.htaskID, round: 1, decisionID: envelope.decisionID,
        attemptID: attempt.attemptID, modelRunID: envelope.modelRunID,
        operationReference: DebugCrashTaskHandler.buildOpenHarmony,
        targetID: current.target.targetID, expectedBindingRevision: nil,
        expectedWorkspaceRevision: envelope.expectedWorkspaceRevision,
        inputsDigestSHA256: String(repeating: "0", count: 64),
        requestID: "request-original", idempotencyKey: "idempotency-original",
        state: .pending, jobID: nil, createdAtUTC: "2026-07-31T00:00:00Z",
        updatedAtUTC: "2026-07-31T00:00:00Z"))

    let reopened = try HarnessTaskStore(rootURL: rootURL)
    let reopenedDecision = try await reopened.decision(current.htaskID, round: 1)
    let reopenedIntent = try await reopened.intent(current.htaskID, round: 1)
    let reopenedRuns = try await reopened.modelRuns(current.htaskID)
    let reopenedAttempts = try await reopened.attempts(current.htaskID)
    let restoredDecision = try XCTUnwrap(reopenedDecision)
    let restoredIntent = try XCTUnwrap(reopenedIntent)
    let restoredRun = try XCTUnwrap(reopenedRuns.first)
    let restoredAttempt = try XCTUnwrap(reopenedAttempts.first)
    XCTAssertEqual(restoredDecision.attemptID, restoredAttempt.attemptID)
    XCTAssertEqual(restoredDecision.modelRunID, restoredRun.modelRunID)
    XCTAssertEqual(restoredIntent.attemptID, restoredAttempt.attemptID)
    XCTAssertEqual(restoredIntent.modelRunID, restoredRun.modelRunID)
    XCTAssertEqual(restoredRun.outcome.decisionID, restoredDecision.decisionID)
  }
}
