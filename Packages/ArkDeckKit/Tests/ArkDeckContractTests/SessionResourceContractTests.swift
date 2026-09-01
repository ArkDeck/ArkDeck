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
