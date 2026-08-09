// Convergence contract tests (CHG-2026-054, TASK-HTP-006).
//
// These cover the three things that stood between "the harness has every
// part of a bounded debug loop" and "one submit converges on a real device",
// all three found on host before the device window rather than inside it:
//
//   1. nothing turned the crank. `task.submit` persisted a task and
//      returned; only an external `task.reconcile` advanced it. Measured on
//      host: twenty seconds after a submit, zero events;
//   2. the handler sent an empty input map to `capture.diagnostics@1`, which
//      declares `durationSeconds` required - so the one operation that
//      collects the evidence the criteria demand could never be admitted;
//   3. `hilog.txt` is declared *required evidence* and *privacy-sensitive*,
//      and the observation builder refused every sensitive artifact with no
//      way to opt in - so even a successful capture could not be measured,
//      every verdict stayed inconclusive, and the loop could only burn its
//      rounds and stop.
//
// Each defect gets its reproduction and its fix, in that order, because the
// reproduction is what proves the fix is about the real failure.

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A clean bounded HiLog retained as diagnostic context. It deliberately
/// carries no liveness or crash measurement.
private let cleanHilog = """
  07-31 04:10:01.100  1401  1401 I A03d00/Ace: WaterFlow layout pass begin
  07-31 04:10:01.480  1401  1401 I A03d00/Ace: WaterFlow reached end of content
  07-31 04:10:02.010  1401  1401 I A03d00/Ace: scroll settled, no recovery needed
  """

/// An empty Faultlogger ledger in the device's own words. The first capture
/// baselines on it and the rest count against that mark, so five *counting*
/// captures satisfy the crash criteria's minimum-sample gate.
private let emptyLedger = """
  ----------------------------------HiviewService----------------------------------
  No fault log exist.
  Fault log list:
  ******
  ******
  """

private struct StagedArtifact {
  let descriptor: HarnessArtifactDescriptor
  let bytes: Data
}

/// Publishes the products selected by each *capture* request. App liveness
/// appears only when the handler supplied a typed Bundle identity;
/// `observe.device@1` publishes none of these products.
private final class ConvergenceArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private let lock = NSLock()
  private let sensitive: Bool
  private var staged: [String: [StagedArtifact]] = [:]
  /// Set by the job port: which job ran which operation.
  private let operations: OperationLedger

  init(sensitive: Bool, operations: OperationLedger) {
    self.sensitive = sensitive
    self.operations = operations
  }

  private func stageIfNeeded(_ jobID: String) {
    guard staged[jobID] == nil else { return }
    guard operations.operation(forJob: jobID) == DebugCrashTaskHandler.captureDiagnostics
    else {
      staged[jobID] = []
      return
    }
    var products: [(name: String, text: String, mediaType: String, sensitive: Bool)] = [
      ("hilog.txt", cleanHilog, "text/plain", sensitive),
      ("crash-index.txt", emptyLedger, "text/plain", sensitive),
    ]
    let inputs = operations.inputs(forJob: jobID)
    if case .string(let bundle)? = inputs["bundleName"] {
      let ability: String
      if case .string(let value)? = inputs["abilityName"] { ability = value } else { ability = "" }
      let process: String
      if case .string(let value)? = inputs["processName"] { process = value } else { process = bundle }
      let applicationRef = sha256Hex(Data("\(bundle)|\(ability)|\(process)".utf8))
      let liveness =
        #"{"documentType":"arkdeck-application-liveness","schemaVersion":"1.0.0","applicationRef":"\#(applicationRef)","state":"HEALTHY","reasonCode":"targetProcessRunning","abilityState":"UNKNOWN","processState":"RUNNING","pidObserved":true,"targetBindingRevision":1,"sourceRuntimeJobId":"\#(jobID)","sourceOperationRef":"capture.diagnostics@1","observationWindow":{"startedAtUtc":"2026-07-31T04:00:00Z","endedAtUtc":"2026-07-31T04:00:00Z"},"observedAtUtc":"2026-07-31T04:00:00Z"}"#
      products.append(("application-liveness.json", liveness, "application/json", false))
    }
    staged[jobID] = products.map { product in
      let name = product.name
      let text = product.text
      let data = Data(text.utf8)
      return StagedArtifact(
        descriptor: HarnessArtifactDescriptor(
          artifactID: "ART-\(jobID)-\(name)",
          name: name,
          mediaType: product.mediaType,
          byteCount: data.count,
          sha256: sha256Hex(data),
          published: true,
          sensitive: product.sensitive,
          missingReason: nil),
        bytes: data)
    }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    lock.withLock {
      stageIfNeeded(jobID)
      return (staged[jobID] ?? []).map(\.descriptor)
    }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      stageIfNeeded(jobID)
      guard
        let match = (staged[jobID] ?? []).first(where: {
          $0.descriptor.artifactID == artifactID
        })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return match.bytes.prefix(maximumBytes)
    }
  }
}

