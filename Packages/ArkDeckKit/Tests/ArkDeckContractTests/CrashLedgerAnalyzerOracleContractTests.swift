// Shared Swift oracle for the Rust daemon's `--analyze-crash-ledger` mode
// (CHG-2026-074, TASK-XPA-015).

import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Swift's one-shot crash-ledger analyzer as the Runtime runs it: the built
/// `arkdeck-agentd` with an empty environment and no stdin, over a listing
/// written to a private file first. The Rust daemon replays every case
/// (`rust/crates/arkdeck-agentd/tests/crash_ledger_analyzer.rs`) and must
/// answer with the same exit status, stdout and stderr byte for byte, except
/// a read failure's Foundation error text: only its fixed prefix is recorded,
/// since the rest names host paths and object addresses.
///
/// The Character properties the listing parser reads — `Character.isNumber`,
/// `isLetter` and `isNewline`, and `CharacterSet.whitespaces` — are recorded
/// for every scalar beside the cases, and
/// `rust/crates/arkdeck-hoststore/src/crash_ledger.rs` is compared with them.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CRASH_LEDGER_RECORD=/private/tmp/<new file>.json`; otherwise
/// the checked-in oracle must match.
final class CrashLedgerAnalyzerOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    var arguments = ["--analyze-crash-ledger", "{input}"]
    var input: Data?
    var inputMode: mode_t = 0o600
  }

  fileprivate struct Oracle: Codable, Equatable {
    struct Recorded: Codable, Equatable {
      let name: String
      /// `{input}` is the listing's path, `{inputVolume}` its `/.vol` alias
      /// (the form the Runtime passes), `{directory}` the directory holding
      /// it and `{missing}` a path in that directory that does not exist.
      let arguments: [String]
      /// Base64 of the listing's bytes, when the case writes one.
      let input: String?
      let inputMode: Int?
      let exitStatus: Int32
      let stdout: String
      let stderr: String
      /// The stderr recorded is only a prefix of what was written.
      let stderrIsPrefix: Bool
    }
    let schemaVersion: String
    let cases: [Recorded]
    /// Each property as closed scalar ranges, `[first, last]`.
    let properties: [String: [[UInt32]]]
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/crash-ledger-analyzer/oracle.json")
  private static let schemaVersion = "arkdeck.crash-ledger-analyzer-oracle/1"
  private static let failurePrefix = "crash-ledger analysis failed: "

  private var productsDirectory: URL {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
      return bundle.bundleURL.deletingLastPathComponent()
    }
    return Bundle.main.bundleURL
  }

  func testSwiftAnswersTheSharedCrashLedgerOracle() throws {
    let recorded = try oracleOfThisBuild()
    if let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_CRASH_LEDGER_RECORD"] {
      guard output.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: output)
      else { throw CocoaError(.fileWriteFileExists) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      var bytes = try encoder.encode(recorded)
      bytes.append(0x0A)
      try bytes.write(to: URL(filePath: output))
      return
    }
    let expected = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: Self.oracle))
    XCTAssertEqual(expected.schemaVersion, recorded.schemaVersion)
    XCTAssertEqual(expected.cases.map(\.name), recorded.cases.map(\.name))
    for (expected, actual) in zip(expected.cases, recorded.cases) {
      XCTAssertEqual(expected, actual, expected.name)
    }
    XCTAssertEqual(expected.properties, recorded.properties)
  }

  // MARK: - The recording

  private func oracleOfThisBuild() throws -> Oracle {
    let executable = productsDirectory.appending(path: "arkdeck-agentd")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let manager = FileManager.default
    let root = URL(
      filePath: "/private/tmp/arkdeck-crash-ledger-oracle-\(UUID().uuidString.prefix(12))",
      directoryHint: .isDirectory)
    try manager.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    var recorded: [Oracle.Recorded] = []
    for (index, testCase) in Self.cases.enumerated() {
      let directory = root.appending(path: "case-\(index)", directoryHint: .isDirectory)
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let input = directory.appending(path: "crash-index.txt")
      var volume = ""
      if let bytes = testCase.input {
        try bytes.write(to: input)
        var status = stat()
        guard stat(input.path, &status) == 0 else { throw POSIXError(.ENOENT) }
        volume = "/.vol/\(status.st_dev)/\(status.st_ino)"
        guard chmod(input.path, testCase.inputMode) == 0 else { throw POSIXError(.EPERM) }
      }
      let missing = directory.appending(path: "absent.txt")
      let arguments = testCase.arguments.map {
        $0.replacingOccurrences(of: "{inputVolume}", with: volume)
          .replacingOccurrences(of: "{input}", with: input.path)
          .replacingOccurrences(of: "{directory}", with: directory.path)
          .replacingOccurrences(of: "{missing}", with: missing.path)
      }
      let (status, stdout, stderr) = try run(
        executable, arguments, outputs: root.appending(path: "case-\(index)"))
      _ = chmod(input.path, 0o600)
      let text = try XCTUnwrap(String(data: stdout, encoding: .utf8), testCase.name)
      XCTAssertEqual(Data(text.utf8), stdout, testCase.name)
      var error = String(decoding: stderr, as: UTF8.self)
      let failed = status == 1
      if failed {
        XCTAssertTrue(error.hasPrefix(Self.failurePrefix), "\(testCase.name): \(error)")
        XCTAssertTrue(error.hasSuffix("\n"), testCase.name)
        XCTAssertTrue(stdout.isEmpty, testCase.name)
        error = Self.failurePrefix
      }
      if status == 0, let bytes = testCase.input {
        // The mode is the analyzer function over the file's bytes.
        XCTAssertEqual(
          try HarnessCrashLedgerDerivedAnalyzer.analyze(bytes), stdout, testCase.name)
      }
      recorded.append(
        Oracle.Recorded(
          name: testCase.name, arguments: testCase.arguments,
          input: testCase.input?.base64EncodedString(),
          inputMode: testCase.input.map { _ in Int(testCase.inputMode) },
          exitStatus: status, stdout: text, stderr: error, stderrIsPrefix: failed))
    }
    return Oracle(
      schemaVersion: Self.schemaVersion, cases: recorded,
      properties: [
        "isLetter": Self.ranges { Character($0).isLetter },
        "isNewline": Self.ranges { Character($0).isNewline },
        "isNumber": Self.ranges { Character($0).isNumber },
        "whitespaces": Self.ranges { CharacterSet.whitespaces.contains($0) },
      ])
  }

  /// The executable with no environment and no stdin, both outputs to files.
  private func run(
    _ executable: URL, _ arguments: [String], outputs prefix: URL
  ) throws -> (Int32, Data, Data) {
    let stdoutURL = URL(filePath: prefix.path + ".stdout")
    let stderrURL = URL(filePath: prefix.path + ".stderr")
    for url in [stdoutURL, stderrURL] {
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = [:]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    try stdout.close()
    try stderr.close()
    XCTAssertEqual(process.terminationReason, .exit, arguments.joined(separator: " "))
    return (
      process.terminationStatus, try Data(contentsOf: stdoutURL), try Data(contentsOf: stderrURL)
    )
  }

  private static func ranges(_ holds: (Unicode.Scalar) -> Bool) -> [[UInt32]] {
    var ranges: [[UInt32]] = []
    for value in UInt32(0)...0x10_FFFF {
      guard let scalar = Unicode.Scalar(value), holds(scalar) else { continue }
      if let last = ranges.last, last[1] + 1 == value {
        ranges[ranges.count - 1][1] = value
      } else {
        ranges.append([value, value])
      }
    }
    return ranges
  }

  // MARK: - The cases

  private static func text(_ value: String) -> Data { Data(value.utf8) }

  /// A listing of `lines`, each ended by `terminator`, fenced and headed as
  /// the device prints it.
  private static func listing(_ lines: [String], terminator: String = "\n") -> Data {
    text((["Fault log list:", "******"] + lines + ["******"]).map { $0 + terminator }.joined())
  }

  private static func entry(_ name: String) -> Data { listing([name]) }

  private static let bom = Data([0xEF, 0xBB, 0xBF])

  private static let cases: [Case] = [
    // The arguments, as Swift checks them before anything is read.
    Case(name: "usage-no-path", arguments: ["--analyze-crash-ledger"]),
    Case(
      name: "usage-two-paths", arguments: ["--analyze-crash-ledger", "{input}", "{input}"],
      input: entry("cppcrash-com.example-1-20260101000000")),
    Case(
      name: "usage-relative-path", arguments: ["--analyze-crash-ledger", "crash-index.txt"]),
    Case(name: "usage-empty-path", arguments: ["--analyze-crash-ledger", ""]),
    Case(
      name: "usage-combining-mark-on-the-slash",
      arguments: ["--analyze-crash-ledger", "/\u{301}private/tmp/crash-index.txt"]),
    Case(
      name: "usage-prepended-mark-before-the-slash",
      arguments: ["--analyze-crash-ledger", "\u{600}/private/tmp/crash-index.txt"]),
    // Paths that cannot be read.
    Case(name: "read-missing-file", arguments: ["--analyze-crash-ledger", "{missing}"]),
    Case(name: "read-directory", arguments: ["--analyze-crash-ledger", "{directory}"]),
    Case(name: "read-root", arguments: ["--analyze-crash-ledger", "/"]),
    Case(
      name: "read-unreadable-file", input: entry("cppcrash-com.example-1-20260101000000"),
      inputMode: 0o000),
    Case(
      name: "read-dot-after-a-file", arguments: ["--analyze-crash-ledger", "{input}/."],
      input: entry("cppcrash-com.example-1-20260101000000")),
    // Path spellings that read the listing.
    Case(
      name: "path-volume-alias", arguments: ["--analyze-crash-ledger", "{inputVolume}"],
      input: entry("cppcrash-com.example.demo-20010039-20260914000000")),
    Case(
      name: "path-trailing-slash", arguments: ["--analyze-crash-ledger", "{input}/"],
      input: entry("cppcrash-com.example-1-20260101000000")),
    Case(
      name: "path-trailing-slashes", arguments: ["--analyze-crash-ledger", "{input}///"],
      input: entry("cppcrash-com.example-1-20260101000000")),
    Case(
      name: "path-dot-segments",
      arguments: ["--analyze-crash-ledger", "{directory}/.//crash-index.txt"],
      input: entry("cppcrash-com.example-1-20260101000000")),
    // The listing's frame.
    Case(name: "empty-file", input: Data()),
    Case(name: "no-header", input: text("Faultlog list\n******\n******\n")),
    Case(name: "header-in-another-case", input: text("fault log list:\n******\n******\n")),
    Case(name: "header-only", input: text("Fault log list:\n")),
    Case(name: "header-and-one-fence", input: text("Fault log list:\n******\n")),
    Case(
      name: "header-one-fence-and-the-empty-marker",
      input: text("Fault log list:\n******\nNo fault log exist.\n")),
    Case(
      name: "empty-marker-without-fences", input: text("Fault log list:\nNo fault log exist.\n")),
    Case(
      name: "measured-empty-ledger",
      input: text("\nFault log list:\n******\n******\nNo fault log exist.\n")),
    Case(
      name: "runtime-fixture-source", input: text("answered\nFault log list:\n******\n")),
    Case(
      name: "header-after-the-fences",
      input: text("******\ncppcrash-com.example-1-20260101000000\n******\nFault log list:\n")),
    Case(
      name: "header-inside-a-line",
      input: text(
        "== Fault log list: ==\n******\ncppcrash-com.example-1-20260101000000\n******\n")),
    Case(
      name: "text-around-the-listing",
      input: text(
        "hilog noise\nFault log list:\n******\ncppcrash-com.example-1-20260101000000\n"
          + "******\ntrailing text\nmore-trailing-text\n")),
    Case(
      name: "fences-win-over-the-empty-marker",
      input: text(
        "Fault log list:\nNo fault log exist.\n******\ncppcrash-com.example-1-20260101000000\n"
          + "******\n")),
    Case(
      name: "a-fence-between-entries",
      input: listing([
        "cppcrash-com.example-1-20260101000000", "******",
        "jscrash-com.example-2-20260101000001",
      ])),
    Case(
      name: "near-fences",
      input: text(
        "Fault log list:\n*****\ncppcrash-com.example-1-20260101000000\n*******\n** ****\n")),
    Case(
      name: "header-with-a-combining-mark",
      input: text("Fault log list:\u{301}\n******\n******\n")),
    Case(
      name: "header-after-a-prepended-mark",
      input: text("\u{600}Fault log list:\n******\n******\n")),
    Case(
      name: "empty-marker-joined-by-zwj",
      input: text("Fault log list:\nNo fault log exist.\u{200D}\n")),
    // Entries.
    Case(
      name: "one-native-crash", input: entry("cppcrash-com.example.demo-20010039-20260914000000")),
    Case(
      name: "measured-kinds",
      input: listing([
        "jscrash-com.example.waterflow-20010042-20260731162134",
        "cppcrash-com.ohos.sceneboard-20010016-20260731081502",
        "appfreeze-com.example.my-app-20010043-20260801093000",
      ])),
    Case(
      name: "crlf-lines",
      input: listing(
        [
          "jscrash-com.example.waterflow-20010042-20260731162134",
          "cppcrash-com.ohos.sceneboard-20010016-20260731081502",
        ], terminator: "\r\n")),
    Case(
      name: "cr-lines",
      input: listing(
        [
          "jscrash-com.example.waterflow-20010042-20260731162134",
          "cppcrash-com.ohos.sceneboard-20010016-20260731081502",
        ], terminator: "\r")),
    Case(
      name: "unicode-line-separators",
      input: text(
        "Fault log list:\u{85}******\u{2028}cppcrash-com.example-1-20260101000000\u{2029}"
          + "jscrash-com.example-2-20260101000001\u{0B}appfreeze-com.example-3-20260101000002"
          + "\u{0C}******")),
    Case(
      name: "blank-lines-between-the-fences",
      input: listing([
        "", "   ", "\t", "\u{3000}", "cppcrash-com.example-1-20260101000000", "\u{A0}",
      ])),
    Case(
      name: "padded-lines",
      input: text(
        "  Fault log list:  \n \t******\u{A0}\n"
          + "\u{1680}cppcrash-com.example-1-20260101000000\u{2000}\n"
          + "\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
          + "jscrash-com.example-2-20260101000001\u{200B}\n\u{202F}appfreeze-com.example-3-"
          + "20260101000002\u{205F}\u{3000}\n\t******\t\n")),
    Case(
      name: "unicode-format-characters-are-not-trimmed",
      input: entry("cppcrash-com.example-1-20260101000000\u{FEFF}")),
    Case(name: "three-fields", input: entry("cppcrash-com.example-20260101000000")),
    Case(name: "timestamp-thirteen-digits", input: entry("cppcrash-com.example-1-2026010100000")),
    Case(name: "timestamp-fifteen-digits", input: entry("cppcrash-com.example-1-202601010000000")),
    Case(name: "timestamp-with-a-letter", input: entry("cppcrash-com.example-1-2026010100000a")),
    Case(name: "uid-empty", input: entry("cppcrash-com.example--20260101000000")),
    Case(name: "uid-with-a-letter", input: entry("cppcrash-com.example-2001a-20260101000000")),
    Case(name: "kind-with-a-digit", input: entry("cpp2crash-com.example-1-20260101000000")),
    Case(name: "kind-empty", input: entry("-com.example-1-20260101000000")),
    Case(name: "bundle-empty", input: entry("cppcrash--1-20260101000000")),
    Case(
      name: "bundle-with-hyphens",
      input: entry("cppcrash-com.example.my-long-app-20010039-20260914000000")),
    Case(name: "bundle-of-hyphens", input: entry("cppcrash----1-20260101000000")),
    Case(
      name: "a-line-of-nul",
      input: Data("Fault log list:\n******\n".utf8) + Data([0x00]) + Data("\n******\n".utf8)),
    Case(
      name: "json-escapes-in-the-bundle",
      input: entry(
        "cppcrash-a\"b\\c/d\u{0}e\u{1}f\u{8}g\u{1B}h\u{1F}i\u{7F}j\tk\u{2FFF}l-1-20260101000000")),
    Case(
      name: "many-entries",
      input: listing(
        (0..<100).map { index in
          "jscrash-com.example.app\(index % 7)-\(20_010_000 + index)-"
            + "202609\(String(format: "%08d", index))"
        })),
    // Text encoding.
    Case(
      name: "invalid-utf8",
      input: Data("Fault log list:\n******\n".utf8) + Data([0xFF])
        + Data("\n******\n".utf8)),
    Case(
      name: "surrogate-encoding",
      input: Data("Fault log list:\n******\n".utf8) + Data([0xED, 0xA0, 0x80])
        + Data("\n******\n".utf8)),
    Case(
      name: "byte-order-mark-then-a-fence",
      input: bom
        + text("******\ncppcrash-com.example-1-20260101000000\n******\nFault log list:\n")),
    Case(
      name: "two-byte-order-marks-then-a-fence",
      input: bom + bom
        + text("******\ncppcrash-com.example-1-20260101000000\n******\nFault log list:\n")),
    Case(name: "byte-order-mark-then-invalid-utf8", input: bom + Data([0xFF])),
    // Unicode in the entry name, as Character properties judge it.
    Case(
      name: "arabic-indic-digits",
      input: entry(
        "jscrash-com.example-\u{662}\u{660}\u{660}\u{661}-\u{662}\u{660}\u{662}\u{666}"
          + "\u{660}\u{667}\u{663}\u{661}\u{661}\u{666}\u{662}\u{661}\u{663}\u{664}")),
    Case(
      name: "fullwidth-digits",
      input: entry(
        "jscrash-com.example-\u{FF12}\u{FF10}-\u{FF12}\u{FF10}\u{FF12}\u{FF16}\u{FF10}"
          + "\u{FF17}\u{FF13}\u{FF11}\u{FF11}\u{FF16}\u{FF12}\u{FF11}\u{FF13}\u{FF14}")),
    Case(
      name: "han-numerals-in-the-uid",
      input: entry("jscrash-com.example-\u{4E00}\u{4E8C}\u{4E09}-20260101000000")),
    Case(
      name: "fractions-and-superscripts-in-the-uid",
      input: entry("jscrash-com.example-\u{BD}\u{B2}-20260101000000")),
    Case(
      name: "kind-in-katakana",
      input: entry("\u{30AF}\u{30E9}\u{30C3}\u{30B7}\u{30E5}-com.example-1-20260101000000")),
    Case(
      name: "kind-of-private-use-letters",
      input: entry("\u{F8C1}crash-com.example-1-20260101000000")),
    Case(
      name: "kind-with-a-combining-mark",
      input: entry("cpp\u{301}crash-com.example-1-20260101000000")),
    Case(
      name: "kind-starting-with-a-combining-mark",
      input: entry("\u{301}cppcrash-com.example-1-20260101000000")),
    Case(
      name: "kind-with-an-indic-conjunct",
      input: entry("\u{915}\u{94D}\u{937}\u{924}\u{94D}\u{930}-com.example-1-20260101000000")),
    Case(
      name: "timestamp-with-combining-marks",
      input: entry("cppcrash-com.example-1-2\u{301}0260101000000")),
    Case(
      name: "timestamp-starting-with-a-combining-mark",
      input: entry("cppcrash-com.example-1-\u{301}0260101000000")),
    Case(
      name: "hyphen-with-a-combining-mark",
      input: entry("cppcrash-com.a-\u{301}b-1-20260101000000")),
    Case(
      name: "hyphen-after-a-prepended-mark",
      input: entry("cppcrash\u{600}-com.example-1-20260101000000")),
    Case(
      name: "kind-ending-in-a-prepended-letter",
      input: entry("crash\u{D4E}-com.example-1-20260101000000")),
    Case(
      name: "bundle-ending-in-a-prepended-letter",
      input: entry("cppcrash-com.example\u{D4E}-1-20260101000000")),
    Case(
      name: "emoji-in-the-bundle",
      input: entry("cppcrash-com.\u{1F9D1}\u{200D}\u{1F4BB}.app-1-20260101000000")),
    Case(
      name: "regional-indicators-in-the-bundle",
      input: entry("cppcrash-com.\u{1F1E8}\u{1F1F3}\u{1F1E8}-1-20260101000000")),
    // The probe `arkdeck runtime service update` sends before it points
    // `ARKDECK_ANALYZER_PATH` at a Rust daemon.
    Case(
      name: "runtime-service-probe", arguments: ["--analyze-crash-ledger", "{inputVolume}"],
      input: listing(["jscrash-com.example.my-app-20010039-20260924000000"], terminator: "\r\n")),
  ]
}
