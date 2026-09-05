import ArkDeckCore
import Foundation

public struct RuntimeTraceCacheInventory: Sendable, Equatable {
  public let entryCount: Int
  public let totalByteCount: Int64
  public let activeEntryCount: Int

  public init(entryCount: Int, totalByteCount: Int64, activeEntryCount: Int) {
    self.entryCount = entryCount
    self.totalByteCount = totalByteCount
    self.activeEntryCount = activeEntryCount
  }

  public var inactiveEntryCount: Int { max(0, entryCount - activeEntryCount) }

  package var projection: JSONValue {
    .object([
      "entryCount": .integer(Int64(entryCount)),
      "totalByteCount": .string(String(totalByteCount)),
      "activeEntryCount": .integer(Int64(activeEntryCount)),
      "inactiveEntryCount": .integer(Int64(inactiveEntryCount)),
    ])
  }
}

public struct RuntimeTraceCachePurgeReport: Sendable, Equatable {
  public let before: RuntimeTraceCacheInventory
  public let after: RuntimeTraceCacheInventory
  public let recoveredPrivateDirectoryCount: Int
  public let removedOrphanOwnerMarkerCount: Int
  public let removedEntryCount: Int
  public let skippedActiveEntryCount: Int

  public init(
    before: RuntimeTraceCacheInventory,
    after: RuntimeTraceCacheInventory,
    recoveredPrivateDirectoryCount: Int,
    removedOrphanOwnerMarkerCount: Int,
    removedEntryCount: Int,
    skippedActiveEntryCount: Int
  ) {
    self.before = before
    self.after = after
    self.recoveredPrivateDirectoryCount = recoveredPrivateDirectoryCount
    self.removedOrphanOwnerMarkerCount = removedOrphanOwnerMarkerCount
    self.removedEntryCount = removedEntryCount
    self.skippedActiveEntryCount = skippedActiveEntryCount
  }

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.trace-cache-purge/1"),
      "before": before.projection,
      "after": after.projection,
      "recoveredPrivateDirectoryCount": .integer(Int64(recoveredPrivateDirectoryCount)),
      "removedOrphanOwnerMarkerCount": .integer(Int64(removedOrphanOwnerMarkerCount)),
      "removedEntryCount": .integer(Int64(removedEntryCount)),
      "skippedActiveEntryCount": .integer(Int64(skippedActiveEntryCount)),
      "purgeScope": .string("inactiveDerivedDatabases"),
      "originalTraceArtifactRemovalCount": .integer(0),
    ])
  }
}

/// The daemon-side owner boundary for ArkTrace's lease-aware cache service.
/// Paths are fixed when the production implementation is composed and can
/// never arrive in a control request.
public protocol RuntimeTraceCacheMaintaining: Sendable {
  func inventory() async throws -> RuntimeTraceCacheInventory
  func purgeUnused() async throws -> RuntimeTraceCachePurgeReport
}

public enum RuntimeTraceCacheLoadResult: Sendable, Equatable {
  case loaded(RuntimeTraceCacheInventory)
  case failed(String)
}

public enum RuntimeTraceCachePurgeResult: Sendable, Equatable {
  case completed(RuntimeTraceCachePurgeReport)
  case failed(String)
}

/// A closed App-facing surface for the same typed local resource used by the
/// CLI. It cannot select a path, read a Trace database, touch an Artifact or
/// submit a device Job.
public protocol RuntimeTraceCacheApplicationProviding: Sendable {
  func loadTraceCache() async -> RuntimeTraceCacheLoadResult
  func purgeUnusedTraceCache() async -> RuntimeTraceCachePurgeResult
}

public enum RuntimeTraceCacheApplicationFacade {
  public static func make() -> any RuntimeTraceCacheApplicationProviding {
    RuntimeTraceCacheXPCProvider()
  }
}

enum RuntimeTraceCacheTransportResult: Sendable {
  case success(Data)
  case failure(String)
}

actor RuntimeTraceCacheXPCProvider: RuntimeTraceCacheApplicationProviding {
  typealias Request =
    @Sendable (
      String, [String: JSONValue]?
    ) async -> RuntimeTraceCacheTransportResult

  private let request: Request

  init(
    request: @escaping Request = { method, params in
      switch await RuntimeXPCRequestTransport.request(
        method: method, params: params,
        protocolVersion: ArkDeckControlProtocol.currentVersion)
      {
      case .success(let data): return .success(data)
      case .failure(.timedOut):
        return .failure(
          "ArkDeck Runtime did not answer the Trace cache request in time. Read cache status before requesting another purge."
        )
      case .failure(let failure): return .failure(failure.message)
      }
    }
  ) {
    self.request = request
  }

  func loadTraceCache() async -> RuntimeTraceCacheLoadResult {
    switch await request("trace.cache.status", nil) {
    case .failure(let reason): return .failed(reason)
    case .success(let data):
      switch RuntimeTraceCacheResponseDecoding.status(data) {
      case .success(let inventory): return .loaded(inventory)
      case .failure(let reason): return .failed(reason)
      }
    }
  }

  func purgeUnusedTraceCache() async -> RuntimeTraceCachePurgeResult {
    switch await request("trace.cache.purge", nil) {
    case .failure(let reason): return .failed(reason)
    case .success(let data):
      switch RuntimeTraceCacheResponseDecoding.purge(data) {
      case .success(let report): return .completed(report)
      case .failure(let reason): return .failed(reason)
      }
    }
  }
}

