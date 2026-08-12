import ArkDeckCore
@testable import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Dispatch
import Foundation
import XCTest

final class JournalRecoveryContractTests: XCTestCase {
  /// Real durable append benchmarks for the writer cursor at 100, 1,000, and
  /// 10,000 historical events.  Every event uses the production file-sync and
  /// directory-sync path; only the final append and an explicit recovery are
  /// timed, so the assertion detects accidental full-history replays on the
  /// hot path without treating a fast disk as correctness.
  func testIncrementalJournalCursorScalesPastTenThousandDurableEvents() throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUN_LONG_JOURNAL_TESTS"] == "1" else {
      throw XCTSkip("set ARKDECK_RUN_LONG_JOURNAL_TESTS=1 to run the 10,000-event journal benchmark")
    }
    for historicalEventCount in [100, 1_000, 10_000] {
      let measurement = try measureCursorBenchmark(historicalEventCount: historicalEventCount)
      XCTAssertLessThan(
        measurement.durableAppendNanoseconds, UInt64(1_000_000_000),
        "the hot append path must validate its cursor, not replay \(historicalEventCount) records")
      XCTAssertLessThan(
        measurement.recoveryNanoseconds, UInt64(5_000_000_000),
        "a \(historicalEventCount)-event journal must remain recoverable within the restart budget")
      XCTAssertFalse(
        measurement.usedFullReplay,
        "the cursor benchmark must take the validated incremental append path")
      XCTAssertLessThan(
        measurement.validationBytesRead, 4_096,
        "the hot append path must read only its validated tail, not \(historicalEventCount) records")
      print(
        "ARKDECK_JOURNAL_CURSOR historicalEvents=\(measurement.historicalEventCount) "
          + "totalEvents=\(measurement.totalEventCount) "
          + "durableAppendNanoseconds=\(measurement.durableAppendNanoseconds) "
          + "validationBytesRead=\(measurement.validationBytesRead) "
          + "fileSyncNanoseconds=\(measurement.fileSyncNanoseconds) "
          + "directorySyncNanoseconds=\(measurement.directorySyncNanoseconds) "
          + "journalBytes=\(measurement.journalBytes) "
          + "recoveryNanoseconds=\(measurement.recoveryNanoseconds) "
          + "peakResidentSetBytes=\(measurement.peakResidentSetBytes)")
    }
  }

  private struct CursorBenchmarkMeasurement {
    let historicalEventCount: Int
    let totalEventCount: Int
    let durableAppendNanoseconds: UInt64
    let validationBytesRead: Int
    let usedFullReplay: Bool
    let fileSyncNanoseconds: UInt64
    let directorySyncNanoseconds: UInt64
    let journalBytes: UInt64
    let recoveryNanoseconds: UInt64
    let peakResidentSetBytes: Int64
  }

  private final class JournalAppendMeasurementCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var latestMeasurement: JournalAppendMeasurement?

    func record(_ measurement: JournalAppendMeasurement) {
      lock.lock()
      latestMeasurement = measurement
      lock.unlock()
    }

    func latest() -> JournalAppendMeasurement? {
      lock.lock()
      defer { lock.unlock() }
      return latestMeasurement
    }
  }

  private func measureCursorBenchmark(
    historicalEventCount: Int
  ) throws -> CursorBenchmarkMeasurement {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appending(path: "incremental-cursor.jsonl")
    let collector = JournalAppendMeasurementCollector()
    let journal = try FileDurableJournal(
      url: journalURL,
      appendMeasurementSink: { collector.record($0) })
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "created", sequence: 0, sessionID: "cursor-session", jobID: "cursor-job",
        timestamp: timestamp, executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "preflight", sequence: 1, sessionID: "cursor-session", jobID: "cursor-job",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "cursor benchmark"))
    for sequence in 2...(historicalEventCount + 1) {
      try journal.appendAndSynchronize(try cursorBenchmarkWarning(sequence: sequence))
    }

    let finalSequence = historicalEventCount + 2
    let appendStarted = DispatchTime.now().uptimeNanoseconds
    try journal.appendAndSynchronize(try cursorBenchmarkWarning(sequence: finalSequence))
    let durableAppendNanoseconds = DispatchTime.now().uptimeNanoseconds - appendStarted
    let appendMeasurement = try XCTUnwrap(collector.latest())
    let journalBytes = try XCTUnwrap(
      (try FileManager.default.attributesOfItem(atPath: journalURL.path)[.size] as? NSNumber)?
        .uint64Value)

    let recoveryStarted = DispatchTime.now().uptimeNanoseconds
    let recovery = try DurableJournalRecovery.inspect(url: journalURL)
    let recoveryNanoseconds = DispatchTime.now().uptimeNanoseconds - recoveryStarted
    XCTAssertEqual(recovery.events.count, historicalEventCount + 3)
    XCTAssertEqual(recovery.lastDurableSequence, finalSequence)
    return CursorBenchmarkMeasurement(
      historicalEventCount: historicalEventCount,
      totalEventCount: recovery.events.count,
      durableAppendNanoseconds: durableAppendNanoseconds,
      validationBytesRead: appendMeasurement.validationBytesRead,
      usedFullReplay: appendMeasurement.usedFullReplay,
      fileSyncNanoseconds: appendMeasurement.fileSyncNanoseconds,
      directorySyncNanoseconds: appendMeasurement.directorySyncNanoseconds,
      journalBytes: journalBytes,
      recoveryNanoseconds: recoveryNanoseconds,
      peakResidentSetBytes: processPeakResidentSetBytes())
  }

  private func processPeakResidentSetBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
  }

  private func cursorBenchmarkWarning(sequence: Int) throws -> JournalEvent {
    try JournalEvent(
      eventID: "warning-\(sequence)", sequence: sequence,
      sessionID: "cursor-session", jobID: "cursor-job", timestamp: timestamp,
      kind: .warning,
      payload: [
        "code": .string("cursorBenchmark"),
        "message": .string("incremental durable append"),
        "details": .object(["sequence": .integer(Int64(sequence))]),
      ])
  }

  func testAgentAuthorityV22RoundTripsE0E1E2AndRejectsUsageDrift() throws {
    let references: [(AgentExecutionAuthorityReference, String?, WorkflowEffect)] = [
      (
        try .validatedReadyTask(
          changeID: "CHG-2026-025", taskID: "TASK-AIN-010",
          mainCommitOID: String(repeating: "a", count: 40),
          taskBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 754),
        nil, .readOnly
      ),
      (
        try .validatedDeviceCapability(
          capabilityID: "CAP-E1-FIXTURE",
          mainCommitOID: String(repeating: "c", count: 40),
          capabilityBlobOID: String(repeating: "d", count: 40), approvalPRNumber: 750),
        "ain010-fixture", .deviceMutation
      ),
      (
        try .validatedStandingAuthorization(
          authorizationID: "AUTH-FIXTURE",
          mainCommitOID: String(repeating: "e", count: 40),
          authorizationBlobOID: String(repeating: "f", count: 40), approvalPRNumber: 700),
        "reservation-fixture", .destructive
      ),
      (
        try historicalChatAuthority(
          confirmationDigestSHA256: String(repeating: "1", count: 64),
          planDigestSHA256: String(repeating: "2", count: 64),
          archiveDigestSHA256: String(repeating: "3", count: 64),
          stepSetDigestSHA256: String(repeating: "4", count: 64),
          targetDigestSHA256: String(repeating: "5", count: 64),
          confirmedAt: timestamp),
        "chat-reservation-fixture", .destructive
      ),
    ]
    for (offset, item) in references.enumerated() {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let journalURL = directory.appending(path: "agent-v22-\(offset).jsonl")
      let journal = try FileDurableJournal(url: journalURL)
      try journal.appendAndSynchronize(
        JournalEvent.jobCreated(
          eventID: "created-\(offset)", sequence: 0, sessionID: "session-\(offset)",
          jobID: "job-\(offset)", timestamp: timestamp, executionMode: "execute",
          executionAuthority: "authorizedAgent",
          schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
          agentAuthorizationRef: item.0, usageReservationID: item.1))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "preflight-\(offset)", sequence: 1, sessionID: "session-\(offset)",
          jobID: "job-\(offset)", timestamp: timestamp, from: .queued, to: .preflight,
          reason: "fixture", schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "running-\(offset)", sequence: 2, sessionID: "session-\(offset)",
          jobID: "job-\(offset)", timestamp: timestamp, from: .preflight, to: .running,
          reason: "fixture", schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
      let step = try agentAuthorityStep(effect: item.2, suffix: "\(offset)")
      try journal.appendAndSynchronize(
        JournalEvent.stepIntent(
          eventID: "intent-\(offset)", sequence: 3, sessionID: "session-\(offset)",
          jobID: "job-\(offset)", timestamp: timestamp, step: step,
          target: JournalTarget(
            scope: "device", targetID: "target-\(offset)", connectKey: "fixture",
            identitySnapshotHash: String(repeating: "1", count: 64)),
          attempt: 1, bindingRevision: 1,
          schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
          agentAuthorizationRef: item.0, usageReservationID: item.1))
      try journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(offset)", sequence: 4, sessionID: "session-\(offset)",
          jobID: "job-\(offset)", timestamp: timestamp, stepID: step.id, attempt: 1,
          correlatesToIntentEventID: "intent-\(offset)", result: "succeeded",
          outcomeCertainty: .confirmed,
          schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
          agentAuthorizationRef: item.0, usageReservationID: item.1))
      let replay = try DurableJournalRecovery.inspect(url: journalURL)
      XCTAssertEqual(replay.schemaVersion, JournalEvent.agentAuthoritySchemaVersion)
      XCTAssertEqual(replay.agentExecutionAuthorityReference, item.0)
      XCTAssertEqual(replay.authorizationReference, item.0.legacyStandingAuthorizationReference)
      XCTAssertEqual(replay.usageReservationID, item.1)
      XCTAssertTrue(replay.outstandingIntents.isEmpty)
    }

    let e0 = references[0].0
    XCTAssertThrowsError(
      try JournalEvent.jobCreated(
        eventID: "bad-e0", sequence: 0, sessionID: "bad-session", jobID: "bad-job",
        timestamp: timestamp, executionMode: "execute",
        executionAuthority: "authorizedAgent",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: e0, usageReservationID: "ghost-usage"))
    let e1 = references[1].0
    XCTAssertThrowsError(
      try JournalEvent.jobCreated(
        eventID: "bad-e1", sequence: 0, sessionID: "bad-session", jobID: "bad-job",
        timestamp: timestamp, executionMode: "execute",
        executionAuthority: "authorizedAgent",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: e1))
  }

  func testAgentAuthorityV22CorrelatesExternalCompensationRefAndUsage() throws {
    let reference = try AgentExecutionAuthorityReference.validatedDeviceCapability(
      capabilityID: "CAP-E1-COMPENSATION",
      mainCommitOID: String(repeating: "a", count: 40),
      capabilityBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 750)
    let arguments: [String: JSONValue] = [
      "captureStepId": .string("capture-1"),
      "stopPolicy": .string("gracefulThenForce"),
    ]
    let descriptor = try CompensationDescriptor(
      id: "stop-capture", kind: .stopRemoteCapture,
      declaredEffect: .deviceMutation, declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .confirmedDevice, trigger: .onFailure,
      arguments: arguments,
      argumentsHash: try JournalCanonicalJSON.argumentsHash(arguments))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "agent-v22-compensation.jsonl")
    let journal = try FileDurableJournal(url: url)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "created", sequence: 0, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, executionMode: "execute",
        executionAuthority: "authorizedAgent",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: reference, usageReservationID: "ain010-compensation"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "running", sequence: 2, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .preflight, to: .running, reason: "fixture",
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion))
    try journal.appendAndSynchronize(
      JournalEvent.compensationIntent(
        eventID: "compensation-intent", sequence: 3, sessionID: "session-1",
        jobID: "job-1", timestamp: timestamp, compensationOfStepID: "capture-1",
        descriptor: descriptor,
        target: JournalTarget(
          scope: "device", targetID: "target-1", connectKey: "fixture",
          identitySnapshotHash: String(repeating: "1", count: 64)),
        attempt: 1, bindingRevision: 1,
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: reference, usageReservationID: "ain010-compensation"))
    try journal.appendAndSynchronize(
      JournalEvent.compensationOutcome(
        eventID: "compensation-outcome", sequence: 4, sessionID: "session-1",
        jobID: "job-1", timestamp: timestamp, compensationOfStepID: "capture-1",
        descriptorID: descriptor.id, attempt: 1,
        correlatesToIntentEventID: "compensation-intent", result: "succeeded",
        outcomeCertainty: .confirmed,
        schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
        agentAuthorizationRef: reference, usageReservationID: "ain010-compensation"))
    let replay = try DurableJournalRecovery.inspect(url: url)
    XCTAssertTrue(replay.outstandingIntents.isEmpty)
    XCTAssertEqual(replay.agentExecutionAuthorityReference, reference)
  }

  func testAuthorizedAgentV2JournalRoundTripsAndCorrelatesDestructiveIntentOutcome() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reference = try authorizationReference()
    let journalURL = directory.appending(path: "authorized-v2.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    let created = try JournalEvent.jobCreated(
      eventID: "job-created", sequence: 0, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, executionMode: "execute", executionAuthority: "authorizedAgent",
      schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
      authorizationRef: reference, usageReservationID: "reservation-1")
    XCTAssertEqual(try JournalEventCodec.decode(JournalEventCodec.encode(created)), created)
    try journal.appendAndSynchronize(created)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "v2-preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "v2-running", sequence: 2, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .preflight, to: .running, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    try journal.appendAndSynchronize(
      makeFlashIntent(
        sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
        authorizationRef: reference, usageReservationID: "reservation-1"))
    try journal.appendAndSynchronize(
      makeOutcome(
        sequence: 4, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
        authorizationRef: reference, usageReservationID: "reservation-1"))

    let replay = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertEqual(replay.schemaVersion, "2.0.0")
    XCTAssertEqual(replay.executionAuthority, "authorizedAgent")
    XCTAssertEqual(replay.authorizationReference, reference)
    XCTAssertEqual(replay.usageReservationID, "reservation-1")
    XCTAssertTrue(replay.outstandingIntents.isEmpty)
    print("TEST-AIN-CONTRACT-001 journal-v2=PASS device_dispatch=0 external_process=0")
  }

  func testAuthorizedAgentV2JournalRejectsMissingDriftGhostAndMixedVersionCorrelation() throws {
    let reference = try authorizationReference()
    let drifted = try AuthorizationReference(
      authorizationID: "authorization-2", mainCommitOID: String(repeating: "a", count: 40),
      authorizationBlobOID: String(repeating: "c", count: 40), approvalPRNumber: 299)

    func seededJournal(_ suffix: String) throws -> FileDurableJournal {
      let directory = try temporaryDirectory()
      let journal = try FileDurableJournal(
        url: directory.appending(path: "authorized-\(suffix).jsonl"))
      try journal.appendAndSynchronize(
        JournalEvent.jobCreated(
          eventID: "job-created", sequence: 0, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, executionMode: "execute", executionAuthority: "authorizedAgent",
          schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
          authorizationRef: reference, usageReservationID: "reservation-1"))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture",
          schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "running", sequence: 2, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, from: .preflight, to: .running, reason: "fixture",
          schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
      return journal
    }

    let missing = try seededJournal("missing")
    XCTAssertThrowsError(
      try missing.appendAndSynchronize(
        makeFlashIntent(
          sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion)))

    let drift = try seededJournal("drift")
    XCTAssertThrowsError(
      try drift.appendAndSynchronize(
        makeFlashIntent(
          sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
          authorizationRef: drifted, usageReservationID: "reservation-1")))

    let mixed = try seededJournal("mixed")
    XCTAssertThrowsError(
      try mixed.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "mixed", sequence: 3, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, from: .running, to: .waitingForRecovery,
          reason: "forged v1")))

    let outcomeDrift = try seededJournal("outcome-drift")
    try outcomeDrift.appendAndSynchronize(
      makeFlashIntent(
        sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
        authorizationRef: reference, usageReservationID: "reservation-1"))
    XCTAssertThrowsError(
      try outcomeDrift.appendAndSynchronize(
        makeOutcome(
          sequence: 4, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
          authorizationRef: drifted, usageReservationID: "reservation-1")))

    let standard = try FileDurableJournal(
      url: try temporaryDirectory().appending(path: "standard-v2.jsonl"))
    try standard.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, executionMode: "execute", executionAuthority: "standardAgent",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    try standard.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    try standard.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "running", sequence: 2, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .preflight, to: .running, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    XCTAssertThrowsError(
      try standard.appendAndSynchronize(
        makeFlashIntent(
          sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion)))

    let simulated = try FileDurableJournal(
      url: try temporaryDirectory().appending(path: "simulated-v2.jsonl"))
    try simulated.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, executionMode: "simulated", executionAuthority: "authorizedAgent",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
        authorizationRef: reference, usageReservationID: "reservation-1"))
    try simulated.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    try simulated.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "running", sequence: 2, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .preflight, to: .running, reason: "fixture",
        schemaVersion: JournalEvent.authorizedAgentSchemaVersion))
    XCTAssertThrowsError(
      try simulated.appendAndSynchronize(
        makeFlashIntent(
          sequence: 3, schemaVersion: JournalEvent.authorizedAgentSchemaVersion,
          authorizationRef: reference, usageReservationID: "reservation-1")))
  }

  func testLockedJournalContractCoversEveryClosedEventKind() throws {
    let data = try JournalRecoveryFixtures.data(named: "all-event-kinds.jsonl")
    let lines = data.split(separator: 0x0A)
    let events = try lines.map { try JournalEventCodec.decode(Data($0)) }
    XCTAssertEqual(Set(events.map(\.kind)), Set(JournalEventKind.allCases))
    for event in events {
      XCTAssertEqual(try JournalEventCodec.decode(JournalEventCodec.encode(event)), event)
    }
  }

  func testClosedCodecRejectsUnknownDuplicateMalformedAndHashMismatchVectors() throws {
    XCTAssertThrowsError(
      try JournalEventCodec.decode(JournalRecoveryFixtures.data(named: "unknown-kind.json")))
    XCTAssertThrowsError(
      try JournalEventCodec.decode(JournalRecoveryFixtures.data(named: "duplicate-member.json"))
    ) { error in
      guard case .duplicateMemberName = error as? ArkDeckStorage.StrictJSONError else {
        return XCTFail("duplicate member must be identified: \(error)")
      }
    }

    let lines = String(
      decoding: try JournalRecoveryFixtures.data(named: "all-event-kinds.jsonl"), as: UTF8.self
    ).split(separator: "\n")
    let warningWithUnknown = lines[16].replacingOccurrences(
      of: "\"details\":{}", with: "\"details\":{},\"future\":true")
    XCTAssertThrowsError(try JournalEventCodec.decode(Data(warningWithUnknown.utf8)))

    let mismatchedHash = String(lines[2]).replacingOccurrences(
      of: "5b0f0df3996fc95b079f245de3a39554beb39a4bc768f95bd2aa307c52c9af3e",
      with: String(repeating: "f", count: 64),
      maxReplacements: 1)
    XCTAssertThrowsError(try JournalEventCodec.decode(Data(mismatchedHash.utf8))) { error in
      guard case .canonicalArgumentsHashMismatch = error as? JournalEventValidationError else {
        return XCTFail("canonical argument mismatch must fail closed: \(error)")
      }
    }
  }

  func testJournalRejectsMalformedCompletedRecordAndInvalidSequenceCorrelation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appending(path: "journal.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    try journal.appendAndSynchronize(try makeJobCreated(sequence: 0))
    let handle = try FileHandle(forWritingTo: journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{}\n".utf8))
    try handle.synchronize()
    try handle.close()
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: journalURL))

    let secondURL = directory.appending(path: "invalid-sequence.jsonl")
    let second = try FileDurableJournal(url: secondURL)
    try second.appendAndSynchronize(try makeJobCreated(sequence: 0))
    XCTAssertThrowsError(
      try second.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "gap", sequence: 2, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, from: .queued, to: .preflight, reason: "gap")))
    XCTAssertEqual(try DurableJournalRecovery.inspect(url: secondURL).events.count, 1)

    let third = try FileDurableJournal(url: directory.appending(path: "orphan-outcome.jsonl"))
    try third.appendAndSynchronize(try makeJobCreated(sequence: 0))
    XCTAssertThrowsError(try third.appendAndSynchronize(makeOutcome(sequence: 1)))

    let missingCreatedURL = directory.appending(path: "missing-created.jsonl")
    let transition = try JournalEvent.stateTransition(
      eventID: "not-created", sequence: 0, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, from: .queued, to: .preflight, reason: "untrusted fixture")
    try (JournalEventCodec.encode(transition) + Data("\n".utf8)).write(to: missingCreatedURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: missingCreatedURL))

    let wrongInitialSequenceURL = directory.appending(path: "created-at-one.jsonl")
    let createdAtOne = try makeJobCreated(sequence: 1)
    try (JournalEventCodec.encode(createdAtOne) + Data("\n".utf8)).write(
      to: wrongInitialSequenceURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: wrongInitialSequenceURL))

    let emptyAppend = try FileDurableJournal(url: directory.appending(path: "append-gate.jsonl"))
    XCTAssertThrowsError(try emptyAppend.appendAndSynchronize(transition))
  }

  func testPlanOnlyJournalRejectsExecuteStatesAndDeviceMutationIntents() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appending(path: "plan-only.jsonl")
    let created = try makeJobCreated(sequence: 0, executionMode: "planOnly")
    let preflight = try JournalEvent.stateTransition(
      eventID: "plan-to-preflight", sequence: 1,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .queued, to: .preflight, reason: "plan fixture")
    let executeOnly = try JournalEvent.stateTransition(
      eventID: "plan-to-running", sequence: 2,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .preflight, to: .running, reason: "invalid execute-only state")
    let planning = try JournalEvent.stateTransition(
      eventID: "plan-to-planning", sequence: 2,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .preflight, to: .planning, reason: "plan fixture")

    let journal = try FileDurableJournal(url: journalURL)
    try journal.appendAndSynchronize(created)
    try journal.appendAndSynchronize(preflight)
    XCTAssertThrowsError(try journal.appendAndSynchronize(executeOnly))
    try journal.appendAndSynchronize(planning)

    var dispatchCount = 0
    XCTAssertThrowsError(
      try WriteAheadIntentGate(journal: journal).dispatch(
        intent: makeFlashIntent(sequence: 3)
      ) {
        dispatchCount += 1
      })
    XCTAssertEqual(dispatchCount, 0)
    XCTAssertEqual(try DurableJournalRecovery.inspect(url: journalURL).currentState, .planning)

    let executeOnlyURL = directory.appending(path: "forged-execute-state.jsonl")
    var executeOnlyData = Data()
    for event in [created, preflight, executeOnly] {
      executeOnlyData.append(try JournalEventCodec.encode(event))
      executeOnlyData.append(Data("\n".utf8))
    }
    try executeOnlyData.write(to: executeOnlyURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: executeOnlyURL))

    let mutationURL = directory.appending(path: "forged-plan-mutation.jsonl")
    var mutationData = Data()
    for event in [created, preflight, planning, try makeFlashIntent(sequence: 3)] {
      mutationData.append(try JournalEventCodec.encode(event))
      mutationData.append(Data("\n".utf8))
    }
    try mutationData.write(to: mutationURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: mutationURL))
  }

  func testTornTailIsIgnoredButForcesExplicitRecovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appending(path: "journal.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    try journal.appendAndSynchronize(try makeJobCreated(sequence: 0))
    let handle = try FileHandle(forWritingTo: journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schemaVersion\":\"1.0.0\"".utf8))
    try handle.synchronize()
    try handle.close()
    let replay = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertTrue(replay.hasTornTail)
    XCTAssertTrue(replay.requiresRecovery)
    XCTAssertEqual(replay.events.count, 1)
  }

  func testJournalFaultInjectionPreventsExternalDispatchAtEveryDurabilityGate() throws {
    let points: [DurabilityFaultPoint] = [
      .journalAppend, .journalWrite, .journalFileSync, .journalDirectorySync,
    ]
    for point in points {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let journalURL = directory.appending(path: "journal.jsonl")
      let seedJournal = try FileDurableJournal(url: journalURL)
      try seedJournal.appendAndSynchronize(try makeJobCreated(sequence: 0))
      try seedJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "fault-to-preflight", sequence: 1,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          from: .queued, to: .preflight, reason: "fault fixture"))
      var faultWasInjected = false
      let journal = try FileDurableJournal(
        url: journalURL,
        faultInjector: DurabilityFaultInjector { observed in
          if observed == point {
            faultWasInjected = true
            throw TestFault.injected(point)
          }
        })
      let gate = WriteAheadIntentGate(journal: journal)
      var dispatchCount = 0
      XCTAssertThrowsError(
        try gate.dispatch(intent: makeFlashIntent(sequence: 2)) { dispatchCount += 1 })
      XCTAssertTrue(faultWasInjected)
      XCTAssertEqual(dispatchCount, 0, "failed \(point.rawValue) must block dispatch")
      print("M1_JOURNAL_FAULT point=\(point.rawValue) external_dispatch_count=\(dispatchCount)")
    }
  }

  func testOutcomeMustBeDurableBeforeCheckpointAndPublicationFailuresNeverTearSnapshot() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let checkpointURL = directory.appending(path: "checkpoint.json")
    let stableStore = try AtomicJournalCheckpointStore(url: checkpointURL)
    let initial = try checkpoint(sequence: 0, state: .running)
    try stableStore.save(initial)

    let ordering = OrderedOperations()
    let gate = DurableOutcomeCheckpointGate(
      journal: RecordingJournal { event in ordering.append("journal:\(event.sequence)") },
      checkpointStore: RecordingCheckpointStore { value in
        ordering.append("checkpoint:\(value.journalSequence)")
      })
    try gate.record(
      outcome: makeOutcome(sequence: 1), checkpoint: checkpoint(sequence: 1, state: .running))
    XCTAssertEqual(ordering.values, ["journal:1", "checkpoint:1"])

    let failingOutcomeGate = DurableOutcomeCheckpointGate(
      journal: RecordingJournal(failure: { $0.kind == .stepOutcome }),
      checkpointStore: stableStore)
    XCTAssertThrowsError(
      try failingOutcomeGate.record(
        outcome: makeOutcome(sequence: 1), checkpoint: checkpoint(sequence: 1, state: .running)))
    XCTAssertEqual(try stableStore.load().journalSequence, 0)
    print("M1_OUTCOME_FAULT point=outcomeAppend checkpoint_sequence=0")

    for point in [
      DurabilityFaultPoint.checkpointTemporaryWrite, .checkpointFileSync, .checkpointReplace,
      .checkpointDirectorySync,
    ] {
      let failingStore = try AtomicJournalCheckpointStore(
        url: checkpointURL,
        faultInjector: DurabilityFaultInjector { observed in
          if observed == point { throw TestFault.injected(point) }
        })
      XCTAssertThrowsError(
        try failingStore.save(checkpoint(sequence: 2, state: .waitingForRecovery)))
      let recovered = try stableStore.load()
      XCTAssertTrue([0, 2].contains(recovered.journalSequence))
      print(
        "M1_CHECKPOINT_FAULT point=\(point.rawValue) recovered_sequence="
          + String(recovered.journalSequence))
    }
  }

  func testConfirmedFailureReconcileRequiresConfirmedBindingRevision() throws {
    XCTAssertThrowsError(
      try JournalEvent.reconcileOutcome(
        eventID: "missing-binding", sequence: 1,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        bindingRevision: nil, recoveryAttemptID: "attempt-1",
        result: "finalizeConfirmedFailure", nextState: .finalizing,
        outcomeCertainty: .confirmed, safeBoundaryConfirmed: true,
        evidence: ["provider-confirmed-failure"]))

    let valid = try JournalEvent.reconcileOutcome(
      eventID: "confirmed-binding", sequence: 1,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      bindingRevision: 1, recoveryAttemptID: "attempt-1",
      result: "finalizeConfirmedFailure", nextState: .finalizing,
      outcomeCertainty: .confirmed, safeBoundaryConfirmed: true,
      evidence: ["provider-confirmed-failure", "binding-confirmed"])
    XCTAssertEqual(valid.bindingRevision, 1)

    let forged = String(decoding: try JournalEventCodec.encode(valid), as: UTF8.self)
      .replacingOccurrences(of: "\"bindingRevision\":1", with: "\"bindingRevision\":null")
    XCTAssertThrowsError(try JournalEventCodec.decode(Data(forged.utf8)))
  }

  func testManifestRecoveryAndHazardUseTheLockedRequiredNullableShape() throws {
    let record = try RecoveryManifestRecord(
      needsAttention: true,
      interruptedReason: "unknown remote task",
      deviceHazards: [
        RecoveryManifestHazard(
          code: "remote-task-unknown", summary: "fixture", severity: "blocking",
          outcomeCertainty: "outcomeUnknown")
      ],
      abandonAuditEventIDs: ["abandon-intent", "abandon-outcome"],
      lastConfirmedStepID: nil,
      lastDeviceMode: .known(value: "updater", evidence: "provider-fixture"),
      managedHostProcessState: "stoppedAtSafeBoundary",
      recoveryGuide: RecoveryManifestGuide(
        providerIdentity: "fixture-provider", automaticRecoveryAvailable: false,
        summary: "human review required", steps: ["Confirm physical target"]),
      unexecutedCompensations: [],
      userConfirmation: RecoveryManifestAbandonConfirmation(
        confirmationID: "confirmation-1", confirmedAt: timestamp),
      recoveryOfSessionID: nil,
      recoveryOfJobID: nil)
    let encoded = try RecoveryManifestCodec.encode(record)
    XCTAssertEqual(try RecoveryManifestCodec.decode(encoded), record)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      Set([
        "needsAttention", "interruptedReason", "deviceHazards", "abandonAuditEventIds",
        "lastConfirmedStepId", "lastDeviceMode", "managedHostProcessState", "recoveryGuide",
        "unexecutedCompensations", "userConfirmation", "recoveryOfSessionId", "recoveryOfJobId",
      ]))
    XCTAssertTrue(object["lastConfirmedStepId"] is NSNull)
    XCTAssertTrue(object["recoveryOfSessionId"] is NSNull)
    XCTAssertTrue(object["recoveryOfJobId"] is NSNull)

    let unknown = String(decoding: encoded, as: UTF8.self).replacingOccurrences(
      of: "{", with: "{\"future\":true,", maxReplacements: 1)
    XCTAssertThrowsError(try RecoveryManifestCodec.decode(Data(unknown.utf8)))
  }

  private let timestamp = "2026-07-16T00:00:00Z"

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-task-m1-003-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeJobCreated(
    sequence: Int,
    executionMode: String = "execute"
  ) throws -> JournalEvent {
    try JournalEvent.jobCreated(
      eventID: "job-created", sequence: sequence, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, executionMode: executionMode)
  }

  private func agentAuthorityStep(
    effect: WorkflowEffect,
    suffix: String
  ) throws -> WorkflowStep {
    switch effect {
    case .readOnly:
      try WorkflowStep(
        id: "agent-read-\(suffix)", kind: .probeDevice, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["evidencePolicy": .string("fixture")])
    case .deviceMutation:
      try WorkflowStep(
        id: "agent-mutate-\(suffix)", kind: .rebootDevice,
        declaredEffect: .deviceMutation, declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "targetMode": .string("normal"), "reason": .string("fixture"),
        ])
    case .destructive:
      try WorkflowStep(
        id: "agent-destructive-\(suffix)", kind: .flashPartition,
        declaredEffect: .destructive,
        declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("fixtureFlash"),
          "partition": .string("system"),
          "imageArtifactId": .string("image-1"),
          "imageSha256": .string(String(repeating: "2", count: 64)),
          "imageSize": .integer(1),
          "confirmationId": .string("confirmation-1"),
          "safeBoundaryId": .string("safe-boundary-1"),
        ])
    case .hostOnly:
      fatalError()
    }
  }

  private func makeFinalizeIntent(sequence: Int) throws -> JournalEvent {
    let step = try WorkflowStep(
      id: "finalize-step", kind: .finalizeSession, declaredEffect: .hostOnly,
      declaredCancellation: .atSafeBoundary, declaredBindingRequirement: .none,
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ])
    return try JournalEvent.stepIntent(
      eventID: "finalize-intent", sequence: sequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      step: step,
      target: JournalTarget(
        scope: "host", targetID: "host-1", connectKey: nil, identitySnapshotHash: nil),
      attempt: 1, bindingRevision: nil)
  }

  private func makeReadOnlyIntent(sequence: Int) throws -> JournalEvent {
    let step = try WorkflowStep(
      id: "read-only-step", kind: .captureRemoteStdout, declaredEffect: .readOnly,
      declaredCancellation: .immediate, declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "catalogId": .string("arkui-ui-dump"),
        "actionId": .string("nodeSummary"),
        "parameters": .object([:]),
        "artifactId": .string("read-only-artifact"),
      ])
    return try JournalEvent.stepIntent(
      eventID: "read-only-intent", sequence: sequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      step: step,
      target: JournalTarget(
        scope: "device", targetID: "device-1", connectKey: "fixture-only",
        identitySnapshotHash: String(repeating: "b", count: 64)),
      attempt: 1, bindingRevision: 1)
  }

  private func makeFlashIntent(
    sequence: Int,
    eventID: String = "flash-intent",
    stepID: String = "flash-step",
    schemaVersion: String = JournalEvent.schemaVersion,
    authorizationRef: AuthorizationReference? = nil,
    usageReservationID: String? = nil
  ) throws -> JournalEvent {
    let step = try WorkflowStep(
      id: stepID, kind: .flashPartition, declaredEffect: .destructive,
      declaredCancellation: .criticalNonInterruptible,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "providerOperationId": .string("fixtureFlash"),
        "partition": .string("system"),
        "imageArtifactId": .string("image-1"),
        "imageSha256": .string(String(repeating: "a", count: 64)),
        "imageSize": .integer(1),
        "confirmationId": .string("confirm-1"),
        "safeBoundaryId": .string("boundary-1"),
      ])
    return try JournalEvent.stepIntent(
      eventID: eventID, sequence: sequence, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, step: step,
      target: JournalTarget(
        scope: "device", targetID: "device-1", connectKey: "fixture-only",
        identitySnapshotHash: String(repeating: "b", count: 64)),
      attempt: 1, bindingRevision: 1, schemaVersion: schemaVersion,
      authorizationRef: authorizationRef, usageReservationID: usageReservationID)
  }

  private func makeOutcome(
    sequence: Int,
    outcomeCertainty: JournalOutcomeCertainty = .confirmed,
    schemaVersion: String = JournalEvent.schemaVersion,
    authorizationRef: AuthorizationReference? = nil,
    usageReservationID: String? = nil
  ) throws -> JournalEvent {
    try JournalEvent.stepOutcome(
      eventID: "flash-outcome-\(sequence)", sequence: sequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      stepID: "flash-step", attempt: 1, correlatesToIntentEventID: "flash-intent",
      result: "succeeded", outcomeCertainty: outcomeCertainty,
      schemaVersion: schemaVersion, authorizationRef: authorizationRef,
      usageReservationID: usageReservationID)
  }

  private func authorizationReference() throws -> AuthorizationReference {
    try AuthorizationReference(
      authorizationID: "authorization-1", mainCommitOID: String(repeating: "a", count: 40),
      authorizationBlobOID: String(repeating: "b", count: 40), approvalPRNumber: 299)
  }

  private func checkpoint(sequence: Int, state: JobState) throws -> JournalCheckpoint {
    try JournalCheckpoint(
      sessionID: "session-1", jobID: "job-1", journalSequence: sequence,
      state: state.rawValue, updatedAt: timestamp)
  }

  private func abandonmentRequest(
    nextSequence: Int = 10,
    outcomeCertainty: JournalOutcomeCertainty = .outcomeUnknown,
    deviceHazards: [String] = ["remote-task-unknown"]
  ) -> RecoveryAbandonmentRequest {
    RecoveryAbandonmentRequest(
      sessionID: "session-1", jobID: "job-1", nextSequence: nextSequence,
      userConfirmationID: "confirmation-1", lastConfirmedStepID: "step-1",
      outcomeCertainty: outcomeCertainty, managedProcessState: "runningInterruptible",
      deviceHazards: deviceHazards)
  }

  private func appendTornTail(to journalURL: URL) throws {
    let handle = try FileHandle(forWritingTo: journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schemaVersion\":\"1.0.0\"".utf8))
    try handle.synchronize()
    try handle.close()
  }

  private func crashFixtureExecutable() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidate = packageRoot.appending(path: ".build/debug/ArkDeckJournalCrashFixture")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      XCTFail("dedicated crash fixture was not built at \(candidate.path)")
      throw TestFault.journal
    }
    return candidate
  }
}

