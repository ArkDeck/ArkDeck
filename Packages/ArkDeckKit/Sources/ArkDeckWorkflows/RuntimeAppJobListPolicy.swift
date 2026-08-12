import ArkDeckCore

/// App workspaces need recent Job context, not every historical timeline.
/// History owns explicit pagination and current-attention projection; the
/// other workspaces consume one bounded newest-first summary page.
enum RuntimeAppJobListPolicy {
  static let recentSummaryParams: [String: JSONValue] = [
    "pageSize": .integer(250),
    "order": .string("newestFirst"),
    "includeTimeline": .bool(false),
  ]
}
