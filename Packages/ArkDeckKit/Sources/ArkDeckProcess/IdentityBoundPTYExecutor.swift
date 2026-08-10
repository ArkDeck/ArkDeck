import Darwin
import Foundation

/// One exact prompt/secret exchange for a descriptor-bound child process.
/// The secret is never included in a process request, argv, environment or
/// returned receipt. Callers must clear their copy after execution.
public struct IdentityBoundPTYInteraction: Sendable, Equatable {
  public let expectedPrompt: Data
  public let secret: Data

  public init(expectedPrompt: Data, secret: Data) {
    self.expectedPrompt = expectedPrompt
    self.secret = secret
  }
}

public struct IdentityBoundPTYExecutionResult: Sendable, Equatable {
  public let termination: ProcessTermination
  public let executableIdentity: ProcessExecutableIdentityReceipt
  public let completedInteractions: Int
  public let observedOutputByteCount: Int

  public init(
    termination: ProcessTermination,
    executableIdentity: ProcessExecutableIdentityReceipt,
    completedInteractions: Int,
    observedOutputByteCount: Int
  ) {
    self.termination = termination
    self.executableIdentity = executableIdentity
    self.completedInteractions = completedInteractions
    self.observedOutputByteCount = observedOutputByteCount
  }
}

public enum IdentityBoundPTYError: Error, Equatable, Sendable {
  case invalidInteraction
  case ptyAllocationFailed(Int32)
  case launchFailed(String)
  case promptProtocolViolation
  case secretEchoDetected
  case outputBudgetExceeded
  case timedOut
  case cancelled
  case waitFailed(Int32)
}

private final class PTYCancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Descriptor-bound PTY execution used by the OpenHarmony signer. It exposes
/// no transcript: a password can therefore never reach a generic process
/// receipt even if an upstream terminal implementation starts echoing input.
public final class IdentityBoundPTYExecutor: @unchecked Sendable {
  public init() {}

  public func execute(
    _ request: ProcessIdentityBoundRequest,
    interactions: [IdentityBoundPTYInteraction],
    outputByteBudget: Int = 1_048_576
  ) async throws -> IdentityBoundPTYExecutionResult {
    try await execute(
      request, interactions: interactions, outputByteBudget: outputByteBudget,
      verifiedResources: [])
  }

