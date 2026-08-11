// Typed harness task model and its sole state transition entry
// (CHG-2026-054, TASK-HTP-001).
//
// A harness task is the multi-round convergence unit that sits *above* a
// runtime job: it owns the goal, the budgets, the round counter and the
// stop conditions, while every side effect still happens through one
// typed runtime operation per round. Two naming rules are load bearing:
//
//   * `HTASK-*` (this file) is a runtime debug task. `TASK-*` in the
//     repository is a Git governance task. They are different namespaces;
//     a harness id never participates in runtime admission or
//     authorization, it travels as correlation provenance only
//     (CHG-2026-054 HTP-INV-12, PRODUCT-LOOP §13).
//   * lifecycle, stage and conditions are orthogonal. `succeeded`/`failed`
//     are lifecycle values, never stages, so a waiting or human-blocked task
//     keeps the product stage it will resume into. The domain and wire both
//     use these canonical names; there is no second lifecycle/stage vocabulary.
//
// Nothing here decides success: entering `succeeded` structurally requires
// an evaluation causation plus an evaluation id, and no evaluation engine
// exists yet (that is TASK-HTP-002). A model, a decision, or a caller
// cannot reach this state by asserting it (HTP-INV-1, HTP-INV-2).

import ArkDeckCore
import Foundation

/// Canonical task projection keys shared by the Harness encoder and bounded
/// consumers. The two legacy aliases remain read-only compatibility keys for
/// decision-context documents; new task projections write lifecycle/stage.
package enum HarnessTaskWireField {
  public static let lifecycle = "lifecycle"
  public static let stage = "stage"
  package static let legacyStatus = "status"
  package static let legacyPhase = "phase"
}

package enum HarnessTaskType: String, CaseIterable, Codable, Sendable {
  /// The only implemented handler. New types arrive as code plus tests,
  /// never as a user-supplied workflow document (no JSON workflow DSL).
  case debugCrash
}

package enum HarnessTaskLifecycle: String, CaseIterable, Sendable {
  case created
  case running
  case waiting
  case humanRequired
  case succeeded
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled: return true
    case .created, .running, .waiting, .humanRequired: return false
    }
  }

}

extension HarnessTaskLifecycle: Codable {}

/// Debug stage inside `running`. The graph is deliberately small and
/// acyclic apart from the analysis/evidence loop the bounded debug journey
/// actually needs.
package enum HarnessTaskStage: String, CaseIterable, Sendable {
  case initializing
  case reproducing
  case collecting
  case analyzing
  case patching
  case building
  case deploying
  case verifying
}

extension HarnessTaskStage: Codable {}

package enum HarnessTaskWaitReason: String, CaseIterable, Codable, Sendable {
  case userSuspended = "USER_SUSPENDED"
  case activeJob = "ACTIVE_JOB"
  case retryBackoff = "RETRY_BACKOFF"
  case deviceUnavailable = "DEVICE_UNAVAILABLE"
  case observationWindow = "OBSERVATION_WINDOW"
}

package enum HarnessTriState: String, CaseIterable, Codable, Sendable {
  case trueValue = "TRUE"
  case falseValue = "FALSE"
  case unknown = "UNKNOWN"
}

package enum HarnessTaskConditionName: String, CaseIterable, Codable, Sendable {
  case targetResolved = "TargetResolved"
  case deviceBound = "DeviceBound"
  case deviceReady = "DeviceReady"
  case workspaceReady = "WorkspaceReady"
  case reproductionConfirmed = "ReproductionConfirmed"
  case artifactsReady = "ArtifactsReady"
  case analysisReady = "AnalysisReady"
  case patchProposalReady = "PatchProposalReady"
  case patchApplied = "PatchApplied"
  case buildPassed = "BuildPassed"
  case buildOutputsReady = "BuildOutputsReady"
  case deploymentObserved = "DeploymentObserved"
  case verificationEvidenceReady = "VerificationEvidenceReady"
  case criteriaSatisfied = "CriteriaSatisfied"
}

package struct HarnessTaskCondition: Equatable, Codable, Sendable {
  public let name: HarnessTaskConditionName
  public let state: HarnessTriState
  public let reasonCode: String
  public let message: String?
  package let evidenceArtifactIDs: [String]
  public let observedAt: String?
  public let observedRevision: Int?

  enum CodingKeys: String, CodingKey {
    case name
    case state
    case reasonCode
    case message
    case evidenceArtifactIDs = "evidenceArtifactIds"
    case observedAt
    case observedRevision
  }

  public init(
    name: HarnessTaskConditionName,
    state: HarnessTriState,
    reasonCode: String,
    message: String? = nil,
    evidenceArtifactIDs: [String] = [],
    observedAt: String? = nil,
    observedRevision: Int? = nil
  ) {
    self.name = name
    self.state = state
    self.reasonCode = reasonCode
    self.message = message
    self.evidenceArtifactIDs = evidenceArtifactIDs
    self.observedAt = observedAt
    self.observedRevision = observedRevision
  }

  public static func unknown(
    _ name: HarnessTaskConditionName,
    reasonCode: String = "notObserved"
  ) -> Self {
    Self(name: name, state: .unknown, reasonCode: reasonCode)
  }
}

