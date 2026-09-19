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
