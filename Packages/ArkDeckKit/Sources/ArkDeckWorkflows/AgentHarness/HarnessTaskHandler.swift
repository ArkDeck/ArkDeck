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
// defaults to deny (TASK-HTP-004), so the loop must be able to converge with
// nothing but repository code. Since TASK-HTP-002 it plans against the
// evaluator's verdict - collect another sample while the criteria are
// undecidable, hand a human the verdict when they genuinely failed - and it
// still never judges evidence itself and never reports a fix (HTP-INV-2).

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
  /// The artifact `capture.diagnostics@1` declares for bounded HiLog. It
  /// supports the *liveness* criterion only: TASK-HTP-006's r6 window
  /// measured zero fault blocks in 887 KB of real `hilog -x` taken right
  /// after a real crash, so a verdict about crashes cannot rest on it
  /// (CHG-2026-055, TASK-HFA-001).
  public static let hilogArtifact = "hilog.txt"
  /// The device's Faultlogger ledger, which is where the crash detail
  /// actually is. The crash criteria name it, so a capture that did not
  /// publish it cannot support any verdict about crashes.
  public static let crashIndexArtifact = HarnessObservationBuilder.crashIndexArtifact
  /// `capture.diagnostics@1` declares `durationSeconds` **required**, so a
  /// step that omits it is refused at admission and the loop can never
  /// collect the evidence its own criteria demand. Twenty seconds is a
  /// declared bound, not a guess: long enough for a live application to emit
  /// output the liveness measurement can see, and short enough that five
  /// samples cost well under two minutes of device time.
  ///
  /// `traceCategories` is deliberately *not* sent. Its presence escalates the
  /// effective effect to `deviceMutation`, and this task type declares
  /// `maxE1Mutations: 0` - an E0 task must not smuggle an E1 leg into its own
  /// evidence collection.
  public static let captureDurationSeconds = 20

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
        // Five clean runs, not one: a crash that reproduces intermittently
        // would otherwise pass on the first quiet capture. The ledger's
        // baseline round contributes no sample, so this needs six captures.
        minimumSamples: 5,
        evidenceRequirements: [Self.crashIndexArtifact],
        inconclusivePolicy: .collectMoreEvidence),
      HarnessSuccessCriterion(
        criterionID: "DC-2-application-liveness",
        metric: "applicationLiveness",
        comparator: .equalTo,
        expected: .string("healthy"),
        mandatory: true,
        minimumSamples: 1,
        evidenceRequirements: [Self.hilogArtifact],
        inconclusivePolicy: .collectMoreEvidence),
      HarnessSuccessCriterion(
        criterionID: "DC-3-no-new-fatal-signature",
        metric: "newFatalSignatureCount",
        comparator: .equalTo,
        expected: .integer(0),
        mandatory: true,
        minimumSamples: 1,
        evidenceRequirements: [Self.crashIndexArtifact],
        inconclusivePolicy: .collectMoreEvidence),
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
      switch snapshot.observed.latestVerdict {
      case .inconclusive:
        // The evaluator asked for more of the same evidence (missing samples
        // or a capture that did not verify). Another bounded capture is the
        // one thing that can change the answer.
        return invoke(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          operation: Self.captureDiagnostics,
          hypothesis:
            "The declared criteria are not yet decidable on the evidence collected so far; "
            + "another bounded capture adds the missing sample.",
          reasonCode: "collectAdditionalSample",
          phaseOnDispatch: snapshot.phase == .collecting ? nil : .collecting)
      case .fail:
        // A real, evidence-backed failure. Repairing it needs the workspace
        // operations (TASK-HTP-005); until they exist the honest move is to
        // hand a human the verdict instead of looping.
        return HarnessPlannedStep(
          decision: HarnessDecision(
            decisionID: decisionID,
            htaskID: snapshot.htaskID,
            round: round,
            kind: .requestHuman,
            hypothesis:
              "The evaluator judged the declared criteria failed on verified evidence; "
              + "repairing it requires source and build operations this task type cannot run.",
            reasonCode: "criteriaFailedNoRepairCapability",
            producer: producerID,
            createdAtUTC: nowUTC),
          phaseOnDispatch: nil)
      case .none:
        // Nothing has been judged yet - either the first capture is still
        // pending or no evaluator is configured in this composition. Either
        // way the next useful step is evidence.
        return invoke(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          operation: Self.captureDiagnostics,
          hypothesis: "No evidence has been evaluated yet for the declared criteria.",
          reasonCode: "collectDeclaredEvidence",
          phaseOnDispatch: snapshot.phase == .collecting ? nil : .collecting)
      case .pass:
        // Unreachable in practice: a passing evaluation ends the task before
        // planning runs. Fail closed rather than invent a next step.
        return HarnessPlannedStep(
          decision: HarnessDecision(
            decisionID: decisionID,
            htaskID: snapshot.htaskID,
            round: round,
            kind: .noSafeAction,
            hypothesis: "The criteria already passed; no further step is defined.",
            reasonCode: "criteriaAlreadyPassed",
            producer: producerID,
            createdAtUTC: nowUTC),
          phaseOnDispatch: nil)
      case .error:
        return HarnessPlannedStep(
          decision: HarnessDecision(
            decisionID: decisionID,
            htaskID: snapshot.htaskID,
            round: round,
            kind: .requestHuman,
            hypothesis:
              "Evidence integrity failed verification; another capture cannot be trusted "
              + "until that is understood.",
            reasonCode: "evidenceIntegrityUnresolved",
            producer: producerID,
            createdAtUTC: nowUTC),
          phaseOnDispatch: nil)
      }
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

  /// Inputs for the operations this type may submit. Every value here is a
  /// field the operation itself declares; nothing derived from a goal string
  /// or a model reaches this map.
  static func typedInputs(
    for operationReference: String,
    snapshot: HarnessTaskSnapshot? = nil
  ) -> [String: JSONValue] {
    switch operationReference {
    case Self.captureDiagnostics:
      var inputs: [String: JSONValue] = [
        "durationSeconds": .integer(Int64(Self.captureDurationSeconds)),
        // The crash ledger is where the judging fields live. It is a
        // read-only leg: unlike the trace, tree and screenshot legs its
        // presence does not raise the effective effect, so an E0 task with
        // `maxE1Mutations: 0` may ask for it.
        "crashLogs": .bool(true),
      ]
      // Fetch one entry's body only when a previous round actually observed
      // that entry. The name comes from verified ledger bytes - never from
      // the goal string, a model, or a caller - and the operation validates
      // it against the entry-name pattern besides.
      if case .string(let entry)? = snapshot?.observed.measurements[
        HarnessObservationBuilder.latestEntryMetric], !entry.isEmpty
      {
        inputs["crashLogName"] = .string(entry)
      }
      return inputs
    default:
      // `observe.device@1` declares no required input: the target it observes
      // comes from the request's target, not from an input field.
      return [:]
    }
  }

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
        // here (HTP-INV-11). What the operation declares *required* has to be
        // present, or admission refuses the step: an empty map is not a
        // conservative default, it is an unrunnable one.
        inputs: Self.typedInputs(for: operation, snapshot: snapshot),
        hypothesis: hypothesis,
        reasonCode: reasonCode,
        producer: producerID,
        createdAtUTC: nowUTC),
      phaseOnDispatch: phaseOnDispatch)
  }
}
