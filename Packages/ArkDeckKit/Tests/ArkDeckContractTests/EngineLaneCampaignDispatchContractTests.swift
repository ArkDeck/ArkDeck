import ArkDeckAgentClient
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

/// The campaign lane's dispatch swap (CHG-2026-025 r16, TASK-AIN-019).
///
/// These are pure mapping tests: no daemon, no device, no process. What they
/// pin is the part that has no second chance to be right — the request bytes
/// the engine admits, and the terminal translation that decides whether a
/// campaign retries, stops, or is told it succeeded.
final class EngineLaneCampaignDispatchContractTests: XCTestCase {
  private static let profile = RockchipFlashProfile.dayu200OpenHarmony70035
  private static let archiveURL = URL(fileURLWithPath: "/tmp/images.tar.gz")

  private static func admitted(
    ordinal: Int = 1,
    reservationID: String = "ain019-reservation-1"
  ) -> RockchipEvolutionCampaignAdmittedAttempt {
    RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: "ECAMP-\(String(repeating: "A", count: 24))",
      ordinal: ordinal,
      reservationID: reservationID,
      jobID: "rockchip-job-1",
      sessionID: "rockchip-session-1",
      targetStableIdentitySHA256: String(repeating: "a", count: 64),
      bindingRevision: 7,
      deviceProfileReference: profile.catalogReference,
      partitionPlan: profile.mappedPartitions.map(\.partitionName),
      archiveSHA256: profile.archiveSHA256,
      postFlashVerification: "full")
  }

  // MARK: - The bytes the engine admits

  func testSubmittedRequestCarriesTheReservationAndTheAdmittedPlansOwnPins()
    throws
  {
    let attempt = Self.admitted()
    let json = try EngineLaneEvolutionFlashDispatcher.encodedRequest(
      admitted: attempt, lease: "lease-v1:input-flash:ART-000",
      profile: Self.profile, runtimeTargetID: "TGT-DAYU200-70035",
      bindingRevision: 7)
    let request = try RuntimeOperationCodec.decodeRequest(Data(json.utf8))

    // The campaign reservation is the authority; a capability must not also
    // be present (the engine refuses both at once).
    XCTAssertEqual(request.campaignReservation?.reservationID, attempt.reservationID)
    XCTAssertNil(request.authorization)
    XCTAssertEqual(request.operation.id, "flash.dayu200")
    XCTAssertEqual(request.operation.version, 1)
    XCTAssertEqual(request.target.targetID, "TGT-DAYU200-70035")
    XCTAssertEqual(request.target.expectedBindingRevision, 7)
    XCTAssertEqual(
      request.inputs["imageBundleLease"], .string("lease-v1:input-flash:ART-000"))
    // Profile and partition set come from the admitted attempt's materialized
    // plan, so the submitted bytes cannot name a different archive or a wider
    // partition set than the campaign was confirmed against.
    XCTAssertEqual(request.inputs["deviceProfile"], .string("dayu200@2"))
    XCTAssertEqual(
      request.inputs["partitionPlan"],
      .array(Self.profile.mappedPartitions.map { .string($0.partitionName) }))
    XCTAssertEqual(request.inputs["postFlashVerification"], .string("full"))
    // One attempt, one idempotency key: a resubmitted attempt is the same
    // job, not a second consumption of the same reservation.
    XCTAssertEqual(request.idempotencyKey, "campaign-\(attempt.reservationID)")
  }

  // MARK: - Terminal mapping

  func testUnknownOutcomeIsNeverDowngradedToFailureOrUpgradedToSuccess() throws {
    // The load-bearing case. `outcomeUnknown` must not become a failure the
    // campaign may safely reflash against, and must not become a success.
    for state in ["succeeded", "failed", "cancelled", "running"] {
      assertRecoveryRequired(
        EngineLaneJobTerminal(
          jobID: "job-1", state: state, outcomeUnknown: true, timeline: []))
    }
    // An unrecognized terminal is unresolved by definition, not a failure.
    assertRecoveryRequired(
      EngineLaneJobTerminal(
        jobID: "job-1", state: "waitingForHuman", outcomeUnknown: false,
        timeline: []))
  }

  func testDecidedTerminalsMapToTheirExactExecutionOutcome() throws {
    let attempt = Self.admitted()
    let succeeded = try EngineLaneEvolutionFlashDispatcher.result(
      EngineLaneJobTerminal(
        jobID: "job-ok", state: "succeeded", outcomeUnknown: false,
        timeline: ["flash intent confirmed by campaign reservation"]),
      admitted: attempt)
    XCTAssertEqual(succeeded.status, .succeeded)
    XCTAssertEqual(succeeded.jobID, "job-ok")
    // The engine lane keeps one durable record per attempt and names it by
    // job identifier; it publishes no stack-B session manifest.
    XCTAssertEqual(succeeded.sessionID, "job-ok")
    XCTAssertEqual(succeeded.evidenceClass, .production)
    XCTAssertNil(succeeded.manifestURL)

    XCTAssertThrowsError(
      try EngineLaneEvolutionFlashDispatcher.result(
        EngineLaneJobTerminal(
          jobID: "job-failed", state: "failed", outcomeUnknown: false,
          timeline: ["dispatch refused"]),
        admitted: attempt)
    ) { error in
      guard case .semanticFailure = error as? RockchipFlashExecutionError else {
        return XCTFail("a confirmed failure must map to a semantic failure: \(error)")
      }
    }

    XCTAssertThrowsError(
      try EngineLaneEvolutionFlashDispatcher.result(
        EngineLaneJobTerminal(
          jobID: "job-loader-no-clean", state: "failed", outcomeUnknown: false,
          timeline: [
            "confirmed not executed enter-loader-mode "
              + "[diagnostic=enterLoaderHDCNoCleanReceipt]"
          ]),
        admitted: attempt)
    ) { error in
      XCTAssertEqual(
        error as? RockchipFlashExecutionError,
        .semanticFailure(
          stepID: RockchipFlashRuntimeDiagnostic.enterLoaderHDCNoCleanReceipt
            .evolutionFailureCode,
          detail: "runtime job job-loader-no-clean failed: "
            + "confirmed not executed enter-loader-mode "
            + "[diagnostic=enterLoaderHDCNoCleanReceipt]"))
    }

    XCTAssertThrowsError(
      try EngineLaneEvolutionFlashDispatcher.result(
        EngineLaneJobTerminal(
          jobID: "job-cancelled", state: "cancelled", outcomeUnknown: false,
          timeline: []),
        admitted: attempt)
    ) { error in
      XCTAssertEqual(
        error as? RockchipFlashExecutionError, .cancelledAtSafeBoundary)
    }
  }

  // MARK: - Dispatch preconditions

  func testDispatchWithoutAPreAdmittedAttemptRefusesBeforeTouchingTheDaemon()
    async throws
  {
    let gateway = RecordingGateway()
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: "TGT-DAYU200-70035", admitter: nil,
      gateway: gateway.value())
    let request = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-CONTRACT-0001", archiveURL: Self.archiveURL,
      targetLocationSelector: "42")

    do {
      _ = try await dispatcher.execute(request, admitted: nil)
      XCTFail("the engine lane never reserves; a missing reservation is no authority")
    } catch let error as RockchipFlashExecutionError {
      guard case .admissionRejected = error else {
        return XCTFail("expected an admission refusal, got \(error)")
      }
    }
    let calls = gateway.calls()
    XCTAssertTrue(calls.isEmpty, "an unauthorized attempt must not reach the daemon: \(calls)")
  }

  func testAdmittedDispatchImportsTheArchiveThenSubmitsAndRuns() async throws {
    let attempt = Self.admitted()
    let gateway = RecordingGateway(
      terminal: EngineLaneJobTerminal(
        jobID: "job-run", state: "succeeded", outcomeUnknown: false, timeline: []))
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: "TGT-DAYU200-70035", admitter: nil,
      gateway: gateway.value())
    let request = try RockchipFlashExecutionRequest(
      evolutionCampaignAttempt: try Self.permit(), archiveURL: Self.archiveURL,
      targetLocationSelector: "42")

    let result = try await dispatcher.execute(request, admitted: attempt)
    XCTAssertEqual(result.jobID, "job-run")
    let calls = gateway.calls()
    XCTAssertEqual(
      calls, ["bindingRevision:TGT-DAYU200-70035", "import:/tmp/images.tar.gz", "submitAndRun"],
      "the archive must be leased into the daemon store before the job is submitted")
    let submitted = try XCTUnwrap(gateway.submittedRequestJSON())
    XCTAssertEqual(
      try RuntimeOperationCodec.decodeRequest(Data(submitted.utf8))
        .campaignReservation?.reservationID,
      attempt.reservationID)
  }

  func testATerminalThatWasNeverObservedIsUnresolvedRatherThanFailed()
    async throws
  {
    // The daemon died mid-run, or the socket dropped. The reservation may or
    // may not have been consumed on the other side, so the campaign must stop
    // rather than treat this as a safe failure it can reflash against.
    let gateway = RecordingGateway(submitFailure: true)
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: "TGT-DAYU200-70035", admitter: nil,
      gateway: gateway.value())
    let request = try RockchipFlashExecutionRequest(
      evolutionCampaignAttempt: try Self.permit(), archiveURL: Self.archiveURL,
      targetLocationSelector: "42")

    do {
      _ = try await dispatcher.execute(request, admitted: Self.admitted())
      XCTFail("an unobserved terminal must not read as success")
    } catch let error as RockchipFlashExecutionError {
      guard case .recoveryRequired = error else {
        return XCTFail("expected an unresolved outcome, got \(error)")
      }
    }
  }

  func testADaemonAuthoredRejectionAtSubmitIsTypedAsSubmissionRefused() async throws {
    // Distinct from a dropped socket: the daemon itself answered "rejected",
    // so no job exists and nothing was dispatched. The campaign layer settles
    // this retry-safe instead of sealing the campaign as unknown (the
    // 2026-08-04 ECAMP-CF1406F8 shape).
    let gateway = EngineLaneRuntimeGateway(
      importFlashBundle: { _, _, _ in "lease-contract" },
      bindingRevision: { _ in 7 },
      submitAndRun: { _ in
        throw EngineLaneSubmissionRefusal(
          detail:
            "the runtime rejected the submission: flash.dayu200@1 is runtime unavailable")
      })
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: "TGT-DAYU200-70035", admitter: nil, gateway: gateway)
    let request = try RockchipFlashExecutionRequest(
      evolutionCampaignAttempt: try Self.permit(), archiveURL: Self.archiveURL,
      targetLocationSelector: "42")

    do {
      _ = try await dispatcher.execute(request, admitted: Self.admitted())
      XCTFail("an authored daemon rejection must surface as submissionRefused")
    } catch let error as RockchipFlashExecutionError {
      guard case .submissionRefused(let detail) = error else {
        return XCTFail("expected submissionRefused, got \(error)")
      }
      XCTAssertTrue(detail.contains("runtime unavailable"), detail)
    }
  }

  func testAnAdmittedAttemptThatNamesNoPublishedProfileNeverDispatches()
    async throws
  {
    let gateway = RecordingGateway()
    let dispatcher = EngineLaneEvolutionFlashDispatcher(
      runtimeTargetID: "TGT-DAYU200-70035", admitter: nil,
      gateway: gateway.value())
    let request = try RockchipFlashExecutionRequest(
      evolutionCampaignAttempt: try Self.permit(), archiveURL: Self.archiveURL,
      targetLocationSelector: "42")
    let drifted = RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: "ECAMP-\(String(repeating: "A", count: 24))", ordinal: 1,
      reservationID: "ain019-reservation-1", jobID: "j", sessionID: "s",
      targetStableIdentitySHA256: String(repeating: "a", count: 64),
      bindingRevision: 7, deviceProfileReference: "dayu200@2",
      // A partition set the published profile does not have.
      partitionPlan: ["userdata"], archiveSHA256: Self.profile.archiveSHA256,
      postFlashVerification: "full")

    do {
      _ = try await dispatcher.execute(request, admitted: drifted)
      XCTFail("a drifted partition plan must not reach the daemon")
    } catch let error as RockchipFlashExecutionError {
      guard case .admissionRejected = error else {
        return XCTFail("expected an admission refusal, got \(error)")
      }
    }
    let calls = gateway.calls()
    XCTAssertTrue(calls.isEmpty, "\(calls)")
  }

  // MARK: - Fixtures

  private func assertRecoveryRequired(
    _ terminal: EngineLaneJobTerminal,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try EngineLaneEvolutionFlashDispatcher.result(
        terminal, admitted: Self.admitted()),
      file: file, line: line
    ) { error in
      guard case .recoveryRequired = error as? RockchipFlashExecutionError else {
        return XCTFail(
          "state \(terminal.state)/unknown=\(terminal.outcomeUnknown) must stay unresolved, "
            + "got \(error)", file: file, line: line)
      }
    }
  }

  private static func digest(_ seed: String) -> String {
    String(repeating: seed, count: 64)
  }

  private static func permit() throws -> RockchipEvolutionCampaignAttemptPermit {
    let assertion = try RockchipEvolutionCampaignConfirmationAssertion.draft(
      baseCommitOID: String(repeating: "a", count: 40),
      candidateToolchainDigestSHA256: digest("1"),
      brokerExecutableDigestSHA256: digest("2"), maxChangedFiles: 8,
      maxDiffLines: 2_000, planDigestSHA256: digest("3"),
      archiveDigestSHA256: digest("4"), stepSetDigestSHA256: digest("5"),
      targetStableIdentitySHA256: digest("a"), bindingLineageRootRevision: 1,
      maxAttempts: 4, confirmedAt: "2026-08-03T00:00:00Z",
      validUntil: "2026-08-03T03:00:00Z")
    let strategy = try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2",
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: [.hdcNormal, .loader], userdataImpact: "ERASE-USERDATA")
    let candidate = try RockchipEvolutionCandidatePin(
      candidateID: "ECAND-0000000000000001", producerID: "engine-lane-builder",
      baseCommitOID: assertion.baseCommitOID,
      sourceTreeDigestSHA256: digest("6"), diffDigestSHA256: digest("7"),
      allowedPathSetDigestSHA256: digest("8"), executableDigestSHA256: digest("9"),
      toolchainDigestSHA256: assertion.candidateToolchainDigestSHA256,
      changedFiles: ["Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/main.swift"],
      changedLines: 1, diffArtifactID: "diff-1",
      buildEvidenceArtifactID: "build-1",
      testEvidenceArtifactID: "test-1", strategy: strategy)
    return try RockchipEvolutionCampaignAttemptPermit(
      assertion: assertion, candidate: candidate)
  }

  private final class RecordingGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var submitted: String?
    private let terminal: EngineLaneJobTerminal
    private let submitFailure: Bool

    init(
      terminal: EngineLaneJobTerminal = EngineLaneJobTerminal(
        jobID: "job-default", state: "succeeded", outcomeUnknown: false,
        timeline: []),
      submitFailure: Bool = false
    ) {
      self.terminal = terminal
      self.submitFailure = submitFailure
    }

    func calls() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return recorded
    }

    func submittedRequestJSON() -> String? {
      lock.lock()
      defer { lock.unlock() }
      return submitted
    }

    private func record(_ entry: String, submission: String? = nil) {
      lock.lock()
      defer { lock.unlock() }
      recorded.append(entry)
      if let submission { submitted = submission }
    }

    func value() -> EngineLaneRuntimeGateway {
      EngineLaneRuntimeGateway(
        importFlashBundle: { [self] _, archiveURL, _ in
          record("import:\(archiveURL.path)")
          return "lease-v1:input-flash:ART-recorded"
        },
        bindingRevision: { [self] targetID in
          record("bindingRevision:\(targetID)")
          return 7
        },
        submitAndRun: { [self] json in
          record("submitAndRun", submission: json)
          if submitFailure {
            throw AgentClientError.transport("connection closed before response")
          }
          return terminal
        })
    }
  }
}
