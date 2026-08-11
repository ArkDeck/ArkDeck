// Three-dimensional harness state contracts (CHG-2026-055, TASK-HFA-006).
//
// Registered acceptance: HFA-AC-13 (transient device facts never rewind the
// product stage and every stage-gate cell fails closed) and HFA-AC-14
// (schema-1 task directories migrate forward without rewriting events.jsonl).

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private actor HFA006NoDispatchJobPort: HarnessRuntimeJobPort {
  private(set) var submissions = 0

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    submissions += 1
    throw HarnessJobPortError.rejected("HFA-006 condition tests dispatch nothing")
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    throw HarnessJobPortError.unknownJob(jobID)
  }

  func requestCancel(jobID: String) async throws {}
}

final class HarnessThreeDimensionalStateContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-hfa006-state", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  private func condition(
    _ name: HarnessTaskConditionName,
    _ state: HarnessTriState = .trueValue,
    reason: String = "contractFixture"
  ) -> HarnessTaskCondition {
    HarnessTaskCondition(name: name, state: state, reasonCode: reason)
  }

  private func allTrueConditions() -> [HarnessTaskCondition] {
    HarnessTaskConditionName.allCases.map { condition($0) }
  }

  private func snapshot(
    id: String = "HTASK-006000000001",
    lifecycle: HarnessTaskLifecycle = .running,
    stage: HarnessTaskStage = .verifying,
    result: HarnessTaskResult? = nil,
    version: Int = 4,
    conditions: [HarnessTaskCondition]? = nil
  ) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: id, type: .debugCrash, intakeDescription: nil,
      projectRef: "waterflow",
      target: HarnessTaskTargetReference(
        targetID: "TGT-hfa006-pseudonym", expectedBindingRevision: 7),
      goal: HarnessTaskGoal(summary: "keep the verified product stage"),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 20, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 3),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      createdAtUTC: "2026-07-31T00:00:00Z",
      updatedAtUTC: "2026-07-31T00:00:00Z",
      status: lifecycle, phase: stage, result: result, version: version,
      waitReason: lifecycle == .waiting ? .userSuspended : nil,
      conditions: conditions ?? allTrueConditions())
  }

  // MARK: - HFA-AC-13

  func testTransientDisconnectRecoveryAndBindingDriftNeverRewindStage() async throws {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let port = HFA006NoDispatchJobPort()
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: port, nowUTC: { "2026-07-31T00:00:01Z" })
    let initial = snapshot()
    try await store.create(initial)

    let disconnected = try await coordinator.recordTargetObservation(
      initial.htaskID, currentBindingRevision: 7, deviceReady: false)
    XCTAssertEqual(disconnected.lifecycle, .waiting)
    XCTAssertEqual(disconnected.waitReason, .deviceUnavailable)
    XCTAssertEqual(disconnected.stage, .verifying)
    XCTAssertEqual(disconnected.condition(.deviceBound).state, .trueValue)
    XCTAssertEqual(disconnected.condition(.deviceReady).state, .falseValue)

    let recovered = try await coordinator.recordTargetObservation(
      initial.htaskID, currentBindingRevision: 7, deviceReady: true)
    XCTAssertEqual(recovered.lifecycle, .running)
    XCTAssertNil(recovered.waitReason)
    XCTAssertEqual(recovered.stage, .verifying)
    XCTAssertEqual(recovered.condition(.deviceReady).state, .trueValue)

    let plannedBasis = HarnessDecisionBasis(
      snapshot: recovered,
      offeredOperations: [DebugCrashTaskHandler.captureDiagnostics])
    let oldDecision = HarnessDecision(
      decisionID: "dec-hfa006-old-binding", htaskID: recovered.htaskID,
      round: recovered.activeRound + 1, kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      hypothesis: "capture against binding revision seven",
      reasonCode: "collectDeclaredEvidence", producer: "contract@1",
      createdAtUTC: "2026-07-31T00:00:01Z"
    ).stamped(with: plannedBasis)

    let changedBinding = try await coordinator.recordTargetObservation(
      initial.htaskID, currentBindingRevision: 8, deviceReady: true)
    XCTAssertEqual(changedBinding.lifecycle, .waiting)
    XCTAssertEqual(changedBinding.waitReason, .deviceUnavailable)
    XCTAssertEqual(changedBinding.stage, .verifying)
    XCTAssertEqual(changedBinding.condition(.deviceBound).state, .unknown)
    XCTAssertEqual(changedBinding.condition(.deviceReady).state, .unknown)
    XCTAssertEqual(
      HarnessDecisionFreshness.staleness(
        of: oldDecision,
        against: HarnessDecisionBasis(
          snapshot: changedBinding,
          offeredOperations: [DebugCrashTaskHandler.captureDiagnostics])),
      .taskStateChanged(observed: recovered.version, current: changedBinding.version))
    let submissions = await port.submissions
    XCTAssertEqual(submissions, 0)
  }

  func testEveryRequiredStageGateCellRejectsFalseAndUnknown() throws {
    var exercisedCells = 0
    for gate in HarnessTaskStageGates.all {
      let base = snapshot(stage: gate.from, conditions: allTrueConditions())
      let positive = HarnessTaskTransition(
        causation: .jobObserved, reasonCode: "positiveGateFixture",
        status: .running, phase: gate.to, activeRound: base.activeRound,
        activeJobID: nil, consumedBudget: base.consumedBudget,
        artifactRefs: base.artifactRefs, cancelRequested: false,
        atUTC: "2026-07-31T00:00:02Z", conditions: base.conditions)
      XCTAssertNoThrow(try HarnessTaskStateReducer.apply(positive, to: base))

      for required in gate.requiredConditions {
        for state in [HarnessTriState.falseValue, .unknown] {
          exercisedCells += 1
          let conditions = HarnessTaskConditionSet.replacing(
            base.conditions,
            with: [condition(required, state, reason: "negativeGateFixture")])
          let transition = HarnessTaskTransition(
            causation: .jobObserved, reasonCode: "negativeGateFixture",
            status: .running, phase: gate.to, activeRound: base.activeRound,
            activeJobID: nil, consumedBudget: base.consumedBudget,
            artifactRefs: base.artifactRefs, cancelRequested: false,
            atUTC: "2026-07-31T00:00:03Z", conditions: conditions)
          XCTAssertThrowsError(
            try HarnessTaskStateReducer.apply(transition, to: base),
            "\(gate.from.rawValue)->\(gate.to.rawValue) must reject "
              + "\(required.rawValue)=\(state.rawValue)"
          ) { error in
            XCTAssertEqual(
              error as? HarnessTaskTransitionError,
              .stageGateUnsatisfied(
                from: gate.from, to: gate.to, condition: required, actual: state))
          }
        }
      }
    }
    XCTAssertGreaterThan(exercisedCells, 0)
  }

  func testConditionChangesParticipateInTheDecisionBasis() {
    let ready = snapshot(version: 9, conditions: allTrueConditions())
    let unavailable = snapshot(
      version: 9,
      conditions: HarnessTaskConditionSet.replacing(
        ready.conditions,
        with: [condition(.deviceReady, .falseValue, reason: "deviceUnavailable")]))
    let operations = [DebugCrashTaskHandler.captureDiagnostics]
    XCTAssertNotEqual(
      HarnessDecisionBasis(snapshot: ready, offeredOperations: operations).digest,
      HarnessDecisionBasis(snapshot: unavailable, offeredOperations: operations).digest)
  }

  func testCanonicalWaitingRecordsFailClosedWithoutAnExactReason() throws {
    let waiting = snapshot(lifecycle: .waiting)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(waiting))
        as? [String: Any])
    object.removeValue(forKey: "waitReason")
    let missingReason = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(try JSONDecoder().decode(HarnessTaskSnapshot.self, from: missingReason))

    object["lifecycle"] = "running"
    object["status"] = "running"
    object["waitReason"] = HarnessTaskWaitReason.activeJob.rawValue
    let reasonOutsideWaiting = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys])
    XCTAssertThrowsError(
      try JSONDecoder().decode(HarnessTaskSnapshot.self, from: reasonOutsideWaiting))
  }
}
