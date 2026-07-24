import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import IOKit
import Security

public struct RockchipFlashExecutionHost: Sendable {
  private let executor: RockchipFlashExecutor

  /// Production composition has no caller-supplied dependency, executable, argv, fact receipt,
  /// repository, branch, clock, storage root or authorization bytes. All such inputs come from
  /// the product-owned Application Support, Keychain, bookmark and protected-main adapters.
  public init() throws {
    executor = RockchipFlashExecutor(
      dependencies: try RockchipProductionExecutionComposition.make())
  }

  init(dependencies: RockchipFlashExecutionDependencies) {
    executor = RockchipFlashExecutor(dependencies: dependencies)
  }

  public func execute(_ request: RockchipFlashExecutionRequest) async throws
    -> RockchipFlashExecutionResult
  {
    try await executor.execute(request)
  }
}

// MARK: - Product-owned power activity

private final class ProductRockchipPowerActivityController: @unchecked Sendable,
  RockchipPowerActivityPort
{
  func acquire(reason: String) throws -> any RockchipPowerActivityLease {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled], reason: reason)
    return ProductRockchipPowerActivityLease(activity: activity)
  }
}

private final class ProductRockchipPowerActivityLease: @unchecked Sendable,
  RockchipPowerActivityLease
{
  private let lock = NSLock()
  private var activity: (any NSObjectProtocol)?

  init(activity: any NSObjectProtocol) {
    self.activity = activity
  }

  deinit { end() }

  func end() {
    lock.lock()
    let activity = activity
    self.activity = nil
    lock.unlock()
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
  }
}

private final class ProductRockchipExecutionLifecyclePort: @unchecked Sendable,
  RockchipExecutionLifecyclePort
{
  private enum State {
    case stopped
    case awake
    case sleeping(eventID: String)
  }

  private let lock = NSLock()
  private let elapsedClock = ContinuousClock()
  private let activeClock = SuspendingClock()
  private var elapsedStart: ContinuousClock.Instant
  private var activeStart: SuspendingClock.Instant
  private var state: State = .stopped
  private var tokens: [NSObjectProtocol] = []
  private var center: NotificationCenter?
  private var handler: (@Sendable (RockchipExecutionLifecycleEvent) -> Void)?

  init() {
    elapsedStart = elapsedClock.now
    activeStart = activeClock.now
  }

  deinit { stop() }

  func start(
    handler: @escaping @Sendable (RockchipExecutionLifecycleEvent) -> Void
  ) throws {
    _ = Bundle(path: "/System/Library/Frameworks/AppKit.framework")?.load()
    guard let workspaceType = NSClassFromString("NSWorkspace") as? NSObject.Type,
      let workspace = workspaceType.perform(NSSelectorFromString("sharedWorkspace"))?
        .takeUnretainedValue() as? NSObject,
      workspace.responds(to: NSSelectorFromString("notificationCenter")),
      let center = workspace.perform(NSSelectorFromString("notificationCenter"))?
        .takeUnretainedValue() as? NotificationCenter
    else {
      throw RockchipFlashExecutionError.storageRejected("NSWorkspace notification center")
    }

    lock.lock()
    defer { lock.unlock() }
    guard case .stopped = state else { return }
    self.handler = handler
    self.center = center
    elapsedStart = elapsedClock.now
    activeStart = activeClock.now
    state = .awake
    tokens = [
      center.addObserver(
        forName: Notification.Name("NSWorkspaceWillSleepNotification"),
        object: nil, queue: nil
      ) { [weak self] _ in self?.receive(.sleep) },
      center.addObserver(
        forName: Notification.Name("NSWorkspaceDidWakeNotification"),
        object: nil, queue: nil
      ) { [weak self] _ in self?.receive(.wake) },
    ]
  }

  func stop() {
    lock.lock()
    let tokens = tokens
    let center = center
    self.tokens = []
    self.center = nil
    handler = nil
    state = .stopped
    lock.unlock()
    if let center {
      for token in tokens { center.removeObserver(token) }
    }
  }

  private func receive(_ kind: RockchipExecutionLifecycleEventKind) {
    lock.lock()
    defer { lock.unlock() }
    guard let handler else { return }
    let eventID = "rockchip-lifecycle-(UUID().uuidString.lowercased())"
    let event: RockchipExecutionLifecycleEvent
    switch (state, kind) {
    case (.awake, .sleep):
      event = RockchipExecutionLifecycleEvent(
        eventID: eventID, kind: .sleep, sleepEventID: nil,
        elapsedDurationNanoseconds: Self.nanoseconds(elapsedStart.duration(to: elapsedClock.now)),
        activeDurationNanoseconds: Self.nanoseconds(activeStart.duration(to: activeClock.now)))
      state = .sleeping(eventID: eventID)
    case (.sleeping(let sleepEventID), .wake):
      event = RockchipExecutionLifecycleEvent(
        eventID: eventID, kind: .wake, sleepEventID: sleepEventID,
        elapsedDurationNanoseconds: Self.nanoseconds(elapsedStart.duration(to: elapsedClock.now)),
        activeDurationNanoseconds: Self.nanoseconds(activeStart.duration(to: activeClock.now)))
      state = .awake
    case (.stopped, _), (.awake, .wake), (.sleeping, .sleep):
      return
    }
    handler(event)
  }

  private static func nanoseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    guard components.seconds >= 0 else { return 0 }
    let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return Int64.max }
    let fractional = components.attoseconds / 1_000_000_000
    let (total, additionOverflow) = whole.addingReportingOverflow(fractional)
    return additionOverflow ? Int64.max : max(0, total)
  }
}

