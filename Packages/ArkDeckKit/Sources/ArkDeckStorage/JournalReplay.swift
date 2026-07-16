import ArkDeckCore
import Foundation

public struct OutstandingJournalIntent: Equatable, Sendable {
  public let eventID: String
  public let stepID: String
  public let attempt: Int
  public let effect: WorkflowEffect
  public let bindingRevision: Int?
}

public struct UnknownJournalOutcome: Equatable, Sendable {
  public let eventID: String
  public let correlatedIntentEventID: String
  public let stepID: String
  public let attempt: Int
  public let effect: WorkflowEffect
  public let isCompensation: Bool
}

struct PendingReconcileTransition: Equatable, Sendable {
  let attemptID: String
  let outcomeEventID: String
  let nextState: JobState
}

public enum RecoveryAbandonmentPhase: String, CaseIterable, Equatable, Sendable {
  case intentDurable
  case requested
  case outcomeDurable
}

public struct PendingRecoveryAbandonment: Equatable, Sendable {
  public let intentEventID: String
  public let phase: RecoveryAbandonmentPhase
  public let outcomeEventID: String?
  public let releaseAuthorized: Bool?
  public let deviceHazards: [String]
  public let outcomeCertainty: JournalOutcomeCertainty
}

public struct JournalReplay: Equatable, Sendable {
  public let events: [JournalEvent]
  public let hasTornTail: Bool
  public let executionMode: String?
  public let currentState: JobState?
  public let lastDurableSequence: Int?
  public let outstandingIntents: [OutstandingJournalIntent]
  public let unknownOutcomes: [UnknownJournalOutcome]
  public let requiredAbandonmentHazards: [String]
  public let latestBindingRevision: Int?
  public let lastConfirmedStepID: String?
  public let lastReconcileOutcomeCertainty: JournalOutcomeCertainty?
  public let resourceReleaseAuthorized: Bool
  public let requiresUnknownFinalizedOutcome: Bool
  public let pendingAbandonment: PendingRecoveryAbandonment?
  public let finalized: Bool
  let pendingReconcileTransition: PendingReconcileTransition?

  public var requiresRecovery: Bool {
    hasTornTail || !outstandingIntents.isEmpty || !unknownOutcomes.isEmpty
      || lastReconcileOutcomeCertainty == .outcomeUnknown
      || currentState == .waitingForRecovery || currentState == .reconciling
      || currentState == .userAbandonRequested
      || pendingReconcileTransition != nil
  }

  public var destructiveReplayCount: Int { 0 }
  public var guessCompensationCount: Int { 0 }
}

public enum DurableJournalRecovery {
  public static func inspect(url: URL) throws -> JournalReplay {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else {
      return JournalReplay(
        events: [], hasTornTail: false, executionMode: nil, currentState: nil,
        lastDurableSequence: nil, outstandingIntents: [], unknownOutcomes: [],
        requiredAbandonmentHazards: [],
        latestBindingRevision: nil, lastConfirmedStepID: nil,
        lastReconcileOutcomeCertainty: nil, resourceReleaseAuthorized: false,
        requiresUnknownFinalizedOutcome: false,
        pendingAbandonment: nil, finalized: false, pendingReconcileTransition: nil)
    }

    let hasTerminatingNewline = data.last == 0x0A
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    let completedLines = lines.dropLast()
    var events: [JournalEvent] = []
    events.reserveCapacity(completedLines.count)
    for (offset, line) in completedLines.enumerated() {
      guard !line.isEmpty else { throw DurableFileError.malformedCompletedRecord(line: offset + 1) }
      do {
        events.append(try JournalEventCodec.decode(Data(line)))
      } catch {
        throw DurableFileError.malformedCompletedRecord(line: offset + 1)
      }
    }
    return try validate(events: events, hasTornTail: !hasTerminatingNewline)
  }

