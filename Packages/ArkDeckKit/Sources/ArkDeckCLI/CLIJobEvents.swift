import ArkDeckAgentClient
import ArkDeckCore
import Darwin
import Foundation

extension RuntimeCLI {
  /// One unary source for events, watch and target wait. Every request gets a
  /// fresh transport ID; only the invocation's output correlation stays fixed.
  static func emitJobEventObservation(
    _ verb: String, rest: [String], session original: CLIRuntimeSession
  ) throws {
    let options = try CLIOptions(rest)
    guard let jobID = options.value("--job"), AgentExecutionIntent.validIdentifier(jobID) else {
      throw original.fail(.invalidInput, "an exact Job identity is required")
    }
    let size = Int(options.value("--page-size") ?? "100") ?? 0
    guard (1...1000).contains(size) else { throw original.fail(.invalidInput, "invalid event page size") }
    if let cursor = options.value("--after-cursor"), cursor.isEmpty || cursor.utf8.count > 2048 {
      throw original.fail(.invalidCursor, "after-cursor must be a bounded opaque cursor")
    }
    let cancellation = AgentClientWaitCancellation()
    let signalObserver = CLIWaitSignalObserver(cancellation: cancellation)
    defer { signalObserver.stop() }
    let deadline: AgentClientWaitDeadline?
    if let duration = options.value("--timeout") {
      guard let parsed = CLIDuration.parse(duration, maximumMilliseconds: 86_400_000) else {
        throw original.fail(.invalidInput, "timeout must be a bounded duration")
      }
      deadline = try AgentClientWaitDeadline(milliseconds: parsed.milliseconds, cancellation: cancellation)
    } else { deadline = nil }
    var session = original
    func check() throws {
      if cancellation.isCancelled { throw AgentClientWaitInterrupted() }
      try deadline?.check()
    }
    func boundRequest() throws {
      try check()
      // No overall timeout was requested: only this unary exchange has a 30s
      // transport budget. An explicit user timeout is never renewed here.
      session.client = session.client.bounded(by: try deadline ?? AgentClientWaitDeadline(
        milliseconds: 30_000, cancellation: cancellation))
    }
    func request(_ method: String, _ fields: [String: JSONValue]) throws -> JSONValue {
      var retries = 0
      while true {
        try boundRequest()
        do { return try session.request(method, fields) }
        catch let error as CLIRegistryError where error.code == .runtimeUnavailable && retries < 2 {
          retries += 1
          try pause(100)
        }
      }
    }
    func pause(_ milliseconds: Int) throws {
      for _ in 0..<max(1, milliseconds / 50) {
        try check()
        Thread.sleep(forTimeInterval: Double(min(50, deadline?.remainingMilliseconds ?? 50)) / 1000)
      }
      try check()
    }
    var cursor = options.value("--after-cursor")
    var lastCursor: String?
    var lastPosition: Int64?
    var lastRevision: Int64?
    var recentIDs: [String] = []
    var recentPositions: [String: Int64] = [:]
    var sequence = 1
    var finalExit: Int32 = 0
    var terminalStatus: JSONValue?
    func failStream(_ error: CLIRegistryError) throws {
      var failure = session.stamped(error)
      failure.command = session.command
      failure.details["jobId"] = .string(jobID)
      if let cursor { failure.details["afterCursor"] = .string(cursor) }
      if session.rendering == .jsonlStream {
        FileHandle.standardOutput.write(Data(CLIEventEnvelope.terminalFailure(
          command: session.command, sequence: sequence, error: failure,
          controlRequestID: session.controlRequestID, lastCursor: lastCursor).utf8))
        session.outputState.hasEmitted = true
        failure.suppressesMachineRendering = true
      }
      throw failure
    }
    do {
      try boundRequest()

      while true {
        var fields: [String: JSONValue] = ["jobId": .string(jobID), "pageSize": .integer(Int64(size))]
        if let cursor { fields["afterCursor"] = .string(cursor) }
        let value = try request("job.events", fields)
        let page = try CLIJobEventPage(value, jobID: jobID, maximumItems: size)
        guard lastRevision == nil || page.revision >= lastRevision! else {
          throw session.fail(.recordUnreadable, "event high-water revision moved backwards")
        }
        if verb == "events" { session.emit(value); return }
        for row in page.rows {
          let position = CLIJobEventPage.decimal(row["streamPosition"])!
          let id = CLIJobEventPage.string(row["eventId"])!
          // A replay of the just-delivered page may be deduplicated by its
          // stable event identity, but new identities never get silently lost.
          if let previousPosition = recentPositions[id] {
            guard position == previousPosition else {
              throw session.fail(.recordUnreadable, "event identity was reused at a new position")
            }
            continue
          }
          guard lastPosition == nil || (lastPosition! < Int64.max && position == lastPosition! + 1) else {
            throw session.fail(.recordUnreadable, "event history is not a contiguous exclusive stream")
          }
          if cursor == nil && lastPosition == nil && position != 1 {
            throw session.fail(.eventHistoryUnavailable, "the retained stream origin is unavailable",
              details: ["earliestRetainedPosition": .string(String(position))])
          }
          if session.rendering == .jsonlStream {
            FileHandle.standardOutput.write(Data(CLIEventEnvelope.runtimeEvent(
              command: session.command, sequence: sequence, fields: row,
              controlRequestID: session.controlRequestID).utf8))
            sequence += 1
          } else if session.rendering == .human {
            print(RuntimeCLI.humanRendering(of: .object(row)))
          }
          lastPosition = position
          lastCursor = CLIJobEventPage.string(row["cursor"])
          // Advance immediately after emission so interruption/error resumes
          // from the last delivered row, not from the end of an unseen page.
          cursor = lastCursor
          recentIDs.append(id)
          recentPositions[id] = position
          if recentIDs.count > 1000 { recentPositions.removeValue(forKey: recentIDs.removeFirst()) }
          try check()
        }
        guard page.rows.isEmpty || lastPosition == page.lastPosition,
          !page.rows.isEmpty || lastPosition == nil || page.revision == lastPosition,
          cursor != nil || !page.rows.isEmpty || page.revision == 0
        else {
          throw session.fail(.recordUnreadable, "event page did not advance the delivered stream")
        }
        cursor = page.nextCursor
        lastRevision = page.revision
        if page.hasMore { continue }
        if verb == "wait" {
          if let terminalStatus {
            finalExit = terminalJobExit(terminalStatus)?.code ?? 0
            if session.rendering == .jsonlStream {
              FileHandle.standardOutput.write(Data(CLIEventEnvelope.terminalSuccess(
                command: session.command, sequence: sequence, result: terminalStatus,
                controlRequestID: session.controlRequestID, lastCursor: lastCursor, exitCode: finalExit).utf8))
              session.outputState.hasEmitted = true
            } else { session.emit(terminalStatus) }
            break
          }
          let status = try request("job.status", ["jobId": .string(jobID)])
          let state = try validatedObservedJobStatus(status, jobID: jobID, session: session)
          if state.isTerminal {
            terminalStatus = status
            // Drain once after observing terminal, including durable events
            // appended between the last page and the status query.
            continue
          }
        }
        try pause(250)
      }
    } catch is AgentClientWaitInterrupted {
      try failStream(session.fail(.clientInterrupted, "client observation interrupted; the Job was not cancelled"))
    } catch AgentClientError.deadlineExceeded {
      try failStream(session.fail(.clientTimeout, "client observation timed out; the Job was not cancelled"))
    } catch let error as CLIRegistryError { try failStream(error) }
    catch { try failStream(session.fail(.internalError, "Job events could not be observed")) }
    if finalExit != 0 { throw CLIError(exitCode: finalExit, message: "Job reached a failed terminal state") }
  }

