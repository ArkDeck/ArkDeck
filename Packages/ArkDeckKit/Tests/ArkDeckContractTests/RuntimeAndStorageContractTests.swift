import ArkDeckRuntime
import ArkDeckStorage
import Foundation
import XCTest

final class RuntimeAndStorageContractTests: XCTestCase {
  func testSingleInstanceGuardBlocksSecondProcessWithoutSessionOrHDCWork() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockFile = directory.appending(path: "single-writer.lock")

    var primary: SingleInstanceGuard? = try SingleInstanceGuard.acquire(at: lockFile)
    XCTAssertNotNil(primary)
    // `flock` is intentionally checked from a second process: that is the
    // product boundary, and same-process descriptors are not contenders.
    XCTAssertEqual(try competingLockProcessStatus(lockFile: lockFile), 0)

    primary = nil
    let replacement = try SingleInstanceGuard.acquire(at: lockFile)
    XCTAssertNotNil(replacement)
  }

  func testSingleInstanceGuardFailsClosedForASymlinkedLockFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target.lock")
    let symlink = directory.appending(path: "single-writer.lock")
    XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

    XCTAssertThrowsError(try SingleInstanceGuard.acquire(at: symlink)) { error in
      guard case .lockUnavailable = error as? SingleInstanceGuardError else {
        return XCTFail("a symlinked lock must fail closed: \(error)")
      }
    }
  }

  func testPowerActivityLeasesReleaseAfterSuccessFailureAndCancellation() async throws {
    let backend = FakePowerActivityBackend()
    let controller = PowerActivityController(backend: backend)
    let firstLease = controller.acquire(reason: "first test lease")
    let secondLease = controller.acquire(reason: "second test lease")
    XCTAssertEqual(controller.activeLeaseCount, 2)
    XCTAssertEqual(backend.beginCount, 1)
    firstLease.end()
    XCTAssertEqual(backend.endCount, 0)
    secondLease.end()
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.endCount, 1)

    var abandonedLease: PowerActivityLease? = controller.acquire(reason: "abandoned test lease")
    XCTAssertEqual(backend.beginCount, 2)
    XCTAssertNotNil(abandonedLease)
    abandonedLease = nil
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.endCount, 2)

    let value = try controller.withActivity(reason: "success") { "complete" }
    XCTAssertEqual(value, "complete")
    XCTAssertEqual(backend.beginCount, 3)
    XCTAssertEqual(backend.endCount, 3)

    do {
      _ = try controller.withActivity(reason: "failure") { () throws -> Void in
        throw TestFailure.expected
      }
      XCTFail("the failing operation should escape its error")
    } catch TestFailure.expected {
      XCTAssertEqual(controller.activeLeaseCount, 0)
      XCTAssertEqual(backend.beginCount, 4)
      XCTAssertEqual(backend.endCount, 4)
    }

    let cancellationTask = Task { [controller] in
      try await controller.withActivity(reason: "cancellation") {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
      }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    cancellationTask.cancel()
    do {
      try await cancellationTask.value
      XCTFail("the cancelled operation should throw")
    } catch is CancellationError {
      XCTAssertEqual(controller.activeLeaseCount, 0)
      XCTAssertEqual(backend.beginCount, 5)
      XCTAssertEqual(backend.endCount, 5)
    }
  }

  /// Deliberately skipped unless a human starts it for the verification-plan
  /// observation described in the M0A evidence runbook.
  func testManualIdleSleepObservationHarness() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ARKDECK_POWER_OBSERVATION"] == "1" else {
      throw XCTSkip("Set ARKDECK_POWER_OBSERVATION=1 to run the manual power-observation harness")
    }
    let seconds = Int(environment["ARKDECK_POWER_OBSERVATION_SECONDS"] ?? "60") ?? 60
    guard (15...300).contains(seconds) else {
      XCTFail("ARKDECK_POWER_OBSERVATION_SECONDS must be between 15 and 300")
      return
    }

    let controller = PowerActivityController()
    let lease = controller.acquire(reason: "ArkDeck M0A manual power observation")
    defer { lease.end() }
    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-m0a-004-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func competingLockProcessStatus(lockFile: URL) throws -> Int32 {
    let perl = URL(fileURLWithPath: "/usr/bin/perl")
    guard FileManager.default.isExecutableFile(atPath: perl.path) else {
      throw XCTSkip("macOS Perl fixture is unavailable")
    }
    let process = Process()
    process.executableURL = perl
    process.arguments = [
      "-MFcntl=:flock",
      "-e",
      "open(my $fh, '>>', $ARGV[0]) or exit 2; flock($fh, LOCK_EX | LOCK_NB) ? exit 1 : exit 0;",
      lockFile.path,
    ]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}

private final class FakePowerActivityBackend: PowerActivityBackend {
  private let lock = NSLock()
  private(set) var beginCount = 0
  private(set) var endCount = 0

  func beginIdleSleepPrevention(reason _: String) -> AnyObject {
    lock.lock()
    beginCount += 1
    lock.unlock()
    return NSObject()
  }

  func endIdleSleepPrevention(_: AnyObject) {
    lock.lock()
    endCount += 1
    lock.unlock()
  }
}

private enum TestFailure: Error {
  case expected
}
