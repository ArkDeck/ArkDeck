import ArkDeckCore
import ArkForgeIPC
import Foundation

/// The device a delegated step was admitted against, carried from the engine
/// to the lane.
///
/// Passed rather than resolved. The engine holds this already — it is the
/// context the step was admitted under — and letting the lane look it up again
/// would allow the two to disagree about which device is under the write,
/// which is the one disagreement that cannot be allowed here.
package struct ArkForgeLaneDeviceBinding: Sendable, Equatable {
  package let connectKey: String
  package let stableIdentitySHA256: String
  package let targetID: String
  package let bindingRevision: Int
  package let usbTopology: String

  package init(
    connectKey: String, stableIdentitySHA256: String, targetID: String,
    bindingRevision: Int, usbTopology: String
  ) {
    self.connectKey = connectKey
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.usbTopology = usbTopology
  }
}

/// Performs the semantic control actions `arkforged` asks for, using the HDC
/// actions ArkDeck kept.
///
/// This is the half of the split ArkDeck alone can do. ArkForge names *what* it
/// needs — "put this device in Loader" — and never receives a connect key, an
/// endpoint, an argv or a server lifecycle; it gets back only what was
/// observed. The mapping table is published by ArkForge's own adapter, and
/// `ArkForgeManagedControlPort` holds the receipt discipline; this type is what
/// actually runs the actions in between.
///
/// # `enterUpdater` is not one command
///
/// It is a command plus two observations, and the observations are the part
/// that matters. Reporting success because `enterLoader` was accepted records a
/// fact about the *message* as a fact about the *device* — which is precisely
/// the mistake the port refuses a receipt for. So this runs the sequence and
/// reports which observations it actually made, letting the port refuse if any
/// is missing rather than deciding for itself that the device moved.
struct ArkForgeControlPerformer: ArkForgeFlashSession.ControlPerformer {

  /// What this performer needs to name the device it is acting on.
  ///
  /// Held rather than taken per call because the binding is what makes an
  /// observation meaningful: "a device rebound in Loader" is not evidence, and
  /// "the bound device rebound in Loader" is.
  struct Binding: Sendable {
    let connectKey: String
    let stableIdentitySHA256: String
    let usbTopology: String
    let descriptor: HostManagedProcessDescriptor
    let rockchipExecutable: ResolvedExecutable

    init(
      connectKey: String, stableIdentitySHA256: String, usbTopology: String,
      descriptor: HostManagedProcessDescriptor, rockchipExecutable: ResolvedExecutable
    ) {
      self.connectKey = connectKey
      self.stableIdentitySHA256 = stableIdentitySHA256
      self.usbTopology = usbTopology
      self.descriptor = descriptor
      self.rockchipExecutable = rockchipExecutable
    }
  }

  enum PerformerError: Error, CustomStringConvertible {
    case unsupported(ArkForgeManagedControlAction)

    var description: String {
      switch self {
      case .unsupported(let action):
        return
          "\(action) is not an action this authority performs; an unknown control action is "
          + "refused rather than mapped to something that looked close"
      }
    }
  }

  private let binding: Binding
  private let host: any RockchipRuntimeActionHosting

  init(binding: Binding, host: any RockchipRuntimeActionHosting) {
    self.binding = binding
    self.host = host
  }

