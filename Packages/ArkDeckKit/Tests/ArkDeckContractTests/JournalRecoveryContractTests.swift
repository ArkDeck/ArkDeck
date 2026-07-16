import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Darwin
import Foundation
import XCTest

final class JournalRecoveryContractTests: XCTestCase {
  func testLockedJournalContractCoversEveryClosedEventKind() throws {
    let data = try Data(contentsOf: fixtureURL("all-event-kinds.jsonl"))
    let lines = data.split(separator: 0x0A)
    let events = try lines.map { try JournalEventCodec.decode(Data($0)) }
    XCTAssertEqual(Set(events.map(\.kind)), Set(JournalEventKind.allCases))
    for event in events {
      XCTAssertEqual(try JournalEventCodec.decode(JournalEventCodec.encode(event)), event)
    }
  }

  func testClosedCodecRejectsUnknownDuplicateMalformedAndHashMismatchVectors() throws {
    XCTAssertThrowsError(
      try JournalEventCodec.decode(Data(contentsOf: fixtureURL("unknown-kind.json"))))
    XCTAssertThrowsError(
      try JournalEventCodec.decode(Data(contentsOf: fixtureURL("duplicate-member.json")))
    ) { error in
      guard case .duplicateMemberName = error as? StrictJSONError else {
        return XCTFail("duplicate member must be identified: \(error)")
      }
    }

    let lines = try String(
      contentsOf: fixtureURL("all-event-kinds.jsonl"), encoding: .utf8
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
      let journal = try FileDurableJournal(
        url: directory.appending(path: "journal.jsonl"),
        faultInjector: DurabilityFaultInjector { observed in
          if observed == point { throw TestFault.injected(point) }
        })
      let gate = WriteAheadIntentGate(journal: journal)
      var dispatchCount = 0
      XCTAssertThrowsError(
        try gate.dispatch(intent: makeFlashIntent(sequence: 0)) { dispatchCount += 1 })
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
    print(
      "M1_RECONCILE state=\(result.state.rawValue) certainty=\(result.outcomeCertainty.rawValue) "
        + "dispatch=0 replay=0 compensation=0")
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
    XCTAssertEqual(
      successJournal.events.map(\.kind),
      [
        .abandonIntent, .stateTransition, .abandonOutcome, .stateTransition,
      ])
    print("M1_ABANDON case=success durable=\(success.durableEventSequences) lane=1 claim=1")
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

  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/JournalRecovery/\(name)")
  }

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

  private func makeJobCreated(sequence: Int) throws -> JournalEvent {
    try JournalEvent.jobCreated(
      eventID: "job-created", sequence: sequence, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, executionMode: "execute")
  }

  private func makeFlashIntent(sequence: Int) throws -> JournalEvent {
    let step = try WorkflowStep(
      id: "flash-step", kind: .flashPartition, declaredEffect: .destructive,
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
      eventID: "flash-intent", sequence: sequence, sessionID: "session-1", jobID: "job-1",
      timestamp: timestamp, step: step,
      target: JournalTarget(
        scope: "device", targetID: "device-1", connectKey: "fixture-only",
        identitySnapshotHash: String(repeating: "b", count: 64)),
      attempt: 1, bindingRevision: 1)
  }

  private func makeOutcome(sequence: Int) throws -> JournalEvent {
    try JournalEvent.stepOutcome(
      eventID: "flash-outcome-\(sequence)", sequence: sequence,
      sessionID: "session-1", jobID: "job-1", timestamp: timestamp,
      stepID: "flash-step", attempt: 1, correlatesToIntentEventID: "flash-intent",
      result: "succeeded", outcomeCertainty: .confirmed)
  }

  private func checkpoint(sequence: Int, state: JobState) throws -> JournalCheckpoint {
    try JournalCheckpoint(
      sessionID: "session-1", jobID: "job-1", journalSequence: sequence,
      state: state.rawValue, updatedAt: timestamp)
  }

  private func writeRunningFlashJournal(
    in directory: URL,
    includeOutcome: Bool
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
      try journal.appendAndSynchronize(makeOutcome(sequence: 4))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "to-recovery", sequence: 5, sessionID: "session-1", jobID: "job-1",
          timestamp: timestamp, from: .running, to: .waitingForRecovery,
          reason: "identity requires explicit recovery"))
    }
    return descriptor
  }

  private func abandonmentRequest() -> RecoveryAbandonmentRequest {
    RecoveryAbandonmentRequest(
      sessionID: "session-1", jobID: "job-1", nextSequence: 10,
      userConfirmationID: "confirmation-1", lastConfirmedStepID: "step-1",
      outcomeCertainty: .outcomeUnknown, managedProcessState: "runningInterruptible",
      deviceHazards: ["remote-task-unknown"])
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
  private(set) var laneReleaseCount = 0
  private(set) var claimReleaseCount = 0
  var totalReleaseCount: Int { laneReleaseCount + claimReleaseCount }
  func releaseDeviceLane() throws {
    lock.lock()
    laneReleaseCount += 1
    lock.unlock()
  }
  func releaseStorageClaim() throws {
    lock.lock()
    claimReleaseCount += 1
    lock.unlock()
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
