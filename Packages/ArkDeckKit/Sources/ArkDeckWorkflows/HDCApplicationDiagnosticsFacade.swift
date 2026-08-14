import ArkDeckCore
import ArkDeckOpenHarmony
import CryptoKit
import Foundation

/// App-facing aliases keep OpenHarmony implementation types behind the
/// Workflows product boundary. The App links and imports Workflows only.
public typealias HDCDiagnosticsPresentation = ArkDeckOpenHarmony.HDCDiagnosticsPresentation
package typealias HDCDeviceObservationPresentationKind =
  ArkDeckOpenHarmony.HDCDeviceObservationPresentationKind
public typealias HDCDeviceObservationPresentationEvent =
  ArkDeckOpenHarmony.HDCDeviceObservationPresentationEvent
public typealias HDCServerOtherClientDetection =
  ArkDeckOpenHarmony.HDCServerOtherClientDetection

extension HDCDiagnosticsPresentation {
  /// True only for the path-free status projection emitted by the daemon
  /// that owns the HDC server. App views can hide local executable and
  /// lifecycle controls without learning an executable path or process ID.
  public var isRuntimeManaged: Bool {
    source == HDCRuntimeDiagnosticsResponseDecoding.sourceLabel
  }
}

/// Closed diagnostics surface consumed by the App. It exposes presentation
/// actions and user-selected configuration, but no process runner, argv,
/// supervisor, lifecycle executor, or durable-audit primitive.
public protocol HDCApplicationDiagnosticsProviding: Sendable {
  var lifecycleDispatchIsProductionComposed: Bool { get }
  func refresh() async -> HDCDiagnosticsPresentation
  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func dispatchConfirmedRecovery() async -> HDCDiagnosticsPresentation
  func selectUserConfiguredExecutable(_ url: URL) async throws -> HDCDiagnosticsPresentation
}

public enum HDCApplicationDiagnosticsFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any HDCApplicationDiagnosticsProviding {
    guard arguments.contains("--ui-test-hdc-diagnostics") else {
      if arguments.contains("--ui-test-reset-hdc-selection") {
        HDCApplicationDiagnosticsConfiguration.clearUserConfiguredExecutable()
      }
      return HDCProductionApplicationDiagnostics(
        runtimeProjectionEnabled: !arguments.contains(
          "--ui-test-hdc-local-production-presentation"))
    }
    return HDCFixtureApplicationDiagnostics(arguments: arguments)
  }

  /// Contract tests exercise the UI fixture's delayed-refresh branch with a
  /// virtual wait. The App still receives the process-isolated implementation
  /// above, while tests avoid turning a state assertion into a ten-second
  /// wall-clock assertion.
  public static func makeFixtureForTesting(
    arguments: [String],
    delayedRefreshWait: @escaping @Sendable () async -> Void
  ) -> any HDCApplicationDiagnosticsProviding {
    precondition(arguments.contains("--ui-test-hdc-diagnostics"))
    return HDCFixtureApplicationDiagnostics(
      arguments: arguments,
      delayedRefreshWaitOverride: delayedRefreshWait)
  }
}

private struct HDCDeviceObservationSessionKey: Sendable, Equatable {
  let candidateCanonicalIdentity: String
  let endpoint: HDCServerEndpointSelection
  let executionSessionIdentity: String
}

