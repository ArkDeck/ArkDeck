import ArkDeckCore
import Foundation

public enum RuntimeHardwareEvidenceEffectLevel: String, Codable, Sendable {
  case hostOnly
  case readOnly
  case deviceMutation
  case destructive
}

public enum RuntimeHardwareEvidenceAuthorityKind: String, Codable, Sendable {
  case defaultReadOnlyPolicy
  case runtimeCapability
  case standingAuthorization
  /// Historical campaign evidence. This is decode/export provenance only and
  /// can never mint a Runtime capability or reach a device dispatcher.
  case evolutionCampaignConfirmation
}

public struct RuntimeHardwareEvidenceAuthority: Codable, Sendable, Equatable {
  public let kind: RuntimeHardwareEvidenceAuthorityKind
  public let reference: String
  public let admittedAtUTC: String
  public let validUntilUTC: String?
  public let consumptionFingerprintSHA256: String?
  public let reservationID: String?
  public let useOrdinal: Int?
  public let stepSetDigest: String?
  public let artifactDigest: String?
  /// All campaign fields are daemon-owned durable correlation facts. They are
  /// optional only so older read-only snapshots remain decodable; a campaign
  /// record with any one missing is never published as hardware evidence.
  public let campaignID: String?
  public let attemptID: String?
  public let attemptOrdinal: Int?
  public let planDigest: String?
  public let targetBindingDigest: String?
  public let candidateDigest: String?
  public let reviewDigest: String?
  public let brokerDigest: String?

  public init(
    kind: RuntimeHardwareEvidenceAuthorityKind,
    reference: String,
    admittedAtUTC: String,
    validUntilUTC: String?,
    consumptionFingerprintSHA256: String?,
    reservationID: String? = nil,
    useOrdinal: Int? = nil,
    stepSetDigest: String? = nil,
    artifactDigest: String? = nil,
    campaignID: String? = nil,
    attemptID: String? = nil,
    attemptOrdinal: Int? = nil,
    planDigest: String? = nil,
    targetBindingDigest: String? = nil,
    candidateDigest: String? = nil,
    reviewDigest: String? = nil,
    brokerDigest: String? = nil
  ) {
    self.kind = kind
    self.reference = reference
    self.admittedAtUTC = admittedAtUTC
    self.validUntilUTC = validUntilUTC
    self.consumptionFingerprintSHA256 = consumptionFingerprintSHA256
    self.reservationID = reservationID
    self.useOrdinal = useOrdinal
    self.stepSetDigest = stepSetDigest
    self.artifactDigest = artifactDigest
    self.campaignID = campaignID
    self.attemptID = attemptID
    self.attemptOrdinal = attemptOrdinal
    self.planDigest = planDigest
    self.targetBindingDigest = targetBindingDigest
    self.candidateDigest = candidateDigest
    self.reviewDigest = reviewDigest
    self.brokerDigest = brokerDigest
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case reference
    case admittedAtUTC = "admittedAtUtc"
    case validUntilUTC = "validUntilUtc"
    case consumptionFingerprintSHA256 = "consumptionFingerprintSha256"
    case reservationID = "reservationId"
    case useOrdinal
    case stepSetDigest
    case artifactDigest
    case campaignID = "campaignId"
    case attemptID = "attemptId"
    case attemptOrdinal
    case planDigest
    case targetBindingDigest
    case candidateDigest
    case reviewDigest
    case brokerDigest
  }
}

public enum RuntimeHardwareEvidenceTransport: String, Codable, Sendable {
  case usb
  case tcp
  case uart
}

public struct RuntimeHardwareEvidencePreflightStep: Codable, Sendable, Equatable {
  public let stepID: String
  public let stepKind: String
  public let outcomeAtUTC: String

  public init(stepID: String, stepKind: String, outcomeAtUTC: String) {
    self.stepID = stepID
    self.stepKind = stepKind
    self.outcomeAtUTC = outcomeAtUTC
  }

  enum CodingKeys: String, CodingKey {
    case stepID = "stepId"
    case stepKind
    case outcomeAtUTC = "outcomeAtUtc"
  }
}

public struct RuntimeHardwareEvidenceObservation: Codable, Sendable, Equatable {
  public let targetID: String?
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let model: String?
  public let firmware: String?
  public let transport: RuntimeHardwareEvidenceTransport?
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let confirmedAtUTC: String?
  public let confirmationMethod: String
  public let preflightSteps: [RuntimeHardwareEvidencePreflightStep]

