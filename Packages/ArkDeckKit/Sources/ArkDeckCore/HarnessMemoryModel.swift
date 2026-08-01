// Three-layer memory model (CHG-2026-054, TASK-HTP-003).
//
// Memory here is a typed fact with evidence attached, not a chat log. The
// promotion rule is the point: task memory records what a round observed,
// and only a fact the evaluator passed on verified evidence - or one a human
// confirmed - may be written to project memory. An unverified guess never
// becomes long-lived knowledge (CHG-2026-054 HTP-INV-1/HTP-INV-2).

import CryptoKit
import Foundation

public enum HarnessMemoryScope: String, CaseIterable, Codable, Sendable {
  case task
  case project
  case failure
}

public enum HarnessMemoryKind: String, CaseIterable, Codable, Sendable {
  case fact
  case attempt
  case observation
  case openIssue
  case verifiedKnowledge
}

/// Where a memory came from. Project memory requires `evaluated` or
/// `humanConfirmed`; nothing else may be promoted.
public enum HarnessMemoryConfidence: String, CaseIterable, Codable, Sendable {
  case observed
  case evaluated
  case humanConfirmed
}

/// Durable lifecycle of one memory fact (CHG-2026-055, TASK-HFA-010).
///
/// Confidence says where a statement came from. Lifecycle says whether the
/// harness may still use it. Keeping the two separate prevents an old
/// `evaluated` statement from remaining current after it was superseded or
/// invalidated.
public enum HarnessMemoryLifecycle: String, CaseIterable, Codable, Sendable {
  case candidate = "CANDIDATE"
  case verified = "VERIFIED"
  case superseded = "SUPERSEDED"
  case invalidated = "INVALIDATED"
}

public enum HarnessMemoryVerificationSource: String, CaseIterable, Codable, Sendable {
  case evaluatorPass = "EVALUATOR_PASS"
  case humanConfirmation = "HUMAN_CONFIRMATION"
}

public struct HarnessMemoryVerification: Equatable, Sendable, Codable {
  public let source: HarnessMemoryVerificationSource
  /// A required, durable evaluation or human-action identity. Free text is
  /// never a promotion receipt.
  public let evidenceID: String
  public let verifiedAtUTC: String

  enum CodingKeys: String, CodingKey {
    case source
    case evidenceID = "evidenceId"
    case verifiedAtUTC = "verifiedAtUtc"
  }

  public init(
    source: HarnessMemoryVerificationSource,
    evidenceID: String,
    verifiedAtUTC: String
  ) {
    self.source = source
    self.evidenceID = evidenceID
    self.verifiedAtUTC = verifiedAtUTC
  }
}

/// Exact revisions in which a memory is valid. An empty set is deliberately
/// unusable rather than a wildcard: missing revision evidence cannot grant a
/// cross-revision fact.
public struct HarnessMemoryRevisionScope: Equatable, Sendable, Codable {
  public let exactRevisions: [String]

  public init(exactRevisions: [String]) {
    self.exactRevisions = Self.normalized(exactRevisions)
  }

  public init(exactRevision: String) {
    self.init(exactRevisions: [exactRevision])
  }

  public var isUsable: Bool { !exactRevisions.isEmpty }

  private static func normalized(_ values: [String]) -> [String] {
    Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })).sorted()
  }
}

/// Closed applicability dimensions. Filtering is conjunctive: every
/// non-empty dimension on a project memory must find an exact match in the
/// current query before ranking begins.
public struct HarnessMemoryApplicability: Equatable, Sendable, Codable {
  public let component: String?
  public let symbols: [String]
  public let filePaths: [String]
  public let failureFingerprints: [String]
  public let operationReferences: [String]
  public let revisionScope: HarnessMemoryRevisionScope
  public let deviceProfiles: [String]
  public let toolchainProfiles: [String]

