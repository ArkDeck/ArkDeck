// Shared Swift oracle for the Rust port of `workspace.run-tests@1` and
// `workspace.symbolize-crash@1` (TASK-XPA-015, M3): every Job the production
// control plane answers for them — plan, submit, run, reconcile and result,
// in order — then what the Runtime keeps afterwards: the capability store,
// the published products and the durable records of the two Jobs whose
// receipt was lost after their child ran.
//
// The tests half covers the person's primary tree (planned, never admitted
// without a capability a person issued), a preset the profile does not
// declare and a stale revision (refused by name), a Runtime-owned copy's
// tests passing under the capability the Runtime issues for the copy, a
// failing module (the Job fails and still publishes its output), and a
// receipt lost after the child ran (parked, reconciled without a readback,
// never run again).
//
// The symbolize half covers a crash log that `capture.diagnostics@1`
// collected from a device, symbolized against the primary project's source
// map (published as sensitive text); a preset whose map is absent (no
// output: the Job fails); a dump that is not that product, one collected
// from the very target the request names, and a preset the profile does not
// declare (each refused by name); and a receipt lost after the child ran
// (parked, reconciled as still unknown, never run again).
//
// Host-local only: a fabricated project under a fixed root, no device, no
// daemon process, no real DevEco, Hvigor or analyzer. `node.sh` and
// `hvigorw.js` stand in for a registered DevEco toolchain's Node launcher and
// Hvigor script, `symbolizer.sh` for the daemon's `--symbolize-crash` mode,
// all with fixed bytes, so the plans and capabilities repeat on every host.
// The two crash logs are published into the Artifact store before the first
// request, as the device's capture would have published them. Record with
// `ARKDECK_RUST_WORKSPACE_TEST_SYMBOLIZE_RECORD=/private/tmp/<new directory>`.
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
private final class TestSymbolizeReceiptLoss: @unchecked Sendable {
  private let lock = NSLock()
  private var lost = false

  func set(_ lost: Bool) { lock.withLock { self.lost = lost } }
  var current: Bool { lock.withLock { lost } }
}

/// The production workspace dispatch, except that a receipt can be lost
/// after the child ran, the way a crashed or unobservable child loses it.
private struct TestSymbolizeReceiptLosingDispatcher: RuntimeProcessDispatching {
  static let lostAfter =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran"

  let base: any RuntimeProcessDispatching
  let loss: TestSymbolizeReceiptLoss

  func unavailableReason(providerID: String) -> String? {
    base.unavailableReason(providerID: providerID)
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard loss.current else { return try await base.dispatch(plan) }
    _ = try await base.dispatch(plan)
    throw RuntimeDispatchFailure.outcomeUnknown(Self.lostAfter)
  }
}

final class WorkspaceTestSymbolizeOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-test-symbolize-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_TEST_SYMBOLIZE_RECORD"
  /// The recording's fixed root: the profile pins the source tree, the tools
  /// and the SDK root by path, and the argv names the map and the dump.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-test-symbolize-oracle", directoryHint: .isDirectory)
  private static let timestamp = "2026-09-25T00:00:00Z"
  private static let project = "TestSymbolizeOracleProject"
  private static let profileID = "workspace-test-symbolize-oracle@1"
  private static let scope = "entry/src/main/ets/**"
  private static let testsPreset = "oracle-tests"
  private static let failingPreset = "oracle-failing-tests"
  private static let symbolPreset = "arkts-sourcemap"
  private static let missingMapPreset = "missing-map"
  private static let sourceMap = "entry/build/default/outputs/default/mapping/sourceMaps.map"
  private static let inputJob = "job-input-crash"
  /// A second capture, from the host target the requests name.
  private static let hostInputJob = "job-input-host-crash"
  private static let crash =
    "Reason:TypeError\nError message:Cannot read property h2 of undefined\nStacktrace:\n    at anonymous (entry|entry|1.0.0|src/main/ets/h/l.ts:14:1)\n"
  /// The running test's root, emptied by `stack(in:)` and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: The source project and the Runtime around it

  private struct Stack {
    let handler: RuntimeControlPlaneHandler
    let artifacts: RuntimeArtifactStore
    let profile: WorkspaceProjectProfile
    let loss: TestSymbolizeReceiptLoss
  }

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// An OpenHarmony-shaped project: two ArkTS sources inside the profile's
  /// scope, its module manifest, and the source map a release build wrote.
  private func sourceTree(in root: URL) throws -> URL {
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let files = [
      "entry/src/main/ets/entryability/EntryAbility.ets": "export default class EntryAbility {}\n",
      "entry/src/main/ets/pages/Index.ets": "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
      "entry/src/main/module.json5": "{ module: { name: 'entry' } }\n",
      Self.sourceMap: "{\"entry|entry|1.0.0|src/main/ets/h/l.ts\":{\"mappings\":\"AAAA\",\"sources\":[\"a.ets\"]}}\n",
    ]
    for (path, text) in files {
      let url = source.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    return try physical(source)
  }

  /// The fixture's stand-in tools, beside the source.
  private func tools(in root: URL) throws -> (node: URL, hvigor: URL, symbolizer: URL, sdk: URL) {
    let tools = root.appending(path: "tools", directoryHint: .isDirectory)
    let sdk = root.appending(path: "sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    for (name, mode) in [("node", 0o755), ("hvigorw.js", 0o644), ("symbolizer", 0o755)] {
      let source = name == "hvigorw.js" ? name : "\(name).sh"
      let url = tools.appending(path: name)
      try Data(contentsOf: Self.oracle.appending(path: source)).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let directory = try physical(tools)
    return (
      directory.appending(path: "node"), directory.appending(path: "hvigorw.js"),
      directory.appending(path: "symbolizer"), try physical(sdk)
    )
  }

  /// A registered Hvigor test preset's closed argv.
  private static func hvigorArguments(script: String, module: String) -> [String] {
    [
      script, "test",
      "--mode", "module",
      "-p", "module=\(module)@default",
      "-p", "product=default",
      "-p", "buildMode=debug",
      "--analyze=normal", "--parallel", "--incremental", "--no-daemon",
    ]
  }

  private func profile(
    source: URL, node: URL, hvigor: URL, symbolizer: URL
  ) throws -> WorkspaceProjectProfile {
    let preset = { (id: String, path: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: path),
        fixedArguments: [], timeoutSeconds: 10)
    }
    let scriptPath = hvigor.resolvingSymlinksInPath().standardizedFileURL.path
    let script = try Data(contentsOf: hvigor)
    let resource = ResolvedExecutableResource(
      path: scriptPath, sha256: SHA256Hex.string(of: script), byteCount: script.count,
      requireExecutable: false)
    let launcher = try WorkspaceExecutableIdentity.hashing(path: node.path)
    let test = { (id: String, module: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: launcher,
        fixedArguments: Self.hvigorArguments(script: scriptPath, module: module),
        timeoutSeconds: 60, verifiedResources: [resource])
    }
    let tests = try test(Self.testsPreset, "entry")
    let failing = try test(Self.failingPreset, "broken")
    let resolver = try WorkspaceExecutableIdentity.hashing(path: symbolizer.path)
    // As the daemon composes a registered symbol preset: the pinned
    // symbolizer's one-shot mode and the map below the project root.
    let symbol = { (id: String, map: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: resolver,
        fixedArguments: [
          "--symbolize-crash",
          URL(filePath: source.path, directoryHint: .isDirectory).appending(path: map).path,
        ], timeoutSeconds: 30)
    }
    let symbolized = try symbol(Self.symbolPreset, Self.sourceMap)
    let missing = try symbol(Self.missingMapPreset, "entry/build/missing/sourceMaps.map")
    return try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: source.path, allowedFileGlobs: [Self.scope],
      inspectionPreset: try preset("inspect", "/usr/bin/grep"),
      patchPreset: try preset("patch", "/usr/bin/grep"),
      buildPresets: [:],
      testPresets: [tests.presetID: tests, failing.presetID: failing],
      symbolPresets: [symbolized.presetID: symbolized, missing.presetID: missing])
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = try sourceTree(in: root)
    let tools = try tools(in: root)
    let profile = try profile(
      source: source, node: tools.node, hvigor: tools.hvigor, symbolizer: tools.symbolizer)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let attempts = try WorkspacePatchAttemptStore(
      rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory))
    let manager = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: registry, patchLineage: attempts)
    let provider = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry, attemptStore: attempts,
      isolationManager: manager, nowUTC: { Self.timestamp })
    let loss = TestSymbolizeReceiptLoss()
    let dispatcher = TestSymbolizeReceiptLosingDispatcher(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: WorkspaceActionExecutableResolver(profile: profile),
          childEnvironmentByExecutablePath: [
            try WorkspaceExecutableIdentity.hashing(path: tools.node.path).path: [
              "DEVECO_SDK_HOME": tools.sdk.path
            ]
          ]),
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
    return Stack(handler: handler, artifacts: artifacts, profile: profile, loss: loss)
  }

  /// Publishes one crash product under the input Job as a device capture
  /// would have, and returns its lease.
  private func publishCrash(
    _ store: RuntimeArtifactStore, job: String = inputJob, name: String, target: String
  ) async throws -> String {
    let metadata = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: job, sessionID: "session-\(job)",
        stepID: "collect-crash-log", name: name, mediaType: "text/plain",
        privacy: .sensitive, retentionClass: .default,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: target, bindingRevision: 3,
          stableIdentitySHA256: String(repeating: "ab", count: 32)),
        contents: Data(Self.crash.utf8)))
    return try await store.leaseReference(jobID: metadata.jobID, artifactID: metadata.artifactID)
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
        domain: "WorkspaceTestSymbolizeOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  /// Plans (when asked), submits, runs and reads one Job.
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

  /// A request refused before anything is admitted.
  private func refused(
    _ stack: Stack, _ frames: Frames, _ label: String, method: String, operation: String,
    inputs: [String: JSONValue]
  ) async throws {
    let answer = try await send(
      stack.handler, frames, method,
      try Self.requestJSON(label, operation: operation, inputs: inputs))
    XCTAssertFalse(answer.ok, label)
  }

  /// A Job whose receipt is lost after its child ran: parked, its durable
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

  // MARK: The recording

  func testTheControlPlaneRunsTestsAndSymbolizesAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()
    var published: [String] = []
    let tests = "workspace.run-tests"
    let symbolize = "workspace.symbolize-crash"
    // The crash logs a device capture published before the first request.
    let crashLog = try await publishCrash(
      stack.artifacts, name: "crash-log.txt", target: "device-oracle-target")
    let crashIndex = try await publishCrash(
      stack.artifacts, name: "crash-index.txt", target: "device-oracle-target")
    let hostCrash = try await publishCrash(
      stack.artifacts, job: Self.hostInputJob, name: "crash-log.txt", target: "workspace-host")

    // 1. The primary tree: planned, never admitted without a capability a
    // person issued; an undeclared preset refused by name.
    let primary: [String: JSONValue] = [
      "projectRef": .string(Self.project), "testPresetRef": .string(Self.testsPreset),
    ]
    let planned = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON("tests-primary", operation: tests, inputs: primary))
    XCTAssertTrue(planned.ok, "primary plan: \(String(describing: planned.error))")
    try await refused(
      stack, frames, "tests-primary", method: "job.submit", operation: tests, inputs: primary)
    try await refused(
      stack, frames, "tests-undeclared", method: "job.plan", operation: tests,
      inputs: ["projectRef": .string(Self.project), "testPresetRef": .string("oracle-release")])

    // 2. A Runtime-owned copy, and its tests under the capability the Runtime
    // issues for it: passing, failing (the output still published), a stale
    // revision refused, a receipt lost after the child ran.
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: stack.profile.projectRoot, profileVersion: Self.profileID, globs: [Self.scope])
    let made = try await job(
      stack, frames, "copy", operation: "workspace.prepare-isolated-copy",
      inputs: [
        "projectRef": .string(Self.project),
        "allowedFileGlobs": .array([.string(Self.scope)]),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ], plan: false)
    XCTAssertEqual(made.state, .string("succeeded"))
    let evolution = root.appending(path: "evolution-workspaces", directoryHint: .isDirectory)
    let workspaceID = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(atPath: evolution.path)
        .first { $0.hasPrefix("evo-") })
    guard
      case .object(let manifest) = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(contentsOf: evolution.appending(path: "\(workspaceID)/workspace.json"))),
      case .object(let record)? = manifest["workspace"],
      case .string(let copyRef)? = record["projectRef"]
    else { return XCTFail("the copy's manifest names its reference") }
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: evolution.appending(path: "\(workspaceID)/workspace", directoryHint: .isDirectory)
        .path,
      profileVersion: Self.profileID, globs: [Self.scope])
    func copyInputs(_ preset: String, revision: String) -> [String: JSONValue] {
      [
        "projectRef": .string(copyRef), "testPresetRef": .string(preset),
        "expectedWorkspaceRevision": .string(revision),
      ]
    }
    let passing = try await job(
      stack, frames, "tests", operation: tests, inputs: copyInputs(Self.testsPreset, revision: base))
    XCTAssertEqual(passing.state, .string("succeeded"))
    published.append(passing.job)
    let failing = try await job(
      stack, frames, "tests-failing", operation: tests,
      inputs: copyInputs(Self.failingPreset, revision: base))
    XCTAssertEqual(failing.state, .string("failed"))
    published.append(failing.job)
    for method in ["job.plan", "job.submit"] {
      try await refused(
        stack, frames, "tests-stale", method: method, operation: tests,
        inputs: copyInputs(Self.testsPreset, revision: String(repeating: "0", count: 64)))
    }
    let lostTests = try await lost(
      stack, frames, "tests-lost", operation: tests,
      inputs: copyInputs(Self.testsPreset, revision: base), root: root)

    // 3. The device's crash log symbolized against the primary project's map;
    // a map that is not there (no output: the Job fails); a dump that is not
    // that product, one from the target the request names, and an undeclared
    // preset refused; a receipt lost after the child ran.
    func symbolizeInputs(_ lease: String, preset: String) -> [String: JSONValue] {
      [
        "projectRef": .string(Self.project), "dumpArtifactRef": .string(lease),
        "symbolPresetRef": .string(preset),
      ]
    }
    let symbolized = try await job(
      stack, frames, "symbolize", operation: symbolize,
      inputs: symbolizeInputs(crashLog, preset: Self.symbolPreset))
    XCTAssertEqual(symbolized.state, .string("succeeded"))
    published.append(symbolized.job)
    let noMap = try await job(
      stack, frames, "symbolize-no-map", operation: symbolize,
      inputs: symbolizeInputs(crashLog, preset: Self.missingMapPreset))
    XCTAssertEqual(noMap.state, .string("failed"))
    for (label, lease, preset) in [
      ("symbolize-index", crashIndex, Self.symbolPreset),
      ("symbolize-host-target", hostCrash, Self.symbolPreset),
      ("symbolize-undeclared", crashLog, "arkts-release"),
    ] {
      try await refused(
        stack, frames, label, method: "job.plan", operation: symbolize,
        inputs: symbolizeInputs(lease, preset: preset))
    }
    let lostSymbolize = try await lost(
      stack, frames, "symbolize-lost", operation: symbolize,
      inputs: symbolizeInputs(crashLog, preset: Self.symbolPreset), root: root)

    // What the Runtime keeps afterwards.
    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "parked-tests-record.json": lostTests.parked,
      "parked-symbolize-record.json": lostSymbolize.parked,
    ]
    let capabilityDirectory = root.appending(path: "capabilities", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: capabilityDirectory.path)
      .sorted() where !name.hasPrefix(".")
    {
      durable["capabilities/" + name] = try Data(
        contentsOf: capabilityDirectory.appending(path: name))
    }
    // The input crash logs as the store keeps them (their index included),
    // and the published products' bytes.
    for input in [Self.inputJob, Self.hostInputJob] {
      let inputs = root.appending(path: "artifacts/\(input)", directoryHint: .isDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: inputs.path).sorted()
      where !name.hasPrefix(".") {
        durable["artifacts/\(input)/\(name)"] = try Data(
          contentsOf: inputs.appending(path: name))
      }
    }
    for job in published {
      let directory = root.appending(path: "artifacts/\(job)", directoryHint: .isDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      where name.hasPrefix("ART-") {
        durable["artifacts/\(job)/\(name)"] = try Data(
          contentsOf: directory.appending(path: name))
      }
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
