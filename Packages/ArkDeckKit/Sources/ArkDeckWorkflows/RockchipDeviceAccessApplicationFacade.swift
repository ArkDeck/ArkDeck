import Foundation

public enum RockchipDeviceAccessPresentationAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reason: String)
}

/// Closed App-facing projection of Runtime's ArkForge read-only discovery.
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
      return RockchipDeviceAccessFixtureProvider(arguments: arguments)
    }
    return RockchipDeviceAccessProductionProvider()
  }
}

actor RockchipDeviceAccessProductionProvider:
  RockchipDeviceAccessApplicationProviding
{
  typealias Request = @Sendable (String) async -> RuntimeXPCRequestTransport.ResultValue
  private let request: Request

  init(request: @escaping Request = {
    await RuntimeXPCRequestTransport.request(method: $0)
  }) {
    self.request = request
  }

  func refresh() async -> RockchipDeviceAccessPresentation {
    RockchipDeviceAccessResponseDecoding.presentation(
      await request("flash.device-access"))
  }
}

enum RockchipDeviceAccessResponseDecoding {
  private struct Envelope: Decodable {
    let ok: Bool
    let result: Payload?
  }

  private struct Payload: Decodable {
    let observationCount: Int
    let observedModes: [String]
  }

  static func presentation(
    _ response: RuntimeXPCRequestTransport.ResultValue
  ) -> RockchipDeviceAccessPresentation {
    guard case .success(let data) = response else {
      return unavailable("runtime_device_access_unreachable", verdict: .probeFailed)
    }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      return unavailable("runtime_device_access_malformed", verdict: .malformedOutput)
    }
    guard envelope.ok else {
      return unavailable("runtime_device_access_unavailable", verdict: .probeFailed)
    }
    guard let payload = envelope.result,
      payload.observationCount >= 0,
      payload.observationCount == payload.observedModes.count
    else {
      return unavailable("runtime_device_access_malformed", verdict: .malformedOutput)
    }
    let modes = payload.observedModes.compactMap(RockchipDeviceMode.init(rawValue:))
    guard modes.count == payload.observedModes.count else {
      return unavailable("runtime_device_access_unknown_mode", verdict: .malformedOutput)
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

  private static func unavailable(
    _ reason: String, verdict: RockchipDeviceAccessVerdict
  ) -> RockchipDeviceAccessPresentation {
    RockchipDeviceAccessPresentation(
      availability: .unavailable(reason: reason),
      advice: RockchipDeviceAccessAdvisor.advice(for: verdict),
      observationCount: 0, observedModes: [])
  }
}

private actor RockchipDeviceAccessFixtureProvider:
  RockchipDeviceAccessApplicationProviding
{
  private let arguments: [String]

  init(arguments: [String]) { self.arguments = arguments }

  func refresh() async -> RockchipDeviceAccessPresentation {
    if arguments.contains("--ui-test-flash-device-access-unavailable") {
      return RockchipDeviceAccessResponseDecoding.presentation(.failure(.unavailable(nil)))
    }
    if arguments.contains("--ui-test-flash-device-access-absent") {
      return RockchipDeviceAccessResponseDecoding.presentation(
        .success(Data(#"{"ok":true,"result":{"observationCount":0,"observedModes":[]}}"#.utf8)))
    }
    return RockchipDeviceAccessPresentation(
      availability: .available,
      advice: RockchipDeviceAccessAdvisor.advice(for: .accessible),
      observationCount: 1,
      observedModes: [.loader])
  }
}
