// Durable dispatch intent, decision record and submission input
// (CHG-2026-054, TASK-HTP-001).
//
// The dispatch order is the load-bearing part of this file:
//
//   1. persist the decision and the dispatch intent (this document),
//   2. derive a stable requestId / idempotencyKey from the task, round,
//      decision and typed inputs,
//   3. submit the runtime operation,
//   4. persist the returned job id as the task-job link.
//
// A crash between 3 and 4 leaves a `submitted` intent with no link.
// Recovery re-submits *the original key* and the engine deduplicates back
// to the same job, so the side effect happens once (HTP-INV-4). Recovery
// never invents a new key, and never substitutes a different operation.

import CryptoKit
import Foundation

public enum HarnessDispatchState: String, CaseIterable, Codable, Sendable {
  /// Intent persisted, nothing submitted yet. Safe to submit.
  case pending
  /// Submit was attempted; the outcome of the submit call itself is not
  /// yet known to be recorded. Recovery re-submits with the same key.
  case submitted
  /// Job id recorded. The round is fully accounted for.
  case linked
  /// The engine refused admission. Zero side effect happened, and recovery
  /// must not retry it: an identical re-submit would be refused for the
  /// same reason, which is exactly the loop a bounded harness must not
  /// enter. Resolving it is a human or policy decision.
  case rejected
}

public enum HarnessDecisionKind: String, CaseIterable, Codable, Sendable {
  case invokeOperation
  case requestHuman
  case noSafeAction
}

/// One proposed next step. In TASK-HTP-001 the producer is the built-in
/// deterministic handler; TASK-HTP-004 adds a model-backed producer behind
/// the same type. Either way a decision carries no status, no retry count,
/// no raw command and no success claim - those fields do not exist here,
/// which is what makes HTP-INV-1 structural instead of advisory.
public struct HarnessDecision: Equatable, Sendable, Codable {
  public static let documentType = "harness-decision"

  public let documentType: String
  public let decisionID: String
  public let htaskID: String
  public let round: Int
  public let kind: HarnessDecisionKind
  public let operationReference: String?
  public let inputs: [String: JSONValue]
  public let hypothesis: String
  public let reasonCode: String
  public let producer: String
  public let createdAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case decisionID = "decisionId"
    case htaskID = "htaskId"
    case round
    case kind
    case operationReference
    case inputs
    case hypothesis
    case reasonCode
    case producer
    case createdAtUTC = "createdAtUtc"
  }

  public init(
    decisionID: String,
    htaskID: String,
    round: Int,
    kind: HarnessDecisionKind,
    operationReference: String? = nil,
    inputs: [String: JSONValue] = [:],
    hypothesis: String,
    reasonCode: String,
    producer: String,
    createdAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.decisionID = decisionID
    self.htaskID = htaskID
    self.round = round
    self.kind = kind
    self.operationReference = operationReference
    self.inputs = inputs
    self.hypothesis = hypothesis
    self.reasonCode = reasonCode
    self.producer = producer
    self.createdAtUTC = createdAtUTC
  }
}

public struct HarnessDispatchIntent: Equatable, Sendable, Codable {
  public static let documentType = "harness-dispatch-intent"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let htaskID: String
  public let round: Int
  public let decisionID: String
  public let operationReference: String
  public let targetID: String
  public let expectedBindingRevision: Int?
  public let inputsDigestSHA256: String
  public let requestID: String
  public let idempotencyKey: String
  public let state: HarnessDispatchState
  public let jobID: String?
  public let createdAtUTC: String
  public let updatedAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case htaskID = "htaskId"
    case round
    case decisionID = "decisionId"
    case operationReference
    case targetID = "targetId"
    case expectedBindingRevision
    case inputsDigestSHA256 = "inputsDigestSha256"
    case requestID = "requestId"
    case idempotencyKey
    case state
    case jobID = "jobId"
    case createdAtUTC = "createdAtUtc"
    case updatedAtUTC = "updatedAtUtc"
  }

  public init(
    htaskID: String,
    round: Int,
    decisionID: String,
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    inputsDigestSHA256: String,
    requestID: String,
    idempotencyKey: String,
    state: HarnessDispatchState,
    jobID: String?,
    createdAtUTC: String,
    updatedAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.htaskID = htaskID
    self.round = round
    self.decisionID = decisionID
    self.operationReference = operationReference
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
    self.inputsDigestSHA256 = inputsDigestSHA256
    self.requestID = requestID
    self.idempotencyKey = idempotencyKey
    self.state = state
    self.jobID = jobID
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
  }

  public func withState(
    _ state: HarnessDispatchState,
    jobID: String? = nil,
    atUTC: String
  ) -> HarnessDispatchIntent {
    HarnessDispatchIntent(
      htaskID: htaskID, round: round, decisionID: decisionID,
      operationReference: operationReference, targetID: targetID,
      expectedBindingRevision: expectedBindingRevision,
      inputsDigestSHA256: inputsDigestSHA256, requestID: requestID,
      idempotencyKey: idempotencyKey, state: state, jobID: jobID ?? self.jobID,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC)
  }
}

