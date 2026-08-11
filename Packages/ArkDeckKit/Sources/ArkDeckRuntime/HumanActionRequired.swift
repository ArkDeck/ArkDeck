import ArkDeckCore
import Foundation

public enum HumanActionCategory: String, CaseIterable, Codable, Sendable {
  case physicalConnection
  case deviceTrustPrompt
  case osPermission
  case credentialProvisioning
  case ambiguousIdentity
  case impactApproval
  case outcomeUnknownDecision
  case governanceApproval
}

public enum HumanActionStatus: String, CaseIterable, Codable, Sendable {
  case waiting
  case resolvedByFreshProbe
  case expired
}

package enum HumanActionResumeProbeOperation: String, CaseIterable, Codable, Sendable {
  case observeDevice
  case probeHostConfiguration
  case probeImpactApproval
  case reconcileOutcome
  case probeGovernanceApproval
}

package enum HumanActionProhibitedAutomation: String, CaseIterable, Codable, Sendable {
  case physicalActuation
  case trustPromptAcceptance
  case privilegeEscalation
  case driverOrHelperInstall
  case systemRuleMutation
  case credentialExtraction
  case identityGuess
  case outcomeGuess
  case selfApproval
}

public struct HumanActionFreshProbeResolution: Equatable, Sendable, Codable {
  package let probeOperationID: HumanActionResumeProbeOperation
  package let probeReceiptID: String
  package let observedAtUTC: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case probeOperationID = "probeOperationId"
    case probeReceiptID = "probeReceiptId"
    case observedAtUTC = "observedAtUtc"
  }

  fileprivate init(
    probeOperationID: HumanActionResumeProbeOperation,
    probeReceiptID: String,
    observedAtUTC: String
  ) {
    self.probeOperationID = probeOperationID
    self.probeReceiptID = probeReceiptID
    self.observedAtUTC = observedAtUTC
  }

  public init(from decoder: Decoder) throws {
    try HumanActionValidation.requireClosedKeys(
      decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    probeOperationID = try container.decode(
      HumanActionResumeProbeOperation.self, forKey: .probeOperationID)
    probeReceiptID = try container.decode(String.self, forKey: .probeReceiptID)
    observedAtUTC = try container.decode(String.self, forKey: .observedAtUTC)
    try HumanActionValidation.identifier(probeReceiptID, field: "resolution.probeReceiptId")
    try HumanActionValidation.timestamp(observedAtUTC, field: "resolution.observedAtUtc")
  }
}

public enum HumanActionRequiredError: Error, Equatable, Sendable {
  case malformed(path: String)
  case invalidMapping(category: HumanActionCategory)
  case invalidTransition
}

public struct HumanActionRequired: Equatable, Sendable, Codable {
  public static let documentType = "humanActionRequired"
  public static let schemaVersion = "1.0.0"

