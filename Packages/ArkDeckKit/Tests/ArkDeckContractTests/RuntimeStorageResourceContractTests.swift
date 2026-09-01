import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only coverage for the Runtime-owned Session settings resource. These
/// fixtures have no provider or target and are not real-device evidence.
final class RuntimeStorageResourceContractTests: XCTestCase {
  private enum FixtureFailure: Error { case malformed, timeout }

  private struct Run {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
  }

  private var root: URL!
  private var ownerRoot: URL!
  private var defaultSessionsRoot: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/runtime-storage-\(UUID().uuidString.prefix(8).lowercased())")
    ownerRoot = root.appending(path: "owner", directoryHint: .isDirectory)
    defaultSessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func store() throws -> RuntimeSessionStorageStore {
    try RuntimeSessionStorageStore(
      ownerRoot: ownerRoot, defaultSessionsRoot: defaultSessionsRoot)
  }

  func testPolicyAndRootAreOnePersistentGenerationBoundResource() throws {
    let storage = try store()
    let initial = try storage.status()
    XCTAssertEqual(initial.generation, 1)
    XCTAssertEqual(
      initial.rootPath,
      defaultSessionsRoot.resolvingSymlinksInPath().standardizedFileURL.path)
    XCTAssertFalse(initial.usesCustomRoot)
    XCTAssertEqual(initial.policy, RuntimeSessionStorageStore.defaultPolicy)
    XCTAssertEqual(initial.currentBytes, 0)
    XCTAssertEqual(initial.sessionCount, 0)

    let policy = RuntimeSessionStoragePolicy(
      totalQuotaBytes: 10_000, safetyMarginBytes: 1_000, retentionDays: 7)
    let updated = try storage.updatePolicy(policy, expectedGeneration: 1)
    XCTAssertEqual(updated.generation, 2)
    XCTAssertEqual(updated.policy, policy)

    let custom = root.appending(path: "custom", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: custom, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o770])
    XCTAssertThrowsError(
      try storage.updateRoot(path: custom.path, resetToDefault: false, expectedGeneration: 1)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(try storage.status().generation, 2)

    for overlapping in [root!, ownerRoot!] {
      XCTAssertThrowsError(
        try storage.updateRoot(
          path: overlapping.path, resetToDefault: false, expectedGeneration: 2)
      ) { error in
        XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "invalidInput")
      }
      XCTAssertEqual(try? storage.status().generation, 2)
    }

    XCTAssertThrowsError(
      try storage.updateRoot(path: custom.path, resetToDefault: false, expectedGeneration: 2)
    ) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "invalidInput")
    }
    XCTAssertEqual(try storage.status().generation, 2)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: custom.path)
    let selected: RuntimeSessionStorageStatus
    do {
      selected = try storage.updateRoot(
        path: custom.path, resetToDefault: false, expectedGeneration: 2)
    } catch {
      XCTFail("current-generation custom root failed: \(error)")
      return
    }
    XCTAssertEqual(selected.generation, 3)
    let canonicalCustom = custom.resolvingSymlinksInPath().standardizedFileURL.path
    XCTAssertEqual(selected.rootPath, canonicalCustom)
    XCTAssertTrue(selected.usesCustomRoot)

    let reloaded: RuntimeSessionStorageStatus
    do {
      reloaded = try store().status()
    } catch {
      XCTFail("persisted custom root failed to reload: \(error)")
      return
    }
    XCTAssertEqual(reloaded.generation, 3)
    XCTAssertEqual(reloaded.policy, policy)
    XCTAssertEqual(reloaded.rootPath, canonicalCustom)
  }

  func testOwnerAndStoredDocumentPermissionsFailClosed() throws {
    _ = try store().updatePolicy(
      RuntimeSessionStoragePolicy(
        totalQuotaBytes: 20_000, safetyMarginBytes: 2_000, retentionDays: 14),
      expectedGeneration: 1)
    let document = ownerRoot.appending(path: "session-storage.json")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: document.path)
    XCTAssertThrowsError(try store().status()) { error in
      XCTAssertEqual((error as? RuntimeSessionStorageFailure)?.code, "recordUnreadable")
    }
  }

  func testRealCLIProcessReadsAndMutatesBothSeparatedDomains() async throws {
    let sessions = try store()
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

    let status = try await run([
      "runtime", "storage", "status", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(
      status.exitCode, 0,
      String(decoding: status.stderr + status.stdout, as: UTF8.self))
    let initial = try result(status)
    let initialSessions = try object(initial["sessionDomain"])
    let initialArtifacts = try object(initial["artifactDomain"])
    XCTAssertEqual(initialSessions["generation"], .string("1"))
    XCTAssertEqual(
      initialSessions["rootPath"],
      .string(defaultSessionsRoot.resolvingSymlinksInPath().standardizedFileURL.path))
    XCTAssertEqual(initialArtifacts["rootReference"], .string("arkdeck-runtime://artifacts"))
    XCTAssertEqual(initialArtifacts["totalBytes"], .string("12345"))
    XCTAssertEqual(initialArtifacts["usedBytes"], .string("0"))

    let policy = try await run([
      "runtime", "storage", "policy", "--expected-generation", "1",
      "--total-quota-bytes", "10000", "--safety-margin-bytes", "1000",
      "--retention-days", "7", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(
      policy.exitCode, 0,
      String(decoding: policy.stderr + policy.stdout, as: UTF8.self))
    XCTAssertEqual(try object(try result(policy)["sessionDomain"])["generation"], .string("2"))

    let custom = root.appending(path: "custom", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: custom, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let selected = try await run([
      "runtime", "storage", "root", "--expected-generation", "2",
      "--root", custom.path, "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(
      selected.exitCode, 0,
      String(decoding: selected.stderr + selected.stdout, as: UTF8.self))
    let selectedSessions = try object(try result(selected)["sessionDomain"])
    XCTAssertEqual(selectedSessions["generation"], .string("3"))
    XCTAssertEqual(selectedSessions["rootKind"], .string("custom"))
    XCTAssertEqual(
      selectedSessions["rootPath"],
      .string(custom.resolvingSymlinksInPath().standardizedFileURL.path))

    let stale = try await run([
      "runtime", "storage", "root", "--expected-generation", "2", "--default",
      "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(stale.exitCode, 65)
    guard case .object(let staleEnvelope) = try CLIStrictJSON.decode(stale.stdout),
      case .object(let error)? = staleEnvelope["error"],
      case .object(let details)? = error["details"]
    else { return XCTFail("stale CAS refusal is not machine-readable") }
    XCTAssertEqual(error["code"], .string("resourceConflict"))
    XCTAssertEqual(details["phase"], .string("runtimeStorageOwner"))
    XCTAssertEqual(details["newDispatchCount"], .integer(0))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testCLIParserRequiresClosedStorageMutations() {
    XCTAssertNotNil(CLIArgumentParser.parse(["runtime", "storage", "status"]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "runtime", "storage", "policy", "--expected-generation", "1",
        "--total-quota-bytes", "10000", "--safety-margin-bytes", "1000",
        "--retention-days", "7",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "runtime", "storage", "root", "--expected-generation", "1", "--default",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "runtime", "storage", "root", "--expected-generation", "1", "--root", "/tmp",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "runtime", "storage", "root", "--expected-generation", "1", "--default",
        "--root", "/tmp",
      ]).failure)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "runtime", "storage", "policy", "--expected-generation", "0",
        "--total-quota-bytes", "10000", "--safety-margin-bytes", "1000",
        "--retention-days", "7",
      ]).failure)
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

  private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let value)? = value else { throw FixtureFailure.malformed }
    return value
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
