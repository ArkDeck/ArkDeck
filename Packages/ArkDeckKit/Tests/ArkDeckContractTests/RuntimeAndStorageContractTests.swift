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

    func testFailedDurableIntentPreventsDispatchAndRecoveryFindsIncompleteIntent() throws {
        let intent = try makeIntent(eventID: "intent-1", sequence: 1)
        var externalDispatches = 0
        let gate = WriteAheadIntentGate(journal: FailingJournal())
        XCTAssertThrowsError(try gate.dispatch(intent: intent) {
            externalDispatches += 1
        }) { error in
            XCTAssertEqual(error as? DurableJournalError, .intentNotDurable)
        }
        XCTAssertEqual(externalDispatches, 0)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appending(path: "journal.jsonl")
        let journal = try FileDurableJournal(url: journalURL)
        try journal.appendAndSynchronize(intent)

        var report = try DurableJournalRecovery.inspect(url: journalURL)
        XCTAssertEqual(report.incompleteIntentEventIDs, ["intent-1"])
        XCTAssertTrue(report.requiresRecovery)

        let outcome = try DurableJournalEvent.stepOutcome(
            eventID: "outcome-1",
            sequence: 2,
            sessionID: "session-1",
            jobID: "job-1",
            timestamp: "2026-07-15T00:00:01Z",
            stepID: "step-1",
            attempt: 1,
            correlatesToIntentEventID: "intent-1",
            result: .succeeded,
            outcomeCertainty: .confirmed
        )
        try journal.appendAndSynchronize(outcome)
        report = try DurableJournalRecovery.inspect(url: journalURL)
        XCTAssertFalse(report.requiresRecovery)

        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\"".utf8))
        try handle.synchronize()
        report = try DurableJournalRecovery.inspect(url: journalURL)
        XCTAssertTrue(report.hasTornTail)
    }

    func testDurableIntentUsesTheLockedJournalContractShape() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appending(path: "journal.jsonl")
        let journal = try FileDurableJournal(url: journalURL)
        try journal.appendAndSynchronize(try makeIntent(eventID: "intent-contract", sequence: 0))

        let line = try XCTUnwrap(String(data: Data(contentsOf: journalURL), encoding: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schemaVersion", "eventId", "sequence", "sessionId", "jobId", "timestamp", "kind",
                "stepId", "attempt", "bindingRevision", "argumentsHash", "payload",
            ])
        )
        XCTAssertEqual(object["eventId"] as? String, "intent-contract")
        XCTAssertEqual(object["sessionId"] as? String, "session-1")
        XCTAssertEqual(object["jobId"] as? String, "job-1")
        XCTAssertEqual(object["stepId"] as? String, "step-1")
        XCTAssertTrue(object["bindingRevision"] is NSNull)
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["step", "target"]))
        let target = try XCTUnwrap(payload["target"] as? [String: Any])
        XCTAssertEqual(target["scope"] as? String, "host")
        XCTAssertTrue(target["connectKey"] is NSNull)
        XCTAssertTrue(target["identitySnapshotHash"] is NSNull)
        let step = try XCTUnwrap(payload["step"] as? [String: Any])
        XCTAssertEqual(
            Set(step.keys),
            Set(["id", "kind", "effect", "cancellation", "bindingRequirement", "arguments", "compensationDescriptors"])
        )
        XCTAssertEqual(step["kind"] as? String, "probeHostTool")
        XCTAssertTrue((step["compensationDescriptors"] as? [Any])?.isEmpty == true)
    }

    func testCheckpointPublicationReplacesThePriorSnapshotAtomically() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AtomicJournalCheckpointStore(url: directory.appending(path: "checkpoint.json"))
        let first = JournalCheckpoint(
            sessionID: "session-1",
            jobID: "job-1",
            journalSequence: 1,
            state: "running",
            updatedAt: "2026-07-15T00:00:00Z"
        )
        let second = JournalCheckpoint(
            sessionID: "session-1",
            jobID: "job-1",
            journalSequence: 2,
            state: "succeeded",
            updatedAt: "2026-07-15T00:00:01Z"
        )

        try store.save(first)
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
    }

    func testOutcomeIsDurableBeforeCheckpointPublication() throws {
        let order = EventOrder()
        let journal = OrderingJournal(order: order)
        let checkpointStore = OrderingCheckpointStore(order: order)
        let gate = DurableOutcomeCheckpointGate(journal: journal, checkpointStore: checkpointStore)
        let outcome = try DurableJournalEvent.stepOutcome(
            eventID: "outcome-1",
            sequence: 2,
            sessionID: "session-1",
            jobID: "job-1",
            timestamp: "2026-07-15T00:00:01Z",
            stepID: "step-1",
            attempt: 1,
            correlatesToIntentEventID: "intent-1",
            result: .succeeded,
            outcomeCertainty: .confirmed
        )
        let checkpoint = JournalCheckpoint(
            sessionID: "session-1",
            jobID: "job-1",
            journalSequence: 2,
            state: "succeeded",
            updatedAt: "2026-07-15T00:00:01Z"
        )

        try gate.record(outcome: outcome, checkpoint: checkpoint)
        XCTAssertEqual(order.events, ["journal", "checkpoint"])
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
        guard (15 ... 300).contains(seconds) else {
            XCTFail("ARKDECK_POWER_OBSERVATION_SECONDS must be between 15 and 300")
            return
        }

        let controller = PowerActivityController()
        let lease = controller.acquire(reason: "ArkDeck M0A manual power observation")
        defer { lease.end() }
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "arkdeck-m0a-004-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeIntent(eventID: String, sequence: Int) throws -> DurableJournalEvent {
        try DurableJournalEvent.stepIntent(
            eventID: eventID,
            sequence: sequence,
            sessionID: "session-1",
            jobID: "job-1",
            timestamp: "2026-07-15T00:00:00Z",
            step: DurableStepDescriptor(
                id: "step-1",
                probeHostTool: DurableProbeHostToolArguments(
                    toolIdentity: "hdc",
                    candidatePath: "/opt/DevEco/hdc"
                )
            ),
            target: DurableJournalTarget(scope: .host, targetID: "host-1"),
            attempt: 1,
            bindingRevision: nil,
            argumentsHash: String(repeating: "a", count: 64)
        )
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

private final class FailingJournal: DurableJournalAppending, @unchecked Sendable {
    func appendAndSynchronize(_: DurableJournalEvent) throws {
        throw TestFailure.expected
    }
}

private final class EventOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class OrderingJournal: DurableJournalAppending, @unchecked Sendable {
    private let order: EventOrder

    init(order: EventOrder) {
        self.order = order
    }

    func appendAndSynchronize(_: DurableJournalEvent) throws {
        order.append("journal")
    }
}

private final class OrderingCheckpointStore: JournalCheckpointSaving, @unchecked Sendable {
    private let order: EventOrder

    init(order: EventOrder) {
        self.order = order
    }

    func save(_: JournalCheckpoint) throws {
        order.append("checkpoint")
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
