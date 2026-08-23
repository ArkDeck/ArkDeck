// Product-owned Rockchip Runtime composition for GJ-4.
//
// The RockUSB identity is the same measured `arkforged` executable that owns
// native enumeration, writes, readback and reset. The standalone recovery
// utility bundled by ArkDeck is deliberately outside this composition: it is
// a Maskrom rescue artifact, not a product Runtime dependency.

import ArkDeckCore
import Foundation

package enum ArkForgeNativeRockUSBToolchain {
  package static let identifier = "arkforged-native-rockusb"
  package static let reportedVersion = "arkforged native RockUSB"
}

/// Re-measures the configured daemon for every facts/materialization read.
/// The LaunchAgent already compared the declared digest at install time; this
/// closes the update window between that install and a Runtime admission.
package struct ArkForgeNativeRockUSBExecutableResolver: RuntimeExecutableResolving {
  private let daemonPath: String?
  private let declaredSHA256: String?

  package init(daemonPath: String?, declaredSHA256: String?) {
    self.daemonPath = daemonPath
    self.declaredSHA256 = declaredSHA256?.lowercased()
  }

  package func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "rockchip" else {
      throw RuntimeDispatchFailure.failed(
        "ArkForge native RockUSB resolver cannot serve provider \(providerID)")
    }
    guard let daemonPath, let declaredSHA256, !daemonPath.isEmpty, !declaredSHA256.isEmpty else {
      throw RuntimeDispatchFailure.failed("ArkForge native RockUSB lane is not configured")
    }
    let resolver = try FixedExecutableResolver.hashing(
      path: daemonPath, providerID: providerID)
    let measured = try resolver.resolveExecutable(providerID: providerID)
    guard measured.sha256 == declaredSHA256 else {
      throw RuntimeDispatchFailure.failed(
        "arkforged executable digest changed after LaunchAgent installation")
    }
    return measured
  }
}

