// Atomic Runtime job admission and compact job-history index.
//
// The Runtime journal remains the source for external-effect history.  This
// repository owns only the transactional mapping from an idempotency key to a
// job identity and its current lifecycle summary.  Keeping this in Storage
// lets Workflow code retain its typed job model without gaining raw SQLite
// access.

import ArkDeckCore
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

  package func createdAtMatches(_ recordCreatedAtUTC: String) -> Bool {
    createdAtUTC == recordCreatedAtUTC
  }
}

package struct RuntimeJobRepositoryPage: Sendable, Equatable {
  public let jobs: [RuntimePersistedJob]
  /// Opaque logical cursor over the complete creation-time / Job-ID order.
  /// It never exposes a SQLite row identity or another storage position.
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
  private static let schemaVersion: Int64 = 1
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private static let listCursorPrefix = "rjh1."
  private static let oldestFirstOrder = "oldestFirst"
  private static let newestFirstOrder = "newestFirst"

  private struct ListCursor: Codable, Equatable {
    let version: Int
    let order: String
    let createdAtOrderKey: String
    let jobID: String
  }

  private let url: URL
  private let lock = NSLock()
  private var handle: OpaquePointer?

  public init(stateDirectory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(stateDirectory)
    try DurableFilePrimitives.createDirectoryIfNeeded(stateDirectory)
    url = stateDirectory.appending(path: Self.filename)

    try Self.refuseRetiredState(stateDirectory: stateDirectory)
    try DurableFilePrimitives.rejectSymbolicLink(url)
    let isNew = !FileManager.default.fileExists(atPath: url.path)
    if isNew {
      let jobs = stateDirectory.appending(path: "jobs")
      try DurableFilePrimitives.rejectSymbolicLink(jobs)
      if FileManager.default.fileExists(atPath: jobs.path),
        !(try FileManager.default.contentsOfDirectory(atPath: jobs.path)).isEmpty
      {
        throw RuntimeJobRepositoryError.corrupt(
          "Runtime job history exists without its admission index; preserved at \(stateDirectory.path)"
        )
      }
    }
    var opened: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      if let opened { sqlite3_close_v2(opened) }
      throw RuntimeJobRepositoryError.ioFailure("cannot open Runtime job repository: \(message)")
    }
    handle = opened
    do {
      guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
        throw failure("cannot set Runtime SQLite busy timeout")
      }
      guard chmod(url.path, 0o600) == 0 else {
        throw RuntimeJobRepositoryError.ioFailure("cannot restrict Runtime job repository")
      }
      // Validate existing bytes before any journal-mode change or schema write.
      try bootstrapSchemaIfNeeded(isNew: isNew)
      try configure()
    } catch {
      sqlite3_close_v2(opened)
      handle = nil
      throw error
    }
  }

  private static func refuseRetiredState(stateDirectory: URL) throws {
    let ledger = stateDirectory.appending(path: "idempotency.json")
    try DurableFilePrimitives.rejectSymbolicLink(ledger)
    guard !FileManager.default.fileExists(atPath: ledger.path) else {
      throw RuntimeJobRepositoryError.corrupt(
        "retired idempotency ledger is unsupported; original state is preserved at \(ledger.path)")
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
      guard let admissionSequence = try query(
        "SELECT COALESCE(MAX(admission_sequence), 0) + 1 AS next_sequence FROM runtime_job"
      ).first?.integer("next_sequence") else {
        throw RuntimeJobRepositoryError.corrupt(
          "Runtime admission sequence cannot advance")
      }
      try run(
        """
        INSERT INTO runtime_job(
          job_id, idempotency_key, request_hash, state, admission_sequence,
          created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        """,
        [
          .text(jobID), .text(idempotencyKey), .text(requestHash), .text(initialState),
          .integer(admissionSequence), .text(createdAtUTC),
          .text(
            try Self.creationOrderKey(
              createdAtUTC: createdAtUTC)),
          .text(createdAtUTC), .blob(initialRecordData),
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
      ORDER BY created_at_order_key, job_id COLLATE BINARY
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
      ORDER BY created_at_order_key, job_id COLLATE BINARY
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
    let decodedCursor = try cursor.map {
      try Self.decodeListCursor($0, newestFirst: newestFirst)
    }
    lock.lock()
    defer { lock.unlock() }
    let rows: [Row]
    if newestFirst {
      if let decodedCursor {
        rows = try query(
          """
          SELECT created_at_order_key, job_id, idempotency_key, request_hash, state,
                 created_at_utc, updated_at_utc, version, initial_record_json
          FROM runtime_job
          WHERE created_at_order_key < ?
             OR (created_at_order_key = ? AND job_id COLLATE BINARY > ?)
          ORDER BY created_at_order_key DESC, job_id COLLATE BINARY ASC
          LIMIT ?
          """,
          [
            .text(decodedCursor.createdAtOrderKey), .text(decodedCursor.createdAtOrderKey),
            .text(decodedCursor.jobID), .integer(Int64(pageSize + 1)),
          ])
      } else {
        rows = try query(
          """
          SELECT created_at_order_key, job_id, idempotency_key, request_hash, state,
                 created_at_utc, updated_at_utc, version, initial_record_json
          FROM runtime_job
          ORDER BY created_at_order_key DESC, job_id COLLATE BINARY ASC
          LIMIT ?
          """,
          [.integer(Int64(pageSize + 1))])
      }
    } else if let decodedCursor {
      rows = try query(
        """
        SELECT created_at_order_key, job_id, idempotency_key, request_hash, state,
               created_at_utc, updated_at_utc, version, initial_record_json
        FROM runtime_job
        WHERE created_at_order_key > ?
           OR (created_at_order_key = ? AND job_id COLLATE BINARY > ?)
        ORDER BY created_at_order_key ASC, job_id COLLATE BINARY ASC
        LIMIT ?
        """,
        [
          .text(decodedCursor.createdAtOrderKey), .text(decodedCursor.createdAtOrderKey),
          .text(decodedCursor.jobID), .integer(Int64(pageSize + 1)),
        ])
    } else {
      rows = try query(
        """
        SELECT created_at_order_key, job_id, idempotency_key, request_hash, state,
               created_at_utc, updated_at_utc, version, initial_record_json
        FROM runtime_job
        ORDER BY created_at_order_key ASC, job_id COLLATE BINARY ASC
        LIMIT ?
        """,
        [.integer(Int64(pageSize + 1))])
    }
    let pageRows = rows.prefix(pageSize)
    let jobs = try pageRows.map(persistedJob)
    let nextCursor: String?
    if rows.count > pageSize, let last = pageRows.last,
      let createdAtOrderKey = last.text("created_at_order_key"),
      let jobID = last.text("job_id")
    {
      nextCursor = try Self.encodeListCursor(
        createdAtOrderKey: createdAtOrderKey, jobID: jobID, newestFirst: newestFirst)
    } else {
      nextCursor = nil
    }
    return RuntimeJobRepositoryPage(jobs: jobs, nextCursor: nextCursor)
  }

  private static func encodeListCursor(
    createdAtOrderKey: String, jobID: String, newestFirst: Bool
  ) throws -> String {
    guard createdAtOrderKey.count == 16, validJobID(jobID) else {
      throw RuntimeJobRepositoryError.corrupt(
        "Runtime job history row cannot form a bounded logical cursor")
    }
    let value = ListCursor(
      version: 1,
      order: newestFirst ? newestFirstOrder : oldestFirstOrder,
      createdAtOrderKey: createdAtOrderKey,
      jobID: jobID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return listCursorPrefix + (try encoder.encode(value)).base64URLEncodedString()
  }

  private static func decodeListCursor(
    _ cursor: String, newestFirst: Bool
  ) throws -> ListCursor {
    guard cursor.utf8.count <= 1_024, cursor.hasPrefix(listCursorPrefix),
      let data = Data(base64URLString: String(cursor.dropFirst(listCursorPrefix.count))),
      let decoded = try? JSONDecoder().decode(ListCursor.self, from: data),
      decoded.version == 1,
      decoded.order == (newestFirst ? newestFirstOrder : oldestFirstOrder),
      decoded.createdAtOrderKey.count == 16,
      decoded.createdAtOrderKey.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }),
      validJobID(decoded.jobID),
      try encodeListCursor(
        createdAtOrderKey: decoded.createdAtOrderKey,
        jobID: decoded.jobID,
        newestFirst: newestFirst) == cursor
    else {
      throw RuntimeJobRepositoryError.corrupt("malformed Runtime job history cursor")
    }
    return decoded
  }

  /// Foundation parses every accepted Runtime timestamp to an instant before
  /// SQLite sees it. The monotonic IEEE-754 transform preserves `Date` order
  /// as a fixed-width ASCII key, including timestamps whose different RFC
  /// 3339 spellings would sort incorrectly as raw text.
  private static func creationOrderKey(
    createdAtUTC: String
  ) throws -> String {
    guard let date = ISO8601Timestamps.parse(createdAtUTC) else {
      throw RuntimeJobRepositoryError.corrupt(
        "Runtime job row has an invalid creation timestamp")
    }
    var interval = date.timeIntervalSinceReferenceDate
    if interval == 0 { interval = 0 }  // Normalize negative zero.
    guard interval.isFinite else {
      throw RuntimeJobRepositoryError.corrupt(
        "Runtime job row has an invalid creation instant")
    }
    let signMask: UInt64 = 1 << 63
    let bits = interval.bitPattern
    let orderedBits = bits & signMask == 0 ? bits ^ signMask : ~bits
    let hex = String(orderedBits, radix: 16, uppercase: false)
    return String(repeating: "0", count: 16 - hex.count) + hex
  }

  private static func validJobID(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && value.utf8.first.map {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      } == true
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }
  }

  // The sole current layout. Checking sqlite_schema includes the table's
  // constraints, every index (including ordering/collation), and any extra
  // trigger/view. A reused user_version alone never identifies a store.
  private static let schemaStatements: [String] = [
    """
    CREATE TABLE runtime_job(
      job_id TEXT PRIMARY KEY,
      idempotency_key TEXT NOT NULL UNIQUE,
      request_hash TEXT NOT NULL,
      state TEXT NOT NULL,
      admission_sequence INTEGER NOT NULL,
      created_at_utc TEXT NOT NULL,
      created_at_order_key TEXT NOT NULL,
      updated_at_utc TEXT NOT NULL,
      version INTEGER NOT NULL CHECK(version >= 1),
      initial_record_json BLOB
    )
    """,
    "CREATE INDEX runtime_job_updated_idx ON runtime_job(updated_at_utc DESC, job_id)",
    "CREATE INDEX runtime_job_created_idx ON runtime_job(created_at_order_key, job_id COLLATE BINARY)",
    "CREATE UNIQUE INDEX runtime_job_admission_sequence_idx ON runtime_job(admission_sequence)",
  ]

  private static func normalizedSchemaSQL(_ value: String) -> String {
    value.filter { !$0.isWhitespace }.lowercased()
  }

  private func configure() throws {
    let mode = try query("PRAGMA journal_mode=WAL").first?.text("journal_mode")
    guard mode?.lowercased() == "wal" else {
      throw RuntimeJobRepositoryError.ioFailure("Runtime SQLite WAL mode unavailable")
    }
    try execute("PRAGMA synchronous=FULL")
  }

  private func bootstrapSchemaIfNeeded(isNew: Bool) throws {
    // One transaction prevents a competing opener from observing partial DDL.
    try transaction {
      let version = try query("PRAGMA user_version").first?.integer("user_version")
      let objects = try query("SELECT name, sql FROM sqlite_schema ORDER BY name")
      if isNew && version == 0 && objects.isEmpty {
        for statement in Self.schemaStatements { try execute(statement) }
        try execute("PRAGMA user_version=\(Self.schemaVersion)")
      } else {
        guard version == Self.schemaVersion else {
          throw RuntimeJobRepositoryError.corrupt(
            "unsupported Runtime job repository schema; original state is preserved at \(url.path)")
        }
      }
      let currentObjects = try query("SELECT name, sql FROM sqlite_schema ORDER BY name")
      let definitions = currentObjects.compactMap { $0.text("sql") }
      let automaticIndexes = currentObjects.filter { $0.text("sql") == nil }.compactMap {
        $0.text("name")
      }
      guard definitions.count == Self.schemaStatements.count,
        Set(definitions.map(Self.normalizedSchemaSQL))
          == Set(Self.schemaStatements.map(Self.normalizedSchemaSQL)),
        Set(automaticIndexes) == [
          "sqlite_autoindex_runtime_job_1", "sqlite_autoindex_runtime_job_2",
        ]
      else {
        throw RuntimeJobRepositoryError.corrupt(
          "Runtime job repository does not match the current v1 layout; original state is preserved at \(url.path)"
        )
      }
      // Logical ordering is part of the durable contract, not a migration.
      var afterJobID = ""
      while true {
        let rows = try query(
          "SELECT job_id, created_at_utc, created_at_order_key, admission_sequence, version "
            + "FROM runtime_job WHERE job_id COLLATE BINARY > ? "
            + "ORDER BY job_id COLLATE BINARY LIMIT 256", [.text(afterJobID)])
        guard !rows.isEmpty else { break }
        for row in rows {
          guard let jobID = row.text("job_id"), Self.validJobID(jobID),
            let created = row.text("created_at_utc"),
            row.text("created_at_order_key") == (try Self.creationOrderKey(createdAtUTC: created)),
            let sequence = row.integer("admission_sequence"), sequence > 0,
            let rowVersion = row.integer("version"), rowVersion > 0
          else {
            throw RuntimeJobRepositoryError.corrupt(
              "invalid current Runtime job ordering or row version")
          }
          afterJobID = jobID
        }
      }
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

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  fileprivate init?(base64URLString value: String) {
    guard !value.isEmpty,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 95
      })
    else { return nil }
    let remainder = value.utf8.count % 4
    guard remainder != 1 else { return nil }
    let standard = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
    guard let decoded = Data(base64Encoded: standard),
      decoded.base64URLEncodedString() == value
    else { return nil }
    self = decoded
  }
}
