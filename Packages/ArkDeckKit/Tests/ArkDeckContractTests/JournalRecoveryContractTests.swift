import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation
import XCTest

final class JournalRecoveryContractTests: XCTestCase {
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
      guard case .duplicateMemberName = error as? StrictJSONError else {
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

  func testTornTailIsDurablyRepairedForReconcileAndAuditedAbandonment() throws {
    let reconcileDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: reconcileDirectory) }
    let reconcileDescriptor = try writeRunningFlashJournal(
      in: reconcileDirectory, includeOutcome: true)
    try appendTornTail(to: reconcileDescriptor.journalURL)
    let tornSession = try XCTUnwrap(SessionRecoveryScanner().scan(reconcileDescriptor))
    XCTAssertTrue(tornSession.replay.hasTornTail)

    let repairedJournal = try FileDurableJournal(url: reconcileDescriptor.journalURL)
    XCTAssertFalse(
      try DurableJournalRecovery.inspect(url: reconcileDescriptor.journalURL).hasTornTail)
    let firstDecision = try DeterministicRecoveryReconciler(journal: repairedJournal).reconcile(
      session: tornSession,
      provider: ProviderRecoveryEvidence(
        disposition: .resume, restartSafe: true, safeBoundaryConfirmed: true,
        outcomeCertainty: .confirmed, evidence: ["provider-confirmed"]),
      binding: RecoveryBindingEvidence(
        confirmed: true, revision: 2, evidence: ["binding-confirmed"]))
    XCTAssertEqual(firstDecision.state, .waitingForRecovery)
    XCTAssertEqual(firstDecision.outcomeCertainty, .outcomeUnknown)

    let repairedSession = try XCTUnwrap(SessionRecoveryScanner().scan(reconcileDescriptor))
    let confirmedDecision = try DeterministicRecoveryReconciler(journal: repairedJournal).reconcile(
      session: repairedSession,
      provider: ProviderRecoveryEvidence(
        disposition: .resume, restartSafe: true, safeBoundaryConfirmed: true,
        outcomeCertainty: .confirmed, evidence: ["provider-confirmed-after-repair"]),
      binding: RecoveryBindingEvidence(
        confirmed: true, revision: 3, evidence: ["binding-confirmed-after-repair"]))
    XCTAssertEqual(confirmedDecision.state, .resumeAtConfirmedSafeBoundary)
    XCTAssertEqual(confirmedDecision.outcomeCertainty, .confirmed)

