import Foundation

/// The impact approval belongs to the host-wide control action. It is not a
/// Job-shaped `HumanActionRequired`: manufacturing a Job identity here would
/// make discovery and lifecycle audit point at an owner that never existed.
package struct HDCControlHumanAction: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let actionID: String
  package let resumeReference: String
  package let status: String

  package init(
    controlActionID: String, preview: HDCControlActionPreview,
    generation: UInt64, createdAt: String, expiresAt: String
  ) throws {
    try self.init(value: [
      "actionId": .string("har-" + UUID().uuidString.lowercased()),
      "resumeReference": .string("resume-" + UUID().uuidString.lowercased()),
      "controlActionId": .string(controlActionID),
      "previewId": preview.value["previewId"]!,
      "previewDigest": preview.value["previewDigest"]!,
      "controlActionGeneration": .string(String(generation)),
      "createdAt": .string(createdAt), "expiresAt": .string(expiresAt),
      "status": .string("waiting"),
    ])
  }

  package init(value: [String: JSONValue]) throws {
    guard Set(value.keys) == ["actionId", "resumeReference", "controlActionId", "previewId",
      "previewDigest", "controlActionGeneration", "createdAt", "expiresAt", "status"],
      case .string(let action)? = value["actionId"], HDCControlValue.identifier(action),
      case .string(let resume)? = value["resumeReference"], HDCControlValue.identifier(resume),
      case .string(let owner)? = value["controlActionId"], HDCControlValue.identifier(owner),
      case .string(let preview)? = value["previewId"], HDCControlValue.identifier(preview),
      case .string(let digest)? = value["previewDigest"], HDCControlValue.digest(digest),
      case .string(let generation)? = value["controlActionGeneration"],
      HDCControlValue.generation(generation) != nil,
      case .string(let created)? = value["createdAt"], let start = HDCControlValue.time(created),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires), end > start,
      case .string(let status)? = value["status"], ["waiting", "expired", "resolved"].contains(status)
    else { throw HDCControlValue.failure("recordUnreadable", "control-action human action is malformed") }
    self.value = value; actionID = action; resumeReference = resume; self.status = status
  }

  package func expiring() throws -> Self {
    guard status == "waiting" else { return self }
    var fields = value; fields["status"] = .string("expired")
    return try Self(value: fields)
  }

  package func resolving() throws -> Self {
    guard status == "waiting" else {
      throw HDCControlValue.failure("humanActionExpired", "impact approval is no longer waiting")
    }
    var fields = value; fields["status"] = .string("resolved")
    return try Self(value: fields)
  }

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.human-action/1"), "actionId": value["actionId"]!,
      "owner": .object(["kind": .string("controlAction"), "id": value["controlActionId"]!]),
      "resumeReference": value["resumeReference"]!, "category": .string("impactApproval"),
      "reasonCode": .string("policy.impactApprovalRequired"),
      "minimumAction": .string("human.reviewImpact"),
      "prohibitedAutomation": .array([.string("selfApproval")]),
      "createdAt": value["createdAt"]!, "expiresAt": value["expiresAt"]!,
      "status": value["status"]!, "newDispatchCount": .integer(0),
      "selectionSchema": .null, "choices": .array([]),
      "binding": .object([
        "controlActionId": value["controlActionId"]!, "previewId": value["previewId"]!,
        "previewDigest": value["previewDigest"]!,
        "generation": value["controlActionGeneration"]!,
      ]),
    ])
  }
}

