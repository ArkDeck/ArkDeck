import Foundation
import SQLite3

enum RuntimeJobSQLiteTestSupport {
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func replaceInitialRecord(
    stateDirectory: URL, jobID: String, data: Data
  ) throws {
    let databaseURL = stateDirectory.appending(path: "runtime-jobs.sqlite3")
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
      databaseURL.path, &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard openCode == SQLITE_OK, let database else {
      throw failure("cannot open Runtime job test database", code: openCode)
    }
    defer { sqlite3_close_v2(database) }
    sqlite3_busy_timeout(database, 5_000)

    var statement: OpaquePointer?
    let prepareCode = sqlite3_prepare_v2(
      database,
      "UPDATE runtime_job SET initial_record_json = ? WHERE job_id = ?",
      -1, &statement, nil)
    guard prepareCode == SQLITE_OK, let statement else {
      throw failure(
        "cannot prepare Runtime job test update: \(String(cString: sqlite3_errmsg(database)))",
        code: prepareCode)
    }
    defer { sqlite3_finalize(statement) }

    let blobCode = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement, 1, bytes.baseAddress, Int32(bytes.count), Self.transient)
    }
    let textCode = jobID.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, Self.transient)
    }
    guard blobCode == SQLITE_OK, textCode == SQLITE_OK else {
      throw failure(
        "cannot bind Runtime job test update",
        code: blobCode == SQLITE_OK ? textCode : blobCode)
    }
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_DONE, sqlite3_changes(database) == 1 else {
      throw failure("cannot update Runtime job test record", code: stepCode)
    }
  }

  private static func failure(_ message: String, code: Int32) -> NSError {
    NSError(
      domain: "RuntimeJobSQLiteTestSupport", code: Int(code),
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
