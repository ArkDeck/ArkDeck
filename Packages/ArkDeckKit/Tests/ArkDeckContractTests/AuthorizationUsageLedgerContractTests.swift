import ArkDeckStorage
import Darwin
import Foundation
import XCTest

/// The campaign (E1/agent) usage ledger's durability contract.
///
/// The legacy standing ledger's four tests went with that ledger (T25/W3).
/// What remains is the ledger the campaign lane actually reserves in, plus
/// the historical-decode case: a chat-authority reservation from before the
/// one-shot factory was withdrawn still decodes and still cannot reserve.
final class AuthorizationUsageLedgerContractTests: XCTestCase {




  func testE1LedgerIsIndependentIdempotentBoundedAndConsumesWithoutRefund() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    let first = try e1Reservation(ordinal: 1, maximumUses: 2)
    XCTAssertTrue(
      try AgentAuthorityUsageReservation.canonicalReservationID(
        authorizationRef: first.authorizationRef, jobID: first.jobID,
        operationDigestSHA256: first.operationDigestSHA256,
        targetDigestSHA256: first.targetDigestSHA256
      ).hasPrefix("ain010-"))
    XCTAssertEqual(try ledger.reserve(first), first)
    XCTAssertEqual(try ledger.reserve(first), first)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName).path))

    let closed = try AgentAuthorityUsageTerminal(
      status: .failed, closedAt: "2026-07-28T10:04:00Z",
      externalIntentEventIDs: ["intent-1"])
    XCTAssertEqual(
      try ledger.close(reservationID: first.reservationID, terminal: closed).terminal,
      closed)
    _ = try ledger.reserve(
      e1Reservation(ordinal: 2, maximumUses: 2))
    XCTAssertThrowsError(
      try ledger.reserve(
        e1Reservation(ordinal: 3, maximumUses: 2)))
    XCTAssertEqual(try ledger.load().reservations.count, 2)
  }

  func testLedgerDocumentsFromEveryTerminalGenerationStillLoad() throws {
    // The closed-shape validator accepts exactly the persisted generations,
    // and forgetting one does not relax anything — it bricks the daemon on
    // its own ledger at startup, which is how the completedIntentEventIds
    // addition was caught on 2026-08-04: agentd refused to boot over
    // terminals written the day before.
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    let reservation = try e1Reservation(ordinal: 1, maximumUses: 3)
    _ = try ledger.reserve(reservation)
    _ = try ledger.close(
      reservationID: reservation.reservationID,
      terminal: try AgentAuthorityUsageTerminal(
        status: .failed, closedAt: "2026-08-04T15:30:00Z",
        externalIntentEventIDs: ["intent-flash-partitions"],
        completedIntentEventIDs: ["intent-flash-partitions"]))

    let ledgerURL = directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    for strippedKeys in [
      ["completedIntentEventIds"],
      ["completedIntentEventIds", "confirmedNotExecutedIntentEventIds"],
    ] {
      var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
      var reservations = try XCTUnwrap(document["reservations"] as? [[String: Any]])
      for index in reservations.indices {
        guard var terminal = reservations[index]["terminal"] as? [String: Any] else { continue }
        for key in strippedKeys { terminal.removeValue(forKey: key) }
        reservations[index]["terminal"] = terminal
      }
      document["reservations"] = reservations
      try JSONSerialization.data(withJSONObject: document).write(to: ledgerURL)
      let reloaded = try AgentAuthorityUsageLedger(root: directory).load()
      let terminal = try XCTUnwrap(reloaded.reservations.first?.terminal)
      XCTAssertEqual(terminal.completedIntentEventIDs, [String](), "\(strippedKeys)")
    }
  }

  func testTerminalPinsCompletedIntentsAndDecodesHistoricalAbsence() throws {
    // `completed` must be a subset of the dispatched intents and disjoint
    // from the proven-absent set — an effect cannot be both verified-complete
    // and proven never to have happened.
    let terminal = try AgentAuthorityUsageTerminal(
      status: .failed, closedAt: "2026-08-04T15:00:00Z",
      externalIntentEventIDs: ["intent-flash-partitions", "intent-reboot-device"],
      confirmedNotExecutedIntentEventIDs: ["intent-reboot-device"],
      completedIntentEventIDs: ["intent-flash-partitions"])
    XCTAssertEqual(terminal.completedIntentEventIDs, ["intent-flash-partitions"])
    XCTAssertThrowsError(
      try AgentAuthorityUsageTerminal(
        status: .failed, closedAt: "2026-08-04T15:00:00Z",
        externalIntentEventIDs: ["intent-flash-partitions"],
        completedIntentEventIDs: ["intent-enter-loader-mode"]))
    XCTAssertThrowsError(
      try AgentAuthorityUsageTerminal(
        status: .failed, closedAt: "2026-08-04T15:00:00Z",
        externalIntentEventIDs: ["intent-flash-partitions"],
        confirmedNotExecutedIntentEventIDs: ["intent-flash-partitions"],
        completedIntentEventIDs: ["intent-flash-partitions"]))

    var historical = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal)) as? [String: Any])
    historical.removeValue(forKey: "completedIntentEventIds")
    let decoded = try JSONDecoder().decode(
      AgentAuthorityUsageTerminal.self,
      from: JSONSerialization.data(withJSONObject: historical))
    XCTAssertEqual(decoded.completedIntentEventIDs, [])
  }

  func testTerminalPinsConfirmedNotExecutedIntentsAndDecodesHistoricalAbsence() throws {
    let terminal = try AgentAuthorityUsageTerminal(
      status: .failed, closedAt: "2026-08-03T12:01:12Z",
      externalIntentEventIDs: ["intent-enter-loader-mode"],
      confirmedNotExecutedIntentEventIDs: ["intent-enter-loader-mode"])
    XCTAssertEqual(
      terminal.confirmedNotExecutedIntentEventIDs, ["intent-enter-loader-mode"])
    XCTAssertThrowsError(
      try AgentAuthorityUsageTerminal(
        status: .failed, closedAt: "2026-08-03T12:01:12Z",
        externalIntentEventIDs: ["intent-enter-loader-mode"],
        confirmedNotExecutedIntentEventIDs: ["intent-flash-partitions"]))
    XCTAssertThrowsError(
      try AgentAuthorityUsageTerminal(
        status: .outcomeUnknown, closedAt: "2026-08-03T12:01:12Z",
        externalIntentEventIDs: ["intent-enter-loader-mode"],
        confirmedNotExecutedIntentEventIDs: ["intent-enter-loader-mode"]))

    var historical = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal)) as? [String: Any])
    historical.removeValue(forKey: "confirmedNotExecutedIntentEventIds")
    let decoded = try JSONDecoder().decode(
      AgentAuthorityUsageTerminal.self,
      from: JSONSerialization.data(withJSONObject: historical))
    XCTAssertEqual(decoded.externalIntentEventIDs, ["intent-enter-loader-mode"])
    XCTAssertEqual(decoded.confirmedNotExecutedIntentEventIDs, [])

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    let reservation = try e1Reservation(ordinal: 1, maximumUses: 1)
    _ = try ledger.reserve(reservation)
    _ = try ledger.close(reservationID: reservation.reservationID, terminal: terminal)
    let ledgerURL = directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    var reservations = try XCTUnwrap(document["reservations"] as? [[String: Any]])
    var persistedTerminal = try XCTUnwrap(reservations[0]["terminal"] as? [String: Any])
    // The generation that predates `confirmedNotExecutedIntentEventIds` also
    // predates `completedIntentEventIds`; stripping only one would produce a
    // hybrid shape no build ever persisted, which the closed-shape validator
    // rightly refuses.
    persistedTerminal.removeValue(forKey: "confirmedNotExecutedIntentEventIds")
    persistedTerminal.removeValue(forKey: "completedIntentEventIds")
    reservations[0]["terminal"] = persistedTerminal
    document["reservations"] = reservations
    try JSONSerialization.data(withJSONObject: document).write(to: ledgerURL)

    let historicalLedger = try AgentAuthorityUsageLedger(root: directory)
    let loaded = try XCTUnwrap(historicalLedger.load().reservations[0].terminal)
    XCTAssertEqual(loaded.confirmedNotExecutedIntentEventIDs, [])
  }

  func testE1LedgerSerializesSameTargetAndRejectsCrossKindOrClosedReserve() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    _ = try ledger.reserve(
      e1Reservation(ordinal: 1, maximumUses: 2))
    XCTAssertThrowsError(
      try ledger.reserve(
        e1Reservation(
          ordinal: 2, maximumUses: 2,
          targetDigest: String(repeating: "8", count: 64))))

    XCTAssertThrowsError(
      try AgentAuthorityUsageReservation(
        reservationID: "ain010-e2",
        authorizationRef: try .validatedStandingAuthorization(
          authorizationID: "AUTH-FIXTURE",
          mainCommitOID: String(repeating: "a", count: 40),
          authorizationBlobOID: String(repeating: "b", count: 40),
          approvalPRNumber: 1),
        ordinal: 1, maximumUses: 1, jobID: "job-e2",
        operationDigestSHA256: String(repeating: "7", count: 64),
        targetDigestSHA256: String(repeating: "8", count: 64),
        reservedAt: "2026-07-28T10:00:00Z",
        forwardLeaseExpiresAt: "2026-07-28T10:01:00Z",
        compensationLeaseExpiresAt: "2026-07-28T10:02:00Z"))
  }

  func testE1LedgerCrashWindowsRetainConsumeOnReplaceAndRejectUnknownShape() throws {
    for point in [
      AuthorizationUsageLedgerFaultPoint.beforeTemporaryWrite,
      .afterFileSync,
      .afterReplace,
      .beforeDirectorySync,
    ] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let request = try e1Reservation(ordinal: 1, maximumUses: 1)
      let ledger = try AgentAuthorityUsageLedger(
        root: directory,
        faultInjector: AuthorizationUsageLedgerFaultInjector { observed in
          if observed == point { throw UsageTestFault.injected(point) }
        })
      XCTAssertThrowsError(try ledger.reserve(request))
      let recovered = try AgentAuthorityUsageLedger(root: directory)
      let count = try recovered.load().reservations.count
      XCTAssertEqual(
        count,
        point == .beforeTemporaryWrite || point == .afterFileSync ? 0 : 1)
      XCTAssertEqual(try recovered.reserve(request), request)
      XCTAssertEqual(try recovered.load().reservations.count, 1)
    }

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    _ = try ledger.reserve(e1Reservation(ordinal: 1, maximumUses: 1))
    let url = directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["unexpected"] = true
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    XCTAssertThrowsError(try ledger.load())
  }

  func testHistoricalChatAuthorityRemainsClosedButCannotReserve() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    let reference = try historicalChatAuthority(
      confirmationDigestSHA256: String(repeating: "1", count: 64),
      planDigestSHA256: String(repeating: "2", count: 64),
      archiveDigestSHA256: String(repeating: "3", count: 64),
      stepSetDigestSHA256: String(repeating: "4", count: 64),
      targetDigestSHA256: String(repeating: "5", count: 64),
      confirmedAt: "2026-08-01T12:00:00Z")
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: "job-chat",
      operationDigestSHA256: String(repeating: "2", count: 64),
      targetDigestSHA256: String(repeating: "5", count: 64))
    XCTAssertTrue(reservationID.hasPrefix("ain018-"))
    let reservation = try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: 1, maximumUses: 1, jobID: "job-chat",
      operationDigestSHA256: String(repeating: "2", count: 64),
      targetDigestSHA256: String(repeating: "5", count: 64),
      reservedAt: "2026-08-01T12:00:00Z",
      forwardLeaseExpiresAt: "2026-08-01T12:01:00Z",
      compensationLeaseExpiresAt: "2026-08-01T12:02:00Z")
    XCTAssertThrowsError(try ledger.reserve(reservation)) { error in
      guard case .invalidRecord(let detail) = error as? AuthorizationUsageLedgerError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(detail.contains("historical read-only"))
    }
    XCTAssertTrue(try ledger.load().reservations.isEmpty)
    XCTAssertEqual(
      try JSONDecoder().decode(
        AgentExecutionAuthorityReference.self, from: JSONEncoder().encode(reference)), reference)
  }

  func testUnreviewedCampaignProvenancePersistsOnlyWithExecutionTuning() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authority = try AgentExecutionAuthorityReference.validatedEvolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "1", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "2", count: 64),
      archiveDigestSHA256: String(repeating: "3", count: 64),
      stepSetDigestSHA256: String(repeating: "4", count: 64),
      targetStableIdentitySHA256: String(repeating: "5", count: 64),
      bindingLineageRootRevision: 2,
      confirmedAt: "2026-08-04T00:00:00Z",
      validUntil: "2026-08-04T03:00:00Z",
      maximumAttempts: 16)
    let tuning = try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250,
      hdcCommandTimeoutSeconds: 7,
      readOnlyCommandTimeoutSeconds: 9)
    let provenance = try AgentAuthorityCampaignEvidenceProvenance(
      candidateDigestSHA256: String(repeating: "6", count: 64),
      brokerDigestSHA256: String(repeating: "7", count: 64),
      executionTuning: tuning)
    XCTAssertNil(provenance.reviewDigestSHA256)
    XCTAssertThrowsError(
      try AgentAuthorityCampaignEvidenceProvenance(
        candidateDigestSHA256: String(repeating: "6", count: 64),
        brokerDigestSHA256: String(repeating: "7", count: 64)))

    let jobID = "job-unreviewed-campaign"
    let reservation = try AgentAuthorityUsageReservation(
      reservationID: AgentAuthorityUsageReservation.canonicalReservationID(
        authorizationRef: authority, jobID: jobID,
        operationDigestSHA256: String(repeating: "2", count: 64),
        targetDigestSHA256: String(repeating: "5", count: 64)),
      authorizationRef: authority,
      ordinal: 1,
      maximumUses: 16,
      jobID: jobID,
      operationDigestSHA256: String(repeating: "2", count: 64),
      targetDigestSHA256: String(repeating: "5", count: 64),
      reservedAt: "2026-08-04T00:01:00Z",
      forwardLeaseExpiresAt: "2026-08-04T00:01:30Z",
      compensationLeaseExpiresAt: "2026-08-04T00:02:30Z",
      campaignEvidenceProvenance: provenance)
    let ledger = try AgentAuthorityUsageLedger(root: directory)
    XCTAssertEqual(try ledger.reserve(reservation), reservation)
    let loadedReservation = try XCTUnwrap(try ledger.load().reservations.first)
    XCTAssertEqual(loadedReservation.campaignEvidenceProvenance, provenance)

    let ledgerURL = directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    var reservations = try XCTUnwrap(document["reservations"] as? [[String: Any]])
    var persistedProvenance = try XCTUnwrap(
      reservations.first?["campaignEvidenceProvenance"] as? [String: Any])
    XCTAssertEqual(
      Set(persistedProvenance.keys),
      Set(["candidateDigestSHA256", "brokerDigestSHA256", "executionTuning"]))
    persistedProvenance.removeValue(forKey: "executionTuning")
    reservations[0]["campaignEvidenceProvenance"] = persistedProvenance
    document["reservations"] = reservations
    try JSONSerialization.data(withJSONObject: document).write(to: ledgerURL)

    XCTAssertThrowsError(try ledger.load()) { error in
      XCTAssertEqual(
        error as? AuthorizationUsageLedgerError,
        .invalidRecord("Agent authority campaign evidence provenance shape is not closed"))
    }
  }



  private func e1Reservation(
    ordinal: Int,
    maximumUses: Int,
    targetDigest: String = String(repeating: "8", count: 64)
  ) throws -> AgentAuthorityUsageReservation {
    let reference = try AgentExecutionAuthorityReference.validatedDeviceCapability(
      capabilityID: "CAP-E1-FIXTURE",
      mainCommitOID: String(repeating: "3", count: 40),
      capabilityBlobOID: String(repeating: "4", count: 40),
      approvalPRNumber: 750)
    let jobID = "job-e1-\(ordinal)"
    let operationDigest = String(repeating: "7", count: 64)
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: jobID,
      operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest)
    return try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: ordinal, maximumUses: maximumUses, jobID: jobID,
      operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest,
      reservedAt: "2026-07-28T10:00:00Z",
      forwardLeaseExpiresAt: "2026-07-28T10:01:00Z",
      compensationLeaseExpiresAt: "2026-07-28T10:02:00Z")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-authorization-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private enum UsageTestFault: Error {
  case injected(AuthorizationUsageLedgerFaultPoint)
}

private final class ConcurrentResults: @unchecked Sendable {
  private let lock = NSLock()
  private var successCount = 0
  private var recordedErrors: [Error] = []

  var successes: Int {
    lock.withLock { successCount }
  }

  var errors: [Error] {
    lock.withLock { recordedErrors }
  }

  func recordSuccess() {
    lock.withLock { successCount += 1 }
  }

  func record(_ error: Error) {
    lock.withLock { recordedErrors.append(error) }
  }
}
