// Shared Swift oracle for the Rust port of `workspace.apply-patch@1` and
// `workspace.revert-patch@1` (TASK-XPA-015, M3): one Runtime-owned isolated
// copy and every patch Job the production control plane answers against it
// and against the person's primary tree — plan, submit, run, reconcile and
// result, in order — then what the Runtime keeps afterwards: the durable
// patch attempts, the capability store, the copy's tree, the copy's
// adoption by a restarted isolation manager at three points, and the durable
// record of the Job whose receipt was lost after its child ran.
//
// The sequence covers a stale revision (refused by name, nothing admitted), a
// patch outside the declared scope (refused before admission), an applied
// patch (a Runtime-issued capability, consumed before the child), a hunk that
// does not apply (the Job fails), an exact revert, a revert of an attempt
// already reverted, a patch against the primary tree with no capability and
// with one the Runtime never issued (both refused before admission), and two
// receipts lost to the Runtime: before the child ran (reconciled not
// executed) and after it ran (reconciled still unknown, parked, never run
// again).
//
// The job.* corpora carry no frame of these operations and are deduplicated
// by shape, so they cannot be replayed as one sequence. Host-local only: a
// fabricated source tree under a fixed root, no device, no daemon process.
// `patch.sh` in the fixture stands in for `/usr/bin/patch` with fixed bytes,
// so the plan digests and capability identities repeat on every host; it runs
// the host's patch with the argv the Runtime lowered. Record with
// `ARKDECK_RUST_WORKSPACE_PATCH_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Whether the oracle's patch dispatch hands its receipt back to the
/// Runtime: always, or lost before or after the child ran.
private final class PatchReceiptLoss: @unchecked Sendable {
  enum Mode: Sendable {
    case none
    case beforeChild
    case afterChild
  }

  private let lock = NSLock()
  private var mode = Mode.none

  func set(_ mode: Mode) { lock.withLock { self.mode = mode } }
  var current: Mode { lock.withLock { mode } }
}

/// The production workspace dispatch, except that a patch's receipt can be
/// lost the way a crashed or unobservable child loses it.
private struct ReceiptLosingDispatcher: RuntimeProcessDispatching {
  static let lostBefore =
    "dispatch outcome unobservable: the oracle lost the receipt before the child ran"
  static let lostAfter =
    "dispatch outcome unobservable: the oracle lost the receipt after the child ran"

  let base: any RuntimeProcessDispatching
  let loss: PatchReceiptLoss

  func unavailableReason(providerID: String) -> String? {
    base.unavailableReason(providerID: providerID)
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .workspace(.applyPatch) = plan.action else {
      return try await base.dispatch(plan)
    }
    switch loss.current {
    case .none:
      return try await base.dispatch(plan)
    case .beforeChild:
      throw RuntimeDispatchFailure.outcomeUnknown(Self.lostBefore)
    case .afterChild:
      _ = try await base.dispatch(plan)
      throw RuntimeDispatchFailure.outcomeUnknown(Self.lostAfter)
    }
  }
}

