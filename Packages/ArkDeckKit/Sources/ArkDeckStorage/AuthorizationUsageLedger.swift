import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum AgentExecutionAuthorityKind: String, Codable, CaseIterable, Sendable {
  case readyTask
  case deviceCapability
  case standingAuthorization
  case chatConfirmation
  case evolutionCampaignConfirmation
}

/// Durable audit identity for an Agent admission. These values deliberately carry no executable
/// behavior and cannot be converted back into a live dispatch permit.
public enum AgentExecutionAuthorityReference: Equatable, Hashable, Sendable, Codable {
  case readyTask(
    changeID: String,
    taskID: String,
    mainCommitOID: String,
    taskBlobOID: String,
    approvalPRNumber: Int
  )
  case deviceCapability(
    capabilityID: String,
    mainCommitOID: String,
    capabilityBlobOID: String,
    approvalPRNumber: Int
  )
  case standingAuthorization(
    authorizationID: String,
    mainCommitOID: String,
    authorizationBlobOID: String,
    approvalPRNumber: Int
  )
  case chatConfirmation(
    confirmationDigestSHA256: String,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetDigestSHA256: String,
    confirmedAt: String
  )
  case evolutionCampaignConfirmation(
    campaignDigestSHA256: String,
    baseCommitOID: String,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetStableIdentitySHA256: String,
    bindingLineageRootRevision: Int,
    confirmedAt: String,
    validUntil: String,
    maximumAttempts: Int
  )

  private enum CodingKeys: String, CodingKey {
    case kind
    case changeID = "changeId"
    case taskID = "taskId"
    case capabilityID = "capabilityId"
    case authorizationID = "authorizationId"
    case mainCommitOID
    case taskBlobOID
    case capabilityBlobOID
    case authorizationBlobOID
    case approvalPRNumber
    case confirmationDigestSHA256
    case planDigestSHA256
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case targetDigestSHA256
    case campaignDigestSHA256
    case baseCommitOID
    case targetStableIdentitySHA256
    case bindingLineageRootRevision
    case validUntil
    case maximumAttempts
    case confirmedAt
  }

