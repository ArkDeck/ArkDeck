import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import Foundation

public enum DeviceBindingJournalAdapterError: Error, Equatable, Sendable {
  case sessionIdentityMismatch
  case journalIdentityMismatch
  case initialBindingAlreadyPersisted
  case initialBindingNotPersisted
  case bindingMismatch
  case candidateMismatch
  case rebindNotAuthorized(DeviceRebindAuthorizationError)
  case effectRejected(DeviceEffectGateRejection)
  case commandIntentNotDurable
  case commandIntentAlreadyDispatched
  case deviceDispatchInFlight
  case incompleteDurableBindingChain(Int)
  case malformedDurableBinding(String)
  case unsupportedStateTransition(JobState)
  case mutationRecoveryRequired
  case mutationJobNotDurablyTerminal
}

public enum DeviceBindingRejectionReason: String, Codable, Equatable, Sendable {
  case identityMismatch
  case userRejected
  case ambiguous
  case staleCandidate
  case serverGenerationChanged
  case policyBlocked
}

public enum DeviceBindingReconcileTrigger: String, Codable, Equatable, Sendable {
  case startup
  case manual
  case deviceReturned
  case providerRecovery
}

public struct DeviceBindingManifestSnapshot: Equatable, Sendable {
  public let originalTarget: JSONValue
  public let bindingHistory: [JSONValue]

  public init(originalTarget: JSONValue, bindingHistory: [JSONValue]) {
    self.originalTarget = originalTarget
    self.bindingHistory = bindingHistory
  }
}