  public let actionID: String
  public let jobID: String
  public let stepID: String?
  package let category: HumanActionCategory
  public let reasonCode: String
  package let minimumActionKey: String
  package let prohibitedAutomation: [HumanActionProhibitedAutomation]
  package let resumeProbeOperationID: HumanActionResumeProbeOperation
  package let generatedAtUTC: String
  public let expiresAtUTC: String?
  public let status: HumanActionStatus
  package let resolution: HumanActionFreshProbeResolution?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case actionID = "actionId"
    case jobID = "jobId"
    case stepID = "stepId"
    case category
    case reasonCode
    case minimumActionKey
    case prohibitedAutomation
    case resumeProbeOperationID = "resumeProbeOperationId"
    case generatedAtUTC = "generatedAtUtc"
    case expiresAtUTC = "expiresAtUtc"
    case status
    case resolution
  }

  public init(
    actionID: String,
    jobID: String,
    stepID: String? = nil,
    category: HumanActionCategory,
    generatedAtUTC: String,
    expiresAtUTC: String? = nil
  ) throws {
    let mapping = HumanActionMapping.value(for: category)
    self.actionID = actionID
    self.jobID = jobID
    self.stepID = stepID
    self.category = category
    reasonCode = mapping.reasonCode
    minimumActionKey = mapping.minimumActionKey
    prohibitedAutomation = mapping.prohibitedAutomation
    resumeProbeOperationID = mapping.resumeProbe
    self.generatedAtUTC = generatedAtUTC
    self.expiresAtUTC = expiresAtUTC
    status = .waiting
    resolution = nil
    try validate()
  }

  private init(
    actionID: String,
    jobID: String,
    stepID: String?,
    category: HumanActionCategory,
    reasonCode: String,
    minimumActionKey: String,
    prohibitedAutomation: [HumanActionProhibitedAutomation],
    resumeProbeOperationID: HumanActionResumeProbeOperation,
    generatedAtUTC: String,
    expiresAtUTC: String?,
    status: HumanActionStatus,
    resolution: HumanActionFreshProbeResolution?
  ) throws {
    self.actionID = actionID
    self.jobID = jobID
    self.stepID = stepID
    self.category = category
    self.reasonCode = reasonCode
    self.minimumActionKey = minimumActionKey
    self.prohibitedAutomation = prohibitedAutomation
    self.resumeProbeOperationID = resumeProbeOperationID
    self.generatedAtUTC = generatedAtUTC
    self.expiresAtUTC = expiresAtUTC
    self.status = status
    self.resolution = resolution
    try validate()
  }

  public init(from decoder: Decoder) throws {
    do {
      try HumanActionValidation.requireClosedKeys(
        decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
      let container = try decoder.container(keyedBy: CodingKeys.self)
      guard try container.decode(String.self, forKey: .documentType) == Self.documentType
      else { throw HumanActionRequiredError.malformed(path: "$.documentType") }
      guard try container.decode(String.self, forKey: .schemaVersion) == Self.schemaVersion
      else { throw HumanActionRequiredError.malformed(path: "$.schemaVersion") }
      try self.init(
        actionID: container.decode(String.self, forKey: .actionID),
        jobID: container.decode(String.self, forKey: .jobID),
        stepID: container.decodeIfPresent(String.self, forKey: .stepID),
        category: container.decode(HumanActionCategory.self, forKey: .category),
        reasonCode: container.decode(String.self, forKey: .reasonCode),
        minimumActionKey: container.decode(String.self, forKey: .minimumActionKey),
        prohibitedAutomation: container.decode(
          [HumanActionProhibitedAutomation].self, forKey: .prohibitedAutomation),
        resumeProbeOperationID: container.decode(
          HumanActionResumeProbeOperation.self, forKey: .resumeProbeOperationID),
        generatedAtUTC: container.decode(String.self, forKey: .generatedAtUTC),
        expiresAtUTC: container.decodeIfPresent(String.self, forKey: .expiresAtUTC),
        status: container.decode(HumanActionStatus.self, forKey: .status),
        resolution: container.decodeIfPresent(
          HumanActionFreshProbeResolution.self, forKey: .resolution))
    } catch let error as HumanActionRequiredError {
      throw error
    } catch {
      throw HumanActionRequiredError.malformed(path: "$")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.documentType, forKey: .documentType)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(actionID, forKey: .actionID)
    try container.encode(jobID, forKey: .jobID)
    try container.encodeIfPresent(stepID, forKey: .stepID)
    try container.encode(category, forKey: .category)
    try container.encode(reasonCode, forKey: .reasonCode)
    try container.encode(minimumActionKey, forKey: .minimumActionKey)
    try container.encode(prohibitedAutomation, forKey: .prohibitedAutomation)
    try container.encode(resumeProbeOperationID, forKey: .resumeProbeOperationID)
    try container.encode(generatedAtUTC, forKey: .generatedAtUTC)
    try container.encodeIfPresent(expiresAtUTC, forKey: .expiresAtUTC)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(resolution, forKey: .resolution)
  }

  package func resolving(
    with receipt: HumanActionFreshProbeReceipt
  ) throws -> HumanActionRequired {
    guard status == .waiting,
      receipt.probeOperationID == resumeProbeOperationID,
      HumanActionValidation.date(receipt.observedAtUTC)
        >= HumanActionValidation.date(generatedAtUTC),
      expiresAtUTC.map({
        HumanActionValidation.date(receipt.observedAtUTC) < HumanActionValidation.date($0)
      }) ?? true
    else { throw HumanActionRequiredError.invalidTransition }
    return try HumanActionRequired(
      actionID: actionID, jobID: jobID, stepID: stepID, category: category,
      reasonCode: reasonCode, minimumActionKey: minimumActionKey,
      prohibitedAutomation: prohibitedAutomation,
      resumeProbeOperationID: resumeProbeOperationID, generatedAtUTC: generatedAtUTC,
      expiresAtUTC: expiresAtUTC, status: .resolvedByFreshProbe,
      resolution: HumanActionFreshProbeResolution(
        probeOperationID: receipt.probeOperationID,
        probeReceiptID: receipt.probeReceiptID,
        observedAtUTC: receipt.observedAtUTC))
  }

  private func validate() throws {
    try HumanActionValidation.identifier(actionID, field: "actionId")
    try HumanActionValidation.identifier(jobID, field: "jobId")
    if let stepID { try HumanActionValidation.identifier(stepID, field: "stepId") }
    try HumanActionValidation.identifier(reasonCode, field: "reasonCode")
    try HumanActionValidation.identifier(minimumActionKey, field: "minimumActionKey")
    try HumanActionValidation.timestamp(generatedAtUTC, field: "generatedAtUtc")
    if let expiresAtUTC {
      try HumanActionValidation.timestamp(expiresAtUTC, field: "expiresAtUtc")
      guard
        HumanActionValidation.date(expiresAtUTC)
          >= HumanActionValidation.date(generatedAtUTC)
      else { throw HumanActionRequiredError.malformed(path: "$.expiresAtUtc") }
    }
    let mapping = HumanActionMapping.value(for: category)
    guard reasonCode == mapping.reasonCode,
      minimumActionKey == mapping.minimumActionKey,
      resumeProbeOperationID == mapping.resumeProbe,
      prohibitedAutomation == mapping.prohibitedAutomation
    else { throw HumanActionRequiredError.invalidMapping(category: category) }
    guard Set(prohibitedAutomation).count == prohibitedAutomation.count,
      !prohibitedAutomation.isEmpty
    else { throw HumanActionRequiredError.malformed(path: "$.prohibitedAutomation") }
    switch status {
    case .waiting:
      guard resolution == nil else { throw HumanActionRequiredError.invalidTransition }
    case .expired:
      guard resolution == nil, expiresAtUTC != nil else {
        throw HumanActionRequiredError.invalidTransition
      }
    case .resolvedByFreshProbe:
      guard let resolution,
        resolution.probeOperationID == resumeProbeOperationID,
        HumanActionValidation.date(resolution.observedAtUTC)
          >= HumanActionValidation.date(generatedAtUTC),
        expiresAtUTC.map({
          HumanActionValidation.date(resolution.observedAtUTC)
            < HumanActionValidation.date($0)
        }) ?? true
      else { throw HumanActionRequiredError.invalidTransition }
    }
  }
}

