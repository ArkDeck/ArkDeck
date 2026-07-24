import ArkDeckRuntime

public enum AutoUpdateLogEvent: Equatable, Sendable {
  case checkStarted
  case available
  case noUpdate
  case downloadStarted
  case verificationStarted
  case failed
  case cancelled
  case handedOff
}

public protocol AutoUpdateEventLogging: Sendable {
  func record(_ event: AutoUpdateLogEvent)
}

public struct NoOpAutoUpdateEventLogger: AutoUpdateEventLogging, Sendable {
  public init() {}
  public func record(_ event: AutoUpdateLogEvent) {}
}

/// Maps updater state to the existing bounded, redacted SystemLogger. No version, URL, path,
/// request field, Team identifier, or error text enters diagnostics.
public struct SystemAutoUpdateEventLogger: AutoUpdateEventLogging, Sendable {
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
