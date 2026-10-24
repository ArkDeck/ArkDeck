import ArkDeckCore
import Foundation

public protocol HDCClientDiagnosticsProviding: Sendable {
  var lifecycleDispatchIsProductionComposed: Bool { get }
  func refresh(deviceObservation: DeviceListPresentation) async -> HDCClientDiagnosticsPresentation
  func requestRecoveryImpactPreview() async -> HDCClientDiagnosticsPresentation
  func confirmRecoveryImpactPreview() async -> HDCClientDiagnosticsPresentation
  func dispatchConfirmedRecovery() async -> HDCClientDiagnosticsPresentation
  func selectUserConfiguredExecutable(_ url: URL) async throws -> HDCClientDiagnosticsPresentation
}

public enum HDCClientDiagnosticsApplicationFacade {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any HDCClientDiagnosticsProviding {
    if arguments.contains("--ui-test-hdc-diagnostics") {
      return HDCClientDiagnosticsFixture(arguments: arguments)
    }
    // Legacy local-production flags cannot select a host execution path.
    return HDCClientDiagnosticsProvider()
  }
}

actor HDCClientDiagnosticsProvider: HDCClientDiagnosticsProviding {
  typealias Send = @Sendable (String) async -> RuntimeXPCRequestTransport.ResultValue
  nonisolated let lifecycleDispatchIsProductionComposed = false
  private let send: Send
  private var latest = HDCClientDiagnosticsPresentation.loading

  init(send: @escaping Send = { await RuntimeXPCRequestTransport.request(method: $0) }) {
    self.send = send
  }

  func refresh(deviceObservation: DeviceListPresentation) async -> HDCClientDiagnosticsPresentation {
    latest = HDCClientDiagnosticsDecoding.presentation(
      await send("runtime.hdc.status"), deviceObservation: deviceObservation)
    return latest
  }

  // The current Runtime approval route requires a foreground console receipt.
  // This client neither fabricates that receipt nor uses a local supervisor.
  func requestRecoveryImpactPreview() -> HDCClientDiagnosticsPresentation { latest }
  func confirmRecoveryImpactPreview() -> HDCClientDiagnosticsPresentation { latest }
  func dispatchConfirmedRecovery() -> HDCClientDiagnosticsPresentation { latest }

  func selectUserConfiguredExecutable(_ url: URL) throws -> HDCClientDiagnosticsPresentation {
    throw AgentExecutionControlFailure(
      "rejected", "Tool selection is managed by Runtime. Refresh its status after changing the registered tool.")
  }
}

enum HDCClientDiagnosticsDecoding {
  typealias Presentation = HDCClientDiagnosticsPresentation

  static func presentation(
    _ response: RuntimeXPCRequestTransport.ResultValue,
    deviceObservation: DeviceListPresentation
  ) -> Presentation {
    let data: Data
    switch response {
    case .failure(let failure): return unavailable(failure.message)
    case .success(let bytes): data = bytes
    }
    let line = data.last == 0x0A ? Data(data.dropLast()) : data
    guard let envelope = try? ControlFrameJSON.decodeObject(
      line, maximumBytes: ArkDeckControlProtocol.maximumResponseFrameBytes)
    else { return unavailable("Runtime returned an unreadable HDC response. Refresh to check again.") }
    if envelope["ok"] == .bool(false), case .object(let error)? = envelope["error"],
      let code = string(error["code"]), let message = string(error["message"]) {
      return unavailable("Runtime refused HDC status (\(code)): \(message)")
    }
    guard envelope["ok"] == .bool(true), case .object(let status)? = envelope["result"],
      status["schemaVersion"] == .string("arkdeck.runtime-hdc-status/1")
    else { return unavailable("Runtime returned an unreadable HDC status. Refresh to check again.") }
    guard status["availability"] == .string("available") else {
      guard status["availability"] == .string("unavailable") || status["availability"] == .string("unknown") else {
        return unavailable("Runtime returned an unrecognized HDC availability. Refresh to check again.")
      }
      let reason = string(status["reasonCode"]) ?? "hdc.statusUnavailable"
      return unavailable("Runtime reports HDC \(string(status["availability"]) ?? "unknown"): \(reason)")
    }
    guard let digest = string(status["executableSHA256"]), digest.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let endpoint = string(status["endpoint"]), endpoint.hasPrefix("127.0.0.1:"),
      let port = UInt16(endpoint.dropFirst("127.0.0.1:".count)), port > 0,
      let generation = string(status["generation"]), let number = UInt64(generation),
      number > 0, String(number) == generation,
      let ownershipValue = string(status["ownership"]),
      let ownership = Presentation.Ownership(rawValue: ownershipValue),
      let healthValue = string(status["serverHealth"]),
      let health = Presentation.Health(rawValue: healthValue),
      let sourceValue = string(status["endpointSource"]),
      let source = Presentation.EndpointSource(rawValue: sourceValue)
    else { return unavailable("Runtime returned incomplete HDC identity or health facts. Refresh to check again.") }
    return Presentation(
      absolutePath: "not exposed by Runtime", source: "ArkDeck Runtime", hash: digest,
      platformTrust: "descriptor-bound SHA-256 verified by Runtime",
      clientVersion: string(status["clientVersion"]) ?? "not currently observed",
      serverVersion: string(status["serverVersion"]) ?? "not currently observed",
      daemonVersion: string(status["daemonVersion"]) ?? "not currently observed",
      endpoint: endpoint, serverHealth: health, generation: generation, ownership: ownership,
      authorization: authorization(deviceObservation), endpointSource: source)
  }

  private static func unavailable(_ reason: String) -> Presentation {
    Presentation(
      absolutePath: "not exposed by Runtime", source: "ArkDeck Runtime",
      authorization: .unavailable(reason: reason), loadFailure: reason)
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value, !text.isEmpty else { return nil }
    return text
  }

  private static func authorization(_ observation: DeviceListPresentation) -> Presentation.Authorization {
    guard case .available = observation.availability else {
      return .unavailable(reason: "Runtime device authorization could not be read")
    }
    let current = observation.candidates.filter { $0.stateObservationHealth == .current }
    if current.contains(where: { $0.state == "Connected" }) { return .ready }
    if current.contains(where: { $0.state == "Unauthorized" }) { return .unauthorizedWaitingForTrust }
    if current.contains(where: { $0.state == "Offline" }) {
      return .unavailable(reason: "HDC reported the target offline")
    }
    if observation.candidates.isEmpty { return .unavailable(reason: "No HDC device candidate is visible") }
    return .unavailable(reason: "Runtime has no current recognized device authorization state")
  }
}
