// Production campaign attempt admitter for the engine lane
// (CHG-2026-025 r16, TASK-AIN-019).
//
// This is not a second admission path. It is the same
// `RockchipProductionAdmissionPort` the in-process executor calls, invoked one
// step earlier so the reservation exists before the engine lane submits its
// job. Every gate — assertion validity, target and broker identity, allowed
// starting mode, campaign ledger correlation, orphaned global use, live
// materialized facts, pre-reserve freshness, ordinal budget, write-ahead
// reservation ordering — runs unchanged, in the same service.

import Foundation

package struct RockchipProductionEvolutionCampaignAttemptAdmitter:
  RockchipEvolutionCampaignAttemptAdmitting
{
  private let port: RockchipProductionAdmissionPort
  private let makeID: @Sendable (String) -> String

  /// Production composition has no caller-supplied dependency, clock, ledger
  /// root or authorization bytes, exactly like the in-process host's.
  public init() throws {
    try self.init(
      port: RockchipProductionExecutionComposition.makeAdmissionPort(
        settings: try RockchipProductExecutionSettings.load()))
  }

  init(
    port: RockchipProductionAdmissionPort,
    makeID: @escaping @Sendable (String) -> String = { prefix in
      "\(prefix)-\(UUID().uuidString.lowercased())"
    }
  ) {
    self.port = port
    self.makeID = makeID
  }

  package func admitAttempt(
    permit: RockchipEvolutionCampaignAttemptPermit,
    archiveURL: URL,
    targetLocationSelector: String
  ) async throws -> RockchipEvolutionCampaignAdmittedAttempt {
    let request = try RockchipFlashExecutionRequest(
      evolutionCampaignAttempt: permit, archiveURL: archiveURL,
      targetLocationSelector: targetLocationSelector)
    let sessionID = makeID("rockchip-session")
    let jobID = makeID("rockchip-job")
    let targetID = makeID("rockchip-target")
    let admission = try await port.admit(
      request: request, sessionID: sessionID, jobID: jobID, targetID: targetID)
    guard case .evolutionCampaign(let token) = admission.backing else {
      throw RockchipEvolutionCampaignError.admissionRejected("authorityKindDrift")
    }
    guard admission.plan.executionMode == .execute,
      admission.usbTopology == targetLocationSelector
    else {
      throw RockchipEvolutionCampaignError.admissionRejected("fact correlation drift")
    }
    // The partition set comes from the board and the archive identity comes
    // from the materialized plan — never from a caller field. That is what
    // this guard protects: the engine lane names the same partitions the
    // campaign was confirmed against, and the same bytes.
    //
    // It used to reach that by looking the plan's archive digest up among the
    // builds compiled into the product, which made it the eleventh and last
    // place a firmware daily published after the release was turned away —
    // found by running a real campaign, after ten earlier ones had been found
    // the same way.
    let profile = admission.archiveProfile
    guard
      let board = RockchipFlashProfile.board(reference: profile.catalogReference),
      profile.mappedPartitions == board.mappedPartitions,
      profile.archiveSHA256 == admission.plan.archiveSHA256,
      profile.archiveSizeBytes == admission.plan.archiveSizeBytes
    else {
      throw RockchipEvolutionCampaignError.admissionRejected(
        "admission profile does not correlate with the materialized DAYU200 plan")
    }
    return RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: token.campaignID,
      ordinal: token.ordinal,
      reservationID: admission.usageReservationID,
      jobID: token.jobID,
      sessionID: token.sessionID,
      targetStableIdentitySHA256: admission.serialDigestSHA256,
      bindingRevision: admission.bindingRevision,
      deviceProfileReference: board.catalogReference,
      partitionPlan: board.mappedPartitions.map(\.partitionName),
      archiveSizeBytes: admission.plan.archiveSizeBytes,
      // The confirmed plan's archive, not a constant: this is the digest the
      // operator confirmed, and the engine re-checks it against the leased
      // bytes before the first write.
      archiveSHA256: admission.plan.archiveSHA256,
      archiveProfile: profile,
      postFlashVerification: admission.plan.postFlashVerification.rawValue)
  }
}
