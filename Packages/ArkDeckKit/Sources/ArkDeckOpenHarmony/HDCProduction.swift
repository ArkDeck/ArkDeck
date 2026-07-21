import ArkDeckProcess
import CryptoKit
import Foundation

/// The HDC port deliberately models endpoint selection as data.  Selection is
/// overlaid on an ArkDeck-owned child process only; it never writes the user's
/// shell or launchd environment.
public enum HDCServerEndpointSource: String, Sendable, Equatable {
  case explicit
  case inheritedEnvironment
  case `default`
}

public enum HDCServerEndpointSelectionError: Error, Sendable, Equatable {
  case invalidExplicitEndpoint(String)
  case invalidInheritedPort(String)
}

public struct HDCServerEndpointSelection: Sendable, Equatable {
  public static let defaultPort = 8710

  public let endpoint: HDCServerEndpoint
  public let source: HDCServerEndpointSource
  public let childEnvironment: [String: String]

  public init(
    endpoint: HDCServerEndpoint,
    source: HDCServerEndpointSource,
    childEnvironment: [String: String]
  ) {
    self.endpoint = endpoint
    self.source = source
    self.childEnvironment = childEnvironment
  }

  /// `OHOS_HDC_SERVER_PORT` selects only a port. Preserve an explicitly
  /// selected host as well by binding endpoint-sensitive read-only probes to
  /// the registered `-s <endpoint>` form.
  func argumentsForEndpointSensitiveProbe(_ arguments: [String]) -> [String] {
    guard source == .explicit else { return arguments }
    return ["-s", endpoint.rawValue] + arguments
  }
}

public enum HDCServerEndpointSelector {
  /// Explicit endpoint wins, followed by the inherited HDC port, then the
  /// documented default.  The inherited environment is an input snapshot, not
  /// a global process mutation.
  public static func select(
    explicitEndpoint: String? = nil,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> HDCServerEndpointSelection {
    if let explicitEndpoint {
      guard let port = port(in: explicitEndpoint) else {
        throw HDCServerEndpointSelectionError.invalidExplicitEndpoint(explicitEndpoint)
      }
      return HDCServerEndpointSelection(
        endpoint: HDCServerEndpoint(explicitEndpoint),
        source: .explicit,
        childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)]
      )
    }

    if let inheritedPort = inheritedEnvironment["OHOS_HDC_SERVER_PORT"] {
      guard let port = validPort(inheritedPort) else {
        throw HDCServerEndpointSelectionError.invalidInheritedPort(inheritedPort)
      }
      return HDCServerEndpointSelection(
        endpoint: HDCServerEndpoint("127.0.0.1:\(port)"),
        source: .inheritedEnvironment,
        childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)]
      )
    }

    return HDCServerEndpointSelection(
      endpoint: HDCServerEndpoint("127.0.0.1:\(HDCServerEndpointSelection.defaultPort)"),
      source: .default,
      childEnvironment: ["OHOS_HDC_SERVER_PORT": String(HDCServerEndpointSelection.defaultPort)]
    )
  }

  private static func port(in endpoint: String) -> Int? {
    guard !endpoint.contains("\0"),
      let separator = endpoint.lastIndex(of: ":"),
      separator != endpoint.startIndex,
      separator < endpoint.index(before: endpoint.endIndex)
    else { return nil }
    return validPort(String(endpoint[endpoint.index(after: separator)...]))
  }

  private static func validPort(_ value: String) -> Int? {
    guard let port = Int(value), (1...65_535).contains(port) else { return nil }
    return port
  }
}

/// Module-internal process request. The public HDC surface never exposes an
/// argv-bearing command: production callers use only registered probes with
/// their required identity preconditions, while lifecycle argv is assembled
/// only by the confirmed executor. Legacy `checkserver`/`-v` entry points stay
/// internal for package compatibility contracts.
/// It intentionally has no fallback to PATH or a settings object.
package enum HDCProcessDispatchOrigin: Sendable, Equatable {
  case readOnlyProbe
  case confirmedLifecycle
  case automaticLifecycle
  case automaticSubserver
  case testControl

  var automaticDispatchKind: HDCAutomaticDispatchKind? {
    switch self {
    case .automaticLifecycle: .lifecycle
    case .automaticSubserver: .subserver
    case .readOnlyProbe, .confirmedLifecycle, .testControl: nil
    }
  }
}

struct HDCProcessCommand: Sendable, Equatable {
  let toolchain: HDCCandidate
  let endpoint: HDCServerEndpointSelection
  let arguments: [String]
  /// Extra values are child-only diagnostics/test inputs. The selected HDC
  /// endpoint is always written last and cannot be overridden here.
  let additionalChildEnvironment: [String: String]
  let timeout: TimeInterval?
  /// A closed, mandatory origin keeps future call sites from silently omitting
  /// automatic instrumentation. Current production uses only read-only probes
  /// and explicitly confirmed lifecycle dispatch.
  let dispatchOrigin: HDCProcessDispatchOrigin

  init(
    toolchain: HDCCandidate,
    endpoint: HDCServerEndpointSelection,
    arguments: [String],
    additionalChildEnvironment: [String: String] = [:],
    timeout: TimeInterval? = nil,
    dispatchOrigin: HDCProcessDispatchOrigin
  ) {
    self.toolchain = toolchain
    self.endpoint = endpoint
    self.arguments = arguments
    self.additionalChildEnvironment = additionalChildEnvironment
    self.timeout = timeout
    self.dispatchOrigin = dispatchOrigin
  }

  var processRequest: ProcessRequest {
    var childEnvironment = additionalChildEnvironment
    childEnvironment.merge(endpoint.childEnvironment) { _, selectedEndpointValue in
      selectedEndpointValue
    }
    return ProcessRequest(
      executable: toolchain.path,
      arguments: arguments,
      environment: childEnvironment,
      timeout: timeout
    )
  }
}

enum HDCProcessCommandError: Error, Sendable, Equatable {
  case toolchainIdentityChanged(path: String)
  case registeredSemanticProfileMismatch
}

/// The command family is selected before a process starts.  A successful
/// result cannot be borrowed by a different HDC command.
public enum HDCRegisteredCommandFamily: Sendable, Equatable {
  case uninstall
  case checkserver
  case version
  case selectedDeviceAuthorization
  /// Lifecycle output has no registered success byte family. A successful
  /// mutation is proved only by the post-dispatch server observation.
  case lifecycleRestart
  case lifecycleStop
  case unregistered
}

/// Fingerprints registered by OPENHARMONY-TOOLS@0.2.0 / Golden 1.0.0.  These
/// constants deliberately change only through the integration-change process
/// that updates the read-only Golden registry.
enum HDCRegisteredGoldenFingerprint {
  static let uninstallSuccessSHA256 =
    "c690501211bc9c7a6a3b37704dd2cd58bdcf03e49771ffee10adf205a589d353"
  static let checkserverHealthySHA256 =
    "50e8dfe03cb770dfade5b91198523b964fd3bd6fd8855b541ceb46201f0d014a"
  static let versionSHA256 =
    "906d35a917937ecbb33d8dc3bbb6b3e1783bd2996a6201ab7227fb406d474ed9"

  static func matches(_ data: Data, sha256: String) -> Bool {
    matches(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sha256: sha256)
  }

  static func matches(_ actualSHA256: String, sha256: String) -> Bool {
    actualSHA256 == sha256
  }
}

/// A semantic family is authority-bearing only as one complete integration
/// profile binding. Production fixes this value to the executable identity
/// registered by OPENHARMONY-TOOLS@0.3.0. Tests that execute the repository
/// fixture must opt in to the explicitly named fake profile rather than
/// teaching the production classifier to trust the fixture's SHA.
package struct HDCRegisteredSemanticProfile: Sendable, Equatable {
  package enum Authority: Sendable, Equatable {
    case pinnedProduction
    case testOnlyFake
  }

  package static let pinnedProduction = HDCRegisteredSemanticProfile(
    authority: .pinnedProduction,
    integrationProfile: HDCReadOnlyProbeRegistry.integrationProfile,
    toolVersion: HDCReadOnlyProbeRegistry.targetToolVersion,
    targetExecutableSHA256: HDCReadOnlyProbeRegistry.targetExecutableSHA256,
    selectedDeviceAuthorizationSHA256: HDCReadOnlyProbeRegistry.pinnedProduction
      .entry(for: .selectedDeviceAuthorizationBinding).rawSHA256)

  package let authority: Authority
  package let integrationProfile: String
  package let toolVersion: String
  package let targetExecutableSHA256: String

  private let uninstallSuccessSHA256: String
  private let checkserverHealthySHA256: String
  private let versionSHA256: String
  private let selectedDeviceAuthorizationSHA256: String?

  private init(
    authority: Authority,
    integrationProfile: String,
    toolVersion: String,
    targetExecutableSHA256: String,
    selectedDeviceAuthorizationSHA256: String?
  ) {
    self.authority = authority
    self.integrationProfile = integrationProfile
    self.toolVersion = toolVersion
    self.targetExecutableSHA256 = targetExecutableSHA256
    uninstallSuccessSHA256 = HDCRegisteredGoldenFingerprint.uninstallSuccessSHA256
    checkserverHealthySHA256 = HDCRegisteredGoldenFingerprint.checkserverHealthySHA256
    versionSHA256 = HDCRegisteredGoldenFingerprint.versionSHA256
    self.selectedDeviceAuthorizationSHA256 = selectedDeviceAuthorizationSHA256
  }

  /// Available to package contract composition only. Production initializers
  /// never select this authority and always use `pinnedProduction`.
  package static func testOnlyFake(
    executableSHA256: String,
    selectedDeviceAuthorizationSHA256: String
  ) -> Self {
    HDCRegisteredSemanticProfile(
      authority: .testOnlyFake,
      integrationProfile: HDCReadOnlyProbeRegistry.integrationProfile,
      toolVersion: HDCReadOnlyProbeRegistry.targetToolVersion,
      targetExecutableSHA256: executableSHA256,
      selectedDeviceAuthorizationSHA256: selectedDeviceAuthorizationSHA256)
  }

  package func matchesSelectedDeviceAuthorizationRawSHA256(_ sha256: String?) -> Bool {
    selectedDeviceAuthorizationSHA256 == sha256
  }

  fileprivate func binding(
    descriptorSHA256: String,
    commandFamily: HDCRegisteredCommandFamily
  ) -> HDCRegisteredSemanticBinding? {
    guard integrationProfile == HDCReadOnlyProbeRegistry.integrationProfile,
      toolVersion == HDCReadOnlyProbeRegistry.targetToolVersion,
      descriptorSHA256 == targetExecutableSHA256,
      commandFamily != .unregistered
    else { return nil }

    let expectedStdoutSHA256: String?
    switch commandFamily {
    case .uninstall:
      expectedStdoutSHA256 = uninstallSuccessSHA256
    case .checkserver:
      expectedStdoutSHA256 = checkserverHealthySHA256
    case .version:
      expectedStdoutSHA256 = versionSHA256
    case .selectedDeviceAuthorization:
      expectedStdoutSHA256 = selectedDeviceAuthorizationSHA256
    case .lifecycleRestart, .lifecycleStop:
      expectedStdoutSHA256 = nil
    case .unregistered:
      return nil
    }
    return HDCRegisteredSemanticBinding(
      integrationProfile: integrationProfile,
      toolVersion: toolVersion,
      executableSHA256: descriptorSHA256,
      commandFamily: commandFamily,
      expectedStdoutSHA256: expectedStdoutSHA256)
  }
}

