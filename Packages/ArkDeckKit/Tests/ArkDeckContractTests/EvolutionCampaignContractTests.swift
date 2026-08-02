import Foundation
import XCTest

@testable import ArkDeckStorage
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

  func testConfirmationIsClosedExactAndHardBoundedToEightAttemptsFourHoursOneConcurrency()
    throws
  {
    let assertion = try makeAssertion()
    XCTAssertEqual(assertion.maxAttempts, 8)
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

    XCTAssertThrowsError(try makeAssertion(maxAttempts: 9))
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

  func testCampaignLedgerAllowsExactlyEightSerialSafeAttemptsAndRejectsNinthOrConcurrent()
    throws
  {
    let root = temporaryDirectory("campaign-eight")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try RockchipEvolutionCampaignLedger(root: root)
    let assertion = try makeAssertion()
    _ = try ledger.create(assertion)

    for ordinal in 1...8 {
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

    let ninth = try makePins(assertion: assertion, ordinal: 9)
    _ = try ledger.appendCandidate(
      campaignID: assertion.campaignID, candidate: ninth.candidate,
      review: ninth.review, at: Self.confirmedAt)
    XCTAssertThrowsError(
      try ledger.reserveAttempt(
        campaignID: assertion.campaignID, candidateID: ninth.candidate.candidateID,
        reviewID: ninth.review.reviewID, ordinal: 9, reservationID: "reservation-9",
        jobID: "job-9", sessionID: "session-9", at: Self.confirmedAt))
    let document = try ledger.load(assertion.campaignID)
    XCTAssertEqual(document.reservedAttemptCount, 8)
    XCTAssertNil(document.activeReservation)
    XCTAssertEqual(document.events.filter { $0.kind == .attemptReserved }.count, 8)
    XCTAssertEqual(Set(document.events.compactMap(\.jobID)).count, 8)
    XCTAssertEqual(Set(document.events.compactMap(\.sessionID)).count, 8)
  }

  func testGlobalUsageLedgerMetersEightAndSerializesOneTarget() throws {
    let root = temporaryDirectory("campaign-usage")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try AgentAuthorityUsageLedger(root: root)
    let reference = try makeAssertion().authorityReference()

    for ordinal in 1...8 {
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
        usageReservation(reference: reference, ordinal: 9, jobID: "job-usage-9")))
    XCTAssertEqual(try ledger.load().reservations.count, 8)
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
    strategy["executable"] = "/usr/local/bin/rkdeveloptool"
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self,
        from: JSONSerialization.data(withJSONObject: strategy)))
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
    XCTAssertFalse(profile.contains("network"))
    XCTAssertFalse(profile.contains("process-exec"))
    XCTAssertFalse(profile.lowercased().contains("usb"))
    XCTAssertFalse(profile.lowercased().contains("hdc"))
    XCTAssertFalse(profile.lowercased().contains("rockusb"))
  }

  private func makeAssertion(
    seed: Character = "0", maxAttempts: Int = 8,
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
      ordinal: ordinal, maximumUses: 8, maximumConcurrentJobs: 1,
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

  func build(assertion _: RockchipEvolutionCampaignConfirmationAssertion) async throws
    -> RockchipEvolutionCandidateBuild
  {
    build
  }
}

private struct RejectingEvolutionReviewer: RockchipEvolutionAdversarialReviewing {
  let reviewerID = "independent-adversarial-reviewer"

  func review(_: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
  {
    throw RockchipEvolutionCampaignError.reviewRejected("contractRejection")
  }
}

private actor CountingEvolutionFlash: RockchipEvolutionFlashDispatching {
  private var count = 0

  func execute(_: RockchipFlashExecutionRequest) async throws -> RockchipFlashExecutionResult {
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
    grant _: VerifiedAuthorizationGrant
  ) async throws -> RockchipTrustedAuthorizationFacts {
    throw RockchipAuthorizationFactError.factPortFailed(name: "must-not-run")
  }

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
