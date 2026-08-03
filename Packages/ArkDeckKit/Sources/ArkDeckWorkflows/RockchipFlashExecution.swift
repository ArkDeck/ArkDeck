import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Foundation

public struct RockchipFlashExecutionRequest: Sendable, Equatable {
  enum Authority: Sendable, Equatable {
    case standingAuthorization(String)
    case evolutionCampaign(RockchipEvolutionCampaignAttemptPermit)
  }

  let authority: Authority
  public let archiveURL: URL
  public let targetLocationSelector: String

  public var authorizationID: String? {
    guard case .standingAuthorization(let value) = authority else { return nil }
    return value
  }

  public var evolutionCampaignID: String? {
    guard case .evolutionCampaign(let permit) = authority else { return nil }
    return permit.assertion.campaignID
  }

  public init(
    authorizationID: String,
    archiveURL: URL,
    targetLocationSelector: String
  ) throws {
    guard RockchipStandingAuthorizationIdentifier.isValid(authorizationID) else {
      throw RockchipFlashExecutionError.invalidRequest("authorizationId")
    }
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/") else {
      throw RockchipFlashExecutionError.invalidRequest("archiveURL")
    }
    guard !targetLocationSelector.isEmpty,
      targetLocationSelector.utf8.allSatisfy({ (48...57).contains($0) }),
      targetLocationSelector == "0" || targetLocationSelector.first != "0"
    else { throw RockchipFlashExecutionError.invalidRequest("targetLocationSelector") }
    authority = .standingAuthorization(authorizationID)
    self.archiveURL = archiveURL.standardizedFileURL
    self.targetLocationSelector = targetLocationSelector
  }

  public init(
    evolutionCampaignAttempt permit: RockchipEvolutionCampaignAttemptPermit,
    archiveURL: URL,
    targetLocationSelector: String
  ) throws {
    guard archiveURL.isFileURL, archiveURL.path.hasPrefix("/") else {
      throw RockchipFlashExecutionError.invalidRequest("archiveURL")
    }
    guard !targetLocationSelector.isEmpty,
      targetLocationSelector.utf8.allSatisfy({ (48...57).contains($0) }),
      targetLocationSelector == "0" || targetLocationSelector.first != "0"
    else { throw RockchipFlashExecutionError.invalidRequest("targetLocationSelector") }
    authority = .evolutionCampaign(permit)
    self.archiveURL = archiveURL.standardizedFileURL
    self.targetLocationSelector = targetLocationSelector
  }
}

public enum RockchipFlashExecutionStatus: String, Sendable, Equatable {
  case succeeded
  case waitingForRecovery
}

public enum RockchipExecutionEvidenceClass: String, Sendable, Equatable {
  case production
  case contractFake
}

public struct RockchipFlashExecutionResult: Sendable, Equatable {
  public let sessionID: String
  public let jobID: String
  public let status: RockchipFlashExecutionStatus
  public let evidenceClass: RockchipExecutionEvidenceClass
  public let manifestURL: URL?

  public init(
    sessionID: String,
    jobID: String,
    status: RockchipFlashExecutionStatus,
    evidenceClass: RockchipExecutionEvidenceClass,
    manifestURL: URL?
  ) {
    self.sessionID = sessionID
    self.jobID = jobID
    self.status = status
    self.evidenceClass = evidenceClass
    self.manifestURL = manifestURL
  }
}

/// A closed, non-sensitive reason for a Loader transition that was proven not
/// to have happened.  These values intentionally carry no process output,
/// target identifier, or topology: they cross the engine-lane status boundary
/// and become input to the bounded evolution repairer.
public enum RockchipFlashRuntimeDiagnostic: String, Sendable, Equatable, CaseIterable {
  /// The exact normal-mode readback proved no transition, while the HDC
  /// process itself had no clean completion receipt.
  case enterLoaderHDCNoCleanReceipt
  /// The HDC process completed cleanly, but the exact Loader postcondition
  /// was never observed and the original normal-mode device remained present.
  case enterLoaderCommandCleanLoaderNotObserved

  /// Bounded observation code accepted by the evolution campaign contract.
  public var evolutionFailureCode: String {
    "flash.\(rawValue)"
  }
}

