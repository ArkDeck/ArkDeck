import ArkDeckCore
import Foundation
import XCTest
import XPC
import os

@testable import ArkDeckClientKit

final class RuntimeXPCRequestTransportTests: XCTestCase {
  func testSharedTransportBoundsASilentEndpointWithoutClaimingRejection() async {
    let startedAt = ContinuousClock.now
    let result = await RuntimeXPCRequestTransport.awaitReply(timeoutSeconds: 0.01) { _ in
      // Reproduces a live endpoint that never invokes its reply closure.
    }

    XCTAssertEqual(result, .failure(.timedOut))
    XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
    XCTAssertFalse(RuntimeXPCRequestTransport.Failure.timedOut.message.contains("retry"))
    XCTAssertTrue(RuntimeXPCRequestTransport.Failure.timedOut.message.contains("may already"))
  }

  func testSharedTransportUsesTheFirstTerminalSignalAndCleansUpOnce() async {
    let cleanupCount = OSAllocatedUnfairLock(initialState: 0)
    let expected = Data("first".utf8)
    let result = await RuntimeXPCRequestTransport.awaitReply(
      timeoutSeconds: 0.01,
      cleanup: { cleanupCount.withLock { $0 += 1 } },
      start: { finish in
        finish(.success(expected))
        finish(.failure(.emptyResponse))
      })

    XCTAssertEqual(result, .success(expected))
    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(cleanupCount.withLock { $0 }, 1)
  }

  /// SPK-8 negative (b), in process: a live Runtime that answers but fails
  /// this App's release-pinned `serverCodeRequirement` (this test process is
  /// not the ArkDeck team's daemon, just as another release is not this one)
  /// is named as a release mismatch with its remedy, well inside the 5 s
  /// health bound, instead of hanging or being called an interruption.
  func testReleaseMismatchedRuntimeIsReportedWithItsRemedyWithoutHanging() async throws {
    let listener = AnonymousRuntimeListener(requirement: nil)
    let startedAt = ContinuousClock.now
    let result = await listener.request()

    guard case .failure(.unavailable(let detail?)) = result else {
      return XCTFail("expected an unavailable Runtime, got \(result)")
    }
    XCTAssertEqual(detail, ArkDeckAgentXPC.runtimeReleaseMismatchDetail)
    XCTAssertTrue(detail.contains("does not match this App"))
    XCTAssertTrue(detail.hasSuffix("run runtime service update"))
    XCTAssertLessThan(startedAt.duration(to: .now), .seconds(4))
  }

  /// SPK-8 negative (a), in process: the listener installs the App's code
  /// requirement on each peer before activation, exactly as the Rust
  /// daemon's `arkdeck_mach_listen` does. A client that is not the ArkDeck
  /// team's App is cut off with zero handler entries, and the App transport
  /// keeps calling that an interruption rather than a release mismatch.
  func testRuntimeRefusingAForeignClientDispatchesNothing() async throws {
    let listener = AnonymousRuntimeListener(requirement: ArkDeckAgentXPC.appCodeRequirement)
    let result = await listener.request()

    // libxpc may deliver the cut-off to the reply or to the event handler
    // first; both keep their existing interruption wording.
    let interruption: Set<String> = [
      "Runtime transport mismatch or interruption; run runtime service update",
      "Runtime connection interrupted; run runtime service update",
    ]
    guard case .failure(.unavailable(let detail?)) = result, interruption.contains(detail) else {
      return XCTFail("expected an interrupted Runtime, got \(result)")
    }
    XCTAssertEqual(listener.dispatches, 0)
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
      xpc_connection_set_event_handler(peer) { event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
          let reply = xpc_dictionary_create_reply(event)
        else { return }
        entries.withLock { $0 += 1 }
        let frame = Data("{}".utf8)
        frame.withUnsafeBytes { xpc_dictionary_set_data(reply, "frame", $0.baseAddress, $0.count) }
        xpc_connection_send_message(peer, reply)
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
