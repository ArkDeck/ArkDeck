import Foundation
import XCTest
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

}
