import ArkDeckCore
import Foundation

enum JournalEventSemanticValidator {
  private static let commonEnvelopeKeys: Set<String> = [
    "schemaVersion", "eventId", "sequence", "sessionId", "jobId", "timestamp",
    "accumulatedElapsedDurationNanoseconds", "accumulatedActiveDurationNanoseconds", "kind",
    "payload",
  ]

  static func validateEnvelopeKeys(_ object: [String: JSONValue], kind: JournalEventKind) throws {
    let required: Set<String> = [
      "schemaVersion", "eventId", "sequence", "sessionId", "jobId", "timestamp", "kind", "payload",
    ]
    let variant: Set<String>
    switch kind {
    case .stepIntent, .compensationIntent:
      variant = ["stepId", "attempt", "bindingRevision", "argumentsHash"]
    case .stepOutcome, .compensationOutcome:
      variant = ["stepId", "attempt"]
    case .bindingConfirmed, .reconcileOutcome:
      variant = ["bindingRevision"]
    default:
      variant = []
    }
    try object.requireKeys(
      required.union(variant), optional: commonEnvelopeKeys.subtracting(required))
  }

  static func validate(_ event: JournalEvent) throws {
    guard
      event.schemaVersion == JournalEvent.schemaVersion
        || event.schemaVersion == JournalEvent.authorizedAgentSchemaVersion
    else {
      throw JournalEventValidationError.malformedEnvelope("unsupported schemaVersion")
    }
    guard event.sequence >= 0, !event.eventID.isEmpty, !event.sessionID.isEmpty,
      !event.jobID.isEmpty
    else {
      throw JournalEventValidationError.malformedEnvelope("invalid id or sequence")
    }
    guard event.accumulatedElapsedDurationNanoseconds.map({ $0 >= 0 }) ?? true,
      event.accumulatedActiveDurationNanoseconds.map({ $0 >= 0 }) ?? true
    else {
      throw JournalEventValidationError.malformedEnvelope("durations must be nonnegative")
    }
    guard isDateTime(event.timestamp) else {
      throw JournalEventValidationError.malformedEnvelope("timestamp is not RFC 3339 date-time")
    }

    do {
      switch event.kind {
      case .jobCreated: try validateJobCreated(event)
      case .stateTransition: try validateStateTransition(event)
      case .stepIntent: try validateStepIntent(event)
      case .stepOutcome: try validateStepOutcome(event)
      case .compensationIntent: try validateCompensationIntent(event)
      case .compensationOutcome: try validateCompensationOutcome(event)
      case .bindingCandidate: try validateBindingCandidate(event)
      case .bindingConfirmed: try validateBindingConfirmed(event)
      case .bindingRejected: try validateBindingRejected(event)
      case .serverGenerationChanged: try validateServerGenerationChanged(event)
      case .sleep: try validateSleep(event)
      case .wake: try validateWake(event)
      case .reconcileStarted: try validateReconcileStarted(event)
      case .reconcileOutcome: try validateReconcileOutcome(event)
      case .abandonIntent: try validateAbandonIntent(event)
      case .abandonOutcome: try validateAbandonOutcome(event)
      case .warning, .error: try validateDiagnostic(event)
      case .finalized: try validateFinalized(event)
      }
    } catch let error as JournalEventValidationError {
      throw error
    } catch {
      throw JournalEventValidationError.malformedPayload(kind: event.kind, detail: "\(error)")
    }
  }

