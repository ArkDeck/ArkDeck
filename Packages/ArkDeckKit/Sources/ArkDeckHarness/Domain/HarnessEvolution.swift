// Bounded Evolution domain model.
//
// Evolution is the automatic workspace-backed task path, not another runtime. It reuses the
// existing Harness -> RuntimeJobEngine -> Catalog -> Provider path and adds
// only the isolation, review and promotion facts that a device-only task does not
// need. None of the types in this file can execute a command, push a branch
// or merge code.

import ArkDeckCore
import CryptoKit
import Foundation

public enum HarnessEvolutionPolicyError: Error, Equatable, Sendable {
  case invalidBaseRevision
  case emptyAllowedPaths
  case unsafeAllowedPath(String)
  case invalidBudget(String)
  case emptyAllowedOperations
  case unknownOperation(String)
  case destructiveOperationNotAllowed(String)
  case operationOutsideTaskPolicy(String)
  case invalidCandidate(String)
  case candidateBaseRevisionMismatch
  case tooManyChangedFiles(actual: Int, limit: Int)
  case diffLineBudgetExceeded(actual: Int, limit: Int)
  case pathOutsideScope(String)
}

/// The exploration envelope.  It narrows an existing task policy; it is not
/// a RuntimeCapability and can never authorize an E1/E2 effect by itself.
public struct HarnessEvolutionPolicy: Equatable, Codable, Sendable {
  public let baseRevision: String
  public let allowedPaths: [String]
  public let maxAttempts: Int
  public let maxChangedFiles: Int
  public let maxDiffLines: Int
  public let allowedOperations: [String]

  private enum CodingKeys: String, CodingKey {
    case baseRevision
    case allowedPaths
    case maxAttempts
    case maxChangedFiles
    case maxDiffLines
    case allowedOperations
  }

