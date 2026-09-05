// Runtime client library (CHG-2026-047, T07).
//
// Thin, transport-only: connects to the daemon's user-private Unix socket
// and speaks the versioned JSON line protocol. Carries no execution logic,
// no provider types and no argv - the strongest injection defense is that
// this surface simply has nowhere to put a command.

import ArkDeckCore
import Darwin
import Foundation

public enum AgentClientError: Error, Equatable, Sendable {
  case connectFailed(String)
  case transport(String)
  case malformedResponse(String)
  case daemonError(code: String, message: String)
  case structuredDaemonError(code: String, message: String, details: [String: JSONValue])
  /// The caller's total waiting budget expired. This never cancels a request.
  case deadlineExceeded
}

public struct AgentClient: Sendable {
  public let socketPath: String
  public var protocolVersion: String { ArkDeckControlProtocol.currentVersion }
  private var waitDeadline: AgentClientWaitDeadline?

  public init(socketPath: String) {
    self.socketPath = socketPath
    self.waitDeadline = nil
  }

  /// All exchanges made with this copy, including the connection identity check, share the same
  /// absolute deadline. Copying it cannot renew the budget.
  package func bounded(by deadline: AgentClientWaitDeadline) -> Self {
    var copy = self
    copy.waitDeadline = waitDeadline.map { $0.intersecting(deadline) } ?? deadline
    return copy
  }

  /// Each business request checks health on the same socket before sending.
  /// A reconnect repeats the check; a lost reply is never replayed.
  public func request(
    method: String, params: [String: JSONValue]? = nil, id: String = UUID().uuidString,
    timeoutSeconds: Int? = nil
  ) throws -> JSONValue {
    try waitDeadline?.check()
    let wire = AgentWireRequest(
      protocolVersion: ArkDeckControlProtocol.currentVersion,
      contractIdentity: ArkDeckControlProtocol.contractIdentity,
      id: id, method: method, params: params)
    let payload = try CanonicalJSONEncoders.canonical().encode(wire)
    let line = try exchange(payload, timeoutSeconds: timeoutSeconds, verifyContract: method != "health")
    let response: AgentWireResponse
    do {
      _ = try ControlProtocolContract.responseFields(line, id: id)
      if method == "health" { try ControlProtocolContract.validateHealth(line, id: id) }
      response = try JSONDecoder().decode(AgentWireResponse.self, from: line)
    } catch {
      throw AgentClientError.malformedResponse("\(error)")
    }
    try waitDeadline?.check()
    guard response.id == id else {
      throw AgentClientError.malformedResponse("response id mismatch")
    }
    if response.ok { return response.result ?? .null }
    if let error = response.error, let details = error.details
    {
      throw AgentClientError.structuredDaemonError(
        code: error.code, message: error.message, details: details)
    }
    throw AgentClientError.daemonError(
      code: response.error?.code ?? "unknown",
      message: response.error?.message ?? "daemon returned no error detail")
  }

