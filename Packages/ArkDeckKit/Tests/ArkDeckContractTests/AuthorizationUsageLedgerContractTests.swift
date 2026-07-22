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
