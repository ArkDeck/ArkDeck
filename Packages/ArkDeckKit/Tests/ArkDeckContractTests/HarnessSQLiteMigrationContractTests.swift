// SQLite is the only harness store. The retired durable-file generation
// must refuse the store loudly rather than be silently shadowed.

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
    XCTAssertEqual(storageMetadataCount, 0)
  }

  /// A `tasks/` or `memory/` tree that predates the retired importer (or came
  /// back from a backup) must refuse the store: opening anyway would present
  /// an empty task list and silently hide history.
  func testUnconsumedDurableFileTreeRefusesStoreOpen() throws {
    for legacyTree in ["tasks", "memory"] {
      let root = try makeRoot()
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(legacyTree, isDirectory: true),
        withIntermediateDirectories: true)
      XCTAssertThrowsError(try HarnessTaskStore(rootURL: root)) { error in
        guard case HarnessTaskStoreError.corrupt(let detail) = error else {
          return XCTFail("expected corrupt for \(legacyTree), got \(error)")
        }
        XCTAssertTrue(detail.contains("retired durable-file tree"), detail)
        XCTAssertTrue(detail.contains(legacyTree), detail)
      }
      try FileManager.default.removeItem(
        at: root.appendingPathComponent(legacyTree, isDirectory: true))
      XCTAssertNoThrow(try HarnessTaskStore(rootURL: root))
    }
  }

  /// Upgrade regression for the previous release: every pre-retirement daemon
  /// recreated `tasks/` on startup and kept mirroring into it, so a store the
  /// retired importer already consumed (completion sentinel present) must open
  /// normally with the residue still on disk.
  func testMigratedStoreWithMirrorResidueStillOpens() async throws {
    let root = try makeRoot()
    do {
      let repository = try HarnessSQLiteRepository(rootURL: root)
      try repository.database.run(
        "INSERT INTO storage_metadata(key, value) VALUES(?, ?)",
        [
          .text(HarnessSQLiteRepository.legacyImportCompletionKey),
          .text("complete"),
        ])
    }
    let mirrorTask = root.appendingPathComponent("tasks/HTASK-OLDMIRROR01", isDirectory: true)
    try FileManager.default.createDirectory(at: mirrorTask, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: mirrorTask.appendingPathComponent("task.json"))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("memory", isDirectory: true),
      withIntermediateDirectories: true)

    let store = try HarnessTaskStore(rootURL: root)
    let listed = try await store.list()
    XCTAssertTrue(listed.isEmpty, "mirror residue must not surface as tasks")
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

  private func makeRoot(copyHistoricalFixture: Bool = false) throws -> URL {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-hfa012-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
