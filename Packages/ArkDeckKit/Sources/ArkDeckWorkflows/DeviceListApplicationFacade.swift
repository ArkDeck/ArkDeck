// App-facing device discovery read.
//
// One question, answered honestly: which device candidates did HDC most
// recently observe, at what time, with which raw state, and which are already
// adopted targets. The projection is fed by the daemon's `device.observations`
// method, which reads via the bootstrap's observation path and never
// touches `advance` — so nothing reachable from this facade can create,
// select or change a binding. Adoption stays a CLI act (`target.adopt` is
// refused by the App transport's allowlist).

import ArkDeckCore
import ArkDeckOpenHarmony
import Foundation
import os

/// Device facts observed by the most recent succeeded `observe.device@1` job
/// for an adopted target — model, firmware and transport as the device
/// reported them, plus when that confirmation happened. This is historical
/// evidence, not live state: it names the device, it does not certify it.
public struct DeviceObservedFactsPresentation: Sendable, Equatable {
  public let model: String?
  public let firmware: String?
  public let transport: String?
  public let confirmedAtUTC: String?

  public init(model: String?, firmware: String?, transport: String?, confirmedAtUTC: String?) {
    self.model = model
    self.firmware = firmware
    self.transport = transport
    self.confirmedAtUTC = confirmedAtUTC
  }
}

/// Display-only information read directly from the currently connected HDC
/// candidate. Unlike `observedFacts`, this is not durable Operation evidence
/// and never supplies or changes target identity.
public struct DeviceInformationPresentation: Sendable, Equatable {
  public let name: String?
  public let systemVersion: String?
  public let transport: String?
  public let observedAtUTC: String?

  public init(
    name: String?, systemVersion: String?, transport: String?, observedAtUTC: String?
  ) {
    self.name = name
    self.systemVersion = systemVersion
    self.transport = transport
    self.observedAtUTC = observedAtUTC
  }
}

/// One HDC device candidate with its raw reported state, joined against the
/// durable target store when it is already adopted. `state` is the tool's own
/// vocabulary (`Connected` / `Unauthorized` / `Offline`), shown rather than
/// reinterpreted; the two derived flags mirror `BootstrapCandidate` exactly.
/// `deviceInformation` is a best-effort live, read-only decoration and does
/// not certify identity or adoption.
/// `observedFacts` is nil when no succeeded observation evidence exists for
/// the adopted target — absence renders as absence, never as a placeholder.
public struct DeviceCandidatePresentation: Sendable, Equatable, Identifiable {
  public enum StateObservationHealth: String, Sendable, Equatable {
    case current
    case stale
  }

  public let connectKey: String
  public let state: String
  public let stateObservedAtUTC: String?
  public let stateObservationHealth: StateObservationHealth
  public let adoptedTargetID: String?
  public let bindingRevision: Int?
  public let deviceInformation: DeviceInformationPresentation?
  public let observedFacts: DeviceObservedFactsPresentation?

  public init(
    connectKey: String, state: String, adoptedTargetID: String?, bindingRevision: Int?,
    deviceInformation: DeviceInformationPresentation? = nil,
    observedFacts: DeviceObservedFactsPresentation? = nil,
    stateObservedAtUTC: String? = nil,
    stateObservationHealth: StateObservationHealth = .current
  ) {
    self.connectKey = connectKey
    self.state = state
    self.stateObservedAtUTC = stateObservedAtUTC
    self.stateObservationHealth = stateObservationHealth
    self.adoptedTargetID = adoptedTargetID
    self.bindingRevision = bindingRevision
    self.deviceInformation = deviceInformation
    self.observedFacts = observedFacts
  }

  public var id: String { connectKey }
  public var isAuthorized: Bool {
    state == "Connected" && stateObservationHealth == .current
  }
  public var needsPhysicalTrust: Bool { state == "Unauthorized" || state == "Offline" }
  public var isAdopted: Bool { adoptedTargetID != nil }
}

