import Foundation
import XCTest

@testable import ArkDeckCore

/// What Swift's CLI does for `runtime signing status` and its deprecated
/// `signing status` spelling, recorded for the Rust CLI to replay
/// (`rust/crates/arkdeck-cli/tests/signing_status.rs`).
///
/// The real `arkdeck` process runs each argv under a private home
/// (`CFFIXED_USER_HOME` and `HOME`), so the preset store it reads is the
/// case's own: none at all, or a receipt that does not decode. Neither case
/// reaches the Keychain: the receipt is judged before any secret is asked
/// about. The record is each run's argv, exit status, stdout, stderr and the
/// files the run left under the home, with their bytes. Every machine run
/// names its correlation identity, so each envelope is fixed.
///
/// Record a new oracle with
/// `ARKDECK_RUST_SIGNING_STATUS_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLISigningStatusOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/signing-status", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_SIGNING_STATUS_RECORD"
  private static let presetDirectory = "Library/Application Support/ArkDeck/Signing/OpenHarmony"

  private struct Case {
    let name: String
    let argv: [String]
    /// The receipt's bytes, when the case installs one.
    let receipt: Data?
  }

  private static let cases: [Case] = {
    let corrupt = Data("{\"schemaVersion\":\"arkdeck-openharmony-signing/v1\"}".utf8)
    return [
      Case(
        name: "notInstalledJson",
        argv: [
          "runtime", "signing", "status", "--output", "json",
        ], receipt: nil),
      Case(name: "notInstalledHuman", argv: ["runtime", "signing", "status"], receipt: nil),
      Case(
        name: "legacyNotInstalledJson",
        argv: [
          "signing", "status", "--output", "json",
        ], receipt: nil),
      Case(name: "legacyNotInstalledHuman", argv: ["signing", "status"], receipt: nil),
      Case(name: "legacyRawJson", argv: ["signing", "status", "--json"], receipt: nil),
      Case(
        name: "corruptReceiptJson",
        argv: [
          "runtime", "signing", "status", "--output", "json",
        ], receipt: corrupt),
      Case(
        name: "unexpectedOption",
        argv: [
          "runtime", "signing", "status", "--bundle-name", "x", "--output", "json",
        ], receipt: nil),
    ]
  }()

  private struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runCLI(_ arguments: [String], home: URL) throws -> CLIRun {
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["CFFIXED_USER_HOME"] = home.path
    environment["HOME"] = home.path
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIRun(
      exitCode: process.terminationStatus,
      stdout: String(decoding: out, as: UTF8.self),
      stderr: String(decoding: err, as: UTF8.self))
  }

  /// Every regular file under `home`, relative, with its bytes as text.
  private static func files(under home: URL) throws -> [JSONValue] {
    guard
      let walker = FileManager.default.enumerator(
        at: home, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var found: [(String, String)] = []
    let prefix = home.resolvingSymlinksInPath().path + "/"
    for case let url as URL in walker
    where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(prefix) else { continue }
      found.append(
        (
          String(path.dropFirst(prefix.count)),
          String(decoding: try Data(contentsOf: url), as: UTF8.self)
        ))
    }
    return found.sorted { $0.0 < $1.0 }.map {
      .object(["path": .string($0.0), "content": .string($0.1)])
    }
  }

  func testSwiftSigningStatusTheRustCLIReplays() throws {
    var records: [JSONValue] = []
    for scripted in Self.cases {
      let home = FileManager.default.temporaryDirectory.appending(
        path: "ads-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: home) }
      if let receipt = scripted.receipt {
        let directory = home.appending(path: Self.presetDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try receipt.write(to: directory.appending(path: "preset-v1.json"))
      }
      let run = try runCLI(scripted.argv, home: home)
      records.append(
        .object([
          "name": .string(scripted.name), "argv": .array(scripted.argv.map(JSONValue.string)),
          "receipt": scripted.receipt.map { .string(String(decoding: $0, as: UTF8.self)) }
            ?? .null,
          "exit": .integer(Int64(run.exitCode)),
          "stdout": .string(
            run.stdout.replacingOccurrences(
              of: #"ctl-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
              with: "ctl-<uuid>", options: .regularExpression)),
          "stderr": .string(run.stderr), "files": .array(try Self.files(under: home)),
        ]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] = try encoder.encode(JSONValue.array(records)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLISigningStatusOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.runSigning"),
            .string("OpenHarmonySigningPresetStore.status"),
            .string("OpenHarmonySigningCredentialOwner.current"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
