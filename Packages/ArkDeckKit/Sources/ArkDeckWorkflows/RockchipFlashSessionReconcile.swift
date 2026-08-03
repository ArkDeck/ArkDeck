import ArkDeckCore
import ArkDeckStorage
import Foundation

// Host-side recovery inspection for Rockchip flash sessions.
//
// The flash execution host writes a durable session journal
// (`<sessionsRoot>/<sessionID>/journal.jsonl`) but, unlike the runtime
// engine's job store, nothing replayed those journals after a crash: a
// killed `arkdeck flash execute` left a dangling destructive `stepIntent`
// nobody decoded, and — on the standing-authorization lane — an open
// usage-ledger reservation that nothing could ever close, permanently
// blocking the authorization's ordinal chain.
//
// This reconciler is the read side. It never dispatches anything and never
// touches a device: it reads the original durable intent, reports which
// destructive commands have no confirmed outcome, and (only when asked)
// closes the orphaned standing-authorization reservation with an honest
// terminal status. `outcomeUnknown` never resurrects an authorization —
// a consumed ordinal stays consumed; recovery of the device itself remains
// a human/E2 decision informed by this report.
//
// Campaign-lane sessions are reported but never closed here: the campaign
// ledger's tombstone semantics belong to `RockchipEvolutionCampaignHost`
// (`flash continue` reconciles them), and a second writer would race it.

/// Whole-run liveness protocol between the flash executor and the
/// reconciler. The executor holds an exclusive `flock` on the session's
/// run-lock file for the lifetime of its durable persistence; the kernel
/// releases it on any process death, so "lock held" is a truthful liveness
/// signal with no PID guessing and no staleness window. Sessions created
/// before this protocol have no lock file, which correctly reads as dead.
package enum RockchipFlashSessionRunLock {
  package static let fileName = ".run.lock"

  /// Executor side: acquire for the whole run. Fails when another live
  /// process already owns this session directory.
  package static func acquire(sessionRoot: URL) throws -> Int32 {
    let path = sessionRoot.appending(path: fileName).path
    let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RockchipFlashSessionReconcileError.sessionsRootUnavailable(
        "cannot create run lock at \(path): errno \(errno)")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let heldErrno = errno
      Darwin.close(descriptor)
      throw RockchipFlashSessionReconcileError.sessionsRootUnavailable(
        "session run lock is already held (errno \(heldErrno)); a live run owns \(path)")
    }
    return descriptor
  }

  package static func release(_ descriptor: Int32) {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  /// Reconciler side: a shared probe that never blocks. Absent file means
  /// no live run (pre-protocol sessions and crashed runs both land here).
  package static func isHeld(sessionRoot: URL) -> Bool {
    let path = sessionRoot.appending(path: fileName).path
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
      flock(descriptor, LOCK_UN)
      return false
    }
    return true
  }
}

public struct RockchipFlashSessionFinding: Sendable, Equatable {
  public enum AuthorityLane: String, Sendable {
    case standingAuthorization
    case agentCampaign
    case none
  }

  public enum LedgerState: Sendable, Equatable {
    /// Standing-authorization reservation named by the journal is still open.
    case openStandingReservation(reservationID: String)
    /// Campaign/agent reservation named by the journal is still open.
    case openAgentReservation(reservationID: String)
    /// The reservation named by the journal already carries a terminal.
    case closed(reservationID: String)
    /// The journal names a reservation the ledger does not contain.
    case missing(reservationID: String)
    /// The journal records no usage reservation.
    case none
  }

  public let sessionID: String
  public let jobID: String?
  public let sessionRootPath: String
  public let schemaVersion: String?
  public let currentState: JobState?
  public let finalized: Bool
  public let hasTornTail: Bool
  /// A live process holds this session's run lock right now. Live sessions
  /// are never attention and never closable: the owner will write its own
  /// terminal, and closing under it would falsify a write-once record.
  public let isLive: Bool
  /// Journal could not be replayed at all (corrupt beyond the torn-tail
  /// repair the durable format tolerates). Fail closed: treated as unknown.
  public let journalError: String?
  public let outstandingIntents: [OutstandingJournalIntent]
  public let unknownOutcomes: [UnknownJournalOutcome]
  public let lastConfirmedStepID: String?
  public let lane: AuthorityLane
  /// Campaign identity derived from the journal's confirmation reference,
  /// so an operator can be pointed at `flash continue --campaign-id …`.
  public let campaignID: String?
  public let ledgerState: LedgerState

