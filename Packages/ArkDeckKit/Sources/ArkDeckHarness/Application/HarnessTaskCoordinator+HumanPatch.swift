// Typed PROPOSE_PATCH entry at the human boundary (TASK-HFA-005).
//
// A deterministic harness can identify that verified evidence needs a source
// repair, but it cannot invent patch bytes. A human - or an external agent
// the operator drives through the same typed CLI - may supply that one
// bounded decision. The producer label is a closed set so the durable record
// says truthfully who answered; it grants nothing, because both labels face
// the identical parse, validation, budget and dispatch boundary. The
// coordinator still owns the operation, workspace lease, capability check,
// idempotency identity and every later stage transition.

import ArkDeckCore
import Foundation

extension HarnessTaskCoordinator {
  package static let humanPatchProducer = "human-operator"
  package static let externalAgentPatchProducer = "external-agent"
  /// The closed producer set for this entry. A label outside it is a
  /// configuration error, not a new kind of authority.
  package static let typedPatchProducers: Set<String> = [
    humanPatchProducer, externalAgentPatchProducer,
  ]
  static let maximumHumanPatchProposalBytes = 512 * 1024

  /// Accept one strict PROPOSE_PATCH document at the existing human boundary.
  ///
  /// The first call prepares an immutable patch Artifact before normal policy
  /// admission. It then schedules checkpoint and apply as separate durable
  /// Decisions. If either admission stops for a maintainer-issued workspace
  /// grant, a semantically identical parsed proposal may be submitted again.
  /// The retry reuses the prepared inputs and that stage's decision/request/
  /// idempotency identity; it never republishes or replaces patch bytes.
  package func proposePatch(
    _ taskID: String,
    proposalJSON: Data,
    producer: String = HarnessTaskCoordinator.humanPatchProducer
  ) async throws -> HarnessReconcileOutcome {
    guard Self.typedPatchProducers.contains(producer) else {
      throw HarnessCoordinatorError.malformedPatchProposal(
        "unknownPatchProducer:\(producer)")
    }
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
      let outcome = try await proposePatchWithLease(
        taskID, proposalJSON: proposalJSON, producer: producer)
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
    proposalJSON: Data,
    producer: String
  ) async throws -> HarnessReconcileOutcome {
    let blocked = try await status(taskID)
    guard blocked.lifecycle == .humanRequired, blocked.activeJobID == nil else {
      throw HarnessCoordinatorError.patchProposalNotAllowed(blocked.lifecycle.rawValue)
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

      // `reconcile` checks the hard task budget before it creates a decision.
      // This typed human entry must preserve the same ordering: a proposal
      // arriving after the deadline may be parsed and validated, but it must
      // not resume the task, create Attempt history, or publish patch bytes.
      if let stopped = try await stopForExhaustedHumanPatchBudget(
        blocked, round: nextRound)
      {
        return stopped
      }

      // A task persisted before execution-fact envelopes existed may already
      // be sitting at this human boundary without Attempt history. Establish
      // the same journey identity reconcile would have created, then resume
      // it before stamping the operator decision. The live workspace read at
      // dispatch must still equal the proposal's exact base revision.
      try await ensureInitialJourneyAttempt(blocked)
      // The resolution names the producer so the event ledger and the
      // resolved human-action record stay a truthful account of who answered
      // at this boundary - a person, or an agent outside the daemon.
      let resumed = try await resume(
        taskID,
        resolution: producer == Self.humanPatchProducer
          ? "humanPatchProposalAccepted" : "externalAgentPatchProposalAccepted")
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
        producer: producer, createdAtUTC: nowUTC()
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

    // A maintainer grant can arrive long after patch preparation. Recheck the
    // overall task deadline before resolving the human block so an expired
    // retry cannot dispatch the already-prepared mutation.
    if let stopped = try await stopForExhaustedHumanPatchBudget(
      blocked, round: nextRound)
    {
      return stopped
    }

    // Authorization changes outside the task state. Re-stamp the exact
    // already-prepared decision on the human resolution, then re-enter the
    // ordinary dispatch boundary with its original identity.
    let resumed = try await resume(taskID, resolution: "workspaceAuthorizationAvailable")
    let basis = HarnessDecisionBasis(
      snapshot: resumed, offeredOperations: offeredOperations(resumed, handler: handler))
    let restamped = executable.stamped(with: basis)
    try await store.putDecision(restamped)
    let step = HarnessPlannedStep(decision: restamped, phaseOnDispatch: .patching)
    if restamped.operationReference == DebugCrashTaskHandler.createCheckpoint
      || (restamped.operationReference == DebugCrashTaskHandler.applyPatch
        && resumed.repairAttempt?.checkpointJobID == nil)
    {
      // Forward-migrate a prepared apply Decision written before checkpoint
      // became explicit. Reuse its Artifact lease and proposal identity, but
      // never let it bypass the new checkpoint ActionRun.
      return try await dispatchPatch(
        step, snapshotAtPlanning: resumed, handler: handler)
    }
    return try await dispatch(
      step, snapshotAtPlanning: resumed, handler: handler)
  }

  private func stopForExhaustedHumanPatchBudget(
    _ snapshot: HarnessTaskSnapshot,
    round: Int
  ) async throws -> HarnessReconcileOutcome? {
    guard
      let refusal = HarnessPolicyGuard.budgetRefusal(
        snapshot, elapsedSeconds: elapsedSeconds(since: snapshot.createdAtUTC))
    else { return nil }
    return try await stop(
      snapshot, refusal: refusal, round: round, requestID: nil, jobID: nil)
  }

  private static func isWorkspaceAuthorizationStop(_ reason: String) -> Bool {
    let lowered = reason.lowercased()
    return lowered.contains("authorization")
      && [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch]
        .contains { lowered.contains($0.lowercased()) }
  }

  private static func matches(
    _ proposal: HarnessDecisionProposal,
    executableDecision: HarnessDecision
  ) -> Bool {
    // Any typed-entry producer may retry a prepared decision; the restamp
    // keeps the stored producer, so a retry can never relabel who proposed.
    executableDecision.kind == .proposePatch
      && typedPatchProducers.contains(executableDecision.producer)
      && executableDecision.operationReference.map {
        [DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch]
          .contains($0)
      } == true
      && executableDecision.patchProposal == proposal.patchProposal
      && executableDecision.requiredArtifacts == proposal.requiredArtifacts
      && executableDecision.expectedObservation == proposal.expectedObservation
      && executableDecision.hypothesis == proposal.hypothesis
      && executableDecision.reasonCode == proposal.reasonCode
      && !executableDecision.inputs.isEmpty
  }
}
