// The bounded decision context and the strict proposal shape
// (CHG-2026-054, TASK-HTP-004).
//
// This is the only place where something outside the repository gets to
// influence what the harness does next, so both directions are narrowed:
//
//   * outbound - the context is assembled from declared fields with hard
//     counts and a byte ceiling. No connect key, no device serial, no stable
//     identity digest. The target travels as a pseudonym, because a model
//     needs to know "the same device as last round", never which device it
//     is. Evidence and in-scope source travel as bounded excerpts: a model
//     that must judge a crash or write a unified diff cannot do either from a
//     digest prefix, and self-debugging is the point. Every excerpt is
//     per-item bounded, says when it was truncated, and is gated by the same
//     operator opt-ins that already govern egress and sensitive evidence;
//   * inbound - a proposal is decoded with a closed key set and may carry
//     only a next step. It cannot carry a task or job state, a retry count,
//     an authorization result or a success claim: those keys are rejected
//     rather than ignored, so a model that tries to declare the task fixed
//     produces a refusal instead of a silent no-op (HTP-INV-1).
//
// Nothing here talks to a model. Transport is a port in the workflow module;
// this file is the contract both sides are held to.

import ArkDeckCore
import CryptoKit
import Foundation

package struct HarnessDecisionContextLimits: Equatable, Sendable, Codable {
  public let maxAttempts: Int
  package let maxFailures: Int
  package let maxMemories: Int
  package let maxArtifacts: Int
  package let maxOperations: Int
  package let maxSummaryCharacters: Int
  /// Per-excerpt ceiling for evidence and source text. A model that must
  /// write a unified diff needs the actual lines; a model that must read a
  /// crash needs the fault block. Both are bounded per item so one large
  /// artifact cannot crowd out everything else.
  package let maxExcerptCharacters: Int
  /// How many source files may be excerpted into one context.
  package let maxSourceFiles: Int
  /// Ceiling on the encoded context. Exceeding it trims, and the trim is
  /// recorded in the context itself - a silently shortened context is a
  /// context nobody can reason about afterwards.
  package let maxEncodedBytes: Int

  public init(
    maxAttempts: Int = 5,
    maxFailures: Int = 5,
    maxMemories: Int = 8,
    maxArtifacts: Int = 12,
    maxOperations: Int = 16,
    // A bounded repair goal may need an exact base revision, patch digest,
    // touched path and unified diff. 480 characters truncated that closed
    // proposal before the model could see it while the overall 32 KiB
    // envelope still had ample room.
    maxSummaryCharacters: Int = 2_048,
    maxExcerptCharacters: Int = 24_000,
    maxSourceFiles: Int = 12,
    maxEncodedBytes: Int = 512 * 1024
  ) {
    self.maxAttempts = maxAttempts
    self.maxFailures = maxFailures
    self.maxMemories = maxMemories
    self.maxArtifacts = maxArtifacts
    self.maxOperations = maxOperations
    self.maxSummaryCharacters = maxSummaryCharacters
    self.maxExcerptCharacters = maxExcerptCharacters
    self.maxSourceFiles = maxSourceFiles
    self.maxEncodedBytes = maxEncodedBytes
  }

  public static let `default` = HarnessDecisionContextLimits()
}

package struct HarnessContextAttempt: Equatable, Sendable, Codable {
  public let round: Int
  public let operationReference: String
  public let outcome: String
  public let reasonCode: String

  public init(round: Int, operationReference: String, outcome: String, reasonCode: String) {
    self.round = round
    self.operationReference = operationReference
    self.outcome = outcome
    self.reasonCode = reasonCode
  }
}

package struct HarnessContextFailure: Equatable, Sendable, Codable {
  public let digest: String
  public let operationReference: String
  package let occurrences: Int
  package let stance: HarnessRetryStance
  package let errorClassification: String
  package let semanticErrorCode: String
  package let retryDisposition: HarnessFailureRetryDisposition
  package let alternativeHints: [String]

  public init(
    digest: String,
    operationReference: String,
    occurrences: Int,
    stance: HarnessRetryStance,
    errorClassification: String,
    semanticErrorCode: String,
    retryDisposition: HarnessFailureRetryDisposition = .actionRetryAllowed,
    alternativeHints: [String] = []
  ) {
    self.digest = digest
    self.operationReference = operationReference
    self.occurrences = occurrences
    self.stance = stance
    self.errorClassification = errorClassification
    self.semanticErrorCode = semanticErrorCode
    self.retryDisposition = retryDisposition
    self.alternativeHints = alternativeHints
  }
}