public struct DeviceListPresentation: Sendable, Equatable {
  public enum Availability: Sendable, Equatable {
    case checking
    case available
    case unavailable(reason: String)
  }

  public let availability: Availability
  public let candidates: [DeviceCandidatePresentation]

  public init(availability: Availability, candidates: [DeviceCandidatePresentation]) {
    self.availability = availability
    self.candidates = candidates
  }

  public static let loading = DeviceListPresentation(availability: .checking, candidates: [])
}

/// Result of the domain-owned bounded physical-trust wait. The App may show
/// the deadline, but it neither polls HDC nor classifies the terminal state.
/// `.timedOut` therefore means the production reader exhausted its bounded
/// window; it is not inferred from a view timer or a fixture-only flag.
public struct DeviceAuthorizationWaitResult: Sendable, Equatable {
  public let authorization: HDCAuthorizationState
  public let presentation: DeviceListPresentation

  public init(
    authorization: HDCAuthorizationState,
    presentation: DeviceListPresentation
  ) {
    self.authorization = authorization
    self.presentation = presentation
  }
}

public protocol DeviceListApplicationProviding: Sendable {
  var authorizationWaitWindowSeconds: TimeInterval { get }
  func startupCandidates() async -> DeviceListPresentation
  func refreshCandidates() async -> DeviceListPresentation
  func waitForAuthorization(connectKey: String) async -> DeviceAuthorizationWaitResult
}

public enum DeviceListApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any DeviceListApplicationProviding {
    if arguments.contains("--ui-test-devices") {
      return DeviceListFixtureApplicationProvider(arguments: arguments)
    }
    return DeviceListProductionApplicationProvider()
  }
}

private actor DeviceListProductionApplicationProvider: DeviceListApplicationProviding {
  nonisolated let authorizationWaitWindowSeconds: TimeInterval = 180
  private let authorizationProbeInterval: Duration = .seconds(5)

  func startupCandidates() async -> DeviceListPresentation {
    await candidates(useWarmSnapshot: true)
  }

  func refreshCandidates() async -> DeviceListPresentation {
    await candidates(useWarmSnapshot: false)
  }

  private func candidates(useWarmSnapshot: Bool) async -> DeviceListPresentation {
    switch await DeviceListXPCReadTransport.request(method: "device.observations")
    {
    case .failure(.transport(let reason)):
      return DeviceListPresentation(
        availability: .unavailable(reason: reason), candidates: [])
    case .success(let data):
      return DeviceCandidatesResponseDecoding.presentation(data)
    }
  }

  func waitForAuthorization(connectKey: String) async -> DeviceAuthorizationWaitResult {
    await boundedAuthorizationWait(
      connectKey: connectKey,
      window: .seconds(authorizationWaitWindowSeconds),
      interval: authorizationProbeInterval)
  }

  private func boundedAuthorizationWait(
    connectKey: String,
    window: Duration,
    interval: Duration
  ) async -> DeviceAuthorizationWaitResult {
    guard !connectKey.isEmpty else {
      return DeviceAuthorizationWaitResult(
        authorization: .unavailable(reason: "The selected device has no connect key"),
        presentation: .loading)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: window)
    var latest = await refreshCandidates()
    while true {
      if Task.isCancelled {
        return DeviceAuthorizationWaitResult(
          authorization: .cancelled, presentation: latest)
      }
      switch latest.availability {
      case .checking:
        break
      case .unavailable(let reason):
        return DeviceAuthorizationWaitResult(
          authorization: .unavailable(reason: reason), presentation: latest)
      case .available:
        guard let candidate = latest.candidates.first(where: { $0.connectKey == connectKey })
        else {
          return DeviceAuthorizationWaitResult(
            authorization: .unavailable(reason: "The selected device is no longer visible"),
            presentation: latest)
        }
        if candidate.isAuthorized {
          return DeviceAuthorizationWaitResult(
            authorization: .ready, presentation: latest)
        }
      }
      guard clock.now < deadline else {
        return DeviceAuthorizationWaitResult(
          authorization: .timedOut, presentation: latest)
      }
      do {
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: interval)))
      } catch {
        return DeviceAuthorizationWaitResult(
          authorization: .cancelled, presentation: latest)
      }
      latest = await refreshCandidates()
    }
  }

}

