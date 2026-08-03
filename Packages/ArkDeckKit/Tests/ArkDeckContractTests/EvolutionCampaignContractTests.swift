import Foundation
import XCTest

@testable import ArkDeckHarness
@testable import ArkDeckStorage
@testable import ArkDeckAgentComposition
@testable import ArkDeckWorkflows

final class EvolutionCampaignContractTests: XCTestCase {
  private static let confirmedAt = "2026-08-02T08:00:00Z"
  private static let validUntil = "2026-08-02T12:00:00Z"
  private static let targetDigest = String(repeating: "a", count: 64)

  func testFlashCLIDefaultsToCampaignAndRemovesLegacySelectors() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    for subcommand in ["preview", "execute", "continue", "status"] {
      XCTAssertTrue(source.contains("case \"\(subcommand)\":"))
    }
    for obsolete in [
      "case \"evolution-preview\":", "case \"evolution-execute\":",
      "case \"evolution-continue\":", "case \"evolution-status\":",
      "--chat-confirmation-digest-sha256", "--chat-confirmed-plan-sha256",
      "case \"binding-preview\":", "case \"rebind-binding\":",
    ] {
      XCTAssertFalse(source.contains(obsolete), "obsolete CLI surface remains: \(obsolete)")
    }
    XCTAssertTrue(source.contains("--campaign-confirmation-digest-sha256"))

