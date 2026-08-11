// Append-only Evolution campaign ledger (CHG-2026-025 r8, TASK-AIN-019).

import ArkDeckCore
import ArkDeckStorage
import Darwin
import Foundation

package enum RockchipEvolutionAttemptDisposition: String, Codable, Sendable {
  case succeeded
  case safeToReflash
  case unsafePartial
  case outcomeUnknown
}

package enum RockchipEvolutionCampaignEventKind: String, Codable, Sendable {
  case candidatePrepared
  case attemptReserved
  case attemptTerminal
  case campaignStopped
}

package struct RockchipEvolutionCampaignEvent: Equatable, Codable, Sendable {
  public let sequence: Int
  public let kind: RockchipEvolutionCampaignEventKind
  public let at: String
  public let candidate: RockchipEvolutionCandidatePin?
  public let review: RockchipEvolutionReviewReceipt?
  package let ordinal: Int?
  package let reservationID: String?
  public let jobID: String?
  public let sessionID: String?
  public let disposition: RockchipEvolutionAttemptDisposition?
  package let destructiveIntentEventIDs: [String]
  package let reasonCode: String?
  /// The underlying error a stop was made of. `reasonCode` stays the closed,
  /// greppable classification; this is the one sentence that says which
  /// catch-all fired and why, so a stopped campaign no longer has to be
  /// reconstructed from macOS crash reports. Optional on purpose: campaign
  /// documents written before this field decode unchanged.
  public let detail: String?

  package static let maximumDetailBytes = 500

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case sequence
    case kind
    case at
    case candidate
    case review
    case ordinal
    case reservationID
    case jobID
    case sessionID
    case disposition
    case destructiveIntentEventIDs
    case reasonCode
    case detail
  }

  package init(
    sequence: Int,
    kind: RockchipEvolutionCampaignEventKind,
    at: String,
    candidate: RockchipEvolutionCandidatePin? = nil,
    ordinal: Int? = nil,
    reservationID: String? = nil,
    jobID: String? = nil,
    sessionID: String? = nil,
    disposition: RockchipEvolutionAttemptDisposition? = nil,
    destructiveIntentEventIDs: [String] = [],
    reasonCode: String? = nil,
    detail: String? = nil
  ) throws {
    try self.init(
      sequence: sequence, kind: kind, at: at, candidate: candidate, review: nil,
      ordinal: ordinal, reservationID: reservationID, jobID: jobID, sessionID: sessionID,
      disposition: disposition, destructiveIntentEventIDs: destructiveIntentEventIDs,
      reasonCode: reasonCode, detail: detail)
  }

  private init(
    sequence: Int,
    kind: RockchipEvolutionCampaignEventKind,
    at: String,
    candidate: RockchipEvolutionCandidatePin?,
    review: RockchipEvolutionReviewReceipt?,
    ordinal: Int?,
    reservationID: String?,
    jobID: String?,
    sessionID: String?,
    disposition: RockchipEvolutionAttemptDisposition?,
    destructiveIntentEventIDs: [String],
    reasonCode: String?,
    detail: String?
  ) throws {
    self.sequence = sequence
    self.kind = kind
    self.at = at
    self.candidate = candidate
    self.review = review
    self.ordinal = ordinal
    self.reservationID = reservationID
    self.jobID = jobID
    self.sessionID = sessionID
    self.disposition = disposition
    self.destructiveIntentEventIDs = Array(Set(destructiveIntentEventIDs)).sorted()
    self.reasonCode = reasonCode
    self.detail = detail
    try validate()
  }

  /// Turns arbitrary error text into something a durable append-only document
  /// may carry: single-line, control-free and bounded. Callers sanitize before
  /// constructing an event; `validate()` then refuses anything that did not.
  package static func sanitizedDetail(_ raw: String) -> String? {
    let collapsed = raw.unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
    }
    let squeezed = String(collapsed).split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    guard !squeezed.isEmpty else { return nil }
    var bounded = squeezed
    while bounded.utf8.count > maximumDetailBytes { bounded.removeLast() }
    return bounded.isEmpty ? nil : bounded
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let allowed = Set(CodingKeys.allCases.map(\.stringValue))
    guard Set(dynamic.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw RockchipEvolutionCampaignError.persistenceRejected("eventClosedShape")
    }
    try self.init(
      sequence: container.decode(Int.self, forKey: .sequence),
      kind: container.decode(RockchipEvolutionCampaignEventKind.self, forKey: .kind),
      at: container.decode(String.self, forKey: .at),
      candidate: container.decodeIfPresent(RockchipEvolutionCandidatePin.self, forKey: .candidate),
      review: container.decodeIfPresent(RockchipEvolutionReviewReceipt.self, forKey: .review),
      ordinal: container.decodeIfPresent(Int.self, forKey: .ordinal),
      reservationID: container.decodeIfPresent(String.self, forKey: .reservationID),
      jobID: container.decodeIfPresent(String.self, forKey: .jobID),
      sessionID: container.decodeIfPresent(String.self, forKey: .sessionID),
      disposition: container.decodeIfPresent(
        RockchipEvolutionAttemptDisposition.self, forKey: .disposition),
      destructiveIntentEventIDs: container.decode(
        [String].self, forKey: .destructiveIntentEventIDs),
      reasonCode: container.decodeIfPresent(String.self, forKey: .reasonCode),
      detail: container.decodeIfPresent(String.self, forKey: .detail))
  }

  private func validate() throws {
    guard sequence > 0, RockchipEvolutionCampaignConfirmationAssertion.date(at) != nil,
      destructiveIntentEventIDs.allSatisfy(Self.isIdentifier),
      detail.map(Self.isDetail) != false
    else { throw RockchipEvolutionCampaignError.persistenceRejected("eventIdentity") }
    switch kind {
    case .candidatePrepared:
      guard let candidate, ordinal == nil, reservationID == nil,
        jobID == nil, sessionID == nil, disposition == nil,
        destructiveIntentEventIDs.isEmpty, reasonCode == nil, detail == nil
      else { throw RockchipEvolutionCampaignError.persistenceRejected("candidatePreparedShape") }
      if let review { try review.validateHistorical(candidate: candidate) }
    case .attemptReserved:
      guard candidate == nil, review == nil, let ordinal, ordinal > 0,
        let reservationID, Self.isIdentifier(reservationID),
        let jobID, Self.isIdentifier(jobID), let sessionID, Self.isIdentifier(sessionID),
        disposition == nil, destructiveIntentEventIDs.isEmpty, reasonCode == nil,
        detail == nil
      else { throw RockchipEvolutionCampaignError.persistenceRejected("attemptReservedShape") }
    case .attemptTerminal:
      // `detail` carries the classification basis: which evidence reconciliation
      // read and which rule fired. A disposition on its own cannot be audited —
      // `outcomeUnknown` is written both by an engine that measured an unknown
      // outcome and by reconciliation that found no terminal at all, and those
      // are opposite facts (TASK-AIN-020). Optional: attempts closed before
      // r17 decode unchanged.
      guard candidate == nil, review == nil, let ordinal, ordinal > 0,
        reservationID == nil, let jobID, Self.isIdentifier(jobID),
        let sessionID, Self.isIdentifier(sessionID), disposition != nil, reasonCode == nil
      else { throw RockchipEvolutionCampaignError.persistenceRejected("attemptTerminalShape") }
    case .campaignStopped:
      // `detail` is optional here and on `attemptTerminal`, and nowhere else: a
      // stop is the only other event whose cause lives outside the campaign's
      // own closed vocabulary.
      guard candidate == nil, review == nil, ordinal == nil, reservationID == nil,
        jobID == nil, sessionID == nil, disposition == nil,
        destructiveIntentEventIDs.isEmpty, let reasonCode, Self.isReason(reasonCode)
      else { throw RockchipEvolutionCampaignError.persistenceRejected("campaignStoppedShape") }
    }
  }

  private static func isDetail(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumDetailBytes
      && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isReason(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }
}

