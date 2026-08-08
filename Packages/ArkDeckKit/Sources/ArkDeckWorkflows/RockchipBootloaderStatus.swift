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
  private let usbProbe: RockchipProductUSBProbe

  public init(targetStore: RuntimeTargetStore, applicationSupportRoot: URL) {
    self.targetStore = targetStore
    self.bindingStore = RockchipProductBindingStore(rootURL: applicationSupportRoot)
    self.usbProbe = RockchipProductUSBProbe()
  }

  init(
    targetStore: RuntimeTargetStore,
    bindingStore: RockchipProductBindingStore,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.targetStore = targetStore
    self.bindingStore = bindingStore
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

    let digest = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
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

    let binding = try bindingStore.loadIfPresent()
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

/// Runtime-owned Loader onboarding. The caller selects only an already
/// adopted target and its expected revision; Runtime obtains every candidate
/// identity/topology fact afresh, applies Core's manual USB rebind policy,
/// persists the owner binding, then advances the generic target store.
public struct ProductRockchipLoaderBindingCoordinator:
  RockchipLoaderBindingCoordinating, Sendable
{
  private let targetStore: RuntimeTargetStore
  private let bindingStore: RockchipProductBindingStore
  private let usbProbe: RockchipProductUSBProbe

  public init(targetStore: RuntimeTargetStore, applicationSupportRoot: URL) {
    self.targetStore = targetStore
    self.bindingStore = RockchipProductBindingStore(rootURL: applicationSupportRoot)
    self.usbProbe = RockchipProductUSBProbe()
  }

  init(
    targetStore: RuntimeTargetStore,
    bindingStore: RockchipProductBindingStore,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.targetStore = targetStore
    self.bindingStore = bindingStore
    self.usbProbe = usbProbe
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
    guard identities.count == 1, let identity = identities.first, identity.isLoader else {
      throw RockchipFlashExecutionError.admissionRejected(
        "exactly one DAYU200 Loader is required for binding")
    }
    let currentIdentity = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let existing = try bindingStore.loadExisting()
    let existingIdentity = SHA256.hash(data: Data(existing.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()

    if target.bindingRevision == expectedBindingRevision,
      existing.revision == expectedBindingRevision,
      existingIdentity == target.stablePhysicalIdentitySHA256,
      currentIdentity == existingIdentity,
      identity.topology == existing.usbTopology
    {
      let alreadyCovered = (try? existing.coversRuntimeTarget(target)) == true
        && (try? existing.matchesConfirmedLiveIdentity(identity)) == true
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

      throw RockchipFlashExecutionError.admissionRejected(
        "selected Loader binding does not carry current Runtime attestation")
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
    let targetConnectIdentity = SHA256.hash(data: Data(target.connectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
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

    try Self.authorizeSelectedLoader(identity: identity, currentIdentity: currentIdentity)

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
    SHA256.hash(data: Data([
      "rockchip-loader-user-selection",
      targetID,
      String(previousRevision),
      String(currentRevision),
      previousIdentity,
      currentIdentity,
      currentTopology,
    ].joined(separator: "\n").utf8))
    .map { String(format: "%02x", $0) }.joined()
  }

  private static func authorizeSelectedLoader(
    identity: RockchipProductUSBIdentity,
    currentIdentity: String
  ) throws {
    let candidateID = "loader-\(currentIdentity.prefix(12))"
    let candidateEvidence = [
      "product:e0-iokit-single-loader-readback",
      "identity:serial-sha256=\(currentIdentity)",
      "binding:usb-topology=\(identity.topology)",
      "mode:loader",
    ]
    let snapshot = try DeviceIdentitySnapshot(attributes: [
      "serial": .string(identity.serial),
      "usbTopology": .string(identity.topology),
      "mode": .string("loader"),
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
