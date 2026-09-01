import Foundation

public struct RuntimeUpdateCleanupReceipt: Equatable, Sendable {
  public static let schemaVersion = "arkdeck.runtime-update-cleanup/1"

  public let status: RuntimeUpdateStatusProjection
  public let removedVerifiedArtifacts: Int

  public init(status: RuntimeUpdateStatusProjection, removedVerifiedArtifacts: Int) {
    self.status = status
    self.removedVerifiedArtifacts = removedVerifiedArtifacts
  }
}

/// A process-independent application facade for the consumer update lifecycle.
///
/// Each mutation holds the store's operation lease for its full network/verification/handoff
/// duration and publishes a generation-bound transition before doing work. This makes separate App
/// and CLI processes observe one lifecycle and lets cleanup distinguish a live operation from a
/// crashed owner without using PID or time heuristics.
public actor RuntimeUpdateApplicationFacade {
  private let streamer: any UpdateHTTPStreaming
  private let verifier: UpdateFeedVerifier
  private let artifactStore: UpdateArtifactStore
  private let artifactValidator: any UpdateArtifactValidating
  private let preferences: any AutoUpdatePreferenceStoring
  private let eventLogger: any AutoUpdateEventLogging
  private let stateStore: RuntimeUpdateStateStore

  public init(
    streamer: any UpdateHTTPStreaming,
    verifier: UpdateFeedVerifier,
    artifactStore: UpdateArtifactStore,
    artifactValidator: any UpdateArtifactValidating,
    preferences: any AutoUpdatePreferenceStoring,
    stateStore: RuntimeUpdateStateStore,
    eventLogger: any AutoUpdateEventLogging = NoOpAutoUpdateEventLogger()
  ) throws {
    _ = try stateStore.load()
    self.streamer = streamer
    self.verifier = verifier
    self.artifactStore = artifactStore
    self.artifactValidator = artifactValidator
    self.preferences = preferences
    self.stateStore = stateStore
    self.eventLogger = eventLogger
  }

  public var state: AutoUpdateState {
    (try? stateStore.load().state) ?? .failed(.storage)
  }

  public var automaticChecksEnabled: Bool {
    preferences.automaticChecksEnabled()
  }

  public func setAutomaticChecksEnabled(_ enabled: Bool) {
    preferences.setAutomaticChecksEnabled(enabled)
  }

  public func status() throws -> RuntimeUpdateStatusProjection {
    RuntimeUpdateStatusProjection(snapshot: try stateStore.load())
  }

  public func recoverOrphanPartials() throws {
    let lease: RuntimeUpdateOperationLease
    do {
      lease = try stateStore.acquireOperationLease()
    } catch RuntimeUpdateStateStoreError.operationInProgress {
      return
    }
    defer { withExtendedLifetime(lease) {} }
    try recoverWithOperationLeaseHeld()
  }

  private func recoverWithOperationLeaseHeld() throws {
    var snapshot = try stateStore.load()
    if snapshot.activeOperationID != nil {
      let recoveredState: AutoUpdateState
      switch snapshot.state {
      case .verifying(let artifact):
        artifactStore.remove(artifact)
        recoveredState = .cancelled
      case .awaitingConsent(_, let artifact):
        artifactStore.remove(artifact.downloaded)
        recoveredState = .failed(.handoff)
      case .checking, .downloading:
        recoveredState = .cancelled
      default:
        throw RuntimeUpdateStateStoreError.recordUnreadable
      }
      snapshot = try stateStore.replace(
        expectedGeneration: snapshot.generation, state: recoveredState)
    }
    try artifactStore.removeOrphanPartials()
    _ = try artifactStore.removeUnreferencedArtifacts(
      keeping: Self.retainedArtifactNames(snapshot.state, in: artifactStore.directory))
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
      now.timeIntervalSince(lastAttempt) < AutoUpdateService.automaticCheckInterval
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
    let lease = try stateStore.acquireOperationLease()
    defer { withExtendedLifetime(lease) {} }
    let current = try stateStore.load()
    guard current.activeOperationID == nil, case .available(let feed) = current.state else {
      throw AutoUpdateServiceError.invalidTransition
    }
    let operationID = UUID()
    let active = try stateStore.replace(
      expectedGeneration: current.generation,
      state: .downloading(feed),
      activeOperationID: operationID)
    let service = makeService(initialState: current.state, operationID: operationID)
    let cancellationMonitor = monitorCancellation(of: service, operationID: operationID)
    defer { cancellationMonitor.cancel() }
    do {
      let result = try await service.downloadAvailableUpdate()
      return try finish(
        result, operationID: operationID, minimumGeneration: active.generation)
    } catch {
      try await settleFailure(service: service, operationID: operationID)
      throw error
    }
  }

  @discardableResult
  public func handoff(
    explicitConsent: Bool,
    revealer: any UpdateArtifactRevealing
  ) async throws -> AutoUpdateState {
    guard explicitConsent else { throw AutoUpdateServiceError.explicitConsentRequired }
    let lease = try stateStore.acquireOperationLease()
    defer { withExtendedLifetime(lease) {} }
    let current = try stateStore.load()
    guard current.activeOperationID == nil,
      case .awaitingConsent = current.state
    else { throw AutoUpdateServiceError.invalidTransition }
    let operationID = UUID()
    let active = try stateStore.replace(
      expectedGeneration: current.generation,
      state: current.state,
      activeOperationID: operationID)
    let service = makeService(initialState: current.state, operationID: operationID)
    let cancellationMonitor = monitorCancellation(of: service, operationID: operationID)
    defer { cancellationMonitor.cancel() }
    do {
      let result = try await service.handoff(explicitConsent: true, revealer: revealer)
      return try finish(
        result, operationID: operationID, minimumGeneration: active.generation)
    } catch {
      try await settleFailure(service: service, operationID: operationID)
      throw error
    }
  }

  @discardableResult
  public func cancel() throws -> RuntimeUpdateStatusProjection {
    RuntimeUpdateStatusProjection(snapshot: try stateStore.requestCancellation())
  }

  @discardableResult
  public func cleanup() throws -> RuntimeUpdateCleanupReceipt {
    let lease = try stateStore.acquireOperationLease()
    defer { withExtendedLifetime(lease) {} }
    try recoverWithOperationLeaseHeld()
    var snapshot = try stateStore.load()
    // An explicit cleanup is the user's way to discard a verified artifact after download or
    // Finder handoff. Publish the path-free idle state first; a crash after that point can leave
    // only an unreferenced immutable cache file, which the next recovery safely removes. App
    // startup recovery does not take this branch, so it preserves an artifact awaiting consent.
    switch snapshot.state {
    case .awaitingConsent, .handedOff:
      snapshot = try stateStore.replace(
        expectedGeneration: snapshot.generation, state: .idle)
    default:
      break
    }
    let removed = try artifactStore.removeUnreferencedArtifacts(
      keeping: Self.retainedArtifactNames(snapshot.state, in: artifactStore.directory))
    return RuntimeUpdateCleanupReceipt(
      status: RuntimeUpdateStatusProjection(snapshot: snapshot),
      removedVerifiedArtifacts: removed)
  }

  private func check(identity: UpdateProductIdentity, now: Date) async throws -> AutoUpdateState {
    let lease = try stateStore.acquireOperationLease()
    defer { withExtendedLifetime(lease) {} }
    let current = try stateStore.load()
    guard current.activeOperationID == nil else {
      throw RuntimeUpdateStateStoreError.operationInProgress
    }
    switch current.state {
    case .idle, .available, .noUpdate, .failed, .cancelled:
      break
    case .checking, .downloading, .verifying, .awaitingConsent, .handedOff:
      throw AutoUpdateServiceError.invalidTransition
    }
    let operationID = UUID()
    let active = try stateStore.replace(
      expectedGeneration: current.generation,
      state: .checking,
      activeOperationID: operationID)
    let service = makeService(initialState: current.state, operationID: operationID)
    let cancellationMonitor = monitorCancellation(of: service, operationID: operationID)
    defer { cancellationMonitor.cancel() }
    do {
      let result = try await service.checkManually(identity: identity, now: now)
      return try finish(
        result, operationID: operationID, minimumGeneration: active.generation)
    } catch {
      try await settleFailure(service: service, operationID: operationID)
      throw error
    }
  }

  private func makeService(
    initialState: AutoUpdateState,
    operationID: UUID
  ) -> AutoUpdateService {
    let stateStore = self.stateStore
    return AutoUpdateService(
      streamer: streamer,
      verifier: verifier,
      artifactStore: artifactStore,
      artifactValidator: artifactValidator,
      preferences: preferences,
      eventLogger: eventLogger,
      initialState: initialState,
      cancellationRequested: {
        guard let snapshot = try? stateStore.load() else { return true }
        return snapshot.activeOperationID != operationID || snapshot.cancellationRequested
      })
  }

  private func monitorCancellation(
    of service: AutoUpdateService,
    operationID: UUID
  ) -> Task<Void, Never> {
    let stateStore = self.stateStore
    return Task {
      while !Task.isCancelled {
        guard let snapshot = try? stateStore.load() else {
          await service.cancel()
          return
        }
        if snapshot.activeOperationID != operationID || snapshot.cancellationRequested {
          await service.cancel()
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  private func finish(
    _ result: AutoUpdateState,
    operationID: UUID,
    minimumGeneration: UInt64
  ) throws -> AutoUpdateState {
    let latest = try stateStore.load()
    guard latest.generation >= minimumGeneration,
      latest.activeOperationID == operationID
    else { throw RuntimeUpdateStateStoreError.resourceConflict }
    if latest.cancellationRequested {
      // Finder reveal is the terminal external effect of this lifecycle. A cancellation that
      // linearizes after reveal cannot truthfully turn that completed handoff into `cancelled`;
      // publish the observed outcome and clear the request instead. Earlier cancellation points
      // are still checked before the reveal and settle as cancelled with no handoff.
      if case .handedOff = result {
        _ = try stateStore.replace(
          expectedGeneration: latest.generation, state: result)
        return result
      }
      _ = try stateStore.replace(
        expectedGeneration: latest.generation, state: .cancelled)
      throw UpdateDownloadError.cancelled
    }
    _ = try stateStore.replace(
      expectedGeneration: latest.generation, state: result)
    return result
  }

  private func settleFailure(
    service: AutoUpdateService,
    operationID: UUID
  ) async throws {
    let latest = try stateStore.load()
    guard latest.activeOperationID == operationID else { return }
    let finalState: AutoUpdateState = latest.cancellationRequested
      ? .cancelled : await service.state
    _ = try stateStore.replace(
      expectedGeneration: latest.generation, state: finalState)
  }

  private static func retainedArtifactNames(
    _ state: AutoUpdateState,
    in directory: URL
  ) -> Set<String> {
    let artifact: DownloadedUpdateArtifact?
    switch state {
    case .verifying(let downloaded):
      artifact = downloaded
    case .awaitingConsent(_, let validated):
      artifact = validated.downloaded
    case .handedOff(let url):
      guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
      else { return [] }
      return [url.lastPathComponent]
    default:
      artifact = nil
    }
    guard let artifact,
      artifact.url.deletingLastPathComponent().standardizedFileURL
        == directory.standardizedFileURL
    else { return [] }
    return [artifact.url.lastPathComponent]
  }
}
