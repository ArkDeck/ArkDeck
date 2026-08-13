// SQLite persistence primitives for the bounded harness (TASK-HFA-012).
//
// This database is deliberately private to ArkDeckStorage. Callers continue
// to exchange typed Harness values; SQL, table names and raw bytes never
// escape the storage boundary. The actor owning this object serializes normal
// access, while SQLITE_OPEN_FULLMUTEX and task-level leases protect daemon
// restarts and accidental second-process access.

import ArkDeckCore
import CryptoKit
import Foundation
import SQLite3

enum HarnessSQLiteValue: Equatable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)
}

struct HarnessSQLiteRow {
  fileprivate let values: [String: HarnessSQLiteValue]

  func integer(_ name: String) -> Int64? {
    guard case .integer(let value)? = values[name] else { return nil }
    return value
  }

  func real(_ name: String) -> Double? {
    guard case .real(let value)? = values[name] else { return nil }
    return value
  }

  func text(_ name: String) -> String? {
    guard case .text(let value)? = values[name] else { return nil }
    return value
  }

  func blob(_ name: String) -> Data? {
    guard case .blob(let value)? = values[name] else { return nil }
    return value
  }
}

struct HarnessSQLiteConfiguration: Equatable, Sendable {
  let journalMode: String
  let foreignKeysEnabled: Bool
  let schemaVersion: Int
  let tableNames: [String]
}

final class HarnessSQLiteDatabase: @unchecked Sendable {
  static let schemaVersion = 1
  static let filename = "harness.sqlite3"

  private var handle: OpaquePointer?
  private var transactionDepth = 0
  private let url: URL
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(rootURL: URL) throws {
    self.url = rootURL.appending(path: Self.filename)
    var opened: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      if let opened { sqlite3_close_v2(opened) }
      throw HarnessTaskStoreError.ioFailure("cannot open harness sqlite store: \(message)")
    }
    self.handle = opened
    do {
      guard chmod(url.path, 0o600) == 0 else {
        throw HarnessTaskStoreError.ioFailure("cannot restrict harness sqlite permissions")
      }
      try configure()
      try bootstrapSchemaIfNeeded()
    } catch {
      sqlite3_close_v2(opened)
      self.handle = nil
      throw error
    }
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  func configuration() throws -> HarnessSQLiteConfiguration {
    let mode = try query("PRAGMA journal_mode").first?.text("journal_mode") ?? ""
    let foreignKeys = try query("PRAGMA foreign_keys").first?.integer("foreign_keys") == 1
    let version = Int(try query("PRAGMA user_version").first?.integer("user_version") ?? 0)
    let names = try query(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"
    ).compactMap { $0.text("name") }
    return HarnessSQLiteConfiguration(
      journalMode: mode, foreignKeysEnabled: foreignKeys,
      schemaVersion: version, tableNames: names)
  }

  @discardableResult
  func run(_ sql: String, _ bindings: [HarnessSQLiteValue] = []) throws -> Int {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else { throw failure("sqlite step", code: result) }
    return Int(sqlite3_changes(requiredHandle()))
  }