package enum HarnessTaskConditionSet {
  public static func unknown(reasonCode: String = "notObserved") -> [HarnessTaskCondition] {
    HarnessTaskConditionName.allCases.map {
      HarnessTaskCondition.unknown($0, reasonCode: reasonCode)
    }
  }

  package static func normalized(
    _ conditions: [HarnessTaskCondition],
    missingReasonCode: String = "notObserved"
  ) -> [HarnessTaskCondition] {
    let byName = Dictionary(conditions.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    return HarnessTaskConditionName.allCases.map {
      byName[$0] ?? .unknown($0, reasonCode: missingReasonCode)
    }
  }

  package static func replacing(
    _ conditions: [HarnessTaskCondition],
    with replacements: [HarnessTaskCondition]
  ) -> [HarnessTaskCondition] {
    normalized(conditions + replacements)
  }

  public static func value(
    _ name: HarnessTaskConditionName,
    in conditions: [HarnessTaskCondition]
  ) -> HarnessTaskCondition {
    conditions.first { $0.name == name } ?? .unknown(name)
  }
}

package struct HarnessTaskStageGate: Equatable, Sendable {
  public let from: HarnessTaskStage
  public let to: HarnessTaskStage
  package let requiredConditions: [HarnessTaskConditionName]

  public init(
    from: HarnessTaskStage,
    to: HarnessTaskStage,
    requiredConditions: [HarnessTaskConditionName]
  ) {
    self.from = from
    self.to = to
    self.requiredConditions = requiredConditions
  }
}

/// The complete stage graph is data. Every legal cell is therefore available
/// to contract tests, and every condition in a cell is enforced by the same
/// reducer path. Recovery/fallback edges keep their stage semantics but have
/// no positive gate: they retreat to analysis without claiming fresh facts.
package enum HarnessTaskStageGates {
  public static let all: [HarnessTaskStageGate] = [
    .init(
      from: .initializing, to: .reproducing,
      requiredConditions: [.targetResolved, .deviceBound, .deviceReady]),
    .init(
      from: .reproducing, to: .collecting,
      requiredConditions: [.targetResolved, .deviceBound, .deviceReady, .artifactsReady]),
    .init(
      from: .reproducing, to: .analyzing,
      requiredConditions: [.reproductionConfirmed, .artifactsReady]),
    .init(
      from: .collecting, to: .reproducing,
      requiredConditions: [.targetResolved, .deviceBound, .deviceReady]),
    .init(
      from: .collecting, to: .analyzing,
      requiredConditions: [.artifactsReady]),
    .init(from: .analyzing, to: .collecting, requiredConditions: []),
    .init(
      from: .analyzing, to: .patching,
      requiredConditions: [
        .workspaceReady, .reproductionConfirmed, .analysisReady, .patchProposalReady,
      ]),
    .init(
      from: .analyzing, to: .verifying,
      requiredConditions: [.analysisReady, .deploymentObserved, .verificationEvidenceReady]),
    .init(
      from: .patching, to: .building,
      requiredConditions: [.workspaceReady, .patchApplied]),
    .init(from: .patching, to: .analyzing, requiredConditions: []),
    .init(
      from: .building, to: .deploying,
      requiredConditions: [.workspaceReady, .patchApplied, .buildPassed, .buildOutputsReady]),
    .init(from: .building, to: .analyzing, requiredConditions: []),
    .init(
      from: .deploying, to: .verifying,
      requiredConditions: [.deviceBound, .deviceReady, .deploymentObserved]),
    .init(from: .deploying, to: .analyzing, requiredConditions: []),
    .init(
      from: .verifying, to: .collecting,
      requiredConditions: [.deviceBound, .deviceReady]),
    .init(
      from: .verifying, to: .analyzing,
      requiredConditions: [.artifactsReady]),
  ]

  public static func gate(
    from: HarnessTaskStage,
    to: HarnessTaskStage
  ) -> HarnessTaskStageGate? {
    all.first { $0.from == from && $0.to == to }
  }
}

package enum HarnessCriterionComparator: String, CaseIterable, Codable, Sendable {
  case equalTo
  case atMost
  case atLeast
  case absent
  case matches
}

/// Declared, machine-checkable success criterion. TASK-HTP-001 only
/// persists these; the evaluator that reads them is TASK-HTP-002, so a
/// task carrying criteria cannot yet be judged - it stops honestly instead
/// of being called successful.
package struct HarnessSuccessCriterion: Equatable, Sendable, Codable {
  package let criterionID: String
  package let metric: String
  package let comparator: HarnessCriterionComparator
  public let expected: JSONValue
  package let mandatory: Bool
  package let minimumSamples: Int
  /// Artifact names whose bytes must verify before this criterion may be
  /// judged at all. Absent evidence is inconclusive, never a pass.
  package let evidenceRequirements: [String]
  package let inconclusivePolicy: HarnessInconclusivePolicy

  enum CodingKeys: String, CodingKey {
    case criterionID = "criterionId"
    case metric
    case comparator
    case expected
    case mandatory
    case minimumSamples
    case evidenceRequirements
    case inconclusivePolicy
  }

  public init(
    criterionID: String,
    metric: String,
    comparator: HarnessCriterionComparator,
    expected: JSONValue,
    mandatory: Bool = true,
    minimumSamples: Int = 1,
    evidenceRequirements: [String] = [],
    inconclusivePolicy: HarnessInconclusivePolicy = .collectMoreEvidence
  ) {
    self.criterionID = criterionID
    self.metric = metric
    self.comparator = comparator
    self.expected = expected
    self.mandatory = mandatory
    self.minimumSamples = minimumSamples
    self.evidenceRequirements = evidenceRequirements
    self.inconclusivePolicy = inconclusivePolicy
  }

  /// Explicit decoding: a task.json written before the evidence and policy
  /// fields existed must still load, and it must load as the strict default
  /// (evidence required by name where declared, otherwise collect more).
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.criterionID = try container.decode(String.self, forKey: .criterionID)
    self.metric = try container.decode(String.self, forKey: .metric)
    self.comparator = try container.decode(HarnessCriterionComparator.self, forKey: .comparator)
    self.expected = try container.decode(JSONValue.self, forKey: .expected)
    self.mandatory = try container.decodeIfPresent(Bool.self, forKey: .mandatory) ?? true
    self.minimumSamples = try container.decodeIfPresent(Int.self, forKey: .minimumSamples) ?? 1
    self.evidenceRequirements =
      try container.decodeIfPresent([String].self, forKey: .evidenceRequirements) ?? []
    self.inconclusivePolicy =
      try container.decodeIfPresent(HarnessInconclusivePolicy.self, forKey: .inconclusivePolicy)
      ?? .collectMoreEvidence
  }
}

package struct HarnessTaskGoal: Equatable, Sendable, Codable {
  public let summary: String
  package let desiredState: [String: JSONValue]

  public init(summary: String, desiredState: [String: JSONValue] = [:]) {
    self.summary = summary
    self.desiredState = desiredState
  }
}

package struct HarnessTaskTargetReference: Equatable, Sendable, Codable {
  public let targetID: String
  /// Present means: execute against exactly this binding revision. The
  /// runtime, not the harness, enforces it; the harness only carries the
  /// operator's intent forward across rounds.
  package let expectedBindingRevision: Int?

  enum CodingKeys: String, CodingKey {
    case targetID = "targetId"
    case expectedBindingRevision
  }

  public init(targetID: String, expectedBindingRevision: Int? = nil) {
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
  }
}

