import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

struct HDCProcessCommand: Sendable, Equatable {
  let toolchain: HDCCandidate
  let endpoint: HDCServerEndpointSelection
  let arguments: [String]
  /// Extra values are child-only diagnostics/test inputs. The selected HDC
  /// endpoint is always written last and cannot be overridden here.
  let additionalChildEnvironment: [String: String]
  let timeout: TimeInterval?

  init(
    toolchain: HDCCandidate,
    endpoint: HDCServerEndpointSelection,
    arguments: [String],
    additionalChildEnvironment: [String: String] = [:],
    timeout: TimeInterval? = nil
  ) {
    self.toolchain = toolchain
    self.endpoint = endpoint
    self.arguments = arguments
    self.additionalChildEnvironment = additionalChildEnvironment
    self.timeout = timeout
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
package enum HDCRegisteredCommandFamily: Sendable, Equatable {
  case uninstall
  case checkserver
  case version
  case selectedDeviceAuthorization
  /// Lifecycle output has no registered success byte family. A successful
  /// mutation is proved only by the post-dispatch server observation.
  case lifecycleRestart
  case lifecycleStop
  /// Endpoint-bound subserver mutation argv. Like the lifecycle families it
  /// has no registered success byte family and stays fail-closed at the
  /// semantic gate; the sealed classification exists so the identity-bound
  /// spawn hook can attribute a subserver invocation to the automatic
  /// subserver counter. The registry `subserverCapability` family remains
  /// unsupported and no production caller dispatches this argv.
  case subserver
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
    matches(SHA256Hex.string(of: data), sha256: sha256)
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
    case deviceObservationProduction
    case testOnlyFake
  }

  package static let pinnedProduction = HDCRegisteredSemanticProfile(
    authority: .pinnedProduction,
    integrationProfile: HDCReadOnlyProbeRegistry.integrationProfile,
    toolVersion: HDCReadOnlyProbeRegistry.targetToolVersion,
    targetExecutableSHA256: HDCReadOnlyProbeRegistry.targetExecutableSHA256,
    selectedDeviceAuthorizationSHA256: HDCReadOnlyProbeRegistry.pinnedProduction
      .entry(for: .selectedDeviceAuthorizationBinding).rawSHA256)

  static let deviceObservationProduction = HDCRegisteredSemanticProfile(
    authority: .deviceObservationProduction,
    integrationProfile: HDCDeviceObservationProbeCatalog.integrationProfile,
    toolVersion: HDCDeviceObservationProbeCatalog.targetToolVersion,
    targetExecutableSHA256: HDCDeviceObservationProbeCatalog.targetExecutableSHA256,
    selectedDeviceAuthorizationSHA256: nil)

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
  /// select one of the two closed registered production authorities and never
  /// select this fake authority.
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
    if authority == .deviceObservationProduction {
      guard integrationProfile == HDCDeviceObservationProbeCatalog.integrationProfile,
        toolVersion == HDCDeviceObservationProbeCatalog.targetToolVersion,
        descriptorSHA256 == HDCDeviceObservationProbeCatalog.targetExecutableSHA256,
        commandFamily == .selectedDeviceAuthorization
      else { return nil }
      return HDCRegisteredSemanticBinding(
        integrationProfile: integrationProfile,
        toolVersion: toolVersion,
        executableSHA256: descriptorSHA256,
        commandFamily: commandFamily,
        expectedStdoutSHA256: nil)
    }
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
    case .lifecycleRestart, .lifecycleStop, .subserver:
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
/// baseline parser's conservative failure precedence, then accepts success only
/// for the registered uninstall command's byte-exact stdout capture. Marker
/// fragments never promote an unregistered command or raw output to success.
package struct HDCRegisteredSemanticEvaluator: ProcessSemanticEvaluating {
  public typealias SemanticResult = HDCCommandSemanticResult

  private let binding: HDCRegisteredSemanticBinding?
  private var baselineParser = HDCSemanticOutputParser()
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
    baselineParser.consume(chunk)
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
    let baselineResult = baselineParser.finish(exitCode: code)
    if case .failure = baselineResult { return baselineResult }
    guard code == 0 else { return .failure(.nonZeroExit(code)) }
    guard let binding else { return .unknownOutput }
    switch binding.commandFamily {
    case .uninstall:
      return !containsStderr
        && HDCRegisteredGoldenFingerprint.matches(
          SHA256Hex.hexString(stdoutHasher.finalize()),
          sha256: binding.expectedStdoutSHA256 ?? "")
        ? .success
        : .unknownOutput
    case .version:
      return !containsStderr
        && HDCRegisteredGoldenFingerprint.matches(
          SHA256Hex.hexString(stdoutHasher.finalize()),
          sha256: binding.expectedStdoutSHA256 ?? "")
        ? .success
        : .unknownOutput
    case .checkserver, .selectedDeviceAuthorization, .lifecycleRestart, .lifecycleStop,
      .subserver, .unregistered:
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
  private let securityScopedAccess: HDCSecurityScopedExecutableAccess

  init(
    process: ProcessPreparedIdentityBoundLaunch,
    semanticBinding: HDCRegisteredSemanticBinding?,
    securityScopedAccess: HDCSecurityScopedExecutableAccess
  ) {
    self.process = process
    self.semanticBinding = semanticBinding
    self.securityScopedAccess = securityScopedAccess
  }

  func close() {
    process.close()
    securityScopedAccess.stop()
  }

  deinit { close() }
}

/// Opaque, Supervisor-minted dispatch permit. Authenticity is class identity:
/// the only initializer is file-private to this file, so neither a value copy
/// nor a caller-constructed lookalike can satisfy the spawn-hook verification.
/// A permit carries no authorization; the lifecycle gates are unchanged and
/// this token exists purely so the observability counters can distinguish
/// confirmed/managed dispatch from an automatic invocation.
final class HDCServerDispatchPermit: @unchecked Sendable {
  fileprivate init() {}
}

/// Task-local carrier that associates the permit supplied to one runner
/// execution with the identity-bound spawn hook that fires inside the same
/// task. Concurrent executions in separate tasks observe only their own
/// binding, so no pid/argv post-hoc synthesis is needed.
enum HDCServerDispatchPermitBinding {
  @TaskLocal static var current: HDCServerDispatchPermit?
}

/// Package-level fault seam between permit minting and spawn-hook
/// verification. The default has no effect; the mutation contract uses
/// `removePermitBeforeSpawn` to prove that the same real spawn without its
/// permit is counted as automatic.
package enum HDCDispatchInstrumentationFault: Sendable, Equatable {
  case none
  case removePermitBeforeSpawn
}

/// Sums observed identity-bound spawns per Supervisor. Counters increment only
/// inside `recordIdentityBoundSpawn`, whose only caller is the spawn-hook
/// closure installed by `HDCProcessCommandRunner` in this file; the entry
/// point is deliberately file-private so no production or test caller can
/// record a dispatch that did not really spawn.
final class HDCSupervisorDispatchMonitor: @unchecked Sendable {
  struct CountersSnapshot: Sendable, Equatable {
    let automaticLifecycleDispatchCount: Int
    let automaticSubserverDispatchCount: Int
    let confirmedLifecycleDispatchCount: Int
    let managedStartDispatchCount: Int
  }

  enum PermitKind: Sendable, Equatable {
    case confirmedLifecycle
    case managedStart
  }

  struct SpawnAuditRecord: Sendable, Equatable {
    let commandFamily: HDCRegisteredCommandFamily
    let permitKind: PermitKind?
    let processIdentifier: pid_t
    let arguments: [String]
  }

  private let lock = NSLock()
  private var automaticLifecycleDispatchCount = 0
  private var automaticSubserverDispatchCount = 0
  private var confirmedLifecycleDispatchCount = 0
  private var managedStartDispatchCount = 0
  private var mintedPermits: [ObjectIdentifier: PermitKind] = [:]
  private var spawnAudit: [SpawnAuditRecord] = []
  private static let auditCapacity = 256

  init() {}

  func mintConfirmedLifecycleDispatchPermit() -> HDCServerDispatchPermit {
    let permit = HDCServerDispatchPermit()
    lock.withLock { mintedPermits[ObjectIdentifier(permit)] = .confirmedLifecycle }
    return permit
  }

  func mintManagedStartDispatchPermit() -> HDCServerDispatchPermit {
    let permit = HDCServerDispatchPermit()
    lock.withLock { mintedPermits[ObjectIdentifier(permit)] = .managedStart }
    return permit
  }

  func countersSnapshot() -> CountersSnapshot {
    lock.withLock {
      CountersSnapshot(
        automaticLifecycleDispatchCount: automaticLifecycleDispatchCount,
        automaticSubserverDispatchCount: automaticSubserverDispatchCount,
        confirmedLifecycleDispatchCount: confirmedLifecycleDispatchCount,
        managedStartDispatchCount: managedStartDispatchCount)
    }
  }

  func spawnAuditTrail() -> [SpawnAuditRecord] {
    lock.withLock { spawnAudit }
  }

  fileprivate func recordIdentityBoundSpawn(
    receipt _: ProcessExecutableIdentityReceipt,
    request: ProcessRequest,
    processIdentifier: pid_t,
    permit: HDCServerDispatchPermit?
  ) {
    let commandFamily = hdcRegisteredCommandFamily(arguments: request.arguments)
    lock.withLock {
      // One-shot: a permit matches exactly one successful spawn.
      let permitKind = permit.flatMap { mintedPermits.removeValue(forKey: ObjectIdentifier($0)) }
      switch (commandFamily, permitKind) {
      case (_, .managedStart):
        managedStartDispatchCount += 1
      case (.lifecycleRestart, .confirmedLifecycle), (.lifecycleStop, .confirmedLifecycle):
        confirmedLifecycleDispatchCount += 1
      case (.lifecycleRestart, nil), (.lifecycleStop, nil):
        automaticLifecycleDispatchCount += 1
      case (.subserver, nil), (.subserver, .confirmedLifecycle):
        // A confirmed lifecycle permit does not cover a subserver argv; the
        // invocation has no matching permit and counts as automatic.
        automaticSubserverDispatchCount += 1
      case (.uninstall, _), (.checkserver, _), (.version, _),
        (.selectedDeviceAuthorization, _), (.unregistered, _):
        break
      }
      spawnAudit.append(
        SpawnAuditRecord(
          commandFamily: commandFamily,
          permitKind: permitKind,
          processIdentifier: processIdentifier,
          arguments: request.arguments))
      if spawnAudit.count > Self.auditCapacity {
        spawnAudit.removeFirst(spawnAudit.count - Self.auditCapacity)
      }
    }
  }
}

package final class HDCProcessCommandRunner: @unchecked Sendable {
  private let executor: FoundationProcessExecutor
  private let semanticProfile: HDCRegisteredSemanticProfile
  private let dispatchInstrumentationFault: HDCDispatchInstrumentationFault

  package init(
    executor: FoundationProcessExecutor = FoundationProcessExecutor(),
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction
  ) {
    self.executor = executor
    self.semanticProfile = semanticProfile
    dispatchInstrumentationFault = .none
  }

  /// Builds a runner whose executor reports every identity-bound successful
  /// spawn to the Supervisor dispatch monitor. The hook closure created here
  /// is the only holder of the monitor's file-private record entry point.
  /// Module-internal on purpose: composition inside this module wires the
  /// monitor; no package or public caller can install one.
  init(
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    dispatchMonitor: HDCSupervisorDispatchMonitor,
    dispatchInstrumentationFault: HDCDispatchInstrumentationFault = .none,
    identityBoundFinalLaunchHook:
      @escaping @Sendable (ProcessExecutableIdentityReceipt) async throws -> Void = { _ in },
    launchObserver: @escaping @Sendable (pid_t) -> Void = { _ in }
  ) {
    executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      identityBoundFinalLaunchHook: identityBoundFinalLaunchHook,
      launchObserver: launchObserver,
      identityBoundSpawnObserver: { receipt, request, processIdentifier in
        dispatchMonitor.recordIdentityBoundSpawn(
          receipt: receipt,
          request: request,
          processIdentifier: processIdentifier,
          permit: HDCServerDispatchPermitBinding.current)
      })
    self.semanticProfile = semanticProfile
    self.dispatchInstrumentationFault = dispatchInstrumentationFault
  }

  func execute(
    _ command: HDCProcessCommand,
    launchGate: ProcessAtomicLaunchGate? = nil,
    dispatchPermit: HDCServerDispatchPermit? = nil,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult> {
    let prepared = try prepare(command)
    defer { prepared.close() }
    if let launchGate {
      return try await executePrepared(
        prepared, launchGate: launchGate, dispatchPermit: dispatchPermit, onOutput: onOutput)
    }
    return try await HDCServerDispatchPermitBinding.$current.withValue(
      effectiveDispatchPermit(dispatchPermit)
    ) {
      try await executor.executePreparedIdentityBoundLaunch(
        prepared.process,
        evaluating: HDCRegisteredSemanticEvaluator(binding: prepared.semanticBinding),
        onOutput: onOutput)
    }
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
        securityScopedAccess: access)
    } catch {
      access.stop()
      throw error
    }
  }

  fileprivate func executePrepared(
    _ prepared: HDCPreparedProcessCommand,
    launchGate: ProcessAtomicLaunchGate,
    dispatchPermit: HDCServerDispatchPermit? = nil,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult> {
    try await HDCServerDispatchPermitBinding.$current.withValue(
      effectiveDispatchPermit(dispatchPermit)
    ) {
      try await executor.executePreparedIdentityBoundLaunch(
        prepared.process,
        gate: launchGate,
        evaluating: HDCRegisteredSemanticEvaluator(binding: prepared.semanticBinding),
        onOutput: onOutput)
    }
  }

  private func effectiveDispatchPermit(
    _ dispatchPermit: HDCServerDispatchPermit?
  ) -> HDCServerDispatchPermit? {
    dispatchInstrumentationFault == .removePermitBeforeSpawn ? nil : dispatchPermit
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
    if arguments.count == 3, arguments[2] == "spawn-sub" || arguments[2] == "killall-sub" {
      return .subserver
    }
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
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10))
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
/// runs the registered, read-only `checkserver` probe. It can observe health,
/// but without a process/server identity it can never claim external or
/// managed ownership and can never automatically restart this endpoint.
package actor HDCServerProcessSupervisor {
  private let supervisor: HDCServerSupervisor
  private let runner: HDCProcessCommandRunner
  private let clientVersionProbe: HDCClientVersionProcessProbe
  private let additionalChildEnvironment: [String: String]
  private let readOnlyProbeRegistry: HDCReadOnlyProbeRegistry
  private let semanticProfile: HDCRegisteredSemanticProfile
  private let identityObserver: any HDCServerProcessIdentityObserving
  /// The observer for the OPENHARMONY-TOOLS@0.6.0 commandless identity
  /// family. Production pins the exact 3.2.0f system observer; the contract
  /// seam below reuses the injected observer so the family's managed-startup
  /// path can be driven without the pinned executable.
  private let commandlessIdentityObserver: any HDCServerProcessIdentityObserving

  public init(
    supervisor: HDCServerSupervisor,
    additionalChildEnvironment: [String: String] = [:]
  ) {
    self.supervisor = supervisor
    let semanticProfile = HDCRegisteredSemanticProfile.pinnedProduction
    let runner = HDCProcessCommandRunner(
      semanticProfile: semanticProfile, dispatchMonitor: supervisor.dispatchMonitor)
    self.runner = runner
    clientVersionProbe = HDCClientVersionProcessProbe(
      runner: runner, additionalChildEnvironment: additionalChildEnvironment)
    self.additionalChildEnvironment = additionalChildEnvironment
    readOnlyProbeRegistry = .pinnedProduction
    self.semanticProfile = semanticProfile
    identityObserver = SystemHDCServerProcessIdentityObserver()
    commandlessIdentityObserver =
      HDCExact320FSystemIdentityObserver.supervisorObservationProduction
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
      semanticProfile: semanticProfile, dispatchMonitor: supervisor.dispatchMonitor)
    self.runner = runner
    clientVersionProbe = HDCClientVersionProcessProbe(
      runner: runner, additionalChildEnvironment: additionalChildEnvironment)
    self.additionalChildEnvironment = additionalChildEnvironment
    self.readOnlyProbeRegistry = readOnlyProbeRegistry
    self.semanticProfile = semanticProfile
    self.identityObserver = identityObserver
    commandlessIdentityObserver = identityObserver
  }

  /// Whether the selected executable belongs to the OPENHARMONY-TOOLS@0.6.0
  /// commandless identity family (hdc 3.2.0f) rather than the 0.3.0
  /// read-only `checkserver` family (hdc 3.2.0d).
  package static func selectsCommandlessFamily(_ toolchain: HDCCandidate) -> Bool {
    toolchain.sha256 == HDCSupervisorObservationProbeCatalog.targetExecutableSHA256
  }

  /// The managed-startup counterpart of `observeRegisteredExistingServer` for
  /// the commandless family.
  ///
  /// That family publishes a bracketed process/listener identity but no
  /// `checkserver` golden of its own, so its health is the host's readiness
  /// `checkserver`, parsed by the registered `openHarmony320Family` semantic
  /// parser and handed in as `serverVersion`. The generation is minted from
  /// the identity observation, exactly as the App facade does for this
  /// family; without this path a daemon that launched hdc 3.2.0f was gated
  /// on the 3.2.0d checkserver registry and could never bind its own server.
  package func observeManagedCommandlessServer(
    endpoint: HDCServerEndpointSelection,
    toolchain: HDCCandidate,
    serverVersion: String
  ) async -> HDCRegisteredServerObservationResult {
    guard Self.selectsCommandlessFamily(toolchain) else {
      return HDCRegisteredServerObservationResult(
        classification: .unsupported(
          reason: "selected executable is outside OPENHARMONY-TOOLS@0.6.0"))
    }
    let session = HDCSupervisorObservationApplicationSession.makeContract(
      supervisor: supervisor, toolchain: toolchain, endpointSelection: endpoint,
      identityObserver: commandlessIdentityObserver)
    let observation = await session.observe()
    let generation: Int
    switch observation.classification {
    case .observed(let observed):
      generation = observed
    case .unavailable(let reason):
      return HDCRegisteredServerObservationResult(classification: .unavailable(reason: reason))
    case .unknown(let reason):
      return HDCRegisteredServerObservationResult(classification: .unknown(reason: reason))
    case .timedOut:
      return HDCRegisteredServerObservationResult(classification: .timedOut)
    case .cancelled:
      return HDCRegisteredServerObservationResult(classification: .cancelled)
    case .unsupported(let reason):
      return HDCRegisteredServerObservationResult(classification: .unsupported(reason: reason))
    }
    guard let identity = observation.identity else {
      return HDCRegisteredServerObservationResult(
        classification: .unknown(reason: "commandless observation carried no identity"))
    }
    guard !serverVersion.isEmpty, !serverVersion.contains("\n") else {
      await supervisor.recordUnverifiedServerProbeFailure(
        endpoint: endpoint.endpoint,
        reason: "managed readiness checkserver did not establish a server version")
      return HDCRegisteredServerObservationResult(
        classification: .unknown(
          reason: "managed readiness checkserver did not establish a server version"),
        identity: identity)
    }
    let state = await supervisor.observeRegisteredServerIdentity(
      endpoint: endpoint.endpoint, health: .healthy, version: .known(serverVersion),
      generation: generation,
      reason:
        "managed launch readiness checkserver (openHarmony320Family) bound to the commandless identity observation")
    guard state.health == .healthy, state.generation == generation else {
      return HDCRegisteredServerObservationResult(
        classification: .unknown(
          reason: "supervisor did not retain the managed health and generation"),
        identity: identity)
    }
    return HDCRegisteredServerObservationResult(
      classification: .observed(generation: generation, serverVersion: serverVersion),
      identity: identity)
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
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10))
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
  package func observeRegisteredExistingServer(
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
          additionalChildEnvironment: additionalChildEnvironment, timeout: 10))
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
    await supervisor.observeRegisteredServerIdentity(
      endpoint: endpoint.endpoint, health: .healthy, version: .known(serverVersion),
      generation: generation,
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
public actor HDCProcessLifecycleExecutor: HDCServerLifecycleExecutor {
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
      semanticProfile: semanticProfile, dispatchMonitor: supervisor.dispatchMonitor)
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
      additionalChildEnvironment: additionalChildEnvironment, timeout: 15)
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
        prepared, launchGate: lease.launchGate, dispatchPermit: lease.dispatchPermit)
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

