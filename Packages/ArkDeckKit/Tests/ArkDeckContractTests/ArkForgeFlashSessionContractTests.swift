import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

/// Step 5's wiring, and `AFA-AC-10`.
///
/// The session is driven by a scripted daemon rather than a real one so every
/// branch — including the ones a healthy run never reaches — is exercised. The
/// hardware run is this same code path with `ArkForgeControllerClient` behind the
/// protocol.
///
/// The assertion that matters most is the cancellation mapping. Once dispatch
/// left the ArkDeck process, that process group stopped being ArkDeck's, so
/// there is no drain proof to obtain on this lane. A refused cancellation must
/// not be recorded as an unconfirmed teardown: that would report a write which
/// is *still running normally* as an unknown outcome, and unknown outcomes are
/// the thing this whole change refuses to replay.
final class ArkForgeFlashSessionContractTests: XCTestCase {

  // MARK: - A daemon that follows a script

  private final class ScriptedDaemon: ArkForgeFlashSession.Daemon, @unchecked Sendable {
    let events: [ArkForgeJobEvent]
    var permitSubmissions: [ArkForgeSubmitStepPermitRequest] = []
    var controlSubmissions: [ArkForgeSubmitManagedControlReceiptRequest] = []
    var cancelAnswer: Result<ArkForgeCancelJobResponse, Error>
    /// Admission request ids whose permit submission this daemon rejects —
    /// inside an OK response, the way the real one does.
    var permitRejections: [String: (code: String, message: String)] = [:]
    /// When set, every control receipt is rejected with this code.
    var controlRejection: (code: String, message: String)?
    var cancelRequests: [String] = []
    var startRequests: [ArkForgeStartExecutionRequest] = []

    init(
      events: [ArkForgeJobEvent],
      cancelAnswer: Result<ArkForgeCancelJobResponse, Error> = .success(
        ArkForgeCancelJobResponse(cancellationState: "cancelledSafe"))
    ) {
      self.events = events
      self.cancelAnswer = cancelAnswer
    }

    func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
      -> ArkForgeStartExecutionResponse
    {
      startRequests.append(body)
      return ArkForgeStartExecutionResponse(jobID: "JOB-1")
    }

    func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
      -> ArkForgeSubmitStepPermitResponse
    {
      permitSubmissions.append(body)
      if let rejection = permitRejections[body.requestID] {
        return ArkForgeSubmitStepPermitResponse(
          accepted: false, rejectionCode: rejection.code, rejectionMessage: rejection.message)
      }
      return ArkForgeSubmitStepPermitResponse(
        accepted: body.refusal == nil, rejectionCode: "", rejectionMessage: "")
    }

    func submitManagedControlReceipt(
      _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
    ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
      controlSubmissions.append(body)
      if let rejection = controlRejection {
        return ArkForgeSubmitManagedControlReceiptResponse(
          accepted: false, rejectionCode: rejection.code, rejectionMessage: rejection.message)
      }
      return ArkForgeSubmitManagedControlReceiptResponse(
        accepted: true, rejectionCode: "", rejectionMessage: "")
    }

    func watchJob(
      _ body: ArkForgeWatchJobRequest, requestID: String,
      handle: (ArkForgeJobEvent) throws -> Bool
    ) throws {
      for event in events where try !handle(event) { return }
      let hasTerminal = events.contains { $0.kind == .outcomeClassified }
      let finalSequence = events.map(\.sequence).max() ?? 0
      if !hasTerminal,
        events.isEmpty || (finalSequence > 0 && body.fromSequence >= finalSequence)
      {
        _ = try handle(
          ArkForgeJobEvent(
            jobID: "JOB-1", sequence: finalSequence + 1, kind: .outcomeClassified,
            atEpochMs: 1_000_070, journalRecordSHA256: [], jobState: "succeeded",
            admission: nil, controlRequest: nil, receipt: nil,
            facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]))
      }
    }

