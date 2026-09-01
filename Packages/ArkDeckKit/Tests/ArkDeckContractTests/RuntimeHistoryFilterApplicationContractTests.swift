import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeHistoryFilterApplicationContractTests: XCTestCase {
  private actor Scenario {
    private var answers: [(String, RuntimeHistoryTransportResult)]
    private var calls: [(String, [String: JSONValue]?)] = []

    init(_ answers: [(String, RuntimeHistoryTransportResult)]) { self.answers = answers }

    func request(
      _ method: String, _ params: [String: JSONValue]?
    ) -> RuntimeHistoryTransportResult {
      calls.append((method, params))
      guard !answers.isEmpty else { return .failure("unexpected request") }
      let next = answers.removeFirst()
      guard next.0 == method else { return .failure("unexpected method \(method)") }
      return next.1
    }

    func recordedCalls() -> [(String, [String: JSONValue]?)] { calls }
  }

  private func response(_ result: JSONValue) throws -> RuntimeHistoryTransportResult {
    .success(
      try CanonicalJSONEncoders.canonical().encode(
        JSONValue.object([
          "id": .string("filter-test"), "ok": .bool(true), "result": result,
        ])))
  }

  private func resource(
    generation: String, query: JSONValue
  ) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.history-filter/1"),
      "generation": .string(generation),
      "query": query,
      "updatedAtUtc": generation == "1" ? .null : .string("2026-09-01T08:30:00.000Z"),
    ])
  }

  private var query: RuntimeHistoryFilterQuery {
    RuntimeHistoryFilterQuery(
      search: "failure", status: "failed", mode: "execute",
      sessionID: "S-1", targetID: "T-1", timeRange: "lastDay", activity: "flash")
  }

  func testAppProviderReadsAndMutatesOnlyTheTypedHistoryResource() async throws {
    let queryValue = query.projection
    let scenario = Scenario([
      ("history.filter.list", try response(.object([
        "schemaVersion": .string("arkdeck.history-filter-list/1"),
        "generation": .string("1"), "filters": .array([]), "updatedAtUtc": .null,
      ]))),
      ("history.filter.save", try response(resource(generation: "2", query: queryValue))),
      ("history.filter.delete", try response(resource(generation: "3", query: .null))),
    ])
    let provider = RuntimeHistoryFilterXPCProvider(request: { method, params in
      await scenario.request(method, params)
    })

    let loaded = await provider.loadHistoryFilter()
    XCTAssertEqual(
      loaded,
      .loaded(RuntimeHistoryFilterResource(generation: 1, query: nil, updatedAtUTC: nil)))
    let saved = await provider.saveHistoryFilter(query, expectedGeneration: 1)
    XCTAssertEqual(
      saved,
      .completed(
        RuntimeHistoryFilterResource(
          generation: 2, query: query, updatedAtUTC: "2026-09-01T08:30:00.000Z")))
    let deleted = await provider.deleteHistoryFilter(expectedGeneration: 2)
    XCTAssertEqual(
      deleted,
      .completed(
        RuntimeHistoryFilterResource(
          generation: 3, query: nil, updatedAtUTC: "2026-09-01T08:30:00.000Z")))

    let calls = await scenario.recordedCalls()
    XCTAssertEqual(calls.map(\.0), [
      "history.filter.list", "history.filter.save", "history.filter.delete",
    ])
    XCTAssertNil(calls[0].1)
    XCTAssertEqual(calls[1].1?["expectedGeneration"], .string("1"))
    XCTAssertEqual(calls[1].1?["sessionId"], .string("S-1"))
    XCTAssertEqual(calls[1].1?["targetId"], .string("T-1"))
    XCTAssertEqual(calls[2].1, ["expectedGeneration": .string("2")])
  }

  func testAppDecoderRefusesAListWhoseContainerAndRecordDrift() throws {
    let drifted = try response(.object([
      "schemaVersion": .string("arkdeck.history-filter-list/1"),
      "generation": .string("4"),
      "filters": .array([resource(generation: "3", query: query.projection)]),
      "updatedAtUtc": .string("2026-09-01T08:30:00.000Z"),
    ]))
    guard case .success(let data) = drifted,
      case .failure(let reason) = RuntimeHistoryFilterResponseDecoding.list(data)
    else { return XCTFail("a drifting list was accepted") }
    XCTAssertTrue(reason.contains("drifting"))
  }
}
