import ArkDeckCore
@testable import ArkDeckHarness
import ArkDeckRuntime
import ArkDeckStorage
import Darwin
import Foundation
import XCTest

/// Anti-hang bound for the rendezvous waits in this file — semaphores handed
/// to a background thread, polls for an asynchronously delivered event, and
/// waits on a real fixture subprocess. It is not a contract bound: the
/// assertions around each wait decide the outcome, and an expired wait reports
/// only that the host never got there.
///
/// The five seconds this replaced sat inside the noise of a saturated
/// `swift test --parallel --num-workers 4` run. `testTEST_AC_JOB_008_01_
/// PlatformInstanceContract` was measured taking 34.007 s under that load and
/// still timing out (recorded in `flake-storage-rendezvous-2026-08-03.md`);
/// this is set far above that and still fails a genuine deadlock well inside
/// one test.
///
/// Negative waits — the `.now() + 0.2` ones asserting a caller is *still*
/// blocked — deliberately do not use this. Host load only reinforces those, so
/// widening them would just make the suite slower.
private let runtimePortRendezvousTimeout: TimeInterval = 60

/// Wait for `semaphore` without blocking a cooperative-pool thread: the block
/// happens on a Dispatch worker while the calling task suspends.
private func waitForSemaphore(
  _ semaphore: DispatchSemaphore, timeout: TimeInterval
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
    }
  }
}

/// Park a fixture double until the test opens its gate.
///
/// The four gates in this file used to discard the wait result
/// (`_ = allow….wait(timeout: .now() + 5)`), which made an expired gate
/// *silently stop blocking*: the double resumed on its own, the serialization
/// the test was pinning quietly did not hold, and the failure surfaced as a
/// baffling `beginCount`/`events` mismatch far from the real cause. An expired
/// gate is now reported as itself.
private func awaitFixtureGate(
  _ semaphore: DispatchSemaphore,
  _ label: String,
  timeout: TimeInterval = runtimePortRendezvousTimeout,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard semaphore.wait(timeout: .now() + timeout) == .success else {
    return XCTFail(
      "fixture gate \(label) expired after \(timeout)s; the double stopped "
        + "blocking on its own, so any assertion after this point is measuring the scaffold, "
        + "not the contract",
      file: file, line: line)
  }
}

final class RuntimePortContractTests: XCTestCase {
  func testTEST_AC_JOB_008_01_PlatformInstanceContract() throws {
    let success = try runTwoProcessVector(activationProductMatches: true)
    XCTAssertEqual(
      success.holder.writerInitializationCount + success.contender.writerInitializationCount,
      1
    )
    XCTAssertEqual(success.holder.activationCount, 1)
    assertWriterInitializationProbes(success.holder)
    XCTAssertEqual(success.contender.admission, "secondary")
    XCTAssertEqual(success.contender.activationDelivery, ActivationDelivery.activated.rawValue)
    assertNoSecondarySideEffects(success.contender)

    let failedDelivery = try runTwoProcessVector(activationProductMatches: false)
    XCTAssertEqual(
      failedDelivery.holder.writerInitializationCount
        + failedDelivery.contender.writerInitializationCount,
      1
    )
    XCTAssertEqual(failedDelivery.holder.activationCount, 0)
    assertWriterInitializationProbes(failedDelivery.holder)
    XCTAssertEqual(failedDelivery.contender.admission, "secondary")
    XCTAssertEqual(
      failedDelivery.contender.activationDelivery,
      ActivationDelivery.unavailable.rawValue
    )
    assertNoSecondarySideEffects(failedDelivery.contender)
  }

  func testTEST_AC_JOB_008_01_LockUncertaintyFailsClosedWithoutActivationOrWriters() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let activationCounter = LockedCounter()
    let writerInitializationCounter = LockedCounter()
    let sender = CountingActivationSender(counter: activationCounter, delivery: .activated)

    let target = directory.appending(path: "target.lock")
    let symlink = directory.appending(path: "symlink.lock")
    XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    assertReadOnly(
      RuntimeInstanceCoordinator(lockFile: symlink, activationSender: sender).admit(
        initializingWriterResources: writerInitializationCounter.increment
      )
    )

