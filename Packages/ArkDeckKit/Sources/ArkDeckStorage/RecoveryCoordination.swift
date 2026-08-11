import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum SupersedingRecoverySource: String, Codable, Sendable {
  /// A complete later Job was already present in immutable Runtime history;
  /// recognizing it performs no provider or device dispatch.
  case historicalRecognition
  /// Protected Runtime admitted and executed a new, distinct overwrite Job.
  case distinctRecoveryExecution
}

public struct SupersededRecoveryIntent: Codable, Equatable, Sendable {
  public let jobID: String
  public let intentEventID: String
  public let operationReference: String
  public let profileReference: String
  public let observedAtUTC: String
  public let possibleEffects: [String]

  public init(
    jobID: String, intentEventID: String, operationReference: String,
    profileReference: String, observedAtUTC: String, possibleEffects: [String]
  ) {
    self.jobID = jobID
    self.intentEventID = intentEventID
    self.operationReference = operationReference
    self.profileReference = profileReference
    self.observedAtUTC = observedAtUTC
    self.possibleEffects = possibleEffects
  }
}

public struct SupersedingRecoveryEpochDraft: Equatable, Sendable {
  public let source: SupersedingRecoverySource
  public let stableTargetIdentitySHA256: String
  public let bindingRevision: Int
  public let coveredIntents: [SupersededRecoveryIntent]
  public let uncertainEffectSetSHA256: String
  public let coverageContractVersion: String
  public let coveredEffectSetSHA256: String
  public let recoveryJobID: String
  public let recoveryIntentEventID: String
  public let operationReference: String
  public let profileReference: String
  public let materializedPlanDigestSHA256: String
  public let artifactSHA256: String
  public let providerExecutableSHA256: String
  public let confirmedStepIDs: [String]
  public let resultingTargetEpochSHA256: String
  public let establishedAtUTC: String

  public init(
    source: SupersedingRecoverySource,
    stableTargetIdentitySHA256: String,
    bindingRevision: Int,
    coveredIntents: [SupersededRecoveryIntent],
    uncertainEffectSetSHA256: String,
    coverageContractVersion: String,
    coveredEffectSetSHA256: String,
    recoveryJobID: String,
    recoveryIntentEventID: String,
    operationReference: String,
    profileReference: String,
    materializedPlanDigestSHA256: String,
    artifactSHA256: String,
    providerExecutableSHA256: String,
    confirmedStepIDs: [String],
    resultingTargetEpochSHA256: String,
    establishedAtUTC: String
  ) {
    self.source = source
    self.stableTargetIdentitySHA256 = stableTargetIdentitySHA256
    self.bindingRevision = bindingRevision
    self.coveredIntents = coveredIntents
    self.uncertainEffectSetSHA256 = uncertainEffectSetSHA256
    self.coverageContractVersion = coverageContractVersion
    self.coveredEffectSetSHA256 = coveredEffectSetSHA256
    self.recoveryJobID = recoveryJobID
    self.recoveryIntentEventID = recoveryIntentEventID
    self.operationReference = operationReference
    self.profileReference = profileReference
    self.materializedPlanDigestSHA256 = materializedPlanDigestSHA256
    self.artifactSHA256 = artifactSHA256
    self.providerExecutableSHA256 = providerExecutableSHA256
    self.confirmedStepIDs = confirmedStepIDs
    self.resultingTargetEpochSHA256 = resultingTargetEpochSHA256
    self.establishedAtUTC = establishedAtUTC
  }
}

/// An append-only relation proving that a later complete overwrite established
/// a known target epoch. Covered intents remain outcomeUnknown in their own
/// journals; admission consults this independent relation instead of rewriting
/// or guessing their historical result.
public struct SupersedingRecoveryEpoch: Codable, Equatable, Sendable {
  public let epochID: String
  public let source: SupersedingRecoverySource
  public let stableTargetIdentitySHA256: String
  public let bindingRevision: Int
  public let coveredIntents: [SupersededRecoveryIntent]
  public let uncertainEffectSetSHA256: String
  public let coverageContractVersion: String
  public let coveredEffectSetSHA256: String
  public let recoveryJobID: String
  public let recoveryIntentEventID: String
  public let operationReference: String
  public let profileReference: String
  public let materializedPlanDigestSHA256: String
  public let artifactSHA256: String
  public let providerExecutableSHA256: String
  public let confirmedStepIDs: [String]
  public let resultingTargetEpochSHA256: String
  public let establishedAtUTC: String
  public let previousEpochSHA256: String?
  public let epochSHA256: String

  public func covers(
    jobID: String, intentEventID: String,
    stableIdentitySHA256: String, bindingRevision: Int
  ) -> Bool {
    self.stableTargetIdentitySHA256 == stableIdentitySHA256
      && self.bindingRevision == bindingRevision
      && coveredIntents.contains {
        $0.jobID == jobID && $0.intentEventID == intentEventID
      }
  }
}