package struct HarnessTaskBudgets: Equatable, Sendable, Codable {
  package let maxRounds: Int
  package let maxWallClockSeconds: Int
  package let maxArtifactBytes: Int
  package let maxE1Mutations: Int
  /// Consecutive evidence rounds that may make no measurable progress before
  /// the active strategy is closed. This is task data, not a process-global
  /// constant, so restart and daemon composition cannot change the bound.
  package let maxNoProgressRounds: Int
  /// Confirmed retries of one identical ActionRun. The first dispatch is not
  /// a retry; crash recovery reuses it and therefore does not consume this.
  package let maxActionRetriesPerRun: Int
  /// Ceiling on model calls (CHG-2026-055, TASK-HFA-011). Zero means the
  /// loop may not call a model at all, which is a legitimate configuration:
  /// the deterministic handler converges without one.
  package let maxModelCalls: Int

  enum CodingKeys: String, CodingKey {
    case maxRounds
    case maxWallClockSeconds
    case maxArtifactBytes
    case maxE1Mutations
    case maxNoProgressRounds
    case maxActionRetriesPerRun
    case maxModelCalls
  }

  public init(
    maxRounds: Int,
    maxWallClockSeconds: Int,
    maxArtifactBytes: Int,
    maxE1Mutations: Int,
    maxNoProgressRounds: Int = 2,
    maxActionRetriesPerRun: Int = 2,
    maxModelCalls: Int = 24
  ) {
    self.maxRounds = maxRounds
    self.maxWallClockSeconds = maxWallClockSeconds
    self.maxArtifactBytes = maxArtifactBytes
    self.maxE1Mutations = maxE1Mutations
    self.maxNoProgressRounds = maxNoProgressRounds
    self.maxActionRetriesPerRun = maxActionRetriesPerRun
    self.maxModelCalls = maxModelCalls
  }

  /// Historical task snapshots predate these ceilings. They remain readable
  /// under the strict defaults instead of silently becoming unbounded or
  /// failing recovery.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.maxRounds = try container.decode(Int.self, forKey: .maxRounds)
    self.maxWallClockSeconds = try container.decode(Int.self, forKey: .maxWallClockSeconds)
    self.maxArtifactBytes = try container.decode(Int.self, forKey: .maxArtifactBytes)
    self.maxE1Mutations = try container.decode(Int.self, forKey: .maxE1Mutations)
    self.maxNoProgressRounds =
      try container.decodeIfPresent(Int.self, forKey: .maxNoProgressRounds) ?? 2
    self.maxActionRetriesPerRun =
      try container.decodeIfPresent(Int.self, forKey: .maxActionRetriesPerRun) ?? 2
    self.maxModelCalls = try container.decodeIfPresent(Int.self, forKey: .maxModelCalls) ?? 24
  }

  /// Ceilings are part of the model, not of a caller's judgement: an
  /// unattended loop with an unbounded budget is the failure mode this
  /// whole plane exists to prevent.
  package static let ceiling = HarnessTaskBudgets(
    maxRounds: 64, maxWallClockSeconds: 24 * 3600, maxArtifactBytes: 2 << 30,
    maxE1Mutations: 32, maxNoProgressRounds: 32, maxActionRetriesPerRun: 16,
    maxModelCalls: 128)
}

package struct HarnessConsumedBudget: Equatable, Sendable, Codable {
  package let rounds: Int
  package let wallClockSeconds: Int
  package let artifactBytes: Int
  package let e1Mutations: Int
  package let modelCalls: Int

  public init(
    rounds: Int = 0,
    wallClockSeconds: Int = 0,
    artifactBytes: Int = 0,
    e1Mutations: Int = 0,
    modelCalls: Int = 0
  ) {
    self.rounds = rounds
    self.wallClockSeconds = wallClockSeconds
    self.artifactBytes = artifactBytes
    self.e1Mutations = e1Mutations
    self.modelCalls = modelCalls
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.rounds = try container.decode(Int.self, forKey: .rounds)
    self.wallClockSeconds = try container.decode(Int.self, forKey: .wallClockSeconds)
    self.artifactBytes = try container.decode(Int.self, forKey: .artifactBytes)
    self.e1Mutations = try container.decode(Int.self, forKey: .e1Mutations)
    self.modelCalls = try container.decodeIfPresent(Int.self, forKey: .modelCalls) ?? 0
  }

  func isMonotonic(from previous: HarnessConsumedBudget) -> Bool {
    rounds >= previous.rounds && wallClockSeconds >= previous.wallClockSeconds
      && artifactBytes >= previous.artifactBytes && e1Mutations >= previous.e1Mutations
      && modelCalls >= previous.modelCalls
  }
}

/// Task-level policy. The full guard (availability, effect ceiling,
/// failure memory, raw-command rejection) is TASK-HTP-003; what lands here
/// is the part the reducer and the coordinator cannot run without: the
/// closed set of operation references this task may ever submit.
package struct HarnessTaskPolicy: Equatable, Sendable, Codable {
  public let allowedOperations: [String]

  public init(allowedOperations: [String]) {
    self.allowedOperations = allowedOperations
  }
}

package struct HarnessTaskResult: Equatable, Sendable, Codable {
  public let outcome: HarnessTaskLifecycle
  public let reasonCode: String
  public let summary: String
  package let evaluationID: String?
  package let artifactRefs: [String]

  enum CodingKeys: String, CodingKey {
    case outcome
    case reasonCode
    case summary
    case evaluationID = "evaluationId"
    case artifactRefs
  }

  public init(
    outcome: HarnessTaskLifecycle,
    reasonCode: String,
    summary: String,
    evaluationID: String? = nil,
    artifactRefs: [String] = []
  ) {
    self.outcome = outcome
    self.reasonCode = reasonCode
    self.summary = summary
    self.evaluationID = evaluationID
    self.artifactRefs = artifactRefs
  }
}

package enum HarnessTaskCausation: String, CaseIterable, Codable, Sendable {
  case submitted
  case admitted
  case recovery
  case jobDispatched
  case jobObserved
  case evaluation
  case humanBlocked
  case humanResolved
  case pauseRequested
  case resumeRequested
  case cancelRequested
  case budgetExhausted
  case noSafeAction
  /// A typed observation changed one or more condition cells without
  /// changing the product stage (for example a transient disconnect).
  case conditionObserved
  /// A transported model call for the current patch question was rejected or
  /// failed. The task remains running and the spent call is durable, so the
  /// next wake may retry only while its declared model-call budget remains.
  case proposalRejected
  /// A proposal was refused at the dispatch boundary because the facts it
  /// was made on had moved (CHG-2026-055, TASK-HFA-002). It is recorded as
  /// its own causation so a reader can tell "we declined to act on stale
  /// facts" from "the strategy failed" - they have different consequences.
  case decisionStale
}

