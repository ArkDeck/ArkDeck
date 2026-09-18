import ArkDeckCore
import Foundation
import XPC
import os

/// Two persistent channels keep a bounded job.run from occupying the ordinary
/// read channel. Each channel serializes health + request, with no replay.
final class XPCConnectionBox: @unchecked Sendable {
  typealias Reply = RuntimeXPCRequestTransport.Reply
  private struct Pending {
    let token: UUID
    let live: OSAllocatedUnfairLock<Bool>
    let frame: Data
    let health: Data
    let requestID: String
    let healthID: String
    let reply: Reply
  }
  private let queue = DispatchQueue(label: "com.arkdeck.runtime.xpc")
  private var connection: ArkDeckRawXPCObject?
  private var waiting: [Pending] = []
  private var active: Pending?
  private var healthPending: UUID?
  private var generation = UUID()

  func enqueue(
    token: UUID, live: OSAllocatedUnfairLock<Bool>, frame: Data, health: Data, requestID: String,
    healthID: String, reply: @escaping Reply
  ) {
    queue.async {
      guard live.withLock({ $0 }) else { return }
      self.waiting.append(
        Pending(
          token: token, live: live, frame: frame, health: health,
          requestID: requestID, healthID: healthID, reply: reply))
      self.advance()
    }
  }

  func cancel(_ token: UUID) {
    queue.async {
      self.waiting.removeAll { $0.token == token }
      if self.active?.token == token {
        self.active = nil
        self.invalidate()
        self.advance()
      }
    }
  }

  private func invalidate() {
    if let connection { xpc_connection_cancel(connection.value) }
    connection = nil
    generation = UUID()
    healthPending = nil
  }

  private func finish(
    _ result: RuntimeXPCRequestTransport.ResultValue, token: UUID, invalid: Bool = false
  ) {
    guard let request = active, request.token == token else { return }
    active = nil
    if invalid { invalidate() }
    request.reply(result)
    advance()
  }

  private func advance() {
    guard active == nil, !waiting.isEmpty else { return }
    let request = waiting.removeFirst()
    guard request.live.withLock({ $0 }) else {
      advance()
      return
    }
    active = request
    if connection == nil {
      let peer = ArkDeckRawXPCObject(
        xpc_connection_create_mach_service(ArkDeckAgentXPC.machServiceName, queue, 0))
      guard
        xpc_connection_set_peer_code_signing_requirement(
          peer.value, ArkDeckAgentXPC.serverCodeRequirement) == 0
      else {
        xpc_connection_cancel(peer.value)
        finish(
          .failure(
            .unavailable("Runtime identity requirement is invalid; run runtime service update")),
          token: request.token, invalid: true)
        return
      }
      let current = generation
      xpc_connection_set_event_handler(peer.value) { [weak self] event in
        guard let self, xpc_get_type(event) == XPC_TYPE_ERROR else { return }
        self.queue.async {
          guard self.generation == current else { return }
          if let active = self.active {
            self.finish(
              .failure(.unavailable("Runtime connection interrupted; run runtime service update")),
              token: active.token, invalid: true)
          } else {
            self.invalidate()
          }
        }
      }
      connection = peer
      xpc_connection_activate(peer.value)
    }
    healthPending = request.token
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, self.healthPending == request.token else { return }
      self.finish(
        .failure(
          .unavailable(
            "Runtime did not establish the current transport contract; run runtime service update")),
        token: request.token, invalid: true)
    }
    send(request.health, token: request.token) { [self] result in
      healthPending = nil
      switch result {
      case .failure(let error): finish(.failure(error), token: request.token, invalid: true)
      case .success(let data):
        let line = data.last == 10 ? Data(data.dropLast()) : data
        guard (try? ControlProtocolContract.validateHealth(line, id: request.healthID)) != nil
        else {
          finish(
            .failure(.unavailable("Runtime contract mismatch; run runtime service update")),
            token: request.token, invalid: true)
          return
        }
        send(request.frame, token: request.token) { [self] result in
          if case .success(let bytes) = result {
            let line = bytes.last == 10 ? Data(bytes.dropLast()) : bytes
            guard (try? ControlProtocolContract.responseFields(line, id: request.requestID)) != nil
            else {
              finish(.failure(.refused("malformedResponse")), token: request.token, invalid: true)
              return
            }
          }
          if case .failure = result {
            finish(result, token: request.token, invalid: true)
          } else {
            finish(result, token: request.token)
          }
        }
      }
    }
  }

  private func send(_ frame: Data, token: UUID, reply: @escaping Reply) {
    guard let active, active.token == token, let connection else { return }
    guard active.live.withLock({ $0 }) else {
      self.active = nil
      invalidate()
      advance()
      return
    }
    let message = xpc_dictionary_create(nil, nil, 0)
    frame.withUnsafeBytes { xpc_dictionary_set_data(message, "frame", $0.baseAddress, $0.count) }
    let current = generation
    xpc_connection_send_message_with_reply(connection.value, message, queue) { [self] response in
      guard self.active?.token == token, generation == current else { return }
      guard xpc_get_type(response) == XPC_TYPE_DICTIONARY,
        xpc_dictionary_get_count(response) == 1
      else {
        reply(
          .failure(
            .unavailable("Runtime transport mismatch or interruption; run runtime service update")))
        return
      }
      var length = 0
      guard let bytes = xpc_dictionary_get_data(response, "frame", &length),
        length <= ArkDeckControlProtocol.maximumResponseFrameBytes
      else {
        reply(.failure(.refused("malformedResponse")))
        return
      }
      reply(.success(Data(bytes: bytes, count: length)))
    }
  }
}

