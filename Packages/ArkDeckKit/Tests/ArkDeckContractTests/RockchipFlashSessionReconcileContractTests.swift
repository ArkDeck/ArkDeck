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
  private var agentLedger: AgentAuthorityUsageLedger!

  private static let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "flash-reconcile-\(UUID().uuidString)", directoryHint: .isDirectory)
    sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    usageRoot = base.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    agentLedger = try AgentAuthorityUsageLedger(root: usageRoot)
  }

  override func tearDownWithError() throws {
    if let base { try? FileManager.default.removeItem(at: base) }
  }

  private func reconciler() -> RockchipFlashSessionReconciler {
    RockchipFlashSessionReconciler(
      sessionsRoot: sessionsRoot, agentLedger: agentLedger, now: { Self.fixedNow })
  }

  private static let timestamp = "2026-08-02T10:00:00Z"


  /// Historical standing authority. Its ledger was retired (T25/W3); the
  /// reference type survives so past journals still decode, and these
  /// sessions must still be scanned, flagged and reported.
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



  func testCleanCrashBetweenStepsIsStillFlagged() throws {
    // The dangerous quiet case: the last outcome is durable and confirmed,
    // no intent dangles, no tail is torn — yet the run is dead mid-flight.
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
    // No unresolved mutation is visible. The reservation this journal names
    // lives in the retired standing ledger, so it reports as missing — and
    // the session still requires attention rather than dropping out.
    XCTAssertEqual(finding.ledgerState, .missing(reservationID: "RES-STANDING-3"))
    XCTAssertTrue(finding.requiresAttention)
  }

  func testTornTailFlagsOutcomeUnknown() throws {
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-torn", jobID: "job-4",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-STANDING-4")
    try session.running()
    try session.tearTail()

    let finding = try XCTUnwrap(try reconciler().scan().first)
    XCTAssertTrue(finding.hasTornTail)
    // A torn tail can hide a destructive intent; it stays flagged.
    XCTAssertTrue(finding.requiresAttention)
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

    // The campaign ledger has exactly one writer; the reconciler reports and
    // never writes, so it must not have touched a byte of it.
    let agentBytesAfter = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))
    XCTAssertEqual(agentBytesBefore, agentBytesAfter)
  }


  // MARK: - Idempotence and settlement



  func testEmptySessionsRootScansClean() throws {
    XCTAssertEqual(try reconciler().scan(), [])
  }

  // MARK: - Liveness, post-terminal orphans, races (regression C1/C2/C6)

  func testLiveSessionIsExcludedFromScanAndCloseIsRefused() throws {
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

    // The kernel releases the lock on process death; releasing here flips
    // the same session straight into closable debt.
    RockchipFlashSessionRunLock.release(lock)
    XCTAssertEqual(try reconciler().scan().map(\.sessionID), ["session-live"])
  }



  // MARK: - Sessionless orphaned reservations (regression C4)


  func testSessionlessAgentReservationIsReportedWithCampaignHintAndDeferred() throws {
    let reservationID = try reserveAgent(jobID: "job-agent-orphan")
    let agentBytesBefore = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))

    let orphans = try reconciler().orphanedReservations()
    XCTAssertEqual(orphans.map(\.reservationID), [reservationID])
    let orphan = try XCTUnwrap(orphans.first)
    XCTAssertEqual(orphan.campaignID, "ECAMP-" + String(repeating: "F", count: 24))

    let agentBytesAfter = try Data(
      contentsOf: usageRoot.appending(path: AgentAuthorityUsageLedger.ledgerFileName))
    XCTAssertEqual(agentBytesBefore, agentBytesAfter, "campaign ledger keeps one writer")
  }

  func testSessionLinkedAndClosedReservationsAreNotOrphans() throws {
    // Linked-open: a session directory names the reservation, so the sweep
    // must not double-report it — the session finding owns it.
    var session = try SessionBuilder(
      sessionsRoot: sessionsRoot, sessionID: "session-linked", jobID: "job-linked",
      schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion)
    try session.jobCreated(
      authorizationRef: try standingReference(), usageReservationID: "RES-LINKED-1")
    try session.running()
    XCTAssertEqual(try reconciler().orphanedReservations(), [])
    XCTAssertEqual(try reconciler().scan().map(\.sessionID), ["session-linked"])

    // Closed reservations are settled history, never orphans.
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
  }
}