/// The reducer-owned part of a task: everything a transition may change.
/// Persisted inside every event so the event log alone can rebuild a
/// snapshot after a crash between the two writes.
package struct HarnessTaskProjection: Equatable, Sendable, Codable {
  public let lifecycle: HarnessTaskLifecycle
  public let stage: HarnessTaskStage
  public let waitReason: HarnessTaskWaitReason?
  package let conditions: [HarnessTaskCondition]
  public let activeRound: Int
  public let activeJobID: String?
  package let consumedBudget: HarnessConsumedBudget
  package let artifactRefs: [String]
  /// Cumulative observed state. Only an observation or an evaluation may
  /// write it (validated below), so a decision cannot describe the world.
  package let observedState: [String: JSONValue]
  package let latestEvaluationID: String?
  /// Consecutive rounds that changed nothing measurable. Durable because a
  /// restart must not reset the loop's patience.
  package let noProgressRounds: Int
  /// A cancel that arrived while an effectful job was still in flight.
  /// Cancellation completes only once that job is observed terminal: the
  /// harness never reports a task cancelled while a side effect it started
  /// may still be running.
  public let cancelRequested: Bool
  public let result: HarnessTaskResult?
  public let version: Int

  enum CodingKeys: String, CodingKey {
    case lifecycle
    case stage
    case waitReason
    case conditions
    case activeRound
    case activeJobID = "activeJobId"
    case consumedBudget
    case artifactRefs
    case observedState
    case latestEvaluationID = "latestEvaluationId"
    case noProgressRounds
    case cancelRequested
    case result
    case version
  }

  public init(
    lifecycle: HarnessTaskLifecycle,
    stage: HarnessTaskStage,
    activeRound: Int,
    activeJobID: String?,
    consumedBudget: HarnessConsumedBudget,
    artifactRefs: [String],
    observedState: [String: JSONValue] = [:],
    latestEvaluationID: String? = nil,
    noProgressRounds: Int = 0,
    cancelRequested: Bool,
    result: HarnessTaskResult?,
    version: Int,
    waitReason: HarnessTaskWaitReason? = nil,
    conditions: [HarnessTaskCondition] = HarnessTaskConditionSet.unknown()
  ) {
    self.lifecycle = lifecycle
    self.stage = stage
    self.waitReason =
      lifecycle == .waiting
      ? (waitReason ?? (activeJobID == nil ? .userSuspended : .activeJob)) : nil
    self.conditions = HarnessTaskConditionSet.normalized(conditions)
    self.activeRound = activeRound
    self.activeJobID = activeJobID
    self.consumedBudget = consumedBudget
    self.artifactRefs = artifactRefs
    self.observedState = observedState
    self.latestEvaluationID = latestEvaluationID
    self.noProgressRounds = noProgressRounds
    self.cancelRequested = cancelRequested
    self.result = result
    self.version = version
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedLifecycle = try container.decode(HarnessTaskLifecycle.self, forKey: .lifecycle)
    self.activeRound = try container.decode(Int.self, forKey: .activeRound)
    self.activeJobID = try container.decodeIfPresent(String.self, forKey: .activeJobID)
    let encodedWaitReason = try container.decodeIfPresent(
      HarnessTaskWaitReason.self, forKey: .waitReason)
    if decodedLifecycle == .waiting, encodedWaitReason == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .waitReason, in: container,
        debugDescription: "waiting lifecycle requires waitReason")
    }
    if decodedLifecycle != .waiting, encodedWaitReason != nil {
      throw DecodingError.dataCorruptedError(
        forKey: .waitReason, in: container,
        debugDescription: "waitReason is valid only while waiting")
    }
    self.lifecycle = decodedLifecycle
    self.waitReason = encodedWaitReason
    self.stage = try container.decode(HarnessTaskStage.self, forKey: .stage)
    let decodedConditions = try container.decodeIfPresent(
      [HarnessTaskCondition].self, forKey: .conditions)
    self.conditions = HarnessTaskConditionSet.normalized(
      decodedConditions ?? [],
      missingReasonCode: decodedConditions == nil ? "migratedWithoutObservation" : "notObserved")
    self.consumedBudget = try container.decode(
      HarnessConsumedBudget.self, forKey: .consumedBudget)
    self.artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs) ?? []
    self.observedState =
      try container.decodeIfPresent([String: JSONValue].self, forKey: .observedState) ?? [:]
    self.latestEvaluationID = try container.decodeIfPresent(
      String.self, forKey: .latestEvaluationID)
    self.noProgressRounds = try container.decodeIfPresent(Int.self, forKey: .noProgressRounds) ?? 0
    self.cancelRequested =
      try container.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
    self.result = try container.decodeIfPresent(HarnessTaskResult.self, forKey: .result)
    self.version = try container.decode(Int.self, forKey: .version)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lifecycle, forKey: .lifecycle)
    try container.encode(stage, forKey: .stage)
    try container.encodeIfPresent(waitReason, forKey: .waitReason)
    try container.encode(conditions, forKey: .conditions)
    try container.encode(activeRound, forKey: .activeRound)
    try container.encodeIfPresent(activeJobID, forKey: .activeJobID)
    try container.encode(consumedBudget, forKey: .consumedBudget)
    try container.encode(artifactRefs, forKey: .artifactRefs)
    try container.encode(observedState, forKey: .observedState)
    try container.encodeIfPresent(latestEvaluationID, forKey: .latestEvaluationID)
    try container.encode(noProgressRounds, forKey: .noProgressRounds)
    try container.encode(cancelRequested, forKey: .cancelRequested)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encode(version, forKey: .version)
  }
}

/// One requested state change. Callers describe *what they observed* and
/// *what it should mean*; the reducer decides whether that is legal.
package struct HarnessTaskTransition: Equatable, Sendable {
  package let causation: HarnessTaskCausation
  public let reasonCode: String
  public let lifecycle: HarnessTaskLifecycle
  public let stage: HarnessTaskStage
  public let waitReason: HarnessTaskWaitReason?
  package let conditions: [HarnessTaskCondition]
  public let activeRound: Int
  public let activeJobID: String?
  package let consumedBudget: HarnessConsumedBudget
  public let jobID: String?
  package let evaluationID: String?
  package let artifactRefs: [String]
  package let observedState: [String: JSONValue]?
  package let noProgressRounds: Int?
  public let cancelRequested: Bool
  public let result: HarnessTaskResult?
  package let atUTC: String

  public init(
    causation: HarnessTaskCausation,
    reasonCode: String,
    lifecycle: HarnessTaskLifecycle,
    stage: HarnessTaskStage,
    activeRound: Int,
    activeJobID: String?,
    consumedBudget: HarnessConsumedBudget,
    jobID: String? = nil,
    evaluationID: String? = nil,
    artifactRefs: [String] = [],
    observedState: [String: JSONValue]? = nil,
    noProgressRounds: Int? = nil,
    cancelRequested: Bool = false,
    result: HarnessTaskResult? = nil,
    atUTC: String,
    waitReason: HarnessTaskWaitReason? = nil,
    conditions: [HarnessTaskCondition] = HarnessTaskConditionSet.unknown()
  ) {
    self.causation = causation
    self.reasonCode = reasonCode
    self.lifecycle = lifecycle
    self.stage = stage
    self.waitReason = waitReason
    self.conditions = HarnessTaskConditionSet.normalized(conditions)
    self.activeRound = activeRound
    self.activeJobID = activeJobID
    self.consumedBudget = consumedBudget
    self.jobID = jobID
    self.evaluationID = evaluationID
    self.artifactRefs = artifactRefs
    self.observedState = observedState
    self.noProgressRounds = noProgressRounds
    self.cancelRequested = cancelRequested
    self.result = result
    self.atUTC = atUTC
  }
}

