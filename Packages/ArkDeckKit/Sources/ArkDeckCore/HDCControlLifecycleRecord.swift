import Foundation

/// Durable proof that a person typed the Runtime-issued one-time challenge in
/// the same foreground console session. The plaintext is deliberately absent:
/// the record retains only the already-persisted challenge hash and its exact
/// owner/preview binding.
package struct HDCControlInteractionReceipt: Equatable, Sendable {
  package let value: [String: JSONValue]

  package init(
    controlActionID: String,
    humanAction: HDCControlHumanAction,
    challenge: HDCControlInteractionChallenge,
    response: String,
    confirmedAt: String
  ) throws {
    guard case .string(let challengeHash)? = challenge.value["challengeSha256"],
      SHA256Hex.string(of: Data(response.utf8)) == challengeHash
    else {
      throw HDCControlValue.failure(
        "impactApprovalChallengeMismatch", "the one-time impact challenge did not match")
    }
    try self.init(value: [
      "receiptId": .string("interaction-" + UUID().uuidString.lowercased()),
      "interactionOrigin": .string("interactiveConsole"),
      "controlActionId": .string(controlActionID),
      "humanActionId": .string(humanAction.actionID),
      "challengeId": challenge.value["challengeId"]!,
      "challengeSha256": .string(challengeHash),
      "previewId": humanAction.value["previewId"]!,
      "previewDigest": humanAction.value["previewDigest"]!,
      "controlActionGeneration": humanAction.value["controlActionGeneration"]!,
      "confirmedAt": .string(confirmedAt),
    ])
  }

  package init(value: [String: JSONValue]) throws {
    guard Set(value.keys) == [
      "receiptId", "interactionOrigin", "controlActionId", "humanActionId", "challengeId",
      "challengeSha256", "previewId", "previewDigest", "controlActionGeneration", "confirmedAt",
    ],
      case .string(let receipt)? = value["receiptId"], HDCControlValue.identifier(receipt),
      value["interactionOrigin"] == .string("interactiveConsole"),
      case .string(let owner)? = value["controlActionId"], HDCControlValue.identifier(owner),
      case .string(let action)? = value["humanActionId"], HDCControlValue.identifier(action),
      case .string(let challenge)? = value["challengeId"], HDCControlValue.identifier(challenge),
      case .string(let challengeHash)? = value["challengeSha256"],
      HDCControlValue.digest(challengeHash),
      case .string(let preview)? = value["previewId"], HDCControlValue.identifier(preview),
      case .string(let previewDigest)? = value["previewDigest"],
      HDCControlValue.digest(previewDigest),
      case .string(let generation)? = value["controlActionGeneration"],
      HDCControlValue.generation(generation) != nil,
      case .string(let confirmed)? = value["confirmedAt"], HDCControlValue.time(confirmed) != nil
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "control-action interaction receipt is malformed")
    }
    self.value = value
  }
}

