import ArkDeckCore
import ArkForgeIPC
import Foundation

/// The archive a delegated step writes, carried from the engine to the lane.
///
/// The engine already resolved and measured this — it is
/// `ProviderExecutionContext.resolvedInputArtifact`, the same bytes ArkDeck's
/// own provider would have written — so the lane is handed it rather than
/// resolving it again. Two resolutions could disagree about which image is
/// under the write, which is not a disagreement worth having.
///
/// `profileID` is the daemon's key for the DeviceProfile, not a path: the
/// daemon loaded its profiles at startup and `materializePlan` looks one up by
/// the id it declared.
package struct ArkForgeLaneArtifact: Sendable, Equatable {
  package let fileURL: URL
  package let sha256: String
  package let profileID: String

  package init(fileURL: URL, sha256: String, profileID: String) {
    self.fileURL = fileURL
    self.sha256 = sha256
    self.profileID = profileID
  }
}

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
  ///
  /// These are descriptor *ingredients*, not a descriptor. The host validates
  /// each action against a descriptor pinning that action's own identifier and
  /// canonical digest, so one prebuilt descriptor can satisfy at most one of
  /// the actions a control sequence runs — the previous shape here carried
  /// exactly that, and the host refused every call it was ever given. The
  /// performer now materializes a fresh descriptor per action through the same
  /// catalog materialization uses.
  struct Binding: Sendable {
    let jobID: String
    let targetID: String
    let bindingRevision: Int
    let connectKey: String
    let stableIdentitySHA256: String
    let usbTopology: String
    let rockchipExecutable: ResolvedExecutable

    init(
      jobID: String, targetID: String, bindingRevision: Int,
      connectKey: String, stableIdentitySHA256: String, usbTopology: String,
      rockchipExecutable: ResolvedExecutable
    ) {
      self.jobID = jobID
      self.targetID = targetID
      self.bindingRevision = bindingRevision
      self.connectKey = connectKey
      self.stableIdentitySHA256 = stableIdentitySHA256
      self.usbTopology = usbTopology
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
      return try await enterUpdater(request: request)
    case .rebootToNormal:
      return try await run(
        .waitForBoundHDCReconnect(expectation: reconnectExpectation()),
        request: request, index: 0)
    case .readProductFacts, .readBuildFacts:
      // The expectation comes from the daemon's request, never from here. An
      // expectation this side invented is one the device is guaranteed to
      // meet, which is the postflight failure AF-011 exists to stop.
      let expected = Dictionary(
        request.expectedFacts.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
      return try await run(
        .verifyBoundBuild(
          expectation: reconnectExpectation(),
          expectedProductModel: expected["const.product.model"] ?? "",
          expectedBuildVersion: expected["const.ohos.fullname"] ?? ""),
        request: request, index: 0)
    case .unspecified:
      // Fail closed. An action this build does not know must not fall through
      // to something that touches the device.
      throw PerformerError.unsupported(request.action)
    }
  }

  /// The reconnect expectation for the bound device, in the HDC alias
  /// identity namespace.
  ///
  /// `waitForBoundHDC` requires `previousIdentitySHA256 ==
  /// SHA256(previousConnectKey)` — the HDC-normal *alias* digest. The stable
  /// target identity this binding also carries is a different namespace (it
  /// derives from the Loader serial), and passing it here failed the whole
  /// postflight as "binding expectation is malformed" on the first run that
  /// ever reached it. The alias digest is computed from the admitted connect
  /// key, which is exactly the invariant the guard checks.
  private func reconnectExpectation() -> RockchipHDCReconnectExpectation {
    RockchipHDCReconnectExpectation(
      previousConnectKey: binding.connectKey,
      previousIdentitySHA256: SHA256Hex.string(of: Data(binding.connectKey.utf8)),
      usbTopology: binding.usbTopology)
  }

  /// The five-action sequence, reporting which of the three facts were seen.
  ///
  /// Each step's failure is a failed observation rather than a thrown error,
  /// because a mode change may have taken effect before the step that failed:
  /// the receipt says what was seen and lets the daemon record the rest as
  /// unknown, which is the truthful shape.
  private func enterUpdater(
    request: ArkForgeManagedControlRequest
  ) async throws -> ArkForgeManagedControlPort.Observation {
    var facts: [String: String] = [:]
    var observedDisconnect = false
    var observedRebind = false
    var failure = ""

    do {
      _ = try await execute(
        .observeHDCNormalUSB(connectKey: binding.connectKey), request: request, index: 0)
      _ = try await execute(
        .enterLoader(connectKey: binding.connectKey), request: request, index: 1)
      _ = try await execute(
        .waitForHDCDisconnect(connectKey: binding.connectKey), request: request, index: 2)
      observedDisconnect = true
      _ = try await execute(
        .waitForLoader(stableIdentitySHA256: binding.stableIdentitySHA256),
        request: request, index: 3)
      let rebound = try await execute(
        .rebindLoader(stableIdentitySHA256: binding.stableIdentitySHA256),
        request: request, index: 4)
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
    _ action: RockchipProviderAction,
    request: ArkForgeManagedControlRequest,
    index: Int
  ) async throws -> ArkForgeManagedControlPort.Observation {
    do {
      let result = try await execute(action, request: request, index: index)
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
    _ action: RockchipProviderAction,
    request: ArkForgeManagedControlRequest,
    index: Int
  ) async throws -> RockchipRuntimeActionExecutionResult {
    // A fresh descriptor per action, through the same catalog materialization
    // uses, because the host validates identifier and canonical action digest
    // per action — one descriptor cannot vouch for five different actions.
    let descriptor = try RockchipHostManagedActionCatalog.descriptor(
      for: action,
      jobID: binding.jobID,
      stepID: Self.recordStepID(for: request, index: index),
      targetID: binding.targetID,
      bindingRevision: binding.bindingRevision,
      connectKey: binding.connectKey,
      expectedIdentitySHA256: binding.stableIdentitySHA256,
      providerExecutableSHA256: binding.rockchipExecutable.sha256,
      executionTuning: nil)
    return try await host.execute(
      action: action, descriptor: descriptor,
      rockchipExecutable: binding.rockchipExecutable)
  }

  /// The record-store step id for one action of one control request.
  ///
  /// The store keys durable action records by `jobID/stepID` and refuses a
  /// second, different intent under the same key — correct for plan steps,
  /// where a resume must replay the recorded result, and exactly why a control
  /// sequence cannot reuse one id for five actions. The daemon's `requestID`
  /// is unique per control attempt, so folding its digest in gives every
  /// attempt fresh records while a crash-and-repeat of the *same* attempt
  /// still replays. Digested rather than embedded because the id must stay a
  /// bounded path component whatever the daemon put in the string.
  static func recordStepID(
    for request: ArkForgeManagedControlRequest, index: Int
  ) -> String {
    let attempt = SHA256Hex.string(of: Data(request.requestID.utf8)).prefix(12)
    return "\(request.stepID)-mc-\(attempt)-a\(index)"
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
    // The verification host answers in its own vocabulary (`model`,
    // `firmware`); the receipt's published table speaks the device's property
    // names. Without this mapping the first postflight that ever verified a
    // real device was refused by the port as a success without its evidence
    // (measured 2026-08-18) — the fact was in hand under the wrong name.
    if let model = result.summary["model"] {
      facts["const.product.model"] = model
    }
    if let firmware = result.summary["firmware"] {
      facts["const.ohos.fullname"] = firmware
    }
    return facts
  }
}