package struct HarnessTaskEvent: Equatable, Sendable, Codable {
  public static let documentType = "harness-task-event"
  public static let schemaVersion = "2.0.0"

  public let documentType: String
  public let schemaVersion: String
  package let htaskID: String
  public let sequence: Int
  package let atUTC: String
  package let causation: HarnessTaskCausation
  public let reasonCode: String
  package let fromLifecycle: HarnessTaskLifecycle
  package let toLifecycle: HarnessTaskLifecycle
  package let fromStage: HarnessTaskStage
  package let toStage: HarnessTaskStage
  public let jobID: String?
  package let evaluationID: String?
  package let resulting: HarnessTaskProjection

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case htaskID = "htaskId"
    case sequence
    case atUTC = "atUtc"
    case causation
    case reasonCode
    case fromLifecycle = "fromLifecycle"
    case toLifecycle = "toLifecycle"
    case fromStage = "fromStage"
    case toStage = "toStage"
    case jobID = "jobId"
    case evaluationID = "evaluationId"
    case resulting
  }

  public init(
    htaskID: String,
    sequence: Int,
    atUTC: String,
    causation: HarnessTaskCausation,
    reasonCode: String,
    fromLifecycle: HarnessTaskLifecycle,
    toLifecycle: HarnessTaskLifecycle,
    fromStage: HarnessTaskStage,
    toStage: HarnessTaskStage,
    jobID: String?,
    evaluationID: String?,
    resulting: HarnessTaskProjection
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.htaskID = htaskID
    self.sequence = sequence
    self.atUTC = atUTC
    self.causation = causation
    self.reasonCode = reasonCode
    self.fromLifecycle = fromLifecycle
    self.toLifecycle = toLifecycle
    self.fromStage = fromStage
    self.toStage = toStage
    self.jobID = jobID
    self.evaluationID = evaluationID
    self.resulting = resulting
  }
}