/// Incomplete facts are a reported failure, never a silently empty list: an
/// empty device list and an unreadable one must stay distinguishable.
enum DeviceCandidatesResponseDecoding {
  static func presentation(_ data: Data) -> DeviceListPresentation {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return DeviceListPresentation(
        availability: .unavailable(reason: "Runtime returned an unreadable response"),
        candidates: [])
    }
    if let error = object["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "Runtime rejected the request"
      return DeviceListPresentation(
        availability: .unavailable(reason: message), candidates: [])
    }
    guard let snapshot = object["result"] as? [String: Any],
      snapshot["schemaVersion"] as? String == "arkdeck.device-observations/1",
      let generation = snapshot["snapshotGeneration"] as? String,
      let parsedGeneration = UInt64(generation), parsedGeneration > 0, String(parsedGeneration) == generation,
      let observedAt = snapshot["observedAtUtc"] as? String, ISO8601Timestamps.parse(observedAt) != nil,
      let health = snapshot["health"] as? String, ["current", "stale"].contains(health),
      let rows = snapshot["observations"] as? [[String: Any]] else {
      return DeviceListPresentation(
        availability: .unavailable(reason: "Runtime response carries no candidate list"),
        candidates: [])
    }
    var candidates: [DeviceCandidatePresentation] = []
    for row in rows {
      guard
        let connectKey = row["candidateKey"] as? String, !connectKey.isEmpty,
        let state = row["authorizationState"] as? String, !state.isEmpty
      else {
        return DeviceListPresentation(
          availability: .unavailable(reason: "Runtime response carries an incomplete candidate"),
          candidates: [])
      }
      let targetID = row["adoptedTargetId"] as? String
      let deviceInformation: DeviceInformationPresentation?
      if let information = row["deviceInformation"] as? [String: Any] {
        let facts = DeviceInformationPresentation(
          name: information["name"] as? String,
          systemVersion: information["systemVersion"] as? String,
          transport: information["transport"] as? String,
          observedAtUTC: information["observedAtUtc"] as? String)
        deviceInformation =
          facts.name != nil || facts.systemVersion != nil || facts.transport != nil
          ? facts : nil
      } else {
        deviceInformation = nil
      }
      let observedFacts: DeviceObservedFactsPresentation?
      if let targetID,
        let observed = row["observedFacts"] as? [String: Any],
        observed["targetId"] as? String == targetID
      {
        let facts = DeviceObservedFactsPresentation(
          model: observed["model"] as? String,
          firmware: observed["firmware"] as? String,
          transport: observed["transport"] as? String,
          confirmedAtUTC: observed["confirmedAtUtc"] as? String)
        observedFacts =
          facts.model != nil || facts.firmware != nil || facts.transport != nil
          ? facts : nil
      } else {
        observedFacts = nil
      }
      candidates.append(
        DeviceCandidatePresentation(
          connectKey: connectKey,
          state: state,
          adoptedTargetID: targetID,
          bindingRevision: (row["bindingRevision"] as? NSNumber)?.intValue,
          deviceInformation: deviceInformation,
          observedFacts: observedFacts,
          stateObservedAtUTC: observedAt,
          stateObservationHealth: DeviceCandidatePresentation.StateObservationHealth(
            rawValue: health) ?? .stale))
    }
    // Multiple live transport faces may name one adopted target. Keep its
    // strongest observed state, without using this display choice for adoption.
    var displayed: [DeviceCandidatePresentation] = []
    for candidate in candidates {
      if let target = candidate.adoptedTargetID,
        let index = displayed.firstIndex(where: { $0.adoptedTargetID == target }) {
        func rank(_ state: String) -> Int { state == "Connected" ? 3 : state == "Unauthorized" ? 2 : 1 }
        if rank(candidate.state) > rank(displayed[index].state) { displayed[index] = candidate }
      } else { displayed.append(candidate) }
    }
    return DeviceListPresentation(availability: .available, candidates: displayed)
  }
}