/// Facts come from the adopted target record and the product-owned component,
/// never from request fields. This makes the target identity and binding
/// revision used for plan admission the same durable facts used by HDC.
package struct TargetStoreRockchipRuntimeFactsPort: RockchipRuntimeFactsPort {
  package static let crossModeBindingServerFactKey = "dayu200CrossModeBinding"
  package static let crossModeBindingSatisfied = "satisfied"
  package static let crossModeBindingUnprepared = "unprepared"
  package static let hdcAliasIdentityServerFactKey = "dayu200HDCNormalAliasSHA256"
  package static let hdcAliasTopologyServerFactKey = "dayu200HDCNormalAliasUSBTopology"

  private let targetStore: RuntimeTargetStore
  private let resolver: any RuntimeExecutableResolving
  private let prober: (any RockchipLiveModeProbing)?
  private let bindingStore: RockchipProductBindingStore?
  private let postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore?
  private let nowUTC: @Sendable () -> String

  /// `prober: nil` keeps the record-only behaviour: mode, build and profile
  /// are reported unknown because nothing measured them. A composed prober
  /// replaces those unknowns with read-only measurements, never with guesses.
  package init(
    targetStore: RuntimeTargetStore,
    resolver: any RuntimeExecutableResolving,
    prober: (any RockchipLiveModeProbing)? = nil,
    bindingStore: RockchipProductBindingStore? = nil,
    postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.targetStore = targetStore
    self.resolver = resolver
    self.prober = prober
    self.bindingStore = bindingStore
    self.postFlashHDCBindingStore = postFlashHDCBindingStore
    self.nowUTC = nowUTC
  }

  package func currentFacts(targetID: String) async throws -> ProviderFacts {
    guard let target = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    let component: ResolvedExecutable
    do {
      component = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw DeviceProviderError.factsUnavailable(
        "ArkForge native RockUSB identity is unavailable: \(error)")
    }
    var executionConnectKey = target.connectKey
    var coveredBinding: RockchipProductBindingSnapshot?
    var serverFacts = [
      "rockusbBackend": "native",
      "arkForgeToolchainID": ArkForgeNativeRockUSBToolchain.identifier,
    ]
    if let bindingStore {
      let covered: Bool
      if let binding = try bindingStore.loadIfPresent() {
        covered = try binding.coversRuntimeTarget(target)
        if covered {
          coveredBinding = binding
          var alias = try binding.confirmedHDCNormalAlias()
          if let routed = try postFlashHDCBindingStore?.loadIfPresent(),
            try routed.covers(target: target, binding: binding)
          {
            guard
              try !targetStore.hasConflictingHDCAliasOwner(
                canonicalTargetID: target.targetID,
                connectKey: routed.hdcConnectKey,
                identitySHA256: routed.hdcIdentitySHA256,
                establishingFlashJobID: routed.jobID)
            else {
              throw DeviceProviderError.factsUnavailable(
                "verified post-flash HDC alias is owned by another adopted target")
            }
            executionConnectKey = routed.hdcConnectKey
            alias = (routed.hdcIdentitySHA256, routed.usbTopology)
          }
          if let alias {
            serverFacts[Self.hdcAliasIdentityServerFactKey] = alias.identitySHA256
            serverFacts[Self.hdcAliasTopologyServerFactKey] = alias.usbTopology
          }
        }
      } else {
        covered = false
      }
      serverFacts[Self.crossModeBindingServerFactKey] =
        covered
        ? Self.crossModeBindingSatisfied : Self.crossModeBindingUnprepared
    }
    let live = await liveFacts(
      connectKey: executionConnectKey,
      stableIdentitySHA256: target.stablePhysicalIdentitySHA256)
    // The durable post-flash alias owns the HDC identity, not a forever port.
    // A DAYU200 cable move keeps the exact connect key/identity but changes
    // IOKit's locationID. When the read-only live probe correlates both
    // surfaces to that same trusted alias, use its current topology for this
    // materialization only. No target, binding or alias record is rewritten.
    // If either observation is absent or disagrees, retain the durable value
    // and let ArkForge's exact topology selection fail closed before dispatch.
    if live.deviceMode == "hdc",
      let topology = live.usbTopology,
      !topology.isEmpty,
      topology.utf8.allSatisfy({ (48...57).contains($0) }),
      let aliasIdentity = serverFacts[Self.hdcAliasIdentityServerFactKey],
      SHA256Hex.string(of: Data(executionConnectKey.utf8)) == aliasIdentity
    {
      serverFacts[Self.hdcAliasTopologyServerFactKey] = topology
    }
    // A revision-1 adoption can itself be the exact HDC-normal personality:
    // it has no adjacent lineage edge yet, but its owner binding still pins
    // the live serial and topology.  Use it only after a fresh HDC-mode probe.
    // A Loader-only revision 1 has no normal-mode topology and remains blocked
    // before any write instead of discovering that only after reboot.
    if serverFacts[Self.hdcAliasIdentityServerFactKey] == nil,
      live.deviceMode == "hdc",
      let binding = coveredBinding
    {
      let connectIdentity = SHA256Hex.string(of: Data(executionConnectKey.utf8))
      let bindingIdentity = SHA256Hex.string(of: Data(binding.serial.utf8))
      if connectIdentity == bindingIdentity,
        !binding.usbTopology.isEmpty,
        binding.usbTopology.utf8.allSatisfy({ (48...57).contains($0) })
      {
        serverFacts[Self.hdcAliasIdentityServerFactKey] = connectIdentity
        serverFacts[Self.hdcAliasTopologyServerFactKey] = binding.usbTopology
      }
    }
    return ProviderFacts(
      providerID: CatalogProvider.arkforge.rawValue,
      toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
      toolSHA256: component.sha256,
      serverFacts: serverFacts,
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      deviceIdentitySHA256: target.stablePhysicalIdentitySHA256,
      executionConnectKey: executionConnectKey,
      deviceMode: live.deviceMode,
      buildFingerprint: live.buildFingerprint,
      profileID: live.profileID,
      collectedAtUTC: nowUTC())
  }

  /// Without a prober the durable adoption record is all this port has, and
  /// it cannot support any of these three: they stay unknown rather than
  /// fabricated. The previous "hdc"/"dayu200" literals were adoption-era
  /// guesses that flowed into evidence as if measured, and the real firmware
  /// profile (dayu200) contradicted one of them.
  ///
  /// With a prober they are measured read-only. A probe failure — including a
  /// device that is simply not attached — is encoded as `absent`, not thrown:
  /// these facts are the pre-admission portrait, while the fail-closed
  /// authority gates are the engine's fresh readback and reservation at the
  /// consume point. Throwing here would take device-absent planOnly and draft
  /// with it, and those must stay possible with no device on the host.
  private func liveFacts(
    connectKey: String?,
    stableIdentitySHA256: String
  ) async -> (
    deviceMode: String, buildFingerprint: String?, profileID: String,
    usbTopology: String?
  ) {
    guard let prober, let connectKey else {
      return ("unknown", nil, "unknown", nil)
    }
    guard
      let observation = try? await prober.observe(
        connectKey: connectKey,
        stableIdentitySHA256: stableIdentitySHA256)
    else {
      return ("absent", nil, "unknown", nil)
    }
    // The flash profile is never inferred from a device model or a mode: only
    // an exact published firmware fingerprint names one. Anything else stays
    // unknown, and the per-request `deviceProfile` input remains the pin that
    // actually authorizes a write.
    let profileID =
      observation.buildFingerprint.flatMap { fingerprint in
        RockchipFlashProfile.dayu200.firmwareVersion == fingerprint
          ? RockchipFlashProfile.dayu200.catalogReference : nil
      } ?? "unknown"
    return (
      observation.deviceMode, observation.buildFingerprint, profileID,
      observation.usbTopology)
  }
}

