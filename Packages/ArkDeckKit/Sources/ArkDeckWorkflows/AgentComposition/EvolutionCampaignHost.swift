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
  func execute(_ request: RockchipFlashExecutionRequest) async throws
    -> RockchipFlashExecutionResult
}

extension RockchipFlashExecutionHost: RockchipEvolutionFlashDispatching {}

/// E0 preview. It hashes the complete published archive, protected-main base,
/// candidate toolchain, running broker and durable stable target. It creates a
/// non-authoritative draft ledger only; no usage reservation or device process
/// exists on this path.
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
    _ = try RockchipEvolutionCampaignLedger(root: roots.campaignLedgerRoot).create(assertion)
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

  public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment)
    throws
  {
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
      flash: RockchipFlashExecutionHost(),
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
    let document = try ledger.load(campaignID)
    return try await execute(
      document: document, archiveURL: archiveURL,
      targetLocationSelector: targetLocationSelector)
  }

  public func status(_ campaignID: String) throws -> RockchipEvolutionCampaignDocument {
    try ledger.load(campaignID)
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
        let result = try await flash.execute(request)
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
      } else if terminal.externalIntentEventIDs.isEmpty {
        disposition = .safeToReflash
      } else {
        disposition = .unsafePartial
      }
    } else {
      // A durable campaign reservation without a matching durable terminal is
      // unknown even if the current process happens to remember an error.
      intents = []
      disposition = .outcomeUnknown
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
