import Foundation

/// Product-facing RockUSB modes. Discovery itself is owned by ArkForge; ArkDeck
/// only projects the daemon's typed observations into App advice.
public enum RockchipDeviceMode: String, Sendable, Equatable {
  case loader = "Loader"
  case maskrom = "Maskrom"
}

public enum RockchipDeviceAccessVerdict: Sendable, Equatable {
  case accessible
  case offlineOrUnauthorized
  case permissionDenied
  case driverUnavailable
  case protocolBlocked
  case malformedOutput
  case probeFailed
}

public enum RockchipDeviceAccessResponsibility: String, Sendable, Equatable {
  case user
  case systemAdministrator
  case deviceOrToolVendor
}

public enum RockchipDeviceAccessRemediation: String, Sendable, Equatable {
  case reconnectOrEnterLoader
  case reviewDevicePermissionOutsideArkDeck
  case repairDriverOutsideArkDeck
  case chooseSupportedLoaderObservation
  case inspectControlledDiagnostics
}

public struct RockchipDeviceAccessAdvice: Sendable, Equatable {
  public let verdict: RockchipDeviceAccessVerdict
  public let responsibility: RockchipDeviceAccessResponsibility
  public let remediation: RockchipDeviceAccessRemediation
  public let reprobeAvailable: Bool

  public init(
    verdict: RockchipDeviceAccessVerdict,
    responsibility: RockchipDeviceAccessResponsibility,
    remediation: RockchipDeviceAccessRemediation,
    reprobeAvailable: Bool
  ) {
    self.verdict = verdict
    self.responsibility = responsibility
    self.remediation = remediation
    self.reprobeAvailable = reprobeAvailable
  }
}

package enum RockchipDeviceAccessAdvisor {
  public static func advice(
    for verdict: RockchipDeviceAccessVerdict
  ) -> RockchipDeviceAccessAdvice {
    switch verdict {
    case .accessible:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .chooseSupportedLoaderObservation, reprobeAvailable: true)
    case .offlineOrUnauthorized:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .reconnectOrEnterLoader, reprobeAvailable: true)
    case .permissionDenied:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .systemAdministrator,
        remediation: .reviewDevicePermissionOutsideArkDeck, reprobeAvailable: true)
    case .driverUnavailable:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .deviceOrToolVendor,
        remediation: .repairDriverOutsideArkDeck, reprobeAvailable: true)
    case .protocolBlocked:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .user,
        remediation: .chooseSupportedLoaderObservation, reprobeAvailable: true)
    case .malformedOutput, .probeFailed:
      return RockchipDeviceAccessAdvice(
        verdict: verdict, responsibility: .deviceOrToolVendor,
        remediation: .inspectControlledDiagnostics, reprobeAvailable: true)
    }
  }
}