  public init(
    component: String? = nil,
    symbols: [String] = [],
    filePaths: [String] = [],
    failureFingerprints: [String] = [],
    operationReferences: [String] = [],
    revisionScope: HarnessMemoryRevisionScope = .init(exactRevisions: []),
    deviceProfiles: [String] = [],
    toolchainProfiles: [String] = []
  ) {
    let trimmed = component?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.component = trimmed?.isEmpty == false ? trimmed : nil
    self.symbols = Self.normalized(symbols)
    self.filePaths = Self.normalized(filePaths)
    self.failureFingerprints = Self.normalized(failureFingerprints)
    self.operationReferences = Self.normalized(operationReferences)
    self.revisionScope = revisionScope
    self.deviceProfiles = Self.normalized(deviceProfiles)
    self.toolchainProfiles = Self.normalized(toolchainProfiles)
  }

  public var hasExactProjectScope: Bool {
    revisionScope.isUsable && !deviceProfiles.isEmpty && !toolchainProfiles.isEmpty
  }

  private static func normalized(_ values: [String]) -> [String] {
    Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })).sorted()
  }
}

public enum HarnessMemoryInvalidationKind: String, CaseIterable, Codable, Sendable {
  case revisionLeavesScope = "REVISION_LEAVES_SCOPE"
  case deviceProfileLeavesScope = "DEVICE_PROFILE_LEAVES_SCOPE"
  case toolchainProfileLeavesScope = "TOOLCHAIN_PROFILE_LEAVES_SCOPE"
  case evidenceUnavailable = "EVIDENCE_UNAVAILABLE"
  case manualRevocation = "MANUAL_REVOCATION"
}

public struct HarnessMemoryInvalidationCondition: Equatable, Sendable, Codable {
  public let kind: HarnessMemoryInvalidationKind
  public let expectedValues: [String]

  public init(kind: HarnessMemoryInvalidationKind, expectedValues: [String] = []) {
    self.kind = kind
    self.expectedValues = Array(Set(expectedValues.filter { !$0.isEmpty })).sorted()
  }
}

public struct HarnessMemoryEvidence: Equatable, Sendable, Codable {
  public let jobIDs: [String]
  /// Durable dispatch-intent request identities. A refused admission produces
  /// no job and no artifact, but the intent record is real evidence - and
  /// without this field such a memory would be unwritable, which is how the
  /// first version silently lost every rejection it observed.
  public let requestIDs: [String]
  /// Closed HumanAction identities used for an explicit promotion,
  /// supersession or invalidation. A resolution string is not evidence.
  public let humanActionIDs: [String]
  public let artifactIDs: [String]
  public let evaluationID: String?
  public let workspaceRevision: String?

  enum CodingKeys: String, CodingKey {
    case jobIDs = "jobIds"
    case requestIDs = "requestIds"
    case humanActionIDs = "humanActionIds"
    case artifactIDs = "artifactIds"
    case evaluationID = "evaluationId"
    case workspaceRevision
  }

  public init(
    jobIDs: [String] = [],
    requestIDs: [String] = [],
    humanActionIDs: [String] = [],
    artifactIDs: [String] = [],
    evaluationID: String? = nil,
    workspaceRevision: String? = nil
  ) {
    self.jobIDs = jobIDs
    self.requestIDs = requestIDs
    self.humanActionIDs = humanActionIDs
    self.artifactIDs = artifactIDs
    self.evaluationID = evaluationID
    self.workspaceRevision = workspaceRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.jobIDs = try container.decodeIfPresent([String].self, forKey: .jobIDs) ?? []
    self.requestIDs = try container.decodeIfPresent([String].self, forKey: .requestIDs) ?? []
    self.humanActionIDs =
      try container.decodeIfPresent([String].self, forKey: .humanActionIDs) ?? []
    self.artifactIDs = try container.decodeIfPresent([String].self, forKey: .artifactIDs) ?? []
    self.evaluationID = try container.decodeIfPresent(String.self, forKey: .evaluationID)
    self.workspaceRevision = try container.decodeIfPresent(
      String.self, forKey: .workspaceRevision)
  }

