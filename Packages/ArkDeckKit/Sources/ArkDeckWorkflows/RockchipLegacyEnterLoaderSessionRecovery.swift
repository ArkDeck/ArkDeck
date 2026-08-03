import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Foundation

/// Resolves the one legacy Flash crash shape for which the original typed
/// effect has an exact, non-mutating readback: `rockusb.enter-loader` with a
/// single DAYU200 now observed in Loader mode through the durable cross-mode
/// binding lineage. It never launches HDC/rkdeveloptool and never retries an
/// effect. Every other unfinished shape remains unknown and continues to
/// block heavy writers.
struct RockchipLegacyEnterLoaderSessionRecovery: Sendable {
  struct Result: Sendable, Equatable {
    let finalizedSessionIDs: [String]
    let deviceMutationDispatchCount: Int
  }

  private struct PreviousBinding: Sendable {
    let revision: Int
    let serialDigestSHA256: String
    let usbTopology: String
  }

  private let storage: SessionStorageExecutionContext
  private let agentLedger: AgentAuthorityUsageLedger
  private let binding: RockchipProductBindingSnapshot
  private let tool: RockchipSelectedDiscoveryTool
  private let toolIdentity: @Sendable () throws -> ProcessExecutableIdentityReceipt
  private let liveIdentity: @Sendable () throws -> RockchipProductUSBIdentity
  private let now: @Sendable () -> Date

