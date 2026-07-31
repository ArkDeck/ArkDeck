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
// So a decision now carries two things it can be checked against later:
// the task's state version, and a digest of the basis below. The guard
// recomputes the basis from a freshly loaded snapshot and refuses to
// dispatch when either moved (HFA-INV-2).
//
// Only persisted facts belong here. Anything that moves on its own - wall
// clock, elapsed seconds, timestamps - would make every decision stale a
// second after it was made, which is not a guard, it is an outage.

import CryptoKit
import Foundation

public struct HarnessDecisionBasis: Equatable, Sendable, Codable {
  public let htaskID: String
  public let stateVersion: Int
  public let status: HarnessTaskStatus
  public let phase: HarnessTaskPhase
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
    self.status = snapshot.status
    self.phase = snapshot.phase
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Why a decision was refused at the dispatch boundary.
///
/// Kept separate from `HarnessGuardRefusal`: a stale decision is not a
/// failed strategy. It costs the model call that produced it and nothing
/// else - no failure fingerprint, no no-progress round, no budget beyond
/// what was already spent. Charging it as a failure would let an operator's
/// own resolution push a task toward `strategyExhausted`.
public enum HarnessDecisionStaleness: Equatable, Sendable {
  case stateVersionMoved(observed: Int, current: Int)
  case basisChanged(observed: String, current: String)
  case activeJobAppeared(String)
  case cancelRequested
  case unverifiable

  public var reasonCode: String {
    switch self {
    case .stateVersionMoved(let observed, let current):
      return "decisionStale:stateVersion:\(observed)->\(current)"
    case .basisChanged(let observed, let current):
      return "decisionStale:basis:\(observed.prefix(12))->\(current.prefix(12))"
    case .activeJobAppeared(let jobID):
      return "decisionStale:activeJob:\(jobID)"
    case .cancelRequested:
      return "decisionStale:cancelRequested"
    case .unverifiable:
      return "decisionStale:unverifiable"
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
    against current: HarnessDecisionBasis
  ) -> HarnessDecisionStaleness? {
    guard decision.observedStateVersion > 0, !decision.basisDigest.isEmpty else {
      return .unverifiable
    }
    guard decision.htaskID == current.htaskID else { return .unverifiable }
    guard decision.observedStateVersion == current.stateVersion else {
      return .stateVersionMoved(
        observed: decision.observedStateVersion, current: current.stateVersion)
    }
    if let activeJobID = current.activeJobID {
      // One effectful active job per task is enforced by the reducer too;
      // catching it here means the job is never submitted in the first
      // place, rather than submitted and then refused by the state model.
      return .activeJobAppeared(activeJobID)
    }
    if current.cancelRequested { return .cancelRequested }
    let currentDigest = current.digest
    guard decision.basisDigest == currentDigest else {
      return .basisChanged(observed: decision.basisDigest, current: currentDigest)
    }
    return nil
  }
}
