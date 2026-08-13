import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckAgentComposition
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private actor EvolutionNoopJobPort: HarnessRuntimeJobPort {
  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    XCTFail("submission must not dispatch a runtime job")
    return HarnessJobAcceptance(jobID: "JOB-UNEXPECTED", deduplicated: false)
  }
  func startRun(jobID: String) async throws {}
  func observe(jobID: String) async throws -> HarnessJobObservation {
    throw HarnessJobPortError.unknownJob(jobID)
  }
  func requestCancel(jobID: String) async throws {}
}

final class HarnessEvolutionContractTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }

  /// `HFA-AC-24` — the isolated workspace outlives the process that made it.
  ///
  /// Registration happens only on the creation path, so a daemon restart used
  /// to leave a task's `evolution-…` reference unresolvable while its files sat
  /// intact on disk. Everything downstream then failed for reasons that named
  /// something else: on 7.0.0.37 GJ-5 spent three rounds reporting the
  /// workspace revision had "changed to none" and stopped claiming the
  /// evidence was insufficient.
  func testAPersistedEvolutionWorkspaceIsAdoptedByANewProcess() async throws {
    let sourceRoot = try temporaryDirectory("adopt-source")
    let stateRoot = try temporaryDirectory("adopt-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let policy = try HarnessEvolutionPolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/**"]),
      allowedPaths: ["Sources/**"], maxAttempts: 3, maxChangedFiles: 2,
      maxDiffLines: 20, allowedOperations: ["workspace.build-openharmony@1"])
    let evolutionRoot = stateRoot.appendingPathComponent("evolution")

    let created = WorkspaceProjectProfileRegistry(profile: profile)
    let workspace = try await EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: created
    ).prepareWorkspace(
      htaskID: "HTASK-ADOPT-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    let original = try XCTUnwrap(created.profile(for: workspace.projectRef))

    // A new process: the same trees on disk, a registry that has only ever
    // seen the source profile.
    let restarted = WorkspaceProjectProfileRegistry(profile: profile)
    let recovered = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: restarted)
    XCTAssertNil(
      restarted.profile(for: workspace.projectRef),
      "precondition: a fresh registry cannot know a workspace it never created")

    try await recovered.adoptPersistedWorkspace(workspace, policy: policy)

    let adopted = try XCTUnwrap(
      restarted.profile(for: workspace.projectRef),
      "a workspace that survived on disk must survive in the registry")
    XCTAssertEqual(adopted, original, "adoption must reconstruct the same identity")
    XCTAssertEqual(adopted.kind, .evolution)
    XCTAssertNotEqual(
      adopted.projectRoot, profile.projectRoot,
      "adoption must never fall back to the source tree; that cancels the isolation")
  }

  /// `HFA-AC-24` — adoption refuses rather than rebuilds.
  func testAdoptionRefusesAManifestItDoesNotAgreeWith() async throws {
    let sourceRoot = try temporaryDirectory("adopt-conflict-source")
    let stateRoot = try temporaryDirectory("adopt-conflict-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let policy = try HarnessEvolutionPolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/**"]),
      allowedPaths: ["Sources/**"], maxAttempts: 3, maxChangedFiles: 2,
      maxDiffLines: 20, allowedOperations: ["workspace.build-openharmony@1"])
    let evolutionRoot = stateRoot.appendingPathComponent("evolution")
    let created = WorkspaceProjectProfileRegistry(profile: profile)
    let workspace = try await EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: created
    ).prepareWorkspace(
      htaskID: "HTASK-ADOPT-002", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)

    let restarted = WorkspaceProjectProfileRegistry(profile: profile)
    let recovered = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: restarted)
    // The same workspace identity claiming a base revision the manifest never
    // recorded. Rebuilding it silently would substitute one isolated tree for
    // another under a reference the task already holds.
    let drifted = HarnessEvolutionWorkspace(
      workspaceID: workspace.workspaceID, htaskID: workspace.htaskID,
      sourceProjectRef: workspace.sourceProjectRef, projectRef: workspace.projectRef,
      baseRevision: String(repeating: "9", count: 64),
      allowedPathsDigest: workspace.allowedPathsDigest,
      createdAtUTC: workspace.createdAtUTC)
    do {
      try await recovered.adoptPersistedWorkspace(drifted, policy: policy)
      XCTFail("adoption must refuse a workspace the manifest does not describe")
    } catch {
      XCTAssertNil(
        restarted.profile(for: workspace.projectRef),
        "a refused adoption must leave nothing registered")
    }
  }

  func testEvolutionWorkspaceIsIsolatedAndExistingRuntimeProviderResolvesIt() async throws {
    let sourceRoot = try temporaryDirectory("evolution-source")
    let stateRoot = try temporaryDirectory("evolution-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: sourceRoot.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let revision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let policy = try HarnessEvolutionPolicy(
      baseRevision: revision, allowedPaths: ["Sources/**"], maxAttempts: 3,
      maxChangedFiles: 2, maxDiffLines: 20,
      allowedOperations: ["workspace.build-openharmony@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appendingPathComponent("evolution"),
      profileRegistry: registry)

    let workspace = try await manager.prepareWorkspace(
      htaskID: "HTASK-EVOLUTION-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    try await manager.prepareAttemptDirectory(
      workspace: workspace, attemptID: "ATTEMPT-001", ordinal: 1,
      createdAtUTC: timestamp)
    let reopened = try await manager.prepareWorkspace(
      htaskID: "HTASK-EVOLUTION-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    XCTAssertEqual(reopened, workspace)

    let isolated = try XCTUnwrap(registry.profile(for: workspace.projectRef))
    XCTAssertEqual(isolated.kind, .evolution)
    XCTAssertNotEqual(isolated.projectRoot, profile.projectRoot)
    XCTAssertNil(isolated.sourceControlPreset)
    try Data("candidate\n".utf8).write(
      to: URL(fileURLWithPath: isolated.projectRoot)
        .appendingPathComponent("Sources/App.txt"))
    XCTAssertEqual(
      try String(
        contentsOf: sourceRoot.appendingPathComponent("Sources/App.txt"), encoding: .utf8),
      "old\n")

    let provider = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: stateRoot.appendingPathComponent("patch-attempts")),
      nowUTC: { "2026-08-02T00:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))
    let context = ProviderExecutionContext(
      jobID: "job-evolution-build", stepID: descriptor.steps[0].stepID,
      targetID: "workspace-test", bindingRevision: nil, nowUTC: timestamp)
    let action = try provider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string(workspace.projectRef),
        "buildPresetRef": .string("build-ok"),
      ], context: context)
    XCTAssertEqual(
      try provider.lower(action: action, context: context).workingDirectory,
      isolated.projectRoot)
  }

  func testCandidatePatchIsPublishedAsDiffAndMetadataArtifacts() async throws {
    let root = try temporaryDirectory("candidate-source")
    let state = try temporaryDirectory("candidate-state")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: root)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("artifacts"),
      nowUTC: { "2026-08-02T00:00:00Z" })
    let port = WorkspaceHarnessRepairPort(
      profile: profile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appendingPathComponent("attempts")),
      artifactStore: artifactStore)
    let proposal = try patchProposal(root: root)
    let task = try taskSnapshot(
      baseRevision: proposal.baseWorkspaceRevision,
      policy: HarnessEvolutionPolicy(
        baseRevision: proposal.baseWorkspaceRevision,
        allowedPaths: ["Sources/**"], maxAttempts: 3,
        maxChangedFiles: 2, maxDiffLines: 20,
        allowedOperations: evolutionOperations))
    let prepared = try await port.preparePatch(
      proposal, projectRef: profile.projectRef, task: task, decisionID: "dec-evolution")
    let candidate = try await port.candidatePatch(
      proposal: proposal, prepared: prepared, task: task,
      attemptID: "ATTEMPT-001", createdBy: .agent, createdAtUTC: timestamp)

    XCTAssertEqual(candidate.diffArtifactID, prepared.artifactID)
    XCTAssertNotNil(candidate.metadataArtifactID)
    XCTAssertEqual(candidate.changedLines, 2)
    XCTAssertEqual(candidate.files, ["Sources/App.txt"])
    let metadata = try await artifactStore.list(jobID: "hcandidate-attempt-001")
    XCTAssertEqual(metadata.map(\.name), ["candidate-patch.json"])
    XCTAssertEqual(metadata.first?.artifactID, candidate.metadataArtifactID)
  }

  func testTaskSubmissionCreatesEvolutionWorkspaceWithoutDispatching() async throws {
    let source = try temporaryDirectory("submission-source")
    let state = try temporaryDirectory("submission-state")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let evolutionPolicy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 3,
      maxChangedFiles: 2, maxDiffLines: 20,
      allowedOperations: evolutionOperations)
    let workspaceManager = try EvolutionWorkspaceManager(
      rootURL: state.appendingPathComponent("evolution"), profileRegistry: registry)
    let coordinator = HarnessTaskCoordinator(
      store: try HarnessTaskStore(rootURL: state.appendingPathComponent("harness")),
      jobPort: EvolutionNoopJobPort(), evolutionWorkspacePort: workspaceManager,
      nowUTC: { "2026-08-02T00:00:00Z" },
      taskIDFactory: { "HTASK-ABCDEF012345" })
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: profile.projectRef,
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(
        summary: "fix crash",
        desiredState: ["baseWorkspaceRevision": .string(base)]),
      budgets: budgets, policy: HarnessTaskPolicy(allowedOperations: evolutionOperations),
      evolutionPolicy: evolutionPolicy)

    let snapshot = try await coordinator.submit(submission)
    XCTAssertTrue(snapshot.requiresWorkspaceIsolation)
    XCTAssertEqual(snapshot.evolutionPolicy, evolutionPolicy)
    XCTAssertEqual(snapshot.executionProjectRef, snapshot.evolutionWorkspace?.projectRef)
    XCTAssertNotEqual(snapshot.executionProjectRef, snapshot.projectRef)
    XCTAssertNotNil(registry.profile(for: try XCTUnwrap(snapshot.executionProjectRef)))
    let attempts = try await coordinator.attempts(snapshot.htaskID)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testCurrentWorkspaceWireCreatesIsolatedTaskWithoutModeFields() async throws {
    let source = try temporaryDirectory("workspace-wire-source")
    let state = try temporaryDirectory("workspace-wire-state")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appendingPathComponent("workspace"), profileRegistry: registry)
    let coordinator = HarnessTaskCoordinator(
      store: try HarnessTaskStore(rootURL: state.appendingPathComponent("harness")),
      jobPort: EvolutionNoopJobPort(), evolutionWorkspacePort: manager,
      nowUTC: { "2026-08-02T00:00:00Z" },
      taskIDFactory: { "HTASK-ABCDEF012346" })
    let service = HarnessTaskMethodService(
      coordinator: coordinator, applicationReferenceValidator: { _, _ in })

    let response = await service.handle(
      "task.submit", requestID: "wire-current",
      params: [
        "targetId": .string("device"), "goal": .string("repair"),
        "projectRef": .string(profile.projectRef), "baseWorkspaceRevision": .string(base),
        "workspaceAllowedPaths": .array([.string("Sources/**")]),
        "workspaceAllowedOperations": .array([.string("workspace.apply-patch@1")]),
      ])
    XCTAssertNil(response.errorCode, response.errorMessage ?? "unexpected task.submit error")
    guard case .object(let fields)? = response.result else {
      return XCTFail("task.submit must return the task object")
    }
    XCTAssertNil(fields["executionMode"])
    XCTAssertNotEqual(fields["evolutionPolicy"], .null)
    XCTAssertNotEqual(fields["evolutionWorkspace"], .null)
  }

  func testTaskAttemptPatchBuildEvaluationAndPromotionPipeline() throws {
    let base = String(repeating: "a", count: 64)
    let patchRevision = String(repeating: "b", count: 64)
    let buildDigest = String(repeating: "c", count: 64)
    let policy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 4,
      maxChangedFiles: 4, maxDiffLines: 50,
      allowedOperations: evolutionOperations)
    let proposal = try inMemoryProposal(baseRevision: base)
    let candidate = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: "ART-DIFF",
      htaskID: "HTASK-EVOLUTION", attemptID: "ATTEMPT-001",
      createdBy: .agent, createdAtUTC: timestamp
    ).recordingMetadataArtifact("ART-CANDIDATE")
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
      patchFingerprint: proposal.patchSHA256, baseWorkspaceRevision: base,
      artifactSourceSet: ["ART-BASELINE"], prerequisiteSet: ["crash-reproduced"],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: "device-profile", toolchainProfile: "build-ok",
        expectedNextObservation: "no-crash"))
    let evaluation = passingEvaluation()
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-001", htaskID: "HTASK-EVOLUTION", ordinal: 1,
      hypothesis: "Fix the measured failure", strategy: strategy,
      patchRevision: patchRevision, evaluationIDs: [evaluation.evaluationID],
      candidatePatch: candidate, buildArtifactIDs: ["ART-BUILD"],
      runtimeArtifactIDs: ["ART-RUNTIME"], latestEvaluationVerdict: .pass,
      createdAtUTC: timestamp, updatedAtUTC: timestamp)
    let repair = HarnessRepairAttempt(
      proposal: proposal, checkpointJobID: "JOB-CHECKPOINT",
      patchAttemptRef: "patch-attempt", patchRevision: patchRevision,
      buildSourceRevision: patchRevision, buildOutputDigest: buildDigest,
      buildOutputArtifactLease: "lease-v1:build:ART-BUILD", buildOutputSigned: true,
      testsPassed: true,
      deployedDigest: buildDigest)
    let snapshot = try taskSnapshot(
      baseRevision: base, policy: policy,
      observedState: [HarnessRepairAttempt.observedStateKey: repair.json])
    let promotion = try HarnessPromotionGate.evaluate(
      snapshot: snapshot, attempt: attempt, evaluation: evaluation,
      promotionCandidateID: "PROMOTION-001",
      createdAtUTC: timestamp)
    XCTAssertEqual(promotion.disposition, "READY_FOR_NORMAL_PR")
    XCTAssertEqual(promotion.workspaceRevision, patchRevision)
    XCTAssertTrue(promotion.artifactIDs.contains("ART-DIFF"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-BUILD"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-RUNTIME"))
  }

  func testEveryPromotionFailureHasAnExplicitAutonomousDebugDisposition() {
    let retryable: [HarnessPromotionGateFailure] = [
      .candidatePatchMissing,
      .candidateArtifactMissing,
      .buildNotPassed,
      .buildArtifactMissing,
      .testsNotPassed,
      .deviceVerificationNotPassed,
      .deviceEvidenceMissing,
      .evaluationNotPassed,
      .scopeCheckFailed("outside"),
      .stalePatch,
    ]
    XCTAssertTrue(
      retryable.allSatisfy { $0.coordinatorDisposition == .retryCandidate })
    XCTAssertEqual(
      HarnessPromotionGateFailure.evolutionPolicyMissing.coordinatorDisposition,
      .evidenceIntegrityBlock)
  }

  func testPolicyRejectsOutOfScopeOverBudgetAndStalePatches() throws {
    let base = String(repeating: "a", count: 64)
    let policy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 2,
      maxChangedFiles: 1, maxDiffLines: 1,
      allowedOperations: ["workspace.apply-patch@1"])
    var corruptPolicy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
    corruptPolicy["maxAttempts"] = 0
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        HarnessEvolutionPolicy.self,
        from: JSONSerialization.data(withJSONObject: corruptPolicy)))
    let proposal = try inMemoryProposal(baseRevision: base)
    let normal = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: "ART-DIFF", htaskID: "HTASK-EVOLUTION",
      attemptID: "ATTEMPT-001", createdBy: .agent, createdAtUTC: timestamp)
    XCTAssertThrowsError(try policy.validate(candidate: normal)) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError,
        .diffLineBudgetExceeded(actual: 2, limit: 1))
    }
    let outside = HarnessCandidatePatch(
      candidatePatchID: "candidate-outside", htaskID: "HTASK-EVOLUTION",
      attemptID: "ATTEMPT-001", baseRevision: base,
      files: ["Secrets/key.txt"], diffDigest: proposal.patchSHA256,
      changedLines: 1, createdBy: .agent, diffArtifactID: "ART-DIFF",
      createdAtUTC: timestamp)
    XCTAssertThrowsError(try policy.validate(candidate: outside)) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError, .pathOutsideScope("Secrets/key.txt"))
    }
    let stale = HarnessCandidatePatch(
      candidatePatchID: "candidate-stale", htaskID: "HTASK-EVOLUTION",
      attemptID: "ATTEMPT-001", baseRevision: String(repeating: "d", count: 64),
      files: ["Sources/App.txt"], diffDigest: proposal.patchSHA256,
      changedLines: 1, createdBy: .agent, diffArtifactID: "ART-DIFF",
      createdAtUTC: timestamp)
    XCTAssertThrowsError(try policy.validate(candidate: stale)) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError, .candidateBaseRevisionMismatch)
    }
  }

  func testEvolutionLoopBoundsRemainEnforced() throws {
    let base = String(repeating: "a", count: 64)
    XCTAssertThrowsError(
      try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 65,
        allowedOperations: ["workspace.apply-patch@1"])
    ) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError, .invalidBudget("maxAttempts"))
    }

    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
      patchFingerprint: String(repeating: "b", count: 64), baseWorkspaceRevision: base,
      artifactSourceSet: [], prerequisiteSet: [],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: "device", toolchainProfile: "build-ok",
        expectedNextObservation: "verify"))
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-001", htaskID: "HTASK-EVOLUTION", ordinal: 1,
      hypothesis: "strategy", strategy: strategy,
      createdAtUTC: timestamp, updatedAtUTC: timestamp)
    let failed = attempt.recordingFailure(
      String(repeating: "f", count: 64), outcome: .failed, atUTC: timestamp)
    XCTAssertEqual(
      HarnessAttemptPlanner.classify(
        attempts: [failed], candidateStrategyFingerprint: strategy.fingerprint,
        identicalActionRunCount: 0, failure: nil, retrySafe: false,
        maxActionRetriesPerRun: 1),
      .duplicateStrategy(attemptID: failed.attemptID))
  }

  func testInvalidAndStaleWorkspaceRevisionFailClosed() async throws {
    XCTAssertThrowsError(
      try HarnessEvolutionPolicy(
        baseRevision: "not-a-revision", allowedPaths: ["Sources/**"],
        allowedOperations: ["workspace.apply-patch@1"])
    ) { error in
      XCTAssertEqual(error as? HarnessEvolutionPolicyError, .invalidBaseRevision)
    }

    let root = try temporaryDirectory("stale-source")
    let state = try temporaryDirectory("stale-state")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: root)
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appendingPathComponent("evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))
    let stale = try HarnessEvolutionPolicy(
      baseRevision: String(repeating: "f", count: 64), allowedPaths: ["Sources/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-STALE", sourceProjectRef: profile.projectRef,
        policy: stale, createdAtUTC: timestamp)
      XCTFail("stale workspace admission must fail")
    } catch let error as EvolutionWorkspaceError {
      guard case .baseRevisionMismatch(let expected, let actual) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertEqual(expected, String(repeating: "f", count: 64))
      XCTAssertNotEqual(actual, expected)
    }
  }

  func testEvolutionWorkspaceRejectsRelativeSymlinkEscapingTheSourceTree() async throws {
    let source = try temporaryDirectory("symlink-source")
    let external = try temporaryDirectory("symlink-external")
    let state = try temporaryDirectory("symlink-state")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Sources/Safe"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: source.appendingPathComponent("Sources/Safe/App.txt"))
    try Data("secret\n".utf8).write(to: external.appendingPathComponent("secret.txt"))
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Other"), withIntermediateDirectories: true)
    let relativeEscape = "../../\(external.lastPathComponent)/secret.txt"
    try FileManager.default.createSymbolicLink(
      atPath: source.appendingPathComponent("Other/escape").path,
      withDestinationPath: relativeEscape)
    let profile = try workspaceProfile(root: source)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/Safe/**"])
    let policy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/Safe/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appendingPathComponent("evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))

    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-SYMLINK", sourceProjectRef: profile.projectRef,
        policy: policy, createdAtUTC: timestamp)
      XCTFail("an escaping relative symlink must never enter an Evolution workspace")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .unsafeSourceEntry("Other/escape"))
    }
  }

  func testWorkspacePolicyDirectlyDrivesIsolationWithoutAModeProjection() throws {
    let base = String(repeating: "a", count: 64)
    let deviceOnly = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "TestProject",
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(summary: "device-only"), budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: ["debug.observe-device@1"]))
    XCTAssertFalse(deviceOnly.requiresWorkspaceIsolation)
    XCTAssertNoThrow(
      try deviceOnly.validate(permittedOperations: ["debug.observe-device@1"]))

    let evolutionPolicy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let evolution = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "TestProject",
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(summary: "evolve"), budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: ["workspace.apply-patch@1"]),
      evolutionPolicy: evolutionPolicy)
    XCTAssertTrue(evolution.requiresWorkspaceIsolation)
    XCTAssertNoThrow(
      try evolution.validate(permittedOperations: ["workspace.apply-patch@1"]))
    XCTAssertThrowsError(
      try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"],
        allowedOperations: ["flash.dayu200"])
    ) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError,
        .destructiveOperationNotAllowed("flash.dayu200"))
    }
  }

  func testWorkspaceGCDestroysOnlyTerminalTreesAndKeepsAuditMetadata() async throws {
    let fixture = try gcFixture("gc-basic")
    let terminal = try await fixture.prepare("HTASK-GC0000000001")
    let active = try await fixture.prepare("HTASK-GC0000000002")
    let unknown = try await fixture.prepare("HTASK-GC0000000003")
    try await fixture.manager.prepareAttemptDirectory(
      workspace: terminal, attemptID: "ATTEMPT-001", ordinal: 1, createdAtUTC: timestamp)

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        HarnessEvolutionWorkspaceGCTaskReference(
          workspaceID: terminal.workspaceID, htaskID: terminal.htaskID,
          lifecycle: .succeeded, updatedAtUTC: "2026-08-01T00:00:00Z"),
        HarnessEvolutionWorkspaceGCTaskReference(
          workspaceID: active.workspaceID, htaskID: active.htaskID,
          lifecycle: .running, updatedAtUTC: "2026-08-01T00:00:00Z"),
      ],
      retention: try HarnessEvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T12:00:00Z")

    let byWorkspace = Dictionary(
      uniqueKeysWithValues: findings.map { ($0.workspaceID, $0) })
    XCTAssertEqual(byWorkspace[terminal.workspaceID]?.disposition, .destroyed)
    XCTAssertEqual(byWorkspace[active.workspaceID]?.disposition, .activeRetained)
    XCTAssertEqual(byWorkspace[unknown.workspaceID]?.disposition, .unknownTaskRetained)
    XCTAssertGreaterThan(
      try XCTUnwrap(byWorkspace[terminal.workspaceID]).reclaimedBytes, 0)

    // The isolated tree is gone; the audit metadata and the attempt
    // manifests survive, and a teardown record now exists.
    let terminalRoot = fixture.workspaceRoot(terminal)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: terminalRoot.appendingPathComponent("workspace").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: terminalRoot.appendingPathComponent("workspace.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: terminalRoot.appendingPathComponent("attempts/attempt-001/attempt.json").path))
    let teardown = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: terminalRoot.appendingPathComponent("teardown.json")))
        as? [String: Any])
    XCTAssertEqual(teardown["documentType"] as? String, "evolution-workspace-teardown")
    XCTAssertEqual(teardown["htaskID"] as? String, terminal.htaskID)
    XCTAssertEqual(teardown["lifecycle"] as? String, "succeeded")

    // The derived profile of the destroyed tree fails at resolution; the
    // active and unknown ones keep resolving, and their trees are intact.
    XCTAssertNil(fixture.registry.profile(for: terminal.projectRef))
    XCTAssertNotNil(fixture.registry.profile(for: active.projectRef))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(active).appendingPathComponent("workspace").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(unknown).appendingPathComponent("workspace").path))

    // Recoverability: the active workspace still reopens idempotently; the
    // destroyed one refuses to impersonate a live tree.
    let reopened = try await fixture.prepare(active.htaskID)
    XCTAssertEqual(reopened, active)
    do {
      _ = try await fixture.prepare(terminal.htaskID)
      XCTFail("a swept workspace must not reopen")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .workspaceAlreadyDestroyed(terminal.workspaceID))
    }

    // A second sweep is idempotent: nothing new to reclaim.
    let second = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        HarnessEvolutionWorkspaceGCTaskReference(
          workspaceID: terminal.workspaceID, htaskID: terminal.htaskID,
          lifecycle: .succeeded, updatedAtUTC: "2026-08-01T00:00:00Z")
      ],
      retention: try HarnessEvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T13:00:00Z")
    XCTAssertEqual(
      second.first { $0.workspaceID == terminal.workspaceID }?.disposition,
      .alreadyDestroyed)
  }

  func testWorkspaceGCRetentionKeepsLatestAndYoungTerminalTrees() async throws {
    let fixture = try gcFixture("gc-retention")
    let oldest = try await fixture.prepare("HTASK-GCAGE0000001")
    let young = try await fixture.prepare("HTASK-GCAGE0000002")
    let newest = try await fixture.prepare("HTASK-GCAGE0000003")
    let references = [
      HarnessEvolutionWorkspaceGCTaskReference(
        workspaceID: oldest.workspaceID, htaskID: oldest.htaskID,
        lifecycle: .failed, updatedAtUTC: "2026-07-20T00:00:00Z"),
      HarnessEvolutionWorkspaceGCTaskReference(
        workspaceID: young.workspaceID, htaskID: young.htaskID,
        lifecycle: .cancelled, updatedAtUTC: "2026-07-30T00:00:00Z"),
      HarnessEvolutionWorkspaceGCTaskReference(
        workspaceID: newest.workspaceID, htaskID: newest.htaskID,
        lifecycle: .succeeded, updatedAtUTC: "2026-08-02T11:00:00Z"),
    ]
    let retention = try HarnessEvolutionWorkspaceRetention(
      minimumTerminalAgeSeconds: 7 * 86_400, retainLatestTerminalCount: 1)

    // Dry run decides identically but touches nothing.
    let preview = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: references,
      retention: try HarnessEvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: retention.minimumTerminalAgeSeconds,
        retainLatestTerminalCount: retention.retainLatestTerminalCount, dryRun: true),
      nowUTC: "2026-08-02T12:00:00Z")
    let previewed = Dictionary(uniqueKeysWithValues: preview.map { ($0.workspaceID, $0) })
    XCTAssertEqual(previewed[oldest.workspaceID]?.disposition, .wouldDestroy)
    XCTAssertEqual(previewed[young.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertEqual(previewed[newest.workspaceID]?.disposition, .retainedByPolicy)
    for workspace in [oldest, young, newest] {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.workspaceRoot(workspace).appendingPathComponent("workspace").path))
    }

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: references, retention: retention, nowUTC: "2026-08-02T12:00:00Z")
    let byWorkspace = Dictionary(uniqueKeysWithValues: findings.map { ($0.workspaceID, $0) })
    // Only the tree both older than the age floor and outside the
    // latest-count window is reclaimed.
    XCTAssertEqual(byWorkspace[oldest.workspaceID]?.disposition, .destroyed)
    XCTAssertEqual(byWorkspace[young.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertEqual(byWorkspace[newest.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(oldest).appendingPathComponent("workspace").path))
    for workspace in [young, newest] {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.workspaceRoot(workspace).appendingPathComponent("workspace").path))
    }
  }

  func testWorkspaceGCResumesInterruptedTeardownAndRemovesStaleTemporaries() async throws {
    let fixture = try gcFixture("gc-resume")
    let workspace = try await fixture.prepare("HTASK-GCRESUME001")
    let taskRoot = fixture.workspaceRoot(workspace)
    // Simulate a teardown that crashed between the rename and the removal,
    // with a stale copy temporary from an interrupted prepare next to it.
    try FileManager.default.moveItem(
      at: taskRoot.appendingPathComponent("workspace"),
      to: taskRoot.appendingPathComponent(".workspace.doomed"))
    try FileManager.default.createDirectory(
      at: taskRoot.appendingPathComponent(".workspace.tmp"), withIntermediateDirectories: false)
    try Data("stale\n".utf8).write(
      to: taskRoot.appendingPathComponent(".workspace.tmp/leftover.txt"))

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        HarnessEvolutionWorkspaceGCTaskReference(
          workspaceID: workspace.workspaceID, htaskID: workspace.htaskID,
          lifecycle: .failed, updatedAtUTC: "2026-08-01T00:00:00Z")
      ],
      retention: try HarnessEvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T12:00:00Z")

    XCTAssertEqual(findings.first?.disposition, .destroyed)
    XCTAssertGreaterThan(try XCTUnwrap(findings.first).reclaimedBytes, 0)
    for doomed in ["workspace", ".workspace.doomed", ".workspace.tmp"] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: taskRoot.appendingPathComponent(doomed).path))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: taskRoot.appendingPathComponent("teardown.json").path))
  }

  func testTaskWorkspaceGCWireSweepsCancelledTaskAndValidatesBounds() async throws {
    let source = try temporaryDirectory("gc-wire-source")
    let state = try temporaryDirectory("gc-wire-state")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appendingPathComponent("evolution"), profileRegistry: registry)
    let coordinator = HarnessTaskCoordinator(
      store: try HarnessTaskStore(rootURL: state.appendingPathComponent("harness")),
      jobPort: EvolutionNoopJobPort(), evolutionWorkspacePort: manager,
      nowUTC: { "2026-08-02T00:00:00Z" },
      taskIDFactory: { "HTASK-ABCDEF0123AA" })
    let service = HarnessTaskMethodService(
      coordinator: coordinator, applicationReferenceValidator: { _, _ in })
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: profile.projectRef,
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(
        summary: "fix crash",
        desiredState: ["baseWorkspaceRevision": .string(base)]),
      budgets: budgets, policy: HarnessTaskPolicy(allowedOperations: evolutionOperations),
      evolutionPolicy: try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 3,
        maxChangedFiles: 2, maxDiffLines: 20,
        allowedOperations: evolutionOperations))
    let snapshot = try await coordinator.submit(submission)
    let workspaceID = try XCTUnwrap(snapshot.evolutionWorkspace?.workspaceID)

    // Default retention keeps the freshly terminal tree (latest-count 2).
    _ = try await coordinator.cancel(snapshot.htaskID)
    let retainedResponse = await service.handle(
      "task.workspaceGC", requestID: "gc-default", params: nil)
    XCTAssertNil(retainedResponse.errorCode)
    guard case .object(let retainedFields)? = retainedResponse.result,
      case .array(let retainedRows)? = retainedFields["workspaces"],
      case .object(let retainedRow)? = retainedRows.first
    else { return XCTFail("task.workspaceGC must report per-workspace findings") }
    XCTAssertEqual(retainedRow["workspaceId"], .string(workspaceID))
    XCTAssertEqual(retainedRow["disposition"], .string("retainedByPolicy"))

    // An explicit zero-retention sweep reclaims it and reports the bytes.
    let response = await service.handle(
      "task.workspaceGC", requestID: "gc-now",
      params: ["retainDays": .integer(0), "retainLast": .integer(0)])
    XCTAssertNil(response.errorCode)
    guard case .object(let fields)? = response.result,
      case .array(let rows)? = fields["workspaces"],
      case .object(let row)? = rows.first
    else { return XCTFail("task.workspaceGC must report per-workspace findings") }
    XCTAssertEqual(row["workspaceId"], .string(workspaceID))
    XCTAssertEqual(row["htaskId"], .string(snapshot.htaskID))
    XCTAssertEqual(row["disposition"], .string("destroyed"))
    guard case .integer(let reclaimed)? = fields["reclaimedBytes"] else {
      return XCTFail("task.workspaceGC must report reclaimed bytes")
    }
    XCTAssertGreaterThan(reclaimed, 0)

    // Bounds are validated at the wire, and a composition without the
    // workspace port fails closed instead of pretending to sweep.
    let malformed = await service.handle(
      "task.workspaceGC", requestID: "gc-bad", params: ["retainDays": .integer(-1)])
    XCTAssertEqual(malformed.errorCode, .invalidParams)
    let portless = HarnessTaskMethodService(
      coordinator: HarnessTaskCoordinator(
        store: try HarnessTaskStore(rootURL: state.appendingPathComponent("harness-portless")),
        jobPort: EvolutionNoopJobPort(),
        nowUTC: { "2026-08-02T00:00:00Z" },
        taskIDFactory: { "HTASK-ABCDEF0123AB" }),
      applicationReferenceValidator: { _, _ in })
    let unavailable = await portless.handle(
      "task.workspaceGC", requestID: "gc-portless", params: nil)
    XCTAssertEqual(unavailable.errorCode, .rejected)
  }

  private struct EvolutionGCFixture {
    let manager: EvolutionWorkspaceManager
    let registry: WorkspaceProjectProfileRegistry
    let managerRoot: URL
    let sourceProjectRef: String
    let policy: HarnessEvolutionPolicy
    let createdAtUTC: String

    func prepare(_ htaskID: String) async throws -> HarnessEvolutionWorkspace {
      try await manager.prepareWorkspace(
        htaskID: htaskID, sourceProjectRef: sourceProjectRef,
        policy: policy, createdAtUTC: createdAtUTC)
    }

    func workspaceRoot(_ workspace: HarnessEvolutionWorkspace) -> URL {
      managerRoot.appendingPathComponent(workspace.workspaceID, isDirectory: true)
    }
  }

  private func gcFixture(_ prefix: String) throws -> EvolutionGCFixture {
    let source = try temporaryDirectory("\(prefix)-source")
    let state = try temporaryDirectory("\(prefix)-state")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try Data("payload\n".utf8).write(to: source.appendingPathComponent("Sources/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let managerRoot = state.appendingPathComponent("evolution", isDirectory: true)
    return EvolutionGCFixture(
      manager: try EvolutionWorkspaceManager(
        rootURL: managerRoot, profileRegistry: registry),
      registry: registry,
      managerRoot: managerRoot,
      sourceProjectRef: profile.projectRef,
      policy: try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 3,
        maxChangedFiles: 2, maxDiffLines: 20,
        allowedOperations: evolutionOperations),
      createdAtUTC: timestamp)
  }

  private var timestamp: String { "2026-08-02T00:00:00Z" }
  private var evolutionOperations: [String] {
    [
      "workspace.apply-patch@1", "workspace.build-openharmony@1",
      "workspace.run-tests@1", "debug.hap@1", "workspace.revert-patch@1",
    ]
  }
  private var budgets: HarnessTaskBudgets {
    HarnessTaskBudgets(
      maxRounds: 20, maxWallClockSeconds: 3_600,
      maxArtifactBytes: 10_000_000, maxE1Mutations: 8)
  }

  private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    roots.append(url)
    return url
  }

  private func workspaceProfile(root: URL) throws -> WorkspaceProjectProfile {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let printf = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let build = try WorkspaceCommandPreset(
      presetID: "build-ok", executable: printf,
      fixedArguments: ["BUILD_OK\n"], timeoutSeconds: 10)
    let tests = try WorkspaceCommandPreset(
      presetID: "tests-ok", executable: printf,
      fixedArguments: ["TESTS_OK\n"], timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: "evolution-test@1", projectRef: "TestProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patching,
      buildPresets: [build.presetID: build], testPresets: [tests.presetID: tests],
      symbolPresets: [:])
  }

  private func patchProposal(root: URL) throws -> HarnessPatchProposal {
    let snapshots = try WorkspaceProviderSupport.snapshots(
      relativePaths: ["Sources/App.txt"], root: root.path)
    return try inMemoryProposal(baseRevision: WorkspaceProviderSupport.revision(snapshots))
  }

  private func inMemoryProposal(baseRevision: String) throws -> HarnessPatchProposal {
    let diff = """
      diff --git a/Sources/App.txt b/Sources/App.txt
      --- a/Sources/App.txt
      +++ b/Sources/App.txt
      @@ -1 +1 @@
      -old
      +new

      """
    let digest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return try HarnessPatchProposal(
      baseWorkspaceRevision: baseRevision, patchSHA256: digest,
      unifiedDiff: diff, touchedFiles: ["Sources/App.txt"],
      expectedChangedSymbols: ["App"])
  }

  private func passingEvaluation() -> HarnessEvaluation {
    HarnessEvaluation(
      evaluationID: "EVAL-001", htaskID: "HTASK-EVOLUTION", round: 5,
      verdict: .pass,
      criterionResults: [
        HarnessCriterionResult(
          criterionID: "no-crash", verdict: .pass, metric: "crashes",
          observed: .integer(0), expected: .integer(0), samples: 5,
          requiredSamples: 5, blockers: [])
      ], measurements: ["crashes": .integer(0)], samples: ["crashes": 5],
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-RUNTIME", name: "crash-index.json", byteCount: 10,
          sha256: String(repeating: "e", count: 64), verified: true)
      ], blockers: [], createdAtUTC: timestamp)
  }

  private func taskSnapshot(
    baseRevision: String,
    policy: HarnessEvolutionPolicy,
    observedState: [String: JSONValue] = [:]
  ) throws -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-EVOLUTION", type: .debugCrash, intakeDescription: nil,
      projectRef: "TestProject", target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(
        summary: "fix crash",
        desiredState: ["baseWorkspaceRevision": .string(baseRevision)]),
      successCriteria: [], budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: evolutionOperations),
      evolutionPolicy: policy,
      evolutionWorkspace: HarnessEvolutionWorkspace(
        workspaceID: "evo-test", htaskID: "HTASK-EVOLUTION",
        sourceProjectRef: "TestProject", projectRef: "evolution-test",
        baseRevision: baseRevision, allowedPathsDigest: String(repeating: "d", count: 64),
        createdAtUTC: timestamp),
      observedState: observedState, createdAtUTC: timestamp, updatedAtUTC: timestamp,
      lifecycle: .running, stage: .verifying)
  }
}
