import ArkDeckCore
import ArkDeckStorage
import Foundation
import XCTest

/// Historical Agent-authority records stay readable and can receive an honest
/// crash-recovery terminal, but no API can mint a new reservation.
final class AuthorizationUsageLedgerContractTests: XCTestCase {
  func testHistoricalReservationLoadsAndCanOnlyReceiveATerminal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reservation = historicalDeviceCapabilityReservation(jobID: "job-historical-1")
    try writeLedger([reservation], to: directory)

    let ledger = try AgentAuthorityUsageLedger(root: directory)
    let loaded = try XCTUnwrap(ledger.load().reservations.first)
    XCTAssertEqual(loaded.jobID, "job-historical-1")
    XCTAssertNil(loaded.terminal)

    let terminal = try AgentAuthorityUsageTerminal(
      status: .outcomeUnknown,
      closedAt: "2026-08-19T00:00:00Z",
      externalIntentEventIDs: ["intent-flash-partitions"])
    let closed = try ledger.close(reservationID: loaded.reservationID, terminal: terminal)
    XCTAssertEqual(closed.terminal, terminal)
    XCTAssertEqual(
      try ledger.close(reservationID: loaded.reservationID, terminal: terminal), closed,
      "an identical recovery close remains idempotent")

    XCTAssertThrowsError(
      try ledger.close(
        reservationID: loaded.reservationID,
        terminal: AgentAuthorityUsageTerminal(
          status: .failed, closedAt: "2026-08-19T00:00:01Z",
          externalIntentEventIDs: ["intent-flash-partitions"])))
  }

  func testHistoricalTerminalGenerationsRemainReadable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var reservation = historicalDeviceCapabilityReservation(jobID: "job-historical-terminal")
    reservation["terminal"] = [
      "status": "failed",
      "closedAt": "2026-08-04T15:30:00Z",
      "externalIntentEventIds": ["intent-flash-partitions"],
    ]
    try writeLedger([reservation], to: directory)

    let terminal = try XCTUnwrap(
      AgentAuthorityUsageLedger(root: directory).load().reservations.first?.terminal)
    XCTAssertEqual(terminal.externalIntentEventIDs, ["intent-flash-partitions"])
    XCTAssertEqual(terminal.confirmedNotExecutedIntentEventIDs, [])
    XCTAssertEqual(terminal.completedIntentEventIDs, [])
  }

  func testHistoricalCampaignProvenanceAndTuningAreDecodeOnly() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var reservation = historicalCampaignReservation(jobID: "job-historical-campaign")
    reservation["campaignEvidenceProvenance"] = [
      "candidateDigestSHA256": String(repeating: "6", count: 64),
      "brokerDigestSHA256": String(repeating: "7", count: 64),
      "executionTuning": [
        "loaderDiscoveryTimeoutSeconds": 90,
        "loaderPollIntervalMilliseconds": 250,
        "hdcCommandTimeoutSeconds": 7,
        "readOnlyCommandTimeoutSeconds": 9,
      ],
    ]
    try writeLedger([reservation], to: directory)

    let provenance = try XCTUnwrap(
      AgentAuthorityUsageLedger(root: directory).load().reservations.first?
        .campaignEvidenceProvenance)
    XCTAssertEqual(provenance.candidateDigestSHA256, String(repeating: "6", count: 64))
    XCTAssertEqual(provenance.executionTuning?.loaderDiscoveryTimeoutSeconds, 90)
    XCTAssertNil(provenance.reviewDigestSHA256)
  }

  func testRecoveryCloseRetainsAtomicReplaceSemantics() throws {
    for point in AuthorizationUsageLedgerFaultPoint.allCases {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let reservation = historicalDeviceCapabilityReservation(jobID: "job-fault-\(point.rawValue)")
      try writeLedger([reservation], to: directory)
      let reservationID = try XCTUnwrap(reservation["reservationId"] as? String)
      let ledger = try AgentAuthorityUsageLedger(
        root: directory,
        faultInjector: AuthorizationUsageLedgerFaultInjector { observed in
          if observed == point { throw UsageTestFault.injected(point) }
        })
      let terminal = try AgentAuthorityUsageTerminal(
        status: .failed, closedAt: "2026-08-19T00:00:00Z",
        externalIntentEventIDs: ["intent-1"])
      XCTAssertThrowsError(try ledger.close(reservationID: reservationID, terminal: terminal))

      let recovered = try AgentAuthorityUsageLedger(root: directory).load()
      let persistedTerminal = try XCTUnwrap(recovered.reservations.first).terminal
      let replaceReached = point == .afterReplace || point == .beforeDirectorySync
      XCTAssertEqual(persistedTerminal != nil, replaceReached, "fault point: \(point)")
    }
  }

  func testClosedShapeAndNoNewReservationSurfaceArePinned() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reservation = historicalDeviceCapabilityReservation(jobID: "job-closed-shape")
    try writeLedger([reservation], to: directory, extraRoot: ["unexpected": true])
    XCTAssertThrowsError(try AgentAuthorityUsageLedger(root: directory).load())

    let sourceURL = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/ArkDeckStorage/AuthorizationUsageLedger.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertFalse(source.contains("public func reserve("))
    XCTAssertFalse(source.contains("public static func canonicalReservationID("))
    XCTAssertFalse(source.contains("public static func validatedStandingAuthorization("))
    XCTAssertFalse(source.contains("public static func validatedEvolutionCampaignConfirmation("))
    XCTAssertFalse(source.contains("public init(\n    candidateDigestSHA256:"))
  }

  private func historicalDeviceCapabilityReservation(jobID: String) -> [String: Any] {
    let capabilityID = "CAP-E1-HISTORICAL"
    let mainCommitOID = String(repeating: "3", count: 40)
    let capabilityBlobOID = String(repeating: "4", count: 40)
    let operationDigest = String(repeating: "7", count: 64)
    let targetDigest = String(repeating: "8", count: 64)
    let identity = [
      "deviceCapability", capabilityID, mainCommitOID, capabilityBlobOID, "750",
    ]
    return reservation(
      idPrefix: "ain010", identity: identity, jobID: jobID,
      operationDigest: operationDigest, targetDigest: targetDigest,
      authority: [
        "kind": "deviceCapability",
        "capabilityId": capabilityID,
        "mainCommitOID": mainCommitOID,
        "capabilityBlobOID": capabilityBlobOID,
        "approvalPRNumber": 750,
      ], maximumUses: 1)
  }

  private func historicalCampaignReservation(jobID: String) -> [String: Any] {
    let campaignDigest = String(repeating: "1", count: 64)
    let baseCommitOID = String(repeating: "a", count: 40)
    let planDigest = String(repeating: "2", count: 64)
    let archiveDigest = String(repeating: "3", count: 64)
    let stepSetDigest = String(repeating: "4", count: 64)
    let targetIdentity = String(repeating: "5", count: 64)
    let confirmedAt = "2026-08-04T00:00:00Z"
    let validUntil = "2026-08-04T03:00:00Z"
    let identity = [
      "evolutionCampaignConfirmation", campaignDigest, baseCommitOID, planDigest,
      archiveDigest, stepSetDigest, targetIdentity, "2", confirmedAt, validUntil, "16",
    ]
    return reservation(
      idPrefix: "ain019", identity: identity, jobID: jobID,
      operationDigest: planDigest, targetDigest: targetIdentity,
      authority: [
        "kind": "evolutionCampaignConfirmation",
        "campaignDigestSHA256": campaignDigest,
        "baseCommitOID": baseCommitOID,
        "planDigestSHA256": planDigest,
        "archiveDigestSHA256": archiveDigest,
        "stepSetDigestSHA256": stepSetDigest,
        "targetStableIdentitySHA256": targetIdentity,
        "bindingLineageRootRevision": 2,
        "confirmedAt": confirmedAt,
        "validUntil": validUntil,
        "maximumAttempts": 16,
      ], maximumUses: 16)
  }

  private func reservation(
    idPrefix: String,
    identity: [String],
    jobID: String,
    operationDigest: String,
    targetDigest: String,
    authority: [String: Any],
    maximumUses: Int
  ) -> [String: Any] {
    let digestInput = (identity + [jobID, operationDigest, targetDigest]).joined(separator: "|")
    let digest = SHA256Hex.string(of: Data(digestInput.utf8))
    return [
      "reservationId": "\(idPrefix)-\(digest.prefix(32))",
      "authorizationRef": authority,
      "ordinal": 1,
      "maximumUses": maximumUses,
      "maximumConcurrentJobs": 1,
      "jobId": jobID,
      "operationDigestSHA256": operationDigest,
      "targetDigestSHA256": targetDigest,
      "reservedAt": "2026-08-04T00:01:00Z",
      "forwardLeaseExpiresAt": "2026-08-04T00:01:30Z",
      "compensationLeaseExpiresAt": "2026-08-04T00:02:30Z",
      "terminal": NSNull(),
    ]
  }

  private func writeLedger(
    _ reservations: [[String: Any]],
    to directory: URL,
    extraRoot: [String: Any] = [:]
  ) throws {
    var document: [String: Any] = [
      "documentType": "agentAuthorityUsage",
      "schemaVersion": "1.0.0",
      "reservations": reservations,
    ]
    for (key, value) in extraRoot { document[key] = value }
    let url = directory.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-authorization-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }
}

private enum UsageTestFault: Error {
  case injected(AuthorizationUsageLedgerFaultPoint)
}
