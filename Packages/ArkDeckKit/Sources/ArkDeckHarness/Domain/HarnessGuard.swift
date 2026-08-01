// Bounded-execution model: budgets, failure fingerprints, progress and the
// guard verdict (CHG-2026-054, TASK-HTP-003).
//
// This is the half of the harness that decides *not* to act. Three rules
// carry the weight:
//
//   * a budget is a stop, never a "try once more". Exhaustion ends the task
//     with the budget's own reason code;
//   * the same failure twice does not earn a third identical attempt. A
//     fingerprint groups failures by what actually determines them, and the
//     second occurrence forces a different strategy - where "different"
//     means a different operation, inputs, phase, patch region or recovery
//     path, not a reworded hypothesis;
//   * a round that produced no new evidence, no verdict change and no phase
//     change made no progress, however much text it generated.
//
// Everything here is pure so the same history always yields the same
// stance, in a test and in the daemon.

import ArkDeckCore
import CryptoKit
import Foundation

public enum HarnessBudgetKind: String, CaseIterable, Codable, Sendable {
  case rounds
  case wallClock
  case artifactBytes
  /// Model calls are their own ceiling (CHG-2026-055, TASK-HFA-011): a loop
  /// that stops making progress can still burn a vendor bill, and rounds do
  /// not bound it - one round can spend a call and dispatch nothing.
  case modelCalls
  case e1Mutations
  case noProgressRounds
  case actionRetriesPerRun

  public var reasonCode: String {
    switch self {
    case .rounds: return "maxRoundsExhausted"
    case .wallClock: return "maxWallClockExhausted"
    case .artifactBytes: return "maxArtifactBytesExhausted"
    case .e1Mutations: return "maxE1MutationsExhausted"
    case .noProgressRounds: return "maxNoProgressRoundsExhausted"
    case .actionRetriesPerRun: return "maxActionRetriesPerRunExhausted"
    case .modelCalls: return "maxModelCallsExhausted"
    }
  }
}

/// What a failure *is*, for the purpose of not repeating it. Deliberately
/// excludes free text: two failures with different prose but the same
/// operation, inputs, phase and error class are the same failure.
public struct HarnessFailureFingerprint: Equatable, Sendable, Codable {
  public let operationReference: String
  public let phase: HarnessTaskPhase
  public let providerID: String
  public let targetProfile: String
  public let normalizedInputsSHA256: String
  public let errorClassification: String
  public let semanticErrorCode: String

  enum CodingKeys: String, CodingKey {
    case operationReference
    case phase
    case providerID = "providerId"
    case targetProfile
    case normalizedInputsSHA256 = "normalizedInputsSha256"
    case errorClassification
    case semanticErrorCode
  }

  public init(
    operationReference: String,
    phase: HarnessTaskPhase,
    providerID: String,
    targetProfile: String,
    normalizedInputsSHA256: String,
    errorClassification: String,
    semanticErrorCode: String
  ) {
    self.operationReference = operationReference
    self.phase = phase
    self.providerID = providerID
    self.targetProfile = targetProfile
    self.normalizedInputsSHA256 = normalizedInputsSHA256
    self.errorClassification = errorClassification
    self.semanticErrorCode = semanticErrorCode
  }

  /// Stable, filename-safe digest: the failure memory record is named after
  /// it, so a traversal cannot be spelled.
  public var digest: String {
    let material = [
      operationReference, phase.rawValue, providerID, targetProfile,
      normalizedInputsSHA256, errorClassification, semanticErrorCode,
    ].joined(separator: "|")
    let hex = SHA256.hash(data: Data(material.utf8))
      .map { String(format: "%02X", $0) }.joined()
    return "FAIL-\(hex.prefix(16))"
  }

  /// Semantic build/test/revision failures cannot become action retries. The
  /// same bytes or command against the same facts will not improve; the next
  /// decision must change strategy (TASK-HFA-003).
  public var retryDisposition: HarnessFailureRetryDisposition {
    switch errorClassification {
    case "BUILD_SEMANTIC_FAILURE", "TEST_FAILURE", "WORKSPACE_REVISION_CONFLICT":
      return .alternativeRequired
    case "RATE_LIMITED", "SERVICE_UNAVAILABLE":
      return .retryAfterBackoff
    case "DEVICE_UNAVAILABLE", "OBSERVATION_INCOMPLETE":
      return .retryAfterObservation
    case "POLICY_DENIED", "AUTHORIZATION_REQUIRED", "UNSUPPORTED":
      return .doNotRetry
    default:
      return .actionRetryAllowed
    }
  }

