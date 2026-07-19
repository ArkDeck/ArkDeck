import ArkDeckOpenHarmony
import ArkDeckProcess
import CryptoKit
import Foundation
import XCTest

/// TEST-INT-UD-GOLDEN-001: the M0B HiDumper streams are packaged byte-exactly, retain their
/// controlled-human-capture provenance/privacy boundary, and match the integration registry.
final class HiDumperGoldenResourceContractTests: XCTestCase {
  private struct GoldenRegistry: Decodable {
    let schemaVersion: String
    let packVersion: String
    let integrationProfile: String
    let registeredBy: String
    let provenance: Provenance
    let entries: [Entry]

    struct Provenance: Decodable {
      let evidenceID: String
      let evidenceClass: String
      let captureDate: String
      let captureBoundary: String
      let redactedManifestPath: String
      let redactedManifestSHA256: String
      let hdcSHA256: String
      let selfCheckPassed: Bool
      let serialPresent: Bool
      let userPathFound: Bool
      let keyMaterialFound: Bool
    }

    struct Entry: Decodable {
      let id: String
      let commandID: String
      let remoteArgv: [String]
      let path: String
      let stream: String
      let exitCode: Int32
      let expectedSemanticClassification: String
      let sha256: String
      let sizeBytes: Int
      let evidenceClass: String
    }
  }

