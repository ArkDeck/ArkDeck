import ArkDeckCore
import ArkDeckStorage
import Foundation

package struct HDCControlImpactReading: Sendable {
  package let impact: HDCControlImpact
  package let observationRelations: [JSONValue]
  package let blockerReasonCode: String?
}

/// Runtime-only observation port. It accepts no caller facts, argv, tool path
/// or authority. The product preview remains distinct from Supervisor leases.
package protocol HDCControlImpactObserving: Sendable {
  var endpointReference: String { get }
  func readImpact() async throws -> HDCControlImpactReading
}

/// Durable control-action owner. Preview/discovery/reconcile never invoke a
/// lifecycle executor. Confirmation and dispatch must join this same owner,
/// not manufacture a Job or treat a preview digest as authorization.
public actor RuntimeHDCControlActionCoordinator {
  private let store: RuntimeHDCControlActionStore
  private let pages: RuntimeSnapshotPager
  private let source: any HDCControlImpactObserving
  private let lifecycleDriver: (any HDCControlLifecycleDriving)?
  private let epoch: String
  private let catalogDigest: String
  private let now: @Sendable () -> Date
  private var inFlight: [String: (id: UUID, task: Task<HDCControlActionRecord, Error>)] = [:]

  package init(directory: URL, source: any HDCControlImpactObserving,
    lifecycleDriver: (any HDCControlLifecycleDriving)? = nil, catalogDigest: String,
    epoch: String = UUID().uuidString.lowercased(), now: @escaping @Sendable () -> Date = { Date() }) throws {
    store = try RuntimeHDCControlActionStore(directory: directory.appending(path: "records"))
    pages = try RuntimeSnapshotPager(directory: directory.appending(path: "snapshots"))
    self.source = source; self.lifecycleDriver = lifecycleDriver
    self.epoch = epoch; self.catalogDigest = catalogDigest; self.now = now
  }

  package func preview(_ fields: [String: JSONValue]) async throws -> JSONValue {
    let intent = try HDCControlActionIntent(fields)
    // Existing request identity wins over current endpoint configuration, so
    // a lost receipt still resolves after a configuration or daemon change.
    if let existing = try store.load(requestID: intent.actionRequestID) {
      guard existing.intent == intent else { throw HDCControlValue.failure("idempotencyConflict", "the request identity belongs to a different lifecycle intent") }
      let record = try refreshAge(existing)
      if record.state == "observing" { return try await finishObservation(record).projection }
      return record.projection
    }
    guard intent.endpointReference == source.endpointReference else {
      throw HDCControlValue.failure("resourceNotFound", "the exact HDC endpoint reference is not configured")
    }
    let record = try store.begin(intent: intent, catalogDigest: catalogDigest, runtimeEpoch: epoch, now: clock())
    return try await finishObservation(record).projection
  }

  package func show(_ actionID: String) throws -> JSONValue { try refreshAge(required(actionID)).projection }

  package func listRecords() throws -> [HDCControlActionRecord] {
    try store.list().map(refreshAge)
  }

  package func list(filters: [String: JSONValue], pageSize: Int, cursor: String?) throws -> JSONValue {
    guard Set(filters.keys).isSubset(of: ["kind", "state"]),
      filters["kind"] == nil || filters["kind"] == .string("hdcLifecycle"),
      filters["state"] == nil || HDCControlValue.oneOf(filters["state"], ["observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown", "blocked", "expired", "previewDrifted"])
    else { throw HDCControlValue.failure("invalidInput", "unsupported control-action discovery filter") }
    return try pages.page(method: "control-action.list", filters: filters, order: "createdAtThenControlActionId",
      pageSize: pageSize, cursor: cursor) {
        try store.list().map(refreshAge).filter { row in filters["state"] == nil || filters["state"] == .string(row.state) }.map(\.projection)
      }
  }

  package func reconcile(_ actionID: String) async throws -> JSONValue {
    let record = try refreshAge(required(actionID))
    if record.state == "observing" { return try await finishObservation(record).projection }
    guard ["previewReady", "awaitingImpactApproval", "blocked"].contains(record.state), let preview = record.preview else { return record.projection }
    let reading: HDCControlImpactReading
    do { reading = try await source.readImpact() }
    catch { return try invalidateLatest(record, reason: "hdc.impactObservationUnavailable").projection }
    let latest = try refreshAge(required(actionID))
    guard latest.generation == record.generation else { return latest.projection }
    guard preview.impact == reading.impact,
      record.value["observationRelations"] == .array(reading.observationRelations),
      record.value["blockerReasonCode"] == (blocker(for: reading, intent: record.intent).map(JSONValue.string) ?? .null)
    else { return try invalidateLatest(record, reason: "hdc.previewDrifted").projection }
    return latest.projection
  }

  /// The exact restart request creates the owner-bound approval resource. It
  /// never confirms or dispatches. A lost response returns the same HAR and
  /// skips re-observation; a different tuple cannot reuse that receipt.
  package func requestRestart(
    actionID: String, previewID: String, previewDigest: String
  ) async throws -> JSONValue {
    let record = try refreshAge(required(actionID))
    guard let preview = record.preview,
      preview.value["previewId"] == .string(previewID),
      preview.value["previewDigest"] == .string(previewDigest)
    else { throw HDCControlValue.failure("reviewedPlanMismatch", "restart does not name the exact immutable preview") }
    if record.state == "awaitingImpactApproval" { return record.projection }
    guard record.state == "previewReady" else {
      throw HDCControlValue.failure("admissionDenied", "the control action is not eligible for impact approval")
    }
    let reading: HDCControlImpactReading
    do { reading = try await source.readImpact() }
    catch {
      let invalid = try invalidateLatest(record, reason: "hdc.impactObservationUnavailable")
      throw HDCControlValue.failure("factsDrifted", "fresh HDC impact could not be proven", details: ["controlAction": invalid.projection])
    }
    let latest = try refreshAge(required(actionID))
    guard latest.generation == record.generation else { return latest.projection }
    guard preview.impact == reading.impact,
      record.value["observationRelations"] == .array(reading.observationRelations),
      blocker(for: reading, intent: record.intent) == nil
    else {
      let invalid = try invalidateLatest(record, reason: "hdc.previewDrifted")
      throw HDCControlValue.failure("factsDrifted", "fresh HDC impact differs from the reviewed preview", details: ["controlAction": invalid.projection])
    }
    let next = try latest.requestingImpactApproval(
      previewID: previewID, previewDigest: previewDigest, now: clock())
    try store.replace(next, expectedGeneration: latest.generation)
    return next.projection
  }

  package func humanAction(_ actionID: String) throws -> JSONValue {
    guard HDCControlValue.identifier(actionID) else {
      throw HDCControlValue.failure("invalidInput", "invalid human-action identity")
    }
    var found: HDCControlHumanAction?
    for record in try store.list() where record.humanAction?.actionID == actionID {
      guard found == nil else { throw HDCControlValue.failure("recordUnreadable", "human action has multiple owners") }
      found = record.humanAction
    }
    guard let found else { throw HDCControlValue.failure("resourceNotFound", "human action does not exist") }
    return found.projection
  }

  package func ownsResumeReference(_ reference: String) throws -> Bool {
    guard HDCControlValue.identifier(reference) else { return false }
    return try store.list().contains { $0.humanAction?.resumeReference == reference }
  }

  package func issueInteractiveChallenge(
    actionID: String, resumeReference: String
  ) throws -> JSONValue {
    let rows = try store.list().filter {
      $0.humanAction?.actionID == actionID
        && $0.humanAction?.resumeReference == resumeReference
    }
    guard rows.count == 1, let record = rows.first else {
      throw HDCControlValue.failure("resourceNotFound", "human action does not exist")
    }
    let current = try refreshAge(record)
    guard current.state == "awaitingImpactApproval", let action = current.humanAction,
      action.status == "waiting"
    else { throw HDCControlValue.failure("humanActionExpired", "impact approval is no longer waiting") }
    let challenge = "ARKDECK-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9).uppercased()
    let next = try current.issuingInteractiveChallenge(challenge: challenge, now: clock())
    try store.replace(next, expectedGeneration: current.generation)
    guard let issued = next.interactionChallenge else {
      throw HDCControlValue.failure("recordUnreadable", "interactive challenge was not persisted")
    }
    return .object([
      "schemaVersion": .string("arkdeck.impact-approval-challenge/1"),
      "interactionOrigin": .string("interactiveConsole"),
      "challenge": .string(challenge), "challengeId": issued.value["challengeId"]!,
      "expiresAt": issued.value["expiresAt"]!, "humanAction": action.projection,
      "controlAction": next.projection,
      "binding": .object([
        "controlActionId": issued.value["controlActionId"]!,
        "humanActionId": issued.value["humanActionId"]!,
        "previewId": issued.value["previewId"]!,
        "previewDigest": issued.value["previewDigest"]!,
        "generation": issued.value["controlActionGeneration"]!,
      ]),
      "newDispatchCount": .integer(0),
    ])
  }

  /// Consumes only the plaintext obtained from the same Runtime-authenticated
  /// foreground console request. The final Job interlock is acquired before
  /// the approval receipt is written; fresh full impact is then reproduced,
  /// and the accepted Supervisor/executor chain owns every later transition.
  package func consumeInteractiveChallenge(
    actionID: String, resumeReference: String, response: String
  ) async throws -> JSONValue {
    guard response.utf8.count == 17, response.hasPrefix("ARKDECK-"),
      response.dropFirst(8).utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
      }),
      let lifecycleDriver
    else {
      throw HDCControlValue.failure(
        "admissionDenied", "interactive HDC lifecycle execution is unavailable")
    }
    let before = try refreshAge(required(actionID))
    guard before.state == "awaitingImpactApproval",
      before.humanAction?.resumeReference == resumeReference,
      before.interactionChallenge != nil
    else {
      throw HDCControlValue.failure(
        "humanActionExpired", "impact approval is no longer awaiting this challenge")
    }
    let interlock = try await lifecycleDriver.acquireFinalInterlock()
    do {
      let reading = try await source.readImpact()
      let latest = try refreshAge(required(actionID))
      guard latest.generation == before.generation,
        latest.humanAction == before.humanAction,
        latest.interactionChallenge == before.interactionChallenge,
        let preview = latest.preview,
        preview.impact == reading.impact,
        latest.value["observationRelations"] == .array(reading.observationRelations),
        blocker(for: reading, intent: latest.intent) == nil
      else {
        let invalid = try invalidateLatest(latest, reason: "hdc.previewDrifted")
        throw HDCControlValue.failure(
          "factsDrifted", "fresh HDC impact differs before interactive approval",
          details: ["controlAction": invalid.projection])
      }
      let approved = try latest.recordingInteractiveApproval(
        response: response, now: clock())
      try store.replace(approved, expectedGeneration: latest.generation)
      let expectedImpact = preview.impact
      let expectedRelations = reading.observationRelations
      let impactSource = source
      let clock = now
      let audit = RuntimeHDCControlLifecycleAuditStore(
        store: store, actionID: actionID, now: clock,
        onLaunchWindowEntered: { lifecycleDriver.noteLaunchWindowEntered() },
        finalImpactValidator: {
          let final = try await impactSource.readImpact()
          return final.impact == expectedImpact
            && final.observationRelations == expectedRelations
            && final.blockerReasonCode == nil
            && final.impact.criticalGateIsClear
        })
      let completed = try await lifecycleDriver.restart(
        approved: approved, reading: reading, audit: audit)
      guard ["succeeded", "failed", "outcomeUnknown"].contains(completed.state) else {
        throw HDCControlValue.failure(
          "recordUnreadable", "HDC lifecycle driver returned a nonterminal control action")
      }
      try await interlock.release()
      return completed.projection
    } catch {
      // The driver has returned, so no process launch can still be in flight.
      // Close whatever durable boundary it reached before releasing the Job
      // admission interlock. This is also idempotently repeated after reopen.
      let recovery = RuntimeHDCControlLifecycleAuditStore(
        store: store, actionID: actionID, now: now)
      _ = try? recovery.recoverInterruptedLifecycle()
      try? await interlock.release()
      throw error
    }
  }

  package func humanActionResourceRows(
    ownerID: String?
  ) throws -> [RuntimeHumanActionResourceRow] {
    if let ownerID, !HDCControlValue.identifier(ownerID) {
      throw HDCControlValue.failure("invalidInput", "invalid human-action owner")
    }
    return try store.list().compactMap { record in
      guard ownerID == nil || ownerID == record.actionID, let action = record.humanAction,
        case .string(let createdAt)? = action.value["createdAt"] else { return nil }
      return RuntimeHumanActionResourceRow(
        createdAt: createdAt, actionID: action.actionID,
        ownerKind: "controlAction", ownerID: record.actionID,
        resumeReference: action.resumeReference, value: action.projection)
    }
  }

  private func finishObservation(_ initial: HDCControlActionRecord) async throws -> HDCControlActionRecord {
    if let task = inFlight[initial.actionID]?.task { return try await task.value }
    let flightID = UUID()
    let task = Task {
      defer { if inFlight[initial.actionID]?.id == flightID { inFlight.removeValue(forKey: initial.actionID) } }
      let record = try refreshAge(required(initial.actionID))
      guard record.state == "observing" else { return record }
      let reading: HDCControlImpactReading
      do { reading = try await source.readImpact() }
      catch { return try invalidateLatest(record, reason: "hdc.impactObservationUnavailable") }
      let latest = try refreshAge(required(record.actionID))
      guard latest.state == "observing", latest.generation == record.generation else { return latest }
      let blocker = blocker(for: reading, intent: record.intent)
      let published = try latest.publishing(impact: reading.impact, relations: reading.observationRelations, blocker: blocker, now: clock())
      try store.replace(published, expectedGeneration: latest.generation)
      return published
    }
    inFlight[initial.actionID] = (flightID, task)
    return try await task.value
  }

  private func blocker(for reading: HDCControlImpactReading, intent: HDCControlActionIntent) -> String? {
    if reading.impact.value["serverGeneration"] == .null { return "hdc.serverIdentityUnproven" }
    if reading.impact.value["serverEndpointRef"] != .string(intent.endpointReference) ||
      reading.impact.value["serverGeneration"] != .string(String(intent.expectedGeneration)) { return "hdc.serverGenerationChanged" }
    if !reading.impact.criticalGateIsClear { return "hdc.criticalJobsUnresolved" }
    if reading.impact.value["serverHealth"] != .string("healthy") { return "hdc.serverHealthUnproven" }
    return reading.blockerReasonCode
  }

  private func clock() throws -> Date {
    let current = now()
    guard current.timeIntervalSince1970.isFinite else { throw HDCControlValue.failure("orchestrationClockUntrusted", "control-action time is unavailable") }
    return current
  }

  private func required(_ id: String) throws -> HDCControlActionRecord {
    guard let record = try store.load(actionID: id) else { throw HDCControlValue.failure("resourceNotFound", "control action does not exist") }
    return record
  }

  private func refreshAge(_ original: HDCControlActionRecord) throws -> HDCControlActionRecord {
    var record = original
    if record.runtimeEpoch != epoch,
      ["approvalRecorded", "dispatchPrepared", "dispatching"].contains(record.state)
    {
      let recovery = RuntimeHDCControlLifecycleAuditStore(
        store: store, actionID: record.actionID, now: now)
      record = try recovery.recoverInterruptedLifecycle()
    }
    guard ["observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "blocked"].contains(record.state) else { return record }
    let current = try clock()
    guard let last = HDCControlValue.time(record.lastObservedAt), let expires = HDCControlValue.time(record.expiresAt), current >= last else {
      throw HDCControlValue.failure("orchestrationClockUntrusted", "control-action clock moved backwards")
    }
    let reason: String
    if current >= expires { reason = "controlAction.expired" }
    else if record.runtimeEpoch != epoch { reason = "controlAction.runtimeRestarted" }
    else if record.value["catalogDigest"] != .string(catalogDigest) { reason = "controlAction.catalogChanged" }
    else { return record }
    let next = try record.invalidated(reason: reason, expired: current >= expires, now: current)
    try store.replace(next, expectedGeneration: record.generation)
    return next
  }

  private func invalidateLatest(_ before: HDCControlActionRecord, reason: String) throws -> HDCControlActionRecord {
    let latest = try refreshAge(required(before.actionID))
    guard latest.generation == before.generation else { return latest }
    let next = try latest.invalidated(reason: reason, expired: false, now: clock())
    if next != latest { try store.replace(next, expectedGeneration: latest.generation) }
    return next
  }
}
