import ArkDeckCore
import ArkForgeIPC
import Foundation

/// The lane the engine dispatches a delegated step through.
///
/// # Two step machines, one job
///
/// The engine walks its own step list and asks this lane for one step at a
/// time. `arkforged` does not work that way: it runs a job, and its plan
/// contains both delegated steps. Bridging them by starting a separate ArkForge
/// job per step would mean two `startExecution` calls, two admissions, and two
/// permits for what the device experiences as one write followed by its
/// readback — and a second job could be admitted after the first had already
/// touched the medium.
///
/// So the first delegated step runs the whole ArkForge job, and the receipts it
/// publishes are kept by step id. The second delegated step is served from
/// those. That keeps ArkDeck's step loop, its journal shape and its UI events
/// exactly as they were (AFA-REQ-004) while there is only ever one ArkForge job
/// underneath.
///
/// # What it refuses to invent
///
/// If the job produced no receipt for a step the engine asks about, this
/// reports that rather than synthesising one. A receipt is the evidence a write
/// happened; a manufactured one would make an unperformed step look confirmed,
/// which is the single worst thing this lane could do.
package actor ArkForgeLaneHost: RuntimeJobEngine.ArkForgeLane {

  /// How to reach a running daemon.
  ///
  /// Deliberately not "how to start one": the daemon's lifecycle belongs to
  /// whoever composed it, and a lane that could restart the process would be a
  /// lane that could quietly re-pair — and re-pairing rotates the epoch, which
  /// voids every unconsumed permit.
  package struct Connection: Sendable {
    package let socketPath: String
    package let controllerSessionID: String

    package init(socketPath: String, controllerSessionID: String) {
      self.socketPath = socketPath
      self.controllerSessionID = controllerSessionID
    }
  }

  package enum LaneError: Error, Equatable, CustomStringConvertible {
    case daemonNotReady(blockers: [String])
    case toolchainMismatch(String)
    case noReceiptForStep(String)

    package var description: String {
      switch self {
      case .daemonNotReady(let blockers):
        return
          "arkforged is not ready to execute: \(blockers.joined(separator: ", ")). Nothing was "
          + "dispatched — this is a standing fact about the daemon, not a fault of this job"
      case .toolchainMismatch(let detail):
        return detail
      case .noReceiptForStep(let stepID):
        return
          "arkforged published no receipt for \(stepID); this lane will not synthesise one, "
          + "because a receipt is the evidence a write happened"
      }
    }
  }

  private let connection: Connection
  private let makeClient: @Sendable (String) throws -> any ArkForgeFlashSession.Daemon
  private let makeAuthority: @Sendable (String, String) -> ArkForgeExecutionAuthority
  /// Built per call from the binding the engine passes, because a performer
  /// without a device is a performer that cannot say *whose* disconnect it saw.
  private let makePerformer:
    @Sendable (ArkForgeLaneDeviceBinding, String) -> any ArkForgeFlashSession.ControlPerformer
  /// jobID → the receipts that job's single ArkForge run published, by step id.
  private var receiptsByJob: [String: [String: ArkForgeActionReceiptSummary]] = [:]

  package init(
    connection: Connection,
    makePerformer: @escaping @Sendable (ArkForgeLaneDeviceBinding, String)
      -> any ArkForgeFlashSession.ControlPerformer,
    makeClient: @escaping @Sendable (String) throws -> any ArkForgeFlashSession.Daemon,
    makeAuthority: @escaping @Sendable (String, String) -> ArkForgeExecutionAuthority
  ) {
    self.connection = connection
    self.makePerformer = makePerformer
    self.makeClient = makeClient
    self.makeAuthority = makeAuthority
  }

  /// Runs the ArkForge job on first use for this ArkDeck job, then serves each
  /// delegated step from what that run published.
  package func perform(
    stepID: String, jobID: String, planID: String, planSHA256: String,
    binding: ArkForgeLaneDeviceBinding
  ) async throws -> ArkForgeActionReceiptSummary {
    if let cached = receiptsByJob[jobID]?[stepID] {
      return cached
    }
    // No cache yet: this is the first delegated step of this job, so it is the
    // one that runs the ArkForge job.
    let client = try makeClient(connection.socketPath)
    let session = ArkForgeFlashSession(
      daemon: client, authority: makeAuthority(jobID, planID),
      performer: makePerformer(binding, jobID),
      controllerSessionID: connection.controllerSessionID)

    let outcome = try await session.run(
      planID: planID, planSHA256: planSHA256, executionPurpose: "flash")
    let published: [ArkForgeActionReceiptSummary]
    switch outcome {
    case .completed(let receipts), .cancelledSafe(let receipts):
      published = receipts
    case .outcomeUnknown(let reason, let receipts):
      // Kept, not discarded. The steps that did complete have real receipts,
      // and the engine needs them to journal what is known before it records
      // that the rest is not.
      published = receipts
      receiptsByJob[jobID] = Dictionary(
        published.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
      throw RuntimeDispatchFailure.failed(reason)
    }
    receiptsByJob[jobID] = Dictionary(
      published.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })

    guard let receipt = receiptsByJob[jobID]?[stepID] else {
      throw LaneError.noReceiptForStep(stepID)
    }
    return receipt
  }

  /// Drops a finished job's receipts.
  package func forget(jobID: String) {
    receiptsByJob[jobID] = nil
  }

  /// Checks the daemon is ready and bound to the toolchain this authority
  /// publishes plans for, before any job is started.
  ///
  /// Both are standing facts, so learning them at composition time rather than
  /// mid-job is the difference between refusing to start and stopping with a
  /// capability already consumed.
  package static func verifyReadiness(_ ack: ArkForgeHelloAck) throws {
    guard ack.executionReady else {
      throw LaneError.daemonNotReady(blockers: ack.executionBlockers)
    }
    if let mismatch = ArkForgeToolchainPin.mismatchExplanation(
      reportedSHA256: ack.toolchainSHA256)
    {
      throw LaneError.toolchainMismatch(mismatch)
    }
  }
}
