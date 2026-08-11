// Runtime client library (CHG-2026-047, T07).
//
// Thin, transport-only: connects to the daemon's user-private Unix socket
// and speaks the versioned JSON line protocol. Carries no execution logic,
// no provider types and no argv - the strongest injection defense is that
// this surface simply has nowhere to put a command.

import ArkDeckCore
import Darwin
import Foundation

package enum AgentClientError: Error, Equatable, Sendable {
  case connectFailed(String)
  case transport(String)
  case malformedResponse(String)
  case daemonError(code: String, message: String)
}

public struct AgentClient: Sendable {
  public let socketPath: String

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  /// One request per connection: simple, race-free, and cheap at local
  /// UDS latencies. Pooling can come later without changing callers.
  public func request(
    method: String, params: [String: JSONValue]? = nil, id: String = UUID().uuidString,
    timeoutSeconds: Int? = nil
  ) throws -> JSONValue {
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
    if let timeoutSeconds {
      guard timeoutSeconds > 0 else {
        throw AgentClientError.transport("timeout must be positive")
      }
      var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
      guard
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
          == 0,
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
          == 0
      else {
        throw AgentClientError.transport("cannot configure bounded socket timeout")
      }
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
    guard connectResult == 0 else {
      throw AgentClientError.connectFailed("connect failed: errno \(errno)")
    }

    let wire = AgentWireRequest(
      protocolVersion: "1.0.0", id: id, method: method, params: params)
    let encoder = CanonicalJSONEncoders.canonical()
    var payload = try encoder.encode(wire)
    payload.append(0x0A)
    var written = 0
    let sendOK: Bool = payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return false }
      while written < payload.count {
        let result = write(fd, base + written, payload.count - written)
        if result <= 0 { return false }
        written += result
      }
      return true
    }
    guard sendOK else { throw AgentClientError.transport("short write") }

    // Only bytes that arrived since the last search can hold the terminator.
    // Rescanning the whole buffer after every read is quadratic in response
    // size, and responses run up to the 8 MB bound below; `memchr` also beats
    // the byte-at-a-time `Collection` scan on the bytes it does look at.
    var buffer = Data()
    var scannedByteCount = 0
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    var terminatorOffset: Int
    while true {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw AgentClientError.transport("request timed out before response")
        }
        throw AgentClientError.transport("connection closed before response")
      }
      buffer.append(contentsOf: chunk[0..<count])
      if buffer.count > 8 * 1024 * 1024 {
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
    let response: AgentWireResponse
    do {
      response = try JSONDecoder().decode(AgentWireResponse.self, from: line)
    } catch {
      throw AgentClientError.malformedResponse("\(error)")
    }
    guard response.id == id else {
      throw AgentClientError.malformedResponse("response id mismatch")
    }
    if response.ok {
      return response.result ?? .null
    }
    throw AgentClientError.daemonError(
      code: response.error?.code ?? "unknown",
      message: response.error?.message ?? "daemon returned no error detail")
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
    let id: String
    let method: String
    let params: [String: JSONValue]?
  }

  private struct AgentWireResponse: Codable {
    struct WireError: Codable {
      let code: String
      let message: String
    }
    let id: String
    let ok: Bool
    let result: JSONValue?
    let error: WireError?
  }
}
