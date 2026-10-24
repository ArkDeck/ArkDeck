@testable import ArkDeckClientKit
import Foundation
import Testing

@testable import ArkDeckCore

struct RuntimeHistoryPagingContractTests {
  @Test func pagingRemainsBoundedAndRetryKeepsTheSameCursor() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead({ await provider.refreshHistory() }, through: transport, index: 0)
    await transport.complete(0, with: try page(["head"], cursor: "older"))
    let initial = await first.value
    #expect(initial.jobs.map(\.id) == ["head"])
    let firstParams = await transport.params(at: 0)
    #expect(firstParams["pageSize"] == .integer(200))
    #expect(firstParams["order"] == .string("createdAtDescJobIdAsc"))
    #expect(firstParams["includeTimeline"] == .bool(false))
    #expect(firstParams["includeCurrent"] == .bool(true))

    let older = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 1)
    await transport.complete(1, with: .failure("temporarily unavailable"))
    let failedPage = await older.value
    #expect(failedPage.jobs == initial.jobs)
    #expect(failedPage.hasOlderJobs)
    #expect(failedPage.olderJobsLoadFailure == "temporarily unavailable")

    let retry = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 2)
    let retryParams = await transport.params(at: 2)
    #expect(retryParams["cursor"] == .string("older"))
    #expect(retryParams["includeCurrent"] == .bool(true))
    await transport.complete(2, with: try page(["head", "tail"]))
    let completed = await retry.value
    #expect(completed.jobs.map(\.id) == ["head", "tail"])
    #expect(!completed.hasOlderJobs)
    #expect(completed.olderJobsLoadFailure == nil)
    let noMorePages = await provider.loadOlderHistory()
    #expect(noMorePages == completed)
    let requestCount = await transport.count
    #expect(requestCount == 3)
  }

  @Test func lateOlderSuccessCannotAppendRowsOrReplaceTheRefreshedCursor() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead({ await provider.refreshHistory() }, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 1)
    let refresh = await startRead({ await provider.refreshHistory() }, through: transport, index: 2)
    await transport.complete(2, with: try page(["new-head"], cursor: "new-cursor"))
    let refreshed = await refresh.value
    await transport.complete(1, with: try page(["stale-tail"], cursor: "stale-cursor"))
    let stale = await older.value
    #expect(stale == refreshed)

    let newOlder = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 3)
    let params = await transport.params(at: 3)
    #expect(params["cursor"] == .string("new-cursor"))
    await transport.complete(3, with: try page(["new-tail"]))
    let result = await newOlder.value
    #expect(result.jobs.map(\.id) == ["new-head", "new-tail"])
    #expect(!result.hasOlderJobs)
  }

  @Test func lateOlderFailureCannotAddAnErrorOrReenableExhaustedPaging() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead({ await provider.refreshHistory() }, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 1)
    let refresh = await startRead({ await provider.refreshHistory() }, through: transport, index: 2)
    await transport.complete(2, with: try page(["new-head"]))
    let refreshed = await refresh.value
    await transport.complete(1, with: .failure("stale page error"))
    let stale = await older.value
    #expect(stale == refreshed)
    #expect(!stale.hasOlderJobs)
    #expect(stale.olderJobsLoadFailure == nil)
  }

  @Test func olderCompletionDuringRefreshCannotMaskTheRefreshFailure() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let first = await startRead({ await provider.refreshHistory() }, through: transport, index: 0)
    await transport.complete(0, with: try page(["old-head"], cursor: "old-cursor"))
    _ = await first.value
    let older = await startRead({ await provider.loadOlderHistory() }, through: transport, index: 1)
    let refresh = await startRead({ await provider.refreshHistory() }, through: transport, index: 2)
    await transport.complete(1, with: try page(["stale-tail"], cursor: "stale-cursor"))
    let stale = await older.value
    #expect(stale == .loading)
    await transport.complete(2, with: .failure("refresh failed"))
    let failed = await refresh.value
    #expect(failed.availability == .unavailable(reason: "refresh failed"))
    #expect(failed.jobs.isEmpty)
    let noStaleCursor = await provider.loadOlderHistory()
    #expect(noStaleCursor == failed)
  }

  @Test func lateRefreshCannotReplaceTheNewestRefreshFailure() async throws {
    let transport = ControlledHistoryTransport()
    let provider = RuntimeHistoryXPCProvider(request: transport.request)
    let old = await startRead({ await provider.refreshHistory() }, through: transport, index: 0)
    let new = await startRead({ await provider.refreshHistory() }, through: transport, index: 1)
    await transport.complete(1, with: .success(Data("not JSON".utf8)))
    let failed = await new.value
    await transport.complete(0, with: try page(["stale-head"], cursor: "stale-cursor"))
    let stale = await old.value
    guard case .unavailable = failed.availability else {
      Issue.record("an unreadable refresh must remain unavailable")
      return
    }
    #expect(stale == failed)
    let noStaleCursor = await provider.loadOlderHistory()
    #expect(noStaleCursor == failed)
  }

  /// No sleeps or daemon access: hold each real provider read at its await
  /// boundary and choose exactly which response wins the race.
  ///
  /// Callers pass a closure that calls the provider, never the method itself:
  /// with approachable concurrency, `provider.loadOlderHistory` as a function
  /// value resolves to the protocol extension's default, which only refreshes.
  private func startRead(
    _ read: @escaping @Sendable () async -> RuntimeHistoryPresentation,
    through transport: ControlledHistoryTransport,
    index: Int,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> Task<RuntimeHistoryPresentation, Never> {
    let task = Task { await read() }
    let arrived = await transport.waitForRequest(index, within: .seconds(5))
    #expect(
      arrived, "history request \(index) did not arrive within 5 seconds",
      sourceLocation: sourceLocation)
    return task
  }

  private func page(_ ids: [String], cursor: String? = nil) throws -> RuntimeHistoryTransportResult
  {
    let jobs = ids.map {
      ["jobId": $0, "operation": "observe.device@1", "targetId": "fixture", "state": "succeeded"]
    }
    return .success(try currentJobPageResponse(jobs, cursor: cursor))
  }
}

private actor ControlledHistoryTransport {
  private var arrivals: [Int: CheckedContinuation<Bool, Never>] = [:]
  private var pending: [Int: CheckedContinuation<RuntimeHistoryTransportResult, Never>] = [:]
  private var requests: [[String: JSONValue]] = []
  var count: Int { requests.count }

  /// Whether request `index` reached this transport, and is held at its await
  /// boundary, within `timeout`. The deadline only bounds a read that never
  /// arrives; it is not what orders the reads.
  func waitForRequest(_ index: Int, within timeout: Duration) async -> Bool {
    guard index >= requests.count else { return true }
    let deadline = Task {
      try await Task.sleep(for: timeout)
      self.arrivals.removeValue(forKey: index)?.resume(returning: false)
    }
    defer { deadline.cancel() }
    return await withCheckedContinuation { arrivals[index] = $0 }
  }

  func request(_ params: [String: JSONValue]) async -> RuntimeHistoryTransportResult {
    let index = requests.count
    requests.append(params)
    return await withCheckedContinuation { continuation in
      pending[index] = continuation
      arrivals.removeValue(forKey: index)?.resume(returning: true)
    }
  }

  func params(at index: Int) -> [String: JSONValue] { requests[index] }

  func complete(_ index: Int, with result: RuntimeHistoryTransportResult) {
    pending.removeValue(forKey: index)?.resume(returning: result)
  }
}