  func perform(
    _ request: ArkForgeManagedControlRequest
  ) async throws -> ArkForgeManagedControlPort.Observation {
    switch request.action {
    case .enterUpdater:
      return try await enterUpdater()
    case .rebootToNormal:
      return try await run(
        .waitForBoundHDCReconnect(
          expectation: RockchipHDCReconnectExpectation(
            previousConnectKey: binding.connectKey,
            previousIdentitySHA256: binding.stableIdentitySHA256,
            usbTopology: binding.usbTopology)))
    case .readProductFacts, .readBuildFacts:
      // The expectation comes from the daemon's request, never from here. An
      // expectation this side invented is one the device is guaranteed to
      // meet, which is the postflight failure AF-011 exists to stop.
      let expected = Dictionary(
        request.expectedFacts.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
      return try await run(
        .verifyBoundBuild(
          expectation: RockchipHDCReconnectExpectation(
            previousConnectKey: binding.connectKey,
            previousIdentitySHA256: binding.stableIdentitySHA256,
            usbTopology: binding.usbTopology),
          expectedProductModel: expected["const.product.model"] ?? "",
          expectedBuildVersion: expected["const.ohos.fullname"] ?? ""))
    case .unspecified:
      // Fail closed. An action this build does not know must not fall through
      // to something that touches the device.
      throw PerformerError.unsupported(request.action)
    }
  }

  /// The five-action sequence, reporting which of the three facts were seen.
  ///
  /// Each step's failure is a failed observation rather than a thrown error,
  /// because a mode change may have taken effect before the step that failed:
  /// the receipt says what was seen and lets the daemon record the rest as
  /// unknown, which is the truthful shape.
  private func enterUpdater() async throws -> ArkForgeManagedControlPort.Observation {
    var facts: [String: String] = [:]
    var observedDisconnect = false
    var observedRebind = false
    var failure = ""

    do {
      _ = try await execute(.observeHDCNormalUSB(connectKey: binding.connectKey))
      _ = try await execute(.enterLoader(connectKey: binding.connectKey))
      _ = try await execute(.waitForHDCDisconnect(connectKey: binding.connectKey))
      observedDisconnect = true
      _ = try await execute(
        .waitForLoader(stableIdentitySHA256: binding.stableIdentitySHA256))
      let rebound = try await execute(
        .rebindLoader(stableIdentitySHA256: binding.stableIdentitySHA256))
      observedRebind = true
      facts = Self.receiptFacts(from: rebound)
    } catch {
      failure = "\(error)"
    }

    return ArkForgeManagedControlPort.Observation(
      accepted: observedDisconnect && observedRebind,
      facts: facts, evidenceSHA256: [], failureReason: failure,
      observedDisconnect: observedDisconnect,
      observedUniqueLoaderRebind: observedRebind)
  }

  private func run(
    _ action: RockchipProviderAction
  ) async throws -> ArkForgeManagedControlPort.Observation {
    do {
      let result = try await execute(action)
      return ArkForgeManagedControlPort.Observation(
        accepted: true, facts: Self.receiptFacts(from: result), evidenceSHA256: [])
    } catch {
      // Not "nothing happened": the action may have taken effect before the
      // failure was seen. The daemon records that as an unknown outcome.
      return ArkForgeManagedControlPort.Observation(
        accepted: false, facts: [:], evidenceSHA256: [], failureReason: "\(error)")
    }
  }

  private func execute(
    _ action: RockchipProviderAction
  ) async throws -> RockchipRuntimeActionExecutionResult {
    try await host.execute(
      action: action, descriptor: binding.descriptor,
      rockchipExecutable: binding.rockchipExecutable)
  }

  /// Keeps only what a receipt may carry.
  ///
  /// The host's summary is ArkDeck's internal vocabulary and includes things
  /// ArkForge must never receive. Rather than filtering the forbidden names —
  /// a denylist that a new summary key silently defeats — this selects the
  /// three the published table declares, so a key nobody reviewed cannot travel
  /// by being added upstream.
  static func receiptFacts(
    from result: RockchipRuntimeActionExecutionResult
  ) -> [String: String] {
    var facts: [String: String] = [:]
    for key in ["mode", "stableIdentitySHA256", "usbTopology"] {
      if let value = result.summary[key] { facts[key] = value }
    }
    // The host names the loader identity differently; map it onto the
    // published key rather than sending both spellings.
    if facts["stableIdentitySHA256"] == nil,
      let identity = result.summary["loaderIdentitySha256"]
    {
      facts["stableIdentitySHA256"] = identity
    }
    if facts["mode"] == nil, result.summary["loaderIdentitySha256"] != nil {
      facts["mode"] = "Loader"
    }
    return facts
  }
}
