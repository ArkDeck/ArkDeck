import ArkDeckCore
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
  case indeterminate
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

public enum ProcessExecutionError: Error, Equatable, LocalizedError {
  case executableMustBeAbsolute(String)
  case invalidExecutableContainsNUL
  case invalidArgumentContainsNUL
  case invalidEnvironmentKey(String)
  case invalidEnvironmentValue(String)
  case invalidTimeout(TimeInterval)
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
  public init() {}

  public func execute(
    _ request: ProcessRequest,
    captureLimit: Int = 64 * 1024,
    onOutput: @escaping ProcessOutputHandler = { _ in }
  ) async throws -> ProcessExecutionResult {
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

  private func spawn(_ request: ProcessRequest) throws -> SpawnedProcess {
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
        request.executable.path.withCString { executablePath in
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
