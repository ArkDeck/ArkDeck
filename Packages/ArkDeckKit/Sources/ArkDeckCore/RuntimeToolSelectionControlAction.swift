import Foundation

package struct RuntimeToolSelectionIntent: Equatable, Sendable {
  package let actionRequestID: String
  package let newToolRef: String
  package let expectedActiveGeneration: UInt64

  package init(_ fields: [String: JSONValue]) throws {
    guard Set(fields.keys) == ["actionRequestId", "tool", "expectedActiveGeneration"],
      case .string(let request)? = fields["actionRequestId"], HDCControlValue.identifier(request),
      case .string(let tool)? = fields["tool"], Self.toolReference(tool),
      case .string(let generation)? = fields["expectedActiveGeneration"],
      let parsed = HDCControlValue.generation(generation)
    else {
      throw HDCControlValue.failure(
        "invalidInput",
        "tool selection requires an exact tool, active generation and request identity")
    }
    actionRequestID = request
    newToolRef = tool
    expectedActiveGeneration = parsed
  }

  package var request: [String: JSONValue] {
    [
      "actionRequestId": .string(actionRequestID), "tool": .string(newToolRef),
      "expectedActiveGeneration": .string(String(expectedActiveGeneration)),
    ]
  }

  package var canonicalIntent: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.tool-selection-intent/1"),
      "kind": .string("runtimeToolSelection"), "newToolRef": .string(newToolRef),
      "expectedActiveGeneration": .string(String(expectedActiveGeneration)),
    ])
  }

  package var fingerprint: String { get throws { try HDCControlValue.hash(canonicalIntent) } }

  package static func toolReference(_ value: String) -> Bool {
    value.hasPrefix("tool:sha256:")
      && HDCControlValue.digest(String(value.dropFirst("tool:sha256:".count)))
  }
}