private struct HDCRegisteredSemanticBinding: Sendable, Equatable {
  let integrationProfile: String
  let toolVersion: String
  let executableSHA256: String
  let commandFamily: HDCRegisteredCommandFamily
  let expectedStdoutSHA256: String?
}

/// Integration-profile-registered command-result evaluator. It preserves the
/// legacy parser's conservative failure precedence, then accepts success only
/// for the registered uninstall command's byte-exact stdout capture. Marker
/// fragments never promote an unregistered command or raw output to success.
public struct HDCRegisteredSemanticEvaluator: ProcessSemanticEvaluating {
  public typealias SemanticResult = HDCCommandSemanticResult

  private let binding: HDCRegisteredSemanticBinding?
  private var legacy = HDCSemanticOutputParser()
  private var stdoutHasher = SHA256()
  private var containsStderr = false

  public init(commandFamily: HDCRegisteredCommandFamily = .unregistered) {
    // A command-family label supplied without the registered executable,
    // profile version, argv shape, and raw family is deliberately untrusted.
    // Keep this public compatibility initializer fail-closed.
    binding = nil
  }

  fileprivate init(binding: HDCRegisteredSemanticBinding?) {
    self.binding = binding
  }

  package init(
    semanticProfile: HDCRegisteredSemanticProfile,
    descriptorSHA256: String,
    arguments: [String]
  ) {
    binding = semanticProfile.binding(
      descriptorSHA256: descriptorSHA256,
      commandFamily: hdcRegisteredCommandFamily(arguments: arguments))
  }

  public mutating func consume(_ chunk: ProcessOutputChunk) {
    legacy.consume(chunk)
    switch chunk.stream {
    case .stdout:
      // The process layer retains a bounded raw capture.  The semantic gate
      // streams its fingerprint too, so a large output cannot turn this
      // adapter into an unbounded second capture.
      stdoutHasher.update(data: chunk.bytes)
    case .stderr:
      containsStderr = containsStderr || !chunk.bytes.isEmpty
    }
  }

  public mutating func finish(execution: ProcessExecutionResult) -> HDCCommandSemanticResult {
    guard case .exited(let code) = execution.termination else {
      // A timeout, cancellation, signal, or wait failure cannot become a
      // semantic success. The existing closed vocabulary uses this conservative
      // failure classification without inventing a new parser family.
      return .failure(.explicitFailureMarker)
    }
    let legacyResult = legacy.finish(exitCode: code)
    if case .failure = legacyResult { return legacyResult }
    guard code == 0 else { return .failure(.nonZeroExit(code)) }
    guard let binding else { return .unknownOutput }
    switch binding.commandFamily {
    case .uninstall:
      return !containsStderr
        && HDCRegisteredGoldenFingerprint.matches(
          stdoutHasher.finalize().map { String(format: "%02x", $0) }.joined(),
          sha256: binding.expectedStdoutSHA256 ?? "")
        ? .success
        : .unknownOutput
    case .version:
      return !containsStderr
        && HDCRegisteredGoldenFingerprint.matches(
          stdoutHasher.finalize().map { String(format: "%02x", $0) }.joined(),
          sha256: binding.expectedStdoutSHA256 ?? "")
        ? .success
        : .unknownOutput
    case .checkserver, .selectedDeviceAuthorization, .lifecycleRestart, .lifecycleStop,
      .unregistered:
      return .unknownOutput
    }
  }
}

/// Bridges the process port to HDC semantic evaluation.  The raw captures are
/// returned unchanged by `ProcessExecutionResult`; this adapter never decodes,
/// redacts, or overwrites them.
private final class HDCPreparedProcessCommand: @unchecked Sendable {
  let process: ProcessPreparedIdentityBoundLaunch
  fileprivate let semanticBinding: HDCRegisteredSemanticBinding?
  fileprivate let dispatchOrigin: HDCProcessDispatchOrigin
  private let securityScopedAccess: HDCSecurityScopedExecutableAccess

  init(
    process: ProcessPreparedIdentityBoundLaunch,
    semanticBinding: HDCRegisteredSemanticBinding?,
    dispatchOrigin: HDCProcessDispatchOrigin,
    securityScopedAccess: HDCSecurityScopedExecutableAccess
  ) {
    self.process = process
    self.semanticBinding = semanticBinding
    self.dispatchOrigin = dispatchOrigin
    self.securityScopedAccess = securityScopedAccess
  }

  func close() {
    process.close()
    securityScopedAccess.stop()
  }

  deinit { close() }
}

package final class HDCProcessCommandRunner: @unchecked Sendable {
  private let executor: FoundationProcessExecutor
  private let semanticProfile: HDCRegisteredSemanticProfile
  private let automaticDispatchInstrumentation: HDCAutomaticDispatchInstrumentation

  package init(
    executor: FoundationProcessExecutor = FoundationProcessExecutor(),
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    automaticDispatchInstrumentation: HDCAutomaticDispatchInstrumentation =
      HDCAutomaticDispatchInstrumentation()
  ) {
    self.executor = executor
    self.semanticProfile = semanticProfile
    self.automaticDispatchInstrumentation = automaticDispatchInstrumentation
  }

  func execute(
    _ command: HDCProcessCommand,
    launchGate: ProcessAtomicLaunchGate? = nil,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult> {
    let prepared = try prepare(command)
    defer { prepared.close() }
    if let launchGate {
      return try await executePrepared(
        prepared, launchGate: launchGate, onOutput: onOutput)
    }
    if let automaticDispatchKind = prepared.dispatchOrigin.automaticDispatchKind {
      await automaticDispatchInstrumentation.record(automaticDispatchKind)
    }
    return try await executor.executePreparedIdentityBoundLaunch(
      prepared.process,
      evaluating: HDCRegisteredSemanticEvaluator(binding: prepared.semanticBinding),
      onOutput: onOutput)
  }

  fileprivate func prepare(_ command: HDCProcessCommand) throws -> HDCPreparedProcessCommand {
    guard
      let access = try? HDCSecurityScopedExecutableAccess(
        path: command.toolchain.path, bookmark: command.toolchain.securityScopedBookmark)
    else {
      throw HDCProcessCommandError.toolchainIdentityChanged(path: command.toolchain.path.path)
    }
    do {
      let prepared = try executor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: command.processRequest, expectedSHA256: command.toolchain.sha256))
      let commandFamily = command.registeredCommandFamily
      let semanticBinding = semanticProfile.binding(
        descriptorSHA256: prepared.executableIdentity.sha256,
        commandFamily: commandFamily)
      guard commandFamily == .unregistered || semanticBinding != nil else {
        prepared.close()
        throw HDCProcessCommandError.registeredSemanticProfileMismatch
      }
      return HDCPreparedProcessCommand(
        process: prepared,
        semanticBinding: semanticBinding,
        dispatchOrigin: command.dispatchOrigin,
        securityScopedAccess: access)
    } catch {
      access.stop()
      throw error
    }
  }

  fileprivate func executePrepared(
    _ prepared: HDCPreparedProcessCommand,
    launchGate: ProcessAtomicLaunchGate,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult> {
    if let automaticDispatchKind = prepared.dispatchOrigin.automaticDispatchKind {
      await automaticDispatchInstrumentation.record(automaticDispatchKind)
    }
    return try await executor.executePreparedIdentityBoundLaunch(
      prepared.process,
      gate: launchGate,
      evaluating: HDCRegisteredSemanticEvaluator(binding: prepared.semanticBinding),
      onOutput: onOutput)
  }
}

extension HDCProcessCommand {
  fileprivate var registeredCommandFamily: HDCRegisteredCommandFamily {
    hdcRegisteredCommandFamily(arguments: arguments)
  }
}