  /// Typed next directions, never executable text. They explain what must
  /// change when the same action is not a valid retry.
  public var alternativeHints: [String] {
    switch errorClassification {
    case "BUILD_SEMANTIC_FAILURE":
      return ["inspectBuildFailure", "changePatchStrategy", "changeToolchainPreset"]
    case "TEST_FAILURE":
      return ["inspectTestEvidence", "changePatchStrategy"]
    case "WORKSPACE_REVISION_CONFLICT":
      return ["refreshWorkspaceRevision", "replanAgainstExactRevision"]
    case "RATE_LIMITED", "SERVICE_UNAVAILABLE":
      return ["waitForBackoff"]
    case "DEVICE_UNAVAILABLE", "OBSERVATION_INCOMPLETE":
      return ["refreshObservation"]
    case "POLICY_DENIED", "AUTHORIZATION_REQUIRED", "UNSUPPORTED":
      return ["requestHumanReview"]
    default:
      return []
    }
  }
}

public enum HarnessFailureRetryDisposition: String, CaseIterable, Codable, Sendable {
  case actionRetryAllowed = "ACTION_RETRY_ALLOWED"
  case retryAfterBackoff = "RETRY_AFTER_BACKOFF"
  case retryAfterObservation = "RETRY_AFTER_OBSERVATION"
  case alternativeRequired = "ALTERNATIVE_REQUIRED"
  case doNotRetry = "DO_NOT_RETRY"
}

public enum HarnessRetryStance: String, CaseIterable, Codable, Sendable {
  /// First occurrence: the same strategy may be retried when the operation
  /// is retry-safe.
  case allowSameStrategy
  /// Second occurrence: an identical decision is refused; something about
  /// the approach has to change.
  case requireNewStrategy
  /// Third and beyond: the harness stops. Repetition is not a plan.
  case prohibited

  public static func stance(forOccurrences occurrences: Int) -> HarnessRetryStance {
    switch occurrences {
    case ..<1: return .allowSameStrategy
    case 1: return .allowSameStrategy
    case 2: return .requireNewStrategy
    default: return .prohibited
    }
  }
}

public struct HarnessFailureRecord: Equatable, Sendable, Codable {
  public static let documentType = "harness-failure-memory"

  public let documentType: String
  public let digest: String
  public let fingerprint: HarnessFailureFingerprint
  public let occurrences: Int
  public let firstSeenUTC: String
  public let lastSeenUTC: String
  public let lastReasonCode: String
  public let retryDisposition: HarnessFailureRetryDisposition
  public let alternativeHints: [String]
  /// Task ids that hit this failure. Cross-task on purpose: the second task
  /// to try the same doomed thing should not have to rediscover it.
  public let observedByTasks: [String]

  enum CodingKeys: String, CodingKey {
    case documentType
    case digest
    case fingerprint
    case occurrences
    case firstSeenUTC = "firstSeenUtc"
    case lastSeenUTC = "lastSeenUtc"
    case lastReasonCode
    case retryDisposition
    case alternativeHints
    case observedByTasks
  }

  public init(
    fingerprint: HarnessFailureFingerprint,
    occurrences: Int,
    firstSeenUTC: String,
    lastSeenUTC: String,
    lastReasonCode: String,
    observedByTasks: [String],
    retryDisposition: HarnessFailureRetryDisposition? = nil,
    alternativeHints: [String]? = nil
  ) {
    self.documentType = Self.documentType
    self.digest = fingerprint.digest
    self.fingerprint = fingerprint
    self.occurrences = occurrences
    self.firstSeenUTC = firstSeenUTC
    self.lastSeenUTC = lastSeenUTC
    self.lastReasonCode = lastReasonCode
    self.retryDisposition = retryDisposition ?? fingerprint.retryDisposition
    self.alternativeHints = Array(Set(alternativeHints ?? fingerprint.alternativeHints)).sorted()
    self.observedByTasks = observedByTasks
  }

