import CryptoKit
import Foundation
import XCTest

/// Contract for the CHG-2026-024 device-observation registry (TASK-I24-001).
///
/// The registry is the deliverable; no production source is touched by this task. These tests
/// therefore prove three things about the registered data itself:
///
/// 1. the pack is closed and hash-exact (manifest ↔ files ↔ canonical registry copy);
/// 2. the registered grammar classifies every synthetic vector exactly as declared — including
///    the two forms of empty and every fail-closed negative;
/// 3. the sibling 1.0.0 read-only pack is byte-identical, so registering a second family grants
///    no authority to the first (CHG-2026-024 unblock prerequisite 6).
///
/// Every vector is synthetic. The capture-plan boundary forbids a captured byte from becoming a
/// repository fixture, so the connect keys are obvious placeholders at the measured 32-character
/// width and the byte totals reproduce the measured shapes (56 Offline / 58 Connected / 9 marker).
final class HDCDeviceObservationRegistryContractTests: XCTestCase {

  // MARK: - Decoded shapes

  private struct Registry: Decodable {
    struct ToolContext: Decodable {
      let platform: String
      let reportedVersion: String
      let executableSHA256: String
      let divergenceNote: String
    }
    struct Column: Decodable {
      let index: Int
      let name: String
      let closedSet: [String]?
      let observedLength: Int?
      let mayBeEmpty: Bool?
      let identifierBearing: Bool?
    }
    struct EmptyMarker: Decodable {
      let literal: String
      let observedTerminator: String
      let observedBytes: Int
      let tabFieldCount: Int
      let sufficiency: String
    }
    struct Row: Decodable {
      let delimiter: String
      let columnCount: Int
      let columns: [Column]
      let observedTerminator: String
      let observedBytes: [String: Int]
      let duplicateKeyDisposition: String
      let orderIsPresentationOnly: Bool
    }
    struct InputContract: Decodable {
      let stream: String
      let exitCode: Int
      let stderrMustBeEmpty: Bool
      let encoding: String
      let lineTerminators: [String]
      let residualCarriageReturnForbidden: Bool
      let emptyMarker: EmptyMarker
      let row: Row
    }
    struct Mapping: Decodable {
      let input: String
      let result: String
    }
    struct IdentityPolicy: Decodable {
      let rawIdentifiersLeaveAdapter: Bool
      let pseudonym: String
      let presentation: String
    }
    struct Provenance: Decodable {
      let evidenceClass: String
      let sourceChange: String
      let sourceEvidence: String
    }
    struct Entry: Decodable {
      let id: String
      let provenance: Provenance
      let family: String
      let status: String
      let toolReportedVersion: String
      let exactArgv: [String]
      let effectClassification: String
      let forbiddenEffects: [String]
      let inputContract: InputContract
      let semanticMappings: [Mapping]
      let presenceRule: String
      let identityPolicy: IdentityPolicy
    }
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let unknownFamilyDisposition: String
    let toolContext: ToolContext
    let entries: [Entry]
  }

  private struct Resources: Decodable {
    struct File: Decodable {
      let file: String
      let bytes: Int
      let sha256: String
    }
    struct Vector: Decodable {
      let id: String
      let file: String
      let bytes: Int
      let sha256: String
      let expectedOutcome: String
      let note: String
    }
    let packVersion: String
    let registryId: String
    let registryVersion: String
    let canonicalRegistryPath: String
    let registryCopy: File
    let controls: File
    let vectors: [Vector]
  }

  private struct Controls: Decodable {
    struct Case: Decodable {
      let id: String
      let input: String
      let expected: String
    }
    let cases: [Case]
  }

  // MARK: - Measured constants (CHG-2026-024 capture sessions, PR #656 / #658)

  private static let toolSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  private static let toolVersion = "3.2.0f"
  /// The sibling read-only pack must not shift by a byte (unblock prerequisite 6).
  private static let readOnlyPackRegistrySHA256 =
    "b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6"
  /// The only two placeholder keys any vector may contain.
  private static let placeholderKeys: Set<String> = [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2",
  ]

  // MARK: - Loading

  private func packURL() throws -> URL {
    let probes = try XCTUnwrap(
      Bundle.module.url(forResource: "Probes", withExtension: nil),
      "the Probes fixture directory must be copied into the test bundle")
    return probes.appending(path: "DeviceObservation/1.0.0", directoryHint: .isDirectory)
  }

