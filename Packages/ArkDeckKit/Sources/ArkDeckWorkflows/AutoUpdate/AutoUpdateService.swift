import ArkDeckRuntime
import Foundation

public enum AutoUpdateFailureCode: String, Equatable, Sendable {
  case network
  case feed
  case download
  case artifact
  case handoff
}

public enum AutoUpdateServiceError: Error, Equatable, Sendable {
  case invalidTransition
  case automaticChecksDisabled
  case automaticCheckNotDue
  case explicitConsentRequired
  case artifactChangedAfterVerification
}

public enum AutoUpdateState: Equatable, Sendable {
  case idle
  case checking
  case available(VerifiedUpdateFeed)
  case noUpdate(UpdateNoUpdateReason)
  case downloading(VerifiedUpdateFeed)
  case verifying(DownloadedUpdateArtifact)
  case awaitingConsent(feed: VerifiedUpdateFeed, artifact: ValidatedUpdateArtifact)
  case handedOff(URL)
  case failed(AutoUpdateFailureCode)
  case cancelled
}

public protocol AutoUpdatePreferenceStoring: Sendable {
  func automaticChecksEnabled() -> Bool
  func setAutomaticChecksEnabled(_ enabled: Bool)
  func lastCheckAttempt() -> Date?
  func recordCheckAttempt(_ date: Date)
}

public final class UserDefaultsAutoUpdatePreferences: AutoUpdatePreferenceStoring,
  @unchecked Sendable
{
  public static let enabledKey = "ArkDeck.AutoUpdate.AutomaticChecksEnabled"
  public static let lastAttemptKey = "ArkDeck.AutoUpdate.LastCheckAttempt"

  private let defaults: UserDefaults
  private let lock = NSLock()

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    lock.withLock {
      if defaults.object(forKey: Self.enabledKey) == nil {
        defaults.set(true, forKey: Self.enabledKey)
      }
    }
  }

  public func automaticChecksEnabled() -> Bool {
    lock.withLock { defaults.bool(forKey: Self.enabledKey) }
  }

  public func setAutomaticChecksEnabled(_ enabled: Bool) {
    lock.withLock { defaults.set(enabled, forKey: Self.enabledKey) }
  }

  public func lastCheckAttempt() -> Date? {
    lock.withLock { defaults.object(forKey: Self.lastAttemptKey) as? Date }
  }

  public func recordCheckAttempt(_ date: Date) {
    lock.withLock { defaults.set(date, forKey: Self.lastAttemptKey) }
  }
}

