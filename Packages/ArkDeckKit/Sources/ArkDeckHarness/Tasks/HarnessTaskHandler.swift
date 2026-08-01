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
  /// Operations a model may choose in this exact persisted phase. This is a
  /// further narrowing of `permittedOperations`, never an expansion.
  func offeredOperations(for snapshot: HarnessTaskSnapshot) -> Set<String>
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

extension HarnessTaskHandler {
  public func offeredOperations(for snapshot: HarnessTaskSnapshot) -> Set<String> {
    permittedOperations
  }
}

public struct DebugCrashTaskHandler: HarnessTaskHandler {
  public static let observeDevice = "observe.device@1"
  public static let captureDiagnostics = "capture.diagnostics@1"
  public static let applyPatch = "workspace.apply-patch@1"
  public static let buildOpenHarmony = "workspace.build-openharmony@1"
  public static let runTests = "workspace.run-tests@1"
  public static let revertPatch = "workspace.revert-patch@1"
  public static let deployHAP = "debug.hap@1"
  public static let analyzeCrashLedger = "analyzer.extract-crash-signature@1"
  /// A successful capture is not evaluated until its raw ledger has passed
  /// through the pinned analyzer. These ID-only facts survive a daemon
  /// restart without exposing the artifact's host path.
  public static let pendingAnalysisSourceJobKey = "pendingCrashAnalysisSourceJobId"
  public static let pendingAnalysisSourceArtifactKey = "pendingCrashAnalysisSourceArtifactId"
  public static let pendingAnalysisSourceLeaseKey = "pendingCrashAnalysisSourceLease"
  public static let pendingAnalysisReturnPhaseKey = "pendingCrashAnalysisReturnPhase"
  /// Durable observation written only after the typed crash-fixture
  /// deployment succeeds. Phase alone cannot carry this fact because the
  /// following capture legitimately moves `reproducing` back to `collecting`.
  public static let baselineDeploymentMarker = "baselineCrashFixtureDeployed"
  /// Bounded HiLog remains diagnostic context only. It proves neither a
  /// crash nor that the declared application is alive.
  public static let hilogArtifact = "hilog.txt"
  /// Derived from the same capture Job's typed process readback. This is the
  /// only Artifact allowed to support DC-2.
  public static let applicationLivenessArtifact = "application-liveness.json"
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

  /// The repair leg remains closed: source changes use the published
  /// workspace operations and the only device mutation is the existing typed
  /// HAP deployment, still guarded by the runtime capability store.
  public var permittedOperations: Set<String> {
    [
      Self.observeDevice, Self.captureDiagnostics, Self.applyPatch,
      Self.buildOpenHarmony, Self.runTests, Self.revertPatch, Self.deployHAP,
      Self.analyzeCrashLedger,
    ]
  }

