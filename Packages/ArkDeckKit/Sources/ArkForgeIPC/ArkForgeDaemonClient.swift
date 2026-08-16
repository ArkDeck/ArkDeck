import Darwin
import Foundation

/// Frame layer: a 4-byte big-endian length followed by that many bytes.
///
/// The length is checked against the limit *before* anything is allocated, so
/// a peer cannot make this process reserve memory by claiming a large frame.
public enum ArkForgeFraming {
  /// Matches `arkforge_ipc::wire::MAX_FRAME_BYTES`. A mismatch here would show
  /// up as one side refusing frames the other considers legal.
  public static let maxFrameBytes = 16 * 1024 * 1024
}

public enum ArkForgeClientError: Error, CustomStringConvertible {
  case socketPathTooLong(path: String, limit: Int)
  case connectFailed(String)
  case transport(String)
  case handshakeRefused(String)
  case protocolMismatch(peerMajor: UInt32, peerMinor: UInt32)
  case wire(ProtobufWireError)
  case daemonRefused(api: ArkForgeApi, status: ArkForgeStatus, error: ArkForgeError?)

  public var description: String {
    switch self {
    case .socketPathTooLong(let path, let limit):
      return "socket path is \(path.utf8.count) bytes but the platform limit is \(limit)"
    case .connectFailed(let detail): return "connect failed: \(detail)"
    case .transport(let detail): return detail
    case .handshakeRefused(let reason): return "daemon refused the session: \(reason)"
    case .protocolMismatch(let major, let minor):
      return
        "daemon speaks protocol \(major).\(minor); this build speaks "
        + "\(ArkForgeHello.protocolMajor).\(ArkForgeHello.protocolMinor)"
    case .wire(let error): return "wire: \(error)"
    case .daemonRefused(let api, let status, let error):
      let detail = error.map { " (\($0))" } ?? ""
      return "\(api) refused with \(status)\(detail)"
    }
  }
}

/// A controller-session client for `arkforged`.
///
/// # What this owns and does not own
///
/// It carries bytes. Every decision about *whether* a step may run stays with
/// the caller: this type will encode a permit the caller signed and will
/// encode a refusal the caller chose, and it has no way to construct either
/// one for itself. That is the same split the daemon enforces from its side —
/// `arkforged` verifies permits and cannot mint them.
///
/// # Why the daemon never calls out
///
/// Every message is client-initiated. The daemon *asks* on the `watchJob`
/// stream and waits for the authority to call back in on a second request,
/// which leaves the authority free to answer, to refuse, or to say nothing —
/// three outcomes the daemon distinguishes (design §3.1). So this client
/// exposes a stream you pull from, not a delegate the daemon pushes to.
public final class ArkForgeDaemonClient {
  private let descriptor: Int32
  private var pending: [UInt8] = []
  public let helloAck: ArkForgeHelloAck

