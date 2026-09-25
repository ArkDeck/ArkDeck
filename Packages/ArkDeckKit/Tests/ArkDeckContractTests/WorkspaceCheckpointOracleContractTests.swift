// Shared Swift oracle for the Rust port of `workspace.create-checkpoint@1`
// and `workspace.sweep-isolated-copies@1` (TASK-XPA-015, M3): every Job the
// production control plane answers for them — plan, submit, run, reconcile
// and result, in order — then what the Runtime keeps afterwards: the
// capability store, the published products, the sealed archive, the copies'
// audit records after the sweeps, and the durable records of the Jobs whose
// receipt was lost after they ran.
//
// The checkpoint half covers a git checkpoint of a clean working copy (no
// object: the Job fails, and the Runtime's own one-use capability for that
// exact plan is spent), one after an edit (the capability's next
// generation), a capability the caller names (refused: the policy is the
// Runtime's own), a stale revision (refused by name at plan and submit), an
// archive checkpoint of a project that is not a git checkout (two exact files
// sealed), the archive refusals (no files named, a missing file, a file
// outside the scope), and a receipt lost after the child ran (parked,
// reconciled without a readback, never run again).
//
// The sweep half covers two Runtime-owned copies, a read of one and a Job of
// the other admitted but not yet run, and two strangers in the copies' root:
// a dry run, the age bound and the latest-count bound (nothing destroyed),
// the sweep that destroys the quiescent copy (its reference no longer
// resolves), a sweep whose receipt is lost after it ran (it destroyed the
// other copy all the same; parked, reconciled as still unknown, never run
// again), and a fresh sweep, for which a destroyed copy no longer vouches:
// both copies and the stranger are kept as unknown. A stranger is never
// touched.
//
// Host-local only: fabricated trees under a fixed root — a project inside a
// larger git checkout, as the WaterFlow demo ships, and a plain project — no
// device, no daemon process. `grep.sh`, `sed.sh`, `git.sh` and `bsdtar.sh` in
// the fixture stand in for the tools a profile pins, with fixed bytes, so
// the plans and capabilities name the same executables on every host. The
// git stand-in fixes the stash commit's author, committer and dates, and the
// bsdtar stand-in writes a portable ustar archive with fixed ownership and no
// Mac metadata, so the checkpoint objects repeat too; the archived files'
// times are fixed. The composition is the daemon's, the sweep's reference
// ledger the engine itself. Record with
// `ARKDECK_RUST_WORKSPACE_CHECKPOINT_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Whether the oracle's workspace dispatch hands its receipt back.
private final class CheckpointReceiptLoss: @unchecked Sendable {
  private let lock = NSLock()
  private var lost = false

  func set(_ lost: Bool) { lock.withLock { self.lost = lost } }
  var current: Bool { lock.withLock { lost } }
}

/// The production workspace dispatch — the Runtime-owned host actions
/// included — except that a receipt can be lost after the dispatch ran, the
/// way a crashed or unobservable child loses it.
private struct CheckpointReceiptLosingDispatcher: RuntimeProcessDispatching {
  static let lostAfter =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran"

  let base: any RuntimeProcessDispatching
  let loss: CheckpointReceiptLoss

  func unavailableReason(providerID: String) -> String? {
    base.unavailableReason(providerID: providerID)
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard loss.current else { return try await base.dispatch(plan) }
    _ = try await base.dispatch(plan)
    throw RuntimeDispatchFailure.outcomeUnknown(Self.lostAfter)
  }
}