    let taskCLI = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift"),
      encoding: .utf8)
    XCTAssertTrue(taskCLI.contains("params[\"workspaceAllowedPaths\"]"))
    XCTAssertTrue(taskCLI.contains("params[\"workspaceAllowedOperations\"]"))
    XCTAssertFalse(taskCLI.contains("params[\"evolutionAllowedOperations\"]"))

    let authoritySource = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckStorage/AuthorizationUsageLedger.swift"),
      encoding: .utf8)
    XCTAssertFalse(
      authoritySource.contains("public static func validatedChatConfirmation"),
      "historical chat authority must not retain a public creation factory")
  }

  func testLegacyCLISurfacesFailClosedBeforeRuntimeOrDeviceAccess() throws {
    let obsoleteInvocations = [
      ["flash", "evolution-status", "--campaign-id", "ECAMP-obsolete"],
      ["flash", "execute", "--chat-confirmation-digest-sha256", digest("a")],
      [
        "task", "submit", "--target", "device", "--goal", "repair",
        "--execution-mode", "evolution",
      ],
      [
        "task", "submit", "--target", "device", "--goal", "repair",
        "--evolution-allowed-paths", "Sources/**",
      ],
    ]
    for arguments in obsoleteInvocations {
      let result = try runCLI(arguments)
      XCTAssertEqual(result.status, 64, "\(arguments): \(result.output)")
    }
  }

  func testTaskPromotionCLIExportsOverTheTaskPlaneAndFailsClosedWithoutATask() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let taskCLI = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift"),
      encoding: .utf8)
    // The exporter is a thin task-plane client: it calls task.promotion and
    // writes the daemon-rendered bundle; it re-verifies the patch digest and
    // never overwrites what a maintainer already has.
    XCTAssertTrue(taskCLI.contains("case \"promotion\":"))
    XCTAssertTrue(taskCLI.contains("method: \"task.promotion\""))
    XCTAssertTrue(taskCLI.contains("refusing to overwrite existing"))
    XCTAssertTrue(taskCLI.contains("refusing to write final.patch"))

    let missingTask = try runCLI(["task", "promotion"])
    XCTAssertEqual(missingTask.status, 64, missingTask.output)
    XCTAssertTrue(missingTask.output.contains("--task"), missingTask.output)
  }

  func testProductCandidateToolchainProbeUsesIdentityBoundSwiftPMRole() async throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let first =
      try await ProductRockchipEvolutionCandidateBuilder.currentToolchainDigest(
        sourceRoot: repositoryRoot)
    let second =
      try await ProductRockchipEvolutionCandidateBuilder.currentToolchainDigest(
        sourceRoot: repositoryRoot)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 64)
    XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  func testConfirmationIsClosedExactAndHardBoundedToSixteenAttemptsFourHoursOneConcurrency()
    throws
  {
    let assertion = try makeAssertion()
    XCTAssertEqual(assertion.maxAttempts, 16)
    XCTAssertEqual(assertion.maximumConcurrentAttempts, 1)
    XCTAssertEqual(assertion.userdataImpact, "ERASE-USERDATA")
    XCTAssertFalse(assertion.isValid(at: "2026-08-02T07:59:59Z"))
    XCTAssertTrue(assertion.isValid(at: Self.confirmedAt))
    XCTAssertEqual(
      assertion.allowedPaths,
      [
        "Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/**"
      ])
    XCTAssertEqual(try assertion.authorityReference().kind, .evolutionCampaignConfirmation)
    XCTAssertEqual(
      try JSONDecoder().decode(
        RockchipEvolutionCampaignConfirmationAssertion.self,
        from: JSONEncoder().encode(assertion)), assertion)

    XCTAssertThrowsError(try makeAssertion(maxAttempts: 17))
    XCTAssertThrowsError(
      try makeAssertion(validUntil: "2026-08-02T12:00:01Z"))

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(assertion)) as? [String: Any])
    object["argv"] = ["wlx", "system", "/tmp/system.img"]
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionCampaignConfirmationAssertion.self,
        from: JSONSerialization.data(withJSONObject: object)))

    let oldChat = try historicalChatAuthority(
      confirmationDigestSHA256: digest("b"), planDigestSHA256: digest("c"),
      archiveDigestSHA256: digest("d"), stepSetDigestSHA256: digest("e"),
      targetDigestSHA256: digest("f"), confirmedAt: Self.confirmedAt)
    XCTAssertEqual(oldChat.kind, .chatConfirmation)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(oldChat), as: UTF8.self)
        .contains("evolutionCampaignConfirmation"))

    let reference = try assertion.authorityReference()
    let event = try JournalEvent.jobCreated(
      eventID: "campaign-created", sequence: 0, sessionID: "session-campaign",
      jobID: "job-campaign", timestamp: Self.confirmedAt,
      executionMode: "execute", executionAuthority: "authorizedAgent",
      schemaVersion: JournalEvent.agentAuthoritySchemaVersion,
      agentAuthorizationRef: reference, usageReservationID: "reservation-campaign")
    let roundTrippedEvent = try JournalEventCodec.decode(JournalEventCodec.encode(event))
    XCTAssertEqual(roundTrippedEvent.agentExecutionAuthorityReference, reference)
    XCTAssertEqual(roundTrippedEvent.usageReservationID, "reservation-campaign")
  }

  private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    let output = Pipe()
    process.executableURL = packageRoot.appending(path: ".build/debug/arkdeck")
    process.arguments = arguments
    process.standardInput = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  func testCampaignLedgerAllowsExactlySixteenSerialSafeAttemptsAndRejectsSeventeenthOrConcurrent()
    throws
  {
    let root = temporaryDirectory("campaign-sixteen")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root)
    let assertion = try makeAssertion()
    _ = try ledger.create(assertion)

    for ordinal in 1...16 {
      let pins = try makePins(assertion: assertion, ordinal: ordinal)
      _ = try ledger.appendCandidate(
        campaignID: assertion.campaignID, candidate: pins.candidate,
        review: pins.review, at: Self.confirmedAt)
      _ = try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: pins.candidate.candidateID,
        reviewID: pins.review.reviewID, ordinal: ordinal,
        reservationID: "reservation-\(ordinal)", jobID: "job-\(ordinal)",
        sessionID: "session-\(ordinal)", at: Self.confirmedAt)

      let contender = try makePins(assertion: assertion, ordinal: 100 + ordinal)
      XCTAssertThrowsError(
        try ledger.appendCandidate(
          campaignID: assertion.campaignID, candidate: contender.candidate,
          review: contender.review, at: Self.confirmedAt),
        "an active attempt must block a concurrent candidate/attempt")

      _ = try ledger.closeAttempt(
        campaignID: assertion.campaignID, ordinal: ordinal,
        jobID: "job-\(ordinal)", sessionID: "session-\(ordinal)",
        disposition: .safeToReflash, destructiveIntentEventIDs: [],
        at: Self.confirmedAt)
    }

    let seventeenth = try makePins(assertion: assertion, ordinal: 17)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: seventeenth.candidate,
      review: seventeenth.review, at: Self.confirmedAt)
    XCTAssertThrowsError(
      try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: seventeenth.candidate.candidateID,
        reviewID: seventeenth.review.reviewID, ordinal: 17,
        reservationID: "reservation-17",
        jobID: "job-17", sessionID: "session-17", at: Self.confirmedAt))
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(document.reservedAttemptCount, 16)
    XCTAssertNil(document.activeReservation)
    XCTAssertEqual(document.events.filter { $0.kind == .attemptReserved }.count, 16)
    XCTAssertEqual(Set(document.events.compactMap(\.jobID)).count, 16)
    XCTAssertEqual(Set(document.events.compactMap(\.sessionID)).count, 16)
  }

  func testGlobalUsageLedgerMetersSixteenAndSerializesOneTarget() throws {
    let root = temporaryDirectory("campaign-usage")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try AgentAuthorityUsageLedger(root: root)
    let reference = try makeAssertion().authorityReference()

    for ordinal in 1...16 {
      let reservation = try usageReservation(
        reference: reference, ordinal: ordinal, jobID: "job-usage-\(ordinal)")
      _ = try ledger.reserve(reservation)
      if ordinal == 1 {
        XCTAssertThrowsError(
          try ledger.reserve(
            usageReservation(reference: reference, ordinal: 2, jobID: "job-concurrent")))
      }
      _ = try ledger.close(
        reservationID: reservation.reservationID,
        terminal: AgentAuthorityUsageTerminal(
          status: .failed, closedAt: Self.confirmedAt,
          externalIntentEventIDs: []))
    }
    XCTAssertThrowsError(
      try ledger.reserve(
        usageReservation(reference: reference, ordinal: 17, jobID: "job-usage-17")))
    XCTAssertEqual(try ledger.load().reservations.count, 16)
  }

  func testSuccessUnknownAndUnsafePartialPermanentlyStopCampaign() throws {
    for (index, disposition) in [
      RockchipEvolutionAttemptDisposition.succeeded,
      .outcomeUnknown,
      .unsafePartial,
    ].enumerated() {
      let root = temporaryDirectory("campaign-terminal-\(index)")
      defer { try? FileManager.default.removeItem(at: root) }
      let ledger = try RockchipEvolutionCampaignLedger(root: root)
      let assertion = try makeAssertion(seed: Character(String(index + 1)))
      let pins = try makePins(assertion: assertion, ordinal: 1)
      _ = try ledger.create(assertion)
      _ = try ledger.appendCandidate(
        campaignID: assertion.campaignID, candidate: pins.candidate,
        review: pins.review, at: Self.confirmedAt)
      _ = try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: pins.candidate.candidateID,
        reviewID: pins.review.reviewID, ordinal: 1, reservationID: "reservation-1",
        jobID: "job-1", sessionID: "session-1", at: Self.confirmedAt)
      _ = try ledger.closeAttempt(
        campaignID: assertion.campaignID, ordinal: 1, jobID: "job-1",
        sessionID: "session-1", disposition: disposition,
        destructiveIntentEventIDs: disposition == .succeeded ? [] : ["intent-1"],
        at: Self.confirmedAt)
      XCTAssertTrue(try ledger.load(assertion.campaignID).isTerminal)
      XCTAssertThrowsError(
        try ledger.appendCandidate(
          campaignID: assertion.campaignID, candidate: pins.candidate,
          review: pins.review, at: Self.confirmedAt))
    }
  }

  func testOrphanedGlobalReservationPermanentlyStopsBeforeLiveFactCollection() async throws {
    let root = temporaryDirectory("campaign-orphan")
    defer { try? FileManager.default.removeItem(at: root) }
    let campaignLedger = try RockchipEvolutionCampaignLedger(
      root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion()
    let pins = try makePins(assertion: assertion, ordinal: 1)
    _ = try campaignLedger.create(assertion)
    _ = try campaignLedger.appendCandidate(
      campaignID: assertion.campaignID, candidate: pins.candidate,
      review: pins.review, at: Self.confirmedAt)
    let reference = try assertion.authorityReference()
    _ = try usageLedger.reserve(
      usageReservation(reference: reference, ordinal: 1, jobID: "job-orphan"))

    let service = RockchipEvolutionCampaignAdmissionService(
      factCollector: RejectingEvolutionFacts(), usageLedger: usageLedger,
      campaignLedger: campaignLedger,
      clock: FixedEvolutionClock(
        reading: RockchipTrustedClockReading(
          monotonicNanoseconds: 100, auditTimestamp: Self.confirmedAt)),
      bindingSerialDigestSHA256: Self.targetDigest, bindingRevision: 1,
      brokerExecutableDigest: { assertion.brokerExecutableDigestSHA256 })
    let permit = try RockchipEvolutionCampaignAttemptPermit(
      assertion: assertion, candidate: pins.candidate, review: pins.review)
    do {
      _ = try await service.admit(
        permit: permit,
        facts: RockchipAuthorizationFactRequest(
          archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
          sessionID: "session-next", jobID: "job-next", targetID: "target-next",
          targetLocationSelector: "42"),
        sessionID: "session-next", startingMode: .loader)
      XCTFail("orphaned global use must stop before live fact collection")
    } catch let error as RockchipEvolutionCampaignError {
      XCTAssertEqual(error, .campaignStopped("orphanedGlobalReservation"))
    }
    let stopped = try campaignLedger.load(assertion.campaignID)
    XCTAssertTrue(stopped.isTerminal)
    XCTAssertEqual(stopped.events.last?.reasonCode, "orphanedGlobalReservation")
  }

  func testCandidateReviewPinsAndClosedStrategyRejectExpansionOrHighSeverity() throws {
    let assertion = try makeAssertion()
    let pins = try makePins(assertion: assertion, ordinal: 1)
    XCTAssertNoThrow(
      try RockchipEvolutionCampaignAttemptPermit(
        assertion: assertion, candidate: pins.candidate, review: pins.review))

    let high = try RockchipEvolutionReviewReceipt(
      reviewID: pins.review.reviewID, reviewerID: "independent-reviewer",
      candidateID: pins.candidate.candidateID,
      candidateExecutableDigestSHA256: pins.candidate.executableDigestSHA256,
      planDigestSHA256: assertion.planDigestSHA256, result: .pass,
      issues: [try RockchipEvolutionReviewIssue(severity: .high, code: "RAW_DEVICE_PATH")],
      createdAt: Self.confirmedAt)
    XCTAssertThrowsError(try high.validate(candidate: pins.candidate))

    let sameProducer = try RockchipEvolutionReviewReceipt(
      reviewID: pins.review.reviewID, reviewerID: pins.candidate.producerID,
      candidateID: pins.candidate.candidateID,
      candidateExecutableDigestSHA256: pins.candidate.executableDigestSHA256,
      planDigestSHA256: assertion.planDigestSHA256, result: .pass, issues: [],
      createdAt: Self.confirmedAt)
    XCTAssertThrowsError(try sameProducer.validate(candidate: pins.candidate))

    var strategy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(pins.candidate.strategy))
        as? [String: Any])
    let legacyStrategy = strategy.filter { key, _ in
      ![
        "loaderDiscoveryTimeoutSeconds", "loaderPollIntervalMilliseconds",
        "hdcCommandTimeoutSeconds", "readOnlyCommandTimeoutSeconds",
      ].contains(key)
    }
    XCTAssertEqual(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: legacyStrategy)),
      pins.candidate.strategy)
    strategy["loaderDiscoveryTimeoutSeconds"] = NSNull()
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: strategy)))
    strategy["loaderDiscoveryTimeoutSeconds"] =
      pins.candidate.strategy.loaderDiscoveryTimeoutSeconds
    strategy["executable"] = "/usr/local/bin/rkdeveloptool"
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: strategy)))
  }

  func testUnresolvedAttemptReconciliationAlsoClosesTheUsageReservation() async throws {
    // Adversarial review C3: tombstoning the campaign attempt while leaving
    // the usage reservation open blocked the target forever — the ledger
    // admits one open reservation per target and nothing else ever closed
    // a crashed attempt's. Reconciliation must close both.
    let root = temporaryDirectory("campaign-usage-close")
    defer { try? FileManager.default.removeItem(at: root) }
    let campaignRoot = root.appending(path: "campaign")
    let usageRoot = root.appending(path: "usage")
    let ledger = try RockchipEvolutionCampaignLedger(root: campaignRoot)
    let usageLedger = try AgentAuthorityUsageLedger(root: usageRoot)
    let assertion = try makeAssertion()
    let pins = try makePins(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: pins.candidate,
      review: pins.review, at: Self.confirmedAt)

    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: String(repeating: "f", count: 64),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: String(repeating: "b", count: 64),
      archiveDigestSHA256: String(repeating: "c", count: 64),
      stepSetDigestSHA256: String(repeating: "d", count: 64),
      targetStableIdentitySHA256: String(repeating: "e", count: 64),
      bindingLineageRootRevision: 1,
      confirmedAt: Self.confirmedAt,
      validUntil: "2026-08-02T12:00:00Z",
      maximumAttempts: 8)
    let operationDigest = String(repeating: "1", count: 64)
    let targetDigest = String(repeating: "2", count: 64)
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: authorityRef, jobID: "job-crashed",
      operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest)
    _ = try usageLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: reservationID, authorizationRef: authorityRef, ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-crashed",
        operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest,
        reservedAt: Self.confirmedAt,
        forwardLeaseExpiresAt: "2026-08-02T23:00:00Z",
        compensationLeaseExpiresAt: "2026-08-02T23:30:00Z",
        terminal: nil))
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: pins.candidate.candidateID,
      reviewID: pins.review.reviewID, ordinal: 1, reservationID: reservationID,
      jobID: "job-crashed", sessionID: "session-crashed", at: Self.confirmedAt)

    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: pins.candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: pins.candidate, reviewDiff: Data("diff".utf8))),
      reviewer: RejectingEvolutionReviewer(), flash: flash,
      nowUTC: { Self.confirmedAt })
    await ain019AssertThrowsAsync(
      try await host.continueCampaign(
        campaignID: assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 0)

    // Campaign tombstoned as before…
    let terminalDocument = try ledger.load(assertion.campaignID)
    XCTAssertTrue(terminalDocument.isTerminal)
    let attemptTerminal = terminalDocument.events.first { $0.ordinal == 1 && $0.disposition != nil }
    XCTAssertEqual(attemptTerminal?.disposition, .outcomeUnknown)
    // …and, new, the usage reservation carries the matching terminal, so
    // the target is no longer host-wide blocked: a fresh reservation for
    // the same target succeeds.
    let usageTerminal = try XCTUnwrap(
      usageLedger.load().reservations.first { $0.reservationID == reservationID }?.terminal)
    XCTAssertEqual(usageTerminal.status, .outcomeUnknown)
    XCTAssertEqual(usageTerminal.externalIntentEventIDs, [])
    let nextID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: authorityRef, jobID: "job-next",
      operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest)
    XCTAssertNoThrow(
      try usageLedger.reserve(
        AgentAuthorityUsageReservation(
          reservationID: nextID, authorizationRef: authorityRef, ordinal: 2,
          maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-next",
          operationDigestSHA256: operationDigest, targetDigestSHA256: targetDigest,
          reservedAt: Self.confirmedAt,
          forwardLeaseExpiresAt: "2026-08-02T23:00:00Z",
          compensationLeaseExpiresAt: "2026-08-02T23:30:00Z",
          terminal: nil)))
  }

  func testLedgerRejectsUnknownFieldsAndUnresolvedAttemptBecomesTerminalBeforeDispatch()
    async throws
  {
    let root = temporaryDirectory("campaign-unresolved")
    defer { try? FileManager.default.removeItem(at: root) }
    let campaignRoot = root.appending(path: "campaign")
    let usageRoot = root.appending(path: "usage")
    let ledger = try RockchipEvolutionCampaignLedger(root: campaignRoot)
    let assertion = try makeAssertion()
    let pins = try makePins(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: pins.candidate,
      review: pins.review, at: Self.confirmedAt)
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: pins.candidate.candidateID,
      reviewID: pins.review.reviewID, ordinal: 1, reservationID: "missing-reservation",
      jobID: "job-1", sessionID: "session-1", at: Self.confirmedAt)

    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: AgentAuthorityUsageLedger(root: usageRoot),
      repairer: FixedEvolutionRepairer(strategy: pins.candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: pins.candidate, reviewDiff: Data("diff".utf8))),
      reviewer: RejectingEvolutionReviewer(), flash: flash,
      nowUTC: { Self.confirmedAt })
    await ain019AssertThrowsAsync(
      try await host.continueCampaign(
        campaignID: assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    let unresolvedDispatches = await flash.dispatchCount()
    XCTAssertEqual(unresolvedDispatches, 0)
    let terminal = try ledger.load(assertion.campaignID)
    XCTAssertTrue(terminal.isTerminal)
    XCTAssertEqual(terminal.events.last?.disposition, .outcomeUnknown)

    let ledgerURL = campaignRoot.appending(path: "\(assertion.campaignID).json")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    object["unexpected"] = true
    try JSONSerialization.data(withJSONObject: object).write(to: ledgerURL)
    XCTAssertThrowsError(try ledger.load(assertion.campaignID))
  }

  func testReviewFailureAndRepeatedFirstAdmissionHaveZeroFlashDispatch() async throws {
    let root = temporaryDirectory("campaign-host-zero")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion()
    let pins = try makePins(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: pins.candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: pins.candidate, reviewDiff: Data("immutable diff".utf8))),
      reviewer: RejectingEvolutionReviewer(), flash: flash,
      nowUTC: { Self.confirmedAt })
    await ain019AssertThrowsAsync(
      try await host.executeConfirmedCampaign(
        confirmationDigestSHA256: assertion.confirmationDigestSHA256,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    let rejectedDispatches = await flash.dispatchCount()
    XCTAssertEqual(rejectedDispatches, 0)
    XCTAssertTrue(try ledger.load(assertion.campaignID).isTerminal)
  }

  func testHostAutomaticallyRepairsAndContinuesSafeFailureUntilSuccess() async throws {
    let root = temporaryDirectory("campaign-auto-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let baseline = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250, hdcCommandTimeoutSeconds: 45,
      readOnlyCommandTimeoutSeconds: 30, userdataImpact: "ERASE-USERDATA")
    let flash = SafeFailureThenSuccessEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: baseline, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(), reviewer: PassingEvolutionReviewer(),
      flash: flash, nowUTC: { Self.confirmedAt })

    let result = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 2)
    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 2)
    let document = try ledger.load(assertion.campaignID)
    XCTAssertTrue(document.isTerminal)
    XCTAssertEqual(
      document.events.filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.safeToReflash, .succeeded])
    XCTAssertEqual(document.events.compactMap(\.candidate).map(\.strategy), [baseline, repaired])
  }

  func testCandidateThatExcludesLiveModeIsRepairedWithoutConsumingAttempt() async throws {
    let root = temporaryDirectory("campaign-live-mode-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let wrongMode = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = StartingModeMismatchThenSuccessEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: wrongMode, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(), reviewer: PassingEvolutionReviewer(),
      flash: flash, nowUTC: { Self.confirmedAt })

    let result = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 1)
    let dispatchCount = await flash.dispatchCount()
    XCTAssertEqual(dispatchCount, 2)
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(document.reservedAttemptCount, 1)
    XCTAssertEqual(document.events.compactMap(\.candidate).map(\.strategy), [wrongMode, repaired])
    XCTAssertEqual(
      document.events.filter { $0.kind == .attemptTerminal }.map(\.disposition), [.succeeded])
  }

  /// The engine lane's executor cannot mint its own reservation (#992: the
  /// engine re-verifies and closes, it never reserves), so the host runs the
  /// nine gates and mints it immediately before dispatch. This pins the
  /// ordering and the hand-off, both of which are invisible to a dispatcher
  /// that admits inside itself.
  func testEngineLaneAttemptIsAdmittedBeforeItIsDispatched() async throws {
    let root = temporaryDirectory("campaign-engine-lane-order")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let strategy = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = PreAdmittingEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: strategy),
      builder: StrategyEchoEvolutionBuilder(), reviewer: PassingEvolutionReviewer(),
      flash: flash, nowUTC: { Self.confirmedAt })

    let result = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 1)
    let trace = await flash.trace()
    XCTAssertEqual(
      trace, ["admit", "dispatch"],
      "the reservation must exist before the engine lane submits anything")
    // The dispatcher received the very reservation the admitter minted, not a
    // nil it would have had to fail closed on.
    let handedOver = await flash.receivedReservationID()
    XCTAssertEqual(handedOver, "reservation-engine-1")
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(document.reservedAttemptCount, 1)
    XCTAssertEqual(
      document.events.filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.succeeded])
  }

  /// The starting-mode repair loop reaches the same gate by a different route
  /// on this lane: the admitter throws the campaign rejection directly rather
  /// than wrapped in a flash error. The candidate must still be repaired
  /// without consuming an attempt.
  func testEngineLaneStartingModeRejectionStillRepairsWithoutConsumingAttempt()
    async throws
  {
    let root = temporaryDirectory("campaign-engine-lane-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let wrongMode = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = PreAdmittingEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt, rejectFirstAdmissionWithMode: "loader")
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: wrongMode, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(), reviewer: PassingEvolutionReviewer(),
      flash: flash, nowUTC: { Self.confirmedAt })

    let result = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 1)
    let trace = await flash.trace()
    // The refused admission never reached dispatch, and never reserved.
    XCTAssertEqual(trace, ["admit", "admit", "dispatch"])
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(document.reservedAttemptCount, 1)
    XCTAssertEqual(document.events.compactMap(\.candidate).map(\.strategy), [wrongMode, repaired])
  }

  func testHostNeverRetriesFailureWithoutFreshAttemptReservation() async throws {
    let root = temporaryDirectory("campaign-pre-admission-stop")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let baseline = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = RejectingBeforeReservationEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: baseline),
      builder: StrategyEchoEvolutionBuilder(), reviewer: PassingEvolutionReviewer(),
      flash: flash, nowUTC: { Self.confirmedAt })

    await ain019AssertThrowsAsync(
      try await host.executeConfirmedCampaign(
        confirmationDigestSHA256: assertion.confirmationDigestSHA256,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))

    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 1)
    let stopped = try ledger.load(assertion.campaignID)
    XCTAssertTrue(stopped.isTerminal)
    XCTAssertEqual(stopped.events.last?.reasonCode, "admissionOrTargetDrift")
    XCTAssertEqual(stopped.reservedAttemptCount, 0)
  }

  func testCodexRepairerAcceptsOnlyClosedNewTypedStrategy() async throws {
    let root = temporaryDirectory("campaign-repairer")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assertion = try makeAssertion()
    let prior = try makePins(assertion: assertion, ordinal: 1).candidate
    let response = Data(
      """
      {"allowedStartingModes":["hdcNormal","loader"],"loaderDiscoveryTimeoutSeconds":90,"loaderPollIntervalMilliseconds":250,"hdcCommandTimeoutSeconds":45,"readOnlyCommandTimeoutSeconds":30}
      """.utf8)
    let repairer = try CodexRockchipEvolutionStrategyRepairer(
      executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path, transport: FixedEvolutionCodexTransport(response: response))
    let strategy = try await repairer.propose(
      assertion: assertion,
      observation: RockchipEvolutionFailureObservation(
        attemptOrdinal: 1, failureCode: "flash.semanticFailure:enter-loader"),
      priorCandidates: [prior])
    XCTAssertEqual(strategy.loaderDiscoveryTimeoutSeconds, 90)
    XCTAssertEqual(strategy.loaderPollIntervalMilliseconds, 250)
    XCTAssertEqual(strategy.hdcCommandTimeoutSeconds, 45)
    XCTAssertEqual(strategy.readOnlyCommandTimeoutSeconds, 30)

    let invalid = try CodexRockchipEvolutionStrategyRepairer(
      executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path,
      transport: FixedEvolutionCodexTransport(
        response: Data(
          """
          {"allowedStartingModes":["loader"],"loaderDiscoveryTimeoutSeconds":90,"loaderPollIntervalMilliseconds":250,"hdcCommandTimeoutSeconds":45,"readOnlyCommandTimeoutSeconds":30,"argv":["wlx"]}
          """.utf8)))
    await ain019AssertThrowsAsync(
      try await invalid.propose(
        assertion: assertion,
        observation: RockchipEvolutionFailureObservation(
          attemptOrdinal: 1, failureCode: "flash.semanticFailure:enter-loader"),
        priorCandidates: [prior]))
  }

  func testCodexReviewerTreatsExactBaselineAsConstraintAndReportsModelRejectCode()
    async throws
  {
    let root = temporaryDirectory("campaign-reviewer")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assertion = try makeAssertion()
    let candidate = try makePins(assertion: assertion, ordinal: 1).candidate
    let request = RockchipEvolutionAdversarialReviewRequest(
      assertion: assertion, candidate: candidate,
      immutableDiff: Data("synthetic strategy-proposal.json".utf8), priorAttempts: [])

    let passingTransport = RecordingEvolutionCodexTransport(
      response: Data("{\"result\":\"PASS\",\"issues\":[]}".utf8))
    let reviewer = try CodexRockchipEvolutionAdversarialReviewer(
      executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path, transport: passingTransport)
    let receipt = try await reviewer.review(request)
    XCTAssertEqual(receipt.result, .pass)
    let recordedRequest = await passingTransport.lastRequest()
    let prompt = try XCTUnwrap(recordedRequest?.arguments.last)
    XCTAssertTrue(prompt.contains("Review candidate expansion"))
    XCTAssertTrue(prompt.contains("ERASE-USERDATA"))
    XCTAssertTrue(prompt.contains("HIGH or CRITICAL"))

    let rejectingTransport = RecordingEvolutionCodexTransport(
      response: Data(
        "{\"result\":\"REJECT\",\"issues\":[{\"severity\":\"HIGH\",\"code\":\"AUTHORITY_SURFACE\"}]}"
          .utf8))
    let rejectingReviewer = try CodexRockchipEvolutionAdversarialReviewer(
      executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path, transport: rejectingTransport)
    do {
      _ = try await rejectingReviewer.review(request)
      XCTFail("a model HIGH issue must reject the candidate")
    } catch let error as RockchipEvolutionCampaignError {
      XCTAssertEqual(error, .reviewRejected("modelReject:AUTHORITY_SURFACE"))
    }
  }

  func testCandidateTargetAndSandboxHaveNoRuntimeDeviceNetworkOrRawProcessSurface() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let manifest = try String(
      contentsOf: packageRoot.appending(path: "Package.swift"), encoding: .utf8)
    XCTAssertTrue(
      manifest.contains(
        ".executableTarget(\n      name: \"ArkDeckEvolutionCandidate\",\n      path: \"Sources/ArkDeckHarness/Candidate\")"
      ))
    let source = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckHarness/Candidate/main.swift"),
      encoding: .utf8)
    XCTAssertTrue(source.contains("import Foundation"))
    for forbidden in [
      "import ArkDeck", "Process(", "/usr/bin/hdc", "rkdeveloptool", "IOKit",
      "IOUSBHost",
    ] {
      XCTAssertFalse(source.contains(forbidden), "candidate source exposed \(forbidden)")
    }

    let profile = ProductRockchipEvolutionCandidateBuilder.sandboxProfile(
      candidateURL: URL(fileURLWithPath: "/private/tmp/candidate"),
      requestURL: URL(fileURLWithPath: "/private/tmp/request.json"))
    XCTAssertTrue(profile.contains("(deny default)"))
    XCTAssertTrue(profile.contains("(import \"dyld-support.sb\")"))
    XCTAssertTrue(
      profile.contains(
        "(allow process-exec (literal \"/private/tmp/candidate\"))"))
    XCTAssertEqual(profile.components(separatedBy: "process-exec").count - 1, 1)
    XCTAssertFalse(profile.contains("(allow process-exec)"))
    XCTAssertFalse(profile.contains("process-exec*"))
    XCTAssertFalse(profile.contains("network"))
    XCTAssertFalse(profile.lowercased().contains("usb"))
    XCTAssertFalse(profile.lowercased().contains("hdc"))
    XCTAssertFalse(profile.lowercased().contains("rockusb"))
  }

  func testCandidateSandboxLaunchesOnlyTheExactCandidateLiteral() throws {
    let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    let candidate = URL(fileURLWithPath: "/usr/bin/true")
    let otherExecutable = URL(fileURLWithPath: "/usr/bin/false")
    let profile = ProductRockchipEvolutionCandidateBuilder.sandboxProfile(
      candidateURL: candidate,
      requestURL: URL(fileURLWithPath: "/private/tmp/unused-candidate-request.json"))

    func run(_ executable: URL) throws -> (status: Int32, stderr: String) {
      let process = Process()
      let errorPipe = Pipe()
      process.executableURL = sandbox
      process.arguments = ["-p", profile, executable.path]
      process.standardError = errorPipe
      try process.run()
      process.waitUntilExit()
      return (
        process.terminationStatus,
        String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    let exact = try run(candidate)
    XCTAssertEqual(exact.status, 0, exact.stderr)

    let rejected = try run(otherExecutable)
    XCTAssertNotEqual(rejected.status, 0)
    XCTAssertTrue(rejected.stderr.contains("Operation not permitted"), rejected.stderr)
  }

  func testExpiredZeroEventPreviewDraftIsCollectedWhileHistoryAndFreshDraftsSurvive() throws {
    let root = temporaryDirectory("campaign-draft-gc")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root)

    let expiredDraft = try makeAssertion(seed: "1", validUntil: "2026-08-02T08:01:00Z")
    _ = try ledger.create(expiredDraft)
    let freshDraft = try makeAssertion(seed: "2")
    _ = try ledger.create(freshDraft)
    let historical = try makeAssertion(seed: "3", validUntil: "2026-08-02T08:01:00Z")
    let pins = try makePins(assertion: historical, ordinal: 1)
    _ = try ledger.create(historical)
    _ = try ledger.appendCandidate(
      campaignID: historical.campaignID, candidate: pins.candidate,
      review: pins.review, at: Self.confirmedAt)
    let corruptURL = root.appending(path: "ECAMP-\(String(repeating: "C", count: 24)).json")
    try Data("{\"broken\":true}".utf8).write(to: corruptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)
    let foreignURL = root.appending(path: "notes.txt")
    try Data("operator notes".utf8).write(to: foreignURL)

    XCTAssertEqual(
      try ledger.collectExpiredZeroEventDrafts(at: "2026-08-02T08:00:30Z"), [],
      "no draft may be collected while its confirmation window is still open")

    let collected = try ledger.collectExpiredZeroEventDrafts(at: "2026-08-02T08:30:00Z")
    XCTAssertEqual(collected, [expiredDraft.campaignID])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appending(path: "\(expiredDraft.campaignID).json").path),
      "an expired zero-event preview draft must not remain durable")
    XCTAssertThrowsError(try ledger.load(expiredDraft.campaignID)) { error in
      XCTAssertEqual(
        error as? RockchipEvolutionCampaignError,
        .campaignNotFound(expiredDraft.campaignID))
    }
    XCTAssertEqual(try ledger.load(freshDraft.campaignID).events, [])
    XCTAssertEqual(
      try ledger.load(historical.campaignID).events.count, 1,
      "a document with history is retained even after expiry")
    XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreignURL.path))
    XCTAssertEqual(try ledger.collectExpiredZeroEventDrafts(at: "2026-08-02T08:30:00Z"), [])
    XCTAssertThrowsError(try ledger.collectExpiredZeroEventDrafts(at: "not-a-timestamp"))
  }

  func testExecuteAndContinueSweepExpiredSiblingDraftsAndStillFindTheirOwnDocument()
    async throws
  {
    let root = temporaryDirectory("campaign-execute-gc")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let expiredDraft = try makeAssertion(seed: "1", validUntil: "2026-08-02T08:01:00Z")
    _ = try ledger.create(expiredDraft)
    let assertion = try makeAssertion(seed: "2")
    _ = try ledger.create(assertion)
    let pins = try makePins(assertion: assertion, ordinal: 1)
    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: pins.candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: pins.candidate, reviewDiff: Data("diff".utf8))),
      reviewer: RejectingEvolutionReviewer(), flash: flash,
      nowUTC: { "2026-08-02T08:30:00Z" })

    await ain019AssertThrowsAsync(
      try await host.executeConfirmedCampaign(
        confirmationDigestSHA256: assertion.confirmationDigestSHA256,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(
      try ledger.load(expiredDraft.campaignID),
      "first admission must sweep expired zero-event sibling drafts")
    XCTAssertTrue(
      try ledger.load(assertion.campaignID).isTerminal,
      "execute must still find its own document after the sweep")

    let secondExpired = try makeAssertion(seed: "4", validUntil: "2026-08-02T08:02:00Z")
    _ = try ledger.create(secondExpired)
    await ain019AssertThrowsAsync(
      try await host.continueCampaign(
        campaignID: assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(try ledger.load(secondExpired.campaignID))

    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 0)
  }

  func testPreviewSourceSweepsExpiredDraftsBeforePersistingItsOwnDraft() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckWorkflows/AgentComposition/EvolutionCampaignHost.swift"),
      encoding: .utf8)
    let sweep = try XCTUnwrap(
      source.range(of: "ledger.collectExpiredZeroEventDrafts(at: confirmedAt)"),
      "preview must sweep expired zero-event drafts")
    let create = try XCTUnwrap(source.range(of: "try ledger.create(assertion)"))
    XCTAssertTrue(
      sweep.lowerBound < create.lowerBound,
      "preview sweeps before persisting its own draft")
  }

  private func makeAssertion(
    seed: Character = "0", maxAttempts: Int = 16,
    validUntil: String = "2026-08-02T12:00:00Z"
  ) throws -> RockchipEvolutionCampaignConfirmationAssertion {
    try .draft(
      baseCommitOID: String(repeating: String(seed), count: 40),
      candidateToolchainDigestSHA256: digest("1"),
      brokerExecutableDigestSHA256: digest("2"), maxChangedFiles: 8,
      maxDiffLines: 2_000, planDigestSHA256: digest("3"),
      archiveDigestSHA256: digest("4"), stepSetDigestSHA256: digest("5"),
      targetStableIdentitySHA256: Self.targetDigest, bindingLineageRootRevision: 1,
      maxAttempts: maxAttempts, confirmedAt: Self.confirmedAt, validUntil: validUntil)
  }

  private func makePins(
    assertion: RockchipEvolutionCampaignConfirmationAssertion, ordinal: Int
  ) throws -> (
    candidate: RockchipEvolutionCandidatePin, review: RockchipEvolutionReviewReceipt
  ) {
    let suffix = String(format: "%016X", ordinal)
    let strategy = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2",
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let candidate = try RockchipEvolutionCandidatePin(
      candidateID: "ECAND-\(suffix)", producerID: "builder-\(ordinal)",
      baseCommitOID: assertion.baseCommitOID,
      sourceTreeDigestSHA256: digest("6"), diffDigestSHA256: digest("7"),
      allowedPathSetDigestSHA256: digest("8"), executableDigestSHA256: digest("9"),
      toolchainDigestSHA256: assertion.candidateToolchainDigestSHA256,
      changedFiles: ["Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/main.swift"],
      changedLines: 1, diffArtifactID: "diff-\(ordinal)",
      buildEvidenceArtifactID: "build-\(ordinal)",
      testEvidenceArtifactID: "test-\(ordinal)", strategy: strategy)
    let review = try RockchipEvolutionReviewReceipt(
      reviewID: "EREVIEW-\(suffix)", reviewerID: "reviewer-\(ordinal)",
      candidateID: candidate.candidateID,
      candidateExecutableDigestSHA256: candidate.executableDigestSHA256,
      planDigestSHA256: assertion.planDigestSHA256, result: .pass, issues: [],
      createdAt: Self.confirmedAt)
    return (candidate, review)
  }

  private func usageReservation(
    reference: AgentExecutionAuthorityReference, ordinal: Int, jobID: String
  ) throws -> AgentAuthorityUsageReservation {
    let operation = digest("3")
    let target = digest("a")
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: jobID,
      operationDigestSHA256: operation, targetDigestSHA256: target)
    return try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: ordinal, maximumUses: 16, maximumConcurrentJobs: 1,
      jobID: jobID, operationDigestSHA256: operation,
      targetDigestSHA256: target, reservedAt: Self.confirmedAt,
      forwardLeaseExpiresAt: "2026-08-02T08:01:00Z",
      compensationLeaseExpiresAt: "2026-08-02T08:02:00Z")
  }

  private func temporaryDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-ain019-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
  }
}

