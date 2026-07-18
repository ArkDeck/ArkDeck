import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

/// `PORT-PROCESS-001` macOS implementation.
///
/// The request intentionally has an executable URL and an argument array rather
/// than a command string. This module never invokes a host shell.
public enum ArkDeckProcessModule {
  public static let identifier = "ArkDeckProcess"
}

public enum ProcessStream: String, Sendable, Equatable, Hashable {
  case stdout
  case stderr
}

public struct ProcessOutputChunk: Sendable, Equatable {
  public let stream: ProcessStream
  public let bytes: Data

  public init(stream: ProcessStream, bytes: Data) {
    self.stream = stream
    self.bytes = bytes
  }
}

/// The in-memory portion of one stream. `totalByteCount` always includes data
/// forwarded to `onOutput`, even when `data` is intentionally truncated.
public struct ProcessStreamCapture: Sendable, Equatable {
  public let data: Data
  public let totalByteCount: Int64
  public let wasTruncated: Bool

  public init(data: Data, totalByteCount: Int64, wasTruncated: Bool) {
    self.data = data
    self.totalByteCount = totalByteCount
    self.wasTruncated = wasTruncated
  }
}

public enum ProcessTermination: Sendable, Equatable {
  case exited(Int32)
  case signalled(Int32)
  case timedOut
  case cancelled
  case waitFailed(Int32)
  case unrecognizedWaitStatus(Int32)
}

/// The result of the executor's bounded attempt to terminate the dedicated
/// process group after timeout or cancellation.
///
/// An unconfirmed result is deliberately distinct from success: callers must
/// not infer descendant cleanup merely because the process-group leader exited.
public enum ProcessGroupTerminationResult: Sendable, Equatable {
  case notRequested
  case noSurvivingMembers(forcedKill: Bool)
  case unconfirmed(forcedKill: Bool)
}

public struct ProcessExecutionResult: Sendable, Equatable {
  public let termination: ProcessTermination
  public let processGroupTermination: ProcessGroupTerminationResult
  public let stdout: ProcessStreamCapture
  public let stderr: ProcessStreamCapture

  public init(
    termination: ProcessTermination,
    processGroupTermination: ProcessGroupTerminationResult = .notRequested,
    stdout: ProcessStreamCapture,
    stderr: ProcessStreamCapture
  ) {
    self.termination = termination
    self.processGroupTermination = processGroupTermination
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// A common result vocabulary for Adapter-owned semantic evaluators. Process
/// exit status is intentionally not sufficient to construct one of these
/// values; the Adapter decides after consuming the raw byte streams.
public enum ProcessSemanticResult<Failure: Sendable & Equatable>: Sendable, Equatable {
  case success
  case failure(Failure)
  case unknownOutput
}

/// Streaming semantic classification supplied by a tool Adapter. Evaluators
/// receive every stdout/stderr byte before retained capture is truncated.
public protocol ProcessSemanticEvaluating: Sendable {
  associatedtype SemanticResult: Sendable

  mutating func consume(_ chunk: ProcessOutputChunk)
  mutating func finish(execution: ProcessExecutionResult) -> SemanticResult
}

public struct SemanticallyEvaluatedProcessResult<SemanticResult: Sendable>: Sendable {
  public let execution: ProcessExecutionResult
  public let semantic: SemanticResult

  public init(execution: ProcessExecutionResult, semantic: SemanticResult) {
    self.execution = execution
    self.semantic = semantic
  }
}

extension SemanticallyEvaluatedProcessResult: Equatable where SemanticResult: Equatable {}

public struct ProcessRequest: Sendable, Equatable {
  public let executable: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let timeout: TimeInterval?

  /// `environment` is overlaid only on this child process's inherited
  /// environment. It never writes a user or system-wide environment value.
  public init(
    executable: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    timeout: TimeInterval? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.timeout = timeout
  }
}

/// Expected immutable executable identity supplied by a durable Job intent.
/// The Process port reopens and hashes the file itself; this value is not an
/// authorization merely because a caller constructed it.
public struct ProcessIdentityBoundRequest: Sendable, Equatable {
  public let process: ProcessRequest
  public let expectedSHA256: String

  public init(process: ProcessRequest, expectedSHA256: String) {
    self.process = process
    self.expectedSHA256 = expectedSHA256
  }
}

/// Identity of the descriptor that was actually handed to `posix_spawn`.
/// `authorizedPath` is diagnostic provenance; device/inode/hash identify the
/// opened executable object and never come from a caller-provided snapshot.
public struct ProcessExecutableIdentityReceipt: Sendable, Equatable, Codable {
  public let authorizedPath: String
  public let inodeLaunchPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: Int64
  public let mode: UInt32
  public let sha256: String

  public init(
    authorizedPath: String,
    inodeLaunchPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: Int64,
    mode: UInt32,
    sha256: String
  ) {
    self.authorizedPath = authorizedPath
    self.inodeLaunchPath = inodeLaunchPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.mode = mode
    self.sha256 = sha256
  }
}

public struct ProcessIdentityBoundExecutionResult: Sendable, Equatable {
  public let execution: ProcessExecutionResult
  public let executableIdentity: ProcessExecutableIdentityReceipt

  public init(
    execution: ProcessExecutionResult,
    executableIdentity: ProcessExecutableIdentityReceipt
  ) {
    self.execution = execution
    self.executableIdentity = executableIdentity
  }
}

public struct SemanticallyEvaluatedIdentityBoundProcessResult<SemanticResult: Sendable>: Sendable {
  public let execution: ProcessExecutionResult
  public let semantic: SemanticResult
  public let executableIdentity: ProcessExecutableIdentityReceipt

  public init(
    execution: ProcessExecutionResult,
    semantic: SemanticResult,
    executableIdentity: ProcessExecutableIdentityReceipt
  ) {
    self.execution = execution
    self.semantic = semantic
    self.executableIdentity = executableIdentity
  }
}

extension SemanticallyEvaluatedIdentityBoundProcessResult: Equatable
where SemanticResult: Equatable {}

/// One-shot state gate shared with the package-owned Supervisor. Invalidation
/// and the `posix_spawn` syscall use the same lock, so a state change cannot
/// land between final gate validation and the kernel launch attempt.
package final class ProcessAtomicLaunchGate: @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated = false
  private var consumed = false

  package init() {}

  package func invalidate() {
    lock.withLock { invalidated = true }
  }

  fileprivate func consume<T>(_ launch: () throws -> T) throws -> T {
    try lock.withLock {
      guard !invalidated, !consumed else {
        throw ProcessExecutionError.launchAuthorizationInvalidated
      }
      consumed = true
      return try launch()
    }
  }
}

/// Package-owned, one-shot authorization retaining the exact verified
/// executable descriptors between durable receipt persistence and spawn.
/// Callers can inspect the receipt but cannot construct or reuse the token.
package final class ProcessPreparedIdentityBoundLaunch: @unchecked Sendable {
  package let request: ProcessIdentityBoundRequest
  package let executableIdentity: ProcessExecutableIdentityReceipt
  fileprivate let executable: VerifiedExecutableDescriptor
  private let lock = NSLock()
  private var consumed = false

  fileprivate init(
    request: ProcessIdentityBoundRequest,
    executable: VerifiedExecutableDescriptor
  ) {
    self.request = request
    self.executableIdentity = executable.receipt
    self.executable = executable
  }

  fileprivate func consume() throws {
    try lock.withLock {
      guard !consumed else {
        throw ProcessExecutionError.launchAuthorizationInvalidated
      }
      consumed = true
    }
  }

  package func close() {
    executable.close()
  }

  deinit { executable.close() }
}

package enum ProcessIdentityBoundLaunchFault: Sendable {
  case none
  case closeDescriptorBeforeSpawn
}

public enum ProcessExecutionError: Error, Equatable, LocalizedError {
  case executableMustBeAbsolute(String)
  case invalidExecutableContainsNUL
  case invalidArgumentContainsNUL
  case invalidEnvironmentKey(String)
  case invalidEnvironmentValue(String)
  case invalidTimeout(TimeInterval)
  case invalidExpectedSHA256
  case executableOpenFailed(String, Int32)
  case executableMustNotBeSymlink
  case executableMustBeRegularFile
  case executableMustBeExecutable
  case executableIdentityChanged
  case executableInodePathUnavailable
  case executableHashMismatch(expected: String, actual: String)
  case executableDescriptorInvalid
  case launchAuthorizationInvalidated
  case launchFailed(String)

