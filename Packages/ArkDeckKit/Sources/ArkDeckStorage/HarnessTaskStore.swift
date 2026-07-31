// Durable harness task store (CHG-2026-054, TASK-HTP-001).
//
// Deliberately built on the same primitives the rest of this package uses -
// exclusive flock, temp file + fsync + rename + directory fsync, and an
// append-only fsync'd log - rather than on a new database. A second
// persistence engine would mean a second set of durability semantics to
// audit next to the journal; the proposal records that trade explicitly.
//
// Two documents per task with one truth between them:
//
//   events.jsonl  append-only, fsync'd, one event per version. The truth.
//   task.json     atomically replaced snapshot. A cache of the log.
//
// A crash between the two writes leaves a snapshot one or more versions
// behind, never ahead: `load` replays the trailing events through the
// reducer's own projection, so the observable state is identical either
// way. The task id is the directory name and its grammar excludes `/` and
// `.`, so traversal is not expressible rather than filtered.

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

  public init(rootURL: URL) throws {
    self.rootURL = rootURL
    self.tasksURL = rootURL.appendingPathComponent("tasks", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: tasksURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create harness task root: \(error)")
    }
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
    let directoryURL = try directory(snapshot.htaskID)
    guard !FileManager.default.fileExists(atPath: directoryURL.path) else {
      throw HarnessTaskStoreError.alreadyExists(snapshot.htaskID)
    }
    do {
      try FileManager.default.createDirectory(
        at: directoryURL.appendingPathComponent("rounds", isDirectory: true),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create task directory: \(error)")
    }
    try withLock(directoryURL) {
      try writeSnapshot(snapshot, in: directoryURL)
    }
  }

  public func load(_ taskID: String) throws -> HarnessTaskSnapshot {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      try loadLocked(directoryURL, taskID: taskID)
    }
  }

  public func list() throws -> [HarnessTaskSnapshot] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: tasksURL.path)
    } catch {
      return []
    }
    var snapshots: [HarnessTaskSnapshot] = []
    for name in names.sorted() where Self.isWellFormed(taskID: name) {
      snapshots.append(try load(name))
    }
    return snapshots
  }

  /// Append the event, then replace the snapshot. The order is what makes
  /// a torn write recoverable: an appended event with a stale snapshot is
  /// replayable, the reverse would lose the causation record of a state
  /// the task is already in.
  public func commit(
    event: HarnessTaskEvent,
    snapshot: HarnessTaskSnapshot,
    expectedVersion: Int
  ) throws {
    let directoryURL = try existingDirectory(snapshot.htaskID)
    try withLock(directoryURL) {
      let current = try loadLocked(directoryURL, taskID: snapshot.htaskID)
      guard current.version == expectedVersion else {
        throw HarnessTaskStoreError.versionConflict(
          expected: expectedVersion, actual: current.version)
      }
      try appendEvent(event, in: directoryURL)
      try writeSnapshot(snapshot, in: directoryURL)
    }
  }

  public func events(_ taskID: String) throws -> [HarnessTaskEvent] {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      try readEvents(in: directoryURL)
    }
  }

  // MARK: - Round records

  public func putDecision(_ decision: HarnessDecision) throws {
    let directoryURL = try existingDirectory(decision.htaskID)
    try withLock(directoryURL) {
      let roundURL = try roundDirectory(directoryURL, round: decision.round)
      try writeJSON(decision, to: roundURL.appendingPathComponent("decision.json"))
    }
  }

  public func decision(_ taskID: String, round: Int) throws -> HarnessDecision? {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let url = directoryURL.appendingPathComponent("rounds/\(round)/decision.json")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try readJSON(HarnessDecision.self, from: url)
    }
  }

  public func putIntent(_ intent: HarnessDispatchIntent) throws {
    let directoryURL = try existingDirectory(intent.htaskID)
    try withLock(directoryURL) {
      let roundURL = try roundDirectory(directoryURL, round: intent.round)
      try writeJSON(intent, to: roundURL.appendingPathComponent("dispatch-intent.json"))
    }
  }

  public func intent(_ taskID: String, round: Int) throws -> HarnessDispatchIntent? {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let url = directoryURL.appendingPathComponent("rounds/\(round)/dispatch-intent.json")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try readJSON(HarnessDispatchIntent.self, from: url)
    }
  }

  public func intents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let roundsURL = directoryURL.appendingPathComponent("rounds", isDirectory: true)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: roundsURL.path)) ?? []
      var found: [HarnessDispatchIntent] = []
      for round in names.compactMap(Int.init).sorted() {
        let url = roundsURL.appendingPathComponent("\(round)/dispatch-intent.json")
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        found.append(try readJSON(HarnessDispatchIntent.self, from: url))
      }
      return found
    }
  }

  /// Intents recovery must still resolve before a task may dispatch
  /// anything new. `rejected` is excluded on purpose: the engine refused
  /// it, zero side effect happened, and re-submitting an identical request
  /// would be refused again.
  public func unresolvedIntents(_ taskID: String) throws -> [HarnessDispatchIntent] {
    try intents(taskID).filter { $0.state == .pending || $0.state == .submitted }
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
    let directoryURL = try existingDirectory(evaluation.htaskID)
    try withLock(directoryURL) {
      let evaluationsURL = directoryURL.appendingPathComponent("evaluations", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: evaluationsURL, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw HarnessTaskStoreError.ioFailure("cannot create evaluations directory: \(error)")
      }
      try writeJSON(
        evaluation,
        to: evaluationsURL.appendingPathComponent("\(evaluation.evaluationID).json"))
    }
  }

  public func evaluation(_ taskID: String, evaluationID: String) throws -> HarnessEvaluation? {
    guard Self.isWellFormed(evaluationID: evaluationID) else {
      throw HarnessTaskStoreError.corrupt("malformed evaluation id \(evaluationID)")
    }
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let url = directoryURL.appendingPathComponent("evaluations/\(evaluationID).json")
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try readJSON(HarnessEvaluation.self, from: url)
    }
  }

  public func evaluations(_ taskID: String) throws -> [HarnessEvaluation] {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let evaluationsURL = directoryURL.appendingPathComponent("evaluations", isDirectory: true)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: evaluationsURL.path)) ?? []
      var found: [HarnessEvaluation] = []
      for name in names.sorted() where name.hasSuffix(".json") {
        found.append(
          try readJSON(
            HarnessEvaluation.self, from: evaluationsURL.appendingPathComponent(name)))
      }
      return found.sorted { ($0.round, $0.evaluationID) < ($1.round, $1.evaluationID) }
    }
  }

  // MARK: - Memory and human actions (TASK-HTP-003)

  /// Failure memory is cross-task on purpose: the second task to attempt the
  /// same doomed thing must inherit the first one's evidence. The record is
  /// named after the fingerprint digest, whose grammar has no separators.
  public func failureRecord(digest: String) throws -> HarnessFailureRecord? {
    guard Self.isWellFormed(failureDigest: digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(digest)")
    }
    let url = failureURL(digest)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try withLock(memoryDirectory("failure")) {
      try readJSON(HarnessFailureRecord.self, from: url)
    }
  }

  public func putFailureRecord(_ record: HarnessFailureRecord) throws {
    guard Self.isWellFormed(failureDigest: record.digest) else {
      throw HarnessTaskStoreError.corrupt("malformed failure digest \(record.digest)")
    }
    let directoryURL = try memoryDirectoryCreating("failure")
    try withLock(directoryURL) {
      try writeJSON(record, to: failureURL(record.digest))
    }
  }

  /// Every failure record, so a decision context can carry "these approaches
  /// are already known bad" instead of letting a producer rediscover them.
  public func failureRecords() throws -> [HarnessFailureRecord] {
    let directoryURL = memoryDirectory("failure")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    guard !names.isEmpty else { return [] }
    return try withLock(directoryURL) {
      var found: [HarnessFailureRecord] = []
      for name in names.sorted() where name.hasSuffix(".json") {
        found.append(
          try readJSON(HarnessFailureRecord.self, from: directoryURL.appendingPathComponent(name)))
      }
      return found.sorted { $0.lastSeenUTC < $1.lastSeenUTC }
    }
  }

  public func appendMemory(_ entry: HarnessMemoryEntry) throws {
    let scope = entry.scope.rawValue
    let directoryURL = try memoryDirectoryCreating(scope)
    let name: String
    switch entry.scope {
    case .task:
      name = "\(entry.htaskID).jsonl"
    case .project:
      // Project memory is keyed by project, not by the task that earned it.
      guard let projectRef = entry.projectRef,
        projectRef.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }), !projectRef.isEmpty, !projectRef.hasPrefix(".")
      else {
        throw HarnessTaskStoreError.corrupt("malformed project ref for memory promotion")
      }
      name = "\(projectRef).jsonl"
    case .failure:
      throw HarnessTaskStoreError.corrupt("failure memory uses putFailureRecord")
    }
    try withLock(directoryURL) {
      try appendJSONLine(entry, to: directoryURL.appendingPathComponent(name))
    }
  }

  public func memory(scope: HarnessMemoryScope, key: String) throws -> [HarnessMemoryEntry] {
    let directoryURL = memoryDirectory(scope.rawValue)
    let url = directoryURL.appendingPathComponent("\(key).jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try withLock(directoryURL) {
      try readJSONLines(HarnessMemoryEntry.self, from: url)
    }
  }

  /// Human actions live under the task they block, so reading a task's state
  /// and reading why it is blocked never diverge.
  public func putHumanAction(_ action: HarnessStoredHumanAction) throws {
    let directoryURL = try existingDirectory(action.htaskID)
    try withLock(directoryURL) {
      let actionsURL = directoryURL.appendingPathComponent("humanActions", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: actionsURL, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw HarnessTaskStoreError.ioFailure("cannot create humanActions directory: \(error)")
      }
      try writeJSON(action, to: actionsURL.appendingPathComponent("\(action.actionID).json"))
    }
  }

  public func humanActions(_ taskID: String) throws -> [HarnessStoredHumanAction] {
    let directoryURL = try existingDirectory(taskID)
    return try withLock(directoryURL) {
      let actionsURL = directoryURL.appendingPathComponent("humanActions", isDirectory: true)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: actionsURL.path)) ?? []
      var found: [HarnessStoredHumanAction] = []
      for name in names.sorted() where name.hasSuffix(".json") {
        found.append(
          try readJSON(
            HarnessStoredHumanAction.self, from: actionsURL.appendingPathComponent(name)))
      }
      return found.sorted { $0.generatedAtUTC < $1.generatedAtUTC }
    }
  }

  public static func isWellFormed(failureDigest digest: String) -> Bool {
    guard digest.hasPrefix("FAIL-"), digest.count <= 40 else { return false }
    let body = digest.dropFirst("FAIL-".count)
    guard !body.isEmpty else { return false }
    return body.allSatisfy { character in
      character.isASCII && (character.isNumber || ("A"..."F").contains(String(character)))
    }
  }

  private func memoryDirectory(_ scope: String) -> URL {
    rootURL.appendingPathComponent("memory/\(scope)", isDirectory: true)
  }

  private func memoryDirectoryCreating(_ scope: String) throws -> URL {
    let url = memoryDirectory(scope)
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create memory directory: \(error)")
    }
    return url
  }

  private func failureURL(_ digest: String) -> URL {
    memoryDirectory("failure").appendingPathComponent("\(digest).json")
  }

  private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(value) else {
      throw HarnessTaskStoreError.ioFailure("cannot encode \(url.lastPathComponent)")
    }
    let payload = encoded + Data("\n".utf8)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw HarnessTaskStoreError.ioFailure("cannot open \(url.lastPathComponent)")
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
      throw HarnessTaskStoreError.ioFailure("short write to \(url.lastPathComponent)")
    }
    guard fsync(fd) == 0 else {
      throw HarnessTaskStoreError.ioFailure("fsync of \(url.lastPathComponent) failed")
    }
  }

  private func readJSONLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
    guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessTaskStoreError.corrupt("\(url.lastPathComponent) is not UTF-8")
    }
    let decoder = JSONDecoder()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    var values: [T] = []
    for (index, line) in lines.enumerated() {
      guard let lineData = line.data(using: .utf8) else { continue }
      do {
        values.append(try decoder.decode(type, from: lineData))
      } catch {
        // Only a torn final line is tolerated, exactly as in the event log.
        guard index == lines.count - 1 else {
          throw HarnessTaskStoreError.corrupt(
            "undecodable line \(index) in \(url.lastPathComponent)")
        }
      }
    }
    return values
  }

  // MARK: - Locked helpers

  private func loadLocked(_ directoryURL: URL, taskID: String) throws -> HarnessTaskSnapshot {
    let snapshotURL = directoryURL.appendingPathComponent("task.json")
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
      throw HarnessTaskStoreError.notFound(taskID)
    }
    let snapshot = try readJSON(HarnessTaskSnapshot.self, from: snapshotURL)
    let events = try readEvents(in: directoryURL)
    var rebuilt = snapshot
    for event in events where event.sequence >= snapshot.version {
      guard event.sequence == rebuilt.version else {
        throw HarnessTaskStoreError.corrupt(
          "event sequence \(event.sequence) does not follow version \(rebuilt.version)")
      }
      rebuilt = rebuilt.applying(event.resulting, atUTC: event.atUTC)
    }
    return rebuilt
  }

  private func roundDirectory(_ directoryURL: URL, round: Int) throws -> URL {
    guard round >= 0 else { throw HarnessTaskStoreError.corrupt("negative round \(round)") }
    let url = directoryURL.appendingPathComponent("rounds/\(round)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot create round directory: \(error)")
    }
    return url
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