private func hdcRegisteredCommandFamily(arguments: [String]) -> HDCRegisteredCommandFamily {
  guard let first = arguments.first else { return .unregistered }
  switch first {
  case "uninstall" where arguments.count == 2 && !arguments[1].isEmpty: return .uninstall
  case "checkserver" where arguments.count == 1: return .checkserver
  case "-v" where arguments.count == 1: return .version
  case "list" where arguments == ["list", "targets", "-v"]:
    return .selectedDeviceAuthorization
  case "-s":
    guard arguments.count >= 3, !arguments[1].isEmpty else {
      return .unregistered
    }
    if arguments.count == 3, arguments[2] == "checkserver" { return .checkserver }
    guard arguments[2] == "kill" else { return .unregistered }
    if arguments.count == 4, arguments[3] == "-r" { return .lifecycleRestart }
    if arguments.count == 3 { return .lifecycleStop }
    return .unregistered
  default: return .unregistered
  }
}

public enum HDCServerProbeClassification: Sendable, Equatable {
  case healthy(serverVersion: String)
  case mismatchUnverified(clientVersion: String, serverVersion: String)
  case unavailable(reason: String)
  case unknown(reason: String)
}

struct HDCServerProcessProbeResult: Sendable, Equatable {
  let classification: HDCServerProbeClassification
  let execution: ProcessExecutionResult
}

/// A ProcessExecutor-backed client version observation. The value is known
/// only when the exact pinned `hdc -v` stdout family, exit status, and stderr
/// contract all match; callers can use it when building a toolchain snapshot.
struct HDCClientVersionProcessProbeResult: Sendable, Equatable {
  let clientVersion: HDCProbeValue<String>
  let execution: ProcessExecutionResult
}

/// Legacy 0.2.0 client-version parser exercised only by package contracts.
/// It is intentionally not public: `hdc -v` may start a shared server, so a
/// production caller must first satisfy the 0.3.0 commandless existing-server
/// identity precondition through `observeRegisteredExistingServer`.
actor HDCClientVersionProcessProbe {
  private let runner: HDCProcessCommandRunner
  private let additionalChildEnvironment: [String: String]

  init(
    additionalChildEnvironment: [String: String] = [:]
  ) {
    runner = HDCProcessCommandRunner()
    self.additionalChildEnvironment = additionalChildEnvironment
  }

  init(
    runner: HDCProcessCommandRunner,
    additionalChildEnvironment: [String: String] = [:]
  ) {
    self.runner = runner
    self.additionalChildEnvironment = additionalChildEnvironment
  }

  func probe(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate
  ) async -> HDCClientVersionProcessProbeResult {
    do {
      let evaluated = try await runner.execute(
        HDCProcessCommand(
          toolchain: toolchain, endpoint: endpoint, arguments: ["-v"],
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10,
          dispatchOrigin: .readOnlyProbe))
      guard evaluated.execution.termination == .exited(0),
        evaluated.execution.stderr.totalByteCount == 0,
        evaluated.semantic == .success,
        let version = parsePinnedClientVersion(evaluated.execution.stdout.data)
      else {
        return HDCClientVersionProcessProbeResult(
          clientVersion: .unknown(reason: "hdc -v output is outside the registered pinned family"),
          execution: evaluated.execution)
      }
      return HDCClientVersionProcessProbeResult(
        clientVersion: .known(version), execution: evaluated.execution)
    } catch {
      let execution = ProcessExecutionResult(
        termination: .waitFailed(-1),
        stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
        stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false))
      return HDCClientVersionProcessProbeResult(
        clientVersion: .unknown(reason: "hdc -v process could not run"), execution: execution)
    }
  }

  private func parsePinnedClientVersion(_ data: Data) -> String? {
    let output = String(decoding: data, as: UTF8.self)
    guard output.hasPrefix("Ver: "), output.hasSuffix("\n") else { return nil }
    let value = String(output.dropFirst("Ver: ".count).dropLast())
    guard !value.isEmpty,
      value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else { return nil }
    return value
  }
}

