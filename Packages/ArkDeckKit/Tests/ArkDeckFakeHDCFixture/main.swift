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
  case selectedDeviceReady
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
  let logURL = URL(fileURLWithPath: invocationLog)
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
if suppliedArguments.first == "uninstall" {
  mode = .success
} else if suppliedArguments.first == "managed-server" {
  mode = .managedServer
} else if endpointBoundArguments == ["-v"] {
  mode = .version
} else if endpointBoundArguments == ["list", "targets", "-v"] {
  mode = .selectedDeviceReady
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
  let chunk = Data(repeating: 0x61, count: 8 * 1024)
  for _ in 0..<128 { FileHandle.standardOutput.write(chunk) }
  FileHandle.standardOutput.write(Data("[Fail] Offline after transfer\n".utf8))
case .endpoint:
  let selected = ProcessInfo.processInfo.environment["OHOS_HDC_SERVER_PORT"] ?? "missing"
  FileHandle.standardOutput.write(Data("endpoint-port=\(selected)\n".utf8))
case .unknown:
  FileHandle.standardOutput.write(Data("unregistered fixture output\n".utf8))
case .managedServer:
  guard let endpointIndex = suppliedArguments.firstIndex(of: "-s"),
    suppliedArguments.indices.contains(endpointIndex + 1),
    let separator = suppliedArguments[endpointIndex + 1].lastIndex(of: ":"),
    suppliedArguments[endpointIndex + 1][..<separator] == "127.0.0.1",
    let port = UInt16(
      suppliedArguments[endpointIndex + 1][
        suppliedArguments[endpointIndex + 1].index(after: separator)...]),
    port > 0
  else { exit(64) }
  let listener = socket(AF_INET, SOCK_STREAM, 0)
  guard listener >= 0 else { exit(65) }
  var reuse: Int32 = 1
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
  let bindResult = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindResult == 0, listen(listener, 1) == 0 else { exit(67) }
  while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)) }
}
