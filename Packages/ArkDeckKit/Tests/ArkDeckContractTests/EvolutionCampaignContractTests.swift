import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckAgentComposition
@testable import ArkDeckWorkflows

final class EvolutionCampaignContractTests: XCTestCase {
  private static let confirmedAt = "2026-08-02T08:00:00Z"
  private static let validUntil = "2026-08-02T12:00:00Z"
  private static let targetDigest = String(repeating: "a", count: 64)

  /// A document `flash plan` produces must not make the `flash execute` that
  /// follows it refuse.
  ///
  /// The campaign lane requires the repository top level as its working
  /// directory, and the candidate scope check counts every untracked file
  /// `git ls-files --others --exclude-standard` reports. Writing the plan
  /// document into the current directory therefore put a file in the tree that
  /// is not candidate source, which is `scopeDrift` — two of this product's own
  /// requirements colliding through a default. Observed on the 7.0.0.34 window,
  /// where the file had to be deleted by hand between `plan` and `execute`.
  func testProducedDocumentsDoNotDefaultIntoTheWorkingTree() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)

    // Both documents go through the one resolver, so there is a single place
    // where this can regress.
    for document in ["arkdeck-flash-plan.json", "arkdeck-flash-handoff.md"] {
      XCTAssertTrue(
        source.contains("outputURL(options, fileName: \"\(document)\")"),
        "\(document) no longer goes through the shared resolver")
    }
    XCTAssertFalse(
      source.contains("options.value(\"--out\") ?? FileManager.default.currentDirectoryPath"),
      "the default output directory is the working directory again")
    XCTAssertTrue(source.contains("static func defaultDocumentDirectory() -> URL"))

    // And the scope check this protects still reads untracked files, so the
    // reason above has not quietly stopped applying.
    let pipeline = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckWorkflows/EvolutionCandidatePipeline.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      pipeline.contains("\"ls-files\", \"--others\", \"--exclude-standard\", \"-z\""),
      "the candidate scope check no longer reads untracked files; re-check whether "
        + "a document in the working tree still causes scopeDrift")
  }

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

  func testCampaignReferenceValidationDiagnosticNamesTheSixteenAttemptLimit() {
    XCTAssertThrowsError(
      try AgentExecutionAuthorityReference.validatedEvolutionCampaignConfirmation(
        campaignDigestSHA256: digest("a"),
        baseCommitOID: String(repeating: "b", count: 40),
        planDigestSHA256: digest("c"),
        archiveDigestSHA256: digest("d"),
        stepSetDigestSHA256: digest("e"),
        targetStableIdentitySHA256: digest("f"),
        bindingLineageRootRevision: 1,
        confirmedAt: Self.confirmedAt,
        validUntil: Self.validUntil,
        maximumAttempts: 17)
    ) { error in
      guard case AuthorizationUsageLedgerError.invalidRecord(let detail) = error else {
        return XCTFail("wrong validation error: \(error)")
      }
      XCTAssertTrue(detail.contains("16 attempt/4 hour envelope"))
      XCTAssertFalse(detail.contains("8 attempt/4 hour envelope"))
    }
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
      let candidate = try makeCandidate(assertion: assertion, ordinal: ordinal)
      _ = try ledger.appendCandidate(
        campaignID: assertion.campaignID, candidate: candidate,
        at: Self.confirmedAt)
      _ = try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: candidate.candidateID,
        ordinal: ordinal,
        reservationID: "reservation-\(ordinal)", jobID: "job-\(ordinal)",
        sessionID: "session-\(ordinal)", at: Self.confirmedAt)

      let contender = try makeCandidate(assertion: assertion, ordinal: 100 + ordinal)
      XCTAssertThrowsError(
        try ledger.appendCandidate(
          campaignID: assertion.campaignID, candidate: contender,
          at: Self.confirmedAt),
        "an active attempt must block a concurrent candidate/attempt")

      _ = try ledger.closeAttempt(
        campaignID: assertion.campaignID, ordinal: ordinal,
        jobID: "job-\(ordinal)", sessionID: "session-\(ordinal)",
        disposition: .safeToReflash, destructiveIntentEventIDs: [],
        at: Self.confirmedAt)
    }

    let seventeenth = try makeCandidate(assertion: assertion, ordinal: 17)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: seventeenth,
      at: Self.confirmedAt)
    XCTAssertThrowsError(
      try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: seventeenth.candidateID,
        ordinal: 17,
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
      let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
      _ = try ledger.create(assertion)
      _ = try ledger.appendCandidate(
        campaignID: assertion.campaignID, candidate: candidate,
        at: Self.confirmedAt)
      _ = try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: candidate.candidateID,
        ordinal: 1, reservationID: "reservation-1",
        jobID: "job-1", sessionID: "session-1", at: Self.confirmedAt)
      _ = try ledger.closeAttempt(
        campaignID: assertion.campaignID, ordinal: 1, jobID: "job-1",
        sessionID: "session-1", disposition: disposition,
        destructiveIntentEventIDs: disposition == .succeeded ? [] : ["intent-1"],
        at: Self.confirmedAt)
      XCTAssertTrue(try ledger.load(assertion.campaignID).isTerminal)
      XCTAssertThrowsError(
        try ledger.appendCandidate(
          campaignID: assertion.campaignID, candidate: candidate,
          at: Self.confirmedAt))
    }
  }

  func testOrphanedGlobalReservationPermanentlyStopsBeforeLiveFactCollection() async throws {
    let root = temporaryDirectory("campaign-orphan")
    defer { try? FileManager.default.removeItem(at: root) }
    let campaignLedger = try RockchipEvolutionCampaignLedger(
      root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion()
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try campaignLedger.create(assertion)
    _ = try campaignLedger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)
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
      assertion: assertion, candidate: candidate)
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

  func testHistoricalReviewReceiptsDecodeAndClosedStrategyRejectExpansionOrHighSeverity() throws {
    let assertion = try makeAssertion()
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    XCTAssertEqual(
      candidate.strategy.loaderDiscoveryTimeoutSeconds, 120,
      "new campaigns must wait through the entire approved Loader observation window")
    XCTAssertNoThrow(
      try RockchipEvolutionCampaignAttemptPermit(
        assertion: assertion, candidate: candidate))

    let high = try historicalReview(
      candidate: candidate, assertion: assertion, reviewerID: "independent-reviewer",
      issues: [["severity": "HIGH", "code": "RAW_DEVICE_PATH"]])
    XCTAssertThrowsError(try high.validateHistorical(candidate: candidate))

    let sameProducer = try historicalReview(
      candidate: candidate, assertion: assertion, reviewerID: candidate.producerID)
    XCTAssertThrowsError(try sameProducer.validateHistorical(candidate: candidate))

    var strategy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.strategy))
        as? [String: Any])
    let legacyStrategy = strategy.filter { key, _ in
      ![
        "loaderDiscoveryTimeoutSeconds", "loaderPollIntervalMilliseconds",
        "hdcCommandTimeoutSeconds", "readOnlyCommandTimeoutSeconds",
      ].contains(key)
    }
    let decodedLegacy = try JSONDecoder().decode(
      RockchipEvolutionTypedStrategy.self,
      from: JSONSerialization.data(withJSONObject: legacyStrategy))
    XCTAssertEqual(decodedLegacy.loaderDiscoveryTimeoutSeconds, 45)
    XCTAssertEqual(
      decodedLegacy.loaderPollIntervalMilliseconds,
      candidate.strategy.loaderPollIntervalMilliseconds)
    XCTAssertEqual(
      decodedLegacy.hdcCommandTimeoutSeconds,
      candidate.strategy.hdcCommandTimeoutSeconds)
    XCTAssertEqual(
      decodedLegacy.readOnlyCommandTimeoutSeconds,
      candidate.strategy.readOnlyCommandTimeoutSeconds)
    XCTAssertEqual(decodedLegacy.operationReference, candidate.strategy.operationReference)
    XCTAssertEqual(decodedLegacy.deviceProfileReference, candidate.strategy.deviceProfileReference)
    XCTAssertEqual(decodedLegacy.archiveDigestSHA256, candidate.strategy.archiveDigestSHA256)
    XCTAssertEqual(decodedLegacy.stepSetDigestSHA256, candidate.strategy.stepSetDigestSHA256)
    XCTAssertEqual(decodedLegacy.allowedStartingModes, candidate.strategy.allowedStartingModes)
    XCTAssertEqual(decodedLegacy.userdataImpact, candidate.strategy.userdataImpact)
    strategy["loaderDiscoveryTimeoutSeconds"] = NSNull()
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: strategy)))
    strategy["loaderDiscoveryTimeoutSeconds"] =
      candidate.strategy.loaderDiscoveryTimeoutSeconds
    strategy["executable"] = "/usr/local/bin/rkdeveloptool"
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: strategy)))
  }

  func testUnresolvedAttemptReconciliationAlsoClosesTheUsageReservation() async throws {
    // Regression C3: tombstoning the campaign attempt while leaving
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
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)

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
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: reservationID,
      jobID: "job-crashed", sessionID: "session-crashed", at: Self.confirmedAt)

    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: candidate)),
      flash: flash,
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

  func testConfirmedNotExecutedMutationIntentReconcilesSafeAndContinues() async throws {
    let root = temporaryDirectory("campaign-confirmed-not-executed")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion(maxAttempts: 3)
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)

    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: assertion.confirmationDigestSHA256,
      baseCommitOID: assertion.baseCommitOID,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetStableIdentitySHA256: assertion.targetStableIdentitySHA256,
      bindingLineageRootRevision: assertion.bindingLineageRootRevision,
      confirmedAt: assertion.confirmedAt, validUntil: assertion.validUntil,
      maximumAttempts: assertion.maxAttempts)
    let usage = try usageReservation(
      reference: authorityRef, ordinal: 1, jobID: "job-loader-no-effect")
    _ = try usageLedger.reserve(usage)
    _ = try usageLedger.close(
      reservationID: usage.reservationID,
      terminal: AgentAuthorityUsageTerminal(
        status: .failed, closedAt: Self.confirmedAt,
        externalIntentEventIDs: ["intent-enter-loader-mode"],
        confirmedNotExecutedIntentEventIDs: ["intent-enter-loader-mode"]))
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: usage.reservationID,
      jobID: "job-loader-no-effect", sessionID: "session-loader-no-effect",
      at: Self.confirmedAt)

    let flash = SuccessAfterReconciledEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })
    let result = try await host.continueCampaign(
      campaignID: assertion.campaignID,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 2)
    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 1)
    XCTAssertEqual(
      try ledger.load(assertion.campaignID).events
        .filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.safeToReflash, .succeeded])
  }

  func testCompletedAndProvenAbsentMutationsReconcileSafeAndContinue() async throws {
    // The 2026-08-04 job that burned campaign ECAMP-8FE52CB8: every mutation
    // step verified (writes, reboot), then a read-only wait failed and the
    // attempt was sealed unsafePartial while the device booted the flashed
    // build. When every dispatched mutation has a proven resolution — its
    // own verified completion or a proven absence — nothing about the device
    // is unknown, and the campaign may retry.
    let root = temporaryDirectory("campaign-completed-mutations")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion(maxAttempts: 3)
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)

    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: assertion.confirmationDigestSHA256,
      baseCommitOID: assertion.baseCommitOID,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetStableIdentitySHA256: assertion.targetStableIdentitySHA256,
      bindingLineageRootRevision: assertion.bindingLineageRootRevision,
      confirmedAt: assertion.confirmedAt, validUntil: assertion.validUntil,
      maximumAttempts: assertion.maxAttempts)
    let usage = try usageReservation(
      reference: authorityRef, ordinal: 1, jobID: "job-completed-mutations")
    _ = try usageLedger.reserve(usage)
    _ = try usageLedger.close(
      reservationID: usage.reservationID,
      terminal: AgentAuthorityUsageTerminal(
        status: .failed, closedAt: Self.confirmedAt,
        externalIntentEventIDs: [
          "intent-enter-loader-mode", "intent-flash-partitions", "intent-reboot-device",
        ],
        confirmedNotExecutedIntentEventIDs: ["intent-reboot-device"],
        completedIntentEventIDs: ["intent-enter-loader-mode", "intent-flash-partitions"]))
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: usage.reservationID,
      jobID: "job-completed-mutations", sessionID: "session-completed-mutations",
      at: Self.confirmedAt)

    let flash = SuccessAfterReconciledEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })
    let result = try await host.continueCampaign(
      campaignID: assertion.campaignID,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 2)
    XCTAssertEqual(
      try ledger.load(assertion.campaignID).events
        .filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.safeToReflash, .succeeded])
  }

  func testMutationsWithoutAProvenResolutionStayUnsafePartial() async throws {
    // The mutation control: one dispatched mutation with neither a verified
    // completion nor a proven absence keeps the strict partial-write reading,
    // and the campaign stays sealed.
    let root = temporaryDirectory("campaign-partial-mutations")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion(maxAttempts: 3)
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)

    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: assertion.confirmationDigestSHA256,
      baseCommitOID: assertion.baseCommitOID,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetStableIdentitySHA256: assertion.targetStableIdentitySHA256,
      bindingLineageRootRevision: assertion.bindingLineageRootRevision,
      confirmedAt: assertion.confirmedAt, validUntil: assertion.validUntil,
      maximumAttempts: assertion.maxAttempts)
    let usage = try usageReservation(
      reference: authorityRef, ordinal: 1, jobID: "job-partial-mutations")
    _ = try usageLedger.reserve(usage)
    _ = try usageLedger.close(
      reservationID: usage.reservationID,
      terminal: AgentAuthorityUsageTerminal(
        status: .failed, closedAt: Self.confirmedAt,
        externalIntentEventIDs: [
          "intent-enter-loader-mode", "intent-flash-partitions",
        ],
        completedIntentEventIDs: ["intent-enter-loader-mode"]))
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: usage.reservationID,
      jobID: "job-partial-mutations", sessionID: "session-partial-mutations",
      at: Self.confirmedAt)

    let flash = SuccessAfterReconciledEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })
    do {
      _ = try await host.continueCampaign(
        campaignID: assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42")
      XCTFail("an unresolved mutation must keep the campaign sealed")
    } catch {}
    let document = try ledger.load(assertion.campaignID)
    XCTAssertTrue(document.isTerminal)
    XCTAssertEqual(
      document.events.filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.unsafePartial])
    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 0, "a sealed campaign must not dispatch")
  }

  func testDaemonRefusedSubmissionSettlesRetrySafeAndSurfaces() async throws {
    // The 2026-08-04 shape that burned campaign ECAMP-CF1406F8: the daemon
    // (restarted without its HDC path) rejected job.submit, no job was ever
    // created, and the attempt tombstoned as outcomeUnknown — sealing the
    // campaign over a host configuration fault. An authored daemon rejection
    // dispatched nothing: the attempt settles retry-safe, the refusal
    // surfaces to the operator, and the same campaign continues once the
    // daemon is fixed.
    let root = temporaryDirectory("campaign-refused-submission")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion(maxAttempts: 3)
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)

    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: assertion.confirmationDigestSHA256,
      baseCommitOID: assertion.baseCommitOID,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetStableIdentitySHA256: assertion.targetStableIdentitySHA256,
      bindingLineageRootRevision: assertion.bindingLineageRootRevision,
      confirmedAt: assertion.confirmedAt, validUntil: assertion.validUntil,
      maximumAttempts: assertion.maxAttempts)
    let usage = try usageReservation(
      reference: authorityRef, ordinal: 1, jobID: "job-refused-submission")
    let campaignID = assertion.campaignID
    let confirmedAt = Self.confirmedAt
    let flash = RefusalAfterReserveEvolutionFlash {
      _ = try usageLedger.reserve(usage)
      let current = try ledger.load(campaignID)
      guard let candidateID = current.events.compactMap(\.candidate).last?.candidateID
      else { throw RockchipEvolutionCampaignError.campaignStopped("noCandidate") }
      _ = try ledger.reserveAttempt(
        campaignID: campaignID, candidateID: candidateID,
        ordinal: 1, reservationID: usage.reservationID,
        jobID: "job-refused-submission", sessionID: "session-refused-submission",
        at: confirmedAt)
    }
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: usageLedger,
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })
    do {
      _ = try await host.continueCampaign(
        campaignID: assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42")
      XCTFail("a refused submission must surface to the operator")
    } catch let error as RockchipFlashExecutionError {
      guard case .submissionRefused = error else {
        return XCTFail("expected submissionRefused, got \(error)")
      }
    }
    let document = try ledger.load(assertion.campaignID)
    XCTAssertFalse(document.isTerminal, "a refused submission must not seal the campaign")
    XCTAssertEqual(
      document.events.filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.safeToReflash])
    let closed = try usageLedger.load().reservations.first {
      $0.reservationID == usage.reservationID
    }
    XCTAssertEqual(closed?.terminal?.status, .failed)
    XCTAssertEqual(closed?.terminal?.externalIntentEventIDs, [])
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
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate,
      at: Self.confirmedAt)
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: "missing-reservation",
      jobID: "job-1", sessionID: "session-1", at: Self.confirmedAt)

    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger, usageLedger: AgentAuthorityUsageLedger(root: usageRoot),
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: candidate)),
      flash: flash,
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

  func testFixedCandidateAdmissionDoesNotRequireReviewReceipt() async throws {
    let root = temporaryDirectory("campaign-host-zero")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion()
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: candidate)),
      flash: flash,
      nowUTC: { Self.confirmedAt })
    await ain019AssertThrowsAsync(
      try await host.executeConfirmedCampaign(
        confirmationDigestSHA256: assertion.confirmationDigestSHA256,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    let rejectedDispatches = await flash.dispatchCount()
    XCTAssertEqual(rejectedDispatches, 1)
    XCTAssertTrue(try ledger.load(assertion.campaignID).isTerminal)
    XCTAssertNil(try ledger.load(assertion.campaignID).latestCandidate?.review)
  }

  func testHostAutomaticallyRepairsVersionedOperationSafeFailureUntilSuccess() async throws {
    let root = temporaryDirectory("campaign-auto-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let baseline = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250, hdcCommandTimeoutSeconds: 45,
      readOnlyCommandTimeoutSeconds: 30, userdataImpact: "ERASE-USERDATA")
    let flash = SafeFailureThenSuccessEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: baseline, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(),
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

  func testHostPassesClosedLoaderDiagnosticToTheRepairer() async throws {
    let root = temporaryDirectory("campaign-loader-diagnostic")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let baseline = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], hdcCommandTimeoutSeconds: 45,
      userdataImpact: "ERASE-USERDATA")
    let repairer = CapturingEvolutionRepairer(baseline: baseline, repaired: repaired)
    let flash = SafeFailureThenSuccessEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt,
      failureStepID: RockchipFlashRuntimeDiagnostic.enterLoaderHDCNoCleanReceipt
        .evolutionFailureCode)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: repairer,
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })

    _ = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    let observedFailureCodes = await repairer.observedFailureCodes()
    XCTAssertEqual(
      observedFailureCodes,
      [RockchipFlashRuntimeDiagnostic.enterLoaderHDCNoCleanReceipt.evolutionFailureCode])
  }

  func testHostStopsAfterThreeConsecutiveNoEffectAttempts() async throws {
    let root = temporaryDirectory("campaign-stop-no-effect")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 16)
    _ = try ledger.create(assertion)
    let first = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let second = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], loaderDiscoveryTimeoutSeconds: 46,
      userdataImpact: "ERASE-USERDATA")
    let third = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], loaderDiscoveryTimeoutSeconds: 47,
      userdataImpact: "ERASE-USERDATA")
    let flash = SafeFailureThenSuccessEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt, safeFailureCount: 3)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ThreeStageEvolutionRepairer(strategies: [first, second, third]),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })

    await ain019AssertThrowsAsync(
      try await host.executeConfirmedCampaign(
        confirmationDigestSHA256: assertion.confirmationDigestSHA256,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))

    let dispatches = await flash.dispatchCount()
    XCTAssertEqual(dispatches, 3)
    let document = try ledger.load(assertion.campaignID)
    XCTAssertTrue(document.isTerminal)
    XCTAssertEqual(document.reservedAttemptCount, 3)
    XCTAssertEqual(document.events.last?.reasonCode, "repeatedSafeNoEffect")
  }

  func testCandidateThatExcludesLiveModeIsRepairedWithoutConsumingAttempt() async throws {
    let root = temporaryDirectory("campaign-live-mode-repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let wrongMode = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = StartingModeMismatchThenSuccessEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: wrongMode, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(),
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

  func testHostConstrainsRepeatedRepairToTheReadbackStartingMode() async throws {
    let root = temporaryDirectory("campaign-mode-constraint")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let assertion = try makeAssertion(maxAttempts: 3)
    _ = try ledger.create(assertion)
    let loaderOnly = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.loader], loaderDiscoveryTimeoutSeconds: 46,
      userdataImpact: "ERASE-USERDATA")
    let flash = StartingModeMismatchThenSuccessEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt, rejectedStartingMode: "hdcNormal")
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: RepeatingEvolutionRepairer(strategy: loaderOnly),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash, nowUTC: { Self.confirmedAt })

    let result = try await host.executeConfirmedCampaign(
      confirmationDigestSHA256: assertion.confirmationDigestSHA256,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    XCTAssertEqual(result.attemptOrdinal, 1)
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(
      document.events.compactMap(\.candidate).map(\.strategy.allowedStartingModes),
      [[.loader], [.hdcNormal, .loader]])
    XCTAssertEqual(document.reservedAttemptCount, 1)
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
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = PreAdmittingEvolutionFlash(ledger: ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: strategy),
      builder: StrategyEchoEvolutionBuilder(),
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
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal], userdataImpact: "ERASE-USERDATA")
    let repaired = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = PreAdmittingEvolutionFlash(
      ledger: ledger, now: Self.confirmedAt, rejectFirstAdmissionWithMode: "loader")
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: ScriptedEvolutionRepairer(baseline: wrongMode, repaired: repaired),
      builder: StrategyEchoEvolutionBuilder(),
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
      deviceProfileReference: "dayu200", archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let flash = RejectingBeforeReservationEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: baseline),
      builder: StrategyEchoEvolutionBuilder(),
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

  func testLocalAgentRepairerAcceptsOnlyClosedNewTypedStrategy() async throws {
    let root = temporaryDirectory("campaign-repairer")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assertion = try makeAssertion()
    let prior = try makeCandidate(assertion: assertion, ordinal: 1)
    let response = Data(
      """
      {"allowedStartingModes":["hdcNormal","loader"],"loaderDiscoveryTimeoutSeconds":90,"loaderPollIntervalMilliseconds":250,"hdcCommandTimeoutSeconds":45,"readOnlyCommandTimeoutSeconds":30}
      """.utf8)
    let repairer = try LocalAgentRockchipEvolutionStrategyRepairer(
      profile: .codex, executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path, transport: FixedEvolutionCLITransport(response: response))
    let strategy = try await repairer.propose(
      assertion: assertion,
      observation: RockchipEvolutionFailureObservation(
        attemptOrdinal: 1, failureCode: "flash.semanticFailure:enter-loader"),
      priorCandidates: [prior])
    XCTAssertEqual(strategy.loaderDiscoveryTimeoutSeconds, 90)
    XCTAssertEqual(strategy.loaderPollIntervalMilliseconds, 250)
    XCTAssertEqual(strategy.hdcCommandTimeoutSeconds, 45)
    XCTAssertEqual(strategy.readOnlyCommandTimeoutSeconds, 30)

    let invalid = try LocalAgentRockchipEvolutionStrategyRepairer(
      profile: .codex, executablePath: "/usr/bin/true", modelName: "contract-model",
      workingDirectory: root.path,
      transport: FixedEvolutionCLITransport(
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

  /// Each profile declares where its answer is, and the transport must read
  /// exactly there. A CLI that interleaves session diagnostics with the
  /// payload on one stream is why the file channel exists at all; a CLI whose
  /// print mode emits only the payload is why the stdout channel does.
  func testEachProfileResponseChannelReadsTheAnswerAndNotTheDiagnostics() async throws {
    let root = temporaryDirectory("agent-cli-response-channel")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = "{\"result\":\"PASS\",\"issues\":[]}"

    // File channel (codex): stdout is noise, the answer is in the named file.
    let fileFixture = root.appending(path: "file-channel-fixture", directoryHint: .notDirectory)
    try """
      #!/bin/sh
      output=''
      while [ "$#" -gt 0 ]; do
        if [ "$1" = '--output-last-message' ]; then
          output="$2"
          shift 2
          continue
        fi
        shift
      done
      printf '%s' 'session diagnostic that is not JSON\n'
      printf '%s' '\(expected)' > "$output"
      """.write(to: fileFixture, atomically: true, encoding: .utf8)

    // Stdout channel (claude-code print mode): the answer is stdout itself,
    // and no output-file flag is ever passed.
    let stdoutFixture = root.appending(
      path: "stdout-channel-fixture", directoryHint: .notDirectory)
    try """
      #!/bin/sh
      for argument in "$@"; do
        if [ "$argument" = '--output-last-message' ]; then
          echo 'a stdout-channel profile must not be given an output file' >&2
          exit 3
        fi
      done
      printf '%s\\n' '\(expected)'
      """.write(to: stdoutFixture, atomically: true, encoding: .utf8)

    for (profile, executable) in [
      (HarnessLocalAgentCLIProfile.codex, fileFixture),
      (HarnessLocalAgentCLIProfile.claudeCode, stdoutFixture),
    ] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
      let digest = SHA256.hash(data: try Data(contentsOf: executable))
        .map { String(format: "%02x", $0) }.joined()
      let response = try await LocalAgentCLIProcessTransport().send(
        HarnessLocalAgentCLIRequest(
          executablePath: executable.path, executableSHA256: digest, profile: profile,
          modelName: "contract-model", prompt: "return JSON",
          workingDirectory: root.path, timeoutSeconds: 10))
      XCTAssertEqual(
        String(decoding: response, as: UTF8.self), expected,
        "\(profile.profileID) read the wrong channel")
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
    let candidate = try makeCandidate(assertion: historical, ordinal: 1)
    _ = try ledger.create(historical)
    _ = try ledger.appendCandidate(
      campaignID: historical.campaignID, candidate: candidate,
      at: Self.confirmedAt)
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
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    let flash = CountingEvolutionFlash()
    let host = try RockchipEvolutionCampaignHost(
      ledger: ledger,
      usageLedger: AgentAuthorityUsageLedger(root: root.appending(path: "usage")),
      repairer: FixedEvolutionRepairer(strategy: candidate.strategy),
      builder: FixedEvolutionBuilder(
        build: RockchipEvolutionCandidateBuild(
          pin: candidate)),
      flash: flash,
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
    XCTAssertEqual(dispatches, 1)
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

  func testPublishedStrategyRepairerSuppliesTheFirstCandidateWithoutAVendor() async throws {
    let assertion = try makeAssertion()

    let strategy = try await PublishedRockchipEvolutionStrategyRepairer().propose(
      assertion: assertion, observation: nil, priorCandidates: [])

    XCTAssertEqual(
      strategy.operationReference,
      RockchipEvolutionCampaignConfirmationAssertion.operationReference)
    XCTAssertEqual(strategy.archiveDigestSHA256, assertion.archiveDigestSHA256)
    XCTAssertEqual(strategy.stepSetDigestSHA256, assertion.stepSetDigestSHA256)
    XCTAssertEqual(
      strategy.userdataImpact,
      RockchipEvolutionCampaignConfirmationAssertion.dataImpact)
    XCTAssertEqual(
      strategy.loaderDiscoveryTimeoutSeconds,
      RockchipEvolutionTypedStrategy.defaultLoaderDiscoveryTimeoutSeconds)
    XCTAssertEqual(
      Set(strategy.allowedStartingModes), Set(RockchipEvolutionStartingMode.allCases))
  }

  func testPublishedStrategyRepairerRefusesToInventARepair() async throws {
    let assertion = try makeAssertion()
    let repairer = PublishedRockchipEvolutionStrategyRepairer()
    let observation = try RockchipEvolutionFailureObservation(
      attemptOrdinal: 1, failureCode: "flash.outcomeUnknown")

    do {
      _ = try await repairer.propose(
        assertion: assertion, observation: observation, priorCandidates: [])
      XCTFail("a repair with no configured repairer must not be invented")
    } catch let error as RockchipEvolutionCampaignError {
      XCTAssertEqual(error, .candidateRejected("repairerUnavailable"))
    }

    do {
      _ = try await repairer.propose(
        assertion: assertion, observation: nil,
        priorCandidates: [try makeCandidate(assertion: assertion, ordinal: 1)])
      XCTFail("a second candidate with no configured repairer must not be invented")
    } catch let error as RockchipEvolutionCampaignError {
      XCTAssertEqual(error, .candidateRejected("repairerUnavailable"))
    }
  }

  // MARK: historical campaign CLI is decode/export only (TASK-AIN-019)

  func testFlashPreviewIsRetiredBeforeReadingTheArchiveOrMintingAConfirmation() throws {
    // The retired writer must refuse without consulting the host, a device, or
    // the archive. Runtime owns new destructive admission through typed Jobs.
    let result = try runCLI([
      "flash", "preview", "--images", "/tmp/arkdeck-ain019-absent-images.tar.gz",
    ])
    XCTAssertEqual(result.status, 64, result.output)
    XCTAssertTrue(result.output.contains("historical campaign preview is retired"), result.output)
    XCTAssertTrue(result.output.contains("Runtime owns Flash admission"), result.output)
    XCTAssertFalse(result.output.contains("flash preflight"), result.output)
    XCTAssertFalse(result.output.contains("confirmation digest:"), result.output)
    XCTAssertFalse(
      result.output.contains("确认本次 Evolution Flash campaign"), result.output)
  }

  func testActiveFlashCLICannotReachHistoricalCampaignWriters() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)
    let runFlashStart = try XCTUnwrap(
      source.range(of: "static func runFlash(_ arguments: [String]) async throws"))
    let reconcileStart = try XCTUnwrap(
      source.range(of: "// MARK: reconcile", range: runFlashStart.upperBound..<source.endIndex))
    let activeFlashSurface = source[runFlashStart.lowerBound..<reconcileStart.lowerBound]

    XCTAssertTrue(activeFlashSurface.contains("historical campaign preview is retired"))
    XCTAssertTrue(activeFlashSurface.contains("historical campaign continuation is retired"))
    for retiredWriter in ["runCampaignPreview(", "runExecute(", "runCampaignContinue("] {
      XCTAssertFalse(
        activeFlashSurface.contains(retiredWriter),
        "the active flash CLI must not call legacy writer \(retiredWriter)")
    }
  }

  // MARK: unknown Loader transition settled by readback (TASK-AIN-019 r11)

  func testUnknownLoaderTransitionSettlesSafeWhenTheBoundTargetIsReadBackRegistered()
    async throws
  {
    let context = try makeUnknownLoaderAttempt(label: "settled")
    defer { try? FileManager.default.removeItem(at: context.root) }

    let flash = SuccessAfterReconciledEvolutionFlash(
      ledger: context.ledger, now: Self.confirmedAt)
    let host = try RockchipEvolutionCampaignHost(
      ledger: context.ledger, usageLedger: context.usageLedger,
      repairer: FixedEvolutionRepairer(strategy: context.candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: flash,
      targetReadback: FixedEvolutionTargetReadback(
        readback: RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .hdcNormal,
          usbTopology: "42")),
      attemptIntents: FixedEvolutionAttemptIntents(kinds: ["enterUpdater"]),
      nowUTC: { Self.confirmedAt })

    let result = try await host.continueCampaign(
      campaignID: context.assertion.campaignID,
      archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
      targetLocationSelector: "42")

    // The unknown attempt is settled as a no-effect failure and the campaign
    // reserves its next ordinal instead of being sealed on attempt 1.
    XCTAssertEqual(result.attemptOrdinal, 2)
    XCTAssertEqual(
      try context.ledger.load(context.assertion.campaignID).events
        .filter { $0.kind == .attemptTerminal }.map(\.disposition),
      [.safeToReflash, .succeeded])
    // The durable usage terminal is append-only and stays exactly as the
    // runtime closed it: the readback settles the campaign attempt, it does
    // not rewrite authority history.
    let usageTerminal = try XCTUnwrap(
      context.usageLedger.load().reservations
        .first { $0.reservationID == context.reservationID }?.terminal)
    XCTAssertEqual(usageTerminal.status, .outcomeUnknown)
  }

  func testUnknownLoaderTransitionStaysSealedWithoutAnExactRegisteredReadback() async throws {
    // Each row removes exactly one leg of the proof. None of them may settle.
    let cases: [(label: String, readback: RockchipEvolutionTargetReadback, kinds: [String])] = [
      ("absent", .absent, ["enterUpdater"]),
      (
        "identity-drift",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: String(repeating: "b", count: 64),
          registeredMode: .loader, usbTopology: "42"),
        ["enterUpdater"]
      ),
      (
        "unregistered-mode",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: nil,
          usbTopology: "42"),
        ["enterUpdater"]
      ),
      // A destructive intent is never made safe by the device coming back.
      (
        "destructive-intent",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .loader,
          usbTopology: "42"),
        ["enterUpdater", "flashPartition"]
      ),
      // A build that cannot name a journaled step cannot prove anything.
      (
        "unrecognized-intent",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .loader,
          usbTopology: "42"),
        ["enterUpdater", "someFutureKind"]
      ),
      // No transition intent at all is not a Loader transition failure.
      (
        "no-transition-intent",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .loader,
          usbTopology: "42"),
        ["verifyRemoteState"]
      ),
    ]

    for row in cases {
      let context = try makeUnknownLoaderAttempt(label: row.label)
      defer { try? FileManager.default.removeItem(at: context.root) }
      let flash = CountingEvolutionFlash()
      let host = try RockchipEvolutionCampaignHost(
        ledger: context.ledger, usageLedger: context.usageLedger,
        repairer: FixedEvolutionRepairer(strategy: context.candidate.strategy),
        builder: StrategyEchoEvolutionBuilder(),
        flash: flash,
        targetReadback: FixedEvolutionTargetReadback(readback: row.readback),
        attemptIntents: FixedEvolutionAttemptIntents(kinds: row.kinds),
        nowUTC: { Self.confirmedAt })

      await ain019AssertThrowsAsync(
        try await host.continueCampaign(
          campaignID: context.assertion.campaignID,
          archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
          targetLocationSelector: "42"))
      let dispatches = await flash.dispatchCount()
      XCTAssertEqual(dispatches, 0, row.label)
      let document = try context.ledger.load(context.assertion.campaignID)
      XCTAssertTrue(document.isTerminal, row.label)
      XCTAssertEqual(
        document.events.last { $0.kind == .attemptTerminal }?.disposition,
        .outcomeUnknown, row.label)
    }
  }

  func testUnknownLoaderTransitionStaysSealedWhenTheRuntimeCannotBeAsked() async throws {
    // The default composition: no evidence reader wired. Refusing to answer
    // must behave like "not proven", never like "no destructive intents".
    let context = try makeUnknownLoaderAttempt(label: "no-reader")
    defer { try? FileManager.default.removeItem(at: context.root) }
    let host = try RockchipEvolutionCampaignHost(
      ledger: context.ledger, usageLedger: context.usageLedger,
      repairer: FixedEvolutionRepairer(strategy: context.candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: CountingEvolutionFlash(),
      targetReadback: FixedEvolutionTargetReadback(
        readback: RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .loader,
          usbTopology: "42")),
      nowUTC: { Self.confirmedAt })

    await ain019AssertThrowsAsync(
      try await host.continueCampaign(
        campaignID: context.assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))
    XCTAssertEqual(
      try context.ledger.load(context.assertion.campaignID).events
        .last { $0.kind == .attemptTerminal }?.disposition,
      .outcomeUnknown)
  }

  func testLoaderTransitionClassificationExcludesEveryDestructiveOrUnknownKind() {
    // Exactly what `flash.dayu200` journals when it dies at the transition:
    // its host-only prefix plus the enterUpdater intent, and nothing past it.
    XCTAssertTrue(
      RockchipEvolutionCampaignHost.isLoaderTransitionOnly(
        ["verifyArtifact", "hashFile", "requestConfirmation", "enterUpdater"]))
    XCTAssertTrue(
      RockchipEvolutionCampaignHost.isLoaderTransitionOnly(
        ["enterUpdater", "waitForDisconnect", "waitForReconnect", "probeDevice"]))
    for excluded in [
      ["enterUpdater", "flashPartition"], ["enterUpdater", "erasePartition"],
      ["enterUpdater", "updatePackage"], ["enterUpdater", "formatPartition"],
      ["enterUpdater", "mutateHDCServerLifecycle"], ["enterUpdater", ""],
      ["verifyRemoteState"], [],
    ] {
      XCTAssertFalse(
        RockchipEvolutionCampaignHost.isLoaderTransitionOnly(excluded), "\(excluded)")
    }
  }

  // MARK: reconciliation reachability and basis (TASK-AIN-020, r17)

  /// AIN-RECON-001, engine half. The readback's input is an `outcomeUnknown`
  /// usage terminal written by the **engine** — a job that survived, could not
  /// observe its own outcome, and journaled its intents. Three device windows
  /// never reached the readback because every one of them killed that writer,
  /// leaving no durable terminal at all, so nothing had ever proved this
  /// terminal is producible rather than only seedable.
  ///
  /// Real-input gated, and unavoidably so: `validateCampaignReservation`
  /// admits a campaign reservation for `flash.dayu200` and nothing else, and
  /// that operation's host steps read a genuine DAYU200 images archive. No
  /// device is involved — the first mutating dispatch never spawns.
  func testTheEngineWritesTheUnknownTerminalTheReadbackConsumes() async throws {
    guard let archivePath = ProcessInfo.processInfo.environment[Self.archiveEnvironmentKey]
    else {
      throw XCTSkip("set \(Self.archiveEnvironmentKey) for the 7.0.0.35 real-input gate")
    }
    let profile = RockchipFlashProfile.dayu200
    let root = temporaryDirectory("engine-written-unknown")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let artifactStore = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts"), nowUTC: { Self.confirmedAt })
    let archive = try await artifactStore.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "job-input-archive", sessionID: "session-input-archive",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-70035", bindingRevision: 7,
          stableIdentitySHA256: Self.engineDeviceIdentity),
        sourceFileURL: URL(fileURLWithPath: archivePath).standardizedFileURL,
        expectedByteCount: Int(profile.archiveSizeBytes),
        expectedSHA256: profile.archiveSHA256))
    let lease = try await artifactStore.leaseReference(
      jobID: archive.jobID, artifactID: archive.artifactID)

    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: digest("f"),
      baseCommitOID: String(repeating: "a", count: 40),
      planDigestSHA256: digest("b"),
      archiveDigestSHA256: profile.archiveSHA256,
      stepSetDigestSHA256: digest("d"),
      targetStableIdentitySHA256: Self.engineDeviceIdentity,
      bindingLineageRootRevision: 7,
      confirmedAt: "2026-08-02T07:00:00Z", validUntil: "2026-08-02T11:00:00Z",
      maximumAttempts: 8)
    let operationDigest = digest("1")
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: authorityRef, jobID: "job-engine-unknown",
      operationDigestSHA256: operationDigest,
      targetDigestSHA256: Self.engineDeviceIdentity)
    _ = try usageLedger.reserve(
      AgentAuthorityUsageReservation(
        reservationID: reservationID, authorizationRef: authorityRef, ordinal: 1,
        maximumUses: 8, maximumConcurrentJobs: 1, jobID: "job-engine-unknown",
        operationDigestSHA256: operationDigest,
        targetDigestSHA256: Self.engineDeviceIdentity,
        reservedAt: "2026-08-02T07:30:00Z",
        forwardLeaseExpiresAt: "2026-08-02T10:00:00Z",
        compensationLeaseExpiresAt: "2026-08-02T10:30:00Z",
        campaignEvidenceProvenance: try AgentAuthorityCampaignEvidenceProvenance(
          candidateDigestSHA256: digest("c"), brokerDigestSHA256: digest("e"),
          executionTuning: try AgentAuthorityCampaignExecutionTuning(
            loaderDiscoveryTimeoutSeconds: 90,
            loaderPollIntervalMilliseconds: 250,
            hdcCommandTimeoutSeconds: 7,
            readOnlyCommandTimeoutSeconds: 9)),
        terminal: nil))

    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [
        RockchipFlashProviderAdapter(
          factsPort: UnknownOutcomeFlashFactsPort(), availability: .available)
      ]),
      dispatcher: LosesTheChildOnFirstMutationDispatcher(),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(path: "capabilities")),
      artifactStore: artifactStore,
      agentUsageLedger: usageLedger,
      nowUTC: { Self.confirmedAt })

    let request = try RuntimeOperationRequest(
      requestID: "req-campaign-unknown", idempotencyKey: "idem-campaign-unknown",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-70035", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: [
        "imageBundleLease": .string(lease),
        "deviceProfile": .string(profile.catalogReference),
        "partitionPlan": .array(profile.mappedPartitions.map { .string($0.partitionName) }),
        "postFlashVerification": .string("basic"),
      ],
      campaignReservation: RuntimeCampaignReservationReference(reservationID: reservationID))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let acceptance = try await engine.submit(try encoder.encode(request))
    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertTrue(parked.outcomeUnknown, "\(parked.timeline)")
    XCTAssertEqual(parked.state, "waitingForRecovery")

    // The half that was missing in every device window: a terminal, written by
    // the engine, carrying the intents it journaled rather than an absence.
    let engineTerminal = try XCTUnwrap(
      usageLedger.load().reservations.first { $0.reservationID == reservationID }?.terminal,
      "an engine that survives its own unknown outcome must close the reservation")
    XCTAssertEqual(engineTerminal.status, .outcomeUnknown)
    XCTAssertFalse(
      engineTerminal.externalIntentEventIDs.isEmpty,
      "the intent sets must be the journaled ones, not an absence")
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(terminal: engineTerminal),
      .requiresLoaderTransitionReadback(
        basis: "terminal=outcomeUnknown dispatched=1 confirmedNotExecuted=0 completed=0 "
          + "rule=loaderTransitionReadback"),
      "this is the one terminal shape that reaches the readback")
  }

  /// AIN-RECON-001, campaign half: both conclusions the readback can draw from
  /// the terminal the engine writes, and a record that says which one it drew.
  func testBothReadbackConclusionsAreReachedAndTheBasisSaysWhich() async throws {
    for (label, readback, expected, expectedBasis) in [
      (
        "settled",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.targetDigest, registeredMode: .hdcNormal,
          usbTopology: "42"),
        RockchipEvolutionAttemptDisposition.safeToReflash, "readback=settled"
      ),
      (
        "refused", .absent, RockchipEvolutionAttemptDisposition.outcomeUnknown,
        "readback=refused"
      ),
    ] {
      let context = try makeUnknownLoaderAttempt(label: "basis-\(label)")
      defer { try? FileManager.default.removeItem(at: context.root) }
      let host = try RockchipEvolutionCampaignHost(
        ledger: context.ledger, usageLedger: context.usageLedger,
        repairer: FixedEvolutionRepairer(strategy: context.candidate.strategy),
        builder: StrategyEchoEvolutionBuilder(),
        flash: CountingEvolutionFlash(),
        targetReadback: FixedEvolutionTargetReadback(readback: readback),
        attemptIntents: FixedEvolutionAttemptIntents(kinds: ["enterUpdater"]),
        nowUTC: { Self.confirmedAt })
      await ain019AssertThrowsAsync(
        try await host.continueCampaign(
          campaignID: context.assertion.campaignID,
          archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
          targetLocationSelector: "42"))
      let closed = try XCTUnwrap(
        try context.ledger.load(context.assertion.campaignID).events
          .first { $0.kind == .attemptTerminal })
      XCTAssertEqual(closed.disposition, expected, label)
      // The branch reconciliation took is readable, not inferred: it names the
      // terminal it read, the intent arithmetic, the rule, and the readback's
      // own answer.
      let basis = try XCTUnwrap(closed.detail, label)
      XCTAssertTrue(basis.contains("terminal=outcomeUnknown"), basis)
      XCTAssertTrue(basis.contains("rule=loaderTransitionReadback"), basis)
      XCTAssertTrue(basis.contains(expectedBasis), basis)
    }
  }

  /// AIN-RECON-001, the other half. A crashed attempt leaves no durable
  /// terminal, and that is an absence rather than a measurement: it never
  /// consults the readback, and the record says so instead of implying a
  /// recovery path that did not run.
  func testNoDurableTerminalIsAnAbsenceAndNeverReachesTheReadback() async throws {
    let context = try makeUnknownLoaderAttempt(label: "no-terminal")
    defer { try? FileManager.default.removeItem(at: context.root) }
    // Erase the seeded terminal: this is a reservation whose writer died.
    try stripTerminal(from: context.usageLedger, reservationID: context.reservationID)

    // The readback would settle if it were consulted — every other leg of the
    // proof is present. It must still not be consulted.
    let readback = CountingEvolutionTargetReadback(
      readback: RockchipEvolutionTargetReadback(
        stableIdentitySHA256: Self.targetDigest, registeredMode: .hdcNormal,
        usbTopology: "42"))
    let host = try RockchipEvolutionCampaignHost(
      ledger: context.ledger, usageLedger: context.usageLedger,
      repairer: FixedEvolutionRepairer(strategy: context.candidate.strategy),
      builder: StrategyEchoEvolutionBuilder(),
      flash: CountingEvolutionFlash(),
      targetReadback: readback,
      attemptIntents: FixedEvolutionAttemptIntents(kinds: ["enterUpdater"]),
      nowUTC: { Self.confirmedAt })
    await ain019AssertThrowsAsync(
      try await host.continueCampaign(
        campaignID: context.assertion.campaignID,
        archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"),
        targetLocationSelector: "42"))

    let closed = try XCTUnwrap(
      try context.ledger.load(context.assertion.campaignID).events
        .first { $0.kind == .attemptTerminal })
    XCTAssertEqual(closed.disposition, .outcomeUnknown)
    XCTAssertEqual(closed.detail, "noDurableTerminal")
    XCTAssertEqual(
      readback.readCount, 0,
      "a crashed attempt is an absence; nothing may read the device on its behalf")
    // The reservation is still closed, or the target stays blocked forever —
    // with empty sets, because nothing measured anything.
    let terminal = try XCTUnwrap(
      context.usageLedger.load().reservations
        .first { $0.reservationID == context.reservationID }?.terminal)
    XCTAssertEqual(terminal.status, .outcomeUnknown)
    XCTAssertEqual(terminal.externalIntentEventIDs, [])
  }

  /// AIN-RECON-002. Proof of no effect outranks the terminal's status. Until
  /// r17 the status was tested first, so the intent-set rules beneath it could
  /// not be reached for `outcomeUnknown` at all.
  ///
  /// Tested on the classifier rather than through the ledger for a reason the
  /// row below states outright: the ledger currently refuses to hold this
  /// shape, so a ledger-level test could only assert that it is impossible —
  /// which would leave the rule order itself untested and free to regress.
  func testProofOfNoEffectOutranksTheTerminalStatus() throws {
    let proven = try AgentAuthorityUsageTerminal(
      status: .failed, closedAt: Self.confirmedAt,
      externalIntentEventIDs: ["intent-enter-loader-mode", "intent-reboot-device"],
      confirmedNotExecutedIntentEventIDs: [
        "intent-enter-loader-mode", "intent-reboot-device",
      ])
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(terminal: proven),
      .decided(
        .safeToReflash,
        basis: "terminal=failed dispatched=2 confirmedNotExecuted=2 completed=0 "
          + "rule=everyDispatchedMutationConfirmedNotExecuted"))

    // The same evidence must win under `outcomeUnknown` too — the rule is
    // ordered above the status, so it cannot be short-circuited again if the
    // ledger invariant below ever moves. Delete that rule and this row falls
    // through to the readback branch instead.
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(
        status: .outcomeUnknown,
        dispatched: ["intent-enter-loader-mode"],
        confirmedNotExecuted: ["intent-enter-loader-mode"],
        completed: []),
      .decided(
        .safeToReflash,
        basis: "terminal=outcomeUnknown dispatched=1 confirmedNotExecuted=1 completed=0 "
          + "rule=everyDispatchedMutationConfirmedNotExecuted"))

    // An absence is not a proof, in either direction. No terminal stays
    // unknown; an unknown terminal with nothing proven still goes to the
    // readback rather than to a disposition.
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(terminal: nil),
      .decided(.outcomeUnknown, basis: "noDurableTerminal"))
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(
        terminal: try AgentAuthorityUsageTerminal(
          status: .outcomeUnknown, closedAt: Self.confirmedAt,
          externalIntentEventIDs: ["intent-enter-loader-mode"])),
      .requiresLoaderTransitionReadback(
        basis: "terminal=outcomeUnknown dispatched=1 confirmedNotExecuted=0 completed=0 "
          + "rule=loaderTransitionReadback"))

    // `unsafePartial` is unchanged, word for word: one dispatched mutation with
    // no proven resolution is still an unknown partial effect, and no
    // reordering above may reach it.
    XCTAssertEqual(
      RockchipEvolutionCampaignHost.classify(
        terminal: try AgentAuthorityUsageTerminal(
          status: .failed, closedAt: Self.confirmedAt,
          externalIntentEventIDs: ["intent-flash-partitions", "intent-reboot-device"],
          confirmedNotExecutedIntentEventIDs: ["intent-reboot-device"])),
      .decided(
        .unsafePartial,
        basis: "terminal=failed dispatched=2 confirmedNotExecuted=1 completed=0 "
          + "rule=unresolvedDispatchedMutations"))
  }

  /// Why the literal AIN-RECON-002 scenario cannot be built through the ledger,
  /// recorded rather than left to be rediscovered.
  ///
  /// `AgentAuthorityUsageTerminal` refuses a non-empty proven-absent set unless
  /// the status is `.failed`, so an `outcomeUnknown` terminal cannot carry the
  /// proof at all. The `else if` ordering was never the binding constraint —
  /// this invariant is. Both facts are pinned so the next reader does not have
  /// to re-derive which one holds.
  func testAnUnknownTerminalCannotCarryTheProofItWouldNeed() throws {
    XCTAssertThrowsError(
      try AgentAuthorityUsageTerminal(
        status: .outcomeUnknown, closedAt: Self.confirmedAt,
        externalIntentEventIDs: ["intent-enter-loader-mode"],
        confirmedNotExecutedIntentEventIDs: ["intent-enter-loader-mode"]))
    // And the engine cannot produce that shape either: a step proven not to
    // have executed ends its job, so the job's status is `failed` and never
    // `outcomeUnknown`.
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      source.contains("status = state == JobState.succeeded.rawValue ? .succeeded : .failed"),
      "a confirmed outcome still closes the reservation as succeeded or failed")
  }

  // MARK: campaignStopped detail (TASK-AIN-019)

  /// A campaign that stopped for good and a confirmation that merely lapsed
  /// need opposite next moves, so `continue` must not answer both with one
  /// word.
  ///
  /// Terminal says: establish what the device is before starting anything new.
  /// Expired says: nothing about the device changed — preview and confirm
  /// again. `terminalOrExpired` told a caller neither, so it stopped for a
  /// human. Measured on the interrupt window of 2026-08-06, where an attempt
  /// ended `outcomeUnknown` and the refusal named no cause.
  func testContinueSaysWhetherTheCampaignEndedOrTheConfirmationLapsed() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/AgentComposition/EvolutionCampaignHost.swift"),
      encoding: .utf8)

    XCTAssertFalse(
      source.contains("campaignStopped(\"terminalOrExpired\")"),
      "the two situations are one reason code again")
    XCTAssertTrue(
      source.contains("\"campaignTerminal:\\(disposition"),
      "a terminal campaign must say which disposition ended it")
    XCTAssertTrue(
      source.contains("\"confirmationExpired:\\(document.assertion.validUntil)\""),
      "an expired confirmation must say when it lapsed")
    // Separate guards, so neither answer can be reached by the other's
    // condition.
    XCTAssertTrue(source.contains("guard !document.isTerminal else {"))
    XCTAssertTrue(source.contains("guard document.assertion.isValid(at: nowUTC()) else {"))
    // The neighbours that were already precise stay that way.
    for existing in ["repeatedSafeNoEffect", "attemptBudgetExhausted"] {
      XCTAssertTrue(
        source.contains("campaignStopped(\"\(existing)\")"),
        "\(existing) lost its own reason code")
    }
  }

  func testCampaignStoppedCarriesTheUnderlyingErrorAndDecodesWithoutIt() throws {
    let root = temporaryDirectory("campaign-stop-detail")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root)
    let assertion = try makeAssertion()
    _ = try ledger.create(assertion)
    let raw = "dispatch refused: process died on signal 6\nlibsecinit abort"
    _ = try ledger.stop(
      campaignID: assertion.campaignID, reasonCode: "admissionOrTargetDrift",
      detail: raw, at: Self.confirmedAt)

    let stopped = try XCTUnwrap(
      try ledger.load(assertion.campaignID).events.last { $0.kind == .campaignStopped })
    XCTAssertEqual(stopped.reasonCode, "admissionOrTargetDrift")
    // Single-line, control-free and bounded, but still the real cause.
    XCTAssertEqual(
      stopped.detail, "dispatch refused: process died on signal 6 libsecinit abort")

    // Oversized text is bounded rather than refused at the call site…
    let overlong = String(repeating: "x", count: 4_000)
    XCTAssertEqual(
      RockchipEvolutionCampaignEvent.sanitizedDetail(overlong)?.utf8.count,
      RockchipEvolutionCampaignEvent.maximumDetailBytes)
    // …and the durable invariant refuses anything that skipped that step.
    XCTAssertThrowsError(
      try RockchipEvolutionCampaignEvent(
        sequence: 1, kind: .campaignStopped, at: Self.confirmedAt,
        reasonCode: "admissionOrTargetDrift", detail: overlong))
    // `detail` belongs to the two events whose cause lives outside the
    // campaign's closed vocabulary: a stop, and — since r17 — an attempt
    // terminal, which carries the basis reconciliation classified it on
    // (TASK-AIN-020). The same bound applies.
    XCTAssertNoThrow(
      try RockchipEvolutionCampaignEvent(
        sequence: 1, kind: .attemptTerminal, at: Self.confirmedAt, ordinal: 1,
        jobID: "job-1", sessionID: "session-1", disposition: .safeToReflash,
        detail: "noDurableTerminal"))
    XCTAssertThrowsError(
      try RockchipEvolutionCampaignEvent(
        sequence: 1, kind: .attemptTerminal, at: Self.confirmedAt, ordinal: 1,
        jobID: "job-1", sessionID: "session-1", disposition: .safeToReflash,
        detail: overlong))
    // And to nothing else.
    for kind in [
      RockchipEvolutionCampaignEventKind.candidatePrepared, .attemptReserved,
    ] {
      XCTAssertThrowsError(
        try RockchipEvolutionCampaignEvent(
          sequence: 1, kind: kind, at: Self.confirmedAt, ordinal: 1,
          reservationID: kind == .attemptReserved ? "reservation-1" : nil,
          jobID: "job-1", sessionID: "session-1", detail: "not here"),
        "\(kind)")
    }
  }

  func testCampaignDocumentsWrittenBeforeDetailStillDecode() throws {
    let root = temporaryDirectory("campaign-stop-detail-legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root)
    let assertion = try makeAssertion()
    _ = try ledger.create(assertion)
    _ = try ledger.stop(
      campaignID: assertion.campaignID, reasonCode: "attemptBudgetExhausted",
      detail: "budget spent", at: Self.confirmedAt)

    // Strip the new key exactly as a document written before this change has it.
    let ledgerURL = root.appending(path: "\(assertion.campaignID).json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    var events = try XCTUnwrap(document["events"] as? [[String: Any]])
    for index in events.indices { events[index].removeValue(forKey: "detail") }
    document["events"] = events
    try JSONSerialization.data(withJSONObject: document).write(to: ledgerURL)

    let reloaded = try ledger.load(assertion.campaignID)
    XCTAssertTrue(reloaded.isTerminal)
    XCTAssertEqual(
      reloaded.events.last { $0.kind == .campaignStopped }?.reasonCode,
      "attemptBudgetExhausted")
    XCTAssertNil(reloaded.events.last { $0.kind == .campaignStopped }?.detail)
  }

  private struct UnknownLoaderAttempt {
    let root: URL
    let ledger: RockchipEvolutionCampaignLedger
    let usageLedger: AgentAuthorityUsageLedger
    let assertion: RockchipEvolutionCampaignConfirmationAssertion
    let candidate: RockchipEvolutionCandidatePin
    let reservationID: String
  }

  /// One campaign whose attempt 1 ended exactly the way 2026-08-04's four did:
  /// a durable `outcomeUnknown` usage terminal carrying one Loader-transition
  /// intent.
  private func makeUnknownLoaderAttempt(label: String) throws -> UnknownLoaderAttempt {
    let root = temporaryDirectory("campaign-unknown-loader-\(label)")
    let ledger = try RockchipEvolutionCampaignLedger(root: root.appending(path: "campaign"))
    let usageLedger = try AgentAuthorityUsageLedger(root: root.appending(path: "usage"))
    let assertion = try makeAssertion(maxAttempts: 3)
    let candidate = try makeCandidate(assertion: assertion, ordinal: 1)
    _ = try ledger.create(assertion)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: candidate, at: Self.confirmedAt)
    let authorityRef = AgentExecutionAuthorityReference.evolutionCampaignConfirmation(
      campaignDigestSHA256: assertion.confirmationDigestSHA256,
      baseCommitOID: assertion.baseCommitOID,
      planDigestSHA256: assertion.planDigestSHA256,
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      targetStableIdentitySHA256: assertion.targetStableIdentitySHA256,
      bindingLineageRootRevision: assertion.bindingLineageRootRevision,
      confirmedAt: assertion.confirmedAt, validUntil: assertion.validUntil,
      maximumAttempts: assertion.maxAttempts)
    let usage = try usageReservation(
      reference: authorityRef, ordinal: 1, jobID: "job-loader-unknown")
    _ = try usageLedger.reserve(usage)
    _ = try usageLedger.close(
      reservationID: usage.reservationID,
      terminal: AgentAuthorityUsageTerminal(
        status: .outcomeUnknown, closedAt: Self.confirmedAt,
        externalIntentEventIDs: ["intent-enter-loader-mode"]))
    _ = try ledger.reserveAttempt(
      campaignID: assertion.campaignID, candidateID: candidate.candidateID,
      ordinal: 1, reservationID: usage.reservationID,
      jobID: "job-loader-unknown", sessionID: "session-loader-unknown",
      at: Self.confirmedAt)
    return UnknownLoaderAttempt(
      root: root, ledger: ledger, usageLedger: usageLedger, assertion: assertion,
      candidate: candidate, reservationID: usage.reservationID)
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

  private func makeCandidate(
    assertion: RockchipEvolutionCampaignConfirmationAssertion, ordinal: Int
  ) throws -> RockchipEvolutionCandidatePin {
    let suffix = String(format: "%016X", ordinal)
    let strategy = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200",
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
    return candidate
  }

  private func historicalReview(
    candidate: RockchipEvolutionCandidatePin,
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    reviewerID: String,
    issues: [[String: String]] = []
  ) throws -> RockchipEvolutionReviewReceipt {
    let json: [String: Any] = [
      "reviewID": "EREVIEW-0000000000000001",
      "reviewerID": reviewerID,
      "candidateID": candidate.candidateID,
      "candidateExecutableDigestSHA256": candidate.executableDigestSHA256,
      "planDigestSHA256": assertion.planDigestSHA256,
      "result": "PASS",
      "issues": issues,
      "createdAt": Self.confirmedAt,
    ]
    return try JSONDecoder().decode(
      RockchipEvolutionReviewReceipt.self,
      from: JSONSerialization.data(withJSONObject: json))
  }

  /// The device identity the engine-lane fixture re-proves at consume time.
  /// Distinct from `targetDigest`, which is what the *campaign* pins: the
  /// engine's gate and the campaign's readback check different subjects, and
  /// collapsing them into one constant would hide that.
  private static let engineDeviceIdentity =
    "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547"

  /// The same real-input gate every campaign-lane engine test uses. It names a
  /// published archive on disk, not a device.
  private static let archiveEnvironmentKey = "ARKDECK_DAYU200_70035_IMAGE"

  /// A fresh campaign whose open attempt is bound to a usage reservation
  /// already carrying `terminal` — the shape some other writer produced.
  private func makeAttemptBoundTo(
    terminal: AgentAuthorityUsageTerminal, label: String
  ) throws -> UnknownLoaderAttempt {
    let context = try makeUnknownLoaderAttempt(label: label)
    try rewriteTerminal(
      in: context.usageLedger, reservationID: context.reservationID,
      to: JSONSerialization.jsonObject(with: try JSONEncoder().encode(terminal))
        as? [String: Any])
    return context
  }

  private func stripTerminal(
    from ledger: AgentAuthorityUsageLedger, reservationID: String
  ) throws {
    try rewriteTerminal(in: ledger, reservationID: reservationID, to: nil)
  }

  /// The ledger is append-only and write-once by design, so a test that needs
  /// a reservation in a state its API cannot reach edits the document behind
  /// it. Reserved for exactly that: expressing "the writer died before it
  /// closed anything", which no legitimate caller can perform.
  private func rewriteTerminal(
    in ledger: AgentAuthorityUsageLedger, reservationID: String, to terminal: [String: Any]?
  ) throws {
    let url = ledger.root.appending(path: AgentAuthorityUsageLedger.ledgerFileName)
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    var reservations = try XCTUnwrap(document["reservations"] as? [[String: Any]])
    let index = try XCTUnwrap(
      reservations.firstIndex { $0["reservationId"] as? String == reservationID })
    // Explicit null, never a removed key: the ledger's closed-shape validator
    // requires the exact reservation key set, and an open reservation is
    // `"terminal": null` on disk.
    reservations[index]["terminal"] = terminal ?? NSNull()
    document["reservations"] = reservations
    try JSONSerialization.data(withJSONObject: document).write(to: url)
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

private struct RepeatingEvolutionRepairer: RockchipEvolutionStrategyRepairing {
  let strategy: RockchipEvolutionTypedStrategy
  let repairerID = "repeating-evolution-repairer"

  func propose(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    observation _: RockchipEvolutionFailureObservation?,
    priorCandidates _: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    strategy
  }
}

private actor CapturingEvolutionRepairer: RockchipEvolutionStrategyRepairing {
  let baseline: RockchipEvolutionTypedStrategy
  let repaired: RockchipEvolutionTypedStrategy
  let repairerID = "capturing-evolution-repairer"
  private var observations: [RockchipEvolutionFailureObservation] = []

  init(baseline: RockchipEvolutionTypedStrategy, repaired: RockchipEvolutionTypedStrategy) {
    self.baseline = baseline
    self.repaired = repaired
  }

  func propose(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    observation: RockchipEvolutionFailureObservation?,
    priorCandidates _: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    if let observation { observations.append(observation) }
    return observation == nil ? baseline : repaired
  }

  func observedFailureCodes() -> [String] {
    observations.map(\.failureCode)
  }
}

private struct ThreeStageEvolutionRepairer: RockchipEvolutionStrategyRepairing {
  let strategies: [RockchipEvolutionTypedStrategy]
  let repairerID = "three-stage-evolution-repairer"

  func propose(
    assertion _: RockchipEvolutionCampaignConfirmationAssertion,
    observation _: RockchipEvolutionFailureObservation?,
    priorCandidates: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    guard priorCandidates.count < strategies.count else {
      throw RockchipEvolutionCampaignError.candidateRejected("repairScript")
    }
    return strategies[priorCandidates.count]
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
    return RockchipEvolutionCandidateBuild(pin: candidate)
  }
}

private actor SafeFailureThenSuccessEvolutionFlash: RockchipEvolutionFlashDispatching {
  let ledger: RockchipEvolutionCampaignLedger
  let now: String
  let safeFailureCount: Int
  let failureStepID: String
  private var count = 0

  init(
    ledger: RockchipEvolutionCampaignLedger,
    now: String,
    safeFailureCount: Int = 1,
    failureStepID: String = "flash.dayu200"
  ) {
    self.ledger = ledger
    self.now = now
    self.safeFailureCount = safeFailureCount
    self.failureStepID = failureStepID
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
      ordinal: ordinal,
      reservationID: "reservation-auto-\(ordinal)", jobID: "job-auto-\(ordinal)",
      sessionID: "session-auto-\(ordinal)", at: now)
    if ordinal <= safeFailureCount {
      _ = try ledger.closeAttempt(
        campaignID: permit.assertion.campaignID, ordinal: ordinal,
        jobID: "job-auto-\(ordinal)", sessionID: "session-auto-\(ordinal)",
        disposition: .safeToReflash, destructiveIntentEventIDs: [], at: now)
      // The production engine reports its versioned operation reference as
      // the failed semantic step. Its `@` is intentionally not valid in a
      // normalized evolution failure code, so the host must retain a stable
      // code and continue the confirmed-safe campaign.
      throw RockchipFlashExecutionError.semanticFailure(
        stepID: failureStepID, detail: "contract safe failure")
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
  let rejectedStartingMode: String
  private var count = 0

  init(
    ledger: RockchipEvolutionCampaignLedger,
    now: String,
    rejectedStartingMode: String = "loader"
  ) {
    self.ledger = ledger
    self.now = now
    self.rejectedStartingMode = rejectedStartingMode
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
      throw RockchipFlashExecutionError.admissionRejected(
        "startingModeNotAllowed:\(rejectedStartingMode)")
    }
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      ordinal: 1,
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

private struct FixedEvolutionCLITransport: HarnessLocalAgentCLITransport {
  let response: Data
  func send(_: HarnessLocalAgentCLIRequest) async throws -> Data { response }
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
    let profile = RockchipFlashProfile.dayu200
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      ordinal: 1,
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

private actor SuccessAfterReconciledEvolutionFlash: RockchipEvolutionFlashDispatching {
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
    let ordinal = 2
    _ = try ledger.reserveAttempt(
      campaignID: permit.assertion.campaignID, candidateID: permit.candidate.candidateID,
      ordinal: ordinal,
      reservationID: "reservation-after-no-effect", jobID: "job-after-no-effect",
      sessionID: "session-after-no-effect", at: now)
    _ = try ledger.closeAttempt(
      campaignID: permit.assertion.campaignID, ordinal: ordinal,
      jobID: "job-after-no-effect", sessionID: "session-after-no-effect",
      disposition: .succeeded,
      destructiveIntentEventIDs: ["intent-flash-partitions"], at: now)
    return RockchipFlashExecutionResult(
      sessionID: "session-after-no-effect", jobID: "job-after-no-effect",
      status: .succeeded, evidenceClass: .contractFake, manifestURL: nil)
  }

  func dispatchCount() -> Int { count }
}

/// Reserves the attempt exactly the way the production admitter would, then
/// answers the way a daemon whose submission layer said no does: a typed
/// refusal, no job, no terminal.
private struct RefusalAfterReserveEvolutionFlash: RockchipEvolutionFlashDispatching {
  let reserve: @Sendable () throws -> Void

  init(reserve: @escaping @Sendable () throws -> Void) {
    self.reserve = reserve
  }

  func execute(
    _ request: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult {
    try reserve()
    throw RockchipFlashExecutionError.submissionRefused(
      detail: "the runtime rejected the submission: flash.dayu200 is runtime unavailable")
  }
}

private struct FixedEvolutionTargetReadback: RockchipEvolutionTargetReadbackReading {
  let readback: RockchipEvolutionTargetReadback

  func readDurableTarget() throws -> RockchipEvolutionTargetReadback { readback }
}

private struct FixedEvolutionAttemptIntents: RockchipEvolutionAttemptIntentReading {
  let kinds: [String]

  func journaledStepKinds(jobID _: String) throws -> [String] { kinds }
}

/// Counts reads, so a test can assert the device was *not* consulted. A
/// readback that would have settled but was never called is the only way to
/// tell "the path refused" apart from "the path never ran" (TASK-AIN-020).
private final class CountingEvolutionTargetReadback: RockchipEvolutionTargetReadbackReading,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var reads = 0
  private let value: RockchipEvolutionTargetReadback

  init(readback: RockchipEvolutionTargetReadback) { value = readback }

  func readDurableTarget() throws -> RockchipEvolutionTargetReadback {
    lock.withLock { reads += 1 }
    return value
  }

  var readCount: Int { lock.withLock { reads } }
}

/// Facts for the engine-lane fixture: the identity the campaign reservation
/// pins, re-proved at consume time.
private struct UnknownOutcomeFlashFactsPort: RockchipRuntimeFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "rockchip",
      toolVersion: BundledRockchipComponent.reportedVersion,
      toolSHA256: String(repeating: "c", count: 64),
      serverFacts: [
        TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey:
          TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied,
        TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey:
          "b02f833b2ad58b84c66c9fe4d4970e39c70c8434c90b393b44325d124a1ed2e0",
        TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey: "42",
      ], targetID: targetID, bindingRevision: 7,
      deviceIdentitySHA256:
        "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
      executionConnectKey: "sealed-campaign-unknown-connect-key",
      deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-facts",
      buildFingerprint: "preflight-only", transport: "sealed-fixture",
      profileID: "dayu200", collectedAtUTC: "2026-08-02T08:00:00Z")
  }
}

/// Loses the child process on the first device mutation — the production shape
/// of an unobservable dispatch (`DescriptorBoundProcessDispatcher` raises the
/// same failure when the executor throws anything but an identity refusal).
/// It is what makes a job's own outcome unknown while the engine survives to
/// record it, which is the terminal the readback consumes.
private struct LosesTheChildOnFirstMutationDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID _: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard plan.action.effect < .deviceMutation else {
      throw RuntimeDispatchFailure.outcomeUnknown("dispatcher lost the child process")
    }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.01)
  }
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
