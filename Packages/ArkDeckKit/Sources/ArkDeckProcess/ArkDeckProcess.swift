import ArkDeckCore
import Darwin
import Foundation

/// `PORT-PROCESS-001` macOS prototype.
///
/// The request intentionally has an executable URL and an argument array rather
/// than a command string. This module never invokes a host shell.
public enum ArkDeckProcessModule {
    public static let identifier = "ArkDeckProcess"
}

public enum ProcessStream: String, Sendable, Equatable {
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
    case timedOut
    case cancelled
}

public struct ProcessExecutionResult: Sendable, Equatable {
    public let termination: ProcessTermination
    public let stdout: ProcessStreamCapture
    public let stderr: ProcessStreamCapture

    public init(
        termination: ProcessTermination,
        stdout: ProcessStreamCapture,
        stderr: ProcessStreamCapture
    ) {
        self.termination = termination
        self.stdout = stdout
        self.stderr = stderr
    }
}

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
    case invalidArgumentContainsNUL
    case invalidEnvironmentKey(String)
    case invalidEnvironmentValue(String)
    case invalidTimeout(TimeInterval)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .executableMustBeAbsolute(path):
            "Process executable must be an absolute file URL: \(path)"
        case .invalidArgumentContainsNUL:
            "Process arguments must not contain NUL bytes"
        case let .invalidEnvironmentKey(key):
            "Process environment key is invalid: \(key)"
        case let .invalidEnvironmentValue(key):
            "Process environment value contains a NUL byte for key: \(key)"
        case let .invalidTimeout(timeout):
            "Process timeout must be positive: \(timeout)"
        case let .launchFailed(message):
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
        guard request.timeout.map({ $0 > 0 }) ?? true else {
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
        return try await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return .empty(termination: .cancelled) }
            return try await start(
                request,
                captureLimit: max(0, captureLimit),
                control: control,
                onOutput: onOutput
            )
        }, onCancel: {
            control.stop(reason: .cancelled)
        })
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
        installReader(for: spawned.stdout, stream: .stdout, capture: capture, drain: drain)
        installReader(for: spawned.stderr, stream: .stderr, capture: capture, drain: drain)
        control.attach(processIdentifier: spawned.processIdentifier)
        let timeoutTask = makeTimeoutTask(for: request.timeout, control: control)
        defer { timeoutTask?.cancel() }

        let status = await waitForExit(of: spawned.processIdentifier)
        control.markFinished(processIdentifier: spawned.processIdentifier)
        await drain.waitUntilFinished()
        return ProcessExecutionResult(
            termination: control.termination ?? .exited(exitCode(from: status)),
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
            throw ProcessExecutionError.launchFailed("could not allocate output pipes: \(String(cString: strerror(errno)))")
        }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            throw ProcessExecutionError.launchFailed("could not allocate output pipes: \(String(cString: strerror(errno)))")
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
        let stdout = FileHandle(fileDescriptor: stdoutDescriptors[0], closeOnDealloc: true)
        stdoutDescriptors[0] = -1
        let stderr = FileHandle(fileDescriptor: stderrDescriptors[0], closeOnDealloc: true)
        stderrDescriptors[0] = -1
        return SpawnedProcess(
            processIdentifier: processIdentifier,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func installReader(
        for handle: FileHandle,
        stream: ProcessStream,
        capture: OutputCapture,
        drain: PipeDrain
    ) {
        drain.enter()
        handle.readabilityHandler = { readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else {
                readableHandle.readabilityHandler = nil
                drain.leave()
                return
            }
            capture.accept(ProcessOutputChunk(stream: stream, bytes: data))
        }
    }

    private func waitForExit(of processIdentifier: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while Darwin.waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private func exitCode(from status: Int32) -> Int32 {
        // Equivalent to the Darwin WIFEXITED/WEXITSTATUS and WTERMSIG macros,
        // which Swift cannot import because they are function-like macros.
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        if terminationSignal != 0x7f {
            return 128 + terminationSignal
        }
        return -1
    }

    private func makeTimeoutTask(for timeout: TimeInterval?, control: ProcessControl) -> Task<Void, Never>? {
        guard let timeout else { return nil }
        let nanoseconds = UInt64((timeout * 1_000_000_000).rounded(.up))
        return Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            control.stop(reason: .timedOut)
        }
    }
}

private struct SpawnedProcess {
    let processIdentifier: pid_t
    let stdout: FileHandle
    let stderr: FileHandle
}

private extension ProcessExecutionResult {
    static func empty(termination: ProcessTermination) -> ProcessExecutionResult {
        ProcessExecutionResult(
            termination: termination,
            stdout: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false),
            stderr: ProcessStreamCapture(data: Data(), totalByteCount: 0, wasTruncated: false)
        )
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var stopped = false
    private var finished = false
    private var storedTermination: ProcessTermination?

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

    func attach(processIdentifier: pid_t) {
        lock.lock()
        self.processIdentifier = processIdentifier
        let shouldStop = stopped
        lock.unlock()
        if shouldStop {
            signalProcessGroup(processIdentifier)
        }
    }

    func stop(reason: ProcessTermination) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if !stopped {
            stopped = true
            storedTermination = reason
        }
        let processIdentifier = processIdentifier
        lock.unlock()
        if let processIdentifier {
            signalProcessGroup(processIdentifier)
        }
    }

    func markFinished(processIdentifier: pid_t) {
        lock.lock()
        if self.processIdentifier == processIdentifier {
            self.processIdentifier = nil
            finished = true
        }
        lock.unlock()
    }

    private func signalProcessGroup(_ processIdentifier: pid_t) {
        // POSIX_SPAWN_SETPGROUP uses the child PID as its new process-group ID.
        Darwin.kill(-processIdentifier, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.forceKillProcessGroup(processIdentifier)
        }
    }

    private func forceKillProcessGroup(_ processIdentifier: pid_t) {
        lock.lock()
        let isStillRunning = self.processIdentifier == processIdentifier
        lock.unlock()
        if isStillRunning {
            Darwin.kill(-processIdentifier, SIGKILL)
        }
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
        totalByteCount += Int64(bytes.count)
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(bytes.prefix(remaining))
        }
        wasTruncated = wasTruncated || bytes.count > remaining
    }

    var value: ProcessStreamCapture {
        ProcessStreamCapture(data: data, totalByteCount: totalByteCount, wasTruncated: wasTruncated)
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var unfinishedStreams = 0

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