/// Normal App composition. Discovery, read-only probes, durable Session
/// diagnostics, and Supervisor attachment stay inside Workflows so the App
/// cannot construct an HDC command or lifecycle capability.
private actor HDCProductionApplicationDiagnostics: HDCApplicationDiagnosticsProviding {
  nonisolated let lifecycleDispatchIsProductionComposed = true
  private let runtimeProjectionEnabled: Bool
  private let provider = HDCApplicationDiagnosticsProvider.shared
  private let host = HDCApplicationDiagnosticsHost.shared
  private var attemptedSessionBootstrap = false
  private var sessionDiagnostics: HDCServerDiagnosticsUseCase?
  private var sessionLifecycle: HDCSessionLifecycleUseCase?
  private var registeredToolchain: HDCCandidate?
  private var registeredEndpoint: HDCServerEndpointSelection?
  private var registeredServerIdentity: HDCServerProcessIdentityReceipt?
  private var activeExecutionIdentity: HDCApplicationDiagnosticsExecutionIdentity?
  private var activeCandidateCatalogID: String?
  private var deviceObservationSession: HDCDeviceObservationApplicationSession?
  private var deviceObservationSessionKey: HDCDeviceObservationSessionKey?

  init(runtimeProjectionEnabled: Bool = true) {
    self.runtimeProjectionEnabled = runtimeProjectionEnabled
  }

  func refresh() async -> HDCDiagnosticsPresentation {
    if let runtime = await runtimeManagedPresentation() { return runtime }
    await attachSessionIfConfigured()
    let base = await provider.refresh()
    let presentation = await runtimeOverlay(base)
    guard let deviceObservationSession else { return presentation }
    return presentation.overlayingDeviceEvents(await deviceObservationSession.refresh())
  }

  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let runtime = await runtimeManagedPresentation() { return runtime }
    await attachSessionIfConfigured()
    let requested = await provider.requestRecoveryImpactPreview()
    let withEvents = await overlayCurrentDeviceEvents(on: requested)
    return await runtimeOverlay(withEvents)
  }

  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let runtime = await runtimeManagedPresentation() { return runtime }
    await attachSessionIfConfigured()
    let confirmed = await provider.confirmRecoveryImpactPreview()
    let withEvents = await overlayCurrentDeviceEvents(on: confirmed)
    return await runtimeOverlay(withEvents)
  }

  func dispatchConfirmedRecovery() async -> HDCDiagnosticsPresentation {
    if let runtime = await runtimeManagedPresentation() { return runtime }
    guard let sessionDiagnostics, let sessionLifecycle else {
      let current = await provider.refresh()
      return await overlayCurrentDeviceEvents(on: current)
    }
    let sessionCurrent = await sessionDiagnostics.refresh()
    guard case .confirmed(let confirmation) = sessionCurrent.lifecycleRecovery else {
      let withEvents = await overlayCurrentDeviceEvents(on: sessionCurrent)
      return await runtimeOverlay(withEvents)
    }
    let result = await sessionLifecycle.dispatch(confirmation: confirmation)
    await sessionDiagnostics.applyLifecycleDispatchResult(result)
    let refreshed = await sessionDiagnostics.refresh()
    let withEvents = await overlayCurrentDeviceEvents(on: refreshed)
    return await runtimeOverlay(withEvents)
  }

  func selectUserConfiguredExecutable(_ url: URL) async throws -> HDCDiagnosticsPresentation {
    if let runtime = await runtimeManagedPresentation() { return runtime }
    try HDCApplicationDiagnosticsConfiguration.persistUserConfiguredExecutable(url)
    attemptedSessionBootstrap = false
    sessionDiagnostics = nil
    sessionLifecycle = nil
    clearRegisteredObservation()
    clearDeviceObservationSession()
    await provider.configure(
      discoveryRequest: HDCApplicationDiagnosticsConfiguration.discoveryRequest())
    await attachSessionIfConfigured()
    let refreshed = await provider.refresh()
    let withEvents = await overlayCurrentDeviceEvents(on: refreshed)
    return await runtimeOverlay(withEvents)
  }

  private func runtimeManagedPresentation() async -> HDCDiagnosticsPresentation? {
    guard runtimeProjectionEnabled else { return nil }
    let presentation = await runtimeOverlay(.unprobed)
    return presentation.isRuntimeManaged ? presentation : nil
  }

  private func runtimeOverlay(
    _ presentation: HDCDiagnosticsPresentation
  ) async -> HDCDiagnosticsPresentation {
    guard runtimeProjectionEnabled else { return presentation }
    async let status = DeviceListXPCReadTransport.request(method: "runtime.hdc-status")
    async let candidates = DeviceListXPCReadTransport.request(method: "device.candidates")
    return HDCRuntimeDiagnosticsResponseDecoding.overlay(
      presentation: presentation,
      statusResponse: await status,
      candidateResponse: await candidates)
  }

  private func attachSessionIfConfigured() async {
    guard !attemptedSessionBootstrap else { return }
    attemptedSessionBootstrap = true

    let request = HDCApplicationDiagnosticsConfiguration.discoveryRequest()
    guard let candidate = HDCExternalFirstDiscovery.discover(request).candidates.first,
      let endpoint = try? HDCServerEndpointSelector.select()
    else {
      clearRegisteredObservation()
      clearDeviceObservationSession()
      return
    }

    let snapshot = HDCJobToolchainSnapshot(
      candidate: candidate,
      endpoint: endpoint.endpoint.rawValue,
      endpointSource: endpoint.source,
      details: HDCProbeDetails(
        platformTrust: .unknown(reason: "ToolTrustInspector has not run"),
        clientVersion: .unknown(
          reason: "registered client probe requires an existing server identity"),
        serverVersion: .unknown(reason: "checkserver has not run"),
        daemonVersion: .unknown(reason: "not exposed by a registered probe"),
        serverGeneration: .unknown(reason: "checkserver has not run")))
    let lifecyclePostDispatchProbe = HDCRegisteredLifecyclePostDispatchProbe(
      toolchain: candidate)

    do {
      let candidateCatalogID = HDCApplicationDiagnosticsSessionScope.catalogIdentifier(
        for: candidate)
      let executionIdentity: HDCApplicationDiagnosticsExecutionIdentity
      if activeCandidateCatalogID == candidateCatalogID, let activeExecutionIdentity {
        executionIdentity = activeExecutionIdentity
      } else {
        executionIdentity = try HDCApplicationDiagnosticsExecutionCatalog(
          root: try sessionCatalogRoot()
        ).select(for: candidate)
      }
      let composition = try await host.compose(
        sessionRoot: executionIdentity.sessionRoot,
        sessionID: executionIdentity.sessionID,
        jobID: executionIdentity.jobID,
        toolchain: candidate,
        snapshot: snapshot,
        authorization: .unavailable(reason: "authorization probe requires a selected device"),
        keyAccessError:
          "Key access diagnostics are unsupported without a configured or user-approved locator.",
        subserverCapability: .unsupported,
        impactInventory: await HDCApplicationParticipantRegistry.shared.inventory(
          for: endpoint.endpoint),
        postDispatchProbe: { step in
          await lifecyclePostDispatchProbe.observe(after: step)
        })
      activeExecutionIdentity = executionIdentity
      activeCandidateCatalogID = candidateCatalogID
      if let identity = await observeRegisteredServerIdentity(
        supervisor: composition.supervisor,
        candidate: candidate,
        endpoint: endpoint)
      {
        registeredToolchain = candidate
        registeredEndpoint = endpoint
        registeredServerIdentity = identity
      } else {
        clearRegisteredObservation()
      }
      replaceDeviceObservationSessionIfNeeded(
        candidate: candidate,
        endpoint: endpoint,
        executionIdentity: executionIdentity)
      sessionDiagnostics = composition.diagnostics
      sessionLifecycle = composition.lifecycle
      await provider.attachSessionDiagnostics(composition.diagnostics)
    } catch {
      // A failed durable bootstrap cannot leave confirmation state reachable.
      sessionDiagnostics = nil
      sessionLifecycle = nil
      clearRegisteredObservation()
      clearDeviceObservationSession()
      await provider.detachSessionDiagnostics()
    }
  }

  private func observeRegisteredServerIdentity(
    supervisor: HDCServerSupervisor,
    candidate: HDCCandidate,
    endpoint: HDCServerEndpointSelection
  ) async -> HDCServerProcessIdentityReceipt? {
    if candidate.sha256
      == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256
    {
      let session = HDCSupervisorObservationApplicationSession.makeProduction(
        supervisor: supervisor,
        toolchain: candidate,
        endpointSelection: endpoint)
      let observation = await session.observe()
      guard case .observed = observation.classification else { return nil }
      return observation.identity
    }

    let processSupervisor = HDCServerProcessSupervisor(supervisor: supervisor)
    let observation = await processSupervisor.observeRegisteredExistingServer(
      endpoint: endpoint, toolchain: candidate)
    guard case .observed = observation.classification else { return nil }
    return observation.identity
  }

  private func clearRegisteredObservation() {
    registeredToolchain = nil
    registeredEndpoint = nil
    registeredServerIdentity = nil
  }

  private func replaceDeviceObservationSessionIfNeeded(
    candidate: HDCCandidate,
    endpoint: HDCServerEndpointSelection,
    executionIdentity: HDCApplicationDiagnosticsExecutionIdentity
  ) {
    let key = HDCDeviceObservationSessionKey(
      candidateCanonicalIdentity: HDCApplicationDiagnosticsSessionScope.catalogIdentifier(
        for: candidate),
      endpoint: endpoint,
      executionSessionIdentity: executionIdentity.sessionID)
    guard key != deviceObservationSessionKey else { return }
    deviceObservationSession = HDCDeviceObservationApplicationSession.makeProduction(
      toolchain: candidate, endpointSelection: endpoint)
    deviceObservationSessionKey = key
  }

  private func clearDeviceObservationSession() {
    deviceObservationSession = nil
    deviceObservationSessionKey = nil
  }

  private func overlayCurrentDeviceEvents(
    on presentation: HDCDiagnosticsPresentation
  ) async -> HDCDiagnosticsPresentation {
    guard let deviceObservationSession else { return presentation }
    return presentation.overlayingDeviceEvents(await deviceObservationSession.currentEvents())
  }

  private func sessionCatalogRoot() throws -> URL {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return applicationSupport.appending(
      path: "ArkDeck/HDC/app-diagnostics-session",
      directoryHint: .isDirectory)
  }
}