private final class RecordingJournal: DurableJournalAppending, @unchecked Sendable {
  private let lock = NSLock()
  private let failure: (JournalEvent) -> Bool
  private let observer: (JournalEvent) -> Void
  private var recorded: [JournalEvent] = []

  init(
    failure: @escaping (JournalEvent) -> Bool = { _ in false },
    observer: @escaping (JournalEvent) -> Void = { _ in }
  ) {
    self.failure = failure
    self.observer = observer
  }

  convenience init(_ observer: @escaping (JournalEvent) -> Void) {
    self.init(observer: observer)
  }

  var events: [JournalEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func appendAndSynchronize(_ event: JournalEvent) throws {
    if failure(event) { throw TestFault.journal }
    lock.lock()
    recorded.append(event)
    lock.unlock()
    observer(event)
  }

  func abandonmentContext() throws -> JournalAbandonmentContext {
    JournalAbandonmentContext(requiredHazards: [], requiresOutcomeUnknown: false)
  }
}

private final class RecordingCheckpointStore: JournalCheckpointSaving, @unchecked Sendable {
  private let observer: (JournalCheckpoint) -> Void
  init(_ observer: @escaping (JournalCheckpoint) -> Void) { self.observer = observer }
  func save(_ checkpoint: JournalCheckpoint) throws { observer(checkpoint) }
}

private final class OrderedOperations: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func append(_ value: String) {
    lock.lock()
    stored.append(value)
    lock.unlock()
  }
}

private enum TestFault: Error {
  case injected(DurabilityFaultPoint)
  case journal
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func stringForTest(_ key: String) -> String? {
    guard case .string(let value)? = self[key] else { return nil }
    return value
  }

  fileprivate func stringArrayForTest(_ key: String) -> [String]? {
    guard case .array(let values)? = self[key] else { return nil }
    return values.compactMap { value in
      guard case .string(let string) = value else { return nil }
      return string
    }
  }
}

extension String {
  fileprivate func replacingOccurrences(
    of target: String,
    with replacement: String,
    maxReplacements: Int
  ) -> String {
    var result = self
    for _ in 0..<maxReplacements {
      guard let range = result.range(of: target) else { break }
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }
}
