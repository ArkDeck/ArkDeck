// Evolution adversarial-review leg contract tests (CHG-2026-025, TASK-AIN-019).
//
// The review leg replaces the human merge gate for unmerged Evolution
// candidates: evaluation PASS alone must never promote. These tests drive
// `finishEvolutionEvaluation` through the public reconcile surface and pin
// every verdict branch: no reviewer / no candidate / no immutable diff /
// exhausted model budget stop for a human; REJECT keeps the loop alive with a
// rollback obligation; COMMENT stops for a human; PASS crosses the promotion
// gate only when every recorded fact still holds. The Codex adapter half
// pins the closed response shape and the identity binding of the verdict.

import CryptoKit
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

// MARK: - Fixtures

private let reviewNow = "2026-08-02T00:00:00Z"

/// Real empty-index bytes shape: the device answered and has nothing.
private let emptyCrashIndex = """

  -------------------------------[ability]-------------------------------


  ----------------------------------HiviewService----------------------------------
  No fault log exist.
  Fault log list:
  ******
  ******
  """

private actor ReviewJobPort: HarnessRuntimeJobPort {
  private var observations: [String: HarnessJobObservation]
  private var submitted: [String] = []
  private var ordinal = 1

  init(observations: [String: HarnessJobObservation]) {
    self.observations = observations
  }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    submitted.append(request.operation.reference)
    let jobID = "JOB-NEXT-\(ordinal)"
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

  func finish(_ jobID: String, state: String = "succeeded") {
    observations[jobID] = HarnessJobObservation(
      jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
      outcomeUnknown: false, waitingForHuman: false, timeline: ["running", state])
  }
}

private final class ReviewArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private struct Staged {
    let descriptor: HarnessArtifactDescriptor
    let bytes: Data
  }

  private let lock = NSLock()
  private var staged: [String: [Staged]] = [:]

  func stage(jobID: String, name: String, text: String) {
    let data = Data(text.utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let descriptor = HarnessArtifactDescriptor(
      artifactID: "ART-\(jobID)-\(name)", name: name, mediaType: "text/plain",
      byteCount: data.count, sha256: digest, published: true, sensitive: false,
      missingReason: nil)
    lock.withLock { staged[jobID, default: []].append(Staged(descriptor: descriptor, bytes: data)) }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    lock.withLock { (staged[jobID] ?? []).map(\.descriptor) }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      guard
        let match = (staged[jobID] ?? []).first(where: { $0.descriptor.artifactID == artifactID })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return match.bytes.prefix(maximumBytes)
    }
  }

  func leaseReference(jobID: String, artifactID: String) async throws -> String {
    throw HarnessArtifactPortError.unavailable(
      "artifact leases are unavailable in this composition")
  }
}

private struct ReviewRepairPort: HarnessRepairPort {
  var liveRevisionOverride: String?

  func currentWorkspaceRevision(
    relativePaths: [String], projectRef: String, task: HarnessTaskSnapshot
  ) async throws -> String {
    if let liveRevisionOverride { return liveRevisionOverride }
    if let revision = task.repairAttempt?.patchRevision { return revision }
    return String(repeating: "0", count: 64)
  }

  func preparePatch(
    _ proposal: HarnessPatchProposal, projectRef: String,
    task: HarnessTaskSnapshot, decisionID: String
  ) async throws -> HarnessPreparedPatch {
    HarnessPreparedPatch(
      inputs: ["projectRef": .string(projectRef)],
      artifactLease: "lease-v1:patch:ART-review")
  }

