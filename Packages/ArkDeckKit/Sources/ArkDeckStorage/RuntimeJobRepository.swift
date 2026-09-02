// Atomic Runtime job admission and compact job-history index.
//
// The Runtime journal remains the source for external-effect history.  This
// repository owns only the transactional mapping from an idempotency key to a
// job identity and its current lifecycle summary.  Keeping this in Storage
// lets Workflow code retain its typed job model without gaining raw SQLite
// access.

import Foundation
import SQLite3

package enum RuntimeJobAdmissionVerdict: Sendable, Equatable {
  case admitted
  case duplicate(jobID: String)
  case conflict
}

package struct RuntimePersistedJob: Sendable, Equatable {
  public let jobID: String
  public let idempotencyKey: String
  package let requestHash: String
  public let state: String
  public let createdAtUTC: String
  public let updatedAtUTC: String
  public let version: Int
  package let initialRecordData: Data?

  /// The creation column of a row the retired legacy idempotency importer
  /// wrote (TASK-DHA-001, #1029): it copied the entry without a timestamp and
  /// stamped this sentinel instead. The importer is gone (#1259) but its rows
  /// are durable history, and their initial record carries the real
  /// timestamp, so the column cannot be asked to agree with the record.
  package static let legacyCreatedAtUTC = "legacy"

  /// Whether this row's creation column verifies the record's own creation
  /// timestamp: equal, or the legacy sentinel above. Every other identity
  /// fact (job id, state, idempotency key, fingerprint, version) still has to
  /// agree; only the one column the importer never had is excused.
  package func createdAtMatches(_ recordCreatedAtUTC: String) -> Bool {
    createdAtUTC == recordCreatedAtUTC || createdAtUTC == Self.legacyCreatedAtUTC
  }
}

package struct RuntimeJobRepositoryPage: Sendable, Equatable {
  public let jobs: [RuntimePersistedJob]
  /// Opaque SQLite row cursor.  It is intentionally not a job ID: callers
  /// cannot skip or repeat records when IDs are hash-shaped rather than
  /// chronologically sortable.
  public let nextCursor: String?
}

package enum RuntimeJobRepositoryError: Error, Equatable, Sendable {
  case ioFailure(String)
  case corrupt(String)
}

