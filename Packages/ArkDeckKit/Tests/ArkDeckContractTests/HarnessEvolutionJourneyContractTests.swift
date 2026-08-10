// Evolution journey contract tests (CHG-2026-025, TASK-AIN-019).
//
// Two gaps this file closes:
//
// 1. `maxEvolutionAttemptsExhausted` had never been reached by a test. The
//    budget guard lives in `beginStrategyAttempt`, so it only fires when a
//    second PROPOSE_PATCH decision actually travels the decision/dispatch
//    path with the strategy budget already spent. The exhaustion test drives
//    the real loop there - patch, deploy failure, owed rollback, second
//    proposal - and pins the humanRequired closure.
//
// 2. No test walked the whole Evolution journey from `coordinator.submit`.
//    The journey test starts at intake and crosses every leg the production
//    loop crosses: observe -> capture -> pinned analyzer -> baseline fixture
//    injection -> crash evidence -> model PROPOSE_PATCH -> checkpoint ->
//    apply -> build -> tests -> deploy -> verification capture -> analyzer ->
//    promotion.
//
// Per PRODUCT-LOOP §11 the fake surfaces assert the real typed shapes: every
// job submission decodes the production `RuntimeOperationRequest`, and the
// tests pin operation references, typed inputs, capability references and
// artifact leases - never just "a job ran".

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

// MARK: - Fixtures

private let journeyNow = "2026-08-02T00:00:00Z"
private let journeyBaseRevision = String(repeating: "a", count: 64)
private let journeyPatchRevision = String(repeating: "b", count: 64)
private let journeyBuildDigest = String(repeating: "c", count: 64)

private let journeyDiff = """
  diff --git a/Sources/App.txt b/Sources/App.txt
  --- a/Sources/App.txt
  +++ b/Sources/App.txt
  @@ -1 +1 @@
  -old
  +new

  """

private let journeySecondDiff = """
  diff --git a/Sources/App.txt b/Sources/App.txt
  --- a/Sources/App.txt
  +++ b/Sources/App.txt
  @@ -1 +1 @@
  -old
  +newer

  """

/// Real empty-index bytes shape: the device answered and has nothing.
private let journeyEmptyIndex = """

  -------------------------------[ability]-------------------------------


  ----------------------------------HiviewService----------------------------------
  No fault log exist.
  Fault log list:
  ******
  ******
  """

/// One jscrash entry for the declared bundle, in the real listing shape.
private let journeyOneEntryIndex = """

  -------------------------------[ability]-------------------------------


  ----------------------------------HiviewService----------------------------------
  Fault log list:
  ******
  jscrash-com.example.waterflowdemo-20010057-20260731162134
  ******
  """

private let journeyEntryTimestamp = "20260731162134"

/// Matched on the entry's own listing tokens (kind + bundle), so the fake
/// device never has to serve a crash body for the reproduction round.
private let journeyDeclaredSignature = "jscrash+com.example.waterflowdemo"

private func journeySHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Ports

/// Decodes the production wire request for every submission, so assertions
/// run against the exact typed shape the runtime would receive.
private actor JourneyJobPort: HarnessRuntimeJobPort {
  private var observations: [String: HarnessJobObservation] = [:]
  private var requests: [RuntimeOperationRequest] = []
  private var jobIDsByOrdinal: [String] = []
  private var nextOrdinal = 1

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    requests.append(request)
    let jobID = "JOB-\(nextOrdinal)"
    nextOrdinal += 1
    jobIDsByOrdinal.append(jobID)
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: "running", isTerminal: false, succeeded: false,
      outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    guard let observation = observations[jobID] else {
      throw HarnessJobPortError.unknownJob(jobID)
    }
    return observation
  }

  func requestCancel(jobID: String) async throws {}

  func finish(_ jobID: String, state: String = "succeeded") {
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
      outcomeUnknown: false, waitingForHuman: false,
      timeline: ["queued", "running", state])
  }

  func submittedOperations() -> [String] { requests.map(\.operation.reference) }
  func submittedRequests() -> [RuntimeOperationRequest] { requests }
  func jobIDs() -> [String] { jobIDsByOrdinal }
}

private struct JourneyStagedArtifact {
  let descriptor: HarnessArtifactDescriptor
  let bytes: Data
}

/// Lease-capable staging port: minting an ID-only lease is what routes a
/// captured crash ledger through the pinned analyzer, exactly as the
/// production `RuntimeArtifactStoreHarnessPort` does.
private final class JourneyArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private let lock = NSLock()
  private var staged: [String: [JourneyStagedArtifact]] = [:]

  func stage(
    jobID: String,
    name: String,
    text: String? = nil,
    bytes: Data? = nil,
    mediaType: String = "text/plain"
  ) {
    let data = bytes ?? Data((text ?? "").utf8)
    let descriptor = HarnessArtifactDescriptor(
      artifactID: "ART-\(jobID)-\(name)", name: name, mediaType: mediaType,
      byteCount: data.count, sha256: journeySHA256(data), published: true,
      sensitive: false, missingReason: nil)
    lock.withLock {
      staged[jobID, default: []].append(
        JourneyStagedArtifact(descriptor: descriptor, bytes: data))
    }
  }

  func descriptor(jobID: String, name: String) -> HarnessArtifactDescriptor? {
    lock.withLock { (staged[jobID] ?? []).first { $0.descriptor.name == name }?.descriptor }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    lock.withLock { (staged[jobID] ?? []).map(\.descriptor) }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      guard
        let match = (staged[jobID] ?? []).first(where: {
          $0.descriptor.artifactID == artifactID
        })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return match.bytes.prefix(maximumBytes)
    }
  }

  func leaseReference(jobID: String, artifactID: String) async throws -> String {
    try lock.withLock {
      guard
        (staged[jobID] ?? []).contains(where: {
          $0.descriptor.artifactID == artifactID && $0.descriptor.published
        })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return "lease-v1:\(jobID):\(artifactID)"
    }
  }
}