enum HDCRuntimeDiagnosticsResponseDecoding {
  static let sourceLabel = "ArkDeck Runtime"

  static func overlay(
    presentation: HDCDiagnosticsPresentation,
    statusResponse: Result<Data, DeviceListXPCReadFailure>,
    candidateResponse: Result<Data, DeviceListXPCReadFailure>
  ) -> HDCDiagnosticsPresentation {
    guard case .success(let statusData) = statusResponse,
      let status = resultObject(statusData),
      status["availability"] as? String == "ready",
      status["source"] as? String == "runtimeManaged",
      status["serverHealth"] as? String == HDCServerHealth.healthy.rawValue,
      status["ownership"] as? String == HDCServerOwnership.arkDeckManaged.rawValue,
      let executableSHA256 = status["toolSha256"] as? String,
      isSHA256(executableSHA256),
      let clientVersion = nonempty(status["clientVersion"] as? String),
      let serverVersion = nonempty(status["serverVersion"] as? String),
      clientVersion == serverVersion,
      let endpoint = loopbackEndpoint(status["endpoint"] as? String),
      let endpointSourceRaw = status["endpointSource"] as? String,
      let endpointSource = HDCServerEndpointSource(rawValue: endpointSourceRaw),
      let protocolVersion = nonempty(status["protocolVersion"] as? String)
    else { return presentation }

    return HDCDiagnosticsPresentation(
      absolutePath: "not exposed by Runtime",
      source: sourceLabel,
      hash: executableSHA256,
      platformTrust: "descriptor-bound SHA-256 verified by Runtime",
      clientVersion: clientVersion,
      serverVersion: serverVersion,
      daemonVersion: "Runtime protocol \(protocolVersion)",
      endpoint: endpoint,
      serverHealth: .healthy,
      generation: "Runtime-owned process lifetime",
      ownership: .arkDeckManaged,
      authorization: authorization(from: candidateResponse),
      channelProtection: .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning: nil,
      keyAccessError: nil,
      subserverCapability: .unsupported,
      lifecycleRecovery: .unavailable(
        reason: "ArkDeck Runtime owns the managed HDC server lifecycle"),
      endpointSource: endpointSource,
      deviceEvents: presentation.deviceEvents)
  }

