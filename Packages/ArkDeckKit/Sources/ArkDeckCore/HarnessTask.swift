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
//   * status and phase are orthogonal. `succeeded`/`failed` are statuses,
//     never phases, so a paused or human-blocked task keeps the phase it
//     will resume into.
//
// Nothing here decides success: entering `succeeded` structurally requires
// an evaluation causation plus an evaluation id, and no evaluation engine
// exists yet (that is TASK-HTP-002). A model, a decision, or a caller
// cannot reach this state by asserting it (HTP-INV-1, HTP-INV-2).

import Foundation

public enum HarnessTaskType: String, CaseIterable, Codable, Sendable {
  /// The only implemented handler. New types arrive as code plus tests,
  /// never as a user-supplied workflow document (no JSON workflow DSL).
  case debugCrash
}

public enum HarnessTaskStatus: String, CaseIterable, Codable, Sendable {
  case created
  case running
  case paused
  case humanRequired
  case succeeded
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled: return true
    case .created, .running, .paused, .humanRequired: return false
    }
  }
}

/// Debug phase inside `running`. The graph is deliberately small and
/// acyclic apart from the analysis/evidence loop the bounded debug journey
/// actually needs.
public enum HarnessTaskPhase: String, CaseIterable, Codable, Sendable {
  case initializing
  case deviceReady
  case reproducing
  case collecting
  case analyzing
  case patching
  case building
  case deploying
  case verifying

  /// Legal successors, excluding "stays in the same phase" which every
  /// phase allows.
  var successors: Set<HarnessTaskPhase> {
    switch self {
    case .initializing: return [.deviceReady]
    case .deviceReady: return [.reproducing, .collecting]
    case .reproducing: return [.collecting, .analyzing]
    // A debug task may establish the cumulative crash-ledger watermark in
    // `collecting` and only then inject its declared crash fixture. That
    // transition is deliberately one-way back through `reproducing`; the
    // fixture handler guards it with an immutable HAP lease and no repair
    // attempt, so ordinary evidence collection cannot cycle here.
    case .collecting: return [.reproducing, .analyzing]
    case .analyzing: return [.collecting, .patching, .verifying]
    case .patching: return [.building, .analyzing]
    case .building: return [.deploying, .analyzing]
    case .deploying: return [.verifying, .analyzing]
    case .verifying: return [.collecting, .analyzing]
    }
  }
}

public enum HarnessCriterionComparator: String, CaseIterable, Codable, Sendable {
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
public struct HarnessSuccessCriterion: Equatable, Sendable, Codable {
  public let criterionID: String
  public let metric: String
  public let comparator: HarnessCriterionComparator
  public let expected: JSONValue
  public let mandatory: Bool
  public let minimumSamples: Int
  /// Artifact names whose bytes must verify before this criterion may be
  /// judged at all. Absent evidence is inconclusive, never a pass.
  public let evidenceRequirements: [String]
  public let inconclusivePolicy: HarnessInconclusivePolicy

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

public struct HarnessTaskGoal: Equatable, Sendable, Codable {
  public let summary: String
  public let desiredState: [String: JSONValue]

  public init(summary: String, desiredState: [String: JSONValue] = [:]) {
    self.summary = summary
    self.desiredState = desiredState
  }
}

public struct HarnessTaskTargetReference: Equatable, Sendable, Codable {
  public let targetID: String
  /// Present means: execute against exactly this binding revision. The
  /// runtime, not the harness, enforces it; the harness only carries the
  /// operator's intent forward across rounds.
  public let expectedBindingRevision: Int?

  enum CodingKeys: String, CodingKey {
    case targetID = "targetId"
    case expectedBindingRevision
  }

