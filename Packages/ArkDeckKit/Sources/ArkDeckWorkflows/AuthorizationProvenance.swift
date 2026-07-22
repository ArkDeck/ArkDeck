import ArkDeckStorage
import CryptoKit
import Foundation

// TASK-AIN-006 (CHG-2026-025): protected-main/GitHub provenance verifier. Network and GitHub
// access are owned by the future TrustedExecutionHost composition. This module accepts one fresh
// snapshot from that internal port, verifies every relationship, and never falls back to a local
// worktree, caller ref or offline cache.

enum AuthorizationReviewState: String, Sendable, Equatable {
  case approved
  case commented
  case changesRequested
  case dismissed
}

struct AuthorizationApprovalReview: Sendable, Equatable {
  let reviewerLogin: String
  let state: AuthorizationReviewState
  let commitOID: String
}

struct AuthorizationProvenanceSnapshot: Sendable, Equatable {
  let repositoryFullName: String
  let branchName: String
  let branchProtected: Bool
  let mainCommitOID: String
  let registryPath: String
  let authorizationBytes: Data
  let authorizationBlobOID: String
  let reviewedHeadBlobOID: String
  let mergeCommitBlobOID: String
  let pullRequestNumber: Int
  let pullRequestMerged: Bool
  let pullRequestBaseBranch: String
  let pullRequestAuthorLogin: String
  let pullRequestHeadOID: String
  let mergeCommitOID: String
  let mergeCommitIsAncestorOfMain: Bool
  let mergedByLogin: String
  let reviews: [AuthorizationApprovalReview]
  let codeOwnersBytes: Data
  let codeOwnersBlobOID: String
}

protocol AuthorizationProvenancePort: Sendable {
  /// Must perform a fresh protected-main/GitHub read. Implementations must not accept a caller
  /// repository, branch, ref, path, bytes or cache override.
  func fetchFreshSnapshot(authorizationID: String, registryPath: String) async throws
    -> AuthorizationProvenanceSnapshot
}

enum AuthorizationProvenanceError: Error, Sendable, Equatable {
  case invalidAuthorizationID
  case sourceUnavailable
  case wrongRepositoryOrBranch
  case mainIsNotProtected
  case invalidGitOID(field: String)
  case wrongRegistryPath
  case blobBytesMismatch(field: String)
  case blobDrift
  case pullRequestNotMerged
  case wrongPullRequestBase
  case wrongPullRequestAuthor
  case mergeNotOnCurrentMain
  case maintainerMergeMissing
  case codeOwnerPolicyMismatch
  case exactHeadApprovalMissing
  case actorSeparationViolation
  case authorizationParse(RockchipStandingAuthorizationParseError)
  case authorizationIDMismatch
  case displayMetadataMismatch(field: String)
  case invalidAuthorizationReference
}

/// A verifier-minted grant. It is intentionally internal, non-Codable and has no initializer
/// outside ArkDeckWorkflows. The serializable AuthorizationReference is audit identity only and
/// cannot reconstruct this capability.
struct VerifiedAuthorizationGrant: Sendable, Equatable {
  let authorizationReference: AuthorizationReference
  let authorization: RockchipStandingAuthorization
  let registryPath: String

  fileprivate init(
    authorizationReference: AuthorizationReference,
    authorization: RockchipStandingAuthorization,
    registryPath: String
  ) {
    self.authorizationReference = authorizationReference
    self.authorization = authorization
    self.registryPath = registryPath
  }
}

struct MaintainerMergedAuthorizationResolver: Sendable {
  static let repositoryFullName = "ArkDeck/ArkDeck"
  static let protectedBranchName = "main"
  static let registryDirectory =
    "openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/authorizations"
  static let codeOwnersPath = ".github/CODEOWNERS"
  static let pinnedCodeOwnersBlobOID = "f4edd22f87965efcfc27ea512283a0c2252bf0fb"
  static let maintainerLogin = "lvye"
  static let agentPRAuthorLogin = "github-actions[bot]"

  private let port: any AuthorizationProvenancePort

  init(port: any AuthorizationProvenancePort) { self.port = port }

