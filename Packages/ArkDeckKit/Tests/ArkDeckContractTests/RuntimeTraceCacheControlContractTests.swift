import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeTraceCacheControlContractTests: XCTestCase {
  private enum FixtureFailure: Error { case unavailable }

  private actor Owner: RuntimeTraceCacheMaintaining {
    enum Behavior { case succeeds, statusFails, purgeFails }

    let behavior: Behavior
    private(set) var inventoryCallCount = 0
    private(set) var purgeCallCount = 0

    init(_ behavior: Behavior = .succeeds) { self.behavior = behavior }

    func inventory() async throws -> RuntimeTraceCacheInventory {
      inventoryCallCount += 1
      if behavior == .statusFails { throw FixtureFailure.unavailable }
      return RuntimeTraceCacheInventory(entryCount: 3, totalByteCount: 4096, activeEntryCount: 1)
    }

    func purgeUnused() async throws -> RuntimeTraceCachePurgeReport {
      purgeCallCount += 1
      if behavior == .purgeFails { throw FixtureFailure.unavailable }
      return RuntimeTraceCachePurgeReport(
        before: RuntimeTraceCacheInventory(
          entryCount: 3, totalByteCount: 4096, activeEntryCount: 1),
        after: RuntimeTraceCacheInventory(
          entryCount: 1, totalByteCount: 1024, activeEntryCount: 1),
        recoveredPrivateDirectoryCount: 0,
        removedOrphanOwnerMarkerCount: 1,
        removedEntryCount: 2,
        skippedActiveEntryCount: 1)
    }

    func callCounts() -> (inventory: Int, purge: Int) {
      (inventoryCallCount, purgeCallCount)
    }
  }

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-trace-cache-control-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func handler(
    owner: (any RuntimeTraceCacheMaintaining)?
  ) throws -> RuntimeControlPlaneHandler {
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(
        resolver: try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")),
      capabilityStore: capabilities,
      nowUTC: { "2026-09-01T00:00:00Z" })
    return RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, traceCacheMaintenance: owner)
  }

  private func request(
    _ handler: RuntimeControlPlaneHandler,
    method: String,
    version: String = ArkDeckControlProtocol.targetVersion,
    params: [String: JSONValue]? = nil
  ) async throws -> AgentWireProtocol.Response {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      JSONValue.object([
        "protocolVersion": .string(version),
        "id": .string("trace-cache-contract"),
        "method": .string(method),
        "params": params.map(JSONValue.object) ?? .null,
      ]))
    return try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(frame))
  }

  func testStatusAndPurgePublishOnlyTheBoundedResource() async throws {
    let owner = Owner()
    let handler = try handler(owner: owner)

    let status = try await request(handler, method: "trace.cache.status")
    XCTAssertTrue(status.ok, String(describing: status.error))
    XCTAssertEqual(
      status.result,
      RuntimeTraceCacheInventory(
        entryCount: 3, totalByteCount: 4096, activeEntryCount: 1
      ).statusProjection)

    let purge = try await request(handler, method: "trace.cache.purge")
    XCTAssertTrue(purge.ok, String(describing: purge.error))
    guard case .object(let fields)? = purge.result else {
      return XCTFail("purge must return one typed object")
    }
    XCTAssertEqual(fields["purgeScope"], .string("inactiveDerivedDatabases"))
    XCTAssertEqual(fields["originalTraceArtifactRemovalCount"], .integer(0))
    XCTAssertNil(fields["path"])
    let callCounts = await owner.callCounts()
    XCTAssertEqual(callCounts.inventory, 1)
    XCTAssertEqual(callCounts.purge, 1)
  }

  func testControlBoundaryRejectsLegacyParametersAndMissingOwner() async throws {
    let owner = Owner()
    let configured = try handler(owner: owner)
    let legacy = try await request(
      configured, method: "trace.cache.status", version: ArkDeckControlProtocol.legacyVersion)
    XCTAssertEqual(legacy.error?.code, "unsupportedProtocolVersion")
    let pathBearing = try await request(
      configured, method: "trace.cache.purge", params: ["path": .string("/tmp/cache")])
    XCTAssertEqual(pathBearing.error?.code, "invalidParams")
    let callCounts = await owner.callCounts()
    XCTAssertEqual(callCounts.inventory, 0)
    XCTAssertEqual(callCounts.purge, 0)

    let missing = try await request(
      try handler(owner: nil), method: "trace.cache.status")
    XCTAssertEqual(missing.error?.code, "internalError")
  }

  func testOwnerFailuresKeepStatusReadOnlyAndPurgeAmbiguous() async throws {
    let status = try await request(
      try handler(owner: Owner(.statusFails)), method: "trace.cache.status")
    XCTAssertEqual(status.error?.code, "recordUnreadable")
    XCTAssertEqual(status.error?.details?["phase"], .string("traceCacheOwner"))
    XCTAssertEqual(status.error?.details?["newDispatchCount"], .integer(0))

    let purge = try await request(
      try handler(owner: Owner(.purgeFails)), method: "trace.cache.purge")
    XCTAssertEqual(purge.error?.code, "outcomeUnknown")
    XCTAssertEqual(purge.error?.details?["phase"], .string("traceCacheOwner"))
    XCTAssertEqual(purge.error?.details?["newDispatchCount"], .integer(0))
    XCTAssertEqual(
      purge.error?.details?["purgeScope"], .string("inactiveDerivedDatabases"))
  }
}