public enum SupersedingRecoveryStoreError: Error, Equatable, Sendable {
  case corrupt(String)
  case invalidEpoch(String)
  case conflictingEpoch(String)
}

private struct SupersedingRecoveryEpochDocument: Codable {
  static let schemaVersion = "1.0.0"
  let schemaVersion: String
  var epochs: [SupersedingRecoveryEpoch]
}

private struct SupersedingRecoveryEpochMaterial: Codable {
  let epochID: String
  let source: SupersedingRecoverySource
  let stableTargetIdentitySHA256: String
  let bindingRevision: Int
  let coveredIntents: [SupersededRecoveryIntent]
  let uncertainEffectSetSHA256: String
  let coverageContractVersion: String
  let coveredEffectSetSHA256: String
  let recoveryJobID: String
  let recoveryIntentEventID: String
  let operationReference: String
  let profileReference: String
  let materializedPlanDigestSHA256: String
  let artifactSHA256: String
  let providerExecutableSHA256: String
  let confirmedStepIDs: [String]
  let resultingTargetEpochSHA256: String
  let establishedAtUTC: String
  let previousEpochSHA256: String?
}

public actor RuntimeSupersedingRecoveryStore {
  private let documentURL: URL
  private let lockURL: URL
  private static let maximumDocumentBytes = 1_048_576

  public init(stateDirectory: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(stateDirectory)
    try DurableFilePrimitives.createDirectoryIfNeeded(stateDirectory)
    documentURL = stateDirectory.appendingPathComponent(
      "superseding-recovery-epochs.json")
    lockURL = stateDirectory.appendingPathComponent(
      ".superseding-recovery-epochs.lock")
  }

  public func list() throws -> [SupersedingRecoveryEpoch] {
    try withExclusiveLock { try load().epochs }
  }

  public func append(_ draft: SupersedingRecoveryEpochDraft) throws
    -> SupersedingRecoveryEpoch
  {
    try Self.validate(draft)
    return try withExclusiveLock {
      var document = try load()
      let intentKeys = Set(draft.coveredIntents.map { "\($0.jobID)\n\($0.intentEventID)" })
      if let existing = document.epochs.first(where: {
        $0.recoveryJobID == draft.recoveryJobID
          && $0.recoveryIntentEventID == draft.recoveryIntentEventID
          && Set($0.coveredIntents.map { "\($0.jobID)\n\($0.intentEventID)" }) == intentKeys
      }) {
        guard Self.matches(existing, draft: draft) else {
          throw SupersedingRecoveryStoreError.conflictingEpoch(existing.epochID)
        }
        return existing
      }
      let seed = Self.digest(
        Data(
          (draft.stableTargetIdentitySHA256 + "\n" + draft.recoveryJobID + "\n"
            + draft.recoveryIntentEventID + "\n" + draft.uncertainEffectSetSHA256).utf8))
      let epochID = "recovery-epoch-\(seed.prefix(32))"
      if document.epochs.contains(where: { $0.epochID == epochID }) {
        throw SupersedingRecoveryStoreError.conflictingEpoch(epochID)
      }
      let material = SupersedingRecoveryEpochMaterial(
        epochID: epochID, source: draft.source,
        stableTargetIdentitySHA256: draft.stableTargetIdentitySHA256,
        bindingRevision: draft.bindingRevision,
        coveredIntents: draft.coveredIntents,
        uncertainEffectSetSHA256: draft.uncertainEffectSetSHA256,
        coverageContractVersion: draft.coverageContractVersion,
        coveredEffectSetSHA256: draft.coveredEffectSetSHA256,
        recoveryJobID: draft.recoveryJobID,
        recoveryIntentEventID: draft.recoveryIntentEventID,
        operationReference: draft.operationReference,
        profileReference: draft.profileReference,
        materializedPlanDigestSHA256: draft.materializedPlanDigestSHA256,
        artifactSHA256: draft.artifactSHA256,
        providerExecutableSHA256: draft.providerExecutableSHA256,
        confirmedStepIDs: draft.confirmedStepIDs,
        resultingTargetEpochSHA256: draft.resultingTargetEpochSHA256,
        establishedAtUTC: draft.establishedAtUTC,
        previousEpochSHA256: document.epochs.last?.epochSHA256)
      let epoch = SupersedingRecoveryEpoch(
        epochID: material.epochID, source: material.source,
        stableTargetIdentitySHA256: material.stableTargetIdentitySHA256,
        bindingRevision: material.bindingRevision,
        coveredIntents: material.coveredIntents,
        uncertainEffectSetSHA256: material.uncertainEffectSetSHA256,
        coverageContractVersion: material.coverageContractVersion,
        coveredEffectSetSHA256: material.coveredEffectSetSHA256,
        recoveryJobID: material.recoveryJobID,
        recoveryIntentEventID: material.recoveryIntentEventID,
        operationReference: material.operationReference,
        profileReference: material.profileReference,
        materializedPlanDigestSHA256: material.materializedPlanDigestSHA256,
        artifactSHA256: material.artifactSHA256,
        providerExecutableSHA256: material.providerExecutableSHA256,
        confirmedStepIDs: material.confirmedStepIDs,
        resultingTargetEpochSHA256: material.resultingTargetEpochSHA256,
        establishedAtUTC: material.establishedAtUTC,
        previousEpochSHA256: material.previousEpochSHA256,
        epochSHA256: Self.digest(material))
      document.epochs.append(epoch)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      try DurableFileWriter.createOrReplaceAtomically(
        destination: documentURL, data: try encoder.encode(document))
      return epoch
    }
  }

  private func load() throws -> SupersedingRecoveryEpochDocument {
    guard FileManager.default.fileExists(atPath: documentURL.path) else {
      return SupersedingRecoveryEpochDocument(
        schemaVersion: SupersedingRecoveryEpochDocument.schemaVersion, epochs: [])
    }
    let document: SupersedingRecoveryEpochDocument
    do {
      document = try JSONDecoder().decode(
        SupersedingRecoveryEpochDocument.self, from: try readDocument())
    } catch {
      throw SupersedingRecoveryStoreError.corrupt("cannot decode recovery epochs: \(error)")
    }
    guard document.schemaVersion == SupersedingRecoveryEpochDocument.schemaVersion else {
      throw SupersedingRecoveryStoreError.corrupt(
        "unsupported recovery epoch schema \(document.schemaVersion)")
    }
    var previous: String?
    for epoch in document.epochs {
      try Self.validate(Self.draft(from: epoch))
      let material = SupersedingRecoveryEpochMaterial(
        epochID: epoch.epochID, source: epoch.source,
        stableTargetIdentitySHA256: epoch.stableTargetIdentitySHA256,
        bindingRevision: epoch.bindingRevision,
        coveredIntents: epoch.coveredIntents,
        uncertainEffectSetSHA256: epoch.uncertainEffectSetSHA256,
        coverageContractVersion: epoch.coverageContractVersion,
        coveredEffectSetSHA256: epoch.coveredEffectSetSHA256,
        recoveryJobID: epoch.recoveryJobID,
        recoveryIntentEventID: epoch.recoveryIntentEventID,
        operationReference: epoch.operationReference,
        profileReference: epoch.profileReference,
        materializedPlanDigestSHA256: epoch.materializedPlanDigestSHA256,
        artifactSHA256: epoch.artifactSHA256,
        providerExecutableSHA256: epoch.providerExecutableSHA256,
        confirmedStepIDs: epoch.confirmedStepIDs,
        resultingTargetEpochSHA256: epoch.resultingTargetEpochSHA256,
        establishedAtUTC: epoch.establishedAtUTC,
        previousEpochSHA256: epoch.previousEpochSHA256)
      guard epoch.previousEpochSHA256 == previous,
        epoch.epochSHA256 == Self.digest(material)
      else {
        throw SupersedingRecoveryStoreError.corrupt(
          "recovery epoch hash chain is invalid at \(epoch.epochID)")
      }
      previous = epoch.epochSHA256
    }
    return document
  }

  private static func validate(_ draft: SupersedingRecoveryEpochDraft) throws {
    let hashes = [
      draft.stableTargetIdentitySHA256, draft.uncertainEffectSetSHA256,
      draft.coveredEffectSetSHA256, draft.materializedPlanDigestSHA256,
      draft.artifactSHA256, draft.providerExecutableSHA256,
      draft.resultingTargetEpochSHA256,
    ]
    let intentKeys = draft.coveredIntents.map { "\($0.jobID)\n\($0.intentEventID)" }
    let possibleEffects = draft.coveredIntents.flatMap(\.possibleEffects)
    guard hashes.allSatisfy(isSHA256), draft.bindingRevision > 0,
      !draft.coveredIntents.isEmpty,
      Set(intentKeys).count == intentKeys.count,
      draft.uncertainEffectSetSHA256 == effectDigest(possibleEffects),
      !draft.confirmedStepIDs.isEmpty,
      Set(draft.confirmedStepIDs).count == draft.confirmedStepIDs.count,
      draft.coveredIntents.allSatisfy({
        !$0.jobID.isEmpty && !$0.intentEventID.isEmpty
          && !$0.possibleEffects.isEmpty
          && Set($0.possibleEffects).count == $0.possibleEffects.count
      })
    else {
      throw SupersedingRecoveryStoreError.invalidEpoch(
        "recovery epoch lacks closed identity, effect, Artifact or postflight facts")
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 64
      && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func effectDigest(_ effects: [String]) -> String {
    digest(Data(Array(Set(effects)).sorted().joined(separator: "\n").utf8))
  }

  private static func draft(from epoch: SupersedingRecoveryEpoch)
    -> SupersedingRecoveryEpochDraft
  {
    SupersedingRecoveryEpochDraft(
      source: epoch.source,
      stableTargetIdentitySHA256: epoch.stableTargetIdentitySHA256,
      bindingRevision: epoch.bindingRevision,
      coveredIntents: epoch.coveredIntents,
      uncertainEffectSetSHA256: epoch.uncertainEffectSetSHA256,
      coverageContractVersion: epoch.coverageContractVersion,
      coveredEffectSetSHA256: epoch.coveredEffectSetSHA256,
      recoveryJobID: epoch.recoveryJobID,
      recoveryIntentEventID: epoch.recoveryIntentEventID,
      operationReference: epoch.operationReference,
      profileReference: epoch.profileReference,
      materializedPlanDigestSHA256: epoch.materializedPlanDigestSHA256,
      artifactSHA256: epoch.artifactSHA256,
      providerExecutableSHA256: epoch.providerExecutableSHA256,
      confirmedStepIDs: epoch.confirmedStepIDs,
      resultingTargetEpochSHA256: epoch.resultingTargetEpochSHA256,
      establishedAtUTC: epoch.establishedAtUTC)
  }

  private static func matches(
    _ epoch: SupersedingRecoveryEpoch, draft: SupersedingRecoveryEpochDraft
  ) -> Bool {
    Self.draft(from: epoch) == draft
  }

  private func readDocument() throws -> Data {
    let descriptor = Darwin.open(
      documentURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SupersedingRecoveryStoreError.corrupt(
        "cannot open recovery epoch document: errno=\(errno)")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
      metadata.st_size >= 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else {
      throw SupersedingRecoveryStoreError.corrupt(
        "recovery epoch document is not a bounded owner-only regular file")
    }
    let expectedCount = Int(metadata.st_size)
    var data = Data(count: expectedCount)
    var offset = 0
    while offset < expectedCount {
      let count = data.withUnsafeMutableBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return Darwin.read(
          descriptor, base.advanced(by: offset), expectedCount - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SupersedingRecoveryStoreError.corrupt(
          "short read of recovery epoch document")
      }
      offset += count
    }
    return data
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let descriptor = Darwin.open(
      lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SupersedingRecoveryStoreError.corrupt(
        "cannot open recovery epoch lock: errno=\(errno)")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else {
      throw SupersedingRecoveryStoreError.corrupt(
        "recovery epoch lock is not owner-only")
    }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw SupersedingRecoveryStoreError.corrupt(
        "cannot acquire recovery epoch lock: errno=\(errno)")
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }

  private static func digest<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      preconditionFailure("recovery epoch material must encode")
    }
    return digest(data)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct JournalAuditContext: @unchecked Sendable {
  private let eventIDBody: () -> String
  private let timestampBody: () -> String

  public init(
    eventID: @escaping () -> String = { UUID().uuidString },
    timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
  ) {
    eventIDBody = eventID
    timestampBody = timestamp
  }

  public func nextEventID() -> String { eventIDBody() }
  public func timestamp() -> String { timestampBody() }
}

public enum ProviderRecoveryDisposition: Equatable, Sendable {
  case resume
  case confirmedFailure
  case uncertain
}

public struct ProviderRecoveryEvidence: Equatable, Sendable {
  public let disposition: ProviderRecoveryDisposition
  public let restartSafe: Bool
  public let safeBoundaryConfirmed: Bool
  public let outcomeCertainty: JournalOutcomeCertainty
  public let evidence: [String]

  public init(
    disposition: ProviderRecoveryDisposition,
    restartSafe: Bool,
    safeBoundaryConfirmed: Bool,
    outcomeCertainty: JournalOutcomeCertainty,
    evidence: [String]
  ) {
    self.disposition = disposition
    self.restartSafe = restartSafe
    self.safeBoundaryConfirmed = safeBoundaryConfirmed
    self.outcomeCertainty = outcomeCertainty
    self.evidence = evidence
  }
}

public struct RecoveryBindingEvidence: Equatable, Sendable {
  public let confirmed: Bool
  public let revision: Int?
  public let evidence: [String]

  public init(confirmed: Bool, revision: Int?, evidence: [String]) {
    self.confirmed = confirmed
    self.revision = revision
    self.evidence = evidence
  }
}

public struct ReconciliationResult: Equatable, Sendable {
  public let state: JobState
  public let outcomeCertainty: JournalOutcomeCertainty
  public let durableEventSequences: [Int]
  public let destructiveDispatchCount: Int
  public let destructiveReplayCount: Int
  public let guessCompensationCount: Int
}

public final class DeterministicRecoveryReconciler: @unchecked Sendable {
  private let journal: any DurableJournalAppending
  private let audit: JournalAuditContext

  public init(journal: any DurableJournalAppending, audit: JournalAuditContext = .init()) {
    self.journal = journal
    self.audit = audit
  }

  public func reconcile(
    session: ScannedRecoverySession,
    provider: ProviderRecoveryEvidence,
    binding: RecoveryBindingEvidence
  ) throws -> ReconciliationResult {
    guard let schemaVersion = session.replay.schemaVersion else {
      throw DurableFileError.sequenceViolation(
        "reconcile requires an explicit journal schemaVersion")
    }
    if let pending = session.replay.pendingReconcileTransition {
      let transition = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(),
        sequence: session.nextSequence,
        sessionID: session.descriptor.sessionID,
        jobID: session.descriptor.jobID,
        timestamp: audit.timestamp(),
        from: .reconciling,
        to: pending.nextState,
        reason: "complete durable reconcile outcome after restart",
        triggerEventID: pending.outcomeEventID,
        schemaVersion: schemaVersion
      )
      try journal.appendAndSynchronize(transition)
      return ReconciliationResult(
        state: pending.nextState,
        outcomeCertainty: session.replay.lastReconcileOutcomeCertainty ?? .outcomeUnknown,
        durableEventSequences: [transition.sequence],
        destructiveDispatchCount: 0,
        destructiveReplayCount: 0,
        guessCompensationCount: 0)
    }
    guard session.state == .waitingForRecovery else {
      throw DurableFileError.sequenceViolation(
        "reconcile requires a waitingForRecovery session")
    }

    var sequence = session.nextSequence
    var durableSequences: [Int] = []
    if let durableState = session.replay.currentState, durableState != .waitingForRecovery {
      let recoveredWaiting = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(),
        sequence: sequence,
        sessionID: session.descriptor.sessionID,
        jobID: session.descriptor.jobID,
        timestamp: audit.timestamp(),
        from: durableState,
        to: .waitingForRecovery,
        reason: "durably record fail-closed launch recovery state",
        schemaVersion: schemaVersion
      )
      try journal.appendAndSynchronize(recoveredWaiting)
      durableSequences.append(recoveredWaiting.sequence)
      sequence += 1
    }

    let enteredReconciling = try JournalEvent.stateTransition(
      eventID: audit.nextEventID(),
      sequence: sequence,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      from: .waitingForRecovery,
      to: .reconciling,
      reason: "begin deterministic recovery reconciliation",
      schemaVersion: schemaVersion
    )
    try journal.appendAndSynchronize(enteredReconciling)
    durableSequences.append(enteredReconciling.sequence)
    sequence += 1

    let attemptID = audit.nextEventID()
    let started = try JournalEvent.reconcileStarted(
      eventID: audit.nextEventID(),
      sequence: sequence,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      recoveryAttemptID: attemptID,
      sourceState: .waitingForRecovery,
      lastDurableSequence: enteredReconciling.sequence,
      trigger: "startup",
      schemaVersion: schemaVersion
    )
    try journal.appendAndSynchronize(started)
    durableSequences.append(started.sequence)
    sequence += 1

    let result: String
    let state: JobState
    let certainty: JournalOutcomeCertainty
    let safeBoundary: Bool
    let revision: Int?
    let hasUnknownIntent =
      session.replay.hasTornTail
      || !session.replay.outstandingIntents.isEmpty
      || !session.replay.unknownOutcomes.isEmpty
    let confirmedBinding = binding.confirmed && binding.revision.map({ $0 > 0 }) == true

    if hasUnknownIntent {
      result = "waitingForRecovery"
      state = .waitingForRecovery
      certainty = .outcomeUnknown
      safeBoundary = false
      revision = nil
    } else {
      switch provider.disposition {
      case .resume
      where provider.restartSafe && provider.safeBoundaryConfirmed
        && provider.outcomeCertainty == .confirmed && confirmedBinding:
        result = "resumeAtConfirmedSafeBoundary"
        state = .resumeAtConfirmedSafeBoundary
        certainty = .confirmed
        safeBoundary = true
        revision = binding.revision
      case .confirmedFailure
      where provider.safeBoundaryConfirmed && provider.outcomeCertainty == .confirmed
        && confirmedBinding:
        result = "finalizeConfirmedFailure"
        state = .finalizing
        certainty = .confirmed
        safeBoundary = true
        revision = binding.revision
      default:
        result = "waitingForRecovery"
        state = .waitingForRecovery
        certainty = .outcomeUnknown
        safeBoundary = false
        revision = nil
      }
    }

    let outcome = try JournalEvent.reconcileOutcome(
      eventID: audit.nextEventID(),
      sequence: sequence,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      bindingRevision: revision,
      recoveryAttemptID: attemptID,
      result: result,
      nextState: state,
      outcomeCertainty: certainty,
      safeBoundaryConfirmed: safeBoundary,
      evidence: provider.evidence + binding.evidence,
      schemaVersion: schemaVersion
    )
    try journal.appendAndSynchronize(outcome)
    durableSequences.append(outcome.sequence)
    sequence += 1

    let decisionTransition = try JournalEvent.stateTransition(
      eventID: audit.nextEventID(),
      sequence: sequence,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      from: .reconciling,
      to: state,
      reason: "persist deterministic reconcile decision",
      triggerEventID: outcome.eventID,
      schemaVersion: schemaVersion
    )
    try journal.appendAndSynchronize(decisionTransition)
    durableSequences.append(decisionTransition.sequence)
    return ReconciliationResult(
      state: state,
      outcomeCertainty: certainty,
      durableEventSequences: durableSequences,
      destructiveDispatchCount: 0,
      destructiveReplayCount: 0,
      guessCompensationCount: 0
    )
  }
}

public enum ManagedProcessStopResult: String, Equatable, Sendable {
  case notRunning
  case stoppedAtSafeBoundary
  case unconfirmed

  var permitsAbandonment: Bool { self == .notRunning || self == .stoppedAtSafeBoundary }
}

public protocol ManagedProcessStopping: Sendable {
  func stopForRecoveryAbandonment() throws -> ManagedProcessStopResult
}

public enum ResourceReleaseDisposition: Equatable, Sendable {
  case releasedNow
  case alreadyReleased
}

public protocol DeviceLaneReleasing: Sendable {
  /// Idempotently confirms that the device lane is released.
  func ensureDeviceLaneReleased() throws -> ResourceReleaseDisposition
}

public protocol StorageClaimReleasing: Sendable {
  /// Idempotently confirms that the storage claim is released.
  func ensureStorageClaimReleased() throws -> ResourceReleaseDisposition
}

public enum RecoveryResourceReleaseError: Error, Equatable, Sendable {
  case releaseNotDurablyAuthorized
}

public enum RecoveryAbandonmentContinuationError: Error, Equatable, Sendable {
  case noPendingAbandonment
  case identityMismatch
  case confirmationMismatch
}

public struct RecoveryAbandonmentRequest: Equatable, Sendable {
  public let sessionID: String
  public let jobID: String
  public let nextSequence: Int
  public let userConfirmationID: String
  public let lastConfirmedStepID: String?
  public let outcomeCertainty: JournalOutcomeCertainty
  public let managedProcessState: String
  public let deviceHazards: [String]

  public init(
    sessionID: String,
    jobID: String,
    nextSequence: Int,
    userConfirmationID: String,
    lastConfirmedStepID: String?,
    outcomeCertainty: JournalOutcomeCertainty,
    managedProcessState: String,
    deviceHazards: [String]
  ) {
    self.sessionID = sessionID
    self.jobID = jobID
    self.nextSequence = nextSequence
    self.userConfirmationID = userConfirmationID
    self.lastConfirmedStepID = lastConfirmedStepID
    self.outcomeCertainty = outcomeCertainty
    self.managedProcessState = managedProcessState
    self.deviceHazards = deviceHazards
  }
}

public struct RecoveryAbandonmentResult: Equatable, Sendable {
  public let state: JobState
  public let durableEventSequences: [Int]
  public let laneReleaseCount: Int
  public let claimReleaseCount: Int
  public let laneReleased: Bool
  public let claimReleased: Bool
  public let resourceReleasePending: Bool
}

public final class AuditedRecoveryAbandonmentCoordinator: @unchecked Sendable {
  private let journal: any DurableJournalAppending
  private let stopper: any ManagedProcessStopping
  private let laneReleaser: any DeviceLaneReleasing
  private let claimReleaser: any StorageClaimReleasing
  private let audit: JournalAuditContext

  public init(
    journal: any DurableJournalAppending,
    stopper: any ManagedProcessStopping,
    laneReleaser: any DeviceLaneReleasing,
    claimReleaser: any StorageClaimReleasing,
    audit: JournalAuditContext = .init()
  ) {
    self.journal = journal
    self.stopper = stopper
    self.laneReleaser = laneReleaser
    self.claimReleaser = claimReleaser
    self.audit = audit
  }

  public func abandon(_ request: RecoveryAbandonmentRequest) -> RecoveryAbandonmentResult {
    var durableSequences: [Int] = []
    let intentID = audit.nextEventID()
    do {
      let journalContext = try journal.abandonmentContext()
      let durableCertainty: JournalOutcomeCertainty =
        journalContext.requiresOutcomeUnknown || request.outcomeCertainty == .outcomeUnknown
        ? .outcomeUnknown : .confirmed
      let durableRequest = RecoveryAbandonmentRequest(
        sessionID: request.sessionID,
        jobID: request.jobID,
        nextSequence: request.nextSequence,
        userConfirmationID: request.userConfirmationID,
        lastConfirmedStepID: request.lastConfirmedStepID,
        outcomeCertainty: durableCertainty,
        managedProcessState: request.managedProcessState,
        deviceHazards: Array(
          Set(request.deviceHazards).union(journalContext.requiredHazards)
        ).sorted())
      let intent = try JournalEvent.abandonIntent(
        eventID: intentID,
        sequence: durableRequest.nextSequence,
        sessionID: durableRequest.sessionID,
        jobID: durableRequest.jobID,
        timestamp: audit.timestamp(),
        userConfirmationID: durableRequest.userConfirmationID,
        lastConfirmedStep: durableRequest.lastConfirmedStepID,
        outcomeCertainty: durableRequest.outcomeCertainty,
        managedProcessState: durableRequest.managedProcessState,
        deviceHazards: durableRequest.deviceHazards
      )
      try journal.appendAndSynchronize(intent)
      durableSequences.append(intent.sequence)

      let requested = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(),
        sequence: durableRequest.nextSequence + 1,
        sessionID: durableRequest.sessionID,
        jobID: durableRequest.jobID,
        timestamp: audit.timestamp(),
        from: .waitingForRecovery,
        to: .userAbandonRequested,
        reason: "durable recovery abandonment intent",
        triggerEventID: intentID
      )
      try journal.appendAndSynchronize(requested)
      durableSequences.append(requested.sequence)
      return finishRequestedAbandonment(
        durableRequest, intentID: intentID, sequence: durableRequest.nextSequence + 2,
        durableSequences: durableSequences)
    } catch {
      return RecoveryAbandonmentResult(
        state: .waitingForRecovery, durableEventSequences: durableSequences,
        laneReleaseCount: 0, claimReleaseCount: 0,
        laneReleased: false, claimReleased: false, resourceReleasePending: false)
    }
  }

  public func resumeAbandonment(
    _ request: RecoveryAbandonmentRequest,
    from replay: JournalReplay
  ) throws -> RecoveryAbandonmentResult {
    guard let pending = replay.pendingAbandonment else {
      throw RecoveryAbandonmentContinuationError.noPendingAbandonment
    }
    guard let first = replay.events.first,
      first.sessionID == request.sessionID, first.jobID == request.jobID
    else {
      throw RecoveryAbandonmentContinuationError.identityMismatch
    }
    guard let durableIntent = replay.events.first(where: { $0.eventID == pending.intentEventID }),
      durableIntent.payload.string("userConfirmationId") == request.userConfirmationID
    else {
      throw RecoveryAbandonmentContinuationError.confirmationMismatch
    }
    let durableRequest = RecoveryAbandonmentRequest(
      sessionID: request.sessionID,
      jobID: request.jobID,
      nextSequence: request.nextSequence,
      userConfirmationID: request.userConfirmationID,
      lastConfirmedStepID: request.lastConfirmedStepID,
      outcomeCertainty: pending.outcomeCertainty,
      managedProcessState: request.managedProcessState,
      deviceHazards: pending.deviceHazards)

    var sequence = (replay.lastDurableSequence ?? -1) + 1
    var durableSequences: [Int] = []
    switch pending.phase {
    case .intentDurable:
      let requested = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(), sequence: sequence,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        from: .waitingForRecovery, to: .userAbandonRequested,
        reason: "resume durable recovery abandonment intent after restart",
        triggerEventID: pending.intentEventID)
      try journal.appendAndSynchronize(requested)
      durableSequences.append(requested.sequence)
      sequence += 1
      return finishRequestedAbandonment(
        durableRequest, intentID: pending.intentEventID, sequence: sequence,
        durableSequences: durableSequences)
    case .requested:
      return finishRequestedAbandonment(
        durableRequest, intentID: pending.intentEventID, sequence: sequence,
        durableSequences: durableSequences)
    case .outcomeDurable:
      guard let outcomeEventID = pending.outcomeEventID,
        let releaseAuthorized = pending.releaseAuthorized
      else {
        throw RecoveryAbandonmentContinuationError.noPendingAbandonment
      }
      let nextState: JobState = releaseAuthorized ? .interrupted : .waitingForRecovery
      let completed = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(), sequence: sequence,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        from: .userAbandonRequested, to: nextState,
        reason: "complete durable abandon outcome after restart",
        triggerEventID: outcomeEventID)
      try journal.appendAndSynchronize(completed)
      durableSequences.append(completed.sequence)
      if releaseAuthorized {
        return releaseAuthorizedResources(durableEventSequences: durableSequences)
      }
      return waitingResult(durableEventSequences: durableSequences)
    }
  }

  public func retryAuthorizedResourceRelease(
    from replay: JournalReplay
  ) throws -> RecoveryAbandonmentResult {
    guard replay.resourceReleaseAuthorized, replay.currentState == .interrupted else {
      throw RecoveryResourceReleaseError.releaseNotDurablyAuthorized
    }
    return releaseAuthorizedResources(durableEventSequences: [])
  }

  private func rollback(
    _ request: RecoveryAbandonmentRequest,
    intentID: String,
    durableSequences: [Int],
    sequence: Int,
    result: String
  ) -> RecoveryAbandonmentResult {
    var sequences = durableSequences
    do {
      let outcome = try JournalEvent.abandonOutcome(
        eventID: audit.nextEventID(), sequence: sequence,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        correlatesToAbandonIntentEventID: intentID, result: result, releaseAuthorized: false,
        unresolvedHazards: request.deviceHazards)
      try journal.appendAndSynchronize(outcome)
      sequences.append(outcome.sequence)
      let rollback = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(), sequence: sequence + 1,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        from: .userAbandonRequested, to: .waitingForRecovery,
        reason: "abandonment did not reach a confirmed safe boundary",
        triggerEventID: outcome.eventID)
      try journal.appendAndSynchronize(rollback)
      sequences.append(rollback.sequence)
    } catch {
      // Launch scanning treats an unfinished userAbandonRequested record as waitingForRecovery.
    }
    return RecoveryAbandonmentResult(
      state: .waitingForRecovery, durableEventSequences: sequences,
      laneReleaseCount: 0, claimReleaseCount: 0,
      laneReleased: false, claimReleased: false, resourceReleasePending: false)
  }

  private func finishRequestedAbandonment(
    _ request: RecoveryAbandonmentRequest,
    intentID: String,
    sequence: Int,
    durableSequences: [Int]
  ) -> RecoveryAbandonmentResult {
    let stopResult: ManagedProcessStopResult
    do { stopResult = try stopper.stopForRecoveryAbandonment() } catch {
      return rollback(
        request, intentID: intentID, durableSequences: durableSequences,
        sequence: sequence, result: "failed")
    }
    guard stopResult.permitsAbandonment else {
      return rollback(
        request, intentID: intentID, durableSequences: durableSequences,
        sequence: sequence, result: "deferred")
    }

    var sequences = durableSequences
    do {
      let outcome = try JournalEvent.abandonOutcome(
        eventID: audit.nextEventID(), sequence: sequence,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        correlatesToAbandonIntentEventID: intentID, result: "archivedInterrupted",
        releaseAuthorized: true, unresolvedHazards: request.deviceHazards)
      try journal.appendAndSynchronize(outcome)
      sequences.append(outcome.sequence)
      let terminal = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(), sequence: sequence + 1,
        sessionID: request.sessionID, jobID: request.jobID, timestamp: audit.timestamp(),
        from: .userAbandonRequested, to: .interrupted,
        reason: "durable abandon outcome authorizes terminal transition",
        triggerEventID: outcome.eventID)
      try journal.appendAndSynchronize(terminal)
      sequences.append(terminal.sequence)
      return releaseAuthorizedResources(durableEventSequences: sequences)
    } catch {
      return waitingResult(durableEventSequences: sequences)
    }
  }

  private func waitingResult(
    durableEventSequences: [Int]
  ) -> RecoveryAbandonmentResult {
    RecoveryAbandonmentResult(
      state: .waitingForRecovery, durableEventSequences: durableEventSequences,
      laneReleaseCount: 0, claimReleaseCount: 0,
      laneReleased: false, claimReleased: false, resourceReleasePending: false)
  }

  private func releaseAuthorizedResources(
    durableEventSequences: [Int]
  ) -> RecoveryAbandonmentResult {
    var laneReleaseCount = 0
    var claimReleaseCount = 0
    var laneReleased = false
    var claimReleased = false

    do {
      let disposition = try laneReleaser.ensureDeviceLaneReleased()
      laneReleaseCount = disposition == .releasedNow ? 1 : 0
      laneReleased = true
    } catch {
      laneReleased = false
    }

    do {
      let disposition = try claimReleaser.ensureStorageClaimReleased()
      claimReleaseCount = disposition == .releasedNow ? 1 : 0
      claimReleased = true
    } catch {
      claimReleased = false
    }

    return RecoveryAbandonmentResult(
      state: .interrupted,
      durableEventSequences: durableEventSequences,
      laneReleaseCount: laneReleaseCount,
      claimReleaseCount: claimReleaseCount,
      laneReleased: laneReleased,
      claimReleased: claimReleased,
      resourceReleasePending: !laneReleased || !claimReleased)
  }
}