  public var isEmpty: Bool {
    jobIDs.isEmpty && requestIDs.isEmpty && humanActionIDs.isEmpty && artifactIDs.isEmpty
      && evaluationID == nil
      && workspaceRevision == nil
  }

  public func merging(_ other: HarnessMemoryEvidence) -> HarnessMemoryEvidence {
    HarnessMemoryEvidence(
      jobIDs: Self.unique(jobIDs + other.jobIDs),
      requestIDs: Self.unique(requestIDs + other.requestIDs),
      humanActionIDs: Self.unique(humanActionIDs + other.humanActionIDs),
      artifactIDs: Self.unique(artifactIDs + other.artifactIDs),
      evaluationID: other.evaluationID ?? evaluationID,
      workspaceRevision: other.workspaceRevision ?? workspaceRevision)
  }

  private static func unique(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
  }
}

public enum HarnessMemoryError: Error, Equatable, Sendable {
  case evidenceRequired(HarnessMemoryScope)
  case promotionRequiresVerifiedConfidence(HarnessMemoryConfidence)
  case projectScopeRequiresProjectRef
  case verificationRequired
  case verificationEvidenceMismatch
  case verifiedMemoryRequiresExactScope
  case invalidationConditionRequired
  case lifecycleTransitionNotAllowed(from: HarnessMemoryLifecycle, to: HarnessMemoryLifecycle)
}