enum RuntimeTraceCacheDecodeResult<Value> {
  case success(Value)
  case failure(String)
}

enum RuntimeTraceCacheResponseDecoding {
  static func status(
    _ data: Data
  ) -> RuntimeTraceCacheDecodeResult<RuntimeTraceCacheInventory> {
    switch resultObject(data) {
    case .failure(let reason): return .failure(reason)
    case .success(let fields):
      guard
        Set(fields.keys) == [
          "schemaVersion", "entryCount", "totalByteCount", "activeEntryCount",
          "inactiveEntryCount", "purgeScope",
        ],
        fields["schemaVersion"] == .string("arkdeck.trace-cache-status/1"),
        fields["purgeScope"] == .string("inactiveDerivedDatabases"),
        let inventory = inventory(fields, includesSchema: true)
      else { return .failure("ArkDeck Runtime returned an invalid Trace cache status") }
      return .success(inventory)
    }
  }

  static func purge(
    _ data: Data
  ) -> RuntimeTraceCacheDecodeResult<RuntimeTraceCachePurgeReport> {
    switch resultObject(data) {
    case .failure(let reason): return .failure(reason)
    case .success(let fields):
      guard
        Set(fields.keys) == [
          "schemaVersion", "before", "after", "recoveredPrivateDirectoryCount",
          "removedOrphanOwnerMarkerCount", "removedEntryCount", "skippedActiveEntryCount",
          "purgeScope", "originalTraceArtifactRemovalCount",
        ],
        fields["schemaVersion"] == .string("arkdeck.trace-cache-purge/1"),
        fields["purgeScope"] == .string("inactiveDerivedDatabases"),
        fields["originalTraceArtifactRemovalCount"] == .integer(0),
        case .object(let beforeFields)? = fields["before"],
        case .object(let afterFields)? = fields["after"],
        let before = inventory(beforeFields, includesSchema: false),
        let after = inventory(afterFields, includesSchema: false),
        let recovered = boundedCount(fields["recoveredPrivateDirectoryCount"]),
        let orphaned = boundedCount(fields["removedOrphanOwnerMarkerCount"]),
        let removed = boundedCount(fields["removedEntryCount"]),
        let skipped = boundedCount(fields["skippedActiveEntryCount"])
      else { return .failure("ArkDeck Runtime returned an invalid Trace cache purge report") }
      return .success(
        RuntimeTraceCachePurgeReport(
          before: before, after: after,
          recoveredPrivateDirectoryCount: recovered,
          removedOrphanOwnerMarkerCount: orphaned,
          removedEntryCount: removed,
          skippedActiveEntryCount: skipped))
    }
  }

  private static func resultObject(
    _ data: Data
  ) -> RuntimeTraceCacheDecodeResult<[String: JSONValue]> {
    guard case .object(let envelope)? = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return .failure("ArkDeck Runtime returned an unreadable Trace cache response") }
    if case .object(let error)? = envelope["error"] {
      let code: String
      let message: String
      if case .string(let value)? = error["code"] { code = value } else { code = "unknown" }
      if case .string(let value)? = error["message"] {
        message = value
      } else {
        message = "no message"
      }
      return .failure("ArkDeck Runtime refused Trace cache maintenance: \(code) — \(message)")
    }
    guard envelope["ok"] == .bool(true), case .object(let result)? = envelope["result"]
    else { return .failure("ArkDeck Runtime returned no Trace cache resource") }
    return .success(result)
  }

  private static func inventory(
    _ fields: [String: JSONValue], includesSchema: Bool
  ) -> RuntimeTraceCacheInventory? {
    var expected: Set<String> = [
      "entryCount", "totalByteCount", "activeEntryCount", "inactiveEntryCount",
    ]
    if includesSchema { expected.formUnion(["schemaVersion", "purgeScope"]) }
    guard Set(fields.keys) == expected,
      let entryCount = boundedCount(fields["entryCount"]),
      case .string(let totalText)? = fields["totalByteCount"],
      let totalByteCount = Int64(totalText), totalByteCount >= 0,
      String(totalByteCount) == totalText,
      let activeEntryCount = boundedCount(fields["activeEntryCount"]),
      let inactiveEntryCount = boundedCount(fields["inactiveEntryCount"]),
      activeEntryCount <= entryCount,
      inactiveEntryCount == entryCount - activeEntryCount
    else { return nil }
    return RuntimeTraceCacheInventory(
      entryCount: entryCount,
      totalByteCount: totalByteCount,
      activeEntryCount: activeEntryCount)
  }

  private static func boundedCount(_ value: JSONValue?) -> Int? {
    guard case .integer(let count)? = value, count >= 0, count <= 65_536 else { return nil }
    return Int(count)
  }
}

extension RuntimeTraceCacheInventory {
  package var statusProjection: JSONValue {
    guard case .object(var fields) = projection else {
      preconditionFailure("inventory is an object")
    }
    fields["schemaVersion"] = .string("arkdeck.trace-cache-status/1")
    fields["purgeScope"] = .string("inactiveDerivedDatabases")
    return .object(fields)
  }
}