/// Process-backed observation adapter for the host-wide supervisor.  It only
/// runs the registered, read-only `checkserver` probe. Health alone never
/// establishes ownership; the bracketed pre-existing process/listener receipt
/// can classify external only with zero automatic lifecycle dispatches and an
/// observation-minted generation. This adapter cannot claim managed ownership
/// or automatically restart the endpoint.
public actor HDCServerProcessSupervisor {
  private let supervisor: HDCServerSupervisor
  private let runner: HDCProcessCommandRunner
  private let clientVersionProbe: HDCClientVersionProcessProbe
  private let additionalChildEnvironment: [String: String]
  private let readOnlyProbeRegistry: HDCReadOnlyProbeRegistry
  private let semanticProfile: HDCRegisteredSemanticProfile
  private let identityObserver: any HDCServerProcessIdentityObserving

  public init(
    supervisor: HDCServerSupervisor,
    additionalChildEnvironment: [String: String] = [:]
  ) {
    self.supervisor = supervisor
    let semanticProfile = HDCRegisteredSemanticProfile.pinnedProduction
    let runner = HDCProcessCommandRunner(
      semanticProfile: semanticProfile,
      automaticDispatchInstrumentation: supervisor.automaticDispatchInstrumentation)
    self.runner = runner
    clientVersionProbe = HDCClientVersionProcessProbe(
      runner: runner, additionalChildEnvironment: additionalChildEnvironment)
    self.additionalChildEnvironment = additionalChildEnvironment
    readOnlyProbeRegistry = .pinnedProduction
    self.semanticProfile = semanticProfile
    identityObserver = SystemHDCServerProcessIdentityObserver()
  }

  init(
    supervisor: HDCServerSupervisor,
    additionalChildEnvironment: [String: String] = [:],
    readOnlyProbeRegistry: HDCReadOnlyProbeRegistry,
    semanticProfile: HDCRegisteredSemanticProfile,
    identityObserver: any HDCServerProcessIdentityObserving
  ) {
    self.supervisor = supervisor
    let runner = HDCProcessCommandRunner(
      semanticProfile: semanticProfile,
      automaticDispatchInstrumentation: supervisor.automaticDispatchInstrumentation)
    self.runner = runner
    clientVersionProbe = HDCClientVersionProcessProbe(
      runner: runner, additionalChildEnvironment: additionalChildEnvironment)
    self.additionalChildEnvironment = additionalChildEnvironment
    self.readOnlyProbeRegistry = readOnlyProbeRegistry
    self.semanticProfile = semanticProfile
    self.identityObserver = identityObserver
  }

  @discardableResult
  func observeExistingServer(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate
  ) async -> HDCServerProcessProbeResult {
    guard registeredExecutableMatches(toolchain) else {
      let reason = "selected executable is outside the registered semantic profile"
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint, reason: reason)
      return HDCServerProcessProbeResult(
        classification: .unknown(reason: reason), execution: unavailableExecution())
    }
    do {
      let evaluated = try await runner.execute(
        HDCProcessCommand(
          toolchain: toolchain, endpoint: endpoint,
          arguments: endpoint.argumentsForEndpointSensitiveProbe(["checkserver"]),
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10,
          dispatchOrigin: .readOnlyProbe))
      let classification = classifyCheckserver(evaluated.execution, semantic: evaluated.semantic)
      switch classification {
      case .healthy(let serverVersion):
        await supervisor.observeUnidentifiedServer(
          endpoint: endpoint.endpoint, health: .healthy, version: .known(serverVersion),
          reason: "ProcessExecutor checkserver probe")
      case .unavailable(let reason):
        await supervisor.recordUnverifiedServerProbeFailure(
          endpoint: endpoint.endpoint, reason: reason)
      case .mismatchUnverified(let clientVersion, let serverVersion):
        await supervisor.recordUnverifiedServerProbeFailure(
          endpoint: endpoint.endpoint,
          reason: "mismatchUnverified: client \(clientVersion), server \(serverVersion)")
      case .unknown(let reason):
        await supervisor.recordUnverifiedServerProbeFailure(
          endpoint: endpoint.endpoint, reason: reason)
      }
      return HDCServerProcessProbeResult(
        classification: classification, execution: evaluated.execution)
    } catch {
      let execution = ProcessExecutionResult(
        termination: .waitFailed(-1),
        stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
        stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false))
      let classification = HDCServerProbeClassification.unknown(
        reason: "checkserver process could not run")
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint, reason: "checkserver process could not run")
      return HDCServerProcessProbeResult(classification: classification, execution: execution)
    }
  }

  /// Runs the registered read-only `hdc -v` probe through the process port.
  /// This is deliberately separate from `checkserver`: client identity is not
  /// inferred from a caller-built snapshot or server stdout.
  func probeClientVersion(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate
  ) async -> HDCClientVersionProcessProbeResult {
    guard registeredExecutableMatches(toolchain) else {
      return HDCClientVersionProcessProbeResult(
        clientVersion: .unknown(
          reason: "selected executable is outside the registered semantic profile"),
        execution: unavailableExecution())
    }
    return await clientVersionProbe.probe(endpoint: endpoint, toolchain: toolchain)
  }

  /// Applies the 0.3.0 commandless existing-server identity precondition
  /// before `checkserver`, then repeats it after the command. No HDC child is
  /// launched when the selected executable, exact loopback endpoint, or
  /// exactly-one-existing-listener precondition is missing.
  @discardableResult
  public func observeRegisteredExistingServer(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate
  ) async -> HDCRegisteredServerObservationResult {
    let entry = readOnlyProbeRegistry.entry(for: .serverIdentityGeneration)
    guard entry.status == .supported, entry.probeKind == .platformProcessObservation,
      !entry.invocationAllowed, entry.exactArguments.isEmpty
    else {
      return HDCRegisteredServerObservationResult(
        classification: .unsupported(reason: "server identity family is not registered"))
    }
    guard toolchain.sha256 == readOnlyProbeRegistry.targetExecutableSHA256 else {
      return HDCRegisteredServerObservationResult(
        classification: .unsupported(
          reason: "selected executable is outside OPENHARMONY-TOOLS@0.3.0"))
    }
    guard registeredExecutableMatches(toolchain) else {
      return HDCRegisteredServerObservationResult(
        classification: .unsupported(
          reason: "semantic profile does not match the complete read-only registry"))
    }

    let before = await observeIdentity(
      endpoint: endpoint.endpoint, toolchain: toolchain,
      timeoutMilliseconds: entry.timeoutMilliseconds)
    guard case .observed(let beforeReceipt) = before else {
      return identityFailureResult(before)
    }

    let evaluated: SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult>
    do {
      evaluated = try await runner.execute(
        HDCProcessCommand(
          toolchain: toolchain, endpoint: endpoint,
          arguments: endpoint.argumentsForEndpointSensitiveProbe(["checkserver"]),
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10,
          dispatchOrigin: .readOnlyProbe))
    } catch {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint, reason: "registered checkserver process could not run")
      return HDCRegisteredServerObservationResult(
        classification: .unknown(reason: "registered checkserver process could not run"),
        identity: beforeReceipt)
    }

    let classification = classifyCheckserver(
      evaluated.execution, semantic: evaluated.semantic)
    guard case .healthy(let serverVersion) = classification else {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint, reason: String(describing: classification))
      return HDCRegisteredServerObservationResult(
        classification: .unknown(reason: "registered checkserver family did not establish health"),
        identity: beforeReceipt, execution: evaluated.execution)
    }

    let after = await observeIdentity(
      endpoint: endpoint.endpoint, toolchain: toolchain,
      timeoutMilliseconds: entry.timeoutMilliseconds)
    guard case .observed(let afterReceipt) = after else {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint,
        reason: "server identity was not available after checkserver")
      let failure = identityFailureResult(after)
      return HDCRegisteredServerObservationResult(
        classification: failure.classification, identity: beforeReceipt,
        execution: evaluated.execution)
    }
    guard beforeReceipt == afterReceipt else {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint,
        reason: "server identity changed across the checkserver observation")
      return HDCRegisteredServerObservationResult(
        classification: .unknown(
          reason: "server identity changed across the checkserver observation"),
        identity: afterReceipt, execution: evaluated.execution)
    }

    guard let generation = afterReceipt.stableGeneration else {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint,
        reason: "server process start identity cannot be represented as a generation")
      return HDCRegisteredServerObservationResult(
        classification: .unknown(
          reason: "server process start identity cannot be represented as a generation"),
        identity: afterReceipt, execution: evaluated.execution)
    }
    let dispatchSnapshot = await supervisor.automaticDispatchSnapshot()
    let ownershipBasis = HDCServerOwnershipBasis(
      preExistingServerReceipt: true,
      automaticLifecycleDispatchCount: dispatchSnapshot.automaticLifecycleDispatchCount,
      generationMintedFromObservation: true)
    await supervisor.observeRegisteredServerIdentity(
      endpoint: endpoint.endpoint, health: .healthy, version: .known(serverVersion),
      generation: generation,
      ownershipBasis: ownershipBasis,
      reason: "OPENHARMONY-TOOLS@0.3.0 bracketed process/listener observation")
    return HDCRegisteredServerObservationResult(
      classification: .observed(generation: generation, serverVersion: serverVersion),
      identity: afterReceipt, execution: evaluated.execution)
  }

  private func observeIdentity(
    endpoint: HDCServerEndpoint,
    toolchain: HDCCandidate,
    timeoutMilliseconds: Int
  ) async -> HDCServerProcessIdentityRawObservation {
    await withTaskGroup(of: HDCServerProcessIdentityRawObservation.self) { group in
      group.addTask {
        await self.identityObserver.observe(
          endpoint: endpoint, selectedToolchain: toolchain)
      }
      group.addTask {
        do {
          try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
          return .timedOut
        } catch {
          return .cancelled
        }
      }
      let result = await group.next() ?? .unknown(reason: "identity observation produced no result")
      group.cancelAll()
      return result
    }
  }

  private func identityFailureResult(
    _ observation: HDCServerProcessIdentityRawObservation
  ) -> HDCRegisteredServerObservationResult {
    switch observation {
    case .observed:
      HDCRegisteredServerObservationResult(
        classification: .unknown(reason: "unexpected identity observation state"))
    case .unavailable(let reason):
      HDCRegisteredServerObservationResult(classification: .unavailable(reason: reason))
    case .unknown(let reason):
      HDCRegisteredServerObservationResult(classification: .unknown(reason: reason))
    case .timedOut:
      HDCRegisteredServerObservationResult(classification: .timedOut)
    case .cancelled:
      HDCRegisteredServerObservationResult(classification: .cancelled)
    }
  }

  private func registeredExecutableMatches(_ toolchain: HDCCandidate) -> Bool {
    semanticProfile.integrationProfile == HDCReadOnlyProbeRegistry.integrationProfile
      && semanticProfile.toolVersion == HDCReadOnlyProbeRegistry.targetToolVersion
      && semanticProfile.targetExecutableSHA256 == readOnlyProbeRegistry.targetExecutableSHA256
      && toolchain.sha256 == semanticProfile.targetExecutableSHA256
  }

  private func unavailableExecution() -> ProcessExecutionResult {
    ProcessExecutionResult(
      termination: .waitFailed(-1),
      stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
      stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false))
  }

  private func classifyCheckserver(
    _ execution: ProcessExecutionResult,
    semantic: HDCCommandSemanticResult
  )
    -> HDCServerProbeClassification
  {
    if case .failure = semantic {
      return .unavailable(reason: "checkserver emitted a registered failure result")
    }
    guard execution.termination == .exited(0) else {
      return .unavailable(reason: "checkserver did not exit zero")
    }
    guard execution.stderr.totalByteCount == 0,
      HDCRegisteredGoldenFingerprint.matches(
        execution.stdout.data, sha256: HDCRegisteredGoldenFingerprint.checkserverHealthySHA256)
    else {
      return .unknown(reason: "checkserver output is outside the registered pinned healthy family")
    }
    let output = String(decoding: execution.stdout.data, as: UTF8.self)
      .trimmingCharacters(in: .newlines)
    let prefix = "Client version:Ver: "
    let separator = ", server version:Ver: "
    guard output.hasPrefix(prefix),
      let separatorRange = output.range(of: separator),
      separatorRange.lowerBound > output.index(output.startIndex, offsetBy: prefix.count)
    else {
      return output.lowercased().contains("[fail]")
        ? .unavailable(reason: "checkserver emitted a registered failure marker")
        : .unknown(reason: "checkserver output is not a registered healthy family")
    }
    let serverVersion = String(output[separatorRange.upperBound...])
    guard !serverVersion.isEmpty, !serverVersion.contains("\n") else {
      return .unknown(reason: "checkserver healthy family omitted a server version")
    }
    let clientVersion = String(
      output[output.index(output.startIndex, offsetBy: prefix.count)..<separatorRange.lowerBound])
    guard clientVersion == serverVersion else {
      // No mismatched version byte family is registered by the integration
      // profile. It must remain raw/unknown rather than being promoted by a
      // permissive text shape.
      return .unknown(reason: "checkserver mismatch output is not a registered pinned family")
    }
    return .healthy(serverVersion: serverVersion)
  }

}

/// Records the exact executable/argv handed to the process port under the same
/// durable lifecycle correlation as its typed intent.  It is deliberately
/// separate from `HDCServerLifecycleAuditStore` so existing preview,
/// confirmation, intent, and outcome ordering remains stable.
package struct HDCServerLifecycleActualCommand: Sendable, Equatable {
  package let stepID: UUID
  package let auditID: UUID
  package let executable: URL
  package let arguments: [String]
  package let endpoint: HDCServerEndpoint

  package init(
    stepID: UUID,
    auditID: UUID,
    executable: URL,
    arguments: [String],
    endpoint: HDCServerEndpoint
  ) {
    self.stepID = stepID
    self.auditID = auditID
    self.executable = executable
    self.arguments = arguments
    self.endpoint = endpoint
  }
}

/// Durable identity of the executable object retained for the lifecycle
/// launch. The Process port creates this receipt from open descriptors; HDC
/// callers cannot substitute fields from the Job snapshot.
package struct HDCServerLifecycleExecutableIdentityReceipt: Sendable, Equatable {
  package let authorizedPath: String
  package let inodeLaunchPath: String
  package let device: UInt64
  package let inode: UInt64
  package let fileSize: Int64
  package let mode: UInt32
  package let sha256: String

  fileprivate init(_ receipt: ProcessExecutableIdentityReceipt) {
    authorizedPath = receipt.authorizedPath
    inodeLaunchPath = receipt.inodeLaunchPath
    device = receipt.device
    inode = receipt.inode
    fileSize = receipt.fileSize
    mode = receipt.mode
    sha256 = receipt.sha256
  }
}

/// A lifecycle process executor consumes this durable proof immediately before
/// handing argv to the process port. The implementation must validate the
/// preview/confirmation/intent chain, reject prior actual/outcome records, and
/// persist `actualCommand` in one non-suspending durable transaction.
package protocol HDCServerLifecycleDispatchAuthorizing: Sendable {
  func consumeDispatchAuthorization(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand
  ) async throws -> Bool

  /// Durably marks the boundary after the latest Supervisor lease check and
  /// before control enters the process runner. A missing marker proves that a
  /// failed dispatch never reached the launch window; once present, every
  /// non-success result is conservatively an externally uncertain outcome.
  func recordLaunchWindowEntry(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand,
    executableIdentity: HDCServerLifecycleExecutableIdentityReceipt
  ) async throws -> Bool
}

