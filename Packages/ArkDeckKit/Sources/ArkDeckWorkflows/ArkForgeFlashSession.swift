import ArkDeckCore
import ArkForgeIPC
import Foundation

/// Drives one `flash.dayu200` job across the ArkForge boundary.
///
/// The daemon never calls out. It *asks* on the `watchJob` stream and waits for
/// this side to call back in, which is what keeps every message
/// client-initiated and leaves this authority free to answer, to refuse, or to
/// say nothing — three outcomes the daemon tells apart (design §3.1). So this
/// is a loop that pulls events and answers them, not a delegate the daemon
/// pushes into.
///
/// What it does not do is decide anything. Admissions go to
/// `ArkForgeExecutionAuthority`, control requests go to
/// `ArkForgeManagedControlPort`, and this type carries the results between
/// them. Putting a judgement here would put it outside the two places that are
/// tested for it.
package actor ArkForgeFlashSession {

  /// The daemon surface this session needs, narrowed to what it calls.
  ///
  /// A protocol rather than the concrete client so a scripted daemon can drive
  /// the whole loop in tests. The real hardware run is the same code path with
  /// `ArkForgeDaemonClient` behind it.
  package protocol Daemon: Sendable {
    func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
      -> ArkForgeStartExecutionResponse
    func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
      -> ArkForgeSubmitStepPermitResponse
    func submitManagedControlReceipt(
      _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
    ) throws -> ArkForgeSubmitManagedControlReceiptResponse
    func watchJob(
      _ body: ArkForgeWatchJobRequest, requestID: String,
      handle: (ArkForgeJobEvent) throws -> Bool
    ) throws
    func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse
  }

  /// How a control request is actually performed on the device.
  ///
  /// Separate from the port that shapes the receipt, because performing is
  /// HDC work and shaping is a contract. The port refuses a receipt that would
  /// leak; this is what produces the observation it refuses or accepts.
  package protocol ControlPerformer: Sendable {
    /// Takes the whole request, not just the action.
    ///
    /// `READ_BUILD_FACTS` is the reason: the daemon states which fact it needs
    /// confirmed, and a performer given only the action would have to invent
    /// an expectation — which is exactly the postflight failure AF-011 exists
    /// to stop, since an invented expectation is one the device is guaranteed
    /// to meet.
    func perform(_ request: ArkForgeManagedControlRequest) async throws
      -> ArkForgeManagedControlPort.Observation
  }

  /// What a finished job amounts to, in the vocabulary the engine journals.
  package enum Outcome: Sendable, Equatable {
    case completed(receipts: [ArkForgeActionReceiptSummary])
    /// Cancelled with proof nothing external happened. Equivalent to the
    /// engine's `.drained`: the tool was never spawned, which is a stronger
    /// statement than "the process group was torn down".
    case cancelledSafe(receipts: [ArkForgeActionReceiptSummary])
    /// The stream ended without a terminal answer. Equivalent to
    /// `.unconfirmed`: the outcome is unknown and the permit must not be
    /// re-signed.
    case outcomeUnknown(reason: String, receipts: [ArkForgeActionReceiptSummary])
  }

  /// How a cancellation attempt resolved (design §6.3.1).
  ///
  /// Once dispatch leaves the ArkDeck process, that process group is no longer
  /// ArkDeck's, so there is no drain proof to obtain on this lane. These three
  /// are what remain, and collapsing the middle one into `.unconfirmed` is the
  /// mistake worth naming: it would record a write that is *still running
  /// normally* as an unknown outcome.
  package enum CancellationResolution: Sendable, Equatable {
    /// `CancelledSafe` — no tool was ever spawned. Close the intent cancelled.
    case safe(state: String)
    /// `CANCEL_NOT_SAFE` — the write is uninterruptible and continues to its
    /// own receipt. The cancellation was **refused**; this is neither a drained
    /// teardown nor an unconfirmed one.
    case refusedWriteInProgress(code: String)
    /// The daemon could not answer. Outcome unknown; do not re-sign.
    case unconfirmed(reason: String)
  }

  private let daemon: any Daemon
  private let authority: ArkForgeExecutionAuthority
  private let performer: any ControlPerformer
  private let controllerSessionID: String
  private var receipts: [ArkForgeActionReceiptSummary] = []
  private var refusals: [String] = []

  package init(
    daemon: any Daemon, authority: ArkForgeExecutionAuthority,
    performer: any ControlPerformer, controllerSessionID: String
  ) {
    self.daemon = daemon
    self.authority = authority
    self.performer = performer
    self.controllerSessionID = controllerSessionID
  }

  /// Every receipt the daemon published, in order. These are what the engine
  /// journals and what the UI renders; their shape is unchanged by this route.
  package var publishedReceipts: [ArkForgeActionReceiptSummary] { receipts }

  /// Admissions this authority declined, with reasons. A refusal is an answer.
  package var declinedAdmissions: [String] { refusals }

  /// Starts the job and drives it to a terminal outcome.
  package func run(
    planID: String, planSHA256: String, executionPurpose: String
  ) async throws -> Outcome {
    let started = try daemon.startExecution(
      ArkForgeStartExecutionRequest(
        planID: planID, planSHA256: planSHA256, executionPurpose: executionPurpose,
        controllerSessionID: controllerSessionID),
      requestID: "start-\(planID)")

    var terminal: Outcome?
    var pendingAdmissions: [ArkForgeStepAdmissionSnapshot] = []
    var pendingControls: [ArkForgeManagedControlRequest] = []

    try daemon.watchJob(
      ArkForgeWatchJobRequest(jobID: started.jobID), requestID: "watch-\(started.jobID)"
    ) { event in
      switch event.kind {
      case .stepAdmissionRequested:
        if let admission = event.admission { pendingAdmissions.append(admission) }
      case .managedControlRequested:
        if let request = event.controlRequest { pendingControls.append(request) }
      case .actionReceipt:
        if let receipt = event.receipt { self.receipts.append(receipt) }
      case .outcomeClassified:
        // The daemon's own classification is authoritative for the job's end.
        let disposition = event.facts.first { $0.key == "disposition" }?.value ?? ""
        if disposition == "outcomeUnknown" {
          terminal = .outcomeUnknown(
            reason: "the daemon classified this job's outcome as unknown",
            receipts: self.receipts)
        }
      default:
        break
      }
      // The handler must not block on device work: the daemon polls this
      // stream, and a handler waiting on a 15-second rebind would hold it.
      // Requests are collected and answered between polls.
      return terminal == nil
    }

    for admission in pendingAdmissions {
      try await answer(admission, jobID: started.jobID)
    }
    for control in pendingControls {
      try await answer(control, jobID: started.jobID)
    }

    if let terminal { return terminal }
    return .completed(receipts: receipts)
  }

  /// Answers one admission by asking the authority, then relaying its decision.
  private func answer(
    _ admission: ArkForgeStepAdmissionSnapshot, jobID: String
  ) async throws {
    switch await authority.admit(admission) {
    case .sign(let permit):
      _ = try daemon.submitStepPermit(
        ArkForgeSubmitStepPermitRequest(
          jobID: jobID, requestID: admission.requestID, permitCBOR: permit.signingBody,
          integrityTag: permit.integrityTag, pairingEpoch: permit.pairingEpoch.value),
        requestID: "permit-\(admission.requestID)")
    case .refuse(let why):
      // Reported, not withheld. Silence lets the snapshot expire and admission
      // run again; a refusal goes to `CancelledSafe` (design §3.3).
      refusals.append("\(admission.stepID): \(why)")
      _ = try daemon.submitStepPermit(
        ArkForgeSubmitStepPermitRequest(
          jobID: jobID, requestID: admission.requestID, refusal: "\(why)"),
        requestID: "refusal-\(admission.requestID)")
    }
  }

  /// Performs a control action and relays what was observed.
  private func answer(
    _ request: ArkForgeManagedControlRequest, jobID: String
  ) async throws {
    let observation: ArkForgeManagedControlPort.Observation
    do {
      observation = try await performer.perform(request)
    } catch {
      // Failing to perform is not "nothing happened": the action may have taken
      // effect before the failure. Reported as unaccepted with the reason,
      // which the daemon records as an unknown outcome rather than a failure.
      observation = .init(
        accepted: false, facts: [:], evidenceSHA256: [],
        failureReason: "control action did not complete: \(error)")
    }
    let receipt = try ArkForgeManagedControlPort.receipt(
      jobID: jobID, requestID: request.requestID, action: request.action,
      observation: observation)
    _ = try daemon.submitManagedControlReceipt(
      receipt, requestID: "control-\(request.requestID)")
  }

  /// Requests cancellation and maps the answer into the engine's vocabulary.
  ///
  /// This is design §6.3.1 made executable. The middle case is the one worth
  /// reading twice: a refused cancellation is **not** an unconfirmed teardown.
  package func cancel(jobID: String) async -> CancellationResolution {
    do {
      let answer = try daemon.cancelJob(jobID: jobID, requestID: "cancel-\(jobID)")
      return .safe(state: answer.cancellationState)
    } catch ArkForgeClientError.daemonRefused(_, _, let error) {
      if let error, error.code == "CANCEL_NOT_SAFE" {
        return .refusedWriteInProgress(code: error.code)
      }
      return .unconfirmed(reason: error.map { "\($0)" } ?? "the daemon refused the cancellation")
    } catch {
      return .unconfirmed(reason: "\(error)")
    }
  }
}

/// The real daemon client satisfies the session's surface.
///
/// Without this, the session's tests would prove something about a stub and
/// nothing about the hardware path. The conformance is empty because the
/// client already has these methods with these signatures — which is the
/// point: the protocol was extracted from the client rather than invented
/// beside it, so a drift between them is a compile error rather than a
/// surprise on the bench.
extension ArkForgeDaemonClient: ArkForgeFlashSession.Daemon {}