  /// Every mutating intent whose outcome the journal confirmed — what the
  /// dead process's own successful closeUsage would have carried.
  public let confirmedMutationIntentEventIDs: [String]

  /// Destructive/mutating intents with no confirmed outcome — the exact
  /// event IDs an honest ledger terminal must carry.
  public var unresolvedMutationIntentEventIDs: [String] {
    var identifiers: [String] = []
    for intent in outstandingIntents where intent.effect >= .deviceMutation {
      identifiers.append(intent.eventID)
    }
    for outcome in unknownOutcomes where outcome.effect >= .deviceMutation {
      identifiers.append(outcome.correlatedIntentEventID)
    }
    var seen: Set<String> = []
    return identifiers.filter { seen.insert($0).inserted }
  }

  /// True when the run cannot confirm its outcome from the journal alone.
  public var journalUnresolved: Bool {
    if journalError != nil { return true }
    if hasTornTail || !outstandingIntents.isEmpty || !unknownOutcomes.isEmpty { return true }
    if finalized { return false }
    // A clean crash between one durable outcome and the next intent leaves
    // no dangling record — only a non-terminal state that never advances.
    guard let currentState else { return true }
    return !currentState.isTerminal
  }

  /// The run's journal reached a confirmed terminal but its authority
  /// record never closed: a crash in the window between the durable
  /// terminal and `closeUsage`. The honest terminal is derivable from the
  /// journal, so this is closable debt — invisible before this field.
  public var terminalWithOpenAuthority: Bool {
    guard !journalUnresolved else { return false }
    switch ledgerState {
    case .openStandingReservation, .openAgentReservation: return true
    case .closed, .missing, .none: return false
    }
  }

  /// The reservation this session's journal names, resolved or not — used
  /// to tell a ledger orphan from a reservation some session accounts for.
  public var linkedReservationID: String? {
    switch ledgerState {
    case .openStandingReservation(let id), .openAgentReservation(let id),
      .closed(let id), .missing(let id):
      return id
    case .none:
      return nil
    }
  }

  /// True while there is still something actionable: an unresolved run —
  /// or a resolved run whose authority never closed — that a live owner is
  /// not about to settle itself.
  public var requiresAttention: Bool {
    if isLive { return false }
    if terminalWithOpenAuthority { return true }
    guard journalUnresolved else { return false }
    if case .closed = ledgerState { return false }
    return true
  }
}

/// An open usage reservation with no session directory left to explain it:
/// the journal was GC'd, moved, or never survived the crash. Invisible to
/// the session scan by construction, yet on the campaign lane it still
/// blocks its target host-wide (one open reservation per target).
public struct RockchipFlashOrphanedReservation: Sendable, Equatable {
  public enum Lane: String, Sendable {
    case standingAuthorization
    case agentCampaign
  }

  public let lane: Lane
  public let reservationID: String
  public let jobID: String
  public let reservedAt: String
  /// Campaign identity from the reservation's own authority reference, so
  /// the operator can still be pointed at `flash continue`.
  public let campaignID: String?
}

public struct RockchipFlashOrphanClosure: Sendable, Equatable {
  public enum Disposition: Sendable, Equatable {
    /// Closed `outcomeUnknown` with an empty intent list: with no journal
    /// left there is no proof any mutation did or did not run. Fail closed.
    case closedStandingReservation(reservationID: String)
    case alreadyClosed(reservationID: String)
    /// Campaign-lane orphans are drained by `flash continue`, whose
    /// reconciliation closes the usage reservation since #982.
    case agentLaneDeferred(reservationID: String)
  }

  public let disposition: Disposition
}

public struct RockchipFlashSessionClosure: Sendable, Equatable {
  public enum Disposition: Sendable, Equatable {
    case closedStandingReservation(
      reservationID: String, status: AuthorizationUsageTerminalStatus)
    case alreadyClosed(reservationID: String)
    /// Campaign-lane sessions are reconciled by `flash continue`, never here.
    case agentLaneDeferred(reservationID: String)
    /// A live process owns this session; its own terminal is authoritative.
    case sessionLive
    case nothingToClose
  }