public struct HarnessMemoryEntry: Equatable, Sendable, Codable {
  public static let documentType = "harness-memory-entry"
  public static let schemaVersion = "2.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let memoryID: String
  public let scope: HarnessMemoryScope
  public let kind: HarnessMemoryKind
  public let lifecycle: HarnessMemoryLifecycle
  public let htaskID: String
  public let projectRef: String?
  public let round: Int?
  public let summary: String
  public let confidence: HarnessMemoryConfidence
  public let evidence: HarnessMemoryEvidence
  public let applicability: HarnessMemoryApplicability
  public let invalidationConditions: [HarnessMemoryInvalidationCondition]
  public let verification: HarnessMemoryVerification?
  public let supersededByMemoryID: String?
  public let invalidationReason: String?
  public let createdAtUTC: String
  public let updatedAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case memoryID = "memoryId"
    case scope
    case kind
    case lifecycle
    case htaskID = "htaskId"
    case projectRef
    case round
    case summary
    case confidence
    case evidence
    case applicability
    case invalidationConditions
    case verification
    case supersededByMemoryID = "supersededByMemoryId"
    case invalidationReason
    case createdAtUTC = "createdAtUtc"
    case updatedAtUTC = "updatedAtUtc"
  }

  public init(
    memoryID: String,
    scope: HarnessMemoryScope,
    kind: HarnessMemoryKind,
    htaskID: String,
    projectRef: String?,
    round: Int?,
    summary: String,
    confidence: HarnessMemoryConfidence,
    evidence: HarnessMemoryEvidence,
    lifecycle: HarnessMemoryLifecycle = .candidate,
    applicability: HarnessMemoryApplicability = .init(),
    invalidationConditions: [HarnessMemoryInvalidationCondition] = [],
    verification: HarnessMemoryVerification? = nil,
    supersededByMemoryID: String? = nil,
    invalidationReason: String? = nil,
    createdAtUTC: String,
    updatedAtUTC: String? = nil
  ) throws {
    // Every memory carries its receipt. A fact with no job, artifact,
    // evaluation or human-action identity behind it is a claim, and claims
    // do not get stored.
    guard !evidence.isEmpty else { throw HarnessMemoryError.evidenceRequired(scope) }
    if scope == .project {
      guard projectRef != nil else { throw HarnessMemoryError.projectScopeRequiresProjectRef }
      guard confidence != .observed else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
      guard lifecycle != .candidate else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
    }
    if lifecycle == .verified {
      guard confidence != .observed else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
      guard let verification else { throw HarnessMemoryError.verificationRequired }
      guard Self.verificationMatches(verification, evidence: evidence) else {
        throw HarnessMemoryError.verificationEvidenceMismatch
      }
      guard applicability.hasExactProjectScope else {
        throw HarnessMemoryError.verifiedMemoryRequiresExactScope
      }
      guard !invalidationConditions.isEmpty else {
        throw HarnessMemoryError.invalidationConditionRequired
      }
    }
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.memoryID = memoryID
    self.scope = scope
    self.kind = kind
    self.lifecycle = lifecycle
    self.htaskID = htaskID
    self.projectRef = projectRef
    self.round = round
    self.summary = summary
    self.confidence = confidence
    self.evidence = evidence
    self.applicability = applicability
    self.invalidationConditions = invalidationConditions
    self.verification = verification
    self.supersededByMemoryID = supersededByMemoryID
    self.invalidationReason = invalidationReason
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC = updatedAtUTC ?? createdAtUTC
  }

  /// Records written before HFA-010 remain readable but do not silently gain
  /// VERIFIED authority. Legacy project records lacked exact applicability
  /// and invalidation conditions, so they decode fail-closed as INVALIDATED.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let scope = try container.decode(HarnessMemoryScope.self, forKey: .scope)
    let createdAtUTC = try container.decode(String.self, forKey: .createdAtUTC)
    let storedLifecycle = try container.decodeIfPresent(
      HarnessMemoryLifecycle.self, forKey: .lifecycle)
    let isLegacy = storedLifecycle == nil
    self.documentType =
      try container.decodeIfPresent(String.self, forKey: .documentType) ?? Self.documentType
    self.schemaVersion =
      try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.0.0"
    self.memoryID = try container.decode(String.self, forKey: .memoryID)
    self.scope = scope
    self.kind = try container.decode(HarnessMemoryKind.self, forKey: .kind)
    self.lifecycle = storedLifecycle ?? (scope == .project ? .invalidated : .candidate)
    self.htaskID = try container.decode(String.self, forKey: .htaskID)
    self.projectRef = try container.decodeIfPresent(String.self, forKey: .projectRef)
    self.round = try container.decodeIfPresent(Int.self, forKey: .round)
    self.summary = try container.decode(String.self, forKey: .summary)
    self.confidence = try container.decode(HarnessMemoryConfidence.self, forKey: .confidence)
    self.evidence = try container.decode(HarnessMemoryEvidence.self, forKey: .evidence)
    self.applicability =
      try container.decodeIfPresent(HarnessMemoryApplicability.self, forKey: .applicability)
      ?? HarnessMemoryApplicability()
    self.invalidationConditions =
      try container.decodeIfPresent(
        [HarnessMemoryInvalidationCondition].self, forKey: .invalidationConditions) ?? []
    self.verification = try container.decodeIfPresent(
      HarnessMemoryVerification.self, forKey: .verification)
    self.supersededByMemoryID = try container.decodeIfPresent(
      String.self, forKey: .supersededByMemoryID)
    self.invalidationReason =
      try container.decodeIfPresent(String.self, forKey: .invalidationReason)
      ?? (isLegacy && scope == .project ? "legacyMemoryMissingExactScope" : nil)
    self.createdAtUTC = createdAtUTC
    self.updatedAtUTC =
      try container.decodeIfPresent(String.self, forKey: .updatedAtUTC) ?? createdAtUTC

    // Codable is also a trust boundary: a hand-written or partially corrupt
    // JSONL row must not acquire VERIFIED authority merely because it names
    // that lifecycle. Apply the same invariants as the public initializer.
    guard !evidence.isEmpty else { throw HarnessMemoryError.evidenceRequired(scope) }
    if scope == .project {
      guard projectRef != nil else { throw HarnessMemoryError.projectScopeRequiresProjectRef }
      guard confidence != .observed else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
      guard lifecycle != .candidate else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
    }
    if lifecycle == .verified {
      guard confidence != .observed else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
      guard let verification else { throw HarnessMemoryError.verificationRequired }
      guard Self.verificationMatches(verification, evidence: evidence) else {
        throw HarnessMemoryError.verificationEvidenceMismatch
      }
      guard applicability.hasExactProjectScope else {
        throw HarnessMemoryError.verifiedMemoryRequiresExactScope
      }
      guard !invalidationConditions.isEmpty else {
        throw HarnessMemoryError.invalidationConditionRequired
      }
    }
  }

  public var contentDigest: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = (try? encoder.encode(self)) ?? Data("{}".utf8)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  public func promoting(
    toProjectRef projectRef: String,
    verification: HarnessMemoryVerification,
    applicability: HarnessMemoryApplicability,
    invalidationConditions: [HarnessMemoryInvalidationCondition],
    additionalEvidence: HarnessMemoryEvidence,
    atUTC: String
  ) throws -> HarnessMemoryEntry {
    guard lifecycle == .candidate else {
      throw HarnessMemoryError.lifecycleTransitionNotAllowed(
        from: lifecycle, to: .verified)
    }
    let confidence: HarnessMemoryConfidence =
      verification.source == .evaluatorPass ? .evaluated : .humanConfirmed
    return try HarnessMemoryEntry(
      memoryID: memoryID, scope: .project, kind: .verifiedKnowledge,
      htaskID: htaskID, projectRef: projectRef, round: round,
      summary: summary, confidence: confidence,
      evidence: evidence.merging(additionalEvidence), lifecycle: .verified,
      applicability: applicability, invalidationConditions: invalidationConditions,
      verification: verification, createdAtUTC: createdAtUTC, updatedAtUTC: atUTC)
  }

  public func superseding(
    by memoryID: String,
    evidence additionalEvidence: HarnessMemoryEvidence,
    atUTC: String
  ) throws -> HarnessMemoryEntry {
    guard lifecycle == .verified || lifecycle == .candidate else {
      throw HarnessMemoryError.lifecycleTransitionNotAllowed(
        from: lifecycle, to: .superseded)
    }
    return try HarnessMemoryEntry(
      memoryID: self.memoryID, scope: scope, kind: kind, htaskID: htaskID,
      projectRef: projectRef, round: round, summary: summary, confidence: confidence,
      evidence: evidence.merging(additionalEvidence), lifecycle: .superseded,
      applicability: applicability, invalidationConditions: invalidationConditions,
      verification: verification, supersededByMemoryID: memoryID,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC)
  }

  public func invalidating(
    reason: String,
    evidence additionalEvidence: HarnessMemoryEvidence,
    atUTC: String
  ) throws -> HarnessMemoryEntry {
    guard lifecycle == .verified || lifecycle == .candidate else {
      throw HarnessMemoryError.lifecycleTransitionNotAllowed(
        from: lifecycle, to: .invalidated)
    }
    return try HarnessMemoryEntry(
      memoryID: memoryID, scope: scope, kind: kind, htaskID: htaskID,
      projectRef: projectRef, round: round, summary: summary, confidence: confidence,
      evidence: evidence.merging(additionalEvidence), lifecycle: .invalidated,
      applicability: applicability, invalidationConditions: invalidationConditions,
      verification: verification, invalidationReason: reason,
      createdAtUTC: createdAtUTC, updatedAtUTC: atUTC)
  }

  private static func verificationMatches(
    _ verification: HarnessMemoryVerification,
    evidence: HarnessMemoryEvidence
  ) -> Bool {
    guard !verification.evidenceID.isEmpty else { return false }
    switch verification.source {
    case .evaluatorPass:
      return evidence.evaluationID == verification.evidenceID
    case .humanConfirmation:
      return evidence.humanActionIDs.contains(verification.evidenceID)
    }
  }
}

