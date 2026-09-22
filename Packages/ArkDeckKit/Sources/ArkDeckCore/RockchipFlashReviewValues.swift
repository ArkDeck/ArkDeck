import Foundation

/// How the review labels its step list: an execute review, a plan-only
/// preparation, or a simulated preview. Presentation vocabulary only — the
/// executed plan is materialized by the engine at submission and by
/// `arkforged` inside the lane.
public enum RockchipFlashExecutionMode: String, CaseIterable, Codable, Equatable, Sendable {
  case execute
  case planOnly
  case simulated
}

/// One observed prerequisite status, merged into the review's prerequisite
/// presentation.
public struct RockchipPrerequisiteObservation: Equatable, Sendable {
  public let identifier: RockchipPrerequisiteIdentifier
  public let status: RockchipPrerequisiteStatus

  public init(
    identifier: RockchipPrerequisiteIdentifier,
    status: RockchipPrerequisiteStatus
  ) {
    self.identifier = identifier
    self.status = status
  }
}
