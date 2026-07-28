import ArkDeckStorage
import Darwin
import Foundation
import XCTest

final class AuthorizationUsageLedgerContractTests: XCTestCase {
  func testReserveIsDurableIdempotentBoundedAndNeverRefunded() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try AuthorizationUsageLedger(root: directory)
    let first = try reservation(id: "reservation-1", ordinal: 1, maxRuns: 2)

    XCTAssertEqual(try ledger.reserve(first), first)
    XCTAssertEqual(try ledger.reserve(first), first)
    XCTAssertEqual(try ledger.load().reservations, [first])

    let driftedRetry = try AuthorizationUsageReservation(
      reservationID: first.reservationID, authorizationRef: first.authorizationRef,
      ordinal: first.ordinal, maxRuns: first.maxRuns, jobID: "job-drifted",
      planDigestSHA256: first.planDigestSHA256,
      targetDigestSHA256: first.targetDigestSHA256,
      reservedAt: first.reservedAt)
    XCTAssertThrowsError(try ledger.reserve(driftedRetry))

    let terminal = try AuthorizationUsageTerminal(
      status: .failed, closedAt: "2026-07-22T01:00:00Z",
      destructiveIntentEventIDs: ["intent-1"])
    XCTAssertEqual(
      try ledger.close(reservationID: first.reservationID, terminal: terminal).terminal,
      terminal)
    XCTAssertEqual(
      try ledger.close(reservationID: first.reservationID, terminal: terminal).terminal,
      terminal)
    XCTAssertThrowsError(
      try ledger.close(
        reservationID: first.reservationID,
        terminal: AuthorizationUsageTerminal(
          status: .succeeded, closedAt: "2026-07-22T01:00:00Z",
          destructiveIntentEventIDs: ["intent-1"])))

    _ = try ledger.reserve(reservation(id: "reservation-2", ordinal: 2, maxRuns: 2))
    XCTAssertThrowsError(
      try ledger.reserve(reservation(id: "reservation-3", ordinal: 3, maxRuns: 2)))
    XCTAssertEqual(try ledger.load().reservations.count, 2)
    print("TEST-AIN-CONTRACT-001 usage-idempotency-limit=PASS device_dispatch=0")
  }

  func testHostWideLockSerializesConcurrentRetryAndSingleRemainingOrdinal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seed = try AuthorizationUsageLedger(root: directory)
    _ = try seed.reserve(reservation(id: "reservation-1", ordinal: 1, maxRuns: 2))

    let identical = try reservation(id: "reservation-1", ordinal: 1, maxRuns: 2)
    let retryResults = ConcurrentResults()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do {
        _ = try AuthorizationUsageLedger(root: directory).reserve(identical)
        retryResults.recordSuccess()
      } catch {
        retryResults.record(error)
      }
    }
    XCTAssertEqual(retryResults.successes, 16)
    XCTAssertTrue(retryResults.errors.isEmpty)

    let contenders = ConcurrentResults()
    let contenderRequests = try (0..<16).map { index in
      try reservation(id: "reservation-contender-\(index)", ordinal: 2, maxRuns: 2)
    }
    DispatchQueue.concurrentPerform(iterations: 16) { index in
      do {
        _ = try AuthorizationUsageLedger(root: directory).reserve(
          contenderRequests[index])
        contenders.recordSuccess()
      } catch {
        contenders.record(error)
      }
    }
    XCTAssertEqual(contenders.successes, 1)
    XCTAssertEqual(try seed.load().reservations.count, 2)
  }

  func testCrashWindowsConsumeOnlyAtAtomicReplaceAndRetryDoesNotDoubleReserve() throws {
    for point in [
      AuthorizationUsageLedgerFaultPoint.beforeTemporaryWrite,
      .afterFileSync,
      .afterReplace,
      .beforeDirectorySync,
    ] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let ledger = try AuthorizationUsageLedger(
        root: directory,
        faultInjector: AuthorizationUsageLedgerFaultInjector { observed in
          if observed == point { throw UsageTestFault.injected(point) }
        })
      let request = try reservation(id: "reservation-1", ordinal: 1, maxRuns: 1)
      XCTAssertThrowsError(try ledger.reserve(request))

      let recovered = try AuthorizationUsageLedger(root: directory)
      let countAfterFault = try recovered.load().reservations.count
      if point == .beforeTemporaryWrite || point == .afterFileSync {
        XCTAssertEqual(countAfterFault, 0)
      } else {
        XCTAssertEqual(countAfterFault, 1)
      }
      XCTAssertEqual(try recovered.reserve(request), request)
      XCTAssertEqual(try recovered.load().reservations.count, 1)
    }
  }

  func testLedgerRejectsSymlinkHardlinkUnknownFieldsAndPathSubstitution() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    let ledgerPath = directory.appending(path: AuthorizationUsageLedger.ledgerFileName)
    try FileManager.default.createSymbolicLink(at: ledgerPath, withDestinationURL: target)
    let ledger = try AuthorizationUsageLedger(root: directory)
    XCTAssertThrowsError(try ledger.load())
    try FileManager.default.removeItem(at: ledgerPath)

    let stable = try AuthorizationUsageLedger(root: directory)
    _ = try stable.reserve(reservation(id: "reservation-1", ordinal: 1, maxRuns: 1))
    let hardlink = directory.appending(path: "usage-hardlink.json")
    XCTAssertEqual(link(ledgerPath.path, hardlink.path), 0)
    XCTAssertThrowsError(try stable.load())
    try FileManager.default.removeItem(at: hardlink)

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerPath)) as? [String: Any])
    object["unexpected"] = true
    try JSONSerialization.data(withJSONObject: object).write(to: ledgerPath)
    XCTAssertThrowsError(try stable.load())

    try FileManager.default.removeItem(at: ledgerPath)
    try FileManager.default.createSymbolicLink(at: ledgerPath, withDestinationURL: target)
    XCTAssertThrowsError(
      try stable.reserve(reservation(id: "reservation-2", ordinal: 2, maxRuns: 2)))
  }

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
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: AuthorizationUsageLedger.ledgerFileName).path))
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

  private func reservation(
    id: String,
    ordinal: Int,
    maxRuns: Int
  ) throws -> AuthorizationUsageReservation {
    try AuthorizationUsageReservation(
      reservationID: id, authorizationRef: authorizationReference(), ordinal: ordinal,
      maxRuns: maxRuns, jobID: "job-\(ordinal)",
      planDigestSHA256: String(repeating: "d", count: 64),
      targetDigestSHA256: String(repeating: "e", count: 64),
      reservedAt: "2026-07-22T00:00:0\(min(ordinal, 9))Z")
  }

  private func authorizationReference() throws -> AuthorizationReference {
    try AuthorizationReference(
      authorizationID: "authorization-1", mainCommitOID: String(repeating: "a", count: 40),
      authorizationBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 299)
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