public struct HarnessMemoryQuery: Equatable, Sendable, Codable {
  public let htaskID: String
  public let projectRef: String?
  public let failureFingerprints: [String]
  public let components: [String]
  public let filePaths: [String]
  public let symbols: [String]
  public let operationReferences: [String]
  public let revision: String?
  public let deviceProfiles: [String]
  public let toolchainProfiles: [String]

  public init(
    htaskID: String,
    projectRef: String?,
    failureFingerprints: [String] = [],
    components: [String] = [],
    filePaths: [String] = [],
    symbols: [String] = [],
    operationReferences: [String] = [],
    revision: String? = nil,
    deviceProfiles: [String] = [],
    toolchainProfiles: [String] = []
  ) {
    self.htaskID = htaskID
    self.projectRef = projectRef
    self.failureFingerprints = Self.normalized(failureFingerprints)
    self.components = Self.normalized(components)
    self.filePaths = Self.normalized(filePaths)
    self.symbols = Self.normalized(symbols)
    self.operationReferences = Self.normalized(operationReferences)
    let trimmed = revision?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.revision = trimmed?.isEmpty == false ? trimmed : nil
    self.deviceProfiles = Self.normalized(deviceProfiles)
    self.toolchainProfiles = Self.normalized(toolchainProfiles)
  }

