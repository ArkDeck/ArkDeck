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

public struct RockchipProductionEvolutionCampaignAttemptAdmitter:
  RockchipEvolutionCampaignAttemptAdmitting
{
  private let port: RockchipProductionAdmissionPort
  private let profiles: [RockchipFlashProfile]
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
    profiles: [RockchipFlashProfile] = RockchipFlashProfile.supportedDAYU200Profiles,
    makeID: @escaping @Sendable (String) -> String = { prefix in
      "\(prefix)-\(UUID().uuidString.lowercased())"
    }
  ) {
    self.port = port
    self.profiles = profiles
    self.makeID = makeID
  }

  public func admitAttempt(
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
    // The profile is selected by the materialized plan's exact archive
    // identity, never by a caller field — the same selection the in-process
    // executor makes, so the engine lane names the same partition set the
    // campaign was confirmed against.
    guard
      let profile = profiles.first(where: {
        $0.archiveSHA256 == admission.plan.archiveSHA256
          && $0.archiveSizeBytes == admission.plan.archiveSizeBytes
      })
    else {
      throw RockchipEvolutionCampaignError.admissionRejected(
        "execute plan has no exact published profile")
    }
    return RockchipEvolutionCampaignAdmittedAttempt(
      campaignID: token.campaignID,
      ordinal: token.ordinal,
      reservationID: admission.usageReservationID,
      jobID: token.jobID,
      sessionID: token.sessionID,
      targetStableIdentitySHA256: admission.serialDigestSHA256,
      bindingRevision: admission.bindingRevision,
      deviceProfileReference: profile.catalogReference,
      partitionPlan: profile.mappedPartitions.map(\.partitionName),
      archiveSHA256: profile.archiveSHA256,
      postFlashVerification: admission.plan.postFlashVerification.rawValue)
  }
}