  public init(
    baseRevision: String,
    allowedPaths: [String],
    maxAttempts: Int = 20,
    maxChangedFiles: Int = 20,
    maxDiffLines: Int = 2_000,
    allowedOperations: [String]
  ) throws {
    guard Self.isSHA256(baseRevision) else {
      throw HarnessEvolutionPolicyError.invalidBaseRevision
    }
    let normalizedPaths = Array(Set(allowedPaths)).sorted()
    guard !normalizedPaths.isEmpty else {
      throw HarnessEvolutionPolicyError.emptyAllowedPaths
    }
    for path in normalizedPaths where !Self.isSafeScope(path) {
      throw HarnessEvolutionPolicyError.unsafeAllowedPath(path)
    }
    guard (1...64).contains(maxAttempts) else {
      throw HarnessEvolutionPolicyError.invalidBudget("maxAttempts")
    }
    guard (1...64).contains(maxChangedFiles) else {
      throw HarnessEvolutionPolicyError.invalidBudget("maxChangedFiles")
    }
    guard (1...100_000).contains(maxDiffLines) else {
      throw HarnessEvolutionPolicyError.invalidBudget("maxDiffLines")
    }
    let normalizedOperations = Array(Set(allowedOperations)).sorted()
    guard !normalizedOperations.isEmpty else {
      throw HarnessEvolutionPolicyError.emptyAllowedOperations
    }
    for operation in normalizedOperations {
      guard let descriptor = RuntimeOperationCatalog.descriptor(reference: operation) else {
        throw HarnessEvolutionPolicyError.unknownOperation(operation)
      }
      guard descriptor.minimumEffect != .destructive,
        !descriptor.permittedEffects.contains(.destructive)
      else {
        throw HarnessEvolutionPolicyError.destructiveOperationNotAllowed(operation)
      }
    }
    self.baseRevision = baseRevision
    self.allowedPaths = normalizedPaths
    self.maxAttempts = maxAttempts
    self.maxChangedFiles = maxChangedFiles
    self.maxDiffLines = maxDiffLines
    self.allowedOperations = normalizedOperations
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      baseRevision: container.decode(String.self, forKey: .baseRevision),
      allowedPaths: container.decode([String].self, forKey: .allowedPaths),
      maxAttempts: container.decode(Int.self, forKey: .maxAttempts),
      maxChangedFiles: container.decode(Int.self, forKey: .maxChangedFiles),
      maxDiffLines: container.decode(Int.self, forKey: .maxDiffLines),
      allowedOperations: container.decode([String].self, forKey: .allowedOperations))
  }

  public func validate(taskPolicy: HarnessTaskPolicy) throws {
    let taskOperations = Set(taskPolicy.allowedOperations)
    for operation in allowedOperations where !taskOperations.contains(operation) {
      throw HarnessEvolutionPolicyError.operationOutsideTaskPolicy(operation)
    }
  }

  public func validate(candidate: HarnessCandidatePatch) throws {
    guard !candidate.files.isEmpty else {
      throw HarnessEvolutionPolicyError.invalidCandidate("files")
    }
    guard candidate.changedLines >= 0 else {
      throw HarnessEvolutionPolicyError.invalidCandidate("changedLines")
    }
    guard Self.isSHA256(candidate.diffDigest) else {
      throw HarnessEvolutionPolicyError.invalidCandidate("diffDigest")
    }
    guard Self.isArtifactIdentifier(candidate.diffArtifactID) else {
      throw HarnessEvolutionPolicyError.invalidCandidate("diffArtifactId")
    }
    guard candidate.baseRevision == baseRevision else {
      throw HarnessEvolutionPolicyError.candidateBaseRevisionMismatch
    }
    guard candidate.files.count <= maxChangedFiles else {
      throw HarnessEvolutionPolicyError.tooManyChangedFiles(
        actual: candidate.files.count, limit: maxChangedFiles)
    }
    guard candidate.changedLines <= maxDiffLines else {
      throw HarnessEvolutionPolicyError.diffLineBudgetExceeded(
        actual: candidate.changedLines, limit: maxDiffLines)
    }
    for file in candidate.files where !allowedPaths.contains(where: { Self.matches(file, $0) }) {
      throw HarnessEvolutionPolicyError.pathOutsideScope(file)
    }
  }

  /// Closed, intentionally small glob matcher: `*` stays within a component
  /// and `**` may cross `/`.  Requests cannot use character classes or path
  /// traversal, so policy matching does not accidentally acquire filesystem
  /// semantics from Foundation or the host shell.
  public static func matches(_ path: String, _ pattern: String) -> Bool {
    guard isSafeRelativePath(path), isSafeScope(pattern) else { return false }
    var expression = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      if character == "*" {
        let next = pattern.index(after: index)
        if next < pattern.endIndex, pattern[next] == "*" {
          expression += ".*"
          index = pattern.index(after: next)
        } else {
          expression += "[^/]*"
          index = next
        }
        continue
      }
      if character == "?" {
        expression += "[^/]"
      } else {
        expression += NSRegularExpression.escapedPattern(for: String(character))
      }
      index = pattern.index(after: index)
    }
    expression += "$"
    return path.range(of: expression, options: .regularExpression) != nil
  }

  private static func isSafeScope(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("/"),
      !value.contains("\\"), !value.contains("[") && !value.contains("]"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return false }
    let literal = value.replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "*", with: "")
      .replacingOccurrences(of: "?", with: "")
    let components = literal.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains(where: { $0 == "." || $0 == ".." })
      && value != ".git" && !value.hasPrefix(".git/") && !value.contains("/.git/")
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
      !value.contains(where: { "*?[]".contains($0) })
    else { return false }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      && value != ".git" && !value.hasPrefix(".git/") && !value.contains("/.git/")
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }

  private static func isArtifactIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:@-".contains($0))
      }
  }
}

/// Opaque reference to a provider-owned isolated tree.  The host path never
/// enters task JSON or model context.
public struct HarnessEvolutionWorkspace: Equatable, Codable, Sendable {
  public let workspaceID: String
  public let htaskID: String
  public let sourceProjectRef: String
  public let projectRef: String
  public let baseRevision: String
  public let allowedPathsDigest: String
  public let createdAtUTC: String

  public init(
    workspaceID: String,
    htaskID: String,
    sourceProjectRef: String,
    projectRef: String,
    baseRevision: String,
    allowedPathsDigest: String,
    createdAtUTC: String
  ) {
    self.workspaceID = workspaceID
    self.htaskID = htaskID
    self.sourceProjectRef = sourceProjectRef
    self.projectRef = projectRef
    self.baseRevision = baseRevision
    self.allowedPathsDigest = allowedPathsDigest
    self.createdAtUTC = createdAtUTC
  }
}

