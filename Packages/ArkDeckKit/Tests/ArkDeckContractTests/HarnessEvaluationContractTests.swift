// Evaluation contract tests (CHG-2026-054, TASK-HTP-002).
//
// Registered acceptance: HTP-AC-5 (only the evaluator may declare success),
// HTP-AC-6 (INCONCLUSIVE is never success), HTP-AC-7 (observations come from
// bytes the harness verified, and absent/corrupt evidence fails closed).
//
// The hilog fixtures are host-authored in the documented OpenHarmony
// cppcrash shape, and the run record says so: validating the scan against
// bytes a real device produced belongs to the hardware task. What is proven
// here is everything that does not need a device - verification before
// measurement, the sample gate, and who is allowed to say "fixed".

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum HilogFixture {
  /// One matching fault (the declared WaterFlow signature) and one unrelated
  /// fatal, so "matching" and "new fatal" cannot be conflated.
  static let twoFaults = """
    07-30 12:00:01.100  1201  1201 I A03d00/Ace: WaterFlow layout pass begin
    07-30 12:00:02.310  1201  1201 E C03f00/Cppcrash: Pid:1201 Uid:20010043
    Process name:com.example.waterflow
    Reason:Signal:SIGABRT(SI_TKILL)@0x0000000000000004
    Fault thread info:
    Tid:1201, Name:e.example.water
    #00 pc 00000000000a1b2c /system/lib64/libc.so(abort+164)
    #01 pc 00000000000d4e5f /system/lib64/libace_compatible.z.so(OHOS::Ace::NG::WaterFlowPattern::RecoverBack()+72)
    #02 pc 00000000000d9a11 /system/lib64/libace_compatible.z.so(OHOS::Ace::NG::ScrollablePattern::OnScrollEnd()+40)
    07-30 12:00:05.900  1330  1330 E C03f00/Cppcrash: Pid:1330 Uid:20010044
    Process name:com.example.other
    Reason:Signal:SIGSEGV(SEGV_MAPERR)@0x0000000000000010
    Fault thread info:
    #00 pc 0000000000012345 /system/lib64/libunrelated.z.so(OtherModule::Boom()+16)
    """

  static let clean = """
    07-30 12:10:01.100  1401  1401 I A03d00/Ace: WaterFlow layout pass begin
    07-30 12:10:01.480  1401  1401 I A03d00/Ace: WaterFlow reached end of content
    07-30 12:10:02.010  1401  1401 I A03d00/Ace: scroll settled, no recovery needed
    """

  static let declaredSignature = "SIGABRT+WaterFlowPattern::RecoverBack"
}

private struct StagedArtifact {
  let descriptor: HarnessArtifactDescriptor
  let bytes: Data
}

private final class StagingArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private let lock = NSLock()
  private var staged: [String: [StagedArtifact]] = [:]
  private var reads: [String] = []
  var inventoryFailure: String?

  var readArtifactIDs: [String] { lock.withLock { reads } }

  func stage(
    jobID: String,
    name: String,
    text: String? = nil,
    bytes: Data? = nil,
    published: Bool = true,
    sensitive: Bool = false,
    sha256Override: String? = nil,
    byteCountOverride: Int? = nil,
    missingReason: String? = nil,
    mediaType: String = "text/plain"
  ) {
    let data = bytes ?? Data((text ?? "").utf8)
    let descriptor = HarnessArtifactDescriptor(
      artifactID: "ART-\(jobID)-\(name)",
      name: name,
      mediaType: mediaType,
      byteCount: byteCountOverride ?? data.count,
      sha256: sha256Override ?? sha256Hex(data),
      published: published,
      sensitive: sensitive,
      missingReason: missingReason)
    lock.withLock { staged[jobID, default: []].append(StagedArtifact(descriptor: descriptor, bytes: data)) }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    try lock.withLock {
      if let inventoryFailure {
        throw HarnessArtifactPortError.unavailable(inventoryFailure)
      }
      return (staged[jobID] ?? []).map(\.descriptor)
    }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      guard let match = (staged[jobID] ?? []).first(where: { $0.descriptor.artifactID == artifactID })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      reads.append(artifactID)
      return match.bytes.prefix(maximumBytes)
    }
  }
}