/// Facts split by authority. `current` may contain current evaluator PASS
/// facts and in-scope VERIFIED memory. CANDIDATE memory remains advice in
/// `relevantMemory` and never crosses this boundary.
package struct HarnessContextConfirmedFacts: Equatable, Sendable, Codable {
  public let current: [String]

  public init(current: [String] = []) {
    self.current = Array(Set(current)).sorted()
  }
}

/// An artifact as a model may see it: identity, size, digest prefix, whether
/// it verified, and — when the operator has opted this project into egress and
/// allowed the artifact to be measured — a bounded excerpt of its text.
///
/// The excerpt exists because self-debugging is the point: a model asked to
/// judge a crash or to write a unified diff cannot do either from a digest
/// prefix. It stays bounded and stays honest: `excerptTruncated` says when the
/// artifact is longer than what is shown, and an artifact the operator has not
/// allowed carries no excerpt at all rather than a redacted-looking one.
package struct HarnessContextArtifact: Equatable, Sendable, Codable {
  public let artifactID: String
  public let name: String
  public let byteCount: Int
  package let sha256Prefix: String
  public let verified: Bool
  package let excerpt: String?
  package let excerptTruncated: Bool

  enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case name
    case byteCount
    case sha256Prefix
    case verified
    case excerpt
    case excerptTruncated
  }

  public init(
    artifactID: String, name: String, byteCount: Int, sha256Prefix: String, verified: Bool,
    excerpt: String? = nil, excerptTruncated: Bool = false
  ) {
    self.artifactID = artifactID
    self.name = name
    self.byteCount = byteCount
    self.sha256Prefix = sha256Prefix
    self.verified = verified
    self.excerpt = excerpt
    self.excerptTruncated = excerptTruncated
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artifactID = try container.decode(String.self, forKey: .artifactID)
    name = try container.decode(String.self, forKey: .name)
    byteCount = try container.decode(Int.self, forKey: .byteCount)
    sha256Prefix = try container.decode(String.self, forKey: .sha256Prefix)
    verified = try container.decode(Bool.self, forKey: .verified)
    // Contexts recorded before excerpts existed decode unchanged.
    excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
    excerptTruncated =
      try container.decodeIfPresent(Bool.self, forKey: .excerptTruncated) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(artifactID, forKey: .artifactID)
    try container.encode(name, forKey: .name)
    try container.encode(byteCount, forKey: .byteCount)
    try container.encode(sha256Prefix, forKey: .sha256Prefix)
    try container.encode(verified, forKey: .verified)
    try container.encodeIfPresent(excerpt, forKey: .excerpt)
    if excerptTruncated { try container.encode(true, forKey: .excerptTruncated) }
  }

  /// Drops the excerpt while keeping identity, size and digest. Trimming a
  /// context shrinks what the model sees; it must never change what the
  /// context says an artifact *is*.
  package func withoutExcerpt() -> Self {
    HarnessContextArtifact(
      artifactID: artifactID, name: name, byteCount: byteCount,
      sha256Prefix: sha256Prefix, verified: verified)
  }
}

extension HarnessDecisionContext {
  /// Rebuilds this context with lighter excerpts. Only the excerpt-bearing
  /// fields and the trim ledger may change; every fact the context asserts
  /// about the task stays identical.
  func replacing(
    artifacts: [HarnessContextArtifact]? = nil,
    sourceFiles: [HarnessContextSourceFile]? = nil,
    trimmed: [String]
  ) -> HarnessDecisionContext {
    HarnessDecisionContext(
      targetPseudonym: targetPseudonym,
      taskType: taskType,
      status: status,
      phase: phase,
      round: round,
      currentTaskStateVersion: currentTaskStateVersion,
      goalSummary: goalSummary,
      desiredState: desiredState,
      observedMeasurements: observedMeasurements,
      observedSamples: observedSamples,
      latestVerdict: latestVerdict,
      criterionResults: criterionResults,
      recentAttempts: recentAttempts,
      unresolvedFailures: unresolvedFailures,
      relevantMemory: relevantMemory,
      confirmedFacts: confirmedFacts,
      memorySelectionManifest: memorySelectionManifest,
      artifacts: artifacts ?? self.artifacts,
      sourceFiles: sourceFiles ?? self.sourceFiles,
      requestedDecision: requestedDecision,
      availableOperations: availableOperations,
      budget: budget,
      blockers: blockers,
      trimmed: trimmed,
      waitReason: waitReason,
      conditions: conditions,
      executionState: HarnessContextExecutionState(
        activeAttempt: nil,
        currentWorkspaceRevision: currentWorkspaceRevision,
        currentDeployedArtifactDigest: currentDeployedArtifactDigest,
        currentDeviceBindingRevision: currentDeviceBindingRevision,
        disprovedHypotheses: disprovedHypotheses,
        unavailableOperations: unavailableOperationsAndReasons,
        authorizedOperationReferences: authorizedOperationRefs,
        currentCapabilityEffectCeiling: currentCapabilityEffectCeiling,
        allowedFileScopes: allowedFileScopes,
        derivedArtifactSummaries: derivedArtifactSummaries))
  }
}