package struct HarnessTaskSnapshot: Equatable, Sendable, Codable {
  public static let documentType = "harness-task"
  public static let schemaVersion = "3.1.0"

  public let documentType: String
  public let schemaVersion: String
  package let htaskID: String
  public let type: HarnessTaskType
  /// Free text is admitted here and nowhere else: it never reaches
  /// execution, admission or a comparison.
  package let intakeDescription: String?
  public let projectRef: String?
  public let target: HarnessTaskTargetReference
  public let goal: HarnessTaskGoal
  package let successCriteria: [HarnessSuccessCriterion]
  package let budgets: HarnessTaskBudgets
  public let policy: HarnessTaskPolicy
  package let evolutionPolicy: HarnessEvolutionPolicy?
  package let evolutionWorkspace: HarnessEvolutionWorkspace?
  package let observedState: [String: JSONValue]
  public let createdAtUTC: String
  public let updatedAtUTC: String
  public let lifecycle: HarnessTaskLifecycle
  public let stage: HarnessTaskStage
  public let waitReason: HarnessTaskWaitReason?
  package let conditions: [HarnessTaskCondition]
  public let activeRound: Int
  public let activeJobID: String?
  package let consumedBudget: HarnessConsumedBudget
  package let artifactRefs: [String]
  package let latestEvaluationID: String?
  package let noProgressRounds: Int
  public let cancelRequested: Bool
  public let result: HarnessTaskResult?
  public let version: Int

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case htaskID = "htaskId"
    case type
    case intakeDescription
    case projectRef
    case target
    case goal
    case successCriteria
    case budgets
    case policy
    case evolutionPolicy
    case evolutionWorkspace
    case observedState
    case createdAtUTC = "createdAtUtc"
    case updatedAtUTC = "updatedAtUtc"
    case lifecycle
    case stage
    case waitReason
    case conditions
    case activeRound
    case activeJobID = "activeJobId"
    case consumedBudget
    case artifactRefs
    case latestEvaluationID = "latestEvaluationId"
    case noProgressRounds
    case cancelRequested
    case result
    case version
  }

  public init(
    htaskID: String,
    type: HarnessTaskType,
    intakeDescription: String?,
    projectRef: String?,
    target: HarnessTaskTargetReference,
    goal: HarnessTaskGoal,
    successCriteria: [HarnessSuccessCriterion],
    budgets: HarnessTaskBudgets,
    policy: HarnessTaskPolicy,
    evolutionPolicy: HarnessEvolutionPolicy? = nil,
    evolutionWorkspace: HarnessEvolutionWorkspace? = nil,
    observedState: [String: JSONValue] = [:],
    createdAtUTC: String,
    updatedAtUTC: String,
    lifecycle: HarnessTaskLifecycle = .created,
    stage: HarnessTaskStage = .initializing,
    activeRound: Int = 0,
    activeJobID: String? = nil,
    consumedBudget: HarnessConsumedBudget = HarnessConsumedBudget(),
    artifactRefs: [String] = [],
    latestEvaluationID: String? = nil,
    noProgressRounds: Int = 0,
    cancelRequested: Bool = false,
    result: HarnessTaskResult? = nil,
    version: Int = 1,
    waitReason: HarnessTaskWaitReason? = nil,
    conditions: [HarnessTaskCondition] = HarnessTaskConditionSet.unknown()
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.htaskID = htaskID
    self.type = type
    self.intakeDescription = intakeDescription
    self.projectRef = projectRef
    self.target = target
    self.goal = goal
    self.successCriteria = successCriteria
    self.budgets = budgets
    self.policy = policy
    self.evolutionPolicy = evolutionPolicy
    self.evolutionWorkspace = evolutionWorkspace
    self.observedState = observedState
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
    self.lifecycle = lifecycle
    self.stage = stage
    self.waitReason =
      lifecycle == .waiting
      ? (waitReason ?? (activeJobID == nil ? .userSuspended : .activeJob)) : nil
    self.conditions = HarnessTaskConditionSet.normalized(conditions)
    self.activeRound = activeRound
    self.activeJobID = activeJobID
    self.consumedBudget = consumedBudget
    self.artifactRefs = artifactRefs
    self.latestEvaluationID = latestEvaluationID
    self.noProgressRounds = noProgressRounds
    self.cancelRequested = cancelRequested
    self.result = result
    self.version = version
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.documentType = try container.decode(String.self, forKey: .documentType)
    self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    self.htaskID = try container.decode(String.self, forKey: .htaskID)
    self.type = try container.decode(HarnessTaskType.self, forKey: .type)
    self.intakeDescription = try container.decodeIfPresent(
      String.self, forKey: .intakeDescription)
    self.projectRef = try container.decodeIfPresent(String.self, forKey: .projectRef)
    self.target = try container.decode(HarnessTaskTargetReference.self, forKey: .target)
    self.goal = try container.decode(HarnessTaskGoal.self, forKey: .goal)
    self.successCriteria =
      try container.decodeIfPresent([HarnessSuccessCriterion].self, forKey: .successCriteria) ?? []
    self.budgets = try container.decode(HarnessTaskBudgets.self, forKey: .budgets)
    self.policy = try container.decode(HarnessTaskPolicy.self, forKey: .policy)
    self.evolutionPolicy = try container.decodeIfPresent(
      HarnessEvolutionPolicy.self, forKey: .evolutionPolicy)
    self.evolutionWorkspace = try container.decodeIfPresent(
      HarnessEvolutionWorkspace.self, forKey: .evolutionWorkspace)
    guard (evolutionPolicy == nil) == (evolutionWorkspace == nil) else {
      throw DecodingError.dataCorruptedError(
        forKey: .evolutionWorkspace, in: container,
        debugDescription: "evolutionPolicy and evolutionWorkspace must appear together")
    }
    self.observedState =
      try container.decodeIfPresent([String: JSONValue].self, forKey: .observedState) ?? [:]
    self.createdAtUTC = try container.decode(String.self, forKey: .createdAtUTC)
    self.updatedAtUTC = try container.decode(String.self, forKey: .updatedAtUTC)

    let decodedLifecycle = try container.decode(HarnessTaskLifecycle.self, forKey: .lifecycle)
    self.stage = try container.decode(HarnessTaskStage.self, forKey: .stage)
    self.activeRound = try container.decode(Int.self, forKey: .activeRound)
    self.activeJobID = try container.decodeIfPresent(String.self, forKey: .activeJobID)
    let encodedWaitReason = try container.decodeIfPresent(
      HarnessTaskWaitReason.self, forKey: .waitReason)
    if decodedLifecycle == .waiting, encodedWaitReason == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .waitReason, in: container,
        debugDescription: "waiting lifecycle requires waitReason")
    }
    if decodedLifecycle != .waiting, encodedWaitReason != nil {
      throw DecodingError.dataCorruptedError(
        forKey: .waitReason, in: container,
        debugDescription: "waitReason is valid only while waiting")
    }
    self.lifecycle = decodedLifecycle
    self.waitReason = encodedWaitReason
    let decodedConditions = try container.decodeIfPresent(
      [HarnessTaskCondition].self, forKey: .conditions)
    self.conditions = HarnessTaskConditionSet.normalized(
      decodedConditions ?? [],
      missingReasonCode: decodedConditions == nil ? "migratedWithoutObservation" : "notObserved")
    self.consumedBudget = try container.decode(
      HarnessConsumedBudget.self, forKey: .consumedBudget)
    self.artifactRefs = try container.decodeIfPresent([String].self, forKey: .artifactRefs) ?? []
    self.latestEvaluationID = try container.decodeIfPresent(
      String.self, forKey: .latestEvaluationID)
    self.noProgressRounds =
      try container.decodeIfPresent(
        Int.self, forKey: .noProgressRounds) ?? 0
    self.cancelRequested =
      try container.decodeIfPresent(
        Bool.self, forKey: .cancelRequested) ?? false
    self.result = try container.decodeIfPresent(HarnessTaskResult.self, forKey: .result)
    self.version = try container.decode(Int.self, forKey: .version)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(documentType, forKey: .documentType)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(htaskID, forKey: .htaskID)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(intakeDescription, forKey: .intakeDescription)
    try container.encodeIfPresent(projectRef, forKey: .projectRef)
    try container.encode(target, forKey: .target)
    try container.encode(goal, forKey: .goal)
    try container.encode(successCriteria, forKey: .successCriteria)
    try container.encode(budgets, forKey: .budgets)
    try container.encode(policy, forKey: .policy)
    try container.encodeIfPresent(evolutionPolicy, forKey: .evolutionPolicy)
    try container.encodeIfPresent(evolutionWorkspace, forKey: .evolutionWorkspace)
    try container.encode(observedState, forKey: .observedState)
    try container.encode(createdAtUTC, forKey: .createdAtUTC)
    try container.encode(updatedAtUTC, forKey: .updatedAtUTC)
    try container.encode(lifecycle, forKey: .lifecycle)
    try container.encode(stage, forKey: .stage)
    try container.encodeIfPresent(waitReason, forKey: .waitReason)
    try container.encode(conditions, forKey: .conditions)
    try container.encode(activeRound, forKey: .activeRound)
    try container.encodeIfPresent(activeJobID, forKey: .activeJobID)
    try container.encode(consumedBudget, forKey: .consumedBudget)
    try container.encode(artifactRefs, forKey: .artifactRefs)
    try container.encodeIfPresent(latestEvaluationID, forKey: .latestEvaluationID)
    try container.encode(noProgressRounds, forKey: .noProgressRounds)
    try container.encode(cancelRequested, forKey: .cancelRequested)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encode(version, forKey: .version)
  }

  /// The current product has no normal/evolution switch. A workspace policy is the single
  /// source of truth for isolation, validation and promotion behavior.
  package var requiresWorkspaceIsolation: Bool { evolutionPolicy != nil }
  /// Source project identity remains stable for memory/egress. Typed
  /// workspace operations use the isolated provider reference in Evolution.
  package var executionProjectRef: String? {
    evolutionWorkspace?.projectRef ?? projectRef
  }

  public func condition(_ name: HarnessTaskConditionName) -> HarnessTaskCondition {
    HarnessTaskConditionSet.value(name, in: conditions)
  }

  public var projection: HarnessTaskProjection {
    HarnessTaskProjection(
      lifecycle: lifecycle, stage: stage, activeRound: activeRound, activeJobID: activeJobID,
      consumedBudget: consumedBudget, artifactRefs: artifactRefs, observedState: observedState,
      latestEvaluationID: latestEvaluationID, noProgressRounds: noProgressRounds,
      cancelRequested: cancelRequested, result: result, version: version,
      waitReason: waitReason, conditions: conditions)
  }

  /// Typed view of the cumulative observed state.
  public var observed: HarnessObservedState {
    HarnessObservedState(json: observedState)
  }

  /// Rebuild a snapshot from an event's resulting projection. Used by the
  /// store when a crash landed between the event append and the snapshot
  /// replace: the log is the truth, the snapshot is a cache.
  package func applying(_ projection: HarnessTaskProjection, atUTC: String) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: htaskID, type: type, intakeDescription: intakeDescription,
      projectRef: projectRef, target: target, goal: goal, successCriteria: successCriteria,
      budgets: budgets, policy: policy,
      evolutionPolicy: evolutionPolicy, evolutionWorkspace: evolutionWorkspace,
      observedState: projection.observedState,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC, lifecycle: projection.lifecycle,
      stage: projection.stage, activeRound: projection.activeRound,
      activeJobID: projection.activeJobID, consumedBudget: projection.consumedBudget,
      artifactRefs: projection.artifactRefs, latestEvaluationID: projection.latestEvaluationID,
      noProgressRounds: projection.noProgressRounds,
      cancelRequested: projection.cancelRequested, result: projection.result,
      version: projection.version, waitReason: projection.waitReason,
      conditions: projection.conditions)
  }

}

