/// App-local selection and refresh ownership. No Runtime authority is stored.
struct DebugWorkspaceRefreshState {
  struct Request: Equatable {
    let generation: Int
    let targetID: String?
  }

  private(set) var selectedTargetID: String?
  private(set) var inFlight: Request?
  private var generation = 0

  mutating func select(_ targetID: String?) {
    selectedTargetID = targetID
  }

  mutating func begin(fallbackTargetID: String? = nil) -> Request? {
    // A completion for a prior target must not switch the visible probe back.
    let targetID = selectedTargetID ?? fallbackTargetID
    if let inFlight, inFlight.targetID == targetID { return nil }
    generation += 1
    let request = Request(generation: generation, targetID: targetID)
    inFlight = request
    return request
  }

  mutating func finish(_ request: Request) -> Bool {
    guard inFlight == request else { return false }
    inFlight = nil
    return true
  }

  static func reconciledTarget(
    _ selected: String?, targets: [String], hasLoaded: Bool, loadFailed: Bool
  ) -> String? {
    // An empty initial projection or a failed read is not target disappearance.
    guard hasLoaded, !loadFailed else { return selected }
    if let selected, targets.contains(selected) { return selected }
    return targets.first
  }
}