private struct FixedEvolutionBuilder: RockchipEvolutionCandidateBuilding {
  let build: RockchipEvolutionCandidateBuild

  func build(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    strategy _: RockchipEvolutionTypedStrategy
  ) async throws
    -> RockchipEvolutionCandidateBuild
  {
    build
  }
}

private struct FixedEvolutionRepairer: RockchipEvolutionStrategyRepairing {
  let strategy: RockchipEvolutionTypedStrategy
  let repairerID = "fixed-evolution-repairer"

  func propose(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    observation _: RockchipEvolutionFailureObservation?,
    priorCandidates _: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    strategy
  }
}

private struct ScriptedEvolutionRepairer: RockchipEvolutionStrategyRepairing {
  let baseline: RockchipEvolutionTypedStrategy
  let repaired: RockchipEvolutionTypedStrategy
  let repairerID = "scripted-evolution-repairer"

  func propose(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    observation: RockchipEvolutionFailureObservation?,
    priorCandidates _: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    observation == nil ? baseline : repaired
  }
}

private struct StrategyEchoEvolutionBuilder: RockchipEvolutionCandidateBuilding {
  func build(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    strategy: RockchipEvolutionTypedStrategy
  ) async throws -> RockchipEvolutionCandidateBuild {
    let suffix = String(strategy.digestSHA256.prefix(24)).uppercased()
    let candidate = try RockchipEvolutionCandidatePin(
      candidateID: "ECAND-\(suffix)", producerID: "strategy-echo-builder",
      baseCommitOID: assertion.baseCommitOID,
      sourceTreeDigestSHA256: String(repeating: "6", count: 64),
      diffDigestSHA256: strategy.digestSHA256,
      allowedPathSetDigestSHA256: String(repeating: "8", count: 64),
      executableDigestSHA256: String(repeating: "9", count: 64),
      toolchainDigestSHA256: assertion.candidateToolchainDigestSHA256,
      changedFiles: [], changedLines: 1, diffArtifactID: "strategy-diff-\(suffix)",
      buildEvidenceArtifactID: "strategy-build-\(suffix)",
      testEvidenceArtifactID: "strategy-test-\(suffix)", strategy: strategy)
    return RockchipEvolutionCandidateBuild(
      pin: candidate, reviewDiff: try JSONEncoder().encode(strategy))
  }
}

