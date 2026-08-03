// Product-facing bounded Evolution campaign composition
// (CHG-2026-025 r8, TASK-AIN-019).

import ArkDeckHarness
import ArkDeckWorkflows
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation

public struct RockchipEvolutionCampaignPreview: Sendable, Equatable {
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

public struct RockchipEvolutionCampaignExecutionResult: Sendable, Equatable {
  public let campaignID: String
  public let attemptOrdinal: Int
  public let flash: RockchipFlashExecutionResult

  public init(campaignID: String, attemptOrdinal: Int, flash: RockchipFlashExecutionResult) {
    self.campaignID = campaignID
    self.attemptOrdinal = attemptOrdinal
    self.flash = flash
  }
}

public protocol RockchipEvolutionFlashDispatching: Sendable {
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
  public var attemptAdmitter: (any RockchipEvolutionCampaignAttemptAdmitting)? { nil }
}



/// E0 preview. It hashes the complete published archive, protected-main base,
/// candidate toolchain, running broker and durable stable target. It creates a
/// non-authoritative draft ledger only; no usage reservation or device process
/// exists on this path. The draft expires with its assertion: a preview that
/// is never confirmed leaves a zero-event document that any later preview or
/// admission sweeps away once `validUntil` passes, so unconfirmed previews
/// accumulate no permanent campaign documents.
public enum RockchipEvolutionCampaignPlanning {
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
    let plan = try await RockchipProductExecutePlanFactPort()
      .makeValidatedExecutePlan(archiveURL: archiveURL.standardizedFileURL)
    let roots = try RockchipEvolutionProductRoots.load()
    let binding = try RockchipProductBindingStore(rootURL: roots.arkDeckRoot).loadExisting()
    let stableIdentity = SHA256.hash(data: Data(binding.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    async let base =
      ProductRockchipEvolutionCandidateBuilder
      .currentProtectedMainBaseCommitOID()
    async let toolchain = ProductRockchipEvolutionCandidateBuilder.currentToolchainDigest()
    let broker = try ProductRockchipEvolutionCandidateBuilder.currentBrokerExecutableDigest()
    let now = Date()
    let confirmedAt = ISO8601DateFormatter().string(from: now)
    let validUntil = ISO8601DateFormatter().string(
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

public final class RockchipEvolutionCampaignHost: @unchecked Sendable {
  private let ledger: RockchipEvolutionCampaignLedger
  private let usageLedger: AgentAuthorityUsageLedger
  private let repairer: any RockchipEvolutionStrategyRepairing
  private let builder: any RockchipEvolutionCandidateBuilding
  private let reviewer: any RockchipEvolutionAdversarialReviewing
  private let flash: any RockchipEvolutionFlashDispatching
  private let nowUTC: @Sendable () -> String

  /// There is no default execution lane. A campaign attempt runs on the
  /// runtime job lane and nowhere else: the in-process flash executor this
  /// used to default to has been retired (T25), and re-adding a default is
  /// how a second execution stack comes back.
  public convenience init(
    flash: any RockchipEvolutionFlashDispatching,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let roots = try RockchipEvolutionProductRoots.load()
    let repairer = try Self.repairer(
      environment: environment, workingDirectory: roots.repairerRoot.path)
    let reviewer = try Self.reviewer(
      environment: environment, workingDirectory: roots.reviewerRoot.path)
    try self.init(
      ledger: RockchipEvolutionCampaignLedger(root: roots.campaignLedgerRoot),
      usageLedger: AgentAuthorityUsageLedger(root: roots.usageRoot),
      repairer: repairer,
      builder: ProductRockchipEvolutionCandidateBuilder(stateRoot: roots.candidateRoot),
      reviewer: reviewer,
      flash: flash,
      nowUTC: { ISO8601DateFormatter().string(from: Date()) })
  }

  package init(
    ledger: RockchipEvolutionCampaignLedger,
    usageLedger: AgentAuthorityUsageLedger,
    repairer: any RockchipEvolutionStrategyRepairing,
    builder: any RockchipEvolutionCandidateBuilding,
    reviewer: any RockchipEvolutionAdversarialReviewing,
    flash: any RockchipEvolutionFlashDispatching,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.ledger = ledger
    self.usageLedger = usageLedger
    self.repairer = repairer
    self.builder = builder
    self.reviewer = reviewer
    self.flash = flash
    self.nowUTC = nowUTC
  }

  public func executeConfirmedCampaign(
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

  public func continueCampaign(
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
  /// no reviewer — only the durable document. Keeping this off the
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
      guard !document.isTerminal, document.assertion.isValid(at: nowUTC()) else {
        throw RockchipEvolutionCampaignError.campaignStopped("terminalOrExpired")
      }
      guard document.reservedAttemptCount < document.assertion.maxAttempts else {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "attemptBudgetExhausted", at: nowUTC())
        throw RockchipEvolutionCampaignError.campaignStopped("attemptBudgetExhausted")
      }
      let priorCandidates = document.events.compactMap(\.candidate)
      guard priorCandidates.count < document.assertion.maxAttempts else {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "candidateBudgetExhausted", at: nowUTC())
        throw RockchipEvolutionCampaignError.campaignStopped("candidateBudgetExhausted")
      }
      let strategy: RockchipEvolutionTypedStrategy
      do {
        strategy = try await repairer.propose(
          assertion: document.assertion, observation: observation,
          priorCandidates: priorCandidates)
      } catch {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "strategyRepairRejected", at: nowUTC())
        throw error
      }
      let build: RockchipEvolutionCandidateBuild
      do {
        build = try await builder.build(assertion: document.assertion, strategy: strategy)
      } catch let error as RockchipEvolutionCampaignError {
        if Self.invalidatesCampaign(error) {
          _ = try? ledger.stop(
            campaignID: document.campaignID, reasonCode: "candidateEnvelopeDrift", at: nowUTC())
        }
        throw error
      }
      let review: RockchipEvolutionReviewReceipt
      do {
        review = try await reviewer.review(
          RockchipEvolutionAdversarialReviewRequest(
            assertion: document.assertion, candidate: build.pin,
            immutableDiff: build.reviewDiff, priorAttempts: document.events))
      } catch {
        _ = try? ledger.stop(
          campaignID: document.campaignID, reasonCode: "adversarialReviewRejected", at: nowUTC())
        throw error
      }
      document = try ledger.appendCandidate(
        campaignID: document.campaignID, candidate: build.pin,
        review: review, at: nowUTC())
      let permit = try RockchipEvolutionCampaignAttemptPermit(
        assertion: document.assertion, candidate: build.pin, review: review)
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
        document = (try? reconcileUnresolved(ledger.load(document.campaignID))) ?? document
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
          _ = try? ledger.stop(
            campaignID: document.campaignID, reasonCode: "admissionOrTargetDrift", at: nowUTC())
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
    let intents: [String]
    if let terminal = usage?.terminal {
      intents = terminal.externalIntentEventIDs
      if terminal.status == .succeeded {
        disposition = .succeeded
      } else if terminal.status == .outcomeUnknown {
        disposition = .outcomeUnknown
      } else if terminal.externalIntentEventIDs.isEmpty
        || Set(terminal.confirmedNotExecutedIntentEventIDs)
          == Set(terminal.externalIntentEventIDs)
      {
        disposition = .safeToReflash
      } else {
        disposition = .unsafePartial
      }
    } else {
      // A durable campaign reservation without a matching durable terminal is
      // unknown even if the current process happens to remember an error.
      intents = []
      disposition = .outcomeUnknown
      // Close the usage reservation too, or the target stays blocked
      // forever: the ledger admits one open reservation per target, and a
      // crashed attempt's reservation had no other closer (adversarial
      // review C3). `outcomeUnknown` mirrors the attempt tombstone below.
      if usage != nil {
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
    }
    return try ledger.closeAttempt(
      campaignID: document.campaignID, ordinal: ordinal,
      jobID: jobID, sessionID: sessionID, disposition: disposition,
      destructiveIntentEventIDs: intents, at: nowUTC())
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
    case .semanticFailure(let stepID, _): return "flash.semanticFailure:\(stepID)"
    case .cancelledAtSafeBoundary: return "flash.cancelledAtSafeBoundary"
    case .invalidRequest: return "flash.invalidRequest"
    case .productionConfigurationUnavailable: return "flash.configurationUnavailable"
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

  private static func reviewer(
    environment: [String: String], workingDirectory: String
  ) throws -> CodexRockchipEvolutionAdversarialReviewer {
    guard environment[HarnessVendorConfiguration.providerKey]?.lowercased() == "codex",
      let path = environment[HarnessVendorConfiguration.codexPathKey],
      let model = environment[HarnessVendorConfiguration.modelKey]
    else { throw RockchipEvolutionCampaignError.reviewRejected("codexReviewerRequired") }
    return try CodexRockchipEvolutionAdversarialReviewer(
      executablePath: path, modelName: model, workingDirectory: workingDirectory)
  }

  private static func repairer(
    environment: [String: String], workingDirectory: String
  ) throws -> CodexRockchipEvolutionStrategyRepairer {
    guard environment[HarnessVendorConfiguration.providerKey]?.lowercased() == "codex",
      let path = environment[HarnessVendorConfiguration.codexPathKey],
      let model = environment[HarnessVendorConfiguration.modelKey]
    else { throw RockchipEvolutionCampaignError.candidateRejected("codexRepairerRequired") }
    return try CodexRockchipEvolutionStrategyRepairer(
      executablePath: path, modelName: model, workingDirectory: workingDirectory)
  }
}

private struct RockchipEvolutionProductRoots {
  let arkDeckRoot: URL
  let usageRoot: URL
  let campaignLedgerRoot: URL
  let candidateRoot: URL
  let repairerRoot: URL
  let reviewerRoot: URL

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
    let reviewer = candidates.appending(path: "Reviewer", directoryHint: .isDirectory)
    for directory in [root, usage, campaign, candidates, repairer, reviewer] {
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
      reviewerRoot: reviewer)
  }
}