  public static func validatedReadyTask(
    changeID: String,
    taskID: String,
    mainCommitOID: String,
    taskBlobOID: String,
    approvalPRNumber: Int
  ) throws -> AgentExecutionAuthorityReference {
    guard changeID.agentAuthorityMatches(#"^CHG-[0-9]{4}-[0-9]{3}$"#),
      taskID.agentAuthorityMatches(#"^TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?$"#)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid ready-task identity")
    }
    try validateCommon(
      mainCommitOID: mainCommitOID, sourceBlobOID: taskBlobOID,
      approvalPRNumber: approvalPRNumber)
    return .readyTask(
      changeID: changeID, taskID: taskID, mainCommitOID: mainCommitOID,
      taskBlobOID: taskBlobOID, approvalPRNumber: approvalPRNumber)
  }

  public static func validatedDeviceCapability(
    capabilityID: String,
    mainCommitOID: String,
    capabilityBlobOID: String,
    approvalPRNumber: Int
  ) throws -> AgentExecutionAuthorityReference {
    guard capabilityID.agentAuthorityMatches(#"^CAP-E1-[A-Z0-9]+(?:-[A-Z0-9]+)*$"#) else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid capabilityId")
    }
    try validateCommon(
      mainCommitOID: mainCommitOID, sourceBlobOID: capabilityBlobOID,
      approvalPRNumber: approvalPRNumber)
    return .deviceCapability(
      capabilityID: capabilityID, mainCommitOID: mainCommitOID,
      capabilityBlobOID: capabilityBlobOID, approvalPRNumber: approvalPRNumber)
  }

  public static func validatedStandingAuthorization(
    authorizationID: String,
    mainCommitOID: String,
    authorizationBlobOID: String,
    approvalPRNumber: Int
  ) throws -> AgentExecutionAuthorityReference {
    guard authorizationID.agentAuthorityMatches(#"^AUTH-[A-Z0-9]+(?:-[A-Z0-9]+)*$"#) else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid authorizationId")
    }
    try validateCommon(
      mainCommitOID: mainCommitOID, sourceBlobOID: authorizationBlobOID,
      approvalPRNumber: approvalPRNumber)
    return .standingAuthorization(
      authorizationID: authorizationID, mainCommitOID: mainCommitOID,
      authorizationBlobOID: authorizationBlobOID, approvalPRNumber: approvalPRNumber)
  }

  public static func validatedChatConfirmation(
    confirmationDigestSHA256: String,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetDigestSHA256: String,
    confirmedAt: String
  ) throws -> AgentExecutionAuthorityReference {
    guard [
      confirmationDigestSHA256, planDigestSHA256, archiveDigestSHA256,
      stepSetDigestSHA256, targetDigestSHA256,
    ].allSatisfy({ $0.agentAuthorityMatches(#"^[a-f0-9]{64}$"#) }),
      AuthorizationUsageValidation.isTimestamp(confirmedAt)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "chat confirmation requires canonical digests and confirmedAt")
    }
    return .chatConfirmation(
      confirmationDigestSHA256: confirmationDigestSHA256,
      planDigestSHA256: planDigestSHA256,
      archiveDigestSHA256: archiveDigestSHA256,
      stepSetDigestSHA256: stepSetDigestSHA256,
      targetDigestSHA256: targetDigestSHA256,
      confirmedAt: confirmedAt)
  }

  public static func validatedEvolutionCampaignConfirmation(
    campaignDigestSHA256: String,
    baseCommitOID: String,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetStableIdentitySHA256: String,
    bindingLineageRootRevision: Int,
    confirmedAt: String,
    validUntil: String,
    maximumAttempts: Int
  ) throws -> AgentExecutionAuthorityReference {
    guard [
      campaignDigestSHA256, planDigestSHA256, archiveDigestSHA256,
      stepSetDigestSHA256, targetStableIdentitySHA256,
    ].allSatisfy({ $0.agentAuthorityMatches(#"^[a-f0-9]{64}$"#) }),
      baseCommitOID.agentAuthorityMatches(#"^[a-f0-9]{40}$"#),
      bindingLineageRootRevision > 0,
      (1...8).contains(maximumAttempts),
      AuthorizationUsageValidation.isTimestamp(confirmedAt),
      AuthorizationUsageValidation.isTimestamp(validUntil),
      let confirmedDate = AuthorizationUsageValidation.date(confirmedAt),
      let validUntilDate = AuthorizationUsageValidation.date(validUntil),
      confirmedDate < validUntilDate,
      validUntilDate.timeIntervalSince(confirmedDate) <= 4 * 60 * 60
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "evolution campaign confirmation requires closed pins and an 8 attempt/4 hour envelope")
    }
    return .evolutionCampaignConfirmation(
      campaignDigestSHA256: campaignDigestSHA256,
      baseCommitOID: baseCommitOID,
      planDigestSHA256: planDigestSHA256,
      archiveDigestSHA256: archiveDigestSHA256,
      stepSetDigestSHA256: stepSetDigestSHA256,
      targetStableIdentitySHA256: targetStableIdentitySHA256,
      bindingLineageRootRevision: bindingLineageRootRevision,
      confirmedAt: confirmedAt,
      validUntil: validUntil,
      maximumAttempts: maximumAttempts)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let dynamic = try decoder.container(keyedBy: AgentAuthorityDynamicCodingKey.self)
    let actualKeys = Set(dynamic.allKeys.map(\.stringValue))
    let kind = try container.decode(AgentExecutionAuthorityKind.self, forKey: .kind)
    switch kind {
    case .readyTask:
      guard
        actualKeys == [
          "kind", "changeId", "taskId", "mainCommitOID", "taskBlobOID", "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("readyTask shape is not closed")
      }
      self = try Self.validatedReadyTask(
        changeID: container.decode(String.self, forKey: .changeID),
        taskID: container.decode(String.self, forKey: .taskID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        taskBlobOID: container.decode(String.self, forKey: .taskBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .deviceCapability:
      guard
        actualKeys == [
          "kind", "capabilityId", "mainCommitOID", "capabilityBlobOID", "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "deviceCapability shape is not closed")
      }
      self = try Self.validatedDeviceCapability(
        capabilityID: container.decode(String.self, forKey: .capabilityID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        capabilityBlobOID: container.decode(String.self, forKey: .capabilityBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .standingAuthorization:
      guard
        actualKeys == [
          "kind", "authorizationId", "mainCommitOID", "authorizationBlobOID",
          "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "standingAuthorization shape is not closed")
      }
      self = try Self.validatedStandingAuthorization(
        authorizationID: container.decode(String.self, forKey: .authorizationID),
        mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
        authorizationBlobOID: container.decode(String.self, forKey: .authorizationBlobOID),
        approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
    case .chatConfirmation:
      guard
        actualKeys == [
          "kind", "confirmationDigestSHA256", "planDigestSHA256", "archiveDigestSHA256",
          "stepSetDigestSHA256", "targetDigestSHA256", "confirmedAt",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "chatConfirmation shape is not closed")
      }
      self = try Self.validatedChatConfirmation(
        confirmationDigestSHA256: container.decode(
          String.self, forKey: .confirmationDigestSHA256),
        planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
        archiveDigestSHA256: container.decode(String.self, forKey: .archiveDigestSHA256),
        stepSetDigestSHA256: container.decode(String.self, forKey: .stepSetDigestSHA256),
        targetDigestSHA256: container.decode(String.self, forKey: .targetDigestSHA256),
        confirmedAt: container.decode(String.self, forKey: .confirmedAt))
    case .evolutionCampaignConfirmation:
      guard
        actualKeys == [
          "kind", "campaignDigestSHA256", "baseCommitOID", "planDigestSHA256",
          "archiveDigestSHA256", "stepSetDigestSHA256", "targetStableIdentitySHA256",
          "bindingLineageRootRevision", "confirmedAt", "validUntil", "maximumAttempts",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "evolutionCampaignConfirmation shape is not closed")
      }
      self = try Self.validatedEvolutionCampaignConfirmation(
        campaignDigestSHA256: container.decode(String.self, forKey: .campaignDigestSHA256),
        baseCommitOID: container.decode(String.self, forKey: .baseCommitOID),
        planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
        archiveDigestSHA256: container.decode(String.self, forKey: .archiveDigestSHA256),
        stepSetDigestSHA256: container.decode(String.self, forKey: .stepSetDigestSHA256),
        targetStableIdentitySHA256: container.decode(
          String.self, forKey: .targetStableIdentitySHA256),
        bindingLineageRootRevision: container.decode(
          Int.self, forKey: .bindingLineageRootRevision),
        confirmedAt: container.decode(String.self, forKey: .confirmedAt),
        validUntil: container.decode(String.self, forKey: .validUntil),
        maximumAttempts: container.decode(Int.self, forKey: .maximumAttempts))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .readyTask(
      let changeID, let taskID, let mainCommitOID, let taskBlobOID, let approvalPRNumber):
      try container.encode(changeID, forKey: .changeID)
      try container.encode(taskID, forKey: .taskID)
      try container.encode(mainCommitOID, forKey: .mainCommitOID)
      try container.encode(taskBlobOID, forKey: .taskBlobOID)
      try container.encode(approvalPRNumber, forKey: .approvalPRNumber)
    case .deviceCapability(
      let capabilityID, let mainCommitOID, let capabilityBlobOID, let approvalPRNumber):
      try container.encode(capabilityID, forKey: .capabilityID)
      try container.encode(mainCommitOID, forKey: .mainCommitOID)
      try container.encode(capabilityBlobOID, forKey: .capabilityBlobOID)
      try container.encode(approvalPRNumber, forKey: .approvalPRNumber)
    case .standingAuthorization(
      let authorizationID, let mainCommitOID, let authorizationBlobOID, let approvalPRNumber):
      try container.encode(authorizationID, forKey: .authorizationID)
      try container.encode(mainCommitOID, forKey: .mainCommitOID)
      try container.encode(authorizationBlobOID, forKey: .authorizationBlobOID)
      try container.encode(approvalPRNumber, forKey: .approvalPRNumber)
    case .chatConfirmation(
      let confirmationDigestSHA256, let planDigestSHA256, let archiveDigestSHA256,
      let stepSetDigestSHA256, let targetDigestSHA256, let confirmedAt):
      try container.encode(confirmationDigestSHA256, forKey: .confirmationDigestSHA256)
      try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
      try container.encode(archiveDigestSHA256, forKey: .archiveDigestSHA256)
      try container.encode(stepSetDigestSHA256, forKey: .stepSetDigestSHA256)
      try container.encode(targetDigestSHA256, forKey: .targetDigestSHA256)
      try container.encode(confirmedAt, forKey: .confirmedAt)
    case .evolutionCampaignConfirmation(
      let campaignDigestSHA256, let baseCommitOID, let planDigestSHA256,
      let archiveDigestSHA256, let stepSetDigestSHA256, let targetStableIdentitySHA256,
      let bindingLineageRootRevision, let confirmedAt, let validUntil, let maximumAttempts):
      try container.encode(campaignDigestSHA256, forKey: .campaignDigestSHA256)
      try container.encode(baseCommitOID, forKey: .baseCommitOID)
      try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
      try container.encode(archiveDigestSHA256, forKey: .archiveDigestSHA256)
      try container.encode(stepSetDigestSHA256, forKey: .stepSetDigestSHA256)
      try container.encode(targetStableIdentitySHA256, forKey: .targetStableIdentitySHA256)
      try container.encode(bindingLineageRootRevision, forKey: .bindingLineageRootRevision)
      try container.encode(confirmedAt, forKey: .confirmedAt)
      try container.encode(validUntil, forKey: .validUntil)
      try container.encode(maximumAttempts, forKey: .maximumAttempts)
    }
  }

  public var kind: AgentExecutionAuthorityKind {
    switch self {
    case .readyTask: .readyTask
    case .deviceCapability: .deviceCapability
    case .standingAuthorization: .standingAuthorization
    case .chatConfirmation: .chatConfirmation
    case .evolutionCampaignConfirmation: .evolutionCampaignConfirmation
    }
  }

  public var effect: WorkflowEffect {
    switch self {
    case .readyTask: .readOnly
    case .deviceCapability: .deviceMutation
    case .standingAuthorization: .destructive
    case .chatConfirmation: .destructive
    case .evolutionCampaignConfirmation: .destructive
    }
  }

  public var sourceIdentifier: String {
    switch self {
    case .readyTask(_, let taskID, _, _, _): taskID
    case .deviceCapability(let capabilityID, _, _, _): capabilityID
    case .standingAuthorization(let authorizationID, _, _, _): authorizationID
    case .chatConfirmation(let confirmationDigestSHA256, _, _, _, _, _):
      "CHAT-\(confirmationDigestSHA256.uppercased())"
    case .evolutionCampaignConfirmation(let campaignDigestSHA256, _, _, _, _, _, _, _, _, _):
      "CAMPAIGN-\(campaignDigestSHA256.uppercased())"
    }
  }

  public var legacyStandingAuthorizationReference: AuthorizationReference? {
    guard
      case .standingAuthorization(
        let authorizationID, let mainCommitOID, let authorizationBlobOID, let approvalPRNumber
      ) = self
    else { return nil }
    return try? AuthorizationReference(
      authorizationID: authorizationID, mainCommitOID: mainCommitOID,
      authorizationBlobOID: authorizationBlobOID, approvalPRNumber: approvalPRNumber)
  }

  init(jsonValue: JSONValue, context: String) throws {
    guard case .object(let object) = jsonValue,
      case .string(let rawKind)? = object[CodingKeys.kind.rawValue],
      let kind = AgentExecutionAuthorityKind(rawValue: rawKind)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "\(context) must be a closed agent authorizationRef object")
    }
    func string(_ key: CodingKeys) throws -> String {
      guard case .string(let value)? = object[key.rawValue] else {
        throw AuthorizationUsageLedgerError.invalidRecord("\(context).\(key.rawValue)")
      }
      return value
    }
    func approvalPRNumber() throws -> Int {
      guard
        let value = object[CodingKeys.approvalPRNumber.rawValue]?.authorizationInteger
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "\(context).approvalPRNumber must be integer")
      }
      return value
    }
    switch kind {
    case .readyTask:
      guard
        Set(object.keys) == [
          "kind", "changeId", "taskId", "mainCommitOID", "taskBlobOID", "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("\(context) readyTask shape")
      }
      self = try Self.validatedReadyTask(
        changeID: string(.changeID), taskID: string(.taskID),
        mainCommitOID: string(.mainCommitOID), taskBlobOID: string(.taskBlobOID),
        approvalPRNumber: approvalPRNumber())
    case .deviceCapability:
      guard
        Set(object.keys) == [
          "kind", "capabilityId", "mainCommitOID", "capabilityBlobOID", "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("\(context) deviceCapability shape")
      }
      self = try Self.validatedDeviceCapability(
        capabilityID: string(.capabilityID), mainCommitOID: string(.mainCommitOID),
        capabilityBlobOID: string(.capabilityBlobOID),
        approvalPRNumber: approvalPRNumber())
    case .standingAuthorization:
      guard
        Set(object.keys) == [
          "kind", "authorizationId", "mainCommitOID", "authorizationBlobOID", "approvalPRNumber",
        ]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("\(context) standingAuthorization shape")
      }
      self = try Self.validatedStandingAuthorization(
        authorizationID: string(.authorizationID), mainCommitOID: string(.mainCommitOID),
        authorizationBlobOID: string(.authorizationBlobOID),
        approvalPRNumber: approvalPRNumber())
    case .chatConfirmation:
      guard
        Set(object.keys) == [
          "kind", "confirmationDigestSHA256", "planDigestSHA256", "archiveDigestSHA256",
          "stepSetDigestSHA256", "targetDigestSHA256", "confirmedAt",
        ],
        case .string(let confirmationDigestSHA256)? =
          object[CodingKeys.confirmationDigestSHA256.rawValue],
        case .string(let planDigestSHA256)? = object[CodingKeys.planDigestSHA256.rawValue],
        case .string(let archiveDigestSHA256)? = object[CodingKeys.archiveDigestSHA256.rawValue],
        case .string(let stepSetDigestSHA256)? = object[CodingKeys.stepSetDigestSHA256.rawValue],
        case .string(let targetDigestSHA256)? = object[CodingKeys.targetDigestSHA256.rawValue],
        case .string(let confirmedAt)? = object[CodingKeys.confirmedAt.rawValue]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "\(context) chatConfirmation shape")
      }
      self = try Self.validatedChatConfirmation(
        confirmationDigestSHA256: confirmationDigestSHA256,
        planDigestSHA256: planDigestSHA256,
        archiveDigestSHA256: archiveDigestSHA256,
        stepSetDigestSHA256: stepSetDigestSHA256,
        targetDigestSHA256: targetDigestSHA256,
        confirmedAt: confirmedAt)
    case .evolutionCampaignConfirmation:
      guard
        Set(object.keys) == [
          "kind", "campaignDigestSHA256", "baseCommitOID", "planDigestSHA256",
          "archiveDigestSHA256", "stepSetDigestSHA256", "targetStableIdentitySHA256",
          "bindingLineageRootRevision", "confirmedAt", "validUntil", "maximumAttempts",
        ],
        let bindingLineageRootRevision =
          object[CodingKeys.bindingLineageRootRevision.rawValue]?.authorizationInteger,
        let maximumAttempts = object[CodingKeys.maximumAttempts.rawValue]?.authorizationInteger
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "\(context) evolutionCampaignConfirmation shape")
      }
      self = try Self.validatedEvolutionCampaignConfirmation(
        campaignDigestSHA256: string(.campaignDigestSHA256),
        baseCommitOID: string(.baseCommitOID),
        planDigestSHA256: string(.planDigestSHA256),
        archiveDigestSHA256: string(.archiveDigestSHA256),
        stepSetDigestSHA256: string(.stepSetDigestSHA256),
        targetStableIdentitySHA256: string(.targetStableIdentitySHA256),
        bindingLineageRootRevision: bindingLineageRootRevision,
        confirmedAt: string(.confirmedAt),
        validUntil: string(.validUntil),
        maximumAttempts: maximumAttempts)
    }
  }

