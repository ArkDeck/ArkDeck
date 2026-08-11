// Read-only export of the bounded decision context (PRODUCT-LOOP §6 GJ-5).
//
// The primary decision producer for a bounded debug loop is an external agent
// driving the typed CLI: it reads this export, reasons with whatever tools it
// has, and answers at the same strict boundary every other producer answers
// at - `task.proposePatch`. The in-process gateways remain for unattended
// operation, where no external session is alive to ask.
//
// Three properties keep the producers interchangeable:
//
//   * the export is the same document a configured gateway adapter would
//     receive: same assembler, same declared fields and ceilings, same
//     identity screen, same `requestedDecision`. An external producer is not
//     a privileged reader - what the egress screen would refuse to send it
//     refuses to export;
//   * exporting is a read. Nothing durable is written, no budget is charged,
//     and the task's state version does not move - the ledger records
//     producers by what they *submit*, at the proposal boundary;
//   * authority is unchanged. The export cannot widen what a proposal may
//     say: whatever comes back still faces `HarnessDecisionProposal.parse`,
//     the deterministic-decision validation and the Policy Guard.

import ArkDeckCore
import Foundation

/// What `task.context` returns: the bounded context plus the digest an
/// external producer can quote to say which facts its proposal stood on.
package struct HarnessExportedDecisionContext: Sendable, Equatable {
  public let context: HarnessDecisionContext
  package let contextDigest: String
  package let contextBytes: Int

  public init(context: HarnessDecisionContext, contextDigest: String, contextBytes: Int) {
    self.context = context
    self.contextDigest = contextDigest
    self.contextBytes = contextBytes
  }
}

extension HarnessTaskCoordinator {
  /// Assemble and screen the bounded decision context for an external
  /// producer. Available in every task status: a producer deciding whether
  /// to propose needs the same view mid-loop as at a human boundary.
  package func decisionContext(_ taskID: String) async throws -> HarnessExportedDecisionContext {
    let snapshot = try await status(taskID)
    guard let handler = handlers[snapshot.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(snapshot.type)
    }
    // The deterministic plan is consulted only for `requestedDecision` - the
    // question the round is asking, in the producer's vocabulary. The planned
    // step itself is discarded; planning is pure and dispatches nothing.
    let deterministic = handler.plan(
      for: snapshot, decisionID: decisionIDFactory(), nowUTC: nowUTC())
    let context = try await assembleContext(
      snapshot, handler: handler, limits: .default,
      requestedDecision: Self.requestedDecision(from: deterministic.decision))
    let violations = HarnessEgressScreen.violations(
      in: context, targetID: snapshot.target.targetID)
    guard violations.isEmpty else {
      // The screen names markers, never values, so the refusal is safe to
      // surface verbatim.
      throw HarnessCoordinatorError.contextNotExportable(
        violations.joined(separator: ","))
    }
    return HarnessExportedDecisionContext(
      context: context,
      contextDigest: context.transmittedDigest,
      contextBytes: context.transmittedByteCount)
  }
}
