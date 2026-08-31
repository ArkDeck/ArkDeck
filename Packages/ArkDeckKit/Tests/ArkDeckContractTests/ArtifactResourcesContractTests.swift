import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Isolated host fixtures; published fixture content is not device evidence.
final class ArtifactResourcesContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var server: AgentDaemonServer?
  private var handler: RuntimeControlPlaneHandler!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private let now = "2026-09-01T00:00:00Z"
  private enum Failure: Error { case fixture }

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/ar-\(UUID().uuidString.prefix(8))")
    artifacts = try store()
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
    handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, artifactStore: artifacts)
    server = AgentDaemonServer(stateDirectory: root.appending(path: "ctl"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
  }
  override func tearDownWithError() throws {
    server?.stop(); server = nil; handler = nil; engine = nil; artifacts = nil; capabilities = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func store(fault: @escaping RuntimeArtifactExport.Fault = { _ in }) throws -> RuntimeArtifactStore {
    try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), importFault: { _ in }, exportFault: fault, nowUTC: { "2026-09-01T00:00:00Z" })
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let result) = value else { throw Failure.fixture }; return result
  }
  private func text(_ value: JSONValue?) throws -> String {
    guard case .string(let result)? = value else { throw Failure.fixture }; return result
  }
  private func owner(_ kind: String, _ id: String) throws -> ArtifactOwnerReference {
    try .init(.object(["kind": .string(kind), "id": .string(id)]))
  }
  private func seedJob(_ id: String = "job-fixture") throws -> ArtifactOwnerReference {
    let request = try RuntimeOperationRequest(requestID: "req-" + id, idempotencyKey: "idem-" + id,
      target: .init(targetID: "TGT-fixture", expectedBindingRevision: 1), operation: .init(id: "observe.device", version: 1), inputs: [:])
    var record = RuntimeJobRecord(jobID: id, request: request, operationReference: "observe.device@1",
      catalogDigest: RuntimeOperationCatalog.catalogDigest, providerID: "hdc", createdAtUTC: now, actualEffect: "readOnly",
      admissionEvidence: nil, materializedPlanDigest: String(repeating: "a", count: 64),
      materializedStableTargetIdentitySHA256: nil, materializedBindingRevision: 1)
    record.state = "succeeded"
    _ = try RuntimeJobRepository(stateDirectory: root.appending(path: "engine")).admit(jobID: id, idempotencyKey: request.idempotencyKey,
      requestHash: SHA256Hex.string(of: CanonicalJSONEncoders.canonical().encode(request)), initialState: record.state,
      createdAtUTC: now, initialRecordData: record.durableData())
    return try owner("job", id)
  }
  private func publish(_ owner: ArtifactOwnerReference, name: String = "fixture.txt", bytes: Data = Data("fixture-content".utf8), privacy: CatalogArtifactPrivacy = .standard) async throws -> RuntimeArtifactMetadata {
    try await artifacts.publish(.init(jobID: owner.id, sessionID: "fixture-session", stepID: "fixture-step", name: name,
      mediaType: "text/plain", privacy: privacy, retentionClass: .default, sourceOperation: "observe.device@1", providerID: "hdc",
      bindingSnapshot: .init(targetID: "TGT-fixture", bindingRevision: 1, stableIdentitySHA256: nil), contents: bytes))
  }
  private func imported(bytes: Data, kind: String = "hap", name: String = "fixture.hap") async throws -> (ArtifactOwnerReference, String) {
    let intent = try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string("import-\(UUID().uuidString.lowercased())"), "kind": .string(kind), "targetId": .string("TGT-fixture"),
      "bindingRevision": .string("1"), "deviceProfile": .null, "name": .string(name),
      "byteCount": .string(String(bytes.count)), "sha256": .string(SHA256Hex.string(of: bytes))])
    let begun = try ArtifactImportProjection(await artifacts.beginImport(intent,
      binding: .init(targetID: "TGT-fixture", bindingRevision: 1, stableIdentitySHA256: nil)))
    var offset = 0
    while offset < bytes.count {
      let count = min(ArtifactImportIntent.maximumChunkBytes, bytes.count - offset)
      let chunk = bytes.subdata(in: offset..<(offset + count))
      _ = try await artifacts.appendImport(id: begun.id, generation: 1, offset: offset, chunk: chunk, sha256: SHA256Hex.string(of: chunk))
      offset += count
    }
    let committed = try object(await artifacts.commitImport(id: begun.id, generation: 1) { _, record in ["kind": .string(record.intent.kind)] })
    let receipt = try object(XCTUnwrap(committed["receipt"]))
    return (try owner("import", begun.id), try text(receipt["artifactId"]))
  }
  private func cli(_ args: [String], raw: Bool = false) throws -> (Int32, Data) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = args + ["--socket", try XCTUnwrap(server).socketURL.path] + (raw ? ["--raw"] : ["--output", "json"])
    let path = root.appending(path: "out-\(UUID()).json")
    FileManager.default.createFile(atPath: path.path, contents: nil)
    let output = try FileHandle(forWritingTo: path)
    defer { try? output.close(); if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let end = Date().addingTimeInterval(25)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else { throw Failure.fixture }
    try output.close(); return (process.terminationStatus, try Data(contentsOf: path))
  }
  private func result(_ response: (Int32, Data)) throws -> JSONValue {
    XCTAssertEqual(response.0, 0)
    return try XCTUnwrap(object(CLIStrictJSON.decode(response.1))["result"])
  }
  private func code(_ response: (Int32, Data)) throws -> String {
    XCTAssertNotEqual(response.0, 0)
    return try text(object(XCTUnwrap(object(CLIStrictJSON.decode(response.1))["error"]))["code"])
  }
  private func wire(_ method: String, _ fields: [String: JSONValue], version: String = "2.0.0") async throws -> (AgentWireProtocol.Response, Data) {
    let request: JSONValue = .object(["protocolVersion": .string(version), "id": .string("fixture"), "method": .string(method), "params": .object(fields)])
    let reply = try await handler.handleLine(CanonicalJSONEncoders.canonical().encode(request))
    return (try JSONDecoder().decode(AgentWireProtocol.Response.self, from: reply), reply)
  }
  private func exportDirectory() throws -> URL {
    let path = root.appending(path: "exports")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
  }

  func testCLIJobAndImportOwnersAreDistinctAndReleasedInputRemainsReadable() async throws {
    let job = try seedJob(); let product = try await publish(job)
    let metadata = try ArtifactResourceProjection(result(cli(["artifact", "inspect", "--job", job.id, "--artifact", product.artifactID, "--require-protocol", "2"])))
    XCTAssertEqual(metadata.owner, job)
    let bytes = Data([0x50,0x4b,3,4]) + Data("imported-input".utf8)
    let (input, id) = try await imported(bytes: bytes)
    let listed = try result(cli(["artifact", "list", "--import", input.id]))
    try ArtifactResourceProjection.validatePage(listed, owner: input, pageSize: 100)
    let invalid = try cli(["artifact", "inspect", "--job", input.id, "--artifact", id, "--require-protocol", "2"])
    XCTAssertEqual(try code(invalid), "invalidInput")
    _ = try await engine.releaseImport(id: input.id, generation: 2)
    let read = try ArtifactReadProjection(result(cli(["artifact", "read", "--import", input.id, "--artifact", id])))
    XCTAssertEqual(read.bytes, bytes)
    let after = try object(result(cli(["artifact", "inspect", "--import", input.id, "--artifact", id])))
    XCTAssertEqual(after["lease"], .null)
    let exported = try object(result(cli(["artifact", "export", "--import", input.id, "--artifact", id, "--destination", exportDirectory().path])))
    XCTAssertEqual(try Data(contentsOf: URL(filePath: text(exported["exportedPath"]))), bytes)
    let jobs = try await engine.listJobs(); XCTAssertEqual(jobs.count, 1); XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testFourMiBSlashHeavyRangeFitsFrameAndRawUsesIdenticalValidatedBytes() async throws {
    let bytes = Data([0x50,0x4b,3,4]) + Data(repeating: 0xff, count: 4_194_304)
    let (input, id) = try await imported(bytes: bytes)
    let fields: [String: JSONValue] = ["owner": input.value, "artifactId": .string(id), "offset": .integer(4), "maxBytes": .integer(4_194_304)]
    let response = try await wire("artifact.read", fields)
    XCTAssertTrue(response.0.ok); XCTAssertLessThan(response.1.count, 8 * 1024 * 1024)
    let range = try ArtifactReadProjection(XCTUnwrap(response.0.result))
    XCTAssertEqual(range.bytes, bytes.dropFirst(4)); XCTAssertEqual(range.digest, SHA256Hex.string(of: bytes))
    let command = ["artifact", "read", "--import", input.id, "--artifact", id, "--offset", "4", "--max-bytes", "4194304"]
    let raw = try cli(command, raw: true); XCTAssertEqual(raw.0, 0); XCTAssertEqual(raw.1, range.bytes)
    let json = try ArtifactReadProjection(result(cli(command))); XCTAssertEqual(json.bytes, raw.1)
    let eof = try await wire("artifact.read", ["owner": input.value, "artifactId": .string(id), "offset": .integer(Int64(bytes.count))])
    XCTAssertEqual(try ArtifactReadProjection(XCTUnwrap(eof.0.result)).bytes.count, 0)
    for (key,value) in [("maxBytes",JSONValue.integer(0)),("maxBytes",.integer(4_194_305)),("offset",.integer(-1)),("offset",.integer(9_007_199_254_740_992)),("offset",.integer(Int64(bytes.count + 1))),("offset",.string("0"))] {
      var invalid = fields; invalid[key] = value
      let rejected = try await wire("artifact.read", invalid)
      XCTAssertEqual(rejected.0.error?.code, "invalidInput")
    }
    var bad = try object(range.value); bad["base64"] = .string("/w==\n"); XCTAssertThrowsError(try ArtifactReadProjection(.object(bad)))
    bad = try object(range.value); bad["artifactDigest"] = .string("bad"); XCTAssertThrowsError(try ArtifactReadProjection(.object(bad)))
  }

  func testSensitiveReadAndOverwriteBothNeedTheirOwnExplicitPermission() async throws {
    let job = try seedJob(); let bytes = Data("private fixture content".utf8)
    let product = try await publish(job, bytes: bytes, privacy: .sensitive)
    let selector = ["--job",job.id,"--artifact",product.artifactID,"--require-protocol","2"]
    XCTAssertEqual(try code(cli(["artifact","read"] + selector)), "sensitiveAccessDenied")
    let range = try ArtifactReadProjection(result(cli(["artifact","read"] + selector + ["--allow-sensitive"])))
    XCTAssertEqual(range.bytes, bytes)
    let directory = try exportDirectory()
    let command = ["artifact","export"] + selector + ["--destination",directory.path]
    XCTAssertEqual(try code(cli(command)), "sensitiveAccessDenied")
    let first = try object(result(cli(command + ["--allow-sensitive"])))
    let path = URL(filePath: try text(first["exportedPath"]))
    try Data("existing-content".utf8).write(to: path)
    XCTAssertEqual(try code(cli(command + ["--allow-sensitive"])), "resourceConflict")
    XCTAssertEqual(try code(cli(command + ["--overwrite"])), "sensitiveAccessDenied")
    XCTAssertEqual(try Data(contentsOf: path), Data("existing-content".utf8))
    let replaced = try object(result(cli(command + ["--overwrite","--allow-sensitive"])))
    XCTAssertEqual(replaced["overwritten"], .bool(true)); XCTAssertEqual(try Data(contentsOf: path), bytes)
  }

  func testInventorySnapshotRetainsOriginalRowsAcrossPublicationAndRestart() async throws {
    let job = try seedJob()
    _ = try await publish(job, name: "one.txt"); _ = try await publish(job, name: "two.txt")
    let first = try object(await artifacts.artifactInventory(owner: job, pageSize: 1, cursor: nil))
    let cursor = try text(first["nextCursor"])
    _ = try await publish(job, name: "three.txt")
    let reopened = try store()
    let next = try await reopened.artifactInventory(owner: job, pageSize: 1, cursor: cursor)
    try ArtifactResourceProjection.validatePage(next, owner: job, pageSize: 1)
    XCTAssertEqual(try object(next)["hasMore"], .bool(false))
    XCTAssertEqual(try object(next)["snapshotRevision"], first["snapshotRevision"])
    do { _ = try await reopened.artifactInventory(owner: job, pageSize: 2, cursor: cursor); XCTFail("query drift accepted") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
    let another = try seedJob("job-other")
    do { _ = try await reopened.artifactInventory(owner: another, pageSize: 1, cursor: cursor); XCTFail("cross-owner cursor accepted") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "invalidCursor") }
  }

  func testExportRefusesSymlinkHardlinkAndDirectorySubstitutionWithoutTouchingAnotherFile() async throws {
    let job = try seedJob(); let product = try await publish(job)
    let directory = try exportDirectory(); let name = product.artifactID + "-" + product.name
    let target = directory.appending(path: name); let outside = root.appending(path: "unrelated")
    let original = Data("unrelated bytes".utf8); try original.write(to: outside)
    for hardlink in [false, true] {
      if hardlink { try FileManager.default.linkItem(at: outside, to: target) }
      else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
      do { _ = try await artifacts.exportArtifact(owner: job, artifactID: product.artifactID, destinationDirectory: directory, overwrite: true, allowSensitive: false); XCTFail("unsafe destination accepted") }
      catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
      XCTAssertEqual(try Data(contentsOf: outside), original)
      try FileManager.default.removeItem(at: target)
    }
    let substitute = root.appending(path: "substitute"); let retained = root.appending(path: "retained")
    try FileManager.default.createDirectory(at: substitute, withIntermediateDirectories: true)
    let swapped = try store(fault: { point in
      if point == .beforePublication {
        try FileManager.default.moveItem(at: directory, to: retained)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: substitute)
      }
    })
    do { _ = try await swapped.exportArtifact(owner: job, artifactID: product.artifactID, destinationDirectory: directory, overwrite: false, allowSensitive: false); XCTFail("swapped directory accepted") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: substitute.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: retained.path), [], "only our staging inode is cleaned up")
    XCTAssertEqual(try Data(contentsOf: outside), original)
  }

  func testPublicationFaultsDoNotClobberNewDestinationOrHideCompletedExport() async throws {
    let job = try seedJob(); let bytes = Data("verified export".utf8); let product = try await publish(job, bytes: bytes)
    let directory = try exportDirectory(); let target = directory.appending(path: product.artifactID + "-" + product.name)
    let another = Data("concurrent file".utf8)
    let before = try store(fault: { point in if point == .beforePublication { try another.write(to: target) } })
    do { _ = try await before.exportArtifact(owner: job, artifactID: product.artifactID, destinationDirectory: directory, overwrite: true, allowSensitive: false); XCTFail("new destination was overwritten") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
    XCTAssertEqual(try Data(contentsOf: target), another)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [target.lastPathComponent])
    let after = try store(fault: { point in if point == .afterPublication { throw Failure.fixture } })
    do { _ = try await after.exportArtifact(owner: job, artifactID: product.artifactID, destinationDirectory: directory, overwrite: true, allowSensitive: false); XCTFail("publication uncertainty was hidden") }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "outcomeUnknown") }
    XCTAssertEqual(try Data(contentsOf: target), bytes, "published content is never deleted on an uncertain reply")
    let retry = try await artifacts.exportArtifact(owner: job, artifactID: product.artifactID, destinationDirectory: directory, overwrite: true, allowSensitive: false)
    XCTAssertEqual(try object(retry)["overwritten"], .bool(true))
    let metadata = try await artifacts.inspectArtifact(owner: job, artifactID: product.artifactID)
    XCTAssertEqual(try ArtifactResourceProjection(metadata).digest, SHA256Hex.string(of: bytes))
  }

  func testSourceMutationFailsClosedAndLegacyWireKeepsItsOriginalShape() async throws {
    let job = try seedJob(); let bytes = Data("immutable".utf8); let product = try await publish(job, bytes: bytes)
    let legacy = try await wire("artifact.list", ["jobId": .string(job.id)], version: "1.0.0")
    guard case .array(let old)? = legacy.0.result else { return XCTFail("legacy inventory shape changed") }
    XCTAssertEqual(old.count, 1); XCTAssertEqual(try object(old[0])["jobId"], .string(job.id))
    let invalid = try await wire("artifact.list", ["jobId": .string(job.id)])
    XCTAssertEqual(invalid.0.error?.code, "invalidInput")
    let both = try cli(["artifact", "list", "--job", job.id, "--import", "imp-00000000-0000-0000-0000-000000000000"])
    XCTAssertEqual(try code(both), "invalidOption")
    let path = root.appending(path: "artifacts/\(job.id)/\(product.artifactID)")
    XCTAssertEqual(chmod(path.path, 0o600), 0)
    try Data(repeating: 0x78, count: bytes.count).write(to: path)
    let read = try await wire("artifact.read", ["owner": job.value, "artifactId": .string(product.artifactID)])
    XCTAssertEqual(read.0.error?.code, "artifactIntegrityFailed")
    let output = try exportDirectory()
    let exported = try await wire("artifact.export", ["owner": job.value, "artifactId": .string(product.artifactID), "destinationDirectory": .string(output.path)])
    XCTAssertEqual(exported.0.error?.code, "artifactIntegrityFailed")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
  }

  func testCLIReportsUncertainHostPublicationDespiteZeroDeviceDispatch() async throws {
    let job = try seedJob(); let bytes = Data("published before the response".utf8)
    let product = try await publish(job, bytes: bytes)
    let after = try store(fault: { point in if point == .afterPublication { throw Failure.fixture } })
    server?.stop()
    handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, artifactStore: after)
    server = AgentDaemonServer(stateDirectory: root.appending(path: "ctl"), handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
    let directory = try exportDirectory()
    let command = ["artifact", "export", "--job", job.id, "--artifact", product.artifactID,
      "--require-protocol", "2", "--destination", directory.path]
    XCTAssertEqual(try code(cli(command)), "outcomeUnknown")
    XCTAssertEqual(try Data(contentsOf: directory.appending(path: product.artifactID + "-" + product.name)), bytes)
    XCTAssertEqual(try code(cli(command)), "resourceConflict", "a retry still requires explicit overwrite")
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testSIGKILLAroundExportPublicationPreservesOriginalOrCompleteVerifiedFile() async throws {
    for window in ["artifact-export-before", "artifact-export-after"] {
      let directory = root.appending(path: window)
      let child = Process()
      child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckEngineCrashFixture")
      child.arguments = [window, directory.path]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run()
      defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let ready = directory.appending(path: "ready"); let end = Date().addingTimeInterval(15)
      while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < end { usleep(10_000) }
      guard FileManager.default.fileExists(atPath: ready.path) else { XCTFail("missing export crash window"); continue }
      kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
      let reopened = try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
      let owner = try owner("job", "job-export-fixture")
      let inventory = try await reopened.list(jobID: owner.id)
      let item = try XCTUnwrap(inventory.first)
      let exported = directory.appending(path: "exports/\(item.artifactID)-\(item.name)")
      XCTAssertEqual(try Data(contentsOf: exported), Data((window == "artifact-export-before" ? "original destination" : "verified crash fixture").utf8))
      let source = try ArtifactReadProjection(await reopened.readArtifact(owner: owner, artifactID: item.artifactID, offset: 0, maximumBytes: 1024, allowSensitive: false))
      XCTAssertEqual(source.bytes, Data("verified crash fixture".utf8))
      do { _ = try await reopened.exportArtifact(owner: owner, artifactID: item.artifactID, destinationDirectory: exported.deletingLastPathComponent(), overwrite: false, allowSensitive: false); XCTFail("restart silently overwrote an existing destination") }
      catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict") }
    }
  }
}
