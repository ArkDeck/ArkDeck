import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import IOKit

package struct RockchipDeviceBindingInstallationReceipt: Sendable, Equatable {
  public let revision: Int
  package let usbTopology: String
  package let serialDigestSHA256: String
  public let created: Bool

  public init(
    revision: Int,
    usbTopology: String,
    serialDigestSHA256: String,
    created: Bool
  ) {
    self.revision = revision
    self.usbTopology = usbTopology
    self.serialDigestSHA256 = serialDigestSHA256
    self.created = created
  }
}

package enum RockchipDeviceBindingInstallation {
  /// Reads IOKit only, requires exactly one DAYU200 in registered HDC-normal or Loader mode,
  /// and durably adopts that cross-mode identity.  The HDC-normal branch does not reboot here:
  /// the transition remains inside the later authorized `enterUpdater` intent.
  /// This entry point performs no RockUSB process launch and has no device-mutation surface.
  @discardableResult
  package static func installCurrentTarget(
    rebind: Bool = false
  ) throws -> RockchipDeviceBindingInstallationReceipt {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    return try RockchipProductBindingBootstrap(
      probe: { try RockchipProductUSBProbe().singleDAYU200() },
      store: RockchipProductBindingStore(rootURL: root)
    ).installCurrentTarget(rebind: rebind)
  }
}