  var jsonValue: JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(self))) ?? .null
  }

  private static func validateCommon(
    mainCommitOID: String,
    sourceBlobOID: String,
    approvalPRNumber: Int
  ) throws {
    guard mainCommitOID.agentAuthorityMatches(#"^[a-f0-9]{40}$"#),
      sourceBlobOID.agentAuthorityMatches(#"^[a-f0-9]{40}$"#),
      approvalPRNumber > 0
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "authority OIDs and approvalPRNumber are invalid")
    }
  }
}

private struct AgentAuthorityDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

public struct AuthorizationReference: Codable, Equatable, Hashable, Sendable {
  public let authorizationID: String
  public let mainCommitOID: String
  public let authorizationBlobOID: String
  public let approvalPRNumber: Int

  enum CodingKeys: String, CodingKey {
    case authorizationID = "authorizationId"
    case mainCommitOID
    case authorizationBlobOID
    case approvalPRNumber
  }

  public init(
    authorizationID: String,
    mainCommitOID: String,
    authorizationBlobOID: String,
    approvalPRNumber: Int
  ) throws {
    guard Self.isIdentifier(authorizationID) else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid authorizationId")
    }
    guard Self.isFullLowercaseGitOID(mainCommitOID),
      Self.isFullLowercaseGitOID(authorizationBlobOID)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "authorization OIDs must be full 40-character lowercase hex")
    }
    guard approvalPRNumber > 0 else {
      throw AuthorizationUsageLedgerError.invalidRecord("approvalPRNumber must be positive")
    }
    self.authorizationID = authorizationID
    self.mainCommitOID = mainCommitOID
    self.authorizationBlobOID = authorizationBlobOID
    self.approvalPRNumber = approvalPRNumber
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      authorizationID: container.decode(String.self, forKey: .authorizationID),
      mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
      authorizationBlobOID: container.decode(String.self, forKey: .authorizationBlobOID),
      approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
  }

  init(jsonValue: JSONValue, context: String) throws {
    guard case .object(let object) = jsonValue,
      Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
      case .string(let authorizationID)? = object[CodingKeys.authorizationID.rawValue],
      case .string(let mainCommitOID)? = object[CodingKeys.mainCommitOID.rawValue],
      case .string(let authorizationBlobOID)? = object[CodingKeys.authorizationBlobOID.rawValue],
      let approvalPRNumber = object[CodingKeys.approvalPRNumber.rawValue]?.authorizationInteger
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "\(context) must be a closed authorizationRef object")
    }
    try self.init(
      authorizationID: authorizationID, mainCommitOID: mainCommitOID,
      authorizationBlobOID: authorizationBlobOID, approvalPRNumber: approvalPRNumber)
  }

  var jsonValue: JSONValue {
    .object([
      CodingKeys.authorizationID.rawValue: .string(authorizationID),
      CodingKeys.mainCommitOID.rawValue: .string(mainCommitOID),
      CodingKeys.authorizationBlobOID.rawValue: .string(authorizationBlobOID),
      CodingKeys.approvalPRNumber.rawValue: .integer(Int64(approvalPRNumber)),
    ])
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isFullLowercaseGitOID(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }
}

extension AuthorizationReference.CodingKeys: CaseIterable {}

public enum AuthorizationUsageTerminalStatus: String, Codable, CaseIterable, Sendable {
  case succeeded
  case failed
  case cancelled
  case interrupted
  case outcomeUnknown
}

public struct AuthorizationUsageTerminal: Codable, Equatable, Sendable {
  public let status: AuthorizationUsageTerminalStatus
  public let closedAt: String
  public let destructiveIntentEventIDs: [String]

