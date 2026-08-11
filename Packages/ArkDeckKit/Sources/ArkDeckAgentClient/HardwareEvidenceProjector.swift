import ArkDeckCore
import CryptoKit
import Foundation

package enum RuntimeHardwareEvidenceEffectLevel: String, Codable, Sendable {
  case hostOnly
  case readOnly
  case deviceMutation
  case destructive
}

package enum RuntimeHardwareEvidenceAuthorityKind: String, Codable, Sendable {
  case defaultReadOnlyPolicy
  case runtimeCapability
  case standingAuthorization
  /// Historical campaign evidence. This is decode/export provenance only and
  /// can never mint a Runtime capability or reach a device dispatcher.
  case evolutionCampaignConfirmation
}

package struct RuntimeHardwareEvidenceAuthority: Codable, Sendable, Equatable {
  public let kind: RuntimeHardwareEvidenceAuthorityKind
  public let reference: String
  public let admittedAtUTC: String
  public let validUntilUTC: String?
  public let consumptionFingerprintSHA256: String?
  public let reservationID: String?
  public let useOrdinal: Int?
  public let stepSetDigest: String?
  package let artifactDigest: String?
  /// All campaign fields are daemon-owned durable correlation facts. They are
  /// optional only so older read-only snapshots remain decodable; a campaign
  /// record with any one missing is never published as hardware evidence.
  public let campaignID: String?
  public let attemptID: String?
  public let attemptOrdinal: Int?
  public let planDigest: String?
  package let targetBindingDigest: String?
  package let candidateDigest: String?
  package let reviewDigest: String?
  package let brokerDigest: String?
  /// Complete-overwrite lineage returned by the daemon with the consumed
  /// authority. Keeping it in an existing receipt field preserves the
  /// one-shot Agent runner's stable wire/storage shape.
  public let recoveryEpoch: RuntimeHardwareEvidenceRecoveryEpoch?

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
    brokerDigest: String? = nil,
    recoveryEpoch: RuntimeHardwareEvidenceRecoveryEpoch? = nil
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
    self.recoveryEpoch = recoveryEpoch
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
    case recoveryEpoch
  }
}

extension RuntimeAgentExecutionReceipt {
  var recoveryEpoch: RuntimeHardwareEvidenceRecoveryEpoch? {
    authority?.recoveryEpoch
  }
}

package enum RuntimeHardwareEvidenceTransport: String, Codable, Sendable {
  case usb
  case tcp
  case uart
}

