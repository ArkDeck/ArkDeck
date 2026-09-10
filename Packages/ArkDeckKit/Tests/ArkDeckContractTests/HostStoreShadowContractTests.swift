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
    try compareRegistrySemantics(prefix: "bundle", kind: "bundle-registry", file: file, read: read)
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
    try compareRegistrySemantics(prefix: "tool", kind: "tool-registry", file: file, read: read)
    _ = try store.acquire(reference, expectedGeneration: "1", owner: .init(kind: .controlAction, id: "shadow-fixture"))
    try compareStore(name: "tool-retained", kind: "tool-registry", file: file, read: read)
    try store.release(reference, owner: .init(kind: .controlAction, id: "shadow-fixture"))
    _ = try store.remove(reference, expectedGeneration: "1")
    try compareStore(name: "tool-removed", kind: "tool-registry", file: file, read: read)
    try refuseExtraRegistryFields(kind: "tool-registry", prefix: "tool", file: file, read: read)
  }

  func testPublishedToolIdentityDiagnosticLookup() throws {
    let known = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260"
    let inputs = [known, "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83",
      known.uppercased(), String(repeating: "0", count: 64), "", known + "\n", known + "\u{0}"]
    for (index, sha256) in inputs.enumerated() {
      let match = HeadlessHDCBootstrapIdentity.lookup(sha256: sha256)
      XCTAssertEqual(match != nil, index < 2)
      let identity: JSONValue = match.map { .object(["version": .string($0.version),
        "profileReferences": .array($0.profileReferences.map(JSONValue.string))]) } ?? .null
      let expected = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(["identity": identity]))
      let input = try JSONEncoder().encode(sha256)
      let result = try rust(input, kind: "tool-identity")
      XCTAssertEqual(result.status, 0)
      let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
      let projection = try JSONSerialization.data(withJSONObject: XCTUnwrap(envelope["projection"]), options: [.sortedKeys])
      XCTAssertEqual(projection, expected)
      try record(name: "identity-published-\(index)", input: input, output: projection,
        outcome: "equal", store: "tool-identity")
    }
  }

  func testToolSelectionLedgerProjection() throws {
    let registryRoot = root.appending(path: "selection-registry")
    let store = BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: registryRoot),
      nowUTC: { "2026-09-10T01:02:03Z" })
    let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    for name in ["ArkDeckFakeHDCFixture", "ArkDeckFakeHapSignerFixture"] {
      let source = root.appending(path: name)
      try FileManager.default.copyItem(at: products.appending(path: name), to: source)
      _ = try store.register(file: source)
    }
    let file = registryRoot.appending(path: "tools.json")
    let original = try Data(contentsOf: file)
    let read: () throws -> JSONValue = { .array(try store.list { _, rows in rows }) }
    let valid = ["active", "pending", "outcome-succeeded", "outcome-failed", "outcome-failed-reason", "pending-maximum-generation"]
    let invalid = ["unordered-records", "pending-old-mismatch", "pending-new-missing", "pending-generation-mismatch",
      "pending-action-invalid", "pending-old-unpinned", "pending-new-unpinned", "pending-outcome-paired",
      "outcome-action-invalid", "outcome-result-invalid", "outcome-generation-mismatch", "outcome-old-missing",
      "outcome-new-missing", "outcome-active-mismatch", "outcome-reason-invalid", "active-unavailable", "active-extra-owner"]
    for name in valid + invalid {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var rows = try XCTUnwrap(document["records"] as? [[String: Any]])
      XCTAssertEqual(rows.count, 2)
      let old = try XCTUnwrap(rows[0]["reference"] as? String)
      let new = try XCTUnwrap(rows[1]["reference"] as? String)
      let missing = "tool:sha256:" + String(repeating: "0", count: 64)
      let activeOwner: [String: Any] = ["kind": "activeSelection", "id": "runtime-hdc-selection"]
      let actionOwner: [String: Any] = ["kind": "controlAction", "id": "fixture-action"]
      let succeeded = name.hasPrefix("outcome-") && name != "outcome-failed" && name != "outcome-failed-reason"
      let activeIndex = succeeded ? 1 : 0
      rows[activeIndex]["references"] = [activeOwner]
      var selection: [String: Any] = ["activeToolRef": succeeded ? new : old, "activeGeneration": UInt64(2)]
      if name.hasPrefix("pending-") || name == "pending" {
        rows[0]["references"] = [activeOwner, actionOwner]
        rows[1]["references"] = [actionOwner]
        var pending: [String: Any] = ["actionID": "fixture-action", "oldToolRef": old, "newToolRef": new,
          "expectedActiveGeneration": UInt64(2)]
        switch name {
        case "pending-old-mismatch": pending["oldToolRef"] = new
        case "pending-new-missing": pending["newToolRef"] = missing
        case "pending-generation-mismatch": pending["expectedActiveGeneration"] = 1
        case "pending-action-invalid": pending["actionID"] = "invalid:action"
        case "pending-old-unpinned": rows[0]["references"] = [activeOwner]
        case "pending-new-unpinned": rows[1]["references"] = [] as [[String: Any]]
        case "pending-maximum-generation":
          selection["activeGeneration"] = UInt64.max; pending["expectedActiveGeneration"] = UInt64.max
        default: break
        }
        selection["pending"] = pending
        if name == "pending-outcome-paired" {
          selection["lastOutcome"] = ["actionID": "fixture-action", "oldToolRef": old, "newToolRef": new,
            "activeGeneration": 2, "result": "failed"]
        }
      }
      if name.hasPrefix("outcome-") {
        var outcome: [String: Any] = ["actionID": "fixture-action", "oldToolRef": old, "newToolRef": new,
          "activeGeneration": 2, "result": succeeded ? "succeeded" : "failed"]
        switch name {
        case "outcome-failed-reason": outcome["reasonCode"] = "fixture.failure"
        case "outcome-action-invalid": outcome["actionID"] = "invalid:action"
        case "outcome-result-invalid": outcome["result"] = "unknown"
        case "outcome-generation-mismatch": outcome["activeGeneration"] = 1
        case "outcome-old-missing": outcome["oldToolRef"] = missing
        case "outcome-new-missing": outcome["newToolRef"] = missing
        case "outcome-active-mismatch":
          rows[0]["references"] = [activeOwner]; rows[1]["references"] = [] as [[String: Any]]
          selection["activeToolRef"] = old
        case "outcome-reason-invalid": outcome["reasonCode"] = "invalid:reason"
        default: break
        }
        selection["lastOutcome"] = outcome
      }
      if name == "active-unavailable" { rows[0]["state"] = "removed"; rows[0]["generation"] = 2; rows[0]["references"] = [] as [[String: Any]] }
      if name == "active-extra-owner" { rows[1]["references"] = [activeOwner] }
      if name == "unordered-records" { rows.reverse() }
      document["records"] = rows; document["selection"] = selection
      let caseName = "tool-ledger-" + name
      if valid.contains(name) {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
        try compareStore(name: caseName, kind: "tool-registry", file: file, read: read)
      } else {
        try compareRefusal(name: caseName, kind: "tool-registry", document: document, file: file, read: read)
      }
    }
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

  func testSessionRuntimeAuditProjection() throws {
    let owner = root.appending(path: "audit-owner")
    let sessions = root.appending(path: "audit-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-audit",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-audit", isPinned: true, expectedGeneration: 1)
    let accepted = ["readonly-hdc", "readonly-arkforge", "capability-hdc", "capability-arkforge", "hdc-label",
      "arkforge-label", "artifact-digest", "maximum-ordinal", "unordered-times", "hdc-cross-branch-field",
      "readonly-declared-compensation", "capability-compensation"]
    let refused = ["missing-audit", "unknown-audit-kind", "extra-audit-field", "missing-audit-field", "empty-reference",
      "invalid-admitted-date", "invalid-valid-until", "empty-reservation", "zero-ordinal", "overflow-ordinal",
      "digest-shape", "artifact-digest-shape", "readonly-consumption", "mutation-with-readonly", "readonly-artifact",
      "label-wrong-provider", "label-wrong-step", "label-without-capability", "unknown-provider", "host-tool-audit",
      "planonly-provider", "simulated-provider", "host-provider-target", "readonly-compensation-mutation", "hdc-extra-field"]
    for name in accepted + refused {
      var step = try HostStoreStepShadowFixtures.step(.probeDevice)
      var provider = name == "readonly-arkforge" || name == "capability-arkforge" ? "arkforge" : "hdc"
      // Closed historical Manifest fields in an isolated directory. No Runtime
      // capability factory, reservation store or Provider is reachable here.
      let sha = JSONValue.string(HostStoreStepShadowFixtures.hash)
      var audit: [String: JSONValue] = ["kind": .string("runtimeCapability"), "reference": .string("fixture-authority"),
        "admittedAtUtc": .string("2026-01-01T00:00:00Z"), "validUntilUtc": .string("2026-01-01T01:00:00Z"),
        "consumptionFingerprintSha256": sha, "reservationId": .string("fixture-reservation"), "useOrdinal": .integer(1),
        "planDigest": sha, "stepSetDigest": sha, "targetBindingDigest": sha, "artifactDigest": .null]
      if name.hasPrefix("readonly-") || ["mutation-with-readonly", "label-without-capability"].contains(name) {
        audit["kind"] = .string("defaultReadOnlyPolicy")
        for key in ["validUntilUtc", "consumptionFingerprintSha256", "reservationId", "useOrdinal", "planDigest", "stepSetDigest", "targetBindingDigest", "artifactDigest"] { audit[key] = .null }
      }
      switch name {
      case "unknown-audit-kind": audit["kind"] = .string("unexpected")
      case "extra-audit-field": audit["extra"] = .bool(true)
      case "missing-audit-field": audit.removeValue(forKey: "artifactDigest")
      case "empty-reference": audit["reference"] = .string("")
      case "invalid-admitted-date": audit["admittedAtUtc"] = .string("2026-02-30T00:00:00Z")
      case "invalid-valid-until": audit["validUntilUtc"] = .string("2026-02-30T00:00:00Z")
      case "empty-reservation": audit["reservationId"] = .string("")
      case "zero-ordinal": audit["useOrdinal"] = .integer(0)
      case "overflow-ordinal": audit["useOrdinal"] = .unsignedInteger(UInt64.max)
      case "maximum-ordinal": audit["useOrdinal"] = .integer(Int64.max)
      case "digest-shape": audit["planDigest"] = .string("invalid")
      case "artifact-digest-shape": audit["artifactDigest"] = .string("invalid")
      case "artifact-digest", "readonly-artifact": audit["artifactDigest"] = sha
      case "unordered-times": audit["validUntilUtc"] = .string("2025-01-01T00:00:00Z")
      case "readonly-consumption": audit["useOrdinal"] = .integer(1)
      case "unknown-provider": provider = "unexpected"
      case "mutation-with-readonly": step = try HostStoreStepShadowFixtures.step(.setParameter)
      case "hdc-label", "label-wrong-provider", "label-without-capability", "label-wrong-step", "arkforge-label":
        let kind: WorkflowStepKind = name == "arkforge-label" ? .flashPartition : name == "label-wrong-step" ? .clearLogBuffer : .runApprovedRemoteMutation
        step = try HostStoreStepShadowFixtures.step(kind)
        if name == "arkforge-label" || name == "label-wrong-provider" { provider = "arkforge" }
        guard case .object(var arguments) = step["arguments"] else { return XCTFail("audit Step fixture") }
        arguments["confirmationId"] = .string(name == "arkforge-label" ? "runtimeE2Admission" : "runtime-capability-admission")
        step["arguments"] = .object(arguments)
        step["argumentsHash"] = .string(SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments))))
      default: break
      }
      var compensations: [JSONValue] = []
      if ["readonly-declared-compensation", "readonly-compensation-mutation", "capability-compensation"].contains(name) {
        let raw = try HostStoreStepShadowFixtures.step(.restoreParameter, id: "comp-shadow")
        var descriptor = Dictionary(uniqueKeysWithValues: ["id", "kind", "effect", "cancellation", "bindingRequirement", "arguments", "argumentsHash"].map { ($0, raw[$0]!) })
        descriptor["trigger"] = .string("onAnyTerminal")
        step["compensationDescriptors"] = .array([.object(descriptor)])
        if name != "readonly-declared-compensation" {
          compensations = [.object(["descriptor": .object(descriptor), "sourceStepId": .string("step-shadow"),
            "disposition": .string("notRun"), "outcomeCertainty": .string("notApplicable"), "result": .string("notRun"),
            "failure": .null, "journalEventIds": .array([])])]
        }
      }
      let data = try SessionStorageFixtures.manifest(sessionID: "session-audit", jobID: "job-session-audit",
        status: name == "planonly-provider" ? "planned" : "succeeded",
        executionMode: name == "planonly-provider" ? "planOnly" : name == "simulated-provider" ? "simulated" : "execute",
        timestamp: "2026-01-01T00:00:00Z", steps: [.object(step)], compensations: compensations)
      guard case .object(var document) = try JSONDecoder().decode(JSONValue.self, from: data) else { return XCTFail("audit manifest fixture") }
      if name == "hdc-extra-field" || name == "hdc-cross-branch-field" {
        guard case .object(var tool) = document["toolchain"] else { return XCTFail("HDC fixture") }
        tool[name == "hdc-extra-field" ? "legacyMetadata" : "profileIdentifier"] = .string("fixture-profile")
        document["toolchain"] = .object(tool)
      } else {
        document["toolchain"] = .object(["kind": .string(name == "host-tool-audit" ? "hostTool" : "runtimeProvider"),
          "providerIdentity": .string(provider), "profileIdentifier": .string("fixture-profile"), "reportedVersion": .string("fixture-version"), "sha256": sha])
        if name != "missing-audit" { document["runtimeAuthority"] = .object(audit) }
        if ["host-tool-audit", "host-provider-target"].contains(name) {
          document["originalTarget"] = .object(["kind": .string("host"), "transport": .string("host"), "connectKey": .null,
            "identitySnapshot": .object(["fixture": .string("host")])])
          document["bindingHistory"] = .array([])
        }
      }
      try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)).write(to: directory.appending(path: "manifest.json"))
      XCTAssertEqual(try store.status().measurementIncomplete, refused.contains(name), name)
      try compareSessionStatus("audit-" + name, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
  }

  func testSessionRecoveryProjection() throws {
    let owner = root.appending(path: "recovery-owner")
    let sessions = root.appending(path: "recovery-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-recovery",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-recovery", isPinned: true, expectedGeneration: 1)
    let base = try RecoveryManifestRecord(needsAttention: true, interruptedReason: "fixture interruption",
      deviceHazards: [try .init(code: "fixture.hazard", summary: "fixture hazard", severity: "possibleBrick", outcomeCertainty: "outcomeUnknown")],
      abandonAuditEventIDs: ["event-abandon"], lastConfirmedStepID: "step-shadow",
      lastDeviceMode: .known(value: "fixture-mode", evidence: "fixture observation"), managedHostProcessState: "notRunning",
      recoveryGuide: try .init(providerIdentity: "fixture-provider", automaticRecoveryAvailable: false,
        summary: "fixture recovery", steps: ["fixture guidance"]), unexecutedCompensations: [],
      userConfirmation: try .init(confirmationID: "confirmation-abandon", confirmedAt: "2026-01-01T00:00:00Z"),
      recoveryOfSessionID: nil, recoveryOfJobID: nil)
    guard case .object(let original) = try JSONDecoder().decode(JSONValue.self, from: RecoveryManifestCodec.encode(base)) else {
      return XCTFail("recovery fixture")
    }
    let processStates = ["notStarted", "notRunning", "stoppedAtSafeBoundary", "stillRunningUnknown", "notApplicable"]
    let accepted = ["interrupted", "failed", "cancelled", "unknown-mode", "guide-automatic", "failed-no-attention",
      "last-confirmed-null", "recovery-of-pair", "unexecuted", "unexecuted-duplicate", "unknown-step"] + processStates
    let refused = ["success-recovery", "planned-recovery", "interrupted-no-audit", "interrupted-no-confirmation",
      "interrupted-no-attention", "interrupted-no-reason", "empty-reason", "missing-key", "extra-key", "duplicate-audit",
      "bad-audit-id", "unknown-last-step", "invalid-recovery-of", "hazard-extra", "hazard-bad-severity",
      "hazard-empty-summary", "device-mode-extra", "device-mode-empty-evidence", "unknown-process", "guide-empty-steps",
      "guide-empty-item", "guide-extra", "confirmation-actor", "confirmation-date", "confirmation-missing-key",
      "undeclared-compensation", "mismatched-compensation", "unexecuted-bad-hash"]
    for name in accepted + refused {
      var recovery = original
      var step = try HostStoreStepShadowFixtures.step(.probeDevice)
      var status = "interrupted"
      var mode = "execute"
      switch name {
      case "failed", "cancelled": status = name
      case "success-recovery": status = "succeeded"
      case "planned-recovery": status = "planned"; mode = "planOnly"
      case "unknown-mode": recovery["lastDeviceMode"] = .object(["state": .string("unknown")])
      case "interrupted-no-audit": recovery["abandonAuditEventIds"] = .array([])
      case "interrupted-no-confirmation": recovery["userConfirmation"] = .null
      case "interrupted-no-attention", "failed-no-attention":
        recovery["needsAttention"] = .bool(false)
        if name == "failed-no-attention" { status = "failed" }
      case "interrupted-no-reason": recovery["interruptedReason"] = .null
      case "empty-reason": recovery["interruptedReason"] = .string("")
      case "missing-key": recovery.removeValue(forKey: "lastConfirmedStepId")
      case "extra-key": recovery["extra"] = .bool(true)
      case "duplicate-audit": recovery["abandonAuditEventIds"] = .array([.string("event-abandon"), .string("event-abandon")])
      case "bad-audit-id": recovery["abandonAuditEventIds"] = .array([.string(" invalid")])
      case "unknown-last-step": recovery["lastConfirmedStepId"] = .string("step-absent")
      case "last-confirmed-null": recovery["lastConfirmedStepId"] = .null
      case "invalid-recovery-of": recovery["recoveryOfSessionId"] = .string(" invalid")
      case "recovery-of-pair": recovery["recoveryOfSessionId"] = .string("session-prior"); recovery["recoveryOfJobId"] = .string("job-prior")
      case "hazard-extra", "hazard-bad-severity", "hazard-empty-summary":
        guard case .array(let hazards) = recovery["deviceHazards"], case .object(var hazard) = hazards[0] else { return XCTFail("hazard fixture") }
        if name == "hazard-extra" { hazard["extra"] = .bool(true) }
        if name == "hazard-bad-severity" { hazard["severity"] = .string("unexpected") }
        if name == "hazard-empty-summary" { hazard["summary"] = .string("") }
        recovery["deviceHazards"] = .array([.object(hazard)])
      case "device-mode-extra": recovery["lastDeviceMode"] = .object(["state": .string("unknown"), "extra": .bool(true)])
      case "device-mode-empty-evidence": recovery["lastDeviceMode"] = .object(["state": .string("known"), "value": .string("mode"), "evidence": .string("")])
      case "unknown-process": recovery["managedHostProcessState"] = .string("unexpected")
      case "guide-automatic", "guide-empty-steps", "guide-empty-item", "guide-extra":
        guard case .object(var guide) = recovery["recoveryGuide"] else { return XCTFail("guide fixture") }
        if name == "guide-automatic" { guide["automaticRecoveryAvailable"] = .bool(true) }
        if name == "guide-empty-steps" { guide["steps"] = .array([]) }
        if name == "guide-empty-item" { guide["steps"] = .array([.string("")]) }
        if name == "guide-extra" { guide["extra"] = .bool(true) }
        recovery["recoveryGuide"] = .object(guide)
      case "confirmation-actor", "confirmation-date", "confirmation-missing-key":
        guard case .object(var confirmation) = recovery["userConfirmation"] else { return XCTFail("confirmation fixture") }
        if name == "confirmation-actor" { confirmation["actor"] = .string("standardAgent") }
        if name == "confirmation-date" { confirmation["confirmedAt"] = .string("2026-02-30T00:00:00Z") }
        if name == "confirmation-missing-key" { confirmation.removeValue(forKey: "actor") }
        recovery["userConfirmation"] = .object(confirmation)
      case "unexecuted", "unexecuted-duplicate", "undeclared-compensation", "mismatched-compensation", "unexecuted-bad-hash":
        let raw = try HostStoreStepShadowFixtures.step(.restoreParameter, id: "comp-shadow")
        var descriptor = Dictionary(uniqueKeysWithValues: ["id", "kind", "effect", "cancellation", "bindingRequirement", "arguments", "argumentsHash"].map { ($0, raw[$0]!) })
        descriptor["trigger"] = .string("onAnyTerminal")
        if name != "undeclared-compensation" { step["compensationDescriptors"] = .array([.object(descriptor)]) }
        if name == "mismatched-compensation" { descriptor["trigger"] = .string("onFailure") }
        if name == "unexecuted-bad-hash" { descriptor["argumentsHash"] = .string(String(repeating: "0", count: 64)) }
        recovery["unexecutedCompensations"] = .array(name == "unexecuted-duplicate" ? [.object(descriptor), .object(descriptor)] : [.object(descriptor)])
      case "unknown-step":
        step["disposition"] = .string("outcomeUnknown")
        step["outcomeCertainty"] = .string("outcomeUnknown")
        step["semanticResult"] = .string("unknown")
        recovery["lastConfirmedStepId"] = .null
      default:
        if processStates.contains(name) { recovery["managedHostProcessState"] = .string(name) }
      }
      let data = try SessionStorageFixtures.manifest(sessionID: "session-recovery", jobID: "job-session-recovery",
        status: status, executionMode: mode, executionAuthority: "interactiveUser", timestamp: "2026-01-01T00:00:00Z",
        steps: [.object(step)], recovery: .object(recovery))
      try data.write(to: directory.appending(path: "manifest.json"))
      XCTAssertEqual(try store.status().measurementIncomplete, refused.contains(name), name)
      try compareSessionStatus("recovery-" + name, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
  }

  func testSessionGraphemeCorpusMatchesActualSwift() throws {
    let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Unicode")
    func compare(_ name: String, _ texts: [String]) throws {
      let input = try JSONEncoder().encode(texts)
      let response = try rust(input, kind: "session-graphemes")
      XCTAssertEqual(response.status, 0, name)
      let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response.output) as? [String: Any])
      let projection = try XCTUnwrap(envelope["projection"] as? [String: [[Int]]])
      let expected = texts.map { $0.map { String($0).utf8.count } }
      let actual = try XCTUnwrap(projection["utf8GraphemeLengths"])
      XCTAssertEqual(actual.count, expected.count)
      for index in expected.indices {
        XCTAssertEqual(actual[index], expected[index], "\(name) vector \(index): \(texts[index].unicodeScalars.map { String($0.value, radix: 16) })")
      }
      try record(name: name, input: input, output: JSONEncoder().encode(expected), outcome: "equal", store: "session-graphemes")
    }
    for (version, count) in [("16.0.0", 1093), ("17.0.0", 766)] {
      let source = try String(contentsOf: fixtures.appending(path: "GraphemeBreakTest-" + version + ".txt"), encoding: .utf8)
      var texts: [String] = []
      for line in source.components(separatedBy: "\n") {
        let data = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let tokens = data.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { continue }
        var value = ""
        for token in tokens where token != "÷" && token != "×" {
          value.unicodeScalars.append(try XCTUnwrap(UInt32(token, radix: 16).flatMap(Unicode.Scalar.init)))
        }
        texts.append(value)
      }
      XCTAssertEqual(texts.count, count)
      // The source corpus supplies inputs; the migration oracle is the actual
      // Swift runtime, whose boundaries differ from either full Unicode version.
      try compare("graphemes-unicode-" + version, texts)
    }
    let properties = try String(contentsOf: fixtures.appending(path: "DerivedCoreProperties-17.0.0.txt"), encoding: .utf8)
    var consonants: [Unicode.Scalar] = []
    var linkers: [Unicode.Scalar] = []
    for line in properties.components(separatedBy: "\n") {
      let data = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
      let fields = data.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      guard fields.count == 3, fields[1] == "InCB", ["Consonant", "Linker"].contains(fields[2]) else { continue }
      let bounds = fields[0].components(separatedBy: "..")
      let first = try XCTUnwrap(UInt32(bounds[0], radix: 16))
      let last = try XCTUnwrap(UInt32(bounds.last!, radix: 16))
      let values = try (first...last).map { try XCTUnwrap(Unicode.Scalar($0)) }
      if fields[2] == "Consonant" { consonants += values } else { linkers += values }
    }
    XCTAssertEqual(consonants.count, 911)
    XCTAssertEqual(linkers.count, 20)
    var texts: [String] = []
    for consonant in consonants {
      for linker in linkers {
        for scalars in [[consonant, linker, consonant], [Unicode.Scalar(0x915)!, linker, consonant],
          [consonant, linker, Unicode.Scalar(0x308)!, consonant]] {
          texts.append(String(String.UnicodeScalarView(scalars)))
        }
      }
    }
    XCTAssertEqual(texts.count, 54_660)
    try compare("graphemes-indic-properties", texts)
  }

  func testSessionStepArgumentBoundaries() throws {
    let owner = root.appending(path: "argument-owner")
    let sessions = root.appending(path: "argument-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-arguments",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-arguments", isPinned: true, expectedGeneration: 1)
    let vectors: [(String, WorkflowStepKind, [String: JSONValue], Bool)] = [
      ("identifier-boundary", .probeDevice, ["evidencePolicy": .string(String(repeating: "a", count: 128))], true),
      ("identifier-overflow", .probeDevice, ["evidencePolicy": .string(String(repeating: "a", count: 129))], false),
      ("scalar-boundary", .setParameter, ["value": .string(String(repeating: "e\u{301}", count: 2048))], true),
      ("scalar-overflow", .setParameter, ["value": .string(String(repeating: "e\u{301}", count: 4096))], false),
      ("relative-unicode-length", .receiveFile, ["localRelativePath": .string(String(repeating: "界", count: 400))], true),
      ("relative-combining-slash", .receiveFile, ["localRelativePath": .string("a/\u{301}b")], false),
      ("relative-prepend-dot", .receiveFile, ["localRelativePath": .string("a\u{600}.")], true),
      ("remote-combining-slash", .sendFile, ["remotePath": .string("/\u{301}a")], false),
      ("remote-prepend-slash", .sendFile, ["remotePath": .string("/a\u{600}/..")], true),
      ("remote-empty-segments", .sendFile, ["remotePath": .string("//")], true),
      ("remote-traversal", .sendFile, ["remotePath": .string("/a/../b")], false),
      ("remote-ascii-control", .sendFile, ["remotePath": .string("/a\n")], false),
      ("remote-c1-control", .sendFile, ["remotePath": .string("/a\u{85}")], true),
      ("optional-hash-null", .sendFile, ["overwritePolicy": .null], false),
      ("optional-generation-null", .probeHDCServer, ["expectedServerGeneration": .null], true),
      ("optional-generation-maximum", .probeHDCServer, ["expectedServerGeneration": .unsignedInteger(UInt64.max)], true),
      ("pointer-null-optionals", .injectPointerInput, ["durationMs": .null, "displayId": .null], true),
      ("swipe-missing-endpoint", .injectPointerInput, ["gesture": .string("swipe")], false),
      ("swipe-boundary", .injectPointerInput, ["gesture": .string("swipe"), "pointerToX": .integer(32767),
        "pointerToY": .integer(0), "durationMs": .integer(80)], true),
      ("swipe-duration-underflow", .injectPointerInput, ["gesture": .string("swipe"), "pointerToX": .integer(1),
        "pointerToY": .integer(1), "durationMs": .integer(79)], false),
      ("options-null-scalar", .postprocessArtifact, ["parameters": .object(["value": .null])], true),
      ("options-null-array", .postprocessArtifact, ["parameters": .object(["value": .array([.null])])], false),
      ("options-array-boundary", .postprocessArtifact, ["parameters": .object(["value": .array(Array(repeating: .bool(true), count: 256))])], true),
      ("options-array-overflow", .postprocessArtifact, ["parameters": .object(["value": .array(Array(repeating: .bool(true), count: 257))])], false),
      ("options-unsafe-key", .postprocessArtifact, ["parameters": .object(["Command": .string("fixture")])], false),
      ("options-nested-object", .postprocessArtifact, ["parameters": .object(["value": .object([:])])], false),
      ("frames-untyped-null", .cleanupOwnedRemotePath, ["framesDirectory": .null], true),
      ("frames-unsafe-key", .cleanupOwnedRemotePath, ["framesDirectory": .object(["shell": .null])], false),
      ("forbidden-action", .enterUpdater, ["providerOperationId": .string("eXeC")], false),
      ("signing-preset-reference", .signWorkspaceOpenHarmonyHap, ["signingPresetRef": .string("preset-fixture")], true),
      ("signing-preset-empty", .signWorkspaceOpenHarmonyHap, ["signingPresetRef": .string("preset-")], false),
      ("diagnostics-id-newline", .captureRemoteStdout, ["actionId": .string("componentDetail"),
        "parameters": .object(["byteBudget": .integer(1024), "windowId": .string("123\r\n"), "componentId": .string("9")])], false),
      ("diagnostics-id-overflow", .captureRemoteStdout, ["actionId": .string("componentDetail"),
        "parameters": .object(["byteBudget": .integer(1024), "windowId": .string(String(repeating: "1", count: 21)), "componentId": .string("9")])], false),
      ("diagnostics-fault-newline", .captureRemoteStdout, ["actionId": .string("crashLog"),
        "parameters": .object(["byteBudget": .integer(1024), "faultLogName": .string("cppcrash-fixture\n")])], false),
      ("diagnostics-fault-path", .captureRemoteStdout, ["actionId": .string("crashLog"),
        "parameters": .object(["byteBudget": .integer(1024), "faultLogName": .string("cppcrash-../fixture")])], false),
      ("diagnostics-hilog", .captureRemoteStdout, ["actionId": .string("boundedHilog"),
        "parameters": .object(["byteBudget": .integer(1024), "durationSeconds": .integer(600), "filters": .array([.string("tag:*")])])], true),
      ("diagnostics-hilog-filter", .captureRemoteStdout, ["actionId": .string("boundedHilog"),
        "parameters": .object(["byteBudget": .integer(1024), "durationSeconds": .integer(600), "filters": .array([.string("tag\n")])])], false),
      ("argument-extra-field", .probeDevice, ["extra": .bool(true)], false),
    ]
    for (name, kind, changes, accepted) in vectors {
      var step = try HostStoreStepShadowFixtures.step(kind)
      var arguments = HostStoreStepShadowFixtures.arguments(kind)
      arguments.merge(changes) { _, new in new }
      step["arguments"] = .object(arguments)
      step["argumentsHash"] = .string(SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments))))
      let data = try SessionStorageFixtures.manifest(sessionID: "session-arguments", jobID: "job-session-arguments",
        executionMode: "execute", executionAuthority: "interactiveUser", timestamp: "2026-01-01T00:00:00Z",
        steps: [.object(step)], confirmations: HostStoreStepShadowFixtures.confirmations(step))
      try data.write(to: directory.appending(path: "manifest.json"))
      XCTAssertEqual(try store.status().measurementIncomplete, !accepted, name)
      try compareSessionStatus("argument-" + name, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
  }

  func testSessionCompensationProjection() throws {
    let owner = root.appending(path: "compensation-owner")
    let sessions = root.appending(path: "compensation-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-compensations",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-compensations", isPinned: true, expectedGeneration: 1)
    let accepted = ["executed", "with-step", "executed-failed", "unknown-result", "not-run"]
    let refused = ["step-trigger-mismatch", "undeclared-step", "duplicate-descriptor", "duplicate-record",
      "unknown-source", "hash-mismatch", "record-mismatch", "missing-failure", "not-run-with-failure"]
    for kind in CompensationDescriptor.allowedKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
      let compensationStep = try HostStoreStepShadowFixtures.step(kind, id: "comp-shadow")
      var descriptor = Dictionary(uniqueKeysWithValues: ["id", "kind", "effect", "cancellation",
        "bindingRequirement", "arguments", "argumentsHash"].map { ($0, compensationStep[$0]!) })
      descriptor["trigger"] = .string("onAnyTerminal")
      for variant in accepted + refused {
        var source = try HostStoreStepShadowFixtures.step(.probeDevice)
        source["compensationDescriptors"] = .array([.object(descriptor)])
        var record: [String: JSONValue] = ["descriptor": .object(descriptor), "sourceStepId": .string("step-shadow"),
          "disposition": .string("executed"), "outcomeCertainty": .string("confirmed"), "result": .string("succeeded"),
          "failure": .null, "journalEventIds": .array([.string("event-shadow")])]
        var execution = compensationStep
        execution["sourceStepId"] = .string("step-shadow")
        execution["compensationTrigger"] = .string("onAnyTerminal")
        var steps: [JSONValue] = []
        let failure: JSONValue = .object(["stage": .string("restore"), "code": .string("restore.failed"), "summary": .string("fixture failure")])
        switch variant {
        case "with-step": steps = [.object(execution)]
        case "step-trigger-mismatch":
          execution["compensationTrigger"] = .string("onFailure")
          steps = [.object(execution)]
        case "undeclared-step":
          execution["id"] = .string("comp-undeclared")
          steps = [.object(execution)]
        case "duplicate-descriptor": source["compensationDescriptors"] = .array([.object(descriptor), .object(descriptor)])
        case "unknown-source": record["sourceStepId"] = .string("step-absent")
        case "hash-mismatch", "record-mismatch":
          var changed = descriptor
          changed[variant == "hash-mismatch" ? "argumentsHash" : "trigger"] = .string(variant == "hash-mismatch" ? String(repeating: "0", count: 64) : "onFailure")
          record["descriptor"] = .object(changed)
        case "executed-failed", "missing-failure":
          record["result"] = .string("failed")
          if variant == "executed-failed" { record["failure"] = failure }
        case "unknown-result":
          record["disposition"] = .string("outcomeUnknown")
          record["outcomeCertainty"] = .string("outcomeUnknown")
          record["result"] = .string("unknown")
        case "not-run", "not-run-with-failure":
          record["disposition"] = .string("notRun")
          record["outcomeCertainty"] = .string("notApplicable")
          record["result"] = .string("notRun")
          if variant == "not-run-with-failure" { record["failure"] = failure }
        default: break
        }
        steps.insert(.object(source), at: 0)
        let records: [JSONValue] = variant == "duplicate-record" ? [.object(record), .object(record)] : [.object(record)]
        let data = try SessionStorageFixtures.manifest(sessionID: "session-compensations", jobID: "job-session-compensations",
          status: ["executed-failed", "missing-failure", "unknown-result"].contains(variant) ? "failed" : "succeeded",
          executionMode: "execute", executionAuthority: "interactiveUser", timestamp: "2026-01-01T00:00:00Z",
          steps: steps, compensations: records)
        try data.write(to: directory.appending(path: "manifest.json"))
        let name = "compensation-" + kind.rawValue + "-" + variant
        XCTAssertEqual(try store.status().measurementIncomplete, refused.contains(variant), name)
        try compareSessionStatus(name, store: store,
          config: owner.appending(path: "session-storage.json"), sessions: sessions)
      }
    }
  }

  func testSessionStepSemanticBoundaries() throws {
    let owner = root.appending(path: "semantics-owner")
    let sessions = root.appending(path: "semantics-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-semantics",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    let variants = ["valid", "effect-understated", "cancellation-understated", "binding-understated",
      "unknown-kind", "unknown-effect", "unknown-cancellation", "unknown-binding", "unknown-disposition",
      "unknown-certainty", "unknown-result", "executed-not-run", "skipped-confirmed", "skipped-valid",
      "unknown-terminal", "failed-success", "failed-failed", "missing-binding", "unknown-binding-revision",
      "negative-duration", "maximum-duration", "null-duration", "overflow-exit", "minimum-exit",
      "source-without-trigger", "trigger-without-source", "duplicate-step", "standard-executed",
      "standard-skipped-success", "standard-skipped-cancelled", "plan-executed", "plan-skipped"]
    for variant in variants {
      var step = try HostStoreStepShadowFixtures.step(.flashPartition)
      var status = "succeeded"
      var mode = "execute"
      var authority = "interactiveUser"
      switch variant {
      case "effect-understated": step["effect"] = .string("deviceMutation")
      case "cancellation-understated": step["cancellation"] = .string("immediate")
      case "binding-understated": step["bindingRequirement"] = .string("none"); step["bindingRevision"] = .null
      case "unknown-kind": step["kind"] = .string("unknown")
      case "unknown-effect": step["effect"] = .string("unknown")
      case "unknown-cancellation": step["cancellation"] = .string("unknown")
      case "unknown-binding": step["bindingRequirement"] = .string("unknown")
      case "unknown-disposition": step["disposition"] = .string("unknown")
      case "unknown-certainty": step["outcomeCertainty"] = .string("unknown")
      case "unknown-result": step["semanticResult"] = .string("other")
      case "executed-not-run": step["semanticResult"] = .string("notRun")
      case "skipped-confirmed": step["disposition"] = .string("skipped")
      case "unknown-terminal":
        step["disposition"] = .string("outcomeUnknown")
        step["outcomeCertainty"] = .string("outcomeUnknown"); step["semanticResult"] = .string("unknown")
      case "failed-success", "failed-failed":
        step["semanticResult"] = .string("failed")
        if variant == "failed-failed" { status = "failed" }
      case "missing-binding": step["bindingRevision"] = .null
      case "unknown-binding-revision": step["bindingRevision"] = .integer(2)
      case "negative-duration": step["durationNanoseconds"] = .integer(-1)
      case "maximum-duration": step["durationNanoseconds"] = .integer(Int64.max)
      case "null-duration": step["durationNanoseconds"] = .null
      case "overflow-exit": step["exitCode"] = .unsignedInteger(UInt64.max)
      case "minimum-exit": step["exitCode"] = .integer(Int64.min)
      case "source-without-trigger": step["sourceStepId"] = .string("source")
      case "trigger-without-source": step["compensationTrigger"] = .string("onFailure")
      default: break
      }
      if variant.hasPrefix("standard-") { authority = "standardAgent" }
      if variant == "standard-skipped-cancelled" { status = "cancelled" }
      if variant.hasPrefix("plan-") { mode = "planOnly"; status = "planned" }
      if ["skipped-valid", "standard-skipped-success", "standard-skipped-cancelled", "plan-skipped"].contains(variant) {
        step["disposition"] = .string("skipped")
        step["outcomeCertainty"] = .string("notApplicable"); step["semanticResult"] = .string("notRun")
      }
      let rows: [JSONValue] = variant == "duplicate-step" ? [.object(step), .object(step)] : [.object(step)]
      let data = try SessionStorageFixtures.manifest(sessionID: "session-semantics", jobID: "job-session-semantics",
        status: status, executionMode: mode, executionAuthority: authority, timestamp: "2026-01-01T00:00:00Z",
        steps: rows, confirmations: HostStoreStepShadowFixtures.confirmations(step))
      try data.write(to: directory.appending(path: "manifest.json"))
      let accepted = ["valid", "skipped-valid", "failed-failed", "maximum-duration", "null-duration", "minimum-exit",
        "standard-skipped-cancelled", "plan-skipped"].contains(variant)
      XCTAssertEqual(try store.status().measurementIncomplete, !accepted, variant)
      try compareSessionStatus("semantics-" + variant, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
  }

  func testSessionEveryStepKindProjection() throws {
    let owner = root.appending(path: "step-owner")
    let sessions = root.appending(path: "step-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-steps",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-steps", isPinned: true, expectedGeneration: 1)
    for kind in WorkflowStepKind.allCases {
      let original = try HostStoreStepShadowFixtures.step(kind)
      let confirmations = HostStoreStepShadowFixtures.confirmations(original)
      for variant in ["valid", "extra-field", "missing-argument", "wrong-hash"] {
        var step = original
        switch variant {
        case "extra-field": step["extra"] = .bool(true)
        case "missing-argument":
          guard case .object(var arguments) = step["arguments"] else { return XCTFail("fixture arguments") }
          let key = try XCTUnwrap(WorkflowStepRegistry.metadata(for: kind).requiredArgumentKeys.sorted().first)
          arguments.removeValue(forKey: key)
          step["arguments"] = .object(arguments)
          step["argumentsHash"] = .string(SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments))))
        case "wrong-hash": step["argumentsHash"] = .string(String(repeating: "0", count: 64))
        default: break
        }
        let data = try SessionStorageFixtures.manifest(sessionID: "session-steps", jobID: "job-session-steps",
          executionMode: "execute", executionAuthority: "interactiveUser", timestamp: "2026-01-01T00:00:00Z",
          steps: [.object(step)], confirmations: confirmations)
        try data.write(to: directory.appending(path: "manifest.json"))
        let name = "step-" + kind.rawValue + "-" + variant
        XCTAssertEqual(try store.status().measurementIncomplete, variant != "valid", name)
        try compareSessionStatus(name, store: store,
          config: owner.appending(path: "session-storage.json"), sessions: sessions)
      }
    }
  }

  func testSessionConfirmationProjection() throws {
    let owner = root.appending(path: "confirmation-owner")
    let sessions = root.appending(path: "confirmation-sessions")
    let store = try RuntimeSessionStorageStore(ownerRoot: owner, defaultSessionsRoot: sessions)
    _ = try store.updatePolicy(.init(totalQuotaBytes: 1_000_000, safetyMarginBytes: 100,
      retentionDays: 7), expectedGeneration: 1)
    let directory = try seedShadowSession(sessions: sessions, month: "01", id: "session-confirmations",
      timestamp: "2026-01-01T00:00:00Z")
    let catalog = try SessionRetentionCatalog(sessionsRoot: sessions)
    try catalog.registerFinalizedSession(sessionRoot: directory, retentionDays: 7, policyGeneration: 2)
    _ = try catalog.updatePin(sessionID: "session-confirmations", isPinned: true, expectedGeneration: 1)
    let file = directory.appending(path: "manifest.json")
    let original = try Data(contentsOf: file)
    let accepted = ["deviceMutation", "destructive", "serverLifecycle", "recoveryAbandon", "securityBoundary", "rejected"]
    let refused = ["unknown-kind", "unknown-decision", "unknown-actor", "actor-extra-field",
      "extra-field", "invalid-id", "invalid-hash", "invalid-date", "unknown-step", "duplicate-id"]
    for name in accepted + refused {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var confirmation: [String: Any] = ["confirmationId": "confirmation-shadow", "kind": "securityBoundary",
        "scopeHash": String(repeating: "a", count: 64), "decision": "accepted",
        "actor": ["kind": "interactiveUser"], "decidedAt": "2026-01-01T00:00:00Z", "relatedStepIds": []]
      switch name {
      case "deviceMutation", "destructive", "serverLifecycle", "recoveryAbandon", "securityBoundary":
        confirmation["kind"] = name
      case "rejected": confirmation["decision"] = "rejected"
      case "unknown-kind": confirmation["kind"] = "unexpected"
      case "unknown-decision": confirmation["decision"] = "unexpected"
      case "unknown-actor": confirmation["actor"] = ["kind": "standardAgent"]
      case "actor-extra-field": confirmation["actor"] = ["kind": "interactiveUser", "extra": true]
      case "extra-field": confirmation["extra"] = true
      case "invalid-id": confirmation["confirmationId"] = " invalid"
      case "invalid-hash": confirmation["scopeHash"] = String(repeating: "g", count: 64)
      case "invalid-date": confirmation["decidedAt"] = "2026-02-30T00:00:00Z"
      case "unknown-step": confirmation["relatedStepIds"] = ["step-absent"]
      default: break
      }
      document["confirmations"] = name == "duplicate-id" ? [confirmation, confirmation] : [confirmation]
      try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
      XCTAssertEqual(try store.status().measurementIncomplete, refused.contains(name), name)
      try compareSessionStatus("confirmation-" + name, store: store,
        config: owner.appending(path: "session-storage.json"), sessions: sessions)
    }
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
      "hangul": "\u{1100}\u{1161}\u{11A8}", "indic": "\u{0915}\u{094D}\u{0937}", "skin-tone": "👍🏽", "prepend": "\u{600}a"]
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

  private func compareRegistrySemantics(
    prefix: String, kind: String, file: URL, read: () throws -> JSONValue
  ) throws {
    let original = try Data(contentsOf: file)
    let tool = prefix == "tool"
    let common = ["duplicate-record", "reference-prefix", "digest-uppercase", "digest-mismatch", "negative-bytes",
      "oversize-bytes", "invalid-time", "time-overflow", "unknown-state", "available-generation", "removed-generation",
      "removed-owners", "unknown-owner", "invalid-owner", "duplicate-owner", "too-many-owners", "schema-unknown"]
    let specific = tool ? ["zero-bytes", "executable-digest", "quarantine-digest", "trust-unknown", "trust-empty-identifier",
      "trust-long-team", "trust-control", "trust-unsigned-metadata", "trust-digest", "dependency-name", "dependency-digest",
      "dependency-zero", "dependency-oversize", "dependency-quarantine", "dependency-trust", "dependency-duplicate",
      "selection-zero", "selection-no-owner", "selection-unknown-tool", "selection-schema-one", "selection-pending-self",
      "selection-outcome-self", "selection-extra"]
      : ["zero-entries", "oversize-entries", "version-empty", "version-overflow", "version-control", "version-nonascii"]
    for name in common + specific {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var rows = try XCTUnwrap(document["records"] as? [[String: Any]])
      var row = rows[0]
      let digestKey = tool ? "contentDigest" : "digest"
      let timeKey = tool ? "registeredAt" : "registeredAtUTC"
      let owner: [String: Any] = ["kind": "job", "id": "fixture-owner"]
      switch name {
      case "reference-prefix": row["reference"] = "unknown:sha256:" + String(repeating: "a", count: 64)
      case "digest-uppercase": row[digestKey] = String(repeating: "A", count: 64)
      case "digest-mismatch": row[digestKey] = String(repeating: "0", count: 64)
      case "negative-bytes": row["byteCount"] = -1
      case "zero-bytes": row["byteCount"] = 0
      case "oversize-bytes": row["byteCount"] = tool ? 268_435_457 : 1_073_741_825
      case "invalid-time": row[timeKey] = "invalid"
      case "time-overflow": row[timeKey] = "2026-09-10T01:02:03Z" + String(repeating: " ", count: 33)
      case "unknown-state": row["state"] = "unknown"
      case "available-generation": row["generation"] = 2
      case "removed-generation": row["state"] = "removed"
      case "removed-owners": row["state"] = "removed"; row["generation"] = 2; row["references"] = [owner]
      case "unknown-owner": row["references"] = [["kind": "unknown", "id": "fixture-owner"]]
      case "invalid-owner": row["references"] = [["kind": "job", "id": "contains:colon"]]
      case "duplicate-owner": row["references"] = [owner, owner]
      case "too-many-owners": row["references"] = (0...1024).map { ["kind": "job", "id": "owner-\($0)"] }
      case "schema-unknown": document["schemaVersion"] = "unknown"
      case "zero-entries": row["entryCount"] = 0
      case "oversize-entries": row["entryCount"] = 4097
      case "version-empty": row["version"] = ""
      case "version-overflow": row["version"] = String(repeating: "a", count: 129)
      case "version-control": row["version"] = "1\n"
      case "version-nonascii": row["version"] = "版本"
      case "executable-digest": row["executableSHA256"] = "invalid"
      case "quarantine-digest": row["quarantineSHA256"] = "invalid"
      default: break
      }
      if name.hasPrefix("trust-") {
        var trust = try XCTUnwrap(row["trust"] as? [String: Any])
        switch name {
        case "trust-unknown": trust["signature"] = "unknown"
        case "trust-empty-identifier": trust["identifier"] = ""
        case "trust-long-team": trust["teamIdentifier"] = String(repeating: "a", count: 257)
        case "trust-control": trust["identifier"] = "line\n"
        case "trust-unsigned-metadata": trust = ["signature": "unsigned", "identifier": "unexpected"]
        case "trust-digest": trust["codeDirectorySHA256"] = "invalid"
        default: break
        }
        row["trust"] = trust
      }
      if name.hasPrefix("dependency-") {
        var dependency: [String: Any] = ["name": "libusb_shared.dylib", "sha256": String(repeating: "a", count: 64),
          "byteCount": 1, "trust": ["signature": "unsigned"]]
        switch name {
        case "dependency-name": dependency["name"] = "other.dylib"
        case "dependency-digest": dependency["sha256"] = "invalid"
        case "dependency-zero": dependency["byteCount"] = 0
        case "dependency-oversize": dependency["byteCount"] = 33_554_433
        case "dependency-quarantine": dependency["quarantineSHA256"] = "invalid"
        case "dependency-trust": dependency["trust"] = ["signature": "invalid"]
        default: break
        }
        row["dependencies"] = name == "dependency-duplicate" ? [dependency, dependency] : [dependency]
      }
      if name.hasPrefix("selection-") {
        let reference = try XCTUnwrap(row["reference"] as? String)
        row["references"] = [["kind": "activeSelection", "id": "runtime-hdc-selection"]]
        var selection: [String: Any] = ["activeToolRef": reference, "activeGeneration": 1]
        switch name {
        case "selection-zero": selection["activeGeneration"] = 0
        case "selection-no-owner": row["references"] = [] as [[String: Any]]
        case "selection-unknown-tool": selection["activeToolRef"] = "tool:sha256:" + String(repeating: "0", count: 64)
        case "selection-schema-one": document["schemaVersion"] = "arkdeck.bootstrap-tools/1"
        case "selection-pending-self": selection["pending"] = ["actionID": "fixture-action", "oldToolRef": reference,
          "newToolRef": reference, "expectedActiveGeneration": 1]
        case "selection-outcome-self": selection["lastOutcome"] = ["actionID": "fixture-action", "oldToolRef": reference,
          "newToolRef": reference, "activeGeneration": 1, "result": "succeeded"]
        case "selection-extra": selection["extra"] = true
        default: break
        }
        document["selection"] = selection
      }
      rows[0] = row
      if name == "duplicate-record" { rows.append(row) }
      document["records"] = rows
      try compareRefusal(name: prefix + "-semantics-" + name, kind: kind, document: document, file: file, read: read)
    }
    // Date acceptance is exercised through the actual legacy Foundation reader.
    for (index, timestamp) in ["2026-09-10T01:02:03+08:00", "2026-09-10T01:02:03Z", "2026-09-10T01:02:03Ztail"].enumerated() {
      var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
      var rows = try XCTUnwrap(document["records"] as? [[String: Any]])
      rows[0][tool ? "registeredAt" : "registeredAtUTC"] = timestamp
      document["records"] = rows
      try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
      try compareStore(name: prefix + "-date-accepted-" + String(index), kind: kind, file: file, read: read)
    }
    if tool {
      for variant in ["legacy-schema", "selection", "maximum-selection-generation"] {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        if variant == "legacy-schema" { document["schemaVersion"] = "arkdeck.bootstrap-tools/1" }
        else {
          var rows = try XCTUnwrap(document["records"] as? [[String: Any]])
          rows[0]["references"] = [["kind": "activeSelection", "id": "runtime-hdc-selection"]]
          document["records"] = rows
          document["selection"] = ["activeToolRef": rows[0]["reference"]!,
            "activeGeneration": variant == "maximum-selection-generation" ? UInt64.max : 1]
        }
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
        try compareStore(name: "tool-" + variant, kind: kind, file: file, read: read)
      }
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
