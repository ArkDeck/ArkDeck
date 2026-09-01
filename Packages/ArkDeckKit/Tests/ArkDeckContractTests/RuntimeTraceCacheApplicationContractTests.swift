import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeTraceCacheApplicationContractTests: XCTestCase {
  private actor Scenario {
    private var answers: [(String, RuntimeTraceCacheTransportResult)]
    private var calls: [(String, [String: JSONValue]?)] = []

    init(_ answers: [(String, RuntimeTraceCacheTransportResult)]) { self.answers = answers }

    func request(
      _ method: String, _ params: [String: JSONValue]?
    ) -> RuntimeTraceCacheTransportResult {
      calls.append((method, params))
      guard !answers.isEmpty else { return .failure("unexpected request") }
      let next = answers.removeFirst()
      guard next.0 == method else { return .failure("unexpected method \(method)") }
      return next.1
    }

    func recordedCalls() -> [(String, [String: JSONValue]?)] { calls }
  }

  private func response(_ result: JSONValue) throws -> RuntimeTraceCacheTransportResult {
    .success(
      try CanonicalJSONEncoders.canonical().encode(
        JSONValue.object([
          "id": .string("trace-cache-test"), "ok": .bool(true), "result": result,
        ])))
  }

  private func inventory(entries: Int64, bytes: String, active: Int64) -> JSONValue {
    .object([
      "entryCount": .integer(entries),
      "totalByteCount": .string(bytes),
      "activeEntryCount": .integer(active),
      "inactiveEntryCount": .integer(entries - active),
    ])
  }

  func testAppProviderUsesOnlyTheTypedTraceCacheResource() async throws {
    var status: [String: JSONValue]
    guard case .object(let inventoryFields) = inventory(entries: 3, bytes: "4096", active: 1)
    else { return XCTFail("inventory fixture must be an object") }
    status = inventoryFields
    status["schemaVersion"] = .string("arkdeck.trace-cache-status/1")
    status["purgeScope"] = .string("inactiveDerivedDatabases")
    let purge: JSONValue = .object([
      "schemaVersion": .string("arkdeck.trace-cache-purge/1"),
      "before": inventory(entries: 3, bytes: "4096", active: 1),
      "after": inventory(entries: 1, bytes: "1024", active: 1),
      "recoveredPrivateDirectoryCount": .integer(0),
      "removedOrphanOwnerMarkerCount": .integer(1),
      "removedEntryCount": .integer(2),
      "skippedActiveEntryCount": .integer(1),
      "purgeScope": .string("inactiveDerivedDatabases"),
      "originalTraceArtifactRemovalCount": .integer(0),
    ])
    let scenario = Scenario([
      ("trace.cache.status", try response(.object(status))),
      ("trace.cache.purge", try response(purge)),
    ])
    let provider = RuntimeTraceCacheXPCProvider(request: { method, params in
      await scenario.request(method, params)
    })

    let loaded = await provider.loadTraceCache()
    XCTAssertEqual(
      loaded,
      .loaded(RuntimeTraceCacheInventory(entryCount: 3, totalByteCount: 4096, activeEntryCount: 1)))
    let purged = await provider.purgeUnusedTraceCache()
    XCTAssertEqual(
      purged,
      .completed(
        RuntimeTraceCachePurgeReport(
          before: RuntimeTraceCacheInventory(
            entryCount: 3, totalByteCount: 4096, activeEntryCount: 1),
          after: RuntimeTraceCacheInventory(
            entryCount: 1, totalByteCount: 1024, activeEntryCount: 1),
          recoveredPrivateDirectoryCount: 0,
          removedOrphanOwnerMarkerCount: 1,
          removedEntryCount: 2,
          skippedActiveEntryCount: 1)))

    let calls = await scenario.recordedCalls()
    XCTAssertEqual(calls.map(\.0), ["trace.cache.status", "trace.cache.purge"])
    XCTAssertNil(calls[0].1)
    XCTAssertNil(calls[1].1)
  }

  func testDecoderRejectsPathsAndImpossibleInventoryCounts() throws {
    let invalid: JSONValue = .object([
      "schemaVersion": .string("arkdeck.trace-cache-status/1"),
      "entryCount": .integer(1),
      "totalByteCount": .string("20"),
      "activeEntryCount": .integer(2),
      "inactiveEntryCount": .integer(0),
      "purgeScope": .string("inactiveDerivedDatabases"),
      "cachePath": .string("/private/cache"),
    ])
    guard case .success(let data) = try response(invalid),
      case .failure(let reason) = RuntimeTraceCacheResponseDecoding.status(data)
    else { return XCTFail("an impossible, path-bearing inventory was accepted") }
    XCTAssertTrue(reason.contains("invalid"))
  }
}
