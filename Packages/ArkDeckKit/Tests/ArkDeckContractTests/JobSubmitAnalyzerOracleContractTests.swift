// Shared Swift oracle for the Rust `job.submit` admitter (CHG-2026-074, TASK-XPA-014).

import CryptoKit
import Darwin
import SQLite3
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Counts dispatch attempts: admission must never reach the dispatcher.
private final class SubmitDispatchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  var count: Int { lock.withLock { attempts } }
  func record() { lock.withLock { attempts += 1 } }
}

private struct SubmitOnlyDispatcher: RuntimeProcessDispatching {
  let counter: SubmitDispatchCounter

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    counter.record()
    throw RuntimeDispatchFailure.failed("job.submit must not dispatch")
  }
}

/// Swift `job.submit` for `analyzer.extract-crash-signature@1`: the oracle
/// `rust/crates/arkdeck-hoststore/tests/job_admission.rs` replays against the
/// Rust admitter. The requests run in order over one Job store, so later ones
/// meet earlier Jobs (duplicates, conflicts, reviewed plans), and the oracle
/// keeps the store they leave: every admitted Job's files and the admission
/// index, and how `job.status` and `job.show` read each admitted Job. A run
/// with `ARKDECK_CONTROL_FRAME_LOG` also records the frames those method
/// schemas are derived from, a Job carrying a thread among them.
///
/// It admits under the `job.plan` oracle's fixed physical root and lock, since
/// the plan digest covers the source Artifact's absolute path. Record a new
/// oracle with `ARKDECK_RUST_JOB_SUBMIT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class JobSubmitAnalyzerOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    var engine = "configured"
    var params: [String: JSONValue]?
    var requestJsonSpaces: Int?
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/job-submit-analyzer", directoryHint: .isDirectory)
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-job-plan-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/private/tmp/arkdeck-job-plan-oracle.lock"
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let sourceJob = "job-oracle-source"
  private static let target = "TGT-ORACLE"
  /// Admission pins these bytes by digest; it never executes them.
  private static let analyzerBytes = Data(
    "#!/bin/sh\n# ArkDeck job.submit oracle analyzer: pinned by digest, never executed.\nexit 64\n"
      .utf8)
  private static let sourceBytes = Data("FATAL EXCEPTION: oracle crash\n".utf8)

  func testSwiftAdmitsTheSharedAnalyzerOracle() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
    let files = try await oracleFiles()
    if let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_SUBMIT_RECORD"] {
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
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: Self.oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: Self.oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(recorded), Set(files.keys))
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: Self.oracle.appending(path: path)), data, path)
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.root)
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: Self.root) }
    let analyzer = Self.root.appending(path: "analyzer")
    try Self.analyzerBytes.write(to: analyzer)
    guard chmod(analyzer.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let artifacts = Self.root.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(rootURL: artifacts, nowUTC: { Self.nowUTC })
    let source = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: Self.sourceJob, sessionID: "HTASK-JOBSUBMITORACLE", stepID: "capture-crash-log",
        name: "crash-log.txt", mediaType: "text/plain", privacy: .standard,
        retentionClass: .default, sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: Self.target, bindingRevision: 3,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: Self.sourceBytes))
    let lease = try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
    let counter = SubmitDispatchCounter()
    let profile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path,
      executableSHA256: AnalyzerProvider.sha256(Self.analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30)
    let jobsState = Self.root.appending(path: "jobs-state", directoryHint: .isDirectory)
    let (engine, configured) = try handler(
      store: store, counter: counter, state: jobsState,
      provider: AnalyzerProvider(profiles: [profile]))
    let (_, unconfigured) = try handler(
      store: store, counter: counter,
      state: Self.root.appending(path: "jobs-state-unconfigured", directoryHint: .isDirectory),
      provider: AnalyzerProvider())
    var recorded: [JSONValue] = []
    var admittedJobs: [String] = []
    for item in try await cases(engine: engine, lease: lease) {
      let params =
        item.params
        ?? ["requestJson": .string(String(repeating: " ", count: item.requestJsonSpaces ?? 0))]
      let response = try await exchange(
        item.engine == "unconfigured" ? unconfigured : configured, "job.submit", params)
      check(response, item.name)
      if case .object(let fields) = response, case .object(let result)? = fields["result"],
        result["deduplicated"] == .bool(false), case .string(let jobID)? = result["jobId"]
      {
        admittedJobs.append(jobID)
      }
      var entry: [String: JSONValue] = ["name": .string(item.name), "response": response]
      if item.engine != "configured" { entry["engine"] = .string(item.engine) }
      if let params = item.params { entry["params"] = .object(params) }
      if let spaces = item.requestJsonSpaces { entry["requestJsonSpaces"] = .integer(Int64(spaces)) }
      recorded.append(.object(entry))
    }
    // How Swift reads each admitted Job, the thread-bearing one included.
    var reads: [String: JSONValue] = [:]
    for jobID in admittedJobs {
      var answers: [String: JSONValue] = [:]
      for method in ["job.status", "job.show"] {
        answers[method] = try await exchange(configured, method, ["jobId": .string(jobID)])
      }
      reads[jobID] = .object(answers)
    }
    XCTAssertEqual(admittedJobs.count, 4)
    XCTAssertEqual(counter.count, 0, "job.submit must not dispatch")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "analyzer": Self.analyzerBytes,
      "cases.json": try encoder.encode(JSONValue.array(recorded)) + Data("\n".utf8),
      "reads.json": try encoder.encode(JSONValue.object(reads)) + Data("\n".utf8),
      "store/index.json": try encoder.encode(try Self.index(of: jobsState)) + Data("\n".utf8),
    ]
    // The published index and payloads; the payload-verification cache
    // records this machine's inodes and times, so it is no part of the oracle.
    let sourceDirectory = artifacts.appending(path: Self.sourceJob, directoryHint: .isDirectory)
    for name in try manager.contentsOfDirectory(atPath: sourceDirectory.path).sorted()
    where !name.hasPrefix(".") {
      files["artifacts/\(Self.sourceJob)/\(name)"] = try Data(
        contentsOf: sourceDirectory.appending(path: name))
    }
    // Every file each admitted Job's directory holds.
    let jobs = jobsState.appending(path: "jobs", directoryHint: .isDirectory)
    for job in try manager.contentsOfDirectory(atPath: jobs.path).sorted() {
      let directory = jobs.appending(path: job, directoryHint: .isDirectory)
      for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() {
        files["store/jobs/\(job)/\(name)"] = try Data(contentsOf: directory.appending(path: name))
      }
    }
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(Self.sha256(data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "JobSubmitAnalyzerOracleContractTests/testSwiftAdmitsTheSharedAnalyzerOracle"),
          "root": .string(Self.root.path),
          "nowUTC": .string(Self.nowUTC),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }

  private func cases(engine: RuntimeJobEngine, lease: String) async throws -> [Case] {
    func document(_ key: String, _ changes: [String: JSONValue?] = [:]) throws -> String {
      var fields: [String: JSONValue] = [
        "documentType": .string("runtime-operation-request"),
        "schemaVersion": .string("1.0.0"),
        "requestId": .string("req-oracle-submit-\(key)"),
        "idempotencyKey": .string("idem-oracle-submit-\(key)-0001"),
        "target": .object(["targetId": .string(Self.target)]),
        "operation": .object([
          "id": .string("analyzer.extract-crash-signature"), "version": .integer(1),
        ]),
        "inputs": .object(["sourceArtifactRef": .string(lease)]),
      ]
      for (name, value) in changes { fields[name] = value }
      let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
      return String(decoding: bytes, as: UTF8.self)
    }
    func request(_ key: String, _ changes: [String: JSONValue?] = [:]) throws -> [String: JSONValue] {
      ["requestJson": .string(try document(key, changes))]
    }
    // Every request here plans the same materialized plan: its digest covers
    // the operation, the inputs and the target, not the request identity.
    let digest = try await engine.planOnly(Data(try document("a").utf8)).materializedPlanDigest
    let other = String(repeating: "0", count: 64)
    // Refused parameter shapes are left to the job.plan oracle: the params
    // check is shared, and recording one here would publish it in the
    // job.submit request schema.
    return [
      Case(name: "admitted", params: try request("a")),
      Case(name: "duplicate", params: try request("a")),
      Case(
        name: "duplicateWithReviewedPlan",
        params: try request("a", ["reviewedPlanDigest": .string(digest)])),
      Case(
        name: "duplicateWithOtherReviewedPlan",
        params: try request("a", ["reviewedPlanDigest": .string(other)])),
      Case(
        name: "conflict",
        params: try request("a", ["requestId": .string("req-oracle-submit-a-changed")])),
      Case(
        name: "admittedWithReviewedPlan",
        params: try request("b", ["reviewedPlanDigest": .string(digest)])),
      Case(
        name: "freshPlanDiffersFromReviewedPlan",
        params: try request("c", ["reviewedPlanDigest": .string(other)])),
      Case(
        name: "admittedWithCallerCapability",
        params: try request(
          "d", ["authorization": .object(["capabilityId": .string("CAP-RT-ORACLE-D")])])),
      Case(
        name: "admittedWithClientContext",
        params: try request(
          "e",
          [
            "documentType": nil,
            "requestedOutputs": .array([.string("analysisReport"), .string("derivedArtifacts")]),
            "clientContext": .object([
              "clientName": .string("oracle"),
              "provenance": .object(["arkdeck.threadId": .string("thread-oracle")]),
            ]),
          ])),
      Case(
        name: "unresolvableLease",
        params: try request(
          "f",
          [
            "inputs": .object([
              "sourceArtifactRef": .string(
                "lease-v1:\(Self.sourceJob):ART-\(String(repeating: "0", count: 32))")
            ])
          ])),
      Case(
        name: "unknownOperation",
        params: try request(
          "g",
          [
            "operation": .object([
              "id": .string("analyzer.no-such-operation"), "version": .integer(1),
            ])
          ])),
      Case(
        name: "pinnedBindingRevision",
        params: try request(
          "h",
          [
            "target": .object([
              "targetId": .string(Self.target), "expectedBindingRevision": .integer(3),
            ])
          ])),
      Case(name: "missingInput", params: try request("i", ["inputs": .object([:])])),
      Case(name: "malformedJSON", params: ["requestJson": .string("{\"schemaVersion\":")]),
      Case(name: "emptyRequestJson", params: ["requestJson": .string("")]),
      Case(name: "requestTooLarge", requestJsonSpaces: 1_048_577),
      Case(name: "unconfiguredAnalyzer", engine: "unconfigured", params: try request("j")),
      Case(name: "duplicateAfterOthers", params: try request("a")),
    ]
  }

  /// A submit is never dispatched, and a refusal before the admission point
  /// says so.
  private func check(_ response: JSONValue, _ name: String) {
    guard case .object(let fields) = response else { return XCTFail(name) }
    if fields["ok"] == .bool(true) {
      guard case .object(let result)? = fields["result"] else { return XCTFail(name) }
      XCTAssertEqual(result["newDispatchCount"], .integer(0), name)
    } else {
      guard case .object(let error)? = fields["error"] else { return XCTFail(name) }
      XCTAssertEqual(
        error["details"],
        .object(["phase": .string("preAdmission"), "newDispatchCount": .integer(0)]), name)
    }
  }

  private func handler(
    store: RuntimeArtifactStore, counter: SubmitDispatchCounter, state: URL,
    provider: AnalyzerProvider
  ) throws -> (RuntimeJobEngine, RuntimeControlPlaneHandler) {
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: state),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: SubmitOnlyDispatcher(counter: counter), capabilityStore: capabilities,
      artifactStore: store, nowUTC: { Self.nowUTC })
    return (
      engine,
      RuntimeControlPlaneHandler(
        engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
        nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
        flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
        methodObserver: nil)
    )
  }

  private func exchange(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("job-submit-oracle"), "method": .string(method),
        "params": .object(params),
      ]))
    let response = await handler.handleFrame(frame)
    var fields: [String: JSONValue] = ["ok": .bool(response.ok)]
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var body: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { body["details"] = .object(details) }
      fields["error"] = .object(body)
    }
    return .object(fields)
  }

  /// What a reader observes of the admission index without writing: layout,
  /// pragmas and every row, as `JobStoreRustWriterParityContractTests` reads it.
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
    ])
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