private struct PassingEvolutionReviewer: RockchipEvolutionAdversarialReviewing {
  let reviewerID = "passing-independent-reviewer"

  func review(_ request: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
  {
    try RockchipEvolutionReviewReceipt(
      reviewID: "EREVIEW-\(String(request.candidate.strategy.digestSHA256.prefix(24)).uppercased())",
      reviewerID: reviewerID, candidateID: request.candidate.candidateID,
      candidateExecutableDigestSHA256: request.candidate.executableDigestSHA256,
      planDigestSHA256: request.assertion.planDigestSHA256, result: .pass, issues: [],
      createdAt: "2026-08-02T08:00:00Z")
  }
}

private actor SafeFailureThenSuccessEvolutionFlash: RockchipEvolutionFlashDispatching {
  let ledger: RockchipEvolutionCampaignLedger
  let now: String
  private var count = 0

  init(ledger: RockchipEvolutionCampaignLedger, now: String) {
    self.ledger = ledger
    self.now = now
  }

  // An in-process-lane fake: it reserves inside execute, so the host must
  // never hand it a pre-admitted attempt.
  func execute(
    _ request: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    guard case .evolutionCampaign(let permit) = request.authority, admitted == nil else {
      throw RockchipEvolutionCampaignError.admissionRejected("campaignPermitRequired")
    }
    count += 1
    let ordinal = count
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      reviewID: permit.review.reviewID, ordinal: ordinal,
      reservationID: "reservation-auto-\(ordinal)", jobID: "job-auto-\(ordinal)",
      sessionID: "session-auto-\(ordinal)", at: now)
    if ordinal == 1 {
      _ = try ledger.closeAttempt(
        campaignID: permit.assertion.campaignID, ordinal: ordinal,
        jobID: "job-auto-\(ordinal)", sessionID: "session-auto-\(ordinal)",
        disposition: .safeToReflash, destructiveIntentEventIDs: [], at: now)
      throw RockchipFlashExecutionError.semanticFailure(
        stepID: "enter-loader", detail: "contract safe failure")
    }
    _ = try ledger.closeAttempt(
      campaignID: permit.assertion.campaignID, ordinal: ordinal,
      jobID: "job-auto-\(ordinal)", sessionID: "session-auto-\(ordinal)",
      disposition: .succeeded, destructiveIntentEventIDs: ["intent-auto-\(ordinal)"], at: now)
    return RockchipFlashExecutionResult(
      sessionID: "session-auto-\(ordinal)", jobID: "job-auto-\(ordinal)",
      status: .succeeded, evidenceClass: .contractFake, manifestURL: nil)
  }

