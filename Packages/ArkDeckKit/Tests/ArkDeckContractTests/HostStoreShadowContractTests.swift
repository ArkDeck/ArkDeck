import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkDeckBootstrap

/// The real Swift store writes isolated host fixtures; the Rust candidate only
/// receives snapshot bytes over stdin. No installed daemon, target or Runtime
/// state is used. Each comparison checks both durable bytes and read projection.
final class HostStoreShadowContractTests: XCTestCase {
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

  private func rust(_ input: Data, kind: String = "history-filter") throws -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = binary
    process.arguments = [kind]
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
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: URL(filePath: path).appending(path: name + ".json"), options: .withoutOverwriting)
  }
}
