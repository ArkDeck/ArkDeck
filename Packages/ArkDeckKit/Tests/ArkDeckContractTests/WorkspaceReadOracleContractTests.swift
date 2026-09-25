// Shared Swift oracle for the Rust port of the four read-only workspace
// operations (TASK-XPA-015, M3): `workspace.inspect-source@1`,
// `workspace.read-source-range@1`, `workspace.inspect-git-status@1` and
// `workspace.inspect-diff@1`. Every Job the production control plane answers
// for them — plan, submit, run, reconcile and result, in order — then what
// the Runtime keeps afterwards: the published products and the durable
// records of the two Jobs whose receipt was lost after their child ran.
//
// The sequence covers, per operation, a read that succeeds; the refusals the
// provider names before anything is admitted (an unknown project, a scope,
// a range, a path, a revision or a pathspec it will not accept, and a
// project whose profile offers no such tool); a read whose tool exits with a
// failure (the Job fails and publishes nothing); and, for the inspection and
// the status, a receipt lost after the child ran (parked, reconciled as not
// executed, failed, never run again).
//
// The job.* corpora carry no frame of these operations and are deduplicated
// by shape, so they cannot be replayed as one sequence. Host-local only: two
// fabricated source trees under a fixed root, one of them a git working
// copy, no device, no daemon process. `grep.sh`, `sed.sh` and `git.sh` in
// the fixture stand in for `/usr/bin/grep`, `/usr/bin/sed` and `/usr/bin/git`
// with fixed bytes, so the plan digests repeat on every host; each runs the
// host's own tool with the argv the Runtime lowered, in a closed environment.
// The composition is the daemon's: `WorkspaceProvider` over the registered
// roots and the configured inspector, the operations provider over the
// resolved profiles. Record with
// `ARKDECK_RUST_WORKSPACE_READ_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Whether the oracle's read dispatch hands its receipt back to the Runtime.
private final class ReadReceiptLoss: @unchecked Sendable {
  private let lock = NSLock()
  private var lost = false

  func set(_ lost: Bool) { lock.withLock { self.lost = lost } }
  var current: Bool { lock.withLock { lost } }
}

/// The production workspace dispatch, except that a read's receipt can be
/// lost after its child ran, the way a crashed or unobservable child loses it.
private struct ReadReceiptLosingDispatcher: RuntimeProcessDispatching {
  static let lostAfter =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran"

  let base: any RuntimeProcessDispatching
  let loss: ReadReceiptLoss

  func unavailableReason(providerID: String) -> String? {
    base.unavailableReason(providerID: providerID)
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard loss.current else { return try await base.dispatch(plan) }
    _ = try await base.dispatch(plan)
    throw RuntimeDispatchFailure.outcomeUnknown(Self.lostAfter)
  }
}

