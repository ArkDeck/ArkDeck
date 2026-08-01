// Where a proposal comes from (CHG-2026-054, TASK-HTP-004).
//
// One wake needs exactly one proposed step. It comes from the deterministic
// handler unless *all* of these hold: the project has egress enabled, a
// gateway adapter is configured, the bounded context assembles within its
// byte ceiling, it passes the identity screen, and the returned bytes survive
// the strict parser.
//
// Any failure along that chain falls back to the deterministic handler for
// that wake - and records why, in the task's own memory and in the decision
// record. The fallback is strictly narrower than the model path (E0 only,
// closed operation set), so it cannot be a quiet escalation; what it must not
// be is invisible, which is why nothing here swallows a rejection.

import ArkDeckCore
import ArkDeckStorage
import Foundation

extension HarnessTaskCoordinator {
  struct PlannedProposal {
    let step: HarnessPlannedStep
    let producer: String
    /// Model calls this wake spent, whatever came back. It is applied by the
    /// caller's transition rather than committed here: a commit inside
    /// planning would move the state version the freshness guard checks
    /// (TASK-HFA-002), turning every model-backed decision stale.
    var modelCallsSpent: Int = 0
    /// Non-nil when a model path was attempted and refused.
    let rejection: String?
  }

  /// The operations a producer may choose from this wake: the task's declared
  /// allow-set intersected with what the task type permits. Nothing outside
  /// this set is offered, so "not offered" is a checkable rejection reason.
  func offeredOperations(
    _ snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler
  ) -> [String] {
    snapshot.policy.allowedOperations
      .filter { handler.offeredOperations(for: snapshot).contains($0) }
      .sorted()
  }

  func plannedProposal(
    _ snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler,
    basis: HarnessDecisionBasis
  ) async -> PlannedProposal {
    let deterministic = handler.plan(
      for: snapshot, decisionID: decisionIDFactory(), nowUTC: nowUTC())

    guard let decisionGateway else {
      return PlannedProposal(
        step: deterministic, producer: deterministic.decision.producer, rejection: nil)
    }
    switch egressPolicy.decide(projectRef: snapshot.projectRef) {
    case .denied(let reason):
      // Not an error and not a silent skip: the record says the loop ran on
      // the deterministic strategy because egress was denied.
      return PlannedProposal(
        step: deterministic, producer: deterministic.decision.producer,
        rejection: "egressDenied:\(reason)")
    case .allowed(let limits):
      // Everything from here on is a model call that happened, whatever it
      // returns. `record` writes the audit row exactly once per outcome
      // (TASK-HFA-002) - a call that was refused by the parser is still a
      // call that shipped a context off this host.
      let startedAtUTC = nowUTC()
      var contextDigest = ""
      var contextBytes = 0
      func record(_ outcome: HarnessModelRunOutcome, responseBytes: Int = 0) async {
        let run = HarnessModelRun(
          modelRunID: modelRunIDFactory(),
          htaskID: snapshot.htaskID,
          round: snapshot.activeRound + 1,
          descriptor: decisionGateway.modelDescriptor,
          observedStateVersion: basis.stateVersion,
          contextDigest: contextDigest,
          contextBytes: contextBytes,
          responseBytes: responseBytes,
          outcome: outcome,
          startedAtUTC: startedAtUTC,
          finishedAtUTC: nowUTC())
        try? await store.putModelRun(run)
      }
      do {
        let context = try await assembleContext(snapshot, handler: handler, limits: limits)
        let violations = HarnessEgressScreen.violations(
          in: context, targetID: snapshot.target.targetID)
        guard violations.isEmpty else {
          // Nothing left this host, so there is no model run to record.
          return PlannedProposal(
            step: deterministic, producer: deterministic.decision.producer,
            rejection: "egressScreen:\(violations.joined(separator: ","))")
        }
        // Digest of what the adapter is about to receive - after trimming
        // and screening, so it stands for the bytes that actually left.
        contextDigest = context.transmittedDigest
        contextBytes = context.transmittedByteCount
        let bytes = try await decisionGateway.propose(context)
        do {
          let proposal = try HarnessDecisionProposal.parse(
            bytes, offeredOperations: Set(context.availableOperations))
          try Self.validateModelProposal(proposal, against: deterministic.decision)
          let decision = HarnessDecision(
            decisionID: decisionIDFactory(),
            htaskID: snapshot.htaskID,
            round: snapshot.activeRound + 1,
            kind: proposal.kind,
            operationReference: proposal.operationReference,
            inputs: proposal.inputs,
            patchProposal: proposal.patchProposal,
            requiredArtifacts: proposal.requiredArtifacts,
            expectedObservation: proposal.expectedObservation,
            hypothesis: proposal.hypothesis,
            reasonCode: proposal.reasonCode,
            producer: decisionGateway.producerID,
            createdAtUTC: nowUTC())
          await record(.accepted(decisionID: decision.decisionID), responseBytes: bytes.count)
          return PlannedProposal(
            step: HarnessPlannedStep(
              decision: decision,
              // Phase movement stays the handler's: a producer proposes a step,
              // not a debug-journey transition.
              phaseOnDispatch: proposal.kind == .proposePatch
                ? .patching : deterministic.phaseOnDispatch),
            producer: decisionGateway.producerID,
            modelCallsSpent: 1,
            rejection: nil)
        } catch let rejection as HarnessDecisionRejection {
          await record(
            .rejected(reasonCode: rejection.reasonCode), responseBytes: bytes.count)
          return PlannedProposal(
            step: deterministic, producer: deterministic.decision.producer,
            modelCallsSpent: 1,
            rejection: "proposalRejected:\(rejection.reasonCode)")
        }
      } catch let error as HarnessDecisionGatewayError {
        if case .contextTooLarge = error {
          // Assembly refused before any transport: no call happened.
          return PlannedProposal(
            step: deterministic, producer: deterministic.decision.producer,
            rejection: "gatewayUnavailable:\(Self.describe(error))")
        }
        await record(.transportFailed(reasonCode: Self.describe(error)))
        return PlannedProposal(
          step: deterministic, producer: deterministic.decision.producer,
          modelCallsSpent: 1,
          rejection: "gatewayUnavailable:\(Self.describe(error))")
      } catch {
        await record(.transportFailed(reasonCode: "gatewayFailure"))
        return PlannedProposal(
          step: deterministic, producer: deterministic.decision.producer,
          modelCallsSpent: 1,
          rejection: "gatewayFailure")
      }
    }
  }

