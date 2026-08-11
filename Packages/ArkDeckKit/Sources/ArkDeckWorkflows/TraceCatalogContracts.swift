import Foundation

public enum TracePresetID: String, CaseIterable, Codable, Equatable, Sendable {
  case attachmentPanorama
  case arkuiDeep
  case renderAnimation
  case schedulingIpc
  case io
  case custom
}

public struct TracePresetDefinition: Equatable, Sendable {
  public let id: TracePresetID
  public let logicalTags: [String]
  public let historicalBufferValue: Int?
  public let bufferUnitRequiresAdapterConfirmation: Bool
  public let displaysResourceWarning: Bool

  public init(
    id: TracePresetID,
    logicalTags: [String],
    historicalBufferValue: Int? = nil,
    bufferUnitRequiresAdapterConfirmation: Bool = false,
    displaysResourceWarning: Bool = false
  ) {
    self.id = id
    self.logicalTags = logicalTags
    self.historicalBufferValue = historicalBufferValue
    self.bufferUnitRequiresAdapterConfirmation = bufferUnitRequiresAdapterConfirmation
    self.displaysResourceWarning = displaysResourceWarning
  }
}

public enum TracePresetCatalog {
  public static let definitions: [TracePresetDefinition] = [
    TracePresetDefinition(
      id: .attachmentPanorama,
      logicalTags: [
        "sched", "freq", "ace", "app", "binder", "disk", "ohos", "graphic", "sync",
        "workq", "ability",
      ],
      historicalBufferValue: 327_680,
      bufferUnitRequiresAdapterConfirmation: true,
      displaysResourceWarning: true),
    TracePresetDefinition(
      id: .arkuiDeep,
      logicalTags: ["ace", "app", "ability", "graphic", "ohos", "sched", "freq", "sync"]),
    TracePresetDefinition(
      id: .renderAnimation,
      logicalTags: ["graphic", "ace", "app", "sched", "freq", "sync"]),
    TracePresetDefinition(
      id: .schedulingIpc,
      logicalTags: ["sched", "freq", "workq", "binder", "sync"]),
    TracePresetDefinition(id: .io, logicalTags: ["disk", "sched", "workq", "binder"]),
    TracePresetDefinition(id: .custom, logicalTags: []),
  ]

  public static func definition(for id: TracePresetID) -> TracePresetDefinition {
    // CaseIterable and the catalog table are both closed. A missing row is a programming
    // invariant, not a reason to guess a preset at runtime.
    definitions.first { $0.id == id }!
  }
}
