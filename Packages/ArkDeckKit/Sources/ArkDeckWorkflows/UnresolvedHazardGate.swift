import Foundation

public enum DeviceHazardSeverity: String, Codable, Sendable {
  case warning
  case blocking
  case possibleBrick
}

public enum DeviceHazardOutcomeCertainty: String, Codable, Sendable {
  case confirmed
  case outcomeUnknown
}

public struct UnresolvedDeviceHazard: Equatable, Codable, Sendable {
  public let code: String
  public let summary: String
  public let severity: DeviceHazardSeverity
  public let outcomeCertainty: DeviceHazardOutcomeCertainty

  public init(
    code: String,
    summary: String,
    severity: DeviceHazardSeverity,
    outcomeCertainty: DeviceHazardOutcomeCertainty
  ) {
    self.code = code
    self.summary = summary
    self.severity = severity
    self.outcomeCertainty = outcomeCertainty
  }

  public var blocksConflictingJob: Bool {
    severity != .warning || outcomeCertainty == .outcomeUnknown
  }
}

public protocol HazardOverrideAuditPersisting: Sendable {
  func persistHazardOverrideAudit(
    hazards: [UnresolvedDeviceHazard],
    userConfirmationID: String
  ) throws -> String
}

public enum HazardPreflightDisposition: Equatable, Sendable {
  case passedNoConflict
  case failedConflict
  case overrideAudited(auditEventID: String)
}

public struct HazardPreflightDecision: Equatable, Sendable {
  public let disposition: HazardPreflightDisposition
  public let deviceDispatchCount: Int
  public let hazardCodes: [String]
}

public struct UnresolvedHazardPreflightGate: Sendable {
  public init() {}

  public func evaluate(
    hazards: [UnresolvedDeviceHazard],
    providerAllowsOverride: Bool,
    userOverrideConfirmationID: String?,
    auditStore: any HazardOverrideAuditPersisting
  ) -> HazardPreflightDecision {
    let blocking = hazards.filter(\.blocksConflictingJob)
    guard !blocking.isEmpty else {
      return HazardPreflightDecision(
        disposition: .passedNoConflict, deviceDispatchCount: 0, hazardCodes: [])
    }
    guard providerAllowsOverride,
      let userOverrideConfirmationID, !userOverrideConfirmationID.isEmpty,
      let auditEventID = try? auditStore.persistHazardOverrideAudit(
        hazards: blocking, userConfirmationID: userOverrideConfirmationID),
      !auditEventID.isEmpty
    else {
      return HazardPreflightDecision(
        disposition: .failedConflict,
        deviceDispatchCount: 0,
        hazardCodes: blocking.map(\.code))
    }
    return HazardPreflightDecision(
      disposition: .overrideAudited(auditEventID: auditEventID),
      deviceDispatchCount: 0,
      hazardCodes: blocking.map(\.code))
  }
}
