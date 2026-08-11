// Durable harness task store (TASK-HFA-012).
//
// SQLite is authoritative: event append and snapshot CAS share one
// transaction, WAL and foreign keys are mandatory, and every typed document
// is held as canonical JSON plus its digest.

import ArkDeckCore
import Darwin
import Foundation

package enum HarnessTaskStoreError: Error, Equatable, Sendable {
  case malformedTaskID(String)
  case ioFailure(String)
  case notFound(String)
  case alreadyExists(String)
  case versionConflict(expected: Int, actual: Int)
  case corrupt(String)
}

package actor HarnessTaskStore {
  private let repository: HarnessSQLiteRepository

  public init(rootURL: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create harness task root: \(error)")
    }
    self.repository = try HarnessSQLiteRepository(rootURL: rootURL)
  }

  // MARK: - Task identity

  /// `HTASK-` plus uppercase hex. No dot, no slash, no unicode: the id is
  /// the directory name, so a traversal or a symlink hop cannot be spelled.
  /// One grammar for every store identifier: `PREFIX-` + 1...n uppercase-hex
  /// characters, bounded to 40 total. `minimumCount` tightens task IDs whose
  /// grammar predates the shared spelling.
  private static func isWellFormedStoreID(
    _ value: String, prefix: String, minimumCount: Int = 0
  ) -> Bool {
    guard value.count >= minimumCount, value.count <= 40, value.hasPrefix(prefix)
    else { return false }
    let body = value.dropFirst(prefix.count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  package static func isWellFormed(taskID: String) -> Bool {
    isWellFormedStoreID(taskID, prefix: "HTASK-", minimumCount: 8)
  }

  // MARK: - Task lifecycle

  public func create(_ snapshot: HarnessTaskSnapshot) throws {
    try repository.create(snapshot)
  }

  public func load(_ taskID: String) throws -> HarnessTaskSnapshot {
    try ensureSQLiteTask(taskID)
    return try repository.load(taskID)
  }

  public func list() throws -> [HarnessTaskSnapshot] {
    try repository.list()
  }

  /// Append the event and replace the snapshot with a CAS in one SQLite
  /// transaction.
  public func commit(
    event: HarnessTaskEvent,
    snapshot: HarnessTaskSnapshot,
    expectedVersion: Int
  ) throws {
    try ensureSQLiteTask(snapshot.htaskID)
    try repository.commit(
      event: event, snapshot: snapshot, expectedVersion: expectedVersion)
  }

  public func events(_ taskID: String) throws -> [HarnessTaskEvent] {
    try ensureSQLiteTask(taskID)
    return try repository.events(taskID)
  }

  // MARK: - Round records

  package func putDecision(_ decision: HarnessDecision) throws {
    try ensureSQLiteTask(decision.htaskID)
    try repository.putDecision(decision)
  }

  public func decision(_ taskID: String, round: Int) throws -> HarnessDecision? {
    try ensureSQLiteTask(taskID)
    return try repository.decision(taskID, round: round)
  }

  package func putIntent(_ intent: HarnessDispatchIntent) throws {
    try ensureSQLiteTask(intent.htaskID)
    try repository.putIntent(intent)
  }

  public func intent(_ taskID: String, round: Int) throws -> HarnessDispatchIntent? {
    try ensureSQLiteTask(taskID)
    return try repository.intent(taskID, round: round)
  }

  package func intents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try ensureSQLiteTask(taskID)
    return try repository.intents(taskID)
  }

  /// Intents recovery must still resolve before a task may dispatch
  /// anything new. `rejected` is excluded on purpose: the engine refused
  /// it, zero side effect happened, and re-submitting an identical request
  /// would be refused again.
  package func unresolvedIntents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try intents(taskID).filter { $0.state == .pending || $0.state == .submitted }
  }

  // MARK: - Strategy attempts (TASK-HFA-004)

  package static func isWellFormed(attemptID: String) -> Bool {
    isWellFormedStoreID(attemptID, prefix: "ATTEMPT-")
  }

  /// Append an immutable attempt event. The event log is the truth; each
  /// event carries the complete resulting Attempt, so a torn final append is
  /// ignored and no separate mutable cache can diverge from it.
  package func recordAttempt(
    _ attempt: HarnessAttempt,
    kind: HarnessAttemptEventKind,
    reasonCode: String
  ) throws {
    guard Self.isWellFormed(attemptID: attempt.attemptID) else {
      throw HarnessTaskStoreError.corrupt("malformed attempt id \(attempt.attemptID)")
    }
    try ensureSQLiteTask(attempt.htaskID)
    try repository.recordAttempt(attempt, kind: kind, reasonCode: reasonCode)
  }

  package func attemptEvents(_ taskID: String) throws -> [HarnessAttemptEvent] {
    try ensureSQLiteTask(taskID)
    return try repository.attemptEvents(taskID)
  }

  public func attempts(_ taskID: String) throws -> [HarnessAttempt] {
    try ensureSQLiteTask(taskID)
    return try repository.attempts(taskID)
  }

  // MARK: - Model runs

  /// A model run id is a file name, so its grammar excludes separators for
  /// the same reason an evaluation id does: a record cannot be written
  /// outside its own task directory (CHG-2026-055, TASK-HFA-002).
  package static func isWellFormed(modelRunID: String) -> Bool {
    isWellFormedStoreID(modelRunID, prefix: "MRUN-")
  }

  /// Several runs can belong to one round - a refused proposal is still a
  /// call that happened - so they are files under the round, not one file
  /// per round that a later run would overwrite.
  package func putModelRun(_ run: HarnessModelRun) throws {
    guard Self.isWellFormed(modelRunID: run.modelRunID) else {
      throw HarnessTaskStoreError.corrupt("malformed model run id \(run.modelRunID)")
    }
    try ensureSQLiteTask(run.htaskID)
    try repository.putModelRun(run)
  }

  package func modelRuns(_ taskID: String) throws -> [HarnessModelRun] {
    try ensureSQLiteTask(taskID)
    return try repository.modelRuns(taskID)
  }

  // MARK: - Evaluations

  /// Evaluations are immutable records: the id is the file name and its
  /// grammar excludes separators, so an evaluation cannot be written outside
  /// its own task directory.
  package static func isWellFormed(evaluationID: String) -> Bool {
    isWellFormedStoreID(evaluationID, prefix: "EVAL-")
  }

  package func putEvaluation(_ evaluation: HarnessEvaluation) throws {
    guard Self.isWellFormed(evaluationID: evaluation.evaluationID) else {
      throw HarnessTaskStoreError.corrupt("malformed evaluation id \(evaluation.evaluationID)")
    }
    try ensureSQLiteTask(evaluation.htaskID)
    try repository.putEvaluation(evaluation)
  }

  package func evaluation(_ taskID: String, evaluationID: String) throws -> HarnessEvaluation? {
    guard Self.isWellFormed(evaluationID: evaluationID) else {
      throw HarnessTaskStoreError.corrupt("malformed evaluation id \(evaluationID)")
    }
    try ensureSQLiteTask(taskID)
    return try repository.evaluation(taskID, evaluationID: evaluationID)
  }

  public func evaluations(_ taskID: String) throws -> [HarnessEvaluation] {
    try ensureSQLiteTask(taskID)
    return try repository.evaluations(taskID)
  }

  // MARK: - Memory and human actions (TASK-HTP-003)

  /// Failure memory is cross-task on purpose: the second task to attempt the
  /// same doomed thing must inherit the first one's evidence. The record is
  /// named after the fingerprint digest, whose grammar has no separators.
  package func failureRecord(digest: String) throws -> HarnessFailureRecord? {
    guard Self.isWellFormed(failureDigest: digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(digest)")
    }
    return try repository.failureRecord(digest: digest)
  }

  package func putFailureRecord(_ record: HarnessFailureRecord) throws {
    guard Self.isWellFormed(failureDigest: record.digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(record.digest)")
    }
    try repository.putFailureRecord(record)
  }

  /// Every failure record, so a decision context can carry "these approaches
  /// are already known bad" instead of letting a producer rediscover them.
  package func failureRecords() throws -> [HarnessFailureRecord] {
    try repository.failureRecords()
  }

  package func appendMemory(_ entry: HarnessMemoryEntry) throws {
    switch entry.scope {
    case .task:
      break
    case .project:
      // Project memory is keyed by project, not by the task that earned it.
      guard let projectRef = entry.projectRef,
        projectRef.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }), !projectRef.isEmpty, !projectRef.hasPrefix(".")
      else {
        throw HarnessTaskStoreError.corrupt("malformed project ref for memory promotion")
      }
    case .failure:
      throw HarnessTaskStoreError.corrupt("failure memory uses putFailureRecord")
    }
    try repository.appendMemory(entry)
  }

  package func memory(scope: HarnessMemoryScope, key: String) throws -> [HarnessMemoryEntry] {
    try repository.memory(scope: scope, key: key)
  }

  package func memoryHistory(
    scope: HarnessMemoryScope,
    key: String
  ) throws -> [HarnessMemoryEntry] {
    try repository.memoryHistory(scope: scope, key: key)
  }

  /// Human actions live under the task they block, so reading a task's state
  /// and reading why it is blocked never diverge.
  package func putHumanAction(_ action: HarnessStoredHumanAction) throws {
    try ensureSQLiteTask(action.htaskID)
    try repository.putHumanAction(action)
  }

  package func humanActions(_ taskID: String) throws -> [HarnessStoredHumanAction] {
    try ensureSQLiteTask(taskID)
    return try repository.humanActions(taskID)
  }

  package static func isWellFormed(failureDigest digest: String) -> Bool {
    isWellFormedStoreID(digest, prefix: "FAIL-")
  }

  /// Full-text lookup is scoped before ranking. It cannot make project
  /// memory applicable by itself; callers still run the typed exact-scope
  /// selector over these candidates.
  package func searchMemory(
    scope: HarnessMemoryScope,
    key: String,
    query: String,
    limit: Int = 50
  ) throws -> [HarnessMemoryEntry] {
    try repository.searchMemory(scope: scope, key: key, query: query, limit: limit)
  }

  /// A database lease complements the actor-local reentrancy gate. It keeps
  /// two daemon processes from reconciling the same task concurrently and
  /// expires after a crash.
  package func acquireReconcileLease(
    taskID: String,
    holderID: String,
    now: Date = Date(),
    ttl: TimeInterval = 300
  ) throws -> Bool {
    try ensureSQLiteTask(taskID)
    return try repository.acquireReconcileLease(
      taskID: taskID, holderID: holderID, now: now, ttl: ttl)
  }

  package func releaseReconcileLease(taskID: String, holderID: String) throws {
    try repository.releaseReconcileLease(taskID: taskID, holderID: holderID)
  }

  func sqliteConfiguration() throws -> HarnessSQLiteConfiguration {
    try repository.configuration()
  }

  func sqliteRowCount(_ table: String) throws -> Int {
    try repository.rowCount(table: table)
  }

  func commitForTesting(
    event: HarnessTaskEvent,
    snapshot: HarnessTaskSnapshot,
    expectedVersion: Int,
    failAfterEvent: Bool
  ) throws {
    try ensureSQLiteTask(snapshot.htaskID)
    try repository.commit(
      event: event, snapshot: snapshot, expectedVersion: expectedVersion,
      failAfterEvent: failAfterEvent)
  }

  private func ensureSQLiteTask(_ taskID: String) throws {
    guard Self.isWellFormed(taskID: taskID) else {
      throw HarnessTaskStoreError.malformedTaskID(taskID)
    }
    guard try repository.containsTask(taskID) else {
      throw HarnessTaskStoreError.notFound(taskID)
    }
  }
}
