import Darwin
import Foundation
import XCTest

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
  private let now = ISO8601Timestamps.parseCanonicalPlain("2026-09-02T00:00:00Z")!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/session-cleanup-\(UUID().uuidString.prefix(8).lowercased())")
    ownerRoot = root.appending(path: "owner", directoryHint: .isDirectory)
    sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    try ownerDirectory(root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
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
