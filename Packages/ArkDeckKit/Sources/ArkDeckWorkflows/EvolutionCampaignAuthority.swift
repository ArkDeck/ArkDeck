// Bounded Evolution E2 campaign authority (CHG-2026-025 r8, TASK-AIN-019).
//
// This is a third authority kind.  It does not reinterpret the r7 one-shot
// chat-confirmation record.  A user confirms the complete exploration
// envelope once; every destructive attempt still receives its own durable
// reservation and can only be dispatched by the product-owned Rockchip host.

import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

struct RockchipEvolutionDynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

public enum RockchipEvolutionCampaignError: Error, Equatable, Sendable,
  LocalizedError
{
  case invalidAssertion(String)
  case confirmationDigestMismatch
  case expired
  case campaignNotFound(String)
  case campaignConflict
  case campaignStopped(String)
  case candidateRejected(String)
  case reviewRejected(String)
  case admissionRejected(String)
  case persistenceRejected(String)

  public var errorDescription: String? {
    switch self {
    case .invalidAssertion(let field): "invalid evolution campaign assertion: \(field)"
    case .confirmationDigestMismatch: "campaign confirmation digest does not match its envelope"
    case .expired: "evolution campaign confirmation has expired"
    case .campaignNotFound(let id): "evolution campaign not found: \(id)"
    case .campaignConflict: "evolution campaign identity or append-only history conflicted"
    case .campaignStopped(let reason): "evolution campaign is terminal: \(reason)"
    case .candidateRejected(let reason): "evolution candidate rejected: \(reason)"
    case .reviewRejected(let reason): "adversarial review rejected: \(reason)"
    case .admissionRejected(let reason): "evolution campaign admission rejected: \(reason)"
    case .persistenceRejected(let reason): "evolution campaign persistence rejected: \(reason)"
    }
  }
}