// MARK: - Descriptor-bound process port

final class FoundationRockchipExecutionProcessPort: @unchecked Sendable,
  RockchipExecutionProcessPort
{
  private let executableURL: URL
  private let executor: FoundationProcessExecutor
  private let securityScopedURL: URL?

  init(executableURL: URL, securityScopedURL: URL?, executor: FoundationProcessExecutor) {
    self.executableURL = executableURL
    self.securityScopedURL = securityScopedURL
    self.executor = executor
  }

  deinit { securityScopedURL?.stopAccessingSecurityScopedResource() }

  func prepare(
    command: RockchipClosedCommand,
    admissionIdentity: ProcessExecutableIdentityReceipt
  ) throws -> RockchipPreparedCommand {
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(
        executable: executableURL, arguments: command.arguments, environment: [:],
        timeout: command.isCriticalWrite ? nil : 15),
      expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    let prepared = try executor.prepareIdentityBoundLaunch(request)
    guard Self.sameDescriptor(prepared.executableIdentity, admissionIdentity) else {
      prepared.close()
      throw RockchipFlashExecutionError.executableIdentityDrift
    }
    return RockchipPreparedCommand(executableIdentity: prepared.executableIdentity) {
      let result = try await self.executor.executePreparedIdentityBoundLaunch(
        prepared, evaluating: RockchipCommandSemanticEvaluator(command: command))
      return RockchipExecutionAttempt(
        execution: result.execution, semantic: result.semantic,
        executableIdentity: result.executableIdentity)
    }
  }

  private static func sameDescriptor(
    _ lhs: ProcessExecutableIdentityReceipt,
    _ rhs: ProcessExecutableIdentityReceipt
  ) -> Bool {
    lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.fileSize == rhs.fileSize
      && lhs.mode == rhs.mode && lhs.sha256 == rhs.sha256
  }
}

// MARK: - Durable Session persistence