  public var digest: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = (try? encoder.encode(self)) ?? Data("{}".utf8)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func normalized(_ values: [String]) -> [String] {
    Array(Set(values.filter { !$0.isEmpty })).sorted()
  }
}

public enum HarnessMemorySelectionReason: String, CaseIterable, Codable, Sendable {
  case taskCandidate = "TASK_CANDIDATE"
  case taskVerified = "TASK_VERIFIED"
  case exactProjectScope = "EXACT_PROJECT_SCOPE"
}

public struct HarnessMemorySelectionRecord: Equatable, Sendable, Codable {
  public let memoryID: String
  public let lifecycle: HarnessMemoryLifecycle
  public let contentDigest: String
  public let score: Int
  public let reason: HarnessMemorySelectionReason

  enum CodingKeys: String, CodingKey {
    case memoryID = "memoryId"
    case lifecycle
    case contentDigest
    case score
    case reason
  }
}

public struct HarnessMemorySelectionManifest: Equatable, Sendable, Codable {
  public static let currentTaskEvidenceScore = 1_000

  public let queryDigest: String
  public let currentEvidenceScore: Int
  public let selected: [HarnessMemorySelectionRecord]
  public let excludedLifecycleCount: Int
  public let excludedScopeCount: Int
  public let trimmedCount: Int

  public init(
    queryDigest: String,
    selected: [HarnessMemorySelectionRecord],
    excludedLifecycleCount: Int,
    excludedScopeCount: Int,
    trimmedCount: Int
  ) {
    self.queryDigest = queryDigest
    self.currentEvidenceScore = Self.currentTaskEvidenceScore
    self.selected = selected
    self.excludedLifecycleCount = excludedLifecycleCount
    self.excludedScopeCount = excludedScopeCount
    self.trimmedCount = trimmedCount
  }

  public static let empty = HarnessMemorySelectionManifest(
    queryDigest: "", selected: [], excludedLifecycleCount: 0,
    excludedScopeCount: 0, trimmedCount: 0)
}

public struct HarnessMemorySelection: Equatable, Sendable {
  public let entries: [HarnessMemoryEntry]
  public let manifest: HarnessMemorySelectionManifest
}