/// One append-only entry from the accepted HDC Supervisor/executor chain.
/// Core validates the closed event vocabulary while Workflows translates the
/// native typed values. No caller-facing RPC accepts this representation.
package struct HDCControlLifecycleAuditEntry: Equatable, Sendable {
  package static let orderedKinds = [
    "impactPreview", "confirmation", "intent", "actualCommand",
    "launchWindowEntered", "outcome", "reconciliation",
  ]

  package let value: [String: JSONValue]
  package let kind: String
  package let auditID: String
  package let payload: [String: JSONValue]
  package let sequence: Int

  package init(
    kind: String,
    auditID: UUID,
    payload: [String: JSONValue],
    sequence: Int,
    recordedAt: String
  ) throws {
    try self.init(value: [
      "eventId": .string("lifecycle-event-" + UUID().uuidString.lowercased()),
      "sequence": .integer(Int64(sequence)),
      "kind": .string(kind),
      "auditId": .string(auditID.uuidString.lowercased()),
      "recordedAt": .string(recordedAt),
      "payload": .object(payload),
    ])
  }

  package init(value: [String: JSONValue]) throws {
    guard Set(value.keys) == [
      "eventId", "sequence", "kind", "auditId", "recordedAt", "payload",
    ],
      case .string(let eventID)? = value["eventId"], HDCControlValue.identifier(eventID),
      case .integer(let rawSequence)? = value["sequence"],
      let sequence = Int(exactly: rawSequence), (1...16).contains(sequence),
      case .string(let kind)? = value["kind"], Self.orderedKinds.contains(kind),
      case .string(let auditID)? = value["auditId"],
      UUID(uuidString: auditID)?.uuidString.lowercased() == auditID,
      case .string(let recordedAt)? = value["recordedAt"],
      HDCControlValue.time(recordedAt) != nil,
      case .object(let payload)? = value["payload"]
    else {
      throw HDCControlValue.failure("recordUnreadable", "HDC lifecycle audit entry is malformed")
    }
    try Self.validate(kind: kind, payload: payload)
    self.value = value
    self.kind = kind
    self.auditID = auditID
    self.payload = payload
    self.sequence = sequence
  }

  private static func validate(kind: String, payload: [String: JSONValue]) throws {
    func exact(_ keys: Set<String>) throws {
      guard Set(payload.keys) == keys else { throw malformed() }
    }
    func identifier(_ key: String) -> String? {
      guard case .string(let value)? = payload[key], HDCControlValue.identifier(value) else {
        return nil
      }
      return value
    }
    func uuid(_ key: String) -> String? {
      guard case .string(let value)? = payload[key],
        UUID(uuidString: value)?.uuidString.lowercased() == value
      else { return nil }
      return value
    }
    func text(_ key: String, maximumBytes: Int = 4096) -> String? {
      guard case .string(let value)? = payload[key], !value.isEmpty,
        value.utf8.count <= maximumBytes,
        value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
      else { return nil }
      return value
    }
    func generation(_ key: String) -> Int? {
      guard case .integer(let value)? = payload[key], let exact = Int(exactly: value), exact > 0
      else { return nil }
      return exact
    }
    func digest(_ key: String) -> String? {
      guard case .string(let value)? = payload[key], HDCControlValue.digest(value) else {
        return nil
      }
      return value
    }
    func stringArray(_ key: String) -> [String]? {
      guard case .array(let values)? = payload[key], values.count <= 4096 else { return nil }
      let strings = values.compactMap { value -> String? in
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 1024,
          text.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { return nil }
        return text
      }
      guard strings.count == values.count, Set(strings).count == strings.count,
        strings == strings.sorted()
      else { return nil }
      return strings
    }
    func outcome(_ key: String) -> [String: JSONValue]? {
      guard case .object(let fields)? = payload[key],
        Set(fields.keys) == ["result", "resultingGeneration", "reason"],
        case .string(let result)? = fields["result"],
        ["succeeded", "stopped", "failed", "outcomeUnknown"].contains(result)
      else { return nil }
      switch result {
      case "succeeded":
        guard case .integer(let value)? = fields["resultingGeneration"], value > 0,
          fields["reason"] == .null else { return nil }
      case "stopped":
        guard fields["resultingGeneration"] == .null, fields["reason"] == .null else {
          return nil
        }
      default:
        guard fields["resultingGeneration"] == .null,
          case .string(let reason)? = fields["reason"], !reason.isEmpty,
          reason.utf8.count <= 4096 else { return nil }
      }
      return fields
    }

    switch kind {
    case "impactPreview":
      try exact([
        "previewId", "action", "endpoint", "generation", "ownership", "scopeHash",
        "affectedDeviceCoordinators", "affectedJobs", "otherClientDetection",
        "expectedInterruption", "recoveryPath",
      ])
      guard uuid("previewId") != nil,
        payload["action"] == .string("restartConfirmedGeneration"),
        text("endpoint", maximumBytes: 256) != nil, generation("generation") != nil,
        case .string(let ownership)? = payload["ownership"],
        ["arkDeckManaged", "external", "unknown"].contains(ownership),
        digest("scopeHash") != nil,
        stringArray("affectedDeviceCoordinators") != nil,
        stringArray("affectedJobs") != nil,
        case .object(let clients)? = payload["otherClientDetection"],
        Set(clients.keys) == ["kind", "clients"],
        case .string(let clientKind)? = clients["kind"],
        ["detected", "noneDetectedExternalClientsMayStillExist",
          "unavailableExternalClientsMayStillExist"].contains(clientKind),
        case .array(let clientValues)? = clients["clients"], clientValues.count <= 4096,
        clientValues.allSatisfy({ if case .string(let value) = $0 { return !value.isEmpty && value.utf8.count <= 1024 }; return false }),
        (clientKind == "detected") == !clientValues.isEmpty,
        text("expectedInterruption") != nil, text("recoveryPath") != nil
      else { throw malformed() }
    case "confirmation":
      try exact([
        "confirmationId", "previewId", "action", "endpoint", "generation", "ownership",
        "scopeHash",
      ])
      guard uuid("confirmationId") != nil, uuid("previewId") != nil,
        payload["action"] == .string("restartConfirmedGeneration"),
        text("endpoint", maximumBytes: 256) != nil, generation("generation") != nil,
        case .string(let ownership)? = payload["ownership"],
        ["arkDeckManaged", "external", "unknown"].contains(ownership),
        digest("scopeHash") != nil else { throw malformed() }
    case "intent":
      try exact([
        "stepId", "confirmationId", "action", "endpoint", "expectedGeneration",
        "expectedOwnership", "impactSnapshotHash",
      ])
      guard uuid("stepId") != nil, uuid("confirmationId") != nil,
        payload["action"] == .string("restartConfirmedGeneration"),
        text("endpoint", maximumBytes: 256) != nil, generation("expectedGeneration") != nil,
        case .string(let ownership)? = payload["expectedOwnership"],
        ["arkDeckManaged", "external", "unknown"].contains(ownership),
        digest("impactSnapshotHash") != nil else { throw malformed() }
    case "actualCommand":
      try exact(["stepId", "executable", "argv", "endpoint"])
      guard uuid("stepId") != nil,
        case .string(let executable)? = payload["executable"], executable.hasPrefix("/"),
        executable.utf8.count <= 4096,
        case .string(let endpoint)? = payload["endpoint"], !endpoint.isEmpty,
        payload["argv"] == .array([
          .string("-s"), .string(endpoint), .string("kill"), .string("-r"),
        ]) else { throw malformed() }
    case "launchWindowEntered":
      try exact([
        "stepId", "executable", "argv", "endpoint", "authorizedExecutable",
        "inodeLaunchPath", "executableDevice", "executableInode", "executableFileSize",
        "executableMode", "executableSha256",
      ])
      guard uuid("stepId") != nil,
        case .string(let executable)? = payload["executable"], executable.hasPrefix("/"),
        payload["authorizedExecutable"] == .string(executable),
        case .string(let endpoint)? = payload["endpoint"], !endpoint.isEmpty,
        payload["argv"] == .array([
          .string("-s"), .string(endpoint), .string("kill"), .string("-r"),
        ]),
        case .string(let inodePath)? = payload["inodeLaunchPath"], inodePath.hasPrefix("/.vol/"),
        case .string(let device)? = payload["executableDevice"], UInt64(device).map(String.init) == device,
        case .string(let inode)? = payload["executableInode"], UInt64(inode).map(String.init) == inode,
        case .integer(let size)? = payload["executableFileSize"], size >= 0,
        case .string(let mode)? = payload["executableMode"], UInt32(mode).map(String.init) == mode,
        digest("executableSha256") != nil else { throw malformed() }
    case "outcome":
      try exact(["stepId", "outcome"])
      guard uuid("stepId") != nil, outcome("outcome") != nil else { throw malformed() }
    case "reconciliation":
      try exact([
        "reconciliationId", "stepId", "expectedScopeHash", "historicalOutcome",
        "outwardOutcome", "postDispatchObservation", "requiresReconcile", "reason",
        "observedScope",
      ])
      guard uuid("reconciliationId") != nil, uuid("stepId") != nil,
        digest("expectedScopeHash") != nil, outcome("historicalOutcome") != nil,
        outcome("outwardOutcome") != nil,
        case .bool = payload["requiresReconcile"], text("reason") != nil,
        case .object(let observation)? = payload["postDispatchObservation"],
        Set(observation.keys) == ["kind", "generation"],
        case .string(let observationKind)? = observation["kind"],
        ["generation", "unavailable", "missing"].contains(observationKind),
        (observationKind == "generation"
          ? { if case .integer(let value)? = observation["generation"] { return value > 0 }; return false }()
          : observation["generation"] == .null),
        case .object(let scope)? = payload["observedScope"],
        Set(scope.keys) == [
          "action", "endpoint", "health", "version", "generation", "generationEvidence",
          "ownership", "affectedDeviceCoordinators", "affectedJobs", "otherClientDetection",
          "criticalJobs", "impactReliable", "scopeHash",
        ],
        scope["action"] == .string("restartConfirmedGeneration"),
        case .string(let endpoint)? = scope["endpoint"], !endpoint.isEmpty,
        case .array = scope["affectedDeviceCoordinators"], case .array = scope["affectedJobs"],
        case .object = scope["otherClientDetection"], case .array = scope["criticalJobs"],
        case .bool = scope["impactReliable"]
      else { throw malformed() }
    default:
      throw malformed()
    }
  }

  private static func malformed() -> AgentExecutionControlFailure {
    HDCControlValue.failure("recordUnreadable", "HDC lifecycle audit payload is malformed")
  }
}
