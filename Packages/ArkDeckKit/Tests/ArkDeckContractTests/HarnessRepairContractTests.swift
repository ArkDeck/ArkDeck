// Repair-leg contract tests (CHG-2026-055, TASK-HFA-003).
//
// Registered acceptance: HFA-AC-6 (bounded PROPOSE_PATCH), HFA-AC-7
// (structural stage equality) and HFA-AC-8 (unknown apply never repeats;
// deployment failure rolls back and charges the mutation budget).

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private actor RepairJobPort: HarnessRuntimeJobPort {
  private var observations: [String: HarnessJobObservation]
  private var submitted: [String] = []
  private var ordinal = 1

  init(observations: [String: HarnessJobObservation]) {
    self.observations = observations
  }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submitted.append(request.operation.reference)
    let jobID = "JOB-NEW-\(ordinal)"
    ordinal += 1
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["running"])
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    guard let value = observations[jobID] else { throw HarnessJobPortError.unknownJob(jobID) }
    return value
  }

  func requestCancel(jobID: String) async throws {}

  func operations() -> [String] { submitted }
}

private struct RepairPortFixture: HarnessRepairPort {
  let applied: HarnessAppliedPatchReadback
  let build: HarnessBuildReadback
  let deployedDigest: String
  let unknown: HarnessPatchApplicationReadback

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    HarnessPreparedPatch(
      inputs: [
        "projectRef": .string(projectRef),
        "patchArtifactRef": .string("lease-v1:patch:ART-patch"),
        "allowedFileGlobs": .array(proposal.touchedFiles.map(JSONValue.string)),
      ],
      artifactLease: "lease-v1:patch:ART-patch")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback { applied }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback { build }

  func deployedArtifactDigest(jobID: String) async throws -> String { deployedDigest }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback { unknown }
}

