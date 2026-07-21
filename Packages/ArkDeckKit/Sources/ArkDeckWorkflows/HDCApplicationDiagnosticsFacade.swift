import ArkDeckCore
import ArkDeckOpenHarmony
import CryptoKit
import Foundation

/// App-facing aliases keep OpenHarmony implementation types behind the
/// Workflows product boundary. The App links and imports Workflows only.
public typealias HDCDiagnosticsPresentation = ArkDeckOpenHarmony.HDCDiagnosticsPresentation
public typealias HDCServerOtherClientDetection =
  ArkDeckOpenHarmony.HDCServerOtherClientDetection

/// Closed diagnostics surface consumed by the App. It exposes presentation
/// actions and user-selected configuration, but no process runner, argv,
/// supervisor, lifecycle executor, or durable-audit primitive.
public protocol HDCApplicationDiagnosticsProviding: Sendable {
  var lifecycleDispatchIsProductionComposed: Bool { get }
  func refresh() async -> HDCDiagnosticsPresentation
  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func dispatchConfirmedRecovery() async -> HDCDiagnosticsPresentation
  func refreshAuthorization(
    for durableBinding: DurableCurrentDeviceBinding
  ) async -> HDCDiagnosticsPresentation
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
      return HDCProductionApplicationDiagnostics()
    }
    return HDCFixtureApplicationDiagnostics(arguments: arguments)
  }
}

