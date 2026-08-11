import ArkDeckCore
import CryptoKit
import Foundation

/// Redacted, read-only relationship between the DAYU200 personality currently
/// present on USB and Runtime's durable target/binding facts. The raw serial,
/// topology and their digest never cross this boundary.
public enum RockchipBootloaderBindingDisposition: String, Sendable, Equatable {
  case absent
  case ambiguous
  case exactBoundTarget
  case targetBindingUnprepared
  case unbound
}

public struct RockchipBootloaderStatus: Sendable, Equatable {
  public let disposition: RockchipBootloaderBindingDisposition
  public let observationCount: Int
  public let mode: String?
  public let targetID: String?
  public let bindingRevision: Int?

  public init(
    disposition: RockchipBootloaderBindingDisposition,
    observationCount: Int,
    mode: String?,
    targetID: String?,
    bindingRevision: Int?
  ) {
    self.disposition = disposition
    self.observationCount = observationCount
    self.mode = mode
    self.targetID = targetID
    self.bindingRevision = bindingRevision
  }
}

public protocol RockchipBootloaderStatusObserving: Sendable {
  func observeBootloaderStatus() throws -> RockchipBootloaderStatus
}

/// Product composition backed only by IOKit and owner-only durable stores.
/// It cannot spawn a process, dispatch a device effect, adopt a target or
/// advance a binding.
public struct ProductRockchipBootloaderStatusObserver:
  RockchipBootloaderStatusObserving, Sendable
{
  private let targetStore: RuntimeTargetStore
  private let bindingStore: RockchipProductBindingStore
  private let postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore
  private let usbProbe: RockchipProductUSBProbe

  public init(targetStore: RuntimeTargetStore, applicationSupportRoot: URL) {
    self.targetStore = targetStore
    self.bindingStore = RockchipProductBindingStore(rootURL: applicationSupportRoot)
    self.postFlashHDCBindingStore = RockchipPostFlashHDCBindingStore(
      rootURL: applicationSupportRoot)
    self.usbProbe = RockchipProductUSBProbe()
  }

  init(
    targetStore: RuntimeTargetStore,
    bindingStore: RockchipProductBindingStore,
    postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore? = nil,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.targetStore = targetStore
    self.bindingStore = bindingStore
    self.postFlashHDCBindingStore = postFlashHDCBindingStore
      ?? RockchipPostFlashHDCBindingStore(rootURL: bindingStore.rootURL)
    self.usbProbe = usbProbe
  }

  public func observeBootloaderStatus() throws -> RockchipBootloaderStatus {
    let identities = try usbProbe.registeredDAYU200Identities()
    guard identities.count == 1, let identity = identities.first else {
      return RockchipBootloaderStatus(
        disposition: identities.isEmpty ? .absent : .ambiguous,
        observationCount: identities.count,
        mode: nil,
        targetID: nil,
        bindingRevision: nil)
    }

    let digest = SHA256Hex.string(of: Data(identity.serial.utf8))
    let binding = try bindingStore.loadIfPresent()
    if identity.isHDCNormal,
      let binding,
      let routed = try postFlashHDCBindingStore.loadIfPresent(),
      let target = try targetStore.find(targetID: routed.targetID),
      try routed.covers(target: target, binding: binding),
      routed.hdcIdentitySHA256 == digest,
      routed.usbTopology == identity.topology
    {
      guard
        try !targetStore.hasConflictingHDCAliasOwner(
          canonicalTargetID: target.targetID,
          connectKey: routed.hdcConnectKey,
          identitySHA256: routed.hdcIdentitySHA256,
          establishingFlashJobID: routed.jobID)
      else {
        return RockchipBootloaderStatus(
          disposition: .ambiguous,
          observationCount: 1,
          mode: Self.mode(of: identity),
          targetID: nil,
          bindingRevision: nil)
      }
      return RockchipBootloaderStatus(
        disposition: .exactBoundTarget,
        observationCount: 1,
        mode: Self.mode(of: identity),
        targetID: target.targetID,
        bindingRevision: target.bindingRevision)
    }
    let matchingTargets = try targetStore.list().filter {
      $0.stablePhysicalIdentitySHA256 == digest
    }
    guard matchingTargets.count <= 1 else {
      return RockchipBootloaderStatus(
        disposition: .ambiguous,
        observationCount: 1,
        mode: Self.mode(of: identity),
        targetID: nil,
        bindingRevision: nil)
    }
    guard let target = matchingTargets.first else {
      return RockchipBootloaderStatus(
        disposition: .unbound,
        observationCount: 1,
        mode: Self.mode(of: identity),
        targetID: nil,
        bindingRevision: nil)
    }

    let covered: Bool
    if let binding {
      do {
        covered = try binding.coversRuntimeTarget(target)
          && binding.matchesConfirmedLiveIdentity(identity)
      } catch {
        // A decoded historical or otherwise incomplete binding is a safe,
        // actionable onboarding state. Do not turn it into an RPC failure and
        // do not claim it covers the live target.
        covered = false
      }
    } else {
      covered = false
    }
    return RockchipBootloaderStatus(
      disposition: covered ? .exactBoundTarget : .targetBindingUnprepared,
      observationCount: 1,
      mode: Self.mode(of: identity),
      targetID: target.targetID,
      bindingRevision: target.bindingRevision)
  }

  private static func mode(of identity: RockchipProductUSBIdentity) -> String? {
    if identity.isLoader { return "loader" }
    if identity.isHDCNormal { return "hdcNormal" }
    return nil
  }
}