  func testGoldenPackContainsExactlyRegisteredBytePinnedStreams() throws {
    let registry = try loadRegistry()
    let root = try goldenRoot()
    XCTAssertEqual(registry.entries.count, 4)
    XCTAssertEqual(Set(registry.entries.map(\.id)).count, registry.entries.count)

    var packagedFiles: Set<String> = []
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    )
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      packagedFiles.insert(
        url.path.replacingOccurrences(of: root.path + "/", with: "")
      )
    }
    XCTAssertEqual(
      packagedFiles,
      Set(registry.entries.map(\.path)).union(["1.0.0/registry.json"])
    )

    for entry in registry.entries {
      let bytes = try Data(contentsOf: root.appending(path: entry.path))
      XCTAssertEqual(bytes.count, entry.sizeBytes, entry.id)
      XCTAssertEqual(sha256Hex(bytes), entry.sha256, entry.id)
      XCTAssertEqual(entry.exitCode, 0, entry.id)
      XCTAssertEqual(entry.evidenceClass, "controlledHumanCapture", entry.id)
    }
  }

  func testProvenanceAndPrivacyBoundaryMatchM0BEvidence() throws {
    let registry = try loadRegistry()
    let root = try goldenRoot()
    XCTAssertEqual(registry.schemaVersion, "1.0.0")
    XCTAssertEqual(registry.packVersion, "1.0.0")
    XCTAssertEqual(registry.integrationProfile, "OPENHARMONY-TOOLS@0.3.0")
    XCTAssertEqual(
      registry.registeredBy,
      "CHG-2026-008-ui-dump-hidumper-wrapper/TASK-UD-001"
    )
    XCTAssertEqual(registry.provenance.evidenceID, "EVD-M0B-DAYU200-20260718-001")
    XCTAssertEqual(registry.provenance.evidenceClass, "controlledHumanCapture")
    XCTAssertEqual(registry.provenance.captureDate, "2026-07-18")
    XCTAssertTrue(registry.provenance.captureBoundary.contains("not a compatibility"))
    XCTAssertEqual(
      registry.provenance.redactedManifestPath,
      "openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/redacted-manifests/hidumper.redacted-manifest.json"
    )
    XCTAssertEqual(
      registry.provenance.redactedManifestSHA256,
      "14e0ce82eaccbd92b8755417104f8c0a57a8aa313db4566d19db3d5a83f1811f"
    )
    XCTAssertEqual(
      registry.provenance.hdcSHA256,
      "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260"
    )
    XCTAssertTrue(registry.provenance.selfCheckPassed)
    XCTAssertFalse(registry.provenance.serialPresent)
    XCTAssertFalse(registry.provenance.userPathFound)
    XCTAssertFalse(registry.provenance.keyMaterialFound)

    let forbiddenByteStrings = ["/Users/", "hdckey", "PRIVATE KEY", "<connectkey>"]
    for entry in registry.entries {
      let bytes = try Data(contentsOf: root.appending(path: entry.path))
      let text = String(decoding: bytes, as: UTF8.self)
      for forbidden in forbiddenByteStrings {
        XCTAssertFalse(text.contains(forbidden), "\(entry.id) contains \(forbidden)")
      }
    }
  }

  func testGoldenStreamsDriveOnlyTheirRegisteredSemanticFamily() throws {
    let registry = try loadRegistry()
    let byID = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.id, $0) })

    let helpStdout = try XCTUnwrap(byID["hidumper-golden-help-stdout"])
    let helpStderr = try XCTUnwrap(byID["hidumper-golden-help-stderr"])
    XCTAssertEqual(helpStdout.remoteArgv, ["hidumper", "--help"])
    XCTAssertEqual(helpStdout.expectedSemanticClassification, "failure.explicitFailureMarker")
    XCTAssertEqual(helpStderr.expectedSemanticClassification, "empty")
    var helpParser = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    helpParser.consume(try chunk(for: helpStdout))
    helpParser.consume(try chunk(for: helpStderr))
    XCTAssertEqual(
      helpParser.finish(exitCode: helpStdout.exitCode), .failure(.explicitFailureMarker))

    let servicesStdout = try XCTUnwrap(byID["hidumper-golden-services-stdout"])
    let servicesStderr = try XCTUnwrap(byID["hidumper-golden-services-stderr"])
    XCTAssertEqual(servicesStdout.remoteArgv, ["hidumper", "-ls"])
    XCTAssertEqual(
      servicesStdout.expectedSemanticClassification,
      "success.systemAbilityList"
    )
    XCTAssertEqual(servicesStderr.expectedSemanticClassification, "empty")
    var servicesParser = HiDumperSemanticOutputParser(outputFamily: .systemAbilityList)
    servicesParser.consume(try chunk(for: servicesStdout))
    servicesParser.consume(try chunk(for: servicesStderr))
    XCTAssertEqual(servicesParser.finish(exitCode: servicesStdout.exitCode), .success)

    var unregisteredParser = HiDumperSemanticOutputParser(outputFamily: .unregistered)
    unregisteredParser.consume(try chunk(for: servicesStdout))
    unregisteredParser.consume(try chunk(for: servicesStderr))
    XCTAssertEqual(unregisteredParser.finish(exitCode: servicesStdout.exitCode), .unknownOutput)
  }

  func testProfileLockBundleAndGitAttributesUseTheSamePack() throws {
    let registry = try loadRegistry()
    let profile = try String(
      contentsOf: repoRoot.appending(path: "openspec/integrations/openharmony/profile.md"),
      encoding: .utf8
    )
    let lock = try String(
      contentsOf: repoRoot.appending(
        path: "openspec/integrations/INTEGRATION-PROFILES.lock.yaml"),
      encoding: .utf8
    )
    let attributes = try String(
      contentsOf: repoRoot.appending(path: ".gitattributes"),
      encoding: .utf8
    )

    XCTAssertTrue(profile.contains("Version：0.3.0"))
    XCTAssertTrue(profile.contains("HiDumper/Golden/1.0.0"))
    XCTAssertTrue(lock.contains("lock: INTEGRATION-PROFILES-0.4.0"))
    XCTAssertTrue(lock.contains("version: 0.3.0"))
    XCTAssertTrue(
      attributes.contains(
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/**/*.bin binary"
      )
    )

    for entry in registry.entries {
      XCTAssertTrue(profile.contains("`\(entry.id)`"), entry.id)
      XCTAssertTrue(lock.contains("id: \(entry.id)"), entry.id)
      XCTAssertTrue(
        lock.contains(
          "path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/\(entry.path)"
        ), entry.id)
      XCTAssertTrue(lock.contains("sha256: \(entry.sha256)"), entry.id)
    }
  }

  private func goldenRoot() throws -> URL {
    try XCTUnwrap(Bundle.module.resourceURL)
      .appending(path: "HiDumper/Golden", directoryHint: .isDirectory)
  }

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var repoRoot: URL {
    packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func loadRegistry() throws -> GoldenRegistry {
    try JSONDecoder().decode(
      GoldenRegistry.self,
      from: Data(contentsOf: try goldenRoot().appending(path: "1.0.0/registry.json"))
    )
  }

  private func chunk(for entry: GoldenRegistry.Entry) throws -> ProcessOutputChunk {
    let stream: ProcessStream = entry.stream == "stdout" ? .stdout : .stderr
    return ProcessOutputChunk(
      stream: stream,
      bytes: try Data(contentsOf: goldenRoot().appending(path: entry.path))
    )
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