  public let sessionID: String
  public let disposition: Disposition
}

public enum RockchipFlashSessionReconcileError: Error, Equatable, Sendable {
  case sessionNotFound(String)
  case sessionsRootUnavailable(String)
}

public struct RockchipFlashSessionReconciler {
  public let sessionsRoot: URL
  private let standingLedger: AuthorizationUsageLedger
  private let agentLedger: AgentAuthorityUsageLedger
  private let now: @Sendable () -> Date

  public init(
    sessionsRoot: URL,
    standingLedger: AuthorizationUsageLedger,
    agentLedger: AgentAuthorityUsageLedger,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessionsRoot = sessionsRoot.standardizedFileURL
    self.standingLedger = standingLedger
    self.agentLedger = agentLedger
    self.now = now
  }

  /// Production composition: the same sessions root the flash host writes
  /// and the same owner-only `AuthorizationUsage` directory its admission
  /// services reserve in.
  public static func production() throws -> RockchipFlashSessionReconciler {
    let sessionsRoot = try SessionSettingsStore().load().sessionsRoot
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let usageRoot =
      applicationSupport
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
      .appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    return RockchipFlashSessionReconciler(
      sessionsRoot: sessionsRoot,
      standingLedger: try AuthorizationUsageLedger(root: usageRoot),
      agentLedger: try AgentAuthorityUsageLedger(root: usageRoot))
  }

  /// Every session whose outcome is unresolved and whose authority record
  /// is still open. Read-only; zero device dispatch.
  public func scan() throws -> [RockchipFlashSessionFinding] {
    try allSessionFindings().filter(\.requiresAttention)
  }

  /// Open reservations no session directory accounts for — the session
  /// journal was GC'd, moved, or never survived. The session scan cannot
  /// see them; without this sweep they are permanent invisible debt (and,
  /// on the campaign lane, a permanent target block). Read-only.
  public func orphanedReservations() throws -> [RockchipFlashOrphanedReservation] {
    let linked = Set(try allSessionFindings().compactMap(\.linkedReservationID))
    var orphans: [RockchipFlashOrphanedReservation] = []
    for reservation in try standingLedger.load().reservations
    where reservation.terminal == nil && !linked.contains(reservation.reservationID) {
      orphans.append(
        RockchipFlashOrphanedReservation(
          lane: .standingAuthorization,
          reservationID: reservation.reservationID,
          jobID: reservation.jobID,
          reservedAt: reservation.reservedAt,
          campaignID: nil))
    }
    for reservation in try agentLedger.load().reservations
    where reservation.terminal == nil && !linked.contains(reservation.reservationID) {
      orphans.append(
        RockchipFlashOrphanedReservation(
          lane: .agentCampaign,
          reservationID: reservation.reservationID,
          jobID: reservation.jobID,
          reservedAt: reservation.reservedAt,
          campaignID: Self.campaignID(of: reservation.authorizationRef)))
    }
    return orphans.sorted { $0.reservationID < $1.reservationID }
  }

