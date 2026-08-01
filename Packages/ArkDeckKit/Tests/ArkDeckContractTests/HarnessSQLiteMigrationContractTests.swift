// HFA-AC-22: SQLite migration preserves historical harness truth and every
// crash window is retryable without touching the legacy source directory.

import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckStorage

final class HarnessSQLiteMigrationContractTests: XCTestCase {
  private let historicalTaskID = "HTASK-265D25D3E0F9"
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots.removeAll()
  }

  func testSQLiteEnablesWALForeignKeysVersionedSchemaAndEveryRequiredTable() async throws {
    let root = try makeRoot(copyHistoricalFixture: false)
    let store = try HarnessTaskStore(rootURL: root)
    let configuration = try await store.sqliteConfiguration()

    XCTAssertEqual(configuration.journalMode.lowercased(), "wal")
    XCTAssertTrue(configuration.foreignKeysEnabled)
    XCTAssertEqual(configuration.schemaVersion, HarnessSQLiteDatabase.schemaVersion)
    let required = Set([
      "schema_migration", "storage_metadata", "harness_task", "task_event",
      "task_condition", "attempt", "attempt_event", "model_run", "decision",
      "action_run", "dispatch_intent", "runtime_job_link", "artifact_link",
      "evaluation", "human_action", "memory_entry", "memory_fts",
      "context_manifest", "reconcile_lease",
    ])
    XCTAssertTrue(required.isSubset(of: Set(configuration.tableNames)))
    let schemaMigrationCount = try await store.sqliteRowCount("schema_migration")
    let storageMetadataCount = try await store.sqliteRowCount("storage_metadata")
    XCTAssertEqual(schemaMigrationCount, 1)
    XCTAssertEqual(storageMetadataCount, 1)
  }

  func testRealHFA005DirectoryMigratesWithByteEquivalentEventsAndResult() async throws {
    let root = try makeRoot(copyHistoricalFixture: true)
    let taskURL = root.appendingPathComponent("tasks/\(historicalTaskID)/task.json")
    let eventsURL = root.appendingPathComponent("tasks/\(historicalTaskID)/events.jsonl")
    let taskBytesBefore = try Data(contentsOf: taskURL)
    let eventBytesBefore = try Data(contentsOf: eventsURL)
    let historical = try JSONDecoder().decode(HarnessTaskSnapshot.self, from: taskBytesBefore)
    let expectedEvents: [HarnessTaskEvent] = try decodeLines(eventBytesBefore)
    let expectedEventWire = try canonicalLines(expectedEvents)
    let expectedResultWire = try canonical(try XCTUnwrap(historical.result))

    let store = try HarnessTaskStore(rootURL: root)
    let migrated = try await store.load(historicalTaskID)
    let migratedEvents = try await store.events(historicalTaskID)

    XCTAssertEqual(migrated.schemaVersion, HarnessTaskSnapshot.schemaVersion)
    XCTAssertEqual(try canonical(try XCTUnwrap(migrated.result)), expectedResultWire)
    XCTAssertEqual(try canonicalLines(migratedEvents), expectedEventWire)
    XCTAssertEqual(migratedEvents, expectedEvents)
    XCTAssertEqual(try Data(contentsOf: taskURL), taskBytesBefore)
    XCTAssertEqual(try Data(contentsOf: eventsURL), eventBytesBefore)

    let decision = try await store.decision(historicalTaskID, round: 1)
    let intents = try await store.intents(historicalTaskID)
    let modelRuns = try await store.modelRuns(historicalTaskID)
    let humanActions = try await store.humanActions(historicalTaskID)
    let memoryHistory = try await store.memoryHistory(scope: .task, key: historicalTaskID)
    let searchResults = try await store.searchMemory(
      scope: .task, key: historicalTaskID, query: "observe", limit: 10)
    XCTAssertEqual(decision?.decisionID, "dec-71040eac6601")
    XCTAssertEqual(intents.count, 1)
    XCTAssertEqual(modelRuns.count, 1)
    XCTAssertEqual(humanActions.count, 1)
    XCTAssertEqual(memoryHistory.count, 1)
    XCTAssertEqual(searchResults.count, 1)
    // JSON envelope evolution requires no lossy SQL rewrite: historical rows
    // decode, remain queryable, and are explicitly non-executable when their
    // v2 preconditions are absent.
    XCTAssertEqual(decision?.envelopeVersion, "1.0.0")
    XCTAssertEqual(intents.first?.schemaVersion, "1.0.0")
    XCTAssertEqual(
      intents.first?.withState(.linked, atUTC: "2026-07-31T00:00:00Z").schemaVersion,
      "1.0.0")
    if let decision {
      let basis = HarnessDecisionBasis(
        snapshot: migrated, offeredOperations: [decision.operationReference].compactMap { $0 })
      XCTAssertEqual(
        HarnessDecisionFreshness.staleness(of: decision, against: basis), .unverifiable)
    }

    let expectedCounts: [String: Int] = [
      "harness_task": 1,
      "task_event": 2,
      "task_condition": HarnessTaskConditionName.allCases.count,
      "model_run": 1,
      "decision": 1,
      "dispatch_intent": 1,
      "human_action": 1,
      "memory_entry": 1,
      "memory_fts": 1,
      "context_manifest": 1,
    ]
    for (table, count) in expectedCounts {
      let actual = try await store.sqliteRowCount(table)
      XCTAssertEqual(actual, count, table)
    }

    // Reopening sees the activation marker. No row is duplicated and the
    // canonical JSON digest still covers the exact stored blob.
    let reopened = try HarnessTaskStore(rootURL: root)
    for (table, count) in expectedCounts {
      let actual = try await reopened.sqliteRowCount(table)
      XCTAssertEqual(actual, count, table)
    }
    let database = try HarnessSQLiteDatabase(rootURL: root)
    for (table, jsonColumn, digestColumn) in [
      ("harness_task", "snapshot_json", "snapshot_digest"),
      ("task_event", "event_json", "event_digest"),
      ("model_run", "run_json", "run_digest"),
      ("context_manifest", "manifest_json", "manifest_digest"),
    ] {
      for row in try database.query(
        "SELECT \(jsonColumn), \(digestColumn) FROM \(table)")
      {
        let bytes = try XCTUnwrap(row.blob(jsonColumn))
        XCTAssertEqual(row.text(digestColumn), HarnessSQLiteDatabase.digest(bytes), table)
      }
    }
  }

  func testBothMigrationCrashWindowsRollBackAndReenterWithoutLegacyDamage() async throws {
    for fault in [
      HarnessTaskStoreMigrationFault.afterTaskRows,
      HarnessTaskStoreMigrationFault.beforeActivation,
    ] {
      let root = try makeRoot(copyHistoricalFixture: true)
      let taskURL = root.appendingPathComponent("tasks/\(historicalTaskID)/task.json")
      let eventsURL = root.appendingPathComponent("tasks/\(historicalTaskID)/events.jsonl")
      let taskBytes = try Data(contentsOf: taskURL)
      let eventBytes = try Data(contentsOf: eventsURL)

      XCTAssertThrowsError(
        try HarnessTaskStore(rootURL: root, migrationFault: fault)
      ) { error in
        XCTAssertEqual(error as? HarnessTaskStoreMigrationFault, fault)
      }
      XCTAssertEqual(try Data(contentsOf: taskURL), taskBytes)
      XCTAssertEqual(try Data(contentsOf: eventsURL), eventBytes)

      let databaseAfterFault = try HarnessSQLiteDatabase(rootURL: root)
      XCTAssertEqual(
        try databaseAfterFault.query("SELECT COUNT(*) AS count FROM harness_task")
          .first?.integer("count"),
        0)
      XCTAssertTrue(
        try databaseAfterFault.query(
          "SELECT value FROM storage_metadata WHERE key = ?",
          [.text("legacy_file_import_v1")]
        ).isEmpty)

      let recovered = try HarnessTaskStore(rootURL: root)
      let recoveredSnapshot = try await recovered.load(historicalTaskID)
      let recoveredEvents = try await recovered.events(historicalTaskID)
      let taskCount = try await recovered.sqliteRowCount("harness_task")
      let eventCount = try await recovered.sqliteRowCount("task_event")
      XCTAssertEqual(recoveredSnapshot.result?.reasonCode, "submissionRejected:rejected")
      XCTAssertEqual(recoveredEvents.count, 2)
      XCTAssertEqual(taskCount, 1)
      XCTAssertEqual(eventCount, 2)
      XCTAssertEqual(try Data(contentsOf: taskURL), taskBytes)
      XCTAssertEqual(try Data(contentsOf: eventsURL), eventBytes)
    }
  }

  func testEventAndSnapshotRollbackTogetherAndCASReportsThePersistedVersion() async throws {
    let root = try makeRoot(copyHistoricalFixture: false)
    let store = try HarnessTaskStore(rootURL: root)
    let base = snapshot()
    try await store.create(base)
    let (paused, pauseEvent) = try HarnessTaskStateReducer.apply(
      transition(
        from: base, causation: .pauseRequested, status: .waiting,
        waitReason: .userSuspended, atUTC: "2026-08-01T00:00:01Z"),
      to: base)

    do {
      try await store.commitForTesting(
        event: pauseEvent, snapshot: paused, expectedVersion: base.version,
        failAfterEvent: true)
      XCTFail("the injected transaction fault must escape")
    } catch let error as HarnessTaskStoreError {
      XCTAssertEqual(error, .ioFailure("injected failure after task event insert"))
    }
    let afterFault = try await store.load(base.htaskID)
    let eventsAfterFault = try await store.events(base.htaskID)
    XCTAssertEqual(afterFault, base)
    XCTAssertTrue(eventsAfterFault.isEmpty)

    try await store.commit(
      event: pauseEvent, snapshot: paused, expectedVersion: base.version)
    let (resumed, resumeEvent) = try HarnessTaskStateReducer.apply(
      transition(
        from: paused, causation: .resumeRequested, status: .running,
        waitReason: nil, atUTC: "2026-08-01T00:00:02Z"),
      to: paused)
    do {
      try await store.commit(
        event: resumeEvent, snapshot: resumed, expectedVersion: base.version)
      XCTFail("a stale CAS must not update the snapshot")
    } catch let error as HarnessTaskStoreError {
      XCTAssertEqual(
        error, .versionConflict(expected: base.version, actual: paused.version))
    }
    let afterConflict = try await store.load(base.htaskID)
    let eventsAfterConflict = try await store.events(base.htaskID)
    XCTAssertEqual(afterConflict, paused)
    XCTAssertEqual(eventsAfterConflict, [pauseEvent])
  }

  func testCanonicalJSONDigestMismatchFailsClosed() async throws {
    let root = try makeRoot(copyHistoricalFixture: false)
    let store = try HarnessTaskStore(rootURL: root)
    let task = snapshot()
    try await store.create(task)
    let database = try HarnessSQLiteDatabase(rootURL: root)
    try database.run(
      "UPDATE harness_task SET snapshot_json = ? WHERE task_id = ?",
      [.blob(Data("{}".utf8)), .text(task.htaskID)])

    do {
      _ = try await store.load(task.htaskID)
      XCTFail("a digest mismatch must never decode into harness state")
    } catch let error as HarnessTaskStoreError {
      XCTAssertEqual(error, .corrupt("sqlite snapshot_json digest mismatch"))
    }
  }

  func testReconcileLeaseIsExclusiveOwnerBoundAndExpiresAfterCrash() async throws {
    let root = try makeRoot(copyHistoricalFixture: false)
    let first = try HarnessTaskStore(rootURL: root)
    try await first.create(snapshot())
    let second = try HarnessTaskStore(rootURL: root)
    let now = Date(timeIntervalSince1970: 100)

    let firstAcquire = try await first.acquireReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-a", now: now, ttl: 10)
    let blockedAcquire = try await second.acquireReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-b", now: now, ttl: 10)
    let expiredAcquire = try await second.acquireReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-b",
      now: Date(timeIntervalSince1970: 111), ttl: 10)
    XCTAssertTrue(firstAcquire)
    XCTAssertFalse(blockedAcquire)
    XCTAssertTrue(expiredAcquire)

    try await first.releaseReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-a")
    let wrongOwnerAcquire = try await first.acquireReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-a",
      now: Date(timeIntervalSince1970: 112), ttl: 10)
    XCTAssertFalse(wrongOwnerAcquire)
    try await second.releaseReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-b")
    let acquireAfterRelease = try await first.acquireReconcileLease(
      taskID: snapshot().htaskID, holderID: "holder-a",
      now: Date(timeIntervalSince1970: 112), ttl: 10)
    XCTAssertTrue(acquireAfterRelease)
  }

  private func makeRoot(copyHistoricalFixture: Bool) throws -> URL {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-hfa012-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    if copyHistoricalFixture {
      let fixture = try XCTUnwrap(
        Bundle.module.url(forResource: "HFA012", withExtension: nil))
      try FileManager.default.copyItem(at: fixture, to: root)
    } else {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    roots.append(root)
    return root
  }

  private func snapshot() -> HarnessTaskSnapshot {
    HarnessTaskSnapshot(
      htaskID: "HTASK-012000000001", type: .debugCrash,
      intakeDescription: "SQLite transaction contract", projectRef: "demo-app",
      target: HarnessTaskTargetReference(targetID: "TGT-SQLITE"),
      goal: HarnessTaskGoal(summary: "Persist one bounded transition."),
      successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024,
        maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: ["observe.device@1"]),
      createdAtUTC: "2026-08-01T00:00:00Z",
      updatedAtUTC: "2026-08-01T00:00:00Z",
      status: .running, phase: .initializing)
  }

  private func transition(
    from snapshot: HarnessTaskSnapshot,
    causation: HarnessTaskCausation,
    status: HarnessTaskStatus,
    waitReason: HarnessTaskWaitReason?,
    atUTC: String
  ) -> HarnessTaskTransition {
    HarnessTaskTransition(
      causation: causation, reasonCode: "sqliteContract", status: status,
      phase: snapshot.phase, activeRound: snapshot.activeRound,
      activeJobID: snapshot.activeJobID, consumedBudget: snapshot.consumedBudget,
      artifactRefs: snapshot.artifactRefs, observedState: snapshot.observedState,
      noProgressRounds: snapshot.noProgressRounds,
      cancelRequested: snapshot.cancelRequested, result: snapshot.result,
      atUTC: atUTC, waitReason: waitReason, conditions: snapshot.conditions)
  }

  private func decodeLines<T: Decodable>(_ data: Data) throws -> [T] {
    try String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
  }

  private func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func canonicalLines<T: Encodable>(_ values: [T]) throws -> Data {
    var data = Data()
    for value in values {
      data.append(try canonical(value))
      data.append(contentsOf: Data("\n".utf8))
    }
    return data
  }
}