/// The result that proves a lifecycle mutation. Exit status and raw command
/// output alone are deliberately insufficient because no kill/restart success
/// byte family is registered in the integration profile.
public enum HDCServerLifecyclePostDispatchObservation: Sendable, Equatable {
  case generation(Int)
  case unavailable
}

/// Confirmed-only lifecycle executor. It cannot execute without durable
/// preview, confirmation, and intent proof, and the actual argv is durably
/// recorded before the child process starts. Automatic paths retain no
/// reference to it. The tests inject the local fake executable, and this type
/// performs no discovery or PATH lookup.
package actor HDCProcessLifecycleExecutor: HDCServerLifecycleExecutor {
  package typealias PostDispatchProbe =
    @Sendable (HDCServerLifecycleStep) async
    -> HDCServerLifecyclePostDispatchObservation?

  private let runner: HDCProcessCommandRunner
  private let toolchain: HDCCandidate
  private let endpointSelection: HDCServerEndpointSelection
  private let additionalChildEnvironment: [String: String]
  private let durableAuthorization: any HDCServerLifecycleDispatchAuthorizing
  private let dispatchLeaseValidator: any HDCServerLifecycleDispatchLeaseValidating
  private let postDispatchProbe: PostDispatchProbe

  init(
    runner: HDCProcessCommandRunner? = nil,
    toolchain: HDCCandidate,
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    endpointSelection: HDCServerEndpointSelection,
    additionalChildEnvironment: [String: String] = [:],
    durableAuthorization: any HDCServerLifecycleDispatchAuthorizing,
    dispatchLeaseValidator: any HDCServerLifecycleDispatchLeaseValidating,
    postDispatchProbe: @escaping PostDispatchProbe
  ) {
    self.runner = runner ?? HDCProcessCommandRunner(semanticProfile: semanticProfile)
    self.toolchain = toolchain
    self.endpointSelection = endpointSelection
    self.additionalChildEnvironment = additionalChildEnvironment
    self.durableAuthorization = durableAuthorization
    self.dispatchLeaseValidator = dispatchLeaseValidator
    self.postDispatchProbe = postDispatchProbe
  }

  package init(
    toolchain: HDCCandidate,
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    endpointSelection: HDCServerEndpointSelection,
    additionalChildEnvironment: [String: String] = [:],
    durableAuthorization: any HDCServerLifecycleDispatchAuthorizing,
    supervisor: HDCServerSupervisor,
    postDispatchProbe: @escaping PostDispatchProbe
  ) {
    runner = HDCProcessCommandRunner(
      semanticProfile: semanticProfile,
      automaticDispatchInstrumentation: supervisor.automaticDispatchInstrumentation)
    self.toolchain = toolchain
    self.endpointSelection = endpointSelection
    self.additionalChildEnvironment = additionalChildEnvironment
    self.durableAuthorization = durableAuthorization
    dispatchLeaseValidator = supervisor
    self.postDispatchProbe = postDispatchProbe
  }

  func execute(
    _ step: HDCServerLifecycleStep,
    lease: HDCServerLifecycleDispatchLease
  ) async -> HDCServerLifecycleExecutorResult {
    func receipt(
      _ outcome: HDCServerLifecycleExecutionOutcome,
      observation: HDCServerLifecyclePostDispatchObservation? = nil
    ) -> HDCServerLifecycleExecutorResult {
      HDCServerLifecycleExecutorResult(
        outcome: outcome, postDispatchObservation: observation)
    }

    guard step.endpoint == endpointSelection.endpoint else {
      return receipt(
        .failed(reason: "confirmed lifecycle endpoint differs from selected child endpoint"))
    }
    let arguments: [String]
    switch step.action {
    case .restartConfirmedGeneration:
      arguments = ["-s", step.endpoint.rawValue, "kill", "-r"]
    case .stopConfirmedGeneration:
      arguments = ["-s", step.endpoint.rawValue, "kill"]
    case .startManaged:
      return receipt(
        .failed(reason: "managed start has a separate absent-endpoint evidence gate"))
    }
    let actual = HDCServerLifecycleActualCommand(
      stepID: step.id, auditID: step.auditID, executable: toolchain.path,
      arguments: arguments, endpoint: step.endpoint)
    do {
      guard
        try await durableAuthorization.consumeDispatchAuthorization(
          of: step, actualCommand: actual)
      else {
        return receipt(
          .failed(
            reason:
              "lifecycle dispatch lacks an unused durable preview, confirmation, and intent authorization"
          )
        )
      }
    } catch {
      return receipt(
        .failed(
          reason: "actual lifecycle command audit could not be persisted before process launch"))
    }

    let command = HDCProcessCommand(
      toolchain: toolchain, endpoint: endpointSelection, arguments: arguments,
      additionalChildEnvironment: additionalChildEnvironment, timeout: 15,
      dispatchOrigin: .confirmedLifecycle)
    let prepared: HDCPreparedProcessCommand
    do {
      prepared = try runner.prepare(command)
    } catch {
      return receipt(
        .failed(
          reason: "lifecycle executable identity could not be prepared before process launch"))
    }
    defer { prepared.close() }

    guard await dispatchLeaseValidator.consumeDispatchLease(lease, for: step) else {
      return receipt(
        .failed(
          reason:
            "lifecycle dispatch lease expired after durable authorization before process launch"
        )
      )
    }
    do {
      guard
        try await durableAuthorization.recordLaunchWindowEntry(
          of: step,
          actualCommand: actual,
          executableIdentity: HDCServerLifecycleExecutableIdentityReceipt(
            prepared.process.executableIdentity))
      else {
        return receipt(
          .failed(
            reason: "lifecycle launch window was not durably entered before process launch"))
      }
    } catch {
      return receipt(
        .failed(
          reason: "lifecycle launch window audit could not be persisted before process launch"))
    }
    do {
      let result = try await runner.executePrepared(
        prepared, launchGate: lease.launchGate)
      let observation = await postDispatchProbe(step)
      guard result.execution.termination == .exited(0) else {
        return receipt(
          .outcomeUnknown(
            reason:
              "lifecycle launch window was entered and the process did not exit zero; post-dispatch state requires reconciliation"
          ),
          observation: observation
        )
      }
      if case .failure = result.semantic {
        return receipt(
          .outcomeUnknown(
            reason:
              "lifecycle launch window was entered and the process emitted a registered failure result; post-dispatch state requires reconciliation"
          ),
          observation: observation
        )
      }
      guard result.execution.stderr.totalByteCount == 0 else {
        return receipt(
          .outcomeUnknown(
            reason:
              "lifecycle process emitted unregistered stderr; post-dispatch state is not trusted"),
          observation: observation)
      }
      guard let observation else {
        return receipt(
          .outcomeUnknown(
            reason: "lifecycle process completed but server state could not be re-probed"))
      }
      switch (step.action, observation) {
      case (.restartConfirmedGeneration, .generation(let generation)):
        guard let expectedGeneration = step.expectedGeneration, generation > expectedGeneration
        else {
          return receipt(
            .outcomeUnknown(
              reason: "restart completed but did not establish a strictly newer server generation"),
            observation: observation)
        }
        return receipt(.succeeded(resultingGeneration: generation), observation: observation)
      case (.stopConfirmedGeneration, .unavailable):
        return receipt(.stopped, observation: observation)
      case (.restartConfirmedGeneration, .unavailable), (.stopConfirmedGeneration, .generation):
        return receipt(
          .outcomeUnknown(reason: "post-dispatch server state does not match lifecycle action"),
          observation: observation)
      case (.startManaged, _):
        return receipt(
          .failed(reason: "managed start has a separate absent-endpoint evidence gate"),
          observation: observation)
      }
    } catch {
      let observation = await postDispatchProbe(step)
      return receipt(
        .outcomeUnknown(
          reason:
            "lifecycle launch window was entered but process execution could not be classified; post-dispatch state requires reconciliation"
        ),
        observation: observation
      )
    }
  }
}

// MARK: - Authorization and channel protection

enum HDCAuthorizationProbeState: Sendable, Equatable {
  case ready
  case unauthorized
  case denied(reason: String)
  case keyAccessDenied(reason: String)
  case offline
  case unknown(reason: String)
}

public enum HDCAuthorizationState: Sendable, Equatable {
  case unauthorizedWaitingForTrust
  case ready
  case denied(reason: String)
  case timedOut
  case cancelled
  case keyAccessDenied(reason: String)
  case unavailable(reason: String)

  public var hasNonDestructiveRetry: Bool {
    switch self {
    case .ready: false
    case .unauthorizedWaitingForTrust, .denied, .timedOut, .cancelled, .keyAccessDenied,
      .unavailable:
      true
    }
  }
}

struct HDCAuthorizationPollingPolicy: Sendable, Equatable {
  let maximumAttempts: Int
  let perProbeTimeout: Duration
  let overallTimeout: Duration
  let pollingInterval: Duration

  init(
    maximumAttempts: Int,
    perProbeTimeout: Duration = .seconds(5),
    overallTimeout: Duration = .seconds(30),
    pollingInterval: Duration = .milliseconds(250)
  ) {
    precondition(maximumAttempts > 0, "authorization polling must be bounded")
    precondition(perProbeTimeout > .zero, "each authorization probe must have a deadline")
    precondition(overallTimeout > .zero, "authorization polling must have an overall deadline")
    precondition(pollingInterval >= .zero, "authorization polling interval cannot be negative")
    self.maximumAttempts = maximumAttempts
    self.perProbeTimeout = perProbeTimeout
    self.overallTimeout = overallTimeout
    self.pollingInterval = pollingInterval
  }
}

