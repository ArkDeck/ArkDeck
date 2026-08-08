import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class RuntimeCapabilityStoreContractTests: XCTestCase {
  private var directoryURL: URL!

  override func setUpWithError() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-capability-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let directoryURL {
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }

  private func makeStore() throws -> RuntimeCapabilityStore {
    try RuntimeCapabilityStore(directoryURL: directoryURL)
  }

  private func e1Capability(
    id: String = "CAP-RT-STORE-001",
    maximumUses: Int = 2,
    exactPlanDigest: String? = nil
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id,
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: maximumUses,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#800 deadbeef"),
      exactPlanDigest: exactPlanDigest)
  }

  private func query(
    effect: WorkflowEffect = .deviceMutation,
    bindingRevision: Int? = 7,
    planDigest: String? = String(repeating: "b", count: 64),
    inputs: [String: JSONValue] = [:]
  ) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: "debug.hap",
      operationVersion: 1,
      effect: effect,
      targetStableIdentitySHA256: String(repeating: "a", count: 64),
      targetBindingRevision: bindingRevision,
      planDigest: planDigest,
      inputs: inputs)
  }

  private func workspaceStandingCapability() throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-WORKSPACE-ROUTE",
      targetScope: .workspaceIdentity(
        sha256: String(repeating: "d", count: 64),
        expectedWorkspaceRevision: "",
        allowedFileScopesDigest: String(repeating: "e", count: 64)),
      operationScope: [
        .init(operationID: "workspace.apply-patch", version: 1),
        .init(operationID: "workspace.build-openharmony", version: 1),
      ],
      effectCeiling: .deviceMutation,
      inputConstraints: ["projectRef": .exactString("demo-app")],
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 4,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#test workspace route"))
  }

  private func workspaceQuery(
    operationID: String,
    revision: String,
    planDigest: String,
    inputs: [String: JSONValue]
  ) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: operationID,
      operationVersion: 1,
      effect: .deviceMutation,
      targetStableIdentitySHA256: nil,
      targetBindingRevision: nil,
      planDigest: planDigest,
      inputs: inputs,
      workspaceIdentitySHA256: String(repeating: "d", count: 64),
      workspaceRevision: revision,
      workspaceFileScopesDigest: String(repeating: "e", count: 64))
  }

  func testInstallListInspectRoundTrip() async throws {
    let store = try makeStore()
    let capability = try e1Capability()
    try await store.install(capability)
    let listed = try await store.list()
    XCTAssertEqual(listed.map(\.capability.capabilityID), ["CAP-RT-STORE-001"])
    XCTAssertEqual(listed.first?.remainingUses, 2)
    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(inspected?.capability, capability)
    let missing = try await store.inspect(capabilityID: "CAP-RT-NOPE-001")
    XCTAssertNil(missing)
  }

  func testInstallIsIdempotentForIdenticalDocumentOnly() async throws {
    let store = try makeStore()
    let capability = try e1Capability()
    try await store.install(capability)
    try await store.install(capability)  // identical: fine
    let drifted = try e1Capability(maximumUses: 5)
    do {
      try await store.install(drifted)
      XCTFail("drifted re-install must be rejected")
    } catch let error as RuntimeCapabilityStoreError {
      XCTAssertEqual(error, .capabilityAlreadyInstalled("CAP-RT-STORE-001"))
    }
    let listed = try await store.list()
    XCTAssertEqual(listed.count, 1)
  }

  func testConsumeDecrementsAndExhaustsFailClosed() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    let first = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-1",
      jobID: "job-1",
      query: query(), nowUTC: "2026-07-15T00:00:00Z")
    XCTAssertEqual(first.remainingUsesAfter, 1)
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-1", jobID: "job-1",
      outcome: .confirmed, terminalState: "succeeded",
      atUTC: "2026-07-15T00:00:30Z")
    let second = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-2",
      jobID: "job-2",
      query: query(), nowUTC: "2026-07-15T00:01:00Z")
    XCTAssertEqual(second.remainingUsesAfter, 0)
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-2", jobID: "job-2",
      outcome: .confirmed, terminalState: "failed",
      atUTC: "2026-07-15T00:01:30Z")
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-3",
        query: query(), nowUTC: "2026-07-15T00:02:00Z")
      XCTFail("exhausted capability must deny")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .exhausted)
    }
  }

  func testPendingAndOutcomeUnknownBlockDifferentReservationWithoutConsuming() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 3))
    let first = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first",
      jobID: "job-first", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    XCTAssertEqual(first.ordinal, 1)

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-second",
        jobID: "job-second", query: query(), nowUTC: "2026-07-15T00:01:00Z")
      XCTFail("a pending predecessor must block a new reservation")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .lineageBlocked(let detail) = error else {
        return XCTFail("expected lineageBlocked, got \(error)")
      }
      XCTAssertTrue(detail.contains("pending"))
    }
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first", jobID: "job-first",
      outcome: .outcomeUnknown, terminalState: "waitingForRecovery",
      atUTC: "2026-07-15T00:02:00Z")
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-second",
        jobID: "job-second", query: query(), nowUTC: "2026-07-15T00:03:00Z")
      XCTFail("outcomeUnknown must block a new reservation")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .lineageBlocked(let detail) = error else {
        return XCTFail("expected lineageBlocked, got \(error)")
      }
      XCTAssertTrue(detail.contains("outcomeUnknown"))
    }
    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.remainingUses, 2)
    XCTAssertFalse(status.lineageAllowsNewExecution)
    XCTAssertEqual(status.lineage.last?.outcome, .outcomeUnknown)
  }

  func testConfirmedOutcomeCreatesHashLinkedAuthorizationLineage() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 3))
    let first = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first",
      jobID: "job-first", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first", jobID: "job-first",
      outcome: .confirmed, terminalState: "succeeded",
      atUTC: "2026-07-15T00:00:30Z")
    let inspectedAfterFirst = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let afterFirst = try XCTUnwrap(inspectedAfterFirst)
    XCTAssertTrue(afterFirst.lineageAllowsNewExecution)
    let firstTip = try XCTUnwrap(afterFirst.lineage.first?.lineageTipSHA256)

    let second = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-second",
      jobID: "job-second", query: query(), nowUTC: "2026-07-15T00:01:00Z")
    XCTAssertEqual(second.ordinal, 2)
    XCTAssertEqual(second.previousLineageSHA256, firstTip)
    XCTAssertNotEqual(second.receiptSHA256, first.receiptSHA256)

    // A crash retry of the same Job retains its exact receipt even while
    // the second node is pending.
    let retry = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-second",
      jobID: "job-second", query: query(), nowUTC: "2026-07-15T09:00:00Z")
    XCTAssertEqual(retry, second)
  }

  func testStandingE1LineageAllowsNewPlanAndBindsEveryMaterialization() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 3))
    let firstPlan = String(repeating: "b", count: 64)
    let secondPlan = String(repeating: "c", count: 64)
    let inputs: [String: JSONValue] = [
      "bundleName": .string("com.example.demo"),
      "abilityName": .string("EntryAbility"),
    ]
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-plan-1",
      jobID: "job-plan-1",
      query: query(planDigest: firstPlan, inputs: inputs),
      nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-plan-1",
      jobID: "job-plan-1", outcome: .confirmed, terminalState: "failed",
      atUTC: "2026-07-15T00:00:30Z")

    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-plan-2",
      jobID: "job-plan-2",
      query: query(planDigest: secondPlan, inputs: inputs),
      nowUTC: "2026-07-15T00:01:00Z")

    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.lineage.map(\.materializedPlanDigest), [firstPlan, secondPlan])
    XCTAssertEqual(
      status.lineage.map(\.authorizationScopeFingerprintSHA256).compactMap { $0 }.count,
      2)
    XCTAssertEqual(
      status.lineage[0].authorizationScopeFingerprintSHA256,
      status.lineage[1].authorizationScopeFingerprintSHA256)
    XCTAssertNotEqual(
      status.lineage[0].queryFingerprintSHA256,
      status.lineage[1].queryFingerprintSHA256)
    XCTAssertEqual(status.remainingUses, 1)
  }

  func testMaintainerWorkspaceStandingGrantAllowsDifferentPatchesAndBuild() async throws {
    let store = try makeStore()
    try await store.install(try workspaceStandingCapability())
    let baseInputs: [String: JSONValue] = ["projectRef": .string("demo-app")]
    let steps: [(String, String, String, [String: JSONValue])] = [
      (
        "workspace.apply-patch", String(repeating: "1", count: 64),
        String(repeating: "a", count: 64),
        baseInputs.merging([
          "patchArtifactRef": .string("lease-v1:patch:ART-A"),
          "allowedFileGlobs": .array([.string("entry/src/main/ets/**")]),
        ]) { _, new in new }
      ),
      (
        "workspace.apply-patch", String(repeating: "2", count: 64),
        String(repeating: "b", count: 64),
        baseInputs.merging([
          "patchArtifactRef": .string("lease-v1:patch:ART-B"),
          "allowedFileGlobs": .array([.string("entry/src/main/ets/**")]),
        ]) { _, new in new }
      ),
      (
        "workspace.build-openharmony", String(repeating: "3", count: 64),
        String(repeating: "c", count: 64),
        baseInputs.merging(["buildPresetRef": .string("debug-hap")]) { _, new in new }
      ),
    ]

    for (offset, step) in steps.enumerated() {
      let ordinal = offset + 1
      _ = try await store.consume(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-\(ordinal)",
        jobID: "job-workspace-\(ordinal)",
        query: workspaceQuery(
          operationID: step.0, revision: step.1, planDigest: step.2, inputs: step.3),
        nowUTC: "2026-08-01T00:0\(offset):00Z")
      try await store.recordOutcome(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-\(ordinal)",
        jobID: "job-workspace-\(ordinal)",
        outcome: .confirmed,
        terminalState: "succeeded",
        atUTC: "2026-08-01T00:0\(offset):30Z")
    }

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-out-of-scope",
        jobID: "job-workspace-out-of-scope",
        query: workspaceQuery(
          operationID: "workspace.run-tests",
          revision: String(repeating: "4", count: 64),
          planDigest: String(repeating: "f", count: 64),
          inputs: baseInputs.merging(["testPresetRef": .string("demo-tests")]) {
            _, new in new
          }),
        nowUTC: "2026-08-01T00:03:00Z")
      XCTFail("a standing grant must reauthorize every operation against its envelope")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected operation-scope denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .operationScopeMismatch)
    }

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-input-out-of-scope",
        jobID: "job-workspace-input-out-of-scope",
        query: workspaceQuery(
          operationID: "workspace.apply-patch",
          revision: String(repeating: "4", count: 64),
          planDigest: String(repeating: "f", count: 64),
          inputs: [
            "projectRef": .string("other-app"),
            "patchArtifactRef": .string("lease-v1:patch:ART-C"),
            "allowedFileGlobs": .array([.string("entry/src/main/ets/**")]),
          ]),
        nowUTC: "2026-08-01T00:03:00Z")
      XCTFail("changed inputs must still satisfy the standing grant constraints")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected input-constraint denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .inputConstraintViolated)
    }

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-expired",
        jobID: "job-workspace-expired",
        query: workspaceQuery(
          operationID: "workspace.apply-patch",
          revision: String(repeating: "4", count: 64),
          planDigest: String(repeating: "f", count: 64),
          inputs: steps[0].3),
        nowUTC: "2027-01-01T00:00:00Z")
      XCTFail("an expired standing grant must not authorize a new materialization")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected expiry denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .expired)
    }

    try await store.revoke(
      capabilityID: "CAP-RT-WORKSPACE-ROUTE",
      atUTC: "2026-08-01T00:04:00Z",
      reason: "route closed")
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-WORKSPACE-ROUTE",
        reservationID: "res-workspace-revoked",
        jobID: "job-workspace-revoked",
        query: workspaceQuery(
          operationID: "workspace.apply-patch",
          revision: String(repeating: "4", count: 64),
          planDigest: String(repeating: "f", count: 64),
          inputs: steps[0].3),
        nowUTC: "2026-08-01T00:05:00Z")
      XCTFail("a revoked standing grant must not authorize a new materialization")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected revocation denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .revoked)
    }

    let inspected = try await store.inspect(capabilityID: "CAP-RT-WORKSPACE-ROUTE")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(
      status.lineage.map(\.operationReference),
      ["workspace.apply-patch@1", "workspace.apply-patch@1", "workspace.build-openharmony@1"])
    XCTAssertEqual(Set(status.lineage.compactMap(\.authorizationScopeFingerprintSHA256)).count, 3)
    XCTAssertEqual(status.remainingUses, 1)
    XCTAssertEqual(status.consumptionCount, 3)
    guard case .revoked = status.capability.revocation else {
      return XCTFail("the final status must retain the durable revocation")
    }
  }

  func testDedicatedReadbackCanResolveUnknownWithoutASecondConsumption() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-reconcile",
      jobID: "job-reconcile", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-reconcile",
      jobID: "job-reconcile", outcome: .outcomeUnknown,
      terminalState: "waitingForRecovery", atUTC: "2026-07-15T00:01:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-reconcile",
      jobID: "job-reconcile", outcome: .confirmed,
      terminalState: "succeeded", atUTC: "2026-07-15T00:02:00Z")

    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.consumptionCount, 1)
    XCTAssertEqual(
      status.lineage.first?.outcomeHistory.map(\.outcome),
      [.outcomeUnknown, .confirmed])
    XCTAssertTrue(status.lineageAllowsNewExecution)
  }

  func testDedicatedReadbackCanResolveUnknownAsSafeToReflash() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-safe-reconcile",
      jobID: "job-safe-reconcile", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-safe-reconcile",
      jobID: "job-safe-reconcile", outcome: .outcomeUnknown,
      terminalState: "waitingForRecovery", atUTC: "2026-07-15T00:01:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-safe-reconcile",
      jobID: "job-safe-reconcile", outcome: .safeToReflash,
      terminalState: "failed", atUTC: "2026-07-15T00:02:00Z")

    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.consumptionCount, 1)
    XCTAssertEqual(
      status.lineage.first?.outcomeHistory.map(\.outcome),
      [.outcomeUnknown, .safeToReflash])
    XCTAssertTrue(status.lineageAllowsNewExecution)

    do {
      try await store.recordOutcome(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-safe-reconcile",
        jobID: "job-safe-reconcile", outcome: .confirmed,
        terminalState: "succeeded", atUTC: "2026-07-15T00:03:00Z")
      XCTFail("a safeToReflash terminal must remain immutable")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .outcomeConflict = error else {
        return XCTFail("expected outcomeConflict, got \(error)")
      }
    }
  }

  func testConfirmedLineageStillRejectsScopeDriftWithoutConsuming() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first",
      jobID: "job-first", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-first", jobID: "job-first",
      outcome: .confirmed, terminalState: "succeeded",
      atUTC: "2026-07-15T00:00:30Z")

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-drift",
        jobID: "job-drift", query: query(bindingRevision: 8),
        nowUTC: "2026-07-15T00:01:00Z")
      XCTFail("confirmed history cannot silently expand its binding scope")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .lineageBlocked(let detail) = error else {
        return XCTFail("expected lineageBlocked, got \(error)")
      }
      XCTAssertTrue(detail.contains("drifted"))
    }
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 1)
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testConfirmedLineageStillRejectsTypedInputDriftWithoutConsuming() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    let firstInputs: [String: JSONValue] = [
      "bundleName": .string("com.example.demo")
    ]
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-input-first",
      jobID: "job-input-first",
      query: query(planDigest: String(repeating: "b", count: 64), inputs: firstInputs),
      nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-input-first",
      jobID: "job-input-first", outcome: .confirmed, terminalState: "succeeded",
      atUTC: "2026-07-15T00:00:30Z")

    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-input-drift",
        jobID: "job-input-drift",
        query: query(
          planDigest: String(repeating: "c", count: 64),
          inputs: ["bundleName": .string("com.example.other")]),
        nowUTC: "2026-07-15T00:01:00Z")
      XCTFail("confirmed history cannot silently expand its typed input scope")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .lineageBlocked(let detail) = error else {
        return XCTFail("expected lineageBlocked, got \(error)")
      }
      XCTAssertTrue(detail.contains("typed inputs"))
    }
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 1)
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testExactPlanPinnedCapabilityStillRejectsPlanDrift() async throws {
    let exactPlan = String(repeating: "b", count: 64)
    let store = try makeStore()
    try await store.install(
      try e1Capability(maximumUses: 2, exactPlanDigest: exactPlan))
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-exact-first",
      jobID: "job-exact-first", query: query(planDigest: exactPlan),
      nowUTC: "2026-07-15T00:00:00Z")
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-exact-first",
      jobID: "job-exact-first", outcome: .confirmed, terminalState: "succeeded",
      atUTC: "2026-07-15T00:00:30Z")

    do {
      try await store.validateNewExecution(
        capabilityID: "CAP-RT-STORE-001",
        query: query(planDigest: String(repeating: "c", count: 64)),
        nowUTC: "2026-07-15T00:01:00Z")
      XCTFail("an explicitly exact-plan capability must remain exact")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected plan denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .planDigestMismatch)
    }
  }

  func testConsumeRetryWithSameReservationIsIdempotent() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    let first = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-crash",
      query: query(), nowUTC: "2026-07-15T00:00:00Z")
    // Same reservation, later wall clock (a crash-recovery retry): returns
    // the ORIGINAL receipt and consumes nothing further.
    let retry = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-crash",
      query: query(), nowUTC: "2026-07-15T09:00:00Z")
    XCTAssertEqual(retry, first)
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 1)
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testConsumeRetryWithDriftedFieldsIsAConflict() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-drift",
      query: query(), nowUTC: "2026-07-15T00:00:00Z")
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-drift",
        query: query(inputs: ["bundleName": .string("com.other")]),
        nowUTC: "2026-07-15T00:00:00Z")
      XCTFail("drifted retry must conflict")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .reservationConflict = error else {
        return XCTFail("expected reservationConflict, got \(error)")
      }
    }
  }

  func testConsumptionFingerprintBindsRevisionAndMaterializedPlanDigest() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability(maximumUses: 2))
    let digest = String(repeating: "b", count: 64)
    _ = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-bound-plan",
      query: query(planDigest: digest), nowUTC: "2026-07-15T00:00:00Z")

    for drifted in [
      query(bindingRevision: 8, planDigest: digest),
      query(planDigest: String(repeating: "c", count: 64)),
    ] {
      do {
        _ = try await store.consume(
          capabilityID: "CAP-RT-STORE-001", reservationID: "res-bound-plan",
          query: drifted, nowUTC: "2026-07-15T00:01:00Z")
        XCTFail("binding revision or materialized plan drift must conflict")
      } catch let error as RuntimeCapabilityStoreError {
        guard case .reservationConflict = error else {
          return XCTFail("expected reservationConflict, got \(error)")
        }
      }
    }
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 1)
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testDenialConsumesNothing() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability())
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-denied",
        query: query(effect: .destructive), nowUTC: "2026-07-15T00:00:00Z")
      XCTFail("effect above ceiling must deny")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .effectAboveCeiling)
    }
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 2)
    XCTAssertEqual(status?.consumptionCount, 0)
  }

  func testMissingMaterializedPlanDigestConsumesNothing() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability())
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-no-plan",
        query: query(planDigest: nil), nowUTC: "2026-07-15T00:00:00Z")
      XCTFail("E1 admission must bind a complete materialized plan digest")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .planDigestRequired)
    }
    let status = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 2)
    XCTAssertEqual(status?.consumptionCount, 0)
  }

  func testRevokeIsDurableAndFailClosed() async throws {
    let store = try makeStore()
    try await store.install(try e1Capability())
    try await store.revoke(
      capabilityID: "CAP-RT-STORE-001", atUTC: "2026-07-10T00:00:00Z", reason: "rotated")
    try await store.revoke(  // idempotent
      capabilityID: "CAP-RT-STORE-001", atUTC: "2026-07-11T00:00:00Z", reason: "again")
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-after-revoke",
        query: query(), nowUTC: "2026-07-15T00:00:00Z")
      XCTFail("revoked capability must deny")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .denied(let denial) = error else {
        return XCTFail("expected denial, got \(error)")
      }
      XCTAssertEqual(denial.reason, .revoked)
    }
    do {
      try await store.revoke(
        capabilityID: "CAP-RT-MISSING-001", atUTC: "2026-07-10T00:00:00Z", reason: "x")
      XCTFail("revoking an unknown capability must fail")
    } catch let error as RuntimeCapabilityStoreError {
      XCTAssertEqual(error, .capabilityNotFound("CAP-RT-MISSING-001"))
    }
  }

  func testStateSurvivesStoreReopen() async throws {
    do {
      let store = try makeStore()
      try await store.install(try e1Capability(maximumUses: 3))
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-persist",
        query: query(), nowUTC: "2026-07-15T00:00:00Z")
    }
    let reopened = try makeStore()
    let status = try await reopened.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(status?.remainingUses, 2)
    XCTAssertEqual(status?.consumptionCount, 1)
    // The idempotent-retry ledger also survives reopen.
    let retry = try await reopened.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-persist",
      query: query(), nowUTC: "2026-07-16T00:00:00Z")
    XCTAssertEqual(retry.consumedAtUTC, "2026-07-15T00:00:00Z")
    XCTAssertEqual(retry.remainingUsesAfter, 2)
  }

  func testCorruptedStoreFailsClosed() async throws {
    do {
      let store = try makeStore()
      try await store.install(try e1Capability())
    }
    let documentURL = directoryURL.appendingPathComponent("runtime-capabilities.json")
    let original = try String(contentsOf: documentURL, encoding: .utf8)
    // Break use accounting: remainingUses above maximumUses.
    let corrupted = original.replacingOccurrences(
      of: "\"remainingUses\" : 2", with: "\"remainingUses\" : 99")
    XCTAssertNotEqual(corrupted, original, "fixture assumption: field present")
    try corrupted.write(to: documentURL, atomically: true, encoding: .utf8)
    let store = try makeStore()
    do {
      _ = try await store.list()
      XCTFail("corrupted accounting must fail closed")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .storeCorrupted = error else {
        return XCTFail("expected storeCorrupted, got \(error)")
      }
    }
  }

  func testTamperedLineageDigestFailsClosed() async throws {
    do {
      let store = try makeStore()
      try await store.install(try e1Capability())
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "res-tamper",
        jobID: "job-tamper", query: query(), nowUTC: "2026-07-15T00:00:00Z")
    }
    let documentURL = directoryURL.appendingPathComponent("runtime-capabilities.json")
    let original = try String(contentsOf: documentURL, encoding: .utf8)
    let corrupted = original.replacingOccurrences(
      of: "\"receiptSHA256\" : \"", with: "\"receiptSHA256\" : \"0")
    XCTAssertNotEqual(corrupted, original, "fixture assumption: receipt digest is present")
    try corrupted.write(to: documentURL, atomically: true, encoding: .utf8)
    do {
      _ = try await makeStore().list()
      XCTFail("tampered lineage must fail closed")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .storeCorrupted = error else {
        return XCTFail("expected storeCorrupted, got \(error)")
      }
    }
  }

  func testV1ConsumptionMigratesAsLegacyUnverifiedAndCannotAuthorizeReuse() async throws {
    let capability = try e1Capability(maximumUses: 2)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let capabilityJSON = try XCTUnwrap(
      String(data: encoder.encode(capability), encoding: .utf8))
    let legacy = """
      {
        "schemaVersion":"1.0.0",
        "records":[{
          "capability":\(capabilityJSON),
          "remainingUses":1,
          "consumptions":[{
            "reservationID":"legacy-reservation",
            "consumedAtUTC":"2026-07-15T00:00:00Z",
            "operationReference":"debug.hap@1",
            "queryFingerprintSHA256":"\(String(repeating: "b", count: 64))",
            "remainingUsesAfter":1
          }]
        }]
      }
      """
    try FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    try Data(legacy.utf8).write(
      to: directoryURL.appendingPathComponent("runtime-capabilities.json"))
    let store = try makeStore()
    let inspected = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    let status = try XCTUnwrap(inspected)
    XCTAssertEqual(status.lineage.first?.outcome, .legacyUnverified)
    XCTAssertFalse(status.lineageAllowsNewExecution)
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-STORE-001", reservationID: "new-reservation",
        jobID: "new-job", query: query(), nowUTC: "2026-07-15T00:01:00Z")
      XCTFail("legacy entries without outcomes must not authorize reuse")
    } catch let error as RuntimeCapabilityStoreError {
      guard case .lineageBlocked = error else {
        return XCTFail("expected lineageBlocked, got \(error)")
      }
    }

    // A durable Job record recovered by the engine may resolve the old
    // reservation. Until that exact recovery happens, the migrated row
    // above remains fail-closed.
    try await store.recordOutcome(
      capabilityID: "CAP-RT-STORE-001",
      reservationID: "legacy-reservation",
      jobID: "job-recovered-from-durable-record",
      outcome: .confirmed,
      terminalState: "succeeded",
      atUTC: "2026-07-15T00:02:00Z")
    let resolved = try await store.inspect(capabilityID: "CAP-RT-STORE-001")
    XCTAssertEqual(resolved?.lineage.first?.outcome, .confirmed)
    XCTAssertEqual(
      resolved?.lineage.first?.outcomeHistory.last?.jobID,
      "job-recovered-from-durable-record")
  }

  func testUnknownCapabilityConsumeFails() async throws {
    let store = try makeStore()
    do {
      _ = try await store.consume(
        capabilityID: "CAP-RT-GHOST-001", reservationID: "res-x",
        query: query(), nowUTC: "2026-07-15T00:00:00Z")
      XCTFail("unknown capability must fail")
    } catch let error as RuntimeCapabilityStoreError {
      XCTAssertEqual(error, .capabilityNotFound("CAP-RT-GHOST-001"))
    }
  }
}
