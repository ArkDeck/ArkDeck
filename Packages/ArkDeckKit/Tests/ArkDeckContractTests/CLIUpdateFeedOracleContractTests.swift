import Foundation
import XCTest

@testable import ArkDeckCore

/// What Swift's CLI does for `maintainer update-feed prepare|assemble` and
/// the deprecated `update-feed` spelling, recorded for the Rust CLI to replay
/// (`rust/crates/arkdeck-cli/tests/update_feed.rs`).
///
/// The real `arkdeck` process runs each argv in a private temporary root.
/// The record is each run's exit status, stdout and stderr, and every file
/// `prepare` wrote. No production signing key is available here (the CLI
/// never holds one), so `assemble` is recorded refusing: a signature of the
/// wrong length, a well-formed signature the production key did not make,
/// and inputs it cannot read. The prepared payload and signature input are
/// deterministic, so they are compared byte for byte.
///
/// The temporary root is labelled `<root>`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_UPDATE_FEED_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIUpdateFeedOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/update-feed", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_UPDATE_FEED_RECORD"

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

  func testSwiftUpdateFeedTheRustCLIReplays() throws {
    let root = "/private/tmp/arkdeck-uf-\(UUID().uuidString.prefix(8).lowercased())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let artifact = "\(root)/ArkDeck-1.2.3.dmg"
    try Data("arkdeck release artifact bytes\n".utf8).write(to: URL(filePath: artifact))
    let empty = "\(root)/empty.dmg"
    try Data().write(to: URL(filePath: empty))
    // These leaves take no correlation identity: each envelope's generated one
    // is recorded and compared as `ctl-<uuid>`.
    func label(_ text: String) -> String {
      text.replacingOccurrences(of: root, with: "<root>")
        .replacingOccurrences(
          of: #"ctl-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
          with: "ctl-<uuid>", options: .regularExpression)
    }

    var runs: [JSONValue] = []
    @discardableResult
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
    let url = "https://github.com/ArkDeck/ArkDeck/releases/download/v1.2.3/ArkDeck-1.2.3.dmg"
    func prepare(
      _ name: String, out: String, spelling: [String] = ["maintainer", "update-feed"],
      overriding: [String: String] = [:], mode: [String] = []
    ) throws {
      var values: [(String, String)] = [
        ("--sequence", "7"), ("--version", "1.2.3"), ("--minimum-system", "14.0"),
        ("--issued-at", "2026-09-01T00:00:00Z"), ("--expires-at", "2026-09-30T00:00:00Z"),
        ("--artifact", artifact), ("--artifact-url", url), ("--notes", "Fixes and é notes"),
        ("--out", "\(root)/\(out)"),
      ]
      values = values.map { flag, value in (flag, overriding[flag] ?? value) }
      try run(name, spelling + ["prepare"] + values.flatMap { [$0.0, $0.1] } + mode)
    }
    try prepare("prepareJson", out: "json", mode: ["--output", "json"])
    try prepare("prepareHuman", out: "human")
    try prepare("prepareDeprecatedJson", out: "deprecated", spelling: ["update-feed"], mode: ["--output", "json"])
    try prepare("prepareDeprecatedHuman", out: "deprecated-human", spelling: ["update-feed"])
    for (name, flag, value) in [
      ("sequenceZero", "--sequence", "0"),
      ("versionTwoParts", "--version", "1.2"),
      ("versionLeadingZero", "--version", "1.02.3"),
      ("systemTooOld", "--minimum-system", "13.6"),
      ("systemThreeParts", "--minimum-system", "14.1.2"),
      ("issuedFractional", "--issued-at", "2026-09-01T00:00:00.000Z"),
      ("issuedOffset", "--issued-at", "2026-09-01T00:00:00+00:00"),
      ("windowTooLong", "--expires-at", "2026-10-02T00:00:00Z"),
      ("windowReversed", "--expires-at", "2026-08-31T00:00:00Z"),
      ("httpURL", "--artifact-url", "http://github.com/ArkDeck/ArkDeck.dmg"),
      ("hostNotAllowed", "--artifact-url", "https://example.com/ArkDeck.dmg"),
      ("hostUppercase", "--artifact-url", "https://GitHub.com/ArkDeck/ArkDeck.dmg"),
      ("ipHost", "--artifact-url", "https://140.82.112.3/ArkDeck.dmg"),
      ("portURL", "--artifact-url", "https://github.com:443/ArkDeck/ArkDeck.dmg"),
      ("fragmentURL", "--artifact-url", "https://github.com/ArkDeck/ArkDeck.dmg#x"),
      ("notDmg", "--artifact-url", "https://github.com/ArkDeck/ArkDeck.zip"),
      ("queryURL", "--artifact-url", "https://github.com/ArkDeck/ArkDeck.dmg?x=1"),
      ("notesDecomposed", "--notes", "e\u{301}"),
      ("notesTooLong", "--notes", String(repeating: "n", count: 4 * 1_024 + 1)),
      ("artifactMissing", "--artifact", "\(root)/missing.dmg"),
      ("artifactEmpty", "--artifact", empty),
    ] {
      try prepare(name, out: "out-\(name)", overriding: [flag: value], mode: ["--output", "json"])
    }
    try run(
      "prepareMissingOption",
      ["maintainer", "update-feed", "prepare", "--sequence", "1", "--output", "json"])

    // The files `prepare` wrote, byte for byte (base64), and their modes.
    var files: [JSONValue] = []
    for directory in ["json", "human", "deprecated"] {
      for name in ["arkdeck-update-payload-v1.json", "arkdeck-update-signature-input-v1.bin"] {
        let path = "\(root)/\(directory)/\(name)"
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        files.append(
          .object([
            "path": .string("\(directory)/\(name)"),
            "base64": .string(try Data(contentsOf: URL(filePath: path)).base64EncodedString()),
            "mode": .integer(Int64((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)),
          ]))
      }
      let directoryMode =
        (try FileManager.default.attributesOfItem(atPath: "\(root)/\(directory)")[
          .posixPermissions] as? NSNumber)?.intValue ?? -1
      files.append(.object(["path": .string(directory), "mode": .integer(Int64(directoryMode))]))
    }

    let payload = "\(root)/json/arkdeck-update-payload-v1.json"
    let shortSignature = "\(root)/short.sig"
    try Data(repeating: 1, count: 63).write(to: URL(filePath: shortSignature))
    let forgedSignature = "\(root)/forged.sig"
    try Data(repeating: 7, count: 64).write(to: URL(filePath: forgedSignature))
    for (name, arguments) in [
      ("assembleShortSignature", ["--payload", payload, "--signature", shortSignature]),
      ("assembleForgedSignature", ["--payload", payload, "--signature", forgedSignature]),
      ("assembleMissingPayload", ["--payload", "\(root)/missing.json", "--signature", forgedSignature]),
      ("assembleMissingSignature", ["--payload", payload, "--signature", "\(root)/missing.sig"]),
    ] {
      try run(
        name,
        ["maintainer", "update-feed", "assemble"] + arguments
          + ["--out", "\(root)/feed-\(name).json", "--output", "json"])
    }
    try run(
      "assembleForgedHuman",
      ["update-feed", "assemble", "--payload", payload, "--signature", forgedSignature, "--out",
       "\(root)/feed-human.json"])
    let written = (try? FileManager.default.contentsOfDirectory(atPath: root))?
      .filter { $0.hasPrefix("feed-") } ?? []
    XCTAssertEqual(written, [], "no feed is written when it does not verify")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var output: [String: Data] = [:]
    output["cases.json"] =
      try encoder.encode(JSONValue.object(["runs": .array(runs), "files": .array(files)]))
      + Data("\n".utf8)
    output["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIUpdateFeedOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.prepareUpdateFeed"), .string("RuntimeCLI.assembleUpdateFeed"),
            .string("UpdateFeedCodec"), .string("UpdateFeedVerifier"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(output, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