package struct HumanActionFreshProbeReceipt: Equatable, Sendable {
  package let probeOperationID: HumanActionResumeProbeOperation
  package let probeReceiptID: String
  package let observedAtUTC: String

  package init(
    probeOperationID: HumanActionResumeProbeOperation,
    probeReceiptID: String,
    observedAtUTC: String
  ) throws {
    try HumanActionValidation.identifier(probeReceiptID, field: "probeReceiptId")
    try HumanActionValidation.timestamp(observedAtUTC, field: "observedAtUtc")
    self.probeOperationID = probeOperationID
    self.probeReceiptID = probeReceiptID
    self.observedAtUTC = observedAtUTC
  }
}

package enum HumanActionRequiredCodec {
  public static func decode(_ data: Data) throws -> HumanActionRequired {
    do {
      var duplicateValidator = StrictJSONDuplicateValidator(data: data)
      try duplicateValidator.validate()
      return try JSONDecoder().decode(HumanActionRequired.self, from: data)
    } catch let error as HumanActionRequiredError {
      throw error
    } catch let error as StrictJSONError {
      switch error {
      case .duplicateMemberName(let path):
        throw HumanActionRequiredError.malformed(path: path)
      case .malformed:
        throw HumanActionRequiredError.malformed(path: "$")
      }
    } catch {
      throw HumanActionRequiredError.malformed(path: "$")
    }
  }

  public static func encode(_ value: HumanActionRequired) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(value)
  }
}

