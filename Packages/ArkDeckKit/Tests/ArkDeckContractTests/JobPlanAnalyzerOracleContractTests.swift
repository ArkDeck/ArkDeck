// Shared Swift oracle for the Rust `job.plan` planner (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Counts dispatch attempts: planning must never reach the dispatcher.
private final class PlanDispatchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  var count: Int { lock.withLock { attempts } }
  func record() { lock.withLock { attempts += 1 } }
}

private struct PlanOnlyDispatcher: RuntimeProcessDispatching {
  let counter: PlanDispatchCounter

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    counter.record()
    throw RuntimeDispatchFailure.failed("job.plan must not dispatch")
  }
}

/// Swift `job.plan` for `analyzer.extract-crash-signature@1`: the oracle
/// `rust/crates/arkdeck-hoststore/tests/job_plan.rs` replays against the Rust
/// planner. Requests travel the control handler, so a run with
/// `ARKDECK_CONTROL_FRAME_LOG` also records the `job.plan` frames the method
/// schema is derived from.
///
/// The materialized plan digest covers the source Artifact's absolute path, so
/// both sides plan under one fixed physical root. Each takes
/// `/private/tmp/arkdeck-job-plan-oracle.lock`, rebuilds the root and removes
/// it afterwards. Record a new oracle with
/// `ARKDECK_RUST_JOB_PLAN_RECORD=/private/tmp/<new directory>`; otherwise the
/// checked-in oracle must match byte for byte.
final class JobPlanAnalyzerOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    var engine = "configured"
    var mutation: String?
    var params: [String: JSONValue]?
    var requestJsonSpaces: Int?
  }

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/job-plan-analyzer", directoryHint: .isDirectory)
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-job-plan-oracle", directoryHint: .isDirectory)
  private static let lockPath = "/private/tmp/arkdeck-job-plan-oracle.lock"
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let sourceJob = "job-oracle-source"
  private static let target = "TGT-ORACLE"
  /// Planning pins these bytes by digest; it never executes them.
  private static let analyzerBytes = Data(
    "#!/bin/sh\n# ArkDeck job.plan oracle analyzer: pinned by digest, never executed.\nexit 64\n"
      .utf8)
  private static let sourceBytes = Data("FATAL EXCEPTION: oracle crash\n".utf8)

  func testSwiftPlansTheSharedAnalyzerOracle() async throws {
    let lock = open(Self.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
    let files = try await oracleFiles()
    if let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_PLAN_RECORD"] {
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
    let expected = try Dictionary(uniqueKeysWithValues: recorded.map { path in
      (path, try Data(contentsOf: Self.oracle.appending(path: path)))
    })
    let comparableExpected = try OracleSDKDiagnosticCompatibility.comparableFiles(expected, family: .jobPlanAnalyzer)
    let comparableActual = try OracleSDKDiagnosticCompatibility.comparableFiles(files, family: .jobPlanAnalyzer)
    for (path, data) in comparableActual {
      XCTAssertEqual(comparableExpected[path], data, path)
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
    let source = try await store.publish(publication("crash-log.txt", Self.sourceBytes))
    let empty = try await store.publish(publication("empty-crash-log.txt", Data()))
    let lease = try await store.leaseReference(jobID: source.jobID, artifactID: source.artifactID)
    let emptyLease = try await store.leaseReference(
      jobID: empty.jobID, artifactID: empty.artifactID)
    let counter = PlanDispatchCounter()
    let profile = AnalyzerProfile(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      executablePath: analyzer.path,
      executableSHA256: AnalyzerProvider.sha256(Self.analyzerBytes),
      fixedArguments: ["--analyze-crash-ledger"], timeoutSeconds: 30)
    let configured = try handler(
      store: store, counter: counter, state: Self.root,
      provider: AnalyzerProvider(profiles: [profile]))
    let unconfigured = try handler(
      store: store, counter: counter,
      state: Self.root.appending(path: "unconfigured", directoryHint: .isDirectory),
      provider: AnalyzerProvider())
    let payload = artifacts.appending(path: Self.sourceJob).appending(path: source.artifactID)
    var recorded: [JSONValue] = []
    for item in try cases(lease: lease, emptyLease: emptyLease, artifactID: source.artifactID) {
      let params =
        item.params
        ?? ["requestJson": .string(String(repeating: " ", count: item.requestJsonSpaces ?? 0))]
      let restore = try mutate(item.mutation, analyzer: analyzer, payload: payload)
      let response = try await plan(
        item.engine == "unconfigured" ? unconfigured : configured, params)
      try restore()
      check(response, item.name)
      var entry: [String: JSONValue] = ["name": .string(item.name), "response": response]
      if item.engine != "configured" { entry["engine"] = .string(item.engine) }
      if let mutation = item.mutation { entry["mutation"] = .string(mutation) }
      if let params = item.params { entry["params"] = .object(params) }
      if let spaces = item.requestJsonSpaces { entry["requestJsonSpaces"] = .integer(Int64(spaces)) }
      recorded.append(.object(entry))
    }
    XCTAssertEqual(counter.count, 0, "job.plan must not dispatch")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "analyzer": Self.analyzerBytes,
      "cases.json": try encoder.encode(JSONValue.array(recorded)) + Data("\n".utf8),
    ]
    // The published index and payloads. Planning also persists Swift's
    // payload-verification cache beside them; it records this machine's
    // inodes and times, so it is no part of the shared store.
    let sourceDirectory = artifacts.appending(path: Self.sourceJob, directoryHint: .isDirectory)
    for name in try manager.contentsOfDirectory(atPath: sourceDirectory.path).sorted()
    where !name.hasPrefix(".") {
      files["artifacts/\(Self.sourceJob)/\(name)"] = try Data(
        contentsOf: sourceDirectory.appending(path: name))
    }
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(AnalyzerProvider.sha256(data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "JobPlanAnalyzerOracleContractTests/testSwiftPlansTheSharedAnalyzerOracle"),
          "root": .string(Self.root.path),
          "nowUTC": .string(Self.nowUTC),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }

  private func cases(lease: String, emptyLease: String, artifactID: String) throws -> [Case] {
    let base: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-oracle-plan"),
      "idempotencyKey": .string("idem-oracle-plan-0001"),
      "target": .object(["targetId": .string(Self.target)]),
      "operation": .object([
        "id": .string("analyzer.extract-crash-signature"), "version": .integer(1),
      ]),
      "inputs": .object(["sourceArtifactRef": .string(lease)]),
    ]
    func request(_ changes: [String: JSONValue?] = [:]) throws -> [String: JSONValue] {
      var fields = base
      for (key, value) in changes { fields[key] = value }
      let bytes = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
      return ["requestJson": .string(String(decoding: bytes, as: UTF8.self))]
    }
    func source(_ reference: JSONValue) throws -> [String: JSONValue] {
      try request(["inputs": .object(["sourceArtifactRef": reference])])
    }
    func raw(_ text: String) -> [String: JSONValue] { ["requestJson": .string(text)] }
    // Refused parameter shapes stay those the committed corpus already
    // publishes, so recording this oracle does not widen the request schema.
    var extra = try request()
    extra["extra"] = .bool(true)
    return [
      Case(name: "planned", params: try request()),
      Case(
        name: "plannedWithClientContext",
        params: try request([
          "documentType": nil,
          "requestId": .string("req-oracle-context"),
          "idempotencyKey": .string("idem-oracle-context-0001"),
          "requestedOutputs": .array([.string("analysisReport"), .string("derivedArtifacts")]),
          "clientContext": .object([
            "clientName": .string("oracle"),
            "provenance": .object(["arkdeck.threadId": .string("thread-oracle")]),
          ]),
        ])),
      Case(name: "extraParameter", params: extra),
      Case(name: "missingRequestJson", params: [:]),
      Case(name: "emptyRequestJson", params: raw("")),
      Case(name: "requestTooLarge", requestJsonSpaces: 1_048_577),
      Case(name: "malformedJSON", params: raw("{\"schemaVersion\":")),
      Case(
        name: "duplicateKey",
        params: raw("{\"schemaVersion\":\"1.0.0\",\"schemaVersion\":\"1.0.0\"}")),
      Case(name: "notAnObject", params: raw("[]")),
      Case(name: "topLevelString", params: raw("\"request\"")),
      Case(name: "topLevelNumber", params: raw("7")),
      Case(name: "topLevelBool", params: raw("true")),
      Case(name: "topLevelNull", params: raw("null")),
      Case(name: "wrongSchemaVersion", params: try request(["schemaVersion": .string("2.0.0")])),
      Case(name: "wrongDocumentType", params: try request(["documentType": .string("runtime-job")])),
      Case(name: "governanceField", params: try request(["taskId": .string("TASK-XPA-014")])),
      Case(name: "retiredAuthority", params: try request(["standingAuthorization": .bool(true)])),
      Case(name: "unknownField", params: try request(["extra": .string("x")])),
      Case(
        name: "unknownNestedField",
        params: try request([
          "target": .object(["targetId": .string(Self.target), "extra": .integer(1)])
        ])),
      Case(
        name: "malformedReviewedPlanDigest",
        params: try request(["reviewedPlanDigest": .string("ABC")])),
      Case(name: "missingRequestId", params: try request(["requestId": nil])),
      Case(name: "malformedTarget", params: try request(["target": .string(Self.target)])),
      Case(name: "shortIdempotencyKey", params: try request(["idempotencyKey": .string("short")])),
      Case(name: "malformedRequestId", params: try request(["requestId": .string("-req")])),
      Case(
        name: "malformedOperationId",
        params: try request([
          "operation": .object(["id": .string("Analyzer"), "version": .integer(1)])
        ])),
      Case(
        name: "capability",
        params: try request([
          "authorization": .object(["capabilityId": .string("CAP-RT-ORACLE")])
        ])),
      Case(
        name: "unknownOperation",
        params: try request([
          "operation": .object([
            "id": .string("analyzer.no-such-operation"), "version": .integer(1),
          ])
        ])),
      Case(
        name: "unversionedOperation",
        params: try request([
          "operation": .object(["id": .string("analyzer.extract-crash-signature")])
        ])),
      Case(name: "missingInput", params: try request(["inputs": .object([:])])),
      Case(
        name: "undeclaredInput",
        params: try request([
          "inputs": .object([
            "sourceArtifactRef": .string(lease), "extraInput": .string("x"),
          ])
        ])),
      Case(name: "wrongInputType", params: try source(.integer(7))),
      Case(
        name: "executableInputKey",
        params: try request([
          "inputs": .object(["sourceArtifactRef": .string(lease), "argv": .string("x")])
        ])),
      Case(name: "inputsNotObject", params: try request(["inputs": .string("x")])),
      Case(name: "inputsNull", params: try request(["inputs": .null])),
      Case(
        name: "inputKeyNotCamelCase",
        params: try request(["inputs": .object(["SourceArtifactRef": .string(lease)])])),
      Case(
        name: "requestedOutputsNotArray",
        params: try request(["requestedOutputs": .string("derivedArtifacts")])),
      Case(
        name: "requestedOutputUnknown",
        params: try request(["requestedOutputs": .array([.string("everything")])])),
      Case(
        name: "requestedOutputsDuplicate",
        params: try request([
          "requestedOutputs": .array([.string("derivedArtifacts"), .string("derivedArtifacts")])
        ])),
      Case(
        name: "authorizationNotObject",
        params: try request(["authorization": .string("CAP-RT-ORACLE")])),
      Case(name: "authorizationWithoutCapability", params: try request(["authorization": .object([:])])),
      Case(
        name: "capabilityMalformed",
        params: try request(["authorization": .object(["capabilityId": .string("CAP-ORACLE")])])),
      Case(name: "clientContextNotObject", params: try request(["clientContext": .string("oracle")])),
      Case(
        name: "clientNameNotString",
        params: try request(["clientContext": .object(["clientName": .integer(7)])])),
      Case(
        name: "clientNameEmpty",
        params: try request(["clientContext": .object(["clientName": .string("")])])),
      Case(
        name: "provenanceValueNotString",
        params: try request([
          "clientContext": .object(["provenance": .object(["origin": .integer(1)])])
        ])),
      Case(
        name: "threadIdMalformed",
        params: try request([
          "clientContext": .object(["provenance": .object(["arkdeck.threadId": .string("-thread")])])
        ])),
      Case(
        name: "bindingRevisionZero",
        params: try request([
          "target": .object([
            "targetId": .string(Self.target), "expectedBindingRevision": .integer(0),
          ])
        ])),
      Case(
        name: "bindingRevisionFraction",
        params: try request([
          "target": .object([
            "targetId": .string(Self.target), "expectedBindingRevision": .number(1.5),
          ])
        ])),
      Case(name: "inputsArray", params: try request(["inputs": .array([])])),
      Case(
        name: "requestedOutputsObject",
        params: try request(["requestedOutputs": .object(["derivedArtifacts": .bool(true)])])),
      Case(
        name: "requestedOutputItemNotString",
        params: try request(["requestedOutputs": .array([.integer(7)])])),
      Case(
        name: "requestedOutputItemNull", params: try request(["requestedOutputs": .array([.null])])),
      Case(
        name: "capabilityIdNotString",
        params: try request(["authorization": .object(["capabilityId": .integer(7)])])),
      Case(
        name: "capabilityIdNull",
        params: try request(["authorization": .object(["capabilityId": .null])])),
      Case(
        name: "provenanceNotObject",
        params: try request(["clientContext": .object(["provenance": .string("origin")])])),
      Case(
        name: "provenanceValueNull",
        params: try request([
          "clientContext": .object(["provenance": .object(["origin": .null])])
        ])),
      Case(name: "plannedWithEmptyClientContext", params: try request(["clientContext": .object([:])])),
      Case(name: "plannedWithoutRequestedOutputs", params: try request(["requestedOutputs": .array([])])),
      Case(
        name: "operationVersionZero",
        params: try request([
          "operation": .object([
            "id": .string("analyzer.extract-crash-signature"), "version": .integer(0),
          ])
        ])),
      Case(
        name: "pinnedBindingRevision",
        params: try request([
          "target": .object([
            "targetId": .string(Self.target), "expectedBindingRevision": .integer(3),
          ])
        ])),
      Case(
        name: "malformedLease",
        params: try source(.string("lease-v2:\(Self.sourceJob):\(artifactID)"))),
      Case(
        name: "missingArtifact",
        params: try source(
          .string("lease-v1:\(Self.sourceJob):ART-\(String(repeating: "0", count: 32))"))),
      Case(name: "missingJob", params: try source(.string("lease-v1:job-oracle-absent:\(artifactID)"))),
      Case(name: "malformedLeaseJob", params: try source(.string("lease-v1:job.oracle:\(artifactID)"))),
      Case(
        name: "malformedImportLease",
        params: try source(.string("lease-v1:imp-oracle:\(artifactID)"))),
      Case(
        name: "foreignTarget",
        params: try request(["target": .object(["targetId": .string("TGT-OTHER")])])),
      Case(name: "emptySource", params: try source(.string(emptyLease))),
      Case(name: "unconfiguredAnalyzer", engine: "unconfigured", params: try request()),
      Case(name: "analyzerDrift", mutation: "analyzerDrift", params: try request()),
      Case(name: "payloadTampered", mutation: "payloadTampered", params: try request()),
      Case(name: "payloadMissing", mutation: "payloadMissing", params: try request()),
    ]
  }

  /// Every answer is pre-admission: a plan is never admitted or dispatched,
  /// and a refusal says so.
  private func check(_ response: JSONValue, _ name: String) {
    guard case .object(let fields) = response else { return XCTFail(name) }
    if fields["ok"] == .bool(true) {
      guard case .object(let result)? = fields["result"] else { return XCTFail(name) }
      XCTAssertEqual(result["jobAdmitted"], .bool(false), name)
      XCTAssertEqual(result["dispatchDisposition"], .string("notDispatched"), name)
    } else {
      guard case .object(let error)? = fields["error"] else { return XCTFail(name) }
      XCTAssertEqual(
        error["details"],
        .object(["phase": .string("preAdmission"), "newDispatchCount": .integer(0)]), name)
    }
  }

  /// Applies a named on-disk change and returns what undoes it. The Rust
  /// replay applies the same changes.
  private func mutate(
    _ mutation: String?, analyzer: URL, payload: URL
  ) throws -> () throws -> Void {
    switch mutation {
    case nil:
      return {}
    case "analyzerDrift":
      let handle = try FileHandle(forWritingTo: analyzer)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("\n".utf8))
      try handle.close()
      return {
        let handle = try FileHandle(forWritingTo: analyzer)
        try handle.truncate(atOffset: UInt64(Self.analyzerBytes.count))
        try handle.close()
      }
    case "payloadTampered":
      let original = try Data(contentsOf: payload)
      var tampered = original
      tampered[tampered.startIndex] ^= 0x20
      try overwrite(payload, with: tampered)
      return { try self.overwrite(payload, with: original) }
    case "payloadMissing":
      let moved = payload.appendingPathExtension("moved")
      try FileManager.default.moveItem(at: payload, to: moved)
      return { try FileManager.default.moveItem(at: moved, to: payload) }
    default:
      throw POSIXError(.EINVAL)
    }
  }

  /// Rewrites a sealed payload in place with bytes of the same length,
  /// keeping its mode.
  private func overwrite(_ url: URL, with data: Data) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    guard chmod(url.path, 0o600) == 0 else { throw POSIXError(.EPERM) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: data)
    try handle.close()
    guard chmod(url.path, mode_t(mode)) == 0 else { throw POSIXError(.EPERM) }
  }

  private func publication(_ name: String, _ contents: Data) -> RuntimeArtifactPublicationRequest {
    RuntimeArtifactPublicationRequest(
      jobID: Self.sourceJob, sessionID: "HTASK-JOBPLANORACLE", stepID: "capture-crash-log",
      name: name, mediaType: "text/plain", privacy: .standard, retentionClass: .default,
      sourceOperation: "capture.diagnostics@1", providerID: "hdc",
      bindingSnapshot: ArtifactBindingSnapshot(
        targetID: Self.target, bindingRevision: 3,
        stableIdentitySHA256: String(repeating: "c", count: 64)),
      contents: contents)
  }

  private func handler(
    store: RuntimeArtifactStore, counter: PlanDispatchCounter, state: URL,
    provider: AnalyzerProvider
  ) throws -> RuntimeControlPlaneHandler {
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: state),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: PlanOnlyDispatcher(counter: counter), capabilityStore: capabilities,
      artifactStore: store, nowUTC: { Self.nowUTC })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [provider.providerID],
      nowUTC: { Self.nowUTC }, targetStore: nil, bootstrap: nil, artifactStore: store,
      flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil)
  }

  private func plan(
    _ handler: RuntimeControlPlaneHandler, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("job-plan-oracle"), "method": .string("job.plan"),
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
}