  func dispatchCount() -> Int { count }
}

private actor RejectingBeforeReservationEvolutionFlash: RockchipEvolutionFlashDispatching {
  private var count = 0

  func execute(
    _: RockchipFlashExecutionRequest,
    admitted _: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    count += 1
    throw RockchipFlashExecutionError.admissionRejected("fresh target drift")
  }

  func dispatchCount() -> Int { count }
}

private actor StartingModeMismatchThenSuccessEvolutionFlash: RockchipEvolutionFlashDispatching {
  let ledger: RockchipEvolutionCampaignLedger
  let now: String
  private var count = 0

  init(ledger: RockchipEvolutionCampaignLedger, now: String) {
    self.ledger = ledger
    self.now = now
  }

  func execute(
    _ request: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    guard case .evolutionCampaign(let permit) = request.authority, admitted == nil else {
      throw RockchipEvolutionCampaignError.admissionRejected("campaignPermitRequired")
    }
    count += 1
    if count == 1 {
      throw RockchipFlashExecutionError.admissionRejected("startingModeNotAllowed:loader")
    }
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      reviewID: permit.review.reviewID, ordinal: 1,
      reservationID: "reservation-mode-1", jobID: "job-mode-1",
      sessionID: "session-mode-1", at: now)
    _ = try ledger.closeAttempt(
      campaignID: permit.assertion.campaignID, ordinal: 1,
      jobID: "job-mode-1", sessionID: "session-mode-1",
      disposition: .succeeded, destructiveIntentEventIDs: ["intent-mode-1"], at: now)
    return RockchipFlashExecutionResult(
      sessionID: "session-mode-1", jobID: "job-mode-1",
      status: .succeeded, evidenceClass: .contractFake, manifestURL: nil)
  }

  func dispatchCount() -> Int { count }
}

