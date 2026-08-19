import ArkDeckCore
import ArkDeckStorage
import Foundation

// Host-side recovery inspection for Rockchip flash sessions.
//
// The flash execution host writes a durable session journal
// (`<sessionsRoot>/<sessionID>/journal.jsonl`) but, unlike the runtime
// engine's job store, nothing replayed those journals after a crash: a
// an interrupted retired flash host could leave a dangling destructive `stepIntent`
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
// Campaign-lane sessions are reported but never closed here. They are historical
// decode/export records; current recovery is owned by Runtime jobs.

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
      throw RockchipLegacyFlashJournalReconcileError.sessionsRootUnavailable(
        "cannot create run lock at \(path): errno \(errno)")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let heldErrno = errno
      Darwin.close(descriptor)
      throw RockchipLegacyFlashJournalReconcileError.sessionsRootUnavailable(
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

package struct RockchipFlashSessionFinding: Sendable, Equatable {
  package enum AuthorityLane: String, Sendable {
    case agentCampaign
    /// Historical decode only. The standing lane was retired with its ledger
    /// (T25/W3): a journal that names one is still reported, and can no
    /// longer be closed by this tool.
    case standingAuthorization
    case none
  }

  package enum LedgerState: Sendable, Equatable {
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
  package let sessionRootPath: String
  package let schemaVersion: String?
  package let currentState: JobState?
  package let finalized: Bool
  package let hasTornTail: Bool
  /// A live process holds this session's run lock right now. Live sessions
  /// are never attention and never closable: the owner will write its own
  /// terminal, and closing under it would falsify a write-once record.
  package let isLive: Bool
  /// Journal could not be replayed at all (corrupt beyond the torn-tail
  /// repair the durable format tolerates). Fail closed: treated as unknown.
  package let journalError: String?
  package let outstandingIntents: [OutstandingJournalIntent]
  package let unknownOutcomes: [UnknownJournalOutcome]
  package let lastConfirmedStepID: String?
  public let lane: AuthorityLane
  /// Campaign identity derived from the journal's confirmation reference,
  /// so an operator can be pointed at `flash continue --campaign-id …`.
  package let campaignID: String?
  package let ledgerState: LedgerState

  /// Every mutating intent whose outcome the journal confirmed — what the
  /// dead process's own successful closeUsage would have carried.
  package let confirmedMutationIntentEventIDs: [String]

  /// Destructive/mutating intents with no confirmed outcome — the exact
  /// event IDs an honest ledger terminal must carry.
  package var unresolvedMutationIntentEventIDs: [String] {
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
  package var journalUnresolved: Bool {
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
  package var terminalWithOpenAuthority: Bool {
    guard !journalUnresolved else { return false }
    switch ledgerState {
    case .openAgentReservation: return true
    case .closed, .missing, .none: return false
    }
  }

  /// The reservation this session's journal names, resolved or not — used
  /// to tell a ledger orphan from a reservation some session accounts for.
  package var linkedReservationID: String? {
    switch ledgerState {
    case .openAgentReservation(let id), .closed(let id), .missing(let id):
      return id
    case .none:
      return nil
    }
  }

  /// True while there is still something actionable: an unresolved run —
  /// or a resolved run whose authority never closed — that a live owner is
  /// not about to settle itself.
  package var requiresAttention: Bool {
    if isLive { return false }
    if terminalWithOpenAuthority { return true }
    guard journalUnresolved else { return false }
    if case .closed = ledgerState { return false }
    return true
  }
}

/// An open usage reservation with no session directory left to explain it:
/// the journal was GC'd, moved, or never survived the crash. Invisible to
/// the session scan by construction. This is historical debt only; it has no
/// current admission effect.
package struct RockchipFlashOrphanedReservation: Sendable, Equatable {
  package let reservationID: String
  public let jobID: String
  package let reservedAt: String
  /// Campaign identity from the reservation's own authority reference, so
  /// the operator can inspect its historical status.
  package let campaignID: String?
}



public enum RockchipLegacyFlashJournalReconcileError: Error, Equatable, Sendable {
  case sessionNotFound(String)
  case sessionsRootUnavailable(String)
}

package struct RockchipLegacyFlashJournalReconciler {
  package let sessionsRoot: URL
  private let agentLedger: AgentAuthorityUsageLedger
  private let now: @Sendable () -> Date

  public init(
    sessionsRoot: URL,
    agentLedger: AgentAuthorityUsageLedger,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessionsRoot = sessionsRoot.standardizedFileURL
    self.agentLedger = agentLedger
    self.now = now
  }

  /// Production composition over the retired host's historical session and
  /// owner-only AuthorizationUsage locations.
  public static func production() throws -> RockchipLegacyFlashJournalReconciler {
    let sessionsRoot = try SessionSettingsStore().load().sessionsRoot
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let usageRoot =
      applicationSupport
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
      .appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    return RockchipLegacyFlashJournalReconciler(
      sessionsRoot: sessionsRoot,
      agentLedger: try AgentAuthorityUsageLedger(root: usageRoot))
  }

  /// Every session whose outcome is unresolved and whose authority record
  /// is still open. Read-only; zero device dispatch.
  package func scan() throws -> [RockchipFlashSessionFinding] {
    try allSessionFindings().filter(\.requiresAttention)
  }

  /// Open reservations no session directory accounts for — the session
  /// journal was GC'd, moved, or never survived. The session scan cannot
  /// see them; without this sweep they remain invisible historical debt.
  /// Read-only.
  package func orphanedReservations() throws -> [RockchipFlashOrphanedReservation] {
    let linked = Set(try allSessionFindings().compactMap(\.linkedReservationID))
    var orphans: [RockchipFlashOrphanedReservation] = []
    for reservation in try agentLedger.load().reservations
    where reservation.terminal == nil && !linked.contains(reservation.reservationID) {
      orphans.append(
        RockchipFlashOrphanedReservation(
          reservationID: reservation.reservationID,
          jobID: reservation.jobID,
          reservedAt: reservation.reservedAt,
          campaignID: Self.campaignID(of: reservation.authorizationRef)))
    }
    return orphans.sorted { $0.reservationID < $1.reservationID }
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
      throw RockchipLegacyFlashJournalReconcileError.sessionNotFound(sessionID)
    }
    return finding
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
    // A standing-lane journal. Its ledger was retired with the lane, so the
    // reservation it names is, by construction, no longer resolvable — which
    // is exactly what `missing` states. The session stays visible in the
    // report; nothing here can write it a terminal.
    return .missing(reservationID: reservationID)
  }
}
