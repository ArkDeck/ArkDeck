import XCTest

@testable import ArkDeckCore

final class RuntimeCapabilityTests: XCTestCase {
  private func makeE1(
    operationScope: [RuntimeCapabilityOperationScope] = [
      .init(operationID: "debug.hap", version: 1)
    ],
    targetScope: RuntimeCapabilityTargetScope = .stablePhysicalIdentity(
      sha256: String(repeating: "a", count: 64)),
    inputConstraints: [String: RuntimeCapabilityInputConstraint] = [:],
    issuedAtUTC: String = "2026-07-01T00:00:00Z",
    expiresAtUTC: String = "2026-12-31T00:00:00Z",
    maximumUses: Int = 10
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-DAYU200-DEBUG-001",
      targetScope: targetScope,
      operationScope: operationScope,
      effectCeiling: .deviceMutation,
      inputConstraints: inputConstraints,
      issuedAtUTC: issuedAtUTC,
      expiresAtUTC: expiresAtUTC,
      maximumUses: maximumUses,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#800 deadbeef"))
  }

  private func makeE2(
    planDigest: String = String(repeating: "b", count: 64)
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-DAYU200-FLASH-001",
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "flash.dayu200", version: 1)],
      effectCeiling: .destructive,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T00:00:00Z",
      maximumUses: 1,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#801 cafebabe"),
      exactPlanDigest: planDigest)
  }

  private func query(
    operationID: String = "debug.hap",
    version: Int = 1,
    effect: WorkflowEffect = .deviceMutation,
    target: String? = String(repeating: "a", count: 64),
    planDigest: String? = nil,
    inputs: [String: JSONValue] = [:]
  ) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: operationID,
      operationVersion: version,
      effect: effect,
      targetStableIdentitySHA256: target,
      planDigest: planDigest,
      inputs: inputs)
  }

  // MARK: - Model invariants

  func testValidE1AndE2Construct() throws {
    _ = try makeE1()
    _ = try makeE2()
  }

  func testReadOnlyCeilingIsRejected() {
    XCTAssertThrowsError(
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "observe.device", version: 1)],
        effectCeiling: .readOnly,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"))
    ) { error in
      XCTAssertEqual(
        error as? RuntimeCapabilityValidationError, .unsupportedEffectCeiling(.readOnly))
    }
  }

  func testDestructiveRequiresExactPlanDigestSingleUseAndStableTarget() throws {
    XCTAssertThrowsError(
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "flash.dayu200", version: 1)],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"))
    ) { error in
      XCTAssertEqual(
        error as? RuntimeCapabilityValidationError, .destructiveRequiresExactPlanDigest)
    }
    XCTAssertThrowsError(
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "flash.dayu200", version: 1)],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 2,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"),
        exactPlanDigest: String(repeating: "b", count: 64))
    ) { error in
      XCTAssertEqual(error as? RuntimeCapabilityValidationError, .destructiveRequiresSingleUse)
    }
    XCTAssertThrowsError(
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "flash.dayu200", version: 1)],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"),
        exactPlanDigest: String(repeating: "b", count: 64))
    ) { error in
      XCTAssertEqual(
        error as? RuntimeCapabilityValidationError, .destructiveRequiresStableIdentityTarget)
    }
  }

  func testPlanDigestOnDeviceMutationIsRejected() {
    XCTAssertThrowsError(
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"),
        exactPlanDigest: String(repeating: "b", count: 64))
    ) { error in
      XCTAssertEqual(
        error as? RuntimeCapabilityValidationError, .exactPlanDigestOnlyForDestructive)
    }
  }

  func testMalformedTimestampAndExpiryOrderingAreRejected() {
    XCTAssertThrowsError(try makeE1(issuedAtUTC: "2026-07-01 00:00:00"))
    XCTAssertThrowsError(try makeE1(issuedAtUTC: "2026-07-01T00:00:00+08"))
    XCTAssertThrowsError(
      try makeE1(issuedAtUTC: "2026-08-01T00:00:00Z", expiresAtUTC: "2026-07-01T00:00:00Z"))
  }

  func testCodableRoundTripPreservesEquality() throws {
    let capability = try makeE2()
    let data = try JSONEncoder().encode(capability)
    let decoded = try JSONDecoder().decode(RuntimeCapability.self, from: data)
    XCTAssertEqual(decoded, capability)
  }

  func testDecodingAnInvariantViolatingDocumentFails() throws {
    let capability = try makeE2()
    let data = try JSONEncoder().encode(capability)
    var text = String(data: data, encoding: .utf8)!
    // Corrupt maximumUses to 2: E2 must be single use, so decode must fail.
    text = text.replacingOccurrences(of: "\"maximumUses\":1", with: "\"maximumUses\":2")
    XCTAssertThrowsError(
      try JSONDecoder().decode(RuntimeCapability.self, from: Data(text.utf8)))
  }

  // MARK: - Authorization matrix

  func testHappyPathAuthorizes() throws {
    let capability = try makeE1()
    XCTAssertNoThrow(
      try capability.authorizes(query(), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3).get())
  }

  private func assertDenied(
    _ result: Result<Void, RuntimeCapabilityDenial>,
    _ reason: RuntimeCapabilityDenialReason,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch result {
    case .success:
      XCTFail("expected denial \(reason)", file: file, line: line)
    case .failure(let denial):
      XCTAssertEqual(denial.reason, reason, file: file, line: line)
    }
  }

  func testExpiryRevocationExhaustionFailClosed() throws {
    let capability = try makeE1()
    assertDenied(
      capability.authorizes(query(), nowUTC: "2027-01-01T00:00:00Z", remainingUses: 3), .expired)
    assertDenied(
      capability.authorizes(query(), nowUTC: "2026-12-31T00:00:00Z", remainingUses: 3), .expired)
    assertDenied(
      capability.authorizes(query(), nowUTC: "2026-06-30T00:00:00Z", remainingUses: 3),
      .notYetValid)
    assertDenied(
      capability.authorizes(query(), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 0), .exhausted)

    let revoked = try RuntimeCapability(
      capabilityID: capability.capabilityID,
      targetScope: capability.targetScope,
      operationScope: capability.operationScope,
      effectCeiling: capability.effectCeiling,
      issuedAtUTC: capability.issuedAtUTC,
      expiresAtUTC: capability.expiresAtUTC,
      maximumUses: capability.maximumUses,
      issuer: capability.issuer,
      revocation: .revoked(atUTC: "2026-07-10T00:00:00Z", reason: "maintainer revoked"))
    assertDenied(
      revoked.authorizes(query(), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3), .revoked)
  }

  func testScopeAndCeilingFailClosed() throws {
    let capability = try makeE1()
    assertDenied(
      capability.authorizes(
        query(operationID: "capture.diagnostics"), nowUTC: "2026-07-15T00:00:00Z",
        remainingUses: 3),
      .operationScopeMismatch)
    assertDenied(
      capability.authorizes(
        query(version: 2), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .operationScopeMismatch)
    assertDenied(
      capability.authorizes(
        query(effect: .destructive), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .effectAboveCeiling)
    assertDenied(
      capability.authorizes(
        query(target: String(repeating: "c", count: 64)), nowUTC: "2026-07-15T00:00:00Z",
        remainingUses: 3),
      .targetScopeMismatch)
    assertDenied(
      capability.authorizes(
        query(target: nil), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .targetIdentityRequired)
  }

  func testE2PlanDigestBindingFailClosed() throws {
    let capability = try makeE2()
    let good = query(
      operationID: "flash.dayu200", effect: .destructive,
      planDigest: String(repeating: "b", count: 64))
    XCTAssertNoThrow(
      try capability.authorizes(good, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1).get())
    assertDenied(
      capability.authorizes(
        query(operationID: "flash.dayu200", effect: .destructive, planDigest: nil),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .planDigestRequired)
    assertDenied(
      capability.authorizes(
        query(
          operationID: "flash.dayu200", effect: .destructive,
          planDigest: String(repeating: "d", count: 64)),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .planDigestMismatch)
  }

  func testInputConstraintsFailClosed() throws {
    let capability = try makeE1(inputConstraints: [
      "bundleName": .exactString("com.example.demo"),
      "durationSeconds": .integerRange(minimum: 1, maximum: 60),
    ])
    let allowed = query(inputs: [
      "bundleName": .string("com.example.demo"),
      "durationSeconds": .integer(30),
    ])
    XCTAssertNoThrow(
      try capability.authorizes(allowed, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3).get())
    assertDenied(
      capability.authorizes(
        query(inputs: [
          "bundleName": .string("com.example.other"),
          "durationSeconds": .integer(30),
        ]),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .inputConstraintViolated)
    assertDenied(
      capability.authorizes(
        query(inputs: [
          "bundleName": .string("com.example.demo"),
          "durationSeconds": .integer(600),
        ]),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .inputConstraintViolated)
    // A constrained input that is absent is a denial, not a pass.
    assertDenied(
      capability.authorizes(
        query(inputs: ["bundleName": .string("com.example.demo")]),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3),
      .inputConstraintViolated)
  }

  // MARK: - Default read-only policy

  func testDefaultReadOnlyPolicyBounds() {
    let policy = RuntimeDefaultReadOnlyPolicy(
      maximumTimeoutSeconds: 60, maximumOutputByteBudget: 1024)
    XCTAssertEqual(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 60, outputByteBudget: 1024), .allowed)
    XCTAssertEqual(
      policy.evaluate(effect: .hostOnly, timeoutSeconds: 1, outputByteBudget: 1), .allowed)
    XCTAssertEqual(
      policy.evaluate(effect: .deviceMutation, timeoutSeconds: 1, outputByteBudget: 1),
      .deniedEffectRequiresCapability(.deviceMutation))
    XCTAssertEqual(
      policy.evaluate(effect: .destructive, timeoutSeconds: 1, outputByteBudget: 1),
      .deniedEffectRequiresCapability(.destructive))
    XCTAssertEqual(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 61, outputByteBudget: 1),
      .deniedTimeoutAboveLimit(requested: 61, limit: 60))
    XCTAssertEqual(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 1, outputByteBudget: 2048),
      .deniedBudgetAboveLimit(requested: 2048, limit: 1024))
  }
}