/// Protected-main HDC tuple already registered by the Rockchip Loader-transition integration.
/// It is deliberately not configurable by CLI/environment/PATH.
enum RockchipHDCIntegrationProfile {
  static let executableURL = URL(
    filePath:
      "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
  static let executableSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  static let reportedVersion = "3.2.0f"
  static let dayu200NormalProductID: UInt16 = 0x5000
  static let postFlashBuildPropertiesCommand =
    "param get \(HDCAllowlistedProperty.fullBuildVersion.rawValue); "
    + "param get \(HDCAllowlistedProperty.productModel.rawValue)"

  static func enterLoaderArguments(connectKey: String) -> [String] {
    // DAYU200's board support and measured hardware path use the device-side
    // reboot command. It reaches RockUSB Loader in about four seconds; HDC's
    // generic `target boot loader` path takes about seventeen seconds on the
    // same RK3568 board. Every token after `shell` is fixed here — neither a
    // request nor a Profile can inject command text — and `-t` preserves the
    // exact connect-key selection when another HDC target is present.
    ["-t", connectKey, "shell", "reboot", "loader"]
  }
}

package struct RockchipProductBindingSnapshot: Codable, Sendable, Equatable {
  package let revision: Int
  package let serial: String
  let usbTopology: String
  let evidence: [String]

  /// Converts the owner-only Rockchip rebind evidence into the one adjacent
  /// edge the generic Runtime target store may apply. Revision 1 has no edge
  /// to apply. Later revisions must carry one unambiguous previous identity,
  /// previous revision/topology and the Runtime user-selection digest;
  /// incomplete or invented lineage never reaches the target store.
  package func runtimeTargetLineageAdvance()
    throws -> RuntimeTargetBindingLineageAdvance?
  {
    let currentIdentity = SHA256Hex.string(of: Data(serial.utf8))
    let currentIdentities = values(prefix: "identity:serial-sha256=")
    guard currentIdentities == [currentIdentity] else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding current identity evidence is missing or ambiguous")
    }
    // A same-revision reactivation never invents or reapplies an adjacent
    // target-store edge. Its complete proof is a different closed evidence
    // shape: one exact target plus correlated Runtime intent/route receipt.
    // Validate that shape before returning nil so malformed reactivation
    // bytes cannot become useful merely because the live Loader matches.
    if try reactivationEvidence() != nil { return nil }
    if revision == 1 { return nil }

    let previousIdentities = values(prefix: "identity:previous-serial-sha256=")
    // The target-side edge, when the document records one separately.
    //
    // `revision` is the binding document's own version and is what the store's
    // compare-and-swap increments. The runtime target has its own numbering,
    // and the two coincide only while a lineage has never been interrupted.
    // The first cross-mode bind of a target whose binding was rebuilt is
    // exactly the case where they diverge, and one field cannot carry both:
    // the store requires `revision == existing.revision + 1` while this check
    // requires `revision == previousRevision + 1`, so any single value
    // violates one of them.
    //
    // So the target edge is recorded under its own key when it differs, and
    // `binding:previous-revision=` keeps meaning what it always meant — the
    // binding document's predecessor.
    let targetEdgeRevisions = values(prefix: "binding:target-previous-revision=")
    let targetEdgeCurrentRevisions = values(prefix: "binding:target-current-revision=")
    let previousRevisions = values(prefix: "binding:previous-revision=")
    let previousTopologies = values(prefix: "binding:previous-usb-topology=")
    let confirmations = values(prefix: "rebind:user-selection-sha256=")
    guard previousIdentities.count == 1,
      previousRevisions.count == 1,
      previousTopologies.count == 1,
      confirmations.count == 1,
      let previousIdentity = previousIdentities.first,
      let previousRevisionText = previousRevisions.first,
      let previousRevision = Int(previousRevisionText),
      let previousTopology = previousTopologies.first,
      let confirmation = confirmations.first,
      RockchipDigestValidation.isCanonicalSHA256(previousIdentity),
      RockchipDigestValidation.isCanonicalSHA256(confirmation),
      previousIdentity != currentIdentity,
      previousRevision > 0,
      revision == previousRevision + 1,
      !previousTopology.isEmpty,
      previousTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      previousTopology == "0" || previousTopology.first != "0"
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding previous identity lineage is invalid or ambiguous")
    }
    // The advance describes the *target's* edge. When the document records
    // one explicitly, that is what the target store is asked to apply; the
    // binding's own numbering is not the target's and saying otherwise is how
    // a first cross-mode bind ended up claiming "revision 2 follows revision
    // 3".
    let edgePrevious =
      targetEdgeRevisions.count == 1
      ? (Int(targetEdgeRevisions[0]) ?? previousRevision)
      : previousRevision
    let edgeCurrent =
      targetEdgeCurrentRevisions.count == 1
      ? (Int(targetEdgeCurrentRevisions[0]) ?? revision)
      : revision
    guard edgePrevious > 0, edgeCurrent == edgePrevious + 1 else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding target lineage edge is invalid")
    }
    return RuntimeTargetBindingLineageAdvance(
      previousStableIdentitySHA256: previousIdentity,
      previousRevision: edgePrevious,
      currentStableIdentitySHA256: currentIdentity,
      currentRevision: edgeCurrent)
  }

  /// A DAYU200 changes both its USB serial and its IOKit topology while moving
  /// between HDC-normal and Loader on the production board.  Revision 2 keeps
  /// the Loader identity as the stable campaign identity, but the immediately
  /// preceding HDC-normal identity remains the only address from which the
  /// typed `enter-loader` step can start.  Accept that alias only when the
  /// owner-only binding carries the complete Runtime-observed adjacent
  /// lineage edge.  A digest without its paired topology, a Loader claiming
  /// the previous HDC identity, or any older/unrelated identity remains a
  /// mismatch.
  func matchesConfirmedLiveIdentity(
    _ identity: RockchipProductUSBIdentity
  ) throws -> Bool {
    guard identity.isRegisteredDAYU200Mode else { return false }
    let currentIdentity = SHA256Hex.string(of: Data(serial.utf8))
    let liveIdentity = SHA256Hex.string(of: Data(identity.serial.utf8))

    // Validate the current evidence and, for revision > 1, the whole adjacent
    // edge before accepting either personality.  This prevents a malformed
    // lineage document from becoming useful merely because the device happens
    // to be in its latest mode.
    _ = try runtimeTargetLineageAdvance()
    if liveIdentity == currentIdentity, identity.topology == usbTopology {
      return true
    }
    guard identity.isHDCNormal,
      let alias = try confirmedHDCNormalAlias(),
      liveIdentity == alias.identitySHA256,
      identity.topology == alias.usbTopology
    else { return false }
    return true
  }

  /// The one HDC-normal personality this binding's confirmed lineage accepts
  /// besides its current identity, or nil when there is no valid confirmed
  /// edge (revision 1, or evidence without the Runtime user-selection proof).
  /// This is the single source for the alias every identity comparison must
  /// use — the executing gates through `matchesConfirmedLiveIdentity`, and
  /// the flash preflight, which on 2026-08-04 compared raw digests instead
  /// and refused the bound board in its HDC-normal personality even though
  /// the campaign's own allowed starting modes include hdcNormal.
  package func confirmedHDCNormalAlias()
    throws -> (identitySHA256: String, usbTopology: String)?
  {
    guard evidence.contains("product:e0-iokit-single-loader-readback") else { return nil }
    let adjacent = try runtimeTargetLineageAdvance() != nil
    let reactivated = try reactivationEvidence() != nil
    guard adjacent != reactivated else {
      if !adjacent { return nil }
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding carries ambiguous HDC alias authority")
    }
    let identities = values(prefix: "identity:hdc-normal-alias-sha256=")
    let topologies = values(prefix: "binding:hdc-normal-alias-usb-topology=")
    guard identities.count == 1, topologies.count == 1,
      let identity = identities.first, let topology = topologies.first,
      RockchipDigestValidation.isCanonicalSHA256(identity),
      !topology.isEmpty,
      topology.utf8.allSatisfy({ (48...57).contains($0) }),
      topology == "0" || topology.first != "0"
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding HDC-normal alias is invalid or ambiguous")
    }
    return (identity, topology)
  }

  /// Durable proof sufficient to finish the narrow crash window after a
  /// Runtime-owned Loader binding was published but before its outstanding
  /// enter-Loader Job intent was settled. This never observes or dispatches a
  /// device action; it only exposes the redacted adjacent revisions and the
  /// Runtime selection digest already validated by the binding document.
  package func loaderBindingRecoveryProof()
    throws -> RockchipLoaderBindingRecoveryProof?
  {
    guard evidence.contains("product:e0-iokit-single-loader-readback"),
      evidence.filter({ $0.hasPrefix("rebind:") }).count == 1,
      let advance = try runtimeTargetLineageAdvance(),
      try confirmedHDCNormalAlias() != nil
    else { return nil }
    let selections = values(prefix: "rebind:user-selection-sha256=")
    guard selections.count == 1, let selection = selections.first,
      RockchipDigestValidation.isCanonicalSHA256(selection)
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable Loader binding selection evidence is invalid or ambiguous")
    }
    return RockchipLoaderBindingRecoveryProof(
      previousRevision: advance.previousRevision,
      currentRevision: advance.currentRevision,
      selectionEvidenceSHA256: selection)
  }

  /// Answers whether this owner-only product binding covers the exact
  /// Runtime target used to materialize a Flash plan.  A target adopted from
  /// HDC alone is not cross-mode evidence: the binding must name the same
  /// stable Loader identity and adjacent revision, and its retained HDC
  /// connect key must be either that identity (revision 1) or the one
  /// explicitly confirmed normal-mode alias.
  ///
  /// Keeping this comparison beside the binding decoder is important.  Both
  /// the App prerequisite portrait and the protected Runtime admission gate
  /// consume this result, so malformed or partial lineage cannot be rendered
  /// as a warning while still authorizing `enter-loader`.
  package func coversRuntimeTarget(_ target: RuntimeTargetRecord) throws -> Bool {
    let advance = try runtimeTargetLineageAdvance()
    let currentIdentity = SHA256Hex.string(of: Data(serial.utf8))
    // The revision the target is expected to sit at.
    //
    // `revision` is this document's own version. A first cross-mode bind
    // deliberately diverges the two numberings — the binding advances from the
    // document it replaced, the target from its own — and records the target
    // edge under `binding:target-current-revision=` precisely because one
    // field cannot carry both. Comparing this document's version against the
    // target's therefore refuses the very target the bind had just advanced
    // correctly, which left a rebuilt binding unable to cover its own board.
    let expectedTargetRevision = advance?.currentRevision ?? revision
    guard target.stablePhysicalIdentitySHA256 == currentIdentity,
      target.bindingRevision == expectedTargetRevision
    else { return false }
    if let reactivation = try reactivationEvidence(),
      reactivation.targetID != target.targetID
    {
      return false
    }

    let connectIdentity = SHA256Hex.string(of: Data(target.connectKey.utf8))
    if connectIdentity == currentIdentity { return true }
    return try confirmedHDCNormalAlias()?.identitySHA256 == connectIdentity
  }

  /// Returns the current App-selection digest only for a fully validated
  /// same-revision Runtime reactivation of this exact target. This supports
  /// idempotent retries after the binding CAS committed but before the XPC
  /// reply arrived; it does not make the snapshot a lineage-recovery proof.
  package func reactivationSelectionEvidence(
    targetID: String
  ) throws -> String? {
    guard let proof = try reactivationEvidence(), proof.targetID == targetID else {
      return nil
    }
    return proof.selectionEvidenceSHA256
  }

  package func reactivatedTargetID() throws -> String? {
    try reactivationEvidence()?.targetID
  }

  func confirmedHDCConnectKey(
    for identity: RockchipProductUSBIdentity
  ) throws -> String? {
    guard identity.isHDCNormal, try matchesConfirmedLiveIdentity(identity) else { return nil }
    return identity.serial
  }

  private func values(prefix: String) -> [String] {
    evidence.compactMap {
      $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
    }
  }

  private struct ReactivationEvidence {
    let targetID: String
    let selectionEvidenceSHA256: String
  }

  /// Validates the non-lineage same-revision activation evidence. Any partial
  /// marker is a hard configuration error; a clean absence returns nil so
  /// revision-1 and adjacent-lineage documents retain their existing shape.
  private func reactivationEvidence() throws -> ReactivationEvidence? {
    let targetIDs = values(prefix: "binding:reactivated-target-id=")
    let currentIntents = values(prefix: "binding:reactivation-current-intent-sha256=")
    let routeReceipts = values(prefix: "binding:reactivation-route-receipt-sha256=")
    let replacedRevisions = values(prefix: "binding:replaced-active-revision=")
    let replacedIdentities = values(prefix: "identity:replaced-active-serial-sha256=")
    let selections = values(prefix: "rebind:user-selection-sha256=")
    let markerCount = targetIDs.count + currentIntents.count + routeReceipts.count
    if markerCount == 0 { return nil }

    let previousIdentities = values(prefix: "identity:previous-serial-sha256=")
    let previousRevisions = values(prefix: "binding:previous-revision=")
    let previousTopologies = values(prefix: "binding:previous-usb-topology=")
    let aliases = values(prefix: "identity:hdc-normal-alias-sha256=")
    let aliasTopologies = values(prefix: "binding:hdc-normal-alias-usb-topology=")
    guard revision > 1,
      evidence.contains("product:e0-iokit-single-loader-readback"),
      targetIDs.count == 1,
      currentIntents.count == 1,
      routeReceipts.count == 1,
      replacedRevisions.count == 1,
      replacedIdentities.count == 1,
      selections.count == 1,
      aliases.count == 1,
      aliasTopologies.count == 1,
      previousIdentities.isEmpty,
      previousRevisions.isEmpty,
      previousTopologies.isEmpty,
      let targetID = targetIDs.first,
      targetID.range(
        of: #"^TGT-[A-Za-z0-9][A-Za-z0-9._-]{0,123}$"#,
        options: .regularExpression) != nil,
      let currentIntent = currentIntents.first,
      let routeReceipt = routeReceipts.first,
      let replacedRevisionText = replacedRevisions.first,
      let replacedRevision = Int(replacedRevisionText),
      replacedRevision > 0,
      let replacedIdentity = replacedIdentities.first,
      let selection = selections.first,
      let alias = aliases.first,
      let aliasTopology = aliasTopologies.first,
      RockchipDigestValidation.isCanonicalSHA256(currentIntent),
      RockchipDigestValidation.isCanonicalSHA256(routeReceipt),
      currentIntent != routeReceipt,
      RockchipDigestValidation.isCanonicalSHA256(replacedIdentity),
      replacedIdentity != SHA256Hex.string(of: Data(serial.utf8)),
      RockchipDigestValidation.isCanonicalSHA256(selection),
      RockchipDigestValidation.isCanonicalSHA256(alias),
      !aliasTopology.isEmpty,
      aliasTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      aliasTopology == "0" || aliasTopology.first != "0"
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding reactivation evidence is invalid or ambiguous")
    }
    let expectedSelection = SHA256Hex.string(
      of: Data(
        [
          "rockchip-loader-user-selection",
          targetID,
          String(replacedRevision),
          String(revision),
          replacedIdentity,
          SHA256Hex.string(of: Data(serial.utf8)),
          usbTopology,
        ].joined(separator: "\n").utf8))
    guard selection == expectedSelection else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding reactivation selection digest does not match its exact facts")
    }
    return ReactivationEvidence(
      targetID: targetID, selectionEvidenceSHA256: selection)
  }
}