package enum HarnessTaskTransitionError: Error, Equatable, Sendable {
  case terminal(HarnessTaskLifecycle)
  case illegalLifecycle(
    from: HarnessTaskLifecycle, to: HarnessTaskLifecycle, causation: HarnessTaskCausation)
  case illegalStage(from: HarnessTaskStage, to: HarnessTaskStage)
  case stageChangeOutsideRunning(HarnessTaskLifecycle)
  case dispatchRequiresRunning(HarnessTaskLifecycle)
  case jobAlreadyActive(String)
  case dispatchRequiresJobID
  case successRequiresEvaluation
  case terminalRequiresResult(HarnessTaskLifecycle)
  case resultOutcomeMismatch(HarnessTaskLifecycle)
  case roundRegressed(from: Int, to: Int)
  case budgetRegressed
  case artifactRefsShrank
  case activeJobOnTerminalTask
  case cancelPending
  case cancelRequestWithdrawn
  case observedStateRequiresEvidence(HarnessTaskCausation)
  case waitingRequiresReason
  case waitReasonOutsideWaiting(HarnessTaskWaitReason)
  case malformedConditionSet
  case conditionRevisionRegressed(
    HarnessTaskConditionName, from: Int, to: Int)
  case conditionChangeRequiresEvidence(HarnessTaskCausation)
  case stageGateUnsatisfied(
    from: HarnessTaskStage, to: HarnessTaskStage, condition: HarnessTaskConditionName,
    actual: HarnessTriState)
  case successRequiresCriteriaSatisfied(HarnessTriState)
}