public struct RockchipLoaderBindingReceipt: Sendable, Equatable {
  public let targetID: String
  public let previousRevision: Int
  public let currentRevision: Int
  public let updated: Bool
  public let selectionEvidenceSHA256: String

  public init(
    targetID: String,
    previousRevision: Int,
    currentRevision: Int,
    updated: Bool,
    selectionEvidenceSHA256: String
  ) {
    self.targetID = targetID
    self.previousRevision = previousRevision
    self.currentRevision = currentRevision
    self.updated = updated
    self.selectionEvidenceSHA256 = selectionEvidenceSHA256
  }
}

public protocol RockchipLoaderBindingCoordinating: Sendable {
  func bindCurrentLoader(
    targetID: String,
    expectedBindingRevision: Int
  ) throws -> RockchipLoaderBindingReceipt
}

/// Runtime-owned proof that an already-adopted target's latest Loader binding
/// was previously used with one exact HDC route. The proof is reconstructed
/// only from correlated owner-only typed intents/receipts; it is not an App or
/// caller assertion and it never claims that a missing adjacent lineage edge
/// was persisted.
package struct RockchipBindingReactivationProof: Sendable, Equatable {
  package let targetID: String
  package let bindingRevision: Int
  package let stableLoaderIdentitySHA256: String
  package let hdcConnectKey: String
  package let hdcIdentitySHA256: String
  package let hdcUSBTopology: String
  package let currentBindingIntentSHA256: String
  package let hdcRouteReceiptSHA256: String

  package init(
    targetID: String,
    bindingRevision: Int,
    stableLoaderIdentitySHA256: String,
    hdcConnectKey: String,
    hdcIdentitySHA256: String,
    hdcUSBTopology: String,
    currentBindingIntentSHA256: String,
    hdcRouteReceiptSHA256: String
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableLoaderIdentitySHA256 = stableLoaderIdentitySHA256
    self.hdcConnectKey = hdcConnectKey
    self.hdcIdentitySHA256 = hdcIdentitySHA256
    self.hdcUSBTopology = hdcUSBTopology
    self.currentBindingIntentSHA256 = currentBindingIntentSHA256
    self.hdcRouteReceiptSHA256 = hdcRouteReceiptSHA256
  }
}

package protocol RockchipBindingReactivationProving: Sendable {
  func proof(
    for target: RuntimeTargetRecord
  ) throws -> RockchipBindingReactivationProof?
}