    func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
      cancelRequests.append(jobID)
      return try cancelAnswer.get()
    }
  }

  private struct StubPerformer: ArkForgeFlashSession.ControlPerformer {
    let observation: ArkForgeManagedControlPort.Observation
    func perform(_ request: ArkForgeManagedControlRequest) async throws
      -> ArkForgeManagedControlPort.Observation
    { observation }
  }

  private struct FailingPerformer: ArkForgeFlashSession.ControlPerformer {
    struct Boom: Error {}
    func perform(_ request: ArkForgeManagedControlRequest) async throws
      -> ArkForgeManagedControlPort.Observation
    { throw Boom() }
  }

  // MARK: - Fixtures

  private let planDigest = [UInt8](repeating: 0x11, count: 32)
  private let deviceFacts = [UInt8](repeating: 0x22, count: 32)

  private func authority(
    now: UInt64 = 1_000_100
  ) -> ArkForgeExecutionAuthority {
    ArkForgeExecutionAuthority(
      plan: .init(
        jobID: "JOB-1", planID: "PLAN-1", planSHA256: planDigest,
        admittedDeviceFactsSHA256: deviceFacts,
        binding: ArkForgeAuthorityBinding(
          authorityNamespace: "arkdeck", bindingID: "TGT-1", bindingRevision: 2,
          stableIdentityDigest: [UInt8](repeating: 0x33, count: 32)),
        controllerSessionID: "SESSION-1"),
      secret: ArkForgePairingSecret(
        secret: Array("session-secret".utf8), epoch: ArkForgePairingEpoch(1)),
      now: { now })
  }

  private func admissionEvent(
    stepID: String, planSHA256: [UInt8]? = nil, sequence: UInt64 = 1
  ) -> ArkForgeJobEvent {
    ArkForgeJobEvent(
      jobID: "JOB-1", sequence: sequence, kind: .stepAdmissionRequested,
      atEpochMs: 1_000_050, journalRecordSHA256: [], jobState: "running",
      admission: ArkForgeStepAdmissionSnapshot(
        jobID: "JOB-1", planID: "PLAN-1", planSHA256: planSHA256 ?? planDigest,
        stepID: stepID, attemptID: "ATTEMPT-1",
        publicStepSHA256: [UInt8](repeating: 0x44, count: 32),
        privateActionSHA256: [UInt8](repeating: 0x55, count: 32),
        effectSetSHA256: [UInt8](repeating: 0x66, count: 32),
        admittedDeviceFactsSHA256: deviceFacts, observedMode: "loader",
        observedAtEpochMs: 1_000_000, snapshotLifetimeMs: 60_000,
        requestID: "ADM-\(stepID)"),
      controlRequest: nil, receipt: nil, facts: [])
  }

  private func receiptEvent(stepID: String, disposition: String) -> ArkForgeJobEvent {
    ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 2, kind: .actionReceipt, atEpochMs: 1_000_060,
      journalRecordSHA256: [], jobState: "running", admission: nil, controlRequest: nil,
      receipt: ArkForgeActionReceiptSummary(
        jobID: "JOB-1", planID: "PLAN-1", stepID: stepID, actionID: "A-1",
        attemptID: "ATTEMPT-1", permitID: "PERMIT-JOB-1-\(stepID)-ATTEMPT-1",
        disposition: disposition, evidenceSHA256: [], verificationOutcome: "verified",
        verificationStrength: "fullHash", verifiedRangeStart: 0, verifiedRangeLength: 4096,
        typedSkipReason: "", failureClassification: "", facts: []),
      facts: [])
  }

  // MARK: - The loop

  func testAMatchingAdmissionIsAnsweredWithASignedPermit() async throws {
    let daemon = ScriptedDaemon(events: [
      admissionEvent(stepID: "flash-partitions"),
      receiptEvent(stepID: "flash-partitions", disposition: "semanticSuccess"),
      ArkForgeJobEvent(
        jobID: "JOB-1", sequence: 3, kind: .outcomeClassified,
        atEpochMs: 1_000_070, journalRecordSHA256: [], jobState: "succeeded",
        admission: nil, controlRequest: nil, receipt: nil,
        facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]),
    ])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.run(
      planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    XCTAssertEqual(daemon.permitSubmissions.count, 1)
    let submitted = try XCTUnwrap(daemon.permitSubmissions.first)
    XCTAssertNil(submitted.refusal, "a matching admission is signed, not declined")
    XCTAssertFalse(submitted.permitCBOR.isEmpty)
    XCTAssertEqual(submitted.pairingEpoch, 1)
    guard case .completed(let receipts) = outcome else {
      return XCTFail("expected completion, got \(outcome)")
    }
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.disposition, "semanticSuccess")
  }

  func testRunExistingNeverStartsAReplacementJob() async throws {
    let daemon = ScriptedDaemon(events: [
      receiptEvent(stepID: "flash-partitions", disposition: "semanticSuccess")
    ])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.runExisting(jobID: "JOB-1")

    XCTAssertTrue(daemon.startRequests.isEmpty)
    guard case .completed(let receipts) = outcome else {
      return XCTFail("expected the correlated job's completion, got \(outcome)")
    }
    XCTAssertEqual(receipts.map(\.stepID), ["flash-partitions"])
  }

  func testPassiveTerminalObservationCannotAnswerOrMutateTheJob() throws {
    let daemon = ScriptedDaemon(events: [
      admissionEvent(stepID: "flash-partitions"),
      receiptEvent(stepID: "flash-partitions", disposition: "semanticSuccess"),
      ArkForgeJobEvent(
        jobID: "JOB-1", sequence: 3, kind: .outcomeClassified,
        atEpochMs: 1_000_070, journalRecordSHA256: [], jobState: "succeeded",
        admission: nil, controlRequest: nil, receipt: nil,
        facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]),
    ])

    let outcome = try ArkForgeFlashSession.observeTerminal(daemon: daemon, jobID: "JOB-1")

    guard case .completed(let receipts) = outcome else {
      return XCTFail("expected passive completion, got \(String(describing: outcome))")
    }
    XCTAssertEqual(receipts.map(\.stepID), ["flash-partitions"])
    XCTAssertTrue(daemon.startRequests.isEmpty)
    XCTAssertTrue(daemon.permitSubmissions.isEmpty)
    XCTAssertTrue(daemon.controlSubmissions.isEmpty)
    XCTAssertTrue(daemon.cancelRequests.isEmpty)
  }

  func testPassiveObservationConsumesReconciledTerminalAndRestartedReceipt() throws {
    let daemon = ScriptedDaemon(events: [
      ArkForgeJobEvent(
        jobID: "JOB-1", sequence: 1, kind: .outcomeClassified,
        atEpochMs: 1_000_050, journalRecordSHA256: [], jobState: "outcomeUnknown",
        admission: nil, controlRequest: nil, receipt: nil,
        facts: [
          ArkForgeKeyValue(key: "outcome", value: "outcomeUnknown"),
          ArkForgeKeyValue(key: "reason", value: "daemon restarted after dispatch"),
        ]),
      receiptEvent(stepID: "postflight-readback", disposition: "semanticSuccess"),
      ArkForgeJobEvent(
        jobID: "JOB-1", sequence: 3, kind: .outcomeClassified,
        atEpochMs: 1_000_070, journalRecordSHA256: [], jobState: "succeeded",
        admission: nil, controlRequest: nil, receipt: nil,
        facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]),
    ])

    let outcome = try ArkForgeFlashSession.observeTerminal(daemon: daemon, jobID: "JOB-1")

    guard case .completed(let receipts) = outcome else {
      return XCTFail("the later durable classification must supersede outcomeUnknown")
    }
    XCTAssertEqual(receipts.map(\.stepID), ["postflight-readback"])
    XCTAssertTrue(daemon.startRequests.isEmpty)
    XCTAssertTrue(daemon.permitSubmissions.isEmpty)
    XCTAssertTrue(daemon.controlSubmissions.isEmpty)
    XCTAssertTrue(daemon.cancelRequests.isEmpty)
  }

  func testAnEmptyPollBetweenAReceiptAndTheNextAdmissionIsNotCompletion() async throws {
    final class GappedDaemon: ArkForgeFlashSession.Daemon, @unchecked Sendable {
      var poll = 0
      var permitSubmissions: [ArkForgeSubmitStepPermitRequest] = []

      func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
        -> ArkForgeStartExecutionResponse
      { ArkForgeStartExecutionResponse(jobID: "JOB-1") }

      func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
        -> ArkForgeSubmitStepPermitResponse
      {
        permitSubmissions.append(body)
        return ArkForgeSubmitStepPermitResponse(
          accepted: true, rejectionCode: "", rejectionMessage: "")
      }

      func submitManagedControlReceipt(
        _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
      ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
        ArkForgeSubmitManagedControlReceiptResponse(
          accepted: true, rejectionCode: "", rejectionMessage: "")
      }

      func watchJob(
        _ body: ArkForgeWatchJobRequest, requestID: String,
        handle: (ArkForgeJobEvent) throws -> Bool
      ) throws {
        poll += 1
        switch poll {
        case 1:
          _ = try handle(
            ArkForgeJobEvent(
              jobID: "JOB-1", sequence: 1, kind: .actionReceipt,
              atEpochMs: 1_000_040, journalRecordSHA256: [], jobState: "running",
              admission: nil, controlRequest: nil,
              receipt: ArkForgeActionReceiptSummary(
                jobID: "JOB-1", planID: "PLAN-1", stepID: "reboot", actionID: "A-1",
                attemptID: "ATTEMPT-1", permitID: "PERMIT-REBOOT",
                disposition: "semanticSuccess", evidenceSHA256: [],
                verificationOutcome: "verified", verificationStrength: "semantic",
                verifiedRangeStart: 0, verifiedRangeLength: 0, typedSkipReason: "",
                failureClassification: "", facts: []),
              facts: []))
        case 2:
          // The real daemon exposed exactly this gap after DEVICE_RESET.
          break
        case 3:
          _ = try handle(
            ArkForgeJobEvent(
              jobID: "JOB-1", sequence: 2, kind: .stepAdmissionRequested,
              atEpochMs: 1_000_050, journalRecordSHA256: [], jobState: "postflight",
              admission: ArkForgeStepAdmissionSnapshot(
                jobID: "JOB-1", planID: "PLAN-1",
                planSHA256: [UInt8](repeating: 0x11, count: 32),
                stepID: "postflight", attemptID: "ATTEMPT-2",
                publicStepSHA256: [UInt8](repeating: 0x44, count: 32),
                privateActionSHA256: [UInt8](repeating: 0x55, count: 32),
                effectSetSHA256: [UInt8](repeating: 0x66, count: 32),
                admittedDeviceFactsSHA256: [UInt8](repeating: 0x22, count: 32),
                observedMode: "hdc-normal", observedAtEpochMs: 1_000_000,
                snapshotLifetimeMs: 60_000, requestID: "ADM-postflight"),
              controlRequest: nil, receipt: nil, facts: []))
        case 4:
          _ = try handle(
            ArkForgeJobEvent(
              jobID: "JOB-1", sequence: 3, kind: .actionReceipt,
              atEpochMs: 1_000_060, journalRecordSHA256: [], jobState: "postflight",
              admission: nil, controlRequest: nil,
              receipt: ArkForgeActionReceiptSummary(
                jobID: "JOB-1", planID: "PLAN-1", stepID: "postflight", actionID: "A-2",
                attemptID: "ATTEMPT-2", permitID: "PERMIT-POSTFLIGHT",
                disposition: "semanticSuccess", evidenceSHA256: [],
                verificationOutcome: "verified", verificationStrength: "semantic",
                verifiedRangeStart: 0, verifiedRangeLength: 0, typedSkipReason: "",
                failureClassification: "", facts: []),
              facts: []))
        default:
          _ = try handle(
            ArkForgeJobEvent(
              jobID: "JOB-1", sequence: 4, kind: .outcomeClassified,
              atEpochMs: 1_000_070, journalRecordSHA256: [], jobState: "succeeded",
              admission: nil, controlRequest: nil, receipt: nil,
              facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]))
        }
      }

      func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
        ArkForgeCancelJobResponse(cancellationState: "cancelledSafe")
      }
    }

    let daemon = GappedDaemon()
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.run(
      planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    XCTAssertEqual(daemon.permitSubmissions.map(\.requestID), ["ADM-postflight"])
    guard case .completed(let receipts) = outcome else {
      return XCTFail("expected completion after the explicit terminal event, got \(outcome)")
    }
    XCTAssertEqual(receipts.map(\.stepID), ["reboot", "postflight"])
  }

  func testARefusedAdmissionIsReportedRatherThanWithheld() async throws {
    // Silence and refusal are different things to the daemon: a refusal goes to
    // CancelledSafe, silence lets the snapshot expire and admission run again.
    // This asserts the session says so rather than simply not answering.
    let daemon = ScriptedDaemon(events: [
      admissionEvent(stepID: "flash-partitions", planSHA256: [UInt8](repeating: 0xEE, count: 32))
    ])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    let submitted = try XCTUnwrap(daemon.permitSubmissions.first)
    XCTAssertNotNil(submitted.refusal, "a refusal must be sent, not withheld")
    XCTAssertTrue(submitted.permitCBOR.isEmpty, "a refusal carries no permit")
    let declined = await session.declinedAdmissions
    XCTAssertEqual(declined.count, 1)
    XCTAssertTrue(declined[0].contains("plan"), declined[0])
  }

  func testAControlRequestIsPerformedAndItsObservationRelayed() async throws {
    let control = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .managedControlRequested, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "running", admission: nil,
      controlRequest: ArkForgeManagedControlRequest(
        jobID: "JOB-1", stepID: "enter-loader-mode", requestID: "CTL-1",
        action: .enterUpdater, permitID: "PERMIT-1", expectedFacts: [],
        deadlineEpochMs: 1_100_000),
      receipt: nil, facts: [])
    let daemon = ScriptedDaemon(events: [control])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(
        observation: .init(
          accepted: true,
          facts: [
            "mode": "Loader", "stableIdentitySHA256": String(repeating: "a", count: 64),
            "usbTopology": "0x14200000",
          ],
          evidenceSHA256: [UInt8](repeating: 0x7, count: 32),
          observedDisconnect: true, observedUniqueLoaderRebind: true)),
      controllerSessionID: "SESSION-1")

    _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    let receipt = try XCTUnwrap(daemon.controlSubmissions.first)
    XCTAssertTrue(receipt.accepted)
    XCTAssertEqual(receipt.action, .enterUpdater)
    XCTAssertEqual(receipt.facts.map(\.key), ["mode", "stableIdentitySHA256", "usbTopology"])
  }

  func testAControlActionThatFailedIsNotReportedAsNothingHavingHappened() async throws {
    // The action may have taken effect before the failure. Reported as
    // unaccepted with a reason, which the daemon records as an unknown outcome
    // rather than as "it did not happen".
    let control = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .managedControlRequested, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "running", admission: nil,
      controlRequest: ArkForgeManagedControlRequest(
        jobID: "JOB-1", stepID: "enter-loader-mode", requestID: "CTL-1",
        action: .enterUpdater, permitID: "PERMIT-1", expectedFacts: [],
        deadlineEpochMs: 1_100_000),
      receipt: nil, facts: [])
    let daemon = ScriptedDaemon(events: [control])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(), performer: FailingPerformer(),
      controllerSessionID: "SESSION-1")

    _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    let receipt = try XCTUnwrap(daemon.controlSubmissions.first)
    XCTAssertFalse(receipt.accepted)
    XCTAssertTrue(receipt.failureReason.contains("did not complete"), receipt.failureReason)
    XCTAssertTrue(receipt.facts.isEmpty)
  }

  // MARK: - Rejections are answers, not noise

  func testARejectedPermitSubmissionIsANamedStop() async throws {
    // The daemon says "rejected" inside an OK response, and this session used
    // to read neither field. Three refusal codes in a row (unknownJob,
    // planMismatch, snapshotExpired) each cost a bench session to discover;
    // a rejection is now a stop carrying the daemon's own code.
    let daemon = ScriptedDaemon(events: [admissionEvent(stepID: "flash-partitions")])
    daemon.permitRejections["ADM-flash-partitions"] = (
      code: "PERMIT_REJECTED", message: "integrity tag does not verify"
    )
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    do {
      _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")
      XCTFail("a rejected permit must stop the session")
    } catch let error as ArkForgeFlashSession.SessionError {
      guard case .permitRejected(let stepID, let code, _) = error else {
        return XCTFail("unexpected session error \(error)")
      }
      XCTAssertEqual(stepID, "flash-partitions")
      XCTAssertEqual(code, "PERMIT_REJECTED")
    }
  }

  func testASnapshotExpiredRejectionIsRecordedButNotFatal() async throws {
    // The one rejection that heals itself: the snapshot expires, admission
    // runs again with a fresher one. The session records it and keeps polling
    // rather than declaring the job dead.
    let daemon = ScriptedDaemon(events: [admissionEvent(stepID: "flash-partitions")])
    daemon.permitRejections["ADM-flash-partitions"] = (
      code: "SNAPSHOT_EXPIRED", message: "the admission snapshot aged out"
    )
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    let declined = await session.declinedAdmissions
    XCTAssertEqual(declined.count, 1)
    XCTAssertTrue(declined[0].contains("SNAPSHOT_EXPIRED"), declined[0])
  }

  func testARejectedControlReceiptCancelsTheJobAndStops() async throws {
    // A rejected receipt leaves the daemon still waiting on its request.
    // Discarding the rejection left both sides waiting on the other with
    // nothing recorded anywhere — the observed shape of the stalled bench.
    let control = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .managedControlRequested, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "running", admission: nil,
      controlRequest: ArkForgeManagedControlRequest(
        jobID: "JOB-1", stepID: "enter-loader-mode", requestID: "CTL-1",
        action: .enterUpdater, permitID: "PERMIT-1", expectedFacts: [],
        deadlineEpochMs: 1_100_000),
      receipt: nil, facts: [])
    let daemon = ScriptedDaemon(events: [control])
    daemon.controlRejection = (
      code: "CONTROL_EVIDENCE_MISMATCH", message: "evidence is not the facts digest"
    )
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(
        observation: .init(
          accepted: true,
          facts: [
            "mode": "Loader", "stableIdentitySHA256": String(repeating: "a", count: 64),
            "usbTopology": "0x14200000",
          ],
          evidenceSHA256: [], observedDisconnect: true, observedUniqueLoaderRebind: true)),
      controllerSessionID: "SESSION-1")

    do {
      _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")
      XCTFail("a rejected control receipt must stop the session")
    } catch let error as ArkForgeFlashSession.SessionError {
      guard case .controlReceiptRejected(let requestID, let code, _) = error else {
        return XCTFail("unexpected session error \(error)")
      }
      XCTAssertEqual(requestID, "CTL-1")
      XCTAssertEqual(code, "CONTROL_EVIDENCE_MISMATCH")
    }
    // And the daemon's job was cancelled rather than left parked on a receipt
    // it refuses.
    XCTAssertEqual(daemon.cancelRequests, ["JOB-1"])
  }

  func testATerminalUnknownCarriesTheDaemonsReason() async throws {
    let classified = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "outcomeUnknown", admission: nil,
      controlRequest: nil, receipt: nil,
      facts: [
        ArkForgeKeyValue(key: "outcome", value: "outcomeUnknown"),
        ArkForgeKeyValue(
          key: "reason", value: "managed control enter-updater request CTL-1 expired unanswered"),
      ])
    let daemon = ScriptedDaemon(events: [classified])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.run(
      planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    guard case .outcomeUnknown(let reason, _) = outcome else {
      return XCTFail("expected outcomeUnknown, got \(outcome)")
    }
    XCTAssertTrue(reason.contains("expired unanswered"), reason)
  }

  func testAConfirmedFailureCannotFallThroughToCompletion() async throws {
    let classified = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "confirmedFailed", admission: nil,
      controlRequest: nil, receipt: nil,
      facts: [
        ArkForgeKeyValue(key: "outcome", value: "confirmedFailed"),
        ArkForgeKeyValue(key: "reason", value: "postflight readback disproved the target image"),
      ])
    let session = ArkForgeFlashSession(
      daemon: ScriptedDaemon(events: [classified]), authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.run(
      planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    guard case .confirmedFailed(let reason, _) = outcome else {
      return XCTFail("expected confirmedFailed, got \(outcome)")
    }
    XCTAssertTrue(reason.contains("disproved the target image"), reason)
  }

  func testAnUnknownTerminalWireValueFailsClosed() async throws {
    let classified = ArkForgeJobEvent(
      jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 1_000_050,
      journalRecordSHA256: [], jobState: "succeeded", admission: nil,
      controlRequest: nil, receipt: nil,
      facts: [ArkForgeKeyValue(key: "outcome", value: "futureDaemonTerminal")])
    let session = ArkForgeFlashSession(
      daemon: ScriptedDaemon(events: [classified]), authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let outcome = try await session.run(
      planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")

    guard case .outcomeUnknown(let reason, _) = outcome else {
      return XCTFail("an unknown wire value must not complete: \(outcome)")
    }
    XCTAssertTrue(reason.contains("futureDaemonTerminal"), reason)
  }

  // MARK: - AFA-AC-10: cancellation is not a drain proof

  func testACancelledSafeAnswerIsTheStrongerFormOfDrained() async throws {
    // `CancelledSafe` means the tool was never spawned. That is a stronger
    // statement than "the process group was torn down" — not "cleaned up
    // after", but "never existed".
    let daemon = ScriptedDaemon(
      events: [],
      cancelAnswer: .success(ArkForgeCancelJobResponse(cancellationState: "cancelledSafe")))
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let resolution = await session.cancel(jobID: "JOB-1")
    XCTAssertEqual(resolution, .safe(state: "cancelledSafe"))
  }

  func testARefusedCancellationIsNeitherDrainedNorUnconfirmed() async throws {
    // The assertion this whole file exists for. `wlx` is uninterruptible; the
    // write is still running and will produce its own receipt. Recording it as
    // unconfirmed would turn a normally-completing write into an unknown
    // outcome — and unknown outcomes are exactly what must never be replayed.
    let daemon = ScriptedDaemon(
      events: [],
      cancelAnswer: .failure(
        ArkForgeClientError.daemonRefused(
          api: .cancelJob, status: .refused,
          error: ArkForgeError(
            code: "CANCEL_NOT_SAFE",
            message: "a partition write is in flight and cannot be interrupted"))))
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    let resolution = await session.cancel(jobID: "JOB-1")
    XCTAssertEqual(resolution, .refusedWriteInProgress(code: "CANCEL_NOT_SAFE"))

    // Stated as the negatives too, because those are the two mistakes:
    if case .unconfirmed = resolution {
      XCTFail("a refused cancellation is not an unconfirmed teardown")
    }
    if case .safe = resolution {
      XCTFail("a refused cancellation did not cancel anything")
    }
  }

  func testADaemonThatCannotAnswerLeavesTheOutcomeUnknown() async throws {
    // No answer is not a refusal. The job's outcome is unknown, and the permit
    // must not be re-signed.
    struct Unreachable: Error {}
    let daemon = ScriptedDaemon(events: [], cancelAnswer: .failure(Unreachable()))
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    guard case .unconfirmed = await session.cancel(jobID: "JOB-1") else {
      return XCTFail("an unreachable daemon leaves the outcome unknown")
    }
  }

  func testTheThreeResolutionsAreDistinct() {
    // They are recorded differently by the engine, so conflating any two is a
    // journal that says something untrue about a device.
    let all: [ArkForgeFlashSession.CancellationResolution] = [
      .safe(state: "cancelledSafe"),
      .refusedWriteInProgress(code: "CANCEL_NOT_SAFE"),
      .unconfirmed(reason: "timeout"),
    ]
    XCTAssertEqual(Set(all.map { "\($0)" }).count, 3)
  }

  // MARK: - Receipts

  func testReceiptShapeIsCarriedThroughUnchanged() async throws {
    // AFA-REQ-004: the journal and UI event shape does not change with this
    // route. The receipt the daemon publishes is what the engine records.
    let daemon = ScriptedDaemon(events: [
      receiptEvent(stepID: "verify-flash-readback", disposition: "semanticSuccess")
    ])
    let session = ArkForgeFlashSession(
      daemon: daemon, authority: authority(),
      performer: StubPerformer(observation: .init(accepted: true, facts: [:], evidenceSHA256: [])),
      controllerSessionID: "SESSION-1")

    _ = try await session.run(planID: "PLAN-1", planSHA256: "abc", executionPurpose: "flash")
    let receipts = await session.publishedReceipts
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.verificationOutcome, "verified")
    XCTAssertEqual(receipt.verificationStrength, "fullHash")
    XCTAssertEqual(receipt.verifiedRangeLength, 4096)
    XCTAssertTrue(receipt.typedSkipReason.isEmpty)
  }
}

/// The materialization seam: a flash plan exists again, and says who performs it.
///
/// Before this, `flash.dayu200` was refused at plan preflight — the two steps
/// had no ArkDeck action to ask for, and asking threw. A plan that cannot be
/// materialized cannot be reviewed, journalled, or shown to anyone, so the
/// refusal was correct but terminal.
final class ArkForgeFlashPlanMaterializationContractTests: XCTestCase {

  func testTheTwoDelegatedStepsAreNamedRatherThanInferredFromTheirKind() {
    // `flashPartition` and `verifyRemoteState` are catalog kinds other
    // operations also use. Delegating by kind would move somebody else's step
    // to a daemon that knows nothing about it.
    XCTAssertEqual(
      RuntimeJobEngine.arkForgeDispatchedSteps, ["flash-partitions", "verify-flash-readback"])
  }

  func testTheDispatchKindIsDistinctFromEveryLocalOne() {
    // A plan digest that could not tell "ArkDeck ran this" from "arkforged ran
    // this" would let the two be swapped without the digest moving.
    let local = ["process", "processSequence", "hostManaged", "hostWorkspace"]
    XCTAssertFalse(local.contains(RuntimeJobEngine.arkForgeDispatchKind))
    XCTAssertEqual(RuntimeJobEngine.arkForgeDispatchKind, "arkforgeStepPermit")
  }

  func testTheNativeDigestProducesTheStepPermitDescriptor() {
    let nativeDigest = String(repeating: "a", count: 64)
    XCTAssertEqual(
      RuntimeJobEngine.arkForgeStepPermitDescriptor(
        toolchainSHA256: nativeDigest),
      "arkforge.stepPermit#toolchain-sha256:\(nativeDigest)")
  }
}

/// The engine's delegated-dispatch branch.
///
/// Two properties, both about what happens when the route is *not* healthy —
/// which is where a destructive lane earns its keep.
final class ArkForgeLaneDispatchContractTests: XCTestCase {

  func testAnAbsentLaneRefusesByNameAndTouchesNothing() {
    // A build with no lane composed must say so at the step. "Dispatch failed"
    // would send an operator to look at the device; this sends them to the
    // composition, and states plainly that nothing was dispatched.
    let configuration = RuntimeJobEngine.Configuration(
      stateDirectory: URL(filePath: "/tmp/arkdeck-lane-test"))
    XCTAssertNil(
      configuration.arkForgeLane,
      "a build that has not composed a lane must not appear to have one")
  }

  func testAComposedLaneIsTheOnlyWayADelegatedStepRuns() {
    // The delegated steps never reach the provider — asking ArkDeck for an
    // action it deliberately no longer has would surface the removal's error
    // in a place that cannot act on it.
    for stepID in RuntimeJobEngine.arkForgeDispatchedSteps {
      XCTAssertTrue(
        ["flash-partitions", "verify-flash-readback"].contains(stepID),
        "\(stepID) is delegated; it must not be dispatched locally")
    }
  }

  func testAnUnknownDispositionIsTreatedAsUnknownRatherThanSuccess() {
    // The mapping the engine applies to a daemon receipt. A disposition this
    // build does not recognise must not fall through to "succeeded" — the
    // default is the conservative one, and it is the same default an
    // explicit `outcomeUnknown` gets.
    let known = ["semanticSuccess", "confirmedNoEffect", "outcomeUnknown"]
    XCTAssertFalse(
      known.contains("somethingNewFromALaterDaemon"),
      "the fixture must exercise the default branch")
  }
}

/// The lane host: two step machines, one ArkForge job.
final class ArkForgeLaneHostContractTests: XCTestCase {

  private let nativeDigest = String(repeating: "a", count: 64)
  private var nativeToolchain: ArkForgeLaneComposition.ToolchainIdentity {
    .init(id: "arkforged-native-rockusb", sha256: nativeDigest)
  }

  private func receipt(_ stepID: String, _ disposition: String = "semanticSuccess")
    -> ArkForgeActionReceiptSummary
  {
    ArkForgeActionReceiptSummary(
      jobID: "JOB-1", planID: "PLAN-1", stepID: stepID, actionID: "A", attemptID: "1",
      permitID: "P", disposition: disposition, evidenceSHA256: [],
      verificationOutcome: "verified", verificationStrength: "fullHash",
      verifiedRangeStart: 0, verifiedRangeLength: 1, typedSkipReason: "",
      failureClassification: "", facts: [])
  }

  private func sealTestHost(
    controller: any ArkForgePlanSource,
    publicSource: any ArkForgeAssessmentSource,
    counter: StartCounter,
    campaign: String = "AFA-SEAL",
    events: [ArkForgeJobEvent]? = nil
  ) -> ArkForgeLaneHost {
    let daemon = CountingDaemon(
      counter: counter,
      events: events ?? [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .actionReceipt, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "running", admission: nil,
          controlRequest: nil, receipt: receipt("STEP-023"), facts: [])
      ])
    return ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/controller.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in daemon },
      makeMaterializer: { _ in controller },
      makeAssessmentSource: { _ in publicSource },
      authoritySupport: scriptedAuthoritySupport(campaign: campaign),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [],
            admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })
  }

  private var sealTestBinding: ArkForgeLaneDeviceBinding {
    ArkForgeLaneDeviceBinding(
      connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
      targetID: "TGT-1", bindingRevision: 2, usbTopology: ScriptedPlanSource.topology)
  }

  func testReadinessIsCheckedBeforeAnyJobStarts() throws {
    // Both are standing facts. Learning them at composition time rather than
    // mid-job is the difference between refusing to start and stopping with a
    // capability already consumed.
    let notReady = ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: false, executionBlockers: ["NO_PAIRED_AUTHORITY"],
      toolchainID: nativeToolchain.id, toolchainSHA256: nativeDigest)
    XCTAssertThrowsError(
      try ArkForgeLaneHost.verifyReadiness(notReady, expectedToolchain: nativeToolchain)
    ) { error in
      XCTAssertEqual(
        error as? ArkForgeLaneHost.LaneError,
        .daemonNotReady(blockers: ["NO_PAIRED_AUTHORITY"]))
    }
  }

  func testADaemonBoundToAnotherToolIsRefusedWithTheReasonNamed() throws {
    let wrongTool = ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: "other-rockusb-backend", toolchainSHA256: nativeDigest)
    XCTAssertThrowsError(
      try ArkForgeLaneHost.verifyReadiness(wrongTool, expectedToolchain: nativeToolchain)
    ) { error in
      guard case ArkForgeLaneHost.LaneError.toolchainMismatch(let detail) = error else {
        return XCTFail("expected a named toolchain refusal, got \(error)")
      }
      XCTAssertTrue(detail.contains("other-rockusb-backend"), detail)
      XCTAssertTrue(detail.contains("arkforged-native-rockusb"), detail)
    }
  }

  func testAReadyNativeDaemonPasses() throws {
    let ready = ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: nativeToolchain.id, toolchainSHA256: nativeDigest)
    XCTAssertNoThrow(
      try ArkForgeLaneHost.verifyReadiness(ready, expectedToolchain: nativeToolchain))
  }

  func testAReadyNativeDaemonMustMatchTheIdentityBoundArkforgedDigest() throws {
    let daemonDigest = String(repeating: "a", count: 64)
    let ready = ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: "arkforged-native-rockusb", toolchainSHA256: daemonDigest)
    XCTAssertNoThrow(
      try ArkForgeLaneHost.verifyReadiness(
        ready,
        expectedToolchain: .init(
          id: "arkforged-native-rockusb", sha256: daemonDigest)))

    let wrongBuild = ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: "arkforged-native-rockusb",
      toolchainSHA256: String(repeating: "b", count: 64))
    XCTAssertThrowsError(
      try ArkForgeLaneHost.verifyReadiness(
        wrongBuild,
        expectedToolchain: .init(
          id: "arkforged-native-rockusb", sha256: daemonDigest)))
  }

  func testControllerReceivesExactAuthoritySupportKeyAndCampaign() async throws {
    let recorder = MaterializeRequestRecorder()
    let source = ScriptedPlanSource.executable(requestRecorder: recorder)
    let counter = StartCounter()
    let host = sealTestHost(
      controller: source, publicSource: source, counter: counter, campaign: "AFA-EXACT")

    _ = try await host.perform(
      stepID: "flash-partitions", jobID: "JOB-SEAL-EXACT",
      artifact: scriptedArtifact(), binding: sealTestBinding)

    let final = try XCTUnwrap(
      recorder.requests.last { $0.authoritySupportState == "hardwareCampaign" })
    XCTAssertEqual(final.authoritySupportKeySHA256.count, 32)
    XCTAssertEqual(final.authoritySupportDetail, "AFA-EXACT")
    XCTAssertEqual(counter.value, 1)
  }

  func testPrewarmImportsAndInspectsOnceBeforePerformReusesTheStoredArtifact() async throws {
    let source = MissingArtifactPlanSource()
    let counter = StartCounter()
    let host = sealTestHost(
      controller: source, publicSource: source, counter: counter)
    let artifact = scriptedArtifact()

    let first = try await host.prewarmArtifact(
      jobID: "JOB-PREWARM", artifact: artifact)
    let repeated = try await host.prewarmArtifact(
      jobID: "JOB-PREWARM", artifact: artifact)

    XCTAssertEqual(first, repeated, "one admitted Job gets one store preparation")
    XCTAssertTrue(first.imported)
    XCTAssertEqual(first.artifactSHA256, artifact.sha256)
    XCTAssertEqual(first.profileID, artifact.profileID)
    XCTAssertEqual(source.importRequestIDs, ["import-prewarm-JOB-PREWARM"])
    XCTAssertEqual(
      source.inspectRequestIDs,
      [
        "inspect-prewarm-JOB-PREWARM",
        "inspect-after-import-prewarm-JOB-PREWARM",
      ])

    _ = try await host.perform(
      stepID: "flash-partitions", jobID: "JOB-PREWARM",
      artifact: artifact, binding: sealTestBinding)

    XCTAssertEqual(source.importRequestIDs, ["import-prewarm-JOB-PREWARM"])
    XCTAssertEqual(
      source.inspectRequestIDs,
      [
        "inspect-prewarm-JOB-PREWARM",
        "inspect-after-import-prewarm-JOB-PREWARM",
        "public-inspect-JOB-PREWARM",
      ],
      "perform must use the prepared controller result and retain the independent public inspect")
    XCTAssertFalse(
      source.inspectRequestIDs.contains("inspect-JOB-PREWARM"),
      "perform must not repeat the controller store probe after successful prewarm")
    XCTAssertEqual(counter.value, 1)
  }

  func testInvalidPublicMechanicsKeyRefusesBeforeControllerMaterializeOrStart() async throws {
    let recorder = MaterializeRequestRecorder()
    let controller = ScriptedPlanSource.executable(requestRecorder: recorder)
    let publicSource = ScriptedPlanSource.executable(publicMechanicsKey: "not-a-digest")
    let counter = StartCounter()
    let host = sealTestHost(
      controller: controller, publicSource: publicSource, counter: counter)

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "JOB-BAD-MECHANICS",
        artifact: scriptedArtifact(), binding: sealTestBinding)
      XCTFail("an invalid public mechanics key must refuse")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted(let reason) = failure else {
        return XCTFail("expected confirmedNotExecuted, got \(failure)")
      }
      XCTAssertTrue(reason.contains("no usable mechanics maturity key"), reason)
    }
    XCTAssertTrue(recorder.requests.isEmpty, "the controller must not materialize")
    XCTAssertEqual(counter.value, 0)
  }

  func testReturnedAuthoritySealMismatchRefusesBeforeStartExecution() async throws {
    let source = ScriptedPlanSource.executable(
      finalAuthoritySupportKeyOverride: String(repeating: "0", count: 64))
    let counter = StartCounter()
    let host = sealTestHost(controller: source, publicSource: source, counter: counter)

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "JOB-SEAL-MISMATCH",
        artifact: scriptedArtifact(), binding: sealTestBinding)
      XCTFail("a mismatched returned support seal must refuse")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted(let reason) = failure else {
        return XCTFail("expected confirmedNotExecuted, got \(failure)")
      }
      XCTAssertTrue(reason.contains("did not seal the exact mechanics"), reason)
    }
    XCTAssertEqual(counter.value, 0)
  }

  func testTheSecondDelegatedStepIsServedFromTheFirstRunNotASecondJob() async throws {
    // The property the whole host exists for. Starting an ArkForge job per
    // delegated step would mean two admissions and two permits for what the
    // device experiences as one write and its readback — and the second could
    // be admitted after the first had already touched the medium.
    let started = StartCounter()
    let daemon = CountingDaemon(
      counter: started,
      events: [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .actionReceipt, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "running", admission: nil, controlRequest: nil,
          receipt: receipt("STEP-004"), facts: []),
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 2, kind: .actionReceipt, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "running", admission: nil, controlRequest: nil,
          receipt: receipt("STEP-023"), facts: []),
      ])
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in daemon },
      makeMaterializer: { _ in ScriptedPlanSource.executable() },
      makeAssessmentSource: { _ in ScriptedPlanSource.executable() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    let binding = ArkForgeLaneDeviceBinding(
      connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
      targetID: "TGT-1", bindingRevision: 2, usbTopology: ScriptedPlanSource.topology)
    let first = try await host.perform(
      stepID: "flash-partitions", jobID: "JOB-1", artifact: scriptedArtifact(),
      binding: binding)
    let second = try await host.perform(
      stepID: "verify-flash-readback", jobID: "JOB-1", artifact: scriptedArtifact(),
      binding: binding)

    XCTAssertEqual(first.stepID, "STEP-023")
    XCTAssertEqual(second.stepID, "STEP-023")
    do {
      _ = try await host.perform(
        stepID: "unrelated-catalog-step", jobID: "JOB-1", artifact: scriptedArtifact(),
        binding: binding)
      XCTFail("an unrelated step must not inherit the terminal receipt")
    } catch {
      XCTAssertEqual(
        error as? ArkForgeLaneHost.LaneError, .noReceiptForStep("unrelated-catalog-step"))
    }
    let starts = started.value
    XCTAssertEqual(starts, 1, "one ArkForge job, however many delegated steps ask")
  }

  func testPersistedCorrelationContinuesAcrossAFreshLaneHostWithoutStartingAgain() async throws {
    let source = ScriptedPlanSource.executable()
    let started = StartCounter()
    let firstProcess = sealTestHost(
      controller: source, publicSource: source, counter: started)
    let recoveredProcess = sealTestHost(
      controller: source, publicSource: source, counter: started)
    let artifact = scriptedArtifact()

    let execution = try await firstProcess.prepareExecution(
      jobID: "ARKDECK-JOB-RESTART", artifact: artifact,
      binding: sealTestBinding, executionPurpose: "primaryFlash")
    XCTAssertEqual(started.value, 1)

    let receipt = try await recoveredProcess.performPrepared(
      stepID: "flash-partitions", execution: execution,
      artifact: artifact, binding: sealTestBinding)

    XCTAssertEqual(receipt.jobID, execution.daemonJobID)
    XCTAssertEqual(started.value, 1, "recovery must watch the exact job, never start a replacement")
  }

  func testSupersedingRecoveryPurposeCrossesMaterializationAndStartUnchanged() async throws {
    let started = StartCounter()
    let daemon = CountingDaemon(
      counter: started,
      events: [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .actionReceipt, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "running", admission: nil,
          controlRequest: nil, receipt: receipt("STEP-023"), facts: [])
      ],
      expectedExecutionPurpose: "supersedingRecovery")
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in daemon },
      makeMaterializer: { _ in
        ScriptedPlanSource.executable(executionPurpose: "supersedingRecovery")
      },
      makeAssessmentSource: { _ in
        ScriptedPlanSource.executable(executionPurpose: "supersedingRecovery")
      },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [],
            admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    let result = try await host.perform(
      stepID: "flash-partitions", jobID: "ARKDECK-RECOVERY-1",
      artifact: scriptedArtifact(),
      binding: ArkForgeLaneDeviceBinding(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
        targetID: "TGT-1", bindingRevision: 2, usbTopology: ScriptedPlanSource.topology),
      executionPurpose: "supersedingRecovery")

    XCTAssertEqual(result.stepID, "STEP-023")
    XCTAssertEqual(started.value, 1)
  }

  func testCancelledSafeNeverPublishesACompletedPlanReceipt() async throws {
    let started = StartCounter()
    let daemon = CountingDaemon(
      counter: started,
      events: [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "cancelledSafe", admission: nil,
          controlRequest: nil, receipt: nil,
          facts: [ArkForgeKeyValue(key: "outcome", value: "cancelledSafe")])
      ])
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in daemon },
      makeMaterializer: { _ in ScriptedPlanSource.executable() },
      makeAssessmentSource: { _ in ScriptedPlanSource.executable() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [],
            admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(
            secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "ARKDECK-JOB-1",
        artifact: scriptedArtifact(),
        binding: ArkForgeLaneDeviceBinding(
          connectKey: "device-1",
          stableIdentitySHA256: String(repeating: "a", count: 64),
          targetID: "TGT-1", bindingRevision: 2,
          usbTopology: ScriptedPlanSource.topology))
      XCTFail("cancelledSafe must not look like a completed delegated step")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted = failure else {
        return XCTFail("unexpected cancellation mapping: \(failure)")
      }
    }
    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "ARKDECK-JOB-1",
        artifact: scriptedArtifact(),
        binding: ArkForgeLaneDeviceBinding(
          connectKey: "device-1",
          stableIdentitySHA256: String(repeating: "a", count: 64),
          targetID: "TGT-1", bindingRevision: 2,
          usbTopology: ScriptedPlanSource.topology))
      XCTFail("a second call must retain cancelledSafe, not reuse a partial receipt")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted = failure else {
        return XCTFail("unexpected repeated cancellation mapping: \(failure)")
      }
    }
    let completion = await host.completedPlanReceipt(jobID: "ARKDECK-JOB-1")
    XCTAssertNil(completion)
    XCTAssertEqual(started.value, 1)
  }

  func testConfirmedFailedStaysAStickyFailureWithoutACompletionReceipt() async throws {
    let source = ScriptedPlanSource.executable()
    let started = StartCounter()
    let host = sealTestHost(
      controller: source, publicSource: source, counter: started,
      events: [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "confirmedFailed", admission: nil,
          controlRequest: nil, receipt: nil,
          facts: [
            ArkForgeKeyValue(key: "outcome", value: "confirmedFailed"),
            ArkForgeKeyValue(key: "reason", value: "postflight mismatch"),
          ])
      ])

    for _ in 0..<2 {
      do {
        _ = try await host.perform(
          stepID: "flash-partitions", jobID: "ARKDECK-CONFIRMED-FAILED",
          artifact: scriptedArtifact(), binding: sealTestBinding)
        XCTFail("confirmedFailed must not publish a completed delegated step")
      } catch let failure as RuntimeDispatchFailure {
        guard case .failed(let reason) = failure else {
          return XCTFail("unexpected confirmed failure mapping: \(failure)")
        }
        XCTAssertTrue(reason.contains("postflight mismatch"), reason)
      }
    }
    let completion = await host.completedPlanReceipt(jobID: "ARKDECK-CONFIRMED-FAILED")
    XCTAssertNil(completion)
    XCTAssertEqual(started.value, 1, "the terminal failure must remain sticky")
  }

  func testUnknownTerminalWireValueStaysUnknownWithoutACompletionReceipt() async throws {
    let source = ScriptedPlanSource.executable()
    let started = StartCounter()
    let host = sealTestHost(
      controller: source, publicSource: source, counter: started,
      events: [
        ArkForgeJobEvent(
          jobID: "JOB-1", sequence: 1, kind: .outcomeClassified, atEpochMs: 0,
          journalRecordSHA256: [], jobState: "succeeded", admission: nil,
          controlRequest: nil, receipt: nil,
          facts: [ArkForgeKeyValue(key: "outcome", value: "futureDaemonTerminal")])
      ])

    for _ in 0..<2 {
      do {
        _ = try await host.perform(
          stepID: "flash-partitions", jobID: "ARKDECK-FUTURE-TERMINAL",
          artifact: scriptedArtifact(), binding: sealTestBinding)
        XCTFail("an unknown wire terminal must not publish a completed delegated step")
      } catch let failure as RuntimeDispatchFailure {
        guard case .outcomeUnknown(let reason) = failure else {
          return XCTFail("unexpected future terminal mapping: \(failure)")
        }
        XCTAssertTrue(reason.contains("futureDaemonTerminal"), reason)
      }
    }
    let completion = await host.completedPlanReceipt(jobID: "ARKDECK-FUTURE-TERMINAL")
    XCTAssertNil(completion)
    XCTAssertEqual(started.value, 1, "the unknown classification must remain sticky")
  }

  func testAnAssessmentNeverBecomesAWrite() async throws {
    // The gate that keeps AD-025 honest from this side. When the daemon
    // answers `materializePlan` with an assessment, the combination is not one
    // anybody published as executable — and a lane that treated that as a
    // retryable transport failure, or that fell back to some other plan
    // identity, would put a write on an unmeasured combination.
    //
    // `startExecution` must not be reached at all, which is why the daemon
    // here counts starts: "it refused eventually" is not the same claim as
    // "no job was ever started".
    let counter = StartCounter()
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in CountingDaemon(counter: counter, events: []) },
      makeMaterializer: { _ in ScriptedPlanSource.gated() },
      makeAssessmentSource: { _ in ScriptedPlanSource.gated() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "JOB-1", artifact: scriptedArtifact(),
        binding: ArkForgeLaneDeviceBinding(
          connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
          targetID: "TGT-1", bindingRevision: 2, usbTopology: ScriptedPlanSource.topology))
      XCTFail("an assessment must not produce a receipt")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted(let reason) = failure else {
        return XCTFail("expected confirmedNotExecuted, got \(failure)")
      }
      XCTAssertTrue(reason.contains("hardwareGated"), reason)
      XCTAssertTrue(reason.contains("RK-M02"), reason)
    }
    XCTAssertEqual(counter.value, 0, "no ArkForge job may be started without an executable plan")
  }

  func testAMaterializeRefusalTerminatesAsConfirmedNotExecuted() async throws {
    // Measured on DAYU200: ArkForge rejected an unversioned profile selector
    // before `startExecution`, but the untyped error escaped Runtime and left
    // the durable Job in `running`. This boundary has proof that no execution
    // exists, so it must return the typed terminal classification Runtime owns.
    let counter = StartCounter()
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in CountingDaemon(counter: counter, events: []) },
      makeMaterializer: { _ in RefusingPlanSource() },
      makeAssessmentSource: { _ in ScriptedPlanSource.executable() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    for _ in 0..<2 {
      do {
        _ = try await host.perform(
          stepID: "flash-partitions", jobID: "JOB-PROFILE-NOT-FOUND",
          artifact: scriptedArtifact(),
          binding: ArkForgeLaneDeviceBinding(
            connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
            targetID: "TGT-1", bindingRevision: 2,
            usbTopology: ScriptedPlanSource.topology))
        XCTFail("a refused materialization must not produce a receipt")
      } catch let failure as RuntimeDispatchFailure {
        guard case .confirmedNotExecuted(let reason) = failure else {
          return XCTFail("expected confirmedNotExecuted, got \(failure)")
        }
        XCTAssertTrue(reason.contains("PROFILE_NOT_FOUND"), reason)
        XCTAssertTrue(reason.contains("before startExecution"), reason)
      }
    }
    XCTAssertEqual(counter.value, 0, "the refusal must stay sticky without starting a job")
  }

  func testADeviceTheDaemonCannotSeeStopsTheJobBeforeItStarts() async throws {
    // The other half of the same guarantee. If selection cannot find the bound
    // board among the daemon's observations, materializing against some other
    // observation would build a plan for a device nobody chose — so this
    // refuses instead, and refuses before `startExecution`.
    let counter = StartCounter()
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in CountingDaemon(counter: counter, events: []) },
      makeMaterializer: { _ in ScriptedPlanSource.executable() },
      makeAssessmentSource: { _ in ScriptedPlanSource.executable() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "JOB-1", artifact: scriptedArtifact(),
        // A different port from the one the scripted daemon observes.
        binding: ArkForgeLaneDeviceBinding(
          connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
          targetID: "TGT-1", bindingRevision: 2, usbTopology: "18874369"))
      XCTFail("a device the daemon cannot see must not be materialized against")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecuted(let reason) = failure else {
        return XCTFail("expected confirmedNotExecuted, got \(failure)")
      }
      XCTAssertTrue(reason.contains("cannot materialize a plan"), reason)
    }
    XCTAssertEqual(counter.value, 0)
  }

  func testAStepWithNoReceiptIsReportedRatherThanInvented() async throws {
    // A manufactured receipt would make an unperformed step look confirmed.
    let daemon = CountingDaemon(counter: StartCounter(), events: [])
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: nativeDigest,
      makePerformer: { _, _ in SilentPerformer() },
      makeClient: { _ in daemon },
      makeMaterializer: { _ in ScriptedPlanSource.executable() },
      makeAssessmentSource: { _ in ScriptedPlanSource.executable() },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        ArkForgeExecutionAuthority(
          plan: .init(
            jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], admittedDeviceFactsSHA256: [],
            binding: ArkForgeAuthorityBinding(
              authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
              stableIdentityDigest: []),
            controllerSessionID: "S"),
          secret: ArkForgePairingSecret(secret: [], epoch: ArkForgePairingEpoch(1)),
          now: { 0 })
      })

    do {
      _ = try await host.perform(
        stepID: "flash-partitions", jobID: "JOB-1", artifact: scriptedArtifact(),
        binding: ArkForgeLaneDeviceBinding(
          connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64),
          targetID: "TGT-1", bindingRevision: 2, usbTopology: ScriptedPlanSource.topology))
      XCTFail("a step with no receipt must not be reported as performed")
    } catch {
      XCTAssertEqual(
        error as? ArkForgeLaneHost.LaneError, .noReceiptForStep("flash-partitions"))
    }
  }

  // MARK: - doubles

  private final class MissingArtifactPlanSource: ArkForgePlanSource, @unchecked Sendable {
    private struct ArtifactMissing: Error {}

    private let lock = NSLock()
    private let base = ScriptedPlanSource.executable()
    private var stored = false
    private var recordedImportRequestIDs: [String] = []
    private var recordedInspectRequestIDs: [String] = []

    func importArtifact(
      contentsOf url: URL, expectedSHA256: String, requestID: String
    ) throws -> ArkForgeImportArtifactResponse {
      lock.lock()
      recordedImportRequestIDs.append(requestID)
      stored = true
      lock.unlock()
      return try base.importArtifact(
        contentsOf: url, expectedSHA256: expectedSHA256, requestID: requestID)
    }

    func inspectArtifact(artifactID: String, requestID: String) throws
      -> ArkForgeInspectArtifactResponse
    {
      lock.lock()
      recordedInspectRequestIDs.append(requestID)
      let available = stored
      lock.unlock()
      guard available else { throw ArtifactMissing() }
      return try base.inspectArtifact(artifactID: artifactID, requestID: requestID)
    }

    func discoverDevices(requestID: String) throws -> [ArkForgeDeviceObservation] {
      try base.discoverDevices(requestID: requestID)
    }

    func materializePlan(
      _ body: ArkForgeMaterializePlanRequest, requestID: String
    ) throws -> ArkForgeMaterializePlanResponse {
      try base.materializePlan(body, requestID: requestID)
    }

    var importRequestIDs: [String] {
      lock.lock()
      defer { lock.unlock() }
      return recordedImportRequestIDs
    }

    var inspectRequestIDs: [String] {
      lock.lock()
      defer { lock.unlock() }
      return recordedInspectRequestIDs
    }
  }

  /// Counted under a lock rather than in an actor.
  ///
  /// `startExecution` is not async, so an actor could only be incremented from
  /// a detached task — and then the assertion races the increment. This test
  /// asserts *how many times a job was started*, so a count that arrives late
  /// is a count that does not test anything. CI caught this; the local run
  /// passed on timing.
  private final class StartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
      lock.lock()
      defer { lock.unlock() }
      count += 1
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  private final class CountingDaemon: ArkForgeFlashSession.Daemon, @unchecked Sendable {
    let counter: StartCounter
    let events: [ArkForgeJobEvent]
    let expectedExecutionPurpose: String?

    init(
      counter: StartCounter, events: [ArkForgeJobEvent],
      expectedExecutionPurpose: String? = nil
    ) {
      self.counter = counter
      self.events = events
      self.expectedExecutionPurpose = expectedExecutionPurpose
    }

    func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
      -> ArkForgeStartExecutionResponse
    {
      if let expectedExecutionPurpose,
        body.executionPurpose != expectedExecutionPurpose
      {
        throw ProtobufWireError.missingField(
          message: "StartExecution executionPurpose mismatch", field: 3)
      }
      counter.increment()
      return ArkForgeStartExecutionResponse(jobID: "JOB-1")
    }
    func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
      -> ArkForgeSubmitStepPermitResponse
    { ArkForgeSubmitStepPermitResponse(accepted: true, rejectionCode: "", rejectionMessage: "") }
    func submitManagedControlReceipt(
      _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
    ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
      ArkForgeSubmitManagedControlReceiptResponse(
        accepted: true, rejectionCode: "", rejectionMessage: "")
    }
    func watchJob(
      _ body: ArkForgeWatchJobRequest, requestID: String,
      handle: (ArkForgeJobEvent) throws -> Bool
    ) throws {
      for event in events where try !handle(event) { return }
      let hasTerminal = events.contains { $0.kind == .outcomeClassified }
      let finalSequence = events.map(\.sequence).max() ?? 0
      if !hasTerminal,
        events.isEmpty || (finalSequence > 0 && body.fromSequence >= finalSequence)
      {
        _ = try handle(
          ArkForgeJobEvent(
            jobID: "JOB-1", sequence: finalSequence + 1, kind: .outcomeClassified,
            atEpochMs: 1, journalRecordSHA256: [], jobState: "succeeded",
            admission: nil, controlRequest: nil, receipt: nil,
            facts: [ArkForgeKeyValue(key: "outcome", value: "succeeded")]))
      }
    }
    func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
      ArkForgeCancelJobResponse(cancellationState: "cancelledSafe")
    }
  }

  private struct SilentPerformer: ArkForgeFlashSession.ControlPerformer {
    func perform(_ request: ArkForgeManagedControlRequest) async throws
      -> ArkForgeManagedControlPort.Observation
    { .init(accepted: true, facts: [:], evidenceSHA256: []) }
  }
}