final class HarnessRepairContractTests: XCTestCase {
  private var rootURL: URL!
  private let now = "2026-07-31T01:00:00Z"

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-repair-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  func testProposePatchSchemaRejectsEverySyntacticEscapeBeforeDispatch() throws {
    let valid = try proposal()
    let validFields: [String: JSONValue] = [
      "kind": .string("proposePatch"),
      "hypothesis": .string("Change the bounded source branch."),
      "baseWorkspaceRevision": .string(valid.baseWorkspaceRevision),
      "patchSha256": .string(valid.patchSHA256),
      "unifiedDiff": .string(valid.unifiedDiff),
      "touchedFiles": .array(valid.touchedFiles.map(JSONValue.string)),
      "expectedChangedSymbols": .array([.string("value")]),
    ]
    let bytes = try JSONEncoder().encode(JSONValue.object(validFields))
    let parsed = try HarnessDecisionProposal.parse(
      bytes, offeredOperations: [DebugCrashTaskHandler.applyPatch])
    XCTAssertEqual(parsed.kind, .proposePatch)
    XCTAssertEqual(parsed.patchProposal, valid)

    var invokeWithPatch = validFields
    invokeWithPatch["kind"] = .string("invokeOperation")
    invokeWithPatch["operationRef"] = .string(DebugCrashTaskHandler.applyPatch)
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        JSONEncoder().encode(JSONValue.object(invokeWithPatch)),
        offeredOperations: [DebugCrashTaskHandler.applyPatch]))

    var patchWithInputs = validFields
    patchWithInputs["inputs"] = .object(["projectRef": .string("demo-app")])
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        JSONEncoder().encode(JSONValue.object(patchWithInputs)),
        offeredOperations: [DebugCrashTaskHandler.applyPatch]))

    XCTAssertThrowsError(
      try HarnessPatchProposal(
        baseWorkspaceRevision: valid.baseWorkspaceRevision,
        patchSHA256: String(repeating: "0", count: 64),
        unifiedDiff: valid.unifiedDiff, touchedFiles: valid.touchedFiles,
        expectedChangedSymbols: []))
    let binary = "diff --git a/Sources/A.swift b/Sources/A.swift\nGIT binary patch\n"
    XCTAssertThrowsError(
      try makeProposal(diff: binary, files: ["Sources/A.swift"]))
    let traversal = "diff --git a/../A.swift b/../A.swift\n--- a/../A.swift\n+++ b/../A.swift\n"
    XCTAssertThrowsError(try makeProposal(diff: traversal, files: ["../A.swift"]))
    let git = "diff --git a/.git/config b/.git/config\n--- a/.git/config\n+++ b/.git/config\n"
    XCTAssertThrowsError(try makeProposal(diff: git, files: [".git/config"]))
    let pathChanging =
      "diff --git a/Sources/A.swift b/Sources/B.swift\n--- a/Sources/A.swift\n+++ b/Sources/B.swift\n"
    XCTAssertThrowsError(
      try makeProposal(
        diff: pathChanging, files: ["Sources/A.swift", "Sources/B.swift"]))
    XCTAssertThrowsError(
      try HarnessPatchProposal(
        baseWorkspaceRevision: String(repeating: "١", count: 64),
        patchSHA256: valid.patchSHA256, unifiedDiff: valid.unifiedDiff,
        touchedFiles: valid.touchedFiles, expectedChangedSymbols: []))
    var corruptDocument = try JSONEncoder().encode(valid)
    corruptDocument = Data(
      String(decoding: corruptDocument, as: UTF8.self)
        .replacingOccurrences(of: valid.patchSHA256, with: String(repeating: "0", count: 64))
        .utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(HarnessPatchProposal.self, from: corruptDocument))
    let headerShapedHunk = """
      diff --git a/Sources/A.swift b/Sources/A.swift
      --- a/Sources/A.swift
      +++ b/Sources/A.swift
      @@ -1 +1 @@
      --- old source content
      +++ new source content
      """
    XCTAssertNoThrow(
      try makeProposal(diff: headerShapedHunk, files: ["Sources/A.swift"]))
    XCTAssertThrowsError(
      try HarnessPatchProposal(
        baseWorkspaceRevision: valid.baseWorkspaceRevision,
        patchSHA256: valid.patchSHA256, unifiedDiff: valid.unifiedDiff,
        touchedFiles: Array(repeating: "Sources/A.swift", count: 33),
        expectedChangedSymbols: []))
    XCTAssertThrowsError(
      try HarnessPatchProposal(
        baseWorkspaceRevision: valid.baseWorkspaceRevision,
        patchSHA256: valid.patchSHA256, unifiedDiff: valid.unifiedDiff,
        touchedFiles: valid.touchedFiles, expectedChangedSymbols: [],
        limits: HarnessPatchLimits(
          maxPatchBytes: Data(valid.unifiedDiff.utf8).count - 1,
          maxTouchedFiles: 32, maxExpectedChangedSymbols: 256)))
  }

  func testAllThreeStageGatesRequireStructuralEquality() throws {
    let stages = [
      "appliedPatchRevision", "buildSourceRevision", "deploymentArtifactDigest",
    ]
    let expected = String(repeating: "a", count: 64)
    let different = String(repeating: "b", count: 64)
    for stage in stages {
      XCTAssertNoThrow(
        try HarnessRepairStageGate.requireEqual(
          stage: stage, expected: expected, actual: expected))
      XCTAssertThrowsError(
        try HarnessRepairStageGate.requireEqual(
          stage: stage, expected: expected, actual: different)) { error in
        XCTAssertEqual(
          error as? HarnessRepairPortError,
          .stageGateMismatch(stage: stage, expected: expected, actual: different))
      }
    }
  }

  func testSemanticRepairFailuresRequireAnAlternativeStrategy() {
    for classification in [
      "BUILD_SEMANTIC_FAILURE", "TEST_FAILURE", "WORKSPACE_REVISION_CONFLICT",
    ] {
      let fingerprint = HarnessFailureFingerprint(
        operationReference: DebugCrashTaskHandler.buildOpenHarmony,
        phase: .building, providerID: "workspace", targetProfile: "workspace-host@1",
        normalizedInputsSHA256: String(repeating: "a", count: 64),
        errorClassification: classification, semanticErrorCode: "fixture")
      XCTAssertEqual(fingerprint.retryDisposition, .alternativeRequired)
    }
  }

  func testWorkspaceProfileGlobSymlinkAndBaseMismatchPublishNoPatchArtifact() async throws {
    let workspace = rootURL.appendingPathComponent("workspace", isDirectory: true)
    let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
    let other = workspace.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("let value = 0\n".utf8).write(to: sources.appendingPathComponent("A.swift"))
    try Data("let other = 0\n".utf8).write(to: other.appendingPathComponent("A.swift"))
    try FileManager.default.createSymbolicLink(
      at: sources.appendingPathComponent("Link.swift"),
      withDestinationURL: sources.appendingPathComponent("A.swift"))

    let executable = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/true")
    let preset = try WorkspaceCommandPreset(
      presetID: "fixture", executable: executable, fixedArguments: [], timeoutSeconds: 10)
    let profile = try WorkspaceProjectProfile(
      profileID: "workspace-host@1", projectRef: "demo-app",
      projectRoot: workspace.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: preset, patchPreset: preset,
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    let attemptStore = try WorkspacePatchAttemptStore(
      rootURL: rootURL.appendingPathComponent("attempts", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: rootURL.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-31T01:00:00Z" })
    let port = WorkspaceHarnessRepairPort(
      profile: profile, attemptStore: attemptStore, artifactStore: artifactStore)
    let task = makeSnapshot(
      phase: .analyzing, activeJobID: "JOB-X",
      repair: HarnessRepairAttempt(proposal: try proposal()))

    let cases: [(String, HarnessPatchProposal)] = [
      (
        "dec-glob",
        try proposal(
          path: "Other/A.swift",
          base: WorkspaceProviderSupport.revision(
            try WorkspaceProviderSupport.snapshots(
              relativePaths: ["Other/A.swift"], root: workspace.path)))),
      (
        "dec-symlink",
        try proposal(path: "Sources/Link.swift", base: String(repeating: "0", count: 64))),
      (
        "dec-base",
        try proposal(path: "Sources/A.swift", base: String(repeating: "0", count: 64))),
    ]
    for (decisionID, proposal) in cases {
      do {
        _ = try await port.preparePatch(
          proposal, projectRef: "demo-app", task: task, decisionID: decisionID)
        XCTFail("\(decisionID) must be refused before Artifact publication")
      } catch {
        // Each case is intentionally refused by a different live host fact.
      }
      let published = (try? await artifactStore.list(jobID: "hpatch-\(decisionID)")) ?? []
      XCTAssertTrue(published.isEmpty)
    }
  }

  func testUnknownApplyUsesFourStateReadbackAndNeverSubmitsASecondApply() async throws {
    let proposal = try proposal()
    let attempt = HarnessRepairAttempt(proposal: proposal)
    let snapshot = makeSnapshot(
      phase: .patching, activeJobID: "JOB-APPLY", repair: attempt)
    let decision = HarnessDecision(
      decisionID: "dec-apply", htaskID: snapshot.htaskID, round: 1,
      kind: .proposePatch, operationReference: DebugCrashTaskHandler.applyPatch,
      inputs: ["projectRef": .string("demo-app")], patchProposal: proposal,
      hypothesis: "apply", reasonCode: "applyPatch", producer: "fixture",
      createdAtUTC: now)
    let jobs = RepairJobPort(observations: [
      "JOB-APPLY": observation("JOB-APPLY", succeeded: false, unknown: true)
    ])
    let fixture = repairFixture(unknown: .patchNotApplied)
    let (coordinator, store) = try await makeStack(
      snapshot: snapshot, decision: decision, operation: DebugCrashTaskHandler.applyPatch,
      jobs: jobs, repair: fixture)

    let outcome = try await coordinator.reconcile(snapshot.htaskID)
    let submitted = await jobs.operations()
    let intents = try await store.intents(snapshot.htaskID)
    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "patchOutcomeReadback:PATCH_NOT_APPLIED")
    XCTAssertEqual(submitted, [], "unknown apply must never dispatch apply again")
    XCTAssertEqual(intents.count, 1)
  }

  func testBuildSourceRevisionMustEqualPatchRevisionBeforeTestsDispatch() async throws {
    let proposal = try proposal()
    let patchRevision = String(repeating: "a", count: 64)
    let attempt = HarnessRepairAttempt(
      proposal: proposal, patchAttemptRef: "patch-fixture", patchRevision: patchRevision)
    let snapshot = makeSnapshot(
      phase: .building, activeJobID: "JOB-BUILD", repair: attempt)
    let decision = HarnessDecision(
      decisionID: "dec-build", htaskID: snapshot.htaskID, round: 1,
      kind: .invokeOperation, operationReference: DebugCrashTaskHandler.buildOpenHarmony,
      inputs: ["projectRef": .string("demo-app"), "buildPresetRef": .string("demo-build")],
      hypothesis: "build", reasonCode: "build", producer: "fixture", createdAtUTC: now)
    let jobs = RepairJobPort(observations: [
      "JOB-BUILD": observation("JOB-BUILD", succeeded: true)
    ])
    let fixture = repairFixture(
      buildSource: String(repeating: "b", count: 64), unknown: .stillUnknown)
    let (coordinator, store) = try await makeStack(
      snapshot: snapshot, decision: decision,
      operation: DebugCrashTaskHandler.buildOpenHarmony, jobs: jobs, repair: fixture)

    let outcome = try await coordinator.reconcile(snapshot.htaskID)
    let submitted = await jobs.operations()
    let events = try await store.events(snapshot.htaskID)
    XCTAssertNotEqual(outcome.snapshot.phase, .deploying)
    XCTAssertNil(outcome.snapshot.repairAttempt?.buildOutputDigest)
    XCTAssertFalse(submitted.contains(DebugCrashTaskHandler.runTests))
    XCTAssertTrue(events.contains { $0.reasonCode.contains("WORKSPACE_REVISION_CONFLICT") })
  }

  func testDeploymentDigestMismatchDispatchesTypedRollbackAndChargesBudget() async throws {
    let proposal = try proposal()
    let expected = String(repeating: "c", count: 64)
    let attempt = HarnessRepairAttempt(
      proposal: proposal, patchAttemptRef: "patch-fixture",
      patchRevision: String(repeating: "a", count: 64),
      buildSourceRevision: String(repeating: "a", count: 64),
      buildOutputDigest: expected,
      buildOutputArtifactLease: "lease-v1:build:ART-build", testsPassed: true)
    let snapshot = makeSnapshot(
      phase: .deploying, activeJobID: "JOB-DEPLOY", repair: attempt,
      consumed: HarnessConsumedBudget(rounds: 1, e1Mutations: 1))
    let decision = HarnessDecision(
      decisionID: "dec-deploy", htaskID: snapshot.htaskID, round: 1,
      kind: .invokeOperation, operationReference: DebugCrashTaskHandler.deployHAP,
      inputs: ["hapArtifactLease": .string("lease-v1:build:ART-build")],
      hypothesis: "deploy", reasonCode: "deploy", producer: "fixture", createdAtUTC: now)
    let jobs = RepairJobPort(observations: [
      "JOB-DEPLOY": observation("JOB-DEPLOY", succeeded: true)
    ])
    let fixture = repairFixture(
      deployed: String(repeating: "d", count: 64), unknown: .stillUnknown)
    let (coordinator, _) = try await makeStack(
      snapshot: snapshot, decision: decision,
      operation: DebugCrashTaskHandler.deployHAP, jobs: jobs, repair: fixture)

    let outcome = try await coordinator.reconcile(snapshot.htaskID)
    let submitted = await jobs.operations()
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(submitted, [DebugCrashTaskHandler.revertPatch])
    XCTAssertEqual(outcome.snapshot.phase, .analyzing)
    XCTAssertEqual(outcome.snapshot.consumedBudget.e1Mutations, 2)
  }

  func testVerificationFailureDispatchesTypedRollbackAndChargesBudget() async throws {
    let proposal = try proposal()
    let digest = String(repeating: "c", count: 64)
    let attempt = HarnessRepairAttempt(
      proposal: proposal, patchAttemptRef: "patch-fixture",
      patchRevision: String(repeating: "a", count: 64),
      buildSourceRevision: String(repeating: "a", count: 64),
      buildOutputDigest: digest,
      buildOutputArtifactLease: "lease-v1:build:ART-build", testsPassed: true,
      deployedDigest: digest)
    let snapshot = makeSnapshot(
      phase: .verifying, activeJobID: nil, repair: attempt,
      consumed: HarnessConsumedBudget(rounds: 1, e1Mutations: 1))
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(snapshot)
    let jobs = RepairJobPort(observations: [:])
    let fixedNow = now
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs,
      repairPort: repairFixture(unknown: .stillUnknown), nowUTC: { fixedNow })

    let outcome = try await coordinator.reconcile(snapshot.htaskID)
    let submitted = await jobs.operations()
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(submitted, [DebugCrashTaskHandler.revertPatch])
    XCTAssertEqual(outcome.snapshot.consumedBudget.e1Mutations, 2)
  }

  // MARK: - Fixtures

  private func proposal() throws -> HarnessPatchProposal {
    let diff = """
      diff --git a/Sources/A.swift b/Sources/A.swift
      --- a/Sources/A.swift
      +++ b/Sources/A.swift
      @@ -1 +1 @@
      -let value = 0
      +let value = 1
      """
    return try makeProposal(diff: diff, files: ["Sources/A.swift"])
  }

  private func proposal(path: String, base: String) throws -> HarnessPatchProposal {
    let diff = """
      diff --git a/\(path) b/\(path)
      --- a/\(path)
      +++ b/\(path)
      @@ -1 +1 @@
      -let value = 0
      +let value = 1
      """
    let digest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return try HarnessPatchProposal(
      baseWorkspaceRevision: base, patchSHA256: digest,
      unifiedDiff: diff, touchedFiles: [path], expectedChangedSymbols: ["value"])
  }

  private func makeProposal(diff: String, files: [String]) throws -> HarnessPatchProposal {
    let digest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return try HarnessPatchProposal(
      baseWorkspaceRevision: String(repeating: "1", count: 64),
      patchSHA256: digest, unifiedDiff: diff, touchedFiles: files,
      expectedChangedSymbols: ["value"])
  }

  private func makeSnapshot(
    phase: HarnessTaskPhase,
    activeJobID: String?,
    repair: HarnessRepairAttempt,
    consumed: HarnessConsumedBudget = HarnessConsumedBudget(rounds: 1)
  ) -> HarnessTaskSnapshot {
    var observed = HarnessObservedState(latestVerdict: .fail).asJSON
    observed[HarnessRepairAttempt.observedStateKey] = repair.json
    return HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1", expectedBindingRevision: 1),
      goal: HarnessTaskGoal(
        summary: "repair crash",
        desiredState: [
          "buildPresetRef": .string("demo-build"),
          "testPresetRef": .string("demo-tests"),
          "bundleName": .string("com.example.demo"),
          "abilityName": .string("EntryAbility"),
        ]),
      successCriteria: DebugCrashTaskHandler().defaultSuccessCriteria(),
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 3),
      policy: HarnessTaskPolicy(
        allowedOperations: DebugCrashTaskHandler().permittedOperations.sorted()),
      observedState: observed, createdAtUTC: now, updatedAtUTC: now,
      status: .running, phase: phase, activeRound: 1, activeJobID: activeJobID,
      consumedBudget: consumed)
  }

  private func makeStack(
    snapshot: HarnessTaskSnapshot,
    decision: HarnessDecision,
    operation: String,
    jobs: RepairJobPort,
    repair: RepairPortFixture
  ) async throws -> (HarnessTaskCoordinator, HarnessTaskStore) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    try await store.create(snapshot)
    try await store.putDecision(decision)
    let intent = HarnessDispatchIntent(
      htaskID: snapshot.htaskID, round: 1, decisionID: decision.decisionID,
      operationReference: operation, targetID: snapshot.target.targetID,
      expectedBindingRevision: snapshot.target.expectedBindingRevision,
      inputsDigestSHA256: HarnessRequestIdentity.inputsDigest(decision.inputs),
      requestID: "req-fixture", idempotencyKey: "idem-fixture", state: .linked,
      jobID: snapshot.activeJobID, createdAtUTC: now, updatedAtUTC: now)
    try await store.putIntent(intent)
    let fixedNow = now
    return (
      HarnessTaskCoordinator(
        store: store, jobPort: jobs, repairPort: repair, nowUTC: { fixedNow }),
      store)
  }

  private func repairFixture(
    buildSource: String = String(repeating: "a", count: 64),
    deployed: String = String(repeating: "c", count: 64),
    unknown: HarnessPatchApplicationReadback
  ) -> RepairPortFixture {
    RepairPortFixture(
      applied: HarnessAppliedPatchReadback(
        patchAttemptRef: "patch-fixture", patchRevision: String(repeating: "a", count: 64)),
      build: HarnessBuildReadback(
        sourceRevision: buildSource, outputDigest: String(repeating: "c", count: 64),
        outputArtifactLease: "lease-v1:build:ART-build"),
      deployedDigest: deployed, unknown: unknown)
  }

  private func observation(
    _ jobID: String, succeeded: Bool, unknown: Bool = false
  ) -> HarnessJobObservation {
    HarnessJobObservation(
      jobID: jobID, state: succeeded ? "succeeded" : (unknown ? "outcomeUnknown" : "failed"),
      isTerminal: true, succeeded: succeeded, outcomeUnknown: unknown,
      waitingForHuman: false, timeline: ["terminal"])
  }
}