  private static func validate(events: [JournalEvent], hasTornTail: Bool) throws -> JournalReplay {
    if let first = events.first {
      guard first.sequence == 0, first.kind == .jobCreated else {
        throw DurableFileError.sequenceViolation(
          "first durable event must be sequence 0 jobCreated")
      }
    }

    var previousSequence: Int?
    var sessionID: String?
    var jobID: String?
    var eventIDs: Set<String> = []
    var executionMode: String?
    var state: JobState?
    var latestBindingRevision: Int?
    var lastConfirmedStepID: String?
    var finalized = false
    var intents: [String: OutstandingJournalIntent] = [:]
    var completedIntentIDs: Set<String> = []
    var unknownOutcomes: [UnknownJournalOutcome] = []
    var hasUnknownOutcome = false
    var abandonIntentIDs: Set<String> = []
    var completedAbandonIntentIDs: Set<String> = []
    var activeAbandonIntentID: String?
    var activeAbandonHazards: [String]?
    var activeAbandonOutcomeCertainty: JournalOutcomeCertainty?
    var pendingAbandonOutcomeID: String?
    var pendingAbandonNextState: JobState?
    var resourceReleaseAuthorized = false
    var requiresUnknownFinalizedOutcome = false
    var recoveryAttemptIDs: Set<String> = []
    var completedRecoveryAttemptIDs: Set<String> = []
    var pendingReconcileTransition: PendingReconcileTransition?
    var lastReconcileOutcomeCertainty: JournalOutcomeCertainty?

    for event in events {
      if let previousSequence, event.sequence != previousSequence + 1 {
        throw DurableFileError.sequenceViolation(
          "sequence \(event.sequence) does not follow \(previousSequence)")
      }
      previousSequence = event.sequence
      if let sessionID, sessionID != event.sessionID {
        throw DurableFileError.sequenceViolation("sessionId changed within journal")
      }
      if let jobID, jobID != event.jobID {
        throw DurableFileError.sequenceViolation("jobId changed within journal")
      }
      sessionID = event.sessionID
      jobID = event.jobID
      guard eventIDs.insert(event.eventID).inserted else {
        throw DurableFileError.sequenceViolation("duplicate eventId \(event.eventID)")
      }
      guard !finalized else {
        throw DurableFileError.sequenceViolation("event follows finalized record")
      }
      if state?.isTerminal == true, event.kind != .finalized {
        throw DurableFileError.sequenceViolation("non-final event follows terminal state")
      }
      if pendingReconcileTransition != nil, event.kind != .stateTransition {
        throw DurableFileError.sequenceViolation(
          "reconcile outcome must be followed by its state transition")
      }
      if pendingAbandonOutcomeID != nil, event.kind != .stateTransition {
        throw DurableFileError.sequenceViolation(
          "abandon outcome must be followed by its state transition")
      }
      if hasUnknownOutcome {
        if event.kind == .stepIntent || event.kind == .compensationIntent {
          throw DurableFileError.sequenceViolation(
            "outcomeUnknown is followed by another external-effect intent")
        }
        let isAuthorizedAbandonTransition =
          event.kind == .stateTransition
          && state == .userAbandonRequested
          && event.stateTransition?.to == .interrupted
          && pendingAbandonNextState == .interrupted
          && event.payload.string("triggerEventId") == pendingAbandonOutcomeID
        if state != .waitingForRecovery, state != .reconciling,
          event.kind == .stateTransition,
          event.stateTransition?.to != .waitingForRecovery,
          !isAuthorizedAbandonTransition
        {
          throw DurableFileError.sequenceViolation(
            "outcomeUnknown is not followed by waitingForRecovery")
        }
      }

      switch event.kind {
      case .jobCreated:
        guard event.sequence == 0, executionMode == nil, state == nil else {
          throw DurableFileError.sequenceViolation("duplicate or late jobCreated")
        }
        executionMode = event.payload.string("executionMode")
        state = .queued
      case .stateTransition:
        guard let transition = event.stateTransition else {
          throw DurableFileError.sequenceViolation("malformed transition")
        }
        guard let currentState = state else {
          throw DurableFileError.sequenceViolation("transition precedes jobCreated")
        }
        guard transition.from == currentState else {
          throw DurableFileError.sequenceViolation(
            "transition source \(transition.from.rawValue) does not match \(currentState.rawValue)")
        }
        if let pending = pendingReconcileTransition {
          guard transition.from == .reconciling, transition.to == pending.nextState,
            event.payload.string("triggerEventId") == pending.outcomeEventID
          else {
            throw DurableFileError.sequenceViolation(
              "state transition does not persist reconcile outcome \(pending.attemptID)")
          }
          pendingReconcileTransition = nil
        }
        if let outcomeID = pendingAbandonOutcomeID, let nextState = pendingAbandonNextState {
          guard transition.from == .userAbandonRequested, transition.to == nextState,
            event.payload.string("triggerEventId") == outcomeID
          else {
            throw DurableFileError.sequenceViolation(
              "state transition does not persist abandon outcome")
          }
          if nextState == .interrupted {
            resourceReleaseAuthorized = true
            if activeAbandonOutcomeCertainty == .outcomeUnknown {
              requiresUnknownFinalizedOutcome = true
            }
          }
          activeAbandonIntentID = nil
          activeAbandonHazards = nil
          activeAbandonOutcomeCertainty = nil
          pendingAbandonOutcomeID = nil
          pendingAbandonNextState = nil
        } else if transition.from == .userAbandonRequested {
          throw DurableFileError.sequenceViolation(
            "abandon transition has no durable correlated outcome")
        }
        if transition.to == .userAbandonRequested {
          guard transition.from == .waitingForRecovery,
            event.payload.string("triggerEventId") == activeAbandonIntentID
          else {
            throw DurableFileError.sequenceViolation(
              "userAbandonRequested transition has no active abandon intent")
          }
        } else if activeAbandonIntentID != nil, transition.from == .waitingForRecovery {
          throw DurableFileError.sequenceViolation(
            "durable abandon intent must transition to userAbandonRequested")
        }
        let hasOutstandingIntent = intents.values.contains { intent in
          !completedIntentIDs.contains(intent.eventID)
        }
        if hasOutstandingIntent,
          transition.to == .finalizing || transition.to.isTerminal
        {
          guard transition.to == .interrupted, resourceReleaseAuthorized else {
            throw DurableFileError.sequenceViolation(
              "unresolved intent cannot enter finalization or terminal state")
          }
        }
        state = transition.to
      case .stepIntent:
        guard state?.permitsJournalIntent == true,
          let stepID = event.stepID, let attempt = event.attempt, let effect = event.stepEffect
        else {
          throw DurableFileError.sequenceViolation("intent is missing typed step data")
        }
        intents[event.eventID] = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: effect,
          bindingRevision: event.bindingRevision)
      case .compensationIntent:
        guard state?.permitsJournalIntent == true,
          let stepID = event.stepID, let attempt = event.attempt
        else {
          throw DurableFileError.sequenceViolation("compensation intent is incomplete")
        }
        intents[event.eventID] = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: .deviceMutation,
          bindingRevision: event.bindingRevision)
      case .stepOutcome, .compensationOutcome:
        guard let correlation = event.correlatedIntentEventID, let intent = intents[correlation],
          !completedIntentIDs.contains(correlation),
          intent.stepID == event.stepID, intent.attempt == event.attempt
        else {
          throw DurableFileError.sequenceViolation("invalid or duplicate outcome correlation")
        }
        completedIntentIDs.insert(correlation)
        if event.payload.string("outcomeCertainty") == JournalOutcomeCertainty.confirmed.rawValue {
          lastConfirmedStepID = event.stepID
        } else {
          hasUnknownOutcome = true
          unknownOutcomes.append(
            UnknownJournalOutcome(
              eventID: event.eventID,
              correlatedIntentEventID: correlation,
              stepID: intent.stepID,
              attempt: intent.attempt,
              effect: intent.effect,
              isCompensation: event.kind == .compensationOutcome))
        }
      case .bindingConfirmed:
        guard let revision = event.bindingRevision,
          latestBindingRevision.map({ revision > $0 }) ?? true
        else { throw DurableFileError.sequenceViolation("binding revision did not increase") }
        latestBindingRevision = revision
      case .reconcileStarted:
        guard let attemptID = event.payload.string("recoveryAttemptId"),
          recoveryAttemptIDs.insert(attemptID).inserted,
          state == .reconciling,
          event.payload.string("sourceState") == JobState.waitingForRecovery.rawValue
        else { throw DurableFileError.sequenceViolation("duplicate recovery attempt") }
      case .reconcileOutcome:
        guard let attemptID = event.payload.string("recoveryAttemptId"),
          recoveryAttemptIDs.contains(attemptID),
          completedRecoveryAttemptIDs.insert(attemptID).inserted,
          state == .reconciling,
          let nextStateRaw = event.payload.string("nextState"),
          let nextState = JobState(rawValue: nextStateRaw),
          JobStateMachine.isAllowedTransition(
            from: .reconciling, to: nextState,
            mode: executionMode == JobExecutionMode.planOnly.rawValue ? .planOnly : .execute),
          let certaintyRaw = event.payload.string("outcomeCertainty"),
          let certainty = JournalOutcomeCertainty(rawValue: certaintyRaw)
        else { throw DurableFileError.sequenceViolation("orphan reconcile outcome") }
        pendingReconcileTransition = PendingReconcileTransition(
          attemptID: attemptID, outcomeEventID: event.eventID, nextState: nextState)
        lastReconcileOutcomeCertainty = certainty
        if let revision = event.bindingRevision {
          latestBindingRevision = max(latestBindingRevision ?? 0, revision)
        }
      case .abandonIntent:
        let requiresOutcomeUnknown =
          hasUnknownOutcome
          || intents.values.contains { !completedIntentIDs.contains($0.eventID) }
        guard state == .waitingForRecovery, activeAbandonIntentID == nil,
          abandonIntentIDs.insert(event.eventID).inserted,
          let hazards = event.payload.journalStringArray("deviceHazards"),
          let certaintyRaw = event.payload.string("outcomeCertainty"),
          let certainty = JournalOutcomeCertainty(rawValue: certaintyRaw),
          !requiresOutcomeUnknown || certainty == .outcomeUnknown,
          Set(hazards).isSuperset(
            of: Set(
              derivedAbandonmentHazards(
                intents: intents.values.filter {
                  !completedIntentIDs.contains($0.eventID)
                }, unknownOutcomes: unknownOutcomes)))
        else {
          throw DurableFileError.sequenceViolation(
            "abandon intent must start from waitingForRecovery and preserve device hazards")
        }
        activeAbandonIntentID = event.eventID
        activeAbandonHazards = hazards
        activeAbandonOutcomeCertainty = certainty
      case .abandonOutcome:
        guard let correlation = event.payload.string("correlatesToAbandonIntentEventId"),
          abandonIntentIDs.contains(correlation),
          completedAbandonIntentIDs.insert(correlation).inserted,
          correlation == activeAbandonIntentID,
          state == .userAbandonRequested,
          let releaseAuthorized = event.payload.bool("releaseAuthorized"),
          let unresolvedHazards = event.payload.journalStringArray("unresolvedHazards"),
          let activeAbandonHazards,
          Set(unresolvedHazards).isSuperset(of: Set(activeAbandonHazards))
        else { throw DurableFileError.sequenceViolation("orphan abandon outcome") }
        pendingAbandonOutcomeID = event.eventID
        pendingAbandonNextState = releaseAuthorized ? .interrupted : .waitingForRecovery
      case .finalized:
        guard pendingReconcileTransition == nil, pendingAbandonOutcomeID == nil,
          let state, state.isTerminal
        else {
          throw DurableFileError.sequenceViolation(
            "finalized record does not match a completed terminal lifecycle")
        }
        guard event.payload.string("terminalStatus") == state.rawValue else {
          throw DurableFileError.sequenceViolation(
            "finalized terminalStatus does not match the durable Job state")
        }
        let hasOutstandingIntent = intents.values.contains { intent in
          !completedIntentIDs.contains(intent.eventID)
        }
        guard
          !hasOutstandingIntent
            || (state == .interrupted && resourceReleaseAuthorized)
        else {
          throw DurableFileError.sequenceViolation(
            "finalized record does not match a completed terminal lifecycle")
        }
        if hasOutstandingIntent || hasUnknownOutcome || requiresUnknownFinalizedOutcome {
          guard state == .interrupted,
            event.payload.string("outcomeCertainty") != "confirmed"
          else {
            throw DurableFileError.sequenceViolation(
              "finalized certainty cannot confirm an unresolved intent or unknown outcome")
          }
        }
        finalized = true
      default:
        break
      }
    }

    let outstanding = intents.values
      .filter { !completedIntentIDs.contains($0.eventID) }
      .sorted { lhs, rhs in lhs.eventID < rhs.eventID }
    unknownOutcomes.sort { lhs, rhs in lhs.eventID < rhs.eventID }
    let requiredAbandonmentHazards = derivedAbandonmentHazards(
      intents: outstanding, unknownOutcomes: unknownOutcomes)
    let pendingAbandonment: PendingRecoveryAbandonment?
    if let intentEventID = activeAbandonIntentID {
      if let outcomeEventID = pendingAbandonOutcomeID {
        pendingAbandonment = PendingRecoveryAbandonment(
          intentEventID: intentEventID,
          phase: .outcomeDurable,
          outcomeEventID: outcomeEventID,
          releaseAuthorized: pendingAbandonNextState == .interrupted,
          deviceHazards: activeAbandonHazards ?? [],
          outcomeCertainty: activeAbandonOutcomeCertainty ?? .outcomeUnknown)
      } else {
        pendingAbandonment = PendingRecoveryAbandonment(
          intentEventID: intentEventID,
          phase: state == .userAbandonRequested ? .requested : .intentDurable,
          outcomeEventID: nil,
          releaseAuthorized: nil,
          deviceHazards: activeAbandonHazards ?? [],
          outcomeCertainty: activeAbandonOutcomeCertainty ?? .outcomeUnknown)
      }
    } else {
      pendingAbandonment = nil
    }
    return JournalReplay(
      events: events,
      hasTornTail: hasTornTail,
      executionMode: executionMode,
      currentState: pendingReconcileTransition?.nextState ?? state,
      lastDurableSequence: previousSequence,
      outstandingIntents: outstanding,
      unknownOutcomes: unknownOutcomes,
      requiredAbandonmentHazards: requiredAbandonmentHazards,
      latestBindingRevision: latestBindingRevision,
      lastConfirmedStepID: lastConfirmedStepID,
      lastReconcileOutcomeCertainty: lastReconcileOutcomeCertainty,
      resourceReleaseAuthorized: resourceReleaseAuthorized,
      requiresUnknownFinalizedOutcome: requiresUnknownFinalizedOutcome,
      pendingAbandonment: pendingAbandonment,
      finalized: finalized,
      pendingReconcileTransition: pendingReconcileTransition
    )
  }
}

