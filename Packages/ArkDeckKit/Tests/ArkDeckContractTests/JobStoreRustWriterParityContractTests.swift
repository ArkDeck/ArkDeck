import ArkDeckCore
import ArkDeckRuntime
import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Shared oracle for the Rust Job index and record writers (TASK-XPA-014).
///
/// Swift `RuntimeJobRecord.durableData()` bytes for record variants built from
/// the Swift-produced `job-publication-current` records, a Foundation
/// pretty-print probe, and the SQLite facts `RuntimeAdmissionService` and
/// `RuntimeJobRecord.persist(into:)` leave after one admission scenario.
/// `rust/crates/arkdeck-hoststore/tests/job_store_writer.rs` must reproduce the
/// bytes and the facts. Record a new oracle with
/// `ARKDECK_RUST_JOB_STORE_RECORD=/private/tmp/<new directory>`. With
/// `ARKDECK_RUST_JOB_STORE_VERIFY=<state directory the Rust owner wrote>`,
/// Swift also opens and reads a Rust-written store.
final class JobStoreRustWriterParityContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/job-store-writer", directoryHint: .isDirectory)
  private static let base = repository.appending(
    path: "rust/tests/fixtures/job-publication-current", directoryHint: .isDirectory)
  private static let hashA = String(repeating: "a", count: 64)
  private static let hashB = String(repeating: "b", count: 64)
  private static let hashOther = String(repeating: "c", count: 64)
  private static let jobB = "job-rust-store-b"
  private static let keyB = "idem-rust-store-b"

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "job-store-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testSwiftWritesTheSharedJobStoreOracle() throws {
    let files = try oracleFiles()
    if let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_STORE_RECORD"] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: Self.oracle.appending(path: path)), data, path)
    }
  }

  func testSwiftReadsTheStoreTheRustOwnerWrote() throws {
    guard let source = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_STORE_VERIFY"] else {
      throw XCTSkip("ARKDECK_RUST_JOB_STORE_VERIFY names a state directory the Rust owner wrote")
    }
    let state = root.appending(path: "rust-state", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: source, isDirectory: true), to: state)
    let expected = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "index.json")))
    XCTAssertEqual(try Self.index(of: state), expected)
    let service = try RuntimeAdmissionService(stateDirectory: state)
    let jobs = try service.allJobs()
    XCTAssertEqual(jobs.count, 2)
    for job in jobs {
      guard
        case .readable(let record) = RuntimeJobRecord.state(
          in: Self.jobDirectory(job.jobID, in: state))
      else { return XCTFail("Swift cannot read the Rust-written record of \(job.jobID)") }
      XCTAssertEqual(try record.durableData(), job.initialRecordData, job.jobID)
      XCTAssertEqual(record.state, job.state, job.jobID)
    }
    let first = try XCTUnwrap(jobs.first { $0.jobID != Self.jobB })
    XCTAssertEqual(
      try service.lookup(idempotencyKey: first.idempotencyKey, requestHash: Self.hashA),
      .duplicate(jobID: first.jobID))
    XCTAssertEqual(
      try service.lookup(idempotencyKey: first.idempotencyKey, requestHash: Self.hashOther),
      .conflict)
    XCTAssertEqual(
      try service.lookup(idempotencyKey: Self.keyB, requestHash: Self.hashB),
      .duplicate(jobID: Self.jobB))
  }

  // MARK: - Oracle

  /// Every oracle file, by its path in the oracle directory.
  private func oracleFiles() throws -> [(String, Data)] {
    let records = try Self.records()
    var files = try records.map { ("records/\($0.0).json", try $0.1.durableData()) }
    files.append(("format-probe.json", try Self.pretty(Self.probe)))
    let (scenario, index) = try runScenario(Dictionary(uniqueKeysWithValues: records))
    files.append(("scenario.json", try Self.pretty(.array(scenario))))
    files.append(("index.json", try Self.pretty(index)))
    return files
  }

  private static func pretty(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(value)
  }

  /// Foundation spellings a durable record can carry: empty containers,
  /// escapes, integers, floating point and key order.
  private static let probe: JSONValue = .object([
    "emptyObject": .object([:]),
    "emptyArray": .array([]),
    "nested": .array([.array([]), .object([:]), .array([.integer(1)]), .object(["k": .null])]),
    "strings": .array([
      .string("a/b"), .string("\u{e9}\u{1f600}"), .string("\u{7}\u{1f}\u{7f}"),
      .string("\n\t\r\u{8}\u{c}"), .string("\"\\"), .string("\u{2028}\u{2029}"),
      .string("\u{0}"), .string("</script>"),
    ]),
    "integers": .array([
      .integer(0), .integer(-1), .integer(.max), .integer(.min), .unsignedInteger(.max),
    ]),
    "numbers": .array([
      .number(0.5), .number(0.1), .number(1e-7), .number(1e21), .number(1e16), .number(1e15),
      .number(123_456_789.123), .number(5e-324), .number(2.5e-5),
      .number(1.7976931348623157e308), .number(0.30000000000000004), .number(1e-5),
      .number(0.0001), .number(1),
    ]),
    "scalars": .array([.bool(true), .bool(false), .null]),
    "keys": .object([
      "b": .integer(0), "a": .integer(1), "B": .integer(2), "_": .integer(3),
      "a10": .integer(4), "a2": .integer(5), "\u{e4}": .integer(6), "Z": .integer(7),
      "~": .integer(8), "\u{7f}": .integer(9), "\u{e9}": .integer(10), "\u{fb00}": .integer(11),
      "\u{1f600}": .integer(12), "a/b": .integer(13), "ss": .integer(14), "\u{df}": .integer(15),
    ]),
  ])

  private static func decode(_ data: Data) throws -> RuntimeJobRecord {
    try JSONDecoder().decode(RuntimeJobRecord.self, from: data)
  }

  /// The record as Swift admission leaves it: RuntimeJobEngine sets preflight
  /// and the first two timeline entries before any Step runs.
  private static func admitted(_ record: RuntimeJobRecord) -> RuntimeJobRecord {
    var record = record
    record.state = "preflight"
    record.outcomeUnknown = false
    record.operationFailure = nil
    record.recoveryStepID = nil
    record.recoveryAction = nil
    record.recoveryIntentEventID = nil
    record.timeline = ["jobCreated", "queued->preflight"]
    record.evidencePreflight = nil
    record.evidenceObservation = nil
    record.traceProbeBefore = nil
    record.traceProbeAfter = nil
    record.actualStepKinds = nil
    record.startedAtUTC = nil
    record.firstEvidenceStepAtUTC = nil
    record.finishedAtUTC = nil
    record.ringCoverage = nil
    record.screenSequence = nil
    record.skipReasons = [:]
    record.outstandingResidueCount = nil
    record.sessionPublicationRecord = nil
    return record
  }

  /// A second Job from the other Swift fixture: the same request under its own
  /// Job and idempotency identity, without the facts of its finished run.
  private static func renamed(_ data: Data) throws -> RuntimeJobRecord {
    guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: data),
      case .object(var request) = fields["request"],
      case .object(var original) = fields["originalSubmissionRequest"]
    else { throw CocoaError(.coderReadCorrupt) }
    request["idempotencyKey"] = .string(keyB)
    original["idempotencyKey"] = .string(keyB)
    fields["jobID"] = .string(jobB)
    fields["request"] = .object(request)
    fields["originalSubmissionRequest"] = .object(original)
    for key in [
      "evidencePreflight", "evidenceObservation", "sessionPublicationRecord", "actualStepKinds",
      "startedAtUTC", "firstEvidenceStepAtUTC", "finishedAtUTC",
    ] {
      fields[key] = nil
    }
    return try decode(JSONEncoder().encode(JSONValue.object(fields)))
  }

  private static func records() throws -> [(String, RuntimeJobRecord)] {
    let publishedBytes = try Data(contentsOf: base.appending(path: "published/job-record.json"))
    let published = try decode(publishedBytes)
    XCTAssertEqual(try published.durableData(), publishedBytes)
    let admittedA = admitted(published)
    var runningA = admittedA
    runningA.state = "running"
    runningA.startedAtUTC = "2026-07-29T00:00:01Z"
    runningA.timeline += [
      "preflight->running", "step capture/trace \u{e9}\u{7} \"quoted\" \\ back\u{2028}",
    ]
    runningA.actualStepKinds = ["probeHostTool"]
    runningA.skipReasons = ["optional/step": "skipped: no device", "a": "b"]
    runningA.screenSequence = RuntimeScreenSequence(
      requestedFrameCount: 7, capturedFrameCount: 6,
      frameDurationsSeconds: [
        0.5, 0.1, 1, 1e-7, 123_456_789.123, 2.5e-5, 1e16, 0.30000000000000004,
      ])
    runningA.ringCoverage = RuntimeRingCoverage(anchor: "ring/anchor", ringHeldAnchor: true)
    runningA.outstandingResidueCount = 2
    let admittedB = admitted(
      try renamed(Data(contentsOf: base.appending(path: "failed/job-record.json"))))
    var unknownB = admittedB
    unknownB.state = "waitingForRecovery"
    unknownB.outcomeUnknown = true
    unknownB.startedAtUTC = "2026-07-29T00:00:02Z"
    unknownB.recoveryStepID = "run-approved-remote-read"
    unknownB.operationFailure = RuntimeOperationFailure(
      code: .executionFailed, category: .execution, retryability: .runtimeDecisionRequired,
      recovery: .inspectJob)
    unknownB.timeline += ["preflight->running", "running->waitingForRecovery"]
    return [
      ("admitted-a", admittedA), ("running-a", runningA), ("published-a", published),
      ("admitted-b", admittedB), ("unknown-b", unknownB),
    ]
  }

  private static func verdict(_ value: RuntimeJobAdmissionVerdict) -> JSONValue {
    switch value {
    case .admitted: .string("admitted")
    case .conflict: .string("conflict")
    case .duplicate(let jobID): .object(["duplicate": .string(jobID)])
    }
  }

  private static func jobDirectory(_ jobID: String, in state: URL) -> URL {
    state.appending(path: "jobs/\(jobID)", directoryHint: .isDirectory)
  }

  /// One admission scenario through the Swift owners, recorded as steps the
  /// Rust owner replays, and the index facts it leaves.
  private func runScenario(
    _ records: [String: RuntimeJobRecord]
  ) throws -> ([JSONValue], JSONValue) {
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var steps: [JSONValue] = []
    do {
      let service = try RuntimeAdmissionService(stateDirectory: state)
      func admit(_ name: String, _ hash: String, _ expected: RuntimeJobAdmissionVerdict) throws {
        let record = try XCTUnwrap(records[name])
        let verdict = try service.admit(record: record, requestHash: hash)
        XCTAssertEqual(verdict, expected, name)
        if verdict == .admitted {
          // RuntimeJobEngine creates the Job directory right after admission.
          try FileManager.default.createDirectory(
            at: Self.jobDirectory(record.jobID, in: state), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        }
        steps.append(
          .object([
            "op": .string("admit"), "record": .string("records/\(name).json"),
            "requestHash": .string(hash), "verdict": Self.verdict(verdict),
          ]))
      }
      func lookup(_ key: String, _ hash: String, _ expected: RuntimeJobAdmissionVerdict) throws {
        let verdict = try service.lookup(idempotencyKey: key, requestHash: hash)
        XCTAssertEqual(verdict, expected, key)
        steps.append(
          .object([
            "op": .string("lookup"), "idempotencyKey": .string(key),
            "requestHash": .string(hash), "verdict": Self.verdict(verdict),
          ]))
      }
      func persist(_ name: String, at timestamp: String) throws {
        let record = try XCTUnwrap(records[name])
        // RuntimeJobEngine.persistRuntimeRecord: the Job-local record, then the index.
        try record.persist(into: Self.jobDirectory(record.jobID, in: state))
        try service.persist(record, at: timestamp)
        steps.append(
          .object([
            "op": .string("persist"), "record": .string("records/\(name).json"),
            "at": .string(timestamp),
          ]))
      }
      let a = try XCTUnwrap(records["admitted-a"])
      try admit("admitted-a", Self.hashA, .admitted)
      try admit("admitted-b", Self.hashB, .admitted)
      try admit("admitted-a", Self.hashA, .duplicate(jobID: a.jobID))
      try admit("admitted-a", Self.hashOther, .conflict)
      try lookup(a.request.idempotencyKey, Self.hashA, .duplicate(jobID: a.jobID))
      try lookup(a.request.idempotencyKey, Self.hashOther, .conflict)
      try lookup("idem-absent", Self.hashA, .admitted)
      try persist("running-a", at: "2026-07-29T00:00:03Z")
      try persist("unknown-b", at: "2026-07-29T00:00:04Z")
      try persist("published-a", at: "2026-07-29T00:00:05Z")
    }
    // The service is released here, so its connection closed and checkpointed.
    return (steps, try Self.index(of: state))
  }

  /// What a reader observes of the index without writing: layout, pragmas,
  /// every row, and each Job-local record's digest.
  private static func index(of state: URL) throws -> JSONValue {
    var handle: OpaquePointer?
    let path = state.appending(path: RuntimeJobRepository.filename).path
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let db = handle
    else {
      if let handle { sqlite3_close_v2(handle) }
      throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close_v2(db) }
    func rows(_ sql: String) throws -> [[JSONValue]] {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
      else { throw CocoaError(.fileReadCorruptFile) }
      defer { sqlite3_finalize(statement) }
      var result: [[JSONValue]] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        result.append(
          (0..<sqlite3_column_count(statement)).map { column -> JSONValue in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
              return .integer(sqlite3_column_int64(statement, column))
            case SQLITE_TEXT:
              return .string(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            case SQLITE_BLOB:
              let count = Int(sqlite3_column_bytes(statement, column))
              let bytes = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) }
              return .string(sha256(bytes ?? Data()))
            default:
              return .null
            }
          })
      }
    }
    let schema = try rows("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name").map {
      JSONValue.object(["name": $0[0], "type": $0[1], "tableName": $0[2], "sql": $0[3]])
    }
    let jobs = try rows(
      """
      SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc,
             created_at_order_key, updated_at_utc, version, initial_record_json
      FROM runtime_job ORDER BY admission_sequence
      """)
    var records: [String: JSONValue] = [:]
    for row in jobs {
      guard case .string(let jobID) = row[0] else { throw CocoaError(.fileReadCorruptFile) }
      let url = jobDirectory(jobID, in: state).appending(path: "job-record.json")
      records[jobID] = .string(sha256(try Data(contentsOf: url)))
    }
    return .object([
      "userVersion": try rows("PRAGMA user_version")[0][0],
      "journalMode": try rows("PRAGMA journal_mode")[0][0],
      "schema": .array(schema),
      "rows": .array(
        jobs.map { row in
          .object([
            "jobId": row[0], "idempotencyKey": row[1], "requestHash": row[2], "state": row[3],
            "admissionSequence": row[4], "createdAtUTC": row[5], "createdAtOrderKey": row[6],
            "updatedAtUTC": row[7], "version": row[8], "recordSHA256": row[9],
          ])
        }),
      "jobRecords": .object(records),
    ])
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
