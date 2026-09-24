// Shared Swift oracle for the Rust Runtime's reading of a DAYU200 flash bundle
// (CHG-2026-074, TASK-XPA-017, milestone M4).

import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift's production flash-bundle Import policy
/// (`FlashBundleImportPolicy.production`) reads a bundle in three steps, and
/// this oracle records each step's answer for every synthetic archive in
/// `rust/tests/fixtures/flash-archive/archives` (written by
/// `make-archives.py` there):
///
/// - `GzipTarArchiveReader.summarize` with the board's `derivationRequest`:
///   the archive's size and digest, every regular member's name, size and
///   digest, the partition table it kept and the version it scanned;
/// - `RockchipImageArchiveIntrospection.describe`: the declared partitions
///   and each member's classification;
/// - `RockchipFlashProfile.forBuild`: the board carrying the build's facts;
///
/// and the policy's own answer. A step that throws is recorded as Swift
/// interpolates the error, the archives' directory spelled `<archives>`. No
/// daemon, device or engine is involved.
///
/// Record a new oracle with
/// `ARKDECK_RUST_FLASH_ARCHIVE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class FlashBundleArchiveOracleContractTests: XCTestCase {
  private static let fixtures: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appending(
      path: "rust/tests/fixtures/flash-archive", directoryHint: .isDirectory)
  }()
  private static let archives = fixtures.appending(path: "archives", directoryHint: .isDirectory)
  private static let oracle = fixtures.appending(path: "oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_FLASH_ARCHIVE_RECORD"

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func failure(_ error: Error) -> JSONValue {
    .object([
      "error": .string(
        "\(error)".replacingOccurrences(
          of: archives.path, with: "<archives>"))
    ])
  }

  private static func summary(_ summary: GzipTarArchiveSummary) -> JSONValue {
    .object([
      "archiveSizeBytes": .integer(summary.archiveSizeBytes),
      "archiveSha256": .string(summary.archiveSHA256),
      "members": .array(
        summary.members.map {
          .object([
            "name": .string($0.name), "sizeBytes": .integer($0.sizeBytes),
            "sha256": .string($0.sha256),
          ])
        }),
      "captured": .object(
        summary.capturedMembers.mapValues {
          .object(["byteCount": .integer(Int64($0.count)), "sha256": .string(digest($0))])
        }),
      "scannedValue": summary.scannedValue.map(JSONValue.string) ?? .null,
    ])
  }

  private static func build(_ build: RockchipImageBuildDescriptor) -> JSONValue {
    .object([
      "archiveSizeBytes": .integer(build.archiveSizeBytes),
      "archiveSha256": .string(build.archiveSHA256),
      "runtimeBuildVersion": .string(build.runtimeBuildVersion),
      "declaredPartitions": .array(
        build.declaredPartitions.map {
          .object([
            "name": .string($0.name), "sizeSectors": .integer($0.sizeSectors),
            "offsetSectors": .integer($0.offsetSectors),
          ])
        }),
      "members": .array(
        build.members.map {
          .object(["name": .string($0.name), "classification": .string($0.classification.rawValue)])
        }),
    ])
  }

  private static func profile(_ profile: RockchipFlashProfile) -> JSONValue {
    .object([
      "archiveSizeBytes": .integer(profile.archiveSizeBytes),
      "archiveSha256": .string(profile.archiveSHA256),
      "firmwareVersion": .string(profile.firmwareVersion),
      "runtimeBuildVersion": .string(profile.runtimeBuildVersion),
      "writeForbiddenMemberNames": .array(profile.writeForbiddenMemberNames.map(JSONValue.string)),
    ])
  }

  func testSwiftReadsEveryFlashBundleAsTheRustRuntimeReplays() throws {
    let board = RockchipFlashProfile.dayu200
    let policy = try XCTUnwrap(FlashBundleImportPolicy.production.candidates.first)
    let names = try FileManager.default.contentsOfDirectory(atPath: Self.archives.path)
      .filter { !$0.hasPrefix(".") }.sorted()
    XCTAssertEqual(names.count, 41)
    var cases: [JSONValue] = []
    for name in names {
      let url = Self.archives.appending(path: name)
      var recorded: [String: JSONValue] = ["archive": .string(name)]
      var summary: GzipTarArchiveSummary?
      do {
        summary = try GzipTarArchiveReader.summarize(
          fileAt: url,
          derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
        recorded["summary"] = Self.summary(summary!)
      } catch {
        recorded["summary"] = Self.failure(error)
      }
      var build: RockchipImageBuildDescriptor?
      if let summary {
        do {
          build = try RockchipImageArchiveIntrospection.describe(summary: summary, board: board)
          recorded["build"] = Self.build(build!)
        } catch {
          recorded["build"] = Self.failure(error)
        }
      } else {
        recorded["build"] = .null
      }
      if let build {
        do {
          recorded["profile"] = Self.profile(try board.forBuild(build))
        } catch {
          recorded["profile"] = Self.failure(error)
        }
      } else {
        recorded["profile"] = .null
      }
      do {
        let validation = try policy.validate(url)
        recorded["importPolicy"] = .object([
          "byteCount": .integer(Int64(validation.byteCount)),
          "sha256": .string(validation.sha256),
        ])
      } catch {
        recorded["importPolicy"] = Self.failure(error)
      }
      cases.append(.object(recorded))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["cases": .array(cases)])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("FlashBundleArchiveOracleContractTests"),
          "archives": .string("rust/tests/fixtures/flash-archive/archives"),
          "steps": .array([
            .string("GzipTarArchiveReader.summarize"),
            .string("RockchipImageArchiveIntrospection.describe"),
            .string("RockchipFlashProfile.forBuild"),
            .string("FlashBundleImportPolicy.production"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