/// The exact delegated envelope shown to and confirmed by the user.  The
/// digest is over every other field, so omission and optional-field drift are
/// bound just as strongly as value drift.
public struct RockchipEvolutionCampaignConfirmationAssertion: Equatable, Codable,
  Sendable
{
  public static let documentType = "rockchip-evolution-campaign-confirmation"
  public static let schemaVersion = "1.0.0"
  public static let operationReference = "flash.dayu200@1"
  public static let candidateBuildTarget = "ArkDeckEvolutionCandidate"
  public static let maximumAttemptLimit = 16
  public static let maximumValiditySeconds: TimeInterval = 4 * 60 * 60
  public static let maximumConcurrency = 1
  public static let dataImpact = "ERASE-USERDATA"
  public static let candidateSourceScope =
    "Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/**"

  public let documentType: String
  public let schemaVersion: String
  public let confirmationDigestSHA256: String
  public let baseCommitOID: String
  public let candidateToolchainDigestSHA256: String
  public let brokerExecutableDigestSHA256: String
  public let allowedPaths: [String]
  public let maxChangedFiles: Int
  public let maxDiffLines: Int
  public let planDigestSHA256: String
  public let archiveDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let targetStableIdentitySHA256: String
  public let bindingLineageRootRevision: Int
  public let maxAttempts: Int
  public let maximumConcurrentAttempts: Int
  public let confirmedAt: String
  public let validUntil: String
  public let userdataImpact: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case confirmationDigestSHA256
    case baseCommitOID
    case candidateToolchainDigestSHA256
    case brokerExecutableDigestSHA256
    case allowedPaths
    case maxChangedFiles
    case maxDiffLines
    case planDigestSHA256
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case targetStableIdentitySHA256
    case bindingLineageRootRevision
    case maxAttempts
    case maximumConcurrentAttempts
    case confirmedAt
    case validUntil
    case userdataImpact
  }

  public init(
    confirmationDigestSHA256: String,
    baseCommitOID: String,
    candidateToolchainDigestSHA256: String,
    brokerExecutableDigestSHA256: String,
    allowedPaths: [String] = [Self.candidateSourceScope],
    maxChangedFiles: Int,
    maxDiffLines: Int,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetStableIdentitySHA256: String,
    bindingLineageRootRevision: Int,
    maxAttempts: Int,
    maximumConcurrentAttempts: Int = Self.maximumConcurrency,
    confirmedAt: String,
    validUntil: String,
    userdataImpact: String = Self.dataImpact
  ) throws {
    documentType = Self.documentType
    schemaVersion = Self.schemaVersion
    self.confirmationDigestSHA256 = confirmationDigestSHA256
    self.baseCommitOID = baseCommitOID
    self.candidateToolchainDigestSHA256 = candidateToolchainDigestSHA256
    self.brokerExecutableDigestSHA256 = brokerExecutableDigestSHA256
    self.allowedPaths = Array(Set(allowedPaths)).sorted()
    self.maxChangedFiles = maxChangedFiles
    self.maxDiffLines = maxDiffLines
    self.planDigestSHA256 = planDigestSHA256
    self.archiveDigestSHA256 = archiveDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.targetStableIdentitySHA256 = targetStableIdentitySHA256
    self.bindingLineageRootRevision = bindingLineageRootRevision
    self.maxAttempts = maxAttempts
    self.maximumConcurrentAttempts = maximumConcurrentAttempts
    self.confirmedAt = confirmedAt
    self.validUntil = validUntil
    self.userdataImpact = userdataImpact
    try validate()
    guard confirmationDigestSHA256 == canonicalEnvelopeDigestSHA256() else {
      throw RockchipEvolutionCampaignError.confirmationDigestMismatch
    }
  }

  public static func draft(
    baseCommitOID: String,
    candidateToolchainDigestSHA256: String,
    brokerExecutableDigestSHA256: String,
    maxChangedFiles: Int,
    maxDiffLines: Int,
    planDigestSHA256: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    targetStableIdentitySHA256: String,
    bindingLineageRootRevision: Int,
    maxAttempts: Int,
    confirmedAt: String,
    validUntil: String
  ) throws -> Self {
    let paths = [Self.candidateSourceScope]
    let digest = sha256(
      canonicalData([
        "archiveDigestSHA256": .string(archiveDigestSHA256),
        "allowedPaths": .array(paths.map(JSONValue.string)),
        "baseCommitOID": .string(baseCommitOID),
        "bindingLineageRootRevision": .integer(Int64(bindingLineageRootRevision)),
        "brokerExecutableDigestSHA256": .string(brokerExecutableDigestSHA256),
        "candidateBuildTarget": .string(Self.candidateBuildTarget),
        "candidateToolchainDigestSHA256": .string(candidateToolchainDigestSHA256),
        "confirmedAt": .string(confirmedAt),
        "documentType": .string(Self.documentType),
        "maxAttempts": .integer(Int64(maxAttempts)),
        "maxChangedFiles": .integer(Int64(maxChangedFiles)),
        "maxDiffLines": .integer(Int64(maxDiffLines)),
        "maximumConcurrentAttempts": .integer(Int64(Self.maximumConcurrency)),
        "operationReference": .string(Self.operationReference),
        "planDigestSHA256": .string(planDigestSHA256),
        "schemaVersion": .string(Self.schemaVersion),
        "stepSetDigestSHA256": .string(stepSetDigestSHA256),
        "targetStableIdentitySHA256": .string(targetStableIdentitySHA256),
        "userdataImpact": .string(Self.dataImpact),
        "validUntil": .string(validUntil),
      ]))
    return try Self(
      confirmationDigestSHA256: digest, baseCommitOID: baseCommitOID,
      candidateToolchainDigestSHA256: candidateToolchainDigestSHA256,
      brokerExecutableDigestSHA256: brokerExecutableDigestSHA256,
      allowedPaths: paths, maxChangedFiles: maxChangedFiles, maxDiffLines: maxDiffLines,
      planDigestSHA256: planDigestSHA256, archiveDigestSHA256: archiveDigestSHA256,
      stepSetDigestSHA256: stepSetDigestSHA256,
      targetStableIdentitySHA256: targetStableIdentitySHA256,
      bindingLineageRootRevision: bindingLineageRootRevision,
      maxAttempts: maxAttempts, confirmedAt: confirmedAt, validUntil: validUntil)
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw RockchipEvolutionCampaignError.invalidAssertion("closedShape")
    }
    try self.init(
      confirmationDigestSHA256: container.decode(
        String.self, forKey: .confirmationDigestSHA256),
      baseCommitOID: container.decode(String.self, forKey: .baseCommitOID),
      candidateToolchainDigestSHA256: container.decode(
        String.self, forKey: .candidateToolchainDigestSHA256),
      brokerExecutableDigestSHA256: container.decode(
        String.self, forKey: .brokerExecutableDigestSHA256),
      allowedPaths: container.decode([String].self, forKey: .allowedPaths),
      maxChangedFiles: container.decode(Int.self, forKey: .maxChangedFiles),
      maxDiffLines: container.decode(Int.self, forKey: .maxDiffLines),
      planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
      archiveDigestSHA256: container.decode(String.self, forKey: .archiveDigestSHA256),
      stepSetDigestSHA256: container.decode(String.self, forKey: .stepSetDigestSHA256),
      targetStableIdentitySHA256: container.decode(
        String.self, forKey: .targetStableIdentitySHA256),
      bindingLineageRootRevision: container.decode(
        Int.self, forKey: .bindingLineageRootRevision),
      maxAttempts: container.decode(Int.self, forKey: .maxAttempts),
      maximumConcurrentAttempts: container.decode(
        Int.self, forKey: .maximumConcurrentAttempts),
      confirmedAt: container.decode(String.self, forKey: .confirmedAt),
      validUntil: container.decode(String.self, forKey: .validUntil),
      userdataImpact: container.decode(String.self, forKey: .userdataImpact))
    guard documentType == (try container.decode(String.self, forKey: .documentType)),
      schemaVersion == (try container.decode(String.self, forKey: .schemaVersion))
    else { throw RockchipEvolutionCampaignError.invalidAssertion("schema") }
  }

  public var campaignID: String {
    "ECAMP-\(confirmationDigestSHA256.prefix(24).uppercased())"
  }

  public func authorityReference() throws -> AgentExecutionAuthorityReference {
    try .validatedEvolutionCampaignConfirmation(
      campaignDigestSHA256: confirmationDigestSHA256,
      baseCommitOID: baseCommitOID,
      planDigestSHA256: planDigestSHA256,
      archiveDigestSHA256: archiveDigestSHA256,
      stepSetDigestSHA256: stepSetDigestSHA256,
      targetStableIdentitySHA256: targetStableIdentitySHA256,
      bindingLineageRootRevision: bindingLineageRootRevision,
      confirmedAt: confirmedAt, validUntil: validUntil,
      maximumAttempts: maxAttempts)
  }

  public func canonicalEnvelopeDigestSHA256() -> String {
    Self.sha256(
      Self.canonicalData([
        "archiveDigestSHA256": .string(archiveDigestSHA256),
        "allowedPaths": .array(allowedPaths.map(JSONValue.string)),
        "baseCommitOID": .string(baseCommitOID),
        "bindingLineageRootRevision": .integer(Int64(bindingLineageRootRevision)),
        "brokerExecutableDigestSHA256": .string(brokerExecutableDigestSHA256),
        "candidateBuildTarget": .string(Self.candidateBuildTarget),
        "candidateToolchainDigestSHA256": .string(candidateToolchainDigestSHA256),
        "confirmedAt": .string(confirmedAt),
        "documentType": .string(Self.documentType),
        "maxAttempts": .integer(Int64(maxAttempts)),
        "maxChangedFiles": .integer(Int64(maxChangedFiles)),
        "maxDiffLines": .integer(Int64(maxDiffLines)),
        "maximumConcurrentAttempts": .integer(Int64(maximumConcurrentAttempts)),
        "operationReference": .string(Self.operationReference),
        "planDigestSHA256": .string(planDigestSHA256),
        "schemaVersion": .string(Self.schemaVersion),
        "stepSetDigestSHA256": .string(stepSetDigestSHA256),
        "targetStableIdentitySHA256": .string(targetStableIdentitySHA256),
        "userdataImpact": .string(userdataImpact),
        "validUntil": .string(validUntil),
      ]))
  }

  public func isValid(at timestamp: String) -> Bool {
    guard let now = Self.date(timestamp), let confirmed = Self.date(confirmedAt),
      let expiry = Self.date(validUntil)
    else { return false }
    return confirmed <= now && now <= expiry
  }

  private func validate() throws {
    guard documentType == Self.documentType, schemaVersion == Self.schemaVersion else {
      throw RockchipEvolutionCampaignError.invalidAssertion("schema")
    }
    guard Self.isSHA256(confirmationDigestSHA256), Self.isOID(baseCommitOID),
      [
        candidateToolchainDigestSHA256, brokerExecutableDigestSHA256,
        planDigestSHA256, archiveDigestSHA256, stepSetDigestSHA256,
        targetStableIdentitySHA256,
      ].allSatisfy(Self.isSHA256)
    else { throw RockchipEvolutionCampaignError.invalidAssertion("digest") }
    guard allowedPaths == [Self.candidateSourceScope] else {
      throw RockchipEvolutionCampaignError.invalidAssertion("allowedPaths")
    }
    guard (1...16).contains(maxChangedFiles), (1...4_000).contains(maxDiffLines) else {
      throw RockchipEvolutionCampaignError.invalidAssertion("candidateBudget")
    }
    guard (1...Self.maximumAttemptLimit).contains(maxAttempts),
      maximumConcurrentAttempts == Self.maximumConcurrency,
      bindingLineageRootRevision > 0, userdataImpact == Self.dataImpact
    else { throw RockchipEvolutionCampaignError.invalidAssertion("effectBudget") }
    guard let confirmed = Self.date(confirmedAt), let expiry = Self.date(validUntil),
      confirmed < expiry,
      expiry.timeIntervalSince(confirmed) <= Self.maximumValiditySeconds
    else { throw RockchipEvolutionCampaignError.invalidAssertion("validity") }
  }

  static func canonicalData(_ object: [String: JSONValue]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(JSONValue.object(object))) ?? Data()
  }

  package static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  package static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func isOID(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

public enum RockchipEvolutionStartingMode: String, Codable, CaseIterable, Sendable {
  case hdcNormal
  case loader
}

/// The candidate's only output.  It can narrow which already-published entry
/// modes are acceptable; it cannot describe a process, executable, argv,
/// action, target, authority or new Catalog step.
public struct RockchipEvolutionTypedStrategy: Equatable, Codable, Sendable {
  public static let defaultLoaderDiscoveryTimeoutSeconds = 45
  public static let defaultLoaderPollIntervalMilliseconds = 500
  public static let defaultHDCCommandTimeoutSeconds = 20
  public static let defaultReadOnlyCommandTimeoutSeconds = 15

  public let operationReference: String
  public let deviceProfileReference: String
  public let archiveDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let allowedStartingModes: [RockchipEvolutionStartingMode]
  public let loaderDiscoveryTimeoutSeconds: Int
  public let loaderPollIntervalMilliseconds: Int
  public let hdcCommandTimeoutSeconds: Int
  public let readOnlyCommandTimeoutSeconds: Int
  public let userdataImpact: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case operationReference
    case deviceProfileReference
    case archiveDigestSHA256
    case stepSetDigestSHA256
    case allowedStartingModes
    case loaderDiscoveryTimeoutSeconds
    case loaderPollIntervalMilliseconds
    case hdcCommandTimeoutSeconds
    case readOnlyCommandTimeoutSeconds
    case userdataImpact
  }

  public init(
    operationReference: String,
    deviceProfileReference: String,
    archiveDigestSHA256: String,
    stepSetDigestSHA256: String,
    allowedStartingModes: [RockchipEvolutionStartingMode],
    loaderDiscoveryTimeoutSeconds: Int = Self.defaultLoaderDiscoveryTimeoutSeconds,
    loaderPollIntervalMilliseconds: Int = Self.defaultLoaderPollIntervalMilliseconds,
    hdcCommandTimeoutSeconds: Int = Self.defaultHDCCommandTimeoutSeconds,
    readOnlyCommandTimeoutSeconds: Int = Self.defaultReadOnlyCommandTimeoutSeconds,
    userdataImpact: String
  ) throws {
    let modes = Array(Set(allowedStartingModes)).sorted { $0.rawValue < $1.rawValue }
    guard operationReference == RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference == "dayu200@2",
      RockchipEvolutionCampaignConfirmationAssertion.isSHA256(archiveDigestSHA256),
      RockchipEvolutionCampaignConfirmationAssertion.isSHA256(stepSetDigestSHA256),
      !modes.isEmpty,
      (15...120).contains(loaderDiscoveryTimeoutSeconds),
      (100...2_000).contains(loaderPollIntervalMilliseconds),
      (5...60).contains(hdcCommandTimeoutSeconds),
      (5...60).contains(readOnlyCommandTimeoutSeconds),
      userdataImpact == RockchipEvolutionCampaignConfirmationAssertion.dataImpact
    else { throw RockchipEvolutionCampaignError.candidateRejected("typedStrategy") }
    self.operationReference = operationReference
    self.deviceProfileReference = deviceProfileReference
    self.archiveDigestSHA256 = archiveDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.allowedStartingModes = modes
    self.loaderDiscoveryTimeoutSeconds = loaderDiscoveryTimeoutSeconds
    self.loaderPollIntervalMilliseconds = loaderPollIntervalMilliseconds
    self.hdcCommandTimeoutSeconds = hdcCommandTimeoutSeconds
    self.readOnlyCommandTimeoutSeconds = readOnlyCommandTimeoutSeconds
    self.userdataImpact = userdataImpact
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let keys = Set(dynamic.allKeys.map(\.stringValue))
    let currentKeys = Set(CodingKeys.allCases.map(\.stringValue))
    let tuningKeys: Set<String> = [
      CodingKeys.loaderDiscoveryTimeoutSeconds.rawValue,
      CodingKeys.loaderPollIntervalMilliseconds.rawValue,
      CodingKeys.hdcCommandTimeoutSeconds.rawValue,
      CodingKeys.readOnlyCommandTimeoutSeconds.rawValue,
    ]
    let isLegacyShape = keys == currentKeys.subtracting(tuningKeys)
    guard keys == currentKeys || isLegacyShape else {
      throw RockchipEvolutionCampaignError.candidateRejected("typedStrategyClosedShape")
    }
    try self.init(
      operationReference: container.decode(String.self, forKey: .operationReference),
      deviceProfileReference: container.decode(String.self, forKey: .deviceProfileReference),
      archiveDigestSHA256: container.decode(String.self, forKey: .archiveDigestSHA256),
      stepSetDigestSHA256: container.decode(String.self, forKey: .stepSetDigestSHA256),
      allowedStartingModes: container.decode(
        [RockchipEvolutionStartingMode].self, forKey: .allowedStartingModes),
      loaderDiscoveryTimeoutSeconds: isLegacyShape
        ? Self.defaultLoaderDiscoveryTimeoutSeconds
        : container.decode(Int.self, forKey: .loaderDiscoveryTimeoutSeconds),
      loaderPollIntervalMilliseconds: isLegacyShape
        ? Self.defaultLoaderPollIntervalMilliseconds
        : container.decode(Int.self, forKey: .loaderPollIntervalMilliseconds),
      hdcCommandTimeoutSeconds: isLegacyShape
        ? Self.defaultHDCCommandTimeoutSeconds
        : container.decode(Int.self, forKey: .hdcCommandTimeoutSeconds),
      readOnlyCommandTimeoutSeconds: isLegacyShape
        ? Self.defaultReadOnlyCommandTimeoutSeconds
        : container.decode(Int.self, forKey: .readOnlyCommandTimeoutSeconds),
      userdataImpact: container.decode(String.self, forKey: .userdataImpact))
  }

  public var digestSHA256: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return RockchipEvolutionCampaignConfirmationAssertion.sha256(
      (try? encoder.encode(self)) ?? Data())
  }
}