  static func validatedObservedJobStatus(
    _ value: JSONValue, jobID: String, session: CLIRuntimeSession
  ) throws -> JobState {
    func unreadable() -> CLIRegistryError { session.fail(.recordUnreadable, "Job status has no supported next action") }
    guard case .object(let fields) = value,
      fields["schemaVersion"] == .string("arkdeck.job-status/1"), fields["jobId"] == .string(jobID),
      case .string(let raw)? = fields["state"], let state = JobState(rawValue: raw),
      case .bool(let unknown)? = fields["outcomeUnknown"], case .bool(let human)? = fields["waitingForHuman"],
      case .object(let next)? = fields["nextAction"], case .string(let kind)? = next["kind"],
      next["owner"] == .object(["kind": .string("job"), "id": .string(jobID)])
    else { throw unreadable() }
    let base: Set<String> = ["kind", "owner", "resource", "reasonCode"]
    if kind == "humanAction" {
      guard human, !unknown, Set(next.keys) == base.union(["resumeReference", "expiresAt"]),
        case .object(let resource)? = next["resource"], Set(resource.keys) == ["kind", "id"],
        resource["kind"] == .string("humanAction"),
        let id = CLIJobEventPage.string(resource["id"]), AgentExecutionIntent.validIdentifier(id),
        let reference = CLIJobEventPage.string(next["resumeReference"]), AgentExecutionIntent.validIdentifier(reference),
        let reason = CLIJobEventPage.string(next["reasonCode"]),
        [AgentPhysicalActionKind.connectDevice, .trustDevice, .selectDevice].map(\.reasonCode).contains(reason),
        next["expiresAt"] == .null || CLIJobEventPage.string(next["expiresAt"]).flatMap(ISO8601Timestamps.parse) != nil
      else { throw unreadable() }
      throw session.fail(.humanActionRequired, "the Job needs the referenced human action", details: ["nextAction": .object(next)])
    }
    guard !human, next["resource"] == next["owner"] else { throw unreadable() }
    let uncertain = unknown || [.waitingForRecovery, .reconciling].contains(state)
    let expected = uncertain ? "reconcile" : state.isTerminal ? "readResult" : "wait"
    guard kind == expected, Set(next.keys) == (kind == "wait" ? base.union(["retryAfter"]) : base),
      next["reasonCode"] == .string(uncertain ? "recovery.outcomeUnknown" : state.isTerminal ? "job.resultAvailable" : "job.running")
    else { throw unreadable() }
    if kind == "wait" {
      guard let hint = CLIJobEventPage.string(next["retryAfter"]),
        CLIDuration.parse(hint, maximumMilliseconds: 86_400_000) != nil else { throw unreadable() }
    }
    if uncertain {
      throw session.fail(.outcomeUnknown, "the Job requires reconciliation; observation never replays an effect",
        details: ["nextAction": .object(next)])
    }
    return state
  }
}