  private func exchange(
    _ frame: Data, timeoutSeconds: Int?, verifyContract: Bool
  ) throws -> Data {
    try waitDeadline?.check()
    guard frame.count + 1 <= ArkDeckControlProtocol.maximumRequestFrameBytes else {
      throw AgentClientError.transport("oversized request; no request was sent")
    }
    if let timeoutSeconds, timeoutSeconds <= 0 { throw AgentClientError.transport("timeout must be positive") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentClientError.connectFailed("cannot create socket") }
    defer { close(fd) }
    // The daemon closes the connection on an oversize frame and on restart, so
    // writing into a closed peer must surface as a transport error the caller
    // can handle. Without this the default SIGPIPE disposition kills the whole
    // process mid-request instead.
    var suppressSignal: Int32 = 1
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw AgentClientError.transport("cannot suppress SIGPIPE") }
    var activeDeadline: AgentClientWaitDeadline? = try waitDeadline
      ?? AgentClientWaitDeadline(milliseconds: min(timeoutSeconds ?? 5, 5) * 1000)
    let originalFlags = fcntl(fd, F_GETFL)
    guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
      throw AgentClientError.transport("cannot configure nonblocking socket")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw AgentClientError.connectFailed(
        "socket path is \(socketPath.utf8.count) bytes but the platform limit is "
          + "\(MemoryLayout.size(ofValue: address.sun_path) - 1); "
          + "run the daemon with a shorter --state-dir")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketPath.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult != 0 {
      let connectError = errno
      guard let activeDeadline,
        connectError == EINPROGRESS || connectError == EALREADY || connectError == EWOULDBLOCK
      else { throw AgentClientError.connectFailed("connect failed: errno \(connectError)") }
      try Self.waitForSocket(fd, events: Int16(POLLOUT), deadline: activeDeadline)
      var socketError: Int32 = 0
      var size = socklen_t(MemoryLayout.size(ofValue: socketError))
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
        throw AgentClientError.connectFailed("connect failed: errno \(socketError)")
      }
    }

    func exchangeOnConnection(_ frame: Data) throws -> Data {
      var payload = frame
      payload.append(0x0A)
      var written = 0
      try payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { throw AgentClientError.transport("empty request") }
        while written < payload.count {
          try activeDeadline?.check()
          let result = write(fd, base + written, payload.count - written)
          if result > 0 {
            written += result
          } else if result < 0, errno == EINTR {
            continue
          } else if result < 0, let activeDeadline, errno == EAGAIN || errno == EWOULDBLOCK {
            try Self.waitForSocket(fd, events: Int16(POLLOUT), deadline: activeDeadline)
          } else {
            throw AgentClientError.transport("short write")
          }
        }
      }

      // Only bytes that arrived since the last search can hold the terminator.
      // Rescanning the whole buffer after every read is quadratic in response
      // size, and responses run up to the 8 MB bound below; `memchr` also beats
      // the byte-at-a-time `Collection` scan on the bytes it does look at.
      var buffer = Data()
      var scannedByteCount = 0
      var chunk = [UInt8](repeating: 0, count: 64 * 1024)
      var terminatorOffset: Int
      while true {
        try activeDeadline?.check()
        let count = read(fd, &chunk, chunk.count)
        if count < 0, errno == EINTR { continue }
        if count < 0, let activeDeadline, errno == EAGAIN || errno == EWOULDBLOCK {
          try Self.waitForSocket(fd, events: Int16(POLLIN), deadline: activeDeadline)
          continue
        }
        if count <= 0 {
          if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            throw AgentClientError.transport("request timed out before response")
          }
          throw AgentClientError.transport("connection closed before response")
        }
        buffer.append(contentsOf: chunk[0..<count])
        if buffer.count > ArkDeckControlProtocol.maximumResponseFrameBytes {
          throw AgentClientError.transport("oversized response")
        }
        if let offset = Self.frameTerminatorOffset(in: buffer, from: scannedByteCount) {
          terminatorOffset = offset
          break
        }
        scannedByteCount = buffer.count
      }
      let line = buffer.subdata(
        in: buffer.startIndex..<(buffer.startIndex + terminatorOffset))
      guard terminatorOffset + 1 == buffer.count else {
        throw AgentClientError.malformedResponse("multiple response frames for one request")
      }
      try activeDeadline?.check()
      return line
    }
    if verifyContract {
      let healthID = UUID().uuidString
      let health = AgentWireRequest(
        protocolVersion: ArkDeckControlProtocol.currentVersion,
        contractIdentity: ArkDeckControlProtocol.contractIdentity,
        id: healthID, method: "health", params: nil)
      do {
        let response = try exchangeOnConnection(CanonicalJSONEncoders.canonical().encode(health))
        try ControlProtocolContract.validateHealth(response, id: healthID)
      } catch {
        if error is AgentClientWaitInterrupted { throw error }
        try waitDeadline?.check()
        throw AgentClientError.structuredDaemonError(
          code: "unsupportedProtocolVersion",
          message: "the connected Runtime could not prove the current contract; no business request was sent",
          details: ["phase": .string("preAdmission"), "newDispatchCount": .integer(0)])
      }
    }
    if verifyContract { activeDeadline = waitDeadline }
    if verifyContract && waitDeadline == nil {
      guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
        throw AgentClientError.transport("cannot restore socket mode")
      }
      var timeout = timeval(tv_sec: timeoutSeconds ?? 0, tv_usec: 0)
      guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
        throw AgentClientError.transport("cannot configure socket timeout")
      }
    }
    return try exchangeOnConnection(frame)
  }

  private static func waitForSocket(
    _ fd: Int32, events: Int16, deadline: AgentClientWaitDeadline
  ) throws {
    while true {
      try deadline.check()
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, Int32(deadline.socketPollMilliseconds))
      try deadline.check()
      if result > 0 {
        guard descriptor.revents & Int16(POLLNVAL) == 0 else {
          throw AgentClientError.transport("socket became invalid")
        }
        // HUP/ERR also wake the syscall, which then reports EOF/the IO error.
        return
      }
      if result < 0, errno != EINTR {
        throw AgentClientError.transport("socket wait failed: errno \(errno)")
      }
    }
  }

  /// Offset of the first frame terminator at or after `searchedByteCount`,
  /// relative to `buffer.startIndex`, or nil while the response is incomplete.
  private static func frameTerminatorOffset(
    in buffer: Data, from searchedByteCount: Int
  ) -> Int? {
    guard searchedByteCount < buffer.count else { return nil }
    return buffer.withUnsafeBytes { raw -> Int? in
      guard let base = raw.baseAddress,
        let hit = memchr(
          base.advanced(by: searchedByteCount), 0x0A, raw.count - searchedByteCount)
      else { return nil }
      return base.distance(to: UnsafeRawPointer(hit))
    }
  }

  private struct AgentWireRequest: Codable {
    let protocolVersion: String
    let contractIdentity: String
    let id: String
    let method: String
    let params: [String: JSONValue]?
  }

  private struct AgentWireResponse: Codable {
    struct WireError: Codable {
      let code: String
      let message: String
      let details: [String: JSONValue]?
    }
    let id: String
    let ok: Bool
    let result: JSONValue?
    let error: WireError?
  }
}