final class RockchipDurableExecutionPersistence: @unchecked Sendable,
  RockchipExecutionPersistence
{
  let sessionRoot: URL
  private let layout: SessionLayout
  private let claim: StorageClaim
  private let coordinator: HostStorageCoordinator
  private let storageContext: SessionStorageExecutionContext?
  private let journal: FileDurableJournal
  private let audit: FileDurableSessionAuditStore
  private let artifactStore: SessionArtifactStore
  private let publisher: AtomicSessionManifestPublisher
  private let lock = NSLock()
  private let createdAt: String
  private var sequence = 0
  private var stepRecords: [String: RockchipPersistedStepResult] = [:]
  private var artifacts: [ArtifactRecord] = []
  private var waitingForRecovery = false

  init(
    layout: SessionLayout,
    claim: StorageClaim,
    coordinator: HostStorageCoordinator,
    storageContext: SessionStorageExecutionContext? = nil
  ) throws {
    self.layout = layout
    sessionRoot = layout.root
    self.claim = claim
    self.coordinator = coordinator
    self.storageContext = storageContext
    journal = try FileDurableJournal(url: layout.journalURL)
    audit = try FileDurableSessionAuditStore(layout: layout)
    artifactStore = SessionArtifactStore(layout: layout)
    publisher = AtomicSessionManifestPublisher(layout: layout)
    createdAt = Self.timestamp()
  }

  func appendJobCreated(admission: RockchipExecutionAdmission) throws {
    try locked {
      try append(
        JournalEvent.jobCreated(
          eventID: eventID("created"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), executionMode: "execute",
          executionAuthority: "authorizedAgent", coreBaseline: "CORE-2.0.0",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion,
          authorizationRef: admission.authorizationReference,
          usageReservationID: admission.usageReservationID))
    }
  }

  func appendRunning() throws {
    try locked {
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("preflight"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .queued, to: .preflight,
          reason: "trusted admission consumed and staging validated",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion))
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("running"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .preflight, to: .running,
          reason: "closed Rockchip command sequence ready",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion))
    }
  }

  func appendIntent(
    step: WorkflowStep,
    admission: RockchipExecutionAdmission,
    isDestructive: Bool
  ) throws -> String {
    try locked {
      let identifier = eventID("intent-\(step.id)")
      try append(
        JournalEvent.stepIntent(
          eventID: identifier, sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), step: step,
          target: JournalTarget(
            scope: "device", targetID: admission.targetID,
            connectKey: admission.usbTopology,
            identitySnapshotHash: admission.targetDigestSHA256),
          attempt: 1, bindingRevision: admission.bindingRevision,
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion,
          authorizationRef: isDestructive ? admission.authorizationReference : nil,
          usageReservationID: isDestructive ? admission.usageReservationID : nil))
      return identifier
    }
  }

  func appendOutcome(
    step: WorkflowStep,
    intentEventID: String,
    admission: RockchipExecutionAdmission,
    result: String,
    certainty: JournalOutcomeCertainty,
    semanticCode: String,
    execution: ProcessExecutionResult?
  ) throws {
    try locked {
      if let execution {
        try persistRawStreams(stepID: step.id, execution: execution)
      }
      let destructive = step.effect == .destructive
      try append(
        JournalEvent.stepOutcome(
          eventID: eventID("outcome-\(step.id)"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), stepID: step.id, attempt: 1,
          correlatesToIntentEventID: intentEventID, result: result,
          outcomeCertainty: certainty, semanticCode: semanticCode,
          summary: result == "succeeded" ? "typed semantic marker confirmed" : "fail closed",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion,
          authorizationRef: destructive ? admission.authorizationReference : nil,
          usageReservationID: destructive ? admission.usageReservationID : nil))
      stepRecords[step.id] = RockchipPersistedStepResult(
        disposition: certainty == .confirmed ? "executed" : "outcomeUnknown",
        outcomeCertainty: certainty.rawValue,
        semanticResult: certainty == .confirmed
          ? (result == "succeeded" ? "succeeded" : "failed") : "unknown",
        exitCode: execution.flatMap(Self.exitCode))
    }
  }

  func appendWaitingForRecovery(stepID: String, reason: String) throws {
    try locked {
      guard !waitingForRecovery else { return }
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("waiting-recovery"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .running, to: .waitingForRecovery,
          reason: "\(stepID):\(reason)",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion))
      waitingForRecovery = true
    }
  }

  func appendLifecycleEvent(_ event: RockchipExecutionLifecycleEvent) throws {
    try locked {
      let payload: [String: JSONValue]
      switch event.kind {
      case .sleep:
        payload = [
          "elapsedDurationNanoseconds": .integer(event.elapsedDurationNanoseconds),
          "activeDurationNanoseconds": .integer(event.activeDurationNanoseconds),
        ]
      case .wake:
        guard let sleepEventID = event.sleepEventID else {
          throw RockchipFlashExecutionError.persistenceRejected("wake missing sleep event")
        }
        payload = [
          "sleepEventId": .string(sleepEventID),
          "elapsedDurationNanoseconds": .integer(event.elapsedDurationNanoseconds),
          "activeDurationNanoseconds": .integer(event.activeDurationNanoseconds),
          "throughputSegmentReset": .bool(true),
        ]
      }
      try append(
        JournalEvent(
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion,
          eventID: event.eventID, sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), kind: event.kind == .sleep ? .sleep : .wake,
          payload: payload))
    }
  }

  func finishSucceeded(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) async throws -> URL {
    let manifest: SessionManifestDocument = try locked {
      let document = try makeManifest(
        plan: plan, admission: admission,
        destructiveIntentEventIDs: destructiveIntentEventIDs)
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("finalizing"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .running, to: .finalizing,
          reason: "all typed outcomes and postflight confirmed",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion))
      try append(
        JournalEvent.stateTransition(
          eventID: eventID("succeeded"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), from: .finalizing, to: .succeeded,
          reason: "terminal manifest graph ready",
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion))
      try append(
        JournalEvent(
          schemaVersion: JournalEvent.rockchipAuthorizedAgentSchemaVersion,
          eventID: eventID("finalized"), sequence: sequence,
          sessionID: layout.sessionID, jobID: layout.jobID,
          timestamp: Self.timestamp(), kind: .finalized,
          payload: [
            "terminalStatus": .string("succeeded"),
            "manifestSha256": .string(document.sha256),
            "outcomeCertainty": .string("confirmed"),
          ]))
      return document
    }
    _ = await coordinator.reportWriteFailure(
      claimID: claim.claimID, errno: 0, terminalDisposition: .succeeded)
    let record = try SessionAuditRecord(
      recordID: eventID("terminal-audit"), auditID: "rockchip-authorized-agent",
      correlationID: layout.sessionID, sessionID: layout.sessionID, jobID: layout.jobID,
      category: .outcome, timestamp: Self.timestamp(),
      details: [
        "status": .string("succeeded"),
        "evidenceClass": .string("\(admission.evidenceClass.rawValue)"),
        "hardwareSupportEligible": .bool(admission.evidenceClass == .production),
      ])
    let receipt = try SessionStorageTerminalFinalizer(
      audit: audit, manifestPublisher: publisher
    ).persist(claim: claim, disposition: .succeeded, auditRecord: record, manifest: manifest)
    _ = try await coordinator.completeRecoveredFinalization(receipt)
    if let storageContext {
      await storageContext.registerFinalizedSession(layout.root)
    }
    return layout.manifestURL
  }

  private func makeManifest(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) throws -> SessionManifestDocument {
    let completedAt = Self.timestamp()
    let stepValues = try plan.steps.map { step -> JSONValue in
      var declaration: [String: JSONValue]
      guard
        case .object(let object) = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(step))
      else {
        throw RockchipFlashExecutionError.persistenceRejected("step declaration")
      }
      declaration = object
      let record = stepRecords[step.id]
      declaration["argumentsHash"] = .string(
        try JournalCanonicalJSON.argumentsHash(step.arguments))
      declaration["sourceStepId"] = .null
      declaration["compensationTrigger"] = .null
      declaration["disposition"] = .string(record?.disposition ?? "skipped")
      declaration["outcomeCertainty"] = .string(record?.outcomeCertainty ?? "notApplicable")
      declaration["bindingRevision"] =
        step.bindingRequirement == .confirmedDevice
        ? .integer(Int64(admission.bindingRevision)) : .null
      declaration["semanticResult"] = .string(record?.semanticResult ?? "notRun")
      if let exitCode = record?.exitCode { declaration["exitCode"] = .integer(Int64(exitCode)) }
      return .object(declaration)
    }
    let authorizationReference = Self.authorizationReference(admission.authorizationReference)
    let relatedConfirmationSteps = plan.steps.filter {
      $0.arguments["confirmationId"] == .string(plan.confirmationID)
    }.map { JSONValue.string($0.id) }
    let artifactValues = try artifacts.map {
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
    }
    let root: JSONValue = .object([
      "schemaVersion": .string("2.1.0"),
      "appVersion": .string("ArkDeckKit-1.0.0"),
      "coreSpecBaseline": .string("CORE-2.0.0"),
      "platformProfile": .string("macos-1.0.0"),
      "sessionId": .string(layout.sessionID),
      "jobId": .string(layout.jobID),
      "status": .string("succeeded"),
      "executionMode": .string("execute"),
      "executionAuthority": .string("authorizedAgent"),
      "authorization": .object([
        "authorizationRef": authorizationReference,
        "usageReservationId": .string(admission.usageReservationID),
        "destructiveIntentEventIds": .array(destructiveIntentEventIDs.map(JSONValue.string)),
      ]),
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(createdAt),
      "completedAt": .string(completedAt),
      "archivedAt": .null,
      "originalTarget": .object([
        "kind": .string("real"), "connectKey": .string(admission.usbTopology),
        "transport": .string("usb"),
        "identitySnapshot": .object([
          "serialSha256": .string(admission.serialDigestSHA256),
          "usbTopology": .string(admission.usbTopology),
        ]),
      ]),
      "bindingHistory": .array([
        .object([
          "revision": .integer(Int64(admission.bindingRevision)),
          "connectKey": .string(admission.usbTopology), "transport": .string("usb"),
          "identitySnapshot": .object([
            "serialSha256": .string(admission.serialDigestSHA256),
            "usbTopology": .string(admission.usbTopology),
          ]),
          "evidence": .array([.string("trusted durable binding and fresh USB readback")]),
          "confirmedBy": .string("corePolicy"),
          "channelProtection": .string("unverifiedAssumeUnprotected"),
        ])
      ]),
      "toolchain": .object([
        "kind": .string("rockchip"),
        "profileIdentifier": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier),
        "reportedVersion": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion),
        "sha256": .string(
          RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256),
        "pathSource": .string("userSelectedSecurityScopedBookmark"),
        "descriptorIdentity": .object([
          "device": .unsignedInteger(admission.executableIdentity.device),
          "inode": .unsignedInteger(admission.executableIdentity.inode),
          "fileSize": .integer(admission.executableIdentity.fileSize),
          "mode": .unsignedInteger(UInt64(admission.executableIdentity.mode)),
        ]),
      ]),
      "workflow": .object([
        "kind": .string("rockchipFlash"),
        "profileVersion": .string(RockchipFlashProfile.profileVersion),
        "providerIdentity": .string(RockchipRockUSBFlashProvider.providerIdentity),
      ]),
      "steps": .array(stepValues), "parameters": .array([]),
      "compensations": .array([]),
      "confirmations": .array([
        .object([
          "confirmationId": .string(plan.confirmationID),
          "kind": .string("destructive"),
          "scopeHash": plan.steps.first(where: { $0.kind == .requestConfirmation })?
            .arguments["scopeHash"] ?? .string(String(repeating: "0", count: 64)),
          "decision": .string("accepted"),
          "actor": .object([
            "kind": .string("authorizedAgent"),
            "authorizationRef": authorizationReference,
          ]),
          "decidedAt": .string(createdAt),
          "relatedStepIds": .array(relatedConfirmationSteps),
        ])
      ]),
      "artifacts": .array(artifactValues), "warnings": .array([]),
      "failure": .null, "recovery": .null,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try SessionManifestDocument(data: encoder.encode(root))
  }

  private func persistRawStreams(stepID: String, execution: ProcessExecutionResult) throws {
    for (stream, capture) in [("stdout", execution.stdout), ("stderr", execution.stderr)]
    where !capture.data.isEmpty {
      let sourceName = ".raw-\(stepID)-\(stream)-\(UUID().uuidString)"
      let sourceURL = layout.root.appending(path: sourceName)
      try Self.writeOwnerOnly(capture.data, to: sourceURL)
      defer { _ = Darwin.unlink(sourceURL.path) }
      let artifactID = "\(stepID)-\(stream)"
      let published = try artifactStore.publish(
        from: sourceURL,
        request: ArtifactPublicationRequest(
          artifactID: artifactID, role: .raw,
          publicationName: "\(artifactID).bin",
          origin: "rockchip-process-\(stream)", mediaType: "application/octet-stream"),
        claim: claim)
      artifacts.append(published.record)
    }
  }

  private func append(_ event: JournalEvent) throws {
    try journal.appendAndSynchronize(event)
    sequence += 1
  }

  private func eventID(_ suffix: String) -> String {
    "rk-\(sequence)-\(suffix)".replacingOccurrences(of: "_", with: "-")
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private static func exitCode(_ execution: ProcessExecutionResult) -> Int32? {
    if case .exited(let code) = execution.termination { return code }
    return nil
  }

  private static func authorizationReference(_ reference: AuthorizationReference) -> JSONValue {
    .object([
      "authorizationId": .string(reference.authorizationID),
      "mainCommitOID": .string(reference.mainCommitOID),
      "authorizationBlobOID": .string(reference.authorizationBlobOID),
      "approvalPRNumber": .integer(Int64(reference.approvalPRNumber)),
    ])
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
          continue
        }
        if count < 0, errno == EINTR { continue }
        throw SessionStorageError.writeFailed(path: url.path, errno: errno)
      }
    }
    guard fsync(descriptor) == 0 else {
      throw SessionStorageError.writeFailed(path: url.path, errno: errno)
    }
  }

  func auditRecordsForTesting(correlationID: String) throws -> [SessionAuditRecord] {
    try audit.replay(correlationID: correlationID)
  }
}