/// Validates the full page before any row reaches stdout. Unknown branches,
/// duplicate identity, unordered positions and changed Job ownership fail closed.
struct CLIJobEventPage {
  let rows: [[String: JSONValue]]
  let revision: Int64
  let nextCursor: String
  let hasMore: Bool
  var lastPosition: Int64? { rows.last.flatMap { Self.decimal($0["streamPosition"]) } }

  init(_ value: JSONValue, jobID: String, maximumItems: Int) throws {
    func invalid() -> CLIRegistryError { .init(code: .recordUnreadable, message: "the Runtime returned an invalid durable event page") }
    guard case .object(let fields) = value,
      Set(fields.keys) == ["schemaVersion", "pageKind", "items", "order", "snapshotRevision", "hasMore", "nextCursor"],
      fields["schemaVersion"] == .string("arkdeck.cli.page/1"), fields["pageKind"] == .string("eventStream"),
      fields["order"] == .string("streamPositionAsc"), let revision = Self.decimal(fields["snapshotRevision"]),
      case .array(let values)? = fields["items"], values.count <= maximumItems,
      case .bool(let more)? = fields["hasMore"], let cursor = Self.string(fields["nextCursor"]),
      !cursor.isEmpty, cursor.utf8.count <= 2048, !more || !values.isEmpty
    else { throw invalid() }
    var rows: [[String: JSONValue]] = []
    var previous: Int64?
    var ids: Set<String> = []
    for value in values {
      guard case .object(let row) = value,
        Set(row.keys) == ["eventId", "streamPosition", "runtimeRevision", "cursor", "type", "data"],
        let id = Self.string(row["eventId"]), !id.isEmpty, id.utf8.count <= 512, ids.insert(id).inserted,
        let position = Self.decimal(row["streamPosition"]), position > 0, position <= revision,
        previous == nil || (previous! < Int64.max && position == previous! + 1),
        Self.decimal(row["runtimeRevision"]) == revision,
        let cursor = Self.string(row["cursor"]), !cursor.isEmpty, cursor.utf8.count <= 2048,
        case .object(let data)? = row["data"], data["jobId"] == .string(jobID),
        let kind = Self.string(data["journalKind"]), let type = JobEventProjectionContract.eventType(forJournalKind: kind),
        row["type"] == .string(type)
      else { throw invalid() }
      let keys: Set<String> = ["jobId", "sessionId", "journalKind", "timestamp", "stepId", "attempt", "bindingRevision"]
      guard Set(data.keys) == (kind == "stateTransition" ? keys.union(["fromState", "toState"]) : keys),
        let session = Self.string(data["sessionId"]), !session.isEmpty, session.utf8.count <= 512,
        let timestamp = Self.string(data["timestamp"]), ISO8601Timestamps.parse(timestamp) != nil,
        data["stepId"] == .null || (Self.string(data["stepId"])?.utf8.count ?? 513) <= 512,
        data["attempt"] == .null || Self.decimal(data["attempt"]) != nil,
        data["bindingRevision"] == .null || Self.decimal(data["bindingRevision"]) != nil
      else { throw invalid() }
      if kind == "stateTransition" {
        guard Self.string(data["fromState"]).flatMap(JobState.init(rawValue:)) != nil,
          Self.string(data["toState"]).flatMap(JobState.init(rawValue:)) != nil else { throw invalid() }
      }
      rows.append(row)
      previous = position
    }
    guard more || previous == nil || previous == revision else { throw invalid() }
    self.rows = rows; self.revision = revision; self.nextCursor = cursor; self.hasMore = more
  }

  static func string(_ value: JSONValue?) -> String? { if case .string(let text) = value { text } else { nil } }
  static func decimal(_ value: JSONValue?) -> Int64? {
    guard let text = string(value), let number = Int64(text), number >= 0, String(number) == text else { return nil }
    return number
  }
}

final class CLIWaitSignalObserver {
  private let source: DispatchSourceSignal
  // SIG_DFL is a null function pointer, not a missing initialization.
  private let prior: sig_t?
  init(cancellation: AgentClientWaitCancellation) {
    prior = signal(SIGINT, SIG_IGN)
    source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
    source.setEventHandler { cancellation.cancel() }
    source.resume()
  }
  func stop() { source.cancel(); signal(SIGINT, prior) }
}
