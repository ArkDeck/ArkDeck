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

/// Swift's answers to the Import requests its App transport refuses, and to
/// the Import arguments its CLI leaves to the Runtime or refuses itself
/// (TASK-XPA-013, X3–X7), as the oracle the Rust App ingress and CLI replay
/// (`rust/tests/fixtures/import-app-refusal-oracle`).
///
/// - App cases go through `AgentXPCEndpoint.responseFrame`, the frame the
///   App's raw XPC listener sends back: the transport's own refusal of the
///   request, or the Runtime's reply over the owners composed or over a
///   handler composed without the Artifact and Target owners.
/// - CLI cases run Swift's `arkdeck` against that handler's daemon and keep
///   its exit status, machine output and standard error.
///
/// With `ARKDECK_IMPORT_APP_REFUSAL_ORACLE_OUTPUT` set to a new path under
/// `/private/tmp/`, the answers are written there; without it they are
/// compared with the committed oracle byte for byte. Runtime identities are
/// recorded by the names the replay substitutes: `$liveImportId`,
/// `$committedImportId`, `$targetId` and `$file`. Host-only fixtures: no
/// device, no dispatch.
final class ImportAppRefusalOracleContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var targets: RuntimeTargetStore!
  private var target: RuntimeTargetRecord!
  private var engine: RuntimeJobEngine!
  private var handler: RuntimeControlPlaneHandler!
  private var unowned: RuntimeControlPlaneHandler!
  private var server: AgentDaemonServer?
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private let hap = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x61, count: 4092)
  private enum OracleError: Error { case missing, unanswered }
  private var app: [JSONValue] = []
  private var cli: [JSONValue] = []
  private var names: [String: String] = [:]

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "iaro-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let key = "150100424a544e4600"
    target = try targets.adopt(stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: key),
      connectKey: key, toolVersion: "3.2.0f", nowUTC: "2026-09-01T00:00:00Z").record
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: [HDCObservationProviderAdapter(
        factsPort: RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: .init()))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
    handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: ["hdc"],
      nowUTC: { "2026-09-01T00:00:00Z" }, targetStore: targets, artifactStore: artifacts)
    // A daemon composed without the Import owners, as the corpus's
    // "Import owner services are unavailable" frames were recorded.
    unowned = RuntimeControlPlaneHandler(engine: engine,
      capabilityStore: try RuntimeCapabilityStore(directoryURL: root.appending(path: "unowned-capabilities")),
      providerIDs: [], nowUTC: { "2026-09-01T00:00:00Z" })
    server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
    names = [target.targetID: "$targetId"]
  }

  override func tearDownWithError() throws {
    server?.stop(); server = nil; handler = nil; unowned = nil; engine = nil; artifacts = nil; targets = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func metadata(_ request: String, kind: String = "hap", name: String = "fixture.hap") throws -> [String: JSONValue] {
    guard case .object(let fields) = try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(request), "kind": .string(kind), "targetId": .string(target.targetID),
      "bindingRevision": .string(String(target.bindingRevision)), "deviceProfile": .null,
      "name": .string(name), "byteCount": .string(String(hap.count)), "sha256": .string(SHA256Hex.string(of: hap))]).projection
    else { throw OracleError.missing }
    return fields
  }

  private func chunk(_ id: String, _ data: Data, offset: Int = 0) -> [String: JSONValue] {
    ["importId": .string(id), "generation": .string("1"), "offset": .string(String(offset)),
      "byteCount": .string(String(data.count)), "sha256": .string(SHA256Hex.string(of: data)),
      "base64": .string(data.base64EncodedString())]
  }

  private func local(_ method: String, _ params: [String: JSONValue]) async throws -> ArtifactImportProjection {
    let request = try ArkDeckAgentXPC.requestFrame(method: method, params: params, requestID: "import-app-oracle")
    let response = try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(request))
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

  /// One frame through the App's transport, as the App sends it, and the
  /// frame the App receives back: the listener's `responseFrame`, which is
  /// the Runtime's reply or the transport's own refusal of the request.
  private func appCase(
    _ name: String, _ method: String, _ params: [String: JSONValue], owners: Bool
  ) async throws {
    let endpoint = AgentXPCEndpoint(handler: owners ? handler : unowned, appJobs: AgentXPCAppJobGate())
    let frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params, requestID: "import-app-oracle")
    var bytes = await endpoint.responseFrame(frame)
    if bytes.last == 10 { bytes.removeLast() }
    guard case .object(var received) = try CLIStrictJSON.decode(bytes) else { throw OracleError.unanswered }
    // A successful reply's result is not an answer to compare.
    if received["ok"] == .bool(true) { received["result"] = .string("$result") }
    app.append(.object(["case": .string(name), "method": .string(method), "params": named(.object(params)),
      "owners": .bool(owners), "received": named(.object(received))]))
  }

  private func cliCase(_ name: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = args + ["--socket", try XCTUnwrap(server).socketURL.path, "--output", "json"]
    let output = root.appending(path: "out-\(UUID()).json")
    let errors = root.appending(path: "err-\(UUID()).txt")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    FileManager.default.createFile(atPath: errors.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: output)
    let errHandle = try FileHandle(forWritingTo: errors)
    process.standardOutput = outHandle; process.standardError = errHandle
    try process.run()
    defer {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      try? outHandle.close(); try? errHandle.close()
    }
    let end = Date().addingTimeInterval(25)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else { throw OracleError.unanswered }
    try outHandle.close(); try errHandle.close()
    let stdout = try Data(contentsOf: output)
    let printed: JSONValue = stdout.isEmpty ? .null
      : (try? CLIStrictJSON.decode(stdout)) ?? .string(String(decoding: stdout, as: UTF8.self))
    // The machine output's per-run identity is not an answer.
    var answer = printed
    if case .object(var fields) = printed, case .object(var meta)? = fields["meta"] {
      meta["controlRequestId"] = .string("$controlRequestId")
      fields["meta"] = .object(meta); answer = .object(fields)
    }
    cli.append(.object(["case": .string(name), "argv": .array(args.map { named(.string($0)) }),
      "exitStatus": .integer(Int64(process.terminationStatus)), "stdout": named(answer),
      "stderr": .string(String(decoding: try Data(contentsOf: errors), as: UTF8.self))]))
  }

  /// A new directory holding one source file, whose path the replay names `$file`.
  private func source(_ name: String, _ data: Data) throws -> String {
    let directory = root.appending(path: "sources-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appending(path: name)
    try data.write(to: file)
    names[file.path] = "$file"
    return file.path
  }

  func testImportRefusalsOfTheAppTransportAndTheCLI() async throws {
    // An upload with the first half of its bytes, and a committed one.
    let live = try await local("artifact.import.begin", metadata("oracle-live"))
    _ = try await local("artifact.import.append", chunk(live.id, hap.prefix(2048)))
    let staged = try await local("artifact.import.begin", metadata("oracle-committed"))
    _ = try await local("artifact.import.append", chunk(staged.id, hap))
    let committed = try await local("artifact.import.commit", ["importId": .string(staged.id), "generation": .string("1")])
    XCTAssertEqual(committed.state, "committed")
    names[live.id] = "$liveImportId"
    names[committed.id] = "$committedImportId"
    let missing = "imp-00000000-0000-4000-8000-000000000001"

    // X3: the Import methods the App does not send, and begins outside its uploads.
    try await appCase("app.list", "artifact.import.list", [:], owners: true)
    try await appCase("app.inspect", "artifact.import.inspect", ["importId": .string(live.id)], owners: true)
    try await appCase("app.inspection", "artifact.import.inspection", ["importId": .string(live.id)], owners: true)
    try await appCase("app.release", "artifact.import.release",
      ["importId": .string(committed.id), "generation": .string("2")], owners: true)
    try await appCase("app.begin.otherKind", "artifact.import.begin",
      metadata("oracle-app-patch", kind: "workspace-patch", name: "fixture.patch"), owners: true)
    try await appCase("app.begin.invalidMetadata", "artifact.import.begin",
      metadata("oracle-app-name", name: "fixture.hsp").merging(["name": .string("fixture.txt")]) { $1 }, owners: true)
    // X5, for reference: an Import this Runtime never began.
    try await appCase("app.append.missingImport", "artifact.import.append", chunk(missing, hap.prefix(2048)), owners: true)
    // X4: the App's uploads on a daemon composed without the Import owners.
    try await appCase("app.begin.withoutOwners", "artifact.import.begin", metadata("oracle-app-unowned"), owners: false)
    try await appCase("app.append.withoutOwners", "artifact.import.append", chunk(live.id, hap.prefix(2048)), owners: false)
    try await appCase("app.abort.withoutOwners", "artifact.import.abort",
      ["importRequestId": .string("oracle-live"), "generation": .string("1")], owners: false)
    try await appCase("app.commit.withoutOwners", "artifact.import.commit",
      ["importId": .string(live.id), "generation": .string("1")], owners: false)

    // X6: arguments Swift's CLI leaves to the Runtime.
    try cliCase("cli.inspect.noSelector", ["artifact", "import", "inspect"])
    try cliCase("cli.inspect.bothSelectors",
      ["artifact", "import", "inspect", "--import", live.id, "--import-request-id", "oracle-live"])
    try cliCase("cli.list.targetInvalid", ["artifact", "import", "list", "--target", "../target"])
    try cliCase("cli.list.cursorEmpty", ["artifact", "import", "list", "--cursor", ""])
    // X7: a native library whose file name is no lib*.so.
    try cliCase("cli.nativeLibrary.unsafeName", ["artifact", "import", "native-library",
      "--import-request-id", "oracle-cli-native", "--target", target.targetID,
      "--file", try source("fixture.bin", Data(repeating: 0x7f, count: 64))])

    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let document = try PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.import-app-refusal-oracle/1"),
      "app": .array(app), "cli": .array(cli),
    ]))
    guard let output = ProcessInfo.processInfo.environment["ARKDECK_IMPORT_APP_REFUSAL_ORACLE_OUTPUT"] else {
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
    return url.appending(path: "rust/tests/fixtures/import-app-refusal-oracle/cases.json")
  }()
}