public struct RockchipEvolutionCandidatePin: Equatable, Codable, Sendable {
  public let candidateID: String
  public let producerID: String
  public let baseCommitOID: String
  public let sourceTreeDigestSHA256: String
  public let diffDigestSHA256: String
  public let allowedPathSetDigestSHA256: String
  public let executableDigestSHA256: String
  public let toolchainDigestSHA256: String
  public let changedFiles: [String]
  public let changedLines: Int
  public let diffArtifactID: String
  public let buildEvidenceArtifactID: String
  public let testEvidenceArtifactID: String
  public let strategy: RockchipEvolutionTypedStrategy

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case candidateID
    case producerID
    case baseCommitOID
    case sourceTreeDigestSHA256
    case diffDigestSHA256
    case allowedPathSetDigestSHA256
    case executableDigestSHA256
    case toolchainDigestSHA256
    case changedFiles
    case changedLines
    case diffArtifactID
    case buildEvidenceArtifactID
    case testEvidenceArtifactID
    case strategy
  }

  public init(
    candidateID: String,
    producerID: String,
    baseCommitOID: String,
    sourceTreeDigestSHA256: String,
    diffDigestSHA256: String,
    allowedPathSetDigestSHA256: String,
    executableDigestSHA256: String,
    toolchainDigestSHA256: String,
    changedFiles: [String],
    changedLines: Int,
    diffArtifactID: String,
    buildEvidenceArtifactID: String,
    testEvidenceArtifactID: String,
    strategy: RockchipEvolutionTypedStrategy
  ) throws {
    let files = Array(Set(changedFiles)).sorted()
    guard
      candidateID.range(of: #"^ECAND-[A-F0-9]{16,32}$"#, options: .regularExpression)
        == candidateID.startIndex..<candidateID.endIndex,
      !producerID.isEmpty, producerID.utf8.count <= 200,
      RockchipEvolutionCampaignConfirmationAssertion.isOID(baseCommitOID),
      [
        sourceTreeDigestSHA256, diffDigestSHA256, allowedPathSetDigestSHA256,
        executableDigestSHA256, toolchainDigestSHA256,
      ].allSatisfy(RockchipEvolutionCampaignConfirmationAssertion.isSHA256),
      changedLines >= 0,
      [diffArtifactID, buildEvidenceArtifactID, testEvidenceArtifactID].allSatisfy({
        $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression)
          == $0.startIndex..<$0.endIndex
      })
    else { throw RockchipEvolutionCampaignError.candidateRejected("candidatePin") }
    self.candidateID = candidateID
    self.producerID = producerID
    self.baseCommitOID = baseCommitOID
    self.sourceTreeDigestSHA256 = sourceTreeDigestSHA256
    self.diffDigestSHA256 = diffDigestSHA256
    self.allowedPathSetDigestSHA256 = allowedPathSetDigestSHA256
    self.executableDigestSHA256 = executableDigestSHA256
    self.toolchainDigestSHA256 = toolchainDigestSHA256
    self.changedFiles = files
    self.changedLines = changedLines
    self.diffArtifactID = diffArtifactID
    self.buildEvidenceArtifactID = buildEvidenceArtifactID
    self.testEvidenceArtifactID = testEvidenceArtifactID
    self.strategy = strategy
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw RockchipEvolutionCampaignError.candidateRejected("candidatePinClosedShape")
    }
    try self.init(
      candidateID: container.decode(String.self, forKey: .candidateID),
      producerID: container.decode(String.self, forKey: .producerID),
      baseCommitOID: container.decode(String.self, forKey: .baseCommitOID),
      sourceTreeDigestSHA256: container.decode(
        String.self, forKey: .sourceTreeDigestSHA256),
      diffDigestSHA256: container.decode(String.self, forKey: .diffDigestSHA256),
      allowedPathSetDigestSHA256: container.decode(
        String.self, forKey: .allowedPathSetDigestSHA256),
      executableDigestSHA256: container.decode(
        String.self, forKey: .executableDigestSHA256),
      toolchainDigestSHA256: container.decode(
        String.self, forKey: .toolchainDigestSHA256),
      changedFiles: container.decode([String].self, forKey: .changedFiles),
      changedLines: container.decode(Int.self, forKey: .changedLines),
      diffArtifactID: container.decode(String.self, forKey: .diffArtifactID),
      buildEvidenceArtifactID: container.decode(
        String.self, forKey: .buildEvidenceArtifactID),
      testEvidenceArtifactID: container.decode(
        String.self, forKey: .testEvidenceArtifactID),
      strategy: container.decode(RockchipEvolutionTypedStrategy.self, forKey: .strategy))
  }
}