private struct HumanActionMapping {
  let reasonCode: String
  let minimumActionKey: String
  let resumeProbe: HumanActionResumeProbeOperation
  let prohibitedAutomation: [HumanActionProhibitedAutomation]

  static func value(for category: HumanActionCategory) -> HumanActionMapping {
    switch category {
    case .physicalConnection:
      HumanActionMapping(
        reasonCode: "device.notObserved", minimumActionKey: "human.connectOrPowerDevice",
        resumeProbe: .observeDevice, prohibitedAutomation: [.physicalActuation])
    case .deviceTrustPrompt:
      HumanActionMapping(
        reasonCode: "device.trustPending",
        minimumActionKey: "human.acceptDeviceTrustPrompt",
        resumeProbe: .observeDevice, prohibitedAutomation: [.trustPromptAcceptance])
    case .osPermission:
      HumanActionMapping(
        reasonCode: "host.permissionOrDriverRequired",
        minimumActionKey: "human.configureHostPermission",
        resumeProbe: .probeHostConfiguration,
        prohibitedAutomation: [
          .privilegeEscalation, .driverOrHelperInstall, .systemRuleMutation,
        ])
    case .credentialProvisioning:
      HumanActionMapping(
        reasonCode: "host.credentialRequired",
        minimumActionKey: "human.provisionCredential",
        resumeProbe: .probeHostConfiguration, prohibitedAutomation: [.credentialExtraction])
    case .ambiguousIdentity:
      HumanActionMapping(
        reasonCode: "device.identityAmbiguous",
        minimumActionKey: "human.confirmDeviceIdentity",
        resumeProbe: .observeDevice, prohibitedAutomation: [.identityGuess])
    case .impactApproval:
      HumanActionMapping(
        reasonCode: "policy.impactApprovalRequired",
        minimumActionKey: "human.reviewImpact",
        resumeProbe: .probeImpactApproval, prohibitedAutomation: [.selfApproval])
    case .outcomeUnknownDecision:
      HumanActionMapping(
        reasonCode: "recovery.outcomeUnknown",
        minimumActionKey: "human.reconcileOrAbandon",
        resumeProbe: .reconcileOutcome, prohibitedAutomation: [.outcomeGuess])
    case .governanceApproval:
      HumanActionMapping(
        reasonCode: "governance.approvalRequired",
        minimumActionKey: "human.mergeRequiredApproval",
        resumeProbe: .probeGovernanceApproval, prohibitedAutomation: [.selfApproval])
    }
  }
}

private enum HumanActionValidation {
  private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  static func requireClosedKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: DynamicKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw HumanActionRequiredError.malformed(path: "$")
    }
  }

  static func identifier(_ value: String, field: String) throws {
    guard value.count <= 128,
      value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) == value.startIndex..<value.endIndex
    else { throw HumanActionRequiredError.malformed(path: "$.\(field)") }
  }

  static func timestamp(_ value: String, field: String) throws {
    guard
      value.range(
        of:
          #"^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?Z$"#,
        options: .regularExpression) == value.startIndex..<value.endIndex,
      date(value) != .distantPast
    else { throw HumanActionRequiredError.malformed(path: "$.\(field)") }
  }

  static func date(_ value: String) -> Date {
    ISO8601Timestamps.parse(value) ?? .distantPast
  }
}