package struct RockchipEvolutionCampaignDocument: Equatable, Codable, Sendable {
  package static let documentType = "rockchip-evolution-campaign-ledger"
  package static let schemaVersion = "1.0.0"

  package let documentType: String
  package let schemaVersion: String
  package let campaignID: String
  public let assertion: RockchipEvolutionCampaignConfirmationAssertion
  public let events: [RockchipEvolutionCampaignEvent]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case campaignID
    case assertion
    case events
  }

  package init(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    events: [RockchipEvolutionCampaignEvent]
  ) throws {
    documentType = Self.documentType
    schemaVersion = Self.schemaVersion
    campaignID = assertion.campaignID
    self.assertion = assertion
    self.events = events
    try validate()
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: RockchipEvolutionDynamicCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(dynamic.allKeys.map(\.stringValue))
        == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw RockchipEvolutionCampaignError.persistenceRejected("documentClosedShape")
    }
    let assertion = try container.decode(
      RockchipEvolutionCampaignConfirmationAssertion.self, forKey: .assertion)
    let events = try container.decode([RockchipEvolutionCampaignEvent].self, forKey: .events)
    try self.init(assertion: assertion, events: events)
    guard documentType == (try container.decode(String.self, forKey: .documentType)),
      schemaVersion == (try container.decode(String.self, forKey: .schemaVersion)),
      campaignID == (try container.decode(String.self, forKey: .campaignID))
    else { throw RockchipEvolutionCampaignError.persistenceRejected("documentIdentity") }
  }

  public var isTerminal: Bool {
    if events.contains(where: { $0.kind == .campaignStopped }) { return true }
    return events.contains {
      $0.kind == .attemptTerminal && $0.disposition != .safeToReflash
    }
  }

  package var reservedAttemptCount: Int {
    events.filter { $0.kind == .attemptReserved }.count
  }

  package var activeReservation: RockchipEvolutionCampaignEvent? {
    guard let reserved = events.last(where: { $0.kind == .attemptReserved }),
      let ordinal = reserved.ordinal,
      !events.contains(where: { $0.kind == .attemptTerminal && $0.ordinal == ordinal })
    else { return nil }
    return reserved
  }

  package var latestCandidate: RockchipEvolutionCampaignEvent? {
    events.last(where: { $0.kind == .candidatePrepared })
  }

  private func validate() throws {
    guard campaignID == assertion.campaignID,
      events.enumerated().allSatisfy({ $0.element.sequence == $0.offset + 1 })
    else { throw RockchipEvolutionCampaignError.persistenceRejected("eventSequence") }
    var candidates: [String: RockchipEvolutionCampaignEvent] = [:]
    var reservations: [Int: RockchipEvolutionCampaignEvent] = [:]
    var terminals = Set<Int>()
    var stopped = false
    for event in events {
      guard !stopped else {
        throw RockchipEvolutionCampaignError.persistenceRejected("eventAfterStop")
      }
      switch event.kind {
      case .candidatePrepared:
        guard let candidate = event.candidate,
          candidate.baseCommitOID == assertion.baseCommitOID,
          candidate.toolchainDigestSHA256 == assertion.candidateToolchainDigestSHA256,
          event.review == nil || event.review?.planDigestSHA256 == assertion.planDigestSHA256
        else { throw RockchipEvolutionCampaignError.persistenceRejected("candidateDrift") }
        candidates[candidate.candidateID] = event
      case .attemptReserved:
        guard let ordinal = event.ordinal, ordinal == reservations.count + 1,
          ordinal <= assertion.maxAttempts,
          activeReservation(in: reservations, terminals: terminals) == nil,
          let latest = candidates.values.max(by: { $0.sequence < $1.sequence }),
          latest.sequence < event.sequence
        else { throw RockchipEvolutionCampaignError.persistenceRejected("reservationOrder") }
        if ordinal > 1 {
          guard
            let prior = events.last(where: {
              $0.kind == .attemptTerminal && $0.ordinal == ordinal - 1
            }), prior.disposition == .safeToReflash
          else { throw RockchipEvolutionCampaignError.persistenceRejected("unsafeContinuation") }
        }
        reservations[ordinal] = event
      case .attemptTerminal:
        guard let ordinal = event.ordinal, let reserved = reservations[ordinal],
          !terminals.contains(ordinal), reserved.jobID == event.jobID,
          reserved.sessionID == event.sessionID
        else { throw RockchipEvolutionCampaignError.persistenceRejected("terminalCorrelation") }
        terminals.insert(ordinal)
        if event.disposition != .safeToReflash { stopped = true }
      case .campaignStopped:
        stopped = true
      }
    }
  }

  private func activeReservation(
    in reservations: [Int: RockchipEvolutionCampaignEvent], terminals: Set<Int>
  ) -> RockchipEvolutionCampaignEvent? {
    reservations.first(where: { !terminals.contains($0.key) })?.value
  }
}