public enum RockchipEvolutionReviewVerdict: String, Codable, Sendable {
  case pass = "PASS"
  case reject = "REJECT"
}

public enum RockchipEvolutionReviewSeverity: String, Codable, CaseIterable, Sendable {
  case low = "LOW"
  case medium = "MEDIUM"
  case high = "HIGH"
  case critical = "CRITICAL"
}

public struct RockchipEvolutionReviewIssue: Equatable, Codable, Sendable {
  public let severity: RockchipEvolutionReviewSeverity
  public let code: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case severity
    case code
  }

  public init(severity: RockchipEvolutionReviewSeverity, code: String) throws {
    guard
      code.range(of: #"^[A-Z][A-Z0-9_-]{1,63}$"#, options: .regularExpression)
        == code.startIndex..<code.endIndex
    else { throw RockchipEvolutionCampaignError.reviewRejected("issueCode") }
    self.severity = severity
    self.code = code
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw RockchipEvolutionCampaignError.reviewRejected("issueClosedShape")
    }
    try self.init(
      severity: container.decode(RockchipEvolutionReviewSeverity.self, forKey: .severity),
      code: container.decode(String.self, forKey: .code))
  }
}

public struct RockchipEvolutionReviewReceipt: Equatable, Codable, Sendable {
  public let reviewID: String
  public let reviewerID: String
  public let candidateID: String
  public let candidateExecutableDigestSHA256: String
  public let planDigestSHA256: String
  public let result: RockchipEvolutionReviewVerdict
  public let issues: [RockchipEvolutionReviewIssue]
  public let createdAt: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case reviewID
    case reviewerID
    case candidateID
    case candidateExecutableDigestSHA256
    case planDigestSHA256
    case result
    case issues
    case createdAt
  }

  public init(
    reviewID: String,
    reviewerID: String,
    candidateID: String,
    candidateExecutableDigestSHA256: String,
    planDigestSHA256: String,
    result: RockchipEvolutionReviewVerdict,
    issues: [RockchipEvolutionReviewIssue],
    createdAt: String
  ) throws {
    guard
      reviewID.range(of: #"^EREVIEW-[A-F0-9]{16,32}$"#, options: .regularExpression)
        == reviewID.startIndex..<reviewID.endIndex,
      !reviewerID.isEmpty, reviewerID.utf8.count <= 200,
      candidateID.range(of: #"^ECAND-[A-F0-9]{16,32}$"#, options: .regularExpression)
        == candidateID.startIndex..<candidateID.endIndex,
      RockchipEvolutionCampaignConfirmationAssertion.isSHA256(
        candidateExecutableDigestSHA256),
      RockchipEvolutionCampaignConfirmationAssertion.isSHA256(planDigestSHA256),
      RockchipEvolutionCampaignConfirmationAssertion.date(createdAt) != nil
    else { throw RockchipEvolutionCampaignError.reviewRejected("receipt") }
    self.reviewID = reviewID
    self.reviewerID = reviewerID
    self.candidateID = candidateID
    self.candidateExecutableDigestSHA256 = candidateExecutableDigestSHA256
    self.planDigestSHA256 = planDigestSHA256
    self.result = result
    self.issues = issues
    self.createdAt = createdAt
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw RockchipEvolutionCampaignError.reviewRejected("receiptClosedShape")
    }
    try self.init(
      reviewID: container.decode(String.self, forKey: .reviewID),
      reviewerID: container.decode(String.self, forKey: .reviewerID),
      candidateID: container.decode(String.self, forKey: .candidateID),
      candidateExecutableDigestSHA256: container.decode(
        String.self, forKey: .candidateExecutableDigestSHA256),
      planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
      result: container.decode(RockchipEvolutionReviewVerdict.self, forKey: .result),
      issues: container.decode([RockchipEvolutionReviewIssue].self, forKey: .issues),
      createdAt: container.decode(String.self, forKey: .createdAt))
  }

  public func validate(candidate: RockchipEvolutionCandidatePin) throws {
    guard candidateID == candidate.candidateID,
      candidateExecutableDigestSHA256 == candidate.executableDigestSHA256,
      reviewerID != candidate.producerID, result == .pass,
      !issues.contains(where: { $0.severity == .high || $0.severity == .critical })
    else { throw RockchipEvolutionCampaignError.reviewRejected("verdictOrIdentity") }
  }
}

