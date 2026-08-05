// The guard that decides not to act (CHG-2026-054, TASK-HTP-003).
//
// Checks run in a fixed order and the first refusal wins, so a task's record
// always names the *first* reason it could not proceed rather than the most
// convenient one:
//
//   1. budgets              - exhaustion is a stop, before anything else
//   2. task type allow-set  - the closed operation set for this task
//   3. runtime availability - never consume anything for an unavailable plan
//   4. raw command surface  - typed inputs only, no argv/shell/remote path
//   5. effect ceiling       - E2 is never automated; E1 needs authorization
//   6. authorization        - an existing maintainer-issued capability only
//   7. failure memory       - the same failure twice forces a new strategy
//   8. progress             - rounds that changed nothing end the loop
//   9. active job           - one effectful job per task
//
// Order 3 before 6 is deliberate: PRODUCT-LOOP §8 requires that capability
// is not consumed when the provider or plan is unavailable, and the cheapest
// way to guarantee that is to refuse before authorization is even consulted.

import ArkDeckCore
import Foundation

public protocol HarnessOperationAvailabilityPort: Sendable {
  /// Machine-readable availability for one operation reference.
  func availability(of reference: String) async -> (available: Bool, reason: String)
}

public protocol HarnessCapabilityPort: Sendable {
  /// Is there an installed, unexpired capability that covers this operation
  /// on this target? The harness never mints, drafts or installs one - it
  /// only asks (HTP-INV-6).
  func hasStandingCapability(operationReference: String, targetID: String) async -> Bool

  /// The id of an installed capability that covers this operation, so a
  /// request can name it (CHG-2026-055, TASK-HFA-009 r2). Selecting a grant
  /// a maintainer already issued is not minting one: HTP-INV-6 forbids the
  /// harness from creating, drafting or widening a capability, and this can
  /// do none of those. The engine still re-checks scope, revision and
  /// expiry, and refuses a reference that does not fit the plan.
  ///
  /// The binding revision and typed inputs the request will carry are passed
  /// in because a grant pinned to a *different* revision or to different
  /// exact inputs can be shown, here and without the device, to be unable to
  /// authorize this request. Naming one anyway does not merely waste a
  /// submission: the engine's refusal is an authorization refusal, which
  /// stops the task for a human — so one stale grant left behind by an
  /// earlier binding revision would shadow the grant the request would
  /// otherwise have been issued, permanently.
  func standingCapabilityID(
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    inputs: [String: JSONValue]
  ) async -> String?
}

extension HarnessCapabilityPort {
  public func standingCapabilityID(
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    inputs: [String: JSONValue]
  ) async -> String? { nil }
}

public struct HarnessGuardInput: Sendable {
  public let snapshot: HarnessTaskSnapshot
  public let operationReference: String
  public let inputs: [String: JSONValue]
  public let inputsDigest: String
  public let permittedOperations: Set<String>
  public let failureRecord: HarnessFailureRecord?
  public let previousStrategy: HarnessStrategySignature?
  public let consecutiveNoProgressRounds: Int
  public let elapsedSeconds: Int?

  public init(
    snapshot: HarnessTaskSnapshot,
    operationReference: String,
    inputs: [String: JSONValue],
    inputsDigest: String,
    permittedOperations: Set<String>,
    failureRecord: HarnessFailureRecord?,
    previousStrategy: HarnessStrategySignature?,
    consecutiveNoProgressRounds: Int,
    elapsedSeconds: Int?
  ) {
    self.snapshot = snapshot
    self.operationReference = operationReference
    self.inputs = inputs
    self.inputsDigest = inputsDigest
    self.permittedOperations = permittedOperations
    self.failureRecord = failureRecord
    self.previousStrategy = previousStrategy
    self.consecutiveNoProgressRounds = consecutiveNoProgressRounds
    self.elapsedSeconds = elapsedSeconds
  }
}

public struct HarnessPolicyGuard: Sendable {
  private let availability: (any HarnessOperationAvailabilityPort)?
  private let capabilities: (any HarnessCapabilityPort)?

