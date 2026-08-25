import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

/// Routes pointer injection over a shell that is already open, and everything
/// else to the dispatcher it wraps.
///
/// A gesture has exactly one device command in it, and spawning a client for
/// that one command costs a process launch on top of the device round trip.
/// Measured against the device, interleaved: the same `uinput` invocation
/// takes p50 334 ms spawned and p50 223 ms over an open channel, against a
/// 400 ms budget for the whole gesture.
///
/// Only pointer injection is routed. The saving is a per-command constant, so
/// it matters for the one operation that has an interaction budget and not for
/// the file transfers and long reads where it would be noise against their own
/// cost — and every operation left on the spawning path is one whose behaviour
/// this cannot change.
package actor PointerInputChannelDispatcher: RuntimeProcessDispatching {
  /// A channel left open is a shell left running on the device. It is closed
  /// once gestures stop, rather than held for as long as the daemon lives.
  package static let defaultIdleTimeout: TimeInterval = 120

  private struct OpenChannel {
    let channel: PersistentDeviceShellChannel
    var lastUsed: Date
  }

  private let fallback: any RuntimeProcessDispatching
  private let resolver: any RuntimeExecutableResolving
  private let childEnvironment: [String: String]
  private let idleTimeout: TimeInterval
  private let now: @Sendable () -> Date
  private var channels: [String: OpenChannel] = [:]
  /// Closing an idle channel cannot wait for the next gesture: the case that
  /// matters is precisely the one where no next gesture comes. Sweeping only
  /// on dispatch left the device holding a shell for as long as the daemon
  /// ran — measured on the device, still open 11 minutes after the last
  /// gesture under a 120s timeout.
  private var sweep: Task<Void, Never>?

  package init(
    fallback: any RuntimeProcessDispatching,
    resolver: any RuntimeExecutableResolving,
    childEnvironment: [String: String] = HDCServerEndpointSelector
      .inheritedPortChildEnvironment(),
    idleTimeout: TimeInterval = PointerInputChannelDispatcher.defaultIdleTimeout,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fallback = fallback
    self.resolver = resolver
    self.childEnvironment = childEnvironment
    self.idleTimeout = idleTimeout
    self.now = now
  }

  package nonisolated func unavailableReason(providerID: String) -> String? {
    fallback.unavailableReason(providerID: providerID)
  }

  package func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    try await dispatch(plan, progress: { _ in })
  }

  package func dispatch(
    _ plan: TypedProcessPlan,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> ProviderProcessReceipt {
    guard let routed = Self.routable(plan) else {
      return try await fallback.dispatch(plan, progress: progress)
    }
    expireIdleChannels()
    let channel: PersistentDeviceShellChannel
    do {
      channel = try openedChannel(connectKey: routed.connectKey)
    } catch {
      // Nothing was written to the device, so the gesture can still be
      // dispatched the ordinary way: an unopenable channel costs latency,
      // never the operation.
      return try await fallback.dispatch(plan, progress: progress)
    }
    do {
      let answer = try channel.run(
        routed.command, timeout: routed.timeoutSeconds,
        outputByteBudget: plan.outputByteBudget ?? 1_048_576)
      channels[routed.connectKey]?.lastUsed = now()
      scheduleSweep()
      // The exit status is reported as the spawning path reports it, which is
      // always 0 because `hdc shell` cannot carry the device's status back.
      // The channel *can* recover it, but a verdict that depended on which
      // path a gesture happened to take would not be one verdict at all.
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: answer.stdout,
        stderr: Data(),
        stdoutTruncated: answer.truncated,
        durationSeconds: 0)
    } catch DeviceShellChannelError.unavailable(let reason) {
      // Refused before anything was written.
      close(connectKey: routed.connectKey)
      _ = reason
      return try await fallback.dispatch(plan, progress: progress)
    } catch DeviceShellChannelError.outcomeUnknown(let reason) {
      // The gesture was written and may well have been carried out. Retrying
      // it on the spawning path could inject it a second time, so this is
      // where the caller inherits an unknown outcome.
      close(connectKey: routed.connectKey)
      throw RuntimeDispatchFailure.outcomeUnknown("pointer injection outcome unknown: \(reason)")
    }
  }

  // MARK: - Internals

  struct RoutedPointerInput: Equatable {
    let connectKey: String
    let command: [String]
    let timeoutSeconds: TimeInterval
  }

  /// Recognises the one plan shape this may carry: a single descriptor-bound
  /// `hdc -t <key> shell <bare tokens>` for pointer injection. Anything else -
  /// another action, a sequence, a host landing, an argument the shell would
  /// not read back unchanged - is left to the spawning path rather than
  /// approximated here.
  static func routable(_ plan: TypedProcessPlan) -> RoutedPointerInput? {
    guard case .hdc(.injectPointerInput) = plan.action,
      plan.hostLanding == nil,
      case .process(_, let argv, let timeoutSeconds) = plan.kind,
      argv.count > 4, argv[0] == "-t", argv[2] == "shell"
    else { return nil }
    let command = Array(argv.dropFirst(3))
    guard !argv[1].isEmpty,
      command.allSatisfy(PersistentDeviceShellChannel.isBareToken)
    else { return nil }
    return RoutedPointerInput(
      connectKey: argv[1], command: command,
      timeoutSeconds: timeoutSeconds.map(TimeInterval.init) ?? 30)
  }

  private func openedChannel(connectKey: String) throws -> PersistentDeviceShellChannel {
    if let existing = channels[connectKey] {
      if existing.channel.isAlive { return existing.channel }
      existing.channel.close()
      channels[connectKey] = nil
    }
    let executable = try resolver.resolveExecutable(providerID: "hdc")
    let channel = try PersistentDeviceShellChannel.open(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: URL(filePath: executable.path),
          arguments: ["-t", connectKey, "shell"],
          environment: childEnvironment),
        expectedSHA256: executable.sha256))
    channels[connectKey] = OpenChannel(channel: channel, lastUsed: now())
    return channel
  }

  /// Arms the next sweep. Re-armed on every use, so the timer always measures
  /// from the last gesture rather than from the first.
  private func scheduleSweep() {
    sweep?.cancel()
    let delay = idleTimeout
    sweep = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.expireIdleChannels()
    }
  }

  private func expireIdleChannels() {
    let cutoff = now().addingTimeInterval(-idleTimeout)
    for (key, open) in channels where open.lastUsed < cutoff || !open.channel.isAlive {
      open.channel.close()
      channels[key] = nil
    }
  }

  private func close(connectKey: String) {
    channels[connectKey]?.channel.close()
    channels[connectKey] = nil
  }

  package func closeAllChannels() {
    sweep?.cancel()
    sweep = nil
    for (_, open) in channels { open.channel.close() }
    channels.removeAll()
  }

  /// Whether a channel is currently held for this device. Lets a test observe
  /// the idle close without reaching into the actor's storage.
  package func holdsChannel(connectKey: String) -> Bool {
    channels[connectKey]?.channel.isAlive == true
  }
}