  /// Runtime orchestration owns every typed operation input. The model may
  /// choose the handler's offered operation, but it cannot attach contextual
  /// metadata (for example the target pseudonym) or substitute a lease,
  /// preset, bundle, ability, duration, or rollback reference. Patch bytes
  /// remain the one bounded exception, and only while the handler is
  /// explicitly asking for a proposal.
  static func validateModelProposal(
    _ proposal: HarnessDecisionProposal,
    against deterministic: HarnessDecision
  ) throws {
    if proposal.kind == .proposePatch {
      guard deterministic.kind == .requestHuman,
        deterministic.reasonCode == "patchProposalRequired"
      else {
        throw HarnessDecisionRejection.operationNotExpected(DebugCrashTaskHandler.applyPatch)
      }
      return
    }
    if proposal.kind == .invokeOperation, let proposed = proposal.operationReference {
      guard proposed != DebugCrashTaskHandler.applyPatch,
        deterministic.kind == .invokeOperation,
        deterministic.operationReference == proposed,
        deterministic.inputs == proposal.inputs
      else { throw HarnessDecisionRejection.operationNotExpected(proposed) }
      return
    }
    let orchestrated: Set<String> = [
      DebugCrashTaskHandler.applyPatch, DebugCrashTaskHandler.buildOpenHarmony,
      DebugCrashTaskHandler.runTests, DebugCrashTaskHandler.revertPatch,
      DebugCrashTaskHandler.deployHAP, DebugCrashTaskHandler.analyzeCrashLedger,
    ]
    if deterministic.kind == .invokeOperation,
      let expected = deterministic.operationReference,
      orchestrated.contains(expected)
    {
      throw HarnessDecisionRejection.operationNotExpected(
        proposal.operationReference ?? expected)
    }
  }

