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

import ArkDeckCore
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
  /// A pending (never submitted) intent whose decision envelope no longer
  /// matches current facts. It is terminal and must never reach the engine.
  case stale
}

public enum HarnessDecisionKind: String, CaseIterable, Codable, Sendable {
  case invokeOperation
  case proposePatch
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
  package static let envelopeVersion = "2.0.0"

  public let documentType: String
  package let envelopeVersion: String
  package let decisionID: String
  package let htaskID: String
  public let round: Int
  public let kind: HarnessDecisionKind
  public let operationReference: String?
  public let inputs: [String: JSONValue]
  package let patchProposal: HarnessPatchProposal?
  /// Stable prerequisite identities and expected readback. They are data for
  /// strategy identity only; neither may carry bytes, paths or commands.
  package let requiredArtifacts: [String]
  package let expectedObservation: String?
  package let hypothesis: String
  public let reasonCode: String
  package let producer: String
  public let createdAtUTC: String
  /// The task state version the producer read (CHG-2026-055, TASK-HFA-002).
  package let observedStateVersion: Int
  /// Digest of `HarnessDecisionBasis` at proposal time. This describes the
  /// Harness facts used to plan. The digest of bytes a model actually received
  /// is `contextDigest`; the two answer different questions and never alias.
  package let basisDigest: String
  /// Strategy identity is Harness-owned. `nil` is valid only before a repair
  /// strategy exists (for example the initial read-only target observation).
  public let attemptID: String?
  /// A model-backed decision links to the exact durable run and the digest of
  /// the bytes actually transmitted. Deterministic decisions carry neither.
  package let modelRunID: String?
  package let contextDigest: String?
  /// Explicit execution preconditions. Applicability is operation-specific;
  /// an unrelated dimension is represented by `nil`, not a wildcard string.
  package let expectedWorkspaceRevision: String?
  public let expectedDeployedArtifactDigest: String?
  package let expectedBindingRevision: Int?

  enum CodingKeys: String, CodingKey {
    case documentType
    case envelopeVersion
    case decisionID = "decisionId"
    case htaskID = "htaskId"
    case round
    case kind
    case operationReference
    case inputs
    case patchProposal
    case requiredArtifacts
    case expectedObservation
    case hypothesis
    case reasonCode
    case producer
    case createdAtUTC = "createdAtUtc"
    case observedStateVersion
    case basisDigest
    case attemptID = "attemptId"
    case modelRunID = "modelRunId"
    case contextDigest
    case expectedWorkspaceRevision
    case expectedDeployedArtifactDigest
    case expectedBindingRevision
  }

