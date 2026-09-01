import Foundation

/// Diagnostic identity lookup only. A matching file is still subject to each
/// Provider's own operation/profile/target admission and dispatch checks.
/// Registration never creates a new semantic or hardware support declaration.
package enum HDCRegisteredToolIdentity {
  package struct Match: Equatable {
    package let version: String
    package let profileReferences: [String]
  }

  package static func match(sha256: String) -> Match? {
    if sha256 == HDCReadOnlyProbeRegistry.targetExecutableSHA256 {
      return Match(version: HDCReadOnlyProbeRegistry.targetToolVersion,
        profileReferences: [HDCReadOnlyProbeRegistry.integrationProfile])
    }
    if sha256 == HDCDeviceObservationProbeCatalog.targetExecutableSHA256,
      sha256 == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256,
      HDCDeviceObservationProbeCatalog.targetToolVersion == HDCSupervisorObservationProbeCatalog.targetToolVersion {
      return Match(version: HDCSupervisorObservationProbeCatalog.targetToolVersion,
        profileReferences: Array(Set([HDCDeviceObservationProbeCatalog.integrationProfile,
          HDCSupervisorObservationProbeCatalog.integrationProfile])).sorted())
    }
    return nil
  }
}