  private static func authorization(
    from response: Result<Data, DeviceListXPCReadFailure>
  ) -> HDCAuthorizationState {
    guard case .success(let data) = response,
      let candidates = resultArray(data)
    else {
      return .unavailable(reason: "Runtime device authorization could not be read")
    }
    let states = candidates.compactMap { $0["state"] as? String }
    if states.contains("Connected") { return .ready }
    if states.contains("Unauthorized") { return .unauthorizedWaitingForTrust }
    if states.contains("Offline") {
      return .unavailable(reason: "HDC reported the target offline")
    }
    if states.isEmpty {
      return .unavailable(reason: "No HDC device candidate is visible")
    }
    return .unavailable(reason: "Runtime returned an unrecognized HDC device state")
  }

  private static func resultObject(_ data: Data) -> [String: Any]? {
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["ok"] as? Bool == true
    else { return nil }
    return envelope["result"] as? [String: Any]
  }

  private static func resultArray(_ data: Data) -> [[String: Any]]? {
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["ok"] as? Bool == true
    else { return nil }
    return envelope["result"] as? [[String: Any]]
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(\.isHexDigit)
  }

  private static func loopbackEndpoint(_ value: String?) -> String? {
    guard let value, value.hasPrefix("127.0.0.1:"),
      let port = Int(value.dropFirst("127.0.0.1:".count)),
      (1...65_535).contains(port)
    else { return nil }
    return value
  }
}

