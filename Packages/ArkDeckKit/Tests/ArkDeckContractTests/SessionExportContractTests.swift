import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only coverage for the generation-bound Session export owner. The
/// Sessions are storage fixtures and the destinations are private temporary
/// directories; nothing here is real-device evidence.
final class SessionExportContractTests: XCTestCase {
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

  private static let rawBytes = Data("device-secret-payload".utf8)
  private static let logBytes = Data("09-02 00:00:00.000 I fixture: hilog line\n".utf8)

  private var root: URL!
  private var ownerRoot: URL!
  private var sessionsRoot: URL!
  private var exportsRoot: URL!
  private let now = ISO8601Timestamps.parseCanonicalPlain("2026-09-02T00:00:00Z")!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/session-export-\(UUID().uuidString.prefix(8).lowercased())")
    ownerRoot = root.appending(path: "owner", directoryHint: .isDirectory)
    sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    exportsRoot = root.appending(path: "exports", directoryHint: .isDirectory)
    try ownerDirectory(root)
    try ownerDirectory(exportsRoot)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testPreviewExcludesSensitiveByDefaultAndApplyPublishesOneDerivedExport() throws {
    let storage = try store()
    let source = try finalizedSession(id: "session-export", timestamp: "2026-08-01T00:00:00Z")
    let manifestBefore = try Data(contentsOf: source.appending(path: "manifest.json"))
    let destination = exportsRoot.appending(path: "session-export-copy", directoryHint: .isDirectory)

    let preview = try object(
      storage.previewSessionExport(
        sessionID: "session-export", destinationPath: destination.path, allowSensitive: false))
    XCTAssertEqual(preview["schemaVersion"], .string("arkdeck.session-export-preview/1"))
    XCTAssertEqual(preview["confirmationRequired"], .bool(true))
    XCTAssertEqual(preview["allowSensitive"], .bool(false))
    XCTAssertEqual(preview["sensitiveDefaultExcluded"], .bool(true))
    XCTAssertEqual(preview["deviceIdentifierPolicy"], .string("redact"))
    XCTAssertEqual(preview["newDispatchCount"], .integer(0))
    XCTAssertEqual(preview["sessionId"], .string("session-export"))
    let rows = try artifactRows(preview)
    XCTAssertEqual(rows.map { $0["artifactId"] }, [.string("artifact-log"), .string("artifact-raw")])
    XCTAssertEqual(rows[0]["privacy"], .string("unknown"))
    XCTAssertEqual(rows[0]["disposition"], .string("include"))
    XCTAssertEqual(rows[0]["transformation"], .string("redactDeviceIdentifiers"))
    XCTAssertEqual(rows[1]["privacy"], .string("sensitive"))
    XCTAssertEqual(rows[1]["disposition"], .string("excludeByDefault"))
    XCTAssertEqual(rows[1]["transformation"], .string("excluded"))
    XCTAssertNil(rows[0]["relativePath"], "the preview must not disclose Session-private paths")
    XCTAssertEqual(
      preview["estimatedBytes"],
      .string(String(UInt64(manifestBefore.count) + UInt64(Self.logBytes.count))))
    let destinationFacts = try object(preview["destination"])
    XCTAssertEqual(destinationFacts["expectedState"], .string("absent"))
    XCTAssertEqual(destinationFacts["path"], .string(destination.standardizedFileURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.path),
      "preview must publish nothing")

    let (previewID, previewDigest) = try tuple(preview)
    let result = try object(
      storage.applySessionExport(previewID: previewID, previewDigest: previewDigest))
    XCTAssertEqual(result["schemaVersion"], .string("arkdeck.session-export-result/1"))
    XCTAssertEqual(result["previewId"], .string(previewID))
    XCTAssertEqual(result["previewDigest"], .string(previewDigest))
    XCTAssertEqual(result["sourceArtifactIds"], .array([.string("artifact-log")]))
    XCTAssertEqual(result["excludedArtifactIds"], .array([.string("artifact-raw")]))
    XCTAssertEqual(result["evidenceClass"], .string("derivedExport"))
    XCTAssertEqual(result["deviceIdentifierPolicy"], .string("redact"))
    XCTAssertEqual(result["newDispatchCount"], .integer(0))
    XCTAssertEqual(result["exportedPath"], .string(destination.standardizedFileURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appending(path: "manifest.json").path))
    XCTAssertEqual(
      try Data(contentsOf: destination.appending(path: "artifacts/log/hilog.txt")), Self.logBytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "artifacts/raw/device.bin").path),
      "a sensitive Artifact that was not opted in must not leave the Session")
    XCTAssertEqual(
      try Data(contentsOf: source.appending(path: "manifest.json")), manifestBefore,
      "export must not rewrite the source manifest")
    XCTAssertEqual(
      try Data(contentsOf: source.appending(path: "artifacts/raw/device.bin")), Self.rawBytes)

    XCTAssertEqual(
      try object(storage.applySessionExport(previewID: previewID, previewDigest: previewDigest)),
      result,
      "an applied preview must return its durable receipt rather than publish again")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path),
      ["session-export-copy"],
      "a retry must leave neither a second export nor staging residue")
  }

  func testExplicitSensitiveOptInIsDigestBoundAndExportsRawArtifacts() throws {
    let storage = try store()
    _ = try finalizedSession(id: "session-sensitive", timestamp: "2026-08-02T00:00:00Z")
    let destination = exportsRoot.appending(path: "sensitive-copy", directoryHint: .isDirectory)

    let closed = try object(
      storage.previewSessionExport(
        sessionID: "session-sensitive", destinationPath: destination.path, allowSensitive: false))
    let open = try object(
      storage.previewSessionExport(
        sessionID: "session-sensitive", destinationPath: destination.path, allowSensitive: true))
    XCTAssertNotEqual(closed["previewDigest"], open["previewDigest"])
    XCTAssertEqual(open["allowSensitive"], .bool(true))
    let rows = try artifactRows(open)
    XCTAssertEqual(rows[1]["artifactId"], .string("artifact-raw"))
    XCTAssertEqual(rows[1]["privacy"], .string("sensitive"))
    XCTAssertEqual(rows[1]["disposition"], .string("include"))
    XCTAssertEqual(rows[1]["transformation"], .string("redactDeviceIdentifiers"))

    let (closedID, closedDigest) = try tuple(closed)
    let (openID, openDigest) = try tuple(open)
    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: closedID, previewDigest: openDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let result = try object(
      storage.applySessionExport(previewID: openID, previewDigest: openDigest))
    XCTAssertEqual(
      result["sourceArtifactIds"], .array([.string("artifact-log"), .string("artifact-raw")]))
    XCTAssertEqual(result["excludedArtifactIds"], .array([]))
    XCTAssertEqual(
      try Data(contentsOf: destination.appending(path: "artifacts/raw/device.bin")), Self.rawBytes)

    // The closed preview is still unexpired and digest-valid, but its
    // destination is now occupied by the other export: it refuses rather than
    // overwriting or publishing beside it.
    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: closedID, previewDigest: closedDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path), ["sensitive-copy"])
  }

  func testExistingDestinationRefusesBeforePublication() throws {
    let storage = try store()
    _ = try finalizedSession(id: "session-occupied", timestamp: "2026-08-03T00:00:00Z")
    let destination = exportsRoot.appending(path: "occupied", directoryHint: .isDirectory)
    let preview = try object(
      storage.previewSessionExport(
        sessionID: "session-occupied", destinationPath: destination.path, allowSensitive: false))
    let (previewID, previewDigest) = try tuple(preview)
    try ownerDirectory(destination)

    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: previewID, previewDigest: previewDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path), ["occupied"])
  }

  func testCatalogGenerationDriftRefusesWithoutPublishing() throws {
    let storage = try store()
    _ = try finalizedSession(id: "session-drift", timestamp: "2026-08-04T00:00:00Z")
    let destination = exportsRoot.appending(path: "drift-copy", directoryHint: .isDirectory)
    let preview = try object(
      storage.previewSessionExport(
        sessionID: "session-drift", destinationPath: destination.path, allowSensitive: false))
    let (previewID, previewDigest) = try tuple(preview)
    guard case .string(let generationText)? = preview["generation"],
      let generation = UInt64(generationText)
    else { return XCTFail("export preview generation is missing") }

    _ = try storage.updateSessionPin(
      sessionID: "session-drift", isPinned: true, expectedGeneration: generation)
    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: previewID, previewDigest: previewDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path), [])
  }

  func testExpiredPreviewRefusesWithoutPublishing() throws {
    let storage = try store()
    _ = try finalizedSession(id: "session-expired", timestamp: "2026-08-05T00:00:00Z")
    let destination = exportsRoot.appending(path: "expired-copy", directoryHint: .isDirectory)
    let preview = try object(
      storage.previewSessionExport(
        sessionID: "session-expired", destinationPath: destination.path, allowSensitive: false))
    let (previewID, previewDigest) = try tuple(preview)
    let expiredStorage = try store(at: now.addingTimeInterval(10 * 60 + 1))

    XCTAssertThrowsError(
      try expiredStorage.applySessionExport(previewID: previewID, previewDigest: previewDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testFaultAfterApplyingBecomesOutcomeUnknownAndNeverReplays() throws {
    let attempts = Counter()
    let storage = try store(
      faultInjector: SessionStorageFaultInjector { point in
        if point == .exportBeforeReplace {
          _ = attempts.increment()
          throw FixtureFailure.io
        }
      })
    _ = try finalizedSession(id: "session-fault", timestamp: "2026-08-06T00:00:00Z")
    let destination = exportsRoot.appending(path: "fault-copy", directoryHint: .isDirectory)
    let preview = try object(
      storage.previewSessionExport(
        sessionID: "session-fault", destinationPath: destination.path, allowSensitive: false))
    let (previewID, previewDigest) = try tuple(preview)

    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: previewID, previewDigest: previewDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "outcomeUnknown")
    }
    XCTAssertEqual(attempts.value, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path), [],
      "a publication that stopped before the rename must leave no staging residue")

    XCTAssertThrowsError(
      try storage.applySessionExport(previewID: previewID, previewDigest: previewDigest)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "outcomeUnknown")
    }
    XCTAssertEqual(attempts.value, 1, "retry must not publish a second time")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testMalformedAndUnknownInputsAreRefusedWithoutRecords() throws {
    let storage = try store()
    _ = try finalizedSession(id: "session-valid", timestamp: "2026-08-07T00:00:00Z")
    let destination = exportsRoot.appending(path: "valid-copy", directoryHint: .isDirectory)
    func code(_ body: () throws -> JSONValue) -> String? {
      do {
        _ = try body()
        return nil
      } catch {
        return (error as? RuntimeSessionStorageFailure)?.code
      }
    }

    XCTAssertEqual(
      code {
        try storage.previewSessionExport(
          sessionID: "not a session", destinationPath: destination.path, allowSensitive: false)
      }, "invalidInput")
    XCTAssertEqual(
      code {
        try storage.previewSessionExport(
          sessionID: "session-valid", destinationPath: "exports/relative", allowSensitive: false)
      }, "invalidInput")
    XCTAssertEqual(
      code {
        try storage.previewSessionExport(
          sessionID: "session-valid",
          destinationPath: sessionsRoot.appending(path: "inside-runtime-storage").path,
          allowSensitive: false)
      }, "invalidInput", "an export may never land inside Runtime Session storage")
    XCTAssertEqual(
      code {
        try storage.previewSessionExport(
          sessionID: "session-valid",
          destinationPath: exportsRoot.appending(path: "missing-parent/copy").path,
          allowSensitive: false)
      }, "invalidInput", "the parent must already exist; export creates exactly one directory")
    XCTAssertEqual(
      code {
        try storage.previewSessionExport(
          sessionID: "session-absent", destinationPath: destination.path, allowSensitive: false)
      }, "resourceNotFound")
    XCTAssertEqual(
      code {
        try storage.applySessionExport(
          previewID: "ABCDEFAB-CDEF-4ABC-8ABC-ABCDEFABCDEF",
          previewDigest: String(repeating: "a", count: 64))
      }, "invalidInput")
    XCTAssertEqual(
      code {
        try storage.applySessionExport(
          previewID: "abcdefab-cdef-4abc-8abc-abcdefabcdef",
          previewDigest: String(repeating: "a", count: 64))
      }, "resourceNotFound")
    // The record store may create its private directory when a well-formed
    // but unknown tuple is looked up; what must never appear is a record.
    let previews = ownerRoot.appending(path: "session-export-previews", directoryHint: .isDirectory)
    XCTAssertEqual(
      (try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? [], [],
      "a refused preview or apply must not leave a durable record behind")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportsRoot.path), [])
  }

  private func store(
    at currentTime: Date? = nil,
    faultInjector: SessionStorageFaultInjector = .none
  ) throws -> RuntimeSessionStorageStore {
    let currentTime = currentTime ?? now
    return try RuntimeSessionStorageStore(
      ownerRoot: ownerRoot, defaultSessionsRoot: sessionsRoot,
      clock: { currentTime }, exportFaultInjector: faultInjector)
  }

  /// One finalized Session holding a sensitive raw Artifact and a log
  /// Artifact, the smallest inventory that exercises both privacy branches.
  @discardableResult
  private func finalizedSession(id: String, timestamp: String) throws -> URL {
    let session = sessionsRoot
      .appending(path: "2026", directoryHint: .isDirectory)
      .appending(path: "08", directoryHint: .isDirectory)
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
    let rawPath = "artifacts/raw/device.bin"
    let logPath = "artifacts/log/hilog.txt"
    for (relative, bytes) in [(rawPath, Self.rawBytes), (logPath, Self.logBytes)] {
      let file = session.appending(path: relative)
      try ownerDirectory(file.deletingLastPathComponent())
      try ownerFile(bytes, at: file)
    }
    let artifacts = [
      try ArtifactRecord(
        id: "artifact-log", role: .log, origin: "fixture",
        relativePath: logPath, size: UInt64(Self.logBytes.count),
        sha256: SHA256Hex.string(of: Self.logBytes), mediaType: "text/plain"),
      try ArtifactRecord(
        id: "artifact-raw", role: .raw, origin: "fixture",
        relativePath: rawPath, size: UInt64(Self.rawBytes.count),
        sha256: SHA256Hex.string(of: Self.rawBytes), mediaType: "application/octet-stream"),
    ]
    try ownerFile(
      try SessionStorageFixtures.manifest(
        sessionID: id, jobID: "job-\(id)", timestamp: timestamp, artifacts: artifacts),
      at: session.appending(path: "manifest.json"))
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

  private func artifactRows(_ preview: [String: JSONValue]) throws -> [[String: JSONValue]] {
    guard case .array(let rows)? = preview["artifacts"] else { throw FixtureFailure.malformed }
    return try rows.map(object)
  }

  private func tuple(_ preview: [String: JSONValue]) throws -> (String, String) {
    guard case .string(let id)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { throw FixtureFailure.malformed }
    return (id, digest)
  }
}
