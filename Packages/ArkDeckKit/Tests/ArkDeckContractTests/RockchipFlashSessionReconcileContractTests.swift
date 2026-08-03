import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The flash session journal used to be write-only: nothing ever replayed it
/// after a crash, and an interrupted standing-authorization run left an open
/// usage reservation forever. These tests pin the read side: unresolved
/// sessions are found from the durable journal alone, orphaned
/// standing-authorization reservations close with an honest terminal that
/// names the dangling destructive intents, and campaign-lane sessions are
/// reported but never closed here (the campaign ledger has one writer).
final class RockchipFlashSessionReconcileContractTests: XCTestCase {

  // MARK: - Fixture plumbing

  private var base: URL!
  private var sessionsRoot: URL!
  private var usageRoot: URL!
  private var standingLedger: AuthorizationUsageLedger!
  private var agentLedger: AgentAuthorityUsageLedger!

  private static let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "flash-reconcile-\(UUID().uuidString)", directoryHint: .isDirectory)
    sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    usageRoot = base.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    standingLedger = try AuthorizationUsageLedger(root: usageRoot)
    agentLedger = try AgentAuthorityUsageLedger(root: usageRoot)
  }

  override func tearDownWithError() throws {
    if let base { try? FileManager.default.removeItem(at: base) }
  }

  private func reconciler() -> RockchipFlashSessionReconciler {
    RockchipFlashSessionReconciler(
      sessionsRoot: sessionsRoot, standingLedger: standingLedger, agentLedger: agentLedger,
      now: { Self.fixedNow })
  }

  private static let timestamp = "2026-08-02T10:00:00Z"

  private func standingReference() throws -> AuthorizationReference {
    try AuthorizationReference(
      authorizationID: "AUTH-2026-025-DAYU200-777",
      mainCommitOID: String(repeating: "a", count: 40),
      authorizationBlobOID: String(repeating: "b", count: 40),
      approvalPRNumber: 700)
  }

  private func campaignReference() -> AgentExecutionAuthorityReference {
    .evolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "f", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "b", count: 64),
      archiveDigestSHA256: String(repeating: "c", count: 64),
      stepSetDigestSHA256: String(repeating: "d", count: 64),
      targetStableIdentitySHA256: String(repeating: "e", count: 64),
      bindingLineageRootRevision: 1,
      confirmedAt: Self.timestamp,
      validUntil: "2026-08-02T14:00:00Z",
      maximumAttempts: 8)
  }

  private func flashStep(id: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: id, kind: .flashPartition, declaredEffect: .destructive,
      declaredCancellation: .criticalNonInterruptible,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "providerOperationId": .string("fixtureFlash"),
        "partition": .string("system"),
        "imageArtifactId": .string("image-1"),
        "imageSha256": .string(String(repeating: "c", count: 64)),
        "imageSize": .integer(1),
        "confirmationId": .string("confirmation-1"),
        "safeBoundaryId": .string("boundary-1"),
      ])
  }

  /// Writes journal events exactly the way the flash host's persistence
  /// does: same factories, same schema versions, sequential from zero.
  private struct SessionBuilder {
    let root: URL
    let journal: FileDurableJournal
    let sessionID: String
    let jobID: String
    let schemaVersion: String
    var sequence = 0

    init(sessionsRoot: URL, sessionID: String, jobID: String, schemaVersion: String) throws {
      self.sessionID = sessionID
      self.jobID = jobID
      self.schemaVersion = schemaVersion
      root = sessionsRoot.appending(path: sessionID, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      journal = try FileDurableJournal(url: root.appending(path: "journal.jsonl"))
    }

    mutating func append(_ event: JournalEvent) throws {
      try journal.appendAndSynchronize(event)
      sequence += 1
    }

    mutating func jobCreated(
      authorizationRef: AuthorizationReference? = nil,
      agentAuthorizationRef: AgentExecutionAuthorityReference? = nil,
      usageReservationID: String? = nil
    ) throws {
      try append(
        JournalEvent.jobCreated(
          eventID: "evt-created", sequence: sequence, sessionID: sessionID, jobID: jobID,
          timestamp: RockchipFlashSessionReconcileContractTests.timestamp,
          executionMode: "execute", executionAuthority: "authorizedAgent",
          coreBaseline: "CORE-2.0.0", schemaVersion: schemaVersion,
          authorizationRef: authorizationRef, agentAuthorizationRef: agentAuthorizationRef,
          usageReservationID: usageReservationID))
    }

    mutating func transition(_ from: JobState, _ to: JobState, eventID: String) throws {
      try append(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
          timestamp: RockchipFlashSessionReconcileContractTests.timestamp,
          from: from, to: to, reason: "fixture", schemaVersion: schemaVersion))
    }

    mutating func running() throws {
      try transition(.queued, .preflight, eventID: "evt-preflight")
      try transition(.preflight, .running, eventID: "evt-running")
    }

    mutating func intent(
      _ step: WorkflowStep,
      eventID: String,
      authorizationRef: AuthorizationReference? = nil,
      agentAuthorizationRef: AgentExecutionAuthorityReference? = nil,
      usageReservationID: String? = nil
    ) throws {
      try append(
        JournalEvent.stepIntent(
          eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
          timestamp: RockchipFlashSessionReconcileContractTests.timestamp,
          step: step,
          target: JournalTarget(
            scope: "device", targetID: "TGT-DAYU200-01", connectKey: "fixture-usb",
            identitySnapshotHash: String(repeating: "e", count: 64)),
          attempt: 1, bindingRevision: 1, schemaVersion: schemaVersion,
          authorizationRef: authorizationRef, agentAuthorizationRef: agentAuthorizationRef,
          usageReservationID: usageReservationID))
    }

    mutating func outcome(
      stepID: String, intentEventID: String, eventID: String,
      certainty: JournalOutcomeCertainty = .confirmed,
      authorizationRef: AuthorizationReference? = nil,
      agentAuthorizationRef: AgentExecutionAuthorityReference? = nil,
      usageReservationID: String? = nil
    ) throws {
      try append(
        JournalEvent.stepOutcome(
          eventID: eventID, sequence: sequence, sessionID: sessionID, jobID: jobID,
          timestamp: RockchipFlashSessionReconcileContractTests.timestamp,
          stepID: stepID, attempt: 1, correlatesToIntentEventID: intentEventID,
          result: certainty == .confirmed ? "succeeded" : "failed",
          outcomeCertainty: certainty, schemaVersion: schemaVersion,
          authorizationRef: authorizationRef,
          agentAuthorizationRef: agentAuthorizationRef,
          usageReservationID: usageReservationID))
    }

    mutating func finalized() throws {
      try transition(.running, .finalizing, eventID: "evt-finalizing")
      try transition(.finalizing, .succeeded, eventID: "evt-succeeded")
      try append(
        JournalEvent(
          schemaVersion: schemaVersion,
          eventID: "evt-finalized", sequence: sequence, sessionID: sessionID, jobID: jobID,
          timestamp: RockchipFlashSessionReconcileContractTests.timestamp, kind: .finalized,
          payload: [
            "terminalStatus": .string("succeeded"),
            "manifestSha256": .string(String(repeating: "9", count: 64)),
            "outcomeCertainty": .string("confirmed"),
          ]))
    }

    func tearTail() throws {
      let handle = try FileHandle(forWritingTo: root.appending(path: "journal.jsonl"))
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("{\"schemaVersion\":\"2.1".utf8))
    }
  }

  private func reserveStanding(_ reservationID: String, jobID: String) throws {
    _ = try standingLedger.reserve(
      AuthorizationUsageReservation(
        reservationID: reservationID, authorizationRef: try standingReference(), ordinal: 1,
        maxRuns: 1, jobID: jobID,
        planDigestSHA256: String(repeating: "1", count: 64),
        targetDigestSHA256: String(repeating: "2", count: 64),
        reservedAt: Self.timestamp, terminal: nil))
  }

  /// Agent reservation IDs are canonical derivations; mint the real one.
  private func reserveAgent(jobID: String) throws -> String {
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: campaignReference(), jobID: jobID,
      operationDigestSHA256: String(repeating: "3", count: 64),
      targetDigestSHA256: String(repeating: "4", count: 64))
    _ = try agentLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: reservationID, authorizationRef: campaignReference(), ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: jobID,
        operationDigestSHA256: String(repeating: "3", count: 64),
        targetDigestSHA256: String(repeating: "4", count: 64),
        reservedAt: Self.timestamp,
        forwardLeaseExpiresAt: "2026-08-02T14:00:00Z",
        compensationLeaseExpiresAt: "2026-08-02T15:00:00Z",
        terminal: nil))
    return reservationID
  }

  // MARK: - Finding unresolved sessions

  func testDanglingDestructiveIntentClosesOutcomeUnknownWithIntentEventID() throws {
    try reserveStanding("RES-STANDING-1", jobID: "job-1")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-dangling", jobID: "job-1",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-1")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-intent-system",
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-1")

    let findings = try reconciler().scan()
    XCTAssertEqual(findings.map(\.sessionID), ["session-dangling"])
    let finding = try XCTUnwrap(findings.first)
    XCTAssertEqual(finding.lane, .standingAuthorization)
    XCTAssertEqual(finding.currentState, .running)
    XCTAssertEqual(finding.outstandingIntents.map(\.eventID), ["evt-intent-system"])
    XCTAssertEqual(
      finding.ledgerState, .openStandingReservation(reservationID: "RES-STANDING-1"))

    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-STANDING-1", status: .outcomeUnknown))
    let reservation = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-STANDING-1" })
    let terminal = try XCTUnwrap(reservation.terminal)
    XCTAssertEqual(terminal.status, .outcomeUnknown)
    XCTAssertEqual(terminal.destructiveIntentEventIDs, ["evt-intent-system"])
  }

  func testCrashBeforeFirstIntentClosesInterrupted() throws {
    try reserveStanding("RES-STANDING-2", jobID: "job-2")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-early-crash", jobID: "job-2",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-2")
    try session.transition(.queued, .preflight, eventID: "evt-preflight")

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertTrue(finding.outstandingIntents.isEmpty)

    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-STANDING-2", status: .interrupted))
    let terminal = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-STANDING-2" }?
        .terminal)
    XCTAssertEqual(terminal.status, .interrupted)
    XCTAssertEqual(terminal.destructiveIntentEventIDs, [])
  }

  func testCleanCrashBetweenStepsIsStillFlagged() throws {
    // The dangerous quiet case: the last outcome is durable and confirmed,
    // no intent dangles, no tail is torn — yet the run is dead mid-flight.
    try reserveStanding("RES-STANDING-3", jobID: "job-3")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-between-steps", jobID: "job-3",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-3")
    try session.running()
    try session.intent(
      try flashStep(id: "write-uboot"), eventID: "evt-intent-uboot",
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-3")
    try session.outcome(
      stepID: "write-uboot", intentEventID: "evt-intent-uboot", eventID: "evt-outcome-uboot",
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-3")

    let findings = try reconciler().scan()
    XCTAssertEqual(findings.map(\.sessionID), ["session-between-steps"])
    let finding = try XCTUnwrap(findings.first)
    XCTAssertTrue(finding.outstandingIntents.isEmpty)
    XCTAssertFalse(finding.hasTornTail)
    XCTAssertEqual(finding.lastConfirmedStepID, "write-uboot")
    // No unresolved mutation is visible, so the honest terminal is
    // `interrupted` — the ordinal is still consumed.
    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-STANDING-3", status: .interrupted))
  }

  func testTornTailFlagsOutcomeUnknown() throws {
    try reserveStanding("RES-STANDING-4", jobID: "job-4")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-torn", jobID: "job-4",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-4")
    try session.running()
    try session.tearTail()

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertTrue(finding.hasTornTail)
    // A torn tail can hide a destructive intent; fail closed.
    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-STANDING-4", status: .outcomeUnknown))
  }

  func testFinalizedSessionIsNotFlagged() throws {
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-finalized", jobID: "job-5",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-DONE")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-intent",
      authorizationRef: try standingReference(), usageReservationID: "RES-DONE")
    try session.outcome(
      stepID: "write-system", intentEventID: "evt-intent", eventID: "evt-out",
      authorizationRef: try standingReference(), usageReservationID: "RES-DONE")
    try session.finalized()

    XCTAssertEqual(try reconciler().scan(), [])
    // Forensic inspection still works for resolved sessions.
    let finding = try reconciler().inspect(sessionID: "session-finalized")
    XCTAssertTrue(finding.finalized)
    XCTAssertFalse(finding.requiresAttention)
  }

  // MARK: - Authority lanes

  func testCampaignLaneIsReportedButClosureIsDeferred() throws {
    let reservationID = try reserveAgent(jobID: "job-6")
    let agentBytesBefore = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-campaign", jobID: "job-6",
      schemaVersion: JournalEvent.agentAuthoritySchemaVersion)
    try session.jobCreated(
      agentAuthorizationRef: campaignReference(), usageReservationID: reservationID)
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-intent-campaign",
      agentAuthorizationRef: campaignReference(), usageReservationID: reservationID)

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertEqual(finding.lane, .agentCampaign)
    XCTAssertEqual(finding.campaignID, "ECAMP-" + String(repeating: "F", count: 24))
    XCTAssertEqual(finding.ledgerState, .openAgentReservation(reservationID: reservationID))

    let closure = try reconciler().close(finding)
    XCTAssertEqual(closure.disposition, .agentLaneDeferred(reservationID: reservationID))
    // The campaign ledger has exactly one writer; the reconciler must not
    // have touched a byte of it.
    let agentBytesAfter = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))
    XCTAssertEqual(agentBytesBefore, agentBytesAfter)
  }

  func testJournalNamingAMissingReservationHasNothingToClose() throws {
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-missing-res", jobID: "job-7",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-NEVER-WRITTEN")
    try session.running()

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertEqual(finding.ledgerState, .missing(reservationID: "RES-NEVER-WRITTEN"))
    XCTAssertEqual(
      try reconciler().close(finding).disposition, .nothingToClose)
  }

  // MARK: - Idempotence and settlement

  func testCloseIsIdempotentAndSettledSessionsDropOutOfScan() throws {
    try reserveStanding("RES-STANDING-8", jobID: "job-8")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-settle", jobID: "job-8",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-8")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-intent-8",
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-8")

    let finding = try XCTUnwrap(try reconciler().scan().first)
    let first = try reconciler().close(finding)
    // Retrying against the pre-closure finding is safe: the derived
    // terminal is deterministic, so the ledger accepts the byte-identical
    // retry instead of conflicting.
    let second = try reconciler().close(finding)
    XCTAssertEqual(first, second)

    // The authority record is settled: the session no longer demands
    // attention, and a fresh inspection reports the closed state.
    XCTAssertEqual(try reconciler().scan(), [])
    let settled = try reconciler().inspect(sessionID: "session-settle")
    XCTAssertEqual(settled.ledgerState, .closed(reservationID: "RES-STANDING-8"))
    XCTAssertEqual(
      try reconciler().close(settled).disposition,
      .alreadyClosed(reservationID: "RES-STANDING-8"))
  }

  func testUnknownOutcomeIntentIsCarriedIntoTheTerminal() throws {
    // A live process that wrote an explicitly unknown outcome and then
    // died: the intent is not dangling, but its outcome is unknown — the
    // terminal must still name it.
    try reserveStanding("RES-STANDING-9", jobID: "job-9")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-unknown-outcome", jobID: "job-9",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-9")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-intent-9",
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-9")
    try session.outcome(
      stepID: "write-system", intentEventID: "evt-intent-9", eventID: "evt-out-9",
      certainty: .outcomeUnknown,
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-9")
    try session.transition(.running, .waitingForRecovery, eventID: "evt-park")

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertEqual(finding.currentState, .waitingForRecovery)
    XCTAssertEqual(finding.unknownOutcomes.map(\.correlatedIntentEventID), ["evt-intent-9"])

    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-STANDING-9", status: .outcomeUnknown))
    let terminal = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-STANDING-9" }?
        .terminal)
    XCTAssertEqual(terminal.destructiveIntentEventIDs, ["evt-intent-9"])
  }

  func testEmptySessionsRootScansClean() throws {
    XCTAssertEqual(try reconciler().scan(), [])
  }

  // MARK: - Liveness, post-terminal orphans, races (adversarial review C1/C2/C6)

  func testLiveSessionIsExcludedFromScanAndCloseIsRefused() throws {
    try reserveStanding("RES-LIVE-1", jobID: "job-live")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-live", jobID: "job-live",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-LIVE-1")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-live-intent",
      authorizationRef: try standingReference(), usageReservationID: "RES-LIVE-1")

    // Simulate the executor's whole-run lock: while held, the dangling
    // intent is a run in progress, not debt.
    let lock = try RockchipFlashSessionRunLock.acquire(sessionRoot: session.root)
    XCTAssertEqual(try reconciler().scan(), [])
    let live = try reconciler().inspect(sessionID: "session-live")
    XCTAssertTrue(live.isLive)
    XCTAssertFalse(live.requiresAttention)
    XCTAssertEqual(try reconciler().close(live).disposition, .sessionLive)
    let untouched = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-LIVE-1" })
    XCTAssertNil(untouched.terminal, "a live run's reservation must never be closed")

    // The kernel releases the lock on process death; releasing here flips
    // the same session straight into closable debt.
    RockchipFlashSessionRunLock.release(lock)
    XCTAssertEqual(try reconciler().scan().map(\.sessionID), ["session-live"])
  }

  func testTerminalSucceededJournalWithOpenReservationClosesSucceeded() throws {
    // Crash window between the durable `finalized` event and closeUsage:
    // the journal proves success, the reservation is still open. The
    // reconciler completes the dead process's own pending write.
    try reserveStanding("RES-TERM-1", jobID: "job-term")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-terminal-open", jobID: "job-term",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-TERM-1")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-term-intent",
      authorizationRef: try standingReference(), usageReservationID: "RES-TERM-1")
    try session.outcome(
      stepID: "write-system", intentEventID: "evt-term-intent", eventID: "evt-term-out",
      authorizationRef: try standingReference(), usageReservationID: "RES-TERM-1")
    try session.finalized()

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertTrue(finding.terminalWithOpenAuthority)
    XCTAssertFalse(finding.journalUnresolved)
    XCTAssertEqual(finding.confirmedMutationIntentEventIDs, ["evt-term-intent"])

    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition,
      .closedStandingReservation(reservationID: "RES-TERM-1", status: .succeeded))
    let terminal = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-TERM-1" }?
        .terminal)
    XCTAssertEqual(terminal.status, .succeeded)
    XCTAssertEqual(terminal.destructiveIntentEventIDs, ["evt-term-intent"])
    // Settled: authority closed, so the session drops out of scan.
    XCTAssertEqual(try reconciler().scan(), [])
  }

  func testCloseRaceAgainstAnotherTerminalSettlesAsAlreadyClosed() throws {
    try reserveStanding("RES-RACE-1", jobID: "job-race")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-race", jobID: "job-race",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-RACE-1")
    try session.running()
    try session.intent(
      try flashStep(id: "write-system"), eventID: "evt-race-intent",
      authorizationRef: try standingReference(), usageReservationID: "RES-RACE-1")

    let finding = try XCTUnwrap(try reconciler().scan().first)
    // Another closer (the dying process, or a concurrent reconcile) wins
    // the write-once terminal between our scan and our close.
    _ = try standingLedger.close(
      reservationID: "RES-RACE-1",
      terminal: AuthorizationUsageTerminal(
        status: .failed, closedAt: "2026-08-02T10:30:00Z",
        destructiveIntentEventIDs: ["evt-race-intent"]))

    let closure = try reconciler().close(finding)
    XCTAssertEqual(
      closure.disposition, .alreadyClosed(reservationID: "RES-RACE-1"))
    let terminal = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-RACE-1" }?
        .terminal)
    XCTAssertEqual(terminal.status, .failed, "the racing writer's truth stands")
  }

  // MARK: - Sessionless orphaned reservations (adversarial review C4)

  func testSessionlessStandingReservationIsSweptAndClosesFailClosed() throws {
    // The session directory is gone (GC, disk-space move, crash before the
    // journal survived); only the open reservation remains. The session
    // scan is blind here by construction — the ledger sweep is not.
    try reserveStanding("RES-ORPHAN-1", jobID: "job-orphan")
    XCTAssertEqual(try reconciler().scan(), [])

    let orphans = try reconciler().orphanedReservations()
    XCTAssertEqual(orphans.map(\.reservationID), ["RES-ORPHAN-1"])
    let orphan = try XCTUnwrap(orphans.first)
    XCTAssertEqual(orphan.lane, .standingAuthorization)

    let closure = try reconciler().closeOrphan(orphan)
    XCTAssertEqual(
      closure.disposition, .closedStandingReservation(reservationID: "RES-ORPHAN-1"))
    let terminal = try XCTUnwrap(
      standingLedger.load().reservations.first { $0.reservationID == "RES-ORPHAN-1" }?
        .terminal)
    XCTAssertEqual(terminal.status, .outcomeUnknown)
    XCTAssertEqual(
      terminal.destructiveIntentEventIDs, [],
      "no journal survives, so no intent may be claimed")
    XCTAssertEqual(try reconciler().orphanedReservations(), [])
    // Retry against the stale orphan value derives a byte-identical
    // terminal, which the write-once ledger accepts idempotently.
    XCTAssertEqual(
      try reconciler().closeOrphan(orphan).disposition,
      .closedStandingReservation(reservationID: "RES-ORPHAN-1"))
  }

  func testSessionlessAgentReservationIsReportedWithCampaignHintAndDeferred() throws {
    let reservationID = try reserveAgent(jobID: "job-agent-orphan")
    let agentBytesBefore = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))

    let orphans = try reconciler().orphanedReservations()
    XCTAssertEqual(orphans.map(\.reservationID), [reservationID])
    let orphan = try XCTUnwrap(orphans.first)
    XCTAssertEqual(orphan.lane, .agentCampaign)
    XCTAssertEqual(orphan.campaignID, "ECAMP-" + String(repeating: "F", count: 24))

    XCTAssertEqual(
      try reconciler().closeOrphan(orphan).disposition,
      .agentLaneDeferred(reservationID: reservationID))
    let agentBytesAfter = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))
    XCTAssertEqual(agentBytesBefore, agentBytesAfter, "campaign ledger keeps one writer")
  }

  func testSessionLinkedAndClosedReservationsAreNotOrphans() throws {
    // Linked-open: a session directory names the reservation, so the sweep
    // must not double-report it — the session finding owns it.
    try reserveStanding("RES-LINKED-1", jobID: "job-linked")
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-linked", jobID: "job-linked",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-LINKED-1")
    try session.running()
    XCTAssertEqual(try reconciler().orphanedReservations(), [])
    XCTAssertEqual(try reconciler().scan().map(\.sessionID), ["session-linked"])

    // Closed reservations are settled history, never orphans.
    let finding = try XCTUnwrap(try reconciler().scan().first)
    _ = try reconciler().close(finding)
    XCTAssertEqual(try reconciler().orphanedReservations(), [])
  }

  func testUndecodableJournalSurfacesAsFailClosedFinding() throws {
    // A complete-but-garbage line is beyond the torn-tail repair the
    // format tolerates. Regressing this path to a silent skip would be
    // fail-open: the session would vanish from the report entirely.
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-corrupt", jobID: "job-corrupt",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-CORRUPT-1")
    let handle = try FileHandle(forWritingTo: session.root.appending(path: "journal.jsonl"))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"not\":\"a journal event\"}\n".utf8))

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertNotNil(finding.journalError)
    XCTAssertTrue(finding.requiresAttention)
    XCTAssertEqual(try reconciler().close(finding).disposition, .nothingToClose)
  }
}
