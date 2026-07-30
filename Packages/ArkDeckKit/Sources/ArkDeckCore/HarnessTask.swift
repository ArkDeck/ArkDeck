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
    case .collecting: return [.analyzing]
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

  enum CodingKeys: String, CodingKey {
    case criterionID = "criterionId"
    case metric
    case comparator
    case expected
    case mandatory
    case minimumSamples
  }

  public init(
    criterionID: String,
    metric: String,
    comparator: HarnessCriterionComparator,
    expected: JSONValue,
    mandatory: Bool = true,
    minimumSamples: Int = 1
  ) {
    self.criterionID = criterionID
    self.metric = metric
    self.comparator = comparator
    self.expected = expected
    self.mandatory = mandatory
    self.minimumSamples = minimumSamples
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

  public init(
    maxRounds: Int,
    maxWallClockSeconds: Int,
    maxArtifactBytes: Int,
    maxE1Mutations: Int
  ) {
    self.maxRounds = maxRounds
    self.maxWallClockSeconds = maxWallClockSeconds
    self.maxArtifactBytes = maxArtifactBytes
    self.maxE1Mutations = maxE1Mutations
  }

  /// Ceilings are part of the model, not of a caller's judgement: an
  /// unattended loop with an unbounded budget is the failure mode this
  /// whole plane exists to prevent.
  public static let ceiling = HarnessTaskBudgets(
    maxRounds: 64, maxWallClockSeconds: 24 * 3600, maxArtifactBytes: 2 << 30,
    maxE1Mutations: 32)
}

public struct HarnessConsumedBudget: Equatable, Sendable, Codable {
  public let rounds: Int
  public let wallClockSeconds: Int
  public let artifactBytes: Int
  public let e1Mutations: Int

  public init(
    rounds: Int = 0,
    wallClockSeconds: Int = 0,
    artifactBytes: Int = 0,
    e1Mutations: Int = 0
  ) {
    self.rounds = rounds
    self.wallClockSeconds = wallClockSeconds
    self.artifactBytes = artifactBytes
    self.e1Mutations = e1Mutations
  }

  func isMonotonic(from previous: HarnessConsumedBudget) -> Bool {
    rounds >= previous.rounds && wallClockSeconds >= previous.wallClockSeconds
      && artifactBytes >= previous.artifactBytes && e1Mutations >= previous.e1Mutations
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
    self.cancelRequested = cancelRequested
    self.result = result
    self.version = version
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
    self.cancelRequested = cancelRequested
    self.result = result
    self.version = version
  }

  public var projection: HarnessTaskProjection {
    HarnessTaskProjection(
      status: status, phase: phase, activeRound: activeRound, activeJobID: activeJobID,
      consumedBudget: consumedBudget, artifactRefs: artifactRefs,
      cancelRequested: cancelRequested, result: result, version: version)
  }

  /// Rebuild a snapshot from an event's resulting projection. Used by the
  /// store when a crash landed between the event append and the snapshot
  /// replace: the log is the truth, the snapshot is a cache.
  public func applying(_ projection: HarnessTaskProjection, atUTC: String) -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: htaskID, type: type, intakeDescription: intakeDescription,
      projectRef: projectRef, target: target, goal: goal, successCriteria: successCriteria,
      budgets: budgets, policy: policy, observedState: observedState,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC, status: projection.status,
      phase: projection.phase, activeRound: projection.activeRound,
      activeJobID: projection.activeJobID, consumedBudget: projection.consumedBudget,
      artifactRefs: projection.artifactRefs, cancelRequested: projection.cancelRequested,
      result: projection.result, version: projection.version)
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
    try validateResult(transition)

    let projection = HarnessTaskProjection(
      status: transition.status,
      phase: transition.phase,
      activeRound: transition.activeRound,
      activeJobID: transition.activeJobID,
      consumedBudget: transition.consumedBudget,
      artifactRefs: transition.artifactRefs,
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
