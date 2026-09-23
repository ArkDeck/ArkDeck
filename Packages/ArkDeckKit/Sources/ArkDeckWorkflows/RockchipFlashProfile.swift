import ArkDeckCore
import Foundation

// Provider error adaptation stays at the execution boundary. Core owns the
// one bounded, read-only archive implementation; its results grant no admission.
extension RockchipFlashProfile {
  package func forBuild(_ build: RockchipImageBuildDescriptor) throws -> RockchipFlashProfile {
    do { return try withArchiveBuild(build) }
    catch RockchipFlashProfileError.archiveDoesNotConform(let reason) {
      throw DeviceProviderError.unsupportedAction(reason)
    }
  }

  package func forArchive(at url: URL) throws -> RockchipFlashProfile {
    do { return try reviewingArchive(at: url) }
    catch RockchipFlashProfileError.archiveDoesNotConform(let reason) {
      throw DeviceProviderError.unsupportedAction(reason)
    }
  }
}
