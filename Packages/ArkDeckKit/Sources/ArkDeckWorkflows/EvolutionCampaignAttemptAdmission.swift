// The campaign attempt admission seam (CHG-2026-025 r16, TASK-AIN-019).
//
// #992 gave the engine a campaign authority: a request may carry an already
// open usage-ledger reservation, and the engine re-verifies its embedded pins,
// re-proves the subject before the first mutation and closes it with the job's
// terminal. The engine deliberately never reserves — the nine-gate campaign
// admission service is the sole minting point.
//
// That leaves one question for the engine lane: who calls the minting point?
// In the in-process lane the executor admits inside its own execute, so the
// reservation is born after dispatch has already begun. The engine lane needs
// the reservation *before* it submits. This file is the seam that lets the
// campaign host run the same nine gates in the same service, one call earlier.

import Foundation

/// What one nine-gate admission produced: the open reservation that authorizes
/// exactly this attempt, plus the pins the engine lane needs to name the same
/// archive and the same partition set the campaign was confirmed against.
package struct RockchipEvolutionCampaignAdmittedAttempt: Sendable, Equatable {
  package let campaignID: String
  package let ordinal: Int
  package let reservationID: String
  public let jobID: String
  public let sessionID: String
  package let targetStableIdentitySHA256: String
  public let bindingRevision: Int
  /// Published profile reference (`dayu200`) selected by the
  /// materialized plan's exact archive identity, never by a caller field.
  package let deviceProfileReference: String
  package let partitionPlan: [String]
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  /// Exact archive-derived profile materialized by this attempt's admission.
  /// This is an invocation-local handoff, not caller authority; upload and
  /// daemon import still revalidate the archive bytes before dispatch.
  package let archiveProfile: RockchipFlashProfile
  /// The confirmed plan's own verification level, carried rather than
  /// re-chosen: the engine lane must ask for exactly the post-flash checks
  /// the campaign was confirmed against.
  package let postFlashVerification: String

  public init(
    campaignID: String,
    ordinal: Int,
    reservationID: String,
    jobID: String,
    sessionID: String,
    targetStableIdentitySHA256: String,
    bindingRevision: Int,
    deviceProfileReference: String,
    partitionPlan: [String],
    archiveSizeBytes: Int64,
    archiveSHA256: String,
    archiveProfile: RockchipFlashProfile,
    postFlashVerification: String
  ) {
    self.campaignID = campaignID
    self.ordinal = ordinal
    self.reservationID = reservationID
    self.jobID = jobID
    self.sessionID = sessionID
    self.targetStableIdentitySHA256 = targetStableIdentitySHA256
    self.bindingRevision = bindingRevision
    self.deviceProfileReference = deviceProfileReference
    self.partitionPlan = partitionPlan
    self.archiveSizeBytes = archiveSizeBytes
    self.archiveSHA256 = archiveSHA256
    self.archiveProfile = archiveProfile
    self.postFlashVerification = postFlashVerification
  }
}

/// Runs the nine gates and mints the attempt's reservation.
///
/// A dispatcher that admits internally (the in-process lane) has no use for
/// this and supplies none; a dispatcher whose executor cannot reserve (the
/// engine lane, by #992's design) supplies one, and the campaign host calls it
/// immediately before dispatch.
package protocol RockchipEvolutionCampaignAttemptAdmitting: Sendable {
  func admitAttempt(
    permit: RockchipEvolutionCampaignAttemptPermit,
    archiveURL: URL,
    targetLocationSelector: String
  ) async throws -> RockchipEvolutionCampaignAdmittedAttempt
}