/// Non-Codable, process-local permit.  CLI bytes cannot manufacture it; only
/// the task-owned builder plus independent reviewer can return one.
public final class RockchipEvolutionCampaignAttemptPermit: @unchecked Sendable, Equatable {
  let assertion: RockchipEvolutionCampaignConfirmationAssertion
  let candidate: RockchipEvolutionCandidatePin
  let review: RockchipEvolutionReviewReceipt

  package init(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    candidate: RockchipEvolutionCandidatePin,
    review: RockchipEvolutionReviewReceipt
  ) throws {
    try review.validate(candidate: candidate)
    guard candidate.baseCommitOID == assertion.baseCommitOID,
      candidate.toolchainDigestSHA256 == assertion.candidateToolchainDigestSHA256,
      candidate.changedFiles.count <= assertion.maxChangedFiles,
      candidate.changedLines <= assertion.maxDiffLines,
      candidate.strategy.operationReference == Self.operationReference(assertion),
      candidate.strategy.archiveDigestSHA256 == assertion.archiveDigestSHA256,
      candidate.strategy.stepSetDigestSHA256 == assertion.stepSetDigestSHA256,
      review.planDigestSHA256 == assertion.planDigestSHA256,
      candidate.changedFiles.allSatisfy(Self.isCandidateSource)
    else { throw RockchipEvolutionCampaignError.candidateRejected("campaignEnvelopeDrift") }
    self.assertion = assertion
    self.candidate = candidate
    self.review = review
  }

