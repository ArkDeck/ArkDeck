import Foundation

// Explicit UI fixture only; none of these display values grant Runtime authority.
actor HDCClientDiagnosticsFixture: HDCClientDiagnosticsProviding {
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
  private var recovery: HDCClientDiagnosticsPresentation.Recovery
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

  func refresh(deviceObservation: DeviceListPresentation) async -> HDCClientDiagnosticsPresentation {
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

  func requestRecoveryImpactPreview() async -> HDCClientDiagnosticsPresentation {
    recovery = .preview(Self.fixturePreview())
    return presentation()
  }

  func confirmRecoveryImpactPreview() async -> HDCClientDiagnosticsPresentation {
    guard case .preview(let preview) = recovery else {
      recovery = .blocked(reason: "No current impact preview is available for confirmation")
      return presentation()
    }
    recovery = .confirmed(.init(generation: preview.generation))
    return presentation()
  }

  func dispatchConfirmedRecovery() async -> HDCClientDiagnosticsPresentation { presentation() }

  func selectUserConfiguredExecutable(_: URL) async throws -> HDCClientDiagnosticsPresentation {
    presentation()
  }

  private func presentation() -> HDCClientDiagnosticsPresentation {
    let authorization: HDCClientDiagnosticsPresentation.Authorization
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
    return HDCClientDiagnosticsPresentation(
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
      ownership: HDCClientDiagnosticsPresentation.Ownership.external,
      authorization: authorization,
      channelProtection: channelVerified
        ? .encryptedVerified(
          HDCClientDiagnosticsPresentation.ChannelEvidence(
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
      automaticLifecycleDispatchCount: 0, automaticSubserverDispatchCount: 0,
      deviceEvents: Array(
        Self.fixtureDeviceEvents.prefix(
          min(
            max(latestCompletedRefreshCallCount, 1),
            Self.fixtureDeviceEvents.count))),
      deviceEventsAvailable: true, isRuntimeManaged: false)
  }

  private static let fixtureDeviceEvents = [
    HDCClientDiagnosticsPresentation.DeviceEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_800),
      kind: .appeared,
      redactedDeviceIdentifier: "redacted-device-0123456789abcdef01234567"),
    HDCClientDiagnosticsPresentation.DeviceEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_801),
      kind: .disappeared,
      redactedDeviceIdentifier: "redacted-device-0123456789abcdef01234567"),
    HDCClientDiagnosticsPresentation.DeviceEvent(
      acceptedAt: Date(timeIntervalSince1970: 1_785_196_802),
      kind: .observationUnknown,
      redactedDeviceIdentifier: nil),
  ]

  private static func fixturePreview() -> HDCClientDiagnosticsPresentation.Impact {
    .init(
      action: .init("restartConfirmedGeneration"), endpoint: .init("127.0.0.1:18710"),
      generation: 7, ownership: HDCClientDiagnosticsPresentation.Ownership.external,
      affectedDeviceCoordinators: ["device-a", "device-b"], affectedJobs: ["job-hdc"],
      otherClientDetection: .detected(["DevEco IDE"]),
      expectedInterruption: "HDC requests using this endpoint will be interrupted.",
      recoveryPath: "Re-probe the shared endpoint and reconcile every affected Job.")
  }
}