enum HDCApplicationDiagnosticsSessionScope {
  /// This stable digest is a catalog partition only. It is never reused as a
  /// Session ID or Job ID; execution identities are unique UUIDs selected by
  /// `HDCApplicationDiagnosticsExecutionCatalog`.
  static func catalogIdentifier(for candidate: HDCCandidate) -> String {
    let canonicalPath = candidate.path.resolvingSymlinksInPath().standardizedFileURL.path
    let pathDigest = SHA256Hex.string(of: Data(canonicalPath.utf8))
    return "app-hdc-\(candidate.sha256.prefix(24))-\(pathDigest.prefix(24))"
  }
}

/// UI automation receives a presentation-only provider through the same
/// Workflows facade. It has no process or lifecycle execution capability.
private actor HDCFixtureApplicationDiagnostics: HDCApplicationDiagnosticsProviding {
  nonisolated let lifecycleDispatchIsProductionComposed = false
  private let launchArguments: [String]
  /// Optional file the UI test rewrites between assertions. Re-reading it on
  /// every refresh lets one launched instance walk every fixture state, which
  /// is what keeps a suite run down to two launches instead of one per fault.
  /// It is reachable only from this actor, and this actor exists only when
  /// `--ui-test-hdc-diagnostics` selected the fixture, so no production
  /// composition can read or be steered by it.
  private let stateFileURL: URL?
  private let delayedRefreshWaitOverride: (@Sendable () async -> Void)?
  private var recovery: HDCLifecycleRecoveryPresentation
  private var refreshCallCount = 0
  private var latestCompletedRefreshCallCount = 0

  init(
    arguments: [String],
    delayedRefreshWaitOverride: (@Sendable () async -> Void)? = nil
  ) {
    launchArguments = arguments
    self.delayedRefreshWaitOverride = delayedRefreshWaitOverride
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      stateFileURL = URL(filePath: arguments[index + 1])
    } else {
      stateFileURL = nil
    }
    recovery =
      arguments.contains("--ui-test-hdc-impact-preview")
      ? .preview(Self.fixturePreview())
      : .unavailable(reason: "No recovery impact preview has been requested")
  }

  /// Launch arguments are the floor; the state file, when present and
  /// readable, replaces them wholesale so a test can move to a state that
  /// asserts the *absence* of a fault it previously set.
  private func activeFaults() -> Set<String> {
    if let stateFileURL, let text = try? String(contentsOf: stateFileURL, encoding: .utf8) {
      return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }
    return Set(launchArguments.filter { $0.hasPrefix("--ui-test-hdc-") })
  }

  private var keyAccessDenied: Bool { activeFaults().contains("--ui-test-hdc-key-access-denied") }
  private var denied: Bool { activeFaults().contains("--ui-test-hdc-denied") }
  private var timedOut: Bool { activeFaults().contains("--ui-test-hdc-timed-out") }
  private var criticalGate: Bool { activeFaults().contains("--ui-test-hdc-critical-gate") }
  private var delayedRefresh: Bool { activeFaults().contains("--ui-test-hdc-refresh-delay") }
  /// Not a fault: the one fixture state in which nothing needs attention. The
  /// default fixture always carries the unprotected-TCP warning, so the
  /// Overview's "nothing needs attention" branch could never be reached.
  private var channelVerified: Bool { activeFaults().contains("--ui-test-hdc-channel-verified") }

  func refresh() async -> HDCDiagnosticsPresentation {
    refreshCallCount += 1
    let acceptedCall = refreshCallCount
    if delayedRefresh, acceptedCall == 2 {
      await waitForDelayedRefreshRelease()
    }
    latestCompletedRefreshCallCount = max(latestCompletedRefreshCallCount, acceptedCall)
    return presentation()
  }

  /// UI automation controls an in-flight refresh by keeping the delay token
  /// in its existing fixture-state file, then removing it after asserting the
  /// disabled controls and previous snapshot. This replaces a fixed sleep
  /// with a deterministic rendezvous and retains a bounded fallback for old
  /// callers that do not provide a state file.
  private func waitForDelayedRefreshRelease() async {
    if let delayedRefreshWaitOverride {
      await delayedRefreshWaitOverride()
      return
    }
    guard stateFileURL != nil else {
      try? await Task.sleep(for: .seconds(10))
      return
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while delayedRefresh, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    recovery = .preview(Self.fixturePreview())
    return presentation()
  }

  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    guard case .preview(let preview) = recovery else {
      recovery = .blocked(reason: "No current impact preview is available for confirmation")
      return presentation()
    }
    recovery = .confirmed(HDCServerLifecycleConfirmation(id: UUID(), preview: preview))
    return presentation()
  }

  func dispatchConfirmedRecovery() async -> HDCDiagnosticsPresentation { presentation() }

  func selectUserConfiguredExecutable(_: URL) async throws -> HDCDiagnosticsPresentation {
    presentation()
  }

  private func presentation() -> HDCDiagnosticsPresentation {
    let authorization: HDCAuthorizationState
    if keyAccessDenied {
      authorization = .unavailable(
        reason: "key access diagnostics unsupported without a user-approved locator")
    } else if denied {
      authorization = .denied(reason: "The device declined trust")
    } else if timedOut {
      authorization = .timedOut
    } else {
      authorization = .ready
    }
    return HDCDiagnosticsPresentation(
      absolutePath: "/Applications/DevEco/hdc",
      source: "devecoSDK",
      hash: "fixture-sha256",
      platformTrust: "unverified (UI fixture)",
      clientVersion: "3.2.0d",
      serverVersion: "3.2.0d",
      daemonVersion: "unknown (not exposed by checkserver)",
      endpoint: "127.0.0.1:18710",
      serverHealth: .healthy,
      generation: "7",
      ownership: .external,
      authorization: authorization,
      channelProtection: channelVerified
        ? .encryptedVerified(
          HDCChannelProtectionEvidence(
            evidenceVersion: "fixture-v1", source: "UI fixture",
            detail: "Fixture-declared verified channel; no real transport was inspected."))
        : .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning: channelVerified
        ? nil
        : "Channel protection is unverified. Use TCP only on a trusted, isolated network.",
      keyAccessError: keyAccessDenied
        ? "Key access diagnostics are unsupported; no key path was read or modified." : nil,
      subserverCapability: .unsupported,
      lifecycleRecovery: recovery,
      criticalGateMessage: criticalGate
        ? "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary."
        : nil,
      deviceEvents: Array(
        Self.fixtureDeviceEvents.prefix(
          min(
            max(latestCompletedRefreshCallCount, 1),
            Self.fixtureDeviceEvents.count))))
  }

  private static let fixtureDeviceEvents = [
    HDCDeviceObservationPresentationEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_800),
      kind: .appeared,
      redactedDeviceIdentifier: "redacted-device-0123456789abcdef01234567"),
    HDCDeviceObservationPresentationEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_801),
      kind: .disappeared,
      redactedDeviceIdentifier: "redacted-device-0123456789abcdef01234567"),
    HDCDeviceObservationPresentationEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_802),
      kind: .observationUnknown,
      redactedDeviceIdentifier: nil),
  ]

  private static func fixturePreview() -> HDCServerLifecycleImpactPreview {
    HDCServerLifecycleImpactPreview(
      id: UUID(),
      auditID: UUID(),
      snapshot: HDCServerImpactSnapshot(
        action: .restartConfirmedGeneration,
        endpoint: HDCServerEndpoint("127.0.0.1:18710"),
        generation: 7,
        ownership: .external,
        affectedDeviceCoordinators: ["device-a", "device-b"],
        affectedJobs: ["job-hdc"],
        otherClientDetection: .detected(["DevEco IDE"]),
        expectedInterruption: "HDC requests using this endpoint will be interrupted.",
        recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job."))
  }
}
