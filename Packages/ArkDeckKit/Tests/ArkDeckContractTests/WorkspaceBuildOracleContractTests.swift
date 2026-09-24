// Shared Swift oracle for the Rust port of `workspace.build-openharmony@1`
// (TASK-XPA-015, M3): one Runtime-owned isolated copy and every build Job the
// production control plane answers against it and against the person's
// primary tree — plan, submit, run, reconcile and result, in order — then
// what the Runtime keeps afterwards: the published build products, the
// capability store, and the durable record of the Job whose receipt was lost
// after its child ran.
//
// The sequence covers a preset the profile does not declare and a stale
// revision (both refused by name, nothing admitted), a build of the copy
// under a Runtime-issued capability (the log and the unsigned HAP it landed,
// both published), a build whose module the project does not declare (the
// Job fails and still publishes its log), the primary tree (planned, never
// admitted without a capability a person issued), and a receipt lost after
// the child ran (parked, reconciled without a readback, never run again, and
// the same build refused while that use is unsettled).
//
// The job.* corpora carry no frame of this operation and are deduplicated by
// shape, so they cannot be replayed as one sequence. Host-local only: a
// fabricated source tree under a fixed root, no device, no daemon process,
// no real DevEco or Hvigor. `node.sh` in the fixture stands in for the Node
// launcher a registered DevEco toolchain pins and `hvigorw.js` for its Hvigor
// script, pinned as the preset's verified resource, both with fixed bytes, so
// the plan digests and capability identities repeat on every host. The child
// environment names `DEVECO_SDK_HOME` for that executable, as the daemon's
// composition names it for a registered Hvigor preset. Record with
// `ARKDECK_RUST_WORKSPACE_BUILD_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Whether the oracle's build dispatch hands its receipt back to the Runtime.
private final class BuildReceiptLoss: @unchecked Sendable {
  private let lock = NSLock()
  private var lost = false

  func set(_ lost: Bool) { lock.withLock { self.lost = lost } }
  var current: Bool { lock.withLock { lost } }
}

/// The production workspace dispatch, except that a build's receipt can be
/// lost after its child ran, the way a crashed or unobservable child loses it.
private struct BuildReceiptLosingDispatcher: RuntimeProcessDispatching {
  static let lostAfter =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran"

  let base: any RuntimeProcessDispatching
  let loss: BuildReceiptLoss

  func unavailableReason(providerID: String) -> String? {
    base.unavailableReason(providerID: providerID)
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .workspace(.buildOpenHarmony) = plan.action, loss.current else {
      return try await base.dispatch(plan)
    }
    _ = try await base.dispatch(plan)
    throw RuntimeDispatchFailure.outcomeUnknown(Self.lostAfter)
  }
}