public enum RockchipFlashExecutionError: Error, Sendable, Equatable, LocalizedError {
  case invalidRequest(String)
  case productionConfigurationUnavailable(String)
  case admissionRejected(String)
  case authorizationGateRejected(String)
  case authorizationConsumptionRejected(String)
  case storageRejected(String)
  case stagingRejected(String)
  case loweringRejected(String)
  case executableIdentityDrift
  case persistenceRejected(String)
  case semanticFailure(stepID: String, detail: String)
  case recoveryRequired(stepID: String, detail: String)
  case postflightMismatch
  case cancelledAtSafeBoundary

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let field): "invalid execution request: \(field)"
    case .productionConfigurationUnavailable(let detail):
      "product execution configuration unavailable: \(detail)"
    case .admissionRejected(let detail): "trusted admission rejected: \(detail)"
    case .authorizationGateRejected(let detail): "authorization gate rejected: \(detail)"
    case .authorizationConsumptionRejected(let detail):
      "authorization consumption rejected: \(detail)"
    case .storageRejected(let detail): "storage admission rejected: \(detail)"
    case .stagingRejected(let detail): "archive staging rejected: \(detail)"
    case .loweringRejected(let detail): "typed lowering rejected: \(detail)"
    case .executableIdentityDrift: "executable descriptor identity drifted from admission"
    case .persistenceRejected(let detail): "durable persistence rejected: \(detail)"
    case .semanticFailure(let stepID, let detail): "step \(stepID) failed: \(detail)"
    case .recoveryRequired(let stepID, let detail):
      "step \(stepID) has an unknown destructive outcome: \(detail)"
    case .postflightMismatch: "postflight identity or reconnect observation mismatched"
    case .cancelledAtSafeBoundary: "execution cancelled at a critical-write safe boundary"
    }
  }
}

struct RockchipExecutionAdmission: @unchecked Sendable {
  enum Backing: @unchecked Sendable {
    case evolutionCampaign(RockchipEvolutionCampaignAdmission)
  }

  enum AuthorityReference: Sendable, Equatable {
    case standingAuthorization(AuthorizationReference)
    case agent(AgentExecutionAuthorityReference)
  }

  let backing: Backing
  let plan: RockchipFlashPlan
  let authorityReference: AuthorityReference
  let usageReservationID: String
  let targetID: String
  let bindingRevision: Int
  let targetDigestSHA256: String
  let serialDigestSHA256: String
  let usbTopology: String
  let executableIdentity: ProcessExecutableIdentityReceipt
  let evidenceClass: RockchipExecutionEvidenceClass
  let evolutionStrategy: RockchipEvolutionTypedStrategy?

  init(
    backing: Backing,
    plan: RockchipFlashPlan,
    authorityReference: AuthorityReference,
    usageReservationID: String,
    targetID: String,
    bindingRevision: Int,
    targetDigestSHA256: String,
    serialDigestSHA256: String,
    usbTopology: String,
    executableIdentity: ProcessExecutableIdentityReceipt,
    evidenceClass: RockchipExecutionEvidenceClass,
    evolutionStrategy: RockchipEvolutionTypedStrategy? = nil
  ) {
    self.backing = backing
    self.plan = plan
    self.authorityReference = authorityReference
    self.usageReservationID = usageReservationID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.targetDigestSHA256 = targetDigestSHA256
    self.serialDigestSHA256 = serialDigestSHA256
    self.usbTopology = usbTopology
    self.executableIdentity = executableIdentity
    self.evidenceClass = evidenceClass
    self.evolutionStrategy = evolutionStrategy
  }

  var journalSchemaVersion: String {
    switch authorityReference {
    case .standingAuthorization: JournalEvent.rockchipAuthorizedAgentSchemaVersion
    case .agent: JournalEvent.agentAuthoritySchemaVersion
    }
  }

  var authorityKind: String {
    switch authorityReference {
    case .standingAuthorization: "standingAuthorization"
    case .agent(let reference): reference.kind.rawValue
    }
  }

  var confirmationDecidedAt: String? {
    guard case .agent(let reference) = authorityReference else { return nil }
    switch reference {
    case .chatConfirmation(_, _, _, _, _, let confirmedAt): return confirmedAt
    case .evolutionCampaignConfirmation(_, _, _, _, _, _, _, let confirmedAt, _, _):
      return confirmedAt
    case .readyTask, .deviceCapability, .standingAuthorization: return nil
    }
  }

  var legacyAuthorizationReference: AuthorizationReference? {
    guard case .standingAuthorization(let reference) = authorityReference else { return nil }
    return reference
  }

  var agentAuthorizationReference: AgentExecutionAuthorityReference? {
    guard case .agent(let reference) = authorityReference else { return nil }
    return reference
  }

  func correlatesAuthority(for effect: WorkflowEffect) -> Bool {
    switch authorityReference {
    case .standingAuthorization: effect == .destructive
    case .agent: effect >= .readOnly
    }
  }
}

/// Nine-gate admission for the campaign lane. Consumption and reservation
/// closing are deliberately absent: on the engine lane both belong to the
/// engine (#992), and re-adding them here is how the second execution stack
/// grows back.
protocol RockchipExecutionAdmissionPort: Sendable {
  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID: String,
    jobID: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission
}