  public init(targetID: String, expectedBindingRevision: Int? = nil) {
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
  }
}

public struct HarnessTaskBudgets: Equatable, Sendable, Codable {
  public let maxRounds: Int
  public let maxWallClockSeconds: Int
  public let maxArtifactBytes: Int
  public let maxE1Mutations: Int
  /// Consecutive evidence rounds that may make no measurable progress before
  /// the active strategy is closed. This is task data, not a process-global
  /// constant, so restart and daemon composition cannot change the bound.
  public let maxNoProgressRounds: Int
  /// Confirmed retries of one identical ActionRun. The first dispatch is not
  /// a retry; crash recovery reuses it and therefore does not consume this.
  public let maxActionRetriesPerRun: Int
  /// Ceiling on model calls (CHG-2026-055, TASK-HFA-011). Zero means the
  /// loop may not call a model at all, which is a legitimate configuration:
  /// the deterministic handler converges without one.
  public let maxModelCalls: Int

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
  public static let ceiling = HarnessTaskBudgets(
    maxRounds: 64, maxWallClockSeconds: 24 * 3600, maxArtifactBytes: 2 << 30,
    maxE1Mutations: 32, maxNoProgressRounds: 32, maxActionRetriesPerRun: 16,
    maxModelCalls: 128)
}

public struct HarnessConsumedBudget: Equatable, Sendable, Codable {
  public let rounds: Int
  public let wallClockSeconds: Int
  public let artifactBytes: Int
  public let e1Mutations: Int
  public let modelCalls: Int

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
public struct HarnessTaskPolicy: Equatable, Sendable, Codable {
  public let allowedOperations: [String]

  public init(allowedOperations: [String]) {
    self.allowedOperations = allowedOperations
  }
}

public struct HarnessTaskResult: Equatable, Sendable, Codable {
  public let outcome: HarnessTaskStatus
  public let reasonCode: String
  public let summary: String
  public let evaluationID: String?
  public let artifactRefs: [String]

  enum CodingKeys: String, CodingKey {
    case outcome
    case reasonCode
    case summary
    case evaluationID = "evaluationId"
    case artifactRefs
  }

