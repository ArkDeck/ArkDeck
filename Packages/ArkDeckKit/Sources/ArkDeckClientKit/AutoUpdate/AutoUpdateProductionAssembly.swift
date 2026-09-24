import Foundation

// The updater's production assembly, shared by the App and the Swift CLI. Its
// events go to the App's own bounded, redacted diagnostics (`SystemLogger`,
// PORT-LOGGING-001), which live in this module (docs/ArchitectureRules.md).

extension AutoUpdateApplicationFacade {
  public static func make() throws -> RuntimeUpdateApplicationFacade {
    let artifactStore = try UpdateArtifactStore.production()
    let replayStore = try FileUpdateReplayStore.production()
    let stateStore = try RuntimeUpdateStateStore.production()
    let trust = try UpdateFeedTrust.production
    let preferences = UserDefaultsAutoUpdatePreferences()
    let eventLogger: any AutoUpdateEventLogging
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      let logger = SystemLogger(
        structuredStore: try StructuredDiagnosticLogStore(
          directory: support.appending(
            path: "ArkDeck/Diagnostics", directoryHint: .isDirectory)))
      eventLogger = SystemAutoUpdateEventLogger(logger: logger)
    } catch {
      eventLogger = NoOpAutoUpdateEventLogger()
    }
    return try RuntimeUpdateApplicationFacade(
      streamer: URLSessionUpdateHTTPStreamer(),
      verifier: UpdateFeedVerifier(
        trust: trust, replayStore: replayStore),
      artifactStore: artifactStore,
      artifactValidator: SystemUpdateArtifactValidator(),
      preferences: preferences,
      stateStore: stateStore,
      eventLogger: eventLogger)
  }
}

/// Maps updater state to the existing bounded, redacted SystemLogger. No version, URL, path,
/// request field, Team identifier, or error text enters diagnostics.
package struct SystemAutoUpdateEventLogger: AutoUpdateEventLogging, Sendable {
  private let logger: SystemLogger
  private let correlationID: DiagnosticCorrelationID

  public init(logger: SystemLogger, correlationID: DiagnosticCorrelationID = .init()) {
    self.logger = logger
    self.correlationID = correlationID
  }

  public func record(_ event: AutoUpdateLogEvent) {
    let mapped: (SystemLogLevel, SystemLogEventName, DiagnosticPublicCode) =
      switch event {
      case .checkStarted:
        (.info, .updateCheck, .updateStarted)
      case .available:
        (.notice, .updateCheck, .updateAvailable)
      case .noUpdate:
        (.info, .updateCheck, .updateNoUpdate)
      case .downloadStarted:
        (.notice, .updateDownload, .updateStarted)
      case .verificationStarted:
        (.notice, .updateVerification, .updateStarted)
      case .failed:
        (.error, .updateVerification, .updateFailed)
      case .cancelled:
        (.notice, .updateDownload, .updateCancelled)
      case .handedOff:
        (.notice, .updateHandoff, .updateHandoff)
      }
    try? logger.log(
      level: mapped.0, category: .workflow, eventName: mapped.1,
      correlationID: correlationID, fields: [.publicCode: .publicCode(mapped.2)])
  }
}
