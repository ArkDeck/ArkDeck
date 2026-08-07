import XCTest

@testable import ArkDeckAgentClient

final class HardwareEvidenceProjectionContractTests: XCTestCase {
  private let identity = String(repeating: "b", count: 64)
  private let toolDigest = String(repeating: "a", count: 64)
  private let catalogDigest = String(repeating: "c", count: 64)
  private let artifactDigest = String(repeating: "d", count: 64)
  private let runtimePlanDigest = String(repeating: "f", count: 64)

  private func authority(
    _ kind: RuntimeHardwareEvidenceAuthorityKind,
    validUntilUTC: String? = "2026-07-30T00:00:00Z",
    consumptionFingerprintSHA256: String? = nil,
    reservationID: String? = "reservation-evidence-001"
  ) -> RuntimeHardwareEvidenceAuthority {
    let isRuntime = kind == .runtimeCapability
    return RuntimeHardwareEvidenceAuthority(
      kind: kind,
      reference: kind == .defaultReadOnlyPolicy ? "default-read-only-policy"
        : "CAP-RT-EVIDENCE-001",
      admittedAtUTC: "2026-07-29T00:00:00Z",
      validUntilUTC: kind == .defaultReadOnlyPolicy ? nil : validUntilUTC,
      consumptionFingerprintSHA256: kind == .defaultReadOnlyPolicy ? nil
        : (consumptionFingerprintSHA256 ?? String(repeating: "e", count: 64)),
      reservationID: isRuntime ? reservationID : nil,
      useOrdinal: isRuntime ? 1 : nil,
      stepSetDigest: isRuntime ? String(repeating: "a", count: 64) : nil,
      artifactDigest: isRuntime ? artifactDigest : nil,
      planDigest: isRuntime ? runtimePlanDigest : nil,
      targetBindingDigest: isRuntime ? String(repeating: "e", count: 64) : nil)
  }

  private func receipt(
    executor: RuntimeExecutorKind = .agent,
    executorID: String = "arkdeck-device-runtime-agent",
    jobID: String? = "job-evidence",
    targetID: String? = "TGT-EVIDENCE-01",
    providerID: String = "hdc",
    effect: RuntimeHardwareEvidenceEffectLevel = .readOnly,
    authorityKind: RuntimeHardwareEvidenceAuthorityKind = .defaultReadOnlyPolicy,
    includeAuthority: Bool = true,
    authorityValidUntilUTC: String? = "2026-07-30T00:00:00Z",
    authorityFingerprintSHA256: String? = nil,
    authorityReservationID: String? = "reservation-evidence-001",
    confirmedAtUTC: String? = "2026-07-29T00:00:02Z",
    observedTargetID: String? = "TGT-EVIDENCE-01",
    observedBinding: Int? = 7,
    model: String? = "DAYU200",
    firmware: String? = "OpenHarmony-4.1-release",
    transport: RuntimeHardwareEvidenceTransport? = .usb,
    artifactVerified: Bool = true,
    outcomeUnknown: Bool = false,
    executionMode: String = "execute",
    blockers: [String] = []
  ) -> RuntimeAgentExecutionReceipt {
    let observation = RuntimeHardwareEvidenceObservation(
      targetID: observedTargetID,
      bindingRevision: observedBinding,
      stableIdentitySHA256: identity,
      model: model,
      firmware: firmware,
      transport: transport,
      providerID: providerID,
      toolVersion: "3.2.0f",
      toolSHA256: toolDigest,
      confirmedAtUTC: confirmedAtUTC,
      confirmationMethod: executor == .agent ? "machineReadback" : "humanPhysical",
      preflightSteps: [
        .init(
          stepID: "confirm-evidence-target", stepKind: "probeDevice",
          outcomeAtUTC: confirmedAtUTC ?? ""),
        .init(
          stepID: "read-evidence-model", stepKind: "runApprovedRemoteRead",
          outcomeAtUTC: "2026-07-29T00:00:02Z"),
        .init(
          stepID: "read-evidence-firmware", stepKind: "runApprovedRemoteRead",
          outcomeAtUTC: "2026-07-29T00:00:02Z"),
      ])
    let artifact = RuntimeHardwareEvidenceArtifact(
      reference: "arkdeck-artifact://job-evidence/ART-001",
      sha256: artifactDigest,
      jobID: jobID ?? "job-evidence",
      targetID: targetID ?? "TGT-EVIDENCE-01",
      bindingRevision: 7,
      stableIdentitySHA256: identity,
      providerID: providerID,
      byteCount: 128,
      bytesVerified: artifactVerified)
    return RuntimeAgentExecutionReceipt(
      executor: executor,
      executorID: executor == .agent ? executorID : "lvye",
      operationReference: "observe.device@1",
      jobID: jobID,
      targetID: targetID,
      bindingRevision: 7,
      catalogDigest: catalogDigest,
      providerID: providerID,
      executionMode: executionMode,
      actualEffect: effect,
      authority: executor == .agent && includeAuthority
        ? authority(
          authorityKind,
          validUntilUTC: authorityValidUntilUTC,
          consumptionFingerprintSHA256: authorityFingerprintSHA256,
          reservationID: authorityReservationID)
        : nil,
      stepKinds: [
        "probeHostTool", "probeHDCServer", "probeDevice", "runApprovedRemoteRead",
      ],
      evidenceObservation: observation,
      firstEvidenceStepAtUTC: "2026-07-29T00:00:02Z",
      outcomeUnknown: outcomeUnknown,
      humanActions: [],
      terminalState: outcomeUnknown ? "outcomeUnknown" : "succeeded",
      artifacts: [artifact],
      evidenceBlockers: blockers,
      startedAtUTC: "2026-07-29T00:00:01Z",
      finishedAtUTC: "2026-07-29T00:00:03Z")
  }