/// Honest workspace fake: the live revision is the base tree until a patch is
/// applied, the patch revision while it is applied, and the base tree again
/// after the typed revert restored the checkpoint preimage.
private final class JourneyRepairPort: HarnessRepairPort, @unchecked Sendable {
  private let lock = NSLock()
  private var nextRevisionOverride: String?

  func failNextRevisionRead() {
    lock.withLock {
      nextRevisionOverride = String(repeating: "d", count: 64)
    }
  }

  func currentWorkspaceRevision(
    relativePaths: [String], projectRef: String, task: HarnessTaskSnapshot
  ) async throws -> String {
    if let overridden = lock.withLock({ () -> String? in
      defer { nextRevisionOverride = nil }
      return nextRevisionOverride
    }) {
      return overridden
    }
    if let repair = task.repairAttempt, !repair.reverted,
      let revision = repair.patchRevision
    {
      return revision
    }
    return journeyBaseRevision
  }

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    HarnessPreparedPatch(
      inputs: [
        "projectRef": .string(projectRef),
        "patchArtifactRef": .string("lease-v1:patch:ART-DIFF"),
        "allowedFileGlobs": .array(proposal.touchedFiles.map(JSONValue.string)),
      ],
      artifactLease: "lease-v1:patch:ART-DIFF",
      artifactID: "ART-DIFF")
  }

  func candidatePatch(
    proposal: HarnessPatchProposal,
    prepared: HarnessPreparedPatch,
    task: HarnessTaskSnapshot,
    attemptID: String,
    createdBy: HarnessCandidatePatchCreator,
    createdAtUTC: String
  ) async throws -> HarnessCandidatePatch {
    HarnessCandidatePatch.create(
      proposal: proposal,
      diffArtifactID: prepared.artifactID ?? prepared.artifactLease,
      htaskID: task.htaskID, attemptID: attemptID,
      createdBy: createdBy, createdAtUTC: createdAtUTC
    ).recordingMetadataArtifact("ART-CANDIDATE")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    HarnessAppliedPatchReadback(
      patchAttemptRef: "patch-attempt-1", patchRevision: journeyPatchRevision)
  }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    HarnessBuildReadback(
      sourceRevision: journeyPatchRevision, outputDigest: journeyBuildDigest,
      outputArtifactLease: "lease-v1:build:ART-BUILD")
  }

  func deployedArtifactDigest(jobID: String) async throws -> String {
    journeyBuildDigest
  }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback { .stillUnknown }
}

/// Records the isolation lifecycle so the tests can pin that Evolution ran in
/// the task-owned tree, not in the source project.
private final class JourneyWorkspacePort: HarnessEvolutionWorkspacePort, @unchecked Sendable {
  private let lock = NSLock()
  private var prepared: [String] = []
  private var attemptDirectories: [(attemptID: String, ordinal: Int)] = []

  var preparedSourceProjects: [String] { lock.withLock { prepared } }
  var preparedAttemptDirectories: [(attemptID: String, ordinal: Int)] {
    lock.withLock { attemptDirectories }
  }

  func adoptPersistedWorkspace(
    _ workspace: HarnessEvolutionWorkspace,
    policy: HarnessEvolutionPolicy
  ) async throws {}

  func prepareWorkspace(
    htaskID: String, sourceProjectRef: String,
    policy: HarnessEvolutionPolicy, createdAtUTC: String
  ) async throws -> HarnessEvolutionWorkspace {
    lock.withLock { prepared.append(sourceProjectRef) }
    return HarnessEvolutionWorkspace(
      workspaceID: "evo-ws-1", htaskID: htaskID,
      sourceProjectRef: sourceProjectRef,
      projectRef: "evolution-\(sourceProjectRef)",
      baseRevision: policy.baseRevision,
      allowedPathsDigest: String(repeating: "d", count: 64),
      createdAtUTC: createdAtUTC)
  }

  func prepareAttemptDirectory(
    workspace: HarnessEvolutionWorkspace, attemptID: String,
    ordinal: Int, createdAtUTC: String
  ) async throws {
    lock.withLock { attemptDirectories.append((attemptID, ordinal)) }
  }