/// Host-wide, file-locked campaign ledger. Every public mutation can only
/// append an event to the validated prior history; no API can edit or remove
/// a candidate, reservation or terminal event. The single removal surface,
/// `collectExpiredZeroEventDrafts`, deletes whole documents that never
/// accrued any event once their confirmation window has expired — it can
/// never touch a document that holds attempt history.
package final class RockchipEvolutionCampaignLedger: @unchecked Sendable {
  package static let maximumBytes = 16 * 1_024 * 1_024

  public let root: URL

  public init(root: URL) throws {
    guard root.isFileURL, root.path.hasPrefix("/") else {
      throw RockchipEvolutionCampaignError.persistenceRejected("root")
    }
    self.root = root.standardizedFileURL
    var metadata = stat()
    if lstat(self.root.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFLNK {
      throw RockchipEvolutionCampaignError.persistenceRejected("rootSymlink")
    }
    try FileManager.default.createDirectory(
      at: self.root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(self.root.path, 0o700) == 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("rootPermissions")
    }
    var created = stat()
    guard lstat(self.root.path, &created) == 0,
      (created.st_mode & S_IFMT) == S_IFDIR, created.st_uid == geteuid(),
      created.st_mode & 0o077 == 0
    else { throw RockchipEvolutionCampaignError.persistenceRejected("rootOwnership") }
  }

  @discardableResult
  public func create(
    _ assertion: RockchipEvolutionCampaignConfirmationAssertion
  ) throws -> RockchipEvolutionCampaignDocument {
    try locked(assertion.campaignID) { rootDescriptor in
      if let existing = try loadLocked(assertion.campaignID, rootDescriptor: rootDescriptor) {
        guard existing.assertion == assertion else {
          throw RockchipEvolutionCampaignError.campaignConflict
        }
        return existing
      }
      let document = try RockchipEvolutionCampaignDocument(assertion: assertion, events: [])
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return document
    }
  }

  /// Deletes campaign documents that hold zero events and whose confirmation
  /// assertion expired strictly before `timestamp`. A zero-event document is a
  /// preview draft: nothing was ever prepared, reserved or dispatched under
  /// it, and once expired it can never be admitted again, so removing the
  /// whole document erases no attempt history. Documents with any event are
  /// never candidates, regardless of age.
  ///
  /// Each candidate is re-validated and unlinked inside the same per-campaign
  /// critical section every writer uses. Entries that fail to load are left
  /// in place for inspection rather than deleted, and per-campaign lock files
  /// always survive: unlinking a lock inode a concurrent process already
  /// opened would let two writers hold the same campaign critical section.
  /// Sweeps are opportunistic hygiene — callers may treat failures as
  /// non-fatal because the subsequent create/load surfaces any real fault.
  @discardableResult
  package func collectExpiredZeroEventDrafts(at timestamp: String) throws -> [String] {
    guard RockchipEvolutionCampaignConfirmationAssertion.date(timestamp) != nil else {
      throw RockchipEvolutionCampaignError.persistenceRejected("collectTimestamp")
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    var collected: [String] = []
    for name in names.sorted() {
      guard name.hasSuffix(".json") else { continue }
      let campaignID = String(name.dropLast(".json".count))
      guard
        campaignID.range(of: #"^ECAMP-[A-F0-9]{24}$"#, options: .regularExpression)
          == campaignID.startIndex..<campaignID.endIndex
      else { continue }
      let didCollect = (try? locked(campaignID) { rootDescriptor -> Bool in
        guard let document = try loadLocked(campaignID, rootDescriptor: rootDescriptor),
          document.events.isEmpty,
          Self.isExpired(document.assertion, at: timestamp)
        else { return false }
        guard Darwin.unlinkat(rootDescriptor, name, 0) == 0,
          Darwin.fsync(rootDescriptor) == 0
        else { throw RockchipEvolutionCampaignError.persistenceRejected("collectDraft") }
        return true
      }) ?? false
      if didCollect { collected.append(campaignID) }
    }
    return collected
  }

  private static func isExpired(
    _ assertion: RockchipEvolutionCampaignConfirmationAssertion, at timestamp: String
  ) -> Bool {
    // Only a validity window that has strictly closed is permanent death;
    // unparseable input keeps the document (never delete when unsure).
    guard let now = RockchipEvolutionCampaignConfirmationAssertion.date(timestamp),
      let expiry = RockchipEvolutionCampaignConfirmationAssertion.date(assertion.validUntil)
    else { return false }
    return expiry < now
  }

  public func load(_ campaignID: String) throws -> RockchipEvolutionCampaignDocument {
    try locked(campaignID) { rootDescriptor in
      guard let document = try loadLocked(campaignID, rootDescriptor: rootDescriptor) else {
        throw RockchipEvolutionCampaignError.campaignNotFound(campaignID)
      }
      return document
    }
  }

  @discardableResult
  package func appendCandidate(
    campaignID: String,
    candidate: RockchipEvolutionCandidatePin,
    at: String
  ) throws -> RockchipEvolutionCampaignDocument {
    return try mutate(campaignID) { document in
      try requireActive(document, at: at)
      guard document.activeReservation == nil else {
        throw RockchipEvolutionCampaignError.campaignStopped("activeAttempt")
      }
      let permit = try RockchipEvolutionCampaignAttemptPermit(
        assertion: document.assertion, candidate: candidate)
      _ = permit
      let event = try RockchipEvolutionCampaignEvent(
        sequence: document.events.count + 1, kind: .candidatePrepared, at: at,
        candidate: candidate)
      return try RockchipEvolutionCampaignDocument(
        assertion: document.assertion, events: document.events + [event])
    }
  }

  @discardableResult
  package func reserveAttempt(
    campaignID: String,
    candidateID: String,
    ordinal: Int,
    reservationID: String,
    jobID: String,
    sessionID: String,
    at: String
  ) throws -> RockchipEvolutionCampaignDocument {
    return try mutate(campaignID) { document in
      try requireActive(document, at: at)
      guard document.activeReservation == nil,
        ordinal == document.reservedAttemptCount + 1,
        ordinal <= document.assertion.maxAttempts,
        let prepared = document.latestCandidate,
        prepared.candidate?.candidateID == candidateID
      else { throw RockchipEvolutionCampaignError.campaignConflict }
      let event = try RockchipEvolutionCampaignEvent(
        sequence: document.events.count + 1, kind: .attemptReserved, at: at,
        ordinal: ordinal, reservationID: reservationID, jobID: jobID, sessionID: sessionID)
      return try RockchipEvolutionCampaignDocument(
        assertion: document.assertion, events: document.events + [event])
    }
  }

  @discardableResult
  package func closeAttempt(
    campaignID: String,
    ordinal: Int,
    jobID: String,
    sessionID: String,
    disposition: RockchipEvolutionAttemptDisposition,
    destructiveIntentEventIDs: [String],
    basis: String? = nil,
    at: String
  ) throws -> RockchipEvolutionCampaignDocument {
    try mutate(campaignID) { document in
      guard let active = document.activeReservation, active.ordinal == ordinal,
        active.jobID == jobID, active.sessionID == sessionID
      else { throw RockchipEvolutionCampaignError.campaignConflict }
      let event = try RockchipEvolutionCampaignEvent(
        sequence: document.events.count + 1, kind: .attemptTerminal, at: at,
        ordinal: ordinal, jobID: jobID, sessionID: sessionID,
        disposition: disposition, destructiveIntentEventIDs: destructiveIntentEventIDs,
        detail: basis.flatMap(RockchipEvolutionCampaignEvent.sanitizedDetail))
      return try RockchipEvolutionCampaignDocument(
        assertion: document.assertion, events: document.events + [event])
    }
  }

  @discardableResult
  public func stop(
    campaignID: String, reasonCode: String, detail: String? = nil, at: String
  ) throws -> RockchipEvolutionCampaignDocument {
    try mutate(campaignID) { document in
      if document.isTerminal { return document }
      let event = try RockchipEvolutionCampaignEvent(
        sequence: document.events.count + 1, kind: .campaignStopped, at: at,
        reasonCode: reasonCode,
        detail: detail.flatMap(RockchipEvolutionCampaignEvent.sanitizedDetail))
      return try RockchipEvolutionCampaignDocument(
        assertion: document.assertion, events: document.events + [event])
    }
  }

  private func mutate(
    _ campaignID: String,
    body: (RockchipEvolutionCampaignDocument) throws -> RockchipEvolutionCampaignDocument
  ) throws -> RockchipEvolutionCampaignDocument {
    try locked(campaignID) { rootDescriptor in
      guard let current = try loadLocked(campaignID, rootDescriptor: rootDescriptor) else {
        throw RockchipEvolutionCampaignError.campaignNotFound(campaignID)
      }
      let updated = try body(current)
      if updated != current { try persistLocked(updated, rootDescriptor: rootDescriptor) }
      return updated
    }
  }

  private func requireActive(
    _ document: RockchipEvolutionCampaignDocument, at: String
  ) throws {
    guard !document.isTerminal else {
      throw RockchipEvolutionCampaignError.campaignStopped("terminal")
    }
    guard document.assertion.isValid(at: at) else {
      throw RockchipEvolutionCampaignError.expired
    }
    if document.reservedAttemptCount > 0 {
      guard let terminal = document.events.last(where: { $0.kind == .attemptTerminal }),
        terminal.ordinal == document.reservedAttemptCount,
        terminal.disposition == .safeToReflash
      else { throw RockchipEvolutionCampaignError.campaignStopped("previousAttemptUnresolved") }
    }
  }

  private func locked<T>(_ campaignID: String, body: (Int32) throws -> T) throws -> T {
    guard
      campaignID.range(of: #"^ECAMP-[A-F0-9]{24}$"#, options: .regularExpression)
        == campaignID.startIndex..<campaignID.endIndex
    else { throw RockchipEvolutionCampaignError.campaignNotFound(campaignID) }
    let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("openRoot")
    }
    defer { Darwin.close(rootDescriptor) }
    var rootMetadata = stat()
    guard fstat(rootDescriptor, &rootMetadata) == 0,
      (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
      rootMetadata.st_uid == geteuid(), rootMetadata.st_mode & 0o077 == 0
    else { throw RockchipEvolutionCampaignError.persistenceRejected("rootBinding") }
    let lockName = ".\(campaignID).lock"
    let lockDescriptor = Darwin.openat(
      rootDescriptor, lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("openLock")
    }
    defer { Darwin.close(lockDescriptor) }
    var lockMetadata = stat()
    guard fstat(lockDescriptor, &lockMetadata) == 0,
      (lockMetadata.st_mode & S_IFMT) == S_IFREG,
      lockMetadata.st_uid == geteuid(), lockMetadata.st_nlink == 1,
      lockMetadata.st_mode & 0o077 == 0
    else { throw RockchipEvolutionCampaignError.persistenceRejected("lockOwnership") }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RockchipEvolutionCampaignError.persistenceRejected("lock")
    }
    defer { flock(lockDescriptor, LOCK_UN) }
    return try body(rootDescriptor)
  }

  private func loadLocked(
    _ campaignID: String, rootDescriptor: Int32
  ) throws -> RockchipEvolutionCampaignDocument? {
    let name = "\(campaignID).json"
    let descriptor = Darwin.openat(
      rootDescriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw RockchipEvolutionCampaignError.persistenceRejected("openLedger")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0, metadata.st_size <= Self.maximumBytes
    else { throw RockchipEvolutionCampaignError.persistenceRejected("ledgerMetadata") }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RockchipEvolutionCampaignError.persistenceRejected("readLedger")
      }
      offset += count
    }
    do {
      return try JSONDecoder().decode(RockchipEvolutionCampaignDocument.self, from: data)
    } catch let error as RockchipEvolutionCampaignError { throw error } catch {
      throw RockchipEvolutionCampaignError.persistenceRejected("decodeLedger")
    }
  }

  private func persistLocked(
    _ document: RockchipEvolutionCampaignDocument, rootDescriptor: Int32
  ) throws {
    let encoder = CanonicalJSONEncoders.canonical()
    let data = try encoder.encode(document)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw RockchipEvolutionCampaignError.persistenceRejected("ledgerSize")
    }
    let finalName = "\(document.campaignID).json"
    let temporaryName = ".\(document.campaignID).\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("createTemporary")
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen { _ = Darwin.close(descriptor) }
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
    }
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw RockchipEvolutionCampaignError.persistenceRejected("writeTemporary")
        }
        offset += count
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("commitLedger")
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptorIsOpen = false
      throw RockchipEvolutionCampaignError.persistenceRejected("commitLedger")
    }
    descriptorIsOpen = false
    guard Darwin.renameat(rootDescriptor, temporaryName, rootDescriptor, finalName) == 0,
      Darwin.fsync(rootDescriptor) == 0
    else { throw RockchipEvolutionCampaignError.persistenceRejected("commitLedger") }
  }
}