public protocol HarnessEvolutionWorkspacePort: Sendable {
  /// Creates or idempotently reopens the task-owned isolated tree and returns
  /// only its opaque provider reference.  It must never return a host path.
  func prepareWorkspace(
    htaskID: String,
    sourceProjectRef: String,
    policy: HarnessEvolutionPolicy,
    createdAtUTC: String
  ) async throws -> HarnessEvolutionWorkspace

  /// Records a strategy directory under the already isolated task tree.
  /// Runtime operations continue to target the stable task workspace so one
  /// capability subject cannot silently become another between attempts.
  func prepareAttemptDirectory(
    workspace: HarnessEvolutionWorkspace,
    attemptID: String,
    ordinal: Int,
    createdAtUTC: String
  ) async throws
}

public enum HarnessCandidatePatchCreator: String, Codable, Sendable {
  case agent
  case human
}

/// Metadata Artifact for the immutable diff Artifact used by applyPatch.
public struct HarnessCandidatePatch: Equatable, Codable, Sendable {
  public static let documentType = "harness-candidate-patch"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let candidatePatchID: String
  public let htaskID: String
  public let attemptID: String
  public let baseRevision: String
  public let files: [String]
  public let diffDigest: String
  public let changedLines: Int
  public let createdBy: HarnessCandidatePatchCreator
  public let diffArtifactID: String
  public let metadataArtifactID: String?
  public let createdAtUTC: String

  public init(
    candidatePatchID: String,
    htaskID: String,
    attemptID: String,
    baseRevision: String,
    files: [String],
    diffDigest: String,
    changedLines: Int,
    createdBy: HarnessCandidatePatchCreator,
    diffArtifactID: String,
    metadataArtifactID: String? = nil,
    createdAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.candidatePatchID = candidatePatchID
    self.htaskID = htaskID
    self.attemptID = attemptID
    self.baseRevision = baseRevision
    self.files = Array(Set(files)).sorted()
    self.diffDigest = diffDigest
    self.changedLines = changedLines
    self.createdBy = createdBy
    self.diffArtifactID = diffArtifactID
    self.metadataArtifactID = metadataArtifactID
    self.createdAtUTC = createdAtUTC
  }

  public static func create(
    proposal: HarnessPatchProposal,
    diffArtifactID: String,
    htaskID: String,
    attemptID: String,
    createdBy: HarnessCandidatePatchCreator,
    createdAtUTC: String
  ) -> HarnessCandidatePatch {
    let changedLines = proposal.unifiedDiff.split(
      separator: "\n", omittingEmptySubsequences: false
    ).reduce(into: 0) { count, line in
      if (line.hasPrefix("+") && !line.hasPrefix("+++"))
        || (line.hasPrefix("-") && !line.hasPrefix("---"))
      {
        count += 1
      }
    }
    let seed = Data("\(htaskID)|\(attemptID)|\(proposal.patchSHA256)".utf8)
    let digest = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
    return HarnessCandidatePatch(
      candidatePatchID: "candidate-\(digest.prefix(24))",
      htaskID: htaskID,
      attemptID: attemptID,
      baseRevision: proposal.baseWorkspaceRevision,
      files: proposal.touchedFiles,
      diffDigest: proposal.patchSHA256,
      changedLines: changedLines,
      createdBy: createdBy,
      diffArtifactID: diffArtifactID,
      createdAtUTC: createdAtUTC)
  }

  public func recordingMetadataArtifact(_ artifactID: String) -> HarnessCandidatePatch {
    HarnessCandidatePatch(
      candidatePatchID: candidatePatchID, htaskID: htaskID, attemptID: attemptID,
      baseRevision: baseRevision, files: files, diffDigest: diffDigest,
      changedLines: changedLines, createdBy: createdBy,
      diffArtifactID: diffArtifactID, metadataArtifactID: artifactID,
      createdAtUTC: createdAtUTC)
  }

  /// True exactly when `text` is the immutable diff this metadata names.
  public func namesDiff(_ text: String) -> Bool {
    SHA256.hash(data: Data(text.utf8))
      .map { String(format: "%02x", $0) }.joined() == diffDigest
  }
}

