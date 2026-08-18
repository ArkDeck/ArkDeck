import ArkDeckCore
import ArkForgeIPC
import CryptoKit
import Foundation

/// ArkDeck's side of the `ManagedDeviceControlPort`.
///
/// `arkforged` names a *semantic* action — "put this device in Loader" — and
/// receives back only what this authority observed. It never receives anything
/// that could reach the device directly, which is the point: ArkDeck keeps HDC,
/// the connect key, the endpoint and the server lifecycle, and ArkForge keeps
/// the device mechanics. Neither half can do the other's job by accident,
/// because neither half is handed the means (ArkForge `architecture.md` 9.2).
///
/// The mapping table's canonical copy is ArkForge's
/// `adapters/arkforge-arkdeck-adapter/src/control.rs`, which asserts that every
/// control action binds to at least one ArkDeck action and that no binding
/// returns a forbidden fact. This file is the executable other half.
package enum ArkForgeManagedControlPort {

  /// The provider actions each semantic action lowers to, in order.
  ///
  /// `enterUpdater` is five observations, not one command. Mapping it to
  /// `enterLoader` alone would record "the command was accepted" as "the device
  /// is in Loader" — a claim about the device made from a fact about the
  /// message. What must be true is all three: accepted, the bound identity
  /// disconnected, and exactly one device rebound in Loader mode.
  package static func providerActions(
    for action: ArkForgeManagedControlAction
  ) -> [String] {
    switch action {
    case .enterUpdater:
      return [
        "observeHDCNormalUSB", "enterLoader", "waitForHDCDisconnect",
        "waitForLoader", "rebindLoader",
      ]
    case .rebootToNormal:
      // In Loader mode there is no HDC to talk to. ArkForge issues the reset
      // through its native RockUSB backend; ArkDeck contributes the half only it can, which is
      // watching the exact bound target come back.
      return ["waitForBoundHDCReconnect"]
    case .readProductFacts, .readBuildFacts:
      return ["verifyBoundBuild"]
    case .unspecified:
      return []
    }
  }

  /// The facts a receipt for this action is expected to carry.
  package static func expectedReceiptFacts(
    for action: ArkForgeManagedControlAction
  ) -> [String] {
    switch action {
    case .enterUpdater, .rebootToNormal:
      return ["mode", "stableIdentitySHA256", "usbTopology"]
    case .readProductFacts:
      return ["const.product.model"]
    case .readBuildFacts:
      return ["const.ohos.fullname"]
    case .unspecified:
      return []
    }
  }

  /// Keys that must never appear in a receipt, in any action.
  ///
  /// Byte-identical to ArkForge's `FORBIDDEN_RECEIPT_FACTS`. The daemon rejects
  /// a receipt carrying one of these outright — it does not drop the field and
  /// continue — so this list is checked here first, where the receipt is built,
  /// and the failure is a refusal to send rather than a refusal on arrival.
  package static let forbiddenReceiptFacts: Set<String> = [
    "connectKey", "hdcExecutablePath", "hdcEndpoint", "argv", "shell",
    "serverLifecycleAction",
  ]

  /// Why a receipt must not be sent.
  package enum ReceiptRefusal: Error, Equatable, CustomStringConvertible {
    case forbiddenFact(String)
    case successWithoutItsFacts(action: String, missing: [String])
    case enterUpdaterWithoutFullObservation(missing: [String])

    package var description: String {
      switch self {
      case .forbiddenFact(let key):
        return
          "a receipt carrying `\(key)` would hand ArkForge something that reaches the device "
          + "directly; architecture.md 9.2 forbids it and the daemon rejects the whole receipt"
      case .successWithoutItsFacts(let action, let missing):
        return
          "\(action) claims success without \(missing.joined(separator: ", ")); a success "
          + "whose evidence is absent is a claim, not an observation"
      case .enterUpdaterWithoutFullObservation(let missing):
        return
          "enterUpdater needs the command accepted, the bound identity disconnected, and "
          + "exactly one Loader rebind; missing \(missing.joined(separator: ", ")). Reporting "
          + "success on the command alone records a fact about the message as a fact about "
          + "the device"
      }
    }
  }

  /// What this authority observed while performing a control action.
  ///
  /// `accepted: false` does **not** mean nothing happened — a mode change may
  /// have taken effect unobserved, and the daemon records that as an unknown
  /// outcome rather than a failure. To say "it definitely did not happen", give
  /// `failureReason` the evidence.
  package struct Observation: Sendable, Equatable {
    package let accepted: Bool
    package let facts: [String: String]
    package let evidenceSHA256: [UInt8]
    package let failureReason: String
    /// For `enterUpdater`: which of the three observations were actually made.
    package let observedDisconnect: Bool
    package let observedUniqueLoaderRebind: Bool

    package init(
      accepted: Bool, facts: [String: String], evidenceSHA256: [UInt8],
      failureReason: String = "", observedDisconnect: Bool = false,
      observedUniqueLoaderRebind: Bool = false
    ) {
      self.accepted = accepted
      self.facts = facts
      self.evidenceSHA256 = evidenceSHA256
      self.failureReason = failureReason
      self.observedDisconnect = observedDisconnect
      self.observedUniqueLoaderRebind = observedUniqueLoaderRebind
    }
  }

  /// Builds the receipt to send, or refuses to build one.
  ///
  /// The refusal is the useful part. A receipt is the only thing ArkForge
  /// learns about the device from this side, so everything that must not travel
  /// is stopped here rather than discovered by the daemon.
  package static func receipt(
    jobID: String, requestID: String, action: ArkForgeManagedControlAction,
    observation: Observation
  ) throws -> ArkForgeSubmitManagedControlReceiptRequest {
    for key in observation.facts.keys where forbiddenReceiptFacts.contains(key) {
      throw ReceiptRefusal.forbiddenFact(key)
    }
    // Also catch a forbidden name hidden inside a fact's *value* — a receipt
    // that puts the connect key in a message string leaks it just as well as
    // one that puts it in a key.
    for (key, value) in observation.facts {
      for forbidden in forbiddenReceiptFacts where value.contains(forbidden) {
        throw ReceiptRefusal.forbiddenFact("\(key) → \(forbidden)")
      }
    }

    if observation.accepted {
      let missing = expectedReceiptFacts(for: action).filter { observation.facts[$0] == nil }
      guard missing.isEmpty else {
        throw ReceiptRefusal.successWithoutItsFacts(
          action: String(describing: action), missing: missing)
      }
      if action == .enterUpdater {
        var absent: [String] = []
        if !observation.observedDisconnect { absent.append("the bound identity's disconnect") }
        if !observation.observedUniqueLoaderRebind {
          absent.append("a unique Loader rebind")
        }
        guard absent.isEmpty else {
          throw ReceiptRefusal.enterUpdaterWithoutFullObservation(missing: absent)
        }
      }
    }

    // The evidence digest of an accepted receipt is defined, not supplied: the
    // canonical digest of the receipt's own facts, which the daemon recomputes
    // before taking the receipt. A refusal made no observation and carries no
    // evidence — and the daemon takes it that way, rather than demanding a
    // digest of nothing.
    return ArkForgeSubmitManagedControlReceiptRequest(
      jobID: jobID, requestID: requestID, action: action, accepted: observation.accepted,
      facts: observation.facts
        .sorted { $0.key < $1.key }
        .map { ArkForgeKeyValue(key: $0.key, value: $0.value) },
      evidenceSHA256: observation.accepted ? canonicalFactsDigest(observation.facts) : [],
      failureReason: observation.failureReason)
  }

  /// The defined evidence digest of an accepted receipt: SHA-256 over
  /// `key=value\n` lines with the keys in byte order.
  ///
  /// `arkforged` recomputes exactly this before accepting a receipt
  /// (`canonical_facts_digest`, jobs.rs), so the two spellings must stay
  /// byte-identical — facts and evidence that can drift apart across the
  /// boundary are how this channel failed the first time. Keys are sorted by
  /// their UTF-8 bytes, matching Rust's `&str` ordering, not by Swift's
  /// Unicode-aware `<`.
  package static func canonicalFactsDigest(_ facts: [String: String]) -> [UInt8] {
    var bytes = Data()
    let ordered = facts.sorted {
      Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8))
    }
    for (key, value) in ordered {
      bytes.append(contentsOf: Data(key.utf8))
      bytes.append(0x3d)  // "="
      bytes.append(contentsOf: Data(value.utf8))
      bytes.append(0x0a)  // "\n"
    }
    return Array(SHA256.hash(data: bytes))
  }

  /// Scans anything bound for a journal or a UI event for the same leaks.
  ///
  /// The receipt is not the only way a connect key escapes: the same facts are
  /// written to the runtime journal and published as UI events, and a secret
  /// that leaks there has leaked. Returns the offending keys, empty when clean.
  package static func leakedFacts(in text: String) -> [String] {
    forbiddenReceiptFacts.filter { text.contains($0) }.sorted()
  }
}