/// Read-only prerequisite portrait used by the App's exact-plan review.
///
/// This is intentionally a projection of facts the production Runtime already
/// measures. It does not participate in admission and it never upgrades an
/// unobservable condition: the protected Runtime repeats its own fresh probe
/// before a destructive dispatch.
public protocol RockchipFlashPrerequisiteObserving: Sendable {
  func observePrerequisites(targetID: String) async throws
    -> [RockchipPrerequisiteObservation]
}

extension TargetStoreRockchipRuntimeFactsPort: RockchipFlashPrerequisiteObserving {
  package func observePrerequisites(
    targetID: String
  ) async throws -> [RockchipPrerequisiteObservation] {
    let facts = try await currentFacts(targetID: targetID)
    let crossModeBindingReady =
      facts.serverFacts[Self.crossModeBindingServerFactKey]
      == Self.crossModeBindingSatisfied
    let statuses: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteStatus]
    switch facts.deviceMode {
    case "loader":
      // Mirrors RockchipProductPrerequisitePort: one attributable Loader
      // observation proves the three product prerequisites that port emits.
      // Stable power has no production sensor and therefore remains unknown.
      statuses =
        crossModeBindingReady || bindingStore == nil
        ? [
          .loader: .satisfied,
          .recoveryPath: .satisfied,
          .unlocked: .satisfied,
          .stablePower: .unknown,
        ]
        : [
          .loader: .unknown,
          .recoveryPath: .unsatisfied,
          .unlocked: .unknown,
          .stablePower: .unknown,
        ]
    case "maskrom":
      statuses = [
        .loader: .unsatisfied,
        .recoveryPath: .unsatisfied,
        .unlocked: .unknown,
        .stablePower: .unknown,
      ]
    case "hdc" where crossModeBindingReady:
      // The target is currently addressable through HDC and the owner-only
      // binding already proves its exact Loader identity/revision and normal
      // alias.  That is the published USB recovery path the execute plan
      // consumes; stable power has no production sensor and stays unknown.
      statuses = [
        .loader: .satisfied,
        .recoveryPath: .satisfied,
        .unlocked: .satisfied,
        .stablePower: .unknown,
      ]
    case "hdc" where bindingStore != nil:
      statuses = [
        .loader: .unknown,
        .recoveryPath: .unsatisfied,
        .unlocked: .unknown,
        .stablePower: .unknown,
      ]
    default:
      statuses = Dictionary(
        uniqueKeysWithValues: RockchipPrerequisiteIdentifier.allCases.map { ($0, .unknown) })
    }
    return RockchipPrerequisiteIdentifier.allCases.map {
      RockchipPrerequisiteObservation(identifier: $0, status: statuses[$0] ?? .unknown)
    }
  }
}