  private func data(_ relative: String) throws -> Data {
    try Data(contentsOf: try packURL().appending(path: relative))
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func loadRegistry() throws -> Registry {
    try JSONDecoder().decode(Registry.self, from: try data("registry.yaml"))
  }

  private func loadResources() throws -> Resources {
    try JSONDecoder().decode(Resources.self, from: try data("resources.json"))
  }

  // MARK: - 1. Pack closure

  func testManifestAndFilesAgreeExactly() throws {
    let resources = try loadResources()
    let registryBytes = try data("registry.yaml")
    XCTAssertEqual(resources.registryCopy.sha256, digest(registryBytes))
    XCTAssertEqual(resources.registryCopy.bytes, registryBytes.count)

    let controlBytes = try data(resources.controls.file)
    XCTAssertEqual(resources.controls.sha256, digest(controlBytes))
    XCTAssertEqual(resources.controls.bytes, controlBytes.count)

    for vector in resources.vectors {
      let bytes = try data(vector.file)
      XCTAssertEqual(vector.sha256, digest(bytes), "\(vector.file) digest drift")
      XCTAssertEqual(vector.bytes, bytes.count, "\(vector.file) length drift")
    }
  }

  func testPackContainsExactlyTheManifestedFiles() throws {
    let root = try packURL()
    let listed = try FileManager.default
      .subpathsOfDirectory(atPath: root.path)
      .filter { !$0.hasSuffix(".gitattributes") }
      .filter {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(
          atPath: root.appending(path: $0).path, isDirectory: &isDir)
        return !isDir.boolValue
      }
    let resources = try loadResources()
    var expected = Set(resources.vectors.map(\.file))
    expected.insert(resources.registryCopy.file)
    expected.insert(resources.controls.file)
    expected.insert("resources.json")
    XCTAssertEqual(Set(listed), expected, "the pack must contain exactly its manifested files")
  }

  func testRegistryAndManifestIdentityAgree() throws {
    let registry = try loadRegistry()
    let resources = try loadResources()
    XCTAssertEqual(registry.registryId, resources.registryId)
    XCTAssertEqual(registry.registryVersion, resources.registryVersion)
    XCTAssertEqual(registry.registryId, "OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES")
    XCTAssertEqual(registry.integrationProfile, "OPENHARMONY-TOOLS@0.5.0")
    XCTAssertEqual(
      resources.canonicalRegistryPath,
      "openspec/integrations/openharmony/device-observation-probes.yaml")
  }

  // MARK: - 2. (D-2) tool identity must be carried, never merged with 3.2.0d

  func testToolIdentityIsPinnedAndCarriedInEveryEntryIdentifier() throws {
    let registry = try loadRegistry()
    XCTAssertEqual(registry.toolContext.reportedVersion, Self.toolVersion)
    XCTAssertEqual(registry.toolContext.executableSHA256, Self.toolSHA256)
    XCTAssertTrue(
      registry.toolContext.divergenceNote.contains("3.2.0d"),
      "the divergence from the sibling registries must be stated in the registry")
    for entry in registry.entries {
      XCTAssertEqual(entry.toolReportedVersion, Self.toolVersion)
      XCTAssertTrue(
        entry.id.contains(Self.toolVersion),
        "entry id \(entry.id) must carry the tool version (D-2 obligation)")
      XCTAssertFalse(
        entry.id.contains("3.2.0d"),
        "entry id \(entry.id) must not claim the sibling tool version")
    }
  }

  func testTheReadOnlySiblingPackIsByteIdentical() throws {
    let probes = try XCTUnwrap(Bundle.module.url(forResource: "Probes", withExtension: nil))
    let sibling = probes.appending(path: "1.0.0/registry.yaml")
    XCTAssertEqual(
      digest(try Data(contentsOf: sibling)), Self.readOnlyPackRegistrySHA256,
      "registering a second family must not disturb the 1.0.0 read-only pack")
  }

  // MARK: - 3. The registered grammar, exercised against every vector

  /// Reference classifier built strictly from the registry declaration. It exists to prove the
  /// declaration is complete and unambiguous; it is not production code.
  private enum Outcome: Equatable {
    case observedEmpty
    case observed(Int)
    case unknown
  }

  private func classify(_ bytes: Data, using entry: Registry.Entry) -> Outcome {
    let contract = entry.inputContract
    guard !bytes.isEmpty else { return .unknown }  // zero bytes is not the empty form
    guard let text = String(data: bytes, encoding: .utf8) else { return .unknown }

    // Split on LF, then strip exactly one trailing CR: both terminators are registered, and a
    // residual CR in any field is forbidden.
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() } else { return .unknown }  // must be terminated
    guard !lines.isEmpty else { return .unknown }

    var normalised: [String] = []
    for var line in lines {
      if line.hasSuffix("\r") { line.removeLast() }
      if line.contains("\r") { return .unknown }  // residualCarriageReturnForbidden
      normalised.append(line)
    }

    if normalised.count == 1 && normalised[0] == contract.emptyMarker.literal {
      return .observedEmpty
    }

    let columns = contract.row.columns
    var keys: Set<String> = []
    var connected = 0
    for line in normalised {
      let fields = line.components(separatedBy: "\t")
      guard fields.count == contract.row.columnCount else { return .unknown }
      for column in columns {
        let value = fields[column.index]
        if let closed = column.closedSet, !closed.contains(value) { return .unknown }
        if column.mayBeEmpty != true && column.closedSet == nil && value.isEmpty {
          return .unknown
        }
      }
      let key = fields[0]
      guard keys.insert(key).inserted else { return .unknown }  // duplicateKeyDisposition
      if fields[3] == "Connected" { connected += 1 }
    }
    return connected == 0 ? .observedEmpty : .observed(connected)
  }