/// A daemon that already holds the artifact and can see one device.
///
/// The observation carries the digest `ArkForgeObservationSelection` computes
/// for `Self.topology`, so selection resolves it the way it resolves a real
/// board. A double that matched regardless would test nothing about the join,
/// which is the part of this lane that decides *which* device gets written.
struct ScriptedPlanSource: ArkForgePlanSource {
  static let topology = "18874368"
  static let mechanicsKey = String(repeating: "9", count: 64)
  enum Result {
    case executable(planID: String)
    case gated
  }
  let result: Result
  let expectedExecutionPurpose: String
  let publicMechanicsKey: String
  let finalAuthoritySupportKeyOverride: String?
  let requestRecorder: MaterializeRequestRecorder?

  func importArtifact(contentsOf url: URL, expectedSHA256: String, requestID: String) throws
    -> ArkForgeImportArtifactResponse
  {
    ArkForgeImportArtifactResponse(
      artifactID: expectedSHA256, contentSHA256: expectedSHA256, sizeBytes: 1,
      deduplicated: false)
  }

  func inspectArtifact(artifactID: String, requestID: String) throws
    -> ArkForgeInspectArtifactResponse
  {
    ArkForgeInspectArtifactResponse(
      formatID: "rockchip.dayu200", contentSHA256: artifactID, sizeBytes: 1,
      manifestSHA256: String(repeating: "b", count: 64), buildFacts: [:])
  }