package struct RuntimeToolSelectionToolFacts: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let toolRef: String

  /// Converts the bootstrap registry projection into the path-free immutable
  /// facts that enter the reviewed preview digest.
  package init(registryProjection source: JSONValue) throws {
    guard case .object(let tool) = source,
      tool["schemaVersion"] == .string("arkdeck.runtime-tool/1"),
      case .string(let reference)? = tool["toolRef"],
      RuntimeToolSelectionIntent.toolReference(reference),
      tool["kind"] == .string("hdc"), tool["platform"] == .string("macos"),
      case .string(let generation)? = tool["generation"],
      HDCControlValue.generation(generation) != nil,
      case .string(let content)? = tool["contentDigest"], HDCControlValue.digest(content),
      case .string(let executable)? = tool["executableSHA256"], HDCControlValue.digest(executable),
      case .object(let trust)? = tool["trust"],
      trust["registeredIdentity"] == .bool(true),
      case .string(let signature)? = trust["signature"],
      ["unsigned", "adHoc", "verified"].contains(signature),
      trust["policy"] == .string("arkdeck.host-tool-inspection/1"),
      case .string(let version)? = trust["toolVersion"],
      HDCControlValue.optionalText(.string(version), maximumBytes: 128),
      case .array(let profiles)? = trust["profileReferences"], profiles.count <= 32,
      profiles.allSatisfy({
        if case .string(let value) = $0 { return HDCControlValue.identifier(value) }
        return false
      })
    else {
      throw HDCControlValue.failure(
        "operationUnavailable",
        "registered candidate lacks a published HDC identity and bounded trust facts")
    }
    func optional(_ key: String) -> JSONValue {
      guard let value = trust[key] else { return .null }
      if value == .null { return .null }
      guard HDCControlValue.optionalText(value, maximumBytes: 256) else { return .null }
      return value
    }
    let profileValues = profiles.sorted { lhs, rhs in
      guard case .string(let a) = lhs, case .string(let b) = rhs else { return false }
      return a.utf8.lexicographicallyPrecedes(b.utf8)
    }
    let profileTexts = profiles.compactMap {
      if case .string(let value) = $0 { return value }
      return nil
    }
    guard profiles == profileValues, Set(profileTexts).count == profiles.count else {
      throw HDCControlValue.failure(
        "recordUnreadable", "published HDC profile references are not canonical")
    }
    toolRef = reference
    value = [
      "toolRef": .string(reference), "recordGeneration": .string(generation),
      "contentSHA256": .string(content), "executableSHA256": .string(executable),
      "signature": .object([
        "state": .string(signature), "identifier": optional("signingIdentifier"),
        "teamIdentifier": optional("teamIdentifier"),
        "codeDirectoryIdentitySHA256": trust["codeDirectoryIdentitySHA256"] ?? .null,
      ]),
      "version": .string(version),
      "trust": .object([
        "policy": .string("arkdeck.host-tool-inspection/1"), "registeredIdentity": .bool(true),
        "platformTrust": trust["platformTrust"] ?? .string("unverified"),
        "executionAssessment": trust["executionAssessment"] ?? .string("notPerformed"),
        "profileReferences": .array(profileValues),
      ]),
    ]
    try Self.validate(value)
  }

  package init(value: [String: JSONValue]) throws {
    try Self.validate(value)
    guard case .string(let reference)? = value["toolRef"] else {
      throw HDCControlValue.failure("recordUnreadable", "tool facts have no reference")
    }
    self.value = value
    toolRef = reference
  }

  private static func validate(_ value: [String: JSONValue]) throws {
    guard
      Set(value.keys) == [
        "toolRef", "recordGeneration", "contentSHA256", "executableSHA256", "signature", "version",
        "trust",
      ],
      case .string(let reference)? = value["toolRef"],
      RuntimeToolSelectionIntent.toolReference(reference),
      case .string(let generation)? = value["recordGeneration"],
      HDCControlValue.generation(generation) != nil,
      case .string(let content)? = value["contentSHA256"], HDCControlValue.digest(content),
      case .string(let executable)? = value["executableSHA256"], HDCControlValue.digest(executable),
      HDCControlValue.optionalText(value["version"], maximumBytes: 128),
      case .object(let signature)? = value["signature"],
      Set(signature.keys) == [
        "state", "identifier", "teamIdentifier", "codeDirectoryIdentitySHA256",
      ],
      HDCControlValue.oneOf(signature["state"], ["unsigned", "adHoc", "verified"]),
      HDCControlValue.optionalText(signature["identifier"], maximumBytes: 256),
      HDCControlValue.optionalText(signature["teamIdentifier"], maximumBytes: 256),
      HDCControlValue.optionalDigest(signature["codeDirectoryIdentitySHA256"]),
      case .object(let trust)? = value["trust"],
      Set(trust.keys) == [
        "policy", "registeredIdentity", "platformTrust", "executionAssessment", "profileReferences",
      ],
      trust["policy"] == .string("arkdeck.host-tool-inspection/1"),
      trust["registeredIdentity"] == .bool(true), trust["platformTrust"] == .string("unverified"),
      trust["executionAssessment"] == .string("notPerformed"),
      case .array(let profiles)? = trust["profileReferences"], profiles.count <= 32,
      profiles.allSatisfy({
        if case .string(let item) = $0 { return HDCControlValue.identifier(item) }
        return false
      })
    else { throw HDCControlValue.failure("recordUnreadable", "tool selection facts are malformed") }
  }
}

package struct RuntimeToolSelectionImpact: Equatable, Sendable {
  package let hdc: HDCControlImpact
  package let oldTool: RuntimeToolSelectionToolFacts
  package let newTool: RuntimeToolSelectionToolFacts
  package let activeGeneration: UInt64

  package init(
    hdc: HDCControlImpact, oldTool: RuntimeToolSelectionToolFacts,
    newTool: RuntimeToolSelectionToolFacts, activeGeneration: UInt64
  ) throws {
    guard activeGeneration > 0, oldTool.toolRef != newTool.toolRef,
      case .object(let runningTool)? = hdc.value["tool"],
      runningTool["sha256"] == oldTool.value["executableSHA256"]
    else {
      throw HDCControlValue.failure(
        "factsDrifted", "active selection does not match the managed HDC executable")
    }
    self.hdc = hdc
    self.oldTool = oldTool
    self.newTool = newTool
    self.activeGeneration = activeGeneration
  }

  package var value: [String: JSONValue] {
    var fields = hdc.value
    fields["oldTool"] = .object(oldTool.value)
    fields["newTool"] = .object(newTool.value)
    fields["expectedActiveGeneration"] = .string(String(activeGeneration))
    return fields
  }
}