  private static func validateJobCreated(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    let baseKeys: Set<String> = [
      "executionMode", "executionAuthority", "initialState", "coreBaseline",
    ]
    if event.schemaVersion == JournalEvent.schemaVersion {
      try event.payload.requireKeys(baseKeys)
    } else {
      try event.payload.requireKeys(
        baseKeys, optional: ["authorizationRef", "usageReservationId"])
    }
    try event.payload.requireEnum("executionMode", ["execute", "planOnly", "simulated"])
    let authority = try event.payload.requiredString("executionAuthority", context: "jobCreated")
    let allowedAuthorities: Set<String> = [
      "interactiveUser", "standardAgent", "controlledHardwareLab", "authorizedAgent",
    ]
    guard allowedAuthorities.contains(authority),
      event.schemaVersion == JournalEvent.authorizedAgentSchemaVersion
        || authority != "authorizedAgent"
    else { throw payload(event, "executionAuthority is not supported by this schemaVersion") }
    if authority == "authorizedAgent" {
      _ = try event.requiredAuthorizationCorrelation(context: "jobCreated")
    } else if event.payload["authorizationRef"] != nil
      || event.payload["usageReservationId"] != nil
    {
      throw payload(event, "non-authorized authority cannot carry authorization correlation")
    }
    guard try event.payload.requiredString("initialState", context: "jobCreated") == "queued" else {
      throw payload(event, "initialState must be queued")
    }
    let baseline = try event.payload.requiredString("coreBaseline", context: "jobCreated")
    guard baseline.matches(#"^CORE-[0-9]+\.[0-9]+\.[0-9]+$"#) else {
      throw payload(event, "invalid coreBaseline")
    }
  }

  private static func validateStateTransition(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(["from", "to", "reason"], optional: ["triggerEventId"])
    guard let transition = event.stateTransition else { throw payload(event, "invalid Job state") }
    _ = try event.payload.requiredNonemptyString("reason", context: "stateTransition")
    try event.payload.validateNullableNonemptyString("triggerEventId", context: "stateTransition")
    let allowed =
      JobStateMachine.isAllowedTransition(
        from: transition.from, to: transition.to, mode: .execute)
      || JobStateMachine.isAllowedTransition(
        from: transition.from, to: transition.to, mode: .planOnly)
    guard allowed else { throw payload(event, "transition is not in the locked pair union") }
  }

  private static func validateStepIntent(_ event: JournalEvent) throws {
    try event.requireStepEnvelope(requiresArgumentsHash: true)
    try event.payload.requireKeys(
      ["step", "target"],
      optional: event.schemaVersion == JournalEvent.authorizedAgentSchemaVersion
        ? ["authorizationRef", "usageReservationId"] : [])
    guard let stepValue = event.payload["step"], let targetValue = event.payload["target"] else {
      throw payload(event, "missing step or target")
    }
    let step: WorkflowStep
    do { step = try JournalCanonicalJSON.decodeWorkflowStep(stepValue) } catch {
      throw payload(event, "embedded workflow step rejected: \(error)")
    }
    guard event.stepID == step.id else {
      throw payload(event, "stepId does not match payload.step.id")
    }
    let canonicalHash = try JournalCanonicalJSON.argumentsHash(step.arguments)
    guard event.argumentsHash == canonicalHash else {
      throw JournalEventValidationError.canonicalArgumentsHashMismatch(stepID: step.id)
    }
    for descriptor in step.compensationDescriptors {
      let descriptorHash = try JournalCanonicalJSON.argumentsHash(descriptor.arguments)
      guard descriptor.argumentsHash.lowercased() == descriptorHash else {
        throw JournalEventValidationError.canonicalArgumentsHashMismatch(stepID: descriptor.id)
      }
    }
    try validateTarget(
      targetValue, bindingRequirement: step.bindingRequirement,
      bindingRevision: event.bindingRevision, event: event)
    try event.validateOptionalAuthorizationCorrelation(context: "stepIntent")
  }

  private static func validateStepOutcome(_ event: JournalEvent) throws {
    try event.requireStepEnvelope(requiresArgumentsHash: false)
    try event.payload.requireKeys(
      ["correlatesToIntentEventId", "result", "outcomeCertainty"],
      optional: event.schemaVersion == JournalEvent.authorizedAgentSchemaVersion
        ? ["semanticCode", "summary", "authorizationRef", "usageReservationId"]
        : ["semanticCode", "summary"])
    _ = try event.payload.requiredNonemptyString(
      "correlatesToIntentEventId", context: "stepOutcome")
    try event.payload.requireEnum("result", ["succeeded", "failed", "cancelled", "timedOut"])
    try event.payload.requireEnum("outcomeCertainty", ["confirmed", "outcomeUnknown"])
    try event.payload.validateNullableString("semanticCode", context: "stepOutcome")
    try event.payload.validateNullableString("summary", context: "stepOutcome")
    try event.validateOptionalAuthorizationCorrelation(context: "stepOutcome")
  }