  /// Opens a controller session and completes the handshake.
  ///
  /// The handshake is not a formality: it carries the two standing execution
  /// facts and the bound toolchain digest, and a caller that ignores them can
  /// materialize a plan this daemon could never run.
  public init(
    socketPath: String, sessionKind: ArkForgeSessionKind = .controller,
    timeoutSeconds: Int = 30
  ) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw ArkForgeClientError.connectFailed("socket() failed: errno \(errno)")
    }
    var opened = true
    defer { if !opened { close(fd) } }
    opened = false

    var suppressSignal: Int32 = 1
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw ArkForgeClientError.transport("cannot suppress SIGPIPE") }

    // A write that never returns would hang whichever queue drives it. Every
    // call here is bounded; a partition write takes minutes, but it reports
    // progress as events rather than by blocking one read for its duration.
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        == 0,
      setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        == 0
    else { throw ArkForgeClientError.transport("cannot configure bounded socket timeout") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let limit = MemoryLayout.size(ofValue: address.sun_path)
    guard socketPath.utf8.count < limit else {
      throw ArkForgeClientError.socketPathTooLong(path: socketPath, limit: limit - 1)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketPath.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      throw ArkForgeClientError.connectFailed("errno \(errno) for \(socketPath)")
    }
    opened = true
    self.descriptor = fd

    try Self.writeFrame(fd, ArkForgeHello(sessionKind: sessionKind).encoded)
    var buffer: [UInt8] = []
    guard let ackFrame = try Self.readFrame(fd, pending: &buffer) else {
      throw ArkForgeClientError.transport("daemon closed before acknowledging the handshake")
    }
    self.pending = buffer
    let ack: ArkForgeHelloAck
    do {
      ack = try ArkForgeHelloAck.decode(ackFrame)
    } catch let error as ProtobufWireError {
      throw ArkForgeClientError.wire(error)
    }
    if let refusal = ack.refusal {
      throw ArkForgeClientError.handshakeRefused(refusal)
    }
    guard ack.protocolMajor == ArkForgeHello.protocolMajor else {
      throw ArkForgeClientError.protocolMismatch(
        peerMajor: ack.protocolMajor, peerMinor: ack.protocolMinor)
    }
    self.helloAck = ack
  }

  deinit { close(descriptor) }

  public func closeSession() {
    close(descriptor)
  }

  // MARK: - Calls

  /// Sends a request and reads exactly one response.
  public func call(_ request: ArkForgeRequest) throws -> ArkForgeResponse {
    try Self.writeFrame(descriptor, request.encoded)
    guard let frame = try Self.readFrame(descriptor, pending: &pending) else {
      throw ArkForgeClientError.transport("daemon closed while answering \(request.api)")
    }
    do {
      return try ArkForgeResponse.decode(frame)
    } catch let error as ProtobufWireError {
      throw ArkForgeClientError.wire(error)
    }
  }

  /// Sends a request and returns the payload only when the daemon answered OK.
  ///
  /// A refusal is raised rather than returned, because every caller of these
  /// APIs treats "refused" as a stop: `startExecution` refused means no job
  /// exists, and continuing as though one did is how a caller ends up waiting
  /// for events that will never arrive.
  public func callExpectingOK(_ request: ArkForgeRequest) throws -> Data {
    let response = try call(request)
    guard response.status == .ok else {
      throw ArkForgeClientError.daemonRefused(
        api: request.api, status: response.status, error: try response.errorBody())
    }
    return response.payload
  }

  public func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
    -> ArkForgeStartExecutionResponse
  {
    let payload = try callExpectingOK(
      ArkForgeRequest(requestID: requestID, api: .startExecution, payload: body.encoded))
    return try ArkForgeStartExecutionResponse.decode(payload)
  }

  public func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
    -> ArkForgeSubmitStepPermitResponse
  {
    let payload = try callExpectingOK(
      ArkForgeRequest(requestID: requestID, api: .submitStepPermit, payload: body.encoded))
    return try ArkForgeSubmitStepPermitResponse.decode(payload)
  }

  public func submitManagedControlReceipt(
    _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
  ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
    let payload = try callExpectingOK(
      ArkForgeRequest(
        requestID: requestID, api: .submitManagedControlReceipt, payload: body.encoded))
    return try ArkForgeSubmitManagedControlReceiptResponse.decode(payload)
  }

  /// Requests cancellation.
  ///
  /// Returns the cancellation state when the daemon could settle one. A
  /// `CANCEL_NOT_SAFE` refusal surfaces as `daemonRefused`, and per design
  /// §6.3.1 that is a *refused* cancellation — the write is still running and
  /// will produce its own receipt. It must not be recorded as an unconfirmed
  /// teardown; there is no process group here for this authority to tear down.
  public func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
    let payload = try callExpectingOK(
      ArkForgeRequest(
        requestID: requestID, api: .cancelJob,
        payload: ArkForgeCancelJobRequest(jobID: jobID).encoded))
    return try ArkForgeCancelJobResponse.decode(payload)
  }

  /// Streams job events, calling `handle` for each until the stream ends.
  ///
  /// `handle` returns `false` to stop reading early. The daemon polls rather
  /// than pushes (design §3.2), so a handler that blocks holds up nothing on
  /// the daemon side except this one stream.
  ///
  /// Sequence numbers are the journal's, so a gap means this authority missed
  /// an event — not that none happened. Reconnect with `fromSequence` set to
  /// the last one seen.
  public func watchJob(
    _ body: ArkForgeWatchJobRequest, requestID: String,
    handle: (ArkForgeJobEvent) throws -> Bool
  ) throws {
    try Self.writeFrame(
      descriptor,
      ArkForgeRequest(requestID: requestID, api: .watchJob, payload: body.encoded).encoded)
    while true {
      guard let frame = try Self.readFrame(descriptor, pending: &pending) else { return }
      let response: ArkForgeResponse
      do {
        response = try ArkForgeResponse.decode(frame)
      } catch let error as ProtobufWireError {
        throw ArkForgeClientError.wire(error)
      }
      guard response.status == .ok else {
        throw ArkForgeClientError.daemonRefused(
          api: .watchJob, status: response.status, error: try response.errorBody())
      }
      if !response.payload.isEmpty {
        let event: ArkForgeJobEvent
        do {
          event = try ArkForgeJobEvent.decode(response.payload)
        } catch let error as ProtobufWireError {
          throw ArkForgeClientError.wire(error)
        }
        if try !handle(event) { return }
      }
      if response.streamEnd { return }
    }
  }

  // MARK: - Frames

  static func writeFrame(_ fd: Int32, _ body: Data) throws {
    guard body.count <= ArkForgeFraming.maxFrameBytes else {
      throw ArkForgeClientError.wire(.frameTooLarge(body.count))
    }
    var payload = Data()
    let length = UInt32(body.count)
    payload.append(contentsOf: [
      UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
    payload.append(body)

    var written = 0
    let ok: Bool = payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return false }
      while written < payload.count {
        let result = write(fd, base + written, payload.count - written)
        if result <= 0 { return false }
        written += result
      }
      return true
    }
    guard ok else { throw ArkForgeClientError.transport("short write after \(written) bytes") }
  }

  /// Reads one frame, buffering whatever arrived past its end.
  ///
  /// Returns nil at a clean end of stream: the peer closing *between* frames
  /// is not an error, and treating it as one would turn every normal
  /// disconnection into a failure to report.
  static func readFrame(_ fd: Int32, pending: inout [UInt8]) throws -> Data? {
    while pending.count < 4 {
      guard try fill(fd, into: &pending) else {
        if pending.isEmpty { return nil }
        throw ArkForgeClientError.transport("stream ended inside a frame header")
      }
    }
    let length =
      Int(pending[0]) << 24 | Int(pending[1]) << 16 | Int(pending[2]) << 8 | Int(pending[3])
    guard length <= ArkForgeFraming.maxFrameBytes else {
      throw ArkForgeClientError.wire(.frameTooLarge(length))
    }
    while pending.count < 4 + length {
      guard try fill(fd, into: &pending) else {
        throw ArkForgeClientError.transport("stream ended inside a frame body")
      }
    }
    let body = Data(pending[4..<(4 + length)])
    pending.removeFirst(4 + length)
    return body
  }

  private static func fill(_ fd: Int32, into buffer: inout [UInt8]) throws -> Bool {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let count = read(fd, &chunk, chunk.count)
    if count == 0 { return false }
    if count < 0 {
      if errno == EAGAIN || errno == EWOULDBLOCK {
        throw ArkForgeClientError.transport("timed out waiting for the daemon")
      }
      throw ArkForgeClientError.transport("read failed: errno \(errno)")
    }
    buffer.append(contentsOf: chunk[0..<count])
    return true
  }
}
