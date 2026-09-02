import Darwin
import Foundation

/// Local-only HDC stand-in used by TASK-M1-006 contract tests. It performs no
/// device operation. The managed-server mode owns only an explicitly selected
/// loopback test listener so the production PID/listener evidence gate can be
/// exercised without contacting HDC hardware.
enum FixtureMode: String {
  case success
  case healthy
  case version
  case unauthorized
  case offline
  case hang
  case slow
  case crash
  case oversized
  case endpoint
  case unknown
  case healthyFailureStderr
  case mismatch
  case managedServer
  case headlessServer
  case selectedDeviceReady
  case subserver
}

let suppliedArguments = Array(CommandLine.arguments.dropFirst())
let endpointBoundArguments: [String]
if suppliedArguments.count >= 3, suppliedArguments[0] == "-s" {
  endpointBoundArguments = Array(suppliedArguments.dropFirst(2))
} else {
  endpointBoundArguments = suppliedArguments
}
if let invocationLog = ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_INVOCATION_LOG"] {
  let record = suppliedArguments.joined(separator: "\u{1F}") + "\n"
  let logURL = URL(filePath: invocationLog)
  if FileManager.default.fileExists(atPath: logURL.path),
    let handle = try? FileHandle(forWritingTo: logURL)
  {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(record.utf8))
  } else {
    try? Data(record.utf8).write(to: logURL, options: .atomic)
  }
}
let mode: FixtureMode
let fixtureConnectKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if endpointBoundArguments
  == ["-t", fixtureConnectKey, "shell", "param", "get", "const.product.name"]
{
  FileHandle.standardOutput.write(Data("OpenHarmony Reference Device\n".utf8))
  exit(0)
} else if endpointBoundArguments
  == ["-t", fixtureConnectKey, "shell", "param", "get", "const.ohos.fullname"]
{
  FileHandle.standardOutput.write(Data("OpenHarmony-4.1-release\n".utf8))
  exit(0)
} else if endpointBoundArguments.count >= 6,
  endpointBoundArguments[0] == "-t",
  endpointBoundArguments[2...4] == ["shell", "param", "get"]
{
  FileHandle.standardError.write(Data("unregistered target/property fixture invocation\n".utf8))
  exit(23)
} else if let receiveIndex = suppliedArguments.firstIndex(of: "recv"),
  receiveIndex > 0, suppliedArguments[receiveIndex - 1] == "file",
  suppliedArguments.count == receiveIndex + 3
{
  // `hdc file recv <remote> <local>` stand-in. The product is the file it
  // writes; stdout is only a progress line, which is precisely why the
  // receive verdict cannot be read off this process. The seam models the
  // three real landings: bytes at the named path, an empty file, and a
  // transfer that lands somewhere the caller did not name (DEVICE-COMMAND-
  // FACTS.md §4).
  let destination = URL(filePath: suppliedArguments[receiveIndex + 2])
  switch ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_RECV_MODE"] {
  case "nothing":
    break
  case "empty":
    try? Data().write(to: destination)
  default:
    let payload =
      ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_RECV_PAYLOAD"]
      ?? "htrace-fixture-bytes"
    try? Data(payload.utf8).write(to: destination)
  }
  FileHandle.standardOutput.write(Data("FileTransfer finish, Size:0\n".utf8))
  exit(0)
} else if suppliedArguments.first == "uninstall" {
  mode = .success
} else if suppliedArguments.first == "managed-server" {
  mode = .managedServer
} else if endpointBoundArguments == ["-m"] {
  // Production owns HDC through its exact foreground shape. This fixture
  // stays alive without binding the singleton production port so daemon
  // composition tests remain hermetic when a real login-session agentd is
  // already serving 127.0.0.1:8710 on the same test host. The separate host
  // contract locks the argv, endpoint and closed environment; checkserver
  // below supplies the registered semantic readiness receipt.
  mode = .headlessServer
} else if endpointBoundArguments == ["-v"] {
  mode = .version
} else if endpointBoundArguments == ["list", "targets", "-v"] {
  mode = .selectedDeviceReady
} else if endpointBoundArguments == ["spawn-sub"] || endpointBoundArguments == ["killall-sub"] {
  // Sealed subserver family stand-in. Like the lifecycle families it has no
  // registered success byte family: the fixture exits zero with no output and
  // the semantic gate stays fail-closed at unknownOutput.
  mode = .subserver
} else if suppliedArguments.contains("kill") {
  // Lifecycle success is established only by the post-dispatch probe, never
  // by treating arbitrary command output as a registered semantic family.
  switch ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_LIFECYCLE_MODE"] {
  case "nonzero": mode = .crash
  case "semantic-failure": mode = .unauthorized
  default: mode = .unknown
  }
} else if endpointBoundArguments == ["checkserver"] {
  // Diagnostic callers cannot alter the production argv. Contract tests vary
  // only this fake-child behavior through its child-only environment seam.
  switch ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_CHECKSERVER_MODE"] {
  case "offline": mode = .offline
  case "stderr-failure": mode = .healthyFailureStderr
  case "mismatch": mode = .mismatch
  default: mode = .healthy
  }
} else {
  mode = suppliedArguments.first.flatMap(FixtureMode.init(rawValue:)) ?? .unknown
}
switch mode {
case .success:
  FileHandle.standardOutput.write(
    Data("[Info]App uninstall path: msg:uninstall bundle successfully. \r\nAppMod finish\r\n".utf8))
case .healthy:
  FileHandle.standardOutput.write(
    Data("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n".utf8))
case .healthyFailureStderr:
  FileHandle.standardOutput.write(
    Data("Client version:Ver: 3.2.0d, server version:Ver: 3.2.0d\n".utf8))
  FileHandle.standardError.write(Data("[Fail] Offline after transfer\n".utf8))
case .mismatch:
  FileHandle.standardOutput.write(
    Data("Client version:Ver: 3.2.0d, server version:Ver: 3.1.0d\n".utf8))
case .version:
  FileHandle.standardOutput.write(Data("Ver: 3.2.0d\n".utf8))
case .selectedDeviceReady:
  // Synthetic parser control only. The identifier is deliberately fake and
  // cannot provide production provenance or device/hardware evidence.
  let row =
    ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_SELECTED_DEVICE_ROW"]
    ?? "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n"
  FileHandle.standardOutput.write(
    Data(row.utf8))
case .unauthorized:
  FileHandle.standardOutput.write(Data("[Fail] ErrorCode: E000003 Unauthorized device\n".utf8))
case .offline:
  FileHandle.standardOutput.write(Data("[Fail] Offline after transfer\n".utf8))
case .hang:
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 60))
case .slow:
  Thread.sleep(forTimeInterval: 0.2)
  FileHandle.standardOutput.write(Data("[Fail] Offline after transfer\n".utf8))
