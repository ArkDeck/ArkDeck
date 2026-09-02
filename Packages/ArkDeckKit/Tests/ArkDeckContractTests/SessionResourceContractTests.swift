import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only coverage for Session discovery and pinning. The manifests are
/// storage fixtures; they are not real-device evidence.
final class SessionResourceContractTests: XCTestCase {
  private enum FixtureFailure: Error { case malformed, timeout, io }

  private struct Run {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
  }

  private var root: URL!
  private var ownerRoot: URL!
  private var sessionsRoot: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/session-resource-\(UUID().uuidString.prefix(8).lowercased())")
    ownerRoot = root.appending(path: "owner", directoryHint: .isDirectory)
    sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    try ownerDirectory(root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testRuntimeOwnerProvidesImmutablePagesAndGenerationBoundPinning() throws {
    let storage = try store()
    _ = try finalizedSession(
      id: "session-first", jobID: "job-first", month: "07",
      timestamp: "2026-07-01T00:00:00Z", bytes: 32)
    _ = try finalizedSession(
      id: "session-latest", jobID: "job-latest", month: "08",
      timestamp: "2026-08-01T00:00:00Z", bytes: 64)

    let firstPage = try object(storage.listSessions(pageSize: 1, cursor: nil))
    XCTAssertEqual(firstPage["schemaVersion"], .string("arkdeck.cli.page/1"))
    XCTAssertEqual(firstPage["order"], .string("completedAtDescSessionIdAsc"))
    XCTAssertEqual(firstPage["hasMore"], .bool(true))
    let latest = try firstItem(firstPage)
    XCTAssertEqual(latest["sessionId"], .string("session-latest"))
    XCTAssertEqual(latest["generation"], .string("0"))
    XCTAssertEqual(latest["pinned"], .bool(false))
    XCTAssertNil(latest["rootPath"])
    guard case .string(let cursor)? = firstPage["nextCursor"] else {
      return XCTFail("first page did not publish its opaque cursor")
    }
    XCTAssertThrowsError(try storage.listSessions(pageSize: 2, cursor: cursor)) { error in
      XCTAssertEqual((error as? AgentExecutionControlFailure)?.code, "invalidCursor")
    }

    let pinned = try object(
      storage.updateSessionPin(
        sessionID: "session-latest", isPinned: true, expectedGeneration: 0))
    XCTAssertEqual(pinned["generation"], .string("1"))
    XCTAssertEqual(pinned["pinned"], .bool(true))
    XCTAssertThrowsError(
      try storage.updateSessionPin(
        sessionID: "session-latest", isPinned: false, expectedGeneration: 0)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }

    // A durable cursor remains the original generation even after the live
    // catalog changes. It is not silently restarted against current state.
    let secondPage = try object(storage.listSessions(pageSize: 1, cursor: cursor))
    XCTAssertEqual(secondPage["hasMore"], .bool(false))
    let first = try firstItem(secondPage)
    XCTAssertEqual(first["sessionId"], .string("session-first"))
    XCTAssertEqual(first["generation"], .string("0"))

    let shown = try object(storage.showSession(sessionID: "session-latest"))
    XCTAssertEqual(shown, pinned)
    let unpinned = try object(
      storage.updateSessionPin(
        sessionID: "session-latest", isPinned: false, expectedGeneration: 1))
    XCTAssertEqual(unpinned["generation"], .string("2"))
    XCTAssertEqual(unpinned["pinned"], .bool(false))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sessionsRoot.path))