/// One invocation's waiting budget, never a Runtime operation budget. The
/// continuous clock prevents wall-clock rollback or machine sleep from giving
/// the client extra time; a forward wall-clock jump also expires the wait.
package struct AgentClientWaitDeadline: Sendable {
  private let wallDeadline: Date
  private let continuousDeadline: ContinuousClock.Instant
  private let budgetMilliseconds: Int
  private let cancellations: [AgentClientWaitCancellation]

  package init(milliseconds: Int, cancellation: AgentClientWaitCancellation? = nil) throws {
    guard (1...86_400_000).contains(milliseconds) else {
      throw AgentClientError.transport("client wait must be between 1ms and 24h")
    }
    budgetMilliseconds = milliseconds
    cancellations = cancellation.map { [$0] } ?? []
    wallDeadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
    continuousDeadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
  }

  private init(
    wallDeadline: Date, continuousDeadline: ContinuousClock.Instant,
    budgetMilliseconds: Int, cancellations: [AgentClientWaitCancellation]
  ) {
    self.wallDeadline = wallDeadline
    self.continuousDeadline = continuousDeadline
    self.budgetMilliseconds = budgetMilliseconds
    self.cancellations = cancellations
  }

  fileprivate func intersecting(_ other: Self) -> Self {
    Self(
      wallDeadline: min(wallDeadline, other.wallDeadline),
      continuousDeadline: min(continuousDeadline, other.continuousDeadline),
      budgetMilliseconds: min(budgetMilliseconds, other.budgetMilliseconds),
      cancellations: cancellations + other.cancellations)
  }

  package var remainingMilliseconds: Int {
    let remaining = ContinuousClock.now.duration(to: continuousDeadline).components
    let continuousMilliseconds = Double(remaining.seconds) * 1000
      + Double(remaining.attoseconds) / 1_000_000_000_000_000
    let wallMilliseconds = wallDeadline.timeIntervalSinceNow * 1000
    let bounded = min(Double(budgetMilliseconds), continuousMilliseconds, wallMilliseconds)
    guard bounded.isFinite, bounded > 0 else { return 0 }
    return Int(bounded.rounded(.up))
  }

  package func check() throws {
    if cancellations.contains(where: { $0.isCancelled }) { throw AgentClientWaitInterrupted() }
    guard remainingMilliseconds > 0 else { throw AgentClientError.deadlineExceeded }
  }

  fileprivate var socketPollMilliseconds: Int {
    min(remainingMilliseconds, cancellations.isEmpty ? 86_400_000 : 100)
  }
}

/// Cancels only the local wait, including a stalled unary read. It sends no
/// cancellation, abandon, run or other mutation to the Runtime.
package final class AgentClientWaitCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  package init() {}
  package var isCancelled: Bool { lock.withLock { cancelled } }
  package func cancel() { lock.withLock { cancelled = true } }
}

package struct AgentClientWaitInterrupted: Error { package init() {} }