private struct RockchipPersistedStepResult {
  let disposition: String
  let outcomeCertainty: String
  let semanticResult: String
  let exitCode: Int32?
}

// MARK: - Production composition

private enum RockchipProductionExecutionComposition {
  static func make() throws -> RockchipFlashExecutionDependencies {
    let settings = try RockchipProductExecutionSettings.load()
    let storage = try RockchipProductionStorageComposition.make()
    let clock = RockchipContinuousAdmissionClock()
    let usbProbe = RockchipProductUSBProbe()
    let provenance = GitHubProtectedMainAuthorizationPort(token: settings.githubToken)
    let ledger = try AuthorizationUsageLedger(root: settings.usageRoot)
    let admission = RockchipProductionAdmissionPort(
      provenance: provenance, usageLedger: ledger, binding: settings.binding,
      tool: settings.tool, clock: clock, usbProbe: usbProbe)
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: settings.tool.executableURL,
      securityScopedURL: settings.securityScopedURL,
      executor: FoundationProcessExecutor())
    let postflight = RockchipProductPostflightPort(probe: usbProbe)
    let coordinator = storage.context.coordinator
    let storageProbe = SystemHostStorageProbe()
    let requiredGrowth =
      UInt64(
        RockchipFlashProfile.dayu200.mappedPartitions.compactMap {
          RockchipFlashProfile.dayu200.member(named: $0.imageMemberName)?.sizeBytes
        }.reduce(Int64(0), +)) + 64 * 1_024 * 1_024
    return RockchipFlashExecutionDependencies(
      admission: admission, process: process, postflight: postflight,
      power: ProductRockchipPowerActivityController(),
      makePersistence: { sessionID, jobID, _ in
        let admission = try await storage.context.prepareHeavyWriterAdmission()
        let snapshot = try storageProbe.snapshot(for: storage.context.rootLease.url)
        guard snapshot.volumeIdentity == admission.volumeIdentity else {
          throw RockchipFlashExecutionError.storageRejected(
            "Session root volume identity changed")
        }
        let request = try StorageClaimRequest(
          claimID: "claim-\(jobID)", jobID: jobID, volumeIdentity: snapshot.volumeIdentity,
          budget: StorageBudget(
            metadataHeadroomBytes: 16 * 1_024 * 1_024,
            finalizationHeadroomBytes: 16 * 1_024 * 1_024,
            remainingGrowthBytes: requiredGrowth, writerClass: .heavy))
        guard
          case .admitted(let claim) = await storage.context.admitHeavyWriter(
            request, snapshot: snapshot, admission: admission)
        else { throw RockchipFlashExecutionError.storageRejected("host storage queued") }
        let layout = try await storage.context.createSession(
          sessionID: sessionID, jobID: jobID, createdAt: Date(), claim: claim,
          admission: admission)
        return try RockchipDurableExecutionPersistence(
          layout: layout, claim: claim, coordinator: coordinator,
          storageContext: storage.context)
      }, lifecycle: ProductRockchipExecutionLifecyclePort())
  }
}

