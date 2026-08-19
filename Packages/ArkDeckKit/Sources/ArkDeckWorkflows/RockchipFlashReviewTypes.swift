import Foundation

// Small shared vocabulary that survived CHG-2026-066's dissolution of
// `RockchipRockUSBFlashProvider`. The provider's plan fabrication, probe
// verdicts, prerequisite gate, outcome assessment and recovery guide had no
// production callers left after the ArkForge lane took execution; what remains
// here is the vocabulary the review surface and the binding/observation code
// genuinely use.

/// USB identity facts observed for a Rockchip device, plus the pinned DAYU200
/// identity constants the binding and bootloader observation gates compare
/// against.
package struct RockchipProbeEvidence: Equatable, Sendable {
  package static let rockUSBVendorID: UInt16 = 0x2207
  package static let dayu200LoaderProductID: UInt16 = 0x350a

  package let usbVendorID: UInt16
  package let usbProductID: UInt16
  /// Mode string reported by ArkForge native discovery, e.g. "Loader" or "Maskrom".
  package let reportedMode: String

  public init(usbVendorID: UInt16, usbProductID: UInt16, reportedMode: String) {
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.reportedMode = reportedMode
  }
}

/// How the review labels its step list: an execute review, a plan-only
/// preparation, or a simulated preview. Presentation vocabulary only — the
/// executed plan is materialized by the engine at submission and by
/// `arkforged` inside the lane.
public enum RockchipFlashExecutionMode: String, CaseIterable, Codable, Equatable, Sendable {
  case execute
  case planOnly
  case simulated
}

/// One observed prerequisite status, merged into the review's prerequisite
/// presentation.
public struct RockchipPrerequisiteObservation: Equatable, Sendable {
  public let identifier: RockchipPrerequisiteIdentifier
  public let status: RockchipPrerequisiteStatus

  public init(
    identifier: RockchipPrerequisiteIdentifier,
    status: RockchipPrerequisiteStatus
  ) {
    self.identifier = identifier
    self.status = status
  }
}