/// A file the task is allowed to change, as the model may see it. Without
/// this a `proposePatch` is impossible in principle: a unified diff needs the
/// exact lines it is diffing against.
package struct HarnessContextSourceFile: Equatable, Sendable, Codable {
  public let path: String
  public let byteCount: Int
  package let sha256Prefix: String
  package let excerpt: String
  package let excerptTruncated: Bool

  public init(
    path: String, byteCount: Int, sha256Prefix: String, excerpt: String,
    excerptTruncated: Bool = false
  ) {
    self.path = path
    self.byteCount = byteCount
    self.sha256Prefix = sha256Prefix
    self.excerpt = excerpt
    self.excerptTruncated = excerptTruncated
  }
}

/// Revision-aware strategy facts sent to a model. The summary deliberately
/// excludes free-form hypothesis prose, capability identifiers and ActionRun
/// inputs: it describes which durable Attempt is active without turning the
/// context into a second execution surface.
package struct HarnessContextActiveAttemptSummary: Equatable, Sendable, Codable {
  public let attemptID: String
  public let ordinal: Int
  package let strategyFingerprint: String
  public let operationReference: String
  public let outcome: HarnessAttemptOutcome
  package let baseWorkspaceRevision: String?
  package let patchRevision: String?
  package let expectedNextObservation: String

  enum CodingKeys: String, CodingKey {
    case attemptID = "attemptId"
    case ordinal
    case strategyFingerprint
    case operationReference
    case outcome
    case baseWorkspaceRevision
    case patchRevision
    case expectedNextObservation
  }

  public init(_ attempt: HarnessAttempt) {
    self.attemptID = attempt.attemptID
    self.ordinal = attempt.ordinal
    self.strategyFingerprint = attempt.strategyFingerprint
    self.operationReference = attempt.strategy.selectedOperationFamily
    self.outcome = attempt.outcome
    self.baseWorkspaceRevision = attempt.applicableBaseRevision
    self.patchRevision = attempt.patchRevision
    self.expectedNextObservation = attempt.strategy.executionExpectation.expectedNextObservation
  }
}

package struct HarnessContextUnavailableOperation: Equatable, Sendable, Codable {
  public let operationReference: String
  public let reasonCode: String

  public init(operationReference: String, reasonCode: String) {
    self.operationReference = operationReference
    // Availability ports promise a machine reason. Keep that property true
    // at the egress boundary even if a provider accidentally returns prose
    // containing a host path or diagnostic output.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-@"))
    let scalarSafe = reasonCode.unicodeScalars.allSatisfy { allowed.contains($0) }
    self.reasonCode = scalarSafe && !reasonCode.isEmpty
      ? String(reasonCode.prefix(160)) : "operationUnavailable"
  }
}

package struct HarnessContextRevisionScope: Equatable, Sendable, Codable {
  public let workspaceRevision: String?
  package let deployedArtifactDigest: String?
  package let deviceBindingRevision: Int?

  public init(
    workspaceRevision: String? = nil,
    deployedArtifactDigest: String? = nil,
    deviceBindingRevision: Int? = nil
  ) {
    self.workspaceRevision = workspaceRevision
    self.deployedArtifactDigest = deployedArtifactDigest
    self.deviceBindingRevision = deviceBindingRevision
  }
}

/// A bounded semantic view of a deterministic analyzer output. Raw bytes do
/// not travel; the source Artifact identity, pinned producer, applicable
/// revision and full content digest do, so the summary remains auditable.
package struct HarnessDerivedArtifactSummary: Equatable, Sendable, Codable {
  public let artifactID: String
  public let name: String
  package let sourceArtifactIDs: [String]
  package let analyzerReference: String
  public let analyzerVersion: String
  package let revisionScope: HarnessContextRevisionScope
  package let redactionStatus: String
  package let contentSHA256: String
  public let byteCount: Int
  package let measurements: [String: JSONValue]

  enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case name
    case sourceArtifactIDs = "sourceArtifactIds"
    case analyzerReference
    case analyzerVersion
    case revisionScope
    case redactionStatus
    case contentSHA256 = "contentSha256"
    case byteCount
    case measurements
  }

  public init(
    artifactID: String,
    name: String,
    sourceArtifactIDs: [String],
    analyzerReference: String,
    analyzerVersion: String,
    revisionScope: HarnessContextRevisionScope,
    redactionStatus: String,
    contentSHA256: String,
    byteCount: Int,
    measurements: [String: JSONValue]
  ) {
    self.artifactID = artifactID
    self.name = name
    self.sourceArtifactIDs = Array(Set(sourceArtifactIDs)).sorted()
    self.analyzerReference = analyzerReference
    self.analyzerVersion = analyzerVersion
    self.revisionScope = revisionScope
    self.redactionStatus = redactionStatus
    self.contentSHA256 = contentSHA256
    self.byteCount = byteCount
    self.measurements = measurements
  }
}