  enum CodingKeys: String, CodingKey {
    case status
    case closedAt
    case destructiveIntentEventIDs = "destructiveIntentEventIds"
  }

  public init(
    status: AuthorizationUsageTerminalStatus,
    closedAt: String,
    destructiveIntentEventIDs: [String]
  ) throws {
    guard AuthorizationUsageValidation.isTimestamp(closedAt) else {
      throw AuthorizationUsageLedgerError.invalidRecord("terminal.closedAt is not RFC 3339")
    }
    guard Set(destructiveIntentEventIDs).count == destructiveIntentEventIDs.count,
      destructiveIntentEventIDs.allSatisfy(AuthorizationUsageValidation.isIdentifier)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "terminal destructiveIntentEventIds must be unique identifiers")
    }
    self.status = status
    self.closedAt = closedAt
    self.destructiveIntentEventIDs = destructiveIntentEventIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      status: container.decode(AuthorizationUsageTerminalStatus.self, forKey: .status),
      closedAt: container.decode(String.self, forKey: .closedAt),
      destructiveIntentEventIDs: container.decode(
        [String].self, forKey: .destructiveIntentEventIDs))
  }
}

public struct AuthorizationUsageReservation: Codable, Equatable, Sendable {
  public let reservationID: String
  public let authorizationRef: AuthorizationReference
  public let ordinal: Int
  public let maxRuns: Int
  public let jobID: String
  public let planDigestSHA256: String
  public let targetDigestSHA256: String
  public let reservedAt: String
  public let terminal: AuthorizationUsageTerminal?

  enum CodingKeys: String, CodingKey {
    case reservationID = "reservationId"
    case authorizationRef
    case ordinal
    case maxRuns
    case jobID = "jobId"
    case planDigestSHA256
    case targetDigestSHA256
    case reservedAt
    case terminal
  }

  public init(
    reservationID: String,
    authorizationRef: AuthorizationReference,
    ordinal: Int,
    maxRuns: Int,
    jobID: String,
    planDigestSHA256: String,
    targetDigestSHA256: String,
    reservedAt: String,
    terminal: AuthorizationUsageTerminal? = nil
  ) throws {
    guard AuthorizationUsageValidation.isIdentifier(reservationID),
      AuthorizationUsageValidation.isIdentifier(jobID)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid reservationId or jobId")
    }
    guard ordinal > 0, maxRuns >= 0 else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "ordinal must be positive and maxRuns must be nonnegative")
    }
    guard AuthorizationUsageValidation.isSHA256(planDigestSHA256),
      AuthorizationUsageValidation.isSHA256(targetDigestSHA256)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "plan and target digests must be lowercase SHA-256")
    }
    guard AuthorizationUsageValidation.isTimestamp(reservedAt) else {
      throw AuthorizationUsageLedgerError.invalidRecord("reservedAt is not RFC 3339")
    }
    self.reservationID = reservationID
    self.authorizationRef = authorizationRef
    self.ordinal = ordinal
    self.maxRuns = maxRuns
    self.jobID = jobID
    self.planDigestSHA256 = planDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
    self.reservedAt = reservedAt
    self.terminal = terminal
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      reservationID: container.decode(String.self, forKey: .reservationID),
      authorizationRef: container.decode(AuthorizationReference.self, forKey: .authorizationRef),
      ordinal: container.decode(Int.self, forKey: .ordinal),
      maxRuns: container.decode(Int.self, forKey: .maxRuns),
      jobID: container.decode(String.self, forKey: .jobID),
      planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
      targetDigestSHA256: container.decode(String.self, forKey: .targetDigestSHA256),
      reservedAt: container.decode(String.self, forKey: .reservedAt),
      terminal: container.decodeIfPresent(AuthorizationUsageTerminal.self, forKey: .terminal))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reservationID, forKey: .reservationID)
    try container.encode(authorizationRef, forKey: .authorizationRef)
    try container.encode(ordinal, forKey: .ordinal)
    try container.encode(maxRuns, forKey: .maxRuns)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
    try container.encode(targetDigestSHA256, forKey: .targetDigestSHA256)
    try container.encode(reservedAt, forKey: .reservedAt)
    if let terminal {
      try container.encode(terminal, forKey: .terminal)
    } else {
      try container.encodeNil(forKey: .terminal)
    }
  }

  fileprivate func replacingTerminal(_ terminal: AuthorizationUsageTerminal) throws
    -> AuthorizationUsageReservation
  {
    try AuthorizationUsageReservation(
      reservationID: reservationID, authorizationRef: authorizationRef, ordinal: ordinal,
      maxRuns: maxRuns, jobID: jobID, planDigestSHA256: planDigestSHA256,
      targetDigestSHA256: targetDigestSHA256, reservedAt: reservedAt, terminal: terminal)
  }
}

public struct AuthorizationUsageLedgerDocument: Codable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"

  public let schemaVersion: String
  public let reservations: [AuthorizationUsageReservation]

  public init(reservations: [AuthorizationUsageReservation]) throws {
    schemaVersion = Self.schemaVersion
    self.reservations = reservations
    try AuthorizationUsageValidation.validateDocument(self)
  }
}

public enum AuthorizationUsageLedgerError: Error, Equatable, Sendable {
  case invalidRecord(String)
  case reservationConflict(String)
  case usageLimitExceeded(authorizationID: String, maxRuns: Int)
  case reservationNotFound(String)
  case unsafePath(String)
}

public enum AuthorizationUsageLedgerFaultPoint: String, CaseIterable, Sendable {
  case beforeTemporaryWrite
  case afterFileSync
  case afterReplace
  case beforeDirectorySync
}

public struct AuthorizationUsageLedgerFaultInjector: @unchecked Sendable {
  private let body: (AuthorizationUsageLedgerFaultPoint) throws -> Void

  public init(_ body: @escaping (AuthorizationUsageLedgerFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: AuthorizationUsageLedgerFaultPoint) throws { try body(point) }

  public static let none = AuthorizationUsageLedgerFaultInjector { _ in }
}

/// A host-wide, durable consume-on-reserve ledger. This type validates shape and correlation only;
/// it does not prove Git provenance or grant device-dispatch authority.
public final class AuthorizationUsageLedger: @unchecked Sendable {
  public static let ledgerFileName = "authorization-usage.json"
  public static let lockFileName = ".authorization-usage.lock"
  public static let maximumBytes = 16 * 1_024 * 1_024

  public let root: URL
  private let faultInjector: AuthorizationUsageLedgerFaultInjector