package struct RockchipLoaderBindingRecoveryProof: Sendable, Equatable {
  package let previousRevision: Int
  package let currentRevision: Int
  package let selectionEvidenceSHA256: String
}

package struct RockchipProductBindingStore: Sendable {
  package init(rootURL: URL) { self.rootURL = rootURL }

  static let bindingFileName = "rockchip-binding.json"
  static let lockFileName = ".rockchip-binding.lock"
  static let maximumDocumentBytes = 64 * 1_024

  let rootURL: URL

  package func loadExisting() throws -> RockchipProductBindingSnapshot {
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    guard let snapshot = try load(rootDescriptor: rootDescriptor) else {
      throw configurationError("durable Rockchip binding is not installed")
    }
    return snapshot
  }

  package func loadIfPresent() throws -> RockchipProductBindingSnapshot? {
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    return try load(rootDescriptor: rootDescriptor)
  }

  /// Writes the binding, refusing a silent change of board or port.
  ///
  /// `rebind` is the operator's explicit answer to a mismatch. Without it a
  /// differing candidate is refused; with it the new binding replaces the old
  /// one and records what it replaced.
  func install(_ candidate: RockchipProductBindingSnapshot, rebind: Bool = false)
    throws -> (snapshot: RockchipProductBindingSnapshot, created: Bool)
  {
    try validate(candidate)
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }

    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw configurationError("binding lock cannot be opened") }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnedRegularFile(lockDescriptor, permissions: 0o600, label: "binding lock")
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw configurationError("binding lock cannot be acquired")
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }

    if let existing = try load(rootDescriptor: rootDescriptor) {
      if existing.serial == candidate.serial, existing.usbTopology == candidate.usbTopology {
        return (existing, false)
      }
      // The binding names one board on one port, and both halves change for
      // ordinary reasons — a bench board moves to another USB port, or a
      // different board is put on the bench. Neither may be adopted silently:
      // this binding is what every destructive admission matches against, so
      // drifting it without a person saying so would let a flash authorized
      // for one device land on another.
      //
      // So the mismatch still refuses by default, and `rebind` is the person
      // saying so. It was refusing with "explicit rebind is required" while
      // offering no way to express one, which left a replugged board
      // permanently unflashable: `singleDAYU200` matches on
      // `identity.topology == selector`, so every admission — the flash, and
      // even reconcile's read-only readback — answered "DAYU200 target
      // unavailable" (measured 2026-08-17, binding held 18874368 while the
      // board enumerated at 17956864).
      guard rebind else {
        throw configurationError(
          "durable binding differs from the only connected Loader; explicit rebind is required")
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var document = try encoder.encode(candidate)
    document.append(0x0A)
    guard document.count <= Self.maximumDocumentBytes else {
      throw configurationError("binding document exceeds its product limit")
    }

    let temporaryName = ".rockchip-binding.\(UUID().uuidString.lowercased()).part"
    let temporaryDescriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard temporaryDescriptor >= 0 else {
      throw configurationError("binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporaryDescriptor) }
      _ = unlinkat(rootDescriptor, temporaryName, 0)
    }
    do {
      try writeAll(document, descriptor: temporaryDescriptor)
      guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0,
        Darwin.fsync(temporaryDescriptor) == 0,
        Darwin.fcntl(temporaryDescriptor, F_FULLFSYNC) == 0
      else { throw configurationError("binding temporary file cannot be synchronized") }
      guard Darwin.close(temporaryDescriptor) == 0 else {
        throw configurationError("binding temporary file cannot be closed")
      }
      temporaryOpen = false
      // `RENAME_EXCL` is what makes a first install unable to clobber a
      // binding that already exists. A rebind is the one case that must
      // replace one, and it only reaches here when the operator asked — the
      // guard above still refuses a silent change.
      guard
        renameatx_np(
          rootDescriptor, temporaryName, rootDescriptor, Self.bindingFileName,
          rebind ? 0 : UInt32(RENAME_EXCL)) == 0
      else { throw configurationError("binding publication cannot be committed") }
      guard Darwin.fsync(rootDescriptor) == 0 else {
        throw configurationError("binding directory cannot be synchronized")
      }
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("binding publication failed")
    }

    guard let readback = try load(rootDescriptor: rootDescriptor), readback == candidate else {
      throw configurationError("binding write-readback failed")
    }
    return (readback, true)
  }

  /// Atomically replaces exactly the expected current binding with one
  /// adjacent Runtime-observed revision. The caller has already applied Core
  /// rebind policy; this store enforces compare-and-swap and schema/readback.
  func replace(
    expectedRevision: Int,
    expectedSerialSHA256: String,
    with candidate: RockchipProductBindingSnapshot
  ) throws -> RockchipProductBindingSnapshot {
    try compareAndSwap(
      expectedRevision: expectedRevision,
      expectedSerialSHA256: expectedSerialSHA256,
      requiredCandidateRevision: expectedRevision + 1,
      with: candidate,
      mismatch: "durable binding changed before Loader rebind")
  }

  /// Switches the singleton active binding to an already-adopted revision-1
  /// target. The coordinator proves the fresh, unique USB identity and exact
  /// selected target before reaching this owner-only compare-and-swap. Keeping
  /// this separate from adjacent same-device lineage replacement prevents a
  /// target switch from being mistaken for a revision advance.
  func activateSelectedInitialTarget(
    expectedRevision: Int,
    expectedSerialSHA256: String,
    with candidate: RockchipProductBindingSnapshot
  ) throws -> RockchipProductBindingSnapshot {
    let candidateIdentity = SHA256Hex.string(of: Data(candidate.serial.utf8))
    guard candidate.revision == 1,
      candidateIdentity != expectedSerialSHA256,
      candidate.evidence.contains(where: { $0.hasPrefix("rebind:user-selection-sha256=") })
    else {
      throw configurationError("selected initial target binding is invalid")
    }
    return try compareAndSwap(
      expectedRevision: expectedRevision,
      expectedSerialSHA256: expectedSerialSHA256,
      requiredCandidateRevision: 1,
      with: candidate,
      mismatch: "durable binding changed before selected target activation")
  }

  /// Switches the singleton active binding to an already-adopted advanced
  /// target only after the coordinator has built the closed same-revision
  /// Runtime reactivation evidence. Unlike `replace`, this does not advance
  /// target lineage; unlike revision-1 activation, it requires a validated
  /// HDC alias so the post-flash target cannot be guessed after reboot.
  func activateSelectedTarget(
    expectedRevision: Int,
    expectedSerialSHA256: String,
    with candidate: RockchipProductBindingSnapshot
  ) throws -> RockchipProductBindingSnapshot {
    let candidateIdentity = SHA256Hex.string(of: Data(candidate.serial.utf8))
    guard candidate.revision > 1,
      candidateIdentity != expectedSerialSHA256,
      try candidate.runtimeTargetLineageAdvance() == nil,
      try candidate.confirmedHDCNormalAlias() != nil,
      let targetID = try candidate.reactivatedTargetID(),
      try candidate.reactivationSelectionEvidence(targetID: targetID) != nil
    else {
      throw configurationError("selected advanced target binding is invalid")
    }
    return try compareAndSwap(
      expectedRevision: expectedRevision,
      expectedSerialSHA256: expectedSerialSHA256,
      requiredCandidateRevision: candidate.revision,
      with: candidate,
      mismatch: "durable binding changed before selected target reactivation")
  }

  private func compareAndSwap(
    expectedRevision: Int,
    expectedSerialSHA256: String,
    requiredCandidateRevision: Int,
    with candidate: RockchipProductBindingSnapshot,
    mismatch: String
  ) throws -> RockchipProductBindingSnapshot {
    try validate(candidate)
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw configurationError("binding lock cannot be opened") }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnedRegularFile(lockDescriptor, permissions: 0o600, label: "binding lock")
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw configurationError("binding lock cannot be acquired")
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }
    guard let existing = try load(rootDescriptor: rootDescriptor) else {
      throw configurationError("durable Rockchip binding is not installed")
    }
    let existingDigest = SHA256Hex.string(of: Data(existing.serial.utf8))
    guard existing.revision == expectedRevision,
      existingDigest == expectedSerialSHA256,
      candidate.revision == requiredCandidateRevision
    else { throw configurationError(mismatch) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var document = try encoder.encode(candidate)
    document.append(0x0A)
    guard document.count <= Self.maximumDocumentBytes else {
      throw configurationError("binding document exceeds its product limit")
    }
    let temporaryName = ".rockchip-binding.\(UUID().uuidString.lowercased()).part"
    let temporaryDescriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard temporaryDescriptor >= 0 else {
      throw configurationError("binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporaryDescriptor) }
      _ = unlinkat(rootDescriptor, temporaryName, 0)
    }
    do {
      try writeAll(document, descriptor: temporaryDescriptor)
      guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0,
        Darwin.fsync(temporaryDescriptor) == 0,
        Darwin.fcntl(temporaryDescriptor, F_FULLFSYNC) == 0
      else { throw configurationError("binding temporary file cannot be synchronized") }
      guard Darwin.close(temporaryDescriptor) == 0 else {
        throw configurationError("binding temporary file cannot be closed")
      }
      temporaryOpen = false
      guard
        renameat(
          rootDescriptor, temporaryName, rootDescriptor, Self.bindingFileName) == 0
      else { throw configurationError("binding replacement cannot be committed") }
      guard Darwin.fsync(rootDescriptor) == 0 else {
        throw configurationError("binding directory cannot be synchronized")
      }
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("binding replacement failed")
    }
    guard let readback = try load(rootDescriptor: rootDescriptor), readback == candidate else {
      throw configurationError("binding replacement readback failed")
    }
    return readback
  }

  private func prepareRoot() throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw configurationError("binding root must be an absolute file URL")
    }
    var existing = stat()
    if lstat(rootURL.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFLNK {
      throw configurationError("binding root cannot be a symbolic link")
    }
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw configurationError("binding root cannot be created")
    }
    guard chmod(rootURL.path, 0o700) == 0 else {
      throw configurationError("binding root must be owner-only")
    }
  }

  private func load(rootDescriptor: Int32) throws -> RockchipProductBindingSnapshot? {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.bindingFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw configurationError("durable binding cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateOwnedRegularFile(descriptor, permissions: 0o600, label: "durable binding")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else { throw configurationError("durable binding size is invalid") }
    let document = try readAll(descriptor: descriptor, byteCount: Int(metadata.st_size))
    guard
      let object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
      Set(object.keys) == ["revision", "serial", "usbTopology", "evidence"]
    else { throw configurationError("durable binding schema is invalid") }
    let snapshot: RockchipProductBindingSnapshot
    do {
      snapshot = try JSONDecoder().decode(RockchipProductBindingSnapshot.self, from: document)
    } catch {
      throw configurationError("durable binding cannot be decoded")
    }
    try validate(snapshot)
    return snapshot
  }

  private func validate(_ snapshot: RockchipProductBindingSnapshot) throws {
    guard snapshot.revision > 0,
      !snapshot.serial.isEmpty,
      !snapshot.usbTopology.isEmpty,
      snapshot.usbTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      !snapshot.evidence.isEmpty,
      snapshot.evidence.allSatisfy({ !$0.isEmpty && !$0.contains(snapshot.serial) })
    else { throw configurationError("durable binding snapshot is invalid") }
  }

  private func validateOwnedRegularFile(
    _ descriptor: Int32,
    permissions: mode_t,
    label: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == permissions
    else { throw configurationError("\(label) must be an owner-only regular file") }
  }

  private func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4_096, byteCount))
    while result.count < byteCount {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, byteCount - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw configurationError("durable binding cannot be read")
      }
      guard count > 0 else { throw configurationError("durable binding was truncated") }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw configurationError("binding temporary file cannot be written")
        }
        guard written > 0 else {
          throw configurationError("binding temporary file cannot be written")
        }
        offset += written
      }
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipProductBindingBootstrap: Sendable {
  let probe: @Sendable () throws -> RockchipProductUSBIdentity
  let store: RockchipProductBindingStore

  func installCurrentTarget(
    rebind: Bool = false
  ) throws -> RockchipDeviceBindingInstallationReceipt {
    let identity = try probe()
    guard identity.isRegisteredDAYU200Mode,
      !identity.serial.isEmpty,
      !identity.topology.isEmpty,
      identity.topology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the single USB identity is not a registered DAYU200 mode")
    }
    let serialDigest = SHA256Hex.string(of: Data(identity.serial.utf8))
    var evidence = [
      "product:e0-iokit-single-dayu200-readback",
      "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
      "identity:serial-sha256=\(serialDigest)",
    ]
    // A rebind continues the lineage; it does not restart it.
    //
    // `runtimeTargetLineageAdvance` reads exactly these four keys and returns
    // nil when `revision == 1`, so a rebind that wrote a fresh revision-1
    // snapshot would publish a binding the recovery machinery cannot follow:
    // the adjacent edge from the old identity to the new one would simply not
    // exist, and a job that bound the old one could never be settled against
    // the new. Carrying the previous revision and identity forward is what
    // makes the replacement an edge rather than an amnesia.
    var revision = 1
    if rebind, let previous = try store.loadIfPresent() {
      revision = previous.revision + 1
      let previousSerialDigest = SHA256Hex.string(of: Data(previous.serial.utf8))
      evidence.append("identity:previous-serial-sha256=\(previousSerialDigest)")
      evidence.append("binding:previous-revision=\(previous.revision)")
      evidence.append("binding:previous-usb-topology=\(previous.usbTopology)")
      // The operator's selection, recorded as what they selected rather than
      // as a bare "yes": `--rebind` names this exact device on this exact
      // port, and the digest is what a later audit compares against.
      evidence.append(
        "rebind:user-selection-sha256="
          + SHA256Hex.string(of: Data("\(identity.serial)|\(identity.topology)".utf8)))
    }
    let candidate = RockchipProductBindingSnapshot(
      revision: revision,
      serial: identity.serial,
      usbTopology: identity.topology,
      evidence: evidence)
    let result = try store.install(candidate, rebind: rebind)
    let storedDigest = SHA256Hex.string(of: Data(result.snapshot.serial.utf8))
    return RockchipDeviceBindingInstallationReceipt(
      revision: result.snapshot.revision,
      usbTopology: result.snapshot.usbTopology,
      serialDigestSHA256: storedDigest,
      created: result.created)
  }
}