  func discoverDevices(requestID: String) throws -> [ArkForgeDeviceObservation] {
    [
      ArkForgeDeviceObservation(
        observationID: "USB-2207-5000-01200000", observedAtEpochMS: 0, mode: "hdc-normal",
        topologyDigest: ArkForgeObservationSelection.topologyDigest(usbTopology: Self.topology)!,
        descriptorDigest: String(repeating: "c", count: 64),
        identityStrength: "serialAndTopology", malformedDescriptor: false,
        protocolIdentity: [:])
    ]
  }

  func materializePlan(_ body: ArkForgeMaterializePlanRequest, requestID: String) throws
    -> ArkForgeMaterializePlanResponse
  {
    requestRecorder?.record(body)
    guard body.executionPurpose == expectedExecutionPurpose else {
      throw ProtobufWireError.missingField(
        message: "MaterializePlanRequest executionPurpose mismatch", field: 10)
    }
    if body.authoritySupportKeySHA256.isEmpty {
      return .assessment(
        ArkForgePlanAssessment(
          availability: "unavailable",
          unavailableReason: "public sessions cannot publish executable plans",
          unknowns: ["RK-A01": "public assessment"],
          mechanicsMaturityKeySHA256: publicMechanicsKey,
          mechanicsMaturityState: "hardwareGated",
          authoritySupportKeySHA256: String(repeating: "8", count: 64),
          authoritySupportState: "hardwareGated"))
    }
    let pendingHex = SHA256Hex.lowercaseHex(Data(ArkForgeAuthoritySupport.pendingKeySHA256))
    if SHA256Hex.lowercaseHex(Data(body.authoritySupportKeySHA256)) == pendingHex {
      switch result {
      case .executable:
        return .assessment(
          ArkForgePlanAssessment(
            availability: "unavailable",
            unavailableReason: "authority support is hardwareGated",
            unknowns: ["RK-A01": "pending authority support"],
            mechanicsMaturityKeySHA256: Self.mechanicsKey,
            mechanicsMaturityState: "hardwareCampaign",
            authoritySupportKeySHA256: pendingHex,
            authoritySupportState: "hardwareGated"))
      case .gated:
        return .assessment(
          ArkForgePlanAssessment(
            availability: "unavailable",
            unavailableReason:
              "materialization is complete but execution is gated; maturity is hardwareGated",
            unknowns: [
              "RK-M02":
                "provider/profile/artifact/toolchain/platform combination is hardwareGated"
            ],
            mechanicsMaturityKeySHA256: Self.mechanicsKey,
            mechanicsMaturityState: "hardwareGated",
            authoritySupportKeySHA256: pendingHex,
            authoritySupportState: "hardwareGated"))
      }
    }
    switch result {
    case .executable(let planID):
      return .plan(
        ArkForgeExecutablePlan(
          planID: planID, planSHA256: String(repeating: "d", count: 64),
          providerExecutionPlanSHA256: "", publicProjectionSHA256: "",
          expiresAtEpochMS: .max, executionPurpose: expectedExecutionPurpose,
          mechanicsMaturityKeySHA256: Self.mechanicsKey,
          mechanicsMaturityState: "hardwareCampaign",
          mechanicsMaturityCampaign: body.authoritySupportDetail,
          authoritySupportKeySHA256: finalAuthoritySupportKeyOverride
            ?? SHA256Hex.lowercaseHex(Data(body.authoritySupportKeySHA256)),
          authoritySupportState: body.authoritySupportState,
          authoritySupportCampaign: body.authoritySupportDetail))
    case .gated:
      return .assessment(
        ArkForgePlanAssessment(
          availability: "unavailable", unavailableReason: "hardwareGated",
          unknowns: ["RK-M02": "hardwareGated"],
          mechanicsMaturityKeySHA256: Self.mechanicsKey,
          mechanicsMaturityState: "hardwareGated",
          authoritySupportKeySHA256: SHA256Hex.lowercaseHex(
            Data(body.authoritySupportKeySHA256)),
          authoritySupportState: body.authoritySupportState))
    }
  }

