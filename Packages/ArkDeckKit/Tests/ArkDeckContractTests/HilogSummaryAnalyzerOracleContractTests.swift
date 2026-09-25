// Shared Swift oracle for the Rust daemon's `--summarize-hilog` mode
// (CHG-2026-074, TASK-XPA-015).

import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Swift's one-shot HiLog summary analyzer as the Runtime runs it: the built
/// `arkdeck-agentd` with an empty environment and no stdin, over a file
/// written to a private directory first. The Rust daemon replays every case
/// (`rust/crates/arkdeck-agentd/tests/hilog_summary_analyzer.rs`) and must
/// answer with the same exit status, stdout and stderr byte for byte.
///
/// The cases cover the argument rule, the bounded physical reader
/// (`ArkTraceProfileFileReader.read` with the kernel inode alias allowed), and
/// the summary itself: blank and header lines, every part of the header
/// pattern at and past its bounds, ICU's end anchor before a final line
/// terminator, the 256-byte prefix and a character cut by it, and how
/// ill-formed UTF-8 is replaced in a tag whose length is bounded.
///
/// Record a new oracle with
/// `ARKDECK_RUST_HILOG_SUMMARY_RECORD=/private/tmp/<new file>.json`; otherwise
/// the checked-in oracle must match.
final class HilogSummaryAnalyzerOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    var arguments = ["--summarize-hilog", "{inputVolume}"]
    var input: Data?
    var inputMode: mode_t = 0o600
    /// A symbolic link `link.txt` to the input, and a FIFO `fifo`.
    var extras = false
  }

  fileprivate struct Oracle: Codable, Equatable {
    struct Recorded: Codable, Equatable {
      let name: String
      /// `{input}` is the file's path, `{inputVolume}` its `/.vol` alias (the
      /// form the Runtime passes), `{device}`/`{inode}` the alias's parts,
      /// `{directory}` the directory holding it, `{directoryDevice}`/
      /// `{directoryInode}` that directory's, `{missing}` a path in it that
      /// does not exist, `{link}` a symbolic link to the input, `{fifo}` a
      /// FIFO beside it, and `{inputViaTmp}` the input's path through the
      /// `/tmp` link.
      let arguments: [String]
      /// Base64 of the file's bytes, when the case writes one.
      let input: String?
      let inputMode: Int?
      let extras: Bool
      let exitStatus: Int32
      let stdout: String
      let stderr: String
    }
    let schemaVersion: String
    let cases: [Recorded]
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/hilog-summary-analyzer/oracle.json")
  private static let schemaVersion = "arkdeck.hilog-summary-analyzer-oracle/1"

  private var productsDirectory: URL {
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
      return bundle.bundleURL.deletingLastPathComponent()
    }
    return Bundle.main.bundleURL
  }

  func testSwiftAnswersTheSharedHilogSummaryOracle() throws {
    let recorded = try oracleOfThisBuild()
    if let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_HILOG_SUMMARY_RECORD"] {
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
  }

  // MARK: - The recording

  private func oracleOfThisBuild() throws -> Oracle {
    let executable = productsDirectory.appending(path: "arkdeck-agentd")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let manager = FileManager.default
    let root = URL(
      filePath: "/private/tmp/arkdeck-hilog-summary-oracle-\(UUID().uuidString.prefix(12))",
      directoryHint: .isDirectory)
    try manager.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    var recorded: [Oracle.Recorded] = []
    XCTAssertEqual(Set(Self.cases.map(\.name)).count, Self.cases.count)
    for (index, testCase) in Self.cases.enumerated() {
      let directory = root.appending(path: "case-\(index)", directoryHint: .isDirectory)
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let input = directory.appending(path: "hilog.txt")
      var device = ""
      var inode = ""
      if let bytes = testCase.input {
        try bytes.write(to: input)
        var status = stat()
        guard stat(input.path, &status) == 0 else { throw POSIXError(.ENOENT) }
        device = String(UInt32(bitPattern: status.st_dev))
        inode = String(status.st_ino)
        guard chmod(input.path, testCase.inputMode) == 0 else { throw POSIXError(.EPERM) }
      }
      var directoryStatus = stat()
      guard stat(directory.path, &directoryStatus) == 0 else { throw POSIXError(.ENOENT) }
      if testCase.extras {
        guard symlink("hilog.txt", directory.appending(path: "link.txt").path) == 0,
          mkfifo(directory.appending(path: "fifo").path, 0o600) == 0
        else { throw POSIXError(.EEXIST) }
      }
      let substitutions = [
        ("{inputVolume}", "/.vol/\(device)/\(inode)"),
        ("{inputViaTmp}", String(input.path.dropFirst("/private".count))),
        ("{input}", input.path),
        ("{device}", device),
        ("{inode}", inode),
        ("{directoryDevice}", String(UInt32(bitPattern: directoryStatus.st_dev))),
        ("{directoryInode}", String(directoryStatus.st_ino)),
        ("{directory}", directory.path),
        ("{missing}", directory.appending(path: "absent.txt").path),
        ("{link}", directory.appending(path: "link.txt").path),
        ("{fifo}", directory.appending(path: "fifo").path),
      ]
      let arguments = testCase.arguments.map { argument in
        substitutions.reduce(argument) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
      }
      let (status, stdout, stderr) = try run(
        executable, arguments, outputs: root.appending(path: "case-\(index)"))
      _ = chmod(input.path, 0o600)
      let text = try XCTUnwrap(String(data: stdout, encoding: .utf8), testCase.name)
      XCTAssertEqual(Data(text.utf8), stdout, testCase.name)
      let error = try XCTUnwrap(String(data: stderr, encoding: .utf8), testCase.name)
      if status == 0, let bytes = testCase.input {
        // The mode is the analyzer function over the file's bytes.
        XCTAssertEqual(try HilogSummaryDerivedAnalyzer.analyze(bytes), stdout, testCase.name)
        XCTAssertTrue(error.isEmpty, testCase.name)
      }
      recorded.append(
        Oracle.Recorded(
          name: testCase.name, arguments: testCase.arguments,
          input: testCase.input?.base64EncodedString(),
          inputMode: testCase.input.map { _ in Int(testCase.inputMode) },
          extras: testCase.extras, exitStatus: status, stdout: text, stderr: error))
    }
    return Oracle(schemaVersion: Self.schemaVersion, cases: recorded)
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

  // MARK: - The cases

  private static func text(_ value: String) -> Data { Data(value.utf8) }

  private static func bytes(_ parts: Data...) -> Data {
    parts.reduce(Data(), +)
  }

  /// A header line with every part as given: the default one is valid.
  private static func header(
    date: String = "09-25", time: String = "10:00:00.123", pid: String = "1234",
    tid: String = "5678", level: String = "I", domain: String = "C02D01", tag: String = "HiLog",
    gap: String = " ", after: String = " body text"
  ) -> String {
    "\(date)\(gap)\(time)\(gap)\(pid)\(gap)\(tid)\(gap)\(level)\(gap)\(domain)/\(tag):\(after)"
  }

  private static func lines(_ values: [String]) -> Data {
    text(values.map { $0 + "\n" }.joined())
  }

  /// A 31-character tag bound: `ascii` ASCII letters, then `raw` bytes.
  private static func boundedTag(ascii: Int, raw: [UInt8]) -> Data {
    bytes(
      text("09-25 10:00:00.123 1 2 W 0000F/" + String(repeating: "t", count: ascii)), Data(raw),
      text(": x\n"))
  }

  /// `09-25 10:00:00.123`, `spaces` spaces, then `rest`: the spaces place
  /// `rest` at a chosen byte.
  private static func padded(_ spaces: Int, _ rest: String) -> String {
    "09-25 10:00:00.123" + String(repeating: " ", count: spaces) + rest
  }

  private static let cases: [Case] = [
    // The arguments, as Swift checks them before anything is read.
    Case(name: "usage-no-path", arguments: ["--summarize-hilog"]),
    Case(
      name: "usage-two-paths", arguments: ["--summarize-hilog", "{input}", "{input}"],
      input: lines([header()])),
    Case(name: "usage-relative-path", arguments: ["--summarize-hilog", "hilog.txt"]),
    Case(name: "usage-empty-path", arguments: ["--summarize-hilog", ""]),
    Case(
      name: "usage-combining-mark-on-the-slash",
      arguments: ["--summarize-hilog", "/\u{301}private/tmp/hilog.txt"]),
    Case(
      name: "usage-prepended-mark-before-the-slash",
      arguments: ["--summarize-hilog", "\u{600}/private/tmp/hilog.txt"]),
    // Paths the bounded physical reader refuses.
    Case(name: "read-missing-file", arguments: ["--summarize-hilog", "{missing}"]),
    Case(name: "read-directory", arguments: ["--summarize-hilog", "{directory}"]),
    Case(name: "read-root", arguments: ["--summarize-hilog", "/"]),
    Case(
      name: "read-unreadable-file", arguments: ["--summarize-hilog", "{input}"],
      input: lines([header()]), inputMode: 0o000),
    Case(
      name: "read-symbolic-link", arguments: ["--summarize-hilog", "{link}"],
      input: lines([header()]), extras: true),
    Case(
      name: "read-fifo", arguments: ["--summarize-hilog", "{fifo}"], input: lines([header()]),
      extras: true),
    Case(
      name: "read-through-the-tmp-link", arguments: ["--summarize-hilog", "{inputViaTmp}"],
      input: lines([header()])),
    Case(
      name: "read-dot-component", arguments: ["--summarize-hilog", "{directory}/./hilog.txt"],
      input: lines([header()])),
    Case(
      name: "read-dot-dot-component",
      arguments: ["--summarize-hilog", "{directory}/../case-0/hilog.txt"],
      input: lines([header()])),
    Case(
      name: "read-dot-after-a-file", arguments: ["--summarize-hilog", "{input}/."],
      input: lines([header()])),
    Case(
      name: "read-volume-directory",
      arguments: ["--summarize-hilog", "/.vol/{directoryDevice}/{directoryInode}"]),
    Case(
      name: "read-volume-signed-device", arguments: ["--summarize-hilog", "/.vol/+{device}/{inode}"],
      input: lines([header()])),
    Case(
      name: "read-volume-leading-zero", arguments: ["--summarize-hilog", "/.vol/{device}/0{inode}"],
      input: lines([header()])),
    Case(
      name: "read-volume-zero-inode", arguments: ["--summarize-hilog", "/.vol/{device}/0"],
      input: lines([header()])),
    Case(
      name: "read-volume-extra-part", arguments: ["--summarize-hilog", "{inputVolume}/x"],
      input: lines([header()])),
    Case(
      name: "read-volume-missing-inode",
      arguments: ["--summarize-hilog", "/.vol/{device}/18446744073709551615"],
      input: lines([header()])),
    Case(
      name: "read-volume-device-overflow",
      arguments: ["--summarize-hilog", "/.vol/4294967296/{inode}"], input: lines([header()])),
    // Path spellings that read the file.
    Case(
      name: "path-component-walk", arguments: ["--summarize-hilog", "{input}"],
      input: lines([header()])),
    Case(
      name: "path-trailing-slash", arguments: ["--summarize-hilog", "{input}/"],
      input: lines([header()])),
    Case(
      name: "path-doubled-slashes", arguments: ["--summarize-hilog", "{directory}//hilog.txt"],
      input: lines([header()])),
    Case(name: "path-volume-alias", input: lines([header(level: "W")])),
    // Line cutting and blank lines.
    Case(name: "empty-file", input: Data()),
    Case(name: "one-line-feed", input: text("\n")),
    Case(name: "blank-lines", input: text(" \t\r\n\n  \n\r\n")),
    Case(name: "blank-final-line-without-feed", input: text(header() + "\n \t")),
    Case(name: "header-without-final-feed", input: text(header())),
    Case(name: "vertical-tab-line-is-not-blank", input: text("\u{0B}\n\u{0C}\n")),
    Case(name: "crlf-lines", input: text([header(), header(level: "E")].map { $0 + "\r\n" }.joined())),
    Case(name: "lone-carriage-returns", input: text(header() + "\r\r\n" + header() + "\r\r\r\n")),
    Case(name: "carriage-return-inside-the-header", input: lines([header(gap: "\r")])),
    // Every severity, and ones that are not.
    Case(
      name: "each-level",
      input: lines(["D", "I", "W", "E", "F"].map { header(level: $0) })),
    Case(
      name: "other-levels",
      input: lines(["d", "V", "A", "DI", "FATAL"].map { header(level: $0) })),
    // The date and time.
    Case(
      name: "date-bounds",
      input: lines(
        ["01-01", "12-31", "00-01", "13-01", "01-00", "01-32", "02-30", "1-01", "01-1", "10-10"]
          .map { header(date: $0) })),
    Case(
      name: "time-bounds",
      input: lines(
        [
          "00:00:00.000", "23:59:59.999", "24:00:00.000", "19:60:00.000", "19:00:60.000",
          "29:00:00.000", "9:00:00.000", "19:0:00.000",
        ].map { header(time: $0) })),
    Case(
      name: "fraction-digits",
      input: lines(
        [
          "10:00:00.1", "10:00:00.12", "10:00:00.123", "10:00:00.1234", "10:00:00.123456",
          "10:00:00.1234567", "10:00:00.123456789", "10:00:00.1234567890", "10:00:00",
          "10:00:00,123",
        ].map { header(time: $0) })),
    // Process and thread IDs.
    Case(
      name: "id-bounds",
      input: lines(
        [
          header(pid: "1"), header(pid: "1234567890"), header(pid: "12345678901"),
          header(tid: "0"), header(tid: "12345678901"), header(pid: ""), header(pid: "-1"),
          header(pid: "\u{FF11}"),
        ])),
    // The gaps between the parts.
    Case(
      name: "gaps",
      input: lines(
        [
          header(gap: "\t"), header(gap: "  \t "), header(gap: ""), header(gap: "\u{A0}"),
          " " + header(), "\t" + header(),
        ])),
    // The domain.
    Case(
      name: "domain-forms",
      input: lines(
        [
          "0000F", "12345678", "1234", "123456789", "A1234", "A12345678", "Z12345678",
          "G0000F", "g0000F", "ZZ1234", "0x1234", "ABCDEF", "abcdef", "C02D01X", "",
        ].map { header(domain: $0) })),
    // The tag, and what closes it.
    Case(
      name: "tag-lengths",
      input: lines(
        [1, 30, 31, 32, 40].map { header(tag: String(repeating: "a", count: $0)) }
          + [header(tag: "")])),
    Case(
      name: "tag-characters",
      input: lines(
        [
          header(tag: "t\u{7F}g"), header(tag: "t\u{1B}g"), header(tag: "t\u{00}g"),
          header(tag: "t\u{85}g"), header(tag: "中文标签"), header(tag: "a:b"),
          header(tag: String(repeating: "\u{1D11E}", count: 31)),
          header(tag: String(repeating: "\u{1D11E}", count: 32)),
          header(tag: String(repeating: "\u{1F1E8}\u{1F1F3}", count: 15) + "x"),
          header(tag: String(repeating: "\u{1F1E8}\u{1F1F3}", count: 16)),
          header(tag: "e\u{301}" + String(repeating: "a", count: 29)),
          header(tag: "e\u{301}" + String(repeating: "a", count: 30)),
        ])),
    Case(
      name: "tag-closings",
      input: lines(
        [
          header(after: ""), header(after: "\t"), header(after: "x"), header(after: "x: y"),
          header(after: "x:y"), header(after: ":"), header(after: "\u{0B}"),
          header(after: "\u{0C}"), header(after: "\u{85}"), header(after: "\u{2028}"),
          header(after: "\u{2029}"), header(after: "\u{85}\u{85}"), header(after: "\u{2028}x"),
          header(after: "\r\u{0B}"), header(after: "\u{3000}"), header(after: "\u{A0}"),
        ])),
    Case(
      name: "tag-closed-before-one-carriage-return",
      input: text(header(after: "") + "\r\n" + header(after: "") + "\r\r\n")),
    Case(
      name: "tag-closed-before-carriage-returns",
      input: text(header(after: "") + "\r\r\r\n" + header(after: "\u{0B}") + "\r\n")),
    // The first 256 bytes.
    Case(
      name: "long-line-body",
      input: lines([header(after: " " + String(repeating: "b", count: 4000))])),
    Case(
      name: "header-past-256-bytes",
      input: lines([header(gap: String(repeating: " ", count: 60))])),
    // 18 + 216 + 22 bytes: the colon is the 256th.
    Case(
      name: "colon-at-byte-256", input: lines([padded(216, "1 2 I 0000F/tagtagtag: body")])),
    // The carriage return is the 256th byte, dropped as the last one kept.
    Case(
      name: "carriage-return-at-byte-256",
      input: lines([padded(215, "1 2 I 0000F/tagtagtag:\rx")])),
    // The colon is the 255th byte and a two-byte character is cut by the 256th.
    Case(
      name: "character-cut-at-byte-256",
      input: lines([padded(215, "1 2 I 0000F/tagtagtag:\u{E9}")])),
    // The colon is the 257th byte.
    Case(
      name: "tag-cut-at-byte-256", input: lines([padded(214, "1 2 I 0000F/tagtagtagtag: x")])),
    // Ill-formed UTF-8, replaced before the pattern reads it: the tag's
    // 31-character bound tells how many replacement characters each gave.
    Case(name: "ill-formed-bytes-in-the-tag", input: illFormedTags()),
    Case(
      name: "ill-formed-bytes-elsewhere",
      input: bytes(
        Data([0xFF]), text(header() + "\n" + header(after: " ")), Data([0xFF, 0x00, 0xC3]),
        text("\n"))),
    Case(
      name: "byte-order-mark-first", input: bytes(Data([0xEF, 0xBB, 0xBF]), text(header() + "\n"))
    ),
    Case(
      name: "nul-in-the-body",
      input: bytes(text(header(after: " a")), Data([0x00]), text("b\n"))),
    // Whole documents.
    Case(
      name: "mixed-document",
      input: lines([
        header(level: "D"), "", "   ", "continuation of the previous entry", header(level: "E"),
        "--------- beginning of main", header(level: "F", domain: "D003F00", tag: "Ability"),
      ])),
    Case(
      name: "all-unrecognized", input: lines(["no header here", "nor here", "  x", "09-25"])),
    Case(name: "many-lines", input: manyLines()),
  ]

  /// Tags of ASCII letters and ill-formed bytes, each pair of lengths one
  /// side of the 31-character bound once the bytes are replaced.
  private static func illFormedTags() -> Data {
    let tags: [(Int, [UInt8])] = [
      (30, [0xFF]), (29, [0xFF, 0xFE]), (30, [0xFF, 0xFE]), (30, [0xE2, 0x82]),
      (29, [0xC0, 0x80]), (30, [0xC0, 0x80]), (28, [0xED, 0xA0, 0x80]),
      (29, [0xED, 0xA0, 0x80]), (27, [0xF4, 0x90, 0x80, 0x80]), (28, [0xF4, 0x90, 0x80, 0x80]),
      (30, [0xF0, 0x9F, 0x98]), (28, [0xE0, 0x80, 0x80]), (29, [0xE0, 0x80, 0x80]),
      (30, [0x80]), (29, [0xF8, 0x88]), (30, [0xF8, 0x88]),
    ]
    var data = Data()
    for (ascii, raw) in tags {
      data.append(boundedTag(ascii: ascii, raw: raw))
    }
    return data
  }

  /// Three thousand lines, every seventh one without a header.
  private static func manyLines() -> Data {
    let levels = ["D", "I", "W", "E", "F"]
    var values: [String] = []
    for index in 0..<3000 {
      if index % 7 == 0 {
        values.append("noise \(index)")
      } else {
        values.append(header(pid: String(index), level: levels[index % 5]))
      }
    }
    return lines(values)
  }
}