  /// Old failure rows derive the new closed guidance from their immutable
  /// fingerprint. Nothing is guessed from the free-text reason.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fingerprint = try container.decode(HarnessFailureFingerprint.self, forKey: .fingerprint)
    self.documentType =
      try container.decodeIfPresent(String.self, forKey: .documentType) ?? Self.documentType
    self.digest = try container.decodeIfPresent(String.self, forKey: .digest)
      ?? fingerprint.digest
    self.fingerprint = fingerprint
    self.occurrences = try container.decode(Int.self, forKey: .occurrences)
    self.firstSeenUTC = try container.decode(String.self, forKey: .firstSeenUTC)
    self.lastSeenUTC = try container.decode(String.self, forKey: .lastSeenUTC)
    self.lastReasonCode = try container.decode(String.self, forKey: .lastReasonCode)
    self.retryDisposition =
      try container.decodeIfPresent(HarnessFailureRetryDisposition.self, forKey: .retryDisposition)
      ?? fingerprint.retryDisposition
    self.alternativeHints =
      try container.decodeIfPresent([String].self, forKey: .alternativeHints)
      ?? fingerprint.alternativeHints
    self.observedByTasks = try container.decode([String].self, forKey: .observedByTasks)
  }

  public var stance: HarnessRetryStance {
    HarnessRetryStance.stance(forOccurrences: occurrences)
  }

  public func recording(taskID: String, reasonCode: String, atUTC: String) -> HarnessFailureRecord {
    HarnessFailureRecord(
      fingerprint: fingerprint,
      occurrences: occurrences + 1,
      firstSeenUTC: firstSeenUTC,
      lastSeenUTC: atUTC,
      lastReasonCode: reasonCode,
      observedByTasks: observedByTasks.contains(taskID)
        ? observedByTasks : observedByTasks + [taskID],
      retryDisposition: retryDisposition,
      alternativeHints: alternativeHints)
  }
}

/// The identity of a *strategy*, used to answer "is this the same attempt
/// again?". Hypothesis text is excluded by construction: rewording is not a
/// new strategy.
public struct HarnessStrategySignature: Equatable, Sendable, Codable {
  public let operationReference: String
  public let inputsDigest: String
  public let phase: HarnessTaskPhase

  public init(operationReference: String, inputsDigest: String, phase: HarnessTaskPhase) {
    self.operationReference = operationReference
    self.inputsDigest = inputsDigest
    self.phase = phase
  }
}

/// Did this round move anything? Computed from persisted state only.
public struct HarnessProgressVector: Equatable, Sendable, Codable {
  public let verdictChanged: Bool
  public let evaluationRecorded: Bool
  public let newVerifiedEvidenceCount: Int
  public let sampleDelta: Int
  public let phaseChanged: Bool
  public let newFailureCount: Int
  public let resolvedFailureCount: Int
  public let workspaceRevisionChanged: Bool

  enum CodingKeys: String, CodingKey {
    case verdictChanged
    case evaluationRecorded
    case newVerifiedEvidenceCount
    case sampleDelta
    case phaseChanged
    case newFailureCount
    case resolvedFailureCount
    case workspaceRevisionChanged
  }

  public init(
    verdictChanged: Bool,
    evaluationRecorded: Bool,
    newVerifiedEvidenceCount: Int,
    sampleDelta: Int,
    phaseChanged: Bool,
    newFailureCount: Int,
    resolvedFailureCount: Int,
    workspaceRevisionChanged: Bool = false
  ) {
    self.verdictChanged = verdictChanged
    self.evaluationRecorded = evaluationRecorded
    self.newVerifiedEvidenceCount = newVerifiedEvidenceCount
    self.sampleDelta = sampleDelta
    self.phaseChanged = phaseChanged
    self.newFailureCount = newFailureCount
    self.resolvedFailureCount = resolvedFailureCount
    self.workspaceRevisionChanged = workspaceRevisionChanged
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    verdictChanged = try container.decode(Bool.self, forKey: .verdictChanged)
    evaluationRecorded = try container.decode(Bool.self, forKey: .evaluationRecorded)
    newVerifiedEvidenceCount = try container.decode(
      Int.self, forKey: .newVerifiedEvidenceCount)
    sampleDelta = try container.decode(Int.self, forKey: .sampleDelta)
    phaseChanged = try container.decode(Bool.self, forKey: .phaseChanged)
    newFailureCount = try container.decode(Int.self, forKey: .newFailureCount)
    resolvedFailureCount = try container.decode(Int.self, forKey: .resolvedFailureCount)
    workspaceRevisionChanged =
      try container.decodeIfPresent(Bool.self, forKey: .workspaceRevisionChanged) ?? false
  }

  /// New analysis prose, another evaluation row, a phase move, or another
  /// decision fingerprint is not progress. Only evidence, a changed verdict,
  /// a sample, an actually changed workspace revision, or a resolved failure
  /// moves the vector.
  public var isProgress: Bool {
    verdictChanged || newVerifiedEvidenceCount > 0 || sampleDelta > 0
      || resolvedFailureCount > 0 || workspaceRevisionChanged
  }
}

