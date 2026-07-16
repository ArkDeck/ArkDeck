import ArkDeckCore
import Foundation

public struct RecoveryManifestHazard: Codable, Equatable, Sendable {
  public let code: String
  public let summary: String
  public let severity: String
  public let outcomeCertainty: String

  public init(code: String, summary: String, severity: String, outcomeCertainty: String) throws {
    guard code.matchesManifestID, !summary.isEmpty,
      ["warning", "blocking", "possibleBrick"].contains(severity),
      ["confirmed", "outcomeUnknown"].contains(outcomeCertainty)
    else { throw RecoveryManifestContractError.invalidField("hazard") }
    self.code = code
    self.summary = summary
    self.severity = severity
    self.outcomeCertainty = outcomeCertainty
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case code, summary, severity, outcomeCertainty
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
    try self.init(
      code: container.decode(String.self, forKey: .code),
      summary: container.decode(String.self, forKey: .summary),
      severity: container.decode(String.self, forKey: .severity),
      outcomeCertainty: container.decode(String.self, forKey: .outcomeCertainty))
  }
}

public enum RecoveryManifestDeviceMode: Codable, Equatable, Sendable {
  case unknown
  case known(value: String, evidence: String)

  private enum CodingKeys: String, CodingKey, CaseIterable { case state, value, evidence }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let dynamic = try decoder.container(keyedBy: RecoveryManifestAnyCodingKey.self)
    let actualKeys = Set(dynamic.allKeys.map(\.stringValue))
    let state = try container.decode(String.self, forKey: .state)
    switch state {
    case "unknown":
      guard actualKeys == ["state"] else {
        throw RecoveryManifestContractError.unknownOrMissingFields
      }
      self = .unknown
    case "known":
      guard actualKeys == Set(CodingKeys.allCases.map(\.stringValue)),
        let value = try? container.decode(String.self, forKey: .value), !value.isEmpty,
        let evidence = try? container.decode(String.self, forKey: .evidence), !evidence.isEmpty
      else { throw RecoveryManifestContractError.invalidField("lastDeviceMode") }
      self = .known(value: value, evidence: evidence)
    default:
      throw RecoveryManifestContractError.invalidField("lastDeviceMode.state")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unknown:
      try container.encode("unknown", forKey: .state)
    case .known(let value, let evidence):
      try container.encode("known", forKey: .state)
      try container.encode(value, forKey: .value)
      try container.encode(evidence, forKey: .evidence)
    }
  }
}

public struct RecoveryManifestGuide: Codable, Equatable, Sendable {
  public let providerIdentity: String
  public let automaticRecoveryAvailable: Bool
  public let summary: String
  public let steps: [String]

  public init(
    providerIdentity: String,
    automaticRecoveryAvailable: Bool,
    summary: String,
    steps: [String]
  ) throws {
    guard !providerIdentity.isEmpty, !summary.isEmpty, !steps.isEmpty,
      steps.allSatisfy({ !$0.isEmpty })
    else { throw RecoveryManifestContractError.invalidField("recoveryGuide") }
    self.providerIdentity = providerIdentity
    self.automaticRecoveryAvailable = automaticRecoveryAvailable
    self.summary = summary
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case providerIdentity, automaticRecoveryAvailable, summary, steps
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
    try self.init(
      providerIdentity: container.decode(String.self, forKey: .providerIdentity),
      automaticRecoveryAvailable: container.decode(Bool.self, forKey: .automaticRecoveryAvailable),
      summary: container.decode(String.self, forKey: .summary),
      steps: container.decode([String].self, forKey: .steps))
  }
}

public struct RecoveryManifestAbandonConfirmation: Codable, Equatable, Sendable {
  public let confirmationID: String
  public let actor: String
  public let decision: String
  public let confirmedAt: String

  public init(confirmationID: String, confirmedAt: String) throws {
    guard confirmationID.matchesManifestID,
      ISO8601DateFormatter().date(from: confirmedAt) != nil
    else { throw RecoveryManifestContractError.invalidField("userConfirmation") }
    self.confirmationID = confirmationID
    actor = "user"
    decision = "archiveInterrupted"
    self.confirmedAt = confirmedAt
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case confirmationID = "confirmationId"
    case actor, decision, confirmedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
    let actor = try container.decode(String.self, forKey: .actor)
    let decision = try container.decode(String.self, forKey: .decision)
    guard actor == "user", decision == "archiveInterrupted" else {
      throw RecoveryManifestContractError.invalidField("userConfirmation")
    }
    try self.init(
      confirmationID: container.decode(String.self, forKey: .confirmationID),
      confirmedAt: container.decode(String.self, forKey: .confirmedAt))
  }
}

public struct RecoveryManifestRecord: Codable, Equatable, Sendable {
  public let needsAttention: Bool
  public let interruptedReason: String?
  public let deviceHazards: [RecoveryManifestHazard]
  public let abandonAuditEventIDs: [String]
  public let lastConfirmedStepID: String?
  public let lastDeviceMode: RecoveryManifestDeviceMode
  public let managedHostProcessState: String
  public let recoveryGuide: RecoveryManifestGuide
  public let unexecutedCompensations: [CompensationDescriptor]
  public let userConfirmation: RecoveryManifestAbandonConfirmation?
  public let recoveryOfSessionID: String?
  public let recoveryOfJobID: String?

