// Durable Runtime recovery boundary.
//
// RuntimeJobEngine decides when recovered jobs become live and reports their
// capability outcomes.  This service owns admission-projection repair and
// journal replay, including every journal-only crash-window completion.  It
// never resolves facts, dispatches a provider action, or changes authority.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Darwin
import Foundation

struct RuntimeRecoveredJob {
  let record: RuntimeJobRecord
  let journal: FileDurableJournal
  let nextSequence: Int
  let completedStepIDs: Set<String>
}

enum RuntimeCompleteOverwriteRecoveryError: Error, Equatable, Sendable {
  case blocked(String)
}

struct RuntimeCompleteOverwriteAdmissionResult: Equatable, Sendable {
  let recoveryContext: RuntimeCompleteOverwriteRecoveryContext?
  let recognizedEpoch: SupersedingRecoveryEpoch?

  static let noRecovery = RuntimeCompleteOverwriteAdmissionResult(
    recoveryContext: nil, recognizedEpoch: nil)
}

private struct RuntimeHistoricalRockchipIntent: Decodable {
  let schemaVersion: String
  let jobID: String
  let stepID: String
  let targetID: String
  let bindingRevision: Int
  let stableIdentitySHA256: String
  let providerExecutableSHA256: String
  let actionSHA256: String
  let action: PersistedTypedProviderAction
}

private struct RuntimeHistoricalRockchipReceipt: Decodable {
  let schemaVersion: String
  let jobID: String
  let stepID: String
  let targetID: String
  let bindingRevision: Int
  let stableIdentitySHA256: String
  let providerExecutableSHA256: String
  let actionSHA256: String
  let summary: [String: String]
  let stdoutSHA256: String
  let stderrSHA256: String
  let stdoutTruncated: Bool
  let subprocessCount: Int
}

struct RuntimeRecoveryService {
  private let stateDirectory: URL
  private let nowUTC: @Sendable () -> String

  init(stateDirectory: URL, nowUTC: @escaping @Sendable () -> String) {
    self.stateDirectory = stateDirectory
    self.nowUTC = nowUTC
  }

  /// Resolves target-lane uncertainty without trusting caller text. Existing
  /// complete history is recognized first and performs zero dispatch. If no
  /// such history exists, only the exact reviewed operation/profile and full
  /// effect domain can become a distinct recovery Job.
  func completeOverwriteAdmission(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    stableIdentitySHA256: String,
    bindingRevision: Int
  ) async throws -> RuntimeCompleteOverwriteAdmissionResult {
    guard !stableIdentitySHA256.isEmpty, bindingRevision > 0 else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.identityOrBindingMissing")
    }
    let store = try RuntimeSupersedingRecoveryStore(stateDirectory: stateDirectory)
    let epochs = try await store.list()
    let unresolved = try unresolvedDestructiveIntents(
      stableIdentitySHA256: stableIdentitySHA256,
      bindingRevision: bindingRevision,
      epochs: epochs)
    guard !unresolved.isEmpty else { return .noRecovery }