    let permissionDirectory = directory.appending(path: "permission", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: permissionDirectory, withIntermediateDirectories: true)
    XCTAssertEqual(Darwin.chmod(permissionDirectory.path, 0o500), 0)
    defer { _ = Darwin.chmod(permissionDirectory.path, 0o700) }
    assertReadOnly(
      RuntimeInstanceCoordinator(
        lockFile: permissionDirectory.appending(path: "single-writer.lock"),
        activationSender: sender
      ).admit(initializingWriterResources: writerInitializationCounter.increment)
    )

    assertReadOnly(
      RuntimeInstanceCoordinator(
        lockFile: directory.appending(path: "unreliable.lock"),
        guardAcquirer: FailingGuardAcquirer(error: .unreliableFilesystem),
        activationSender: sender
      ).admit(initializingWriterResources: writerInitializationCounter.increment)
    )
    XCTAssertEqual(activationCounter.value, 0)
    XCTAssertEqual(writerInitializationCounter.value, 0)
  }

  func test_PORT_ACTIVATION_001_matchingBoundedRequestsAreDeduplicated() throws {
    let successCounter = LockedCounter()
    let successListener = MacOSActivationListener(
      productIdentifier: "dev.arkdeck.activation-contract",
      userIdentifier: "501",
      deduplicationBitCount: 64
    ) {
      successCounter.increment()
      return true
    }
    let matching = try JSONEncoder().encode(
      ActivationRequest(
        requestID: "request-1",
        productIdentifier: "dev.arkdeck.activation-contract",
        userIdentifier: "501"
      )
    )
    XCTAssertEqual(successListener.receive(matching), .activated)
    XCTAssertEqual(successListener.receive(matching), .duplicate)
    XCTAssertEqual(successCounter.value, 1)

    let mismatch = try JSONEncoder().encode(
      ActivationRequest(
        requestID: "request-2",
        productIdentifier: "another-product",
        userIdentifier: "501"
      )
    )
    XCTAssertEqual(successListener.receive(mismatch), .rejected)
    XCTAssertEqual(successListener.receive(Data(repeating: 0x41, count: 4_097)), .rejected)
    XCTAssertEqual(successCounter.value, 1)
    XCTAssertEqual(
      MacOSActivationRequestSender(
        productIdentifier: String(repeating: "a", count: 5_000),
        userIdentifier: "501"
      ).requestActivation(),
      .requestTooLarge
    )

    let failureCounter = LockedCounter()
    let failureListener = MacOSActivationListener(
      productIdentifier: "dev.arkdeck.activation-contract",
      userIdentifier: "501"
    ) {
      failureCounter.increment()
      return false
    }
    XCTAssertEqual(failureListener.receive(matching), .activationFailed)
    XCTAssertEqual(failureListener.receive(matching), .duplicate)
    XCTAssertEqual(failureCounter.value, 1)
  }

  func test_PORT_POWER_001_balancesConcurrentNestedAndAllTerminalPaths() async throws {
    let backend = FakePowerActivityBackend()
    let controller = PowerActivityController(backend: backend)
    let leaseBox = PowerLeaseBox()
    let group = DispatchGroup()
    for index in 0..<16 {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        do {
          leaseBox.append(try controller.acquire(reason: "concurrent-\(index)"))
        } catch {
          leaseBox.record(error)
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + runtimePortRendezvousTimeout), .success)
    XCTAssertTrue(leaseBox.errors.isEmpty)
    XCTAssertEqual(controller.activeLeaseCount, 16)
    XCTAssertEqual(backend.beginCount, 1)
    XCTAssertEqual(backend.endCount, 0)
    leaseBox.endAll()
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.endCount, 1)

    let value = try controller.withActivity(reason: "success") { "complete" }
    XCTAssertEqual(value, "complete")
    do {
      _ = try controller.withActivity(reason: "throw") { () throws -> Void in
        throw RuntimePortTestError.expected
      }
      XCTFail("throw must escape")
    } catch RuntimePortTestError.expected {}

    // This was the one real wall-clock bet in the file: sleep 50 ms, then hope
    // `cancel()` lands before a 5 s sleep finishes on its own. A host stall
    // longer than the inner sleep let the activity complete normally and the
    // test failed at "cancelled activity must throw" — the cancellation path
    // was never exercised. Now the activity says when it is running, and only
    // cancellation ends it; the sleep bound is the anti-hang backstop, so a
    // cancel that fails to land fails the test instead of hanging forever.
    let activityEntered = DispatchSemaphore(value: 0)
    let cancellation = Task { [controller] in
      try await controller.withActivity(reason: "cancel") {
        activityEntered.signal()
        try await Task.sleep(
          nanoseconds: UInt64(runtimePortRendezvousTimeout) * 1_000_000_000)
      }
    }
    let entered = await waitForSemaphore(
      activityEntered, timeout: runtimePortRendezvousTimeout)
    XCTAssertEqual(entered, .success, "the cancellable activity must start before it is cancelled")
    cancellation.cancel()
    do {
      try await cancellation.value
      XCTFail("cancelled activity must throw")
    } catch is CancellationError {}
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.beginCount, 4)
    XCTAssertEqual(backend.endCount, 4)

    var abandoned: PowerActivityLease? = try controller.acquire(reason: "lease deinit")
    XCTAssertEqual(backend.beginCount, 5)
    XCTAssertNotNil(abandoned)
    abandoned = nil
    XCTAssertNil(abandoned)
    XCTAssertEqual(backend.endCount, 5)

    backend.failNextBegin = true
    XCTAssertThrowsError(try controller.acquire(reason: "backend failure"))
    XCTAssertEqual(controller.activeLeaseCount, 0)
    XCTAssertEqual(backend.beginAttemptCount, 6)
    XCTAssertEqual(backend.beginCount, 5)
    XCTAssertEqual(backend.endCount, 5)

    let teardownBackend = FakePowerActivityBackend()
    var teardownController: PowerActivityController? = PowerActivityController(
      backend: teardownBackend
    )
    let teardownLease = try XCTUnwrap(teardownController).acquire(reason: "teardown")
    teardownController = nil
    XCTAssertEqual(teardownBackend.beginCount, 1)
    XCTAssertEqual(teardownBackend.endCount, 1)
    teardownLease.end()
    XCTAssertEqual(teardownBackend.endCount, 1)
  }

  func test_PORT_POWER_001_lastReleaseSerializesUnderlyingActivityTransition() throws {
    let backend = BlockingEndPowerActivityBackend()
    let controller = PowerActivityController(backend: backend)
    let firstLease = try controller.acquire(reason: "first")
    let releaseFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      firstLease.end()
      releaseFinished.signal()
    }
    XCTAssertEqual(
      backend.firstEndEntered.wait(timeout: .now() + runtimePortRendezvousTimeout),
      .success)

    let secondLeaseBox = PowerLeaseBox()
    let acquisitionFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { acquisitionFinished.signal() }
      do {
        secondLeaseBox.append(try controller.acquire(reason: "second"))
      } catch {
        secondLeaseBox.record(error)
      }
    }

    // Short on purpose, and deliberately not the anti-hang bound: this asserts
    // the second begin is still parked behind the in-progress end. Host load
    // can only keep it parked longer, so widening this would only slow the test.
    XCTAssertEqual(backend.secondBeginEntered.wait(timeout: .now() + 0.2), .timedOut)
    XCTAssertEqual(backend.beginCount, 1)
    backend.allowFirstEnd.signal()
    XCTAssertEqual(releaseFinished.wait(timeout: .now() + runtimePortRendezvousTimeout), .success)
    XCTAssertEqual(
      acquisitionFinished.wait(timeout: .now() + runtimePortRendezvousTimeout),
      .success)
    XCTAssertTrue(secondLeaseBox.errors.isEmpty)
    XCTAssertEqual(backend.beginCount, 2)
    XCTAssertEqual(backend.endCount, 1)
    XCTAssertEqual(backend.maximumSimultaneousActivityCount, 1)

    secondLeaseBox.endAll()
    XCTAssertEqual(backend.endCount, 2)
    XCTAssertEqual(backend.maximumSimultaneousActivityCount, 1)
  }

  func testTEST_AC_NFR_001_01_ClockContractIgnoresWallClockJumps() throws {
    let wall = MutableAuditClock(Date(timeIntervalSince1970: 1_700_000_000))
    let elapsed = MutableMonotonicClock(1_000)
    let active = MutableMonotonicClock(2_000)
    let clocks = RuntimeClockPair(
      auditClock: wall,
      elapsedClock: elapsed,
      activeClock: active
    )
    elapsed.advance(by: 20_000_000_000)
    active.advance(by: 12_000_000_000)
    let control = try clocks.sample()
    let deadline = try ElapsedDeadline(
      startElapsedDurationNanoseconds: 0,
      timeoutNanoseconds: 30_000_000_000
    )

    wall.set(Date(timeIntervalSince1970: 4_000_000_000))
    let forwardJump = try clocks.sample()
    wall.set(Date(timeIntervalSince1970: 100))
    let backwardJump = try clocks.sample()

    for sample in [forwardJump, backwardJump] {
      XCTAssertEqual(sample.elapsedDurationNanoseconds, control.elapsedDurationNanoseconds)
      XCTAssertEqual(sample.activeDurationNanoseconds, control.activeDurationNanoseconds)
      XCTAssertEqual(
        deadline.isExpired(atElapsedDurationNanoseconds: sample.elapsedDurationNanoseconds),
        deadline.isExpired(atElapsedDurationNanoseconds: control.elapsedDurationNanoseconds)
      )
    }
  }

  func testTEST_AC_NFR_001_04_RestartClockFaultInjectionFailsSafeWithoutOldTicks() throws {
    let checkpointUTC = Date(timeIntervalSince1970: 1_700_000_000)
    let deadlineUTC = checkpointUTC.addingTimeInterval(120)
    let snapshot = try RestartSafeTimingSnapshot(
      accumulatedElapsedDurationNanoseconds: 20_000_000_000,
      accumulatedActiveDurationNanoseconds: 10_000_000_000,
      configuredOverallTimeoutNanoseconds: 120_000_000_000,
      configuredDeadlineUTC: deadlineUTC,
      snapshotUTC: checkpointUTC
    )
    let fields = Mirror(reflecting: snapshot).children.compactMap(\.label)
    XCTAssertEqual(
      Set(fields),
      [
        "accumulatedElapsedDurationNanoseconds",
        "accumulatedActiveDurationNanoseconds",
        "configuredOverallTimeoutNanoseconds",
        "configuredDeadlineUTC",
        "snapshotUTC",
      ]
    )
    XCTAssertEqual(
      RestartDeadlineEvaluator.evaluate(
        snapshot: snapshot,
        currentUTC: checkpointUTC.addingTimeInterval(10)
      ),
      .notExpired(remainingNanoseconds: 90_000_000_000)
    )
    XCTAssertEqual(
      RestartDeadlineEvaluator.evaluate(
        snapshot: snapshot,
        currentUTC: checkpointUTC.addingTimeInterval(-1)
      ),
      .expired(.wallClockRollback)
    )
    XCTAssertEqual(
      RestartDeadlineEvaluator.evaluate(
        snapshot: snapshot,
        currentUTC: checkpointUTC.addingTimeInterval(121)
      ),
      .expired(.deadlineReached)
    )
    XCTAssertEqual(
      RestartDeadlineEvaluator.evaluate(
        snapshot: nil,
        currentUTC: checkpointUTC
      ),
      .expired(.invalidOrMissingEvidence)
    )
    XCTAssertThrowsError(
      try RestartSafeTimingSnapshot(
        accumulatedElapsedDurationNanoseconds: -1,
        accumulatedActiveDurationNanoseconds: 0,
        configuredOverallTimeoutNanoseconds: 1,
        configuredDeadlineUTC: nil,
        snapshotUTC: checkpointUTC
      )
    )
    let oldTick = CountingMonotonicClock()
    _ = RestartDeadlineEvaluator.evaluate(snapshot: snapshot, currentUTC: deadlineUTC)
    XCTAssertEqual(oldTick.readCount, 0)
  }

  private func runTwoProcessVector(activationProductMatches: Bool) throws -> TwoProcessVector {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try runtimeFixtureExecutable()
    let product = "dev.arkdeck.runtime-fixture.\(UUID().uuidString)"
    let lockFile = directory.appending(path: "single-writer.lock")
    let readyFile = directory.appending(path: "ready")
    let stopFile = directory.appending(path: "stop")
    let holderResultFile = directory.appending(path: "holder.json")
    let contenderResultFile = directory.appending(path: "contender.json")

    let holder = Process()
    holder.executableURL = fixture
    holder.arguments = [
      "holder",
      lockFile.path,
      readyFile.path,
      stopFile.path,
      holderResultFile.path,
      product,
    ]
    try holder.run()
    defer {
      if holder.isRunning { holder.terminate() }
    }
    try waitForFile(readyFile, process: holder, timeout: runtimePortRendezvousTimeout)

    let contender = Process()
    contender.executableURL = fixture
    contender.arguments = [
      "contender",
      lockFile.path,
      contenderResultFile.path,
      activationProductMatches ? product : "\(product).missing",
      "request-1",
    ]
    try contender.run()
    try waitForExit(contender, timeout: runtimePortRendezvousTimeout)
    XCTAssertEqual(contender.terminationStatus, 0)

    try Data().write(to: stopFile, options: .atomic)
    try waitForExit(holder, timeout: runtimePortRendezvousTimeout)
    XCTAssertEqual(holder.terminationStatus, 0)

    let decoder = JSONDecoder()
    return TwoProcessVector(
      holder: try decoder.decode(FixtureResult.self, from: Data(contentsOf: holderResultFile)),
      contender: try decoder.decode(
        FixtureResult.self,
        from: Data(contentsOf: contenderResultFile)
      )
    )
  }

  private func assertReadOnly(
    _ admission: RuntimeInstanceAdmission,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .readOnlyDiagnostics = admission else {
      XCTFail("uncertain lock must fail closed", file: file, line: line)
      return
    }
  }

  private func assertNoSecondarySideEffects(
    _ result: FixtureResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(result.writerInitializationCount, 0, file: file, line: line)
    XCTAssertEqual(result.jobInitializationProbeCount, 0, file: file, line: line)
    XCTAssertEqual(result.hdcInitializationProbeCount, 0, file: file, line: line)
    XCTAssertEqual(result.sessionWriterInitializationProbeCount, 0, file: file, line: line)
  }

  private func assertWriterInitializationProbes(
    _ result: FixtureResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(result.writerInitializationCount, 1, file: file, line: line)
    XCTAssertEqual(result.jobInitializationProbeCount, 1, file: file, line: line)
    XCTAssertEqual(result.hdcInitializationProbeCount, 1, file: file, line: line)
    XCTAssertEqual(result.sessionWriterInitializationProbeCount, 1, file: file, line: line)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .appending(path: "arkdeck-m1-004-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func runtimeFixtureExecutable() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidate = packageRoot.appending(path: ".build/debug/ArkDeckRuntimePortFixture")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      throw RuntimePortTestError.fixtureUnavailable(candidate.path)
    }
    return candidate
  }

  private func waitForFile(_ url: URL, process: Process, timeout: TimeInterval) throws {
    let limit = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path), Date() < limit {
      guard process.isRunning else {
        throw RuntimePortTestError.fixtureExited(process.terminationStatus)
      }
      usleep(10_000)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw RuntimePortTestError.fixtureTimeout
    }
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval) throws {
    let limit = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < limit {
      usleep(10_000)
    }
    guard !process.isRunning else {
      process.terminate()
      throw RuntimePortTestError.fixtureTimeout
    }
    process.waitUntilExit()
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
  ) -> Bool {
    let limit = Date().addingTimeInterval(timeout)
    while !condition(), Date() < limit {
      usleep(10_000)
    }
    return condition()
  }
}

