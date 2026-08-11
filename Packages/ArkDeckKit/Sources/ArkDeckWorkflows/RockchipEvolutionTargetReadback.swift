// Read-only readback of the durable DAYU200 target (TASK-AIN-019).
//
// Two callers need the same answer for different reasons: the flash preflight
// asks "is the bound target on the bus at all" before a confirmation phrase is
// printed, and campaign reconciliation asks "did the target come back in a
// registered mode" before it may settle an unknown Loader transition. Both are
// E0: this port reads the USB registry and never spawns, never transitions and
// never re-sends a mutation command.

import ArkDeckCore
import CryptoKit
import Foundation

/// One read-only USB observation of the durable target.
///
/// Every field is optional on purpose, because "nothing answered", "something
/// answered with the wrong identity" and "the right target answered in a
/// personality this product has not registered" are three different fail-closed
/// outcomes and no caller may collapse them into each other.
public struct RockchipEvolutionTargetReadback: Sendable, Equatable {
  /// SHA-256 of the observed USB serial, or nil when nothing answered.
  public let stableIdentitySHA256: String?
  /// The registered DAYU200 mode, or nil when the observed personality is not
  /// one this product has registered (Maskrom, DFU, a bare recovery gadget).
  public let registeredMode: RockchipEvolutionStartingMode?
  public let usbTopology: String?

  public static let absent = RockchipEvolutionTargetReadback(
    stableIdentitySHA256: nil, registeredMode: nil, usbTopology: nil)

  public init(
    stableIdentitySHA256: String?,
    registeredMode: RockchipEvolutionStartingMode?,
    usbTopology: String?
  ) {
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.registeredMode = registeredMode
    self.usbTopology = usbTopology
  }
}

public protocol RockchipEvolutionTargetReadbackReading: Sendable {
  /// Reads the single Rockchip target currently on the bus. Ambiguity (two
  /// Rockchip devices) is absence: an observation that cannot be attributed to
  /// the bound target proves nothing about it.
  func readDurableTarget() throws -> RockchipEvolutionTargetReadback
}

/// The default for every composition that has not been wired with a real
/// readback. It reports absence, which is the fail-closed answer: an unknown
/// attempt stays unknown and a preflight target check stays red.
public struct AbsentRockchipEvolutionTargetReadback: RockchipEvolutionTargetReadbackReading {
  public init() {}

  public func readDurableTarget() throws -> RockchipEvolutionTargetReadback { .absent }
}

/// Production readback over the same IOKit enumeration the flash admission
/// gates already use. It deliberately does not go through
/// `RockchipProductUSBProbe.singleDAYU200`, which filters to registered modes
/// and would therefore report an unregistered personality as plain absence —
/// the distinction this port exists to preserve.
public struct ProductRockchipEvolutionTargetReadback: RockchipEvolutionTargetReadbackReading {
  private let identitySource: @Sendable () throws -> [RockchipProductUSBIdentity]

  public init() {
    self.init(identitySource: { try RockchipProductUSBProbe.systemIdentities() })
  }

  init(identitySource: @escaping @Sendable () throws -> [RockchipProductUSBIdentity]) {
    self.identitySource = identitySource
  }

  public func readDurableTarget() throws -> RockchipEvolutionTargetReadback {
    let rockchip = try identitySource().filter {
      $0.vendorID == RockchipProbeEvidence.rockUSBVendorID
    }
    guard rockchip.count == 1, let identity = rockchip.first else { return .absent }
    let mode: RockchipEvolutionStartingMode?
    if identity.isLoader {
      mode = .loader
    } else if identity.isHDCNormal {
      mode = .hdcNormal
    } else {
      mode = nil
    }
    return RockchipEvolutionTargetReadback(
      stableIdentitySHA256: SHA256Hex.string(of: Data(identity.serial.utf8)),
      registeredMode: mode,
      usbTopology: identity.topology)
  }
}