/// Which operation each job ran, shared between the job port and the artifact
/// port so evidence appears only where the catalog says it would.
private final class OperationLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var byJob: [String: String] = [:]
  private var inputsByJob: [String: [String: JSONValue]] = [:]

  func record(
    jobID: String,
    operation: String,
    inputs: [String: JSONValue] = [:]
  ) {
    lock.withLock {
      byJob[jobID] = operation
      inputsByJob[jobID] = inputs
    }
  }

  func operation(forJob jobID: String) -> String? { lock.withLock { byJob[jobID] } }
  func inputs(forJob jobID: String) -> [String: JSONValue] {
    lock.withLock { inputsByJob[jobID] ?? [:] }
  }
}

/// Every submitted job succeeds immediately, so what the tests observe is the
/// harness's own convergence and not a device's timing.
private final class SucceedingJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var nextOrdinal = 1
  private var submitted: [String] = []
  private var inputsByOperation: [String: [String: JSONValue]] = [:]
  let operations: OperationLedger

  init(operations: OperationLedger) {
    self.operations = operations
  }

  var submittedOperations: [String] { lock.withLock { submitted } }
  func inputs(for operation: String) -> [String: JSONValue]? {
    lock.withLock { inputsByOperation[operation] }
  }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    let jobID = lock.withLock { () -> String in
      let id = "JOB-\(nextOrdinal)"
      nextOrdinal += 1
      submitted.append(request.operation.reference)
      inputsByOperation[request.operation.reference] = request.inputs
      return id
    }
    operations.record(
      jobID: jobID, operation: request.operation.reference, inputs: request.inputs)
    return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    HarnessJobObservation(
      jobID: jobID, state: "succeeded", isTerminal: true, succeeded: true,
      outcomeUnknown: false, waitingForHuman: false,
      timeline: ["queued", "running", "succeeded"])
  }

  func requestCancel(jobID: String) async throws {}
}

/// Records what the ticker asked for, without a coordinator behind it.
private final class RecordingDriveTarget: HarnessAutoDriveTarget, @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [String]
  private var reconciled: [String] = []
  private var failuresRemaining: [String: Int]

  init(ids: [String], failuresBeforeSuccess: [String: Int] = [:]) {
    self.ids = ids
    self.failuresRemaining = failuresBeforeSuccess
  }

  var reconcileCalls: [String] { lock.withLock { reconciled } }

  func drivableTaskIDs() async throws -> [String] { lock.withLock { ids } }

  func reconcile(_ htaskID: String) async throws -> HarnessReconcileOutcome {
    try lock.withLock {
      reconciled.append(htaskID)
      if let remaining = failuresRemaining[htaskID], remaining > 0 {
        failuresRemaining[htaskID] = remaining - 1
        throw HarnessCoordinatorError.notFound(htaskID)
      }
      return HarnessReconcileOutcome(
        snapshot: HarnessTaskSnapshot(
          htaskID: htaskID,
          type: .debugCrash,
          intakeDescription: "recorded",
          projectRef: nil,
          target: HarnessTaskTargetReference(targetID: "T", expectedBindingRevision: 1),
          goal: HarnessTaskGoal(summary: "recorded", desiredState: [:]),
          successCriteria: [],
          budgets: HarnessTaskBudgets(
            maxRounds: 8, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
            maxE1Mutations: 0),
          policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash),
          createdAtUTC: "2026-07-31T00:00:00Z",
          updatedAtUTC: "2026-07-31T00:00:00Z",
          status: .running,
          phase: .collecting),
        action: .waitedForActiveJob, reasonCode: "recorded")
    }
  }
}

