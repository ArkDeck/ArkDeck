import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
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
      try String(contentsOf: sourceRoot.appendingPathComponent("Sources/App.txt")),
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
    XCTAssertEqual(snapshot.executionMode, .evolution)
    XCTAssertEqual(snapshot.evolutionPolicy, evolutionPolicy)
    XCTAssertEqual(snapshot.executionProjectRef, snapshot.evolutionWorkspace?.projectRef)
    XCTAssertNotEqual(snapshot.executionProjectRef, snapshot.projectRef)
    XCTAssertNotNil(registry.profile(for: try XCTUnwrap(snapshot.executionProjectRef)))
    let attempts = try await coordinator.attempts(snapshot.htaskID)
    XCTAssertTrue(attempts.isEmpty)
  }

  func testTaskAttemptPatchBuildEvaluationReviewAndPromotionPipeline() throws {
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
      buildOutputArtifactLease: "lease-v1:build:ART-BUILD", testsPassed: true,
      deployedDigest: buildDigest)
    let snapshot = try taskSnapshot(
      baseRevision: base, policy: policy,
      observedState: [HarnessRepairAttempt.observedStateKey: repair.json])
    let review = HarnessAdversarialReview(
      reviewID: "REVIEW-001", reviewerID: "reviewer-agent@1",
      candidatePatchID: candidate.candidatePatchID,
      evaluationID: evaluation.evaluationID, result: .pass, issues: [],
      createdAtUTC: timestamp)

    let promotion = try HarnessPromotionGate.evaluate(
      snapshot: snapshot, attempt: attempt, evaluation: evaluation,
      review: review, promotionCandidateID: "PROMOTION-001",
      createdAtUTC: timestamp)
    XCTAssertEqual(promotion.disposition, "READY_FOR_NORMAL_PR")
    XCTAssertEqual(promotion.workspaceRevision, patchRevision)
    XCTAssertTrue(promotion.artifactIDs.contains("ART-DIFF"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-BUILD"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-RUNTIME"))
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

  func testReviewerRejectAndLoopBoundsPreventPromotion() throws {
    let base = String(repeating: "a", count: 64)
    XCTAssertThrowsError(
      try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 65,
        allowedOperations: ["workspace.apply-patch@1"])
    ) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError, .invalidBudget("maxAttempts"))
    }

    let policy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 2,
      allowedOperations: evolutionOperations)
    let proposal = try inMemoryProposal(baseRevision: base)
    let candidate = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: "ART-DIFF", htaskID: "HTASK-EVOLUTION",
      attemptID: "ATTEMPT-001", createdBy: .agent, createdAtUTC: timestamp
    ).recordingMetadataArtifact("ART-CANDIDATE")
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
      patchFingerprint: proposal.patchSHA256, baseWorkspaceRevision: base,
      artifactSourceSet: [], prerequisiteSet: [],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: "device", toolchainProfile: "build-ok",
        expectedNextObservation: "verify"))
    let evaluation = passingEvaluation()
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-001", htaskID: "HTASK-EVOLUTION", ordinal: 1,
      hypothesis: "strategy", strategy: strategy,
      patchRevision: String(repeating: "b", count: 64),
      evaluationIDs: [evaluation.evaluationID], candidatePatch: candidate,
      buildArtifactIDs: ["ART-BUILD"], runtimeArtifactIDs: ["ART-RUNTIME"],
      latestEvaluationVerdict: .pass, createdAtUTC: timestamp, updatedAtUTC: timestamp)
    let repair = HarnessRepairAttempt(
      proposal: proposal, patchAttemptRef: "patch-attempt",
      patchRevision: String(repeating: "b", count: 64),
      buildSourceRevision: String(repeating: "b", count: 64),
      buildOutputDigest: String(repeating: "c", count: 64), testsPassed: true,
      deployedDigest: String(repeating: "c", count: 64))
    let snapshot = try taskSnapshot(
      baseRevision: base, policy: policy,
      observedState: [HarnessRepairAttempt.observedStateKey: repair.json])
    let rejected = HarnessAdversarialReview(
      reviewID: "REVIEW-REJECT", reviewerID: "reviewer-agent@1",
      candidatePatchID: candidate.candidatePatchID,
      evaluationID: evaluation.evaluationID, result: .reject,
      issues: [HarnessReviewIssue(severity: .high, description: "unsafe ownership change")],
      createdAtUTC: timestamp)
    XCTAssertThrowsError(
      try HarnessPromotionGate.evaluate(
        snapshot: snapshot, attempt: attempt, evaluation: evaluation,
        review: rejected, promotionCandidateID: "PROMOTION-REJECTED",
        createdAtUTC: timestamp)
    ) { error in
      XCTAssertEqual(
        error as? HarnessPromotionGateFailure, .reviewNotPassed(.reject))
    }

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

  func testWorkspacePolicySelectsEvolutionWithoutCallerMode() throws {
    let base = String(repeating: "a", count: 64)
    let normal = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "TestProject",
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(summary: "normal"), budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: ["debug.observe-device@1"]))
    XCTAssertEqual(normal.executionMode, .normal)
    XCTAssertNoThrow(
      try normal.validate(permittedOperations: ["debug.observe-device@1"]))

    let evolutionPolicy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let evolution = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "TestProject",
      target: HarnessTaskTargetReference(targetID: "device"),
      goal: HarnessTaskGoal(summary: "evolve"), budgets: budgets,
      policy: HarnessTaskPolicy(allowedOperations: ["workspace.apply-patch@1"]),
      evolutionPolicy: evolutionPolicy)
    XCTAssertEqual(evolution.executionMode, .evolution)
    XCTAssertNoThrow(
      try evolution.validate(permittedOperations: ["workspace.apply-patch@1"]))
    XCTAssertThrowsError(
      try HarnessEvolutionPolicy(
        baseRevision: base, allowedPaths: ["Sources/**"],
        allowedOperations: ["flash.dayu200@1"])
    ) { error in
      XCTAssertEqual(
        error as? HarnessEvolutionPolicyError,
        .destructiveOperationNotAllowed("flash.dayu200@1"))
    }
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
      executionMode: .evolution, evolutionPolicy: policy,
      evolutionWorkspace: HarnessEvolutionWorkspace(
        workspaceID: "evo-test", htaskID: "HTASK-EVOLUTION",
        sourceProjectRef: "TestProject", projectRef: "evolution-test",
        baseRevision: baseRevision, allowedPathsDigest: String(repeating: "d", count: 64),
        createdAtUTC: timestamp),
      observedState: observedState, createdAtUTC: timestamp, updatedAtUTC: timestamp,
      status: .running, phase: .verifying)
  }
}
