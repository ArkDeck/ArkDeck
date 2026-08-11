// The decision port and its egress boundary (CHG-2026-054, TASK-HTP-004).
//
// A model is a replaceable *port*, not a dependency. Three properties make
// that literal rather than aspirational:
//
//   * egress defaults to deny. With no explicit per-project opt-in, no
//     context leaves the host and the loop runs on the deterministic
//     handler - so "the model is unavailable" and "the loop is unavailable"
//     are different sentences (PRODUCT-LOOP §6/HTP-INV-10);
//   * the context that does leave is assembled from declared fields with
//     hard counts and a byte ceiling, carries no artifact bytes and no
//     device identity, and says what it trimmed;
//   * whatever comes back is bytes until the strict parser accepts it, and
//     an accepted proposal still has to pass the same Policy Guard as a
//     deterministic step. Swapping adapters cannot change what the state
//     machine concludes, only which step gets proposed.

import ArkDeckCore
import Foundation

package enum HarnessEgressDecision: Equatable, Sendable {
  case denied(reason: String)
  case allowed(limits: HarnessDecisionContextLimits)
}

/// Per-project egress policy. Absent configuration means denied: enabling
/// egress is an explicit act, recorded in the composition root, never a
/// default that a fresh install inherits.
package struct HarnessEgressPolicy: Sendable, Equatable {
  private let enabledProjects: Set<String>
  private let limits: HarnessDecisionContextLimits

  public init(
    enabledProjects: Set<String> = [],
    limits: HarnessDecisionContextLimits = .default
  ) {
    self.enabledProjects = enabledProjects
    self.limits = limits
  }

  package static let deniedByDefault = HarnessEgressPolicy()

  public func decide(projectRef: String?) -> HarnessEgressDecision {
    guard let projectRef else {
      return .denied(reason: "egressRequiresProjectRef")
    }
    guard enabledProjects.contains(projectRef) else {
      return .denied(reason: "egressNotEnabledForProject")
    }
    return .allowed(limits: limits)
  }
}

package enum HarnessDecisionGatewayError: Error, Equatable, Sendable {
  case unavailable(String)
  case transportFailure(String)
  case contextTooLarge(bytes: Int, limit: Int)
}

/// The port. Implementations return raw bytes; parsing and validation are
/// the harness's job, so no adapter can widen what a decision may say.
package protocol HarnessDecisionGateway: Sendable {
  var producerID: String { get }
  /// What to record about the model behind this port (CHG-2026-055,
  /// TASK-HFA-002). The default says only what the port itself can know -
  /// the producer id - and marks the rest unspecified rather than guessing
  /// a vendor or a version. Real adapters override it.
  var modelDescriptor: HarnessModelDescriptor { get }
  func propose(_ context: HarnessDecisionContext) async throws -> Data
}

extension HarnessDecisionGateway {
  package var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(provider: producerID)
  }
}

// There is deliberately no "deterministic gateway" adapter here. The built-in
// producer *is* the task handler, and the coordinator already runs it when no
// gateway is configured or when the model path is refused. Wrapping a second,
// simpler strategy in this port would be a rival implementation of the
// handler's plan - free to drift, and (as the first draft of this file proved
// by proposing a capture before the device had been observed) free to be
// wrong. The port exists for producers the repository does not own.
//
// Nor is this port the primary way intelligence reaches the loop. An
// attended loop's producer is an external agent that reads the same bounded
// context via `task.context` and answers at `task.proposePatch`; adapters
// behind this port serve the unattended case, where no such session exists.