public actor AutoUpdateService {
  public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

  private let streamer: any UpdateHTTPStreaming
  private let verifier: UpdateFeedVerifier
  private let artifactStore: UpdateArtifactStore
  private let artifactValidator: any UpdateArtifactValidating
  private let preferences: any AutoUpdatePreferenceStoring
  private let eventLogger: any AutoUpdateEventLogging
  private var internalState: AutoUpdateState = .idle
  private var activeOperationID: UUID?
  private var activeDownloadTask: Task<DownloadedUpdateArtifact, any Error>?

  public init(
    streamer: any UpdateHTTPStreaming,
    verifier: UpdateFeedVerifier,
    artifactStore: UpdateArtifactStore,
    artifactValidator: any UpdateArtifactValidating,
    preferences: any AutoUpdatePreferenceStoring,
    eventLogger: any AutoUpdateEventLogging = NoOpAutoUpdateEventLogger()
  ) {
    self.streamer = streamer
    self.verifier = verifier
    self.artifactStore = artifactStore
    self.artifactValidator = artifactValidator
    self.preferences = preferences
    self.eventLogger = eventLogger
  }

  public var state: AutoUpdateState { internalState }

  public var automaticChecksEnabled: Bool {
    preferences.automaticChecksEnabled()
  }

  public func setAutomaticChecksEnabled(_ enabled: Bool) {
    preferences.setAutomaticChecksEnabled(enabled)
  }

  public func recoverOrphanPartials() throws {
    do {
      try artifactStore.removeOrphanPartials()
    } catch {
      internalState = .failed(.download)
      eventLogger.record(.failed)
      throw error
    }
  }

  @discardableResult
  public func checkAutomaticallyIfDue(
    identity: UpdateProductIdentity,
    now: Date = Date()
  ) async throws -> AutoUpdateState {
    guard preferences.automaticChecksEnabled() else {
      throw AutoUpdateServiceError.automaticChecksDisabled
    }
    if let lastAttempt = preferences.lastCheckAttempt(),
      now.timeIntervalSince(lastAttempt) < Self.automaticCheckInterval
    {
      throw AutoUpdateServiceError.automaticCheckNotDue
    }
    return try await check(identity: identity, now: now)
  }

  @discardableResult
  public func checkManually(
    identity: UpdateProductIdentity,
    now: Date = Date()
  ) async throws -> AutoUpdateState {
    try await check(identity: identity, now: now)
  }

  @discardableResult
  public func downloadAvailableUpdate() async throws -> AutoUpdateState {
    guard case .available(let feed) = internalState else {
      throw AutoUpdateServiceError.invalidTransition
    }
    internalState = .downloading(feed)
    eventLogger.record(.downloadStarted)
    let operationID = UUID()
    activeOperationID = operationID
    var downloaded: DownloadedUpdateArtifact?
    do {
      let request = try UpdateRequestFactory.artifactRequest(signedURL: feed.payload.artifact.url)
      let stream = streamer.stream(
        for: request, maximumBytes: feed.payload.artifact.byteLength)
      let artifactStore = self.artifactStore
      let downloadTask = Task {
        try await artifactStore.writeVerified(
          stream: stream,
          expectedLength: feed.payload.artifact.byteLength,
          expectedSHA256: feed.payload.artifact.sha256)
      }
      activeDownloadTask = downloadTask
      let materialized = try await downloadTask.value
      downloaded = materialized
      guard activeOperationID == operationID else {
        artifactStore.remove(materialized)
        throw UpdateDownloadError.cancelled
      }
      activeDownloadTask = nil
      internalState = .verifying(materialized)
      eventLogger.record(.verificationStarted)
      let validated = try artifactValidator.validate(materialized)
      guard activeOperationID == operationID else {
        artifactStore.remove(materialized)
        throw UpdateDownloadError.cancelled
      }
      activeOperationID = nil
      internalState = .awaitingConsent(feed: feed, artifact: validated)
      return internalState
    } catch is CancellationError {
      if let downloaded { artifactStore.remove(downloaded) }
      transitionIfCurrent(operationID, to: .cancelled, event: .cancelled)
      throw UpdateDownloadError.cancelled
    } catch let error as UpdateDownloadError where error == .cancelled {
      if let downloaded { artifactStore.remove(downloaded) }
      transitionIfCurrent(operationID, to: .cancelled, event: .cancelled)
      throw error
    } catch {
      if let downloaded { artifactStore.remove(downloaded) }
      transitionIfCurrent(
        operationID,
        to: .failed(failureCode(for: error, default: .download)),
        event: .failed)
      throw error
    }
  }

  @discardableResult
  public func handoff(
    explicitConsent: Bool,
    revealer: any UpdateArtifactRevealing
  ) async throws -> AutoUpdateState {
    guard explicitConsent else { throw AutoUpdateServiceError.explicitConsentRequired }
    guard case .awaitingConsent(_, let approved) = internalState else {
      throw AutoUpdateServiceError.invalidTransition
    }
    do {
      let revalidated = try artifactValidator.validate(approved.downloaded)
      guard revalidated == approved else {
        throw AutoUpdateServiceError.artifactChangedAfterVerification
      }
      guard
        try UpdateArtifactStore.identity(at: revalidated.downloaded.url)
          == revalidated.downloaded.identity
      else {
        throw AutoUpdateServiceError.artifactChangedAfterVerification
      }
      try await revealer.revealInFinder(revalidated.downloaded.url)
      internalState = .handedOff(revalidated.downloaded.url)
      eventLogger.record(.handedOff)
      return internalState
    } catch {
      artifactStore.remove(approved.downloaded)
      internalState = .failed(.handoff)
      eventLogger.record(.failed)
      throw error
    }
  }

  public func cancel() {
    switch internalState {
    case .checking, .downloading, .verifying:
      activeDownloadTask?.cancel()
      activeDownloadTask = nil
      activeOperationID = nil
      internalState = .cancelled
      eventLogger.record(.cancelled)
    default:
      break
    }
  }

  private func check(
    identity: UpdateProductIdentity,
    now: Date
  ) async throws -> AutoUpdateState {
    switch internalState {
    case .checking, .downloading, .verifying, .awaitingConsent, .handedOff:
      throw AutoUpdateServiceError.invalidTransition
    case .idle, .available, .noUpdate, .failed, .cancelled:
      break
    }
    preferences.recordCheckAttempt(now)
    internalState = .checking
    eventLogger.record(.checkStarted)
    let operationID = UUID()
    activeOperationID = operationID
    do {
      let request = try UpdateRequestFactory.feedRequest(identity: identity)
      let stream = streamer.stream(
        for: request, maximumBytes: UInt64(UpdateFeedCodec.maximumFeedBytes))
      var feedData = Data()
      for try await chunk in stream {
        if Task.isCancelled || activeOperationID != operationID {
          throw CancellationError()
        }
        guard chunk.count <= UpdateFeedCodec.maximumFeedBytes - feedData.count else {
          throw UpdateFeedError.feedTooLarge
        }
        feedData.append(chunk)
      }
      let result = try verifier.verify(
        feedData,
        context: UpdateVerificationContext(
          installedVersion: identity.appVersion,
          systemVersion: identity.osVersion,
          architecture: identity.architecture),
        now: now)
      guard activeOperationID == operationID else { throw CancellationError() }
      activeOperationID = nil
      switch result {
      case .update(let verified):
        internalState = .available(verified)
        eventLogger.record(.available)
      case .noUpdate(let reason):
        internalState = .noUpdate(reason)
        eventLogger.record(.noUpdate)
      }
      return internalState
    } catch is CancellationError {
      transitionIfCurrent(operationID, to: .cancelled, event: .cancelled)
      throw UpdateDownloadError.cancelled
    } catch {
      transitionIfCurrent(
        operationID, to: .failed(failureCode(for: error, default: .feed)), event: .failed)
      throw error
    }
  }

  private func transitionIfCurrent(
    _ operationID: UUID,
    to state: AutoUpdateState,
    event: AutoUpdateLogEvent
  ) {
    guard activeOperationID == operationID else { return }
    activeDownloadTask = nil
    activeOperationID = nil
    internalState = state
    eventLogger.record(event)
  }

  private func failureCode(
    for error: any Error,
    default defaultCode: AutoUpdateFailureCode
  ) -> AutoUpdateFailureCode {
    if error is UpdateNetworkError || error is URLError { return .network }
    if error is UpdateFeedError { return .feed }
    if error is UpdateDownloadError { return .download }
    if error is UpdateArtifactSecurityError { return .artifact }
    return defaultCode
  }
}

public enum AutoUpdateApplicationFacade {
  public static func make() throws -> AutoUpdateService {
    let artifactStore = try UpdateArtifactStore.production()
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
    return AutoUpdateService(
      streamer: URLSessionUpdateHTTPStreamer(),
      verifier: UpdateFeedVerifier(
        trust: trust, replayStore: UserDefaultsUpdateReplayStore()),
      artifactStore: artifactStore,
      artifactValidator: SystemUpdateArtifactValidator(),
      preferences: preferences,
      eventLogger: eventLogger)
  }

  public static func currentProductIdentity(
    bundle: Bundle = .main,
    processInfo: ProcessInfo = .processInfo
  ) -> UpdateProductIdentity {
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    let os = processInfo.operatingSystemVersion
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "unsupported"
    #endif
    return UpdateProductIdentity(
      appVersion: normalizedApplicationVersion(version),
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      architecture: architecture)
  }

  static func normalizedApplicationVersion(_ value: String) -> String {
    if UpdateSemanticVersion(value) != nil { return value }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    let threePart = value + ".0"
    if components.count == 2, UpdateSemanticVersion(threePart) != nil {
      return threePart
    }
    return value
  }
}
