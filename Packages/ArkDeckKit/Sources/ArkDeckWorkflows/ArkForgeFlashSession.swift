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

  /// A daemon answer this session must not paper over.
  ///
  /// Both of these used to be discarded — the submit calls return a
  /// `SubmissionOutcome`, the daemon says *accepted or rejected* inside an OK
  /// response, and this session read neither. A rejected control receipt
  /// therefore vanished: the daemon kept waiting for a receipt, this side kept
  /// polling for events, and the operator watched a job that was neither
  /// failing nor progressing. An answer the daemon rejected is now a named
  /// stop, carrying the daemon's own code.
  package enum SessionError: Error, Equatable, CustomStringConvertible {
    case permitRejected(stepID: String, code: String, message: String)
    case controlReceiptRejected(requestID: String, code: String, message: String)

    package var description: String {
      switch self {
      case .permitRejected(let stepID, let code, let message):
        return "arkforged rejected the permit for \(stepID): \(code) \(message)"
      case .controlReceiptRejected(let requestID, let code, let message):
        return
          "arkforged rejected the control receipt for \(requestID): \(code) \(message). "
          + "The job was cancelled rather than left waiting for a receipt it refuses"
      }
    }
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
    // The daemon names the job, and every admission it sends will carry that
    // name. Taken here, from the reply, rather than assumed from ArkDeck's own
    // job ID — which belongs to a different namespace and matched nothing.
    await authority.adoptDaemonJob(started.jobID)

    var terminal: Outcome?
    // The journal sequence already answered. `events_from` is exclusive, so
    // this is the last sequence seen rather than one past it.
    var cursor: UInt64 = 0
    var quietPolls = 0
    /// Steps whose permit this session signed and whose receipt has not arrived
    /// yet. This is the only reason to keep asking once the daemon goes quiet:
    /// a signed permit is a write that owes evidence.
    var awaitingReceipts: Set<String> = []

    // `watchJob` is one poll, not a subscription: `arkforged` replies with the
    // events queued at that instant and ends the stream. Every event this
    // session cares about is *caused* by an answer it sends — the permit is
    // what causes the write, and the write is what causes the receipt — so a
    // single poll can only ever observe the requests, never the answers to
    // them. Polling once and answering afterwards therefore ends with the
    // admission granted and nobody left to collect what it produced, which is
    // exactly "arkforged published no receipt for flash-partitions". The loop
    // this type's comment describes has to be a real loop.
    while terminal == nil {
      var admissions: [ArkForgeStepAdmissionSnapshot] = []
      var controls: [ArkForgeManagedControlRequest] = []
      var sawEvent = false

      try daemon.watchJob(
        ArkForgeWatchJobRequest(jobID: started.jobID, fromSequence: cursor),
        requestID: "watch-\(started.jobID)-\(cursor)"
      ) { event in
        // The cursor is exclusive, so anything at or below it was answered on an
        // earlier poll. Guarding here is what keeps a re-poll from counting the
        // same receipt twice.
        guard event.sequence > cursor else { return terminal == nil }
        sawEvent = true
        cursor = event.sequence
        switch event.kind {
        case .stepAdmissionRequested:
          if let admission = event.admission { admissions.append(admission) }
        case .managedControlRequested:
          if let request = event.controlRequest { controls.append(request) }
        case .actionReceipt:
          if let receipt = event.receipt {
            self.receipts.append(receipt)
            awaitingReceipts.remove(receipt.stepID)
          }
        case .outcomeClassified:
          // The daemon's own classification is authoritative for the job's end.
          // It keys that fact `outcome`, not `disposition`; reading the wrong
          // key meant this never saw a terminal answer at all.
          switch event.facts.first(where: { $0.key == "outcome" })?.value ?? "" {
          case "outcomeUnknown", "recoveryAssessable":
            // The daemon publishes why beside the classification. Without it
            // the operator gets "unknown" while the one line naming the cause
            // sits in a CBOR journal on the other side of the boundary.
            let why = event.facts.first(where: { $0.key == "reason" })?.value
            terminal = .outcomeUnknown(
              reason: why.map { "the daemon classified this job's outcome as unknown: \($0)" }
                ?? "the daemon classified this job's outcome as unknown",
              receipts: self.receipts)
          case "cancelledSafe":
            terminal = .cancelledSafe(receipts: self.receipts)
          default:
            terminal = .completed(receipts: self.receipts)
          }
        default:
          break
        }
        // The handler must not block on device work: the daemon polls this
        // stream, and a handler waiting on a 15-second rebind would hold it.
        // Requests are collected and answered between polls.
        return terminal == nil
      }

      for admission in admissions {
        // A signed permit is what makes a receipt due. If one already arrived in
        // the same poll as the admission, nothing is owed.
        if try await answer(admission, jobID: started.jobID),
          !receipts.contains(where: { $0.stepID == admission.stepID })
        {
          awaitingReceipts.insert(admission.stepID)
        }
      }
      for control in controls {
        try await answer(control, jobID: started.jobID)
      }

      if terminal != nil { break }
      if sawEvent {
        quietPolls = 0
      } else if awaitingReceipts.isEmpty {
        // Nothing new, nothing to answer, and no permit still owing evidence:
        // the daemon has said everything it has to say.
        return .completed(receipts: receipts)
      } else {
        // A signed permit is outstanding, so the daemon is mid-write and a
        // partition write is minutes of exactly this silence. Back off instead
        // of spinning, and outlast the operation's own timeout rather than
        // calling a still-running write missing.
        quietPolls += 1
        if quietPolls > Self.quietPollLimit {
          return .outcomeUnknown(
            reason: "arkforged produced no further events for "
              + "\(Self.quietPollLimit * Int(Self.pollIntervalMilliseconds) / 1000)s",
            receipts: receipts)
        }
        try await Task.sleep(nanoseconds: Self.pollIntervalMilliseconds * 1_000_000)
      }
    }

    return terminal ?? .completed(receipts: receipts)
  }

  /// How long to wait before polling again when the daemon has nothing queued.
  private static let pollIntervalMilliseconds: UInt64 = 500

  /// How many consecutive quiet polls before the outcome is unknown. The
  /// catalog gives `flash.dayu200` 1800 seconds, so this outlasts the operation
  /// instead of deciding a still-running write has gone missing.
  private static let quietPollLimit = 4200

  /// Answers one admission by asking the authority, then relaying its decision.
  ///
  /// Returns whether a permit was signed, because that — and only that — is what
  /// leaves a receipt outstanding.
  @discardableResult
  private func answer(
    _ admission: ArkForgeStepAdmissionSnapshot, jobID: String
  ) async throws -> Bool {
    switch await authority.admit(admission) {
    case .sign(let permit):
      let response = try daemon.submitStepPermit(
        ArkForgeSubmitStepPermitRequest(
          jobID: jobID, requestID: admission.requestID, permitCBOR: permit.signingBody,
          integrityTag: permit.integrityTag, pairingEpoch: permit.pairingEpoch.value),
        requestID: "permit-\(admission.requestID)")
      guard response.accepted else {
        // The daemon said no inside an OK response, and this used to be
        // discarded — which is how three refusal codes in a row (unknownJob,
        // planMismatch, snapshotExpired) each cost a bench session to see.
        refusals.append(
          "\(admission.stepID): permit rejected: "
            + "\(response.rejectionCode) \(response.rejectionMessage)")
        if response.rejectionCode == "SNAPSHOT_EXPIRED" {
          // The one rejection that heals itself: the snapshot expires, the
          // admission runs again, the next snapshot is fresher. No permit is
          // outstanding, so nothing is owed a receipt.
          return false
        }
        throw SessionError.permitRejected(
          stepID: admission.stepID, code: response.rejectionCode,
          message: response.rejectionMessage)
      }
      return true
    case .refuse(let why):
      // Reported, not withheld. Silence lets the snapshot expire and admission
      // run again; a refusal goes to `CancelledSafe` (design §3.3).
      refusals.append("\(admission.stepID): \(why)")
      _ = try daemon.submitStepPermit(
        ArkForgeSubmitStepPermitRequest(
          jobID: jobID, requestID: admission.requestID, refusal: "\(why)"),
        requestID: "refusal-\(admission.requestID)")
      return false
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
    let response = try daemon.submitManagedControlReceipt(
      receipt, requestID: "control-\(request.requestID)")
    guard response.accepted else {
      // A rejected receipt leaves the daemon still waiting on the request.
      // Discarding the rejection — which is what happened here — left both
      // sides waiting on the other with nothing recorded anywhere. Cancel so
      // the daemon's job settles rather than parks, then stop with the
      // daemon's own code. (The daemon also enforces the request deadline now,
      // so even a session that dies right here strands nothing for long.)
      _ = try? daemon.cancelJob(jobID: jobID, requestID: "cancel-\(request.requestID)")
      throw SessionError.controlReceiptRejected(
        requestID: request.requestID, code: response.rejectionCode,
        message: response.rejectionMessage)
    }
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
