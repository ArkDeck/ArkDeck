import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Foundation

package struct RuntimeToolSelectionRegistryCandidate: Sendable, Equatable {
  package let activeTool: RuntimeToolSelectionToolFacts
  package let newTool: RuntimeToolSelectionToolFacts
  package let activeGeneration: UInt64

  package init(
    activeTool: RuntimeToolSelectionToolFacts,
    newTool: RuntimeToolSelectionToolFacts,
    activeGeneration: UInt64
  ) {
    self.activeTool = activeTool
    self.newTool = newTool
    self.activeGeneration = activeGeneration
  }
}

package enum RuntimeToolSelectionDurableOutcome: Sendable, Equatable {
  case pending
  case succeeded(activeToolRef: String, activeGeneration: UInt64)
  case failed(activeToolRef: String, activeGeneration: UInt64, reasonCode: String)
  case absent
}

package protocol RuntimeToolSelectionRegistryControlling: Sendable {
  func candidate(
    newToolRef: String, expectedActiveGeneration: UInt64,
    pendingActionID: String?
  ) throws -> RuntimeToolSelectionRegistryCandidate
  func prepare(
    actionID: String, newToolRef: String, expectedActiveGeneration: UInt64
  ) throws -> ResolvedExecutable
  func failPending(actionID: String, reasonCode: String) throws
  func outcome(actionID: String) throws -> RuntimeToolSelectionDurableOutcome
  func acknowledge(actionID: String) throws
}

package struct RuntimeToolSelectionImpactReading: Sendable, Equatable {
  package let impact: RuntimeToolSelectionImpact
  package let observationRelations: [JSONValue]
  package let blockerReasonCode: String?
}

package protocol RuntimeToolSelectionLifecycleDriving: Sendable {
  func acquireFinalInterlock() async throws -> any HDCControlLifecycleInterlock
  func noteLaunchWindowEntered()
  func restartWithSelectedTool(
    approved: RuntimeToolSelectionControlActionRecord,
    reading: RuntimeToolSelectionImpactReading,
    audit: RuntimeToolSelectionLifecycleAuditStore
  ) async throws
}

