// The bounded decision context and the strict proposal shape
// (CHG-2026-054, TASK-HTP-004).
//
// This is the only place where something outside the repository gets to
// influence what the harness does next, so both directions are narrowed:
//
//   * outbound - the context is assembled from declared fields with hard
//     counts and a byte ceiling. No raw artifact bytes, no connect key, no
//     device serial, no stable identity digest. The target travels as a
//     pseudonym, because a model needs to know "the same device as last
//     round", never which device it is;
//   * inbound - a proposal is decoded with a closed key set and may carry
//     only a next step. It cannot carry a task or job state, a retry count,
//     an authorization result or a success claim: those keys are rejected
//     rather than ignored, so a model that tries to declare the task fixed
//     produces a refusal instead of a silent no-op (HTP-INV-1).
//
// Nothing here talks to a model. Transport is a port in the workflow module;
// this file is the contract both sides are held to.

import CryptoKit
import Foundation

public struct HarnessDecisionContextLimits: Equatable, Sendable, Codable {
  public let maxAttempts: Int
  public let maxFailures: Int
  public let maxMemories: Int
  public let maxArtifacts: Int
  public let maxOperations: Int
  public let maxSummaryCharacters: Int
  /// Ceiling on the encoded context. Exceeding it trims, and the trim is
  /// recorded in the context itself - a silently shortened context is a
  /// context nobody can reason about afterwards.
  public let maxEncodedBytes: Int

  public init(
    maxAttempts: Int = 5,
    maxFailures: Int = 5,
    maxMemories: Int = 8,
    maxArtifacts: Int = 12,
    maxOperations: Int = 16,
    maxSummaryCharacters: Int = 480,
    maxEncodedBytes: Int = 32 * 1024
  ) {
    self.maxAttempts = maxAttempts
    self.maxFailures = maxFailures
    self.maxMemories = maxMemories
    self.maxArtifacts = maxArtifacts
    self.maxOperations = maxOperations
    self.maxSummaryCharacters = maxSummaryCharacters
    self.maxEncodedBytes = maxEncodedBytes
  }

  public static let `default` = HarnessDecisionContextLimits()
}

public struct HarnessContextAttempt: Equatable, Sendable, Codable {
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

public struct HarnessContextFailure: Equatable, Sendable, Codable {
  public let digest: String
  public let operationReference: String
  public let occurrences: Int
  public let stance: HarnessRetryStance
  public let errorClassification: String
  public let semanticErrorCode: String

  public init(
    digest: String,
    operationReference: String,
    occurrences: Int,
    stance: HarnessRetryStance,
    errorClassification: String,
    semanticErrorCode: String
  ) {
    self.digest = digest
    self.operationReference = operationReference
    self.occurrences = occurrences
    self.stance = stance
    self.errorClassification = errorClassification
    self.semanticErrorCode = semanticErrorCode
  }
}

/// An artifact as a model may see it: identity, size, digest prefix and
/// whether it verified. Never content.
public struct HarnessContextArtifact: Equatable, Sendable, Codable {
  public let artifactID: String
  public let name: String
  public let byteCount: Int
  public let sha256Prefix: String
  public let verified: Bool

  enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case name
    case byteCount
    case sha256Prefix
    case verified
  }

  public init(
    artifactID: String, name: String, byteCount: Int, sha256Prefix: String, verified: Bool
  ) {
    self.artifactID = artifactID
    self.name = name
    self.byteCount = byteCount
    self.sha256Prefix = sha256Prefix
    self.verified = verified
  }
}

public struct HarnessContextBudget: Equatable, Sendable, Codable {
  public let roundsRemaining: Int
  public let wallClockSecondsRemaining: Int
  public let artifactBytesRemaining: Int
  public let e1MutationsRemaining: Int

  public init(
    roundsRemaining: Int,
    wallClockSecondsRemaining: Int,
    artifactBytesRemaining: Int,
    e1MutationsRemaining: Int
  ) {
    self.roundsRemaining = roundsRemaining
    self.wallClockSecondsRemaining = wallClockSecondsRemaining
    self.artifactBytesRemaining = artifactBytesRemaining
    self.e1MutationsRemaining = e1MutationsRemaining
  }
}

public struct HarnessDecisionContext: Equatable, Sendable, Codable {
  public static let documentType = "harness-decision-context"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  /// Pseudonymous, stable within a task: enough to reason about "the same
  /// target as before", not enough to identify a device.
  public let targetPseudonym: String
  public let taskType: HarnessTaskType
  public let status: HarnessTaskStatus
  public let phase: HarnessTaskPhase
  public let round: Int
  public let goalSummary: String
  public let desiredState: [String: JSONValue]
  public let observedMeasurements: [String: JSONValue]
  public let observedSamples: [String: Int]
  public let latestVerdict: HarnessEvaluationVerdict?
  public let criterionResults: [HarnessCriterionResult]
  public let recentAttempts: [HarnessContextAttempt]
  public let unresolvedFailures: [HarnessContextFailure]
  public let relevantMemory: [String]
  public let artifacts: [HarnessContextArtifact]
  public let availableOperations: [String]
  public let budget: HarnessContextBudget
  public let blockers: [String]
  /// What was left out, and why. A trimmed context says so.
  public let trimmed: [String]