  public init(
    root: URL,
    faultInjector: AuthorizationUsageLedgerFaultInjector = .none
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(root)
    self.root = root.standardizedFileURL
    self.faultInjector = faultInjector
    try DurableFilePrimitives.rejectSymbolicLink(self.root)
    try FileManager.default.createDirectory(
      at: self.root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try withLockedRoot { _ in () }
  }

  @discardableResult
  public func reserve(_ request: AuthorizationUsageReservation) throws
    -> AuthorizationUsageReservation
  {
    guard request.terminal == nil else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "reserve request must not carry terminal state")
    }
    return try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      if let existing = document.reservations.first(where: {
        $0.reservationID == request.reservationID
      }) {
        guard existing == request else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "reservation retry fields drifted: \(request.reservationID)")
        }
        return existing
      }
      let sameAuthorization = document.reservations.filter {
        $0.authorizationRef.authorizationID == request.authorizationRef.authorizationID
      }
      guard
        sameAuthorization.allSatisfy({
          $0.authorizationRef == request.authorizationRef && $0.maxRuns == request.maxRuns
        })
      else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "authorizationRef or maxRuns drifted")
      }
      let expectedOrdinal = (sameAuthorization.map(\.ordinal).max() ?? 0) + 1
      guard request.ordinal == expectedOrdinal else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "ordinal must be the next monotonic value \(expectedOrdinal)")
      }
      if request.maxRuns > 0, request.ordinal > request.maxRuns {
        throw AuthorizationUsageLedgerError.usageLimitExceeded(
          authorizationID: request.authorizationRef.authorizationID,
          maxRuns: request.maxRuns)
      }
      document = try AuthorizationUsageLedgerDocument(
        reservations: document.reservations + [request])
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return request
    }
  }

  @discardableResult
  public func close(
    reservationID: String,
    terminal: AuthorizationUsageTerminal
  ) throws -> AuthorizationUsageReservation {
    try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      guard
        let index = document.reservations.firstIndex(where: {
          $0.reservationID == reservationID
        })
      else {
        throw AuthorizationUsageLedgerError.reservationNotFound(reservationID)
      }
      let existing = document.reservations[index]
      if let existingTerminal = existing.terminal {
        guard existingTerminal == terminal else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "terminal retry fields drifted: \(reservationID)")
        }
        return existing
      }
      let closed = try existing.replacingTerminal(terminal)
      var reservations = document.reservations
      reservations[index] = closed
      document = try AuthorizationUsageLedgerDocument(reservations: reservations)
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return closed
    }
  }

  public func load() throws -> AuthorizationUsageLedgerDocument {
    try withLockedRoot { try loadLocked(rootDescriptor: $0) }
  }

  private func withLockedRoot<T>(_ body: (Int32) throws -> T) throws -> T {
    let rootDescriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open ledger root")
    }
    defer { Darwin.close(rootDescriptor) }
    try validateRootBinding(rootDescriptor)

    var prior = stat()
    let lockWasAbsent =
      fstatat(rootDescriptor, Self.lockFileName, &prior, AT_SYMLINK_NOFOLLOW) != 0
      && errno == ENOENT
    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open usage lock")
    }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnerSafeRegularFile(lockDescriptor, context: "usage lock")
    if lockWasAbsent {
      try DurableFilePrimitives.fullSync(
        lockDescriptor, path: root.appending(path: Self.lockFileName).path)
      try DurableFilePrimitives.syncDirectory(root)
    }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw AuthorizationUsageLedgerError.unsafePath("cannot acquire usage lock")
    }
    defer { flock(lockDescriptor, LOCK_UN) }
    try validatePathBinding(
      descriptor: lockDescriptor, rootDescriptor: rootDescriptor,
      name: Self.lockFileName, context: "usage lock")
    try validateRootBinding(rootDescriptor)
    let result = try body(rootDescriptor)
    try validateRootBinding(rootDescriptor)
    return result
  }

  private func loadLocked(rootDescriptor: Int32) throws -> AuthorizationUsageLedgerDocument {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.ledgerFileName,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath("cannot open usage ledger")
      }
      return try AuthorizationUsageLedgerDocument(reservations: [])
    }
    defer { Darwin.close(descriptor) }
    try validateOwnerSafeRegularFile(descriptor, context: "usage ledger")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger size is invalid")
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "usage ledger")
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw AuthorizationUsageLedgerError.invalidRecord("usage ledger read failed")
      }
      offset += count
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "usage ledger")
    return try AuthorizationUsageValidation.decode(data)
  }

  private func persistLocked(
    _ document: AuthorizationUsageLedgerDocument,
    rootDescriptor: Int32
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger exceeds size limit")
    }
    let temporaryName = ".authorization-usage.\(UUID().uuidString).tmp"
    let temporaryURL = root.appending(path: temporaryName)
    let descriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot create usage temporary file")
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
    }
    try validateOwnerSafeRegularFile(descriptor, context: "usage temporary file")
    try faultInjector.check(.beforeTemporaryWrite)
    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporaryURL.path)
    try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
    try faultInjector.check(.afterFileSync)
    var temporaryMetadata = stat()
    guard fstat(descriptor, &temporaryMetadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot inspect usage temporary file")
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptorIsOpen = false
      throw AuthorizationUsageLedgerError.unsafePath("cannot close usage temporary file")
    }
    descriptorIsOpen = false
    try validateExistingLedgerPath(rootDescriptor)
    guard renameat(rootDescriptor, temporaryName, rootDescriptor, Self.ledgerFileName) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot atomically replace usage ledger")
    }
    try validatePathBinding(
      metadata: temporaryMetadata, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "replaced usage ledger")
    try faultInjector.check(.afterReplace)
    try faultInjector.check(.beforeDirectorySync)
    try DurableFilePrimitives.syncDirectory(root)
  }

  private func validateExistingLedgerPath(_ rootDescriptor: Int32) throws {
    var metadata = stat()
    if fstatat(
      rootDescriptor, Self.ledgerFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0
    {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath("usage ledger path inspection failed")
      }
      return
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_nlink == 1, metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath("unsafe usage ledger replacement target")
    }
  }

  private func validateRootBinding(_ descriptor: Int32) throws {
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      lstat(root.path, &pathMetadata) == 0,
      descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
      descriptorMetadata.st_uid == geteuid(),
      descriptorMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath("ledger root path changed or is unsafe")
    }
  }

  private func validateOwnerSafeRegularFile(_ descriptor: Int32, context: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath("unsafe \(context)")
    }
  }

  private func validatePathBinding(
    descriptor: Int32,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot inspect \(context)")
    }
    try validatePathBinding(
      metadata: metadata, rootDescriptor: rootDescriptor, name: name, context: context)
  }

  private func validatePathBinding(
    metadata: stat,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var pathMetadata = stat()
    guard fstatat(rootDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_dev == pathMetadata.st_dev, metadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath("\(context) path changed")
    }
  }
}

public struct AgentAuthorityUsageTerminal: Codable, Equatable, Sendable {
  public let status: AuthorizationUsageTerminalStatus
  public let closedAt: String
  public let externalIntentEventIDs: [String]

  enum CodingKeys: String, CodingKey, CaseIterable {
    case status
    case closedAt
    case externalIntentEventIDs = "externalIntentEventIds"
  }

  public init(
    status: AuthorizationUsageTerminalStatus,
    closedAt: String,
    externalIntentEventIDs: [String]
  ) throws {
    guard AuthorizationUsageValidation.isTimestamp(closedAt),
      Set(externalIntentEventIDs).count == externalIntentEventIDs.count,
      externalIntentEventIDs.allSatisfy(AuthorizationUsageValidation.isIdentifier)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid Agent authority terminal")
    }
    self.status = status
    self.closedAt = closedAt
    self.externalIntentEventIDs = externalIntentEventIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      status: container.decode(AuthorizationUsageTerminalStatus.self, forKey: .status),
      closedAt: container.decode(String.self, forKey: .closedAt),
      externalIntentEventIDs: container.decode([String].self, forKey: .externalIntentEventIDs))
  }
}

