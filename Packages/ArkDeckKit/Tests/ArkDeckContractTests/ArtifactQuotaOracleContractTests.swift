// Shared Swift oracle for the Rust Artifact quota reader (CHG-2026-074, TASK-XPA-013).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `artifact.quota`: the oracle `rust/crates/arkdeck-hoststore/tests/
/// artifact_quota.rs` replays against the Rust Artifact quota reader.
///
/// Each scenario is one Artifact root. `published` is written by the Swift
/// `RuntimeArtifactStore` through its public API: published and missing
/// Artifacts of two Jobs, beside the Import owner's directory and a cleanup
/// ledger the walk skips. The others are that root with one change each: a
/// stray, linked or dotted root entry, a Job without an index, an index that
/// is empty, linked, dangling, a directory, of another schema, holding a
/// member the model lacks, a negative count on a missing row, a duplicate,
/// foreign or unsafe identity, a mistyped, absent or ambiguous member, and a
/// published payload that is absent, linked, unreadable, resized, rewritten
/// or no longer sealed. A store opened afresh over the scenario's root, so
/// its used-bytes cache is empty, answers `artifact.quota` through the
/// control plane. The oracle keeps each root's files as the read found them
/// (without the payload-verification caches, whose fingerprints are machine
/// facts), the kind and mode of every entry before and after the read, and
/// every answer, the root's directory spelled `<root>` where an answer names
/// it.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARTIFACT_QUOTA_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArtifactQuotaOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/artifact-quota", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let home = "/private/tmp/arkdeck-artifact-quota-oracle/home"
  private static let rootLabel = "<root>"
  private static let verificationCache = ".payload-verification-v1.json"
  private static let jobA = "job-oracle-a"
  private static let jobB = "job-oracle-b"
  private static let binding = ArtifactBindingSnapshot(
    targetID: "TGT-ORACLE", bindingRevision: nil, stableIdentitySHA256: nil)

  func testSwiftAnswersTheSharedArtifactQuotaOracle() async throws {
    let manager = FileManager.default
    let run = manager.temporaryDirectory.appending(
      path: "arkdeck-artifact-quota-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
    let stores = run.appending(path: "stores", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: stores, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: run) }

    let scenarios = try await Self.scenarios(in: stores)
    let published = stores.appending(path: "published", directoryHint: .isDirectory)
    // Every root as it stands before any read, since a read may reseal
    // payloads and write a verification cache.
    var befores: [String: (tree: JSONValue, contents: [String: Data])] = [:]
    for name in scenarios {
      let root = stores.appending(path: name, directoryHint: .isDirectory)
      try Self.forgetVerifications(in: root)
      befores[name] = try Self.entries(of: root, fallback: published)
    }

    var files: [String: Data] = [:]
    var cases: [JSONValue] = []
    var trees: [String: JSONValue] = [:]
    for name in scenarios {
      let root = stores.appending(path: name, directoryHint: .isDirectory)
      let before = try XCTUnwrap(befores[name])
      for (path, data) in before.contents {
        files["stores/\(name)/\(path)"] = data
      }
      let handler = try Self.handler(
        over: root,
        state: run.appending(path: "engines/\(name)", directoryHint: .isDirectory))
      let response = try await Self.send(handler, "artifact.quota", [:])
      let after = try Self.entries(of: root, fallback: published)
      trees[name] = .object(["before": before.tree, "after": after.tree])
      cases.append(
        .object([
          "scenario": .string(name), "response": Self.labelled(response, root: root),
        ]))
    }
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    files["cases.json"] = try encoder.encode(JSONValue.array(cases))
    files["tree.json"] = try encoder.encode(JSONValue.object(trees))
    files["provenance.json"] = try encoder.encode(
      JSONValue.object([
        "recordedBy": .string(
          "ArtifactQuotaOracleContractTests.testSwiftAnswersTheSharedArtifactQuotaOracle"),
        "nowUTC": .string(Self.nowUTC),
        "home": .string(Self.home),
        "rootLabel": .string(Self.rootLabel),
        "quotaBytes": .integer(Int64(ArtifactQuota().totalBytes)),
      ]))
    try Self.recordOrCompare(
      files, oracle: Self.oracle, variable: "ARKDECK_RUST_ARTIFACT_QUOTA_RECORD")
  }

  // MARK: - Scenarios

  private static func scenarios(in stores: URL) async throws -> [String] {
    var names: [String] = []
    func store(_ name: String) throws -> RuntimeArtifactStore {
      try RuntimeArtifactStore(
        rootURL: stores.appending(path: name, directoryHint: .isDirectory),
        quota: ArtifactQuota(), redaction: ArtifactRedactionPolicy(homeDirectory: home),
        nowUTC: { ArtifactQuotaOracleContractTests.nowUTC })
    }

    // A root the store created, with nothing in it.
    _ = try store("empty")
    names.append("empty")

    let base = try store("published")
    _ = try await base.publish(
      request(
        jobA, "hilog.txt", "I/oracle: the first line\nI/oracle: the second line\n",
        mediaType: "text/plain"))
    _ = try await base.publish(
      request(
        jobA, "crash-signature.json", "{\"schemaVersion\":\"1.0.0\",\"signature\":\"oracle\"}\n",
        mediaType: "application/json"))
    _ = try await base.recordMissing(
      jobID: jobA, sessionID: "session-\(jobA)", stepID: "step-1", name: "screenshot.png",
      mediaType: "image/png", privacy: .standard, retentionClass: .default,
      sourceOperation: "capture.screen-sequence@1", providerID: "hdc", bindingSnapshot: binding,
      reason: "the device refused the capture")
    _ = try await base.publish(
      request(
        jobB, "trace-note.txt", "trace oracle\n", mediaType: "text/plain", privacy: .sensitive,
        window: ArtifactObservationWindow(
          startUTC: "2026-09-13T23:59:58.000Z", endUTC: "2026-09-13T23:59:59.500Z")))
    let published = stores.appending(path: "published", directoryHint: .isDirectory)
    try makeDirectory(published.appending(path: ".imports-v1/records", directoryHint: .isDirectory))
    try write(Data("{}\n".utf8), to: published.appending(path: "cleanup-debt.json"))
    names.append("published")

    let firstPayload = try artifactID(row: 0, in: published.appending(path: "\(jobA)/index.json"))
    func variant(_ name: String, _ edit: (URL) throws -> Void) throws {
      let root = stores.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.copyItem(at: published, to: root)
      try edit(root)
      names.append(name)
    }
    func index(_ root: URL) -> URL { root.appending(path: "\(jobA)/index.json") }
    func payload(_ root: URL) -> URL { root.appending(path: "\(jobA)/\(firstPayload)") }

    try variant("strayFile") { try write(Data("stray\n".utf8), to: $0.appending(path: "notes.txt")) }
    try variant("linkedJob") { root in
      try FileManager.default.createSymbolicLink(
        atPath: root.appending(path: "job-link").path, withDestinationPath: jobA)
    }
    try variant("dotDirectory") {
      try makeDirectory($0.appending(path: ".cache", directoryHint: .isDirectory))
    }
    try variant("jobWithoutIndex") {
      try makeDirectory($0.appending(path: "job-oracle-c", directoryHint: .isDirectory))
    }
    try variant("emptyIndex") { try write(Data(), to: index($0)) }
    try variant("linkedIndex") { root in
      try FileManager.default.moveItem(
        at: index(root), to: root.appending(path: "\(jobA)/index-copy.json"))
      try FileManager.default.createSymbolicLink(
        atPath: index(root).path, withDestinationPath: "index-copy.json")
    }
    try variant("danglingIndexLink") { root in
      try FileManager.default.removeItem(at: index(root))
      try FileManager.default.createSymbolicLink(
        atPath: index(root).path, withDestinationPath: "absent.json")
    }
    try variant("indexDirectory") { root in
      try FileManager.default.removeItem(at: index(root))
      try makeDirectory(index(root))
    }
    try variant("unsupportedSchema") {
      try editIndex(index($0)) { $0["schemaVersion"] = .string("2.0.0") }
    }
    try variant("unknownRowMember") {
      try editIndex(index($0)) { try row(0, of: &$0) { $0["retired"] = .bool(true) } }
    }
    try variant("negativeMissingCount") {
      try editIndex(index($0)) { try row(2, of: &$0) { $0["byteCount"] = .integer(-5) } }
    }
    try variant("duplicateIdentity") {
      try editIndex(index($0)) { try row(1, of: &$0) { $0["artifactID"] = .string(firstPayload) } }
    }
    try variant("foreignJob") {
      try editIndex(index($0)) { try row(0, of: &$0) { $0["jobID"] = .string(jobB) } }
    }
    try variant("unsafeIdentity") {
      try editIndex(index($0)) { try row(0, of: &$0) { $0["artifactID"] = .string("ART-NOT-SAFE") } }
    }
    // Only the row names the identity: Swift refuses it before it opens any
    // payload of the row, and a payload whose name ends in a line terminator
    // could not be checked out on Windows.
    try variant("trailingNewlineIdentity") { root in
      try editIndex(index(root)) {
        try row(0, of: &$0) { $0["artifactID"] = .string(firstPayload + "\n") }
      }
    }
    try variant("wrongMemberType") {
      try editIndex(index($0)) { try row(0, of: &$0) { $0["byteCount"] = .string("40") } }
    }
    try variant("missingMember") {
      try editIndex(index($0)) { try row(0, of: &$0) { $0["sha256"] = nil } }
    }
    try variant("ambiguousStatus") {
      try editIndex(index($0)) {
        try row(0, of: &$0) {
          $0["status"] = .object([
            "published": .object([:]), "missing": .object(["reason": .string("both")]),
          ])
        }
      }
    }
    try variant("unknownStatus") {
      try editIndex(index($0)) {
        try row(0, of: &$0) { $0["status"] = .object(["lost": .object([:])]) }
      }
    }
    try variant("missingPayload") { try FileManager.default.removeItem(at: payload($0)) }
    try variant("linkedPayload") { root in
      try FileManager.default.moveItem(
        at: payload(root), to: root.appending(path: "\(jobA)/payload-copy"))
      try FileManager.default.createSymbolicLink(
        atPath: payload(root).path, withDestinationPath: "payload-copy")
    }
    try variant("unreadablePayload") { try chmod(payload($0), 0o000) }
    try variant("resizedPayload") { root in
      try chmod(payload(root), 0o600)
      let handle = try FileHandle(forWritingTo: payload(root))
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("!".utf8))
      try handle.close()
      try chmod(payload(root), 0o400)
    }
    try variant("rewrittenPayload") { root in
      try chmod(payload(root), 0o600)
      var bytes = try Data(contentsOf: payload(root))
      bytes[0] = bytes[0] == UInt8(ascii: "X") ? UInt8(ascii: "Y") : UInt8(ascii: "X")
      let handle = try FileHandle(forWritingTo: payload(root))
      try handle.write(contentsOf: bytes)
      try handle.close()
      try chmod(payload(root), 0o400)
    }
    try variant("unsealedPayload") { try chmod(payload($0), 0o644) }
    return names
  }

  private static func request(
    _ job: String, _ name: String, _ text: String, mediaType: String,
    privacy: CatalogArtifactPrivacy = .standard, window: ArtifactObservationWindow? = nil
  ) -> RuntimeArtifactPublicationRequest {
    RuntimeArtifactPublicationRequest(
      jobID: job, sessionID: "session-\(job)", stepID: "step-1", name: name, mediaType: mediaType,
      privacy: privacy, retentionClass: .default,
      sourceOperation: "analyzer.extract-crash-signature@1", providerID: "host",
      bindingSnapshot: binding, contents: Data(text.utf8), observationWindow: window)
  }

  // MARK: - Root edits

  /// Writes a store file as the store does: private to its owner.
  private static func write(_ data: Data, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private static func chmod(_ url: URL, _ mode: mode_t) throws {
    guard Darwin.chmod(url.path, mode) == 0 else { throw POSIXError(.EPERM) }
  }

  private static func artifactID(row index: Int, in url: URL) throws -> String {
    let document = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    guard case .array(let rows)? = document["artifacts"], rows.indices.contains(index),
      case .object(let row) = rows[index], case .string(let id)? = row["artifactID"]
    else { throw CocoaError(.coderInvalidValue) }
    return id
  }

  /// Re-encodes an index after `edit`, as a canonical pretty document.
  private static func editIndex(
    _ url: URL, _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    var document = try JSONDecoder().decode(
      [String: JSONValue].self, from: Data(contentsOf: url))
    try edit(&document)
    try write(try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object(document)), to: url)
  }

  private static func row(
    _ index: Int, of document: inout [String: JSONValue],
    _ edit: (inout [String: JSONValue]) throws -> Void
  ) throws {
    guard case .array(var rows)? = document["artifacts"], rows.indices.contains(index),
      case .object(var row) = rows[index]
    else { throw CocoaError(.coderInvalidValue) }
    try edit(&row)
    rows[index] = .object(row)
    document["artifacts"] = .array(rows)
  }

  /// Removes every Job's payload-verification cache: its fingerprints are
  /// this machine's inodes and times.
  private static func forgetVerifications(in root: URL) throws {
    let manager = FileManager.default
    for name in try manager.contentsOfDirectory(atPath: root.path) {
      var directory: ObjCBool = false
      let cache = root.appending(path: "\(name)/\(verificationCache)")
      if manager.fileExists(atPath: root.appending(path: name).path, isDirectory: &directory),
        directory.boolValue, manager.fileExists(atPath: cache.path)
      {
        try manager.removeItem(at: cache)
      }
    }
  }

  // MARK: - Reads

  /// The daemon's control plane over a store opened afresh on `root`.
  private static func handler(over root: URL, state: URL) throws -> RuntimeControlPlaneHandler {
    let store = try RuntimeArtifactStore(
      rootURL: root, quota: ArtifactQuota(), redaction: ArtifactRedactionPolicy(homeDirectory: home),
      nowUTC: { ArtifactQuotaOracleContractTests.nowUTC })
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: state),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: QuotaOracleRefusingDispatcher(),
      capabilityStore: capabilities,
      nowUTC: { ArtifactQuotaOracleContractTests.nowUTC })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { ArtifactQuotaOracleContractTests.nowUTC }, artifactStore: store)
  }

  /// One control frame through the handler, answered as the oracle records it.
  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("artifact-quota-oracle"), "method": .string(method),
        "params": .object(params),
      ]))
    let response = await handler.handleFrame(frame)
    var fields: [String: JSONValue] = ["ok": .bool(response.ok)]
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var body: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { body["details"] = .object(details) }
      fields["error"] = .object(body)
    }
    return .object(fields)
  }

  /// The answer with the root's directory spelled `<root>`.
  private static func labelled(_ response: JSONValue, root: URL) -> JSONValue {
    guard case .object(var fields) = response, case .object(var error)? = fields["error"],
      case .string(let message)? = error["message"]
    else { return response }
    error["message"] = .string(message.replacingOccurrences(of: root.path, with: rootLabel))
    fields["error"] = .object(error)
    return .object(fields)
  }

  /// Every entry under `root` with its kind and mode, and the bytes of every
  /// regular file but a verification cache. A file this user cannot read is
  /// read at the same path under `fallback`, whose bytes it kept.
  private static func entries(
    of root: URL, fallback: URL
  ) throws -> (tree: JSONValue, contents: [String: Data]) {
    let manager = FileManager.default
    var paths: [String] = []
    func walk(_ relative: String) throws {
      let directory =
        relative.isEmpty ? root : root.appending(path: relative, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path) {
        let child = relative.isEmpty ? name : "\(relative)/\(name)"
        paths.append(child)
        let attributes = try manager.attributesOfItem(atPath: root.appending(path: child).path)
        if attributes[.type] as? FileAttributeType == .typeDirectory { try walk(child) }
      }
    }
    try walk("")
    var tree: [JSONValue] = []
    var contents: [String: Data] = [:]
    for path in paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
      let url = root.appending(path: path)
      let attributes = try manager.attributesOfItem(atPath: url.path)
      let mode = String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, radix: 8)
      var entry: [String: JSONValue] = ["path": .string(path)]
      switch attributes[.type] as? FileAttributeType {
      case .typeSymbolicLink?:
        entry["kind"] = .string("symlink")
        entry["target"] = .string(try manager.destinationOfSymbolicLink(atPath: url.path))
      case .typeDirectory?:
        entry["kind"] = .string("directory")
        entry["mode"] = .string(mode)
      case .typeRegular?:
        entry["kind"] = .string("file")
        entry["mode"] = .string(mode)
        if url.lastPathComponent != verificationCache {
          let data =
            try (try? Data(contentsOf: url)) ?? Data(contentsOf: fallback.appending(path: path))
          entry["size"] = .integer(Int64(data.count))
          contents[path] = data
        }
      default:
        entry["kind"] = .string("other")
      }
      tree.append(.object(entry))
    }
    return (.array(tree), contents)
  }

  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  private static func recordOrCompare(
    _ files: [String: Data], oracle: URL, variable: String
  ) throws {
    if let output = ProcessInfo.processInfo.environment[variable] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(recorded), Set(files.keys))
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: oracle.appending(path: path)), data, path)
    }
  }
}

/// Dispatches nothing: a quota read never reaches a provider.
private struct QuotaOracleRefusingDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID: String) -> String? {
    "the Artifact quota oracle dispatches nothing"
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.failed("the Artifact quota oracle dispatches nothing")
  }
}
