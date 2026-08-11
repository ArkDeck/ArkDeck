// Where a proposal comes from (CHG-2026-054, TASK-HTP-004).
//
// One wake needs exactly one proposed step. Mechanical typed steps always
// come from the deterministic handler. A model is consulted only for the one
// decision the handler cannot synthesize: patch bytes at the explicit
// `patchProposalRequired` boundary. That bounded question additionally needs
// project egress, a configured gateway, a context within its byte ceiling,
// the identity screen and a response that survives the strict parser.
//
// Any failure along that chain records why and returns the deterministic
// handler's step. If that step can make progress, the wake executes it. If it
// is the bounded patch question and transport really occurred, the caller
// charges the call and leaves the task running for another wake; only the
// task's model-call budget may end those retries. Pre-transport privacy,
// identity and context refusals retain the deterministic human boundary.

import ArkDeckCore
import ArkDeckRuntime
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
    basis: HarnessDecisionBasis,
    deterministic: HarnessPlannedStep
  ) async -> PlannedProposal {
    // Runtime orchestration already owns every mechanical typed step. Asking
    // a model to echo observe/capture/analyze/build/test/sign/deploy adds no
    // authority or useful choice, but does add one network round trip and a
    // fresh model process per wake. Keep that entire route deterministic and
    // do not even evaluate egress until the handler reaches the bounded patch
    // question it cannot answer itself.
    guard let requestedDecision = Self.requestedDecision(from: deterministic.decision) else {
      return PlannedProposal(
        step: deterministic, producer: deterministic.decision.producer, rejection: nil)
    }

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
      // Allocate once so the accepted Decision and durable ModelRun have one
      // immutable join key. A producer never sees or supplies this value.
      let modelRunID = modelRunIDFactory()
      var contextDigest = ""
      var contextBytes = 0
      func record(
        _ outcome: HarnessModelRunOutcome, responseBytes: Int = 0,
        rejectedResponse: Data? = nil
      ) async {
        let run = HarnessModelRun(
          modelRunID: modelRunID,
          htaskID: snapshot.htaskID,
          round: snapshot.activeRound + 1,
          descriptor: decisionGateway.modelDescriptor,
          observedStateVersion: basis.stateVersion,
          contextDigest: contextDigest,
          contextBytes: contextBytes,
          responseBytes: responseBytes,
          rejectedResponseExcerpt: rejectedResponse.map {
            String(String(decoding: $0, as: UTF8.self).prefix(4_096))
          },
          outcome: outcome,
          startedAtUTC: startedAtUTC,
          finishedAtUTC: nowUTC())
        try? await store.putModelRun(run)
      }
      do {
        let context = try await assembleContext(
          snapshot, handler: handler, limits: limits,
          requestedDecision: requestedDecision)
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
            // The step that dispatches is the handler's, typed inputs and all.
            // A proposal that named the operation and left the inputs alone
            // gets them from the decision it agreed with, so what reaches the
            // runtime is byte-identical to the unproposed round.
            inputs: Self.effectiveInputs(of: proposal, against: deterministic.decision),
            patchProposal: proposal.patchProposal,
            requiredArtifacts: proposal.requiredArtifacts,
            expectedObservation: proposal.expectedObservation,
            hypothesis: proposal.hypothesis,
            reasonCode: proposal.reasonCode,
            producer: decisionGateway.producerID,
            createdAtUTC: nowUTC(),
            modelRunID: modelRunID,
            contextDigest: contextDigest)
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
            .rejected(reasonCode: rejection.reasonCode), responseBytes: bytes.count,
            rejectedResponse: bytes)
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
        // Stated inputs must match exactly; *absent* inputs are the correct
        // answer and take the handler's.
        //
        // The typed inputs are not the model's to author - a lease, a preset,
        // a bundle, a duration and a cleanup policy are all the harness's, and
        // the envelope instruction says so in as many words ("do not invent
        // operation inputs or copy context metadata into inputs"). Demanding
        // that the model echo them back byte-for-byte anyway made the
        // instruction unfollowable: 23 of 36 rejected proposals across the two
        // passing GJ-5 runs named the right operation and left inputs empty,
        // exactly as told, and were refused for it.
        //
        // Nothing widens here. An empty-inputs proposal dispatches the
        // handler's own step verbatim; what the model contributes is the
        // hypothesis and reason code attached to it. Task termination remains
        // owned by deterministic policy and observed Runtime facts.
        proposal.inputs.isEmpty || deterministic.inputs == proposal.inputs
      else { throw HarnessDecisionRejection.operationNotExpected(proposed) }
      return
    }
    let orchestrated: Set<String> = [
      DebugCrashTaskHandler.createCheckpoint, DebugCrashTaskHandler.applyPatch,
      DebugCrashTaskHandler.buildOpenHarmony,
      DebugCrashTaskHandler.signOpenHarmonyHAP, DebugCrashTaskHandler.runTests,
      DebugCrashTaskHandler.revertPatch,
      DebugCrashTaskHandler.deployHAP, DebugCrashTaskHandler.analyzeCrashLedger,
    ]
    if deterministic.kind == .invokeOperation,
      let expected = deterministic.operationReference,
      orchestrated.contains(expected)
    {
      // The rule is unchanged: an orchestrated step's sequence belongs to the
      // deterministic route. Only the answer changed — it now says what was
      // proposed and which step refused it, instead of naming an operation the
      // producer may never have mentioned.
      throw HarnessDecisionRejection.decisionNotYoursDuringOrchestratedStep(
        proposed: proposal.operationReference ?? proposal.kind.rawValue,
        step: expected)
    }
    switch proposal.kind {
    case .requestHuman, .noSafeAction:
      // A producer can report that it has no candidate, but accepting that as
      // the task's conclusion gives one model response authority over the
      // lifecycle and bypasses every task-owned retry budget. The rejection
      // is charged like any other transported proposal; the deterministic
      // route then decides whether this wake is retryable or is a real hard
      // boundary.
      throw HarnessDecisionRejection.terminalDecisionNotProposable(proposal.kind)
    case .proposePatch, .invokeOperation:
      break
    }
  }

  /// The typed inputs an accepted proposal executes with.
  ///
  /// Only an `invokeOperation` that agreed with the handler's operation and
  /// stated no inputs of its own inherits them; every other shape keeps what
  /// it carried. Terminal proposal shapes are rejected before this helper is
  /// used, but still return their empty input map for diagnostic callers.
  static func effectiveInputs(
    of proposal: HarnessDecisionProposal,
    against deterministic: HarnessDecision
  ) -> [String: JSONValue] {
    guard proposal.kind == .invokeOperation, proposal.inputs.isEmpty,
      let proposed = proposal.operationReference,
      deterministic.operationReference == proposed
    else { return proposal.inputs }
    return deterministic.inputs
  }

  /// What the round is asking the model for, in the model's own vocabulary.
  /// Only the questions a model is allowed to answer are named; a
  /// deterministic step it may not override says nothing, so the context
  /// cannot become a channel for steering it.
  static func requestedDecision(from decision: HarnessDecision) -> String? {
    guard decision.kind == .requestHuman,
      decision.reasonCode == "patchProposalRequired"
    else { return nil }
    return "proposePatch"
  }

  func assembleContext(
    _ snapshot: HarnessTaskSnapshot,
    handler: any HarnessTaskHandler,
    limits: HarnessDecisionContextLimits,
    requestedDecision: String? = nil
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
    let failures =
      failureRecords
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
    let activeAttempt = durableAttempts.last { !$0.outcome.isClosed }
    var currentWorkspaceRevision: String?
    if let repairPort, let projectRef = snapshot.executionProjectRef,
      let proposal = snapshot.repairAttempt?.proposal
    {
      currentWorkspaceRevision = try? await repairPort.currentWorkspaceRevision(
        relativePaths: proposal.touchedFiles, projectRef: projectRef, task: snapshot)
    }
    if currentWorkspaceRevision == nil, snapshot.requiresWorkspaceIsolation {
      currentWorkspaceRevision = snapshot.evolutionPolicy?.baseRevision
    }
    var availabilityByReference: [String: Bool] = [:]
    var unavailableOperations: [HarnessContextUnavailableOperation] = []
    let availabilityStates = await withTaskGroup(
      of: (reference: String, available: Bool, reason: String).self,
      returning: [(reference: String, available: Bool, reason: String)].self
    ) { group in
      for reference in snapshot.policy.allowedOperations.sorted() {
        group.addTask {
          let state = await self.policyGuard.contextAvailability(of: reference)
          return (reference, state.available, state.reason)
        }
      }
      var states: [(reference: String, available: Bool, reason: String)] = []
      for await state in group { states.append(state) }
      return states.sorted { $0.reference < $1.reference }
    }
    for state in availabilityStates {
      let reference = state.reference
      availabilityByReference[reference] = state.available
      if !state.available {
        unavailableOperations.append(
          HarnessContextUnavailableOperation(
            operationReference: reference, reasonCode: state.reason))
      }
    }
    let contextAvailableOperations = offered.filter {
      availabilityByReference[$0] != false
    }
    var authorizedOperationReferences: [String] = []
    var capabilityEffectCeiling: WorkflowEffect?
    for reference in offered where availabilityByReference[reference] != false {
      guard let descriptor = RuntimeOperationCatalog.descriptor(reference: reference),
        !descriptor.permittedEffects.contains(.destructive)
      else { continue }
      let mayMutate = descriptor.permittedEffects.contains(.deviceMutation)
      if !mayMutate {
        authorizedOperationReferences.append(reference)
        continue
      }
      if await policyGuard.contextHasStandingCapability(
        operationReference: reference, targetID: snapshot.target.targetID)
      {
        authorizedOperationReferences.append(reference)
        capabilityEffectCeiling = .deviceMutation
      }
    }
    let revisionScope = HarnessContextRevisionScope(
      workspaceRevision: currentWorkspaceRevision,
      deployedArtifactDigest: snapshot.repairAttempt?.deployedDigest,
      deviceBindingRevision: snapshot.target.expectedBindingRevision)
    let derivedArtifactSummaries: [HarnessDerivedArtifactSummary]
    if let evaluation,
      let derived = evaluation.evidence.first(where: {
        $0.verified && $0.name == "crash-signature.json"
      }),
      let source = evaluation.evidence.first(where: {
        $0.verified && $0.name == HarnessObservationBuilder.crashIndexArtifact
      })
    {
      derivedArtifactSummaries = [
        HarnessDerivedArtifactSummary(
          artifactID: derived.artifactID,
          name: derived.name,
          sourceArtifactIDs: [source.artifactID],
          analyzerReference: HarnessCrashLedgerAnalysis.analyzerRef,
          analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
          revisionScope: revisionScope,
          redactionStatus: derived.sensitiveOptIn ? "sensitiveOptIn" : "standard",
          contentSHA256: derived.sha256,
          byteCount: derived.byteCount,
          measurements: evaluation.measurements)
      ]
    } else {
      derivedArtifactSummaries = []
    }
    let executionState = HarnessContextExecutionState(
      activeAttempt: activeAttempt,
      currentWorkspaceRevision: currentWorkspaceRevision,
      currentDeployedArtifactDigest: snapshot.repairAttempt?.deployedDigest,
      currentDeviceBindingRevision: snapshot.target.expectedBindingRevision,
      disprovedHypotheses: durableAttempts.flatMap { attempt in
        attempt.disprovedFacts.map { "\(attempt.attemptID):\($0)" }
      },
      unavailableOperations: unavailableOperations,
      authorizedOperationReferences: authorizedOperationReferences,
      currentCapabilityEffectCeiling: capabilityEffectCeiling,
      allowedFileScopes: snapshot.evolutionPolicy?.allowedPaths
        ?? snapshot.repairAttempt?.proposal.touchedFiles ?? [],
      derivedArtifactSummaries: derivedArtifactSummaries)
    // Evidence text the model may actually reason about. An artifact is
    // excerpted only when it verified and the operator either did not mark it
    // sensitive or named it in this run's opt-in — the same gate the
    // evaluator answers to. Everything else keeps its identity-only shape
    // rather than arriving as a blank that looks like an empty file.
    var artifacts: [HarnessContextArtifact] = []
    for record in evaluation?.evidence ?? [] {
      let identityOnly = HarnessContextArtifact(
        artifactID: record.artifactID, name: record.name, byteCount: record.byteCount,
        // A digest prefix identifies an artifact across rounds.
        sha256Prefix: String(record.sha256.prefix(12)), verified: record.verified)
      // `verified` is the gate, and it is not a weak one: the observation
      // builder refuses to verify a sensitive artifact no operator named,
      // recording it with an `artifactSensitiveNotOptedIn` blocker instead.
      // So a verified record is already one this run is allowed to read, and
      // re-testing the opt-in here would be a second copy of that rule.
      // Whether a model is called at all is the egress policy's decision,
      // taken before this context is ever assembled.
      guard let artifactPort, record.verified, let jobID = record.jobID else {
        artifacts.append(identityOnly)
        continue
      }
      let budget = limits.maxExcerptCharacters
      guard
        let data = try? await artifactPort.read(
          jobID: jobID, artifactID: record.artifactID, maximumBytes: budget * 4),
        let text = String(data: data, encoding: .utf8)
      else {
        artifacts.append(identityOnly)
        continue
      }
      // The tail is what a crash log's reader needs: the newest fault block,
      // not the oldest boot noise.
      let truncated = text.count > budget
      artifacts.append(
        HarnessContextArtifact(
          artifactID: record.artifactID, name: record.name, byteCount: record.byteCount,
          sha256Prefix: String(record.sha256.prefix(12)), verified: record.verified,
          excerpt: truncated ? String(text.suffix(budget)) : text,
          excerptTruncated: truncated))
    }
    var sourceFiles: [HarnessContextSourceFile] = []
    if let repairPort, let projectRef = snapshot.executionProjectRef {
      sourceFiles =
        (try? await repairPort.readableSourceFiles(
          projectRef: projectRef, task: snapshot, maximumFiles: limits.maxSourceFiles,
          maximumCharactersPerFile: limits.maxExcerptCharacters)) ?? []
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
      operationReferences: contextAvailableOperations
        + durableAttempts.map {
          $0.strategy.selectedOperationFamily
        },
      revision: durableAttempts.last?.patchRevision
        ?? durableAttempts.last?.applicableBaseRevision
        ?? repair?.patchRevision ?? repair?.proposal.baseWorkspaceRevision
        ?? desiredText("baseWorkspaceRevision"),
      deviceProfiles: [desiredText("deviceProfile")].compactMap { $0 },
      toolchainProfiles: durableAttempts.map { $0.strategy.executionExpectation.toolchainProfile }
        + [desiredText("buildPresetRef"), desiredText("testPresetRef")].compactMap { $0 })
    return try HarnessDecisionContextAssembler(limits: limits).assemble(
      snapshot: snapshot,
      availableOperations: contextAvailableOperations,
      evaluation: evaluation,
      attempts: attempts,
      failures: failures,
      memory: memory,
      artifacts: artifacts,
      sourceFiles: sourceFiles,
      requestedDecision: requestedDecision,
      elapsedSeconds: elapsedSeconds(since: snapshot.createdAtUTC) ?? 0,
      memoryQuery: memoryQuery,
      executionState: executionState)
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