  enum CodingKeys: String, CodingKey {
    case targetID = "targetId"
    case bindingRevision
    case stableIdentitySHA256 = "stableIdentitySha256"
    case model
    case firmware
    case transport
    case providerID = "providerId"
    case toolVersion
    case toolSHA256 = "toolSha256"
    case confirmedAtUTC = "confirmedAtUtc"
    case confirmationMethod
    case preflightSteps
  }
}

public struct RuntimeHardwareEvidenceArtifact: Codable, Sendable, Equatable {
  public let reference: String
  public let sha256: String
  public let jobID: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let providerID: String
  public let byteCount: Int
  public let bytesVerified: Bool

  enum CodingKeys: String, CodingKey {
    case reference
    case sha256
    case jobID = "jobId"
    case targetID = "targetId"
    case bindingRevision
    case stableIdentitySHA256 = "stableIdentitySha256"
    case providerID = "providerId"
    case byteCount
    case bytesVerified
  }
}

public struct RuntimeHardwareEvidenceTrustedFacts: Codable, Sendable, Equatable {
  public let jobID: String
  public let operationReference: String
  public let catalogDigest: String
  public let targetID: String
  public let bindingRevision: Int?
  public let providerID: String
  public let actualEffect: RuntimeHardwareEvidenceEffectLevel?
  public let authority: RuntimeHardwareEvidenceAuthority?
  public let observation: RuntimeHardwareEvidenceObservation?
  public let actualStepKinds: [String]
  public let executionMode: String
  public let terminalState: String
  public let outcomeUnknown: Bool
  public let startedAtUTC: String?
  public let firstEvidenceStepAtUTC: String?
  public let finishedAtUTC: String?
  public let artifacts: [RuntimeHardwareEvidenceArtifact]
  public let blockers: [String]

  enum CodingKeys: String, CodingKey {
    case jobID = "jobId"
    case operationReference
    case catalogDigest
    case targetID = "targetId"
    case bindingRevision
    case providerID = "providerId"
    case actualEffect
    case authority
    case observation
    case actualStepKinds
    case executionMode
    case terminalState
    case outcomeUnknown
    case startedAtUTC = "startedAtUtc"
    case firstEvidenceStepAtUTC = "firstEvidenceStepAtUtc"
    case finishedAtUTC = "finishedAtUtc"
    case artifacts
    case blockers
  }
}

/// The only caller-supplied surface. None of these values can authorize or
/// describe device execution.
public struct HardwareEvidenceClaimMetadata: Sendable, Equatable {
  public let evidenceID: String
  public let acceptanceIDs: [String]
  public let validUntilUTC: String?
  public let notes: String?

  public init(
    evidenceID: String,
    acceptanceIDs: [String],
    validUntilUTC: String? = nil,
    notes: String? = nil
  ) {
    self.evidenceID = evidenceID
    self.acceptanceIDs = acceptanceIDs
    self.validUntilUTC = validUntilUTC
    self.notes = notes
  }
}

public struct HardwareEvidenceIncomplete: Sendable, Equatable {
  public let code = "evidenceIncomplete"
  public let reasons: [String]
  public let publicationCount = 0
}

public enum HardwareEvidenceProjectionResult: Sendable, Equatable {
  case published(HardwareEvidenceV5Record)
  case evidenceIncomplete(HardwareEvidenceIncomplete)
}

public struct HardwareEvidenceV5Record: Codable, Sendable, Equatable {
  public let schemaVersion: String
  public let evidenceId: String
  public let executor: Executor
  public let runtime: Runtime
  public let targetConfirmation: TargetConfirmation
  public let device: Device
  public let toolchain: Toolchain
  public let transport: RuntimeHardwareEvidenceTransport
  public let provider: String
  public let effectLevel: RuntimeHardwareEvidenceEffectLevel
  public let stepKinds: [String]
  public let acceptanceIds: [String]
  public let executedAt: String
  public let validUntil: String?
  public let artifacts: [Artifact]
  public let deviations: [String]?
  public let notes: String?

  public struct Executor: Codable, Sendable, Equatable {
    public let kind: RuntimeExecutorKind
    public let id: String
    public let authority: Authority?
  }

  public struct Authority: Codable, Sendable, Equatable {
    public let kind: RuntimeHardwareEvidenceAuthorityKind
    public let reference: String
    public let reservationId: String?
    public let useOrdinal: Int?
    public let planDigest: String?
    public let stepSetDigest: String?
    public let targetBindingDigest: String?
    public let artifactDigest: String?
  }

  public struct Runtime: Codable, Sendable, Equatable {
    public let operationReference: String
    public let jobId: String
    public let catalogDigest: String
    public let terminalState: String
    public let startedAt: String
    public let finishedAt: String
  }