final class WorkspaceBuildOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-build-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_BUILD_RECORD"
  /// The recording's fixed root: the profile pins the source tree, the tools
  /// and the SDK root by path, and the lowered argv names the Hvigor script.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-build-oracle", directoryHint: .isDirectory)
  /// A capability's clock is whole seconds.
  private static let timestamp = "2026-09-25T00:00:00Z"
  private static let project = "BuildOracleProject"
  private static let profileID = "workspace-build-oracle@1"
  private static let debugPreset = "oracle-debug"
  private static let missingModulePreset = "oracle-missing-module"
  private static let debugProduct = "entry/build/default/outputs/default/entry-default-unsigned.hap"
  private static let missingProduct =
    "broken/build/default/outputs/default/broken-default-unsigned.hap"
  /// The running test's root, emptied by `stack(in:)` and removed after it.
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: The source project and the Runtime around it

  private struct Stack {
    let handler: RuntimeControlPlaneHandler
    let profile: WorkspaceProjectProfile
    let loss: BuildReceiptLoss
  }

  private func physical(_ url: URL) throws -> URL {
    guard let resolved = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
  }

  /// An OpenHarmony-shaped project: two ArkTS sources inside the profile's
  /// scope, one module manifest outside it.
  private func sourceTree(in root: URL) throws -> URL {
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let ets = source.appending(path: "entry/src/main/ets", directoryHint: .isDirectory)
    for directory in ["entryability", "pages"] {
      try FileManager.default.createDirectory(
        at: ets.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    try Data("export default class EntryAbility {}\n".utf8).write(
      to: ets.appending(path: "entryability/EntryAbility.ets"))
    try Data("@Entry\n@Component\nstruct Index {\n  build() {}\n}\n".utf8).write(
      to: ets.appending(path: "pages/Index.ets"))
    try Data("{ module: { name: 'entry' } }\n".utf8).write(
      to: source.appending(path: "entry/src/main/module.json5"))
    return try physical(source)
  }

  /// The fixture's stand-in toolchain: an executable Node launcher, its
  /// Hvigor script and an SDK root, beside the source.
  private func toolchain(in root: URL) throws -> (node: URL, hvigor: URL, sdk: URL) {
    let tools = root.appending(path: "tools", directoryHint: .isDirectory)
    let sdk = root.appending(path: "sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let node = tools.appending(path: "node")
    let hvigor = tools.appending(path: "hvigorw.js")
    try Data(contentsOf: Self.oracle.appending(path: "node.sh")).write(to: node)
    try Data(contentsOf: Self.oracle.appending(path: "hvigorw.js")).write(to: hvigor)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hvigor.path)
    return (
      try physical(tools).appending(path: "node"),
      try physical(tools).appending(path: "hvigorw.js"),
      try physical(sdk)
    )
  }

  /// A registered Hvigor preset's closed argv, as the daemon's composition
  /// derives it from the preset's module, product and build mode.
  private static func hvigorArguments(script: String, module: String) -> [String] {
    [
      script, "assembleHap",
      "--mode", "module",
      "-p", "module=\(module)@default",
      "-p", "product=default",
      "-p", "buildMode=debug",
      "--analyze=normal", "--parallel", "--incremental", "--no-daemon",
    ]
  }

  private func profile(
    source: URL, node: URL, hvigor: URL
  ) throws -> WorkspaceProjectProfile {
    let preset = { (id: String, path: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: path),
        fixedArguments: [], timeoutSeconds: 10)
    }
    // The daemon names the script and its resource in Foundation's canonical
    // spelling, as it canonicalizes a registered toolchain's hvigorw.js.
    let scriptPath = hvigor.resolvingSymlinksInPath().standardizedFileURL.path
    let script = try Data(contentsOf: hvigor)
    let resource = ResolvedExecutableResource(
      path: scriptPath, sha256: SHA256Hex.string(of: script), byteCount: script.count,
      requireExecutable: false)
    let launcher = try WorkspaceExecutableIdentity.hashing(path: node.path)
    let build = { (id: String, module: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: launcher,
        fixedArguments: Self.hvigorArguments(script: scriptPath, module: module),
        timeoutSeconds: 60, verifiedResources: [resource])
    }
    let debug = try build(Self.debugPreset, "entry")
    let missing = try build(Self.missingModulePreset, "broken")
    return try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: source.path, allowedFileGlobs: ["entry/src/main/ets/**"],
      inspectionPreset: try preset("inspect", "/usr/bin/grep"),
      patchPreset: try preset("patch", "/usr/bin/grep"),
      buildPresets: [debug.presetID: debug, missing.presetID: missing],
      testPresets: [:], symbolPresets: [:],
      buildProducts: [
        debug.presetID: Self.debugProduct, missing.presetID: Self.missingProduct,
      ])
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = try sourceTree(in: root)
    let tools = try toolchain(in: root)
    let profile = try profile(source: source, node: tools.node, hvigor: tools.hvigor)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    // The daemon's composition: the attempt store first, then the isolation
    // manager that reads it as the copies' patch lineage.
    let attempts = try WorkspacePatchAttemptStore(
      rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory))
    let manager = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: registry, patchLineage: attempts)
    let provider = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry, attemptStore: attempts,
      isolationManager: manager, nowUTC: { Self.timestamp })
    let loss = BuildReceiptLoss()
    let dispatcher = BuildReceiptLosingDispatcher(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: WorkspaceActionExecutableResolver(profile: profile),
          // Keyed by the executable identity's own path, as the daemon keys
          // a registered toolchain's Node launcher.
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
    return Stack(handler: handler, profile: profile, loss: loss)
  }

  private static func requestJSON(
    _ label: String, operation: String, target: String = "workspace-host",
    inputs: [String: JSONValue], authorization: String? = nil
  ) throws -> [String: JSONValue] {
    let document = try RuntimeOperationRequest(
      requestID: "request-\(label)", idempotencyKey: "idempotency-\(label)",
      target: DurableTargetReference(targetID: target),
      operation: RuntimeOperationReference(id: operation, version: 1),
      inputs: inputs,
      authorization: authorization.map { RuntimeCapabilityReference(capabilityID: $0) })
    return [
      "requestJson": .string(
        String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self))
    ]
  }

  private static func buildInputs(
    project: String, preset: String, revision: String?
  ) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = [
      "projectRef": .string(project), "buildPresetRef": .string(preset),
    ]
    if let revision { inputs["expectedWorkspaceRevision"] = .string(revision) }
    return inputs
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
        domain: "WorkspaceBuildOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  // MARK: The recording

  func testTheControlPlaneBuildsACopyAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()

    // The Runtime-owned copy every build below runs in.
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: stack.profile.projectRoot, profileVersion: stack.profile.profileID,
      globs: stack.profile.allowedFileGlobs)
    let copy = try Self.requestJSON(
      "copy", operation: "workspace.prepare-isolated-copy",
      inputs: [
        "projectRef": .string(Self.project),
        "allowedFileGlobs": .array([.string("entry/src/main/ets/**")]),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ])
    let copyJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", copy))
    let copied = try await send(stack.handler, frames, "job.run", ["jobId": .string(copyJob)])
    XCTAssertEqual(Self.state(copied), .string("succeeded"))
    let evolution = root.appending(path: "evolution-workspaces", directoryHint: .isDirectory)
    let workspaces = try FileManager.default.contentsOfDirectory(atPath: evolution.path)
      .filter { $0.hasPrefix("evo-") }.sorted()
    XCTAssertEqual(workspaces.count, 1, "one isolated copy")
    let workspaceID = try XCTUnwrap(workspaces.first)
    let copyTree = evolution.appending(
      path: "\(workspaceID)/workspace", directoryHint: .isDirectory)
    guard
      case .object(let manifest) = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(contentsOf: evolution.appending(path: "\(workspaceID)/workspace.json"))),
      case .object(let record)? = manifest["workspace"],
      case .string(let copyRef)? = record["projectRef"]
    else { return XCTFail("the copy's manifest names its reference") }
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: copyTree.path, profileVersion: Self.profileID,
      globs: ["entry/src/main/ets/**"])

    // 1. A preset the profile does not declare: refused before admission.
    let undeclared = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON(
        "undeclared", operation: "workspace.build-openharmony",
        inputs: Self.buildInputs(project: copyRef, preset: "oracle-release", revision: base)))
    XCTAssertFalse(undeclared.ok)

    // 2. A stale revision: refused by name, nothing admitted.
    let stale = try Self.requestJSON(
      "stale", operation: "workspace.build-openharmony",
      inputs: Self.buildInputs(
        project: copyRef, preset: Self.debugPreset,
        revision: String(repeating: "0", count: 64)))
    for method in ["job.plan", "job.submit"] {
      let answer = try await send(stack.handler, frames, method, stale)
      XCTAssertFalse(answer.ok, method)
    }

    // 3. The copy built under a Runtime-issued capability: its log and the
    // unsigned HAP it landed, both published.
    let build = try Self.requestJSON(
      "build", operation: "workspace.build-openharmony",
      inputs: Self.buildInputs(project: copyRef, preset: Self.debugPreset, revision: base))
    let planned = try await send(stack.handler, frames, "job.plan", build)
    XCTAssertTrue(planned.ok, "build plan: \(String(describing: planned.error))")
    let buildJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", build))
    let built = try await send(stack.handler, frames, "job.run", ["jobId": .string(buildJob)])
    XCTAssertEqual(Self.state(built), .string("succeeded"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(buildJob)])
    // The store owns the product's bytes now; the landed file in the copy
    // does not outlive its publication.
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: copyTree.appending(path: Self.debugProduct).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: URL(filePath: stack.profile.projectRoot).appending(path: "entry/build").path),
      "nothing was built in the primary tree")

    // 4. A module the project does not declare: the Job fails, and its log
    // is still published.
    let missing = try Self.requestJSON(
      "missing-module", operation: "workspace.build-openharmony",
      inputs: Self.buildInputs(
        project: copyRef, preset: Self.missingModulePreset, revision: base))
    _ = try await send(stack.handler, frames, "job.plan", missing)
    let missingJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", missing))
    let failed = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(missingJob)])
    XCTAssertEqual(Self.state(failed), .string("failed"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(missingJob)])

    // 5. The person's primary tree: planned, never admitted without a
    // capability a person issued.
    let primary = try Self.requestJSON(
      "primary", operation: "workspace.build-openharmony",
      inputs: Self.buildInputs(project: Self.project, preset: Self.debugPreset, revision: nil))
    let primaryPlan = try await send(stack.handler, frames, "job.plan", primary)
    XCTAssertTrue(primaryPlan.ok, "primary plan: \(String(describing: primaryPlan.error))")
    let refused = try await send(stack.handler, frames, "job.submit", primary)
    XCTAssertEqual(refused.error?.code, "admissionDenied")
    let named = try await send(
      stack.handler, frames, "job.submit",
      try Self.requestJSON(
        "primary-named", operation: "workspace.build-openharmony",
        inputs: Self.buildInputs(project: Self.project, preset: Self.debugPreset, revision: nil),
        authorization: "CAP-RT-PERSON-ISSUED-PRIMARY-TREE"))
    XCTAssertEqual(named.error?.code, "admissionDenied")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: URL(filePath: stack.profile.projectRoot).appending(path: "entry/build").path),
      "nothing reached the primary tree")

    // 6. The receipt lost after the child ran: parked, reconciled without a
    // readback, and never run again.
    let lost = try Self.requestJSON(
      "lost-after", operation: "workspace.build-openharmony",
      inputs: Self.buildInputs(project: copyRef, preset: Self.debugPreset, revision: base))
    let lostJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", lost))
    stack.loss.set(true)
    let parked = try await send(stack.handler, frames, "job.run", ["jobId": .string(lostJob)])
    stack.loss.set(false)
    XCTAssertEqual(Self.state(parked), .string("waitingForRecovery"))
    _ = try await send(stack.handler, frames, "job.reconcile", ["jobId": .string(lostJob)])
    let rerun = try await send(stack.handler, frames, "job.run", ["jobId": .string(lostJob)])
    XCTAssertFalse(rerun.ok, "a parked build is never run again")
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(lostJob)])
    // The same build is not admitted again while that use is unsettled.
    let again = try await send(
      stack.handler, frames, "job.submit",
      try Self.requestJSON(
        "lost-after-again", operation: "workspace.build-openharmony",
        inputs: Self.buildInputs(project: copyRef, preset: Self.debugPreset, revision: base)))
    XCTAssertEqual(again.error?.code, "admissionDenied")

    // What the Runtime keeps afterwards.
    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "parked-record.json": try Data(
        contentsOf: root.appending(path: "engine/jobs/\(lostJob)/job-record.json")),
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
    for job in [buildJob, missingJob] {
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