private final class XPCDispatchWorkItemBox: @unchecked Sendable {
  let item: DispatchWorkItem
  init(_ item: DispatchWorkItem) { self.item = item }
}

/// The single App-to-Runtime request transport used by every workspace.
///
/// The Runtime still owns admission and every effect. This layer only frames
/// one request, guarantees that reply/error/timeout races resume the caller
/// once, and bounds the otherwise-infinite wait when a live XPC endpoint stops
/// answering. A timeout is deliberately outcome-neutral: callers must not
/// treat it as proof that a mutating request was rejected or retry it.
package enum RuntimeXPCRequestTransport {
  package enum Failure: Error, Sendable, Equatable {
    case compose
    case unavailable(String?)
    case refused(String)
    case emptyResponse
    case timedOut

    package var message: String {
      switch self {
      case .compose:
        "Could not compose a Runtime request"
      case .unavailable(let detail):
        detail.map { "ArkDeck Runtime is not reachable: \($0)" }
          ?? "ArkDeck Runtime is not reachable"
      case .refused(let reason):
        "Runtime transport refused this request: \(reason)"
      case .emptyResponse:
        "Runtime returned neither a response nor a reason"
      case .timedOut:
        "ArkDeck Runtime did not answer in time. This request may already have been accepted. Check Runtime History before submitting another request."
      }
    }
  }

  package typealias ResultValue = Result<Data, Failure>
  package typealias Reply = @Sendable (ResultValue) -> Void

  private static let ordinaryConnection = XPCConnectionBox()
  private static let jobConnection = XPCConnectionBox()

  package static let ordinaryTimeoutSeconds: TimeInterval = 120
  package static let runtimeJobTimeoutSeconds: TimeInterval = (4 * 60 * 60) + (5 * 60)

  package static func request(
    method: String,
    params: [String: JSONValue]? = nil,
    timeoutSeconds: TimeInterval? = nil,
    protocolVersion: String = ArkDeckAgentXPC.wireProtocolVersion
  ) async -> ResultValue {
    let frame: Data
    let requestID = UUID().uuidString
    let healthID = UUID().uuidString
    let healthFrame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(
        method: method, params: params, requestID: requestID, protocolVersion: protocolVersion)
      healthFrame = try ArkDeckAgentXPC.requestFrame(method: "health", requestID: healthID)
    } catch {
      return .failure(.compose)
    }

    let box = method == "job.run" ? jobConnection : ordinaryConnection
    let token = UUID()
    let live = OSAllocatedUnfairLock(initialState: true)
    return await awaitReply(
      timeoutSeconds: timeoutSeconds ?? defaultTimeoutSeconds(for: method),
      cleanup: {
        live.withLock { $0 = false }
        box.cancel(token)
      }
    ) { finish in
      box.enqueue(
        token: token, live: live, frame: frame, health: healthFrame,
        requestID: requestID, healthID: healthID, reply: finish)
    }
  }

  private static func defaultTimeoutSeconds(for method: String) -> TimeInterval {
    // `job.run` is a synchronous view of a bounded Runtime invocation. Its
    // published destructive budget is four hours, so an ordinary RPC timeout
    // would manufacture an avoidable unknown client outcome during a valid
    // Flash. The small grace only transports the durable terminal response.
    method == "job.run" ? runtimeJobTimeoutSeconds : ordinaryTimeoutSeconds
  }

  /// Internal seam for the silent-endpoint contract test. The start closure
  /// may reply, fail, reply twice, or never reply; every path remains bounded
  /// and the first terminal signal wins.
  package static func awaitReply(
    timeoutSeconds: TimeInterval,
    cleanup: @escaping @Sendable () -> Void = {},
    start: @escaping @Sendable (@escaping Reply) -> Void
  ) async -> ResultValue {
    await withCheckedContinuation { continuation in
      struct CompletionState: Sendable {
        var answered = false
        var timeout: XPCDispatchWorkItemBox?
      }
      let completion = OSAllocatedUnfairLock(initialState: CompletionState())
      @Sendable func finish(_ result: ResultValue) {
        let outcome = completion.withLock {
          state -> (won: Bool, timeout: XPCDispatchWorkItemBox?) in
          if state.answered { return (false, nil) }
          state.answered = true
          defer { state.timeout = nil }
          return (true, state.timeout)
        }
        guard outcome.won else { return }
        outcome.timeout?.item.cancel()
        cleanup()
        continuation.resume(returning: result)
      }

      let timeout = XPCDispatchWorkItemBox(
        DispatchWorkItem {
          finish(.failure(.timedOut))
        })
      completion.withLock { $0.timeout = timeout }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + max(0, timeoutSeconds), execute: timeout.item)
      start(finish)
    }
  }
}