private struct FixtureResult: Codable {
  let role: String
  let admission: String
  let activationDelivery: String?
  let writerInitializationCount: Int
  let activationCount: Int
  let jobInitializationProbeCount: Int
  let hdcInitializationProbeCount: Int
  let sessionWriterInitializationProbeCount: Int
}

private struct TwoProcessVector {
  let holder: FixtureResult
  let contender: FixtureResult
}

private enum RuntimePortTestError: Error {
  case expected
  case fixtureUnavailable(String)
  case fixtureExited(Int32)
  case fixtureTimeout
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class LockedErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedErrors: [Error] = []

  func record(_ error: Error) {
    lock.lock()
    recordedErrors.append(error)
    lock.unlock()
  }

  var errors: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return recordedErrors
  }
}

private struct CountingActivationSender: ActivationRequestSending {
  let counter: LockedCounter
  let delivery: ActivationDelivery

  func requestActivation() -> ActivationDelivery {
    counter.increment()
    return delivery
  }
}

private struct FailingGuardAcquirer: SingleInstanceGuardAcquiring {
  let error: SingleInstanceGuardError

  func acquire(at _: URL) throws -> SingleInstanceGuard {
    throw error
  }
}

private final class FakePowerActivityBackend: PowerActivityBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var beginAttempts = 0
  private var begins = 0
  private var ends = 0
  var failNextBegin = false

  func beginIdleSleepPrevention(reason _: String) throws -> AnyObject {
    lock.lock()
    beginAttempts += 1
    let shouldFail = failNextBegin
    failNextBegin = false
    if !shouldFail { begins += 1 }
    lock.unlock()
    if shouldFail { throw RuntimePortTestError.expected }
    return NSObject()
  }

  func endIdleSleepPrevention(_: AnyObject) {
    lock.lock()
    ends += 1
    lock.unlock()
  }

  var beginCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return begins
  }

  var beginAttemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return beginAttempts
  }

  var endCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return ends
  }
}

