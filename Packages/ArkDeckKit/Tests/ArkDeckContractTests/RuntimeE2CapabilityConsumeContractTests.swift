import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Drives the Runtime-owned destructive capability path end to end. No device
/// or real process is used: the dispatcher records the first mutation and
/// refuses before spawning it. Historical caller-installed capabilities stay
/// decodable/exportable but cannot admit a new Flash.
final class RuntimeE2CapabilityConsumeContractTests: XCTestCase {
  private static let archiveEnvironmentKey = "ARKDECK_DAYU200_70035_IMAGE"
  private static let targetIdentity = String(repeating: "a", count: 64)
  private static let toolIdentity = String(repeating: "b", count: 64)

  private actor DispatchLog {
    private(set) var effects: [String] = []

    func record(_ effect: String) { effects.append(effect) }
    func snapshot() -> [String] { effects }
  }

  /// Records every dispatch attempt, then refuses before any spawn. The
  /// consume e2e must reach this boundary exactly once and never cross it.
  private struct RecordingRefusingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog

    func unavailableReason(providerID _: String) -> String? { nil }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.record(plan.action.effect.rawValue)
      throw RuntimeDispatchFailure.failed(
        "the consume e2e never spawns a real process")
    }
  }

  private struct FactsPort: RockchipRuntimeFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip",
        toolVersion: BundledRockchipComponent.reportedVersion,
        toolSHA256: RuntimeE2CapabilityConsumeContractTests.toolIdentity,
        serverFacts: [:], targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          RuntimeE2CapabilityConsumeContractTests.targetIdentity,
        executionConnectKey: "sealed-consume-e2e-connect-key",
        deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-facts",
        buildFingerprint: "preflight-only",
        transport: "sealed-fixture",
        profileID: "dayu200@2", collectedAtUTC: "2026-08-01T00:00:00Z")
    }
  }

  func testRuntimeIssuesExactPlanCapabilityAndCallerCapabilityCannotAdmit() async throws {
    guard let archivePath = ProcessInfo.processInfo.environment[Self.archiveEnvironmentKey]
    else {
      throw XCTSkip("set \(Self.archiveEnvironmentKey) for the 7.0.0.35 real-input gate")
    }
    let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-e2-consume-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let artifactStore = try RuntimeArtifactStore(
      rootURL: root.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-08-01T00:00:00Z" })
    let artifact = try await artifactStore.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "input-e2-consume", sessionID: "session-input-e2-consume",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-70035", bindingRevision: 7,
          stableIdentitySHA256: Self.targetIdentity),
        sourceFileURL: archiveURL,
        expectedByteCount: Int(profile.archiveSizeBytes),
        expectedSHA256: profile.archiveSHA256))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: root.appendingPathComponent("capabilities", isDirectory: true))
    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appendingPathComponent("engine", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(
          factsPort: FactsPort(), availability: .available)
      ]),
      dispatcher: RecordingRefusingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-01T00:00:00Z" })

    let inputs = flashInputs(lease: lease, profile: profile)

    // The exact plan digest comes from the engine's own materialization.
    let preview = try await engine.planOnly(
      encoded(try flashRequest(requestID: "runtime-capability-plan", inputs: inputs)))
    XCTAssertEqual(preview.materializedPlanDigest.count, 64)

    // A historical maintainer capability remains installable for
    // decode/export compatibility, but callers cannot select it for a new
    // Runtime-owned destructive execution.
    let historical = try RuntimeCapability(
      capabilityID: "CAP-RT-LEGACY-DESTRUCTIVE-970",
      targetScope: .stablePhysicalIdentity(sha256: Self.targetIdentity),
      operationScope: [
        RuntimeCapabilityOperationScope(operationID: "flash.dayu200", version: 1)
      ],
      effectCeiling: .destructive,
      inputConstraints: exactStringConstraints(from: inputs),
      issuedAtUTC: "2026-08-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T02:00:00Z",
      maximumUses: 1,
      issuer: RuntimeCapabilityIssuer(
        kind: .maintainerMergedPR, reference: "PR#970 legacy export fixture"),
      exactPlanDigest: preview.materializedPlanDigest,
      exactBindingRevision: 7)
    try await capabilityStore.install(historical)
    do {
      let acceptance = try await engine.submit(
        encoded(
          try flashRequest(
            requestID: "runtime-capability-caller-supplied", inputs: inputs,
            capabilityID: historical.capabilityID)))
      _ = try await engine.run(jobID: acceptance.jobID)
      XCTFail("a caller-supplied destructive capability must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection shape: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired, detail)
      XCTAssertTrue(detail.contains("caller-supplied"), detail)
    }
    var dispatched = await dispatchLog.snapshot()
    XCTAssertTrue(dispatched.isEmpty, "refusal must precede any dispatch")
    let historicalInspection = try await capabilityStore.inspect(
      capabilityID: historical.capabilityID)
    let historicalStatus = try XCTUnwrap(historicalInspection)
    XCTAssertEqual(historicalStatus.consumptionCount, 0)

    // No caller authority is supplied. The Runtime materializes the plan,
    // issues a short-lived exact capability, persists it and binds it into
    // the admitted request before any mutation can run.
    let acceptance = try await engine.submit(
      encoded(
        try flashRequest(requestID: "runtime-capability-positive", inputs: inputs)))
    let capabilityStatuses = try await capabilityStore.list()
    let issued = try XCTUnwrap(
      capabilityStatuses.first {
        $0.capability.issuer.kind == .runtimeDefaultPolicy
      })
    XCTAssertEqual(issued.capability.effectCeiling, .destructive)
    XCTAssertEqual(issued.capability.maximumUses, 1)
    XCTAssertEqual(issued.capability.exactPlanDigest, preview.materializedPlanDigest)
    XCTAssertEqual(issued.capability.exactBindingRevision, 7)
    XCTAssertEqual(issued.capability.exactInputs, inputs)
    XCTAssertEqual(issued.capability.exactArtifactFacts?["artifactSha256"], profile.archiveSHA256)
    XCTAssertEqual(
      issued.capability.exactArtifactFacts?["artifactByteCount"],
      String(profile.archiveSizeBytes))
    XCTAssertEqual(issued.consumptionCount, 0)

    let status = try await engine.run(jobID: acceptance.jobID)

    // The dispatcher refuses before spawn. The Runtime nevertheless burns the
    // one-shot intent before crossing the first mutation boundary.
    XCTAssertEqual(status.state, "failed")
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertFalse(status.waitingForHuman)
    XCTAssertTrue(
      status.timeline.contains("capability consumed before first mutation"),
      "\(status.timeline)")

    dispatched = await dispatchLog.snapshot()
    XCTAssertEqual(dispatched.count, 1, "\(dispatched)")
    let dispatchedEffect = try XCTUnwrap(
      dispatched.first.flatMap { WorkflowEffect(rawValue: $0) })
    XCTAssertGreaterThanOrEqual(dispatchedEffect, .deviceMutation)

    let consumedInspection = try await capabilityStore.inspect(
      capabilityID: issued.capability.capabilityID)
    let consumed = try XCTUnwrap(consumedInspection)
    XCTAssertEqual(consumed.consumptionCount, 1)
    XCTAssertEqual(consumed.remainingUses, 0)
    XCTAssertEqual(consumed.lineage.count, 1)

    // A generic failed dispatch is not a complete safeToReflash readback.
    // Changing request/idempotency IDs must not roll to a new capability.
    do {
      let retried = try await engine.submit(
        encoded(
          try flashRequest(requestID: "runtime-capability-unsafe-retry", inputs: inputs)))
      _ = try await engine.run(jobID: retried.jobID)
      XCTFail("an unsafe predecessor must permanently block a new dispatch")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, _) = error else {
        return XCTFail("unexpected unsafe-retry rejection: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired)
    }
    let finalDispatches = await dispatchLog.snapshot()
    XCTAssertEqual(finalDispatches.count, 1)
  }

  // MARK: - Fixtures

  private func flashInputs(
    lease: String, profile: RockchipFlashProfile
  ) -> [String: JSONValue] {
    [
      "imageBundleLease": .string(lease),
      "deviceProfile": .string(profile.catalogReference),
      "partitionPlan": .array(
        profile.mappedPartitions.map { .string($0.partitionName) }),
      "postFlashVerification": .string("basic"),
    ]
  }

  /// Mirrors the draft path's exact-input constraint derivation: strings
  /// pin exactly, arrays stay unconstrained (there is no array constraint
  /// kind), so the capability document matches what a maintainer reviews.
  private func exactStringConstraints(
    from inputs: [String: JSONValue]
  ) -> [String: RuntimeCapabilityInputConstraint] {
    var constraints: [String: RuntimeCapabilityInputConstraint] = [:]
    for (key, value) in inputs {
      if case .string(let text) = value {
        constraints[key] = .exactString(text)
      }
    }
    return constraints
  }

  private func flashRequest(
    requestID: String, inputs: [String: JSONValue], capabilityID: String? = nil
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: "idem-\(requestID)",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-70035", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
      inputs: inputs,
      authorization: capabilityID.map(RuntimeCapabilityReference.init))
  }

  private func encoded(_ request: RuntimeOperationRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }
}