struct RockchipProductionStorageComposition: Sendable {
  let context: SessionStorageExecutionContext

  static func make(
    runtime: SessionStorageApplicationRuntime = .production
  ) throws -> RockchipProductionStorageComposition {
    RockchipProductionStorageComposition(context: try runtime.makeExecutionContext())
  }
}

private struct RockchipProductBindingSnapshot: Codable, Sendable {
  let revision: Int
  let serial: String
  let usbTopology: String
  let evidence: [String]
}

private final class RockchipProductExecutionSettings: @unchecked Sendable {
  let usageRoot: URL
  let tool: RockchipSelectedDiscoveryTool
  let securityScopedURL: URL
  let githubToken: String
  let binding: RockchipProductBindingSnapshot

  private init(
    usageRoot: URL,
    tool: RockchipSelectedDiscoveryTool,
    securityScopedURL: URL,
    githubToken: String,
    binding: RockchipProductBindingSnapshot
  ) {
    self.usageRoot = usageRoot
    self.tool = tool
    self.securityScopedURL = securityScopedURL
    self.githubToken = githubToken
    self.binding = binding
  }

  static func load() throws -> RockchipProductExecutionSettings {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    let usage = root.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    for directory in [root, usage] {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chmod(directory.path, 0o700) == 0 else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "owner-only Application Support directory")
      }
    }

    let defaults = UserDefaults.standard
    guard let bookmark = defaults.data(forKey: "ArkDeck.Rockchip.ToolBookmark") else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "pinned rkdeveloptool bookmark is not installed")
    }
    var stale = false
    let executableURL = try URL(
      resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, executableURL.isFileURL, executableURL.path.hasPrefix("/"),
      executableURL.startAccessingSecurityScopedResource()
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "rkdeveloptool bookmark is stale or inaccessible")
    }
    let trustRaw = defaults.string(forKey: "ArkDeck.Rockchip.ToolCodeTrust")
    let trust = trustRaw.flatMap(RockchipPlatformCodeTrust.init(rawValue:)) ?? .unknown
    guard defaults.object(forKey: "ArkDeck.Rockchip.ToolQuarantinePresent") != nil else {
      executableURL.stopAccessingSecurityScopedResource()
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "tool quarantine assessment is absent")
    }
    let quarantine = defaults.bool(forKey: "ArkDeck.Rockchip.ToolQuarantinePresent")
    let selectedTool = RockchipSelectedDiscoveryTool(
      executableURL: executableURL, pathSource: .userSelectedSecurityScopedBookmark,
      securityScopedBookmark: bookmark,
      reportedVersion: RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: trust, quarantinePresent: quarantine))
    guard let token = try productKeychainToken(), !token.isEmpty else {
      executableURL.stopAccessingSecurityScopedResource()
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "product GitHub provenance credential is not installed in Keychain")
    }
    let bindingURL = root.appending(path: "rockchip-binding.json")
    let bindingData = try Data(contentsOf: bindingURL, options: [.mappedIfSafe])
    let binding = try JSONDecoder().decode(RockchipProductBindingSnapshot.self, from: bindingData)
    guard binding.revision > 0, !binding.serial.isEmpty,
      !binding.usbTopology.isEmpty,
      binding.usbTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      !binding.evidence.isEmpty, binding.evidence.allSatisfy({ !$0.isEmpty })
    else {
      executableURL.stopAccessingSecurityScopedResource()
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable Rockchip binding snapshot is invalid")
    }
    return RockchipProductExecutionSettings(
      usageRoot: usage, tool: selectedTool,
      securityScopedURL: executableURL, githubToken: token, binding: binding)
  }

  private static func productKeychainToken() throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "dev.arkdeck.github-provenance",
      kSecAttrAccount: "protected-main-reader",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "Keychain provenance credential cannot be read")
    }
    return String(data: data, encoding: .utf8)
  }
}