  public static func == (
    lhs: RockchipEvolutionCampaignAttemptPermit,
    rhs: RockchipEvolutionCampaignAttemptPermit
  ) -> Bool {
    lhs.assertion == rhs.assertion && lhs.candidate == rhs.candidate && lhs.review == rhs.review
  }

  private static func operationReference(
    _ assertion: RockchipEvolutionCampaignConfirmationAssertion
  ) -> String {
    _ = assertion
    return RockchipEvolutionCampaignConfirmationAssertion.operationReference
  }

  private static func isCandidateSource(_ path: String) -> Bool {
    let prefix = "Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/"
    return path.hasPrefix(prefix) && path.count > prefix.count && !path.contains("..")
      && !path.contains("\\")
  }
}

struct RockchipConsumedEvolutionCampaignAdmission: Sendable, Equatable {
  let authorizationReference: AgentExecutionAuthorityReference
  let usageReservation: AgentAuthorityUsageReservation
  let facts: RockchipTrustedAuthorizationFacts
}

/// Invocation-local token returned only after the merged broker has repeated
/// every campaign/candidate/review/live-fact comparison and durably reserved
/// this ordinal.  The campaign grants up to eight attempts; this token still
/// consumes exactly once.
final class RockchipEvolutionCampaignAdmission: @unchecked Sendable {
  let campaignID: String
  let ordinal: Int
  let sessionID: String
  let jobID: String
  let authorizationReference: AgentExecutionAuthorityReference
  let usageReservation: AgentAuthorityUsageReservation
  let facts: RockchipTrustedAuthorizationFacts

