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
    func hold(_ value: Gate) { lock.withLock { gate = value } }
    var dispatchCount: Int { lock.withLock { count } }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      let paused = lock.withLock { count += 1; let value = gate; gate = nil; return value }
      await paused?.enter()
      let output: String
      switch plan.action {
      case .hdc(.observeTool): output = "Ver: 3.2.0f\n"
      case .hdc(.observeServer): output = "Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n"
      case .hdc(.observeDevice), .hdc(.listDeviceCandidates): output = "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
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

  private func owner() throws -> RuntimeAgentExecutionCoordinator {
    let capturedPort = port!
    let capturedClock = clock!
    let observations = TargetObservationCoordinator(
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

  private func startServer(_ owner: RuntimeAgentExecutionCoordinator) throws -> AgentDaemonServer {
    let capturedClock = clock!
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities")),
      providerIDs: ["hdc"], nowUTC: { RuntimeAgentTime.format(capturedClock.now()) },
      targetStore: targets, agentExecutions: owner,
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
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
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
    let args = ["agent", "run", "--require-protocol", "2", "--execution-id", "execution-test", "--operation", "observe.device@1"]
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

  func testCLIClientTimeoutAndConcurrentJobRunCannotCancelOrDuplicateTheJob() async throws {
    let gate = Gate()
    dispatcher.hold(gate)
    let owner = try owner()
    let server = try startServer(owner)
    let (code, result) = try cli(["agent", "run", "--require-protocol", "2", "--execution-id", "execution-test",
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
    let (code, reply) = try cli(["agent", "run", "--require-protocol", "2", "--operation", "observe.device@1",
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
    var submission = try ControlProtocolNegotiation.decodeObject(XCTUnwrap(record.submissionRequest), maximumBytes: 4 * 1024 * 1024)
    submission["reviewedPlanDigest"] = .string(String(repeating: "a", count: 64))
    let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(submission))
    do { _ = try await engine.acceptedJobForAgent(bytes); XCTFail("existing admission is not proof of this reviewed precondition") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "reviewedPlanMismatch") }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testLegacyProtocolCannotReachTheNewExecutionOwner() async throws {
    let owner = try owner()
    let server = try startServer(owner)
    let legacy = AgentClient(socketPath: server.socketURL.path)
    do { _ = try legacy.request(method: "agent.run", params: request()); XCTFail("new resources must not change protocol 1") }
    catch let error as AgentClientError {
      guard case .daemonError(let code, _) = error else { return XCTFail("wrong legacy error") }
      XCTAssertEqual(code, "unknownMethod")
    }
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
    var document = try ControlProtocolNegotiation.decodeObject(Data(contentsOf: path), maximumBytes: 16 * 1024 * 1024)
    document["intentFingerprintSHA256"] = .string(String(repeating: "0", count: 64))
    try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document)).write(to: path)
    do { _ = try await owner.run(request()); XCTFail("an unreadable record is not absence") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "recordUnreadable") }
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