  public init(
    decisionID: String,
    htaskID: String,
    round: Int,
    kind: HarnessDecisionKind,
    operationReference: String? = nil,
    inputs: [String: JSONValue] = [:],
    patchProposal: HarnessPatchProposal? = nil,
    requiredArtifacts: [String] = [],
    expectedObservation: String? = nil,
    hypothesis: String,
    reasonCode: String,
    producer: String,
    createdAtUTC: String,
    observedStateVersion: Int = 0,
    basisDigest: String = "",
    attemptID: String? = nil,
    modelRunID: String? = nil,
    contextDigest: String? = nil,
    expectedWorkspaceRevision: String? = nil,
    expectedDeployedArtifactDigest: String? = nil,
    expectedBindingRevision: Int? = nil
  ) {
    self.documentType = Self.documentType
    self.envelopeVersion = Self.envelopeVersion
    self.decisionID = decisionID
    self.htaskID = htaskID
    self.round = round
    self.kind = kind
    self.operationReference = operationReference
    self.inputs = inputs
    self.patchProposal = patchProposal
    self.requiredArtifacts = requiredArtifacts
    self.expectedObservation = expectedObservation
    self.hypothesis = hypothesis
    self.reasonCode = reasonCode
    self.producer = producer
    self.createdAtUTC = createdAtUTC
    self.observedStateVersion = observedStateVersion
    self.basisDigest = basisDigest
    self.attemptID = attemptID
    self.modelRunID = modelRunID
    self.contextDigest = contextDigest
    self.expectedWorkspaceRevision = expectedWorkspaceRevision
    self.expectedDeployedArtifactDigest = expectedDeployedArtifactDigest
    self.expectedBindingRevision = expectedBindingRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.documentType = try container.decode(String.self, forKey: .documentType)
    self.envelopeVersion = try container.decode(String.self, forKey: .envelopeVersion)
    self.decisionID = try container.decode(String.self, forKey: .decisionID)
    self.htaskID = try container.decode(String.self, forKey: .htaskID)
    self.round = try container.decode(Int.self, forKey: .round)
    self.kind = try container.decode(HarnessDecisionKind.self, forKey: .kind)
    self.operationReference = try container.decodeIfPresent(
      String.self, forKey: .operationReference)
    self.inputs =
      try container.decodeIfPresent([String: JSONValue].self, forKey: .inputs) ?? [:]
    self.patchProposal = try container.decodeIfPresent(
      HarnessPatchProposal.self, forKey: .patchProposal)
    self.requiredArtifacts =
      try container.decodeIfPresent([String].self, forKey: .requiredArtifacts) ?? []
    self.expectedObservation = try container.decodeIfPresent(
      String.self, forKey: .expectedObservation)
    self.hypothesis = try container.decode(String.self, forKey: .hypothesis)
    self.reasonCode = try container.decode(String.self, forKey: .reasonCode)
    self.producer = try container.decode(String.self, forKey: .producer)
    self.createdAtUTC = try container.decode(String.self, forKey: .createdAtUTC)
    self.observedStateVersion = try container.decode(Int.self, forKey: .observedStateVersion)
    self.basisDigest = try container.decode(String.self, forKey: .basisDigest)
    self.attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID)
    self.modelRunID = try container.decodeIfPresent(String.self, forKey: .modelRunID)
    self.contextDigest = try container.decodeIfPresent(String.self, forKey: .contextDigest)
    self.expectedWorkspaceRevision = try container.decodeIfPresent(
      String.self, forKey: .expectedWorkspaceRevision)
    self.expectedDeployedArtifactDigest = try container.decodeIfPresent(
      String.self, forKey: .expectedDeployedArtifactDigest)
    self.expectedBindingRevision = try container.decodeIfPresent(
      Int.self, forKey: .expectedBindingRevision)
  }

  /// The same decision, stamped with the basis its producer read. Kept as a
  /// derivation rather than a mutable field so a producer cannot forge a
  /// basis it did not observe: the coordinator stamps it, from the snapshot
  /// it loaded, on the way out of planning.
  package func stamped(
    with basis: HarnessDecisionBasis,
    attemptID: String? = nil,
    expectedWorkspaceRevision: String? = nil,
    expectedDeployedArtifactDigest: String? = nil,
    expectedBindingRevision: Int? = nil
  ) -> HarnessDecision {
    HarnessDecision(
      decisionID: decisionID,
      htaskID: htaskID,
      round: round,
      kind: kind,
      operationReference: operationReference,
      inputs: inputs,
      patchProposal: patchProposal,
      requiredArtifacts: requiredArtifacts,
      expectedObservation: expectedObservation,
      hypothesis: hypothesis,
      reasonCode: reasonCode,
      producer: producer,
      createdAtUTC: createdAtUTC,
      observedStateVersion: basis.stateVersion,
      basisDigest: basis.digest,
      attemptID: attemptID ?? self.attemptID,
      modelRunID: modelRunID,
      contextDigest: contextDigest,
      expectedWorkspaceRevision: expectedWorkspaceRevision ?? self.expectedWorkspaceRevision,
      expectedDeployedArtifactDigest:
        expectedDeployedArtifactDigest ?? self.expectedDeployedArtifactDigest,
      expectedBindingRevision: expectedBindingRevision ?? self.expectedBindingRevision)
  }
}

public struct HarnessDispatchIntent: Equatable, Sendable, Codable {
  public static let documentType = "harness-dispatch-intent"
  public static let schemaVersion = "2.0.0"