struct JournalAppendValidationState {
  private var lastSequence: Int?
  private var sessionID: String?
  private var jobID: String?
  private var eventIDs: Set<String>
  private var currentState: JobState?
  private var outstanding: [String: OutstandingJournalIntent]
  private var unresolvedDeviceHazards: Set<String>
  private var hasUnknownOutcome: Bool
  private var latestBindingRevision: Int?
  private var recoveryAttempts: Set<String>
  private var completedRecoveryAttempts: Set<String>
  private var pendingReconcileTransition: PendingReconcileTransition?
  private var abandonIntents: Set<String>
  private var completedAbandonIntents: Set<String>
  private var activeAbandonIntentID: String?
  private var activeAbandonHazards: [String]?
  private var activeAbandonOutcomeCertainty: JournalOutcomeCertainty?
  private var pendingAbandonOutcomeID: String?
  private var pendingAbandonNextState: JobState?
  private var resourceReleaseAuthorized: Bool
  private var requiresUnknownFinalizedOutcome: Bool
  private var finalized: Bool

  init(replay: JournalReplay) throws {
    guard !replay.hasTornTail else {
      throw DurableFileError.sequenceViolation("cannot append after a torn tail")
    }
    lastSequence = replay.lastDurableSequence
    sessionID = replay.events.last?.sessionID
    jobID = replay.events.last?.jobID
    eventIDs = Set(replay.events.map(\.eventID))
    pendingReconcileTransition = replay.pendingReconcileTransition
    currentState = pendingReconcileTransition == nil ? replay.currentState : .reconciling
    outstanding = Dictionary(
      uniqueKeysWithValues: replay.outstandingIntents.map { ($0.eventID, $0) })
    unresolvedDeviceHazards = Set(replay.requiredAbandonmentHazards)
    hasUnknownOutcome = !replay.unknownOutcomes.isEmpty
    latestBindingRevision = replay.latestBindingRevision
    recoveryAttempts = Set(
      replay.events.filter { $0.kind == .reconcileStarted }
        .compactMap { $0.payload.string("recoveryAttemptId") })
    completedRecoveryAttempts = Set(
      replay.events.filter { $0.kind == .reconcileOutcome }
        .compactMap { $0.payload.string("recoveryAttemptId") })
    abandonIntents = Set(replay.events.filter { $0.kind == .abandonIntent }.map(\.eventID))
    completedAbandonIntents = Set(
      replay.events.filter { $0.kind == .abandonOutcome }
        .compactMap { $0.payload.string("correlatesToAbandonIntentEventId") })
    activeAbandonIntentID = replay.pendingAbandonment?.intentEventID
    activeAbandonHazards = replay.pendingAbandonment?.deviceHazards
    activeAbandonOutcomeCertainty = replay.pendingAbandonment?.outcomeCertainty
    if let pending = replay.pendingAbandonment, pending.phase == .outcomeDurable {
      pendingAbandonOutcomeID = pending.outcomeEventID
      pendingAbandonNextState =
        pending.releaseAuthorized == true
        ? .interrupted : .waitingForRecovery
    } else {
      pendingAbandonOutcomeID = nil
      pendingAbandonNextState = nil
    }
    resourceReleaseAuthorized = replay.resourceReleaseAuthorized
    requiresUnknownFinalizedOutcome = replay.requiresUnknownFinalizedOutcome
    finalized = replay.finalized
  }

