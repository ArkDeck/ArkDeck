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
  /// Retired authority labels. The current Runtime never issues or emits
  /// them; they remain in the vocabulary only so the projector and the
  /// headless verifier refuse them by name instead of through an opaque
  /// decode failure. Neither can mint a Runtime capability, reach a device
  /// dispatcher, or become valid current evidence.
  case standingAuthorization
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
  /// Runtime capability correlation returned by the daemon with the consumed
  /// authority. Destructive evidence requires every one of them.
  public let planDigest: String?
  package let targetBindingDigest: String?
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
    planDigest: String? = nil,
    targetBindingDigest: String? = nil,
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
    self.planDigest = planDigest
    self.targetBindingDigest = targetBindingDigest
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
    case planDigest
    case targetBindingDigest
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
  case published(HardwareEvidenceRecord)
  case evidenceIncomplete(HardwareEvidenceIncomplete)
}

/// The one current real-hardware evidence record, the Swift twin of
/// `openspec/contracts/hardware-evidence.schema.json`. It carries every
/// safety correlation the Runtime can prove: executor and admission authority,
/// fresh target confirmation, reservation and use ordinal, actual typed step
/// kinds, plan/step-set/target/Artifact digests, and the complete-overwrite
/// recovery lineage with its uncertain effects, coverage, supersession,
/// postflight and terminal disposition. The label is fixed; there is no other
/// layout to select, migrate from, or fall back to.
package struct HardwareEvidenceRecord: Codable, Sendable, Equatable {
  package static let schemaVersion = "1.0.0"

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
    public let startedAt: String
    public let finishedAt: String
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
    public let epochId: String
    public let source: String
    public let coveredIntents: [CoveredIntent]
    public let uncertainEffectSetDigest: String
    public let coverageContractVersion: String
    public let coveredEffectSetDigest: String
    public let recoveryJobId: String
    public let recoveryIntentEventId: String
    public let operationReference: String
    public let profileReference: String
    public let planDigest: String
    public let artifactDigest: String
    public let providerExecutableDigest: String
    public let target: RecoveryTarget
    public let capability: RecoveryCapability?
    public let confirmedStepIds: [String]
    public let postflight: RecoveryPostflight
    public let resultingTargetEpochDigest: String
    public let originalOutcomesRemainUnknown: Bool
    public let originalJobsSucceeded: Bool

    public struct CoveredIntent: Codable, Sendable, Equatable {
      public let jobId: String
      public let intentEventId: String
      public let operationReference: String
      public let profileReference: String
      public let possibleEffects: [String]
    }

    public struct RecoveryTarget: Codable, Sendable, Equatable {
      public let stableIdentitySHA256: String
      public let bindingRevision: Int
      public let confirmationMethod: String
      public let confirmedAt: String
    }

    public struct RecoveryCapability: Codable, Sendable, Equatable {
      public let reference: String
      public let reservationId: String
      public let useOrdinal: Int
    }

    public struct RecoveryPostflight: Codable, Sendable, Equatable {
      public let flashReadbackConfirmed: Bool
      public let rebootConfirmed: Bool
      public let rebindConfirmed: Bool
      public let runtimeBuildConfirmed: Bool
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
    let terminal = schemaTerminalState(
      receipt.terminalState, outcomeUnknown: receipt.outcomeUnknown)
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
        reasons.append("retired authority kind cannot be emitted as hardware evidence")
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
      return incomplete(
        reasons + ["target/model/firmware/transport preflight facts are incomplete"])
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

    let projectedRecovery: HardwareEvidenceRecord.Recovery?
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
        || !ArkForgeFlashOperation.containsDurableRecordReference(
          recovery.operationReference)
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
      let recoveryCapability: HardwareEvidenceRecord.Recovery.RecoveryCapability?
      if recovery.source == "distinctRecoveryExecution" {
        if recovery.recoveryJobID == jobID,
          receipt.terminalState == "recovered",
          authority?.kind == .runtimeCapability,
          let capabilityReference = nonempty(authority?.reference),
          let reservationID = nonempty(authority?.reservationID),
          let useOrdinal = authority?.useOrdinal,
          useOrdinal >= 1
        {
          recoveryCapability = HardwareEvidenceRecord.Recovery.RecoveryCapability(
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
      projectedRecovery = HardwareEvidenceRecord.Recovery(
        disposition: "supersedingRecoveryEpoch",
        epochId: recovery.epochID,
        source: recovery.source,
        coveredIntents: recovery.coveredIntents.map {
          HardwareEvidenceRecord.Recovery.CoveredIntent(
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
        target: HardwareEvidenceRecord.Recovery.RecoveryTarget(
          stableIdentitySHA256: recovery.stableTargetIdentitySHA256,
          bindingRevision: recovery.bindingRevision,
          confirmationMethod: observation.confirmationMethod,
          confirmedAt: confirmed),
        capability: recoveryCapability,
        confirmedStepIds: recovery.confirmedStepIDs,
        postflight: HardwareEvidenceRecord.Recovery.RecoveryPostflight(
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
    let record = HardwareEvidenceRecord(
      schemaVersion: HardwareEvidenceRecord.schemaVersion,
      evidenceId: claims.evidenceID,
      executor: HardwareEvidenceRecord.Executor(
        kind: receipt.executor,
        id: receipt.executorID,
        authority: authority.map {
          HardwareEvidenceRecord.Authority(
            kind: $0.kind,
            reference: $0.reference,
            reservationId: $0.reservationID,
            useOrdinal: $0.useOrdinal,
            planDigest: $0.planDigest,
            stepSetDigest: $0.stepSetDigest,
            targetBindingDigest: $0.targetBindingDigest,
            artifactDigest: $0.artifactDigest)
        }),
      runtime: HardwareEvidenceRecord.Runtime(
        operationReference: receipt.operationReference,
        jobId: jobID,
        catalogDigest: receipt.catalogDigest,
        terminalState: terminal,
        startedAt: started,
        finishedAt: finished),
      targetConfirmation: HardwareEvidenceRecord.TargetConfirmation(
        confirmedDeviceIdentitySHA256: identity,
        bindingRevision: bindingRevision,
        confirmedAt: confirmed,
        method: observation.confirmationMethod),
      device: HardwareEvidenceRecord.Device(
        model: model,
        serialSHA256: identity,
        firmware: firmware,
        bindingRevision: bindingRevision),
      toolchain: HardwareEvidenceRecord.Toolchain(
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
        HardwareEvidenceRecord.Artifact(
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
    value.count == 64
      && value.allSatisfy {
        ("0"..."9").contains(String($0))
          || ("a"..."f").contains(String($0))
      }
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
    return suffix.count == 32
      && suffix.allSatisfy {
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
    }
      && suffix.allSatisfy {
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
    ISO8601Timestamps.parse(value)
  }
}

/// Refusals of the current evidence reader. Refused bytes are never rewritten,
/// relabelled or migrated.
package enum HardwareEvidenceRecordError: Error, Equatable, Sendable {
  case malformed(String)
  case unsupportedSchemaVersion(String)
}

extension HardwareEvidenceRecord {
  /// Reads exactly the record this writer produces. The label alone is not
  /// proof of compatibility: a document carrying another version, duplicate
  /// members, or any field shape other than the current complete one is
  /// refused, including documents that spell `1.0.0` over a different
  /// historical layout. Nothing here migrates, relabels or re-encodes bytes.
  package static func decode(_ data: Data) throws -> HardwareEvidenceRecord {
    var duplicates = StrictJSONDuplicateValidator(data: data)
    do {
      try duplicates.validate()
    } catch {
      throw HardwareEvidenceRecordError.malformed("evidence document has duplicate or malformed members")
    }
    let decoder = JSONDecoder()
    guard let supplied = try? decoder.decode(JSONValue.self, from: data),
      case .object(let fields) = supplied
    else {
      throw HardwareEvidenceRecordError.malformed("evidence document is not a JSON object")
    }
    guard case .string(let version)? = fields["schemaVersion"] else {
      throw HardwareEvidenceRecordError.malformed("evidence document has no schemaVersion")
    }
    guard version == schemaVersion else {
      throw HardwareEvidenceRecordError.unsupportedSchemaVersion(version)
    }
    guard let record = try? decoder.decode(HardwareEvidenceRecord.self, from: data),
      let current = try? decoder.decode(JSONValue.self, from: JSONEncoder().encode(record)),
      current == supplied
    else {
      throw HardwareEvidenceRecordError.malformed(
        "evidence document does not have the current complete field shape")
    }
    return record
  }
}