  private func expected(_ declared: String) throws -> Outcome {
    switch declared {
    case "observedEmpty": return .observedEmpty
    case "unknown": return .unknown
    default:
      let parts = declared.components(separatedBy: ":")
      guard parts.count == 2, parts[0] == "observed", let count = Int(parts[1]) else {
        // An unrecognised registry value is a registry defect; skipping here
        // would let a typo silently drop the vector from coverage.
        XCTFail("unrecognised expectedOutcome \(declared)")
        struct UnrecognisedExpectedOutcome: Error {}
        throw UnrecognisedExpectedOutcome()
      }
      return .observed(count)
    }
  }

  func testEveryVectorClassifiesExactlyAsDeclared() throws {
    let entry = try XCTUnwrap(try loadRegistry().entries.first)
    let resources = try loadResources()
    XCTAssertGreaterThanOrEqual(
      resources.vectors.count, 12,
      "the vector set must keep covering the whole matrix")
    for vector in resources.vectors {
      let bytes = try data(vector.file)
      XCTAssertEqual(
        classify(bytes, using: entry), try expected(vector.expectedOutcome),
        "\(vector.file): \(vector.note)")
    }
  }

  /// The measured hazard: the marker ends CRLF while device rows end LF. A parser that splits on
  /// newline alone leaves a stray CR, and `[Empty]\r` must never read as empty.
  func testEmptyMarkerSurvivesItsCRLFAndOverToleranceIsRejected() throws {
    let entry = try XCTUnwrap(try loadRegistry().entries.first)
    let marker = try data("vectors/empty-marker.bin")
    XCTAssertEqual(marker.count, 9)
    XCTAssertEqual(Array(marker.suffix(2)), [0x0d, 0x0a], "the marker must stay CRLF-terminated")
    XCTAssertEqual(classify(marker, using: entry), .observedEmpty)

    // Negative: an extra CR is not the registered marker.
    XCTAssertEqual(classify(try data("vectors/marker-double-cr.bin"), using: entry), .unknown)

    // Negative: the naive split leaves a residual CR, which must not read as empty.
    let residual = Data("[Empty]\r".utf8)
    XCTAssertNotEqual(classify(residual, using: entry), .observedEmpty)
  }

  func testEmptyIsZeroConnectedRowsAndTheMarkerIsNotNecessary() throws {
    let entry = try XCTUnwrap(try loadRegistry().entries.first)
    // A server with history never emits the marker again; all-Offline rows are still empty.
    XCTAssertEqual(classify(try data("vectors/single-offline.bin"), using: entry), .observedEmpty)
    XCTAssertEqual(classify(try data("vectors/all-offline-two.bin"), using: entry), .observedEmpty)
    // Presence is decided by the state column, never by row count.
    XCTAssertEqual(
      classify(try data("vectors/mixed-connected-offline.bin"), using: entry),
      .observed(1))
    let mappings = Dictionary(
      uniqueKeysWithValues: entry.semanticMappings.map { ($0.input, $0.result) })
    XCTAssertEqual(mappings["rowsWithZeroConnected"], "observedEmpty")
    XCTAssertEqual(mappings["emptyMarkerLine"], "observedEmpty")
    XCTAssertTrue(entry.inputContract.emptyMarker.sufficiency.contains("NOT necessary"))
    XCTAssertTrue(entry.presenceRule.contains("never"))
  }

  func testRowOrderIsPresentationOnlyAndRepetitionIsStable() throws {
    let entry = try XCTUnwrap(try loadRegistry().entries.first)
    let two = try data("vectors/two-connected.bin")
    XCTAssertEqual(classify(two, using: entry), .observed(2))
    // Reversing the emitted order must not change the verdict.
    let reversed = Data(
      String(decoding: two, as: UTF8.self)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
        .reversed()
        .map { $0 + "\n" }
        .joined()
        .utf8)
    XCTAssertEqual(classify(reversed, using: entry), .observed(2))
    XCTAssertTrue(entry.inputContract.row.orderIsPresentationOnly)
    // Same bytes twice is the same verdict (stability).
    XCTAssertEqual(classify(two, using: entry), classify(two, using: entry))
  }

