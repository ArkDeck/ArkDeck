import ArkDeckCore
import Foundation

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
    let attemptID = audit.nextEventID()
    let started = try JournalEvent.reconcileStarted(
      eventID: audit.nextEventID(),
      sequence: session.nextSequence,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      recoveryAttemptID: attemptID,
      sourceState: session.state,
      lastDurableSequence: session.replay.lastDurableSequence ?? 0,
      trigger: "startup"
    )
    try journal.appendAndSynchronize(started)

    let result: String
    let state: JobState
    let certainty: JournalOutcomeCertainty
    let safeBoundary: Bool
    let revision: Int?
    let hasUnknownIntent =
      session.outcomeCertainty == .outcomeUnknown
      || !session.replay.outstandingIntents.isEmpty
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
        certainty = provider.outcomeCertainty
        safeBoundary = false
        revision = nil
      }
    }

    let outcome = try JournalEvent.reconcileOutcome(
      eventID: audit.nextEventID(),
      sequence: session.nextSequence + 1,
      sessionID: session.descriptor.sessionID,
      jobID: session.descriptor.jobID,
      timestamp: audit.timestamp(),
      bindingRevision: revision,
      recoveryAttemptID: attemptID,
      result: result,
      nextState: state,
      outcomeCertainty: certainty,
      safeBoundaryConfirmed: safeBoundary,
      evidence: provider.evidence + binding.evidence
    )
    try journal.appendAndSynchronize(outcome)
    return ReconciliationResult(
      state: state,
      outcomeCertainty: certainty,
      durableEventSequences: [started.sequence, outcome.sequence],
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

public protocol DeviceLaneReleasing: Sendable {
  func releaseDeviceLane() throws
}

public protocol StorageClaimReleasing: Sendable {
  func releaseStorageClaim() throws
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
      let intent = try JournalEvent.abandonIntent(
        eventID: intentID,
        sequence: request.nextSequence,
        sessionID: request.sessionID,
        jobID: request.jobID,
        timestamp: audit.timestamp(),
        userConfirmationID: request.userConfirmationID,
        lastConfirmedStep: request.lastConfirmedStepID,
        outcomeCertainty: request.outcomeCertainty,
        managedProcessState: request.managedProcessState,
        deviceHazards: request.deviceHazards
      )
      try journal.appendAndSynchronize(intent)
      durableSequences.append(intent.sequence)

      let requested = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(),
        sequence: request.nextSequence + 1,
        sessionID: request.sessionID,
        jobID: request.jobID,
        timestamp: audit.timestamp(),
        from: .waitingForRecovery,
        to: .userAbandonRequested,
        reason: "durable recovery abandonment intent",
        triggerEventID: intentID
      )
      try journal.appendAndSynchronize(requested)
      durableSequences.append(requested.sequence)

      let stopResult: ManagedProcessStopResult
      do { stopResult = try stopper.stopForRecoveryAbandonment() } catch {
        return rollback(
          request, intentID: intentID, durableSequences: durableSequences,
          sequence: request.nextSequence + 2, result: "failed")
      }
      guard stopResult.permitsAbandonment else {
        return rollback(
          request, intentID: intentID, durableSequences: durableSequences,
          sequence: request.nextSequence + 2, result: "deferred")
      }

      let outcome = try JournalEvent.abandonOutcome(
        eventID: audit.nextEventID(),
        sequence: request.nextSequence + 2,
        sessionID: request.sessionID,
        jobID: request.jobID,
        timestamp: audit.timestamp(),
        correlatesToAbandonIntentEventID: intentID,
        result: "archivedInterrupted",
        releaseAuthorized: true,
        unresolvedHazards: request.deviceHazards
      )
      try journal.appendAndSynchronize(outcome)
      durableSequences.append(outcome.sequence)

      let terminal = try JournalEvent.stateTransition(
        eventID: audit.nextEventID(),
        sequence: request.nextSequence + 3,
        sessionID: request.sessionID,
        jobID: request.jobID,
        timestamp: audit.timestamp(),
        from: .userAbandonRequested,
        to: .interrupted,
        reason: "durable abandon outcome authorizes terminal transition",
        triggerEventID: outcome.eventID
      )
      try journal.appendAndSynchronize(terminal)
      durableSequences.append(terminal.sequence)
      try laneReleaser.releaseDeviceLane()
      try claimReleaser.releaseStorageClaim()
      return RecoveryAbandonmentResult(
        state: .interrupted, durableEventSequences: durableSequences,
        laneReleaseCount: 1, claimReleaseCount: 1)
    } catch {
      return RecoveryAbandonmentResult(
        state: .waitingForRecovery, durableEventSequences: durableSequences,
        laneReleaseCount: 0, claimReleaseCount: 0)
    }
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
      laneReleaseCount: 0, claimReleaseCount: 0)
  }
}