  /// The port the guard consulted, so the dispatcher can name the grant the
  /// guard just verified (CHG-2026-055, TASK-HFA-009 r2). Looking it up twice
  /// leaves a window where a grant expires in between; the engine closes it
  /// by re-validating scope, revision and expiry at consumption, so a stale
  /// id is refused there rather than acted on.
  public var capabilityPort: (any HarnessCapabilityPort)? { capabilities }

  public init(
    availability: (any HarnessOperationAvailabilityPort)? = nil,
    capabilities: (any HarnessCapabilityPort)? = nil
  ) {
    self.availability = availability
    self.capabilities = capabilities
  }

  /// Read-only context projection of the same ports the guard will consult
  /// before dispatch. These helpers never reserve or consume a capability;
  /// they let the model see why a published operation is currently absent
  /// without exposing a capability identifier or secret.
  func contextAvailability(
    of operationReference: String
  ) async -> (available: Bool, reason: String) {
    guard let availability else { return (true, "availabilityNotConfigured") }
    return await availability.availability(of: operationReference)
  }

  func contextHasStandingCapability(
    operationReference: String, targetID: String
  ) async -> Bool {
    guard let capabilities else { return false }
    return await capabilities.hasStandingCapability(
      operationReference: operationReference, targetID: targetID)
  }

  /// Budget-only screen, used before a decision even exists: a task with an
  /// exhausted budget must not spend a model call or a planning round.
  public static func budgetRefusal(
    _ snapshot: HarnessTaskSnapshot,
    elapsedSeconds: Int?
  ) -> HarnessGuardRefusal? {
    let consumed = snapshot.consumedBudget
    let budgets = snapshot.budgets
    if consumed.rounds >= budgets.maxRounds { return .budgetExhausted(.rounds) }
    if let elapsedSeconds, elapsedSeconds >= budgets.maxWallClockSeconds {
      return .budgetExhausted(.wallClock)
    }
    if consumed.artifactBytes >= budgets.maxArtifactBytes {
      return .budgetExhausted(.artifactBytes)
    }
    if budgets.maxE1Mutations > 0, consumed.e1Mutations >= budgets.maxE1Mutations {
      return .budgetExhausted(.e1Mutations)
    }
    if consumed.modelCalls >= budgets.maxModelCalls {
      // Exhaustion stops the model path, not the task: the deterministic
      // handler still converges, so this is a ceiling on spend, not a halt.
      return .budgetExhausted(.modelCalls)
    }
    return nil
  }

  public func evaluate(_ input: HarnessGuardInput) async -> HarnessGuardVerdict {
    let snapshot = input.snapshot

    // 1. Budgets.
    if let refusal = Self.budgetRefusal(snapshot, elapsedSeconds: input.elapsedSeconds) {
      return .refuse(refusal)
    }
    // 2. The closed allow-set: task policy ∩ task-type permitted.
    guard snapshot.policy.allowedOperations.contains(input.operationReference),
      input.permittedOperations.contains(input.operationReference)
    else {
      return .refuse(.operationNotPermitted(input.operationReference))
    }

    // 3. Availability before any authorization talk.
    if let availability {
      let state = await availability.availability(of: input.operationReference)
      guard state.available else {
        return .refuse(
          .operationUnavailable(reference: input.operationReference, reason: state.reason))
      }
    }

    // 4. Typed inputs only.
    if let refusal = HarnessRawSurfaceScreen.screen(input.inputs) {
      return .refuse(refusal)
    }

    // 5/6. Effect ceiling and authorization.
    if let refusal = await effectRefusal(input) {
      return .refuse(refusal)
    }

    // 7. Failure memory.
    if let record = input.failureRecord {
      switch record.stance {
      case .prohibited:
        return .refuse(
          .repeatedFailureProhibited(digest: record.digest, occurrences: record.occurrences))
      case .requireNewStrategy:
        let proposed = HarnessStrategySignature(
          operationReference: input.operationReference, inputsDigest: input.inputsDigest,
          phase: snapshot.phase)
        if let previous = input.previousStrategy, previous == proposed {
          return .refuse(
            .repeatedFailureNeedsNewStrategy(
              digest: record.digest, occurrences: record.occurrences))
        }
      case .allowSameStrategy:
        break
      }
    }

    // 8. Progress. A different operation/input/phase is allowed to become a
    // new strategy; the same strategy may not spend another round after its
    // task-declared patience is exhausted.
    let proposed = HarnessStrategySignature(
      operationReference: input.operationReference, inputsDigest: input.inputsDigest,
      phase: snapshot.phase)
    if input.consecutiveNoProgressRounds >= snapshot.budgets.maxNoProgressRounds,
      input.previousStrategy == proposed
    {
      return .refuse(.noProgress(rounds: input.consecutiveNoProgressRounds))
    }

    // 9. One effectful job.
    if let active = snapshot.activeJobID {
      return .refuse(.activeJobConflict(active))
    }

    return .allow
  }

