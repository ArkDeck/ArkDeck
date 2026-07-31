// Strategy-level Attempt model (CHG-2026-055, TASK-HFA-004).
//
// A runtime dispatch is an ActionRun; a source-repair strategy is an Attempt.
// Keeping those identities separate prevents a transient retry from looking
// like a new strategy, and prevents the same failed patch from looking new
// merely because its free-text hypothesis was rewritten.

import CryptoKit
import Foundation

public enum HarnessStrategyDescriptorError: Error, Equatable, Sendable {
  case emptyField(String)
  case invalidDigest(String)
}

/// Target, toolchain and expected readback are one of the seven canonical
/// strategy elements. They are grouped so the top-level fingerprint shape
/// remains the reviewed seven-element shape while retaining each exact fact.
public struct HarnessStrategyExecutionExpectation: Equatable, Sendable, Codable {
  public let targetProfile: String
  public let toolchainProfile: String
  public let expectedNextObservation: String

  public init(
    targetProfile: String,
    toolchainProfile: String,
    expectedNextObservation: String
  ) {
    self.targetProfile = targetProfile
    self.toolchainProfile = toolchainProfile
    self.expectedNextObservation = expectedNextObservation
  }
}

/// The seven canonical inputs to `strategyFingerprint`.
///
/// `hypothesis` prose is deliberately absent. `hypothesisClass` is the
/// stable machine reason (for example `modelProposal`), not model prose.
public struct HarnessStrategyDescriptor: Equatable, Sendable, Codable {
  public let hypothesisClass: String
  public let selectedOperationFamily: String
  public let patchFingerprint: String
  public let baseWorkspaceRevision: String
  public let artifactSourceSet: [String]
  public let prerequisiteSet: [String]
  public let executionExpectation: HarnessStrategyExecutionExpectation

  public init(
    hypothesisClass: String,
    selectedOperationFamily: String,
    patchFingerprint: String,
    baseWorkspaceRevision: String,
    artifactSourceSet: [String],
    prerequisiteSet: [String],
    executionExpectation: HarnessStrategyExecutionExpectation
  ) throws {
    for (name, value) in [
      ("hypothesisClass", hypothesisClass),
      ("selectedOperationFamily", selectedOperationFamily),
      ("targetProfile", executionExpectation.targetProfile),
      ("toolchainProfile", executionExpectation.toolchainProfile),
      ("expectedNextObservation", executionExpectation.expectedNextObservation),
    ] where value.isEmpty {
      throw HarnessStrategyDescriptorError.emptyField(name)
    }
    guard Self.isSHA256(patchFingerprint) else {
      throw HarnessStrategyDescriptorError.invalidDigest("patchFingerprint")
    }
    guard Self.isSHA256(baseWorkspaceRevision) else {
      throw HarnessStrategyDescriptorError.invalidDigest("baseWorkspaceRevision")
    }
    self.hypothesisClass = hypothesisClass
    self.selectedOperationFamily = selectedOperationFamily
    self.patchFingerprint = patchFingerprint
    self.baseWorkspaceRevision = baseWorkspaceRevision
    self.artifactSourceSet = Array(Set(artifactSourceSet)).sorted()
    self.prerequisiteSet = Array(Set(prerequisiteSet)).sorted()
    self.executionExpectation = executionExpectation
  }