  var abandonmentContext: JournalAbandonmentContext {
    JournalAbandonmentContext(
      requiredHazards: unresolvedDeviceHazards.sorted(),
      requiresOutcomeUnknown: !outstanding.isEmpty || hasUnknownOutcome)
  }

  func validate(_ event: JournalEvent) throws {
    if let lastSequence {
      guard event.sequence == lastSequence + 1 else {
        throw DurableFileError.sequenceViolation("append sequence is not contiguous")
      }
      guard event.sessionID == sessionID, event.jobID == jobID else {
        throw DurableFileError.sequenceViolation("append identity changed")
      }
    } else {
      guard event.sequence == 0, event.kind == .jobCreated else {
        throw DurableFileError.sequenceViolation(
          "first durable event must be sequence 0 jobCreated")
      }
    }
    guard !eventIDs.contains(event.eventID), !finalized else {
      throw DurableFileError.sequenceViolation("duplicate eventId or finalized journal")
    }
    if currentState?.isTerminal == true, event.kind != .finalized {
      throw DurableFileError.sequenceViolation("non-final event follows terminal state")
    }
    if pendingReconcileTransition != nil, event.kind != .stateTransition {
      throw DurableFileError.sequenceViolation(
        "reconcile outcome must be followed by its state transition")
    }
    if pendingAbandonOutcomeID != nil, event.kind != .stateTransition {
      throw DurableFileError.sequenceViolation(
        "abandon outcome must be followed by its state transition")
    }
    if hasUnknownOutcome {
      if event.kind == .stepIntent || event.kind == .compensationIntent {
        throw DurableFileError.sequenceViolation(
          "outcomeUnknown blocks subsequent external-effect intent")
      }
      let isAuthorizedAbandonTransition =
        event.kind == .stateTransition
        && currentState == .userAbandonRequested
        && event.stateTransition?.to == .interrupted
        && pendingAbandonNextState == .interrupted
        && event.payload.string("triggerEventId") == pendingAbandonOutcomeID
      if currentState != .waitingForRecovery, currentState != .reconciling,
        event.kind == .stateTransition,
        event.stateTransition?.to != .waitingForRecovery,
        !isAuthorizedAbandonTransition
      {
        throw DurableFileError.sequenceViolation(
          "outcomeUnknown requires transition to waitingForRecovery")
      }
    }

    switch event.kind {
    case .jobCreated:
      guard lastSequence == nil else {
        throw DurableFileError.sequenceViolation("jobCreated must be first")
      }
    case .stateTransition:
      guard let transition = event.stateTransition, let current = currentState,
        transition.from == current
      else {
        throw DurableFileError.sequenceViolation("transition source is not current state")
      }
      if let pending = pendingReconcileTransition {
        guard transition.from == .reconciling, transition.to == pending.nextState,
          event.payload.string("triggerEventId") == pending.outcomeEventID
        else {
          throw DurableFileError.sequenceViolation(
            "state transition does not persist reconcile outcome")
        }
      }
      if let outcomeID = pendingAbandonOutcomeID, let nextState = pendingAbandonNextState {
        guard transition.from == .userAbandonRequested, transition.to == nextState,
          event.payload.string("triggerEventId") == outcomeID
        else {
          throw DurableFileError.sequenceViolation(
            "state transition does not persist abandon outcome")
        }
      } else if transition.from == .userAbandonRequested {
        throw DurableFileError.sequenceViolation(
          "abandon transition has no durable correlated outcome")
      }
      if transition.to == .userAbandonRequested {
        guard transition.from == .waitingForRecovery,
          event.payload.string("triggerEventId") == activeAbandonIntentID
        else {
          throw DurableFileError.sequenceViolation(
            "userAbandonRequested transition has no active abandon intent")
        }
      } else if activeAbandonIntentID != nil, transition.from == .waitingForRecovery {
        throw DurableFileError.sequenceViolation(
          "durable abandon intent must transition to userAbandonRequested")
      }
      let hasOutstandingIntent = !outstanding.isEmpty
      if hasOutstandingIntent,
        transition.to == .finalizing || transition.to.isTerminal
      {
        let authorizesInterrupted =
          transition.to == .interrupted
          && pendingAbandonNextState == .interrupted
          && event.payload.string("triggerEventId") == pendingAbandonOutcomeID
        guard authorizesInterrupted else {
          throw DurableFileError.sequenceViolation(
            "unresolved intent cannot enter finalization or terminal state")
        }
      }
    case .stepIntent, .compensationIntent:
      guard currentState?.permitsJournalIntent == true else {
        throw DurableFileError.sequenceViolation(
          "current Job state does not permit external-effect intent")
      }
    case .stepOutcome, .compensationOutcome:
      guard let correlation = event.correlatedIntentEventID,
        let intent = outstanding[correlation],
        intent.stepID == event.stepID, intent.attempt == event.attempt
      else { throw DurableFileError.sequenceViolation("outcome does not match outstanding intent") }
    case .bindingConfirmed:
      guard let revision = event.bindingRevision,
        latestBindingRevision.map({ revision > $0 }) ?? true
      else { throw DurableFileError.sequenceViolation("binding revision did not increase") }
    case .reconcileOutcome:
      guard let attempt = event.payload.string("recoveryAttemptId"),
        recoveryAttempts.contains(attempt), !completedRecoveryAttempts.contains(attempt),
        currentState == .reconciling,
        let nextStateRaw = event.payload.string("nextState"),
        let nextState = JobState(rawValue: nextStateRaw),
        JobStateMachine.isAllowedTransition(
          from: .reconciling, to: nextState, mode: .execute)
          || JobStateMachine.isAllowedTransition(
            from: .reconciling, to: nextState, mode: .planOnly)
      else {
        throw DurableFileError.sequenceViolation("reconcile outcome has no durable start")
      }
    case .reconcileStarted:
      guard let attempt = event.payload.string("recoveryAttemptId"),
        !recoveryAttempts.contains(attempt), currentState == .reconciling,
        event.payload.string("sourceState") == JobState.waitingForRecovery.rawValue
      else {
        throw DurableFileError.sequenceViolation(
          "reconcile start must follow waitingForRecovery to reconciling")
      }
    case .abandonIntent:
      let requiresOutcomeUnknown = !outstanding.isEmpty || hasUnknownOutcome
      guard currentState == .waitingForRecovery, activeAbandonIntentID == nil,
        let hazards = event.payload.journalStringArray("deviceHazards"),
        let certaintyRaw = event.payload.string("outcomeCertainty"),
        let certainty = JournalOutcomeCertainty(rawValue: certaintyRaw),
        !requiresOutcomeUnknown || certainty == .outcomeUnknown,
        Set(hazards).isSuperset(of: unresolvedDeviceHazards)
      else {
        throw DurableFileError.sequenceViolation(
          "abandon intent must start from waitingForRecovery and preserve device hazards")
      }
    case .abandonOutcome:
      guard let correlation = event.payload.string("correlatesToAbandonIntentEventId"),
        abandonIntents.contains(correlation), !completedAbandonIntents.contains(correlation),
        correlation == activeAbandonIntentID,
        currentState == .userAbandonRequested,
        let unresolvedHazards = event.payload.journalStringArray("unresolvedHazards"),
        let activeAbandonHazards,
        Set(unresolvedHazards).isSuperset(of: Set(activeAbandonHazards))
      else { throw DurableFileError.sequenceViolation("abandon outcome has no durable intent") }
    case .finalized:
      guard let state = currentState, state.isTerminal else {
        throw DurableFileError.sequenceViolation("finalized requires a terminal Job state")
      }
      guard state.rawValue == event.payload.string("terminalStatus") else {
        throw DurableFileError.sequenceViolation("finalized status does not match Job state")
      }
      let hasOutstandingIntent = !outstanding.isEmpty
      guard
        !hasOutstandingIntent
          || (state == .interrupted && resourceReleaseAuthorized)
      else {
        throw DurableFileError.sequenceViolation(
          "finalized cannot hide an unresolved external-effect intent")
      }
      if hasOutstandingIntent || hasUnknownOutcome || requiresUnknownFinalizedOutcome {
        guard event.payload.string("outcomeCertainty") != "confirmed" else {
          throw DurableFileError.sequenceViolation(
            "finalized certainty cannot confirm an unresolved intent or unknown outcome")
        }
      }
    default:
      break
    }
  }