public struct AgentAuthorityUsageReservation: Codable, Equatable, Sendable {
  public let reservationID: String
  public let authorizationRef: AgentExecutionAuthorityReference
  public let ordinal: Int
  public let maximumUses: Int
  public let maximumConcurrentJobs: Int
  public let jobID: String
  public let operationDigestSHA256: String
  public let targetDigestSHA256: String
  public let reservedAt: String
  public let forwardLeaseExpiresAt: String
  public let compensationLeaseExpiresAt: String
  public let terminal: AgentAuthorityUsageTerminal?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case reservationID = "reservationId"
    case authorizationRef
    case ordinal
    case maximumUses
    case maximumConcurrentJobs
    case jobID = "jobId"
    case operationDigestSHA256
    case targetDigestSHA256
    case reservedAt
    case forwardLeaseExpiresAt
    case compensationLeaseExpiresAt
    case terminal
  }

  public static func canonicalReservationID(
    authorizationRef: AgentExecutionAuthorityReference,
    jobID: String,
    operationDigestSHA256: String,
    targetDigestSHA256: String
  ) throws -> String {
    guard AuthorizationUsageValidation.isIdentifier(jobID),
      AuthorizationUsageValidation.isSHA256(operationDigestSHA256),
      AuthorizationUsageValidation.isSHA256(targetDigestSHA256)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "agent authority reservation requires canonical digests")
    }
    let identity: [String]
    let identifierPrefix: String
    switch authorizationRef {
    case .deviceCapability(
      let capabilityID, let mainCommitOID, let capabilityBlobOID, let approvalPRNumber):
      identity = [
        "deviceCapability", capabilityID, mainCommitOID, capabilityBlobOID,
        String(approvalPRNumber),
      ]
      identifierPrefix = "ain010"
    case .chatConfirmation(
      let confirmationDigestSHA256, let planDigestSHA256, let archiveDigestSHA256,
      let stepSetDigestSHA256, let targetDigestSHA256, let confirmedAt):
      identity = [
        "chatConfirmation", confirmationDigestSHA256, planDigestSHA256,
        archiveDigestSHA256, stepSetDigestSHA256, targetDigestSHA256, confirmedAt,
      ]
      identifierPrefix = "ain018"
    case .evolutionCampaignConfirmation(
      let campaignDigestSHA256, let baseCommitOID, let planDigestSHA256,
      let archiveDigestSHA256, let stepSetDigestSHA256, let targetStableIdentitySHA256,
      let bindingLineageRootRevision, let confirmedAt, let validUntil, let maximumAttempts):
      identity = [
        "evolutionCampaignConfirmation", campaignDigestSHA256, baseCommitOID,
        planDigestSHA256, archiveDigestSHA256, stepSetDigestSHA256,
        targetStableIdentitySHA256, String(bindingLineageRootRevision), confirmedAt,
        validUntil, String(maximumAttempts),
      ]
      identifierPrefix = "ain019"
    case .readyTask, .standingAuthorization:
      throw AuthorizationUsageLedgerError.invalidRecord(
        "authority kind does not use the agent authority ledger")
    }
    let input = (identity + [jobID, operationDigestSHA256, targetDigestSHA256])
      .joined(separator: "|")
    let digest = SHA256.hash(data: Data(input.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\(identifierPrefix)-\(digest.prefix(32))"
  }

  public init(
    reservationID: String,
    authorizationRef: AgentExecutionAuthorityReference,
    ordinal: Int,
    maximumUses: Int,
    maximumConcurrentJobs: Int = 1,
    jobID: String,
    operationDigestSHA256: String,
    targetDigestSHA256: String,
    reservedAt: String,
    forwardLeaseExpiresAt: String,
    compensationLeaseExpiresAt: String,
    terminal: AgentAuthorityUsageTerminal? = nil
  ) throws {
    let canonicalReservationID = try? Self.canonicalReservationID(
      authorizationRef: authorizationRef, jobID: jobID,
      operationDigestSHA256: operationDigestSHA256,
      targetDigestSHA256: targetDigestSHA256)
    let validLimits: Bool
    switch authorizationRef.kind {
    case .deviceCapability:
      validLimits = (1...32).contains(maximumUses) && maximumConcurrentJobs == 1
    case .chatConfirmation:
      validLimits = maximumUses == 1 && maximumConcurrentJobs == 1
    case .evolutionCampaignConfirmation:
      validLimits = (1...8).contains(maximumUses) && maximumConcurrentJobs == 1
    case .readyTask, .standingAuthorization:
      validLimits = false
    }
    guard validLimits,
      AuthorizationUsageValidation.isIdentifier(reservationID),
      reservationID == canonicalReservationID,
      AuthorizationUsageValidation.isIdentifier(jobID),
      ordinal > 0,
      AuthorizationUsageValidation.isSHA256(operationDigestSHA256),
      AuthorizationUsageValidation.isSHA256(targetDigestSHA256),
      AuthorizationUsageValidation.isTimestamp(reservedAt),
      AuthorizationUsageValidation.isTimestamp(forwardLeaseExpiresAt),
      AuthorizationUsageValidation.isTimestamp(compensationLeaseExpiresAt),
      let reservedDate = AuthorizationUsageValidation.date(reservedAt),
      let forwardDate = AuthorizationUsageValidation.date(forwardLeaseExpiresAt),
      let compensationDate = AuthorizationUsageValidation.date(compensationLeaseExpiresAt),
      reservedDate < forwardDate, forwardDate <= compensationDate
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid Agent authority reservation")
    }
    self.reservationID = reservationID
    self.authorizationRef = authorizationRef
    self.ordinal = ordinal
    self.maximumUses = maximumUses
    self.maximumConcurrentJobs = maximumConcurrentJobs
    self.jobID = jobID
    self.operationDigestSHA256 = operationDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
    self.reservedAt = reservedAt
    self.forwardLeaseExpiresAt = forwardLeaseExpiresAt
    self.compensationLeaseExpiresAt = compensationLeaseExpiresAt
    self.terminal = terminal
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      reservationID: container.decode(String.self, forKey: .reservationID),
      authorizationRef: container.decode(
        AgentExecutionAuthorityReference.self, forKey: .authorizationRef),
      ordinal: container.decode(Int.self, forKey: .ordinal),
      maximumUses: container.decode(Int.self, forKey: .maximumUses),
      maximumConcurrentJobs: container.decode(Int.self, forKey: .maximumConcurrentJobs),
      jobID: container.decode(String.self, forKey: .jobID),
      operationDigestSHA256: container.decode(String.self, forKey: .operationDigestSHA256),
      targetDigestSHA256: container.decode(String.self, forKey: .targetDigestSHA256),
      reservedAt: container.decode(String.self, forKey: .reservedAt),
      forwardLeaseExpiresAt: container.decode(String.self, forKey: .forwardLeaseExpiresAt),
      compensationLeaseExpiresAt: container.decode(
        String.self, forKey: .compensationLeaseExpiresAt),
      terminal: container.decodeIfPresent(AgentAuthorityUsageTerminal.self, forKey: .terminal))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reservationID, forKey: .reservationID)
    try container.encode(authorizationRef, forKey: .authorizationRef)
    try container.encode(ordinal, forKey: .ordinal)
    try container.encode(maximumUses, forKey: .maximumUses)
    try container.encode(maximumConcurrentJobs, forKey: .maximumConcurrentJobs)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(operationDigestSHA256, forKey: .operationDigestSHA256)
    try container.encode(targetDigestSHA256, forKey: .targetDigestSHA256)
    try container.encode(reservedAt, forKey: .reservedAt)
    try container.encode(forwardLeaseExpiresAt, forKey: .forwardLeaseExpiresAt)
    try container.encode(compensationLeaseExpiresAt, forKey: .compensationLeaseExpiresAt)
    if let terminal {
      try container.encode(terminal, forKey: .terminal)
    } else {
      try container.encodeNil(forKey: .terminal)
    }
  }

  fileprivate func replacingTerminal(_ terminal: AgentAuthorityUsageTerminal) throws
    -> AgentAuthorityUsageReservation
  {
    try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: authorizationRef, ordinal: ordinal,
      maximumUses: maximumUses, maximumConcurrentJobs: maximumConcurrentJobs, jobID: jobID,
      operationDigestSHA256: operationDigestSHA256, targetDigestSHA256: targetDigestSHA256,
      reservedAt: reservedAt, forwardLeaseExpiresAt: forwardLeaseExpiresAt,
      compensationLeaseExpiresAt: compensationLeaseExpiresAt, terminal: terminal)
  }
}

public struct AgentAuthorityUsageLedgerDocument: Codable, Equatable, Sendable {
  public static let documentType = "agentAuthorityUsage"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  public let reservations: [AgentAuthorityUsageReservation]

  public init(reservations: [AgentAuthorityUsageReservation]) throws {
    documentType = Self.documentType
    schemaVersion = Self.schemaVersion
    self.reservations = reservations
    try AgentAuthorityUsageValidation.validateDocument(self)
  }
}

/// Independent consume-on-reserve ledger for E1 capabilities and one-shot chat-confirmed E2
/// authorities. The legacy E2 ledger above remains the standing-authorization usage store.
public final class AgentAuthorityUsageLedger: @unchecked Sendable {
  public static let ledgerFileName = "agent-authority-usage.json"
  public static let lockFileName = ".agent-authority-usage.lock"
  public static let maximumBytes = 16 * 1_024 * 1_024

  public let root: URL
  private let faultInjector: AuthorizationUsageLedgerFaultInjector

