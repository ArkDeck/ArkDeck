// Typed SQLite repository (TASK-HFA-012).
//
// SQLite is the only authoritative harness store.

import ArkDeckCore
import Foundation

struct HarnessContextManifestRecord: Encodable, Equatable, Sendable {
  let documentType = "harness-context-manifest"
  let schemaVersion = "1.0.0"
  let htaskID: String
  let modelRunID: String
  let contextDigest: String
  let observedStateVersion: Int
  let byteCount: Int
}

final class HarnessSQLiteRepository: @unchecked Sendable {
  /// Completion sentinel written by the retired one-time importer. It is
  /// read-only now: the current code never writes it, but a database that
  /// carries it has provably consumed its durable-file trees.
  static let legacyImportCompletionKey = "legacy_file_import_v1"

  let database: HarnessSQLiteDatabase

  init(rootURL: URL) throws {
    self.database = try HarnessSQLiteDatabase(rootURL: rootURL)
    // The durable-file generation (`tasks/`, `memory/`) is retired along with
    // its one-time importer. Every pre-retirement release recreated `tasks/`
    // on startup and kept mirroring into it, so a surviving tree on an
    // upgraded store is normal residue — the importer's completion sentinel
    // proves the database consumed it. Without that sentinel the tree is
    // unimported history (or a restored backup); opening the store anyway
    // would silently present an empty task list, so it refuses loudly.
    let imported =
      try database.query(
        "SELECT value FROM storage_metadata WHERE key = ?",
        [.text(Self.legacyImportCompletionKey)]
      ).first?.text("value") == "complete"
    guard !imported else { return }
    for legacyTree in ["tasks", "memory"] {
      let url = rootURL.appendingPathComponent(legacyTree, isDirectory: true)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        throw HarnessTaskStoreError.corrupt(
          "retired durable-file tree present at \(url.path) and "
            + "\(HarnessSQLiteDatabase.filename) carries no import-completion "
            + "sentinel; this tree cannot be imported any more. Verify its records "
            + "are represented in the database (or no longer needed), then remove "
            + "the directory to reopen the store")
      }
    }
  }

  // MARK: - Task lifecycle

  func containsTask(_ taskID: String) throws -> Bool {
    !(try database.query(
      "SELECT 1 AS present FROM harness_task WHERE task_id = ? LIMIT 1",
      [.text(taskID)])).isEmpty
  }

  func create(_ snapshot: HarnessTaskSnapshot) throws {
    try database.transaction {
      guard try containsTask(snapshot.htaskID) == false else {
        throw HarnessTaskStoreError.alreadyExists(snapshot.htaskID)
      }
      try insertTask(snapshot, replace: false)
    }
  }

  func load(_ taskID: String) throws -> HarnessTaskSnapshot {
    guard
      let row = try database.query(
        "SELECT snapshot_json, snapshot_digest FROM harness_task WHERE task_id = ?",
        [.text(taskID)]
      ).first
    else { throw HarnessTaskStoreError.notFound(taskID) }
    let data = try verifiedData(row, jsonColumn: "snapshot_json", digestColumn: "snapshot_digest")
    return try HarnessSQLiteDatabase.decode(HarnessTaskSnapshot.self, from: data)
  }

  func list() throws -> [HarnessTaskSnapshot] {
    try database.query(
      "SELECT snapshot_json, snapshot_digest FROM harness_task ORDER BY task_id"
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "snapshot_json", digestColumn: "snapshot_digest")
      return try HarnessSQLiteDatabase.decode(HarnessTaskSnapshot.self, from: data)
    }
  }

  func commit(
    event: HarnessTaskEvent,
    snapshot: HarnessTaskSnapshot,
    expectedVersion: Int,
    failAfterEvent: Bool = false
  ) throws {
    guard event.htaskID == snapshot.htaskID else {
      throw HarnessTaskStoreError.corrupt("task event and snapshot identities do not join")
    }
    try database.transaction {
      let actual = try database.query(
        "SELECT state_version FROM harness_task WHERE task_id = ?",
        [.text(snapshot.htaskID)]
      ).first?.integer("state_version")
      guard let actual else { throw HarnessTaskStoreError.notFound(snapshot.htaskID) }
      guard Int(actual) == expectedVersion else {
        throw HarnessTaskStoreError.versionConflict(
          expected: expectedVersion, actual: Int(actual))
      }
      guard event.sequence == expectedVersion,
        snapshot.version == expectedVersion + 1
      else {
        throw HarnessTaskStoreError.corrupt("task event and snapshot versions do not join")
      }
      let eventData = try canonical(event)
      try database.run(
        """
        INSERT INTO task_event(task_id, sequence, event_json, event_digest, at_utc)
        VALUES(?, ?, ?, ?, ?)
        """,
        [
          .text(event.htaskID), .integer(Int64(event.sequence)), .blob(eventData),
          .text(HarnessSQLiteDatabase.digest(eventData)), .text(event.atUTC),
        ])
      if failAfterEvent {
        throw HarnessTaskStoreError.ioFailure("injected failure after task event insert")
      }

      let snapshotData = try canonical(snapshot)
      let resultData = try snapshot.result.map(canonical)
      let changed = try database.run(
        """
        UPDATE harness_task
        SET state_version = ?, snapshot_json = ?, snapshot_digest = ?, result_json = ?,
            updated_at_utc = ?
        WHERE task_id = ? AND state_version = ?
        """,
        [
          .integer(Int64(snapshot.version)), .blob(snapshotData),
          .text(HarnessSQLiteDatabase.digest(snapshotData)), blobOrNull(resultData),
          .text(snapshot.updatedAtUTC), .text(snapshot.htaskID),
          .integer(Int64(expectedVersion)),
        ])
      guard changed == 1 else {
        let racedActual = try database.query(
          "SELECT state_version FROM harness_task WHERE task_id = ?",
          [.text(snapshot.htaskID)]
        ).first?.integer("state_version")
        guard let racedActual else { throw HarnessTaskStoreError.notFound(snapshot.htaskID) }
        throw HarnessTaskStoreError.versionConflict(
          expected: expectedVersion, actual: Int(racedActual))
      }
      try replaceConditions(snapshot)
      try linkSnapshotArtifacts(snapshot)
      if let jobID = event.jobID {
        try linkRuntimeJob(
          taskID: event.htaskID, jobID: jobID, requestID: nil,
          round: snapshot.activeRound, atUTC: event.atUTC)
      }
    }
  }

  func events(_ taskID: String) throws -> [HarnessTaskEvent] {
    guard try containsTask(taskID) else { throw HarnessTaskStoreError.notFound(taskID) }
    return try database.query(
      "SELECT event_json, event_digest FROM task_event WHERE task_id = ? ORDER BY sequence",
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "event_json", digestColumn: "event_digest")
      return try HarnessSQLiteDatabase.decode(HarnessTaskEvent.self, from: data)
    }
  }

  // MARK: - Round records

  func putDecision(_ decision: HarnessDecision) throws {
    try requireTask(decision.htaskID)
    if let intent = try intent(decision.htaskID, round: decision.round),
      intent.state == .pending || intent.state == .submitted || intent.state == .linked
    {
      guard let stored = try self.decision(decision.htaskID, round: decision.round),
        stored == decision,
        intent.decisionID == decision.decisionID
      else {
        throw HarnessTaskStoreError.corrupt(
          "decision \(intent.decisionID) is owned by \(intent.state.rawValue) intent "
            + "\(intent.requestID)")
      }
    }
    let data = try canonical(decision)
    try database.run(
      """
      INSERT INTO decision(task_id, round, decision_id, decision_json, decision_digest)
      VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(task_id, round) DO UPDATE SET
        decision_id=excluded.decision_id,
        decision_json=excluded.decision_json,
        decision_digest=excluded.decision_digest
      """,
      [
        .text(decision.htaskID), .integer(Int64(decision.round)),
        .text(decision.decisionID), .blob(data),
        .text(HarnessSQLiteDatabase.digest(data)),
      ])
  }

  func decision(_ taskID: String, round: Int) throws -> HarnessDecision? {
    try requireTask(taskID)
    guard
      let row = try database.query(
        "SELECT decision_json, decision_digest FROM decision WHERE task_id = ? AND round = ?",
        [.text(taskID), .integer(Int64(round))]
      ).first
    else { return nil }
    let data = try verifiedData(
      row, jsonColumn: "decision_json", digestColumn: "decision_digest")
    return try HarnessSQLiteDatabase.decode(HarnessDecision.self, from: data)
  }

  func putIntent(_ intent: HarnessDispatchIntent) throws {
    try requireTask(intent.htaskID)
    if let stored = try self.intent(intent.htaskID, round: intent.round),
      stored.state == .pending || stored.state == .submitted || stored.state == .linked
    {
      let sameExecutionIdentity =
        stored.schemaVersion == intent.schemaVersion
        && stored.decisionID == intent.decisionID
        && stored.attemptID == intent.attemptID
        && stored.modelRunID == intent.modelRunID
        && stored.operationReference == intent.operationReference
        && stored.targetID == intent.targetID
        && stored.expectedBindingRevision == intent.expectedBindingRevision
        && stored.expectedWorkspaceRevision == intent.expectedWorkspaceRevision
        && stored.expectedDeployedArtifactDigest == intent.expectedDeployedArtifactDigest
        && stored.inputsDigestSHA256 == intent.inputsDigestSHA256
        && stored.requestID == intent.requestID
        && stored.idempotencyKey == intent.idempotencyKey
        && stored.createdAtUTC == intent.createdAtUTC
      guard sameExecutionIdentity else {
        throw HarnessTaskStoreError.corrupt(
          "\(stored.state.rawValue) intent \(stored.requestID) execution identity is immutable")
      }
    }
    let data = try canonical(intent)
    try database.transaction {
      try database.run(
        """
        INSERT INTO dispatch_intent(task_id, round, request_id, intent_json, intent_digest)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(task_id, round) DO UPDATE SET
          request_id=excluded.request_id,
          intent_json=excluded.intent_json,
          intent_digest=excluded.intent_digest
        """,
        [
          .text(intent.htaskID), .integer(Int64(intent.round)), .text(intent.requestID),
          .blob(data), .text(HarnessSQLiteDatabase.digest(data)),
        ])
      if let jobID = intent.jobID {
        try linkRuntimeJob(
          taskID: intent.htaskID, jobID: jobID, requestID: intent.requestID,
          round: intent.round, atUTC: intent.updatedAtUTC)
      }
    }
  }

  func intent(_ taskID: String, round: Int) throws -> HarnessDispatchIntent? {
    try requireTask(taskID)
    guard
      let row = try database.query(
        "SELECT intent_json, intent_digest FROM dispatch_intent WHERE task_id = ? AND round = ?",
        [.text(taskID), .integer(Int64(round))]
      ).first
    else { return nil }
    let data = try verifiedData(
      row, jsonColumn: "intent_json", digestColumn: "intent_digest")
    return try HarnessSQLiteDatabase.decode(HarnessDispatchIntent.self, from: data)
  }

  func intents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try requireTask(taskID)
    return try database.query(
      "SELECT intent_json, intent_digest FROM dispatch_intent WHERE task_id = ? ORDER BY round",
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "intent_json", digestColumn: "intent_digest")
      return try HarnessSQLiteDatabase.decode(HarnessDispatchIntent.self, from: data)
    }
  }

  // MARK: - Attempts

  func recordAttempt(
    _ attempt: HarnessAttempt,
    kind: HarnessAttemptEventKind,
    reasonCode: String
  ) throws {
    try database.transaction {
      try requireTask(attempt.htaskID)
      let existingEvents = try attemptEvents(attempt.htaskID)
      let current = existingEvents.last(where: { $0.attemptID == attempt.attemptID })?.resulting
      try validateAttempt(
        attempt, kind: kind, current: current, events: existingEvents)
      let event = HarnessAttemptEvent(
        sequence: (existingEvents.last?.sequence ?? 0) + 1,
        kind: kind, reasonCode: reasonCode, atUTC: attempt.updatedAtUTC,
        resulting: attempt)
      try database.transaction {
        let attemptData = try canonical(attempt)
        try database.run(
          """
          INSERT INTO attempt(task_id, attempt_id, ordinal, attempt_json, attempt_digest)
          VALUES(?, ?, ?, ?, ?)
          ON CONFLICT(task_id, attempt_id) DO UPDATE SET
            ordinal=excluded.ordinal,
            attempt_json=excluded.attempt_json,
            attempt_digest=excluded.attempt_digest
          """,
          [
            .text(attempt.htaskID), .text(attempt.attemptID),
            .integer(Int64(attempt.ordinal)), .blob(attemptData),
            .text(HarnessSQLiteDatabase.digest(attemptData)),
          ])
        let eventData = try canonical(event)
        try database.run(
          """
          INSERT INTO attempt_event(task_id, attempt_id, sequence, event_json, event_digest)
          VALUES(?, ?, ?, ?, ?)
          """,
          [
            .text(attempt.htaskID), .text(attempt.attemptID),
            .integer(Int64(event.sequence)), .blob(eventData),
            .text(HarnessSQLiteDatabase.digest(eventData)),
          ])
        for actionRunID in attempt.actionRunIDs {
          try database.run(
            """
            INSERT OR IGNORE INTO action_run(
              task_id, action_run_id, attempt_id, recorded_at_utc
            ) VALUES(?, ?, ?, ?)
            """,
            [
              .text(attempt.htaskID), .text(actionRunID), .text(attempt.attemptID),
              .text(attempt.updatedAtUTC),
            ])
        }
      }
    }
  }

  func attemptEvents(_ taskID: String) throws -> [HarnessAttemptEvent] {
    try requireTask(taskID)
    let events: [HarnessAttemptEvent] = try database.query(
      "SELECT event_json, event_digest FROM attempt_event WHERE task_id = ? ORDER BY sequence",
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "event_json", digestColumn: "event_digest")
      return try HarnessSQLiteDatabase.decode(HarnessAttemptEvent.self, from: data)
    }
    for (index, event) in events.enumerated() where event.sequence != index + 1 {
      throw HarnessTaskStoreError.corrupt(
        "attempt event sequence \(event.sequence) does not follow \(index)")
    }
    return events
  }

  func attempts(_ taskID: String) throws -> [HarnessAttempt] {
    try requireTask(taskID)
    return try database.query(
      """
      SELECT attempt_json, attempt_digest FROM attempt
      WHERE task_id = ? ORDER BY ordinal, attempt_id
      """,
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "attempt_json", digestColumn: "attempt_digest")
      return try HarnessSQLiteDatabase.decode(HarnessAttempt.self, from: data)
    }
  }

  // MARK: - Model, evaluation and human records

  func putModelRun(_ run: HarnessModelRun) throws {
    try requireTask(run.htaskID)
    let data = try canonical(run)
    let manifest = HarnessContextManifestRecord(
      htaskID: run.htaskID, modelRunID: run.modelRunID,
      contextDigest: run.contextDigest,
      observedStateVersion: run.observedStateVersion,
      byteCount: run.contextBytes)
    let manifestData = try canonical(manifest)
    try database.transaction {
      try database.run(
        """
        INSERT INTO model_run(task_id, model_run_id, round, run_json, run_digest)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(task_id, model_run_id) DO UPDATE SET
          round=excluded.round, run_json=excluded.run_json, run_digest=excluded.run_digest
        """,
        [
          .text(run.htaskID), .text(run.modelRunID), .integer(Int64(run.round)),
          .blob(data), .text(HarnessSQLiteDatabase.digest(data)),
        ])
      try database.run(
        """
        INSERT INTO context_manifest(
          task_id, context_digest, model_run_id, observed_state_version,
          byte_count, manifest_json, manifest_digest
        ) VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(task_id, context_digest, model_run_id) DO UPDATE SET
          observed_state_version=excluded.observed_state_version,
          byte_count=excluded.byte_count,
          manifest_json=excluded.manifest_json,
          manifest_digest=excluded.manifest_digest
        """,
        [
          .text(run.htaskID), .text(run.contextDigest), .text(run.modelRunID),
          .integer(Int64(run.observedStateVersion)), .integer(Int64(run.contextBytes)),
          .blob(manifestData), .text(HarnessSQLiteDatabase.digest(manifestData)),
        ])
    }
  }

  func modelRuns(_ taskID: String) throws -> [HarnessModelRun] {
    try requireTask(taskID)
    return try database.query(
      "SELECT run_json, run_digest FROM model_run WHERE task_id = ? ORDER BY round, model_run_id",
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "run_json", digestColumn: "run_digest")
      return try HarnessSQLiteDatabase.decode(HarnessModelRun.self, from: data)
    }
  }

  func putEvaluation(_ evaluation: HarnessEvaluation) throws {
    try requireTask(evaluation.htaskID)
    let data = try canonical(evaluation)
    try database.transaction {
      try database.run(
        """
        INSERT INTO evaluation(
          task_id, evaluation_id, round, evaluation_json, evaluation_digest
        ) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(task_id, evaluation_id) DO UPDATE SET
          round=excluded.round,
          evaluation_json=excluded.evaluation_json,
          evaluation_digest=excluded.evaluation_digest
        """,
        [
          .text(evaluation.htaskID), .text(evaluation.evaluationID),
          .integer(Int64(evaluation.round)), .blob(data),
          .text(HarnessSQLiteDatabase.digest(data)),
        ])
      for evidence in evaluation.evidence {
        try linkArtifact(
          taskID: evaluation.htaskID, artifactID: evidence.artifactID,
          source: "evaluation:\(evaluation.evaluationID)", atUTC: evaluation.createdAtUTC)
      }
    }
  }

  func evaluation(_ taskID: String, evaluationID: String) throws -> HarnessEvaluation? {
    try requireTask(taskID)
    guard
      let row = try database.query(
        """
        SELECT evaluation_json, evaluation_digest FROM evaluation
        WHERE task_id = ? AND evaluation_id = ?
        """,
        [.text(taskID), .text(evaluationID)]
      ).first
    else { return nil }
    let data = try verifiedData(
      row, jsonColumn: "evaluation_json", digestColumn: "evaluation_digest")
    return try HarnessSQLiteDatabase.decode(HarnessEvaluation.self, from: data)
  }

  func evaluations(_ taskID: String) throws -> [HarnessEvaluation] {
    try requireTask(taskID)
    return try database.query(
      """
      SELECT evaluation_json, evaluation_digest FROM evaluation
      WHERE task_id = ? ORDER BY round, evaluation_id
      """,
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "evaluation_json", digestColumn: "evaluation_digest")
      return try HarnessSQLiteDatabase.decode(HarnessEvaluation.self, from: data)
    }
  }

  func putHumanAction(_ action: HarnessStoredHumanAction) throws {
    try requireTask(action.htaskID)
    let data = try canonical(action)
    try database.run(
      """
      INSERT INTO human_action(
        task_id, action_id, action_json, action_digest, generated_at_utc
      ) VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(task_id, action_id) DO UPDATE SET
        action_json=excluded.action_json,
        action_digest=excluded.action_digest,
        generated_at_utc=excluded.generated_at_utc
      """,
      [
        .text(action.htaskID), .text(action.actionID), .blob(data),
        .text(HarnessSQLiteDatabase.digest(data)), .text(action.generatedAtUTC),
      ])
  }

  func humanActions(_ taskID: String) throws -> [HarnessStoredHumanAction] {
    try requireTask(taskID)
    return try database.query(
      """
      SELECT action_json, action_digest FROM human_action
      WHERE task_id = ? ORDER BY generated_at_utc, action_id
      """,
      [.text(taskID)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "action_json", digestColumn: "action_digest")
      return try HarnessSQLiteDatabase.decode(HarnessStoredHumanAction.self, from: data)
    }
  }

  // MARK: - Memory and FTS

  func putFailureRecord(_ record: HarnessFailureRecord) throws {
    let data = try canonical(record)
    try insertMemoryRow(
      taskID: nil, scope: HarnessMemoryScope.failure.rawValue,
      scopeKey: record.digest, memoryID: record.digest, lifecycle: "FAILURE",
      summary: record.lastReasonCode, data: data, updatedAtUTC: record.lastSeenUTC)
  }

  func failureRecord(digest: String) throws -> HarnessFailureRecord? {
    guard
      let row = try database.query(
        """
        SELECT entry_json, entry_digest FROM memory_entry
        WHERE scope = ? AND scope_key = ? ORDER BY entry_id DESC LIMIT 1
        """,
        [.text(HarnessMemoryScope.failure.rawValue), .text(digest)]
      )
      .first
    else { return nil }
    let data = try verifiedData(
      row, jsonColumn: "entry_json", digestColumn: "entry_digest")
    return try HarnessSQLiteDatabase.decode(HarnessFailureRecord.self, from: data)
  }

  func failureRecords() throws -> [HarnessFailureRecord] {
    let rows = try database.query(
      """
      SELECT m.entry_json, m.entry_digest
      FROM memory_entry m
      JOIN (
        SELECT scope_key, MAX(entry_id) AS entry_id
        FROM memory_entry WHERE scope = ? GROUP BY scope_key
      ) latest ON latest.entry_id = m.entry_id
      ORDER BY m.updated_at_utc, m.scope_key
      """,
      [.text(HarnessMemoryScope.failure.rawValue)])
    return try rows.compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "entry_json", digestColumn: "entry_digest")
      return try HarnessSQLiteDatabase.decode(HarnessFailureRecord.self, from: data)
    }
  }

  func appendMemory(_ entry: HarnessMemoryEntry) throws {
    let key: String
    switch entry.scope {
    case .task:
      key = entry.htaskID
    case .project:
      guard let projectRef = entry.projectRef else {
        throw HarnessTaskStoreError.corrupt("project memory has no project ref")
      }
      key = projectRef
    case .failure:
      throw HarnessTaskStoreError.corrupt("failure memory uses putFailureRecord")
    }
    let data = try canonical(entry)
    let taskID = try containsTask(entry.htaskID) ? entry.htaskID : nil
    try insertMemoryRow(
      taskID: taskID, scope: entry.scope.rawValue, scopeKey: key,
      memoryID: entry.memoryID, lifecycle: entry.lifecycle.rawValue,
      summary: entry.summary, data: data, updatedAtUTC: entry.updatedAtUTC)
  }

  func memoryHistory(scope: HarnessMemoryScope, key: String) throws -> [HarnessMemoryEntry] {
    try database.query(
      """
      SELECT entry_json, entry_digest FROM memory_entry
      WHERE scope = ? AND scope_key = ? ORDER BY entry_id
      """,
      [.text(scope.rawValue), .text(key)]
    ).compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "entry_json", digestColumn: "entry_digest")
      return try HarnessSQLiteDatabase.decode(HarnessMemoryEntry.self, from: data)
    }
  }

  func memory(scope: HarnessMemoryScope, key: String) throws -> [HarnessMemoryEntry] {
    HarnessMemorySelector.collapse(try memoryHistory(scope: scope, key: key))
  }

  func searchMemory(
    scope: HarnessMemoryScope,
    key: String,
    query: String,
    limit: Int
  ) throws -> [HarnessMemoryEntry] {
    guard limit > 0, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }
    let rows = try database.query(
      """
      SELECT m.entry_json, m.entry_digest
      FROM memory_fts f
      JOIN memory_entry m ON m.entry_id = f.rowid
      WHERE memory_fts MATCH ? AND m.scope = ? AND m.scope_key = ?
      ORDER BY bm25(memory_fts), m.entry_id DESC LIMIT ?
      """,
      [.text(query), .text(scope.rawValue), .text(key), .integer(Int64(limit))])
    let decoded: [HarnessMemoryEntry] = try rows.compactMap { row in
      let data = try verifiedData(
        row, jsonColumn: "entry_json", digestColumn: "entry_digest")
      return try HarnessSQLiteDatabase.decode(HarnessMemoryEntry.self, from: data)
    }
    return HarnessMemorySelector.collapse(decoded)
  }

  // MARK: - Task-level reconcile lease

  func acquireReconcileLease(
    taskID: String,
    holderID: String,
    now: Date,
    ttl: TimeInterval
  ) throws -> Bool {
    try requireTask(taskID)
    guard !holderID.isEmpty, ttl > 0, ttl.isFinite else {
      throw HarnessTaskStoreError.corrupt("invalid reconcile lease")
    }
    let nowValue = now.timeIntervalSince1970
    let changed = try database.run(
      """
      INSERT INTO reconcile_lease(task_id, holder_id, expires_at_unix)
      VALUES(?, ?, ?)
      ON CONFLICT(task_id) DO UPDATE SET
        holder_id=excluded.holder_id,
        expires_at_unix=excluded.expires_at_unix
      WHERE reconcile_lease.holder_id = excluded.holder_id
         OR reconcile_lease.expires_at_unix <= ?
      """,
      [.text(taskID), .text(holderID), .real(nowValue + ttl), .real(nowValue)])
    return changed == 1
  }

  func releaseReconcileLease(taskID: String, holderID: String) throws {
    try database.run(
      "DELETE FROM reconcile_lease WHERE task_id = ? AND holder_id = ?",
      [.text(taskID), .text(holderID)])
  }

  // MARK: - Diagnostics used by contract tests

  func configuration() throws -> HarnessSQLiteConfiguration {
    try database.configuration()
  }

  func rowCount(table: String) throws -> Int {
    let allowed: Set<String> = [
      "harness_task", "task_event", "task_condition", "attempt", "attempt_event",
      "model_run", "decision", "action_run", "dispatch_intent", "runtime_job_link",
      "artifact_link", "evaluation", "human_action", "memory_entry", "memory_fts",
      "context_manifest", "reconcile_lease", "schema_migration", "storage_metadata",
    ]
    guard allowed.contains(table) else {
      throw HarnessTaskStoreError.corrupt("unsupported sqlite diagnostics table")
    }
    return Int(
      try database.query("SELECT COUNT(*) AS count FROM \(table)")
        .first?.integer("count") ?? 0)
  }

  // MARK: - Shared normalized writes

  private func insertTask(_ snapshot: HarnessTaskSnapshot, replace: Bool) throws {
    let data = try canonical(snapshot)
    let resultData = try snapshot.result.map(canonical)
    let verb = replace ? "INSERT OR REPLACE" : "INSERT"
    try database.run(
      """
      \(verb) INTO harness_task(
        task_id, state_version, snapshot_json, snapshot_digest, result_json,
        created_at_utc, updated_at_utc
      ) VALUES(?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(snapshot.htaskID), .integer(Int64(snapshot.version)), .blob(data),
        .text(HarnessSQLiteDatabase.digest(data)), blobOrNull(resultData),
        .text(snapshot.createdAtUTC), .text(snapshot.updatedAtUTC),
      ])
    try replaceConditions(snapshot)
    try linkSnapshotArtifacts(snapshot)
  }

  private func replaceConditions(_ snapshot: HarnessTaskSnapshot) throws {
    try database.run("DELETE FROM task_condition WHERE task_id = ?", [.text(snapshot.htaskID)])
    for condition in snapshot.conditions {
      let data = try canonical(condition)
      try database.run(
        """
        INSERT INTO task_condition(
          task_id, name, condition_json, condition_digest
        ) VALUES(?, ?, ?, ?)
        """,
        [
          .text(snapshot.htaskID), .text(condition.name.rawValue), .blob(data),
          .text(HarnessSQLiteDatabase.digest(data)),
        ])
      for artifactID in condition.evidenceArtifactIDs {
        try linkArtifact(
          taskID: snapshot.htaskID, artifactID: artifactID,
          source: "condition:\(condition.name.rawValue)",
          atUTC: condition.observedAt ?? snapshot.updatedAtUTC)
      }
    }
  }

  private func linkSnapshotArtifacts(_ snapshot: HarnessTaskSnapshot) throws {
    for artifactID in snapshot.artifactRefs {
      try linkArtifact(
        taskID: snapshot.htaskID, artifactID: artifactID,
        source: "snapshot", atUTC: snapshot.updatedAtUTC)
    }
  }

  private func linkArtifact(
    taskID: String, artifactID: String, source: String, atUTC: String
  ) throws {
    try database.run(
      """
      INSERT OR IGNORE INTO artifact_link(task_id, artifact_id, source, linked_at_utc)
      VALUES(?, ?, ?, ?)
      """,
      [.text(taskID), .text(artifactID), .text(source), .text(atUTC)])
  }

  private func linkRuntimeJob(
    taskID: String, jobID: String, requestID: String?, round: Int?, atUTC: String
  ) throws {
    try database.run(
      """
      INSERT INTO runtime_job_link(task_id, job_id, request_id, round, linked_at_utc)
      VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(task_id, job_id) DO UPDATE SET
        request_id=COALESCE(excluded.request_id, runtime_job_link.request_id),
        round=COALESCE(excluded.round, runtime_job_link.round)
      """,
      [
        .text(taskID), .text(jobID), textOrNull(requestID),
        round.map { .integer(Int64($0)) } ?? .null, .text(atUTC),
      ])
  }

  private func insertMemoryRow(
    taskID: String?, scope: String, scopeKey: String, memoryID: String,
    lifecycle: String, summary: String, data: Data, updatedAtUTC: String
  ) throws {
    try database.transaction {
      try database.run(
        """
        INSERT INTO memory_entry(
          task_id, scope, scope_key, memory_id, lifecycle, summary,
          entry_json, entry_digest, updated_at_utc
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          textOrNull(taskID), .text(scope), .text(scopeKey), .text(memoryID),
          .text(lifecycle), .text(summary), .blob(data),
          .text(HarnessSQLiteDatabase.digest(data)), .text(updatedAtUTC),
        ])
      let rowID = database.lastInsertedRowID
      try database.run(
        "INSERT INTO memory_fts(rowid, summary) VALUES(?, ?)",
        [.integer(rowID), .text(summary)])
    }
  }

  private func requireTask(_ taskID: String) throws {
    guard try containsTask(taskID) else { throw HarnessTaskStoreError.notFound(taskID) }
  }

  private func canonical<T: Encodable>(_ value: T) throws -> Data {
    try HarnessSQLiteDatabase.canonicalData(value)
  }

  private func verifiedData(
    _ row: HarnessSQLiteRow,
    jsonColumn: String,
    digestColumn: String
  ) throws -> Data {
    guard let data = row.blob(jsonColumn), let digest = row.text(digestColumn) else {
      throw HarnessTaskStoreError.corrupt("sqlite row is missing \(jsonColumn) integrity data")
    }
    guard HarnessSQLiteDatabase.digest(data) == digest else {
      throw HarnessTaskStoreError.corrupt("sqlite \(jsonColumn) digest mismatch")
    }
    return data
  }

  private func blobOrNull(_ value: Data?) -> HarnessSQLiteValue {
    value.map(HarnessSQLiteValue.blob) ?? .null
  }

  private func textOrNull(_ value: String?) -> HarnessSQLiteValue {
    value.map(HarnessSQLiteValue.text) ?? .null
  }

  private func validateAttempt(
    _ attempt: HarnessAttempt,
    kind: HarnessAttemptEventKind,
    current: HarnessAttempt?,
    events: [HarnessAttemptEvent]
  ) throws {
    switch kind {
    case .created:
      guard current == nil else {
        throw HarnessTaskStoreError.corrupt("attempt \(attempt.attemptID) already exists")
      }
      guard attempt.ordinal >= 1,
        !events.contains(where: { $0.resulting.ordinal == attempt.ordinal }),
        attempt.outcome == .active,
        attempt.strategyFingerprint == attempt.strategy.fingerprint,
        attempt.baseRevision == attempt.strategy.baseWorkspaceRevision
      else {
        throw HarnessTaskStoreError.corrupt("invalid created attempt \(attempt.attemptID)")
      }
    case .actionRunRecorded, .patchRevisionObserved, .candidatePatchRecorded,
      .buildArtifactsRecorded, .runtimeArtifactsRecorded, .failureRecorded,
      .evaluationRecorded, .promotionRecorded, .resumed, .closed:
      guard let current else {
        throw HarnessTaskStoreError.corrupt("unknown attempt \(attempt.attemptID)")
      }
      let validHumanResume =
        kind == .resumed && current.outcome == .humanRequired && attempt.outcome == .active
      guard current.htaskID == attempt.htaskID,
        current.ordinal == attempt.ordinal,
        current.strategyFingerprint == attempt.strategyFingerprint,
        current.baseRevision == attempt.baseRevision,
        Set(current.actionRunIDs).isSubset(of: Set(attempt.actionRunIDs)),
        Set(current.evaluationIDs).isSubset(of: Set(attempt.evaluationIDs)),
        Set(current.confirmedFacts).isSubset(of: Set(attempt.confirmedFacts)),
        Set(current.disprovedFacts).isSubset(of: Set(attempt.disprovedFacts)),
        Set(current.buildArtifactIDs).isSubset(of: Set(attempt.buildArtifactIDs)),
        Set(current.runtimeArtifactIDs).isSubset(of: Set(attempt.runtimeArtifactIDs)),
        current.evolutionWorkspace == nil
          || current.evolutionWorkspace == attempt.evolutionWorkspace,
        current.candidatePatch == nil || current.candidatePatch == attempt.candidatePatch,
        current.promotionCandidate == nil
          || current.promotionCandidate == attempt.promotionCandidate,
        !(current.outcome.isClosed && attempt.outcome == .active) || validHumanResume
      else {
        throw HarnessTaskStoreError.corrupt(
          "attempt \(attempt.attemptID) update regressed an immutable field")
      }
    }
  }
}
