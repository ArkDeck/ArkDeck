import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCLI
@testable import ArkDeckCore

final class AgentClientDeadlineContractTests: XCTestCase {
  /// A deliberately uncooperative local peer. These are transport fixtures,
  /// never a production Runtime or device transport.
  private func withPeer(
    connections: Int = 1,
    readRequest: Bool = true,
    reply: @escaping @Sendable (Int, Int32, Data) -> Void,
    body: (AgentClient) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "acd-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = directory.appending(path: "s").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketPath.utf8CString.withUnsafeBytes { source in buffer.copyMemory(from: source) }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(listener, 2), 0)
    let served = expectation(description: "fixture peer finished")
    DispatchQueue.global().async {
      defer { served.fulfill() }
      for index in 0..<connections {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 3000) > 0 else {
          return XCTFail("fixture did not receive the expected connection")
        }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return XCTFail("fixture accept failed") }
        defer { close(connection) }
        var suppress: Int32 = 1
        _ = setsockopt(
          connection, SOL_SOCKET, SO_NOSIGPIPE, &suppress,
          socklen_t(MemoryLayout.size(ofValue: suppress)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(
          connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
          socklen_t(MemoryLayout.size(ofValue: timeout)))
        var frame = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while readRequest && !frame.contains(0x0A) {
          let count = read(connection, &chunk, chunk.count)
          guard count > 0 else { return XCTFail("fixture received no complete request") }
          frame.append(contentsOf: chunk.prefix(count))
        }
        reply(index, connection, frame)
      }
    }
    defer { wait(for: [served], timeout: 5) }
    try body(AgentClient(socketPath: socketPath))
  }

  private static func awaitClientClose(_ connection: Int32) {
    var byte: UInt8 = 0
    XCTAssertEqual(read(connection, &byte, 1), 0, "timeout must close only the client's connection")
  }

  func testSilentPeerRespectsAMillisecondDeadlineAndClosesTheConnection() throws {
    try withPeer(reply: { _, connection, _ in Self.awaitClientClose(connection) }) { client in
      let deadline = try AgentClientWaitDeadline(milliseconds: 150)
      let started = ContinuousClock.now
      XCTAssertThrowsError(try client.bounded(by: deadline).request(method: "health")) {
        XCTAssertEqual($0 as? AgentClientError, .deadlineExceeded)
      }
      XCTAssertLessThan(started.duration(to: .now), .seconds(2))
      XCTAssertEqual(deadline.remainingMilliseconds, 0)
    }
  }

  func testInterruptClosesAStalledUnaryReadWithoutWaitingForItsDeadline() throws {
    let cancellation = AgentClientWaitCancellation()
    try withPeer(reply: { _, connection, _ in
      cancellation.cancel()
      Self.awaitClientClose(connection)
    }) { client in
      let deadline = try AgentClientWaitDeadline(milliseconds: 30_000, cancellation: cancellation)
      let started = ContinuousClock.now
      XCTAssertThrowsError(try client.bounded(by: deadline).request(method: "job.events")) {
        XCTAssertTrue($0 is AgentClientWaitInterrupted)
      }
      XCTAssertLessThan(started.duration(to: .now), .seconds(2))
      XCTAssertGreaterThan(deadline.remainingMilliseconds, 20_000)
    }
  }

  func testPartialResponseBytesCannotRenewTheTotalReadBudget() throws {
    try withPeer(reply: { _, connection, _ in
      let response = Data((#"{"id":"test","ok":true,"result":{"ready":true}}"# + "\n").utf8)
      for value in response {
        var byte = value
        guard write(connection, &byte, 1) == 1 else { return }
        Thread.sleep(forTimeInterval: 0.04)
      }
      XCTFail("a trickled frame must not finish after the deadline")
    }) { client in
      let started = ContinuousClock.now
      let deadline = try AgentClientWaitDeadline(milliseconds: 200)
      XCTAssertThrowsError(try client.bounded(by: deadline).request(method: "health", id: "test")) {
        XCTAssertEqual($0 as? AgentClientError, .deadlineExceeded)
      }
      XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }
  }

  func testNegotiationAndDomainRequestConsumeTheSameDeadline() throws {
    try withPeer(
      connections: 2,
      reply: { index, connection, request in
        if index == 0 {
          Thread.sleep(forTimeInterval: 0.3)
          guard
            var response = ControlProtocolNegotiation.responseIfBootstrap(Data(request.dropLast()))
          else {
            return XCTFail("first request must be neutral negotiation")
          }
          response.append(0x0A)
          _ = response.withUnsafeBytes { write(connection, $0.baseAddress!, $0.count) }
        } else {
          Self.awaitClientClose(connection)
        }
      }
    ) { client in
      let deadline = try AgentClientWaitDeadline(milliseconds: 700)
      let selected = try client.bounded(by: deadline).negotiated(
        requiredMajor: 2, forMethod: "health")
      XCTAssertEqual(selected.selectedProtocolVersion, ArkDeckControlProtocol.targetVersion)
      XCTAssertLessThan(deadline.remainingMilliseconds, 450)
      let requestStarted = ContinuousClock.now
      XCTAssertThrowsError(try selected.request(method: "health")) {
        XCTAssertEqual($0 as? AgentClientError, .deadlineExceeded)
      }
      XCTAssertLessThan(
        requestStarted.duration(to: .now), .milliseconds(650),
        "negotiation cannot renew the 700ms budget")
      XCTAssertEqual(deadline.remainingMilliseconds, 0)
    }
  }

  func testDeadlineFailureNeverClaimsAMutationWasNotAccepted() {
    XCTAssertEqual(
      CLIRuntimeSession.mapped(
        .deadlineExceeded, method: "device.observations", command: "device.wait"
      ).code, .clientTimeout)
    XCTAssertEqual(
      CLIRuntimeSession.mapped(.deadlineExceeded, method: "target.adopt", command: "target.adopt")
        .code, .outcomeUnknown)
    XCTAssertEqual(
      CLIRuntimeSession.mapped(.deadlineExceeded, method: "job.submit", command: "job.submit").code,
      .outcomeUnknown)
  }

  func testBlockedWritesCannotOutliveTheSameDeadline() throws {
    try withPeer(
      readRequest: false,
      reply: { _, connection, _ in
        // Keep the peer's receive buffer full past the client's total budget.
        Thread.sleep(forTimeInterval: 0.5)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = read(connection, &bytes, bytes.count)
          if count == 0 { return }
          guard count > 0 else { return XCTFail("the expired client did not close its connection") }
        }
      }
    ) { client in
      let deadline = try AgentClientWaitDeadline(milliseconds: 200)
      XCTAssertThrowsError(
        try client.bounded(by: deadline).request(
          method: "health",
          params: ["fixturePadding": .string(String(repeating: "x", count: 3 * 1024 * 1024))])
      ) {
        XCTAssertEqual($0 as? AgentClientError, .deadlineExceeded)
      }
    }
  }

  func testAnExpiredDeadlineDoesNotOpenAnotherConnection() throws {
    let deadline = try AgentClientWaitDeadline(milliseconds: 1)
    Thread.sleep(forTimeInterval: 0.01)
    XCTAssertThrowsError(
      try AgentClient(socketPath: "/nonexistent/fixture.sock").bounded(by: deadline).request(
        method: "health")
    ) {
      XCTAssertEqual(
        $0 as? AgentClientError, .deadlineExceeded, "a new connection would fail differently")
    }
  }
}