struct RockchipProductUSBIdentity: Sendable, Equatable {
  let serial: String
  let vendorID: UInt16
  let productID: UInt16
  let topology: String
  let productName: String?

  init(
    serial: String,
    vendorID: UInt16,
    productID: UInt16,
    topology: String,
    productName: String? = nil
  ) {
    self.serial = serial
    self.vendorID = vendorID
    self.productID = productID
    self.topology = topology
    self.productName = productName
  }

  var isLoader: Bool {
    vendorID == RockchipProbeEvidence.rockUSBVendorID
      && productID == RockchipProbeEvidence.dayu200LoaderProductID
  }

  var isHDCNormal: Bool {
    guard vendorID == RockchipProbeEvidence.rockUSBVendorID,
      productID == RockchipHDCIntegrationProfile.dayu200NormalProductID,
      let productName
    else { return false }
    return productName.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) == "HDC Device"
  }

  var isRegisteredDAYU200Mode: Bool { isLoader || isHDCNormal }
}

struct RockchipProductUSBProbe: Sendable {
  private enum Requirement {
    case loader
    case hdcNormal
    case registeredDAYU200
  }

  private let identitySource: @Sendable () throws -> [RockchipProductUSBIdentity]

  init(
    identitySource: @escaping @Sendable () throws -> [RockchipProductUSBIdentity] = {
      try Self.systemIdentities()
    }
  ) {
    self.identitySource = identitySource
  }

