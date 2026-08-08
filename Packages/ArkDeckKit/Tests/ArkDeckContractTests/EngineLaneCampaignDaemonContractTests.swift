import ArkDeckAgentClient
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The campaign lane end to end over a real daemon socket
/// (CHG-2026-025 r16, TASK-AIN-019).
///
/// The mapping tests next door prove the bytes; this one proves the chain:
/// the request the dispatcher builds is admitted by the real engine over a
/// real socket against a real open reservation, the reservation is re-verified
/// at the moment before the first mutation, the dispatcher refuses before any
/// spawn, and the job's terminal closes the reservation. Real device dispatch
/// count is zero, by construction.
///
/// Gated on the same real archive as the plan-only suites: the lease the
/// engine resolves must name the published DAYU200 bytes, so there is no
/// honest way to fake this leg.
///
/// One leg is deliberately not on the socket here. Streaming the 731 MB
/// archive through `artifact.importFlashBundle.append` measured ~12 MB/min on
/// this host — roughly an hour per attempt — so this test publishes the same
/// bytes into the same artifact store the handler serves and leases them
/// directly. That is the identical artifact the RPC route would produce; the
/// upload's own contract is covered by the flash-artifact suite. The
/// throughput itself is a real product limitation of the import wire, not of
/// this lane, and is called out in the delivering PR rather than papered over.
final class EngineLaneCampaignDaemonContractTests: XCTestCase {
  private static let archiveEnvironmentKey = "ARKDECK_DAYU200_70035_IMAGE"
  private static let previousTargetIdentity = String(repeating: "6", count: 64)
  private static let targetIdentity = String(repeating: "7", count: 64)
  private static let toolIdentity = String(repeating: "c", count: 64)
  private static let fixedNow = "2026-08-03T00:30:00Z"