  /// Close a sessionless standing orphan. With no journal left there is no
  /// proof of what ran: `outcomeUnknown` with an empty intent list is the
  /// only honest terminal, and the ordinal stays consumed. Campaign-lane
  /// orphans are deferred to `flash continue`'s reconciliation.
  public func closeOrphan(
    _ orphan: RockchipFlashOrphanedReservation
  ) throws -> RockchipFlashOrphanClosure {
    guard orphan.lane == .standingAuthorization else {
      return RockchipFlashOrphanClosure(
        disposition: .agentLaneDeferred(reservationID: orphan.reservationID))
    }
    do {
      let closed = try standingLedger.close(
        reservationID: orphan.reservationID,
        terminal: AuthorizationUsageTerminal(
          status: .outcomeUnknown,
          closedAt: ISO8601DateFormatter().string(from: now()),
          destructiveIntentEventIDs: []))
      return RockchipFlashOrphanClosure(
        disposition: .closedStandingReservation(reservationID: closed.reservationID))
    } catch AuthorizationUsageLedgerError.reservationConflict {
      let reservation = try standingLedger.load().reservations.first {
        $0.reservationID == orphan.reservationID
      }
      guard reservation?.terminal != nil else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "terminal race on \(orphan.reservationID) left no terminal")
      }
      return RockchipFlashOrphanClosure(
        disposition: .alreadyClosed(reservationID: orphan.reservationID))
    }
  }

  private func allSessionFindings() throws -> [RockchipFlashSessionFinding] {
    let manager = FileManager.default
    var isDirectory = ObjCBool(false)
    guard manager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [] }
    let entries = try manager.contentsOfDirectory(
      at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    var findings: [RockchipFlashSessionFinding] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        continue
      }
      guard let finding = try finding(sessionRoot: entry) else { continue }
      findings.append(finding)
    }
    return findings
  }

  private static func campaignID(of reference: AgentExecutionAuthorityReference) -> String? {
    guard
      case .evolutionCampaignConfirmation(let campaignDigestSHA256, _, _, _, _, _, _, _, _, _) =
        reference
    else { return nil }
    return "ECAMP-" + campaignDigestSHA256.prefix(24).uppercased()
  }

  /// Inspect one session by ID, resolved or not (forensic view).
  public func inspect(sessionID: String) throws -> RockchipFlashSessionFinding {
    let root = sessionsRoot.appending(path: sessionID, directoryHint: .isDirectory)
    guard let finding = try finding(sessionRoot: root) else {
      throw RockchipFlashSessionReconcileError.sessionNotFound(sessionID)
    }
    return finding
  }

  /// Honestly close the standing-authorization reservation of an
  /// unresolved — or terminal-but-never-closed — session. Live sessions
  /// are refused: their owner's terminal is the only honest one. Retries
  /// and races settle gracefully: if a conflicting close reveals that a
  /// terminal now exists, whoever wrote it won. Campaign-lane reservations
  /// are reconciled by `flash continue`, which owns both the campaign
  /// tombstone and, since the same review, the usage-ledger closure.
  public func close(_ finding: RockchipFlashSessionFinding) throws -> RockchipFlashSessionClosure {
    guard !finding.isLive else {
      return RockchipFlashSessionClosure(
        sessionID: finding.sessionID, disposition: .sessionLive)
    }
    switch finding.ledgerState {
    case .openAgentReservation(let reservationID):
      return RockchipFlashSessionClosure(
        sessionID: finding.sessionID,
        disposition: .agentLaneDeferred(reservationID: reservationID))
    case .closed(let reservationID):
      return RockchipFlashSessionClosure(
        sessionID: finding.sessionID,
        disposition: .alreadyClosed(reservationID: reservationID))
    case .missing, .none:
      return RockchipFlashSessionClosure(
        sessionID: finding.sessionID, disposition: .nothingToClose)
    case .openStandingReservation(let reservationID):
      let status: AuthorizationUsageTerminalStatus
      let intentIDs: [String]
      if finding.terminalWithOpenAuthority, finding.currentState == .succeeded,
        finding.finalized
      {
        // The journal proved the run finished: complete the dead process's
        // own pending write instead of inventing doubt about a confirmed
        // success. The intent list is what its closeUsage would have sent —
        // every mutating intent of the run, all with confirmed outcomes.
        status = .succeeded
        intentIDs = finding.confirmedMutationIntentEventIDs
      } else if finding.terminalWithOpenAuthority {
        // Terminal shapes the executor does not write today; fail closed.
        status = .outcomeUnknown
        intentIDs = finding.confirmedMutationIntentEventIDs
      } else {
        let unresolved = finding.unresolvedMutationIntentEventIDs
        // A dangling or unknown mutation — or a journal we cannot read
        // past — is `outcomeUnknown`; a run that provably never issued a
        // mutating intent was merely `interrupted`. Both consume the
        // ordinal.
        status =
          unresolved.isEmpty && !finding.hasTornTail && finding.journalError == nil
          ? .interrupted : .outcomeUnknown
        intentIDs = unresolved
      }
      do {
        let closed = try standingLedger.close(
          reservationID: reservationID,
          terminal: AuthorizationUsageTerminal(
            status: status,
            closedAt: ISO8601DateFormatter().string(from: now()),
            destructiveIntentEventIDs: intentIDs))
        return RockchipFlashSessionClosure(
          sessionID: finding.sessionID,
          disposition: .closedStandingReservation(
            reservationID: closed.reservationID, status: status))
      } catch AuthorizationUsageLedgerError.reservationConflict {
        // Raced another closer (a concurrent reconcile, or the session's
        // own process finishing between scan and close). If a terminal now
        // exists, that writer's truth stands.
        let reservation = try standingLedger.load().reservations.first {
          $0.reservationID == reservationID
        }
        guard reservation?.terminal != nil else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "terminal race on \(reservationID) left no terminal")
        }
        return RockchipFlashSessionClosure(
          sessionID: finding.sessionID,
          disposition: .alreadyClosed(reservationID: reservationID))
      }
    }
  }

  // MARK: - Internals

  private func finding(sessionRoot: URL) throws -> RockchipFlashSessionFinding? {
    let journalURL = sessionRoot.appending(path: "journal.jsonl")
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
    let sessionID = sessionRoot.lastPathComponent
    let isLive = RockchipFlashSessionRunLock.isHeld(sessionRoot: sessionRoot)
    do {
      let replay = try DurableJournalRecovery.inspect(url: journalURL)
      return RockchipFlashSessionFinding(
        sessionID: sessionID,
        jobID: replay.events.first?.jobID,
        sessionRootPath: sessionRoot.path,
        schemaVersion: replay.schemaVersion,
        currentState: replay.currentState,
        finalized: replay.finalized,
        hasTornTail: replay.hasTornTail,
        isLive: isLive,
        journalError: nil,
        outstandingIntents: replay.outstandingIntents,
        unknownOutcomes: replay.unknownOutcomes,
        lastConfirmedStepID: replay.lastConfirmedStepID,
        lane: lane(of: replay),
        campaignID: campaignID(of: replay),
        ledgerState: try ledgerState(of: replay),
        confirmedMutationIntentEventIDs: Self.confirmedMutationIntents(of: replay))
    } catch {
      // Fail closed: an unreadable journal is an unresolved run whose
      // ledger linkage is unknown — surface it rather than skipping it.
      return RockchipFlashSessionFinding(
        sessionID: sessionID,
        jobID: nil,
        sessionRootPath: sessionRoot.path,
        schemaVersion: nil,
        currentState: nil,
        finalized: false,
        hasTornTail: false,
        isLive: isLive,
        journalError: String(describing: error),
        outstandingIntents: [],
        unknownOutcomes: [],
        lastConfirmedStepID: nil,
        lane: .none,
        campaignID: nil,
        ledgerState: .none,
        confirmedMutationIntentEventIDs: [])
    }
  }

  /// Mutating intents whose outcomes the journal confirmed: all mutation
  /// intents minus the dangling and unknown ones.
  private static func confirmedMutationIntents(of replay: JournalReplay) -> [String] {
    let outstanding = Set(replay.outstandingIntents.map(\.eventID))
    let unknown = Set(replay.unknownOutcomes.map(\.correlatedIntentEventID))
    var identifiers: [String] = []
    for event in replay.events where event.kind == .stepIntent {
      guard let step = event.workflowStep, step.effect >= .deviceMutation,
        !outstanding.contains(event.eventID), !unknown.contains(event.eventID)
      else { continue }
      identifiers.append(event.eventID)
    }
    return identifiers
  }

  private func campaignID(of replay: JournalReplay) -> String? {
    replay.agentExecutionAuthorityReference.flatMap(Self.campaignID(of:))
  }

  private func lane(of replay: JournalReplay) -> RockchipFlashSessionFinding.AuthorityLane {
    if replay.agentExecutionAuthorityReference != nil { return .agentCampaign }
    if replay.authorizationReference != nil { return .standingAuthorization }
    return .none
  }

  private func ledgerState(of replay: JournalReplay) throws
    -> RockchipFlashSessionFinding.LedgerState
  {
    guard let reservationID = replay.usageReservationID else { return .none }
    if replay.agentExecutionAuthorityReference != nil {
      guard
        let reservation = try agentLedger.load().reservations.first(where: {
          $0.reservationID == reservationID
        })
      else { return .missing(reservationID: reservationID) }
      return reservation.terminal == nil
        ? .openAgentReservation(reservationID: reservationID)
        : .closed(reservationID: reservationID)
    }
    guard
      let reservation = try standingLedger.load().reservations.first(where: {
        $0.reservationID == reservationID
      })
    else { return .missing(reservationID: reservationID) }
    return reservation.terminal == nil
      ? .openStandingReservation(reservationID: reservationID)
      : .closed(reservationID: reservationID)
  }
}