/// Builds the bounded context. Trimming is explicit and recorded: a reader of
/// the durable record can tell what the model was not shown.
package struct HarnessDecisionContextAssembler: Sendable {
  private let limits: HarnessDecisionContextLimits

  /// Desired-state fields that help a model reason about the product goal.
  /// Runtime orchestration references (artifact leases, capabilities and
  /// bindings) are deliberately absent: besides being outside the model's
  /// authority, a device-bound lease can embed the raw target id that the
  /// egress screen must refuse.
  private static let modelVisibleDesiredStateKeys: Set<String> = [
    "crashSignature", "bundleName", "abilityName", "buildPresetRef", "testPresetRef",
  ]

  public init(limits: HarnessDecisionContextLimits = .default) {
    self.limits = limits
  }

  public func assemble(
    snapshot: HarnessTaskSnapshot,
    availableOperations: [String],
    evaluation: HarnessEvaluation?,
    attempts: [HarnessContextAttempt],
    failures: [HarnessContextFailure],
    memory: [HarnessMemoryEntry],
    artifacts: [HarnessContextArtifact],
    sourceFiles: [HarnessContextSourceFile] = [],
    requestedDecision: String? = nil,
    elapsedSeconds: Int,
    memoryQuery explicitMemoryQuery: HarnessMemoryQuery? = nil,
    executionState: HarnessContextExecutionState = .empty
  ) throws -> HarnessDecisionContext {
    var trimmed: [String] = []
    func trim<T>(_ values: [T], to limit: Int, label: String) -> [T] {
      guard values.count > limit else { return values }
      trimmed.append("\(label):kept\(limit)of\(values.count)")
      return Array(values.suffix(limit))
    }

    let observed = snapshot.observed
    let modelVisibleDesiredState = snapshot.goal.desiredState.filter {
      Self.modelVisibleDesiredStateKeys.contains($0.key)
    }
    let omittedDesiredStateCount =
      snapshot.goal.desiredState.count - modelVisibleDesiredState.count
    if omittedDesiredStateCount > 0 {
      trimmed.append("desiredState:omitted\(omittedDesiredStateCount)OrchestrationFields")
    }
    func desiredText(_ key: String) -> String? {
      guard case .string(let value)? = snapshot.goal.desiredState[key] else { return nil }
      return value
    }
    let repair = snapshot.repairAttempt
    let memoryQuery = explicitMemoryQuery ?? HarnessMemoryQuery(
      htaskID: snapshot.htaskID,
      projectRef: snapshot.projectRef,
      components: [snapshot.type.rawValue, desiredText("component")].compactMap { $0 },
      filePaths: repair?.proposal.touchedFiles ?? [],
      symbols: repair?.proposal.expectedChangedSymbols ?? [],
      operationReferences: availableOperations,
      revision: repair?.patchRevision ?? repair?.proposal.baseWorkspaceRevision
        ?? desiredText("baseWorkspaceRevision"),
      deviceProfiles: [desiredText("deviceProfile")].compactMap { $0 },
      toolchainProfiles: [desiredText("buildPresetRef"), desiredText("testPresetRef")]
        .compactMap { $0 })
    let memorySelection = HarnessMemorySelector.select(
      memory, matching: memoryQuery, limit: limits.maxMemories)
    if memorySelection.manifest.trimmedCount > 0 {
      trimmed.append(
        "memory:kept\(memorySelection.entries.count)of"
          + "\(memorySelection.entries.count + memorySelection.manifest.trimmedCount)")
    }
    let currentEvaluationFacts = (evaluation?.criterionResults ?? []).compactMap { result in
      result.verdict == .pass ? "criterion:\(result.criterionID)=pass" : nil
    }
    let verifiedMemoryFacts = memorySelection.entries.compactMap { entry in
      entry.lifecycle == .verified
        ? "memory:\(entry.memoryID): \(entry.summary)" : nil
    }
    let budget = HarnessContextBudget(
      roundsRemaining: max(0, snapshot.budgets.maxRounds - snapshot.consumedBudget.rounds),
      wallClockSecondsRemaining: max(0, snapshot.budgets.maxWallClockSeconds - elapsedSeconds),
      artifactBytesRemaining: max(
        0, snapshot.budgets.maxArtifactBytes - snapshot.consumedBudget.artifactBytes),
      e1MutationsRemaining: max(
        0, snapshot.budgets.maxE1Mutations - snapshot.consumedBudget.e1Mutations),
      noProgressRoundsRemaining: max(
        0, snapshot.budgets.maxNoProgressRounds - snapshot.noProgressRounds),
      actionRetriesPerRun: snapshot.budgets.maxActionRetriesPerRun,
      modelCallsRemaining: max(
        0, snapshot.budgets.maxModelCalls - snapshot.consumedBudget.modelCalls))
    let boundedExecutionState = HarnessContextExecutionState(
      activeAttempt: executionState.activeAttempt,
      currentWorkspaceRevision: executionState.currentWorkspaceRevision,
      currentDeployedArtifactDigest: executionState.currentDeployedArtifactDigest,
      currentDeviceBindingRevision: executionState.currentDeviceBindingRevision,
      disprovedHypotheses: trim(
        executionState.disprovedHypotheses, to: limits.maxMemories,
        label: "disprovedHypotheses"),
      unavailableOperations: trim(
        executionState.unavailableOperations, to: limits.maxOperations,
        label: "unavailableOperations"),
      authorizedOperationReferences: trim(
        executionState.authorizedOperationReferences, to: limits.maxOperations,
        label: "authorizedOperations"),
      currentCapabilityEffectCeiling: executionState.currentCapabilityEffectCeiling,
      allowedFileScopes: trim(
        executionState.allowedFileScopes, to: limits.maxArtifacts,
        label: "allowedFileScopes"),
      derivedArtifactSummaries: trim(
        executionState.derivedArtifactSummaries, to: limits.maxArtifacts,
        label: "derivedArtifactSummaries"))

    let context = HarnessDecisionContext(
      targetPseudonym: HarnessDecisionContext.pseudonym(forTargetID: snapshot.target.targetID),
      taskType: snapshot.type,
      status: snapshot.lifecycle,
      phase: snapshot.stage,
      round: snapshot.activeRound,
      currentTaskStateVersion: snapshot.version,
      goalSummary: String(snapshot.goal.summary.prefix(limits.maxSummaryCharacters)),
      desiredState: modelVisibleDesiredState,
      observedMeasurements: observed.measurements,
      observedSamples: observed.samples,
      latestVerdict: observed.latestVerdict,
      criterionResults: evaluation?.criterionResults ?? [],
      recentAttempts: trim(attempts, to: limits.maxAttempts, label: "attempts"),
      unresolvedFailures: trim(failures, to: limits.maxFailures, label: "failures"),
      relevantMemory: memorySelection.entries.map {
        "\($0.lifecycle.rawValue)/\($0.kind.rawValue)/\($0.confidence.rawValue): \($0.summary)"
      },
      confirmedFacts: HarnessContextConfirmedFacts(
        current: currentEvaluationFacts + verifiedMemoryFacts),
      memorySelectionManifest: memorySelection.manifest,
      artifacts: trim(artifacts, to: limits.maxArtifacts, label: "artifacts"),
      sourceFiles: trim(sourceFiles, to: limits.maxSourceFiles, label: "sourceFiles"),
      requestedDecision: requestedDecision,
      availableOperations: trim(
        availableOperations, to: limits.maxOperations, label: "operations"),
      budget: budget,
      blockers: observed.blockers,
      trimmed: trimmed,
      waitReason: snapshot.waitReason,
      conditions: snapshot.conditions,
      executionState: boundedExecutionState)

    let encoder = CanonicalJSONEncoders.canonical()
    func encodedSize(_ value: HarnessDecisionContext) -> Int {
      ((try? encoder.encode(value)) ?? Data()).count
    }
    var sized = context
    // Excerpts are the only part of a context that can grow without bound
    // with the work itself, so they are what gives way first: drop the source
    // text, then the evidence text, and only then refuse. Dropping is
    // recorded, because a model reasoning from a context that silently lost
    // the file it was asked to patch would be reasoning about nothing.
    if encodedSize(sized) > limits.maxEncodedBytes, !sized.sourceFiles.isEmpty {
      trimmed.append("sourceFiles:droppedForSize\(sized.sourceFiles.count)")
      sized = sized.replacing(sourceFiles: [], trimmed: trimmed)
    }
    if encodedSize(sized) > limits.maxEncodedBytes,
      sized.artifacts.contains(where: { $0.excerpt != nil })
    {
      trimmed.append("artifactExcerpts:droppedForSize")
      sized = sized.replacing(
        artifacts: sized.artifacts.map { $0.withoutExcerpt() }, trimmed: trimmed)
    }
    let encoded = encodedSize(sized)
    guard encoded <= limits.maxEncodedBytes else {
      // Refuse rather than send a context the policy did not size for. The
      // caller falls back to the deterministic strategy, which needs none.
      throw HarnessDecisionGatewayError.contextTooLarge(
        bytes: encoded, limit: limits.maxEncodedBytes)
    }
    return sized
  }
}

/// Screen for identity that must never leave the host, applied to the encoded
/// context before it is handed to an adapter. Belt and braces: the assembler
/// already omits these fields, and this catches a future field that forgets.
package enum HarnessEgressScreen {
  package static func violations(in context: HarnessDecisionContext, targetID: String) -> [String] {
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(context),
      let text = String(data: data, encoding: .utf8)
    else { return ["contextNotEncodable"] }
    var found: [String] = []
    if text.contains(targetID) { found.append("targetId") }
    for marker in [
      "connectKey", "serial", "stablePhysicalIdentity", "/data/local/tmp", "/Users/",
      "/home/", "/private/", "/tmp/", "file://",
    ] {
      if text.localizedCaseInsensitiveContains(marker) { found.append(marker) }
    }
    return found
  }
}