    guard let contract = descriptor.completeOverwriteRecovery,
      let profile = Self.stringInput("deviceProfile", request: request),
      let profileContract = contract.profile(reference: profile)
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.providerContractUnavailable")
    }
    let expectedPartitions = profileContract.coveredEffects.map {
      String($0.dropFirst("partition:".count))
    }
    guard
      let requestedPartitions = Self.stringArrayInput(
        "partitionPlan", request: request),
      requestedPartitions == expectedPartitions,
      Self.stringInput("postFlashVerification", request: request) == "full"
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.incompleteRequestedCoverage")
    }
    let coveredEffects = Set(profileContract.coveredEffects)
    guard
      unresolved.allSatisfy({
        $0.operationReference == descriptor.reference
          && $0.profileReference == profile
          && Set($0.possibleEffects).isSubset(of: coveredEffects)
      })
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.unboundedOrUnsupportedEffect")
    }

    guard
      let started = unresolved.compactMap({ ISO8601Timestamps.parse($0.observedAtUTC) }).min(),
      unresolved.allSatisfy({ ISO8601Timestamps.parse($0.observedAtUTC) != nil }),
      let latestUnknown = unresolved.compactMap({ ISO8601Timestamps.parse($0.observedAtUTC) }).max()
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.invalidHistoricalTimestamp")
    }

    if let historical = try historicalRecovery(
      after: unresolved, latestUnknown: latestUnknown, descriptor: descriptor,
      contract: contract, profileContract: profileContract,
      stableIdentitySHA256: stableIdentitySHA256,
      bindingRevision: bindingRevision)
    {
      let epoch = try await store.append(historical)
      return RuntimeCompleteOverwriteAdmissionResult(
        recoveryContext: nil, recognizedEpoch: epoch)
    }

    guard let now = ISO8601Timestamps.parse(nowUTC()),
      now.timeIntervalSince(started) < 4 * 60 * 60
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.sharedFourHourBudgetExpired")
    }
    let priorEpochs = epochs.filter {
      $0.stableTargetIdentitySHA256 == stableIdentitySHA256
        && $0.bindingRevision == bindingRevision
        && ISO8601Timestamps.parse($0.establishedAtUTC).map {
          now.timeIntervalSince($0) < 4 * 60 * 60
        } == true
    }.count
    let ordinal = unresolved.count + priorEpochs + 1
    guard ordinal <= 16 else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.sharedEpochBudgetExhausted")
    }
    return RuntimeCompleteOverwriteAdmissionResult(
      recoveryContext: RuntimeCompleteOverwriteRecoveryContext(
        coveredIntents: unresolved,
        uncertainEffectSetSHA256: Self.effectDigest(
          unresolved.flatMap(\.possibleEffects)),
        coverageContractVersion: contract.contractVersion,
        coveredEffectSetSHA256: Self.effectDigest(profileContract.coveredEffects),
        profileReference: profile,
        destructiveEpochOrdinal: ordinal),
      recognizedEpoch: nil)
  }

  private func unresolvedDestructiveIntents(
    stableIdentitySHA256: String,
    bindingRevision: Int,
    epochs: [SupersedingRecoveryEpoch]
  ) throws -> [SupersededRecoveryIntent] {
    let jobsRoot = stateDirectory.appending(path: "jobs", directoryHint: .isDirectory)
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: jobsRoot, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    else { return [] }
    var unresolved: [SupersededRecoveryIntent] = []
    for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard let record = try? RuntimeJobRecord.load(from: directory),
        record.materializedStableTargetIdentitySHA256 == stableIdentitySHA256,
        record.materializedBindingRevision == bindingRevision
      else { continue }
      let replay = try DurableJournalRecovery.inspect(
        url: directory.appending(path: "journal.jsonl"))
      guard !replay.hasTornTail else {
        throw RuntimeCompleteOverwriteRecoveryError.blocked(
          "completeOverwriteRecovery.tornHistoricalJournal")
      }
      let profile = Self.stringInput("deviceProfile", request: record.request) ?? ""
      let partitions = Self.stringArrayInput("partitionPlan", request: record.request)
      var destructiveIntents = replay.outstandingIntents
        .filter { $0.effect == .destructive }
        .map { ($0.eventID, $0.stepID) }
      destructiveIntents.append(
        contentsOf: replay.unknownOutcomes
          .filter { $0.effect == .destructive }
          .map { ($0.correlatedIntentEventID, $0.stepID) })
      if !destructiveIntents.isEmpty,
        replay.events.contains(where: {
          guard $0.kind == .stateTransition, let transition = $0.stateTransition else {
            return false
          }
          return transition.to == .cancelRequested
            || transition.to == .userAbandonRequested
        })
      {
        throw RuntimeCompleteOverwriteRecoveryError.blocked(
          "completeOverwriteRecovery.explicitCancellationPending")
      }
      var seenIntentEventIDs: Set<String> = []
      for (intentEventID, stepID) in destructiveIntents {
        guard seenIntentEventIDs.insert(intentEventID).inserted else { continue }
        if epochs.contains(where: {
          $0.covers(
            jobID: record.jobID, intentEventID: intentEventID,
            stableIdentitySHA256: stableIdentitySHA256,
            bindingRevision: bindingRevision)
        }) {
          continue
        }
        guard record.operationReference == "flash.dayu200",
          stepID == "flash-partitions", !profile.isEmpty,
          let partitions, !partitions.isEmpty,
          replay.events.contains(where: {
            $0.kind == .stepIntent && $0.eventID == intentEventID
              && $0.stepID == stepID && $0.stepEffect == .destructive
          })
        else {
          throw RuntimeCompleteOverwriteRecoveryError.blocked(
            "completeOverwriteRecovery.unboundedHistoricalIntent")
        }
        unresolved.append(
          SupersededRecoveryIntent(
            jobID: record.jobID, intentEventID: intentEventID,
            operationReference: record.operationReference,
            profileReference: profile,
            observedAtUTC: record.finishedAtUTC ?? record.createdAtUTC,
            possibleEffects: partitions.map { "partition:\($0)" }))
      }
    }
    return unresolved.sorted {
      ($0.observedAtUTC, $0.jobID, $0.intentEventID)
        < ($1.observedAtUTC, $1.jobID, $1.intentEventID)
    }
  }

  private func historicalRecovery(
    after unresolved: [SupersededRecoveryIntent],
    latestUnknown: Date,
    descriptor: CatalogOperationDescriptor,
    contract: CatalogCompleteOverwriteRecoveryDescriptor,
    profileContract: CatalogCompleteOverwriteRecoveryProfileDescriptor,
    stableIdentitySHA256: String,
    bindingRevision: Int
  ) throws -> SupersedingRecoveryEpochDraft? {
    let jobsRoot = stateDirectory.appending(path: "jobs", directoryHint: .isDirectory)
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: jobsRoot, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
    else { return nil }
    let profile = profileContract.reference
    let expectedPartitions = profileContract.coveredEffects.map {
      String($0.dropFirst("partition:".count))
    }
    let requiredSteps = [contract.overwriteStepID] + contract.verificationStepIDs
    let candidates = directories.compactMap {
      directory -> (URL, RuntimeJobRecord, Date)? in
      guard let record = try? RuntimeJobRecord.load(from: directory),
        let finishedAtUTC = record.finishedAtUTC,
        let finishedAt = ISO8601Timestamps.parse(finishedAtUTC),
        finishedAt > latestUnknown,
        record.state == JobState.succeeded.rawValue,
        !record.outcomeUnknown,
        record.operationReference == descriptor.reference,
        record.materializedStableTargetIdentitySHA256 == stableIdentitySHA256,
        record.materializedBindingRevision == bindingRevision,
        Self.stringInput("deviceProfile", request: record.request) == profile,
        Self.stringArrayInput("partitionPlan", request: record.request) == expectedPartitions,
        Self.stringInput("postFlashVerification", request: record.request) == "full",
        let materializedPlanDigest = record.materializedPlanDigest,
        Self.isSHA256(materializedPlanDigest)
      else { return nil }
      return (directory, record, finishedAt)
    }.sorted { $0.2 < $1.2 }

    for (directory, record, _) in candidates {
      let replay = try DurableJournalRecovery.inspect(
        url: directory.appending(path: "journal.jsonl"))
      guard !replay.hasTornTail, replay.outstandingIntents.isEmpty,
        replay.unknownOutcomes.isEmpty, replay.currentState == .succeeded
      else { continue }
      var confirmedIntentByStep: [String: String] = [:]
      var confirmedStepIDs: [String] = []
      var seenConfirmedStepIDs: Set<String> = []
      for outcome in replay.events where outcome.kind == .stepOutcome {
        guard let stepID = outcome.stepID,
          outcome.payload["result"] == .string("succeeded"),
          outcome.payload["outcomeCertainty"] == .string("confirmed"),
          let intentEventID = outcome.correlatedIntentEventID,
          replay.events.contains(where: {
            $0.kind == .stepIntent && $0.eventID == intentEventID
              && $0.stepID == stepID
          })
        else { continue }
        if seenConfirmedStepIDs.insert(stepID).inserted {
          confirmedStepIDs.append(stepID)
        }
        if requiredSteps.contains(stepID) {
          confirmedIntentByStep[stepID] = intentEventID
        }
      }
      guard Set(requiredSteps).isSubset(of: Set(confirmedIntentByStep.keys)),
        let recoveryIntentEventID = confirmedIntentByStep[contract.overwriteStepID],
        let proof = try historicalHostProof(
          record: record, requiredStepIDs: requiredSteps,
          expectedPartitions: expectedPartitions)
      else { continue }
      let resultingEpoch = Self.sha256(
        [
          stableIdentitySHA256, String(bindingRevision), record.jobID,
          record.materializedPlanDigest!, proof.artifactSHA256,
          requiredSteps.joined(separator: ","),
        ].joined(separator: "\n"))
      return SupersedingRecoveryEpochDraft(
        source: .historicalRecognition,
        stableTargetIdentitySHA256: stableIdentitySHA256,
        bindingRevision: bindingRevision,
        coveredIntents: unresolved,
        uncertainEffectSetSHA256: Self.effectDigest(
          unresolved.flatMap(\.possibleEffects)),
        coverageContractVersion: contract.contractVersion,
        coveredEffectSetSHA256: Self.effectDigest(profileContract.coveredEffects),
        recoveryJobID: record.jobID,
        recoveryIntentEventID: recoveryIntentEventID,
        operationReference: record.operationReference,
        profileReference: profile,
        materializedPlanDigestSHA256: record.materializedPlanDigest!,
        artifactSHA256: proof.artifactSHA256,
        providerExecutableSHA256: proof.providerExecutableSHA256,
        confirmedStepIDs: confirmedStepIDs,
        resultingTargetEpochSHA256: resultingEpoch,
        establishedAtUTC: record.finishedAtUTC!)
    }
    return nil
  }

  private func historicalHostProof(
    record: RuntimeJobRecord,
    requiredStepIDs: [String],
    expectedPartitions: [String]
  ) throws -> (artifactSHA256: String, providerExecutableSHA256: String)? {
    let root =
      stateDirectory
      .appending(path: "rockchip-runtime", directoryHint: .isDirectory)
      .appending(path: record.jobID, directoryHint: .isDirectory)
    var executable: String?
    var artifact: String?
    for stepID in requiredStepIDs {
      let directory = root.appending(path: stepID, directoryHint: .isDirectory)
      let intent: RuntimeHistoricalRockchipIntent
      let receipt: RuntimeHistoricalRockchipReceipt
      do {
        intent = try JSONDecoder().decode(
          RuntimeHistoricalRockchipIntent.self,
          from: try Self.readOwnerOnlyRecord(
            directory.appending(path: "intent.json")))
        receipt = try JSONDecoder().decode(
          RuntimeHistoricalRockchipReceipt.self,
          from: try Self.readOwnerOnlyRecord(
            directory.appending(path: "receipt.json")))
      } catch { return nil }
      let actionEncoder = CanonicalJSONEncoders.canonical()
      guard let encodedAction = try? actionEncoder.encode(intent.action),
        Self.sha256(encodedAction) == intent.actionSHA256
      else { return nil }
      guard intent.schemaVersion == "1.0.0", receipt.schemaVersion == "1.0.0",
        intent.jobID == record.jobID, receipt.jobID == record.jobID,
        intent.stepID == stepID, receipt.stepID == stepID,
        intent.targetID == record.request.target.targetID,
        receipt.targetID == record.request.target.targetID,
        intent.bindingRevision == record.materializedBindingRevision,
        receipt.bindingRevision == record.materializedBindingRevision,
        intent.stableIdentitySHA256 == record.materializedStableTargetIdentitySHA256,
        receipt.stableIdentitySHA256 == record.materializedStableTargetIdentitySHA256,
        intent.providerExecutableSHA256 == receipt.providerExecutableSHA256,
        intent.actionSHA256 == receipt.actionSHA256,
        Self.isSHA256(intent.providerExecutableSHA256),
        Self.isSHA256(receipt.stdoutSHA256), Self.isSHA256(receipt.stderrSHA256),
        !receipt.stdoutTruncated, receipt.subprocessCount > 0,
        !receipt.summary.isEmpty
      else { return nil }
      if let executable, executable != intent.providerExecutableSHA256 { return nil }
      executable = intent.providerExecutableSHA256
      if stepID == "flash-partitions" {
        guard case .rockchip(.flashPartitions(let bundle)) = try intent.action.materialize(),
          bundle.partitionNames == expectedPartitions,
          Self.isSHA256(bundle.sha256), bundle.byteCount > 0,
          receipt.summary["partitionCount"] == String(expectedPartitions.count),
          receipt.summary["bundleSha256"] == bundle.sha256
        else { return nil }
        artifact = bundle.sha256
      }
    }
    guard let artifact, let executable else { return nil }
    return (artifact, executable)
  }

  private static func stringInput(
    _ key: String, request: RuntimeOperationRequest
  ) -> String? {
    guard case .string(let value)? = request.inputs[key] else { return nil }
    return value
  }

  private static func stringArrayInput(
    _ key: String, request: RuntimeOperationRequest
  ) -> [String]? {
    guard case .array(let values)? = request.inputs[key] else { return nil }
    var result: [String] = []
    result.reserveCapacity(values.count)
    for value in values {
      guard case .string(let item) = value else { return nil }
      result.append(item)
    }
    return result
  }

  private static func effectDigest(_ effects: [String]) -> String {
    sha256(Array(Set(effects)).sorted().joined(separator: "\n"))
  }

  private static func sha256(_ value: String) -> String {
    RuntimeJobRecord.sha256Hex(Data(value.utf8))
  }

  private static func sha256(_ data: Data) -> String {
    RuntimeJobRecord.sha256Hex(data)
  }

  private static func isSHA256(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 64
      && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func readOwnerOnlyRecord(_ url: URL) throws -> Data {
    let maximumBytes = 1_048_576
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.hostProofUnavailable")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
      metadata.st_size >= 0, metadata.st_size <= maximumBytes
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.unsafeHostProof")
    }
    let expectedCount = Int(metadata.st_size)
    var data = Data(count: expectedCount)
    var offset = 0
    while offset < expectedCount {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), expectedCount - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeCompleteOverwriteRecoveryError.blocked(
          "completeOverwriteRecovery.shortHostProof")
      }
      offset += count
    }
    var finalMetadata = stat()
    guard fstat(descriptor, &finalMetadata) == 0,
      finalMetadata.st_dev == metadata.st_dev,
      finalMetadata.st_ino == metadata.st_ino,
      finalMetadata.st_size == metadata.st_size,
      finalMetadata.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
      finalMetadata.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
      finalMetadata.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
      finalMetadata.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec
    else {
      throw RuntimeCompleteOverwriteRecoveryError.blocked(
        "completeOverwriteRecovery.hostProofChangedDuringRead")
    }
    return data
  }

  /// Recreates only the wholly absent projection left by a process loss after
  /// the SQLite admission commit and before the first journal append.  A
  /// partial projection is never guessed at: it is attributable corruption
  /// because it could otherwise hide an external-effect history.
  func restoreInitialAdmissionProjectionIfNeeded(_ persisted: RuntimePersistedJob) throws {
    let directory = jobDirectory(for: persisted.jobID)
    let recordURL = directory.appending(path: "job-record.json")
    let journalURL = directory.appending(path: "journal.jsonl")
    let hasRecord = FileManager.default.fileExists(atPath: recordURL.path)
    let hasJournal = FileManager.default.fileExists(atPath: journalURL.path)
    if hasRecord && hasJournal { return }
    guard let data = persisted.initialRecordData else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has no recoverable initial record")
    }
    let record: RuntimeJobRecord
    do {
      record = try JSONDecoder().decode(RuntimeJobRecord.self, from: data)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has an invalid initial record: \(error)")
    }
    guard record.jobID == persisted.jobID, record.state == JobState.preflight.rawValue else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) initial record does not match its transactional identity")
    }
    if hasJournal {
      let inspection = try DurableJournalRecovery.inspect(url: journalURL)
      if !hasRecord, inspection.events.isEmpty {
        // The writer creates and fsyncs an empty inode before its first
        // append.  This exact loss window is still an admitted job with zero
        // effect history, so complete its initial durable pair.
        let journal = try FileDurableJournal(url: journalURL)
        try appendInitialAdmissionEvents(to: journal, record: record)
        try record.persist(into: directory)
        return
      }
      guard
        !hasRecord,
        inspection.events.count == 2,
        inspection.events[0].kind == .jobCreated,
        inspection.events[0].jobID == record.jobID,
        inspection.events[1].kind == .stateTransition,
        inspection.events[1].stateTransition?.from == .queued,
        inspection.events[1].stateTransition?.to == .preflight
      else {
        throw RuntimeJobEngineError.internalFailure(
          "admitted job \(persisted.jobID) has a partial durable projection")
      }
      try record.persist(into: directory)
      return
    }
    guard !hasRecord else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has a partial durable projection")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let journal = try FileDurableJournal(url: journalURL)
    try appendInitialAdmissionEvents(to: journal, record: record)
    try record.persist(into: directory)
  }

  /// Replays a repaired projection without ever dispatching a provider.  Any
  /// unresolved intent is durably parked, while the quiet cancellation and
  /// finalization windows are completed journal-only at their safe boundary.
  func replay(_ persisted: RuntimePersistedJob) async throws -> RuntimeRecoveredJob {
    let jobID = persisted.jobID
    let directory = jobDirectory(for: jobID)
    guard var record = try? RuntimeJobRecord.load(from: directory) else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(jobID) has no readable durable record after recovery projection")
    }
    let journalURL = directory.appending(path: "journal.jsonl")
    let journal = try FileDurableJournal(url: journalURL)
    var inspection = try DurableJournalRecovery.inspect(url: journalURL)
    var nextSequence = Int((inspection.lastDurableSequence ?? -1) + 1)

    // A crash after reconcileOutcome may leave its mandatory triggered
    // transition unwritten. Finish that journal-only decision before
    // considering any provider work.
    if let last = inspection.events.last,
      last.kind == .reconcileOutcome,
      case .string(let nextStateRaw)? = last.payload["nextState"],
      let nextState = JobState(rawValue: nextStateRaw)
    {
      try appendTransition(
        to: journal, record: record, sequence: &nextSequence,
        from: .reconciling, to: nextState,
        reason: "complete durable reconcile decision after restart",
        triggerEventID: last.eventID)
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    let hasUnresolvedProviderIntent =
      inspection.hasTornTail || !inspection.outstandingIntents.isEmpty
      || !inspection.unknownOutcomes.isEmpty
      || inspection.lastReconcileOutcomeCertainty == .outcomeUnknown
    if hasUnresolvedProviderIntent,
      let currentState = inspection.currentState,
      currentState != .waitingForRecovery,
      currentState != .reconciling,
      JobStateMachine.isAllowedTransition(
        from: currentState, to: .waitingForRecovery, mode: .execute)
    {
      try appendTransition(
        to: journal, record: record, sequence: &nextSequence,
        from: currentState, to: .waitingForRecovery,
        reason: "durably park unresolved provider intent after restart")
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    if hasUnresolvedProviderIntent {
      record.state = (inspection.currentState ?? .waitingForRecovery).rawValue
      record.outcomeUnknown = true
      if record.recoveryStepID == nil {
        record.recoveryStepID =
          inspection.unknownOutcomes.last?.stepID
          ?? inspection.outstandingIntents.last?.stepID
      }
      record.timeline.append("recovered: outstanding intents or unknown outcomes; no redispatch")
    } else {
      // A clean non-terminal cancellation/finalization journal has no resume
      // lane. Complete only these already-durable decisions; recovery never
      // dispatches in any branch.
      switch inspection.currentState {
      case .cancelRequested, .cancellingAtSafeBoundary:
        if inspection.currentState == .cancelRequested {
          try appendTransition(
            to: journal, record: record, sequence: &nextSequence,
            from: .cancelRequested, to: .cancellingAtSafeBoundary,
            reason: "process loss with no outstanding intent is a confirmed safe boundary")
        }
        try appendTransition(
          to: journal, record: record, sequence: &nextSequence,
          from: .cancellingAtSafeBoundary, to: .cancelled,
          reason: "complete durable cancellation after restart")
        inspection = try DurableJournalRecovery.inspect(url: journalURL)
        record.finishedAtUTC = nowUTC()
        record.timeline.append(
          "recovered: completed durable cancellation at journal-confirmed safe boundary; no redispatch"
        )
      case .finalizing:
        let establishedRecoveryEpoch: SupersedingRecoveryEpoch?
        if record.admissionEvidence?.completeOverwriteRecovery != nil,
          let store = try? RuntimeSupersedingRecoveryStore(stateDirectory: stateDirectory)
        {
          establishedRecoveryEpoch = try matchingDurableRecoveryEpoch(
            record: record, replay: inspection, epochs: try await store.list())
        } else {
          establishedRecoveryEpoch = nil
        }
        if establishedRecoveryEpoch != nil {
          try appendTransition(
            to: journal, record: record, sequence: &nextSequence,
            from: .finalizing, to: .recovered,
            reason: "complete terminal transition for durable superseding recovery epoch")
        } else {
          try appendTransition(
            to: journal, record: record, sequence: &nextSequence,
            from: .finalizing, to: .failed,
            reason: "finalization was interrupted before its terminal transition")
        }
        inspection = try DurableJournalRecovery.inspect(url: journalURL)
        record.finishedAtUTC = nowUTC()
        if inspection.lastReconcileOutcomeCertainty == .confirmed {
          record.outcomeUnknown = false
          record.recoveryStepID = nil
          record.recoveryIntentEventID = nil
          record.recoveryAction = nil
        }
        record.timeline.append(
          establishedRecoveryEpoch == nil
            ? "recovered: finalization interrupted before terminal transition; failed without redispatch"
            : "recovered: durable superseding epoch completed journal-only; no redispatch")
      default:
        record.timeline.append("recovered: journal clean")
      }
      if let currentState = inspection.currentState {
        record.state = currentState.rawValue
      }
      if inspection.currentState == .resumeAtConfirmedSafeBoundary,
        inspection.lastReconcileOutcomeCertainty == .confirmed
      {
        record.outcomeUnknown = false
        record.recoveryStepID = nil
        record.recoveryIntentEventID = nil
        record.recoveryAction = nil
      }
    }
    return RuntimeRecoveredJob(
      record: record, journal: journal, nextSequence: nextSequence,
      completedStepIDs: confirmedSucceededStepIDs(in: inspection))
  }

  private func jobDirectory(for jobID: String) -> URL {
    stateDirectory
      .appending(path: "jobs", directoryHint: .isDirectory)
      .appending(path: jobID, directoryHint: .isDirectory)
  }

  private func appendInitialAdmissionEvents(
    to journal: FileDurableJournal, record: RuntimeJobRecord
  ) throws {
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC, executionMode: "execute",
        schemaVersion: journalSchemaVersion(of: record)))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC,
        from: .queued, to: .preflight, reason: "recovered committed admission",
        schemaVersion: journalSchemaVersion(of: record)))
  }

  private func appendTransition(
    to journal: FileDurableJournal, record: RuntimeJobRecord,
    sequence: inout Int, from: JobState, to: JobState,
    reason: String, triggerEventID: String? = nil
  ) throws {
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "recovery-t-\(sequence)", sequence: sequence,
        sessionID: record.sessionID, jobID: record.jobID, timestamp: nowUTC(),
        from: from, to: to, reason: reason, triggerEventID: triggerEventID,
        schemaVersion: journalSchemaVersion(of: record)))
    sequence += 1
  }

  private func journalSchemaVersion(of record: RuntimeJobRecord) -> String {
    record.operationReference == "flash.dayu200"
      ? JournalEvent.completeOverwriteRecoverySchemaVersion : JournalEvent.schemaVersion
  }

  private func confirmedSucceededStepIDs(in replay: JournalReplay) -> Set<String> {
    Set(
      replay.events.compactMap { event in
        guard event.kind == .stepOutcome,
          case .string("confirmed")? = event.payload["outcomeCertainty"],
          case .string("succeeded")? = event.payload["result"]
        else { return nil }
        return event.stepID
      })
  }

  private func matchingDurableRecoveryEpoch(
    record: RuntimeJobRecord,
    replay: JournalReplay,
    epochs: [SupersedingRecoveryEpoch]
  ) throws -> SupersedingRecoveryEpoch? {
    guard let recovery = record.admissionEvidence?.completeOverwriteRecovery,
      let descriptor = RuntimeOperationCatalog.descriptor(reference: record.operationReference),
      let contract = descriptor.completeOverwriteRecovery,
      contract.contractVersion == recovery.coverageContractVersion,
      let profileContract = contract.profile(reference: recovery.profileReference),
      let stableIdentity = record.materializedStableTargetIdentitySHA256,
      let bindingRevision = record.materializedBindingRevision,
      let planDigest = record.materializedPlanDigest,
      let artifactSHA256 = record.admissionEvidence?
        .runtimeCapabilityCorrelation?.artifactSHA256,
      let providerSHA256 = record.admissionEvidence?
        .recoveryProviderExecutableSHA256,
      Self.isSHA256(stableIdentity), bindingRevision > 0,
      Self.isSHA256(planDigest), Self.isSHA256(artifactSHA256),
      Self.isSHA256(providerSHA256),
      Self.effectDigest(profileContract.coveredEffects) == recovery.coveredEffectSetSHA256
    else { return nil }
    let requiredSteps = [contract.overwriteStepID] + contract.verificationStepIDs
    var intentByConfirmedStep: [String: String] = [:]
    var confirmedStepIDs: [String] = []
    var seenStepIDs: Set<String> = []
    for outcome in replay.events where outcome.kind == .stepOutcome {
      guard let stepID = outcome.stepID,
        outcome.payload["result"] == .string("succeeded"),
        outcome.payload["outcomeCertainty"] == .string("confirmed"),
        let intentEventID = outcome.correlatedIntentEventID,
        replay.events.contains(where: {
          $0.kind == .stepIntent && $0.eventID == intentEventID && $0.stepID == stepID
        })
      else { continue }
      intentByConfirmedStep[stepID] = intentEventID
      if seenStepIDs.insert(stepID).inserted { confirmedStepIDs.append(stepID) }
    }
    guard Set(requiredSteps).isSubset(of: Set(intentByConfirmedStep.keys)),
      let overwriteIntent = intentByConfirmedStep[contract.overwriteStepID]
    else { return nil }
    let resultingEpoch = Self.sha256(
      [
        stableIdentity, String(bindingRevision), record.jobID,
        planDigest, artifactSHA256, requiredSteps.joined(separator: ","),
      ].joined(separator: "\n"))
    return epochs.last {
      $0.source == .distinctRecoveryExecution
        && $0.recoveryJobID == record.jobID
        && $0.recoveryIntentEventID == overwriteIntent
        && $0.stableTargetIdentitySHA256 == stableIdentity
        && $0.bindingRevision == bindingRevision
        && $0.coveredIntents == recovery.coveredIntents
        && $0.uncertainEffectSetSHA256 == recovery.uncertainEffectSetSHA256
        && $0.coverageContractVersion == recovery.coverageContractVersion
        && $0.coveredEffectSetSHA256 == recovery.coveredEffectSetSHA256
        && $0.operationReference == record.operationReference
        && $0.profileReference == recovery.profileReference
        && $0.materializedPlanDigestSHA256 == planDigest
        && $0.artifactSHA256 == artifactSHA256
        && $0.providerExecutableSHA256 == providerSHA256
        && $0.confirmedStepIDs == confirmedStepIDs
        && $0.resultingTargetEpochSHA256 == resultingEpoch
    }
  }
}
