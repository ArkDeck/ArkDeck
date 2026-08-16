import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

/// Step 5's wiring, and `AFA-AC-10`.
///
/// The session is driven by a scripted daemon rather than a real one so every
/// branch — including the ones a healthy run never reaches — is exercised. The
/// hardware run is this same code path with `ArkForgeDaemonClient` behind the
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
    { ArkForgeStartExecutionResponse(jobID: "JOB-1") }

    func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
      -> ArkForgeSubmitStepPermitResponse
    {
      permitSubmissions.append(body)
      return ArkForgeSubmitStepPermitResponse(
        accepted: body.refusal == nil, rejectionCode: "", rejectionMessage: "")
    }

    func submitManagedControlReceipt(
      _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
    ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
      controlSubmissions.append(body)
      return ArkForgeSubmitManagedControlReceiptResponse(
        accepted: true, rejectionCode: "", rejectionMessage: "")
    }

    func watchJob(
      _ body: ArkForgeWatchJobRequest, requestID: String,
      handle: (ArkForgeJobEvent) throws -> Bool
    ) throws {
      for event in events where try !handle(event) { return }
    }

    func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
      try cancelAnswer.get()
    }
  }

  private struct StubPerformer: ArkForgeFlashSession.ControlPerformer {
    let observation: ArkForgeManagedControlPort.Observation
    func perform(_ action: ArkForgeManagedControlAction, stepID: String) async throws
      -> ArkForgeManagedControlPort.Observation
    { observation }
  }

  private struct FailingPerformer: ArkForgeFlashSession.ControlPerformer {
    struct Boom: Error {}
    func perform(_ action: ArkForgeManagedControlAction, stepID: String) async throws
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
}