/// Normal App composition. Discovery, read-only probes, durable Session
/// diagnostics, and Supervisor attachment stay inside Workflows so the App
/// cannot construct an HDC command or lifecycle capability.
private actor HDCProductionApplicationDiagnostics: HDCApplicationDiagnosticsProviding {
  nonisolated let lifecycleDispatchIsProductionComposed = true
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

  func refresh() async -> HDCDiagnosticsPresentation {
    await attachSessionIfConfigured()
    return await provider.refresh()
  }

  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    await attachSessionIfConfigured()
    return await provider.requestRecoveryImpactPreview()
  }

  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    await attachSessionIfConfigured()
    return await provider.confirmRecoveryImpactPreview()
  }

  func dispatchConfirmedRecovery() async -> HDCDiagnosticsPresentation {
    guard let sessionDiagnostics, let sessionLifecycle else {
      return await provider.refresh()
    }
    let current = await sessionDiagnostics.refresh()
    guard case .confirmed(let confirmation) = current.lifecycleRecovery else {
      return current
    }
    let result = await sessionLifecycle.dispatch(confirmation: confirmation)
    await sessionDiagnostics.applyLifecycleDispatchResult(result)
    return await sessionDiagnostics.refresh()
  }

  func refreshAuthorization(
    for durableBinding: DurableCurrentDeviceBinding
  ) async -> HDCDiagnosticsPresentation {
    await attachSessionIfConfigured()
    guard let sessionDiagnostics, let registeredToolchain, let registeredEndpoint,
      let registeredServerIdentity
    else {
      return await provider.refresh()
    }
    let result = await HDCSelectedDeviceAuthorizationProbe().probe(
      endpoint: registeredEndpoint,
      toolchain: registeredToolchain,
      serverIdentity: registeredServerIdentity,
      durableBinding: durableBinding)
    await sessionDiagnostics.applyRegisteredAuthorization(result.authorization)
    return await provider.refresh()
  }

  func selectUserConfiguredExecutable(_ url: URL) async throws -> HDCDiagnosticsPresentation {
    try HDCApplicationDiagnosticsConfiguration.persistUserConfiguredExecutable(url)
    attemptedSessionBootstrap = false
    sessionDiagnostics = nil
    sessionLifecycle = nil
    clearRegisteredObservation()
    await provider.configure(
      discoveryRequest: HDCApplicationDiagnosticsConfiguration.discoveryRequest())
    await attachSessionIfConfigured()
    return await provider.refresh()
  }

  private func attachSessionIfConfigured() async {
    guard !attemptedSessionBootstrap else { return }
    attemptedSessionBootstrap = true

    let request = HDCApplicationDiagnosticsConfiguration.discoveryRequest()
    guard let candidate = HDCExternalFirstDiscovery.discover(request).candidates.first,
      let endpoint = try? HDCServerEndpointSelector.select()
    else {
      return
    }

    let snapshot = HDCJobToolchainSnapshot(
      candidate: candidate,
      endpoint: endpoint.endpoint.rawValue,
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
      let processSupervisor = HDCServerProcessSupervisor(supervisor: composition.supervisor)
      let registeredObservation = await processSupervisor.observeRegisteredExistingServer(
        endpoint: endpoint, toolchain: candidate)
      if case .observed = registeredObservation.classification,
        let identity = registeredObservation.identity
      {
        registeredToolchain = candidate
        registeredEndpoint = endpoint
        registeredServerIdentity = identity
      } else {
        clearRegisteredObservation()
      }
      sessionDiagnostics = composition.diagnostics
      sessionLifecycle = composition.lifecycle
      await provider.attachSessionDiagnostics(composition.diagnostics)
    } catch {
      // A failed durable bootstrap cannot leave confirmation state reachable.
      sessionDiagnostics = nil
      sessionLifecycle = nil
      clearRegisteredObservation()
      await provider.detachSessionDiagnostics()
    }
  }

  private func clearRegisteredObservation() {
    registeredToolchain = nil
    registeredEndpoint = nil
    registeredServerIdentity = nil
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

enum HDCApplicationDiagnosticsSessionScope {
  /// This stable digest is a catalog partition only. It is never reused as a
  /// Session ID or Job ID; execution identities are unique UUIDs selected by
  /// `HDCApplicationDiagnosticsExecutionCatalog`.
  static func catalogIdentifier(for candidate: HDCCandidate) -> String {
    let canonicalPath = candidate.path.resolvingSymlinksInPath().standardizedFileURL.path
    let pathDigest = SHA256.hash(data: Data(canonicalPath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "app-hdc-\(candidate.sha256.prefix(24))-\(pathDigest.prefix(24))"
  }
}

/// UI automation receives a presentation-only provider through the same
/// Workflows facade. It has no process or lifecycle execution capability.
private actor HDCFixtureApplicationDiagnostics: HDCApplicationDiagnosticsProviding {
  nonisolated let lifecycleDispatchIsProductionComposed = false
  private let keyAccessDenied: Bool
  private let denied: Bool
  private let timedOut: Bool
  private let criticalGate: Bool
  private var recovery: HDCLifecycleRecoveryPresentation

  init(arguments: [String]) {
    keyAccessDenied = arguments.contains("--ui-test-hdc-key-access-denied")
    denied = arguments.contains("--ui-test-hdc-denied")
    timedOut = arguments.contains("--ui-test-hdc-timed-out")
    criticalGate = arguments.contains("--ui-test-hdc-critical-gate")
    recovery =
      arguments.contains("--ui-test-hdc-impact-preview")
      ? .preview(Self.fixturePreview())
      : .unavailable(reason: "No recovery impact preview has been requested")
  }

  func refresh() async -> HDCDiagnosticsPresentation { presentation() }

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

  func refreshAuthorization(
    for _: DurableCurrentDeviceBinding
  ) async -> HDCDiagnosticsPresentation {
    presentation()
  }

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
      channelProtection: .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning:
        "Channel protection is unverified. Use TCP only on a trusted, isolated network.",
      keyAccessError: keyAccessDenied
        ? "Key access diagnostics are unsupported; no key path was read or modified." : nil,
      subserverCapability: .unsupported,
      lifecycleRecovery: recovery,
      criticalGateMessage: criticalGate
        ? "Blocked by Job job-hdc, Step flash-system. Wait for the flash checkpoint safe boundary."
        : nil)
  }

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
