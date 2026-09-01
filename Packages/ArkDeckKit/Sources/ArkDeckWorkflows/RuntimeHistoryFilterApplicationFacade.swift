import ArkDeckCore
import Foundation

public enum RuntimeHistoryFilterLoadResult: Sendable, Equatable {
  case loaded(RuntimeHistoryFilterResource)
  case failed(String)
}

public enum RuntimeHistoryFilterMutationResult: Sendable, Equatable {
  case completed(RuntimeHistoryFilterResource)
  case failed(String)
}

/// A closed App-facing surface for one bounded local presentation resource.
/// It cannot submit, run, cancel, adopt, import, export or reach a device.
public protocol RuntimeHistoryFilterApplicationProviding: Sendable {
  func loadHistoryFilter() async -> RuntimeHistoryFilterLoadResult
  func saveHistoryFilter(
    _ query: RuntimeHistoryFilterQuery,
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult
  func deleteHistoryFilter(
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult
}

public enum RuntimeHistoryFilterApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any RuntimeHistoryFilterApplicationProviding {
    if arguments.contains("--ui-test-runtime-history") {
      return RuntimeHistoryFilterFixtureProvider()
    }
    return RuntimeHistoryFilterXPCProvider()
  }
}

actor RuntimeHistoryFilterXPCProvider: RuntimeHistoryFilterApplicationProviding {
  typealias Request = @Sendable (
    String, [String: JSONValue]?
  ) async -> RuntimeHistoryTransportResult

  private let request: Request

  init(
    request: @escaping Request = { method, params in
      switch await RuntimeXPCRequestTransport.request(method: method, params: params) {
      case .success(let data): return .success(data)
      case .failure(let failure): return .failure(failure.message)
      }
    }
  ) {
    self.request = request
  }

  func loadHistoryFilter() async -> RuntimeHistoryFilterLoadResult {
    switch await request("history.filter.list", nil) {
    case .failure(let reason): return .failed(reason)
    case .success(let data):
      switch RuntimeHistoryFilterResponseDecoding.list(data) {
      case .success(let resource): return .loaded(resource)
      case .failure(let reason): return .failed(reason)
      }
    }
  }

  func saveHistoryFilter(
    _ query: RuntimeHistoryFilterQuery,
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult {
    var params = query.controlParams
    params["expectedGeneration"] = .string(String(expectedGeneration))
    return await mutate(method: "history.filter.save", params: params)
  }

  func deleteHistoryFilter(
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult {
    await mutate(
      method: "history.filter.delete",
      params: ["expectedGeneration": .string(String(expectedGeneration))])
  }

  private func mutate(
    method: String,
    params: [String: JSONValue]
  ) async -> RuntimeHistoryFilterMutationResult {
    switch await request(method, params) {
    case .failure(let reason): return .failed(reason)
    case .success(let data):
      switch RuntimeHistoryFilterResponseDecoding.resource(data) {
      case .success(let resource): return .completed(resource)
      case .failure(let reason): return .failed(reason)
      }
    }
  }
}

private actor RuntimeHistoryFilterFixtureProvider: RuntimeHistoryFilterApplicationProviding {
  private var resource = RuntimeHistoryFilterResource(
    generation: 1, query: nil, updatedAtUTC: nil)

  func loadHistoryFilter() async -> RuntimeHistoryFilterLoadResult { .loaded(resource) }

  func saveHistoryFilter(
    _ query: RuntimeHistoryFilterQuery,
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult {
    guard resource.generation == expectedGeneration else {
      return .failed("The saved History filter changed. Reload it and try again.")
    }
    resource = RuntimeHistoryFilterResource(
      generation: expectedGeneration + 1, query: query,
      updatedAtUTC: "2026-08-28T00:00:00.000Z")
    return .completed(resource)
  }

  func deleteHistoryFilter(
    expectedGeneration: UInt64
  ) async -> RuntimeHistoryFilterMutationResult {
    guard resource.generation == expectedGeneration, resource.query != nil else {
      return .failed("The saved History filter no longer exists.")
    }
    resource = RuntimeHistoryFilterResource(
      generation: expectedGeneration + 1, query: nil,
      updatedAtUTC: "2026-08-28T00:00:00.000Z")
    return .completed(resource)
  }
}

private extension RuntimeHistoryFilterQuery {
  var controlParams: [String: JSONValue] {
    [
      "search": .string(search),
      "status": .string(status),
      "mode": .string(mode),
      "sessionId": sessionID.map(JSONValue.string) ?? .null,
      "targetId": targetID.map(JSONValue.string) ?? .null,
      "timeRange": .string(timeRange),
      "activity": .string(activity),
    ]
  }
}

enum RuntimeHistoryFilterDecodeResult<Value> {
  case success(Value)
  case failure(String)
}

enum RuntimeHistoryFilterResponseDecoding {
  static func list(_ data: Data) -> RuntimeHistoryFilterDecodeResult<RuntimeHistoryFilterResource> {
    switch envelopeResult(data) {
    case .failure(let reason): return .failure(reason)
    case .success(let object):
      guard Set(object.keys) == ["schemaVersion", "generation", "filters", "updatedAtUtc"],
        object["schemaVersion"] as? String == "arkdeck.history-filter-list/1",
        let generation = canonicalGeneration(object["generation"]),
        let filters = object["filters"] as? [[String: Any]], filters.count <= 1
      else { return .failure("ArkDeck Runtime returned an invalid History filter list") }
      let updatedAtUTC: String?
      switch object["updatedAtUtc"] {
      case is NSNull: updatedAtUTC = nil
      case let value as String: updatedAtUTC = value
      default: return .failure("ArkDeck Runtime returned an invalid History filter timestamp")
      }
      guard (generation == 1 && updatedAtUTC == nil)
        || (generation > 1 && updatedAtUTC != nil)
      else { return .failure("ArkDeck Runtime returned an impossible History filter generation") }
      guard let row = filters.first else {
        return .success(
          RuntimeHistoryFilterResource(
            generation: generation, query: nil, updatedAtUTC: updatedAtUTC))
      }
      guard case .success(let resource) = decodeResource(row),
        resource.generation == generation,
        resource.updatedAtUTC == updatedAtUTC,
        resource.query != nil
      else { return .failure("ArkDeck Runtime returned a drifting History filter list") }
      return .success(resource)
    }
  }

  static func resource(_ data: Data) -> RuntimeHistoryFilterDecodeResult<RuntimeHistoryFilterResource> {
    switch envelopeResult(data) {
    case .failure(let reason): return .failure(reason)
    case .success(let object): return decodeResource(object)
    }
  }

  private static func envelopeResult(_ data: Data) -> RuntimeHistoryFilterDecodeResult<[String: Any]> {
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure("ArkDeck Runtime returned an unreadable History filter response") }
    if let error = envelope["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure("ArkDeck Runtime refused the History filter: \(code) — \(message)")
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any]
    else { return .failure("ArkDeck Runtime returned no History filter resource") }
    return .success(result)
  }

  private static func decodeResource(
    _ object: [String: Any]
  ) -> RuntimeHistoryFilterDecodeResult<RuntimeHistoryFilterResource> {
    guard Set(object.keys) == ["schemaVersion", "generation", "query", "updatedAtUtc"],
      object["schemaVersion"] as? String == "arkdeck.history-filter/1",
      let generation = canonicalGeneration(object["generation"])
    else { return .failure("ArkDeck Runtime returned an invalid History filter resource") }
    let updatedAtUTC: String?
    switch object["updatedAtUtc"] {
    case is NSNull: updatedAtUTC = nil
    case let value as String: updatedAtUTC = value
    default: return .failure("ArkDeck Runtime returned an invalid History filter timestamp")
    }
    let query: RuntimeHistoryFilterQuery?
    switch object["query"] {
    case is NSNull:
      query = nil
    case let fields as [String: Any]:
      guard let decoded = decodeQuery(fields) else {
        return .failure("ArkDeck Runtime returned an invalid History filter query")
      }
      query = decoded
    default:
      return .failure("ArkDeck Runtime returned an invalid History filter query")
    }
    guard (generation == 1 && query == nil && updatedAtUTC == nil)
      || (generation > 1 && updatedAtUTC != nil)
    else {
      return .failure("ArkDeck Runtime returned an impossible History filter generation")
    }
    return .success(
      RuntimeHistoryFilterResource(
        generation: generation, query: query, updatedAtUTC: updatedAtUTC))
  }

  private static func decodeQuery(_ fields: [String: Any]) -> RuntimeHistoryFilterQuery? {
    guard Set(fields.keys) == [
      "search", "status", "mode", "sessionId", "targetId", "timeRange", "activity",
    ],
      let search = fields["search"] as? String,
      let status = fields["status"] as? String,
      let mode = fields["mode"] as? String,
      let timeRange = fields["timeRange"] as? String,
      let activity = fields["activity"] as? String,
      ["all", "active", "needsAttention", "succeeded", "failed", "interrupted", "cancelled"]
        .contains(status),
      ["all", "execute", "planned", "simulated", "unknown"].contains(mode),
      ["anyTime", "lastHour", "lastDay", "lastWeek"].contains(timeRange),
      ["all", "flash", "viewer", "trace", "diagnostics", "debug", "device", "other"]
        .contains(activity)
    else { return nil }
    func nullableString(_ value: Any?) -> (Bool, String?) {
      switch value {
      case is NSNull: return (true, nil)
      case let value as String: return (true, value)
      default: return (false, nil)
      }
    }
    let session = nullableString(fields["sessionId"])
    let target = nullableString(fields["targetId"])
    guard session.0, target.0 else { return nil }
    return RuntimeHistoryFilterQuery(
      search: search, status: status, mode: mode,
      sessionID: session.1, targetID: target.1,
      timeRange: timeRange, activity: activity)
  }

  private static func canonicalGeneration(_ value: Any?) -> UInt64? {
    guard let text = value as? String, let generation = UInt64(text),
      generation > 0, generation <= UInt64(Int64.max), String(generation) == text
    else { return nil }
    return generation
  }
}
