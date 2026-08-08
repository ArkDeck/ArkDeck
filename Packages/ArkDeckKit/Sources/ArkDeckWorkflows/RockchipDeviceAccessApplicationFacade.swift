import Foundation

public enum RockchipDeviceAccessPresentationAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reason: String)
}

/// Closed App-facing projection of the registered read-only `rkdeveloptool ld`
/// probe. It contains diagnosis and remediation facts only; no argv, shell,
/// privilege escalation, driver installation, or device mutation is exposed.
public struct RockchipDeviceAccessPresentation: Sendable, Equatable {
  public let availability: RockchipDeviceAccessPresentationAvailability
  public let advice: RockchipDeviceAccessAdvice?
  public let observationCount: Int
  public let observedModes: [RockchipDeviceMode]

  public init(
    availability: RockchipDeviceAccessPresentationAvailability,
    advice: RockchipDeviceAccessAdvice?,
    observationCount: Int,
    observedModes: [RockchipDeviceMode]
  ) {
    self.availability = availability
    self.advice = advice
    self.observationCount = observationCount
    self.observedModes = observedModes
  }

  public static let loading = RockchipDeviceAccessPresentation(
    availability: .checking, advice: nil, observationCount: 0, observedModes: [])
}

public protocol RockchipDeviceAccessApplicationProviding: Sendable {
  func refresh() async -> RockchipDeviceAccessPresentation
}

public enum RockchipDeviceAccessApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any RockchipDeviceAccessApplicationProviding {
    if arguments.contains("--ui-test-flash") {
      return RockchipDeviceAccessFixtureProvider()
    }
    return RockchipDeviceAccessProductionProvider()
  }
}

private actor RockchipDeviceAccessProductionProvider:
  RockchipDeviceAccessApplicationProviding
{
  func refresh() async -> RockchipDeviceAccessPresentation {
    let settings: RockchipProductDiscoverySettings
    do {
      settings = try RockchipProductExecutionSettings.loadDiscovery()
    } catch {
      return RockchipDeviceAccessPresentation(
        availability: .unavailable(
          reason: "The pinned rkdeveloptool selection or trust facts are unavailable"),
        advice: RockchipDeviceAccessAdvisor.advice(
          for: .toolBlocked(.ordinaryBookmarkMissing)),
        observationCount: 0,
        observedModes: [])
    }
    let attempt = await RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter(
      toolWorkingDirectory: settings.toolWorkingDirectory
    ).discover(using: settings.tool)
    return RockchipDeviceAccessPresentation(
      availability: .available,
      advice: attempt.advice,
      observationCount: attempt.observations.count,
      observedModes: attempt.observations.map(\.mode))
  }
}

private actor RockchipDeviceAccessFixtureProvider:
  RockchipDeviceAccessApplicationProviding
{
  func refresh() async -> RockchipDeviceAccessPresentation {
    RockchipDeviceAccessPresentation(
      availability: .available,
      advice: RockchipDeviceAccessAdvisor.advice(for: .accessible),
      observationCount: 1,
      observedModes: [.loader])
  }
}