final class WorkspaceCheckpointOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-checkpoint-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_CHECKPOINT_RECORD"
  /// The recording's fixed root: the profiles name the source trees by path,
  /// and an archive checkpoint's argv names its files' root and destination.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-checkpoint-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-25T00:00:00Z"
  /// The archived files' modification time, fixed: 2026-09-25T00:00:00Z.
  private static let fileDate = Date(timeIntervalSince1970: 1_790_294_400)
  /// A project inside a larger git checkout: its checkpoint is a git object.
  private static let project = "CheckpointOracleProject"
  /// A project that is not a git checkout: its checkpoint is a sealed archive.
  private static let archiveProject = "ArchiveOracleProject"
  private static let profileID = "workspace-checkpoint-oracle@1"
  private static let scope = "entry/src/main/ets/**"
  private static let index = "entry/src/main/ets/pages/Index.ets"
  private static let ability = "entry/src/main/ets/entryability/EntryAbility.ets"
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
    let loss: CheckpointReceiptLoss
  }

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// Writes one source file owner-writable and world-readable, with the
  /// fixed modification time an archive records.
  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644, .modificationDate: Self.fileDate], ofItemAtPath: url.path)
  }

  /// One OpenHarmony-shaped project: two ArkTS sources inside the profile's
  /// scope and a build profile outside it.
  private func tree(at source: URL) throws -> URL {
    try write(Self.abilitySource, to: source.appending(path: Self.ability))
    try write(Self.indexSource, to: source.appending(path: Self.index))
    try write("{}\n", to: source.appending(path: "build-profile.json5"))
    return try physical(source)
  }

  /// The host's git in a closed environment, with the author and the clock
  /// fixed, as the Rust replay runs it.
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
  private func standInTools(in root: URL) throws -> [String: URL] {
    let directory = root.appending(path: "tools", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var tools: [String: URL] = [:]
    for name in ["grep", "sed", "git", "bsdtar"] {
      let tool = directory.appending(path: name)
      try Data(contentsOf: Self.oracle.appending(path: "\(name).sh")).write(to: tool)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
      tools[name] = try physical(directory).appending(path: name)
    }
    return tools
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let repository = root.appending(path: "repository", directoryHint: .isDirectory)
    let source = try tree(at: repository.appending(path: "project", directoryHint: .isDirectory))
    try git(["init", "--quiet"], in: repository)
    try git(["add", "-A"], in: repository)
    try git(["commit", "--quiet", "-m", "base"], in: repository)
    let plain = try tree(at: root.appending(path: "plain", directoryHint: .isDirectory))
    let tools = try standInTools(in: root)
    let preset = { (id: String, tool: String) in
      try WorkspaceCommandPreset(
        presetID: id,
        executable: try WorkspaceExecutableIdentity.hashing(path: tools[tool]!.path),
        fixedArguments: [], timeoutSeconds: 30)
    }
    let profile = try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: source.path, allowedFileGlobs: [Self.scope],
      inspectionPreset: try preset("source-inspection", "grep"),
      sourceControlPreset: try preset("git", "git"),
      sourceReaderPreset: try preset("source-range", "sed"),
      archiveCheckpointPreset: try preset("sealed-source-archive", "bsdtar"),
      patchPreset: try preset("unified-diff", "grep"),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let plainProfile = try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.archiveProject,
      projectRoot: plain.path, allowedFileGlobs: [Self.scope],
      inspectionPreset: try preset("source-inspection", "grep"),
      archiveCheckpointPreset: try preset("sealed-source-archive", "bsdtar"),
      patchPreset: try preset("unified-diff", "grep"),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    // The daemon's order: profiles by reference, the first the provider's own.
    let profiles = [plainProfile, profile]
    let registry = try WorkspaceProjectProfileRegistry(profiles: profiles)
    let attempts = try WorkspacePatchAttemptStore(
      rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory))
    let manager = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: registry, patchLineage: attempts)
    let operations = WorkspaceOperationsProvider(
      profile: plainProfile, profileRegistry: registry, attemptStore: attempts,
      isolationManager: manager, availabilityProfiles: profiles,
      nowUTC: { Self.timestamp })
    let provider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: [
        Self.project: source.path, Self.archiveProject: plain.path,
      ]),
      tool: nil, operations: operations)
    let loss = CheckpointReceiptLoss()
    let ledger = WorkspaceReferenceLedgerHandle()
    let dispatcher = CheckpointReceiptLosingDispatcher(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: WorkspaceActionExecutableResolver(profiles: profiles)),
        manager: manager, sweeper: manager, referenceLedger: ledger),
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
    ledger.install(engine)
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
    _ label: String, operation: String, inputs: [String: JSONValue],
    authorization: String? = nil
  ) throws -> [String: JSONValue] {
    let document = try RuntimeOperationRequest(
      requestID: "request-\(label)", idempotencyKey: "idempotency-\(label)",
      target: DurableTargetReference(targetID: "workspace-host"),
      operation: RuntimeOperationReference(id: operation, version: 1),
      inputs: inputs,
      authorization: authorization.map { RuntimeCapabilityReference(capabilityID: $0) })
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
        domain: "WorkspaceCheckpointOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  /// Plans (when asked), submits, runs and reads one Job: its Job and the
  /// state its run reached.
  private func job(
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

  /// A request the provider or the admission refuses before anything is
  /// admitted.
  private func refused(
    _ stack: Stack, _ frames: Frames, _ label: String, method: String, operation: String,
    inputs: [String: JSONValue], authorization: String? = nil
  ) async throws {
    let answer = try await send(
      stack.handler, frames, method,
      try Self.requestJSON(
        label, operation: operation, inputs: inputs, authorization: authorization))
    XCTAssertFalse(answer.ok, label)
  }

  /// A Job whose receipt is lost after its dispatch ran: parked, its durable
  /// record kept, reconciled, never run again.
  private func lost(
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
    XCTAssertEqual(Self.state(reconciled), .string("waitingForRecovery"), label)
    let rerun = try await send(stack.handler, frames, "job.run", ["jobId": .string(job)])
    XCTAssertFalse(rerun.ok, "\(label): a parked Job is never run again")
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(job)])
    return (job, record)
  }

  private static func revision(_ root: URL, globs: [String] = [scope]) throws -> String {
    try WorkspaceProviderSupport.workspaceRevision(
      root: root.path, profileVersion: profileID, globs: globs)
  }

  // MARK: The recording

  func testTheControlPlaneCheckpointsAndSweepsAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()
    var published: [String] = []
    let checkpoint = "workspace.create-checkpoint"
    let sweep = "workspace.sweep-isolated-copies"
    let range = "workspace.read-source-range"

    // 1. A git checkpoint of a clean working copy: nothing to stash, no
    // checkpoint object, the Job fails. The Runtime issued its own one-use
    // capability for the exact plan, and the run consumed it.
    let clean = try await job(
      stack, frames, "checkpoint-clean", operation: checkpoint,
      inputs: ["projectRef": .string(Self.project)])
    XCTAssertEqual(clean.state, .string("failed"))

    // 2. After an edit, a checkpoint object, under the capability's next
    // generation.
    try write(Self.indexSource + "// edited\n", to: stack.source.appending(path: Self.index))
    let stashed = try await job(
      stack, frames, "checkpoint", operation: checkpoint,
      inputs: ["projectRef": .string(Self.project)], plan: false)
    XCTAssertEqual(stashed.state, .string("succeeded"))
    published.append(stashed.job)

    // 3. A capability the caller names: a Runtime-owned policy admits none.
    try await refused(
      stack, frames, "checkpoint-named", method: "job.submit", operation: checkpoint,
      inputs: ["projectRef": .string(Self.project)],
      authorization: "CAP-RT-CALLER-NAMED-CHECKPOINT")

    // 4. A stale revision: refused by name at plan and submit.
    for method in ["job.plan", "job.submit"] {
      try await refused(
        stack, frames, "checkpoint-stale", method: method, operation: checkpoint,
        inputs: [
          "projectRef": .string(Self.project),
          "expectedWorkspaceRevision": .string(String(repeating: "0", count: 64)),
        ])
    }

    // 5. An archive checkpoint of the project that is not a git checkout:
    // the two files named, sealed.
    let sealed = try await job(
      stack, frames, "archive", operation: checkpoint,
      inputs: [
        "projectRef": .string(Self.archiveProject),
        "checkpointFilePaths": .array([.string(Self.index), .string(Self.ability)]),
      ])
    XCTAssertEqual(sealed.state, .string("succeeded"))
    published.append(sealed.job)

    // 6. What an archive checkpoint refuses: no files named, a missing file,
    // a file outside the profile's scope.
    try await refused(
      stack, frames, "archive-unnamed", method: "job.plan", operation: checkpoint,
      inputs: ["projectRef": .string(Self.archiveProject)])
    try await refused(
      stack, frames, "archive-missing", method: "job.plan", operation: checkpoint,
      inputs: [
        "projectRef": .string(Self.archiveProject),
        "checkpointFilePaths": .array([.string("entry/src/main/ets/pages/Missing.ets")]),
      ])
    try await refused(
      stack, frames, "archive-outside", method: "job.plan", operation: checkpoint,
      inputs: [
        "projectRef": .string(Self.archiveProject),
        "checkpointFilePaths": .array([.string("build-profile.json5")]),
      ])

    // 7. Two Runtime-owned copies of the checkout's project, a read of one,
    // a Job of the other admitted and not yet run, and two strangers.
    let evolution = root.appending(path: "evolution-workspaces", directoryHint: .isDirectory)
    /// One Runtime-owned copy of the checkout's project: its workspace and
    /// the reference its derived profile resolves by.
    func copy(_ label: String, scope: String) async throws -> (workspace: String, reference: String)
    {
      let made = try await job(
        stack, frames, label, operation: "workspace.prepare-isolated-copy",
        inputs: [
          "projectRef": .string(Self.project),
          "allowedFileGlobs": .array([.string(scope)]),
          "expectedWorkspaceRevision": .string(try Self.revision(stack.source)),
        ], plan: false)
      XCTAssertEqual(made.state, .string("succeeded"))
      for name in try FileManager.default.contentsOfDirectory(atPath: evolution.path)
      where name.hasPrefix("evo-") {
        guard
          case .object(let manifest) = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: evolution.appending(path: "\(name)/workspace.json"))),
          case .object(let record)? = manifest["workspace"],
          case .string(let owner)? = record["htaskID"],
          owner == "runtime-\(made.job)",
          case .string(let reference)? = record["projectRef"]
        else { continue }
        return (name, reference)
      }
      throw POSIXError(.ENOENT)
    }
    /// Whether a copy's tree is still there to be read.
    func hasTree(_ workspace: String) -> Bool {
      FileManager.default.fileExists(
        atPath: evolution.appending(path: "\(workspace)/workspace", directoryHint: .isDirectory)
          .path)
    }
    let quiescent = try await copy("copy-pages", scope: "entry/src/main/ets/pages/**")
    let held = try await copy("copy-ability", scope: "entry/src/main/ets/entryability/**")
    let read = try await job(
      stack, frames, "read-copy", operation: range,
      inputs: [
        "projectRef": .string(quiescent.reference), "filePath": .string(Self.index),
        "lineStart": .integer(1), "lineEnd": .integer(2),
      ], plan: false)
    XCTAssertEqual(read.state, .string("succeeded"))
    let holding = try Self.jobID(
      try await send(
        stack.handler, frames, "job.submit",
        try Self.requestJSON(
          "read-held", operation: range,
          inputs: [
            "projectRef": .string(held.reference), "filePath": .string(Self.ability),
            "lineStart": .integer(1), "lineEnd": .integer(1),
          ])))
    for stranger in ["evo-stranger", "not-a-copy"] {
      try FileManager.default.createDirectory(
        at: evolution.appending(path: "\(stranger)/workspace", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try Data("stranger\n".utf8).write(
        to: evolution.appending(path: "\(stranger)/workspace/kept.txt"))
    }

    // 8. The sweeps that destroy nothing: a dry run, the age bound, the
    // latest-count bound.
    func sweepInputs(retain: Int64, quiescent: Int64, dryRun: Bool) -> [String: JSONValue] {
      [
        "retainLatestCount": .integer(retain),
        "minimumQuiescentSeconds": .integer(quiescent),
        "dryRun": .bool(dryRun),
      ]
    }
    for (label, inputs) in [
      ("sweep-dry", sweepInputs(retain: 0, quiescent: 0, dryRun: true)),
      ("sweep-aged", sweepInputs(retain: 0, quiescent: 3_600, dryRun: true)),
      ("sweep-latest", sweepInputs(retain: 1, quiescent: 0, dryRun: false)),
    ] {
      let swept = try await job(stack, frames, label, operation: sweep, inputs: inputs)
      XCTAssertEqual(swept.state, .string("succeeded"), label)
      published.append(swept.job)
    }
    XCTAssertTrue(hasTree(quiescent.workspace), "nothing destroyed yet")
    XCTAssertTrue(hasTree(held.workspace), "nothing destroyed yet")

    // 9. The sweep that destroys the quiescent copy, whose reference then no
    // longer resolves.
    let destroying = try await job(
      stack, frames, "sweep", operation: sweep,
      inputs: sweepInputs(retain: 0, quiescent: 0, dryRun: false))
    XCTAssertEqual(destroying.state, .string("succeeded"))
    published.append(destroying.job)
    XCTAssertFalse(hasTree(quiescent.workspace), "the quiescent copy is destroyed")
    XCTAssertTrue(hasTree(held.workspace), "a copy with an active Job is kept")
    try await refused(
      stack, frames, "read-destroyed", method: "job.plan", operation: range,
      inputs: [
        "projectRef": .string(quiescent.reference), "filePath": .string(Self.index),
        "lineStart": .integer(1), "lineEnd": .integer(2),
      ])

    // 10. The held Job runs; a sweep whose receipt is lost after it ran
    // destroys that copy all the same, is parked, reconciled as still
    // unknown, and never run again; a fresh sweep finds both destroyed.
    let finished = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(holding)])
    XCTAssertEqual(Self.state(finished), .string("succeeded"))
    let lostSweep = try await lost(
      stack, frames, "sweep-lost", operation: sweep,
      inputs: sweepInputs(retain: 0, quiescent: 0, dryRun: false), root: root)
    XCTAssertFalse(hasTree(held.workspace), "the lost sweep destroyed the other copy")
    let again = try await job(
      stack, frames, "sweep-again", operation: sweep,
      inputs: sweepInputs(retain: 0, quiescent: 0, dryRun: false), plan: false)
    XCTAssertEqual(again.state, .string("succeeded"))
    published.append(again.job)
    for stranger in ["evo-stranger", "not-a-copy"] {
      XCTAssertEqual(
        try Data(contentsOf: evolution.appending(path: "\(stranger)/workspace/kept.txt")),
        Data("stranger\n".utf8), "a stranger is never touched")
    }

    // 11. A git checkpoint whose receipt is lost after the child ran:
    // parked, reconciled without a readback, never run again.
    try write(Self.indexSource + "// edited again\n", to: stack.source.appending(path: Self.index))
    let lostCheckpoint = try await lost(
      stack, frames, "checkpoint-lost", operation: checkpoint,
      inputs: ["projectRef": .string(Self.project)], root: root)

    // What the Runtime keeps afterwards.
    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "parked-sweep-record.json": lostSweep.parked,
      "parked-checkpoint-record.json": lostCheckpoint.parked,
    ]
    let capabilityDirectory = root.appending(path: "capabilities", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: capabilityDirectory.path)
      .sorted() where !name.hasPrefix(".")
    {
      durable["capabilities/" + name] = try Data(
        contentsOf: capabilityDirectory.appending(path: name))
    }
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
    // The sealed archive the Runtime owns.
    let attempts = root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: attempts.path).sorted()
    where name.hasPrefix("checkpoint-") {
      durable["attempts/" + name] = try Data(contentsOf: attempts.appending(path: name))
    }
    // The copies' audit records after the sweeps, and what each copy's root
    // still holds.
    var inventory: [String: JSONValue] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: evolution.path).sorted() {
      let entry = evolution.appending(path: name, directoryHint: .isDirectory)
      let names = try FileManager.default.contentsOfDirectory(atPath: entry.path).sorted()
      inventory[name] = .array(names.map(JSONValue.string))
      for record in ["workspace.json", "teardown.json"] where names.contains(record) {
        durable["copies/\(name)/\(record)"] = try Data(
          contentsOf: entry.appending(path: record))
      }
    }
    durable["copies/inventory.json"] = try CanonicalJSONEncoders.canonicalPretty().encode(
      JSONValue.object(inventory))

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