/// Facts whose authority lives outside the task snapshot but which are safe
/// and useful in the outbound context. The coordinator rebuilds this value on
/// every wake; it is never accepted from a model or persisted as task state.
package struct HarnessContextExecutionState: Equatable, Sendable {
  package let activeAttempt: HarnessAttempt?
  package let currentWorkspaceRevision: String?
  package let currentDeployedArtifactDigest: String?
  package let currentDeviceBindingRevision: Int?
  package let disprovedHypotheses: [String]
  package let unavailableOperations: [HarnessContextUnavailableOperation]
  package let authorizedOperationReferences: [String]
  package let currentCapabilityEffectCeiling: WorkflowEffect?
  package let allowedFileScopes: [String]
  package let derivedArtifactSummaries: [HarnessDerivedArtifactSummary]

  public init(
    activeAttempt: HarnessAttempt? = nil,
    currentWorkspaceRevision: String? = nil,
    currentDeployedArtifactDigest: String? = nil,
    currentDeviceBindingRevision: Int? = nil,
    disprovedHypotheses: [String] = [],
    unavailableOperations: [HarnessContextUnavailableOperation] = [],
    authorizedOperationReferences: [String] = [],
    currentCapabilityEffectCeiling: WorkflowEffect? = nil,
    allowedFileScopes: [String] = [],
    derivedArtifactSummaries: [HarnessDerivedArtifactSummary] = []
  ) {
    self.activeAttempt = activeAttempt
    self.currentWorkspaceRevision = currentWorkspaceRevision
    self.currentDeployedArtifactDigest = currentDeployedArtifactDigest
    self.currentDeviceBindingRevision = currentDeviceBindingRevision
    self.disprovedHypotheses = Array(Set(disprovedHypotheses)).sorted()
    self.unavailableOperations = unavailableOperations.sorted {
      $0.operationReference < $1.operationReference
    }
    self.authorizedOperationReferences = Array(Set(authorizedOperationReferences)).sorted()
    self.currentCapabilityEffectCeiling = currentCapabilityEffectCeiling
    self.allowedFileScopes = Array(Set(allowedFileScopes.filter(Self.isLogicalScope))).sorted()
    self.derivedArtifactSummaries = derivedArtifactSummaries.sorted {
      $0.artifactID < $1.artifactID
    }
  }

  public static let empty = HarnessContextExecutionState()

  private static func isLogicalScope(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, !trimmed.hasPrefix("/"),
      !trimmed.hasPrefix("~"), !trimmed.contains("\\"),
      !trimmed.split(separator: "/").contains("..")
    else { return false }
    return true
  }
}

package struct HarnessContextBudget: Equatable, Sendable, Codable {
  package let roundsRemaining: Int
  package let wallClockSecondsRemaining: Int
  package let artifactBytesRemaining: Int
  package let e1MutationsRemaining: Int
  package let noProgressRoundsRemaining: Int
  package let actionRetriesPerRun: Int
  package let modelCallsRemaining: Int

  public init(
    roundsRemaining: Int,
    wallClockSecondsRemaining: Int,
    artifactBytesRemaining: Int,
    e1MutationsRemaining: Int,
    noProgressRoundsRemaining: Int = 0,
    actionRetriesPerRun: Int = 0,
    modelCallsRemaining: Int = 0
  ) {
    self.roundsRemaining = roundsRemaining
    self.wallClockSecondsRemaining = wallClockSecondsRemaining
    self.artifactBytesRemaining = artifactBytesRemaining
    self.e1MutationsRemaining = e1MutationsRemaining
    self.noProgressRoundsRemaining = noProgressRoundsRemaining
    self.actionRetriesPerRun = actionRetriesPerRun
    self.modelCallsRemaining = modelCallsRemaining
  }
}