  public var errorDescription: String? {
    switch self {
    case .executableMustBeAbsolute(let path):
      "Process executable must be an absolute file URL: \(path)"
    case .invalidExecutableContainsNUL:
      "Process executable must not contain NUL bytes"
    case .invalidArgumentContainsNUL:
      "Process arguments must not contain NUL bytes"
    case .invalidEnvironmentKey(let key):
      "Process environment key is invalid: \(key)"
    case .invalidEnvironmentValue(let key):
      "Process environment value contains a NUL byte for key: \(key)"
    case .invalidTimeout(let timeout):
      "Process timeout must be finite and positive: \(timeout)"
    case .invalidExpectedSHA256:
      "Expected executable SHA-256 must be 64 lowercase hexadecimal characters"
    case .executableOpenFailed(let path, let code):
      "Process executable could not be opened without following links: \(path) (errno \(code))"
    case .executableMustNotBeSymlink:
      "Process executable must not be a symbolic link"
    case .executableMustBeRegularFile:
      "Process executable descriptor must identify a regular file"
    case .executableMustBeExecutable:
      "Process executable does not have an executable mode"
    case .executableIdentityChanged:
      "Process executable path or descriptor identity changed before spawn"
    case .executableInodePathUnavailable:
      "Process executable cannot be addressed by a stable device/inode path on this volume"
    case .executableHashMismatch(let expected, let actual):
      "Process executable hash mismatch: expected \(expected), observed \(actual)"
    case .executableDescriptorInvalid:
      "Process executable descriptor became invalid before spawn"
    case .launchAuthorizationInvalidated:
      "Process launch authorization was invalidated or already consumed"
    case .launchFailed(let message):
      "Process could not start: \(message)"
    }
  }
}

public typealias ProcessOutputHandler = @Sendable (ProcessOutputChunk) -> Void

/// A `posix_spawn` adapter with a dedicated process group, separate streamed
/// stdout/stderr, and bounded in-memory captures. `onOutput` receives every
/// chunk so a future Artifact writer can persist raw output without making
/// memory grow with the output size. Timeout and cancellation signal only the
/// spawned process group, which also prevents a descendant from surviving the
/// parent process.
public final class FoundationProcessExecutor: @unchecked Sendable {
  private let identityBoundPreSpawnHook: @Sendable (ProcessExecutableIdentityReceipt) throws -> Void
  private let identityBoundFinalLaunchHook:
    @Sendable (ProcessExecutableIdentityReceipt) async throws -> Void
  private let launchObserver: @Sendable (pid_t) -> Void
  private let identityBoundLaunchFault: ProcessIdentityBoundLaunchFault