/// The Rockchip route is installed in production even while it is
/// unavailable. It validates the exact host-managed action shape and exposes
/// the concrete compatibility blocker through operation.list. It must not
/// fall back to PATH, a bookmark, the HDC dispatcher, or the old whole-plan
/// host (which would consume a second legacy authorization).
package struct ArkForgeNativeRockchipControlDispatcher: RuntimeProcessDispatching {
  private let resolver: any RuntimeExecutableResolving
  private let host: any RockchipRuntimeActionHosting

  /// The same host this dispatcher runs actions through, for the ArkForge lane
  /// to perform managed control on.
  ///
  /// Exposed rather than rebuilt: a second host would be a second HDC owner,
  /// and the whole point of keeping control on this side is that there is
  /// exactly one. When this dispatcher was composed without a descriptor-bound
  /// HDC, the host it hands back refuses — which is the same answer the
  /// dispatcher itself would give, arrived at the same way.
  var actionHost: any RockchipRuntimeActionHosting { host }

  /// `unavailableDetail` names the concrete missing piece when one is known —
  /// an unpreparable tool runtime directory reaches the operator through
  /// `operation.list` this way instead of as a generic refusal.
  package init(
    resolver: any RuntimeExecutableResolving,
    unavailableDetail: String? = nil
  ) {
    self.resolver = resolver
    host = RefusingRockchipRuntimeActionHost(
      reason: [
        "the per-action RockUSB host requires descriptor-bound HDC and a product state directory",
        unavailableDetail,
      ].compactMap { $0 }.joined(separator: ": "))
  }

  /// `stateWorkingDirectory` is product-owned state for the remaining HDC
  /// control reads; native RockUSB itself executes inside `arkforged`.
  package init(
    resolver: any RuntimeExecutableResolving,
    hdcResolver: any RuntimeExecutableResolving,
    stateDirectory: URL,
    stateWorkingDirectory: URL,
    postFlashHDCBindingStore: RockchipPostFlashHDCBindingStore? = nil
  ) {
    self.resolver = resolver
    host = DurableRockchipRuntimeActionHost(
      executor: FoundationRockchipRuntimeActionExecutor(
        hdcResolver: hdcResolver,
        runner: FoundationRockchipRuntimeCommandRunner(
          workingDirectory: stateWorkingDirectory),
        loaderObserver: ProductArkForgeLoaderObserver(
          runtimeDirectory: stateDirectory.appending(
            path: "arkforge", directoryHint: .isDirectory)),
        // The staged-image cache went with the write path it fed: only
        // `flashWrites` ever unpacked an archive here, and that lowering is
        // arkforged's now (CHG-2026-059).
        postFlashHDCBindingStore: postFlashHDCBindingStore),
      records: RockchipRuntimeActionRecordStore(
        rootURL: stateDirectory.appending(
          path:
            "rockchip-runtime", directoryHint: .isDirectory)))
  }

  init(
    resolver: any RuntimeExecutableResolving,
    host: any RockchipRuntimeActionHosting
  ) {
    self.resolver = resolver
    self.host = host
  }

  package func unavailableReason(providerID: String) -> String? {
    guard [CatalogProvider.arkforge.rawValue, "rockchip"].contains(providerID) else {
      return "ArkForge native RockUSB dispatcher cannot serve provider \(providerID)"
    }
    do {
      _ = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      return "ArkForge native RockUSB identity is unavailable: \(error)"
    }
    return host.unavailableReason()
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    try await dispatch(plan, progress: { _ in })
  }

  public func dispatch(
    _ plan: TypedProcessPlan,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> ProviderProcessReceipt {
    guard case .rockchip(let action) = plan.action else {
      throw RuntimeDispatchFailure.failed(
        "ArkForge native RockUSB dispatcher received a non-Rockchip action")
    }
    guard case .hostManaged(let descriptor) = plan.kind else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip runtime actions must use their closed host-managed descriptors")
    }
    if let reason = unavailableReason(providerID: CatalogProvider.arkforge.rawValue) {
      throw RuntimeDispatchFailure.failed(reason)
    }
    let executable: ResolvedExecutable
    do {
      executable = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw RuntimeDispatchFailure.failed(
        "ArkForge native RockUSB identity is unavailable: \(error)")
    }
    guard descriptor.providerExecutableSHA256 == executable.sha256 else {
      throw RuntimeDispatchFailure.failed(
        "ArkForge native RockUSB identity changed after availability materialization")
    }
    let result = try await host.execute(
      action: action,
      descriptor: descriptor,
      providerExecutable: executable,
      progress: progress)
    guard let recordID = result.summary["recordID"], !recordID.isEmpty else {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "Rockchip host returned no durable job/step receipt")
    }
    return ProviderProcessReceipt(
      exitStatus: 0,
      stdout: result.stdout,
      stderr: result.stderr,
      stdoutTruncated: result.stdoutTruncated,
      durationSeconds: result.subprocesses.reduce(0) {
        $0 + $1.durationSeconds
      },
      hostManagedRecordID: recordID,
      hostManagedSummary: result.summary,
      subprocesses: result.subprocesses)
  }
}
