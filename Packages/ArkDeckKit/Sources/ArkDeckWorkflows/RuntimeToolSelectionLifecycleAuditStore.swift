import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import Foundation

/// Durable adapter from one tool-selection owner into the accepted HDC
/// Supervisor/executor audit contract. The actual executable and argv are
/// captured by the identity-bound executor; neither is caller input.
package final class RuntimeToolSelectionLifecycleAuditStore:
  HDCServerLifecycleAuditStore, HDCServerLifecycleDispatchAuthorizing,
  @unchecked Sendable
{
  private let store: RuntimeToolSelectionControlActionStore
  private let actionID: String
  private let now: @Sendable () -> Date
  private let finalImpactValidator: @Sendable () async throws -> Bool
  private let onLaunchWindowEntered: @Sendable () -> Void
  private let mutationLock = NSLock()
  private let signalLock = NSLock()
  private var enteredLaunchWindow = false

  package init(
    store: RuntimeToolSelectionControlActionStore, actionID: String,
    now: @escaping @Sendable () -> Date,
    finalImpactValidator: @escaping @Sendable () async throws -> Bool,
    onLaunchWindowEntered: @escaping @Sendable () -> Void
  ) {
    self.store = store
    self.actionID = actionID
    self.now = now
    self.finalImpactValidator = finalImpactValidator
    self.onLaunchWindowEntered = onLaunchWindowEntered
  }

  package func append(_ event: HDCServerLifecycleAuditEvent) async throws {
    switch event {
    case .impactPreview(let preview):
      try append(
        kind: "impactPreview", auditID: preview.auditID,
        payload: RuntimeHDCControlLifecycleAuditStore.preview(preview))
    case .confirmation(let confirmation):
      try append(
        kind: "confirmation", auditID: confirmation.auditID,
        payload: RuntimeHDCControlLifecycleAuditStore.confirmation(confirmation))
    case .intent(let step):
      try append(
        kind: "intent", auditID: step.auditID,
        payload: RuntimeHDCControlLifecycleAuditStore.intent(step))
    case .outcome(let stepID, let auditID, let outcome):
      try append(
        kind: "outcome", auditID: auditID,
        payload: [
          "stepId": .string(stepID.uuidString.lowercased()),
          "outcome": .object(RuntimeHDCControlLifecycleAuditStore.outcome(outcome)),
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
    guard try await finalImpactValidator(),
      step.action == .restartConfirmedGeneration,
      actualCommand.stepID == step.id, actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint,
      actualCommand.arguments == ["-s", step.endpoint.rawValue, "kill", "-r"],
      let record = try store.load(actionID: actionID),
      Self.lastAudit(record, kind: "intent")?.payload
        == RuntimeHDCControlLifecycleAuditStore.intent(step),
      !Self.hasAudit(record, kinds: ["actualCommand", "launchWindowEntered"])
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
      executableIdentity.fileSize >= 0, HDCControlValue.digest(executableIdentity.sha256),
      let record = try store.load(actionID: actionID), let preview = record.preview,
      preview.impact.newTool.value["executableSHA256"] == .string(executableIdentity.sha256),
      let actual = Self.lastAudit(record, kind: "actualCommand"),
      actual.payload["stepId"] == .string(step.id.uuidString.lowercased()),
      actual.payload["executable"] == .string(actualCommand.executable.path),
      actual.payload["argv"] == .array(actualCommand.arguments.map(JSONValue.string)),
      !Self.hasAudit(record, kinds: ["launchWindowEntered"])
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
    signalLock.withLock { enteredLaunchWindow = true }
    onLaunchWindowEntered()
    return true
  }

  package func launchWindowWasEntered() -> Bool {
    signalLock.withLock { enteredLaunchWindow }
  }

  package func record() throws -> RuntimeToolSelectionControlActionRecord {
    guard let record = try store.load(actionID: actionID) else {
      throw HDCControlValue.failure("recordUnreadable", "tool-selection control action disappeared")
    }
    return record
  }

  package func markSelectionPrepared() throws -> RuntimeToolSelectionControlActionRecord {
    mutationLock.lock()
    defer { mutationLock.unlock() }
    let current = try record()
    let next = try current.prepared(now: now())
    try store.replace(next, expectedGeneration: current.generation)
    return next
  }

  package func markFailedBeforeLaunch(
    reasonCode: String
  ) throws -> RuntimeToolSelectionControlActionRecord {
    mutationLock.lock()
    defer { mutationLock.unlock() }
    let current = try record()
    let next = try current.failedBeforeLaunch(reasonCode: reasonCode, now: now())
    try store.replace(next, expectedGeneration: current.generation)
    return next
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
        "historicalOutcome": .object(
          RuntimeHDCControlLifecycleAuditStore.outcome(reconciliation.historicalOutcome)),
        "outwardOutcome": .object(
          RuntimeHDCControlLifecycleAuditStore.outcome(reconciliation.outwardOutcome)),
        "postDispatchObservation": .object(
          RuntimeHDCControlLifecycleAuditStore.postDispatchObservation(
            reconciliation.postDispatchObservation)),
        "requiresReconcile": .bool(reconciliation.requiresReconcile),
        "reason": .string(reconciliation.reason),
        "observedScope": .object(
          RuntimeHDCControlLifecycleAuditStore.observedScope(reconciliation.observedScope)),
      ])
  }

  private nonisolated func append(
    kind: String, auditID: UUID, payload: [String: JSONValue]
  ) throws {
    mutationLock.lock()
    defer { mutationLock.unlock() }
    let current = try record()
    let next = try current.appendingLifecycleAudit(
      kind: kind, auditID: auditID, payload: payload, now: now())
    try store.replace(next, expectedGeneration: current.generation)
  }

  private struct AuditRow {
    let kind: String
    let payload: [String: JSONValue]
  }

  private static func audit(_ record: RuntimeToolSelectionControlActionRecord) -> [AuditRow] {
    guard case .array(let rows)? = record.value["selectionAudit"] else { return [] }
    return rows.compactMap { row in
      guard case .object(let fields) = row,
        case .string(let kind)? = fields["kind"],
        case .object(let payload)? = fields["payload"]
      else { return nil }
      return AuditRow(kind: kind, payload: payload)
    }
  }

  private static func lastAudit(
    _ record: RuntimeToolSelectionControlActionRecord, kind: String
  ) -> AuditRow? {
    audit(record).last(where: { $0.kind == kind })
  }

  private static func hasAudit(
    _ record: RuntimeToolSelectionControlActionRecord, kinds: Set<String>
  ) -> Bool {
    audit(record).contains { kinds.contains($0.kind) }
  }
}
