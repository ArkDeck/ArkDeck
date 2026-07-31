// Three-layer memory model (CHG-2026-054, TASK-HTP-003).
//
// Memory here is a typed fact with evidence attached, not a chat log. The
// promotion rule is the point: task memory records what a round observed,
// and only a fact the evaluator passed on verified evidence - or one a human
// confirmed - may be written to project memory. An unverified guess never
// becomes long-lived knowledge (CHG-2026-054 HTP-INV-1/HTP-INV-2).

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

public struct HarnessMemoryEvidence: Equatable, Sendable, Codable {
  public let jobIDs: [String]
  /// Durable dispatch-intent request identities. A refused admission produces
  /// no job and no artifact, but the intent record is real evidence - and
  /// without this field such a memory would be unwritable, which is how the
  /// first version silently lost every rejection it observed.
  public let requestIDs: [String]
  public let artifactIDs: [String]
  public let evaluationID: String?
  public let workspaceRevision: String?

  enum CodingKeys: String, CodingKey {
    case jobIDs = "jobIds"
    case requestIDs = "requestIds"
    case artifactIDs = "artifactIds"
    case evaluationID = "evaluationId"
    case workspaceRevision
  }

  public init(
    jobIDs: [String] = [],
    requestIDs: [String] = [],
    artifactIDs: [String] = [],
    evaluationID: String? = nil,
    workspaceRevision: String? = nil
  ) {
    self.jobIDs = jobIDs
    self.requestIDs = requestIDs
    self.artifactIDs = artifactIDs
    self.evaluationID = evaluationID
    self.workspaceRevision = workspaceRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.jobIDs = try container.decodeIfPresent([String].self, forKey: .jobIDs) ?? []
    self.requestIDs = try container.decodeIfPresent([String].self, forKey: .requestIDs) ?? []
    self.artifactIDs = try container.decodeIfPresent([String].self, forKey: .artifactIDs) ?? []
    self.evaluationID = try container.decodeIfPresent(String.self, forKey: .evaluationID)
    self.workspaceRevision = try container.decodeIfPresent(
      String.self, forKey: .workspaceRevision)
  }

  public var isEmpty: Bool {
    jobIDs.isEmpty && requestIDs.isEmpty && artifactIDs.isEmpty && evaluationID == nil
      && workspaceRevision == nil
  }
}

public enum HarnessMemoryError: Error, Equatable, Sendable {
  case evidenceRequired(HarnessMemoryScope)
  case promotionRequiresVerifiedConfidence(HarnessMemoryConfidence)
  case projectScopeRequiresProjectRef
}

public struct HarnessMemoryEntry: Equatable, Sendable, Codable {
  public static let documentType = "harness-memory-entry"

  public let documentType: String
  public let memoryID: String
  public let scope: HarnessMemoryScope
  public let kind: HarnessMemoryKind
  public let htaskID: String
  public let projectRef: String?
  public let round: Int?
  public let summary: String
  public let confidence: HarnessMemoryConfidence
  public let evidence: HarnessMemoryEvidence
  public let createdAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case memoryID = "memoryId"
    case scope
    case kind
    case htaskID = "htaskId"
    case projectRef
    case round
    case summary
    case confidence
    case evidence
    case createdAtUTC = "createdAtUtc"
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
    createdAtUTC: String
  ) throws {
    // Every memory carries its receipt. A fact with no job, artifact or
    // evaluation behind it is a claim, and claims do not get stored.
    guard !evidence.isEmpty else { throw HarnessMemoryError.evidenceRequired(scope) }
    if scope == .project {
      guard projectRef != nil else { throw HarnessMemoryError.projectScopeRequiresProjectRef }
      guard confidence != .observed else {
        throw HarnessMemoryError.promotionRequiresVerifiedConfidence(confidence)
      }
    }
    self.documentType = Self.documentType
    self.memoryID = memoryID
    self.scope = scope
    self.kind = kind
    self.htaskID = htaskID
    self.projectRef = projectRef
    self.round = round
    self.summary = summary
    self.confidence = confidence
    self.evidence = evidence
    self.createdAtUTC = createdAtUTC
  }
}
