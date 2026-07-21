import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckStorage
import Foundation

/// The manifest publisher is terminal/write-once, so lifecycle handling cannot
/// mutate it in place.  This value is the exact `serverLifecycle`
/// confirmation payload a finalization use case must place into its manifest;
/// it retains the durable audit correlation and the typed lifecycle Step ID.
package struct HDCServerLifecycleManifestConfirmation: Sendable, Equatable {
  let confirmationID: String
  let scopeHash: String
  let decision: String
  let actor: String
  let decidedAt: String
  let relatedStepIDs: [String]

  init(
    confirmationID: String,
    scopeHash: String,
    decision: String,
    actor: String,
    decidedAt: String,
    relatedStepIDs: [String]
  ) {
    self.confirmationID = confirmationID
    self.scopeHash = scopeHash
    self.decision = decision
    self.actor = actor
    self.decidedAt = decidedAt
    self.relatedStepIDs = relatedStepIDs.sorted()
  }
}

package struct HDCLifecycleRecoveryGate: Sendable, Equatable {
  let lifecycleAuditID: UUID
  let reason: String
}

/// Production adapter for host-wide HDC lifecycle evidence.  Each record is
/// synchronously durable through the M1-005 storage seam before this actor
/// returns.  The adapter does not manufacture workflow authority or alter the
/// locked manifest: it supplies the confirmation tuple for the eventual
/// write-once manifest publisher.
package actor DurableHDCServerLifecycleAuditStore:
  HDCServerLifecycleAuditStore, HDCServerLifecycleDispatchAuthorizing
{
  private let auditStore: any DurableSessionAuditAppending
  private let manifestPublisher: any SessionManifestPublishing
  private let timestamp: @Sendable () -> String

  init(
    auditStore: any DurableSessionAuditAppending,
    manifestPublisher: any SessionManifestPublishing,
    timestamp: @escaping @Sendable () -> String
  ) throws {
    guard auditStore.layout.sessionID == manifestPublisher.layout.sessionID,
      auditStore.layout.jobID == manifestPublisher.layout.jobID
    else {
      throw HDCServerLifecycleAdapterError.sessionIdentityMismatch
    }
    self.auditStore = auditStore
    self.manifestPublisher = manifestPublisher
    self.timestamp = timestamp
  }

  package func append(_ event: HDCServerLifecycleAuditEvent) async throws {
    switch event {
    case .impactPreview(let preview):
      try appendRecord(
        recordID: "hdc-preview-\(preview.id.uuidString)", auditID: preview.auditID,
        category: .preview, details: previewDetails(preview))
    case .confirmation(let confirmation):
      try appendRecord(
        recordID: "hdc-confirmation-\(confirmation.id.uuidString)", auditID: confirmation.auditID,
        category: .confirmation, details: confirmationDetails(confirmation))
    case .intent(let step):
      try appendRecord(
        recordID: "hdc-intent-\(step.id.uuidString)", auditID: step.auditID,
        category: .intent, details: intentDetails(step))
    case .outcome(let stepID, let auditID, let outcome):
      try appendRecord(
        recordID: "hdc-outcome-\(stepID.uuidString)", auditID: auditID,
        category: .outcome, details: outcomeDetails(stepID: stepID, outcome: outcome))
    case .reconciliation(let reconciliation):
      try appendRecord(
        recordID: "hdc-reconciliation-\(reconciliation.id.uuidString)",
        auditID: reconciliation.auditID,
        category: .outcome,
        details: reconciliationDetails(reconciliation))
    }
  }

  /// Terminal reconciliation uses the storage seam's synchronous full-sync
  /// transaction. This method is nonisolated by design: the Supervisor does
  /// not yield between its final scope check, this durable commit, and endpoint
  /// state application.
  package nonisolated func appendTerminalReconciliation(
    _ reconciliation: HDCServerLifecycleReconciliation
  ) throws {
    try appendRecord(
      recordID: "hdc-reconciliation-\(reconciliation.id.uuidString)",
      auditID: reconciliation.auditID,
      category: .outcome,
      details: reconciliationDetails(reconciliation))
  }

  /// Restores a manifest-compatible confirmation from the durable audit log.
  /// It remains available after actor/store recreation and therefore cannot be
  /// forged by transient in-memory state.
  func manifestConfirmation(auditID: UUID) -> HDCServerLifecycleManifestConfirmation? {
    guard let proof = try? durableProof(for: auditID) else { return nil }
    return proof.manifestConfirmation
  }

  /// Restores the conservative terminal interpretation of the lifecycle
  /// chain. A durable process success without its required reconciliation
  /// record is never replayed as success after a crash/reopen.
  func resolvedLifecycleOutcome(
    auditID: UUID
  ) -> HDCServerLifecycleExecutionOutcome? {
    guard let chain = try? durableExecutionChain(for: auditID) else { return nil }
    guard let historicalOutcome = chain.historicalOutcome else {
      return chain.launchWindowEntered
        ? .outcomeUnknown(
          reason: "durable lifecycle launch window has no persisted outcome")
        : nil
    }
    switch historicalOutcome {
    case .succeeded, .stopped:
      guard chain.launchWindowEntered, let reconciliation = chain.reconciliation else {
        return .outcomeUnknown(
          reason: "durable successful lifecycle outcome lacks terminal reconciliation")
      }
      guard
        postDispatchObservation(reconciliation.postDispatchObservation, proves: historicalOutcome)
      else {
        return .outcomeUnknown(
          reason: "durable lifecycle success lacks its matching post-dispatch observation")
      }
      return reconciliation.outwardOutcome
    case .failed:
      guard !chain.launchWindowEntered, chain.reconciliation == nil else {
        return .outcomeUnknown(
          reason: "durable failed lifecycle outcome does not prove pre-launch nonexecution")
      }
      return historicalOutcome
    case .outcomeUnknown:
      guard chain.launchWindowEntered, let reconciliation = chain.reconciliation,
        reconciliation.requiresReconcile,
        case .outcomeUnknown = reconciliation.outwardOutcome
      else {
        return .outcomeUnknown(
          reason: "durable uncertain lifecycle outcome lacks terminal reconciliation")
      }
      return reconciliation.outwardOutcome
    }
  }

  /// The process executor calls this immediately before it starts the child.
  /// This actor has no suspension point between replay, reuse rejection, and
  /// the synchronous durable actual-argv append, making a proof single-use
  /// across retries and actor/store recreation.
  package func consumeDispatchAuthorization(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand
  ) async throws -> Bool {
    guard actualCommand.stepID == step.id,
      actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint,
      let proof = try? durableProof(for: step.auditID),
      proof.stepID == step.id,
      proof.matches(step)
    else { return false }
    let records = try auditStore.replay(correlationID: step.auditID.uuidString)
    guard
      !records.contains(where: { record in
        record.details["eventType"] == .string("actualCommand")
          || record.details["eventType"] == .string("outcome")
      })
    else { return false }
    try appendRecord(
      recordID: "hdc-argv-\(actualCommand.stepID.uuidString)", auditID: actualCommand.auditID,
      category: .intent,
      details: [
        "eventType": .string("actualCommand"),
        "stepId": .string(actualCommand.stepID.uuidString),
        "executable": .string(actualCommand.executable.path),
        "argv": .array(actualCommand.arguments.map(JSONValue.string)),
        "endpoint": .string(actualCommand.endpoint.rawValue),
      ])
    return true
  }

  /// Persists the point after lease validation but before the process runner
  /// is entered. This record is single-use and bound to the already durable
  /// actual argv, allowing reopen/finalization to distinguish a proven
  /// pre-launch failure from an uncertain external effect.
  package func recordLaunchWindowEntry(
    of step: HDCServerLifecycleStep,
    actualCommand: HDCServerLifecycleActualCommand,
    executableIdentity: HDCServerLifecycleExecutableIdentityReceipt
  ) async throws -> Bool {
    let records = try auditStore.replay(correlationID: step.auditID.uuidString)
    let actualRecords = records.filter {
      $0.details["eventType"] == .string("actualCommand")
    }
    guard actualCommand.stepID == step.id,
      actualCommand.auditID == step.auditID,
      actualCommand.endpoint == step.endpoint,
      actualRecords.count == 1,
      let durableActual = actualRecords.first,
      durableActual.details.stringValue(for: "stepId") == actualCommand.stepID.uuidString,
      durableActual.details.stringValue(for: "executable") == actualCommand.executable.path,
      durableActual.details["argv"]
        == .array(actualCommand.arguments.map(JSONValue.string)),
      durableActual.details.stringValue(for: "endpoint") == actualCommand.endpoint.rawValue,
      executableIdentity.authorizedPath == actualCommand.executable.path,
      executableIdentity.inodeLaunchPath
        == "/.vol/\(executableIdentity.device)/\(executableIdentity.inode)",
      executableIdentity.fileSize >= 0,
      executableIdentity.sha256.count == 64,
      executableIdentity.sha256.utf8.allSatisfy({ byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
      }),
      !records.contains(where: { record in
        record.details["eventType"] == .string("launchWindowEntered")
          || record.details["eventType"] == .string("outcome")
      })
    else { return false }
    try appendRecord(
      recordID: "hdc-launch-window-\(step.id.uuidString)", auditID: step.auditID,
      category: .intent,
      details: [
        "eventType": .string("launchWindowEntered"),
        "stepId": .string(step.id.uuidString),
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
    return true
  }

  /// The terminal manifest is owned by the Session finalization workflow. This
  /// adapter actively publishes it through the supplied publisher only after
  /// verifying that the restored lifecycle confirmation is present verbatim.
  func publishFinalManifest(
    _ manifest: SessionManifestDocument,
    auditID: UUID
  ) throws -> PublishedSessionManifest {
    guard let completion = try? completedLifecycleProof(for: auditID) else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    let proof = completion.authorization
    guard
      manifest.confirmations.contains(where: { confirmation in
        confirmation.confirmationID == proof.manifestConfirmation.confirmationID
          && confirmation.kind == "serverLifecycle"
          && confirmation.scopeHash == proof.manifestConfirmation.scopeHash
          && confirmation.decision == proof.manifestConfirmation.decision
          && confirmation.actor == proof.manifestConfirmation.actor
          && confirmation.decidedAt == proof.manifestConfirmation.decidedAt
          && confirmation.relatedStepIDs == proof.manifestConfirmation.relatedStepIDs
      })
    else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    try validateManifestLifecycleStep(
      manifest, authorization: proof, outcome: completion.outcome)
    return try manifestPublisher.publish(manifest)
  }

  /// Builds and publishes the production terminal Session record from the
  /// durable lifecycle chain. Callers cannot supply a success-shaped Manifest:
  /// the typed Step, confirmation, outcome, toolchain, and journal correlation
  /// are reconstructed here before the write-once publication boundary.
  func finalizeTerminalLifecycle(
    coreStep: WorkflowStep,
    auditID: UUID,
    outcome: HDCServerLifecycleExecutionOutcome,
    toolchainIntent: JobToolchainIntent
  ) throws -> PublishedSessionManifest {
    let completion = try completedLifecycleProof(for: auditID)
    guard completion.outcome == outcome,
      coreStep.id == completion.authorization.stepID.uuidString,
      toolchainIntent.jobID == auditStore.layout.jobID
    else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    let manifest = try terminalManifest(
      coreStep: coreStep,
      authorization: completion.authorization,
      outcome: outcome,
      toolchainIntent: toolchainIntent)
    try appendTerminalJournal(
      manifest: manifest,
      coreStep: coreStep,
      authorization: completion.authorization,
      outcome: outcome)
    return try publishFinalManifest(manifest, auditID: auditID)
  }

  func replay(auditID: UUID) throws -> [SessionAuditRecord] {
    try auditStore.replay(correlationID: auditID.uuidString)
  }

  /// A fixed per-Session correlation provides a durable, reopenable dispatch
  /// barrier without requiring an in-memory list of lifecycle audit IDs. The
  /// barrier is armed before Supervisor dispatch and cleared only after a
  /// result is proven not to have an unresolved external effect.
  package nonisolated func lifecycleRecoveryGate() throws -> HDCLifecycleRecoveryGate? {
    let records = try auditStore.replay(correlationID: Self.recoveryGateCorrelationID)
    var pending: HDCLifecycleRecoveryGate?
    for record in records {
      guard record.details["eventType"] == .string("hdcLifecycleRecoveryGate"),
        let state = record.details.stringValue(for: "state"),
        let rawAuditID = record.details.stringValue(for: "lifecycleAuditId"),
        let auditID = UUID(uuidString: rawAuditID),
        let reason = record.details.stringValue(for: "reason")
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
      }
      switch state {
      case "pending":
        guard pending == nil else {
          throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
        }
        pending = HDCLifecycleRecoveryGate(lifecycleAuditID: auditID, reason: reason)
      case "resolved":
        guard pending?.lifecycleAuditID == auditID else {
          throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
        }
        pending = nil
      default:
        throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
      }
    }
    return pending
  }

  package nonisolated func armLifecycleRecoveryGate(
    lifecycleAuditID: UUID
  ) throws {
    guard try lifecycleRecoveryGate() == nil else {
      throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
    }
    try appendRecoveryGateRecord(
      state: "pending", lifecycleAuditID: lifecycleAuditID,
      reason: "A destructive HDC lifecycle dispatch may enter an external-effect window")
  }

  package nonisolated func resolveLifecycleRecoveryGate(
    lifecycleAuditID: UUID,
    reason: String
  ) throws {
    guard try lifecycleRecoveryGate()?.lifecycleAuditID == lifecycleAuditID else {
      throw HDCServerLifecycleAdapterError.durableLifecycleRecoveryGateInvalid
    }
    try appendRecoveryGateRecord(
      state: "resolved", lifecycleAuditID: lifecycleAuditID, reason: reason)
  }

  private struct DurableLifecycleProof {
    let confirmationID: String
    let scopeHash: String
    let stepID: UUID
    let action: String
    let endpoint: String
    let generation: Int64
    let ownership: String
    let decision: String
    let actor: String
    let confirmedAt: String

    var manifestConfirmation: HDCServerLifecycleManifestConfirmation {
      HDCServerLifecycleManifestConfirmation(
        confirmationID: confirmationID,
        scopeHash: scopeHash,
        decision: decision,
        actor: actor,
        decidedAt: confirmedAt,
        relatedStepIDs: [stepID.uuidString])
    }

    func matches(_ step: HDCServerLifecycleStep) -> Bool {
      step.action.rawValue == action
        && step.endpoint.rawValue == endpoint
        && step.expectedGeneration.map(Int64.init) == generation
        && step.expectedOwnership.rawValue == ownership
        && step.impactSnapshotHash == scopeHash
        && step.confirmationID?.uuidString == confirmationID
    }
  }

  private struct DurableReconciliationProof: Equatable {
    let outwardOutcome: HDCServerLifecycleExecutionOutcome
    let postDispatchObservation: HDCServerLifecyclePostDispatchObservation?
    let requiresReconcile: Bool
    let observedScopeHash: String?
  }

  private struct DurableExecutionChain {
    let authorization: DurableLifecycleProof
    let launchWindowEntered: Bool
    let historicalOutcome: HDCServerLifecycleExecutionOutcome?
    let reconciliation: DurableReconciliationProof?
  }

  private struct CompletedLifecycleProof {
    let authorization: DurableLifecycleProof
    let outcome: HDCServerLifecycleExecutionOutcome
  }

  private func terminalManifest(
    coreStep: WorkflowStep,
    authorization: DurableLifecycleProof,
    outcome: HDCServerLifecycleExecutionOutcome,
    toolchainIntent: JobToolchainIntent
  ) throws -> SessionManifestDocument {
    let status: String
    let disposition: String
    let stepCertainty: String
    let semanticResult: String
    let failure: JSONValue
    let warnings: JSONValue
    switch outcome {
    case .succeeded, .stopped:
      status = JobState.succeeded.rawValue
      disposition = "executed"
      stepCertainty = JournalOutcomeCertainty.confirmed.rawValue
      semanticResult = "succeeded"
      failure = .null
      warnings = .array([])
    case .failed(let reason):
      status = JobState.failed.rawValue
      disposition = "skipped"
      stepCertainty = "notApplicable"
      semanticResult = "notRun"
      failure = .object([
        "stage": .string("hdcServerLifecycle"),
        "code": .string("hdc.lifecycle.prelaunchFailed"),
        "summary": .string(reason),
      ])
      warnings = .array([.string(reason)])
    case .outcomeUnknown:
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }

    let encodedStep = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(coreStep))
    guard case .object(var manifestStep) = encodedStep else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    manifestStep["argumentsHash"] = .string(
      try JournalCanonicalJSON.argumentsHash(coreStep.arguments))
    manifestStep["sourceStepId"] = .null
    manifestStep["compensationTrigger"] = .null
    manifestStep["disposition"] = .string(disposition)
    manifestStep["outcomeCertainty"] = .string(stepCertainty)
    manifestStep["bindingRevision"] = .null
    manifestStep["semanticResult"] = .string(semanticResult)

    let confirmation = authorization.manifestConfirmation
    let endpointIdentity: JSONValue = .object([
      "endpoint": .string(authorization.endpoint),
      "serverGeneration": .integer(authorization.generation),
      "serverOwnership": .string(authorization.ownership),
    ])
    let completedAt = timestamp()
    let manifest: JSONValue = .object([
      "schemaVersion": .string("1.0.0"),
      "appVersion": .string("ArkDeckKit-M1-006"),
      "coreSpecBaseline": .string("CORE-2.0.0"),
      "platformProfile": .string("PLATFORM-MACOS@0.2.0"),
      "sessionId": .string(auditStore.layout.sessionID),
      "jobId": .string(auditStore.layout.jobID),
      "status": .string(status),
      "executionMode": .string(JobExecutionMode.execute.rawValue),
      "executionAuthority": .string("interactiveUser"),
      "outcomeCertainty": .string(JournalOutcomeCertainty.confirmed.rawValue),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(authorization.confirmedAt),
      "completedAt": .string(completedAt),
      "archivedAt": .null,
      "originalTarget": .object([
        "kind": .string("real"),
        "connectKey": .string(authorization.endpoint),
        "transport": .string("tcp"),
        "identitySnapshot": endpointIdentity,
      ]),
      "bindingHistory": .array([
        .object([
          "revision": .integer(1),
          "connectKey": .string(authorization.endpoint),
          "transport": .string("tcp"),
          "identitySnapshot": endpointIdentity,
          "evidence": .array([
            .string("durable server lifecycle confirmation \(authorization.confirmationID)")
          ]),
          "confirmedBy": .string("user"),
          "channelProtection": .string("unverifiedAssumeUnprotected"),
        ])
      ]),
      "toolchain": .object([
        "kind": .string(toolchainIntent.kind.rawValue),
        "source": .string(toolchainIntent.source.rawValue),
        "path": .string(toolchainIntent.executablePath),
        "sha256": .string(toolchainIntent.executableSHA256),
        "clientVersion": .string(diagnosticString(toolchainIntent.clientVersion)),
        "serverVersion": .string(diagnosticString(toolchainIntent.serverVersion)),
        "daemonVersion": diagnosticOptionalString(toolchainIntent.daemonVersion),
        "endpoint": .string(authorization.endpoint),
        "serverGeneration": .integer(authorization.generation),
        "serverOwnership": .string(authorization.ownership),
      ]),
      "workflow": .object([
        "kind": .string("hdcServerLifecycle"),
        "profileVersion": .string("OPENHARMONY-TOOLS@0.3.0"),
        "providerIdentity": .string("ArkDeck.HDCProcessLifecycleExecutor"),
      ]),
      "steps": .array([.object(manifestStep)]),
      "parameters": .array([]),
      "compensations": .array([]),
      "confirmations": .array([
        .object([
          "confirmationId": .string(confirmation.confirmationID),
          "kind": .string("serverLifecycle"),
          "scopeHash": .string(confirmation.scopeHash),
          "decision": .string(confirmation.decision),
          "actor": .string(confirmation.actor),
          "decidedAt": .string(confirmation.decidedAt),
          "relatedStepIds": .array(
            confirmation.relatedStepIDs.map(JSONValue.string)),
        ])
      ]),
      "artifacts": .array([]),
      "warnings": warnings,
      "failure": failure,
      "recovery": .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try SessionManifestDocument(data: encoder.encode(manifest))
  }

  private func appendTerminalJournal(
    manifest: SessionManifestDocument,
    coreStep: WorkflowStep,
    authorization: DurableLifecycleProof,
    outcome: HDCServerLifecycleExecutionOutcome
  ) throws {
    let layout = auditStore.layout
    if FileManager.default.fileExists(atPath: layout.journalURL.path) {
      let replay = try DurableJournalRecovery.inspect(url: layout.journalURL)
      if !replay.events.isEmpty {
        guard replay.finalized, replay.events.last?.kind == .finalized,
          replay.events.last?.payload.stringValue(for: "manifestSha256") == manifest.sha256
        else {
          throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
        }
        return
      }
    }

    let journal = try FileDurableJournal(url: layout.journalURL)
    let eventPrefix = "hdc-\(authorization.stepID.uuidString.lowercased())"
    let eventTimestamp = authorization.confirmedAt
    var sequence = 0
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "\(eventPrefix)-created", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: eventTimestamp, executionMode: JobExecutionMode.execute.rawValue,
        executionAuthority: "interactiveUser", coreBaseline: "CORE-2.0.0"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(eventPrefix)-preflight", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: eventTimestamp, from: .queued, to: .preflight,
        reason: "HDC lifecycle Session preflight"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(eventPrefix)-running", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: eventTimestamp, from: .preflight, to: .running,
        reason: "HDC lifecycle Session started"))
    sequence += 1

    if case .succeeded = outcome {
      sequence = try appendSuccessfulStepAttempt(
        journal: journal, coreStep: coreStep, authorization: authorization,
        sequence: sequence, timestamp: eventTimestamp, eventPrefix: eventPrefix)
    } else if case .stopped = outcome {
      sequence = try appendSuccessfulStepAttempt(
        journal: journal, coreStep: coreStep, authorization: authorization,
        sequence: sequence, timestamp: eventTimestamp, eventPrefix: eventPrefix)
    }

    let terminalState: JobState
    switch outcome {
    case .succeeded, .stopped: terminalState = .succeeded
    case .failed: terminalState = .failed
    case .outcomeUnknown:
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(eventPrefix)-finalizing", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: eventTimestamp, from: .running, to: .finalizing,
        reason: "HDC lifecycle reached a confirmed terminal outcome"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(eventPrefix)-terminal", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: eventTimestamp, from: .finalizing, to: terminalState,
        reason: "HDC lifecycle terminal evidence is ready for publication"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "\(eventPrefix)-finalized", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: timestamp(), kind: .finalized,
        payload: [
          "terminalStatus": .string(terminalState.rawValue),
          "manifestSha256": .string(manifest.sha256),
          "outcomeCertainty": .string(JournalOutcomeCertainty.confirmed.rawValue),
        ]))
  }

  private func appendSuccessfulStepAttempt(
    journal: FileDurableJournal,
    coreStep: WorkflowStep,
    authorization: DurableLifecycleProof,
    sequence: Int,
    timestamp: String,
    eventPrefix: String
  ) throws -> Int {
    let intentEventID = "\(eventPrefix)-step-intent"
    try journal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: intentEventID, sequence: sequence,
        sessionID: auditStore.layout.sessionID, jobID: auditStore.layout.jobID,
        timestamp: timestamp, step: coreStep,
        target: JournalTarget(
          scope: "host", targetID: authorization.endpoint,
          connectKey: nil, identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "\(eventPrefix)-step-outcome", sequence: sequence + 1,
        sessionID: auditStore.layout.sessionID, jobID: auditStore.layout.jobID,
        timestamp: timestamp, stepID: coreStep.id, attempt: 1,
        correlatesToIntentEventID: intentEventID,
        result: "succeeded", outcomeCertainty: .confirmed,
        semanticCode: "hdc.lifecycle.confirmed",
        summary: "HDC server lifecycle outcome confirmed by registered observation"))
    return sequence + 2
  }

  private func diagnosticString(_ evidence: JobToolchainEvidence<String>) -> String {
    switch evidence {
    case .known(let value): value
    case .unknown(let reason): "unknown (\(reason))"
    case .unverified(let value, let reason):
      value.map { "unverified \($0) (\(reason))" } ?? "unverified (\(reason))"
    }
  }

  private func diagnosticOptionalString(
    _ evidence: JobToolchainEvidence<String>
  ) -> JSONValue {
    guard case .known(let value) = evidence else { return .null }
    return .string(value)
  }

  private func validateManifestLifecycleStep(
    _ manifest: SessionManifestDocument,
    authorization: DurableLifecycleProof,
    outcome: HDCServerLifecycleExecutionOutcome
  ) throws {
    let expectedJobStatus: String
    let expectedDisposition: String
    let expectedOutcomeCertainty: String
    let expectedSemanticResult: String
    switch outcome {
    case .succeeded, .stopped:
      expectedJobStatus = "succeeded"
      expectedDisposition = "executed"
      expectedOutcomeCertainty = "confirmed"
      expectedSemanticResult = "succeeded"
    case .failed:
      expectedJobStatus = "failed"
      expectedDisposition = "skipped"
      expectedOutcomeCertainty = "notApplicable"
      expectedSemanticResult = "notRun"
    case .outcomeUnknown:
      // An unknown external effect is a recovery state, never a directly
      // finalizable lifecycle result.
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }

    let decoded = try JSONDecoder().decode(JSONValue.self, from: manifest.canonicalData)
    guard case .object(let root) = decoded,
      root.stringValue(for: "status") == expectedJobStatus,
      root.stringValue(for: "executionMode") == "execute",
      root.stringValue(for: "outcomeCertainty") == "confirmed",
      case .array(let steps) = root["steps"]
    else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
    let matchingSteps = steps.compactMap { value -> [String: JSONValue]? in
      guard case .object(let step) = value,
        step.stringValue(for: "id") == authorization.stepID.uuidString
      else { return nil }
      return step
    }
    let expectedArguments: JSONValue = .object([
      "action": .string(authorization.action),
      "endpoint": .string(authorization.endpoint),
      "expectedGeneration": .integer(authorization.generation),
      "expectedOwnership": .string(authorization.ownership),
      "impactSnapshotHash": .string(authorization.scopeHash),
      "confirmationId": .string(authorization.confirmationID),
    ])
    guard matchingSteps.count == 1, let step = matchingSteps.first,
      step.stringValue(for: "kind") == WorkflowStepKind.mutateHDCServerLifecycle.rawValue,
      step.stringValue(for: "effect") == WorkflowEffect.destructive.rawValue,
      step.stringValue(for: "cancellation") == WorkflowCancellationPolicy.atSafeBoundary.rawValue,
      step.stringValue(for: "bindingRequirement") == WorkflowBindingRequirement.none.rawValue,
      step["arguments"] == expectedArguments,
      step["compensationDescriptors"] == .array([]),
      step["sourceStepId"] == .null,
      step["compensationTrigger"] == .null,
      step.stringValue(for: "disposition") == expectedDisposition,
      step.stringValue(for: "outcomeCertainty") == expectedOutcomeCertainty,
      step.stringValue(for: "semanticResult") == expectedSemanticResult
    else {
      throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
    }
  }

  private func durableProof(for auditID: UUID) throws -> DurableLifecycleProof {
    let records = try auditStore.replay(correlationID: auditID.uuidString)
    guard
      let previewIndex = records.firstIndex(
        where: { $0.details["eventType"] == .string("impactPreview") }),
      let confirmationIndex = records.firstIndex(
        where: { $0.details["eventType"] == .string("confirmation") }),
      let intentIndex = records.firstIndex(where: { $0.details["eventType"] == .string("intent") }),
      previewIndex < confirmationIndex,
      confirmationIndex < intentIndex,
      records.filter({ $0.details["eventType"] == .string("impactPreview") }).count == 1,
      records.filter({ $0.details["eventType"] == .string("confirmation") }).count == 1,
      records.filter({ $0.details["eventType"] == .string("intent") }).count == 1,
      let preview = Optional(records[previewIndex]),
      let confirmation = Optional(records[confirmationIndex]),
      let intent = Optional(records[intentIndex]),
      let previewID = preview.details.stringValue(for: "previewId"),
      confirmation.details.stringValue(for: "previewId") == previewID,
      let confirmationID = confirmation.details.stringValue(for: "confirmationId"),
      intent.details.stringValue(for: "confirmationId") == confirmationID,
      let scopeHash = preview.details.stringValue(for: "scopeHash"),
      confirmation.details.stringValue(for: "scopeHash") == scopeHash,
      intent.details.stringValue(for: "impactSnapshotHash") == scopeHash,
      let action = preview.details.stringValue(for: "action"),
      confirmation.details.stringValue(for: "action") == action,
      intent.details.stringValue(for: "action") == action,
      let endpoint = preview.details.stringValue(for: "endpoint"),
      confirmation.details.stringValue(for: "endpoint") == endpoint,
      intent.details.stringValue(for: "endpoint") == endpoint,
      let generation = preview.details.integerValue(for: "generation"),
      confirmation.details.integerValue(for: "generation") == generation,
      intent.details.integerValue(for: "expectedGeneration") == generation,
      let ownership = preview.details.stringValue(for: "ownership"),
      confirmation.details.stringValue(for: "ownership") == ownership,
      intent.details.stringValue(for: "expectedOwnership") == ownership,
      let decision = confirmation.details.stringValue(for: "decision"),
      decision == "accepted",
      let actor = confirmation.details.stringValue(for: "actor"),
      actor == "user",
      let stepIDText = intent.details.stringValue(for: "stepId"),
      let stepID = UUID(uuidString: stepIDText)
    else {
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }
    return DurableLifecycleProof(
      confirmationID: confirmationID, scopeHash: scopeHash, stepID: stepID, action: action,
      endpoint: endpoint, generation: generation, ownership: ownership,
      decision: decision, actor: actor, confirmedAt: confirmation.timestamp)
  }

  private func durableExecutionChain(for auditID: UUID) throws -> DurableExecutionChain {
    let authorization = try durableProof(for: auditID)
    let records = try auditStore.replay(correlationID: auditID.uuidString)
    let actualIndices = records.indices.filter {
      records[$0].details["eventType"] == .string("actualCommand")
    }
    let outcomeIndices = records.indices.filter {
      records[$0].details["eventType"] == .string("outcome")
    }
    let launchWindowIndices = records.indices.filter {
      records[$0].details["eventType"] == .string("launchWindowEntered")
    }
    guard actualIndices.count == 1, outcomeIndices.count <= 1,
      launchWindowIndices.count <= 1,
      let intentIndex = records.firstIndex(where: { $0.details["eventType"] == .string("intent") }),
      let actualIndex = actualIndices.first,
      intentIndex < actualIndex
    else {
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }

    let actual = records[actualIndex]
    guard actual.details.stringValue(for: "stepId") == authorization.stepID.uuidString,
      actual.details.stringValue(for: "endpoint") == authorization.endpoint,
      let executable = actual.details.stringValue(for: "executable"),
      executable.hasPrefix("/"),
      !executable.contains("\0"),
      actual.details["argv"]
        == expectedLifecycleArguments(
          action: authorization.action, endpoint: authorization.endpoint)
    else {
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }

    let outcomeIndex = outcomeIndices.first
    let historicalOutcome: HDCServerLifecycleExecutionOutcome?
    if let outcomeIndex {
      guard actualIndex < outcomeIndex,
        records[outcomeIndex].details.stringValue(for: "stepId")
          == authorization.stepID.uuidString,
        let parsedOutcome = lifecycleOutcome(from: records[outcomeIndex].details)
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      historicalOutcome = parsedOutcome
    } else {
      historicalOutcome = nil
    }

    let launchWindowEntered: Bool
    if let launchWindowIndex = launchWindowIndices.first {
      guard actualIndex < launchWindowIndex,
        outcomeIndex.map({ launchWindowIndex < $0 }) ?? true
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      let launchWindow = records[launchWindowIndex]
      guard launchWindow.details.stringValue(for: "stepId") == authorization.stepID.uuidString,
        launchWindow.details.stringValue(for: "endpoint") == authorization.endpoint,
        launchWindow.details.stringValue(for: "executable") == executable,
        launchWindow.details["argv"] == actual.details["argv"],
        launchWindow.details.stringValue(for: "authorizedExecutable") == executable,
        let inodeLaunchPath = launchWindow.details.stringValue(for: "inodeLaunchPath"),
        let device = launchWindow.details.stringValue(for: "executableDevice"),
        let inode = launchWindow.details.stringValue(for: "executableInode"),
        inodeLaunchPath == "/.vol/\(device)/\(inode)",
        UInt64(device) != nil,
        UInt64(inode) != nil,
        let fileSize = launchWindow.details.integerValue(for: "executableFileSize"),
        fileSize >= 0,
        let mode = launchWindow.details.stringValue(for: "executableMode"),
        UInt32(mode) != nil,
        let executableSHA256 = launchWindow.details.stringValue(for: "executableSha256"),
        executableSHA256.count == 64,
        executableSHA256.utf8.allSatisfy({ byte in
          (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        })
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      launchWindowEntered = true
    } else {
      launchWindowEntered = false
    }

    let reconciliationIndices = records.indices.filter {
      records[$0].details["eventType"] == .string("reconciliation")
    }
    var reconciliation: DurableReconciliationProof?
    if !reconciliationIndices.isEmpty {
      guard let historicalOutcome, let outcomeIndex,
        reconciliationIndices.count == 1,
        let reconciliationIndex = reconciliationIndices.first,
        outcomeIndex < reconciliationIndex
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      let details = records[reconciliationIndex].details
      guard details.stringValue(for: "stepId") == authorization.stepID.uuidString,
        details.stringValue(for: "expectedScopeHash") == authorization.scopeHash,
        lifecycleOutcome(from: details) == historicalOutcome,
        let outwardOutcome = lifecycleOutcome(from: details, prefix: "outward"),
        case .bool(let requiresReconcile) = details["requiresReconcile"]
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      let observedScopeHash: String?
      if case .object(let observedScope) = details["observedScope"] {
        observedScopeHash = observedScope.stringValue(for: "scopeHash")
      } else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      let postDispatchObservation = try postDispatchObservation(from: details)
      reconciliation = DurableReconciliationProof(
        outwardOutcome: outwardOutcome,
        postDispatchObservation: postDispatchObservation,
        requiresReconcile: requiresReconcile,
        observedScopeHash: observedScopeHash)
    }
    return DurableExecutionChain(
      authorization: authorization,
      launchWindowEntered: launchWindowEntered,
      historicalOutcome: historicalOutcome,
      reconciliation: reconciliation)
  }

  private func completedLifecycleProof(for auditID: UUID) throws -> CompletedLifecycleProof {
    let chain = try durableExecutionChain(for: auditID)
    guard let historicalOutcome = chain.historicalOutcome else {
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }
    switch historicalOutcome {
    case .succeeded, .stopped:
      guard chain.launchWindowEntered,
        let reconciliation = chain.reconciliation,
        !reconciliation.requiresReconcile,
        reconciliation.observedScopeHash == chain.authorization.scopeHash,
        reconciliation.outwardOutcome == historicalOutcome,
        postDispatchObservation(reconciliation.postDispatchObservation, proves: historicalOutcome)
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      return CompletedLifecycleProof(
        authorization: chain.authorization, outcome: reconciliation.outwardOutcome)
    case .failed:
      guard !chain.launchWindowEntered, chain.reconciliation == nil else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      return CompletedLifecycleProof(
        authorization: chain.authorization, outcome: historicalOutcome)
    case .outcomeUnknown:
      guard chain.launchWindowEntered,
        let reconciliation = chain.reconciliation,
        reconciliation.requiresReconcile,
        case .outcomeUnknown = reconciliation.outwardOutcome
      else {
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
      return CompletedLifecycleProof(
        authorization: chain.authorization, outcome: reconciliation.outwardOutcome)
    }
  }

  private func expectedLifecycleArguments(action: String, endpoint: String) -> JSONValue? {
    switch action {
    case HDCServerLifecycleAction.restartConfirmedGeneration.rawValue:
      return .array([.string("-s"), .string(endpoint), .string("kill"), .string("-r")])
    case HDCServerLifecycleAction.stopConfirmedGeneration.rawValue:
      return .array([.string("-s"), .string(endpoint), .string("kill")])
    case HDCServerLifecycleAction.startManaged.rawValue:
      return nil
    default:
      return nil
    }
  }

  private func postDispatchObservation(
    _ observation: HDCServerLifecyclePostDispatchObservation?,
    proves outcome: HDCServerLifecycleExecutionOutcome
  ) -> Bool {
    switch (outcome, observation) {
    case (.succeeded(let resultingGeneration), .generation(let observedGeneration)):
      return resultingGeneration == observedGeneration
    case (.stopped, .unavailable):
      return true
    case (.failed, _), (.outcomeUnknown, _), (_, nil), (.succeeded, .unavailable),
      (.stopped, .generation):
      return false
    }
  }

  private func lifecycleOutcome(
    from details: [String: JSONValue], prefix: String = ""
  ) -> HDCServerLifecycleExecutionOutcome? {
    let resultKey = prefixed("result", by: prefix)
    let generationKey = prefixed("resultingGeneration", by: prefix)
    let reasonKey = prefixed("reason", by: prefix)
    guard let result = details.stringValue(for: resultKey) else { return nil }
    switch result {
    case "succeeded":
      guard let generation = details.integerValue(for: generationKey),
        let exactGeneration = Int(exactly: generation)
      else { return nil }
      return .succeeded(resultingGeneration: exactGeneration)
    case "stopped":
      return .stopped
    case "failed":
      guard let reason = details.stringValue(for: reasonKey) else { return nil }
      return .failed(reason: reason)
    case "outcomeUnknown":
      guard let reason = details.stringValue(for: reasonKey) else { return nil }
      return .outcomeUnknown(reason: reason)
    default:
      return nil
    }
  }

  nonisolated private func appendRecord(
    recordID: String,
    auditID: UUID,
    category: SessionAuditCategory,
    details: [String: JSONValue]
  ) throws {
    let correlationID = auditID.uuidString
    let record = try SessionAuditRecord(
      recordID: recordID, auditID: correlationID, correlationID: correlationID,
      sessionID: auditStore.layout.sessionID, jobID: auditStore.layout.jobID,
      category: category, timestamp: timestamp(), details: details)
    try auditStore.appendAndSynchronize(record)
  }

  nonisolated private static let recoveryGateCorrelationID =
    "00000000-0000-0000-0000-000000000006"

  nonisolated private func appendRecoveryGateRecord(
    state: String,
    lifecycleAuditID: UUID,
    reason: String
  ) throws {
    try auditStore.appendAndSynchronize(
      SessionAuditRecord(
        recordID: "hdc-recovery-gate-\(state)-\(lifecycleAuditID.uuidString)",
        auditID: Self.recoveryGateCorrelationID,
        correlationID: Self.recoveryGateCorrelationID,
        sessionID: auditStore.layout.sessionID,
        jobID: auditStore.layout.jobID,
        category: state == "pending" ? .intent : .outcome,
        timestamp: timestamp(),
        details: [
          "eventType": .string("hdcLifecycleRecoveryGate"),
          "state": .string(state),
          "lifecycleAuditId": .string(lifecycleAuditID.uuidString),
          "reason": .string(reason),
        ]))
  }

  private func previewDetails(_ preview: HDCServerLifecycleImpactPreview) -> [String: JSONValue] {
    let snapshot = preview.snapshot
    return [
      "eventType": .string("impactPreview"), "previewId": .string(preview.id.uuidString),
      "action": .string(snapshot.action.rawValue), "endpoint": .string(snapshot.endpoint.rawValue),
      "generation": .integer(Int64(snapshot.generation)),
      "ownership": .string(snapshot.ownership.rawValue),
      "affectedDeviceCoordinators": .array(
        snapshot.affectedDeviceCoordinators.map(JSONValue.string)),
      "affectedJobs": .array(snapshot.affectedJobs.map(JSONValue.string)),
      "otherClientDetection": .string(String(describing: snapshot.otherClientDetection)),
      "expectedInterruption": .string(snapshot.expectedInterruption),
      "recoveryPath": .string(snapshot.recoveryPath), "scopeHash": .string(snapshot.scopeHash),
    ]
  }

  private func confirmationDetails(_ confirmation: HDCServerLifecycleConfirmation) -> [String:
    JSONValue]
  {
    [
      "eventType": .string("confirmation"), "confirmationId": .string(confirmation.id.uuidString),
      "previewId": .string(confirmation.previewID.uuidString),
      "action": .string(confirmation.action.rawValue),
      "endpoint": .string(confirmation.endpoint.rawValue),
      "generation": .integer(Int64(confirmation.generation)),
      "ownership": .string(confirmation.ownership.rawValue),
      "scopeHash": .string(confirmation.scopeHash),
      "decision": .string("accepted"),
      "actor": .string("user"),
    ]
  }

  private func intentDetails(_ step: HDCServerLifecycleStep) -> [String: JSONValue] {
    [
      "eventType": .string("intent"), "stepId": .string(step.id.uuidString),
      "action": .string(step.action.rawValue), "endpoint": .string(step.endpoint.rawValue),
      "expectedGeneration": step.expectedGeneration.map { .integer(Int64($0)) } ?? .null,
      "expectedOwnership": .string(step.expectedOwnership.rawValue),
      "impactSnapshotHash": .string(step.impactSnapshotHash),
      "confirmationId": step.confirmationID.map { .string($0.uuidString) } ?? .null,
    ]
  }

  nonisolated private func outcomeDetails(
    stepID: UUID, outcome: HDCServerLifecycleExecutionOutcome
  ) -> [String: JSONValue] {
    var details: [String: JSONValue] = [
      "eventType": .string("outcome"), "stepId": .string(stepID.uuidString),
    ]
    appendOutcome(outcome, to: &details)
    return details
  }

  nonisolated private func appendOutcome(
    _ outcome: HDCServerLifecycleExecutionOutcome,
    prefix: String = "",
    to details: inout [String: JSONValue]
  ) {
    let resultKey = prefixed("result", by: prefix)
    let generationKey = prefixed("resultingGeneration", by: prefix)
    let reasonKey = prefixed("reason", by: prefix)
    switch outcome {
    case .succeeded(let generation):
      details[resultKey] = .string("succeeded")
      details[generationKey] = .integer(Int64(generation))
    case .stopped:
      details[resultKey] = .string("stopped")
    case .failed(let reason):
      details[resultKey] = .string("failed")
      details[reasonKey] = .string(reason)
    case .outcomeUnknown(let reason):
      details[resultKey] = .string("outcomeUnknown")
      details[reasonKey] = .string(reason)
    }
  }

  nonisolated private func reconciliationDetails(
    _ reconciliation: HDCServerLifecycleReconciliation
  ) -> [String: JSONValue] {
    var details = outcomeDetails(
      stepID: reconciliation.stepID, outcome: reconciliation.historicalOutcome)
    details["eventType"] = .string("reconciliation")
    details["expectedScopeHash"] = .string(reconciliation.expectedScopeHash)
    appendOutcome(reconciliation.outwardOutcome, prefix: "outward", to: &details)
    details["requiresReconcile"] = .bool(reconciliation.requiresReconcile)
    details["observedScope"] = .object(observedScopeDetails(reconciliation.observedScope))
    details["postDispatchObservation"] = postDispatchObservationDetails(
      reconciliation.postDispatchObservation)
    // Keep reconciliation metadata separate from an outcome's own `reason`.
    // Otherwise an outcomeUnknown reconciliation would overwrite the
    // historical outcome tuple and make the durable chain unverifiable.
    details["reconciliationReason"] = .string(reconciliation.reason)
    return details
  }

  nonisolated private func postDispatchObservationDetails(
    _ observation: HDCServerLifecyclePostDispatchObservation?
  ) -> JSONValue {
    switch observation {
    case .generation(let generation):
      return .object([
        "kind": .string("generation"),
        "generation": .integer(Int64(generation)),
      ])
    case .unavailable:
      return .object(["kind": .string("unavailable")])
    case nil:
      return .null
    }
  }

  private func postDispatchObservation(
    from details: [String: JSONValue]
  ) throws -> HDCServerLifecyclePostDispatchObservation? {
    guard let value = details["postDispatchObservation"] else {
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }
    switch value {
    case .null:
      return nil
    case .object(let object):
      switch object.stringValue(for: "kind") {
      case "generation":
        guard object.count == 2,
          let value = object.integerValue(for: "generation"),
          let generation = Int(exactly: value)
        else {
          throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
        }
        return .generation(generation)
      case "unavailable":
        guard object.count == 1 else {
          throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
        }
        return .unavailable
      default:
        throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
      }
    default:
      throw HDCServerLifecycleAdapterError.durableLifecycleProofMissingOrMismatched
    }
  }

  nonisolated private func observedScopeDetails(
    _ scope: HDCServerLifecycleObservedScope
  ) -> [String: JSONValue] {
    [
      "action": .string(scope.action.rawValue),
      "endpoint": .string(scope.endpoint.rawValue),
      "statePresent": .bool(scope.health != nil),
      "health": scope.health.map { .string($0.rawValue) } ?? .null,
      "version": probeDetails(scope.version),
      "generation": scope.generation.map { .integer(Int64($0)) } ?? .null,
      "generationEvidence": probeDetails(scope.generationEvidence),
      "ownership": scope.ownership.map { .string($0.rawValue) } ?? .null,
      "affectedDeviceCoordinators": .array(
        scope.affectedDeviceCoordinators.map(JSONValue.string)),
      "affectedJobs": .array(scope.affectedJobs.map(JSONValue.string)),
      "otherClientDetection": otherClientDetails(scope.otherClientDetection),
      "criticalJobs": .array(
        scope.criticalJobs.map { job in
          .object([
            "jobId": .string(job.jobID),
            "stepId": .string(job.stepID),
            "safeBoundaryAction": .string(job.safeBoundaryAction),
          ])
        }),
      "impactReliable": .bool(scope.impactReliable),
      "scopeHash": scope.scopeHash.map(JSONValue.string) ?? .null,
    ]
  }

  nonisolated private func probeDetails(_ probe: HDCProbeValue<String>?) -> JSONValue {
    guard let probe else { return .object(["certainty": .string("absent")]) }
    switch probe {
    case .known(let value):
      return .object(["certainty": .string("known"), "value": .string(value)])
    case .unknown(let reason):
      return .object(["certainty": .string("unknown"), "reason": .string(reason)])
    }
  }

  nonisolated private func probeDetails(_ probe: HDCProbeValue<Int>?) -> JSONValue {
    guard let probe else { return .object(["certainty": .string("absent")]) }
    switch probe {
    case .known(let value):
      return .object(["certainty": .string("known"), "value": .integer(Int64(value))])
    case .unknown(let reason):
      return .object(["certainty": .string("unknown"), "reason": .string(reason)])
    }
  }

  nonisolated private func otherClientDetails(
    _ detection: HDCServerOtherClientDetection
  ) -> JSONValue {
    switch detection {
    case .detected(let clients):
      return .object([
        "kind": .string("detected"),
        "clients": .array(clients.sorted().map(JSONValue.string)),
      ])
    case .noneDetectedExternalClientsMayStillExist:
      return .object([
        "kind": .string("noneDetectedExternalClientsMayStillExist"), "clients": .array([]),
      ])
    case .unavailableExternalClientsMayStillExist:
      return .object([
        "kind": .string("unavailableExternalClientsMayStillExist"), "clients": .array([]),
      ])
    }
  }

  nonisolated private func prefixed(_ key: String, by prefix: String) -> String {
    guard !prefix.isEmpty else { return key }
    return prefix + key.prefix(1).uppercased() + key.dropFirst()
  }
}

enum HDCServerLifecycleAdapterError: Error, Sendable, Equatable {
  case sessionIdentityMismatch
  case durableLifecycleProofMissingOrMismatched
  case manifestConfirmationMissingOrMismatched
  case durableToolchainIntentMissingOrMismatched
  case durableLifecycleRecoveryGateInvalid
}

/// Stores the immutable Core Job toolchain intent before any lifecycle Step
/// can be authorized, then binds each Core lifecycle Step to that exact
/// reopened value. The generic Session audit seam supplies the full-sync and
/// reopen guarantees; no Workflows actor memory is accepted as evidence.
package final class DurableHDCJobToolchainIntentStore: @unchecked Sendable {
  private let auditStore: any DurableSessionAuditAppending
  private let timestamp: @Sendable () -> String
  private let lock = NSLock()

  package init(
    auditStore: any DurableSessionAuditAppending,
    timestamp: @escaping @Sendable () -> String
  ) {
    self.auditStore = auditStore
    self.timestamp = timestamp
  }

  package func persistOrReopen(_ requested: JobToolchainIntent) throws -> JobToolchainIntent {
    try lock.withLock {
      let records = try auditStore.replay(correlationID: requested.jobID)
      let intents = records.filter {
        $0.details["eventType"] == .string("jobToolchainIntent")
      }
      if let existing = intents.first {
        guard intents.count == 1,
          let decoded = try? decode(JobToolchainIntent.self, from: existing.details["intent"]),
          sameFixedToolchain(decoded, requested)
        else {
          throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
        }
        return decoded
      }
      let details: [String: JSONValue] = [
        "eventType": .string("jobToolchainIntent"),
        "intent": try encode(requested),
      ]
      try auditStore.appendAndSynchronize(
        SessionAuditRecord(
          recordID: "hdc-toolchain-\(requested.id.uuidString)",
          auditID: requested.id.uuidString,
          correlationID: requested.jobID,
          sessionID: auditStore.layout.sessionID,
          jobID: auditStore.layout.jobID,
          category: .intent,
          timestamp: timestamp(),
          details: details))
      return requested
    }
  }

  package func bind(
    _ binding: JobToolchainIntentBinding,
    auditID: UUID
  ) throws {
    try lock.withLock {
      let intentRecords = try auditStore.replay(correlationID: binding.jobID).filter {
        $0.details["eventType"] == .string("jobToolchainIntent")
      }
      guard intentRecords.count == 1,
        let durableIntent = try? decode(
          JobToolchainIntent.self, from: intentRecords[0].details["intent"]),
        durableIntent == binding.intent
      else {
        throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
      }
      let records = try auditStore.replay(correlationID: auditID.uuidString)
      guard
        !records.contains(where: {
          $0.details["eventType"] == .string("jobToolchainIntentBinding")
        })
      else {
        throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
      }
      try auditStore.appendAndSynchronize(
        SessionAuditRecord(
          recordID: "hdc-toolchain-binding-\(binding.step.id)",
          auditID: auditID.uuidString,
          correlationID: auditID.uuidString,
          sessionID: auditStore.layout.sessionID,
          jobID: auditStore.layout.jobID,
          category: .intent,
          timestamp: timestamp(),
          details: [
            "eventType": .string("jobToolchainIntentBinding"),
            "intentId": .string(binding.intent.id.uuidString),
            "binding": try encode(binding),
          ]))
    }
  }

  package func reopen(jobID: String) throws -> JobToolchainIntent {
    try lock.withLock {
      let records = try auditStore.replay(correlationID: jobID).filter {
        $0.details["eventType"] == .string("jobToolchainIntent")
      }
      guard records.count == 1,
        let intent = try? decode(JobToolchainIntent.self, from: records[0].details["intent"])
      else {
        throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
      }
      return intent
    }
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  private func decode<Value: Decodable>(_: Value.Type, from value: JSONValue?) throws -> Value {
    guard let value else {
      throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
    }
    return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }

  private func sameFixedToolchain(
    _ lhs: JobToolchainIntent,
    _ rhs: JobToolchainIntent
  ) -> Bool {
    lhs.jobID == rhs.jobID && lhs.kind == rhs.kind
      && lhs.executablePath == rhs.executablePath && lhs.source == rhs.source
      && lhs.executableSHA256 == rhs.executableSHA256
      && lhs.platformTrust == rhs.platformTrust && lhs.clientVersion == rhs.clientVersion
      && lhs.serverVersion == rhs.serverVersion && lhs.daemonVersion == rhs.daemonVersion
      && lhs.endpoint == rhs.endpoint && lhs.serverGeneration == rhs.serverGeneration
  }
}

/// Closed production mutation use case. It is the only Workflows owner of the
/// concrete HDC process executor, Core Job dispatch state, durable toolchain
/// binding, Supervisor dispatch, and terminal manifest adapter.
package actor HDCSessionLifecycleUseCase {
  private let supervisor: HDCServerSupervisor
  private let executor: HDCProcessLifecycleExecutor
  private let intentStore: DurableHDCJobToolchainIntentStore
  private let toolchainIntent: JobToolchainIntent
  private let finalizer: DurableHDCServerLifecycleAuditStore
  private var jobStateMachine: JobStateMachine

  package init(
    supervisor: HDCServerSupervisor,
    executor: HDCProcessLifecycleExecutor,
    intentStore: DurableHDCJobToolchainIntentStore,
    toolchainIntent: JobToolchainIntent,
    finalizer: DurableHDCServerLifecycleAuditStore
  ) throws {
    let machine: JobStateMachine
    if try finalizer.lifecycleRecoveryGate() != nil {
      machine = try JobStateMachine(
        mode: .execute, recoveringFrom: .running, finding: .missingDestructiveOutcome)
    } else {
      var running = JobStateMachine(mode: .execute)
      try running.handle(.startPreflight)
      try running.handle(.preflightPassed)
      machine = running
    }
    self.supervisor = supervisor
    self.executor = executor
    self.intentStore = intentStore
    self.toolchainIntent = toolchainIntent
    self.finalizer = finalizer
    jobStateMachine = machine
  }

  package func dispatch(
    confirmation: HDCServerLifecycleConfirmation
  ) async -> HDCServerLifecycleDispatchResult {
    do {
      if let gate = try finalizer.lifecycleRecoveryGate() {
        return .blocked(.recoveryRequired(reason: gate.reason))
      }
    } catch {
      return .blocked(.auditPersistenceFailed)
    }

    let coreStep: WorkflowStep
    do {
      coreStep = try HDCServerLifecycleStep.coreWorkflowStep(confirmation: confirmation)
      _ = try jobStateMachine.authorizeDispatch(of: coreStep)
      try intentStore.bind(
        JobToolchainIntentBinding(
          jobID: toolchainIntent.jobID, intent: toolchainIntent, step: coreStep),
        auditID: confirmation.auditID)
      try finalizer.armLifecycleRecoveryGate(lifecycleAuditID: confirmation.auditID)
    } catch {
      if let activeStep = jobStateMachine.activeStep {
        try? jobStateMachine.completeAuthorizedStep(id: activeStep.id)
      }
      return .blocked(.auditPersistenceFailed)
    }
    let result = await supervisor.dispatch(
      confirmationID: confirmation.id, coreStep: coreStep, using: executor)
    switch result {
    case .completed(.outcomeUnknown(let reason)):
      _ = try? jobStateMachine.handle(.externalOutcomeOrIdentityUnknown)
      return .completed(.outcomeUnknown(reason: reason))
    case .completed(let outcome):
      do {
        try jobStateMachine.completeAuthorizedStep(id: coreStep.id)
        switch outcome {
        case .succeeded, .stopped:
          try jobStateMachine.handle(.workflowCompleted)
        case .failed(let reason):
          try jobStateMachine.handle(
            .confirmedFailure(
              WorkflowFailure(
                classification: .process,
                code: "hdc.lifecycle.prelaunchFailed",
                summary: reason)))
        case .outcomeUnknown:
          throw HDCServerLifecycleAdapterError.manifestConfirmationMissingOrMismatched
        }
        _ = try await finalizer.finalizeTerminalLifecycle(
          coreStep: coreStep,
          auditID: confirmation.auditID,
          outcome: outcome,
          toolchainIntent: toolchainIntent)
        try finalizer.resolveLifecycleRecoveryGate(
          lifecycleAuditID: confirmation.auditID,
          reason: "Lifecycle terminal Manifest was durably published: \(outcome)")
        try jobStateMachine.handle(.finalizationCompleted)
        return result
      } catch {
        return .completed(
          .outcomeUnknown(
            reason:
              "Lifecycle result could not complete the durable terminal Session finalizer"))
      }
    case .blocked(let block):
      do {
        try finalizer.resolveLifecycleRecoveryGate(
          lifecycleAuditID: confirmation.auditID,
          reason: "Supervisor blocked before lifecycle process dispatch: \(block)")
        try jobStateMachine.completeAuthorizedStep(id: coreStep.id)
        return result
      } catch {
        _ = try? jobStateMachine.handle(.externalOutcomeOrIdentityUnknown)
        return .blocked(.auditPersistenceFailed)
      }
    }
  }

  package func publishFinalManifest(
    _ manifest: SessionManifestDocument,
    auditID: UUID
  ) async throws -> PublishedSessionManifest {
    try await finalizer.publishFinalManifest(manifest, auditID: auditID)
  }

  package func replay(auditID: UUID) async throws -> [SessionAuditRecord] {
    try await finalizer.replay(auditID: auditID)
  }

  package func manifestConfirmation(
    auditID: UUID
  ) async -> HDCServerLifecycleManifestConfirmation? {
    await finalizer.manifestConfirmation(auditID: auditID)
  }

  package func reopenToolchainIntent() throws -> JobToolchainIntent {
    try intentStore.reopen(jobID: toolchainIntent.jobID)
  }

}

/// The production Session composition used by the App shell. It owns the
/// concrete durable audit store and manifest publisher, while keeping the
/// lifecycle executor outside the diagnostics/UI surface.
public struct HDCSessionDiagnosticsComposition: Sendable {
  public let supervisor: HDCServerSupervisor
  public let diagnostics: HDCServerDiagnosticsUseCase
  package let lifecycle: HDCSessionLifecycleUseCase?
  package let toolchainIntent: JobToolchainIntent?

  package init(
    supervisor: HDCServerSupervisor,
    diagnostics: HDCServerDiagnosticsUseCase,
    lifecycle: HDCSessionLifecycleUseCase?,
    toolchainIntent: JobToolchainIntent?
  ) {
    self.supervisor = supervisor
    self.diagnostics = diagnostics
    self.lifecycle = lifecycle
    self.toolchainIntent = toolchainIntent
  }
}

package struct HDCApplicationDiagnosticsExecutionIdentity: Sendable, Equatable {
  let sessionID: String
  let jobID: String
  let sessionRoot: URL
  let isCrashRecovery: Bool
}

/// Candidate identity partitions the locator catalog only. Every logical HDC
/// lifecycle Job receives fresh Session/Job IDs; an old identity is selected
/// exclusively when its durable recovery gate proves an interrupted external-
/// effect/finalization window.
package struct HDCApplicationDiagnosticsExecutionCatalog: Sendable {
  private struct Locator: Codable {
    static let schemaVersion = "1.0.0"

    let schemaVersion: String
    let candidatePath: String
    let candidateSHA256: String
    let sessionID: String
    let jobID: String
  }

  private let root: URL

  package init(root: URL) {
    self.root = root
  }

  package func select(for candidate: HDCCandidate) throws
    -> HDCApplicationDiagnosticsExecutionIdentity
  {
    let canonicalPath = candidate.path.resolvingSymlinksInPath().standardizedFileURL.path
    let catalogRoot = root.appending(
      path: HDCApplicationDiagnosticsSessionScope.catalogIdentifier(for: candidate),
      directoryHint: .isDirectory)
    let sessionsRoot = catalogRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let locatorURL = catalogRoot.appending(path: "active-execution.json")
    try FileManager.default.createDirectory(
      at: sessionsRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    if FileManager.default.fileExists(atPath: locatorURL.path) {
      let locator = try JSONDecoder().decode(Locator.self, from: Data(contentsOf: locatorURL))
      guard locator.schemaVersion == Locator.schemaVersion,
        locator.candidatePath == canonicalPath,
        locator.candidateSHA256 == candidate.sha256
      else {
        throw HDCServerLifecycleAdapterError.sessionIdentityMismatch
      }
      let sessionRoot = sessionsRoot.appending(
        path: locator.sessionID, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: sessionRoot.path) {
        let layout = try SessionLayout(
          sessionID: locator.sessionID, jobID: locator.jobID, root: sessionRoot)
        let auditStore = try FileDurableSessionAuditStore(layout: layout)
        let adapter = try DurableHDCServerLifecycleAuditStore(
          auditStore: auditStore,
          manifestPublisher: AtomicSessionManifestPublisher(layout: layout),
          timestamp: { ISO8601DateFormatter().string(from: Date()) })
        if try adapter.lifecycleRecoveryGate() != nil {
          return HDCApplicationDiagnosticsExecutionIdentity(
            sessionID: locator.sessionID,
            jobID: locator.jobID,
            sessionRoot: sessionRoot,
            isCrashRecovery: true)
        }
        if FileManager.default.fileExists(atPath: layout.manifestURL.path) {
          _ = try AtomicSessionManifestPublisher(layout: layout).load()
        }
      }
    }

    let sessionID = "hdc-session-\(UUID().uuidString.lowercased())"
    let jobID = "hdc-job-\(UUID().uuidString.lowercased())"
    let locator = Locator(
      schemaVersion: Locator.schemaVersion,
      candidatePath: canonicalPath,
      candidateSHA256: candidate.sha256,
      sessionID: sessionID,
      jobID: jobID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(locator).write(to: locatorURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: locatorURL.path)
    return HDCApplicationDiagnosticsExecutionIdentity(
      sessionID: sessionID,
      jobID: jobID,
      sessionRoot: sessionsRoot.appending(path: sessionID, directoryHint: .isDirectory),
      isCrashRecovery: false)
  }
}

/// App/runtime-root owner for the one host-wide HDC Supervisor. The first
/// configured toolchain creates the durable host composition. Later toolchain
/// selections attach read-only diagnostics to that same Supervisor; lifecycle
/// authority never migrates from one durable toolchain intent to another in
/// actor memory.
package struct HDCApplicationHostImpactParticipant: Sendable, Equatable {
  let recipient: HDCServerRecipient
  let criticalState: HDCServerCriticalState
}

package enum HDCApplicationHostImpactInventory: Sendable, Equatable {
  case complete([HDCApplicationHostImpactParticipant])
  case unavailable(reason: String)

  var unavailableReason: String? {
    guard case .unavailable(let reason) = self else { return nil }
    return reason
  }

  func isReliable(for endpoint: HDCServerEndpoint) -> Bool {
    guard case .complete(let participants) = self else { return false }
    return participants.allSatisfy { $0.recipient.endpoint == endpoint }
      && Set(participants.map(\.recipient)).count == participants.count
  }

}

package actor HDCApplicationDiagnosticsHost {
  package static let shared = HDCApplicationDiagnosticsHost()
  package static let attachedLifecycleUnavailableReason =
    "Lifecycle mutation remains bound to the original host toolchain Session; restart the App to establish a new durable host intent."

  private var hostComposition: HDCSessionDiagnosticsComposition?
  private var hostSessionID: String?
  private var hostJobID: String?
  private var hostLifecycleRecipient: HDCServerRecipient?

  package init() {}

  package func compose(
    sessionRoot: URL,
    sessionID: String,
    jobID: String,
    toolchain: HDCCandidate,
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    snapshot: HDCJobToolchainSnapshot,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState = .unverifiedAssumeUnprotected,
    keyAccessError: String? = nil,
    additionalChildEnvironment: [String: String] = [:],
    subserverCapability: HDCSubserverCapability = .unsupported,
    impactInventory: HDCApplicationHostImpactInventory,
    manifestFaultInjector: SessionStorageFaultInjector = .none,
    postDispatchProbe: @escaping HDCProcessLifecycleExecutor.PostDispatchProbe
  ) async throws -> HDCSessionDiagnosticsComposition {
    if let hostComposition {
      await apply(
        impactInventory: impactInventory,
        lifecycleRecipient: hostLifecycleRecipient,
        supervisor: hostComposition.supervisor,
        endpoint: HDCServerEndpoint(snapshot.endpoint))
      if hostSessionID == sessionID, hostJobID == jobID { return hostComposition }
      return HDCSessionDiagnosticsBootstrap.makeAttached(
        supervisor: hostComposition.supervisor,
        snapshot: snapshot,
        authorization: authorization,
        channelProtection: channelProtection,
        keyAccessError: keyAccessError,
        subserverCapability: subserverCapability,
        lifecycleRecoveryUnavailableReason: Self.attachedLifecycleUnavailableReason
      )
    }

    let composition = try HDCSessionDiagnosticsBootstrap.makeHost(
      sessionRoot: sessionRoot,
      sessionID: sessionID,
      jobID: jobID,
      toolchain: toolchain,
      semanticProfile: semanticProfile,
      snapshot: snapshot,
      authorization: authorization,
      channelProtection: channelProtection,
      keyAccessError: keyAccessError,
      additionalChildEnvironment: additionalChildEnvironment,
      subserverCapability: subserverCapability,
      impactInventory: impactInventory,
      lifecycleRecoveryUnavailableReason: impactInventory.unavailableReason,
      manifestFaultInjector: manifestFaultInjector,
      postDispatchProbe: postDispatchProbe)
    let endpoint = HDCServerEndpoint(snapshot.endpoint)
    let lifecycleJob = HDCServerRecipient(id: jobID, kind: .job, endpoint: endpoint)
    await apply(
      impactInventory: impactInventory,
      lifecycleRecipient: lifecycleJob,
      supervisor: composition.supervisor,
      endpoint: endpoint)
    hostComposition = composition
    hostSessionID = sessionID
    hostJobID = jobID
    hostLifecycleRecipient = lifecycleJob
    return composition
  }

  private func apply(
    impactInventory: HDCApplicationHostImpactInventory,
    lifecycleRecipient: HDCServerRecipient?,
    supervisor: HDCServerSupervisor,
    endpoint: HDCServerEndpoint
  ) async {
    if let lifecycleRecipient {
      await supervisor.register(lifecycleRecipient)
      await supervisor.updateCriticalState(.none, for: lifecycleRecipient)
    }
    switch impactInventory {
    case .complete(let participants):
      let exactEndpoint = participants.allSatisfy { $0.recipient.endpoint == endpoint }
      let uniqueRecipients = Set(participants.map(\.recipient)).count == participants.count
      guard exactEndpoint, uniqueRecipients else {
        await supervisor.setParticipantImpactReliability(false, for: endpoint)
        return
      }
      for participant in participants {
        await supervisor.register(participant.recipient)
        await supervisor.updateCriticalState(
          participant.criticalState, for: participant.recipient)
      }
      await supervisor.setParticipantImpactReliability(true, for: endpoint)
    case .unavailable:
      await supervisor.setParticipantImpactReliability(false, for: endpoint)
    }
  }
}

public enum HDCSessionDiagnosticsBootstrap {
  /// Internal factory for the host actor. Keeping lifecycle-bearing creation
  /// file-private makes `HDCApplicationDiagnosticsHost.compose`, whose type
  /// requires an impact inventory, the only package entry point that can
  /// create a host-wide Supervisor. Subsequent Sessions use `makeAttached`.
  ///
  /// This function never starts an HDC process; process-backed probes remain
  /// an explicit read-only step performed by the App after composition.
  fileprivate static func makeHost(
    sessionRoot: URL,
    sessionID: String,
    jobID: String,
    toolchain: HDCCandidate,
    semanticProfile: HDCRegisteredSemanticProfile = .pinnedProduction,
    snapshot: HDCJobToolchainSnapshot,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState = .unverifiedAssumeUnprotected,
    keyAccessError: String? = nil,
    additionalChildEnvironment: [String: String] = [:],
    subserverCapability: HDCSubserverCapability = .unsupported,
    impactInventory: HDCApplicationHostImpactInventory,
    lifecycleRecoveryUnavailableReason: String? = nil,
    manifestFaultInjector: SessionStorageFaultInjector = .none,
    postDispatchProbe: @escaping HDCProcessLifecycleExecutor.PostDispatchProbe
  ) throws -> HDCSessionDiagnosticsComposition {
    guard toolchain.path == snapshot.path, toolchain.source == snapshot.source,
      toolchain.sha256 == snapshot.sha256
    else {
      throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
    }
    try FileManager.default.createDirectory(
      at: sessionRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: sessionRoot.appending(path: "audit", directoryHint: .isDirectory),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    for relativePath in ["artifacts/raw", "artifacts/derived", "artifacts/partial"] {
      try FileManager.default.createDirectory(
        at: sessionRoot.appending(path: relativePath, directoryHint: .isDirectory),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    let layout = try SessionLayout(sessionID: sessionID, jobID: jobID, root: sessionRoot)
    let durableAudit = try FileDurableSessionAuditStore(layout: layout)
    let timestamp: @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    let intentStore = DurableHDCJobToolchainIntentStore(
      auditStore: durableAudit, timestamp: timestamp)
    let adapter = try DurableHDCServerLifecycleAuditStore(
      auditStore: durableAudit,
      manifestPublisher: AtomicSessionManifestPublisher(
        layout: layout, faultInjector: manifestFaultInjector),
      timestamp: timestamp)
    let persistedRecoveryGate = try adapter.lifecycleRecoveryGate()
    let toolchainIntent: JobToolchainIntent
    if persistedRecoveryGate != nil {
      let reopened = try intentStore.reopen(jobID: jobID)
      guard reopened.executablePath == toolchain.path.path,
        reopened.executableSHA256 == toolchain.sha256,
        reopened.source.rawValue == snapshot.source.rawValue,
        reopened.endpoint == snapshot.endpoint
      else {
        throw HDCServerLifecycleAdapterError.durableToolchainIntentMissingOrMismatched
      }
      toolchainIntent = reopened
    } else {
      let requestedIntent = try coreToolchainIntent(
        id: UUID(), jobID: jobID, snapshot: snapshot)
      toolchainIntent = try intentStore.persistOrReopen(requestedIntent)
    }
    let endpoint = try HDCServerEndpointSelector.select(
      explicitEndpoint: snapshot.endpoint)
    let supervisor = HDCServerSupervisor(
      auditStore: adapter,
      endpoint: endpoint.endpoint,
      participantImpactReliable: impactInventory.isReliable(for: endpoint.endpoint))
    let executor = HDCProcessLifecycleExecutor(
      toolchain: toolchain,
      semanticProfile: semanticProfile,
      endpointSelection: endpoint,
      additionalChildEnvironment: additionalChildEnvironment,
      durableAuthorization: adapter,
      supervisor: supervisor,
      postDispatchProbe: postDispatchProbe)
    let lifecycle = try HDCSessionLifecycleUseCase(
      supervisor: supervisor,
      executor: executor,
      intentStore: intentStore,
      toolchainIntent: toolchainIntent,
      finalizer: adapter)
    return makeDiagnostics(
      supervisor: supervisor, snapshot: snapshot, authorization: authorization,
      channelProtection: channelProtection, keyAccessError: keyAccessError,
      subserverCapability: subserverCapability,
      lifecycle: lifecycle,
      toolchainIntent: toolchainIntent,
      lifecycleRecoveryUnavailableReason: persistedRecoveryGate?.reason
        ?? lifecycleRecoveryUnavailableReason)
  }

  /// Attaches a Session's read-only diagnostics use case to the one
  /// host-wide Supervisor created by `makeHost`. This API deliberately does
  /// not create an audit store or Supervisor: lifecycle authority and its
  /// durable audit correlation belong to the host composition root.
  public static func makeAttached(
    supervisor: HDCServerSupervisor,
    snapshot: HDCJobToolchainSnapshot,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState = .unverifiedAssumeUnprotected,
    keyAccessError: String? = nil,
    subserverCapability: HDCSubserverCapability = .unsupported,
    lifecycleRecoveryUnavailableReason: String =
      "Lifecycle mutation is unavailable for an attached read-only Session."
  ) -> HDCSessionDiagnosticsComposition {
    makeDiagnostics(
      supervisor: supervisor, snapshot: snapshot, authorization: authorization,
      channelProtection: channelProtection, keyAccessError: keyAccessError,
      subserverCapability: subserverCapability,
      lifecycle: nil,
      toolchainIntent: nil,
      lifecycleRecoveryUnavailableReason: lifecycleRecoveryUnavailableReason)
  }

  private static func makeDiagnostics(
    supervisor: HDCServerSupervisor,
    snapshot: HDCJobToolchainSnapshot,
    authorization: HDCAuthorizationState,
    channelProtection: HDCChannelProtectionState,
    keyAccessError: String?,
    subserverCapability: HDCSubserverCapability,
    lifecycle: HDCSessionLifecycleUseCase?,
    toolchainIntent: JobToolchainIntent?,
    lifecycleRecoveryUnavailableReason: String?
  ) -> HDCSessionDiagnosticsComposition {
    let diagnostics = HDCServerDiagnosticsUseCase(
      supervisor: supervisor, snapshot: snapshot, authorization: authorization,
      channelProtection: channelProtection, keyAccessError: keyAccessError,
      subserverCapability: subserverCapability,
      lifecycleRecoveryUnavailableReason: lifecycleRecoveryUnavailableReason)
    return HDCSessionDiagnosticsComposition(
      supervisor: supervisor,
      diagnostics: diagnostics,
      lifecycle: lifecycle,
      toolchainIntent: toolchainIntent)
  }

  private static func coreToolchainIntent(
    id: UUID,
    jobID: String,
    snapshot: HDCJobToolchainSnapshot
  ) throws -> JobToolchainIntent {
    let source: JobToolchainSource
    switch snapshot.source {
    case .userConfigured: source = .userConfigured
    case .devecoSDK: source = .devecoSDK
    case .openHarmonySDK: source = .openHarmonySDK
    }
    return try JobToolchainIntent(
      id: id,
      jobID: jobID,
      executablePath: snapshot.path.path,
      source: source,
      executableSHA256: snapshot.sha256,
      platformTrust: coreEvidence(snapshot.platformTrust),
      clientVersion: coreEvidence(snapshot.clientVersion),
      serverVersion: coreEvidence(snapshot.serverVersion),
      daemonVersion: coreEvidence(snapshot.daemonVersion),
      endpoint: snapshot.endpoint,
      serverGeneration: coreEvidence(snapshot.serverGeneration))
  }

  private static func coreEvidence<Value>(
    _ value: HDCProbeValue<Value>
  ) -> JobToolchainEvidence<Value> where Value: Codable & Sendable & Equatable {
    switch value {
    case .known(let known): .known(known)
    case .unknown(let reason): .unknown(reason: reason)
    }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func stringValue(for key: String) -> String? {
    guard case .string(let value) = self[key] else { return nil }
    return value
  }

  fileprivate func integerValue(for key: String) -> Int64? {
    guard case .integer(let value) = self[key] else { return nil }
    return value
  }
}
