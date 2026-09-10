import Darwin
import Foundation
import XCTest
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckAgentClient
@testable import ArkDeckStorage
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

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
    let encoded = try CanonicalJSONEncoders.canonical().encode(fields)
    XCTAssertNil(AgentFacadeOrigin(encoded + Data("\n".utf8)))
    var duplicate = Data("{\"arkdeckOrigin\":1,".utf8)
    duplicate.append(encoded.dropFirst())
    XCTAssertNil(AgentFacadeOrigin(duplicate))
    var wrongType = fields
    wrongType["foregroundConsole"] = .integer(1)
    XCTAssertNil(AgentFacadeOrigin(try CanonicalJSONEncoders.canonical().encode(wrongType)))
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
    XCTAssertFalse(try pairing(.object(["arkdeckPairing": .bool(true), "secret": .string(secret)])))
    XCTAssertFalse(config.authenticates(Data("{\"arkdeckPairing\":1,\"secret\":\"\(secret)\",\"secret\":\"\(secret)\"}".utf8)))
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


extension AgentFacadeContractTests {
  /// An isolated real Swift store and Job owner sit behind a transport-only
  /// reply barrier. No fake result is accepted as Runtime or hardware evidence.
  func testForwardedSubmitSurvivesFacadeDeathWithoutReplay() async throws {
    try await checkForwardedSubmitSurvivesPeerDeath(killAuthority: false)
  }

  func testForwardedSubmitSurvivesSwiftDeathWithoutReplay() async throws {
    try await checkForwardedSubmitSurvivesPeerDeath(killAuthority: true)
  }

