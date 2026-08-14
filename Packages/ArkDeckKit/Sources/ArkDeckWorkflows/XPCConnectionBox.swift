import ArkDeckCore
import Foundation
import os

/// Sendable-safe holder for an `NSXPCConnection` captured by facade reply
/// closures. One definition for all App-facing facades; the connection class
/// itself is thread-safe, the box only carries the reference across the
/// `@Sendable` boundary.
final class XPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
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
enum RuntimeXPCRequestTransport {
  enum Failure: Error, Sendable, Equatable {
    case compose
    case unavailable(String?)
    case refused(String)
    case emptyResponse
    case timedOut

    var message: String {
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

  typealias ResultValue = Result<Data, Failure>
  typealias Reply = @Sendable (ResultValue) -> Void

  static let ordinaryTimeoutSeconds: TimeInterval = 120
  static let runtimeJobTimeoutSeconds: TimeInterval = (4 * 60 * 60) + (5 * 60)

  static func request(
    method: String,
    params: [String: JSONValue]? = nil,
    timeoutSeconds: TimeInterval? = nil
  ) async -> ResultValue {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
    } catch {
      return .failure(.compose)
    }

    let box = XPCConnectionBox(
      NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
    return await awaitReply(
      timeoutSeconds: timeoutSeconds ?? defaultTimeoutSeconds(for: method),
      cleanup: { box.connection.invalidate() }
    ) { finish in
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { error in
          finish(.failure(.unavailable(error.localizedDescription)))
        } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure(.unavailable(nil)))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure(.refused(refusal)))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure(.emptyResponse))
        }
      }
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
  static func awaitReply(
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