package struct HarnessDecisionContext: Equatable, Sendable, Codable {
  public static let documentType = "harness-decision-context"
  public static let schemaVersion = "2.2.0"

  public let documentType: String
  public let schemaVersion: String
  /// Pseudonymous, stable within a task: enough to reason about "the same
  /// target as before", not enough to identify a device.
  package let targetPseudonym: String
  package let taskType: HarnessTaskType
  public let status: HarnessTaskLifecycle
  package let phase: HarnessTaskStage
  public let lifecycle: HarnessTaskLifecycle
  public let stage: HarnessTaskStage
  public let waitReason: HarnessTaskWaitReason?
  package let conditions: [HarnessTaskCondition]
  public let round: Int
  package let currentTaskStateVersion: Int
  package let activeAttemptID: String?
  package let activeAttemptSummary: HarnessContextActiveAttemptSummary?
  package let currentWorkspaceRevision: String?
  package let currentDeployedArtifactDigest: String?
  package let currentDeviceBindingRevision: Int?
  package let disprovedHypotheses: [String]
  package let unavailableOperationsAndReasons: [HarnessContextUnavailableOperation]
  package let currentCapabilityEffectCeiling: WorkflowEffect?
  package let authorizedOperationRefs: [String]
  package let allowedFileScopes: [String]
  package let expectedNextObservation: String?
  package let derivedArtifactSummaries: [HarnessDerivedArtifactSummary]
  package let goalSummary: String
  package let desiredState: [String: JSONValue]
  package let observedMeasurements: [String: JSONValue]
  package let observedSamples: [String: Int]
  package let latestVerdict: HarnessEvaluationVerdict?
  package let criterionResults: [HarnessCriterionResult]
  package let recentAttempts: [HarnessContextAttempt]
  package let unresolvedFailures: [HarnessContextFailure]
  package let relevantMemory: [String]
  package let confirmedFacts: HarnessContextConfirmedFacts
  package let memorySelectionManifest: HarnessMemorySelectionManifest
  public let artifacts: [HarnessContextArtifact]
  /// The files this task is allowed to change, with their current text.
  package let sourceFiles: [HarnessContextSourceFile]
  /// What this round is actually asking for. Without it a model can only
  /// infer the question from the phase, and the one round that matters most —
  /// "propose a patch" — looks indistinguishable from "pick an operation",
  /// which is how a model ends up trying to invoke apply-patch instead of
  /// writing the diff apply-patch would need.
  package let requestedDecision: String?
  package let availableOperations: [String]
  package let budget: HarnessContextBudget
  public let blockers: [String]
  /// What was left out, and why. A trimmed context says so.
  public let trimmed: [String]

  public init(
    targetPseudonym: String,
    taskType: HarnessTaskType,
    status: HarnessTaskLifecycle,
    phase: HarnessTaskStage,
    round: Int,
    currentTaskStateVersion: Int = 0,
    goalSummary: String,
    desiredState: [String: JSONValue],
    observedMeasurements: [String: JSONValue],
    observedSamples: [String: Int],
    latestVerdict: HarnessEvaluationVerdict?,
    criterionResults: [HarnessCriterionResult],
    recentAttempts: [HarnessContextAttempt],
    unresolvedFailures: [HarnessContextFailure],
    relevantMemory: [String],
    confirmedFacts: HarnessContextConfirmedFacts = .init(),
    memorySelectionManifest: HarnessMemorySelectionManifest = .empty,
    artifacts: [HarnessContextArtifact],
    sourceFiles: [HarnessContextSourceFile] = [],
    requestedDecision: String? = nil,
    availableOperations: [String],
    budget: HarnessContextBudget,
    blockers: [String],
    trimmed: [String],
    waitReason: HarnessTaskWaitReason? = nil,
    conditions: [HarnessTaskCondition] = HarnessTaskConditionSet.unknown(),
    executionState: HarnessContextExecutionState = .empty
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.targetPseudonym = targetPseudonym
    self.taskType = taskType
    self.status = status
    self.phase = phase
    self.lifecycle = status
    self.stage = phase
    self.waitReason = waitReason
    self.conditions = HarnessTaskConditionSet.normalized(conditions)
    self.round = round
    self.currentTaskStateVersion = currentTaskStateVersion
    self.activeAttemptID = executionState.activeAttempt?.attemptID
    self.activeAttemptSummary = executionState.activeAttempt.map(
      HarnessContextActiveAttemptSummary.init)
    self.currentWorkspaceRevision = executionState.currentWorkspaceRevision
    self.currentDeployedArtifactDigest = executionState.currentDeployedArtifactDigest
    self.currentDeviceBindingRevision = executionState.currentDeviceBindingRevision
    self.disprovedHypotheses = executionState.disprovedHypotheses
    self.unavailableOperationsAndReasons = executionState.unavailableOperations
    self.currentCapabilityEffectCeiling = executionState.currentCapabilityEffectCeiling
    self.authorizedOperationRefs = executionState.authorizedOperationReferences
    self.allowedFileScopes = executionState.allowedFileScopes
    self.expectedNextObservation =
      executionState.activeAttempt?.strategy.executionExpectation.expectedNextObservation
    self.derivedArtifactSummaries = executionState.derivedArtifactSummaries
    self.goalSummary = goalSummary
    self.desiredState = desiredState
    self.observedMeasurements = observedMeasurements
    self.observedSamples = observedSamples
    self.latestVerdict = latestVerdict
    self.criterionResults = criterionResults
    self.recentAttempts = recentAttempts
    self.unresolvedFailures = unresolvedFailures
    self.relevantMemory = relevantMemory
    self.confirmedFacts = confirmedFacts
    self.memorySelectionManifest = memorySelectionManifest
    self.artifacts = artifacts
    self.sourceFiles = sourceFiles
    self.requestedDecision = requestedDecision
    self.availableOperations = availableOperations
    self.budget = budget
    self.blockers = blockers
    self.trimmed = trimmed
  }

  /// The canonical serialization of this context, and the only one an
  /// adapter may put on the wire (CHG-2026-055, TASK-HFA-002). Sorted keys
  /// and unescaped slashes make it byte-stable, which is what lets
  /// `transmittedDigest` stand for "what the model received" rather than
  /// "what the harness intended to send".
  package var transmittedBytes: Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }

  /// Computed over the trimmed, screened context - so the digest represents
  /// the bytes that left the host, after redaction, not before it.
  package var transmittedDigest: String {
    SHA256Hex.string(of: transmittedBytes)
  }

  package var transmittedByteCount: Int { transmittedBytes.count }

  /// Stable pseudonym for a target id. Deterministic so the same device reads
  /// as the same device across rounds, one-way so the id cannot be recovered.
  package static func pseudonym(forTargetID targetID: String) -> String {
    let hex = SHA256Hex.string(of: Data("arkdeck-harness-target|\(targetID)".utf8))
    return "target-\(hex.prefix(12))"
  }
}