/// One durable owner for the tool-selection preview, HAR, accepted HDC
/// lifecycle dispatch, daemon recomposition and final active-selection CAS.
public actor RuntimeToolSelectionControlActionCoordinator {
  private let store: RuntimeToolSelectionControlActionStore
  private let pages: RuntimeSnapshotPager
  private let hdcSource: any HDCControlImpactObserving
  private let registry: any RuntimeToolSelectionRegistryControlling
  private let lifecycle: (any RuntimeToolSelectionLifecycleDriving)?
  private let epoch: String
  private let catalogDigest: String
  private let now: @Sendable () -> Date
  private var inFlight:
    [String: (id: UUID, task: Task<RuntimeToolSelectionControlActionRecord, Error>)] = [:]

  package init(
    directory: URL, hdcSource: any HDCControlImpactObserving,
    registry: any RuntimeToolSelectionRegistryControlling,
    lifecycle: (any RuntimeToolSelectionLifecycleDriving)? = nil,
    catalogDigest: String, epoch: String = UUID().uuidString.lowercased(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    store = try RuntimeToolSelectionControlActionStore(
      directory: directory.appending(path: "records"))
    pages = try RuntimeSnapshotPager(directory: directory.appending(path: "snapshots"))
    self.hdcSource = hdcSource
    self.registry = registry
    self.lifecycle = lifecycle
    self.catalogDigest = catalogDigest
    self.epoch = epoch
    self.now = now
  }

  /// The single select leaf creates the immutable preview and, when eligible,
  /// its impact-approval HAR. It never changes the active selection.
  package func select(_ fields: [String: JSONValue]) async throws -> JSONValue {
    let intent = try RuntimeToolSelectionIntent(fields)
    if let existing = try store.load(requestID: intent.actionRequestID) {
      guard existing.intent == intent else {
        throw HDCControlValue.failure(
          "idempotencyConflict", "the request identity belongs to a different tool-selection intent"
        )
      }
      let record = try refresh(existing)
      if record.state == "observing" {
        return try await finishObservation(record, requestApproval: true).projection
      }
      return record.projection
    }
    let record = try store.begin(
      intent: intent, catalogDigest: catalogDigest, runtimeEpoch: epoch, now: clock())
    return try await finishObservation(record, requestApproval: true).projection
  }

  package func show(_ actionID: String) async throws -> JSONValue {
    try await reconcileRecord(required(actionID)).projection
  }

  package func reconcile(_ actionID: String) async throws -> JSONValue {
    try await reconcileRecord(required(actionID)).projection
  }

  package func listRecords() throws -> [RuntimeToolSelectionControlActionRecord] {
    try store.list().map(refresh)
  }

  package func list(
    filters: [String: JSONValue], pageSize: Int, cursor: String?
  ) throws -> JSONValue {
    guard Set(filters.keys).isSubset(of: ["kind", "state"]),
      filters["kind"] == nil || filters["kind"] == .string("runtimeToolSelection"),
      filters["state"] == nil || HDCControlValue.oneOf(filters["state"], Self.states)
    else {
      throw HDCControlValue.failure("invalidInput", "unsupported tool-selection discovery filter")
    }
    return try pages.page(
      method: "control-action.list", filters: filters,
      order: "createdAtThenControlActionId", pageSize: pageSize, cursor: cursor
    ) {
      try store.list().map(refresh).filter {
        filters["state"] == nil || filters["state"] == .string($0.state)
      }.map(\.projection)
    }
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
    let current = try refresh(record)
    guard current.state == "awaitingImpactApproval", current.humanAction?.status == "waiting" else {
      throw HDCControlValue.failure("humanActionExpired", "impact approval is no longer waiting")
    }
    let challenge =
      "ARKDECK-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9).uppercased()
    let next = try current.issuingInteractiveChallenge(challenge: challenge, now: clock())
    try store.replace(next, expectedGeneration: current.generation)
    guard let issued = next.interactionChallenge, let action = next.humanAction else {
      throw HDCControlValue.failure("recordUnreadable", "interactive challenge was not persisted")
    }
    return .object([
      "schemaVersion": .string("arkdeck.impact-approval-challenge/1"),
      "interactionOrigin": .string("interactiveConsole"), "challenge": .string(challenge),
      "challengeId": issued.value["challengeId"]!, "expiresAt": issued.value["expiresAt"]!,
      "humanAction": action.projection, "controlAction": next.projection,
      "binding": .object([
        "controlActionId": issued.value["controlActionId"]!,
        "humanActionId": issued.value["humanActionId"]!,
        "previewId": issued.value["previewId"]!, "previewDigest": issued.value["previewDigest"]!,
        "generation": issued.value["controlActionGeneration"]!,
      ]),
      "newDispatchCount": .integer(0),
    ])
  }

  package func consumeInteractiveChallenge(
    actionID: String, resumeReference: String, response: String
  ) async throws -> JSONValue {
    guard response.utf8.count == 17, response.hasPrefix("ARKDECK-"),
      response.dropFirst(8).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
      let lifecycle
    else {
      throw HDCControlValue.failure("admissionDenied", "interactive tool selection is unavailable")
    }
    let before = try refresh(required(actionID))
    guard before.state == "awaitingImpactApproval",
      before.humanAction?.resumeReference == resumeReference,
      before.interactionChallenge != nil, let preview = before.preview
    else {
      throw HDCControlValue.failure(
        "humanActionExpired", "impact approval is no longer awaiting this challenge")
    }
    let interlock = try await lifecycle.acquireFinalInterlock()
    var releaseInterlock = true
    do {
      let reading = try await read(before.intent)
      let latest = try refresh(required(actionID))
      guard latest.generation == before.generation,
        latest.humanAction == before.humanAction,
        latest.interactionChallenge == before.interactionChallenge,
        preview.impact == reading.impact,
        latest.value["observationRelations"] == .array(reading.observationRelations),
        blocker(reading, intent: latest.intent) == nil
      else {
        let invalid = try invalidate(latest, reason: "tool.selectionPreviewDrifted")
        throw HDCControlValue.failure(
          "factsDrifted", "fresh tool-selection impact differs before approval",
          details: ["controlAction": invalid.projection])
      }
      let approved = try latest.recordingInteractiveApproval(response: response, now: clock())
      try store.replace(approved, expectedGeneration: latest.generation)
      let source = hdcSource
      let registry = registry
      let expectedImpact = reading.impact
      let audit = RuntimeToolSelectionLifecycleAuditStore(
        store: store, actionID: actionID, now: now,
        finalImpactValidator: {
          let freshHDC = try await source.readImpact()
          let candidate = try registry.candidate(
            newToolRef: approved.intent.newToolRef,
            expectedActiveGeneration: approved.intent.expectedActiveGeneration,
            pendingActionID: approved.actionID)
          let fresh = try RuntimeToolSelectionImpact(
            hdc: freshHDC.impact, oldTool: candidate.activeTool,
            newTool: candidate.newTool, activeGeneration: candidate.activeGeneration)
          return fresh == expectedImpact && freshHDC.blockerReasonCode == nil
        }, onLaunchWindowEntered: { lifecycle.noteLaunchWindowEntered() })
      _ = try audit.markSelectionPrepared()
      do {
        try await lifecycle.restartWithSelectedTool(
          approved: approved, reading: reading, audit: audit)
        let record = try audit.record()
        guard record.state == "outcomeUnknown" else {
          throw HDCControlValue.failure(
            "recordUnreadable", "selected HDC lifecycle did not enter its durable launch window")
        }
        // The Runtime lifecycle lease remains held until launchd replaces this
        // daemon. This closes the transient window between new server facts and
        // the next fully recomposed provider graph.
        releaseInterlock = false
        return record.projection
      } catch {
        if audit.launchWindowWasEntered() {
          releaseInterlock = false
          let record = try? audit.record()
          throw HDCControlValue.failure(
            "outcomeUnknown", "tool-selection lifecycle requires startup reconciliation",
            details: record.map { ["controlAction": $0.projection] } ?? [:])
        }
        let record = try audit.record()
        _ = try? registry.failPending(
          actionID: actionID, reasonCode: "tool.lifecycleFailedBeforeLaunch")
        let failed =
          (try? audit.markFailedBeforeLaunch(reasonCode: "tool.lifecycleFailedBeforeLaunch"))
          ?? record
        throw HDCControlValue.failure(
          "operationFailed", "tool selection failed before a confirmed lifecycle effect",
          details: ["controlAction": failed.projection])
      }
    } catch {
      if releaseInterlock {
        try? await interlock.release()
        releaseInterlock = false
      }
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
        case .string(let createdAt)? = action.value["createdAt"]
      else { return nil }
      return RuntimeHumanActionResourceRow(
        createdAt: createdAt, actionID: action.actionID, ownerKind: "controlAction",
        ownerID: record.actionID, resumeReference: action.resumeReference,
        value: action.projection)
    }
  }

  private func finishObservation(
    _ initial: RuntimeToolSelectionControlActionRecord, requestApproval: Bool
  ) async throws -> RuntimeToolSelectionControlActionRecord {
    if let task = inFlight[initial.actionID]?.task { return try await task.value }
    let flightID = UUID()
    let task = Task {
      defer {
        if inFlight[initial.actionID]?.id == flightID {
          inFlight.removeValue(forKey: initial.actionID)
        }
      }
      let record = try refresh(required(initial.actionID))
      guard record.state == "observing" else { return record }
      let reading: RuntimeToolSelectionImpactReading
      do { reading = try await read(record.intent) } catch {
        return try invalidate(record, reason: "tool.selectionFactsUnavailable")
      }
      let latest = try refresh(required(record.actionID))
      guard latest.state == "observing", latest.generation == record.generation else {
        return latest
      }
      let published = try latest.publishing(
        impact: reading.impact, relations: reading.observationRelations,
        blocker: blocker(reading, intent: record.intent), now: clock())
      try store.replace(published, expectedGeneration: latest.generation)
      guard requestApproval, published.state == "previewReady" else { return published }
      let fresh = try await read(record.intent)
      guard fresh == reading else {
        return try invalidate(published, reason: "tool.selectionPreviewDrifted")
      }
      let awaiting = try published.requestingImpactApproval(now: clock())
      try store.replace(awaiting, expectedGeneration: published.generation)
      return awaiting
    }
    inFlight[initial.actionID] = (flightID, task)
    return try await task.value
  }

  private func read(
    _ intent: RuntimeToolSelectionIntent
  ) async throws -> RuntimeToolSelectionImpactReading {
    let hdc = try await hdcSource.readImpact()
    let candidate = try registry.candidate(
      newToolRef: intent.newToolRef,
      expectedActiveGeneration: intent.expectedActiveGeneration,
      pendingActionID: nil)
    return RuntimeToolSelectionImpactReading(
      impact: try RuntimeToolSelectionImpact(
        hdc: hdc.impact, oldTool: candidate.activeTool,
        newTool: candidate.newTool, activeGeneration: candidate.activeGeneration),
      observationRelations: hdc.observationRelations,
      blockerReasonCode: hdc.blockerReasonCode)
  }

  private func blocker(
    _ reading: RuntimeToolSelectionImpactReading,
    intent: RuntimeToolSelectionIntent
  ) -> String? {
    if reading.impact.activeGeneration != intent.expectedActiveGeneration {
      return "tool.activeGenerationChanged"
    }
    if reading.impact.newTool.toolRef != intent.newToolRef { return "tool.candidateChanged" }
    if !reading.impact.hdc.criticalGateIsClear { return "hdc.criticalJobsUnresolved" }
    if reading.impact.hdc.value["serverHealth"] != .string("healthy") {
      return "hdc.serverHealthUnproven"
    }
    return reading.blockerReasonCode
  }

  private func reconcileRecord(
    _ original: RuntimeToolSelectionControlActionRecord
  ) async throws -> RuntimeToolSelectionControlActionRecord {
    let record = try refresh(original)
    if record.state == "observing" {
      return try await finishObservation(record, requestApproval: true)
    }
    if record.state == "outcomeUnknown" {
      switch try registry.outcome(actionID: record.actionID) {
      case .pending: return record
      case .succeeded(let reference, let generation):
        let settled = try record.settled(
          result: "succeeded", activeToolRef: reference,
          activeGeneration: generation, reasonCode: nil, now: clock())
        try store.replace(settled, expectedGeneration: record.generation)
        try registry.acknowledge(actionID: record.actionID)
        return settled
      case .failed(let reference, let generation, let reason):
        let settled = try record.settled(
          result: "failed", activeToolRef: reference,
          activeGeneration: generation, reasonCode: reason, now: clock())
        try store.replace(settled, expectedGeneration: record.generation)
        try registry.acknowledge(actionID: record.actionID)
        return settled
      case .absent:
        throw HDCControlValue.failure(
          "recordUnreadable", "pending tool selection lost its durable registry outcome")
      }
    }
    return record
  }

  private func refresh(
    _ original: RuntimeToolSelectionControlActionRecord
  ) throws -> RuntimeToolSelectionControlActionRecord {
    guard
      [
        "observing", "previewReady", "awaitingImpactApproval", "approvalRecorded",
        "dispatchPrepared", "blocked",
      ].contains(original.state)
    else { return original }
    let current = try clock()
    guard let last = HDCControlValue.time(original.lastObservedAt),
      let expires = HDCControlValue.time(original.expiresAt), current >= last
    else {
      throw HDCControlValue.failure(
        "orchestrationClockUntrusted", "tool-selection clock moved backwards")
    }
    let reason: String?
    if current >= expires {
      reason = "controlAction.expired"
    } else if original.runtimeEpoch != epoch {
      reason = "controlAction.runtimeRestarted"
    } else {
      reason = nil
    }
    guard let reason else { return original }
    return try invalidate(original, reason: reason, expired: current >= expires)
  }

  private func invalidate(
    _ original: RuntimeToolSelectionControlActionRecord,
    reason: String, expired: Bool = false
  ) throws -> RuntimeToolSelectionControlActionRecord {
    let latest = try required(original.actionID)
    guard latest.generation == original.generation else { return latest }
    let invalid = try latest.invalidated(reason: reason, expired: expired, now: clock())
    try store.replace(invalid, expectedGeneration: latest.generation)
    return invalid
  }

  private func required(_ actionID: String) throws -> RuntimeToolSelectionControlActionRecord {
    guard let record = try store.load(actionID: actionID) else {
      throw HDCControlValue.failure("resourceNotFound", "control action does not exist")
    }
    return record
  }

  private func clock() throws -> Date {
    let current = now()
    guard current.timeIntervalSince1970.isFinite else {
      throw HDCControlValue.failure(
        "orchestrationClockUntrusted", "tool-selection time is unavailable")
    }
    return current
  }

  private static let states: Set<String> = [
    "observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared",
    "outcomeUnknown", "succeeded", "failed", "blocked", "expired", "previewDrifted",
  ]
}