  /// Enumerates registered DAYU200 personalities without selecting or
  /// mutating one. Callers must keep raw identities inside the product-owned
  /// boundary and expose only a redacted projection.
  func registeredDAYU200Identities() throws -> [RockchipProductUSBIdentity] {
    try identitySource().filter(\.isRegisteredDAYU200Mode)
  }

  func singleLoader(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(selector: selector, serialDigestSHA256: nil, requirement: .loader)
  }

  func singleLoader(
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: nil, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleLoader(
    selector: String,
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleDAYU200(
    selector: String? = nil,
    stableIdentitySHA256: String? = nil
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .registeredDAYU200)
  }

  /// Selects one live DAYU200 personality from the exact current/previous
  /// identities proven by the durable binding.  This differs from accepting
  /// an arbitrary serial alias: the previous identity is usable only as the
  /// HDC-normal side of the one confirmed adjacent lineage edge.
  func singleDAYU200(
    selector: String,
    binding: RockchipProductBindingSnapshot
  ) throws -> RockchipProductUSBIdentity {
    // Fail closed on malformed owner-only lineage even when the host currently
    // has no matching USB device.
    _ = try binding.runtimeTargetLineageAdvance()
    let matches = try identitySource().filter { identity in
      guard identity.topology == selector else { return false }
      return try binding.matchesConfirmedLiveIdentity(identity)
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "DAYU200 target unavailable" : "DAYU200 target ambiguous")
    }
    return match
  }

