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
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class WorkspaceReadOnlyOperationsContractTests: XCTestCase {
  private var root: URL!
  private var state: URL!
  private var profile: WorkspaceProjectProfile!
  private var provider: WorkspaceOperationsProvider!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-workspace-readonly", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    state = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
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
    let plan = try lower(
      "workspace.inspect-git-status@1", inputs: ["projectRef": .string("TestProject")])
    guard case .process(_, let argv, _) = plan.kind else {
      return XCTFail("a host-only read must lower to a process plan")
    }
    // `-C <root>` first: git runs in the root this provider resolved, and no
    // input in the request can move it. `-- .` then confines the answer to
    // that root: `-C` only picks the working directory, and `git status`
    // without a pathspec describes the whole repository.
    XCTAssertEqual(
      argv,
      [
        "-C", profile.projectRoot, "status", "--porcelain=v1", "--untracked-files=all",
        "--", ".",
      ])
  }

  /// The reason the pathspec is not cosmetic. A project checked into a larger
  /// repository — which is how the WaterFlow demo ships — would otherwise have
  /// its status answered with the containing repository's working tree, so a
  /// read scoped to one project returned every unrelated modified and
  /// untracked file around it.
  /// What decides whether the WaterFlow profile offers source control at all.
  /// Asking whether the project root itself holds `.git` answers "no" for
  /// every project checked into a larger repository, which is exactly how the
  /// demo ships — so the question is whether some ancestor does.
  func testAProjectInsideARepositoryCountsAsSourceControlled() throws {
    let repository = root.appending(path: "walk-repo", directoryHint: .isDirectory)
    let nested = repository.appending(path: "a/b/c", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    XCTAssertFalse(
      WorkspaceProjectProfile.isInsideGitWorkingCopy(nested.path),
      "no .git anywhere above it yet")

    try FileManager.default.createDirectory(
      at: repository.appending(path: ".git", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    XCTAssertTrue(
      WorkspaceProjectProfile.isInsideGitWorkingCopy(nested.path),
      "a project nested in a working copy is source controlled by it")
    XCTAssertTrue(
      WorkspaceProjectProfile.isInsideGitWorkingCopy(repository.path),
      "and so is the repository root itself")
  }

  func testStatusOfANestedProjectDoesNotDescribeTheRepositoryAroundIt() throws {
    let repository = root.appending(path: "outer-repo", directoryHint: .isDirectory)
    let project = repository.appending(path: "nested/project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    for argv in [
      ["init", "--quiet"], ["config", "user.email", "t@invalid.example"],
      ["config", "user.name", "T"],
    ] {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/git")
      process.arguments = ["-C", repository.path] + argv
      try process.run()
      process.waitUntilExit()
    }
    try Data("outside\n".utf8).write(to: repository.appending(path: "OUTSIDE.txt"))
    try Data("inside\n".utf8).write(to: project.appending(path: "INSIDE.txt"))

    func status(_ extra: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/git")
      process.arguments =
        ["-C", project.path, "status", "--porcelain=v1", "--untracked-files=all"] + extra
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    }

    // Without the pathspec the containing repository leaks in.
    let unscoped = try status([])
    XCTAssertTrue(unscoped.contains("OUTSIDE.txt"), "precondition: git reports the whole repo")

    // With it, the answer is the project the caller asked about.
    let scoped = try status(["--", "."])
    XCTAssertFalse(
      scoped.contains("OUTSIDE.txt"),
      "a status scoped to one project must not report the repository around it")
    XCTAssertTrue(scoped.contains("INSIDE.txt"), "the project's own files still appear")
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
      guard
        case .unavailable(let code, let reason) =
          bareProvider.runtimeAvailability(for: descriptor)
      else {
        return XCTFail("\(reference) must be unavailable without a pinned git")
      }
      // Machine-readable, so `operation.list` can say why rather than fail
      // at run time after a capability was already spent (PRODUCT-LOOP §8).
      XCTAssertEqual(code, .workspacePresetUnavailable)
      XCTAssertEqual(reason, "workspace.presetUnavailable")
      // And it stays the operator's to fix: `sourceControlPreset` exists
      // exactly when the configured project root is a git working copy, so
      // pointing `--workspace-project` at one reaches these two.
      XCTAssertEqual(code.origin, .hostConfiguration, reference)
    }
  }

  /// A missing symbolizer is host configuration, and this test used to assert
  /// the opposite.
  ///
  /// It was written against a build where both profile factories really did
  /// pass `symbolPresets: [:]`, and it kept passing after `waterFlowDemo`
  /// gained a `symbolizerPath` the daemon feeds from `ARKDECK_ANALYZER_PATH` —
  /// it asserted what the code did rather than what was true. The reason it
  /// pinned, `productBuild`, is documented as "no local configuration reaches
  /// this", so a caller that believed it stopped looking for a setting that
  /// exists.
  func testTheSymbolizerIsReportedAsHostConfigurationRatherThanAMissingCapability() throws {
    let bare = try makeProfile(withSourceControl: false)
    let bareProvider = makeProvider(bare)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.symbolize-crash@1"))
    guard case .unavailable(let code, let reason) = bareProvider.runtimeAvailability(
      for: descriptor)
    else {
      return XCTFail("symbolize-crash must be unavailable without a symbol preset")
    }
    XCTAssertEqual(code, .workspacePresetUnavailable)
    // Named apart from the generic preset reason so the caller learns which
    // preset is missing, the same way the signing lane already answers.
    XCTAssertEqual(reason, "workspace.symbolPresetUnavailable")
    XCTAssertEqual(
      code.origin, .hostConfiguration,
      "configuring an analyzer reaches this operation, so the caller must not be told to stop")
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
      ["-n", "10,20p", root.appending(path: "Sources/App.txt").path])
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
    let source = root.appending(path: "Sources/App.txt")
    try Data("old\n".utf8).write(to: source)
    let archiveProfile = try makeArchiveProfile()
    let archiveProvider = makeProvider(archiveProfile)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.create-checkpoint@1"))
    // The stated revision is the profile-scoped workspace revision - the one
    // digest the authorization facts, the issued capability's scope and
    // `apply-patch` all speak. A digest of only `checkpointFilePaths` is not
    // it, and demanding that narrower one made this leg unreachable for the
    // only caller that has ever sent it.
    let action = try archiveProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "expectedWorkspaceRevision": .string(
          try WorkspaceProviderSupport.workspaceRevision(
            root: archiveProfile.projectRoot, profileVersion: archiveProfile.profileID,
            globs: archiveProfile.allowedFileGlobs)),
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
    guard
      case .verified(let summary) = try archiveProvider.verify(
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

    let handle = try FileHandle(forWritingTo: URL(filePath: archivePath))
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
    let project = root.appending(path: "WaterFlow", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: project.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appending(path: "entry/src/main/module.json5"))
    let script = project.appending(path: "hvigorw.js")
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

  func testMultiProjectAvailabilityRoutesTheExactSelectedProfile() throws {
    let first = try makeProfile(withSourceControl: false, projectRef: "FirstProject")
    let second = try makeProfile(withSourceControl: true, projectRef: "SecondProject")
    let registry = try WorkspaceProjectProfileRegistry(profiles: [first, second])
    let union = WorkspaceOperationsProvider(
      profile: first, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: UUID().uuidString, directoryHint: .isDirectory)),
      availabilityProfiles: [first, second],
      nowUTC: { "2026-09-01T00:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.read-source-range@1"))

    XCTAssertEqual(
      union.runtimeAvailability(for: descriptor), .available,
      "one project with the typed preset keeps the global operation route available")
    XCTAssertThrowsError(
      try union.action(
        for: descriptor.steps[0], operation: descriptor,
        inputs: [
          "projectRef": .string("FirstProject"),
          "filePath": .string("Sources/Water.swift"),
          "lineStart": .integer(1), "lineEnd": .integer(2),
        ], context: context()),
      "the union must not lend another project's preset to the selected project")
    XCTAssertNoThrow(
      try union.action(
        for: descriptor.steps[0], operation: descriptor,
        inputs: [
          "projectRef": .string("SecondProject"),
          "filePath": .string("Sources/Water.swift"),
          "lineStart": .integer(1), "lineEnd": .integer(2),
        ], context: context()))
  }

  // MARK: - The published surface stays closed

  func testTheCheckpointIsARuntimeAuthorizedMutationNotARead() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.create-checkpoint@1"))
    // It writes a git object. Publishing it as a read would let it run under
    // the default read-only policy, which is what r2 closed.
    XCTAssertEqual(descriptor.minimumEffect, .deviceMutation)
    XCTAssertEqual(descriptor.authorization[.deviceMutation], .runtimeCapability)
    XCTAssertTrue(descriptor.defaultPolicyIssuanceEnabled)
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

  // MARK: - Engine dispatch

  /// Every other test in this file stops at the provider: it lowers an action
  /// and asserts the argv. That left the engine leg untested, and the engine
  /// leg was missing — none of these three step kinds had an arm in the
  /// journal argument table, so each one reached its `default` and threw
  /// `internalFailure`. Three published, available operations could not be
  /// dispatched at all. Submitting through the engine is what proves the
  /// operation is real, so this test does that rather than lowering again.
  func testEachPublishedReadIsDispatchableThroughTheEngine() async throws {
    for (reference, inputs, artifactName) in [
      (
        "workspace.inspect-git-status@1",
        ["projectRef": JSONValue.string("TestProject")],
        "git-status.txt"
      ),
      (
        "workspace.inspect-diff@1",
        [
          "projectRef": JSONValue.string("TestProject"),
          "baseRevision": .string("HEAD"),
          "pathScope": .string("Sources"),
        ],
        "diff-summary.txt"
      ),
      (
        "workspace.read-source-range@1",
        [
          "projectRef": JSONValue.string("TestProject"),
          "filePath": .string("Sources/Water.swift"),
          "lineStart": .integer(1),
          "lineEnd": .integer(40),
        ],
        "source-range.txt"
      ),
    ] {
      let engine = try makeEngine()
      let acceptance = try await engine.submit(try engineRequest(reference, inputs: inputs))
      let status = try await engine.run(jobID: acceptance.jobID)
      XCTAssertEqual(
        status.state, "succeeded",
        "\(reference) must dispatch, not fail in the engine: \(status.timeline)")

      // The observation lands in the artifact the catalog declares required.
      let stored = try await engineArtifacts.list(jobID: acceptance.jobID)
      XCTAssertTrue(
        stored.contains { $0.name == artifactName },
        "\(reference) must publish \(artifactName), got \(stored.map(\.name))")
    }
  }

  // MARK: - Helpers

  private struct EngineDispatcher: RuntimeProcessDispatching {
    let stdout: Data
    func unavailableReason(providerID: String) -> String? { nil }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: 0, stdout: stdout, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01)
    }
  }

  private var engineArtifacts: RuntimeArtifactStore!

  private func makeEngine() throws -> RuntimeJobEngine {
    let scope = state.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    engineArtifacts = try RuntimeArtifactStore(
      rootURL: scope.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-07-31T00:00:00Z" })
    return try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: scope.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [
        WorkspaceProvider(
          registry: WorkspaceProjectRegistry(roots: ["TestProject": root.path]),
          operations: provider)
      ]),
      dispatcher: EngineDispatcher(stdout: Data("observation\n".utf8)),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: scope.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: engineArtifacts,
      nowUTC: { "2026-07-31T00:00:00Z" })
  }

  private func engineRequest(
    _ reference: String, inputs: [String: JSONValue]
  ) throws -> Data {
    let parts = reference.split(separator: "@")
    let request = try RuntimeOperationRequest(
      requestID: "req-\(UUID().uuidString.prefix(8).lowercased())",
      idempotencyKey: "idem-\(UUID().uuidString.lowercased())",
      target: DurableTargetReference(targetID: "TestProject", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: String(parts[0]), version: Int(parts[1])!),
      inputs: inputs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }

  private func makeProfile(
    withSourceControl: Bool, projectRef: String = "TestProject"
  ) throws -> WorkspaceProjectProfile {
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
      profileID: "test-workspace@1", projectRef: projectRef,
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
        rootURL: state.appending(path: UUID().uuidString, directoryHint: .isDirectory)),
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
    try provider.lower(
      action: .workspace(try action(reference, inputs: inputs)), context: context())
  }

  private func receipt(exitStatus: Int32, stdout: String) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: exitStatus, stdout: Data(stdout.utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.005)
  }
}