package enum HDCApplicationDiagnosticsConfiguration {
  package static let userConfiguredPathsPreferenceKey = "ArkDeck.HDC.userConfiguredPaths"
  package static let userConfiguredBookmarksPreferenceKey =
    "ArkDeck.HDC.userConfiguredSecurityScopedBookmarks"
  /// Read-only, maintainer-adjudicated operator surface:
  /// no code writes these two keys; operators seed them with
  /// `defaults write` on hosts whose SDK layout the automatic probes
  /// cannot see. Keep them read-only here.
  package static let devecoSDKPathsPreferenceKey = "ArkDeck.HDC.devecoSDKPaths"
  package static let openHarmonySDKPathsPreferenceKey = "ArkDeck.HDC.openHarmonySDKPaths"
  /// A support/automation override for the same explicit candidate setting.
  /// It is intentionally singular and absolute-path-only; it never enables
  /// PATH discovery or a UI-test fixture provider.
  package static let userConfiguredPathLaunchArgument = "--arkdeck-hdc-user-configured-path"
  package static let userConfiguredPathEnvironmentKey = "ARKDECK_HDC_USER_CONFIGURED_PATH"

  package static func discoveryRequest(
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
  package static func persistUserConfiguredExecutable(
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
  package static func clearUserConfiguredExecutable(
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
    return URL(filePath: value)
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

/// Closed App-facing projection of the internal device-observation event
/// vocabulary. Internal reasons, raw snapshots, and unchanged transitions are
/// deliberately absent.
public enum HDCDeviceObservationPresentationKind: String, Sendable, Equatable {
  case appeared
  case disappeared
  case observationUnknown
  case observationUnavailable
}

/// Immutable presentation event. The package-only initializer accepts a Date,
/// not a caller-formatted timestamp, so every timestamp is created at the
/// event-acceptance boundary in one exact UTC RFC 3339 form.
public struct HDCDeviceObservationPresentationEvent: Sendable, Equatable {
  public let timestamp: String
  public let kind: HDCDeviceObservationPresentationKind
  public let redactedDeviceIdentifier: String?

  package init(
    acceptedAt: Date,
    kind: HDCDeviceObservationPresentationKind,
    redactedDeviceIdentifier: String?
  ) {
    timestamp = ISO8601Timestamps.string(
      from: acceptedAt, includingFractionalSeconds: true)
    self.kind = kind
    self.redactedDeviceIdentifier = redactedDeviceIdentifier
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
  public let serverHealth: HDCServerHealth
  public let generation: String
  public let ownership: HDCServerOwnership
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
  /// Mirrors of the Supervisor dispatch monitor. The automatic counters are
  /// measured at the unique identity-bound spawn hook; the confirmed and
  /// managed counts stay independent fields and are never subtracted from or
  /// renamed into an automatic value.
  public let automaticLifecycleDispatchCount: Int
  public let automaticSubserverDispatchCount: Int
  public let confirmedLifecycleDispatchCount: Int
  public let managedStartDispatchCount: Int
  /// The endpoint selection source as originally selected; nil when no
  /// selection has been established for this presentation.
  public let endpointSource: HDCServerEndpointSource?
  /// Sorted names of environment keys injected into ArkDeck-owned child
  /// processes only. Values are deliberately not exposed; the parent process
  /// environment is never modified.
  public let childEnvironmentInjectionKeys: [String]
  /// Per-evidence ownership classification basis for the presented endpoint.
  public let ownershipBasis: HDCServerOwnershipBasis?
  /// Bounded App-facing history produced by the registered read-only device
  /// observation session. Raw connect keys and internal reasons never enter
  /// this value.
  public let deviceEvents: [HDCDeviceObservationPresentationEvent]

  public init(
    absolutePath: String,
    source: String,
    hash: String,
    platformTrust: String,
    clientVersion: String,
    serverVersion: String,
    daemonVersion: String,
    endpoint: String,
    serverHealth: HDCServerHealth = .unknown,
    generation: String,
    ownership: HDCServerOwnership,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState,
    tcpUnprotectedWarning: String? = nil,
    keyAccessError: String? = nil,
    subserverCapability: HDCSubserverCapability,
    lifecycleImpactPreview: HDCServerImpactSnapshot? = nil,
    lifecycleRecovery: HDCLifecycleRecoveryPresentation? = nil,
    criticalGateMessage: String? = nil,
    automaticLifecycleDispatchCount: Int = 0,
    automaticSubserverDispatchCount: Int = 0,
    confirmedLifecycleDispatchCount: Int = 0,
    managedStartDispatchCount: Int = 0,
    endpointSource: HDCServerEndpointSource? = nil,
    childEnvironmentInjectionKeys: [String] = [],
    ownershipBasis: HDCServerOwnershipBasis? = nil,
    deviceEvents: [HDCDeviceObservationPresentationEvent] = []
  ) {
    self.absolutePath = absolutePath
    self.source = source
    self.hash = hash
    self.platformTrust = platformTrust
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.daemonVersion = daemonVersion
    self.endpoint = endpoint
    self.serverHealth = serverHealth
    self.generation = generation
    self.ownership = ownership
    self.authorization = authorization
    self.channelProtection = channelProtection
    self.tcpUnprotectedWarning = tcpUnprotectedWarning
    self.keyAccessError = keyAccessError
    self.subserverCapability = subserverCapability
    self.automaticLifecycleDispatchCount = automaticLifecycleDispatchCount
    self.automaticSubserverDispatchCount = automaticSubserverDispatchCount
    self.confirmedLifecycleDispatchCount = confirmedLifecycleDispatchCount
    self.managedStartDispatchCount = managedStartDispatchCount
    self.endpointSource = endpointSource
    self.childEnvironmentInjectionKeys = childEnvironmentInjectionKeys
    self.ownershipBasis = ownershipBasis
    self.deviceEvents = deviceEvents
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

  /// Package-only immutable overlay used by Workflows after one explicit
  /// observation refresh. It copies the complete diagnostics value and cannot
  /// manufacture a source, runner, argv, or lifecycle capability.
  public func overlayingDeviceEvents(
    _ events: [HDCDeviceObservationPresentationEvent]
  ) -> HDCDiagnosticsPresentation {
    HDCDiagnosticsPresentation(
      absolutePath: absolutePath,
      source: source,
      hash: hash,
      platformTrust: platformTrust,
      clientVersion: clientVersion,
      serverVersion: serverVersion,
      daemonVersion: daemonVersion,
      endpoint: endpoint,
      serverHealth: serverHealth,
      generation: generation,
      ownership: ownership,
      authorization: authorization,
      channelProtection: channelProtection,
      tcpUnprotectedWarning: tcpUnprotectedWarning,
      keyAccessError: keyAccessError,
      subserverCapability: subserverCapability,
      lifecycleRecovery: lifecycleRecovery,
      criticalGateMessage: criticalGateMessage,
      automaticLifecycleDispatchCount: automaticLifecycleDispatchCount,
      automaticSubserverDispatchCount: automaticSubserverDispatchCount,
      confirmedLifecycleDispatchCount: confirmedLifecycleDispatchCount,
      managedStartDispatchCount: managedStartDispatchCount,
      endpointSource: endpointSource,
      childEnvironmentInjectionKeys: childEnvironmentInjectionKeys,
      ownershipBasis: ownershipBasis,
      deviceEvents: events)
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
package actor HDCReadOnlyDiagnosticsUseCase: HDCDiagnosticsStateProviding {
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
        endpoint: endpoint.endpoint.rawValue,
        reason: "No user-configured or SDK HDC candidate is available for diagnostics")
    }
    return HDCDiagnosticsPresentation(
      absolutePath: candidate.path.path, source: candidate.source.rawValue, hash: candidate.sha256,
      platformTrust: "unknown (trust inspection has not run)",
      clientVersion: "unknown (version probe has not run)",
      serverVersion: "unknown (checkserver has not run)",
      daemonVersion: "unknown (not exposed by a registered probe)",
      endpoint: endpoint.endpoint.rawValue, serverHealth: .unknown,
      generation: "unknown (server supervisor has not run)", ownership: .unknown,
      authorization: .unavailable(reason: "authorization probe requires a selected device"),
      channelProtection: .unverifiedAssumeUnprotected,
      tcpUnprotectedWarning:
        "Channel protection is unverified. Use TCP only on a trusted, isolated network.",
      keyAccessError:
        "Key access diagnostics are unsupported without a configured or user-approved locator.",
      subserverCapability: .unsupported,
      lifecycleRecovery: .unavailable(
        reason: "Recovery requires a verified endpoint and a Session-backed durable audit"),
      endpointSource: endpoint.source)
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
    endpoint: String = "unknown",
    reason: String
  ) -> HDCDiagnosticsPresentation {
    HDCDiagnosticsPresentation(
      absolutePath: "unknown (no configured candidate)", source: "unknown", hash: "unverified",
      platformTrust: "unverified", clientVersion: "unknown", serverVersion: "unknown",
      daemonVersion: "unknown", endpoint: endpoint, serverHealth: .unknown,
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
package actor HDCApplicationDiagnosticsProvider: HDCDiagnosticsStateProviding {
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
  package func attachSessionDiagnostics(_ useCase: HDCServerDiagnosticsUseCase) {
    sessionDiagnostics = useCase
  }

  /// Rebuilds the read-only phase after the App stores a new user-selected
  /// bookmark. Existing Session confirmation state is detached so authority
  /// from the previous candidate cannot survive the selection change.
  package func configure(
    discoveryRequest: HDCDiscoveryRequest,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    sessionDiagnostics = nil
    readOnlyDiagnostics = HDCReadOnlyDiagnosticsUseCase(
      discoveryRequest: discoveryRequest, inheritedEnvironment: inheritedEnvironment)
  }

  /// A finished or invalidated Session must not leave stale confirmation
  /// presentation reachable from a later App window.
  package func detachSessionDiagnostics() {
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
  private let childEnvironmentInjectionKeys: [String]
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
    lifecycleRecoveryUnavailableReason: String? = nil,
    childEnvironmentInjectionKeys: [String] = []
  ) {
    self.supervisor = supervisor
    self.snapshot = snapshot
    self.authorization = authorization
    self.channelProtection = channelProtection
    self.keyAccessError = keyAccessError
    self.subserverCapability = subserverCapability
    self.childEnvironmentInjectionKeys = childEnvironmentInjectionKeys.sorted()
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

  public func applyLifecycleDispatchResult(_ result: HDCServerLifecycleDispatchResult) async {
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
  public func applyRegisteredAuthorization(_ state: HDCAuthorizationState) {
    authorization = state
  }

  private var currentLifecycleRecoveryUnavailableReason: String? {
    configuredLifecycleRecoveryUnavailableReason ?? runtimeLifecycleRecoveryRequiredReason
  }

  private func presentation() async -> HDCDiagnosticsPresentation {
    let endpoint = HDCServerEndpoint(snapshot.endpoint)
    let state = await supervisor.state(for: endpoint)
    let serverVersion =
      state.map { diagnosticText($0.version) } ?? diagnosticText(snapshot.serverVersion)
    // The counter mirror is a verbatim snapshot of the monitor: automatic
    // values stay measured, and the confirmed/managed counts remain the
    // independent audit values without subtraction or renaming.
    let dispatchCounters = supervisor.dispatchMonitor.countersSnapshot()
    let ownershipBasis = await supervisor.ownershipBasis(for: endpoint)
    return HDCDiagnosticsPresentation(
      absolutePath: snapshot.path.path, source: snapshot.source.rawValue, hash: snapshot.sha256,
      platformTrust: diagnosticText(snapshot.platformTrust),
      clientVersion: diagnosticText(snapshot.clientVersion), serverVersion: serverVersion,
      daemonVersion: diagnosticText(snapshot.daemonVersion), endpoint: snapshot.endpoint,
      serverHealth: state?.health ?? .unknown,
      generation: state.map { diagnosticText($0.generationEvidence) }
        ?? diagnosticText(snapshot.serverGeneration),
      ownership: state?.ownership ?? .unknown, authorization: authorization,
      channelProtection: channelProtection,
      tcpUnprotectedWarning: channelProtection == .unverifiedAssumeUnprotected
        ? "Channel protection is unverified. Use TCP only on a trusted, isolated network."
        : nil,
      keyAccessError: keyAccessError, subserverCapability: subserverCapability,
      lifecycleRecovery: lifecycleRecovery,
      automaticLifecycleDispatchCount: dispatchCounters.automaticLifecycleDispatchCount,
      automaticSubserverDispatchCount: dispatchCounters.automaticSubserverDispatchCount,
      confirmedLifecycleDispatchCount: dispatchCounters.confirmedLifecycleDispatchCount,
      managedStartDispatchCount: dispatchCounters.managedStartDispatchCount,
      endpointSource: snapshot.endpointSource,
      childEnvironmentInjectionKeys: childEnvironmentInjectionKeys,
      ownershipBasis: ownershipBasis)
  }

  private func diagnosticText<T>(_ value: HDCProbeValue<T>) -> String {
    switch value {
    case .known(let value): String(describing: value)
    case .unknown(let reason): "unknown (\(reason))"
    }
  }
}

// MARK: - Registered zero-to-many device observation family

/// Closed Sources-side adoption of the single supported entry of
/// `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`
/// (`openspec/integrations/openharmony/device-observation-probes.yaml`).
/// The registered tool context is hdc 3.2.0f; it is deliberately a different
/// tool than the 3.2.0d read-only registry and the two must never be merged.
enum HDCDeviceObservationProbeCatalog {
  static let registryID = "OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES"
  static let registryVersion = "1.0.0"
  static let integrationProfile = "OPENHARMONY-TOOLS@0.5.0"
  static let entryID = "openharmony-hdc-device-observation-snapshot-3.2.0f-macos"
  static let family = "deviceObservationSnapshot"
  static let statusSupported = true
  static let invocationAllowed = true
  static let exactArguments = ["list", "targets", "-v"]
  static let exactEndpoint = "127.0.0.1:8710"
  static let targetToolVersion = "3.2.0f"
  static let targetExecutableSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  static let timeoutMilliseconds = 15_000
  static let emptyMarkerLine = "[Empty]\r\n"

  /// The zero-to-many family exists only while the registered entry stays
  /// supported and invocable with a non-empty exact argv. Absence must surface
  /// as a hard failure in the fan-out contract, never as a skip.
  static var familyIsRegistered: Bool {
    statusSupported && invocationAllowed && !exactArguments.isEmpty
  }
}

/// Parses the registered `tabDelimitedDeviceRowsOrEmptyMarker` raw family.
/// Presence is decided by the `state` column per the registered presence rule;
/// the parser itself never interprets row disappearance.
enum HDCDeviceObservationRawFamilyParser {
  static func parse(
    execution: ProcessExecutionResult,
    pseudonymize: (String) -> HDCObservedDeviceIdentifier
  ) -> HDCDeviceObservationSnapshot {
    if execution.termination == .timedOut {
      return .unavailable(reason: "device observation timed out")
    }
    if execution.termination == .cancelled {
      return .unavailable(reason: "device observation was cancelled")
    }
    guard execution.termination == .exited(0),
      execution.stderr.totalByteCount == 0,
      !execution.stdout.wasTruncated
    else {
      return .unknown(reason: "stderr was not empty, the exit was nonzero, or stdout truncated")
    }
    let data = execution.stdout.data
    guard !data.isEmpty else {
      return .unknown(reason: "zero-byte stdout is outside the registered raw family")
    }
    if data == Data(HDCDeviceObservationProbeCatalog.emptyMarkerLine.utf8) {
      return .observedEmpty
    }
    guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
      return .unknown(reason: "stdout is not a terminated UTF-8 row family")
    }
    var connectKeys: Set<String> = []
    var connected: [HDCObservedDeviceIdentifier] = []
    for var line in text.dropLast().components(separatedBy: "\n") {
      if line.hasSuffix("\r") { line = String(line.dropLast()) }
      guard !line.contains("\r") else {
        return .unknown(reason: "residual carriage return inside a device row field")
      }
      let columns = line.components(separatedBy: "\t")
      guard columns.count == 5 else {
        return .unknown(reason: "device row column count is outside the registered family")
      }
      let connectKey = columns[0]
      guard !connectKey.isEmpty,
        columns[2] == "USB",
        columns[3] == "Connected" || columns[3] == "Offline",
        columns[4] == "localhost"
      else {
        return .unknown(reason: "device row literal is outside the registered closed sets")
      }
      guard connectKeys.insert(connectKey).inserted else {
        return .unknown(reason: "duplicate connect key rows are outside the registered family")
      }
      if columns[3] == "Connected" {
        connected.append(pseudonymize(connectKey))
      }
    }
    guard !connected.isEmpty else { return .observedEmpty }
    return .observedConnectedSet(connected.sorted())
  }
}

/// Production source leg of the read-only device fan-out. It can only issue
/// the registered exact argv against the registered exact endpoint after a
/// stable pre/post existing-server identity bracket; every deviation is an
/// unavailable/unknown snapshot rather than a different command. Raw connect
/// keys never leave this adapter: identifiers are per-session HMAC-SHA-256
/// pseudonyms in the registered `redacted-device-<24 hex>` presentation.
actor HDCRegisteredDeviceObservationSource: HDCDeviceObservationSnapshotProviding {
  nonisolated let authority = HDCDeviceObservationSourceAuthority.integrationRegistered

  private let runner: HDCProcessCommandRunner
  private let toolchain: HDCCandidate
  private let endpointSelection: HDCServerEndpointSelection
  private let identityObserver: any HDCServerProcessIdentityObserving
  private let additionalChildEnvironment: [String: String]
  private let pseudonymKey: SymmetricKey
  private var runnerInvocationCount = 0

  init(
    runner: HDCProcessCommandRunner,
    toolchain: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection,
    identityObserver: any HDCServerProcessIdentityObserving,
    additionalChildEnvironment: [String: String] = [:],
    pseudonymKey: SymmetricKey = SymmetricKey(size: .bits256)
  ) {
    self.runner = runner
    self.toolchain = toolchain
    self.endpointSelection = endpointSelection
    self.identityObserver = identityObserver
    self.additionalChildEnvironment = additionalChildEnvironment
    self.pseudonymKey = pseudonymKey
  }

  func observe() async -> HDCDeviceObservationSnapshot {
    guard HDCDeviceObservationProbeCatalog.familyIsRegistered else {
      return .unavailable(
        reason: "the zero-to-many device observation family is not registered")
    }
    guard
      endpointSelection.endpoint.rawValue == HDCDeviceObservationProbeCatalog.exactEndpoint
    else {
      return .unavailable(reason: "endpoint differs from the registered exact endpoint")
    }
    let before = await identityObserver.observe(
      endpoint: endpointSelection.endpoint, selectedToolchain: toolchain)
    guard case .observed(let beforeReceipt) = before else {
      return .unavailable(reason: "existing-server identity precondition is unavailable")
    }
    let evaluated: SemanticallyEvaluatedIdentityBoundProcessResult<HDCCommandSemanticResult>
    do {
      runnerInvocationCount += 1
      evaluated = try await runner.execute(
        HDCProcessCommand(
          toolchain: toolchain,
          endpoint: endpointSelection,
          arguments: HDCDeviceObservationProbeCatalog.exactArguments,
          additionalChildEnvironment: additionalChildEnvironment,
          timeout: TimeInterval(HDCDeviceObservationProbeCatalog.timeoutMilliseconds) / 1_000))
    } catch {
      return .unavailable(reason: "device observation process could not run")
    }
    let after = await identityObserver.observe(
      endpoint: endpointSelection.endpoint, selectedToolchain: toolchain)
    guard case .observed(let afterReceipt) = after, afterReceipt == beforeReceipt else {
      return .unavailable(reason: "server identity changed across the device observation")
    }
    return HDCDeviceObservationRawFamilyParser.parse(execution: evaluated.execution) {
      connectKey in
      let code = HMAC<SHA256>.authenticationCode(
        for: Data(connectKey.utf8), using: pseudonymKey)
      let digest = SHA256Hex.lowercaseHex(code).prefix(24)
      return HDCObservedDeviceIdentifier(redactedKey: "redacted-device-\(digest)")
    }
  }

  func observedRunnerInvocationCount() -> Int {
    runnerInvocationCount
  }
}

/// One bounded application observation session. The production factory has no
/// source, runner, argv, clock, or pseudonym-key injection surface; it creates
/// the exact registered source internally only after the candidate and
/// endpoint gates pass. The separately named internal contract factory cannot
/// be referenced from ArkDeckWorkflows.
package actor HDCDeviceObservationApplicationSession {
  private let composition: HDCDeviceObservationComposition?
  private let productionSource: HDCRegisteredDeviceObservationSource?
  private let unavailableReason: String?
  private let unavailableBridge: HDCDeviceObservationPresentationBridge?
  private var refreshIsInFlight = false

  package static func makeProduction(
    toolchain: HDCCandidate,
    endpointSelection: HDCServerEndpointSelection
  ) -> HDCDeviceObservationApplicationSession {
    guard toolchain.sha256 == HDCDeviceObservationProbeCatalog.targetExecutableSHA256 else {
      return HDCDeviceObservationApplicationSession(
        unavailableReason: "candidate SHA-256 differs from the registered device observation tool")
    }
    guard endpointSelection.endpoint.rawValue == HDCDeviceObservationProbeCatalog.exactEndpoint
    else {
      return HDCDeviceObservationApplicationSession(
        unavailableReason: "endpoint differs from the registered device observation endpoint")
    }

    let source = HDCRegisteredDeviceObservationSource(
      runner: HDCProcessCommandRunner(semanticProfile: .deviceObservationProduction),
      toolchain: toolchain,
      endpointSelection: endpointSelection,
      identityObserver:
        HDCExact320FSystemIdentityObserver.deviceObservationProduction)
    guard
      let composition = try? HDCDeviceObservationComposition.makeProduction(
        source: source, capacity: 64)
    else {
      return HDCDeviceObservationApplicationSession(
        unavailableReason: "registered device observation composition is unavailable")
    }
    return HDCDeviceObservationApplicationSession(
      composition: composition, productionSource: source)
  }

  static func makeContract(
    source: any HDCDeviceObservationSnapshotProviding,
    capacity: Int = 64,
    clock: @escaping @Sendable () -> Date
  ) throws -> HDCDeviceObservationApplicationSession {
    HDCDeviceObservationApplicationSession(
      composition: try HDCDeviceObservationComposition.makeProduction(
        source: source, capacity: capacity, clock: clock),
      productionSource: nil)
  }

  private init(
    composition: HDCDeviceObservationComposition,
    productionSource: HDCRegisteredDeviceObservationSource?
  ) {
    self.composition = composition
    self.productionSource = productionSource
    unavailableReason = nil
    unavailableBridge = nil
  }

  private init(unavailableReason: String) {
    composition = nil
    productionSource = nil
    self.unavailableReason = unavailableReason
    unavailableBridge = HDCDeviceObservationPresentationBridge(capacity: 64)
  }

  package func refresh() async -> [HDCDeviceObservationPresentationEvent] {
    guard !refreshIsInFlight else { return await currentEvents() }
    refreshIsInFlight = true
    defer { refreshIsInFlight = false }

    if let composition {
      await composition.pollOnce()
      return await composition.presentationEvents()
    }
    if let unavailableReason, let unavailableBridge {
      await unavailableBridge.ingest([
        .observationUnavailable(reason: unavailableReason)
      ])
      return await unavailableBridge.events()
    }
    return []
  }

  package func currentEvents() async -> [HDCDeviceObservationPresentationEvent] {
    if let composition {
      return await composition.presentationEvents()
    }
    return await unavailableBridge?.events() ?? []
  }

  func observedRunnerInvocationCount() async -> Int {
    await productionSource?.observedRunnerInvocationCount() ?? 0
  }
}

// NOTE (CHG-2026-047 T06): endpoint selection and the authorization/
// security surface moved to sibling files as pure moves. Everything else
// stays here by design: the dispatch-security core's private/fileprivate
// web is a load-bearing anti-forgery boundary (HDCServerDispatchPermit's
// fileprivate-only initializer), and the diagnostics use-cases plus the
// registered device observation family are pinned to this exact file by
// sibling-change source-scan guards (HDCDeviceObservationPresentation
// ContractTests DP1/DP13/DP19; HDCSupervisorObservabilityContractTests
// C6). Relocating them requires those changes' consent - deferred to T23.