  /// Canonical JSON is the fingerprint material. No delimiter joining and
  /// no dictionary iteration order can make two distinct strategies collide.
  public var canonicalJSON: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }

  public var fingerprint: String {
    SHA256.hash(data: canonicalJSON).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

public enum HarnessAttemptOutcome: String, CaseIterable, Codable, Sendable {
  case active
  case succeeded
  case failed
  case noProgress
  case reverted
  case superseded
  case humanRequired
  case cancelled

  public var isClosed: Bool { self != .active }
}

public struct HarnessAttempt: Equatable, Sendable, Codable {
  public static let documentType = "harness-attempt"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let attemptID: String
  public let htaskID: String
  public let ordinal: Int
  public let hypothesis: String
  public let strategy: HarnessStrategyDescriptor
  public let strategyFingerprint: String
  public let baseRevision: String
  public let patchRevision: String?
  public let outcome: HarnessAttemptOutcome
  public let failureFingerprint: String?
  public let actionRunIDs: [String]
  public let evaluationIDs: [String]
  public let confirmedFacts: [String]
  public let disprovedFacts: [String]
  public let createdAtUTC: String
  public let updatedAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case attemptID = "attemptId"
    case htaskID = "htaskId"
    case ordinal
    case hypothesis
    case strategy
    case strategyFingerprint
    case baseRevision
    case patchRevision
    case outcome
    case failureFingerprint
    case actionRunIDs = "actionRunIds"
    case evaluationIDs = "evaluationIds"
    case confirmedFacts
    case disprovedFacts
    case createdAtUTC = "createdAtUtc"
    case updatedAtUTC = "updatedAtUtc"
  }

  public init(
    attemptID: String,
    htaskID: String,
    ordinal: Int,
    hypothesis: String,
    strategy: HarnessStrategyDescriptor,
    patchRevision: String? = nil,
    outcome: HarnessAttemptOutcome = .active,
    failureFingerprint: String? = nil,
    actionRunIDs: [String] = [],
    evaluationIDs: [String] = [],
    confirmedFacts: [String] = [],
    disprovedFacts: [String] = [],
    createdAtUTC: String,
    updatedAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.attemptID = attemptID
    self.htaskID = htaskID
    self.ordinal = ordinal
    self.hypothesis = hypothesis
    self.strategy = strategy
    self.strategyFingerprint = strategy.fingerprint
    self.baseRevision = strategy.baseWorkspaceRevision
    self.patchRevision = patchRevision
    self.outcome = outcome
    self.failureFingerprint = failureFingerprint
    self.actionRunIDs = Self.unique(actionRunIDs)
    self.evaluationIDs = Self.unique(evaluationIDs)
    self.confirmedFacts = Self.unique(confirmedFacts).sorted()
    self.disprovedFacts = Self.unique(disprovedFacts).sorted()
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
  }

  public func recordingActionRun(_ actionRunID: String, atUTC: String) -> HarnessAttempt {
    derived(actionRunIDs: actionRunIDs + [actionRunID], updatedAtUTC: atUTC)
  }

  public func recordingPatchRevision(_ revision: String, atUTC: String) -> HarnessAttempt {
    derived(patchRevision: revision, updatedAtUTC: atUTC)
  }

  public func recordingFailure(
    _ fingerprint: String,
    outcome: HarnessAttemptOutcome = .failed,
    atUTC: String
  ) -> HarnessAttempt {
    derived(outcome: outcome, failureFingerprint: fingerprint, updatedAtUTC: atUTC)
  }

  public func recordingEvaluation(
    _ evaluationID: String,
    confirmedFacts: [String],
    disprovedFacts: [String],
    outcome: HarnessAttemptOutcome? = nil,
    atUTC: String
  ) -> HarnessAttempt {
    derived(
      outcome: outcome ?? self.outcome,
      evaluationIDs: evaluationIDs + [evaluationID],
      confirmedFacts: self.confirmedFacts + confirmedFacts,
      disprovedFacts: self.disprovedFacts + disprovedFacts,
      updatedAtUTC: atUTC)
  }

  public func closing(_ outcome: HarnessAttemptOutcome, atUTC: String) -> HarnessAttempt {
    derived(outcome: outcome, updatedAtUTC: atUTC)
  }

  private func derived(
    patchRevision: String? = nil,
    outcome: HarnessAttemptOutcome? = nil,
    failureFingerprint: String? = nil,
    actionRunIDs: [String]? = nil,
    evaluationIDs: [String]? = nil,
    confirmedFacts: [String]? = nil,
    disprovedFacts: [String]? = nil,
    updatedAtUTC: String
  ) -> HarnessAttempt {
    HarnessAttempt(
      attemptID: attemptID, htaskID: htaskID, ordinal: ordinal,
      hypothesis: hypothesis, strategy: strategy,
      patchRevision: patchRevision ?? self.patchRevision,
      outcome: outcome ?? self.outcome,
      failureFingerprint: failureFingerprint ?? self.failureFingerprint,
      actionRunIDs: actionRunIDs ?? self.actionRunIDs,
      evaluationIDs: evaluationIDs ?? self.evaluationIDs,
      confirmedFacts: confirmedFacts ?? self.confirmedFacts,
      disprovedFacts: disprovedFacts ?? self.disprovedFacts,
      createdAtUTC: createdAtUTC, updatedAtUTC: updatedAtUTC)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}

public enum HarnessAttemptEventKind: String, CaseIterable, Codable, Sendable {
  case created
  case actionRunRecorded
  case patchRevisionObserved
  case failureRecorded
  case evaluationRecorded
  case closed
}

public struct HarnessAttemptEvent: Equatable, Sendable, Codable {
  public static let documentType = "harness-attempt-event"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let htaskID: String
  public let attemptID: String
  public let sequence: Int
  public let kind: HarnessAttemptEventKind
  public let reasonCode: String
  public let atUTC: String
  public let resulting: HarnessAttempt

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case htaskID = "htaskId"
    case attemptID = "attemptId"
    case sequence
    case kind
    case reasonCode
    case atUTC = "atUtc"
    case resulting
  }

  public init(
    sequence: Int,
    kind: HarnessAttemptEventKind,
    reasonCode: String,
    atUTC: String,
    resulting: HarnessAttempt
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.htaskID = resulting.htaskID
    self.attemptID = resulting.attemptID
    self.sequence = sequence
    self.kind = kind
    self.reasonCode = reasonCode
    self.atUTC = atUTC
    self.resulting = resulting
  }
}