private struct RockchipProductUSBIdentity: Sendable, Equatable {
  let serial: String
  let vendorID: UInt16
  let productID: UInt16
  let topology: String
}

private struct RockchipProductUSBProbe: Sendable {
  func singleLoader(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(selector: selector, requiresLoader: true)
  }

  func singleConnected(selector: String) throws -> RockchipProductUSBIdentity {
    try single(selector: selector, requiresLoader: false)
  }

  private func single(selector: String?, requiresLoader: Bool) throws
    -> RockchipProductUSBIdentity
  {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable") }
    defer { IOObjectRelease(iterator) }
    var matches: [RockchipProductUSBIdentity] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      guard let vendor = number(service, "idVendor"),
        let product = number(service, "idProduct"),
        let location = number(service, "locationID"),
        let serial = string(service, "USB Serial Number")
          ?? string(service, "kUSBSerialNumberString"),
        !requiresLoader
          || (vendor.uint16Value == RockchipProbeEvidence.rockUSBVendorID
            && product.uint16Value == RockchipProbeEvidence.dayu200LoaderProductID)
      else { continue }
      let identity = RockchipProductUSBIdentity(
        serial: serial, vendorID: vendor.uint16Value,
        productID: product.uint16Value, topology: String(location.uint64Value))
      if selector == nil || selector == identity.topology { matches.append(identity) }
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "Loader target unavailable" : "Loader target ambiguous")
    }
    return match
  }

  private func number(_ service: io_registry_entry_t, _ key: String) -> NSNumber? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber
  }

  private func string(_ service: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}

private struct RockchipProductBindingPort: RockchipDurableBindingFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let snapshot: RockchipProductBindingSnapshot

  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact {
    let identity = try DeviceIdentitySnapshot(attributes: [
      "serial": .string(snapshot.serial), "usbTopology": .string(snapshot.usbTopology),
    ])
    let binding = try CurrentDeviceBinding(
      revision: snapshot.revision, connectKey: snapshot.usbTopology, transport: .usb,
      identitySnapshot: identity, evidence: snapshot.evidence, confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
    return RockchipTrustedDurableBindingFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      receipt: try DurableCurrentDeviceBinding(
        reference: DeviceBindingReference(targetID: targetID, revision: snapshot.revision),
        binding: binding))
  }
}

private struct RockchipProductPrerequisitePort: RockchipPrerequisiteFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let probe: RockchipProductUSBProbe

  func probePrerequisites() async throws -> RockchipTrustedPrerequisiteFact {
    _ = try probe.singleLoader(selector: selector)
    return RockchipTrustedPrerequisiteFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observations: [
        RockchipPrerequisiteObservation(identifier: .loader, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .recoveryPath, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .unlocked, status: .satisfied),
      ])
  }
}

private struct RockchipProductIdentityReadbackPort: RockchipIdentityReadbackFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let observationSequence: UInt64
  let probe: RockchipProductUSBProbe
  let clock: any RockchipAdmissionClock

  func readIdentity() async throws -> RockchipTrustedIdentityReadbackFact {
    let identity = try probe.singleLoader(selector: selector)
    let reading = clock.now()
    return RockchipTrustedIdentityReadbackFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observationSequence: observationSequence,
      observedAtMonotonicNanoseconds: reading.monotonicNanoseconds,
      deadlineMonotonicNanoseconds: reading.monotonicNanoseconds
        + RockchipAuthorizationFactCollector.maximumReadbackLifetimeNanoseconds,
      observedAtTimestamp: reading.auditTimestamp,
      serialDigestSHA256: SHA256.hash(data: Data(identity.serial.utf8)).map {
        String(format: "%02x", $0)
      }.joined(),
      usbVendorID: identity.vendorID, usbProductID: identity.productID,
      usbTopology: identity.topology)
  }
}

