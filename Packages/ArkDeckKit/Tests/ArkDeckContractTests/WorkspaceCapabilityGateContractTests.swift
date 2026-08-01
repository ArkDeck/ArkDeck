// The workspace authorization gate (CHG-2026-055, TASK-HFA-009 r2).
//
// Registered acceptance: HFA-AC-18 (capability half) and HFA-AC-19.
//
// Until r2 a workspace mutation was `hostOnly`, which the engine admits under
// the default read-only policy — so patching, building and reverting this
// machine's source needed no authorization at all. These tests pin what
// changed and, more importantly, what did not: a grant for one subject must
// never authorize the other, and the runtime must not issue its own.

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class WorkspaceCapabilityGateContractTests: XCTestCase {
  private let identity = String(repeating: "a1", count: 32)
  private let revision = String(repeating: "b2", count: 32)
  private let scopes = String(repeating: "c3", count: 32)
  private let deviceIdentity = String(repeating: "d4", count: 32)

  // MARK: - A grant is bound to one subject

  func testAWorkspaceGrantDoesNotAuthorizeADeviceMutation() throws {
    let grant = try workspaceGrant()
    // The device query carries no workspace facts, so the workspace scope has
    // nothing to match — and matching by omission is exactly the hole this
    // closes.
    let verdict = grant.authorizes(
      deviceQuery(operationID: "workspace.apply-patch"),
      nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    guard case .failure(let denial) = verdict else {
      return XCTFail("a workspace grant must not authorize a device mutation")
    }
    XCTAssertEqual(denial.reason, .targetIdentityRequired)
  }

  func testADeviceGrantDoesNotAuthorizeAWorkspaceMutation() throws {
    let grant = try deviceGrant()
    let verdict = grant.authorizes(
      workspaceQuery(), nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    guard case .failure(let denial) = verdict else {
      return XCTFail("a device grant must not authorize a workspace mutation")
    }
    // It fails on identity, not on some incidental field: the subjects are
    // different kinds, not the same kind with different values.
    XCTAssertEqual(denial.reason, .targetIdentityRequired)
  }

  func testAGrantForAnotherTreeIsRefused() throws {
    let grant = try workspaceGrant(identity: String(repeating: "ee", count: 32))
    guard case .failure(let denial) = grant.authorizes(
      workspaceQuery(), nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    else {
      return XCTFail("a grant issued for a different workspace must not match")
    }
    XCTAssertEqual(denial.reason, .targetScopeMismatch)
    XCTAssertTrue(denial.detail.contains("workspace identity"))
  }

  func testAWiderWriteScopeThanTheGrantIsRefused() throws {
    let grant = try workspaceGrant(scopes: String(repeating: "ff", count: 32))
    guard case .failure(let denial) = grant.authorizes(
      workspaceQuery(), nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    else {
      return XCTFail("writable scopes outside the grant must not be authorized")
    }
    XCTAssertEqual(denial.reason, .targetScopeMismatch)
    XCTAssertTrue(denial.detail.contains("scopes"))
  }

  // MARK: - Standing versus pinned

  func testAPinnedGrantIsRefusedOnceTheTreeMoves() throws {
    let pinned = try workspaceGrant(expectedRevision: revision)
    guard case .success = pinned.authorizes(
      workspaceQuery(revision: revision), nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    else {
      return XCTFail("a pinned grant must authorize the revision it was pinned to")
    }
    guard case .failure(let denial) = pinned.authorizes(
      workspaceQuery(revision: String(repeating: "0f", count: 32)),
      nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
    else {
      return XCTFail("a pinned grant must not survive the tree moving")
    }
    XCTAssertTrue(denial.detail.contains("revision moved"))
  }

  func testAStandingGrantSurvivesTheRevisionsItsOwnMutationsProduce() throws {
    // Patch, build, test and revert each move the revision. A grant pinned to
    // one would be single-use by construction, and nobody can pre-compute the
    // next three values — so an empty expected revision means "this tree,
    // these scopes". The per-request binding from r1 still refuses a caller
    // whose declared base revision no longer matches.
    let standing = try workspaceGrant(expectedRevision: "")
    for moved in [revision, String(repeating: "12", count: 32), String(repeating: "34", count: 32)] {
      guard case .success = standing.authorizes(
        workspaceQuery(revision: moved), nowUTC: "2026-08-01T00:00:00Z", remainingUses: 8)
      else {
        return XCTFail("a standing grant must survive a revision it authorized the change to")
      }
    }
  }

  // MARK: - The catalog half

  func testEveryWorkspaceMutationRequiresAGrantAndForbidsSelfIssuance() throws {
    let mutations = [
      "workspace.apply-patch@1", "workspace.build-openharmony@1", "workspace.run-tests@1",
      "workspace.revert-patch@1", "workspace.create-checkpoint@1",
    ]
    for reference in mutations {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      XCTAssertEqual(descriptor.minimumEffect, .deviceMutation, reference)
      XCTAssertEqual(descriptor.authorization[.deviceMutation], .standingCapability, reference)
      // Two layers say the runtime may not mint its own workspace grant: the
      // descriptor here, and the engine's issuance branch. Either alone would
      // be a single point of failure for a gate that authorizes itself.
      XCTAssertFalse(descriptor.defaultPolicyIssuanceEnabled, reference)
    }
  }

  func testTheReadOnlyWorkspaceFamilyStillNeedsNoGrant() throws {
    for reference in [
      "workspace.inspect-source@1", "workspace.inspect-git-status@1",
      "workspace.inspect-diff@1", "workspace.read-source-range@1",
      "workspace.symbolize-crash@1",
    ] {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      // Raising reads too would have made the flip look safer while making
      // the loop unable to look at anything.
      XCTAssertEqual(descriptor.minimumEffect, .hostOnly, reference)
      XCTAssertEqual(descriptor.authorization[.hostOnly], .defaultReadOnly, reference)
    }
  }

  // MARK: - Helpers

  private func workspaceGrant(
    identity: String? = nil, expectedRevision: String = "", scopes: String? = nil
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-WORKSPACE-GATE",
      targetScope: .workspaceIdentity(
        sha256: identity ?? self.identity,
        expectedWorkspaceRevision: expectedRevision,
        allowedFileScopesDigest: scopes ?? self.scopes),
      operationScope: [
        RuntimeCapabilityOperationScope(operationID: "workspace.apply-patch", version: 1)
      ],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-30T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 8,
      issuer: RuntimeCapabilityIssuer(
        kind: .maintainerMergedPR, reference: "test:workspace-gate"))
  }

  private func deviceGrant() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-DEVICE-GATE",
      targetScope: .stablePhysicalIdentity(sha256: deviceIdentity),
      operationScope: [
        RuntimeCapabilityOperationScope(operationID: "workspace.apply-patch", version: 1)
      ],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-30T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 8,
      issuer: RuntimeCapabilityIssuer(
        kind: .maintainerMergedPR, reference: "test:device-gate"))
  }

  private func workspaceQuery(revision: String? = nil) -> RuntimeCapabilityAuthorizationQuery {
    RuntimeCapabilityAuthorizationQuery(
      operationID: "workspace.apply-patch", operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: nil, targetBindingRevision: nil,
      planDigest: String(repeating: "9a", count: 32), inputs: [:],
      workspaceIdentitySHA256: identity,
      workspaceRevision: revision ?? self.revision,
      workspaceFileScopesDigest: scopes)
  }

  private func deviceQuery(operationID: String) -> RuntimeCapabilityAuthorizationQuery {
    RuntimeCapabilityAuthorizationQuery(
      operationID: operationID, operationVersion: 1, effect: .deviceMutation,
      targetStableIdentitySHA256: deviceIdentity, targetBindingRevision: 7,
      planDigest: String(repeating: "9a", count: 32), inputs: [:])
  }
}