  func testMeasuredByteShapesAreCarriedByTheRegistry() throws {
    let row = try XCTUnwrap(try loadRegistry().entries.first).inputContract.row
    XCTAssertEqual(row.columnCount, 5)
    XCTAssertEqual(row.observedBytes["Offline"], 56)
    XCTAssertEqual(row.observedBytes["Connected"], 58)
    XCTAssertEqual(try data("vectors/single-offline.bin").count, 56)
    XCTAssertEqual(try data("vectors/single-connected.bin").count, 58)
    XCTAssertEqual(try data("vectors/two-connected.bin").count, 116)
    XCTAssertEqual(try data("vectors/mixed-connected-offline.bin").count, 114)
    XCTAssertEqual(try data("vectors/all-offline-two.bin").count, 112)
  }

  // MARK: - 3b. Provenance must survive its source change being archived

  /// TASK-ASP-001. The registry used to name an exact in-repo path, which is why
  /// CHG-2026-024 could not be archived: `git mv` broke the reference and repairing it
  /// cascaded into the lock, this pack's manifest and these assertions. The change id plus a
  /// change-relative evidence path carry the same meaning and survive the move.
  func testProvenanceIsArchiveStableAndNamesNoInRepoPath() throws {
    let registry = try loadRegistry()
    for entry in registry.entries {
      let provenance = entry.provenance
      XCTAssertTrue(
        provenance.sourceChange.hasPrefix("CHG-"),
        "\(entry.id): sourceChange must be a change id")
      XCTAssertFalse(provenance.sourceEvidence.isEmpty)
      // The whole point: no repository-rooted path, so archiving cannot break it.
      XCTAssertFalse(
        provenance.sourceEvidence.hasPrefix("openspec/"),
        "\(entry.id): sourceEvidence must be relative to the change directory")
      XCTAssertFalse(provenance.sourceEvidence.hasPrefix("/"))
      XCTAssertFalse(provenance.sourceEvidence.contains("openspec/changes/"))
      XCTAssertFalse(
        provenance.sourceEvidence.contains("archive/"),
        "\(entry.id): an archive-dated directory would break on the next rename")
    }
  }

  /// Belt and braces: the whole registry text, not just the decoded fields.
  func testNoRegistryByteNamesAnInRepoChangePath() throws {
    for file in ["registry.yaml", "resources.json"] {
      let text = String(decoding: try data(file), as: UTF8.self)
      XCTAssertFalse(
        text.contains("openspec/changes/"),
        "\(file) still names an in-repo change path")
    }
  }

  // MARK: - 4. Fail-closed and privacy

  func testEveryNonStdoutControlStaysFailClosed() throws {
    let controls = try JSONDecoder().decode(
      Controls.self, from: try data("controls/fail-closed-vectors.json"))
    XCTAssertGreaterThanOrEqual(controls.cases.count, 10)
    for control in controls.cases {
      XCTAssertTrue(
        ["unknown", "unavailable"].contains(control.expected),
        "\(control.id) must never yield observedEmpty or a partial set")
    }
    let ids = Set(controls.cases.map(\.id))
    for required in [
      "stderr-non-empty", "nonzero-exit", "stdout-truncated", "timeout",
      "cancelled", "server-absent", "endpoint-drift", "server-identity-drift",
    ] {
      XCTAssertTrue(ids.contains(required), "control \(required) is missing")
    }
  }

  func testEffectSurfaceIsReadOnlyAndArgvIsExact() throws {
    let entry = try XCTUnwrap(try loadRegistry().entries.first)
    XCTAssertEqual(entry.exactArgv, ["list", "targets", "-v"])
    XCTAssertEqual(entry.effectClassification, "readOnly")
    for forbidden in [
      "serverStart", "serverStop", "serverRestart", "serverAdoption",
      "subserverLifecycle", "deviceMigration", "deviceMutation", "destructive",
    ] {
      XCTAssertTrue(entry.forbiddenEffects.contains(forbidden))
    }
    XCTAssertEqual(try loadRegistry().unknownFamilyDisposition, "unknown")
  }

  func testNoVectorCarriesAnythingButThePlaceholderKeys() throws {
    let resources = try loadResources()
    let keyPattern = try NSRegularExpression(pattern: "[0-9a-f]{32}")
    for vector in resources.vectors {
      let text = String(decoding: try data(vector.file), as: UTF8.self)
      let range = NSRange(text.startIndex..., in: text)
      for match in keyPattern.matches(in: text, range: range) {
        let found = String(text[Range(match.range, in: text)!])
        XCTAssertTrue(
          Self.placeholderKeys.contains(found),
          "\(vector.file) carries a 32-hex token that is not a placeholder")
      }
    }
    let identity = try XCTUnwrap(try loadRegistry().entries.first).identityPolicy
    XCTAssertFalse(identity.rawIdentifiersLeaveAdapter)
    XCTAssertTrue(identity.presentation.hasPrefix("redacted-device-"))
  }
}
