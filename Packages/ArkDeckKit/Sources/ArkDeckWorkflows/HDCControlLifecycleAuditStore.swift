import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import Foundation

/// Host-wide lifecycle evidence owned by one durable controlAction. This is
/// intentionally independent of Session/Job manifests: the CLI action has no
/// fabricated Job identity, but keeps the same Supervisor and executor audit
/// ordering and the same actual-argv/launch-window proof.
package final class RuntimeHDCControlLifecycleAuditStore:
  HDCServerLifecycleAuditStore, HDCServerLifecycleDispatchAuthorizing,
  @unchecked Sendable
{
  private let store: RuntimeHDCControlActionStore
  private let actionID: String
  private let now: @Sendable () -> Date
  private let onLaunchWindowEntered: @Sendable () -> Void
  private let finalImpactValidator: @Sendable () async throws -> Bool
  private let mutationLock = NSLock()

  package init(
    store: RuntimeHDCControlActionStore,
    actionID: String,
    now: @escaping @Sendable () -> Date,
    onLaunchWindowEntered: @escaping @Sendable () -> Void = {},
    finalImpactValidator: @escaping @Sendable () async throws -> Bool = { true }
  ) {
    self.store = store
    self.actionID = actionID
    self.now = now
    self.onLaunchWindowEntered = onLaunchWindowEntered
    self.finalImpactValidator = finalImpactValidator
  }

  package func append(_ event: HDCServerLifecycleAuditEvent) async throws {
    switch event {
    case .impactPreview(let preview):
      try append(
        kind: "impactPreview", auditID: preview.auditID,
        payload: Self.preview(preview))
    case .confirmation(let confirmation):
      try append(
        kind: "confirmation", auditID: confirmation.auditID,
        payload: Self.confirmation(confirmation))
    case .intent(let step):
      try append(kind: "intent", auditID: step.auditID, payload: Self.intent(step))
    case .outcome(let stepID, let auditID, let outcome):
      try append(
        kind: "outcome", auditID: auditID,
        payload: [
          "stepId": .string(stepID.uuidString.lowercased()),
          "outcome": .object(Self.outcome(outcome)),
        ])
    case .reconciliation(let reconciliation):
      try appendReconciliation(reconciliation)
    }
  }

  package nonisolated func appendTerminalReconciliation(
    _ reconciliation: HDCServerLifecycleReconciliation
  ) throws {
    try appendReconciliation(reconciliation)
  }

  package func consumeDispatchAuthorization(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand
  ) async throws -> Bool {
    guard try await finalImpactValidator() else { return false }
    guard actualCommand.stepID == step.id, actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint,
      actualCommand.arguments
        == ["-s", step.endpoint.rawValue, "kill", "-r"],
      let record = try store.load(actionID: actionID),
      record.lifecycleAudit.last?.kind == "intent",
      record.lifecycleAudit.last?.auditID == step.auditID.uuidString.lowercased(),
      record.lifecycleAudit.last?.payload == Self.intent(step),
      !record.lifecycleAudit.contains(where: {
        ["actualCommand", "launchWindowEntered", "outcome", "reconciliation"].contains($0.kind)
      })
    else { return false }
    try append(
      kind: "actualCommand", auditID: step.auditID,
      payload: [
        "stepId": .string(step.id.uuidString.lowercased()),
        "executable": .string(actualCommand.executable.path),
        "argv": .array(actualCommand.arguments.map(JSONValue.string)),
        "endpoint": .string(actualCommand.endpoint.rawValue),
      ])
    return true
  }

  package func recordLaunchWindowEntry(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand,
    executableIdentity: HDCServerLifecycleExecutableIdentityReceipt
  ) async throws -> Bool {
    guard actualCommand.stepID == step.id, actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint,
      executableIdentity.authorizedPath == actualCommand.executable.path,
      executableIdentity.inodeLaunchPath
        == "/.vol/\(executableIdentity.device)/\(executableIdentity.inode)",
      executableIdentity.fileSize >= 0,
      executableIdentity.sha256.count == 64,
      let record = try store.load(actionID: actionID),
      record.lifecycleAudit.last?.kind == "actualCommand",
      record.lifecycleAudit.last?.auditID == step.auditID.uuidString.lowercased(),
      record.lifecycleAudit.last?.payload["stepId"]
        == .string(step.id.uuidString.lowercased()),
      record.lifecycleAudit.last?.payload["executable"]
        == .string(actualCommand.executable.path),
      record.lifecycleAudit.last?.payload["argv"]
        == .array(actualCommand.arguments.map(JSONValue.string)),
      !record.lifecycleAudit.contains(where: {
        ["launchWindowEntered", "outcome", "reconciliation"].contains($0.kind)
      })
    else { return false }
    try append(
      kind: "launchWindowEntered", auditID: step.auditID,
      payload: [
        "stepId": .string(step.id.uuidString.lowercased()),
        "executable": .string(actualCommand.executable.path),
        "argv": .array(actualCommand.arguments.map(JSONValue.string)),
        "endpoint": .string(actualCommand.endpoint.rawValue),
        "authorizedExecutable": .string(executableIdentity.authorizedPath),
        "inodeLaunchPath": .string(executableIdentity.inodeLaunchPath),
        "executableDevice": .string(String(executableIdentity.device)),
        "executableInode": .string(String(executableIdentity.inode)),
        "executableFileSize": .integer(executableIdentity.fileSize),
        "executableMode": .string(String(executableIdentity.mode)),
        "executableSha256": .string(executableIdentity.sha256),
      ])
    // The marker is already durably synchronized. The managed foreground
    // owner may now classify its exact imminent exit as confirmed lifecycle,
    // rather than terminating the Runtime as an unrelated crash.
    onLaunchWindowEntered()
    return true
  }

  package func record() throws -> HDCControlActionRecord {
    guard let record = try store.load(actionID: actionID) else {
      throw HDCControlValue.failure("recordUnreadable", "control action disappeared")
    }
    return record
  }

  /// Closes an interrupted lifecycle strictly from its durable boundary. An
  /// approval with no typed intent is invalidated. An intent with no launch
  /// marker is proven not executed because the production executor persists
  /// that marker before entering its process runner. Once the marker exists,
  /// the external effect is permanently outcome-unknown and is never replayed.
  package func recoverInterruptedLifecycle() throws -> HDCControlActionRecord {
    var current = try record()
    switch current.state {
    case "approvalRecorded":
      let recoveryTime = now()
      let expired = HDCControlValue.time(current.expiresAt).map {
        recoveryTime >= $0
      } ?? true
      let invalid = try current.invalidated(
        reason: expired ? "controlAction.expired" : "hdc.lifecycleInterruptedBeforeIntent",
        expired: expired, now: recoveryTime)
      try store.replace(invalid, expectedGeneration: current.generation)
      return invalid
    case "dispatchPrepared":
      let identity = try Self.interruptedIdentity(current)
      try append(
        kind: "outcome", auditID: identity.auditID,
        payload: [
          "stepId": .string(identity.stepID),
          "outcome": .object([
            "result": .string("failed"), "resultingGeneration": .null,
            "reason": .string(
              "Runtime restarted before the durable HDC launch-window entry"),
          ]),
        ])
      return try record()
    case "dispatching":
      let identity = try Self.interruptedIdentity(current)
      if current.lifecycleAudit.last?.kind == "launchWindowEntered" {
        try append(
          kind: "outcome", auditID: identity.auditID,
          payload: [
            "stepId": .string(identity.stepID),
            "outcome": .object([
              "result": .string("outcomeUnknown"), "resultingGeneration": .null,
              "reason": .string(
                "Runtime restarted after the durable HDC launch-window entry"),
            ]),
          ])
        current = try record()
      }
      guard current.lifecycleAudit.last?.kind == "outcome",
        case .object(let historical)? = current.lifecycleAudit.last?.payload["outcome"]
      else {
        throw HDCControlValue.failure(
          "recordUnreadable", "interrupted HDC lifecycle has no recoverable outcome boundary")
      }
      let outward: [String: JSONValue] = [
        "result": .string("outcomeUnknown"), "resultingGeneration": .null,
        "reason": .string(
          "Runtime restarted before terminal HDC lifecycle reconciliation"),
      ]
      try append(
        kind: "reconciliation", auditID: identity.auditID,
        payload: [
          "reconciliationId": .string(UUID().uuidString.lowercased()),
          "stepId": .string(identity.stepID),
          "expectedScopeHash": .string(identity.scopeHash),
          "historicalOutcome": .object(historical),
          "outwardOutcome": .object(outward),
          "postDispatchObservation": .object([
            "kind": .string("missing"), "generation": .null,
          ]),
          "requiresReconcile": .bool(true),
          "reason": .string(
            "Runtime restarted before terminal lifecycle reconciliation; the external outcome remains unknown and is never replayed"),
          "observedScope": .object([
            "action": .string("restartConfirmedGeneration"),
            "endpoint": .string(identity.endpoint),
            "health": .null, "version": .null, "generation": .null,
            "generationEvidence": .null, "ownership": .null,
            "affectedDeviceCoordinators": .array([]), "affectedJobs": .array([]),
            "otherClientDetection": .object([
              "kind": .string("unavailableExternalClientsMayStillExist"),
              "clients": .array([]),
            ]),
            "criticalJobs": .array([]), "impactReliable": .bool(false),
            "scopeHash": .null,
          ]),
        ])
      return try record()
    default:
      return current
    }
  }

  private static func interruptedIdentity(
    _ record: HDCControlActionRecord
  ) throws -> (auditID: UUID, stepID: String, scopeHash: String, endpoint: String) {
    guard let first = record.lifecycleAudit.first,
      let auditID = UUID(uuidString: first.auditID),
      let intent = record.lifecycleAudit.first(where: { $0.kind == "intent" }),
      case .string(let stepID)? = intent.payload["stepId"],
      case .string(let scopeHash)? = intent.payload["impactSnapshotHash"],
      case .string(let endpoint)? = intent.payload["endpoint"]
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "interrupted HDC lifecycle lacks its typed intent identity")
    }
    return (auditID, stepID, scopeHash, endpoint)
  }

  private nonisolated func appendReconciliation(
    _ reconciliation: HDCServerLifecycleReconciliation
  ) throws {
    try append(
      kind: "reconciliation", auditID: reconciliation.auditID,
      payload: [
        "reconciliationId": .string(reconciliation.id.uuidString.lowercased()),
        "stepId": .string(reconciliation.stepID.uuidString.lowercased()),
        "expectedScopeHash": .string(reconciliation.expectedScopeHash),
        "historicalOutcome": .object(Self.outcome(reconciliation.historicalOutcome)),
        "outwardOutcome": .object(Self.outcome(reconciliation.outwardOutcome)),
        "postDispatchObservation": .object(
          Self.postDispatchObservation(reconciliation.postDispatchObservation)),
        "requiresReconcile": .bool(reconciliation.requiresReconcile),
        "reason": .string(reconciliation.reason),
        "observedScope": .object(Self.observedScope(reconciliation.observedScope)),
      ])
  }

  private nonisolated func append(
    kind: String, auditID: UUID, payload: [String: JSONValue]
  ) throws {
    mutationLock.lock()
    defer { mutationLock.unlock() }
    guard let current = try store.load(actionID: actionID) else {
      throw HDCControlValue.failure("recordUnreadable", "control action disappeared")
    }
    let next = try current.appendingLifecycleAudit(
      kind: kind, auditID: auditID, payload: payload, now: now())
    try store.replace(next, expectedGeneration: current.generation)
  }

  package static func preview(
    _ preview: HDCServerLifecycleImpactPreview
  ) -> [String: JSONValue] {
    let snapshot = preview.snapshot
    return [
      "previewId": .string(preview.id.uuidString.lowercased()),
      "action": .string(snapshot.action.rawValue),
      "endpoint": .string(snapshot.endpoint.rawValue),
      "generation": .integer(Int64(snapshot.generation)),
      "ownership": .string(snapshot.ownership.rawValue),
      "scopeHash": .string(snapshot.scopeHash),
      "affectedDeviceCoordinators": .array(
        snapshot.affectedDeviceCoordinators.map(JSONValue.string)),
      "affectedJobs": .array(snapshot.affectedJobs.map(JSONValue.string)),
      "otherClientDetection": .object(otherClients(snapshot.otherClientDetection)),
      "expectedInterruption": .string(snapshot.expectedInterruption),
      "recoveryPath": .string(snapshot.recoveryPath),
    ]
  }

  package static func confirmation(
    _ confirmation: HDCServerLifecycleConfirmation
  ) -> [String: JSONValue] {
    [
      "confirmationId": .string(confirmation.id.uuidString.lowercased()),
      "previewId": .string(confirmation.previewID.uuidString.lowercased()),
      "action": .string(confirmation.action.rawValue),
      "endpoint": .string(confirmation.endpoint.rawValue),
      "generation": .integer(Int64(confirmation.generation)),
      "ownership": .string(confirmation.ownership.rawValue),
      "scopeHash": .string(confirmation.scopeHash),
    ]
  }

  package static func intent(_ step: HDCServerLifecycleStep) -> [String: JSONValue] {
    [
      "stepId": .string(step.id.uuidString.lowercased()),
      "confirmationId": step.confirmationID.map {
        .string($0.uuidString.lowercased())
      } ?? .null,
      "action": .string(step.action.rawValue),
      "endpoint": .string(step.endpoint.rawValue),
      "expectedGeneration": step.expectedGeneration.map { .integer(Int64($0)) } ?? .null,
      "expectedOwnership": .string(step.expectedOwnership.rawValue),
      "impactSnapshotHash": .string(step.impactSnapshotHash),
    ]
  }

  package static func outcome(
    _ outcome: HDCServerLifecycleExecutionOutcome
  ) -> [String: JSONValue] {
    switch outcome {
    case .succeeded(let generation):
      return [
        "result": .string("succeeded"), "resultingGeneration": .integer(Int64(generation)),
        "reason": .null,
      ]
    case .stopped:
      return ["result": .string("stopped"), "resultingGeneration": .null, "reason": .null]
    case .failed(let reason):
      return [
        "result": .string("failed"), "resultingGeneration": .null,
        "reason": .string(reason),
      ]
    case .outcomeUnknown(let reason):
      return [
        "result": .string("outcomeUnknown"), "resultingGeneration": .null,
        "reason": .string(reason),
      ]
    }
  }

  package static func postDispatchObservation(
    _ observation: HDCServerLifecyclePostDispatchObservation?
  ) -> [String: JSONValue] {
    switch observation {
    case .generation(let generation):
      return ["kind": .string("generation"), "generation": .integer(Int64(generation))]
    case .unavailable:
      return ["kind": .string("unavailable"), "generation": .null]
    case nil:
      return ["kind": .string("missing"), "generation": .null]
    }
  }

  package static func observedScope(
    _ scope: HDCServerLifecycleObservedScope
  ) -> [String: JSONValue] {
    [
      "action": .string(scope.action.rawValue),
      "endpoint": .string(scope.endpoint.rawValue),
      "health": scope.health.map { .string($0.rawValue) } ?? .null,
      "version": probe(scope.version),
      "generation": scope.generation.map { .integer(Int64($0)) } ?? .null,
      "generationEvidence": probe(scope.generationEvidence),
      "ownership": scope.ownership.map { .string($0.rawValue) } ?? .null,
      "affectedDeviceCoordinators": .array(
        scope.affectedDeviceCoordinators.map(JSONValue.string)),
      "affectedJobs": .array(scope.affectedJobs.map(JSONValue.string)),
      "otherClientDetection": .object(otherClients(scope.otherClientDetection)),
      "criticalJobs": .array(scope.criticalJobs.map {
        .object([
          "jobId": .string($0.jobID), "stepId": .string($0.stepID),
          "safeBoundaryAction": .string($0.safeBoundaryAction),
        ])
      }),
      "impactReliable": .bool(scope.impactReliable),
      "scopeHash": scope.scopeHash.map(JSONValue.string) ?? .null,
    ]
  }

  private static func probe<T>(_ value: HDCProbeValue<T>?) -> JSONValue
  where T: Sendable & Equatable {
    guard let value else { return .null }
    switch value {
    case .known(let value):
      if let text = value as? String {
        return .object(["kind": .string("known"), "value": .string(text), "reason": .null])
      }
      if let integer = value as? Int {
        return .object([
          "kind": .string("known"), "value": .integer(Int64(integer)), "reason": .null,
        ])
      }
      return .object([
        "kind": .string("unknown"), "value": .null,
        "reason": .string("unsupported probe value"),
      ])
    case .unknown(let reason):
      return .object([
        "kind": .string("unknown"), "value": .null, "reason": .string(reason),
      ])
    }
  }

  package static func otherClients(
    _ detection: HDCServerOtherClientDetection
  ) -> [String: JSONValue] {
    switch detection {
    case .detected(let clients):
      return [
        "kind": .string("detected"),
        "clients": .array(clients.sorted().map(JSONValue.string)),
      ]
    case .noneDetectedExternalClientsMayStillExist:
      return [
        "kind": .string("noneDetectedExternalClientsMayStillExist"), "clients": .array([]),
      ]
    case .unavailableExternalClientsMayStillExist:
      return [
        "kind": .string("unavailableExternalClientsMayStillExist"), "clients": .array([]),
      ]
    }
  }
}

