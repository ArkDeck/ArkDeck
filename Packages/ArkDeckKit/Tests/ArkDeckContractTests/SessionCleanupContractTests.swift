import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckRuntime
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class SessionCleanupContractTests: XCTestCase {
  private enum FixtureFailure: Error { case malformed, io }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      return count
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  private var root: URL!
  private var ownerRoot: URL!
  private var sessionsRoot: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private let now = ISO8601Timestamps.parseCanonicalPlain("2026-09-02T00:00:00Z")!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/session-cleanup-\(UUID().uuidString.prefix(8).lowercased())")
    ownerRoot = root.appending(path: "owner", directoryHint: .isDirectory)
    sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    try ownerDirectory(root)
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(), capabilityStore: capabilities,
      nowUTC: { "2026-09-02T00:00:00Z" })
  }

  override func tearDownWithError() throws {
    engine = nil
    capabilities = nil
    try? FileManager.default.removeItem(at: root)
  }

  func testCurrentSwiftOwnerReadsActualRustCleanupPreviewRecord() throws {
    // These bytes were copied directly from the isolated Rust owner by
    // rust/scripts/check-session-cleanup.py --record-store-copy. The Session
    // inputs are explicitly simulated fixtures, not hardware evidence.
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/SessionStorage/rust-cleanup-ready.json")
    let bytes = try Data(contentsOf: fixture)
    let fields = try ControlFrameJSON.decodeObject(bytes.dropLast(), maximumBytes: 16 * 1_024 * 1_024)
    guard case .string(let previewID)? = fields["previewID"] else {
      return XCTFail("actual Rust record omitted preview identity")
    }
    let directory = root.appending(path: "rust-records", directoryHint: .isDirectory)
    let records = try RuntimeSessionCleanupRecordStore(directory: directory)
    let path = directory.appending(path: "cleanup-\(previewID).json")
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let record = try records.load(previewID)
    XCTAssertEqual(record.state, .ready)
    XCTAssertEqual(record.result, .null)
    XCTAssertEqual(record.preview, fields["preview"])
    var encoded = try CanonicalJSONEncoders.canonical().encode(record)
    encoded.append(0x0A)
    XCTAssertEqual(encoded, bytes)
  }

  func testCurrentSwiftOwnerReadsActualRustExportPreviewRecord() throws {
    // Copied from the real isolated Rust preview owner, not re-encoded by a
    // fixture generator. Only simulated Session data is represented here.
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/SessionStorage/rust-export-ready.json")
    let bytes = try Data(contentsOf: fixture)
    let fields = try ControlFrameJSON.decodeObject(bytes.dropLast(), maximumBytes: 16 * 1_024 * 1_024)
    guard case .string(let previewID)? = fields["previewID"] else {
      return XCTFail("actual Rust record omitted preview identity")
    }
    let directory = root.appending(path: "rust-export-records", directoryHint: .isDirectory)
    let records = try RuntimeSessionExportRecordStore(directory: directory)
    let path = directory.appending(path: "export-\(previewID).json")
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let record = try records.load(previewID)
    XCTAssertEqual(record.state, .ready)
    XCTAssertEqual(record.result, .null)
    XCTAssertEqual(record.preview, fields["preview"])
    var encoded = try CanonicalJSONEncoders.canonical().encode(record)
    encoded.append(0x0A)
    XCTAssertEqual(encoded, bytes)
  }

  func testCurrentSwiftOwnerReadsActualRustExportAppliedRecord() throws {
    // Copied from the real isolated Rust apply owner, not re-encoded by a
    // fixture generator. Only simulated Session data is represented here.
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/SessionStorage/rust-export-applied.json")
    let bytes = try Data(contentsOf: fixture)
    let fields = try ControlFrameJSON.decodeObject(bytes.dropLast(), maximumBytes: 16 * 1_024 * 1_024)
    guard case .string(let previewID)? = fields["previewID"] else {
      return XCTFail("actual Rust record omitted preview identity")
    }
    let directory = root.appending(path: "rust-export-records", directoryHint: .isDirectory)
    let records = try RuntimeSessionExportRecordStore(directory: directory)
    let path = directory.appending(path: "export-\(previewID).json")
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let record = try records.load(previewID)
    XCTAssertEqual(record.state, .applied)
    XCTAssertEqual(record.result, fields["result"])
    XCTAssertEqual(record.preview, fields["preview"])
    var encoded = try CanonicalJSONEncoders.canonical().encode(record)
    encoded.append(0x0A)
    XCTAssertEqual(encoded, bytes)
  }

  func testPreviewBindsArtifactsAndApplyRevalidatesActiveLeases() throws {
    let storage = try store()
    let target = try finalizedSession(
      id: "session-target", month: "01", timestamp: "2020-01-01T00:00:00Z",
      artifact: true)
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1),
      expectedGeneration: 1)

    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    XCTAssertEqual(preview["schemaVersion"], .string("arkdeck.session-cleanup-preview/1"))
    XCTAssertEqual(preview["confirmationRequired"], .bool(true))
    XCTAssertEqual(preview["newDispatchCount"], .integer(0))
    let row = try onlySession(preview)
    XCTAssertEqual(row["sessionId"], .string("session-target"))
    XCTAssertEqual(row["disposition"], .string("reclaim"))
    guard case .array(let artifacts)? = row["artifacts"], artifacts.count == 1,
      case .object(let artifact) = artifacts[0]
    else { return XCTFail("cleanup preview omitted the Artifact reference") }
    XCTAssertEqual(artifact["artifactId"], .string("artifact-raw"))
    XCTAssertEqual(artifact["privacy"], .string("sensitive"))
    XCTAssertNil(artifact["relativePath"])

    let (previewID, previewDigest) = try tuple(preview)
    XCTAssertThrowsError(
      try storage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest,
        activeSessionIDs: ["session-target"])
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

    let result = try object(
      storage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest, activeSessionIDs: []))
    XCTAssertEqual(result["removedSessionIds"], .array([.string("session-target")]))
    XCTAssertEqual(result["newDispatchCount"], .integer(0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(
      try object(
        storage.applySessionCleanup(
          previewID: previewID, previewDigest: previewDigest,
          activeSessionIDs: ["session-target"])),
      result,
      "an applied preview must return its durable receipt rather than replay")
  }

  func testPartialDeleteBecomesOutcomeUnknownAndNeverReplays() throws {
    let deletes = Counter()
    let storage = try store(
      controller: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete, deletes.increment() == 2 {
            throw FixtureFailure.io
          }
        }))
    let first = try finalizedSession(
      id: "session-first", month: "01", timestamp: "2020-01-01T00:00:00Z")
    let second = try finalizedSession(
      id: "session-second", month: "02", timestamp: "2021-01-01T00:00:00Z")
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1),
      expectedGeneration: 1)
    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    let (previewID, previewDigest) = try tuple(preview)

    XCTAssertThrowsError(
      try storage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest, activeSessionIDs: []))
    { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "outcomeUnknown")
    }
    XCTAssertEqual(deletes.value, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

    XCTAssertThrowsError(
      try storage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest, activeSessionIDs: []))
    { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "outcomeUnknown")
    }
    XCTAssertEqual(deletes.value, 2, "retry must not dispatch another deletion")
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testPinGenerationDriftRefusesWithoutDeleting() throws {
    let deletes = Counter()
    let storage = try store(
      controller: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete { _ = deletes.increment() }
        }))
    let target = try finalizedSession(
      id: "session-pin-drift", month: "01", timestamp: "2020-01-01T00:00:00Z")
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1),
      expectedGeneration: 1)
    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    let (previewID, previewDigest) = try tuple(preview)
    guard case .string(let generationText)? = preview["generation"],
      let generation = UInt64(generationText)
    else { return XCTFail("cleanup preview generation is missing") }

    _ = try storage.updateSessionPin(
      sessionID: "session-pin-drift", isPinned: true,
      expectedGeneration: generation)
    XCTAssertThrowsError(
      try storage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest, activeSessionIDs: []))
    { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(deletes.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
  }

  func testExpiredPreviewRefusesWithoutDeleting() throws {
    let deletes = Counter()
    let storage = try store(
      controller: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete { _ = deletes.increment() }
        }))
    let target = try finalizedSession(
      id: "session-expired", month: "01", timestamp: "2020-01-01T00:00:00Z")
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1),
      expectedGeneration: 1)
    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    let (previewID, previewDigest) = try tuple(preview)
    let expiredStorage = try store(
      at: now.addingTimeInterval(10 * 60 + 1),
      controller: SessionRetentionController(
        faultInjector: SessionStorageFaultInjector { point in
          if point == .retentionBeforeDelete { _ = deletes.increment() }
        }))

    XCTAssertThrowsError(
      try expiredStorage.applySessionCleanup(
        previewID: previewID, previewDigest: previewDigest, activeSessionIDs: []))
    { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(deletes.value, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
  }

  func testCurrentSwiftOwnerReadsActualRustCleanupAppliedRecord() throws {
    // Direct bytes from the Rust cleanup owner after deleting only simulated
    // Session fixtures. This is format interoperability, not hardware evidence.
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Fixtures/SessionStorage/rust-cleanup-applied.json")
    let bytes = try Data(contentsOf: fixture)
    let fields = try ControlFrameJSON.decodeObject(bytes.dropLast(), maximumBytes: 16 * 1_024 * 1_024)
    guard case .string(let id)? = fields["previewID"] else { return XCTFail("missing preview identity") }
    let directory = root.appending(path: "rust-cleanup-applied", directoryHint: .isDirectory)
    let records = try RuntimeSessionCleanupRecordStore(directory: directory)
    try ownerFile(bytes, at: directory.appending(path: "cleanup-\(id).json"))
    let record = try records.load(id)
    XCTAssertEqual(record.state, .applied)
    XCTAssertEqual(record.preview, fields["preview"])
    XCTAssertEqual(record.result, fields["result"])
    var encoded = try CanonicalJSONEncoders.canonical().encode(record)
    encoded.append(0x0A)
    XCTAssertEqual(encoded, bytes)
  }

  func testCleanupApplyProducerRecordsExactTupleAndArtifactReceipt() async throws {
    let storage = try store()
    let target = try finalizedSession(
      id: "session-producer", month: "01", timestamp: "2020-01-01T00:00:00Z", artifact: true)
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1), expectedGeneration: 1)
    let previewResponse = try await wire("session.cleanup.preview", params: [:], storage: storage)
    XCTAssertTrue(previewResponse.ok)
    let preview = try object(previewResponse.result)
    let (id, digest) = try tuple(preview)
    let invalid = try await wire("session.cleanup.apply", params: [
      "previewId": .string("malformed"), "previewDigest": .string(digest),
    ], storage: storage)
    XCTAssertEqual(invalid.error?.code, "invalidInput")
    let missing = try await wire("session.cleanup.apply", params: [
      "previewId": .string("00000000-0000-0000-0000-000000000099"),
      "previewDigest": .string(digest),
    ], storage: storage)
    XCTAssertEqual(missing.error?.code, "resourceNotFound")
    let conflict = try await wire("session.cleanup.apply", params: [
      "previewId": .string(id), "previewDigest": .string(String(repeating: "f", count: 64)),
    ], storage: storage)
    XCTAssertEqual(conflict.error?.code, "resourceConflict")
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    let params: [String: JSONValue] = ["previewId": .string(id), "previewDigest": .string(digest)]
    let response = try await wire("session.cleanup.apply", params: params, storage: storage)
    XCTAssertTrue(response.ok)
    let result = try object(response.result)
    XCTAssertEqual(result["removedSessionIds"], .array([.string("session-producer")]))
    guard case .array(let artifacts)? = result["removedArtifacts"], artifacts.count == 1 else {
      return XCTFail("cleanup producer omitted the removed Artifact identity")
    }
    XCTAssertEqual(try object(artifacts[0])["artifactId"], .string("artifact-raw"))
    XCTAssertEqual(result["newDispatchCount"], .integer(0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let replay = try await wire("session.cleanup.apply", params: params, storage: try store())
    XCTAssertEqual(replay.result, response.result)
  }

  func testCleanupApplyProducerRecordsPartialDeletionAndRefusesReplay() async throws {
    let deletes = Counter()
    let storage = try store(controller: SessionRetentionController(
      faultInjector: SessionStorageFaultInjector { point in
        if point == .retentionBeforeDelete, deletes.increment() == 2 { throw FixtureFailure.io }
      }))
    let first = try finalizedSession(id: "session-first", month: "01", timestamp: "2020-01-01T00:00:00Z")
    let second = try finalizedSession(id: "session-second", month: "02", timestamp: "2021-01-01T00:00:00Z")
    _ = try storage.updatePolicy(
      .init(totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1), expectedGeneration: 1)
    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    let (id, digest) = try tuple(preview)
    let params: [String: JSONValue] = ["previewId": .string(id), "previewDigest": .string(digest)]
    let response = try await wire("session.cleanup.apply", params: params, storage: storage)
    XCTAssertEqual(response.error?.code, "outcomeUnknown")
    XCTAssertEqual(response.error?.details?["newDispatchCount"], .integer(0))
    let restarted = try await wire("session.cleanup.apply", params: params, storage: try store())
    XCTAssertEqual(restarted.error?.code, "outcomeUnknown")
    XCTAssertEqual(deletes.value, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testCleanupApplyProducerRecordsUnavailableAndUnreadableOwners() async throws {
    let tuple: [String: JSONValue] = [
      "previewId": .string("00000000-0000-0000-0000-000000000099"),
      "previewDigest": .string(String(repeating: "a", count: 64)),
    ]
    let unavailable = try await wire("session.cleanup.apply", params: tuple, storage: nil)
    XCTAssertEqual(unavailable.error?.code, "operationUnavailable")
    let storage = try store()
    let preview = try object(storage.previewSessionCleanup(activeSessionIDs: []))
    let (id, digest) = try self.tuple(preview)
    try Data("corrupt fixture record".utf8).write(to:
      ownerRoot.appending(path: "session-cleanup-previews/cleanup-\(id).json"))
    let unreadable = try await wire("session.cleanup.apply", params: [
      "previewId": .string(id), "previewDigest": .string(digest),
    ], storage: storage)
    XCTAssertEqual(unreadable.error?.code, "recordUnreadable")
  }

  private func wire(
    _ method: String, params: [String: JSONValue], storage: RuntimeSessionStorageStore?
  ) async throws -> AgentWireProtocol.Response {
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-02T00:00:00Z" }, runtimeSessionStorage: storage)
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("session-cleanup-producer"), "method": .string(method), "params": .object(params),
    ])
    let response = await handler.handleLine(try CanonicalJSONEncoders.canonical().encode(request))
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: response)
  }

  private func store(
    at currentTime: Date? = nil,
    controller: SessionRetentionController = SessionRetentionController()
  ) throws -> RuntimeSessionStorageStore {
    let currentTime = currentTime ?? now
    return try RuntimeSessionStorageStore(
      ownerRoot: ownerRoot, defaultSessionsRoot: sessionsRoot,
      clock: { currentTime }, retentionController: controller)
  }

  @discardableResult
  private func finalizedSession(
    id: String,
    month: String,
    timestamp: String,
    artifact: Bool = false
  ) throws -> URL {
    let session = sessionsRoot
      .appending(path: "2026", directoryHint: .isDirectory)
      .appending(path: month, directoryHint: .isDirectory)
      .appending(path: id, directoryHint: .isDirectory)
    try ownerDirectory(session)
    try ownerFile(
      try CanonicalJSONEncoders.canonical().encode(
        JSONValue.object([
          "schemaVersion": .string("1.0.0"),
          "sessionId": .string(id),
          "jobId": .string("job-\(id)"),
        ])),
      at: session.appending(path: ".session-identity.json"))
    var artifacts: [ArtifactRecord] = []
    if artifact {
      let bytes = Data("sensitive".utf8)
      let relative = "artifacts/raw/raw.bin"
      let destination = session.appending(path: relative)
      try ownerDirectory(destination.deletingLastPathComponent())
      try ownerFile(bytes, at: destination)
      artifacts = [
        try ArtifactRecord(
          id: "artifact-raw", role: .raw, origin: "fixture",
          relativePath: relative, size: UInt64(bytes.count),
          sha256: SHA256Hex.string(of: bytes), mediaType: "application/octet-stream")
      ]
    }
    try ownerFile(
      try SessionStorageFixtures.manifest(
        sessionID: id, jobID: "job-\(id)", timestamp: timestamp,
        artifacts: artifacts),
      at: session.appending(path: "manifest.json"))
    try ownerFile(
      Data(repeating: 0x53, count: 32),
      at: session.appending(path: "payload.bin"))
    return session
  }

  private func ownerDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(url.path, 0o700) == 0 else { throw FixtureFailure.io }
  }

  private func ownerFile(_ data: Data, at url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, 0o600) == 0 else { throw FixtureFailure.io }
  }

  private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let value)? = value else { throw FixtureFailure.malformed }
    return value
  }

  private func onlySession(_ preview: [String: JSONValue]) throws -> [String: JSONValue] {
    guard case .array(let rows)? = preview["sessions"], rows.count == 1 else {
      throw FixtureFailure.malformed
    }
    return try object(rows[0])
  }

  private func tuple(_ preview: [String: JSONValue]) throws -> (String, String) {
    guard case .string(let id)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { throw FixtureFailure.malformed }
    return (id, digest)
  }
}
