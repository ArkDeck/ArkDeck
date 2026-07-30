// Closed task handlers (CHG-2026-054, TASK-HTP-001).
//
// A task type is code plus tests, never a user-supplied workflow document:
// the handler owns which operations the type may ever submit, which phase
// follows a completed operation, and what the next step is. Adding a type
// means adding a handler and its tests, which is the point - there is no
// DSL for a caller to compose an arbitrary device workflow with.
//
// The `debugCrash` handler here is fully deterministic and needs no model.
// That is a design commitment, not a placeholder: egress to a model
// defaults to deny (TASK-HTP-004), so the loop must be able to converge on
// evidence collection with nothing but repository code. What it cannot do
// yet is analyse: the evaluator is TASK-HTP-002, so once evidence is
// collected this handler stops honestly and asks for a human instead of
// guessing or declaring anything fixed.

import ArkDeckCore
import Foundation

public struct HarnessPlannedStep: Equatable, Sendable {
  public let decision: HarnessDecision
  /// Phase the task moves into when this step is dispatched. `nil` keeps
  /// the current phase.
  public let phaseOnDispatch: HarnessTaskPhase?

  public init(decision: HarnessDecision, phaseOnDispatch: HarnessTaskPhase?) {
    self.decision = decision
    self.phaseOnDispatch = phaseOnDispatch
  }
}

public protocol HarnessTaskHandler: Sendable {
  var type: HarnessTaskType { get }
  /// The closed set of operation references this task type may submit.
  /// A submission may narrow it; nothing may widen it.
  var permittedOperations: Set<String> { get }
  /// Default criteria for a submission that declares none. They are
  /// recorded, not evaluated, until TASK-HTP-002 lands the evaluator.
  func defaultSuccessCriteria() -> [HarnessSuccessCriterion]
  /// The next step, given only persisted state. Pure: same snapshot in,
  /// same step out, so a replay after a crash proposes the same thing.
  func plan(for snapshot: HarnessTaskSnapshot, decisionID: String, nowUTC: String)
    -> HarnessPlannedStep
  /// Phase after an operation completed successfully.
  func phase(afterSuccessOf operationReference: String, in phase: HarnessTaskPhase)
    -> HarnessTaskPhase
}

public struct DebugCrashTaskHandler: HarnessTaskHandler {
  public static let observeDevice = "observe.device@1"
  public static let captureDiagnostics = "capture.diagnostics@1"

  public init() {}

  public var type: HarnessTaskType { .debugCrash }

  /// E0 only. A crash-debug task cannot reach a device mutation in
  /// TASK-HTP-001: the operations that mutate a device are not in this
  /// set, so no budget or capability discussion can make them reachable.
  public var permittedOperations: Set<String> {
    [Self.observeDevice, Self.captureDiagnostics]
  }

  public func defaultSuccessCriteria() -> [HarnessSuccessCriterion] {
    [
      HarnessSuccessCriterion(
        criterionID: "DC-1-crash-signature-absent",
        metric: "matchingCrashCount",
        comparator: .equalTo,
        expected: .integer(0),
        mandatory: true,
        minimumSamples: 5),
      HarnessSuccessCriterion(
        criterionID: "DC-2-application-liveness",
        metric: "applicationLiveness",
        comparator: .equalTo,
        expected: .string("healthy"),
        mandatory: true,
        minimumSamples: 1),
      HarnessSuccessCriterion(
        criterionID: "DC-3-no-new-fatal-signature",
        metric: "newFatalSignatureCount",
        comparator: .equalTo,
        expected: .integer(0),
        mandatory: true,
        minimumSamples: 1),
    ]
  }

  public func plan(
    for snapshot: HarnessTaskSnapshot,
    decisionID: String,
    nowUTC: String
  ) -> HarnessPlannedStep {
    let round = snapshot.activeRound + 1
    switch snapshot.phase {
    case .initializing:
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.observeDevice,
        hypothesis: "The target must be observable before any evidence is worth collecting.",
        reasonCode: "baselineTargetObservation",
        phaseOnDispatch: nil)
    case .deviceReady, .reproducing:
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.captureDiagnostics,
        hypothesis:
          "Bounded HiLog and UI dump for the declared goal are the minimum evidence "
          + "any later analysis needs.",
        reasonCode: "collectDeclaredEvidence",
        phaseOnDispatch: nil)
    case .collecting, .analyzing, .verifying:
      // Evidence exists; judging it is the evaluator's job and the
      // evaluator does not exist yet. Stopping here is the honest move:
      // this handler will not classify a crash, and it will never report
      // a fix (HTP-INV-2).
      return HarnessPlannedStep(
        decision: HarnessDecision(
          decisionID: decisionID,
          htaskID: snapshot.htaskID,
          round: round,
          kind: .requestHuman,
          hypothesis:
            "Evidence for this round is collected; deciding whether the goal is met "
            + "requires the evaluation engine.",
          reasonCode: "evaluationEngineUnavailable",
          producer: producerID,
          createdAtUTC: nowUTC),
        phaseOnDispatch: nil)
    case .patching, .building, .deploying:
      // Reachable only if a future handler revision moves here; today
      // nothing in this type can, so it fails closed rather than
      // pretending a workspace operation exists.
      return HarnessPlannedStep(
        decision: HarnessDecision(
          decisionID: decisionID,
          htaskID: snapshot.htaskID,
          round: round,
          kind: .noSafeAction,
          hypothesis: "No workspace operation is available to this task type.",
          reasonCode: "workspaceOperationsUnavailable",
          producer: producerID,
          createdAtUTC: nowUTC),
        phaseOnDispatch: nil)
    }
  }

  public func phase(
    afterSuccessOf operationReference: String,
    in phase: HarnessTaskPhase
  ) -> HarnessTaskPhase {
    switch (operationReference, phase) {
    case (Self.observeDevice, .initializing): return .deviceReady
    case (Self.captureDiagnostics, .deviceReady): return .collecting
    case (Self.captureDiagnostics, .reproducing): return .collecting
    default: return phase
    }
  }

  private var producerID: String { "debug-crash-handler@1" }

  private func invoke(
    _ snapshot: HarnessTaskSnapshot,
    decisionID: String,
    round: Int,
    nowUTC: String,
    operation: String,
    hypothesis: String,
    reasonCode: String,
    phaseOnDispatch: HarnessTaskPhase?
  ) -> HarnessPlannedStep {
    HarnessPlannedStep(
      decision: HarnessDecision(
        decisionID: decisionID,
        htaskID: snapshot.htaskID,
        round: round,
        kind: .invokeOperation,
        operationReference: operation,
        // Typed inputs only, and only ones this operation declares. No
        // argv, no remote path, no target selection flag can be expressed
        // here (HTP-INV-11).
        inputs: [:],
        hypothesis: hypothesis,
        reasonCode: reasonCode,
        producer: producerID,
        createdAtUTC: nowUTC),
      phaseOnDispatch: phaseOnDispatch)
  }
}
