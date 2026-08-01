// Durable harness task store (TASK-HFA-012).
//
// SQLite is authoritative: event append and snapshot CAS share one
// transaction, WAL and foreign keys are mandatory, and every typed document
// is held as canonical JSON plus its digest. The old durable-file helpers at
// the bottom remain only for one-time import and a non-authoritative mirror
// consumed by older diagnostics. Import never deletes the legacy tree.

import ArkDeckCore
import Darwin
import Foundation

public enum HarnessTaskStoreError: Error, Equatable, Sendable {
  case malformedTaskID(String)
  case ioFailure(String)
  case notFound(String)
  case alreadyExists(String)
  case versionConflict(expected: Int, actual: Int)
  case corrupt(String)
}

public actor HarnessTaskStore {
  private let rootURL: URL
  private let tasksURL: URL
  private let repository: HarnessSQLiteRepository

  public init(rootURL: URL) throws {
    try self.init(rootURL: rootURL, migrationFault: nil)
  }

  init(
    rootURL: URL,
    migrationFault: HarnessTaskStoreMigrationFault?
  ) throws {
    self.rootURL = rootURL
    self.tasksURL = rootURL.appendingPathComponent("tasks", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: tasksURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create harness task root: \(error)")
    }
    self.repository = try HarnessSQLiteRepository(
      rootURL: rootURL, migrationFault: migrationFault)
  }

  // MARK: - Task identity

  /// `HTASK-` plus uppercase hex. No dot, no slash, no unicode: the id is
  /// the directory name, so a traversal or a symlink hop cannot be spelled.
  public static func isWellFormed(taskID: String) -> Bool {
    guard taskID.count >= 8, taskID.count <= 40, taskID.hasPrefix("HTASK-") else { return false }
    let body = taskID.dropFirst("HTASK-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  private func directory(_ taskID: String) throws -> URL {
    guard Self.isWellFormed(taskID: taskID) else {
      throw HarnessTaskStoreError.malformedTaskID(taskID)
    }
    return tasksURL.appendingPathComponent(taskID, isDirectory: true)
  }

  /// Readers and writers of an existing task go through here so an unknown
  /// id reports `notFound` instead of an io failure from locking a directory
  /// that was never created.
  private func existingDirectory(_ taskID: String) throws -> URL {
    let url = try directory(taskID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw HarnessTaskStoreError.notFound(taskID)
    }
    return url
  }

  // MARK: - Task lifecycle

  public func create(_ snapshot: HarnessTaskSnapshot) throws {
    try repository.create(snapshot)
    let directoryURL = try directory(snapshot.htaskID)
    do {
      try FileManager.default.createDirectory(
        at: directoryURL.appendingPathComponent("rounds", isDirectory: true),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      // SQLite already committed. The legacy directory is only a mirror and
      // cannot be allowed to redefine the durable outcome.
      return
    }
    try? withLock(directoryURL) {
      try writeSnapshot(snapshot, in: directoryURL)
    }
  }

  public func load(_ taskID: String) throws -> HarnessTaskSnapshot {
    try ensureSQLiteTask(taskID)
    return try repository.load(taskID)
  }

  public func list() throws -> [HarnessTaskSnapshot] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: tasksURL.path)) ?? []
    for name in names where Self.isWellFormed(taskID: name) {
      try ensureSQLiteTask(name)
    }
    return try repository.list()
  }

  /// Append the event and replace the snapshot with a CAS in one SQLite
  /// transaction. The legacy durable-file mirror below is best-effort and
  /// never authoritative.
  public func commit(
    event: HarnessTaskEvent,
    snapshot: HarnessTaskSnapshot,
    expectedVersion: Int
  ) throws {
    try ensureSQLiteTask(snapshot.htaskID)
    try repository.commit(
      event: event, snapshot: snapshot, expectedVersion: expectedVersion)
    if let directoryURL = try? existingDirectory(snapshot.htaskID) {
      try? withLock(directoryURL) {
        try appendEvent(event, in: directoryURL)
        try writeSnapshot(snapshot, in: directoryURL)
      }
    }
  }

  public func events(_ taskID: String) throws -> [HarnessTaskEvent] {
    try ensureSQLiteTask(taskID)
    return try repository.events(taskID)
  }

  // MARK: - Round records

  public func putDecision(_ decision: HarnessDecision) throws {
    try ensureSQLiteTask(decision.htaskID)
    try repository.putDecision(decision)
  }

  public func decision(_ taskID: String, round: Int) throws -> HarnessDecision? {
    try ensureSQLiteTask(taskID)
    return try repository.decision(taskID, round: round)
  }

  public func putIntent(_ intent: HarnessDispatchIntent) throws {
    try ensureSQLiteTask(intent.htaskID)
    try repository.putIntent(intent)
  }

  public func intent(_ taskID: String, round: Int) throws -> HarnessDispatchIntent? {
    try ensureSQLiteTask(taskID)
    return try repository.intent(taskID, round: round)
  }

  public func intents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try ensureSQLiteTask(taskID)
    return try repository.intents(taskID)
  }

  /// Intents recovery must still resolve before a task may dispatch
  /// anything new. `rejected` is excluded on purpose: the engine refused
  /// it, zero side effect happened, and re-submitting an identical request
  /// would be refused again.
  public func unresolvedIntents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try intents(taskID).filter { $0.state == .pending || $0.state == .submitted }
  }

  // MARK: - Strategy attempts (TASK-HFA-004)

  public static func isWellFormed(attemptID: String) -> Bool {
    guard attemptID.hasPrefix("ATTEMPT-"), attemptID.count <= 40 else { return false }
    let body = attemptID.dropFirst("ATTEMPT-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  /// Append an immutable attempt event. The event log is the truth; each
  /// event carries the complete resulting Attempt, so a torn final append is
  /// ignored and no separate mutable cache can diverge from it.
  public func recordAttempt(
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

  public func attemptEvents(_ taskID: String) throws -> [HarnessAttemptEvent] {
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
  public static func isWellFormed(modelRunID: String) -> Bool {
    guard modelRunID.hasPrefix("MRUN-"), modelRunID.count <= 40 else { return false }
    let body = modelRunID.dropFirst("MRUN-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  /// Several runs can belong to one round - a refused proposal is still a
  /// call that happened - so they are files under the round, not one file
  /// per round that a later run would overwrite.
  public func putModelRun(_ run: HarnessModelRun) throws {
    guard Self.isWellFormed(modelRunID: run.modelRunID) else {
      throw HarnessTaskStoreError.malformedTaskID(run.modelRunID)
    }
    try ensureSQLiteTask(run.htaskID)
    try repository.putModelRun(run)
  }

  public func modelRuns(_ taskID: String) throws -> [HarnessModelRun] {
    try ensureSQLiteTask(taskID)
    return try repository.modelRuns(taskID)
  }

  // MARK: - Evaluations

  /// Evaluations are immutable records: the id is the file name and its
  /// grammar excludes separators, so an evaluation cannot be written outside
  /// its own task directory.
  public static func isWellFormed(evaluationID: String) -> Bool {
    guard evaluationID.hasPrefix("EVAL-"), evaluationID.count <= 40 else { return false }
    let body = evaluationID.dropFirst("EVAL-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  public func putEvaluation(_ evaluation: HarnessEvaluation) throws {
    guard Self.isWellFormed(evaluationID: evaluation.evaluationID) else {
      throw HarnessTaskStoreError.corrupt("malformed evaluation id \(evaluation.evaluationID)")
    }
    try ensureSQLiteTask(evaluation.htaskID)
    try repository.putEvaluation(evaluation)
  }

  public func evaluation(_ taskID: String, evaluationID: String) throws -> HarnessEvaluation? {
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
  public func failureRecord(digest: String) throws -> HarnessFailureRecord? {
    guard Self.isWellFormed(failureDigest: digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(digest)")
    }
    return try repository.failureRecord(digest: digest)
  }

  public func putFailureRecord(_ record: HarnessFailureRecord) throws {
    guard Self.isWellFormed(failureDigest: record.digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(record.digest)")
    }
    try repository.putFailureRecord(record)
  }

  /// Every failure record, so a decision context can carry "these approaches
  /// are already known bad" instead of letting a producer rediscover them.
  public func failureRecords() throws -> [HarnessFailureRecord] {
    try repository.failureRecords()
  }

  public func appendMemory(_ entry: HarnessMemoryEntry) throws {
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

  public func memory(scope: HarnessMemoryScope, key: String) throws -> [HarnessMemoryEntry] {
    try repository.memory(scope: scope, key: key)
  }

  public func memoryHistory(
    scope: HarnessMemoryScope,
    key: String
  ) throws -> [HarnessMemoryEntry] {
    try repository.memoryHistory(scope: scope, key: key)
  }

  /// Human actions live under the task they block, so reading a task's state
  /// and reading why it is blocked never diverge.
  public func putHumanAction(_ action: HarnessStoredHumanAction) throws {
    try ensureSQLiteTask(action.htaskID)
    try repository.putHumanAction(action)
  }

  public func humanActions(_ taskID: String) throws -> [HarnessStoredHumanAction] {
    try ensureSQLiteTask(taskID)
    return try repository.humanActions(taskID)
  }

  public static func isWellFormed(failureDigest digest: String) -> Bool {
    guard digest.hasPrefix("FAIL-"), digest.count <= 40 else { return false }
    let body = digest.dropFirst("FAIL-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  /// Full-text lookup is scoped before ranking. It cannot make project
  /// memory applicable by itself; callers still run the typed exact-scope
  /// selector over these candidates.
  public func searchMemory(
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
  public func acquireReconcileLease(
    taskID: String,
    holderID: String,
    now: Date = Date(),
    ttl: TimeInterval = 300
  ) throws -> Bool {
    try ensureSQLiteTask(taskID)
    return try repository.acquireReconcileLease(
      taskID: taskID, holderID: holderID, now: now, ttl: ttl)
  }

  public func releaseReconcileLease(taskID: String, holderID: String) throws {
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
    if try repository.containsTask(taskID) { return }

    // This path exists for a legacy directory that appeared after store
    // startup (including restore tools). Replaying through the old reducer
    // first preserves the historical forward-migration behavior; the
    // repository then imports the resulting typed state atomically.
    let directoryURL = try existingDirectory(taskID)
    _ = try withLock(directoryURL) {
      try loadLocked(directoryURL, taskID: taskID)
    }
    guard try repository.importLegacyTaskIfPresent(taskID) else {
      throw HarnessTaskStoreError.notFound(taskID)
    }
  }

  // MARK: - Locked helpers

  private func loadLocked(_ directoryURL: URL, taskID: String) throws -> HarnessTaskSnapshot {
    let snapshotURL = directoryURL.appendingPathComponent("task.json")
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
      throw HarnessTaskStoreError.notFound(taskID)
    }
    let snapshot = try readJSON(HarnessTaskSnapshot.self, from: snapshotURL)
    let requiresForwardMigration = snapshot.schemaVersion != HarnessTaskSnapshot.schemaVersion
    let events = try readEvents(in: directoryURL)
    var rebuilt = snapshot
    for event in events where event.sequence >= snapshot.version {
      guard event.sequence == rebuilt.version else {
        throw HarnessTaskStoreError.corrupt(
          "event sequence \(event.sequence) does not follow version \(rebuilt.version)")
      }
      rebuilt = rebuilt.applying(event.resulting, atUTC: event.atUTC)
    }
    if requiresForwardMigration {
      // Only the replaceable cache is migrated. The append-only timeline is
      // the truth and its bytes are never opened for writing here.
      rebuilt = rebuilt.migratedToCurrentSchema()
      try writeSnapshot(rebuilt, in: directoryURL)
    }
    return rebuilt
  }

  private func readEvents(in directoryURL: URL) throws -> [HarnessTaskEvent] {
    let url = directoryURL.appendingPathComponent("events.jsonl")
    guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessTaskStoreError.corrupt("event log is not UTF-8")
    }
    let decoder = JSONDecoder()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    var events: [HarnessTaskEvent] = []
    for (index, line) in lines.enumerated() {
      guard let lineData = line.data(using: .utf8) else {
        throw HarnessTaskStoreError.corrupt("event line is not UTF-8")
      }
      do {
        events.append(try decoder.decode(HarnessTaskEvent.self, from: lineData))
      } catch {
        // A torn *final* line is the one corruption an append log can
        // legitimately produce (write interrupted before fsync returned);
        // anything earlier means the log itself is inconsistent and the
        // task must not be resumed from it.
        guard index == lines.count - 1 else {
          throw HarnessTaskStoreError.corrupt("undecodable event line \(index): \(error)")
        }
      }
    }
    return events.sorted { $0.sequence < $1.sequence }
  }

  private func appendEvent(_ event: HarnessTaskEvent, in directoryURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(event) else {
      throw HarnessTaskStoreError.ioFailure("cannot encode task event")
    }
    let payload = encoded + Data("\n".utf8)
    let url = directoryURL.appendingPathComponent("events.jsonl")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw HarnessTaskStoreError.ioFailure("cannot open task event log")
    }
    defer { close(fd) }
    let written = payload.withUnsafeBytes { buffer -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      var total = 0
      while total < buffer.count {
        let result = write(fd, base + total, buffer.count - total)
        if result <= 0 { return total }
        total += result
      }
      return total
    }
    guard written == payload.count else {
      throw HarnessTaskStoreError.ioFailure("short write to task event log")
    }
    guard fsync(fd) == 0 else {
      throw HarnessTaskStoreError.ioFailure("fsync of task event log failed")
    }
  }

  private func writeSnapshot(_ snapshot: HarnessTaskSnapshot, in directoryURL: URL) throws {
    try writeJSON(snapshot, to: directoryURL.appendingPathComponent("task.json"))
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      throw HarnessTaskStoreError.ioFailure("cannot encode \(url.lastPathComponent)")
    }
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
    let fd = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw HarnessTaskStoreError.ioFailure("cannot open temp file for \(url.lastPathComponent)")
    }
    var closed = false
    defer { if !closed { close(fd) } }
    let written = data.withUnsafeBytes { buffer -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      var total = 0
      while total < buffer.count {
        let result = write(fd, base + total, buffer.count - total)
        if result <= 0 { return total }
        total += result
      }
      return total
    }
    guard written == data.count else {
      unlink(temporaryURL.path)
      throw HarnessTaskStoreError.ioFailure("short write for \(url.lastPathComponent)")
    }
    guard fsync(fd) == 0 else {
      unlink(temporaryURL.path)
      throw HarnessTaskStoreError.ioFailure("fsync failed for \(url.lastPathComponent)")
    }
    close(fd)
    closed = true
    guard rename(temporaryURL.path, url.path) == 0 else {
      unlink(temporaryURL.path)
      throw HarnessTaskStoreError.ioFailure("atomic rename failed for \(url.lastPathComponent)")
    }
    let directoryFD = open(
      url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if directoryFD >= 0 {
      _ = fsync(directoryFD)
      close(directoryFD)
    }
  }

  private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    guard let data = FileManager.default.contents(atPath: url.path) else {
      throw HarnessTaskStoreError.notFound(url.lastPathComponent)
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw HarnessTaskStoreError.corrupt("undecodable \(url.lastPathComponent): \(error)")
    }
  }

  private func withLock<T>(_ directoryURL: URL, _ body: () throws -> T) throws -> T {
    let lockURL = directoryURL.appendingPathComponent(".lock")
    let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw HarnessTaskStoreError.ioFailure("cannot open task lock")
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw HarnessTaskStoreError.ioFailure("cannot acquire task lock")
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
}
