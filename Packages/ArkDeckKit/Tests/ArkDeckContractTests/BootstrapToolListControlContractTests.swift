import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckBootstrap
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Fresh private host fixtures are retained. No helper is selected or executed.
final class BootstrapToolListControlContractTests: XCTestCase {
  private var root: URL!
  private var registryRoot: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-list-rpc-\(UUID().uuidString.lowercased())")
    registryRoot = root.appending(path: "bootstrap")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  private static func owner(_ root: URL) -> BootstrapToolRegistry {
    BootstrapToolRegistry(owner: BootstrapBundleRegistry(root: root))
  }
  private static func page(_ directory: URL, _ size: Int, _ cursor: String?) throws -> JSONValue {
    let owner = Self.owner(directory)
    let inventory = try BootstrapDevEcoToolchainRegistry(owner: owner.sharedOwner).combinedInventory(with: owner)
    let items = try inventory.values.sorted { left, right in
      guard case .object(let a) = left, case .string(let ar)? = a["toolRef"],
        case .object(let b) = right, case .string(let br)? = b["toolRef"]
      else { throw AgentExecutionControlFailure("recordUnreadable", "tool inventory has no reference") }
      return ar < br
    }
    return try RuntimeSnapshotPager(directory: inventory.snapshotDirectory).page(method: "runtime.tool.list",
      filters: [:], order: "toolRef:asc", pageSize: size, cursor: cursor, items: { items })
  }
  private func wire(_ fields: [String: JSONValue], configured: Bool = true,
    record: Bool = true) async throws -> AgentWireProtocol.Response {
    let directory = registryRoot!
    let list: (@Sendable (Int, String?) async throws -> JSONValue)? = configured ? { @Sendable size, cursor in
      try Self.page(directory, size, cursor)
    } : nil
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-11T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapToolLister: list,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("tool-list-fixture"), "method": .string("runtime.tool.list"),
      "params": .object(fields),
    ])
    return try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(
      try CanonicalJSONEncoders.canonical().encode(request)))
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let result) = value else { throw AgentExecutionControlFailure("fixture", "expected object") }
    return result
  }
  private func failure(_ value: AgentWireProtocol.Response, _ code: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value.ok, file: file, line: line)
    XCTAssertNil(value.result, file: file, line: line)
    XCTAssertEqual(value.error?.code, code, file: file, line: line)
    XCTAssertEqual(value.error?.details?["phase"], .string("bootstrapRegistryOwner"), file: file, line: line)
    XCTAssertEqual(value.error?.details?["newDispatchCount"], .integer(0), file: file, line: line)
    XCTAssertEqual(dispatcher.dispatchCount, 0, file: file, line: line)
  }

  func testStructuralRefusalsPrecedeOwnerAccessAndUnavailableIsExplicit() async throws {
    for fields: [String: JSONValue] in [["pageSize": .null], ["pageSize": .number(1.5)],
      ["cursor": .integer(1)], ["path": .string("/private/tmp/forbidden")]] {
      failure(try await wire(fields, configured: false, record: false), "invalidParams")
    }
    failure(try await wire([:], configured: false), "operationUnavailable")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.path))
  }

  func testEmptyDefaultPageAndBoundedInputFailuresAreActualOwnerResults() async throws {
    let response = try await wire([:])
    let page = try object(XCTUnwrap(response.result))
    XCTAssertEqual(page["schemaVersion"], .string("arkdeck.cli.page/1"))
    XCTAssertEqual(page["pageKind"], .string("snapshot"))
    XCTAssertEqual(page["items"], .array([]))
    XCTAssertEqual(page["order"], .string("toolRef:asc"))
    XCTAssertEqual(page["hasMore"], .bool(false))
    XCTAssertEqual(page["nextCursor"], .null)
    let indexes = try Data(contentsOf: registryRoot.appending(path: "bundles.json"))
    for size: Int64 in [-1, 0, 1001] {
      failure(try await wire(["pageSize": .integer(size)]), "invalidInput")
    }
    failure(try await wire(["pageSize": .integer(1), "cursor": .string("invalid")]), "invalidCursor")
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "bundles.json")), indexes)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testInventoryAndLockFailuresPrecedePageAndCursorValidation() async throws {
    let response = try await wire([:])
    XCTAssertTrue(response.ok)
    let lock = open(registryRoot.appending(path: ".lock").path, O_RDWR | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(lock, 0)
    defer { close(lock) }
    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
    failure(try await wire(["pageSize": .integer(0), "cursor": .string("invalid")]), "resourceConflict")
    XCTAssertEqual(flock(lock, LOCK_UN), 0)
    let index = registryRoot.appending(path: "bundles.json")
    try Data("{corrupt fixture".utf8).write(to: index)
    let before = try Data(contentsOf: index)
    failure(try await wire(["pageSize": .integer(0), "cursor": .string("invalid")]), "recordUnreadable")
    XCTAssertEqual(try Data(contentsOf: index), before)
  }

  func testNativeContentCorruptionPrecedesCursorValidation() async throws {
    let owner = Self.owner(registryRoot)
    let registered = try object(owner.register(file: URL(filePath: "/usr/bin/true")))
    guard case .string(let digest)? = registered["contentDigest"] else { return XCTFail("digest") }
    let source = registryRoot.appending(path: "tool-\(digest).hdc/hdc")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    try Data("corrupt native content".utf8).write(to: source)
    failure(try await wire(["pageSize": .integer(1), "cursor": .string("invalid")]), "recordUnreadable")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.appending(path: "tool-snapshots").path))
  }

  private func recordPages() async throws -> [JSONValue] {
    var pages: [JSONValue] = []
    var cursor: String?
    repeat {
      var fields: [String: JSONValue] = ["pageSize": .integer(1)]
      if let cursor { fields["cursor"] = .string(cursor) }
      let response = try await wire(fields)
      XCTAssertTrue(response.ok, "\(String(describing: response.error))")
      let page = try XCTUnwrap(response.result)
      let values = try object(page)
      pages.append(page)
      cursor = { if case .string(let value)? = values["nextCursor"] { return value }; return nil }()
    } while cursor != nil
    return pages
  }

  func testActualNativeToolsPageAcrossReopenedOwnersAndExpiredCursor() async throws {
    let owner = Self.owner(registryRoot)
    _ = try owner.register(file: URL(filePath: "/usr/bin/true"))
    _ = try owner.register(file: URL(filePath: "/usr/bin/false"))
    let before = try Data(contentsOf: registryRoot.appending(path: "tools.json"))
    let pages = try await recordPages()
    XCTAssertEqual(pages.count, 2)
    let first = try object(pages[0]), second = try object(pages[1])
    XCTAssertEqual(first["snapshotRevision"], second["snapshotRevision"])
    guard case .string(let cursor)? = first["nextCursor"],
      case .string(let revision)? = first["snapshotRevision"] else { return XCTFail("cursor") }
    let repeatResponse = try await wire(["pageSize": .integer(1), "cursor": .string(cursor)])
    XCTAssertEqual(repeatResponse.result, pages[1])
    failure(try await wire(["pageSize": .integer(2), "cursor": .string(cursor)]), "invalidCursor")
    let snapshot = registryRoot.appending(path: "tool-snapshots/snapshot-\(revision).json")
    // Expiration means the bounded snapshot has been reclaimed, not a TTL.
    try FileManager.default.removeItem(at: snapshot)
    failure(try await wire(["pageSize": .integer(1), "cursor": .string(cursor)]), "invalidCursor")
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "tools.json")), before)
  }

  func testExplicitNativeFamiliesProduceCombinedPages() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["ARKDECK_TOOL_LIST_DEVECO_SOURCE"],
      let output = env["ARKDECK_TOOL_LIST_OUTPUT_ROOT"] else {
      throw XCTSkip("requires actual DevEco source and a fresh temporary registry")
    }
    guard output.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: output),
      !output.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw AgentExecutionControlFailure("fixture", "fresh temporary output required")
    }
    registryRoot = URL(filePath: output)
    let owner = Self.owner(registryRoot)
    let a = try object(owner.register(file: URL(filePath: "/usr/bin/true")))
    _ = try owner.register(file: URL(filePath: "/usr/bin/false"))
    guard case .string(let reference)? = a["toolRef"] else { return XCTFail("reference") }
    _ = try owner.remove(reference, expectedGeneration: "1")
    _ = try BootstrapDevEcoToolchainRegistry(owner: owner.sharedOwner).register(root: URL(filePath: source))
    let pages = try await recordPages()
    XCTAssertEqual(pages.count, 3)
    let allResponse = try await wire([:])
    let all = try XCTUnwrap(allResponse.result)
    let receipt: JSONValue = .object(["pages": .array(pages), "all": all])
    let path = root.appending(path: "actual-native-tool-list.json")
    try CanonicalJSONEncoders.canonical().encode(receipt).write(to: path)
    print("nativeToolListRegistry=\(registryRoot.path)")
    print("nativeToolListReceipt=\(path.path)")
  }

  func testExplicitRustPagesReadBackWithoutRegistryWrites() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["ARKDECK_TOOL_LIST_RUST_ROOT"],
      let receipt = env["ARKDECK_TOOL_LIST_RUST_RECEIPT"] else {
      throw XCTSkip("requires actual retained Rust pages and a temporary registry")
    }
    guard directory.hasPrefix("/private/tmp/"), receipt.hasPrefix("/private/tmp/") else {
      throw AgentExecutionControlFailure("fixture", "temporary producer inputs required")
    }
    registryRoot = URL(filePath: directory)
    let files = ["tools.json", "bundles.json", "deveco-toolchains.json"]
    let before = try files.map { try Data(contentsOf: registryRoot.appending(path: $0)) }
    let producer = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: receipt)))
    guard case .array(let pages)? = try object(producer)["pages"] else { return XCTFail("pages") }
    for index in 1..<pages.count {
      guard case .string(let cursor)? = try object(pages[index-1])["nextCursor"] else { return XCTFail("cursor") }
      let response = try await wire(["pageSize": .integer(1), "cursor": .string(cursor)])
      XCTAssertEqual(response.result, pages[index])
    }
    XCTAssertEqual(try files.map { try Data(contentsOf: registryRoot.appending(path: $0)) }, before)
  }
}