    let custom = root.appending(path: "custom", directoryHint: .isDirectory)
    try ownerDirectory(custom)
    _ = try storage.updateRoot(
      path: custom.path, resetToDefault: false, expectedGeneration: 1)
    XCTAssertEqual(
      try firstItem(try object(storage.listSessions(pageSize: 1, cursor: cursor)))["sessionId"],
      .string("session-first"),
      "a root change must not silently restart an immutable Session page")
  }

  func testRealCLIProcessListsShowsPinsAndUnpinsWithoutCreatingAJob() async throws {
    let sessions = try store()
    _ = try finalizedSession(
      id: "session-cli", jobID: "job-fixture", month: "08",
      timestamp: "2026-08-02T00:00:00Z", bytes: 48)
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: 12_345),
      nowUTC: { "2026-09-02T00:00:00Z" })
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")),
      capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { "2026-09-02T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-02T00:00:00Z" }, artifactStore: artifacts,
      runtimeSessionStorage: sessions)
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "control", directoryHint: .isDirectory),
      handler: handler, nowUTC: { "2026-09-02T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }

    let listed = try await run([
      "session", "list", "--page-size", "1", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(listed.exitCode, 0, diagnostic(listed))
    let page = try result(listed)
    let listedSession = try firstItem(page)
    XCTAssertEqual(listedSession["sessionId"], .string("session-cli"))
    XCTAssertEqual(listedSession["generation"], .string("0"))

    let shown = try await run([
      "session", "show", "--session", "session-cli", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(shown.exitCode, 0, diagnostic(shown))
    XCTAssertEqual(try result(shown), listedSession)

    let pinned = try await run([
      "session", "pin", "--session", "session-cli", "--expected-generation", "0",
      "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(pinned.exitCode, 0, diagnostic(pinned))
    let pinnedSession = try result(pinned)
    XCTAssertEqual(pinnedSession["generation"], .string("1"))
    XCTAssertEqual(pinnedSession["pinned"], .bool(true))

    let stale = try await run([
      "session", "unpin", "--session", "session-cli", "--expected-generation", "0",
      "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(stale.exitCode, 65, diagnostic(stale))
    let staleError = try error(stale)
    XCTAssertEqual(staleError["code"], .string("resourceConflict"))
    let staleDetails = try object(staleError["details"])
    XCTAssertEqual(staleDetails["phase"], .string("sessionOwner"))
    XCTAssertEqual(staleDetails["newDispatchCount"], .integer(0))

    let unpinned = try await run([
      "session", "unpin", "--session", "session-cli", "--expected-generation", "1",
      "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(unpinned.exitCode, 0, diagnostic(unpinned))
    XCTAssertEqual(try result(unpinned)["generation"], .string("2"))
    XCTAssertEqual(try result(unpinned)["pinned"], .bool(false))

    _ = try sessions.updatePolicy(
      RuntimeSessionStoragePolicy(
        totalQuotaBytes: 1_024, safetyMarginBytes: 1_023, retentionDays: 1),
      expectedGeneration: 1)
    let previewRun = try await run([
      "session", "cleanup", "preview", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(previewRun.exitCode, 0, diagnostic(previewRun))
    let preview = try result(previewRun)
    XCTAssertEqual(preview["schemaVersion"], .string("arkdeck.session-cleanup-preview/1"))
    guard case .string(let previewID)? = preview["previewId"],
      case .string(let previewDigest)? = preview["previewDigest"]
    else { return XCTFail("cleanup preview tuple is missing") }
    let applyArguments = [
      "session", "cleanup", "apply", "--preview-id", previewID,
      "--preview-digest", previewDigest, "--socket", server.socketURL.path,
      "--output", "json",
    ]
    let applied = try await run(applyArguments)
    XCTAssertEqual(applied.exitCode, 0, diagnostic(applied))
    let cleanupResult = try result(applied)
    XCTAssertEqual(cleanupResult["schemaVersion"], .string("arkdeck.session-cleanup-result/1"))
    XCTAssertEqual(cleanupResult["removedSessionIds"], .array([.string("session-cli")]))
    let receiptRetry = try await run(applyArguments)
    XCTAssertEqual(receiptRetry.exitCode, 0, diagnostic(receiptRetry))
    XCTAssertEqual(try result(receiptRetry), cleanupResult)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: sessionsRoot.appending(path: "2026/08/session-cli").path))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testRealCLIProcessExportsASessionThroughPreviewAndApply() async throws {
    let sessions = try store()
    let source = try finalizedSessionWithArtifacts(
      id: "session-export", jobID: "job-export", month: "08",
      timestamp: "2026-08-04T00:00:00Z")
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      quota: ArtifactQuota(totalBytes: 12_345),
      nowUTC: { "2026-09-02T00:00:00Z" })
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")),
      capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { "2026-09-02T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-02T00:00:00Z" }, artifactStore: artifacts,
      runtimeSessionStorage: sessions)
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "control", directoryHint: .isDirectory),
      handler: handler, nowUTC: { "2026-09-02T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }

    let exports = root.appending(path: "exports", directoryHint: .isDirectory)
    try ownerDirectory(exports)
    let destination = exports.appending(path: "session-export-copy", directoryHint: .isDirectory)
    let previewRun = try await run([
      "session", "export", "preview", "--session", "session-export",
      "--destination", destination.path, "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(previewRun.exitCode, 0, diagnostic(previewRun))
    let preview = try result(previewRun)
    XCTAssertEqual(preview["schemaVersion"], .string("arkdeck.session-export-preview/1"))
    XCTAssertEqual(preview["allowSensitive"], .bool(false))
    XCTAssertEqual(preview["newDispatchCount"], .integer(0))
    guard case .string(let previewID)? = preview["previewId"],
      case .string(let previewDigest)? = preview["previewDigest"]
    else { return XCTFail("export preview tuple is missing") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let applyArguments = [
      "session", "export", "apply", "--preview-id", previewID,
      "--preview-digest", previewDigest, "--socket", server.socketURL.path,
      "--output", "json",
    ]
    let applied = try await run(applyArguments)
    XCTAssertEqual(applied.exitCode, 0, diagnostic(applied))
    let exportResult = try result(applied)
    XCTAssertEqual(exportResult["schemaVersion"], .string("arkdeck.session-export-result/1"))
    XCTAssertEqual(exportResult["sourceArtifactIds"], .array([.string("artifact-log")]))
    XCTAssertEqual(exportResult["excludedArtifactIds"], .array([.string("artifact-raw")]))
    XCTAssertEqual(exportResult["evidenceClass"], .string("derivedExport"))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appending(path: "manifest.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "artifacts/log/hilog.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appending(path: "artifacts/raw/device.bin").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: source.appending(path: "artifacts/raw/device.bin").path),
      "export must not move or delete source Artifacts")

    let receiptRetry = try await run(applyArguments)
    XCTAssertEqual(receiptRetry.exitCode, 0, diagnostic(receiptRetry))
    XCTAssertEqual(try result(receiptRetry), exportResult)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: exports.path), ["session-export-copy"])

    let stale = try await run(applyArguments.map { $0 == previewDigest ? String(repeating: "0", count: 64) : $0 })
    XCTAssertEqual(stale.exitCode, 65, diagnostic(stale))
    let staleError = try error(stale)
    XCTAssertEqual(staleError["code"], .string("resourceConflict"))
    let staleDetails = try object(staleError["details"])
    XCTAssertEqual(staleDetails["phase"], .string("sessionOwner"))
    XCTAssertEqual(staleDetails["newDispatchCount"], .integer(0))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testParserPublishesClosedSessionResourceArguments() {
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "list", "--page-size", "100", "--cursor", "opaque",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "show", "--session", "session-1",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "pin", "--session", "session-1", "--expected-generation", "0",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "unpin", "--session", "session-1", "--expected-generation", "01",
      ]).failure)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "pin", "--session", "session-1", "--expected-generation", "0",
        "--root", "/tmp",
      ]).failure)
    XCTAssertNotNil(CLIArgumentParser.parse(["session", "cleanup", "preview"]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "cleanup", "apply",
        "--preview-id", "abcdefab-cdef-4abc-8abc-abcdefabcdef",
        "--preview-digest", String(repeating: "a", count: 64),
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "cleanup", "apply",
        "--preview-id", "abcdefab-cdef-4abc-8abc-abcdefabcdef",
        "--preview-digest", String(repeating: "A", count: 64),
      ]).failure)
    XCTAssertNotNil(CLIArgumentParser.parse(["session", "cleanup", "confirm"]).failure)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "export", "preview", "--session", "session-1",
        "--destination", "/private/tmp/session-1-export", "--allow-sensitive",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "export", "preview", "--session", "session-1",
      ]).failure, "the destination is part of the preview contract")
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "export", "apply",
        "--preview-id", "abcdefab-cdef-4abc-8abc-abcdefabcdef",
        "--preview-digest", String(repeating: "a", count: 64),
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "export", "apply",
        "--preview-id", "abcdefab-cdef-4abc-8abc-abcdefabcdef",
        "--preview-digest", String(repeating: "a", count: 64),
        "--allow-sensitive",
      ]).failure, "privacy is chosen at preview and bound by its digest")
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "session", "export", "apply",
        "--preview-id", "abcdefab-cdef-4abc-8abc-abcdefabcdef",
        "--preview-digest", String(repeating: "a", count: 64),
        "--destination", "/private/tmp/elsewhere",
      ]).failure, "apply publishes the exact preview and names no destination of its own")
    XCTAssertNotNil(CLIArgumentParser.parse(["session", "export", "confirm"]).failure)
  }

  func testUnaccountedContentCannotBeHiddenByAPartialSessionList() throws {
    let storage = try store()
    _ = try finalizedSession(
      id: "session-safe", jobID: "job-safe", month: "08",
      timestamp: "2026-08-03T00:00:00Z", bytes: 16)
    let rogue = sessionsRoot.appending(path: "not-a-year", directoryHint: .isDirectory)
    try ownerDirectory(rogue)
    try ownerFile(Data([0x01]), at: rogue.appending(path: "unknown.bin"))

    XCTAssertThrowsError(try storage.listSessions(pageSize: 100, cursor: nil)) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "operationUnavailable")
    }
    XCTAssertThrowsError(try storage.showSession(sessionID: "session-safe")) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "operationUnavailable")
    }
    XCTAssertThrowsError(
      try storage.updateSessionPin(
        sessionID: "session-safe", isPinned: true, expectedGeneration: 0)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "operationUnavailable")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: sessionsRoot
          .appending(path: "2026/08/session-safe/.session-retention.json").path),
      "an incomplete catalog must not publish a pin transition")
    XCTAssertTrue(FileManager.default.fileExists(atPath: rogue.path))
  }

  private func store() throws -> RuntimeSessionStorageStore {
    try RuntimeSessionStorageStore(
      ownerRoot: ownerRoot, defaultSessionsRoot: sessionsRoot)
  }

  @discardableResult
  private func finalizedSession(
    id: String, jobID: String, month: String, timestamp: String, bytes: Int
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
          "jobId": .string(jobID),
        ])),
      at: session.appending(path: ".session-identity.json"))
    try ownerFile(
      try SessionStorageFixtures.manifest(
        sessionID: id, jobID: jobID, timestamp: timestamp),
      at: session.appending(path: "manifest.json"))
    try ownerFile(
      Data(repeating: 0x53, count: bytes),
      at: session.appending(path: "payload.bin"))
    return session
  }

  /// A finalized Session with one sensitive raw Artifact and one log
  /// Artifact, so the export path exercises both privacy dispositions.
  private func finalizedSessionWithArtifacts(
    id: String, jobID: String, month: String, timestamp: String
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
          "jobId": .string(jobID),
        ])),
      at: session.appending(path: ".session-identity.json"))
    let rawBytes = Data("device-secret-payload".utf8)
    let logBytes = Data("09-02 00:00:00.000 I fixture: hilog line\n".utf8)
    let rawPath = "artifacts/raw/device.bin"
    let logPath = "artifacts/log/hilog.txt"
    for (relative, bytes) in [(rawPath, rawBytes), (logPath, logBytes)] {
      let file = session.appending(path: relative)
      try ownerDirectory(file.deletingLastPathComponent())
      try ownerFile(bytes, at: file)
    }
    let artifacts = [
      try ArtifactRecord(
        id: "artifact-log", role: .log, origin: "fixture",
        relativePath: logPath, size: UInt64(logBytes.count),
        sha256: SHA256Hex.string(of: logBytes), mediaType: "text/plain"),
      try ArtifactRecord(
        id: "artifact-raw", role: .raw, origin: "fixture",
        relativePath: rawPath, size: UInt64(rawBytes.count),
        sha256: SHA256Hex.string(of: rawBytes), mediaType: "application/octet-stream"),
    ]
    try ownerFile(
      try SessionStorageFixtures.manifest(
        sessionID: id, jobID: jobID, timestamp: timestamp, artifacts: artifacts),
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

  private func run(_ argv: [String]) async throws -> Run {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = argv
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw FixtureFailure.timeout
    }
    return Run(
      exitCode: process.terminationStatus,
      stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
      stderr: stderr.fileHandleForReading.readDataToEndOfFile())
  }

  private func result(_ run: Run) throws -> [String: JSONValue] {
    guard case .object(let envelope) = try CLIStrictJSON.decode(run.stdout),
      case .object(let value)? = envelope["result"]
    else { throw FixtureFailure.malformed }
    return value
  }

  private func error(_ run: Run) throws -> [String: JSONValue] {
    guard case .object(let envelope) = try CLIStrictJSON.decode(run.stdout),
      case .object(let value)? = envelope["error"]
    else { throw FixtureFailure.malformed }
    return value
  }

  private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let value)? = value else { throw FixtureFailure.malformed }
    return value
  }

  private func firstItem(_ page: [String: JSONValue]) throws -> [String: JSONValue] {
    guard case .array(let items)? = page["items"], items.count == 1 else {
      throw FixtureFailure.malformed
    }
    return try object(items[0])
  }

  private func diagnostic(_ run: Run) -> String {
    String(decoding: run.stderr + run.stdout, as: UTF8.self)
  }
}

private extension Result {
  var success: Success? {
    guard case .success(let value) = self else { return nil }
    return value
  }

  var failure: Failure? {
    guard case .failure(let value) = self else { return nil }
    return value
  }
}
