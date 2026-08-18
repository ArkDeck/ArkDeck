import ArkForgeIPC
import Foundation

public enum RockchipDeviceAccessPresentationAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reason: String)
}

/// Closed App-facing projection of ArkForge's public read-only discovery.
/// It contains diagnosis and remediation facts only; no execution session,
/// permit, argv, shell, privilege escalation, or device mutation is exposed.
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
    let observations: [ArkForgeDeviceObservation]
    do {
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false)
      let socket = applicationSupport
        .appending(path: "ArkDeck/Agentd/arkforge/public.sock").path
      let client = try ArkForgeDaemonClient(
        socketPath: socket, sessionKind: .publicSession, timeoutSeconds: 15)
      observations = try client.discoverDevices(
        requestID: "app-device-access-\(UUID().uuidString.lowercased())")
    } catch {
      return RockchipDeviceAccessPresentation(
        availability: .unavailable(
          reason: "ArkForge native RockUSB discovery is unavailable: \(error)"),
        advice: RockchipDeviceAccessAdvisor.advice(for: .probeFailed),
        observationCount: 0,
        observedModes: [])
    }
    let modes = observations.compactMap { observation -> RockchipDeviceMode? in
      switch observation.mode {
      case "rockusb-loader", "loader": return .loader
      case "rockusb-maskrom", "maskrom": return .maskrom
      default: return nil
      }
    }
    let verdict: RockchipDeviceAccessVerdict
    if modes.contains(.loader) {
      verdict = .accessible
    } else if modes.isEmpty {
      verdict = .offlineOrUnauthorized
    } else {
      verdict = .protocolBlocked
    }
    return RockchipDeviceAccessPresentation(
      availability: .available,
      advice: RockchipDeviceAccessAdvisor.advice(for: verdict),
      observationCount: modes.count,
      observedModes: modes)
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
