import ArkDeckCore
import ArkDeckStorage
import Foundation

/// The one table binding a Rockchip runtime action to its closed host-managed
/// descriptor identity.
///
/// Before this type the table existed twice — `lower(action:context:)` writing
/// identifiers into materialized plans, `actionMatchesDescriptor` checking
/// them — and a third site fabricated a descriptor beside both
/// (`identifier: "arkforge.managedControl"`, `actionSHA256: ""`), which the
/// validating host then refused on every call it was ever given. Nothing
/// noticed, because the fabrication compiled: the table's shape lived in three
/// heads and no type. A descriptor that can only be produced here cannot
/// disagree with the validator, and a new action that forgets to register
/// fails to compile rather than failing on a bench.
package enum RockchipHostManagedActionCatalog {

  /// The closed descriptor identifier for one action.
  package static func identifier(for action: RockchipProviderAction) -> String {
    switch action {
    case .enterLoader:
      return "rockchip.hdc.enter-loader.v1"
    case .observeHDCNormalUSB:
      return "rockchip.iokit.observe-hdc-normal.v1"
    case .waitForHDCDisconnect:
      return "rockchip.hdc.wait-disconnect.v1"
    case .waitForLoader:
      return "rockchip.rockusb.wait-loader.v1"
    case .rebindLoader:
      return "rockchip.rockusb.rebind-loader.v1"
    case .rebootToNormal:
      return "rockchip.rockusb.reboot-normal.v1"
    case .waitForHDCReconnect:
      return "rockchip.hdc.wait-reconnect.v1"
    case .waitForBoundHDCReconnect:
      return "rockchip.hdc.wait-bound-reconnect.v2"
    case .verifyBoundBuild:
      return "rockchip.hdc.verify-bound-build.v2"
    case .capturePostFlashDiagnostics:
      return "rockchip.hdc.capture-post-flash-hilog.v1"
    }
  }

  /// The canonical digest a descriptor pins its typed action with, computed
  /// exactly as the validating host recomputes it.
  package static func actionSHA256(of action: TypedProviderAction) throws -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    let encoded = try encoder.encode(try PersistedTypedProviderAction(action))
    return SHA256Hex.string(of: encoded)
  }

  /// A descriptor the durable host's validation will accept for `action`.
  package static func descriptor(
    for action: RockchipProviderAction,
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int,
    connectKey: String,
    expectedIdentitySHA256: String,
    providerExecutableSHA256: String
  ) throws -> HostManagedProcessDescriptor {
    HostManagedProcessDescriptor(
      identifier: identifier(for: action),
      jobID: jobID,
      stepID: stepID,
      targetID: targetID,
      bindingRevision: bindingRevision,
      connectKey: connectKey,
      expectedIdentitySHA256: expectedIdentitySHA256,
      providerExecutableSHA256: providerExecutableSHA256,
      actionSHA256: try actionSHA256(of: .rockchip(action)))
  }
}
