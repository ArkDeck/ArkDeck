// Durable Runtime recovery boundary.
//
// RuntimeJobEngine decides when recovered jobs become live and reports their
// capability outcomes.  This service owns admission-projection repair and
// journal replay, including every journal-only crash-window completion.  It
// never resolves facts, dispatches a provider action, or changes authority.

import ArkDeckCore
import ArkDeckStorage
import Foundation

struct RuntimeRecoveredJob {
  let record: RuntimeJobRecord
  let journal: FileDurableJournal
  let nextSequence: Int
  let completedStepIDs: Set<String>
}

struct RuntimeRecoveryService {
  private let stateDirectory: URL
  private let nowUTC: @Sendable () -> String

  init(stateDirectory: URL, nowUTC: @escaping @Sendable () -> String) {
    self.stateDirectory = stateDirectory
    self.nowUTC = nowUTC
  }

  /// Recreates only the wholly absent projection left by a process loss after
  /// the SQLite admission commit and before the first journal append.  A
  /// partial projection is never guessed at: it is attributable corruption
  /// because it could otherwise hide an external-effect history.
  func restoreInitialAdmissionProjectionIfNeeded(_ persisted: RuntimePersistedJob) throws {
    let directory = jobDirectory(for: persisted.jobID)
    let recordURL = directory.appendingPathComponent("job-record.json")
    let journalURL = directory.appendingPathComponent("journal.jsonl")
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
  func replay(_ persisted: RuntimePersistedJob) throws -> RuntimeRecoveredJob {
    let jobID = persisted.jobID
    let directory = jobDirectory(for: jobID)
    guard var record = try? RuntimeJobRecord.load(from: directory) else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(jobID) has no readable durable record after recovery projection")
    }
    let journalURL = directory.appendingPathComponent("journal.jsonl")
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
          "recovered: completed durable cancellation at journal-confirmed safe boundary; no redispatch")
      case .finalizing:
        try appendTransition(
          to: journal, record: record, sequence: &nextSequence,
          from: .finalizing, to: .failed,
          reason: "finalization was interrupted before its terminal transition")
        inspection = try DurableJournalRecovery.inspect(url: journalURL)
        record.finishedAtUTC = nowUTC()
        if inspection.lastReconcileOutcomeCertainty == .confirmed {
          record.outcomeUnknown = false
          record.recoveryStepID = nil
          record.recoveryIntentEventID = nil
          record.recoveryAction = nil
        }
        record.timeline.append(
          "recovered: finalization interrupted before terminal transition; failed without redispatch")
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
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
  }

  private func appendInitialAdmissionEvents(
    to journal: FileDurableJournal, record: RuntimeJobRecord
  ) throws {
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC, executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC,
        from: .queued, to: .preflight, reason: "recovered committed admission"))
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
        from: from, to: to, reason: reason, triggerEventID: triggerEventID))
    sequence += 1
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
}