    let abandonDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: abandonDirectory) }
    let abandonDescriptor = try writeRunningFlashJournal(
      in: abandonDirectory, includeOutcome: true)
    try appendTornTail(to: abandonDescriptor.journalURL)
    let abandonSession = try XCTUnwrap(SessionRecoveryScanner().scan(abandonDescriptor))
    let resources = ResourceCounters()
    let abandonment = AuditedRecoveryAbandonmentCoordinator(
      journal: try FileDurableJournal(url: abandonDescriptor.journalURL),
      stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(abandonmentRequest(nextSequence: abandonSession.nextSequence))
    XCTAssertEqual(abandonment.state, .interrupted)
    XCTAssertEqual(resources.laneReleaseCount, 1)
    XCTAssertEqual(resources.claimReleaseCount, 1)
    XCTAssertFalse(
      try DurableJournalRecovery.inspect(url: abandonDescriptor.journalURL).hasTornTail)
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

  func testJournalSupersedesOlderCheckpointAndRejectsCheckpointAheadOfJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = descriptor(in: directory)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(try makeJobCreated(sequence: 0))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture"))
    let checkpointStore = try AtomicJournalCheckpointStore(url: descriptor.checkpointURL)
    try checkpointStore.save(checkpoint(sequence: 0, state: .queued))

    let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    XCTAssertEqual(scanned.snapshotSource, .journalSupersedesCheckpoint)
    XCTAssertEqual(scanned.state, .preflight)

    try checkpointStore.save(checkpoint(sequence: 3, state: .running))
    XCTAssertThrowsError(try SessionRecoveryScanner().scan(descriptor))
  }

  func testMissingDestructiveOutcomeAlwaysWaitsAndNeverReplaysOrCompensates() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: false)
    let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    XCTAssertEqual(scanned.state, .waitingForRecovery)
    XCTAssertEqual(scanned.outcomeCertainty, .outcomeUnknown)
    XCTAssertEqual(scanned.destructiveDispatchCount, 0)
    XCTAssertEqual(scanned.destructiveReplayCount, 0)
    XCTAssertEqual(scanned.guessCompensationCount, 0)

    let journal = try FileDurableJournal(url: descriptor.journalURL)
    let result = try DeterministicRecoveryReconciler(journal: journal).reconcile(
      session: scanned,
      provider: ProviderRecoveryEvidence(
        disposition: .resume, restartSafe: true, safeBoundaryConfirmed: true,
        outcomeCertainty: .confirmed, evidence: ["provider-fixture"]),
      binding: RecoveryBindingEvidence(confirmed: true, revision: 1, evidence: ["binding-fixture"])
    )
    XCTAssertEqual(result.state, .waitingForRecovery)
    XCTAssertEqual(result.outcomeCertainty, .outcomeUnknown)
    XCTAssertEqual(result.destructiveDispatchCount, 0)
    XCTAssertEqual(result.destructiveReplayCount, 0)
    XCTAssertEqual(result.guessCompensationCount, 0)
    XCTAssertEqual(result.durableEventSequences.count, 5)
    let reconciled = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertEqual(reconciled.currentState, .waitingForRecovery)
    XCTAssertEqual(
      reconciled.events.suffix(5).map(\.kind),
      [.stateTransition, .stateTransition, .reconcileStarted, .reconcileOutcome, .stateTransition])
    print(
      "M1_RECONCILE state=\(result.state.rawValue) certainty=\(result.outcomeCertainty.rawValue) "
        + "dispatch=0 replay=0 compensation=0")
  }

  func testDurableUnknownStepAndCompensationOutcomesForceFailClosedRecovery() throws {
    let stepDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: stepDirectory) }
    let stepDescriptor = try writeRunningFlashJournal(
      in: stepDirectory, includeOutcome: true, outcomeCertainty: .outcomeUnknown)
    let stepReplay = try DurableJournalRecovery.inspect(url: stepDescriptor.journalURL)
    let stepSession = try XCTUnwrap(SessionRecoveryScanner().scan(stepDescriptor))
    XCTAssertTrue(stepReplay.outstandingIntents.isEmpty)
    XCTAssertEqual(stepReplay.unknownOutcomes.map(\.correlatedIntentEventID), ["flash-intent"])
    XCTAssertEqual(
      stepReplay.requiredAbandonmentHazards,
      ["unresolved-destructive-intent:flash-step:flash-intent"])
    XCTAssertEqual(stepSession.state, .waitingForRecovery)
    XCTAssertEqual(stepSession.outcomeCertainty, .outcomeUnknown)
    let failClosedGate = WriteAheadIntentGate(
      journal: try FileDurableJournal(url: stepDescriptor.journalURL))
    var dispatchCount = 0
    XCTAssertThrowsError(
      try failClosedGate.dispatch(
        intent: makeFlashIntent(
          sequence: 5, eventID: "next-flash-intent", stepID: "next-flash-step")
      ) {
        dispatchCount += 1
      })
    XCTAssertEqual(dispatchCount, 0)

    let compensationDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: compensationDirectory) }
    let compensationDescriptor = descriptor(in: compensationDirectory)
    let journal = try FileDurableJournal(url: compensationDescriptor.journalURL)
    let fixtureLines = String(
      decoding: try JournalRecoveryFixtures.data(named: "all-event-kinds.jsonl"), as: UTF8.self
    ).split(separator: "\n")
    for line in fixtureLines.prefix(5) {
      try journal.appendAndSynchronize(try JournalEventCodec.decode(Data(line.utf8)))
    }
    let unknownCompensation = String(fixtureLines[5]).replacingOccurrences(
      of: "\"outcomeCertainty\":\"confirmed\"",
      with: "\"outcomeCertainty\":\"outcomeUnknown\"")
    try journal.appendAndSynchronize(
      try JournalEventCodec.decode(Data(unknownCompensation.utf8)))

    let compensationReplay = try DurableJournalRecovery.inspect(
      url: compensationDescriptor.journalURL)
    let compensationSession = try XCTUnwrap(
      SessionRecoveryScanner().scan(compensationDescriptor))
    XCTAssertTrue(compensationReplay.outstandingIntents.isEmpty)
    XCTAssertEqual(compensationReplay.unknownOutcomes.count, 1)
    XCTAssertTrue(try XCTUnwrap(compensationReplay.unknownOutcomes.first).isCompensation)
    XCTAssertEqual(
      compensationReplay.requiredAbandonmentHazards,
      ["unresolved-deviceMutation-intent:comp-1:e04"])
    XCTAssertEqual(compensationSession.state, .waitingForRecovery)
    XCTAssertEqual(compensationSession.outcomeCertainty, .outcomeUnknown)
  }

  func testOutstandingExternalIntentCannotBeFinalizedOrHiddenFromRecovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: false)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    let toFinalizing = try JournalEvent.stateTransition(
      eventID: "to-finalizing", sequence: 4,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .running, to: .finalizing, reason: "invalid unresolved terminal path")
    XCTAssertThrowsError(try journal.appendAndSynchronize(toFinalizing))
    let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    XCTAssertEqual(scanned.state, .waitingForRecovery)
    XCTAssertEqual(scanned.outcomeCertainty, .outcomeUnknown)

    let rawURL = directory.appending(path: "untrusted-finalized.jsonl")
    let failed = try JournalEvent.stateTransition(
      eventID: "to-failed", sequence: 5,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .finalizing, to: .failed, reason: "invalid unresolved terminal path")
    let finalized = try JournalEvent(
      eventID: "finalized", sequence: 6,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("failed"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
    var rawData = Data()
    let prefix = try DurableJournalRecovery.inspect(url: descriptor.journalURL).events
    for event in prefix + [toFinalizing, failed, finalized] {
      rawData.append(try JournalEventCodec.encode(event))
      rawData.append(Data("\n".utf8))
    }
    try rawData.write(to: rawURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: rawURL))
  }

  func testHostOnlyAndReadOnlyOutstandingIntentsBlockNormalTerminalLifecycle() throws {
    let finalizeDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: finalizeDirectory) }
    let finalizeDescriptor = descriptor(in: finalizeDirectory)
    let finalizeJournal = try FileDurableJournal(url: finalizeDescriptor.journalURL)
    try finalizeJournal.appendAndSynchronize(try makeJobCreated(sequence: 0))
    try finalizeJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "finalize-to-preflight", sequence: 1,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .queued, to: .preflight, reason: "fixture"))
    try finalizeJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "finalize-to-running", sequence: 2,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .preflight, to: .running, reason: "fixture"))
    try finalizeJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "enter-finalizing", sequence: 3,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .running, to: .finalizing, reason: "begin finalization"))
    try finalizeJournal.appendAndSynchronize(try makeFinalizeIntent(sequence: 4))
    let forgedSuccess = try JournalEvent.stateTransition(
      eventID: "finalize-succeeded", sequence: 5,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      from: .finalizing, to: .succeeded, reason: "missing finalize outcome")
    XCTAssertThrowsError(try finalizeJournal.appendAndSynchronize(forgedSuccess))
    let finalizeSession = try XCTUnwrap(SessionRecoveryScanner().scan(finalizeDescriptor))
    XCTAssertEqual(finalizeSession.state, .waitingForRecovery)
    XCTAssertEqual(finalizeSession.outcomeCertainty, .outcomeUnknown)
    let forgedFinalized = try JournalEvent(
      eventID: "finalize-finalized", sequence: 6,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("succeeded"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
    let finalizeRawURL = finalizeDirectory.appending(path: "forged-finalized.jsonl")
    var finalizeRawData = Data()
    for event in try DurableJournalRecovery.inspect(url: finalizeDescriptor.journalURL).events
      + [forgedSuccess, forgedFinalized]
    {
      finalizeRawData.append(try JournalEventCodec.encode(event))
      finalizeRawData.append(Data("\n".utf8))
    }
    try finalizeRawData.write(to: finalizeRawURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: finalizeRawURL))

    let intents = [
      ("read-only", try makeReadOnlyIntent(sequence: 3))
    ]
    for (label, intent) in intents {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let descriptor = descriptor(in: directory)
      let journal = try FileDurableJournal(url: descriptor.journalURL)
      try journal.appendAndSynchronize(try makeJobCreated(sequence: 0))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "\(label)-to-preflight", sequence: 1,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          from: .queued, to: .preflight, reason: "fixture"))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "\(label)-to-running", sequence: 2,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          from: .preflight, to: .running, reason: "fixture"))
      try journal.appendAndSynchronize(intent)

      let toFinalizing = try JournalEvent.stateTransition(
        eventID: "\(label)-to-finalizing", sequence: 4,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .running, to: .finalizing, reason: "invalid unresolved intent path")
      XCTAssertThrowsError(try journal.appendAndSynchronize(toFinalizing), label)
      let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
      XCTAssertEqual(scanned.state, .waitingForRecovery, label)
      XCTAssertEqual(scanned.outcomeCertainty, .outcomeUnknown, label)

      let succeeded = try JournalEvent.stateTransition(
        eventID: "\(label)-succeeded", sequence: 5,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .finalizing, to: .succeeded, reason: "invalid unresolved intent path")
      let finalized = try JournalEvent(
        eventID: "\(label)-finalized", sequence: 6,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        kind: .finalized,
        payload: [
          "terminalStatus": .string("succeeded"),
          "manifestSha256": .string(String(repeating: "a", count: 64)),
          "outcomeCertainty": .string("confirmed"),
        ])
      let rawURL = directory.appending(path: "forged-terminal.jsonl")
      var rawData = Data()
      for event in try DurableJournalRecovery.inspect(url: descriptor.journalURL).events
        + [toFinalizing, succeeded, finalized]
      {
        rawData.append(try JournalEventCodec.encode(event))
        rawData.append(Data("\n".utf8))
      }
      try rawData.write(to: rawURL)
      XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: rawURL), label)
    }
  }

  func testInitialAbandonmentDerivesHazardsAndUnknownCertaintyFromJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: false)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "outstanding-to-recovery", sequence: 4,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .running, to: .waitingForRecovery, reason: "fixture unresolved device intent"))
    let requiredHazard = "unresolved-destructive-intent:flash-step:flash-intent"
    XCTAssertEqual(
      try journal.abandonmentContext(),
      JournalAbandonmentContext(
        requiredHazards: [requiredHazard], requiresOutcomeUnknown: true))

    XCTAssertThrowsError(
      try journal.appendAndSynchronize(
        JournalEvent.abandonIntent(
          eventID: "hazard-clearing-intent", sequence: 5,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          userConfirmationID: "confirmation-1", lastConfirmedStep: nil,
          outcomeCertainty: .outcomeUnknown, managedProcessState: "notRunning",
          deviceHazards: [])))
    XCTAssertThrowsError(
      try journal.appendAndSynchronize(
        JournalEvent.abandonIntent(
          eventID: "certainty-forging-intent", sequence: 5,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          userConfirmationID: "confirmation-1", lastConfirmedStep: nil,
          outcomeCertainty: .confirmed, managedProcessState: "notRunning",
          deviceHazards: [requiredHazard])))

    let resources = ResourceCounters()
    let result = AuditedRecoveryAbandonmentCoordinator(
      journal: journal, stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(
      abandonmentRequest(
        nextSequence: 5, outcomeCertainty: .confirmed, deviceHazards: []))
    XCTAssertEqual(result.state, .interrupted)
    let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    let intent = try XCTUnwrap(replay.events.last(where: { $0.kind == .abandonIntent }))
    let outcome = try XCTUnwrap(replay.events.last(where: { $0.kind == .abandonOutcome }))
    XCTAssertEqual(intent.payload.stringArrayForTest("deviceHazards"), [requiredHazard])
    XCTAssertEqual(intent.payload.stringForTest("outcomeCertainty"), "outcomeUnknown")
    XCTAssertEqual(outcome.payload.stringArrayForTest("unresolvedHazards"), [requiredHazard])
  }

  func testAuthorizedInterruptedRejectsMismatchedFinalizedStatus() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: false)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "finalized-to-recovery", sequence: 4,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .running, to: .waitingForRecovery, reason: "fixture unresolved device intent"))
    let resources = ResourceCounters()
    let abandoned = AuditedRecoveryAbandonmentCoordinator(
      journal: journal, stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(abandonmentRequest(nextSequence: 5, deviceHazards: []))
    XCTAssertEqual(abandoned.state, .interrupted)

    let mismatched = try JournalEvent(
      eventID: "mismatched-finalized", sequence: 9,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("failed"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
    XCTAssertThrowsError(try journal.appendAndSynchronize(mismatched))

    let handle = try FileHandle(forWritingTo: descriptor.journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: JournalEventCodec.encode(mismatched) + Data("\n".utf8))
    try handle.synchronize()
    try handle.close()
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: descriptor.journalURL))
  }

  func testInterruptedFinalizedCannotConfirmUnresolvedIntentOutcome() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: false)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "certainty-to-recovery", sequence: 4,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .running, to: .waitingForRecovery, reason: "fixture unresolved device intent"))
    let resources = ResourceCounters()
    let abandoned = AuditedRecoveryAbandonmentCoordinator(
      journal: journal, stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(
      abandonmentRequest(
        nextSequence: 5, outcomeCertainty: .confirmed, deviceHazards: []))
    XCTAssertEqual(abandoned.state, .interrupted)
    let interruptedReplay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertTrue(interruptedReplay.requiresUnknownFinalizedOutcome)

    let incorrectlyConfirmed = try JournalEvent(
      eventID: "confirmed-finalized", sequence: 9,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("interrupted"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
    XCTAssertThrowsError(try journal.appendAndSynchronize(incorrectlyConfirmed))

    let rawURL = directory.appending(path: "forged-confirmed-finalized.jsonl")
    var rawData = Data()
    for event in interruptedReplay.events + [incorrectlyConfirmed] {
      rawData.append(try JournalEventCodec.encode(event))
      rawData.append(Data("\n".utf8))
    }
    try rawData.write(to: rawURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: rawURL))

    let unknownFinalized = try JournalEvent(
      eventID: "unknown-finalized", sequence: 9,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("interrupted"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("outcomeUnknown"),
      ])
    try journal.appendAndSynchronize(unknownFinalized)
    XCTAssertTrue(try DurableJournalRecovery.inspect(url: descriptor.journalURL).finalized)
    XCTAssertNil(try SessionRecoveryScanner().scan(descriptor))
  }

  func testAuditedAbandonmentPreservesDurableUnknownThroughFinalized() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(
      in: directory, includeOutcome: true, outcomeCertainty: .outcomeUnknown)
    let initialSession = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    let waiting = try DeterministicRecoveryReconciler(journal: journal).reconcile(
      session: initialSession,
      provider: ProviderRecoveryEvidence(
        disposition: .uncertain, restartSafe: false, safeBoundaryConfirmed: false,
        outcomeCertainty: .outcomeUnknown, evidence: ["provider-uncertain"]),
      binding: RecoveryBindingEvidence(
        confirmed: false, revision: nil, evidence: ["binding-uncertain"]))
    XCTAssertEqual(waiting.state, .waitingForRecovery)

    let waitingSession = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let resources = ResourceCounters()
    let abandoned = AuditedRecoveryAbandonmentCoordinator(
      journal: journal, stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(
      abandonmentRequest(
        nextSequence: waitingSession.nextSequence,
        outcomeCertainty: .confirmed,
        deviceHazards: []))
    XCTAssertEqual(abandoned.state, .interrupted)
    let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertEqual(replay.unknownOutcomes.count, 1)
    XCTAssertTrue(replay.requiresUnknownFinalizedOutcome)

    let confirmed = try JournalEvent(
      eventID: "durable-unknown-confirmed-finalized",
      sequence: (replay.lastDurableSequence ?? -1) + 1,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("interrupted"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
    XCTAssertThrowsError(try journal.appendAndSynchronize(confirmed))

    let unknown = try JournalEvent(
      eventID: "durable-unknown-finalized", sequence: confirmed.sequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      kind: .finalized,
      payload: [
        "terminalStatus": .string("interrupted"),
        "manifestSha256": .string(String(repeating: "a", count: 64)),
        "outcomeCertainty": .string("outcomeUnknown"),
      ])
    try journal.appendAndSynchronize(unknown)
  }

  func testReconcileOutcomeSurvivesCrashBeforeDecisionTransition() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-reconciling", sequence: 6, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .waitingForRecovery, to: .reconciling,
        reason: "fixture reconcile"))
    try journal.appendAndSynchronize(
      JournalEvent.reconcileStarted(
        eventID: "reconcile-started", sequence: 7, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, recoveryAttemptID: "attempt-1",
        sourceState: .waitingForRecovery, lastDurableSequence: 6, trigger: "startup"))
    let outcome = try JournalEvent.reconcileOutcome(
      eventID: "reconcile-outcome", sequence: 8, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, bindingRevision: 1, recoveryAttemptID: "attempt-1",
      result: "resumeAtConfirmedSafeBoundary", nextState: .resumeAtConfirmedSafeBoundary,
      outcomeCertainty: .confirmed, safeBoundaryConfirmed: true, evidence: ["fixture"])
    try journal.appendAndSynchronize(outcome)

    let replayAfterCrash = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertEqual(replayAfterCrash.currentState, .resumeAtConfirmedSafeBoundary)
    XCTAssertTrue(replayAfterCrash.requiresRecovery)
    let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let resumed = try DeterministicRecoveryReconciler(
      journal: FileDurableJournal(url: descriptor.journalURL)
    ).reconcile(
      session: scanned,
      provider: ProviderRecoveryEvidence(
        disposition: .uncertain, restartSafe: false, safeBoundaryConfirmed: false,
        outcomeCertainty: .outcomeUnknown, evidence: []),
      binding: RecoveryBindingEvidence(confirmed: false, revision: nil, evidence: []))
    XCTAssertEqual(resumed.state, .resumeAtConfirmedSafeBoundary)
    XCTAssertEqual(resumed.durableEventSequences, [9])
    XCTAssertEqual(
      try DurableJournalRecovery.inspect(url: descriptor.journalURL).currentState,
      .resumeAtConfirmedSafeBoundary)
    XCTAssertFalse(try DurableJournalRecovery.inspect(url: descriptor.journalURL).requiresRecovery)
  }

  func testReconcileRestartsAfterCrashInReconciling() throws {
    for crashAfterStarted in [false, true] {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
      let journal = try FileDurableJournal(url: descriptor.journalURL)
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "old-to-reconciling", sequence: 6,
          sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
          from: .waitingForRecovery, to: .reconciling, reason: "crash fixture"))
      if crashAfterStarted {
        try journal.appendAndSynchronize(
          JournalEvent.reconcileStarted(
            eventID: "old-reconcile-start", sequence: 7,
            sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
            recoveryAttemptID: "old-attempt", sourceState: .waitingForRecovery,
            lastDurableSequence: 6, trigger: "startup"))
      }

      let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
      XCTAssertEqual(scanned.state, .waitingForRecovery)
      XCTAssertEqual(scanned.outcomeCertainty, .confirmed)
      let resumed = try DeterministicRecoveryReconciler(
        journal: FileDurableJournal(url: descriptor.journalURL)
      ).reconcile(
        session: scanned,
        provider: ProviderRecoveryEvidence(
          disposition: .resume, restartSafe: true, safeBoundaryConfirmed: true,
          outcomeCertainty: .confirmed, evidence: ["provider"]),
        binding: RecoveryBindingEvidence(
          confirmed: true, revision: 1, evidence: ["binding"]))
      XCTAssertEqual(resumed.state, .resumeAtConfirmedSafeBoundary)
      XCTAssertEqual(resumed.outcomeCertainty, .confirmed)
      let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
      XCTAssertEqual(replay.currentState, .resumeAtConfirmedSafeBoundary)
      XCTAssertEqual(replay.events[scanned.nextSequence].stateTransition?.from, .reconciling)
      XCTAssertEqual(replay.events[scanned.nextSequence].stateTransition?.to, .waitingForRecovery)
    }
  }

  func testLaterConfirmedReconcileSupersedesHistoricalUnknownDecision() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
    let firstScan = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let first = try DeterministicRecoveryReconciler(
      journal: FileDurableJournal(url: descriptor.journalURL)
    ).reconcile(
      session: firstScan,
      provider: ProviderRecoveryEvidence(
        disposition: .uncertain, restartSafe: false, safeBoundaryConfirmed: false,
        outcomeCertainty: .outcomeUnknown, evidence: ["provider-uncertain"]),
      binding: RecoveryBindingEvidence(
        confirmed: false, revision: nil, evidence: ["binding-uncertain"]))
    XCTAssertEqual(first.state, .waitingForRecovery)
    XCTAssertEqual(first.outcomeCertainty, .outcomeUnknown)

    let secondScan = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    XCTAssertEqual(secondScan.state, .waitingForRecovery)
    XCTAssertEqual(secondScan.outcomeCertainty, .outcomeUnknown)
    let second = try DeterministicRecoveryReconciler(
      journal: FileDurableJournal(url: descriptor.journalURL)
    ).reconcile(
      session: secondScan,
      provider: ProviderRecoveryEvidence(
        disposition: .resume, restartSafe: true, safeBoundaryConfirmed: true,
        outcomeCertainty: .confirmed, evidence: ["provider-confirmed"]),
      binding: RecoveryBindingEvidence(
        confirmed: true, revision: 1, evidence: ["binding-confirmed"]))
    XCTAssertEqual(second.state, .resumeAtConfirmedSafeBoundary)
    XCTAssertEqual(second.outcomeCertainty, .confirmed)

    let resolvedReplay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertEqual(resolvedReplay.lastReconcileOutcomeCertainty, .confirmed)
    XCTAssertFalse(resolvedReplay.requiresRecovery)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "resume-running", sequence: secondScan.nextSequence + 4,
        sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
        from: .resumeAtConfirmedSafeBoundary, to: .running,
        reason: "confirmed reconcile supersedes historical unknown"))
    XCTAssertEqual(
      try DurableJournalRecovery.inspect(url: descriptor.journalURL).currentState,
      .running)
  }

  func testLatestUnknownReconcileCannotBeConfirmedByAbandonment() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
    let initial = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    let uncertain = try DeterministicRecoveryReconciler(journal: journal).reconcile(
      session: initial,
      provider: ProviderRecoveryEvidence(
        disposition: .uncertain, restartSafe: false, safeBoundaryConfirmed: false,
        outcomeCertainty: .outcomeUnknown, evidence: ["provider-uncertain"]),
      binding: RecoveryBindingEvidence(
        confirmed: false, revision: nil, evidence: ["binding-uncertain"]))
    XCTAssertEqual(uncertain.state, .waitingForRecovery)
    XCTAssertEqual(
      try journal.abandonmentContext(),
      JournalAbandonmentContext(requiredHazards: [], requiresOutcomeUnknown: true))

    let session = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let forged = try JournalEvent.abandonIntent(
      eventID: "forged-confirmed-abandon", sequence: session.nextSequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      userConfirmationID: "confirmation-1", lastConfirmedStep: "flash-step",
      outcomeCertainty: .confirmed, managedProcessState: "notRunning",
      deviceHazards: [])
    XCTAssertThrowsError(try journal.appendAndSynchronize(forged))

    let forgedURL = directory.appending(path: "forged-confirmed-abandon.jsonl")
    var forgedData = Data()
    for event in session.replay.events + [forged] {
      forgedData.append(try JournalEventCodec.encode(event))
      forgedData.append(Data("\n".utf8))
    }
    try forgedData.write(to: forgedURL)
    XCTAssertThrowsError(try DurableJournalRecovery.inspect(url: forgedURL))

    let resources = ResourceCounters()
    let abandoned = AuditedRecoveryAbandonmentCoordinator(
      journal: journal, stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources
    ).abandon(
      abandonmentRequest(
        nextSequence: session.nextSequence, outcomeCertainty: .confirmed,
        deviceHazards: []))
    XCTAssertEqual(abandoned.state, .interrupted)
    let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    let intent = try XCTUnwrap(replay.events.last(where: { $0.kind == .abandonIntent }))
    XCTAssertEqual(intent.payload.stringForTest("outcomeCertainty"), "outcomeUnknown")
    XCTAssertTrue(replay.requiresUnknownFinalizedOutcome)
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

  func testConfirmedRecoveryRequiresEveryResumeCondition() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
    let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
    let journal = RecordingJournal()
    let reconciler = DeterministicRecoveryReconciler(journal: journal)

    for restartSafe in [false, true] {
      for safeBoundary in [false, true] {
        for outcomeConfirmed in [false, true] {
          for bindingConfirmed in [false, true] {
            let decision = try reconciler.reconcile(
              session: scanned,
              provider: ProviderRecoveryEvidence(
                disposition: .resume, restartSafe: restartSafe,
                safeBoundaryConfirmed: safeBoundary,
                outcomeCertainty: outcomeConfirmed ? .confirmed : .outcomeUnknown,
                evidence: ["provider"]),
              binding: RecoveryBindingEvidence(
                confirmed: bindingConfirmed, revision: bindingConfirmed ? 1 : nil,
                evidence: ["binding"])
            )
            let permitted = restartSafe && safeBoundary && outcomeConfirmed && bindingConfirmed
            XCTAssertEqual(
              decision.state, permitted ? .resumeAtConfirmedSafeBoundary : .waitingForRecovery)
            XCTAssertEqual(decision.destructiveDispatchCount, 0)
          }
        }
      }
    }
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

  func testAbandonmentFaultMatrixReleasesOnlyAfterDurableTerminalTransition() throws {
    let request = abandonmentRequest()

    let intentFailureResources = ResourceCounters()
    let intentFailure = AuditedRecoveryAbandonmentCoordinator(
      journal: RecordingJournal(failure: { $0.kind == .abandonIntent }),
      stopper: FakeStopper(.notRunning), laneReleaser: intentFailureResources,
      claimReleaser: intentFailureResources
    )
    .abandon(request)
    XCTAssertEqual(intentFailure.state, .waitingForRecovery)
    XCTAssertEqual(intentFailureResources.laneReleaseCount, 0)
    XCTAssertEqual(intentFailureResources.claimReleaseCount, 0)
    print(
      "M1_ABANDON case=intent_failure durable=\(intentFailure.durableEventSequences) lane=0 claim=0"
    )

    let unsafeResources = ResourceCounters()
    let unsafe = AuditedRecoveryAbandonmentCoordinator(
      journal: RecordingJournal(), stopper: FakeStopper(.unconfirmed),
      laneReleaser: unsafeResources, claimReleaser: unsafeResources
    )
    .abandon(request)
    XCTAssertEqual(unsafe.state, .waitingForRecovery)
    XCTAssertEqual(unsafeResources.totalReleaseCount, 0)
    print(
      "M1_ABANDON case=safe_boundary_unconfirmed durable=\(unsafe.durableEventSequences) lane=0 claim=0"
    )

    let outcomeFailureResources = ResourceCounters()
    let outcomeFailure = AuditedRecoveryAbandonmentCoordinator(
      journal: RecordingJournal(failure: { $0.kind == .abandonOutcome }),
      stopper: FakeStopper(.stoppedAtSafeBoundary),
      laneReleaser: outcomeFailureResources, claimReleaser: outcomeFailureResources
    )
    .abandon(request)
    XCTAssertEqual(outcomeFailure.state, .waitingForRecovery)
    XCTAssertEqual(outcomeFailureResources.totalReleaseCount, 0)
    print(
      "M1_ABANDON case=outcome_sync_failure durable=\(outcomeFailure.durableEventSequences) lane=0 claim=0"
    )

    let terminalFailureResources = ResourceCounters()
    let terminalFailure = AuditedRecoveryAbandonmentCoordinator(
      journal: RecordingJournal(failure: { event in
        event.kind == .stateTransition && event.payload.stringForTest("to") == "interrupted"
      }),
      stopper: FakeStopper(.notRunning), laneReleaser: terminalFailureResources,
      claimReleaser: terminalFailureResources
    )
    .abandon(request)
    XCTAssertEqual(terminalFailure.state, .waitingForRecovery)
    XCTAssertEqual(terminalFailureResources.totalReleaseCount, 0)
    print(
      "M1_ABANDON case=terminal_transition_failure durable=\(terminalFailure.durableEventSequences) lane=0 claim=0"
    )

    let successJournal = RecordingJournal()
    let successResources = ResourceCounters()
    let success = AuditedRecoveryAbandonmentCoordinator(
      journal: successJournal, stopper: FakeStopper(.stoppedAtSafeBoundary),
      laneReleaser: successResources, claimReleaser: successResources
    )
    .abandon(request)
    XCTAssertEqual(success.state, .interrupted)
    XCTAssertEqual(successResources.laneReleaseCount, 1)
    XCTAssertEqual(successResources.claimReleaseCount, 1)
    XCTAssertTrue(success.laneReleased)
    XCTAssertTrue(success.claimReleased)
    XCTAssertFalse(success.resourceReleasePending)
    XCTAssertEqual(
      successJournal.events.map(\.kind),
      [
        .abandonIntent, .stateTransition, .abandonOutcome, .stateTransition,
      ])
    print("M1_ABANDON case=success durable=\(success.durableEventSequences) lane=1 claim=1")
  }

  func testAbandonmentResumesEveryAuditedCrashWindow() throws {
    for phase in RecoveryAbandonmentPhase.allCases {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
      let journal = try FileDurableJournal(url: descriptor.journalURL)
      let request = abandonmentRequest(nextSequence: 6)
      let resumedRequest = RecoveryAbandonmentRequest(
        sessionID: request.sessionID, jobID: request.jobID,
        nextSequence: request.nextSequence,
        userConfirmationID: request.userConfirmationID,
        lastConfirmedStepID: request.lastConfirmedStepID,
        outcomeCertainty: request.outcomeCertainty,
        managedProcessState: request.managedProcessState,
        deviceHazards: [])
      let intent = try JournalEvent.abandonIntent(
        eventID: "abandon-intent", sequence: 6,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: timestamp,
        userConfirmationID: request.userConfirmationID,
        lastConfirmedStep: request.lastConfirmedStepID,
        outcomeCertainty: request.outcomeCertainty,
        managedProcessState: request.managedProcessState,
        deviceHazards: request.deviceHazards)
      try journal.appendAndSynchronize(intent)
      if phase != .intentDurable {
        try journal.appendAndSynchronize(
          JournalEvent.stateTransition(
            eventID: "abandon-requested", sequence: 7,
            sessionID: request.sessionID, jobID: request.jobID, timestamp: timestamp,
            from: .waitingForRecovery, to: .userAbandonRequested,
            reason: "fixture", triggerEventID: intent.eventID))
      }
      if phase == .outcomeDurable {
        try journal.appendAndSynchronize(
          JournalEvent.abandonOutcome(
            eventID: "abandon-outcome", sequence: 8,
            sessionID: request.sessionID, jobID: request.jobID, timestamp: timestamp,
            correlatesToAbandonIntentEventID: intent.eventID,
            result: "archivedInterrupted", releaseAuthorized: true,
            unresolvedHazards: request.deviceHazards))
      } else if phase == .requested {
        XCTAssertThrowsError(
          try journal.appendAndSynchronize(
            JournalEvent.abandonOutcome(
              eventID: "hazard-clearing-outcome", sequence: 8,
              sessionID: request.sessionID, jobID: request.jobID, timestamp: timestamp,
              correlatesToAbandonIntentEventID: intent.eventID,
              result: "archivedInterrupted", releaseAuthorized: true,
              unresolvedHazards: [])))
      }

      let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
      XCTAssertEqual(replay.pendingAbandonment?.phase, phase)
      XCTAssertEqual(replay.pendingAbandonment?.deviceHazards, request.deviceHazards)
      let scanned = try XCTUnwrap(SessionRecoveryScanner().scan(descriptor))
      XCTAssertEqual(scanned.state, .waitingForRecovery)
      let resources = ResourceCounters()
      let coordinator = AuditedRecoveryAbandonmentCoordinator(
        journal: try FileDurableJournal(url: descriptor.journalURL),
        stopper: FakeStopper(.notRunning), laneReleaser: resources,
        claimReleaser: resources)
      let resumed = try coordinator.resumeAbandonment(resumedRequest, from: replay)
      XCTAssertEqual(resumed.state, .interrupted)
      XCTAssertFalse(resumed.resourceReleasePending)
      XCTAssertEqual(resources.laneReleaseCount, 1)
      XCTAssertEqual(resources.claimReleaseCount, 1)
      let completed = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
      XCTAssertNil(completed.pendingAbandonment)
      XCTAssertTrue(completed.resourceReleaseAuthorized)
      XCTAssertEqual(completed.currentState, .interrupted)
      let durableOutcome = try XCTUnwrap(
        completed.events.last(where: { $0.kind == .abandonOutcome }))
      XCTAssertEqual(
        durableOutcome.payload.stringArrayForTest("unresolvedHazards"),
        request.deviceHazards)
    }
  }

  func testPartialAuthorizedReleaseIsAccurateAndIdempotentlyRecoverable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = try writeRunningFlashJournal(in: directory, includeOutcome: true)
    let resources = ResourceCounters(claimFailures: 1)
    let coordinator = AuditedRecoveryAbandonmentCoordinator(
      journal: try FileDurableJournal(url: descriptor.journalURL),
      stopper: FakeStopper(.notRunning), laneReleaser: resources,
      claimReleaser: resources)
    let first = coordinator.abandon(abandonmentRequest(nextSequence: 6))
    XCTAssertEqual(first.state, .interrupted)
    XCTAssertEqual(first.laneReleaseCount, 1)
    XCTAssertEqual(first.claimReleaseCount, 0)
    XCTAssertTrue(first.laneReleased)
    XCTAssertFalse(first.claimReleased)
    XCTAssertTrue(first.resourceReleasePending)

    let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    XCTAssertEqual(replay.currentState, .interrupted)
    XCTAssertTrue(replay.resourceReleaseAuthorized)
    let retry = try coordinator.retryAuthorizedResourceRelease(from: replay)
    XCTAssertEqual(retry.state, .interrupted)
    XCTAssertEqual(retry.laneReleaseCount, 0)
    XCTAssertEqual(retry.claimReleaseCount, 1)
    XCTAssertTrue(retry.laneReleased)
    XCTAssertTrue(retry.claimReleased)
    XCTAssertFalse(retry.resourceReleasePending)
    XCTAssertEqual(resources.laneReleaseCount, 1)
    XCTAssertEqual(resources.claimReleaseCount, 1)
  }

  func testHazardGateExhaustsProviderUserAndDurableAuditTruthTable() {
    let hazard = UnresolvedDeviceHazard(
      code: "remote-task-unknown", summary: "fixture", severity: .blocking,
      outcomeCertainty: .outcomeUnknown)
    let gate = UnresolvedHazardPreflightGate()
    for providerAllows in [false, true] {
      for userAllows in [false, true] {
        for auditSucceeds in [false, true] {
          let audit = HazardAudit(succeeds: auditSucceeds)
          let decision = gate.evaluate(
            hazards: [hazard],
            providerAllowsOverride: providerAllows,
            userOverrideConfirmationID: userAllows ? "confirmation-1" : nil,
            auditStore: audit)
          let shouldPass = providerAllows && userAllows && auditSucceeds
          XCTAssertEqual(
            decision.disposition,
            shouldPass ? .overrideAudited(auditEventID: "audit-1") : .failedConflict)
          XCTAssertEqual(decision.deviceDispatchCount, 0)
          XCTAssertEqual(audit.callCount, providerAllows && userAllows ? 1 : 0)
        }
      }
    }
  }

  func testMacOSCrashWindowMatrixPreservesUnknownOutcomeAndZeroDeviceDispatch() throws {
    let executable = try crashFixtureExecutable()
    let windows = [
      "beforeIntent", "afterDurableIntent", "afterSyntheticSideEffectBeforeOutcome",
      "afterDurableOutcomeBeforeFinalize",
    ]
    for window in windows {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let process = Process()
      process.executableURL = executable
      process.arguments = [window, directory.path]
      try process.run()
      let ready = directory.appending(path: "ready")
      let deadline = Date().addingTimeInterval(10)
      while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
        usleep(10_000)
      }
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: ready.path), "fixture did not reach \(window)")
      Darwin.kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()

      let replay = try DurableJournalRecovery.inspect(
        url: directory.appending(path: "journal.jsonl"))
      let scanned = try XCTUnwrap(
        SessionRecoveryScanner().scan(
          UnfinishedSessionDescriptor(
            sessionID: "session-crash", jobID: "job-crash",
            journalURL: directory.appending(path: "journal.jsonl"),
            checkpointURL: directory.appending(path: "checkpoint.json"))))
      let counters = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appending(path: "counters.json"))) as? [String: Int])
      XCTAssertEqual(counters["deviceDispatchCount"], 0)
      XCTAssertEqual(counters["destructiveDispatchCount"], 0)
      XCTAssertEqual(replay.destructiveReplayCount, 0)
      XCTAssertEqual(replay.guessCompensationCount, 0)
      if window == "afterDurableIntent" || window == "afterSyntheticSideEffectBeforeOutcome" {
        XCTAssertEqual(replay.outstandingIntents.map(\.eventID), ["flash-intent"])
        XCTAssertTrue(replay.requiresRecovery)
        XCTAssertEqual(scanned.state, .waitingForRecovery)
        XCTAssertEqual(scanned.outcomeCertainty, .outcomeUnknown)
      } else {
        XCTAssertTrue(replay.outstandingIntents.isEmpty)
        XCTAssertEqual(scanned.state, .running)
        XCTAssertEqual(scanned.outcomeCertainty, .confirmed)
      }
      XCTAssertEqual(
        counters["hostSyntheticEffectCount"],
        window == "afterSyntheticSideEffectBeforeOutcome"
          || window == "afterDurableOutcomeBeforeFinalize" ? 1 : 0)
      print(
        "M1_JOURNAL_CRASH window=\(window) durable_sequences="
          + replay.events.map { String($0.sequence) }.joined(separator: ",")
          + " state=\(scanned.state.rawValue) certainty=\(scanned.outcomeCertainty.rawValue) "
          + "device_dispatch=0 destructive_dispatch=0 "
          + "replay=0 compensation=0 release=0 host_synthetic_effect="
          + String(counters["hostSyntheticEffectCount"] ?? -1))
    }
  }

  private let timestamp = "2026-07-16T00:00:00Z"

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-task-m1-003-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func descriptor(in directory: URL) -> UnfinishedSessionDescriptor {
    UnfinishedSessionDescriptor(
      sessionID: "session-1", jobID: "job-1",
      journalURL: directory.appending(path: "journal.jsonl"),
      checkpointURL: directory.appending(path: "checkpoint.json"))
  }

  private func makeJobCreated(
    sequence: Int,
    executionMode: String = "execute"
  ) throws -> JournalEvent {
    try JournalEvent.jobCreated(
      eventID: "job-created", sequence: sequence, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, executionMode: executionMode)
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

  private func writeRunningFlashJournal(
    in directory: URL,
    includeOutcome: Bool,
    outcomeCertainty: JournalOutcomeCertainty = .confirmed
  ) throws -> UnfinishedSessionDescriptor {
    let descriptor = descriptor(in: directory)
    let journal = try FileDurableJournal(url: descriptor.journalURL)
    try journal.appendAndSynchronize(try makeJobCreated(sequence: 0))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .queued, to: .preflight, reason: "fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-running", sequence: 2, sessionID: "session-1", jobID: "job-1",
        timestamp: timestamp, from: .preflight, to: .running, reason: "fixture"))
    try journal.appendAndSynchronize(makeFlashIntent(sequence: 3))
    if includeOutcome {
      try journal.appendAndSynchronize(
        makeOutcome(sequence: 4, outcomeCertainty: outcomeCertainty))
      if outcomeCertainty == .confirmed {
        try journal.appendAndSynchronize(
          JournalEvent.stateTransition(
            eventID: "to-recovery", sequence: 5, sessionID: "session-1", jobID: "job-1",
            timestamp: timestamp, from: .running, to: .waitingForRecovery,
            reason: "identity requires explicit recovery"))
      }
    }
    return descriptor
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