final class HarnessConvergenceContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-converge-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  private func coordinator(
    sensitiveEvidence: Set<String> = [],
    sensitiveArtifacts: Bool = false,
    jobPort: SucceedingJobPort? = nil
  ) throws -> HarnessTaskCoordinator {
    let port = jobPort ?? SucceedingJobPort(operations: OperationLedger())
    return HarnessTaskCoordinator(
      store: try HarnessTaskStore(rootURL: rootURL),
      jobPort: port,
      artifactPort: ConvergenceArtifactPort(
        sensitive: sensitiveArtifacts, operations: port.operations),
      nowUTC: { "2026-07-31T04:00:00Z" },
      sensitiveEvidenceAllowList: sensitiveEvidence)
  }

  private func submission() -> HarnessTaskSubmission {
    HarnessTaskSubmission(
      type: .debugCrash,
      target: HarnessTaskTargetReference(
        targetID: "TGT-convergence", expectedBindingRevision: 1),
      goal: HarnessTaskGoal(
        summary: "converge without a human poke",
        desiredState: [
          "bundleName": .string("com.example.waterflowdemo"),
          "abilityName": .string("EntryAbility"),
        ]),
      // The handler's own defaults: five clean samples plus liveness, which is
      // exactly what a real crash task submits.
      successCriteria: DebugCrashTaskHandler().defaultSuccessCriteria(),
      budgets: HarnessTaskBudgets(
        maxRounds: 12, maxWallClockSeconds: 1800, maxArtifactBytes: 1 << 20,
        maxE1Mutations: 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
  }

  // MARK: - Defect 1: nothing turned the crank

  func testASubmittedTaskDoesNotAdvanceUntilSomethingDrivesIt() async throws {
    let harness = try coordinator()
    let submitted = try await harness.submit(submission())

    // The same shape as the host measurement: time passing is not a driver.
    let statusNow = try await harness.status(submitted.htaskID)
    let eventsNow = try await harness.events(submitted.htaskID)
    XCTAssertEqual(statusNow.status, .created)
    XCTAssertEqual(statusNow.activeRound, 0)
    XCTAssertEqual(
      eventsNow.count, 0,
      "a submit that advances by itself would have written an admission event")
    let drivable = try await harness.drivableTaskIDs()
    XCTAssertEqual(
      drivable, [submitted.htaskID],
      "the task is drivable - what was missing is something that drives it")
  }

  func testAutoDriveConvergesASubmittedTaskWithNoExternalReconcile() async throws {
    let jobPort = SucceedingJobPort(operations: OperationLedger())
    let harness = try coordinator(
      sensitiveEvidence: ["hilog.txt", "crash-index.txt"], sensitiveArtifacts: true, jobPort: jobPort)
    let submitted = try await harness.submit(submission())

    let ticker = HarnessAutoDriveTicker(
      target: harness, intervalSeconds: 1, sleep: { _ in })
    let report = await ticker.run(maximumWakes: 40)

    let final = try await harness.status(submitted.htaskID)
    XCTAssertEqual(
      final.status, .succeeded,
      "one submit plus auto-drive must reach a verdict with nobody poking reconcile")
    XCTAssertEqual(final.latestEvaluationID?.isEmpty, false)
    let events = try await harness.events(submitted.htaskID)
    let terminal = events.filter { $0.toStatus == .succeeded }
    XCTAssertEqual(
      terminal.map(\.causation), [.evaluation],
      "success still arrives only through the evaluator (HTP-INV-2)")
    XCTAssertGreaterThanOrEqual(
      jobPort.submittedOperations.filter { $0 == DebugCrashTaskHandler.captureDiagnostics }
        .count, 5,
      "the five-sample gate must be satisfied by five real captures")
    XCTAssertEqual(jobPort.submittedOperations.first, DebugCrashTaskHandler.observeDevice)
    XCTAssertGreaterThan(report.dispatchedJobIDs.count, 0)
    XCTAssertEqual(report.degradedTaskIDs, [])
  }

  func testAutoDriveDefaultsOnAndOnlyAnExplicitOverrideTurnsItOff() {
    let key = HarnessAutoDriveTicker.intervalEnvironmentKey
    XCTAssertEqual(
      HarnessAutoDriveTicker.configuredIntervalSeconds([:]),
      HarnessAutoDriveTicker.defaultIntervalSeconds,
      "accepting a bounded task must also turn its loop; no second operator action is required")
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: ""]))
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: "soon"]))
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: "0"]))
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: "off"]))
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: " OFF "]))
    XCTAssertNil(HarnessAutoDriveTicker.configuredIntervalSeconds([key: "-5"]))
    XCTAssertNil(
      HarnessAutoDriveTicker.configuredIntervalSeconds([key: "3601"]),
      "out of range is off, not silently clamped to another cadence")
    XCTAssertEqual(HarnessAutoDriveTicker.configuredIntervalSeconds([key: "5"]), 5)
    XCTAssertEqual(HarnessAutoDriveTicker.configuredIntervalSeconds([key: " 5 "]), 5)
  }

  func testAutoDriveDoesOneReconcilePerDrivableTaskPerWake() async {
    let target = RecordingDriveTarget(ids: ["HTASK-A", "HTASK-B"])
    let ticker = HarnessAutoDriveTicker(target: target, intervalSeconds: 1, sleep: { _ in })

    let report = await ticker.run(maximumWakes: 3)

    XCTAssertEqual(report.wakes, 3)
    XCTAssertEqual(report.reconciles, 6)
    XCTAssertEqual(
      target.reconcileCalls,
      ["HTASK-A", "HTASK-B", "HTASK-A", "HTASK-B", "HTASK-A", "HTASK-B"],
      "one step per task per wake, so no task starves another")
  }

  func testAutoDriveNeverDrivesPausedHumanRequiredOrTerminalTasks() async throws {
    let harness = try coordinator()
    let paused = try await harness.submit(submission())
    // Pause applies to a task that is running: one step first, then pause.
    _ = try await harness.reconcile(paused.htaskID)
    _ = try await harness.pause(paused.htaskID)
    let cancelled = try await harness.submit(submission())
    _ = try await harness.cancel(cancelled.htaskID)

    let drivable = try await harness.drivableTaskIDs()
    XCTAssertFalse(
      drivable.contains(paused.htaskID), "an operator paused it on purpose")
    XCTAssertFalse(drivable.contains(cancelled.htaskID))

    let before = try await harness.status(paused.htaskID).version
    let ticker = HarnessAutoDriveTicker(
      target: harness, intervalSeconds: 1, sleep: { _ in })
    _ = await ticker.run(maximumWakes: 3)
    let after = try await harness.status(paused.htaskID)
    XCTAssertEqual(after.version, before, "a paused task is untouched by the driver")
    XCTAssertEqual(after.lifecycle, .waiting)
    XCTAssertEqual(after.waitReason, .userSuspended)
  }

  func testAutoDriveKeepsDrivingAfterSchedulerFailuresUntilTheTaskCanResume() async {
    let target = RecordingDriveTarget(
      ids: ["HTASK-TRANSIENT"],
      failuresBeforeSuccess: [
        "HTASK-TRANSIENT": HarnessAutoDriveTicker.maximumConsecutiveFailures
      ])
    let ticker = HarnessAutoDriveTicker(target: target, intervalSeconds: 1, sleep: { _ in })

    let report = await ticker.run(maximumWakes: 5)

    XCTAssertEqual(report.degradedTaskIDs, [])
    XCTAssertEqual(
      target.reconcileCalls.count, 5,
      "scheduler failures do not invent a stop outside the task's durable budget")
    XCTAssertEqual(report.reconciles, 2)
  }

  // MARK: - Defect 2: required typed inputs were never sent

  func testEveryBuiltInEvidenceStepSatisfiesTheRequiredInputsItsOperationDeclares() throws {
    // Repair operations derive their required inputs from a bounded patch,
    // readback state and ProjectProfile; HarnessRepairContractTests exercise
    // those concrete plans. This table covers the state-independent evidence
    // steps the deterministic handler can plan from an empty snapshot.
    for reference in [
      DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics,
    ] {
      let descriptor = try XCTUnwrap(
        RuntimeOperationCatalog.descriptor(reference: reference),
        "\(reference) must exist in the catalog this build ships")
      let inputs = DebugCrashTaskHandler.typedInputs(for: reference)
      for field in descriptor.inputs where field.isRequired {
        XCTAssertNotNil(
          inputs[field.name],
          "\(reference) declares \(field.name) required, so a planned step that omits it "
            + "is refused at admission and the loop can never collect its evidence")
      }
      for (name, _) in inputs {
        XCTAssertTrue(
          descriptor.inputs.contains { $0.name == name },
          "\(reference) received an input it does not declare: \(name)")
      }
    }
  }

  func testTheCaptureStepCarriesABoundedDurationAndNoTraceLeg() throws {
    let inputs = DebugCrashTaskHandler.typedInputs(
      for: DebugCrashTaskHandler.captureDiagnostics)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: DebugCrashTaskHandler.captureDiagnostics))
    let duration = try XCTUnwrap(descriptor.inputs.first { $0.name == "durationSeconds" })

    XCTAssertEqual(
      inputs["durationSeconds"], .integer(Int64(DebugCrashTaskHandler.captureDurationSeconds)))
    XCTAssertGreaterThanOrEqual(
      DebugCrashTaskHandler.captureDurationSeconds, duration.minimum ?? 1)
    XCTAssertLessThanOrEqual(
      DebugCrashTaskHandler.captureDurationSeconds, duration.maximum ?? 600)
    XCTAssertNil(
      inputs["traceCategories"],
      "a trace leg escalates the effective effect to deviceMutation, and this task type "
        + "declares maxE1Mutations: 0")
    XCTAssertEqual(
      inputs["crashLogs"], .bool(true),
      "the crash ledger is where the judging fields are (CHG-2026-055, TASK-HFA-001)")
    for escalating in ["uiScreenshot", "uiComponentTree"] {
      XCTAssertNil(
        inputs[escalating],
        "\(escalating) escalates to deviceMutation; the crash leg deliberately does not")
    }
    XCTAssertNil(
      inputs["crashLogName"],
      "no round has observed an entry yet, so no entry may be named")
  }

  func testThePlannedCaptureReachesTheEngineWithItsDeclaredInputs() async throws {
    let jobPort = SucceedingJobPort(operations: OperationLedger())
    let harness = try coordinator(
      sensitiveEvidence: ["hilog.txt", "crash-index.txt"], sensitiveArtifacts: true, jobPort: jobPort)
    let submitted = try await harness.submit(submission())
    // observe, then capture: two reconciles reach the second dispatch.
    for _ in 0..<4 { _ = try? await harness.reconcile(submitted.htaskID) }

    let captured = try XCTUnwrap(
      jobPort.inputs(for: DebugCrashTaskHandler.captureDiagnostics),
      "the capture must have been submitted at all")
    XCTAssertEqual(
      captured["durationSeconds"],
      .integer(Int64(DebugCrashTaskHandler.captureDurationSeconds)),
      "the input the handler declares must survive the whole dispatch path")
    XCTAssertEqual(captured["crashLogs"], .bool(true))
    XCTAssertEqual(captured["bundleName"], .string("com.example.waterflowdemo"))
    XCTAssertEqual(captured["abilityName"], .string("EntryAbility"))
  }

  // MARK: - Defect 3: required evidence that could never be measured

  func testSensitiveEvidenceIsNotMeasuredUntilAnOperatorNamesIt() async throws {
    let ledger = OperationLedger()
    ledger.record(jobID: "JOB-1", operation: DebugCrashTaskHandler.captureDiagnostics)
    let port = ConvergenceArtifactPort(sensitive: true, operations: ledger)
    let closed = HarnessObservationBuilder(artifacts: port)
    let denied = try await closed.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(
      denied.collectionBlockers,
      ["artifactSensitiveNotOptedIn:hilog.txt", "artifactSensitiveNotOptedIn:crash-index.txt"])
    XCTAssertTrue(denied.measurements.isEmpty)
    XCTAssertEqual(denied.evidence.first?.sensitiveOptIn, false)

    // Naming only the log buys only the log. It cannot answer either the
    // application-state or crash-ledger question.
    let logOnly = HarnessObservationBuilder(
      artifacts: port, sensitiveEvidenceAllowList: ["hilog.txt"])
    let partial = try await logOnly.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(partial.collectionBlockers, ["artifactSensitiveNotOptedIn:crash-index.txt"])
    XCTAssertNil(partial.measurements["applicationLiveness"])
    XCTAssertNil(partial.measurements["matchingCrashCount"])

    let opened = HarnessObservationBuilder(
      artifacts: port, sensitiveEvidenceAllowList: ["hilog.txt", "crash-index.txt"])
    let allowed = try await opened.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil,
      requiredEvidence: ["hilog.txt", "crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(allowed.collectionBlockers, [])
    XCTAssertNil(allowed.measurements["applicationLiveness"])
    XCTAssertEqual(allowed.measurements["matchingCrashCount"], .integer(0))
    let record = try XCTUnwrap(allowed.evidence.first)
    XCTAssertTrue(record.verified)
    XCTAssertTrue(
      record.sensitiveOptIn,
      "a maintainer must be able to tell a measured-under-opt-in digest from an unread one")
    XCTAssertEqual(record.sha256, sha256Hex(Data(cleanHilog.utf8)))
  }

  func testAnUnnamedArtifactStaysClosedEvenWhenAnotherNameIsAllowed() async throws {
    let ledger = OperationLedger()
    ledger.record(jobID: "JOB-1", operation: DebugCrashTaskHandler.captureDiagnostics)
    let port = ConvergenceArtifactPort(sensitive: true, operations: ledger)
    let builder = HarnessObservationBuilder(
      artifacts: port, sensitiveEvidenceAllowList: ["ui-dump.json"])
    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(
      observation.collectionBlockers,
      ["artifactSensitiveNotOptedIn:hilog.txt", "artifactSensitiveNotOptedIn:crash-index.txt"],
      "the opt-in is per artifact name, not a blanket permission")
  }

  func testWithoutTheOptInACrashTaskBurnsItsRoundsAndNeverSucceeds() async throws {
    let harness = try coordinator(sensitiveArtifacts: true)
    let submitted = try await harness.submit(submission())

    let ticker = HarnessAutoDriveTicker(
      target: harness, intervalSeconds: 1, sleep: { _ in })
    _ = await ticker.run(maximumWakes: 40)

    let final = try await harness.status(submitted.htaskID)
    XCTAssertEqual(
      final.status, .failed,
      "this is the window failure: required evidence exists and cannot be measured")
    XCTAssertNotEqual(final.status, .succeeded)
    let events = try await harness.events(submitted.htaskID)
    let stop = try XCTUnwrap(events.last)
    XCTAssertEqual(stop.reasonCode, "maxRoundsExhausted")
    let evaluations = try await harness.evaluations(submitted.htaskID)
    XCTAssertEqual(
      evaluations.last?.verdict, .inconclusive,
      "unreadable evidence is inconclusive, never a pass")
    let recordedBlockers = Set(
      evaluations.flatMap { (evaluation: HarnessEvaluation) -> [String] in
        evaluation.blockers + evaluation.criterionResults.flatMap(\.blockers)
      })
    XCTAssertTrue(
      recordedBlockers.contains("artifactSensitiveNotOptedIn:hilog.txt"),
      "the reason must be legible in the record, not just in the outcome: \(recordedBlockers)")
  }

  // MARK: - Defect 4: the operator's flag form could not run a device operation

  func testTheFlagFormRefusesADeviceOperationWithNoPinnedBindingRevision() throws {
    // Measured on the GJ-5 window's first leg: `job submit --target …
    // --operation observe.device@1` reached the daemon and came back with
    // `evidenceIncomplete: target/binding/routing/tool facts are absent or
    // mismatched`, because the document carried no binding revision at all.
    do {
      _ = try RuntimeOperationRequest.operatorFlagForm(
        targetID: "TGT-958780b2ffb7", expectedBindingRevision: nil,
        operationID: "observe.device", version: 1,
        requestID: "cli-test", idempotencyKey: "cli-test-idem-01")
      XCTFail("a device-bound operation with no pinned revision must be refused before submit")
    } catch let rejection as RuntimeOperationRequestRejection {
      XCTAssertEqual(rejection.path, "$.target.expectedBindingRevision")
      XCTAssertTrue(
        rejection.message.contains("--expected-binding-revision"),
        "the refusal has to name what the operator must pass: \(rejection.message)")
    }
  }

  func testTheFlagFormCarriesThePinItWasGiven() throws {
    let request = try RuntimeOperationRequest.operatorFlagForm(
      targetID: "TGT-958780b2ffb7", expectedBindingRevision: 1,
      operationID: "observe.device", version: 1,
      requestID: "cli-test", idempotencyKey: "cli-test-idem-02")
    XCTAssertEqual(request.target.expectedBindingRevision, 1)
    XCTAssertEqual(request.target.targetID, "TGT-958780b2ffb7")
    XCTAssertEqual(request.operation.reference, "observe.device@1")
    XCTAssertTrue(request.inputs.isEmpty, "the flag form expresses no typed inputs")
    XCTAssertNil(request.authorization, "and no authorization identifier")
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(RuntimeOperationRequest.self, from: encoded)
    XCTAssertEqual(decoded.target.expectedBindingRevision, 1, "the pin survives the wire")
  }

  func testTheFlagFormRefusesToPinARevisionOnAHostOnlyOperation() throws {
    let hostOnly = try RuntimeOperationRequest.operatorFlagForm(
      targetID: "demo-app", expectedBindingRevision: nil,
      operationID: "workspace.inspect-source", version: 1,
      requestID: "cli-test", idempotencyKey: "cli-test-idem-03")
    XCTAssertNil(
      hostOnly.target.expectedBindingRevision,
      "a host-only operation has no binding to pin (HTP-AC-20)")
    XCTAssertThrowsError(
      try RuntimeOperationRequest.operatorFlagForm(
        targetID: "demo-app", expectedBindingRevision: 1,
        operationID: "workspace.inspect-source", version: 1,
        requestID: "cli-test", idempotencyKey: "cli-test-idem-04"),
      "pinning a revision on a host-only operation is refused before submit")
  }

  func testEveryDeviceBoundOperationIsReachableThroughTheFlagForm() throws {
    // The point of the fix: with a revision pinned, the documented flag form
    // builds a valid request for *every* device-bound operation, not just the
    // one the window happened to run.
    for descriptor in RuntimeOperationCatalog.operations
    where descriptor.binding == .confirmedDevice {
      let request = try RuntimeOperationRequest.operatorFlagForm(
        targetID: "TGT-958780b2ffb7", expectedBindingRevision: 3,
        operationID: descriptor.id, version: descriptor.version,
        requestID: "cli-test", idempotencyKey: "cli-test-idem-\(descriptor.id)")
      XCTAssertEqual(request.target.expectedBindingRevision, 3, descriptor.reference)
    }
  }

  func testCapabilityDraftDoesNotAskTheDeviceStoreForAWorkspaceSubject() throws {
    var deviceBindingLookups = 0
    let target = RuntimeOperationRequest.capabilityDraftTarget(
      targetID: "demo-app",
      operationID: "workspace.build-openharmony",
      version: 1,
      currentDeviceBindingRevision: {
        deviceBindingLookups += 1
        return 7
      })
    XCTAssertEqual(target.targetID, "demo-app")
    XCTAssertNil(target.expectedBindingRevision)
    XCTAssertEqual(
      deviceBindingLookups, 0,
      "a workspace project reference must not be looked up as an adopted device")
  }

  func testCapabilityDraftStillPinsADeviceSubjectToItsCurrentBinding() throws {
    var deviceBindingLookups = 0
    let target = RuntimeOperationRequest.capabilityDraftTarget(
      targetID: "TGT-958780b2ffb7",
      operationID: "debug.hap",
      version: 1,
      currentDeviceBindingRevision: {
        deviceBindingLookups += 1
        return 9
      })
    XCTAssertEqual(target.targetID, "TGT-958780b2ffb7")
    XCTAssertEqual(target.expectedBindingRevision, 9)
    XCTAssertEqual(deviceBindingLookups, 1)
  }

  func testAnEvidenceRecordWrittenBeforeTheOptInDecodesAsNotOptedIn() throws {
    let legacy = """
      {"artifactId":"ART-1","name":"hilog.txt","byteCount":12,
       "sha256":"\(String(repeating: "a", count: 64))","verified":true}
      """
    let record = try JSONDecoder().decode(
      HarnessEvidenceRecord.self, from: Data(legacy.utf8))
    XCTAssertFalse(
      record.sensitiveOptIn,
      "records written when no opt-in existed cannot have been opted into")
    XCTAssertTrue(record.verified)
  }
}