public enum HarnessAttemptRoute: Equatable, Sendable {
  case newAttempt(ordinal: Int)
  case continueAttempt(attemptID: String)
  case actionRetry(attemptID: String, retryOrdinal: Int)
  case crashReplay(attemptID: String, actionRunID: String)
  case duplicateStrategy(attemptID: String)
  case actionRetryBudgetExhausted(attemptID: String, retries: Int)
}

/// Pure classifier for the §10.2 split. Recovery is first because it must
/// reuse the original ActionRun/idempotency key; a confirmed retry creates a
/// new ActionRun; a semantic duplicate never dispatches.
public enum HarnessAttemptPlanner {
  public static func classify(
    attempts: [HarnessAttempt],
    candidateStrategyFingerprint: String,
    identicalActionRunCount: Int,
    failure: HarnessFailureFingerprint?,
    retrySafe: Bool,
    originalUnresolvedActionRunID: String? = nil,
    maxActionRetriesPerRun: Int
  ) -> HarnessAttemptRoute {
    if let originalUnresolvedActionRunID,
      let active = attempts.last(where: { $0.outcome == .active })
    {
      return .crashReplay(
        attemptID: active.attemptID, actionRunID: originalUnresolvedActionRunID)
    }
    guard let existing = attempts.last(where: {
      $0.strategyFingerprint == candidateStrategyFingerprint
    }) else {
      return .newAttempt(ordinal: (attempts.map(\.ordinal).max() ?? 0) + 1)
    }
    guard existing.outcome == .active else {
      return .duplicateStrategy(attemptID: existing.attemptID)
    }
    guard identicalActionRunCount > 0 else {
      return .continueAttempt(attemptID: existing.attemptID)
    }
    guard let failure, retrySafe,
      failure.retryDisposition == .actionRetryAllowed
    else {
      return .duplicateStrategy(attemptID: existing.attemptID)
    }
    let retries = max(0, identicalActionRunCount - 1)
    guard retries < maxActionRetriesPerRun else {
      return .actionRetryBudgetExhausted(attemptID: existing.attemptID, retries: retries)
    }
    return .actionRetry(attemptID: existing.attemptID, retryOrdinal: retries + 1)
  }
}