/// Runtime-owned DAYU200 onboarding. The caller selects only an already
/// adopted target and its expected revision; Runtime obtains every candidate
/// identity/topology fact afresh, applies Core's manual USB rebind policy, and
/// either activates an exact revision-1 target or advances the same target's
/// HDC-to-Loader lineage.
public struct ProductRockchipLoaderBindingCoordinator:
  RockchipLoaderBindingCoordinating, Sendable
{
  private let targetStore: RuntimeTargetStore
  private let bindingStore: RockchipProductBindingStore
  private let usbProbe: RockchipProductUSBProbe
  private let reactivationProofSource: any RockchipBindingReactivationProving

  public init(targetStore: RuntimeTargetStore, applicationSupportRoot: URL) {
    self.targetStore = targetStore
    self.bindingStore = RockchipProductBindingStore(rootURL: applicationSupportRoot)
    self.usbProbe = RockchipProductUSBProbe()
    self.reactivationProofSource = RockchipRuntimeBindingReactivationProofSource(
      rootURL: applicationSupportRoot
        .appendingPathComponent("Agentd", isDirectory: true)
        .appendingPathComponent("rockchip-runtime", isDirectory: true))
  }

  init(
    targetStore: RuntimeTargetStore,
    bindingStore: RockchipProductBindingStore,
    usbProbe: RockchipProductUSBProbe,
    reactivationProofSource: (any RockchipBindingReactivationProving)? = nil
  ) {
    self.targetStore = targetStore
    self.bindingStore = bindingStore
    self.usbProbe = usbProbe
    self.reactivationProofSource = reactivationProofSource
      ?? RockchipRuntimeBindingReactivationProofSource(
        rootURL: bindingStore.rootURL
          .appendingPathComponent("Agentd", isDirectory: true)
          .appendingPathComponent("rockchip-runtime", isDirectory: true))
  }

  public func bindCurrentLoader(
    targetID: String,
    expectedBindingRevision: Int
  ) throws -> RockchipLoaderBindingReceipt {
    guard !targetID.isEmpty, expectedBindingRevision > 0,
      let target = try targetStore.find(targetID: targetID),
      target.bindingRevision == expectedBindingRevision
        || target.bindingRevision == expectedBindingRevision + 1
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "selected target or binding revision is stale")
    }
    let identities = try usbProbe.registeredDAYU200Identities()
    guard identities.count == 1, let identity = identities.first,
      identity.isRegisteredDAYU200Mode
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "exactly one registered DAYU200 USB identity is required for binding")
    }
    let currentIdentity = SHA256Hex.string(of: Data(identity.serial.utf8))
    let existing = try bindingStore.loadExisting()
    let existingIdentity = SHA256Hex.string(of: Data(existing.serial.utf8))

    // A newly adopted board can coexist with an older board's singleton
    // active binding. Selecting that exact revision-1 target in the App is
    // the explicit switch: Runtime still requires one fresh USB identity,
    // exact target identity/connect-key equality, and a unique target record.
    // Historical same-identity bindings are deliberately excluded and remain
    // byte-for-byte unprepared as required by the compatibility contract.
    if target.bindingRevision == expectedBindingRevision,
      target.bindingRevision == 1,
      currentIdentity != existingIdentity,
      currentIdentity == target.stablePhysicalIdentitySHA256
    {
      let connectIdentity = SHA256Hex.string(of: Data(target.connectKey.utf8))
      let matchingTargets = try targetStore.list().filter {
        $0.bindingRevision == 1
          && $0.stablePhysicalIdentitySHA256 == currentIdentity
      }
      guard connectIdentity == currentIdentity,
        matchingTargets.map(\.targetID) == [targetID]
      else {
        throw RockchipFlashExecutionError.admissionRejected(
          "selected target does not uniquely match the current DAYU200 identity")
      }

      try Self.authorizeSelectedTarget(identity: identity, currentIdentity: currentIdentity)
      let selectionDigest = Self.selectionDigest(
        targetID: targetID,
        previousRevision: existing.revision,
        currentRevision: target.bindingRevision,
        previousIdentity: existingIdentity,
        currentIdentity: currentIdentity,
        currentTopology: identity.topology)
      let next = RockchipProductBindingSnapshot(
        revision: target.bindingRevision,
        serial: identity.serial,
        usbTopology: identity.topology,
        evidence: [
          "product:e0-iokit-single-dayu200-readback",
          "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
          "identity:serial-sha256=\(currentIdentity)",
          "binding:selected-target-id=\(targetID)",
          "binding:replaced-active-revision=\(existing.revision)",
          "identity:replaced-active-serial-sha256=\(existingIdentity)",
          "rebind:user-selection-sha256=\(selectionDigest)",
        ])
      let stored = try bindingStore.activateSelectedInitialTarget(
        expectedRevision: existing.revision,
        expectedSerialSHA256: existingIdentity,
        with: next)
      guard try stored.coversRuntimeTarget(target),
        try stored.matchesConfirmedLiveIdentity(identity)
      else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "selected target activation did not cover the fresh DAYU200 identity")
      }
      return RockchipLoaderBindingReceipt(
        targetID: targetID,
        previousRevision: target.bindingRevision,
        currentRevision: target.bindingRevision,
        updated: true,
        selectionEvidenceSHA256: selectionDigest)
    }

    if target.bindingRevision == expectedBindingRevision,
      existing.revision == expectedBindingRevision,
      existingIdentity == target.stablePhysicalIdentitySHA256,
      currentIdentity == existingIdentity,
      identity.topology == existing.usbTopology
    {
      let alreadyCovered = (try? existing.coversRuntimeTarget(target)) == true
        && (try? existing.matchesConfirmedLiveIdentity(identity)) == true
      let initialSelections = existing.evidence.compactMap { value -> String? in
        let prefix = "rebind:user-selection-sha256="
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
      }
      if alreadyCovered,
        existing.revision == 1,
        existing.evidence.contains("binding:selected-target-id=\(targetID)"),
        initialSelections.count == 1,
        let selection = initialSelections.first,
        RockchipStandingAuthorization.isCanonicalSHA256(selection)
      {
        return RockchipLoaderBindingReceipt(
          targetID: targetID,
          previousRevision: expectedBindingRevision,
          currentRevision: expectedBindingRevision,
          updated: false,
          selectionEvidenceSHA256: selection)
      }
      if alreadyCovered,
        let proof = try existing.loaderBindingRecoveryProof(),
        proof.currentRevision == expectedBindingRevision
      {
        return RockchipLoaderBindingReceipt(
          targetID: targetID,
          previousRevision: expectedBindingRevision,
          currentRevision: expectedBindingRevision,
          updated: false,
          selectionEvidenceSHA256: proof.selectionEvidenceSHA256)
      }
      if alreadyCovered,
        let selection = try existing.reactivationSelectionEvidence(targetID: targetID)
      {
        return RockchipLoaderBindingReceipt(
          targetID: targetID,
          previousRevision: expectedBindingRevision,
          currentRevision: expectedBindingRevision,
          updated: false,
          selectionEvidenceSHA256: selection)
      }

      throw RockchipFlashExecutionError.admissionRejected(
        "selected Loader binding does not carry current Runtime attestation")
    }

    guard identity.isLoader else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the selected HDC-normal target has no active cross-mode binding")
    }

    // Switching the singleton binding away from an already-advanced target
    // used to make that target permanently unselectable even when its exact
    // Loader returned. Reactivation is not a legacy-binding migration: the
    // old binding bytes are absent and are never guessed. Runtime instead
    // requires (1) one fresh exact Loader, (2) one unique current target, and
    // (3) correlated owner-only typed history proving that this same target,
    // revision and Loader identity previously carried the retained HDC route.
    if target.bindingRevision == expectedBindingRevision,
      target.bindingRevision > 1,
      currentIdentity != existingIdentity,
      currentIdentity == target.stablePhysicalIdentitySHA256
    {
      _ = try existing.runtimeTargetLineageAdvance()
      let matchingTargets = try targetStore.list().filter {
        $0.bindingRevision == target.bindingRevision
          && $0.stablePhysicalIdentitySHA256 == currentIdentity
      }
      guard matchingTargets.map(\.targetID) == [targetID],
        let proof = try reactivationProofSource.proof(for: target)
      else {
        throw RockchipFlashExecutionError.admissionRejected(
          "selected historical target has no complete Runtime reactivation proof")
      }
      let connectIdentity = SHA256Hex.string(of: Data(target.connectKey.utf8))
      guard proof.targetID == targetID,
        proof.bindingRevision == target.bindingRevision,
        proof.stableLoaderIdentitySHA256 == currentIdentity,
        proof.hdcConnectKey == target.connectKey,
        proof.hdcIdentitySHA256 == connectIdentity,
        RockchipStandingAuthorization.isCanonicalSHA256(
          proof.currentBindingIntentSHA256),
        RockchipStandingAuthorization.isCanonicalSHA256(
          proof.hdcRouteReceiptSHA256),
        !proof.hdcUSBTopology.isEmpty,
        proof.hdcUSBTopology.utf8.allSatisfy({ (48...57).contains($0) })
      else {
        throw RockchipFlashExecutionError.admissionRejected(
          "selected historical target Runtime proof does not match its current binding")
      }

      try Self.authorizeSelectedTarget(identity: identity, currentIdentity: currentIdentity)
      let selectionDigest = Self.selectionDigest(
        targetID: targetID,
        previousRevision: existing.revision,
        currentRevision: target.bindingRevision,
        previousIdentity: existingIdentity,
        currentIdentity: currentIdentity,
        currentTopology: identity.topology)
      let next = RockchipProductBindingSnapshot(
        revision: target.bindingRevision,
        serial: identity.serial,
        usbTopology: identity.topology,
        evidence: [
          "product:e0-iokit-single-loader-readback",
          "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
          "identity:serial-sha256=\(currentIdentity)",
          "identity:hdc-normal-alias-sha256=\(proof.hdcIdentitySHA256)",
          "binding:hdc-normal-alias-usb-topology=\(proof.hdcUSBTopology)",
          "binding:reactivated-target-id=\(targetID)",
          "binding:reactivation-current-intent-sha256=\(proof.currentBindingIntentSHA256)",
          "binding:reactivation-route-receipt-sha256=\(proof.hdcRouteReceiptSHA256)",
          "binding:replaced-active-revision=\(existing.revision)",
          "identity:replaced-active-serial-sha256=\(existingIdentity)",
          "rebind:user-selection-sha256=\(selectionDigest)",
        ])
      let stored = try bindingStore.activateSelectedTarget(
        expectedRevision: existing.revision,
        expectedSerialSHA256: existingIdentity,
        with: next)
      guard try stored.coversRuntimeTarget(target),
        try stored.matchesConfirmedLiveIdentity(identity),
        try stored.confirmedHDCNormalAlias()?.identitySHA256 == connectIdentity
      else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "reactivated target binding did not cover its fresh Loader and durable HDC route")
      }
      return RockchipLoaderBindingReceipt(
        targetID: targetID,
        previousRevision: target.bindingRevision,
        currentRevision: target.bindingRevision,
        updated: true,
        selectionEvidenceSHA256: selectionDigest)
    }

    if target.bindingRevision == expectedBindingRevision + 1,
      existing.revision == target.bindingRevision,
      currentIdentity == target.stablePhysicalIdentitySHA256,
      try existing.coversRuntimeTarget(target),
      try existing.matchesConfirmedLiveIdentity(identity),
      let lineage = try existing.runtimeTargetLineageAdvance()
    {
      let evidence = Self.selectionDigest(
        targetID: targetID,
        previousRevision: expectedBindingRevision,
        currentRevision: target.bindingRevision,
        previousIdentity: lineage.previousStableIdentitySHA256,
        currentIdentity: currentIdentity,
        currentTopology: identity.topology)
      return RockchipLoaderBindingReceipt(
        targetID: targetID,
        previousRevision: expectedBindingRevision,
        currentRevision: target.bindingRevision,
        updated: false,
        selectionEvidenceSHA256: evidence)
    }

    guard target.bindingRevision == expectedBindingRevision,
      existing.revision == expectedBindingRevision,
      existingIdentity == target.stablePhysicalIdentitySHA256,
      currentIdentity != existingIdentity,
      let hdcAlias = try existing.confirmedHDCNormalAlias()
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "selected target has no migratable HDC-to-Loader binding lineage")
    }
    let targetConnectIdentity = SHA256Hex.string(of: Data(target.connectKey.utf8))
    guard targetConnectIdentity == hdcAlias.identitySHA256 else {
      throw RockchipFlashExecutionError.admissionRejected(
        "selected target connect key does not match its durable HDC-normal alias")
    }
    let matchingLineageTargets = try targetStore.list().filter {
      $0.bindingRevision == expectedBindingRevision
        && $0.stablePhysicalIdentitySHA256 == existingIdentity
    }
    guard matchingLineageTargets.map(\.targetID) == [targetID] else {
      throw RockchipFlashExecutionError.admissionRejected(
        "selected target binding lineage is missing or ambiguous")
    }

    try Self.authorizeSelectedTarget(identity: identity, currentIdentity: currentIdentity)

    let nextRevision = expectedBindingRevision + 1
    let selectionDigest = Self.selectionDigest(
      targetID: targetID,
      previousRevision: expectedBindingRevision,
      currentRevision: nextRevision,
      previousIdentity: existingIdentity,
      currentIdentity: currentIdentity,
      currentTopology: identity.topology)
    let next = RockchipProductBindingSnapshot(
      revision: nextRevision,
      serial: identity.serial,
      usbTopology: identity.topology,
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(currentIdentity)",
        "identity:previous-serial-sha256=\(existingIdentity)",
        "binding:previous-revision=\(expectedBindingRevision)",
        "binding:previous-usb-topology=\(existing.usbTopology)",
        "identity:hdc-normal-alias-sha256=\(hdcAlias.identitySHA256)",
        "binding:hdc-normal-alias-usb-topology=\(hdcAlias.usbTopology)",
        "rebind:user-selection-sha256=\(selectionDigest)",
      ])
    let stored = try bindingStore.replace(
      expectedRevision: expectedBindingRevision,
      expectedSerialSHA256: existingIdentity,
      with: next)
    guard let advance = try stored.runtimeTargetLineageAdvance() else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "persisted Loader binding did not produce an adjacent target advance")
    }
    let advanced = try targetStore.advanceBindingLineage(advance)
    guard advanced.record.targetID == targetID,
      advanced.record.bindingRevision == nextRevision,
      advanced.record.stablePhysicalIdentitySHA256 == currentIdentity
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "Runtime target did not advance to the persisted Loader binding")
    }
    return RockchipLoaderBindingReceipt(
      targetID: targetID,
      previousRevision: expectedBindingRevision,
      currentRevision: nextRevision,
      updated: true,
      selectionEvidenceSHA256: selectionDigest)
  }

  private static func selectionDigest(
    targetID: String,
    previousRevision: Int,
    currentRevision: Int,
    previousIdentity: String,
    currentIdentity: String,
    currentTopology: String
  ) -> String {
    SHA256Hex.string(of: Data([
      "rockchip-loader-user-selection",
      targetID,
      String(previousRevision),
      String(currentRevision),
      previousIdentity,
      currentIdentity,
      currentTopology,
    ].joined(separator: "\n").utf8))
  }

  private static func authorizeSelectedTarget(
    identity: RockchipProductUSBIdentity,
    currentIdentity: String
  ) throws {
    let mode = identity.isLoader ? "loader" : "hdc-normal"
    let candidateID = "dayu200-\(mode)-\(currentIdentity.prefix(12))"
    let candidateEvidence = [
      "product:e0-iokit-single-dayu200-readback",
      "identity:serial-sha256=\(currentIdentity)",
      "binding:usb-topology=\(identity.topology)",
      "mode:\(mode)",
    ]
    let snapshot = try DeviceIdentitySnapshot(attributes: [
      "serial": .string(identity.serial),
      "usbTopology": .string(identity.topology),
      "mode": .string(mode),
    ])
    let candidate = try DeviceRebindCandidate(
      candidateID: candidateID,
      connectKey: identity.topology,
      transport: .usb,
      identitySnapshot: snapshot,
      evidence: candidateEvidence,
      usbEvidence: USBRebindEvidence(
        serialMatches: false,
        daemonFingerprintMatches: false,
        topologyMatches: false,
        expectedModeMatches: true,
        modelBuildMatches: false))
    let context = DeviceRebindContext(
      transport: .usb,
      disconnected: true,
      endpointExplicitlyAdded: true,
      expectedModeTransition: true,
      candidates: [candidate],
      userConfirmedCandidateID: candidateID)
    try DeviceRebindPolicy.authorizePersistence(
      context: context, selectedCandidate: candidate, confirmedBy: .user)
  }
}