  func query(
    _ sql: String,
    _ bindings: [HarnessSQLiteValue] = []
  ) throws -> [HarnessSQLiteRow] {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    var rows: [HarnessSQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else { throw failure("sqlite query", code: result) }
      var values: [String: HarnessSQLiteValue] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, index))
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
          values[name] = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
          values[name] = .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
          guard let bytes = sqlite3_column_text(statement, index) else {
            values[name] = .null
            continue
          }
          values[name] = .text(String(cString: bytes))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, index))
          if count == 0 {
            values[name] = .blob(Data())
          } else if let bytes = sqlite3_column_blob(statement, index) {
            values[name] = .blob(Data(bytes: bytes, count: count))
          } else {
            values[name] = .null
          }
        default:
          values[name] = .null
        }
      }
      rows.append(HarnessSQLiteRow(values: values))
    }
    return rows
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    let depth = transactionDepth
    let savepoint = "harness_nested_\(depth)"
    if depth == 0 {
      try executeBatch("BEGIN IMMEDIATE")
    } else {
      try executeBatch("SAVEPOINT \(savepoint)")
    }
    transactionDepth += 1
    let result: T
    do {
      result = try body()
    } catch {
      transactionDepth -= 1
      if depth == 0 {
        try? executeBatch("ROLLBACK")
      } else {
        try? executeBatch("ROLLBACK TO SAVEPOINT \(savepoint)")
        try? executeBatch("RELEASE SAVEPOINT \(savepoint)")
      }
      throw error
    }
    transactionDepth -= 1
    do {
      if depth == 0 {
        try executeBatch("COMMIT")
      } else {
        try executeBatch("RELEASE SAVEPOINT \(savepoint)")
      }
    } catch {
      if depth == 0 {
        try? executeBatch("ROLLBACK")
      } else {
        try? executeBatch("ROLLBACK TO SAVEPOINT \(savepoint)")
        try? executeBatch("RELEASE SAVEPOINT \(savepoint)")
      }
      throw error
    }
    return result
  }

  var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(requiredHandle()) }

  static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    do {
      return try encoder.encode(value)
    } catch {
      throw HarnessTaskStoreError.ioFailure("cannot encode canonical harness JSON: \(error)")
    }
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw HarnessTaskStoreError.corrupt("cannot decode harness sqlite JSON: \(error)")
    }
  }

  static func digest(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }

  private func configure() throws {
    guard sqlite3_busy_timeout(requiredHandle(), 5_000) == SQLITE_OK else {
      throw failure("cannot set sqlite busy timeout")
    }
    let mode = try query("PRAGMA journal_mode=WAL").first?.text("journal_mode")
    guard mode?.lowercased() == "wal" else {
      throw HarnessTaskStoreError.ioFailure("harness sqlite WAL mode unavailable")
    }
    try executeBatch("PRAGMA foreign_keys=ON")
    guard try query("PRAGMA foreign_keys").first?.integer("foreign_keys") == 1 else {
      throw HarnessTaskStoreError.ioFailure("harness sqlite foreign keys unavailable")
    }
    try executeBatch("PRAGMA synchronous=FULL")
  }

  private func bootstrapSchemaIfNeeded() throws {
    let current = Int(try query("PRAGMA user_version").first?.integer("user_version") ?? 0)
    guard current <= Self.schemaVersion else {
      throw HarnessTaskStoreError.corrupt(
        "harness sqlite schema \(current) is newer than supported \(Self.schemaVersion)")
    }
    guard current < Self.schemaVersion else { return }
    try transaction {
      try executeBatch(Self.schemaV1)
      try executeBatch("PRAGMA user_version=\(Self.schemaVersion)")
      try run(
        "INSERT OR REPLACE INTO schema_migration(version, applied_at_utc) VALUES(?, ?)",
        [.integer(Int64(Self.schemaVersion)), .text(Self.utcNow())])
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(requiredHandle(), sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
      throw failure("cannot prepare sqlite statement", code: code)
    }
    return statement
  }

  private func bind(_ values: [HarnessSQLiteValue], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .null:
        code = sqlite3_bind_null(statement, index)
      case .integer(let number):
        code = sqlite3_bind_int64(statement, index, number)
      case .real(let number):
        code = sqlite3_bind_double(statement, index, number)
      case .text(let text):
        code = text.withCString {
          sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
      case .blob(let data):
        code = data.withUnsafeBytes { bytes in
          sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
      }
      guard code == SQLITE_OK else { throw failure("cannot bind sqlite value", code: code) }
    }
  }

  private func executeBatch(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(requiredHandle(), sql, nil, nil, &message)
    guard code == SQLITE_OK else {
      let detail = message.map { String(cString: $0) }
      if let message { sqlite3_free(message) }
      throw HarnessTaskStoreError.ioFailure(
        "sqlite batch failed: \(detail ?? String(cString: sqlite3_errmsg(requiredHandle())))")
    }
  }

  private func requiredHandle() -> OpaquePointer {
    guard let handle else { preconditionFailure("closed harness sqlite handle") }
    return handle
  }

  private func failure(_ operation: String, code: Int32? = nil) -> HarnessTaskStoreError {
    let suffix = code.map { " [\($0)]" } ?? ""
    return .ioFailure("\(operation)\(suffix): \(String(cString: sqlite3_errmsg(requiredHandle())))")
  }

  private static func utcNow() -> String {
    ISO8601Timestamps.string(from: Date(), includingFractionalSeconds: true)
  }

  private static let schemaV1 = """
    CREATE TABLE schema_migration(
      version INTEGER PRIMARY KEY,
      applied_at_utc TEXT NOT NULL
    );
    CREATE TABLE storage_metadata(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE harness_task(
      task_id TEXT PRIMARY KEY,
      state_version INTEGER NOT NULL CHECK(state_version >= 1),
      snapshot_json BLOB NOT NULL,
      snapshot_digest TEXT NOT NULL,
      result_json BLOB,
      created_at_utc TEXT NOT NULL,
      updated_at_utc TEXT NOT NULL
    );
    CREATE TABLE task_event(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      sequence INTEGER NOT NULL,
      event_json BLOB NOT NULL,
      event_digest TEXT NOT NULL,
      at_utc TEXT NOT NULL,
      PRIMARY KEY(task_id, sequence)
    );
    CREATE TABLE task_condition(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      condition_json BLOB NOT NULL,
      condition_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, name)
    );
    CREATE TABLE attempt(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      attempt_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      attempt_json BLOB NOT NULL,
      attempt_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, attempt_id),
      UNIQUE(task_id, ordinal)
    );
    CREATE TABLE attempt_event(
      task_id TEXT NOT NULL,
      attempt_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      event_json BLOB NOT NULL,
      event_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, sequence),
      FOREIGN KEY(task_id, attempt_id) REFERENCES attempt(task_id, attempt_id) ON DELETE CASCADE
    );
    CREATE TABLE model_run(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      model_run_id TEXT NOT NULL,
      round INTEGER NOT NULL,
      run_json BLOB NOT NULL,
      run_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, model_run_id)
    );
    CREATE TABLE decision(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      round INTEGER NOT NULL,
      decision_id TEXT NOT NULL,
      decision_json BLOB NOT NULL,
      decision_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, round)
    );
    CREATE TABLE action_run(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      action_run_id TEXT NOT NULL,
      attempt_id TEXT,
      recorded_at_utc TEXT NOT NULL,
      PRIMARY KEY(task_id, action_run_id),
      FOREIGN KEY(task_id, attempt_id) REFERENCES attempt(task_id, attempt_id) ON DELETE CASCADE
    );
    CREATE TABLE dispatch_intent(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      round INTEGER NOT NULL,
      request_id TEXT NOT NULL,
      intent_json BLOB NOT NULL,
      intent_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, round)
    );
    CREATE TABLE runtime_job_link(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      job_id TEXT NOT NULL,
      request_id TEXT,
      round INTEGER,
      linked_at_utc TEXT NOT NULL,
      PRIMARY KEY(task_id, job_id)
    );
    CREATE TABLE artifact_link(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      artifact_id TEXT NOT NULL,
      source TEXT NOT NULL,
      linked_at_utc TEXT NOT NULL,
      PRIMARY KEY(task_id, artifact_id, source)
    );
    CREATE TABLE evaluation(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      evaluation_id TEXT NOT NULL,
      round INTEGER NOT NULL,
      evaluation_json BLOB NOT NULL,
      evaluation_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, evaluation_id)
    );
    CREATE TABLE human_action(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      action_id TEXT NOT NULL,
      action_json BLOB NOT NULL,
      action_digest TEXT NOT NULL,
      generated_at_utc TEXT NOT NULL,
      PRIMARY KEY(task_id, action_id)
    );
    CREATE TABLE memory_entry(
      entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id TEXT REFERENCES harness_task(task_id) ON DELETE CASCADE,
      scope TEXT NOT NULL,
      scope_key TEXT NOT NULL,
      memory_id TEXT NOT NULL,
      lifecycle TEXT NOT NULL,
      summary TEXT NOT NULL,
      entry_json BLOB NOT NULL,
      entry_digest TEXT NOT NULL,
      updated_at_utc TEXT NOT NULL
    );
    CREATE INDEX memory_scope_key_idx ON memory_entry(scope, scope_key, entry_id);
    CREATE INDEX memory_identity_idx ON memory_entry(memory_id, entry_id);
    CREATE VIRTUAL TABLE memory_fts USING fts5(summary, content='');
    CREATE TABLE context_manifest(
      task_id TEXT NOT NULL REFERENCES harness_task(task_id) ON DELETE CASCADE,
      context_digest TEXT NOT NULL,
      model_run_id TEXT NOT NULL,
      observed_state_version INTEGER NOT NULL,
      byte_count INTEGER NOT NULL,
      manifest_json BLOB NOT NULL,
      manifest_digest TEXT NOT NULL,
      PRIMARY KEY(task_id, context_digest, model_run_id),
      FOREIGN KEY(task_id, model_run_id) REFERENCES model_run(task_id, model_run_id) ON DELETE CASCADE
    );
    CREATE TABLE reconcile_lease(
      task_id TEXT PRIMARY KEY REFERENCES harness_task(task_id) ON DELETE CASCADE,
      holder_id TEXT NOT NULL,
      expires_at_unix REAL NOT NULL
    );
    """
}
