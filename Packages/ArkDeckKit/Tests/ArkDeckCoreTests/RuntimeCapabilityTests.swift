import Foundation
import Testing

@testable import ArkDeckCore

struct RuntimeCapabilityTests {
  private func makeE1(
    operationScope: [RuntimeCapabilityOperationScope] = [
      .init(operationID: "debug.hap", version: 1)
    ],
    targetScope: RuntimeCapabilityTargetScope = .stablePhysicalIdentity(
      sha256: String(repeating: "a", count: 64)),
    inputConstraints: [String: RuntimeCapabilityInputConstraint] = [:],
    issuedAtUTC: String = "2026-07-01T00:00:00Z",
    expiresAtUTC: String = "2026-12-31T00:00:00Z",
    maximumUses: Int = 10,
    exactPlanDigest: String? = nil,
    exactBindingRevision: Int? = nil
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
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#800 deadbeef"),
      exactPlanDigest: exactPlanDigest,
      exactBindingRevision: exactBindingRevision)
  }

  private func makeE2(
    planDigest: String = String(repeating: "b", count: 64)
  ) throws -> RuntimeCapability {
    try RuntimeCapability(
      capabilityID: "CAP-RT-DAYU200-FLASH-001",
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "flash.dayu200")],
      effectCeiling: .destructive,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T00:00:00Z",
      maximumUses: 1,
      issuer: .init(kind: .maintainerMergedPR, reference: "PR#801 cafebabe"),
      exactPlanDigest: planDigest)
  }

  private func query(
    operationID: String = "debug.hap",
    version: Int? = 1,
    effect: WorkflowEffect = .deviceMutation,
    target: String? = String(repeating: "a", count: 64),
    bindingRevision: Int? = 7,
    planDigest: String? = nil,
    inputs: [String: JSONValue] = [:]
  ) -> RuntimeCapabilityAuthorizationQuery {
    .init(
      operationID: operationID,
      operationVersion: version,
      effect: effect,
      targetStableIdentitySHA256: target,
      targetBindingRevision: bindingRevision,
      planDigest: planDigest,
      inputs: inputs)
  }

  // MARK: - Model invariants

  @Test func validE1AndE2Construct() throws {
    _ = try makeE1()
    _ = try makeE2()
    _ = try RuntimeCapability(
      capabilityID: "CAP-RT-POLICY-DEBUG-001",
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      exactInputs: [:],
      issuedAtUTC: "1970-01-01T00:00:00Z",
      expiresAtUTC: "9999-12-31T23:59:59Z",
      maximumUses: 10_000,
      issuer: .init(kind: .runtimeDefaultPolicy, reference: "catalog:test:debug.hap@1"))
  }

  @Test func dayu200SingletonCapabilityDoesNotAliasLegacyVersionedScope() throws {
    let current = try makeE2()
    let query = RuntimeCapabilityAuthorizationQuery(
      operationID: "flash.dayu200",
      operationVersion: nil,
      effect: .destructive,
      targetStableIdentitySHA256: String(repeating: "a", count: 64),
      targetBindingRevision: 7,
      planDigest: String(repeating: "b", count: 64),
      inputs: [:])
    #expect(throws: Never.self) {
      _ = try current.authorizes(
        query, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1).get()
    }

    let legacy = try RuntimeCapability(
      capabilityID: "CAP-RT-DAYU200-FLASH-LEGACY-001",
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "flash.dayu200", version: 1)],
      effectCeiling: .destructive,
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T00:00:00Z",
      maximumUses: 1,
      issuer: .init(kind: .maintainerMergedPR, reference: "historical decode-only"),
      exactPlanDigest: String(repeating: "b", count: 64))
    assertDenied(
      legacy.authorizes(
        query, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .operationScopeMismatch)
  }

  @Test func runtimePolicyBindsCompleteTypedInputMap() throws {
    let capability = try RuntimeCapability(
      capabilityID: "CAP-RT-POLICY-DEBUG-INPUTS-001",
      targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
      operationScope: [.init(operationID: "debug.hap", version: 1)],
      effectCeiling: .deviceMutation,
      exactInputs: ["captureDiagnostics": .bool(true)],
      issuedAtUTC: "2026-07-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T00:00:00Z",
      maximumUses: 10_000,
      issuer: .init(kind: .runtimeDefaultPolicy, reference: "catalog:test:debug.hap@1"))

    #expect(throws: Never.self) {
      _ = try capability.authorizes(
        query(inputs: ["captureDiagnostics": .bool(true)]),
        nowUTC: "2026-07-02T00:00:00Z",
        remainingUses: 10
      ).get()
    }
    let denial = #expect(throws: RuntimeCapabilityDenial.self) {
      try capability.authorizes(
        query(
          inputs: [
            "captureDiagnostics": .bool(true),
            "cleanupPolicy": .string("retain"),
          ]),
        nowUTC: "2026-07-02T00:00:00Z",
        remainingUses: 10
      ).get()
    }
    // A missing or foreign error is already recorded by #expect(throws:).
    if let denial {
      #expect(denial.reason == .inputConstraintViolated)
    }
  }

  @Test func runtimePolicyWithoutExactInputsIsRejected() {
    #expect(throws: RuntimeCapabilityValidationError.runtimePolicyRequiresExactInputs) {
      try RuntimeCapability(
        capabilityID: "CAP-RT-POLICY-DEBUG-UNBOUND-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 10_000,
        issuer: .init(kind: .runtimeDefaultPolicy, reference: "catalog:test:debug.hap@1"))
    }
  }

  @Test func readOnlyCeilingIsRejected() {
    #expect(throws: RuntimeCapabilityValidationError.unsupportedEffectCeiling(.readOnly)) {
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "observe.device", version: 1)],
        effectCeiling: .readOnly,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"))
    }
  }

  @Test func destructiveRequiresExactPlanDigestSingleUseAndStableTarget() throws {
    #expect(throws: Never.self) {
      _ = try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "flash.dayu200")],
        effectCeiling: .destructive,
        exactInputs: [:],
        exactArtifactFacts: ["artifactSha256": String(repeating: "a", count: 64)],
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .runtimeDefaultPolicy, reference: "catalog:test"),
        exactPlanDigest: String(repeating: "b", count: 64))
    }
    #expect(throws: RuntimeCapabilityValidationError.destructiveRequiresExactPlanDigest) {
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "flash.dayu200")],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"))
    }
    #expect(throws: RuntimeCapabilityValidationError.destructiveRequiresSingleUse) {
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .stablePhysicalIdentity(sha256: String(repeating: "a", count: 64)),
        operationScope: [.init(operationID: "flash.dayu200")],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 2,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"),
        exactPlanDigest: String(repeating: "b", count: 64))
    }
    #expect(throws: RuntimeCapabilityValidationError.destructiveRequiresStableIdentityTarget) {
      try RuntimeCapability(
        capabilityID: "CAP-RT-X-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "flash.dayu200")],
        effectCeiling: .destructive,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-08-01T00:00:00Z",
        maximumUses: 1,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#1"),
        exactPlanDigest: String(repeating: "b", count: 64))
    }
  }

  @Test func deviceMutationCanBindExactPlanAndBindingRevision() throws {
    let capability = try makeE1(
      maximumUses: 1,
      exactPlanDigest: String(repeating: "b", count: 64),
      exactBindingRevision: 7)
    #expect(throws: Never.self) {
      _ = try capability.authorizes(
        query(planDigest: String(repeating: "b", count: 64)),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1
      ).get()
    }
    assertDenied(
      capability.authorizes(
        query(bindingRevision: 8, planDigest: String(repeating: "b", count: 64)),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .targetScopeMismatch)
    assertDenied(
      capability.authorizes(
        query(planDigest: String(repeating: "c", count: 64)),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .planDigestMismatch)
  }

  @Test func malformedTimestampAndExpiryOrderingAreRejected() {
    #expect(throws: (any Error).self) { try makeE1(issuedAtUTC: "2026-07-01 00:00:00") }
    #expect(throws: (any Error).self) { try makeE1(issuedAtUTC: "2026-07-01T00:00:00+08") }
    #expect(throws: (any Error).self) {
      try makeE1(issuedAtUTC: "2026-08-01T00:00:00Z", expiresAtUTC: "2026-07-01T00:00:00Z")
    }
  }

  @Test func codableRoundTripPreservesEquality() throws {
    let capability = try makeE2()
    let data = try JSONEncoder().encode(capability)
    let decoded = try JSONDecoder().decode(RuntimeCapability.self, from: data)
    #expect(decoded == capability)
  }

  @Test func decodingAnInvariantViolatingDocumentFails() throws {
    let capability = try makeE2()
    let data = try JSONEncoder().encode(capability)
    var text = String(data: data, encoding: .utf8)!
    // Corrupt maximumUses to 2: E2 must be single use, so decode must fail.
    text = text.replacingOccurrences(of: "\"maximumUses\":1", with: "\"maximumUses\":2")
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(RuntimeCapability.self, from: Data(text.utf8))
    }
  }

  // MARK: - Authorization matrix

  @Test func happyPathAuthorizes() throws {
    let capability = try makeE1()
    #expect(throws: Never.self) {
      _ = try capability.authorizes(query(), nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3)
        .get()
    }
  }

  private func assertDenied(
    _ result: Result<Void, RuntimeCapabilityDenial>,
    _ reason: RuntimeCapabilityDenialReason,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    switch result {
    case .success:
      Issue.record("expected denial \(reason)", sourceLocation: sourceLocation)
    case .failure(let denial):
      #expect(denial.reason == reason, sourceLocation: sourceLocation)
    }
  }

  @Test func expiryRevocationExhaustionFailClosed() throws {
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

  @Test func scopeAndCeilingFailClosed() throws {
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

  @Test func e2PlanDigestBindingFailClosed() throws {
    let capability = try makeE2()
    let good = query(
      operationID: "flash.dayu200", version: nil, effect: .destructive,
      planDigest: String(repeating: "b", count: 64))
    #expect(throws: Never.self) {
      _ = try capability.authorizes(good, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1).get()
    }
    assertDenied(
      capability.authorizes(
        query(
          operationID: "flash.dayu200", version: nil, effect: .destructive,
          planDigest: nil),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .planDigestRequired)
    assertDenied(
      capability.authorizes(
        query(
          operationID: "flash.dayu200", version: nil, effect: .destructive,
          planDigest: String(repeating: "d", count: 64)),
        nowUTC: "2026-07-15T00:00:00Z", remainingUses: 1),
      .planDigestMismatch)
  }

  @Test func inputConstraintsFailClosed() throws {
    let capability = try makeE1(inputConstraints: [
      "bundleName": .exactString("com.example.demo"),
      "durationSeconds": .integerRange(minimum: 1, maximum: 60),
    ])
    let allowed = query(inputs: [
      "bundleName": .string("com.example.demo"),
      "durationSeconds": .integer(30),
    ])
    #expect(throws: Never.self) {
      _ = try capability.authorizes(allowed, nowUTC: "2026-07-15T00:00:00Z", remainingUses: 3)
        .get()
    }
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

  @Test func defaultReadOnlyPolicyBounds() {
    let policy = RuntimeDefaultReadOnlyPolicy(
      maximumTimeoutSeconds: 60, maximumOutputByteBudget: 1024)
    #expect(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 60, outputByteBudget: 1024) == .allowed)
    #expect(
      policy.evaluate(effect: .hostOnly, timeoutSeconds: 1, outputByteBudget: 1) == .allowed)
    #expect(
      policy.evaluate(effect: .deviceMutation, timeoutSeconds: 1, outputByteBudget: 1)
        == .deniedEffectRequiresCapability(.deviceMutation))
    #expect(
      policy.evaluate(effect: .destructive, timeoutSeconds: 1, outputByteBudget: 1)
        == .deniedEffectRequiresCapability(.destructive))
    #expect(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 61, outputByteBudget: 1)
        == .deniedTimeoutAboveLimit(requested: 61, limit: 60))
    #expect(
      policy.evaluate(effect: .readOnly, timeoutSeconds: 1, outputByteBudget: 2048)
        == .deniedBudgetAboveLimit(requested: 2048, limit: 1024))
  }
}