  func resolve(authorizationID: String) async throws -> VerifiedAuthorizationGrant {
    guard RockchipStandingAuthorizationIdentifier.isValid(authorizationID) else {
      throw AuthorizationProvenanceError.invalidAuthorizationID
    }
    let registryPath = Self.registryPath(for: authorizationID)
    let snapshot: AuthorizationProvenanceSnapshot
    do {
      snapshot = try await port.fetchFreshSnapshot(
        authorizationID: authorizationID, registryPath: registryPath)
    } catch {
      throw AuthorizationProvenanceError.sourceUnavailable
    }

    guard snapshot.repositoryFullName == Self.repositoryFullName,
      snapshot.branchName == Self.protectedBranchName
    else { throw AuthorizationProvenanceError.wrongRepositoryOrBranch }
    guard snapshot.branchProtected else { throw AuthorizationProvenanceError.mainIsNotProtected }
    for (field, oid) in [
      ("mainCommitOID", snapshot.mainCommitOID),
      ("authorizationBlobOID", snapshot.authorizationBlobOID),
      ("reviewedHeadBlobOID", snapshot.reviewedHeadBlobOID),
      ("mergeCommitBlobOID", snapshot.mergeCommitBlobOID),
      ("pullRequestHeadOID", snapshot.pullRequestHeadOID),
      ("mergeCommitOID", snapshot.mergeCommitOID),
      ("codeOwnersBlobOID", snapshot.codeOwnersBlobOID),
    ] where !Self.isFullLowercaseGitOID(oid) {
      throw AuthorizationProvenanceError.invalidGitOID(field: field)
    }
    guard snapshot.registryPath == registryPath else {
      throw AuthorizationProvenanceError.wrongRegistryPath
    }
    guard Self.gitBlobOID(snapshot.authorizationBytes) == snapshot.authorizationBlobOID else {
      throw AuthorizationProvenanceError.blobBytesMismatch(field: "authorization")
    }
    guard Self.gitBlobOID(snapshot.codeOwnersBytes) == snapshot.codeOwnersBlobOID else {
      throw AuthorizationProvenanceError.blobBytesMismatch(field: "CODEOWNERS")
    }
    guard snapshot.authorizationBlobOID == snapshot.reviewedHeadBlobOID,
      snapshot.authorizationBlobOID == snapshot.mergeCommitBlobOID
    else { throw AuthorizationProvenanceError.blobDrift }
    guard snapshot.pullRequestMerged, snapshot.pullRequestNumber > 0 else {
      throw AuthorizationProvenanceError.pullRequestNotMerged
    }
    guard snapshot.pullRequestBaseBranch == Self.protectedBranchName else {
      throw AuthorizationProvenanceError.wrongPullRequestBase
    }
    guard snapshot.pullRequestAuthorLogin == Self.agentPRAuthorLogin else {
      throw AuthorizationProvenanceError.wrongPullRequestAuthor
    }
    guard snapshot.mergeCommitIsAncestorOfMain else {
      throw AuthorizationProvenanceError.mergeNotOnCurrentMain
    }
    guard snapshot.mergedByLogin == Self.maintainerLogin else {
      throw AuthorizationProvenanceError.maintainerMergeMissing
    }
    guard snapshot.codeOwnersBlobOID == Self.pinnedCodeOwnersBlobOID,
      Self.codeOwnersRequireMaintainer(snapshot.codeOwnersBytes)
    else { throw AuthorizationProvenanceError.codeOwnerPolicyMismatch }
    guard
      snapshot.reviews.contains(where: {
        $0.reviewerLogin == Self.maintainerLogin && $0.state == .approved
          && $0.commitOID == snapshot.pullRequestHeadOID
      })
    else { throw AuthorizationProvenanceError.exactHeadApprovalMissing }
    guard snapshot.pullRequestAuthorLogin != snapshot.mergedByLogin,
      snapshot.reviews.filter({ $0.state == .approved }).allSatisfy({
        $0.reviewerLogin != snapshot.pullRequestAuthorLogin
      })
    else { throw AuthorizationProvenanceError.actorSeparationViolation }

    let authorization: RockchipStandingAuthorization
    do {
      authorization = try RockchipStandingAuthorization.parse(snapshot.authorizationBytes)
    } catch let error as RockchipStandingAuthorizationParseError {
      throw AuthorizationProvenanceError.authorizationParse(error)
    } catch {
      throw AuthorizationProvenanceError.authorizationParse(.invalidJSON("unknown"))
    }
    guard authorization.authorizationId == authorizationID else {
      throw AuthorizationProvenanceError.authorizationIDMismatch
    }
    guard authorization.approvedBy == Self.maintainerLogin else {
      throw AuthorizationProvenanceError.displayMetadataMismatch(field: "approvedBy")
    }
    guard authorization.carrier.contains("PR #\(snapshot.pullRequestNumber)"),
      authorization.carrier.contains(registryPath)
    else { throw AuthorizationProvenanceError.displayMetadataMismatch(field: "carrier") }

    let reference: AuthorizationReference
    do {
      reference = try AuthorizationReference(
        authorizationID: authorizationID,
        mainCommitOID: snapshot.mainCommitOID,
        authorizationBlobOID: snapshot.authorizationBlobOID,
        approvalPRNumber: snapshot.pullRequestNumber)
    } catch {
      throw AuthorizationProvenanceError.invalidAuthorizationReference
    }
    return VerifiedAuthorizationGrant(
      authorizationReference: reference, authorization: authorization,
      registryPath: registryPath)
  }

  static func registryPath(for authorizationID: String) -> String {
    "\(registryDirectory)/\(authorizationID).json"
  }

  private static func isFullLowercaseGitOID(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private static func codeOwnersRequireMaintainer(_ data: Data) -> Bool {
    guard let text = String(data: data, encoding: .utf8) else { return false }
    let effectiveLines = text.split(whereSeparator: { $0.isNewline }).compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      return line.isEmpty || line.hasPrefix("#") ? nil : line
    }
    return effectiveLines == ["* @\(maintainerLogin)"]
  }

  private static func gitBlobOID(_ data: Data) -> String {
    var bytes = Data("blob \(data.count)\0".utf8)
    bytes.append(data)
    return Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
