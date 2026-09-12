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
  private func seed(_ id: String, at: String? = nil, status: String = "succeeded", timeline: [String] = [],
    target: String = "TGT-fixture", operation: String = "observe.device", thread: String? = nil
  ) throws -> RuntimeJobRecord {
    let request = try RuntimeOperationRequest(requestID: "req-\(id)", idempotencyKey: "idem-\(id)",
      target: DurableTargetReference(targetID: target, expectedBindingRevision: 1),
      operation: RuntimeOperationReference(id: operation, version: 1), inputs: ["privateInput": .string("private-input-value")],
      clientContext: thread.map { RuntimeClientContext(clientName: "job-list-oracle", threadID: $0) })
    var record = RuntimeJobRecord(jobID: id, request: request, operationReference: "\(operation)@1",
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

  /// Produce a disposable current SQLite fixture and native read responses for
  /// the Rust owner migration. No device, capability or journal is fabricated.
  func testRustJobOwnerCurrentSQLiteFixture() async throws {
    try seed("job-rust-a", timeline: ["native producer", "completed"])
    try seed("job-rust-b", status: "waitingForRecovery", timeline: ["outcome unknown; never replay"])
    let requests: [(String, [String: JSONValue])] = [
      ("job.status", ["jobId": .string("job-rust-a")]),
      ("job.show", ["jobId": .string("job-rust-a")]),
      ("job.status", ["jobId": .string("job-rust-b")]),
      ("job.list", ["includeTimeline": .bool(true)]),
      ("job.timeline", ["jobId": .string("job-rust-a")]),
    ]
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    var responses: [JSONValue] = []
    for (method, params) in requests {
      let response = await handler.handleFrame(try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("rust-job-owner-oracle"), "method": .string(method), "params": .object(params),
      ])))
      XCTAssertTrue(response.ok, "\(method): \(String(describing: response.error))")
      responses.append(.object(["method": .string(method), "params": .object(params),
        "result": try XCTUnwrap(response.result)]))
    }
    guard let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_FIXTURE_OUTPUT"] else { return }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    XCTAssertTrue(destination.path.hasPrefix("/private/tmp/"))
    guard destination.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: destination.path) else {
      throw FixtureError.missing
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    // The fixture is quiescent: all seed transactions and read responses above
    // finished. Preserve the complete SQLite/WAL/SHM set without checkpointing
    // or changing any bytes in the producer's state directory.
    try FileManager.default.copyItem(at: state, to: destination.appending(path: "jobs-state"))
    try PortableCanonicalJSON.canonicalBytes(.array(responses)).write(to: destination.appending(path: "swift-results.json"))
  }
  func testRustJobEventsCurrentFixture() async throws {
    let id = "job-rust-events"
    try seed(id)
    let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_EVENT_FIXTURE_OUTPUT"]
    var retainedState = state
    if let output {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: destination.path) else {
        throw FixtureError.missing
      }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      retainedState = destination.appending(path: "jobs-state")
      try FileManager.default.copyItem(at: state, to: retainedState)
      try Data("arkdeck.job-events-interop-fixture/1".utf8).write(to: destination.appending(path: "fixture-kind"))
    }
    let journal = try FileDurableJournal(url: retainedState.appending(path: "jobs/\(id)/journal.jsonl"))
    try journal.appendAndSynchronize(.jobCreated(eventID: "created", sequence: 0,
      sessionID: "session-\(id)", jobID: id, timestamp: date, executionMode: "execute"))
    for n in 1...4 {
      try journal.appendAndSynchronize(JournalEvent(eventID: "event-\(n)", sequence: n,
        sessionID: "session-\(id)", jobID: id, timestamp: date, kind: .warning,
        payload: ["code": .string("fixture"), "message": .string("sensitive fixture payload"), "details": .object([:])]))
    }
    let fixtureEngine = try RuntimeJobEngine(configuration: .init(stateDirectory: retainedState),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-08-31T12:00:00Z" })
    let handler = RuntimeControlPlaneHandler(engine: fixtureEngine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-08-31T12:00:00Z" }, artifactStore: artifacts)
    var samples: [JSONValue] = []
    var cursor: JSONValue?
    for size in [2, 3, 100] {
      var params: [String: JSONValue] = ["jobId": .string(id), "pageSize": .integer(Int64(size))]
      if let cursor { params["afterCursor"] = cursor }
      let response = await handler.handleFrame(try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("rust-event-owner-oracle"), "method": .string("job.events"), "params": .object(params),
      ])))
      XCTAssertTrue(response.ok, String(describing: response.error))
      let value = try XCTUnwrap(response.result)
      let parsed = try CLIJobEventPage(value, jobID: id, maximumItems: size)
      XCTAssertEqual(parsed.rows.count, size == 100 ? 0 : size)
      samples.append(.object(["method": .string("job.events"), "params": .object(params), "result": value]))
      cursor = .string(parsed.nextCursor)
    }
    if let output {
      try PortableCanonicalJSON.canonicalBytes(.array(samples)).write(to: URL(filePath: output).appending(path: "swift-results.json"))
    }
  }

  func testCurrentSwiftEventsReadActualRustCursor() throws {
    guard let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_EVENT_FIXTURE_OUTPUT"] else { return }
    let directory = URL(filePath: output)
    guard directory.path.hasPrefix("/private/tmp/"),
      try String(contentsOf: directory.appending(path: "fixture-kind"), encoding: .utf8) == "arkdeck.job-events-interop-fixture/1"
    else { throw FixtureError.missing }
    let result = try object(CLIStrictJSON.decode(Data(contentsOf: directory.appending(path: "rust-results.json"))))
    guard case .string(let cursor)? = result["nextCursor"] else { throw FixtureError.missing }
    let page = try CLIJobEventPage(JournalEventPages.page(directory: directory.appending(path: "jobs-state/jobs/job-rust-events"),
      jobID: "job-rust-events", sessionID: "session-job-rust-events", afterCursor: cursor, pageSize: 100),
      jobID: "job-rust-events", maximumItems: 100)
    XCTAssertEqual(page.rows.map { $0["eventId"] }, [.string("event-2"), .string("event-3"), .string("event-4")])
  }

  private func page(_ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
    try object(await engine.jobListSnapshot(RuntimeJobListQuery(params)))
  }
  private func read(_ method: String, id: String, version: String = ArkDeckControlProtocol.currentVersion) async throws -> AgentWireProtocol.Response {
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    return await handler.handleFrame(try PortableCanonicalJSON.canonicalBytes(.object([
      "protocolVersion": .string(version), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("read-fixture"), "method": .string(method), "params": .object(["jobId": .string(id)]),
    ])))
  }
  private func cli(
    _ args: [String], outputArguments: [String] = ["--output", "json"]
  ) throws -> (Int32, [String: JSONValue]) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments =
      args + ["--socket", try XCTUnwrap(server).socketURL.path] + outputArguments
    let output = root.appending(path: "stdout-\(UUID()).json")
    let errors = root.appending(path: "stderr-\(UUID()).txt")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    let errorHandle = try FileHandle(forWritingTo: errors)
    process.standardOutput = handle; process.standardError = errorHandle
    try process.run()
    let end = Date().addingTimeInterval(20)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { process.terminate(); throw FixtureError.missing }
    try handle.close()
    try errorHandle.close()
    let stdout = try Data(contentsOf: output)
    let stderr = try Data(contentsOf: errors)
    do {
      return (process.terminationStatus, try object(CLIStrictJSON.decode(stdout)))
    } catch {
      XCTFail(
        "CLI exited \(process.terminationStatus); stdout=\(String(decoding: stdout, as: UTF8.self)); "
          + "stderr=\(String(decoding: stderr, as: UTF8.self))")
      throw error
    }
  }
  private func publishRequired(
    _ id: String, target: String = "TGT-fixture", size: Int = 20,
    operationReference: String = "observe.device@1", providerID: String = "hdc",
    bindingRevision: Int = 1
  ) async throws -> [RuntimeArtifactMetadata] {
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: operationReference))
    var values: [RuntimeArtifactMetadata] = []
    for declaration in descriptor.artifacts where declaration.isRequired {
      values.append(try await artifacts.publish(.init(jobID: id, sessionID: "session-\(id)", stepID: "fixture-probe",
        name: declaration.name, mediaType: declaration.mediaType, privacy: declaration.privacy,
        retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference, providerID: providerID,
        bindingSnapshot: .init(targetID: target, bindingRevision: bindingRevision, stableIdentitySHA256: nil),
        contents: Data(String(repeating: "x", count: size).utf8))))
    }
    return values
  }

  func testWarmReadProjectionStillObservesChangedBytesAndRejectsCorruptionOrMetadataMismatch() async throws {
    var record = try seed("job-warm-read", timeline: ["before"])
    _ = try await engine.jobReadSnapshot(jobID: record.jobID)
    _ = try await page()
    record.timeline = ["after"]
    try save(record)
    let changed = try await engine.jobReadSnapshot(jobID: record.jobID)
    XCTAssertEqual(changed.record.timeline, ["after"])
    let changedRows = try rows(await page(["includeTimeline": .bool(true)]))
    XCTAssertEqual(changedRows.first?["timeline"], .object([
      "kind": .string("inline"), "entries": .array([.string("after")])]))

    let repository = try RuntimeJobRepository(stateDirectory: state)
    // Same record bytes, conflicting current row metadata: a warm hit cannot
    // bypass the existing row/record coherence guard.
    try repository.updateJobState(jobID: record.jobID, state: "failed",
      updatedAtUTC: date, recordData: record.durableData())
    let mismatched = try await read("job.status", id: record.jobID)
    XCTAssertEqual(mismatched.error?.code, "recordUnreadable")
    do { _ = try await page(); XCTFail("list accepted mismatched row metadata") }
    catch RuntimeJobEngineError.jobRecordUnreadable { }
    try save(record)
    _ = try await engine.jobReadSnapshot(jobID: record.jobID)

    try repository.updateJobState(jobID: record.jobID, state: record.state,
      updatedAtUTC: date, recordData: Data("not-json".utf8))
    let corrupted = try await read("job.status", id: record.jobID)
    XCTAssertEqual(corrupted.error?.code, "recordUnreadable")
    do { _ = try await page(); XCTFail("list accepted corrupted current bytes") }
    catch RuntimeJobEngineError.jobRecordUnreadable { }
    try save(record)
    let restored = try await engine.jobReadSnapshot(jobID: record.jobID)
    XCTAssertEqual(restored.record.timeline, ["after"])
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testReadProjectionRemainsFreshAfterWorkingSetExceedsCacheCapacity() async throws {
    var first = try seed("job-cache-first", timeline: ["original"])
    _ = try await engine.jobReadSnapshot(jobID: first.jobID)
    for index in 0..<130 {
      let record = try seed("job-cache-\(index)")
      _ = try await engine.jobReadSnapshot(jobID: record.jobID)
    }
    first.timeline = ["changed after eviction"]
    try save(first)
    let current = try await engine.jobReadSnapshot(jobID: first.jobID)
    XCTAssertEqual(current.record.timeline, first.timeline)
    let newReader = try makeEngine()
    let durable = try await newReader.jobReadSnapshot(jobID: first.jobID)
    XCTAssertEqual(durable.record.timeline, first.timeline)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  /// A refusal has to say which Job, and a store has to be enumerable.
  ///
  /// The read surface keeps failing on a record this build cannot decode — that
  /// contract is pinned by three tests and is not touched here. What it failed
  /// with was a bare `recordUnreadable` and "the Job read resource is
  /// unreadable": the same amount of information for one rotted row as for a
  /// whole store an earlier build wrote. The engine knew the Job id; the wire
  /// discarded it.
  ///
  /// `doctor` named only what start-up recovery walked, and that query excludes
  /// terminal states — so the terminal majority, which is what an operator
  /// meets first because any one of them refuses a History page, was named
  /// nowhere. `--deep` now counts the whole ledger and names a bounded sample.
  func testAnUnreadableRecordIsNamedByTheWireErrorAndCountedByDeepDoctor() async throws {
    let broken = try seed("job-unreadable-named", at: "2026-08-31T11:30:00Z")
    try RuntimeJobRepository(stateDirectory: state).updateJobState(
      jobID: broken.jobID, state: broken.state, updatedAtUTC: date,
      recordData: Data("not-json".utf8))

    let refused = try await read("job.status", id: broken.jobID)
    XCTAssertFalse(refused.ok, "the read still fails; only its message improves")
    XCTAssertEqual(refused.error?.code, "recordUnreadable")
    XCTAssertTrue(
      refused.error?.message.contains(broken.jobID) == true,
      "the refusal must name the Job: \(refused.error?.message ?? "")")
    XCTAssertNil(
      refused.error?.details,
      "the id goes in the message; the published error shape is unchanged")

    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
      nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    func doctor(deep: Bool) async throws -> [[String: JSONValue]] {
      let response = await handler.handleFrame(
        try PortableCanonicalJSON.canonicalBytes(
          .object([
            "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
            "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
            "id": .string("doctor-fixture"), "method": .string("doctor"),
            "params": .object(["deep": .bool(deep)]),
          ])))
      guard case .object(let report)? = response.result,
        case .array(let findings)? = report["findings"]
      else { throw FixtureError.missing }
      return findings.compactMap {
        guard case .object(let fields) = $0,
          fields["code"] == .string("runtime.durableRecordsUnreadable")
        else { return nil }
        return fields
      }
    }

    let counted = try await doctor(deep: true)
    guard let finding = counted.first else {
      return XCTFail("deep doctor must count the whole ledger, not only the active set")
    }
    XCTAssertEqual(finding["severity"], .string("blocker"))
    // The count and the named record live in the summary, not in `details`:
    // `spec/control/methods/doctor.json` publishes finding details as a closed
    // set of five counters, so a finding that needs to say more says it in the
    // one published free-form field rather than widening the wire contract.
    guard case .string(let summary)? = finding["summary"] else {
      return XCTFail("a finding must carry its summary")
    }
    XCTAssertTrue(summary.hasPrefix("1 durable Job records"), summary)
    XCTAssertTrue(summary.contains(broken.jobID), summary)
    XCTAssertNil(finding["details"])

    // The whole-ledger scan is a deep probe; a shallow report is unchanged.
    let shallow = try await doctor(deep: false)
    XCTAssertTrue(shallow.isEmpty)
  }

  /// The guard that would have caught this class earlier only runs when a
  /// contract-test run is recording frames, so a finding that emits a field the
  /// method never published reaches `main` unremarked. This one always runs:
  /// `spec/control/methods/doctor.json` publishes finding `details` as a closed
  /// object, and everything the daemon can put there has to be inside it.
  func testEveryDoctorFindingStaysInsideThePublishedDetailContract() async throws {
    let broken = try seed("job-detail-contract", at: "2026-08-31T11:30:00Z")
    try RuntimeJobRepository(stateDirectory: state).updateJobState(
      jobID: broken.jobID, state: broken.state, updatedAtUTC: date,
      recordData: Data("not-json".utf8))

    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let document = try JSONSerialization.jsonObject(
      with: Data(contentsOf: repository.appending(path: "spec/control/methods/doctor.json")))
    guard let published = Self.publishedDetailKeys(document) else {
      return XCTFail("doctor.json must publish a closed finding detail object")
    }

    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
      nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    for deep in [false, true] {
      let response = await handler.handleFrame(
        try PortableCanonicalJSON.canonicalBytes(
          .object([
            "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
            "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
            "id": .string("doctor-details"), "method": .string("doctor"),
            "params": .object(["deep": .bool(deep)]),
          ])))
      guard case .object(let report)? = response.result,
        case .array(let findings)? = report["findings"]
      else { return XCTFail("doctor must answer with its versioned report") }
      for finding in findings {
        guard case .object(let fields) = finding else { continue }
        guard case .object(let details)? = fields["details"] else { continue }
        let unpublished = Set(details.keys).subtracting(published)
        XCTAssertTrue(
          unpublished.isEmpty,
          "finding \(fields["code"] ?? .null) publishes detail keys doctor.json forbids: "
            + "\(unpublished.sorted())")
      }
    }
  }

  /// Reads the one closed `details` object out of the published doctor schema
  /// without a full JSON Schema walk: the document has exactly one.
  private static func publishedDetailKeys(_ document: Any) -> Set<String>? {
    if let object = document as? [String: Any] {
      if let details = object["details"] as? [String: Any],
        details["additionalProperties"] as? Bool == false,
        let properties = details["properties"] as? [String: Any]
      {
        return Set(properties.keys)
      }
      for value in object.values {
        if let found = publishedDetailKeys(value) { return found }
      }
    }
    if let array = document as? [Any] {
      for value in array {
        if let found = publishedDetailKeys(value) { return found }
      }
    }
    return nil
  }

  func testCurrentHistoryRejectsRetiredCreationSentinelAndTimestampDrift() async throws {
    try admitVerifiedRow("job-current", createdAtColumn: date)
    XCTAssertThrowsError(try admitVerifiedRow("job-legacy", createdAtColumn: "legacy"))
    let listed = try rows(await page()).compactMap { row -> String? in
      guard case .string(let id)? = row["jobId"] else { return nil }
      return id
    }
    XCTAssertEqual(listed, ["job-current"])
    let admission = try RuntimeAdmissionService(stateDirectory: state)
    // Any other disagreement between the column and the record is still a
    // corrupt row, not history.
    try admitVerifiedRow("job-drifted", createdAtColumn: "2026-01-01T00:00:00Z")
    do {
      _ = try await page()
      XCTFail("a row whose creation column drifts from its record must stay unreadable")
    } catch let error as RuntimeJobEngineError {
      guard case .jobRecordUnreadable(let id) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(id, "job-drifted")
    }
    XCTAssertThrowsError(try admission.requireNoActiveWorkspacePresetReference("preset-fixture"))
    XCTAssertThrowsError(try admission.requireNoActiveImportReference("imp-fixture"))
  }

  /// Admits a row whose request hash is the record's real submission
  /// fingerprint, so the durable-history scans can verify it exactly as they
  /// verify a row the Runtime admitted itself.
  private func admitVerifiedRow(
    _ id: String, recordCreatedAtUTC: String? = nil, createdAtColumn: String,
    jobState: String = "succeeded", outcomeUnknown: Bool = false,
    providerID: String = "hdc", operation: String = "observe.device@1",
    catalogDigest: String = RuntimeOperationCatalog.catalogDigest,
    inputs: [String: JSONValue] = [:]
  ) throws {
    let parts = operation.split(separator: "@")
    let request = try RuntimeOperationRequest(requestID: "req-\(id)", idempotencyKey: "idem-\(id)",
      target: DurableTargetReference(targetID: "TGT-fixture", expectedBindingRevision: 1),
      operation: RuntimeOperationReference(id: String(parts[0]), version: Int(parts[1])!), inputs: inputs)
    var record = RuntimeJobRecord(jobID: id, request: request, operationReference: operation,
      catalogDigest: catalogDigest, providerID: providerID,
      createdAtUTC: recordCreatedAtUTC ?? date,
      actualEffect: "readOnly", admissionEvidence: nil, materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil, materializedBindingRevision: 1)
    record.state = jobState; record.actualStepKinds = []; record.outcomeUnknown = outcomeUnknown
    let fingerprint = SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(request))
    _ = try RuntimeJobRepository(stateDirectory: state).admit(
      jobID: id, idempotencyKey: request.idempotencyKey, requestHash: fingerprint,
      initialState: jobState, createdAtUTC: createdAtColumn,
      initialRecordData: record.durableData())
  }

  func testNonterminalRowsFromAnotherCatalogDigestBlockOnlyWhatTheyReference() throws {
    // A Job admitted under another Catalog digest that never reached a
    // terminal state (an unrecoverable flash, say) has no descriptor in this
    // build. Its provider and inputs are still durable: a flash Job cannot
    // hold a workspace registration, and a lease-shaped input still holds its
    // Import. Neither scan may fail closed on such a row.
    let stale = String(repeating: "0", count: 64)
    let flashImport = "imp-0f5c1d2e-3a4b-4c5d-8e6f-70a1b2c3d4e5"
    let patchImport = "imp-1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    try admitVerifiedRow(
      "job-stale-flash", createdAtColumn: date, jobState: "waitingForRecovery",
      outcomeUnknown: true, providerID: "rockchip", operation: "flash.dayu200@1",
      catalogDigest: stale,
      inputs: ["imageArtifactLease": .string("lease-v1:\(flashImport):ART-" + String(repeating: "1", count: 32))])
    try admitVerifiedRow(
      "job-stale-patch", createdAtColumn: date, jobState: "waitingForRecovery",
      outcomeUnknown: true, providerID: "workspace", operation: "workspace.apply-patch@1",
      catalogDigest: stale,
      inputs: [
        "projectRef": .string("demo-app"),
        "patchArtifactRef": .string("lease-v1:\(patchImport):ART-" + String(repeating: "2", count: 32)),
        "allowedFileGlobs": .array([.string("entry/**")]),
      ])
    try admitVerifiedRow(
      "job-stale-build", createdAtColumn: date, jobState: "waitingForRecovery",
      outcomeUnknown: true, providerID: "workspace", operation: "workspace.build-openharmony@1",
      catalogDigest: stale,
      inputs: ["projectRef": .string("other-project"), "buildPresetRef": .string("preset-fixture")])

    let admission = try RuntimeAdmissionService(stateDirectory: state)
    XCTAssertThrowsError(try admission.requireNoActiveWorkspaceProjectReference("demo-app")) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }
    XCTAssertNoThrow(try admission.requireNoActiveWorkspaceProjectReference("untouched-project"))
    XCTAssertThrowsError(try admission.requireNoActiveWorkspacePresetReference("preset-fixture")) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }
    XCTAssertNoThrow(try admission.requireNoActiveWorkspacePresetReference("preset-untouched"))
    XCTAssertThrowsError(try admission.requireNoActiveImportReference(flashImport)) { error in
      XCTAssertEqual((error as? AgentExecutionControlFailure)?.code, "resourceConflict")
    }
    XCTAssertThrowsError(try admission.requireNoActiveImportReference(patchImport))
    XCTAssertNoThrow(try admission.requireNoActiveImportReference("imp-9999aaaa-bbbb-4ccc-8ddd-eeeeffff0000"))
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
      .string(ArkDeckControlProtocol.currentVersion))
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let legacyPlan = try cli(
      ["job", "plan"] + requestArguments, outputArguments: ["--json"])
    XCTAssertEqual(legacyPlan.0, 0)
    XCTAssertEqual(legacyPlan.1["schemaVersion"], .string("arkdeck.job-plan/1"))
    XCTAssertEqual(legacyPlan.1, plan, "--json only changes the envelope rendering")
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
    let result = try cli(["job", "result", "--job", id])
    XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1["ok"], .bool(true))
    let fields = try object(XCTUnwrap(result.1["result"]))
    let evidence = try object(XCTUnwrap(fields["evidence"]))
    XCTAssertEqual(evidence["status"], .string("verified"))
    XCTAssertEqual(dispatcher.dispatchCount, dispatches)
  }

  func testWorkspaceContinuationRunsThroughRealCLIAndUDSAndAProcessRetryDoesNotRedispatch()
    async throws
  {
    let port = TargetObservationCoordinatorContractTests.Port()
    let clock = self.clock
    let observations = TargetObservationCoordinator(
      observation: port, targetStore: targets, usbRelations: { try port.relations() },
      nowUTC: { RuntimeAgentTime.format(clock.now()) })
    let owner = try RuntimeAgentExecutionCoordinator(
      directory: root.appending(path: "continuation-executions"),
      engine: engine, targets: targets, observations: observations,
      now: { clock.now() })
    let source = try object(await owner.run([
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string("continuation-source-execution"),
      "operation": .string("observe.device@1"),
      "inputs": .object([:]),
      "maximumWaitMilliseconds": .string("30000"),
    ]))
    let sourceJobID = try XCTUnwrap(CLIJobEventPage.string(source["jobId"]))
    var sourceFinished = false
    for _ in 0..<400 {
      if try await engine.status(jobID: sourceJobID).state == "succeeded" {
        sourceFinished = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(sourceFinished)
    try startServer()

    let inspectEnvelope = try cli([
      "workspace", "continuation", "inspect", "--source-job", sourceJobID,
    ])
    XCTAssertEqual(inspectEnvelope.0, 0, "\(inspectEnvelope.1)")
    XCTAssertEqual(inspectEnvelope.1["ok"], .bool(true), "\(inspectEnvelope.1)")
    let inspected = try object(XCTUnwrap(inspectEnvelope.1["result"]))
    XCTAssertEqual(inspected["schemaVersion"], .string("arkdeck.workspace-continuation/1"))
    XCTAssertEqual(inspected["sourceJobId"], .string(sourceJobID))
    XCTAssertEqual(inspected["operation"], .string("observe.device@1"))
    XCTAssertEqual(inspected["effectiveEffect"], .string("readOnly"))
    XCTAssertEqual(inspected["jobId"], .null)
    XCTAssertEqual(inspected["dispatched"], .bool(false))

    let dispatchesBeforeContinuation = dispatcher.dispatchCount
    let continuationID = "continuation-cli-uds-001"
    let firstEnvelope = try cli([
      "workspace", "continuation", "run", "--source-job", sourceJobID,
      "--continuation-request-id", continuationID,
    ])
    XCTAssertEqual(firstEnvelope.0, 0, "\(firstEnvelope.1)")
    XCTAssertEqual(firstEnvelope.1["ok"], .bool(true), "\(firstEnvelope.1)")
    let first = try object(XCTUnwrap(firstEnvelope.1["result"]))
    XCTAssertEqual(first["continuationRequestId"], .string(continuationID))
    XCTAssertEqual(first["deduplicated"], .bool(false))
    XCTAssertEqual(first["dispatched"], .bool(true))
    let continuationJobID = try XCTUnwrap(CLIJobEventPage.string(first["jobId"]))
    XCTAssertNotEqual(continuationJobID, sourceJobID)
    XCTAssertGreaterThan(dispatcher.dispatchCount, dispatchesBeforeContinuation)
    let dispatchesAfterFirstRun = dispatcher.dispatchCount

    let retryEnvelope = try cli([
      "workspace", "continuation", "run", "--source-job", sourceJobID,
      "--continuation-request-id", continuationID,
    ])
    XCTAssertEqual(retryEnvelope.0, 0, "\(retryEnvelope.1)")
    XCTAssertEqual(retryEnvelope.1["ok"], .bool(true), "\(retryEnvelope.1)")
    let retry = try object(XCTUnwrap(retryEnvelope.1["result"]))
    XCTAssertEqual(retry["jobId"], .string(continuationJobID))
    XCTAssertEqual(retry["deduplicated"], .bool(true))
    XCTAssertEqual(retry["dispatched"], .bool(false))
    XCTAssertEqual(dispatcher.dispatchCount, dispatchesAfterFirstRun)
  }

  /// Records the actual control-plane producer, including filters previously
  /// exercised only through direct engine calls. Fixture ledger rows grant no
  /// execution authority, and every read must leave dispatch count at zero.
  func testJobListFilterProducerFramesAndBoundedRefusals() async throws {
    try seed("job-filter-a", thread: "thread-a")
    try seed("job-filter-b", status: "failed", target: "TGT-other", operation: "observe.server", thread: "thread-b")
    try seed("job-filter-c", thread: "thread-a")
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    func list(_ params: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      await handler.handleFrame(try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("job-list-filter-oracle"), "method": .string("job.list"), "params": .object(params),
      ])))
    }
    for (key, value, expected): (String, String, [String]) in [
      ("state", "failed", ["job-filter-b"]),
      ("operation", "observe.server@1", ["job-filter-b"]),
      ("target", "TGT-other", ["job-filter-b"]),
      ("thread", "thread-a", ["job-filter-a", "job-filter-c"]),
      ("operation", "observe.absent@1", []), ("target", "TGT-absent", []), ("thread", "thread-absent", []),
    ] {
      let response = try await list([key: .string(value)])
      XCTAssertTrue(response.ok, response.error?.message ?? key)
      XCTAssertEqual(try rows(object(XCTUnwrap(response.result))).map { $0["jobId"] }, expected.map(JSONValue.string))
    }
    let filters: [String: JSONValue] = ["state": .string("succeeded"), "operation": .string("observe.device@1"),
      "target": .string("TGT-fixture"), "thread": .string("thread-a"), "pageSize": .integer(1)]
    let first = try await list(filters)
    XCTAssertTrue(first.ok)
    let firstPage = try object(XCTUnwrap(first.result))
    let cursor = try XCTUnwrap(firstPage["nextCursor"])
    let next = try await list(filters.merging(["cursor": cursor]) { _, new in new })
    XCTAssertTrue(next.ok)
    XCTAssertEqual(try rows(object(XCTUnwrap(next.result))).map { $0["jobId"] }, [.string("job-filter-c")])
    for (key, value) in [("state", "failed"), ("operation", "observe.server@1"),
      ("target", "TGT-other"), ("thread", "thread-b")] {
      let refused = try await list(filters.merging(["cursor": cursor, key: .string(value)]) { _, new in new })
      XCTAssertEqual(refused.error?.code, "invalidCursor", key)
    }
    for key in ["state", "operation", "target", "thread"] {
      for value: JSONValue in [.integer(1), .null, .string(""), .string(String(repeating: "x", count: 257)),
        .string("contains\nnewline"), .string("contains\u{7f}delete")] {
        let refused = try await list([key: value])
        XCTAssertEqual(refused.error?.code, "invalidInput", key)
      }
    }
    let unknownState = try await list(["state": .string("unpublished-state")])
    XCTAssertEqual(unknownState.error?.code, "invalidInput")
    for params: [String: JSONValue] in [
      ["order": .string("wrong")], ["pageSize": .integer(0)], ["pageSize": .integer(1001)],
      ["includeCurrent": .string("true")], ["includeTimeline": .string("true")],
    ] {
      let refused = try await list(params)
      XCTAssertEqual(refused.error?.code, "invalidInput")
    }
    for token in ["", "malformed-token", String(repeating: "x", count: 2049)] {
      let refused = try await list(["cursor": .string(token)])
      XCTAssertEqual(refused.error?.code, "invalidCursor")
    }
    try seed("job-filter-large-timeline", timeline: [String(repeating: "x", count: 270_000)], thread: "thread-large")
    let largeTimeline = try await list(["thread": .string("thread-large"), "includeTimeline": .bool(true)])
    XCTAssertTrue(largeTimeline.ok)
    XCTAssertEqual(try rows(object(XCTUnwrap(largeTimeline.result))).first?["timeline"], .object([
      "kind": .string("snapshotPages"), "jobId": .string("job-filter-large-timeline"), "method": .string("job.timeline"),
    ]))
    let corrupted = try seed("job-filter-corrupt")
    try RuntimeJobRepository(stateDirectory: state).updateJobState(jobID: corrupted.jobID,
      state: corrupted.state, updatedAtUTC: date, recordData: Data("not-json".utf8))
    let refused = try await list(["state": .string("succeeded")])
    XCTAssertEqual(refused.error?.code, "recordUnreadable")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
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
    let listed = try cli(["job", "list", "--include-current", "--include-timeline"])
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
    let failed = try cli(["job", "status", "--job", "job-failed"])
    XCTAssertEqual(failed.0, 0); XCTAssertEqual(failed.1["ok"], .bool(true))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testNonterminalResultIsNotReadyAndDoesNotStartTheJob() async throws {
    try seed("job-pending", status: "queued"); try startServer()
    let result = try cli(["job", "result", "--job", "job-pending"])
    XCTAssertEqual(result.0, 75); XCTAssertEqual(result.1["ok"], .bool(false))
    XCTAssertEqual(try object(XCTUnwrap(result.1["error"]))["code"], .string("resultNotReady"))
    let evidence = try cli(["job", "evidence", "--job", "job-pending"])
    XCTAssertEqual(evidence.0, 75); XCTAssertEqual(evidence.1["ok"], .bool(true))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testFailedResultRetainsProjectionWithExitOneAndEvidenceFailureWithExitTwo() async throws {
    try seed("job-failed", status: "failed")
    let metadata = try await publishRequired("job-failed")
    try startServer()
    let failed = try cli(["job", "result", "--job", "job-failed"])
    XCTAssertEqual(failed.0, 1); XCTAssertEqual(failed.1["ok"], .bool(true))
    let result = try object(XCTUnwrap(failed.1["result"]))
    XCTAssertEqual(try object(XCTUnwrap(result["evidence"]))["status"], .string("verified"))
    let file = root.appending(path: "artifacts/job-failed/\(try XCTUnwrap(metadata.first).artifactID)")
    try FileManager.default.removeItem(at: file)
    let broken = try cli(["job", "result", "--job", "job-failed"])
    XCTAssertEqual(broken.0, 2); XCTAssertEqual(broken.1["ok"], .bool(true))
    let retained = try object(XCTUnwrap(broken.1["result"]))
    XCTAssertEqual(try object(XCTUnwrap(retained["job"]))["outcome"], .string("failed"))
    XCTAssertEqual(try object(XCTUnwrap(retained["evidence"]))["status"], .string("artifactIntegrityFailed"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  private static func strings(_ value: JSONValue?) -> [String] {
    guard case .array(let values)? = value else { return [] }
    return values.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
  }

  @discardableResult
  private func seedUnprovableFlash(_ id: String, jobState: String = "waitingForRecovery") throws -> RuntimeJobRecord {
    // A Flash Job parked in `waitingForRecovery`: its journal is by definition
    // not closed, so the typed step kinds cannot be derived from durable state.
    // Everything else about the Job is on disk and readable.
    let request = try RuntimeOperationRequest(
      requestID: "req-\(id)", idempotencyKey: "idem-\(id)",
      target: DurableTargetReference(targetID: "TGT-fixture", expectedBindingRevision: 2),
      operation: RuntimeOperationReference(id: "flash.full-restore", version: 1))
    var record = RuntimeJobRecord(
      jobID: id, request: request, operationReference: ArkForgeFlashOperation.canonicalReference,
      catalogDigest: RuntimeOperationCatalog.catalogDigest, providerID: "arkforge",
      createdAtUTC: date, actualEffect: "destructive", admissionEvidence: nil,
      materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil, materializedBindingRevision: 2)
    record.state = jobState
    record.outcomeUnknown = jobState == "waitingForRecovery"
    _ = try RuntimeJobRepository(stateDirectory: state).admit(
      jobID: id, idempotencyKey: request.idempotencyKey,
      requestHash: String(repeating: "b", count: 64), initialState: record.state,
      createdAtUTC: record.createdAtUTC, initialRecordData: record.durableData())

    // A terminal Flash Job cannot carry an unresolved intent — the journal
    // refuses to finalize one ("unresolved intent cannot enter finalization or
    // terminal state"). So the terminal route to unprovable steps is a journal
    // that is gone, and the fixture leaves none.
    guard jobState == "waitingForRecovery" else { return record }

    // A real journal with a destructive intent and no outcome behind it: the
    // shape a Flash Job that stopped mid-write actually leaves on disk.
    let directory = state.appending(path: "jobs/\(id)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let journal = try FileDurableJournal(url: directory.appending(path: "journal.jsonl"))
    try journal.appendAndSynchronize(
      try JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: "session-\(id)", jobID: id,
        timestamp: date, executionMode: "execute"))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "preflight", sequence: 1, sessionID: "session-\(id)", jobID: id,
        timestamp: date, from: .queued, to: .preflight, reason: "fixture"))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "running", sequence: 2, sessionID: "session-\(id)", jobID: id,
        timestamp: date, from: .preflight, to: .running, reason: "fixture"))
    try journal.appendAndSynchronize(
      try JournalEvent.stepIntent(
        eventID: "intent-flash-partitions", sequence: 3, sessionID: "session-\(id)",
        jobID: id, timestamp: date,
        step: try WorkflowStep(
          id: "flash-partitions", kind: .flashPartition, declaredEffect: .destructive,
          declaredCancellation: .criticalNonInterruptible,
          declaredBindingRequirement: .confirmedDevice,
          arguments: [
            "providerOperationId": .string("flashPartitions"),
            "partition": .string("userdata"), "imageArtifactId": .string("image-bundle"),
            "imageSha256": .string(String(repeating: "c", count: 64)), "imageSize": .integer(1),
            "confirmationId": .string("runtime-capability"),
            "safeBoundaryId": .string("complete-overwrite"),
          ]),
        target: JournalTarget(
          scope: "device", targetID: "TGT-fixture", connectKey: "fixture-only",
          identitySnapshotHash: String(repeating: "d", count: 64)),
        attempt: 1, bindingRevision: 2))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "waiting", sequence: 4, sessionID: "session-\(id)", jobID: id,
        timestamp: date, from: .running, to: .waitingForRecovery,
        reason: "outcome unknown"))
    XCTAssertFalse(
      try DurableJournalRecovery.inspect(url: directory.appending(path: "journal.jsonl"))
        .outstandingIntents.isEmpty,
      "the fixture must leave the journal genuinely unclosed")
    return record
  }

  /// Measured on the 2026-09-07 GJ-4 window: `job.evidence` for the flash Job
  /// that had stopped in `waitingForRecovery` answered with every field null,
  /// which no client could decode, so the terminal reason the Runtime had
  /// actually recorded reached no published surface at all. One underivable
  /// fact — the typed step kinds of an unclosed Flash journal — was throwing,
  /// and the throw took the whole readable snapshot with it. The unknown fact
  /// stays unknown; the facts durable state does hold get published.
  func testAFlashJobWithAnUnprovableJournalStillPublishesTheFactsItHolds() async throws {
    try seedUnprovableFlash("job-unprovable-flash")

    let response = try await read("job.evidence", id: "job-unprovable-flash")
    XCTAssertTrue(response.ok)
    let fields = try object(XCTUnwrap(response.result))

    XCTAssertEqual(fields["providerId"], .string("arkforge"))
    XCTAssertEqual(fields["executionMode"], .string("execute"))
    XCTAssertEqual(fields["terminalState"], .string("outcomeUnknown"))
    XCTAssertEqual(fields["outcomeUnknown"], .bool(true))
    XCTAssertEqual(fields["targetId"], .string("TGT-fixture"))
    // The one fact durable state cannot prove says so, rather than claiming
    // an empty step list that would read as "nothing ran".
    XCTAssertEqual(fields["actualStepKinds"], .null)

    // The client decoder is the surface that failed in the field, so it is
    // the one that has to accept this answer.
    XCTAssertNoThrow(try CurrentRuntimeResourceReads.evidence(.object(fields)))
    let facts = try CurrentRuntimeResourceReads.evidence(.object(fields))
    XCTAssertEqual(facts.providerID, "arkforge")
    XCTAssertEqual(facts.executionMode, "execute")
    XCTAssertNil(facts.actualStepKinds)

    // This response must also survive the real CLI validator and emission,
    // not only the shared App/Agent evidence decoder.
    try startServer()
    let emitted = try cli(["job", "evidence", "--job", "job-unprovable-flash"])
    XCTAssertEqual(emitted.0, 75)
    XCTAssertEqual(emitted.1["ok"], .bool(true))
    XCTAssertEqual(emitted.1["result"], response.result)

    // Negative control: nothing else started reporting its steps as unknown.
    try seed("job-provable-steps")
    let controlResponse = try await read("job.evidence", id: "job-provable-steps")
    let control = try object(XCTUnwrap(controlResponse.result))
    XCTAssertEqual(control["actualStepKinds"], .array([]))
    XCTAssertEqual(try CurrentRuntimeResourceReads.evidence(.object(control)).actualStepKinds, [])
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  /// The degraded read that runs when the evidence snapshot itself fails. It
  /// is built from the very record the caller already holds, so publishing
  /// that record's provider and execution mode as null claimed they were
  /// unknown while they were in hand — and made the answer undecodable for
  /// exactly the same reason.
  func testTheDegradedEvidenceReadPublishesWhatTheRecordAlreadyProves() async throws {
    try seed("job-degraded-read")
    // Corrupting the recovery epoch document is what fails the snapshot: the
    // Job record beside it stays readable.
    try Data("{not-a-document}".utf8).write(
      to: state.appending(path: "superseding-recovery-epochs.json"))

    let degraded = try await read("job.evidence", id: "job-degraded-read")
    let fields = try object(XCTUnwrap(degraded.result))
    XCTAssertTrue(Self.strings(fields["blockers"]).contains("recordUnreadable"))
    XCTAssertEqual(fields["providerId"], .string("hdc"))
    XCTAssertEqual(fields["executionMode"], .string("execute"))
    XCTAssertEqual(fields["actualStepKinds"], .null)
    let facts = try CurrentRuntimeResourceReads.evidence(.object(fields))
    XCTAssertEqual(facts.providerID, "hdc")
    XCTAssertNil(facts.actualStepKinds)

    // Negative control: with the document readable again the full snapshot is
    // what answers, so the degraded shape is not what this fixture always gets.
    try FileManager.default.removeItem(
      at: state.appending(path: "superseding-recovery-epochs.json"))
    let restoredResponse = try await read("job.evidence", id: "job-degraded-read")
    let restored = try object(XCTUnwrap(restoredResponse.result))
    XCTAssertFalse(Self.strings(restored["blockers"]).contains("recordUnreadable"))
    XCTAssertEqual(restored["actualStepKinds"], .array([]))
  }

  /// `job.result` and the Agent execution projection embed the same evidence
  /// object, and their published schemas declared `actualStepKinds` as a
  /// non-nullable array. Since the Runtime learned to say "unknown" the daemon
  /// has answered null there, so the declaration was false — and worse, an
  /// unprovable step list contributed no blocker, so a destructive Job whose
  /// write cannot be proven came back `status: "verified"` with `blockers: []`
  /// and passed every gate that reads only `blockers`.
  func testAJobWhoseTypedStepsAreUnprovableIsNotAVerifiedResult() async throws {
    // Terminal, and its journal is gone, so durable state cannot prove which
    // typed steps ran. `job.result` refuses a non-terminal Job outright, so
    // this is the reachable shape for the Agent-facing evidence surfaces.
    try seedUnprovableFlash("job-unprovable-terminal", jobState: "failed")
    _ = try await publishRequired(
      "job-unprovable-terminal", operationReference: ArkForgeFlashOperation.canonicalReference,
      providerID: "arkforge", bindingRevision: 2)

    let response = try await read("job.result", id: "job-unprovable-terminal")
    XCTAssertTrue(response.ok, response.error?.message ?? "-")
    let fields = try object(XCTUnwrap(response.result))
    let evidence = try object(XCTUnwrap(fields["evidence"]))

    XCTAssertEqual(evidence["actualStepKinds"], .null)
    XCTAssertTrue(Self.strings(evidence["blockers"]).contains("stepKindsUnprovable"))
    XCTAssertEqual(evidence["status"], .string("stepKindsUnprovable"))
    // The CLI's own integrity gate reads only `blockers`, so this is what
    // turns an unprovable destructive Job into a non-zero exit.
    XCTAssertNotNil(RuntimeCLI.evidenceIntegrityExit(.object(evidence)))

    try startServer()
    for verb in ["evidence", "result"] {
      let emitted = try cli(["job", verb, "--job", "job-unprovable-terminal"])
      XCTAssertEqual(emitted.0, 2, verb)
      XCTAssertEqual(emitted.1["ok"], .bool(true), verb)
      XCTAssertEqual(emitted.1["result"], verb == "evidence" ? .object(evidence) : response.result, verb)
    }

    // Negative control: an ordinary Job whose steps the record does prove is
    // still verified, still an array, and still exits clean.
    let ordinary = try seed("job-provable-terminal")
    var proven = ordinary
    proven.actualStepKinds = ["readDeviceFacts"]
    try save(proven)
    _ = try await publishRequired("job-provable-terminal")
    let controlResponse = try await read("job.result", id: "job-provable-terminal")
    let control = try object(XCTUnwrap(controlResponse.result))
    let controlEvidence = try object(XCTUnwrap(control["evidence"]))
    XCTAssertEqual(controlEvidence["actualStepKinds"], .array([.string("readDeviceFacts")]))
    XCTAssertFalse(Self.strings(controlEvidence["blockers"]).contains("stepKindsUnprovable"))
    XCTAssertEqual(controlEvidence["status"], .string("verified"))
    XCTAssertNil(RuntimeCLI.evidenceIntegrityExit(.object(controlEvidence)))
    for verb in ["evidence", "result"] {
      let emitted = try cli(["job", verb, "--job", "job-provable-terminal"])
      XCTAssertEqual(emitted.0, 0, verb)
      XCTAssertEqual(emitted.1["ok"], .bool(true), verb)
      XCTAssertEqual(emitted.1["result"], verb == "evidence" ? .object(controlEvidence) : controlResponse.result, verb)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testCLIEvidenceReasonsRemainReadableButCannotBypassVerification() async throws {
    let record = try seed("job-open-evidence-reasons")
    _ = try await publishRequired(record.jobID)
    let response = try await read("job.result", id: record.jobID)
    let result = try object(XCTUnwrap(response.result))
    let evidence = try object(XCTUnwrap(result["evidence"]))

    for verb in ["evidence", "result"] {
      var rest = ["--output", "json"]
      let session = RuntimeCLI.runtimeSession(&rest, command: "job.\(verb)")
      func validate(_ changes: [String: JSONValue]) throws -> Int32 {
        let changed = JSONValue.object(evidence.merging(changes) { _, new in new })
        let value = verb == "evidence" ? changed : .object(result.merging(["evidence": changed]) { _, new in new })
        return try CLIJobReadValidation.validate(
          value, verb: verb, jobID: record.jobID, options: [:], session: session)
      }

      // Open reason strings remain visible even when the client has never
      // named them. They must never become a successful verification.
      for status in ["artifactIntegrityFailed", "futureEvidenceBlocker"] {
        XCTAssertEqual(
          try validate(["status": .string(status), "blockers": .array([.string("futureEvidenceBlocker")])]),
          2, verb)
      }
      for changes: [String: JSONValue] in [
        ["status": .string("verified"), "blockers": .array([.string("futureEvidenceBlocker")])],
        ["status": .string("futureEvidenceBlocker"), "blockers": .array([])],
        ["status": .null],
        ["status": .integer(2)],
        ["blockers": .string("futureEvidenceBlocker")],
        ["blockers": .array([.null])],
        ["blockers": .array([.integer(2)])],
        ["blockers": .array([.object(["reason": .string("futureEvidenceBlocker")])])],
        ["schemaVersion": .string("arkdeck.job-evidence/99")],
        ["futureField": .bool(true)],
      ] {
        XCTAssertThrowsError(try validate(changes), verb) { error in
          XCTAssertEqual((error as? CLIRegistryError)?.code, .recordUnreadable, verb)
        }
      }
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  /// `job.show` echoes the durable record. Its five neighbouring optional
  /// fields all publish `.null` when the record is silent; this one published
  /// an empty array, which reads as "no typed step ran".
  ///
  /// The Runtime never stores an empty list — the only writer
  /// (`RuntimeJobEngine`, the step-intent path) appends at least one element —
  /// so a published `[]` could only ever be that collapse. Measured on this
  /// host's 1,897 durable records on 2026-09-07: 38 have the key absent, 0
  /// hold an empty array, and 7 of the 38 are `recovered` Flash Jobs, whose
  /// steps ran inside the ArkForge lane and never reached the record.
  func testJobShowSaysNothingRatherThanClaimingNoStepRan() async throws {
    let silent = try seed("job-silent-steps")
    var record = silent
    record.actualStepKinds = nil
    try save(record)

    let response = try await read("job.show", id: "job-silent-steps")
    XCTAssertTrue(response.ok, response.error?.message ?? "-")
    let fields = try object(XCTUnwrap(response.result))
    XCTAssertEqual(fields["actualStepKinds"], .null)
    // The CLI validates `job.show` by exact key set and never inspects this
    // value (CLIJobResources.swift, `case "show"`), so a null keeps the key and
    // leaves that check untouched.
    XCTAssertTrue(fields.keys.contains("actualStepKinds"))

    // Negative control: a record that does list its steps still publishes them.
    var proven = silent
    proven.actualStepKinds = ["readDeviceFacts"]
    try save(proven)
    let provenResponse = try await read("job.show", id: "job-silent-steps")
    let provenFields = try object(XCTUnwrap(provenResponse.result))
    XCTAssertEqual(provenFields["actualStepKinds"], .array([.string("readDeviceFacts")]))
    XCTAssertEqual(Set(provenFields.keys), Set(fields.keys))
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
    let result = try cli(["job", "result", "--job", "job-cleanup"])
    XCTAssertEqual(result.0, 0)
    let fields = try object(XCTUnwrap(result.1["result"]))
    let next = try object(XCTUnwrap(fields["nextAction"]))
    XCTAssertEqual(try object(XCTUnwrap(fields["job"]))["outstandingResidueCount"], .integer(1))
    XCTAssertEqual(next["kind"], .string("cleanup"))
    let encoded = String(decoding: try PortableCanonicalJSON.canonicalBytes(.object(fields)), as: UTF8.self)
    XCTAssertFalse(encoded.contains("/private/device/residue")); XCTAssertFalse(encoded.contains("fixture-private-reason"))
    try Data("{broken}".utf8).write(to: root.appending(path: "artifacts/cleanup-debt.json"))
    let unreadable = try cli(["job", "result", "--job", "job-cleanup"])
    XCTAssertEqual(unreadable.1["ok"], .bool(false)); XCTAssertNil(unreadable.1["result"])
    XCTAssertEqual(try object(XCTUnwrap(unreadable.1["error"]))["code"], .string("recordUnreadable"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  /// Actual handler and CLI responses cover continuation rows that the old
  /// single-page timeline corpus could not demonstrate. No operation is run.
  func testTimelineProducerFramesPreserveSegmentsAndBoundCursors() async throws {
    let original = String(repeating: "e\u{301}中🙂", count: 12_000)
    var record = try seed("job-timeline-segments", timeline: [original, "", "last entry"])
    try seed("job-timeline-foreign", timeline: ["foreign entry"])
    try seed("job-timeline-empty")
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { "2026-08-31T12:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    func timeline(_ params: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
      await handler.handleFrame(try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("job-timeline-oracle"), "method": .string("job.timeline"), "params": .object(params),
      ])))
    }
    var cursor: JSONValue?
    var firstCursor: JSONValue?
    var revision: JSONValue?
    var reconstructed = ["", "", ""]
    var parts: [JSONValue] = [], lastParts: [JSONValue] = []
    var pageCount = 0
    repeat {
      var params: [String: JSONValue] = ["jobId": .string(record.jobID), "pageSize": .integer(1)]
      if let cursor { params["cursor"] = cursor }
      let response = try await timeline(params)
      XCTAssertTrue(response.ok, response.error?.message ?? "timeline refused")
      let fields = try object(XCTUnwrap(response.result))
      XCTAssertEqual(fields["order"], .string("entryIndexAscPartIndexAsc"))
      let values = try rows(fields)
      XCTAssertEqual(values.count, 1)
      if let revision { XCTAssertEqual(fields["snapshotRevision"], revision) }
      else { revision = fields["snapshotRevision"] }
      for row in values {
        let index = try XCTUnwrap(CLIJobEventPage.decimal(row["entryIndex"]))
        let text = try XCTUnwrap(CLIJobEventPage.string(row["text"]))
        XCTAssertLessThanOrEqual(text.utf8.count, 64 * 1024)
        reconstructed[Int(index)] += text
        parts.append(try XCTUnwrap(row["partIndex"]))
        lastParts.append(try XCTUnwrap(row["lastPart"]))
      }
      cursor = fields["nextCursor"] == .null ? nil : fields["nextCursor"]
      XCTAssertEqual(fields["hasMore"], .bool(cursor != nil))
      pageCount += 1
      if pageCount == 1 {
        firstCursor = cursor
        record.timeline = ["new current timeline"]
        try save(record)
      }
      XCTAssertLessThanOrEqual(pageCount, 4)
    } while cursor != nil && pageCount < 5
    XCTAssertNil(cursor)
    XCTAssertEqual(pageCount, 4)
    XCTAssertEqual(parts, [.string("0"), .string("1"), .string("0"), .string("0")])
    XCTAssertEqual(lastParts, [.bool(false), .bool(true), .bool(true), .bool(true)])
    XCTAssertEqual(Array(reconstructed[0].utf8), Array(original.utf8))
    XCTAssertEqual(Array(reconstructed.dropFirst()), ["", "last entry"])

    // The real CLI can start on a continuation whose first row is part 1.
    // It must consume the existing snapshot rather than the changed record.
    try startServer()
    let token = try XCTUnwrap(CLIJobEventPage.string(firstCursor))
    let continued = try cli(["job", "timeline", "--job", record.jobID, "--page-size", "1", "--cursor", token])
    XCTAssertEqual(continued.0, 0)
    let continuedPage = try object(XCTUnwrap(continued.1["result"]))
    XCTAssertEqual(continuedPage["snapshotRevision"], revision)
    XCTAssertEqual(try rows(continuedPage).first?["partIndex"], .string("1"))

    let empty = try await timeline(["jobId": .string("job-timeline-empty")])
    XCTAssertTrue(empty.ok)
    XCTAssertEqual(try object(XCTUnwrap(empty.result))["items"], .array([]))
    let listPage = try await page(["pageSize": .integer(1)])
    let listCursor = try XCTUnwrap(listPage["nextCursor"])
    for params: [String: JSONValue] in [
      ["jobId": .string("job-timeline-foreign"), "pageSize": .integer(1), "cursor": .string(token)],
      ["jobId": .string(record.jobID), "pageSize": .integer(2), "cursor": .string(token)],
      ["jobId": .string(record.jobID), "pageSize": .integer(1), "cursor": listCursor],
      ["jobId": .string(record.jobID), "cursor": .string("")],
      ["jobId": .string(record.jobID), "cursor": .string("malformed-token")],
    ] {
      let response = try await timeline(params)
      XCTAssertEqual(response.error?.code, "invalidCursor")
    }
    for params: [String: JSONValue] in [
      ["jobId": .string(record.jobID), "pageSize": .integer(0)],
      ["jobId": .string(record.jobID), "pageSize": .integer(1001)],
      ["jobId": .string("bad/job")],
    ] {
      let response = try await timeline(params)
      XCTAssertEqual(response.error?.code, "invalidInput")
    }
    let missing = try await timeline(["jobId": .string("job-timeline-missing")])
    XCTAssertEqual(missing.error?.code, "notFound")
    try RuntimeJobRepository(stateDirectory: state).updateJobState(jobID: record.jobID, state: record.state,
      updatedAtUTC: date, recordData: Data("not-json".utf8))
    let unreadable = try await timeline(["jobId": .string(record.jobID), "pageSize": .integer(1), "cursor": .string(token)])
    XCTAssertEqual(unreadable.error?.code, "recordUnreadable")
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

    // The production App reader consumes the same daemon as the real CLI.
    // Its page reconstruction must preserve every Unicode byte and the
    // separate final entry without running the already-recorded Job.
    let client = AgentClient(socketPath: try XCTUnwrap(server).socketURL.path)
    let appDetail = try await RuntimeAppReadResources.jobDetail(jobID: "job-long") { method, params in
      let result = try client.request(method: method, params: params)
      return try CanonicalJSONEncoders.canonical().encode(JSONValue.object([
        "id": .string("app-test"), "ok": .bool(true), "result": result,
      ]))
    }
    let appTimeline = try object(XCTUnwrap(try object(appDetail)["timeline"]))
    XCTAssertEqual(appTimeline["kind"], .string("inline"))
    XCTAssertEqual(appTimeline["entries"], .array([.string(original), .string("last entry")]))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testUnknownOutcomeRemainsReconcileAndSuccessfulStatusQuery() async throws {
    var record = try seed("job-unknown", status: "interrupted")
    record.outcomeUnknown = true; try save(record)
    _ = try await publishRequired(record.jobID)
    try startServer()
    let status = try cli(["job", "status", "--job", record.jobID])
    XCTAssertEqual(status.0, 0)
    let result = try cli(["job", "result", "--job", record.jobID])
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

  func testUnreadableAndOversizedRecordsFailBoundedAndRetiredVersionIsRefused() async throws {
    let record = try seed("job-corrupt")
    let repository = try RuntimeJobRepository(stateDirectory: state)
    try repository.updateJobState(jobID: record.jobID, state: record.state, updatedAtUTC: date, recordData: Data("{bad}".utf8))
    let corrupt = try await read("job.show", id: record.jobID)
    XCTAssertEqual(corrupt.error?.code, "recordUnreadable")
    try repository.updateJobState(jobID: record.jobID, state: record.state, updatedAtUTC: date,
      recordData: Data(repeating: 32, count: 16 * 1024 * 1024 + 1))
    let oversized = try await read("job.show", id: record.jobID)
    XCTAssertEqual(oversized.error?.code, "recordUnreadable")
    let legacy = try await read("job.show", id: record.jobID, version: "2.0.0")
    XCTAssertEqual(legacy.error?.code, "unsupportedProtocolVersion")
    let missing = try await read("job.show", id: "job-absent")
    XCTAssertEqual(missing.error?.code, "notFound")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