private enum HDCAuthorizationProbeRaceResult: Sendable {
  case probe(HDCAuthorizationProbeState)
  case deadlineExceeded
  case cancelled
}

private actor HDCAuthorizationProbeRace {
  private var result: HDCAuthorizationProbeRaceResult?
  private var continuation: CheckedContinuation<HDCAuthorizationProbeRaceResult, Never>?

  func wait() async -> HDCAuthorizationProbeRaceResult {
    if let result { return result }
    return await withCheckedContinuation { continuation = $0 }
  }

  func resolve(_ result: HDCAuthorizationProbeRaceResult) {
    guard self.result == nil else { return }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(returning: result)
  }
}

/// Bounded polling has no lifecycle executor and therefore cannot restart a
/// shared server to force an authorization prompt.
struct HDCAuthorizationWorkflow: Sendable {
  func poll(
    policy: HDCAuthorizationPollingPolicy,
    probe: @escaping @Sendable (Int) async -> HDCAuthorizationProbeState
  ) async -> HDCAuthorizationState {
    let clock = ContinuousClock()
    let overallDeadline = clock.now.advanced(by: policy.overallTimeout)
    for attempt in 1...policy.maximumAttempts {
      if Task.isCancelled { return .cancelled }
      guard clock.now < overallDeadline else { return .timedOut }
      let remaining = clock.now.duration(to: overallDeadline)
      let probeResult = await runProbe(
        attempt: attempt,
        timeout: min(policy.perProbeTimeout, remaining),
        probe: probe)
      if Task.isCancelled { return .cancelled }
      let probeState: HDCAuthorizationProbeState
      switch probeResult {
      case .probe(let state):
        probeState = state
      case .deadlineExceeded:
        return .timedOut
      case .cancelled:
        return .cancelled
      }
      switch probeState {
      case .ready:
        return .ready
      case .denied(let reason):
        return .denied(reason: reason)
      case .keyAccessDenied(let reason):
        return .keyAccessDenied(reason: reason)
      case .offline:
        return .unavailable(reason: "HDC reported the target offline")
      case .unknown(let reason):
        return .unavailable(reason: reason)
      case .unauthorized:
        break
      }

      if (attempt < policy.maximumAttempts) && (policy.pollingInterval > .zero) {
        guard clock.now < overallDeadline else { return .timedOut }
        let delay = min(policy.pollingInterval, clock.now.duration(to: overallDeadline))
        do {
          try await clock.sleep(for: delay)
        } catch {
          return .cancelled
        }
      }
    }
    return .timedOut
  }

  /// The probe runs in an unstructured task so leaving this function never
  /// waits for a non-cooperative implementation. Cancellation is requested on
  /// every losing branch, and the single-assignment race rejects late values.
  private func runProbe(
    attempt: Int,
    timeout: Duration,
    probe: @escaping @Sendable (Int) async -> HDCAuthorizationProbeState
  ) async -> HDCAuthorizationProbeRaceResult {
    let race = HDCAuthorizationProbeRace()
    let probeTask = Task {
      let state = await probe(attempt)
      await race.resolve(.probe(state))
    }
    let deadlineTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await race.resolve(.deadlineExceeded)
    }
    let result = await withTaskCancellationHandler {
      await race.wait()
    } onCancel: {
      Task { await race.resolve(.cancelled) }
    }
    probeTask.cancel()
    deadlineTask.cancel()
    return result
  }
}

public struct HDCChannelProtectionEvidence: Sendable, Equatable {
  public let evidenceVersion: String
  public let source: String
  public let detail: String

  public init(evidenceVersion: String, source: String, detail: String) {
    precondition(!evidenceVersion.isEmpty && !source.isEmpty && !detail.isEmpty)
    self.evidenceVersion = evidenceVersion
    self.source = source
    self.detail = detail
  }
}

public enum HDCChannelProtectionState: Sendable, Equatable {
  case encryptedVerified(HDCChannelProtectionEvidence)
  case unverifiedAssumeUnprotected
}

public enum HDCSubserverCapability: Sendable, Equatable {
  case supportedReadOnly
  case unsupported
  case unknown(reason: String)
}

public struct HDCSecurityPresentation: Sendable, Equatable {
  public let authorization: HDCAuthorizationState
  public let protection: HDCChannelProtectionState
  public let tcpWarning: String?

  public init(
    authorization: HDCAuthorizationState,
    protection: HDCChannelProtectionState,
    transportIsTCP: Bool
  ) {
    self.authorization = authorization
    self.protection = protection
    tcpWarning =
      transportIsTCP && protection == .unverifiedAssumeUnprotected
      ? "Channel protection is unverified. Use this TCP target only on a trusted, isolated network."
      : nil
  }
}

/// The recovery state exposed to the UI is deliberately narrower than an
/// executor.  A presentation can request and confirm an impact snapshot, but
/// it contains neither an argv nor a dispatch capability.
public enum HDCLifecycleRecoveryPresentation: Sendable, Equatable {
  case unavailable(reason: String)
  case preview(HDCServerLifecycleImpactPreview)
  case confirmed(HDCServerLifecycleConfirmation)
  case blocked(reason: String)

  var impactPreview: HDCServerImpactSnapshot? {
    switch self {
    case .preview(let preview): return preview.snapshot
    case .confirmed: return nil
    case .unavailable, .blocked: return nil
    }
  }
}

/// App-facing diagnostics use case.  It intentionally has no lifecycle
/// executor parameter, so UI actions can create a durable preview and user
/// confirmation but can never manufacture a `kill` or `kill -r` dispatch.
public protocol HDCDiagnosticsStateProviding: Sendable {
  func refresh() async -> HDCDiagnosticsPresentation
  func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
  func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation
}

/// App-owned configuration for the read-only discovery phase. User-selected
/// executables persist as security-scoped bookmarks; explicit launch/support
/// overrides remain absolute-path-only. Discovery validates every path and
/// never searches PATH. Session composition replaces this read-only provider
/// once a durable supervisor is available.
public enum HDCApplicationDiagnosticsConfiguration {
  public static let userConfiguredPathsPreferenceKey = "ArkDeck.HDC.userConfiguredPaths"
  public static let userConfiguredBookmarksPreferenceKey =
    "ArkDeck.HDC.userConfiguredSecurityScopedBookmarks"
  public static let devecoSDKPathsPreferenceKey = "ArkDeck.HDC.devecoSDKPaths"
  public static let openHarmonySDKPathsPreferenceKey = "ArkDeck.HDC.openHarmonySDKPaths"
  /// A support/automation override for the same explicit candidate setting.
  /// It is intentionally singular and absolute-path-only; it never enables
  /// PATH discovery or a UI-test fixture provider.
  public static let userConfiguredPathLaunchArgument = "--arkdeck-hdc-user-configured-path"
  public static let userConfiguredPathEnvironmentKey = "ARKDECK_HDC_USER_CONFIGURED_PATH"

  public static func discoveryRequest(
    userDefaults: UserDefaults = .standard,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> HDCDiscoveryRequest {
    let restored = restoreUserConfiguredBookmarks(userDefaults: userDefaults)
    let explicitOverrides =
      launchArgumentValues(
        named: userConfiguredPathLaunchArgument, in: arguments)
      + (environment[userConfiguredPathEnvironmentKey].map { [$0] } ?? [])
    return HDCDiscoveryRequest(
      // Persisted absolute-path strings are display/migration metadata only;
      // after relaunch they cannot substitute for a sandbox capability.
      // An explicit support/automation override takes precedence over a
      // previously persisted bookmark, but never discards that bookmark's
      // capability metadata for later normal launches.
      userConfiguredPaths: absoluteURLs(explicitOverrides) + restored.urls,
      devecoSDKPaths: paths(for: devecoSDKPathsPreferenceKey, userDefaults: userDefaults),
      openHarmonySDKPaths: paths(for: openHarmonySDKPathsPreferenceKey, userDefaults: userDefaults),
      securityScopedBookmarks: restored.bookmarksByPath)
  }

  /// Called with a URL returned by the standard file importer. The bookmark,
  /// not the path string, is the persistent authority used after relaunch.
  public static func persistUserConfiguredExecutable(
    _ url: URL,
    userDefaults: UserDefaults = .standard
  ) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart { url.stopAccessingSecurityScopedResource() }
    }
    let bookmark = try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
    userDefaults.set([bookmark], forKey: userConfiguredBookmarksPreferenceKey)
    userDefaults.set([url.path], forKey: userConfiguredPathsPreferenceKey)
  }

  /// Explicit UI-automation/support reset. It removes only ArkDeck's HDC
  /// selection metadata and bookmark; it never touches the selected file.
  public static func clearUserConfiguredExecutable(
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.removeObject(forKey: userConfiguredBookmarksPreferenceKey)
    userDefaults.removeObject(forKey: userConfiguredPathsPreferenceKey)
  }

  /// Command-line defaults provide a single string, while persisted settings
  /// use a string array. Treat both as the same explicit-path configuration;
  /// neither form enables PATH search or a fixture-only discovery route.
  private static func paths(
    for key: String,
    userDefaults: UserDefaults,
    fallback: [String] = []
  ) -> [URL] {
    let values: [String] =
      userDefaults.stringArray(forKey: key)
      ?? userDefaults.string(forKey: key).map { [$0] }
      ?? fallback
    return values.compactMap { value in
      absoluteURL(value)
    }
  }

  private static func absoluteURLs(_ values: [String]) -> [URL] {
    values.compactMap(absoluteURL)
  }

  private static func absoluteURL(_ value: String) -> URL? {
    guard value.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: value)
  }

  private static func restoreUserConfiguredBookmarks(
    userDefaults: UserDefaults
  ) -> (urls: [URL], bookmarksByPath: [String: Data]) {
    guard
      let stored = userDefaults.array(forKey: userConfiguredBookmarksPreferenceKey) as? [Data]
    else {
      return ([], [:])
    }
    var urls: [URL] = []
    var bookmarksByPath: [String: Data] = [:]
    var refreshed: [Data] = []
    for bookmark in stored {
      var isStale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale)
      else { continue }
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      let activeBookmark: Data
      if isStale {
        guard
          let replacement = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else { continue }
        activeBookmark = replacement
      } else {
        activeBookmark = bookmark
      }
      let normalized = url.resolvingSymlinksInPath().standardizedFileURL
      guard bookmarksByPath[normalized.path] == nil else { continue }
      urls.append(normalized)
      bookmarksByPath[normalized.path] = activeBookmark
      refreshed.append(activeBookmark)
    }
    if refreshed != stored {
      userDefaults.set(refreshed, forKey: userConfiguredBookmarksPreferenceKey)
    }
    return (urls, bookmarksByPath)
  }

  private static func launchArgumentValues(named name: String, in arguments: [String]) -> [String] {
    arguments.indices.compactMap { index in
      guard arguments[index] == name, arguments.indices.contains(index + 1) else { return nil }
      return arguments[index + 1]
    }
  }
}

