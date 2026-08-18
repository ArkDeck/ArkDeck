import Foundation

/// Immutable plan facts derived from the selected archive. Device/tool facts
/// are owned by the Runtime and ArkForge; this port never probes USB or starts
/// a RockUSB implementation.
package struct RockchipValidatedExecutePlanFacts: Sendable, Equatable {
  package let plan: RockchipFlashPlan
  package let archiveProfile: RockchipFlashProfile
}

protocol RockchipExecutePlanFactPort: Sendable {
  func makeValidatedExecutePlan(archiveURL: URL) async throws -> RockchipValidatedExecutePlanFacts
}

package struct RockchipProductExecutePlanFactPort: RockchipExecutePlanFactPort {
  package init() {}

  package func makeValidatedExecutePlan(
    archiveURL: URL
  ) async throws -> RockchipValidatedExecutePlanFacts {
    let board = RockchipFlashProfile.dayu200
    let summary = try GzipTarArchiveReader.summarize(
      fileAt: archiveURL,
      derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
    return try makeValidatedExecutePlanFacts(summary: summary, board: board)
  }

  func makeValidatedExecutePlan(
    summary: GzipTarArchiveSummary,
    board: RockchipFlashProfile = .dayu200
  ) throws -> RockchipFlashPlan {
    try makeValidatedExecutePlanFacts(summary: summary, board: board).plan
  }

  func makeValidatedExecutePlanFacts(
    summary: GzipTarArchiveSummary,
    board: RockchipFlashProfile
  ) throws -> RockchipValidatedExecutePlanFacts {
    let profile: RockchipFlashProfile
    do {
      profile = try board.forBuild(
        RockchipImageArchiveIntrospection.describe(summary: summary, board: board))
    } catch {
      throw RockchipAuthorizationFactError.archiveValidationFailed
    }
    let provider = RockchipRockUSBFlashProvider(profile: profile)
    let verdict = provider.profile.validate(summary.archiveObservation())
    guard verdict == .valid else { throw RockchipAuthorizationFactError.archiveValidationFailed }
    return RockchipValidatedExecutePlanFacts(
      plan: try provider.makePlan(mode: .execute, archiveValidation: verdict),
      archiveProfile: profile)
  }
}

enum RockchipAuthorizationFactError: Error, Sendable, Equatable {
  case archiveValidationFailed
}