case .crash:
  exit(23)
case .oversized:
  // The process port retains a bounded 64 KiB capture per stream. Emit one
  // chunk past that cap so the capture is provably truncated, and no more:
  // the reading side classifies every chunk as it arrives, so a megabyte here
  // could not be drained inside the command timeout on a loaded host. The
  // command was then guillotined mid-drain and whether truncation had already
  // been observed came down to scheduling.
  let captureLimit = 64 * 1024
  let chunk = Data(repeating: 0x61, count: 8 * 1024)
  for _ in 0..<(captureLimit / chunk.count + 1) { FileHandle.standardOutput.write(chunk) }
  FileHandle.standardOutput.write(Data("[Fail] Offline after transfer\n".utf8))
case .endpoint:
  let selected = ProcessInfo.processInfo.environment["OHOS_HDC_SERVER_PORT"] ?? "missing"
  FileHandle.standardOutput.write(Data("endpoint-port=\(selected)\n".utf8))
case .unknown:
  FileHandle.standardOutput.write(Data("unregistered fixture output\n".utf8))
case .subserver:
  break
case .headlessServer, .managedServer:
  guard let endpointIndex = suppliedArguments.firstIndex(of: "-s"),
    suppliedArguments.indices.contains(endpointIndex + 1),
    let separator = suppliedArguments[endpointIndex + 1].lastIndex(of: ":"),
    suppliedArguments[endpointIndex + 1][..<separator] == "127.0.0.1",
    let port = UInt16(
      suppliedArguments[endpointIndex + 1][
        suppliedArguments[endpointIndex + 1].index(after: separator)...]),
    port > 0
  else { exit(64) }
  if mode == .headlessServer {
    // A real cold HDC server does not publish its listener at posix_spawn
    // return. Keep that startup interval visible so the host contract proves
    // it waits for transport readiness before accepting semantic checkserver
    // output.
    Thread.sleep(forTimeInterval: 1)
  }
  // Real `hdc 3.2.0f` binds its channel host through a dual-stack socket, so
  // the kernel reports the listener as AF_INET6 with the IPv4-mapped loopback
  // `::ffff:127.0.0.1`. `ARKDECK_FAKE_HDC_LISTENER_FAMILY=inet6-mapped`
  // reproduces that shape so the managed-ownership gate is proven against the
  // socket family the real tool actually uses, not only the plain AF_INET one.
  let listenerFamily = ProcessInfo.processInfo.environment["ARKDECK_FAKE_HDC_LISTENER_FAMILY"]
  let listener: Int32
  let bindResult: Int32
  var reuse: Int32 = 1
  if listenerFamily == "inet6-mapped" || listenerFamily == "inet6-loopback" {
    // `inet6-loopback` binds the IPv6 loopback `::1` only: a listener that
    // can never serve `127.0.0.1`, kept so the ownership rule is proven to
    // accept the mapped form and not every AF_INET6 socket on the port.
    listener = socket(AF_INET6, SOCK_STREAM, 0)
    guard listener >= 0 else { exit(65) }
    var v6Only: Int32 = listenerFamily == "inet6-loopback" ? 1 : 0
    guard
      setsockopt(
        listener, SOL_SOCKET, SO_REUSEADDR, &reuse,
        socklen_t(MemoryLayout<Int32>.size)) == 0,
      setsockopt(
        listener, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6Only,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { exit(66) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    let bound = listenerFamily == "inet6-loopback" ? "::1" : "::ffff:127.0.0.1"
    guard inet_pton(AF_INET6, bound, &address.sin6_addr) == 1 else { exit(66) }
    bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  } else {
    listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { exit(65) }
    guard
      setsockopt(
        listener, SOL_SOCKET, SO_REUSEADDR, &reuse,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { exit(66) }
    var address = sockaddr_in(
      sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
      sin_family: sa_family_t(AF_INET),
      sin_port: port.bigEndian,
      sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
      sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
  guard bindResult == 0, listen(listener, 4) == 0 else { exit(67) }
  while true {
    let client = accept(listener, nil, nil)
    if client >= 0 { close(client) }
  }
}