private final class BlockingEndPowerActivityBackend: PowerActivityBackend, @unchecked Sendable {
  let firstEndEntered = DispatchSemaphore(value: 0)
  let allowFirstEnd = DispatchSemaphore(value: 0)
  let secondBeginEntered = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var begins = 0
  private var ends = 0
  private var activeActivities = 0
  private var maximumActiveActivities = 0
  private var hasBlockedEnd = false

  func beginIdleSleepPrevention(reason _: String) throws -> AnyObject {
    lock.lock()
    begins += 1
    activeActivities += 1
    maximumActiveActivities = max(maximumActiveActivities, activeActivities)
    let isSecondBegin = begins == 2
    lock.unlock()
    if isSecondBegin {
      secondBeginEntered.signal()
    }
    return NSObject()
  }

  func endIdleSleepPrevention(_: AnyObject) {
    lock.lock()
    let shouldBlock = !hasBlockedEnd
    hasBlockedEnd = true
    lock.unlock()
    if shouldBlock {
      firstEndEntered.signal()
      awaitFixtureGate(allowFirstEnd, "allowFirstEnd")
    }
    lock.lock()
    ends += 1
    activeActivities -= 1
    lock.unlock()
  }

  var beginCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return begins
  }

  var endCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return ends
  }

  var maximumSimultaneousActivityCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumActiveActivities
  }
}

private final class PowerLeaseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var leases: [PowerActivityLease] = []
  private var recordedErrors: [Error] = []

  func append(_ lease: PowerActivityLease) {
    lock.lock()
    leases.append(lease)
    lock.unlock()
  }

  func record(_ error: Error) {
    lock.lock()
    recordedErrors.append(error)
    lock.unlock()
  }

  var errors: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return recordedErrors
  }

  func endAll() {
    lock.lock()
    let current = leases
    leases = []
    lock.unlock()
    for lease in current {
      lease.end()
    }
  }
}

private final class MutableAuditClock: AuditClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }

  var nowUTC: Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ date: Date) {
    lock.lock()
    value = date
    lock.unlock()
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }
}

private final class MutableMonotonicClock: MonotonicRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64

  init(_ value: Int64) { self.value = value }

  var nowNanoseconds: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by nanoseconds: Int64) {
    lock.lock()
    value += nanoseconds
    lock.unlock()
  }
}

private final class CountingMonotonicClock: MonotonicRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0

  var nowNanoseconds: Int64 {
    lock.lock()
    reads += 1
    lock.unlock()
    return 0
  }

  var readCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }
}