  private var stateDirectory: URL!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    // sun_path is 104 bytes; the default temp directory plus a UUID already
    // crowds it, so the socket lives under a short home-relative root.
    stateDirectory = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        ".arkdeck-engine-lane-\(UInt32.random(in: 0..<100_000))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  func testCampaignAttemptRunsThroughTheDaemonAndClosesItsReservation()
    async throws
  {
    guard let archivePath = ProcessInfo.processInfo.environment[Self.archiveEnvironmentKey]
    else {
      throw XCTSkip("set \(Self.archiveEnvironmentKey) for the 7.0.0.35 real-input gate")
    }
    let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035

    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let initialTarget = try targetStore.adopt(
      stableIdentitySHA256: Self.previousTargetIdentity, connectKey: "usb-engine-lane",
      toolVersion: "3.2.0f", nowUTC: Self.fixedNow
    ).record
    let adopted = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: Self.previousTargetIdentity,
        previousRevision: initialTarget.bindingRevision,
        currentStableIdentitySHA256: Self.targetIdentity,
        currentRevision: 2)
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { Self.fixedNow })
    let usageLedger = try AgentAuthorityUsageLedger(
      root: stateDirectory.appendingPathComponent("usage", isDirectory: true))

    // The reservation a nine-gate campaign admission would have minted, with
    // the confirmation pins the engine re-verifies. Seeded directly because
    // the admission service itself needs a physically attached DAYU200, and
    // this test's whole point is that everything after the mint is real.
    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "f", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "b", count: 64),
      archiveDigestSHA256: profile.archiveSHA256,
      stepSetDigestSHA256: String(repeating: "d", count: 64),
      targetStableIdentitySHA256: Self.targetIdentity,
      bindingLineageRootRevision: 2,
      confirmedAt: "2026-08-03T00:00:00Z",
      validUntil: "2026-08-03T03:00:00Z",
      maximumAttempts: 8)
    let operationDigest = String(repeating: "1", count: 64)
    let executionTuning = try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250,
      hdcCommandTimeoutSeconds: 7,
      readOnlyCommandTimeoutSeconds: 9)
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: authorityRef, jobID: "job-engine-lane-1",
      operationDigestSHA256: operationDigest, targetDigestSHA256: Self.targetIdentity)
    _ = try usageLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: reservationID, authorizationRef: authorityRef, ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-engine-lane-1",
        operationDigestSHA256: operationDigest,
        targetDigestSHA256: Self.targetIdentity,
        reservedAt: "2026-08-03T00:20:00Z",
        forwardLeaseExpiresAt: "2026-08-03T02:00:00Z",
        compensationLeaseExpiresAt: "2026-08-03T02:30:00Z",
        campaignEvidenceProvenance: try AgentAuthorityCampaignEvidenceProvenance(
          candidateDigestSHA256: String(repeating: "a", count: 64),
          brokerDigestSHA256: String(repeating: "c", count: 64),
          executionTuning: executionTuning),
        terminal: nil))

    let dispatchLog = DispatchLog()
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let providers = DeviceProviderRegistry(providers: [
      RockchipFlashProviderAdapter(
        factsPort: SealedFactsPort(bindingRevision: adopted.bindingRevision),
        availability: .available)
    ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers,
      dispatcher: RecordingRefusingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      agentUsageLedger: usageLedger,
      nowUTC: { Self.fixedNow })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: { Self.fixedNow },
      targetStore: targetStore,
      bootstrap: nil,
      artifactStore: artifactStore,
      flashBundleImportDirectory: stateDirectory.appendingPathComponent(
        "flash-bundle-imports", isDirectory: true),
      flashBundleImportPolicy: .production,
      harnessCoordinator: nil,
      methodObserver: nil)
    let server = AgentDaemonServer(
      stateDirectory: stateDirectory, handler: handler, nowUTC: { Self.fixedNow })
    guard try server.start() == .started else {
      return XCTFail("the contract daemon must start fresh")
    }
    self.server = server
    let socketPath = stateDirectory.appendingPathComponent("agentd.sock").path

    let admitted = RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: "ECAMP-\(String(repeating: "F", count: 24))", ordinal: 1,
      reservationID: reservationID, jobID: "job-engine-lane-1",
      sessionID: "session-engine-lane-1",
      targetStableIdentitySHA256: Self.targetIdentity, bindingRevision: 2,
      deviceProfileReference: profile.catalogReference,
      partitionPlan: profile.mappedPartitions.map(\.partitionName),
      archiveSHA256: profile.archiveSHA256,
      postFlashVerification: "full")
    // The same bytes the RPC import would have produced, published into the
    // store the handler serves (see the note at the top of this file).
    let artifact = try await artifactStore.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "input-engine-lane", sessionID: "session-input-engine-lane",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: adopted.targetID, bindingRevision: adopted.bindingRevision,
          stableIdentitySHA256: Self.targetIdentity),
        sourceFileURL: archiveURL,
        expectedByteCount: Int(profile.archiveSizeBytes),
        expectedSHA256: profile.archiveSHA256))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)

    let socketGateway = EngineLaneRuntimeGateway.overDaemonSocket(
      AgentClient(socketPath: socketPath))
    var gateway = socketGateway
    gateway.importFlashBundle = { _, _, _ in lease }
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: adopted.targetID, admitter: nil, gateway: gateway)
    let request = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-ENGINE-LANE-0001", archiveURL: archiveURL,
      targetLocationSelector: "42")

    // The dispatcher proves at the last hop that no external effect happened,
    // so the campaign sees a confirmed failure — not a success and not an
    // unknown outcome.
    do {
      _ = try await dispatcher.execute(request, admitted: admitted)
      XCTFail("the contract dispatcher never spawns, so this cannot succeed")
    } catch let error as RockchipFlashExecutionError {
      guard case .semanticFailure(_, let detail) = error else {
        return XCTFail("a refused dispatch is a confirmed failure, got \(error)")
      }
      XCTAssertTrue(detail.contains("failed"), detail)
    }

    // Exactly one dispatch attempt reached the provider — the plan's first
    // mutating step — and it was refused before any process existed. Nothing
    // destructive was ever attempted.
    let dispatched = await dispatchLog.snapshot()
    XCTAssertEqual(dispatched, ["deviceMutation"], "\(dispatched)")
    XCTAssertFalse(dispatched.contains("destructive"), "\(dispatched)")
    let dispatchedTunings = await dispatchLog.executionTunings()
    XCTAssertEqual(dispatchedTunings, [executionTuning])

    // The engine's own gates ran on the real request: intent confirmed by the
    // reservation, then the reservation re-verified immediately before the
    // first mutation.
    let jobs = await engine.listJobs()
    let job = try XCTUnwrap(jobs.first { $0.operationReference.hasPrefix("flash.dayu200") })
    XCTAssertEqual(job.state, "failed")
    XCTAssertFalse(job.outcomeUnknown)
    XCTAssertTrue(
      job.timeline.contains { $0.contains("flash intent confirmed by campaign reservation") },
      "\(job.timeline)")
    XCTAssertTrue(
      job.timeline.contains("campaign reservation verified before first mutation"),
      "\(job.timeline)")
    let wireEvidence = try AgentClient(socketPath: socketPath).request(
      method: "job.evidence", params: ["jobId": .string(job.jobID)])
    let wireEvidenceBytes = try JSONEncoder().encode(wireEvidence)
    let trustedEvidence = try JSONDecoder().decode(
      RuntimeHardwareEvidenceTrustedFacts.self, from: wireEvidenceBytes)
    XCTAssertEqual(trustedEvidence.authority?.campaignID, admitted.campaignID)
    XCTAssertEqual(trustedEvidence.authority?.attemptID, reservationID)
    XCTAssertEqual(trustedEvidence.authority?.attemptOrdinal, admitted.ordinal)
    XCTAssertEqual(
      trustedEvidence.authority?.planDigest,
      trustedEvidence.authority?.consumptionFingerprintSHA256)
    XCTAssertEqual(
      trustedEvidence.authority?.targetBindingDigest, Self.targetIdentity)
    XCTAssertEqual(
      trustedEvidence.authority?.candidateDigest, String(repeating: "a", count: 64))
    XCTAssertEqual(
      trustedEvidence.authority?.reviewDigest, String(repeating: "b", count: 64))
    XCTAssertEqual(
      trustedEvidence.authority?.brokerDigest, String(repeating: "c", count: 64))

    // The job's terminal closed the reservation with exactly the journaled
    // mutating intent. Neither the dispatcher nor the campaign host closes a
    // campaign reservation — that is the engine's job (#992).
    let closed = try XCTUnwrap(
      usageLedger.load().reservations.first { $0.reservationID == reservationID })
    let terminal = try XCTUnwrap(closed.terminal, "the job terminal must close the reservation")
    XCTAssertEqual(terminal.status, .failed)
    XCTAssertEqual(
      terminal.externalIntentEventIDs.count, 1,
      "exactly the journaled mutating intent: \(terminal.externalIntentEventIDs)")
    XCTAssertEqual(
      terminal.confirmedNotExecutedIntentEventIDs, terminal.externalIntentEventIDs,
      "the exact no-effect readback must remain attached to its durable intent")

    // The engine resolved the lease to the published bytes, not to whatever
    // the caller happened to name: this is the exact archive the campaign
    // confirmation pins.
    XCTAssertEqual(artifact.sha256, profile.archiveSHA256)
    XCTAssertEqual(artifact.byteCount, Int(profile.archiveSizeBytes))
  }

  // MARK: - Fixtures

  private actor DispatchLog {
    private var effects: [String] = []
    private var recordedExecutionTunings: [AgentAuthorityCampaignExecutionTuning?] = []

    func record(
      effect: String,
      executionTuning: AgentAuthorityCampaignExecutionTuning?
    ) {
      effects.append(effect)
      recordedExecutionTunings.append(executionTuning)
    }

    func snapshot() -> [String] { effects }
    func executionTunings() -> [AgentAuthorityCampaignExecutionTuning?] {
      recordedExecutionTunings
    }
  }

  private struct RecordingRefusingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog
    func unavailableReason(providerID _: String) -> String? { nil }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      let executionTuning: AgentAuthorityCampaignExecutionTuning?
      if case .hostManaged(let descriptor) = plan.kind {
        executionTuning = descriptor.executionTuning
      } else {
        executionTuning = nil
      }
      await log.record(
        effect: plan.action.effect.rawValue, executionTuning: executionTuning)
      throw RuntimeDispatchFailure.confirmedNotExecuted(
        "the engine-lane contract test proves no process was spawned")
    }
  }

  private struct SealedFactsPort: RockchipRuntimeFactsPort {
    let bindingRevision: Int

    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip",
        toolVersion: BundledRockchipComponent.reportedVersion,
        toolSHA256: EngineLaneCampaignDaemonContractTests.toolIdentity,
        serverFacts: [
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
            TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied
        ], targetID: targetID, bindingRevision: bindingRevision,
        deviceIdentitySHA256: EngineLaneCampaignDaemonContractTests.targetIdentity,
        executionConnectKey: "sealed-engine-lane-connect-key",
        deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-facts",
        buildFingerprint: "preflight-only",
        transport: "sealed-fixture",
        profileID: "dayu200@2",
        collectedAtUTC: EngineLaneCampaignDaemonContractTests.fixedNow)
    }
  }
}
