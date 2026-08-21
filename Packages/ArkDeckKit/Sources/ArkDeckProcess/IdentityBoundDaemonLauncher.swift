import Darwin
import Foundation

/// Starts a long-lived, descriptor-bound child and hands it one secret on
/// stdin.
///
/// This exists because a pairing secret must not travel any other way. Put it
/// in `argv` and every process that can read `/proc`-equivalent state sees it;
/// put it in the environment and the child cannot erase it after reading. Both
/// outlive the moment they are needed. A pipe whose write end is retained only
/// by the parent gives the child both the one-shot secret and a process-lifetime
/// authority signal: EOF proves the owning parent generation is gone.
///
/// It is a sibling of `IdentityBoundPTYExecutor`, not a replacement: that one
/// answers a prompt from a short-lived tool and waits for it to exit. This one
/// launches a service that stays up, writes once, and returns a handle.
///
/// The identity discipline is the same and is the reason this lives here rather
/// than beside its caller. The executable is opened, hashed, and launched
/// through the path bound to *that* opened inode, and it is revalidated twice —
/// once while the spawn is being configured and again immediately before
/// `posix_spawn`. A binary swapped between the check and the launch is the
/// failure this shape removes, and it matters more here than anywhere: the
/// child this starts is the process that will write partitions.
package struct IdentityBoundDaemonLauncher: Sendable {

  package init() {}

  /// A running child, and what was proved about it at launch.
  package struct Handle: Sendable {
    package let processIdentifier: pid_t
    package let executableIdentity: ProcessExecutableIdentityReceipt
    private let authorityLiveness: AuthorityLiveness

    fileprivate init(
      processIdentifier: pid_t,
      executableIdentity: ProcessExecutableIdentityReceipt,
      authorityLivenessDescriptor: Int32
    ) {
      self.processIdentifier = processIdentifier
      self.executableIdentity = executableIdentity
      authorityLiveness = AuthorityLiveness(descriptor: authorityLivenessDescriptor)
    }

    /// Ends the child and its process group.
    ///
    /// The group, not just the process: this launcher puts the child in its own
    /// group precisely so a service that spawned helpers cannot leave them
    /// behind when it goes.
    package func terminate() {
      // EOF is the child's fail-closed signal that the exact parent authority
      // generation is gone. Close first so a child handling SIGTERM cannot
      // briefly keep serving against an authority that no longer exists.
      authorityLiveness.close()
      kill(-processIdentifier, SIGTERM)
    }

    /// Reaps the child, returning its exit status if it has ended.
    @discardableResult
    package func reap() -> Int32? {
      var status: Int32 = 0
      let result = waitpid(processIdentifier, &status, WNOHANG)
      guard result == processIdentifier else { return nil }
      return status
    }
  }

  package enum LaunchError: Error, Equatable, CustomStringConvertible {
    case pipeUnavailable(Int32)
    case configurationFailed(String)
    case spawnFailed(Int32)
    case secretNotDelivered(String)

    package var description: String {
      switch self {
      case .pipeUnavailable(let code): return "could not create the stdin pipe: errno \(code)"
      case .configurationFailed(let detail): return "could not configure the spawn: \(detail)"
      case .spawnFailed(let code): return "posix_spawn failed: errno \(code)"
      case .secretNotDelivered(let detail):
        return
          "the child started but the secret did not reach it: \(detail). It is left "
          + "unpaired rather than started with a partial handshake"
      }
    }
  }

  /// Launches the child, writes `secret` to stdin and retains the pipe in the
  /// returned handle as the child's parent-authority liveness capability.
  ///
  /// `secret` is taken by value and never stored, logged, or returned. The
  /// caller is responsible for clearing its own copy; nothing here keeps one.
  ///
  /// The child reads the protocol-defined secret length, not until EOF. The
  /// write end must stay open after delivery: EOF means the owning parent died,
  /// at which point a destructive service must stop rather than become an
  /// orphan that can continue accepting work.
  package func launch(
    _ request: ProcessIdentityBoundRequest,
    secret: Data,
    executor: FoundationProcessExecutor = FoundationProcessExecutor()
  ) async throws -> Handle {
    let prepared = try await executor.prepareIdentityBoundLaunch(request)
    try prepared.consume()
    defer { prepared.close() }
    let process = prepared.request.process
    try prepared.executable.revalidate(path: process.executable)

    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else { throw LaunchError.pipeUnavailable(errno) }
    let readEnd = pipeFDs[0]
    let writeEnd = pipeFDs[1]
    var writeEndOpen = true
    defer {
      Darwin.close(readEnd)
      if writeEndOpen { Darwin.close(writeEnd) }
    }

    var arguments = try Self.cStrings(
      [process.argumentZero ?? process.executable.path] + process.arguments)
    defer { Self.freeCStrings(&arguments) }
    var environment = try Self.cStrings(
      ProcessInfo.processInfo.environment
        .filter { FoundationProcessExecutor.baseChildEnvironmentKeys.contains($0.key) }
        .merging(process.environment) { _, requested in requested }
        .sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" })
    defer { Self.freeCStrings(&environment) }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw LaunchError.configurationFailed("file actions")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let directory = process.workingDirectory {
      let result = directory.path.withCString {
        posix_spawn_file_actions_addchdir(&fileActions, $0)
      }
      guard result == 0 else {
        throw LaunchError.configurationFailed("working directory")
      }
    }
    // The child reads the pipe; the write end is the parent's alone. Closing it
    // in the child is what makes the parent's later close a real EOF.
    guard posix_spawn_file_actions_adddup2(&fileActions, readEnd, STDIN_FILENO) == 0,
      posix_spawn_file_actions_addclose(&fileActions, writeEnd) == 0,
      posix_spawn_file_actions_addclose(&fileActions, readEnd) == 0,
      posix_spawnattr_init(&attributes) == 0
    else {
      throw LaunchError.configurationFailed("stdin pipe")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw LaunchError.configurationFailed("child process group")
    }

    // The second revalidation, immediately before the spawn. Everything above
    // took time; this is the check that the bytes have not moved since.
    try prepared.executable.revalidate(path: process.executable)
    var pid: pid_t = 0
    let spawnResult = arguments.withUnsafeMutableBufferPointer { argv in
      environment.withUnsafeMutableBufferPointer { envp in
        prepared.executable.inodeLaunchPath.withCString { executable in
          posix_spawn(
            &pid, executable, &fileActions, &attributes, argv.baseAddress, envp.baseAddress)
        }
      }
    }
    guard spawnResult == 0 else { throw LaunchError.spawnFailed(spawnResult) }

    var written = 0
    let delivered: Bool = secret.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return secret.isEmpty }
      while written < secret.count {
        let count = write(writeEnd, base + written, secret.count - written)
        if count <= 0 {
          if errno == EINTR { continue }
          return false
        }
        written += count
      }
      return true
    }
    guard delivered else {
      // A partial secret can never pair. Close the liveness capability and
      // terminate the dedicated group so no unpaired child survives failure.
      Darwin.close(writeEnd)
      writeEndOpen = false
      kill(-pid, SIGTERM)
      throw LaunchError.secretNotDelivered("wrote \(written) of \(secret.count) bytes")
    }

    // Ownership transfers to the handle. It closes on explicit termination or
    // when the last handle copy is released; the surrounding defer must no
    // longer touch this descriptor.
    writeEndOpen = false
    return Handle(
      processIdentifier: pid,
      executableIdentity: prepared.executable.receipt,
      authorityLivenessDescriptor: writeEnd)
  }

  // MARK: - argv/envp marshalling

  private static func cStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
    var out: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    guard !out.contains(where: { $0 == nil }) else {
      freeCStrings(&out)
      throw LaunchError.configurationFailed("argument marshalling")
    }
    out.append(nil)
    return out
  }

  private static func freeCStrings(_ values: inout [UnsafeMutablePointer<CChar>?]) {
    for value in values where value != nil { free(value) }
    values = []
  }

  /// Reference ownership makes copies of `Handle` share one idempotent close.
  /// A raw descriptor stored directly in the value would either double-close
  /// after a copy or leak to avoid doing so; either outcome breaks the
  /// authority-lifetime guarantee.
  private final class AuthorityLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
      self.descriptor = descriptor
    }

    func close() {
      lock.lock()
      let owned = descriptor
      descriptor = nil
      lock.unlock()
      if let owned { Darwin.close(owned) }
    }

    deinit { close() }
  }
}
