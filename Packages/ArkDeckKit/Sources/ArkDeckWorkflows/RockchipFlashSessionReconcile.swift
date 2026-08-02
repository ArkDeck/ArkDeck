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

  /// True while there is still something actionable: an unresolved run
  /// whose authority record has not been honestly closed.
  public var requiresAttention: Bool {
    guard journalUnresolved else { return false }
    if case .closed = ledgerState { return false }
    return true
  }
}

public struct RockchipFlashSessionClosure: Sendable, Equatable {
  public enum Disposition: Sendable, Equatable {
    case closedStandingReservation(
      reservationID: String, status: AuthorizationUsageTerminalStatus)
    case alreadyClosed(reservationID: String)
    /// Campaign-lane sessions are reconciled by `flash continue`, never here.
    case agentLaneDeferred(reservationID: String)
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
      if finding.requiresAttention { findings.append(finding) }
    }
    return findings
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
  /// unresolved session. Idempotent: the closure status is derived
  /// deterministically from the journal, so a retry writes byte-identical
  /// terminal state. Campaign-lane reservations are deferred to
  /// `flash continue`, which owns the campaign tombstone semantics.
  public func close(_ finding: RockchipFlashSessionFinding) throws -> RockchipFlashSessionClosure {
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
      let intentIDs = finding.unresolvedMutationIntentEventIDs
      // A dangling or unknown mutation — or a journal we cannot read past —
      // is `outcomeUnknown`; a run that provably never issued a mutating
      // intent was merely `interrupted`. Both consume the ordinal.
      let status: AuthorizationUsageTerminalStatus =
        intentIDs.isEmpty && !finding.hasTornTail && finding.journalError == nil
        ? .interrupted : .outcomeUnknown
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
    }
  }

  // MARK: - Internals

  private func finding(sessionRoot: URL) throws -> RockchipFlashSessionFinding? {
    let journalURL = sessionRoot.appending(path: "journal.jsonl")
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
    let sessionID = sessionRoot.lastPathComponent
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
        journalError: nil,
        outstandingIntents: replay.outstandingIntents,
        unknownOutcomes: replay.unknownOutcomes,
        lastConfirmedStepID: replay.lastConfirmedStepID,
        lane: lane(of: replay),
        campaignID: campaignID(of: replay),
        ledgerState: try ledgerState(of: replay))
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
        journalError: String(describing: error),
        outstandingIntents: [],
        unknownOutcomes: [],
        lastConfirmedStepID: nil,
        lane: .none,
        campaignID: nil,
        ledgerState: .none)
    }
  }

  private func campaignID(of replay: JournalReplay) -> String? {
    guard
      case .evolutionCampaignConfirmation(let campaignDigestSHA256, _, _, _, _, _, _, _, _, _) =
        replay.agentExecutionAuthorityReference
    else { return nil }
    return "ECAMP-" + campaignDigestSHA256.prefix(24).uppercased()
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
