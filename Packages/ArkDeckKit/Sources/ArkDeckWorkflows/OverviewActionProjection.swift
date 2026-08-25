// The Overview's "start a new one" row.
//
// The capability matrix states adjectives — available, limited, unavailable,
// unknown — and leaves the reader to work out the consequence. This turns each
// one into the thing an operator can act on: an entry that opens, or a named
// reason it does not, plus the effect grade so nobody learns what a button
// costs by pressing it.
//
// The rule this exists to hold: a probe that did not answer is NOT-PROBED, and
// never unavailable. ArkDeck does not infer absence from a failed probe.

import ArkDeckCore
import Foundation

public struct OverviewAction: Identifiable, Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case uiDump
    case trace
    case debugHAP
    case flash
    case toolkit
  }

  public enum Availability: Sendable, Equatable {
    case available
    /// Probed and answered, but not with everything this entry needs.
    case limited(reason: String)
    /// Runtime or Catalog stated it is not available, and why.
    case unavailable(reason: String)
    /// Nothing probed this. Absence of an answer, not an answer of absence.
    case notProbed(reason: String)

    public var opensWorkspace: Bool {
      switch self {
      case .available, .limited: true
      case .unavailable, .notProbed: false
      }
    }
  }

  public let kind: Kind
  public let operationReference: String
  /// The Catalog effect grade this entry submits under. Shown before the entry
  /// is used, not after.
  public let effect: String
  public let availability: Availability
  /// The probe result behind the verdict, verbatim where there is one.
  public let evidence: String?

  public var id: String { kind.rawValue }
}

public enum OverviewActionProjection {
  /// Which matrix row backs each entry, and what it submits.
  static let backing: [OverviewAction.Kind: (capability: String?, operation: String, effect: String)] = [
    .uiDump: ("hidumper", "capture.diagnostics@1", "readOnly"),
    .trace: ("hitrace", "capture.diagnostics@1", "readOnly"),
    .debugHAP: (nil, "debug.hap@1", "deviceMutation"),
    .flash: ("rockusb-flash", ArkForgeFlashOperation.canonicalReference, "destructive"),
    .toolkit: (nil, "input.tap@1", "deviceMutation"),
  ]

  /// Fixed order, so the row does not reshuffle as probes come back.
  static let order: [OverviewAction.Kind] = [.uiDump, .trace, .debugHAP, .flash, .toolkit]

  /// Which workspace owns a finished run, so "run it again" opens the one that
  /// submitted it.
  ///
  /// The operation reference alone is not always enough: Viewer and Trace both
  /// submit `capture.diagnostics@1`, and they differ only in the typed inputs
  /// they asked for. Where the reported inputs do not settle it, this returns
  /// nil — opening the wrong workspace would prefill a different request than
  /// the one being repeated.
  public static func workspaceKind(
    forOperation reference: String,
    parameters: [RuntimeJobParameterPresentation]
  ) -> OverviewAction.Kind? {
    let values = Dictionary(
      parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    func isTrue(_ name: String) -> Bool {
      values[name].map { $0.lowercased() == "true" } ?? false
    }

    // Flash identity goes through the canonical policy: a durable record may
    // still carry the compatibility alias, and only that policy knows both.
    if ArkForgeFlashOperation.contains(reference)
      || ArkForgeFlashOperation.containsDurableRecordReference(reference)
    {
      return .flash
    }

    switch reference.split(separator: "@").first.map(String.init) {
    case "debug.hap": return .debugHAP
    case "input.tap", "input.long-press", "input.swipe": return .toolkit
    case "capture.diagnostics":
      if isTrue("uiComponentTree") || isTrue("advancedDump") { return .uiDump }
      if let categories = values["traceCategories"],
        !categories.isEmpty, categories != "[]"
      {
        return .trace
      }
      // A screenshot-only capture is the Toolkit's, but only when nothing else
      // in the request claims it.
      if isTrue("uiScreenshot"), !isTrue("uiDump") { return .toolkit }
      return nil
    default: return nil
    }
  }

  public static func actions(
    from matrix: OverviewCapabilityMatrixPresentation
  ) -> [OverviewAction] {
    let items = Dictionary(
      matrix.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    return order.compactMap { kind -> OverviewAction? in
      guard let backing = backing[kind] else { return nil }
      let availability: OverviewAction.Availability
      var evidence: String?

      if let capability = backing.capability, let item = items[capability] {
        evidence = item.evidence
        switch item.state {
        case .available:
          availability = .available
        case .limited:
          availability = .limited(reason: item.evidence)
        case .unavailable:
          availability = .unavailable(reason: item.evidence)
        case .unknown:
          availability = .notProbed(reason: item.evidence)
        }
      } else if let capability = backing.capability {
        // The row this entry reads is missing from the matrix. That is a gap
        // in what was probed, so it reads as not probed — with the matrix's
        // own failure when it gave one.
        availability = .notProbed(
          reason: matrix.failure ?? "Runtime reported no \(capability) probe result")
      } else {
        availability = .notProbed(
          reason: matrix.failure ?? "no published probe reports this capability yet")
      }

      return OverviewAction(
        kind: kind,
        operationReference: backing.operation,
        effect: backing.effect,
        availability: availability,
        evidence: evidence)
    }
  }
}
