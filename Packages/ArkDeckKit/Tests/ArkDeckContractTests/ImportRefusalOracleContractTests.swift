@testable import ArkDeckClientKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's answers to the `artifact.import.*` refusals the ControlFrames
/// corpus holds no frame of (TASK-XPA-013), and to the refusals Swift's CLI
/// makes of an upload itself. Each case drives Swift's
/// `RuntimeControlPlaneHandler`, or its CLI against that handler's daemon,
/// into one refusal and asserts the exact code and message. With
/// `ARKDECK_IMPORT_REFUSAL_ORACLE_OUTPUT` set to a new path under
/// `/private/tmp/`, the answers are written there as the oracle the Rust
/// Import owner and CLI replay (`rust/tests/fixtures/import-refusal-oracle`).
/// Runtime identities are recorded by the names the replay substitutes:
/// `$liveImportId`, `$committedImportId`, `$targetId` and `$file`.
/// Host-only fixtures: no device, no dispatch.
final class ImportRefusalOracleContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var targets: RuntimeTargetStore!
  private var target: RuntimeTargetRecord!
  private var engine: RuntimeJobEngine!
  private var handler: RuntimeControlPlaneHandler!
  private var server: AgentDaemonServer?
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private let now = "2026-09-01T00:00:00Z"
  private let hap = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x61, count: 4092)
  private enum OracleError: Error { case missing, unanswered }
  private var wire: [JSONValue] = []
  private var cli: [JSONValue] = []
  private var names: [String: String] = [:]

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "iro-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let key = "150100424a544e4600"
    target = try targets.adopt(stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: key),
      connectKey: key, toolVersion: "3.2.0f", nowUTC: now).record
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(
        factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: .init()))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
    handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
      nowUTC: { "2026-09-01T00:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
    names = [target.targetID: "$targetId"]
  }

  override func tearDownWithError() throws {
    server?.stop(); server = nil; handler = nil; engine = nil; artifacts = nil; targets = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func metadata(_ request: String, bytes: Data? = nil, name: String = "fixture.hap",
    targetID: String? = nil, revision: Int? = nil) throws -> [String: JSONValue] {
    let data = bytes ?? hap
    guard case .object(let fields) = try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(request), "kind": .string("hap"), "targetId": .string(targetID ?? target.targetID),
      "bindingRevision": .string(String(revision ?? target.bindingRevision)), "deviceProfile": .null,
      "name": .string(name), "byteCount": .string(String(data.count)), "sha256": .string(SHA256Hex.string(of: data))]).projection
    else { throw OracleError.missing }
    return fields
  }

  private func chunk(_ id: String, _ data: Data, offset: Int = 0, generation: String = "1") -> [String: JSONValue] {
    ["importId": .string(id), "generation": .string(generation), "offset": .string(String(offset)),
      "byteCount": .string(String(data.count)), "sha256": .string(SHA256Hex.string(of: data)),
      "base64": .string(data.base64EncodedString())]
  }

  private func send(_ method: String, _ params: [String: JSONValue]) async throws -> AgentWireProtocol.Response {
    let request = try ArkDeckAgentXPC.requestFrame(method: method, params: params, requestID: "import-refusal-oracle")
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(request))
  }

  private func result(_ method: String, _ params: [String: JSONValue]) async throws -> ArtifactImportProjection {
    let response = try await send(method, params)
    guard let value = response.result else { throw OracleError.unanswered }
    return try ArtifactImportProjection(value)
  }

  /// A runtime identity, as the name the replay substitutes for it.
  private func named(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text): return .string(names[text] ?? text)
    case .object(let fields): return .object(fields.mapValues(named))
    case .array(let items): return .array(items.map(named))
    default: return value
    }
  }

  private func refusal(
    _ name: String, _ method: String, _ params: [String: JSONValue], code: String, message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let response = try await send(method, params)
    guard let error = response.error else {
      XCTFail("\(name) was not refused", file: file, line: line); throw OracleError.unanswered
    }
    XCTAssertEqual(error.code, code, name, file: file, line: line)
    XCTAssertEqual(error.message, message, name, file: file, line: line)
    wire.append(.object(["case": .string(name), "method": .string(method), "params": named(.object(params)),
      "error": .object(["code": .string(error.code), "message": .string(error.message),
        "details": error.details.map(JSONValue.object) ?? .null])]))
  }

  private func runCLI(_ args: [String]) throws -> (Int32, [String: JSONValue]) {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = args + ["--socket", try XCTUnwrap(server).socketURL.path, "--output", "json"]
    let output = root.appending(path: "out-\(UUID()).json")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    process.standardOutput = handle; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? handle.close() }
    let end = Date().addingTimeInterval(25)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else { throw OracleError.unanswered }
    try handle.close()
    guard case .object(let fields) = try CLIStrictJSON.decode(Data(contentsOf: output)) else { throw OracleError.missing }
    return (process.terminationStatus, fields)
  }

  private func cliRefusal(
    _ name: String, _ args: [String], code: String, message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let (status, output) = try runCLI(args)
    XCTAssertNotEqual(status, 0, name, file: file, line: line)
    guard case .object(let error)? = output["error"] else {
      XCTFail("\(name) printed no error: \(output)", file: file, line: line); throw OracleError.unanswered
    }
    XCTAssertEqual(error["code"], .string(code), name, file: file, line: line)
    XCTAssertEqual(error["message"], .string(message), name, file: file, line: line)
    cli.append(.object(["case": .string(name), "argv": .array(args.map { named(.string($0)) }),
      "exitStatus": .integer(Int64(status)), "error": named(.object(error))]))
  }

  /// A new directory holding one source file, whose path the replay names `$file`.
  private func source(_ name: String, _ data: Data?) throws -> String {
    let directory = root.appending(path: "sources-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appending(path: name)
    if let data { try data.write(to: file) }
    names[file.path] = "$file"
    return file.path
  }

  func testImportRefusalsTheCorpusDoesNotRecord() async throws {
    let upload = RuntimeImportControlFailureText.self
    // An upload with the first half of its bytes, and a committed one.
    let live = try await result("artifact.import.begin", metadata("oracle-live"))
    _ = try await result("artifact.import.append", chunk(live.id, hap.prefix(2048)))
    let staged = try await result("artifact.import.begin", metadata("oracle-committed"))
    _ = try await result("artifact.import.append", chunk(staged.id, hap))
    let committed = try await result("artifact.import.commit", ["importId": .string(staged.id), "generation": .string("1")])
    XCTAssertEqual(committed.state, "committed")
    names[live.id] = "$liveImportId"
    names[committed.id] = "$committedImportId"
    let missing = "imp-00000000-0000-4000-8000-000000000001"
    let other = Data(repeating: 0x62, count: 2048)

    // append: bounds, then identity, then generation, then the owner.
    var fields = chunk(live.id, hap.prefix(2048)); fields["offset"] = .string("x")
    try await refusal("append.bounds.offset", "artifact.import.append", fields, code: "invalidInput", message: upload.appendBounds)
    fields = chunk(live.id, Data()); fields["byteCount"] = .string("0")
    try await refusal("append.bounds.byteCountZero", "artifact.import.append", fields, code: "invalidInput", message: upload.appendBounds)
    fields = chunk(live.id, hap.prefix(2048)); fields["sha256"] = .string(SHA256Hex.string(of: hap.prefix(2048)).uppercased())
    try await refusal("append.bounds.digestNotLowercase", "artifact.import.append", fields, code: "invalidInput", message: upload.appendBounds)
    fields = chunk(live.id, hap.prefix(2048)); fields["byteCount"] = .string("2047")
    try await refusal("append.bounds.byteCountMismatch", "artifact.import.append", fields, code: "invalidInput", message: upload.appendBounds)
    fields = chunk(live.id, hap.prefix(2048)); fields["offset"] = .string("x"); fields["importId"] = .string(""); fields["generation"] = .string("0")
    try await refusal("append.order.boundsFirst", "artifact.import.append", fields, code: "invalidInput", message: upload.appendBounds)
    fields = chunk(live.id, hap.prefix(2048)); fields["importId"] = .string("")
    try await refusal("append.identityRequired.empty", "artifact.import.append", fields, code: "invalidInput", message: upload.identity)
    fields = chunk(live.id, hap.prefix(2048)); fields["importId"] = .integer(7)
    try await refusal("append.identityRequired.notString", "artifact.import.append", fields, code: "invalidInput", message: upload.identity)
    fields = chunk(live.id, hap.prefix(2048)); fields["importId"] = .string(""); fields["generation"] = .string("0")
    try await refusal("append.order.identityBeforeGeneration", "artifact.import.append", fields, code: "invalidInput", message: upload.identity)
    fields = chunk(live.id, hap.prefix(2048)); fields["importId"] = .string("imp-not-a-uuid")
    try await refusal("append.invalidIdentity", "artifact.import.append", fields, code: "invalidInput", message: upload.invalidIdentity)
    try await refusal("append.generationRequired.zero", "artifact.import.append", chunk(live.id, hap.prefix(2048), generation: "0"),
      code: "invalidInput", message: upload.generation)
    try await refusal("append.generationRequired.nonCanonical", "artifact.import.append", chunk(live.id, hap.prefix(2048), generation: "01"),
      code: "invalidInput", message: upload.generation)
    try await refusal("append.generationOrStateChanged", "artifact.import.append", chunk(live.id, hap.prefix(2048), generation: "2"),
      code: "resourceConflict", message: "Import generation or state changed")
    try await refusal("append.overlap", "artifact.import.append", chunk(live.id, other),
      code: "resourceConflict", message: "Import chunk overlaps different committed bytes")

    // abort
    try await refusal("abort.identityRequired.empty", "artifact.import.abort",
      ["importRequestId": .string(""), "generation": .string("1")], code: "invalidInput", message: upload.identity)
    try await refusal("abort.invalidRequestIdentity", "artifact.import.abort",
      ["importRequestId": .string("bad id!"), "generation": .string("1")], code: "invalidInput", message: upload.invalidRequestIdentity)
    try await refusal("abort.generationRequired.zero", "artifact.import.abort",
      ["importRequestId": .string("oracle-live"), "generation": .string("0")], code: "invalidInput", message: upload.generation)
    try await refusal("abort.order.identityBeforeGeneration", "artifact.import.abort",
      ["importRequestId": .string(""), "generation": .string("0")], code: "invalidInput", message: upload.identity)

    // commit: identity, generation, then the identity's format.
    try await refusal("commit.identityRequired.empty", "artifact.import.commit",
      ["importId": .string(""), "generation": .string("1")], code: "invalidInput", message: upload.identity)
    try await refusal("commit.invalidIdentity", "artifact.import.commit",
      ["importId": .string("imp-not-a-uuid"), "generation": .string("1")], code: "invalidInput", message: upload.invalidIdentity)
    try await refusal("commit.generationRequired.zero", "artifact.import.commit",
      ["importId": .string(live.id), "generation": .string("0")], code: "invalidInput", message: upload.generation)
    try await refusal("commit.order.generationBeforeIdentityFormat", "artifact.import.commit",
      ["importId": .string("imp-not-a-uuid"), "generation": .string("0")], code: "invalidInput", message: upload.generation)

    // inspect and inspection
    for method in ["artifact.import.inspect", "artifact.import.inspection"] {
      let verb = method.split(separator: ".").last!
      try await refusal("\(verb).identityRequired.empty", method, ["importId": .string("")],
        code: "invalidInput", message: upload.identity)
      try await refusal("\(verb).invalidIdentity", method, ["importId": .string("imp-not-a-uuid")],
        code: "invalidInput", message: upload.invalidIdentity)
      try await refusal("\(verb).invalidRequestIdentity", method, ["importRequestId": .string("bad id!")],
        code: "invalidInput", message: upload.invalidRequestIdentity)
    }

    // release: identity and generation before the owner, then its holds.
    try await refusal("release.identityRequired.empty", "artifact.import.release",
      ["importId": .string(""), "generation": .string("2")], code: "invalidInput", message: upload.identity)
    try await refusal("release.invalidIdentity", "artifact.import.release",
      ["importId": .string("imp-not-a-uuid"), "generation": .string("2")], code: "invalidInput", message: upload.invalidIdentity)
    try await refusal("release.generationRequired.notDecimal", "artifact.import.release",
      ["importId": .string(committed.id), "generation": .string("x")], code: "invalidInput", message: upload.generation)
    try await refusal("release.generationRequired.zero", "artifact.import.release",
      ["importId": .string(committed.id), "generation": .string("0")], code: "invalidInput", message: upload.generation)
    try await refusal("release.order.generationBeforeLookup", "artifact.import.release",
      ["importId": .string(missing), "generation": .string("x")], code: "invalidInput", message: upload.generation)
    guard case .object(let fieldsOfCommitted) = committed.value, case .object(let receipt)? = fieldsOfCommitted["receipt"],
      case .string(let lease)? = receipt["lease"], let reference = try RuntimeImportLeaseReference(lease)
    else { throw OracleError.missing }
    let hold = try await artifacts.acquireImportInputs([reference])
    try await refusal("release.activeMaterialization", "artifact.import.release",
      ["importId": .string(committed.id), "generation": .string("2")],
      code: "resourceConflict", message: "Import is still used by an active materialization")
    if let hold { await artifacts.endImportUse(hold) }
    let request = try RuntimeOperationRequest(requestID: "oracle-referencing-job", idempotencyKey: "oracle-referencing-job",
      target: .init(targetID: target.targetID, expectedBindingRevision: target.bindingRevision), operation: .init(id: "debug.hap", version: 1),
      inputs: ["hapArtifactLease": .string(lease), "bundleName": .string("com.example.fixture"), "abilityName": .string("EntryAbility")])
    let accepted = try await engine.submit(RuntimeOperationCodec.encodeRequest(request))
    try await refusal("release.activeJob", "artifact.import.release",
      ["importId": .string(committed.id), "generation": .string("2")],
      code: "resourceConflict", message: "Import is still referenced by an active or uncertain Job")
    try await engine.requestCancel(jobID: accepted.jobID)

    // list
    try await refusal("list.optionsClosed", "artifact.import.list", ["limit": .integer(1)],
      code: "invalidInput", message: "Import list options are closed")
    try await refusal("list.invalidCursor.empty", "artifact.import.list", ["cursor": .string("")],
      code: "invalidCursor", message: "invalid Import cursor")
    try await refusal("list.invalidCursor.notString", "artifact.import.list", ["cursor": .integer(7)],
      code: "invalidCursor", message: "invalid Import cursor")

    // begin: the Target binding refusal as the Target owner answers it.
    try await refusal("begin.bindingNotCurrent.revision", "artifact.import.begin",
      metadata("oracle-stale-revision", revision: target.bindingRevision + 1),
      code: "resourceConflict", message: "the exact target binding is no longer current")
    try await refusal("begin.bindingNotCurrent.unknownTarget", "artifact.import.begin",
      metadata("oracle-unknown-target", targetID: "TGT-000000000000"),
      code: "resourceConflict", message: "the exact target binding is no longer current")

    // The CLI's own refusals of an upload.
    let hapArguments = { (request: String, file: String) in
      ["artifact", "import", "hap", "--import-request-id", request, "--target", self.target.targetID, "--file", file]
    }
    try cliRefusal("cli.sourceCannotBeOpened", hapArguments("oracle-cli-missing", try source("fixture.hap", nil)),
      code: "invalidInput", message: "Import source cannot be opened")
    try cliRefusal("cli.sourceOutsideBound", hapArguments("oracle-cli-empty", try source("fixture.hap", Data())),
      code: "invalidInput", message: "Import source exceeds its registered regular-file bound")
    try cliRefusal("cli.metadataOutsideKind", hapArguments("oracle-cli-kind", try source("fixture.txt", hap)),
      code: "invalidInput", message: "Import requires registered metadata and exact target/binding references")
    let changing = try await result("artifact.import.begin", metadata("oracle-cli-changed"))
    _ = try await result("artifact.import.append", chunk(changing.id, hap.prefix(100)))
    var changed = hap; changed[100] = 0xff
    try cliRefusal("cli.sourceChangedForExistingIdentity", hapArguments("oracle-cli-changed", try source("fixture.hap", changed)),
      code: "artifactIntegrityFailed", message: "Import source changed; staged data was not overwritten or aborted")
    _ = try await result("artifact.import.begin", metadata("oracle-cli-renamed"))
    try cliRefusal("cli.identityNamesDifferentMetadata", hapArguments("oracle-cli-renamed", try source("other.hap", hap)),
      code: "idempotencyConflict", message: "Import request identity already names different metadata")

    // Last: a Target store that cannot be read reaches the handler's
    // catch-all. The store is restored afterwards.
    let store = root.appending(path: "targets/targets.json")
    let saved = try Data(contentsOf: store)
    try Data("{".utf8).write(to: store)
    try await refusal("begin.targetStoreUnreadable", "artifact.import.begin", metadata("oracle-unreadable-targets"),
      code: "recordUnreadable", message: "Import state or immutable content is unreadable")
    try saved.write(to: store)

    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let document = try PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.import-refusal-oracle/1"),
      "wire": .array(wire), "cli": .array(cli),
    ]))
    guard let output = ProcessInfo.processInfo.environment["ARKDECK_IMPORT_REFUSAL_ORACLE_OUTPUT"] else {
      // Without the recording variable, Swift's answers are the committed oracle, byte for byte.
      XCTAssertEqual(try Data(contentsOf: Self.oracle), document)
      return
    }
    let destination = URL(fileURLWithPath: output)
    guard destination.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: destination.path) else {
      throw OracleError.missing
    }
    try document.write(to: destination)
  }

  private static let oracle: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appending(path: "rust/tests/fixtures/import-refusal-oracle/cases.json")
  }()
}

/// The Import control handler's own texts, as `RuntimeImportControlHandler`
/// and `RuntimeImportStore` answer them.
private enum RuntimeImportControlFailureText {
  static let appendBounds = "Import append requires exact bounded bytes, offset and digest"
  static let identity = "Import identity is required"
  static let invalidIdentity = "invalid Import identity"
  static let invalidRequestIdentity = "invalid Import request identity"
  static let generation = "exact Import generation is required"
}