final class WorkspaceReadOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-read-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_READ_RECORD"
  /// The recording's fixed root: the profiles and the registered roots name
  /// the source trees by path, and the inspection's argv ends with one.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-read-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-25T00:00:00Z"
  /// A git working copy with a source reader: every read is offered.
  private static let project = "ReadOracleProject"
  /// No source control and no source reader: only the inspection is.
  private static let plainProject = "PlainOracleProject"
  private static let profileID = "workspace-read-oracle@1"
  private static let scope = "entry/src/main/ets/**"
  private static let index = "entry/src/main/ets/pages/Index.ets"
  private static let indexSource =
    "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n"
  private static let abilitySource = "export default class EntryAbility {}\n"
  /// The running test's root, emptied by `stack(in:)` and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: The source projects and the Runtime around them

  private struct Stack {
    let handler: RuntimeControlPlaneHandler
    let source: URL
    let loss: ReadReceiptLoss
  }

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// One OpenHarmony-shaped project: two ArkTS sources inside the profile's
  /// scope and a build profile outside it.
  private func tree(_ name: String, in root: URL) throws -> URL {
    let source = root.appending(path: name, directoryHint: .isDirectory)
    let ets = source.appending(path: "entry/src/main/ets", directoryHint: .isDirectory)
    for directory in ["entryability", "pages"] {
      try FileManager.default.createDirectory(
        at: ets.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    try Data(Self.abilitySource.utf8).write(
      to: ets.appending(path: "entryability/EntryAbility.ets"))
    try Data(Self.indexSource.utf8).write(to: ets.appending(path: "pages/Index.ets"))
    try Data("{}\n".utf8).write(to: source.appending(path: "build-profile.json5"))
    return try physical(source)
  }

  /// The host's git in the closed environment the stand-in gives it, with
  /// the author and the clock fixed, as the Rust replay runs it.
  private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.environment = [
      "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Oracle", "GIT_AUTHOR_EMAIL": "oracle@invalid.example",
      "GIT_COMMITTER_NAME": "Oracle", "GIT_COMMITTER_EMAIL": "oracle@invalid.example",
      "GIT_AUTHOR_DATE": "2026-09-25T00:00:00Z",
      "GIT_COMMITTER_DATE": "2026-09-25T00:00:00Z",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    // `waitUntilExit` spins the calling thread's run loop, which a
    // cooperative-pool thread never wakes; `isRunning` is updated off it.
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning {
      guard Date() < deadline else {
        process.terminate()
        throw POSIXError(.ETIMEDOUT)
      }
      usleep(10_000)
    }
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
  }

  /// The fixture's stand-in tools, executable, beside the sources.
  private func standInTools(in root: URL) throws -> (grep: URL, sed: URL, git: URL) {
    let directory = root.appending(path: "tools", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["grep", "sed", "git"] {
      let tool = directory.appending(path: name)
      try Data(contentsOf: Self.oracle.appending(path: "\(name).sh")).write(to: tool)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }
    let physicalTools = try physical(directory)
    return (
      physicalTools.appending(path: "grep"), physicalTools.appending(path: "sed"),
      physicalTools.appending(path: "git")
    )
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = try tree("source", in: root)
    let plain = try tree("plain", in: root)
    try git(["init", "--quiet"], in: source)
    try git(["add", "-A"], in: source)
    try git(["commit", "--quiet", "-m", "base"], in: source)
    let tools = try standInTools(in: root)
    let preset = { (id: String, tool: URL) in
      try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: tool.path),
        fixedArguments: [], timeoutSeconds: 30)
    }
    let inspection = try preset("source-inspection", tools.grep)
    let profile = try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: source.path, allowedFileGlobs: [Self.scope],
      inspectionPreset: inspection,
      sourceControlPreset: try preset("git", tools.git),
      sourceReaderPreset: try preset("source-range", tools.sed),
      patchPreset: try preset("unified-diff", tools.grep),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let plainProfile = try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.plainProject,
      projectRoot: plain.path, allowedFileGlobs: [Self.scope],
      inspectionPreset: inspection, patchPreset: try preset("unified-diff", tools.grep),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let profiles = [plainProfile, profile]
    let registry = try WorkspaceProjectProfileRegistry(profiles: profiles)
    // The daemon's composition: the attempt store first, then the isolation
    // manager that reads it as the copies' patch lineage, then the
    // operations provider over every resolved profile behind the inspector.
    let attempts = try WorkspacePatchAttemptStore(
      rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory))
    let manager = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: registry, patchLineage: attempts)
    let operations = WorkspaceOperationsProvider(
      profile: plainProfile, profileRegistry: registry, attemptStore: attempts,
      isolationManager: manager, availabilityProfiles: profiles,
      nowUTC: { Self.timestamp })
    let inspectorBytes = try Data(contentsOf: tools.grep)
    let inspector = ResolvedExecutable(
      path: tools.grep.path, sha256: SHA256Hex.string(of: inspectorBytes))
    let provider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: [
        Self.project: source.path, Self.plainProject: plain.path,
      ]),
      tool: WorkspaceInspectorTool(
        executablePath: inspector.path, executableSHA256: inspector.sha256),
      operations: operations)
    let loss = ReadReceiptLoss()
    let dispatcher = ReadReceiptLosingDispatcher(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: CombinedWorkspaceExecutableResolver(
            inspector: inspector,
            operations: WorkspaceActionExecutableResolver(profiles: profiles))),
        manager: manager),
      loss: loss)
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
    return Stack(handler: handler, source: source, loss: loss)
  }

  private static func requestJSON(
    _ label: String, operation: String, inputs: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    let document = try RuntimeOperationRequest(
      requestID: "request-\(label)", idempotencyKey: "idempotency-\(label)",
      target: DurableTargetReference(targetID: "workspace-host"),
      operation: RuntimeOperationReference(id: operation, version: 1),
      inputs: inputs, authorization: nil)
    return [
      "requestJson": .string(
        String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self))
    ]
  }

  /// Every exchange, as the control-frame recorder spells it.
  private final class Frames: @unchecked Sendable {
    var lines: [Data] = []
  }

  private func send(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue]
  ) async throws -> AgentWireProtocol.Response {
    let request = AgentWireProtocol.Request(
      id: UUID().uuidString, method: method, params: params)
    let response = await handler.handleFrame(try JSONEncoder().encode(request))
    frames.lines.append(
      try ControlFrameRecord(request: request, response: response).encodedLine())
    return response
  }

  private static func jobID(_ response: AgentWireProtocol.Response) throws -> String {
    guard case .object(let accepted)? = response.result,
      case .string(let jobID)? = accepted["jobId"]
    else {
      throw NSError(
        domain: "WorkspaceReadOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  /// Plans, submits, runs and reads one Job, as a caller does: its Job and
  /// the state its run reached.
  private func read(
    _ stack: Stack, _ frames: Frames, _ label: String, operation: String,
    inputs: [String: JSONValue], plan: Bool = true
  ) async throws -> (job: String, state: JSONValue?) {
    let request = try Self.requestJSON(label, operation: operation, inputs: inputs)
    if plan {
      let planned = try await send(stack.handler, frames, "job.plan", request)
      XCTAssertTrue(planned.ok, "\(label) plan: \(String(describing: planned.error))")
    }
    let job = try Self.jobID(try await send(stack.handler, frames, "job.submit", request))
    let ran = try await send(stack.handler, frames, "job.run", ["jobId": .string(job)])
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(job)])
    return (job, Self.state(ran))
  }

  /// A plan the provider refuses before anything is admitted.
  private func refusedPlan(
    _ stack: Stack, _ frames: Frames, _ label: String, operation: String,
    inputs: [String: JSONValue]
  ) async throws {
    let refused = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON(label, operation: operation, inputs: inputs))
    XCTAssertFalse(refused.ok, label)
  }

  /// A read whose receipt is lost after its child ran: parked, its durable
  /// record kept, reconciled, never run again.
  private func lostRead(
    _ stack: Stack, _ frames: Frames, _ label: String, operation: String,
    inputs: [String: JSONValue], root: URL
  ) async throws -> (job: String, parked: Data) {
    let job = try Self.jobID(
      try await send(
        stack.handler, frames, "job.submit",
        try Self.requestJSON(label, operation: operation, inputs: inputs)))
    stack.loss.set(true)
    let parked = try await send(stack.handler, frames, "job.run", ["jobId": .string(job)])
    stack.loss.set(false)
    XCTAssertEqual(Self.state(parked), .string("waitingForRecovery"), label)
    let record = try Data(
      contentsOf: root.appending(path: "engine/jobs/\(job)/job-record.json"))
    let reconciled = try await send(
      stack.handler, frames, "job.reconcile", ["jobId": .string(job)])
    XCTAssertEqual(Self.state(reconciled), .string("failed"), label)
    let rerun = try await send(stack.handler, frames, "job.run", ["jobId": .string(job)])
    XCTAssertFalse(rerun.ok, "\(label): a reconciled read is never run again")
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(job)])
    return (job, record)
  }

  // MARK: The recording

  func testTheControlPlaneAnswersTheWorkspaceReadsAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()
    var published: [String] = []
    let inspect = "workspace.inspect-source"
    let range = "workspace.read-source-range"
    let status = "workspace.inspect-git-status"
    let diff = "workspace.inspect-diff"

    // 1. The inspection: a symbol found, a symbol absent (a real answer,
    // not a failure), then what the provider refuses by name.
    let found = try await read(
      stack, frames, "inspect", operation: inspect,
      inputs: [
        "projectRef": .string(Self.project), "symbol": .string("build"),
        "fileScope": .string("*.ets"),
      ])
    XCTAssertEqual(found.state, .string("succeeded"))
    published.append(found.job)
    let absent = try await read(
      stack, frames, "inspect-absent", operation: inspect,
      inputs: [
        "projectRef": .string(Self.plainProject), "symbol": .string("NoSuchSymbol"),
        "fileScope": .string("*.ets"),
      ], plan: false)
    XCTAssertEqual(absent.state, .string("succeeded"))
    published.append(absent.job)
    try await refusedPlan(
      stack, frames, "inspect-unknown", operation: inspect,
      inputs: [
        "projectRef": .string("UnknownOracleProject"), "symbol": .string("build"),
        "fileScope": .string("*.ets"),
      ])
    try await refusedPlan(
      stack, frames, "inspect-scope", operation: inspect,
      inputs: [
        "projectRef": .string(Self.project), "symbol": .string("build"),
        "fileScope": .string("pages/*.ets"),
      ])
    try await refusedPlan(
      stack, frames, "inspect-symbol", operation: inspect,
      inputs: [
        "projectRef": .string(Self.project), "symbol": .string("two\nlines"),
        "fileScope": .string("*.ets"),
      ])
    let lostInspection = try await lostRead(
      stack, frames, "inspect-lost", operation: inspect,
      inputs: [
        "projectRef": .string(Self.project), "symbol": .string("Entry"),
        "fileScope": .string("*.ets"),
      ], root: root)

    // 2. A bounded source range: read, then refused by range, by path and
    // where the profile offers no reader; a missing file fails the Job.
    let lines = try await read(
      stack, frames, "range", operation: range,
      inputs: [
        "projectRef": .string(Self.project), "filePath": .string(Self.index),
        "lineStart": .integer(2), "lineEnd": .integer(4),
      ])
    XCTAssertEqual(lines.state, .string("succeeded"))
    published.append(lines.job)
    try await refusedPlan(
      stack, frames, "range-inverted", operation: range,
      inputs: [
        "projectRef": .string(Self.project), "filePath": .string(Self.index),
        "lineStart": .integer(5), "lineEnd": .integer(4),
      ])
    try await refusedPlan(
      stack, frames, "range-outside", operation: range,
      inputs: [
        "projectRef": .string(Self.project), "filePath": .string("build-profile.json5"),
        "lineStart": .integer(1), "lineEnd": .integer(1),
      ])
    try await refusedPlan(
      stack, frames, "range-traversal", operation: range,
      inputs: [
        "projectRef": .string(Self.project),
        "filePath": .string("entry/src/main/ets/../../../../build-profile.json5"),
        "lineStart": .integer(1), "lineEnd": .integer(1),
      ])
    try await refusedPlan(
      stack, frames, "range-no-reader", operation: range,
      inputs: [
        "projectRef": .string(Self.plainProject), "filePath": .string(Self.index),
        "lineStart": .integer(1), "lineEnd": .integer(2),
      ])
    let missing = try await read(
      stack, frames, "range-missing", operation: range,
      inputs: [
        "projectRef": .string(Self.project),
        "filePath": .string("entry/src/main/ets/pages/Missing.ets"),
        "lineStart": .integer(1), "lineEnd": .integer(1),
      ])
    XCTAssertEqual(missing.state, .string("failed"))

    // 3. The working copy's status: clean, then after an edit and a new
    // file; refused where the profile has no source control.
    let clean = try await read(
      stack, frames, "status-clean", operation: status,
      inputs: ["projectRef": .string(Self.project)])
    XCTAssertEqual(clean.state, .string("succeeded"))
    published.append(clean.job)
    try Data((Self.indexSource + "// edited\n").utf8).write(
      to: stack.source.appending(path: Self.index))
    try Data("export const added = 1\n".utf8).write(
      to: stack.source.appending(path: "entry/src/main/ets/pages/Added.ets"))
    let dirty = try await read(
      stack, frames, "status-dirty", operation: status,
      inputs: ["projectRef": .string(Self.project)], plan: false)
    XCTAssertEqual(dirty.state, .string("succeeded"))
    published.append(dirty.job)
    try await refusedPlan(
      stack, frames, "status-no-git", operation: status,
      inputs: ["projectRef": .string(Self.plainProject)])
    let lostStatus = try await lostRead(
      stack, frames, "status-lost", operation: status,
      inputs: ["projectRef": .string(Self.project)], root: root)

    // 4. A bounded diff: against HEAD; refused by revision and by pathspec;
    // a revision git does not know fails the Job.
    let changed = try await read(
      stack, frames, "diff", operation: diff,
      inputs: [
        "projectRef": .string(Self.project), "baseRevision": .string("HEAD"),
        "pathScope": .string("entry"),
      ])
    XCTAssertEqual(changed.state, .string("succeeded"))
    published.append(changed.job)
    try await refusedPlan(
      stack, frames, "diff-revision", operation: diff,
      inputs: [
        "projectRef": .string(Self.project), "baseRevision": .string("--output=x"),
        "pathScope": .string("entry"),
      ])
    try await refusedPlan(
      stack, frames, "diff-pathspec", operation: diff,
      inputs: [
        "projectRef": .string(Self.project), "baseRevision": .string("HEAD"),
        "pathScope": .string("/etc"),
      ])
    let unknown = try await read(
      stack, frames, "diff-unknown-revision", operation: diff,
      inputs: [
        "projectRef": .string(Self.project), "baseRevision": .string("nosuchrevision"),
        "pathScope": .string("entry"),
      ], plan: false)
    XCTAssertEqual(unknown.state, .string("failed"))

    // What the Runtime keeps afterwards.
    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "parked-inspection-record.json": lostInspection.parked,
      "parked-status-record.json": lostStatus.parked,
    ]
    // The published products' bytes; their metadata carries observation
    // windows read off the host clock, so only the payloads are kept.
    for job in published {
      let directory = root.appending(path: "artifacts/\(job)", directoryHint: .isDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      where name.hasPrefix("ART-") {
        durable["artifacts/\(job)/\(name)"] = try Data(
          contentsOf: directory.appending(path: name))
      }
    }
    // Nothing was published for a read that failed or was never confirmed.
    for job in [missing.job, unknown.job, lostInspection.job, lostStatus.job] {
      let directory = root.appending(path: "artifacts/\(job)", directoryHint: .isDirectory)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      XCTAssertFalse(names.contains { $0.hasPrefix("ART-") }, "\(job) published nothing")
    }

    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      for (name, bytes) in durable {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
      }
      return
    }

    // The checked-in oracle is what this Runtime answers and keeps, byte for
    // byte.
    for (name, bytes) in durable.sorted(by: { $0.key < $1.key }) {
      let recorded = try Data(contentsOf: Self.oracle.appending(path: name))
      if name == "frames.jsonl" {
        let expected = recorded.split(separator: UInt8(ascii: "\n"))
        let actual = bytes.split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(expected.count, actual.count, "frame count")
        for (index, (lhs, rhs)) in zip(expected, actual).enumerated() {
          XCTAssertEqual(
            String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self),
            "frame \(index)")
        }
      } else {
        XCTAssertEqual(recorded, bytes, name)
      }
    }
  }
}
