import ArkDeckCore
import Foundation

public struct OutstandingJournalIntent: Equatable, Sendable {
  public let eventID: String
  public let stepID: String
  public let attempt: Int
  public let effect: WorkflowEffect
  public let bindingRevision: Int?
}

public struct JournalReplay: Equatable, Sendable {
  public let events: [JournalEvent]
  public let hasTornTail: Bool
  public let executionMode: String?
  public let currentState: JobState?
  public let lastDurableSequence: Int?
  public let outstandingIntents: [OutstandingJournalIntent]
  public let latestBindingRevision: Int?
  public let lastConfirmedStepID: String?
  public let finalized: Bool

  public var requiresRecovery: Bool {
    hasTornTail || !outstandingIntents.isEmpty || currentState == .userAbandonRequested
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
        lastDurableSequence: nil, outstandingIntents: [], latestBindingRevision: nil,
        lastConfirmedStepID: nil, finalized: false)
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
    var abandonIntentIDs: Set<String> = []
    var recoveryAttemptIDs: Set<String> = []

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

      switch event.kind {
      case .jobCreated:
        guard executionMode == nil, state == nil else {
          throw DurableFileError.sequenceViolation("duplicate or late jobCreated")
        }
        executionMode = event.payload.string("executionMode")
        state = .queued
      case .stateTransition:
        guard let transition = event.stateTransition else {
          throw DurableFileError.sequenceViolation("malformed transition")
        }
        if let state, transition.from != state {
          throw DurableFileError.sequenceViolation(
            "transition source \(transition.from.rawValue) does not match \(state.rawValue)")
        }
        state = transition.to
      case .stepIntent:
        guard let stepID = event.stepID, let attempt = event.attempt, let effect = event.stepEffect
        else {
          throw DurableFileError.sequenceViolation("intent is missing typed step data")
        }
        intents[event.eventID] = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: effect,
          bindingRevision: event.bindingRevision)
      case .compensationIntent:
        guard let stepID = event.stepID, let attempt = event.attempt else {
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
        if event.payload.string("outcomeCertainty") == "confirmed" {
          lastConfirmedStepID = event.stepID
        }
      case .bindingConfirmed:
        guard let revision = event.bindingRevision,
          latestBindingRevision.map({ revision > $0 }) ?? true
        else { throw DurableFileError.sequenceViolation("binding revision did not increase") }
        latestBindingRevision = revision
      case .reconcileStarted:
        guard let attemptID = event.payload.string("recoveryAttemptId"),
          recoveryAttemptIDs.insert(attemptID).inserted
        else { throw DurableFileError.sequenceViolation("duplicate recovery attempt") }
      case .reconcileOutcome:
        guard let attemptID = event.payload.string("recoveryAttemptId"),
          recoveryAttemptIDs.contains(attemptID)
        else { throw DurableFileError.sequenceViolation("orphan reconcile outcome") }
        if let revision = event.bindingRevision {
          latestBindingRevision = max(latestBindingRevision ?? 0, revision)
        }
      case .abandonIntent:
        abandonIntentIDs.insert(event.eventID)
      case .abandonOutcome:
        guard let correlation = event.payload.string("correlatesToAbandonIntentEventId"),
          abandonIntentIDs.contains(correlation)
        else { throw DurableFileError.sequenceViolation("orphan abandon outcome") }
      case .finalized:
        finalized = true
      default:
        break
      }
    }

    let outstanding = intents.values
      .filter { !completedIntentIDs.contains($0.eventID) }
      .sorted { lhs, rhs in lhs.eventID < rhs.eventID }
    return JournalReplay(
      events: events,
      hasTornTail: hasTornTail,
      executionMode: executionMode,
      currentState: state,
      lastDurableSequence: previousSequence,
      outstandingIntents: outstanding,
      latestBindingRevision: latestBindingRevision,
      lastConfirmedStepID: lastConfirmedStepID,
      finalized: finalized
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
  private var latestBindingRevision: Int?
  private var recoveryAttempts: Set<String>
  private var abandonIntents: Set<String>
  private var finalized: Bool

  init(replay: JournalReplay) throws {
    guard !replay.hasTornTail else {
      throw DurableFileError.sequenceViolation("cannot append after a torn tail")
    }
    lastSequence = replay.lastDurableSequence
    sessionID = replay.events.last?.sessionID
    jobID = replay.events.last?.jobID
    eventIDs = Set(replay.events.map(\.eventID))
    currentState = replay.currentState
    outstanding = Dictionary(
      uniqueKeysWithValues: replay.outstandingIntents.map { ($0.eventID, $0) })
    latestBindingRevision = replay.latestBindingRevision
    recoveryAttempts = Set(
      replay.events.filter { $0.kind == .reconcileStarted }
        .compactMap { $0.payload.string("recoveryAttemptId") })
    abandonIntents = Set(replay.events.filter { $0.kind == .abandonIntent }.map(\.eventID))
    finalized = replay.finalized
  }

  func validate(_ event: JournalEvent) throws {
    if let lastSequence {
      guard event.sequence == lastSequence + 1 else {
        throw DurableFileError.sequenceViolation("append sequence is not contiguous")
      }
      guard event.sessionID == sessionID, event.jobID == jobID else {
        throw DurableFileError.sequenceViolation("append identity changed")
      }
    }
    guard !eventIDs.contains(event.eventID), !finalized else {
      throw DurableFileError.sequenceViolation("duplicate eventId or finalized journal")
    }

    switch event.kind {
    case .jobCreated:
      guard lastSequence == nil else {
        throw DurableFileError.sequenceViolation("jobCreated must be first")
      }
    case .stateTransition:
      if let current = currentState {
        guard event.stateTransition?.from == current else {
          throw DurableFileError.sequenceViolation("transition source is not current state")
        }
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
        recoveryAttempts.contains(attempt)
      else {
        throw DurableFileError.sequenceViolation("reconcile outcome has no durable start")
      }
    case .abandonOutcome:
      guard let correlation = event.payload.string("correlatesToAbandonIntentEventId"),
        abandonIntents.contains(correlation)
      else { throw DurableFileError.sequenceViolation("abandon outcome has no durable intent") }
    case .finalized:
      guard let state = currentState,
        state.rawValue == event.payload.string("terminalStatus")
      else { throw DurableFileError.sequenceViolation("finalized status does not match Job state") }
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
      currentState = event.stateTransition?.to
    case .stepIntent:
      if let stepID = event.stepID, let attempt = event.attempt, let effect = event.stepEffect {
        outstanding[event.eventID] = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: effect,
          bindingRevision: event.bindingRevision)
      }
    case .compensationIntent:
      if let stepID = event.stepID, let attempt = event.attempt {
        outstanding[event.eventID] = OutstandingJournalIntent(
          eventID: event.eventID, stepID: stepID, attempt: attempt, effect: .deviceMutation,
          bindingRevision: event.bindingRevision)
      }
    case .stepOutcome, .compensationOutcome:
      if let correlation = event.correlatedIntentEventID {
        outstanding.removeValue(forKey: correlation)
      }
    case .bindingConfirmed:
      latestBindingRevision = event.bindingRevision
    case .reconcileStarted:
      if let attempt = event.payload.string("recoveryAttemptId") {
        recoveryAttempts.insert(attempt)
      }
    case .abandonIntent:
      abandonIntents.insert(event.eventID)
    case .finalized:
      finalized = true
    default:
      break
    }
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
    if replay.finalized { return nil }
    if let first = replay.events.first {
      guard first.sessionID == descriptor.sessionID, first.jobID == descriptor.jobID else {
        throw DurableFileError.sequenceViolation("catalog identity does not match journal")
      }
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

    let uncertain = replay.hasTornTail || !replay.outstandingIntents.isEmpty
    let state: JobState
    if uncertain || journalState == .userAbandonRequested {
      state = .waitingForRecovery
    } else {
      state = journalState ?? .waitingForRecovery
    }
    return ScannedRecoverySession(
      descriptor: descriptor,
      replay: replay,
      state: state,
      outcomeCertainty: uncertain ? .outcomeUnknown : .confirmed,
      snapshotSource: snapshotSource,
      nextSequence: (replay.lastDurableSequence ?? -1) + 1
    )
  }
}