  func assembleContext(
    _ snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler,
    limits: HarnessDecisionContextLimits
  ) async throws -> HarnessDecisionContext {
    let offered = offeredOperations(snapshot, handler: handler)
    let durableAttempts = (try? await store.attempts(snapshot.htaskID)) ?? []
    let attempts: [HarnessContextAttempt]
    if !durableAttempts.isEmpty {
      attempts = durableAttempts.map { attempt in
        HarnessContextAttempt(
          round: attempt.ordinal,
          operationReference: attempt.strategy.selectedOperationFamily,
          outcome: attempt.outcome.rawValue,
          reasonCode: "strategy:\(attempt.strategyFingerprint)")
      }
    } else {
      // Forward-readable fallback for tasks created before Attempt events
      // existed. New tasks never synthesize strategy identity from prose.
      let events = (try? await store.events(snapshot.htaskID)) ?? []
      attempts = events.compactMap { event -> HarnessContextAttempt? in
        guard event.causation == .jobDispatched || event.causation == .jobObserved,
          let jobID = event.jobID
        else { return nil }
        return HarnessContextAttempt(
          round: event.resulting.activeRound,
          operationReference: Self.operationReference(fromReason: event.reasonCode) ?? "-",
          outcome: event.causation == .jobDispatched ? "dispatched" : "observed",
          reasonCode: event.reasonCode.replacingOccurrences(of: jobID, with: "job"))
      }
    }
    let failureRecords = ((try? await store.failureRecords()) ?? [])
      .filter { offered.contains($0.fingerprint.operationReference) }
    let failures = failureRecords
      .map { record in
        HarnessContextFailure(
          digest: record.digest,
          operationReference: record.fingerprint.operationReference,
          occurrences: record.occurrences,
          stance: record.stance,
          errorClassification: record.fingerprint.errorClassification,
          semanticErrorCode: record.fingerprint.semanticErrorCode,
          retryDisposition: record.retryDisposition,
          alternativeHints: record.alternativeHints)
      }
    var memory = (try? await store.memory(scope: .task, key: snapshot.htaskID)) ?? []
    if let projectRef = snapshot.projectRef {
      memory += (try? await store.memory(scope: .project, key: projectRef)) ?? []
    }
    var evaluation: HarnessEvaluation?
    if let evaluationID = snapshot.latestEvaluationID {
      evaluation = try? await store.evaluation(snapshot.htaskID, evaluationID: evaluationID)
    }
    let artifacts = (evaluation?.evidence ?? []).map { record in
      HarnessContextArtifact(
        artifactID: record.artifactID, name: record.name, byteCount: record.byteCount,
        // A digest prefix identifies an artifact across rounds without
        // shipping its contents.
        sha256Prefix: String(record.sha256.prefix(12)), verified: record.verified)
    }
    func desiredText(_ key: String) -> String? {
      guard case .string(let value)? = snapshot.goal.desiredState[key] else { return nil }
      return value
    }
    let repair = snapshot.repairAttempt
    let memoryQuery = HarnessMemoryQuery(
      htaskID: snapshot.htaskID,
      projectRef: snapshot.projectRef,
      failureFingerprints: failureRecords.map(\.digest)
        + durableAttempts.compactMap(\.failureFingerprint),
      components: [snapshot.type.rawValue, desiredText("component")].compactMap { $0 },
      filePaths: repair?.proposal.touchedFiles ?? [],
      symbols: repair?.proposal.expectedChangedSymbols ?? [],
      operationReferences: offered + durableAttempts.map {
        $0.strategy.selectedOperationFamily
      },
      revision: durableAttempts.last?.patchRevision ?? durableAttempts.last?.baseRevision
        ?? repair?.patchRevision ?? repair?.proposal.baseWorkspaceRevision
        ?? desiredText("baseWorkspaceRevision"),
      deviceProfiles: [desiredText("deviceProfile")].compactMap { $0 },
      toolchainProfiles: durableAttempts.map { $0.strategy.executionExpectation.toolchainProfile }
        + [desiredText("buildPresetRef"), desiredText("testPresetRef")].compactMap { $0 })
    return try HarnessDecisionContextAssembler(limits: limits).assemble(
      snapshot: snapshot,
      availableOperations: offered,
      evaluation: evaluation,
      attempts: attempts,
      failures: failures,
      memory: memory,
      artifacts: artifacts,
      elapsedSeconds: elapsedSeconds(since: snapshot.createdAtUTC) ?? 0,
      memoryQuery: memoryQuery)
  }

  static func operationReference(fromReason reason: String) -> String? {
    // Reason codes are `<code>:<operationRef>[:<detail>]`; the operation is
    // the first component that looks like `id@version`.
    reason.split(separator: ":").map(String.init).first { $0.contains("@") }
  }

  static func describe(_ error: HarnessDecisionGatewayError) -> String {
    switch error {
    case .unavailable(let reason): return "unavailable:\(reason)"
    case .transportFailure: return "transport"
    case .contextTooLarge(let bytes, let limit): return "contextTooLarge:\(bytes)>\(limit)"
    }
  }
}