package struct RuntimeToolSelectionPreview: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let impact: RuntimeToolSelectionImpact

  package init(
    actionID: String, previewID: String, createdAt: String, expiresAt: String,
    impact: RuntimeToolSelectionImpact
  ) throws {
    var fields = impact.value
    fields.merge(
      [
        "schemaVersion": .string("arkdeck.tool-selection-preview/1"),
        "controlActionId": .string(actionID), "previewId": .string(previewID),
        "kind": .string("runtimeToolSelection"), "action": .string("select"),
        "createdAt": .string(createdAt), "expiresAt": .string(expiresAt),
        "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
        "confirmationRequired": .bool(true), "dispatchCount": .integer(0),
        "digestAlgorithm": .string("sha256-jcs"),
      ], uniquingKeysWith: { _, new in new })
    fields["previewDigest"] = .string(try HDCControlValue.hash(.object(fields)))
    try self.init(value: fields)
  }

  package init(value: [String: JSONValue]) throws {
    let metadata: Set<String> = [
      "schemaVersion", "controlActionId", "previewId", "kind", "action", "createdAt", "expiresAt",
      "owner", "confirmationRequired", "dispatchCount", "digestAlgorithm", "previewDigest",
    ]
    guard value["schemaVersion"] == .string("arkdeck.tool-selection-preview/1"),
      value["kind"] == .string("runtimeToolSelection"), value["action"] == .string("select"),
      value["confirmationRequired"] == .bool(true), value["dispatchCount"] == .integer(0),
      value["digestAlgorithm"] == .string("sha256-jcs"),
      case .string(let actionID)? = value["controlActionId"], HDCControlValue.identifier(actionID),
      case .string(let previewID)? = value["previewId"], HDCControlValue.identifier(previewID),
      case .string(let created)? = value["createdAt"], let start = HDCControlValue.time(created),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires),
      end > start,
      value["owner"] == .object(["kind": .string("controlAction"), "id": .string(actionID)]),
      case .string(let digest)? = value["previewDigest"], HDCControlValue.digest(digest),
      try digest == HDCControlValue.hash(.object(value.filter { $0.key != "previewDigest" })),
      case .object(let old)? = value["oldTool"], case .object(let new)? = value["newTool"],
      case .string(let generation)? = value["expectedActiveGeneration"],
      let activeGeneration = HDCControlValue.generation(generation)
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "tool-selection preview failed identity or digest validation")
    }
    let hdcFields = value.filter {
      !metadata.contains($0.key)
        && !["oldTool", "newTool", "expectedActiveGeneration"].contains($0.key)
    }
    let hdc = try HDCControlImpact(hdcFields)
    let impact = try RuntimeToolSelectionImpact(
      hdc: hdc, oldTool: RuntimeToolSelectionToolFacts(value: old),
      newTool: RuntimeToolSelectionToolFacts(value: new), activeGeneration: activeGeneration)
    let storedImpact = value.filter { !metadata.contains($0.key) }
    guard impact.value == storedImpact else {
      throw HDCControlValue.failure(
        "recordUnreadable", "stored tool-selection impact is not canonical")
    }
    self.value = value
    self.impact = impact
  }
}