package struct HDCControlInteractionChallenge: Equatable, Sendable {
  package let value: [String: JSONValue]

  package init(
    controlActionID: String, humanAction: HDCControlHumanAction,
    challenge: String, issuedAt: String, expiresAt: String
  ) throws {
    try self.init(value: [
      "challengeId": .string("challenge-" + UUID().uuidString.lowercased()),
      "challengeSha256": .string(SHA256Hex.string(of: Data(challenge.utf8))),
      "controlActionId": .string(controlActionID),
      "humanActionId": .string(humanAction.actionID),
      "previewId": humanAction.value["previewId"]!,
      "previewDigest": humanAction.value["previewDigest"]!,
      "controlActionGeneration": humanAction.value["controlActionGeneration"]!,
      "issuedAt": .string(issuedAt), "expiresAt": .string(expiresAt),
    ])
  }

  package init(value: [String: JSONValue]) throws {
    guard Set(value.keys) == ["challengeId", "challengeSha256", "controlActionId", "humanActionId",
      "previewId", "previewDigest", "controlActionGeneration", "issuedAt", "expiresAt"],
      case .string(let challenge)? = value["challengeId"], HDCControlValue.identifier(challenge),
      case .string(let hash)? = value["challengeSha256"], HDCControlValue.digest(hash),
      case .string(let owner)? = value["controlActionId"], HDCControlValue.identifier(owner),
      case .string(let action)? = value["humanActionId"], HDCControlValue.identifier(action),
      case .string(let preview)? = value["previewId"], HDCControlValue.identifier(preview),
      case .string(let digest)? = value["previewDigest"], HDCControlValue.digest(digest),
      case .string(let generation)? = value["controlActionGeneration"], HDCControlValue.generation(generation) != nil,
      case .string(let issued)? = value["issuedAt"], let start = HDCControlValue.time(issued),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires),
      end > start, end.timeIntervalSince(start) <= 120
    else { throw HDCControlValue.failure("recordUnreadable", "interactive challenge is malformed") }
    self.value = value
  }
}

