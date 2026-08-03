import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipLegacyEnterLoaderRecoveryContractTests: XCTestCase {
  func testExactLoaderReadbackFinalizesLegacySessionAndUnblocksRetention() async throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(
      path: "rockchip-legacy-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    let usageRoot = base.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    let suite = "RockchipLegacyEnterLoaderRecovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: base)
    }
    let store = SessionSettingsStore(
      defaults: defaults, defaultRootProvider: { sessionsRoot })
    let firstRuntime = SessionStorageApplicationRuntime(settingsStore: store)
    let firstContext = try firstRuntime.makeExecutionContext()
    let admission = try await firstContext.prepareHeavyWriterAdmission()
    let storageSnapshot = HostStorageSnapshot(
      volumeIdentity: admission.volumeIdentity,
      totalBytes: 100_000_000_000, availableBytes: 90_000_000_000, isReadOnly: false)
    let claimRequest = try StorageClaimRequest(
      claimID: "claim-legacy-enter-loader", jobID: "job-legacy-enter-loader",
      volumeIdentity: admission.volumeIdentity,
      budget: StorageBudget(
        metadataHeadroomBytes: 1_024, finalizationHeadroomBytes: 1_024,
        remainingGrowthBytes: 1_024, writerClass: .heavy))
    guard
      case .admitted(let claim) = await firstContext.admitHeavyWriter(
        claimRequest, snapshot: storageSnapshot, admission: admission)
    else { return XCTFail("fixture claim must be admitted") }
    let layout = try await firstContext.createSession(
      sessionID: "rockchip-session-legacy-enter-loader",
      jobID: "job-legacy-enter-loader",
      createdAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T02:24:54Z")),
      claim: claim, admission: admission)

    let previousSerialDigest = sha256(Data("normal-serial".utf8))
    let previousTopology = "100"
    let currentSerial = "loader-serial"
    let currentTopology = "200"
    let targetDigest = sha256(
      Data(
        [
          RockchipFlashProfile.targetDeviceModel, previousSerialDigest, "1", previousTopology,
          String(RockchipProbeEvidence.rockUSBVendorID),
          String(RockchipProbeEvidence.dayu200LoaderProductID),
        ].joined(separator: "|").utf8))
    let plan = try RockchipLegacyEnterLoaderSessionRecovery.legacyPlan(
      profile: .dayu200OpenHarmony70035)
    let reference = AgentExecutionAuthorityReference.chatConfirmation(
      confirmationDigestSHA256: String(repeating: "a", count: 64),
      planDigestSHA256: plan.planDigestSHA256,
      archiveDigestSHA256: plan.archiveSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      targetDigestSHA256: targetDigest,
      confirmedAt: "2026-08-02T02:24:54Z")
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: layout.jobID,
      operationDigestSHA256: plan.planDigestSHA256,
      targetDigestSHA256: targetDigest)
    let enter = try XCTUnwrap(plan.steps.first { $0.id == "rk-rf002-enter-loader" })
    let intentID = "rk-3-intent-rk-rf002-enter-loader"
    let journal = try FileDurableJournal(url: layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "rk-0-created", sequence: 0,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: "2026-08-02T02:24:54Z", executionMode: "execute",
        executionAuthority: "authorizedAgent", coreBaseline: "CORE-2.0.0",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: reference, usageReservationID: reservationID))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "rk-1-preflight", sequence: 1,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: "2026-08-02T02:24:55Z", from: .queued, to: .preflight,
        reason: "fixture", schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "rk-2-running", sequence: 2,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: "2026-08-02T02:24:56Z", from: .preflight, to: .running,
        reason: "fixture", schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
    try journal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: intentID, sequence: 3,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: "2026-08-02T02:24:57Z", step: enter,
        target: JournalTarget(
          scope: "device", targetID: "rockchip-target-legacy",
          connectKey: previousTopology, identitySnapshotHash: targetDigest),
        attempt: 1, bindingRevision: 1,
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: reference, usageReservationID: reservationID))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "rk-4-waiting-recovery", sequence: 4,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: "2026-08-02T02:25:46Z", from: .running, to: .waitingForRecovery,
        reason: "launch-or-outcome-unknown",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion))

    let ledger = try AgentAuthorityUsageLedger(root: usageRoot)
    let historicalReservation = try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: 1, maximumUses: 1, maximumConcurrentJobs: 1,
      jobID: layout.jobID,
      operationDigestSHA256: plan.planDigestSHA256,
      targetDigestSHA256: targetDigest,
      reservedAt: "2026-08-02T02:24:54Z",
      forwardLeaseExpiresAt: "2026-08-02T02:25:24Z",
      compensationLeaseExpiresAt: "2026-08-02T02:26:54Z",
      terminal: AgentAuthorityUsageTerminal(
        status: .outcomeUnknown, closedAt: "2026-08-02T02:25:46Z",
        externalIntentEventIDs: [intentID]))
    let historicalDocument = try AgentAuthorityUsageLedgerDocument(
      reservations: [historicalReservation])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(historicalDocument).write(
      to: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName),
      options: .atomic)

    // New coordinator models process restart: the old claim is no longer a
    // live run, while the directory/journal remain durable.
    let restartedRuntime = SessionStorageApplicationRuntime(settingsStore: store)
    let restarted = try restartedRuntime.makeExecutionContext()
    let binding = RockchipProductBindingSnapshot(
      revision: 2, serial: currentSerial, usbTopology: currentTopology,
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "identity:serial-sha256=\(sha256(Data(currentSerial.utf8)))",
        "rebind:chat-confirmation-sha256=\(String(repeating: "b", count: 64))",
        "identity:previous-serial-sha256=\(previousSerialDigest)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=\(previousTopology)",
      ])
    let selectedTool = RockchipSelectedDiscoveryTool(
      executableURL: URL(fileURLWithPath: "/contract/rkdeveloptool"),
      pathSource: .installedOrdinaryBookmark, bookmarkData: Data("bookmark".utf8),
      reportedVersion: RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: .adHoc, quarantinePresent: false))
    let toolIdentity = ProcessExecutableIdentityReceipt(
      authorizedPath: selectedTool.executableURL.path,
      inodeLaunchPath: "/dev/fd/10", device: 1, inode: 2,
      fileSize: 3, mode: UInt32(S_IFREG | 0o755),
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    let recoveryDate = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-02T02:30:00Z"))
    let journalBeforeMismatchedReadback = try Data(contentsOf: layout.journalURL)
    let mismatchedRecovery = RockchipLegacyEnterLoaderSessionRecovery(
      storage: restarted, agentLedger: ledger, binding: binding,
      tool: selectedTool, toolWorkingDirectory: base,
      liveIdentity: {
        RockchipProductUSBIdentity(
          serial: currentSerial,
          vendorID: RockchipProbeEvidence.rockUSBVendorID,
          productID: RockchipProbeEvidence.dayu200LoaderProductID,
          topology: "201")
      },
      toolIdentity: { toolIdentity },
      now: { recoveryDate })
    do {
      _ = try await mismatchedRecovery.recoverAll()
      XCTFail("mismatched Loader topology must fail closed")
    } catch {
      XCTAssertTrue(
        String(describing: error).contains("not the bound Loader identity"),
        "unexpected mismatch error: \(error)")
    }
    XCTAssertEqual(try Data(contentsOf: layout.journalURL), journalBeforeMismatchedReadback)
    XCTAssertTrue(
      try restarted.catalog.scan(
        retentionDays: restarted.settings.retentionDays,
        policyGeneration: restarted.settings.generation
      ).unknownPressure)

    let recovery = RockchipLegacyEnterLoaderSessionRecovery(
      storage: restarted, agentLedger: ledger, binding: binding,
      tool: selectedTool, toolWorkingDirectory: base,
      liveIdentity: {
        RockchipProductUSBIdentity(
          serial: currentSerial,
          vendorID: RockchipProbeEvidence.rockUSBVendorID,
          productID: RockchipProbeEvidence.dayu200LoaderProductID,
          topology: currentTopology)
      },
      toolIdentity: { toolIdentity },
      now: { recoveryDate })

    let result = try await recovery.recoverAll()
    XCTAssertEqual(result.finalizedSessionIDs, [layout.sessionID])
    XCTAssertEqual(result.deviceMutationDispatchCount, 0)
    let manifest = try AtomicSessionManifestPublisher(layout: layout).load()
    XCTAssertEqual(manifest.status, "failed")
    let replay = try DurableJournalRecovery.inspect(url: layout.journalURL)
    XCTAssertTrue(replay.finalized)
    XCTAssertEqual(replay.currentState, .failed)
    XCTAssertEqual(replay.lastReconcileOutcomeCertainty, .confirmed)
    XCTAssertEqual(replay.outstandingIntents, [])
    XCTAssertEqual(replay.unknownOutcomes, [])
    XCTAssertTrue(
      replay.events.allSatisfy {
        $0.schemaVersion == JournalEvent.agentAuthoritySchemaVersion
      })
    let catalog = try restarted.catalog.scan(
      retentionDays: restarted.settings.retentionDays,
      policyGeneration: restarted.settings.generation)
    XCTAssertFalse(catalog.unknownPressure)
    XCTAssertTrue(catalog.entries.contains { $0.sessionID == layout.sessionID })
    _ = try await restarted.prepareHeavyWriterAdmission()
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