  public init() {
    identityBoundPreSpawnHook = { _ in }
    identityBoundFinalLaunchHook = { _ in }
    launchObserver = { _ in }
    identityBoundLaunchFault = .none
  }

  package init(
    identityBoundPreSpawnHook:
      @escaping @Sendable (ProcessExecutableIdentityReceipt) throws
      -> Void,
    identityBoundFinalLaunchHook:
      @escaping @Sendable (ProcessExecutableIdentityReceipt) async throws -> Void = { _ in },
    launchObserver: @escaping @Sendable (pid_t) -> Void,
    identityBoundLaunchFault: ProcessIdentityBoundLaunchFault = .none
  ) {
    self.identityBoundPreSpawnHook = identityBoundPreSpawnHook
    self.identityBoundFinalLaunchHook = identityBoundFinalLaunchHook
    self.launchObserver = launchObserver
    self.identityBoundLaunchFault = identityBoundLaunchFault
  }

  public func execute(
    _ request: ProcessRequest,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> ProcessExecutionResult {
    try validate(request)

    let control = ProcessControl()
    return try await withTaskCancellationHandler(
      operation: {
        guard !Task.isCancelled else { return .empty(termination: .cancelled) }
        return try await start(
          request,
          captureLimit: max(0, captureLimit),
          control: control,
          onOutput: onOutput
        )
      },
      onCancel: {
        control.stop(reason: .cancelled)
      })
  }

  /// Runs a process while allowing an Adapter to classify the complete raw
  /// byte stream. The semantic result remains independent from the process
  /// termination status, including the exit-zero case.
  public func execute<Evaluator: ProcessSemanticEvaluating>(
    _ request: ProcessRequest,
    evaluating evaluator: Evaluator,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedProcessResult<Evaluator.SemanticResult> {
    let evaluation = SemanticEvaluationBox(evaluator)
    let execution = try await execute(request, captureLimit: captureLimit) { chunk in
      evaluation.consume(chunk)
      onOutput(chunk)
    }
    return SemanticallyEvaluatedProcessResult(
      execution: execution,
      semantic: evaluation.finish(execution: execution)
    )
  }

  /// Opens without following symlinks, validates the descriptor identity and
  /// hash, rechecks the pathname, then executes Darwin's stable
  /// `/.vol/<device>/<inode>` name while retaining the same descriptor through
  /// the `posix_spawn` syscall.
  public func executeIdentityBound(
    _ request: ProcessIdentityBoundRequest,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> ProcessIdentityBoundExecutionResult {
    try await executeIdentityBoundImpl(
      request, gate: nil, captureLimit: captureLimit, onOutput: onOutput)
  }

  package func executeIdentityBound(
    _ request: ProcessIdentityBoundRequest,
    gate: ProcessAtomicLaunchGate,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> ProcessIdentityBoundExecutionResult {
    try await executeIdentityBoundImpl(
      request, gate: gate, captureLimit: captureLimit, onOutput: onOutput)
  }

  public func executeIdentityBound<Evaluator: ProcessSemanticEvaluating>(
    _ request: ProcessIdentityBoundRequest,
    evaluating evaluator: Evaluator,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<Evaluator.SemanticResult> {
    let evaluation = SemanticEvaluationBox(evaluator)
    let result = try await executeIdentityBound(request, captureLimit: captureLimit) { chunk in
      evaluation.consume(chunk)
      onOutput(chunk)
    }
    return SemanticallyEvaluatedIdentityBoundProcessResult(
      execution: result.execution,
      semantic: evaluation.finish(execution: result.execution),
      executableIdentity: result.executableIdentity)
  }

  package func executeIdentityBound<Evaluator: ProcessSemanticEvaluating>(
    _ request: ProcessIdentityBoundRequest,
    gate: ProcessAtomicLaunchGate,
    evaluating evaluator: Evaluator,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<Evaluator.SemanticResult> {
    let evaluation = SemanticEvaluationBox(evaluator)
    let result = try await executeIdentityBound(
      request, gate: gate, captureLimit: captureLimit
    ) { chunk in
      evaluation.consume(chunk)
      onOutput(chunk)
    }
    return SemanticallyEvaluatedIdentityBoundProcessResult(
      execution: result.execution,
      semantic: evaluation.finish(execution: result.execution),
      executableIdentity: result.executableIdentity)
  }

  package func prepareIdentityBoundLaunch(
    _ request: ProcessIdentityBoundRequest
  ) throws -> ProcessPreparedIdentityBoundLaunch {
    try validate(request.process)
    guard Self.isValidSHA256(request.expectedSHA256) else {
      throw ProcessExecutionError.invalidExpectedSHA256
    }
    let executable = try VerifiedExecutableDescriptor.open(
      path: request.process.executable, expectedSHA256: request.expectedSHA256)
    do {
      try identityBoundPreSpawnHook(executable.receipt)
      if identityBoundLaunchFault == .closeDescriptorBeforeSpawn {
        executable.close()
      }
      try executable.revalidate(path: request.process.executable)
      return ProcessPreparedIdentityBoundLaunch(request: request, executable: executable)
    } catch {
      executable.close()
      throw error
    }
  }

  package func executePreparedIdentityBoundLaunch<Evaluator: ProcessSemanticEvaluating>(
    _ prepared: ProcessPreparedIdentityBoundLaunch,
    evaluating evaluator: Evaluator,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<Evaluator.SemanticResult> {
    let evaluation = SemanticEvaluationBox(evaluator)
    let result = try await executePreparedIdentityBoundLaunchImpl(
      prepared, gate: nil, captureLimit: captureLimit
    ) { chunk in
      evaluation.consume(chunk)
      onOutput(chunk)
    }
    return SemanticallyEvaluatedIdentityBoundProcessResult(
      execution: result.execution,
      semantic: evaluation.finish(execution: result.execution),
      executableIdentity: result.executableIdentity)
  }

  package func executePreparedIdentityBoundLaunch<Evaluator: ProcessSemanticEvaluating>(
    _ prepared: ProcessPreparedIdentityBoundLaunch,
    gate: ProcessAtomicLaunchGate,
    evaluating evaluator: Evaluator,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> SemanticallyEvaluatedIdentityBoundProcessResult<Evaluator.SemanticResult> {
    let evaluation = SemanticEvaluationBox(evaluator)
    let result = try await executePreparedIdentityBoundLaunchImpl(
      prepared, gate: gate, captureLimit: captureLimit
    ) { chunk in
      evaluation.consume(chunk)
      onOutput(chunk)
    }
    return SemanticallyEvaluatedIdentityBoundProcessResult(
      execution: result.execution,
      semantic: evaluation.finish(execution: result.execution),
      executableIdentity: result.executableIdentity)
  }

  private func executeIdentityBoundImpl(
    _ request: ProcessIdentityBoundRequest,
    gate: ProcessAtomicLaunchGate?,
    captureLimit: Int,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProcessIdentityBoundExecutionResult {
    let prepared = try prepareIdentityBoundLaunch(request)
    return try await executePreparedIdentityBoundLaunchImpl(
      prepared, gate: gate, captureLimit: captureLimit, onOutput: onOutput)
  }

  private func executePreparedIdentityBoundLaunchImpl(
    _ prepared: ProcessPreparedIdentityBoundLaunch,
    gate: ProcessAtomicLaunchGate?,
    captureLimit: Int,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProcessIdentityBoundExecutionResult {
    let control = ProcessControl()
    return try await withTaskCancellationHandler(
      operation: {
        guard !Task.isCancelled else {
          throw ProcessExecutionError.launchAuthorizationInvalidated
        }
        return try await startPreparedIdentityBound(
          prepared,
          gate: gate,
          captureLimit: max(0, captureLimit),
          control: control,
          onOutput: onOutput)
      },
      onCancel: {
        control.stop(reason: .cancelled)
      })
  }

  private func validate(_ request: ProcessRequest) throws {
    guard request.executable.isFileURL, request.executable.path.hasPrefix("/") else {
      throw ProcessExecutionError.executableMustBeAbsolute(request.executable.path)
    }
    guard !request.executable.path.contains("\0"),
      !request.executable.absoluteString.localizedCaseInsensitiveContains("%00")
    else {
      throw ProcessExecutionError.invalidExecutableContainsNUL
    }
    guard request.timeout.map({ $0.isFinite && $0 > 0 }) ?? true else {
      throw ProcessExecutionError.invalidTimeout(request.timeout ?? 0)
    }
    guard !request.arguments.contains(where: { $0.contains("\0") }) else {
      throw ProcessExecutionError.invalidArgumentContainsNUL
    }
    for (key, value) in request.environment {
      guard !key.isEmpty, !key.contains("="), !key.contains("\0") else {
        throw ProcessExecutionError.invalidEnvironmentKey(key)
      }
      guard !value.contains("\0") else {
        throw ProcessExecutionError.invalidEnvironmentValue(key)
      }
    }
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  private func start(
    _ request: ProcessRequest,
    captureLimit: Int,
    control: ProcessControl,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProcessExecutionResult {
    guard !control.hasStopRequest else {
      return .empty(termination: control.termination ?? .cancelled)
    }

    let spawned = try spawn(request)
    return await collectExecution(
      of: spawned,
      request: request,
      captureLimit: captureLimit,
      control: control,
      onOutput: onOutput)
  }

  private func startPreparedIdentityBound(
    _ prepared: ProcessPreparedIdentityBoundLaunch,
    gate: ProcessAtomicLaunchGate?,
    captureLimit: Int,
    control: ProcessControl,
    onOutput: @escaping ProcessOutputHandler
  ) async throws -> ProcessIdentityBoundExecutionResult {
    guard !control.hasStopRequest else {
      throw ProcessExecutionError.launchAuthorizationInvalidated
    }
    try prepared.consume()
    defer { prepared.close() }
    let executable = prepared.executable
    try executable.revalidate(path: prepared.request.process.executable)
    try await identityBoundFinalLaunchHook(executable.receipt)
    guard !control.hasStopRequest else {
      throw ProcessExecutionError.launchAuthorizationInvalidated
    }

    let launch = {
      try executable.revalidate(path: prepared.request.process.executable)
      guard !control.hasStopRequest else {
        throw ProcessExecutionError.launchAuthorizationInvalidated
      }
      return try self.spawn(
        prepared.request.process,
        executablePath: executable.inodeLaunchPath)
    }
    let spawned = try gate.map { try $0.consume(launch) } ?? launch()
    let execution = await collectExecution(
      of: spawned,
      request: prepared.request.process,
      captureLimit: captureLimit,
      control: control,
      onOutput: onOutput)
    return ProcessIdentityBoundExecutionResult(
      execution: execution, executableIdentity: executable.receipt)
  }

  private func collectExecution(
    of spawned: SpawnedProcess,
    request: ProcessRequest,
    captureLimit: Int,
    control: ProcessControl,
    onOutput: @escaping ProcessOutputHandler
  ) async -> ProcessExecutionResult {
    let capture = OutputCapture(limit: captureLimit, onOutput: onOutput)
    let drain = PipeDrain()
    control.attach(drain: drain)
    installReader(for: spawned.stdout, stream: .stdout, capture: capture, drain: drain)
    installReader(for: spawned.stderr, stream: .stderr, capture: capture, drain: drain)
    control.attach(processIdentifier: spawned.processIdentifier)
    let timeoutTask = makeTimeoutTask(for: request.timeout, control: control)
    defer { timeoutTask?.cancel() }

    let waitResult = await waitForExit(of: spawned.processIdentifier)
    await drain.waitUntilFinished()
    let groupTermination = await control.waitForProcessGroupTermination()
    return ProcessExecutionResult(
      termination: control.termination ?? termination(from: waitResult),
      processGroupTermination: groupTermination,
      stdout: capture.capture(for: .stdout),
      stderr: capture.capture(for: .stderr)
    )
  }

  private func spawn(
    _ request: ProcessRequest,
    executablePath: String? = nil
  ) throws -> SpawnedProcess {
    var arguments = try makeCStringVector([request.executable.path] + request.arguments)
    defer { freeCStringVector(arguments) }
    var environment = try makeCStringVector(
      ProcessInfo.processInfo.environment
        .merging(request.environment) { _, requested in requested }
        .sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" }
    )
    defer { freeCStringVector(environment) }

    var stdoutDescriptors: [Int32] = [-1, -1]
    var stderrDescriptors: [Int32] = [-1, -1]
    defer { closeAll(stdoutDescriptors + stderrDescriptors) }
    guard Darwin.pipe(&stdoutDescriptors) == 0 else {
      throw ProcessExecutionError.launchFailed(
        "could not allocate output pipes: \(String(cString: strerror(errno)))")
    }
    guard Darwin.pipe(&stderrDescriptors) == 0 else {
      throw ProcessExecutionError.launchFailed(
        "could not allocate output pipes: \(String(cString: strerror(errno)))")
    }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var initializedFileActions = false
    var initializedAttributes = false
    defer {
      if initializedFileActions {
        posix_spawn_file_actions_destroy(&fileActions)
      }
      if initializedAttributes {
        posix_spawnattr_destroy(&attributes)
      }
    }

    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw ProcessExecutionError.launchFailed("could not initialize posix_spawn file actions")
    }
    initializedFileActions = true
    guard posix_spawn_file_actions_adddup2(&fileActions, stdoutDescriptors[1], STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, stderrDescriptors[1], STDERR_FILENO) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[0]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[0]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[1]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[1]) == 0
    else {
      throw ProcessExecutionError.launchFailed("could not configure posix_spawn")
    }
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw ProcessExecutionError.launchFailed("could not initialize posix_spawn attributes")
    }
    initializedAttributes = true
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw ProcessExecutionError.launchFailed("could not configure posix_spawn process group")
    }

    var processIdentifier: pid_t = 0
    let spawnResult = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
      environment.withUnsafeMutableBufferPointer { environmentBuffer in
        (executablePath ?? request.executable.path).withCString { executablePath in
          posix_spawn(
            &processIdentifier,
            executablePath,
            &fileActions,
            &attributes,
            argumentBuffer.baseAddress,
            environmentBuffer.baseAddress
          )
        }
      }
    }
    Darwin.close(stdoutDescriptors[1])
    stdoutDescriptors[1] = -1
    Darwin.close(stderrDescriptors[1])
    stderrDescriptors[1] = -1

    guard spawnResult == 0 else {
      throw ProcessExecutionError.launchFailed(String(cString: strerror(spawnResult)))
    }
    launchObserver(processIdentifier)
    let stdout = stdoutDescriptors[0]
    stdoutDescriptors[0] = -1
    let stderr = stderrDescriptors[0]
    stderrDescriptors[0] = -1
    return SpawnedProcess(
      processIdentifier: processIdentifier,
      stdout: stdout,
      stderr: stderr
    )
  }

  private func installReader(
    for descriptor: Int32,
    stream: ProcessStream,
    capture: OutputCapture,
    drain: PipeDrain
  ) {
    drain.enter()
    DispatchQueue.global(qos: .utility).async {
      defer {
        Darwin.close(descriptor)
        drain.leave()
      }
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      var pollDescriptor = pollfd(
        fd: descriptor,
        events: Int16(POLLIN | POLLHUP | POLLERR),
        revents: 0
      )
      while !drain.isCancelled {
        pollDescriptor.revents = 0
        let pollResult = Darwin.poll(&pollDescriptor, 1, 25)
        if pollResult == -1 {
          if errno == EINTR {
            continue
          }
          return
        }
        if pollResult == 0 {
          continue
        }
        guard !drain.isCancelled else { return }
        let byteCount = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if byteCount > 0 {
          capture.accept(
            ProcessOutputChunk(
              stream: stream,
              bytes: Data(buffer.prefix(byteCount))
            )
          )
          continue
        }
        if byteCount == -1, errno == EINTR {
          continue
        }
        return
      }
    }
  }

  private func waitForExit(of processIdentifier: pid_t) async -> ProcessWaitResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        var status: Int32 = 0
        while true {
          if Darwin.waitpid(processIdentifier, &status, 0) == processIdentifier {
            continuation.resume(returning: .status(status))
            return
          }
          if errno != EINTR {
            continuation.resume(returning: .failure(errno))
            return
          }
        }
      }
    }
  }

  private func termination(from waitResult: ProcessWaitResult) -> ProcessTermination {
    let status: Int32
    switch waitResult {
    case .status(let observedStatus):
      status = observedStatus
    case .failure(let code):
      return .waitFailed(code)
    }
    // Equivalent to the Darwin WIFEXITED/WEXITSTATUS and WTERMSIG macros,
    // which Swift cannot import because they are function-like macros.
    let terminationSignal = status & 0x7f
    if terminationSignal == 0 {
      return .exited((status >> 8) & 0xff)
    }
    if terminationSignal != 0x7f {
      return .signalled(terminationSignal)
    }
    return .unrecognizedWaitStatus(status)
  }

  private func makeTimeoutTask(for timeout: TimeInterval?, control: ProcessControl) -> Task<
    Void, Never
  >? {
    guard let timeout else { return nil }
    let requestedNanoseconds = timeout * 1_000_000_000
    let nanoseconds =
      requestedNanoseconds >= Double(UInt64.max)
      ? UInt64.max
      : UInt64(requestedNanoseconds.rounded(.up))
    return Task {
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      control.stop(reason: .timedOut)
    }
  }
}

private final class VerifiedExecutableDescriptor {
  private(set) var fileDescriptor: Int32
  private var hashDescriptor: Int32
  let receipt: ProcessExecutableIdentityReceipt
  private let expectedSHA256: String
  private let openedDevice: dev_t
  private let openedInode: ino_t

  var inodeLaunchPath: String { receipt.inodeLaunchPath }

  private init(
    fileDescriptor: Int32,
    hashDescriptor: Int32,
    receipt: ProcessExecutableIdentityReceipt,
    expectedSHA256: String,
    openedDevice: dev_t,
    openedInode: ino_t
  ) {
    self.fileDescriptor = fileDescriptor
    self.hashDescriptor = hashDescriptor
    self.receipt = receipt
    self.expectedSHA256 = expectedSHA256
    self.openedDevice = openedDevice
    self.openedInode = openedInode
  }

  static func open(path: URL, expectedSHA256: String) throws -> VerifiedExecutableDescriptor {
    var pathMetadata = stat()
    guard path.path.withCString({ lstat($0, &pathMetadata) }) == 0 else {
      throw ProcessExecutionError.executableOpenFailed(path.path, errno)
    }
    guard (pathMetadata.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
      throw ProcessExecutionError.executableMustNotBeSymlink
    }

    let descriptor = Darwin.open(path.path, O_EXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw ProcessExecutionError.executableMustNotBeSymlink
      }
      throw ProcessExecutionError.executableOpenFailed(path.path, errno)
    }
    let hashDescriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW)
    guard hashDescriptor >= 0 else {
      let openError = errno
      Darwin.close(descriptor)
      throw ProcessExecutionError.executableOpenFailed(path.path, openError)
    }
    do {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
        fcntl(hashDescriptor, F_SETFD, FD_CLOEXEC) == 0
      else {
        throw ProcessExecutionError.executableDescriptorInvalid
      }
      var descriptorMetadata = stat()
      var hashDescriptorMetadata = stat()
      guard fstat(descriptor, &descriptorMetadata) == 0 else {
        throw ProcessExecutionError.executableDescriptorInvalid
      }
      guard fstat(hashDescriptor, &hashDescriptorMetadata) == 0,
        hashDescriptorMetadata.st_dev == descriptorMetadata.st_dev,
        hashDescriptorMetadata.st_ino == descriptorMetadata.st_ino
      else {
        throw ProcessExecutionError.executableIdentityChanged
      }
      guard (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
        throw ProcessExecutionError.executableMustBeRegularFile
      }
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      guard descriptorMetadata.st_mode & executableBits != 0,
        path.path.withCString({ access($0, X_OK) }) == 0
      else {
        throw ProcessExecutionError.executableMustBeExecutable
      }
      guard pathMetadata.st_dev == descriptorMetadata.st_dev,
        pathMetadata.st_ino == descriptorMetadata.st_ino
      else {
        throw ProcessExecutionError.executableIdentityChanged
      }

      let sha256 = try hash(fileDescriptor: hashDescriptor)
      guard sha256 == expectedSHA256 else {
        throw ProcessExecutionError.executableHashMismatch(
          expected: expectedSHA256, actual: sha256)
      }
      let device = UInt64(UInt32(bitPattern: descriptorMetadata.st_dev))
      let inode = UInt64(descriptorMetadata.st_ino)
      let inodeLaunchPath = "/.vol/\(device)/\(inode)"
      var inodePathMetadata = stat()
      guard inodeLaunchPath.withCString({ lstat($0, &inodePathMetadata) }) == 0,
        inodePathMetadata.st_dev == descriptorMetadata.st_dev,
        inodePathMetadata.st_ino == descriptorMetadata.st_ino,
        (inodePathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      else {
        throw ProcessExecutionError.executableInodePathUnavailable
      }
      let receipt = ProcessExecutableIdentityReceipt(
        authorizedPath: path.path,
        inodeLaunchPath: inodeLaunchPath,
        device: device,
        inode: inode,
        fileSize: descriptorMetadata.st_size,
        mode: UInt32(descriptorMetadata.st_mode),
        sha256: sha256)
      return VerifiedExecutableDescriptor(
        fileDescriptor: descriptor,
        hashDescriptor: hashDescriptor,
        receipt: receipt,
        expectedSHA256: expectedSHA256,
        openedDevice: descriptorMetadata.st_dev,
        openedInode: descriptorMetadata.st_ino)
    } catch {
      Darwin.close(descriptor)
      Darwin.close(hashDescriptor)
      throw error
    }
  }

  func revalidate(path: URL) throws {
    guard fileDescriptor >= 0, hashDescriptor >= 0 else {
      throw ProcessExecutionError.executableDescriptorInvalid
    }
    var descriptorMetadata = stat()
    var hashDescriptorMetadata = stat()
    guard fstat(fileDescriptor, &descriptorMetadata) == 0,
      fstat(hashDescriptor, &hashDescriptorMetadata) == 0,
      descriptorMetadata.st_dev == openedDevice,
      descriptorMetadata.st_ino == openedInode,
      hashDescriptorMetadata.st_dev == openedDevice,
      hashDescriptorMetadata.st_ino == openedInode,
      (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    else {
      throw ProcessExecutionError.executableDescriptorInvalid
    }

    var pathMetadata = stat()
    guard path.path.withCString({ lstat($0, &pathMetadata) }) == 0,
      (pathMetadata.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK),
      pathMetadata.st_dev == openedDevice,
      pathMetadata.st_ino == openedInode
    else {
      throw ProcessExecutionError.executableIdentityChanged
    }
    var inodePathMetadata = stat()
    guard inodeLaunchPath.withCString({ lstat($0, &inodePathMetadata) }) == 0,
      inodePathMetadata.st_dev == openedDevice,
      inodePathMetadata.st_ino == openedInode,
      (inodePathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    else {
      throw ProcessExecutionError.executableInodePathUnavailable
    }
    let finalHash = try Self.hash(fileDescriptor: hashDescriptor)
    guard finalHash == expectedSHA256 else {
      throw ProcessExecutionError.executableHashMismatch(
        expected: expectedSHA256, actual: finalHash)
    }
  }

  func close() {
    if fileDescriptor >= 0 {
      Darwin.close(fileDescriptor)
      fileDescriptor = -1
    }
    if hashDescriptor >= 0 {
      Darwin.close(hashDescriptor)
      hashDescriptor = -1
    }
  }

  deinit { close() }

  private static func hash(fileDescriptor: Int32) throws -> String {
    var hasher = SHA256()
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(fileDescriptor, bytes.baseAddress, bytes.count, offset)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw ProcessExecutionError.executableDescriptorInvalid
      }
      hasher.update(data: Data(buffer.prefix(count)))
      offset += off_t(count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private struct SpawnedProcess {
  let processIdentifier: pid_t
  let stdout: Int32
  let stderr: Int32
}

private enum ProcessWaitResult: Sendable {
  case status(Int32)
  case failure(Int32)
}

extension ProcessExecutionResult {
  fileprivate static func empty(termination: ProcessTermination) -> ProcessExecutionResult {
    ProcessExecutionResult(
      termination: termination,
      processGroupTermination: .notRequested,
      stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
      stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false)
    )
  }
}

private final class SemanticEvaluationBox<Evaluator: ProcessSemanticEvaluating>: @unchecked Sendable
{
  private let lock = NSLock()
  private var evaluator: Evaluator

  init(_ evaluator: Evaluator) {
    self.evaluator = evaluator
  }

  func consume(_ chunk: ProcessOutputChunk) {
    lock.lock()
    evaluator.consume(chunk)
    lock.unlock()
  }

  func finish(execution: ProcessExecutionResult) -> Evaluator.SemanticResult {
    lock.lock()
    defer { lock.unlock() }
    return evaluator.finish(execution: execution)
  }
}

private final class ProcessControl: @unchecked Sendable {
  private let lock = NSLock()
  private let processGroupCleanup = DispatchGroup()
  private var processIdentifier: pid_t?
  private var drain: PipeDrain?
  private var stopped = false
  private var cleanupStarted = false
  private var storedTermination: ProcessTermination?
  private var groupTermination: ProcessGroupTerminationResult = .notRequested

  var hasStopRequest: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  var termination: ProcessTermination? {
    lock.lock()
    defer { lock.unlock() }
    return storedTermination
  }

  func attach(drain: PipeDrain) {
    lock.lock()
    self.drain = drain
    let shouldCancel = stopped
    lock.unlock()
    if shouldCancel {
      drain.cancel()
    }
  }

  func attach(processIdentifier: pid_t) {
    lock.lock()
    self.processIdentifier = processIdentifier
    let shouldStartCleanup = prepareCleanupIfNeeded()
    lock.unlock()
    if shouldStartCleanup {
      terminateProcessGroup(processIdentifier)
    }
  }

  func stop(reason: ProcessTermination) {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    storedTermination = reason
    let processIdentifier = processIdentifier
    let drain = drain
    let shouldStartCleanup = prepareCleanupIfNeeded()
    lock.unlock()
    drain?.cancel()
    if shouldStartCleanup, let processIdentifier {
      terminateProcessGroup(processIdentifier)
    }
  }

  func waitForProcessGroupTermination() async -> ProcessGroupTerminationResult {
    let wasStopped = lock.withLock { stopped }
    guard wasStopped else { return .notRequested }

    await withCheckedContinuation { continuation in
      processGroupCleanup.notify(queue: .global(qos: .utility)) {
        continuation.resume()
      }
    }
    return lock.withLock { groupTermination }
  }

  /// Called with `lock` held. Entering the DispatchGroup while still locked
  /// prevents a waiter from observing a stop request before cleanup exists.
  private func prepareCleanupIfNeeded() -> Bool {
    guard stopped, processIdentifier != nil, !cleanupStarted else { return false }
    cleanupStarted = true
    processGroupCleanup.enter()
    return true
  }

  private func terminateProcessGroup(_ processIdentifier: pid_t) {
    // POSIX_SPAWN_SETPGROUP uses the child PID as its new process-group ID.
    Darwin.kill(-processIdentifier, SIGTERM)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      if self.waitForGroupToDisappear(processIdentifier, timeout: 0.25) {
        self.completeGroupTermination(.noSurvivingMembers(forcedKill: false))
        return
      }

      let forcedKill = Darwin.kill(-processIdentifier, SIGKILL) == 0
      let disappeared = self.waitForGroupToDisappear(processIdentifier, timeout: 1.0)
      self.completeGroupTermination(
        disappeared
          ? .noSurvivingMembers(forcedKill: forcedKill)
          : .unconfirmed(forcedKill: forcedKill)
      )
    }
  }

  private func waitForGroupToDisappear(_ processIdentifier: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = DispatchTime.now() + timeout
    repeat {
      if !processGroupExists(processIdentifier) {
        return true
      }
      usleep(10_000)
    } while DispatchTime.now() < deadline
    return !processGroupExists(processIdentifier)
  }

  private func processGroupExists(_ processIdentifier: pid_t) -> Bool {
    if Darwin.kill(-processIdentifier, 0) == 0 {
      return true
    }
    return errno != ESRCH
  }

  private func completeGroupTermination(_ result: ProcessGroupTerminationResult) {
    lock.lock()
    groupTermination = result
    lock.unlock()
    processGroupCleanup.leave()
  }
}

private final class OutputCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private let onOutput: ProcessOutputHandler
  private var stdout = MutableStreamCapture()
  private var stderr = MutableStreamCapture()

  init(limit: Int, onOutput: @escaping ProcessOutputHandler) {
    self.limit = limit
    self.onOutput = onOutput
  }

  func accept(_ chunk: ProcessOutputChunk) {
    lock.lock()
    switch chunk.stream {
    case .stdout:
      stdout.append(chunk.bytes, limit: limit)
    case .stderr:
      stderr.append(chunk.bytes, limit: limit)
    }
    lock.unlock()
    onOutput(chunk)
  }

  func capture(for stream: ProcessStream) -> ProcessStreamCapture {
    lock.lock()
    defer { lock.unlock() }
    switch stream {
    case .stdout:
      return stdout.value
    case .stderr:
      return stderr.value
    }
  }
}

private struct MutableStreamCapture {
  private var data = Data()
  private var totalByteCount: Int64 = 0
  private var wasTruncated = false

  mutating func append(_ bytes: Data, limit: Int) {
    let (newTotal, overflowed) = totalByteCount.addingReportingOverflow(Int64(bytes.count))
    totalByteCount = overflowed ? .max : newTotal
    let remaining = max(0, limit - data.count)
    if remaining > 0 {
      data.append(bytes.prefix(remaining))
    }
    wasTruncated = wasTruncated || overflowed || bytes.count > remaining
  }

  var value: ProcessStreamCapture {
    ProcessStreamCapture(data: data, totalByteCount: totalByteCount, wasTruncated: wasTruncated)
  }
}

private final class PipeDrain: @unchecked Sendable {
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var unfinishedStreams = 0
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func enter() {
    lock.lock()
    unfinishedStreams += 1
    lock.unlock()
    group.enter()
  }

  func leave() {
    lock.lock()
    guard unfinishedStreams > 0 else {
      lock.unlock()
      return
    }
    unfinishedStreams -= 1
    lock.unlock()
    group.leave()
  }

  func waitUntilFinished() async {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global()) {
        continuation.resume()
      }
    }
  }
}

private func makeCStringVector(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
  var vector: [UnsafeMutablePointer<CChar>?] = []
  for string in strings {
    guard !string.contains("\0"), let pointer = strdup(string) else {
      freeCStringVector(vector)
      throw ProcessExecutionError.launchFailed("argument or environment contains a NUL byte")
    }
    vector.append(pointer)
  }
  vector.append(nil)
  return vector
}

private func freeCStringVector(_ vector: [UnsafeMutablePointer<CChar>?]) {
  for pointer in vector {
    free(pointer)
  }
}

private func closeAll(_ fileDescriptors: [Int32]) {
  for descriptor in fileDescriptors where descriptor >= 0 {
    Darwin.close(descriptor)
  }
}
