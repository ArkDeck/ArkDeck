// Decision gateway contract tests (CHG-2026-054, TASK-HTP-004).
//
// Registered acceptance: HTP-AC-12 (strict proposal schema and its rejection
// surface), HTP-AC-13 (egress denied by default; bounded and identity-free
// when enabled), HTP-AC-14 (the port is replaceable and task state does not
// depend on a model session).

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private func encodeProposal(_ fields: [String: JSONValue]) -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return (try? encoder.encode(JSONValue.object(fields))) ?? Data()
}

/// Returns whatever the test scripted, and records every context it was given
/// so the outbound side can be asserted on.
private final class ScriptedGateway: HarnessDecisionGateway, @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [Result<Data, any Error>]
  private var seen: [HarnessDecisionContext] = []

  let producerID: String

  init(producerID: String = "scripted-gateway@1", replies: [Result<Data, any Error>]) {
    self.producerID = producerID
    self.replies = replies
  }

  var seenContexts: [HarnessDecisionContext] { lock.withLock { seen } }

  func propose(_ context: HarnessDecisionContext) async throws -> Data {
    try lock.withLock {
      seen.append(context)
      guard !replies.isEmpty else {
        throw HarnessDecisionGatewayError.unavailable("no scripted reply left")
      }
      return try replies.removeFirst().get()
    }
  }
}

private final class GatewayJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: HarnessJobObservation] = [:]
  private var submissions: [String] = []
  private var nextOrdinal = 1

  var submittedOperations: [String] { lock.withLock { submissions } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    return lock.withLock {
      submissions.append(request.operation.reference)
      let jobID = "JOB-\(nextOrdinal)"
      nextOrdinal += 1
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: "running", isTerminal: false, succeeded: false,
        outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
      return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
    }
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    try lock.withLock {
      guard let observation = observations[jobID] else {
        throw HarnessJobPortError.unknownJob(jobID)
      }
      return observation
    }
  }

  func requestCancel(jobID: String) async throws {}

  func finish(_ jobID: String, state: String = "succeeded") {
    lock.withLock {
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
        outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running", state])
    }
  }
}

private struct GatewayAvailability: HarnessOperationAvailabilityPort {
  let unavailable: [String: String]

  func availability(of reference: String) async -> (available: Bool, reason: String) {
    if let reason = unavailable[reference] { return (false, reason) }
    return (true, "available")
  }
}

private struct GatewayCapabilities: HarnessCapabilityPort {
  let covered: Set<String>

  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    covered.contains(operationReference)
  }
}

final class HarnessDecisionGatewayContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-gateway-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  private let offered = DebugCrashTaskHandler().permittedOperations

  private func makeStack(
    gateway: (any HarnessDecisionGateway)?,
    egress: HarnessEgressPolicy,
    jobs: GatewayJobPort,
    projectRef: String? = "demo-app",
    desiredState: [String: JSONValue] = [:],
    goalSummary: String = "No WaterFlow SIGABRT",
    expectedBindingRevision: Int? = nil,
    policyGuard: HarnessPolicyGuard = HarnessPolicyGuard()
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:00Z" },
      policyGuard: policyGuard, decisionGateway: gateway, egressPolicy: egress)
    let submission = HarnessTaskSubmission(
      type: .debugCrash, projectRef: projectRef,
      target: HarnessTaskTargetReference(
        targetID: "TGT-958780b2ffb7",
        expectedBindingRevision: expectedBindingRevision),
      goal: HarnessTaskGoal(summary: goalSummary, desiredState: desiredState),
      budgets: HarnessTaskBudgets(
        maxRounds: 6, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20, maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, store, submission)
  }

  // MARK: - HTP-AC-12: strict schema

  func testAWellFormedProposalIsAccepted() throws {
    let proposal = try HarnessDecisionProposal.parse(
      encodeProposal([
        "kind": .string("invokeOperation"),
        "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
        "hypothesis": .string("Collect one more bounded sample."),
        "reasonCode": .string("collectAdditionalSample"),
        "confidence": .number(0.6),
      ]),
      offeredOperations: offered)
    XCTAssertEqual(proposal.kind, .invokeOperation)
    XCTAssertEqual(proposal.operationReference, DebugCrashTaskHandler.captureDiagnostics)
    XCTAssertEqual(proposal.reasonCode, "collectAdditionalSample")
    XCTAssertEqual(proposal.confidence, 0.6)
  }

  func testStateRetryAndSuccessFieldsAreRejectedNotIgnored() {
    // Each of these is a decision the harness or the runtime owns. Ignoring
    // them would let a model believe it had decided; rejecting says otherwise.
    let forbidden: [String: JSONValue] = [
      "status": .string("succeeded"),
      "phase": .string("verifying"),
      "result": .string("fixed"),
      "retryCount": .integer(3),
      "verdict": .string("pass"),
      "succeeded": .bool(true),
      "authorization": .string("CAP-RT-1"),
      "capabilityId": .string("CAP-RT-1"),
      "effect": .string("deviceMutation"),
      "budget": .integer(99),
      "activeJobId": .string("JOB-1"),
      "version": .integer(7),
    ]
    for (field, value) in forbidden {
      var fields: [String: JSONValue] = [
        "kind": .string("invokeOperation"),
        "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
        "hypothesis": .string("h"),
      ]
      fields[field] = value
      XCTAssertThrowsError(
        try HarnessDecisionProposal.parse(encodeProposal(fields), offeredOperations: offered),
        "\(field) must be refused"
      ) { error in
        XCTAssertEqual(
          error as? HarnessDecisionRejection, .forbiddenField(field),
          "\(field) must be refused as forbidden, not ignored")
      }
    }
  }

  func testUnknownFieldsAndKindsAreRefused() {
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("invokeOperation"),
          "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
          "hypothesis": .string("h"), "sideChannel": .string("anything"),
        ]), offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .unknownField("sideChannel")) }

    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("applyPatchDirectly"), "hypothesis": .string("h"),
        ]), offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .unknownKind("applyPatchDirectly")) }

    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(Data("not json".utf8), offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .malformedJSON) }
  }

  func testRawCommandSurfacesAreRefusedInInputsAndInProse() {
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("invokeOperation"),
          "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
          "hypothesis": .string("h"),
          "inputs": .object(["argv": .array([.string("hdc"), .string("shell")])]),
        ]), offeredOperations: offered)
    ) { error in
      guard case .rawCommandSurface = error as? HarnessDecisionRejection else {
        return XCTFail("argv in inputs must be refused, got \(error)")
      }
    }

    // Prose is part of the durable record, so a shell fragment smuggled
    // through the hypothesis is still refused.
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("requestHuman"),
          "hypothesis": .string("ask the operator to run hdc shell rm -rf /data/local/tmp"),
        ]), offeredOperations: offered)
    ) { error in
      guard case .rawCommandSurface = error as? HarnessDecisionRejection else {
        return XCTFail("a shell fragment in prose must be refused, got \(error)")
      }
    }
  }

  func testAnOperationOutsideTheOfferIsRefused() {
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("invokeOperation"), "operationRef": .string("flash.dayu200@1"),
          "hypothesis": .string("reflash it"),
        ]), offeredOperations: offered)
    ) {
      XCTAssertEqual(
        $0 as? HarnessDecisionRejection, .operationNotOffered("flash.dayu200@1"))
    }

    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal(["kind": .string("invokeOperation"), "hypothesis": .string("h")]),
        offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .operationRequired) }
  }

  func testEmptyAndOversizedFieldsAreRefused() {
    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("noSafeAction"), "hypothesis": .string("   "),
        ]), offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .emptyHypothesis) }

    XCTAssertThrowsError(
      try HarnessDecisionProposal.parse(
        encodeProposal([
          "kind": .string("noSafeAction"),
          "hypothesis": .string(String(repeating: "a", count: 2048)),
        ]), offeredOperations: offered)
    ) { XCTAssertEqual($0 as? HarnessDecisionRejection, .oversizedField("hypothesis")) }
  }

  // MARK: - HTP-AC-13: egress

  func testEgressIsDeniedByDefaultAndNoContextLeavesTheHost() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [])
    let (coordinator, store, submission) = try makeStack(
      gateway: gateway, egress: .deniedByDefault, jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .dispatched, "the loop still runs with egress denied")
    XCTAssertEqual(
      gateway.seenContexts.count, 0, "no context may leave the host without an opt-in")
    XCTAssertTrue(outcome.reasonCode.contains("egressDenied:egressNotEnabledForProject"))

    // The fallback is recorded, not silent.
    let memory = try await store.memory(scope: .task, key: task.htaskID)
    XCTAssertTrue(
      memory.contains {
        $0.summary.contains("fell back") && $0.summary.contains("egressDenied")
      })
    let decision = try await store.decision(task.htaskID, round: 1)
    XCTAssertEqual(decision?.producer, "debug-crash-handler@1")
  }

  func testEgressWithoutAProjectRefIsDenied() {
    let policy = HarnessEgressPolicy(enabledProjects: ["demo-app"])
    XCTAssertEqual(policy.decide(projectRef: nil), .denied(reason: "egressRequiresProjectRef"))
    XCTAssertEqual(
      policy.decide(projectRef: "other-app"),
      .denied(reason: "egressNotEnabledForProject"))
    guard case .allowed = policy.decide(projectRef: "demo-app") else {
      return XCTFail("an enabled project must be allowed")
    }
  }

  func testAnEnabledContextIsBoundedPseudonymousAndFreeOfDeviceIdentity() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [
      .success(
        encodeProposal([
          "kind": .string("invokeOperation"),
          "operationRef": .string(DebugCrashTaskHandler.observeDevice),
          "hypothesis": .string("Observe the target before collecting anything."),
        ]))
    ])
    let repairTail =
      "patchSha256=6b45f926b558c6075aa78fe533ca422574d982cd71d3c4cf3974186e36571c98"
    let boundedRepairGoal = String(repeating: "bounded repair context ", count: 30) + repairTail
    let (coordinator, _, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]), jobs: jobs,
      desiredState: [
        "crashSignature": .string("jscrash:com.example.waterflowdemo"),
        "buildPresetRef": .string("waterflow-debug"),
        "baselineHapArtifactLease": .string(
          "lease-v1:input-hap-TGT-958780b2ffb7-r1-deadbeef:ART-baseline"),
      ], goalSummary: boundedRepairGoal)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(jobs.submittedOperations, [DebugCrashTaskHandler.observeDevice])

    let context = try XCTUnwrap(gateway.seenContexts.first)
    XCTAssertEqual(
      context.targetPseudonym,
      HarnessDecisionContext.pseudonym(forTargetID: "TGT-958780b2ffb7"))
    XCTAssertNotEqual(context.targetPseudonym, "TGT-958780b2ffb7")
    XCTAssertEqual(
      HarnessEgressScreen.violations(in: context, targetID: "TGT-958780b2ffb7"), [],
      "no target id, connect key, serial, identity digest or remote path may travel")
    XCTAssertEqual(
      context.desiredState["crashSignature"], .string("jscrash:com.example.waterflowdemo"))
    XCTAssertEqual(context.desiredState["buildPresetRef"], .string("waterflow-debug"))
    XCTAssertNil(
      context.desiredState["baselineHapArtifactLease"],
      "runtime-only artifact leases must not cross the model egress boundary")
    XCTAssertTrue(
      context.trimmed.contains("desiredState:omitted1OrchestrationFields"),
      "omitting orchestration-only desired state must be visible in the context")
    XCTAssertGreaterThan(context.goalSummary.count, 480)
    XCTAssertTrue(
      context.goalSummary.hasSuffix(repairTail),
      "the exact patch digest at the end of a bounded repair goal must reach the model")
    XCTAssertEqual(Set(context.availableOperations), [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(context.budget.roundsRemaining, 6)
    XCTAssertEqual(context.budget.e1MutationsRemaining, 0)

    // The context carries artifact identity and size, never content.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(context)
    XCTAssertLessThanOrEqual(encoded.count, HarnessDecisionContextLimits.default.maxEncodedBytes)
  }

  func testContextTrimmingIsRecordedRatherThanSilent() throws {
    let limits = HarnessDecisionContextLimits(
      maxAttempts: 1, maxFailures: 1, maxMemories: 1, maxArtifacts: 1, maxOperations: 1,
      maxSummaryCharacters: 16, maxEncodedBytes: 32 * 1024)
    let snapshot = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app", target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: String(repeating: "goal ", count: 20)),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: Array(offered)),
      createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z",
      status: .running, phase: .collecting, activeRound: 3)

    let context = try HarnessDecisionContextAssembler(limits: limits).assemble(
      snapshot: snapshot,
      availableOperations: Array(offered).sorted(),
      evaluation: nil,
      attempts: (1...4).map {
        HarnessContextAttempt(
          round: $0, operationReference: DebugCrashTaskHandler.captureDiagnostics,
          outcome: "observed", reasonCode: "operationSucceeded")
      },
      failures: [],
      memory: [],
      artifacts: [],
      elapsedSeconds: 5)
    XCTAssertEqual(context.recentAttempts.count, 1)
    XCTAssertEqual(context.availableOperations.count, 1)
    XCTAssertEqual(context.goalSummary.count, 16)
    XCTAssertTrue(context.trimmed.contains("attempts:kept1of4"))
    XCTAssertTrue(context.trimmed.contains("operations:kept1of9"))
  }

  // MARK: - Excerpts: what the model may now read, and what it still may not

  private func excerptSnapshot() -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app", target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "repair the crash"),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 1),
      policy: HarnessTaskPolicy(allowedOperations: Array(offered)),
      createdAtUTC: "2026-07-31T00:00:00Z", updatedAtUTC: "2026-07-31T00:00:00Z",
      status: .running, phase: .analyzing, activeRound: 3)
  }

  /// Self-debugging is the point: a model asked for a unified diff has to see
  /// the lines, and a model asked to judge a crash has to see the fault block.
  /// Both arrive bounded, and a bounded excerpt says so.
  func testEvidenceAndInScopeSourceReachTheModelAsBoundedExcerpts() throws {
    let limits = HarnessDecisionContextLimits(maxExcerptCharacters: 64, maxSourceFiles: 2)
    let longLog = String(repeating: "x", count: 200) + "FAULT-TAIL"
    let context = try HarnessDecisionContextAssembler(limits: limits).assemble(
      snapshot: excerptSnapshot(),
      availableOperations: Array(offered).sorted(),
      evaluation: nil,
      attempts: [], failures: [], memory: [],
      artifacts: [
        HarnessContextArtifact(
          artifactID: "ART-1", name: "hilog.txt", byteCount: longLog.utf8.count,
          sha256Prefix: "abc123abc123", verified: true,
          excerpt: String(longLog.suffix(64)), excerptTruncated: true),
        HarnessContextArtifact(
          artifactID: "ART-2", name: "crash-index.txt", byteCount: 12,
          sha256Prefix: "def456def456", verified: false),
      ],
      sourceFiles: [
        HarnessContextSourceFile(
          path: "entry/src/main/ets/CrashProbe.ets", byteCount: 40,
          sha256Prefix: "0f0f0f0f0f0f", excerpt: "export const ENABLED: boolean = true;")
      ],
      elapsedSeconds: 5)

    let log = try XCTUnwrap(context.artifacts.first { $0.name == "hilog.txt" })
    XCTAssertEqual(log.excerpt?.count, 64)
    XCTAssertTrue(log.excerptTruncated, "a shortened excerpt must say it was shortened")
    XCTAssertTrue(
      log.excerpt?.hasSuffix("FAULT-TAIL") ?? false,
      "the tail is what a crash reader needs, not the oldest boot noise")
    // Identity survives alongside content: the model can still tell "the same
    // artifact as last round" without relying on the text.
    XCTAssertEqual(log.byteCount, longLog.utf8.count)
    XCTAssertEqual(log.sha256Prefix, "abc123abc123")

    let unverified = try XCTUnwrap(context.artifacts.first { $0.name == "crash-index.txt" })
    XCTAssertNil(
      unverified.excerpt,
      "an artifact this run was not allowed to read carries no text at all")

    XCTAssertEqual(context.sourceFiles.count, 1)
    XCTAssertEqual(
      context.sourceFiles.first?.excerpt, "export const ENABLED: boolean = true;")
  }

  /// Excerpts are the only part of a context that grows with the work, so they
  /// give way first — and the context says what it lost. What it must never do
  /// is change the facts it asserts about an artifact while shedding text.
  func testOversizedContextShedsExcerptsBeforeRefusingAndRecordsIt() throws {
    let big = String(repeating: "s", count: 4_000)
    let artifacts = (1...4).map { index in
      HarnessContextArtifact(
        artifactID: "ART-\(index)", name: "hilog-\(index).txt", byteCount: big.utf8.count,
        sha256Prefix: "digest\(index)0000", verified: true, excerpt: big)
    }
    let sourceFiles = (1...4).map { index in
      HarnessContextSourceFile(
        path: "entry/src/main/ets/File\(index).ets", byteCount: big.utf8.count,
        sha256Prefix: "source\(index)0000", excerpt: big)
    }
    let snapshot = excerptSnapshot()

    // Room for the evidence text but not for the source text as well.
    let sourceShed = try HarnessDecisionContextAssembler(
      limits: HarnessDecisionContextLimits(maxEncodedBytes: 24 * 1024)
    ).assemble(
      snapshot: snapshot, availableOperations: [], evaluation: nil,
      attempts: [], failures: [], memory: [], artifacts: artifacts,
      sourceFiles: sourceFiles, elapsedSeconds: 5)
    XCTAssertTrue(sourceShed.sourceFiles.isEmpty)
    XCTAssertTrue(sourceShed.trimmed.contains { $0.hasPrefix("sourceFiles:droppedForSize") })
    XCTAssertTrue(sourceShed.artifacts.allSatisfy { $0.excerpt != nil })

    // Room for neither: the evidence text goes too, and every artifact keeps
    // its identity, size and digest exactly as before.
    let bothShed = try HarnessDecisionContextAssembler(
      limits: HarnessDecisionContextLimits(maxEncodedBytes: 8 * 1024)
    ).assemble(
      snapshot: snapshot, availableOperations: [], evaluation: nil,
      attempts: [], failures: [], memory: [], artifacts: artifacts,
      sourceFiles: sourceFiles, elapsedSeconds: 5)
    XCTAssertTrue(bothShed.sourceFiles.isEmpty)
    XCTAssertTrue(bothShed.artifacts.allSatisfy { $0.excerpt == nil })
    XCTAssertTrue(bothShed.trimmed.contains("artifactExcerpts:droppedForSize"))
    XCTAssertEqual(
      bothShed.artifacts.map(\.sha256Prefix), artifacts.map(\.sha256Prefix),
      "shedding text must not change what the context says an artifact is")
    XCTAssertEqual(bothShed.artifacts.map(\.byteCount), artifacts.map(\.byteCount))

    // A context that still cannot fit is refused, not silently emptied.
    XCTAssertThrowsError(
      try HarnessDecisionContextAssembler(
        limits: HarnessDecisionContextLimits(maxEncodedBytes: 256)
      ).assemble(
        snapshot: snapshot, availableOperations: [], evaluation: nil,
        attempts: [], failures: [], memory: [], artifacts: artifacts,
        sourceFiles: sourceFiles, elapsedSeconds: 5))
  }

  /// Widening what the model may read must not widen what it may identify.
  func testExcerptsDoNotCarryDeviceIdentity() throws {
    let context = try HarnessDecisionContextAssembler().assemble(
      snapshot: excerptSnapshot(),
      availableOperations: [], evaluation: nil, attempts: [], failures: [], memory: [],
      artifacts: [
        HarnessContextArtifact(
          artifactID: "ART-1", name: "hilog.txt", byteCount: 8, sha256Prefix: "aaaaaaaaaaaa",
          verified: true, excerpt: "a log line")
      ],
      sourceFiles: [
        HarnessContextSourceFile(
          path: "entry/src/main/ets/A.ets", byteCount: 4, sha256Prefix: "bbbbbbbbbbbb",
          excerpt: "let a = 1")
      ],
      elapsedSeconds: 5)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = String(decoding: try encoder.encode(context), as: UTF8.self)
    XCTAssertFalse(encoded.contains("TGT-1"), "the target still travels as a pseudonym")
    XCTAssertTrue(encoded.contains(context.targetPseudonym))
  }

  /// The round has to say what it is asking for. Without it the one round
  /// that matters most — "propose a patch" — is indistinguishable from "pick
  /// an operation", which is how a model ends up trying to invoke apply-patch
  /// instead of writing the diff apply-patch needs. Only questions a model is
  /// allowed to answer are named, so this cannot become a steering channel
  /// for a deterministic step it may not override.
  func testOnlyAnAnswerableAskIsNamedInTheContext() {
    func decision(kind: HarnessDecisionKind, reasonCode: String) -> HarnessDecision {
      HarnessDecision(
        decisionID: "dec-1", htaskID: "HTASK-0123456789AB", round: 1, kind: kind,
        hypothesis: "h", reasonCode: reasonCode, producer: "deterministic",
        createdAtUTC: "2026-07-31T00:00:00Z")
    }
    XCTAssertEqual(
      HarnessTaskCoordinator.requestedDecision(
        from: decision(kind: .requestHuman, reasonCode: "patchProposalRequired")),
      "proposePatch")
    // Every other human block is a question for a person, not for a model.
    XCTAssertNil(
      HarnessTaskCoordinator.requestedDecision(
        from: decision(kind: .requestHuman, reasonCode: "evidenceIntegrityUnresolved")))
    // A deterministic operation step is not up for negotiation.
    XCTAssertNil(
      HarnessTaskCoordinator.requestedDecision(
        from: decision(kind: .invokeOperation, reasonCode: "collectDeclaredEvidence")))
    XCTAssertNil(
      HarnessTaskCoordinator.requestedDecision(
        from: decision(kind: .noSafeAction, reasonCode: "patchProposalRequired")))
  }

  func testRevisionAwareExecutionStateIsCanonicalBoundedAndTraceable() throws {
    let baseRevision = String(repeating: "a", count: 64)
    let patchRevision = String(repeating: "b", count: 64)
    let deployedDigest = String(repeating: "c", count: 64)
    let artifactDigest = String(repeating: "d", count: 64)
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "modelProposal",
      selectedOperationFamily: DebugCrashTaskHandler.applyPatch,
      patchFingerprint: String(repeating: "e", count: 64),
      baseWorkspaceRevision: baseRevision,
      artifactSourceSet: ["ART-SOURCE"],
      prerequisiteSet: ["checkpointPublished"],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: "target-profile",
        toolchainProfile: "waterflow-debug",
        expectedNextObservation: "PATCH_APPLIED"))
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-000000000001", htaskID: "HTASK-0123456789AB", ordinal: 2,
      hypothesis: "free-form prose is intentionally absent from the summary",
      strategy: strategy, patchRevision: patchRevision,
      disprovedFacts: ["criterion:DC-2=fail"],
      createdAtUTC: "2026-08-01T00:00:00Z", updatedAtUTC: "2026-08-01T00:00:01Z")
    let derived = HarnessDerivedArtifactSummary(
      artifactID: "ART-DERIVED", name: "crash-signature.json",
      sourceArtifactIDs: ["ART-RAW"],
      analyzerReference: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      revisionScope: HarnessContextRevisionScope(
        workspaceRevision: patchRevision,
        deployedArtifactDigest: deployedDigest,
        deviceBindingRevision: 7),
      redactionStatus: "standard", contentSHA256: artifactDigest, byteCount: 412,
      measurements: ["matchingCrashCount": .integer(0)])
    let snapshot = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil,
      projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-1", expectedBindingRevision: 7),
      goal: HarnessTaskGoal(summary: "repair"), successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 12, maxWallClockSeconds: 600, maxArtifactBytes: 4096,
        maxE1Mutations: 4, maxModelCalls: 10),
      policy: HarnessTaskPolicy(allowedOperations: Array(offered)),
      createdAtUTC: "2026-08-01T00:00:00Z", updatedAtUTC: "2026-08-01T00:00:01Z",
      status: .running, phase: .patching, activeRound: 4,
      consumedBudget: HarnessConsumedBudget(
        rounds: 4, wallClockSeconds: 10, artifactBytes: 100, e1Mutations: 1,
        modelCalls: 3),
      version: 9)
    let unavailable = HarnessContextUnavailableOperation(
      operationReference: DebugCrashTaskHandler.runTests,
      reasonCode: "presetUnavailable")
    let execution = HarnessContextExecutionState(
      activeAttempt: attempt,
      currentWorkspaceRevision: patchRevision,
      currentDeployedArtifactDigest: deployedDigest,
      currentDeviceBindingRevision: 7,
      disprovedHypotheses: ["ATTEMPT-000000000001:criterion:DC-2=fail"],
      unavailableOperations: [unavailable],
      authorizedOperationReferences: [
        DebugCrashTaskHandler.applyPatch, DebugCrashTaskHandler.runTests,
      ],
      currentCapabilityEffectCeiling: .deviceMutation,
      allowedFileScopes: [
        "entry/src/main/ets/crashprobe/CrashProbe.ets", "/Users/operator/secret",
        "../outside",
      ],
      derivedArtifactSummaries: [derived])
    let assembler = HarnessDecisionContextAssembler()
    let first = try assembler.assemble(
      snapshot: snapshot, availableOperations: [DebugCrashTaskHandler.applyPatch],
      evaluation: nil, attempts: [], failures: [], memory: [], artifacts: [],
      elapsedSeconds: 10, executionState: execution)

    XCTAssertEqual(first.currentTaskStateVersion, 9)
    XCTAssertEqual(first.activeAttemptID, attempt.attemptID)
    XCTAssertEqual(first.activeAttemptSummary?.strategyFingerprint, attempt.strategyFingerprint)
    XCTAssertEqual(first.activeAttemptSummary?.baseWorkspaceRevision, baseRevision)
    XCTAssertEqual(first.currentWorkspaceRevision, patchRevision)
    XCTAssertEqual(first.currentDeployedArtifactDigest, deployedDigest)
    XCTAssertEqual(first.currentDeviceBindingRevision, 7)
    XCTAssertEqual(first.expectedNextObservation, "PATCH_APPLIED")
    XCTAssertEqual(first.disprovedHypotheses, ["ATTEMPT-000000000001:criterion:DC-2=fail"])
    XCTAssertEqual(first.unavailableOperationsAndReasons, [unavailable])
    XCTAssertEqual(first.currentCapabilityEffectCeiling, .deviceMutation)
    XCTAssertEqual(
      first.allowedFileScopes, ["entry/src/main/ets/crashprobe/CrashProbe.ets"],
      "host-absolute and escaping scopes must not cross egress")
    XCTAssertEqual(first.budget.modelCallsRemaining, 7)
    XCTAssertEqual(first.derivedArtifactSummaries.first?.sourceArtifactIDs, ["ART-RAW"])
    XCTAssertEqual(first.derivedArtifactSummaries.first?.contentSHA256, artifactDigest)
    XCTAssertLessThanOrEqual(
      first.transmittedByteCount, HarnessDecisionContextLimits.default.maxEncodedBytes)

    let second = try assembler.assemble(
      snapshot: snapshot, availableOperations: [DebugCrashTaskHandler.applyPatch],
      evaluation: nil, attempts: [], failures: [], memory: [], artifacts: [],
      elapsedSeconds: 10,
      executionState: HarnessContextExecutionState(
        activeAttempt: attempt,
        currentWorkspaceRevision: String(repeating: "f", count: 64),
        currentDeployedArtifactDigest: deployedDigest,
        currentDeviceBindingRevision: 7))
    XCTAssertNotEqual(
      first.transmittedDigest, second.transmittedDigest,
      "an exact revision change must change the hash of what the model receives")

    let unsafeReason = HarnessContextUnavailableOperation(
      operationReference: DebugCrashTaskHandler.runTests,
      reasonCode: "missing preset at /Users/operator/project")
    XCTAssertEqual(unsafeReason.reasonCode, "operationUnavailable")
    let unsafeContext = try assembler.assemble(
      snapshot: snapshot, availableOperations: [], evaluation: nil, attempts: [],
      failures: [], memory: [], artifacts: [], elapsedSeconds: 10,
      executionState: HarnessContextExecutionState(
        disprovedHypotheses: ["source:/Users/operator/project/build.log"]))
    XCTAssertTrue(
      HarnessEgressScreen.violations(in: unsafeContext, targetID: "TGT-1").contains("/Users/"),
      "a host absolute path in any future summary must fail the final egress screen")
  }

  func testCoordinatorSeparatesUnavailableOperationsFromTheOffer() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [
      .success(
        encodeProposal([
          "kind": .string("noSafeAction"),
          "hypothesis": .string("No currently available operation is safe."),
        ]))
    ])
    let availability = GatewayAvailability(unavailable: [
      DebugCrashTaskHandler.observeDevice: "providerUnavailable"
    ])
    let (coordinator, _, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]),
      jobs: jobs, expectedBindingRevision: 7,
      policyGuard: HarnessPolicyGuard(availability: availability))
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    let context = try XCTUnwrap(gateway.seenContexts.first)
    XCTAssertEqual(context.currentTaskStateVersion, 2)
    XCTAssertEqual(context.currentDeviceBindingRevision, 7)
    XCTAssertTrue(context.availableOperations.isEmpty)
    XCTAssertEqual(
      context.unavailableOperationsAndReasons,
      [
        HarnessContextUnavailableOperation(
          operationReference: DebugCrashTaskHandler.observeDevice,
          reasonCode: "providerUnavailable")
      ])
    XCTAssertFalse(context.authorizedOperationRefs.contains(DebugCrashTaskHandler.observeDevice))
    XCTAssertTrue(jobs.submittedOperations.isEmpty, "an unavailable operation must reach zero dispatch")
  }

  func testCoordinatorProjectsStandingCapabilityWithoutExposingItsIdentifier() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [
      .success(
        encodeProposal([
          "kind": .string("invokeOperation"),
          "operationRef": .string(DebugCrashTaskHandler.observeDevice),
          "hypothesis": .string("Observe the bound target."),
        ])),
      .success(
        encodeProposal([
          "kind": .string("invokeOperation"),
          "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
          "hypothesis": .string("Capture the declared evidence."),
        ])),
    ])
    let capabilities = GatewayCapabilities(covered: [
      DebugCrashTaskHandler.captureDiagnostics
    ])
    let (coordinator, _, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]),
      jobs: jobs, expectedBindingRevision: 7,
      policyGuard: HarnessPolicyGuard(capabilities: capabilities))
    let task = try await coordinator.submit(submission)

    let first = try await coordinator.reconcile(task.htaskID)
    let firstJob = try XCTUnwrap(first.snapshot.activeJobID)
    jobs.finish(firstJob)
    _ = try await coordinator.reconcile(task.htaskID)
    _ = try await coordinator.reconcile(task.htaskID)

    let context = try XCTUnwrap(gateway.seenContexts.last)
    XCTAssertEqual(context.availableOperations, [DebugCrashTaskHandler.captureDiagnostics])
    XCTAssertEqual(context.currentCapabilityEffectCeiling, .deviceMutation)
    XCTAssertEqual(
      context.authorizedOperationRefs, [DebugCrashTaskHandler.captureDiagnostics])
    let wire = try XCTUnwrap(String(data: context.transmittedBytes, encoding: .utf8))
    XCTAssertFalse(wire.localizedCaseInsensitiveContains("capabilityId"))
    XCTAssertFalse(wire.contains("CAP-"))
  }

  func testAnOversizedContextIsRefusedInsteadOfSent() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [])
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, nowUTC: { "2026-07-31T00:00:00Z" },
      decisionGateway: gateway,
      egressPolicy: HarnessEgressPolicy(
        enabledProjects: ["demo-app"],
        // A ceiling nothing can fit under: the assembler must refuse rather
        // than ship a context the policy never sized for.
        limits: HarnessDecisionContextLimits(maxEncodedBytes: 64)))
    let task = try await coordinator.submit(
      HarnessTaskSubmission(
        type: .debugCrash, projectRef: "demo-app",
        target: HarnessTaskTargetReference(targetID: "TGT-1"),
        goal: HarnessTaskGoal(summary: "goal"),
        budgets: HarnessTaskBudgets(
          maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
        policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash)))

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(gateway.seenContexts.count, 0, "an oversized context is never handed over")
    XCTAssertTrue(outcome.reasonCode.contains("gatewayUnavailable:contextTooLarge"))
    XCTAssertEqual(outcome.action, .dispatched, "the deterministic strategy still runs")
  }

  // MARK: - HTP-AC-14: replaceable port, no session state

  func testARejectedProposalFallsBackVisiblyAndChangesNothingElse() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [
      // A model claiming the task is fixed: refused as a forbidden field, and
      // the loop proceeds on the deterministic strategy.
      .success(
        encodeProposal([
          "kind": .string("noSafeAction"), "hypothesis": .string("already fixed"),
          "status": .string("succeeded"),
        ]))
    ])
    let (coordinator, store, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]), jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertNotEqual(outcome.snapshot.status, .succeeded, "a model cannot declare success")
    XCTAssertTrue(outcome.reasonCode.contains("proposalRejected:forbiddenField:status"))
    let decision = try await store.decision(task.htaskID, round: 1)
    XCTAssertEqual(decision?.producer, "debug-crash-handler@1")
    let memory = try await store.memory(scope: .task, key: task.htaskID)
    XCTAssertTrue(memory.contains { $0.summary.contains("proposalRejected:forbiddenField:status") })
  }

  func testRepairOperationsArePhaseBoundAndCannotReplaceHandlerOwnedInputs() async throws {
    let diff = """
      diff --git a/Sources/A.swift b/Sources/A.swift
      --- a/Sources/A.swift
      +++ b/Sources/A.swift
      @@ -1 +1 @@
      -let value = 0
      +let value = 1
      """
    let digest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(replies: [
      .success(
        encodeProposal([
          "kind": .string("proposePatch"),
          "hypothesis": .string("Patch before any evidence exists."),
          "baseWorkspaceRevision": .string(String(repeating: "1", count: 64)),
          "patchSha256": .string(digest), "unifiedDiff": .string(diff),
          "touchedFiles": .array([.string("Sources/A.swift")]),
          "expectedChangedSymbols": .array([.string("value")]),
        ]))
    ])
    let (coordinator, _, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]), jobs: jobs)
    let task = try await coordinator.submit(submission)

    let outcome = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(outcome.action, .dispatched)
    XCTAssertEqual(jobs.submittedOperations, [DebugCrashTaskHandler.observeDevice])
    XCTAssertEqual(
      Set(try XCTUnwrap(gateway.seenContexts.first).availableOperations),
      [DebugCrashTaskHandler.observeDevice])
    XCTAssertTrue(outcome.reasonCode.contains("operationNotOffered:workspace.apply-patch@1"))

    let deterministic = DebugCrashTaskHandler().plan(
      for: task, decisionID: "dec-fixture", nowUTC: "2026-07-31T00:00:00Z").decision
    let injectedDeploy = HarnessDecisionProposal(
      kind: .invokeOperation, operationReference: DebugCrashTaskHandler.deployHAP,
      inputs: ["hapArtifactLease": .string("lease-v1:foreign:ART-1")],
      hypothesis: "deploy", reasonCode: "deploy", confidence: nil)
    XCTAssertThrowsError(
      try HarnessTaskCoordinator.validateModelProposal(
        injectedDeploy, against: deterministic))

    let contextualInput = HarnessDecisionProposal(
      kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.observeDevice,
      inputs: ["targetPseudonym": .string("target-aeb60a604573")],
      hypothesis: "observe", reasonCode: "observe", confidence: nil)
    XCTAssertThrowsError(
      try HarnessTaskCoordinator.validateModelProposal(
        contextualInput, against: deterministic)
    ) { error in
      XCTAssertEqual(
        error as? HarnessDecisionRejection,
        .operationNotExpected(DebugCrashTaskHandler.observeDevice))
    }

    let exactAnalyzer = HarnessDecision(
      decisionID: "dec-analyzer", htaskID: task.htaskID, round: 2,
      kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.analyzeCrashLedger,
      inputs: ["sourceArtifactRef": .string("lease-v1:source:ART-source")],
      hypothesis: "analyze", reasonCode: "analyze", producer: "fixture",
      createdAtUTC: "2026-07-31T00:00:00Z")
    let prematureStop = HarnessDecisionProposal(
      kind: .requestHuman, operationReference: nil, inputs: [:],
      hypothesis: "stop", reasonCode: "stop", confidence: nil)
    let matchingAnalyzer = HarnessDecisionProposal(
      kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.analyzeCrashLedger,
      inputs: exactAnalyzer.inputs,
      hypothesis: "analyze", reasonCode: "analyze", confidence: nil)
    XCTAssertNoThrow(
      try HarnessTaskCoordinator.validateModelProposal(
        matchingAnalyzer, against: exactAnalyzer))
    XCTAssertThrowsError(
      try HarnessTaskCoordinator.validateModelProposal(
        prematureStop, against: exactAnalyzer)
    ) { error in
      XCTAssertEqual(
        error as? HarnessDecisionRejection,
        .operationNotExpected(DebugCrashTaskHandler.analyzeCrashLedger))
    }
  }

  func testConclusionsFollowTheStepNotTheProducer() async throws {
    // The same two steps, proposed two ways: by the built-in handler (no
    // gateway configured) and by a model through the port. The state machine
    // must reach the same conclusions, including the honest stop at the end.
    func run(_ gateway: (any HarnessDecisionGateway)?) async throws -> [String] {
      rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("arkdeck-harness-gateway-swap", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      let jobs = GatewayJobPort()
      let (coordinator, _, submission) = try makeStack(
        gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]), jobs: jobs)
      let task = try await coordinator.submit(submission)
      var trace: [String] = []
      var priorModelCalls = 0
      for round in 1...4 {
        let outcome = try await coordinator.reconcile(task.htaskID)
        XCTAssertGreaterThanOrEqual(
          outcome.snapshot.consumedBudget.modelCalls, priorModelCalls,
          "observing a completed runtime job must not erase already charged model calls")
        priorModelCalls = outcome.snapshot.consumedBudget.modelCalls
        trace.append("\(outcome.action.rawValue)/\(jobs.submittedOperations.last ?? "-")")
        if ![HarnessTaskLifecycle.running, .waiting, .created].contains(
          outcome.snapshot.lifecycle)
        { break }
        jobs.finish("JOB-\(round)")
      }
      return trace
    }

    let builtIn = try await run(nil)
    let throughThePort = try await run(
      ScriptedGateway(replies: [
        .success(
          encodeProposal([
            "kind": .string("invokeOperation"),
            "operationRef": .string(DebugCrashTaskHandler.observeDevice),
            "hypothesis": .string("Observe the target first."),
          ])),
        .success(
          encodeProposal([
            "kind": .string("invokeOperation"),
            "operationRef": .string(DebugCrashTaskHandler.captureDiagnostics),
            "hypothesis": .string("Collect the declared evidence."),
          ])),
        // Third wake: the model is unreachable. The loop must reach the same
        // conclusion the built-in producer would.
        .failure(HarnessDecisionGatewayError.transportFailure("socket closed")),
      ]))
    XCTAssertEqual(
      builtIn, throughThePort,
      "conclusions must follow the proposed step, not the identity of the producer")
    XCTAssertEqual(builtIn.last?.hasPrefix("stoppedForHuman"), true)
  }

  func testTaskStateHoldsNoModelSessionHandle() async throws {
    let jobs = GatewayJobPort()
    let gateway = ScriptedGateway(
      producerID: "scripted-gateway@1",
      replies: [
        .success(
          encodeProposal([
            "kind": .string("invokeOperation"),
            "operationRef": .string(DebugCrashTaskHandler.observeDevice),
            "hypothesis": .string("Observe first."),
          ]))
      ])
    let (coordinator, store, submission) = try makeStack(
      gateway: gateway, egress: HarnessEgressPolicy(enabledProjects: ["demo-app"]), jobs: jobs)
    let task = try await coordinator.submit(submission)
    _ = try await coordinator.reconcile(task.htaskID)

    // The decision record names the producer; the task snapshot itself carries
    // no conversation, no session id and no model output.
    let loadedDecision = try await store.decision(task.htaskID, round: 1)
    let decision = try XCTUnwrap(loadedDecision)
    XCTAssertEqual(decision.producer, "scripted-gateway@1")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let reloaded = try await store.load(task.htaskID)
    let snapshotJSON = try XCTUnwrap(
      String(data: try encoder.encode(reloaded), encoding: .utf8))
    for marker in ["session", "conversation", "messages", "apiKey", "token"] {
      XCTAssertFalse(
        snapshotJSON.localizedCaseInsensitiveContains(marker),
        "task state must not hold \(marker)")
    }
  }
}
