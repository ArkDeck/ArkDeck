import Darwin
import Foundation

/// What one command over a persistent device shell answered.
///
/// `deviceExitStatus` is the status of the command *on the device*. A spawned
/// `hdc shell` cannot report that at all — it exits 0 whether the device
/// command succeeded, failed or was never found — so verdicts on that path
/// have to be inferred from output text. Framing the command lets the device
/// shell report its own status, which is a stronger fact than the text.
package struct DeviceShellAnswer: Sendable, Equatable {
  package let stdout: Data
  package let deviceExitStatus: Int32
  package let truncated: Bool

  package init(stdout: Data, deviceExitStatus: Int32, truncated: Bool) {
    self.stdout = stdout
    self.deviceExitStatus = deviceExitStatus
    self.truncated = truncated
  }
}

package enum DeviceShellChannelError: Error, Equatable, Sendable {
  /// The channel could not be established, or is no longer usable. Nothing
  /// was written to the device, so the caller may fall back to spawning.
  case unavailable(String)
  /// The command was written but its answer never arrived. Whether the device
  /// carried it out is not known and must not be guessed: the caller owns an
  /// unknown outcome from here.
  case outcomeUnknown(String)
}

/// A long-lived `hdc shell` bound to one device.
///
/// Spawning a client for every command costs a process launch on top of the
/// device round trip. Measured against DAYU200, the same `uinput` invocation
/// takes p50 242 ms spawned and p50 177 ms over a channel that is already
/// open — and an interactive gesture has to fit inside 400 ms end to end.
///
/// The channel is deliberately narrow. Each command is framed by a fresh
/// nonce, so an answer that arrives late can never be read as the next
/// command's answer; anything unexpected closes the channel rather than
/// resynchronising a stream whose position is no longer trustworthy; and a
/// command whose frame never completes is reported as an unknown outcome,
/// never as a failure, because the device may well have carried it out.
package final class PersistentDeviceShellChannel: @unchecked Sendable {
  /// Bytes read past the budget before the channel is abandoned. A command
  /// that floods cannot be allowed to hold the channel until timeout, but
  /// nor should a slightly-over-budget answer cost the channel.
  private static let overflowToleranceBytes = 4 * 1_024 * 1_024

  private let lock = NSLock()
  private var master: Int32 = -1
  private var childPID: pid_t = -1
  private var isClosed = false
  private var pending = Data()

  private init(master: Int32, childPID: pid_t) {
    self.master = master
    self.childPID = childPID
  }

  deinit { closeLocked() }

  /// Opens a shell on the device the request's arguments name.
  ///
  /// The executable's identity is verified here exactly as a spawned dispatch
  /// verifies it, and the channel then rides that one verified process: every
  /// later command reaches the device through the binary this check passed.
  package static func open(
    _ request: ProcessIdentityBoundRequest,
    settleSeconds: TimeInterval = 10
  ) throws -> PersistentDeviceShellChannel {
    let prepared: ProcessPreparedIdentityBoundLaunch
    do {
      prepared = try FoundationProcessExecutor().prepareIdentityBoundLaunch(request)
    } catch {
      throw DeviceShellChannelError.unavailable("channel executable identity refused: \(error)")
    }
    do {
      try prepared.consume()
    } catch {
      throw DeviceShellChannelError.unavailable("channel launch already consumed: \(error)")
    }
    defer { prepared.close() }

    var master: Int32 = -1
    var slave: Int32 = -1
    guard unsafe openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw DeviceShellChannelError.unavailable("cannot allocate a terminal for the channel")
    }
    var releaseDescriptors = true
    defer {
      if releaseDescriptors, master >= 0 { Darwin.close(master) }
      if slave >= 0 { Darwin.close(slave) }
    }
    // `hdc shell` refuses to run over a plain pipe — it reports "Not support
    // stdio TTY mode" and then discards everything written to it — so the
    // channel has to be a terminal. Echo and newline translation are turned
    // off so what comes back is the device's output and nothing else: with
    // echo on, every command is reflected into its own answer.
    var terminal = termios()
    guard unsafe tcgetattr(slave, &terminal) == 0 else {
      throw DeviceShellChannelError.unavailable("cannot read channel terminal attributes")
    }
    terminal.c_lflag &= ~tcflag_t(ECHO | ECHONL)
    terminal.c_oflag &= ~tcflag_t(ONLCR)
    guard unsafe tcsetattr(slave, TCSANOW, &terminal) == 0 else {
      throw DeviceShellChannelError.unavailable("cannot configure the channel terminal")
    }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

    let process = prepared.request.process
    var arguments = try unsafe cStrings(
      [process.argumentZero ?? process.executable.path] + process.arguments)
    defer { unsafe freeCStrings(&arguments) }
    var environment = try unsafe cStrings(
      ProcessInfo.processInfo.environment
        .filter { FoundationProcessExecutor.baseChildEnvironmentKeys.contains($0.key) }
        .merging(process.environment) { _, requested in requested }
        .sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" })
    defer { unsafe freeCStrings(&environment) }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard unsafe posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw DeviceShellChannelError.unavailable("cannot configure the channel spawn")
    }
    defer { unsafe posix_spawn_file_actions_destroy(&fileActions) }
    guard unsafe posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO) == 0,
      unsafe posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO) == 0,
      unsafe posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO) == 0,
      unsafe posix_spawn_file_actions_addclose(&fileActions, master) == 0,
      unsafe posix_spawn_file_actions_addclose(&fileActions, slave) == 0,
      unsafe posix_spawnattr_init(&attributes) == 0
    else {
      throw DeviceShellChannelError.unavailable("cannot configure the channel spawn")
    }
    defer { unsafe posix_spawnattr_destroy(&attributes) }
    // Its own process group, so closing the channel takes the client with it
    // and never reaches anything else.
    guard unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      unsafe posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw DeviceShellChannelError.unavailable("cannot isolate the channel process group")
    }

    do {
      try prepared.executable.revalidate(path: process.executable)
    } catch {
      throw DeviceShellChannelError.unavailable("channel executable identity changed: \(error)")
    }
    var pid: pid_t = 0
    let spawned = unsafe arguments.withUnsafeMutableBufferPointer { argv in
      unsafe environment.withUnsafeMutableBufferPointer { envp in
        unsafe prepared.executable.inodeLaunchPath.withCString { executable in
          unsafe posix_spawn(
            &pid, executable, &fileActions, &attributes, argv.baseAddress, envp.baseAddress)
        }
      }
    }
    guard spawned == 0 else {
      throw DeviceShellChannelError.unavailable("cannot start the channel client")
    }
    Darwin.close(slave)
    slave = -1
    releaseDescriptors = false

    let channel = PersistentDeviceShellChannel(master: master, childPID: pid)
    // The client discards anything written before it has the device shell up,
    // exactly as it discards everything written to it over a plain pipe. So
    // the first write waits for the shell to say something, rather than being
    // sent into a client that is not listening yet and then blamed on the
    // device for not answering.
    let ready = Date().addingTimeInterval(settleSeconds)
    while channel.hasReadNothing, Date() < ready, channel.isAlive {
      channel.drainForOpening(until: min(ready, Date().addingTimeInterval(0.1)))
    }
    guard !channel.hasReadNothing else {
      channel.close()
      throw DeviceShellChannelError.unavailable("the channel shell never came up")
    }
    // Opening is then proved rather than assumed: one framed no-op has to come
    // back. That both consumes the banner and prompt - which would otherwise
    // land in the first real answer - and establishes that this channel can
    // carry a command at all, before anything depends on it.
    do {
      let ready = try channel.run(
        ["true"], timeout: settleSeconds, outputByteBudget: 4_096)
      guard ready.deviceExitStatus == 0 else {
        channel.close()
        throw DeviceShellChannelError.unavailable("the channel shell refused a no-op")
      }
    } catch {
      channel.close()
      throw DeviceShellChannelError.unavailable("the channel never became ready: \(error)")
    }
    return channel
  }

  /// Whether anything at all has come back yet. Used only while opening.
  var hasReadNothing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending.isEmpty
  }

  func drainForOpening(until deadline: Date) {
    lock.lock()
    defer { lock.unlock() }
    drain(until: deadline)
  }

  package var isAlive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isAliveLocked()
  }

  /// Runs one command and returns what the device answered.
  ///
  /// `arguments` are joined into a single shell line, so every element must be
  /// a bare token. A caller that cannot promise that must spawn instead: this
  /// refuses rather than quoting, because a quoting rule that differs from the
  /// spawned path by one character would make the two dispatch shapes run
  /// different commands.
  package func run(
    _ arguments: [String],
    timeout: TimeInterval,
    outputByteBudget: Int
  ) throws -> DeviceShellAnswer {
    guard !arguments.isEmpty, arguments.allSatisfy(Self.isBareToken) else {
      throw DeviceShellChannelError.unavailable(
        "the channel carries bare tokens only; this command needs a spawn")
    }
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, isAliveLocked() else {
      throw DeviceShellChannelError.unavailable("the channel is not open")
    }

    let nonce = "ARKDECK" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    // The opening marker separates the command's output from the prompt and
    // echo that precede it; the closing one is written by the shell only once
    // the command has returned, and carries that command's own status.
    let line = Data(
      "echo \(nonce)B; \(arguments.joined(separator: " ")); echo \(nonce):$?\n".utf8)

    // Anything still buffered belongs to the previous command's trailing
    // prompt. It is dropped before writing so it cannot be read as output.
    pending.removeAll(keepingCapacity: true)
    do {
      try writeAll(line)
    } catch {
      closeLocked()
      throw DeviceShellChannelError.unavailable("cannot write to the channel: \(error)")
    }

    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if case .complete(let body, let status) = Self.frame(in: pending, nonce: nonce) {
        pending.removeAll(keepingCapacity: true)
        // The budget bounds what comes back, not what has to be read to find
        // the frame: the command still has to be accounted for, so the answer
        // is trimmed here rather than by dropping bytes the frame lives in.
        var bounded = body
        var truncated = false
        if bounded.count > outputByteBudget {
          bounded = Data(bounded.prefix(outputByteBudget))
          truncated = true
        }
        return DeviceShellAnswer(
          stdout: bounded, deviceExitStatus: status, truncated: truncated)
      }
      // A command that answers without ever framing it cannot be allowed to
      // hold the channel, or the memory, until its timeout.
      if pending.count > outputByteBudget + Self.overflowToleranceBytes {
        closeLocked()
        throw DeviceShellChannelError.outcomeUnknown(
          "the channel answered past every bound before framing its answer")
      }
      guard Date() < deadline else {
        closeLocked()
        throw DeviceShellChannelError.outcomeUnknown(
          "the channel did not answer within its timeout")
      }
      guard isAliveLocked() else {
        closeLocked()
        throw DeviceShellChannelError.outcomeUnknown(
          "the channel client exited before answering")
      }
      drain(until: min(deadline, Date().addingTimeInterval(0.05)))
    }
  }

  package func close() {
    lock.lock()
    defer { lock.unlock() }
    closeLocked()
  }

  // MARK: - Internals

  /// A token that a shell would read back exactly as written. Digits, letters
  /// and a short set of punctuation that carries no meaning to the shell.
  package static func isBareToken(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 256 else { return false }
    return value.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || "-_./:=+,@".contains($0))
    }
  }

  enum FrameReading: Equatable {
    /// The frame is closed and carries the command's own status.
    case complete(body: Data, status: Int32)
    /// Part of the frame is there but not all of it. Reading on is correct;
    /// treating this as malformed would abandon a live channel over nothing
    /// more than where a read boundary happened to fall.
    case incomplete
    /// The frame has not started arriving yet.
    case absent
  }

  /// Finds the command's own frame in what has been read so far.
  ///
  /// The command is bracketed rather than merely terminated, because what
  /// precedes its output is not predictable: the shell prints a prompt whose
  /// shape is its own business, and the device's shell also echoes the line it
  /// was given. Both land before the opening marker and are excluded by where
  /// the frame starts, rather than by recognising them - which would mean
  /// keeping a list of prompt shapes and being wrong about the first one
  /// missing from it.
  ///
  /// Both markers also appear inside the echoed command line. They are told
  /// apart by what follows: the echoed opening marker is followed by `;` and
  /// the printed one by a newline; the echoed closing marker is followed by
  /// `:$?` and the printed one by the status digits.
  static func frame(in buffer: Data, nonce: String) -> FrameReading {
    let begin = Data("\(nonce)B".utf8)
    let end = Data("\(nonce):".utf8)
    var searchFrom = buffer.startIndex
    var bodyStart: Data.Index?
    while let found = buffer.range(of: begin, in: searchFrom..<buffer.endIndex) {
      var index = found.upperBound
      while index < buffer.endIndex, buffer[index] == 0x0D {
        index = buffer.index(after: index)
      }
      if index < buffer.endIndex, buffer[index] == 0x0A {
        bodyStart = buffer.index(after: index)
        break
      }
      searchFrom = found.upperBound
    }
    guard let bodyStart else {
      return buffer.range(of: begin) == nil ? .absent : .incomplete
    }
    searchFrom = bodyStart
    while let found = buffer.range(of: end, in: searchFrom..<buffer.endIndex) {
      var digits = ""
      var index = found.upperBound
      while index < buffer.endIndex, buffer[index] >= 0x30, buffer[index] <= 0x39 {
        digits.append(Character(UnicodeScalar(buffer[index])))
        index = buffer.index(after: index)
      }
      if digits.isEmpty {
        searchFrom = found.upperBound
        continue
      }
      // A status still being written must not be read as a shorter one.
      guard index < buffer.endIndex, let status = Int32(digits) else { return .incomplete }
      return .complete(body: Data(buffer[bodyStart..<found.lowerBound]), status: status)
    }
    return .incomplete
  }

  private func isAliveLocked() -> Bool {
    guard childPID > 0 else { return false }
    var status: Int32 = 0
    let reaped = unsafe waitpid(childPID, &status, WNOHANG)
    if reaped == childPID {
      childPID = -1
      return false
    }
    return reaped == 0
  }

  /// Reads whatever is available, and returns as soon as it has read
  /// something. Waiting out the rest of a window after the answer has already
  /// arrived would add that window to every command — which is most of what a
  /// channel exists to remove.
  private func drain(until deadline: Date) {
    while Date() < deadline {
      var descriptor = pollfd(
        fd: master, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
      let polled = unsafe Darwin.poll(&descriptor, 1, remaining)
      if polled <= 0 { return }
      var buffer = [UInt8](repeating: 0, count: 8_192)
      let count = unsafe buffer.withUnsafeMutableBytes {
        unsafe Darwin.read(master, $0.baseAddress, $0.count)
      }
      if count > 0 {
        pending.append(contentsOf: buffer.prefix(count))
        return
      } else if count == 0 {
        return
      } else if errno != EAGAIN, errno != EINTR {
        return
      }
    }
  }

  private func writeAll(_ data: Data) throws {
    var written = 0
    while written < data.count {
      let count = unsafe data.withUnsafeBytes { raw -> Int in
        unsafe Darwin.write(master, raw.baseAddress!.advanced(by: written), raw.count - written)
      }
      if count > 0 {
        written += count
      } else if errno == EAGAIN || errno == EINTR {
        continue
      } else {
        throw DeviceShellChannelError.unavailable("channel write failed")
      }
    }
  }

  private func closeLocked() {
    guard !isClosed else { return }
    isClosed = true
    if master >= 0 {
      Darwin.close(master)
      master = -1
    }
    if childPID > 0 {
      kill(-childPID, SIGKILL)
      var status: Int32 = 0
      _ = unsafe waitpid(childPID, &status, 0)
      childPID = -1
    }
    pending.removeAll()
  }
}

private func cStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
  guard values.allSatisfy({ !$0.contains("\0") }) else {
    throw DeviceShellChannelError.unavailable("cannot materialize the channel command")
  }
  return unsafe values.map { unsafe strdup($0) } + [nil]
}

private func freeCStrings(_ values: inout [UnsafeMutablePointer<CChar>?]) {
  for unsafe value in unsafe values { unsafe free(value) }
  unsafe values.removeAll(keepingCapacity: false)
}
