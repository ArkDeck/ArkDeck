import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeHistoryPagingContractTests: XCTestCase {
  func testPagingRemainsBoundedAndRetryKeepsTheSameCursor() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead(provider.refreshHistory, through: transport, index: 0)
    await transport.complete(0, with: try page(["head"], cursor: "older"))
    let initial = await first.value
    XCTAssertEqual(initial.jobs.map(\.id), ["head"])
    let firstParams = await transport.params(at: 0)
    XCTAssertEqual(firstParams["pageSize"], .integer(200))
    XCTAssertEqual(firstParams["order"], .string("newestFirst"))
    XCTAssertEqual(firstParams["includeTimeline"], .bool(false))
    XCTAssertEqual(firstParams["includeCurrent"], .bool(true))

    let older = await startRead(provider.loadOlderHistory, through: transport, index: 1)
    await transport.complete(1, with: .failure("temporarily unavailable"))
    let failedPage = await older.value
    XCTAssertEqual(failedPage.jobs, initial.jobs)
    XCTAssertTrue(failedPage.hasOlderJobs)
    XCTAssertEqual(failedPage.olderJobsLoadFailure, "temporarily unavailable")

    let retry = await startRead(provider.loadOlderHistory, through: transport, index: 2)
    let retryParams = await transport.params(at: 2)
    XCTAssertEqual(retryParams["cursor"], .string("older"))
    XCTAssertNil(retryParams["includeCurrent"])
    await transport.complete(2, with: try page(["head", "tail"]))
    let completed = await retry.value
    XCTAssertEqual(completed.jobs.map(\.id), ["head", "tail"])
    XCTAssertFalse(completed.hasOlderJobs)
    XCTAssertNil(completed.olderJobsLoadFailure)
    let noMorePages = await provider.loadOlderHistory()
    XCTAssertEqual(noMorePages, completed)
    let requestCount = await transport.count
    XCTAssertEqual(requestCount, 3)
  }

  func testLateOlderSuccessCannotAppendRowsOrReplaceTheRefreshedCursor() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead(provider.refreshHistory, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead(provider.loadOlderHistory, through: transport, index: 1)
    let refresh = await startRead(provider.refreshHistory, through: transport, index: 2)
    await transport.complete(2, with: try page(["new-head"], cursor: "new-cursor"))
    let refreshed = await refresh.value
    await transport.complete(1, with: try page(["stale-tail"], cursor: "stale-cursor"))
    let stale = await older.value
    XCTAssertEqual(stale, refreshed)

    let newOlder = await startRead(provider.loadOlderHistory, through: transport, index: 3)
    let params = await transport.params(at: 3)
    XCTAssertEqual(params["cursor"], .string("new-cursor"))
    await transport.complete(3, with: try page(["new-tail"]))
    let result = await newOlder.value
    XCTAssertEqual(result.jobs.map(\.id), ["new-head", "new-tail"])
    XCTAssertFalse(result.hasOlderJobs)
  }

  func testLateOlderFailureCannotAddAnErrorOrReenableExhaustedPaging() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead(provider.refreshHistory, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead(provider.loadOlderHistory, through: transport, index: 1)
    let refresh = await startRead(provider.refreshHistory, through: transport, index: 2)
    await transport.complete(2, with: try page(["new-head"]))
    let refreshed = await refresh.value
    await transport.complete(1, with: .failure("stale page error"))
    let stale = await older.value
    XCTAssertEqual(stale, refreshed)
    XCTAssertFalse(stale.hasOlderJobs)
    XCTAssertNil(stale.olderJobsLoadFailure)
  }

  func testOlderCompletionDuringRefreshCannotMaskTheRefreshFailure() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead(provider.refreshHistory, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead(provider.loadOlderHistory, through: transport, index: 1)
    let refresh = await startRead(provider.refreshHistory, through: transport, index: 2)
    await transport.complete(1, with: try page(["stale-tail"], cursor: "stale-cursor"))
    let stale = await older.value
    XCTAssertEqual(stale, .loading)
    await transport.complete(2, with: .failure("refresh failed"))
    let failed = await refresh.value
    XCTAssertEqual(failed.availability, .unavailable(reason: "refresh failed"))
    XCTAssertTrue(failed.jobs.isEmpty)
    let noStaleCursor = await provider.loadOlderHistory()
    XCTAssertEqual(noStaleCursor, failed)
  }

  func testLateRefreshCannotReplaceTheNewestRefreshFailure() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let old = await startRead(provider.refreshHistory, through: transport, index: 0)
    let new = await startRead(provider.refreshHistory, through: transport, index: 1)
    await transport.complete(1, with: .success(Data("not JSON".utf8)))
    let failed = await new.value
    await transport.complete(0, with: try page(["stale-head"], cursor: "stale-cursor"))
    let stale = await old.value
    guard case .unavailable = failed.availability else {
      return XCTFail("an unreadable refresh must remain unavailable")
    }
    XCTAssertEqual(stale, failed)
    let noStaleCursor = await provider.loadOlderHistory()
    XCTAssertEqual(noStaleCursor, failed)
  }

  /// No sleeps or daemon access: hold each real provider read at its await
  /// boundary and choose exactly which response wins the race.
  private func startRead(
    _ read: @escaping @Sendable () async -> RuntimeHistoryPresentation,
    through transport: ControlledHistoryTransport,
    index: Int
  ) async -> Task<RuntimeHistoryPresentation, Never> {
    let arrived = expectation(description: "history request \(index)")
    await transport.expect(index, arrival: arrived)
    let task = Task { await read() }
    await fulfillment(of: [arrived], timeout: 5)
    return task
  }

  private func page(_ ids: [String], cursor: String? = nil) throws -> RuntimeHistoryTransportResult
  {
    let jobs = ids.map {
      ["jobId": $0, "operation": "observe.device@1", "targetId": "fixture", "state": "succeeded"]
    }
    var result: [String: Any] = ["jobs": jobs]
    if let cursor { result["nextCursor"] = cursor }
    return .success(try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]))
  }
}

private actor ControlledHistoryTransport {
  private var arrivals: [Int: XCTestExpectation] = [:]
  private var pending: [Int: CheckedContinuation<RuntimeHistoryTransportResult, Never>] = [:]
  private var requests: [[String: JSONValue]] = []
  var count: Int { requests.count }

  func expect(_ index: Int, arrival: XCTestExpectation) {
    arrivals[index] = arrival
  }

  func request(_ params: [String: JSONValue]) async -> RuntimeHistoryTransportResult {
    let index = requests.count
    requests.append(params)
    return await withCheckedContinuation { continuation in
      pending[index] = continuation
      arrivals.removeValue(forKey: index)?.fulfill()
    }
  }

  func params(at index: Int) -> [String: JSONValue] { requests[index] }

  func complete(_ index: Int, with result: RuntimeHistoryTransportResult) {
    pending.removeValue(forKey: index)?.resume(returning: result)
  }
}