public enum HarnessMemorySelector {
  /// Exact filtering is completed before any score is assigned. A high score
  /// can therefore never compensate for a revision or profile mismatch.
  public static func select(
    _ history: [HarnessMemoryEntry],
    matching query: HarnessMemoryQuery,
    limit: Int
  ) -> HarnessMemorySelection {
    let current = collapse(history)
    var lifecycleExcluded = 0
    var scopeExcluded = 0
    var ranked: [(HarnessMemoryEntry, HarnessMemorySelectionRecord)] = []

    for entry in current {
      guard entry.lifecycle == .candidate || entry.lifecycle == .verified else {
        lifecycleExcluded += 1
        continue
      }
      let match = exactMatch(entry, query: query)
      guard match.matches else {
        scopeExcluded += 1
        continue
      }
      let base = entry.lifecycle == .verified ? 600 : 100
      // Seven exact dimensions, ten points each. A CANDIDATE therefore
      // remains below both VERIFIED memory and current task evidence.
      let score = base + min(70, match.matchedDimensions * 10)
      let reason: HarnessMemorySelectionReason
      if entry.scope == .task {
        reason = entry.lifecycle == .verified ? .taskVerified : .taskCandidate
      } else {
        reason = .exactProjectScope
      }
      ranked.append(
        (entry, HarnessMemorySelectionRecord(
          memoryID: entry.memoryID, lifecycle: entry.lifecycle,
          contentDigest: entry.contentDigest, score: score, reason: reason)))
    }

    ranked.sort {
      if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
      if $0.0.updatedAtUTC != $1.0.updatedAtUTC {
        return $0.0.updatedAtUTC > $1.0.updatedAtUTC
      }
      return $0.0.memoryID < $1.0.memoryID
    }
    let boundedLimit = max(0, limit)
    let selected = Array(ranked.prefix(boundedLimit))
    return HarnessMemorySelection(
      entries: selected.map(\.0),
      manifest: HarnessMemorySelectionManifest(
        queryDigest: query.digest, selected: selected.map(\.1),
        excludedLifecycleCount: lifecycleExcluded,
        excludedScopeCount: scopeExcluded,
        trimmedCount: max(0, ranked.count - selected.count)))
  }

  /// Latest lifecycle row per identity. The append-only JSONL remains the
  /// audit history; consumers see one current fact.
  public static func collapse(_ history: [HarnessMemoryEntry]) -> [HarnessMemoryEntry] {
    var latest: [String: HarnessMemoryEntry] = [:]
    for entry in history {
      guard let existing = latest[entry.memoryID] else {
        latest[entry.memoryID] = entry
        continue
      }
      if entry.updatedAtUTC > existing.updatedAtUTC
        || (entry.updatedAtUTC == existing.updatedAtUTC
          && lifecycleOrder(entry.lifecycle) > lifecycleOrder(existing.lifecycle))
      {
        latest[entry.memoryID] = entry
      }
    }
    return latest.values.sorted {
      if $0.updatedAtUTC != $1.updatedAtUTC { return $0.updatedAtUTC < $1.updatedAtUTC }
      return $0.memoryID < $1.memoryID
    }
  }

  private static func exactMatch(
    _ entry: HarnessMemoryEntry,
    query: HarnessMemoryQuery
  ) -> (matches: Bool, matchedDimensions: Int) {
    if entry.scope == .task {
      return (entry.htaskID == query.htaskID, entry.htaskID == query.htaskID ? 1 : 0)
    }
    guard entry.projectRef == query.projectRef,
      entry.lifecycle == .verified,
      entry.applicability.hasExactProjectScope,
      let revision = query.revision,
      entry.applicability.revisionScope.exactRevisions.contains(revision),
      !Set(entry.applicability.deviceProfiles).isDisjoint(with: query.deviceProfiles),
      !Set(entry.applicability.toolchainProfiles).isDisjoint(with: query.toolchainProfiles)
    else { return (false, 0) }

    var matched = 3  // revision + device profile + toolchain profile
    if let component = entry.applicability.component {
      guard query.components.contains(component) else { return (false, 0) }
      matched += 1
    }
    for pair in [
      (entry.applicability.failureFingerprints, query.failureFingerprints),
      (entry.applicability.filePaths, query.filePaths),
      (entry.applicability.symbols, query.symbols),
      (entry.applicability.operationReferences, query.operationReferences),
    ] where !pair.0.isEmpty {
      guard !Set(pair.0).isDisjoint(with: pair.1) else { return (false, 0) }
      matched += 1
    }
    return (true, matched)
  }

  private static func lifecycleOrder(_ lifecycle: HarnessMemoryLifecycle) -> Int {
    switch lifecycle {
    case .candidate: return 0
    case .verified: return 1
    case .superseded: return 2
    case .invalidated: return 3
    }
  }
}
