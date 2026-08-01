// Read-only workspace observations (CHG-2026-055, TASK-HFA-008).
//
// Registered acceptance: HFA-AC-17 (typed-only, argv asserted token for
// token, and the forbidden surfaces stay inexpressible).
//
// These operations exist so the analysis stage can locate evidence without
// anyone handing the loop a shell. What makes that true is not the
// descriptor - it is that the argv below is built from a pinned executable,
// a root this provider resolved itself, and inputs that cannot become
// options. PRODUCT-LOOP §11 records the cost of assuming otherwise twice
// over: typed-level tests were green while production argv was wrong.

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class WorkspaceReadOnlyOperationsContractTests: XCTestCase {
  private var root: URL!
  private var state: URL!
  private var profile: WorkspaceProjectProfile!
  private var provider: WorkspaceOperationsProvider!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-workspace-readonly", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    state = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    profile = try makeProfile(withSourceControl: true)
    provider = makeProvider(profile)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: - HFA-AC-17: argv, token for token

  func testGitStatusLowersRootBoundArgvTokenForToken() throws {
    let plan = try lower("workspace.inspect-git-status@1", inputs: ["projectRef": .string("TestProject")])
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("a host-only read must lower to a process plan")
    }
    // `-C <root>` first: git runs in the root this provider resolved, and no
    // input in the request can move it.
    XCTAssertEqual(
      argv,
      ["-C", profile.projectRoot, "status", "--porcelain=v1", "--untracked-files=all"])
  }

  func testDiffLowersRevisionAndScopeAfterTheOptionTerminator() throws {
    let plan = try lower(
      "workspace.inspect-diff@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "baseRevision": .string("HEAD~1"),
        "pathScope": .string("Sources/*.swift"),
      ])
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("a host-only read must lower to a process plan")
    }
    XCTAssertEqual(
      argv,
      ["-C", profile.projectRoot, "diff", "--stat", "HEAD~1", "--", "Sources/*.swift"])
    // The terminator is what makes a scope that starts with a dash
    // unreachable as an option, so its position is part of the contract.
    XCTAssertEqual(argv.firstIndex(of: "--"), argv.count - 2)
  }

  func testARevisionOrScopeThatCouldBecomeAnOptionOrAPathIsRefused() {
    for revision in ["-fsomething", "../etc", "a/b", "HEAD;rm", "..", ""] {
      XCTAssertThrowsError(
        try action(
          "workspace.inspect-diff@1",
          inputs: [
            "projectRef": .string("TestProject"),
            "baseRevision": .string(revision),
            "pathScope": .string("Sources/*"),
          ]), "revision \(revision) must be refused")
    }
    for scope in ["-x", "/etc/passwd", "../../etc", "Sources/$(id)", ""] {
      XCTAssertThrowsError(
        try action(
          "workspace.inspect-diff@1",
          inputs: [
            "projectRef": .string("TestProject"),
            "baseRevision": .string("HEAD"),
            "pathScope": .string(scope),
          ]), "scope \(scope) must be refused")
    }
  }

  func testAForeignProjectReferenceIsRefusedRatherThanResolved() {
    XCTAssertThrowsError(
      try action("workspace.inspect-git-status@1", inputs: ["projectRef": .string("OtherProject")]))
  }

  // MARK: - Availability: no preset, no admission

  func testWithoutAPinnedSourceControlToolBothOperationsReportUnavailable() throws {
    let bare = try makeProfile(withSourceControl: false)
    let bareProvider = makeProvider(bare)
    for reference in ["workspace.inspect-git-status@1", "workspace.inspect-diff@1"] {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      guard case .unavailable(let reason) = bareProvider.runtimeAvailability(for: descriptor) else {
        return XCTFail("\(reference) must be unavailable without a pinned git")
      }
      // Machine-readable, so `operation.list` can say why rather than fail
      // at run time after a capability was already spent (PRODUCT-LOOP §8).
      XCTAssertEqual(reason, "workspace.presetUnavailable")
    }
  }

  // MARK: - Semantics: an empty read is an observation

  func testACleanTreeIsAnObservationAndNotAFailure() throws {
    let action = try action(
      "workspace.inspect-git-status@1", inputs: ["projectRef": .string("TestProject")])
    let outcome = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: ""),
      action: .workspace(action), context: context())
    guard case .verified(let summary) = outcome else {
      return XCTFail("exit 0 with no output is a clean tree, not a failure")
    }
    XCTAssertEqual(summary["dirty"], "false")

    let dirty = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: " M Sources/App.txt\n"),
      action: .workspace(action), context: context())
    guard case .verified(let dirtySummary) = dirty else {
      return XCTFail("a dirty tree is still a successful read")
    }
    XCTAssertEqual(dirtySummary["dirty"], "true")
  }

  func testANonZeroExitIsAFailureAndNotAnEmptyObservation() throws {
    let action = try action(
      "workspace.inspect-git-status@1", inputs: ["projectRef": .string("TestProject")])
    let outcome = try provider.verify(
      receipt: receipt(exitStatus: 128, stdout: ""),
      action: .workspace(action), context: context())
    guard case .failed(let code, _) = outcome else {
      return XCTFail("a broken read must not read as a clean tree")
    }
    XCTAssertEqual(code, "workspace.gitStatusFailed")
  }

  func testRecoveryOfAReadConfirmsNothingHappened() async throws {
    let action = try action(
      "workspace.inspect-git-status@1", inputs: ["projectRef": .string("TestProject")])
    let outcome = try await provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: "job-workspace", stepID: "inspect-git-status",
        intentEventID: "evt-inspect-git-status", action: .workspace(action)),
      context: context())
    // A read writes nothing, so there is no side effect for recovery to
    // confirm and repeating it cannot double anything.
    XCTAssertEqual(outcome, .confirmedNotExecuted)
  }

  // MARK: - Bounded reads and checkpoints

  func testAReadRangeLowersAProfileScopedPathAndABoundedSpan() throws {
    let plan = try lower(
      "workspace.read-source-range@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "filePath": .string("Sources/App.txt"),
        "lineStart": .integer(10),
        "lineEnd": .integer(20),
      ])
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("a host-only read must lower to a process plan")
    }
    XCTAssertEqual(
      argv,
      ["-n", "10,20p", root.appendingPathComponent("Sources/App.txt").path])
  }

  func testAnUnboundedOrEscapingReadRangeIsRefused() {
    let cases: [(String, Int64, Int64)] = [
      ("Sources/App.txt", 1, 5000),  // span beyond the declared bound
      ("Sources/App.txt", 20, 10),  // inverted
      ("../../etc/passwd", 1, 5),  // traversal
      ("/etc/passwd", 1, 5),  // absolute
      ("Docs/Secret.txt", 1, 5),  // outside the profile globs
    ]
    for (path, start, end) in cases {
      XCTAssertThrowsError(
        try action(
          "workspace.read-source-range@1",
          inputs: [
            "projectRef": .string("TestProject"),
            "filePath": .string(path),
            "lineStart": .integer(start),
            "lineEnd": .integer(end),
          ]), "\(path) \(start)-\(end) must be refused")
    }
  }

  func testACheckpointLowersStashCreateAndMovesNothing() throws {
    let plan = try lower(
      "workspace.create-checkpoint@1", inputs: ["projectRef": .string("TestProject")])
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("a checkpoint must lower to a process plan")
    }
    // `stash create` writes an object and moves no ref, index or worktree.
    XCTAssertEqual(argv, ["-C", profile.projectRoot, "stash", "create"])
    XCTAssertFalse(argv.contains("push"))
    XCTAssertFalse(argv.contains("commit"))
  }

  func testACheckpointWithoutAnObjectIsAFailureNotASuccess() throws {
    let action = try action(
      "workspace.create-checkpoint@1", inputs: ["projectRef": .string("TestProject")])
    // git prints nothing when there is nothing to stash. Calling that a
    // checkpoint would let the repair leg believe it can roll back.
    let empty = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: "\n"),
      action: .workspace(action), context: context())
    guard case .failed(let code, _) = empty else {
      return XCTFail("an empty checkpoint must not verify")
    }
    XCTAssertEqual(code, "workspace.checkpointEmpty")

    let oid = String(repeating: "a1b2c3d4", count: 5)
    let made = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: oid + "\n"),
      action: .workspace(action), context: context())
    guard case .verified(let summary) = made else {
      return XCTFail("a real object id is a checkpoint")
    }
    XCTAssertEqual(summary["checkpointObject"], oid)
  }

  func testANonGitCheckpointSealsExactFilesAndCanBeReconciled() async throws {
    let source = root.appendingPathComponent("Sources/App.txt")
    try Data("old\n".utf8).write(to: source)
    let archiveProfile = try makeArchiveProfile()
    let archiveProvider = makeProvider(archiveProfile)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.create-checkpoint@1"))
    let snapshots = try WorkspaceProviderSupport.snapshots(
      relativePaths: ["Sources/App.txt"], root: archiveProfile.projectRoot)
    let action = try archiveProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "expectedWorkspaceRevision": .string(WorkspaceProviderSupport.revision(snapshots)),
        "checkpointFilePaths": .array([.string("Sources/App.txt")]),
      ], context: context())
    guard case .workspace(.createArchiveCheckpoint(let checkpoint)) = action
    else {
      return XCTFail("a non-Git profile must lower an exact sealed archive checkpoint")
    }
    let journalStep = try RuntimeJobEngine.journalStep(
      for: descriptor.steps[0], jobID: context().jobID,
      inputs: ["projectRef": .string("TestProject")], action: action)
    XCTAssertEqual(journalStep.arguments["projectRef"], .string("TestProject"))
    XCTAssertEqual(journalStep.arguments["artifactId"], .string("checkpoint.txt"))
    let archivePath = checkpoint.archivePath
    XCTAssertEqual(
      checkpoint.invocation.arguments,
      [
        "-c", "-f", archivePath, "-C", archiveProfile.projectRoot, "--",
        "Sources/App.txt",
      ])

    let dispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: archiveProfile))
    let receipt = try await dispatcher.dispatch(
      try archiveProvider.lower(action: action, context: context()))
    guard case .verified(let summary) = try archiveProvider.verify(
      receipt: receipt, action: action, context: context())
    else {
      return XCTFail("the archive must exist and preserve the exact source snapshot")
    }
    XCTAssertEqual(summary["checkpointKind"], "sealedArchive")
    XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
    XCTAssertEqual(try Data(contentsOf: source), Data("old\n".utf8))

    let recovered = try await archiveProvider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: context().jobID, stepID: context().stepID,
        intentEventID: "evt-checkpoint", action: action),
      context: context())
    guard case .confirmedCompleted(let recoveredSummary) = recovered else {
      return XCTFail("a durable provider-owned archive must be recoverable after restart")
    }
    XCTAssertEqual(
      recoveredSummary["checkpointObject"], summary["checkpointObject"])

    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: archivePath))
    try handle.truncate(atOffset: 512)
    try handle.close()
    let partial = try await archiveProvider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: context().jobID, stepID: context().stepID,
        intentEventID: "evt-checkpoint", action: action),
      context: context())
    guard case .stillUnknown = partial else {
      return XCTFail("a receipt-lost partial archive must never be reported completed")
    }
  }

  func testWaterFlowPublishesThePinnedNonGitCheckpointRoute() throws {
    let project = root.appendingPathComponent("WaterFlow", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("entry/src/main", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appendingPathComponent("build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appendingPathComponent("entry/src/main/module.json5"))
    let script = project.appendingPathComponent("hvigorw.js")
    try Data("// fixture".utf8).write(to: script)

    let production = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, nodePath: "/usr/bin/true", hvigorScriptPath: script.path)
    XCTAssertNil(production.sourceControlPreset)
    XCTAssertEqual(production.archiveCheckpointPreset?.executable.path, "/usr/bin/bsdtar")
    XCTAssertEqual(production.archiveCheckpointPreset?.presetID, "sealed-source-archive")
    let checkpoint = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.create-checkpoint@1"))
    XCTAssertEqual(makeProvider(production).runtimeAvailability(for: checkpoint), .available)
  }

  // MARK: - The published surface stays closed

  func testTheCheckpointIsAnAuthorizedMutationNotARead() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.create-checkpoint@1"))
    // It writes a git object. Publishing it as a read would let it run under
    // the default read-only policy, which is what r2 closed.
    XCTAssertEqual(descriptor.minimumEffect, .deviceMutation)
    XCTAssertEqual(descriptor.authorization[.deviceMutation], .standingCapability)
    XCTAssertFalse(descriptor.defaultPolicyIssuanceEnabled)
  }

  func testTheForbiddenWorkspaceSurfacesAreNotExpressible() {
    for forbidden in [
      "workspace.run-shell@1", "workspace.execute-command@1", "workspace.run-git@1",
      "workspace.write-file@1", "workspace.run-arbitrary-script@1",
    ] {
      XCTAssertNil(
        RuntimeOperationCatalog.descriptor(reference: forbidden),
        "\(forbidden) must not exist in the published catalog")
    }
  }

  func testBothNewOperationsAreHostOnlyReadsInTheCatalog() throws {
    // create-checkpoint left this family in TASK-HFA-009 r2: it writes a git
    // object, so it is now E1 and needs a workspace-scoped capability. The
    // three reads below still write nothing.
    for reference in [
      "workspace.inspect-git-status@1", "workspace.inspect-diff@1",
      "workspace.read-source-range@1",
    ] {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      XCTAssertEqual(descriptor.provider, .workspace)
      XCTAssertEqual(descriptor.binding, WorkflowBindingRequirement.none)
      XCTAssertEqual(descriptor.minimumEffect, .hostOnly)
      XCTAssertEqual(descriptor.steps.count, 1)
      XCTAssertEqual(descriptor.steps[0].effect, .hostOnly)
    }
  }

  // MARK: - Helpers

  private func makeProfile(withSourceControl: Bool) throws -> WorkspaceProjectProfile {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let git = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/git")
    let sed = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/sed")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let sourceControl =
      withSourceControl
      ? try WorkspaceCommandPreset(
        presetID: "git", executable: git, fixedArguments: [], timeoutSeconds: 30)
      : nil
    return try WorkspaceProjectProfile(
      profileID: "test-workspace@1", projectRef: "TestProject",
      projectRoot: root.path,
      allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, sourceControlPreset: sourceControl,
      sourceReaderPreset: withSourceControl
        ? try WorkspaceCommandPreset(
          presetID: "read", executable: sed, fixedArguments: [], timeoutSeconds: 10)
        : nil,
      patchPreset: patching,
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
  }

  private func makeArchiveProfile() throws -> WorkspaceProjectProfile {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let tar = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/bsdtar")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let checkpointing = try WorkspaceCommandPreset(
      presetID: "sealed-source-archive", executable: tar,
      fixedArguments: [], timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: "test-workspace@1", projectRef: "TestProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, archiveCheckpointPreset: checkpointing,
      patchPreset: patching,
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
  }

  private func makeProvider(_ profile: WorkspaceProjectProfile) -> WorkspaceOperationsProvider {
    WorkspaceOperationsProvider(
      profile: profile,
      attemptStore: try! WorkspacePatchAttemptStore(
        rootURL: state.appendingPathComponent(UUID().uuidString, isDirectory: true)),
      nowUTC: { "2026-07-31T00:00:00Z" })
  }

  private func context() -> ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-workspace", stepID: "workspace-step", targetID: "workspace-test",
      bindingRevision: nil, nowUTC: "2026-07-31T00:00:00Z")
  }

  private func action(
    _ reference: String, inputs: [String: JSONValue]
  ) throws -> WorkspaceProviderAction {
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
    let action = try provider.action(
      for: descriptor.steps[0], operation: descriptor, inputs: inputs, context: context())
    guard case .workspace(let workspace) = action else {
      throw DeviceProviderError.unsupportedAction("not a workspace action")
    }
    return workspace
  }

  private func lower(
    _ reference: String, inputs: [String: JSONValue]
  ) throws -> TypedProcessPlan {
    try provider.lower(action: .workspace(try action(reference, inputs: inputs)), context: context())
  }

  private func receipt(exitStatus: Int32, stdout: String) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: exitStatus, stdout: Data(stdout.utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.005)
  }
}