public enum HarnessAdversarialReviewVerdict: String, CaseIterable, Codable, Sendable {
  case pass = "PASS"
  case reject = "REJECT"
  case comment = "COMMENT"
}

public enum HarnessReviewIssueSeverity: String, CaseIterable, Codable, Sendable {
  case low = "LOW"
  case medium = "MEDIUM"
  case high = "HIGH"
  case critical = "CRITICAL"
}

public struct HarnessReviewIssue: Equatable, Codable, Sendable {
  public let severity: HarnessReviewIssueSeverity
  public let description: String

  public init(severity: HarnessReviewIssueSeverity, description: String) {
    self.severity = severity
    self.description = description
  }
}

/// The reviewer receives evidence and metadata only: the immutable unified
/// diff (the bytes the candidate metadata's `diffDigest` names), the attempt
/// history and the evaluation.  There is deliberately no patch *proposal*
/// envelope and no operation output in this protocol, and the reviewer holds
/// no operation or patch-writing port, so review cannot mutate the candidate
/// under review.
public struct HarnessAdversarialReviewRequest: Equatable, Codable, Sendable {
  public let originalProblem: String
  public let candidatePatch: HarnessCandidatePatch
  /// The exact reviewed bytes.  The coordinator verifies this text hashes to
  /// `candidatePatch.diffDigest` before review, so a reviewer verdict always
  /// names the diff it actually read.
  public let unifiedDiff: String
  public let attemptHistory: [HarnessAttempt]
  public let evaluation: HarnessEvaluation
  public let artifactIDs: [String]

  public init(
    originalProblem: String,
    candidatePatch: HarnessCandidatePatch,
    unifiedDiff: String,
    attemptHistory: [HarnessAttempt],
    evaluation: HarnessEvaluation,
    artifactIDs: [String]
  ) {
    self.originalProblem = originalProblem
    self.candidatePatch = candidatePatch
    self.unifiedDiff = unifiedDiff
    self.attemptHistory = attemptHistory
    self.evaluation = evaluation
    self.artifactIDs = Array(Set(artifactIDs)).sorted()
  }
}

public struct HarnessAdversarialReview: Equatable, Codable, Sendable {
  public static let documentType = "harness-adversarial-review"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let reviewID: String
  public let reviewerID: String
  public let candidatePatchID: String
  public let evaluationID: String
  public let result: HarnessAdversarialReviewVerdict
  public let issues: [HarnessReviewIssue]
  public let createdAtUTC: String

  public init(
    reviewID: String,
    reviewerID: String,
    candidatePatchID: String,
    evaluationID: String,
    result: HarnessAdversarialReviewVerdict,
    issues: [HarnessReviewIssue],
    createdAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.reviewID = reviewID
    self.reviewerID = reviewerID
    self.candidatePatchID = candidatePatchID
    self.evaluationID = evaluationID
    self.result = result
    self.issues = issues
    self.createdAtUTC = createdAtUTC
  }
}

public protocol HarnessAdversarialReviewing: Sendable {
  var reviewerID: String { get }
  func review(_ request: HarnessAdversarialReviewRequest) async throws
    -> HarnessAdversarialReview
}

public enum HarnessPromotionGateFailure: Error, Equatable, Sendable {
  case evolutionPolicyMissing
  case candidatePatchMissing
  case candidateArtifactMissing
  case buildNotPassed
  case buildArtifactMissing
  case testsNotPassed
  case deviceVerificationNotPassed
  case deviceEvidenceMissing
  case evaluationNotPassed
  case reviewNotPassed(HarnessAdversarialReviewVerdict)
  case scopeCheckFailed(String)
  case stalePatch
}

public struct HarnessPromotionCandidate: Equatable, Codable, Sendable {
  public static let documentType = "harness-promotion-candidate"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let promotionCandidateID: String
  public let htaskID: String
  public let attemptID: String
  public let candidatePatchID: String
  public let baseRevision: String
  public let workspaceRevision: String
  public let evaluationID: String
  public let reviewID: String
  public let artifactIDs: [String]
  public let createdAtUTC: String
  /// Promotion produces a normal PR candidate. It is never a merge claim.
  public let disposition: String

