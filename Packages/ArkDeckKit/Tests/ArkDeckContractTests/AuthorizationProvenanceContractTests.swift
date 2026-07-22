import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class AuthorizationProvenanceContractTests: XCTestCase {
  private static let authorizationID = "AUTH-2026-025-DAYU200-001"
  private static let mainOID = String(repeating: "c", count: 40)
  private static let headOID = String(repeating: "d", count: 40)
  private static let mergeOID = String(repeating: "e", count: 40)
  private static let codeOwners = Data(
    """
    # ArkDeck CODEOWNERS.
    #
    # Per openspec/governance/enforcement.md, a valid human approval is an
    # approving review by a configured human CODEOWNER on a protected branch/PR
    # (or an equivalent externally verifiable mechanism). @lvye is the human
    # maintainer; automation/agents must never be listed here.
    #
    # All paths require human owner review:
    * @lvye

    """.utf8)

  private func authorizationBytes(
    authorizationID: String = AuthorizationProvenanceContractTests.authorizationID,
    approvedBy: String = "lvye",
    carrier: String? = nil
  ) throws -> Data {
    let plan = try RockchipRockUSBFlashProvider().makePlan(
      mode: .execute, archiveValidation: .valid)
    let path = MaintainerMergedAuthorizationResolver.registryPath(for: Self.authorizationID)
    return try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": "1.0.0",
        "authorizationId": authorizationID,
        "approvedBy": approvedBy,
        "carrier": carrier ?? "protected main PR #296 \(path)",
        "target": [
          "model": RockchipFlashProfile.targetDeviceModel,
          "serialSHA256": Self.sha256("fixture-serial"),
          "bindingRevision": 1,
        ],
        "firmwareArchiveSHA256": plan.archiveSHA256,
        "transport": "usb",
        "toolchainFingerprint": RockchipFlashProfile.pinnedToolchainFingerprint,
        "providerIdentity": RockchipRockUSBFlashProvider.providerIdentity,
        "planDigestSHA256": plan.planDigestSHA256,
        "stepSetDigestSHA256": plan.stepSetDigestSHA256,
        "recoveryPath": "CHG-2026-016 Loader wlx recovery",
        "validUntil": "2030-08-31T00:00:00Z",
        "maxRuns": 1,
      ], options: [.sortedKeys])
  }

  private func snapshot(
    authorizationBytes: Data? = nil,
    repository: String = MaintainerMergedAuthorizationResolver.repositoryFullName,
    branch: String = MaintainerMergedAuthorizationResolver.protectedBranchName,
    protected: Bool = true,
    mainOID: String = AuthorizationProvenanceContractTests.mainOID,
    registryPath: String? = nil,
    authorizationBlobOID: String? = nil,
    reviewedBlobOID: String? = nil,
    mergeBlobOID: String? = nil,
    merged: Bool = true,
    base: String = "main",
    author: String = "github-actions[bot]",
    ancestor: Bool = true,
    mergedBy: String = "lvye",
    reviews: [AuthorizationApprovalReview]? = nil,
    codeOwnersBytes: Data = AuthorizationProvenanceContractTests.codeOwners,
    codeOwnersBlobOID: String? = nil
  ) throws -> AuthorizationProvenanceSnapshot {
    let bytes = try authorizationBytes ?? self.authorizationBytes()
    let blob = authorizationBlobOID ?? Self.gitBlobOID(bytes)
    return AuthorizationProvenanceSnapshot(
      repositoryFullName: repository,
      branchName: branch,
      branchProtected: protected,
      mainCommitOID: mainOID,
      registryPath: registryPath
        ?? MaintainerMergedAuthorizationResolver.registryPath(for: Self.authorizationID),
      authorizationBytes: bytes,
      authorizationBlobOID: blob,
      reviewedHeadBlobOID: reviewedBlobOID ?? blob,
      mergeCommitBlobOID: mergeBlobOID ?? blob,
      pullRequestNumber: 296,
      pullRequestMerged: merged,
      pullRequestBaseBranch: base,
      pullRequestAuthorLogin: author,
      pullRequestHeadOID: Self.headOID,
      mergeCommitOID: Self.mergeOID,
      mergeCommitIsAncestorOfMain: ancestor,
      mergedByLogin: mergedBy,
      reviews: reviews
        ?? [
          AuthorizationApprovalReview(
            reviewerLogin: "lvye", state: .approved, commitOID: Self.headOID)
        ],
      codeOwnersBytes: codeOwnersBytes,
      codeOwnersBlobOID: codeOwnersBlobOID ?? Self.gitBlobOID(codeOwnersBytes))
  }

  func testTEST_AIN_AUTH_PROV_001_ExactProtectedMainProvenanceMintsTypedGrant()
    async throws
  {
    XCTAssertEqual(Self.gitBlobOID(Self.codeOwners), "f4edd22f87965efcfc27ea512283a0c2252bf0fb")
    let port = FakeAuthorizationProvenancePort(snapshot: try snapshot())
    let grant = try await MaintainerMergedAuthorizationResolver(port: port).resolve(
      authorizationID: Self.authorizationID)

    XCTAssertEqual(grant.authorization.authorizationId, Self.authorizationID)
    XCTAssertEqual(grant.authorizationReference.authorizationID, Self.authorizationID)
    XCTAssertEqual(grant.authorizationReference.mainCommitOID, Self.mainOID)
    XCTAssertEqual(grant.authorizationReference.approvalPRNumber, 296)
    let positiveCallCount = await port.callCount
    XCTAssertEqual(positiveCallCount, 1)
    print(
      "TEST-AIN-AUTH-PROV-001 PASS source=protected-main blob=head=merge "
        + "review=exact-head codeowner=pinned actor-separation=valid")
  }

  func testProvenanceSourceIsFixedAndUnavailableSourceFailsClosed() async throws {
    let invalidPort = FakeAuthorizationProvenancePort(snapshot: try snapshot())
    await assertError(.invalidAuthorizationID) {
      try await MaintainerMergedAuthorizationResolver(port: invalidPort).resolve(
        authorizationID: "../AUTH-ESCAPE")
    }
    let invalidCallCount = await invalidPort.callCount
    XCTAssertEqual(invalidCallCount, 0)

    let unavailable = FakeAuthorizationProvenancePort(snapshot: try snapshot(), fails: true)
    await assertError(.sourceUnavailable) {
      try await MaintainerMergedAuthorizationResolver(port: unavailable).resolve(
        authorizationID: Self.authorizationID)
    }
  }

  func testEveryProvenanceRelationshipFailsClosed() async throws {
    let originalBytes = try authorizationBytes()
    let originalBlob = Self.gitBlobOID(originalBytes)
    let alteredCodeOwners = Data("* @someone-else\n".utf8)
    let cases: [(AuthorizationProvenanceError, AuthorizationProvenanceSnapshot)] = [
      (.wrongRepositoryOrBranch, try snapshot(repository: "fork/ArkDeck")),
      (.wrongRepositoryOrBranch, try snapshot(branch: "agent/topic")),
      (.mainIsNotProtected, try snapshot(protected: false)),
      (.invalidGitOID(field: "mainCommitOID"), try snapshot(mainOID: "main")),
      (.wrongRegistryPath, try snapshot(registryPath: "tmp/AUTH.json")),
      (
        .blobBytesMismatch(field: "authorization"),
        try snapshot(
          authorizationBlobOID: String(repeating: "a", count: 40),
          reviewedBlobOID: String(repeating: "a", count: 40),
          mergeBlobOID: String(repeating: "a", count: 40))
      ),
      (
        .blobDrift,
        try snapshot(reviewedBlobOID: String(repeating: "b", count: 40))
      ),
      (.pullRequestNotMerged, try snapshot(merged: false)),
      (.wrongPullRequestBase, try snapshot(base: "release")),
      (.wrongPullRequestAuthor, try snapshot(author: "human")),
      (.mergeNotOnCurrentMain, try snapshot(ancestor: false)),
      (.maintainerMergeMissing, try snapshot(mergedBy: "someone-else")),
      (
        .codeOwnerPolicyMismatch,
        try snapshot(
          codeOwnersBytes: alteredCodeOwners,
          codeOwnersBlobOID: Self.gitBlobOID(alteredCodeOwners))
      ),
      (
        .exactHeadApprovalMissing,
        try snapshot(reviews: [
          AuthorizationApprovalReview(
            reviewerLogin: "lvye", state: .approved, commitOID: Self.mainOID)
        ])
      ),
      (
        .actorSeparationViolation,
        try snapshot(reviews: [
          AuthorizationApprovalReview(
            reviewerLogin: "lvye", state: .approved, commitOID: Self.headOID),
          AuthorizationApprovalReview(
            reviewerLogin: "github-actions[bot]", state: .approved,
            commitOID: Self.headOID),
        ])
      ),
    ]

    for (expected, candidate) in cases {
      let port = FakeAuthorizationProvenancePort(snapshot: candidate)
      await assertError(expected) {
        try await MaintainerMergedAuthorizationResolver(port: port).resolve(
          authorizationID: Self.authorizationID)
      }
    }
    XCTAssertEqual(originalBlob, Self.gitBlobOID(originalBytes))
  }

  func testAuthorizationCarrierCannotSelfAssertIdentityOrApproval() async throws {
    let wrongIDBytes = try authorizationBytes(authorizationID: "AUTH-OTHER-001")
    await assertError(.authorizationIDMismatch) {
      try await MaintainerMergedAuthorizationResolver(
        port: FakeAuthorizationProvenancePort(
          snapshot: try self.snapshot(authorizationBytes: wrongIDBytes))
      )
      .resolve(authorizationID: Self.authorizationID)
    }

    let wrongApprover = try authorizationBytes(approvedBy: "agent")
    await assertError(.displayMetadataMismatch(field: "approvedBy")) {
      try await MaintainerMergedAuthorizationResolver(
        port: FakeAuthorizationProvenancePort(
          snapshot: try self.snapshot(authorizationBytes: wrongApprover))
      )
      .resolve(authorizationID: Self.authorizationID)
    }

    let wrongCarrier = try authorizationBytes(carrier: "PR #296 caller-local.json")
    await assertError(.displayMetadataMismatch(field: "carrier")) {
      try await MaintainerMergedAuthorizationResolver(
        port: FakeAuthorizationProvenancePort(
          snapshot: try self.snapshot(authorizationBytes: wrongCarrier))
      )
      .resolve(authorizationID: Self.authorizationID)
    }
  }

  private func assertError(
    _ expected: AuthorizationProvenanceError,
    operation: () async throws -> VerifiedAuthorizationGrant,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await operation()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as AuthorizationProvenanceError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("unexpected error \(error)", file: file, line: line)
    }
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func gitBlobOID(_ data: Data) -> String {
    var bytes = Data("blob \(data.count)\0".utf8)
    bytes.append(data)
    return Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}

private actor FakeAuthorizationProvenancePort: AuthorizationProvenancePort {
  let snapshot: AuthorizationProvenanceSnapshot
  let fails: Bool
  private(set) var callCount = 0

  init(snapshot: AuthorizationProvenanceSnapshot, fails: Bool = false) {
    self.snapshot = snapshot
    self.fails = fails
  }

  func fetchFreshSnapshot(authorizationID: String, registryPath: String) async throws
    -> AuthorizationProvenanceSnapshot
  {
    callCount += 1
    if fails { throw FakeProvenanceFailure.unavailable }
    return snapshot
  }
}

private enum FakeProvenanceFailure: Error { case unavailable }