private final class ScriptedJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: HarnessJobObservation] = [:]
  private var submissions: [String] = []
  private var nextOrdinal = 1

  var submittedOperations: [String] { lock.withLock { submissions } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    return lock.withLock {
      let jobID = "JOB-\(nextOrdinal)"
      nextOrdinal += 1
      submissions.append(request.operation.reference)
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
        outcomeUnknown: false, waitingForHuman: false,
        timeline: ["queued", "running", state])
    }
  }
}

final class HarnessEvaluationContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-eval-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - HTP-AC-7: observations come from verified bytes

  func testMeasurementsComeFromVerifiedBytes() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.twoFaults)
    port.stage(jobID: "JOB-1", name: "ui-dump.json", text: "{\"windows\":[]}")
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: HilogFixture.declaredSignature,
      requiredEvidence: ["hilog.txt"])

    XCTAssertEqual(observation.measurements["matchingCrashCount"], .integer(1))
    XCTAssertEqual(observation.measurements["newFatalSignatureCount"], .integer(1))
    XCTAssertEqual(observation.measurements["verificationRunCount"], .integer(1))
    XCTAssertEqual(observation.measurements["applicationLiveness"], .string("unhealthy"))
    if case .string(let signature)? = observation.measurements["latestCrashSignature"] {
      XCTAssertTrue(signature.hasPrefix("SIGSEGV"), "latest fault is the unrelated one")
    } else {
      XCTFail("a fault block must yield a signature")
    }
    XCTAssertEqual(observation.integrityBlockers, [])
    XCTAssertEqual(observation.collectionBlockers, [])
    XCTAssertEqual(observation.verifiedEvidenceNames, ["hilog.txt", "ui-dump.json"])
    XCTAssertEqual(observation.sampleContribution["matchingCrashCount"], 1)
  }

  func testCleanLogMeasuresHealthyAndZeroCounts() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: HilogFixture.declaredSignature,
      requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.measurements["matchingCrashCount"], .integer(0))
    XCTAssertEqual(observation.measurements["newFatalSignatureCount"], .integer(0))
    XCTAssertEqual(observation.measurements["applicationLiveness"], .string("healthy"))
    XCTAssertNil(observation.measurements["latestCrashSignature"])
  }

  func testHashMismatchIsAnIntegrityBlockerAndYieldsNoMeasurement() async throws {
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean,
      sha256Override: String(repeating: "0", count: 64))
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.integrityBlockers, ["artifactHashMismatch:hilog.txt"])
    XCTAssertTrue(
      observation.measurements.isEmpty,
      "bytes that did not verify must not produce a measurement in either direction")
    XCTAssertEqual(observation.evidence.first?.verified, false)
  }

  func testAbsentEmptyOversizeAndSensitiveEvidenceAreCollectionBlockers() async throws {
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-1", name: "hilog.txt", text: "", published: false,
      missingReason: "upstreamCaptureFailed")
    port.stage(jobID: "JOB-2", name: "hilog.txt", text: "")
    port.stage(jobID: "JOB-3", name: "hilog.txt", text: HilogFixture.clean)
    port.stage(jobID: "JOB-4", name: "hilog.txt", text: HilogFixture.clean, sensitive: true)
    let builder = HarnessObservationBuilder(artifacts: port, maximumEvaluationBytes: 16)

    let missing = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(
      missing.collectionBlockers, ["artifactMissing:hilog.txt:upstreamCaptureFailed"])

    let empty = try await builder.observe(
      round: 1, jobID: "JOB-2", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(empty.collectionBlockers, ["artifactEmpty:hilog.txt"])

    let oversize = try await builder.observe(
      round: 1, jobID: "JOB-3", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(oversize.collectionBlockers.count, 1)
    XCTAssertTrue(
      oversize.collectionBlockers[0].hasPrefix("artifactExceedsEvaluationBound:hilog.txt"),
      "a hash over a truncated prefix proves nothing, so oversize evidence is a blocker")
    XCTAssertTrue(oversize.measurements.isEmpty)

    let sensitive = try await builder.observe(
      round: 1, jobID: "JOB-4", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(sensitive.collectionBlockers, ["artifactSensitiveNotOptedIn:hilog.txt"])
    XCTAssertEqual(port.readArtifactIDs.filter { $0.contains("JOB-4") }, [])
  }

  func testRequiredEvidenceThatWasNeverCollectedIsABlocker() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "ui-dump.json", text: "{\"windows\":[]}")
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.collectionBlockers, ["artifactNotCollected:hilog.txt"])
  }

  func testUnavailableInventoryIsABlockerNotAnEmptyObservation() async throws {
    let port = StagingArtifactPort()
    port.inventoryFailure = "artifact store unavailable"
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.collectionBlockers, ["artifactInventoryUnavailable:JOB-1"])
    XCTAssertTrue(observation.measurements.isEmpty)
  }

  // MARK: - Evaluator semantics (HTP-AC-5, HTP-AC-6)

  private func criterion(
    _ id: String,
    metric: String,
    comparator: HarnessCriterionComparator = .equalTo,
    expected: JSONValue,
    mandatory: Bool = true,
    minimumSamples: Int = 1,
    evidence: [String] = ["hilog.txt"],
    policy: HarnessInconclusivePolicy = .collectMoreEvidence
  ) -> HarnessSuccessCriterion {
    HarnessSuccessCriterion(
      criterionID: id, metric: metric, comparator: comparator, expected: expected,
      mandatory: mandatory, minimumSamples: minimumSamples, evidenceRequirements: evidence,
      inconclusivePolicy: policy)
  }

  func testNoMandatoryCriterionIsInconclusiveNotPass() {
    let observation = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "hilog.txt", byteCount: 10, sha256: "abc", verified: true)
      ])
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion("OPT-1", metric: "matchingCrashCount", expected: .integer(0), mandatory: false)
      ],
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 9]),
      round: observation, evaluationID: "EVAL-000000000001", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(
      evaluation.verdict, .inconclusive,
      "nothing mandatory to check is not a fix")
  }

  func testSampleGateAndIntegrityDominateTheVerdict() {
    let verified = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "hilog.txt", byteCount: 10, sha256: "abc", verified: true)
      ])
    let criteria = [criterion("DC-1", metric: "matchingCrashCount", expected: .integer(0), minimumSamples: 5)]

    let short = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 2]),
      round: verified, evaluationID: "EVAL-000000000002", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(short.verdict, .inconclusive)
    XCTAssertEqual(short.criterionResults[0].blockers, ["insufficientSamples:2/5"])

    let enough = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 5]),
      round: verified, evaluationID: "EVAL-000000000003", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(enough.verdict, .pass)

    let corrupt = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "hilog.txt", byteCount: 10, sha256: "abc", verified: false,
          blocker: "artifactHashMismatch:hilog.txt")
      ],
      integrityBlockers: ["artifactHashMismatch:hilog.txt"])
    let unverifiable = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 5]),
      round: corrupt, evaluationID: "EVAL-000000000004", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(
      unverifiable.verdict, .error,
      "a hash mismatch is 'we cannot tell', never 'the criteria passed'")
  }

  func testComparatorsAndEscalationSelection() {
    let verified = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "hilog.txt", byteCount: 10, sha256: "abc", verified: true)
      ])
    let observed = HarnessObservedState(
      measurements: [
        "frameTimeP95": .number(21.5),
        "fps": .integer(58),
        "latestCrashSignature": .string("SIGABRT+WaterFlowPattern::RecoverBack"),
        "newFatalSignatureCount": .integer(0),
      ],
      samples: [
        "frameTimeP95": 3, "fps": 3, "latestCrashSignature": 1, "newFatalSignatureCount": 1,
      ])
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion("C-atMost", metric: "frameTimeP95", comparator: .atMost, expected: .number(24)),
        criterion("C-atLeast", metric: "fps", comparator: .atLeast, expected: .integer(55)),
        criterion(
          "C-matches", metric: "latestCrashSignature", comparator: .matches,
          expected: .string("RecoverBack")),
        criterion(
          "C-absent", metric: "newFatalSignatureCount", comparator: .absent, expected: .null),
      ],
      observed: observed, round: verified, evaluationID: "EVAL-000000000005",
      htaskID: "HTASK-0123456789AB", nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(evaluation.verdict, .pass)

    let mixed = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion(
          "C-human", metric: "unobserved", expected: .integer(0), policy: .requestHuman),
        criterion(
          "C-collect", metric: "alsoUnobserved", expected: .integer(0),
          policy: .collectMoreEvidence),
      ],
      observed: observed, round: verified, evaluationID: "EVAL-000000000006",
      htaskID: "HTASK-0123456789AB", nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(mixed.verdict, .inconclusive)
    XCTAssertEqual(
      HarnessCriteriaEvaluator.escalation(
        for: mixed,
        criteria: [
          criterion("C-human", metric: "unobserved", expected: .integer(0), policy: .requestHuman),
          criterion(
            "C-collect", metric: "alsoUnobserved", expected: .integer(0),
            policy: .collectMoreEvidence),
        ]),
      .requestHuman,
      "one criterion needing a human is not diluted by another that wants more evidence")
  }

  func testObservedStateAccumulatesCountersAndReplacesLatestValues() {
    var state = HarnessObservedState()
    state = state.merging(
      HarnessRoundObservation(
        round: 1,
        measurements: [
          "matchingCrashCount": .integer(1), "applicationLiveness": .string("unhealthy"),
        ],
        sampleContribution: ["matchingCrashCount": 1, "applicationLiveness": 1]))
    state = state.merging(
      HarnessRoundObservation(
        round: 2,
        measurements: [
          "matchingCrashCount": .integer(2), "applicationLiveness": .string("healthy"),
        ],
        sampleContribution: ["matchingCrashCount": 1, "applicationLiveness": 1]))
    XCTAssertEqual(state.measurements["matchingCrashCount"], .integer(3))
    XCTAssertEqual(state.measurements["applicationLiveness"], .string("healthy"))
    XCTAssertEqual(state.samples["matchingCrashCount"], 2)
    // Round trip through the snapshot's free-form observed state.
    XCTAssertEqual(HarnessObservedState(json: state.asJSON), state)
  }

  func testObservedStateCannotBeWrittenWithoutEvidence() throws {
    let snapshot = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil, projectRef: nil,
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "goal"), successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: ["observe.device@1"]),
      createdAtUTC: "2026-07-30T00:00:00Z", updatedAtUTC: "2026-07-30T00:00:00Z",
      status: .humanRequired, phase: .collecting)
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        HarnessTaskTransition(
          causation: .humanResolved, reasonCode: "operator says it is fixed", status: .running,
          phase: .collecting, activeRound: 0, activeJobID: nil,
          consumedBudget: HarnessConsumedBudget(),
          observedState: ["measurements": .object(["matchingCrashCount": .integer(0)])],
          atUTC: "2026-07-30T00:01:00Z"),
        to: snapshot)
    ) { error in
      XCTAssertEqual(
        error as? HarnessTaskTransitionError,
        .observedStateRequiresEvidence(.humanResolved))
    }
  }

  // MARK: - End to end through the coordinator

  private func makeStack(
    artifacts: StagingArtifactPort,
    jobs: ScriptedJobPort,
    maxRounds: Int = 8,
    minimumSamples: Int = 2
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, artifactPort: artifacts,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let submission = HarnessTaskSubmission(
      type: .debugCrash,
      target: HarnessTaskTargetReference(targetID: "TGT-958780b2ffb7"),
      goal: HarnessTaskGoal(
        summary: "No WaterFlow SIGABRT across runs",
        desiredState: ["crashSignature": .string(HilogFixture.declaredSignature)]),
      successCriteria: [
        criterion(
          "DC-1", metric: "matchingCrashCount", expected: .integer(0),
          minimumSamples: minimumSamples),
        criterion("DC-2", metric: "newFatalSignatureCount", expected: .integer(0)),
      ],
      budgets: HarnessTaskBudgets(
        maxRounds: maxRounds, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, store, submission)
  }

  func testSuccessIsReachableOnlyThroughAPassingEvaluation() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, store, submission) = try makeStack(artifacts: artifacts, jobs: jobs)
    let task = try await coordinator.submit(submission)

    // Round 1: observe.device publishes no hilog, so nothing is decidable.
    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    let afterObserve = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(afterObserve.action, .dispatched)
    XCTAssertEqual(afterObserve.snapshot.observed.latestVerdict, .inconclusive)

    // Round 2: a clean capture - one sample, still short of the two required.
    artifacts.stage(jobID: "JOB-2", name: "hilog.txt", text: HilogFixture.clean)
    jobs.finish("JOB-2")
    let firstSample = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(firstSample.action, .dispatched, "an inconclusive verdict buys another round")
    XCTAssertEqual(firstSample.snapshot.status, .running)
    XCTAssertEqual(firstSample.snapshot.observed.samples["matchingCrashCount"], 1)

    // Round 3: the second clean sample satisfies both criteria.
    artifacts.stage(jobID: "JOB-3", name: "hilog.txt", text: HilogFixture.clean)
    jobs.finish("JOB-3")
    let succeeded = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(succeeded.action, .evaluatedSucceeded)
    XCTAssertEqual(succeeded.snapshot.status, .succeeded)
    let evaluationID = try XCTUnwrap(succeeded.snapshot.latestEvaluationID)
    XCTAssertEqual(succeeded.snapshot.result?.evaluationID, evaluationID)
    XCTAssertEqual(succeeded.snapshot.result?.reasonCode, "criteriaPassed")

    // The verdict is a durable record, not a phrase in a summary.
    let loaded = try await store.evaluation(task.htaskID, evaluationID: evaluationID)
    let stored = try XCTUnwrap(loaded)
    XCTAssertEqual(stored.verdict, .pass)
    XCTAssertEqual(stored.criterionResults.map(\.verdict), [.pass, .pass])
    XCTAssertTrue(stored.evidence.contains { $0.name == "hilog.txt" && $0.verified })

    // Only an evaluation causation may carry the task into succeeded.
    let events = try await coordinator.events(task.htaskID)
    let terminal = try XCTUnwrap(events.last)
    XCTAssertEqual(terminal.causation, .evaluation)
    XCTAssertEqual(terminal.toStatus, .succeeded)
    XCTAssertEqual(terminal.evaluationID, evaluationID)
    XCTAssertEqual(
      events.filter { $0.toStatus == .succeeded }.map(\.causation), [.evaluation],
      "no other causation ever reaches succeeded")
  }

  func testAFailingCriterionHandsTheVerdictToAHumanAndNeverSucceeds() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, store, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, minimumSamples: 1)
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)
    // The capture still shows the declared crash.
    artifacts.stage(jobID: "JOB-2", name: "hilog.txt", text: HilogFixture.twoFaults)
    jobs.finish("JOB-2")

    let failed = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(failed.snapshot.observed.latestVerdict, .fail)
    XCTAssertEqual(failed.snapshot.observed.measurements["matchingCrashCount"], .integer(1))
    XCTAssertEqual(failed.action, .stoppedForHuman)
    XCTAssertEqual(failed.reasonCode, "criteriaFailedNoRepairCapability")
    XCTAssertEqual(failed.snapshot.status, .humanRequired)
    XCTAssertNotEqual(failed.snapshot.status, .succeeded)

    let evaluations = try await store.evaluations(task.htaskID)
    XCTAssertEqual(evaluations.last?.verdict, .fail)
  }

  func testInconclusiveNeverSucceedsAndTheBudgetStopsTheLoop() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    // Five samples required, three rounds of budget: the loop must stop
    // without ever calling this a success.
    let (coordinator, _, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, maxRounds: 3, minimumSamples: 5)
    let task = try await coordinator.submit(submission)

    var finalOutcome: HarnessReconcileOutcome?
    for round in 1...6 {
      let outcome = try await coordinator.reconcile(task.htaskID)
      finalOutcome = outcome
      if outcome.snapshot.status.isTerminal || outcome.action == .stoppedForHuman { break }
      artifacts.stage(jobID: "JOB-\(round)", name: "hilog.txt", text: HilogFixture.clean)
      jobs.finish("JOB-\(round)")
    }
    let outcome = try XCTUnwrap(finalOutcome)
    XCTAssertEqual(outcome.action, .stoppedBudgetExhausted)
    XCTAssertEqual(outcome.snapshot.status, .failed)
    XCTAssertEqual(outcome.reasonCode, "maxRoundsExhausted")
    XCTAssertEqual(outcome.snapshot.observed.latestVerdict, .inconclusive)
    XCTAssertLessThan(outcome.snapshot.observed.samples["matchingCrashCount"] ?? 0, 5)
  }

  func testEvidenceIntegrityFailureStopsForAHumanWithoutAnotherCapture() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, _, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, minimumSamples: 1)
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)
    artifacts.stage(
      jobID: "JOB-2", name: "hilog.txt", text: HilogFixture.clean,
      sha256Override: String(repeating: "f", count: 64))
    jobs.finish("JOB-2")

    let blocked = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(blocked.action, .stoppedEvidenceIntegrity)
    XCTAssertEqual(blocked.snapshot.status, .humanRequired)
    XCTAssertTrue(blocked.reasonCode.hasPrefix("evidenceIntegrity:artifactHashMismatch"))
    let submittedBefore = jobs.submittedOperations.count
    let again = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(again.action, .awaitingHuman)
    XCTAssertEqual(
      jobs.submittedOperations.count, submittedBefore,
      "unverifiable evidence must not trigger another capture on its own")
  }
}