/// SQLite is authoritative for Runtime admission.  The job-local JSON record
/// is deliberately retained as the detailed recovery snapshot, while its
/// initial bytes are also held transactionally here.  That duplicate is what
/// lets recovery recreate a job directory after a crash immediately following
/// a committed admission transaction.
package final class RuntimeJobRepository: @unchecked Sendable {
  package static let filename = "runtime-jobs.sqlite3"
  private static let schemaVersion = 1
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private let url: URL
  private let lock = NSLock()
  private var handle: OpaquePointer?

  public init(stateDirectory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(stateDirectory)
    try DurableFilePrimitives.createDirectoryIfNeeded(stateDirectory)
    url = stateDirectory.appending(path: Self.filename)

    var opened: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      if let opened { sqlite3_close_v2(opened) }
      throw RuntimeJobRepositoryError.ioFailure("cannot open Runtime job repository: \(message)")
    }
    handle = opened
    do {
      guard chmod(url.path, 0o600) == 0 else {
        throw RuntimeJobRepositoryError.ioFailure("cannot restrict Runtime job repository")
      }
      try configure()
      try bootstrapSchemaIfNeeded()
      try refuseUnconsumedLegacyLedger(stateDirectory: stateDirectory)
    } catch {
      sqlite3_close_v2(opened)
      handle = nil
      throw error
    }
  }

  /// The pre-SQLite idempotency ledger generation is retired, and its importer
  /// never deleted the file after consuming it — a surviving `idempotency.json`
  /// on an upgraded store is normal residue. It stays acceptable exactly while
  /// every key it names is represented in the SQLite admission table. A key
  /// this table has never seen means unconsumed history (or a restored
  /// backup): admitting requests past it could replay a used key as a fresh
  /// device mutation, so the repository refuses to open instead.
  private func refuseUnconsumedLegacyLedger(stateDirectory: URL) throws {
    let ledgerURL = stateDirectory.appending(path: "idempotency.json")
    guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return }
    struct LegacyLedger: Decodable {
      struct Entry: Decodable { let idempotencyKey: String }
      let entries: [Entry]
    }
    let ledger: LegacyLedger
    do {
      ledger = try JSONDecoder().decode(LegacyLedger.self, from: Data(contentsOf: ledgerURL))
    } catch {
      throw RuntimeJobRepositoryError.corrupt(
        "retired ledger \(ledgerURL.path) is undecodable, so its keys cannot be "
          + "proven consumed: \(error). Verify and remove the file to restore admission")
    }
    for entry in ledger.entries {
      let known = try query(
        "SELECT 1 AS present FROM runtime_job WHERE idempotency_key = ? LIMIT 1",
        [.text(entry.idempotencyKey)])
      guard !known.isEmpty else {
        throw RuntimeJobRepositoryError.corrupt(
          "retired ledger \(ledgerURL.path) names key \(entry.idempotencyKey) "
            + "that \(Self.filename) has never admitted; this generation can no "
            + "longer be imported and admitting past it could replay a used key. "
            + "Verify the ledger's jobs, then remove the file to restore admission")
      }
    }
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  package func lookup(idempotencyKey: String, requestHash: String) throws -> RuntimeJobAdmissionVerdict {
    lock.lock()
    defer { lock.unlock() }
    guard let row = try query(
      "SELECT job_id, request_hash FROM runtime_job WHERE idempotency_key = ? LIMIT 1",
      [.text(idempotencyKey)]).first
    else { return .admitted }
    guard let jobID = row.text("job_id"), let storedHash = row.text("request_hash") else {
      throw RuntimeJobRepositoryError.corrupt("Runtime admission row has missing identity columns")
    }
    return storedHash == requestHash ? .duplicate(jobID: jobID) : .conflict
  }

  /// Inserts the idempotency identity, job identity and initial job state in
  /// one transaction.  A duplicate request observes the existing exact job;
  /// a changed request is never allowed to overwrite the first mapping.
  package func admit(
    jobID: String,
    idempotencyKey: String,
    requestHash: String,
    initialState: String,
    createdAtUTC: String,
    initialRecordData: Data
  ) throws -> RuntimeJobAdmissionVerdict {
    lock.lock()
    defer { lock.unlock() }
    return try transaction {
      if let row = try query(
        "SELECT job_id, request_hash FROM runtime_job WHERE idempotency_key = ? LIMIT 1",
        [.text(idempotencyKey)]).first
      {
        guard let existingID = row.text("job_id"), let storedHash = row.text("request_hash") else {
          throw RuntimeJobRepositoryError.corrupt("Runtime admission row has missing identity columns")
        }
        return storedHash == requestHash ? .duplicate(jobID: existingID) : .conflict
      }
      try run(
        """
        INSERT INTO runtime_job(
          job_id, idempotency_key, request_hash, state, created_at_utc,
          updated_at_utc, version, initial_record_json
        ) VALUES(?, ?, ?, ?, ?, ?, 1, ?)
        """,
        [
          .text(jobID), .text(idempotencyKey), .text(requestHash), .text(initialState),
          .text(createdAtUTC), .text(createdAtUTC), .blob(initialRecordData),
        ])
      return .admitted
    }
  }

  /// State is an index for query/pagination; its journal and job-record
  /// counterparts continue to carry the complete auditable recovery facts.
  package func updateJobState(
    jobID: String, state: String, updatedAtUTC: String, recordData: Data
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let changed = try run(
      """
      UPDATE runtime_job
      SET state = ?, updated_at_utc = ?, version = version + 1, initial_record_json = ?
      WHERE job_id = ?
      """,
      [.text(state), .text(updatedAtUTC), .blob(recordData), .text(jobID)])
    guard changed == 1 else {
      throw RuntimeJobRepositoryError.corrupt("cannot update missing Runtime job \(jobID)")
    }
  }

  package func allJobs() throws -> [RuntimePersistedJob] {
    lock.lock()
    defer { lock.unlock() }
    return try query(
      """
      SELECT job_id, idempotency_key, request_hash, state, created_at_utc,
             updated_at_utc, version, initial_record_json
      FROM runtime_job
      ORDER BY created_at_utc, job_id
      """
    ).map(persistedJob)
  }

  /// One SQLite read snapshot, one bounded record at a time. The callback may
  /// build a small metadata snapshot but cannot execute another repository
  /// operation while this statement owns the read lock. No admission/state
  /// transaction or recovery semantics are changed by this query path.
  package func forEachJob(jobID: String? = nil, _ body: (RuntimePersistedJob) throws -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    let statement = try prepare("""
      SELECT job_id, idempotency_key, request_hash, state, created_at_utc,
             updated_at_utc, version, initial_record_json
      FROM runtime_job
      """ + (jobID == nil ? "" : " WHERE job_id = ?"))
    defer { sqlite3_finalize(statement) }
    if let jobID { try bind([.text(jobID)], to: statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw failure("Runtime snapshot query", code: result) }
      try autoreleasepool {
        // Check byte lengths before copying SQLite values into Swift memory.
        // A malformed large row is never silently omitted from a complete list.
        for column in 0..<sqlite3_column_count(statement) {
          let count = Int(sqlite3_column_bytes(statement, column))
          guard count <= (column == 7 ? 16 * 1024 * 1024 : 4096) else {
            throw RuntimeJobRepositoryError.corrupt("Runtime Job snapshot record exceeds its read bound")
          }
        }
        var values: [String: Value] = [:]
        for column in 0..<sqlite3_column_count(statement) {
          let name = String(cString: sqlite3_column_name(statement, column))
          switch sqlite3_column_type(statement, column) {
          case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
          case SQLITE_TEXT:
            if let text = sqlite3_column_text(statement, column) { values[name] = .text(String(cString: text)) }
          case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            if count == 0 { values[name] = .blob(Data()) }
            else if let bytes = sqlite3_column_blob(statement, column) { values[name] = .blob(Data(bytes: bytes, count: count)) }
          default: break
          }
        }
        try body(persistedJob(Row(values: values)))
      }
    }
  }

  /// Jobs whose journal may still require recovery work.  Terminal history is
  /// deliberately excluded: the record and terminal transition were both
  /// durably written before this index row was advanced to a terminal state,
  /// so reopening every terminal journal at daemon launch provides no
  /// recovery action while making startup scale with total history.
  ///
  /// Unknown future states are treated as active.  That conservative default
  /// keeps an upgraded Runtime from silently skipping a newly introduced
  /// recovery state.
  public func activeJobs() throws -> [RuntimePersistedJob] {
    lock.lock()
    defer { lock.unlock() }
    return try query(
      """
      SELECT job_id, idempotency_key, request_hash, state, created_at_utc,
             updated_at_utc, version, initial_record_json
      FROM runtime_job
      WHERE state NOT IN ('planned', 'succeeded', 'recovered', 'failed', 'cancelled', 'interrupted')
      ORDER BY created_at_utc, job_id
      """
    ).map(persistedJob)
  }

  public func job(jobID: String) throws -> RuntimePersistedJob? {
    lock.lock()
    defer { lock.unlock() }
    return try query(
      """
      SELECT job_id, idempotency_key, request_hash, state, created_at_utc,
             updated_at_utc, version, initial_record_json
      FROM runtime_job WHERE job_id = ? LIMIT 1
      """,
      [.text(jobID)]
    ).first.map(persistedJob)
  }

  public func listJobs(
    pageSize: Int, cursor: String?, newestFirst: Bool = false
  ) throws -> RuntimeJobRepositoryPage {
    guard (1...1_000).contains(pageSize) else {
      throw RuntimeJobRepositoryError.corrupt("pageSize must be between 1 and 1000")
    }
    let cursorRowID: Int64?
    if let cursor {
      guard let parsed = Int64(cursor), parsed >= 0 else {
        throw RuntimeJobRepositoryError.corrupt("malformed Runtime job history cursor")
      }
      cursorRowID = parsed
    } else {
      cursorRowID = nil
    }
    lock.lock()
    defer { lock.unlock() }
    let rows: [Row]
    if newestFirst {
      if let cursorRowID {
        rows = try query(
          """
          SELECT rowid AS storage_row_id, job_id, idempotency_key, request_hash, state,
                 created_at_utc, updated_at_utc, version, initial_record_json
          FROM runtime_job
          WHERE rowid < ?
          ORDER BY rowid DESC
          LIMIT ?
          """,
          [.integer(cursorRowID), .integer(Int64(pageSize + 1))])
      } else {
        rows = try query(
          """
          SELECT rowid AS storage_row_id, job_id, idempotency_key, request_hash, state,
                 created_at_utc, updated_at_utc, version, initial_record_json
          FROM runtime_job
          ORDER BY rowid DESC
          LIMIT ?
          """,
          [.integer(Int64(pageSize + 1))])
      }
    } else {
      rows = try query(
        """
        SELECT rowid AS storage_row_id, job_id, idempotency_key, request_hash, state,
               created_at_utc, updated_at_utc, version, initial_record_json
        FROM runtime_job
        WHERE rowid > ?
        ORDER BY rowid
        LIMIT ?
        """,
        [.integer(cursorRowID ?? 0), .integer(Int64(pageSize + 1))])
    }
    let pageRows = rows.prefix(pageSize)
    let jobs = try pageRows.map(persistedJob)
    let nextCursor: String?
    if rows.count > pageSize, let last = pageRows.last?.integer("storage_row_id") {
      nextCursor = String(last)
    } else {
      nextCursor = nil
    }
    return RuntimeJobRepositoryPage(jobs: jobs, nextCursor: nextCursor)
  }

  // MARK: - Setup and one-time migration

  private func configure() throws {
    guard sqlite3_busy_timeout(requiredHandle(), 5_000) == SQLITE_OK else {
      throw failure("cannot set Runtime SQLite busy timeout")
    }
    let mode = try query("PRAGMA journal_mode=WAL").first?.text("journal_mode")
    guard mode?.lowercased() == "wal" else {
      throw RuntimeJobRepositoryError.ioFailure("Runtime SQLite WAL mode unavailable")
    }
    try execute("PRAGMA synchronous=FULL")
  }

  private func bootstrapSchemaIfNeeded() throws {
    let version = Int(try query("PRAGMA user_version").first?.integer("user_version") ?? 0)
    guard version <= Self.schemaVersion else {
      throw RuntimeJobRepositoryError.corrupt(
        "Runtime job repository schema \(version) is newer than supported \(Self.schemaVersion)")
    }
    guard version < Self.schemaVersion else { return }
    try transaction {
      try execute(
        """
        CREATE TABLE runtime_job(
          job_id TEXT PRIMARY KEY,
          idempotency_key TEXT NOT NULL UNIQUE,
          request_hash TEXT NOT NULL,
          state TEXT NOT NULL,
          created_at_utc TEXT NOT NULL,
          updated_at_utc TEXT NOT NULL,
          version INTEGER NOT NULL CHECK(version >= 1),
          initial_record_json BLOB
        );
        CREATE INDEX runtime_job_updated_idx
          ON runtime_job(updated_at_utc DESC, job_id);
        """
      )
      try execute("PRAGMA user_version=\(Self.schemaVersion)")
    }
  }

  // MARK: - SQLite primitives

  private enum Value {
    case text(String)
    case integer(Int64)
    case blob(Data)
  }

  private func persistedJob(_ row: Row) throws -> RuntimePersistedJob {
    guard
      let jobID = row.text("job_id"),
      let idempotencyKey = row.text("idempotency_key"),
      let requestHash = row.text("request_hash"),
      let state = row.text("state"),
      let created = row.text("created_at_utc"),
      let updated = row.text("updated_at_utc"),
      let version = row.integer("version")
    else {
      throw RuntimeJobRepositoryError.corrupt("Runtime job row has missing required columns")
    }
    return RuntimePersistedJob(
      jobID: jobID, idempotencyKey: idempotencyKey, requestHash: requestHash,
      state: state, createdAtUTC: created, updatedAtUTC: updated,
      version: Int(version), initialRecordData: row.blob("initial_record_json"))
  }

  private struct Row {
    let values: [String: Value]

    func text(_ name: String) -> String? {
      guard case .text(let value)? = values[name] else { return nil }
      return value
    }

    func integer(_ name: String) -> Int64? {
      guard case .integer(let value)? = values[name] else { return nil }
      return value
    }

    func blob(_ name: String) -> Data? {
      guard case .blob(let value)? = values[name] else { return nil }
      return value
    }
  }

  @discardableResult
  private func run(_ sql: String, _ bindings: [Value] = []) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else { throw failure("Runtime SQLite step", code: result) }
    return Int(sqlite3_changes(requiredHandle()))
  }

  private func query(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    var rows: [Row] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw failure("Runtime SQLite query", code: result) }
      var values: [String: Value] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, index))
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
          values[name] = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
          if let text = sqlite3_column_text(statement, index) {
            values[name] = .text(String(cString: text))
          }
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, index))
          if count == 0 {
            values[name] = .blob(Data())
          } else if let bytes = sqlite3_column_blob(statement, index) {
            values[name] = .blob(Data(bytes: bytes, count: count))
          }
        default:
          break
        }
      }
      rows.append(Row(values: values))
    }
    return rows
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(requiredHandle(), sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
      throw failure("cannot prepare Runtime SQLite statement", code: code)
    }
    return statement
  }

  private func bind(_ values: [Value], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .text(let value):
        code = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
      case .integer(let value):
        code = sqlite3_bind_int64(statement, index, value)
      case .blob(let value):
        code = value.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
      }
      guard code == SQLITE_OK else { throw failure("cannot bind Runtime SQLite value", code: code) }
    }
  }

  private func execute(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(requiredHandle(), sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let detail = message.map { String(cString: $0) }
      if let message { sqlite3_free(message) }
      throw RuntimeJobRepositoryError.ioFailure(
        "Runtime SQLite batch failed: \(detail ?? String(cString: sqlite3_errmsg(requiredHandle())))")
    }
  }

  private func requiredHandle() -> OpaquePointer {
    guard let handle else { preconditionFailure("closed Runtime SQLite repository") }
    return handle
  }

  private func failure(_ operation: String, code: Int32? = nil) -> RuntimeJobRepositoryError {
    let suffix = code.map { " [\($0)]" } ?? ""
    return .ioFailure("\(operation)\(suffix): \(String(cString: sqlite3_errmsg(requiredHandle())))")
  }
}