  func singleConnected(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: nil,
      requirement: .hdcNormal)
  }

  func singleConnected(
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: nil, serialDigestSHA256: stableIdentitySHA256,
      requirement: .hdcNormal)
  }

  private func single(
    selector: String?,
    serialDigestSHA256: String?,
    requirement: Requirement
  ) throws
    -> RockchipProductUSBIdentity
  {
    let identities = try identitySource()
    var matches: [RockchipProductUSBIdentity] = []
    for identity in identities {
      let modeMatches: Bool
      switch requirement {
      case .loader: modeMatches = identity.isLoader
      case .hdcNormal: modeMatches = identity.isHDCNormal
      case .registeredDAYU200: modeMatches = identity.isRegisteredDAYU200Mode
      }
      guard modeMatches else { continue }
      let digest = SHA256Hex.string(of: Data(identity.serial.utf8))
      if (selector == nil || selector == identity.topology)
        && (serialDigestSHA256 == nil || serialDigestSHA256 == digest)
      {
        matches.append(identity)
      }
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "DAYU200 target unavailable" : "DAYU200 target ambiguous")
    }
    return match
  }

  static func systemIdentities() throws -> [RockchipProductUSBIdentity] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable") }
    defer { IOObjectRelease(iterator) }
    var identities: [RockchipProductUSBIdentity] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      guard let vendor = number(service, "idVendor"),
        let product = number(service, "idProduct"),
        let location = number(service, "locationID"),
        let serial = string(service, "USB Serial Number")
          ?? string(service, "kUSBSerialNumberString")
      else { continue }
      let identity = RockchipProductUSBIdentity(
        serial: serial, vendorID: vendor.uint16Value,
        productID: product.uint16Value, topology: String(location.uint64Value),
        productName: string(service, "USB Product Name"))
      identities.append(identity)
    }
    return identities
  }

  private static func number(_ service: io_registry_entry_t, _ key: String) -> NSNumber? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber
  }

  private static func string(_ service: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}