/// Durable discovery and preview state. This initial record deliberately has
/// no API that can mint a confirmation, mark dispatch successful or replay it.
package struct HDCControlActionRecord: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let intent: HDCControlActionIntent
  package let preview: HDCControlActionPreview?
  package let humanAction: HDCControlHumanAction?
  package let interactionChallenge: HDCControlInteractionChallenge?
  package let interactionReceipt: HDCControlInteractionReceipt?
  package let lifecycleAudit: [HDCControlLifecycleAuditEntry]
  package let actionID: String
  package let generation: UInt64
  package let state: String
  package let createdAt: String
  package let expiresAt: String
  package let lastObservedAt: String
  package let runtimeEpoch: String

  package init(intent: HDCControlActionIntent, catalogDigest: String, runtimeEpoch: String, now: Date) throws {
    let created = Self.timestamp(now)
    guard let date = HDCControlValue.time(created) else { throw HDCControlValue.failure("recordUnreadable", "control action requires a representable creation time") }
    try self.init(value: ["schemaVersion": .string("arkdeck.runtime-hdc-control-action/1"),
      "controlActionId": .string("control-action-" + UUID().uuidString.lowercased()),
      "actionRequestId": .string(intent.actionRequestID), "request": .object(intent.request),
      "requestFingerprint": .string(try intent.fingerprint), "fingerprintAlgorithm": .string("sha256-jcs"),
      "catalogDigest": .string(catalogDigest), "runtimeEpoch": .string(runtimeEpoch),
      "generation": .string("1"), "state": .string("observing"), "createdAt": .string(created),
      "expiresAt": .string(Self.timestamp(date.addingTimeInterval(300))), "lastObservedAt": .string(created),
      "preview": .null, "blockerReasonCode": .null, "observationRelations": .array([]),
      "humanAction": .null, "interactionChallenge": .null,
      "interactionReceipt": .null, "lifecycleAudit": .array([])])
  }

  package init(value: [String: JSONValue]) throws {
    guard Set(value.keys) == ["schemaVersion", "controlActionId", "actionRequestId", "request", "requestFingerprint", "fingerprintAlgorithm",
      "catalogDigest", "runtimeEpoch", "generation", "state", "createdAt", "expiresAt", "lastObservedAt", "preview", "blockerReasonCode", "observationRelations", "humanAction", "interactionChallenge", "interactionReceipt", "lifecycleAudit"],
      value["schemaVersion"] == .string("arkdeck.runtime-hdc-control-action/1"),
      case .string(let id)? = value["controlActionId"], HDCControlValue.identifier(id),
      case .object(let request)? = value["request"],
      value["fingerprintAlgorithm"] == .string("sha256-jcs"),
      case .string(let catalog)? = value["catalogDigest"], HDCControlValue.digest(catalog),
      case .string(let epoch)? = value["runtimeEpoch"], HDCControlValue.identifier(epoch),
      case .string(let generationText)? = value["generation"], let generation = HDCControlValue.generation(generationText),
      case .string(let state)? = value["state"], ["observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown", "blocked", "expired", "previewDrifted"].contains(state),
      case .string(let created)? = value["createdAt"], let start = HDCControlValue.time(created),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires), end.timeIntervalSince(start) == 300,
      case .string(let observed)? = value["lastObservedAt"], let latest = HDCControlValue.time(observed), latest >= start,
      HDCControlValue.optionalIdentifier(value["blockerReasonCode"]),
      case .array(let relations)? = value["observationRelations"], relations.count <= 1000
    else { throw HDCControlValue.failure("recordUnreadable", "control-action record has invalid identity or state") }
    let intent = try HDCControlActionIntent(request)
    guard value["actionRequestId"] == .string(intent.actionRequestID), value["requestFingerprint"] == .string(try intent.fingerprint) else {
      throw HDCControlValue.failure("recordUnreadable", "control-action intent fingerprint is invalid")
    }
    let preview: HDCControlActionPreview?
    if value["preview"] == .null { preview = nil }
    else if case .object(let fields)? = value["preview"] { preview = try HDCControlActionPreview(value: fields) }
    else { throw HDCControlValue.failure("recordUnreadable", "control-action preview is malformed") }
    let humanAction: HDCControlHumanAction?
    if value["humanAction"] == .null { humanAction = nil }
    else if case .object(let fields)? = value["humanAction"] { humanAction = try HDCControlHumanAction(value: fields) }
    else { throw HDCControlValue.failure("recordUnreadable", "control-action human action is malformed") }
    let interactionChallenge: HDCControlInteractionChallenge?
    if value["interactionChallenge"] == .null { interactionChallenge = nil }
    else if case .object(let fields)? = value["interactionChallenge"] {
      interactionChallenge = try HDCControlInteractionChallenge(value: fields)
    } else { throw HDCControlValue.failure("recordUnreadable", "control-action challenge is malformed") }
    let interactionReceipt: HDCControlInteractionReceipt?
    if value["interactionReceipt"] == .null { interactionReceipt = nil }
    else if case .object(let fields)? = value["interactionReceipt"] {
      interactionReceipt = try HDCControlInteractionReceipt(value: fields)
    } else { throw HDCControlValue.failure("recordUnreadable", "control-action interaction receipt is malformed") }
    guard case .array(let rawLifecycleAudit)? = value["lifecycleAudit"],
      rawLifecycleAudit.count <= 16
    else { throw HDCControlValue.failure("recordUnreadable", "control-action lifecycle audit is malformed") }
    let lifecycleAudit = try rawLifecycleAudit.map { raw -> HDCControlLifecycleAuditEntry in
      guard case .object(let fields) = raw else {
        throw HDCControlValue.failure("recordUnreadable", "control-action lifecycle audit entry is malformed")
      }
      return try HDCControlLifecycleAuditEntry(value: fields)
    }
    if let preview {
      guard preview.value["controlActionId"] == .string(id), preview.value["createdAt"] == .string(created),
        preview.value["expiresAt"] == .string(expires), preview.impact.value["serverEndpointRef"] == .string(intent.endpointReference),
        state != "observing"
      else { throw HDCControlValue.failure("recordUnreadable", "control-action preview belongs to another owner or intent") }
    } else if ["previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state) {
      throw HDCControlValue.failure("recordUnreadable", "ready control action has no preview")
    }
    if ["previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state) {
      let requiresLiveApprovalWindow = [
        "previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared",
      ].contains(state)
      let expectedLifecycleBlocker: JSONValue =
        state == "failed" ? .string("hdc.lifecycleFailedBeforeLaunch")
        : state == "outcomeUnknown" ? .string("hdc.lifecycleOutcomeUnknown")
        : .null
      guard let preview, preview.impact.criticalGateIsClear,
        preview.impact.value["serverGeneration"] == .string(String(intent.expectedGeneration)),
        preview.impact.value["serverHealth"] == .string("healthy"),
        value["blockerReasonCode"] == expectedLifecycleBlocker,
        !requiresLiveApprovalWindow || latest < end
      else { throw HDCControlValue.failure("recordUnreadable", "ready preview lacks its complete gate") }
    } else if state == "observing" {
      guard value["blockerReasonCode"] == .null, relations.isEmpty, humanAction == nil,
        interactionReceipt == nil, lifecycleAudit.isEmpty else {
        throw HDCControlValue.failure("recordUnreadable", "unobserved action has resolved facts")
      }
    } else if value["blockerReasonCode"] == .null,
      !["succeeded", "failed", "outcomeUnknown"].contains(state) {
      throw HDCControlValue.failure("recordUnreadable", "blocked control action has no reason")
    }
    if state == "awaitingImpactApproval" {
      guard let preview, let humanAction, humanAction.status == "waiting",
        humanAction.value["controlActionId"] == .string(id),
        humanAction.value["previewId"] == preview.value["previewId"],
        humanAction.value["previewDigest"] == preview.value["previewDigest"],
        case .string(let actionGeneration)? = humanAction.value["controlActionGeneration"],
        HDCControlValue.generation(actionGeneration).map({ $0 <= generation }) == true,
        humanAction.value["expiresAt"] == .string(expires), latest < end
      else { throw HDCControlValue.failure("recordUnreadable", "impact approval is not bound to its exact preview generation") }
    } else if let humanAction {
      let resolvedState = ["approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state)
      let invalidatedResolved = ["expired", "previewDrifted"].contains(state) && humanAction.status == "resolved"
      guard (resolvedState && humanAction.status == "resolved")
        || invalidatedResolved
        || (["expired", "previewDrifted"].contains(state) && humanAction.status == "expired")
      else {
        throw HDCControlValue.failure("recordUnreadable", "control action retains an invalid human-action state")
      }
    }
    if let interactionChallenge {
      guard ["awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown", "expired", "previewDrifted"].contains(state), let humanAction,
        interactionChallenge.value["controlActionId"] == .string(id),
        interactionChallenge.value["humanActionId"] == .string(humanAction.actionID),
        interactionChallenge.value["previewId"] == humanAction.value["previewId"],
        interactionChallenge.value["previewDigest"] == humanAction.value["previewDigest"],
        interactionChallenge.value["controlActionGeneration"] == humanAction.value["controlActionGeneration"],
        case .string(let challengeExpiry)? = interactionChallenge.value["expiresAt"],
        let challengeEnd = HDCControlValue.time(challengeExpiry), challengeEnd <= end
      else { throw HDCControlValue.failure("recordUnreadable", "interactive challenge is not bound to its HAR") }
    }
    if let interactionReceipt {
      guard let humanAction, let interactionChallenge,
        humanAction.status == "resolved",
        interactionReceipt.value["controlActionId"] == .string(id),
        interactionReceipt.value["humanActionId"] == .string(humanAction.actionID),
        interactionReceipt.value["challengeId"] == interactionChallenge.value["challengeId"],
        interactionReceipt.value["challengeSha256"] == interactionChallenge.value["challengeSha256"],
        interactionReceipt.value["previewId"] == humanAction.value["previewId"],
        interactionReceipt.value["previewDigest"] == humanAction.value["previewDigest"],
        interactionReceipt.value["controlActionGeneration"] == humanAction.value["controlActionGeneration"],
        case .string(let confirmedAt)? = interactionReceipt.value["confirmedAt"],
        let confirmationTime = HDCControlValue.time(confirmedAt),
        case .string(let issuedAt)? = interactionChallenge.value["issuedAt"],
        let issueTime = HDCControlValue.time(issuedAt),
        case .string(let challengeExpiresAt)? = interactionChallenge.value["expiresAt"],
        let challengeExpiry = HDCControlValue.time(challengeExpiresAt),
        confirmationTime >= issueTime, confirmationTime < challengeExpiry
      else { throw HDCControlValue.failure("recordUnreadable", "interactive receipt is not bound to its one-time challenge") }
    } else if ["approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state) {
      throw HDCControlValue.failure("recordUnreadable", "advanced control action lacks interactive approval proof")
    }
    try Self.validateLifecycleAudit(
      lifecycleAudit, state: state, interactionReceipt: interactionReceipt, preview: preview,
      intent: intent)
    // Private continuity bindings are persisted with the preview, not emitted
    // by list/show. A connect key by itself cannot create a relation proof.
    var boundIDs: Set<String> = []
    for relation in relations {
      guard case .object(let fields) = relation,
        Set(fields.keys) == ["observationId", "generation", "serial", "location", "attachmentId", "vendorId", "productId"],
        case .string(let observation)? = fields["observationId"], HDCControlValue.identifier(observation), boundIDs.insert(observation).inserted,
        case .string(let revision)? = fields["generation"], HDCControlValue.generation(revision) != nil,
        HDCControlValue.optionalText(fields["serial"], maximumBytes: 1024), fields["serial"] != .null,
        case .string(let location)? = fields["location"], UInt64(location).map(String.init) == location,
        case .string(let attachment)? = fields["attachmentId"], let attachmentNumber = UInt64(attachment), attachmentNumber > 0, String(attachmentNumber) == attachment,
        case .integer(let vendor)? = fields["vendorId"], (1...65535).contains(vendor),
        case .integer(let product)? = fields["productId"], (1...65535).contains(product)
      else { throw HDCControlValue.failure("recordUnreadable", "observation continuity binding is malformed") }
      guard let preview, case .array(let rows)? = preview.impact.value["affectedDeviceObservations"], rows.contains(where: {
        guard case .object(let row) = $0 else { return false }
        return row["observationId"] == .string(observation) && row["generation"] == .string(revision)
      }) else { throw HDCControlValue.failure("recordUnreadable", "continuity binding is absent from its preview") }
    }
    if ["previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state), let preview,
      case .array(let observations)? = preview.impact.value["affectedDeviceObservations"] {
      let observedIDs = Set(observations.compactMap { row -> String? in
        guard case .object(let fields) = row, case .string(let id)? = fields["observationId"] else { return nil }
        return id
      })
      guard observedIDs == boundIDs else { throw HDCControlValue.failure("recordUnreadable", "ready preview lacks durable observation relations") }
    }
    self.value = value; self.intent = intent; self.preview = preview; self.humanAction = humanAction
    self.interactionChallenge = interactionChallenge; self.interactionReceipt = interactionReceipt
    self.lifecycleAudit = lifecycleAudit; actionID = id
    self.generation = generation; self.state = state; createdAt = created; expiresAt = expires
    lastObservedAt = observed; runtimeEpoch = epoch
  }

  package func publishing(impact: HDCControlImpact, relations: [JSONValue], blocker: String?, now: Date) throws -> Self {
    guard state == "observing", preview == nil else { throw HDCControlValue.failure("resourceConflict", "the immutable preview has already been published") }
    let preview = try HDCControlActionPreview(actionID: actionID, previewID: "preview-" + UUID().uuidString.lowercased(),
      createdAt: createdAt, expiresAt: expiresAt, impact: impact)
    var fields = try advanced(now: now)
    fields["preview"] = .object(preview.value)
    fields["observationRelations"] = .array(relations)
    fields["state"] = .string(blocker == nil ? "previewReady" : "blocked")
    fields["blockerReasonCode"] = blocker.map(JSONValue.string) ?? .null
    return try Self(value: fields)
  }

  package func invalidated(reason: String, expired: Bool, now: Date) throws -> Self {
    guard ["observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "blocked"].contains(state) else { return self }
    var fields = try advanced(now: now)
    fields["state"] = .string(expired ? "expired" : "previewDrifted")
    fields["blockerReasonCode"] = .string(reason)
    if let humanAction { fields["humanAction"] = .object(try humanAction.expiring().value) }
    if interactionReceipt == nil { fields["interactionChallenge"] = .null }
    return try Self(value: fields)
  }

  package func issuingInteractiveChallenge(
    challenge: String, now: Date
  ) throws -> Self {
    guard state == "awaitingImpactApproval", let humanAction,
      humanAction.status == "waiting", challenge.utf8.count == 17,
      challenge.hasPrefix("ARKDECK-"),
      challenge.dropFirst(8).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
    else { throw HDCControlValue.failure("admissionDenied", "impact approval is not awaiting an interactive challenge") }
    let current = Self.timestamp(now)
    guard let ownerExpiry = HDCControlValue.time(expiresAt), now < ownerExpiry else {
      throw HDCControlValue.failure("humanActionExpired", "impact approval expired")
    }
    let challengeExpiry = min(ownerExpiry, now.addingTimeInterval(120))
    let challengeRecord = try HDCControlInteractionChallenge(
      controlActionID: actionID, humanAction: humanAction, challenge: challenge,
      issuedAt: current, expiresAt: Self.timestamp(challengeExpiry))
    var fields = try advanced(now: now)
    fields["interactionChallenge"] = .object(challengeRecord.value)
    return try Self(value: fields)
  }

  package func requestingImpactApproval(
    previewID: String, previewDigest: String, now: Date
  ) throws -> Self {
    guard state == "previewReady", let preview,
      preview.value["previewId"] == .string(previewID),
      preview.value["previewDigest"] == .string(previewDigest), humanAction == nil
    else { throw HDCControlValue.failure("reviewedPlanMismatch", "restart must name this action's exact immutable preview") }
    var fields = try advanced(now: now)
    let nextGeneration = generation + 1
    let action = try HDCControlHumanAction(
      controlActionID: actionID, preview: preview, generation: nextGeneration,
      createdAt: Self.timestamp(now), expiresAt: expiresAt)
    fields["state"] = .string("awaitingImpactApproval")
    fields["humanAction"] = .object(action.value)
    return try Self(value: fields)
  }

  package func recordingInteractiveApproval(
    response: String, now: Date
  ) throws -> Self {
    guard state == "awaitingImpactApproval", let humanAction, let interactionChallenge,
      interactionReceipt == nil,
      case .string(let challengeExpiry)? = interactionChallenge.value["expiresAt"],
      let expiry = HDCControlValue.time(challengeExpiry), now < expiry
    else {
      throw HDCControlValue.failure(
        "impactApprovalChallengeExpired", "the one-time impact challenge is absent or expired")
    }
    let confirmedAt = Self.timestamp(now)
    let receipt = try HDCControlInteractionReceipt(
      controlActionID: actionID, humanAction: humanAction,
      challenge: interactionChallenge, response: response, confirmedAt: confirmedAt)
    var fields = try advanced(now: now)
    fields["humanAction"] = .object(try humanAction.resolving().value)
    fields["interactionReceipt"] = .object(receipt.value)
    fields["state"] = .string("approvalRecorded")
    return try Self(value: fields)
  }

  package func appendingLifecycleAudit(
    kind: String, auditID: UUID, payload: [String: JSONValue], now: Date
  ) throws -> Self {
    guard interactionReceipt != nil,
      ["approvalRecorded", "dispatchPrepared", "dispatching"].contains(state),
      lifecycleAudit.count < 16
    else {
      throw HDCControlValue.failure(
        "admissionDenied", "control action cannot append another HDC lifecycle event")
    }
    let entry = try HDCControlLifecycleAuditEntry(
      kind: kind, auditID: auditID, payload: payload,
      sequence: lifecycleAudit.count + 1, recordedAt: Self.timestamp(now))
    var fields = try advanced(now: now)
    fields["lifecycleAudit"] = .array(
      lifecycleAudit.map { .object($0.value) } + [.object(entry.value)])
    fields["state"] = .string(Self.state(afterAppending: entry, prior: lifecycleAudit))
    switch Self.state(afterAppending: entry, prior: lifecycleAudit) {
    case "succeeded": fields["blockerReasonCode"] = .null
    case "failed": fields["blockerReasonCode"] = .string("hdc.lifecycleFailedBeforeLaunch")
    case "outcomeUnknown": fields["blockerReasonCode"] = .string("hdc.lifecycleOutcomeUnknown")
    default: break
    }
    return try Self(value: fields)
  }

  private func advanced(now: Date) throws -> [String: JSONValue] {
    guard generation < UInt64(Int64.max), let previous = HDCControlValue.time(lastObservedAt),
      now.timeIntervalSince1970.isFinite, now >= previous else {
      throw HDCControlValue.failure("orchestrationClockUntrusted", "control-action time moved behind its durable observation")
    }
    var fields = value
    fields["generation"] = .string(String(generation + 1)); fields["lastObservedAt"] = .string(Self.timestamp(now))
    return fields
  }

  package var projection: JSONValue {
    .object(["schemaVersion": .string("arkdeck.control-action/1"), "controlActionId": .string(actionID),
      "actionRequestId": .string(intent.actionRequestID), "requestFingerprint": value["requestFingerprint"]!,
      "fingerprintAlgorithm": .string("sha256-jcs"), "kind": .string("hdcLifecycle"), "action": .string("restart"),
      "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
      "generation": .string(String(generation)), "state": .string(state), "catalogDigest": value["catalogDigest"]!,
      "createdAt": .string(createdAt), "expiresAt": .string(expiresAt), "lastObservedAt": .string(lastObservedAt),
      "preview": preview.map { .object($0.value) } ?? .null, "blockerReasonCode": value["blockerReasonCode"]!,
      "humanAction": humanAction?.projection ?? .null,
      "dispatchCount": .integer(lifecycleAudit.contains(where: { $0.kind == "launchWindowEntered" }) ? 1 : 0),
      "nextAction": .object(["kind": .string(state == "awaitingImpactApproval" ? "humanAction" : state == "previewReady" ? "inspectControlAction" : ["succeeded", "failed"].contains(state) ? "none" : "reconcile"),
        "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
        "resource": state == "awaitingImpactApproval"
          ? .object(["kind": .string("humanAction"), "id": humanAction!.value["actionId"]!])
          : .object(["kind": .string("controlAction"), "id": .string(actionID)]),
        "reasonCode": state == "awaitingImpactApproval" ? .string("policy.impactApprovalRequired")
          : state == "succeeded" ? .string("controlAction.completed")
          : state == "failed" ? .string("hdc.lifecycleFailedBeforeLaunch")
          : state == "outcomeUnknown" ? .string("hdc.lifecycleOutcomeUnknown")
          : value["blockerReasonCode"] == .null ? .string("controlAction.previewAvailable") : value["blockerReasonCode"]!])])
  }

  private static func state(
    afterAppending entry: HDCControlLifecycleAuditEntry,
    prior: [HDCControlLifecycleAuditEntry]
  ) -> String {
    switch entry.kind {
    case "impactPreview", "confirmation": return "approvalRecorded"
    case "intent", "actualCommand": return "dispatchPrepared"
    case "launchWindowEntered": return "dispatching"
    case "outcome":
      if case .object(let outcome)? = entry.payload["outcome"],
        outcome["result"] == .string("failed") { return "failed" }
      return "dispatching"
    case "reconciliation":
      guard case .object(let outward)? = entry.payload["outwardOutcome"],
        case .string(let result)? = outward["result"]
      else { return "outcomeUnknown" }
      return result == "succeeded" || result == "stopped" ? "succeeded" : "outcomeUnknown"
    default: return prior.isEmpty ? "approvalRecorded" : "outcomeUnknown"
    }
  }

  private static func validateLifecycleAudit(
    _ events: [HDCControlLifecycleAuditEntry],
    state: String,
    interactionReceipt: HDCControlInteractionReceipt?,
    preview: HDCControlActionPreview?,
    intent: HDCControlActionIntent
  ) throws {
    guard events.enumerated().allSatisfy({ $0.element.sequence == $0.offset + 1 }) else {
      throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle audit sequence is discontinuous")
    }
    if events.isEmpty {
      guard !["dispatchPrepared", "dispatching", "succeeded", "failed", "outcomeUnknown"].contains(state)
      else { throw HDCControlValue.failure("recordUnreadable", "advanced HDC action has no lifecycle audit") }
      return
    }
    guard interactionReceipt != nil, let preview,
      events.allSatisfy({ $0.auditID == events[0].auditID }),
      events[0].kind == "impactPreview"
    else { throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle audit lacks one approval owner") }
    let kinds = events.map(\.kind)
    let permitted: Bool = {
      if kinds == ["impactPreview"] || kinds == ["impactPreview", "confirmation"]
        || kinds == ["impactPreview", "confirmation", "intent"]
        || kinds == ["impactPreview", "confirmation", "intent", "actualCommand"]
      { return true }
      if kinds == ["impactPreview", "confirmation", "intent", "outcome"]
        || kinds == ["impactPreview", "confirmation", "intent", "actualCommand", "outcome"]
      {
        guard let last = events.last, case .object(let outcome)? = last.payload["outcome"] else {
          return false
        }
        return outcome["result"] == .string("failed")
      }
      if kinds == ["impactPreview", "confirmation", "intent", "actualCommand", "launchWindowEntered"]
        || kinds == ["impactPreview", "confirmation", "intent", "actualCommand", "launchWindowEntered", "outcome"]
      { return true }
      return kinds == ["impactPreview", "confirmation", "intent", "actualCommand", "launchWindowEntered", "outcome", "reconciliation"]
    }()
    guard permitted else {
      throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle audit order is invalid")
    }
    let first = events[0].payload
    guard first["action"] == .string("restartConfirmedGeneration"),
      first["generation"] == .integer(Int64(intent.expectedGeneration)),
      first["endpoint"] == preview.impact.value["endpoint"],
      first["ownership"] == preview.impact.value["serverOwnership"],
      first["affectedDeviceCoordinators"] == preview.impact.value["affectedTargetIds"],
      first["affectedJobs"] == preview.impact.value["affectedJobIds"]
    else { throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle preview differs from the approved control preview") }
    if events.count >= 2 {
      let confirmation = events[1].payload
      guard confirmation["previewId"] == first["previewId"],
        confirmation["action"] == first["action"], confirmation["endpoint"] == first["endpoint"],
        confirmation["generation"] == first["generation"],
        confirmation["ownership"] == first["ownership"],
        confirmation["scopeHash"] == first["scopeHash"]
      else { throw HDCControlValue.failure("recordUnreadable", "HDC confirmation differs from its lifecycle preview") }
    }
    if events.count >= 3 {
      let confirmation = events[1].payload, intentEvent = events[2].payload
      guard intentEvent["confirmationId"] == confirmation["confirmationId"],
        intentEvent["action"] == confirmation["action"],
        intentEvent["endpoint"] == confirmation["endpoint"],
        intentEvent["expectedGeneration"] == confirmation["generation"],
        intentEvent["expectedOwnership"] == confirmation["ownership"],
        intentEvent["impactSnapshotHash"] == confirmation["scopeHash"]
      else { throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle intent differs from its confirmation") }
      for event in events.dropFirst(3) {
        guard event.payload["stepId"] == intentEvent["stepId"] else {
          throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle event differs from its typed step")
        }
      }
    }
    let expectedState: String
    if let last = events.last, last.kind == "outcome",
      case .object(let outcome)? = last.payload["outcome"], outcome["result"] == .string("failed")
    { expectedState = "failed" }
    else { expectedState = Self.state(afterAppending: events.last!, prior: Array(events.dropLast())) }
    // A Runtime restart may invalidate an approved interaction only while the
    // accepted Supervisor chain still has no typed lifecycle intent. Keeping
    // those preview/confirmation entries proves that no dispatch was prepared;
    // discarding them would weaken the crash-boundary evidence.
    if ["expired", "previewDrifted"].contains(state),
      !kinds.contains("intent")
    { return }
    guard state == expectedState else {
      throw HDCControlValue.failure("recordUnreadable", "HDC control-action state differs from its durable lifecycle audit")
    }
  }

  package static func timestamp(_ value: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: value)
  }
}