  mutating func accept(_ event: JournalEvent) {
    lastSequence = event.sequence
    sessionID = event.sessionID
    jobID = event.jobID
    eventIDs.insert(event.eventID)
    switch event.kind {
    case .jobCreated:
      currentState = .queued
    case .stateTransition:
      if event.stateTransition?.to == .interrupted,
        pendingAbandonNextState == .interrupted,
        event.payload.string("triggerEventId") == pendingAbandonOutcomeID
      {
        resourceReleaseAuthorized = true
        if activeAbandonOutcomeCertainty == .outcomeUnknown {
          requiresUnknownFinalizedOutcome = true
        }
      }
      if event.stateTransition?.from == .userAbandonRequested {
        activeAbandonIntentID = nil
        activeAbandonHazards = nil
        activeAbandonOutcomeCertainty = nil
      }
      currentState = event.stateTransition?.to
      pendingReconcileTransition = nil
      pendingAbandonOutcomeID = nil
      pendingAbandonNextState = nil
    case .stepIntent:
      if let stepID = event.stepID, let attempt = event.attempt, let effect = event.stepEffect {
        let intent = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: effect,
          bindingRevision: event.bindingRevision)
        outstanding[event.eventID] = intent
        if effect >= .deviceMutation {
          unresolvedDeviceHazards.insert(derivedAbandonmentHazard(for: intent))
        }
      }
    case .compensationIntent:
      if let stepID = event.stepID, let attempt = event.attempt {
        let intent = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: .deviceMutation,
          bindingRevision: event.bindingRevision)
        outstanding[event.eventID] = intent
        unresolvedDeviceHazards.insert(derivedAbandonmentHazard(for: intent))
      }
    case .stepOutcome, .compensationOutcome:
      if let correlation = event.correlatedIntentEventID,
        let intent = outstanding[correlation]
      {
        if event.payload.string("outcomeCertainty")
          == JournalOutcomeCertainty.confirmed.rawValue
        {
          unresolvedDeviceHazards.remove(derivedAbandonmentHazard(for: intent))
        }
        outstanding.removeValue(forKey: correlation)
      }
      if event.payload.string("outcomeCertainty")
        == JournalOutcomeCertainty.outcomeUnknown.rawValue
      {
        hasUnknownOutcome = true
      }
    case .bindingConfirmed:
      latestBindingRevision = event.bindingRevision
    case .reconcileStarted:
      if let attempt = event.payload.string("recoveryAttemptId") {
        recoveryAttempts.insert(attempt)
      }
    case .reconcileOutcome:
      if let attempt = event.payload.string("recoveryAttemptId"),
        let nextStateRaw = event.payload.string("nextState"),
        let nextState = JobState(rawValue: nextStateRaw)
      {
        completedRecoveryAttempts.insert(attempt)
        pendingReconcileTransition = PendingReconcileTransition(
          attemptID: attempt, outcomeEventID: event.eventID, nextState: nextState)
      }
    case .abandonIntent:
      abandonIntents.insert(event.eventID)
      activeAbandonIntentID = event.eventID
      activeAbandonHazards = event.payload.journalStringArray("deviceHazards")
      activeAbandonOutcomeCertainty = event.payload.string("outcomeCertainty")
        .flatMap { JournalOutcomeCertainty(rawValue: $0) }
    case .abandonOutcome:
      if let correlation = event.payload.string("correlatesToAbandonIntentEventId") {
        completedAbandonIntents.insert(correlation)
      }
      pendingAbandonOutcomeID = event.eventID
      pendingAbandonNextState =
        event.payload.bool("releaseAuthorized") == true
        ? .interrupted : .waitingForRecovery
    case .finalized:
      finalized = true
    default:
      break
    }
  }
}

