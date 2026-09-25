// Shared Swift oracle for the Rust ArkTrace doctor probe (CHG-2026-074,
// TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckWorkflows

/// Swift `ProductionArkTraceDoctorProbe.probe` — the reviewed CLI's
/// `doctor --self-test` run at its canonical path inside its bundle, its
/// pinned files and tree held, under a private home — over a stand-in CLI
/// compiled from `rust/tests/fixtures/arktrace-doctor/fake-arktrace.c` into a
/// bundle at one fixed root: the oracle
/// `rust/tests/fixtures/arktrace-doctor` the Rust probe replays.
///
/// The stand-in logs how it was run and answers with the oracle's bytes, so
/// each case sets what it prints, what it writes to stderr and how it exits:
/// the reviewed envelope, and each way the probe refuses one — any member of
/// another value, set or type, a warning, a truncation, a missing, reordered,
/// failed or unsafely named check, an extra member, a duplicate one, a
/// fractional number, a non-zero exit, a diagnostic, output past the 256 KiB
/// a probe keeps, none, or not JSON — and each drift the probe refuses before
/// it runs anything: its pinned tree, a pinned file, a namespace another user
/// could write. An envelope names the executable's own digest, which depends
/// on the compiler that built it, so the oracle records `SHA` in its place.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARKTRACE_DOCTOR_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArkTraceDoctorOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/arktrace-doctor", directoryHint: .isDirectory)
  static let root = "/private/tmp/arkdeck-arktrace-oracle/doctor"
  static let app = "\(root)/ArkTraceCLI.app"
  static let executable = "\(app)/Contents/MacOS/arktrace"
  static let manifest = "\(app)/Contents/Resources/manifest.json"
  static let home = "\(root)/home"

  static func check(_ code: String, _ name: String, _ status: String = "ok") -> String {
    #"{"code":"\#(code)","name":"\#(name)","status":"\#(status)"}"#
  }

  static let checks = [
    ("tool", "ArkTrace CLI"), ("os", "macOS"), ("architecture", "arm64"),
    ("parserManifest", "Parser manifest"), ("parserIdentity", "Parser identity"),
    ("sqlite", "SQLite"), ("cache", "Cache"), ("schemaAdapter", "Schema adapter"),
    ("selfTest", "Self-test"),
  ]

  static func envelope(
    checks list: [String] = checks.map { check($0.0, $0.1) },
    replacing: [(String, String)] = []
  ) -> String {
    var text =
      #"{"schemaVersion":"1.0","tool":{"name":"arktrace","version":"0.1.0","buildRevision":"SHA"},"#
      + #""request":{"command":"doctor","parameters":{"selfTest":true}},"trace":null,"#
      + #""provenance":null,"limits":{"timeoutMs":120000,"maxRows":10000,"maxEvents":10000,"#
      + #""maxOutputBytes":262144},"dataQuality":{"status":"ok","warnings":[]},"#
      + #""truncation":{"truncated":false,"sections":[]},"result":{"checks":["#
      + list.joined(separator: ",") + #"],"selfTest":true}}"# + "\n"
    for (old, new) in replacing {
      precondition(text.contains(old), old)
      text = text.replacingOccurrences(of: old, with: new)
    }
    return text
  }

  struct Case {
    let name: String
    var stdout = envelope()
    var stderr = ""
    var exit: Int?
    /// `treeDrift`, `resourceDrift` or `namespaceWritable`.
    var alteration: String?
  }

  static var cases: [Case] {
    let valid = checks.map { check($0.0, $0.1) }
    var reordered = valid
    reordered.swapAt(0, 1)
    func named(_ name: String) -> [String] {
      var list = valid
      list[4] = check("parserIdentity", name)
      return list
    }
    return [
      Case(name: "reviewed"),
      Case(name: "trailingWhitespace", stdout: envelope() + "  \n"),
      Case(name: "toolVersion", stdout: envelope(replacing: [(#""0.1.0""#, #""0.2.0""#)])),
      Case(name: "buildRevision", stdout: envelope(replacing: [(#""SHA""#, #""0000""#)])),
      Case(name: "toolName", stdout: envelope(replacing: [(#""arktrace""#, #""ArkTrace""#)])),
      Case(name: "command", stdout: envelope(replacing: [(#""doctor""#, #""summary""#)])),
      Case(
        name: "selfTestParameter",
        stdout: envelope(replacing: [(#"{"selfTest":true}"#, #"{"selfTest":false}"#)])),
      Case(
        name: "selfTestParameterNumber",
        stdout: envelope(replacing: [(#"{"selfTest":true}"#, #"{"selfTest":1}"#)])),
      Case(name: "schemaVersion", stdout: envelope(replacing: [(#""1.0""#, #""1.1""#)])),
      Case(name: "traceNotNull", stdout: envelope(replacing: [(#""trace":null"#, #""trace":{}"#)])),
      Case(
        name: "timeoutMs",
        stdout: envelope(replacing: [(#""timeoutMs":120000"#, #""timeoutMs":60000"#)])),
      Case(
        name: "timeoutMsFraction",
        stdout: envelope(replacing: [(#""timeoutMs":120000"#, #""timeoutMs":120000.0"#)])),
      Case(
        name: "timeoutMsBoolean",
        stdout: envelope(replacing: [(#""timeoutMs":120000"#, #""timeoutMs":true"#)])),
      Case(name: "maxRows", stdout: envelope(replacing: [(#""maxRows":10000"#, #""maxRows":1000"#)])),
      Case(
        name: "maxOutputBytes",
        stdout: envelope(replacing: [(#""maxOutputBytes":262144"#, #""maxOutputBytes":262145"#)])),
      Case(
        name: "warning",
        stdout: envelope(replacing: [(#""warnings":[]"#, #""warnings":["slow"]"#)])),
      Case(
        name: "qualityStatus",
        stdout: envelope(replacing: [(#""status":"ok","warnings""#, #""status":"warnings","warnings""#)])),
      Case(
        name: "truncated",
        stdout: envelope(replacing: [(#""truncated":false"#, #""truncated":true"#)])),
      Case(name: "eightChecks", stdout: envelope(checks: Array(valid.dropLast()))),
      Case(name: "reorderedChecks", stdout: envelope(checks: reordered)),
      Case(
        name: "failedCheck",
        stdout: envelope(checks: {
          var list = valid
          list[5] = check("sqlite", "SQLite", "failed")
          return list
        }())),
      Case(name: "emptyCheckName", stdout: envelope(checks: named(""))),
      Case(name: "controlCheckName", stdout: envelope(checks: named("Parser\\u0007identity"))),
      Case(name: "formatCheckName", stdout: envelope(checks: named("Parser\u{200B}identity"))),
      Case(name: "longCheckName", stdout: envelope(checks: named(String(repeating: "n", count: 129)))),
      Case(name: "boundCheckName", stdout: envelope(checks: named(String(repeating: "n", count: 128)))),
      Case(
        name: "extraMember",
        stdout: envelope(replacing: [(#""schemaVersion":"1.0","#, #""schemaVersion":"1.0","extra":1,"#)])),
      Case(
        name: "duplicateMember",
        stdout: envelope(replacing: [(#""schemaVersion":"1.0","#, #""schemaVersion":"1.0","schemaVersion":"1.0","#)])),
      Case(
        name: "resultSelfTest",
        stdout: envelope(replacing: [(#"],"selfTest":true}}"#, #"],"selfTest":false}}"#)])),
      Case(name: "exit3", exit: 3),
      Case(name: "diagnostic", stderr: "warning: slow disk\n"),
      Case(name: "past256KiB", stdout: envelope() + String(repeating: " ", count: 262_144)),
      Case(name: "silent", stdout: ""),
      Case(name: "notJSON", stdout: "doctor: ok\n"),
      Case(name: "treeDrift", alteration: "treeDrift"),
      Case(name: "resourceDrift", alteration: "resourceDrift"),
      Case(name: "namespaceWritable", alteration: "namespaceWritable"),
    ]
  }

  func testSwiftProbesTheSharedArkTraceStandIn() async throws {
    let lock = try ArkTraceProfileLoaderOracleContractTests.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_ARKTRACE_DOCTOR_RECORD",
      oracle: Self.oracle)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    for directory in [
      Self.root, Self.app, "\(Self.app)/Contents", "\(Self.app)/Contents/MacOS",
      "\(Self.app)/Contents/Resources",
    ] {
      try ArkTraceProfileLoaderOracleContractTests.directory(directory)
    }
    let compiler = Process()
    compiler.executableURL = URL(filePath: "/usr/bin/cc")
    compiler.arguments = [
      "-O0", "-o", Self.executable,
      Self.oracle.appending(path: "fake-arktrace.c").path,
    ]
    try compiler.run()
    compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus, 0)
    guard chmod(Self.executable, 0o755) == 0 else { throw POSIXError(.EPERM) }
    let manifestBytes = Data("{\"parser\":\"trace_streamer\"}\n".utf8)
    try ArkTraceProfileLoaderOracleContractTests.write(manifestBytes, Self.manifest, mode: 0o644)
    let executableBytes = try Data(contentsOf: URL(filePath: Self.executable))
    let executableSHA256 = AnalyzerProvider.sha256(executableBytes)
    let tree = try ArkTraceDistributionTreeHasher.digest(rootPath: Self.app)
    let contract = ArkTraceDoctorContract(
      executable: ResolvedExecutable(
        path: Self.executable, sha256: executableSHA256,
        verifiedResources: [
          ResolvedExecutableResource(
            path: Self.manifest, sha256: AnalyzerProvider.sha256(manifestBytes),
            byteCount: manifestBytes.count, requireExecutable: false),
          ResolvedExecutableResource(
            path: Self.executable, sha256: executableSHA256,
            byteCount: executableBytes.count, requireExecutable: true),
        ],
        verifiedTrees: [ResolvedExecutableTreeResource(path: Self.app, sha256: tree)],
        canonicalNamespaceRoot: Self.app),
      productVersion: "0.1.0", timeoutSeconds: 120, outputByteBudget: 256 * 1024)
    let probe = ProductionArkTraceDoctorProbe(homeURL: URL(filePath: Self.home))

    var recorded: [JSONValue] = []
    for item in Self.cases {
      try Data(item.stdout.replacingOccurrences(of: "SHA", with: executableSHA256).utf8)
        .write(to: URL(filePath: "\(Self.root)/stdout"))
      try Data(item.stderr.utf8).write(to: URL(filePath: "\(Self.root)/stderr"))
      if let exit = item.exit {
        try Data("\(exit)\n".utf8).write(to: URL(filePath: "\(Self.root)/exit"))
      } else {
        try? manager.removeItem(atPath: "\(Self.root)/exit")
      }
      try? manager.removeItem(atPath: "\(Self.root)/calls.log")
      switch item.alteration {
      case "treeDrift":
        try ArkTraceProfileLoaderOracleContractTests.write(
          Data("drift\n".utf8), "\(Self.app)/Contents/drift.txt", mode: 0o644)
      case "resourceDrift":
        try ArkTraceProfileLoaderOracleContractTests.write(
          Data("{\"parser\":\"drifted\"}\n".utf8), Self.manifest, mode: 0o644)
      case "namespaceWritable":
        guard chmod(Self.app, 0o775) == 0 else { throw POSIXError(.EPERM) }
      default: break
      }
      let result = await probe.probe(contract)
      switch item.alteration {
      case "treeDrift": try manager.removeItem(atPath: "\(Self.app)/Contents/drift.txt")
      case "resourceDrift":
        try ArkTraceProfileLoaderOracleContractTests.write(manifestBytes, Self.manifest, mode: 0o644)
      case "namespaceWritable":
        guard chmod(Self.app, 0o755) == 0 else { throw POSIXError(.EPERM) }
      default: break
      }
      let calls = (try? String(contentsOfFile: "\(Self.root)/calls.log", encoding: .utf8)) ?? ""
      recorded.append(
        .object([
          "name": .string(item.name),
          "stdout": .string(item.stdout),
          "stderr": .string(item.stderr),
          "exit": item.exit.map { .integer(Int64($0)) } ?? .null,
          "alteration": item.alteration.map(JSONValue.string) ?? .null,
          "result": .bool(result),
          "calls": .array(
            calls.split(separator: "\n").map {
              .string($0.replacingOccurrences(of: executableSHA256, with: "SHA"))
            }),
        ]))
    }
    // The private home the probe made.
    var home: [JSONValue] = []
    for path in try manager.subpathsOfDirectory(atPath: Self.home).sorted() {
      var metadata = stat()
      guard lstat("\(Self.home)/\(path)", &metadata) == 0 else { throw POSIXError(.EIO) }
      home.append(
        .object([
          "path": .string(path),
          "kind": .string(metadata.st_mode & S_IFMT == S_IFDIR ? "directory" : "other"),
          "mode": .string(String(metadata.st_mode & 0o7777, radix: 8)),
        ]))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "fake-arktrace.c": try Data(contentsOf: Self.oracle.appending(path: "fake-arktrace.c")),
      "cases.json": try encoder.encode(
        JSONValue.object([
          "cases": .array(recorded), "home": .array(home),
          "manifest": .string(String(decoding: manifestBytes, as: UTF8.self)),
        ])) + Data("\n".utf8),
    ]
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "ArkTraceDoctorOracleContractTests.testSwiftProbesTheSharedArkTraceStandIn"),
          "root": .string(Self.root),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
