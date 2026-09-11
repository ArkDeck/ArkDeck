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
final class BootstrapBundleListControlContractTests: XCTestCase {
  private var root: URL!
  private var registryRoot: URL!
  private var engine: RuntimeJobEngine!
  private var capabilities: RuntimeCapabilityStore!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/bundle-list-rpc-\(UUID().uuidString.lowercased())")
    registryRoot = root.appending(path: "bootstrap")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-11T00:00:00Z" })
  }

  private static func owner(_ root: URL) -> BootstrapBundleRegistry {
    BootstrapBundleRegistry(root: root, validateBundle: { candidate in
      do { _ = try LaunchAgentService.validateProductionDaemonBundle(candidate, fileManager: .default) }
      catch { throw AgentExecutionControlFailure("admissionDenied", "bundle failed native helper trust") }
    })
  }
  private func wire(_ fields: [String: JSONValue], configured: Bool = true,
    record: Bool = true) async throws -> AgentWireProtocol.Response {
    let directory = registryRoot!
    let list: (@Sendable (Int, String?) async throws -> JSONValue)? = configured ? { @Sendable size, cursor in
      try Self.owner(directory).list { snapshots, items in
        try RuntimeSnapshotPager(directory: snapshots).page(method: "runtime.bundle.list", filters: [:],
          order: "bundleRef:asc", pageSize: size, cursor: cursor, items: { items })
      }
    } : nil
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities,
      providerIDs: [], nowUTC: { "2026-09-11T00:00:00Z" }, targetStore: nil, bootstrap: nil,
      bootstrapBundleLister: list,
      artifactStore: nil, flashBundleImportDirectory: nil, flashBundleImportPolicy: .production,
      methodObserver: nil, frameObserver: record ? nil : { @Sendable _ in })
    let request: JSONValue = .object([
      "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "id": .string("bundle-list-fixture"), "method": .string("runtime.bundle.list"),
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
    XCTAssertEqual(page["order"], .string("bundleRef:asc"))
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

  func testNativeRejectionPrecedesInvalidCursorAndNeverPublishesPage() async throws {
    let source = root.appending(path: "UnsignedFixture.app")
    try FileManager.default.createDirectory(at: source.appending(path: "Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "fixture-1"],
      format: .xml, options: 0).write(to: source.appending(path: "Contents/Info.plist"))
    try Data("negative fixture".utf8).write(to: source.appending(path: "Contents/payload"))
    // This only seeds adversarial bytes. The actual handler uses production
    // trust, and only its native refusal is a producer recording.
    _ = try BootstrapBundleRegistry(root: registryRoot, validateBundle: { _ in }).register(file: source)
    failure(try await wire(["pageSize": .integer(1), "cursor": .string("invalid")]), "admissionDenied")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryRoot.appending(path: "bundle-snapshots").path))
  }

  func testActualNativeBundlesRetainCrossProcessPages() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let firstSource = env["ARKDECK_BUNDLE_LIST_SOURCE_A"],
      let secondSource = env["ARKDECK_BUNDLE_LIST_SOURCE_B"],
      let output = env["ARKDECK_BUNDLE_LIST_OUTPUT_ROOT"] else {
      throw XCTSkip("requires two actual signed helpers and a fresh private temporary output root")
    }
    guard output.hasPrefix("/private/tmp/"), !output.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !FileManager.default.fileExists(atPath: output) else {
      throw AgentExecutionControlFailure("fixture", "fresh explicit temporary output is required")
    }
    registryRoot = URL(filePath: output)
    let owner = Self.owner(registryRoot)
    let a = try owner.register(file: URL(filePath: firstSource))
    let b = try owner.register(file: URL(filePath: secondSource))
    XCTAssertNotEqual(try object(a)["bundleRef"], try object(b)["bundleRef"])
    let before = try Data(contentsOf: registryRoot.appending(path: "bundles.json"))
    let firstResponse = try await wire(["pageSize": .integer(1)])
    let first = try XCTUnwrap(firstResponse.result)
    let fields = try object(first)
    guard case .string(let cursor)? = fields["nextCursor"] else { return XCTFail("actual native inventory must span two pages") }
    XCTAssertEqual(fields["hasMore"], .bool(true))
    let secondResponse = try await wire(["pageSize": .integer(1), "cursor": .string(cursor)])
    let second = try XCTUnwrap(secondResponse.result)
    XCTAssertEqual(try object(second)["hasMore"], .bool(false))
    XCTAssertEqual(try object(second)["nextCursor"], .null)
    XCTAssertEqual(try object(second)["snapshotRevision"], fields["snapshotRevision"])
    failure(try await wire(["pageSize": .integer(2), "cursor": .string(cursor)]), "invalidCursor")
    let input: JSONValue = .object(["first": first, "second": second])
    try CanonicalJSONEncoders.canonical().encode(input).write(to: root.appending(path: "actual-native-pages.json"))
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "bundles.json")), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
    print("nativeBundleListRegistry=\(registryRoot.path)")
    print("nativeBundleListPages=\(root.appending(path: "actual-native-pages.json").path)")
  }

  func testExplicitRustCursorIsReadBackBySwiftWithoutInventoryWrites() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["ARKDECK_BUNDLE_LIST_RUST_ROOT"],
      let cursor = env["ARKDECK_BUNDLE_LIST_RUST_CURSOR"],
      let receipt = env["ARKDECK_BUNDLE_LIST_RUST_RECEIPT"] else {
      throw XCTSkip("requires an actual retained Rust-produced cursor and receipt")
    }
    guard directory.hasPrefix("/private/tmp/"), receipt.hasPrefix("/private/tmp/"),
      !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw AgentExecutionControlFailure("fixture", "explicit temporary producer input is required")
    }
    registryRoot = URL(filePath: directory)
    let before = try Data(contentsOf: registryRoot.appending(path: "bundles.json"))
    let producer = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: receipt)))
    let expected = try XCTUnwrap(object(producer)["second"])
    let actual = try await wire(["pageSize": .integer(1), "cursor": .string(cursor)])
    XCTAssertTrue(actual.ok)
    XCTAssertEqual(actual.result, expected)
    XCTAssertEqual(try Data(contentsOf: registryRoot.appending(path: "bundles.json")), before)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