private struct FixedEvolutionCodexTransport: HarnessCodexTransport {
  let response: Data
  func send(_: HarnessCodexProcessRequest) async throws -> Data { response }
}

private actor RecordingEvolutionCodexTransport: HarnessCodexTransport {
  let response: Data
  private var requests: [HarnessCodexProcessRequest] = []

  init(response: Data) { self.response = response }

  func send(_ request: HarnessCodexProcessRequest) async throws -> Data {
    requests.append(request)
    return response
  }

  func lastRequest() -> HarnessCodexProcessRequest? { requests.last }
}

private struct RejectingEvolutionReviewer: RockchipEvolutionAdversarialReviewing {
  let reviewerID = "independent-adversarial-reviewer"

  func review(_: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
  {
    throw RockchipEvolutionCampaignError.reviewRejected("contractRejection")
  }
}

/// Stands in for the engine lane: it cannot reserve inside execute, so it
/// publishes an admitter and expects the host to have minted the reservation
/// before dispatch.
private final class PreAdmittingEvolutionFlash: RockchipEvolutionFlashDispatching,
  @unchecked Sendable
{
  private let recorder: EngineLaneTrace
  let attemptAdmitter: (any RockchipEvolutionCampaignAttemptAdmitting)?

  init(
    ledger: RockchipEvolutionCampaignLedger,
    now: String,
    rejectFirstAdmissionWithMode: String? = nil
  ) {
    let recorder = EngineLaneTrace()
    self.recorder = recorder
    attemptAdmitter = ScriptedCampaignAttemptAdmitter(
      ledger: ledger, now: now, recorder: recorder,
      rejectFirstAdmissionWithMode: rejectFirstAdmissionWithMode)
  }

  func execute(
    _: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    guard let admitted else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the engine lane requires a campaign reservation minted before dispatch")
    }
    await recorder.record("dispatch", reservationID: admitted.reservationID)
    return RockchipFlashExecutionResult(
      sessionID: admitted.sessionID, jobID: admitted.jobID,
      status: .succeeded, evidenceClass: .contractFake, manifestURL: nil)
  }

