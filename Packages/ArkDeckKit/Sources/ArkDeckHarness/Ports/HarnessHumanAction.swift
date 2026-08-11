// The harness as a producer of typed human actions (CHG-2026-054, TASK-HTP-003).
//
// `HumanActionRequired` has existed in this package since CHG-2026-025 with a
// complete category vocabulary, a per-category minimum action, a prohibited
// automation list and a resume probe - and, until now, no producer on the
// runtime path. The harness is that producer.
//
// Two rules keep the document honest:
//
//   * the category is chosen from the closed set, and the model itself fills
//     reasonCode / minimumActionKey / prohibitedAutomation / resumeProbe. The
//     harness cannot write its own idea of what a human must do;
//   * where no category describes the block, no document is produced. A
//     strategy that ran out and evidence that failed verification are real
//     stops, but neither is one of the eight defined human actions, and
//     filling the field anyway would be putting untrue content into an
//     evidence-grade record (the CHG-2026-050 lesson: do not substitute the
//     nearest available identity).

import ArkDeckCore
import ArkDeckRuntime
import Foundation

public enum HarnessHumanActionFactory {
  /// The subset of harness blocks the closed category vocabulary covers.
  public static func category(for block: HarnessHumanBlock) -> HumanActionCategory? {
    switch block {
    case .authorizationApproval: return .impactApproval
    case .outcomeUnknown: return .outcomeUnknownDecision
    // No typed category is invented for these. The record still exists — it
    // carries status, reason code and evidence — because a stop with nothing
    // in the human's queue is worse than a stop with no typed document.
    case .strategyExhausted, .evidenceIntegrity, .environmentUnavailable,
      .producerProposalRequired:
      return nil
    }
  }

  public static func make(
    actionID: String,
    snapshot: HarnessTaskSnapshot,
    block: HarnessHumanBlock,
    reasonCode: String,
    round: Int?,
    jobID: String?,
    requestID: String?,
    evidenceRefs: [String],
    nowUTC: String
  ) -> HarnessStoredHumanAction {
    var document: JSONValue?
    if let category = category(for: block) {
      // The document's `jobId` names the runtime work the block is about: the
      // job when one exists, otherwise the refused request identity. Never a
      // task id dressed up as a job id.
      let correlation = jobID ?? requestID
      if let correlation,
        let action = try? HumanActionRequired(
          actionID: actionID, jobID: correlation, category: category, generatedAtUTC: nowUTC)
      {
        document = encode(action)
      }
    }
    return HarnessStoredHumanAction(
      actionID: actionID,
      htaskID: snapshot.htaskID,
      block: block,
      reasonCode: reasonCode,
      round: round,
      jobID: jobID,
      requestID: requestID,
      document: document,
      // Resuming returns the task to the phase it was blocked in: a human
      // decision does not rewind the debug journey.
      resumeStatus: .running,
      resumePhase: snapshot.stage,
      evidenceRefs: evidenceRefs,
      generatedAtUTC: nowUTC)
  }

  /// Resolve an open block with a typed human decision. When the record holds
  /// a `HumanActionRequired`, the document's own state machine performs the
  /// transition, so a resolution that its rules reject (wrong probe, stale
  /// timestamp, expired action) cannot be recorded as resolved.
  public static func resolve(
    _ stored: HarnessStoredHumanAction,
    resolution: String,
    probeReceiptID: String,
    nowUTC: String
  ) throws -> HarnessStoredHumanAction {
    guard stored.isOpen else { throw HumanActionRequiredError.invalidTransition }
    guard let documentValue = stored.document else {
      // No typed document: the record itself carries the resolution.
      return stored.resolved(at: nowUTC, resolution: resolution)
    }
    let action = try decode(documentValue)
    let receipt = try HumanActionFreshProbeReceipt(
      probeOperationID: action.resumeProbeOperationID,
      probeReceiptID: probeReceiptID,
      observedAtUTC: nowUTC)
    let resolved = try action.resolving(with: receipt)
    return stored.resolved(at: nowUTC, resolution: resolution, document: encode(resolved))
  }

  static func encode(_ action: HumanActionRequired) -> JSONValue? {
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(action),
      let projected = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    return projected
  }

  static func decode(_ value: JSONValue) throws -> HumanActionRequired {
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(value) else {
      throw HumanActionRequiredError.malformed(path: "$")
    }
    return try JSONDecoder().decode(HumanActionRequired.self, from: data)
  }
}