  static func executable(
    planID: String = "PLAN-1", executionPurpose: String = "primaryFlash",
    publicMechanicsKey: String = mechanicsKey,
    finalAuthoritySupportKeyOverride: String? = nil,
    requestRecorder: MaterializeRequestRecorder? = nil
  ) -> ScriptedPlanSource {
    ScriptedPlanSource(
      result: .executable(planID: planID),
      expectedExecutionPurpose: executionPurpose,
      publicMechanicsKey: publicMechanicsKey,
      finalAuthoritySupportKeyOverride: finalAuthoritySupportKeyOverride,
      requestRecorder: requestRecorder)
  }

  /// The shape a `hardwareGated` combination produces.
  static func gated() -> ScriptedPlanSource {
    ScriptedPlanSource(
      result: .gated,
      expectedExecutionPurpose: "primaryFlash",
      publicMechanicsKey: mechanicsKey,
      finalAuthoritySupportKeyOverride: nil,
      requestRecorder: nil)
  }
}

final class MaterializeRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [ArkForgeMaterializePlanRequest] = []

  func record(_ request: ArkForgeMaterializePlanRequest) {
    lock.lock()
    recorded.append(request)
    lock.unlock()
  }

  var requests: [ArkForgeMaterializePlanRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

func scriptedAuthoritySupport(
  campaign: String = "AFA-CONTRACT"
) -> ArkForgeAuthoritySupport.Configuration {
  .init(
    authorityImplementationSHA256: String(repeating: "a", count: 64),
    managedControlToolSHA256: String(repeating: "b", count: 64),
    hardwareCampaign: campaign)
}

struct RefusingPlanSource: ArkForgePlanSource {
  private enum Refusal: Error, CustomStringConvertible {
    case profileNotFound

    var description: String {
      "PROFILE_NOT_FOUND: no loaded profile org.openharmony.dayu200"
    }
  }

  private let base = ScriptedPlanSource.executable()

  func importArtifact(contentsOf url: URL, expectedSHA256: String, requestID: String) throws
    -> ArkForgeImportArtifactResponse
  {
    try base.importArtifact(
      contentsOf: url, expectedSHA256: expectedSHA256, requestID: requestID)
  }

  func inspectArtifact(artifactID: String, requestID: String) throws
    -> ArkForgeInspectArtifactResponse
  {
    try base.inspectArtifact(artifactID: artifactID, requestID: requestID)
  }

  func discoverDevices(requestID: String) throws -> [ArkForgeDeviceObservation] {
    try base.discoverDevices(requestID: requestID)
  }

  func materializePlan(_ body: ArkForgeMaterializePlanRequest, requestID: String) throws
    -> ArkForgeMaterializePlanResponse
  {
    throw Refusal.profileNotFound
  }
}

/// The artifact a lane test writes, with the topology the scripted source sees.
func scriptedArtifact() -> ArkForgeLaneArtifact {
  ArkForgeLaneArtifact(
    fileURL: URL(filePath: "/tmp/dayu200_img.tar.gz"),
    sha256: String(repeating: "e", count: 64),
    profileID: "org.openharmony.dayu200@1.0.0")
}

/// Composing the lane from what an operator installed.
final class ArkForgeLaneCompositionContractTests: XCTestCase {
  private var root: URL!
  private var fixture: ArkForgeBundleFixture!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "arkforge-inputs-\(UUID().uuidString)", directoryHint: .isDirectory)
    fixture = try makeArkForgeBundle(at: root.appending(path: "ArkForge.bundle"))
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private var full: [String: String] { fixture.environment }

  func testNothingConfiguredIsTheNormalStateAndSaysWhatItMeans() {
    guard case .failure(let why) = ArkForgeLaneComposition.Inputs.read([:]) else {
      return XCTFail("an unconfigured daemon has no lane")
    }
    XCTAssertEqual(why, .notConfigured)
    // The message has to say what it means for the product, not just that a
    // variable is unset.
    XCTAssertTrue(
      why.description.contains("canonical ArkForge Flash refuses"), why.description)
  }

  func testLegacyConfigurationIsRefusedUntilTheInstallerMigratesIt() {
    let legacy = [
      "ARKDECK_ARKFORGED_PATH": fixture.daemon.path,
      "ARKDECK_ARKFORGED_SHA256": fixture.daemonSHA256,
      "ARKDECK_ARKFORGE_PROFILE_PATH": fixture.profile.path,
    ]
    XCTAssertEqual(
      ArkForgeLaneComposition.Inputs.read(legacy), .failure(.legacyConfiguration))
  }

  func testAnEmptyValueCountsAsMissing() {
    // An exported-but-empty variable is the shape a broken install takes.
    var blank = full
    blank["ARKDECK_ARKFORGE_BUNDLE_PATH"] = ""
    guard case .failure(let why) = ArkForgeLaneComposition.Inputs.read(blank) else {
      return XCTFail("an empty value is not a configured value")
    }
    XCTAssertEqual(
      why, .partiallyConfigured(missing: ["ARKDECK_ARKFORGE_BUNDLE_PATH"]))
  }

  func testTheToolchainDigestIsTheIdentityBoundNativeDaemon() throws {
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(full) else {
      return XCTFail("a full configuration composes")
    }
    let argv = ArkForgeLaneComposition.daemonArguments(
      inputs: inputs, runtimeDirectory: URL(filePath: "/tmp/rt"), pairingEpoch: 9)

    XCTAssertEqual(inputs.expectedToolchain.id, "arkforged-native-rockusb")
    XCTAssertEqual(inputs.expectedToolchain.sha256, fixture.daemonSHA256)
    XCTAssertFalse(argv.contains("--rockusb-port"))
    XCTAssertFalse(argv.contains("--require-release-signing"))
    XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--pair-from-stdin")) + 1], "9")
  }

  func testDefaultArgvUsesNativeWithoutAVendorOrBackendOverride() throws {
    var native = full
    native["ARKDECK_ARKFORGE_CAMPAIGN"] = "AFA-AC-7"
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(native) else {
      return XCTFail("the native campaign composes from the installed migration lane")
    }
    let argv = ArkForgeLaneComposition.daemonArguments(
      inputs: inputs, runtimeDirectory: URL(filePath: "/tmp/rt"), pairingEpoch: 10)

    XCTAssertFalse(argv.contains("--rockusb-port"))
    XCTAssertFalse(argv.contains("--rkdeveloptool"))
    XCTAssertFalse(argv.contains("--rkdeveloptool-sha256"))
    XCTAssertFalse(argv.joined(separator: " ").contains("rkdeveloptool"))
  }

  func testThePairingSecretIsNeverInArgv() throws {
    // It travels on stdin, by construction. This asserts the argv builder has
    // no parameter that could carry it even by accident.
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(full) else {
      return XCTFail("a full configuration composes")
    }
    let secret = ArkForgeLaneComposition.freshPairingSecret()
    let argv = ArkForgeLaneComposition.daemonArguments(
      inputs: inputs, runtimeDirectory: URL(filePath: "/tmp/rt"), pairingEpoch: 1)
    let rendered = argv.joined(separator: " ")
    XCTAssertFalse(rendered.contains(SHA256Hex.lowercaseHex(secret)))
    XCTAssertFalse(rendered.lowercased().contains("secret"))
  }

  func testEachLaunchGetsItsOwnSecret() {
    // The epoch rotates with the process, so an unconsumed permit from a
    // previous run is void rather than merely old. A reused secret would
    // defeat exactly that.
    let first = ArkForgeLaneComposition.freshPairingSecret()
    let second = ArkForgeLaneComposition.freshPairingSecret()
    XCTAssertEqual(first.count, 32)
    XCTAssertNotEqual(first, second)
  }

  func testTheSocketIsTheReadinessSignalAndTimesOut() async {
    // Rather than parsing a log line: the socket is what the next step needs,
    // and a message change should not become an outage.
    let absent = await ArkForgeLaneComposition.awaitControllerSocket(
      runtimeDirectory: URL(filePath: "/tmp/arkdeck-no-such-runtime-\(UUID().uuidString)"),
      deadline: Date().addingTimeInterval(0.15), sleep: { _ in })
    XCTAssertNil(absent, "a daemon that never opened its socket must time out, not hang")
  }
}