  private let lock = NSLock()
  private var consumed = false

  init(
    campaignID: String,
    ordinal: Int,
    sessionID: String,
    jobID: String,
    authorizationReference: AgentExecutionAuthorityReference,
    usageReservation: AgentAuthorityUsageReservation,
    facts: RockchipTrustedAuthorizationFacts
  ) {
    self.campaignID = campaignID
    self.ordinal = ordinal
    self.sessionID = sessionID
    self.jobID = jobID
    self.authorizationReference = authorizationReference
    self.usageReservation = usageReservation
    self.facts = facts
  }

  func consume(at current: RockchipTrustedClockReading) throws
    -> RockchipConsumedEvolutionCampaignAdmission
  {
    lock.lock()
    defer { lock.unlock() }
    guard !consumed else {
      throw RockchipEvolutionCampaignError.admissionRejected("attemptAlreadyConsumed")
    }
    consumed = true
    guard current.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds else {
      throw RockchipEvolutionCampaignError.admissionRejected("freshReadbackExpired")
    }
    return RockchipConsumedEvolutionCampaignAdmission(
      authorizationReference: authorizationReference,
      usageReservation: usageReservation,
      facts: facts)
  }
}

actor RockchipEvolutionCampaignAdmissionService {
  private let factCollector: any RockchipAuthorizationFactCollecting
  private let usageLedger: AgentAuthorityUsageLedger
  private let campaignLedger: RockchipEvolutionCampaignLedger
  private let clock: any RockchipAdmissionClock
  private let bindingSerialDigestSHA256: String
  private let bindingRevision: Int
  private let brokerExecutableDigest: @Sendable () throws -> String

  init(
    factCollector: any RockchipAuthorizationFactCollecting,
    usageLedger: AgentAuthorityUsageLedger,
    campaignLedger: RockchipEvolutionCampaignLedger,
    clock: any RockchipAdmissionClock,
    bindingSerialDigestSHA256: String,
    bindingRevision: Int,
    brokerExecutableDigest: @escaping @Sendable () throws -> String = {
      try ProductRockchipEvolutionCandidateBuilder.currentBrokerExecutableDigest()
    }
  ) {
    self.factCollector = factCollector
    self.usageLedger = usageLedger
    self.campaignLedger = campaignLedger
    self.clock = clock
    self.bindingSerialDigestSHA256 = bindingSerialDigestSHA256
    self.bindingRevision = bindingRevision
    self.brokerExecutableDigest = brokerExecutableDigest
  }

  func admit(
    permit: RockchipEvolutionCampaignAttemptPermit,
    facts request: RockchipAuthorizationFactRequest,
    sessionID: String,
    startingMode: RockchipEvolutionStartingMode
  ) async throws -> RockchipEvolutionCampaignAdmission {
    let assertion = permit.assertion
    let admittedAt = clock.now()
    guard assertion.isValid(at: admittedAt.auditTimestamp) else {
      throw RockchipEvolutionCampaignError.expired
    }
    guard assertion.targetStableIdentitySHA256 == bindingSerialDigestSHA256,
      bindingRevision >= assertion.bindingLineageRootRevision,
      try brokerExecutableDigest() == assertion.brokerExecutableDigestSHA256
    else { throw RockchipEvolutionCampaignError.admissionRejected("brokerOrTargetDrift") }
    guard permit.candidate.strategy.allowedStartingModes.contains(startingMode) else {
      throw RockchipEvolutionCampaignError.admissionRejected(
        "startingModeNotAllowed:\(startingMode.rawValue)")
    }
    let campaign = try campaignLedger.load(assertion.campaignID)
    guard campaign.assertion == assertion, !campaign.isTerminal,
      campaign.activeReservation == nil,
      let prepared = campaign.latestCandidate,
      prepared.candidate == permit.candidate, prepared.review == permit.review
    else { throw RockchipEvolutionCampaignError.admissionRejected("campaignLedgerDrift") }
    let reference = try assertion.authorityReference()
    let campaignReservationIDs = Set(
      campaign.events.compactMap { event in
        event.kind == .attemptReserved ? event.reservationID : nil
      })
    let orphanedGlobalUse = try usageLedger.load().reservations.contains { reservation in
      reservation.authorizationRef == reference
        && !campaignReservationIDs.contains(reservation.reservationID)
    }
    guard !orphanedGlobalUse else {
      _ = try? campaignLedger.stop(
        campaignID: assertion.campaignID, reasonCode: "orphanedGlobalReservation",
        at: admittedAt.auditTimestamp)
      throw RockchipEvolutionCampaignError.campaignStopped("orphanedGlobalReservation")
    }

    let expectation = RockchipAuthorizationFactExpectation(
      targetModel: RockchipFlashProfile.targetDeviceModel,
      serialDigestSHA256: bindingSerialDigestSHA256,
      bindingRevision: bindingRevision,
      firmwareArchiveSHA256: assertion.archiveDigestSHA256,
      transport: "usb",
      toolchainFingerprint: RockchipFlashProfile.pinnedToolchainFingerprint,
      providerIdentity: RockchipRockUSBFlashProvider.providerIdentity,
      planDigestSHA256: assertion.planDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      validUntil: assertion.validUntil)
    let facts: RockchipTrustedAuthorizationFacts
    do {
      facts = try await factCollector.collect(request: request, expectation: expectation)
    } catch let error as RockchipAuthorizationFactError {
      throw RockchipEvolutionCampaignError.admissionRejected("facts:\(error)")
    }
    guard facts.plan.planDigestSHA256 == assertion.planDigestSHA256,
      facts.plan.archiveSHA256 == assertion.archiveDigestSHA256,
      facts.plan.stepSetDigestSHA256 == assertion.stepSetDigestSHA256,
      facts.serialDigestSHA256 == assertion.targetStableIdentitySHA256,
      facts.bindingReference.revision >= assertion.bindingLineageRootRevision,
      facts.bindingReference.revision == bindingRevision,
      facts.executableIdentity.sha256
        == RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    else { throw RockchipEvolutionCampaignError.admissionRejected("materializedFactDrift") }

    let beforeReservation = clock.now()
    guard assertion.isValid(at: beforeReservation.auditTimestamp),
      beforeReservation.monotonicNanoseconds < facts.readbackDeadlineMonotonicNanoseconds,
      let reservationDate = RockchipStandingAuthorization.parseTimestamp(
        beforeReservation.auditTimestamp)
    else { throw RockchipEvolutionCampaignError.admissionRejected("preReserveFreshness") }
    let ordinal = campaign.reservedAttemptCount + 1
    guard ordinal <= assertion.maxAttempts else {
      throw RockchipEvolutionCampaignError.campaignStopped("attemptBudgetExhausted")
    }
    let reservationID = try AgentAuthorityUsageReservation.canonicalReservationID(
      authorizationRef: reference, jobID: request.jobID,
      operationDigestSHA256: assertion.planDigestSHA256,
      targetDigestSHA256: facts.targetDigestSHA256)
    let reservation = try AgentAuthorityUsageReservation(
      reservationID: reservationID, authorizationRef: reference,
      ordinal: ordinal, maximumUses: assertion.maxAttempts,
      maximumConcurrentJobs: RockchipEvolutionCampaignConfirmationAssertion.maximumConcurrency,
      jobID: request.jobID,
      operationDigestSHA256: assertion.planDigestSHA256,
      targetDigestSHA256: facts.targetDigestSHA256,
      reservedAt: beforeReservation.auditTimestamp,
      forwardLeaseExpiresAt: ISO8601DateFormatter().string(
        from: reservationDate.addingTimeInterval(30)),
      compensationLeaseExpiresAt: ISO8601DateFormatter().string(
        from: reservationDate.addingTimeInterval(120)))
    do { _ = try usageLedger.reserve(reservation) } catch let error as AuthorizationUsageLedgerError
    {
      throw RockchipEvolutionCampaignError.admissionRejected("usage:\(error)")
    }
    // Ordering is intentional. A crash after global reservation but before
    // this campaign event leaves an unresolved consumed use and therefore
    // fails closed; it never creates an unmetered attempt.
    do {
      _ = try campaignLedger.reserveAttempt(
        campaignID: assertion.campaignID,
        candidateID: permit.candidate.candidateID,
        reviewID: permit.review.reviewID,
        ordinal: ordinal, reservationID: reservation.reservationID,
        jobID: request.jobID, sessionID: sessionID,
        at: beforeReservation.auditTimestamp)
    } catch {
      _ = try? usageLedger.close(
        reservationID: reservation.reservationID,
        terminal: AgentAuthorityUsageTerminal(
          status: .outcomeUnknown, closedAt: beforeReservation.auditTimestamp,
          externalIntentEventIDs: []))
      _ = try? campaignLedger.stop(
        campaignID: assertion.campaignID, reasonCode: "reservationCorrelationUnknown",
        at: beforeReservation.auditTimestamp)
      throw error
    }
    return RockchipEvolutionCampaignAdmission(
      campaignID: assertion.campaignID, ordinal: ordinal,
      sessionID: sessionID, jobID: request.jobID,
      authorizationReference: reference,
      usageReservation: reservation, facts: facts)
  }
}