/// Presentation-only state for the minimal HDC diagnostics surface.  The view
/// receives this immutable value and has no process or lifecycle authority.
public struct HDCDiagnosticsPresentation: Sendable, Equatable {
  public let absolutePath: String
  public let source: String
  public let hash: String
  public let platformTrust: String
  public let clientVersion: String
  public let serverVersion: String
  public let daemonVersion: String
  public let endpoint: String
  public let endpointSource: HDCServerEndpointSource?
  public let childEnvironmentKeys: [String]
  public let serverHealth: HDCServerHealth
  public let generation: String
  public let ownership: HDCServerOwnership
  public let ownershipBasis: HDCServerOwnershipBasis?
  public let automaticDispatchSnapshot: HDCAutomaticDispatchSnapshot?
  public let deviceObservationEvents: [HDCDeviceObservationEvent]
  public let authorization: HDCAuthorizationState
  public let channelProtection: HDCChannelProtectionState
  /// Nil unless the verified presentation identifies the connection as TCP
  /// without channel-protection evidence.
  public let tcpUnprotectedWarning: String?
  public let keyAccessError: String?
  public let subserverCapability: HDCSubserverCapability
  public let lifecycleRecovery: HDCLifecycleRecoveryPresentation
  /// An impact preview is display-only.  Confirmation and dispatch authority
  /// remain in `HDCServerSupervisor` and cannot be created by this value.
  public let lifecycleImpactPreview: HDCServerImpactSnapshot?
  public let criticalGateMessage: String?

  public init(
    absolutePath: String,
    source: String,
    hash: String,
    platformTrust: String,
    clientVersion: String,
    serverVersion: String,
    daemonVersion: String,
    endpoint: String,
    endpointSource: HDCServerEndpointSource? = nil,
    childEnvironmentKeys: [String] = [],
    serverHealth: HDCServerHealth = .unknown,
    generation: String,
    ownership: HDCServerOwnership,
    ownershipBasis: HDCServerOwnershipBasis? = nil,
    automaticDispatchSnapshot: HDCAutomaticDispatchSnapshot? = nil,
    deviceObservationEvents: [HDCDeviceObservationEvent] = [],
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState,
    tcpUnprotectedWarning: String? = nil,
    keyAccessError: String? = nil,
    subserverCapability: HDCSubserverCapability,
    lifecycleImpactPreview: HDCServerImpactSnapshot? = nil,
    lifecycleRecovery: HDCLifecycleRecoveryPresentation? = nil,
    criticalGateMessage: String? = nil
  ) {
    self.absolutePath = absolutePath
    self.source = source
    self.hash = hash
    self.platformTrust = platformTrust
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.daemonVersion = daemonVersion
    self.endpoint = endpoint
    self.endpointSource = endpointSource
    self.childEnvironmentKeys = Array(Set(childEnvironmentKeys)).sorted()
    self.serverHealth = serverHealth
    self.generation = generation
    self.ownership = ownership
    self.ownershipBasis = ownershipBasis
    self.automaticDispatchSnapshot = automaticDispatchSnapshot
    self.deviceObservationEvents = deviceObservationEvents
    self.authorization = authorization
    self.channelProtection = channelProtection
    self.tcpUnprotectedWarning = tcpUnprotectedWarning
    self.keyAccessError = keyAccessError
    self.subserverCapability = subserverCapability
    let resolvedRecovery =
      lifecycleRecovery
      ?? lifecycleImpactPreview.map {
        .preview(HDCServerLifecycleImpactPreview(id: UUID(), auditID: UUID(), snapshot: $0))
      }
      ?? .unavailable(reason: "No lifecycle recovery use case is configured")
    self.lifecycleRecovery = resolvedRecovery
    self.lifecycleImpactPreview = resolvedRecovery.impactPreview
    self.criticalGateMessage = criticalGateMessage
  }

  public static let unprobed = HDCDiagnosticsPresentation(
    absolutePath: "unknown", source: "unknown", hash: "unverified",
    platformTrust: "unverified", clientVersion: "unknown", serverVersion: "unknown",
    daemonVersion: "unknown", endpoint: "unknown", generation: "unknown", ownership: .unknown,
    authorization: .unavailable(reason: "HDC authorization has not been probed"),
    channelProtection: .unverifiedAssumeUnprotected,
    subserverCapability: .unknown(reason: "subserver capability has not been probed"),
    lifecycleRecovery: .unavailable(reason: "HDC diagnostics have not been configured"))

  public static let loading = HDCDiagnosticsPresentation(
    absolutePath: "loading", source: "loading", hash: "loading",
    platformTrust: "loading", clientVersion: "loading", serverVersion: "loading",
    daemonVersion: "loading", endpoint: "loading", generation: "loading", ownership: .unknown,
    authorization: .unavailable(reason: "HDC diagnostics are loading"),
    channelProtection: .unverifiedAssumeUnprotected,
    subserverCapability: .unknown(reason: "HDC diagnostics are loading"),
    lifecycleRecovery: .unavailable(reason: "HDC diagnostics are loading"))
}

/// Read-only production diagnostics when the App has not yet assembled a
/// Session-backed supervisor.  It performs external-first discovery only; it
/// never runs an HDC command, and reports that absence as a concrete state
/// rather than leaving the UI permanently `unprobed`.
public actor HDCReadOnlyDiagnosticsUseCase: HDCDiagnosticsStateProviding {
  private let discoveryRequest: HDCDiscoveryRequest
  private let inheritedEnvironment: [String: String]

  public init(
    discoveryRequest: HDCDiscoveryRequest = HDCDiscoveryRequest(),
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.discoveryRequest = discoveryRequest
    self.inheritedEnvironment = inheritedEnvironment
  }

  public func refresh() async -> HDCDiagnosticsPresentation {
    let endpoint: HDCServerEndpointSelection
    do {
      endpoint = try HDCServerEndpointSelector.select(inheritedEnvironment: inheritedEnvironment)
    } catch {
      return unavailablePresentation(
        reason: "HDC endpoint configuration is invalid and was not used for a child process")
    }
    let report = HDCExternalFirstDiscovery.discover(discoveryRequest)
    guard let candidate = report.candidates.first else {
      return unavailablePresentation(
        endpointSelection: endpoint,
        reason: "No user-configured or SDK HDC candidate is available for diagnostics")
    }
    return HDCDiagnosticsPresentation(
      absolutePath: candidate.path.path, source: candidate.source.rawValue, hash: candidate.sha256,
      platformTrust: "unknown (trust inspection has not run)",
      clientVersion: "unknown (version probe has not run)",
      serverVersion: "unknown (checkserver has not run)",
      daemonVersion: "unknown (not exposed by a registered probe)",
      endpoint: endpoint.endpoint.rawValue,
      endpointSource: endpoint.source,
      childEnvironmentKeys: Array(endpoint.childEnvironment.keys),
      serverHealth: .unknown,
      generation: "unknown (server supervisor has not run)", ownership: .unknown,
      authorization: .unavailable(reason: "authorization probe requires a selected device"),
      channelProtection: .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning:
        "Channel protection is unverified. Use TCP only on a trusted, isolated network.",
      keyAccessError:
        "Key access diagnostics are unsupported without a configured or user-approved locator.",
      subserverCapability: .unsupported,
      lifecycleRecovery: .unavailable(
        reason: "Recovery requires a verified endpoint and a Session-backed durable audit"))
  }

  public func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    unavailablePresentation(
      reason: "Recovery requires a verified endpoint and a Session-backed durable audit")
  }

  public func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    unavailablePresentation(
      reason: "No durable lifecycle impact preview is available to confirm")
  }

  private func unavailablePresentation(
    endpointSelection: HDCServerEndpointSelection? = nil,
    reason: String
  ) -> HDCDiagnosticsPresentation {
    HDCDiagnosticsPresentation(
      absolutePath: "unknown (no configured candidate)", source: "unknown", hash: "unverified",
      platformTrust: "unverified", clientVersion: "unknown", serverVersion: "unknown",
      daemonVersion: "unknown",
      endpoint: endpointSelection?.endpoint.rawValue ?? "unknown",
      endpointSource: endpointSelection?.source,
      childEnvironmentKeys: endpointSelection.map { Array($0.childEnvironment.keys) } ?? [],
      serverHealth: .unknown,
      generation: "unknown", ownership: .unknown,
      authorization: .unavailable(reason: reason),
      channelProtection: .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning:
        "Channel protection is unverified. Use TCP only on a trusted, isolated network.",
      keyAccessError:
        "Key access diagnostics are unsupported without a configured or user-approved locator.",
      subserverCapability: .unsupported,
      lifecycleRecovery: .unavailable(reason: reason))
  }
}