extension JobState {
  fileprivate var permitsJournalIntent: Bool {
    switch self {
    case .queued, .waitingForRecovery, .reconciling, .resumeAtConfirmedSafeBoundary,
      .userAbandonRequested, .planned, .succeeded, .failed, .cancelled, .interrupted:
      false
    default:
      true
    }
  }
}

private func derivedAbandonmentHazard(for intent: OutstandingJournalIntent) -> String {
  derivedAbandonmentHazard(
    eventID: intent.eventID, stepID: intent.stepID, effect: intent.effect)
}

private func derivedAbandonmentHazard(
  eventID: String,
  stepID: String,
  effect: WorkflowEffect
) -> String {
  "unresolved-\(effect.rawValue)-intent:\(stepID):\(eventID)"
}

private func derivedAbandonmentHazards(
  intents: [OutstandingJournalIntent],
  unknownOutcomes: [UnknownJournalOutcome]
) -> [String] {
  var hazards = Set(
    intents.filter { $0.effect >= .deviceMutation }.map {
      derivedAbandonmentHazard(for: $0)
    })
  hazards.formUnion(
    unknownOutcomes.filter { $0.effect >= .deviceMutation }.map {
      derivedAbandonmentHazard(
        eventID: $0.correlatedIntentEventID,
        stepID: $0.stepID,
        effect: $0.effect)
    })
  return hazards.sorted()
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func journalStringArray(_ key: String) -> [String]? {
    guard case .array(let values)? = self[key] else { return nil }
    var result: [String] = []
    result.reserveCapacity(values.count)
    for value in values {
      guard case .string(let string) = value else { return nil }
      result.append(string)
    }
    return result
  }
}