  private func effectRefusal(_ input: HarnessGuardInput) async -> HarnessGuardRefusal? {
    guard let descriptor = RuntimeOperationCatalog.descriptor(reference: input.operationReference)
    else {
      return .operationNotPermitted(input.operationReference)
    }
    // Two different questions, and only one of them belongs here.
    //
    // The *effective* effect of a request is decided by which steps its typed
    // inputs select, and the engine computes it with the same pure rule it
    // then executes with (the CHG-2026-049 correction). Recomputing that here
    // would be a second copy of the selection rule, free to drift - and
    // guessing the ceiling instead is worse than useless: `capture.diagnostics@1`
    // permits deviceMutation on its remote-trace path, so authorising by the
    // ceiling would refuse the ordinary E0 capture that GJ-1 exists to run.
    //
    // So the guard screens on what it can know without duplicating anything:
    // an operation that *cannot* avoid mutating (its minimum effect already
    // mutates) needs authorization, and a destructive ceiling is never
    // automated at all. Everything in between goes to the engine, which
    // refuses admission without a capability and consumes it atomically; that
    // refusal comes back as an authorization block, not as an execution.
    if descriptor.permittedEffects.contains(.destructive)
      || descriptor.minimumEffect == .destructive
    {
      // E2 is never automated, with or without a budget or a capability.
      return .destructiveEffectNeverAutomated(reference: input.operationReference)
    }
    switch descriptor.minimumEffect {
    case .hostOnly, .readOnly:
      return nil
    case .destructive:
      return .destructiveEffectNeverAutomated(reference: input.operationReference)
    case .deviceMutation:
      let effect = WorkflowEffect.deviceMutation.rawValue
      guard input.snapshot.budgets.maxE1Mutations > 0 else {
        return .authorizationRequired(reference: input.operationReference, effect: effect)
      }
      // Where the catalog allows the runtime to issue its own bounded
      // envelope, a pre-issued grant is not a precondition: the engine still
      // decides, and it binds that envelope to the exact target identity,
      // binding revision and typed inputs of the request before consuming it
      // atomically. Demanding a standing grant here is stricter than the
      // authority it screens for, and the strictness was not even load-
      // bearing — it was satisfied by *any* unexpired grant naming the
      // operation, including one issued for a superseded binding revision.
      // The operations that must not be self-authorized say so in the
      // catalog (`defaultPolicyIssuance: disabled`, which is what the
      // TASK-HFA-009 flip set on every `workspace.*` mutation) and still
      // fall through to the standing-grant requirement below.
      if descriptor.defaultPolicyIssuanceEnabled { return nil }
      // A task that works in its own isolated copy is in the same position:
      // the runtime issues its own bounded envelope for that copy, and the
      // only way anything leaves it is a promotion a person merges. Demanding
      // a pre-issued grant here would put a human in front of a scratch
      // directory while the pull request — the actual gate — stays where it
      // is, and the grant could not even be written until the task had
      // created the workspace it names.
      if input.snapshot.requiresWorkspaceIsolation { return nil }
      guard let capabilities else {
        return .authorizationRequired(reference: input.operationReference, effect: effect)
      }
      let held = await capabilities.hasStandingCapability(
        operationReference: input.operationReference,
        targetID: input.snapshot.target.targetID)
      return held
        ? nil : .authorizationRequired(reference: input.operationReference, effect: effect)
    }
  }
}