  /// The journey never runs workspace GC. Failing loud here beats a silent
  /// swept-nothing answer: if a future test routes `task.workspaceGC`
  /// through this fake, it must stage real expectations instead.
  struct SweepUnsupported: Error {}
  func sweepTerminalWorkspaces(
    tasks: [HarnessEvolutionWorkspaceGCTaskReference],
    retention: HarnessEvolutionWorkspaceRetention,
    nowUTC: String
  ) async throws -> [HarnessEvolutionWorkspaceGCFinding] {
    throw SweepUnsupported()
  }
}

/// Proposes the bounded patch exactly when the loop's offer narrows to the
/// repair boundary; on every other wake it is unreachable so the wake falls
/// back - visibly - to the deterministic handler.
private final class JourneyGateway: HarnessDecisionGateway, @unchecked Sendable {
  let producerID = "journey-gateway@1"
  private let lock = NSLock()
  private var patchWakes = 0

  var patchProposalWakes: Int { lock.withLock { patchWakes } }

  func propose(_ context: HarnessDecisionContext) async throws -> Data {
    guard context.availableOperations == [DebugCrashTaskHandler.applyPatch] else {
      throw HarnessDecisionGatewayError.unavailable("deterministicWake")
    }
    let proposalOrdinal = lock.withLock {
      patchWakes += 1
      return patchWakes
    }
    let diff = proposalOrdinal == 1 ? journeyDiff : journeySecondDiff
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      JSONValue.object([
        "kind": .string("proposePatch"),
        "hypothesis": .string("Replace the crashing branch inside the bounded scope."),
        "reasonCode": .string("patchModelProposal"),
        "baseWorkspaceRevision": .string(journeyBaseRevision),
        "patchSha256": .string(journeySHA256(Data(diff.utf8))),
        "unifiedDiff": .string(diff),
        "touchedFiles": .array([.string("Sources/App.txt")]),
        "expectedChangedSymbols": .array([.string("App")]),
        "expectedObservation": .string("PATCH_APPLIED"),
      ]))
  }
}

/// A grant a maintainer issued for the workspace mutations and the typed HAP
/// deployment; the harness may only ask for it and name it (HTP-INV-6).
private struct JourneyCapabilityGrant: HarnessCapabilityPort {
  static let covered: Set<String> = [
    DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
    DebugCrashTaskHandler.buildOpenHarmony, DebugCrashTaskHandler.runTests,
    DebugCrashTaskHandler.revertPatch, DebugCrashTaskHandler.deployHAP,
  ]

  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    Self.covered.contains(operationReference)
  }

  func standingCapabilityID(
    operationReference: String, targetID: String,
    expectedBindingRevision: Int?, inputs: [String: JSONValue]
  ) async -> String? {
    Self.covered.contains(operationReference) ? "CAP-RT-WORKSPACE-FIXTURE" : nil
  }
}

// MARK: - Tests

final class HarnessEvolutionJourneyContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-journey-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: Stack

  private struct JourneyStack {
    let coordinator: HarnessTaskCoordinator
    let store: HarnessTaskStore
    let jobs: JourneyJobPort
    let artifacts: JourneyArtifactPort
    let gateway: JourneyGateway
    let workspace: JourneyWorkspacePort
    let repair: JourneyRepairPort
    let taskID: String
    let policy: HarnessEvolutionPolicy
  }

  private func makeJourneyStack(
    maxAttempts: Int,
    maxE1Mutations: Int
  ) async throws -> JourneyStack {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let jobs = JourneyJobPort()
    let artifacts = JourneyArtifactPort()
    let gateway = JourneyGateway()
    let workspace = JourneyWorkspacePort()
    let repair = JourneyRepairPort()
    let evolutionPolicy = try HarnessEvolutionPolicy(
      baseRevision: journeyBaseRevision, allowedPaths: ["Sources/**"],
      maxAttempts: maxAttempts, maxChangedFiles: 4, maxDiffLines: 50,
      allowedOperations: [
        DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
        DebugCrashTaskHandler.buildOpenHarmony, DebugCrashTaskHandler.runTests,
        DebugCrashTaskHandler.revertPatch, DebugCrashTaskHandler.deployHAP,
      ])
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, artifactPort: artifacts,
      repairPort: repair,
      evolutionWorkspacePort: workspace,
      nowUTC: { journeyNow },
      policyGuard: HarnessPolicyGuard(capabilities: JourneyCapabilityGrant()),
      decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(enabledProjects: ["demo-app"]))
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
      goal: HarnessTaskGoal(
        summary: "No injected WaterFlow jscrash after the bounded repair",
        desiredState: [
          "crashSignature": .string(journeyDeclaredSignature),
          "bundleName": .string("com.example.waterflowdemo"),
          "abilityName": .string("EntryAbility"),
          "baselineHapArtifactLease": .string("lease-v1:input-hap:ART-crash-fixture"),
          "buildPresetRef": .string("demo-build"),
          "testPresetRef": .string("demo-tests"),
          "baseWorkspaceRevision": .string(journeyBaseRevision),
        ]),
      successCriteria: [
        HarnessSuccessCriterion(
          criterionID: "DC-1", metric: "matchingCrashCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 1,
          evidenceRequirements: [HarnessObservationBuilder.crashIndexArtifact]),
        HarnessSuccessCriterion(
          criterionID: "DC-2", metric: "newFatalSignatureCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 1,
          evidenceRequirements: [HarnessObservationBuilder.crashIndexArtifact]),
      ],
      budgets: HarnessTaskBudgets(
        maxRounds: 24, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: maxE1Mutations),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      evolutionPolicy: evolutionPolicy)
    let task = try await coordinator.submit(submission)
    XCTAssertEqual(task.evolutionWorkspace?.workspaceID, "evo-ws-1")
    XCTAssertEqual(task.executionProjectRef, "evolution-demo-app")
    XCTAssertEqual(workspace.preparedSourceProjects, ["demo-app"])
    return JourneyStack(
      coordinator: coordinator, store: store, jobs: jobs, artifacts: artifacts,
      gateway: gateway, workspace: workspace, repair: repair,
      taskID: task.htaskID, policy: evolutionPolicy)
  }

  private func stageAnalyzerEnvelope(
    _ stack: JourneyStack,
    analyzerJobID: String,
    sourceJobID: String,
    indexText: String
  ) throws {
    let source = try XCTUnwrap(
      stack.artifacts.descriptor(
        jobID: sourceJobID, name: HarnessObservationBuilder.crashIndexArtifact))
    let output = try HarnessCrashLedgerDerivedAnalyzer.analyze(Data(indexText.utf8))
    let envelope = HarnessCrashLedgerDerivedArtifact(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      sourceArtifactID: source.artifactID, sourceSHA256: source.sha256,
      sourceByteCount: source.byteCount,
      analyzerOutputSHA256: journeySHA256(output),
      analyzerOutputByteCount: output.count,
      result: try JSONDecoder().decode(HarnessCrashLedgerAnalysis.self, from: output))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    stack.artifacts.stage(
      jobID: analyzerJobID, name: "crash-signature.json",
      bytes: try encoder.encode(envelope), mediaType: "application/json")
  }

  private func inputString(
    _ request: RuntimeOperationRequest, _ key: String
  ) -> String? {
    guard case .string(let value)? = request.inputs[key] else { return nil }
    return value
  }

  private func latestRequest(_ stack: JourneyStack) async throws -> RuntimeOperationRequest {
    let requests = await stack.jobs.submittedRequests()
    return try XCTUnwrap(requests.last)
  }

  /// Drives the shared journey prefix from intake to the repair `debug.hap@1`
  /// dispatch, asserting each wake's typed step. Returns the deploy job ID so
  /// the two tests can finish it in opposite directions.
  private func driveToRepairDeployDispatch(_ stack: JourneyStack) async throws -> String {
    let coordinator = stack.coordinator
    let taskID = stack.taskID

    // Wake 1: intake admits and observes the target.
    let observeWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(observeWake.action, .dispatched)
    await stack.jobs.finish("JOB-1")

    // Wake 2: the first bounded capture, pre-injection, so the typed request
    // carries no application identity yet.
    let captureWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(captureWake.action, .dispatched)
    let captureRequest = try await latestRequest(stack)
    XCTAssertEqual(captureRequest.operation.reference, DebugCrashTaskHandler.captureDiagnostics)
    XCTAssertEqual(captureRequest.inputs["durationSeconds"], .integer(20))
    XCTAssertEqual(captureRequest.inputs["crashLogs"], .bool(true))
    XCTAssertNil(
      captureRequest.inputs["bundleName"],
      "before the fixture is injected the capture must not sample the application")
    stack.artifacts.stage(
      jobID: "JOB-2", name: HarnessObservationBuilder.crashIndexArtifact,
      text: journeyEmptyIndex)
    await stack.jobs.finish("JOB-2")

    // Wake 3: the captured ledger goes to the pinned analyzer as an ID-only
    // lease, never as bytes in a decision.
    let analyzerWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(analyzerWake.action, .dispatched)
    let analyzerRequest = try await latestRequest(stack)
    XCTAssertEqual(analyzerRequest.operation.reference, DebugCrashTaskHandler.analyzeCrashLedger)
    XCTAssertEqual(
      inputString(analyzerRequest, "sourceArtifactRef"),
      "lease-v1:JOB-2:ART-JOB-2-crash-index.txt")
    XCTAssertNil(
      analyzerRequest.target.expectedBindingRevision,
      "the host-only analyzer must not masquerade as device-bound")
    try stageAnalyzerEnvelope(
      stack, analyzerJobID: "JOB-3", sourceJobID: "JOB-2", indexText: journeyEmptyIndex)
    await stack.jobs.finish("JOB-3")

    // Wake 4: the empty ledger baselines the watermark, and the loop injects
    // the declared crash fixture through the typed deployment.
    let fixtureWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(fixtureWake.action, .dispatched)
    let fixtureRequest = try await latestRequest(stack)
    XCTAssertEqual(fixtureRequest.operation.reference, DebugCrashTaskHandler.deployHAP)
    XCTAssertEqual(
      inputString(fixtureRequest, "hapArtifactLease"), "lease-v1:input-hap:ART-crash-fixture")
    XCTAssertEqual(inputString(fixtureRequest, "bundleName"), "com.example.waterflowdemo")
    XCTAssertEqual(
      fixtureRequest.authorization?.capabilityID, "CAP-RT-WORKSPACE-FIXTURE",
      "an E1 deployment must name the maintainer-issued grant it rides on")
    XCTAssertEqual(
      fixtureWake.snapshot.observed.measurements[HarnessObservationBuilder.watermarkMetric],
      .string(""))
    await stack.jobs.finish("JOB-4")

    // Wake 5: fixture deployed; the next capture may sample the application.
    let crashCaptureWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(crashCaptureWake.action, .dispatched)
    let crashCaptureRequest = try await latestRequest(stack)
    XCTAssertEqual(
      crashCaptureRequest.operation.reference, DebugCrashTaskHandler.captureDiagnostics)
    XCTAssertEqual(
      inputString(crashCaptureRequest, "bundleName"), "com.example.waterflowdemo")
    stack.artifacts.stage(
      jobID: "JOB-5", name: HarnessObservationBuilder.crashIndexArtifact,
      text: journeyOneEntryIndex)
    await stack.jobs.finish("JOB-5")

    // Wake 6: the crash round's ledger goes through the analyzer too.
    let crashAnalyzerWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(crashAnalyzerWake.action, .dispatched)
    let crashAnalyzerOperations = await stack.jobs.submittedOperations()
    XCTAssertEqual(crashAnalyzerOperations.last, DebugCrashTaskHandler.analyzeCrashLedger)
    try stageAnalyzerEnvelope(
      stack, analyzerJobID: "JOB-6", sourceJobID: "JOB-5", indexText: journeyOneEntryIndex)
    await stack.jobs.finish("JOB-6")

    // Wake 7: the evaluator judges the declared crash on verified evidence,
    // the model proposes the bounded patch, and the coordinator interposes
    // the checkpoint before the patch can reach the runtime.
    let checkpointWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(checkpointWake.action, .dispatched)
    XCTAssertEqual(checkpointWake.snapshot.observed.latestVerdict, .fail)
    XCTAssertEqual(stack.gateway.patchProposalWakes, 1)
    let checkpointRequest = try await latestRequest(stack)
    XCTAssertEqual(
      checkpointRequest.operation.reference, DebugCrashTaskHandler.createCheckpoint)
    XCTAssertEqual(inputString(checkpointRequest, "projectRef"), "evolution-demo-app")
    XCTAssertEqual(
      inputString(checkpointRequest, "expectedWorkspaceRevision"), journeyBaseRevision)
    XCTAssertEqual(
      checkpointRequest.inputs["checkpointFilePaths"], .array([.string("Sources/App.txt")]))
    XCTAssertEqual(checkpointRequest.authorization?.capabilityID, "CAP-RT-WORKSPACE-FIXTURE")
    XCTAssertEqual(
      stack.workspace.preparedAttemptDirectories.map(\.ordinal), [2],
      "the strategy Attempt gets its isolated directory; the journey identity does not")
    await stack.jobs.finish("JOB-7")

    // Wake 8: the prepared apply resumes under the same strategy identity.
    let applyWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(applyWake.action, .dispatched)
    let applyRequest = try await latestRequest(stack)
    XCTAssertEqual(applyRequest.operation.reference, DebugCrashTaskHandler.applyPatch)
    XCTAssertEqual(inputString(applyRequest, "projectRef"), "evolution-demo-app")
    XCTAssertEqual(
      inputString(applyRequest, "patchArtifactRef"), "lease-v1:patch:ART-DIFF",
      "apply consumes the immutable diff lease, never inline patch bytes")
    await stack.jobs.finish("JOB-8")

    // Wake 9: build the exact patched workspace.
    let buildWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(buildWake.action, .dispatched)
    let buildRequest = try await latestRequest(stack)
    XCTAssertEqual(buildRequest.operation.reference, DebugCrashTaskHandler.buildOpenHarmony)
    XCTAssertEqual(inputString(buildRequest, "buildPresetRef"), "demo-build")
    await stack.jobs.finish("JOB-9")

    // Wake 10: run the declared tests against the same patch revision.
    let testsWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(testsWake.action, .dispatched)
    let testsRequest = try await latestRequest(stack)
    XCTAssertEqual(testsRequest.operation.reference, DebugCrashTaskHandler.runTests)
    XCTAssertEqual(inputString(testsRequest, "testPresetRef"), "demo-tests")
    await stack.jobs.finish("JOB-10")

    // Wake 11: deploy only the digest-gated build output.
    let deployWake = try await coordinator.reconcile(taskID)
    XCTAssertEqual(deployWake.action, .dispatched)
    let deployRequest = try await latestRequest(stack)
    XCTAssertEqual(deployRequest.operation.reference, DebugCrashTaskHandler.deployHAP)
    XCTAssertEqual(
      inputString(deployRequest, "hapArtifactLease"), "lease-v1:build:ART-BUILD",
      "the repair deployment must carry the build-output lease, not the fixture lease")
    return try XCTUnwrap(deployWake.dispatchedJobID)
  }

  /// Finish one deployed candidate with exact verification evidence. A
  /// passing promotion returns `evaluatedSucceeded`; a retryable promotion
  /// rejection continues the same reconcile into the exact revert dispatch.
  private func driveVerificationAndPromotion(
    _ stack: JourneyStack,
    captureJobID: String,
    analyzerJobID: String,
    forcePromotionDrift: Bool = false
  ) async throws -> HarnessReconcileOutcome {
    let capture = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(capture.action, .dispatched)
    let captureRequest = try await latestRequest(stack)
    XCTAssertEqual(
      captureRequest.operation.reference, DebugCrashTaskHandler.captureDiagnostics)
    XCTAssertEqual(
      inputString(captureRequest, "expectedDeployedArtifactDigest"),
      journeyBuildDigest)
    stack.artifacts.stage(
      jobID: captureJobID, name: HarnessObservationBuilder.crashIndexArtifact,
      text: journeyOneEntryIndex)
    await stack.jobs.finish(captureJobID)

    let analyzer = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(analyzer.action, .dispatched)
    let analyzerOperations = await stack.jobs.submittedOperations()
    XCTAssertEqual(analyzerOperations.last, DebugCrashTaskHandler.analyzeCrashLedger)
    try stageAnalyzerEnvelope(
      stack, analyzerJobID: analyzerJobID, sourceJobID: captureJobID,
      indexText: journeyOneEntryIndex)
    await stack.jobs.finish(analyzerJobID)
    if forcePromotionDrift { stack.repair.failNextRevisionRead() }
    return try await stack.coordinator.reconcile(stack.taskID)
  }

  // MARK: Gap 2 - the full journey to promotion

  func testEvolutionJourneyFromSubmitReachesPromotionThroughEveryTypedLeg() async throws {
    let stack = try await makeJourneyStack(maxAttempts: 4, maxE1Mutations: 7)
    let deployJobID = try await driveToRepairDeployDispatch(stack)
    await stack.jobs.finish(deployJobID)

    // Wake 12: the deployment readback matches the build digest, a fresh
    // verification epoch begins, and only the device-local watermark survives.
    let verifyCaptureWake = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(verifyCaptureWake.action, .dispatched)
    XCTAssertEqual(verifyCaptureWake.snapshot.phase, .verifying)
    XCTAssertEqual(
      verifyCaptureWake.snapshot.repairAttempt?.deployedDigest, journeyBuildDigest)
    XCTAssertEqual(
      verifyCaptureWake.snapshot.observed.measurements[
        HarnessObservationBuilder.watermarkMetric],
      .string(journeyEntryTimestamp),
      "the injected crash is retired into the watermark, not carried as a count")
    XCTAssertNil(verifyCaptureWake.snapshot.observed.measurements["matchingCrashCount"])
    let verifyCaptureRequest = try await latestRequest(stack)
    XCTAssertEqual(
      verifyCaptureRequest.operation.reference, DebugCrashTaskHandler.captureDiagnostics)
    XCTAssertEqual(
      inputString(verifyCaptureRequest, "expectedDeployedArtifactDigest"),
      journeyBuildDigest,
      "verification evidence must bind to the exact deployed artifact digest")
    stack.artifacts.stage(
      jobID: "JOB-12", name: HarnessObservationBuilder.crashIndexArtifact,
      text: journeyOneEntryIndex)
    await stack.jobs.finish("JOB-12")

    // Wake 13: verification evidence takes the same pinned-analyzer route.
    let verifyAnalyzerWake = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(verifyAnalyzerWake.action, .dispatched)
    let verifyAnalyzerOperations = await stack.jobs.submittedOperations()
    XCTAssertEqual(verifyAnalyzerOperations.last, DebugCrashTaskHandler.analyzeCrashLedger)
    try stageAnalyzerEnvelope(
      stack, analyzerJobID: "JOB-13", sourceJobID: "JOB-12",
      indexText: journeyOneEntryIndex)
    await stack.jobs.finish("JOB-13")

    // Wake 14: PASS evaluation, promotion gate, success.
    let promoted = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(promoted.action, .evaluatedSucceeded)
    XCTAssertEqual(promoted.reasonCode, "promotionCandidateReady")
    XCTAssertEqual(promoted.snapshot.status, .succeeded)
    XCTAssertEqual(promoted.snapshot.result?.reasonCode, "promotionCandidateReady")
    XCTAssertEqual(
      promoted.snapshot.consumedBudget.e1Mutations, 6,
      "fixture, checkpoint, apply, build, tests and repair deploy each charged exactly once")

    // The complete typed operation sequence, in order.
    let operations = await stack.jobs.submittedOperations()
    XCTAssertEqual(
      operations,
      [
        DebugCrashTaskHandler.observeDevice,
        DebugCrashTaskHandler.captureDiagnostics,
        DebugCrashTaskHandler.analyzeCrashLedger,
        DebugCrashTaskHandler.deployHAP,
        DebugCrashTaskHandler.captureDiagnostics,
        DebugCrashTaskHandler.analyzeCrashLedger,
        DebugCrashTaskHandler.createCheckpoint,
        DebugCrashTaskHandler.applyPatch,
        DebugCrashTaskHandler.buildOpenHarmony,
        DebugCrashTaskHandler.runTests,
        DebugCrashTaskHandler.deployHAP,
        DebugCrashTaskHandler.captureDiagnostics,
        DebugCrashTaskHandler.analyzeCrashLedger,
      ])

    // Durable Attempt facts: the journey identity was superseded by the one
    // strategy Attempt, which closed succeeded carrying the promotion.
    let attempts = try await stack.store.attempts(stack.taskID)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts.first?.outcome, .superseded)
    let strategyAttempt = try XCTUnwrap(attempts.last)
    XCTAssertEqual(strategyAttempt.outcome, .succeeded)
    XCTAssertNil(strategyAttempt.review)
    XCTAssertEqual(strategyAttempt.candidatePatch?.metadataArtifactID, "ART-CANDIDATE")
    XCTAssertEqual(strategyAttempt.buildArtifactIDs, ["ART-BUILD"])
    let promotion = try XCTUnwrap(strategyAttempt.promotionCandidate)
    XCTAssertEqual(promotion.disposition, "READY_FOR_NORMAL_PR")
    XCTAssertEqual(promotion.baseRevision, stack.policy.baseRevision)
    XCTAssertEqual(promotion.workspaceRevision, journeyPatchRevision)
    XCTAssertEqual(
      promotion.candidatePatchID, strategyAttempt.candidatePatch?.candidatePatchID)
    XCTAssertTrue(promotion.artifactIDs.contains("ART-DIFF"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-CANDIDATE"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-BUILD"))
    XCTAssertTrue(
      Set(promoted.snapshot.artifactRefs).isSuperset(of: Set(promotion.artifactIDs)),
      "the succeeded task must carry every promotion artifact reference")
    let verifiedEvidence = try await stack.store.evaluations(stack.taskID)
      .last.map { $0.evidence.filter(\.verified).map(\.artifactID) } ?? []
    XCTAssertTrue(
      Set(verifiedEvidence).isSubset(of: Set(strategyAttempt.runtimeArtifactIDs)),
      "promotion may only stand on evidence recorded against the strategy Attempt")
    let events = try await stack.store.attemptEvents(stack.taskID)
    XCTAssertEqual(
      events.map(\.kind).suffix(2), [.promotionRecorded, .closed])

    // The verdict that ended the task is a durable PASS evaluation.
    let evaluationID = try XCTUnwrap(promoted.snapshot.latestEvaluationID)
    let evaluation = try await stack.store.evaluation(
      stack.taskID, evaluationID: evaluationID)
    XCTAssertEqual(evaluation?.verdict, .pass)
  }

  func testRetryablePromotionDriftRollsBackAndConvergesWithANewCandidate() async throws {
    let stack = try await makeJourneyStack(maxAttempts: 4, maxE1Mutations: 13)
    let firstDeployJobID = try await driveToRepairDeployDispatch(stack)
    await stack.jobs.finish(firstDeployJobID)

    // The first candidate passes product evaluation, but its live isolated
    // revision drifts at promotion. The same wake must continue into the
    // exact published revert instead of ending `humanRequired`.
    let rollback = try await driveVerificationAndPromotion(
      stack, captureJobID: "JOB-12", analyzerJobID: "JOB-13",
      forcePromotionDrift: true)
    XCTAssertEqual(rollback.action, .dispatched)
    let rollbackRequest = try await latestRequest(stack)
    XCTAssertEqual(rollbackRequest.operation.reference, DebugCrashTaskHandler.revertPatch)
    XCTAssertEqual(rollback.snapshot.status, .waiting)
    XCTAssertEqual(rollback.snapshot.repairAttempt?.rollbackRequired, true)
    XCTAssertNotNil(
      rollback.snapshot.observedState[DebugCrashTaskHandler.promotionRetryReasonKey])
    let humanActionsAfterDrift = try await stack.coordinator.humanActions(stack.taskID)
    XCTAssertTrue(humanActionsAfterDrift.isEmpty)

    // Revert readback closes the rejected Attempt. The coordinator then asks
    // for a distinct patch in the same reconcile and checkpoints it before
    // any apply effect.
    await stack.jobs.finish("JOB-14")
    let secondCheckpoint = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(
      secondCheckpoint.action, .dispatched,
      "second candidate did not dispatch: \(secondCheckpoint.reasonCode)")
    let secondCheckpointRequest = try await latestRequest(stack)
    XCTAssertEqual(
      secondCheckpointRequest.operation.reference, DebugCrashTaskHandler.createCheckpoint)
    XCTAssertEqual(stack.gateway.patchProposalWakes, 2)

    await stack.jobs.finish("JOB-15")
    let secondApply = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(
      secondApply.dispatchedJobID, "JOB-16",
      "second apply did not dispatch: \(secondApply.action)/\(secondApply.reasonCode)")
    let afterSecondCheckpoint = try await stack.store.load(stack.taskID)
    XCTAssertNil(
      afterSecondCheckpoint.observedState[DebugCrashTaskHandler.promotionRetryReasonKey])
    await stack.jobs.finish("JOB-16")
    let secondBuild = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(secondBuild.dispatchedJobID, "JOB-17")
    await stack.jobs.finish("JOB-17")
    let secondTests = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(secondTests.dispatchedJobID, "JOB-18")
    await stack.jobs.finish("JOB-18")
    let secondDeploy = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(secondDeploy.dispatchedJobID, "JOB-19")
    await stack.jobs.finish("JOB-19")

    let promoted = try await driveVerificationAndPromotion(
      stack, captureJobID: "JOB-20", analyzerJobID: "JOB-21")
    XCTAssertEqual(promoted.action, .evaluatedSucceeded)
    XCTAssertEqual(promoted.reasonCode, "promotionCandidateReady")
    XCTAssertEqual(promoted.snapshot.status, .succeeded)
    XCTAssertEqual(promoted.snapshot.consumedBudget.e1Mutations, 12)
    let finalHumanActions = try await stack.coordinator.humanActions(stack.taskID)
    XCTAssertTrue(finalHumanActions.isEmpty)

    let attempts = try await stack.store.attempts(stack.taskID)
    let strategies = attempts.filter { $0.strategy.hypothesisClass != "taskJourney" }
    XCTAssertEqual(strategies.count, 2)
    XCTAssertEqual(strategies.first?.outcome, .reverted)
    XCTAssertEqual(strategies.last?.outcome, .succeeded)
    XCTAssertNotEqual(
      strategies.first?.strategy.patchFingerprint,
      strategies.last?.strategy.patchFingerprint)
  }

  // MARK: Gap 1 - strategy attempt budget exhaustion

  func testSecondProposalAfterRevertStopsForHumanWithMaxEvolutionAttemptsExhausted()
    async throws
  {
    // maxAttempts: 1 - the first strategy Attempt spends the whole budget.
    // The deploy leg fails, so the loop owes a rollback and then genuinely
    // wants a second strategy; that second PROPOSE_PATCH must be refused at
    // admission with the registered reason code, not silently retried.
    let stack = try await makeJourneyStack(maxAttempts: 1, maxE1Mutations: 13)
    let deployJobID = try await driveToRepairDeployDispatch(stack)
    await stack.jobs.finish(deployJobID, state: "installFailed")

    // The failed deployment keeps the Attempt active and dispatches the owed
    // typed rollback in the same wake.
    let rollbackWake = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(rollbackWake.action, .dispatched)
    let rollbackRequest = try await latestRequest(stack)
    XCTAssertEqual(rollbackRequest.operation.reference, DebugCrashTaskHandler.revertPatch)
    XCTAssertEqual(inputString(rollbackRequest, "projectRef"), "evolution-demo-app")
    XCTAssertEqual(inputString(rollbackRequest, "patchAttemptRef"), "patch-attempt-1")
    let rollbackJobID = try XCTUnwrap(rollbackWake.dispatchedJobID)
    await stack.jobs.finish(rollbackJobID)

    // The rollback readback closes the strategy as reverted; the wake then
    // plans again, the gateway proposes a second patch through the real
    // decision path, and `beginStrategyAttempt` refuses it: the strategy
    // budget is spent, so the task closes for a human.
    let exhausted = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(exhausted.action, .stoppedForHuman)
    XCTAssertEqual(exhausted.reasonCode, "maxEvolutionAttemptsExhausted:1")
    XCTAssertEqual(exhausted.snapshot.status, .humanRequired)
    XCTAssertEqual(exhausted.snapshot.result?.reasonCode, "maxEvolutionAttemptsExhausted:1")
    XCTAssertEqual(
      stack.gateway.patchProposalWakes, 2,
      "the second proposal must have travelled the decision path, not been presumed")

    // The refusal is admission, not execution: no third Attempt exists, the
    // reverted strategy keeps its outcome, and no workspace mutation was
    // submitted after the rollback.
    let attempts = try await stack.store.attempts(stack.taskID)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts.first?.outcome, .superseded)
    XCTAssertEqual(attempts.last?.outcome, .reverted)
    let operations = await stack.jobs.submittedOperations()
    XCTAssertEqual(operations.last, DebugCrashTaskHandler.revertPatch)
    XCTAssertEqual(
      operations.filter { $0 == DebugCrashTaskHandler.createCheckpoint }.count, 1,
      "the refused second strategy must not have dispatched another checkpoint")

    // The closure is a typed human block with the registered category.
    let actions = try await stack.coordinator.humanActions(stack.taskID)
    let action = try XCTUnwrap(actions.last)
    XCTAssertEqual(action.block, .strategyExhausted)
    XCTAssertEqual(action.reasonCode, "maxEvolutionAttemptsExhausted:1")

    // The refused proposal itself is on the durable record with the model
    // producer's identity.
    let round = exhausted.snapshot.activeRound + 1
    let refused = try await stack.store.decision(stack.taskID, round: round)
    XCTAssertEqual(refused?.kind, .proposePatch)
    XCTAssertEqual(refused?.producer, "journey-gateway@1")

    // No automatic escape: reconciling a humanRequired task changes nothing.
    let parked = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(parked.action, .awaitingHuman)
    let after = await stack.jobs.submittedOperations()
    XCTAssertEqual(after.count, operations.count)
  }
}