private struct RockchipProductPostflightPort: RockchipExecutionPostflightPort {
  let probe: RockchipProductUSBProbe

  func probe(expectedTopology: String) async throws -> RockchipPostflightReceipt {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while ContinuousClock.now < deadline {
      if let identity = try? probe.singleConnected(selector: expectedTopology) {
        let digest = SHA256.hash(data: Data(identity.serial.utf8)).map {
          String(format: "%02x", $0)
        }.joined()
        return RockchipPostflightReceipt(
          connected: true, serialDigestSHA256: digest,
          usbTopology: identity.topology)
      }
      try await Task.sleep(for: .seconds(1))
    }
    return RockchipPostflightReceipt(
      connected: false, serialDigestSHA256: String(repeating: "0", count: 64),
      usbTopology: expectedTopology)
  }
}

private final class RockchipProductionAdmissionPort: @unchecked Sendable,
  RockchipExecutionAdmissionPort
{
  private let provenance: GitHubProtectedMainAuthorizationPort
  private let usageLedger: AuthorizationUsageLedger
  private let binding: RockchipProductBindingSnapshot
  private let tool: RockchipSelectedDiscoveryTool
  private let clock: any RockchipAdmissionClock
  private let usbProbe: RockchipProductUSBProbe

  init(
    provenance: GitHubProtectedMainAuthorizationPort,
    usageLedger: AuthorizationUsageLedger,
    binding: RockchipProductBindingSnapshot,
    tool: RockchipSelectedDiscoveryTool,
    clock: any RockchipAdmissionClock,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.provenance = provenance
    self.usageLedger = usageLedger
    self.binding = binding
    self.tool = tool
    self.clock = clock
    self.usbProbe = usbProbe
  }

  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID: String,
    jobID: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission {
    let sequence: UInt64 = 1
    let collector = RockchipAuthorizationFactCollector(
      planPort: RockchipProductExecutePlanFactPort(),
      bindingPort: RockchipProductBindingPort(
        sessionID: sessionID, jobID: jobID, targetID: targetID, snapshot: binding),
      toolDevicePort: RockchipDiscoveryToolDeviceFactPort(
        sessionID: sessionID, jobID: jobID, targetID: targetID,
        observationSequence: sequence, adapter: RockchipDeviceDiscoveryAdapter(),
        tool: tool, clock: clock),
      prerequisitePort: RockchipProductPrerequisitePort(
        sessionID: sessionID, jobID: jobID, targetID: targetID,
        selector: request.targetLocationSelector, probe: usbProbe),
      identityReadbackPort: RockchipProductIdentityReadbackPort(
        sessionID: sessionID, jobID: jobID, targetID: targetID,
        selector: request.targetLocationSelector, observationSequence: sequence,
        probe: usbProbe, clock: clock),
      clock: clock)
    let service = AuthorizationAdmissionService(
      resolver: MaintainerMergedAuthorizationResolver(port: provenance),
      factCollector: collector, usageLedger: usageLedger, clock: clock)
    let token = try await service.admit(
      AuthorizationAdmissionRequest(
        authorizationID: request.authorizationID,
        facts: RockchipAuthorizationFactRequest(
          archiveURL: request.archiveURL, sessionID: sessionID, jobID: jobID,
          targetID: targetID, targetLocationSelector: request.targetLocationSelector)))
    return RockchipExecutionAdmission(
      backing: .production(token), plan: token.facts.plan,
      authorizationReference: token.authorizationReference,
      usageReservationID: token.usageReservation.reservationID,
      targetID: targetID, bindingRevision: token.facts.bindingReference.revision,
      targetDigestSHA256: token.facts.targetDigestSHA256,
      serialDigestSHA256: token.facts.serialDigestSHA256,
      usbTopology: token.facts.usbTopology,
      executableIdentity: token.facts.executableIdentity,
      evidenceClass: .production)
  }

  func authorizeAndConsume(_ admission: RockchipExecutionAdmission) async throws {
    guard case .production(let token) = admission.backing else {
      throw RockchipFlashExecutionError.authorizationGateRejected("production token missing")
    }
    let decision = await RockchipFlashAuthorizationGate().authorizeUnattended(
      admission: token, plan: admission.plan, monitor: RockchipFlashDispatchMonitor())
    guard case .authorizedAgentAdmissionAccepted(let reservationID) = decision.outcome,
      reservationID == admission.usageReservationID,
      decision.authorizationRef == admission.authorizationReference,
      decision.dispatchSnapshot.totalDispatchCount == 0
    else {
      throw RockchipFlashExecutionError.authorizationGateRejected(decision.jobMarker)
    }
    let consumed = try token.consume(at: clock.now())
    guard consumed.authorizationReference == admission.authorizationReference,
      consumed.usageReservation.reservationID == admission.usageReservationID,
      consumed.facts.executableIdentity == admission.executableIdentity
    else { throw RockchipFlashExecutionError.authorizationGateRejected("consume correlation") }
  }

  func closeUsage(
    admission: RockchipExecutionAdmission,
    status: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs: [String]
  ) throws {
    let terminal = try AuthorizationUsageTerminal(
      status: status, closedAt: clock.now().auditTimestamp,
      destructiveIntentEventIDs: destructiveIntentEventIDs)
    _ = try usageLedger.close(
      reservationID: admission.usageReservationID, terminal: terminal)
  }
}

