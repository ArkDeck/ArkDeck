import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RockchipTargetAliasReconciliationContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-target-alias-reconciliation", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testCompleteLaterFlashAppendsRelationWithoutRewritingUnknownJobOrTargets() async throws {
    let fixture = try makeFixture(unknownStepID: "enter-loader-mode")
    let unknownBefore = try RuntimeJobRecord.load(from: fixture.unknownJobDirectory)
    let targetsBefore = try fixture.targetStore.list()

    let resolution = try XCTUnwrap(fixture.reconciler.reconcileIfProven())

    XCTAssertEqual(resolution.aliasTargetID, fixture.alias.targetID)
    XCTAssertEqual(resolution.canonicalTargetID, fixture.canonical.targetID)
    XCTAssertEqual(resolution.establishingFlashJobID, fixture.establishingFlashJobID)
    XCTAssertEqual(resolution.coveredUnknownIntents.count, 1)
    XCTAssertEqual(resolution.coveredUnknownIntents.first?.stepID, "enter-loader-mode")
    XCTAssertEqual(try fixture.targetStore.list(), targetsBefore)
    XCTAssertEqual(try fixture.targetStore.listActive(), [fixture.canonical])
    XCTAssertEqual(
      try fixture.targetStore.candidateTarget(connectKey: fixture.alias.connectKey),
      fixture.canonical)
    XCTAssertEqual(
      try RuntimeJobRecord.load(from: fixture.unknownJobDirectory), unknownBefore,
      "the old outcome stays unknown and immutable")
    XCTAssertTrue(unknownBefore.outcomeUnknown)
    XCTAssertEqual(try fixture.reconciler.reconcileIfProven(), resolution)

    let laterFlashJobID = "job-44444444444444444444444444444444"
    try writeSuccessfulFlashJob(
      state: fixture.stateDirectory, jobID: laterFlashJobID,
      target: fixture.canonical,
      startedAtUTC: "2026-08-08T00:30:00Z",
      finishedAtUTC: "2026-08-08T00:35:00Z")
    _ = try fixture.postFlashStore.publish(
      RockchipPostFlashHDCBinding(
        targetID: fixture.canonical.targetID,
        bindingRevision: fixture.canonical.bindingRevision,
        stableLoaderIdentitySHA256:
          fixture.canonical.stablePhysicalIdentitySHA256,
        previousHDCIdentitySHA256:
          fixture.alias.stablePhysicalIdentitySHA256,
        hdcIdentitySHA256: fixture.alias.stablePhysicalIdentitySHA256,
        hdcConnectKey: fixture.alias.connectKey,
        usbTopology: resolution.routedUSBTopology,
        productModel: "ohos", buildVersion: "OpenHarmony-7.0.0.37",
        jobID: laterFlashJobID,
        establishedAtUTC: "2026-08-08T00:34:00Z"),
      expectedPreviousHDCIdentitySHA256:
        fixture.alias.stablePhysicalIdentitySHA256)
    XCTAssertEqual(
      try fixture.reconciler.reconcileIfProven(), resolution,
      "a later Flash with the same exact identities must reuse the durable relation")
    XCTAssertEqual(try fixture.targetStore.aliasResolutions(), [resolution])

    let admission = try RuntimeAdmissionService(stateDirectory: fixture.stateDirectory)
    _ = try admission.admit(
      record: unknownBefore, requestHash: String(repeating: "f", count: 64))
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: fixture.stateDirectory.appending(
        path:
          "capabilities", directoryHint: .isDirectory))
    let resolver = try FixedExecutableResolver.hashing(path: "/bin/ls", providerID: "hdc")
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: fixture.stateDirectory),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: DescriptorBoundProcessDispatcher(resolver: resolver),
      capabilityStore: capabilityStore,
      nowUTC: { "2026-08-08T00:20:00Z" })
    let status = try await engine.status(jobID: unknownBefore.jobID)
    XCTAssertTrue(status.outcomeUnknown)
    XCTAssertEqual(status.resolvedByTargetAliasResolutionID, resolution.resolutionID)
  }

  func testDestructiveUnknownAliasIntentCannotBeCoveredByNormalModePostflight() throws {
    let fixture = try makeFixture(unknownStepID: "flash-partitions")

    XCTAssertThrowsError(try fixture.reconciler.reconcileIfProven())
    XCTAssertTrue(try fixture.targetStore.aliasResolutions().isEmpty)
    XCTAssertEqual(try fixture.targetStore.listActive().count, 2)
  }

  func testUnreadableHistoricalJobFailsClosedInsteadOfBeingSkipped() throws {
    let fixture = try makeFixture(unknownStepID: "enter-loader-mode")
    let malformed = root.appending(
      path:
        "state/jobs/job-33333333333333333333333333333333", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(
      to: malformed.appending(path: "job-record.json"))

    XCTAssertThrowsError(try fixture.reconciler.reconcileIfProven())
    XCTAssertTrue(try fixture.targetStore.aliasResolutions().isEmpty)
  }

  private struct Fixture {
    let reconciler: ProductRockchipTargetAliasReconciler
    let targetStore: RuntimeTargetStore
    let canonical: RuntimeTargetRecord
    let alias: RuntimeTargetRecord
    let establishingFlashJobID: String
    let unknownJobDirectory: URL
    let stateDirectory: URL
    let postFlashStore: RockchipPostFlashHDCBindingStore
  }

  private func makeFixture(unknownStepID: String) throws -> Fixture {
    let state = root.appending(path: "state", directoryHint: .isDirectory)
    _ = try RuntimeJobRepository(stateDirectory: state)
    let applicationSupport = root.appending(
      path:
        "application-support", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(
      directoryURL: state.appending(path: "targets", directoryHint: .isDirectory))
    let bindingStore = RockchipProductBindingStore(rootURL: applicationSupport)
    let postFlashStore = RockchipPostFlashHDCBindingStore(rootURL: applicationSupport)
    let originalConnectKey = "original-hdc-address"
    let originalIdentity = digest(originalConnectKey)
    let loaderSerial = "loader-serial"
    let loaderIdentity = digest(loaderSerial)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: originalIdentity, connectKey: originalConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let canonical = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: originalIdentity, previousRevision: 1,
        currentStableIdentitySHA256: loaderIdentity, currentRevision: 2)
    ).record
    _ = try bindingStore.install(
      RockchipProductBindingSnapshot(
        revision: canonical.bindingRevision, serial: loaderSerial, usbTopology: "42",
        evidence: [
          "product:e0-iokit-single-loader-readback",
          "identity:serial-sha256=\(loaderIdentity)",
          "identity:previous-serial-sha256=\(originalIdentity)",
          "binding:previous-revision=\(adopted.bindingRevision)",
          "binding:previous-usb-topology=42",
          "identity:hdc-normal-alias-sha256=\(originalIdentity)",
          "binding:hdc-normal-alias-usb-topology=42",
          "rebind:user-selection-sha256=\(String(repeating: "e", count: 64))",
        ]))

    let aliasConnectKey = "post-flash-hdc-address"
    let aliasIdentity = digest(aliasConnectKey)
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity, connectKey: aliasConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:01:00Z"
    ).record
    let unknownJobID = "job-22222222222222222222222222222222"
    let unknownDirectory = try writeUnknownJob(
      state: state, jobID: unknownJobID, target: alias,
      stepID: unknownStepID, timestamp: "2026-08-08T00:02:00Z")

    let establishingFlashJobID = "job-11111111111111111111111111111111"
    try writeSuccessfulFlashJob(
      state: state, jobID: establishingFlashJobID, target: canonical,
      startedAtUTC: "2026-08-08T00:05:00Z",
      finishedAtUTC: "2026-08-08T00:10:00Z")
    _ = try postFlashStore.publish(
      RockchipPostFlashHDCBinding(
        targetID: canonical.targetID,
        bindingRevision: canonical.bindingRevision,
        stableLoaderIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        previousHDCIdentitySHA256: originalIdentity,
        hdcIdentitySHA256: aliasIdentity,
        hdcConnectKey: aliasConnectKey,
        usbTopology: "42",
        productModel: "ohos",
        // The Runtime route pins what this immutable artifact actually
        // booted. It may legitimately differ from today's default profile.
        buildVersion: "OpenHarmony-7.0.0.37",
        jobID: establishingFlashJobID,
        establishedAtUTC: "2026-08-08T00:09:00Z"),
      expectedPreviousHDCIdentitySHA256: originalIdentity)

    return Fixture(
      reconciler: ProductRockchipTargetAliasReconciler(
        targetStore: targetStore, bindingStore: bindingStore,
        postFlashBindingStore: postFlashStore, stateDirectory: state),
      targetStore: targetStore, canonical: canonical, alias: alias,
      establishingFlashJobID: establishingFlashJobID,
      unknownJobDirectory: unknownDirectory, stateDirectory: state,
      postFlashStore: postFlashStore)
  }

  private func writeUnknownJob(
    state: URL, jobID: String, target: RuntimeTargetRecord,
    stepID: String, timestamp: String
  ) throws -> URL {
    let request = try flashRequest(jobID: jobID, target: target)
    var record = RuntimeJobRecord(
      jobID: jobID, request: request, operationReference: "flash.dayu200",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: "rockchip", createdAtUTC: timestamp,
      actualEffect: stepID == "flash-partitions" ? "destructive" : "deviceMutation",
      admissionEvidence: nil,
      materializedPlanDigest: String(repeating: "9", count: 64),
      materializedStableTargetIdentitySHA256: target.stablePhysicalIdentitySHA256,
      materializedBindingRevision: target.bindingRevision)
    record.originalSubmissionRequest = record.request
    record.state = JobState.waitingForRecovery.rawValue
    record.outcomeUnknown = true
    record.startedAtUTC = timestamp
    let directory = try jobDirectory(state: state, jobID: jobID)
    try record.persist(into: directory)
    let journal = try FileDurableJournal(
      url: directory.appending(path: "journal.jsonl"))
    var sequence = try appendRunningPrefix(
      journal: journal, record: record, timestamp: timestamp)
    let step = try workflowStep(stepID)
    try journal.appendAndSynchronize(
      try stepIntent(
        record: record, step: step, eventID: "intent-\(stepID)",
        sequence: sequence, timestamp: timestamp))
    sequence += 1
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "waiting-\(jobID)", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
        from: .running, to: .waitingForRecovery, reason: "fixture outcome unknown",
        schemaVersion: JournalEvent.schemaVersion))
    return directory
  }

  private func writeSuccessfulFlashJob(
    state: URL, jobID: String, target: RuntimeTargetRecord,
    startedAtUTC: String, finishedAtUTC: String
  ) throws {
    let request = try flashRequest(jobID: jobID, target: target)
    let planDigest = String(repeating: "a", count: 64)
    let correlation = RuntimeCapabilityEvidenceCorrelation(
      reservationID: request.idempotencyKey, useOrdinal: 1,
      planDigestSHA256: planDigest,
      stepSetDigestSHA256: String(repeating: "b", count: 64),
      targetBindingDigestSHA256: RuntimeJobRecord.sha256Hex(Data("\(target.stablePhysicalIdentitySHA256)\n\(target.bindingRevision)".utf8)),
      artifactSHA256: String(repeating: "d", count: 64))
    let evidence = RuntimeAdmissionEvidence(
      kind: .runtimeCapability, reference: "CAP-RT-ALIAS-FIXTURE",
      admittedAtUTC: startedAtUTC, validUntilUTC: "2026-12-31T00:00:00Z",
      consumptionFingerprintSHA256: String(repeating: "e", count: 64),
      runtimeCapabilityCorrelation: correlation)
    var record = RuntimeJobRecord(
      jobID: jobID, request: request, operationReference: "flash.dayu200",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: "rockchip", createdAtUTC: startedAtUTC,
      actualEffect: "destructive", admissionEvidence: evidence,
      materializedPlanDigest: planDigest,
      materializedStableTargetIdentitySHA256: target.stablePhysicalIdentitySHA256,
      materializedBindingRevision: target.bindingRevision)
    record.originalSubmissionRequest = record.request
    record.state = JobState.succeeded.rawValue
    record.startedAtUTC = startedAtUTC
    record.finishedAtUTC = finishedAtUTC
    let directory = try jobDirectory(state: state, jobID: jobID)
    try record.persist(into: directory)
    let journal = try FileDurableJournal(
      url: directory.appending(path: "journal.jsonl"))
    var sequence = try appendRunningPrefix(
      journal: journal, record: record, timestamp: startedAtUTC)
    for stepID in [
      "enter-loader-mode", "flash-partitions", "verify-flash-readback",
      "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
    ] {
      let step = try workflowStep(stepID)
      let intentID = "intent-\(stepID)"
      try journal.appendAndSynchronize(
        try stepIntent(
          record: record, step: step, eventID: intentID,
          sequence: sequence, timestamp: finishedAtUTC))
      sequence += 1
      try journal.appendAndSynchronize(
        try JournalEvent.stepOutcome(
          eventID: "outcome-\(stepID)", sequence: sequence,
          sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
          stepID: stepID, attempt: 1, correlatesToIntentEventID: intentID,
          result: "succeeded", outcomeCertainty: .confirmed,
          schemaVersion: JournalEvent.schemaVersion))
      sequence += 1
    }
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "finalizing-\(jobID)", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
        from: .running, to: .finalizing, reason: "fixture steps complete",
        schemaVersion: JournalEvent.schemaVersion))
    sequence += 1
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "succeeded-\(jobID)", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: finishedAtUTC,
        from: .finalizing, to: .succeeded, reason: "fixture finalized",
        schemaVersion: JournalEvent.schemaVersion))
  }

  private func appendRunningPrefix(
    journal: FileDurableJournal, record: RuntimeJobRecord, timestamp: String
  ) throws -> Int {
    let schema = JournalEvent.schemaVersion
    try journal.appendAndSynchronize(
      try JournalEvent.jobCreated(
        eventID: "created-\(record.jobID)", sequence: 0,
        sessionID: record.sessionID, jobID: record.jobID, timestamp: timestamp,
        executionMode: "execute", schemaVersion: schema))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "preflight-\(record.jobID)", sequence: 1,
        sessionID: record.sessionID, jobID: record.jobID, timestamp: timestamp,
        from: .queued, to: .preflight, reason: "fixture admitted",
        schemaVersion: schema))
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "running-\(record.jobID)", sequence: 2,
        sessionID: record.sessionID, jobID: record.jobID, timestamp: timestamp,
        from: .preflight, to: .running, reason: "fixture running",
        schemaVersion: schema))
    return 3
  }

  private func stepIntent(
    record: RuntimeJobRecord, step: WorkflowStep, eventID: String,
    sequence: Int, timestamp: String
  ) throws -> JournalEvent {
    try JournalEvent.stepIntent(
      eventID: eventID, sequence: sequence, sessionID: record.sessionID,
      jobID: record.jobID, timestamp: timestamp, step: step,
      target: JournalTarget(
        scope: "device", targetID: record.request.target.targetID,
        connectKey: "fixture-connect-key",
        identitySnapshotHash: record.materializedStableTargetIdentitySHA256!),
      attempt: 1, bindingRevision: record.materializedBindingRevision,
      schemaVersion: JournalEvent.schemaVersion)
  }

  private func workflowStep(_ stepID: String) throws -> WorkflowStep {
    switch stepID {
    case "enter-loader-mode":
      try WorkflowStep(
        id: stepID, kind: .enterUpdater, declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("enterLoaderMode"),
          "expectedMode": .string("loader"),
          "reconnectDeadlineMilliseconds": .integer(60_000),
        ])
    case "flash-partitions":
      try WorkflowStep(
        id: stepID, kind: .flashPartition, declaredEffect: .destructive,
        declaredCancellation: .criticalNonInterruptible,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "providerOperationId": .string("flashPartitions"),
          "partition": .string("userdata"),
          "imageArtifactId": .string("image-bundle"),
          "imageSha256": .string(String(repeating: "d", count: 64)),
          "imageSize": .integer(1),
          "confirmationId": .string("runtime-capability"),
          "safeBoundaryId": .string("complete-overwrite"),
        ])
    case "verify-flash-readback":
      try WorkflowStep(
        id: stepID, kind: .verifyRemoteState, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "probeId": .string("flashReadback"), "expectedState": .string("complete"),
        ])
    case "reboot-device":
      try WorkflowStep(
        id: stepID, kind: .rebootDevice, declaredEffect: .deviceMutation,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["targetMode": .string("normal"), "reason": .string("postFlash")])
    case "wait-for-hdc":
      try WorkflowStep(
        id: stepID, kind: .waitForReconnect, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: [
          "deadlineMilliseconds": .integer(60_000), "reason": .string("postFlash"),
        ])
    case "rebind-and-verify-build":
      try WorkflowStep(
        id: stepID, kind: .probeDevice, declaredEffect: .readOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .confirmedDevice,
        arguments: ["evidencePolicy": .string("postFlashBuild")])
    default:
      throw NSError(domain: "target-alias-fixture", code: 1)
    }
  }

  private func flashRequest(
    jobID: String, target: RuntimeTargetRecord
  ) throws -> RuntimeOperationRequest {
    let partitions = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200")?
        .completeOverwriteRecovery?.profile(reference: "dayu200")
    ).coveredEffects.map { String($0.dropFirst("partition:".count)) }
    return try RuntimeOperationRequest(
      requestID: "request-\(jobID)", idempotencyKey: "idempotency-\(jobID)",
      target: DurableTargetReference(
        targetID: target.targetID, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: [
        "imageBundleLease": .string(
          "lease-v1:alias-fixture:ART-0123456789abcdef0123456789abcdef"),
        "deviceProfile": .string("dayu200"),
        "partitionPlan": .array(partitions.map(JSONValue.string)),
        "postFlashVerification": .string("full"),
      ],
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-ALIAS-FIXTURE"))
  }

  private func jobDirectory(state: URL, jobID: String) throws -> URL {
    let directory = state.appending(path: "jobs/\(jobID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return directory
  }

  private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
