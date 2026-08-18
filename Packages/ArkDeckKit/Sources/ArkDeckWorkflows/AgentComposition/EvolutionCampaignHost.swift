// Product-facing bounded Evolution campaign composition
// (CHG-2026-025 r8, TASK-AIN-019).

import ArkDeckCore
import ArkDeckStorage
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

private enum EvolutionCampaignRepairConfiguration {
  // Preserve the accepted environment spelling while severing campaign
  // ownership from the retiring decision-plane configuration.
  static let providerKey = "ARKDECK_HARNESS_MODEL_PROVIDER"
  static let cliPathKey = "ARKDECK_HARNESS_CLI_PATH"
  static let modelKey = "ARKDECK_HARNESS_MODEL_NAME"
}

package struct RockchipEvolutionCampaignPreview: Sendable, Equatable {
  public let assertion: RockchipEvolutionCampaignConfirmationAssertion
  public let deviceMutationDispatchCount: Int

  public init(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    deviceMutationDispatchCount: Int
  ) {
    self.assertion = assertion
    self.deviceMutationDispatchCount = deviceMutationDispatchCount
  }
}

package struct RockchipEvolutionCampaignExecutionResult: Sendable, Equatable {
  public let campaignID: String
  public let attemptOrdinal: Int
  public let flash: RockchipFlashExecutionResult

  public init(campaignID: String, attemptOrdinal: Int, flash: RockchipFlashExecutionResult) {
    self.campaignID = campaignID
    self.attemptOrdinal = attemptOrdinal
    self.flash = flash
  }
}

package protocol RockchipEvolutionFlashDispatching: Sendable {
  /// Non-nil when this dispatcher's executor cannot mint its own reservation.
  /// The engine lane is that case by #992's design — the engine re-verifies
  /// and closes an already open reservation but never reserves — so the host
  /// runs the nine gates here, immediately before dispatch. The in-process
  /// lane admits inside its own execute and supplies none.
  var attemptAdmitter: (any RockchipEvolutionCampaignAttemptAdmitting)? { get }

  func execute(
    _ request: RockchipFlashExecutionRequest,
    admitted: RockchipEvolutionCampaignAdmittedAttempt?
  ) async throws -> RockchipFlashExecutionResult
}

extension RockchipEvolutionFlashDispatching {
  package var attemptAdmitter: (any RockchipEvolutionCampaignAttemptAdmitting)? { nil }
}

/// E0 preview. It hashes the complete published archive, protected-main base,
/// candidate toolchain, running broker and durable stable target. It creates a
/// non-authoritative draft ledger only; no usage reservation or device process
/// exists on this path. The draft expires with its assertion: a preview that
/// is never confirmed leaves a zero-event document that any later preview or
/// admission sweeps away once `validUntil` passes, so unconfirmed previews
/// accumulate no permanent campaign documents.
package enum RockchipEvolutionCampaignPlanning {
  public static func preview(
    archiveURL: URL,
    maxAttempts: Int,
    maxChangedFiles: Int = 8,
    maxDiffLines: Int = 2_000,
    validitySeconds: Int = 4 * 60 * 60
  ) async throws -> RockchipEvolutionCampaignPreview {
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/"),
      (1...RockchipEvolutionCampaignConfirmationAssertion.maximumAttemptLimit)
        .contains(maxAttempts),
      (60...Int(RockchipEvolutionCampaignConfirmationAssertion.maximumValiditySeconds))
        .contains(validitySeconds)
    else { throw RockchipEvolutionCampaignError.invalidAssertion("preview") }
    let validatedPlan = try await RockchipProductExecutePlanFactPort()
      .makeValidatedExecutePlan(archiveURL: archiveURL.standardizedFileURL)
    let plan = validatedPlan.plan
    let roots = try RockchipEvolutionProductRoots.load()
    let binding = try RockchipProductBindingStore(rootURL: roots.arkDeckRoot).loadExisting()
    let stableIdentity = SHA256Hex.string(of: Data(binding.serial.utf8))
    async let base =
      ProductRockchipEvolutionCandidateBuilder
      .currentProtectedMainBaseCommitOID()
    async let toolchain = ProductRockchipEvolutionCandidateBuilder.currentToolchainDigest()
    let broker = try ProductRockchipEvolutionCandidateBuilder.currentBrokerExecutableDigest()
    let now = Date()
    let confirmedAt = ISO8601Timestamps.string(from: now)
    let validUntil = ISO8601Timestamps.string(
      from: now.addingTimeInterval(TimeInterval(validitySeconds)))
    let assertion = try await RockchipEvolutionCampaignConfirmationAssertion.draft(
      baseCommitOID: base,
      candidateToolchainDigestSHA256: toolchain,
      brokerExecutableDigestSHA256: broker,
      maxChangedFiles: maxChangedFiles, maxDiffLines: maxDiffLines,
      planDigestSHA256: plan.planDigestSHA256,
      archiveDigestSHA256: plan.archiveSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      targetStableIdentitySHA256: stableIdentity,
      bindingLineageRootRevision: binding.revision,
      maxAttempts: maxAttempts, confirmedAt: confirmedAt, validUntil: validUntil)
    let ledger = try RockchipEvolutionCampaignLedger(root: roots.campaignLedgerRoot)
    _ = try? ledger.collectExpiredZeroEventDrafts(at: confirmedAt)
    _ = try ledger.create(assertion)
    return RockchipEvolutionCampaignPreview(assertion: assertion, deviceMutationDispatchCount: 0)
  }
}