/// Derivation of the runtime request identity from the harness decision.
///
/// Deterministic on purpose: the same (task, round, decision, operation,
/// inputs) always yields the same key, so a re-submit after a crash is
/// indistinguishable from the first attempt to the engine's dedup path.
/// A clock or a random suffix here would silently turn recovery into a
/// second side effect.
public enum HarnessRequestIdentity {
  public static func inputsDigest(_ inputs: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(inputs)) ?? Data("{}".utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func derive(
    htaskID: String,
    round: Int,
    decisionID: String,
    operationReference: String,
    targetID: String,
    inputsDigest: String
  ) -> (requestID: String, idempotencyKey: String) {
    let material =
      "\(htaskID)|\(round)|\(decisionID)|\(operationReference)|\(targetID)|\(inputsDigest)"
    let digest = SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02x", $0) }.joined()
    // Both identifiers must satisfy the runtime wire grammar (ASCII
    // identifier, idempotency key >= 8 chars); a hex prefix always does.
    return ("htask-\(digest.prefix(24))", "htask-\(digest.prefix(48))")
  }
}

public enum HarnessTaskSubmissionError: Error, Equatable, Sendable {
  case malformedTargetID
  case emptyGoal
  case emptyAllowedOperations
  case operationNotPermittedForType(String)
  case budgetOutOfRange(String)
  case intakeTooLong
  case unsupportedTaskType(HarnessTaskType)
  case duplicateCriterionID(String)
}

/// Typed submission input. Natural language is admitted only as
/// `intakeDescription`; everything the loop executes on is typed.
public struct HarnessTaskSubmission: Equatable, Sendable, Codable {
  public let type: HarnessTaskType
  public let intakeDescription: String?
  public let projectRef: String?
  public let target: HarnessTaskTargetReference
  public let goal: HarnessTaskGoal
  public let successCriteria: [HarnessSuccessCriterion]
  public let budgets: HarnessTaskBudgets
  public let policy: HarnessTaskPolicy

  public init(
    type: HarnessTaskType,
    intakeDescription: String? = nil,
    projectRef: String? = nil,
    target: HarnessTaskTargetReference,
    goal: HarnessTaskGoal,
    successCriteria: [HarnessSuccessCriterion] = [],
    budgets: HarnessTaskBudgets,
    policy: HarnessTaskPolicy
  ) {
    self.type = type
    self.intakeDescription = intakeDescription
    self.projectRef = projectRef
    self.target = target
    self.goal = goal
    self.successCriteria = successCriteria
    self.budgets = budgets
    self.policy = policy
  }

  public func validate(permittedOperations: Set<String>) throws {
    let targetID = target.targetID
    guard !targetID.isEmpty, targetID.count <= 128,
      targetID.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
      })
    else {
      throw HarnessTaskSubmissionError.malformedTargetID
    }
    if let revision = target.expectedBindingRevision, revision < 1 {
      throw HarnessTaskSubmissionError.budgetOutOfRange("expectedBindingRevision")
    }
    guard !goal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HarnessTaskSubmissionError.emptyGoal
    }
    if let intake = intakeDescription, intake.count > 4096 {
      throw HarnessTaskSubmissionError.intakeTooLong
    }
    guard !policy.allowedOperations.isEmpty else {
      throw HarnessTaskSubmissionError.emptyAllowedOperations
    }
    for reference in policy.allowedOperations where !permittedOperations.contains(reference) {
      throw HarnessTaskSubmissionError.operationNotPermittedForType(reference)
    }
    try validateBudget(budgets.maxRounds, ceiling: HarnessTaskBudgets.ceiling.maxRounds, "maxRounds")
    try validateBudget(
      budgets.maxWallClockSeconds, ceiling: HarnessTaskBudgets.ceiling.maxWallClockSeconds,
      "maxWallClockSeconds")
    try validateBudget(
      budgets.maxArtifactBytes, ceiling: HarnessTaskBudgets.ceiling.maxArtifactBytes,
      "maxArtifactBytes")
    guard
      budgets.maxE1Mutations >= 0,
      budgets.maxE1Mutations <= HarnessTaskBudgets.ceiling.maxE1Mutations
    else {
      throw HarnessTaskSubmissionError.budgetOutOfRange("maxE1Mutations")
    }
    var seen = Set<String>()
    for criterion in successCriteria {
      guard seen.insert(criterion.criterionID).inserted else {
        throw HarnessTaskSubmissionError.duplicateCriterionID(criterion.criterionID)
      }
    }
  }

  private func validateBudget(_ value: Int, ceiling: Int, _ field: String) throws {
    guard value >= 1, value <= ceiling else {
      throw HarnessTaskSubmissionError.budgetOutOfRange(field)
    }
  }
}