public enum HarnessGuardRefusal: Equatable, Sendable {
  case budgetExhausted(HarnessBudgetKind)
  case operationNotPermitted(String)
  case operationUnavailable(reference: String, reason: String)
  case effectAboveCeiling(reference: String, effect: String)
  case authorizationRequired(reference: String, effect: String)
  case destructiveEffectNeverAutomated(reference: String)
  case repeatedFailureNeedsNewStrategy(digest: String, occurrences: Int)
  case repeatedFailureProhibited(digest: String, occurrences: Int)
  case noProgress(rounds: Int)
  case rawCommandSurface(field: String)
  case activeJobConflict(String)

  public var reasonCode: String {
    switch self {
    case .budgetExhausted(let kind): return kind.reasonCode
    case .operationNotPermitted(let reference): return "operationNotPermitted:\(reference)"
    case .operationUnavailable(let reference, _): return "operationUnavailable:\(reference)"
    case .effectAboveCeiling(let reference, let effect):
      return "effectAboveCeiling:\(reference):\(effect)"
    case .authorizationRequired(let reference, let effect):
      return "authorizationRequired:\(reference):\(effect)"
    case .destructiveEffectNeverAutomated(let reference):
      return "destructiveEffectNeverAutomated:\(reference)"
    case .repeatedFailureNeedsNewStrategy(let digest, let occurrences):
      return "repeatedFailureNeedsNewStrategy:\(digest):\(occurrences)"
    case .repeatedFailureProhibited(let digest, let occurrences):
      return "repeatedFailureProhibited:\(digest):\(occurrences)"
    case .noProgress(let rounds): return "noProgressRounds:\(rounds)"
    case .rawCommandSurface(let field): return "rawCommandSurface:\(field)"
    case .activeJobConflict(let jobID): return "activeJobConflict:\(jobID)"
    }
  }

  /// Whether the refusal is a stop for a human, and which human action it
  /// corresponds to. `nil` means the loop may still change strategy.
  public var humanCategory: HarnessHumanBlock? {
    switch self {
    case .authorizationRequired, .destructiveEffectNeverAutomated:
      return .authorizationApproval
    case .repeatedFailureProhibited, .noProgress, .repeatedFailureNeedsNewStrategy:
      return .strategyExhausted
    case .operationUnavailable:
      return .environmentUnavailable
    case .budgetExhausted, .operationNotPermitted, .effectAboveCeiling,
      .rawCommandSurface, .activeJobConflict:
      return nil
    }
  }
}

/// The kinds of human block the harness can produce. Only the first two map
/// onto the closed `HumanActionRequired` category vocabulary; the rest carry
/// a status and a reason code, because inventing a category would put an
/// untrue minimum-action into an evidence-grade document.
public enum HarnessHumanBlock: String, CaseIterable, Codable, Sendable {
  case authorizationApproval
  case outcomeUnknown
  case strategyExhausted
  case evidenceIntegrity
  /// The runtime says the operation cannot run here (no tool configured, no
  /// adopted target, provider unregistered). A human changes the environment;
  /// no amount of retrying changes it.
  case environmentUnavailable
}

public enum HarnessGuardVerdict: Equatable, Sendable {
  case allow
  case refuse(HarnessGuardRefusal)
}

/// Raw-surface screen for typed inputs. The runtime rejects executable
/// surfaces too; this is the earlier, cheaper refusal that also names the
/// offending field in the task's own record (HTP-INV-11).
public enum HarnessRawSurfaceScreen {
  static let forbiddenKeys: Set<String> = [
    "argv", "args", "command", "cmd", "executable", "exec", "shell", "script",
    "hdc", "remotepath", "path", "binary", "interpreter", "env",
  ]

  static let forbiddenValueFragments: [String] = [
    "/data/local/tmp", "/system/", "hdc ", "sh -c", "bash -c", "&&", "||", ";rm", "|",
    "$(", "`",
  ]

  public static func screen(_ inputs: [String: JSONValue]) -> HarnessGuardRefusal? {
    for key in inputs.keys {
      if forbiddenKeys.contains(key.lowercased()) {
        return .rawCommandSurface(field: key)
      }
    }
    for (key, value) in inputs {
      guard let text = stringValue(value) else { continue }
      let lowered = text.lowercased()
      for fragment in forbiddenValueFragments where lowered.contains(fragment) {
        return .rawCommandSurface(field: "\(key)=\(fragment)")
      }
    }
    return nil
  }

  private static func stringValue(_ value: JSONValue) -> String? {
    switch value {
    case .string(let text): return text
    case .array(let entries):
      let parts = entries.compactMap(stringValue)
      return parts.isEmpty ? nil : parts.joined(separator: " ")
    case .object(let fields):
      let parts = fields.values.compactMap(stringValue)
      return parts.isEmpty ? nil : parts.joined(separator: " ")
    default: return nil
    }
  }
}
