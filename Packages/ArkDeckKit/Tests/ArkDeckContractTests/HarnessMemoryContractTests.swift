import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import Foundation
import XCTest

@testable import ArkDeckHarness

final class HarnessMemoryContractTests: XCTestCase {
  private let revisionA = String(repeating: "a", count: 64)
  private let revisionB = String(repeating: "b", count: 64)
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-hfa010-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  // MARK: - HFA-AC-20: promotion authority

  func testVerifiedMemoryRequiresAPassOrHumanReceiptAndExactScope() throws {
    XCTAssertThrowsError(
      try HarnessMemoryEntry(
        memoryID: "MEM-NARRATED", scope: .project, kind: .verifiedKnowledge,
        htaskID: "HTASK-1", projectRef: "waterflow", round: 1,
        summary: "the model says this is fixed", confidence: .evaluated,
        evidence: HarnessMemoryEvidence(jobIDs: ["JOB-1"]), lifecycle: .verified,
        applicability: exactScope(),
        invalidationConditions: invalidationConditions(),
        createdAtUTC: timestamp(0))
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .verificationRequired)
    }

    XCTAssertThrowsError(
      try verified(
        id: "MEM-WRONG-RECEIPT", verificationID: "EVAL-2",
        evidence: HarnessMemoryEvidence(evaluationID: "EVAL-1"))
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .verificationEvidenceMismatch)
    }

    XCTAssertThrowsError(
      try HarnessMemoryEntry(
        memoryID: "MEM-UNSCOPED", scope: .project, kind: .verifiedKnowledge,
        htaskID: "HTASK-1", projectRef: "waterflow", round: 1,
        summary: "passed but has no applicability", confidence: .evaluated,
        evidence: HarnessMemoryEvidence(evaluationID: "EVAL-1"), lifecycle: .verified,
        applicability: HarnessMemoryApplicability(),
        invalidationConditions: invalidationConditions(),
        verification: HarnessMemoryVerification(
          source: .evaluatorPass, evidenceID: "EVAL-1", verifiedAtUTC: timestamp(1)),
        createdAtUTC: timestamp(0))
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .verifiedMemoryRequiresExactScope)
    }
  }

  func testHumanPromotionNeedsTheSameDurableHumanActionIdentity() throws {
    let candidate = try taskCandidate(id: "MEM-HUMAN")
    let verification = HarnessMemoryVerification(
      source: .humanConfirmation, evidenceID: "HACT-1", verifiedAtUTC: timestamp(2))

    XCTAssertThrowsError(
      try candidate.promoting(
        toProjectRef: "waterflow", verification: verification,
        applicability: exactScope(), invalidationConditions: invalidationConditions(),
        additionalEvidence: HarnessMemoryEvidence(requestIDs: ["HACT-1"]),
        atUTC: timestamp(2))
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .verificationEvidenceMismatch)
    }

    let promoted = try candidate.promoting(
      toProjectRef: "waterflow", verification: verification,
      applicability: exactScope(), invalidationConditions: invalidationConditions(),
      additionalEvidence: HarnessMemoryEvidence(humanActionIDs: ["HACT-1"]),
      atUTC: timestamp(2))
    XCTAssertEqual(promoted.lifecycle, .verified)
    XCTAssertEqual(promoted.confidence, .humanConfirmed)
    XCTAssertEqual(promoted.verification?.evidenceID, "HACT-1")
  }

  func testDecodedVerifiedMemoryCannotBypassPromotionAuthority() throws {
    let forged = """
      {
        "documentType":"harness-memory-entry",
        "schemaVersion":"2.0.0",
        "memoryId":"MEM-FORGED",
        "scope":"project",
        "kind":"verifiedKnowledge",
        "lifecycle":"VERIFIED",
        "htaskId":"HTASK-1",
        "projectRef":"waterflow",
        "round":1,
        "summary":"self-declared success",
        "confidence":"evaluated",
        "evidence":{"evaluationId":"EVAL-1"},
        "applicability":{
          "component":"debugCrash",
          "symbols":[],
          "filePaths":[],
          "failureFingerprints":[],
          "operationReferences":[],
          "revisionScope":{"exactRevisions":["\(revisionA)"]},
          "deviceProfiles":["dayu200"],
          "toolchainProfiles":["waterflow-debug@1"]
        },
        "invalidationConditions":[
          {"kind":"EVIDENCE_UNAVAILABLE","expectedValues":["EVAL-1"]}
        ],
        "createdAtUtc":"2026-08-01T00:00:00Z",
        "updatedAtUtc":"2026-08-01T00:00:01Z"
      }
      """

    XCTAssertThrowsError(
      try JSONDecoder().decode(HarnessMemoryEntry.self, from: Data(forged.utf8))
    ) { error in
      XCTAssertEqual(error as? HarnessMemoryError, .verificationRequired)
    }
  }

  // MARK: - exact filter, then rank

  func testExactScopeFiltersBeforeRankingAndCandidatesStayBelowCurrentEvidence() throws {
    let matching = try verified(id: "MEM-MATCH")
    let wrongRevision = try verified(
      id: "MEM-REVISION", applicability: exactScope(revision: revisionB))
    let wrongDevice = try verified(
      id: "MEM-DEVICE", applicability: exactScope(device: "phone@1"))
    let wrongToolchain = try verified(
      id: "MEM-TOOLCHAIN", applicability: exactScope(toolchain: "clang-release@1"))
    let wrongComponent = try verified(
      id: "MEM-COMPONENT", applicability: exactScope(component: "flashFirmware"))
    let wrongFile = try verified(
      id: "MEM-FILE", applicability: exactScope(filePath: "entry/src/main/ets/pages/About.ets"))
    let wrongSymbol = try verified(
      id: "MEM-SYMBOL", applicability: exactScope(symbol: "AboutPage.onLoad"))
    let wrongFingerprint = try verified(
      id: "MEM-FINGERPRINT", applicability: exactScope(fingerprint: "FAIL-999"))
    let wrongOperation = try verified(
      id: "MEM-OPERATION", applicability: exactScope(operation: "workspace.search-source@1"))
    let candidate = try taskCandidate(id: "MEM-CANDIDATE")
    let superseded = try matching.superseding(
      by: "MEM-NEW", evidence: HarnessMemoryEvidence(requestIDs: ["REQ-2"]),
      atUTC: timestamp(4))
    let invalidated = try verified(id: "MEM-INVALID").invalidating(
      reason: "evidenceRevoked", evidence: HarnessMemoryEvidence(requestIDs: ["REQ-3"]),
      atUTC: timestamp(5))

    let selection = HarnessMemorySelector.select(
      [
        matching, wrongRevision, wrongDevice, wrongToolchain, wrongComponent, wrongFile,
        wrongSymbol, wrongFingerprint, wrongOperation, candidate, superseded, invalidated,
      ],
      matching: query(), limit: 8)

    XCTAssertEqual(Set(selection.entries.map(\.memoryID)), ["MEM-CANDIDATE"])
    // MEM-MATCH's latest row is SUPERSEDED, so the older VERIFIED row cannot
    // leak through; the other project memories fail exact filtering.
    XCTAssertEqual(selection.manifest.excludedLifecycleCount, 2)
    XCTAssertEqual(selection.manifest.excludedScopeCount, 8)
    let candidateRecord = try XCTUnwrap(selection.manifest.selected.first)
    XCTAssertEqual(candidateRecord.lifecycle, .candidate)
    XCTAssertLessThan(
      candidateRecord.score, selection.manifest.currentEvidenceScore,
      "an unverified memory can never outrank evidence from this task")
  }

  func testMatchingVerifiedMemoryOutranksCandidateAndLifecycleRowsCollapseAfterRestart()
    async throws
  {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let candidate = try taskCandidate(id: "MEM-CANDIDATE")
    let matching = try verified(id: "MEM-MATCH")
    try await store.appendMemory(candidate)
    try await store.appendMemory(matching)

    let first = HarnessMemorySelector.select(
      [candidate, matching], matching: query(), limit: 8)
    XCTAssertEqual(first.entries.map(\.memoryID), ["MEM-MATCH", "MEM-CANDIDATE"])
    XCTAssertGreaterThan(
      try XCTUnwrap(first.manifest.selected.first).score,
      try XCTUnwrap(first.manifest.selected.last).score)

    let invalidated = try matching.invalidating(
      reason: "operatorRevokedEvidence",
      evidence: HarnessMemoryEvidence(humanActionIDs: ["HACT-2"]),
      atUTC: timestamp(9))
    try await store.appendMemory(invalidated)
    let reloaded = try await store.memory(scope: .project, key: "waterflow")
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.lifecycle, .invalidated)
    let history = try await store.memoryHistory(scope: .project, key: "waterflow")
    XCTAssertEqual(history.count, 2, "the lifecycle audit remains append-only")
    XCTAssertTrue(
      HarnessMemorySelector.select(reloaded, matching: query(), limit: 8).entries.isEmpty)
  }

  // MARK: - ContextAssembler integration

  func testContextConfirmedFactsContainOnlyInScopeVerifiedMemory() throws {
    let matching = try verified(id: "MEM-MATCH", summary: "WaterFlow crash fix is durable")
    let foreign = try verified(
      id: "MEM-FOREIGN", summary: "foreign revision claim",
      applicability: exactScope(revision: revisionB))
    let candidate = try taskCandidate(id: "MEM-CANDIDATE", summary: "unverified suggestion")
    let context = try HarnessDecisionContextAssembler().assemble(
      snapshot: snapshot(), availableOperations: ["workspace.inspect-diff@1"],
      evaluation: nil, attempts: [], failures: [],
      memory: [matching, foreign, candidate], artifacts: [], elapsedSeconds: 5,
      memoryQuery: query())

    XCTAssertTrue(context.relevantMemory.contains { $0.contains("WaterFlow crash fix is durable") })
    XCTAssertTrue(context.relevantMemory.contains { $0.contains("unverified suggestion") })
    XCTAssertFalse(context.relevantMemory.contains { $0.contains("foreign revision claim") })
    XCTAssertTrue(
      context.confirmedFacts.current.contains {
        $0.contains("MEM-MATCH") && $0.contains("WaterFlow crash fix is durable")
      })
    XCTAssertFalse(context.confirmedFacts.current.contains { $0.contains("unverified suggestion") })
    XCTAssertFalse(
      context.confirmedFacts.current.contains { $0.contains("foreign revision claim") })
    XCTAssertEqual(
      context.memorySelectionManifest.selected.first?.reason, .exactProjectScope)
    XCTAssertEqual(context.memorySelectionManifest.excludedScopeCount, 1)
  }

  func testLegacyProjectMemoryLoadsFailClosedInsteadOfGainingScope() throws {
    let legacy = """
      {
        "documentType":"harness-memory-entry",
        "memoryId":"MEM-LEGACY",
        "scope":"project",
        "kind":"verifiedKnowledge",
        "htaskId":"HTASK-1",
        "projectRef":"waterflow",
        "round":1,
        "summary":"old evaluated statement",
        "confidence":"evaluated",
        "evidence":{"evaluationId":"EVAL-OLD"},
        "createdAtUtc":"2026-07-31T00:00:00Z"
      }
      """
    let entry = try JSONDecoder().decode(HarnessMemoryEntry.self, from: Data(legacy.utf8))
    XCTAssertEqual(entry.lifecycle, .invalidated)
    XCTAssertEqual(entry.invalidationReason, "legacyMemoryMissingExactScope")
    XCTAssertTrue(
      HarnessMemorySelector.select([entry], matching: query(), limit: 8).entries.isEmpty)
  }

  func testFailureMemoryCarriesFiveClosedDispositionsAndTypedAlternatives() {
    XCTAssertEqual(HarnessFailureRetryDisposition.allCases.count, 5)
    let semantic = failureFingerprint("BUILD_SEMANTIC_FAILURE")
    XCTAssertEqual(semantic.retryDisposition, .alternativeRequired)
    XCTAssertEqual(
      semantic.alternativeHints,
      ["inspectBuildFailure", "changePatchStrategy", "changeToolchainPreset"])
    XCTAssertEqual(
      failureFingerprint("RATE_LIMITED").retryDisposition, .retryAfterBackoff)
    XCTAssertEqual(
      failureFingerprint("DEVICE_UNAVAILABLE").retryDisposition, .retryAfterObservation)
    XCTAssertEqual(
      failureFingerprint("POLICY_DENIED").retryDisposition, .doNotRetry)
    XCTAssertEqual(
      failureFingerprint("TRANSIENT").retryDisposition, .actionRetryAllowed)
  }

  // MARK: - Fixtures

  private func exactScope(
    revision: String? = nil,
    device: String = "dayu200",
    toolchain: String = "waterflow-debug@1",
    component: String = HarnessTaskType.debugCrash.rawValue,
    filePath: String = "entry/src/main/ets/pages/Index.ets",
    symbol: String = "CrashController.onClick",
    fingerprint: String = "FAIL-001",
    operation: String = "workspace.inspect-diff@1"
  ) -> HarnessMemoryApplicability {
    HarnessMemoryApplicability(
      component: component,
      symbols: [symbol],
      filePaths: [filePath],
      failureFingerprints: [fingerprint],
      operationReferences: [operation],
      revisionScope: HarnessMemoryRevisionScope(exactRevision: revision ?? revisionA),
      deviceProfiles: [device], toolchainProfiles: [toolchain])
  }

  private func invalidationConditions() -> [HarnessMemoryInvalidationCondition] {
    [
      HarnessMemoryInvalidationCondition(
        kind: .revisionLeavesScope, expectedValues: [revisionA]),
      HarnessMemoryInvalidationCondition(
        kind: .deviceProfileLeavesScope, expectedValues: ["dayu200"]),
      HarnessMemoryInvalidationCondition(
        kind: .toolchainProfileLeavesScope, expectedValues: ["waterflow-debug@1"]),
      HarnessMemoryInvalidationCondition(
        kind: .evidenceUnavailable, expectedValues: ["EVAL-1"]),
    ]
  }

  private func verified(
    id: String,
    summary: String = "verified scoped fact",
    verificationID: String = "EVAL-1",
    evidence: HarnessMemoryEvidence? = nil,
    applicability: HarnessMemoryApplicability? = nil
  ) throws -> HarnessMemoryEntry {
    try HarnessMemoryEntry(
      memoryID: id, scope: .project, kind: .verifiedKnowledge,
      htaskID: "HTASK-1", projectRef: "waterflow", round: 1,
      summary: summary, confidence: .evaluated,
      evidence: evidence
        ?? HarnessMemoryEvidence(
          artifactIDs: ["ART-1"], evaluationID: verificationID,
          workspaceRevision: revisionA),
      lifecycle: .verified, applicability: applicability ?? exactScope(),
      invalidationConditions: invalidationConditions(),
      verification: HarnessMemoryVerification(
        source: .evaluatorPass, evidenceID: verificationID, verifiedAtUTC: timestamp(1)),
      createdAtUTC: timestamp(0), updatedAtUTC: timestamp(1))
  }

  private func taskCandidate(
    id: String,
    summary: String = "candidate task observation"
  ) throws -> HarnessMemoryEntry {
    try HarnessMemoryEntry(
      memoryID: id, scope: .task, kind: .observation,
      htaskID: "HTASK-1", projectRef: "waterflow", round: 1,
      summary: summary, confidence: .observed,
      evidence: HarnessMemoryEvidence(jobIDs: ["JOB-1"]),
      createdAtUTC: timestamp(0))
  }

  private func query() -> HarnessMemoryQuery {
    HarnessMemoryQuery(
      htaskID: "HTASK-1", projectRef: "waterflow",
      failureFingerprints: ["FAIL-001"],
      components: [HarnessTaskType.debugCrash.rawValue],
      filePaths: ["entry/src/main/ets/pages/Index.ets"],
      symbols: ["CrashController.onClick"],
      operationReferences: ["workspace.inspect-diff@1"],
      revision: revisionA, deviceProfiles: ["dayu200"],
      toolchainProfiles: ["waterflow-debug@1"])
  }

  private func snapshot() -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-1", type: .debugCrash, intakeDescription: nil,
      projectRef: "waterflow", target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(
        summary: "fix WaterFlow crash",
        desiredState: [
          "component": .string(HarnessTaskType.debugCrash.rawValue),
          "baseWorkspaceRevision": .string(revisionA),
          "deviceProfile": .string("dayu200"),
          "buildPresetRef": .string("waterflow-debug@1"),
        ]),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: ["workspace.inspect-diff@1"]),
      createdAtUTC: timestamp(0), updatedAtUTC: timestamp(1),
      lifecycle: .running, stage: .analyzing, activeRound: 1)
  }

  private func failureFingerprint(_ classification: String) -> HarnessFailureFingerprint {
    HarnessFailureFingerprint(
      operationReference: "workspace.build-openharmony@1", phase: .building,
      providerID: "workspace", targetProfile: "waterflow",
      normalizedInputsSHA256: revisionA,
      errorClassification: classification, semanticErrorCode: "fixture")
  }

  private func timestamp(_ second: Int) -> String {
    String(format: "2026-08-01T00:00:%02dZ", second)
  }
}
