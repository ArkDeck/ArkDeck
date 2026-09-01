import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// A real arkdeck process talks to the real local daemon transport. Published
/// fixture bytes are host fixtures and are never reported as device evidence.
final class CLIDiagnosticsProcessContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var server: AgentDaemonServer?
  private var handler: RuntimeControlPlaneHandler!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private let now = "2026-09-01T00:00:00Z"

  private enum Failure: Error {
    case fixture
  }

  override func setUpWithError() throws {
    root = URL(
      filePath:
        "/private/tmp/diagnostics-cli-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts"),
      nowUTC: { "2026-09-01T00:00:00Z" })
    capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: dispatcher,
      capabilityStore: capabilities,
      artifactStore: artifacts,
      nowUTC: { "2026-09-01T00:00:00Z" })
    handler = RuntimeControlPlaneHandler(
      engine: engine,
      capabilityStore: capabilities,
      providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" },
      artifactStore: artifacts)
    server = AgentDaemonServer(
      stateDirectory: root.appending(path: "ctl"),
      handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    handler = nil
    engine = nil
    artifacts = nil
    capabilities = nil
    try? FileManager.default.removeItem(at: root)
  }

  func testInspectPreviewAndExportUseExactPublishedArtifacts()
    async throws
  {
    let jobID = "job-diagnostics-cli"
    try seedJob(jobID)
    let hilog = Data("first line\nsecond line\n".utf8)
    let hilogMetadata = try await publish(
      jobID: jobID,
      name: "hilog.txt",
      mediaType: "text/plain",
      bytes: hilog,
      privacy: .sensitive)
    let products: [String: Any] = [
      "hilog.txt": [
        "status": "published",
        "required": true,
        "artifactId": hilogMetadata.artifactID,
        "byteCount": hilogMetadata.byteCount,
        "sha256": hilogMetadata.sha256,
      ]
    ]
    _ = try await publishJSON(
      jobID: jobID,
      name: "artifact-index.json",
      object: [
        "jobId": jobID,
        "operation": "capture.diagnostics@1",
        "artifacts": products,
      ])
    _ = try await publishJSON(
      jobID: jobID,
      name: "capture-summary.json",
      object: [
        "jobId": jobID,
        "operation": "capture.diagnostics@1",
        "artifacts": products,
        "completeness": "complete",
        "missingRequired": [String](),
      ])
    _ = try await publishJSON(
      jobID: jobID,
      name: "markers.json",
      object: [
        "documentType": "arkdeck-diagnostic-markers",
        "schemaVersion": "1.0.0",
        "jobId": jobID,
        "markers": [
          [
            "kind": "manual",
            "atHostUTC": now,
            "label": "stutter",
          ]
        ],
        "notDerived": [[String: String]](),
      ])

    let inspected = try object(
      result(
        cli([
          "diagnostics", "inspect",
          "--job", jobID,
        ])))
    XCTAssertEqual(
      inspected["schemaVersion"],
      .string(
        DiagnosticSessionOfflineInspection.schemaVersion))
    XCTAssertEqual(inspected["partial"], .bool(false))
    let derivation = try object(
      try XCTUnwrap(inspected["derivation"]))
    XCTAssertEqual(
      derivation["parser"],
      .string(DiagnosticSessionOfflineInspector.parserID))
    guard case .array(let sources)? = derivation["sources"] else {
      return XCTFail("inspection did not report source digests")
    }
    XCTAssertEqual(sources.count, 3)

    let refused = try cli([
      "diagnostics", "preview",
      "--job", jobID,
      "--artifact", hilogMetadata.artifactID,
    ])
    XCTAssertEqual(
      try errorCode(refused),
      "sensitiveAccessDenied")
    let preview = try object(
      result(
        cli([
          "diagnostics", "preview",
          "--job", jobID,
          "--artifact", hilogMetadata.artifactID,
          "--max-characters", "5",
          "--allow-sensitive",
        ])))
    XCTAssertEqual(
      preview["schemaVersion"],
      .string(
        DiagnosticArtifactOfflinePreview.schemaVersion))
    XCTAssertEqual(preview["text"], .string("first"))
    XCTAssertEqual(preview["clipped"], .bool(true))

    let destination = root.appending(path: "exports")
    try FileManager.default.createDirectory(
      at: destination,
      withIntermediateDirectories: true)
    let exported = try object(
      result(
        cli([
          "diagnostics", "export",
          "--job", jobID,
          "--artifact", hilogMetadata.artifactID,
          "--destination", destination.path,
          "--allow-sensitive",
        ])))
    let exportedPath = try text(exported["exportedPath"])
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: exportedPath)),
      hilog)

    let trace = Data("immutable trace fixture".utf8)
    let traceMetadata = try await publish(
      jobID: jobID,
      name: "trace.htrace",
      mediaType: "application/octet-stream",
      bytes: trace,
      privacy: .sensitive)
    let traceExported = try object(
      result(
        cli([
          "trace", "export",
          "--job", jobID,
          "--artifact", traceMetadata.artifactID,
          "--destination", destination.path,
          "--allow-sensitive",
        ])))
    let traceExportedPath = try text(traceExported["exportedPath"])
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: traceExportedPath)),
      trace)

    let wrongTraceArtifact = try cli([
      "trace", "export",
      "--job", jobID,
      "--artifact", hilogMetadata.artifactID,
      "--destination", destination.path,
      "--allow-sensitive",
    ])
    XCTAssertEqual(try errorCode(wrongTraceArtifact), "invalidInput")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  private func seedJob(_ jobID: String) throws {
    let request = try RuntimeOperationRequest(
      requestID: "req-\(jobID)",
      idempotencyKey: "idem-\(jobID)",
      target: .init(
        targetID: "TGT-diagnostics",
        expectedBindingRevision: 1),
      operation: .init(
        id: "capture.diagnostics",
        version: 1),
      inputs: [
        "captureHilog": .bool(true),
        "uiDump": .bool(false),
        "traceCategories": .array([]),
      ])
    var record = RuntimeJobRecord(
      jobID: jobID,
      request: request,
      operationReference: "capture.diagnostics@1",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: "hdc",
      createdAtUTC: now,
      actualEffect: "readOnly",
      admissionEvidence: nil,
      materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil,
      materializedBindingRevision: 1)
    record.state = "succeeded"
    _ = try RuntimeJobRepository(
      stateDirectory: root.appending(path: "engine")
    ).admit(
      jobID: jobID,
      idempotencyKey: request.idempotencyKey,
      requestHash: SHA256Hex.string(
        of: CanonicalJSONEncoders.canonical().encode(request)),
      initialState: record.state,
      createdAtUTC: now,
      initialRecordData: record.durableData())
  }

  private func publishJSON(
    jobID: String,
    name: String,
    object: [String: Any]
  ) async throws -> RuntimeArtifactMetadata {
    try await publish(
      jobID: jobID,
      name: name,
      mediaType: "application/json",
      bytes: JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]),
      privacy: .standard)
  }

  private func publish(
    jobID: String,
    name: String,
    mediaType: String,
    bytes: Data,
    privacy: CatalogArtifactPrivacy
  ) async throws -> RuntimeArtifactMetadata {
    try await artifacts.publish(
      .init(
        jobID: jobID,
        sessionID: "session-diagnostics",
        stepID: "fixture-\(name)",
        name: name,
        mediaType: mediaType,
        privacy: privacy,
        retentionClass: .default,
        sourceOperation: "capture.diagnostics@1",
        providerID: "hdc",
        bindingSnapshot: .init(
          targetID: "TGT-diagnostics",
          bindingRevision: 1,
          stableIdentitySHA256: nil),
        contents: bytes))
  }

  private func cli(_ arguments: [String]) throws
    -> (Int32, Data)
  {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent()
      .appending(path: "arkdeck")
    process.arguments =
      arguments
      + [
        "--socket", try XCTUnwrap(server).socketURL.path,
        "--output", "json",
      ]
    let path = root.appending(
      path: "out-\(UUID().uuidString).json")
    FileManager.default.createFile(
      atPath: path.path,
      contents: nil)
    let output = try FileHandle(forWritingTo: path)
    defer {
      try? output.close()
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard !process.isRunning else {
      throw Failure.fixture
    }
    try output.close()
    return (
      process.terminationStatus,
      try Data(contentsOf: path)
    )
  }

  private func result(
    _ response: (Int32, Data)
  ) throws -> JSONValue {
    XCTAssertEqual(
      response.0,
      0,
      String(decoding: response.1, as: UTF8.self))
    return try XCTUnwrap(
      object(CLIStrictJSON.decode(response.1))["result"])
  }

  private func errorCode(
    _ response: (Int32, Data)
  ) throws -> String {
    XCTAssertNotEqual(response.0, 0)
    let envelope = try object(
      CLIStrictJSON.decode(response.1))
    return try text(
      object(try XCTUnwrap(envelope["error"]))["code"])
  }

  private func object(_ value: JSONValue) throws
    -> [String: JSONValue]
  {
    guard case .object(let fields) = value else {
      throw Failure.fixture
    }
    return fields
  }

  private func text(_ value: JSONValue?) throws -> String {
    guard case .string(let text)? = value else {
      throw Failure.fixture
    }
    return text
  }
}
