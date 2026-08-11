import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

public enum HeadlessHDCServerHostError: Error, Equatable, Sendable {
  case serverDidNotBecomeReady(String)
}

/// Owns the loopback HDC server needed by a login-session LaunchAgent.
///
/// HDC's ordinary client-side background bootstrap is not durable under the
/// daemon's bounded process executor: on macOS it can remain attached to the
/// client until that client reaches its timeout, leaving no listener behind.
/// The supported foreground form gives launchd one real child lifecycle to
/// own. No caller supplies argv, endpoint, executable path or environment.
package final class HeadlessHDCServerHost: @unchecked Sendable {
  private final class Lifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var exited = false
    private var stopping = false

    func arm() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !exited, !stopping else { return false }
      armed = true
      return true
    }

    func requestStop() {
      lock.lock()
      stopping = true
      lock.unlock()
    }

    func recordExit() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      exited = true
      return armed && !stopping
    }
  }

  private let task: Task<Void, Never>
  private let lifecycle: Lifecycle

  private init(task: Task<Void, Never>, lifecycle: Lifecycle) {
    self.task = task
    self.lifecycle = lifecycle
  }

  public static func start(
    executable: ResolvedExecutable,
    onUnexpectedExit: @escaping @Sendable () -> Void = {}
  ) async throws -> HeadlessHDCServerHost {
    let selection = try HDCServerEndpointSelector.select()
    let request = foregroundRequest(executable: executable, endpoint: selection)
    let lifecycle = Lifecycle()
    let task = Task.detached {
      _ = try? await FoundationProcessExecutor().executeIdentityBound(
        request, captureLimit: 256 * 1024)
      if lifecycle.recordExit() {
        onUnexpectedExit()
      }
    }
    let host = HeadlessHDCServerHost(task: task, lifecycle: lifecycle)
    do {
      try await awaitReadiness(executable: executable, endpoint: selection)
      guard lifecycle.arm() else {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
          "foreground HDC server exited during readiness")
      }
      return host
    } catch {
      await host.stop()
      throw error
    }
  }

  public func stop() async {
    lifecycle.requestStop()
    task.cancel()
    _ = await task.result
  }

  deinit {
    lifecycle.requestStop()
    task.cancel()
  }

  package static func foregroundRequest(
    executable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection
  ) -> ProcessIdentityBoundRequest {
    ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: URL(fileURLWithPath: executable.path),
        arguments: ["-s", endpoint.endpoint.rawValue, "-m"],
        environment: endpoint.childEnvironment),
      expectedSHA256: executable.sha256)
  }

  package static func readinessPlan(
    endpoint: HDCServerEndpointSelection
  ) -> TypedProcessPlan {
    TypedProcessPlan(
      action: .hdc(.observeServer),
      kind: .process(
        executableSHA256: "resolved-at-dispatch",
        argumentSummary: ["-s", endpoint.endpoint.rawValue, "checkserver"],
        timeoutSeconds: 2))
  }

  private static func awaitReadiness(
    executable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection
  ) async throws {
    let resolver = FixedExecutableResolver(table: ["hdc": executable])
    let dispatcher = DescriptorBoundProcessDispatcher(
      resolver: resolver, childEnvironment: endpoint.childEnvironment)
    let plan = readinessPlan(endpoint: endpoint)
    var lastReason = "no completed server observation"
    for _ in 0..<10 {
      if Task.isCancelled {
        throw CancellationError()
      }
      do {
        let receipt = try await dispatcher.dispatch(plan)
        if receipt.exitStatus == 0, receipt.stderr.isEmpty,
          case .parsed(let check) = HDCObservationSemanticParser.parseServerCheck(
            stdout: receipt.stdout, profile: .openHarmony320Family,
            truncated: receipt.stdoutTruncated),
          check.versionsAgree
        {
          return
        }
        lastReason =
          "checkserver exit=\(receipt.exitStatus.map(String.init) ?? "unknown") "
          + "stdoutBytes=\(receipt.stdout.count) stderrBytes=\(receipt.stderr.count)"
      } catch {
        lastReason = "\(error)"
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HeadlessHDCServerHostError.serverDidNotBecomeReady(lastReason)
  }
}