  private static func validateCompensationIntent(_ event: JournalEvent) throws {
    try event.requireStepEnvelope(requiresArgumentsHash: true)
    try event.payload.requireKeys(["compensationOfStepId", "descriptor", "target"])
    _ = try event.payload.requiredNonemptyString(
      "compensationOfStepId", context: "compensationIntent")
    guard let descriptorValue = event.payload["descriptor"],
      let targetValue = event.payload["target"]
    else {
      throw payload(event, "missing descriptor or target")
    }
    let descriptor: CompensationDescriptor
    do { descriptor = try JournalCanonicalJSON.decodeCompensation(descriptorValue) } catch {
      throw payload(event, "embedded compensation rejected: \(error)")
    }
    guard event.stepID == descriptor.id else {
      throw payload(event, "stepId does not match descriptor.id")
    }
    let canonicalHash = try JournalCanonicalJSON.argumentsHash(descriptor.arguments)
    guard event.argumentsHash == canonicalHash,
      descriptor.argumentsHash.lowercased() == canonicalHash
    else {
      throw JournalEventValidationError.canonicalArgumentsHashMismatch(stepID: descriptor.id)
    }
    try validateTarget(
      targetValue, bindingRequirement: descriptor.bindingRequirement,
      bindingRevision: event.bindingRevision, event: event)
  }

  private static func validateCompensationOutcome(_ event: JournalEvent) throws {
    try event.requireStepEnvelope(requiresArgumentsHash: false)
    try event.payload.requireKeys(
      [
        "compensationOfStepId", "descriptorId", "correlatesToIntentEventId", "result",
        "outcomeCertainty",
      ], optional: ["semanticCode", "summary"])
    _ = try event.payload.requiredNonemptyString(
      "compensationOfStepId", context: "compensationOutcome")
    let descriptorID = try event.payload.requiredNonemptyString(
      "descriptorId", context: "compensationOutcome")
    guard event.stepID == descriptorID else {
      throw payload(event, "stepId does not match descriptorId")
    }
    _ = try event.payload.requiredNonemptyString(
      "correlatesToIntentEventId", context: "compensationOutcome")
    try event.payload.requireEnum("result", ["succeeded", "failed", "cancelled", "timedOut"])
    try event.payload.requireEnum("outcomeCertainty", ["confirmed", "outcomeUnknown"])
    try event.payload.validateNullableString("semanticCode", context: "compensationOutcome")
    try event.payload.validateNullableString("summary", context: "compensationOutcome")
  }