/// The only component allowed to change a task's state.
///
/// It is pure: no clock, no storage, no runtime. Everything it needs is in
/// the previous snapshot and the requested transition, which is what makes
/// "no other write path exists" a checkable property rather than a habit.
package enum HarnessTaskStateReducer {
  public static func apply(
    _ transition: HarnessTaskTransition,
    to snapshot: HarnessTaskSnapshot
  ) throws -> (HarnessTaskSnapshot, HarnessTaskEvent) {
    guard !snapshot.lifecycle.isTerminal else {
      throw HarnessTaskTransitionError.terminal(snapshot.lifecycle)
    }
    try validateLifecycle(transition, snapshot)
    try validateConditions(transition, snapshot)
    try validateStage(transition, snapshot)
    try validateJob(transition, snapshot)
    try validateProgress(transition, snapshot)
    try validateObservation(transition, snapshot)
    try validateResult(transition)

    let projection = HarnessTaskProjection(
      lifecycle: transition.lifecycle,
      stage: transition.stage,
      activeRound: transition.activeRound,
      activeJobID: transition.activeJobID,
      consumedBudget: transition.consumedBudget,
      artifactRefs: transition.artifactRefs,
      observedState: transition.observedState ?? snapshot.observedState,
      latestEvaluationID: transition.evaluationID ?? snapshot.latestEvaluationID,
      noProgressRounds: transition.noProgressRounds ?? snapshot.noProgressRounds,
      cancelRequested: transition.cancelRequested,
      result: transition.result,
      version: snapshot.version + 1,
      waitReason: transition.waitReason,
      conditions: transition.conditions)
    let event = HarnessTaskEvent(
      htaskID: snapshot.htaskID,
      // The event log is append-only and one event per version: sequence
      // and version move together so a reader can join them without a
      // second index.
      sequence: snapshot.version,
      atUTC: transition.atUTC,
      causation: transition.causation,
      reasonCode: transition.reasonCode,
      fromLifecycle: snapshot.lifecycle,
      toLifecycle: transition.lifecycle,
      fromStage: snapshot.stage,
      toStage: transition.stage,
      jobID: transition.jobID,
      evaluationID: transition.evaluationID,
      resulting: projection)
    return (snapshot.applying(projection, atUTC: transition.atUTC), event)
  }

  private static func validateLifecycle(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    let allowed: Set<HarnessTaskLifecycle>
    switch snapshot.lifecycle {
    case .created:
      allowed = [.created, .running, .waiting, .humanRequired, .failed, .cancelled]
    case .running:
      allowed = [.running, .waiting, .humanRequired, .succeeded, .failed, .cancelled]
    case .waiting:
      allowed = [.waiting, .running, .humanRequired, .failed, .cancelled]
    case .humanRequired:
      allowed = [.humanRequired, .running, .failed, .cancelled]
    case .succeeded, .failed, .cancelled:
      allowed = []
    }
    guard allowed.contains(transition.lifecycle) else {
      throw HarnessTaskTransitionError.illegalLifecycle(
        from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
    }

    // Causation is not decoration: it is how a caller proves it is allowed
    // to ask for this state. A decision that claims success without an
    // evaluation is rejected here, at the only write path.
    switch transition.lifecycle {
    case .succeeded:
      guard transition.causation == .evaluation, transition.evaluationID != nil else {
        throw HarnessTaskTransitionError.successRequiresEvaluation
      }
    case .running where snapshot.lifecycle == .waiting:
      guard
        [.resumeRequested, .jobObserved, .recovery, .conditionObserved]
          .contains(transition.causation)
      else {
        throw HarnessTaskTransitionError.illegalLifecycle(
          from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
      }
    case .running where snapshot.lifecycle == .humanRequired:
      guard transition.causation == .humanResolved else {
        throw HarnessTaskTransitionError.illegalLifecycle(
          from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
      }
    case .waiting where transition.waitReason == .userSuspended:
      guard snapshot.waitReason == .userSuspended || transition.causation == .pauseRequested else {
        throw HarnessTaskTransitionError.illegalLifecycle(
          from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
      }
    case .cancelled:
      // Either the cancel arrived with no job in flight (cancelRequested)
      // or a previously requested cancel is finalising now that the job it
      // had to wait for is terminal (jobObserved / recovery).
      let finalisingPriorRequest =
        snapshot.cancelRequested
        && [.jobObserved, .recovery].contains(transition.causation)
      guard transition.causation == .cancelRequested || finalisingPriorRequest else {
        throw HarnessTaskTransitionError.illegalLifecycle(
          from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
      }
    case .failed:
      guard
        [.budgetExhausted, .noSafeAction, .jobObserved, .evaluation, .humanBlocked, .recovery]
          .contains(transition.causation)
      else {
        throw HarnessTaskTransitionError.illegalLifecycle(
          from: snapshot.lifecycle, to: transition.lifecycle, causation: transition.causation)
      }
    default:
      break
    }

    if transition.lifecycle == .waiting, transition.waitReason == nil {
      throw HarnessTaskTransitionError.waitingRequiresReason
    }
    if transition.lifecycle != .waiting, let reason = transition.waitReason {
      throw HarnessTaskTransitionError.waitReasonOutsideWaiting(reason)
    }
  }

  private static func validateStage(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    guard transition.stage != snapshot.stage else { return }
    // Lifecycle waits preserve the stage. A stage may advance when an
    // admitted job starts waiting or when that job's readback returns.
    let stageBearingLifecycle = transition.lifecycle == .running || transition.lifecycle == .waiting
    let stageBearingOrigin =
      snapshot.lifecycle == .running || snapshot.lifecycle == .created
      || (snapshot.lifecycle == .waiting && snapshot.activeJobID != nil)
    guard stageBearingLifecycle, stageBearingOrigin else {
      throw HarnessTaskTransitionError.stageChangeOutsideRunning(transition.lifecycle)
    }
    guard let gate = HarnessTaskStageGates.gate(from: snapshot.stage, to: transition.stage) else {
      throw HarnessTaskTransitionError.illegalStage(from: snapshot.stage, to: transition.stage)
    }
    for required in gate.requiredConditions {
      let actual = HarnessTaskConditionSet.value(required, in: transition.conditions).state
      guard actual == .trueValue else {
        throw HarnessTaskTransitionError.stageGateUnsatisfied(
          from: snapshot.stage, to: transition.stage, condition: required, actual: actual)
      }
    }
  }

  private static func validateConditions(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    let names = transition.conditions.map(\.name)
    guard names.count == HarnessTaskConditionName.allCases.count,
      Set(names).count == HarnessTaskConditionName.allCases.count
    else {
      throw HarnessTaskTransitionError.malformedConditionSet
    }
    let changed = transition.conditions != snapshot.conditions
    if changed,
      ![
        HarnessTaskCausation.jobDispatched, .jobObserved, .evaluation, .recovery,
        .conditionObserved,
      ].contains(transition.causation)
    {
      throw HarnessTaskTransitionError.conditionChangeRequiresEvidence(transition.causation)
    }
    for condition in transition.conditions {
      let previous = HarnessTaskConditionSet.value(condition.name, in: snapshot.conditions)
      if let from = previous.observedRevision, let to = condition.observedRevision, to < from {
        throw HarnessTaskTransitionError.conditionRevisionRegressed(
          condition.name, from: from, to: to)
      }
    }
    if transition.lifecycle == .succeeded {
      let actual = HarnessTaskConditionSet.value(
        .criteriaSatisfied, in: transition.conditions
      ).state
      guard actual == .trueValue else {
        throw HarnessTaskTransitionError.successRequiresCriteriaSatisfied(actual)
      }
    }
  }

  private static func validateJob(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    guard transition.cancelRequested || !snapshot.cancelRequested else {
      // A recorded cancel request is not retractable: withdrawing it would
      // let a task keep dispatching after the operator stopped it.
      throw HarnessTaskTransitionError.cancelRequestWithdrawn
    }
    if transition.causation == .jobDispatched {
      guard !snapshot.cancelRequested else {
        throw HarnessTaskTransitionError.cancelPending
      }
      guard transition.lifecycle == .waiting, transition.waitReason == .activeJob else {
        throw HarnessTaskTransitionError.dispatchRequiresRunning(transition.lifecycle)
      }
      if let active = snapshot.activeJobID {
        // One effectful active job per task, enforced in the state model
        // rather than only in the reconciler (HTP-INV-3).
        throw HarnessTaskTransitionError.jobAlreadyActive(active)
      }
      guard let jobID = transition.jobID, transition.activeJobID == jobID else {
        throw HarnessTaskTransitionError.dispatchRequiresJobID
      }
    }
    if transition.activeJobID != nil, transition.lifecycle.isTerminal {
      // Pausing or blocking on a human does not abandon an in-flight job -
      // the engine still owns it and the next wake observes it. A *terminal*
      // task claiming an active job would be the real inconsistency.
      throw HarnessTaskTransitionError.activeJobOnTerminalTask
    }
  }

  private static func validateProgress(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    guard transition.activeRound >= snapshot.activeRound else {
      throw HarnessTaskTransitionError.roundRegressed(
        from: snapshot.activeRound, to: transition.activeRound)
    }
    guard transition.consumedBudget.isMonotonic(from: snapshot.consumedBudget) else {
      throw HarnessTaskTransitionError.budgetRegressed
    }
    guard Set(snapshot.artifactRefs).isSubset(of: Set(transition.artifactRefs)) else {
      throw HarnessTaskTransitionError.artifactRefsShrank
    }
  }

  private static func validateObservation(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    guard let observed = transition.observedState, observed != snapshot.observedState else {
      return
    }
    // Observed state is evidence-derived by construction: only an observation
    // of a real job or an evaluation of real artifacts may write it. A
    // decision, a resume note or a cancel cannot (HTP-INV-1).
    guard [.jobObserved, .evaluation, .recovery].contains(transition.causation) else {
      throw HarnessTaskTransitionError.observedStateRequiresEvidence(transition.causation)
    }
  }

  private static func validateResult(_ transition: HarnessTaskTransition) throws {
    if transition.lifecycle.isTerminal {
      guard let result = transition.result else {
        throw HarnessTaskTransitionError.terminalRequiresResult(transition.lifecycle)
      }
      guard result.outcome == transition.lifecycle else {
        throw HarnessTaskTransitionError.resultOutcomeMismatch(transition.lifecycle)
      }
    }
  }
}