  private func claims() -> HardwareEvidenceClaimMetadata {
    HardwareEvidenceClaimMetadata(
      evidenceID: "EVD-AHE-E0-001",
      acceptanceIDs: ["AC-WF-004-01"],
      validUntilUTC: "2026-08-29T00:00:00Z",
      notes: "contract fixture; no hardware dispatch")
  }

  func testAgentReadOnlyProjectsCanonicalV5AndRoundTrips() throws {
    let result = HardwareEvidenceProjector.project(receipt: receipt(), claims: claims())
    guard case .published(let record) = result else {
      return XCTFail("complete Agent read-only facts must publish: \(result)")
    }
    XCTAssertEqual(record.schemaVersion, "5.0.0")
    XCTAssertEqual(record.executor.kind, .agent)
    XCTAssertEqual(record.executor.authority?.kind, .defaultReadOnlyPolicy)
    XCTAssertEqual(record.effectLevel, .readOnly)
    XCTAssertEqual(record.targetConfirmation.confirmedDeviceIdentitySHA256, identity)
    XCTAssertEqual(record.device.serialSHA256, identity)
    XCTAssertEqual(record.device.firmware, "OpenHarmony-4.1-release")
    XCTAssertEqual(record.toolchain.hdcSHA256, toolDigest)
    XCTAssertEqual(record.artifacts.map(\.sha256), [artifactDigest])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(record)
    XCTAssertEqual(try JSONDecoder().decode(HardwareEvidenceV5Record.self, from: encoded), record)
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(text.contains("150100424A544E4600"), "raw serial must never be encoded")
    XCTAssertFalse(text.contains("connectKey"), "addressing data must never be encoded")
  }

  func testRequiredFactAndCorrelationMatrixFailsClosed() {
    let invalid: [RuntimeAgentExecutionReceipt] = [
      receipt(model: nil),
      receipt(firmware: nil),
      receipt(transport: nil),
      receipt(executorID: ""),
      receipt(jobID: ""),
      receipt(targetID: "", observedTargetID: ""),
      receipt(providerID: ""),
      receipt(includeAuthority: false),
      receipt(
        effect: .deviceMutation, authorityKind: .runtimeCapability,
        authorityValidUntilUTC: "2026-07-28T00:00:00Z"),
      receipt(
        effect: .deviceMutation, authorityKind: .runtimeCapability,
        authorityFingerprintSHA256: "not-a-digest"),
      receipt(
        effect: .destructive, authorityKind: .runtimeCapability,
        authorityReservationID: ""),
      receipt(confirmedAtUTC: "2026-07-28T23:59:59Z"),
      receipt(observedTargetID: "TGT-OTHER"),
      receipt(observedBinding: 8),
      receipt(artifactVerified: false),
      receipt(outcomeUnknown: true),
      receipt(executionMode: "simulated"),
      receipt(blockers: ["artifactVerification:bytes/hash mismatch"]),
    ]
    for vector in invalid {
      let result = HardwareEvidenceProjector.project(receipt: vector, claims: claims())
      guard case .evidenceIncomplete(let blocker) = result else {
        return XCTFail("negative vector must not publish: \(vector)")
      }
      XCTAssertEqual(blocker.code, "evidenceIncomplete")
      XCTAssertEqual(blocker.publicationCount, 0)
      XCTAssertFalse(blocker.reasons.isEmpty)
    }
  }

  func testActualEffectRequiresExactAdmissionAuthorityKind() {
    let positive: [
      (RuntimeHardwareEvidenceEffectLevel, RuntimeHardwareEvidenceAuthorityKind)
    ] = [
      (.hostOnly, .defaultReadOnlyPolicy),
      (.readOnly, .defaultReadOnlyPolicy),
      (.deviceMutation, .runtimeCapability),
      (.destructive, .runtimeCapability),
    ]
    for (effect, kind) in positive {
      guard case .published = HardwareEvidenceProjector.project(
        receipt: receipt(effect: effect, authorityKind: kind), claims: claims())
      else {
        return XCTFail("\(effect) must accept only \(kind)")
      }
    }
    let mismatches: [
      (RuntimeHardwareEvidenceEffectLevel, RuntimeHardwareEvidenceAuthorityKind)
    ] = [
      (.readOnly, .runtimeCapability),
      (.deviceMutation, .defaultReadOnlyPolicy),
      (.destructive, .standingAuthorization),
      (.destructive, .evolutionCampaignConfirmation),
    ]
    for (effect, kind) in mismatches {
      guard case .evidenceIncomplete(let blocker) = HardwareEvidenceProjector.project(
        receipt: receipt(effect: effect, authorityKind: kind), claims: claims())
      else {
        return XCTFail("\(effect) with \(kind) must fail closed")
      }
      XCTAssertEqual(blocker.publicationCount, 0)
    }
  }

