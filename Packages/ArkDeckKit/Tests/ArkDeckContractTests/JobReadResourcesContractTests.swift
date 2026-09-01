import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only fixtures exercise the actual Runtime, socket and CLI process.
/// They deliberately cannot count as real-device acceptance.
final class JobReadResourcesContractTests: XCTestCase {
  private var root: URL!
  private var engine: RuntimeJobEngine!
  private var artifacts: RuntimeArtifactStore!
  private var capabilities: RuntimeCapabilityStore!
  private var targets: RuntimeTargetStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private var server: AgentDaemonServer?
  private let clock = RuntimeAgentExecutionContractTests.Clock()
  private let date = "2026-08-31T12:00:00Z"
  private enum FixtureError: Error { case missing }
  private var state: URL { root.appending(path: "engine") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "jr-\(UUID().uuidString.prefix(8))")
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-08-31T12:00:00Z" })
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try makeEngine()
  }
  override func tearDownWithError() throws {
    server?.stop(); server = nil
    engine = nil; artifacts = nil; capabilities = nil; targets = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func makeEngine() throws -> RuntimeJobEngine {
    try RuntimeJobEngine(configuration: .init(stateDirectory: state),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(
        factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: clock))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { [clock] in RuntimeAgentTime.format(clock.now()) })
  }
  private func startServer() throws {
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler,
      nowUTC: { "2026-08-31T12:00:00Z" })
    _ = try server?.start()
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw FixtureError.missing }
    return fields
  }
  private func rows(_ page: [String: JSONValue]) throws -> [[String: JSONValue]] {
    guard case .array(let values)? = page["items"] else { throw FixtureError.missing }
    return try values.map(object)
  }
  @discardableResult
  private func seed(_ id: String, at: String? = nil, status: String = "succeeded", timeline: [String] = []) throws -> RuntimeJobRecord {
    let request = try RuntimeOperationRequest(requestID: "req-\(id)", idempotencyKey: "idem-\(id)",
      target: DurableTargetReference(targetID: "TGT-fixture", expectedBindingRevision: 1),
      operation: RuntimeOperationReference(id: "observe.device", version: 1), inputs: ["privateInput": .string("private-input-value")])
    var record = RuntimeJobRecord(jobID: id, request: request, operationReference: "observe.device@1",
      catalogDigest: RuntimeOperationCatalog.catalogDigest, providerID: "hdc", createdAtUTC: at ?? date,
      actualEffect: "readOnly", admissionEvidence: nil, materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil, materializedBindingRevision: 1)
    record.state = status; record.timeline = timeline
    record.outcomeUnknown = status == "waitingForRecovery"
    record.actualStepKinds = []
    _ = try RuntimeJobRepository(stateDirectory: state).admit(jobID: id, idempotencyKey: request.idempotencyKey,
      requestHash: String(repeating: "b", count: 64), initialState: status, createdAtUTC: record.createdAtUTC,
      initialRecordData: record.durableData())
    return record
  }
  private func save(_ record: RuntimeJobRecord) throws {
    try RuntimeJobRepository(stateDirectory: state).updateJobState(jobID: record.jobID, state: record.state,
      updatedAtUTC: date, recordData: record.durableData())
  }
  private func page(_ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
    try object(await engine.jobListSnapshot(RuntimeJobListQuery(params)))
  }
  private func read(_ method: String, id: String, version: String = "2.0.0") async throws -> AgentWireProtocol.Response {
    let request = try JSONDecoder().decode(AgentWireProtocol.Request.self,
      from: PortableCanonicalJSON.canonicalBytes(.object(["protocolVersion": .string(version), "id": .string("read-fixture"),
        "method": .string(method), "params": .object(["jobId": .string(id)])])))
    return await RuntimeJobResourceReader(engine: engine, artifactStore: artifacts).response(request)
  }
  private func cli(
    _ args: [String], outputArguments: [String] = ["--output", "json"]
  ) throws -> (Int32, [String: JSONValue]) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments =
      args + ["--socket", try XCTUnwrap(server).socketURL.path] + outputArguments
    let output = root.appending(path: "stdout-\(UUID()).json")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    process.standardOutput = handle; process.standardError = FileHandle.nullDevice
    try process.run()
    let end = Date().addingTimeInterval(20)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { process.terminate(); throw FixtureError.missing }
    try handle.close()
    return (process.terminationStatus, try object(CLIStrictJSON.decode(Data(contentsOf: output))))
  }
  private func publishRequired(_ id: String, target: String = "TGT-fixture", size: Int = 20) async throws -> [RuntimeArtifactMetadata] {
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "observe.device@1"))
    var values: [RuntimeArtifactMetadata] = []
    for declaration in descriptor.artifacts where declaration.isRequired {
      values.append(try await artifacts.publish(.init(jobID: id, sessionID: "session-\(id)", stepID: "fixture-probe",
        name: declaration.name, mediaType: declaration.mediaType, privacy: declaration.privacy,
        retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference, providerID: "hdc",
        bindingSnapshot: .init(targetID: target, bindingRevision: 1, stableIdentitySHA256: nil),
        contents: Data(String(repeating: "x", count: size).utf8))))
    }
    return values
  }

  func testRealCLIDefaultsPlanSubmitAndRunToTheTargetProtocol() async throws {
    let connectKey = "150100424a544e4600"
    let adopted = try targets.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: connectKey),
      connectKey: connectKey, toolVersion: "3.2.0f", nowUTC: date
    ).record
    try startServer()
    let requestArguments = [
      "--target", adopted.targetID, "--expected-binding-revision",
      String(adopted.bindingRevision),
      "--operation", "observe.device@1",
      "--request-id", "req-cli-v2-job-lifecycle",
      "--idempotency-key", "idem-cli-v2-job-lifecycle",
    ]

    let planned = try cli(["job", "plan"] + requestArguments)
    XCTAssertEqual(planned.0, 0, "\(planned.1)")
    guard planned.0 == 0 else { return }
    let plan = try object(XCTUnwrap(planned.1["result"]))
    XCTAssertEqual(plan["schemaVersion"], .string("arkdeck.job-plan/1"))
    XCTAssertEqual(plan["jobAdmitted"], .bool(false))
    XCTAssertEqual(
      try object(XCTUnwrap(planned.1["meta"]))["controlProtocolVersion"],
      .string("2.0.0"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let legacyPlan = try cli(
      ["job", "plan"] + requestArguments, outputArguments: ["--json"])
    XCTAssertEqual(legacyPlan.0, 0)
    XCTAssertNil(legacyPlan.1["schemaVersion"])
    XCTAssertEqual(
      legacyPlan.1["operationReference"], .string("observe.device@1"))
    XCTAssertNil(legacyPlan.1["ok"])
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let mixed = try cli(
      ["job", "submit", "--wait", "--require-protocol", "2"] + requestArguments)
    XCTAssertEqual(mixed.0, 64)
    XCTAssertEqual(
      try object(XCTUnwrap(mixed.1["error"]))["code"], .string("invalidOption"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let submitted = try cli(["job", "submit"] + requestArguments)
    XCTAssertEqual(submitted.0, 0)
    let acceptance = try object(XCTUnwrap(submitted.1["result"]))
    let jobID = try XCTUnwrap(CLIJobEventPage.string(acceptance["jobId"]))
    XCTAssertEqual(acceptance["schemaVersion"], .string("arkdeck.job-acceptance/1"))
    XCTAssertEqual(acceptance["deduplicated"], .bool(false))
    XCTAssertEqual(acceptance["newDispatchCount"], .integer(0))
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let ran = try cli(["job", "run", "--job", jobID])
    XCTAssertEqual(ran.0, 0)
    let status = try object(XCTUnwrap(ran.1["result"]))
    XCTAssertEqual(status["schemaVersion"], .string("arkdeck.job-status/1"))
    XCTAssertEqual(status["jobId"], .string(jobID))
    XCTAssertEqual(status["state"], .string("succeeded"))
    let dispatches = dispatcher.dispatchCount
    XCTAssertGreaterThan(dispatches, 0)

    let rerun = try cli(["job", "run", "--job", jobID])
    XCTAssertEqual(rerun.0, 65)
    XCTAssertEqual(
      try object(XCTUnwrap(rerun.1["error"]))["code"],
      .string("resourceConflict"))
    XCTAssertEqual(dispatcher.dispatchCount, dispatches)

    let duplicate = try cli(["job", "submit"] + requestArguments)
    XCTAssertEqual(duplicate.0, 0)
    let duplicateAcceptance = try object(XCTUnwrap(duplicate.1["result"]))
    XCTAssertEqual(duplicateAcceptance["jobId"], .string(jobID))
    XCTAssertEqual(duplicateAcceptance["deduplicated"], .bool(true))
    XCTAssertEqual(dispatcher.dispatchCount, dispatches)
  }

  func testCompletedTypedFixtureRunReadsVerifiedResultWithoutNewDispatch() async throws {
    let port = TargetObservationCoordinatorContractTests.Port()
    let clock = self.clock
    let observations = TargetObservationCoordinator(observation: port, targetStore: targets,
      usbRelations: { try port.relations() }, nowUTC: { RuntimeAgentTime.format(clock.now()) })
    let owner = try RuntimeAgentExecutionCoordinator(directory: root.appending(path: "executions"),
      engine: engine, targets: targets, observations: observations, now: { clock.now() })
    let response = try object(await owner.run(["schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string("read-execution"), "operation": .string("observe.device@1"), "inputs": .object([:]),
      "maximumWaitMilliseconds": .string("30000")]))
    let id = try XCTUnwrap(CLIJobEventPage.string(response["jobId"]))
    var finished = false
    for _ in 0..<400 {
      if try await engine.status(jobID: id).state == "succeeded" { finished = true; break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(finished)
    let dispatches = dispatcher.dispatchCount
    XCTAssertGreaterThan(dispatches, 0)
    try startServer()
    let result = try cli(["job", "result", "--job", id, "--require-protocol", "2"])
    XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1["ok"], .bool(true))
    let fields = try object(XCTUnwrap(result.1["result"]))
    let evidence = try object(XCTUnwrap(fields["evidence"]))
    XCTAssertEqual(evidence["status"], .string("verified"))
    XCTAssertEqual(dispatcher.dispatchCount, dispatches)
  }

  func testFixedJobSnapshotUsesTimeThenASCIIIdentityAndSurvivesUpdatesAndRestart() async throws {
    try seed("job-z", at: "2026-08-31T12:00:00Z")
    var changing = try seed("job-b", at: "2026-08-31T12:00:00.100Z", status: "queued")
    try seed("job-a", at: "2026-08-31T12:00:00.100Z")
    let first = try await page(["pageSize": .integer(1)])
    XCTAssertEqual(try rows(first).map { $0["jobId"] }, [.string("job-a")])
    XCTAssertEqual(first["order"], .string("createdAtDescJobIdAsc"))
    changing.state = "failed"; try save(changing)
    try seed("job-new", at: "2026-08-31T13:00:00Z")
    engine = try makeEngine()
    let second = try await page(["pageSize": .integer(1), "cursor": XCTUnwrap(first["nextCursor"])])
    XCTAssertEqual(second["snapshotRevision"], first["snapshotRevision"])
    XCTAssertEqual(try rows(second).first?["jobId"], .string("job-b"))
    XCTAssertEqual(try rows(second).first?["state"], .string("queued"))
    let last = try await page(["pageSize": .integer(1), "cursor": XCTUnwrap(second["nextCursor"])])
    XCTAssertEqual(try rows(last).first?["jobId"], .string("job-z"))
    XCTAssertEqual(last["nextCursor"], .null); XCTAssertEqual(last["hasMore"], .bool(false))
    let fresh = try await page()
    XCTAssertEqual(try rows(fresh).first?["jobId"], .string("job-new"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCursorIsBoundToEveryFilterOrderPageSizeAndMethod() async throws {
    try seed("job-a"); try seed("job-b")
    let first = try await page(["pageSize": .integer(1)])
    let cursor = try XCTUnwrap(first["nextCursor"])
    for changed: [String: JSONValue] in [
      ["state": .string("failed")], ["target": .string("other")], ["operation": .string("observe.server@1")],
      ["thread": .string("thread-other")], ["order": .string("createdAtAscJobIdAsc")],
      ["pageSize": .integer(2)], ["includeTimeline": .bool(true)], ["includeCurrent": .bool(true)],
    ] {
      do {
        _ = try await page(["pageSize": .integer(1), "cursor": cursor].merging(changed) { _, new in new })
        XCTFail("changed query must not reuse the cursor")
      } catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
    }
    do {
      _ = try await engine.jobTimelineSnapshot(jobID: "job-a", pageSize: 1, cursor: CLIJobEventPage.string(cursor))
      XCTFail("cursor must be method-bound")
    } catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
  }

  func testCLIQueriesKeepNonterminalHistoryAndTypedShowWithoutProviderLowering() async throws {
    try seed("job-pending", status: "queued", timeline: ["historical entry"])
    try seed("job-failed", status: "failed")
    try startServer()
    let listed = try cli(["job", "list", "--require-protocol", "2", "--include-current", "--include-timeline"])
    XCTAssertEqual(listed.0, 0)
    let page = try object(XCTUnwrap(listed.1["result"]))
    XCTAssertEqual(try rows(page).count, 2)
    let text = String(decoding: try PortableCanonicalJSON.canonicalBytes(.object(page)), as: UTF8.self)
    XCTAssertFalse(text.contains("private-input-value"))
    let shown = try cli(["job", "show", "--job", "job-pending"])
    XCTAssertEqual(shown.0, 0)
    let show = try object(XCTUnwrap(shown.1["result"]))
    let request = try object(XCTUnwrap(show["request"]))
    XCTAssertEqual(request["inputs"], .object(["privateInput": .string("private-input-value")]))
    XCTAssertNil(show["recoveryAction"]); XCTAssertNil(show["admissionEvidence"])
    XCTAssertEqual(show["events"], .object(["method": .string("job.events"), "jobId": .string("job-pending")]))
    let failed = try cli(["job", "status", "--job", "job-failed", "--require-protocol", "2"])
    XCTAssertEqual(failed.0, 0); XCTAssertEqual(failed.1["ok"], .bool(true))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testNonterminalResultIsNotReadyAndDoesNotStartTheJob() async throws {
    try seed("job-pending", status: "queued"); try startServer()
    let result = try cli(["job", "result", "--job", "job-pending", "--require-protocol", "2"])
    XCTAssertEqual(result.0, 75); XCTAssertEqual(result.1["ok"], .bool(false))
    XCTAssertEqual(try object(XCTUnwrap(result.1["error"]))["code"], .string("resultNotReady"))
    let evidence = try cli(["job", "evidence", "--job", "job-pending", "--require-protocol", "2"])
    XCTAssertEqual(evidence.0, 75); XCTAssertEqual(evidence.1["ok"], .bool(true))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testFailedResultRetainsProjectionWithExitOneAndEvidenceFailureWithExitTwo() async throws {
    try seed("job-failed", status: "failed")
    let metadata = try await publishRequired("job-failed")
    try startServer()
    let failed = try cli(["job", "result", "--job", "job-failed", "--require-protocol", "2"])
    XCTAssertEqual(failed.0, 1); XCTAssertEqual(failed.1["ok"], .bool(true))
    let result = try object(XCTUnwrap(failed.1["result"]))
    XCTAssertEqual(try object(XCTUnwrap(result["evidence"]))["status"], .string("verified"))
    let file = root.appending(path: "artifacts/job-failed/\(try XCTUnwrap(metadata.first).artifactID)")
    try FileManager.default.removeItem(at: file)
    let broken = try cli(["job", "result", "--job", "job-failed", "--require-protocol", "2"])
    XCTAssertEqual(broken.0, 2); XCTAssertEqual(broken.1["ok"], .bool(true))
    let retained = try object(XCTUnwrap(broken.1["result"]))
    XCTAssertEqual(try object(XCTUnwrap(retained["job"]))["outcome"], .string("failed"))
    XCTAssertEqual(try object(XCTUnwrap(retained["evidence"]))["status"], .string("artifactIntegrityFailed"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testMissingRequiredIndexEntryAndWrongArtifactOwnerCannotVerify() async throws {
    try seed("job-missing"); try seed("job-foreign")
    let metadata = try await publishRequired("job-missing")
    XCTAssertFalse(metadata.isEmpty)
    let index = root.appending(path: "artifacts/job-missing/index.json")
    var doc = try object(CLIStrictJSON.decode(Data(contentsOf: index)))
    doc["artifacts"] = .array([])
    try PortableCanonicalJSON.canonicalBytes(.object(doc)).write(to: index)
    let missing = try await read("job.evidence", id: "job-missing")
    XCTAssertTrue(missing.ok)
    XCTAssertEqual(try object(XCTUnwrap(missing.result))["status"], .string("artifactIntegrityFailed"))
    _ = try await publishRequired("job-foreign", target: "TGT-someone-else")
    let foreign = try await read("job.evidence", id: "job-foreign")
    XCTAssertEqual(try object(XCTUnwrap(foreign.result))["status"], .string("artifactIntegrityFailed"))
  }

  func testLargeArtifactVerificationAndSymlinkRefusal() async throws {
    try seed("job-large")
    let metadata = try await publishRequired("job-large", size: 2 * 1024 * 1024 + 13)
    let before = try await read("job.evidence", id: "job-large")
    XCTAssertEqual(try object(XCTUnwrap(before.result))["status"], .string("verified"))
    let payload = root.appending(path: "artifacts/job-large/\(try XCTUnwrap(metadata.first).artifactID)")
    let moved = root.appending(path: "foreign-payload")
    try FileManager.default.moveItem(at: payload, to: moved)
    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: moved)
    let linked = try await read("job.evidence", id: "job-large")
    XCTAssertEqual(try object(XCTUnwrap(linked.result))["status"], .string("artifactIntegrityFailed"))
  }

  func testCleanupReferenceIsExactAndUnreadableLedgerIsNotEmptySuccess() async throws {
    try seed("job-cleanup"); _ = try await publishRequired("job-cleanup")
    try await artifacts.recordCleanupDebt(jobID: "job-cleanup", stepID: "cleanup-fixture",
      remotePath: "/private/device/residue", reason: "fixture-private-reason")
    try startServer()
    let result = try cli(["job", "result", "--job", "job-cleanup", "--require-protocol", "2"])
    XCTAssertEqual(result.0, 0)
    let fields = try object(XCTUnwrap(result.1["result"]))
    let next = try object(XCTUnwrap(fields["nextAction"]))
    XCTAssertEqual(try object(XCTUnwrap(fields["job"]))["outstandingResidueCount"], .integer(1))
    XCTAssertEqual(next["kind"], .string("cleanup"))
    let encoded = String(decoding: try PortableCanonicalJSON.canonicalBytes(.object(fields)), as: UTF8.self)
    XCTAssertFalse(encoded.contains("/private/device/residue")); XCTAssertFalse(encoded.contains("fixture-private-reason"))
    try Data("{broken}".utf8).write(to: root.appending(path: "artifacts/cleanup-debt.json"))
    let unreadable = try cli(["job", "result", "--job", "job-cleanup", "--require-protocol", "2"])
    XCTAssertEqual(unreadable.1["ok"], .bool(false)); XCTAssertNil(unreadable.1["result"])
    XCTAssertEqual(try object(XCTUnwrap(unreadable.1["error"]))["code"], .string("recordUnreadable"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testLongUnicodeTimelineIsReferenceAndLosslessBoundedPages() async throws {
    let original = String(repeating: "中文🙂e\u{301}", count: 120_000)
    try seed("job-long", timeline: [original, "last entry"])
    let show = try await read("job.show", id: "job-long")
    let shown = try object(XCTUnwrap(show.result))
    XCTAssertEqual(try object(XCTUnwrap(shown["timeline"]))["kind"], .string("snapshotPages"))
    var cursor: String?
    var rebuilt = ["", ""]
    repeat {
      let page = try object(await engine.jobTimelineSnapshot(jobID: "job-long", pageSize: 3, cursor: cursor))
      XCTAssertLessThan(try PortableCanonicalJSON.canonicalBytes(.object(page)).count, 1024 * 1024)
      for row in try rows(page) {
        let index = try XCTUnwrap(CLIJobEventPage.decimal(row["entryIndex"]))
        rebuilt[Int(index)] += try XCTUnwrap(CLIJobEventPage.string(row["text"]))
      }
      cursor = CLIJobEventPage.string(page["nextCursor"])
    } while cursor != nil
    XCTAssertEqual(Array(rebuilt[0].utf8), Array(original.utf8)); XCTAssertEqual(rebuilt[1], "last entry")
    try startServer()
    let cliPage = try cli(["job", "timeline", "--job", "job-long", "--page-size", "3"])
    XCTAssertEqual(cliPage.0, 0)
  }

  func testUnknownOutcomeRemainsReconcileAndSuccessfulStatusQuery() async throws {
    var record = try seed("job-unknown", status: "interrupted")
    record.outcomeUnknown = true; try save(record)
    _ = try await publishRequired(record.jobID)
    try startServer()
    let status = try cli(["job", "status", "--job", record.jobID, "--require-protocol", "2"])
    XCTAssertEqual(status.0, 0)
    let result = try cli(["job", "result", "--job", record.jobID, "--require-protocol", "2"])
    XCTAssertEqual(result.0, 75); XCTAssertEqual(result.1["ok"], .bool(true))
    let fields = try object(XCTUnwrap(result.1["result"]))
    XCTAssertEqual(fields["outcomeUnknown"], .bool(true))
    XCTAssertEqual(try object(XCTUnwrap(fields["nextAction"]))["kind"], .string("reconcile"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLIDecoderRejectsUnknownSchemaAndForeignReferencesBeforeEmission() async throws {
    try seed("job-exact", timeline: [String(repeating: "x", count: 300_000)])
    let response = try await read("job.show", id: "job-exact")
    let valid = try object(XCTUnwrap(response.result))
    var rest = ["--output", "json"]
    let session = RuntimeCLI.runtimeSession(&rest, command: "job.show")
    for changed: [String: JSONValue] in [
      ["schemaVersion": .string("arkdeck.job/99")], ["futureField": .bool(true)],
      ["events": .object(["method": .string("job.events"), "jobId": .string("job-foreign")])],
      ["timeline": .object(["kind": .string("snapshotPages"), "method": .string("job.timeline"), "jobId": .string("job-foreign")])],
    ] {
      XCTAssertThrowsError(try CLIJobReadValidation.validate(.object(valid.merging(changed) { _, new in new }),
        verb: "show", jobID: "job-exact", options: [:], session: session)) { error in
        XCTAssertEqual((error as? CLIRegistryError)?.code, .recordUnreadable)
      }
    }
  }

  func testUnreadableAndOversizedRecordsFailBoundedAndLegacyResourcesStayFrozen() async throws {
    let record = try seed("job-corrupt")
    let repository = try RuntimeJobRepository(stateDirectory: state)
    try repository.updateJobState(jobID: record.jobID, state: record.state, updatedAtUTC: date, recordData: Data("{bad}".utf8))
    let corrupt = try await read("job.show", id: record.jobID)
    XCTAssertEqual(corrupt.error?.code, "recordUnreadable")
    try repository.updateJobState(jobID: record.jobID, state: record.state, updatedAtUTC: date,
      recordData: Data(repeating: 32, count: 16 * 1024 * 1024 + 1))
    let oversized = try await read("job.show", id: record.jobID)
    XCTAssertEqual(oversized.error?.code, "recordUnreadable")
    let legacy = try await read("job.show", id: record.jobID, version: "1.0.0")
    XCTAssertEqual(legacy.error?.code, "unknownMethod")
    let missing = try await read("job.show", id: "job-absent")
    XCTAssertEqual(missing.error?.code, "notFound")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
