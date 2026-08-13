import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

public enum HeadlessHDCServerHostError: Error, Equatable, Sendable {
  case serverDidNotBecomeReady(String)
}

/// Immutable, path-free facts established before the daemon opens either of
/// its client transports. The App can consume this projection without gaining
/// an executable locator, argv surface, or lifecycle handle.
public struct HDCManagedRuntimeDiagnostics: Sendable, Equatable {
  public let executableSHA256: String
  public let clientVersion: String
  public let serverVersion: String
  public let endpoint: String
  public let endpointSource: String

  public init(
    executableSHA256: String,
    clientVersion: String,
    serverVersion: String,
    endpoint: String,
    endpointSource: String
  ) {
    self.executableSHA256 = executableSHA256
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.endpoint = endpoint
    self.endpointSource = endpointSource
  }
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
  package let diagnostics: HDCManagedRuntimeDiagnostics

  private init(
    task: Task<Void, Never>, lifecycle: Lifecycle,
    diagnostics: HDCManagedRuntimeDiagnostics
  ) {
    self.task = task
    self.lifecycle = lifecycle
    self.diagnostics = diagnostics
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
    do {
      let check = try await awaitReadiness(executable: executable, endpoint: selection)
      let host = HeadlessHDCServerHost(
        task: task, lifecycle: lifecycle,
        diagnostics: HDCManagedRuntimeDiagnostics(
          executableSHA256: executable.sha256,
          clientVersion: check.clientVersion,
          serverVersion: check.serverVersion,
          endpoint: selection.endpoint.rawValue,
          endpointSource: selection.source.rawValue))
      guard lifecycle.arm() else {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
          "foreground HDC server exited during readiness")
      }
      return host
    } catch {
      lifecycle.requestStop()
      task.cancel()
      _ = await task.result
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
        executable: URL(filePath: executable.path),
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
  ) async throws -> HDCParsedServerCheck {
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
          return check
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