// MARK: - Inbound proposal

package enum HarnessDecisionRejection: Error, Equatable, Sendable {
  case malformedJSON
  case unknownField(String)
  case forbiddenField(String)
  case unknownKind(String)
  case operationRequired
  /// The reference the producer asked for, and what this round actually
  /// offers. Both, because a rejection that names only the refused thing
  /// leaves the producer to guess what to ask for next — and on the
  /// 7.0.0.34 window it guessed the same thing every round until the
  /// no-progress budget ran out.
  case operationNotOffered(String, offered: [String] = [])
  case operationNotExpected(String)
  /// A model may propose a bounded operation or patch, but it cannot end the
  /// task. Human escalation and the conclusion that no safe action remains
  /// belong to the deterministic handler, policy guard and Runtime facts.
  case terminalDecisionNotProposable(HarnessDecisionKind)
  /// The handler is mid-way through an orchestrated step and the route is not
  /// the producer's to change — including by escalating to a human.
  ///
  /// Its own case because reporting it as `operationNotExpected` named the
  /// step the handler wanted, and a producer that proposed no operation was
  /// told its operation was wrong. It then repeated the same escalation two
  /// rounds later (`HTASK-0C535C0E0B87`, rounds 11 and 13), which is what a
  /// refusal that misnames its subject produces.
  case decisionNotYoursDuringOrchestratedStep(proposed: String, step: String)
  case rawCommandSurface(String)
  case oversizedField(String)
  case emptyHypothesis
  case invalidPatch(String)

  public var reasonCode: String {
    switch self {
    case .malformedJSON: return "malformedJson"
    case .unknownField(let field): return "unknownField:\(field)"
    case .forbiddenField(let field): return "forbiddenField:\(field)"
    case .unknownKind(let kind): return "unknownKind:\(kind)"
    case .operationRequired: return "operationRequired"
    case .operationNotOffered(let reference, let offered):
      // An empty offer is its own fact: nothing this round is actionable, which
      // is not the same as "not this one, try another".
      let alternatives = offered.isEmpty ? "none" : offered.sorted().joined(separator: ",")
      return "operationNotOffered:\(reference):offered=\(alternatives)"
    case .operationNotExpected(let reference): return "operationNotExpected:\(reference)"
    case .terminalDecisionNotProposable(let kind):
      return "terminalDecisionNotProposable:\(kind.rawValue)"
    case .decisionNotYoursDuringOrchestratedStep(let proposed, let step):
      return "decisionNotYoursDuringOrchestratedStep:proposed=\(proposed):step=\(step)"
    case .rawCommandSurface(let field): return "rawCommandSurface:\(field)"
    case .oversizedField(let field): return "oversizedField:\(field)"
    case .emptyHypothesis: return "emptyHypothesis"
    case .invalidPatch(let reason): return reason
    }
  }
}