  public init(
    needsAttention: Bool,
    interruptedReason: String?,
    deviceHazards: [RecoveryManifestHazard],
    abandonAuditEventIDs: [String],
    lastConfirmedStepID: String?,
    lastDeviceMode: RecoveryManifestDeviceMode,
    managedHostProcessState: String,
    recoveryGuide: RecoveryManifestGuide,
    unexecutedCompensations: [CompensationDescriptor],
    userConfirmation: RecoveryManifestAbandonConfirmation?,
    recoveryOfSessionID: String?,
    recoveryOfJobID: String?
  ) throws {
    guard interruptedReason.map({ !$0.isEmpty }) ?? true,
      Set(abandonAuditEventIDs).count == abandonAuditEventIDs.count,
      abandonAuditEventIDs.allSatisfy(\.matchesManifestID),
      lastConfirmedStepID.map(\.matchesManifestID) ?? true,
      [
        "notStarted", "notRunning", "stoppedAtSafeBoundary", "stillRunningUnknown",
        "notApplicable",
      ].contains(managedHostProcessState),
      recoveryOfSessionID.map(\.matchesManifestID) ?? true,
      recoveryOfJobID.map(\.matchesManifestID) ?? true,
      abandonAuditEventIDs.isEmpty || userConfirmation != nil
    else { throw RecoveryManifestContractError.invalidField("recovery") }
    self.needsAttention = needsAttention
    self.interruptedReason = interruptedReason
    self.deviceHazards = deviceHazards
    self.abandonAuditEventIDs = abandonAuditEventIDs
    self.lastConfirmedStepID = lastConfirmedStepID
    self.lastDeviceMode = lastDeviceMode
    self.managedHostProcessState = managedHostProcessState
    self.recoveryGuide = recoveryGuide
    self.unexecutedCompensations = unexecutedCompensations
    self.userConfirmation = userConfirmation
    self.recoveryOfSessionID = recoveryOfSessionID
    self.recoveryOfJobID = recoveryOfJobID
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case needsAttention, interruptedReason, deviceHazards
    case abandonAuditEventIDs = "abandonAuditEventIds"
    case lastConfirmedStepID = "lastConfirmedStepId"
    case lastDeviceMode, managedHostProcessState, recoveryGuide, unexecutedCompensations
    case userConfirmation
    case recoveryOfSessionID = "recoveryOfSessionId"
    case recoveryOfJobID = "recoveryOfJobId"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
    try self.init(
      needsAttention: container.decode(Bool.self, forKey: .needsAttention),
      interruptedReason: container.decodeIfPresent(String.self, forKey: .interruptedReason),
      deviceHazards: container.decode([RecoveryManifestHazard].self, forKey: .deviceHazards),
      abandonAuditEventIDs: container.decode([String].self, forKey: .abandonAuditEventIDs),
      lastConfirmedStepID: container.decodeIfPresent(String.self, forKey: .lastConfirmedStepID),
      lastDeviceMode: container.decode(RecoveryManifestDeviceMode.self, forKey: .lastDeviceMode),
      managedHostProcessState: container.decode(String.self, forKey: .managedHostProcessState),
      recoveryGuide: container.decode(RecoveryManifestGuide.self, forKey: .recoveryGuide),
      unexecutedCompensations: container.decode(
        [CompensationDescriptor].self, forKey: .unexecutedCompensations),
      userConfirmation: container.decodeIfPresent(
        RecoveryManifestAbandonConfirmation.self, forKey: .userConfirmation),
      recoveryOfSessionID: container.decodeIfPresent(String.self, forKey: .recoveryOfSessionID),
      recoveryOfJobID: container.decodeIfPresent(String.self, forKey: .recoveryOfJobID))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(needsAttention, forKey: .needsAttention)
    try container.encode(interruptedReason, forKey: .interruptedReason)
    try container.encode(deviceHazards, forKey: .deviceHazards)
    try container.encode(abandonAuditEventIDs, forKey: .abandonAuditEventIDs)
    try container.encode(lastConfirmedStepID, forKey: .lastConfirmedStepID)
    try container.encode(lastDeviceMode, forKey: .lastDeviceMode)
    try container.encode(managedHostProcessState, forKey: .managedHostProcessState)
    try container.encode(recoveryGuide, forKey: .recoveryGuide)
    try container.encode(unexecutedCompensations, forKey: .unexecutedCompensations)
    try container.encode(userConfirmation, forKey: .userConfirmation)
    try container.encode(recoveryOfSessionID, forKey: .recoveryOfSessionID)
    try container.encode(recoveryOfJobID, forKey: .recoveryOfJobID)
  }
}

public enum RecoveryManifestContractError: Error, Equatable, Sendable {
  case unknownOrMissingFields
  case invalidField(String)
}

public enum RecoveryManifestCodec {
  public static func encode(_ record: RecoveryManifestRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(record)
  }

  public static func decode(_ data: Data) throws -> RecoveryManifestRecord {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    return try JSONDecoder().decode(RecoveryManifestRecord.self, from: data)
  }
}

extension Decoder {
  fileprivate func strictContainer<Key: CodingKey & CaseIterable>(
    keyedBy _: Key.Type
  ) throws -> KeyedDecodingContainer<Key>
  where Key.AllCases: Collection, Key.AllCases.Element == Key {
    let expected = Set(Key.allCases.map(\.stringValue))
    let dynamicContainer = try container(keyedBy: RecoveryManifestAnyCodingKey.self)
    guard Set(dynamicContainer.allKeys.map(\.stringValue)) == expected else {
      throw RecoveryManifestContractError.unknownOrMissingFields
    }
    return try container(keyedBy: Key.self)
  }
}

private struct RecoveryManifestAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

extension String {
  fileprivate var matchesManifestID: Bool {
    range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == startIndex..<endIndex
  }
}
