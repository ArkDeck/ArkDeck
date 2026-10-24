import ArkDeckCore
import Foundation
import Testing
import XPC
import os

@testable import ArkDeckClientKit

struct RuntimeXPCRequestTransportTests {
  /// A live endpoint that never invokes its reply closure is bounded by the
  /// caller's own deadline, not by any other bound (the ordinary deadline is
  /// 120 s): the transport arms exactly the deadline it was given, and when
  /// that deadline passes the wait ends as a timeout that claims no
  /// rejection. The deadline is passed by the test, not waited for on a
  /// loaded runner's wall clock.
  @Test func sharedTransportBoundsASilentEndpointWithoutClaimingRejection() async {
    let armed = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
    let result = await RuntimeXPCRequestTransport.awaitReply(
      timeoutSeconds: 0.01,
      armTimeout: { seconds, fire in
        armed.withLock { $0.append(seconds) }
        // The deadline passes after the silent endpoint has started.
        DispatchQueue.global().async(execute: fire)
      }
    ) { _ in
      // Reproduces a live endpoint that never invokes its reply closure.
    }

    #expect(result == .failure(.timedOut))
    #expect(armed.withLock { $0 } == [0.01])
    #expect(!RuntimeXPCRequestTransport.Failure.timedOut.message.contains("retry"))
    #expect(RuntimeXPCRequestTransport.Failure.timedOut.message.contains("may already"))
  }

  /// The production deadline fires on its own: a silent endpoint behind the
  /// dispatch timer still ends as a timeout. How long a loaded runner takes
  /// to deliver it is not this test's question; the time limit only turns a
  /// timer that never fires into a failure instead of a hang.
  @Test(.timeLimit(.minutes(1)))
  func productionDeadlineEndsASilentEndpoint() async {
    let result = await RuntimeXPCRequestTransport.awaitReply(timeoutSeconds: 0.01) { _ in }
    #expect(result == .failure(.timedOut))
  }

  @Test func sharedTransportUsesTheFirstTerminalSignalAndCleansUpOnce() async {
    let cleanupCount = OSAllocatedUnfairLock(initialState: 0)
    let expected = Data("first".utf8)
    let result = await RuntimeXPCRequestTransport.awaitReply(
      timeoutSeconds: 0.01,
      cleanup: { cleanupCount.withLock { $0 += 1 } },
      start: { finish in
        finish(.success(expected))
        finish(.failure(.emptyResponse))
      })

    #expect(result == .success(expected))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(cleanupCount.withLock { $0 } == 1)
  }

  /// SPK-8 negative (b), in process: a live Runtime that answers but fails
  /// this App's release-pinned `serverCodeRequirement` (this test process is
  /// not the ArkDeck team's daemon, just as another release is not this one)
  /// is named as a release mismatch with its remedy, well inside the 5 s
  /// health bound, instead of hanging or being called an interruption.
  @Test func releaseMismatchedRuntimeIsReportedWithItsRemedyWithoutHanging() async throws {
    let listener = AnonymousRuntimeListener(requirement: nil)
    let startedAt = ContinuousClock.now
    let result = await listener.request()

    guard case .failure(.unavailable(let detail?)) = result else {
      Issue.record("expected an unavailable Runtime, got \(result)")
      return
    }
    #expect(detail == ArkDeckAgentXPC.runtimeReleaseMismatchDetail)
    #expect(detail.contains("does not match this App"))
    #expect(detail.hasSuffix("run runtime service update"))
    #expect(startedAt.duration(to: .now) < .seconds(4))
  }

  /// SPK-8 negative (a), in process: the listener installs the App's code
  /// requirement on each peer before activation, exactly as the Rust
  /// daemon's `arkdeck_mach_listen` does. A client that is not the ArkDeck
  /// team's App is cut off with zero handler entries, and the App transport
  /// keeps calling that an interruption rather than a release mismatch.
  @Test func runtimeRefusingAForeignClientDispatchesNothing() async throws {
    let listener = AnonymousRuntimeListener(requirement: ArkDeckAgentXPC.appCodeRequirement)
    let result = await listener.request()

    // libxpc may deliver the cut-off to the reply or to the event handler
    // first; both keep their existing interruption wording.
    let interruption: Set<String> = [
      "Runtime transport mismatch or interruption; run runtime service update",
      "Runtime connection interrupted; run runtime service update",
    ]
    guard case .failure(.unavailable(let detail?)) = result, interruption.contains(detail) else {
      Issue.record("expected an interrupted Runtime, got \(result)")
      return
    }
    #expect(listener.dispatches == 0)
  }
}

/// A one-process stand-in for the Mach service: an anonymous libxpc listener
/// whose handler counts entries and answers every frame. No launchd, Mach
/// name or installed Runtime is involved.
private final class AnonymousRuntimeListener: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.arkdeck.tests.anonymous-runtime")
  private let listener: xpc_connection_t
  private let entries = OSAllocatedUnfairLock(initialState: 0)

  init(requirement: String?) {
    listener = xpc_connection_create(nil, queue)
    let entries = entries
    xpc_connection_set_event_handler(listener) { peer in
      guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
      if let requirement,
        xpc_connection_set_peer_code_signing_requirement(peer, requirement) != 0
      {
        xpc_connection_cancel(peer)
        return
      }
      // The handler answers on the connection each frame arrived on rather
      // than capturing `peer`: an `xpc_object_t` is not `Sendable`, and this
      // handler is a `@Sendable` closure.
      xpc_connection_set_event_handler(peer) { event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
          let reply = xpc_dictionary_create_reply(event)
        else { return }
        entries.withLock { $0 += 1 }
        guard let connection = xpc_dictionary_get_remote_connection(event) else { return }
        let frame = Data("{}".utf8)
        frame.withUnsafeBytes { xpc_dictionary_set_data(reply, "frame", $0.baseAddress, $0.count) }
        xpc_connection_send_message(connection, reply)
      }
      xpc_connection_activate(peer)
    }
    xpc_connection_activate(listener)
  }

  deinit { xpc_connection_cancel(listener) }

  var dispatches: Int { entries.withLock { $0 } }

  func request() async -> RuntimeXPCRequestTransport.ResultValue {
    let endpoint = ArkDeckRawXPCObject(xpc_endpoint_create(listener))
    let box = XPCConnectionBox { queue in
      let connection = xpc_connection_create_from_endpoint(endpoint.value)
      xpc_connection_set_target_queue(connection, queue)
      return connection
    }
    let requestID = UUID().uuidString
    let healthID = UUID().uuidString
    guard
      let frame = try? ArkDeckAgentXPC.requestFrame(method: "history.list", requestID: requestID),
      let health = try? ArkDeckAgentXPC.requestFrame(method: "health", requestID: healthID)
    else { return .failure(.compose) }
    let live = OSAllocatedUnfairLock(initialState: true)
    let result = await RuntimeXPCRequestTransport.awaitReply(timeoutSeconds: 30) { finish in
      box.enqueue(
        token: UUID(), live: live, frame: frame, health: health,
        requestID: requestID, healthID: healthID, reply: finish)
    }
    withExtendedLifetime(box) {}
    return result
  }
}
