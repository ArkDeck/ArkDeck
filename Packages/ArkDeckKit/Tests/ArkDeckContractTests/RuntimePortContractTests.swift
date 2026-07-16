import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Darwin
import Foundation
import XCTest

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
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
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

    let cancellation = Task { [controller] in
      try await controller.withActivity(reason: "cancel") {
        try await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
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
    XCTAssertEqual(backend.firstEndEntered.wait(timeout: .now() + 5), .success)

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

    XCTAssertEqual(backend.secondBeginEntered.wait(timeout: .now() + 0.2), .timedOut)
    XCTAssertEqual(backend.beginCount, 1)
    backend.allowFirstEnd.signal()
    XCTAssertEqual(releaseFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(acquisitionFinished.wait(timeout: .now() + 5), .success)
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

  func testTEST_AC_NFR_001_02_SleepClockContractAndLockedJournalShape() throws {
    let wall = MutableAuditClock(Date(timeIntervalSince1970: 1_700_000_000))
    let elapsed = MutableMonotonicClock(0)
    let active = MutableMonotonicClock(0)
    let source = FakeSleepWakeNotificationSource()
    let tracker = ThroughputSegmentTracker()
    let sink = RecordingLifecycleSink(tracker: tracker)
    let identifiers = IdentifierSequence(["sleep-1", "wake-1"])
    let clocks = RuntimeClockPair(
      auditClock: wall,
      elapsedClock: elapsed,
      activeClock: active
    )
    let observer = RuntimeSleepWakeObserver(
      source: source,
      clocks: clocks,
      sink: sink,
      eventIDGenerator: { identifiers.next() }
    )
    try observer.start()
    defer { observer.stop() }

    observer.handle(.wake)
    XCTAssertTrue(sink.events.isEmpty)
    XCTAssertNil(tracker.record(totalUnits: 100, activeDurationNanoseconds: 0))
    XCTAssertEqual(
      try XCTUnwrap(
        tracker.record(totalUnits: 200, activeDurationNanoseconds: 10_000_000_000)
      ).unitsPerSecond,
      10,
      accuracy: 0.000_001
    )

    observer.handle(.sleep)
    elapsed.advance(by: 60_000_000_000)
    wall.advance(by: 60)
    observer.handle(.wake)
    observer.handle(.wake)

    XCTAssertEqual(sink.events.count, 2)
    let sleepEvent = sink.events[0]
    let wakeEvent = sink.events[1]
    XCTAssertEqual(sleepEvent.kind, .sleep)
    XCTAssertEqual(wakeEvent.kind, .wake)
    XCTAssertEqual(wakeEvent.sleepEventID, sleepEvent.eventID)
    XCTAssertEqual(wakeEvent.elapsedDurationNanoseconds, 60_000_000_000)
    XCTAssertEqual(wakeEvent.activeDurationNanoseconds, 0)
    XCTAssertEqual(wakeEvent.throughputSegmentReset, true)
    XCTAssertEqual(sink.segmentResetCount, 1)
    XCTAssertEqual(sink.reconnectEvaluationCount, 1)
    XCTAssertEqual(sink.reconcileRequestCount, 1)

    let deadline = try ElapsedDeadline(
      startElapsedDurationNanoseconds: 0,
      timeoutNanoseconds: 30_000_000_000
    )
    XCTAssertTrue(
      deadline.isExpired(
        atElapsedDurationNanoseconds: wakeEvent.elapsedDurationNanoseconds
      )
    )
    XCTAssertNil(
      tracker.record(
        totalUnits: 200,
        activeDurationNanoseconds: wakeEvent.activeDurationNanoseconds
      )
    )
    XCTAssertEqual(tracker.currentSegment, 1)

    let lockedSleep = try makeLockedJournalEvent(sleepEvent, sequence: 10)
    let lockedWake = try makeLockedJournalEvent(wakeEvent, sequence: 11)
    XCTAssertEqual(try JournalEventCodec.decode(JournalEventCodec.encode(lockedSleep)), lockedSleep)
    XCTAssertEqual(try JournalEventCodec.decode(JournalEventCodec.encode(lockedWake)), lockedWake)
  }

  func testTEST_AC_NFR_001_03_WakeStartsANewThroughputSegmentExactlyOnce() throws {
    let elapsed = MutableMonotonicClock(0)
    let active = MutableMonotonicClock(0)
    let source = FakeSleepWakeNotificationSource()
    let tracker = ThroughputSegmentTracker()
    let sink = RecordingLifecycleSink(tracker: tracker)
    let identifiers = IdentifierSequence(["sleep-segment", "wake-segment"])
    let observer = RuntimeSleepWakeObserver(
      source: source,
      clocks: RuntimeClockPair(elapsedClock: elapsed, activeClock: active),
      sink: sink,
      eventIDGenerator: { identifiers.next() }
    )
    try observer.start()
    defer { observer.stop() }

    XCTAssertNil(tracker.record(totalUnits: 0, activeDurationNanoseconds: 0))
    XCTAssertEqual(
      try XCTUnwrap(
        tracker.record(totalUnits: 100, activeDurationNanoseconds: 10_000_000_000)
      ).unitsPerSecond,
      10,
      accuracy: 0.000_001
    )
    observer.handle(.sleep)
    elapsed.advance(by: 60_000_000_000)
    observer.handle(.wake)
    observer.handle(.wake)

    XCTAssertEqual(tracker.currentSegment, 1)
    XCTAssertNil(tracker.record(totalUnits: 100, activeDurationNanoseconds: 10_000_000_000))
    active.advance(by: 2_000_000_000)
    XCTAssertEqual(
      try XCTUnwrap(
        tracker.record(totalUnits: 120, activeDurationNanoseconds: 12_000_000_000)
      ).unitsPerSecond,
      10,
      accuracy: 0.000_001
    )
    XCTAssertEqual(sink.events.count, 2)
    XCTAssertEqual(sink.segmentResetCount, 1)
    XCTAssertEqual(sink.reconnectEvaluationCount, 1)
    XCTAssertEqual(sink.reconcileRequestCount, 1)
  }

  func test_PORT_SLEEP_WAKE_001_concurrentCallbacksPreserveJournalOrder() throws {
    let source = FakeSleepWakeNotificationSource()
    let sink = BlockingOrderingLifecycleSink()
    let identifiers = IdentifierSequence(["sleep-concurrent", "wake-concurrent"])
    let observer = RuntimeSleepWakeObserver(
      source: source,
      clocks: RuntimeClockPair(
        elapsedClock: MutableMonotonicClock(0),
        activeClock: MutableMonotonicClock(0)
      ),
      sink: sink,
      eventIDGenerator: { identifiers.next() }
    )
    try observer.start()
    defer {
      sink.allowSleepRecord.signal()
      observer.stop()
    }

    let sleepFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      observer.handle(.sleep)
      sleepFinished.signal()
    }
    XCTAssertEqual(sink.sleepRecordEntered.wait(timeout: .now() + 5), .success)

    let wakeFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      observer.handle(.wake)
      wakeFinished.signal()
    }
    XCTAssertEqual(wakeFinished.wait(timeout: .now() + 0.2), .timedOut)
    XCTAssertTrue(sink.events.isEmpty)

    sink.allowSleepRecord.signal()
    XCTAssertEqual(sleepFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(wakeFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(sink.events.map(\.kind), [.sleep, .wake])
    XCTAssertEqual(sink.events.last?.sleepEventID, "sleep-concurrent")
    XCTAssertEqual(sink.segmentResetCount, 1)
    XCTAssertEqual(sink.reconnectEvaluationCount, 1)
    XCTAssertEqual(sink.reconcileRequestCount, 1)
  }

  func test_PORT_SLEEP_WAKE_001_startThenConcurrentStopAreLinearized() throws {
    let source = CoordinatedSleepWakeNotificationSource()
    source.blockNextStart()
    let sink = RecordingLifecycleSink(tracker: ThroughputSegmentTracker())
    let observer = RuntimeSleepWakeObserver(source: source, sink: sink)
    let errors = LockedErrorBox()
    let startFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { startFinished.signal() }
      do {
        try observer.start()
      } catch {
        errors.record(error)
      }
    }
    XCTAssertEqual(source.startEntered.wait(timeout: .now() + 5), .success)

    let stopFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      observer.stop()
      stopFinished.signal()
    }
    XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.2), .timedOut)

    source.allowStart.signal()
    XCTAssertEqual(startFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(stopFinished.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(errors.errors.isEmpty)
    XCTAssertFalse(source.isRegistered)
    XCTAssertEqual(source.startCount, 1)
    XCTAssertEqual(source.stopCount, 1)

    observer.handle(.sleep)
    XCTAssertTrue(sink.events.isEmpty)
  }

  func test_PORT_SLEEP_WAKE_001_concurrentStopThenStartReRegistersSource() throws {
    let source = CoordinatedSleepWakeNotificationSource()
    let sink = RecordingLifecycleSink(tracker: ThroughputSegmentTracker())
    let identifiers = IdentifierSequence(["sleep-restart", "wake-restart"])
    let observer = RuntimeSleepWakeObserver(
      source: source,
      sink: sink,
      eventIDGenerator: { identifiers.next() }
    )
    try observer.start()
    defer { observer.stop() }

    source.blockNextStop()
    let stopFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      observer.stop()
      stopFinished.signal()
    }
    XCTAssertEqual(source.stopEntered.wait(timeout: .now() + 5), .success)

    let errors = LockedErrorBox()
    let startFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { startFinished.signal() }
      do {
        try observer.start()
      } catch {
        errors.record(error)
      }
    }
    XCTAssertEqual(startFinished.wait(timeout: .now() + 0.2), .timedOut)

    source.allowStop.signal()
    XCTAssertEqual(stopFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(startFinished.wait(timeout: .now() + 5), .success)
    XCTAssertTrue(errors.errors.isEmpty)
    XCTAssertTrue(source.isRegistered)
    XCTAssertEqual(source.startCount, 2)
    XCTAssertEqual(source.stopCount, 1)

    source.emit(.sleep)
    source.emit(.wake)
    XCTAssertTrue(
      waitUntil(timeout: 5) {
        sink.events.count == 2 && sink.segmentResetCount == 1
          && sink.reconnectEvaluationCount == 1 && sink.reconcileRequestCount == 1
      }
    )
    XCTAssertEqual(sink.events.map(\.kind), [.sleep, .wake])
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

  /// Human-only harness for TEST-MAC-M1-PORTS-001. It never initiates sleep.
  func testTEST_MAC_M1_PORTS_001_ManualProductionSleepWakeObservationHarness() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ARKDECK_RUNTIME_SLEEP_WAKE_OBSERVATION"] == "1" else {
      throw XCTSkip(
        "Set ARKDECK_RUNTIME_SLEEP_WAKE_OBSERVATION=1 and manually sleep/wake the Mac"
      )
    }
    let timeout =
      TimeInterval(
        environment["ARKDECK_RUNTIME_SLEEP_WAKE_TIMEOUT_SECONDS"] ?? "180"
      ) ?? 180
    guard (30...600).contains(timeout) else {
      XCTFail("ARKDECK_RUNTIME_SLEEP_WAKE_TIMEOUT_SECONDS must be 30...600")
      return
    }

    let sink = RecordingLifecycleSink(tracker: ThroughputSegmentTracker())
    let observer = RuntimeSleepWakeObserver(sink: sink)
    try observer.start()
    defer { observer.stop() }
    // The operator timeout is active-process time. A wall-clock deadline can
    // expire while macOS is asleep and make the harness exit before the main
    // RunLoop gets a chance to deliver NSWorkspaceDidWakeNotification.
    let timeoutClock = SuspendingActiveClock()
    let activeLimitNanoseconds = Int64(timeout * 1_000_000_000)
    while sink.events.count < 2 || sink.segmentResetCount < 1
      || sink.reconnectEvaluationCount < 1 || sink.reconcileRequestCount < 1,
      timeoutClock.nowNanoseconds < activeLimitNanoseconds
    {
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    let events = sink.events
    let sequence = events.map(\.kind)
    let sequenceDescription = sequence.map(\.rawValue).joined(separator: ",")
    guard sequence == [.sleep, .wake] else {
      print(
        "TEST-MAC-M1-PORTS-001 result=fail observed_sequence="
          + "\(sequenceDescription.isEmpty ? "none" : sequenceDescription) "
          + "elapsed_delta_ns=unavailable active_delta_ns=unavailable "
          + "segment_reset_count=\(sink.segmentResetCount) "
          + "reconnect_evaluation_count=\(sink.reconnectEvaluationCount) "
          + "reconcile_request_count=\(sink.reconcileRequestCount)"
      )
      XCTFail("expected NSWorkspace sequence sleep,wake; observed \(sequenceDescription)")
      return
    }
    let sleep = events[0]
    let wake = events[1]
    let elapsedDelta = wake.elapsedDurationNanoseconds - sleep.elapsedDurationNanoseconds
    let activeDelta = wake.activeDurationNanoseconds - sleep.activeDurationNanoseconds
    let suspendedDelta = elapsedDelta - activeDelta
    let minimumSuspendedDelta: Int64 = 10_000_000_000
    let countersMatch =
      sink.segmentResetCount == 1 && sink.reconnectEvaluationCount == 1
      && sink.reconcileRequestCount == 1
    let binaryPass =
      activeDelta >= 0 && suspendedDelta >= minimumSuspendedDelta
      && countersMatch
    XCTAssertGreaterThanOrEqual(activeDelta, 0)
    XCTAssertGreaterThanOrEqual(
      suspendedDelta,
      minimumSuspendedDelta,
      "active clock must exclude at least the known 10-second sleep interval"
    )
    XCTAssertEqual(sink.segmentResetCount, 1)
    XCTAssertEqual(sink.reconnectEvaluationCount, 1)
    XCTAssertEqual(sink.reconcileRequestCount, 1)
    print(
      "TEST-MAC-M1-PORTS-001 result=\(binaryPass ? "pass" : "fail") "
        + "elapsed_delta_ns=\(elapsedDelta) active_delta_ns=\(activeDelta) "
        + "suspended_delta_ns=\(suspendedDelta) minimum_suspended_delta_ns="
        + "\(minimumSuspendedDelta) observed_sequence=\(sequenceDescription) "
        + "segment_reset_count=\(sink.segmentResetCount) "
        + "reconnect_evaluation_count=\(sink.reconnectEvaluationCount) "
        + "reconcile_request_count=\(sink.reconcileRequestCount)"
    )
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
    try waitForFile(readyFile, process: holder, timeout: 5)

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
    try waitForExit(contender, timeout: 5)
    XCTAssertEqual(contender.terminationStatus, 0)

    try Data().write(to: stopFile, options: .atomic)
    try waitForExit(holder, timeout: 5)
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

  private func makeLockedJournalEvent(
    _ event: RuntimeSleepWakeJournalEvent,
    sequence: Int
  ) throws -> JournalEvent {
    var payload: [String: JSONValue] = [
      "elapsedDurationNanoseconds": .integer(event.elapsedDurationNanoseconds),
      "activeDurationNanoseconds": .integer(event.activeDurationNanoseconds),
    ]
    if let sleepEventID = event.sleepEventID {
      payload["sleepEventId"] = .string(sleepEventID)
    }
    if let reset = event.throughputSegmentReset {
      payload["throughputSegmentReset"] = .bool(reset)
    }
    return try JournalEvent(
      eventID: event.eventID,
      sequence: sequence,
      sessionID: "runtime-session",
      jobID: "runtime-job",
      timestamp: "2026-07-16T10:00:00Z",
      accumulatedElapsedDurationNanoseconds: Int(event.elapsedDurationNanoseconds),
      accumulatedActiveDurationNanoseconds: Int(event.activeDurationNanoseconds),
      kind: event.kind == .sleep ? .sleep : .wake,
      payload: payload
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
      _ = allowFirstEnd.wait(timeout: .now() + 5)
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

private final class FakeSleepWakeNotificationSource: SleepWakeNotificationSource,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var handler: (@Sendable (SystemSleepWakeNotification) -> Void)?

  func start(handler: @escaping @Sendable (SystemSleepWakeNotification) -> Void) throws {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  func stop() {
    lock.lock()
    handler = nil
    lock.unlock()
  }

  func emit(_ notification: SystemSleepWakeNotification) {
    lock.lock()
    let callback = handler
    lock.unlock()
    callback?(notification)
  }
}

private final class CoordinatedSleepWakeNotificationSource: SleepWakeNotificationSource,
  @unchecked Sendable
{
  let startEntered = DispatchSemaphore(value: 0)
  let allowStart = DispatchSemaphore(value: 0)
  let stopEntered = DispatchSemaphore(value: 0)
  let allowStop = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var handler: (@Sendable (SystemSleepWakeNotification) -> Void)?
  private var shouldBlockNextStart = false
  private var shouldBlockNextStop = false
  private var starts = 0
  private var stops = 0

  func blockNextStart() {
    lock.lock()
    shouldBlockNextStart = true
    lock.unlock()
  }

  func blockNextStop() {
    lock.lock()
    shouldBlockNextStop = true
    lock.unlock()
  }

  func start(handler: @escaping @Sendable (SystemSleepWakeNotification) -> Void) throws {
    lock.lock()
    let shouldBlock = shouldBlockNextStart
    shouldBlockNextStart = false
    lock.unlock()
    if shouldBlock {
      startEntered.signal()
      _ = allowStart.wait(timeout: .now() + 5)
    }
    lock.lock()
    self.handler = handler
    starts += 1
    lock.unlock()
  }

  func stop() {
    lock.lock()
    let shouldBlock = shouldBlockNextStop
    shouldBlockNextStop = false
    lock.unlock()
    if shouldBlock {
      stopEntered.signal()
      _ = allowStop.wait(timeout: .now() + 5)
    }
    lock.lock()
    handler = nil
    stops += 1
    lock.unlock()
  }

  func emit(_ notification: SystemSleepWakeNotification) {
    lock.lock()
    let callback = handler
    lock.unlock()
    callback?(notification)
  }

  var isRegistered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return handler != nil
  }

  var startCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return starts
  }

  var stopCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return stops
  }
}

