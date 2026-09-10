@testable import ArkDeckStorage
import ArkDeckCore
import Foundation
import Darwin
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkDeckBootstrap

/// The real Swift store writes isolated host fixtures; the Rust candidate only
/// receives snapshot bytes over stdin. No installed daemon, target or Runtime
/// state is used. Each comparison checks both durable bytes and read projection.
final class HostStoreShadowContractTests: XCTestCase {
  private static let oracleBinarySHA256: String? = {
    guard let file = Bundle(for: HostStoreShadowContractTests.self).executableURL,
      let bytes = try? Data(contentsOf: file) else { return nil }
    return SHA256Hex.string(of: bytes)
  }()
  private var root: URL!
  private var binary: URL!

  override func setUpWithError() throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_HOSTSTORE_SHADOW_BINARY"] else {
      throw XCTSkip("run rust/scripts/hoststore-shadow.py for the cross-language lane")
    }
    binary = URL(filePath: path)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    root = URL(filePath: "/private/tmp/arkdeck-hoststore-shadow-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }

  func testHistorySavedDeletedUnicodeAndMaximumGeneration() throws {
    let store = RuntimeHistoryFilterStore(
      rootURL: root, nowUTC: { "2026-09-10T01:02:03.456Z" })
    let queries = [
      RuntimeHistoryFilterQuery(),
      RuntimeHistoryFilterQuery(
        search: "失败 café / tab\t\"quote\" \\ emoji 🦀", status: "needsAttention",
        mode: "execute", sessionID: "session-shadow", targetID: "target-shadow",
        timeRange: "lastWeek", activity: "flash"),
      RuntimeHistoryFilterQuery(
        search: String(repeating: "a", count: 512), status: "cancelled",
        mode: "simulated", timeRange: "lastHour", activity: "other"),
    ]
    var generation: UInt64 = 1
    for (index, query) in queries.enumerated() {
      _ = try store.save(expectedGeneration: generation, query: query)
      generation += 1
      try compareHistory(name: "history-saved-\(index)", store: store)
      _ = try store.delete(expectedGeneration: generation)
      generation += 1
      try compareHistory(name: "history-deleted-\(index)", store: store)
    }
    // A representable durable UInt64 may exceed the CLI JSON numeric domain.
    let file = root.appending(path: "history-filter.json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    document["generation"] = Int64.max
    var bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    bytes.append(0x0A)
    try bytes.write(to: file)
    try compareHistory(name: "history-maximum-generation", store: store)
  }

  func testHistoryExtraFieldIsRefusedByBothReaders() throws {
    let store = RuntimeHistoryFilterStore(
      rootURL: root, nowUTC: { "2026-09-10T01:02:03.456Z" })
    _ = try store.save(expectedGeneration: 1, query: RuntimeHistoryFilterQuery())
    let file = root.appending(path: "history-filter.json")
    let original = try Data(contentsOf: file)
    for nested in [false, true] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      if nested {
        var query = try XCTUnwrap(document["query"] as? [String: Any])
        query["extra"] = true
        document["query"] = query
      } else {
        document["extra"] = true
      }
      let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
      try bytes.write(to: file)
      XCTAssertThrowsError(try store.read())
      let result = try rust(bytes)
      XCTAssertEqual(result.status, 65)
      XCTAssertTrue(result.output.isEmpty)
      try record(name: nested ? "history-extra-query-field" : "history-extra-document-field",
                 input: bytes, output: Data(), outcome: "refused")
    }
  }

  func testHistoryUnsupportedValuesAreRefusedWithoutRewrite() throws {
    let store = RuntimeHistoryFilterStore(
      rootURL: root, nowUTC: { "2026-09-10T01:02:03.456Z" })
    _ = try store.save(expectedGeneration: 1, query: RuntimeHistoryFilterQuery())
    let file = root.appending(path: "history-filter.json")
    let original = try Data(contentsOf: file)
    let cases: [(String, String, String)] = [
      ("status", "status", "unsupported"), ("mode", "mode", "unsupported"),
      ("time-range", "timeRange", "unsupported"), ("activity", "activity", "unsupported"),
      ("search-bound", "search", String(repeating: "a", count: 513)),
      ("search-control", "search", "line\nfeed"),
      ("search-format-control", "search", "zero\u{200B}width"),
      ("session-leading-space", "sessionID", "\u{2007}session"),
      ("session-empty", "sessionID", ""),
      ("target-bound", "targetID", String(repeating: "a", count: 257)),
    ]
    for (name, key, value) in cases {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var query = try XCTUnwrap(document["query"] as? [String: Any])
      query[key] = value
      document["query"] = query
      try compareRefusal(name: "history-invalid-" + name, kind: "history-filter",
        document: document, file: file, read: { try store.read().listProjection })
    }
  }

  func testBundleRegistryAvailableRetainedAndRemoved() throws {
    let registryRoot = root.appending(path: "registry")
    let source = root.appending(path: "Fixture.app")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Contents"), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": "shadow-fixture-1"], format: .xml, options: 0)
      .write(to: source.appending(path: "Contents/Info.plist"))
    try Data("non-executable shadow fixture".utf8).write(to: source.appending(path: "Contents/payload"))
    // Test-owned non-executable bytes; this injection is never a signature claim.
    let store = BootstrapBundleRegistry(root: registryRoot, validateBundle: { _ in },
      nowUTC: { "2026-09-10T01:02:03Z" })
    let registered = try store.register(file: source)
    guard case .object(let fields) = registered, case .string(let reference)? = fields["bundleRef"]
    else { return XCTFail("missing fixture bundle reference") }
    let file = registryRoot.appending(path: "bundles.json")
    let read: () throws -> JSONValue = { .array(try store.list { _, rows in rows }) }
    try compareStore(name: "bundle-available", kind: "bundle-registry", file: file, read: read)
    _ = try store.acquire(reference, expectedGeneration: "1", owner: .init(kind: .controlAction, id: "shadow-fixture"))
    try compareStore(name: "bundle-retained", kind: "bundle-registry", file: file, read: read)
    try store.release(reference, owner: .init(kind: .controlAction, id: "shadow-fixture"))
    _ = try store.remove(reference, expectedGeneration: "1")
    try compareStore(name: "bundle-removed", kind: "bundle-registry", file: file, read: read)
    try refuseExtraRegistryFields(kind: "bundle-registry", prefix: "bundle", file: file, read: read)
  }

  func testToolRegistryAvailableRetainedAndRemoved() throws {
    let registryRoot = root.appending(path: "registry")
    let store = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: registryRoot),
      nowUTC: { "2026-09-10T01:02:03Z" })
    let source = root.appending(path: "fixture-hdc")
    let fixture = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appending(path: "ArkDeckFakeHDCFixture")
    try FileManager.default.copyItem(at: fixture, to: source)
    let registered = try store.register(file: source)
    guard case .object(let fields) = registered, case .string(let reference)? = fields["toolRef"]
    else { return XCTFail("missing fixture tool reference") }
    let file = registryRoot.appending(path: "tools.json")
    let read: () throws -> JSONValue = { .array(try store.list { _, rows in rows }) }
    try compareStore(name: "tool-available", kind: "tool-registry", file: file, read: read)
    _ = try store.acquire(reference, expectedGeneration: "1", owner: .init(kind: .controlAction, id: "shadow-fixture"))
    try compareStore(name: "tool-retained", kind: "tool-registry", file: file, read: read)
    try store.release(reference, owner: .init(kind: .controlAction, id: "shadow-fixture"))
    _ = try store.remove(reference, expectedGeneration: "1")
    try compareStore(name: "tool-removed", kind: "tool-registry", file: file, read: read)
    try refuseExtraRegistryFields(kind: "tool-registry", prefix: "tool", file: file, read: read)
  }

  func testDisplayNamesTargetTombstoneAndCandidate() throws {
    let store = RuntimeTargetDisplayNameStore(
      rootURL: root, nowUTC: { "2026-09-10T01:02:03.456Z" })
    _ = try store.set(targetID: "target-a", expectedGeneration: 1, name: "设备 café 🦀")
    _ = try store.set(targetID: "target-b", expectedGeneration: 1, name: "Second")
    let file = root.appending(path: "target-display-names.json")
    var references: [TargetObservationReference] = []
    let read: () throws -> JSONValue = {
      let targets = try ["target-a", "target-b"].map { try store.read(targetID: $0).projection }
      let candidates = try store.candidateDisplayNames(references: references)
      return .object([
        "targets": .array(targets),
        "candidates": .array(try references.map { try XCTUnwrap(candidates[$0.observationID]).projection }),
      ])
    }
    try compareStore(name: "names-targets", kind: "display-names", file: file, read: read)
    // Swift String equality uses canonical equivalence, including its NFC guard.
    _ = try store.set(targetID: "target-a", expectedGeneration: 2, name: "cafe\u{301}")
    try compareStore(name: "names-decomposed-unicode", kind: "display-names", file: file, read: read)
    _ = try store.clear(targetID: "target-b", expectedGeneration: 2)
    try compareStore(name: "names-tombstone", kind: "display-names", file: file, read: read)
    let first = TargetObservationReference(candidate: "fixture-candidate", observationID: "observation-fixture", generation: 1)
    _ = try store.setCandidate(first, activeReferences: [first], nextGeneration: 2, name: "Candidate")
    references = [.init(candidate: first.candidate, observationID: first.observationID, generation: 2)]
    try compareStore(name: "names-candidate", kind: "display-names", file: file, read: read)
    let unstaged = try Data(contentsOf: file)
    for variant in ["canonical-stage", "embedded-null-candidate"] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: unstaged) as? [String: Any])
      var candidates = try XCTUnwrap(document["candidateRecords"] as? [[String: Any]])
      if variant == "canonical-stage" {
        candidates[0]["name"] = "café"
        candidates[0]["stagedTargetID"] = "target-a"
        candidates[0]["stagedTargetGeneration"] = 3
      } else {
        candidates[0]["candidate"] = "fixture\u{0}candidate"
        references = [.init(candidate: "fixture\u{0}candidate", observationID: first.observationID, generation: 2)]
      }
      document["candidateRecords"] = candidates
      var bytes = try JSONSerialization.data(withJSONObject: document,
        options: [.sortedKeys, .withoutEscapingSlashes])
      bytes.append(0x0A)
      try bytes.write(to: file)
      try compareStore(name: "names-" + variant, kind: "display-names", file: file, read: read)
    }
    references = [.init(candidate: first.candidate, observationID: first.observationID, generation: 2)]
    try unstaged.write(to: file)
    try refuseExtraRegistryFields(kind: "display-names", prefix: "names", file: file, read: read)
    let original = try Data(contentsOf: file)
    for name in ["unordered-targets", "duplicate-target", "duplicate-candidate", "stage-unpaired", "stage-mismatch", "target-identifier", "candidate-empty", "candidate-bound", "observation-empty", "observation-bound", "candidate-key-collision", "name-empty", "name-bound", "name-space", "name-format-control", "canonical-duplicate-candidate"] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var targets = try XCTUnwrap(document["records"] as? [[String: Any]])
      var candidates = try XCTUnwrap(document["candidateRecords"] as? [[String: Any]])
      switch name {
      case "unordered-targets": targets.reverse()
      case "duplicate-target": targets.insert(targets[0], at: 0)
      case "duplicate-candidate": candidates.append(candidates[0])
      case "stage-unpaired": candidates[0]["stagedTargetID"] = "target-a"
      case "canonical-duplicate-candidate":
        var second = candidates[0]
        candidates[0]["candidate"] = "cafe\u{301}"
        second["candidate"] = "café"
        candidates.append(second)
      case "name-empty": targets[0]["name"] = ""
      case "name-bound": targets[0]["name"] = String(repeating: "a", count: 257)
      case "name-space": targets[0]["name"] = "trailing\u{2007}"
      case "name-format-control": targets[0]["name"] = "zero\u{200B}width"
      case "target-identifier": targets[0]["targetID"] = "-invalid"
      case "candidate-empty": candidates[0]["candidate"] = ""
      case "candidate-bound": candidates[0]["candidate"] = String(repeating: "a", count: 1025)
      case "observation-empty": candidates[0]["observationID"] = ""
      case "observation-bound": candidates[0]["observationID"] = String(repeating: "a", count: 129)
      case "candidate-key-collision":
        var second = candidates[0]
        candidates[0]["candidate"] = "a"
        candidates[0]["observationID"] = "b\nc"
        second["candidate"] = "a\nb"
        second["observationID"] = "c"
        candidates.append(second)
      default:
        candidates[0]["stagedTargetID"] = "target-a"
        candidates[0]["stagedTargetGeneration"] = 999
      }
      document["records"] = targets
      document["candidateRecords"] = candidates
      try compareRefusal(name: "names-invalid-" + name, kind: "display-names",
        document: document, file: file, read: read)
    }

  }

  func testSessionInventoryAndRetentionProjection() throws {
    let owner = root.appending(path: "session-owner")
    let sessions = root.appending(path: "session-tree")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    let config = owner.appending(path: "session-storage.json")
    try compareSessionStatus("empty", store: store, config: config, sessions: sessions)
    try FileManager.default.removeItem(at: sessions.appending(path: ".arkdeck-retention-catalog.json"))
    try Data().write(to: sessions.appending(path: ".arkdeck-retention-catalog.lock"))
    try compareSessionStatus("fresh-catalog", store: store, config: config, sessions: sessions, beforeReconciliation: true)
    let first = try seedShadowSession(sessions: sessions, month: "01", id: "session-first",
      timestamp: "2026-01-01T00:00:00.123456789Z", includeArtifacts: true)
    try compareSessionStatus("unregistered", store: store, config: config, sessions: sessions)
    try catalog.registerFinalizedSession(sessionRoot: first, retentionDays: 7, policyGeneration: 2)
    try compareSessionStatus("registered", store: store, config: config, sessions: sessions)
    _ = try catalog.updatePin(sessionID: "session-first", isPinned: true, expectedGeneration: 1)
    try compareSessionStatus("pinned", store: store, config: config, sessions: sessions)
    let second = try seedShadowSession(sessions: sessions, month: "02", id: "session-second",
      timestamp: "2024-02-29T23:59:60.123+23:59")
    try catalog.registerFinalizedSession(sessionRoot: second, retentionDays: 7, policyGeneration: 2)
    try compareSessionStatus("leap-second", store: store, config: config, sessions: sessions)
    let catalogFile = sessions.appending(path: ".arkdeck-retention-catalog.json")
    let oldCatalog = try Data(contentsOf: catalogFile)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 8), expectedGeneration: 2)
    try oldCatalog.write(to: catalogFile)
    try compareSessionStatus("reconcile-policy", store: store, config: config, sessions: sessions, beforeReconciliation: true)
    let duplicateParent = sessions.appending(path: "2027/01")
    try FileManager.default.createDirectory(at: duplicateParent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let duplicate = duplicateParent.appending(path: "session-first")
    try FileManager.default.copyItem(at: first, to: duplicate)
    try compareSessionStatus("duplicate-identity", store: store, config: config, sessions: sessions)
    try FileManager.default.removeItem(at: duplicate)
    let backup = root.appending(path: "session-second-backup")
    try FileManager.default.copyItem(at: second, to: backup)
    try FileManager.default.removeItem(at: second)
    try compareSessionStatus("reconcile-removed", store: store, config: config, sessions: sessions, beforeReconciliation: true)
    try FileManager.default.copyItem(at: backup, to: second)
    try catalog.registerFinalizedSession(sessionRoot: second, retentionDays: 8, policyGeneration: 3)
    try Data("unscoped".utf8).write(to: sessions.appending(path: "loose.bin"))
    try compareSessionStatus("unscoped", store: store, config: config, sessions: sessions)
    try FileManager.default.removeItem(at: second)
    try compareSessionStatus("unscoped-retains-missing", store: store, config: config, sessions: sessions, beforeReconciliation: true)
    try FileManager.default.copyItem(at: backup, to: second)
    let identity = first.appending(path: ".session-identity.json")
    let originalIdentity = try Data(contentsOf: identity)
    let mismatch: JSONValue = .object(["schemaVersion": .string("1.0.0"), "sessionId": .string("session-first"), "jobId": .string("job-mismatch")])
    try CanonicalJSONEncoders.canonical().encode(mismatch).write(to: identity)
    try compareSessionStatus("identity-mismatch", store: store, config: config, sessions: sessions)
    try originalIdentity.write(to: identity)
    let manifest = first.appending(path: "manifest.json")
    let original = try Data(contentsOf: manifest)
    for variant in ["artifact-hash-mismatch", "artifact-lineage-cycle", "artifact-invalid-path"] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var artifacts = try XCTUnwrap(document["artifacts"] as? [[String: Any]])
      switch variant {
      case "artifact-hash-mismatch": artifacts[0]["sha256"] = String(repeating: "b", count: 64)
      case "artifact-invalid-path": artifacts[0]["relativePath"] = "../payload.bin"
      default:
        artifacts[1]["derivedFrom"] = ["derived"]
        artifacts[1]["origin"] = try DerivedArtifactProvenance(operation: "shadow.derive",
          inputHashes: [try XCTUnwrap(artifacts[1]["sha256"] as? String)],
          parameters: ["format": "text"], statistics: ["bytes": 15]).manifestOrigin()
      }
      document["artifacts"] = artifacts
      try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: manifest)
      try compareSessionStatus(variant, store: store, config: config, sessions: sessions)
    }
    try Data("{}".utf8).write(to: manifest)
    try compareSessionStatus("corrupt-manifest", store: store, config: config, sessions: sessions)
    try original.write(to: manifest)
    let outside = root.appending(path: "original.bin")
    try Data("original immutable fixture".utf8).write(to: outside)
    let link = first.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try compareSessionStatus("symlink", store: store, config: config, sessions: sessions)
    try FileManager.default.removeItem(at: link)
    let metadata = sessions.appending(path: ".arkdeck-retention-catalog.json")
    var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
    extra["extra"] = true
    try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: metadata)
    try compareSessionStatus("extra-catalog-field", store: store, config: config, sessions: sessions)
    try Data("{}".utf8).write(to: metadata)
    try compareSessionStatus("corrupt-catalog", store: store, config: config, sessions: sessions)
    try FileManager.default.removeItem(at: metadata)
    try compareSessionStatus("missing-catalog", store: store, config: config, sessions: sessions)
  }

  private func seedShadowSession(sessions: URL, month: String, id: String, timestamp: String, includeArtifacts: Bool = false) throws -> URL {
    let directory = sessions.appending(path: "2026/" + month + "/" + id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let identity: JSONValue = .object(["schemaVersion": .string("1.0.0"),
      "sessionId": .string(id), "jobId": .string("job-" + id)])
    try CanonicalJSONEncoders.canonical().encode(identity).write(to: directory.appending(path: ".session-identity.json"))
    let payload = Data(repeating: 0x41, count: 33)
    var artifacts: [ArtifactRecord] = []
    if includeArtifacts {
      let sourceHash = SHA256Hex.string(of: payload)
      artifacts.append(try ArtifactRecord(id: "raw", role: .raw, origin: "shadow-fixture",
        relativePath: "payload.bin", size: UInt64(payload.count), sha256: sourceHash))
      let derived = Data("derived summary".utf8)
      let provenance = try DerivedArtifactProvenance(operation: "shadow.derive", inputHashes: [sourceHash],
        parameters: ["format": "text"], statistics: ["bytes": Int64(derived.count)])
      artifacts.append(try ArtifactRecord(id: "derived", role: .derived, origin: provenance.manifestOrigin(),
        relativePath: "derived.txt", size: UInt64(derived.count), sha256: SHA256Hex.string(of: derived),
        mediaType: "text/plain", derivedFrom: ["raw"]))
      try derived.write(to: directory.appending(path: "derived.txt"))
    }
    try SessionStorageFixtures.manifest(sessionID: id, jobID: "job-" + id, timestamp: timestamp, artifacts: artifacts)
      .write(to: directory.appending(path: "manifest.json"))
    try payload.write(to: directory.appending(path: "payload.bin"))
    return directory
  }

  private func sessionSnapshot() throws -> Data {
    var values: [[String: String]] = []
    for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
      let file = root.appending(path: path)
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let type = try XCTUnwrap(attributes[.type] as? FileAttributeType)
      var row = ["path": path, "type": type.rawValue,
        "mode": String(try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue)]
      if type == .typeRegular { row["sha256"] = SHA256Hex.string(of: try Data(contentsOf: file)) }
      if type == .typeSymbolicLink { row["link"] = try FileManager.default.destinationOfSymbolicLink(atPath: file.path) }
      values.append(row)
    }
    return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  private func compareSessionStatus(_ name: String, store: RuntimeSessionStorageStore, config: URL, sessions: URL, beforeReconciliation: Bool = false) throws {
    // Swift may reconcile only these isolated fixtures. Rust then reads that
    // concrete snapshot without rewriting the catalog, lock marker or payload.
    let prepared = beforeReconciliation ? nil : try CanonicalJSONEncoders.canonical().encode(store.status().projection)
    let before = try sessionSnapshot()
    let physical = try XCTUnwrap(realpath(sessions.path, nil))
    defer { free(physical) }
    let result = try rust(Data(contentsOf: config), kind: "session-status", arguments: [String(cString: physical)])
    XCTAssertEqual(result.status, 0, name)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: result.output)
    let output = try CanonicalJSONEncoders.canonical().encode(decoded)
    XCTAssertEqual(try sessionSnapshot(), before, name)
    let expected = try prepared ?? CanonicalJSONEncoders.canonical().encode(store.status().projection)
    XCTAssertEqual(output, expected, name)
    try record(name: "inventory-" + name, input: before, output: output, outcome: "equal", store: "session-storage")
  }

  func testSessionParameterStateProjection() throws {
    let owner = root.appending(path: "parameter-owner")
    let sessions = root.appending(path: "parameter-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-parameters",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-parameters", isPinned: true, expectedGeneration: 1)
    let file = directory.appending(path: "manifest.json")
    let original = try Data(contentsOf: file)
    let graphemes = ["crlf": "\r\n", "combining": "e\u{301}", "flag": "🇨🇳",
      "hangul": "\u{1100}\u{1161}\u{11A8}", "indic": "\u{0915}\u{094D}\u{0937}", "skin-tone": "👍🏽"]
    let accepted = ["restored", "missing-before", "unreadable-before", "empty-value", "unicode-boundary", "failed-session"]
      + graphemes.keys.sorted().map { $0 + "-boundary" }
    let rejected = ["different-bytes", "restored-missing-before", "desired-missing", "value-too-long",
      "unicode-too-long", "state-extra-field", "success-failed-restore", "unreadable-empty-reason"]
      + graphemes.keys.sorted().map { $0 + "-too-long" }
    for name in accepted + rejected {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var parameter: [String: Any] = ["name": "persist.shadow", "beforeState": ["state": "value", "value": "original"],
        "desiredState": ["state": "value", "value": "desired"], "afterState": ["state": "value", "value": "original"],
        "restoreState": ["state": "value", "value": "original"], "restoreDisposition": "restored"]
      switch name {
      case "missing-before", "unreadable-before", "unreadable-empty-reason":
        parameter["beforeState"] = name == "missing-before" ? ["state": "missing"]
          : ["state": "unreadable", "reason": name == "unreadable-before" ? "fixture unavailable" : ""]
        parameter["restoreState"] = ["state": "missing"]
        parameter["restoreDisposition"] = "notRequired"
      case "empty-value": parameter["desiredState"] = ["state": "value", "value": ""]
      case "unicode-boundary", "unicode-too-long":
        parameter["desiredState"] = ["state": "value", "value": String(repeating: "👩‍👩‍👦", count: name == "unicode-boundary" ? 4096 : 4097)]
      case "different-bytes":
        parameter["beforeState"] = ["state": "value", "value": "café"]
        parameter["restoreState"] = ["state": "value", "value": "cafe\u{301}"]
      case "restored-missing-before": parameter["beforeState"] = ["state": "missing"]
      case "desired-missing": parameter["desiredState"] = ["state": "missing"]
      case "value-too-long": parameter["desiredState"] = ["state": "value", "value": String(repeating: "a", count: 4097)]
      case "state-extra-field": parameter["desiredState"] = ["state": "value", "value": "desired", "extra": true]
      case "success-failed-restore", "failed-session":
        parameter["restoreDisposition"] = "failed"
        if name == "failed-session" {
          document["status"] = "failed"
          document["failure"] = ["stage": "restore", "code": "restore.failed", "summary": "fixture failure"]
        }
      default: break
      }
      for (kind, grapheme) in graphemes where name == kind + "-boundary" || name == kind + "-too-long" {
        let count = name.hasSuffix("-boundary") ? 4096 : 4097
        let value = String(repeating: grapheme, count: count)
        XCTAssertEqual(value.count, count, name)
        parameter["desiredState"] = ["state": "value", "value": value]
      }
      document["parameters"] = [parameter]
      try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
      XCTAssertEqual(try store.status().measurementIncomplete, rejected.contains(name), name)
      try compareSessionStatus("parameter-" + name, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
  }

  func testSessionTimestampCalculationMatchesFrozenSwiftDecoder() throws {
    let accepted = [
      "2001-01-01T00:00:00Z", "2026-09-10T01:02:03.123456789123Z",
      "2024-02-29T23:59:60.123+23:59", "2026-09-10t01:02:03z",
      "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z",
      "1582-10-10T00:00:00Z", "1500-02-28T00:00:00Z",
      "2000-02-29T00:00:00-23:59", "2001-01-01T00:00:00.000000001Z",
    ]
    let refused = [
      "0000-01-01T00:00:00Z", "2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z",
      "2026-09-10T24:00:00Z", "2026-09-10T01:60:00Z", "2026-09-10T01:02:61Z",
      "2026-09-10T01:02:03+24:00", "2026-09-10T01:02:03.Z",
      "2026-09-10T01:02:03Zextra", "2026-09-10T01:02:03+01:60",
    ]
    for (index, value) in accepted.enumerated() {
      let date = try SessionManifestDocument.lockedTimestampDate(value, field: "shadow timestamp")
      let input = try JSONEncoder().encode(value)
      let result = try rust(input, kind: "session-timestamp")
      XCTAssertEqual(result.status, 0, value)
      let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
      let projection = try XCTUnwrap(envelope["projection"] as? [String: String])
      XCTAssertEqual(projection["referenceSecondsBits"], String(date.timeIntervalSinceReferenceDate.bitPattern), value)
      let output = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys])
      try record(name: "timestamp-accepted-\(index)", input: input, output: output,
        outcome: "equal", store: "session-timestamp")
    }
    for (index, value) in refused.enumerated() {
      XCTAssertThrowsError(try SessionManifestDocument.lockedTimestampDate(value, field: "shadow timestamp"), value)
      let input = try JSONEncoder().encode(value)
      let result = try rust(input, kind: "session-timestamp")
      XCTAssertEqual(result.status, 65, value)
      XCTAssertTrue(result.output.isEmpty)
      try record(name: "timestamp-refused-\(index)", input: input, output: Data(),
        outcome: "refused", store: "session-timestamp")
    }
  }

  func testSessionConfigurationPolicyRootAndRefusal() throws {
    let owner = root.appending(path: "owner")
    let sessions = root.appending(path: "sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    let file = owner.appending(path: "session-storage.json")
    let read: () throws -> JSONValue = {
      // status may update the retention catalog: both are isolated fixture roots.
      // Compare configuration only until the Rust inventory scanner is delivered.
      guard case .object(let status) = try store.status().projection else {
        throw NSError(domain: "HostStoreShadow", code: 1)
      }
      return .object(status.filter { ["generation", "rootPath", "rootKind", "policy"].contains($0.key) })
    }
    _ = try store.updatePolicy(
      .init(totalQuotaBytes: 10000, safetyMarginBytes: 1000, retentionDays: 7), expectedGeneration: 1)
    try compareStore(name: "session-policy", kind: "session-configuration", file: file, read: read)
    let custom = root.appending(path: "custom")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    _ = try store.updateRoot(path: custom.path, resetToDefault: false, expectedGeneration: 2)
    try compareStore(name: "session-custom-root", kind: "session-configuration", file: file, read: read)
    _ = try store.updatePolicy(
      .init(totalQuotaBytes: UInt64(Int64.max), safetyMarginBytes: 1, retentionDays: 7), expectedGeneration: 3)
    try compareStore(name: "session-maximum-quota", kind: "session-configuration", file: file, read: read)
    let original = try Data(contentsOf: file)
    for nested in [false, true] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      if nested {
        var policy = try XCTUnwrap(document["policy"] as? [String: Any])
        policy["extra"] = true; document["policy"] = policy
      } else { document["extra"] = true }
      var bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
      bytes.append(0x0A)
      try bytes.write(to: file)
      XCTAssertThrowsError(try read())
      let result = try rust(bytes, kind: "session-configuration")
      XCTAssertEqual(result.status, 65)
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      try record(name: nested ? "session-extra-policy-field" : "session-extra-document-field",
                 input: bytes, output: Data(), outcome: "refused", store: "session-configuration")
    }
  }

  private func refuseExtraRegistryFields(
    kind: String, prefix: String, file: URL, read: () throws -> JSONValue
  ) throws {
    let original = try Data(contentsOf: file)
    for nested in [false, true] {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      if nested {
        var records = try XCTUnwrap(document["records"] as? [[String: Any]])
        records[0]["extra"] = true
        document["records"] = records
      } else { document["extra"] = true }
      let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
      try bytes.write(to: file)
      XCTAssertThrowsError(try read())
      let result = try rust(bytes, kind: kind)
      XCTAssertEqual(result.status, 65)
      XCTAssertTrue(result.output.isEmpty)
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      try record(name: prefix + (nested ? "-extra-record-field" : "-extra-index-field"),
                 input: bytes, output: Data(), outcome: "refused", store: kind)
    }
    try original.write(to: file)
  }

  private func compareRefusal(
    name: String, kind: String, document: [String: Any], file: URL,
    read: () throws -> JSONValue
  ) throws {
    let bytes = try JSONSerialization.data(withJSONObject: document,
      options: [.sortedKeys, .withoutEscapingSlashes])
    try bytes.write(to: file)
    XCTAssertThrowsError(try read(), name)
    let result = try rust(bytes, kind: kind)
    XCTAssertEqual(result.status, 65, name)
    XCTAssertTrue(result.output.isEmpty, name)
    XCTAssertEqual(try Data(contentsOf: file), bytes, name)
    try record(name: name, input: bytes, output: Data(), outcome: "refused", store: kind)
  }

  private func compareHistory(name: String, store: RuntimeHistoryFilterStore) throws {
    try compareStore(name: name, kind: "history-filter", file: root.appending(path: "history-filter.json")) {
      try store.read().listProjection
    }
  }

  private func compareStore(name: String, kind: String, file: URL, read: () throws -> JSONValue) throws {
    let original = try Data(contentsOf: file)
    let swiftProjection = try CanonicalJSONEncoders.canonical().encode(read())
    let result = try rust(original, kind: kind)
    XCTAssertEqual(result.status, 0)
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    let rewritten = Data(try XCTUnwrap(envelope["document"] as? String).utf8)
    XCTAssertEqual(rewritten, original, name)
    let projection = try JSONSerialization.data(
      withJSONObject: XCTUnwrap(envelope["projection"]), options: [.sortedKeys, .withoutEscapingSlashes])
    XCTAssertEqual(projection, swiftProjection, name)
    XCTAssertEqual(try Data(contentsOf: file), original, "Rust comparison must not write the store")
    // Only this test copy is replaced; the production reader must accept Rust bytes.
    try rewritten.write(to: file)
    XCTAssertEqual(try CanonicalJSONEncoders.canonical().encode(read()), swiftProjection)
    try record(name: name, input: original, output: projection, outcome: "equal", store: kind)
  }

  private func rust(_ input: Data, kind: String = "history-filter", arguments: [String] = []) throws -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = binary
    process.arguments = [kind] + arguments
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    // The adapter is bounded to 4 MiB input. Drain before wait to avoid pipe backpressure.
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
  }

  private func record(name: String, input: Data, output: Data, outcome: String, store: String = "history-filter") throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_HOSTSTORE_SHADOW_RESULTS"] else { return }
    let report: [String: Any] = [
      "case": name, "store": store, "outcome": outcome,
      "inputSHA256": SHA256Hex.string(of: input), "projectionSHA256": SHA256Hex.string(of: output),
      "oracleBinarySHA256": try XCTUnwrap(Self.oracleBinarySHA256),
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: URL(filePath: path).appending(path: name + ".json"), options: .withoutOverwriting)
  }
}
