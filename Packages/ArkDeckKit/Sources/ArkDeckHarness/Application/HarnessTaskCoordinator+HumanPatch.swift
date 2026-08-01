// Typed human PROPOSE_PATCH entry (TASK-HFA-005).
//
// A deterministic harness can identify that verified evidence needs a source
// repair, but it cannot invent patch bytes. A human may supply that one bounded
// decision. The coordinator still owns the operation, workspace lease,
// capability check, idempotency identity and every later stage transition.

import ArkDeckCore
import Foundation

extension HarnessTaskCoordinator {
  static let humanPatchProducer = "human-operator"
  static let maximumHumanPatchProposalBytes = 512 * 1024

  /// Accept one strict PROPOSE_PATCH document at the existing human boundary.
  ///
  /// The first call prepares an immutable patch Artifact before normal policy
  /// admission. If admission stops for a maintainer-issued workspace grant, a
  /// semantically identical parsed proposal may be submitted again after that grant lands.
  /// The retry reuses the prepared inputs, decision id, request id and
  /// idempotency key; it never republishes or silently replaces patch bytes.
  public func proposePatch(
    _ taskID: String,
    proposalJSON: Data
  ) async throws -> HarnessReconcileOutcome {
    guard proposalJSON.count <= Self.maximumHumanPatchProposalBytes else {
      throw HarnessCoordinatorError.malformedPatchProposal("patchProposalTooLarge")
    }
    guard reconcilingTaskIDs.insert(taskID).inserted else {
      let snapshot = try await status(taskID)
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .reconcileInProgress,
        reasonCode: "reconcileInProgress")
    }
    defer { reconcilingTaskIDs.remove(taskID) }

    guard
      try await store.acquireReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
    else {
      let snapshot = try await status(taskID)
      return HarnessReconcileOutcome(
        snapshot: snapshot, action: .reconcileInProgress,
        reasonCode: "reconcileLeaseHeld")
    }
    do {
      let outcome = try await proposePatchWithLease(taskID, proposalJSON: proposalJSON)
      try? await store.releaseReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
      return outcome
    } catch {
      try? await store.releaseReconcileLease(
        taskID: taskID, holderID: reconcileLeaseHolderID)
      throw error
    }
  }

  private func proposePatchWithLease(
    _ taskID: String,
    proposalJSON: Data
  ) async throws -> HarnessReconcileOutcome {
    let blocked = try await status(taskID)
    guard blocked.status == .humanRequired, blocked.activeJobID == nil else {
      throw HarnessCoordinatorError.patchProposalNotAllowed(blocked.status.rawValue)
    }
    guard let handler = handlers[blocked.type] else {
      throw HarnessCoordinatorError.unsupportedTaskType(blocked.type)
    }

    let offered = Set(offeredOperations(blocked, handler: handler))
    let proposal: HarnessDecisionProposal
    do {
      proposal = try HarnessDecisionProposal.parse(
        proposalJSON, offeredOperations: offered)
    } catch let rejection as HarnessDecisionRejection {
      throw HarnessCoordinatorError.malformedPatchProposal(rejection.reasonCode)
    }
    guard proposal.kind == .proposePatch else {
      throw HarnessCoordinatorError.malformedPatchProposal("proposePatchKindRequired")
    }

    let nextRound = blocked.activeRound + 1
    let stored = try await store.decision(taskID, round: nextRound)
    let reason = blocked.result?.reasonCode ?? "humanActionRequired"
    if reason == "patchProposalRequired" {
      let deterministic = handler.plan(
        for: blocked, decisionID: decisionIDFactory(), nowUTC: nowUTC())
      do {
        try Self.validateModelProposal(proposal, against: deterministic.decision)
      } catch let rejection as HarnessDecisionRejection {
        throw HarnessCoordinatorError.malformedPatchProposal(rejection.reasonCode)
      }

      // A task persisted before execution-fact envelopes existed may already
      // be sitting at this human boundary without Attempt history. Establish
      // the same journey identity reconcile would have created, then resume
      // it before stamping the operator decision. The live workspace read at
      // dispatch must still equal the proposal's exact base revision.
      try await ensureInitialJourneyAttempt(blocked)
      let resumed = try await resume(taskID, resolution: "humanPatchProposalAccepted")
      guard let attemptID = try await activeAttempt(taskID)?.attemptID else {
        throw HarnessCoordinatorError.malformedRequest("missingActiveAttempt")
      }
      let basis = HarnessDecisionBasis(
        snapshot: resumed, offeredOperations: offeredOperations(resumed, handler: handler))
      let decision = HarnessDecision(
        decisionID: decisionIDFactory(), htaskID: taskID, round: nextRound,
        kind: .proposePatch, patchProposal: proposal.patchProposal,
        requiredArtifacts: proposal.requiredArtifacts,
        expectedObservation: proposal.expectedObservation,
        hypothesis: proposal.hypothesis, reasonCode: proposal.reasonCode,
        producer: Self.humanPatchProducer, createdAtUTC: nowUTC()
      )
      .stamped(
        with: basis, attemptID: attemptID,
        expectedWorkspaceRevision: proposal.patchProposal?.baseWorkspaceRevision)
      try await store.putDecision(decision)
      return try await dispatchPatch(
        HarnessPlannedStep(decision: decision, phaseOnDispatch: .patching),
        snapshotAtPlanning: resumed, handler: handler)
    }

    guard Self.isWorkspaceAuthorizationStop(reason),
      let executable = stored,
      Self.matches(proposal, executableDecision: executable)
    else {
      if Self.isWorkspaceAuthorizationStop(reason), stored != nil {
        throw HarnessCoordinatorError.patchProposalMismatch
      }
      throw HarnessCoordinatorError.patchProposalNotAllowed(reason)
    }

    // Authorization changes outside the task state. Re-stamp the exact
    // already-prepared decision on the human resolution, then re-enter the
    // ordinary dispatch boundary with its original identity.
    let resumed = try await resume(taskID, resolution: "workspaceAuthorizationAvailable")
    let basis = HarnessDecisionBasis(
      snapshot: resumed, offeredOperations: offeredOperations(resumed, handler: handler))
    let restamped = executable.stamped(with: basis)
    try await store.putDecision(restamped)
    return try await dispatch(
      HarnessPlannedStep(decision: restamped, phaseOnDispatch: .patching),
      snapshotAtPlanning: resumed, handler: handler)
  }

  private static func isWorkspaceAuthorizationStop(_ reason: String) -> Bool {
    let lowered = reason.lowercased()
    return lowered.contains("authorization")
      && lowered.contains(DebugCrashTaskHandler.applyPatch.lowercased())
  }

  private static func matches(
    _ proposal: HarnessDecisionProposal,
    executableDecision: HarnessDecision
  ) -> Bool {
    executableDecision.kind == .proposePatch
      && executableDecision.producer == humanPatchProducer
      && executableDecision.operationReference == DebugCrashTaskHandler.applyPatch
      && executableDecision.patchProposal == proposal.patchProposal
      && executableDecision.requiredArtifacts == proposal.requiredArtifacts
      && executableDecision.expectedObservation == proposal.expectedObservation
      && executableDecision.hypothesis == proposal.hypothesis
      && executableDecision.reasonCode == proposal.reasonCode
      && !executableDecision.inputs.isEmpty
  }
}