  func appliedPatchReadback(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessAppliedPatchReadback {
    HarnessAppliedPatchReadback(
      patchAttemptRef: "patch-review", patchRevision: String(repeating: "b", count: 64))
  }

  func buildReadback(
    jobID: String, attempt: HarnessRepairAttempt, buildPresetRef: String,
    task: HarnessTaskSnapshot
  ) async throws -> HarnessBuildReadback {
    HarnessBuildReadback(
      sourceRevision: String(repeating: "b", count: 64),
      outputDigest: String(repeating: "c", count: 64),
      outputArtifactLease: "lease-v1:build:ART-BUILD")
  }

  func deployedArtifactDigest(jobID: String) async throws -> String {
    String(repeating: "c", count: 64)
  }

  func reconcileUnknownPatch(
    jobID: String, proposal: HarnessPatchProposal
  ) async throws -> HarnessPatchApplicationReadback { .stillUnknown }
}

private struct ReviewWorkspaceGrant: HarnessCapabilityPort {
  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    operationReference.hasPrefix("workspace.")
  }
  func standingCapabilityID(operationReference: String, targetID: String) async -> String? {
    operationReference.hasPrefix("workspace.") ? "CAP-RT-WORKSPACE-FIXTURE" : nil
  }
}

private final class ScriptedReviewer: HarnessAdversarialReviewing, @unchecked Sendable {
  enum Script {
    case verdict(HarnessAdversarialReviewVerdict, [HarnessReviewIssue])
    /// Violates the pass-means-no-issues consistency the coordinator checks.
    case passWithIssue
    /// Names a candidate the coordinator never asked about.
    case foreignCandidate
    case failTransport
  }

  let reviewerID = "scripted-reviewer@1"
  private let lock = NSLock()
  private let script: Script
  private var requests: [HarnessAdversarialReviewRequest] = []

  init(_ script: Script) { self.script = script }

  var receivedRequests: [HarnessAdversarialReviewRequest] { lock.withLock { requests } }

  func review(_ request: HarnessAdversarialReviewRequest) async throws
    -> HarnessAdversarialReview
  {
    lock.withLock { requests.append(request) }
    func review(
      _ result: HarnessAdversarialReviewVerdict,
      _ issues: [HarnessReviewIssue],
      candidatePatchID: String? = nil
    ) -> HarnessAdversarialReview {
      HarnessAdversarialReview(
        reviewID: "HREVIEW-SCRIPTED", reviewerID: reviewerID,
        candidatePatchID: candidatePatchID ?? request.candidatePatch.candidatePatchID,
        evaluationID: request.evaluation.evaluationID,
        result: result, issues: issues, createdAtUTC: reviewNow)
    }
    switch script {
    case .verdict(let result, let issues):
      return review(result, issues)
    case .passWithIssue:
      return review(.pass, [HarnessReviewIssue(severity: .low, description: "note")])
    case .foreignCandidate:
      return review(.pass, [], candidatePatchID: "candidate-other")
    case .failTransport:
      throw HarnessDecisionGatewayError.transportFailure("reviewerDown")
    }
  }
}

private final class RecordingCodexTransport: HarnessCodexTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let response: Data
  private var requests: [HarnessCodexProcessRequest] = []

  init(response: String) { self.response = Data(response.utf8) }

  var recorded: [HarnessCodexProcessRequest] { lock.withLock { requests } }

  func send(_ request: HarnessCodexProcessRequest) async throws -> Data {
    lock.withLock { requests.append(request) }
    return response
  }
}

// MARK: - Tests

final class HarnessEvolutionReviewContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-review-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: Coordinator leg

  func testEvaluationPassWithoutAReviewerStopsForHumanNotPromotion() async throws {
    let stack = try await makeReviewStack(reviewer: nil)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "adversarialReviewerUnavailable")
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
    let attempt = try await lastAttempt(stack)
    XCTAssertEqual(attempt.outcome, .humanRequired)
    XCTAssertNil(attempt.promotionCandidate)
  }

  func testEvaluationPassWithoutACandidatePatchStopsForHuman() async throws {
    let stack = try await makeReviewStack(
      reviewer: ScriptedReviewer(.verdict(.pass, [])), seedAttempt: false)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "candidatePatchUnavailableAtReview")
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
  }

  func testEvaluationPassWithoutTheImmutableDiffStopsForHuman() async throws {
    // The repair attempt on record carries a different diff than the one the
    // candidate metadata names: reviewing anything else would be dishonest.
    let stack = try await makeReviewStack(
      reviewer: ScriptedReviewer(.verdict(.pass, [])), repairDiffTampered: true)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "candidateDiffUnavailableAtReview")
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
  }

  func testExhaustedModelBudgetStopsReviewForHuman() async throws {
    let stack = try await makeReviewStack(
      reviewer: ScriptedReviewer(.verdict(.pass, [])),
      maxModelCalls: 1,
      consumedModelCalls: 1)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "adversarialReviewModelBudgetExhausted")
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
  }

  func testReviewerRejectKeepsTheEvolutionLoopAliveThroughItsOwedRollback() async throws {
    let reviewer = ScriptedReviewer(
      .verdict(.reject, [HarnessReviewIssue(severity: .high, description: "possible regression")]))
    let stack = try await makeReviewStack(reviewer: reviewer)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    // REJECT is a loop event, not a terminal one: the same wake records the
    // rejection, keeps the strategy Attempt active, and dispatches the owed
    // typed rollback under that identity - review FAIL never needs a human
    // to keep evolving.
    XCTAssertEqual(outcome.snapshot.noProgressRounds, 0)
    XCTAssertEqual(outcome.snapshot.repairAttempt?.rollbackRequired, true)
    let submitted = await stack.jobs.operations()
    XCTAssertEqual(submitted, ["workspace.revert-patch@1"])
    let attempt = try await lastAttempt(stack)
    XCTAssertEqual(attempt.outcome, .active)
    XCTAssertEqual(attempt.review?.result, .reject)
    XCTAssertNil(attempt.promotionCandidate)
    let events = try await stack.store.attemptEvents(stack.taskID)
    XCTAssertTrue(events.contains { $0.kind == .reviewRecorded })

    // The reviewer saw the immutable diff, not just metadata.
    XCTAssertEqual(reviewer.receivedRequests.count, 1)
    XCTAssertEqual(reviewer.receivedRequests.first?.unifiedDiff, stack.unifiedDiff)

    // The rollback readback closes the rejected strategy as reverted, so
    // duplicate-strategy admission refuses the same fingerprint while the
    // loop stays free to propose the next one. This synthetic stack has no
    // decision gateway to propose it, so only the Attempt-level facts are
    // the contract here.
    await stack.jobs.finish("JOB-NEXT-1")
    let reverted = try await stack.coordinator.reconcile(stack.taskID)
    XCTAssertEqual(reverted.snapshot.repairAttempt?.reverted, true)
    let closed = try await lastAttempt(stack)
    XCTAssertEqual(closed.outcome, .reverted)
    XCTAssertNil(closed.promotionCandidate)
  }

  func testReviewerCommentStopsForHumanDisposition() async throws {
    let stack = try await makeReviewStack(
      reviewer: ScriptedReviewer(
        .verdict(.comment, [HarnessReviewIssue(severity: .medium, description: "needs a look")])))
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertEqual(outcome.reasonCode, "adversarialReviewComment")
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
    let attempt = try await lastAttempt(stack)
    XCTAssertEqual(attempt.outcome, .humanRequired)
    XCTAssertEqual(attempt.review?.result, .comment)
    XCTAssertNil(attempt.promotionCandidate)
  }

  func testMalformedReviewsNeverPromoteAndStopForHuman() async throws {
    for script in [ScriptedReviewer.Script.passWithIssue, .foreignCandidate, .failTransport] {
      let stack = try await makeReviewStack(reviewer: ScriptedReviewer(script))
      let outcome = try await stack.coordinator.reconcile(stack.taskID)

      XCTAssertEqual(outcome.action, .stoppedForHuman)
      XCTAssertTrue(
        outcome.reasonCode.hasPrefix("adversarialReviewUnavailable:"),
        "unexpected reason \(outcome.reasonCode)")
      XCTAssertEqual(outcome.snapshot.status, .humanRequired)
      let attempt = try await lastAttempt(stack)
      XCTAssertNil(attempt.promotionCandidate)
    }
  }

  func testReviewerPassPromotesThroughTheGateAndSucceedsTheTask() async throws {
    let reviewer = ScriptedReviewer(.verdict(.pass, []))
    let stack = try await makeReviewStack(reviewer: reviewer)
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .evaluatedSucceeded)
    XCTAssertEqual(outcome.reasonCode, "promotionCandidateReady")
    XCTAssertEqual(outcome.snapshot.status, .succeeded)
    XCTAssertEqual(outcome.snapshot.result?.reasonCode, "promotionCandidateReady")

    let attempt = try await lastAttempt(stack)
    XCTAssertEqual(attempt.outcome, .succeeded)
    XCTAssertEqual(attempt.review?.result, .pass)
    let promotion = try XCTUnwrap(attempt.promotionCandidate)
    XCTAssertEqual(promotion.disposition, "READY_FOR_NORMAL_PR")
    XCTAssertEqual(promotion.candidatePatchID, stack.candidatePatchID)
    XCTAssertTrue(promotion.artifactIDs.contains("ART-DIFF"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-CANDIDATE"))
    XCTAssertTrue(promotion.artifactIDs.contains("ART-BUILD"))
    XCTAssertTrue(
      Set(outcome.snapshot.artifactRefs).isSuperset(of: Set(promotion.artifactIDs)),
      "the succeeded task must carry every promotion artifact reference")
    let events = try await stack.store.attemptEvents(stack.taskID)
    XCTAssertEqual(
      events.map(\.kind).suffix(3), [.reviewRecorded, .promotionRecorded, .closed])
  }

  func testStaleWorkspaceAtReviewTimeRefusesPromotion() async throws {
    // The tree moved after the evaluated build: the gate's live-revision
    // recheck must refuse, because the promoted diff would not be the tree.
    let stack = try await makeReviewStack(
      reviewer: ScriptedReviewer(.verdict(.pass, [])),
      liveRevisionOverride: String(repeating: "e", count: 64))
    let outcome = try await stack.coordinator.reconcile(stack.taskID)

    XCTAssertEqual(outcome.action, .stoppedForHuman)
    XCTAssertTrue(outcome.reasonCode.hasPrefix("promotionGateRejected:"))
    XCTAssertEqual(outcome.snapshot.status, .humanRequired)
    let attempt = try await lastAttempt(stack)
    XCTAssertNil(attempt.promotionCandidate)
  }

  // MARK: Codex adapter

  func testCodexReviewerParsesAClosedPassVerdictAndBindsIdentityFromTheRequest() async throws {
    let transport = RecordingCodexTransport(response: #"{"result":"PASS","issues":[]}"#)
    let reviewer = try makeCodexReviewer(transport: transport)
    let request = try adapterRequest()

    let review = try await reviewer.review(request)

    XCTAssertEqual(review.result, .pass)
    XCTAssertTrue(review.issues.isEmpty)
    XCTAssertEqual(review.reviewerID, reviewer.reviewerID)
    XCTAssertTrue(review.reviewID.hasPrefix("HREVIEW-"))
    XCTAssertEqual(review.candidatePatchID, request.candidatePatch.candidatePatchID)
    XCTAssertEqual(review.evaluationID, request.evaluation.evaluationID)

    let sent = try XCTUnwrap(transport.recorded.first)
    XCTAssertTrue(sent.arguments.contains("--ephemeral"))
    XCTAssertEqual(
      sent.arguments.firstIndex(of: "--sandbox").map { sent.arguments[$0 + 1] }, "read-only")
    let prompt = try XCTUnwrap(sent.arguments.last)
    XCTAssertTrue(prompt.contains(request.unifiedDiff))
    XCTAssertTrue(prompt.contains(request.originalProblem))
  }

  func testCodexReviewerParsesRejectIssuesAndRefusesEveryOpenShape() async throws {
    let reject = RecordingCodexTransport(
      response: #"{"result":"REJECT","issues":[{"severity":"HIGH","description":"regression"}]}"#)
    let rejected = try await makeCodexReviewer(transport: reject).review(adapterRequest())
    XCTAssertEqual(rejected.result, .reject)
    XCTAssertEqual(rejected.issues, [HarnessReviewIssue(severity: .high, description: "regression")])

    let malformed: [(String, CodexHarnessAdversarialReviewError)] = [
      ("not json", .responseShape),
      (#"{"result":"PASS","issues":[],"extra":1}"#, .responseShape),
      (#"{"result":"MAYBE","issues":[]}"#, .responseShape),
      (#"{"result":"PASS","issues":[{"severity":"HIGH","description":"x"}]}"#,
       .verdictIssueConsistency),
      (#"{"result":"REJECT","issues":[]}"#, .verdictIssueConsistency),
      (#"{"result":"COMMENT","issues":[]}"#, .verdictIssueConsistency),
      (#"{"result":"REJECT","issues":[{"severity":"SEVERE","description":"x"}]}"#, .issueShape),
      (#"{"result":"REJECT","issues":[{"severity":"HIGH","description":"  "}]}"#, .issueShape),
      (#"{"result":"REJECT","issues":[{"severity":"HIGH","description":"x","code":"C"}]}"#,
       .issueShape),
    ]
    for (response, expected) in malformed {
      let reviewer = try makeCodexReviewer(transport: RecordingCodexTransport(response: response))
      do {
        _ = try await reviewer.review(adapterRequest())
        XCTFail("response \(response) must be refused")
      } catch let error as CodexHarnessAdversarialReviewError {
        XCTAssertEqual(error, expected, "response \(response)")
      }
    }
  }

  func testCodexReviewerRefusesOversizedOrMismatchedDiffBeforeAnyModelCall() async throws {
    let transport = RecordingCodexTransport(response: #"{"result":"PASS","issues":[]}"#)
    let reviewer = try makeCodexReviewer(transport: transport)

    let oversized = try adapterRequest(
      diffOverride: String(
        repeating: "x", count: CodexHarnessAdversarialReviewer.maximumReviewDiffBytes + 1))
    do {
      _ = try await reviewer.review(oversized)
      XCTFail("an oversized diff cannot claim to have been reviewed")
    } catch let error as CodexHarnessAdversarialReviewError {
      guard case .diffTooLarge = error else { return XCTFail("unexpected \(error)") }
    }

    let mismatched = try adapterRequest(diffOverride: "diff --git a/x b/x\n")
    do {
      _ = try await reviewer.review(mismatched)
      XCTFail("a diff that does not hash to the candidate digest is not the candidate")
    } catch let error as CodexHarnessAdversarialReviewError {
      XCTAssertEqual(error, .requestIntegrity)
    }

    XCTAssertTrue(transport.recorded.isEmpty, "no model call may precede integrity checks")
  }

  // MARK: Environment composition

  func testReviewerCompositionIsExplicitClosedAndFailClosed() throws {
    XCTAssertNil(try HarnessVendorConfiguration.adversarialReviewer(environment: [:]))

    XCTAssertThrowsError(
      try HarnessVendorConfiguration.adversarialReviewer(environment: [
        HarnessVendorConfiguration.reviewerModelKey: "some-model"
      ])
    ) { error in
      XCTAssertEqual(error as? HarnessVendorConfigurationError, .providerRequired)
    }

    XCTAssertThrowsError(
      try HarnessVendorConfiguration.adversarialReviewer(environment: [
        HarnessVendorConfiguration.reviewerProviderKey: "claude"
      ])
    ) { error in
      XCTAssertEqual(
        error as? HarnessVendorConfigurationError, .unsupportedProvider("claude"))
    }

    XCTAssertThrowsError(
      try HarnessVendorConfiguration.adversarialReviewer(environment: [
        HarnessVendorConfiguration.reviewerProviderKey: "codex",
        HarnessVendorConfiguration.reviewerModelKey: "some-model",
        HarnessVendorConfiguration.reviewerCodexPathKey: "/usr/bin/true",
      ])
    ) { error in
      XCTAssertEqual(
        error as? HarnessVendorConfigurationError, .missingCodexWorkingDirectory)
    }

    let reviewer = try HarnessVendorConfiguration.adversarialReviewer(environment: [
      HarnessVendorConfiguration.reviewerProviderKey: "codex",
      HarnessVendorConfiguration.reviewerModelKey: "some-model",
      HarnessVendorConfiguration.reviewerCodexPathKey: "/usr/bin/true",
      HarnessVendorConfiguration.reviewerCodexWorkingDirectoryKey: rootURL.path,
    ])
    XCTAssertTrue(
      try XCTUnwrap(reviewer).reviewerID.hasPrefix("codex-harness-adversarial-reviewer@1:"))
  }

  // MARK: - Stack builder

  private struct ReviewStack {
    let coordinator: HarnessTaskCoordinator
    let store: HarnessTaskStore
    let jobs: ReviewJobPort
    let taskID: String
    let candidatePatchID: String
    let unifiedDiff: String
  }

  private func lastAttempt(_ stack: ReviewStack) async throws -> HarnessAttempt {
    let attempts = try await stack.store.attempts(stack.taskID)
    return try XCTUnwrap(attempts.last)
  }

  /// Seeds one Evolution task at the exact moment its verification capture
  /// job finished: reconciling once observes the job, evaluates the staged
  /// evidence to a PASS and enters the review leg.
  private func makeReviewStack(
    reviewer: (any HarnessAdversarialReviewing)?,
    seedAttempt: Bool = true,
    repairDiffTampered: Bool = false,
    liveRevisionOverride: String? = nil,
    maxModelCalls: Int = 24,
    consumedModelCalls: Int = 0
  ) async throws -> ReviewStack {
    let taskID = "HTASK-0123456789AB"
    let attemptID = "ATTEMPT-0123456789AB"
    let jobID = "JOB-VERIFY"
    let diff = """
      diff --git a/Sources/App.txt b/Sources/App.txt
      --- a/Sources/App.txt
      +++ b/Sources/App.txt
      @@ -1 +1 @@
      -old
      +new

      """
    let base = String(repeating: "a", count: 64)
    let patchRevision = String(repeating: "b", count: 64)
    let buildDigest = String(repeating: "c", count: 64)
    let diffDigest = SHA256.hash(data: Data(diff.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let proposal = try HarnessPatchProposal(
      baseWorkspaceRevision: base, patchSHA256: diffDigest, unifiedDiff: diff,
      touchedFiles: ["Sources/App.txt"], expectedChangedSymbols: ["App"])
    let evolutionPolicy = try HarnessEvolutionPolicy(
      baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 4,
      maxChangedFiles: 4, maxDiffLines: 50,
      allowedOperations: [
        "workspace.apply-patch@1", "workspace.build-openharmony@1",
        "workspace.run-tests@1", "workspace.revert-patch@1", "debug.hap@1",
      ])
    let candidate = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: "ART-DIFF", htaskID: taskID,
      attemptID: attemptID, createdBy: .agent, createdAtUTC: reviewNow
    ).recordingMetadataArtifact("ART-CANDIDATE")
    let tamperedDiff = """
      diff --git a/Sources/App.txt b/Sources/App.txt
      --- a/Sources/App.txt
      +++ b/Sources/App.txt
      @@ -1 +1 @@
      -old
      +tampered

      """
    let repair = HarnessRepairAttempt(
      proposal: repairDiffTampered
        ? try HarnessPatchProposal(
          baseWorkspaceRevision: base,
          patchSHA256: SHA256.hash(data: Data(tamperedDiff.utf8))
            .map { String(format: "%02x", $0) }.joined(),
          unifiedDiff: tamperedDiff,
          touchedFiles: ["Sources/App.txt"], expectedChangedSymbols: ["App"])
        : proposal,
      patchAttemptRef: "patch-review", patchRevision: patchRevision,
      buildSourceRevision: patchRevision, buildOutputDigest: buildDigest,
      buildOutputArtifactLease: "lease-v1:build:ART-BUILD", testsPassed: true,
      deployedDigest: buildDigest)
    var observed = HarnessObservedState(
      measurements: [HarnessObservationBuilder.watermarkMetric: .string("")],
      latestVerdict: .fail
    ).asJSON
    observed[HarnessRepairAttempt.observedStateKey] = repair.json
    let snapshot = HarnessTaskSnapshot(
      htaskID: taskID, type: .debugCrash, intakeDescription: nil,
      projectRef: "TestProject",
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(
        summary: "No WaterFlow SIGABRT across runs",
        desiredState: [
          "crashSignature": .string("SIGABRT+WaterFlowPattern::RecoverBack"),
          "baseWorkspaceRevision": .string(base),
        ]),
      successCriteria: [
        HarnessSuccessCriterion(
          criterionID: "DC-1", metric: "matchingCrashCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 1,
          evidenceRequirements: ["crash-index.txt"]),
        HarnessSuccessCriterion(
          criterionID: "DC-2", metric: "newFatalSignatureCount", comparator: .equalTo,
          expected: .integer(0), minimumSamples: 1,
          evidenceRequirements: ["crash-index.txt"]),
      ],
      budgets: HarnessTaskBudgets(
        maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 8, maxModelCalls: maxModelCalls),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
      evolutionPolicy: evolutionPolicy,
      evolutionWorkspace: HarnessEvolutionWorkspace(
        workspaceID: "evo-review", htaskID: taskID, sourceProjectRef: "TestProject",
        projectRef: "evolution-review", baseRevision: base,
        allowedPathsDigest: String(repeating: "d", count: 64), createdAtUTC: reviewNow),
      observedState: observed, createdAtUTC: reviewNow, updatedAtUTC: reviewNow,
      status: .running, phase: .verifying, activeRound: 1, activeJobID: jobID,
      consumedBudget: HarnessConsumedBudget(rounds: 1, modelCalls: consumedModelCalls))

    let storeRoot = rootURL.appendingPathComponent(
      UUID().uuidString.lowercased(), isDirectory: true)
    let store = try HarnessTaskStore(rootURL: storeRoot)
    try await store.create(snapshot)
    let decision = HarnessDecision(
      decisionID: "dec-verify", htaskID: taskID, round: 1, kind: .invokeOperation,
      operationReference: DebugCrashTaskHandler.captureDiagnostics,
      inputs: [:], hypothesis: "verify", reasonCode: "verificationCapture",
      producer: "review-fixture", createdAtUTC: reviewNow)
    try await store.putDecision(decision)
    try await store.putIntent(
      HarnessDispatchIntent(
        htaskID: taskID, round: 1, decisionID: decision.decisionID,
        operationReference: DebugCrashTaskHandler.captureDiagnostics,
        targetID: "TGT-1", expectedBindingRevision: nil,
        inputsDigestSHA256: HarnessRequestIdentity.inputsDigest(decision.inputs),
        requestID: "req-review", idempotencyKey: "idem-review", state: .linked,
        jobID: jobID, createdAtUTC: reviewNow, updatedAtUTC: reviewNow))
    if seedAttempt {
      let strategy = try HarnessStrategyDescriptor(
        hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
        patchFingerprint: proposal.patchSHA256, baseWorkspaceRevision: base,
        artifactSourceSet: [], prerequisiteSet: [],
        executionExpectation: HarnessStrategyExecutionExpectation(
          targetProfile: "device-profile", toolchainProfile: "build-ok",
          expectedNextObservation: "no-crash"))
      let attempt = HarnessAttempt(
        attemptID: attemptID, htaskID: taskID, ordinal: 1,
        hypothesis: "Fix the measured failure", strategy: strategy,
        patchRevision: patchRevision, candidatePatch: candidate,
        buildArtifactIDs: ["ART-BUILD"],
        createdAtUTC: reviewNow, updatedAtUTC: reviewNow)
      try await store.recordAttempt(attempt, kind: .created, reasonCode: "strategyAccepted")
    }

    let artifacts = ReviewArtifactPort()
    artifacts.stage(jobID: jobID, name: "crash-index.txt", text: emptyCrashIndex)
    let jobs = ReviewJobPort(observations: [
      jobID: HarnessJobObservation(
        jobID: jobID, state: "succeeded", isTerminal: true, succeeded: true,
        outcomeUnknown: false, waitingForHuman: false, timeline: ["succeeded"])
    ])
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, artifactPort: artifacts,
      repairPort: ReviewRepairPort(liveRevisionOverride: liveRevisionOverride),
      adversarialReviewer: reviewer,
      nowUTC: { reviewNow },
      policyGuard: HarnessPolicyGuard(capabilities: ReviewWorkspaceGrant()))
    return ReviewStack(
      coordinator: coordinator, store: store, jobs: jobs, taskID: taskID,
      candidatePatchID: candidate.candidatePatchID, unifiedDiff: diff)
  }

  // MARK: - Adapter fixtures

  private func makeCodexReviewer(
    transport: RecordingCodexTransport
  ) throws -> CodexHarnessAdversarialReviewer {
    try CodexHarnessAdversarialReviewer(
      executablePath: "/usr/bin/true", modelName: "review-model",
      workingDirectory: rootURL.path, transport: transport,
      nowUTC: { reviewNow })
  }

  private func adapterRequest(diffOverride: String? = nil) throws
    -> HarnessAdversarialReviewRequest
  {
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
    let base = String(repeating: "a", count: 64)
    let proposal = try HarnessPatchProposal(
      baseWorkspaceRevision: base, patchSHA256: digest, unifiedDiff: diff,
      touchedFiles: ["Sources/App.txt"], expectedChangedSymbols: ["App"])
    let candidate = HarnessCandidatePatch.create(
      proposal: proposal, diffArtifactID: "ART-DIFF", htaskID: "HTASK-0123456789AB",
      attemptID: "ATTEMPT-0123456789AB", createdBy: .agent, createdAtUTC: reviewNow
    ).recordingMetadataArtifact("ART-CANDIDATE")
    let strategy = try HarnessStrategyDescriptor(
      hypothesisClass: "repair", selectedOperationFamily: "workspace.apply-patch",
      patchFingerprint: proposal.patchSHA256, baseWorkspaceRevision: base,
      artifactSourceSet: [], prerequisiteSet: [],
      executionExpectation: HarnessStrategyExecutionExpectation(
        targetProfile: "device-profile", toolchainProfile: "build-ok",
        expectedNextObservation: "no-crash"))
    let attempt = HarnessAttempt(
      attemptID: "ATTEMPT-0123456789AB", htaskID: "HTASK-0123456789AB", ordinal: 1,
      hypothesis: "Fix the measured failure", strategy: strategy,
      createdAtUTC: reviewNow, updatedAtUTC: reviewNow)
    let evaluation = HarnessEvaluation(
      evaluationID: "EVAL-0123456789AB", htaskID: "HTASK-0123456789AB", round: 3,
      verdict: .pass,
      criterionResults: [
        HarnessCriterionResult(
          criterionID: "DC-1", verdict: .pass, metric: "matchingCrashCount",
          observed: .integer(0), expected: .integer(0), samples: 1,
          requiredSamples: 1, blockers: [])
      ], measurements: ["matchingCrashCount": .integer(0)],
      samples: ["matchingCrashCount": 1],
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-RUNTIME", name: "crash-index.txt", byteCount: 10,
          sha256: String(repeating: "e", count: 64), verified: true)
      ], blockers: [], createdAtUTC: reviewNow)
    return HarnessAdversarialReviewRequest(
      originalProblem: "No WaterFlow SIGABRT across runs",
      candidatePatch: candidate,
      unifiedDiff: diffOverride ?? diff,
      attemptHistory: [attempt],
      evaluation: evaluation,
      artifactIDs: ["ART-BUILD", "ART-RUNTIME"])
  }
}
