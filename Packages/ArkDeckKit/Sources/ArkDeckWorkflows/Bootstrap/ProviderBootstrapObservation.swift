import Foundation

/// Bootstrap observations use the same typed dispatcher and semantic parser as
/// Jobs. Only verified summaries become candidates or identity facts. Target
/// refusals retain bounded parser diagnostics; unrelated tool text stays private.
package struct ProviderBootstrapObservation: BootstrapObservationPort {
  let provider: HDCObservationProviderAdapter
  let dispatcher: any RuntimeProcessDispatching
  let nowUTC: @Sendable () -> String

  package init(
    provider: HDCObservationProviderAdapter, dispatcher: any RuntimeProcessDispatching,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.provider = provider
    self.dispatcher = dispatcher
    self.nowUTC = nowUTC
  }

  private func run(
    _ action: HDCProviderAction, connectKey: String? = nil
  ) async throws -> ProviderSemanticOutcome {
    let context = ProviderExecutionContext(
      jobID: "bootstrap", stepID: "observe", targetID: "-", bindingRevision: nil,
      connectKey: connectKey, nowUTC: nowUTC())
    let plan = try provider.lower(action: .hdc(action), context: context)
    let receipt = try await dispatcher.dispatch(plan)
    return try provider.verify(receipt: receipt, action: .hdc(action), context: context)
  }

  private func targetSummary(
    _ action: HDCProviderAction, failureMessage: String
  ) async throws -> [String: String] {
    // Only listDeviceCandidates and observeDevice call this path. Their failed
    // details are fixed prose, a row count or a closed authorization state;
    // unknown is either fixed empty-output prose or the escaped, bounded target
    // parser diagnostic. Preserve that preview without escaping it a second time.
    switch try await run(action) {
    case .verified(let summary): return summary
    case .failed(let code, let detail):
      throw BootstrapError.observationFailed("\(code): \(detail)")
    case .unknown(let reason):
      throw BootstrapError.observationFailed(reason)
    case .unsupported:
      throw BootstrapError.observationFailed(failureMessage)
    }
  }

  package func observeToolVersion() async throws -> String {
    guard case .verified(let summary) = try await run(.observeTool),
      let version = summary["toolVersion"]
    else {
      throw BootstrapError.observationFailed("tool version could not be verified")
    }
    return version
  }

  package func listCandidates() async throws -> [BootstrapCandidate] {
    let summary = try await targetSummary(
      .listDeviceCandidates, failureMessage: "candidate list could not be verified")
    guard let countText = summary["targetCount"], let count = Int(countText) else {
      throw BootstrapError.observationFailed("candidate list summary is malformed")
    }
    guard count > 0 else { return [] }
    guard let keys = summary["connectKeys"], !keys.isEmpty else {
      throw BootstrapError.observationFailed(
        "provider did not publish candidate connect keys; adoption needs the device window")
    }
    return keys.split(separator: ",").map { entry in
      let parts = entry.split(separator: "=", maxSplits: 1)
      return BootstrapCandidate(
        connectKey: String(parts[0]),
        state: parts.count == 2 ? String(parts[1]) : "Unknown")
    }
  }

  package func observeDeviceInformation(connectKey: String) async throws
    -> BootstrapDeviceInformation?
  {
    async let name = property(.productName, connectKey: connectKey)
    async let systemVersion = property(.fullBuildVersion, connectKey: connectKey)
    let values = await (name, systemVersion)
    return BootstrapDeviceInformation(
      name: values.0, systemVersion: values.1,
      transport: connectKey.contains(":") ? "Network" : "USB")
  }

  private func property(
    _ property: HDCAllowlistedProperty, connectKey: String
  ) async -> String? {
    guard case .verified(let summary) = try? await run(.queryProperty(property), connectKey: connectKey),
      let value = summary["value"]
    else { return nil }
    let normalized = value.lowercased()
    guard !["default", "unknown", "none", "null", "[empty]"].contains(normalized),
      !normalized.hasPrefix("[fail]")
    else { return nil }
    return value
  }

  package func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
    _ = try await targetSummary(
      .observeDevice(connectKey: connectKey), failureMessage: "device observation could not be verified")
    // The provider has confirmed the exact USB connect key before this fact
    // can be used by the independently bracketed target-adoption path.
    return ["serial": connectKey]
  }
}
