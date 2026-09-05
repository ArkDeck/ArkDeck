import ArkDeckCore
import Foundation
import SQLite3
import XCTest

@testable import ArkDeckStorage

final class CurrentDurableStorageContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "svc002-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func schema(_ name: String) throws -> JSONValue {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
      repository.appending(path: "openspec/contracts/\(name).schema.json")))
  }

  func testCurrentSchemaAndSwiftAgreeOnRecoveryResultsAndBinding() throws {
    let schema = try schema("journal-event")
    let cases: [(String, JobState, Int?)] = [
      ("resumeAtConfirmedSafeBoundary", .resumeAtConfirmedSafeBoundary, 2),
      ("resumeHostOnlyAtConfirmedSafeBoundary", .resumeAtConfirmedSafeBoundary, nil),
      ("finalizeConfirmedFailure", .finalizing, 2),
      ("finalizeHostOnlyConfirmedFailure", .finalizing, nil),
      ("finalizeLanePostflightRecovered", .finalizing, 2),
      ("waitingForRecovery", .waitingForRecovery, nil),
      ("noAction", .waitingForRecovery, nil),
    ]
    for (result, nextState, binding) in cases {
      let event = try JournalEvent.reconcileOutcome(
        eventID: "event-reconciled", sequence: 1, sessionID: "session-current",
        jobID: "job-current", timestamp: "2026-09-05T00:00:00Z",
        bindingRevision: binding, recoveryAttemptID: "recovery-current",
        result: result, nextState: nextState, outcomeCertainty: .confirmed,
        safeBoundaryConfirmed: true, evidence: ["fixture-proof"])
      let bytes = try JournalEventCodec.encode(event)
      guard case .object(var value) = try JSONDecoder().decode(JSONValue.self, from: bytes)
      else { return XCTFail("event must be object") }
      XCTAssertTrue(JSONSchemaSubset.validate(.object(value), against: schema), result)
      XCTAssertNoThrow(try JournalEventCodec.decode(bytes), result)
      if result != "waitingForRecovery" && result != "noAction" {
        value["bindingRevision"] = binding == nil ? .integer(2) : .null
        XCTAssertFalse(JSONSchemaSubset.validate(.object(value), against: schema), result)
        XCTAssertThrowsError(try JournalEventCodec.decode(JSONEncoder().encode(value)), result)
      }
    }
  }

  func testManifestSchemaAndSwiftRejectOldActorAtTheSameVersion() throws {
    guard case .object(var confirmation) = SessionStorageFixtures.serverLifecycleConfirmation()
    else { return XCTFail("confirmation fixture") }
    confirmation["relatedStepIds"] = .array([])
    let current = try SessionStorageFixtures.manifest(confirmations: [.object(confirmation)])
    let schema = try schema("manifest")
    let value = try JSONDecoder().decode(JSONValue.self, from: current)
    XCTAssertTrue(JSONSchemaSubset.validate(value, against: schema))
    XCTAssertNoThrow(try SessionManifestDocument(data: current))
    confirmation["actor"] = .string("user")
    let retired = try SessionStorageFixtures.manifest(confirmations: [.object(confirmation)])
    XCTAssertFalse(JSONSchemaSubset.validate(
      try JSONDecoder().decode(JSONValue.self, from: retired), against: schema))
    XCTAssertThrowsError(try SessionManifestDocument(data: retired))
  }

  private func sql(_ command: String, at directory: URL) throws {
    var handle: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(directory.appending(path: RuntimeJobRepository.filename).path, &handle),
      SQLITE_OK)
    let database = try XCTUnwrap(handle)
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, command, nil, nil, &message)
    let detail = message.map { String(cString: $0) } ?? "SQLite fixture"
    if let message { sqlite3_free(message) }
    XCTAssertEqual(result, SQLITE_OK, detail)
  }

  func testNewV1RetainsIdempotencyRowVersionsAndLogicalOrderAfterRestart() throws {
    do {
      let repository = try RuntimeJobRepository(stateDirectory: root)
      XCTAssertEqual(
        try repository.admit(
          jobID: "job-a", idempotencyKey: "idem-a", requestHash: "hash-a", initialState: "queued",
          createdAtUTC: "2026-09-05T00:00:00Z", initialRecordData: Data("{}".utf8)), .admitted)
      try repository.updateJobState(
        jobID: "job-a", state: "running", updatedAtUTC: "2026-09-05T00:00:01Z",
        recordData: Data("{}".utf8))
      XCTAssertEqual(try repository.job(jobID: "job-a")?.version, 2)
    }
    let reopened = try RuntimeJobRepository(stateDirectory: root)
    XCTAssertEqual(
      try reopened.lookup(idempotencyKey: "idem-a", requestHash: "hash-a"),
      .duplicate(jobID: "job-a"))
    XCTAssertEqual(
      try reopened.lookup(idempotencyKey: "idem-a", requestHash: "different"), .conflict)
    XCTAssertEqual(try reopened.listJobs(pageSize: 1, cursor: nil).jobs.first?.version, 2)
  }

  func testSameVersionWrongColumnsIndexesOrConstraintsAreRefusedWithoutRewriting() throws {
    for (index, change) in [
      "PRAGMA user_version=2",
      "ALTER TABLE runtime_job ADD COLUMN authority TEXT",
      "DROP INDEX runtime_job_created_idx",
      "DROP INDEX runtime_job_created_idx; CREATE INDEX runtime_job_created_idx ON runtime_job(job_id, created_at_order_key)",
      "CREATE TRIGGER unexpected AFTER INSERT ON runtime_job BEGIN DELETE FROM runtime_job; END",
      "DROP TABLE runtime_job; CREATE TABLE runtime_job(job_id TEXT PRIMARY KEY)",
    ].enumerated() {
      let directory = root.appending(path: "case-\(index)")
      do { _ = try RuntimeJobRepository(stateDirectory: directory) }
      try sql(change, at: directory)
      let url = directory.appending(path: RuntimeJobRepository.filename)
      let original = try Data(contentsOf: url)
      XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: directory), change)
      XCTAssertEqual(try Data(contentsOf: url), original, change)
    }
  }

  func testExistingUninitializedDatabaseIsNeverRebuilt() throws {
    let url = root.appending(path: RuntimeJobRepository.filename)
    try Data().write(to: url)
    XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: root))
    XCTAssertEqual(try Data(contentsOf: url), Data())
  }

  func testDanglingDurableStateLinksAreNotTreatedAsFirstInstallation() async throws {
    let missing = root.appending(path: "missing-original-state")
    for name in [RuntimeJobRepository.filename, "idempotency.json", "jobs"] {
      let link = root.appending(path: name)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
      XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: root), name)
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), missing.path)
      try FileManager.default.removeItem(at: link)
    }
    let capabilityRoot = root.appending(path: "capabilities")
    let store = try RuntimeCapabilityStore(directoryURL: capabilityRoot)
    for name in ["runtime-capabilities.json", "runtime-capabilities.ledger"] {
      let link = capabilityRoot.appending(path: name)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
      do {
        _ = try await store.list()
        XCTFail("dangling \(name) must not become an empty authority store")
      } catch {}
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path), missing.path)
      try FileManager.default.removeItem(at: link)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  func testMissingAdmissionIndexBesideJobHistoryStaysMissing() throws {
    let directory = root.appending(path: "jobs/job-unresolved")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = directory.appending(path: "journal.jsonl")
    let original = Data("unreadable old intent\n".utf8)
    try original.write(to: journal)
    XCTAssertThrowsError(try RuntimeJobRepository(stateDirectory: root))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appending(path: RuntimeJobRepository.filename).path))
    XCTAssertEqual(try Data(contentsOf: journal), original)
  }

  func testProductionMutationRootCannotBypassRetiredAuthority() throws {
    let configured = root.appending(path: "Agent")
    try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
    XCTAssertNoThrow(
      try RuntimeStateContinuity.requireMutationState(
        selectedRoot: configured, defaultRoot: configured))
    XCTAssertThrowsError(
      try RuntimeStateContinuity.requireMutationState(
        selectedRoot: root.appending(path: "replacement"), defaultRoot: configured))
    let retired = root.appending(path: "AuthorizationUsage")
    try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
    let ledger = retired.appending(path: "agent-authority-usage.json")
    let bytes = Data(#"{"schemaVersion":"1.0.0","unresolved":true}"#.utf8)
    try bytes.write(to: ledger)
    XCTAssertThrowsError(
      try RuntimeStateContinuity.requireMutationState(
        selectedRoot: configured, defaultRoot: configured))
    XCTAssertEqual(try Data(contentsOf: ledger), bytes)
  }

  func testMutationChecksBothConfiguredAndDefaultSessionRootsWithoutChangingJournalBytes() throws {
    let configured = root.appending(path: "Agentd")
    try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
    for folder in ["Sessions", "custom-sessions"] {
      let sessions = root.appending(path: folder)
      let session = sessions.appending(path: "session-current")
      try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
      let journal = session.appending(path: "journal.jsonl")
      let event = try JournalEvent.jobCreated(
        eventID: "created", sequence: 0, sessionID: "session-current", jobID: "job-current",
        timestamp: "2026-09-05T00:00:00Z", executionMode: "execute")
      var bytes = try JournalEventCodec.encode(event)
      bytes.append(0x0A)
      try bytes.write(to: journal)
      XCTAssertNoThrow(try RuntimeStateContinuity.requireMutationState(
        selectedRoot: configured, defaultRoot: configured, sessionRoots: [sessions]))
      let retired = Data(String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "1.0.0", with: "2.2.0").utf8)
      try retired.write(to: journal)
      XCTAssertThrowsError(try RuntimeStateContinuity.requireMutationState(
        selectedRoot: configured, defaultRoot: configured, sessionRoots: [sessions]))
      XCTAssertEqual(try Data(contentsOf: journal), retired)
      try bytes.write(to: journal)
    }
  }

  func testMissingCapabilityStateCannotReplaceAnAuthorizedJobHistoryWithEmptyBudget() throws {
    let configured = root.appending(path: "Agentd")
    let job = configured.appending(path: "jobs/job-authorized")
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    let record = job.appending(path: "job-record.json")
    let bytes = Data(#"{"request":{"authorization":{"capabilityId":"CAP-RT-EXISTING"}},"actualEffect":"deviceMutation"}"#.utf8)
    try bytes.write(to: record)
    XCTAssertThrowsError(try RuntimeStateContinuity.requireMutationState(
      selectedRoot: configured, defaultRoot: configured))
    XCTAssertEqual(try Data(contentsOf: record), bytes)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: configured.appending(path: "capabilities/runtime-capabilities.json").path))
  }

  func testMissingJobDirectoryCannotHideIndexedMutationHistoryFromContinuityCheck() throws {
    let configured = root.appending(path: "Agentd")
    do {
      let repository = try RuntimeJobRepository(stateDirectory: configured)
      _ = try repository.admit(
        jobID: "job-indexed", idempotencyKey: "indexed", requestHash: "fixture",
        initialState: "succeeded", createdAtUTC: "2026-09-05T00:00:00Z",
        initialRecordData: Data(#"{"request":{},"actualEffect":"readOnly"}"#.utf8))
    }
    XCTAssertNoThrow(try RuntimeStateContinuity.requireMutationState(
      selectedRoot: configured, defaultRoot: configured))
    do {
      let repository = try RuntimeJobRepository(stateDirectory: configured)
      try repository.updateJobState(
        jobID: "job-indexed", state: "succeeded", updatedAtUTC: "2026-09-05T00:00:01Z",
        recordData: Data(#"{"request":{"authorization":{"capabilityId":"CAP-RT-EXISTING"}},"actualEffect":"deviceMutation"}"#.utf8))
    }
    let index = configured.appending(path: RuntimeJobRepository.filename)
    let bytes = try Data(contentsOf: index)
    XCTAssertThrowsError(try RuntimeStateContinuity.requireMutationState(
      selectedRoot: configured, defaultRoot: configured))
    XCTAssertEqual(try Data(contentsOf: index), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: configured.appending(path: "jobs").path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: configured.appending(path: "capabilities/runtime-capabilities.json").path))
  }
}