  public func offeredOperations(for snapshot: HarnessTaskSnapshot) -> Set<String> {
    if let repair = snapshot.repairAttempt, repair.patchAttemptRef != nil, !repair.reverted,
      repair.rollbackRequired
        || (repair.deployedDigest != nil && snapshot.observed.latestVerdict == .fail)
    {
      return [Self.revertPatch]
    }
    if pendingAnalysisLease(snapshot) != nil {
      return [Self.analyzeCrashLedger]
    }
    switch snapshot.phase {
    case .initializing:
      return [Self.observeDevice]
    case .collecting where baselineDeploymentReady(snapshot):
      return baselineDeploymentBudgetAvailable(snapshot) ? [Self.deployHAP] : []
    case .reproducing, .collecting, .verifying:
      return [Self.captureDiagnostics]
    case .analyzing:
      return snapshot.observed.latestVerdict == .fail
        ? [Self.applyPatch] : [Self.captureDiagnostics]
    case .patching:
      return []
    case .building:
      guard let repair = snapshot.repairAttempt else { return [] }
      if repair.buildSourceRevision == nil { return [Self.buildOpenHarmony] }
      if !repair.testsPassed { return [Self.runTests] }
      return [Self.deployHAP]
    case .deploying:
      return []
    }
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
        // Every clean verification run must also prove that the exact
        // deployed application is alive; one old liveness observation may
        // not bless the other four crash-ledger samples.
        minimumSamples: 5,
        evidenceRequirements: [Self.applicationLivenessArtifact],
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
    if let repair = snapshot.repairAttempt, let patchAttemptRef = repair.patchAttemptRef,
      !repair.reverted,
      repair.rollbackRequired
        || (repair.deployedDigest != nil && snapshot.observed.latestVerdict == .fail)
    {
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.revertPatch,
        inputs: [
          "projectRef": .string(snapshot.projectRef ?? ""),
          "patchAttemptRef": .string(patchAttemptRef),
        ],
        hypothesis:
          "Deployment or verification failed; restore the exact durable patch preimage before "
          + "another strategy is considered.",
        reasonCode: "rollbackFailedRepair", phaseOnDispatch: .analyzing)
    }
    if let lease = pendingAnalysisLease(snapshot) {
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.analyzeCrashLedger,
        inputs: ["sourceArtifactRef": .string(lease)],
        hypothesis:
          "Parse the exact captured crash-ledger Artifact with the pinned deterministic "
          + "analyzer before any criterion consumes it.",
        reasonCode: "analyzeCapturedCrashLedger", phaseOnDispatch: .analyzing)
    }
    switch snapshot.phase {
    case .initializing:
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.observeDevice,
        hypothesis: "The target must be observable before any evidence is worth collecting.",
        reasonCode: "baselineTargetObservation",
        phaseOnDispatch: nil)
    case .reproducing:
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.captureDiagnostics,
        hypothesis:
          "Bounded HiLog and UI dump for the declared goal are the minimum evidence "
          + "any later analysis needs.",
        reasonCode: "collectDeclaredEvidence",
        phaseOnDispatch: nil)
    case .collecting where baselineDeploymentReady(snapshot):
      guard baselineDeploymentBudgetAvailable(snapshot) else {
        return noSafeAction(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          reasonCode: "baselineDeploymentRepairBudgetUnavailable",
          hypothesis:
            "Injecting the declared crash fixture is admitted only when the E1 budget also "
            + "reserves the repair deployment and its possible rollback.")
      }
      guard let lease = desiredString("baselineHapArtifactLease", snapshot),
        let bundle = desiredString("bundleName", snapshot),
        let ability = desiredString("abilityName", snapshot)
      else {
        return noSafeAction(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          reasonCode: "baselineDeploymentInputsUnavailable",
          hypothesis:
            "The immutable crash-fixture lease, bundle name and ability name are required "
            + "before the task may inject its declared failure.")
      }
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.deployHAP,
        inputs: [
          "hapArtifactLease": .string(lease), "bundleName": .string(bundle),
          "abilityName": .string(ability), "cleanupPolicy": .string("retain"),
          "postRunAbilityState": .string("running"), "captureDiagnostics": .bool(true),
          "diagnosticsDurationSeconds": .integer(5),
          "portForwardProfile": .string("none"),
        ],
        hypothesis:
          "The crash ledger has a durable baseline; deploy the immutable declared fixture so "
          + "the next bounded capture can distinguish a newly injected crash from history.",
        reasonCode: "deployBaselineCrashFixture", phaseOnDispatch: .reproducing)
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
          phaseOnDispatch: snapshot.phase == .analyzing ? .collecting : nil)
      case .fail:
        // A model-backed producer may replace this deterministic fallback with
        // a strictly parsed PROPOSE_PATCH. Without patch bytes there is
        // nothing safe for the built-in strategy to invent.
        return HarnessPlannedStep(
          decision: HarnessDecision(
            decisionID: decisionID,
            htaskID: snapshot.htaskID,
            round: round,
            kind: .requestHuman,
            hypothesis:
              "The evaluator judged the declared criteria failed on verified evidence; "
              + "repairing it requires a bounded PROPOSE_PATCH decision.",
            reasonCode: "patchProposalRequired",
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
          phaseOnDispatch: snapshot.phase == .analyzing ? .collecting : nil)
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
    case .patching:
      return noSafeAction(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        reasonCode: "patchReadbackUnavailable",
        hypothesis: "The patching phase has no active job or verified applied-patch readback.")
    case .building:
      guard let repair = snapshot.repairAttempt else {
        return noSafeAction(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          reasonCode: "repairAttemptUnavailable",
          hypothesis: "Build cannot start without an evidence-derived patch attempt.")
      }
      if repair.buildSourceRevision == nil {
        return invoke(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          operation: Self.buildOpenHarmony,
          inputs: [
            "projectRef": .string(snapshot.projectRef ?? ""),
            "buildPresetRef": .string(desiredString("buildPresetRef", snapshot) ?? "arkdeck-debug"),
          ],
          hypothesis:
            "Build the exact patched workspace; its source revision and output digest must be "
            + "read back before deployment.",
          reasonCode: "buildPatchedWorkspace", phaseOnDispatch: nil)
      }
      if !repair.testsPassed {
        return invoke(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          operation: Self.runTests,
          inputs: [
            "projectRef": .string(snapshot.projectRef ?? ""),
            "testPresetRef": .string(desiredString("testPresetRef", snapshot) ?? "arkdeck-tests"),
          ],
          hypothesis: "Run the declared tests against the same patch revision before deployment.",
          reasonCode: "testPatchedWorkspace", phaseOnDispatch: nil)
      }
      guard let lease = repair.buildOutputArtifactLease,
        let bundle = desiredString("bundleName", snapshot),
        let ability = desiredString("abilityName", snapshot)
      else {
        return noSafeAction(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          reasonCode: "deploymentInputsUnavailable",
          hypothesis:
            "The verified build output lease, bundle name and ability name are required for "
            + "the typed deployment leg.")
      }
      guard snapshot.consumedBudget.e1Mutations + 2 <= snapshot.budgets.maxE1Mutations else {
        return noSafeAction(
          snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
          reasonCode: "deploymentRollbackBudgetUnavailable",
          hypothesis:
            "Deployment is not admitted unless the E1 budget can pay for both deployment and "
            + "a possible rollback.")
      }
      return invoke(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        operation: Self.deployHAP,
        inputs: [
          "hapArtifactLease": .string(lease), "bundleName": .string(bundle),
          "abilityName": .string(ability), "cleanupPolicy": .string("retain"),
          "postRunAbilityState": .string("running"),
        ],
        hypothesis: "Deploy only the immutable output whose digest passed the build gate.",
        reasonCode: "deployVerifiedBuildOutput", phaseOnDispatch: .deploying)
    case .deploying:
      return noSafeAction(
        snapshot, decisionID: decisionID, round: round, nowUTC: nowUTC,
        reasonCode: "deploymentReadbackUnavailable",
        hypothesis: "Deployment may advance only through an equal artifact-digest readback.")
    }
  }

  public func phase(
    afterSuccessOf operationReference: String,
    in phase: HarnessTaskPhase
  ) -> HarnessTaskPhase {
    switch (operationReference, phase) {
    case (Self.observeDevice, .initializing): return .reproducing
    case (Self.captureDiagnostics, .reproducing): return .collecting
    case (Self.applyPatch, .patching): return .building
    case (Self.deployHAP, .deploying): return .verifying
    case (Self.revertPatch, .deploying), (Self.revertPatch, .verifying): return .analyzing
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
      // The first capture of a task that owns a crash fixture establishes a
      // ledger watermark before the fixture is injected. Sampling liveness
      // there would turn the expected stopped process into a product failure
      // and prevent the injection. Every post-injection/ordinary capture is
      // application-specific.
      let baselineLeasePresent: Bool
      if case .string(let lease)? = snapshot?.goal.desiredState["baselineHapArtifactLease"] {
        baselineLeasePresent = !lease.isEmpty
      } else {
        baselineLeasePresent = false
      }
      let baselineInjected =
        snapshot?.observedState[Self.baselineDeploymentMarker] == .bool(true)
      let shouldObserveApplication =
        !baselineLeasePresent || baselineInjected || snapshot?.repairAttempt?.deployedDigest != nil
      if shouldObserveApplication,
        case .string(let bundle)? = snapshot?.goal.desiredState["bundleName"], !bundle.isEmpty
      {
        inputs["bundleName"] = .string(bundle)
        if case .string(let ability)? = snapshot?.goal.desiredState["abilityName"],
          !ability.isEmpty
        {
          inputs["abilityName"] = .string(ability)
        }
        if case .string(let process)? = snapshot?.goal.desiredState["processName"],
          !process.isEmpty
        {
          inputs["processName"] = .string(process)
        }
        if let digest = snapshot?.repairAttempt?.deployedDigest {
          inputs["expectedDeployedArtifactDigest"] = .string(digest)
        }
      }
      return inputs
    default:
      // `observe.device@1` declares no required input: the target it observes
      // comes from the request's target, not from an input field.
      return [:]
    }
  }

  private func desiredString(_ key: String, _ snapshot: HarnessTaskSnapshot) -> String? {
    guard case .string(let value)? = snapshot.goal.desiredState[key], !value.isEmpty else {
      return nil
    }
    return value
  }

  private func pendingAnalysisLease(_ snapshot: HarnessTaskSnapshot) -> String? {
    guard case .string(let value)? = snapshot.observedState[
      Self.pendingAnalysisSourceLeaseKey], !value.isEmpty
    else { return nil }
    return value
  }

  /// A fixture is injected only after a readable Faultlogger round established
  /// a device-local watermark. Otherwise an old crash could be attributed to
  /// this task. `repairAttempt == nil` separates this one-time reproduction
  /// deployment from the later verified-build deployment.
  private func baselineDeploymentReady(_ snapshot: HarnessTaskSnapshot) -> Bool {
    guard snapshot.phase == .collecting, snapshot.repairAttempt == nil,
      snapshot.observed.latestVerdict == .inconclusive,
      snapshot.observedState[Self.baselineDeploymentMarker] != .bool(true),
      desiredString("baselineHapArtifactLease", snapshot) != nil,
      desiredString("bundleName", snapshot) != nil,
      desiredString("abilityName", snapshot) != nil,
      case .string = snapshot.observed.measurements[HarnessObservationBuilder.watermarkMetric]
    else { return false }
    return true
  }

  /// One mutation injects the fault. Two more must remain available for the
  /// verified repair deployment and its mandatory rollback reserve.
  private func baselineDeploymentBudgetAvailable(_ snapshot: HarnessTaskSnapshot) -> Bool {
    snapshot.consumedBudget.e1Mutations + 3 <= snapshot.budgets.maxE1Mutations
  }

  private func noSafeAction(
    _ snapshot: HarnessTaskSnapshot,
    decisionID: String,
    round: Int,
    nowUTC: String,
    reasonCode: String,
    hypothesis: String
  ) -> HarnessPlannedStep {
    HarnessPlannedStep(
      decision: HarnessDecision(
        decisionID: decisionID, htaskID: snapshot.htaskID, round: round,
        kind: .noSafeAction, hypothesis: hypothesis, reasonCode: reasonCode,
        producer: producerID, createdAtUTC: nowUTC),
      phaseOnDispatch: nil)
  }

  private func invoke(
    _ snapshot: HarnessTaskSnapshot,
    decisionID: String,
    round: Int,
    nowUTC: String,
    operation: String,
    inputs: [String: JSONValue]? = nil,
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
        inputs: inputs ?? Self.typedInputs(for: operation, snapshot: snapshot),
        hypothesis: hypothesis,
        reasonCode: reasonCode,
        producer: producerID,
        createdAtUTC: nowUTC),
      phaseOnDispatch: phaseOnDispatch)
  }
}
