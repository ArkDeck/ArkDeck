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
import ArkDeckStorage
import Foundation

public enum HarnessEgressDecision: Equatable, Sendable {
  case denied(reason: String)
  case allowed(limits: HarnessDecisionContextLimits)
}

/// Per-project egress policy. Absent configuration means denied: enabling
/// egress is an explicit act, recorded in the composition root, never a
/// default that a fresh install inherits.
public struct HarnessEgressPolicy: Sendable, Equatable {
  private let enabledProjects: Set<String>
  private let limits: HarnessDecisionContextLimits

  public init(
    enabledProjects: Set<String> = [],
    limits: HarnessDecisionContextLimits = .default
  ) {
    self.enabledProjects = enabledProjects
    self.limits = limits
  }

  public static let deniedByDefault = HarnessEgressPolicy()

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

public enum HarnessDecisionGatewayError: Error, Equatable, Sendable {
  case unavailable(String)
  case transportFailure(String)
  case contextTooLarge(bytes: Int, limit: Int)
}

/// The port. Implementations return raw bytes; parsing and validation are
/// the harness's job, so no adapter can widen what a decision may say.
public protocol HarnessDecisionGateway: Sendable {
  var producerID: String { get }
  /// What to record about the model behind this port (CHG-2026-055,
  /// TASK-HFA-002). The default says only what the port itself can know -
  /// the producer id - and marks the rest unspecified rather than guessing
  /// a vendor or a version. Real adapters override it.
  var modelDescriptor: HarnessModelDescriptor { get }
  func propose(_ context: HarnessDecisionContext) async throws -> Data
}

extension HarnessDecisionGateway {
  public var modelDescriptor: HarnessModelDescriptor {
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

/// Builds the bounded context. Trimming is explicit and recorded: a reader of
/// the durable record can tell what the model was not shown.
public struct HarnessDecisionContextAssembler: Sendable {
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
    elapsedSeconds: Int
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
    let budget = HarnessContextBudget(
      roundsRemaining: max(0, snapshot.budgets.maxRounds - snapshot.consumedBudget.rounds),
      wallClockSecondsRemaining: max(0, snapshot.budgets.maxWallClockSeconds - elapsedSeconds),
      artifactBytesRemaining: max(
        0, snapshot.budgets.maxArtifactBytes - snapshot.consumedBudget.artifactBytes),
      e1MutationsRemaining: max(
        0, snapshot.budgets.maxE1Mutations - snapshot.consumedBudget.e1Mutations),
      noProgressRoundsRemaining: max(
        0, snapshot.budgets.maxNoProgressRounds - snapshot.noProgressRounds),
      actionRetriesPerRun: snapshot.budgets.maxActionRetriesPerRun)

    let context = HarnessDecisionContext(
      targetPseudonym: HarnessDecisionContext.pseudonym(forTargetID: snapshot.target.targetID),
      taskType: snapshot.type,
      status: snapshot.status,
      phase: snapshot.phase,
      round: snapshot.activeRound,
      goalSummary: String(snapshot.goal.summary.prefix(limits.maxSummaryCharacters)),
      desiredState: modelVisibleDesiredState,
      observedMeasurements: observed.measurements,
      observedSamples: observed.samples,
      latestVerdict: observed.latestVerdict,
      criterionResults: evaluation?.criterionResults ?? [],
      recentAttempts: trim(attempts, to: limits.maxAttempts, label: "attempts"),
      unresolvedFailures: trim(failures, to: limits.maxFailures, label: "failures"),
      relevantMemory: trim(
        memory.map { "\($0.kind.rawValue)/\($0.confidence.rawValue): \($0.summary)" },
        to: limits.maxMemories, label: "memory"),
      artifacts: trim(artifacts, to: limits.maxArtifacts, label: "artifacts"),
      availableOperations: trim(
        availableOperations, to: limits.maxOperations, label: "operations"),
      budget: budget,
      blockers: observed.blockers,
      trimmed: trimmed)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = (try? encoder.encode(context)) ?? Data()
    guard encoded.count <= limits.maxEncodedBytes else {
      // Refuse rather than send a context the policy did not size for. The
      // caller falls back to the deterministic strategy, which needs none.
      throw HarnessDecisionGatewayError.contextTooLarge(
        bytes: encoded.count, limit: limits.maxEncodedBytes)
    }
    return context
  }
}

/// Screen for identity that must never leave the host, applied to the encoded
/// context before it is handed to an adapter. Belt and braces: the assembler
/// already omits these fields, and this catches a future field that forgets.
public enum HarnessEgressScreen {
  public static func violations(in context: HarnessDecisionContext, targetID: String) -> [String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(context),
      let text = String(data: data, encoding: .utf8)
    else { return ["contextNotEncodable"] }
    var found: [String] = []
    if text.contains(targetID) { found.append("targetId") }
    for marker in ["connectKey", "serial", "stablePhysicalIdentity", "/data/local/tmp"] {
      if text.localizedCaseInsensitiveContains(marker) { found.append(marker) }
    }
    return found
  }
}
