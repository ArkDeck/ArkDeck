import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeAgentExecutionContractTests: XCTestCase {
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_788_170_000)
    private var factsAction: (@Sendable () -> Void)?
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    func onFacts(_ action: @escaping @Sendable () -> Void) { lock.withLock { factsAction = action } }
    func readFacts() {
      let action = lock.withLock { let action = factsAction; factsAction = nil; return action }
      action?()
    }
  }

  struct Facts: HDCObservationFactsPort {
    let targets: RuntimeTargetStore
    let clock: Clock
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      clock.readFacts()
      guard let target = try targets.find(targetID: targetID) else {
        throw DeviceProviderError.factsUnavailable("fixture target is absent")
      }
      return ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
        serverFacts: [:], targetID: targetID, bindingRevision: target.bindingRevision,
        deviceIdentitySHA256: target.stablePhysicalIdentitySHA256, executionConnectKey: target.connectKey,
        deviceMode: nil, buildFingerprint: nil, profileID: "openharmony-standard@1",
        collectedAtUTC: RuntimeAgentTime.format(clock.now()))
    }
  }

  final class Dispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var gate: Gate?
    private var targetOutput: Data?
    func hold(_ value: Gate) { lock.withLock { gate = value } }
    func setTargetOutput(_ value: String?) {
      lock.withLock { targetOutput = value.map { Data($0.utf8) } }
    }
    var dispatchCount: Int { lock.withLock { count } }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      let paused = lock.withLock { count += 1; let value = gate; gate = nil; return value }
      await paused?.enter()
      let output: String
      switch plan.action {
      case .hdc(.observeTool): output = "Ver: 3.2.0f\n"
      case .hdc(.observeServer): output = "Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n"
      case .hdc(.observeDevice), .hdc(.listDeviceCandidates):
        if let bytes = lock.withLock({ targetOutput }) {
          return ProviderProcessReceipt(
            exitStatus: 0, stdout: bytes, stderr: Data(), stdoutTruncated: false,
            durationSeconds: 0.01)
        }
        output = "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
      case .hdc(.queryProperty(.productName)): output = "OpenHarmony Reference Device\n"
      case .hdc(.queryProperty(.fullBuildVersion)): output = "OpenHarmony-4.1-release\n"
      default: throw RuntimeDispatchFailure.failed("unexpected fixture action")
      }
      return ProviderProcessReceipt(exitStatus: 0, stdout: Data(output.utf8), stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
    }
  }

  actor Gate {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async { arrived = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
  }

  private var directory: URL!
  private var clock: Clock!
  private var port: TargetObservationCoordinatorContractTests.Port!
  private var targets: RuntimeTargetStore!
  private var engine: RuntimeJobEngine!
  private var dispatcher: Dispatcher!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "ae-\(UUID().uuidString.prefix(8))")
    clock = Clock()
    port = TargetObservationCoordinatorContractTests.Port()
    targets = try RuntimeTargetStore(directoryURL: directory.appending(path: "targets"))
    dispatcher = Dispatcher()
    engine = try makeEngine()
  }

  private func makeEngine(fault: RuntimeAdmissionFaultInjector = .none) throws -> RuntimeJobEngine {
    let capturedClock = clock!
    return try RuntimeJobEngine(
      configuration: .init(stateDirectory: directory.appending(path: "engine"), admissionFaultInjector: fault),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(factsPort: Facts(targets: targets, clock: clock))]),
      dispatcher: dispatcher,
      capabilityStore: RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      artifactStore: RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), nowUTC: { RuntimeAgentTime.format(capturedClock.now()) }),
      nowUTC: { RuntimeAgentTime.format(capturedClock.now()) })
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func owner(
    observations suppliedObservations: TargetObservationCoordinator? = nil
  ) throws -> RuntimeAgentExecutionCoordinator {
    let capturedPort = port!
    let capturedClock = clock!
    let observations = suppliedObservations ?? TargetObservationCoordinator(
      observation: capturedPort, targetStore: targets, usbRelations: { try capturedPort.relations() },
      nowUTC: { RuntimeAgentTime.format(capturedClock.now()) })
    return try RuntimeAgentExecutionCoordinator(
      directory: directory.appending(path: "executions"), engine: engine, targets: targets,
      observations: observations, now: { capturedClock.now() })
  }

  private func request(_ id: String = "execution-test", budget: Int = 30_000) -> [String: JSONValue] {
    ["schemaVersion": .string(AgentExecutionIntent.schemaVersion), "executionId": .string(id),
      "operation": .string("observe.device@1"), "inputs": .object([:]),
      "maximumWaitMilliseconds": .string(String(budget))]
  }

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw AgentClientFixtureError.missingObject }
    return fields
  }
  private enum AgentClientFixtureError: Error { case missingObject }

  private func waitForJob(_ owner: RuntimeAgentExecutionCoordinator) async throws -> [String: JSONValue] {
    for _ in 0..<400 {
      let status = try object(await owner.status("execution-test"))
      if status["state"] == .string("completed") { return status }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw AgentClientFixtureError.missingObject
  }

  private func startServer(
    _ owner: RuntimeAgentExecutionCoordinator,
    observations: TargetObservationCoordinator? = nil,
    humanActions: RuntimeHumanActionResourceCoordinator? = nil
  ) throws -> AgentDaemonServer {
    let capturedClock = clock!
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      providerIDs: ["hdc"], nowUTC: { RuntimeAgentTime.format(capturedClock.now()) },
      targetStore: targets, targetObservations: observations, agentExecutions: owner,
      humanActionResources: humanActions,
      artifactStore: try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"),
        nowUTC: { RuntimeAgentTime.format(capturedClock.now()) }))
    let instance = AgentDaemonServer(stateDirectory: directory.appending(path: "control"), handler: handler,
      nowUTC: { RuntimeAgentTime.format(capturedClock.now()) })
    _ = try instance.start()
    server = instance
    return instance
  }

  private func cli(_ arguments: [String], server: AgentDaemonServer) throws -> (Int32, [String: JSONValue]) {
    let process = Process()
    process.executableURL = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = arguments + ["--output", "json", "--socket", server.socketURL.path]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let limit = Date().addingTimeInterval(30)
    while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { process.terminate(); throw AgentClientFixtureError.missingObject }
    let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorBytes = stderr.fileHandleForReading.readDataToEndOfFile()
    if bytes.isEmpty { XCTFail("CLI \(arguments.prefix(2)) exited \(process.terminationStatus): \(String(decoding: errorBytes, as: UTF8.self))") }
    let document = try CLIStrictJSON.decode(bytes)
    return (process.terminationStatus, try object(document))
  }

  private func action(_ value: JSONValue) throws -> (reference: String, fields: [String: JSONValue]) {
    let fields = try object(value)
    let action = try object(XCTUnwrap(fields["humanAction"]))
    guard case .string(let reference)? = action["resumeReference"] else { throw AgentClientFixtureError.missingObject }
    return (reference, action)
  }

  func testPendingExecutionSurvivesOwnerRestartWithoutChangingItsIntentOrToken() async throws {
    port.setState("Unauthorized")
    let initial = try await owner().run(request())
    let first = try action(initial)
    let restarted = try owner()
    let again = try await restarted.run(request())
    XCTAssertEqual(try action(again).reference, first.reference)
    XCTAssertEqual(try object(again)["executionId"], .string("execution-test"))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    XCTAssertEqual(try targets.list().count, 0)
  }

  func testReviewedPlanPresenceAndValueCannotChangeDuringAPause() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    var original = request()
    original["reviewedPlanDigest"] = .string(String(repeating: "a", count: 64))
    let first = try action(await owner.run(original))
    for digest in [nil, String(repeating: "b", count: 64)] {
      var changed = request()
      if let digest { changed["reviewedPlanDigest"] = .string(digest) }
      do { _ = try await owner.run(changed); XCTFail("changed precondition must conflict") }
      catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "idempotencyConflict") }
    }
    let replay = try action(await owner.run(original))
    XCTAssertEqual(replay.reference, first.reference)
    var invalidDifferentIntent = original
    invalidDifferentIntent["inputs"] = .object(["undeclared": .bool(true)])
    do { _ = try await owner.run(invalidDifferentIntent); XCTFail("an existing identity must report changed intent") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "idempotencyConflict") }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testPausedBudgetIncludesRestartAndCannotBeExtendedByReentry() async throws {
    port.setState("Unauthorized")
    let first = try action(await owner().run(request(budget: 1000)))
    clock.advance(2)
    let restarted = try owner()
    do { _ = try await restarted.run(request(budget: 1000)); XCTFail("budget must include paused time") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "orchestrationBudgetExpired") }
    do { _ = try await restarted.resume(reference: first.reference); XCTFail("expired HAR cannot resume") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "humanActionExpired") }
    do { _ = try await restarted.run(request(budget: 10_000)); XCTFail("same ID cannot increase its budget") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "idempotencyConflict") }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testClockRollbackFailsClosedAcrossOwnerRestart() async throws {
    port.setState("Unauthorized")
    _ = try await owner().run(request())
    clock.advance(-1)
    do { _ = try await owner().run(request()); XCTFail("clock rollback must be refused") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "orchestrationClockUntrusted") }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    XCTAssertEqual(try targets.list().count, 0)
  }

  func testAbandonExpiresTheExactHARAndNeverCreatesAJob() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    let first = try action(await owner.run(request()))
    let current = try object(await owner.status("execution-test"))
    guard case .string(let value)? = current["generation"], let generation = Int64(value) else { return XCTFail("generation is absent") }
    let abandoned = try object(await owner.abandon("execution-test", expectedGeneration: generation))
    XCTAssertEqual(abandoned["state"], .string("abandoned"))
    port.setState("Connected")
    do { _ = try await owner.resume(reference: first.reference); XCTFail("abandoned execution cannot resume") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "humanActionExpired") }
    let replay = try object(await owner.run(request()))
    XCTAssertEqual(replay["state"], .string("abandoned"))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  /// `TASK-XPA-001`: `agent.list` and `agent.abandon` answer through the
  /// control plane, so their result shapes enter the recorded corpus. The
  /// owner-level tests above own the semantics; this one records the frames a
  /// client reads back and checks that nothing else happened.
  /// `agent.run`, `agent.resume` and `agent.status` embed the same evidence
  /// object as `job.result`, and their published schemas declared
  /// `evidence.actualStepKinds` as a non-nullable array. The daemon has
  /// answered null there since the Runtime learned to say "unknown", so the
  /// declaration was false; #1762 fixed the behaviour on this path but could
  /// not publish the shape, because no recorded frame carried it. This test is
  /// the frame.
  func testAgentStatusPublishesUnknownStepsAsNullAndRefusesToCallItVerified() async throws {
    let jobID = "job-agent-unprovable"
    let executionID = "execution-unprovable"

    // A terminal Flash Job whose journal is gone. A terminal Job cannot carry
    // an unresolved intent — the journal refuses to finalize one — so a lost
    // journal is the reachable way for durable state to be unable to prove the
    // typed steps of a Job that has already ended.
    // The store checks that a stored submission is exactly the request the
    // coordinator would have prepared from the intent, so the identifiers are
    // derived the same way it derives them.
    let seed = RuntimeAgentExecutionStore.fingerprint(Data(executionID.utf8))
    let request = try RuntimeOperationRequest(
      requestID: "agent-request-\(seed)", idempotencyKey: "agent-execution-\(seed)",
      target: DurableTargetReference(targetID: "TGT-fixture", expectedBindingRevision: 2),
      operation: RuntimeOperationReference(id: "flash.full-restore", version: 1))
    var record = RuntimeJobRecord(
      jobID: jobID, request: request, operationReference: ArkForgeFlashOperation.canonicalReference,
      catalogDigest: RuntimeOperationCatalog.catalogDigest, providerID: "arkforge",
      createdAtUTC: RuntimeAgentTime.format(clock.now()), actualEffect: "destructive",
      admissionEvidence: nil, materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil, materializedBindingRevision: 2)
    record.state = "failed"
    _ = try RuntimeJobRepository(stateDirectory: directory.appending(path: "engine")).admit(
      jobID: jobID, idempotencyKey: request.idempotencyKey,
      requestHash: String(repeating: "b", count: 64), initialState: record.state,
      createdAtUTC: record.createdAtUTC, initialRecordData: record.durableData())

    // An execution that owns that Job. `agent.status` reads the record and
    // hands the Job to the daemon's own result projection, which is the code
    // under test.
    let intent = try AgentExecutionIntent([
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(executionID),
      "operation": .string(ArkForgeFlashOperation.canonicalReference),
      "inputs": .object([:]),
      "maximumWaitMilliseconds": .string("30000"),
    ])
    let now = RuntimeAgentTime.format(clock.now())
    let store = try RuntimeAgentExecutionStore(directory: directory.appending(path: "executions"))
    try store.save(
      RuntimeAgentExecutionRecord(
        schemaVersion: "arkdeck.runtime-agent-execution/1", intent: intent,
        intentFingerprintSHA256: RuntimeAgentExecutionStore.fingerprint(try intent.canonicalIntent),
        catalogDigest: RuntimeOperationCatalog.catalogDigest, createdAt: now,
        // The store's own invariants: the deadline is exactly the intent's
        // wait budget past creation, and a record that owns a Job carries the
        // request it submitted.
        deadline: RuntimeAgentTime.format(clock.now().addingTimeInterval(30)),
        lastObservedAt: now, generation: 1, state: .completed,
        target: AgentResolvedTarget(targetID: "TGT-fixture", bindingRevision: 2),
        submissionRequest: try CanonicalJSONEncoders.canonical().encode(request),
        jobID: jobID, jobState: "failed", outcomeUnknown: false,
        failureCode: nil, actions: []),
      expectedGeneration: nil)

    let capturedClock = clock!
    let handler = RuntimeControlPlaneHandler(
      engine: engine,
      capabilityStore: try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      providerIDs: ["hdc"], nowUTC: { RuntimeAgentTime.format(capturedClock.now()) },
      targetStore: targets, agentExecutions: try owner(),
      artifactStore: try RuntimeArtifactStore(
        rootURL: directory.appending(path: "artifacts"),
        nowUTC: { RuntimeAgentTime.format(capturedClock.now()) }))
    let response = await handler.handleFrame(
      try JSONEncoder().encode(
        AgentWireProtocol.Request(
          id: UUID().uuidString, method: "agent.status",
          params: ["executionId": .string(executionID)])))

    XCTAssertTrue(response.ok, response.error?.message ?? "-")
    let fields = try object(XCTUnwrap(response.result))
    let evidence = try object(XCTUnwrap(fields["evidence"]))
    XCTAssertEqual(evidence["actualStepKinds"], .null)
    XCTAssertNotEqual(evidence["status"], .string("verified"))
    guard case .array(let blockers)? = evidence["blockers"] else {
      return XCTFail("evidence must publish its blockers")
    }
    XCTAssertTrue(blockers.contains(.string(RuntimeJobResourceReader.stepKindsUnprovable)))

    // `agent.run` re-offered with the same immutable intent answers the
    // existing execution through the same projection, so it publishes the
    // shape too.
    let reRun = await handler.handleFrame(
      try JSONEncoder().encode(
        AgentWireProtocol.Request(
          id: UUID().uuidString, method: "agent.run",
          params: [
            "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
            "executionId": .string(executionID),
            "operation": .string(ArkForgeFlashOperation.canonicalReference),
            "inputs": .object([:]),
            "maximumWaitMilliseconds": .string("30000"),
          ])))
    XCTAssertTrue(reRun.ok, reRun.error?.message ?? "-")
    let runEvidence = try object(XCTUnwrap(try object(XCTUnwrap(reRun.result))["evidence"]))
    XCTAssertEqual(runEvidence["actualStepKinds"], .null)
  }

  func testAgentListAndAbandonPublishTheirResultShapesThroughTheControlPlane() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    let capturedClock = clock!
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      providerIDs: ["hdc"], nowUTC: { RuntimeAgentTime.format(capturedClock.now()) },
      targetStore: targets, agentExecutions: owner,
      artifactStore: try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"),
        nowUTC: { RuntimeAgentTime.format(capturedClock.now()) }))
    func send(_ method: String, _ params: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      let frame = try JSONEncoder().encode(
        AgentWireProtocol.Request(id: UUID().uuidString, method: method, params: params))
      return await handler.handleFrame(frame)
    }

    let started = try await send("agent.run", request())
    XCTAssertTrue(started.ok, started.error?.message ?? "-")
    let listed = try await send("agent.list", [:])
    XCTAssertTrue(listed.ok, listed.error?.message ?? "-")
    let renderedList = String(decoding: try JSONEncoder().encode(listed.result ?? .null), as: UTF8.self)
    XCTAssertTrue(renderedList.contains("execution-test"), "the pending execution is listed: \(renderedList)")
    XCTAssertFalse(renderedList.contains("150100424a544e4600"), "no connect key crosses the control plane")

    let current = try object(await owner.status("execution-test"))
    guard case .string(let generation)? = current["generation"] else { return XCTFail("generation is absent") }
    let abandoned = try await send(
      "agent.abandon", ["executionId": .string("execution-test"), "expectedGeneration": .string(generation)])
    XCTAssertTrue(abandoned.ok, abandoned.error?.message ?? "-")
    guard case .object(let outcome)? = abandoned.result else { return XCTFail("agent.abandon must answer the execution") }
    XCTAssertEqual(outcome["state"], .string("abandoned"))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testTrustResumeAfterRestartRequiresFreshSelectionInsteadOfFollowingAReusedKey() async throws {
    port.setState("Unauthorized")
    let first = try action(await owner().run(request()))
    port.setState("Connected")
    port.setRelations([TargetObservationCoordinatorContractTests.Port.relation(id: 99)])
    let restarted = try owner()
    let fresh = try action(await restarted.resume(reference: first.reference))
    XCTAssertNotEqual(fresh.reference, first.reference)
    XCTAssertEqual(fresh.fields["reasonCode"], .string("device.identityAmbiguous"))
    XCTAssertEqual(try targets.list().count, 0)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testPhysicalReconnectStartsAFreshObservationAndResolvesWithoutASecondHAR() async throws {
    let identity = DeviceBootstrapMachine.stableIdentitySHA256(
      serial: "150100424a544e4600")
    let existing = try targets.adopt(
      stableIdentitySHA256: identity, connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f", nowUTC: RuntimeAgentTime.format(clock.now())).record
    port.setState("Offline")
    let owner = try owner()
    let first = try action(await owner.run(request()))
    XCTAssertEqual(first.fields["reasonCode"], .string("device.notObserved"))

    // Replugging preserves the device's independently read serial but creates
    // a new USB attachment/observation identity. The physical HAR authorizes
    // probing that new attachment; it does not authorize guessing a device.
    port.setRelations([TargetObservationCoordinatorContractTests.Port.relation(id: 18)])
    port.setState("Connected")
    let resumed = try object(await owner.resume(reference: first.reference))
    XCTAssertEqual(resumed["state"], .string("jobOwned"), "unexpected resume projection: \(resumed)")
    XCTAssertNotEqual(resumed["jobId"], .null, "reconnect must transfer the exact intent to a Job")
    let finished = try await waitForJob(owner)

    XCTAssertEqual(finished["state"], .string("completed"))
    XCTAssertEqual(finished["jobState"], .string("succeeded"))
    XCTAssertEqual(finished["targetId"], .string(existing.targetID))
    XCTAssertEqual(finished["bindingRevision"], .integer(Int64(existing.bindingRevision)))
    guard case .string(let actionID)? = first.fields["actionId"] else {
      return XCTFail("human-action identity is absent")
    }
    let original = try object(await owner.humanAction(actionID))
    XCTAssertEqual(original["status"], .string("resolvedByFreshProbe"))
    let page = try object(await owner.humanActions(filters: [:], pageSize: 10, cursor: nil))
    guard case .array(let actions)? = page["items"] else {
      return XCTFail("human-action page is absent")
    }
    XCTAssertEqual(actions.count, 1, "a proven singleton reconnect must not manufacture an identity HAR")
    XCTAssertEqual(try targets.list(), [existing], "a normal USB replug must not advance target lineage")
  }

  func testConcurrentReentryCreatesOneJobAndDoesNotCancelIt() async throws {
    let owner = try owner()
    let fields = request()
    async let first = owner.run(fields)
    async let second = owner.run(fields)
    let pair = try await [first, second]
    let job = try object(pair[0])["jobId"]
    XCTAssertNotEqual(job, .null)
    XCTAssertEqual(try object(pair[1])["jobId"], job)
    var final: [String: JSONValue] = [:]
    for _ in 0..<200 {
      final = try object(await owner.status("execution-test"))
      if final["state"] == .string("completed") { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(final["state"], .string("completed"))
    XCTAssertEqual(final["jobState"], .string("succeeded"))
    let count = dispatcher.dispatchCount
    XCTAssertGreaterThan(count, 0)
    let replay = try object(await owner.run(fields))
    XCTAssertEqual(replay["jobId"], job)
    XCTAssertEqual(dispatcher.dispatchCount, count)
    let jobs = try await engine.listJobs()
    XCTAssertEqual(jobs.count, 1)
    do { _ = try await owner.abandon("execution-test", expectedGeneration: 1); XCTFail("abandon cannot cancel an existing Job") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
  }

  func testConflictingJobIdempotencyNeverLeavesACrossOwnedExecution() async throws {
    let identity = DeviceBootstrapMachine.stableIdentitySHA256(
      serial: "150100424a544e4600")
    let target = try targets.adopt(
      stableIdentitySHA256: identity, connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f", nowUTC: RuntimeAgentTime.format(clock.now())).record
    let existing = try RuntimeOperationRequest(
      requestID: "existing-request", idempotencyKey: "shared-job-idempotency",
      target: .init(
        targetID: target.targetID,
        expectedBindingRevision: target.bindingRevision),
      operation: .init(id: "observe.device", version: 1), inputs: [:],
      requestedOutputs: [.derivedArtifacts], authorization: nil,
      clientContext: nil)
    _ = try await engine.submit(RuntimeOperationCodec.encodeRequest(existing))

    var conflicting = request("execution-conflict")
    conflicting["requestId"] = .string("owner-request")
    conflicting["idempotencyKey"] = .string("shared-job-idempotency")
    conflicting["target"] = .object([
      "targetId": .string(target.targetID),
      "expectedBindingRevision": .integer(Int64(target.bindingRevision)),
    ])
    let owner = try owner()
    do {
      _ = try await owner.run(conflicting)
      XCTFail("a Job idempotency conflict must be surfaced")
    } catch let error as AgentExecutionControlFailure {
      XCTAssertEqual(error.code, "idempotencyConflict")
      XCTAssertEqual(error.details["newDispatchCount"], .integer(0))
    }
    let status = try object(await owner.status("execution-conflict"))
    XCTAssertEqual(status["state"], .string("failed"))
    XCTAssertEqual(status["failureCode"], .string("idempotencyConflict"))
    XCTAssertEqual(status["jobId"], .null)
    let jobs = try await engine.listJobs()
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testInvalidInputsAreRefusedBeforeAnyExecutionOrHumanActionExists() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    var invalid = request()
    invalid["inputs"] = .object(["rawShell": .string("not a published input")])
    do { _ = try await owner.run(invalid); XCTFail("undeclared input must not create a pending owner") }
    catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, _) = error else { return XCTFail("wrong rejection: \(error)") }
    }
    let page = try object(await owner.list(filters: [:], pageSize: 10, cursor: nil))
    XCTAssertEqual(page["items"], .array([]))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testBudgetExpiringDuringAdoptionOrMaterializationCreatesNoJob() async throws {
    let clock = clock!
    port.onIdentity { clock.advance(2) }
    let first = try owner()
    do { _ = try await first.run(request(budget: 1000)); XCTFail("expired adoption must not commit") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "orchestrationBudgetExpired") }
    XCTAssertTrue(try targets.list().isEmpty)
    port.onIdentity {}
    clock.onFacts { clock.advance(2) }
    do { _ = try await first.run(request("execution-materialization", budget: 1000)); XCTFail("expired materialization must not admit") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "orchestrationBudgetExpired") }
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let status = try object(await first.status("execution-materialization"))
    XCTAssertEqual(status["state"], .string("budgetExpired"))
  }

  func testStaleAbandonCannotOverrideANewerOwnerGeneration() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    _ = try await owner.run(request())
    do { _ = try await owner.abandon("execution-test", expectedGeneration: 1); XCTFail("old generation must conflict") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
    let current = try object(await owner.status("execution-test"))
    XCTAssertEqual(current["state"], .string("waitingForHuman"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testSnapshotCursorSurvivesRestartAndBindsTheExactQueryWithoutDisclosingInputs() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    _ = try await owner.run(request("execution-a"))
    _ = try await owner.run(request("execution-b"))
    let first = try object(await owner.list(filters: [:], pageSize: 1, cursor: nil))
    guard case .string(let cursor)? = first["nextCursor"] else { return XCTFail("missing continuation") }
    _ = try await owner.run(request("execution-c"))
    let restarted = try self.owner()
    let second = try object(await restarted.list(filters: [:], pageSize: 1, cursor: cursor))
    XCTAssertEqual(first["snapshotRevision"], second["snapshotRevision"])
    XCTAssertEqual(second["hasMore"], .bool(false))
    guard case .array(let items)? = second["items"], let item = items.first else { return XCTFail("missing item") }
    let fields = try object(item)
    XCTAssertEqual(fields["executionId"], .string("execution-b"))
    for key in ["inputs", "capabilityReference", "humanAction", "selection"] { XCTAssertNil(fields[key]) }
    for bad in [cursor + "x", UUID().uuidString.lowercased() + "." + UUID().uuidString.lowercased()] {
      do { _ = try await restarted.list(filters: [:], pageSize: 1, cursor: bad); XCTFail("forged cursor must fail") }
      catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
    }
    do { _ = try await restarted.humanActions(filters: [:], pageSize: 1, cursor: cursor); XCTFail("cross-method cursor must fail") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
    do { _ = try await restarted.list(filters: ["state": .string("waitingForHuman")], pageSize: 1, cursor: cursor); XCTFail("changed query must fail") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
  }

  func testLostAdmissionReceiptFindsTheSameJobAfterRestartAndBudgetExpiry() async throws {
    engine = try makeEngine(fault: .init { boundary in
      if boundary == .afterAdmission { throw AgentClientFixtureError.missingObject }
    })
    let owner = try owner()
    do { _ = try await owner.run(request(budget: 1000)); XCTFail("fixture must interrupt publication") }
    catch AgentClientFixtureError.missingObject {}
    let accepted = try await engine.listJobs()
    XCTAssertEqual(accepted.count, 1)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    clock.advance(2)
    engine = try makeEngine()
    _ = try await engine.recoverActiveJobs()
    let restarted = try self.owner()
    let queried = try object(await restarted.status("execution-test"))
    XCTAssertEqual(queried["jobId"], .string(accepted[0].jobID))
    _ = try await restarted.run(request(budget: 1000))
    let finished = try await waitForJob(restarted)
    XCTAssertEqual(finished["jobState"], .string("succeeded"))
    let jobs = try await engine.listJobs()
    XCTAssertEqual(jobs.count, 1)
  }

  func testCLIProducesOneHARReferenceAndResumesItsOriginalUntargetedIntent() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    let server = try startServer(owner)
    let args = ["agent", "run", "--execution-id", "execution-test", "--operation", "observe.device@1"]
    let (pausedCode, paused) = try cli(args, server: server)
    XCTAssertEqual(pausedCode, 75)
    let error = try object(XCTUnwrap(paused["error"]))
    XCTAssertEqual(error["code"], .string("humanActionRequired"))
    let details = try object(XCTUnwrap(error["details"]))
    let first = try action(XCTUnwrap(details["execution"]))
    guard case .string(let actionID)? = first.fields["actionId"] else { return XCTFail("missing action ID") }
    let (showCode, show) = try cli(["human-action", "show", "--human-action", actionID], server: server)
    XCTAssertEqual(showCode, 0)
    XCTAssertEqual(try object(XCTUnwrap(show["result"]))["resumeReference"], .string(first.reference))
    port.setState("Connected")
    let (code, resumed) = try cli(["agent", "resume", "--resume-reference", first.reference, "--timeout", "10s"], server: server)
    XCTAssertEqual(code, 0)
    XCTAssertEqual(resumed["ok"], .bool(true))
    let result = try object(XCTUnwrap(resumed["result"]))
    XCTAssertEqual(result["state"], .string("completed"))
    XCTAssertEqual(result["jobState"], .string("succeeded"))
    let count = dispatcher.dispatchCount
    let (replayedCode, replayed) = try cli(args, server: server)
    XCTAssertEqual(replayedCode, 0)
    XCTAssertEqual(try object(XCTUnwrap(replayed["result"]))["jobId"], result["jobId"])
    XCTAssertEqual(dispatcher.dispatchCount, count)
    let actionAfter = try object(await owner.humanAction(actionID))
    XCTAssertEqual(actionAfter["status"], .string("resolvedByFreshProbe"))
  }

  func testBootstrapLimitsRawToolFailuresAndPreservesBoundedTargetDiagnostics() async throws {
    struct ReceiptDispatcher: RuntimeProcessDispatching {
      let receipt: ProviderProcessReceipt
      func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt { receipt }
    }
    let capturedClock = clock!
    func observation(_ bytes: Data, truncated: Bool = false) -> ProviderBootstrapObservation {
      ProviderBootstrapObservation(
        provider: HDCObservationProviderAdapter(factsPort: Facts(targets: targets, clock: clock)),
        dispatcher: ReceiptDispatcher(receipt: ProviderProcessReceipt(
          exitStatus: 0, stdout: bytes, stderr: Data(), stdoutTruncated: truncated,
          durationSeconds: 0.01)),
        nowUTC: { RuntimeAgentTime.format(capturedClock.now()) })
    }
    for output in ["Ver: \u{1B}[2J\n", "Ver: " + String(repeating: "x", count: 16_384) + "\n",
      "Ver: access_token=fixture-tool-value\n", ""]
    {
      do {
        _ = try await observation(Data(output.utf8)).observeToolVersion()
        XCTFail("unverified tool output must be refused")
      } catch BootstrapError.observationFailed(let reason) {
        XCTAssertEqual(reason, "tool version could not be verified")
      }
    }
    let version = try await observation(Data("Ver: 3.2.0f\n".utf8)).observeToolVersion()
    XCTAssertEqual(version, "3.2.0f")

    let rejected = Data(("key\t\tUSB\t" + String(repeating: "\u{1B}", count: 10_000) + "\tlocalhost\n").utf8)
    guard case .malformed(let preview) = HDCObservationSemanticParser.parseTargetList(
      stdout: rejected, profile: .openHarmony320Family, toolVersion: "3.2.0f", truncated: false)
    else { return XCTFail("fixture must produce a bounded target diagnostic") }
    for (bytes, truncated, expected) in [
      (rejected, false, preview),
      (Data([0xFF, 0xFE]), false, "invalidEncoding: stdout is not valid UTF-8"),
      (rejected, true, "truncated: stdout exceeded its byte budget"),
      (Data(), false, "empty observation output"),
    ] {
      for identity in [false, true] {
        do {
          let port = observation(bytes, truncated: truncated)
          if identity { _ = try await port.observeDeviceIdentity(connectKey: "key") }
          else { _ = try await port.listCandidates() }
          XCTFail("unverified target output must be refused")
        } catch BootstrapError.observationFailed(let reason) {
          XCTAssertEqual(reason, expected, "the target preview must not be escaped twice")
          XCTAssertLessThanOrEqual(reason.utf8.count, 1_536)
          XCTAssertTrue(reason.utf8.allSatisfy { (0x20...0x7E).contains($0) })
        }
      }
    }
  }

  func testProductionTargetDiagnosticReachesDiscoveryAdoptionAndBothCLIResumePaths() async throws {
    let malformed = "[I] ignored\n\n150100424a544e4600\tConnected\r\n"
    guard case .malformed(let reason) = HDCObservationSemanticParser.parseTargetList(
      stdout: Data(malformed.utf8), profile: .openHarmony320Family,
      toolVersion: "3.2.0f", truncated: false)
    else { return XCTFail("fixture must be refused by the production parser") }
    let capturedClock = clock!
    let capturedPort = port!
    let observations = TargetObservationCoordinator(
      observation: ProviderBootstrapObservation(
        provider: HDCObservationProviderAdapter(factsPort: Facts(targets: targets, clock: clock)),
        dispatcher: dispatcher, nowUTC: { RuntimeAgentTime.format(capturedClock.now()) }),
      targetStore: targets, usbRelations: { try capturedPort.relations() },
      nowUTC: { RuntimeAgentTime.format(capturedClock.now()) })
    let owner = try owner(observations: observations)
    let humanActions = try RuntimeHumanActionResourceCoordinator(
      directory: directory.appending(path: "human-actions"), agents: owner, controlResources: nil)
    let server = try startServer(owner, observations: observations, humanActions: humanActions)

    func refused(_ arguments: [String], code: String, exitCode: Int32) throws {
      let before = dispatcher.dispatchCount
      let reply = try cli(arguments, server: server)
      XCTAssertEqual(reply.0, exitCode)
      XCTAssertEqual(reply.1["ok"], .bool(false))
      let error = try object(XCTUnwrap(reply.1["error"]))
      XCTAssertEqual(error["code"], .string(code))
      XCTAssertEqual(error["message"], .string(reason))
      if case .object(let details)? = error["details"] {
        XCTAssertNil(details["phase"])
        XCTAssertNil(details["newDispatchCount"], "a failed read probe is not a zero-dispatch proof")
      }
      XCTAssertEqual(dispatcher.dispatchCount, before + 1, "one explicit request performs one bounded target probe")
      XCTAssertTrue(try targets.list().isEmpty)
    }

    dispatcher.setTargetOutput(malformed)
    try refused(["device", "candidates"], code: "internalError", exitCode: 70)
    try refused(["agent", "run", "--execution-id", "malformed-discovery",
      "--operation", "observe.device@1"], code: "outcomeUnknown", exitCode: 75)

    // Adoption must first possess a real observation reference. Its fresh
    // recheck then returns the same production diagnostic and creates no target.
    dispatcher.setTargetOutput(nil)
    let client = AgentClient(socketPath: server.socketURL.path)
    let snapshot = try object(client.request(method: "device.observations"))
    guard case .array(let rows)? = snapshot["observations"],
      let row = rows.first, case .string(let generation)? = snapshot["snapshotGeneration"],
      case .string(let observationID)? = try object(row)["observationId"]
    else { return XCTFail("production discovery did not return a reference") }
    dispatcher.setTargetOutput(malformed)
    try refused(["target", "adopt", "--candidate", "150100424a544e4600",
      "--observation", observationID, "--observation-generation", generation],
      code: "outcomeUnknown", exitCode: 75)

    dispatcher.setTargetOutput("150100424a544e4600\t\tUSB\tUnauthorized\tlocalhost\n")
    let paused = try cli(["agent", "run", "--execution-id", "execution-test",
      "--operation", "observe.device@1"], server: server)
    XCTAssertEqual(paused.0, 75)
    let pausedError = try object(XCTUnwrap(paused.1["error"]))
    XCTAssertEqual(pausedError["code"], .string("humanActionRequired"))
    let details = try object(XCTUnwrap(pausedError["details"]))
    let pending = try action(XCTUnwrap(details["execution"]))
    guard case .string(let actionID)? = pending.fields["actionId"] else {
      return XCTFail("production observation did not produce a physical action")
    }
    let actionBefore = try await owner.humanAction(actionID)
    dispatcher.setTargetOutput(malformed)
    try refused(["agent", "resume", "--resume-reference", pending.reference],
      code: "outcomeUnknown", exitCode: 75)
    try refused(["human-action", "resume", "--human-action", actionID,
      "--resume-reference", pending.reference], code: "outcomeUnknown", exitCode: 75)
    let actionAfter = try await owner.humanAction(actionID)
    XCTAssertEqual(actionAfter, actionBefore, "a parse refusal cannot consume or replace physical assistance")
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testTargetDiagnosticSurvivesJobRestartAndCLIReadsWithoutClosingOrReplayingItsIntent() async throws {
    let malformed = "150100424a544e4600\tConnected\r\n"
    guard case .malformed(let reason) = HDCObservationSemanticParser.parseTargetList(
      stdout: Data(malformed.utf8), profile: .openHarmony320Family,
      toolVersion: "3.2.0f", truncated: false)
    else { return XCTFail("fixture must be refused by the production parser") }
    let target = try targets.adopt(
      stableIdentitySHA256: DeviceBootstrapMachine.stableIdentitySHA256(serial: "150100424a544e4600"),
      connectKey: "150100424a544e4600", toolVersion: "3.2.0f",
      nowUTC: RuntimeAgentTime.format(clock.now())).record
    let request = try RuntimeOperationRequest(
      requestID: "malformed-target-request", idempotencyKey: "malformed-target-job",
      target: .init(targetID: target.targetID, expectedBindingRevision: target.bindingRevision),
      operation: .init(id: "observe.device", version: 1), inputs: [:],
      requestedOutputs: [.derivedArtifacts], authorization: nil, clientContext: nil)
    dispatcher.setTargetOutput(malformed)
    let accepted = try await engine.submit(RuntimeOperationCodec.encodeRequest(request))
    let status = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(status.state, "waitingForRecovery")
    XCTAssertTrue(status.outcomeUnknown)
    XCTAssertEqual(dispatcher.dispatchCount, 3, "tool, server and exact target probes run once")
    let diagnostic = try XCTUnwrap(status.timeline.first { $0.contains(reason) })
    let journal = directory.appending(path: "engine/jobs/\(accepted.jobID)/journal.jsonl")
    let original = try DurableJournalRecovery.inspect(url: journal)
    XCTAssertEqual(original.outstandingIntents.count, 1)
    let intent = try XCTUnwrap(original.outstandingIntents.first)
    XCTAssertEqual(intent.stepID, "confirm-evidence-target")
    XCTAssertFalse(original.events.contains { $0.correlatedIntentEventID == intent.eventID })
    XCTAssertTrue(original.events.contains { $0.payload["reason"] == .string("outcomeUnknown: \(reason)") })

    engine = try makeEngine()
    _ = try await engine.recoverActiveJobs()
    let restarted = try await engine.status(jobID: accepted.jobID)
    XCTAssertEqual(restarted.state, "waitingForRecovery")
    XCTAssertTrue(restarted.outcomeUnknown)
    XCTAssertTrue(restarted.timeline.contains(diagnostic))
    do {
      _ = try await engine.run(jobID: accepted.jobID)
      XCTFail("an outstanding observation intent must not be replayed")
    } catch RuntimeJobEngineError.jobNotRunnable {}

    let server = try startServer(owner())
    let shown = try cli(["job", "show", "--job", accepted.jobID], server: server)
    XCTAssertEqual(shown.0, 0)
    let detail = try object(XCTUnwrap(shown.1["result"]))
    let timeline = try object(XCTUnwrap(detail["timeline"]))
    guard case .array(let entries)? = timeline["entries"] else {
      return XCTFail("the bounded diagnostic must be inline in Job detail")
    }
    XCTAssertTrue(entries.contains(.string(diagnostic)))
    let page = try cli(["job", "timeline", "--job", accepted.jobID], server: server)
    XCTAssertEqual(page.0, 0)
    let pageFields = try object(XCTUnwrap(page.1["result"]))
    guard case .array(let items)? = pageFields["items"] else { return XCTFail("timeline page is absent") }
    XCTAssertTrue(try items.map(object).contains { $0["text"] == .string(diagnostic) })
    let readStatus = try cli(["job", "status", "--job", accepted.jobID], server: server)
    XCTAssertEqual(readStatus.0, 0)
    XCTAssertEqual(try object(XCTUnwrap(readStatus.1["result"]))["outcomeUnknown"], .bool(true))
    let afterReads = try DurableJournalRecovery.inspect(url: journal)
    XCTAssertEqual(afterReads.outstandingIntents, original.outstandingIntents)
    XCTAssertFalse(afterReads.events.contains { $0.correlatedIntentEventID == intent.eventID })
    XCTAssertEqual(dispatcher.dispatchCount, 3, "restart and every readback perform zero new dispatches")
  }

  func testCLIClientTimeoutAndConcurrentJobRunCannotCancelOrDuplicateTheJob() async throws {
    let gate = Gate()
    dispatcher.hold(gate)
    let owner = try owner()
    let server = try startServer(owner)
    let (code, result) = try cli(["agent", "run", "--execution-id", "execution-test",
      "--operation", "observe.device@1", "--timeout", "400ms"], server: server)
    XCTAssertEqual(code, 75)
    XCTAssertEqual(try object(XCTUnwrap(result["error"]))["code"], .string("clientTimeout"))
    let jobs = try await engine.listJobs()
    XCTAssertEqual(jobs.count, 1)
    let jobID = try XCTUnwrap(jobs.first?.jobID)
    let engine = engine!
    let joined = Task { try await engine.run(jobID: jobID) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(dispatcher.dispatchCount, 1)
    await gate.release()
    _ = try await joined.value
    let final = try await waitForJob(owner)
    XCTAssertEqual(final["jobState"], .string("succeeded"))
  }

  func testReviewedPlanMismatchIsTypedAndNeverCreatesAJob() async throws {
    let owner = try owner()
    let server = try startServer(owner)
    let (code, reply) = try cli(["agent", "run", "--operation", "observe.device@1",
      "--execution-id", "execution-test", "--reviewed-plan-digest", String(repeating: "a", count: 64)], server: server)
    XCTAssertEqual(code, 65)
    XCTAssertEqual(try object(XCTUnwrap(reply["error"]))["code"], .string("reviewedPlanMismatch"))
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testReceiptRecoveryCannotAttachAJobWithADifferentReviewedPlan() async throws {
    engine = try makeEngine(fault: .init { boundary in
      if boundary == .afterAdmission { throw AgentClientFixtureError.missingObject }
    })
    let owner = try owner()
    do { _ = try await owner.run(request()); XCTFail("fixture must interrupt publication") }
    catch AgentClientFixtureError.missingObject {}
    let store = try RuntimeAgentExecutionStore(directory: directory.appending(path: "executions"))
    let record = try XCTUnwrap(store.load("execution-test"))
    var submission = try ControlFrameJSON.decodeObject(XCTUnwrap(record.submissionRequest), maximumBytes: 4 * 1024 * 1024)
    submission["reviewedPlanDigest"] = .string(String(repeating: "a", count: 64))
    let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(submission))
    do { _ = try await engine.acceptedJobForAgent(bytes); XCTFail("existing admission is not proof of this reviewed precondition") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "reviewedPlanMismatch") }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testMissingCurrentIdentityCannotReachTheExecutionOwner() async throws {
    let owner = try owner()
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, agentExecutions: owner)
    let frame = try PortableCanonicalJSON.canonicalBytes(.object([
      "protocolVersion": .string("1.0.0"), "id": .string("retired-peer"),
      "method": .string("agent.run"), "params": .object(request()),
    ]))
    let response = await handler.handleFrame(frame)
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.error?.code, "unsupportedProtocolVersion")
    let page = try object(await owner.list(filters: [:], pageSize: 10, cursor: nil))
    XCTAssertEqual(page["items"], .array([]))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testUnreadableOwnerNeverBecomesANewExecution() async throws {
    port.setState("Unauthorized")
    let owner = try owner()
    _ = try await owner.run(request())
    let name = RuntimeAgentExecutionStore.fingerprint(Data("execution-test".utf8))
    let path = directory.appending(path: "executions/execution-\(name).json")
    var document = try ControlFrameJSON.decodeObject(Data(contentsOf: path), maximumBytes: 16 * 1024 * 1024)
    document["intentFingerprintSHA256"] = .string(String(repeating: "0", count: 64))
    try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)).write(to: path)
    do { _ = try await owner.run(request()); XCTFail("an unreadable record is not absence") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "recordUnreadable") }
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