  public init(
    root: URL,
    faultInjector: AuthorizationUsageLedgerFaultInjector = .none
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(root)
    self.root = root.standardizedFileURL
    self.faultInjector = faultInjector
    try DurableFilePrimitives.rejectSymbolicLink(self.root)
    try FileManager.default.createDirectory(
      at: self.root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try withLockedRoot { _ in () }
  }

  @discardableResult
  public func reserve(_ request: AgentAuthorityUsageReservation) throws
    -> AgentAuthorityUsageReservation
  {
    guard request.terminal == nil else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority reserve request must not carry terminal")
    }
    return try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      if let existing = document.reservations.first(where: {
        $0.reservationID == request.reservationID
      }) {
        guard request.authorizationRef.kind != .chatConfirmation else {
          throw AuthorizationUsageLedgerError.usageLimitExceeded(
            authorizationID: request.authorizationRef.sourceIdentifier,
            maxRuns: request.maximumUses)
        }
        guard existing == request else {
          throw AuthorizationUsageLedgerError.reservationConflict(
          "Agent authority reservation retry fields drifted")
        }
        return existing
      }
      let sameAuthority = document.reservations.filter {
        $0.authorizationRef.sourceIdentifier == request.authorizationRef.sourceIdentifier
      }
      guard
        sameAuthority.allSatisfy({
          $0.authorizationRef == request.authorizationRef
            && $0.maximumUses == request.maximumUses
            && $0.maximumConcurrentJobs == request.maximumConcurrentJobs
        })
      else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "Agent authority identity or limits drifted")
      }
      let expectedOrdinal = (sameAuthority.map(\.ordinal).max() ?? 0) + 1
      guard request.ordinal == expectedOrdinal else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "Agent authority ordinal must be \(expectedOrdinal)")
      }
      guard request.ordinal <= request.maximumUses else {
        throw AuthorizationUsageLedgerError.usageLimitExceeded(
          authorizationID: request.authorizationRef.sourceIdentifier,
          maxRuns: request.maximumUses)
      }
      let activeForTarget = document.reservations.filter {
        $0.targetDigestSHA256 == request.targetDigestSHA256 && $0.terminal == nil
      }
      guard activeForTarget.isEmpty else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "Agent authority target already has an active reservation")
      }
      document = try AgentAuthorityUsageLedgerDocument(
        reservations: document.reservations + [request])
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return request
    }
  }

  @discardableResult
  public func close(
    reservationID: String,
    terminal: AgentAuthorityUsageTerminal
  ) throws -> AgentAuthorityUsageReservation {
    try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      guard
        let index = document.reservations.firstIndex(where: {
          $0.reservationID == reservationID
        })
      else {
        throw AuthorizationUsageLedgerError.reservationNotFound(reservationID)
      }
      let existing = document.reservations[index]
      if let current = existing.terminal {
        guard current == terminal else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "Agent authority terminal retry fields drifted")
        }
        return existing
      }
      let closed = try existing.replacingTerminal(terminal)
      var reservations = document.reservations
      reservations[index] = closed
      document = try AgentAuthorityUsageLedgerDocument(reservations: reservations)
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return closed
    }
  }

  public func load() throws -> AgentAuthorityUsageLedgerDocument {
    try withLockedRoot { try loadLocked(rootDescriptor: $0) }
  }

  private func withLockedRoot<T>(_ body: (Int32) throws -> T) throws -> T {
    let rootDescriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open Agent authority ledger root")
    }
    defer { Darwin.close(rootDescriptor) }
    try validateRootBinding(rootDescriptor)
    var prior = stat()
    let lockWasAbsent =
      fstatat(rootDescriptor, Self.lockFileName, &prior, AT_SYMLINK_NOFOLLOW) != 0
      && errno == ENOENT
    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open Agent authority usage lock")
    }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnerSafeRegularFile(lockDescriptor, context: "Agent authority usage lock")
    if lockWasAbsent {
      try DurableFilePrimitives.fullSync(
        lockDescriptor, path: root.appending(path: Self.lockFileName).path)
      try DurableFilePrimitives.syncDirectory(root)
    }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw AuthorizationUsageLedgerError.unsafePath("cannot acquire Agent authority usage lock")
    }
    defer { flock(lockDescriptor, LOCK_UN) }
    try validatePathBinding(
      descriptor: lockDescriptor, rootDescriptor: rootDescriptor,
      name: Self.lockFileName, context: "Agent authority usage lock")
    try validateRootBinding(rootDescriptor)
    let result = try body(rootDescriptor)
    try validateRootBinding(rootDescriptor)
    return result
  }

  private func loadLocked(rootDescriptor: Int32) throws -> AgentAuthorityUsageLedgerDocument {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.ledgerFileName,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath("cannot open Agent authority usage ledger")
      }
      return try AgentAuthorityUsageLedgerDocument(reservations: [])
    }
    defer { Darwin.close(descriptor) }
    try validateOwnerSafeRegularFile(descriptor, context: "Agent authority usage ledger")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority usage ledger size is invalid")
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "Agent authority usage ledger")
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "Agent authority usage ledger read failed")
      }
      offset += count
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "Agent authority usage ledger")
    return try AgentAuthorityUsageValidation.decode(data)
  }

  private func persistLocked(
    _ document: AgentAuthorityUsageLedgerDocument,
    rootDescriptor: Int32
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority usage ledger exceeds size limit")
    }
    let temporaryName = ".agent-authority-usage.\(UUID().uuidString).tmp"
    let temporaryURL = root.appending(path: temporaryName)
    let descriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath(
        "cannot create Agent authority usage temporary file")
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
    }
    try validateOwnerSafeRegularFile(
      descriptor, context: "Agent authority usage temporary file")
    try faultInjector.check(.beforeTemporaryWrite)
    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporaryURL.path)
    try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
    try faultInjector.check(.afterFileSync)
    var temporaryMetadata = stat()
    guard fstat(descriptor, &temporaryMetadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath(
        "cannot inspect Agent authority usage temporary file")
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptorIsOpen = false
      throw AuthorizationUsageLedgerError.unsafePath(
        "cannot close Agent authority usage temporary file")
    }
    descriptorIsOpen = false
    try validateExistingLedgerPath(rootDescriptor)
    guard renameat(rootDescriptor, temporaryName, rootDescriptor, Self.ledgerFileName) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath(
        "cannot atomically replace Agent authority usage ledger")
    }
    try validatePathBinding(
      metadata: temporaryMetadata, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "replaced Agent authority usage ledger")
    try faultInjector.check(.afterReplace)
    try faultInjector.check(.beforeDirectorySync)
    try DurableFilePrimitives.syncDirectory(root)
  }

  private func validateExistingLedgerPath(_ rootDescriptor: Int32) throws {
    var metadata = stat()
    if fstatat(rootDescriptor, Self.ledgerFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath(
          "Agent authority usage ledger path inspection failed")
      }
      return
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_nlink == 1, metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath(
        "unsafe Agent authority usage ledger replacement target")
    }
  }

  private func validateRootBinding(_ descriptor: Int32) throws {
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      lstat(root.path, &pathMetadata) == 0,
      descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
      descriptorMetadata.st_uid == geteuid(),
      descriptorMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath(
        "Agent authority ledger root path changed or is unsafe")
    }
  }

  private func validateOwnerSafeRegularFile(_ descriptor: Int32, context: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath("unsafe \(context)")
    }
  }

  private func validatePathBinding(
    descriptor: Int32,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot inspect \(context)")
    }
    try validatePathBinding(
      metadata: metadata, rootDescriptor: rootDescriptor, name: name, context: context)
  }

  private func validatePathBinding(
    metadata: stat,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var pathMetadata = stat()
    guard fstatat(rootDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_dev == pathMetadata.st_dev, metadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath("\(context) path changed")
    }
  }
}