/// Long-lived application provider. At launch it gives the UI diagnostics for
/// the configured HDC candidate. Session bootstrap must explicitly attach the
/// durable, supervisor-backed use case before preview/confirmation is enabled;
/// attaching a UI fixture or a bare executor is impossible through this API.
public actor HDCApplicationDiagnosticsProvider: HDCDiagnosticsStateProviding {
  public static let shared = HDCApplicationDiagnosticsProvider()

  private var readOnlyDiagnostics: HDCReadOnlyDiagnosticsUseCase
  private var sessionDiagnostics: HDCServerDiagnosticsUseCase?

  public init(
    discoveryRequest: HDCDiscoveryRequest =
      HDCApplicationDiagnosticsConfiguration.discoveryRequest(),
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    readOnlyDiagnostics = HDCReadOnlyDiagnosticsUseCase(
      discoveryRequest: discoveryRequest, inheritedEnvironment: inheritedEnvironment)
  }

  /// Called only by production Session bootstrap after it has constructed the
  /// supervisor and its durable lifecycle audit adapter.
  public func attachSessionDiagnostics(_ useCase: HDCServerDiagnosticsUseCase) {
    sessionDiagnostics = useCase
  }

  /// Rebuilds the read-only phase after the App stores a new user-selected
  /// bookmark. Existing Session confirmation state is detached so authority
  /// from the previous candidate cannot survive the selection change.
  public func configure(
    discoveryRequest: HDCDiscoveryRequest,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    sessionDiagnostics = nil
    readOnlyDiagnostics = HDCReadOnlyDiagnosticsUseCase(
      discoveryRequest: discoveryRequest, inheritedEnvironment: inheritedEnvironment)
  }

  /// A finished or invalidated Session must not leave stale confirmation
  /// presentation reachable from a later App window.
  public func detachSessionDiagnostics() {
    sessionDiagnostics = nil
  }

  public func refresh() async -> HDCDiagnosticsPresentation {
    if let sessionDiagnostics { return await sessionDiagnostics.refresh() }
    return await readOnlyDiagnostics.refresh()
  }

  public func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let sessionDiagnostics {
      return await sessionDiagnostics.requestRecoveryImpactPreview()
    }
    return await readOnlyDiagnostics.requestRecoveryImpactPreview()
  }

  public func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let sessionDiagnostics {
      return await sessionDiagnostics.confirmRecoveryImpactPreview()
    }
    return await readOnlyDiagnostics.confirmRecoveryImpactPreview()
  }
}

/// Session-composed production diagnostics.  The caller supplies a supervisor
/// already wired to the durable lifecycle audit adapter.  This use case is the
/// only UI-facing path that can request/confirm recovery; dispatch remains in
/// the separately composed lifecycle execution use case.
public actor HDCServerDiagnosticsUseCase: HDCDiagnosticsStateProviding {
  private let supervisor: HDCServerSupervisor
  private let snapshot: HDCJobToolchainSnapshot
  private var authorization: HDCAuthorizationState
  private let channelProtection: HDCChannelProtectionState
  private let keyAccessError: String?
  private let subserverCapability: HDCSubserverCapability
  private let configuredLifecycleRecoveryUnavailableReason: String?
  private var runtimeLifecycleRecoveryRequiredReason: String?
  private var lifecycleRecovery: HDCLifecycleRecoveryPresentation

  public init(
    supervisor: HDCServerSupervisor,
    snapshot: HDCJobToolchainSnapshot,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState,
    keyAccessError: String? = nil,
    subserverCapability: HDCSubserverCapability = .unsupported,
    lifecycleRecoveryUnavailableReason: String? = nil
  ) {
    self.supervisor = supervisor
    self.snapshot = snapshot
    self.authorization = authorization
    self.channelProtection = channelProtection
    self.keyAccessError = keyAccessError
    self.subserverCapability = subserverCapability
    configuredLifecycleRecoveryUnavailableReason = lifecycleRecoveryUnavailableReason
    runtimeLifecycleRecoveryRequiredReason = nil
    lifecycleRecovery = .unavailable(
      reason: lifecycleRecoveryUnavailableReason
        ?? "No recovery impact preview has been requested")
  }

  public func refresh() async -> HDCDiagnosticsPresentation {
    await presentation()
  }

  public func requestRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let lifecycleRecoveryUnavailableReason = currentLifecycleRecoveryUnavailableReason {
      lifecycleRecovery = .unavailable(reason: lifecycleRecoveryUnavailableReason)
      return await presentation()
    }
    switch await supervisor.createImpactPreview(
      action: .restartConfirmedGeneration,
      endpoint: HDCServerEndpoint(snapshot.endpoint)
    ) {
    case .ready(let preview): lifecycleRecovery = .preview(preview)
    case .blocked(let block): lifecycleRecovery = .blocked(reason: String(describing: block))
    }
    return await presentation()
  }

  public func confirmRecoveryImpactPreview() async -> HDCDiagnosticsPresentation {
    if let lifecycleRecoveryUnavailableReason = currentLifecycleRecoveryUnavailableReason {
      lifecycleRecovery = .unavailable(reason: lifecycleRecoveryUnavailableReason)
      return await presentation()
    }
    guard case .preview(let preview) = lifecycleRecovery else {
      lifecycleRecovery = .blocked(
        reason: "No current impact preview is available for confirmation")
      return await presentation()
    }
    switch await supervisor.confirm(preview.id) {
    case .accepted(let confirmation): lifecycleRecovery = .confirmed(confirmation)
    case .blocked(let block): lifecycleRecovery = .blocked(reason: String(describing: block))
    }
    return await presentation()
  }

  package func applyLifecycleDispatchResult(_ result: HDCServerLifecycleDispatchResult) async {
    switch result {
    case .completed(.succeeded(let generation)):
      lifecycleRecovery = .unavailable(
        reason: "Confirmed HDC server recovery completed at generation \(generation)")
    case .completed(.stopped):
      lifecycleRecovery = .unavailable(reason: "Confirmed HDC server stop completed")
    case .completed(.failed(let reason)):
      lifecycleRecovery = .blocked(reason: reason)
    case .completed(.outcomeUnknown(let reason)):
      runtimeLifecycleRecoveryRequiredReason = reason
      lifecycleRecovery = .blocked(reason: reason)
    case .blocked(.recoveryRequired(let reason)):
      runtimeLifecycleRecoveryRequiredReason = reason
      lifecycleRecovery = .blocked(reason: reason)
    case .blocked(let block):
      lifecycleRecovery = .blocked(reason: String(describing: block))
    }
  }

  /// Applies only the result of the registered selected-device authorization
  /// probe. Callers cannot set authorization from UI state or an unbound
  /// device row.
  package func applyRegisteredAuthorization(_ state: HDCAuthorizationState) {
    authorization = state
  }

  /// The caller supplies a snapshot from an approved read-only observer. The
  /// diagnostics use case only forwards it into the supervisor's diff/fan-out
  /// surface and has no command or process capability of its own.
  package func applyReadOnlyDeviceSnapshot(_ snapshot: HDCReadOnlyDeviceSnapshot) async {
    guard snapshot.endpoint.rawValue == self.snapshot.endpoint else { return }
    await supervisor.observeReadOnlyDeviceSnapshot(snapshot)
  }

  private var currentLifecycleRecoveryUnavailableReason: String? {
    configuredLifecycleRecoveryUnavailableReason ?? runtimeLifecycleRecoveryRequiredReason
  }

  private func presentation() async -> HDCDiagnosticsPresentation {
    let endpoint = HDCServerEndpoint(snapshot.endpoint)
    async let currentState = supervisor.state(for: endpoint)
    async let automaticDispatchSnapshot = supervisor.automaticDispatchSnapshot()
    async let deviceObservationEvents = supervisor.recentDeviceObservationEvents(for: endpoint)
    let (state, dispatchSnapshot, deviceEvents) = await (
      currentState, automaticDispatchSnapshot, deviceObservationEvents
    )
    let serverVersion =
      state.map { diagnosticText($0.version) } ?? diagnosticText(snapshot.serverVersion)
    return HDCDiagnosticsPresentation(
      absolutePath: snapshot.path.path, source: snapshot.source.rawValue, hash: snapshot.sha256,
      platformTrust: diagnosticText(snapshot.platformTrust),
      clientVersion: diagnosticText(snapshot.clientVersion), serverVersion: serverVersion,
      daemonVersion: diagnosticText(snapshot.daemonVersion), endpoint: snapshot.endpoint,
      endpointSource: snapshot.endpointSource,
      childEnvironmentKeys: snapshot.childEnvironmentKeys,
      serverHealth: state?.health ?? .unknown,
      generation: state.map { diagnosticText($0.generationEvidence) }
        ?? diagnosticText(snapshot.serverGeneration),
      ownership: state?.ownership ?? .unknown,
      ownershipBasis: state?.ownershipBasis,
      automaticDispatchSnapshot: dispatchSnapshot,
      deviceObservationEvents: deviceEvents,
      authorization: authorization,
      channelProtection: channelProtection,
      tcpUnprotectedWarning: channelProtection == .unverifiedAssumeUnprotected
        ? "Channel protection is unverified. Use TCP only on a trusted, isolated network."
        : nil,
      keyAccessError: keyAccessError, subserverCapability: subserverCapability,
      lifecycleRecovery: lifecycleRecovery)
  }

  private func diagnosticText<T>(_ value: HDCProbeValue<T>) -> String {
    switch value {
    case .known(let value): String(describing: value)
    case .unknown(let reason): "unknown (\(reason))"
    }
  }
}
