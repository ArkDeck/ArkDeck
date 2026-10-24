/// Display-only progress returned by Runtime. This is not a Provider receipt,
/// an execution handle or proof that the current step completed.
public struct FlashProcessProgressPresentation: Sendable, Equatable {
  public enum Phase: String, Sendable, Equatable {
    case staging
    case writing
  }

  public let stepID: String
  public let phase: Phase
  public let unitName: String?
  public let completedUnitCount: Int
  public let totalUnitCount: Int
  public let currentUnitPercent: Int?

  public init(
    stepID: String, phase: Phase, unitName: String? = nil,
    completedUnitCount: Int, totalUnitCount: Int, currentUnitPercent: Int? = nil
  ) {
    self.stepID = stepID
    self.phase = phase
    self.unitName = unitName
    self.completedUnitCount = completedUnitCount
    self.totalUnitCount = totalUnitCount
    self.currentUnitPercent = currentUnitPercent
  }
}