private enum AgentAuthorityUsageValidation {
  static func validateDocument(_ document: AgentAuthorityUsageLedgerDocument) throws {
    guard document.documentType == AgentAuthorityUsageLedgerDocument.documentType,
      document.schemaVersion == AgentAuthorityUsageLedgerDocument.schemaVersion
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "unsupported Agent authority usage document")
    }
    var reservationIDs = Set<String>()
    var ordinals: [String: Set<Int>] = [:]
    var identities: [String: (AgentExecutionAuthorityReference, Int)] = [:]
    var activeTargets = Set<String>()
    for reservation in document.reservations {
      guard reservationIDs.insert(reservation.reservationID).inserted else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "duplicate Agent authority reservationId")
      }
      let authorityID = reservation.authorizationRef.sourceIdentifier
      if let identity = identities[authorityID] {
        guard identity.0 == reservation.authorizationRef,
          identity.1 == reservation.maximumUses
        else {
          throw AuthorizationUsageLedgerError.invalidRecord(
            "Agent authority identity or limit drift")
        }
      } else {
        identities[authorityID] = (reservation.authorizationRef, reservation.maximumUses)
      }
      var seen = ordinals[authorityID, default: []]
      guard seen.insert(reservation.ordinal).inserted,
        reservation.ordinal <= reservation.maximumUses
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "invalid Agent authority ordinal")
      }
      ordinals[authorityID] = seen
      if reservation.terminal == nil,
        !activeTargets.insert(reservation.targetDigestSHA256).inserted
      {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "multiple active Agent authority reservations for one target")
      }
    }
    for seen in ordinals.values {
      let maximum = seen.max() ?? 0
      guard seen == Set(1...maximum) else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "Agent authority ordinals are not contiguous")
      }
    }
  }

  static func decode(_ data: Data) throws -> AgentAuthorityUsageLedgerDocument {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    do { try duplicateValidator.validate() } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("duplicate JSON member")
    }
    let root: JSONValue
    do { root = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority usage ledger is not valid JSON")
    }
    try validateClosedShape(root)
    let document: AgentAuthorityUsageLedgerDocument
    do {
      document = try JSONDecoder().decode(AgentAuthorityUsageLedgerDocument.self, from: data)
    } catch {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority usage fields are invalid")
    }
    try validateDocument(document)
    return document
  }

  static func validateClosedShape(_ root: JSONValue) throws {
    guard case .object(let object) = root,
      Set(object.keys) == ["documentType", "schemaVersion", "reservations"],
      object["documentType"] == .string(AgentAuthorityUsageLedgerDocument.documentType),
      object["schemaVersion"] == .string(AgentAuthorityUsageLedgerDocument.schemaVersion),
      case .array(let reservations)? = object["reservations"]
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "Agent authority usage root shape is invalid")
    }
    let reservationKeys = Set(AgentAuthorityUsageReservation.CodingKeys.allCases.map(\.rawValue))
    let terminalKeys = Set(AgentAuthorityUsageTerminal.CodingKeys.allCases.map(\.rawValue))
    for value in reservations {
      guard case .object(let reservation) = value,
        Set(reservation.keys) == reservationKeys,
        let authority = reservation["authorizationRef"]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "Agent authority reservation shape is not closed")
      }
      let reference = try AgentExecutionAuthorityReference(
        jsonValue: authority, context: "reservation.authorizationRef")
      guard reference.kind == .deviceCapability || reference.kind == .chatConfirmation
        || reference.kind == .evolutionCampaignConfirmation
      else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "Agent authority usage requires deviceCapability, chatConfirmation or "
            + "evolutionCampaignConfirmation")
      }
      if case .object(let terminal)? = reservation["terminal"] {
        guard Set(terminal.keys) == terminalKeys else {
          throw AuthorizationUsageLedgerError.invalidRecord(
            "Agent authority terminal shape is not closed")
        }
      } else if reservation["terminal"] != .null {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "Agent authority terminal must be object or null")
      }
    }
  }
}

private enum AuthorizationUsageValidation {
  static func validateDocument(_ document: AuthorizationUsageLedgerDocument) throws {
    guard document.schemaVersion == AuthorizationUsageLedgerDocument.schemaVersion else {
      throw AuthorizationUsageLedgerError.invalidRecord("unsupported usage schemaVersion")
    }
    var reservationIDs = Set<String>()
    var ordinals: [String: Set<Int>] = [:]
    var maximumOrdinal: [String: Int] = [:]
    var identities: [String: (AuthorizationReference, Int)] = [:]
    for reservation in document.reservations {
      guard reservationIDs.insert(reservation.reservationID).inserted else {
        throw AuthorizationUsageLedgerError.invalidRecord("duplicate reservationId")
      }
      let authorizationID = reservation.authorizationRef.authorizationID
      if let identity = identities[authorizationID] {
        guard identity.0 == reservation.authorizationRef, identity.1 == reservation.maxRuns else {
          throw AuthorizationUsageLedgerError.invalidRecord(
            "authorizationRef or maxRuns drift within ledger")
        }
      } else {
        identities[authorizationID] = (reservation.authorizationRef, reservation.maxRuns)
      }
      var seen = ordinals[authorizationID, default: []]
      guard seen.insert(reservation.ordinal).inserted else {
        throw AuthorizationUsageLedgerError.invalidRecord("duplicate authorization ordinal")
      }
      ordinals[authorizationID] = seen
      maximumOrdinal[authorizationID] = max(
        maximumOrdinal[authorizationID] ?? 0, reservation.ordinal)
      if reservation.maxRuns > 0, reservation.ordinal > reservation.maxRuns {
        throw AuthorizationUsageLedgerError.invalidRecord("reservation exceeds maxRuns")
      }
    }
    for (authorizationID, seen) in ordinals {
      let maximum = maximumOrdinal[authorizationID] ?? 0
      guard seen == Set(1...maximum) else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "authorization ordinals are not monotonic and contiguous")
      }
    }
  }

  static func decode(_ data: Data) throws -> AuthorizationUsageLedgerDocument {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    do { try duplicateValidator.validate() } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("duplicate JSON member")
    }
    let root: JSONValue
    do { root = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger is not valid JSON")
    }
    try validateClosedShape(root)
    let document: AuthorizationUsageLedgerDocument
    do {
      document = try JSONDecoder().decode(AuthorizationUsageLedgerDocument.self, from: data)
    } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger fields are invalid")
    }
    try validateDocument(document)
    return document
  }

  static func validateClosedShape(_ root: JSONValue) throws {
    guard case .object(let object) = root,
      Set(object.keys) == ["schemaVersion", "reservations"],
      object["schemaVersion"] == .string(AuthorizationUsageLedgerDocument.schemaVersion),
      case .array(let reservations)? = object["reservations"]
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger root shape is invalid")
    }
    let reservationKeys = Set(
      AuthorizationUsageReservation.CodingKeys.allCases.map(\.rawValue))
    let terminalKeys = Set(AuthorizationUsageTerminal.CodingKeys.allCases.map(\.rawValue))
    for value in reservations {
      guard case .object(let reservation) = value,
        Set(reservation.keys) == reservationKeys,
        let authorizationValue = reservation["authorizationRef"]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("reservation shape is not closed")
      }
      _ = try AuthorizationReference(
        jsonValue: authorizationValue, context: "reservation.authorizationRef")
      if case .object(let terminal)? = reservation["terminal"] {
        guard Set(terminal.keys) == terminalKeys else {
          throw AuthorizationUsageLedgerError.invalidRecord("terminal shape is not closed")
        }
      } else if reservation["terminal"] != .null {
        throw AuthorizationUsageLedgerError.invalidRecord("terminal must be object or null")
      }
    }
  }

  static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func isTimestamp(_ value: String) -> Bool {
    date(value) != nil
  }

  static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}

extension AuthorizationUsageReservation.CodingKeys: CaseIterable {}
extension AuthorizationUsageTerminal.CodingKeys: CaseIterable {}

extension JSONValue {
  fileprivate var authorizationInteger: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .unsignedInteger(let value): Int(exactly: value)
    default: nil
    }
  }
}

extension String {
  fileprivate func agentAuthorityMatches(_ pattern: String) -> Bool {
    range(of: pattern, options: .regularExpression) == startIndex..<endIndex
  }
}
