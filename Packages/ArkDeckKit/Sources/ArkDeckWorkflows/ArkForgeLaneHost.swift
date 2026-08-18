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
/// The four calls that put a plan in the daemon's store.
///
/// A protocol so a scripted source can drive the lane in tests, and so the
/// session's `Daemon` surface stays the five calls a running job makes. The
/// real client satisfies both.
package protocol ArkForgePlanSource: Sendable {
  func importArtifact(contentsOf url: URL, expectedSHA256: String, requestID: String) throws
    -> ArkForgeImportArtifactResponse
  func inspectArtifact(artifactID: String, requestID: String) throws
    -> ArkForgeInspectArtifactResponse
  func discoverDevices(requestID: String) throws -> [ArkForgeDeviceObservation]
  func materializePlan(_ body: ArkForgeMaterializePlanRequest, requestID: String) throws
    -> ArkForgeMaterializePlanResponse
}

/// The real client is the plan source, for the same reason it is the daemon:
/// the protocol was extracted from it rather than invented beside it, so drift
/// is a compile error instead of a surprise on the bench.
extension ArkForgeDaemonClient: ArkForgePlanSource {}

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
    case deviceNotObserved(String)
    case planNotExecutable(availability: String, reason: String, unknowns: [String: String])

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
      case .deviceNotObserved(let detail):
        return "arkforged cannot materialize a plan for this job's device: \(detail)"
      case .planNotExecutable(let availability, let reason, let unknowns):
        // Every blocker, not just the first. They are what an operator acts
        // on, and a maturity gate reads very differently from a profile
        // violation.
        let listed =
          unknowns
          .sorted { $0.key < $1.key }
          .map { "\($0.key): \($0.value)" }
          .joined(separator: "; ")
        return
          "arkforged materialized an assessment rather than an executable plan "
          + "(\(availability)): \(reason). Blockers: \(listed.isEmpty ? "none stated" : listed). "
          + "Nothing was dispatched and the device was not touched"
      }
    }
  }

  private let connection: Connection
  private let makeClient: @Sendable (String) throws -> any ArkForgeFlashSession.Daemon
  /// The materialization half of the client surface.
  ///
  /// Separate from `makeClient` because the session's `Daemon` protocol is
  /// narrowed to the five calls a running job makes, and these four happen
  /// before a job exists. Widening `Daemon` would have made every scripted
  /// test daemon implement calls it never receives.
  private let makeMaterializer: @Sendable (String) throws -> any ArkForgePlanSource
  /// Built from the plan that was actually materialized, not from the job alone.
  ///
  /// The authority signs against the plan digest and the device it approved, and
  /// neither is knowable until `materializePlan` has answered — which is why
  /// these arrive here rather than at composition time.
  private let makeAuthority:
    @Sendable (String, String, [UInt8], ArkForgeLaneDeviceBinding) -> ArkForgeExecutionAuthority
  /// Built per call from the binding the engine passes, because a performer
  /// without a device is a performer that cannot say *whose* disconnect it saw.
  private let makePerformer:
    @Sendable (ArkForgeLaneDeviceBinding, String) -> any ArkForgeFlashSession.ControlPerformer
  /// jobID → the receipts that job's single ArkForge run published, by step id.
  private var receiptsByJob: [String: [String: ArkForgeActionReceiptSummary]] = [:]
  /// The terminal receipt of a job whose lane already ran — both the anchor
  /// for engine step names the daemon never uses, and the proof that a later
  /// lane-covered step of the same job must **never** re-run the lane.
  private var lastReceiptByJob: [String: ArkForgeActionReceiptSummary] = [:]

  package init(
    connection: Connection,
    makePerformer: @escaping @Sendable (ArkForgeLaneDeviceBinding, String)
      -> any ArkForgeFlashSession.ControlPerformer,
    makeClient: @escaping @Sendable (String) throws -> any ArkForgeFlashSession.Daemon,
    makeMaterializer: @escaping @Sendable (String) throws -> any ArkForgePlanSource,
    makeAuthority: @escaping @Sendable (String, String, [UInt8], ArkForgeLaneDeviceBinding)
      -> ArkForgeExecutionAuthority
  ) {
    self.connection = connection
    self.makePerformer = makePerformer
    self.makeClient = makeClient
    self.makeMaterializer = makeMaterializer
    self.makeAuthority = makeAuthority
  }

  /// Decodes a 64-character lowercase hex digest into its 32 raw bytes.
  ///
  /// Returns nil rather than a partial value: a digest that is not exactly 32
  /// bytes is not a digest, and padding or truncating one would produce a permit
  /// bound to something no daemon will recognise.
  package static func digestBytes(_ hex: String) -> [UInt8]? {
    guard hex.count == 64 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(32)
    var high: UInt8?
    for character in hex {
      guard let nibble = character.hexDigitValue, nibble >= 0, nibble <= 15 else { return nil }
      if let first = high {
        out.append(first << 4 | UInt8(nibble))
        high = nil
      } else {
        high = UInt8(nibble)
      }
    }
    return high == nil ? out : nil
  }

  /// Runs the ArkForge job on first use for this ArkDeck job, then serves each
  /// delegated step from what that run published.
  package func perform(
    stepID: String, jobID: String, artifact: ArkForgeLaneArtifact,
    binding: ArkForgeLaneDeviceBinding
  ) async throws -> ArkForgeActionReceiptSummary {
    if let cached = receiptsByJob[jobID]?[stepID] ?? lastReceiptByJob[jobID] {
      // The anchor fallback is load-bearing here, not a convenience: a second
      // lane-covered step of the same job (`verify-flash-readback` after
      // `flash-partitions`) misses the by-name cache — the daemon named its
      // steps `STEP-001`… — and falling through would materialize and run the
      // whole lane again, which is a second flash.
      return cached
    }
    // No cache yet: this is the first delegated step of this job, so it is the
    // one that materializes the plan and runs the ArkForge job.
    let client = try makeClient(connection.socketPath)
    let plan = try await materialize(artifact: artifact, binding: binding, jobID: jobID)
    // `arkforged` states the plan digest as hex here and sends it as raw bytes in
    // every admission, so it is decoded once, at the boundary between the two.
    guard let planDigest = Self.digestBytes(plan.planSHA256) else {
      throw LaneError.planNotExecutable(
        availability: "unusable",
        reason: "arkforged returned a plan digest that is not 32 hex-encoded bytes",
        unknowns: ["planSHA256": plan.planSHA256])
    }
    let session = ArkForgeFlashSession(
      daemon: client, authority: makeAuthority(jobID, plan.planID, planDigest, binding),
      performer: makePerformer(binding, jobID),
      controllerSessionID: connection.controllerSessionID)

    let outcome = try await session.run(
      planID: plan.planID, planSHA256: plan.planSHA256, executionPurpose: "flash")
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
      // Unknown, not failed — the difference decides everything downstream.
      // `.failed` records the capability use `.confirmed` with a `failed`
      // terminal, which reads as "device state known"; the recovery scanner
      // then finds no unresolved intent, no recovery epoch can classify, and
      // the generation loop treats the lineage as closed. Measured 2026-08-18:
      // a 2 GB write whose marker never arrived was relabelled `failed` here,
      // and every later destructive submit answered
      // `capability denied [denial:exhausted]`. An unknown outcome must reach
      // the engine as exactly that, so the job parks `waitingForRecovery` and
      // the complete-overwrite recovery lane can reopen the target.
      throw RuntimeDispatchFailure.outcomeUnknown(reason)
    }
    receiptsByJob[jobID] = Dictionary(
      published.map { ($0.stepID, $0) }, uniquingKeysWith: { first, _ in first })
    lastReceiptByJob[jobID] = published.last

    // The daemon names its own steps (`STEP-001`…) and this engine names its
    // own (`flash-partitions`, `verify-flash-readback`); the two never
    // coincide, so an exact lookup can only match a scripted daemon that
    // echoes this engine's names. For a lane-covered step the per-step receipt
    // is a journaling anchor, not the evidence itself — `publishedReceipts`
    // carries every receipt the daemon produced — and the anchor for a step
    // the daemon completed under its own names is the plan's terminal
    // receipt: the last checkpoint of the run that subsumed this step.
    // Measured 2026-08-18: the first plan that ever completed end to end
    // failed here, on the name.
    guard let receipt = receiptsByJob[jobID]?[stepID] ?? lastReceiptByJob[jobID] else {
      throw LaneError.noReceiptForStep(stepID)
    }
    return receipt
  }

  /// Puts this job's plan in the daemon's store and returns how the daemon
  /// addresses it.
  ///
  /// The order is the daemon's, not a preference: an artifact must be imported
  /// before it can be inspected, inspected before `materializePlan` will look
  /// at it (`ARTIFACT_NOT_INSPECTED`), and a device observation must exist
  /// before the provider can probe. Import is attempted only when inspection
  /// says the store does not have these bytes — the store is content-addressed
  /// so a re-import would be correct but would stream ~731 MB to learn what a
  /// digest already answered.
  private func materialize(
    artifact: ArkForgeLaneArtifact, binding: ArkForgeLaneDeviceBinding, jobID: String
  ) async throws -> ArkForgeExecutablePlan {
    let client = try makeMaterializer(connection.socketPath)

    if (try? client.inspectArtifact(artifactID: artifact.sha256, requestID: "inspect-\(jobID)"))
      == nil
    {
      _ = try client.importArtifact(
        contentsOf: artifact.fileURL, expectedSHA256: artifact.sha256,
        requestID: "import-\(jobID)")
      _ = try client.inspectArtifact(
        artifactID: artifact.sha256, requestID: "inspect-after-import-\(jobID)")
    }

    let observations = try client.discoverDevices(requestID: "discover-\(jobID)")
    let observation: ArkForgeDeviceObservation
    switch ArkForgeObservationSelection.select(
      observations: observations, usbTopology: binding.usbTopology)
    {
    case .success(let selected): observation = selected
    case .failure(let why): throw LaneError.deviceNotObserved("\(why)")
    }

    let answer = try client.materializePlan(
      ArkForgeMaterializePlanRequest(
        artifactID: artifact.sha256, profileID: artifact.profileID,
        observationID: observation.observationID),
      requestID: "materialize-\(jobID)")
    switch answer {
    case .plan(let plan):
      return plan
    case .assessment(let assessment):
      // Not a transport failure and not retryable. The daemon built the whole
      // plan and declined to make it executable, and the reasons are the only
      // actionable part — a maturity gate and a profile violation need
      // different people.
      throw LaneError.planNotExecutable(
        availability: assessment.availability, reason: assessment.unavailableReason,
        unknowns: assessment.unknowns)
    }
  }

  package func latestReceipt(jobID: String) -> ArkForgeActionReceiptSummary? {
    lastReceiptByJob[jobID]
  }

  /// Drops a finished job's receipts.
  package func forget(jobID: String) {
    receiptsByJob[jobID] = nil
    lastReceiptByJob[jobID] = nil
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