  public init(
    targetPseudonym: String,
    taskType: HarnessTaskType,
    status: HarnessTaskStatus,
    phase: HarnessTaskPhase,
    round: Int,
    goalSummary: String,
    desiredState: [String: JSONValue],
    observedMeasurements: [String: JSONValue],
    observedSamples: [String: Int],
    latestVerdict: HarnessEvaluationVerdict?,
    criterionResults: [HarnessCriterionResult],
    recentAttempts: [HarnessContextAttempt],
    unresolvedFailures: [HarnessContextFailure],
    relevantMemory: [String],
    artifacts: [HarnessContextArtifact],
    availableOperations: [String],
    budget: HarnessContextBudget,
    blockers: [String],
    trimmed: [String]
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.targetPseudonym = targetPseudonym
    self.taskType = taskType
    self.status = status
    self.phase = phase
    self.round = round
    self.goalSummary = goalSummary
    self.desiredState = desiredState
    self.observedMeasurements = observedMeasurements
    self.observedSamples = observedSamples
    self.latestVerdict = latestVerdict
    self.criterionResults = criterionResults
    self.recentAttempts = recentAttempts
    self.unresolvedFailures = unresolvedFailures
    self.relevantMemory = relevantMemory
    self.artifacts = artifacts
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
  public var transmittedBytes: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }

  /// Computed over the trimmed, screened context - so the digest represents
  /// the bytes that left the host, after redaction, not before it.
  public var transmittedDigest: String {
    SHA256.hash(data: transmittedBytes).map { String(format: "%02x", $0) }.joined()
  }

  public var transmittedByteCount: Int { transmittedBytes.count }

  /// Stable pseudonym for a target id. Deterministic so the same device reads
  /// as the same device across rounds, one-way so the id cannot be recovered.
  public static func pseudonym(forTargetID targetID: String) -> String {
    let hex = SHA256.hash(data: Data("arkdeck-harness-target|\(targetID)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "target-\(hex.prefix(12))"
  }
}

// MARK: - Inbound proposal

public enum HarnessDecisionRejection: Error, Equatable, Sendable {
  case malformedJSON
  case unknownField(String)
  case forbiddenField(String)
  case unknownKind(String)
  case operationRequired
  case operationNotOffered(String)
  case rawCommandSurface(String)
  case oversizedField(String)
  case emptyHypothesis

  public var reasonCode: String {
    switch self {
    case .malformedJSON: return "malformedJson"
    case .unknownField(let field): return "unknownField:\(field)"
    case .forbiddenField(let field): return "forbiddenField:\(field)"
    case .unknownKind(let kind): return "unknownKind:\(kind)"
    case .operationRequired: return "operationRequired"
    case .operationNotOffered(let reference): return "operationNotOffered:\(reference)"
    case .rawCommandSurface(let field): return "rawCommandSurface:\(field)"
    case .oversizedField(let field): return "oversizedField:\(field)"
    case .emptyHypothesis: return "emptyHypothesis"
    }
  }
}

/// Strictly decoded model output. The allowed key set is closed and the
/// forbidden set is explicit, because "ignore what you do not understand" is
/// how a control plane ends up acting on a field it never agreed to.
public struct HarnessDecisionProposal: Equatable, Sendable {
  public let kind: HarnessDecisionKind
  public let operationReference: String?
  public let inputs: [String: JSONValue]
  public let hypothesis: String
  public let reasonCode: String
  public let confidence: Double?

  public static let allowedFields: Set<String> = [
    "kind", "operationRef", "operationReference", "inputs", "hypothesis", "reasonCode",
    "confidence", "requiredArtifacts", "expectedObservation",
  ]

  /// Keys a proposal may never carry. Each one is a decision the harness or
  /// the runtime owns, and accepting it - even as advice - would move that
  /// authority to the model.
  public static let forbiddenFields: Set<String> = [
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
    confidence: Double?
  ) {
    self.kind = kind
    self.operationReference = operationReference
    self.inputs = inputs
    self.hypothesis = hypothesis
    self.reasonCode = reasonCode
    self.confidence = confidence
  }

  /// Parse and validate raw model bytes against one context's offer.
  public static func parse(
    _ data: Data,
    offeredOperations: Set<String>,
    maximumFieldCharacters: Int = 1024
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

    var reasonCode = "modelProposal"
    if case .string(let declared)? = fields["reasonCode"] {
      guard declared.count <= 128,
        declared.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        })
      else {
        throw HarnessDecisionRejection.oversizedField("reasonCode")
      }
      reasonCode = declared
    }

    var confidence: Double?
    switch fields["confidence"] {
    case .number(let value): confidence = value
    case .integer(let value): confidence = Double(value)
    default: confidence = nil
    }

    // Raw-surface screening applies to inputs *and* to every string the
    // proposal carries: a shell fragment smuggled through `hypothesis` is
    // still a shell fragment in the durable record.
    if let refusal = HarnessRawSurfaceScreen.screen(inputs) {
      throw HarnessDecisionRejection.rawCommandSurface(refusal.reasonCode)
    }
    if let offending = HarnessRawSurfaceScreen.screen(["hypothesis": .string(hypothesis)]) {
      throw HarnessDecisionRejection.rawCommandSurface(offending.reasonCode)
    }

    switch kind {
    case .invokeOperation:
      guard let operationReference else { throw HarnessDecisionRejection.operationRequired }
      guard offeredOperations.contains(operationReference) else {
        // Not merely "not permitted": the model was told exactly which
        // operations were on the table this round.
        throw HarnessDecisionRejection.operationNotOffered(operationReference)
      }
    case .requestHuman, .noSafeAction:
      break
    }

    return HarnessDecisionProposal(
      kind: kind, operationReference: operationReference, inputs: inputs,
      hypothesis: hypothesis, reasonCode: reasonCode, confidence: confidence)
  }
}
