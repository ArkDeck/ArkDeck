import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The campaign lane's engine wire: a request may carry an OPEN usage-ledger
/// reservation minted by the bounded-campaign admission service, and the
/// engine re-verifies its embedded confirmation pins, records
/// `evolutionCampaignConfirmation` evidence at the moment before the first
/// mutation, and closes the reservation with the job's terminal. This is the
/// authority POL-AGENT-002 already blesses — implemented on stack A for the
/// first time, so the campaign brain no longer needs the in-process flash
/// executor to reach a device.
final class RuntimeCampaignWireContractTests: XCTestCase {
  private static let archiveEnvironmentKey = "ARKDECK_DAYU200_70035_IMAGE"
  private static let targetIdentity = String(repeating: "a", count: 64)
  private static let toolIdentity = String(repeating: "b", count: 64)
  private static let fixedNow = "2026-08-01T00:00:00Z"

  // MARK: - Wire shape (ungated)

  func testCampaignReservationRoundTripsAndExcludesCapabilityAuthority() throws {
    let request = try RuntimeOperationRequest(
      requestID: "req-campaign-wire",
      idempotencyKey: "idem-campaign-wire",
      target: DurableTargetReference(targetID: "TGT-DAYU200-01", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
      campaignReservation: RuntimeCampaignReservationReference(
        reservationID: "ain019-abc123"))
    let decoded = try RuntimeOperationCodec.decodeRequest(
      try RuntimeOperationCodec.encodeRequest(request))
    XCTAssertEqual(decoded.campaignReservation?.reservationID, "ain019-abc123")
    XCTAssertNil(decoded.authorization)

    // Exactly one E2 authority kind per request.
    XCTAssertThrowsError(
      try RuntimeOperationRequest(
        requestID: "req-two-authorities",
        idempotencyKey: "idem-two-authorities",
        target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
        operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
        authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-X-1"),
        campaignReservation: RuntimeCampaignReservationReference(
          reservationID: "ain019-abc123"))
    ) { error in
      guard let rejection = error as? RuntimeOperationRequestRejection else {
        return XCTFail("expected a wire rejection, got \(error)")
      }
      XCTAssertEqual(rejection.code, .authorizationRequired)
    }

    // Malformed reservation identifiers are refused at the wire.
    XCTAssertThrowsError(
      try RuntimeOperationRequest(
        requestID: "req-bad-reservation",
        idempotencyKey: "idem-bad-reservation",
        target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
        operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
        campaignReservation: RuntimeCampaignReservationReference(reservationID: "no spaces")))

    // Old wire without the field still decodes (2.x minor addition).
    let legacy = Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-legacy-wire",
        "idempotencyKey": "idem-legacy-wire",
        "target": { "targetId": "TGT-DAYU200-01" },
        "operation": { "id": "observe.device", "version": 1 }
      }
      """.utf8)
    XCTAssertNil(try RuntimeOperationCodec.decodeRequest(legacy).campaignReservation)
  }

  func testCampaignExecutionTuningIsBoundedAndLegacyProvenanceRemainsReadable()
    throws
  {
    let tuning = try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250,
      hdcCommandTimeoutSeconds: 7,
      readOnlyCommandTimeoutSeconds: 9)
    let provenance = try AgentAuthorityCampaignEvidenceProvenance(
      candidateDigestSHA256: String(repeating: "a", count: 64),
      brokerDigestSHA256: String(repeating: "c", count: 64),
      executionTuning: tuning)
    let encoded = try JSONEncoder().encode(provenance)
    XCTAssertEqual(
      try JSONDecoder().decode(
        AgentAuthorityCampaignEvidenceProvenance.self, from: encoded), provenance)

    let legacy: [String: Any] = [
      "candidateDigestSHA256": String(repeating: "a", count: 64),
      "reviewDigestSHA256": String(repeating: "b", count: 64),
      "brokerDigestSHA256": String(repeating: "c", count: 64),
    ]
    let decodedLegacy = try JSONDecoder().decode(
      AgentAuthorityCampaignEvidenceProvenance.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(decodedLegacy.reviewDigestSHA256, String(repeating: "b", count: 64))
    XCTAssertNil(decodedLegacy.executionTuning)

    var invalid = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    invalid["executionTuning"] = [
      "loaderDiscoveryTimeoutSeconds": 14,
      "loaderPollIntervalMilliseconds": 250,
      "hdcCommandTimeoutSeconds": 7,
      "readOnlyCommandTimeoutSeconds": 9,
    ]
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        AgentAuthorityCampaignEvidenceProvenance.self,
        from: JSONSerialization.data(withJSONObject: invalid)))
  }

  // MARK: - Facts honesty (ungated)

  func testTargetFactsPortReportsUnknownInsteadOfFabricating() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-facts-honesty-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RuntimeTargetStore(directoryURL: root)
    _ = try store.adopt(
      stableIdentitySHA256: Self.targetIdentity,
      connectKey: "usb-1", toolVersion: "3.2.0f", nowUTC: Self.fixedNow)
    let targetID = try XCTUnwrap(store.list().first?.targetID)
    let port = TargetStoreRockchipRuntimeFactsPort(
      targetStore: store, resolver: FixedResolver(), nowUTC: { Self.fixedNow })

    let facts = try await port.currentFacts(targetID: targetID)
    XCTAssertEqual(facts.deviceMode, "unknown", "adoption records observe no live mode")
    XCTAssertEqual(facts.profileID, "unknown", "the flash profile is a per-request input")
    XCTAssertEqual(facts.deviceIdentitySHA256, Self.targetIdentity)
  }

  // MARK: - Engine lane (real-input gated, same gate as the plan-only tests)

  func testCampaignReservationAdmitsConsumesAndClosesWithTheJobTerminal() async throws {
    guard let archivePath = ProcessInfo.processInfo.environment[Self.archiveEnvironmentKey]
    else {
      throw XCTSkip("set \(Self.archiveEnvironmentKey) for the 7.0.0.35 real-input gate")
    }
    let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-campaign-wire-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let artifactStore = try RuntimeArtifactStore(
      rootURL: root.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { Self.fixedNow })
    let artifact = try await artifactStore.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "input-campaign-wire", sessionID: "session-input-campaign-wire",
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

    let usageLedger = try AgentAuthorityUsageLedger(
      root: root.appendingPathComponent("usage", isDirectory: true))
    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "f", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "b", count: 64),
      archiveDigestSHA256: profile.archiveSHA256,
      stepSetDigestSHA256: String(repeating: "d", count: 64),
      targetStableIdentitySHA256: Self.targetIdentity,
      bindingLineageRootRevision: 1,
      confirmedAt: "2026-07-31T23:00:00Z",
      validUntil: "2026-08-01T03:00:00Z",
      maximumAttempts: 8)
    let operationDigest = String(repeating: "1", count: 64)
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: authorityRef, jobID: "job-campaign-1",
      operationDigestSHA256: operationDigest,
      targetDigestSHA256: Self.targetIdentity)
    _ = try usageLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: reservationID, authorizationRef: authorityRef, ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-campaign-1",
        operationDigestSHA256: operationDigest,
        targetDigestSHA256: Self.targetIdentity,
        reservedAt: "2026-07-31T23:30:00Z",
        forwardLeaseExpiresAt: "2026-08-01T02:00:00Z",
        compensationLeaseExpiresAt: "2026-08-01T02:30:00Z",
        campaignEvidenceProvenance: try AgentAuthorityCampaignEvidenceProvenance(
          candidateDigestSHA256: String(repeating: "c", count: 64),
          brokerDigestSHA256: String(repeating: "e", count: 64),
          executionTuning: try AgentAuthorityCampaignExecutionTuning(
            loaderDiscoveryTimeoutSeconds: 90,
            loaderPollIntervalMilliseconds: 250,
            hdcCommandTimeoutSeconds: 7,
            readOnlyCommandTimeoutSeconds: 9)),
        terminal: nil))

    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appendingPathComponent("engine", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(factsPort: FactsPort(), availability: .available)
      ]),
      dispatcher: RecordingRefusingDispatcher(log: dispatchLog),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appendingPathComponent("capabilities", isDirectory: true)),
      artifactStore: artifactStore,
      agentUsageLedger: usageLedger,
      nowUTC: { Self.fixedNow })

    let inputs: [String: JSONValue] = [
      "imageBundleLease": .string(lease),
      "deviceProfile": .string(profile.catalogReference),
      "partitionPlan": .array(
        profile.mappedPartitions.map { .string($0.partitionName) }),
      "postFlashVerification": .string("basic"),
    ]

    // 1. Unknown reservation: refused at admission, before any dispatch.
    do {
      let acceptance = try await engine.submit(
        encoded(
          try flashRequest(
            requestID: "campaign-unknown", inputs: inputs,
            reservationID: "ain019-never-reserved")))
      _ = try await engine.run(jobID: acceptance.jobID)
      XCTFail("an unknown campaign reservation must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection shape: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired, detail)
      XCTAssertTrue(detail.contains("does not exist"), detail)
    }
    var dispatched = await dispatchLog.snapshot()
    XCTAssertTrue(dispatched.isEmpty)

    // 2. The open reservation admits the submit; the engine verifies the
    //    pins at the moment before the first mutation, the dispatcher
    //    refuses before any spawn, and the job's confirmed failure closes
    //    the reservation with the journaled mutating intent.
    let acceptance = try await engine.submit(
      encoded(
        try flashRequest(
          requestID: "campaign-positive", inputs: inputs,
          reservationID: reservationID)))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed")
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertTrue(
      status.timeline.contains { $0.contains("flash intent confirmed by campaign reservation") },
      "\(status.timeline)")
    XCTAssertTrue(
      status.timeline.contains("campaign reservation verified before first mutation"),
      "\(status.timeline)")
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.authority?.kind, .evolutionCampaignConfirmation)
    XCTAssertEqual(evidence.authority?.campaignCorrelation?.campaignID, "ECAMP-FFFFFFFFFFFFFFFFFFFFFFFF")
    XCTAssertEqual(evidence.authority?.campaignCorrelation?.attemptID, reservationID)
    XCTAssertEqual(evidence.authority?.campaignCorrelation?.attemptOrdinal, 1)
    XCTAssertEqual(
      evidence.authority?.campaignCorrelation?.planDigestSHA256,
      evidence.authority?.consumptionFingerprintSHA256)
    XCTAssertEqual(
      evidence.authority?.campaignCorrelation?.targetBindingDigestSHA256,
      Self.targetIdentity)
    XCTAssertEqual(
      evidence.authority?.campaignCorrelation?.candidateDigestSHA256,
      String(repeating: "c", count: 64))
    XCTAssertEqual(
      evidence.authority?.campaignCorrelation?.reviewDigestSHA256,
      String(repeating: "d", count: 64))
    XCTAssertEqual(
      evidence.authority?.campaignCorrelation?.brokerDigestSHA256,
      String(repeating: "e", count: 64))
    dispatched = await dispatchLog.snapshot()
    XCTAssertEqual(dispatched.count, 1, "\(dispatched)")

    let closed = try XCTUnwrap(
      usageLedger.load().reservations.first { $0.reservationID == reservationID })
    let terminal = try XCTUnwrap(closed.terminal, "the job terminal must close the reservation")
    XCTAssertEqual(terminal.status, .failed)
    XCTAssertEqual(
      terminal.externalIntentEventIDs.count, 1,
      "exactly the journaled mutating intent: \(terminal.externalIntentEventIDs)")

    // 3. A terminal reservation admits nothing further.
    do {
      let again = try await engine.submit(
        encoded(
          try flashRequest(
            requestID: "campaign-reuse", inputs: inputs,
            reservationID: reservationID)))
      _ = try await engine.run(jobID: again.jobID)
      XCTFail("a terminal campaign reservation must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection shape: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired, detail)
      XCTAssertTrue(detail.contains("already terminal"), detail)
    }
    dispatched = await dispatchLog.snapshot()
    XCTAssertEqual(dispatched.count, 1, "no second dispatch")

    // 4. A reservation pinning a different device identity never admits.
    let foreignRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "e", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "b", count: 64),
      archiveDigestSHA256: profile.archiveSHA256,
      stepSetDigestSHA256: String(repeating: "d", count: 64),
      targetStableIdentitySHA256: String(repeating: "9", count: 64),
      bindingLineageRootRevision: 1,
      confirmedAt: "2026-07-31T23:00:00Z",
      validUntil: "2026-08-01T03:00:00Z",
      maximumAttempts: 8)
    let foreignID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: foreignRef, jobID: "job-campaign-2",
      operationDigestSHA256: operationDigest,
      targetDigestSHA256: String(repeating: "9", count: 64))
    _ = try usageLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: foreignID, authorizationRef: foreignRef, ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-campaign-2",
        operationDigestSHA256: operationDigest,
        targetDigestSHA256: String(repeating: "9", count: 64),
        reservedAt: "2026-07-31T23:30:00Z",
        forwardLeaseExpiresAt: "2026-08-01T02:00:00Z",
        compensationLeaseExpiresAt: "2026-08-01T02:30:00Z",
        terminal: nil))
    do {
      let mismatched = try await engine.submit(
        encoded(
          try flashRequest(
            requestID: "campaign-foreign", inputs: inputs,
            reservationID: foreignID)))
      _ = try await engine.run(jobID: mismatched.jobID)
      XCTFail("an identity-mismatched campaign reservation must be refused")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection shape: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired, detail)
      XCTAssertTrue(detail.contains("different stable device identity"), detail)
    }
    dispatched = await dispatchLog.snapshot()
    XCTAssertEqual(dispatched.count, 1)
    let untouchedForeign = try XCTUnwrap(
      usageLedger.load().reservations.first { $0.reservationID == foreignID })
    XCTAssertNil(untouchedForeign.terminal, "a refused admission must not close anything")
  }

  // MARK: - Fixtures

  private actor DispatchLog {
    private(set) var effects: [String] = []
    func record(_ effect: String) { effects.append(effect) }
    func snapshot() -> [String] { effects }
  }

  private struct RecordingRefusingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog
    func unavailableReason(providerID _: String) -> String? { nil }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.record(plan.action.effect.rawValue)
      throw RuntimeDispatchFailure.failed("the campaign wire test never spawns a real process")
    }
  }

  private struct FactsPort: RockchipRuntimeFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip",
        toolVersion: BundledRockchipComponent.reportedVersion,
        toolSHA256: RuntimeCampaignWireContractTests.toolIdentity,
        serverFacts: [:], targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256: RuntimeCampaignWireContractTests.targetIdentity,
        executionConnectKey: "sealed-campaign-wire-connect-key",
        deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-facts",
        buildFingerprint: "preflight-only",
        transport: "sealed-fixture",
        profileID: "dayu200@2", collectedAtUTC: RuntimeCampaignWireContractTests.fixedNow)
    }
  }

  private struct FixedResolver: RuntimeExecutableResolving {
    func resolveExecutable(providerID _: String) throws -> ResolvedExecutable {
      ResolvedExecutable(
        path: "/usr/bin/true",
        sha256: String(repeating: "c", count: 64))
    }
  }

  private func flashRequest(
    requestID: String, inputs: [String: JSONValue], reservationID: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: "idem-\(requestID)",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-70035", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
      inputs: inputs,
      campaignReservation: RuntimeCampaignReservationReference(reservationID: reservationID))
  }

  private func encoded(_ request: RuntimeOperationRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }
}