  public let documentType: String
  public let schemaVersion: String
  package let htaskID: String
  public let round: Int
  package let decisionID: String
  public let attemptID: String?
  package let modelRunID: String?
  public let operationReference: String
  public let targetID: String
  package let expectedBindingRevision: Int?
  package let expectedWorkspaceRevision: String?
  public let expectedDeployedArtifactDigest: String?
  package let inputsDigestSHA256: String
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
    case attemptID = "attemptId"
    case modelRunID = "modelRunId"
    case operationReference
    case targetID = "targetId"
    case expectedBindingRevision
    case expectedWorkspaceRevision
    case expectedDeployedArtifactDigest
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
    attemptID: String? = nil,
    modelRunID: String? = nil,
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    expectedWorkspaceRevision: String? = nil,
    expectedDeployedArtifactDigest: String? = nil,
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
    self.attemptID = attemptID
    self.modelRunID = modelRunID
    self.operationReference = operationReference
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
    self.expectedWorkspaceRevision = expectedWorkspaceRevision
    self.expectedDeployedArtifactDigest = expectedDeployedArtifactDigest
    self.inputsDigestSHA256 = inputsDigestSHA256
    self.requestID = requestID
    self.idempotencyKey = idempotencyKey
    self.state = state
    self.jobID = jobID
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
  }

  private init(
    schemaVersion: String,
    htaskID: String,
    round: Int,
    decisionID: String,
    attemptID: String?,
    modelRunID: String?,
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    expectedWorkspaceRevision: String?,
    expectedDeployedArtifactDigest: String?,
    inputsDigestSHA256: String,
    requestID: String,
    idempotencyKey: String,
    state: HarnessDispatchState,
    jobID: String?,
    createdAtUTC: String,
    updatedAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = schemaVersion
    self.htaskID = htaskID
    self.round = round
    self.decisionID = decisionID
    self.attemptID = attemptID
    self.modelRunID = modelRunID
    self.operationReference = operationReference
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
    self.expectedWorkspaceRevision = expectedWorkspaceRevision
    self.expectedDeployedArtifactDigest = expectedDeployedArtifactDigest
    self.inputsDigestSHA256 = inputsDigestSHA256
    self.requestID = requestID
    self.idempotencyKey = idempotencyKey
    self.state = state
    self.jobID = jobID
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC
  }

  /// Schema-1 intents are compatibility-quarantined. A record that spells
  /// `"schemaVersion":"1.0.0"` explicitly still decodes for audit and export; a schema-1-era
  /// record without the key fails decoding loudly (`schemaVersion` is required). Recovery that
  /// reaches a quarantined intent fails loudly at the association check rather than skipping
  /// it silently. Compatibility may reduce executability; it must never reduce the current
  /// schema's association checks.
  ///
  /// Retirement criterion: remove the schema-1 quarantine after every supported production
  /// store and migration fixture reports zero rows for:
  /// `SELECT count(*) FROM dispatch_intent WHERE json_extract(intent_json, '$.schemaVersion') = '1.0.0'`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.documentType = try container.decode(String.self, forKey: .documentType)
    self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    self.htaskID = try container.decode(String.self, forKey: .htaskID)
    self.round = try container.decode(Int.self, forKey: .round)
    self.decisionID = try container.decode(String.self, forKey: .decisionID)
    self.attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID)
    self.modelRunID = try container.decodeIfPresent(String.self, forKey: .modelRunID)
    self.operationReference = try container.decode(String.self, forKey: .operationReference)
    self.targetID = try container.decode(String.self, forKey: .targetID)
    self.expectedBindingRevision = try container.decodeIfPresent(
      Int.self, forKey: .expectedBindingRevision)
    self.expectedWorkspaceRevision = try container.decodeIfPresent(
      String.self, forKey: .expectedWorkspaceRevision)
    self.expectedDeployedArtifactDigest = try container.decodeIfPresent(
      String.self, forKey: .expectedDeployedArtifactDigest)
    self.inputsDigestSHA256 = try container.decode(String.self, forKey: .inputsDigestSHA256)
    self.requestID = try container.decode(String.self, forKey: .requestID)
    self.idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
    self.state = try container.decode(HarnessDispatchState.self, forKey: .state)
    self.jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
    self.createdAtUTC = try container.decode(String.self, forKey: .createdAtUTC)
    self.updatedAtUTC = try container.decode(String.self, forKey: .updatedAtUTC)
  }

  package var isExecutableUnderCurrentSchema: Bool {
    schemaVersion == Self.schemaVersion
  }

  package func withState(
    _ state: HarnessDispatchState,
    jobID: String? = nil,
    atUTC: String
  ) -> HarnessDispatchIntent {
    HarnessDispatchIntent(
      schemaVersion: schemaVersion,
      htaskID: htaskID, round: round, decisionID: decisionID,
      attemptID: attemptID, modelRunID: modelRunID,
      operationReference: operationReference, targetID: targetID,
      expectedBindingRevision: expectedBindingRevision,
      expectedWorkspaceRevision: expectedWorkspaceRevision,
      expectedDeployedArtifactDigest: expectedDeployedArtifactDigest,
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
package enum HarnessRequestIdentity {
  package static func inputsDigest(_ inputs: [String: JSONValue]) -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    let data = (try? encoder.encode(inputs)) ?? Data("{}".utf8)
    return SHA256Hex.string(of: data)
  }

  package static func derive(
    htaskID: String,
    round: Int,
    decisionID: String,
    operationReference: String,
    targetID: String,
    inputsDigest: String
  ) -> (requestID: String, idempotencyKey: String) {
    let material =
      "\(htaskID)|\(round)|\(decisionID)|\(operationReference)|\(targetID)|\(inputsDigest)"
    let digest = SHA256Hex.string(of: Data(material.utf8))
    // Both identifiers must satisfy the runtime wire grammar (ASCII
    // identifier, idempotency key >= 8 chars); a hex prefix always does.
    return ("htask-\(digest.prefix(24))", "htask-\(digest.prefix(48))")
  }
}

package enum HarnessTaskSubmissionError: Error, Equatable, Sendable {
  case malformedTargetID
  case emptyGoal
  case emptyAllowedOperations
  case operationNotPermittedForType(String)
  case budgetOutOfRange(String)
  case insufficientE1MutationBudget(required: Int, actual: Int)
  case malformedDesiredState(String)
  case intakeTooLong
  case unsupportedTaskType(HarnessTaskType)
  case duplicateCriterionID(String)
  case evolutionProjectRequired
  case malformedEvolutionPolicy(String)
  /// A task may mutate a workspace only from inside a task-owned isolated
  /// copy. Names the mutating operations it asked for without one.
  case workspaceIsolationRequired([String])
}

/// Typed submission input. Natural language is admitted only as
/// `intakeDescription`; everything the loop executes on is typed.
public struct HarnessTaskSubmission: Equatable, Sendable, Codable {
  public let type: HarnessTaskType
  package let intakeDescription: String?
  public let projectRef: String?
  public let target: HarnessTaskTargetReference
  public let goal: HarnessTaskGoal
  package let successCriteria: [HarnessSuccessCriterion]
  package let budgets: HarnessTaskBudgets
  public let policy: HarnessTaskPolicy
  package let evolutionPolicy: HarnessEvolutionPolicy?

  public init(
    type: HarnessTaskType,
    intakeDescription: String? = nil,
    projectRef: String? = nil,
    target: HarnessTaskTargetReference,
    goal: HarnessTaskGoal,
    successCriteria: [HarnessSuccessCriterion] = [],
    budgets: HarnessTaskBudgets,
    policy: HarnessTaskPolicy,
    evolutionPolicy: HarnessEvolutionPolicy? = nil
  ) {
    self.type = type
    self.intakeDescription = intakeDescription
    self.projectRef = projectRef
    self.target = target
    self.goal = goal
    self.successCriteria = successCriteria
    self.budgets = budgets
    self.policy = policy
    self.evolutionPolicy = evolutionPolicy
  }

  /// Workspace isolation is a fact derived from the typed policy envelope. It is not a
  /// caller-selectable execution mode.
  package var requiresWorkspaceIsolation: Bool { evolutionPolicy != nil }

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
    if let evolutionPolicy {
      guard projectRef != nil else {
        throw HarnessTaskSubmissionError.evolutionProjectRequired
      }
      do {
        try evolutionPolicy.validate(taskPolicy: policy)
      } catch {
        throw HarnessTaskSubmissionError.malformedEvolutionPolicy("\(error)")
      }
    }
    try validateBudget(
      budgets.maxRounds, ceiling: HarnessTaskBudgets.ceiling.maxRounds, "maxRounds")
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
    try validateBudget(
      budgets.maxNoProgressRounds,
      ceiling: HarnessTaskBudgets.ceiling.maxNoProgressRounds,
      "maxNoProgressRounds")
    try validateBudget(
      budgets.maxActionRetriesPerRun,
      ceiling: HarnessTaskBudgets.ceiling.maxActionRetriesPerRun,
      "maxActionRetriesPerRun")
    guard budgets.maxModelCalls >= 0,
      budgets.maxModelCalls <= HarnessTaskBudgets.ceiling.maxModelCalls
    else {
      throw HarnessTaskSubmissionError.budgetOutOfRange("maxModelCalls")
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