  public struct TargetConfirmation: Codable, Sendable, Equatable {
    public let confirmedDeviceIdentitySHA256: String
    public let bindingRevision: Int
    public let confirmedAt: String
    public let method: String
  }

  public struct Device: Codable, Sendable, Equatable {
    public let model: String
    public let serialSHA256: String
    public let firmware: String
    public let bindingRevision: Int
  }

  public struct Toolchain: Codable, Sendable, Equatable {
    public let hdcVersion: String
    public let hdcSHA256: String
  }

  public struct Artifact: Codable, Sendable, Equatable {
    public let reference: String
    public let sha256: String
    public let note: String?
  }
}

/// Pure projection: no daemon client, provider, capability store or
/// dispatcher is reachable from this type.
public enum HardwareEvidenceProjector {
  public static func project(
    receipt: RuntimeAgentExecutionReceipt,
    claims: HardwareEvidenceClaimMetadata
  ) -> HardwareEvidenceProjectionResult {
    var reasons = receipt.evidenceBlockers
    guard let jobID = receipt.jobID, !jobID.isEmpty else {
      return incomplete(reasons + ["runtime.jobId is absent or empty"])
    }
    guard let targetID = receipt.targetID, !targetID.isEmpty else {
      return incomplete(reasons + ["runtime.targetId is absent or empty"])
    }
    guard let bindingRevision = receipt.bindingRevision, bindingRevision >= 1 else {
      return incomplete(reasons + ["runtime.bindingRevision is absent or invalid"])
    }
    guard let effect = receipt.actualEffect else {
      return incomplete(reasons + ["runtime.actualEffect is absent"])
    }
    guard let observation = receipt.evidenceObservation else {
      return incomplete(reasons + ["same-operation evidence preflight is absent"])
    }
    let started = receipt.startedAtUTC
    let finished = receipt.finishedAtUTC
    guard let firstEvidence = receipt.firstEvidenceStepAtUTC,
      let confirmed = observation.confirmedAtUTC
    else {
      return incomplete(reasons + ["runtime or confirmation timestamps are incomplete"])
    }

    if !validEvidenceID(claims.evidenceID) {
      reasons.append("claim evidenceId is malformed")
    }
    if receipt.executorID.isEmpty {
      reasons.append("executor id is empty")
    }
    if receipt.providerID.isEmpty {
      reasons.append("provider id is empty")
    }
    if claims.acceptanceIDs.isEmpty
      || Set(claims.acceptanceIDs).count != claims.acceptanceIDs.count
      || !claims.acceptanceIDs.allSatisfy(validAcceptanceID)
    {
      reasons.append("claim acceptanceIds are empty, duplicated, or malformed")
    }
    if receipt.executionMode != "execute" {
      reasons.append("execution mode is not execute")
    }
    if receipt.outcomeUnknown {
      reasons.append("runtime outcome is unknown")
    }
    let terminal = schemaTerminalState(receipt.terminalState, outcomeUnknown: receipt.outcomeUnknown)
    if terminal == nil {
      reasons.append("terminal state is not evidence-representable")
    }
    if !validOperationReference(receipt.operationReference) {
      reasons.append("operation reference is malformed")
    }
    if !validSHA256(receipt.catalogDigest) {
      reasons.append("catalog digest is malformed")
    }
    if receipt.stepKinds.isEmpty || Set(receipt.stepKinds).count != receipt.stepKinds.count
      || receipt.stepKinds.contains(where: { $0.isEmpty })
    {
      reasons.append("actual step kinds are empty, duplicated, or malformed")
    }
    guard let startDate = parseDate(started), let finishDate = parseDate(finished),
      let confirmationDate = parseDate(confirmed), let firstEvidenceDate = parseDate(firstEvidence)
    else {
      return incomplete(reasons + ["runtime or confirmation timestamp is malformed"])
    }
    if startDate > finishDate {
      reasons.append("runtime finish precedes start")
    }
    if confirmationDate < startDate || confirmationDate > firstEvidenceDate {
      reasons.append("target confirmation is stale or follows evidence-bearing capture")
    }
    if firstEvidenceDate > finishDate {
      reasons.append("evidence-bearing step follows runtime finish")
    }
    if let validUntil = claims.validUntilUTC {
      guard let validUntilDate = parseDate(validUntil), validUntilDate >= finishDate else {
        return incomplete(reasons + ["claim validUntil is malformed or precedes execution"])
      }
    }

    let authority = receipt.authority
    let authorityMatchesEffect: Bool
    switch effect {
    case .hostOnly, .readOnly:
      authorityMatchesEffect = authority?.kind == .defaultReadOnlyPolicy
    case .deviceMutation, .destructive:
      authorityMatchesEffect = authority?.kind == .runtimeCapability
    }
    if receipt.executor == .agent {
      if !authorityMatchesEffect || authority?.reference.isEmpty != false {
        reasons.append("actual effect and admission authority do not match")
      }
      if observation.confirmationMethod != "machineReadback" {
        reasons.append("Agent evidence confirmation is not machineReadback")
      }
    } else if authority != nil {
      reasons.append("human evidence carries an Agent authority")
    }
    if let authority {
      guard let admitted = parseDate(authority.admittedAtUTC), admitted <= startDate else {
        return incomplete(reasons + ["admission timestamp is missing or follows execution"])
      }
      if let expiry = authority.validUntilUTC {
        guard let expiryDate = parseDate(expiry), expiryDate >= finishDate else {
          return incomplete(reasons + ["admission authority expired before execution finished"])
        }
      }
      if authority.kind != .defaultReadOnlyPolicy,
        !validSHA256(authority.consumptionFingerprintSHA256 ?? "")
      {
        reasons.append("capability consumption fingerprint is absent or malformed")
      }
      if authority.kind == .standingAuthorization
        || authority.kind == .evolutionCampaignConfirmation
      {
        reasons.append("legacy authority kind cannot be emitted as V5 evidence")
      }
      if effect == .destructive, authority.kind == .runtimeCapability {
        guard
          nonempty(authority.reservationID) != nil,
          let useOrdinal = authority.useOrdinal,
          useOrdinal >= 1,
          let planDigest = authority.planDigest,
          let stepSetDigest = authority.stepSetDigest,
          let targetBindingDigest = authority.targetBindingDigest,
          let artifactDigest = authority.artifactDigest,
          [planDigest, stepSetDigest, targetBindingDigest, artifactDigest]
            .allSatisfy(validSHA256),
          receipt.artifacts.contains(where: { $0.sha256 == artifactDigest })
        else {
          reasons.append("Runtime capability correlation is absent, malformed, or drifted")
          return incomplete(reasons)
        }
      }
    }

    guard let observedTargetID = observation.targetID,
      let observedBinding = observation.bindingRevision,
      let identity = observation.stableIdentitySHA256,
      let model = nonempty(observation.model),
      let firmware = nonempty(observation.firmware),
      let transport = observation.transport
    else {
      return incomplete(reasons + ["target/model/firmware/transport preflight facts are incomplete"])
    }
    if observedTargetID != targetID || observedBinding != bindingRevision {
      reasons.append("preflight target or binding does not match the job")
    }
    if !validSHA256(identity) {
      reasons.append("stable device identity is not a lowercase SHA-256 digest")
    }
    if observation.providerID != receipt.providerID {
      reasons.append("preflight provider does not match the job")
    }
    if nonempty(observation.toolVersion) == nil || !validSHA256(observation.toolSHA256) {
      reasons.append("toolchain facts are incomplete or malformed")
    }
    let expectedPreflight: [(String, String)] = [
      ("confirm-evidence-target", "probeDevice"),
      ("read-evidence-model", "runApprovedRemoteRead"),
      ("read-evidence-firmware", "runApprovedRemoteRead"),
    ]
    if observation.preflightSteps.count != expectedPreflight.count
      || !zip(observation.preflightSteps, expectedPreflight).allSatisfy({ actual, expected in
        actual.stepID == expected.0 && actual.stepKind == expected.1
          && receipt.stepKinds.contains(actual.stepKind)
      })
    {
      reasons.append("three-step preflight is absent, reordered, or not typed")
    } else {
      let preflightDates = observation.preflightSteps.compactMap {
        parseDate($0.outcomeAtUTC)
      }
      if preflightDates.count != expectedPreflight.count
        || preflightDates != preflightDates.sorted()
        || preflightDates.contains(where: { $0 < startDate || $0 > firstEvidenceDate })
        || observation.preflightSteps.last?.outcomeAtUTC != confirmed
      {
        reasons.append("preflight outcome times are malformed, stale, or follow evidence capture")
      }
    }

    if receipt.artifacts.isEmpty {
      reasons.append("no verified immutable artifacts are available")
    }
    for artifact in receipt.artifacts {
      if !artifact.bytesVerified || !validSHA256(artifact.sha256)
        || artifact.reference.isEmpty || artifact.byteCount < 0
      {
        reasons.append("artifact bytes/hash are unverifiable")
      }
      if artifact.jobID != jobID || artifact.targetID != targetID
        || artifact.bindingRevision != bindingRevision
        || artifact.providerID != receipt.providerID
      {
        reasons.append("artifact job/target/binding/provider correlation mismatch")
      }
      if let artifactIdentity = artifact.stableIdentitySHA256, artifactIdentity != identity {
        reasons.append("artifact stable identity does not match preflight")
      }
    }

    guard reasons.isEmpty, let terminal else { return incomplete(reasons) }
    let record = HardwareEvidenceV5Record(
      schemaVersion: "5.0.0",
      evidenceId: claims.evidenceID,
      executor: HardwareEvidenceV5Record.Executor(
        kind: receipt.executor,
        id: receipt.executorID,
        authority: authority.map {
          HardwareEvidenceV5Record.Authority(
            kind: $0.kind,
            reference: $0.reference,
            reservationId: $0.reservationID,
            useOrdinal: $0.useOrdinal,
            planDigest: $0.planDigest,
            stepSetDigest: $0.stepSetDigest,
            targetBindingDigest: $0.targetBindingDigest,
            artifactDigest: $0.artifactDigest)
        }),
      runtime: HardwareEvidenceV5Record.Runtime(
        operationReference: receipt.operationReference,
        jobId: jobID,
        catalogDigest: receipt.catalogDigest,
        terminalState: terminal,
        startedAt: started,
        finishedAt: finished),
      targetConfirmation: HardwareEvidenceV5Record.TargetConfirmation(
        confirmedDeviceIdentitySHA256: identity,
        bindingRevision: bindingRevision,
        confirmedAt: confirmed,
        method: observation.confirmationMethod),
      device: HardwareEvidenceV5Record.Device(
        model: model,
        serialSHA256: identity,
        firmware: firmware,
        bindingRevision: bindingRevision),
      toolchain: HardwareEvidenceV5Record.Toolchain(
        hdcVersion: observation.toolVersion,
        hdcSHA256: observation.toolSHA256),
      transport: transport,
      provider: receipt.providerID,
      effectLevel: effect,
      stepKinds: receipt.stepKinds,
      acceptanceIds: claims.acceptanceIDs,
      executedAt: finished,
      validUntil: claims.validUntilUTC,
      artifacts: receipt.artifacts.map {
        HardwareEvidenceV5Record.Artifact(
          reference: $0.reference, sha256: $0.sha256, note: nil)
      },
      deviations: nil,
      notes: claims.notes)
    return .published(record)
  }