  func trace() async -> [String] { await recorder.entries() }
  func receivedReservationID() async -> String? { await recorder.reservationID() }
}

private actor EngineLaneTrace {
  private var recorded: [String] = []
  private var dispatchedReservationID: String?

  func record(_ entry: String, reservationID: String? = nil) {
    recorded.append(entry)
    if let reservationID { dispatchedReservationID = reservationID }
  }

  func entries() -> [String] { recorded }
  func reservationID() -> String? { dispatchedReservationID }

  private var admissions = 0

  func nextAdmissionOrdinal() -> Int {
    admissions += 1
    return admissions
  }
}

private struct ScriptedCampaignAttemptAdmitter: RockchipEvolutionCampaignAttemptAdmitting {
  private let ledger: RockchipEvolutionCampaignLedger
  private let now: String
  private let recorder: EngineLaneTrace
  private let rejectFirstAdmissionWithMode: String?

  init(
    ledger: RockchipEvolutionCampaignLedger,
    now: String,
    recorder: EngineLaneTrace,
    rejectFirstAdmissionWithMode: String?
  ) {
    self.ledger = ledger
    self.now = now
    self.recorder = recorder
    self.rejectFirstAdmissionWithMode = rejectFirstAdmissionWithMode
  }

  func admitAttempt(
    permit: RockchipEvolutionCampaignAttemptPermit,
    archiveURL _: URL,
    targetLocationSelector _: String
  ) async throws -> RockchipEvolutionCampaignAdmittedAttempt {
    await recorder.record("admit")
    let ordinal = await recorder.nextAdmissionOrdinal()
    if ordinal == 1, let mode = rejectFirstAdmissionWithMode {
      // The real service's spelling: the campaign error, unwrapped.
      throw RockchipEvolutionCampaignError.admissionRejected("startingModeNotAllowed:\(mode)")
    }
    let profile = RockchipFlashProfile.dayu200OpenHarmony70035
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      reviewID: permit.review.reviewID, ordinal: 1,
      reservationID: "reservation-engine-1", jobID: "job-engine-1",
      sessionID: "session-engine-1", at: now)
    _ = try ledger.closeAttempt(
      campaignID: permit.assertion.campaignID, ordinal: 1,
      jobID: "job-engine-1", sessionID: "session-engine-1",
      disposition: .succeeded, destructiveIntentEventIDs: ["intent-engine-1"], at: now)
    return RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: permit.assertion.campaignID, ordinal: 1,
      reservationID: "reservation-engine-1", jobID: "job-engine-1",
      sessionID: "session-engine-1",
      targetStableIdentitySHA256: permit.assertion.targetStableIdentitySHA256,
      bindingRevision: permit.assertion.bindingLineageRootRevision,
      deviceProfileReference: profile.catalogReference,
      partitionPlan: profile.mappedPartitions.map(\.partitionName),
      archiveSHA256: profile.archiveSHA256,
      postFlashVerification: "full")
  }
}

private actor CountingEvolutionFlash: RockchipEvolutionFlashDispatching {
  private var count = 0

  func execute(
    _: RockchipFlashExecutionRequest,
    admitted _: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    count += 1
    throw RockchipEvolutionCampaignError.admissionRejected("unexpectedContractDispatch")
  }

  func dispatchCount() -> Int { count }
}

private struct FixedEvolutionClock: RockchipAdmissionClock {
  let reading: RockchipTrustedClockReading
  func now() -> RockchipTrustedClockReading { reading }
}

private struct RejectingEvolutionFacts: RockchipAuthorizationFactCollecting {
  func collect(
    request _: RockchipAuthorizationFactRequest,
    expectation _: RockchipAuthorizationFactExpectation
  ) async throws -> RockchipTrustedAuthorizationFacts {
    throw RockchipAuthorizationFactError.factPortFailed(name: "must-not-run")
  }
}

private func ain019AssertThrowsAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath, line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected async expression to throw", file: file, line: line)
  } catch {}
}