/// Strictly decoded model output. The allowed key set is closed and the
/// forbidden set is explicit, because "ignore what you do not understand" is
/// how a control plane ends up acting on a field it never agreed to.
package struct HarnessDecisionProposal: Equatable, Sendable {
  public let kind: HarnessDecisionKind
  public let operationReference: String?
  public let inputs: [String: JSONValue]
  package let hypothesis: String
  public let reasonCode: String
  package let confidence: Double?
  package let patchProposal: HarnessPatchProposal?
  package let requiredArtifacts: [String]
  package let expectedObservation: String?

  package static let allowedFields: Set<String> = [
    "kind", "operationRef", "operationReference", "inputs", "hypothesis", "reasonCode",
    "confidence", "requiredArtifacts", "expectedObservation",
    "baseWorkspaceRevision", "patchSha256", "unifiedDiff", "touchedFiles",
    "expectedChangedSymbols",
  ]

  private static let patchFields: Set<String> = [
    "baseWorkspaceRevision", "patchSha256", "unifiedDiff", "touchedFiles",
    "expectedChangedSymbols",
  ]

  /// Keys a proposal may never carry. Each one is a decision the harness or
  /// the runtime owns, and accepting it - even as advice - would move that
  /// authority to the model.
  package static let forbiddenFields: Set<String> = [
    "status", "taskstatus", "phase", "jobstate", "jobstatus", "state", "result",
    "retrycount", "retries", "attempt", "attempts", "verdict", "evaluation", "succeeded",
    "success", "fixed", "authorization", "authorized", "capability", "capabilityid",
    "effect", "budget", "consumedbudget", "activejobid", "version", "noprogressrounds",
  ]

  public init(
    kind: HarnessDecisionKind,
    operationReference: String?,
    inputs: [String: JSONValue],
    hypothesis: String,
    reasonCode: String,
    confidence: Double?,
    patchProposal: HarnessPatchProposal? = nil,
    requiredArtifacts: [String] = [],
    expectedObservation: String? = nil
  ) {
    self.kind = kind
    self.operationReference = operationReference
    self.inputs = inputs
    self.hypothesis = hypothesis
    self.reasonCode = reasonCode
    self.confidence = confidence
    self.patchProposal = patchProposal
    self.requiredArtifacts = requiredArtifacts
    self.expectedObservation = expectedObservation
  }

  /// Parse and validate raw model bytes against one context's offer.
  ///
  /// The field cap bounds a *prose* field, and the reason it exists is to keep
  /// an unbounded essay out of a durable record — not to make a real answer
  /// impossible. 1,024 characters refused a correct patch proposal on device
  /// because its `expectedObservation` described what a rebuilt, redeployed
  /// application should show; the diff itself was byte-perfect. 4,096 leaves
  /// room for an honest one and is still two orders of magnitude below the
  /// context envelope.
  public static func parse(
    _ data: Data,
    offeredOperations: Set<String>,
    maximumFieldCharacters: Int = 4_096
  ) throws -> HarnessDecisionProposal {
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let fields) = decoded
    else {
      throw HarnessDecisionRejection.malformedJSON
    }

    for key in fields.keys {
      let normalized = key.lowercased()
      if forbiddenFields.contains(normalized) {
        throw HarnessDecisionRejection.forbiddenField(key)
      }
      guard allowedFields.contains(key) else {
        throw HarnessDecisionRejection.unknownField(key)
      }
    }

    guard case .string(let rawKind)? = fields["kind"],
      let kind = HarnessDecisionKind(rawValue: rawKind)
    else {
      if case .string(let rawKind)? = fields["kind"] {
        throw HarnessDecisionRejection.unknownKind(rawKind)
      }
      throw HarnessDecisionRejection.unknownKind("-")
    }

    var operationReference: String?
    if case .string(let reference)? = fields["operationRef"] {
      operationReference = reference
    } else if case .string(let reference)? = fields["operationReference"] {
      operationReference = reference
    }

    var inputs: [String: JSONValue] = [:]
    if case .object(let declared)? = fields["inputs"] {
      inputs = declared
    }

    guard case .string(let hypothesis)? = fields["hypothesis"],
      !hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw HarnessDecisionRejection.emptyHypothesis
    }
    guard hypothesis.count <= maximumFieldCharacters else {
      throw HarnessDecisionRejection.oversizedField("hypothesis")
    }

    // `reasonCode` is a durable label, not a decision. It has to stay
    // identifier-shaped, because it enters failure fingerprints and prose
    // would splinter one recurring failure into a new fingerprint every round.
    //
    // But a label that arrives as a sentence is a reason to drop the *label*,
    // not the proposal behind it: rejecting the whole decision threw away a
    // sound patch because its name had a space in it, and the loop then
    // spent a round rediscovering the same patch. Keep the invariant, name
    // the field's default, continue.
    var reasonCode = "modelProposal"
    if case .string(let declared)? = fields["reasonCode"],
      declared.count <= 128,
      declared.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
      })
    {
      reasonCode = declared
    }

    var confidence: Double?
    switch fields["confidence"] {
    case .number(let value): confidence = value
    case .integer(let value): confidence = Double(value)
    default: confidence = nil
    }

    var requiredArtifacts: [String] = []
    if case .array(let values)? = fields["requiredArtifacts"] {
      guard values.count <= 64 else {
        throw HarnessDecisionRejection.oversizedField("requiredArtifacts")
      }
      requiredArtifacts = try values.map { value in
        guard case .string(let text) = value,
          !text.isEmpty, text.utf8.count <= 256,
          !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          })
        else {
          throw HarnessDecisionRejection.oversizedField("requiredArtifacts")
        }
        return text
      }
      guard Set(requiredArtifacts).count == requiredArtifacts.count else {
        throw HarnessDecisionRejection.oversizedField("requiredArtifacts")
      }
    } else if fields["requiredArtifacts"] != nil {
      throw HarnessDecisionRejection.oversizedField("requiredArtifacts")
    }
    // Same treatment as `reasonCode`, and for the same reason: this is a
    // label on the strategy record, not the decision. It stays bounded and
    // control-character free because it enters the durable strategy identity,
    // but a sentence that ran past the bound now costs the label rather than
    // the patch it was attached to. The consumption site already has a
    // default for an absent expectation.
    //
    // A non-string is still a refusal: that is a caller sending the wrong
    // shape, not a caller being wordy.
    var expectedObservation: String?
    if case .string(let value)? = fields["expectedObservation"] {
      if !value.isEmpty, value.utf8.count <= 256,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      {
        expectedObservation = value
      }
    } else if fields["expectedObservation"] != nil {
      throw HarnessDecisionRejection.oversizedField("expectedObservation")
    }

    // Raw-surface screening applies to inputs *and* to every string the
    // proposal carries: a shell fragment smuggled through `hypothesis` is
    // still a shell fragment in the durable record. Prose is screened for
    // command *shapes* rather than for punctuation, because an explanation
    // that quotes the guard it is changing is an explanation.
    if let refusal = HarnessRawSurfaceScreen.screen(inputs) {
      throw HarnessDecisionRejection.rawCommandSurface(refusal.reasonCode)
    }
    let strategyStrings: [String: JSONValue] = [
      "hypothesis": .string(hypothesis),
      "requiredArtifacts": .array(requiredArtifacts.map(JSONValue.string)),
      "expectedObservation": expectedObservation.map(JSONValue.string) ?? .null,
    ]
    if let offending = HarnessRawSurfaceScreen.screenProse(strategyStrings) {
      throw HarnessDecisionRejection.rawCommandSurface(offending.reasonCode)
    }

    var patchProposal: HarnessPatchProposal?
    switch kind {
    case .invokeOperation:
      if let field = patchFields.first(where: { fields[$0] != nil }) {
        throw HarnessDecisionRejection.invalidPatch("patchFieldRequiresProposePatch:\(field)")
      }
      guard let operationReference else { throw HarnessDecisionRejection.operationRequired }
      guard offeredOperations.contains(operationReference) else {
        // Not merely "not permitted": the model was told exactly which
        // operations were on the table this round.
        throw HarnessDecisionRejection.operationNotOffered(
          operationReference, offered: Array(offeredOperations))
      }
    case .proposePatch:
      if fields["operationRef"] != nil || fields["operationReference"] != nil {
        throw HarnessDecisionRejection.invalidPatch("proposePatchCannotSelectOperation")
      }
      if fields["inputs"] != nil {
        throw HarnessDecisionRejection.invalidPatch("proposePatchCannotDeclareInputs")
      }
      guard offeredOperations.contains("workspace.apply-patch@1") else {
        throw HarnessDecisionRejection.operationNotOffered(
          "workspace.apply-patch@1", offered: Array(offeredOperations))
      }
      do {
        patchProposal = try HarnessPatchProposal.parse(fields)
      } catch let error as HarnessPatchProposalError {
        throw HarnessDecisionRejection.invalidPatch(error.reasonCode)
      }
    case .requestHuman, .noSafeAction:
      if let field = patchFields.first(where: { fields[$0] != nil }) {
        throw HarnessDecisionRejection.invalidPatch("patchFieldRequiresProposePatch:\(field)")
      }
      break
    }

    return HarnessDecisionProposal(
      kind: kind, operationReference: operationReference, inputs: inputs,
      hypothesis: hypothesis, reasonCode: reasonCode, confidence: confidence,
      patchProposal: patchProposal, requiredArtifacts: requiredArtifacts,
      expectedObservation: expectedObservation)
  }
}