private final class FakeStopper: ManagedProcessStopping, @unchecked Sendable {
  private let result: ManagedProcessStopResult
  init(_ result: ManagedProcessStopResult) { self.result = result }
  func stopForRecoveryAbandonment() throws -> ManagedProcessStopResult { result }
}

private final class ResourceCounters: DeviceLaneReleasing, StorageClaimReleasing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var claimFailuresRemaining: Int
  private var laneReleased = false
  private var claimReleased = false
  private(set) var laneReleaseCount = 0
  private(set) var claimReleaseCount = 0
  init(claimFailures: Int = 0) { claimFailuresRemaining = claimFailures }
  var totalReleaseCount: Int { laneReleaseCount + claimReleaseCount }
  func ensureDeviceLaneReleased() throws -> ResourceReleaseDisposition {
    lock.lock()
    defer { lock.unlock() }
    if laneReleased { return .alreadyReleased }
    laneReleased = true
    laneReleaseCount += 1
    return .releasedNow
  }
  func ensureStorageClaimReleased() throws -> ResourceReleaseDisposition {
    lock.lock()
    defer { lock.unlock() }
    if claimFailuresRemaining > 0 {
      claimFailuresRemaining -= 1
      throw TestFault.journal
    }
    if claimReleased { return .alreadyReleased }
    claimReleased = true
    claimReleaseCount += 1
    return .releasedNow
  }
}

private final class HazardAudit: HazardOverrideAuditPersisting, @unchecked Sendable {
  private let succeeds: Bool
  private(set) var callCount = 0
  init(succeeds: Bool) { self.succeeds = succeeds }
  func persistHazardOverrideAudit(
    hazards _: [UnresolvedDeviceHazard],
    userConfirmationID _: String
  ) throws -> String {
    callCount += 1
    if !succeeds { throw TestFault.journal }
    return "audit-1"
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