package struct RuntimeToolSelectionControlActionRecord: Equatable, Sendable {
  package let value: [String: JSONValue]
  package let intent: RuntimeToolSelectionIntent
  package let preview: RuntimeToolSelectionPreview?
  package let humanAction: HDCControlHumanAction?
  package let interactionChallenge: HDCControlInteractionChallenge?
  package let interactionReceipt: HDCControlInteractionReceipt?
  package let generation: UInt64
  package let actionID: String
  package let state: String
  package let runtimeEpoch: String
  package let createdAt: String
  package let expiresAt: String
  package let lastObservedAt: String

  package init(
    intent: RuntimeToolSelectionIntent, catalogDigest: String,
    runtimeEpoch: String, now: Date
  ) throws {
    let created = Self.timestamp(now)
    guard let start = HDCControlValue.time(created) else {
      throw HDCControlValue.failure(
        "recordUnreadable", "tool-selection action requires a representable creation time")
    }
    try self.init(value: [
      "schemaVersion": .string("arkdeck.runtime-tool-selection-control-action/1"),
      "controlActionId": .string("control-action-" + UUID().uuidString.lowercased()),
      "actionRequestId": .string(intent.actionRequestID),
      "requestFingerprint": .string(try intent.fingerprint),
      "intent": .object(intent.request), "catalogDigest": .string(catalogDigest),
      "runtimeEpoch": .string(runtimeEpoch), "generation": .string("1"),
      "state": .string("observing"), "createdAt": .string(created),
      "expiresAt": .string(Self.timestamp(start.addingTimeInterval(300))),
      "lastObservedAt": .string(created), "preview": .null,
      "observationRelations": .array([]),
      "blockerReasonCode": .null, "humanAction": .null,
      "interactionChallenge": .null, "interactionReceipt": .null,
      "dispatchCount": .integer(0), "selectionAudit": .array([]),
    ])
  }

  package init(value: [String: JSONValue]) throws {
    let keys: Set<String> = [
      "schemaVersion", "controlActionId", "actionRequestId", "requestFingerprint", "intent",
      "catalogDigest", "runtimeEpoch", "generation", "state", "createdAt", "expiresAt",
      "lastObservedAt", "preview", "observationRelations", "blockerReasonCode", "humanAction",
      "interactionChallenge", "interactionReceipt", "dispatchCount", "selectionAudit",
    ]
    guard Set(value.keys) == keys,
      value["schemaVersion"] == .string("arkdeck.runtime-tool-selection-control-action/1"),
      case .string(let id)? = value["controlActionId"], HDCControlValue.identifier(id),
      case .object(let intentFields)? = value["intent"],
      let intent = try? RuntimeToolSelectionIntent(intentFields),
      value["actionRequestId"] == .string(intent.actionRequestID),
      case .string(let fingerprint)? = value["requestFingerprint"],
      HDCControlValue.digest(fingerprint),
      try fingerprint == intent.fingerprint,
      case .string(let catalog)? = value["catalogDigest"], HDCControlValue.digest(catalog),
      case .string(let epoch)? = value["runtimeEpoch"], HDCControlValue.identifier(epoch),
      case .string(let generationText)? = value["generation"],
      let generation = HDCControlValue.generation(generationText),
      case .string(let state)? = value["state"], Self.states.contains(state),
      case .string(let created)? = value["createdAt"], let start = HDCControlValue.time(created),
      case .string(let expires)? = value["expiresAt"], let end = HDCControlValue.time(expires),
      end.timeIntervalSince(start) == 300,
      case .string(let observed)? = value["lastObservedAt"],
      let latest = HDCControlValue.time(observed), latest >= start,
      HDCControlValue.optionalIdentifier(value["blockerReasonCode"]),
      case .array(let relations)? = value["observationRelations"], relations.count <= 256,
      case .integer(let dispatchCount)? = value["dispatchCount"], (0...1).contains(dispatchCount),
      case .array(let audit)? = value["selectionAudit"], audit.count <= 16,
      audit.allSatisfy({
        if case .object = $0 { return true }
        return false
      })
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "tool-selection control action is malformed")
    }
    let preview = try Self.optionalObject(
      value["preview"], RuntimeToolSelectionPreview.init(value:))
    let human = try Self.optionalObject(value["humanAction"], HDCControlHumanAction.init(value:))
    let challenge = try Self.optionalObject(
      value["interactionChallenge"], HDCControlInteractionChallenge.init(value:))
    let receipt = try Self.optionalObject(
      value["interactionReceipt"], HDCControlInteractionReceipt.init(value:))
    guard preview.map({ $0.value["controlActionId"] == .string(id) }) ?? true,
      human.map({ $0.value["controlActionId"] == .string(id) }) ?? true,
      challenge.map({ $0.value["controlActionId"] == .string(id) }) ?? true,
      receipt.map({ $0.value["controlActionId"] == .string(id) }) ?? true,
      state == "failed" || (dispatchCount == 1) == ["outcomeUnknown", "succeeded"].contains(state),
      ![
        "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared", "outcomeUnknown",
        "succeeded", "failed",
      ].contains(state) || human != nil,
      !["observing", "previewReady", "blocked"].contains(state) || human == nil,
      (receipt != nil)
        == ["approvalRecorded", "dispatchPrepared", "outcomeUnknown", "succeeded", "failed"]
        .contains(state)
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "tool-selection owner bindings contradict its state")
    }
    self.value = value
    self.intent = intent
    self.preview = preview
    humanAction = human
    interactionChallenge = challenge
    interactionReceipt = receipt
    self.generation = generation
    actionID = id
    self.state = state
    runtimeEpoch = epoch
    createdAt = created
    expiresAt = expires
    lastObservedAt = observed
  }

  package func publishing(
    impact: RuntimeToolSelectionImpact, relations: [JSONValue],
    blocker: String?, now: Date
  ) throws -> Self {
    guard state == "observing" else { return self }
    var fields = try advanced(now: now)
    let preview = try RuntimeToolSelectionPreview(
      actionID: actionID, previewID: "preview-" + UUID().uuidString.lowercased(),
      createdAt: Self.timestamp(now), expiresAt: expiresAt, impact: impact)
    fields["preview"] = .object(preview.value)
    fields["observationRelations"] = .array(relations)
    fields["blockerReasonCode"] = blocker.map(JSONValue.string) ?? .null
    fields["state"] = .string(blocker == nil ? "previewReady" : "blocked")
    return try Self(value: fields)
  }

  package func requestingImpactApproval(now: Date) throws -> Self {
    guard state == "previewReady", let preview else {
      throw HDCControlValue.failure(
        "admissionDenied", "tool selection is not eligible for impact approval")
    }
    var fields = try advanced(now: now)
    let action = try HDCControlHumanAction(
      controlActionID: actionID, preview: preview.value, generation: generation + 1,
      createdAt: Self.timestamp(now), expiresAt: expiresAt)
    fields["state"] = .string("awaitingImpactApproval")
    fields["humanAction"] = .object(action.value)
    return try Self(value: fields)
  }

  package func issuingInteractiveChallenge(challenge: String, now: Date) throws -> Self {
    guard state == "awaitingImpactApproval", let humanAction,
      interactionChallenge == nil, interactionReceipt == nil,
      let recordExpiry = HDCControlValue.time(expiresAt)
    else {
      throw HDCControlValue.failure(
        "humanActionExpired", "tool-selection approval is no longer waiting")
    }
    var fields = try advanced(now: now)
    let issued = Self.timestamp(now)
    let challengeExpiry = min(recordExpiry, now.addingTimeInterval(120))
    let challenge = try HDCControlInteractionChallenge(
      controlActionID: actionID, humanAction: humanAction, challenge: challenge,
      issuedAt: issued, expiresAt: Self.timestamp(challengeExpiry))
    fields["interactionChallenge"] = .object(challenge.value)
    return try Self(value: fields)
  }

  package func recordingInteractiveApproval(response: String, now: Date) throws -> Self {
    guard state == "awaitingImpactApproval", let humanAction, let interactionChallenge,
      case .string(let expiryText)? = interactionChallenge.value["expiresAt"],
      let expiry = HDCControlValue.time(expiryText), now < expiry
    else {
      throw HDCControlValue.failure(
        "impactApprovalChallengeExpired", "tool-selection challenge expired")
    }
    var fields = try advanced(now: now)
    let resolved = try humanAction.resolving()
    let receipt = try HDCControlInteractionReceipt(
      controlActionID: actionID, humanAction: humanAction, challenge: interactionChallenge,
      response: response, confirmedAt: Self.timestamp(now))
    fields["state"] = .string("approvalRecorded")
    fields["humanAction"] = .object(resolved.value)
    fields["interactionReceipt"] = .object(receipt.value)
    return try Self(value: fields)
  }

  package func prepared(now: Date) throws -> Self {
    guard state == "approvalRecorded", let preview else {
      throw HDCControlValue.failure("recordUnreadable", "tool selection lacks an approved preview")
    }
    var fields = try advanced(now: now)
    fields["state"] = .string("dispatchPrepared")
    fields["selectionAudit"] = .array([
      .object([
        "kind": .string("selectionPrepared"), "recordedAt": .string(Self.timestamp(now)),
        "oldToolRef": .string(preview.impact.oldTool.toolRef),
        "newToolRef": .string(preview.impact.newTool.toolRef),
        "activeGeneration": .string(String(preview.impact.activeGeneration)),
      ])
    ])
    return try Self(value: fields)
  }

  package func launchWindowEntered(now: Date) throws -> Self {
    guard state == "dispatchPrepared", case .array(var audit)? = value["selectionAudit"] else {
      throw HDCControlValue.failure("recordUnreadable", "tool selection is not dispatch prepared")
    }
    var fields = try advanced(now: now)
    audit.append(
      .object([
        "kind": .string("launchWindowEntered"), "recordedAt": .string(Self.timestamp(now)),
        "typedStep": .string("mutateHDCServerLifecycle"),
        "action": .string("restartConfirmedGeneration"),
      ]))
    fields["selectionAudit"] = .array(audit)
    fields["state"] = .string("outcomeUnknown")
    fields["dispatchCount"] = .integer(1)
    return try Self(value: fields)
  }

  package func appendingLifecycleAudit(
    kind: String, auditID: UUID, payload: [String: JSONValue], now: Date
  ) throws -> Self {
    guard ["dispatchPrepared", "outcomeUnknown"].contains(state),
      [
        "impactPreview", "confirmation", "intent", "actualCommand", "launchWindowEntered",
        "outcome", "reconciliation",
      ].contains(kind),
      case .array(var audit)? = value["selectionAudit"], audit.count < 16
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "invalid tool-selection lifecycle audit transition")
    }
    if kind == "launchWindowEntered" {
      guard state == "dispatchPrepared",
        !audit.contains(where: {
          if case .object(let row) = $0 { return row["kind"] == .string("launchWindowEntered") }
          return false
        })
      else {
        throw HDCControlValue.failure(
          "recordUnreadable", "tool-selection launch window was already entered")
      }
    }
    var fields = try advanced(now: now)
    audit.append(
      .object([
        "kind": .string(kind), "auditId": .string(auditID.uuidString.lowercased()),
        "recordedAt": .string(Self.timestamp(now)), "payload": .object(payload),
      ]))
    fields["selectionAudit"] = .array(audit)
    if kind == "launchWindowEntered" {
      fields["state"] = .string("outcomeUnknown")
      fields["dispatchCount"] = .integer(1)
    }
    return try Self(value: fields)
  }

  package func failedBeforeLaunch(reasonCode: String, now: Date) throws -> Self {
    guard ["approvalRecorded", "dispatchPrepared"].contains(state),
      HDCControlValue.identifier(reasonCode),
      case .array(var audit)? = value["selectionAudit"]
    else {
      throw HDCControlValue.failure("recordUnreadable", "invalid pre-launch tool-selection failure")
    }
    var fields = try advanced(now: now)
    audit.append(
      .object([
        "kind": .string("selectionOutcome"), "recordedAt": .string(Self.timestamp(now)),
        "result": .string("failed"), "reasonCode": .string(reasonCode),
      ]))
    fields["selectionAudit"] = .array(audit)
    fields["state"] = .string("failed")
    fields["blockerReasonCode"] = .string(reasonCode)
    fields["dispatchCount"] = .integer(0)
    return try Self(value: fields)
  }

  package func settled(
    result: String, activeToolRef: String, activeGeneration: UInt64,
    reasonCode: String?, now: Date
  ) throws -> Self {
    guard state == "outcomeUnknown", ["succeeded", "failed"].contains(result),
      RuntimeToolSelectionIntent.toolReference(activeToolRef), activeGeneration > 0,
      reasonCode.map(HDCControlValue.identifier) ?? true,
      case .array(var audit)? = value["selectionAudit"]
    else { throw HDCControlValue.failure("recordUnreadable", "invalid tool-selection settlement") }
    var fields = try advanced(now: now)
    audit.append(
      .object([
        "kind": .string("selectionOutcome"), "recordedAt": .string(Self.timestamp(now)),
        "result": .string(result), "activeToolRef": .string(activeToolRef),
        "activeGeneration": .string(String(activeGeneration)),
        "reasonCode": reasonCode.map(JSONValue.string) ?? .null,
      ]))
    fields["selectionAudit"] = .array(audit)
    fields["state"] = .string(result)
    fields["blockerReasonCode"] = reasonCode.map(JSONValue.string) ?? .null
    return try Self(value: fields)
  }

  package func invalidated(reason: String, expired: Bool, now: Date) throws -> Self {
    var fields = try advanced(now: now)
    fields["state"] = .string(expired ? "expired" : "previewDrifted")
    fields["blockerReasonCode"] = .string(reason)
    if let humanAction { fields["humanAction"] = .object(try humanAction.expiring().value) }
    fields["interactionChallenge"] = .null
    return try Self(value: fields)
  }

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.control-action/1"),
      "controlActionId": .string(actionID), "actionRequestId": .string(intent.actionRequestID),
      "requestFingerprint": value["requestFingerprint"]!,
      "fingerprintAlgorithm": .string("sha256-jcs"),
      "kind": .string("runtimeToolSelection"), "action": .string("select"),
      "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
      "generation": .string(String(generation)), "state": .string(state),
      "catalogDigest": value["catalogDigest"]!, "createdAt": .string(createdAt),
      "expiresAt": .string(expiresAt), "lastObservedAt": .string(lastObservedAt),
      "preview": preview.map { .object($0.value) } ?? .null,
      "blockerReasonCode": value["blockerReasonCode"]!,
      "humanAction": humanAction?.projection ?? .null,
      "dispatchCount": value["dispatchCount"]!,
      "nextAction": .object([
        "kind": .string(
          state == "awaitingImpactApproval"
            ? "humanAction" : ["succeeded", "failed"].contains(state) ? "none" : "reconcile"),
        "owner": .object(["kind": .string("controlAction"), "id": .string(actionID)]),
        "resource": state == "awaitingImpactApproval"
          ? .object(["kind": .string("humanAction"), "id": humanAction!.value["actionId"]!])
          : .object(["kind": .string("controlAction"), "id": .string(actionID)]),
        "reasonCode": state == "awaitingImpactApproval"
          ? .string("policy.impactApprovalRequired")
          : state == "succeeded"
            ? .string("controlAction.completed")
            : state == "failed"
              ? value["blockerReasonCode"]!
              : state == "outcomeUnknown"
                ? .string("tool.selectionRecomposePending")
                : value["blockerReasonCode"] == .null
                  ? .string("controlAction.previewAvailable") : value["blockerReasonCode"]!,
      ]),
    ])
  }

  package static func timestamp(_ date: Date) -> String { HDCControlActionRecord.timestamp(date) }

  private func advanced(now: Date) throws -> [String: JSONValue] {
    guard generation < UInt64.max, let previous = HDCControlValue.time(lastObservedAt),
      now >= previous
    else {
      throw HDCControlValue.failure(
        "orchestrationClockUntrusted", "tool-selection clock moved backwards")
    }
    var fields = value
    fields["generation"] = .string(String(generation + 1))
    fields["lastObservedAt"] = .string(Self.timestamp(now))
    return fields
  }

  private static let states: Set<String> = [
    "observing", "previewReady", "awaitingImpactApproval", "approvalRecorded", "dispatchPrepared",
    "outcomeUnknown", "succeeded", "failed", "blocked", "expired", "previewDrifted",
  ]

  private static func optionalObject<T>(
    _ value: JSONValue?, _ decode: ([String: JSONValue]) throws -> T
  ) throws -> T? {
    if value == .null { return nil }
    guard case .object(let fields)? = value else {
      throw HDCControlValue.failure("recordUnreadable", "tool-selection nested record is malformed")
    }
    return try decode(fields)
  }
}