public struct UnfinishedSessionDescriptor: Equatable, Sendable {
  public let sessionID: String
  public let jobID: String
  public let journalURL: URL
  public let checkpointURL: URL

  public init(sessionID: String, jobID: String, journalURL: URL, checkpointURL: URL) {
    self.sessionID = sessionID
    self.jobID = jobID
    self.journalURL = journalURL
    self.checkpointURL = checkpointURL
  }
}

public protocol UnfinishedSessionCatalog: Sendable {
  func unfinishedSessions() throws -> [UnfinishedSessionDescriptor]
}

public enum RecoverySnapshotSource: String, Equatable, Sendable {
  case matchingCheckpoint
  case journalSupersedesCheckpoint
  case journalOnly
}

public struct ScannedRecoverySession: Equatable, Sendable {
  public let descriptor: UnfinishedSessionDescriptor
  public let replay: JournalReplay
  public let state: JobState
  public let outcomeCertainty: JournalOutcomeCertainty
  public let snapshotSource: RecoverySnapshotSource
  public let nextSequence: Int

  public var destructiveDispatchCount: Int { 0 }
  public var destructiveReplayCount: Int { 0 }
  public var guessCompensationCount: Int { 0 }
}

public struct SessionRecoveryScanner: Sendable {
  public init() {}

