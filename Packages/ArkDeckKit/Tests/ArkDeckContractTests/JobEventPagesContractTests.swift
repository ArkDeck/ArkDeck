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

final class JobEventPagesContractTests: XCTestCase {
  private var directory: URL!
  private let timestamp = "2026-08-31T12:00:00Z"
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "je-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    server?.stop(); server = nil
    try? FileManager.default.removeItem(at: directory)
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw FixtureError.missing }
    return fields
  }
  private enum FixtureError: Error { case missing }

  func testWireVocabularyCoversExactlyTheAcceptedJournalKindsWithoutAStorageImport() {
    XCTAssertEqual(JobEventProjectionContract.journalKinds, Set(JournalEventKind.allCases.map(\.rawValue)))
    XCTAssertNil(JobEventProjectionContract.eventType(forJournalKind: "future-event"))
  }

  private func journal(_ jobID: String = "job-events") throws -> FileDurableJournal {
    let journal = try FileDurableJournal(url: directory.appending(path: jobID).appending(path: "journal.jsonl"))
    try journal.appendAndSynchronize(.jobCreated(eventID: "created", sequence: 0,
      sessionID: "session-events", jobID: jobID, timestamp: timestamp, executionMode: "execute"))
    return journal
  }
  private func warning(_ n: Int, jobID: String = "job-events", bytes: Int = 32) throws -> JournalEvent {
    try JournalEvent(eventID: "event-\(n)", sequence: n, sessionID: "session-events", jobID: jobID,
      timestamp: timestamp, kind: .warning, payload: ["code": .string("fixture"),
        "message": .string(String(repeating: "sensitive-payload", count: bytes)), "details": .object([:])])
  }
  private func page(_ cursor: String? = nil, size: Int = 100, jobID: String = "job-events") throws -> CLIJobEventPage {
    try CLIJobEventPage(JournalEventPages.page(directory: directory.appending(path: jobID),
      jobID: jobID, sessionID: "session-events", afterCursor: cursor, pageSize: size),
      jobID: jobID, maximumItems: size)
  }
  private func assertFailure(_ code: String, _ body: () throws -> Void) {
    do { try body(); XCTFail("expected \(code)") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, code) }
    catch { XCTFail("unexpected error: \(error)") }
  }

  func testOriginExclusivePositionsPerEventCursorsAndRestartRetention() throws {
    let writer = try journal()
    for n in 1...4 { try writer.appendAndSynchronize(warning(n)) }
    let first = try page(size: 2)
    XCTAssertEqual(first.rows.map { $0["streamPosition"] }, [.string("1"), .string("2")])
    XCTAssertEqual(first.revision, 5)
    XCTAssertTrue(first.hasMore)
    let rowCursor = try XCTUnwrap(CLIJobEventPage.string(first.rows[0]["cursor"]))
    let resumed = try page(rowCursor, size: 3)
    XCTAssertEqual(resumed.rows.map { $0["streamPosition"] }, [.string("2"), .string("3"), .string("4")])
    let second = try page(first.nextCursor, size: 100)
    XCTAssertEqual(second.rows.map { $0["streamPosition"] }, [.string("3"), .string("4"), .string("5")])
    XCTAssertFalse(second.hasMore)
    XCTAssertTrue(try page(second.nextCursor).rows.isEmpty)
    // No in-memory pager, snapshot cache or TTL is involved in continuation.
    let reopened = try FileDurableJournal(url: writer.url)
    try reopened.appendAndSynchronize(warning(5))
    let appended = try page(second.nextCursor)
    XCTAssertEqual(appended.rows.map { $0["eventId"] }, [.string("event-5")])
    XCTAssertEqual(appended.revision, 6)
    XCTAssertFalse(first.nextCursor.contains(directory.path))
    let key = directory.appending(path: "job-events/event-cursor-key.v1")
    let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(mode.intValue, 0o600)
  }

  func testForgedCrossJobSnapshotAndMalformedCursorsCannotSelectAnOffset() throws {
    _ = try journal(); _ = try journal("another-job")
    let cursor = try page().nextCursor
    for value in [cursor + "x", "../journal.jsonl", "1", "snapshot.some-token", cursor + "="] {
      assertFailure("invalidCursor") { _ = try self.page(value) }
    }
    _ = try page(jobID: "another-job")
    assertFailure("invalidCursor") { _ = try self.page(cursor, jobID: "another-job") }
    // Invalid cursor must not be mistaken for the origin even if key absent.
    try FileManager.default.removeItem(at: directory.appending(path: "job-events/event-cursor-key.v1"))
    assertFailure("invalidCursor") { _ = try self.page(cursor) }
  }

  func testTornTailIsWithheldUntilCompletedAndHistoricalCursorRemainsValid() throws {
    let writer = try journal()
    let cursor = try page().nextCursor
    var bytes = try JournalEventCodec.encode(warning(1)); bytes.append(10)
    let handle = try FileHandle(forWritingTo: writer.url)
    defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: bytes.dropLast(12)); try handle.synchronize()
    XCTAssertTrue(try page(cursor).rows.isEmpty)
    try handle.write(contentsOf: bytes.suffix(12)); try handle.synchronize()
    let complete = try page(cursor)
    XCTAssertEqual(complete.rows.map { $0["eventId"] }, [.string("event-1")])
    XCTAssertEqual(complete.revision, 2)
  }

  func testMalformedCompletedRecordAndMissingRetainedHistoryNeverSilentlyRestart() throws {
    let writer = try journal()
    let cursor = try page().nextCursor
    let handle = try FileHandle(forWritingTo: writer.url)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
    assertFailure("recordUnreadable") { _ = try self.page(cursor) }
    try FileManager.default.removeItem(at: writer.url)
    assertFailure("recordUnreadable") { _ = try self.page(cursor) }
  }

  func testTruncationReplacementAndPrivateKeyCorruptionFailClosed() throws {
    let writer = try journal()
    try writer.appendAndSynchronize(warning(1))
    let cursor = try page().nextCursor
    let first = try JournalEventCodec.encode(.jobCreated(eventID: "created", sequence: 0,
      sessionID: "session-events", jobID: "job-events", timestamp: timestamp, executionMode: "execute")) + Data([10])
    try first.write(to: writer.url, options: .atomic)
    assertFailure("recordUnreadable") { _ = try self.page(cursor) }
    try Data([0]).write(to: directory.appending(path: "job-events/event-cursor-key.v1"))
    assertFailure("recordUnreadable") { _ = try self.page() }
  }

  func testLargeRawPayloadIsProjectedWithoutSensitiveContentAndPagesMakeProgress() throws {
    let writer = try journal()
    try writer.appendAndSynchronize(warning(1, bytes: 120_000))
    let first = try page(size: 1)
    let next = try page(first.nextCursor, size: 1)
    let encoded = try PortableCanonicalJSON.canonicalString(.array(next.rows.map(JSONValue.object)))
    XCTAssertLessThan(encoded.utf8.count, 4096)
    XCTAssertFalse(encoded.contains("sensitive-payload"))
    XCTAssertEqual(next.rows[0]["streamPosition"], .string("2"))
  }

  func testByteBoundedPagesAdvanceAcrossMoreThanOneThousandRetainedEvents() throws {
    let writer = try journal()
    // Seed a complete fixture WAL in one synchronized write. Production still
    // uses its original per-event append/sync path, which this reader never changes.
    let handle = try FileHandle(forWritingTo: writer.url)
    try handle.seekToEnd()
    for n in 1...1100 {
      try handle.write(contentsOf: JournalEventCodec.encode(warning(n)) + Data([10]))
    }
    try handle.synchronize(); try handle.close()
    var cursor: String?
    var positions: [Int64] = []
    repeat {
      let value = try JournalEventPages.page(directory: writer.url.deletingLastPathComponent(),
        jobID: "job-events", sessionID: "session-events", afterCursor: cursor, pageSize: 1000)
      XCTAssertLessThan(try PortableCanonicalJSON.canonicalBytes(value).count, 8_388_608)
      let parsed = try CLIJobEventPage(value, jobID: "job-events", maximumItems: 1000)
      XCTAssertFalse(parsed.rows.isEmpty)
      positions += parsed.rows.map { CLIJobEventPage.decimal($0["streamPosition"])! }
      cursor = parsed.nextCursor
      if !parsed.hasMore { break }
    } while positions.count < 1200
    XCTAssertEqual(positions, Array(1...1101).map(Int64.init))
  }

  func testPageDecoderRejectsUnknownShapesOrderDuplicateIdentityAndNumericPosition() throws {
    _ = try journal()
    let raw = try JournalEventPages.page(directory: directory.appending(path: "job-events"), jobID: "job-events",
      sessionID: "session-events", afterCursor: nil, pageSize: 100)
    let original = try object(raw)
    for (key, value) in [("order", JSONValue.string("eventIdAsc")), ("nextCursor", .null),
      ("snapshotRevision", .string("01")), ("hasMore", .string("false"))] {
      var broken = original; broken[key] = value
      XCTAssertThrowsError(try CLIJobEventPage(.object(broken), jobID: "job-events", maximumItems: 100))
    }
    guard case .array(let rows)? = original["items"] else { return XCTFail("missing rows") }
    var row = try object(rows[0]); row["streamPosition"] = .integer(1)
    var broken = original; broken["items"] = .array([.object(row)])
    XCTAssertThrowsError(try CLIJobEventPage(.object(broken), jobID: "job-events", maximumItems: 100))
    broken["items"] = .array([rows[0], rows[0]])
    XCTAssertThrowsError(try CLIJobEventPage(.object(broken), jobID: "job-events", maximumItems: 100))
    var maximum = try object(rows[0]); maximum["streamPosition"] = .string(String(Int64.max))
    maximum["runtimeRevision"] = .string(String(Int64.max))
    var later = maximum; later["eventId"] = .string("different-identity")
    broken["snapshotRevision"] = .string(String(Int64.max))
    broken["items"] = .array([.object(maximum), .object(later)])
    XCTAssertThrowsError(try CLIJobEventPage(.object(broken), jobID: "job-events", maximumItems: 100),
      "malformed maximum positions must fail, never overflow the CLI")
  }

  // This fixture drives the actual daemon/engine and CLI, using a synthetic
  // typed HDC port. It cannot prove real hardware acceptance.
  private struct RuntimeFixture {
    let engine: RuntimeJobEngine
    let owner: RuntimeAgentExecutionCoordinator
    let dispatcher: RuntimeAgentExecutionContractTests.Dispatcher
    let server: AgentDaemonServer
  }
  private func runtime() throws -> RuntimeFixture {
    let clock = RuntimeAgentExecutionContractTests.Clock()
    let port = TargetObservationCoordinatorContractTests.Port()
    let targets = try RuntimeTargetStore(directoryURL: directory.appending(path: "targets"))
    let capabilities = try RuntimeCapabilityStore(directoryURL: directory.appending(path: "capabilities"))
    let artifacts = try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), nowUTC: { RuntimeAgentTime.format(clock.now()) })
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(configuration: .init(stateDirectory: directory.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(
        factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: clock))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts,
      nowUTC: { RuntimeAgentTime.format(clock.now()) })
    let observations = TargetObservationCoordinator(observation: port, targetStore: targets,
      usbRelations: { try port.relations() }, nowUTC: { RuntimeAgentTime.format(clock.now()) })
    let owner = try RuntimeAgentExecutionCoordinator(directory: directory.appending(path: "owners"),
      engine: engine, targets: targets, observations: observations, now: { clock.now() })
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: ["hdc"], nowUTC: { RuntimeAgentTime.format(clock.now()) }, targetStore: targets, agentExecutions: owner, artifactStore: artifacts)
    let server = AgentDaemonServer(stateDirectory: directory.appending(path: "control"), handler: handler, nowUTC: { RuntimeAgentTime.format(clock.now()) })
    _ = try server.start(); self.server = server
    return RuntimeFixture(engine: engine, owner: owner, dispatcher: dispatcher, server: server)
  }
  private func run(_ runtime: RuntimeFixture, finished: Bool = true) async throws -> String {
    let result = try object(await runtime.owner.run([
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion), "executionId": .string("events-execution"),
      "operation": .string("observe.device@1"), "inputs": .object([:]), "maximumWaitMilliseconds": .string("30000"),
    ]))
    let id = try XCTUnwrap(CLIJobEventPage.string(result["jobId"]))
    if finished {
      for _ in 0..<200 {
        if try await runtime.engine.status(jobID: id).state == "succeeded" { return id }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw FixtureError.missing
    }
    return id
  }
  private func cli(_ args: [String], interruptAfter: Double? = nil) throws -> (Int32, [[String: JSONValue]]) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = args + ["--socket", try XCTUnwrap(server).socketURL.path, "--control-request-id", "ctl-events-test"]
    let output = directory.appending(path: "output-\(UUID()).jsonl")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    process.standardOutput = handle; process.standardError = FileHandle.nullDevice
    try process.run()
    let started = Date()
    var interrupted = false
    while process.isRunning && Date().timeIntervalSince(started) < 20 {
      if let interruptAfter, !interrupted, Date().timeIntervalSince(started) >= interruptAfter {
        process.interrupt(); interrupted = true
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning { process.terminate(); throw FixtureError.missing }
    try handle.close()
    let lines = try Data(contentsOf: output).split(separator: 10)
    guard !lines.isEmpty else {
      XCTFail("CLI produced no machine output, exit \(process.terminationStatus), reason \(process.terminationReason)")
      throw FixtureError.missing
    }
    return (process.terminationStatus, try lines.map { try object(CLIStrictJSON.decode(Data($0))) })
  }

  func testRealCLIWaitDrainsEventsThenOneTerminalAndWatchDoesNotStopAtJobCompletion() async throws {
    let runtime = try runtime(); let id = try await run(runtime)
    let count = runtime.dispatcher.dispatchCount
    let waited = try cli(["job", "wait", "--job", id, "--page-size", "2", "--output", "jsonl", "--timeout", "5s"])
    XCTAssertEqual(waited.0, 0)
    XCTAssertGreaterThan(waited.1.count, 3)
    assertFrames(waited.1, exit: 0, command: "job.wait")
    let watched = try cli(["job", "watch", "--job", id, "--output", "jsonl", "--timeout", "400ms"])
    XCTAssertEqual(watched.0, 75)
    assertFrames(watched.1, exit: 75, command: "job.watch")
    let error = try object(XCTUnwrap(watched.1.last?["error"]))
    XCTAssertEqual(error["code"], .string("clientTimeout"))
    XCTAssertEqual(runtime.dispatcher.dispatchCount, count)
  }

  func testRealCLIResumeFromMiddleAndInterruptDoNotCancelOrRerunJob() async throws {
    let runtime = try runtime(); let id = try await run(runtime)
    let page = try CLIJobEventPage(await runtime.engine.eventPage(jobID: id, afterCursor: nil, pageSize: 2), jobID: id, maximumItems: 2)
    let middle = try XCTUnwrap(CLIJobEventPage.string(page.rows[0]["cursor"]))
    let count = runtime.dispatcher.dispatchCount
    let result = try cli(["job", "watch", "--job", id, "--after-cursor", middle, "--output", "jsonl"], interruptAfter: 0.5)
    XCTAssertEqual(result.0, 130)
    XCTAssertEqual(result.1.first?["streamPosition"], .string("2"))
    assertFrames(result.1, exit: 130, command: "job.watch")
    XCTAssertEqual(runtime.dispatcher.dispatchCount, count)
    let state = try await runtime.engine.status(jobID: id)
    XCTAssertEqual(state.state, "succeeded")
  }

  func testRealCLIWaitTimeoutDuringDispatchReturnsCursorAndLeavesJobRunning() async throws {
    let runtime = try runtime()
    let gate = RuntimeAgentExecutionContractTests.Gate()
    runtime.dispatcher.hold(gate)
    let id = try await run(runtime, finished: false)
    let output = try cli(["job", "wait", "--job", id, "--output", "jsonl", "--timeout", "300ms"])
    XCTAssertEqual(output.0, 75)
    assertFrames(output.1, exit: 75, command: "job.wait")
    let before = try await runtime.engine.status(jobID: id)
    XCTAssertFalse(JobState(rawValue: before.state)?.isTerminal == true)
    await gate.release()
    let finished = try await runtime.engine.run(jobID: id)
    XCTAssertEqual(finished.state, "succeeded")
  }

  func testRuntimeRestartAcceptsItsPriorEventCursorWithoutRedispatch() async throws {
    let original = try runtime(); let id = try await run(original)
    let first = try CLIJobEventPage(await original.engine.eventPage(jobID: id, afterCursor: nil, pageSize: 1), jobID: id, maximumItems: 1)
    original.server.stop()
    let restarted = try runtime()
    let next = try CLIJobEventPage(await restarted.engine.eventPage(jobID: id, afterCursor: first.nextCursor, pageSize: 100), jobID: id, maximumItems: 100)
    XCTAssertEqual(next.rows.first?["streamPosition"], .string("2"))
    XCTAssertEqual(restarted.dispatcher.dispatchCount, 0)
  }

  func testFailedTerminalJobStillReturnsAResultWithExactExitOne() async throws {
    let runtime = try runtime()
    let gate = RuntimeAgentExecutionContractTests.Gate()
    runtime.dispatcher.hold(gate)
    let id = try await run(runtime, finished: false)
    for _ in 0..<100 {
      if await gate.arrived { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await runtime.engine.requestCancel(jobID: id)
    await gate.release()
    let finished = try await runtime.engine.run(jobID: id)
    XCTAssertEqual(finished.state, "cancelled")
    let waited = try cli(["job", "wait", "--job", id, "--output", "jsonl", "--timeout", "5s"])
    XCTAssertEqual(waited.0, 1)
    assertFrames(waited.1, exit: 1, command: "job.wait")
    XCTAssertNotNil(waited.1.last?["result"])
    XCTAssertNil(waited.1.last?["error"])
  }

  func testUnknownOutcomeAndHumanActionTerminateObservationWithoutClaimingSuccess() throws {
    let session = CLIRuntimeSession(client: AgentClient(socketPath: "/unused"), command: "job.wait",
      rendering: .jsonlStream, controlRequestID: "ctl-events-test", lifecycle: .current)
    let owner = JSONValue.object(["kind": .string("job"), "id": .string("job-test")])
    var status: [String: JSONValue] = ["schemaVersion": .string("arkdeck.job-status/1"),
      "jobId": .string("job-test"), "state": .string("failed"), "outcomeUnknown": .bool(true), "waitingForHuman": .bool(false),
      "nextAction": .object(["kind": .string("reconcile"), "owner": owner, "resource": owner, "reasonCode": .string("recovery.outcomeUnknown")])]
    XCTAssertThrowsError(try RuntimeCLI.validatedObservedJobStatus(.object(status), jobID: "job-test", session: session)) {
      XCTAssertEqual(($0 as? CLIRegistryError)?.code, .outcomeUnknown)
    }
    status["state"] = .string("waitingForDevice"); status["outcomeUnknown"] = .bool(false); status["waitingForHuman"] = .bool(true)
    status["nextAction"] = .object(["kind": .string("humanAction"), "owner": owner,
      "resource": .object(["kind": .string("humanAction"), "id": .string("har-test")]),
      "reasonCode": .string("device.trustPending"), "resumeReference": .string("resume-test"), "expiresAt": .null])
    XCTAssertThrowsError(try RuntimeCLI.validatedObservedJobStatus(.object(status), jobID: "job-test", session: session)) {
      XCTAssertEqual(($0 as? CLIRegistryError)?.code, .humanActionRequired)
    }
    var broken = try object(XCTUnwrap(status["nextAction"])); broken["authority"] = .string("must-not-exist")
    status["nextAction"] = .object(broken)
    XCTAssertThrowsError(try RuntimeCLI.validatedObservedJobStatus(.object(status), jobID: "job-test", session: session)) {
      XCTAssertEqual(($0 as? CLIRegistryError)?.code, .recordUnreadable)
    }
  }

  func testCurrentStatusAndMissingJobOrInvalidCursorHaveExactShapes() async throws {
    let runtime = try runtime(); let id = try await run(runtime)
    let old = AgentClient(socketPath: runtime.server.socketURL.path)
    let oldStatus = try object(old.request(method: "job.status", params: ["jobId": .string(id)]))
    XCTAssertNil(oldStatus["timeline"]); XCTAssertNotNil(oldStatus["nextAction"])
    XCTAssertNoThrow(try old.request(method: "job.events", params: ["jobId": .string(id)]))
    let missing = try cli(["job", "events", "--job", "missing-job", "--output", "json"])
    XCTAssertEqual(missing.0, 65)
    XCTAssertEqual(try object(XCTUnwrap(missing.1[0]["error"]))["code"], .string("resourceNotFound"))
    let bad = try cli(["job", "watch", "--job", id, "--after-cursor", "bogus", "--output", "jsonl"])
    XCTAssertEqual(bad.0, 65); XCTAssertEqual(bad.1.count, 1)
    XCTAssertEqual(bad.1[0]["lastCursor"], .null)
    XCTAssertEqual(try object(XCTUnwrap(bad.1[0]["error"]))["code"], .string("invalidCursor"))
  }

  private func assertFrames(_ frames: [[String: JSONValue]], exit: Int64, command: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(frames.filter { $0["type"] == .string("terminal") }.count, 1, file: file, line: line)
    for (index, frame) in frames.enumerated() {
      XCTAssertEqual(frame["schemaVersion"], .string("arkdeck.cli.event/1"), file: file, line: line)
      XCTAssertEqual(frame["sequence"], .integer(Int64(index + 1)), file: file, line: line)
      XCTAssertEqual(frame["command"], .string(command), file: file, line: line)
      XCTAssertEqual(frame["controlRequestId"], .string("ctl-events-test"), file: file, line: line)
      if index < frames.count - 1 {
        XCTAssertNotNil(frame["data"], file: file, line: line)
        for key in ["ok", "result", "error", "exitCode"] { XCTAssertNil(frame[key], file: file, line: line) }
      }
    }
    XCTAssertEqual(frames.last?["exitCode"], .integer(exit), file: file, line: line)
    XCTAssertEqual(frames.last?["ok"], .bool(exit == 0 || exit == 1), file: file, line: line)
    if frames.count > 1 { XCTAssertEqual(frames.last?["lastCursor"], frames[frames.count - 2]["cursor"], file: file, line: line) }
  }
}
