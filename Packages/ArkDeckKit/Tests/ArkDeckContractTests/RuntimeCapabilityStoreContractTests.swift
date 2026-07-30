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
    id: String = "CAP-RT-STORE-001", maximumUses: Int = 2
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: id,
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: maximumUses,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#800 deadbeef"))
  }

  private func query(
    effect: WorkflowEffect = .deviceMutation,
    bindingRevision: Int? = 7,
    planDigest: String? = nil,
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
      query: query(), nowUTC: "2026-07-15T00:00:00Z")
    XCTAssertEqual(first.remainingUsesAfter, 1)
    let second = try await store.consume(
      capabilityID: "CAP-RT-STORE-001", reservationID: "res-2",
      query: query(), nowUTC: "2026-07-15T00:01:00Z")
    XCTAssertEqual(second.remainingUsesAfter, 0)
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