  public init(
    promotionCandidateID: String,
    htaskID: String,
    attemptID: String,
    candidatePatchID: String,
    baseRevision: String,
    workspaceRevision: String,
    evaluationID: String,
    reviewID: String,
    artifactIDs: [String],
    createdAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.promotionCandidateID = promotionCandidateID
    self.htaskID = htaskID
    self.attemptID = attemptID
    self.candidatePatchID = candidatePatchID
    self.baseRevision = baseRevision
    self.workspaceRevision = workspaceRevision
    self.evaluationID = evaluationID
    self.reviewID = reviewID
    self.artifactIDs = Array(Set(artifactIDs)).sorted()
    self.createdAtUTC = createdAtUTC
    self.disposition = "READY_FOR_NORMAL_PR"
  }
}

public enum HarnessPromotionGate {
  public static func evaluate(
    snapshot: HarnessTaskSnapshot,
    attempt: HarnessAttempt,
    evaluation: HarnessEvaluation,
    review: HarnessAdversarialReview,
    promotionCandidateID: String,
    createdAtUTC: String
  ) throws -> HarnessPromotionCandidate {
    guard let policy = snapshot.evolutionPolicy else {
      throw HarnessPromotionGateFailure.evolutionPolicyMissing
    }
    guard let candidate = attempt.candidatePatch else {
      throw HarnessPromotionGateFailure.candidatePatchMissing
    }
    guard candidate.htaskID == snapshot.htaskID,
      attempt.htaskID == snapshot.htaskID,
      candidate.attemptID == attempt.attemptID,
      candidate.baseRevision == attempt.baseRevision,
      candidate.baseRevision == policy.baseRevision,
      candidate.diffDigest == attempt.strategy.patchFingerprint
    else { throw HarnessPromotionGateFailure.stalePatch }
    do {
      try policy.validate(candidate: candidate)
    } catch {
      throw HarnessPromotionGateFailure.scopeCheckFailed("\(error)")
    }
    guard candidate.metadataArtifactID != nil else {
      throw HarnessPromotionGateFailure.candidateArtifactMissing
    }
    guard let repair = snapshot.repairAttempt,
      let patchRevision = repair.patchRevision,
      repair.buildSourceRevision == patchRevision,
      repair.buildOutputDigest != nil
    else { throw HarnessPromotionGateFailure.buildNotPassed }
    guard !attempt.buildArtifactIDs.isEmpty else {
      throw HarnessPromotionGateFailure.buildArtifactMissing
    }
    guard repair.testsPassed else {
      throw HarnessPromotionGateFailure.testsNotPassed
    }
    guard let buildDigest = repair.buildOutputDigest,
      repair.deployedDigest == buildDigest
    else { throw HarnessPromotionGateFailure.deviceVerificationNotPassed }
    let verifiedEvidence = evaluation.evidence.filter(\.verified)
    guard !attempt.runtimeArtifactIDs.isEmpty, !verifiedEvidence.isEmpty,
      Set(verifiedEvidence.map(\.artifactID)).isSubset(of: Set(attempt.runtimeArtifactIDs))
    else { throw HarnessPromotionGateFailure.deviceEvidenceMissing }
    guard evaluation.verdict == .pass,
      attempt.evaluationIDs.contains(evaluation.evaluationID)
    else { throw HarnessPromotionGateFailure.evaluationNotPassed }
    guard review.candidatePatchID == candidate.candidatePatchID,
      review.evaluationID == evaluation.evaluationID,
      review.result == .pass,
      review.issues.isEmpty
    else { throw HarnessPromotionGateFailure.reviewNotPassed(review.result) }
    return HarnessPromotionCandidate(
      promotionCandidateID: promotionCandidateID,
      htaskID: snapshot.htaskID,
      attemptID: attempt.attemptID,
      candidatePatchID: candidate.candidatePatchID,
      baseRevision: candidate.baseRevision,
      workspaceRevision: patchRevision,
      evaluationID: evaluation.evaluationID,
      reviewID: review.reviewID,
      artifactIDs: snapshot.artifactRefs + attempt.buildArtifactIDs
        + attempt.runtimeArtifactIDs + [candidate.diffArtifactID]
        + [candidate.metadataArtifactID].compactMap { $0 },
      createdAtUTC: createdAtUTC)
  }
}

/// Public spelling requested by the Evolution design while retaining the
/// single strategy-attempt model already used by the Harness.
public typealias EvolutionAttempt = HarnessAttempt