  init(
    storage: SessionStorageExecutionContext,
    agentLedger: AgentAuthorityUsageLedger,
    binding: RockchipProductBindingSnapshot,
    tool: RockchipSelectedDiscoveryTool,
    toolWorkingDirectory: URL,
    liveIdentity: @escaping @Sendable () throws -> RockchipProductUSBIdentity,
    toolIdentity: (@Sendable () throws -> ProcessExecutableIdentityReceipt)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.storage = storage
    self.agentLedger = agentLedger
    self.binding = binding
    self.tool = tool
    self.toolIdentity = toolIdentity ?? {
      let prepared = try FoundationProcessExecutor().prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: tool.executableURL, arguments: ["ld"],
            workingDirectory: toolWorkingDirectory, timeout: 5),
          expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction
            .executableSHA256))
      defer { prepared.close() }
      return prepared.executableIdentity
    }
    self.liveIdentity = liveIdentity
    self.now = now
  }

  func recoverAll() async throws -> Result {
    let catalog = try storage.catalog.scan(
      retentionDays: storage.settings.retentionDays,
      policyGeneration: storage.settings.generation)
    let active = Set(
      await storage.coordinator.activeSessions(on: catalog.volumeIdentity).map(\.sessionID))
    var finalized: [String] = []
    for relativeID in catalog.unknownSessionIDs.sorted() {
      guard let root = sessionRoot(relativeID: relativeID) else { continue }
      let sessionID = root.lastPathComponent
      guard sessionID.hasPrefix("rockchip-session-") else { continue }
      guard !active.contains(sessionID) else { continue }
      if try recover(sessionRoot: root) {
        finalized.append(sessionID)
      }
    }
    return Result(finalizedSessionIDs: finalized, deviceMutationDispatchCount: 0)
  }

  private func recover(sessionRoot: URL) throws -> Bool {
    let lock = try RockchipFlashSessionRunLock.acquire(sessionRoot: sessionRoot)
    defer { RockchipFlashSessionRunLock.release(lock) }

    let replay = try DurableJournalRecovery.inspect(
      url: sessionRoot.appending(path: "journal.jsonl"))
    guard let first = replay.events.first,
      first.kind == .jobCreated
    else { return false }
    let sessionID = first.sessionID
    let jobID = first.jobID
    let layout = try storage.sessionStore.openSession(
      sessionID: sessionID, jobID: jobID, root: sessionRoot)

    // A Manifest that survived while catalog registration did not is a
    // post-publication crash, not a reason to replay recovery events.
    if FileManager.default.fileExists(atPath: layout.manifestURL.path) {
      try storage.catalog.registerFinalizedSession(
        sessionRoot: layout.root,
        retentionDays: storage.settings.retentionDays,
        policyGeneration: storage.settings.generation)
      return true
    }
    guard !replay.hasTornTail else { return false }

    let context = try recoveryContext(replay: replay)
    let journal = try FileDurableJournal(url: layout.journalURL)
    var current = replay

    if !current.outstandingIntents.isEmpty {
      guard current.currentState == .waitingForRecovery,
        current.outstandingIntents.count == 1,
        current.unknownOutcomes.isEmpty,
        let intent = current.events.first(where: {
          $0.eventID == current.outstandingIntents[0].eventID
        })
      else { return false }
      try requireExactLoaderReadback(intent: intent, context: context)
      try journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: recoveryEventID("loader-outcome", sequence: nextSequence(current)),
          sequence: nextSequence(current),
          sessionID: sessionID, jobID: jobID,
          timestamp: timestamp(), stepID: context.enterLoaderStep.id, attempt: 1,
          correlatesToIntentEventID: intent.eventID,
          result: "succeeded", outcomeCertainty: .confirmed,
          semanticCode: "rockchip.enter-loader.recovery-readback-confirmed",
          summary: "durable binding lineage and live Loader identity confirmed",
          schemaVersion: intent.schemaVersion,
          authorizationRef: nil,
          agentAuthorizationRef: current.agentExecutionAuthorityReference,
          usageReservationID: current.usageReservationID))
      current = try DurableJournalRecovery.inspect(url: layout.journalURL)
    }

    if current.currentState == .waitingForRecovery || current.currentState == .reconciling {
      let descriptor = UnfinishedSessionDescriptor(
        sessionID: sessionID, jobID: jobID,
        journalURL: layout.journalURL, checkpointURL: layout.snapshotURL)
      guard let scanned = try SessionRecoveryScanner().scan(descriptor) else { return false }
      _ = try DeterministicRecoveryReconciler(journal: journal).reconcile(
        session: scanned,
        provider: ProviderRecoveryEvidence(
          disposition: .confirmedFailure,
          restartSafe: false,
          safeBoundaryConfirmed: true,
          outcomeCertainty: .confirmed,
          evidence: [
            "rockchip:enter-loader-original-intent-readback=completed",
            "rockchip:device-mutation-replay-count=0",
          ]),
        binding: RecoveryBindingEvidence(
          confirmed: true, revision: binding.revision,
          evidence: ["rockchip:durable-cross-mode-binding-lineage=confirmed"]))
      current = try DurableJournalRecovery.inspect(url: layout.journalURL)
    }

    if current.currentState == .finalizing {
      let sequence = nextSequence(current)
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: recoveryEventID("failed", sequence: sequence), sequence: sequence,
          sessionID: sessionID, jobID: jobID, timestamp: timestamp(),
          from: .finalizing, to: .failed,
          reason: "original Flash stopped after confirmed enter-loader recovery",
          schemaVersion: first.schemaVersion))
      current = try DurableJournalRecovery.inspect(url: layout.journalURL)
    }

    guard current.currentState == .failed || current.finalized,
      current.outstandingIntents.isEmpty,
      current.unknownOutcomes.isEmpty,
      current.lastReconcileOutcomeCertainty == .confirmed
    else { return false }

    let manifest = try makeManifest(layout: layout, replay: current, context: context)
    if !current.finalized {
      let sequence = nextSequence(current)
      try journal.appendAndSynchronize(
        JournalEvent(
          schemaVersion: first.schemaVersion,
          eventID: recoveryEventID("finalized", sequence: sequence), sequence: sequence,
          sessionID: sessionID, jobID: jobID, timestamp: timestamp(), kind: .finalized,
          payload: [
            "terminalStatus": .string("failed"),
            "manifestSha256": .string(manifest.sha256),
            "outcomeCertainty": .string("confirmed"),
          ]))
    }
    let audit = try FileDurableSessionAuditStore(layout: layout)
    let auditDetails: [String: JSONValue] = [
      "status": .string("failed"),
      "outcomeCertainty": .string("confirmed"),
      "deviceMutationDispatchCount": .integer(0),
      "originalIntentEventId": .string(context.intentEventID),
    ]
    let priorRecoveryAudits = try audit.replay(correlationID: sessionID).filter {
      $0.auditID == "rockchip-enter-loader-recovery"
    }
    guard priorRecoveryAudits.count <= 1,
      priorRecoveryAudits.allSatisfy({
        $0.sessionID == sessionID && $0.jobID == jobID && $0.category == .outcome
          && $0.details == auditDetails
      })
    else {
      throw RockchipFlashExecutionError.storageRejected(
        "legacy recovery audit drift")
    }
    if priorRecoveryAudits.isEmpty {
      try audit.appendAndSynchronize(
        SessionAuditRecord(
          recordID: "rockchip-enter-loader-recovery-outcome",
          auditID: "rockchip-enter-loader-recovery",
          correlationID: sessionID, sessionID: sessionID, jobID: jobID,
          category: .outcome, timestamp: timestamp(), details: auditDetails))
    }
    _ = try AtomicSessionManifestPublisher(layout: layout).publish(manifest)
    try storage.catalog.registerFinalizedSession(
      sessionRoot: layout.root,
      retentionDays: storage.settings.retentionDays,
      policyGeneration: storage.settings.generation)
    return true
  }

  private struct RecoveryContext {
    let reference: AgentExecutionAuthorityReference
    let confirmationDigest: String
    let confirmedAt: String
    let usageReservationID: String
    let intentEventID: String
    let enterLoaderStep: WorkflowStep
    let plan: RockchipFlashPlan
    let previousBinding: PreviousBinding
    let currentSerialDigest: String
    let toolIdentity: ProcessExecutableIdentityReceipt
  }

  private func recoveryContext(replay: JournalReplay) throws -> RecoveryContext {
    guard replay.events.first?.schemaVersion == JournalEvent.agentAuthoritySchemaVersion,
      case .chatConfirmation(
        let confirmationDigest, let planDigest, let archiveDigest,
        let stepSetDigest, let targetDigest, let confirmedAt)? =
        replay.agentExecutionAuthorityReference,
      let reservationID = replay.usageReservationID,
      let intent = replay.events.first(where: { $0.kind == .stepIntent }),
      replay.events.filter({ $0.kind == .stepIntent }).count == 1,
      let step = intent.workflowStep,
      intent.attempt == 1,
      step.kind == .enterUpdater,
      step.effect == .deviceMutation,
      step.arguments["providerOperationId"] == .string("rockusb.enter-loader"),
      let revision = intent.bindingRevision,
      let previous = try previousBinding(revision: revision),
      let target = intentTarget(intent),
      target.connectKey == previous.usbTopology,
      target.identitySnapshotHash == targetDigest,
      targetDigest == targetDigestSHA256(previous: previous),
      let profile = RockchipFlashProfile.supportedDAYU200Profiles.first(where: {
        $0.archiveSHA256 == archiveDigest
      })
    else { throw RockchipFlashExecutionError.storageRejected("legacy recovery shape drift") }
    let plan = try Self.legacyPlan(profile: profile)
    guard plan.planDigestSHA256 == planDigest,
      plan.stepSetDigestSHA256 == stepSetDigest,
      plan.archiveSHA256 == archiveDigest,
      plan.steps.first(where: { $0.id == step.id }) == step,
      let terminal = try agentLedger.load().reservations.first(where: {
        $0.reservationID == reservationID
      })?.terminal,
      terminal.status == .outcomeUnknown,
      terminal.externalIntentEventIDs == [intent.eventID]
    else { throw RockchipFlashExecutionError.storageRejected("legacy recovery authority drift") }

    let currentSerial = sha256(Data(binding.serial.utf8))
    return RecoveryContext(
      reference: replay.agentExecutionAuthorityReference!,
      confirmationDigest: confirmationDigest, confirmedAt: confirmedAt,
      usageReservationID: reservationID, intentEventID: intent.eventID,
      enterLoaderStep: step, plan: plan, previousBinding: previous,
      currentSerialDigest: currentSerial, toolIdentity: try toolIdentity())
  }

  private func requireExactLoaderReadback(
    intent: JournalEvent, context: RecoveryContext
  ) throws {
    let live = try liveIdentity()
    guard live.isLoader,
      live.topology == binding.usbTopology,
      sha256(Data(live.serial.utf8)) == context.currentSerialDigest,
      context.currentSerialDigest == sha256(Data(binding.serial.utf8)),
      binding.revision > context.previousBinding.revision
    else {
      throw RockchipFlashExecutionError.storageRejected(
        "legacy enter-loader readback is not the bound Loader identity")
    }
  }

  private func previousBinding(revision: Int) throws -> PreviousBinding? {
    let serials = values(prefix: "identity:previous-serial-sha256=")
    let topologies = values(prefix: "binding:previous-usb-topology=")
    let revisions = values(prefix: "binding:previous-revision=").compactMap(Int.init)
    let rebindConfirmations = values(prefix: "rebind:chat-confirmation-sha256=")
    guard serials.count == 1, topologies.count == 1, revisions == [revision],
      rebindConfirmations.count == 1,
      RockchipStandingAuthorization.isCanonicalSHA256(serials[0]),
      RockchipStandingAuthorization.isCanonicalSHA256(rebindConfirmations[0]),
      canonicalTopology(topologies[0]), binding.revision > revision
    else { return nil }
    return PreviousBinding(
      revision: revision, serialDigestSHA256: serials[0], usbTopology: topologies[0])
  }

  private func values(prefix: String) -> [String] {
    binding.evidence.compactMap {
      $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
    }
  }

  private func makeManifest(
    layout: SessionLayout, replay: JournalReplay, context: RecoveryContext
  ) throws -> SessionManifestDocument {
    guard let createdAt = replay.events.first?.timestamp,
      let completedAt = replay.events.last(where: {
        $0.kind == .stateTransition && $0.stateTransition?.to == .failed
      })?.timestamp
    else { throw RockchipFlashExecutionError.storageRejected("legacy terminal timestamps") }
    let bindingHistory: [JSONValue] = [
      bindingValue(
        revision: context.previousBinding.revision,
        serialDigest: context.previousBinding.serialDigestSHA256,
        topology: context.previousBinding.usbTopology,
        evidence: "original durable intent binding"),
      bindingValue(
        revision: binding.revision, serialDigest: context.currentSerialDigest,
        topology: binding.usbTopology,
        evidence: "fresh Loader readback through durable cross-mode lineage"),
    ]
    let steps = try context.plan.steps.map { step -> JSONValue in
      var object = try jsonObject(step)
      object["argumentsHash"] = .string(
        try JournalCanonicalJSON.argumentsHash(step.arguments))
      object["sourceStepId"] = .null
      object["compensationTrigger"] = .null
      object["bindingRevision"] =
        step.bindingRequirement == .confirmedDevice
        ? .integer(Int64(context.previousBinding.revision)) : .null
      if step.id == context.enterLoaderStep.id {
        object["disposition"] = .string("executed")
        object["outcomeCertainty"] = .string("confirmed")
        object["semanticResult"] = .string("succeeded")
      } else {
        object["disposition"] = .string("skipped")
        object["outcomeCertainty"] = .string("notApplicable")
        object["semanticResult"] = .string("notRun")
      }
      return .object(object)
    }
    let authorizationReference = try jsonValue(context.reference)
    let related = context.plan.steps.filter {
      $0.arguments["confirmationId"] == .string(context.plan.confirmationID)
    }.map { JSONValue.string($0.id) }
    let scopeHash = context.plan.steps.first {
      $0.kind == .requestConfirmation
    }?.arguments["scopeHash"] ?? .string(context.confirmationDigest)
    let root: JSONValue = .object([
      "schemaVersion": .string(JournalEvent.agentAuthoritySchemaVersion),
      "appVersion": .string("ArkDeckKit-1.0.0"),
      "coreSpecBaseline": .string("CORE-2.0.0"),
      "platformProfile": .string("macos-1.0.0"),
      "sessionId": .string(layout.sessionID), "jobId": .string(layout.jobID),
      "status": .string("failed"), "executionMode": .string("execute"),
      "executionAuthority": .string("authorizedAgent"),
      "authorization": .object([
        "authorizationRef": authorizationReference,
        "usageReservationId": .string(context.usageReservationID),
        "externalIntentEventIds": .array([.string(context.intentEventID)]),
      ]),
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(createdAt), "completedAt": .string(completedAt),
      "archivedAt": .null,
      "originalTarget": .object([
        "kind": .string("real"),
        "connectKey": .string(context.previousBinding.usbTopology),
        "transport": .string("usb"),
        "identitySnapshot": .object([
          "serialSha256": .string(context.previousBinding.serialDigestSHA256),
          "usbTopology": .string(context.previousBinding.usbTopology),
        ]),
      ]),
      "bindingHistory": .array(bindingHistory),
      "toolchain": .object([
        "kind": .string("rockchip"),
        "profileIdentifier": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier),
        "reportedVersion": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion),
        "sha256": .string(context.toolIdentity.sha256),
        "pathSource": .string(tool.pathSource.rawValue),
        "descriptorIdentity": .object([
          "device": .unsignedInteger(context.toolIdentity.device),
          "inode": .unsignedInteger(context.toolIdentity.inode),
          "fileSize": .integer(context.toolIdentity.fileSize),
          "mode": .unsignedInteger(UInt64(context.toolIdentity.mode)),
        ]),
      ]),
      "workflow": .object([
        "kind": .string("rockchipFlash"),
        "profileVersion": .string(RockchipFlashProfile.profileVersion),
        "providerIdentity": .string(RockchipRockUSBFlashProvider.providerIdentity),
      ]),
      "steps": .array(steps), "parameters": .array([]),
      "compensations": .array([]),
      "confirmations": .array([
        .object([
          "confirmationId": .string(context.plan.confirmationID),
          "kind": .string("destructive"), "scopeHash": scopeHash,
          "decision": .string("accepted"),
          "actor": .object([
            "kind": .string("authorizedAgent"),
            "authorizationRef": authorizationReference,
          ]),
          "decidedAt": .string(context.confirmedAt),
          "relatedStepIds": .array(related),
        ])
      ]),
      "artifacts": .array([]),
      "warnings": .array([
        .string(
          "legacy enter-loader outcome resolved by exact Loader and durable binding readback; no effect replayed")
      ]),
      "failure": .object([
        "stage": .string("recovery"),
        "code": .string("rockchip-enter-loader-recovered"),
        "summary": .string("Flash stopped after enter-loader; no partition write was dispatched"),
      ]),
      "recovery": .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try SessionManifestDocument(data: encoder.encode(root))
  }

  static func legacyPlan(profile: RockchipFlashProfile) throws -> RockchipFlashPlan {
    let current = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid,
      postFlashVerification: .full, planNonce: "rf002")
    let steps = current.steps.filter {
      $0.arguments["probeId"] != .string("rockusb-partition-readback")
    }
    let stepSet = sha256(
      Data(
        try steps.enumerated().map { index, step in
          "\(index)|\(step.id)|\(step.kind.rawValue)|\(try JournalCanonicalJSON.argumentsHash(step.arguments))"
        }.joined(separator: "\n").utf8))
    let planDigest = sha256(
      Data(
        [
          "mode=execute",
          "provider=\(RockchipRockUSBFlashProvider.providerIdentity)@\(RockchipRockUSBFlashProvider.providerVersion)",
          "profile=\(RockchipFlashProfile.profileIdentity)@\(profile.planDocumentVersion)",
          "archive=\(profile.archiveSHA256)",
          "stepSet=\(stepSet)",
          "target=\(RockchipFlashProfile.targetDeviceModel)",
        ].joined(separator: "\n").utf8))
    return RockchipFlashPlan(
      executionMode: .execute, steps: steps,
      confirmationID: current.confirmationID,
      destructiveStepIDs: current.destructiveStepIDs,
      planDigestSHA256: planDigest, stepSetDigestSHA256: stepSet,
      archiveSHA256: current.archiveSHA256,
      archiveSizeBytes: current.archiveSizeBytes,
      postFlashVerification: .full, dataImpact: current.dataImpact)
  }

  private func sessionRoot(relativeID: String) -> URL? {
    let parts = relativeID.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
      parts[1].count == 2, parts[1].allSatisfy(\.isNumber),
      !parts[2].isEmpty
    else { return nil }
    let monthRoot = storage.rootLease.url
      .appending(path: String(parts[0]), directoryHint: .isDirectory)
      .appending(path: String(parts[1]), directoryHint: .isDirectory)
    // SessionStore.openSession canonicalizes the final relative path without a
    // directory URL hint before comparing resolved URLs.
    return monthRoot.appending(path: String(parts[2]))
  }

  private func intentTarget(_ event: JournalEvent) -> (
    connectKey: String, identitySnapshotHash: String
  )? {
    guard case .object(let target)? = event.payload["target"],
      case .string(let connectKey)? = target["connectKey"],
      case .string(let identity)? = target["identitySnapshotHash"]
    else { return nil }
    return (connectKey, identity)
  }

  private func targetDigestSHA256(previous: PreviousBinding) -> String {
    Self.sha256(
      Data(
        [
          RockchipFlashProfile.targetDeviceModel,
          previous.serialDigestSHA256,
          String(previous.revision), previous.usbTopology,
          String(RockchipProbeEvidence.rockUSBVendorID),
          String(RockchipProbeEvidence.dayu200LoaderProductID),
        ].joined(separator: "|").utf8))
  }

  private func bindingValue(
    revision: Int, serialDigest: String, topology: String, evidence: String
  ) -> JSONValue {
    .object([
      "revision": .integer(Int64(revision)),
      "connectKey": .string(topology), "transport": .string("usb"),
      "identitySnapshot": .object([
        "serialSha256": .string(serialDigest), "usbTopology": .string(topology)
      ]),
      "evidence": .array([.string(evidence)]),
      "confirmedBy": .string("corePolicy"),
      "channelProtection": .string("unverifiedAssumeUnprotected"),
    ])
  }

  private func jsonObject<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
    guard case .object(let object) = try jsonValue(value) else {
      throw RockchipFlashExecutionError.storageRejected("legacy recovery JSON object")
    }
    return object
  }

  private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  private func nextSequence(_ replay: JournalReplay) -> Int {
    (replay.lastDurableSequence ?? -1) + 1
  }

  private func recoveryEventID(_ suffix: String, sequence: Int) -> String {
    "rk-recovery-\(sequence)-\(suffix)"
  }

  private func timestamp() -> String { ISO8601DateFormatter().string(from: now()) }

  private func canonicalTopology(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
      && (value == "0" || value.first != "0")
  }

  private func sha256(_ data: Data) -> String { Self.sha256(data) }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
