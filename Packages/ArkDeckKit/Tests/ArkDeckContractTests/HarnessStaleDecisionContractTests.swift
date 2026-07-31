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

import XCTest

@testable import ArkDeckCore
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
  private var ordinal = 1

  var submittedOperations: [String] { submitted }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submitted.append(request.operation.reference)
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
    cancelRequested: Bool = false
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB",
      type: .debugCrash,
      intakeDescription: nil,
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
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
      outcome.reasonCode.hasPrefix("decisionStale:stateVersion"),
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
    guard case .basisChanged? = HarnessDecisionFreshness.staleness(of: decision, against: narrowed)
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
}
