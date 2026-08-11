// What a producer saw when it proposed a step (CHG-2026-055, TASK-HFA-002).
//
// A decision is only valid against the facts it was made on. Between the
// snapshot a producer read and the moment its step becomes a side effect
// there is at least one suspension point - the model call is a network
// round trip - and the coordinator is an actor, so `resume`, `pause` and
// `cancel` can land inside that window. Before this type existed the only
// thing standing between "the facts changed" and "the side effect happened
// anyway" was the optimistic lock in `store.commit`, which runs *after*
// submit: the job would already be dispatched, and only the bookkeeping
// would fail.
//
// So a decision carries the task version and basis digest below, plus an
// execution envelope for Attempt, model context, workspace, deployment and
// binding facts. The guard reloads those facts and refuses a never-submitted
// intent when any applicable dimension moved (HFA-INV-2).
//
// Only persisted facts belong here. Anything that moves on its own - wall
// clock, elapsed seconds, timestamps - would make every decision stale a
// second after it was made, which is not a guard, it is an outage.

import ArkDeckCore
import CryptoKit
import Foundation

public struct HarnessDecisionBasis: Equatable, Sendable, Codable {
  public let htaskID: String
  public let stateVersion: Int
  public let status: HarnessTaskLifecycle
  public let phase: HarnessTaskStage
  public let lifecycle: HarnessTaskLifecycle
  public let stage: HarnessTaskStage
  public let waitReason: HarnessTaskWaitReason?
  public let conditions: [HarnessTaskCondition]
  public let activeRound: Int
  public let activeJobID: String?
  public let cancelRequested: Bool
  public let expectedBindingRevision: Int?
  public let latestEvaluationID: String?
  public let observedState: [String: JSONValue]
  public let artifactRefs: [String]
  public let consumedBudget: HarnessConsumedBudget
  /// The operations the producer was allowed to choose from. Availability
  /// changing under a proposal is exactly the case a version counter alone
  /// does not catch: nothing about the task moved, but what it may do did.
  public let offeredOperations: [String]

  enum CodingKeys: String, CodingKey {
    case htaskID = "htaskId"
    case stateVersion
    case status
    case phase
    case lifecycle
    case stage
    case waitReason
    case conditions
    case activeRound
    case activeJobID = "activeJobId"
    case cancelRequested
    case expectedBindingRevision
    case latestEvaluationID = "latestEvaluationId"
    case observedState
    case artifactRefs
    case consumedBudget
    case offeredOperations
  }

  public init(snapshot: HarnessTaskSnapshot, offeredOperations: [String]) {
    self.htaskID = snapshot.htaskID
    self.stateVersion = snapshot.version
    self.status = snapshot.lifecycle
    self.phase = snapshot.stage
    self.lifecycle = snapshot.lifecycle
    self.stage = snapshot.stage
    self.waitReason = snapshot.waitReason
    self.conditions = snapshot.conditions
    self.activeRound = snapshot.activeRound
    self.activeJobID = snapshot.activeJobID
    self.cancelRequested = snapshot.cancelRequested
    self.expectedBindingRevision = snapshot.target.expectedBindingRevision
    self.latestEvaluationID = snapshot.latestEvaluationID
    self.observedState = snapshot.observedState
    self.artifactRefs = snapshot.artifactRefs
    self.consumedBudget = snapshot.consumedBudget
    self.offeredOperations = offeredOperations.sorted()
  }

  /// Canonical digest: sorted keys, no escaped slashes, no clock. Same
  /// persisted facts in, same digest out - on this process or the next one.
  public var digest: String {
    let encoder = CanonicalJSONEncoders.canonical()
    let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
    return SHA256Hex.string(of: data)
  }
}

/// Why a decision was refused at the dispatch boundary.
///
/// Kept separate from `HarnessGuardRefusal`: a stale decision is not a
/// failed strategy. It costs the model call that produced it and nothing
/// else - no failure fingerprint, no no-progress round, no budget beyond
/// what was already spent. Charging it as a failure would let an operator's
/// own resolution push a task toward `strategyExhausted`.
/// What was established about the workspace revision, as three outcomes
/// rather than one optional.
///
/// `nil` used to carry both "the workspace is at some other revision" and
/// "nothing answered", and the staleness check read the second as the first —
/// asserting a change that was never observed. They have different causes and
/// different fixes, so they are different values.
public enum HarnessWorkspaceRevisionReading: Equatable, Sendable {
  /// Nothing to establish: this decision pins no workspace revision.
  case notRequired
  case measured(String)
  /// The reading did not happen. The reason is carried so the stop that
  /// follows can name it instead of blaming the evidence.
  case unmeasurable(reason: String)
}

public struct HarnessDecisionExecutionFacts: Equatable, Sendable {
  public let activeAttemptID: String?
  public let workspaceRevision: HarnessWorkspaceRevisionReading
  public let deployedArtifactDigest: String?
  public let bindingRevision: Int?
  public let modelRunID: String?
  public let modelContextDigest: String?
  public let modelDecisionID: String?

  public init(
    activeAttemptID: String? = nil,
    workspaceRevision: HarnessWorkspaceRevisionReading = .notRequired,
    deployedArtifactDigest: String? = nil,
    bindingRevision: Int? = nil,
    modelRunID: String? = nil,
    modelContextDigest: String? = nil,
    modelDecisionID: String? = nil
  ) {
    self.activeAttemptID = activeAttemptID
    self.workspaceRevision = workspaceRevision
    self.deployedArtifactDigest = deployedArtifactDigest
    self.bindingRevision = bindingRevision
    self.modelRunID = modelRunID
    self.modelContextDigest = modelContextDigest
    self.modelDecisionID = modelDecisionID
  }
}