final class WorkspacePatchOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-patch-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_PATCH_RECORD"
  /// The recording's fixed root: the profile pins the source tree by path,
  /// and the lowered argv names the copy and the patch Artifact by path.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-patch-oracle", directoryHint: .isDirectory)
  /// A capability's clock is whole seconds.
  private static let timestamp = "2026-09-20T00:00:00Z"
  private static let project = "PatchOracleProject"
  private static let profileID = "workspace-patch-oracle@1"
  private static let inputJob = "job-input-patch"
  private static let goodPatch =
    "--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1 @@\n-old\n+new\n"
  private static let conflictPatch =
    "--- a/Sources/App.txt\n+++ b/Sources/App.txt\n@@ -1 +1 @@\n-stale\n+newer\n"
  private static let outsidePatch =
    "--- a/Sources/Other.txt\n+++ b/Sources/Other.txt\n@@ -1 +1 @@\n"
    + "-outside the narrowed scope\n+changed\n"
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
    let loss: PatchReceiptLoss
  }

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

  /// The fixture's stand-in patch tool, executable, beside the source.
  private func patchTool(in root: URL) throws -> URL {
    let tools = root.appending(path: "tools", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let tool = tools.appending(path: "patch")
    try Data(contentsOf: Self.oracle.appending(path: "patch.sh")).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    return tool
  }

  private func profile(source: URL, tool: URL) throws -> WorkspaceProjectProfile {
    let preset = { (id: String, path: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: try WorkspaceExecutableIdentity.hashing(path: path),
        fixedArguments: [], timeoutSeconds: 10)
    }
    return try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: source.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: try preset("inspect", "/usr/bin/grep"),
      patchPreset: try preset("patch", tool.path),
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = try sourceTree(in: root)
    let profile = try profile(source: source, tool: try patchTool(in: root))
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
    let loss = PatchReceiptLoss()
    let dispatcher = ReceiptLosingDispatcher(
      base: RuntimeOwnedWorkspaceDispatcher(
        fallback: DescriptorBoundProcessDispatcher(
          resolver: WorkspaceActionExecutableResolver(profile: profile)),
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

  /// Publishes one unified diff under the input Job, bound to the host
  /// target the patch Jobs name, and returns its lease.
  private func publishPatch(
    _ store: RuntimeArtifactStore, name: String, contents: String
  ) async throws -> String {
    let metadata = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: Self.inputJob, sessionID: "session-input-patch", stepID: "import-patch",
        name: name, mediaType: "text/x-diff", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-workspace-patch", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "workspace-host", bindingRevision: nil, stableIdentitySHA256: nil),
        contents: Data(contents.utf8)))
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

  private static func applyInputs(
    project: String, lease: String, revision: String?, globs: [String] = ["Sources/App.txt"]
  ) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = [
      "projectRef": .string(project), "patchArtifactRef": .string(lease),
      "allowedFileGlobs": .array(globs.map(JSONValue.string)),
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
        domain: "WorkspacePatchOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  /// A restarted isolation manager's adoption over the same state: the
  /// copies it cannot vouch for, by name.
  private func adoption(_ root: URL, profile: WorkspaceProjectProfile) throws -> [String] {
    let manager = try EvolutionWorkspaceManager(
      rootURL: root.appending(path: "evolution-workspaces", directoryHint: .isDirectory),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile),
      patchLineage: try WorkspacePatchAttemptStore(
        rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory)))
    return manager.adoptRuntimeWorkspaces()
  }

  // MARK: The recording

  func testTheControlPlaneAppliesAndRevertsPatchesAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()
    let good = try await publishPatch(stack.artifacts, name: "good.patch", contents: Self.goodPatch)
    let conflict = try await publishPatch(
      stack.artifacts, name: "conflict.patch", contents: Self.conflictPatch)
    let outside = try await publishPatch(
      stack.artifacts, name: "outside.patch", contents: Self.outsidePatch)

    // The Runtime-owned copy every patch below is applied to.
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: stack.profile.projectRoot, profileVersion: stack.profile.profileID,
      globs: stack.profile.allowedFileGlobs)
    let copy = try Self.requestJSON(
      "copy", operation: "workspace.prepare-isolated-copy",
      inputs: [
        "projectRef": .string(Self.project),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
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
    let revision = { () throws -> String in
      try WorkspaceProviderSupport.workspaceRevision(
        root: copyTree.path, profileVersion: Self.profileID, globs: ["Sources/App.txt"])
    }
    let base = try revision()

    // 1. A stale revision: refused by name, nothing admitted.
    let stale = try Self.requestJSON(
      "stale", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(
        project: copyRef, lease: good, revision: String(repeating: "0", count: 64)))
    for method in ["job.plan", "job.submit"] {
      let answer = try await send(stack.handler, frames, method, stale)
      XCTAssertFalse(answer.ok, method)
    }
    // 2. A patch outside the copy's scope: refused before admission.
    let wide = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON(
        "outside", operation: "workspace.apply-patch",
        inputs: Self.applyInputs(project: copyRef, lease: outside, revision: base)))
    XCTAssertFalse(wide.ok)

    // 3. The patch applied to the copy under a Runtime-issued capability.
    let apply = try Self.requestJSON(
      "apply", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(project: copyRef, lease: good, revision: base))
    let planned = try await send(stack.handler, frames, "job.plan", apply)
    XCTAssertTrue(planned.ok, "apply plan: \(String(describing: planned.error))")
    let applyJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", apply))
    let applied = try await send(stack.handler, frames, "job.run", ["jobId": .string(applyJob)])
    XCTAssertEqual(Self.state(applied), .string("succeeded"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(applyJob)])
    XCTAssertEqual(
      try Data(contentsOf: copyTree.appending(path: "Sources/App.txt")), Data("new\n".utf8))
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: stack.profile.projectRoot).appending(path: "Sources/App.txt")),
      Data("old\n".utf8), "the primary tree is untouched")
    let patched = try revision()
    let goodSHA = SHA256Hex.string(of: Data(Self.goodPatch.utf8))
    let attempt =
      "patch-"
      + SHA256Hex.string(of: Data("\(applyJob)\n\(goodSHA)\n\(copyRef)".utf8)).prefix(32)
    let afterApply = try adoption(root, profile: stack.profile)
    XCTAssertEqual(afterApply, [], "the lineage vouches for the patched copy")

    // 4. A hunk that does not apply: the Job fails.
    let hunk = try Self.requestJSON(
      "conflict", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(project: copyRef, lease: conflict, revision: patched))
    _ = try await send(stack.handler, frames, "job.plan", hunk)
    let hunkJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", hunk))
    let failed = try await send(stack.handler, frames, "job.run", ["jobId": .string(hunkJob)])
    XCTAssertEqual(Self.state(failed), .string("failed"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(hunkJob)])

    // 5. The exact attempt reverted.
    let revert = try Self.requestJSON(
      "revert", operation: "workspace.revert-patch",
      inputs: [
        "projectRef": .string(copyRef), "patchAttemptRef": .string(String(attempt)),
        "expectedWorkspaceRevision": .string(patched),
      ])
    _ = try await send(stack.handler, frames, "job.plan", revert)
    let revertJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", revert))
    let reverted = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(revertJob)])
    XCTAssertEqual(Self.state(reverted), .string("succeeded"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(revertJob)])
    XCTAssertEqual(
      try Data(contentsOf: copyTree.appending(path: "Sources/App.txt")), Data("old\n".utf8))
    XCTAssertEqual(try revision(), base)
    let afterRevert = try adoption(root, profile: stack.profile)
    XCTAssertEqual(afterRevert, [])

    // 6. An attempt already reverted is not reverted again.
    let again = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON(
        "revert-again", operation: "workspace.revert-patch",
        inputs: [
          "projectRef": .string(copyRef), "patchAttemptRef": .string(String(attempt)),
          "expectedWorkspaceRevision": .string(base),
        ]))
    XCTAssertFalse(again.ok)

    // 7. The person's primary tree: planned, never admitted without a
    // capability a person issued.
    let primary = try Self.requestJSON(
      "primary", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(project: Self.project, lease: good, revision: nil))
    let primaryPlan = try await send(stack.handler, frames, "job.plan", primary)
    XCTAssertTrue(primaryPlan.ok, "primary plan: \(String(describing: primaryPlan.error))")
    let refused = try await send(stack.handler, frames, "job.submit", primary)
    XCTAssertEqual(refused.error?.code, "admissionDenied")
    let named = try await send(
      stack.handler, frames, "job.submit",
      try Self.requestJSON(
        "primary-named", operation: "workspace.apply-patch",
        inputs: Self.applyInputs(project: Self.project, lease: good, revision: nil),
        authorization: "CAP-RT-PERSON-ISSUED-PRIMARY-TREE"))
    XCTAssertEqual(named.error?.code, "admissionDenied")
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: stack.profile.projectRoot).appending(path: "Sources/App.txt")),
      Data("old\n".utf8), "nothing reached the primary tree")

    // 8. The receipt lost before the child ran: parked, then reconciled as
    // not executed, the tree untouched.
    let before = try Self.requestJSON(
      "lost-before", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(project: copyRef, lease: good, revision: base))
    let beforeJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", before))
    stack.loss.set(.beforeChild)
    let parkedBefore = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(beforeJob)])
    stack.loss.set(.none)
    XCTAssertEqual(Self.state(parkedBefore), .string("waitingForRecovery"))
    _ = try await send(stack.handler, frames, "job.reconcile", ["jobId": .string(beforeJob)])
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(beforeJob)])
    XCTAssertEqual(try revision(), base)
    // The same mutation is not admitted again while that use is unsettled.
    let resubmitted = try await send(
      stack.handler, frames, "job.submit",
      try Self.requestJSON(
        "lost-before-again", operation: "workspace.apply-patch",
        inputs: Self.applyInputs(project: copyRef, lease: good, revision: base)))
    XCTAssertEqual(resubmitted.error?.code, "admissionDenied")

    // 9. The receipt lost after the child ran: parked, reconciled still
    // unknown, and never run again. A wider request scope is another plan,
    // so another capability.
    let after = try Self.requestJSON(
      "lost-after", operation: "workspace.apply-patch",
      inputs: Self.applyInputs(
        project: copyRef, lease: good, revision: base, globs: ["Sources/**"]))
    let afterJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", after))
    stack.loss.set(.afterChild)
    let parkedAfter = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(afterJob)])
    stack.loss.set(.none)
    XCTAssertEqual(Self.state(parkedAfter), .string("waitingForRecovery"))
    _ = try await send(stack.handler, frames, "job.reconcile", ["jobId": .string(afterJob)])
    let rerun = try await send(stack.handler, frames, "job.run", ["jobId": .string(afterJob)])
    XCTAssertFalse(rerun.ok, "a parked patch is never run again")
    XCTAssertEqual(try revision(), patched, "the lost child did patch the copy")
    let final = try adoption(root, profile: stack.profile)
    XCTAssertEqual(final, ["\(workspaceID):revision"], "no lineage vouches for that change")

    // What the Runtime keeps afterwards.
    let parked = try Data(
      contentsOf: root.appending(path: "engine/jobs/\(afterJob)/job-record.json"))
    let adoptions = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "afterApply": .array(afterApply.map(JSONValue.string)),
        "afterRevert": .array(afterRevert.map(JSONValue.string)),
        "final": .array(final.map(JSONValue.string)),
      ]))
    let tree = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "workspaceID": .string(workspaceID),
        "entries": .array(
          try Self.tree(at: copyTree).map {
            .object(["path": .string($0.0), "sha256": .string($0.1)])
          }),
      ]))
    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "adoption.json": adoptions,
      "tree.json": tree,
      "parked-record.json": parked,
    ]
    for (directory, prefix) in [
      ("artifacts/\(Self.inputJob)", "artifacts/\(Self.inputJob)/"),
      ("workspace-patch-attempts", "attempts/"),
      ("capabilities", "capabilities/"),
    ] {
      let url = root.appending(path: directory, directoryHint: .isDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      where !name.hasPrefix(".") {
        durable[prefix + name] = try Data(contentsOf: url.appending(path: name))
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
}
