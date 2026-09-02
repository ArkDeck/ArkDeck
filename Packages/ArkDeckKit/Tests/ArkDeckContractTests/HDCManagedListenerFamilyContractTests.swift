import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony

/// Real `hdc 3.2.0f` binds its channel host through a dual-stack socket: the
/// kernel reports the `127.0.0.1:8710` listener as `AF_INET6` with the
/// IPv4-mapped loopback address. The managed-ownership gate used to accept
/// only `AF_INET`, so a daemon on protected `main` launched the real tool,
/// watched it become reachable, and then refused to bind it to its own
/// identity — the Runtime never opened its socket. These tests drive the fake
/// fixture through both socket families the real tool and the fixture can
/// take, and prove the rule is closed: the mapped loopback form is accepted,
/// the IPv6-only loopback (which cannot serve `127.0.0.1`) is not.
final class HDCManagedListenerFamilyContractTests: XCTestCase {
  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }

  private struct FixtureServer {
    let process: Process
    let endpoint: HDCServerEndpoint
    let candidate: HDCCandidate
    let arguments: [String]
    var pid: Int32 { process.processIdentifier }

    func stop() {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
  }

  private func startFixtureServer(port: UInt16, family: String?) throws -> FixtureServer {
    let fixture = productsDirectory.appending(path: "ArkDeckFakeHDCFixture")
    guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
      throw XCTSkip("ArkDeckFakeHDCFixture binary not built")
    }
    let digest = SHA256.hash(data: try Data(contentsOf: fixture))
      .map { String(format: "%02x", $0) }.joined()
    let endpoint = HDCServerEndpoint("127.0.0.1:\(port)")
    let arguments = ["managed-server", "-s", endpoint.rawValue]
    let process = Process()
    process.executableURL = fixture
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["ARKDECK_FAKE_HDC_LISTENER_FAMILY"] = family
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let server = FixtureServer(
      process: process, endpoint: endpoint,
      candidate: HDCCandidate(path: fixture, source: .userConfigured, sha256: digest),
      arguments: arguments)
    let loopbackIsIPv6Only = family == "inet6-loopback"
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if loopbackConnects(port: port, ipv6: loopbackIsIPv6Only) { return server }
      usleep(50_000)
    }
    server.stop()
    XCTFail("fixture listener on \(endpoint.rawValue) (\(family ?? "inet")) never came up")
    throw XCTSkip("fixture listener unavailable")
  }

  private func loopbackConnects(port: UInt16, ipv6: Bool) -> Bool {
    if ipv6 {
      let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }
      var address = sockaddr_in6()
      address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = port.bigEndian
      guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else { return false }
      return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
        }
      }
    }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in(
      sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
      sin_family: sa_family_t(AF_INET),
      sin_port: port.bigEndian,
      sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
      sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  private func startIdentity(of pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
  }

  private func evidence(for server: FixtureServer, endpoint: HDCServerEndpoint? = nil, arguments: [String]? = nil, pid: Int32? = nil) -> HDCManagedServerLaunchEvidence {
    HDCManagedServerLaunchEvidence(
      endpoint: endpoint ?? server.endpoint,
      pid: pid ?? server.pid,
      toolPath: server.candidate.path,
      arguments: arguments ?? server.arguments,
      generation: 7,
      version: .unknown(reason: "managed listener family fixture"))
  }

  private func receipt(for server: FixtureServer) throws -> HDCServerProcessIdentityReceipt {
    let start = try XCTUnwrap(startIdentity(of: server.pid))
    return HDCServerProcessIdentityReceipt(
      pid: server.pid, startSeconds: start.seconds, startMicroseconds: start.microseconds,
      executablePath: server.candidate.path.resolvingSymlinksInPath().standardizedFileURL,
      executableSHA256: server.candidate.sha256, endpoint: server.endpoint)
  }

  func testManagedOwnershipAcceptsTheRealToolsDualStackLoopbackListener() throws {
    let server = try startFixtureServer(port: 18_851, family: "inet6-mapped")
    defer { server.stop() }
    XCTAssertTrue(
      SystemHDCManagedServerProcessInspector().matches(evidence(for: server)),
      "an AF_INET6 listener on ::ffff:127.0.0.1 is how hdc 3.2.0f owns 127.0.0.1:<port>")
    XCTAssertTrue(
      HDCCommandlessServerIdentity.verifiesManagedProcess(
        try receipt(for: server), arguments: server.arguments),
      "the daemon's startup binding goes through this predicate")
  }

  func testManagedOwnershipStillAcceptsAPlainIPv4Listener() throws {
    let server = try startFixtureServer(port: 18_852, family: nil)
    defer { server.stop() }
    XCTAssertTrue(SystemHDCManagedServerProcessInspector().matches(evidence(for: server)))
    XCTAssertTrue(
      HDCCommandlessServerIdentity.verifiesManagedProcess(
        try receipt(for: server), arguments: server.arguments))
  }

  func testAnIPv6OnlyLoopbackListenerDoesNotOwnTheIPv4Endpoint() throws {
    let server = try startFixtureServer(port: 18_853, family: "inet6-loopback")
    defer { server.stop() }
    XCTAssertFalse(
      SystemHDCManagedServerProcessInspector().matches(evidence(for: server)),
      "::1 cannot serve 127.0.0.1, so it is not the declared endpoint's listener")
    XCTAssertFalse(
      HDCCommandlessServerIdentity.verifiesManagedProcess(
        try receipt(for: server), arguments: server.arguments))
  }

  func testTheDualStackRuleDoesNotLoosenTheOtherBindings() throws {
    let server = try startFixtureServer(port: 18_854, family: "inet6-mapped")
    defer { server.stop() }
    let inspector = SystemHDCManagedServerProcessInspector()
    XCTAssertFalse(
      inspector.matches(evidence(for: server, endpoint: HDCServerEndpoint("127.0.0.1:18_855"))),
      "another port is not owned")
    XCTAssertFalse(
      inspector.matches(evidence(for: server, arguments: ["managed-server", "-s", "127.0.0.1:18_855"])),
      "argv must still match the launch record exactly")
    XCTAssertFalse(
      inspector.matches(evidence(for: server, pid: getpid())),
      "a different live process is not the managed server")
    server.stop()
    XCTAssertFalse(
      inspector.matches(evidence(for: server)),
      "a dead process owns nothing")
  }
}