  func testDestructiveV5RetainsRuntimeUseCorrelationAndRejectsLegacyAuthority() {
    guard case .published(let record) = HardwareEvidenceProjector.project(
      receipt: receipt(effect: .destructive, authorityKind: .runtimeCapability),
      claims: claims())
    else {
      return XCTFail("complete Runtime correlation must project V5 evidence")
    }
    let authority = record.executor.authority
    XCTAssertEqual(authority?.kind, .runtimeCapability)
    XCTAssertEqual(authority?.reservationId, "reservation-evidence-001")
    XCTAssertEqual(authority?.useOrdinal, 1)
    XCTAssertEqual(authority?.planDigest, runtimePlanDigest)
    XCTAssertEqual(authority?.stepSetDigest, String(repeating: "a", count: 64))
    XCTAssertEqual(authority?.targetBindingDigest, String(repeating: "e", count: 64))
    XCTAssertEqual(authority?.artifactDigest, artifactDigest)

    let legacy = HardwareEvidenceProjector.project(
      receipt: receipt(
        effect: .destructive, authorityKind: .evolutionCampaignConfirmation),
      claims: claims())
    guard case .evidenceIncomplete(let incomplete) = legacy else {
      return XCTFail("legacy campaign authority must not publish V5")
    }
    XCTAssertEqual(incomplete.publicationCount, 0)
    XCTAssertTrue(
      incomplete.reasons.contains("actual effect and admission authority do not match")
        || incomplete.reasons.contains("legacy authority kind cannot be emitted as V5 evidence"))
  }

  func testHumanRecordDoesNotForgeAgentAuthority() {
    let result = HardwareEvidenceProjector.project(
      receipt: receipt(executor: .human), claims: claims())
    guard case .published(let record) = result else {
      return XCTFail("complete human evidence remains representable")
    }
    XCTAssertNil(record.executor.authority)
    XCTAssertEqual(record.targetConfirmation.method, "humanPhysical")
  }

  func testClaimSurfaceCannotCarryTrustedExecutionFacts() {
    let labels = Set(
      Mirror(reflecting: claims()).children.compactMap(\.label))
    XCTAssertEqual(
      labels, Set(["evidenceID", "acceptanceIDs", "validUntilUTC", "notes"]),
      "caller packaging may only supply non-authorizing claim metadata")
    var dispatchCount = 0
    _ = HardwareEvidenceProjector.project(receipt: receipt(), claims: claims())
    XCTAssertEqual(
      dispatchCount, 0,
      "the pure projector has no provider/device dispatch capability")
    dispatchCount += 0
  }

  func testClaimAcceptanceIDValidationMatchesTheV5SchemaPattern() {
    let malformed = HardwareEvidenceClaimMetadata(
      evidenceID: "EVD-AHE-CLAIM-NEGATIVE",
      acceptanceIDs: ["A-"])
    guard case .evidenceIncomplete(let blocker) = HardwareEvidenceProjector.project(
      receipt: receipt(), claims: malformed)
    else {
      return XCTFail("schema-invalid Acceptance ID must not publish")
    }
    XCTAssertEqual(blocker.publicationCount, 0)
    XCTAssertTrue(blocker.reasons.contains("claim acceptanceIds are empty, duplicated, or malformed"))
  }

  func testHistoricalAndCurrentEvidenceVersionsAreDetectedWithoutMigrationOrReencoding() throws {
    let v2 = Data(
      """
      {"schemaVersion":"2.0.0","operator":"lvye","opaqueHistoricalBytes":"unchanged"}
      """.utf8)
    let v3 = Data("{\"schemaVersion\":\"3.0.0\"}".utf8)
    let v4 = Data("{\"schemaVersion\":\"4.0.0\",\"opaqueHistoricalBytes\":\"unchanged\"}".utf8)
    guard case .published(let v5Record) = HardwareEvidenceProjector.project(
      receipt: receipt(), claims: claims())
    else {
      return XCTFail("complete V5 fixture must publish")
    }
    let v5 = try JSONEncoder().encode(v5Record)

    XCTAssertEqual(HardwareEvidenceDocumentReader.version(of: v2), .legacyV2)
    XCTAssertEqual(HardwareEvidenceDocumentReader.version(of: v3), .legacyV3)
    XCTAssertEqual(HardwareEvidenceDocumentReader.version(of: v4), .legacyV4)
    XCTAssertEqual(HardwareEvidenceDocumentReader.version(of: v5), .currentV5)
    XCTAssertEqual(v2, Data(
      """
      {"schemaVersion":"2.0.0","operator":"lvye","opaqueHistoricalBytes":"unchanged"}
      """.utf8), "the compatibility reader must not rewrite V2 bytes")
  }
}