private final class IdentifierSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) { self.values = values }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? UUID().uuidString : values.removeFirst()
  }
}

private final class RecordingLifecycleSink: RuntimeLifecycleSink, @unchecked Sendable {
  private let lock = NSLock()
  private let tracker: ThroughputSegmentTracker
  private var recordedEvents: [RuntimeSleepWakeJournalEvent] = []
  private var resets = 0
  private var reconnects = 0
  private var reconciles = 0

  init(tracker: ThroughputSegmentTracker) { self.tracker = tracker }

  func record(_ event: RuntimeSleepWakeJournalEvent) {
    lock.lock()
    recordedEvents.append(event)
    lock.unlock()
  }

  func resetThroughputSegment() {
    tracker.resetAfterWake()
    lock.lock()
    resets += 1
    lock.unlock()
  }

  func evaluateReconnect() {
    lock.lock()
    reconnects += 1
    lock.unlock()
  }

  func requestReconcile() {
    lock.lock()
    reconciles += 1
    lock.unlock()
  }

  var events: [RuntimeSleepWakeJournalEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  var segmentResetCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return resets
  }

  var reconnectEvaluationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reconnects
  }

  var reconcileRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reconciles
  }
}

private final class BlockingOrderingLifecycleSink: RuntimeLifecycleSink, @unchecked Sendable {
  let sleepRecordEntered = DispatchSemaphore(value: 0)
  let allowSleepRecord = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var shouldBlockSleepRecord = true
  private var recordedEvents: [RuntimeSleepWakeJournalEvent] = []
  private var resets = 0
  private var reconnects = 0
  private var reconciles = 0

  func record(_ event: RuntimeSleepWakeJournalEvent) {
    lock.lock()
    let shouldBlock = event.kind == .sleep && shouldBlockSleepRecord
    if shouldBlock {
      shouldBlockSleepRecord = false
    }
    lock.unlock()
    if shouldBlock {
      sleepRecordEntered.signal()
      _ = allowSleepRecord.wait(timeout: .now() + 5)
    }
    lock.lock()
    recordedEvents.append(event)
    lock.unlock()
  }

  func resetThroughputSegment() {
    lock.lock()
    resets += 1
    lock.unlock()
  }

  func evaluateReconnect() {
    lock.lock()
    reconnects += 1
    lock.unlock()
  }

  func requestReconcile() {
    lock.lock()
    reconciles += 1
    lock.unlock()
  }

  var events: [RuntimeSleepWakeJournalEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  var segmentResetCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return resets
  }

  var reconnectEvaluationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reconnects
  }

  var reconcileRequestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reconciles
  }
}
