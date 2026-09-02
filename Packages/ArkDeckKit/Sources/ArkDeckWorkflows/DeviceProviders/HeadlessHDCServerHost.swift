import ArkDeckOpenHarmony
import ArkDeckProcess
import Darwin
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
    private var exitReason: String?
    private var stopping = false
    private var launch: HDCManagedProcessLaunch?
    private var confirmedLifecycleExitDeadline: UInt64?

    func recordLaunch(pid: Int32, executable: ProcessExecutableIdentityReceipt, request: ProcessRequest) {
      let captured = HDCManagedProcessLaunch.capture(pid: pid, executable: executable, request: request)
      lock.withLock { if launch == nil, !exited, !stopping { launch = captured } }
    }

    func activeLaunch() -> HDCManagedProcessLaunch? {
      lock.withLock { armed && !exited && !stopping ? launch : nil }
    }

    func retainedLaunch() -> HDCManagedProcessLaunch? {
      lock.withLock { !exited && !stopping ? launch : nil }
    }

    func expectConfirmedLifecycleExit() {
      lock.withLock {
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds
          .addingReportingOverflow(20_000_000_000)
        confirmedLifecycleExitDeadline = overflow ? UInt64.max : deadline
      }
    }

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

    func recordExit(reason: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      exited = true
      exitReason = reason
      launch = nil
      let expected = confirmedLifecycleExitDeadline.map {
        DispatchTime.now().uptimeNanoseconds <= $0
      } ?? false
      return armed && !stopping && !expected
    }

    func recordedExitReason() -> String? {
      lock.lock()
      defer { lock.unlock() }
      return exitReason
    }
  }

  private let task: Task<Void, Never>
  private let lifecycle: Lifecycle
  private let executable: ResolvedExecutable
  private let endpoint: HDCServerEndpointSelection
  private let supervisor: HDCServerSupervisor
  private let lifecycleAuditRouter: RuntimeHDCControlLifecycleAuditRouter
  package let diagnostics: HDCManagedRuntimeDiagnostics

  private init(
    task: Task<Void, Never>, lifecycle: Lifecycle,
    diagnostics: HDCManagedRuntimeDiagnostics, executable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection, supervisor: HDCServerSupervisor,
    lifecycleAuditRouter: RuntimeHDCControlLifecycleAuditRouter
  ) {
    self.task = task
    self.lifecycle = lifecycle
    self.diagnostics = diagnostics
    self.executable = executable
    self.endpoint = endpoint
    self.supervisor = supervisor
    self.lifecycleAuditRouter = lifecycleAuditRouter
  }

  public static func start(
    executable: ResolvedExecutable,
    onUnexpectedExit: @escaping @Sendable () -> Void = {}
  ) async throws -> HeadlessHDCServerHost {
    let selection = try HDCServerEndpointSelector.select()
    return try await start(
      executable: executable, endpoint: selection, onUnexpectedExit: onUnexpectedExit)
  }

  package static func start(
    executable: ResolvedExecutable,
    endpoint selection: HDCServerEndpointSelection,
    onUnexpectedExit: @escaping @Sendable () -> Void = {}
  ) async throws -> HeadlessHDCServerHost {
    try await startInternal(
      executable: executable, endpoint: selection,
      permitsUnregisteredTestFixture: false, onUnexpectedExit: onUnexpectedExit)
  }

  /// Package-test seam for the local fake executable. It still proves the
  /// retained identity-bound spawn, process birth, fixed argv and listener,
  /// but deliberately leaves the Supervisor lifecycle-ineligible because the
  /// fixture has no published native health/identity family.
  package static func startTestFixture(
    executable: ResolvedExecutable,
    endpoint selection: HDCServerEndpointSelection,
    onUnexpectedExit: @escaping @Sendable () -> Void = {}
  ) async throws -> HeadlessHDCServerHost {
    try await startInternal(
      executable: executable, endpoint: selection,
      permitsUnregisteredTestFixture: true, onUnexpectedExit: onUnexpectedExit)
  }

  private static func startInternal(
    executable: ResolvedExecutable,
    endpoint selection: HDCServerEndpointSelection,
    permitsUnregisteredTestFixture: Bool,
    onUnexpectedExit: @escaping @Sendable () -> Void
  ) async throws -> HeadlessHDCServerHost {
    let request = foregroundRequest(executable: executable, endpoint: selection)
    let lifecycle = Lifecycle()
    let lifecycleAuditRouter = RuntimeHDCControlLifecycleAuditRouter()
    let supervisor = HDCServerSupervisor(
      auditStore: lifecycleAuditRouter, endpoint: selection.endpoint,
      participantImpactReliable: false)
    guard let managedStartAuthorization = await supervisor.authorizeManagedStart(
      at: selection.endpoint)
    else {
      throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
        "managed HDC endpoint was not absent before the foreground launch")
    }
    let task = Task.detached {
      let reason: String
      do {
        let executor = FoundationProcessExecutor(identityBoundPreSpawnHook: { _ in }, launchObserver: { _ in },
          identityBoundSpawnObserver: { identity, request, pid in lifecycle.recordLaunch(pid: pid, executable: identity, request: request) })
        let result = try await executor.executeIdentityBound(
          request, captureLimit: 256 * 1024)
        reason = foregroundExitReason(result.execution.termination)
      } catch {
        // The process boundary can include an authorized executable pathname.
        // Startup callers need the outcome class, never that pathname.
        reason = "foreground HDC server launch was refused"
      }
      if lifecycle.recordExit(reason: reason) {
        onUnexpectedExit()
      }
    }
    do {
      let check = try await awaitReadiness(
        executable: executable, endpoint: selection, lifecycle: lifecycle)
      guard let launch = lifecycle.retainedLaunch() else {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
          "managed HDC launch identity was not retained")
      }
      let toolchain = HDCCandidate(
        path: URL(filePath: executable.path), source: .userConfigured,
        sha256: executable.sha256)
      let identity: HDCServerProcessIdentityReceipt?
      if permitsUnregisteredTestFixture {
        identity = HDCServerProcessIdentityReceipt(
          pid: launch.pid, startSeconds: launch.startSeconds,
          startMicroseconds: launch.startMicroseconds,
          executablePath: URL(filePath: launch.executablePath),
          executableSHA256: launch.executableSHA256, endpoint: selection.endpoint)
      } else {
        let observation = await HDCCommandlessServerIdentity.observe(
          toolchain: toolchain, endpoint: selection.endpoint)
        identity = observation.identity
      }
      guard let identity, let generation = identity.stableGeneration,
        identity.stableGeneration == generation,
        launch.matches(identity),
        HDCCommandlessServerIdentity.verifiesManagedProcess(
          identity, arguments: launch.arguments),
        await supervisor.recordManagedStart(
          authorization: managedStartAuthorization,
          evidence: HDCManagedServerLaunchEvidence(
            endpoint: selection.endpoint, pid: identity.pid,
            toolPath: identity.executablePath, arguments: launch.arguments,
            generation: generation, version: .known(check.serverVersion)))
      else {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
          "managed HDC launch could not be bound to its live process identity")
      }
      if permitsUnregisteredTestFixture {
        await supervisor.setParticipantImpactReliability(false, for: selection.endpoint)
      } else {
        // hdc 3.2.0f publishes the commandless identity family (0.6.0) and no
        // checkserver golden; 3.2.0d publishes the read-only checkserver
        // family (0.3.0). Bind through the family the selected tool belongs
        // to, as the App facade does: gating every tool on the 0.3.0 registry
        // meant a daemon launching 3.2.0f could never establish its own
        // server's health and restarted forever.
        let processSupervisor = HDCServerProcessSupervisor(supervisor: supervisor)
        let registered: HDCRegisteredServerObservationResult
        if HDCServerProcessSupervisor.selectsCommandlessFamily(toolchain) {
          registered = await processSupervisor.observeManagedCommandlessServer(
            endpoint: selection, toolchain: toolchain, serverVersion: check.serverVersion)
        } else {
          registered = await processSupervisor.observeRegisteredExistingServer(
            endpoint: selection, toolchain: toolchain)
        }
        guard case .observed(let registeredGeneration, let registeredVersion) = registered.classification,
          registeredGeneration == generation, registeredVersion == check.serverVersion,
          let state = await supervisor.state(for: selection.endpoint),
          state.health == .healthy, state.generation == generation,
          state.ownership == .arkDeckManaged
        else {
          throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
            "managed HDC Supervisor could not establish registered health and generation")
        }
      }
      let host = HeadlessHDCServerHost(
        task: task, lifecycle: lifecycle,
        diagnostics: HDCManagedRuntimeDiagnostics(
          executableSHA256: executable.sha256,
          clientVersion: check.clientVersion,
          serverVersion: check.serverVersion,
          endpoint: selection.endpoint.rawValue,
          endpointSource: selection.source.rawValue), executable: executable, endpoint: selection,
        supervisor: supervisor, lifecycleAuditRouter: lifecycleAuditRouter)
      guard lifecycle.arm() else {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(
          lifecycle.recordedExitReason() ?? "foreground HDC server exited during readiness")
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

  package func controlImpactSource(engine: RuntimeJobEngine, targets: RuntimeTargetStore,
    observations: TargetObservationCoordinator) -> any HDCControlImpactObserving {
    HeadlessHDCControlImpactSource(executable: executable, endpoint: endpoint,
      managedLaunch: { [lifecycle] in lifecycle.activeLaunch() }, engine: engine,
      targets: targets, observations: observations, supervisor: supervisor)
  }

  package func controlLifecycleDriver(
    engine: RuntimeJobEngine, targets: RuntimeTargetStore,
    observations: TargetObservationCoordinator
  ) -> any HDCControlLifecycleDriving {
    HeadlessHDCControlLifecycleDriver(
      executable: executable, endpoint: endpoint,
      expectConfirmedLifecycleExit: { [lifecycle] in lifecycle.expectConfirmedLifecycleExit() },
      engine: engine,
      supervisor: supervisor, auditRouter: lifecycleAuditRouter)
  }

  package func toolSelectionLifecycleDriver(
    engine: RuntimeJobEngine,
    registry: any RuntimeToolSelectionRegistryControlling,
    requestDaemonRecomposition: @escaping @Sendable () -> Void
  ) -> any RuntimeToolSelectionLifecycleDriving {
    HeadlessHDCToolSelectionLifecycleDriver(
      oldExecutable: executable, endpoint: endpoint, engine: engine,
      supervisor: supervisor, auditRouter: lifecycleAuditRouter,
      expectConfirmedLifecycleExit: { [lifecycle] in
        lifecycle.expectConfirmedLifecycleExit()
      }, registry: registry,
      requestDaemonRecomposition: requestDaemonRecomposition)
  }

  package func statusObserver(daemonVersion: String?) -> any HDCStatusObserving {
    HeadlessHDCStatusObserver(executable: executable, startup: diagnostics, daemonVersion: daemonVersion,
      managedLaunch: { [lifecycle] in lifecycle.activeLaunch() }, supervisor: supervisor)
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

  private static func foregroundExitReason(_ termination: ProcessTermination) -> String {
    switch termination {
    case .exited(let status):
      return "foreground HDC server exited with status \(status)"
    case .signalled(let signal):
      return "foreground HDC server exited after signal \(signal)"
    case .timedOut:
      return "foreground HDC server exceeded its lifecycle bound"
    case .cancelled:
      return "foreground HDC server was cancelled"
    case .waitFailed(let code), .unrecognizedWaitStatus(let code):
      return "foreground HDC server wait status was unresolved (\(code))"
    }
  }

  private static func awaitReadiness(
    executable: ResolvedExecutable,
    endpoint: HDCServerEndpointSelection,
    lifecycle: Lifecycle
  ) async throws -> HDCParsedServerCheck {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))

    // An HDC client automatically bootstraps a background server when no
    // listener exists. Running checkserver while the managed `-m` process is
    // still binding can therefore create a competing server and keep the
    // bounded probe attached until timeout. Establish the loopback listener
    // fact first; the semantic HDC probe below still proves that the listener
    // is the compatible server we launched.
    var listenerIsReachable = false
    while clock.now < deadline {
      if Task.isCancelled {
        throw CancellationError()
      }
      if let reason = lifecycle.recordedExitReason() {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(reason)
      }
      if loopbackListenerIsReachable(endpoint: endpoint.endpoint) {
        listenerIsReachable = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard listenerIsReachable else {
      let reason = lifecycle.recordedExitReason()
        ?? "foreground HDC loopback listener did not become reachable before startup deadline"
      throw HeadlessHDCServerHostError.serverDidNotBecomeReady(reason)
    }

    let resolver = FixedExecutableResolver(table: ["hdc": executable])
    let dispatcher = DescriptorBoundProcessDispatcher(
      resolver: resolver, childEnvironment: endpoint.childEnvironment)
    let plan = readinessPlan(endpoint: endpoint)
    var lastReason = "no completed server observation"
    while clock.now < deadline {
      if Task.isCancelled {
        throw CancellationError()
      }
      if let reason = lifecycle.recordedExitReason() {
        throw HeadlessHDCServerHostError.serverDidNotBecomeReady(reason)
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

  /// A bounded, nonblocking reachability probe for the selector's loopback
  /// endpoint. It establishes only that a listener exists; HDC identity and
  /// version remain gated by the registered checkserver semantic parser.
  package static func loopbackListenerIsReachable(endpoint: HDCServerEndpoint) -> Bool {
    guard let separator = endpoint.rawValue.lastIndex(of: ":"),
      endpoint.rawValue[..<separator] == "127.0.0.1",
      let port = UInt16(endpoint.rawValue[endpoint.rawValue.index(after: separator)...])
    else { return false }

    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&pollDescriptor, 1, 100) == 1 else { return false }
    var socketError: Int32 = 0
    var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(
      descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0
    else { return false }
    return socketError == 0
  }
}