// MARK: - Fresh protected-main GitHub provenance

private struct GitHubProtectedMainAuthorizationPort: AuthorizationProvenancePort, Sendable {
  let token: String

  func fetchFreshSnapshot(authorizationID: String, registryPath: String) async throws
    -> AuthorizationProvenanceSnapshot
  {
    let branch: GitHubBranch = try await get("/repos/ArkDeck/ArkDeck/branches/main")
    let authorization = try await content(path: registryPath, ref: "main")
    let pullRequestNumber = try authorizationPullRequestNumber(authorization.data)
    let pullRequest: GitHubPullRequest = try await get(
      "/repos/ArkDeck/ArkDeck/pulls/\(pullRequestNumber)")
    guard let mergeCommitOID = pullRequest.mergeCommitSHA else {
      throw AuthorizationProvenanceError.pullRequestNotMerged
    }
    async let headContent = content(path: registryPath, ref: pullRequest.head.sha)
    async let mergeContent = content(path: registryPath, ref: mergeCommitOID)
    async let reviews: [GitHubReview] = get(
      "/repos/ArkDeck/ArkDeck/pulls/\(pullRequestNumber)/reviews?per_page=100")
    async let codeOwners = content(path: ".github/CODEOWNERS", ref: "main")
    async let comparison: GitHubComparison = get(
      "/repos/ArkDeck/ArkDeck/compare/\(mergeCommitOID)...main")
    let (reviewed, merged, reviewRows, owners, ancestry) = try await (
      headContent, mergeContent, reviews, codeOwners, comparison
    )
    return AuthorizationProvenanceSnapshot(
      repositoryFullName: "ArkDeck/ArkDeck", branchName: "main",
      branchProtected: branch.protected, mainCommitOID: branch.commit.sha,
      registryPath: registryPath, authorizationBytes: authorization.data,
      authorizationBlobOID: authorization.sha,
      reviewedHeadBlobOID: reviewed.sha, mergeCommitBlobOID: merged.sha,
      pullRequestNumber: pullRequest.number, pullRequestMerged: pullRequest.merged,
      pullRequestBaseBranch: pullRequest.base.ref,
      pullRequestAuthorLogin: pullRequest.user.login,
      pullRequestHeadOID: pullRequest.head.sha, mergeCommitOID: mergeCommitOID,
      mergeCommitIsAncestorOfMain: ["ahead", "identical"].contains(ancestry.status),
      mergedByLogin: pullRequest.mergedBy?.login ?? "",
      reviews: reviewRows.map {
        AuthorizationApprovalReview(
          reviewerLogin: $0.user.login,
          state: Self.reviewState($0.state),
          commitOID: $0.commitID ?? "")
      },
      codeOwnersBytes: owners.data, codeOwnersBlobOID: owners.sha)
  }

  private func content(path: String, ref: String) async throws -> (data: Data, sha: String) {
    let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ref
    let response: GitHubContent = try await get(
      "/repos/ArkDeck/ArkDeck/contents/\(path)?ref=\(encodedRef)")
    guard response.encoding == "base64",
      let data = Data(base64Encoded: response.content.replacingOccurrences(of: "\n", with: ""))
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    return (data, response.sha)
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    guard let url = URL(string: "https://api.github.com\(path)") else {
      throw AuthorizationProvenanceError.sourceUnavailable
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("ArkDeck/1.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AuthorizationProvenanceError.sourceUnavailable
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private func authorizationPullRequestNumber(_ data: Data) throws -> Int {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let carrier = object["carrier"] as? String
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    let expression = try NSRegularExpression(pattern: #"PR #([0-9]+)"#)
    let range = NSRange(carrier.startIndex..<carrier.endIndex, in: carrier)
    guard let match = expression.firstMatch(in: carrier, range: range),
      let numberRange = Range(match.range(at: 1), in: carrier),
      let number = Int(carrier[numberRange]), number > 0
    else { throw AuthorizationProvenanceError.sourceUnavailable }
    return number
  }

  private static func reviewState(_ value: String) -> AuthorizationReviewState {
    switch value.uppercased() {
    case "APPROVED": .approved
    case "CHANGES_REQUESTED": .changesRequested
    case "DISMISSED": .dismissed
    default: .commented
    }
  }
}

private struct GitHubBranch: Decodable {
  let protected: Bool
  let commit: GitHubCommit
}

private struct GitHubCommit: Decodable { let sha: String }

private struct GitHubContent: Decodable {
  let content: String
  let encoding: String
  let sha: String
}

private struct GitHubUser: Decodable { let login: String }

private struct GitHubPullRef: Decodable {
  let ref: String
  let sha: String
}

private struct GitHubPullRequest: Decodable {
  let number: Int
  let merged: Bool
  let mergeCommitSHA: String?
  let base: GitHubPullRef
  let head: GitHubPullRef
  let user: GitHubUser
  let mergedBy: GitHubUser?

  enum CodingKeys: String, CodingKey {
    case number, merged, base, head, user
    case mergeCommitSHA = "merge_commit_sha"
    case mergedBy = "merged_by"
  }
}

private struct GitHubReview: Decodable {
  let user: GitHubUser
  let state: String
  let commitID: String?

  enum CodingKeys: String, CodingKey {
    case user, state
    case commitID = "commit_id"
  }
}

private struct GitHubComparison: Decodable { let status: String }