/// Bridges the Core binding values to the existing locked journal and generic
/// Session audit contracts. A durable receipt is returned only after the
/// corresponding `bindingConfirmed` record has been fully synchronized.
public actor DeviceBindingJournalAdapter: HDCDeviceCommandExecuting {
  package static let sharedMutationLane = DeviceMutationLaneCoordinator()

  private let journal: any DurableJournalAppending
  private let auditStore: any DurableSessionAuditAppending
  private let mutationLane: DeviceMutationLaneCoordinator
  private let mutationLaneOwnerID: String
  private let timestamp: @Sendable () -> String
  private let eventID: @Sendable () -> String
  private var history: DeviceBindingHistory
  private var nextSequence: Int
  private var hasDurableInitialBinding: Bool
  private var currentState: JobState?
  private var identityDisposition: DeviceIdentityDisposition
  private var durableCommandIntents: [String: HDCDeviceCommandIntent] = [:]
  private var dispatchedCommandIntentIDs: Set<String> = []
  private var activeDispatchIntentIDs: Set<String> = []
  private var mutationJobLease: DeviceMutationLaneLease?
  private var mutationJobLeaseAcquisitionInProgress = false

  public init(
    history: DeviceBindingHistory,
    journal: any DurableJournalAppending,
    auditStore: any DurableSessionAuditAppending,
    replay: JournalReplay,
    timestamp: @escaping @Sendable () -> String = {
      ISO8601DateFormatter().string(from: Date())
    },
    eventID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws {
    try self.init(
      history: history,
      journal: journal,
      auditStore: auditStore,
      replay: replay,
      mutationLane: Self.sharedMutationLane,
      mutationLaneOwnerID: UUID().uuidString,
      timestamp: timestamp,
      eventID: eventID)
  }

  package init(
    history: DeviceBindingHistory,
    journal: any DurableJournalAppending,
    auditStore: any DurableSessionAuditAppending,
    replay: JournalReplay,
    mutationLane: DeviceMutationLaneCoordinator,
    mutationLaneOwnerID: String = UUID().uuidString,
    timestamp: @escaping @Sendable () -> String,
    eventID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws {
    guard
      replay.events.allSatisfy({
        $0.sessionID == auditStore.layout.sessionID && $0.jobID == auditStore.layout.jobID
      })
    else { throw DeviceBindingJournalAdapterError.journalIdentityMismatch }
    guard replay.events.first?.kind == .jobCreated else {
      throw DeviceBindingJournalAdapterError.journalIdentityMismatch
    }
    self.history = history
    self.journal = journal
    self.auditStore = auditStore
    self.mutationLane = mutationLane
    self.mutationLaneOwnerID = mutationLaneOwnerID
    self.timestamp = timestamp
    self.eventID = eventID
    nextSequence = (replay.lastDurableSequence ?? -1) + 1
    currentState = replay.currentState
    identityDisposition = Self.restoredIdentityDisposition(from: replay)
    dispatchedCommandIntentIDs = Set(replay.events.compactMap(\.correlatedIntentEventID))
    let confirmations = replay.events.filter { $0.kind == .bindingConfirmed }
    if confirmations.isEmpty {
      guard history.bindings.count == 1 else {
        throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(1)
      }
      hasDurableInitialBinding = false
    } else {
      guard confirmations.count == history.bindings.count else {
        throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(
          confirmations.count + 1)
      }
      for binding in history.bindings {
        let matches = confirmations.filter {
          Self.confirmation($0, matches: binding, in: replay.events)
        }
        guard matches.count == 1
        else {
          throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(binding.revision)
        }
      }
      hasDurableInitialBinding = true
    }
  }

  public static func reopen(
    layout: SessionLayout,
    targetID: String,
    timestamp: @escaping @Sendable () -> String = {
      ISO8601DateFormatter().string(from: Date())
    },
    eventID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws -> DeviceBindingJournalAdapter {
    try reopen(
      layout: layout,
      targetID: targetID,
      mutationLane: Self.sharedMutationLane,
      timestamp: timestamp,
      eventID: eventID)
  }

  package static func reopen(
    layout: SessionLayout,
    targetID: String,
    mutationLane: DeviceMutationLaneCoordinator,
    timestamp: @escaping @Sendable () -> String,
    eventID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) throws -> DeviceBindingJournalAdapter {
    let replay = try DurableJournalRecovery.inspect(url: layout.journalURL)
    let auditStore = try FileDurableSessionAuditStore(layout: layout)
    let history = try restoreHistory(targetID: targetID, auditStore: auditStore, replay: replay)
    let journal = try FileDurableJournal(url: layout.journalURL)
    return try DeviceBindingJournalAdapter(
      history: history,
      journal: journal,
      auditStore: auditStore,
      replay: replay,
      mutationLane: mutationLane,
      timestamp: timestamp,
      eventID: eventID)
  }

  public func persistInitialBinding() throws -> DurableCurrentDeviceBinding {
    try synchronizeDurableAuthority()
    guard !hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingAlreadyPersisted
    }
    let binding = history.bindings[0]
    let candidateEventID = eventID()
    try appendCandidate(
      eventID: candidateEventID,
      candidateID: "initial-\(history.targetID)",
      connectKey: binding.connectKey,
      transport: binding.transport,
      identitySnapshot: binding.identitySnapshot,
      evidence: binding.evidence,
      ambiguous: false)
    try appendAudit(
      suffix: "initial-intent-\(binding.revision)-\(nextSequence)",
      category: .intent,
      details: [
        "eventType": .string("initialBindingIntent"),
        "targetId": .string(history.targetID),
        "originalTarget": Self.originalTargetValue(history.originalTarget),
        "binding": Self.bindingValue(binding, includesRevision: true),
      ])
    try appendConfirmed(candidateEventID: candidateEventID, binding: binding)
    hasDurableInitialBinding = true
    identityDisposition = .confirmed
    return try receipt(for: binding)
  }

  public func persistRebind(
    candidate: DeviceRebindCandidate,
    binding: CurrentDeviceBinding,
    context: DeviceRebindContext
  ) throws -> DurableCurrentDeviceBinding {
    let replay = try synchronizeDurableAuthority()
    try requireResolvedMutationAuthority(replay)
    guard hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingNotPersisted
    }
    switch currentState {
    case .running, .waitingForDevice, .awaitingRebindConfirmation:
      break
    default:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
    guard activeDispatchIntentIDs.isEmpty, !mutationJobLeaseAcquisitionInProgress else {
      throw DeviceBindingJournalAdapterError.deviceDispatchInFlight
    }
    guard candidate.connectKey == binding.connectKey,
      candidate.transport == binding.transport,
      candidate.identitySnapshot == binding.identitySnapshot,
      candidate.evidence == binding.evidence
    else { throw DeviceBindingJournalAdapterError.candidateMismatch }
    do {
      try DeviceRebindPolicy.authorizePersistence(
        context: context,
        selectedCandidate: candidate,
        confirmedBy: binding.confirmedBy)
    } catch let error as DeviceRebindAuthorizationError {
      throw DeviceBindingJournalAdapterError.rebindNotAuthorized(error)
    }
    var candidateHistory = history
    try candidateHistory.append(binding)

    identityDisposition = .unconfirmed
    let candidateEventID = eventID()
    try appendCandidate(
      eventID: candidateEventID,
      candidateID: candidate.candidateID,
      connectKey: candidate.connectKey,
      transport: candidate.transport,
      identitySnapshot: candidate.identitySnapshot,
      evidence: candidate.evidence,
      ambiguous: false)
    try appendAudit(
      suffix: "rebind-intent-\(binding.revision)-\(nextSequence)",
      category: .intent,
      details: [
        "eventType": .string("rebindConfirmationIntent"),
        "targetId": .string(history.targetID),
        "oldConnectKey": history.current.connectKey.map(JSONValue.string) ?? .null,
        "newConnectKey": binding.connectKey.map(JSONValue.string) ?? .null,
        "binding": Self.bindingValue(binding, includesRevision: true),
      ])
    try appendConfirmed(candidateEventID: candidateEventID, binding: binding)
    history = candidateHistory
    try appendConfirmedRebindTransitionsIfNeeded()
    identityDisposition = .confirmed
    return try receipt(for: binding)
  }

  public func recordRejectedCandidates(
    _ candidates: [DeviceRebindCandidate],
    reason: DeviceBindingRejectionReason
  ) throws {
    try synchronizeDurableAuthority()
    guard hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingNotPersisted
    }
    guard !candidates.isEmpty else {
      if case .confirmed = identityDisposition {
        identityDisposition = .unconfirmed
      }
      try appendWaitingForDeviceTransitionIfNeeded()
      try appendAudit(
        suffix: "no-candidate-\(nextSequence)",
        category: .outcome,
        details: [
          "eventType": .string("bindingCandidatesUnavailable"),
          "targetId": .string(history.targetID),
          "candidateIds": .array([]),
          "reason": .string(reason.rawValue),
          "state": .string((currentState ?? .waitingForDevice).rawValue),
        ])
      return
    }
    identityDisposition =
      candidates.count > 1 || reason == .ambiguous
      ? .ambiguous(candidateIDs: candidates.map(\.candidateID)) : .unconfirmed
    var candidateEventIDs: [String] = []
    for candidate in candidates {
      let candidateEventID = eventID()
      try appendCandidate(
        eventID: candidateEventID,
        candidateID: candidate.candidateID,
        connectKey: candidate.connectKey,
        transport: candidate.transport,
        identitySnapshot: candidate.identitySnapshot,
        evidence: candidate.evidence,
        ambiguous: candidates.count > 1 || reason == .ambiguous)
      candidateEventIDs.append(candidateEventID)
    }

    for (candidate, candidateEventID) in zip(candidates, candidateEventIDs) {
      try append(
        JournalEvent(
          eventID: eventID(),
          sequence: nextSequence,
          sessionID: auditStore.layout.sessionID,
          jobID: auditStore.layout.jobID,
          timestamp: timestamp(),
          kind: .bindingRejected,
          payload: [
            "candidateEventId": .string(candidateEventID),
            "reason": .string(reason.rawValue),
            "evidence": .array(candidate.evidence.map(JSONValue.string)),
          ]))
    }
    try appendAwaitingRebindTransitions()
    try appendAudit(
      suffix: "rejected-\(nextSequence)",
      category: .outcome,
      details: [
        "eventType": .string("bindingRejected"),
        "targetId": .string(history.targetID),
        "candidateIds": .array(candidates.map { .string($0.candidateID) }),
        "reason": .string(reason.rawValue),
        "state": .string(JobState.awaitingRebindConfirmation.rawValue),
      ])
  }

  package func persistStepIntent(
    step: WorkflowStep,
    attempt: Int
  ) throws -> DurableHDCDeviceCommandIntent {
    let replay = try synchronizeDurableAuthority()
    if step.effect >= .deviceMutation {
      try requireResolvedMutationAuthority(replay)
    }
    guard hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingNotPersisted
    }
    let durableBinding = try receipt(for: history.current)
    let decision = DeviceEffectGate.evaluate(
      effect: step.effect,
      intendedBinding: durableBinding.reference,
      durableBinding: durableBinding,
      identity: identityDisposition)
    if case .rejected(let reason) = decision {
      throw DeviceBindingJournalAdapterError.effectRejected(reason)
    }
    guard currentState == .running else {
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
    if step.effect >= .deviceMutation {
      _ = try durableBinding.binding.identitySnapshot.stablePhysicalIdentitySha256()
    }
    let commandIntent = try HDCDeviceCommandIntent(
      step: step,
      bindingReference: durableBinding.reference)
    let intentEventID = eventID()
    try append(
      JournalEvent.stepIntent(
        eventID: intentEventID,
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        step: step,
        target: JournalTarget(
          scope: "device",
          targetID: history.targetID,
          connectKey: durableBinding.binding.connectKey,
          identitySnapshotHash: try durableBinding.binding.identitySnapshot.sha256()),
        attempt: attempt,
        bindingRevision: durableBinding.reference.revision))
    durableCommandIntents[intentEventID] = commandIntent
    return try DurableHDCDeviceCommandIntent(
      journalIntentEventID: intentEventID,
      intent: commandIntent)
  }

  package func dispatchAuthorized(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    using dispatcher: any HDCDeviceCommandDispatching
  ) async throws -> HDCDeviceCommandDispatchReceipt {
    let replay = try synchronizeDurableAuthority()
    guard durableCommandIntents[durableIntent.journalIntentEventID] == durableIntent.intent else {
      throw DeviceBindingJournalAdapterError.commandIntentNotDurable
    }
    if durableIntent.intent.step.effect >= .deviceMutation {
      try requireResolvedMutationAuthority(replay)
    }
    guard !dispatchedCommandIntentIDs.contains(durableIntent.journalIntentEventID) else {
      throw DeviceBindingJournalAdapterError.commandIntentAlreadyDispatched
    }
    guard durableIntent.intent.step.effect >= .deviceMutation else {
      return try await dispatchWithCurrentAuthority(durableIntent, using: dispatcher)
    }
    guard activeDispatchIntentIDs.isEmpty else {
      throw DeviceBindingJournalAdapterError.deviceDispatchInFlight
    }
    _ = try authorizedCommand(for: durableIntent)
    try await ensureExclusiveMutationJobLease()
    return try await dispatchWithCurrentAuthority(durableIntent, using: dispatcher)
  }

  /// Releases this Job's exclusive device ownership only after the locked journal proves that the
  /// Job is durably terminal and has no unresolved side-effect outcome.
  public func releaseExclusiveMutationLaneAfterDurableTerminal() async throws {
    guard activeDispatchIntentIDs.isEmpty, !mutationJobLeaseAcquisitionInProgress else {
      throw DeviceBindingJournalAdapterError.deviceDispatchInFlight
    }
    let replay = try synchronizeDurableAuthority()
    guard let durableState = replay.currentState,
      durableState.isTerminal,
      !replay.hasTornTail,
      replay.outstandingIntents.isEmpty,
      replay.unknownOutcomes.isEmpty,
      !replay.requiresRecovery
    else { throw DeviceBindingJournalAdapterError.mutationJobNotDurablyTerminal }
    let requestIdentity = mutationJobRequestIdentity
    guard
      let adoptedLease = try await mutationLane.adoptActiveLease(
        requestIdentity: requestIdentity,
        ownerID: mutationLaneOwnerID)
    else {
      mutationJobLease = nil
      return
    }
    try await mutationLane.releaseLease(adoptedLease)
    mutationJobLease = nil
  }

  private func ensureExclusiveMutationJobLease() async throws {
    let replay = try synchronizeDurableAuthority()
    try requireResolvedMutationAuthority(replay)
    let deviceID = try history.current.identitySnapshot.stablePhysicalIdentitySha256()
    if mutationJobLease?.deviceID == deviceID { return }
    guard !mutationJobLeaseAcquisitionInProgress else {
      throw DeviceBindingJournalAdapterError.deviceDispatchInFlight
    }
    mutationJobLeaseAcquisitionInProgress = true
    defer { mutationJobLeaseAcquisitionInProgress = false }
    if let previousLease = mutationJobLease {
      try await mutationLane.releaseLease(previousLease)
      mutationJobLease = nil
    }
    mutationJobLease = try await mutationLane.acquireLease(
      deviceID: deviceID,
      requestIdentity: mutationJobRequestIdentity,
      ownerID: mutationLaneOwnerID)
  }

  private func dispatchWithCurrentAuthority(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    using dispatcher: any HDCDeviceCommandDispatching
  ) async throws -> HDCDeviceCommandDispatchReceipt {
    guard durableIntent.intent.step.effect >= .deviceMutation else {
      return try await dispatchAfterFinalAuthorityCheck(durableIntent, using: dispatcher)
    }
    guard let lease = mutationJobLease else {
      throw DeviceBindingJournalAdapterError.deviceDispatchInFlight
    }
    try await mutationLane.beginDispatch(lease)
    do {
      let receipt = try await dispatchAfterFinalAuthorityCheck(durableIntent, using: dispatcher)
      try await mutationLane.endDispatch(lease)
      return receipt
    } catch {
      try? await mutationLane.endDispatch(lease)
      throw error
    }
  }

  private func dispatchAfterFinalAuthorityCheck(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    using dispatcher: any HDCDeviceCommandDispatching
  ) async throws -> HDCDeviceCommandDispatchReceipt {
    let command = try authorizedCommand(for: durableIntent)
    dispatchedCommandIntentIDs.insert(durableIntent.journalIntentEventID)
    activeDispatchIntentIDs.insert(durableIntent.journalIntentEventID)
    defer { activeDispatchIntentIDs.remove(durableIntent.journalIntentEventID) }
    return try await dispatcher.dispatch(command)
  }

  private func authorizedCommand(
    for durableIntent: DurableHDCDeviceCommandIntent
  ) throws -> HDCDeviceCommand {
    let replay = try synchronizeDurableAuthority()
    guard durableCommandIntents[durableIntent.journalIntentEventID] == durableIntent.intent else {
      throw DeviceBindingJournalAdapterError.commandIntentNotDurable
    }
    if durableIntent.intent.step.effect >= .deviceMutation {
      try requireResolvedMutationAuthority(replay)
    }
    guard !dispatchedCommandIntentIDs.contains(durableIntent.journalIntentEventID) else {
      throw DeviceBindingJournalAdapterError.commandIntentAlreadyDispatched
    }
    let currentBinding = try currentDurableBinding()
    guard durableIntent.intent.bindingReference == currentBinding.reference else {
      throw DeviceBindingJournalAdapterError.bindingMismatch
    }
    let decision = DeviceEffectGate.evaluate(
      effect: durableIntent.intent.step.effect,
      intendedBinding: durableIntent.intent.bindingReference,
      durableBinding: currentBinding,
      identity: identityDisposition)
    if case .rejected(let reason) = decision {
      throw DeviceBindingJournalAdapterError.effectRejected(reason)
    }
    guard currentState == .running else {
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
    return try HDCDeviceCommandMaterializer.materialize(durableIntent, from: currentBinding)
  }

  public func recordReconcileAwaiting(
    recoveryAttemptID: String,
    trigger: DeviceBindingReconcileTrigger,
    evidence: [String]
  ) throws {
    try synchronizeDurableAuthority()
    let lastDurableSequence = max(nextSequence - 1, 0)
    try append(
      JournalEvent.reconcileStarted(
        eventID: eventID(),
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        recoveryAttemptID: recoveryAttemptID,
        sourceState: .waitingForRecovery,
        lastDurableSequence: lastDurableSequence,
        trigger: trigger.rawValue))
    try append(
      JournalEvent.reconcileOutcome(
        eventID: eventID(),
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        bindingRevision: nil,
        recoveryAttemptID: recoveryAttemptID,
        result: "waitingForRecovery",
        nextState: .waitingForRecovery,
        outcomeCertainty: .confirmed,
        safeBoundaryConfirmed: false,
        evidence: evidence))
  }

  public func currentDurableBinding() throws -> DurableCurrentDeviceBinding {
    guard hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingNotPersisted
    }
    return try receipt(for: history.current)
  }

  public func manifestSnapshot() throws -> DeviceBindingManifestSnapshot {
    guard hasDurableInitialBinding else {
      throw DeviceBindingJournalAdapterError.initialBindingNotPersisted
    }
    return DeviceBindingManifestSnapshot(
      originalTarget: Self.originalTargetValue(history.originalTarget),
      bindingHistory: history.bindings.map {
        Self.bindingValue($0, includesRevision: true)
      })
  }

  public func bindingHistory() -> DeviceBindingHistory { history }

  private var mutationJobRequestIdentity: DeviceMutationLaneRequestIdentity {
    .job(
      sessionID: auditStore.layout.sessionID,
      jobID: auditStore.layout.jobID)
  }

  private func requireResolvedMutationAuthority(_ replay: JournalReplay) throws {
    let knownUndispatchedIntentIDs = Set(durableCommandIntents.keys).subtracting(
      dispatchedCommandIntentIDs)
    let hasUncertainOutstandingIntent = replay.outstandingIntents.contains { intent in
      !knownUndispatchedIntentIDs.contains(intent.eventID)
    }
    let hasNonIntentRecoveryBoundary =
      replay.hasTornTail
      || !replay.unknownOutcomes.isEmpty
      || replay.lastReconcileOutcomeCertainty == .outcomeUnknown
      || currentState == .waitingForRecovery
      || currentState == .reconciling
      || currentState == .userAbandonRequested
    let replayRequiresRecoveryBeyondKnownUndispatchedIntents =
      replay.requiresRecovery
      && (hasUncertainOutstandingIntent || hasNonIntentRecoveryBoundary)
    let recoveryBoundaryRequiresMutationStop =
      replayRequiresRecoveryBeyondKnownUndispatchedIntents
      || replay.requiresUnknownFinalizedOutcome
      || replay.pendingAbandonment != nil
    guard recoveryBoundaryRequiresMutationStop else { return }
    try appendWaitingForRecoveryTransitionIfNeeded()
    throw DeviceBindingJournalAdapterError.mutationRecoveryRequired
  }

  private func appendWaitingForRecoveryTransitionIfNeeded() throws {
    guard let state = currentState, state != .waitingForRecovery else { return }
    guard JobStateMachine.isAllowedTransition(from: state, to: .waitingForRecovery, mode: .execute)
    else { return }
    try appendStateTransition(
      from: state,
      to: .waitingForRecovery,
      reason: "mutationOutcomeRequiresRecovery")
  }

  @discardableResult
  private func synchronizeDurableAuthority() throws -> JournalReplay {
    let replay = try DurableJournalRecovery.inspect(url: auditStore.layout.journalURL)
    guard replay.events.first?.kind == .jobCreated,
      replay.events.allSatisfy({
        $0.sessionID == auditStore.layout.sessionID && $0.jobID == auditStore.layout.jobID
      })
    else { throw DeviceBindingJournalAdapterError.journalIdentityMismatch }
    currentState = replay.currentState
    nextSequence = (replay.lastDurableSequence ?? -1) + 1
    identityDisposition = Self.restoredIdentityDisposition(from: replay)
    dispatchedCommandIntentIDs.formUnion(replay.events.compactMap(\.correlatedIntentEventID))
    return replay
  }

  private func receipt(for binding: CurrentDeviceBinding) throws -> DurableCurrentDeviceBinding {
    try DurableCurrentDeviceBinding(
      reference: DeviceBindingReference(targetID: history.targetID, revision: binding.revision),
      binding: binding)
  }

  private func appendCandidate(
    eventID: String,
    candidateID: String,
    connectKey: String?,
    transport: DeviceTransport,
    identitySnapshot: DeviceIdentitySnapshot,
    evidence: [String],
    ambiguous: Bool
  ) throws {
    try append(
      JournalEvent(
        eventID: eventID,
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        kind: .bindingCandidate,
        payload: [
          "candidateId": .string(candidateID),
          "connectKey": connectKey.map(JSONValue.string) ?? .null,
          "transport": .string(transport.rawValue),
          "identitySnapshot": .object(identitySnapshot.attributes),
          "evidence": .array(evidence.map(JSONValue.string)),
          "ambiguity": .string(ambiguous ? "ambiguous" : "unambiguous"),
        ]))
  }

  private func appendConfirmed(
    candidateEventID: String,
    binding: CurrentDeviceBinding
  ) throws {
    try append(
      JournalEvent(
        eventID: eventID(),
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        kind: .bindingConfirmed,
        bindingRevision: binding.revision,
        payload: [
          "candidateEventId": .string(candidateEventID),
          "binding": Self.bindingValue(binding, includesRevision: false),
        ]))
  }

  private func appendAwaitingRebindTransitions() throws {
    switch currentState {
    case .running:
      try appendStateTransition(from: .running, to: .waitingForDevice, reason: "deviceDisconnected")
      try appendStateTransition(
        from: .waitingForDevice,
        to: .awaitingRebindConfirmation,
        reason: "bindingCandidateAmbiguous")
    case .waitingForDevice:
      try appendStateTransition(
        from: .waitingForDevice,
        to: .awaitingRebindConfirmation,
        reason: "bindingCandidateAmbiguous")
    case .awaitingRebindConfirmation:
      return
    case .none:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(.queued)
    default:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
  }

  private func appendWaitingForDeviceTransitionIfNeeded() throws {
    switch currentState {
    case .running:
      try appendStateTransition(
        from: .running,
        to: .waitingForDevice,
        reason: "deviceDisconnectedNoCandidate")
    case .waitingForDevice, .awaitingRebindConfirmation:
      return
    case .none:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(.queued)
    default:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
  }

  private func appendConfirmedRebindTransitionsIfNeeded() throws {
    switch currentState {
    case .awaitingRebindConfirmation:
      try appendStateTransition(
        from: .awaitingRebindConfirmation,
        to: .waitingForDevice,
        reason: "bindingConfirmed")
      try appendStateTransition(
        from: .waitingForDevice,
        to: .running,
        reason: "deviceRebound")
    case .waitingForDevice:
      try appendStateTransition(
        from: .waitingForDevice,
        to: .running,
        reason: "deviceRebound")
    case .running:
      return
    case .none:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(.queued)
    default:
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
  }

  private func appendStateTransition(from: JobState, to: JobState, reason: String) throws {
    guard currentState == from else {
      throw DeviceBindingJournalAdapterError.unsupportedStateTransition(currentState ?? .queued)
    }
    try append(
      JournalEvent.stateTransition(
        eventID: eventID(),
        sequence: nextSequence,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        timestamp: timestamp(),
        from: from,
        to: to,
        reason: reason))
  }

  private func appendAudit(
    suffix: String,
    category: SessionAuditCategory,
    details: [String: JSONValue]
  ) throws {
    try auditStore.appendAndSynchronize(
      SessionAuditRecord(
        recordID: "binding-\(suffix)",
        auditID: "device-binding-\(history.targetID)",
        correlationID: "device-binding-\(history.targetID)",
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        category: category,
        timestamp: timestamp(),
        details: details))
  }

  private func append(_ event: JournalEvent) throws {
    try journal.appendAndSynchronize(event)
    nextSequence += 1
    switch event.kind {
    case .stateTransition:
      if case .string(let rawState)? = event.payload["to"] {
        currentState = JobState(rawValue: rawState)
      }
    case .reconcileOutcome:
      if case .string(let rawState)? = event.payload["nextState"] {
        currentState = JobState(rawValue: rawState)
      }
    default:
      break
    }
  }

  private static func restoredIdentityDisposition(
    from replay: JournalReplay
  ) -> DeviceIdentityDisposition {
    guard
      let lastConfirmationSequence = replay.events.last(where: {
        $0.kind == .bindingConfirmed
      })?.sequence
    else { return .unconfirmed }

    let laterEvents = replay.events.filter { $0.sequence > lastConfirmationSequence }
    let laterCandidates = laterEvents.filter { $0.kind == .bindingCandidate }
    guard !laterCandidates.isEmpty else {
      return replay.currentState == .running ? .confirmed : .unconfirmed
    }
    let candidateIDs = laterCandidates.compactMap { event -> String? in
      guard case .string(let candidateID)? = event.payload["candidateId"] else { return nil }
      return candidateID
    }
    let hasAmbiguity =
      laterCandidates.count > 1
      || laterCandidates.contains { $0.payload["ambiguity"] == .string("ambiguous") }
      || laterEvents.contains {
        $0.kind == .bindingRejected && $0.payload["reason"] == .string("ambiguous")
      }
    return hasAmbiguity
      ? .ambiguous(candidateIDs: candidateIDs)
      : .unconfirmed
  }

  private static func restoreHistory(
    targetID: String,
    auditStore: any DurableSessionAuditAppending,
    replay: JournalReplay
  ) throws -> DeviceBindingHistory {
    let records = try auditStore.replay(correlationID: "device-binding-\(targetID)")
    let confirmations = replay.events.filter { $0.kind == .bindingConfirmed }.sorted {
      ($0.bindingRevision ?? 0) < ($1.bindingRevision ?? 0)
    }
    guard !confirmations.isEmpty else {
      throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(1)
    }
    guard let revisionOneConfirmation = confirmations.first,
      revisionOneConfirmation.bindingRevision == 1,
      let initialRecord = records.first(where: { record in
        guard record.details["eventType"] == .string("initialBindingIntent"),
          let value = record.details["binding"],
          let restored = try? binding(from: value)
        else { return false }
        return confirmation(revisionOneConfirmation, matches: restored, in: replay.events)
      }),
      let originalValue = initialRecord.details["originalTarget"],
      let initialValue = initialRecord.details["binding"]
    else { throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(1) }
    let original = try originalTarget(from: originalValue)
    let initial = try binding(from: initialValue)
    var history = try DeviceBindingHistory(
      targetID: targetID, originalTarget: original, initialBinding: initial)

    for revision in 1...confirmations.count {
      let revisionConfirmations = confirmations.filter { $0.bindingRevision == revision }
      guard revisionConfirmations.count == 1,
        let confirmed = revisionConfirmations.first,
        let auditRecord = records.first(where: { record in
          guard let value = record.details["binding"],
            let restored = try? binding(from: value)
          else { return false }
          return restored.revision == revision
            && confirmation(confirmed, matches: restored, in: replay.events)
        }),
        let value = auditRecord.details["binding"]
      else { throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(revision) }
      let restored = try binding(from: value)
      if revision > 1 { try history.append(restored) }
    }
    guard confirmations.count == history.bindings.count else {
      throw DeviceBindingJournalAdapterError.incompleteDurableBindingChain(
        history.bindings.count + 1)
    }
    return history
  }

  private static func confirmation(
    _ event: JournalEvent,
    matches binding: CurrentDeviceBinding,
    in events: [JournalEvent]
  ) -> Bool {
    guard event.bindingRevision == binding.revision,
      event.payload["binding"] == bindingValue(binding, includesRevision: false),
      case .string(let candidateEventID)? = event.payload["candidateEventId"],
      let candidate = events.first(where: {
        $0.kind == .bindingCandidate && $0.eventID == candidateEventID
          && $0.sequence < event.sequence
      }),
      candidate.payload["connectKey"]
        == (binding.connectKey.map(JSONValue.string) ?? .null),
      candidate.payload["transport"] == .string(binding.transport.rawValue),
      candidate.payload["identitySnapshot"] == .object(binding.identitySnapshot.attributes),
      candidate.payload["evidence"] == .array(binding.evidence.map(JSONValue.string))
    else { return false }
    return true
  }

  private static func originalTargetValue(_ target: OriginalTargetSnapshot) -> JSONValue {
    .object([
      "kind": .string(target.kind.rawValue),
      "connectKey": target.connectKey.map(JSONValue.string) ?? .null,
      "transport": .string(target.transport.rawValue),
      "identitySnapshot": .object(target.identitySnapshot.attributes),
    ])
  }

  private static func bindingValue(
    _ binding: CurrentDeviceBinding,
    includesRevision: Bool
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "connectKey": binding.connectKey.map(JSONValue.string) ?? .null,
      "transport": .string(binding.transport.rawValue),
      "identitySnapshot": .object(binding.identitySnapshot.attributes),
      "evidence": .array(binding.evidence.map(JSONValue.string)),
      "confirmedBy": .string(binding.confirmedBy.rawValue),
      "channelProtection": .string(binding.channelProtection.rawValue),
    ]
    if includesRevision { object["revision"] = .integer(Int64(binding.revision)) }
    return .object(object)
  }

  private static func originalTarget(from value: JSONValue) throws -> OriginalTargetSnapshot {
    guard case .object(let object) = value,
      case .string(let kindRaw)? = object["kind"],
      let kind = DeviceTargetKind(rawValue: kindRaw),
      case .string(let transportRaw)? = object["transport"],
      let transport = DeviceTransport(rawValue: transportRaw),
      case .object(let attributes)? = object["identitySnapshot"]
    else { throw DeviceBindingJournalAdapterError.malformedDurableBinding("originalTarget") }
    return try OriginalTargetSnapshot(
      kind: kind,
      connectKey: optionalString(object["connectKey"]),
      transport: transport,
      identitySnapshot: DeviceIdentitySnapshot(attributes: attributes))
  }

  private static func binding(from value: JSONValue) throws -> CurrentDeviceBinding {
    guard case .object(let object) = value,
      case .integer(let revisionValue)? = object["revision"],
      let revision = Int(exactly: revisionValue),
      case .string(let transportRaw)? = object["transport"],
      let transport = DeviceTransport(rawValue: transportRaw),
      case .object(let attributes)? = object["identitySnapshot"],
      case .array(let evidenceValues)? = object["evidence"],
      case .string(let confirmationRaw)? = object["confirmedBy"],
      let confirmation = DeviceBindingConfirmation(rawValue: confirmationRaw),
      case .string(let protectionRaw)? = object["channelProtection"],
      let protection = DeviceChannelProtection(rawValue: protectionRaw)
    else { throw DeviceBindingJournalAdapterError.malformedDurableBinding("binding") }
    let evidence = try evidenceValues.map { value -> String in
      guard case .string(let string) = value else {
        throw DeviceBindingJournalAdapterError.malformedDurableBinding("evidence")
      }
      return string
    }
    return try CurrentDeviceBinding(
      revision: revision,
      connectKey: optionalString(object["connectKey"]),
      transport: transport,
      identitySnapshot: DeviceIdentitySnapshot(attributes: attributes),
      evidence: evidence,
      confirmedBy: confirmation,
      channelProtection: protection)
  }

  private static func optionalString(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
  }
}