  package func execute(
    _ request: ProcessIdentityBoundRequest,
    interactions: [IdentityBoundPTYInteraction],
    outputByteBudget: Int = 1_048_576,
    verifiedResources: [VerifiedRegularFileDescriptor]
  ) async throws -> IdentityBoundPTYExecutionResult {
    guard !interactions.isEmpty,
      interactions.count <= 4,
      outputByteBudget >= 1_024,
      interactions.allSatisfy({
        !$0.expectedPrompt.isEmpty && $0.expectedPrompt.count <= 512
          && !$0.secret.isEmpty && $0.secret.count <= 4_096
          && !$0.secret.contains(0) && !$0.secret.contains(10) && !$0.secret.contains(13)
      })
    else { throw IdentityBoundPTYError.invalidInteraction }

    let prepared = try FoundationProcessExecutor().prepareIdentityBoundLaunch(request)
    let cancellation = PTYCancellationBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            continuation.resume(
              returning: try Self.run(
                prepared: prepared, interactions: interactions,
                outputByteBudget: outputByteBudget, cancellation: cancellation,
                verifiedResources: verifiedResources))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func run(
    prepared: ProcessPreparedIdentityBoundLaunch,
    interactions: [IdentityBoundPTYInteraction],
    outputByteBudget: Int,
    cancellation: PTYCancellationBox,
    verifiedResources: [VerifiedRegularFileDescriptor]
  ) throws -> IdentityBoundPTYExecutionResult {
    try prepared.consume()
    defer { prepared.close() }
    let request = prepared.request.process
    try prepared.executable.revalidate(path: request.executable)

    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw IdentityBoundPTYError.ptyAllocationFailed(errno)
    }
    defer {
      if master >= 0 { Darwin.close(master) }
      if slave >= 0 { Darwin.close(slave) }
    }
    // The parent owns the privacy boundary. Do not rely on the signer to win
    // a race between printing its prompt and disabling terminal echo.
    var terminal = termios()
    guard tcgetattr(slave, &terminal) == 0 else {
      throw IdentityBoundPTYError.launchFailed("could not read PTY attributes")
    }
    terminal.c_lflag &= ~tcflag_t(ECHO | ECHONL)
    guard tcsetattr(slave, TCSANOW, &terminal) == 0 else {
      throw IdentityBoundPTYError.launchFailed("could not disable PTY echo")
    }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

    var arguments = try cStrings(
      [request.argumentZero ?? request.executable.path] + request.arguments)
    defer { freeCStrings(&arguments) }
    var environment = try cStrings(
      ProcessInfo.processInfo.environment
        .filter { FoundationProcessExecutor.baseChildEnvironmentKeys.contains($0.key) }
        .merging(request.environment) { _, requested in requested }
        .sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" })
    defer { freeCStrings(&environment) }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw IdentityBoundPTYError.launchFailed("could not initialize file actions")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let directory = request.workingDirectory {
      let result = directory.path.withCString {
        posix_spawn_file_actions_addchdir_np(&fileActions, $0)
      }
      guard result == 0 else {
        throw IdentityBoundPTYError.launchFailed("could not bind working directory")
      }
    }
    guard posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addclose(&fileActions, master) == 0,
      posix_spawn_file_actions_addclose(&fileActions, slave) == 0,
      posix_spawnattr_init(&attributes) == 0
    else {
      throw IdentityBoundPTYError.launchFailed("could not configure PTY spawn")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw IdentityBoundPTYError.launchFailed("could not configure child process group")
    }

    try prepared.executable.revalidate(path: request.executable)
    for resource in verifiedResources { try resource.revalidate() }
    var pid: pid_t = 0
    let spawnResult = arguments.withUnsafeMutableBufferPointer { argv in
      environment.withUnsafeMutableBufferPointer { envp in
        prepared.executable.inodeLaunchPath.withCString { executable in
          posix_spawn(&pid, executable, &fileActions, &attributes, argv.baseAddress, envp.baseAddress)
        }
      }
    }
    guard spawnResult == 0 else {
      throw IdentityBoundPTYError.launchFailed(String(cString: strerror(spawnResult)))
    }
    Darwin.close(slave)
    slave = -1

    let timeout = request.timeout ?? 60
    let deadline = Date().addingTimeInterval(timeout)
    var output = Data()
    defer { output.resetBytes(in: 0..<output.count) }
    var completed = 0
    var status: Int32 = 0
    var childExited = false
    let promptMarker = Data("please input ".utf8)

    defer {
      if !childExited {
        terminateProcessGroup(pid)
        _ = waitpid(pid, &status, 0)
      }
    }

    while !childExited {
      if cancellation.isCancelled {
        terminateProcessGroup(pid)
        throw IdentityBoundPTYError.cancelled
      }
      if Date() >= deadline {
        terminateProcessGroup(pid)
        throw IdentityBoundPTYError.timedOut
      }

      var descriptor = pollfd(fd: master, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      let polled = Darwin.poll(&descriptor, 1, 25)
      if polled < 0, errno != EINTR {
        throw IdentityBoundPTYError.waitFailed(errno)
      }
      if polled > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = buffer.withUnsafeMutableBytes {
          Darwin.read(master, $0.baseAddress, $0.count)
        }
        if count > 0 {
          output.append(contentsOf: buffer.prefix(count))
          guard output.count <= outputByteBudget else {
            terminateProcessGroup(pid)
            throw IdentityBoundPTYError.outputBudgetExceeded
          }
          for interaction in interactions where contains(output, interaction.secret) {
            terminateProcessGroup(pid)
            throw IdentityBoundPTYError.secretEchoDetected
          }
          let promptCount = occurrences(of: promptMarker, in: output)
          guard promptCount <= interactions.count else {
            terminateProcessGroup(pid)
            throw IdentityBoundPTYError.promptProtocolViolation
          }
          while completed < interactions.count,
            contains(output, interactions[completed].expectedPrompt)
          {
            try write(interactions[completed].secret, to: master)
            try write(Data([10]), to: master)
            completed += 1
          }
          if promptCount > completed {
            terminateProcessGroup(pid)
            throw IdentityBoundPTYError.promptProtocolViolation
          }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EIO {
          throw IdentityBoundPTYError.waitFailed(errno)
        }
      }

      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid {
        childExited = true
      } else if waited < 0, errno != EINTR {
        throw IdentityBoundPTYError.waitFailed(errno)
      }
    }
    guard completed == interactions.count else {
      throw IdentityBoundPTYError.promptProtocolViolation
    }
    let termination: ProcessTermination
    // Darwin's wait macros are function-like and therefore unavailable to
    // Swift. Decode the same wait status bits directly.
    let terminationSignal = status & 0x7f
    if terminationSignal == 0 {
      termination = .exited((status >> 8) & 0xff)
    } else if terminationSignal != 0x7f {
      termination = .signalled(terminationSignal)
    } else {
      termination = .unrecognizedWaitStatus(status)
    }
    return IdentityBoundPTYExecutionResult(
      termination: termination,
      executableIdentity: prepared.executableIdentity,
      completedInteractions: completed,
      observedOutputByteCount: output.count)
  }

  private static func terminateProcessGroup(_ pid: pid_t) {
    _ = Darwin.kill(-pid, SIGTERM)
    usleep(100_000)
    _ = Darwin.kill(-pid, SIGKILL)
  }

  private static func contains(_ haystack: Data, _ needle: Data) -> Bool {
    !needle.isEmpty && haystack.range(of: needle) != nil
  }

  private static func occurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = haystack.startIndex
    while cursor < haystack.endIndex,
      let range = haystack.range(of: needle, in: cursor..<haystack.endIndex)
    {
      count += 1
      cursor = range.upperBound
    }
    return count
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        throw IdentityBoundPTYError.waitFailed(errno)
      }
    }
  }

  private static func cStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
    guard values.allSatisfy({ !$0.contains("\0") }) else {
      throw ProcessExecutionError.invalidArgumentContainsNUL
    }
    return values.map { strdup($0) } + [nil]
  }

  private static func freeCStrings(_ values: inout [UnsafeMutablePointer<CChar>?]) {
    for value in values { free(value) }
    values.removeAll(keepingCapacity: false)
  }
}