  public init(
    outcome: HarnessTaskStatus,
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

public enum HarnessTaskCausation: String, CaseIterable, Codable, Sendable {
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
  /// A proposal was refused at the dispatch boundary because the facts it
  /// was made on had moved (CHG-2026-055, TASK-HFA-002). It is recorded as
  /// its own causation so a reader can tell "we declined to act on stale
  /// facts" from "the strategy failed" - they have different consequences.
  case decisionStale
}

/// The reducer-owned part of a task: everything a transition may change.
/// Persisted inside every event so the event log alone can rebuild a
/// snapshot after a crash between the two writes.
public struct HarnessTaskProjection: Equatable, Sendable, Codable {
  public let status: HarnessTaskStatus
  public let phase: HarnessTaskPhase
  public let activeRound: Int
  public let activeJobID: String?
  public let consumedBudget: HarnessConsumedBudget
  public let artifactRefs: [String]
  /// Cumulative observed state. Only an observation or an evaluation may
  /// write it (validated below), so a decision cannot describe the world.
  public let observedState: [String: JSONValue]
  public let latestEvaluationID: String?
  /// Consecutive rounds that changed nothing measurable. Durable because a
  /// restart must not reset the loop's patience.
  public let noProgressRounds: Int
  /// A cancel that arrived while an effectful job was still in flight.
  /// Cancellation completes only once that job is observed terminal: the
  /// harness never reports a task cancelled while a side effect it started
  /// may still be running.
  public let cancelRequested: Bool
  public let result: HarnessTaskResult?
  public let version: Int

  enum CodingKeys: String, CodingKey {
    case status
    case phase
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
    status: HarnessTaskStatus,
    phase: HarnessTaskPhase,
    activeRound: Int,
    activeJobID: String?,
    consumedBudget: HarnessConsumedBudget,
    artifactRefs: [String],
    observedState: [String: JSONValue] = [:],
    latestEvaluationID: String? = nil,
    noProgressRounds: Int = 0,
    cancelRequested: Bool,
    result: HarnessTaskResult?,
    version: Int
  ) {
    self.status = status
    self.phase = phase
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
    self.status = try container.decode(HarnessTaskStatus.self, forKey: .status)
    self.phase = try container.decode(HarnessTaskPhase.self, forKey: .phase)
    self.activeRound = try container.decode(Int.self, forKey: .activeRound)
    self.activeJobID = try container.decodeIfPresent(String.self, forKey: .activeJobID)
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
}

/// One requested state change. Callers describe *what they observed* and
/// *what it should mean*; the reducer decides whether that is legal.
public struct HarnessTaskTransition: Equatable, Sendable {
  public let causation: HarnessTaskCausation
  public let reasonCode: String
  public let status: HarnessTaskStatus
  public let phase: HarnessTaskPhase
  public let activeRound: Int
  public let activeJobID: String?
  public let consumedBudget: HarnessConsumedBudget
  public let jobID: String?
  public let evaluationID: String?
  public let artifactRefs: [String]
  public let observedState: [String: JSONValue]?
  public let noProgressRounds: Int?
  public let cancelRequested: Bool
  public let result: HarnessTaskResult?
  public let atUTC: String

  public init(
    causation: HarnessTaskCausation,
    reasonCode: String,
    status: HarnessTaskStatus,
    phase: HarnessTaskPhase,
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
    atUTC: String
  ) {
    self.causation = causation
    self.reasonCode = reasonCode
    self.status = status
    self.phase = phase
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

public struct HarnessTaskEvent: Equatable, Sendable, Codable {
  public static let documentType = "harness-task-event"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let htaskID: String
  public let sequence: Int
  public let atUTC: String
  public let causation: HarnessTaskCausation
  public let reasonCode: String
  public let fromStatus: HarnessTaskStatus
  public let toStatus: HarnessTaskStatus
  public let fromPhase: HarnessTaskPhase
  public let toPhase: HarnessTaskPhase
  public let jobID: String?
  public let evaluationID: String?
  public let resulting: HarnessTaskProjection

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case htaskID = "htaskId"
    case sequence
    case atUTC = "atUtc"
    case causation
    case reasonCode
    case fromStatus
    case toStatus
    case fromPhase
    case toPhase
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
    fromStatus: HarnessTaskStatus,
    toStatus: HarnessTaskStatus,
    fromPhase: HarnessTaskPhase,
    toPhase: HarnessTaskPhase,
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
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.fromPhase = fromPhase
    self.toPhase = toPhase
    self.jobID = jobID
    self.evaluationID = evaluationID
    self.resulting = resulting
  }
}

public struct HarnessTaskSnapshot: Equatable, Sendable, Codable {
  public static let documentType = "harness-task"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let htaskID: String
  public let type: HarnessTaskType
  /// Free text is admitted here and nowhere else: it never reaches
  /// execution, admission or a comparison.
  public let intakeDescription: String?
  public let projectRef: String?
  public let target: HarnessTaskTargetReference
  public let goal: HarnessTaskGoal
  public let successCriteria: [HarnessSuccessCriterion]
  public let budgets: HarnessTaskBudgets
  public let policy: HarnessTaskPolicy
  public let observedState: [String: JSONValue]
  public let createdAtUTC: String
  public let updatedAtUTC: String
  public let status: HarnessTaskStatus
  public let phase: HarnessTaskPhase
  public let activeRound: Int
  public let activeJobID: String?
  public let consumedBudget: HarnessConsumedBudget
  public let artifactRefs: [String]
  public let latestEvaluationID: String?
  public let noProgressRounds: Int
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
    case observedState
    case createdAtUTC = "createdAtUtc"
    case updatedAtUTC = "updatedAtUtc"
    case status
    case phase
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
    observedState: [String: JSONValue] = [:],
    createdAtUTC: String,
    updatedAtUTC: String,
    status: HarnessTaskStatus = .created,
    phase: HarnessTaskPhase = .initializing,
    activeRound: Int = 0,
    activeJobID: String? = nil,
    consumedBudget: HarnessConsumedBudget = HarnessConsumedBudget(),
    artifactRefs: [String] = [],
    latestEvaluationID: String? = nil,
    noProgressRounds: Int = 0,
    cancelRequested: Bool = false,
    result: HarnessTaskResult? = nil,
    version: Int = 1
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
    self.observedState = observedState
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
    self.status = status
    self.phase = phase
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

  public var projection: HarnessTaskProjection {
    HarnessTaskProjection(
      status: status, phase: phase, activeRound: activeRound, activeJobID: activeJobID,
      consumedBudget: consumedBudget, artifactRefs: artifactRefs, observedState: observedState,
      latestEvaluationID: latestEvaluationID, noProgressRounds: noProgressRounds,
      cancelRequested: cancelRequested, result: result, version: version)
  }

  /// Typed view of the cumulative observed state.
  public var observed: HarnessObservedState {
    HarnessObservedState(json: observedState)
  }

  /// Rebuild a snapshot from an event's resulting projection. Used by the
  /// store when a crash landed between the event append and the snapshot
  /// replace: the log is the truth, the snapshot is a cache.
  public func applying(_ projection: HarnessTaskProjection, atUTC: String) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: htaskID, type: type, intakeDescription: intakeDescription,
      projectRef: projectRef, target: target, goal: goal, successCriteria: successCriteria,
      budgets: budgets, policy: policy, observedState: projection.observedState,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC, status: projection.status,
      phase: projection.phase, activeRound: projection.activeRound,
      activeJobID: projection.activeJobID, consumedBudget: projection.consumedBudget,
      artifactRefs: projection.artifactRefs, latestEvaluationID: projection.latestEvaluationID,
      noProgressRounds: projection.noProgressRounds,
      cancelRequested: projection.cancelRequested, result: projection.result,
      version: projection.version)
  }
}

public enum HarnessTaskTransitionError: Error, Equatable, Sendable {
  case terminal(HarnessTaskStatus)
  case illegalStatus(from: HarnessTaskStatus, to: HarnessTaskStatus, causation: HarnessTaskCausation)
  case illegalPhase(from: HarnessTaskPhase, to: HarnessTaskPhase)
  case phaseChangeOutsideRunning(HarnessTaskStatus)
  case dispatchRequiresRunning(HarnessTaskStatus)
  case jobAlreadyActive(String)
  case dispatchRequiresJobID
  case successRequiresEvaluation
  case terminalRequiresResult(HarnessTaskStatus)
  case resultOutcomeMismatch(HarnessTaskStatus)
  case roundRegressed(from: Int, to: Int)
  case budgetRegressed
  case artifactRefsShrank
  case activeJobOnTerminalTask
  case cancelPending
  case cancelRequestWithdrawn
  case observedStateRequiresEvidence(HarnessTaskCausation)
}

/// The only component allowed to change a task's state.
///
/// It is pure: no clock, no storage, no runtime. Everything it needs is in
/// the previous snapshot and the requested transition, which is what makes
/// "no other write path exists" a checkable property rather than a habit.
public enum HarnessTaskStateReducer {
  public static func apply(
    _ transition: HarnessTaskTransition,
    to snapshot: HarnessTaskSnapshot
  ) throws -> (HarnessTaskSnapshot, HarnessTaskEvent) {
    guard !snapshot.status.isTerminal else {
      throw HarnessTaskTransitionError.terminal(snapshot.status)
    }
    try validateStatus(transition, snapshot)
    try validatePhase(transition, snapshot)
    try validateJob(transition, snapshot)
    try validateProgress(transition, snapshot)
    try validateObservation(transition, snapshot)
    try validateResult(transition)

    let projection = HarnessTaskProjection(
      status: transition.status,
      phase: transition.phase,
      activeRound: transition.activeRound,
      activeJobID: transition.activeJobID,
      consumedBudget: transition.consumedBudget,
      artifactRefs: transition.artifactRefs,
      observedState: transition.observedState ?? snapshot.observedState,
      latestEvaluationID: transition.evaluationID ?? snapshot.latestEvaluationID,
      noProgressRounds: transition.noProgressRounds ?? snapshot.noProgressRounds,
      cancelRequested: transition.cancelRequested,
      result: transition.result,
      version: snapshot.version + 1)
    let event = HarnessTaskEvent(
      htaskID: snapshot.htaskID,
      // The event log is append-only and one event per version: sequence
      // and version move together so a reader can join them without a
      // second index.
      sequence: snapshot.version,
      atUTC: transition.atUTC,
      causation: transition.causation,
      reasonCode: transition.reasonCode,
      fromStatus: snapshot.status,
      toStatus: transition.status,
      fromPhase: snapshot.phase,
      toPhase: transition.phase,
      jobID: transition.jobID,
      evaluationID: transition.evaluationID,
      resulting: projection)
    return (snapshot.applying(projection, atUTC: transition.atUTC), event)
  }

  private static func validateStatus(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    let allowed: Set<HarnessTaskStatus>
    switch snapshot.status {
    case .created:
      allowed = [.created, .running, .humanRequired, .failed, .cancelled]
    case .running:
      allowed = [.running, .paused, .humanRequired, .succeeded, .failed, .cancelled]
    case .paused:
      allowed = [.paused, .running, .cancelled]
    case .humanRequired:
      allowed = [.humanRequired, .running, .failed, .cancelled]
    case .succeeded, .failed, .cancelled:
      allowed = []
    }
    guard allowed.contains(transition.status) else {
      throw HarnessTaskTransitionError.illegalStatus(
        from: snapshot.status, to: transition.status, causation: transition.causation)
    }

    // Causation is not decoration: it is how a caller proves it is allowed
    // to ask for this state. A decision that claims success without an
    // evaluation is rejected here, at the only write path.
    switch transition.status {
    case .succeeded:
      guard transition.causation == .evaluation, transition.evaluationID != nil else {
        throw HarnessTaskTransitionError.successRequiresEvaluation
      }
    case .running where snapshot.status == .paused:
      guard transition.causation == .resumeRequested else {
        throw HarnessTaskTransitionError.illegalStatus(
          from: snapshot.status, to: transition.status, causation: transition.causation)
      }
    case .running where snapshot.status == .humanRequired:
      guard transition.causation == .humanResolved else {
        throw HarnessTaskTransitionError.illegalStatus(
          from: snapshot.status, to: transition.status, causation: transition.causation)
      }
    case .paused:
      guard transition.causation == .pauseRequested else {
        throw HarnessTaskTransitionError.illegalStatus(
          from: snapshot.status, to: transition.status, causation: transition.causation)
      }
    case .cancelled:
      // Either the cancel arrived with no job in flight (cancelRequested)
      // or a previously requested cancel is finalising now that the job it
      // had to wait for is terminal (jobObserved / recovery).
      let finalisingPriorRequest =
        snapshot.cancelRequested
        && [.jobObserved, .recovery].contains(transition.causation)
      guard transition.causation == .cancelRequested || finalisingPriorRequest else {
        throw HarnessTaskTransitionError.illegalStatus(
          from: snapshot.status, to: transition.status, causation: transition.causation)
      }
    case .failed:
      guard
        [.budgetExhausted, .noSafeAction, .jobObserved, .evaluation, .humanBlocked, .recovery]
          .contains(transition.causation)
      else {
        throw HarnessTaskTransitionError.illegalStatus(
          from: snapshot.status, to: transition.status, causation: transition.causation)
      }
    default:
      break
    }
  }

  private static func validatePhase(
    _ transition: HarnessTaskTransition,
    _ snapshot: HarnessTaskSnapshot
  ) throws {
    guard transition.phase != snapshot.phase else { return }
    // Leaving `running` preserves the phase so a resume returns to the
    // same point; only a running task advances the debug phase.
    guard transition.status == .running, snapshot.status == .running || snapshot.status == .created
    else {
      throw HarnessTaskTransitionError.phaseChangeOutsideRunning(transition.status)
    }
    guard snapshot.phase.successors.contains(transition.phase) else {
      throw HarnessTaskTransitionError.illegalPhase(from: snapshot.phase, to: transition.phase)
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
      guard transition.status == .running else {
        throw HarnessTaskTransitionError.dispatchRequiresRunning(transition.status)
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
    if transition.activeJobID != nil, transition.status.isTerminal {
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
    if transition.status.isTerminal {
      guard let result = transition.result else {
        throw HarnessTaskTransitionError.terminalRequiresResult(transition.status)
      }
      guard result.outcome == transition.status else {
        throw HarnessTaskTransitionError.resultOutcomeMismatch(transition.status)
      }
    }
  }
}
