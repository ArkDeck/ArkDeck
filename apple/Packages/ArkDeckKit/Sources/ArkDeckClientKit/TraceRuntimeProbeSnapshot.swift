import Foundation

// The probe's read models. The probe itself stays in Workflows, next to the
// device providers and the OpenHarmony adapter it drives
// (docs/ArchitectureRules.md).

public enum TraceRuntimeParameterState: String, Codable, Sendable, Equatable {
  case missing
  case unreadable
  case value
}

public struct TraceRuntimeParameterObservation: Codable, Sendable, Equatable {
  public let name: String
  public let state: TraceRuntimeParameterState
  public let value: String?
  public let detail: String?

  public init(
    name: String,
    state: TraceRuntimeParameterState,
    value: String? = nil,
    detail: String? = nil
  ) {
    self.name = name
    self.state = state
    self.value = value
    self.detail = detail
  }
}

public enum TraceRuntimeToolDisposition: String, Codable, Sendable, Equatable {
  case captureEligible
  case probeOnly
  case unrecognized
  case probeFailed
}

public struct TraceRuntimeToolObservation: Codable, Sendable, Equatable {
  public let tool: String
  public let disposition: TraceRuntimeToolDisposition
  public let family: String?
  public let rawHelpSHA256: String?
  public let detail: String?

  public init(
    tool: String,
    disposition: TraceRuntimeToolDisposition,
    family: String? = nil,
    rawHelpSHA256: String? = nil,
    detail: String? = nil
  ) {
    self.tool = tool
    self.disposition = disposition
    self.family = family
    self.rawHelpSHA256 = rawHelpSHA256
    self.detail = detail
  }
}

public struct TraceRuntimeProbeSnapshot: Codable, Sendable, Equatable {
  public let targetID: String
  public let bindingRevision: Int
  public let adapterDisposition: String
  public let tool: String?
  public let family: String?
  public let supportedTags: [String]
  public let rawHelp: String?
  public let rawHelpSHA256: String?
  public let tools: [TraceRuntimeToolObservation]
  public let parameters: [TraceRuntimeParameterObservation]

  public init(
    targetID: String,
    bindingRevision: Int,
    adapterDisposition: String,
    tool: String?,
    family: String?,
    supportedTags: [String],
    rawHelp: String?,
    rawHelpSHA256: String?,
    tools: [TraceRuntimeToolObservation],
    parameters: [TraceRuntimeParameterObservation]
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.adapterDisposition = adapterDisposition
    self.tool = tool
    self.family = family
    self.supportedTags = supportedTags
    self.rawHelp = rawHelp
    self.rawHelpSHA256 = rawHelpSHA256
    self.tools = tools
    self.parameters = parameters
  }
}

/// Read-only target capability portrait. This never creates a mutation
/// capability and cannot be used as a substitute for Runtime admission.