package struct RuntimeHardwareEvidencePreflightStep: Codable, Sendable, Equatable {
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

package struct RuntimeHardwareEvidenceObservation: Codable, Sendable, Equatable {
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

package struct RuntimeHardwareEvidenceArtifact: Codable, Sendable, Equatable {
  public let reference: String
  public let sha256: String
  public let jobID: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let providerID: String
  public let byteCount: Int
  package let bytesVerified: Bool

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

package struct RuntimeHardwareEvidenceRecoveryEpoch: Codable, Sendable, Equatable {
  package struct CoveredIntent: Codable, Sendable, Equatable {
    public let jobID: String
    public let intentEventID: String
    public let operationReference: String
    public let profileReference: String
    package let observedAtUTC: String
    package let possibleEffects: [String]

    enum CodingKeys: String, CodingKey {
      case jobID = "jobId"
      case intentEventID = "intentEventId"
      case operationReference
      case profileReference
      case observedAtUTC = "observedAtUtc"
      case possibleEffects
    }
  }

  package let epochID: String
  public let source: String
  package let stableTargetIdentitySHA256: String
  public let bindingRevision: Int
  package let coveredIntents: [CoveredIntent]
  package let uncertainEffectSetSHA256: String
  package let coverageContractVersion: String
  package let coveredEffectSetSHA256: String
  package let recoveryJobID: String
  package let recoveryIntentEventID: String
  public let operationReference: String
  public let profileReference: String
  package let materializedPlanDigestSHA256: String
  public let artifactSHA256: String
  public let providerExecutableSHA256: String
  package let confirmedStepIDs: [String]
  package let resultingTargetEpochSHA256: String
  package let establishedAtUTC: String
  package let epochSHA256: String

  enum CodingKeys: String, CodingKey {
    case epochID = "epochId"
    case source
    case stableTargetIdentitySHA256 = "stableTargetIdentitySha256"
    case bindingRevision
    case coveredIntents
    case uncertainEffectSetSHA256 = "uncertainEffectSetSha256"
    case coverageContractVersion
    case coveredEffectSetSHA256 = "coveredEffectSetSha256"
    case recoveryJobID = "recoveryJobId"
    case recoveryIntentEventID = "recoveryIntentEventId"
    case operationReference
    case profileReference
    case materializedPlanDigestSHA256 = "materializedPlanDigestSha256"
    case artifactSHA256 = "artifactSha256"
    case providerExecutableSHA256 = "providerExecutableSha256"
    case confirmedStepIDs = "confirmedStepIds"
    case resultingTargetEpochSHA256 = "resultingTargetEpochSha256"
    case establishedAtUTC = "establishedAtUtc"
    case epochSHA256 = "epochSha256"
  }
}

package struct RuntimeHardwareEvidenceTrustedFacts: Codable, Sendable, Equatable {
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
  public let recoveryEpoch: RuntimeHardwareEvidenceRecoveryEpoch?
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
    case recoveryEpoch
    case artifacts
    case blockers
  }
}

/// The only caller-supplied surface. None of these values can authorize or
/// describe device execution.
package struct HardwareEvidenceClaimMetadata: Sendable, Equatable {
  package let evidenceID: String
  package let acceptanceIDs: [String]
  public let validUntilUTC: String?
  package let notes: String?

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

package struct HardwareEvidenceIncomplete: Sendable, Equatable {
  public let code = "evidenceIncomplete"
  public let reasons: [String]
  package let publicationCount = 0
}

package enum HardwareEvidenceProjectionResult: Sendable, Equatable {
  case published(HardwareEvidenceV6Record)
  case evidenceIncomplete(HardwareEvidenceIncomplete)
}

package struct HardwareEvidenceV6Record: Codable, Sendable, Equatable {
  public let schemaVersion: String
  package let evidenceId: String
  public let executor: Executor
  public let runtime: Runtime
  package let targetConfirmation: TargetConfirmation
  public let device: Device
  public let toolchain: Toolchain
  public let transport: RuntimeHardwareEvidenceTransport
  public let provider: String
  package let effectLevel: RuntimeHardwareEvidenceEffectLevel
  package let stepKinds: [String]
  package let acceptanceIds: [String]
  package let executedAt: String
  public let validUntil: String?
  public let artifacts: [Artifact]
  public let recovery: Recovery?
  package let deviations: [String]?
  package let notes: String?

  package struct Executor: Codable, Sendable, Equatable {
    public let kind: RuntimeExecutorKind
    public let id: String
    public let authority: Authority?
  }

  package struct Authority: Codable, Sendable, Equatable {
    public let kind: RuntimeHardwareEvidenceAuthorityKind
    public let reference: String
    package let reservationId: String?
    public let useOrdinal: Int?
    public let planDigest: String?
    public let stepSetDigest: String?
    package let targetBindingDigest: String?
    package let artifactDigest: String?
  }

  public struct Runtime: Codable, Sendable, Equatable {
    public let operationReference: String
    public let jobId: String
    public let catalogDigest: String
    public let terminalState: String
    package let startedAt: String
    package let finishedAt: String
  }

  package struct TargetConfirmation: Codable, Sendable, Equatable {
    package let confirmedDeviceIdentitySHA256: String
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

  package struct Toolchain: Codable, Sendable, Equatable {
    package let hdcVersion: String
    package let hdcSHA256: String
  }

  public struct Artifact: Codable, Sendable, Equatable {
    public let reference: String
    public let sha256: String
    public let note: String?
  }

  public struct Recovery: Codable, Sendable, Equatable {
    public let disposition: String
    package let epochId: String
    public let source: String
    package let coveredIntents: [CoveredIntent]
    package let uncertainEffectSetDigest: String
    package let coverageContractVersion: String
    package let coveredEffectSetDigest: String
    package let recoveryJobId: String
    package let recoveryIntentEventId: String
    public let operationReference: String
    public let profileReference: String
    public let planDigest: String
    package let artifactDigest: String
    package let providerExecutableDigest: String
    public let target: RecoveryTarget
    public let capability: RecoveryCapability?
    package let confirmedStepIds: [String]
    public let postflight: RecoveryPostflight
    package let resultingTargetEpochDigest: String
    package let originalOutcomesRemainUnknown: Bool
    package let originalJobsSucceeded: Bool

    package struct CoveredIntent: Codable, Sendable, Equatable {
      public let jobId: String
      package let intentEventId: String
      public let operationReference: String
      public let profileReference: String
      package let possibleEffects: [String]
    }

    package struct RecoveryTarget: Codable, Sendable, Equatable {
      public let stableIdentitySHA256: String
      public let bindingRevision: Int
      public let confirmationMethod: String
      public let confirmedAt: String
    }

    package struct RecoveryCapability: Codable, Sendable, Equatable {
      public let reference: String
      package let reservationId: String
      public let useOrdinal: Int
    }

    package struct RecoveryPostflight: Codable, Sendable, Equatable {
      package let flashReadbackConfirmed: Bool
      package let rebootConfirmed: Bool
      package let rebindConfirmed: Bool
      package let runtimeBuildConfirmed: Bool
    }
  }
}

/// Pure projection: no daemon client, provider, capability store or
/// dispatcher is reachable from this type.
package enum HardwareEvidenceProjector {
  package static func project(
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
        reasons.append("legacy authority kind cannot be emitted as V6 evidence")
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

    let projectedRecovery: HardwareEvidenceV6Record.Recovery?
    if let recovery = receipt.recoveryEpoch {
      let requiredSteps: Set<String> = [
        "flash-partitions", "verify-flash-readback", "reboot-device", "wait-for-hdc",
        "rebind-and-verify-build",
      ]
      let possibleEffects = recovery.coveredIntents.flatMap(\.possibleEffects)
      let recoveryHashes = [
        recovery.stableTargetIdentitySHA256,
        recovery.uncertainEffectSetSHA256,
        recovery.coveredEffectSetSHA256,
        recovery.materializedPlanDigestSHA256,
        recovery.artifactSHA256,
        recovery.providerExecutableSHA256,
        recovery.resultingTargetEpochSHA256,
        recovery.epochSHA256,
      ]
      if effect != .destructive {
        reasons.append("recovery lineage is attached to a non-destructive run")
      }
      if recovery.source != "historicalRecognition"
        && recovery.source != "distinctRecoveryExecution"
      {
        reasons.append("recovery source is unknown")
      }
      if recoveryHashes.contains(where: { !validSHA256($0) })
        || !validRecoveryEpochID(recovery.epochID)
        || recovery.recoveryJobID.isEmpty
        || recovery.recoveryIntentEventID.isEmpty
        || recovery.coverageContractVersion.isEmpty
        || !validOperationReference(recovery.operationReference)
        || recovery.operationReference != "flash.dayu200"
        || recovery.profileReference != "dayu200"
      {
        reasons.append("recovery identity, plan, Artifact, tool, or epoch facts are malformed")
      }
      if recovery.stableTargetIdentitySHA256 != identity
        || recovery.bindingRevision != bindingRevision
      {
        reasons.append("recovery target identity or binding does not match fresh confirmation")
      }
      if recovery.operationReference != receipt.operationReference
        || recovery.materializedPlanDigestSHA256 != authority?.planDigest
        || recovery.artifactSHA256 != authority?.artifactDigest
        || recovery.providerExecutableSHA256 != observation.toolSHA256
        || !receipt.artifacts.contains(where: { $0.sha256 == recovery.artifactSHA256 })
      {
        reasons.append("recovery operation, plan, Artifact, or tool correlation drifted")
      }
      if recovery.coveredIntents.isEmpty
        || recovery.coveredIntents.contains(where: {
          $0.jobID.isEmpty || $0.intentEventID.isEmpty
            || $0.possibleEffects.isEmpty
            || Set($0.possibleEffects).count != $0.possibleEffects.count
        })
        || effectSetDigest(possibleEffects) != recovery.uncertainEffectSetSHA256
      {
        reasons.append("recovery uncertain-effect lineage is incomplete or drifted")
      }
      if !requiredSteps.isSubset(of: Set(recovery.confirmedStepIDs))
        || Set(recovery.confirmedStepIDs).count != recovery.confirmedStepIDs.count
      {
        reasons.append("recovery typed outcomes or postflight are incomplete")
      }
      let establishedAt = parseDate(recovery.establishedAtUTC)
      if establishedAt == nil || establishedAt! > finishDate {
        reasons.append("recovery epoch time is malformed or follows evidence execution")
      }
      let recoveryCapability: HardwareEvidenceV6Record.Recovery.RecoveryCapability?
      if recovery.source == "distinctRecoveryExecution" {
        if recovery.recoveryJobID == jobID,
          receipt.terminalState == "recovered",
          authority?.kind == .runtimeCapability,
          let capabilityReference = nonempty(authority?.reference),
          let reservationID = nonempty(authority?.reservationID),
          let useOrdinal = authority?.useOrdinal,
          useOrdinal >= 1
        {
          recoveryCapability = HardwareEvidenceV6Record.Recovery.RecoveryCapability(
            reference: capabilityReference,
            reservationId: reservationID,
            useOrdinal: useOrdinal)
        } else {
          reasons.append("distinct recovery capability, Job, or terminal lineage is incomplete")
          recoveryCapability = nil
        }
      } else {
        recoveryCapability = nil
      }
      projectedRecovery = HardwareEvidenceV6Record.Recovery(
        disposition: "supersedingRecoveryEpoch",
        epochId: recovery.epochID,
        source: recovery.source,
        coveredIntents: recovery.coveredIntents.map {
          HardwareEvidenceV6Record.Recovery.CoveredIntent(
            jobId: $0.jobID, intentEventId: $0.intentEventID,
            operationReference: $0.operationReference,
            profileReference: $0.profileReference,
            possibleEffects: $0.possibleEffects)
        },
        uncertainEffectSetDigest: recovery.uncertainEffectSetSHA256,
        coverageContractVersion: recovery.coverageContractVersion,
        coveredEffectSetDigest: recovery.coveredEffectSetSHA256,
        recoveryJobId: recovery.recoveryJobID,
        recoveryIntentEventId: recovery.recoveryIntentEventID,
        operationReference: recovery.operationReference,
        profileReference: recovery.profileReference,
        planDigest: recovery.materializedPlanDigestSHA256,
        artifactDigest: recovery.artifactSHA256,
        providerExecutableDigest: recovery.providerExecutableSHA256,
        target: HardwareEvidenceV6Record.Recovery.RecoveryTarget(
          stableIdentitySHA256: recovery.stableTargetIdentitySHA256,
          bindingRevision: recovery.bindingRevision,
          confirmationMethod: observation.confirmationMethod,
          confirmedAt: confirmed),
        capability: recoveryCapability,
        confirmedStepIds: recovery.confirmedStepIDs,
        postflight: HardwareEvidenceV6Record.Recovery.RecoveryPostflight(
          flashReadbackConfirmed: true,
          rebootConfirmed: true,
          rebindConfirmed: true,
          runtimeBuildConfirmed: true),
        resultingTargetEpochDigest: recovery.resultingTargetEpochSHA256,
        originalOutcomesRemainUnknown: true,
        originalJobsSucceeded: false)
    } else {
      if receipt.terminalState == "recovered" {
        reasons.append("recovered terminal is missing durable recovery lineage")
      }
      projectedRecovery = nil
    }

    guard reasons.isEmpty, let terminal else { return incomplete(reasons) }
    let record = HardwareEvidenceV6Record(
      schemaVersion: "6.0.0",
      evidenceId: claims.evidenceID,
      executor: HardwareEvidenceV6Record.Executor(
        kind: receipt.executor,
        id: receipt.executorID,
        authority: authority.map {
          HardwareEvidenceV6Record.Authority(
            kind: $0.kind,
            reference: $0.reference,
            reservationId: $0.reservationID,
            useOrdinal: $0.useOrdinal,
            planDigest: $0.planDigest,
            stepSetDigest: $0.stepSetDigest,
            targetBindingDigest: $0.targetBindingDigest,
            artifactDigest: $0.artifactDigest)
        }),
      runtime: HardwareEvidenceV6Record.Runtime(
        operationReference: receipt.operationReference,
        jobId: jobID,
        catalogDigest: receipt.catalogDigest,
        terminalState: terminal,
        startedAt: started,
        finishedAt: finished),
      targetConfirmation: HardwareEvidenceV6Record.TargetConfirmation(
        confirmedDeviceIdentitySHA256: identity,
        bindingRevision: bindingRevision,
        confirmedAt: confirmed,
        method: observation.confirmationMethod),
      device: HardwareEvidenceV6Record.Device(
        model: model,
        serialSHA256: identity,
        firmware: firmware,
        bindingRevision: bindingRevision),
      toolchain: HardwareEvidenceV6Record.Toolchain(
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
        HardwareEvidenceV6Record.Artifact(
          reference: $0.reference, sha256: $0.sha256, note: nil)
      },
      recovery: projectedRecovery,
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

  private static func effectSetDigest(_ effects: [String]) -> String {
    let bytes = Data(Array(Set(effects)).sorted().joined(separator: "\n").utf8)
    return SHA256Hex.string(of: bytes)
  }

  private static func validEvidenceID(_ value: String) -> Bool {
    guard value.hasPrefix("EVD-"), value.count > 4 else { return false }
    return value.dropFirst(4).allSatisfy {
      $0.isASCII && ($0.isUppercase || $0.isNumber || "._-".contains($0))
    }
  }

  private static func validRecoveryEpochID(_ value: String) -> Bool {
    guard value.hasPrefix("recovery-epoch-") else { return false }
    let suffix = value.dropFirst("recovery-epoch-".count)
    return suffix.count == 32 && suffix.allSatisfy {
      $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))
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
    guard parts.count == 1 || parts.count == 2,
      let first = parts[0].first, first.isLowercase
    else { return false }
    if parts.count == 2 {
      guard let version = Int(parts[1]), version > 0 else { return false }
    }
    return parts[0].allSatisfy {
      $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-")
    }
  }

  private static func schemaTerminalState(
    _ value: String, outcomeUnknown: Bool
  ) -> String? {
    if outcomeUnknown { return "outcomeUnknown" }
    switch value {
    case "succeeded", "recovered", "partial", "failed", "cancelled": return value
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

/// Read-only compatibility discriminator. Historical V1-V5 bytes are returned
/// untouched; the V6 writer never attempts to migrate or re-encode them.
package enum HardwareEvidenceDocumentReader {
  package enum Version: String, Sendable, Equatable {
    case legacyV1 = "1.0.0"
    case legacyV2 = "2.0.0"
    case legacyV3 = "3.0.0"
    case legacyV4 = "4.0.0"
    case legacyV5 = "5.0.0"
    case currentV6 = "6.0.0"
  }

  public static func version(of data: Data) -> Version? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let fields) = value,
      case .string(let version)? = fields["schemaVersion"]
    else { return nil }
    return Version(rawValue: version)
  }
}