/// What reconciliation concluded about one attempt, and why.
///
/// The `basis` exists because a disposition on its own cannot be audited.
/// `outcomeUnknown` has two writers that mean opposite things — an engine that
/// measured an unknown outcome and carried complete intent sets, and
/// reconciliation that found no terminal at all and knows nothing — and until
/// r17 the campaign document recorded the same word for both (TASK-AIN-020).
package enum RockchipEvolutionAttemptClassification: Equatable, Sendable {
  case decided(RockchipEvolutionAttemptDisposition, basis: String)
  /// Only an engine-written `outcomeUnknown` reaches here. The readback is
  /// applied by the host, which owns the ports it needs.
  case requiresLoaderTransitionReadback(basis: String)
}

package final class RockchipEvolutionCampaignHost: @unchecked Sendable {
  package typealias AttemptClassification = RockchipEvolutionAttemptClassification

  /// A `safeToReflash` terminal proves no external effect occurred, but it
  /// does not make an unbounded sequence of materially identical proposals
  /// useful. Three consecutive no-effect attempts are enough to distinguish
  /// a transient transition race from a product-path defect; preserve the
  /// evidence and stop before the strategy-only repair lane churns through
  /// the confirmed Flash budget.
  private static let maximumConsecutiveNoEffectAttempts = 3

  private let ledger: RockchipEvolutionCampaignLedger
  private let usageLedger: AgentAuthorityUsageLedger
  private let repairer: any RockchipEvolutionStrategyRepairing
  private let builder: any RockchipEvolutionCandidateBuilding
  private let flash: any RockchipEvolutionFlashDispatching
  private let targetReadback: any RockchipEvolutionTargetReadbackReading
  private let attemptIntents: any RockchipEvolutionAttemptIntentReading
  private let nowUTC: @Sendable () -> String

  /// There is no default execution lane. A campaign attempt runs on the
  /// runtime job lane and nowhere else: the in-process flash executor this
  /// used to default to has been retired (T25), and re-adding a default is
  /// how a second execution stack comes back.
  public convenience init(
    flash: any RockchipEvolutionFlashDispatching,
    attemptIntents: any RockchipEvolutionAttemptIntentReading =
      UnavailableRockchipEvolutionAttemptIntents(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let roots = try RockchipEvolutionProductRoots.load()
    let repairer = try Self.repairer(
      environment: environment, workingDirectory: roots.repairerRoot.path)
    try self.init(
      ledger: RockchipEvolutionCampaignLedger(root: roots.campaignLedgerRoot),
      usageLedger: AgentAuthorityUsageLedger(root: roots.usageRoot),
      repairer: repairer,
      builder: ProductRockchipEvolutionCandidateBuilder(stateRoot: roots.candidateRoot),
      flash: flash,
      targetReadback: ProductRockchipEvolutionTargetReadback(),
      attemptIntents: attemptIntents,
      nowUTC: { ISO8601Timestamps.string(from: Date()) })
  }

  /// `targetReadback` and `attemptIntents` default to the two values that
  /// cannot settle anything: absence and refusal. A composition that forgets
  /// to wire them keeps today's behaviour — an unknown attempt stays unknown —
  /// instead of inheriting a proof it never obtained.
  package init(
    ledger: RockchipEvolutionCampaignLedger,
    usageLedger: AgentAuthorityUsageLedger,
    repairer: any RockchipEvolutionStrategyRepairing,
    builder: any RockchipEvolutionCandidateBuilding,
    flash: any RockchipEvolutionFlashDispatching,
    targetReadback: any RockchipEvolutionTargetReadbackReading =
      AbsentRockchipEvolutionTargetReadback(),
    attemptIntents: any RockchipEvolutionAttemptIntentReading =
      UnavailableRockchipEvolutionAttemptIntents(),
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.ledger = ledger
    self.usageLedger = usageLedger
    self.repairer = repairer
    self.builder = builder
    self.flash = flash
    self.targetReadback = targetReadback
    self.attemptIntents = attemptIntents
    self.nowUTC = nowUTC
  }

  package func executeConfirmedCampaign(
    confirmationDigestSHA256: String,
    archiveURL: URL,
    targetLocationSelector: String
  ) async throws -> RockchipEvolutionCampaignExecutionResult {
    guard
      RockchipEvolutionCampaignConfirmationAssertion.isSHA256(
        confirmationDigestSHA256)
    else { throw RockchipEvolutionCampaignError.invalidAssertion("confirmationDigest") }
    let campaignID = "ECAMP-\(confirmationDigestSHA256.prefix(24).uppercased())"
    // Best-effort sweep of expired zero-event preview drafts. If the target
    // campaign itself is such a draft it becomes campaignNotFound here, which
    // is the same fail-closed outcome expiry would have forced below.
    _ = try? ledger.collectExpiredZeroEventDrafts(at: nowUTC())
    let document = try ledger.load(campaignID)
    guard document.assertion.confirmationDigestSHA256 == confirmationDigestSHA256 else {
      throw RockchipEvolutionCampaignError.confirmationDigestMismatch
    }
    guard document.reservedAttemptCount == 0 else {
      throw RockchipEvolutionCampaignError.admissionRejected(
        "firstAdmissionAlreadyConsumed")
    }
    return try await execute(
      document: document, archiveURL: archiveURL,
      targetLocationSelector: targetLocationSelector)
  }

  package func continueCampaign(
    campaignID: String,
    archiveURL: URL,
    targetLocationSelector: String
  ) async throws -> RockchipEvolutionCampaignExecutionResult {
    _ = try? ledger.collectExpiredZeroEventDrafts(at: nowUTC())
    let document = try ledger.load(campaignID)
    return try await execute(
      document: document, archiveURL: archiveURL,
      targetLocationSelector: targetLocationSelector)
  }

  public func status(_ campaignID: String) throws -> RockchipEvolutionCampaignDocument {
    try ledger.load(campaignID)
  }

  /// Reading a campaign's own ledger needs no execution lane, no repairer and
  /// no review role — only the durable document. Keeping this off the
  /// dispatcher-bearing initializer means `flash status` cannot be the reason
  /// a default execution lane comes back.
  public static func status(
    campaignID: String
  ) throws -> RockchipEvolutionCampaignDocument {
    let roots = try RockchipEvolutionProductRoots.load()
    return try RockchipEvolutionCampaignLedger(root: roots.campaignLedgerRoot)
      .load(campaignID)
  }

  private func execute(
    document initial: RockchipEvolutionCampaignDocument,
    archiveURL: URL,
    targetLocationSelector: String
  ) async throws -> RockchipEvolutionCampaignExecutionResult {
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/") else {
      throw RockchipEvolutionCampaignError.invalidAssertion("archiveURL")
    }
    var document = try reconcileUnresolved(initial)
    var observation: RockchipEvolutionFailureObservation?
    if document.reservedAttemptCount > 0,
      document.events.last(where: { $0.kind == .attemptTerminal })?.disposition == .safeToReflash
    {
      observation = try RockchipEvolutionFailureObservation(
        attemptOrdinal: document.reservedAttemptCount,
        failureCode: "campaign.safeToReflash")
    }
    while true {
      // Two situations, and they were one word. A campaign that has stopped
      // for good and a confirmation that has merely lapsed need opposite next
      // moves: the first says establish what the device is before starting
      // anything new, the second says nothing about the device changed —
      // preview and confirm again. A caller told only `terminalOrExpired`
      // cannot choose, so it stops for a human. The two guards below already
      // name themselves exactly; this one was the outlier.
      guard !document.isTerminal else {
        let disposition = document.events
          .last(where: { $0.kind == .attemptTerminal })?.disposition
        throw RockchipEvolutionCampaignError.campaignStopped(
          "campaignTerminal:\(disposition.map(String.init(describing:)) ?? "noAttemptTerminal")")
      }
      guard document.assertion.isValid(at: nowUTC()) else {
        throw RockchipEvolutionCampaignError.campaignStopped(
          "confirmationExpired:\(document.assertion.validUntil)")
      }
      guard !Self.hasRepeatedNoEffectFailure(document) else {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "repeatedSafeNoEffect",
          detail: "\(Self.maximumConsecutiveNoEffectAttempts) consecutive attempts ended "
            + "with no external effect", at: nowUTC())
        throw RockchipEvolutionCampaignError.campaignStopped("repeatedSafeNoEffect")
      }
      guard document.reservedAttemptCount < document.assertion.maxAttempts else {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "attemptBudgetExhausted",
          detail: "\(document.reservedAttemptCount) of \(document.assertion.maxAttempts) "
            + "confirmed attempts are already reserved", at: nowUTC())
        throw RockchipEvolutionCampaignError.campaignStopped("attemptBudgetExhausted")
      }
      let priorCandidates = document.events.compactMap(\.candidate)
      guard priorCandidates.count < document.assertion.maxAttempts else {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "candidateBudgetExhausted",
          detail: "\(priorCandidates.count) of \(document.assertion.maxAttempts) candidates "
            + "are already prepared", at: nowUTC())
        throw RockchipEvolutionCampaignError.campaignStopped("candidateBudgetExhausted")
      }
      let proposedStrategy: RockchipEvolutionTypedStrategy
      do {
        proposedStrategy = try await repairer.propose(
          assertion: document.assertion, observation: observation,
          priorCandidates: priorCandidates)
      } catch {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "strategyRepairRejected",
          detail: "\(error)", at: nowUTC())
        throw error
      }
      let strategy: RockchipEvolutionTypedStrategy
      do {
        strategy = try Self.constrain(
          proposedStrategy, toRequiredStartingModeFrom: observation)
      } catch {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "candidateModeConstraintRejected",
          detail: "\(error)", at: nowUTC())
        throw error
      }
      let build: RockchipEvolutionCandidateBuild
      do {
        build = try await builder.build(assertion: document.assertion, strategy: strategy)
      } catch let error as RockchipEvolutionCampaignError {
        if Self.invalidatesCampaign(error) {
          _ = try? ledger.stop(
            campaignID: document.campaignID, reasonCode: "candidateEnvelopeDrift",
            detail: "\(error)", at: nowUTC())
        }
        throw error
      }
      document = try ledger.appendCandidate(
        campaignID: document.campaignID, candidate: build.pin, at: nowUTC())
      let permit = try RockchipEvolutionCampaignAttemptPermit(
        assertion: document.assertion, candidate: build.pin)
      let request = try RockchipFlashExecutionRequest(
        evolutionCampaignAttempt: permit, archiveURL: archiveURL,
        targetLocationSelector: targetLocationSelector)
      let reservedBeforeDispatch = document.reservedAttemptCount
      do {
        // Nine gates and the reservation mint, for the lane whose executor
        // cannot do it itself. This runs inside the same do/catch as dispatch
        // on purpose: an admission that reserved and then failed leaves the
        // campaign ledger's attemptReserved event behind, and the reconcile
        // below is what resolves it — exactly as when the in-process lane
        // failed after admitting inside execute.
        let admitted = try await flash.attemptAdmitter?.admitAttempt(
          permit: permit, archiveURL: archiveURL,
          targetLocationSelector: targetLocationSelector)
        let result = try await flash.execute(request, admitted: admitted)
        let closed = try reconcileUnresolved(ledger.load(document.campaignID))
        guard let terminal = closed.events.last(where: { $0.kind == .attemptTerminal }),
          terminal.disposition == .succeeded, let ordinal = terminal.ordinal
        else {
          throw RockchipEvolutionCampaignError.campaignStopped("missingSuccessfulTerminal")
        }
        return RockchipEvolutionCampaignExecutionResult(
          campaignID: document.campaignID, attemptOrdinal: ordinal, flash: result)
      } catch {
        if case RockchipFlashExecutionError.submissionRefused = error,
          let current = try? ledger.load(document.campaignID),
          let reservationID = current.activeReservation?.reservationID
        {
          // The daemon's authored rejection dispatched nothing — no job was
          // created. Durable-ize that answer so the settle below reads a
          // terminal with an empty external-intent set (exactly what
          // `safeToReflash` requires) instead of an absence it must call
          // unknown. If an engine-side terminal already exists it stands;
          // this write losing a race means the request did reach a job
          // after all, and the durable record is the authority.
          try? _ = usageLedger.close(
            reservationID: reservationID,
            terminal: AgentAuthorityUsageTerminal(
              status: .failed, closedAt: nowUTC(),
              externalIntentEventIDs: []))
        }
        document = (try? reconcileUnresolved(ledger.load(document.campaignID))) ?? document
        if case RockchipFlashExecutionError.submissionRefused = error {
          // Settled retry-safe above. Surface the refusal instead of looping
          // the repairer against the same host fault; the operator fixes the
          // daemon and continues the same campaign.
          throw error
        }
        if document.reservedAttemptCount == reservedBeforeDispatch,
          let mode = Self.startingModeMismatch(error)
        {
          // A candidate that excludes the already-read live mode is a bad
          // typed proposal, not target drift and not a Flash attempt. Keep
          // the campaign bounded by its candidate budget and ask the
          // repairer for a strategy that includes the observed mode.
          observation = try RockchipEvolutionFailureObservation(
            attemptOrdinal: max(1, reservedBeforeDispatch + 1),
            failureCode: "flash.startingModeNotAllowed:\(mode)")
          continue
        }
        guard document.reservedAttemptCount == reservedBeforeDispatch + 1 else {
          // The catch-all. Before this carried the underlying error, a
          // campaign that died here recorded four words and left the actual
          // cause to be excavated from macOS crash reports.
          _ = try? ledger.stop(
            campaignID: document.campaignID, reasonCode: "admissionOrTargetDrift",
            detail: "\(error)", at: nowUTC())
          throw error
        }
        guard
          let terminal = document.events.last(where: { $0.kind == .attemptTerminal }),
          terminal.disposition == .safeToReflash, let ordinal = terminal.ordinal,
          document.reservedAttemptCount < document.assertion.maxAttempts
        else { throw error }
        observation = try RockchipEvolutionFailureObservation(
          attemptOrdinal: ordinal, failureCode: Self.failureCode(error))
      }
    }
  }

  private func reconcileUnresolved(
    _ document: RockchipEvolutionCampaignDocument
  ) throws -> RockchipEvolutionCampaignDocument {
    guard let active = document.activeReservation, let reservationID = active.reservationID,
      let ordinal = active.ordinal, let jobID = active.jobID, let sessionID = active.sessionID
    else { return document }
    let usage = try usageLedger.load().reservations.first {
      $0.reservationID == reservationID
    }
    let disposition: RockchipEvolutionAttemptDisposition
    let basis: String
    switch Self.classify(terminal: usage?.terminal) {
    case .decided(let decided, let why):
      disposition = decided
      basis = why
    case .requiresLoaderTransitionReadback(let why):
      let settled = settlesUnknownLoaderTransition(document: document, jobID: jobID)
      disposition = settled ? .safeToReflash : .outcomeUnknown
      basis = "\(why) readback=\(settled ? "settled" : "refused")"
    }
    let intents = usage?.terminal?.externalIntentEventIDs ?? []
    if let usage, usage.terminal == nil {
      // Close the usage reservation too, or the target stays blocked
      // forever: the ledger admits one open reservation per target, and a
      // crashed attempt's reservation had no other closer (regression C3).
      // `outcomeUnknown` mirrors the attempt tombstone below.
      //
      // This terminal is an absence, not a measurement, and the empty intent
      // sets say so: nothing read the device, and nothing may later mistake
      // them for "no mutation was dispatched" (TASK-AIN-020).
      do {
        _ = try usageLedger.close(
          reservationID: reservationID,
          terminal: AgentAuthorityUsageTerminal(
            status: .outcomeUnknown, closedAt: nowUTC(),
            externalIntentEventIDs: []))
      } catch AuthorizationUsageLedgerError.reservationConflict {
        // Raced the dying process's own close; whoever wrote a terminal
        // won, and the re-read on the next continue sees it.
      }
    }
    return try ledger.closeAttempt(
      campaignID: document.campaignID, ordinal: ordinal,
      jobID: jobID, sessionID: sessionID, disposition: disposition,
      destructiveIntentEventIDs: intents, basis: basis, at: nowUTC())
  }

  /// Which rule decides an attempt, and on what evidence.
  ///
  /// Split out of `reconcileUnresolved` because the order of these rules is a
  /// property worth stating rather than an accident of an `if`/`else if`
  /// chain: **evidence outranks status**. Until r17 the `outcomeUnknown`
  /// status was tested first, so the intent-set rules below it could never be
  /// reached for that status at all.
  ///
  /// Be precise about what that reordering does and does not buy.
  /// `AgentAuthorityUsageTerminal` refuses a non-empty
  /// `confirmedNotExecutedIntentEventIDs` unless the status is `.failed`, so an
  /// `outcomeUnknown` terminal cannot carry that proof today — the short
  /// circuit was never the binding constraint, that ledger invariant is. The
  /// order is corrected anyway, so a status can never again outrank a proof,
  /// and pinned by a test rather than left to be rediscovered a third time.
  ///
  /// The rule that actually stopped dropping evidence is one layer down: the
  /// dedicated reconciliation readback now journals its no-effect proof with
  /// the semantic code `mutationIntentEvidence` recognizes, so a proven
  /// non-execution reaches `confirmedNotExecutedIntentEventIDs` instead of
  /// leaving the campaign to burn as `unsafePartial`.
  static func classify(terminal: AgentAuthorityUsageTerminal?) -> AttemptClassification {
    guard let terminal else {
      // A durable campaign reservation without a matching durable terminal is
      // unknown even if the current process happens to remember an error, and
      // it is *not* a readback case: see `settlesUnknownLoaderTransition`.
      return .decided(.outcomeUnknown, basis: "noDurableTerminal")
    }
    return classify(
      status: terminal.status,
      dispatched: Set(terminal.externalIntentEventIDs),
      confirmedNotExecuted: Set(terminal.confirmedNotExecutedIntentEventIDs),
      completed: Set(terminal.completedIntentEventIDs))
  }

  /// The rules over the four facts they decide on, rather than over the type
  /// that carries them. The ledger refuses some combinations — a non-empty
  /// proven-absent set outside a `.failed` terminal, for one — so taking the
  /// facts directly is the only way to test the *order* of these rules against
  /// a shape the ledger will not build. An untestable rule order is how the
  /// status came to outrank the evidence in the first place.
  static func classify(
    status: AuthorizationUsageTerminalStatus,
    dispatched: Set<String>,
    confirmedNotExecuted: Set<String>,
    completed: Set<String>
  ) -> AttemptClassification {
    let counts =
      "terminal=\(status.rawValue) dispatched=\(dispatched.count) "
      + "confirmedNotExecuted=\(confirmedNotExecuted.count) completed=\(completed.count)"
    if status == .succeeded {
      return .decided(.succeeded, basis: "\(counts) rule=terminalSucceeded")
    }
    if !dispatched.isEmpty, confirmedNotExecuted == dispatched {
      // The strongest evidence the product can hold: every mutation it
      // dispatched has an exact readback proving it never happened. Tested
      // before the status, because no status outranks a proof of no effect.
      return .decided(
        .safeToReflash, basis: "\(counts) rule=everyDispatchedMutationConfirmedNotExecuted")
    }
    if status == .outcomeUnknown {
      return .requiresLoaderTransitionReadback(basis: "\(counts) rule=loaderTransitionReadback")
    }
    if dispatched.isEmpty {
      return .decided(.safeToReflash, basis: "\(counts) rule=noMutationDispatched")
    }
    if confirmedNotExecuted.union(completed) == dispatched {
      // Every dispatched mutation has a proven resolution: either its
      // exact readback proved it never happened, or its own provider
      // verification proved it completed. There is no unknown partial
      // effect on the device — which is precisely what `safeToReflash`
      // asserts. The 2026-08-04 shape this settles: nine verified writes,
      // a verified reboot, and then a failure in a read-only wait; the
      // device had booted the flashed build, and the campaign burned as
      // `unsafePartial` anyway.
      return .decided(.safeToReflash, basis: "\(counts) rule=everyDispatchedMutationResolved")
    }
    return .decided(.unsafePartial, basis: "\(counts) rule=unresolvedDispatchedMutations")
  }

  /// TASK-AIN-019 r11 approved exactly one way out of a failed Loader
  /// transition: re-read the *same* durable target in a registered mode. Until
  /// now that rule only reached the executor's own `confirmedNotExecuted`
  /// path, so an engine-lane attempt that ended `outcomeUnknown` — which is
  /// what a host tool killed mid-transition produces — was sealed forever and
  /// took its whole campaign with it.
  ///
  /// This applies the same rule to the unknown terminal, and nowhere else:
  ///
  /// * only when every intent the job journaled is a Loader-transition-class
  ///   step. One `flashPartition` (or any step whose kind can be destructive,
  ///   or any kind this build does not recognize) and the path never applies —
  ///   an interrupted partition write is not made safe by the device coming
  ///   back, and `flash-partitions` keeps its unknown semantics untouched.
  /// * only when the readback names the identity this campaign is pinned to,
  ///   in a mode the product has registered.
  ///
  /// It is a pure read: no mutation is re-sent, no usage terminal is rewritten
  /// (they are append-only), and no new terminal vocabulary is invented — the
  /// proof is "no external effect happened", which is what `safeToReflash`
  /// already means for the `confirmedNotExecuted` intents beside it.
  ///
  /// ## What this settles, and what it deliberately does not (TASK-AIN-020)
  ///
  /// It settles an **engine-written** `outcomeUnknown` — a job that survived,
  /// measured that it could not observe its own outcome, and journaled complete
  /// intent sets. That is production-reachable: an unobservable dispatch, or a
  /// provider whose verification returns unknown for a step with no paired
  /// readback.
  ///
  /// It does **not** settle a crashed attempt, and cannot be made to without
  /// changing two other things first. Three device windows interrupted a flash
  /// by killing the writer, so all three left no durable terminal at all and
  /// took the `noDurableTerminal` path, which never reaches here. That is
  /// structural, not a matter of timing:
  ///
  /// * reconciliation writes its own unknown terminal and closes the attempt in
  ///   the same pass, so the terminal it wrote is never re-read — after it,
  ///   `document.activeReservation` is nil and `reconcileUnresolved` returns at
  ///   its first guard;
  /// * the classifier's only input is `actualStepKinds`, a runtime-record
  ///   projection persisted *before* the write-ahead intent gate makes an
  ///   intent durable. A process death between the two leaves a durable
  ///   destructive intent that the projection does not name — exactly the
  ///   window a crash lands in. Harmless while the crash path never consults
  ///   the readback; a correctness hole the moment it does.
  ///
  /// So a crashed attempt stays `outcomeUnknown`, and this is not documented as
  /// recovering it.
  private func settlesUnknownLoaderTransition(
    document: RockchipEvolutionCampaignDocument,
    jobID: String
  ) -> Bool {
    guard let kinds = try? attemptIntents.journaledStepKinds(jobID: jobID),
      Self.isLoaderTransitionOnly(kinds)
    else { return false }
    guard let readback = try? targetReadback.readDurableTarget(),
      let observed = readback.stableIdentitySHA256,
      observed == document.assertion.targetStableIdentitySHA256,
      readback.registeredMode != nil
    else { return false }
    return true
  }

  static func isLoaderTransitionOnly(_ rawKinds: [String]) -> Bool {
    var sawTransition = false
    for raw in rawKinds {
      switch WorkflowStepRegistry.resolve(rawKind: raw) {
      case .unsupported:
        // An unrecognized kind is assumed destructive by the registry, and a
        // build that cannot name a step cannot prove anything about it.
        return false
      case .supported(let kind, let metadata):
        guard metadata.minimumEffect < .destructive else { return false }
        if kind == .enterUpdater { sawTransition = true }
      }
    }
    return sawTransition
  }

  private static func invalidatesCampaign(_ error: RockchipEvolutionCampaignError) -> Bool {
    switch error {
    case .candidateRejected(let reason):
      return [
        "scopeDrift", "toolchainDrift", "immutablePinDrift", "taskOwnedWorkspace",
        "protectedMainBase", "workspaceEscape", "unsafeSourceEntry",
      ].contains(reason)
    case .expired, .confirmationDigestMismatch, .invalidAssertion:
      return true
    default:
      return false
    }
  }

  private static func hasRepeatedNoEffectFailure(
    _ document: RockchipEvolutionCampaignDocument
  ) -> Bool {
    let terminalAttempts = document.events.filter { $0.kind == .attemptTerminal }
    guard terminalAttempts.count >= maximumConsecutiveNoEffectAttempts else { return false }
    return terminalAttempts.suffix(maximumConsecutiveNoEffectAttempts).allSatisfy {
      $0.disposition == .safeToReflash
    }
  }

  /// A pre-reservation mode mismatch is an exact live observation, not a
  /// suggestion for the model.  Keep every model-controlled timing choice,
  /// but add the observed mode to its closed typed entry set before the
  /// candidate is built. This prevents a succession of distinct
  /// loader-only candidates from churning before a normal-mode device can
  /// reserve a next attempt.
  private static func constrain(
    _ strategy: RockchipEvolutionTypedStrategy,
    toRequiredStartingModeFrom observation: RockchipEvolutionFailureObservation?
  ) throws -> RockchipEvolutionTypedStrategy {
    guard let observation,
      let mode = requiredStartingMode(from: observation.failureCode)
    else { return strategy }
    return try RockchipEvolutionTypedStrategy(
      operationReference: strategy.operationReference,
      deviceProfileReference: strategy.deviceProfileReference,
      archiveDigestSHA256: strategy.archiveDigestSHA256,
      stepSetDigestSHA256: strategy.stepSetDigestSHA256,
      allowedStartingModes: strategy.allowedStartingModes + [mode],
      loaderDiscoveryTimeoutSeconds: strategy.loaderDiscoveryTimeoutSeconds,
      loaderPollIntervalMilliseconds: strategy.loaderPollIntervalMilliseconds,
      hdcCommandTimeoutSeconds: strategy.hdcCommandTimeoutSeconds,
      readOnlyCommandTimeoutSeconds: strategy.readOnlyCommandTimeoutSeconds,
      userdataImpact: strategy.userdataImpact)
  }

  private static func requiredStartingMode(from failureCode: String)
    -> RockchipEvolutionStartingMode?
  {
    let prefix = "flash.startingModeNotAllowed:"
    guard failureCode.hasPrefix(prefix) else { return nil }
    return RockchipEvolutionStartingMode(rawValue: String(failureCode.dropFirst(prefix.count)))
  }

  private static func failureCode(_ error: any Error) -> String {
    guard let error = error as? RockchipFlashExecutionError else {
      if let campaign = error as? RockchipEvolutionCampaignError {
        switch campaign {
        case .admissionRejected: return "campaign.admissionRejected"
        case .candidateRejected: return "campaign.candidateRejected"
        default: return "campaign.safeFailure"
        }
      }
      return "flash.safeFailure"
    }
    switch error {
    case .admissionRejected: return "flash.admissionRejected"
    case .authorizationGateRejected: return "flash.authorizationGateRejected"
    case .authorizationConsumptionRejected: return "flash.authorizationConsumptionRejected"
    case .storageRejected: return "flash.storageRejected"
    case .stagingRejected: return "flash.stagingRejected"
    case .loweringRejected: return "flash.loweringRejected"
    case .executableIdentityDrift: return "flash.executableIdentityDrift"
    case .persistenceRejected: return "flash.persistenceRejected"
    // Step identifiers are evidence identifiers, not failure-code components:
    // published operation references contain `@` (for example
    // `flash.dayu200`), while observations deliberately accept only the
    // narrow, bounded failure-code grammar. Keep the repair signal stable and
    // retain the exact step detail in the durable job evidence instead.
    case .semanticFailure(let stepID, _):
      if RockchipFlashRuntimeDiagnostic.allCases.contains(where: {
        $0.evolutionFailureCode == stepID
      }) {
        return stepID
      }
      return "flash.semanticFailure"
    case .cancelledAtSafeBoundary: return "flash.cancelledAtSafeBoundary"
    case .invalidRequest: return "flash.invalidRequest"
    case .productionConfigurationUnavailable: return "flash.configurationUnavailable"
    case .submissionRefused: return "flash.submissionRefused"
    case .recoveryRequired, .postflightMismatch: return "flash.unsafeFailure"
    }
  }

  private static func startingModeMismatch(_ error: any Error) -> String? {
    // Both spellings, because both lanes reach the same gate by different
    // routes: the in-process executor wraps the campaign rejection in a flash
    // error, while the engine lane's admitter throws it directly.
    let detail: String
    switch error {
    case let flash as RockchipFlashExecutionError:
      guard case .admissionRejected(let value) = flash else { return nil }
      detail = value
    case let campaign as RockchipEvolutionCampaignError:
      guard case .admissionRejected(let value) = campaign else { return nil }
      detail = value
    default:
      return nil
    }
    let prefix = "startingModeNotAllowed:"
    guard detail.hasPrefix(prefix) else { return nil }
    let mode = String(detail.dropFirst(prefix.count))
    return RockchipEvolutionStartingMode(rawValue: mode)?.rawValue
  }

  /// A configured model vendor gets the repair lane; everything else gets the
  /// published strategy. Requiring the vendor up front made an unconfigured
  /// host refuse the whole campaign, including the first attempt, which never
  /// asks the repairer for anything a confirmation does not already pin.
  /// `PublishedRockchipEvolutionStrategyRepairer` still refuses to invent a
  /// repair, so an unconfigured host loses attempt evolution — not the safety
  /// of any attempt it does run.
  private static func repairer(
    environment: [String: String], workingDirectory: String
  ) throws -> any RockchipEvolutionStrategyRepairing {
    guard
      let provider = environment[EvolutionCampaignRepairConfiguration.providerKey]?.lowercased(),
      let profile = LocalAgentCLIProfile.named(provider),
      let path = environment[EvolutionCampaignRepairConfiguration.cliPathKey],
      let model = environment[EvolutionCampaignRepairConfiguration.modelKey]
    else { return PublishedRockchipEvolutionStrategyRepairer() }
    return try LocalAgentRockchipEvolutionStrategyRepairer(
      profile: profile, executablePath: path, modelName: model,
      workingDirectory: workingDirectory)
  }
}

private struct RockchipEvolutionProductRoots {
  let arkDeckRoot: URL
  let usageRoot: URL
  let campaignLedgerRoot: URL
  let candidateRoot: URL
  let repairerRoot: URL

  static func load() throws -> Self {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    let usage = root.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    let campaign = usage.appending(path: "evolution-campaigns", directoryHint: .isDirectory)
    let candidates = root.appending(path: "EvolutionCandidates", directoryHint: .isDirectory)
    let repairer = candidates.appending(path: "Repairer", directoryHint: .isDirectory)
    for directory in [root, usage, campaign, candidates, repairer] {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chmod(directory.path, 0o700) == 0 else {
        throw RockchipEvolutionCampaignError.persistenceRejected("ownerOnlyDirectory")
      }
    }
    return Self(
      arkDeckRoot: root, usageRoot: usage,
      campaignLedgerRoot: campaign, candidateRoot: candidates, repairerRoot: repairer,
    )
  }
}