  private static func validateBindingCandidate(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      ["candidateId", "connectKey", "transport", "identitySnapshot", "evidence", "ambiguity"])
    _ = try event.payload.requiredNonemptyString("candidateId", context: "bindingCandidate")
    try event.payload.validateNullableString("connectKey", context: "bindingCandidate")
    try event.payload.requireEnum("transport", ["usb", "tcp", "uart", "synthetic"])
    try event.payload.requireNonemptyObject("identitySnapshot", context: "bindingCandidate")
    try event.payload.requireStringArray("evidence", minimumCount: 0, context: "bindingCandidate")
    try event.payload.requireEnum("ambiguity", ["unambiguous", "ambiguous"])
  }

  private static func validateBindingConfirmed(_ event: JournalEvent) throws {
    guard event.bindingRevision.map({ $0 > 0 }) == true else {
      throw payload(event, "bindingRevision is required")
    }
    guard event.stepID == nil, event.attempt == nil, event.argumentsHash == nil else {
      throw payload(event, "unexpected step envelope fields")
    }
    try event.payload.requireKeys(["candidateEventId", "binding"])
    _ = try event.payload.requiredNonemptyString("candidateEventId", context: "bindingConfirmed")
    guard case .object(let binding)? = event.payload["binding"] else {
      throw payload(event, "binding must be an object")
    }
    try binding.requireKeys(
      [
        "connectKey", "transport", "identitySnapshot", "evidence", "confirmedBy",
        "channelProtection",
      ])
    try binding.validateNullableString("connectKey", context: "binding")
    try binding.requireEnum("transport", ["usb", "tcp", "uart", "synthetic"])
    try binding.requireNonemptyObject("identitySnapshot", context: "binding")
    try binding.requireStringArray("evidence", minimumCount: 1, context: "binding")
    try binding.requireEnum("confirmedBy", ["corePolicy", "user", "simulation"])
    try binding.requireEnum(
      "channelProtection", ["encryptedVerified", "unverifiedAssumeUnprotected", "notApplicable"])
    let transport = try binding.requiredString("transport", context: "binding")
    if transport == "synthetic" {
      guard binding["connectKey"] == .null,
        binding.string("confirmedBy") == "simulation",
        binding.string("channelProtection") == "notApplicable"
      else { throw payload(event, "synthetic binding invariants failed") }
    } else {
      _ = try binding.requiredNonemptyString("connectKey", context: "binding")
      guard binding.string("confirmedBy") != "simulation",
        binding.string("channelProtection") != "notApplicable"
      else { throw payload(event, "real binding invariants failed") }
    }
  }

  private static func validateBindingRejected(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(["candidateEventId", "reason", "evidence"])
    _ = try event.payload.requiredNonemptyString("candidateEventId", context: "bindingRejected")
    try event.payload.requireEnum(
      "reason",
      [
        "identityMismatch", "userRejected", "ambiguous", "staleCandidate",
        "serverGenerationChanged", "policyBlocked",
      ])
    try event.payload.requireStringArray("evidence", minimumCount: 0, context: "bindingRejected")
  }

  private static func validateServerGenerationChanged(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      ["endpoint", "previousGeneration", "currentGeneration", "ownership", "reason"])
    _ = try event.payload.requiredNonemptyString("endpoint", context: "serverGenerationChanged")
    try event.payload.requireNonnegativeInt(
      "previousGeneration", context: "serverGenerationChanged")
    try event.payload.requireNonnegativeInt("currentGeneration", context: "serverGenerationChanged")
    try event.payload.requireEnum("ownership", ["external", "arkDeckManaged", "unknown"])
    _ = try event.payload.requiredNonemptyString("reason", context: "serverGenerationChanged")
  }

  private static func validateSleep(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(["elapsedDurationNanoseconds", "activeDurationNanoseconds"])
    try event.payload.requireNonnegativeInt("elapsedDurationNanoseconds", context: "sleep")
    try event.payload.requireNonnegativeInt("activeDurationNanoseconds", context: "sleep")
  }

  private static func validateWake(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      [
        "sleepEventId", "elapsedDurationNanoseconds", "activeDurationNanoseconds",
        "throughputSegmentReset",
      ])
    _ = try event.payload.requiredNonemptyString("sleepEventId", context: "wake")
    try event.payload.requireNonnegativeInt("elapsedDurationNanoseconds", context: "wake")
    try event.payload.requireNonnegativeInt("activeDurationNanoseconds", context: "wake")
    guard event.payload["throughputSegmentReset"] == .bool(true) else {
      throw payload(event, "throughputSegmentReset must be true")
    }
  }

  private static func validateReconcileStarted(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      ["recoveryAttemptId", "sourceState", "lastDurableSequence", "trigger"])
    _ = try event.payload.requiredNonemptyString("recoveryAttemptId", context: "reconcileStarted")
    let state = try event.payload.requiredString("sourceState", context: "reconcileStarted")
    guard JobState(rawValue: state) != nil else { throw payload(event, "invalid sourceState") }
    try event.payload.requireNonnegativeInt("lastDurableSequence", context: "reconcileStarted")
    try event.payload.requireEnum(
      "trigger", ["startup", "manual", "deviceReturned", "providerRecovery"])
  }

  private static func validateReconcileOutcome(_ event: JournalEvent) throws {
    guard event.stepID == nil, event.attempt == nil, event.argumentsHash == nil else {
      throw payload(event, "unexpected step envelope fields")
    }
    try event.payload.requireKeys(
      [
        "recoveryAttemptId", "result", "nextState", "outcomeCertainty",
        "safeBoundaryConfirmed", "evidence",
      ])
    _ = try event.payload.requiredNonemptyString("recoveryAttemptId", context: "reconcileOutcome")
    let result = try event.payload.requiredString("result", context: "reconcileOutcome")
    let nextState = try event.payload.requiredString("nextState", context: "reconcileOutcome")
    let certainty = try event.payload.requiredString(
      "outcomeCertainty", context: "reconcileOutcome")
    guard let safe = event.payload.bool("safeBoundaryConfirmed") else {
      throw payload(event, "safeBoundaryConfirmed must be boolean")
    }
    try event.payload.requireStringArray("evidence", minimumCount: 0, context: "reconcileOutcome")
    switch result {
    case "resumeAtConfirmedSafeBoundary":
      guard nextState == "resumeAtConfirmedSafeBoundary", certainty == "confirmed", safe,
        event.bindingRevision.map({ $0 > 0 }) == true
      else { throw payload(event, "resume evidence is inconsistent") }
    case "waitingForRecovery":
      guard nextState == "waitingForRecovery",
        certainty == "confirmed" || certainty == "outcomeUnknown"
      else { throw payload(event, "waiting result is inconsistent") }
    case "finalizeConfirmedFailure":
      guard nextState == "finalizing", certainty == "confirmed", safe,
        event.bindingRevision.map({ $0 > 0 }) == true
      else {
        throw payload(event, "confirmed failure result is inconsistent")
      }
    case "noAction":
      guard nextState == "waitingForRecovery" else {
        throw payload(event, "noAction is inconsistent")
      }
    default:
      throw payload(event, "unknown reconcile result")
    }
  }

  private static func validateAbandonIntent(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      [
        "userConfirmationId", "lastConfirmedStep", "outcomeCertainty", "managedProcessState",
        "deviceHazards",
      ])
    _ = try event.payload.requiredNonemptyString("userConfirmationId", context: "abandonIntent")
    try event.payload.validateNullableNonemptyString("lastConfirmedStep", context: "abandonIntent")
    try event.payload.requireEnum("outcomeCertainty", ["confirmed", "outcomeUnknown"])
    try event.payload.requireEnum(
      "managedProcessState",
      ["notRunning", "runningInterruptible", "criticalAwaitingSafeBoundary", "unknown"])
    try event.payload.requireStringArray("deviceHazards", minimumCount: 0, context: "abandonIntent")
  }

  private static func validateAbandonOutcome(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(
      ["correlatesToAbandonIntentEventId", "result", "releaseAuthorized", "unresolvedHazards"])
    _ = try event.payload.requiredNonemptyString(
      "correlatesToAbandonIntentEventId", context: "abandonOutcome")
    let result = try event.payload.requiredString("result", context: "abandonOutcome")
    guard ["archivedInterrupted", "deferred", "failed"].contains(result),
      let release = event.payload.bool("releaseAuthorized")
    else { throw payload(event, "invalid abandon result") }
    guard release == (result == "archivedInterrupted") else {
      throw payload(event, "releaseAuthorized does not match result")
    }
    try event.payload.requireStringArray(
      "unresolvedHazards", minimumCount: 0, context: "abandonOutcome")
  }

  private static func validateDiagnostic(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(["code", "message", "details"])
    _ = try event.payload.requiredNonemptyString("code", context: "diagnostic")
    _ = try event.payload.requiredNonemptyString("message", context: "diagnostic")
    guard case .object? = event.payload["details"] else {
      throw payload(event, "details must be object")
    }
  }

  private static func validateFinalized(_ event: JournalEvent) throws {
    try event.noStepEnvelope()
    try event.payload.requireKeys(["terminalStatus", "manifestSha256", "outcomeCertainty"])
    let status = try event.payload.requiredString("terminalStatus", context: "finalized")
    guard ["planned", "succeeded", "failed", "cancelled", "interrupted"].contains(status) else {
      throw payload(event, "invalid terminal status")
    }
    let hash = try event.payload.requiredString("manifestSha256", context: "finalized")
    guard hash.isLowercaseSHA256 else { throw payload(event, "invalid manifestSha256") }
    let certainty = try event.payload.requiredString("outcomeCertainty", context: "finalized")
    if status == "interrupted" {
      guard ["confirmed", "outcomeUnknown", "mixed"].contains(certainty) else {
        throw payload(event, "invalid interrupted certainty")
      }
    } else if certainty != "confirmed" {
      throw payload(event, "non-interrupted terminal status requires confirmed certainty")
    }
  }

  private static func validateTarget(
    _ value: JSONValue,
    bindingRequirement: WorkflowBindingRequirement,
    bindingRevision: Int?,
    event: JournalEvent
  ) throws {
    guard case .object(let target) = value else { throw payload(event, "target must be object") }
    try target.requireKeys(["scope", "targetId", "connectKey", "identitySnapshotHash"])
    try target.requireEnum("scope", ["host", "server", "device"])
    _ = try target.requiredNonemptyString("targetId", context: "target")
    try target.validateNullableNonemptyString("connectKey", context: "target")
    try target.validateNullableSHA256("identitySnapshotHash", context: "target")
    switch bindingRequirement {
    case .none:
      guard bindingRevision == nil else {
        throw payload(event, "non-device step has bindingRevision")
      }
    case .confirmedDevice:
      guard bindingRevision.map({ $0 > 0 }) == true,
        target.string("scope") == "device",
        (try? target.requiredNonemptyString("connectKey", context: "target")) != nil,
        target.string("identitySnapshotHash")?.isLowercaseSHA256 == true
      else { throw payload(event, "confirmed-device target evidence is incomplete") }
    }
  }

  private static func isDateTime(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }

  private static func payload(_ event: JournalEvent, _ detail: String)
    -> JournalEventValidationError
  {
    .malformedPayload(kind: event.kind, detail: detail)
  }
}

