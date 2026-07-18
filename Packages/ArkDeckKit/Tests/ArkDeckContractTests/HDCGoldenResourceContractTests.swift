import ArkDeckOpenHarmony
import ArkDeckProcess
import CryptoKit
import Foundation
import XCTest

/// TASK-I5-001 (CHG-2026-005): the versioned HDC golden fixture pack must be locatable through
/// `Bundle.module` alone (no `#filePath`, no repository-checkout relative paths), must contain
/// exactly the registered fixture set, and every fixture's bytes must match its pinned SHA-256.
/// The tests also pin the byte-level lineage of the M0A failure candidates and the semantic
/// classification of every registered fixture under the current (pre-M1-006) parser.
final class HDCGoldenResourceContractTests: XCTestCase {
  private struct GoldenRegistry: Decodable {
    let schemaVersion: String
    let packVersion: String
    let integrationProfile: String
    let registeredBy: String
    let entries: [Entry]

    struct Entry: Decodable {
      let id: String
      let family: String
      let path: String
      let stream: String
      let exitCode: Int32
      let expectedSemanticClassification: String
      let currentParserClassification: String?
      let sha256: String
      let sizeBytes: Int
      let evidenceClass: String
      let sourceLineage: String
    }
  }

  private func goldenRoot() throws -> URL {
    try XCTUnwrap(
      Bundle.module.url(forResource: "Golden", withExtension: nil),
      "Golden resource tree must be packaged via the SwiftPM .copy declaration")
  }

  private func loadRegistry() throws -> GoldenRegistry {
    let registryURL = try XCTUnwrap(
      Bundle.module.url(
        forResource: "registry", withExtension: "json", subdirectory: "Golden/1.0.0"),
      "Golden/1.0.0/registry.json must be locatable through Bundle.module")
    let registry = try JSONDecoder().decode(
      GoldenRegistry.self, from: Data(contentsOf: registryURL))
    XCTAssertEqual(registry.schemaVersion, "1.0.0")
    XCTAssertEqual(registry.packVersion, "1.0.0")
    XCTAssertEqual(registry.integrationProfile, "OPENHARMONY-TOOLS@0.2.0")
    return registry
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func testGoldenPackContainsExactRegisteredFixtureSetWithMatchingHashes() throws {
    let registry = try loadRegistry()
    XCTAssertEqual(registry.entries.count, 5)
    XCTAssertEqual(Set(registry.entries.map(\.id)).count, registry.entries.count)

    let root = try goldenRoot()
    var packagedFiles: Set<String> = []
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
      packagedFiles.insert(relative)
    }
    let expected = Set(registry.entries.map(\.path)).union(["1.0.0/registry.json"])
    XCTAssertEqual(
      packagedFiles, expected,
      "the packaged Golden tree must contain exactly the registered fixtures plus the registry")

    for entry in registry.entries {
      let url = root.appending(path: entry.path)
      let bytes = try Data(contentsOf: url)
      XCTAssertEqual(bytes.count, entry.sizeBytes, entry.id)
      XCTAssertEqual(sha256Hex(bytes), entry.sha256, entry.id)
      XCTAssertEqual(entry.stream, "stdout", entry.id)
      XCTAssertEqual(entry.exitCode, 0, entry.id)
      XCTAssertFalse(entry.sourceLineage.isEmpty, entry.id)
    }
  }

  func testFailureFixturesAreByteExactM0ACandidateExtractions() throws {
    let registry = try loadRegistry()
    let root = try goldenRoot()
    let byID = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.id, $0) })

    let unauthorized = try XCTUnwrap(byID["hdc-golden-failure-unauthorized"])
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: unauthorized.path)),
      HDCFixtures.exitZeroFailure,
      "failure-unauthorized must be the byte-exact M0A candidate")

    let offline = try XCTUnwrap(byID["hdc-golden-failure-offline"])
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: offline.path)),
      HDCFixtures.largeOutputFailureTail,
      "failure-offline must be the byte-exact M0A candidate")
  }

  func testRegisteredFixtureClassificationsUnderCurrentParserAreTruthful() throws {
    let registry = try loadRegistry()
    let root = try goldenRoot()

    func currentClassification(_ entry: GoldenRegistry.Entry) throws -> HDCCommandSemanticResult {
      var parser = HDCSemanticOutputParser()
      let bytes = try Data(contentsOf: root.appending(path: entry.path))
      parser.consume(ProcessOutputChunk(stream: .stdout, bytes: bytes))
      return parser.finish(exitCode: entry.exitCode)
    }

    for entry in registry.entries {
      switch entry.id {
      case "hdc-golden-failure-unauthorized":
        XCTAssertEqual(try currentClassification(entry), .failure(.unauthorized))
      case "hdc-golden-failure-offline":
        XCTAssertEqual(try currentClassification(entry), .failure(.offline))
      case "hdc-golden-success-uninstall":
        // Real hdc 3.2.0d success bytes do NOT contain the M0A `[success]` marker. The current
        // parser therefore reports `.unknownOutput` — pinned here so the registered
        // success-family mapping can only take effect through TASK-M1-006's profile-driven
        // parser adoption, never through a silent marker relaxation.
        XCTAssertEqual(entry.currentParserClassification, "unknownOutput")
        XCTAssertEqual(try currentClassification(entry), .unknownOutput)
        XCTAssertEqual(entry.expectedSemanticClassification, "success")
      case "hdc-golden-healthy-checkserver", "hdc-golden-version":
        // Probe-family outputs (not command-result outputs): the command parser must not
        // misclassify them as success or failure.
        XCTAssertEqual(try currentClassification(entry), .unknownOutput)
      default:
        XCTFail("unregistered fixture id: \(entry.id)")
      }
    }
  }
}
