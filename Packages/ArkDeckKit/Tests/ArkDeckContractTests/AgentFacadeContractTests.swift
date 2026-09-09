import Darwin
import Foundation
import XCTest
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore

final class AgentFacadeContractTests: XCTestCase {
  func testPrivateOriginRequiresExactFieldsUIDAndFrameDigest() throws {
    let frame = try ArkDeckAgentXPC.requestFrame(method: "health", requestID: "origin-test")
    var fields: [String: JSONValue] = [
      "arkdeckOrigin": .integer(1), "transport": .string("unixSocket"),
      "foregroundConsole": .bool(true), "peerEUID": .integer(Int64(geteuid())),
      "peerPID": .integer(Int64(getpid())), "frameSHA256": .string(SHA256Hex.string(of: frame))]
    func origin() throws -> AgentFacadeOrigin? {
      AgentFacadeOrigin(try CanonicalJSONEncoders.canonical().encode(fields))
    }
    let valid = try XCTUnwrap(origin())
    XCTAssertEqual(valid.context, .unixSocket(foregroundConsole: true))
    XCTAssertTrue(valid.validates(frame))
    XCTAssertFalse(valid.validates(frame + Data(" ".utf8)))
    fields["transport"] = .string("appXPC")
    XCTAssertNil(try origin())
    fields["foregroundConsole"] = .bool(false)
    XCTAssertEqual(try origin()?.context, .appXPC)
    fields["peerEUID"] = .integer(Int64(geteuid()) + 1)
    XCTAssertNil(try origin())
    fields["peerEUID"] = .integer(Int64(geteuid()))
    fields["extra"] = .bool(true)
    XCTAssertNil(try origin())
  }

  func testPrivatePairingCannotBeOmittedOrWidened() throws {
    let secret = String(repeating: "a", count: 64)
    let config = try AgentFacadeConfiguration(socketURL: URL(filePath: "/private/tmp/test.sock"), secret: secret)
    func pairing(_ value: JSONValue) throws -> Bool {
      config.authenticates(try CanonicalJSONEncoders.canonical().encode(value))
    }
    XCTAssertTrue(try pairing(.object(["arkdeckPairing": .integer(1), "secret": .string(secret)])))
    XCTAssertFalse(try pairing(.object(["arkdeckPairing": .integer(1)])))
    XCTAssertFalse(try pairing(.object(["arkdeckPairing": .integer(1), "secret": .string(String(repeating: "b", count: 64))])))
    XCTAssertFalse(try pairing(.object(["arkdeckPairing": .integer(1), "secret": .string(secret), "extra": .bool(true)])))
  }
}

extension AgentDaemonContractTests {
  /// Run the identical process/UDS subset with either executable. A facade run
  /// additionally supplies ARKDECK_SWIFT_DAEMON to select its paired authority.
  func testExternalDaemonSingleV1Contract() throws {
    guard let executable = ProcessInfo.processInfo.environment["ARKDECK_DAEMON_UNDER_TEST"] else {
      throw XCTSkip("set ARKDECK_DAEMON_UNDER_TEST for the external Swift/facade matrix")
    }
    let directory = URL(filePath: "/private/tmp/xpa-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let socketPath = directory.appending(path: "agentd.sock").path
    let process = Process()
    process.executableURL = URL(filePath: executable)
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ARKDECK_") }
    if let swift = ProcessInfo.processInfo.environment["ARKDECK_SWIFT_DAEMON"] {
      environment["ARKDECK_SWIFT_DAEMON"] = swift
      environment["ARKDECK_ENDPOINT"] = socketPath
    } else { process.arguments = ["--state-dir", directory.path] }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      try? FileManager.default.removeItem(at: directory)
    }
    let deadline = Date().addingTimeInterval(30)
    while !FileManager.default.fileExists(atPath: socketPath), process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertTrue(process.isRunning)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      socketPath.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connected, 0)
    func send(_ frame: Data) throws -> [String: JSONValue] {
      let bytes = frame + Data([10])
      let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
      XCTAssertEqual(written, bytes.count)
      var response = Data()
      var byte: UInt8 = 0
      while response.count < 8 * 1024 * 1024 {
        guard read(fd, &byte, 1) == 1 else { throw POSIXError(.EIO) }
        if byte == 10 { break }
        response.append(byte)
      }
      return try JSONDecoder().decode([String: JSONValue].self, from: response)
    }
    let frame = try ArkDeckAgentXPC.requestFrame(method: "health", requestID: "external")
    XCTAssertEqual(try send(frame)["ok"], .bool(true))
    var fields = try JSONDecoder().decode([String: JSONValue].self, from: frame)
    fields["arkdeckOrigin"] = .object(["foregroundConsole": .bool(true)])
    let forged = try send(CanonicalJSONEncoders.canonical().encode(fields))
    guard case .object(let error)? = forged["error"] else { return XCTFail("missing structural refusal") }
    XCTAssertEqual(error["code"], .string("malformedFrame"))
    fields.removeValue(forKey: "arkdeckOrigin")
    fields["method"] = .string("unpublished.method")
    let unknown = try send(CanonicalJSONEncoders.canonical().encode(fields))
    guard case .object(let unknownError)? = unknown["error"] else { return XCTFail("missing method refusal") }
    XCTAssertEqual(unknownError["code"], .string("unknownMethod"))
    fields["method"] = .string("health")
    fields["protocolVersion"] = .string("0.0.0")
    let old = try send(CanonicalJSONEncoders.canonical().encode(fields))
    guard case .object(let oldError)? = old["error"] else { return XCTFail("missing version refusal") }
    XCTAssertEqual(oldError["code"], .string("unsupportedProtocolVersion"))
  }
}
