import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore

/// What Swift's CLI does for `runtime support-bundle preview|export`,
/// recorded for the Rust CLI to replay
/// (`rust/crates/arkdeck-cli/tests/support_bundle.rs`).
///
/// The real `arkdeck` process runs each argv in a private temporary root. The
/// record is each run's exit status, stdout and stderr, and — for the export
/// that publishes — every file of the bundle, its bytes and its mode. The
/// scope digest binds the destination's parent directory by device and inode,
/// which no replay on another host can reproduce, so the oracle also records
/// the parent's identity the digest was taken over: a replay derives Swift's
/// digest from it and the recorded entries, and compares the formula rather
/// than the value. `bundle.json` carries the time it was generated; the replay
/// compares everything else in it.
///
/// The temporary root is labelled `<root>` (and `<private-root>` in its
/// `/private` spelling).
///
/// Record a new oracle with
/// `ARKDECK_RUST_SUPPORT_BUNDLE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match, but for the generation time
/// and the host facts it names.
final class CLISupportBundleOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/support-bundle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_SUPPORT_BUNDLE_RECORD"

  private struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runCLI(_ arguments: [String]) throws -> CLIRun {
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
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

  func testSwiftSupportBundleTheRustCLIReplays() throws {
    let name = "arkdeck-sb-\(UUID().uuidString.prefix(8).lowercased())"
    let privateRoot = "/private/tmp/\(name)"
    let root = "/tmp/\(name)"
    try FileManager.default.createDirectory(
      atPath: privateRoot, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: privateRoot) }
    try FileManager.default.createDirectory(
      atPath: "\(privateRoot)/writable", withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    chmod("\(privateRoot)/writable", 0o770)
    func label(_ text: String) -> String {
      text.replacingOccurrences(of: privateRoot, with: "<private-root>")
        .replacingOccurrences(of: root, with: "<root>")
    }

    var runs: [JSONValue] = []
    func run(_ name: String, _ arguments: [String]) throws -> CLIRun {
      let result = try runCLI(arguments)
      runs.append(
        .object([
          "name": .string(name), "argv": .array(arguments.map { .string(label($0)) }),
          "exit": .integer(Int64(result.exitCode)), "stdout": .string(label(result.stdout)),
          "stderr": .string(label(result.stderr)),
        ]))
      return result
    }
    let destination = "\(root)/support"
    let preview = try run(
      "previewJson",
      [
        "runtime", "support-bundle", "preview", "--destination", destination, "--output", "json",
        "--control-request-id", "ctl-support-preview",
      ])
    let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(preview.stdout.utf8))
    guard case .object(let fields) = envelope, case .object(let result)? = fields["result"],
      case .string(let digest)? = result["scopeSHA256"]
    else { return XCTFail("preview answered no digest: \(preview.stdout)") }
    _ = try run("previewLegacy", ["runtime", "support-bundle", "preview", "--destination", destination, "--json"])
    _ = try run("previewHuman", ["runtime", "support-bundle", "preview", "--destination", destination])
    _ = try run(
      "exportWrongDigest",
      [
        "runtime", "support-bundle", "export", "--destination", destination, "--preview-digest",
        String(repeating: "0", count: 64), "--output", "json",
        "--control-request-id", "ctl-support-wrong",
      ])
    _ = try run(
      "exportElsewhere",
      [
        "runtime", "support-bundle", "export", "--destination", "\(root)/elsewhere",
        "--preview-digest", digest, "--output", "json", "--control-request-id", "ctl-support-else",
      ])
    _ = try run(
      "export",
      [
        "runtime", "support-bundle", "export", "--destination", destination, "--preview-digest",
        digest, "--output", "json", "--control-request-id", "ctl-support-export",
      ])
    var files: [JSONValue] = []
    let enumerator = FileManager.default.enumerator(atPath: "\(privateRoot)/support")
    var paths: [String] = [""]
    while let path = enumerator?.nextObject() as? String { paths.append(path) }
    for path in paths.sorted() {
      let full = path.isEmpty ? "\(privateRoot)/support" : "\(privateRoot)/support/\(path)"
      var metadata = stat()
      XCTAssertEqual(lstat(full, &metadata), 0, full)
      let directory = metadata.st_mode & S_IFMT == S_IFDIR
      var file: [String: JSONValue] = [
        "path": .string(path), "mode": .integer(Int64(metadata.st_mode & 0o7777)),
        "kind": .string(directory ? "directory" : "file"),
      ]
      if !directory {
        file["text"] = .string(
          label(String(decoding: try Data(contentsOf: URL(filePath: full)), as: UTF8.self)))
      }
      files.append(.object(file))
    }
    _ = try run(
      "exportAgain",
      [
        "runtime", "support-bundle", "export", "--destination", destination, "--preview-digest",
        digest, "--output", "json", "--control-request-id", "ctl-support-again",
      ])
    _ = try run(
      "previewExisting",
      [
        "runtime", "support-bundle", "preview", "--destination", destination, "--output", "json",
        "--control-request-id", "ctl-support-existing",
      ])
    for (name, candidate) in [
      ("previewRelative", "support"),
      ("previewPrivateSpelling", "\(privateRoot)/support-2"),
      ("previewTrailingSlash", "\(root)/support-3/"),
      ("previewDotDot", "\(root)/writable/../support-4"),
      ("previewMissingParent", "\(root)/missing/support"),
      ("previewWritableParent", "\(root)/writable/support"),
      ("previewRootItself", "/"),
    ] {
      _ = try run(
        name,
        [
          "runtime", "support-bundle", "preview", "--destination", candidate, "--output", "json",
          "--control-request-id", "ctl-support-\(name)",
        ])
    }

    // What the digest was taken over: the destination's parent, as the
    // writer opened it.
    var parent = stat()
    XCTAssertEqual(stat(root, &parent), 0)
    let host = ProcessInfo.processInfo.operatingSystemVersion
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var output: [String: Data] = [:]
    output["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "runs": .array(runs), "exportedFiles": .array(files),
          "digest": .object([
            "value": .string(digest), "destination": .string(label(destination)),
            "parentDevice": .integer(Int64(parent.st_dev)),
            "parentInode": .integer(Int64(parent.st_ino)),
          ]),
          "host": .object([
            "platform": .string(
              "macOS \(host.majorVersion).\(host.minorVersion).\(host.patchVersion)"),
            "architecture": .string("arm64"),
          ]),
        ])) + Data("\n".utf8)
    output["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLISupportBundleOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.runRuntimeSupportBundle"),
            .string("RuntimeSupportBundleApplicationFacade"), .string("LocalDiagnosticBundle"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompareSupportBundle(
      output, variable: Self.recordVariable, oracle: Self.oracle)
  }
}

extension HDCOracleHarness {
  /// `recordOrCompare`, except that a comparison ignores what differs between
  /// runs and hosts by nature: the generation time in `bundle.json`, the
  /// digest and the identity of the temporary parent it binds, and the host's
  /// platform version.
  static func recordOrCompareSupportBundle(
    _ files: [String: Data], variable: String, oracle: URL
  ) throws {
    if ProcessInfo.processInfo.environment[variable] != nil {
      try recordOrCompare(files, variable: variable, oracle: oracle)
      return
    }
    func stable(_ data: Data) -> String {
      var text = String(decoding: data, as: UTF8.self)
      for pattern in [
        #""generatedAt\\" ?: ?\\"[^"\\]*\\""#, #"[0-9a-f]{64}"#,
        #""parent(Device|Inode)" : [0-9]+"#, #"macOS [0-9]+\.[0-9]+\.[0-9]+"#,
      ] {
        text = text.replacingOccurrences(of: pattern, with: "<varies>", options: .regularExpression)
      }
      return text
    }
    for (path, data) in files {
      let expected = try Data(contentsOf: oracle.appending(path: path))
      XCTAssertEqual(stable(expected), stable(data), path)
    }
  }
}