  public func scan(catalog: any UnfinishedSessionCatalog) throws -> [ScannedRecoverySession] {
    try catalog.unfinishedSessions().compactMap(scan)
  }

  public func scan(_ descriptor: UnfinishedSessionDescriptor) throws -> ScannedRecoverySession? {
    let replay = try DurableJournalRecovery.inspect(url: descriptor.journalURL)
    guard let first = replay.events.first, first.sequence == 0, first.kind == .jobCreated else {
      throw DurableFileError.sequenceViolation(
        "recovery journal must begin with sequence 0 jobCreated")
    }
    if replay.finalized { return nil }
    guard first.sessionID == descriptor.sessionID, first.jobID == descriptor.jobID else {
      throw DurableFileError.sequenceViolation("catalog identity does not match journal")
    }

    let journalState = replay.currentState
    let checkpointExists = FileManager.default.fileExists(atPath: descriptor.checkpointURL.path)
    let snapshotSource: RecoverySnapshotSource
    if checkpointExists {
      let checkpoint = try AtomicJournalCheckpointStore(url: descriptor.checkpointURL).load()
      guard checkpoint.sessionID == descriptor.sessionID, checkpoint.jobID == descriptor.jobID
      else {
        throw DurableFileError.checkpointInvalid("checkpoint identity mismatch")
      }
      guard let lastSequence = replay.lastDurableSequence else {
        throw DurableFileError.checkpointInvalid("checkpoint exists without journal authority")
      }
      guard checkpoint.journalSequence <= lastSequence else {
        throw DurableFileError.checkpointInvalid("checkpoint is ahead of journal")
      }
      if checkpoint.journalSequence == lastSequence {
        if let journalState, checkpoint.state != journalState.rawValue {
          throw DurableFileError.checkpointInvalid("checkpoint state disagrees with journal")
        }
        snapshotSource = .matchingCheckpoint
      } else {
        snapshotSource = .journalSupersedesCheckpoint
      }
    } else {
      snapshotSource = .journalOnly
    }

    let uncertainOutcome =
      replay.hasTornTail || !replay.outstandingIntents.isEmpty
      || !replay.unknownOutcomes.isEmpty
      || replay.lastReconcileOutcomeCertainty == .outcomeUnknown
      || replay.pendingAbandonment != nil
    let interruptedRecovery = journalState == .reconciling
    let state: JobState
    if uncertainOutcome || journalState == .userAbandonRequested || interruptedRecovery {
      state = .waitingForRecovery
    } else {
      state = journalState ?? .waitingForRecovery
    }
    return ScannedRecoverySession(
      descriptor: descriptor,
      replay: replay,
      state: state,
      outcomeCertainty: uncertainOutcome ? .outcomeUnknown : .confirmed,
      snapshotSource: snapshotSource,
      nextSequence: (replay.lastDurableSequence ?? -1) + 1
    )
  }
}
