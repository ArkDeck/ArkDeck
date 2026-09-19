import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// `TASK-XPA-014`: the HDC lifecycle and control-action methods as the
/// production daemon answers them when it composes no managed HDC server.
/// `ArkDeckAgentDaemonMain` then has no HDC control-action owner and no
/// tool-selection owner, and builds the union control-action owner over
/// neither, backed by `<state>/control-action-snapshots`. The isolated Rust
/// daemon composes no HDC server either, so these are the answers its routes
/// must give. A run with `ARKDECK_CONTROL_FRAME_LOG` set records them for the
/// method schemas.
final class ControlActionNoHostContractTests: XCTestCase {
  private static let order = "createdAtThenControlActionId"
  private static let actionID = "control-action-5f0c1a52-0b4e-4c8a-9d2e-2b7f3c6a9e10"
  private static let identityRequired = "an exact control-action identity is required"
  private static let unsupportedFilter = "unsupported control-action discovery filter"
  private static let staleCursor =
    "cursor is invalid, belongs to another query or its snapshot was reclaimed"
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/control-action-no-host-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private struct Daemon {
    let handler: RuntimeControlPlaneHandler
    let dispatcher: RuntimeAgentExecutionContractTests.Dispatcher
    let engine: RuntimeJobEngine
    let snapshots: URL

    /// One request frame through the handler's line entry, as a socket
    /// client's frame reaches it.
    func send(
      _ method: String, _ params: [String: JSONValue]
    ) async throws -> AgentWireProtocol.Response {
      let frame = try PortableCanonicalJSON.canonicalBytes(.object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("no-host-" + UUID().uuidString.lowercased()),
        "method": .string(method), "params": .object(params),
      ]))
      return try JSONDecoder().decode(
        AgentWireProtocol.Response.self, from: await handler.handleLine(frame))
    }

    func snapshotFiles() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: snapshots.path).sorted()
    }
  }

  /// What `ArkDeckAgentDaemonMain` composes when no HDC server host started:
  /// `hdcControlActions` and `toolSelectionActions` are nil, and the union
  /// owner has neither an HDC nor a tool-selection owner.
  private func daemon() throws -> Daemon {
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-19T00:00:00Z" })
    let snapshots = root.appending(path: "state/control-action-snapshots")
    let controls = try RuntimeControlActionResourceCoordinator(
      directory: snapshots, hdc: nil, tools: nil)
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-19T00:00:00Z" }, hdcControlActions: nil,
      toolSelectionActions: nil, controlActions: controls)
    return Daemon(
      handler: handler, dispatcher: dispatcher, engine: engine, snapshots: snapshots)
  }

  /// Every refusal of these routes carries exactly `newDispatchCount: 0`.
  private func assertRefused(
    _ response: AgentWireProtocol.Response, _ code: String, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(response.ok, file: file, line: line)
    XCTAssertNil(response.result, file: file, line: line)
    XCTAssertEqual(response.error?.code, code, file: file, line: line)
    XCTAssertEqual(response.error?.message, message, file: file, line: line)
    XCTAssertEqual(
      response.error?.details, ["newDispatchCount": .integer(0)], file: file, line: line)
  }

  func testLifecycleMethodsAreUnavailableAndNoControlActionExists() async throws {
    let daemon = try daemon()
    let unavailable = "the Runtime HDC control-action owner is unavailable"
    // The owner check comes before any parameter is read, so an empty request
    // and a well-formed one get the same answer.
    let endpoint = "hdc-endpoint:" + SHA256Hex.string(of: Data("127.0.0.1:8710".utf8))
    for params: [String: JSONValue] in [
      [:],
      [
        "action": .string("restart"), "actionRequestId": .string("cli-action"),
        "serverEndpointRef": .string(endpoint),
        "expectedServerGeneration": .string("100000023"),
      ],
    ] {
      assertRefused(
        try await daemon.send("runtime.hdc.impact-preview", params),
        "operationUnavailable", unavailable)
    }
    for params: [String: JSONValue] in [
      [:],
      [
        "controlAction": .string(Self.actionID),
        "previewId": .string("preview-9a4d2c1e-6b3f-4e8a-8c7d-1f2e3d4c5b6a"),
        "previewDigest": .string(String(repeating: "d", count: 64)),
      ],
    ] {
      assertRefused(
        try await daemon.send("runtime.hdc.restart", params), "operationUnavailable", unavailable)
    }
    // The union owner exists but owns no action, so an exact identity is
    // looked up and not found; a malformed one is refused before the lookup.
    for method in ["control-action.show", "control-action.reconcile"] {
      assertRefused(
        try await daemon.send(method, ["controlAction": .string(Self.actionID)]),
        "resourceNotFound", "control action does not exist")
      assertRefused(
        try await daemon.send(method, ["controlAction": .string("control action/1")]),
        "invalidInput", Self.identityRequired)
    }
    // An extra key, the one the committed corpus already refuses.
    assertRefused(
      try await daemon.send(
        "control-action.show",
        ["controlAction": .string(Self.actionID), "executable": .string("/usr/bin/false")]),
      "invalidInput", Self.identityRequired)
    XCTAssertEqual(daemon.dispatcher.dispatchCount, 0)
    let jobs = try await daemon.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(try daemon.snapshotFiles(), [])
  }

  func testListPublishesAnEmptySnapshotPageAndRefusesInvalidFiltersAndCursors() async throws {
    let daemon = try daemon()
    // The owner creates its private snapshot directory when it is composed.
    var status = stat()
    XCTAssertEqual(lstat(daemon.snapshots.path, &status), 0)
    XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
    XCTAssertEqual(status.st_mode & 0o777, 0o700)
    XCTAssertEqual(try daemon.snapshotFiles(), [])

    // (request, the filters it names, the page size it resolves to)
    let hdc: [String: JSONValue] = ["kind": .string("hdcLifecycle")]
    let awaiting: [String: JSONValue] = ["state": .string("awaitingImpactApproval")]
    let toolsSucceeded: [String: JSONValue] = [
      "kind": .string("runtimeToolSelection"), "state": .string("succeeded"),
    ]
    let pages: [([String: JSONValue], [String: JSONValue], Int64)] = [
      ([:], [:], 100),
      (["pageSize": .integer(1000)], [:], 1000),
      (hdc, hdc, 100),
      (awaiting, awaiting, 100),
      (toolsSucceeded.merging(["pageSize": .integer(1)]) { old, _ in old }, toolsSucceeded, 1),
    ]
    var published: [String] = []
    for (params, filters, pageSize) in pages {
      let response = try await daemon.send("control-action.list", params)
      XCTAssertTrue(response.ok, "\(params)")
      XCTAssertNil(response.error, "\(params)")
      guard case .object(let page)? = response.result,
        case .string(let revision)? = page["snapshotRevision"]
      else { return XCTFail("\(params) answered no snapshot page") }
      XCTAssertEqual(
        response.result,
        .object([
          "schemaVersion": .string("arkdeck.cli.page/1"), "pageKind": .string("snapshot"),
          "items": .array([]), "order": .string(Self.order),
          "snapshotRevision": .string(revision), "hasMore": .bool(false), "nextCursor": .null,
        ]), "\(params)")
      XCTAssertEqual(UUID(uuidString: revision)?.uuidString.lowercased(), revision)

      // Each page is one new private snapshot of one empty page, named by its
      // revision and bound to the query's filters and page size.
      published.append("snapshot-\(revision).json")
      XCTAssertEqual(try daemon.snapshotFiles(), published.sorted(), "\(params)")
      let file = daemon.snapshots.appending(path: "snapshot-\(revision).json")
      XCTAssertEqual(lstat(file.path, &status), 0)
      XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(status.st_mode & 0o777, 0o600)
      let snapshot = try JSONDecoder().decode(
        [String: JSONValue].self, from: Data(contentsOf: file))
      guard case .array(let tokens)? = snapshot["tokens"], tokens.count == 1,
        case .string(let token) = tokens[0]
      else { return XCTFail("\(params) stored no single page token") }
      XCTAssertTrue(token.hasPrefix(revision + "."), token)
      let query = try PortableCanonicalJSON.canonicalBytes(.object([
        "method": .string("control-action.list"), "filters": .object(filters),
        "order": .string(Self.order), "pageSize": .integer(pageSize),
      ]))
      XCTAssertEqual(
        snapshot,
        [
          "schemaVersion": .string("arkdeck.runtime-snapshot/1"), "revision": .string(revision),
          "queryDigest": .string(SHA256Hex.string(of: query)), "order": .string(Self.order),
          "tokens": .array([.string(token)]), "pages": .array([.array([])]),
        ], "\(params)")
    }

    // A refused list reads no page and publishes no snapshot.
    let firstRevision = String(published[0].dropFirst("snapshot-".count).dropLast(".json".count))
    let pageToken = "\(firstRevision).00000000-0000-4000-8000-000000000000"
    let refusals: [([String: JSONValue], String, String)] = [
      (["kind": .string("adbLifecycle")], "invalidInput", Self.unsupportedFilter),
      (["state": .string("running")], "invalidInput", Self.unsupportedFilter),
      (["pageSize": .integer(0)], "invalidInput", "invalid page size"),
      (["cursor": .string("not-a-cursor")], "invalidCursor", Self.staleCursor),
      // The first query's snapshot, but a page token it never issued.
      (["cursor": .string(pageToken)], "invalidCursor", Self.staleCursor),
      // Longer than the 256 bytes the handler reads.
      (
        ["cursor": .string(String(repeating: "c", count: 257))], "invalidCursor",
        "invalid control-action cursor"
      ),
    ]
    for (params, code, message) in refusals {
      assertRefused(try await daemon.send("control-action.list", params), code, message)
      XCTAssertEqual(try daemon.snapshotFiles(), published.sorted(), "\(params)")
    }
    XCTAssertEqual(daemon.dispatcher.dispatchCount, 0)
    let jobs = try await daemon.engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }
}