extension JournalEvent {
  fileprivate func noStepEnvelope() throws {
    guard stepID == nil, attempt == nil, bindingRevision == nil, argumentsHash == nil else {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "unexpected step envelope fields")
    }
  }

  fileprivate func requireStepEnvelope(requiresArgumentsHash: Bool) throws {
    guard let stepID, !stepID.isEmpty, attempt.map({ $0 > 0 }) == true else {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "invalid step envelope")
    }
    if requiresArgumentsHash {
      guard argumentsHash?.isLowercaseSHA256 == true else {
        throw JournalEventValidationError.malformedPayload(
          kind: kind, detail: "invalid argumentsHash")
      }
    } else if argumentsHash != nil || bindingRevision != nil {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "outcome carries intent-only envelope fields")
    }
  }

  fileprivate func requiredAuthorizationCorrelation(
    context: String
  ) throws -> (AuthorizationReference, String) {
    guard let value = payload["authorizationRef"] else {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "\(context) is missing authorizationRef")
    }
    let reference: AuthorizationReference
    do {
      reference = try AuthorizationReference(
        jsonValue: value, context: "\(context).authorizationRef")
    } catch {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "\(context) authorizationRef is malformed")
    }
    guard let reservationID = payload.string("usageReservationId"),
      reservationID.matches("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
    else {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "\(context) is missing usageReservationId")
    }
    return (reference, reservationID)
  }

  fileprivate func validateOptionalAuthorizationCorrelation(context: String) throws {
    let hasReference = payload["authorizationRef"] != nil
    let hasReservation = payload["usageReservationId"] != nil
    guard hasReference == hasReservation else {
      throw JournalEventValidationError.malformedPayload(
        kind: kind, detail: "\(context) authorization correlation is incomplete")
    }
    if hasReference { _ = try requiredAuthorizationCorrelation(context: context) }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  func requireKeys(_ required: Set<String>, optional: Set<String> = []) throws {
    let actual = Set(keys)
    let missing = required.subtracting(actual)
    let unexpected = actual.subtracting(required.union(optional))
    guard missing.isEmpty, unexpected.isEmpty else {
      throw JournalEventValidationError.malformedEnvelope(
        "missing keys \(missing.sorted()); unexpected keys \(unexpected.sorted())")
    }
  }

  func requiredString(_ key: String, context: String) throws -> String {
    guard case .string(let value)? = self[key] else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be string")
    }
    return value
  }

  func requiredNonemptyString(_ key: String, context: String) throws -> String {
    let value = try requiredString(key, context: context)
    guard !value.isEmpty else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be nonempty")
    }
    return value
  }

  func optionalString(_ key: String, context: String) throws -> String? {
    guard let value = self[key] else { return nil }
    if case .null = value { return nil }
    guard case .string(let string) = value else {
      throw JournalEventValidationError.malformedEnvelope(
        "\(context).\(key) must be string or null")
    }
    return string
  }

  func validateNullableString(_ key: String, context: String) throws {
    guard self[key] != nil else { return }
    _ = try optionalString(key, context: context)
  }

  func validateNullableNonemptyString(_ key: String, context: String) throws {
    guard let value = try optionalString(key, context: context) else { return }
    guard !value.isEmpty else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be nonempty")
    }
  }

  func requiredInt(_ key: String, context: String) throws -> Int {
    guard let value = self[key], let integer = value.intValue else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be integer")
    }
    return integer
  }

  func optionalInt(_ key: String, context: String) throws -> Int? {
    guard let value = self[key] else { return nil }
    if case .null = value { return nil }
    guard let integer = value.intValue else {
      throw JournalEventValidationError.malformedEnvelope(
        "\(context).\(key) must be integer or null")
    }
    return integer
  }

  func requireNonnegativeInt(_ key: String, context: String) throws {
    guard try requiredInt(key, context: context) >= 0 else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be nonnegative")
    }
  }

  func requireEnum(_ key: String, _ allowed: Set<String>) throws {
    let value = try requiredString(key, context: "payload")
    guard allowed.contains(value) else {
      throw JournalEventValidationError.malformedEnvelope(
        "payload.\(key) has unknown value \(value)")
    }
  }

  func requireStringArray(_ key: String, minimumCount: Int, context: String) throws {
    guard case .array(let values)? = self[key], values.count >= minimumCount,
      values.allSatisfy({ value in
        if case .string(let string) = value { return !string.isEmpty }
        return false
      })
    else {
      throw JournalEventValidationError.malformedEnvelope("\(context).\(key) must be string array")
    }
  }

  func requireNonemptyObject(_ key: String, context: String) throws {
    guard case .object(let value)? = self[key], !value.isEmpty else {
      throw JournalEventValidationError.malformedEnvelope(
        "\(context).\(key) must be nonempty object")
    }
  }

  func validateNullableSHA256(_ key: String, context: String) throws {
    guard let value = try optionalString(key, context: context) else { return }
    guard value.isLowercaseSHA256 else {
      throw JournalEventValidationError.malformedEnvelope(
        "\(context).\(key) must be lowercase SHA-256")
    }
  }

  func string(_ key: String) -> String? {
    guard case .string(let value)? = self[key] else { return nil }
    return value
  }

  func bool(_ key: String) -> Bool? {
    guard case .bool(let value)? = self[key] else { return nil }
    return value
  }
}

extension JSONValue {
  fileprivate var intValue: Int? {
    switch self {
    case .integer(let value): return Int(exactly: value)
    case .unsignedInteger(let value): return Int(exactly: value)
    default: return nil
    }
  }
}

extension String {
  fileprivate var isLowercaseSHA256: Bool { matches(#"^[a-f0-9]{64}$"#) }

  fileprivate func matches(_ pattern: String) -> Bool {
    range(of: pattern, options: .regularExpression) == startIndex..<endIndex
  }
}
