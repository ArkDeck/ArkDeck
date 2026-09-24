// Shared Swift oracle for the Rust port of `workspace.prepare-isolated-copy@1`
// (TASK-XPA-015, M3): one Job's whole life through the production control
// plane — plan, submit, run, result — and the copy the Runtime owns
// afterwards: its manifest and the tree it holds.
//
// The four `job.*` corpora carry no frame of this operation, and they are
// deduplicated by shape, so they could not be replayed as one sequence. This
// records the sequence, as `workspace-mutation-oracle` records the project and
// preset control plane.
//
// Host-local only: a fabricated source tree under a fixed root, no device, no
// daemon process. Record with
// `ARKDECK_RUST_WORKSPACE_ISOLATION_RECORD=/private/tmp/<new directory>`, with
// `ARKDECK_CONTROL_FRAME_LOG` pointing at the same run's frame directory.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class WorkspaceIsolationOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-isolation-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_ISOLATION_RECORD"
  /// The recording's fixed root: the profile pins the source tree by path.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-isolation-oracle", directoryHint: .isDirectory)
  /// The read-back's own fixed root. SwiftPM's parallel runner may run this
  /// class's tests at the same time, each in its own process, so no two tests
  /// share a root, and none is emptied or removed except by the test naming it.
  private static let statusRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-isolation-status", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-20T00:00:00.000Z"
  /// The running test's root, emptied by `stack(in:)` and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: The source project and the Runtime around it

  private func sourceTree(in root: URL) throws -> URL {
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appending(path: "Sources/App.txt"))
    try Data("outside the narrowed scope\n".utf8).write(
      to: source.appending(path: "Sources/Other.txt"))
    guard let physical = realpath(source.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(physical) }
    return URL(filePath: String(cString: physical), directoryHint: .isDirectory)
  }

  private func profile(root: URL) throws -> WorkspaceProjectProfile {
    let preset = { (id: String, path: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: path),
        fixedArguments: [], timeoutSeconds: 10)
    }
    return try WorkspaceProjectProfile(
      profileID: "workspace-isolation-oracle@1", projectRef: "IsolationOracleProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: try preset("inspect", "/usr/bin/grep"),
      patchPreset: try preset("patch", "/usr/bin/patch"),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
  }

  private func stack(in root: URL) throws -> (
    RuntimeControlPlaneHandler, EvolutionWorkspaceManager, URL
  ) {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = try sourceTree(in: root)
    let profile = try profile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let evolution = root.appending(path: "evolution-workspaces", directoryHint: .isDirectory)
    let manager = try EvolutionWorkspaceManager(rootURL: evolution, profileRegistry: registry)
    let provider = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory)),
      isolationManager: manager, nowUTC: { Self.timestamp })
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(
      fallback: DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: profile)),
      manager: manager)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { Self.timestamp })
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers,
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilities, artifactStore: artifacts,
      workspaceProjectStore: nil, nowUTC: { Self.timestamp })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities,
      providerIDs: providers.registeredProviderIDs, nowUTC: { Self.timestamp },
      targetStore: nil, bootstrap: nil, targetObservations: nil,
      hdcRuntimeDiagnostics: nil, artifactStore: artifacts, historyFilterStore: nil,
      flashBundleImportDirectory: root.appending(
        path: "flash-bundle-imports", directoryHint: .isDirectory),
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: nil, flashLanePlanPreviewer: nil,
      rockchipBootloaderStatusObserver: nil, rockchipDeviceAccessObserver: nil,
      rockchipLoaderBindingCoordinator: nil, rockchipPostFlashAliasReconciler: nil,
      workspaceProjects: [], methodObserver: nil)
    return (handler, manager, source)
  }

  private func request(
    _ handler: RuntimeControlPlaneHandler, method: String, params: [String: JSONValue]
  ) async throws -> AgentWireProtocol.Response {
    let frame = try JSONEncoder().encode(
      AgentWireProtocol.Request(id: UUID().uuidString, method: method, params: params))
    return await handler.handleFrame(frame)
  }

  // MARK: The recording

  func testTheControlPlanePreparesOneIsolatedCopyAsRecorded() async throws {
    let (handler, manager, source) = try stack(in: Self.oracleRoot)
    let profile = try profile(root: source)
    let revision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let document = try RuntimeOperationRequest(
      requestID: "isolation-request", idempotencyKey: "isolation-idempotency",
      target: DurableTargetReference(targetID: "workspace-host"),
      operation: RuntimeOperationReference(id: "workspace.prepare-isolated-copy", version: 1),
      inputs: [
        "projectRef": .string(profile.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(revision),
      ])
    let requestJson = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

    var answers: [(String, AgentWireProtocol.Response)] = []
    let planned = try await request(
      handler, method: "job.plan", params: ["requestJson": .string(requestJson)])
    XCTAssertTrue(planned.ok, "job.plan: \(String(describing: planned.error))")
    answers.append(("job.plan", planned))
    let submitted = try await request(
      handler, method: "job.submit", params: ["requestJson": .string(requestJson)])
    XCTAssertTrue(submitted.ok, "job.submit: \(String(describing: submitted.error))")
    answers.append(("job.submit", submitted))
    guard case .object(let accepted)? = submitted.result,
      case .string(let jobID)? = accepted["jobId"]
    else { return XCTFail("job.submit must name its Job") }
    let ran = try await request(handler, method: "job.run", params: ["jobId": .string(jobID)])
    XCTAssertTrue(ran.ok, "job.run: \(String(describing: ran.error))")
    answers.append(("job.run", ran))
    let result = try await request(handler, method: "job.result", params: ["jobId": .string(jobID)])
    XCTAssertTrue(result.ok, "job.result: \(String(describing: result.error))")
    answers.append(("job.result", result))

    // The copy the Runtime owns afterwards.
    let workspaces = try FileManager.default.contentsOfDirectory(
      atPath: Self.oracleRoot.appending(path: "evolution-workspaces").path
    ).filter { $0.hasPrefix("evo-") }.sorted()
    XCTAssertEqual(workspaces.count, 1, "one isolated copy")
    guard let workspaceID = workspaces.first else { return }
    let copy = Self.oracleRoot.appending(path: "evolution-workspaces/\(workspaceID)")
    let manifest = try Data(contentsOf: copy.appending(path: "workspace.json"))
    let tree = try Self.tree(at: copy.appending(path: "workspace", directoryHint: .isDirectory))
    // The copy holds the whole profile scope; the request's narrower globs
    // become the copy's own `allowedPaths`, which is what may be written in
    // it, not what is copied into it.
    XCTAssertEqual(tree.map(\.0), ["Sources/App.txt", "Sources/Other.txt"])
    guard case .object(let held) = try JSONDecoder().decode(JSONValue.self, from: manifest) else {
      return XCTFail("workspace.json is not an object")
    }
    XCTAssertEqual(held["allowedPaths"], .array([.string("Sources/App.txt")]))
    guard case .object(let record)? = held["workspace"] else {
      return XCTFail("workspace.json holds no record")
    }
    XCTAssertEqual(record["workspaceID"], .string(workspaceID))
    XCTAssertEqual(record["sourceProjectRef"], .string(profile.projectRef))
    guard case .string(let base)? = record["baseRevision"] else {
      return XCTFail("the record must carry its base revision")
    }
    XCTAssertEqual(base.count, 64)
    _ = manager

    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try manifest.write(to: directory.appending(path: "workspace.json"))
      try CanonicalJSONEncoders.canonical().encode(
        JSONValue.object([
          "workspaceID": .string(workspaceID),
          "sourceRevision": .string(revision),
          "entries": .array(
            tree.map { .object(["path": .string($0.0), "sha256": .string($0.1)]) }),
        ])
      ).write(to: directory.appending(path: "tree.json"))
      return
    }

    // The checked-in frames are what this handler answers, in this order.
    let recorded = try String(
      contentsOf: Self.oracle.appending(path: "frames.jsonl"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }
    XCTAssertEqual(recorded.count, answers.count)
    for (frame, answer) in zip(recorded, answers) {
      guard case .object(let fields) = frame else { return XCTFail("a frame is not an object") }
      XCTAssertEqual(fields["method"], .string(answer.0))
      XCTAssertEqual(fields["ok"], .bool(answer.1.ok))
      XCTAssertEqual(fields["result"] ?? .null, answer.1.result ?? .null, answer.0)
    }
    let recordedManifest = try Data(
      contentsOf: Self.oracle.appending(path: "workspace.json"))
    XCTAssertEqual(
      try Self.masked(manifest), try Self.masked(recordedManifest),
      "the manifest is the recorded one once host paths are set aside")
    guard
      case .object(let recordedTree) = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "tree.json")))
    else { return XCTFail("tree.json is not an object") }
    XCTAssertEqual(recordedTree["workspaceID"], .string(workspaceID))
    XCTAssertEqual(recordedTree["sourceRevision"], .string(revision))
    XCTAssertEqual(
      recordedTree["entries"],
      .array(tree.map { .object(["path": .string($0.0), "sha256": .string($0.1)]) }))
  }

  /// The same Job read back through the Job status surfaces. A workspace
  /// operation belongs to no App workspace, so every projection of its Job
  /// carries a null `workspaceKind` — a value the committed `job.status`,
  /// `job.show` and `job.reconcile` corpora had never sampled, so their
  /// published schemas refused it. Run with `ARKDECK_CONTROL_FRAME_LOG` to
  /// record these frames for the corpora (TASK-XPA-015, the Rust port of this
  /// operation); without it the test states the Swift answer.
  func testTheIsolationJobReadsBackThroughTheStatusSurfaces() async throws {
    let (handler, _, source) = try stack(in: Self.statusRoot)
    let profile = try profile(root: source)
    let revision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let document = try RuntimeOperationRequest(
      requestID: "isolation-read-request", idempotencyKey: "isolation-read-idempotency",
      target: DurableTargetReference(targetID: "workspace-host"),
      operation: RuntimeOperationReference(id: "workspace.prepare-isolated-copy", version: 1),
      inputs: [
        "projectRef": .string(profile.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(revision),
      ])
    let requestJson = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    let submitted = try await request(
      handler, method: "job.submit", params: ["requestJson": .string(requestJson)])
    guard case .object(let accepted)? = submitted.result,
      case .string(let jobID)? = accepted["jobId"]
    else { return XCTFail("job.submit must name its Job") }
    let ran = try await request(handler, method: "job.run", params: ["jobId": .string(jobID)])
    XCTAssertTrue(ran.ok, "job.run: \(String(describing: ran.error))")
    for method in ["job.status", "job.show", "job.reconcile"] {
      let answer = try await request(handler, method: method, params: ["jobId": .string(jobID)])
      XCTAssertTrue(answer.ok, "\(method): \(String(describing: answer.error))")
      guard case .object(let fields)? = answer.result else {
        return XCTFail("\(method) answers an object")
      }
      let projection: [String: JSONValue]
      if case .object(let job)? = fields["job"] { projection = job } else { projection = fields }
      XCTAssertEqual(projection["state"], .string("succeeded"), method)
      XCTAssertEqual(projection["workspaceKind"], .null, method)
    }
  }

  /// Every regular file under `root`, tree-relative, with its digest.
  private static func tree(at root: URL) throws -> [(String, String)] {
    var entries: [(String, String)] = []
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relative = String(url.path.dropFirst(root.path.count + 1))
      entries.append((relative, SHA256Hex.string(of: try Data(contentsOf: url))))
    }
    return entries.sorted { $0.0 < $1.0 }
  }

  /// The manifest with every host path set aside.
  private static func masked(_ bytes: Data) throws -> JSONValue {
    func strip(_ value: JSONValue) -> JSONValue {
      switch value {
      case .object(var fields):
        for key in ["projectRoot", "sourceProjectRoot", "rootPath", "path"] {
          if fields[key] != nil { fields[key] = .string("<host path>") }
        }
        for (key, nested) in fields { fields[key] = strip(nested) }
        return .object(fields)
      case .array(let values):
        return .array(values.map(strip))
      default:
        return value
      }
    }
    return strip(try JSONDecoder().decode(JSONValue.self, from: bytes))
  }
}