  private func checkForwardedSubmitSurvivesPeerDeath(killAuthority: Bool) async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let facade = environment["ARKDECK_DAEMON_UNDER_TEST"],
      let swift = environment["ARKDECK_SWIFT_DAEMON"] else {
      throw XCTSkip("set both external executables for the real Swift journal crash test")
    }
    let root = URL(filePath: "/private/tmp/xpa-journal-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"),
      nowUTC: { "2026-09-09T00:00:00Z" })
    let source = try await store.publish(RuntimeArtifactPublicationRequest(
      jobID: "JOB-XPA-FIXTURE", sessionID: "xpa-fixture", stepID: "source",
      name: "hilog.txt", mediaType: "text/plain", privacy: .sensitive,
      retentionClass: .pinnedUntilVerified, sourceOperation: "capture.diagnostics@1",
      providerID: "hdc", bindingSnapshot: ArtifactBindingSnapshot(
        targetID: "TGT-XPA-FIXTURE", bindingRevision: 1,
        stableIdentitySHA256: String(repeating: "c", count: 64)),
      contents: Data("09-09 00:00:00.000 1 1 I C01234/Test: fixture\n".utf8)))
    let lease = try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
    let request = try RuntimeOperationRequest(requestID: "req-xpa-crash", idempotencyKey: "idem-xpa-crash",
      target: DurableTargetReference(targetID: "TGT-XPA-FIXTURE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-hilog", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    let wrapper = root.appending(path: "reply-barrier")
    try Self.replyBarrier.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let publicSocket = root.appending(path: "agentd.sock").path
    let marker = root.appending(path: "reply.json")
    var childEnvironment = environment.filter { !$0.key.hasPrefix("ARKDECK_") }
    childEnvironment["ARKDECK_SWIFT_DAEMON"] = wrapper.path
    childEnvironment["ARKDECK_ENDPOINT"] = publicSocket
    childEnvironment["ARKDECK_ANALYZER_PATH"] = swift
    childEnvironment["XPA_REAL_SWIFT"] = swift
    childEnvironment["XPA_REPLY_MARKER"] = marker.path
    childEnvironment["XPA_SWIFT_PID_FILE"] = root.appending(path: "authority.pid").path
    let process = Process()
    process.executableURL = URL(filePath: facade)
    process.environment = childEnvironment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let client = AgentClient(socketPath: publicSocket)
    let readyDeadline = Date().addingTimeInterval(30)
    while Date() < readyDeadline {
      if (try? client.request(method: "health", timeoutSeconds: 1)) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = try client.request(method: "health", timeoutSeconds: 1)
    let pending = Task.detached { () -> Bool in
      do {
        _ = try client.request(method: "job.submit", params: ["requestJson": .string(requestJSON)], timeoutSeconds: 10)
        return false // The reply barrier must prevent successful delivery.
      } catch AgentClientError.structuredDaemonError(_, _, let details) {
        return details["phase"] == nil && details["newDispatchCount"] == nil
      } catch { return true }
    }
    let replyDeadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < replyDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let reply = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: marker))
    guard reply["ok"] == .bool(true), case .object(let accepted)? = reply["result"],
      case .string(let jobID)? = accepted["jobId"] else {
      return XCTFail("real Swift submit did not commit: \(reply)")
    }
    XCTAssertEqual(accepted["deduplicated"], .bool(false))
    let killedPID: Int32
    if killAuthority {
      killedPID = try XCTUnwrap(Int32(String(contentsOf: root.appending(path: "authority.pid"), encoding: .utf8)))
    } else { killedPID = process.processIdentifier }
    XCTAssertEqual(kill(killedPID, SIGKILL), 0)
    process.waitUntilExit()
    let neutral = await pending.value
    XCTAssertTrue(neutral, "an interrupted forwarded frame cannot claim zero dispatch")

    // The paired Swift drains on EOF. Restart through its normal entry point
    // against the same store, then settle ambiguity only through typed reads.
    let restart = Process()
    restart.executableURL = URL(filePath: swift)
    restart.arguments = ["--state-dir", root.path]
    restart.environment = environment.filter { !$0.key.hasPrefix("ARKDECK_") }
    restart.environment?["ARKDECK_ANALYZER_PATH"] = swift
    restart.standardOutput = FileHandle.nullDevice
    restart.standardError = FileHandle.nullDevice
    try await Task.sleep(for: .milliseconds(300))
    try restart.run()
    defer { if restart.isRunning { restart.terminate(); restart.waitUntilExit() } }
    let readDeadline = Date().addingTimeInterval(30)
    while Date() < readDeadline {
      if (try? client.request(method: "health", timeoutSeconds: 1)) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let status = try client.request(method: "job.status", params: ["jobId": .string(jobID)])
    guard case .object(let state) = status else { return XCTFail("missing durable status") }
    XCTAssertEqual(state["jobId"], .string(jobID))
    let listed = try client.request(method: "job.list")
    guard case .object(let page) = listed, case .array(let items)? = page["items"] else {
      return XCTFail("missing durable Job page")
    }
    XCTAssertEqual(items.count, 1, "facade restart must not create a second Job")
    let repeated = try client.request(method: "job.submit", params: ["requestJson": .string(requestJSON)])
    guard case .object(let deduplicated) = repeated else { return XCTFail("missing idempotency result") }
    XCTAssertEqual(deduplicated["jobId"], .string(jobID))
    XCTAssertEqual(deduplicated["deduplicated"], .bool(true))
  }

  private static let replyBarrier = #"""
#!/usr/bin/env python3
import json,os,socket,subprocess,sys,threading,time
from pathlib import Path
secret=sys.stdin.buffer.readline()
public=Path(os.environ['ARKDECK_PRIVATE_SOCKET'])
private=public.with_name('authority.sock')
env=dict(os.environ);env['ARKDECK_PRIVATE_SOCKET']=str(private)
child=subprocess.Popen([os.environ['XPA_REAL_SWIFT'],*sys.argv[1:]],env=env,stdin=subprocess.PIPE)
child.stdin.write(secret);child.stdin.flush()
Path(os.environ['XPA_SWIFT_PID_FILE']).write_text(str(child.pid))
def authority_exit():
    child.wait();os._exit(69)
threading.Thread(target=authority_exit,daemon=True).start()
def drain():
    sys.stdin.buffer.read()
    child.stdin.close()
    try: child.wait(timeout=25)
    except subprocess.TimeoutExpired: child.terminate();child.wait(timeout=5)
    os._exit(0)
threading.Thread(target=drain,daemon=True).start()
end=time.monotonic()+25
while not private.exists():
    if child.poll() is not None or time.monotonic()>end: sys.exit(69)
    time.sleep(.01)
listener=socket.socket(socket.AF_UNIX);listener.bind(str(public));os.chmod(public,0o600);listener.listen()
def serve(peer):
    with peer,peer.makefile('rb') as incoming:
        authority=socket.socket(socket.AF_UNIX);authority.connect(str(private))
        with authority,authority.makefile('rb') as response:
            auth=incoming.readline()
            if not auth:return
            authority.sendall(auth)
            while True:
                origin=incoming.readline()
                if not origin:return
                frame=incoming.readline();authority.sendall(origin+frame)
                reply=response.readline()
                if json.loads(frame).get('method')=='job.submit':
                    Path(os.environ['XPA_REPLY_MARKER']).write_bytes(reply)
                    threading.Event().wait()
                peer.sendall(reply)
while True:
    peer,_=listener.accept();threading.Thread(target=serve,args=(peer,),daemon=True).start()
"""#
}