/// The headless Runtime owns one Supervisor for the lifetime of its selected
/// HDC endpoint. This router binds that shared actor to exactly one durable
/// controlAction audit while a confirmed dispatch is in flight.
package final class RuntimeHDCControlLifecycleAuditRouter:
  HDCServerLifecycleAuditStore, HDCServerLifecycleDispatchAuthorizing,
  @unchecked Sendable
{
  package struct Binding: Sendable, Equatable { fileprivate let id: UUID }
  private let lock = NSLock()
  private typealias Owner = any HDCServerLifecycleAuditStore & HDCServerLifecycleDispatchAuthorizing
  private var active: (Binding, Owner)?

  package init() {}

  package func bind<T>(_ store: T) throws -> Binding
  where T: HDCServerLifecycleAuditStore, T: HDCServerLifecycleDispatchAuthorizing {
    lock.lock()
    defer { lock.unlock() }
    guard active == nil else {
      throw HDCControlValue.failure(
        "resourceConflict", "another HDC lifecycle audit is already bound")
    }
    let binding = Binding(id: UUID())
    active = (binding, store)
    return binding
  }

  package func unbind(_ binding: Binding) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active?.0 == binding else {
      throw HDCControlValue.failure("resourceConflict", "HDC lifecycle audit binding changed")
    }
    active = nil
  }

  package func append(_ event: HDCServerLifecycleAuditEvent) async throws {
    try await required().append(event)
  }

  package nonisolated func appendTerminalReconciliation(
    _ reconciliation: HDCServerLifecycleReconciliation
  ) throws {
    try required().appendTerminalReconciliation(reconciliation)
  }

  package func consumeDispatchAuthorization(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand
  ) async throws -> Bool {
    try await required().consumeDispatchAuthorization(
      of: step, actualCommand: actualCommand)
  }

  package func recordLaunchWindowEntry(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand,
    executableIdentity: HDCServerLifecycleExecutableIdentityReceipt
  ) async throws -> Bool {
    try await required().recordLaunchWindowEntry(
      of: step, actualCommand: actualCommand,
      executableIdentity: executableIdentity)
  }

  private nonisolated func required() throws -> Owner {
    lock.lock()
    defer { lock.unlock() }
    guard let active else {
      throw HDCControlValue.failure(
        "admissionDenied", "no durable control action owns HDC lifecycle audit")
    }
    return active.1
  }
}