/// Presentation values only: one adopted ready device and one candidate that
/// still needs the on-device trust prompt, so UI automation can walk both
/// sidebar states and the authorization detail without any device. The same
/// state file the other fixtures read lets one launched sweep flip the
/// unauthorized candidate to Connected — the transition a real device makes
/// when its owner accepts the trust prompt.
private actor DeviceListFixtureApplicationProvider: DeviceListApplicationProviding {
  nonisolated let authorizationWaitWindowSeconds: TimeInterval
  private let stateFileURL: URL?
  private let authorizationProbeInterval: Duration

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    if arguments.contains("--ui-test-device-poll-fast") {
      authorizationWaitWindowSeconds = 2
      authorizationProbeInterval = .milliseconds(250)
    } else {
      authorizationWaitWindowSeconds = 180
      authorizationProbeInterval = .seconds(5)
    }
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      stateFileURL = URL(filePath: arguments[index + 1])
    } else {
      stateFileURL = nil
    }
  }

  private var secondCandidateAuthorized: Bool {
    guard let stateFileURL,
      let text = try? String(contentsOf: stateFileURL, encoding: .utf8)
    else { return false }
    return text.contains("--ui-test-device-authorized")
  }

  func refreshCandidates() async -> DeviceListPresentation {
    DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "150100469346864",
          state: "Connected",
          adoptedTargetID: "target-fixture-dayu200",
          bindingRevision: 3,
          deviceInformation: DeviceInformationPresentation(
            name: "DAYU200",
            systemVersion: "OpenHarmony 5.0.0.71",
            transport: "USB",
            observedAtUTC: "2026-08-07T00:00:00Z"),
          observedFacts: DeviceObservedFactsPresentation(
            model: "DAYU200",
            firmware: "OpenHarmony 5.0.0.71",
            transport: "USB",
            confirmedAtUTC: "2026-08-07T00:00:00Z")),
        DeviceCandidatePresentation(
          connectKey: "7f2c091a445e21",
          state: secondCandidateAuthorized ? "Connected" : "Unauthorized",
          adoptedTargetID: nil,
          bindingRevision: nil),
      ])
  }

  func startupCandidates() async -> DeviceListPresentation {
    await refreshCandidates()
  }

  func waitForAuthorization(connectKey: String) async -> DeviceAuthorizationWaitResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(authorizationWaitWindowSeconds))
    var latest = await refreshCandidates()
    while true {
      if Task.isCancelled {
        return DeviceAuthorizationWaitResult(
          authorization: .cancelled, presentation: latest)
      }
      if latest.candidates.first(where: { $0.connectKey == connectKey })?.isAuthorized == true {
        return DeviceAuthorizationWaitResult(
          authorization: .ready, presentation: latest)
      }
      guard clock.now < deadline else {
        return DeviceAuthorizationWaitResult(
          authorization: .timedOut, presentation: latest)
      }
      do {
        try await clock.sleep(
          until: min(deadline, clock.now.advanced(by: authorizationProbeInterval)))
      } catch {
        return DeviceAuthorizationWaitResult(
          authorization: .cancelled, presentation: latest)
      }
      latest = await refreshCandidates()
    }
  }
}

enum DeviceListXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)
}

enum DeviceListXPCReadTransport {
  static func request(
    method: String, params: [String: JSONValue]? = nil
  ) async -> Result<Data, DeviceListXPCReadFailure> {
    await RuntimeXPCRequestTransport.request(method: method, params: params)
      .mapError { DeviceListXPCReadFailure.transport($0.message) }
  }
}
