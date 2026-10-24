import ArkDeckCore
import Foundation

/// The complete query represented by History's one saved local preset.
///
/// Every enum-like field is validated by the Runtime owner before it is
/// persisted. Optional Session and target identities mean "all"; the App's
/// historical private sentinel strings never cross this contract.
public struct RuntimeHistoryFilterQuery: Codable, Equatable, Sendable {
  public let search: String
  public let status: String
  public let mode: String
  public let sessionID: String?
  public let targetID: String?
  public let timeRange: String
  public let activity: String

  public init(
    search: String = "",
    status: String = "all",
    mode: String = "all",
    sessionID: String? = nil,
    targetID: String? = nil,
    timeRange: String = "anyTime",
    activity: String = "all"
  ) {
    self.search = search
    self.status = status
    self.mode = mode
    self.sessionID = sessionID
    self.targetID = targetID
    self.timeRange = timeRange
    self.activity = activity
  }

  package var projection: JSONValue {
    .object([
      "search": .string(search),
      "status": .string(status),
      "mode": .string(mode),
      "sessionId": sessionID.map(JSONValue.string) ?? .null,
      "targetId": targetID.map(JSONValue.string) ?? .null,
      "timeRange": .string(timeRange),
      "activity": .string(activity),
    ])
  }
}

/// One versioned local resource. A nil query is the durable empty/tombstone
/// state; its generation still advances so delete followed by save cannot
/// reuse an old generation.
public struct RuntimeHistoryFilterResource: Equatable, Sendable {
  public let generation: UInt64
  public let query: RuntimeHistoryFilterQuery?
  public let updatedAtUTC: String?

  public init(
    generation: UInt64,
    query: RuntimeHistoryFilterQuery?,
    updatedAtUTC: String?
  ) {
    self.generation = generation
    self.query = query
    self.updatedAtUTC = updatedAtUTC
  }

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.history-filter/1"),
      "generation": .string(String(generation)),
      "query": query.map(\.projection) ?? .null,
      "updatedAtUtc": updatedAtUTC.map(JSONValue.string) ?? .null,
    ])
  }

  package var listProjection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.history-filter-list/1"),
      "generation": .string(String(generation)),
      "filters": .array(query == nil ? [] : [projection]),
      "updatedAtUtc": updatedAtUTC.map(JSONValue.string) ?? .null,
    ])
  }
}