public enum HarnessDecisionStaleness: Equatable, Sendable {
  case taskStateChanged(observed: Int, current: Int)
  case attemptChanged(observed: String?, current: String?)
  case workspaceRevisionChanged(observed: String, current: String)
  /// The revision this decision pins could not be read at all. Not staleness
  /// in the sense the others are — nothing was observed to have moved — but it
  /// is equally a reason not to act on the decision.
  case workspaceRevisionUnmeasurable(observed: String, reason: String)
  case deployedArtifactChanged(observed: String, current: String?)
  case bindingRevisionChanged(observed: Int, current: Int?)
  case contextMismatch
  case basisMismatch(observed: String, current: String)
  case modelRunMissing(String?)
  case activeJobAppeared(String)
  case cancelRequested
  case unverifiable

  public var reasonCode: String {
    switch self {
    case .taskStateChanged(let observed, let current):
      return "STALE_DECISION:taskStateChanged:\(observed)->\(current)"
    case .attemptChanged(let observed, let current):
      return "STALE_DECISION:attemptChanged:\(observed ?? "none")->\(current ?? "none")"
    case .workspaceRevisionChanged(let observed, let current):
      return "STALE_DECISION:workspaceRevisionChanged:\(observed.prefix(12))->"
        + "\(current.prefix(12))"
    case .workspaceRevisionUnmeasurable(let observed, let reason):
      return "STALE_DECISION:workspaceRevisionUnmeasurable:\(observed.prefix(12)):\(reason)"
    case .deployedArtifactChanged(let observed, let current):
      return "STALE_DECISION:deployedArtifactChanged:\(observed.prefix(12))->"
        + "\((current ?? "none").prefix(12))"
    case .bindingRevisionChanged(let observed, let current):
      return "STALE_DECISION:bindingRevisionChanged:\(observed)->"
        + "\(current.map(String.init) ?? "none")"
    case .contextMismatch:
      return "STALE_DECISION:contextMismatch"
    case .basisMismatch(let observed, let current):
      return "STALE_DECISION:basisMismatch:\(observed.prefix(12))->\(current.prefix(12))"
    case .modelRunMissing(let modelRunID):
      return "STALE_DECISION:modelRunMissing:\(modelRunID ?? "none")"
    case .activeJobAppeared(let jobID):
      return "STALE_DECISION:taskStateChanged:activeJob:\(jobID)"
    case .cancelRequested:
      return "STALE_DECISION:taskStateChanged:cancelRequested"
    case .unverifiable:
      return "STALE_DECISION:unverifiable"
    }
  }
}

public enum HarnessDecisionFreshness {
  /// The single freshness check, run against a snapshot loaded *after* the
  /// proposal came back. Returns `nil` when the decision may proceed.
  ///
  /// A decision that carries no basis at all (a record written before this
  /// guard existed) is `unverifiable`, not "probably fine": fail closed.
  public static func staleness(
    of decision: HarnessDecision,
    against current: HarnessDecisionBasis,
    executionFacts: HarnessDecisionExecutionFacts? = nil
  ) -> HarnessDecisionStaleness? {
    guard decision.envelopeVersion == HarnessDecision.envelopeVersion,
      decision.observedStateVersion > 0, !decision.basisDigest.isEmpty
    else {
      return .unverifiable
    }
    guard decision.htaskID == current.htaskID else { return .unverifiable }
    guard decision.observedStateVersion == current.stateVersion else {
      return .taskStateChanged(
        observed: decision.observedStateVersion, current: current.stateVersion)
    }
    if let activeJobID = current.activeJobID {
      // One effectful active job per task is enforced by the reducer too;
      // catching it here means the job is never submitted in the first
      // place, rather than submitted and then refused by the state model.
      return .activeJobAppeared(activeJobID)
    }
    if current.cancelRequested { return .cancelRequested }
    if let facts = executionFacts {
      if decision.attemptID != facts.activeAttemptID {
        return .attemptChanged(observed: decision.attemptID, current: facts.activeAttemptID)
      }
      if let expected = decision.expectedWorkspaceRevision {
        switch facts.workspaceRevision {
        case .measured(let current) where current != expected:
          return .workspaceRevisionChanged(observed: expected, current: current)
        case .unmeasurable(let reason):
          return .workspaceRevisionUnmeasurable(observed: expected, reason: reason)
        case .measured, .notRequired:
          break
        }
      }
      if let expected = decision.expectedDeployedArtifactDigest,
        expected != facts.deployedArtifactDigest
      {
        return .deployedArtifactChanged(
          observed: expected, current: facts.deployedArtifactDigest)
      }
      if let expected = decision.expectedBindingRevision,
        expected != facts.bindingRevision
      {
        return .bindingRevisionChanged(observed: expected, current: facts.bindingRevision)
      }
      switch (decision.modelRunID, decision.contextDigest) {
      case (nil, nil):
        break
      case (let modelRunID?, let contextDigest?):
        guard facts.modelRunID == modelRunID else {
          return .modelRunMissing(modelRunID)
        }
        guard facts.modelContextDigest == contextDigest,
          facts.modelDecisionID == decision.decisionID
        else { return .contextMismatch }
      case (let modelRunID, _):
        return .modelRunMissing(modelRunID)
      }
    }
    let currentDigest = current.digest
    guard decision.basisDigest == currentDigest else {
      return .basisMismatch(observed: decision.basisDigest, current: currentDigest)
    }
    return nil
  }
}