  private static func incomplete(_ reasons: [String]) -> HardwareEvidenceProjectionResult {
    .evidenceIncomplete(
      HardwareEvidenceIncomplete(
        reasons: Array(Set(reasons.isEmpty ? ["trusted evidence facts are incomplete"] : reasons))
          .sorted()))
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { ("0"..."9").contains(String($0))
      || ("a"..."f").contains(String($0)) }
  }

  private static func validEvidenceID(_ value: String) -> Bool {
    guard value.hasPrefix("EVD-"), value.count > 4 else { return false }
    return value.dropFirst(4).allSatisfy {
      $0.isASCII && ($0.isUppercase || $0.isNumber || "._-".contains($0))
    }
  }

  private static func validAcceptanceID(_ value: String) -> Bool {
    guard let separator = value.firstIndex(of: "-"),
      separator != value.startIndex,
      let first = value.first,
      first.isASCII,
      first.isUppercase
    else { return false }
    let suffixStart = value.index(after: separator)
    guard suffixStart != value.endIndex else { return false }
    let prefix = value[..<separator]
    let suffix = value[suffixStart...]
    return prefix.allSatisfy {
      $0.isASCII && ($0.isUppercase || $0.isNumber)
    } && suffix.allSatisfy {
      $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "-")
    }
  }

  private static func validOperationReference(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, let version = Int(parts[1]), version > 0,
      let first = parts[0].first, first.isLowercase
    else { return false }
    return parts[0].allSatisfy {
      $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-")
    }
  }

  private static func schemaTerminalState(
    _ value: String, outcomeUnknown: Bool
  ) -> String? {
    if outcomeUnknown { return "outcomeUnknown" }
    switch value {
    case "succeeded", "partial", "failed", "cancelled": return value
    default: return nil
    }
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// Read-only compatibility discriminator. Historical V2-V4 bytes are returned
/// untouched; the V5 writer never attempts to migrate or re-encode them.
public enum HardwareEvidenceDocumentReader {
  public enum Version: String, Sendable, Equatable {
    case legacyV2 = "2.0.0"
    case legacyV3 = "3.0.0"
    case legacyV4 = "4.0.0"
    case currentV5 = "5.0.0"
  }

  public static func version(of data: Data) -> Version? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let fields) = value,
      case .string(let version)? = fields["schemaVersion"]
    else { return nil }
    return Version(rawValue: version)
  }
}
