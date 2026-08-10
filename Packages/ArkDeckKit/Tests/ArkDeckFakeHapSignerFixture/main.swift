import Darwin
import Foundation

// Process-only hapsigner stand-in. It never contacts a device and its output
// is simulation evidence only; contract tests use it to exercise the PTY and
// postflight boundaries without storing real signing material in the repo.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, arguments[0] == "-jar" else { exit(64) }
let mode = (try? String(contentsOfFile: arguments[1], encoding: .utf8)) ?? "success"

func value(after option: String) -> String? {
  guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
    return nil
  }
  return arguments[index + 1]
}

func writeOutput(_ text: String) {
  FileHandle.standardOutput.write(Data(text.utf8))
}

func readSecretWithoutEcho() -> Data? {
  var original = termios()
  guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
  var hidden = original
  hidden.c_lflag &= ~tcflag_t(ECHO)
  guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else { return nil }
  defer { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) }
  var result = Data()
  while result.count <= 1_024 {
    var byte: UInt8 = 0
    let count = Darwin.read(STDIN_FILENO, &byte, 1)
    if count <= 0 { return nil }
    if byte == 10 || byte == 13 { return result }
    result.append(byte)
  }
  return nil
}

switch arguments[2] {
case "sign-app":
  guard let input = value(after: "-inFile"), let output = value(after: "-outFile") else {
    exit(64)
  }
  if mode == "unknown-prompt" {
    writeOutput("Password: ")
    sleep(1)
    exit(65)
  }
  writeOutput("please input KeystorePwd (timeout 30 seconds):")
  guard let keystore = readSecretWithoutEcho(), !keystore.isEmpty else { exit(66) }
  if mode == "repeat-prompt" {
    writeOutput("please input KeystorePwd (timeout 30 seconds):")
    sleep(1)
    exit(67)
  }
  writeOutput("please input KeyPwd (timeout 30 seconds):")
  guard let key = readSecretWithoutEcho(), !key.isEmpty else { exit(68) }
  if mode == "echo-secret" {
    FileHandle.standardOutput.write(keystore)
    exit(69)
  }
  guard var bytes = try? Data(contentsOf: URL(fileURLWithPath: input)) else { exit(70) }
  bytes.append(Data("arkdeck-signed-fixture".utf8))
  do {
    try bytes.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
  } catch {
    exit(71)
  }
  exit(0)

case "verify-app":
  guard let input = value(after: "-inFile"),
    let certificate = value(after: "-outCertchain"),
    let profile = value(after: "-outProfile"),
    let bytes = try? Data(contentsOf: URL(fileURLWithPath: input)),
    bytes.starts(with: [0x50, 0x4b, 0x03, 0x04])
  else { exit(72) }
  if mode == "verify-failure" { exit(73) }
  if mode.hasPrefix("verify-once:"),
    let marker = mode.split(separator: ":", maxSplits: 1).last.map(String.init),
    !FileManager.default.fileExists(atPath: marker)
  {
    try? Data("failed-once".utf8).write(to: URL(fileURLWithPath: marker))
    exit(73)
  }
  try? Data("fixture-certificate-chain".utf8).write(
    to: URL(fileURLWithPath: certificate), options: .withoutOverwriting)
  if mode != "empty-profile" {
    try? Data("fixture-profile".utf8).write(
      to: URL(fileURLWithPath: profile), options: .withoutOverwriting)
  } else {
    try? Data().write(to: URL(fileURLWithPath: profile), options: .withoutOverwriting)
  }
  exit(0)

default:
  exit(64)
}
