// Shared Swift oracle for the Rust post-flash HDC alias store (TASK-XPA-016,
// M4): the bytes `RockchipPostFlashHDCBindingStore` leaves on disk and the
// decisions it makes, across the store's whole vocabulary — a first
// publication, a crash-retry of the same proof, a revision advance with its
// archived epoch, the refusals of a stale or foreign publication, a
// same-revision serial rotation, a reissued lineage reconciled and then
// declined, an archive name already taken by a different entry and by the
// identical one, and the two candidate refusals. The Rust store replays every
// step and must leave the same files, byte for byte.
//
// Everything here is host-local: no device, no HDC, no daemon. Record a new
// oracle with `ARKDECK_RUST_POST_FLASH_ALIAS_RECORD=/private/tmp/<new
// directory>`; otherwise the checked-in oracle must match byte for byte.
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class PostFlashAliasOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/post-flash-alias", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_POST_FLASH_ALIAS_RECORD"
  /// A fixed root. Nothing in the store's bytes depends on it; provenance
  /// names it.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-post-flash-alias-oracle", directoryHint: .isDirectory)
  private static let lockName = ".rockchip-post-flash-hdc-binding.lock"
  private static let maximumBytes = 64 * 1_024

  private static let targetID = "TGT-HOST"
  private static let loaderA = String(repeating: "a", count: 64)
  private static let loaderB = String(repeating: "b", count: 64)
  private static let loaderC = String(repeating: "c", count: 64)
  private static let productModel = "ohos"
  private static let buildVersion = "OpenHarmony-7.0.0.36"

  private var stepIndex = 0
  private var steps: [JSONValue] = []
  private var files: [String: Data] = [:]

  private static func digest(_ key: String) -> String {
    SHA256Hex.string(of: Data(key.utf8))
  }

  private static func entry(
    revision: Int, loader: String, previousKey: String, key: String,
    at establishedAtUTC: String, topology: String = "42", jobID: String = "job-host"
  ) -> RockchipPostFlashHDCBinding {
    RockchipPostFlashHDCBinding(
      targetID: targetID, bindingRevision: revision,
      stableLoaderIdentitySHA256: loader,
      previousHDCIdentitySHA256: digest(previousKey),
      hdcIdentitySHA256: digest(key), hdcConnectKey: key,
      usbTopology: topology, productModel: productModel, buildVersion: buildVersion,
      jobID: jobID, establishedAtUTC: establishedAtUTC)
  }

  private static func json(_ record: RockchipPostFlashHDCBinding) -> JSONValue {
    .object([
      "schemaVersion": .string(record.schemaVersion),
      "targetID": .string(record.targetID),
      "bindingRevision": .integer(Int64(record.bindingRevision)),
      "stableLoaderIdentitySHA256": .string(record.stableLoaderIdentitySHA256),
      "previousHDCIdentitySHA256": .string(record.previousHDCIdentitySHA256),
      "hdcIdentitySHA256": .string(record.hdcIdentitySHA256),
      "hdcConnectKey": .string(record.hdcConnectKey),
      "usbTopology": .string(record.usbTopology),
      "productModel": .string(record.productModel),
      "buildVersion": .string(record.buildVersion),
      "jobID": .string(record.jobID),
      "establishedAtUTC": .string(record.establishedAtUTC),
    ])
  }

  private static func json(_ target: RuntimeTargetRecord) -> JSONValue {
    .object([
      "targetID": .string(target.targetID),
      "stablePhysicalIdentitySHA256": .string(target.stablePhysicalIdentitySHA256),
      "bindingRevision": .integer(Int64(target.bindingRevision)),
      "connectKey": .string(target.connectKey),
      "toolVersion": .string(target.toolVersion),
      "adoptedAtUTC": .string(target.adoptedAtUTC),
    ])
  }

  /// The store's own canonical bytes of a record, as `commit` and
  /// `archiveSuperseded` write them.
  private static func canonicalBytes(_ record: RockchipPostFlashHDCBinding) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(record) + Data([0x0A])
  }

  private func published(
    _ body: () throws -> RockchipPostFlashHDCBinding
  ) -> JSONValue {
    do {
      return .object(["published": Self.json(try body())])
    } catch RockchipFlashExecutionError.productionConfigurationUnavailable(let detail) {
      return .object(["refused": .string(detail)])
    } catch {
      return .object(["error": .string(String(describing: error))])
    }
  }

  private func loaded(
    _ body: () throws -> RockchipPostFlashHDCBinding?
  ) -> JSONValue {
    do {
      return .object(["loaded": try body().map(Self.json) ?? .null])
    } catch RockchipFlashExecutionError.productionConfigurationUnavailable(let detail) {
      return .object(["refused": .string(detail)])
    } catch {
      return .object(["error": .string(String(describing: error))])
    }
  }

  private func reconciled(
    _ body: () throws -> RockchipPostFlashHDCBindingStore.ReissuedLineageReconciliation?
  ) -> JSONValue {
    do {
      guard let outcome = try body() else { return .object(["reconciled": .null]) }
      return .object([
        "reconciled": .object([
          "archivedRevision": .integer(Int64(outcome.archivedRevision)),
          "publishedRevision": .integer(Int64(outcome.publishedRevision)),
          "targetID": .string(outcome.targetID),
          "hdcIdentitySHA256": .string(outcome.hdcIdentitySHA256),
        ])
      ])
    } catch RockchipFlashExecutionError.productionConfigurationUnavailable(let detail) {
      return .object(["refused": .string(detail)])
    } catch {
      return .object(["error": .string(String(describing: error))])
    }
  }

  /// Records one step: its input, its outcome, and every file the store's
  /// root holds afterwards (with mode and size), byte for byte.
  private func step(
    _ name: String, input: JSONValue, outcome: JSONValue,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let prefix = String(format: "steps/%02d-%@", stepIndex, name)
    var listing: [JSONValue] = []
    let manager = FileManager.default
    for path in try manager.subpathsOfDirectory(atPath: Self.root.path).sorted() {
      let url = Self.root.appending(path: path)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
      listing.append(
        .object([
          "path": .string(path),
          "kind": .string(isDirectory ? "directory" : "file"),
          "mode": .string(String(metadata.st_mode & 0o777, radix: 8)),
          "bytes": .integer(Int64(metadata.st_size)),
        ]))
      guard !isDirectory else { continue }
      files["\(prefix)/\(path)"] = try Data(contentsOf: url)
    }
    let leftovers = listing.filter {
      if case .object(let entry) = $0, case .string(let path)? = entry["path"] {
        return path.hasSuffix(".part")
      }
      return false
    }
    XCTAssertTrue(leftovers.isEmpty, "no temporary file survives a step", file: file, line: line)
    steps.append(
      .object([
        "index": .integer(Int64(stepIndex)),
        "step": .string(name),
        "input": input,
        "outcome": outcome,
        "files": .array(listing),
      ]))
    stepIndex += 1
  }

  private func plant(_ name: String, bytes: Data) throws {
    let url = Self.root.appending(path: name)
    try? FileManager.default.removeItem(at: url)
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func testSwiftPublishesArchivesAndReconcilesThePostFlashAlias() throws {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    defer { try? manager.removeItem(at: Self.root) }
    let store = RockchipPostFlashHDCBindingStore(rootURL: Self.root)
    let publishInput = { (candidate: RockchipPostFlashHDCBinding, previousKey: String) in
      JSONValue.object([
        "candidate": Self.json(candidate),
        "expectedPreviousHDCIdentitySHA256": .string(Self.digest(previousKey)),
      ])
    }

    // 00: an empty store answers absence, and preparing its root is not a write.
    let empty = loaded { try store.loadIfPresent() }
    XCTAssertEqual(empty, .object(["loaded": .null]))
    try step("load-empty", input: .null, outcome: empty)

    // 01: the first publication.
    let revision3 = Self.entry(
      revision: 3, loader: Self.loaderA, previousKey: "old-key", key: "old-key",
      at: "2026-08-14T08:09:51Z")
    let first = published {
      try store.publish(revision3, expectedPreviousHDCIdentitySHA256: Self.digest("old-key"))
    }
    XCTAssertEqual(first, .object(["published": Self.json(revision3)]))
    try step("publish-revision-3", input: publishInput(revision3, "old-key"), outcome: first)

    // 02: a crash retry of the same proof is idempotent, keeping the stored
    // time, and writes nothing.
    let retry = Self.entry(
      revision: 3, loader: Self.loaderA, previousKey: "old-key", key: "old-key",
      at: "2026-08-14T09:00:00Z")
    let retried = published {
      try store.publish(retry, expectedPreviousHDCIdentitySHA256: Self.digest("old-key"))
    }
    XCTAssertEqual(retried, .object(["published": Self.json(revision3)]))
    try step("retry-same-proof", input: publishInput(retry, "old-key"), outcome: retried)

    // 03: a revision advance opens a new epoch and archives the superseded one.
    let revision4 = Self.entry(
      revision: 4, loader: Self.loaderB, previousKey: "new-key", key: "new-key",
      at: "2026-08-18T04:30:00Z")
    let advanced = published {
      try store.publish(revision4, expectedPreviousHDCIdentitySHA256: Self.digest("new-key"))
    }
    XCTAssertEqual(advanced, .object(["published": Self.json(revision4)]))
    XCTAssertTrue(
      manager.fileExists(
        atPath: Self.root.appending(path: "post-flash-superseded-20260814T080951Z.json").path))
    try step("advance-revision-4", input: publishInput(revision4, "new-key"), outcome: advanced)

    // 04: a stale lower-revision job cannot rotate the newer route.
    let stale = published {
      try store.publish(retry, expectedPreviousHDCIdentitySHA256: Self.digest("old-key"))
    }
    let chainRefusal = "post-flash binding changed before verified alias publication"
    XCTAssertEqual(stale, .object(["refused": .string(chainRefusal)]))
    try step("stale-revision-refused", input: publishInput(retry, "old-key"), outcome: stale)

    // 05: the same revision with another Loader identity is not this lineage.
    let otherLoader = Self.entry(
      revision: 4, loader: Self.loaderC, previousKey: "new-key", key: "new-key",
      at: "2026-08-18T05:00:00Z")
    let foreign = published {
      try store.publish(otherLoader, expectedPreviousHDCIdentitySHA256: Self.digest("new-key"))
    }
    XCTAssertEqual(foreign, .object(["refused": .string(chainRefusal)]))
    try step(
      "other-loader-refused", input: publishInput(otherLoader, "new-key"), outcome: foreign)

    // 06: the same revision may rotate its serial when the chain names the
    // stored alias as the previous one; no epoch changes, nothing is archived.
    let rotated = Self.entry(
      revision: 4, loader: Self.loaderB, previousKey: "new-key", key: "newer-key",
      at: "2026-08-19T00:00:00Z")
    let rotation = published {
      try store.publish(rotated, expectedPreviousHDCIdentitySHA256: Self.digest("new-key"))
    }
    XCTAssertEqual(rotation, .object(["published": Self.json(rotated)]))
    try step(
      "rotate-serial-same-revision", input: publishInput(rotated, "new-key"), outcome: rotation)

    // 07: a reissued lineage — the live target's counter restarted at 2 while
    // the stored alias says 4 — is archived and republished at the live revision.
    let live = RuntimeTargetRecord(
      targetID: Self.targetID, stablePhysicalIdentitySHA256: Self.loaderB,
      bindingRevision: 2, connectKey: "newer-key", toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-09-07T02:20:01Z")
    let reconcileInput = { (topology: String, nowUTC: String) in
      JSONValue.object([
        "target": Self.json(live),
        "observedHDCIdentitySHA256": .string(Self.digest("newer-key")),
        "observedHDCConnectKey": .string("newer-key"),
        "observedUSBTopology": .string(topology),
        "nowUTC": .string(nowUTC),
      ])
    }
    let reissue = reconciled {
      try store.reconcileReissuedLineage(
        target: live, observedHDCIdentitySHA256: Self.digest("newer-key"),
        observedHDCConnectKey: "newer-key", observedUSBTopology: "42",
        nowUTC: "2026-09-08T08:05:00Z")
    }
    XCTAssertEqual(
      reissue,
      .object([
        "reconciled": .object([
          "archivedRevision": .integer(4), "publishedRevision": .integer(2),
          "targetID": .string(Self.targetID),
          "hdcIdentitySHA256": .string(Self.digest("newer-key")),
        ])
      ]))
    XCTAssertTrue(
      manager.fileExists(
        atPath: Self.root.appending(path: "post-flash-superseded-20260819T000000Z.json").path))
    try step(
      "reissue-reconciled", input: reconcileInput("42", "2026-09-08T08:05:00Z"), outcome: reissue)

    // 08: reconciling again finds nothing ahead of the live target.
    let repeated = reconciled {
      try store.reconcileReissuedLineage(
        target: live, observedHDCIdentitySHA256: Self.digest("newer-key"),
        observedHDCConnectKey: "newer-key", observedUSBTopology: "42",
        nowUTC: "2026-09-08T09:00:00Z")
    }
    XCTAssertEqual(repeated, .object(["reconciled": .null]))
    try step(
      "reissue-repeat-declined", input: reconcileInput("42", "2026-09-08T09:00:00Z"),
      outcome: repeated)

    // 09: any disagreement of the five facts declines without a write.
    let disagreement = reconciled {
      try store.reconcileReissuedLineage(
        target: RuntimeTargetRecord(
          targetID: Self.targetID, stablePhysicalIdentitySHA256: Self.loaderB,
          bindingRevision: 1, connectKey: "newer-key", toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-09-07T02:20:01Z"),
        observedHDCIdentitySHA256: Self.digest("newer-key"),
        observedHDCConnectKey: "newer-key", observedUSBTopology: "43",
        nowUTC: "2026-09-08T09:30:00Z")
    }
    XCTAssertEqual(disagreement, .object(["reconciled": .null]))
    try step(
      "reissue-disagreement-declined", input: reconcileInput("43", "2026-09-08T09:30:00Z"),
      outcome: disagreement)

    // 10: the archive name a revision advance would take is held by a
    // different entry: refused, and the occupant is kept.
    let squatter = RockchipPostFlashHDCBinding(
      targetID: "TGT-SQUATTER", bindingRevision: 9,
      stableLoaderIdentitySHA256: String(repeating: "e", count: 64),
      previousHDCIdentitySHA256: String(repeating: "f", count: 64),
      hdcIdentitySHA256: String(repeating: "f", count: 64),
      hdcConnectKey: "older-connect-key", usbTopology: "18874368",
      productModel: Self.productModel, buildVersion: "OpenHarmony-7.0.0.35",
      jobID: "job-squatter", establishedAtUTC: "2026-09-02T07:00:39Z")
    let takenName = "post-flash-superseded-20260908T080500Z.json"
    try plant(takenName, bytes: try Self.canonicalBytes(squatter))
    let revision3Again = Self.entry(
      revision: 3, loader: Self.loaderB, previousKey: "newer-key", key: "next-key",
      at: "2026-09-09T00:00:00Z")
    let collision = published {
      try store.publish(
        revision3Again, expectedPreviousHDCIdentitySHA256: Self.digest("newer-key"))
    }
    XCTAssertEqual(
      collision,
      .object([
        "refused": .string(
          "superseded post-flash binding archive \(takenName) already holds a different entry")
      ]))
    try step(
      "archive-collision-refused",
      input: .object([
        "planted": .object(["name": .string(takenName), "record": Self.json(squatter)]),
        "candidate": Self.json(revision3Again),
        "expectedPreviousHDCIdentitySHA256": .string(Self.digest("newer-key")),
      ]),
      outcome: collision)

    // 11: the same name holding the identical entry is the archive itself:
    // the advance proceeds.
    let current = try XCTUnwrap(try store.loadIfPresent())
    XCTAssertEqual(current.bindingRevision, 2)
    try plant(takenName, bytes: try Self.canonicalBytes(current))
    let proceeds = published {
      try store.publish(
        revision3Again, expectedPreviousHDCIdentitySHA256: Self.digest("newer-key"))
    }
    XCTAssertEqual(proceeds, .object(["published": Self.json(revision3Again)]))
    try step(
      "archive-collision-identical",
      input: .object([
        "planted": .object(["name": .string(takenName), "record": Self.json(current)]),
        "candidate": Self.json(revision3Again),
        "expectedPreviousHDCIdentitySHA256": .string(Self.digest("newer-key")),
      ]),
      outcome: proceeds)

    // 12/13: a candidate the store cannot hold, and a previous alias that is
    // not a digest, are refused before the lock.
    let invalidTopology = Self.entry(
      revision: 3, loader: Self.loaderB, previousKey: "newer-key", key: "next-key",
      at: "2026-09-09T00:00:00Z", topology: "4a")
    let invalid = published {
      try store.publish(
        invalidTopology, expectedPreviousHDCIdentitySHA256: Self.digest("newer-key"))
    }
    XCTAssertEqual(
      invalid, .object(["refused": .string("post-flash binding document is invalid")]))
    try step(
      "invalid-document-refused", input: publishInput(invalidTopology, "newer-key"),
      outcome: invalid)
    let badPrevious = published {
      try store.publish(revision3Again, expectedPreviousHDCIdentitySHA256: "not-a-digest")
    }
    XCTAssertEqual(
      badPrevious, .object(["refused": .string("post-flash binding previous alias is invalid")]))
    try step(
      "invalid-previous-alias-refused",
      input: .object([
        "candidate": Self.json(revision3Again),
        "expectedPreviousHDCIdentitySHA256": .string("not-a-digest"),
      ]),
      outcome: badPrevious)

    // 14: what the store finally holds.
    let final = loaded { try store.loadIfPresent() }
    XCTAssertEqual(final, .object(["loaded": Self.json(revision3Again)]))
    try step("load-final", input: .null, outcome: final)

    try record()
  }

  private func record() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] = try encoder.encode(JSONValue.array(steps)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    let provenance: [String: JSONValue] = [
      "producer": .string(
        "PostFlashAliasOracleContractTests.testSwiftPublishesArchivesAndReconcilesThePostFlashAlias"),
      "root": .string(Self.root.path),
      "store": .object([
        "fileName": .string(RockchipPostFlashHDCBindingStore.fileName),
        "lockName": .string(Self.lockName),
        "maximumBytes": .integer(Int64(Self.maximumBytes)),
        "schemaVersion": .string(RockchipPostFlashHDCBinding.currentSchemaVersion),
      ]),
      // Where production keeps the store: the daemon composes it at the
      // parent of its state directory (`ArkDeckAgentDaemonMain/main.swift`),
      // i.e. `<Application Support>/ArkDeck`, not the state directory itself.
      "productionRoot": .object([
        "applicationSupportRelativeStateDirectory": .string(
          ArkDeckAgentFilesystemLayout.applicationSupportRelativeStateDirectory),
        "applicationSupportRelativeRoot": .string(
          URL(filePath: ArkDeckAgentFilesystemLayout.applicationSupportRelativeStateDirectory)
            .deletingLastPathComponent().lastPathComponent),
        "rule": .string("the parent of the daemon state directory"),
      ]),
      "files": .object(digests),
    ]
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
