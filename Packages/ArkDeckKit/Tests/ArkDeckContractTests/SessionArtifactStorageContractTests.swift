import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import XCTest

final class SessionArtifactStorageContractTests: XCTestCase {
  func testTEST_AC_ART_001_01_failedSessionPreservesJournalPartialAndManifestStatus() async throws {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "event-created", sequence: 0, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        executionMode: "simulated"))

    let source = fixture.base.appending(path: "capture-source.bin")
    try Data("incomplete-capture".utf8).write(to: source)
    let coordinator = fixture.coordinator
    let claim = fixture.claim
    let store = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactFileSync {
          throw DurableFileError.syncFailed(path: "capture.part", errno: ENOSPC)
        }
      })
    var observedErrno: Int32?
    do {
      _ = try store.publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: "artifact-partial", role: .raw, publicationName: "capture.bin",
          origin: "injected ENOSPC receive"),
        claim: claim)
      XCTFail("injected file sync ENOSPC must fail publication")
    } catch SessionStorageError.writeFailed(_, let failure) {
      observedErrno = failure
    }
    let failureErrno = try XCTUnwrap(observedErrno)
    XCTAssertEqual(failureErrno, ENOSPC)
    _ = await coordinator.reportWriteFailure(claimID: claim.claimID, errno: failureErrno)
    XCTAssertTrue(claim.finalizationOnly)
    let partial = try XCTUnwrap(store.partialArtifacts().first)
    let partialBytes = try Data(contentsOf: partial.url)
    let partialRecord = try ArtifactRecord(
      id: "artifact-partial", role: .partial, origin: "interrupted receive",
      relativePath: "artifacts/partial/\(partial.url.lastPathComponent)",
      size: UInt64(partialBytes.count),
      sha256: sha256(partialBytes))
    let failureCode = "storage.errno.\(failureErrno)"
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        status: "failed", artifacts: [partialRecord], failureCode: failureCode))
    let terminalTransitions: [(String, Int, JobState, JobState)] = [
      ("event-preflight", 1, .queued, .preflight),
      ("event-running", 2, .preflight, .running),
      ("event-finalizing", 3, .running, .finalizing),
      ("event-failed", 4, .finalizing, .failed),
    ]
    for (eventID, sequence, from, to) in terminalTransitions {
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence, sessionID: fixture.layout.sessionID,
          jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
          from: from, to: to, reason: "artifact receive failure finalization"))
    }
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "event-finalized", sequence: 5, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        kind: .finalized,
        payload: [
          "terminalStatus": .string("failed"),
          "manifestSha256": .string(document.sha256),
          "outcomeCertainty": .string("confirmed"),
        ]))
    let audit = try FileDurableSessionAuditStore(layout: fixture.layout)
    let terminalRecord = try SessionAuditRecord(
      recordID: "artifact-receive-failed", auditID: "artifact-receive-audit",
      correlationID: "artifact-receive-correlation", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp,
      details: ["errno": .integer(Int64(failureErrno)), "stage": .string("artifactReceive")])
    _ = try SessionStorageTerminalFinalizer(
      audit: audit, manifestPublisher: AtomicSessionManifestPublisher(layout: fixture.layout)
    ).persist(
      claim: claim, disposition: .failed, auditRecord: terminalRecord, manifest: document)

    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.journalURL.path))
    XCTAssertEqual(try SessionArtifactStore(layout: fixture.layout).partialArtifacts().count, 1)
    XCTAssertEqual(
      try AtomicSessionManifestPublisher(layout: fixture.layout).load().status, "failed")
    XCTAssertNotEqual(document.status, "succeeded")
    XCTAssertTrue(
      String(decoding: document.canonicalData, as: UTF8.self).contains(failureCode))
  }

  func testTEST_AC_ART_002_01_rawImmutableAndDerivedLineageIsRebuildable() async throws {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let rawSource = fixture.base.appending(path: "raw.trace")
    let rawBytes = Data("keep-1\nchatter\nkeep-2\n".utf8)
    try rawBytes.write(to: rawSource)
    let store = SessionArtifactStore(layout: fixture.layout)
    let claim = fixture.claim
    let raw = try store.publish(
      from: rawSource,
      request: ArtifactPublicationRequest(
        artifactID: "raw-trace", role: .raw, publicationName: "trace.raw",
        origin: "simulated trace fixture", mediaType: "application/octet-stream"),
      claim: claim)

    let derivedSource = fixture.base.appending(path: "filtered.trace")
    try Data("keep-1\nkeep-2\n".utf8).write(to: derivedSource)
    let provenance = try DerivedArtifactProvenance(
      operation: "drop-line", inputHashes: [raw.record.sha256],
      parameters: ["contains": "chatter"], statistics: ["removedLines": 1])
    let derived = try store.publish(
      from: derivedSource,
      request: ArtifactPublicationRequest(
        derivedArtifactID: "derived-trace", publicationName: "trace.filtered",
        provenance: provenance, sourceArtifacts: [raw.record],
        mediaType: "application/octet-stream"),
      claim: claim)

    XCTAssertEqual(try Data(contentsOf: raw.url), rawBytes)
    XCTAssertEqual(sha256(try Data(contentsOf: raw.url)), raw.record.sha256)
    XCTAssertEqual(derived.record.derivedFrom, [raw.record.id])
    XCTAssertEqual(
      try DerivedArtifactProvenance(manifestOrigin: derived.record.origin), provenance)
    XCTAssertThrowsError(
      try ArtifactPublicationRequest(
        artifactID: "untyped-derived", role: .derived, publicationName: "untyped.bin",
        origin: "caller-controlled", derivedFrom: [raw.record.id]))
    XCTAssertThrowsError(
      try DerivedArtifactProvenance(
        operation: "missing-rebuild-data", inputHashes: [raw.record.sha256],
        parameters: [:], statistics: [:]))
    let forgedSource = try ArtifactRecord(
      id: raw.record.id, role: raw.record.role, origin: raw.record.origin,
      relativePath: raw.record.relativePath, size: raw.record.size,
      sha256: String(repeating: "f", count: 64), mediaType: raw.record.mediaType)
    XCTAssertThrowsError(
      try ArtifactPublicationRequest(
        derivedArtifactID: "mismatched-derived", publicationName: "mismatched.bin",
        provenance: provenance, sourceArtifacts: [forgedSource]))
    XCTAssertThrowsError(try Data("mutation".utf8).write(to: raw.url))

    XCTAssertEqual(Darwin.chmod(raw.url.path, S_IRUSR | S_IWUSR), 0)
    try Data("tampered-source".utf8).write(to: raw.url)
    let secondDerivedSource = fixture.base.appending(path: "second-filtered.trace")
    try Data("second-output".utf8).write(to: secondDerivedSource)
    XCTAssertThrowsError(
      try store.publish(
        from: secondDerivedSource,
        request: ArtifactPublicationRequest(
          derivedArtifactID: "derived-after-source-tamper",
          publicationName: "trace.after-tamper", provenance: provenance,
          sourceArtifacts: [raw.record]),
        claim: claim))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.derivedDirectory.appending(path: "trace.after-tamper").path))
  }

  func testTEST_AC_ART_003_01_crashBeforeAtomicPublicationLeavesOnlyRecognizablePart() async throws
  {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "incoming.bin")
    try Data("complete-but-not-published".utf8).write(to: source)
    let store = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactReplace { throw StorageContractFault.injected(point.rawValue) }
      })
    let claim = fixture.claim
    XCTAssertThrowsError(
      try store.publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: "artifact-crash", role: .raw, publicationName: "capture.bin",
          origin: "fault fixture"),
        claim: claim))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: "capture.bin").path))
    let partials = try store.partialArtifacts()
    XCTAssertEqual(partials.count, 1)
    XCTAssertGreaterThan(partials[0].size, 0)
  }

  func testTEST_AC_ART_004_01_simulatedManifestCannotBeReadAsHardwareSuccess() async throws {
    let fixture = try await makeSession(
      sessionID: "session-simulated-export", jobID: "job-simulated-export")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        sessionDisposition: "archived"))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(document)
    let exportRoot = fixture.base.appending(path: "simulated-export")
    let (_, exportClaim) = try await admittedClaim(
      claimID: "claim-simulated-export", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)
    _ = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: [], claim: exportClaim, to: exportRoot)
    let exportedLayout = try SessionLayout(
      sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID, root: exportRoot)
    let exported = try AtomicSessionManifestPublisher(layout: exportedLayout).load()
    XCTAssertEqual(exported.executionMode, "simulated")
    let string = String(decoding: exported.canonicalData, as: UTF8.self)
    XCTAssertTrue(string.contains("\"sessionDisposition\":\"archived\""))
    XCTAssertTrue(string.contains("\"archivedAt\":\""))
    XCTAssertTrue(string.contains("session-storage-fixture-1"))
    XCTAssertTrue(string.contains("session-storage-scenario-1"))
    XCTAssertTrue(string.contains("\"kind\":\"synthetic\""))
    XCTAssertFalse(string.contains("\"executionMode\":\"execute\""))
    guard
      case .object(var reinterpreted) = try JSONDecoder().decode(
        JSONValue.self, from: exported.canonicalData)
    else { return XCTFail("exported manifest root") }
    reinterpreted["executionMode"] = .string("execute")
    XCTAssertThrowsError(
      try SessionManifestDocument(data: canonicalData(.object(reinterpreted))))
  }

  func testTEST_AC_ART_005_01_gibInputIsHashedAndReferencedWithoutSessionCopy() async throws {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let image = fixture.base.appending(path: "system.img")
    XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: nil))
    let handle = try FileHandle(forWritingTo: image)
    try handle.truncate(atOffset: 1_073_741_824)
    try handle.close()
    var metadata = stat()
    XCTAssertEqual(lstat(image.path, &metadata), 0)
    let allocatedBytes = UInt64(metadata.st_blocks) * 512

    let reference = try InputImageReferencer().reference(image)
    print("TASK-M1-005 sparse logical=\(reference.size) allocated=\(allocatedBytes)")
    XCTAssertEqual(reference.size, 1_073_741_824)
    XCTAssertLessThan(allocatedBytes, reference.size)
    let sessionFiles = try FileManager.default.subpathsOfDirectory(atPath: fixture.layout.root.path)
    XCTAssertFalse(sessionFiles.contains(where: { $0.contains("system.img") }))
    XCTAssertEqual(reference.path, image.path)
    XCTAssertEqual(reference.sha256.count, 64)
    XCTAssertEqual(reference.fileSystemInode, UInt64(metadata.st_ino))
    XCTAssertEqual(reference.fileSystemDevice, UInt64(UInt32(bitPattern: metadata.st_dev)))
  }

  func testTEST_AC_ART_006_01_defaultDiagnosticExportExcludesDeviceRaw() async throws {
    let fixture = try await makeSession(
      sessionID: "session-fixture-serial", jobID: "job-fixture-serial")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let rawBytes = Data("device-raw".utf8)
    let partialBytes = Data("device-partial".utf8)
    let keyOnlyIdentifier = "key-only-fixture-token"
    var diagnosticBytes = Data([0xFF, 0x00])
    diagnosticBytes.append(
      Data(
        "device=fixture-device serial=fixture-serial \(keyOnlyIdentifier) usb real ID".utf8))
    let planBytes = Data(
      "target fixture-device via fixture-serial and \(keyOnlyIdentifier); slot values 111111 stay bounded"
        .utf8)
    let raw = try ArtifactRecord(
      id: "raw-device", role: .raw, origin: "export fixture",
      relativePath: "artifacts/raw/fixture-serial.trace", size: UInt64(rawBytes.count),
      sha256: sha256(rawBytes))
    let partial = try ArtifactRecord(
      id: "partial-device", role: .partial, origin: "export fixture",
      relativePath: "artifacts/partial/fixture-device.part", size: UInt64(partialBytes.count),
      sha256: sha256(partialBytes))
    let diagnostic = try ArtifactRecord(
      id: "app-diagnostic", role: .diagnostic, origin: "export fixture",
      relativePath: "artifacts/raw/app.log", size: UInt64(diagnosticBytes.count),
      sha256: sha256(diagnosticBytes))
    let planArtifact = try ArtifactRecord(
      id: "plan-fixture-serial", role: .plan, origin: "export fixture",
      relativePath: "artifacts/plan/fixture-serial.plan", size: UInt64(planBytes.count),
      sha256: sha256(planBytes))
    let durableArtifacts = [raw, partial, diagnostic, planArtifact]
    let exportPlan = SessionExportPlanner().plan(
      artifacts: durableArtifacts, includeDeviceData: false)
    XCTAssertEqual(exportPlan.excludedDeviceDataRelativePaths.count, 2)
    XCTAssertTrue(
      exportPlan.excludedDeviceDataRelativePaths.allSatisfy {
        $0.hasPrefix("excluded-device-data/")
          && !$0.contains("fixture-device") && !$0.contains("fixture-serial")
      })
    XCTAssertTrue(exportPlan.includedRelativePaths.contains("manifest.json"))
    XCTAssertTrue(exportPlan.includedRelativePaths.contains(diagnostic.relativePath))
    XCTAssertTrue(exportPlan.includedRelativePaths.contains(planArtifact.relativePath))
    XCTAssertFalse(exportPlan.includedRelativePaths.contains(raw.relativePath))
    XCTAssertTrue(exportPlan.sensitiveDataWarning.contains("Trace"))
    XCTAssertEqual(exportPlan.deviceIdentifierPolicy, .redact)

    for (record, bytes) in [
      (raw, rawBytes), (partial, partialBytes), (diagnostic, diagnosticBytes),
      (planArtifact, planBytes),
    ] {
      let url = fixture.layout.root.appending(path: record.relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url)
    }
    let schemaDigest = String(repeating: "f", count: 64)
    let restoreDescriptor = try compensationDescriptor(
      id: "restore-fixture-serial", kind: "restoreParameter", effect: "deviceMutation",
      cancellation: "atSafeBoundary", bindingRequirement: "confirmedDevice",
      trigger: "onFailure",
      arguments: [
        "name": .string("fixture-serial"),
        "snapshotStepId": .string("snapshot-fixture-serial"),
        "restorePolicy": .string("restoreKnownValue"),
      ])
    let recoveryDescriptor = try compensationDescriptor(
      id: "recovery-fixture-serial", kind: "restoreParameter", effect: "deviceMutation",
      cancellation: "atSafeBoundary", bindingRequirement: "confirmedDevice",
      trigger: "onFailure",
      arguments: [
        "name": .string("fixture-serial"),
        "snapshotStepId": .string("snapshot-fixture-serial"),
        "restorePolicy": .string("restoreKnownValue"),
      ])
    let snapshotStep = try executionStep(
      id: "snapshot-fixture-serial", kind: "snapshotParameter", effect: "readOnly",
      cancellation: "immediate", bindingRequirement: "confirmedDevice",
      arguments: ["name": .string("fixture-serial")],
      compensationDescriptors: [restoreDescriptor, recoveryDescriptor], disposition: "executed",
      outcomeCertainty: "confirmed", semanticResult: "succeeded")
    let probeStep = try executionStep(
      id: "probe-fixture-serial", kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none",
      arguments: [
        "toolIdentity": .string("tool-fixture-serial"),
        "candidatePath": .string("/fixture/fixture-serial/hdc"),
        "expectedSha256": .string(schemaDigest),
      ], disposition: "executed", outcomeCertainty: "confirmed",
      semanticResult: "succeeded")
    let finalizeStep = try executionStep(
      id: "finalize-fixture-serial", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string(fixture.layout.sessionID),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], disposition: "executed", outcomeCertainty: "confirmed",
      semanticResult: "failed")
    let compensation: JSONValue = .object([
      "descriptor": restoreDescriptor,
      "sourceStepId": .string("snapshot-fixture-serial"),
      "disposition": .string("executed"),
      "outcomeCertainty": .string("confirmed"),
      "result": .string("failed"),
      "failure": .object([
        "stage": .string("restore fixture-serial"),
        "code": .string("fixture-serial"),
        "summary": .string("restore failed for fixture-device"),
      ]),
      "journalEventIds": .array([
        .string("journal-fixture-serial-intent"),
        .string("journal-fixture-serial-outcome"),
      ]),
    ])
    let recovery: JSONValue = .object([
      "needsAttention": .bool(true),
      "interruptedReason": .string("fixture-device recovery required"),
      "deviceHazards": .array([
        .object([
          "code": .string("fixture-serial"),
          "summary": .string("fixture-device state uncertain"),
          "severity": .string("blocking"),
          "outcomeCertainty": .string("confirmed"),
        ])
      ]),
      "abandonAuditEventIds": .array([]),
      "lastConfirmedStepId": .string("snapshot-fixture-serial"),
      "lastDeviceMode": .object([
        "state": .string("known"), "value": .string("fixture-serial"),
        "evidence": .string("fixture-device evidence"),
      ]),
      "managedHostProcessState": .string("notRunning"),
      "recoveryGuide": .object([
        "providerIdentity": .string("provider-fixture-serial"),
        "automaticRecoveryAvailable": .bool(false),
        "summary": .string("recover fixture-device"),
        "steps": .array([.string("inspect fixture-serial")]),
      ]),
      "unexecutedCompensations": .array([recoveryDescriptor]),
      "userConfirmation": .null,
      "recoveryOfSessionId": .string(fixture.layout.sessionID),
      "recoveryOfJobId": .string(fixture.layout.jobID),
    ])
    let denseIdentifierValue = String(repeating: "fixture-device", count: 290)
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed",
        executionMode: "execute", executionAuthority: "interactiveUser",
        steps: [snapshotStep, probeStep, finalizeStep],
        parameters: [
          .object([
            "name": .string("fixture-serial"),
            "beforeState": .object([
              "state": .string("value"), "value": .string(denseIdentifierValue),
            ]),
            "desiredState": .object([
              "state": .string("value"), "value": .string("fixture-serial"),
            ]),
            "afterState": .object([
              "state": .string("value"), "value": .string("fixture-device"),
            ]),
            "restoreState": .object([
              "state": .string("value"), "value": .string("fixture-serial"),
            ]),
            "restoreDisposition": .string("notRequired"),
          ])
        ],
        compensations: [compensation],
        artifacts: durableArtifacts,
        failureCode: "fixture-serial",
        failureSummary: "failure references fixture-device and fixture-serial",
        warnings: ["warning references fixture-device and fixture-serial"],
        realIdentitySnapshot: .object([
          "serial": .string("fixture-serial"), "transportToken": .string("usb"),
          "kindToken": .string("real"), "shortToken": .string("ID"), "slot": .integer(1),
          "digestToken": .string(schemaDigest),
          "fixture-serial": .string("identity-key-value"),
          keyOnlyIdentifier: .string("safe-key-only-value"),
        ]),
        recovery: recovery))
    guard case .object(let restoreDescriptorObject) = restoreDescriptor,
      case .string(let restoreArgumentsHash)? = restoreDescriptorObject["argumentsHash"]
    else { return XCTFail("restore descriptor fixture") }
    func workflowStep(from executionRecord: JSONValue) throws -> WorkflowStep {
      guard case .object(let record) = executionRecord else {
        throw StorageContractFault.operation
      }
      let declarationKeys = [
        "id", "kind", "effect", "cancellation", "bindingRequirement", "arguments",
        "compensationDescriptors",
      ]
      let declaration = try Dictionary(
        uniqueKeysWithValues: declarationKeys.map { key -> (String, JSONValue) in
          guard let value = record[key] else { throw StorageContractFault.operation }
          return (key, value)
        })
      return try WorkflowStepDecoder.decodeCoreOrProviderStep(
        canonicalData(.object(declaration)))
    }
    let snapshotWorkflowStep = try workflowStep(from: snapshotStep)
    let probeWorkflowStep = try workflowStep(from: probeStep)
    let finalizeWorkflowStep = try workflowStep(from: finalizeStep)
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "journal-created", sequence: 0, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        executionMode: "execute", executionAuthority: "interactiveUser"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "journal-preflight", sequence: 1, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        from: .queued, to: .preflight, reason: "export fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "journal-running", sequence: 2, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        from: .preflight, to: .running, reason: "export fixture"))
    let deviceTarget = JournalTarget(
      scope: "device", targetID: "fixture-device", connectKey: "fixture-device",
      identitySnapshotHash: String(repeating: "a", count: 64))
    let hostTarget = JournalTarget(
      scope: "host", targetID: "fixture-host", connectKey: nil,
      identitySnapshotHash: nil)
    var journalSequence = 3
    for (step, stepTarget, bindingRevision, result) in [
      (snapshotWorkflowStep, deviceTarget, Int?.some(1), "succeeded"),
      (probeWorkflowStep, hostTarget, Int?.none, "succeeded"),
      (finalizeWorkflowStep, hostTarget, Int?.none, "failed"),
    ] {
      let intentID = "journal-\(step.id)-intent"
      try journal.appendAndSynchronize(
        JournalEvent.stepIntent(
          eventID: intentID, sequence: journalSequence,
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, step: step, target: stepTarget,
          attempt: 1, bindingRevision: bindingRevision))
      journalSequence += 1
      try journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "journal-\(step.id)-outcome", sequence: journalSequence,
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, stepID: step.id, attempt: 1,
          correlatesToIntentEventID: intentID, result: result,
          outcomeCertainty: .confirmed))
      journalSequence += 1
    }
    let target: JSONValue = .object([
      "scope": .string("device"), "targetId": .string("fixture-device"),
      "connectKey": .string("fixture-device"),
      "identitySnapshotHash": .string(String(repeating: "a", count: 64)),
    ])
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "journal-fixture-serial-intent", sequence: journalSequence,
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .compensationIntent,
        stepID: "restore-fixture-serial", attempt: 1, bindingRevision: 1,
        argumentsHash: restoreArgumentsHash,
        payload: [
          "compensationOfStepId": .string("snapshot-fixture-serial"),
          "descriptor": restoreDescriptor, "target": target,
        ]))
    journalSequence += 1
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "journal-fixture-serial-outcome", sequence: journalSequence,
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .compensationOutcome,
        stepID: "restore-fixture-serial", attempt: 1,
        payload: [
          "compensationOfStepId": .string("snapshot-fixture-serial"),
          "descriptorId": .string("restore-fixture-serial"),
          "correlatesToIntentEventId": .string("journal-fixture-serial-intent"),
          "result": .string("failed"), "outcomeCertainty": .string("confirmed"),
        ]))
    journalSequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "journal-finalizing", sequence: journalSequence,
        sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        from: .running, to: .finalizing, reason: "export fixture finalization"))
    journalSequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "journal-failed", sequence: journalSequence,
        sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        from: .finalizing, to: .failed, reason: "export fixture failed"))
    journalSequence += 1
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "journal-finalized", sequence: journalSequence,
        sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        kind: .finalized,
        payload: [
          "terminalStatus": .string("failed"),
          "manifestSha256": .string(manifest.sha256),
          "outcomeCertainty": .string("confirmed"),
        ]))
    guard
      case .object(var forgedCompensationRoot) = try JSONDecoder().decode(
        JSONValue.self, from: manifest.canonicalData),
      case .array(var forgedCompensations)? = forgedCompensationRoot["compensations"],
      case .object(var forgedCompensation) = forgedCompensations[0]
    else { return XCTFail("compensation outcome fixture must be an object") }
    forgedCompensation["result"] = .string("succeeded")
    forgedCompensation["failure"] = .null
    forgedCompensations[0] = .object(forgedCompensation)
    forgedCompensationRoot["compensations"] = .array(forgedCompensations)
    let forgedCompensationManifest = try SessionManifestDocument(
      data: canonicalData(.object(forgedCompensationRoot)))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: fixture.layout).publish(
        forgedCompensationManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("journal failed/compensation succeeded returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("outcome does not match Manifest execution tuple"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(manifest)
    let (_, exportClaim) = try await admittedClaim(
      claimID: "claim-platform-export", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)

    let forgedRaw = try ArtifactRecord(
      id: raw.id, role: .diagnostic, origin: raw.origin,
      relativePath: raw.relativePath, size: raw.size, sha256: raw.sha256)
    let forgedDestination = fixture.base.appending(path: "forged-role-export")
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [forgedRaw, partial, diagnostic],
        claim: exportClaim, to: forgedDestination))
    XCTAssertFalse(FileManager.default.fileExists(atPath: forgedDestination.path))

    let destination = fixture.base.appending(path: "diagnostic-export")
    let materialized = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: durableArtifacts, claim: exportClaim, to: destination)
    let exportedPaths = try FileManager.default.subpathsOfDirectory(atPath: materialized.root.path)
    XCTAssertTrue(exportedPaths.contains("manifest.json"))
    XCTAssertTrue(exportedPaths.contains(diagnostic.relativePath))
    XCTAssertFalse(exportedPaths.contains(planArtifact.relativePath))
    XCTAssertFalse(exportedPaths.contains { $0.contains("fixture-serial") })
    XCTAssertFalse(exportedPaths.contains(raw.relativePath))
    XCTAssertFalse(exportedPaths.contains(partial.relativePath))
    let exportedManifest = try Data(contentsOf: destination.appending(path: "manifest.json"))
    let exportedDiagnostic = try Data(
      contentsOf: destination.appending(path: diagnostic.relativePath))
    let exportedDocument = try SessionManifestDocument(data: exportedManifest)
    let exportedDiagnosticRecord = try XCTUnwrap(
      exportedDocument.artifacts.first { $0.id == diagnostic.id })
    let exportedPlanRecord = try XCTUnwrap(exportedDocument.artifacts.first { $0.role == .plan })
    let exportedPlanBytes = try Data(
      contentsOf: destination.appending(path: exportedPlanRecord.relativePath))
    XCTAssertEqual(exportedDocument.artifacts.count, 2)
    XCTAssertEqual(exportedDiagnosticRecord.id, diagnostic.id)
    XCTAssertEqual(exportedDiagnosticRecord.size, UInt64(exportedDiagnostic.count))
    XCTAssertEqual(exportedDiagnosticRecord.sha256, sha256(exportedDiagnostic))
    XCTAssertTrue(exportedDiagnosticRecord.origin.hasPrefix("export:v1:redacted:"))
    XCTAssertEqual(exportedPlanRecord.size, UInt64(exportedPlanBytes.count))
    XCTAssertEqual(exportedPlanRecord.sha256, sha256(exportedPlanBytes))
    XCTAssertTrue(exportedPlanRecord.origin.hasPrefix("export:v1:redacted:"))
    XCTAssertTrue(exportedPlanRecord.id.hasPrefix("redacted-device-"))
    XCTAssertTrue(exportedPlanRecord.relativePath.contains("redacted-device-"))
    XCTAssertEqual(exportedDiagnostic.first, 0xFF)
    XCTAssertFalse(String(decoding: exportedManifest, as: UTF8.self).contains("fixture-device"))
    XCTAssertFalse(String(decoding: exportedManifest, as: UTF8.self).contains("fixture-serial"))
    XCTAssertFalse(String(decoding: exportedDiagnostic, as: UTF8.self).contains("fixture-device"))
    XCTAssertFalse(String(decoding: exportedDiagnostic, as: UTF8.self).contains("fixture-serial"))
    XCTAssertFalse(
      String(decoding: exportedDiagnostic, as: UTF8.self).contains(keyOnlyIdentifier))
    XCTAssertFalse(String(decoding: exportedPlanBytes, as: UTF8.self).contains("fixture-device"))
    XCTAssertFalse(String(decoding: exportedPlanBytes, as: UTF8.self).contains("fixture-serial"))
    XCTAssertFalse(String(decoding: exportedPlanBytes, as: UTF8.self).contains(keyOnlyIdentifier))
    XCTAssertTrue(String(decoding: exportedPlanBytes, as: UTF8.self).contains("111111"))
    XCTAssertLessThan(exportedPlanBytes.count, planBytes.count * 4)
    XCTAssertTrue(
      String(decoding: exportedDiagnostic, as: UTF8.self).contains("[REDACTED-DEVICE-ID]"))
    let exportedObject = try jsonObject(exportedManifest)
    let exportedSessionID = try XCTUnwrap(exportedObject["sessionId"] as? String)
    let exportedJobID = try XCTUnwrap(exportedObject["jobId"] as? String)
    XCTAssertTrue(exportedSessionID.hasPrefix("redacted-device-"))
    XCTAssertTrue(exportedJobID.hasPrefix("redacted-device-"))
    let originalTarget = try XCTUnwrap(exportedObject["originalTarget"] as? [String: Any])
    XCTAssertEqual(originalTarget["kind"] as? String, "real")
    XCTAssertEqual(originalTarget["transport"] as? String, "usb")
    let exportedParameters = try XCTUnwrap(exportedObject["parameters"] as? [[String: Any]])
    XCTAssertTrue(
      try XCTUnwrap(exportedParameters.first?["name"] as? String).hasPrefix(
        "redacted-device-"))
    let exportedBeforeState = try XCTUnwrap(
      exportedParameters.first?["beforeState"] as? [String: Any])
    let exportedDenseValue = try XCTUnwrap(exportedBeforeState["value"] as? String)
    XCTAssertLessThanOrEqual(exportedDenseValue.count, 4_096)
    XCTAssertFalse(exportedDenseValue.contains("fixture-device"))
    let exportedFailure = try XCTUnwrap(exportedObject["failure"] as? [String: Any])
    XCTAssertTrue(
      try XCTUnwrap(exportedFailure["code"] as? String).hasPrefix("redacted-device-"))
    let exportedSteps = try XCTUnwrap(exportedObject["steps"] as? [[String: Any]])
    XCTAssertEqual(exportedSteps.count, 3)
    let exportedSnapshot = try XCTUnwrap(
      exportedSteps.first { $0["kind"] as? String == "snapshotParameter" })
    let exportedSnapshotArguments = try XCTUnwrap(
      exportedSnapshot["arguments"] as? [String: Any])
    XCTAssertTrue(
      try XCTUnwrap(exportedSnapshotArguments["name"] as? String).hasPrefix(
        "redacted-device-"))
    let exportedProbe = try XCTUnwrap(
      exportedSteps.first { $0["kind"] as? String == "probeHostTool" })
    let exportedProbeArguments = try XCTUnwrap(exportedProbe["arguments"] as? [String: Any])
    XCTAssertEqual(exportedProbeArguments["expectedSha256"] as? String, schemaDigest)
    let exportedFinalize = try XCTUnwrap(
      exportedSteps.first { $0["kind"] as? String == "finalizeSession" })
    let exportedFinalizeArguments = try XCTUnwrap(
      exportedFinalize["arguments"] as? [String: Any])
    XCTAssertEqual(exportedFinalizeArguments["sessionId"] as? String, exportedSessionID)
    let exportedCompensations = try XCTUnwrap(
      exportedObject["compensations"] as? [[String: Any]])
    let exportedCompensationFailure = try XCTUnwrap(
      exportedCompensations.first?["failure"] as? [String: Any])
    XCTAssertTrue(
      try XCTUnwrap(exportedCompensationFailure["code"] as? String).hasPrefix(
        "redacted-device-"))
    let exportedRecovery = try XCTUnwrap(exportedObject["recovery"] as? [String: Any])
    let exportedRecoveryDescriptors = try XCTUnwrap(
      exportedRecovery["unexecutedCompensations"] as? [[String: Any]])
    let exportedRecoveryArguments = try XCTUnwrap(
      exportedRecoveryDescriptors.first?["arguments"] as? [String: Any])
    XCTAssertTrue(
      try XCTUnwrap(exportedRecoveryArguments["name"] as? String).hasPrefix(
        "redacted-device-"))
    XCTAssertEqual(materialized.plan.excludedDeviceDataRelativePaths.count, 2)
    XCTAssertFalse(
      materialized.plan.excludedDeviceDataRelativePaths.joined().contains("fixture-serial"))
    XCTAssertFalse(
      materialized.plan.excludedDeviceDataRelativePaths.joined().contains("fixture-device"))

    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: durableArtifacts, claim: exportClaim,
        to: destination))

    let unredactedDestination = fixture.base.appending(path: "diagnostic-export-identifiers")
    _ = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: durableArtifacts,
      claim: exportClaim, to: unredactedDestination, includeDeviceData: true,
      deviceIdentifierPolicy: .include)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: unredactedDestination.appending(path: raw.relativePath).path))
    XCTAssertTrue(
      String(
        decoding: try Data(contentsOf: unredactedDestination.appending(path: "manifest.json")),
        as: UTF8.self
      ).contains("fixture-device"))

    let retryFixture = try await makeSession(
      sessionID: "session-export-retry", jobID: "job-export-retry")
    defer { try? FileManager.default.removeItem(at: retryFixture.base) }
    let external = retryFixture.base.appending(path: "external-diagnostic.log")
    let retryBytes = Data("fixture-device".utf8)
    try retryBytes.write(to: external)
    let symlinkDiagnostic = try ArtifactRecord(
      id: "symlink-diagnostic", role: .diagnostic, origin: "retry fixture",
      relativePath: "artifacts/derived/symlink-diagnostic.log",
      size: UInt64(retryBytes.count), sha256: sha256(retryBytes))
    let retryManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: retryFixture.layout.sessionID, jobID: retryFixture.layout.jobID,
        executionMode: "execute", executionAuthority: "interactiveUser",
        artifacts: [symlinkDiagnostic]))
    let symlinkURL = retryFixture.layout.root.appending(path: symlinkDiagnostic.relativePath)
    try retryBytes.write(to: symlinkURL)
    _ = try AtomicSessionManifestPublisher(layout: retryFixture.layout).publish(retryManifest)
    let (_, retryClaim) = try await admittedClaim(
      claimID: "claim-export-retry", jobID: retryFixture.layout.jobID,
      layout: retryFixture.layout, writer: .heavy)
    try FileManager.default.removeItem(at: symlinkURL)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: external)
    let retryDestination = retryFixture.base.appending(path: "symlink-export")
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: retryFixture.layout, artifacts: [symlinkDiagnostic],
        claim: retryClaim, to: retryDestination)
    ) { error in
      guard case SessionStorageError.invalidRecord = error else {
        return XCTFail("export symlink failure escaped Storage error domain: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: retryDestination.path))
    try FileManager.default.removeItem(at: symlinkURL)
    try retryBytes.write(to: symlinkURL)
    XCTAssertNoThrow(
      try SessionDiagnosticExporter().export(
        layout: retryFixture.layout, artifacts: [symlinkDiagnostic],
        claim: retryClaim, to: retryDestination))
  }

  func testDiagnosticExportRequiresHeavyVolumeBoundGrowthClaimAndCleansFailedAttempt()
    async throws
  {
    let fixture = try await makeSession(
      sessionID: "session-export-admission", jobID: "job-export-admission")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(document)
    let destination = fixture.base.appending(path: "claim-bound-export")

    let (_, lightClaim) = try await admittedClaim(
      claimID: "claim-export-light", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .light)
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [], claim: lightClaim, to: destination)
    ) { error in
      guard case SessionStorageError.invalidRecord = error else {
        return XCTFail("light export claim was not rejected: \(error)")
      }
    }

    let wrongVolume = try VolumeIdentity(value: "uuid:not-the-export-volume")
    let (_, wrongVolumeClaim) = try await admittedClaim(
      claimID: "claim-export-wrong-volume", jobID: fixture.layout.jobID,
      writer: .heavy, volumeIdentity: wrongVolume)
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [], claim: wrongVolumeClaim, to: destination)
    ) { error in
      guard case SessionStorageError.volumeIdentityChanged = error else {
        return XCTFail("export destination volume mismatch was not rejected: \(error)")
      }
    }

    let (_, boundedClaim) = try await admittedClaim(
      claimID: "claim-export-one-byte", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy, growth: 1)
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [], claim: boundedClaim, to: destination)
    ) { error in
      guard case SessionStorageError.insufficientSpace = error else {
        return XCTFail("export growth budget was not enforced: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(boundedClaim.remainingGrowthBytes, 1)

    let (stoppedCoordinator, stoppedClaim) = try await admittedClaim(
      claimID: "claim-export-stopped", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)
    _ = await stoppedCoordinator.reportWriteFailure(claimID: stoppedClaim.claimID, errno: ENOSPC)
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [], claim: stoppedClaim, to: destination)
    ) { error in
      XCTAssertEqual(
        error as? SessionStorageError, .optionalWritesStopped(stoppedClaim.claimID))
    }

    let (_, retryClaim) = try await admittedClaim(
      claimID: "claim-export-after-failure", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)
    let actualVolume = try SystemVolumeIdentityResolver().resolve(fixture.layout.root)
    let outputDescriptorMismatch = fixture.base.appending(path: "descriptor-mismatch-export")
    XCTAssertThrowsError(
      try SessionDiagnosticExporter(
        volumeIdentityResolver: SequencedVolumeIdentityResolver(
          pathIdentities: [actualVolume], descriptorIdentity: wrongVolume)
      ).export(
        layout: fixture.layout, artifacts: [], claim: retryClaim,
        to: outputDescriptorMismatch)
    ) { error in
      XCTAssertEqual(
        error as? SessionStorageError,
        .volumeIdentityChanged(expected: actualVolume, actual: wrongVolume))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputDescriptorMismatch.path))
    let invalidNameDestination = fixture.base.appending(path: String(repeating: "x", count: 300))
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: [], claim: retryClaim,
        to: invalidNameDestination)
    ) { error in
      XCTAssertEqual(
        error as? SessionStorageError,
        .writeFailed(path: invalidNameDestination.path, errno: ENAMETOOLONG))
    }
    _ = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: [], claim: retryClaim, to: destination)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testDefaultDiagnosticExportClosesExcludedRawDerivedLineage() async throws {
    let fixture = try await makeSession(
      sessionID: "session-export-derived", jobID: "job-export-derived")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = SessionArtifactStore(layout: fixture.layout)
    let rawSource = fixture.base.appending(path: "export-source.raw")
    let derivedSource = fixture.base.appending(path: "export-filtered.trace")
    let rawBytes = Data("raw-device-trace".utf8)
    let derivedBytes = Data("filtered-diagnostic-trace".utf8)
    try rawBytes.write(to: rawSource)
    try derivedBytes.write(to: derivedSource)
    let raw = try store.publish(
      from: rawSource,
      request: ArtifactPublicationRequest(
        artifactID: "export-raw", role: .raw, publicationName: "export.raw",
        origin: "diagnostic export fixture"),
      claim: fixture.claim)
    let provenance = try DerivedArtifactProvenance(
      operation: "filter-diagnostic-trace", inputHashes: [raw.record.sha256],
      parameters: ["predicate": "diagnostic-only"], statistics: ["removedRecords": 1])
    let derived = try store.publish(
      from: derivedSource,
      request: ArtifactPublicationRequest(
        derivedArtifactID: "export-derived", publicationName: "export.filtered",
        provenance: provenance, sourceArtifacts: [raw.record]),
      claim: fixture.claim)
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        artifacts: [raw.record, derived.record]))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(document)
    let (_, exportClaim) = try await admittedClaim(
      claimID: "claim-export-derived", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)

    let destination = fixture.base.appending(path: "default-derived-export")
    _ = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: document.artifacts,
      claim: exportClaim, to: destination)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destination.appending(path: raw.record.relativePath).path))
    XCTAssertEqual(
      try Data(contentsOf: destination.appending(path: derived.record.relativePath)),
      derivedBytes)
    let exported = try SessionManifestDocument(
      data: Data(contentsOf: destination.appending(path: "manifest.json")))
    let detachedDerived = try XCTUnwrap(
      exported.artifacts.first { $0.id == derived.record.id })
    XCTAssertEqual(detachedDerived.role, .diagnostic)
    XCTAssertNil(detachedDerived.derivedFrom)
    XCTAssertTrue(detachedDerived.origin.hasPrefix("export:v1:redacted:source-role:derived:"))
    XCTAssertEqual(detachedDerived.sha256, derived.record.sha256)

    let completeDestination = fixture.base.appending(path: "complete-derived-export")
    _ = try SessionDiagnosticExporter().export(
      layout: fixture.layout, artifacts: document.artifacts,
      claim: exportClaim, to: completeDestination, includeDeviceData: true,
      deviceIdentifierPolicy: .include)
    let complete = try SessionManifestDocument(
      data: Data(contentsOf: completeDestination.appending(path: "manifest.json")))
    XCTAssertEqual(complete.artifacts, [raw.record, derived.record])
    XCTAssertEqual(
      try DerivedArtifactProvenance(
        manifestOrigin: try XCTUnwrap(complete.artifacts.last?.origin)),
      provenance)
  }

  func testJournalWriterRejectsReplacedJournalInode() async throws {
    let fixture = try await makeSession(
      sessionID: "session-journal-bound", jobID: "job-journal-bound")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "journal-bound-created", sequence: 0, sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, timestamp: SessionStorageFixtures.timestamp,
        executionMode: "simulated"))
    // Replace the journal inode with a byte-identical copy: a live writer must fail
    // attributably instead of silently adopting the replacement's history.
    let displaced = fixture.base.appending(path: "journal-displaced.jsonl")
    try FileManager.default.moveItem(at: fixture.layout.journalURL, to: displaced)
    try FileManager.default.copyItem(at: displaced, to: fixture.layout.journalURL)
    XCTAssertThrowsError(
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "journal-bound-transition", sequence: 1,
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: .queued, to: .preflight,
          reason: "replaced inode fixture"))
    ) { error in
      guard case DurableFileError.sequenceViolation(let message) = error else {
        return XCTFail("replaced journal inode returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("bound durable journal"))
    }
    // The rejection happens before any mutation, so the writer is not poisoned and a
    // fresh writer bound to the current inode continues normally.
    let reopened = try FileDurableJournal(url: fixture.layout.journalURL)
    XCTAssertNoThrow(
      try reopened.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "journal-bound-reopened", sequence: 1,
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: .queued, to: .preflight,
          reason: "rebound writer fixture")))
  }

  func testDiagnosticExportRejectsForeignSessionManifest() async throws {
    let fixture = try await makeSession(
      sessionID: "session-export-foreign", jobID: "job-export-foreign")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let foreign = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: "session-export-other", jobID: "job-export-other",
        status: "failed", artifacts: []))
    try foreign.canonicalData.write(to: fixture.layout.manifestURL)
    let (_, exportClaim) = try await admittedClaim(
      claimID: "claim-export-foreign", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)
    let destination = fixture.base.appending(path: "foreign-export")
    XCTAssertThrowsError(
      try SessionDiagnosticExporter().export(
        layout: fixture.layout, artifacts: foreign.artifacts,
        claim: exportClaim, to: destination)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("foreign manifest escaped export identity validation: \(error)")
      }
      XCTAssertTrue(message.contains("identity mismatch"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testDiagnosticExportRejectsPublishedStagingPathSubstitution() async throws {
    let fixture = try await makeSession(
      sessionID: "session-export-staging", jobID: "job-export-staging")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(document)
    let (_, exportClaim) = try await admittedClaim(
      claimID: "claim-export-staging", jobID: fixture.layout.jobID,
      layout: fixture.layout, writer: .heavy)
    let destination = fixture.base.appending(path: "anchored-export")
    let displaced = fixture.base.appending(path: "anchored-export-displaced")
    let external = fixture.base.appending(path: "external-export-target")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let sentinel = external.appending(path: "sentinel")
    try Data("outside".utf8).write(to: sentinel)
    var substituted = false
    let exporter = SessionDiagnosticExporter(
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .exportAfterReplace, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(at: destination, to: displaced)
        try FileManager.default.createSymbolicLink(
          at: destination, withDestinationURL: external)
      })
    XCTAssertThrowsError(
      try exporter.export(
        layout: fixture.layout, artifacts: [], claim: exportClaim, to: destination)
    ) { error in
      guard case SessionStorageError.invalidRecord = error else {
        return XCTFail("export staging substitution returned the wrong error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
  }

  func testTEST_AC_ART_006_02_retentionNeverDeletesPinnedSessionAndBlocksWhenPinsExceedMargin()
    async throws
  {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let sessionsRoot = base.appending(path: "Sessions")
    let ordinaryRoot = sessionsRoot.appending(path: "2026/07/ordinary-session")
    let pinnedRoot = sessionsRoot.appending(path: "2026/07/pinned-session")
    try FileManager.default.createDirectory(at: ordinaryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let ordinary = try RetainedSession(
      sessionID: "ordinary-session", root: ordinaryRoot, sizeBytes: 60,
      completedAt: now.addingTimeInterval(-500), expiresAt: now.addingTimeInterval(-1),
      isPinned: false)
    let pinned = try RetainedSession(
      sessionID: "pinned-session", root: pinnedRoot, sizeBytes: 100,
      completedAt: now.addingTimeInterval(-1_000), expiresAt: now.addingTimeInterval(-500),
      isPinned: true)
    let controller = SessionRetentionController()
    let plan = controller.plan(
      sessions: [pinned, ordinary], totalQuotaBytes: 120, safetyMarginBytes: 20, now: now)
    XCTAssertEqual(plan.deletionSessionIDs, [ordinary.sessionID])
    XCTAssertFalse(plan.deletionSessionIDs.contains(pinned.sessionID))
    XCTAssertThrowsError(
      try controller.apply(plan, sessions: [pinned], sessionsRoot: sessionsRoot))
    let pinnedSubstitution = try RetainedSession(
      sessionID: ordinary.sessionID, root: ordinary.root, sizeBytes: ordinary.sizeBytes,
      completedAt: ordinary.completedAt, expiresAt: ordinary.expiresAt, isPinned: true)
    XCTAssertThrowsError(
      try controller.apply(
        plan, sessions: [pinned, pinnedSubstitution], sessionsRoot: sessionsRoot))
    let escapedRoot = base.appending(path: "outside/ordinary-session")
    try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
    let escaped = try RetainedSession(
      sessionID: ordinary.sessionID, root: escapedRoot, sizeBytes: ordinary.sizeBytes,
      completedAt: ordinary.completedAt, expiresAt: ordinary.expiresAt, isPinned: false)
    XCTAssertThrowsError(
      try controller.apply(plan, sessions: [pinned, escaped], sessionsRoot: sessionsRoot)
    ) {
      error in
      guard case SessionStorageError.retentionTargetEscapesRoot = error else {
        return XCTFail("retention escape was not rejected: \(error)")
      }
    }
    try controller.apply(plan, sessions: [pinned, ordinary], sessionsRoot: sessionsRoot)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ordinaryRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedRoot.path))
    try FileManager.default.createSymbolicLink(at: ordinaryRoot, withDestinationURL: escapedRoot)
    let symlinked = try RetainedSession(
      sessionID: ordinary.sessionID, root: ordinaryRoot, sizeBytes: ordinary.sizeBytes,
      completedAt: ordinary.completedAt, expiresAt: ordinary.expiresAt, isPinned: false)
    XCTAssertThrowsError(
      try controller.apply(plan, sessions: [pinned, symlinked], sessionsRoot: sessionsRoot)
    ) {
      error in
      guard case SessionStorageError.invalidRecord = error else {
        return XCTFail("retention symlink escaped Storage error domain: \(error)")
      }
    }

    let blocked = controller.plan(
      sessions: [
        try RetainedSession(
          sessionID: "pinned-session", root: pinnedRoot, sizeBytes: 120,
          completedAt: now, expiresAt: now, isPinned: true)
      ], totalQuotaBytes: 120, safetyMarginBytes: 20, now: now)
    XCTAssertTrue(blocked.blocksNewHeavyWriters)
    XCTAssertTrue(blocked.deletionSessionIDs.isEmpty)
    let volume = try VolumeIdentity(value: "volume-retention-pinned")
    let coordinator = HostStorageCoordinator()
    await coordinator.updateRetentionAdmission(blocked, on: volume)
    let heavy = try request(
      id: "heavy-after-pinned-retention", job: "job-after-pinned-retention", volume: volume,
      writer: .heavy)
    let admission = await coordinator.admit(
      heavy, snapshot: storageSnapshot(identity: volume, available: UInt64.max))
    XCTAssertEqual(admission, .queued(.insufficientHeadroom))
    XCTAssertThrowsError(
      try controller.apply(
        blocked, sessions: [pinned, pinned], sessionsRoot: sessionsRoot))
  }

  func testRetentionDeletionStaysOnAnchoredDirectoryWhenPathIsReplacedBySymlink() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let sessionsRoot = base.appending(path: "Sessions")
    let month = sessionsRoot.appending(path: "2026/07")
    let movedMonth = sessionsRoot.appending(path: "2026/07-anchored")
    let target = month.appending(path: "race-session")
    let outsideParent = base.appending(path: "outside")
    let outsideTarget = outsideParent.appending(path: "race-session")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("delete only the anchored Session".utf8).write(
      to: target.appending(path: "inside.txt"))
    try FileManager.default.createDirectory(
      at: outsideTarget, withIntermediateDirectories: true)
    let outsideSentinel = outsideTarget.appending(path: "must-survive.txt")
    try Data("external".utf8).write(to: outsideSentinel)

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let retained = try RetainedSession(
      sessionID: "race-session", root: target, sizeBytes: 100,
      completedAt: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(-1),
      isPinned: false)
    var replacedPath = false
    let controller = SessionRetentionController(
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .retentionBeforeDelete, !replacedPath else { return }
        replacedPath = true
        try FileManager.default.moveItem(at: month, to: movedMonth)
        try FileManager.default.createSymbolicLink(
          at: month, withDestinationURL: outsideParent)
      })
    let plan = controller.plan(
      sessions: [retained], totalQuotaBytes: 100, safetyMarginBytes: 100, now: now)
    XCTAssertEqual(plan.deletionSessionIDs, [retained.sessionID])

    try controller.apply(plan, sessions: [retained], sessionsRoot: sessionsRoot)

    XCTAssertTrue(replacedPath)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: movedMonth.appending(path: retained.sessionID).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideSentinel.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
  }

  func testTEST_AC_STO_001_01_sameVolumeDifferentPathsShareIdentityAndBudget() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let firstPath = base.appending(path: "first")
    let secondPath = base.appending(path: "second")
    try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
    let resolver = SystemVolumeIdentityResolver()
    let firstIdentity = try resolver.resolve(firstPath)
    XCTAssertEqual(firstIdentity, try resolver.resolve(secondPath))
    let snapshot = storageSnapshot(identity: firstIdentity, available: 10_000)
    let coordinator = HostStorageCoordinator()
    let first = try request(
      id: "claim-first", job: "job-first", volume: firstIdentity, writer: .heavy)
    let second = try request(
      id: "claim-second", job: "job-second", volume: firstIdentity, writer: .heavy)
    guard case .admitted = await coordinator.admit(first, snapshot: snapshot) else {
      return XCTFail("first heavy writer must be admitted")
    }
    let secondAdmission = await coordinator.admit(second, snapshot: snapshot)
    let activeCount = await coordinator.activeClaimCount(on: firstIdentity)
    XCTAssertEqual(secondAdmission, .queued(.waitingForStorage))
    XCTAssertEqual(activeCount, 1)
  }

  func testTEST_AC_STO_002_01_lowWaterStopsOptionalGrowthButKeepsFinalizationHeadroom()
    async throws
  {
    let identity = try VolumeIdentity(value: "volume-low-water")
    let coordinator = HostStorageCoordinator()
    let claim = try request(
      id: "claim-low", job: "job-low", volume: identity, writer: .light,
      metadata: 100, finalization: 100, growth: 300)
    guard
      case .admitted = await coordinator.admit(
        claim, snapshot: storageSnapshot(identity: identity, available: 1_000))
    else { return XCTFail("claim should be admitted") }
    let lowWaterAction = await coordinator.revalidate(
      claimID: claim.claimID,
      current: storageSnapshot(identity: identity, available: 400))
    let enospcAction = await coordinator.reportWriteFailure(claimID: claim.claimID, errno: ENOSPC)
    let reserved = await coordinator.reservedBytes(on: identity)
    let active = await coordinator.activeClaimCount(on: identity)
    XCTAssertEqual(lowWaterAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(enospcAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(reserved, 200)
    XCTAssertEqual(active, 1)
  }

  func testTEST_AC_STO_003_01_heavyWriterAdmissionSerializesPerVolumeOnly() async throws {
    let volumeA = try VolumeIdentity(value: "volume-a")
    let volumeB = try VolumeIdentity(value: "volume-b")
    let coordinator = HostStorageCoordinator()
    let snapshotA = storageSnapshot(identity: volumeA, available: 100_000)
    let snapshotB = storageSnapshot(identity: volumeB, available: 100_000)
    let heavyA = try request(id: "heavy-a", job: "job-heavy-a", volume: volumeA, writer: .heavy)
    let heavyA2 = try request(
      id: "heavy-a-2", job: "job-heavy-a-2", volume: volumeA, writer: .heavy)
    let heavyB = try request(id: "heavy-b", job: "job-heavy-b", volume: volumeB, writer: .heavy)
    let lightA = try request(id: "light-a", job: "job-light-a", volume: volumeA, writer: .light)
    let unknownA = try request(
      id: "unknown-a", job: "job-unknown-a", volume: volumeA, writer: .unknown)
    guard case .admitted = await coordinator.admit(heavyA, snapshot: snapshotA) else {
      return XCTFail("first heavy writer")
    }
    let secondHeavyAdmission = await coordinator.admit(heavyA2, snapshot: snapshotA)
    XCTAssertEqual(secondHeavyAdmission, .queued(.waitingForStorage))
    guard case .admitted = await coordinator.admit(heavyB, snapshot: snapshotB) else {
      return XCTFail("different volume should admit")
    }
    guard case .admitted = await coordinator.admit(lightA, snapshot: snapshotA) else {
      return XCTFail("bounded light writer may run with heavy when budget allows")
    }
    let unknownAdmission = await coordinator.admit(unknownA, snapshot: snapshotA)
    XCTAssertEqual(unknownAdmission, .queued(.waitingForStorage))
  }

  func testTEST_AC_STO_004_01_softClaimRechecksExternalPressureWithoutDoubleCounting() async throws
  {
    let identity = try VolumeIdentity(value: "volume-soft-claim")
    let coordinator = HostStorageCoordinator()
    let claim = try request(
      id: "soft-claim", job: "job-soft", volume: identity, writer: .light,
      metadata: 100, finalization: 100, growth: 800)
    guard
      case .admitted = await coordinator.admit(
        claim, snapshot: storageSnapshot(identity: identity, available: 2_000))
    else { return XCTFail("claim should be admitted") }
    let initialReserved = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(initialReserved, 1_000)
    try await coordinator.updateRemainingGrowth(claimID: claim.claimID, remainingBytes: 300)
    do {
      try await coordinator.updateRemainingGrowth(claimID: claim.claimID, remainingBytes: 301)
      XCTFail("growth increase must require fresh admission")
    } catch SessionStorageError.invalidRecord {}
    XCTAssertThrowsError(
      try StorageBudget(
        metadataHeadroomBytes: UInt64.max, finalizationHeadroomBytes: 1,
        remainingGrowthBytes: 1, writerClass: .light))
    let updatedReserved = await coordinator.reservedBytes(on: identity)
    let pressureAction = await coordinator.revalidate(
      claimID: claim.claimID,
      current: storageSnapshot(identity: identity, available: 499))
    let enospcAction = await coordinator.reportWriteFailure(claimID: claim.claimID, errno: ENOSPC)
    let finalReserved = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(updatedReserved, 500)
    XCTAssertEqual(pressureAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(enospcAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(finalReserved, 200)

    let fixture = try await makeSession(sessionID: "session-enospc", jobID: "job-enospc")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let artifactCoordinator = fixture.coordinator
    let artifactClaim = fixture.claim
    let completedSource = fixture.base.appending(path: "completed.shard")
    try Data("completed-shard".utf8).write(to: completedSource)
    let completed = try SessionArtifactStore(layout: fixture.layout).publish(
      from: completedSource,
      request: ArtifactPublicationRequest(
        artifactID: "completed-shard", role: .raw, publicationName: "completed.shard",
        origin: "ENOSPC fixture"),
      claim: artifactClaim)
    let growingSource = fixture.base.appending(path: "growing.shard")
    try Data(repeating: 0x41, count: 128 * 1_024).write(to: growingSource)
    var writeCount = 0
    let failingStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactWrite else { return }
        writeCount += 1
        if writeCount == 2 {
          throw SessionStorageError.writeFailed(path: "injected.part", errno: ENOSPC)
        }
      })
    do {
      _ = try failingStore.publish(
        from: growingSource,
        request: ArtifactPublicationRequest(
          artifactID: "growing-shard", role: .raw, publicationName: "growing.shard",
          origin: "ENOSPC fixture"),
        claim: artifactClaim)
      XCTFail("runtime ENOSPC must fail publication")
    } catch SessionStorageError.writeFailed(_, let failure) {
      XCTAssertEqual(failure, ENOSPC)
      _ = await artifactCoordinator.reportWriteFailure(
        claimID: artifactClaim.claimID, errno: failure)
    }
    let stickyAction = await artifactCoordinator.revalidate(
      claimID: artifactClaim.claimID,
      current: storageSnapshot(identity: artifactClaim.volumeIdentity, available: UInt64.max))
    XCTAssertEqual(stickyAction, .stopOptionalWritesAndFinalize)
    XCTAssertThrowsError(
      try failingStore.publish(
        from: completedSource,
        request: ArtifactPublicationRequest(
          artifactID: "write-after-enospc", role: .raw, publicationName: "forbidden.shard",
          origin: "ENOSPC fixture"),
        claim: artifactClaim)
    ) { error in
      guard case SessionStorageError.optionalWritesStopped = error else {
        return XCTFail("unexpected claim-stop error: \(error)")
      }
    }
    let partial = try XCTUnwrap(failingStore.partialArtifacts().first)
    let partialBytes = try Data(contentsOf: partial.url)
    let partialRecord = try ArtifactRecord(
      id: "growing-shard-partial", role: .partial, origin: "runtime ENOSPC",
      relativePath: "artifacts/partial/\(partial.url.lastPathComponent)",
      size: UInt64(partialBytes.count), sha256: sha256(partialBytes))
    let failedManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID, status: "failed",
        artifacts: [completed.record, partialRecord]))
    _ = try AtomicSessionManifestPublisher(layout: fixture.layout).publish(failedManifest)
    XCTAssertTrue(FileManager.default.fileExists(atPath: completed.url.path))
    XCTAssertGreaterThan(partial.size, 0)
    XCTAssertEqual(
      try AtomicSessionManifestPublisher(layout: fixture.layout).load().status, "failed")
  }

  func testTEST_AC_STO_005_01_leaseReleasesAllPathsAndRemountIdentityFailsClosed() async throws {
    let successSetup = try makeSessionFactory(
      sessionID: "session-lease-success", jobID: "job-success")
    defer { try? FileManager.default.removeItem(at: successSetup.factory.base) }
    let identity = successSetup.identity
    let replacement = try VolumeIdentity(value: "volume-replacement")
    let coordinator = HostStorageCoordinator()
    let snapshot = storageSnapshot(identity: identity, available: 50_000)
    let successFixture = SessionFixtureBox()
    let successPersistence = TerminalPersistenceBox()
    let releasedClaim = StorageClaimBox()
    let success = try request(
      id: "lease-success", job: "job-success", volume: identity, writer: .light)
    let successResult = try await coordinator.performWithClaim(
      request: success, snapshot: snapshot,
      operation: { claim in
        let fixture = try successSetup.factory.create(
          claim: claim, coordinator: coordinator)
        successFixture.store(fixture)
        successPersistence.store(
          try Self.terminalFinalization(
            fixture: fixture, status: "succeeded", recordID: "terminal-success"))
        releasedClaim.store(claim)
        return "complete"
      },
      finalize: { claim, disposition in
        XCTAssertTrue(claim.finalizationOnly)
        let persistence = try XCTUnwrap(successPersistence.load())
        return try persistence.finalizer.persist(
          claim: claim, disposition: disposition,
          auditRecord: persistence.auditRecord, manifest: persistence.manifest)
      })
    guard case .executed(let value) = successResult else { return XCTFail("success path") }
    XCTAssertEqual(value, "complete")
    let activeAfterSuccess = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterSuccess, 0)
    let completedSuccessPersistence = try XCTUnwrap(successPersistence.load())
    XCTAssertThrowsError(
      try completedSuccessPersistence.finalizer.persist(
        claim: XCTUnwrap(releasedClaim.load()), disposition: .succeeded,
        auditRecord: completedSuccessPersistence.auditRecord,
        manifest: completedSuccessPersistence.manifest)
    ) { error in
      guard case SessionStorageError.claimUnavailable = error else {
        return XCTFail("released claim was accepted for finalization: \(error)")
      }
    }

    let throwSetup = try makeSessionFactory(
      sessionID: "session-lease-throw", jobID: "job-throw")
    defer { try? FileManager.default.removeItem(at: throwSetup.factory.base) }
    let throwPersistence = TerminalPersistenceBox()
    let throwing = try request(
      id: "lease-throw", job: "job-throw", volume: identity, writer: .light)
    do {
      _ =
        try await coordinator.performWithClaim(
          request: throwing, snapshot: snapshot,
          operation: { claim in
            let fixture = try throwSetup.factory.create(
              claim: claim, coordinator: coordinator)
            throwPersistence.store(
              try Self.terminalFinalization(
                fixture: fixture, status: "failed", recordID: "terminal-throw"))
            throw StorageContractFault.operation
          },
          finalize: { claim, disposition in
            XCTAssertTrue(claim.finalizationOnly)
            let persistence = try XCTUnwrap(throwPersistence.load())
            return try persistence.finalizer.persist(
              claim: claim, disposition: disposition,
              auditRecord: persistence.auditRecord, manifest: persistence.manifest)
          }) as StorageClaimExecution<String>
      XCTFail("throw must escape")
    } catch StorageContractFault.operation {}
    let activeAfterThrow = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterThrow, 0)

    let cancelSetup = try makeSessionFactory(
      sessionID: "session-lease-cancel", jobID: "job-cancel")
    defer { try? FileManager.default.removeItem(at: cancelSetup.factory.base) }
    let cancelPersistence = TerminalPersistenceBox()
    let cancelling = try request(
      id: "lease-cancel", job: "job-cancel", volume: identity, writer: .light)
    let cancelOperation: @Sendable (StorageClaim) async throws -> String = { claim in
      let fixture = try cancelSetup.factory.create(
        claim: claim, coordinator: coordinator)
      cancelPersistence.store(
        try Self.terminalFinalization(
          fixture: fixture, status: "cancelled", recordID: "terminal-cancel"))
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return "late"
    }
    let cancelFinalizer:
      @Sendable (StorageClaim, StorageTerminalDisposition) async throws
        -> StorageTerminalPersistenceReceipt = { claim, disposition in
          XCTAssertFalse(Task.isCancelled)
          XCTAssertTrue(claim.finalizationOnly)
          let persistence = try XCTUnwrap(cancelPersistence.load())
          return try persistence.finalizer.persist(
            claim: claim, disposition: disposition,
            auditRecord: persistence.auditRecord, manifest: persistence.manifest)
        }
    let task = Task {
      try await coordinator.performWithClaim(
        request: cancelling, snapshot: snapshot,
        operation: cancelOperation, finalize: cancelFinalizer)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancel must escape")
    } catch is CancellationError {}
    let activeAfterCancel = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterCancel, 0)

    let failedFinalizationSetup = try makeSessionFactory(
      sessionID: "session-finalization-failure", jobID: "job-finalization-failure")
    defer { try? FileManager.default.removeItem(at: failedFinalizationSetup.factory.base) }
    let manifestSyncAttempts = LockedCounter()
    let failedPersistence = TerminalPersistenceBox()
    let failedFinalization = try request(
      id: "lease-finalization-failure", job: "job-finalization-failure", volume: identity,
      writer: .light)
    let retainedFailedClaim = StorageClaimBox()
    do {
      _ =
        try await coordinator.performWithClaim(
          request: failedFinalization, snapshot: snapshot,
          operation: { claim in
            let fixture = try failedFinalizationSetup.factory.create(
              claim: claim, coordinator: coordinator)
            failedPersistence.store(
              try Self.terminalFinalization(
                fixture: fixture, status: "failed",
                recordID: "terminal-finalization-failure",
                manifestFaultInjector: SessionStorageFaultInjector { point in
                  guard point == .manifestFileSync else { return }
                  if manifestSyncAttempts.incrementAndGet() == 1 {
                    throw StorageContractFault.finalization
                  }
                }))
            retainedFailedClaim.store(claim)
            throw StorageContractFault.operation
          },
          finalize: { claim, disposition in
            let persistence = try XCTUnwrap(failedPersistence.load())
            return try persistence.finalizer.persist(
              claim: claim, disposition: disposition,
              auditRecord: persistence.auditRecord, manifest: persistence.manifest)
          })
        as StorageClaimExecution<String>
      XCTFail("terminal persistence failure must escape")
    } catch let combined as StorageOperationFinalizationError {
      guard case .operation = combined.operationError as? StorageContractFault else {
        return XCTFail("original operation error was not preserved: \(combined.operationError)")
      }
      guard case .finalization = combined.finalizationError as? StorageContractFault else {
        return XCTFail("finalization error was not preserved: \(combined.finalizationError)")
      }
    }
    let activeAfterFinalizationFailure = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterFinalizationFailure, 1)
    let repairPersistence = try XCTUnwrap(failedPersistence.load())
    let repairedReceipt = try repairPersistence.finalizer.persist(
      claim: XCTUnwrap(retainedFailedClaim.load()), disposition: .failed,
      auditRecord: repairPersistence.auditRecord,
      manifest: repairPersistence.manifest)
    let repairedRelease = try await coordinator.completeRecoveredFinalization(repairedReceipt)
    let repeatedRepairedRelease = try await coordinator.completeRecoveredFinalization(
      repairedReceipt)
    let activeAfterRepair = await coordinator.activeClaimCount()
    XCTAssertEqual(repairedRelease, .releasedNow)
    XCTAssertEqual(repeatedRepairedRelease, .alreadyReleased)
    XCTAssertEqual(activeAfterRepair, 0)

    let rogueSetup = try makeSessionFactory(
      sessionID: "session-rogue-receipt", jobID: "job-receipt-mismatch")
    defer { try? FileManager.default.removeItem(at: rogueSetup.factory.base) }
    let rogueCoordinator = HostStorageCoordinator()
    let rogueRequest = try request(
      id: "rogue-receipt-claim", job: "job-receipt-mismatch", volume: identity,
      writer: .light)
    guard
      case .admitted(let rogueClaim) = await rogueCoordinator.admit(
        rogueRequest, snapshot: snapshot)
    else { return XCTFail("rogue receipt fixture claim") }
    let rogueFixture = try rogueSetup.factory.create(
      claim: rogueClaim, coordinator: rogueCoordinator)
    _ = await rogueCoordinator.reportWriteFailure(claimID: rogueClaim.claimID, errno: ENOSPC)
    let roguePersistence = try Self.terminalFinalization(
      fixture: rogueFixture, status: "succeeded", recordID: "terminal-rogue-receipt")
    let rogueReceipt = try roguePersistence.finalizer.persist(
      claim: rogueClaim, disposition: .succeeded,
      auditRecord: roguePersistence.auditRecord, manifest: roguePersistence.manifest)

    let receiptSetup = try makeSessionFactory(
      sessionID: "session-receipt-mismatch", jobID: "job-receipt-mismatch")
    defer { try? FileManager.default.removeItem(at: receiptSetup.factory.base) }
    let receiptPersistence = TerminalPersistenceBox()
    let receiptRequest = try request(
      id: "expected-receipt-claim", job: "job-receipt-mismatch", volume: identity,
      writer: .light)
    let expectedReceiptClaim = StorageClaimBox()
    do {
      _ =
        try await coordinator.performWithClaim(
          request: receiptRequest, snapshot: snapshot,
          operation: { claim in
            let fixture = try receiptSetup.factory.create(
              claim: claim, coordinator: coordinator)
            receiptPersistence.store(
              try Self.terminalFinalization(
                fixture: fixture, status: "succeeded",
                recordID: "terminal-receipt-mismatch"))
            expectedReceiptClaim.store(claim)
            return "complete"
          },
          finalize: { _, _ in rogueReceipt }) as StorageClaimExecution<String>
      XCTFail("receipt for a different claim must be rejected")
    } catch SessionStorageError.invalidRecord(let message) {
      XCTAssertTrue(message.contains("receipt mismatch"))
    }
    let activeAfterReceiptMismatch = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterReceiptMismatch, 1)
    let expectedPersistence = try XCTUnwrap(receiptPersistence.load())
    let recoveredReceipt = try expectedPersistence.finalizer.persist(
      claim: XCTUnwrap(expectedReceiptClaim.load()), disposition: .succeeded,
      auditRecord: expectedPersistence.auditRecord,
      manifest: expectedPersistence.manifest)
    let recoveryReleaser = try await coordinator.recoveredFinalizationReleaser(recoveredReceipt)
    XCTAssertEqual(try recoveryReleaser.ensureStorageClaimReleased(), .releasedNow)
    XCTAssertEqual(try recoveryReleaser.ensureStorageClaimReleased(), .alreadyReleased)
    let activeAfterSeamRelease = await coordinator.activeClaimCount()
    let repeatedSeamRelease = try await coordinator.completeRecoveredFinalization(
      recoveredReceipt)
    XCTAssertEqual(activeAfterSeamRelease, 0)
    XCTAssertEqual(repeatedSeamRelease, .alreadyReleased)

    let reusedSetup = try makeSessionFactory(
      sessionID: "session-reused-generation", jobID: "job-receipt-mismatch")
    defer { try? FileManager.default.removeItem(at: reusedSetup.factory.base) }
    let reusedPersistence = TerminalPersistenceBox()
    let reusedGenerationClaim = StorageClaimBox()
    do {
      _ =
        try await coordinator.performWithClaim(
          request: receiptRequest, snapshot: snapshot,
          operation: { claim in
            let fixture = try reusedSetup.factory.create(
              claim: claim, coordinator: coordinator)
            reusedPersistence.store(
              try Self.terminalFinalization(
                fixture: fixture, status: "succeeded",
                recordID: "terminal-reused-generation"))
            reusedGenerationClaim.store(claim)
            return "new admission generation"
          },
          finalize: { _, _ in throw StorageContractFault.finalization })
        as StorageClaimExecution<String>
      XCTFail("new claim generation finalization fault must escape")
    } catch StorageContractFault.finalization {}
    do {
      _ = try await coordinator.recoveredFinalizationReleaser(recoveredReceipt)
      XCTFail("stale receipt must not bind the reused claim ID")
    } catch SessionStorageError.invalidRecord(let message) {
      XCTAssertTrue(message.contains("admission generation"))
    }
    let activeAfterStaleReceipt = await coordinator.activeClaimCount()
    XCTAssertEqual(activeAfterStaleReceipt, 1)
    let currentPersistence = try XCTUnwrap(reusedPersistence.load())
    let reusedClaimReceipt = try currentPersistence.finalizer.persist(
      claim: XCTUnwrap(reusedGenerationClaim.load()), disposition: .succeeded,
      auditRecord: currentPersistence.auditRecord,
      manifest: currentPersistence.manifest)
    let reusedClaimRelease = try await coordinator.completeRecoveredFinalization(
      reusedClaimReceipt)
    let activeAfterReusedClaimRelease = await coordinator.activeClaimCount()
    XCTAssertEqual(reusedClaimRelease, .releasedNow)
    XCTAssertEqual(activeAfterReusedClaimRelease, 0)

    let remount = try request(
      id: "lease-remount", job: "job-remount", volume: identity, writer: .light)
    guard case .admitted = await coordinator.admit(remount, snapshot: snapshot) else {
      return XCTFail("remount claim")
    }
    let remountAction = await coordinator.revalidate(
      claimID: remount.claimID,
      current: storageSnapshot(identity: replacement, available: 50_000))
    XCTAssertEqual(
      remountAction, .pauseForVolumeIdentityChange(expected: identity, actual: replacement))

    let unverifiedIdentity = try VolumeIdentity(value: "dev-unverified:4294967295")
    let unverified = try request(
      id: "lease-unverified-volume", job: "job-unverified-volume", volume: unverifiedIdentity,
      writer: .light)
    guard
      case .admitted = await coordinator.admit(
        unverified,
        snapshot: storageSnapshot(identity: unverifiedIdentity, available: 50_000))
    else { return XCTFail("unverified mount should be grouped for initial admission") }
    let unverifiedAction = await coordinator.revalidate(
      claimID: unverified.claimID,
      current: storageSnapshot(identity: unverifiedIdentity, available: 50_000))
    XCTAssertEqual(unverifiedAction, .volumeUnavailable)
    let repeatedUnverifiedAction = await coordinator.revalidate(
      claimID: unverified.claimID,
      current: storageSnapshot(identity: unverifiedIdentity, available: 50_000))
    XCTAssertEqual(repeatedUnverifiedAction, .volumeUnavailable)
  }

  func testCompletedReceiptTombstonesUseBoundedLRUIdempotencyWindow() async throws {
    let coordinator = HostStorageCoordinator(completedReceiptCacheLimit: 2)
    var bases: [URL] = []
    defer {
      for base in bases { try? FileManager.default.removeItem(at: base) }
    }
    var receipts: [StorageTerminalPersistenceReceipt] = []

    for index in 0..<3 {
      let setup = try makeSessionFactory(
        sessionID: "session-receipt-cache-\(index)", jobID: "job-receipt-cache-\(index)")
      bases.append(setup.factory.base)
      let persistence = TerminalPersistenceBox()
      let receiptBox = TerminalReceiptBox()
      let request = try request(
        id: "claim-receipt-cache-\(index)", job: setup.factory.jobID,
        volume: setup.identity, writer: .light)
      let result: StorageClaimExecution<String> = try await coordinator.performWithClaim(
        request: request,
        snapshot: storageSnapshot(identity: setup.identity, available: 50_000),
        operation: { claim in
          let fixture = try setup.factory.create(claim: claim, coordinator: coordinator)
          persistence.store(
            try Self.terminalFinalization(
              fixture: fixture, status: "succeeded",
              recordID: "terminal-receipt-cache-\(index)"))
          return "completed-\(index)"
        },
        finalize: { claim, disposition in
          let terminal = try XCTUnwrap(persistence.load())
          let receipt = try terminal.finalizer.persist(
            claim: claim, disposition: disposition,
            auditRecord: terminal.auditRecord, manifest: terminal.manifest)
          receiptBox.store(receipt)
          return receipt
        })
      guard case .executed(let value) = result else {
        return XCTFail("receipt-cache claim was unexpectedly queued")
      }
      XCTAssertEqual(value, "completed-\(index)")
      receipts.append(try XCTUnwrap(receiptBox.load()))
      if index == 1 {
        let touched = try await coordinator.completeRecoveredFinalization(receipts[0])
        XCTAssertEqual(touched, .alreadyReleased)
      }
    }

    let tombstoneCount = await coordinator.completedReceiptTombstoneCount()
    XCTAssertEqual(tombstoneCount, 2)
    let retained = try await coordinator.completeRecoveredFinalization(receipts[0])
    XCTAssertEqual(retained, .alreadyReleased)
    do {
      _ = try await coordinator.completeRecoveredFinalization(receipts[1])
      XCTFail("least-recently-used receipt tombstone must be evicted")
    } catch SessionStorageError.claimUnavailable {}
    let newest = try await coordinator.completeRecoveredFinalization(receipts[2])
    XCTAssertEqual(newest, .alreadyReleased)
  }

  func testTEST_MAC_M1_STORE_001_realVolumeIdentityAdmissionAndENOSPCMatrix() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appending(path: "first")
    let second = base.appending(path: "second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let resolver = SystemVolumeIdentityResolver()
    let identity = try resolver.resolve(first)
    XCTAssertEqual(identity, try resolver.resolve(second))
    let realSnapshot = try SystemHostStorageProbe().snapshot(for: first)
    XCTAssertEqual(realSnapshot.volumeIdentity, identity)
    XCTAssertGreaterThan(realSnapshot.totalBytes, 0)
    XCTAssertGreaterThan(realSnapshot.availableBytes, 0)

    let coordinator = HostStorageCoordinator()
    let admissionSnapshot = storageSnapshot(identity: identity, available: 10_000)
    let firstHeavy = try request(
      id: "mac-heavy-one", job: "mac-job-one", volume: identity, writer: .heavy,
      metadata: 128, finalization: 128, growth: 1_024)
    let secondHeavy = try request(
      id: "mac-heavy-two", job: "mac-job-two", volume: identity, writer: .heavy,
      metadata: 128, finalization: 128, growth: 1_024)
    guard case .admitted = await coordinator.admit(firstHeavy, snapshot: admissionSnapshot) else {
      return XCTFail("first macOS heavy writer")
    }
    let secondAdmission = await coordinator.admit(secondHeavy, snapshot: admissionSnapshot)
    let lowWaterAction = await coordinator.revalidate(
      claimID: firstHeavy.claimID,
      current: storageSnapshot(identity: identity, available: 200))
    let enospcAction = await coordinator.reportWriteFailure(
      claimID: firstHeavy.claimID, errno: ENOSPC)
    let retryAfterENOSPC = await coordinator.admit(secondHeavy, snapshot: admissionSnapshot)
    let reserved = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(secondAdmission, .queued(.waitingForStorage))
    XCTAssertEqual(lowWaterAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(enospcAction, .stopOptionalWritesAndFinalize)
    XCTAssertEqual(retryAfterENOSPC, .queued(.waitingForStorage))
    XCTAssertEqual(reserved, 256)
    let replacement = try VolumeIdentity(value: identity.value + ":replacement")
    let remountAction = await coordinator.revalidate(
      claimID: firstHeavy.claimID,
      current: storageSnapshot(identity: replacement, available: 10_000))
    XCTAssertEqual(
      remountAction, .pauseForVolumeIdentityChange(expected: identity, actual: replacement))
  }

  func testDurableSessionAuditSeamReopensReplaysAndPropagatesWriteFailure() async throws {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let categories = SessionAuditCategory.allCases
    var records: [SessionAuditRecord] = []
    for (index, category) in categories.enumerated() {
      records.append(
        try SessionAuditRecord(
          recordID: "audit-record-\(index)", auditID: "audit-host-wide",
          correlationID: "correlation-lifecycle", sessionID: fixture.layout.sessionID,
          jobID: fixture.layout.jobID, category: category,
          timestamp: SessionStorageFixtures.timestamp,
          details: ["ordinal": .integer(Int64(index)), "category": .string(category.rawValue)]))
    }
    var store: FileDurableSessionAuditStore? = try FileDurableSessionAuditStore(
      layout: fixture.layout)
    for record in records { try store?.appendAndSynchronize(record) }
    let bytesBeforeReopen = try Data(contentsOf: fixture.layout.sessionAuditURL)
    print("TASK-M1-005 audit records=\(records.count) bytes=\(bytesBeforeReopen.count)")
    store = nil
    let tornWriter = try FileHandle(forWritingTo: fixture.layout.sessionAuditURL)
    try tornWriter.seekToEnd()
    try tornWriter.write(contentsOf: Data("{\"recordId\":\"torn".utf8))
    try tornWriter.close()
    let reopened = try FileDurableSessionAuditStore(layout: fixture.layout)
    XCTAssertEqual(try reopened.replay(correlationID: "correlation-lifecycle"), records)
    XCTAssertEqual(try Data(contentsOf: fixture.layout.sessionAuditURL), bytesBeforeReopen)
    XCTAssertThrowsError(try FileDurableSessionAuditStore(layout: fixture.layout))
    try reopened.appendAndSynchronize(records[0])
    let conflictingRetry = try SessionAuditRecord(
      recordID: records[0].recordID, auditID: "audit-host-wide",
      correlationID: "correlation-lifecycle", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .preview,
      timestamp: SessionStorageFixtures.timestamp, details: ["conflict": .bool(true)])
    XCTAssertThrowsError(try reopened.appendAndSynchronize(conflictingRetry))
    let afterDuplicate = try SessionAuditRecord(
      recordID: "audit-after-duplicate", auditID: "audit-host-wide",
      correlationID: "correlation-lifecycle", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .outcome,
      timestamp: "2026-07-17T08:00:00.500Z", details: ["durable": .bool(true)])
    try reopened.appendAndSynchronize(afterDuplicate)
    XCTAssertEqual(
      try reopened.replay(correlationID: "correlation-lifecycle"), records + [afterDuplicate])

    let failureFixture = try await makeSession(
      sessionID: "session-audit-failure", jobID: "job-audit-failure")
    defer { try? FileManager.default.removeItem(at: failureFixture.base) }
    let failureStore = try FileDurableSessionAuditStore(
      layout: failureFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .auditFileSync { throw StorageContractFault.injected(point.rawValue) }
      })
    let intent = try SessionAuditRecord(
      recordID: "audit-intent-failure", auditID: "audit-host-wide",
      correlationID: "correlation-failure", sessionID: failureFixture.layout.sessionID,
      jobID: failureFixture.layout.jobID, category: .intent,
      timestamp: SessionStorageFixtures.timestamp, details: ["action": .string("restart")])
    XCTAssertThrowsError(try failureStore.appendAndSynchronize(intent))

    let confirmationFixture = try await makeSession(
      sessionID: "session-confirmation-failure", jobID: "job-confirmation-failure")
    defer { try? FileManager.default.removeItem(at: confirmationFixture.base) }
    let confirmationStore = try FileDurableSessionAuditStore(
      layout: confirmationFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .auditAppend { throw StorageContractFault.injected(point.rawValue) }
      })
    let confirmation = try SessionAuditRecord(
      recordID: "audit-confirmation-failure", auditID: "audit-host-wide",
      correlationID: "correlation-failure", sessionID: confirmationFixture.layout.sessionID,
      jobID: confirmationFixture.layout.jobID, category: .confirmation,
      timestamp: SessionStorageFixtures.timestamp, details: ["decision": .string("accepted")])
    XCTAssertThrowsError(try confirmationStore.appendAndSynchronize(confirmation))
  }

  func testAuditBindsDurableDescriptorToPathAndBoundsCompleteRecord() async throws {
    let fixture = try await makeSession(
      sessionID: "session-audit-path-binding", jobID: "job-audit-path-binding")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let displacedURL = fixture.layout.sessionAuditURL.deletingLastPathComponent()
      .appending(path: "session.displaced.jsonl")
    var substituted = false
    let store = try FileDurableSessionAuditStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .auditFileSync, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(
          at: fixture.layout.sessionAuditURL, to: displacedURL)
        guard
          FileManager.default.createFile(
            atPath: fixture.layout.sessionAuditURL.path, contents: Data(),
            attributes: [.posixPermissions: 0o600])
        else { throw StorageContractFault.operation }
      })
    let record = try SessionAuditRecord(
      recordID: "audit-path-binding", auditID: "audit-path-binding",
      correlationID: "audit-path-binding", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["result": .string("failed")])
    XCTAssertThrowsError(try store.appendAndSynchronize(record)) { error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("audit descriptor substitution returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("no longer bound"))
    }
    XCTAssertThrowsError(try store.replay(correlationID: record.correlationID))
    XCTAssertTrue((try Data(contentsOf: fixture.layout.sessionAuditURL)).isEmpty)
    XCTAssertTrue(try String(contentsOf: displacedURL, encoding: .utf8).contains(record.recordID))

    let reopened = try FileDurableSessionAuditStore(layout: fixture.layout)
    XCTAssertEqual(try reopened.replay(correlationID: record.correlationID), [])

    let oversizedTimestamp =
      "2026-07-17T08:00:00." + String(repeating: "1", count: 80) + "Z"
    XCTAssertThrowsError(
      try SessionAuditRecord(
        recordID: "audit-oversized-timestamp", auditID: "audit-path-binding",
        correlationID: "audit-path-binding", sessionID: fixture.layout.sessionID,
        jobID: fixture.layout.jobID, category: .outcome,
        timestamp: oversizedTimestamp, details: ["result": .string("failed")])
    ) { error in
      guard case SessionStorageError.invalidTimestamp = error else {
        return XCTFail("oversized timestamp returned the wrong error: \(error)")
      }
    }
    var oversizedLine = Data(
      repeating: 0x20, count: SessionAuditRecord.maximumCanonicalRecordBytes + 1)
    oversizedLine.append(0x0A)
    let oversizedFixture = try await makeSession(
      sessionID: "session-audit-record-bound", jobID: "job-audit-record-bound")
    defer { try? FileManager.default.removeItem(at: oversizedFixture.base) }
    try oversizedLine.write(to: oversizedFixture.layout.sessionAuditURL)
    XCTAssertThrowsError(try FileDurableSessionAuditStore(layout: oversizedFixture.layout))
  }

  func testAuditBindsSessionDirectoryAncestryAndStreamsWithinWholeLogBound() async throws {
    let fixture = try await makeSession(
      sessionID: "session-audit-ancestry", jobID: "job-audit-ancestry")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let auditDirectory = fixture.layout.sessionAuditURL.deletingLastPathComponent()
    let displacedDirectory = fixture.layout.root.appending(path: "audit-displaced")
    var substituted = false
    let store = try FileDurableSessionAuditStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .auditFileSync, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(at: auditDirectory, to: displacedDirectory)
        try FileManager.default.createSymbolicLink(
          at: auditDirectory, withDestinationURL: displacedDirectory)
      })
    let record = try SessionAuditRecord(
      recordID: "audit-ancestry", auditID: "audit-ancestry",
      correlationID: "audit-ancestry", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["result": .string("failed")])
    XCTAssertThrowsError(try store.appendAndSynchronize(record)) { error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("audit ancestry substitution returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("descriptor ancestry"))
    }
    XCTAssertThrowsError(try FileDurableSessionAuditStore(layout: fixture.layout))
    XCTAssertTrue(
      try String(
        contentsOf: displacedDirectory.appending(path: "session.jsonl"), encoding: .utf8
      ).contains(record.recordID))

    let oversizedFixture = try await makeSession(
      sessionID: "session-audit-log-bound", jobID: "job-audit-log-bound")
    defer { try? FileManager.default.removeItem(at: oversizedFixture.base) }
    let descriptor = Darwin.open(
      oversizedFixture.layout.sessionAuditURL.path,
      O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    XCTAssertEqual(
      Darwin.ftruncate(
        descriptor, off_t(FileDurableSessionAuditStore.maximumLogBytes + 1)),
      0)
    XCTAssertEqual(Darwin.close(descriptor), 0)
    XCTAssertThrowsError(try FileDurableSessionAuditStore(layout: oversizedFixture.layout)) {
      error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("oversized audit log returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("bounded capacity"))
    }

    let streamingFixture = try await makeSession(
      sessionID: "session-audit-stream", jobID: "job-audit-stream")
    defer { try? FileManager.default.removeItem(at: streamingFixture.base) }
    var streamingStore: FileDurableSessionAuditStore? = try FileDurableSessionAuditStore(
      layout: streamingFixture.layout)
    let detail = String(repeating: "bounded-audit-record-", count: 32)
    for index in 0..<300 {
      try streamingStore?.appendAndSynchronize(
        SessionAuditRecord(
          recordID: "stream-record-\(index)", auditID: "stream-audit",
          correlationID: index == 299 ? "stream-match" : "stream-other",
          sessionID: streamingFixture.layout.sessionID, jobID: streamingFixture.layout.jobID,
          category: .outcome, timestamp: SessionStorageFixtures.timestamp,
          details: ["index": .integer(Int64(index)), "detail": .string(detail)]))
    }
    streamingStore = nil
    let reopened = try FileDurableSessionAuditStore(layout: streamingFixture.layout)
    let matches = try reopened.replay(correlationID: "stream-match")
    XCTAssertEqual(matches.map(\.recordID), ["stream-record-299"])
    var metadata = stat()
    XCTAssertEqual(lstat(streamingFixture.layout.sessionAuditURL.path, &metadata), 0)
    XCTAssertGreaterThan(metadata.st_size, 64 * 1_024)
    XCTAssertLessThanOrEqual(
      metadata.st_size, off_t(FileDurableSessionAuditStore.maximumLogBytes))
  }

  func testManifestSeamRoundTripsServerLifecycleAndRejectsUnknownExtraPartialFiles() async throws {
    let fixture = try await makeSession()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let lifecycleStep = try executionStep(
      id: "step-lifecycle-1", kind: "mutateHDCServerLifecycle", effect: "destructive",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "action": .string("stopConfirmedGeneration"),
        "endpoint": .string("fixture-endpoint"),
        "expectedGeneration": .integer(1),
        "expectedOwnership": .string("external"),
        "impactSnapshotHash": .string(SessionStorageFixtures.scopeHash),
        "confirmationId": .string("confirmation-lifecycle-1"),
      ])
    let lifecycleData = try SessionStorageFixtures.manifest(
      status: "failed", steps: [lifecycleStep],
      confirmations: [SessionStorageFixtures.serverLifecycleConfirmation()])
    let document = try SessionManifestDocument(data: lifecycleData)
    let publisher = AtomicSessionManifestPublisher(layout: fixture.layout)
    let published = try publisher.publish(document)
    print("TASK-M1-005 manifest sha256=\(published.sha256) bytes=\(document.canonicalData.count)")
    XCTAssertEqual(published.sha256, document.sha256)
    let reopened = try AtomicSessionManifestPublisher(layout: fixture.layout).load()
    XCTAssertEqual(reopened, document)
    let lifecycle = try XCTUnwrap(reopened.confirmations.first)
    XCTAssertEqual(lifecycle.kind, "serverLifecycle")
    XCTAssertEqual(lifecycle.relatedStepIDs, ["step-lifecycle-1"])

    var extra = try jsonObject(lifecycleData)
    extra["futureField"] = true
    XCTAssertThrowsError(
      try SessionManifestDocument(data: try JSONSerialization.data(withJSONObject: extra)))

    var partial = try jsonObject(lifecycleData)
    var confirmations = try XCTUnwrap(partial["confirmations"] as? [[String: Any]])
    confirmations[0].removeValue(forKey: "relatedStepIds")
    partial["confirmations"] = confirmations
    XCTAssertThrowsError(
      try SessionManifestDocument(data: try JSONSerialization.data(withJSONObject: partial)))

    var nestedExtra = try jsonObject(lifecycleData)
    var nestedConfirmations = try XCTUnwrap(nestedExtra["confirmations"] as? [[String: Any]])
    nestedConfirmations[0]["future"] = "unsafe"
    nestedExtra["confirmations"] = nestedConfirmations
    XCTAssertThrowsError(
      try SessionManifestDocument(data: try JSONSerialization.data(withJSONObject: nestedExtra)))

    let failureFixture = try await makeSession(
      sessionID: "session-manifest-failure", jobID: "job-manifest-failure")
    defer { try? FileManager.default.removeItem(at: failureFixture.base) }
    let failureDocument = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: failureFixture.layout.sessionID, jobID: failureFixture.layout.jobID))
    let failingPublisher = AtomicSessionManifestPublisher(
      layout: failureFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .manifestFileSync { throw StorageContractFault.injected(point.rawValue) }
      })
    XCTAssertThrowsError(try failingPublisher.publish(failureDocument))
  }

  func testManifestRejectsOversizedCanonicalDocumentBeforeWriteOncePublication() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-size", jobID: "job-manifest-size")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let oversizedWarning = String(
      repeating: "x", count: SessionManifestDocument.maximumCanonicalBytes)
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          warnings: [oversizedWarning]))
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("oversized canonical manifest escaped the manifest domain: \(error)")
      }
      XCTAssertTrue(message.contains("exceeds"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
  }

  func testManifestPreflightsRecoveryMarkerConflictBeforeWriteOncePublication() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-marker-preflight", jobID: "job-manifest-marker-preflight")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let claim = fixture.claim
    let source = fixture.base.appending(path: "marker-preflight.bin")
    let bytes = Data("marker-preflight-bytes".utf8)
    try bytes.write(to: source)
    let published = try SessionArtifactStore(layout: fixture.layout).publish(
      from: source,
      request: ArtifactPublicationRequest(
        artifactID: "marker-preflight", role: .raw,
        publicationName: "marker-preflight.bin", origin: "durable marker record"),
      claim: claim)
    let conflictingRecord = try ArtifactRecord(
      id: published.record.id, role: published.record.role,
      origin: "schema-valid but conflicting origin",
      relativePath: published.record.relativePath, size: published.record.size,
      sha256: published.record.sha256, mediaType: published.record.mediaType,
      derivedFrom: published.record.derivedFrom)
    let conflictingManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: [conflictingRecord]))
    let publisher = AtomicSessionManifestPublisher(layout: fixture.layout)
    XCTAssertThrowsError(try publisher.publish(conflictingManifest)) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("marker conflict escaped Artifact validation: \(error)")
      }
      XCTAssertTrue(message.contains("proposed terminal manifest"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.partialDirectory.path)
        .filter { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") }.count,
      1)

    let correctManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: [published.record]))
    XCTAssertNoThrow(try publisher.publish(correctManifest))
    XCTAssertEqual(try publisher.load(), correctManifest)
  }

  func testManifestPublicationToleratesIncompleteMarkerAfterSourceLoss() async throws {
    let fixture = try await makeSession(
      sessionID: "session-orphan-marker", jobID: "job-orphan-marker")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let claim = fixture.claim
    let source = fixture.base.appending(path: "orphan-marker.bin")
    let bytes = Data("orphan-marker-bytes".utf8)
    try bytes.write(to: source)
    var interrupted = false
    let crashingStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactReplace, !interrupted {
          interrupted = true
          throw StorageContractFault.operation
        }
      })
    XCTAssertThrowsError(
      try crashingStore.publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: "orphan-marker", role: .raw,
          publicationName: "orphan-marker.bin", origin: "orphan marker fixture"),
        claim: claim))
    XCTAssertTrue(interrupted)
    try FileManager.default.removeItem(at: source)
    let partialEntries = try FileManager.default.contentsOfDirectory(
      atPath: fixture.layout.partialDirectory.path)
    XCTAssertEqual(
      partialEntries.filter { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") }.count, 1)
    XCTAssertEqual(partialEntries.filter { $0.hasSuffix(".part") }.count, 1)

    // A provably incomplete publication (durable marker, absent final) whose capture source was
    // lost must not block terminal publication of a manifest that does not own the record.
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: []))
    let publisher = AtomicSessionManifestPublisher(layout: fixture.layout)
    XCTAssertNoThrow(try publisher.publish(manifest))
    XCTAssertEqual(try publisher.load(), manifest)
    let survivors = try FileManager.default.contentsOfDirectory(
      atPath: fixture.layout.partialDirectory.path)
    XCTAssertEqual(
      survivors.filter { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") }.count, 1,
      "the incomplete marker remains as recovery evidence")
    XCTAssertEqual(survivors.filter { $0.hasSuffix(".part") }.count, 1)
  }

  func testManifestPreflightBindsEveryDeclaredArtifactToRealStableBytes() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-artifact-bytes", jobID: "job-manifest-artifact-bytes")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let publisher = AtomicSessionManifestPublisher(layout: fixture.layout)
    func document(_ record: ArtifactRecord) throws -> SessionManifestDocument {
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          status: "failed", artifacts: [record]))
    }
    func assertRejected(
      _ record: ArtifactRecord, file: StaticString = #filePath, line: UInt = #line
    )
      throws
    {
      XCTAssertThrowsError(try publisher.publish(document(record)), file: file, line: line)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path),
        file: file, line: line)
    }

    let ghost = try ArtifactRecord(
      id: "ghost-artifact", role: .raw, origin: "ghost fixture",
      relativePath: "artifacts/raw/ghost.bin", size: 5,
      sha256: String(repeating: "0", count: 64))
    try assertRejected(ghost)

    let actualURL = fixture.layout.rawDirectory.appending(path: "declared.bin")
    let actualBytes = Data("descriptor-bound-manifest-artifact".utf8)
    try actualBytes.write(to: actualURL)
    let wrongSize = try ArtifactRecord(
      id: "wrong-size-artifact", role: .raw, origin: "wrong size fixture",
      relativePath: "artifacts/raw/declared.bin", size: UInt64(actualBytes.count + 1),
      sha256: sha256(actualBytes))
    try assertRejected(wrongSize)
    let wrongHash = try ArtifactRecord(
      id: "wrong-hash-artifact", role: .raw, origin: "wrong hash fixture",
      relativePath: "artifacts/raw/declared.bin", size: UInt64(actualBytes.count),
      sha256: String(repeating: "f", count: 64))
    try assertRejected(wrongHash)

    let symlinkURL = fixture.layout.rawDirectory.appending(path: "symlink.bin")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: actualURL)
    let symlinkRecord = try ArtifactRecord(
      id: "symlink-artifact", role: .raw, origin: "symlink fixture",
      relativePath: "artifacts/raw/symlink.bin", size: UInt64(actualBytes.count),
      sha256: sha256(actualBytes))
    try assertRejected(symlinkRecord)
  }

  func testManifestCommitRejectsArtifactNamespaceSubstitutionBeforeWriteOnceRename() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-artifact-substitution",
      jobID: "job-manifest-artifact-substitution")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "manifest-substitution-source.bin")
    let bytes = Data("manifest-substitution-bytes".utf8)
    try bytes.write(to: source)
    let published = try SessionArtifactStore(layout: fixture.layout).publish(
      from: source,
      request: ArtifactPublicationRequest(
        artifactID: "manifest-substitution-artifact", role: .raw,
        publicationName: "manifest-substitution.bin", origin: "namespace substitution fixture"),
      claim: fixture.claim)
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: [published.record]))
    let artifactsURL = fixture.layout.root.appending(path: "artifacts")
    let displacedURL = fixture.layout.root.appending(path: "artifacts-displaced")
    let externalURL = fixture.base.appending(path: "external-artifacts")
    for component in ["raw", "derived", "partial"] {
      try FileManager.default.createDirectory(
        at: externalURL.appending(path: component), withIntermediateDirectories: true)
    }
    let externalImpostor = externalURL.appending(
      path: String(published.record.relativePath.dropFirst("artifacts/".count)))
    try bytes.write(to: externalImpostor)
    var substituted = false
    defer {
      if substituted {
        try? FileManager.default.removeItem(at: artifactsURL)
        try? FileManager.default.moveItem(at: displacedURL, to: artifactsURL)
      }
    }
    let publisher = AtomicSessionManifestPublisher(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .manifestReplace, !substituted else { return }
        try FileManager.default.moveItem(at: artifactsURL, to: displacedURL)
        try FileManager.default.createSymbolicLink(
          at: artifactsURL, withDestinationURL: externalURL)
        substituted = true
      })

    XCTAssertThrowsError(try publisher.publish(document)) { error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("Artifact namespace substitution escaped validation: \(error)")
      }
    }
    XCTAssertTrue(substituted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    XCTAssertEqual(try Data(contentsOf: externalImpostor), bytes)
  }

  func testManifestCommitSerializesArtifactPublicationAcrossStoreInstances() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-publication-barrier",
      jobID: "job-manifest-publication-barrier")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "late-artifact.bin")
    try Data("must-not-publish-after-terminal-manifest".utf8).write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "late-artifact", role: .raw, publicationName: "late-artifact.bin",
      origin: "manifest publication barrier fixture")
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: []))
    let manifestPaused = DispatchSemaphore(value: 0)
    let artifactAtLock = DispatchSemaphore(value: 0)
    let allowManifest = DispatchSemaphore(value: 0)
    let manifestFinished = DispatchSemaphore(value: 0)
    let artifactFinished = DispatchSemaphore(value: 0)
    let manifestResult = ManifestPublicationResultBox()
    let artifactResult = PublicationResultBox()
    let publisher = AtomicSessionManifestPublisher(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .manifestWrite else { return }
        manifestPaused.signal()
        guard allowManifest.wait(timeout: .now() + 5) == .success else {
          throw StorageContractFault.operation
        }
      })
    let artifactStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactPublicationLock { artifactAtLock.signal() }
      })

    DispatchQueue.global().async {
      manifestResult.store(Result { try publisher.publish(manifest) })
      manifestFinished.signal()
    }
    guard await waitForSemaphore(manifestPaused) == .success else {
      return XCTFail("manifest publisher did not pause after marker preflight")
    }
    DispatchQueue.global().async {
      artifactResult.store(
        Result {
          try artifactStore.publish(
            from: source, request: request, claim: fixture.claim)
        })
      artifactFinished.signal()
    }
    guard await waitForSemaphore(artifactAtLock) == .success else {
      allowManifest.signal()
      return XCTFail("Artifact writer did not reach the shared publication barrier")
    }
    XCTAssertEqual(artifactFinished.wait(timeout: .now() + 0.1), .timedOut)
    allowManifest.signal()
    let manifestWait = await waitForSemaphore(manifestFinished)
    let artifactWait = await waitForSemaphore(artifactFinished)
    XCTAssertEqual(manifestWait, .success)
    XCTAssertEqual(artifactWait, .success)

    XCTAssertNoThrow(try XCTUnwrap(manifestResult.load()).get())
    XCTAssertThrowsError(try XCTUnwrap(artifactResult.load()).get()) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("late Artifact publication escaped Storage validation: \(error)")
      }
      XCTAssertTrue(message.contains("terminal manifest"))
    }
    XCTAssertEqual(try publisher.load(), manifest)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: request.publicationName).path))
    XCTAssertTrue(try artifactStore.partialArtifacts().isEmpty)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.partialDirectory.path)
        .contains { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") })
  }

  func testArtifactRecoveryMarkerProducerEnforcesExactReaderBound() async throws {
    let fixture = try await makeSession(
      sessionID: "session-marker-bound", jobID: "job-marker-bound")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let claim = fixture.claim
    let source = fixture.base.appending(path: "marker-bound-source.bin")
    let bytes = Data("marker-bound".utf8)
    try bytes.write(to: source)
    let digest = sha256(bytes)
    let maximumMarkerBytes = 64 * 1_024

    let exactPrototype = try ArtifactRecord(
      id: "marker-exact", role: .raw, origin: "x",
      relativePath: "artifacts/raw/exact.bin", size: UInt64(bytes.count), sha256: digest)
    let exactOriginCount =
      1 + maximumMarkerBytes
      - (try recoveryMarkerCanonicalData(exactPrototype)).count
    let exactOrigin = String(repeating: "x", count: exactOriginCount)
    let exactRecord = try ArtifactRecord(
      id: "marker-exact", role: .raw, origin: exactOrigin,
      relativePath: "artifacts/raw/exact.bin", size: UInt64(bytes.count), sha256: digest)
    XCTAssertEqual(try recoveryMarkerCanonicalData(exactRecord).count, maximumMarkerBytes)
    let store = SessionArtifactStore(layout: fixture.layout)
    let exactRequest = try ArtifactPublicationRequest(
      artifactID: exactRecord.id, role: .raw, publicationName: "exact.bin",
      origin: exactOrigin, expectedSHA256: digest)
    let exactPublished = try store.publish(
      from: source,
      request: exactRequest,
      claim: claim)
    XCTAssertEqual(exactPublished.record, exactRecord)
    let exactMarker = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: fixture.layout.partialDirectory, includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasSuffix(".json") })
    XCTAssertEqual(try Data(contentsOf: exactMarker).count, maximumMarkerBytes)
    XCTAssertEqual(
      try store.publish(from: source, request: exactRequest, claim: claim),
      exactPublished)

    let oversizedPrototype = try ArtifactRecord(
      id: "marker-oversized", role: .raw, origin: "x",
      relativePath: "artifacts/raw/oversized.bin", size: UInt64(bytes.count), sha256: digest)
    let oversizedOriginCount =
      2 + maximumMarkerBytes
      - (try recoveryMarkerCanonicalData(oversizedPrototype)).count
    let oversizedOrigin = String(repeating: "x", count: oversizedOriginCount)
    let oversizedRecord = try ArtifactRecord(
      id: "marker-oversized", role: .raw, origin: oversizedOrigin,
      relativePath: "artifacts/raw/oversized.bin", size: UInt64(bytes.count), sha256: digest)
    XCTAssertEqual(
      try recoveryMarkerCanonicalData(oversizedRecord).count, maximumMarkerBytes + 1)
    XCTAssertThrowsError(
      try SessionArtifactStore(layout: fixture.layout).publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: oversizedRecord.id, role: .raw, publicationName: "oversized.bin",
          origin: oversizedOrigin, expectedSHA256: digest),
        claim: claim)
    ) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("oversized marker escaped Artifact validation: \(error)")
      }
      XCTAssertTrue(message.contains("exceeds 65536"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: "oversized.bin").path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.partialDirectory.path)
        .filter { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") }.count,
      1)
    let exactManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
        status: "failed", artifacts: [exactPublished.record]))
    XCTAssertNoThrow(
      try AtomicSessionManifestPublisher(layout: fixture.layout).publish(exactManifest))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixture.layout.partialDirectory.path)
        .filter { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") }.count,
      0)
  }

  func testArtifactClaimDurabilityAndRegularFileBoundaries() async throws {
    let fixture = try await makeSession(
      sessionID: "session-artifact-boundaries", jobID: "job-artifact-boundaries")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let claim = fixture.claim
    let source = fixture.base.appending(path: "source.bin")
    try Data("source-bytes".utf8).write(to: source)
    let syncFailureStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactFileSync {
          throw DurableFileError.syncFailed(path: "injected-sync.part", errno: ENOSPC)
        }
      })
    XCTAssertThrowsError(
      try syncFailureStore.publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: "sync-failure", role: .raw, publicationName: "sync-failure.bin",
          origin: "sync fault"),
        claim: claim)
    ) { error in
      guard case SessionStorageError.writeFailed(_, let failure) = error else {
        return XCTFail("sync failure escaped Storage error domain: \(error)")
      }
      XCTAssertEqual(failure, ENOSPC)
    }

    var reached: Set<SessionStorageFaultPoint> = []
    let durableStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { reached.insert($0) })
    _ = try durableStore.publish(
      from: source,
      request: ArtifactPublicationRequest(
        artifactID: "directory-sync", role: .raw, publicationName: "directory-sync.bin",
        origin: "directory sync fixture"),
      claim: claim)
    XCTAssertTrue(reached.contains(.artifactPartialDirectorySync))
    XCTAssertTrue(reached.contains(.artifactDirectorySync))
    XCTAssertTrue(reached.contains(.artifactSourceDirectorySync))

    let sourceDirectoryFailure = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactSourceDirectorySync {
          throw DurableFileError.syncFailed(
            path: fixture.layout.partialDirectory.path, errno: ENOSPC)
        }
      })
    XCTAssertThrowsError(
      try sourceDirectoryFailure.publish(
        from: source,
        request: ArtifactPublicationRequest(
          artifactID: "source-dir-sync", role: .raw, publicationName: "source-dir-sync.bin",
          origin: "source directory sync fault"),
        claim: claim)
    ) { error in
      guard case SessionStorageError.writeFailed(_, let failure) = error else {
        return XCTFail("directory sync failure escaped Storage error domain: \(error)")
      }
      XCTAssertEqual(failure, ENOSPC)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: "source-dir-sync.bin").path))

    let fifo = fixture.base.appending(path: "blocking.fifo")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertThrowsError(
      try durableStore.publish(
        from: fifo,
        request: ArtifactPublicationRequest(
          artifactID: "fifo-source", role: .raw, publicationName: "fifo.bin",
          origin: "special-file fixture"),
        claim: claim)
    ) { error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("FIFO must be rejected as a non-regular source: \(error)")
      }
    }
    XCTAssertThrowsError(
      try InputImageReferencer().reference(URL(fileURLWithPath: "/dev/zero")))
  }

  func testArtifactPublicationRejectsSourceAppendAndTruncateDuringStreaming() async throws {
    let appendFixture = try await makeSession(
      sessionID: "session-source-append", jobID: "job-source-append")
    defer { try? FileManager.default.removeItem(at: appendFixture.base) }
    let appendSource = appendFixture.base.appending(path: "append-source.bin")
    try Data(repeating: 0x41, count: 128 * 1_024).write(to: appendSource)
    let appendClaim = appendFixture.claim
    let appendStore = SessionArtifactStore(
      layout: appendFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactSourceValidation else { return }
        let handle = try FileHandle(forWritingTo: appendSource)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("concurrent-append".utf8))
        try handle.close()
      })
    XCTAssertThrowsError(
      try appendStore.publish(
        from: appendSource,
        request: ArtifactPublicationRequest(
          artifactID: "artifact-source-append", role: .raw,
          publicationName: "append.bin", origin: "concurrent append fixture"),
        claim: appendClaim)
    ) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("source append was not rejected as unstable: \(error)")
      }
      XCTAssertTrue(message.contains("changed"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: appendFixture.layout.rawDirectory.appending(path: "append.bin").path))

    let truncateFixture = try await makeSession(
      sessionID: "session-source-truncate", jobID: "job-source-truncate")
    defer { try? FileManager.default.removeItem(at: truncateFixture.base) }
    let truncateSource = truncateFixture.base.appending(path: "truncate-source.bin")
    try Data(repeating: 0x42, count: 128 * 1_024).write(to: truncateSource)
    let truncateClaim = truncateFixture.claim
    let truncateStore = SessionArtifactStore(
      layout: truncateFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactSourceValidation else { return }
        guard Darwin.truncate(truncateSource.path, 16 * 1_024) == 0 else {
          throw SessionStorageError.writeFailed(path: truncateSource.path, errno: errno)
        }
      })
    XCTAssertThrowsError(
      try truncateStore.publish(
        from: truncateSource,
        request: ArtifactPublicationRequest(
          artifactID: "artifact-source-truncate", role: .raw,
          publicationName: "truncate.bin", origin: "concurrent truncate fixture"),
        claim: truncateClaim)
    ) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("source truncation was not rejected as unstable: \(error)")
      }
      XCTAssertTrue(message.contains("changed"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: truncateFixture.layout.rawDirectory.appending(path: "truncate.bin").path))

    let overwriteFixture = try await makeSession(
      sessionID: "session-source-overwrite", jobID: "job-source-overwrite")
    defer { try? FileManager.default.removeItem(at: overwriteFixture.base) }
    let overwriteSource = overwriteFixture.base.appending(path: "overwrite-source.bin")
    let originalBytes = Data(repeating: 0x43, count: 128 * 1_024)
    let replacementBytes = Data(repeating: 0x44, count: originalBytes.count)
    try originalBytes.write(to: overwriteSource)
    let overwriteClaim = overwriteFixture.claim
    let overwriteStore = SessionArtifactStore(
      layout: overwriteFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactSourceValidation else { return }
        let descriptor = Darwin.open(overwriteSource.path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
          throw SessionStorageError.writeFailed(path: overwriteSource.path, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        try replacementBytes.withUnsafeBytes { buffer in
          guard Darwin.pwrite(descriptor, buffer.baseAddress, buffer.count, 0) == buffer.count
          else {
            throw SessionStorageError.writeFailed(path: overwriteSource.path, errno: errno)
          }
        }
      })
    XCTAssertThrowsError(
      try overwriteStore.publish(
        from: overwriteSource,
        request: ArtifactPublicationRequest(
          artifactID: "artifact-source-overwrite", role: .raw,
          publicationName: "overwrite.bin", origin: "same-size overwrite fixture"),
        claim: overwriteClaim)
    ) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("source overwrite was not rejected as unstable: \(error)")
      }
      XCTAssertTrue(message.contains("changed"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: overwriteFixture.layout.rawDirectory.appending(path: "overwrite.bin").path))
  }

  func testSessionLayoutRequiresLiveSameJobSameVolumeClaimAndBindsIdentity() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try SessionStore(sessionsRoot: base.appending(path: "Sessions"))
    let date = Date(timeIntervalSince1970: 1_752_739_200)
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: "session-without-claim", jobID: "job-original", createdAt: date,
        claim: nil)
    ) { error in
      guard case SessionStorageError.claimUnavailable(let claimID) = error else {
        return XCTFail("Session creation without admission must fail closed: \(error)")
      }
      XCTAssertTrue(claimID.contains("missing-claim"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.sessionsRoot.appending(path: "2025/07/session-without-claim").path))

    let identity = try SystemVolumeIdentityResolver().resolve(store.sessionsRoot)
    let coordinator = HostStorageCoordinator()
    let creationRequest = try request(
      id: "claim-session-create", job: "job-original", volume: identity, writer: .light,
      metadata: 1_024, finalization: 1_024, growth: 1)
    guard
      case .admitted(let creationClaim) = await coordinator.admit(
        creationRequest,
        snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { return XCTFail("Session metadata claim must be admitted") }
    let layout = try store.createSession(
      sessionID: "session-exclusive", jobID: "job-original", createdAt: date,
      claim: creationClaim)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.identityURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.partialDirectory.path))
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: "session-second-root", jobID: "job-original", createdAt: date,
        claim: creationClaim)
    ) { error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("one claim created two Session roots: \(error)")
      }
      XCTAssertTrue(message.contains("already bound"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.sessionsRoot.appending(path: "2025/07/session-second-root").path))
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: "session-exclusive", jobID: "job-replacement", createdAt: date,
        claim: creationClaim))

    let existingRootCoordinator = HostStorageCoordinator()
    let existingRootRequest = try request(
      id: "claim-existing-session", job: "job-original", volume: identity, writer: .light,
      metadata: 1_024, finalization: 1_024, growth: 1)
    guard
      case .admitted(let existingRootClaim) = await existingRootCoordinator.admit(
        existingRootRequest,
        snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { return XCTFail("fresh existing-root claim must be admitted") }
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: layout.sessionID, jobID: layout.jobID, createdAt: date,
        claim: existingRootClaim)
    ) { error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("existing Session root escaped creation preflight: \(error)")
      }
      XCTAssertTrue(message.contains("already exists"))
    }
    let existingRootActive = await existingRootCoordinator.activeClaimCount(on: identity)
    let existingRootReserved = await existingRootCoordinator.reservedBytes(on: identity)
    XCTAssertEqual(existingRootActive, 0)
    XCTAssertEqual(existingRootReserved, 0)
    let existingRootWriteFailure = await existingRootCoordinator.reportWriteFailure(
      claimID: existingRootClaim.claimID, errno: ENOSPC)
    XCTAssertEqual(existingRootWriteFailure, .volumeUnavailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.manifestURL.path))
    XCTAssertNoThrow(
      try store.openSession(
        sessionID: "session-exclusive", jobID: "job-original", root: layout.root))
    XCTAssertThrowsError(
      try store.openSession(
        sessionID: "session-other", jobID: "job-original", root: layout.root))
    XCTAssertThrowsError(
      try store.openSession(
        sessionID: "session-exclusive", jobID: "job-replacement", root: layout.root))

    let escapedRoot = base.appending(path: "outside/session-exclusive")
    try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try store.openSession(
        sessionID: "session-exclusive", jobID: "job-original", root: escapedRoot))

    let symlinkRoot = store.sessionsRoot.appending(path: "2026/08/session-exclusive")
    try FileManager.default.createDirectory(
      at: symlinkRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: layout.root)
    XCTAssertThrowsError(
      try store.openSession(
        sessionID: "session-exclusive", jobID: "job-original", root: symlinkRoot))

    _ = await coordinator.reportWriteFailure(claimID: creationClaim.claimID, errno: ENOSPC)
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: "session-after-stop", jobID: "job-original", createdAt: date,
        claim: creationClaim)
    ) { error in
      guard case SessionStorageError.optionalWritesStopped = error else {
        return XCTFail("finalization-only permit created a new Session: \(error)")
      }
    }

    let otherVolume = try VolumeIdentity(value: identity.value + ":other")
    let otherCoordinator = HostStorageCoordinator()
    let otherRequest = try request(
      id: "claim-session-other-volume", job: "job-other-volume", volume: otherVolume,
      writer: .light)
    guard
      case .admitted(let otherClaim) = await otherCoordinator.admit(
        otherRequest,
        snapshot: storageSnapshot(identity: otherVolume, available: UInt64.max))
    else { return XCTFail("synthetic other-volume claim") }
    XCTAssertThrowsError(
      try store.createSession(
        sessionID: "session-wrong-volume", jobID: "job-other-volume", createdAt: date,
        claim: otherClaim)
    ) { error in
      guard case SessionStorageError.volumeIdentityChanged = error else {
        return XCTFail("wrong-volume claim created a Session: \(error)")
      }
    }
  }

  func testConcurrentSessionCreationReleasesLosingClaimHeadroom() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let sessionsRoot = base.appending(path: "Sessions")
    let initialStore = try SessionStore(sessionsRoot: sessionsRoot)
    let identity = try SystemVolumeIdentityResolver().resolve(initialStore.sessionsRoot)
    let coordinator = HostStorageCoordinator()
    let jobID = "job-session-create-race"
    let requestA = try request(
      id: "claim-session-create-a", job: jobID, volume: identity, writer: .light,
      metadata: 100, finalization: 100, growth: 1)
    let requestB = try request(
      id: "claim-session-create-b", job: jobID, volume: identity, writer: .light,
      metadata: 100, finalization: 100, growth: 1)
    guard
      case .admitted(let claimA) = await coordinator.admit(
        requestA, snapshot: storageSnapshot(identity: identity, available: UInt64.max)),
      case .admitted(let claimB) = await coordinator.admit(
        requestB, snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { return XCTFail("racing Session claims must be admitted") }

    let reachedRootCreate = DispatchSemaphore(value: 0)
    let allowRootCreate = DispatchSemaphore(value: 0)
    let finishedA = DispatchSemaphore(value: 0)
    let finishedB = DispatchSemaphore(value: 0)
    let resultA = SessionLayoutResultBox()
    let resultB = SessionLayoutResultBox()
    let raceFault = SessionStorageFaultInjector { point in
      guard point == .sessionBeforeRootCreate else { return }
      reachedRootCreate.signal()
      guard allowRootCreate.wait(timeout: .now() + 5) == .success else {
        throw StorageContractFault.operation
      }
    }
    let storeA = try SessionStore(sessionsRoot: sessionsRoot, faultInjector: raceFault)
    let storeB = try SessionStore(sessionsRoot: sessionsRoot, faultInjector: raceFault)
    let date = Date(timeIntervalSince1970: 1_752_739_200)

    DispatchQueue.global().async {
      resultA.store(
        Result {
          try storeA.createSession(
            sessionID: "session-create-race", jobID: jobID, createdAt: date,
            claim: claimA)
        })
      finishedA.signal()
    }
    DispatchQueue.global().async {
      resultB.store(
        Result {
          try storeB.createSession(
            sessionID: "session-create-race", jobID: jobID, createdAt: date,
            claim: claimB)
        })
      finishedB.signal()
    }
    let reachedA = await waitForSemaphore(reachedRootCreate)
    let reachedB = await waitForSemaphore(reachedRootCreate)
    guard reachedA == .success, reachedB == .success else {
      allowRootCreate.signal()
      allowRootCreate.signal()
      return XCTFail("both Session creators must pass the non-atomic ENOENT preflight")
    }
    allowRootCreate.signal()
    allowRootCreate.signal()
    let waitA = await waitForSemaphore(finishedA)
    let waitB = await waitForSemaphore(finishedB)
    XCTAssertEqual(waitA, .success)
    XCTAssertEqual(waitB, .success)

    let outcomeA = try XCTUnwrap(resultA.load())
    let outcomeB = try XCTUnwrap(resultB.load())
    let winner: (layout: SessionLayout, claim: StorageClaim)
    let loserError: Error
    switch (outcomeA, outcomeB) {
    case (.success(let layout), .failure(let error)):
      winner = (layout, claimA)
      loserError = error
    case (.failure(let error), .success(let layout)):
      winner = (layout, claimB)
      loserError = error
    default:
      return XCTFail("exactly one racing Session creator must win root mkdir")
    }
    guard case SessionStorageError.invalidRecord(let message) = loserError else {
      return XCTFail("racing root loser returned the wrong error: \(loserError)")
    }
    XCTAssertTrue(message.contains("already exists"))
    let activeAfterRace = await coordinator.activeClaimCount(on: identity)
    let reservedAfterRace = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(activeAfterRace, 1)
    XCTAssertEqual(reservedAfterRace, 201)

    let winnerFixture = SessionFixture(
      base: base, layout: winner.layout, coordinator: coordinator, claim: winner.claim)
    let terminal = try Self.terminalFinalization(
      fixture: winnerFixture, status: "failed", recordID: "session-create-race-terminal")
    _ = await coordinator.reportWriteFailure(
      claimID: winner.claim.claimID, errno: ENOSPC, terminalDisposition: .failed)
    let receipt = try terminal.finalizer.persist(
      claim: winner.claim, disposition: .failed,
      auditRecord: terminal.auditRecord, manifest: terminal.manifest)
    let release = try await coordinator.completeRecoveredFinalization(receipt)
    let activeAfterRelease = await coordinator.activeClaimCount(on: identity)
    let reservedAfterRelease = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(release, .releasedNow)
    XCTAssertEqual(activeAfterRelease, 0)
    XCTAssertEqual(reservedAfterRelease, 0)
  }

  func testSessionCreationRepairsOwnedRootAfterFaultsAndReleasesClaim() async throws {
    let faultPoints: [SessionStorageFaultPoint] = [
      .sessionRootCreated, .sessionIdentityFileSync, .sessionDirectorySync,
    ]
    for (index, faultPoint) in faultPoints.enumerated() {
      let base = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: base) }
      let sessionsRoot = base.appending(path: "Sessions")
      let identityStore = try SessionStore(sessionsRoot: sessionsRoot)
      let identity = try SystemVolumeIdentityResolver().resolve(identityStore.sessionsRoot)
      let coordinator = HostStorageCoordinator()
      let sessionID = "session-create-repair-\(index)"
      let jobID = "job-create-repair-\(index)"
      let claimRequest = try request(
        id: "claim-create-repair-\(index)", job: jobID, volume: identity,
        writer: .light, metadata: 100, finalization: 100, growth: 1)
      guard
        case .admitted(let claim) = await coordinator.admit(
          claimRequest, snapshot: storageSnapshot(identity: identity, available: UInt64.max))
      else { return XCTFail("repair fixture claim must be admitted") }
      var injected = false
      let failingStore = try SessionStore(
        sessionsRoot: sessionsRoot,
        faultInjector: SessionStorageFaultInjector { point in
          if point == faultPoint, !injected {
            injected = true
            throw StorageContractFault.injected(point.rawValue)
          }
        })
      let date = Date(timeIntervalSince1970: 1_752_739_200)
      XCTAssertThrowsError(
        try failingStore.createSession(
          sessionID: sessionID, jobID: jobID, createdAt: date, claim: claim))
      XCTAssertTrue(injected)
      let activeBeforeRepair = await coordinator.activeClaimCount(on: identity)
      let reservedBeforeRepair = await coordinator.reservedBytes(on: identity)
      XCTAssertEqual(activeBeforeRepair, 1)
      XCTAssertEqual(reservedBeforeRepair, 201)

      let repairStore = try SessionStore(sessionsRoot: sessionsRoot)
      if faultPoint == .sessionRootCreated {
        let ownedRoot = failingStore.sessionsRoot
          .appending(path: "2025/07", directoryHint: .isDirectory)
          .appending(path: sessionID, directoryHint: .isDirectory)
        let displacedRoot = ownedRoot.deletingLastPathComponent()
          .appending(path: "\(sessionID).owned", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: ownedRoot, to: displacedRoot)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        XCTAssertThrowsError(
          try repairStore.createSession(
            sessionID: sessionID, jobID: jobID, createdAt: date, claim: claim)
        ) { error in
          guard case SessionStorageError.invalidRecord(let message) = error else {
            return XCTFail("replacement root was not rejected: \(error)")
          }
          XCTAssertTrue(message.contains("root identity"))
        }
        try FileManager.default.removeItem(at: ownedRoot)
        try FileManager.default.moveItem(at: displacedRoot, to: ownedRoot)
      }
      let repairedLayout = try repairStore.createSession(
        sessionID: sessionID, jobID: jobID, createdAt: date, claim: claim)
      XCTAssertNoThrow(
        try repairStore.openSession(
          sessionID: sessionID, jobID: jobID, root: repairedLayout.root))

      let fixture = SessionFixture(
        base: base, layout: repairedLayout, coordinator: coordinator, claim: claim)
      let terminal = try Self.terminalFinalization(
        fixture: fixture, status: "failed", recordID: "repair-terminal-\(index)")
      _ = await coordinator.reportWriteFailure(
        claimID: claim.claimID, errno: ENOSPC, terminalDisposition: .failed)
      let receipt = try terminal.finalizer.persist(
        claim: claim, disposition: .failed,
        auditRecord: terminal.auditRecord, manifest: terminal.manifest)
      let release = try await coordinator.completeRecoveredFinalization(receipt)
      let activeAfterRelease = await coordinator.activeClaimCount(on: identity)
      let reservedAfterRelease = await coordinator.reservedBytes(on: identity)
      XCTAssertEqual(release, .releasedNow)
      XCTAssertEqual(activeAfterRelease, 0)
      XCTAssertEqual(reservedAfterRelease, 0)
    }
  }

  func testManifestWholeGraphRelationshipsFailClosedBeforePublication() throws {
    let descriptor = try compensationDescriptor(
      id: "compensation-stop", kind: "stopRemoteCapture", effect: "deviceMutation",
      cancellation: "atSafeBoundary", bindingRequirement: "confirmedDevice",
      trigger: "onFailure",
      arguments: [
        "captureStepId": .string("step-source"), "stopPolicy": .string("safe-stop"),
      ])
    let sourceStep = try executionStep(
      id: "step-source", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], compensationDescriptors: [descriptor])
    let boundStep = try executionStep(
      id: "step-bound", kind: "probeDevice", effect: "readOnly",
      cancellation: "immediate", bindingRequirement: "confirmedDevice",
      arguments: ["evidencePolicy": .string("fixture-evidence")])
    let compensation: JSONValue = .object([
      "descriptor": descriptor,
      "sourceStepId": .string("step-source"),
      "disposition": .string("notRun"),
      "outcomeCertainty": .string("notApplicable"),
      "result": .string("notRun"),
      "failure": .null,
      "journalEventIds": .array([]),
    ])
    let confirmation: JSONValue = .object([
      "confirmationId": .string("confirmation-graph"),
      "kind": .string("deviceMutation"),
      "scopeHash": .string(SessionStorageFixtures.scopeHash),
      "decision": .string("accepted"),
      "actor": .string("user"),
      "decidedAt": .string(SessionStorageFixtures.timestamp),
      "relatedStepIds": .array([.string("step-bound")]),
    ])
    let raw = try ArtifactRecord(
      id: "artifact-source", role: .raw, origin: "fixture",
      relativePath: "artifacts/raw/source.bin", size: 1,
      sha256: String(repeating: "1", count: 64))
    let derivedProvenance = try DerivedArtifactProvenance(
      operation: "fixture-filter", inputHashes: [raw.sha256],
      parameters: ["filter": "fixture"], statistics: ["removedRecords": 1])
    let derived = try ArtifactRecord(
      id: "artifact-derived", role: .derived, origin: derivedProvenance.manifestOrigin(),
      relativePath: "artifacts/derived/derived.bin", size: 1,
      sha256: String(repeating: "2", count: 64), derivedFrom: [raw.id])
    let restoredParameter: JSONValue = .object([
      "name": .string("persist.fixture"),
      "beforeState": .object(["state": .string("value"), "value": .string("original")]),
      "desiredState": .object(["state": .string("value"), "value": .string("changed")]),
      "afterState": .object(["state": .string("value"), "value": .string("changed")]),
      "restoreState": .object(["state": .string("value"), "value": .string("original")]),
      "restoreDisposition": .string("restored"),
    ])
    let valid = try SessionStorageFixtures.manifest(
      steps: [sourceStep, boundStep], parameters: [restoredParameter],
      compensations: [compensation], artifacts: [raw, derived],
      confirmations: [confirmation])
    XCTAssertNoThrow(try SessionManifestDocument(data: valid))

    let confirmationStep = try executionStep(
      id: "step-confirmation-reference", kind: "requestConfirmation", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none",
      arguments: [
        "confirmationId": .string("confirmation-step-reference"),
        "promptKey": .string("confirm-fixture"),
        "riskClass": .string("deviceMutation"),
        "scopeHash": .string(SessionStorageFixtures.scopeHash),
      ])
    let matchingStepConfirmation: JSONValue = .object([
      "confirmationId": .string("confirmation-step-reference"),
      "kind": .string("deviceMutation"),
      "scopeHash": .string(SessionStorageFixtures.scopeHash),
      "decision": .string("accepted"), "actor": .string("user"),
      "decidedAt": .string(SessionStorageFixtures.timestamp),
      "relatedStepIds": .array([.string("step-confirmation-reference")]),
    ])
    XCTAssertNoThrow(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [confirmationStep], confirmations: [matchingStepConfirmation])))
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(steps: [confirmationStep], confirmations: []))
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("missing confirmation returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("confirmationId does not resolve"))
    }
    var mismatchedStepConfirmation = matchingStepConfirmation
    if case .object(var object) = mismatchedStepConfirmation {
      object["relatedStepIds"] = .array([.string("step-source")])
      mismatchedStepConfirmation = .object(object)
    }
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep, confirmationStep], confirmations: [mismatchedStepConfirmation]))
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("mismatched confirmation returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("confirmationId does not resolve"))
    }

    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep, sourceStep], confirmations: [])))
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(artifacts: [raw, raw], confirmations: [])))
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep, boundStep], confirmations: [confirmation, confirmation])))
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep], compensations: [compensation, compensation],
          confirmations: [])))

    let compensationFailure: JSONValue = .object([
      "stage": .string("compensation"), "code": .string("fixture.failed"),
      "summary": .string("fixture compensation failed"),
    ])
    let invalidCompensationTuples: [(String, String, String, JSONValue)] = [
      ("executed", "notApplicable", "succeeded", .null),
      ("executed", "confirmed", "notRun", .null),
      ("executed", "confirmed", "succeeded", compensationFailure),
      ("notRun", "notApplicable", "succeeded", .null),
      ("notRun", "confirmed", "failed", compensationFailure),
      ("outcomeUnknown", "confirmed", "unknown", .null),
      ("outcomeUnknown", "outcomeUnknown", "failed", compensationFailure),
    ]
    for (disposition, certainty, result, compensationFailure) in invalidCompensationTuples {
      guard case .object(var invalidCompensation) = compensation else {
        return XCTFail("compensation fixture must be an object")
      }
      invalidCompensation["disposition"] = .string(disposition)
      invalidCompensation["outcomeCertainty"] = .string(certainty)
      invalidCompensation["result"] = .string(result)
      invalidCompensation["failure"] = compensationFailure
      XCTAssertThrowsError(
        try SessionManifestDocument(
          data: SessionStorageFixtures.manifest(
            steps: [sourceStep], compensations: [.object(invalidCompensation)],
            confirmations: []))
      ) { error in
        guard case SessionStorageError.invalidManifest(let message) = error else {
          return XCTFail("invalid compensation tuple returned the wrong error: \(error)")
        }
        XCTAssertTrue(message.contains("compensation") && message.contains("tuple"))
      }
    }

    var descendingBindings = try jsonObject(valid)
    var binding = try XCTUnwrap(
      (descendingBindings["bindingHistory"] as? [[String: Any]])?.first)
    binding["revision"] = 2
    var olderBinding = binding
    olderBinding["revision"] = 1
    descendingBindings["bindingHistory"] = [binding, olderBinding]
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: try JSONSerialization.data(withJSONObject: descendingBindings)))

    var missingBinding = try jsonObject(valid)
    var missingBindingSteps = try XCTUnwrap(missingBinding["steps"] as? [[String: Any]])
    missingBindingSteps[1]["bindingRevision"] = 2
    missingBinding["steps"] = missingBindingSteps
    XCTAssertThrowsError(
      try SessionManifestDocument(data: try JSONSerialization.data(withJSONObject: missingBinding)))

    var unknownConfirmationStep = confirmation
    if case .object(var object) = unknownConfirmationStep {
      object["relatedStepIds"] = .array([.string("step-missing")])
      unknownConfirmationStep = .object(object)
    }
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep, boundStep], confirmations: [unknownConfirmationStep])))

    let danglingProvenance = try DerivedArtifactProvenance(
      operation: "fixture-filter", inputHashes: [String(repeating: "4", count: 64)],
      parameters: ["filter": "fixture"], statistics: ["removedRecords": 1])
    let danglingDerived = try ArtifactRecord(
      id: "artifact-dangling", role: .derived, origin: danglingProvenance.manifestOrigin(),
      relativePath: "artifacts/derived/dangling.bin", size: 1,
      sha256: String(repeating: "3", count: 64), derivedFrom: ["artifact-missing"])
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          artifacts: [danglingDerived], confirmations: [])))

    let wrongHashProvenance = try DerivedArtifactProvenance(
      operation: "fixture-filter", inputHashes: [String(repeating: "9", count: 64)],
      parameters: ["filter": "fixture"], statistics: ["removedRecords": 1])
    let wrongHashDerived = try ArtifactRecord(
      id: "artifact-wrong-source-hash", role: .derived,
      origin: wrongHashProvenance.manifestOrigin(),
      relativePath: "artifacts/derived/wrong-source-hash.bin", size: 1,
      sha256: String(repeating: "8", count: 64), derivedFrom: [raw.id])
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          artifacts: [raw, wrongHashDerived], confirmations: [])))

    let cycleAHash = String(repeating: "a", count: 64)
    let cycleBHash = String(repeating: "b", count: 64)
    let cycleAProvenance = try DerivedArtifactProvenance(
      operation: "cycle-a", inputHashes: [cycleBHash],
      parameters: ["filter": "fixture"], statistics: ["removedRecords": 0])
    let cycleBProvenance = try DerivedArtifactProvenance(
      operation: "cycle-b", inputHashes: [cycleAHash],
      parameters: ["filter": "fixture"], statistics: ["removedRecords": 0])
    let cycleA = try ArtifactRecord(
      id: "artifact-cycle-a", role: .derived, origin: cycleAProvenance.manifestOrigin(),
      relativePath: "artifacts/derived/cycle-a.bin", size: 1, sha256: cycleAHash,
      derivedFrom: ["artifact-cycle-b"])
    let cycleB = try ArtifactRecord(
      id: "artifact-cycle-b", role: .derived, origin: cycleBProvenance.manifestOrigin(),
      relativePath: "artifacts/derived/cycle-b.bin", size: 1, sha256: cycleBHash,
      derivedFrom: ["artifact-cycle-a"])
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          artifacts: [cycleA, cycleB], confirmations: [])))

    var missingCompensationSource = compensation
    if case .object(var object) = missingCompensationSource {
      object["sourceStepId"] = .string("step-missing")
      missingCompensationSource = .object(object)
    }
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [sourceStep], compensations: [missingCompensationSource],
          confirmations: [])))

    var mismatchedRestore = restoredParameter
    if case .object(var object) = mismatchedRestore {
      object["restoreState"] = .object([
        "state": .string("value"), "value": .string("not-original"),
      ])
      mismatchedRestore = .object(object)
    }
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          parameters: [mismatchedRestore], confirmations: [])))
  }

  func testManifestPublicationPreservesOutcomeUnknownAcrossGenericReconcile()
    async throws
  {
    let ghostFixture = try await makeSession(
      sessionID: "session-ghost-journal", jobID: "job-ghost-journal")
    defer { try? FileManager.default.removeItem(at: ghostFixture.base) }
    let ghostDescriptor = try compensationDescriptor(
      id: "compensation-ghost-journal", kind: "stopRemoteCapture",
      effect: "deviceMutation", cancellation: "atSafeBoundary",
      bindingRequirement: "confirmedDevice", trigger: "onFailure",
      arguments: [
        "captureStepId": .string("step-ghost-source"),
        "stopPolicy": .string("safe-stop"),
      ])
    let ghostSource = try executionStep(
      id: "step-ghost-source", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string(ghostFixture.layout.sessionID),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], compensationDescriptors: [ghostDescriptor])
    let ghostCompensation: JSONValue = .object([
      "descriptor": ghostDescriptor,
      "sourceStepId": .string("step-ghost-source"),
      "disposition": .string("notRun"),
      "outcomeCertainty": .string("notApplicable"),
      "result": .string("notRun"), "failure": .null,
      "journalEventIds": .array([.string("ghost-journal-event")]),
    ])
    let ghostManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: ghostFixture.layout.sessionID, jobID: ghostFixture.layout.jobID,
        steps: [ghostSource], compensations: [ghostCompensation]))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: ghostFixture.layout).publish(ghostManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("ghost journal reference returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("ghost or mismatched compensation journalEventId"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: ghostFixture.layout.manifestURL.path))

    let reconcileFixture = try await makeSession(
      sessionID: "session-journal-reconcile", jobID: "job-journal-reconcile")
    defer { try? FileManager.default.removeItem(at: reconcileFixture.base) }
    let arguments: [String: JSONValue] = [
      "toolIdentity": .string("fixture-tool"),
      "candidatePath": .string("/fixture/tool"),
      "expectedSha256": .string(String(repeating: "c", count: 64)),
    ]
    let execution = try executionStep(
      id: "step-journal-reconcile", kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: arguments,
      disposition: "executed", outcomeCertainty: "confirmed", semanticResult: "failed")
    let workflowStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(
      canonicalData(
        .object([
          "id": .string("step-journal-reconcile"),
          "kind": .string("probeHostTool"), "effect": .string("hostOnly"),
          "cancellation": .string("immediate"),
          "bindingRequirement": .string("none"),
          "arguments": .object(arguments), "compensationDescriptors": .array([]),
        ])))
    let confirmedManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        status: "failed", steps: [execution]))
    let journal = try FileDurableJournal(url: reconcileFixture.layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "reconcile-created", sequence: 0,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "reconcile-preflight", sequence: 1,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .queued, to: .preflight,
        reason: "journal contract fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "reconcile-running", sequence: 2,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .preflight, to: .running,
        reason: "journal contract fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "reconcile-step-intent", sequence: 3,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, step: workflowStep,
        target: JournalTarget(
          scope: "host", targetID: "fixture-host", connectKey: nil,
          identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "reconcile-step-unknown", sequence: 4,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, stepID: workflowStep.id, attempt: 1,
        correlatesToIntentEventID: "reconcile-step-intent", result: "failed",
        outcomeCertainty: .outcomeUnknown))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "reconcile-waiting", sequence: 5,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .running,
        to: .waitingForRecovery, reason: "outcome is unknown"))

    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: reconcileFixture.layout).publish(
        confirmedManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("outcomeUnknown journal returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("cannot resolve durable outcomeUnknown"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: reconcileFixture.layout.manifestURL.path))

    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "reconcile-entered", sequence: 6,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .waitingForRecovery,
        to: .reconciling, reason: "provider recovery"))
    let genericReconcileStart = try JournalEvent.reconcileStarted(
      eventID: "reconcile-started", sequence: 7,
      sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
      timestamp: SessionStorageFixtures.timestamp, recoveryAttemptID: "reconcile-attempt",
      sourceState: .waitingForRecovery, lastDurableSequence: 0,
      trigger: "providerRecovery")
    try journal.appendAndSynchronize(genericReconcileStart)
    try journal.appendAndSynchronize(
      JournalEvent.reconcileOutcome(
        eventID: "reconcile-confirmed", sequence: 8,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, bindingRevision: 1,
        recoveryAttemptID: "reconcile-attempt", result: "finalizeConfirmedFailure",
        nextState: .finalizing, outcomeCertainty: .confirmed,
        safeBoundaryConfirmed: true, evidence: ["provider", "binding"]))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "reconcile-finalizing", sequence: 9,
        sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .reconciling, to: .finalizing,
        reason: "confirmed failure", triggerEventID: "reconcile-confirmed"))

    let replayAfterGenericReconcile = try DurableJournalRecovery.inspect(
      url: reconcileFixture.layout.journalURL)
    XCTAssertEqual(replayAfterGenericReconcile.currentState, .finalizing)
    XCTAssertEqual(replayAfterGenericReconcile.unknownOutcomes.count, 1)
    XCTAssertTrue(replayAfterGenericReconcile.requiresRecovery)

    XCTAssertThrowsError(
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "reconcile-failed", sequence: 10,
          sessionID: reconcileFixture.layout.sessionID, jobID: reconcileFixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: .finalizing, to: .failed,
          reason: "generic reconcile must not confirm an unknown outcome"))
    ) { error in
      guard case DurableFileError.sequenceViolation(let message) = error else {
        return XCTFail("generic reconcile terminalization returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("outcomeUnknown"))
    }
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: reconcileFixture.layout).publish(
        confirmedManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("generic reconcile Manifest returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("cannot resolve durable outcomeUnknown"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: reconcileFixture.layout.manifestURL.path))
  }

  func testManifestPublicationBindsJournalAuthorityBaselineTypedStepAndBindingIdentity()
    async throws
  {
    let authorityCases = [
      ("authority", "controlledHardwareLab", "CORE-2.0.0"),
      ("baseline", "interactiveUser", "CORE-9.9.9"),
    ]
    for (suffix, journalAuthority, journalBaseline) in authorityCases {
      let fixture = try await makeSession(
        sessionID: "session-journal-\(suffix)-mismatch",
        jobID: "job-journal-\(suffix)-mismatch")
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let manifest = try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          status: "failed", executionMode: "execute",
          executionAuthority: "interactiveUser"))
      try appendTerminalJournal(
        layout: fixture.layout, manifest: manifest, prefix: "journal-\(suffix)-mismatch",
        executionMode: "execute", executionAuthority: journalAuthority,
        coreBaseline: journalBaseline, terminalState: .failed
      ) { _, _ in }

      XCTAssertThrowsError(
        try AtomicSessionManifestPublisher(layout: fixture.layout).publish(manifest)
      ) { error in
        guard case SessionStorageError.invalidManifest(let message) = error else {
          return XCTFail("journal \(suffix) mismatch returned the wrong error: \(error)")
        }
        XCTAssertTrue(
          message.contains("executionAuthority/coreBaseline does not match Manifest"))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    }

    let validBinding: [String: JSONValue] = [
      "connectKey": .string("fixture-device"),
      "transport": .string("usb"),
      "identitySnapshot": .object(["serial": .string("fixture-serial")]),
      "evidence": .array([.string("fixture-binding")]),
      "confirmedBy": .string("user"),
      "channelProtection": .string("encryptedVerified"),
    ]
    var changedConnectKey = validBinding
    changedConnectKey["connectKey"] = .string("replacement-device")
    var changedIdentity = validBinding
    changedIdentity["identitySnapshot"] = .object(["serial": .string("replacement-serial")])
    var changedEvidence = validBinding
    changedEvidence["evidence"] = .array([.string("replacement-evidence")])
    for (suffix, journalBinding) in [
      ("connect-key", changedConnectKey),
      ("identity", changedIdentity),
      ("evidence", changedEvidence),
    ] {
      let fixture = try await makeSession(
        sessionID: "session-journal-binding-\(suffix)",
        jobID: "job-journal-binding-\(suffix)")
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let manifest = try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          status: "failed", executionMode: "execute",
          executionAuthority: "interactiveUser"))
      try appendTerminalJournal(
        layout: fixture.layout, manifest: manifest, prefix: "journal-binding-\(suffix)",
        executionMode: "execute", executionAuthority: "interactiveUser",
        terminalState: .failed
      ) { journal, sequence in
        try journal.appendAndSynchronize(
          JournalEvent(
            eventID: "journal-binding-\(suffix)-confirmed", sequence: sequence,
            sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
            timestamp: SessionStorageFixtures.timestamp, kind: .bindingConfirmed,
            bindingRevision: 1,
            payload: [
              "candidateEventId": .string("journal-binding-\(suffix)-candidate"),
              "binding": .object(journalBinding),
            ]))
        sequence += 1
      }

      XCTAssertThrowsError(
        try AtomicSessionManifestPublisher(layout: fixture.layout).publish(manifest)
      ) { error in
        guard case SessionStorageError.invalidManifest(let message) = error else {
          return XCTFail("journal binding \(suffix) mismatch returned the wrong error: \(error)")
        }
        XCTAssertTrue(message.contains("confirmed binding does not match Manifest"))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    }

    let stepArguments: [String: JSONValue] = [
      "toolIdentity": .string("fixture-tool"),
      "candidatePath": .string("/fixture/tool"),
      "expectedSha256": .string(String(repeating: "c", count: 64)),
    ]
    let journalDescriptor = try compensationDescriptor(
      id: "journal-step-compensation", kind: "stopRemoteCapture",
      effect: "deviceMutation", cancellation: "atSafeBoundary",
      bindingRequirement: "confirmedDevice", trigger: "onFailure",
      arguments: [
        "captureStepId": .string("journal-step"),
        "stopPolicy": .string("safe-stop"),
      ])
    let stepCases: [(String, String, String, [JSONValue], [JSONValue])] = [
      ("effect", "readOnly", "immediate", [], []),
      ("cancellation", "hostOnly", "atSafeBoundary", [], []),
      ("compensations", "hostOnly", "immediate", [journalDescriptor], []),
    ]
    for (suffix, manifestEffect, manifestCancellation, journalDescriptors, manifestDescriptors)
      in stepCases
    {
      let fixture = try await makeSession(
        sessionID: "session-journal-step-\(suffix)", jobID: "job-journal-step-\(suffix)")
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let workflowStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(
        canonicalData(
          .object([
            "id": .string("journal-step"), "kind": .string("probeHostTool"),
            "effect": .string("hostOnly"), "cancellation": .string("immediate"),
            "bindingRequirement": .string("none"), "arguments": .object(stepArguments),
            "compensationDescriptors": .array(journalDescriptors),
          ])))
      let manifestStep = try executionStep(
        id: workflowStep.id, kind: "probeHostTool", effect: manifestEffect,
        cancellation: manifestCancellation, bindingRequirement: "none",
        arguments: stepArguments, compensationDescriptors: manifestDescriptors,
        disposition: "executed", outcomeCertainty: "confirmed",
        semanticResult: "succeeded")
      let manifest = try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
          steps: [manifestStep]))
      try appendTerminalJournal(
        layout: fixture.layout, manifest: manifest, prefix: "journal-step-\(suffix)",
        executionMode: "simulated", terminalState: .succeeded
      ) { journal, sequence in
        let intentID = "journal-step-\(suffix)-intent"
        try journal.appendAndSynchronize(
          JournalEvent.stepIntent(
            eventID: intentID, sequence: sequence,
            sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
            timestamp: SessionStorageFixtures.timestamp, step: workflowStep,
            target: JournalTarget(
              scope: "host", targetID: "fixture-host", connectKey: nil,
              identitySnapshotHash: nil),
            attempt: 1, bindingRevision: nil))
        sequence += 1
        try journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "journal-step-\(suffix)-outcome", sequence: sequence,
            sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
            timestamp: SessionStorageFixtures.timestamp, stepID: workflowStep.id, attempt: 1,
            correlatesToIntentEventID: intentID, result: "succeeded",
            outcomeCertainty: .confirmed))
        sequence += 1
      }

      XCTAssertThrowsError(
        try AtomicSessionManifestPublisher(layout: fixture.layout).publish(manifest)
      ) { error in
        guard case SessionStorageError.invalidManifest(let message) = error else {
          return XCTFail("journal Step \(suffix) mismatch returned the wrong error: \(error)")
        }
        XCTAssertTrue(message.contains("Step intent declaration does not correlate"))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    }
  }

  func testManifestPublicationRejectsJournalOutcomeExecutionTupleMismatch() async throws {
    let failedFixture = try await makeSession(
      sessionID: "session-journal-failed-tuple", jobID: "job-journal-failed-tuple")
    defer { try? FileManager.default.removeItem(at: failedFixture.base) }
    let failedArguments: [String: JSONValue] = [
      "toolIdentity": .string("fixture-tool"),
      "candidatePath": .string("/fixture/tool"),
      "expectedSha256": .string(String(repeating: "c", count: 64)),
    ]
    let failedWorkflowStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(
      canonicalData(
        .object([
          "id": .string("step-journal-failed-tuple"),
          "kind": .string("probeHostTool"), "effect": .string("hostOnly"),
          "cancellation": .string("immediate"),
          "bindingRequirement": .string("none"),
          "arguments": .object(failedArguments), "compensationDescriptors": .array([]),
        ])))
    let forgedSucceededStep = try executionStep(
      id: failedWorkflowStep.id, kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: failedArguments,
      disposition: "executed", outcomeCertainty: "confirmed", semanticResult: "succeeded")
    let forgedSucceededManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
        status: "failed", steps: [forgedSucceededStep]))
    let failedJournal = try FileDurableJournal(url: failedFixture.layout.journalURL)
    try failedJournal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "failed-tuple-created", sequence: 0,
        sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))
    for (eventID, sequence, from, to) in [
      ("failed-tuple-preflight", 1, JobState.queued, JobState.preflight),
      ("failed-tuple-running", 2, JobState.preflight, JobState.running),
    ] {
      try failedJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence,
          sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: from, to: to,
          reason: "journal outcome tuple fixture"))
    }
    try failedJournal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "failed-tuple-intent", sequence: 3,
        sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, step: failedWorkflowStep,
        target: JournalTarget(
          scope: "host", targetID: "fixture-host", connectKey: nil,
          identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try failedJournal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "failed-tuple-outcome", sequence: 4,
        sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, stepID: failedWorkflowStep.id, attempt: 1,
        correlatesToIntentEventID: "failed-tuple-intent", result: "failed",
        outcomeCertainty: .confirmed))
    for (eventID, sequence, from, to) in [
      ("failed-tuple-finalizing", 5, JobState.running, JobState.finalizing),
      ("failed-tuple-terminal", 6, JobState.finalizing, JobState.failed),
    ] {
      try failedJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence,
          sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: from, to: to,
          reason: "journal outcome tuple fixture"))
    }
    try failedJournal.appendAndSynchronize(
      JournalEvent(
        eventID: "failed-tuple-finalized", sequence: 7,
        sessionID: failedFixture.layout.sessionID, jobID: failedFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .finalized,
        payload: [
          "terminalStatus": .string("failed"),
          "manifestSha256": .string(forgedSucceededManifest.sha256),
          "outcomeCertainty": .string("confirmed"),
        ]))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: failedFixture.layout).publish(
        forgedSucceededManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("journal failed/Manifest succeeded returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("outcome does not match Manifest execution tuple"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: failedFixture.layout.manifestURL.path))

    let unknownFixture = try await makeSession(
      sessionID: "session-journal-confirmed-tuple", jobID: "job-journal-confirmed-tuple")
    defer { try? FileManager.default.removeItem(at: unknownFixture.base) }
    let unknownDescriptor = try compensationDescriptor(
      id: "compensation-journal-confirmed-tuple", kind: "stopRemoteCapture",
      effect: "deviceMutation", cancellation: "atSafeBoundary",
      bindingRequirement: "confirmedDevice", trigger: "onFailure",
      arguments: [
        "captureStepId": .string("step-journal-confirmed-tuple"),
        "stopPolicy": .string("safe-stop"),
      ])
    let confirmedWorkflowStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(
      canonicalData(
        .object([
          "id": .string("step-journal-confirmed-tuple"),
          "kind": .string("probeHostTool"), "effect": .string("hostOnly"),
          "cancellation": .string("immediate"),
          "bindingRequirement": .string("none"),
          "arguments": .object(failedArguments),
          "compensationDescriptors": .array([unknownDescriptor]),
        ])))
    let forgedUnknownStep = try executionStep(
      id: confirmedWorkflowStep.id, kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: failedArguments,
      compensationDescriptors: [unknownDescriptor], disposition: "outcomeUnknown",
      outcomeCertainty: "outcomeUnknown", semanticResult: "unknown")
    let unknownCompensation: JSONValue = .object([
      "descriptor": unknownDescriptor,
      "sourceStepId": .string(confirmedWorkflowStep.id),
      "disposition": .string("outcomeUnknown"),
      "outcomeCertainty": .string("outcomeUnknown"),
      "result": .string("unknown"), "failure": .null,
      "journalEventIds": .array([]),
    ])
    let abandonIntentID = "confirmed-tuple-abandon-intent"
    let abandonOutcomeID = "confirmed-tuple-abandon-outcome"
    let abandonConfirmationID = "confirmed-tuple-abandon-confirmation"
    let recovery: JSONValue = .object([
      "needsAttention": .bool(true),
      "interruptedReason": .string("fixture interruption"),
      "deviceHazards": .array([]),
      "abandonAuditEventIds": .array([
        .string(abandonIntentID), .string(abandonOutcomeID),
      ]),
      "lastConfirmedStepId": .string(confirmedWorkflowStep.id),
      "lastDeviceMode": .object(["state": .string("unknown")]),
      "managedHostProcessState": .string("notRunning"),
      "recoveryGuide": .object([
        "providerIdentity": .string("fixture-provider"),
        "automaticRecoveryAvailable": .bool(false),
        "summary": .string("inspect interrupted fixture"),
        "steps": .array([.string("inspect fixture state")]),
      ]),
      "unexecutedCompensations": .array([]),
      "userConfirmation": .object([
        "confirmationId": .string(abandonConfirmationID),
        "actor": .string("user"), "decision": .string("archiveInterrupted"),
        "confirmedAt": .string(SessionStorageFixtures.timestamp),
      ]),
      "recoveryOfSessionId": .string(unknownFixture.layout.sessionID),
      "recoveryOfJobId": .string(unknownFixture.layout.jobID),
    ])
    let interruptedData = try SessionStorageFixtures.manifest(
      sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
      status: "interrupted", executionAuthority: "interactiveUser",
      steps: [forgedUnknownStep], compensations: [unknownCompensation], recovery: recovery)
    guard
      case .object(var interruptedRoot) = try JSONDecoder().decode(
        JSONValue.self, from: interruptedData)
    else { return XCTFail("interrupted manifest fixture must be an object") }
    interruptedRoot["outcomeCertainty"] = .string("outcomeUnknown")
    let forgedUnknownManifest = try SessionManifestDocument(
      data: canonicalData(.object(interruptedRoot)))
    let confirmedJournal = try FileDurableJournal(url: unknownFixture.layout.journalURL)
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "confirmed-tuple-created", sequence: 0,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated",
        executionAuthority: "interactiveUser"))
    for (eventID, sequence, from, to) in [
      ("confirmed-tuple-preflight", 1, JobState.queued, JobState.preflight),
      ("confirmed-tuple-running", 2, JobState.preflight, JobState.running),
    ] {
      try confirmedJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence,
          sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: from, to: to,
          reason: "journal outcome tuple fixture"))
    }
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "confirmed-tuple-intent", sequence: 3,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, step: confirmedWorkflowStep,
        target: JournalTarget(
          scope: "host", targetID: "fixture-host", connectKey: nil,
          identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "confirmed-tuple-outcome", sequence: 4,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, stepID: confirmedWorkflowStep.id, attempt: 1,
        correlatesToIntentEventID: "confirmed-tuple-intent", result: "succeeded",
        outcomeCertainty: .confirmed))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "confirmed-tuple-waiting", sequence: 5,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .running, to: .waitingForRecovery,
        reason: "fixture interruption"))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.abandonIntent(
        eventID: abandonIntentID, sequence: 6,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        userConfirmationID: abandonConfirmationID, lastConfirmedStep: confirmedWorkflowStep.id,
        outcomeCertainty: .outcomeUnknown, managedProcessState: "notRunning", deviceHazards: []))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "confirmed-tuple-abandon-requested", sequence: 7,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .waitingForRecovery,
        to: .userAbandonRequested, reason: "user confirmed abandonment",
        triggerEventID: abandonIntentID))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.abandonOutcome(
        eventID: abandonOutcomeID, sequence: 8,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        correlatesToAbandonIntentEventID: abandonIntentID, result: "archivedInterrupted",
        releaseAuthorized: true, unresolvedHazards: []))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "confirmed-tuple-interrupted", sequence: 9,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .userAbandonRequested,
        to: .interrupted, reason: "abandonment persisted", triggerEventID: abandonOutcomeID))
    try confirmedJournal.appendAndSynchronize(
      JournalEvent(
        eventID: "confirmed-tuple-finalized", sequence: 10,
        sessionID: unknownFixture.layout.sessionID, jobID: unknownFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .finalized,
        payload: [
          "terminalStatus": .string("interrupted"),
          "manifestSha256": .string(forgedUnknownManifest.sha256),
          "outcomeCertainty": .string("outcomeUnknown"),
        ]))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: unknownFixture.layout).publish(
        forgedUnknownManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("journal confirmed/Manifest unknown returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("outcome does not match Manifest execution tuple"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: unknownFixture.layout.manifestURL.path))
  }

  func testManifestPublicationUsesLatestAttemptAndRequiresReverseDurableBacking() async throws {
    func interruptedRecovery(
      sessionID: String,
      jobID: String,
      prefix: String,
      lastConfirmedStepID: String?
    ) -> JSONValue {
      .object([
        "needsAttention": .bool(true),
        "interruptedReason": .string("fixture interruption"),
        "deviceHazards": .array([]),
        "abandonAuditEventIds": .array([
          .string("\(prefix)-abandon-intent"), .string("\(prefix)-abandon-outcome"),
        ]),
        "lastConfirmedStepId": lastConfirmedStepID.map(JSONValue.string) ?? .null,
        "lastDeviceMode": .object(["state": .string("unknown")]),
        "managedHostProcessState": .string("notRunning"),
        "recoveryGuide": .object([
          "providerIdentity": .string("fixture-provider"),
          "automaticRecoveryAvailable": .bool(false),
          "summary": .string("inspect interrupted fixture"),
          "steps": .array([.string("inspect fixture state")]),
        ]),
        "unexecutedCompensations": .array([]),
        "userConfirmation": .object([
          "confirmationId": .string("\(prefix)-confirmation"),
          "actor": .string("user"), "decision": .string("archiveInterrupted"),
          "confirmedAt": .string(SessionStorageFixtures.timestamp),
        ]),
        "recoveryOfSessionId": .string(sessionID),
        "recoveryOfJobId": .string(jobID),
      ])
    }

    let latestFixture = try await makeSession(
      sessionID: "session-journal-latest-attempt", jobID: "job-journal-latest-attempt")
    defer { try? FileManager.default.removeItem(at: latestFixture.base) }
    let arguments: [String: JSONValue] = [
      "toolIdentity": .string("fixture-tool"),
      "candidatePath": .string("/fixture/tool"),
      "expectedSha256": .string(String(repeating: "c", count: 64)),
    ]
    let workflowStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(
      canonicalData(
        .object([
          "id": .string("step-journal-latest-attempt"),
          "kind": .string("probeHostTool"), "effect": .string("hostOnly"),
          "cancellation": .string("immediate"), "bindingRequirement": .string("none"),
          "arguments": .object(arguments), "compensationDescriptors": .array([]),
        ])))
    let forgedSucceededStep = try executionStep(
      id: workflowStep.id, kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: arguments,
      disposition: "executed", outcomeCertainty: "confirmed", semanticResult: "succeeded")
    let latestPrefix = "latest-attempt"
    let latestManifestData = try SessionStorageFixtures.manifest(
      sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
      status: "interrupted", steps: [forgedSucceededStep],
      recovery: interruptedRecovery(
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        prefix: latestPrefix, lastConfirmedStepID: workflowStep.id))
    guard
      case .object(var latestManifestRoot) = try JSONDecoder().decode(
        JSONValue.self, from: latestManifestData)
    else { return XCTFail("latest-attempt Manifest fixture must be an object") }
    latestManifestRoot["outcomeCertainty"] = .string("outcomeUnknown")
    let latestManifest = try SessionManifestDocument(
      data: canonicalData(.object(latestManifestRoot)))
    let latestJournal = try FileDurableJournal(url: latestFixture.layout.journalURL)
    try latestJournal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "\(latestPrefix)-created", sequence: 0,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))
    for (eventID, sequence, from, to) in [
      ("\(latestPrefix)-preflight", 1, JobState.queued, JobState.preflight),
      ("\(latestPrefix)-running", 2, JobState.preflight, JobState.running),
    ] {
      try latestJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence,
          sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: from, to: to,
          reason: "latest attempt fixture"))
    }
    try latestJournal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "\(latestPrefix)-intent-1", sequence: 3,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, step: workflowStep,
        target: JournalTarget(
          scope: "host", targetID: "fixture-host", connectKey: nil,
          identitySnapshotHash: nil),
        attempt: 1, bindingRevision: nil))
    try latestJournal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "\(latestPrefix)-outcome-1", sequence: 4,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, stepID: workflowStep.id, attempt: 1,
        correlatesToIntentEventID: "\(latestPrefix)-intent-1", result: "succeeded",
        outcomeCertainty: .confirmed))
    try latestJournal.appendAndSynchronize(
      JournalEvent.stepIntent(
        eventID: "\(latestPrefix)-intent-2", sequence: 5,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, step: workflowStep,
        target: JournalTarget(
          scope: "host", targetID: "fixture-host", connectKey: nil,
          identitySnapshotHash: nil),
        attempt: 2, bindingRevision: nil))
    try latestJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(latestPrefix)-waiting", sequence: 6,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .running, to: .waitingForRecovery,
        reason: "latest attempt has no durable outcome"))
    try latestJournal.appendAndSynchronize(
      JournalEvent.abandonIntent(
        eventID: "\(latestPrefix)-abandon-intent", sequence: 7,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        userConfirmationID: "\(latestPrefix)-confirmation",
        lastConfirmedStep: workflowStep.id, outcomeCertainty: .outcomeUnknown,
        managedProcessState: "notRunning", deviceHazards: []))
    try latestJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(latestPrefix)-abandon-requested", sequence: 8,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .waitingForRecovery,
        to: .userAbandonRequested, reason: "user confirmed abandonment",
        triggerEventID: "\(latestPrefix)-abandon-intent"))
    try latestJournal.appendAndSynchronize(
      JournalEvent.abandonOutcome(
        eventID: "\(latestPrefix)-abandon-outcome", sequence: 9,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp,
        correlatesToAbandonIntentEventID: "\(latestPrefix)-abandon-intent",
        result: "archivedInterrupted", releaseAuthorized: true, unresolvedHazards: []))
    try latestJournal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(latestPrefix)-interrupted", sequence: 10,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .userAbandonRequested,
        to: .interrupted, reason: "abandonment persisted",
        triggerEventID: "\(latestPrefix)-abandon-outcome"))
    try latestJournal.appendAndSynchronize(
      JournalEvent(
        eventID: "\(latestPrefix)-finalized", sequence: 11,
        sessionID: latestFixture.layout.sessionID, jobID: latestFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .finalized,
        payload: [
          "terminalStatus": .string("interrupted"),
          "manifestSha256": .string(latestManifest.sha256),
          "outcomeCertainty": .string("outcomeUnknown"),
        ]))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: latestFixture.layout).publish(latestManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("latest outstanding attempt returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("outcome does not match Manifest execution tuple"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: latestFixture.layout.manifestURL.path))

    let stepFixture = try await makeSession(
      sessionID: "session-step-without-journal", jobID: "job-step-without-journal")
    defer { try? FileManager.default.removeItem(at: stepFixture.base) }
    let unbackedStep = try executionStep(
      id: "step-without-journal", kind: "probeHostTool", effect: "hostOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: arguments,
      disposition: "executed", outcomeCertainty: "confirmed", semanticResult: "succeeded")
    let unbackedStepManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: stepFixture.layout.sessionID, jobID: stepFixture.layout.jobID,
        steps: [unbackedStep]))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: stepFixture.layout).publish(
        unbackedStepManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("unbacked Manifest Step returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("Step step-without-journal lacks a durable journal"))
    }

    let compensationFixture = try await makeSession(
      sessionID: "session-compensation-without-journal",
      jobID: "job-compensation-without-journal")
    defer { try? FileManager.default.removeItem(at: compensationFixture.base) }
    let descriptor = try compensationDescriptor(
      id: "compensation-without-journal", kind: "stopRemoteCapture",
      effect: "deviceMutation", cancellation: "atSafeBoundary",
      bindingRequirement: "confirmedDevice", trigger: "onFailure",
      arguments: [
        "captureStepId": .string("source-without-journal"),
        "stopPolicy": .string("safe-stop"),
      ])
    let sourceStep = try executionStep(
      id: "source-without-journal", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string(compensationFixture.layout.sessionID),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], compensationDescriptors: [descriptor])
    let unbackedCompensation: JSONValue = .object([
      "descriptor": descriptor, "sourceStepId": .string("source-without-journal"),
      "disposition": .string("outcomeUnknown"),
      "outcomeCertainty": .string("outcomeUnknown"), "result": .string("unknown"),
      "failure": .null, "journalEventIds": .array([]),
    ])
    let compensationPrefix = "compensation-without-journal"
    let unbackedCompensationData = try SessionStorageFixtures.manifest(
      sessionID: compensationFixture.layout.sessionID,
      jobID: compensationFixture.layout.jobID, status: "interrupted",
      executionMode: "execute", executionAuthority: "interactiveUser",
      steps: [sourceStep], compensations: [unbackedCompensation],
      recovery: interruptedRecovery(
        sessionID: compensationFixture.layout.sessionID,
        jobID: compensationFixture.layout.jobID, prefix: compensationPrefix,
        lastConfirmedStepID: nil))
    guard
      case .object(var unbackedCompensationRoot) = try JSONDecoder().decode(
        JSONValue.self, from: unbackedCompensationData)
    else { return XCTFail("unbacked compensation Manifest fixture must be an object") }
    unbackedCompensationRoot["outcomeCertainty"] = .string("outcomeUnknown")
    let unbackedCompensationManifest = try SessionManifestDocument(
      data: canonicalData(.object(unbackedCompensationRoot)))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: compensationFixture.layout).publish(
        unbackedCompensationManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("unbacked Manifest compensation returned the wrong error: \(error)")
      }
      XCTAssertTrue(
        message.contains("compensation compensation-without-journal lacks a durable journal"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: compensationFixture.layout.manifestURL.path))
  }

  func testManifestPublicationRejectsNonterminalAndUnfinalizedNonemptyJournal()
    async throws
  {
    let nonterminalFixture = try await makeSession(
      sessionID: "session-journal-nonterminal", jobID: "job-journal-nonterminal")
    defer { try? FileManager.default.removeItem(at: nonterminalFixture.base) }
    let nonterminalManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: nonterminalFixture.layout.sessionID,
        jobID: nonterminalFixture.layout.jobID))
    let nonterminalJournal = try FileDurableJournal(url: nonterminalFixture.layout.journalURL)
    try nonterminalJournal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "nonterminal-created", sequence: 0,
        sessionID: nonterminalFixture.layout.sessionID,
        jobID: nonterminalFixture.layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))

    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: nonterminalFixture.layout).publish(
        nonterminalManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("nonterminal journal returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("journal is not terminal"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: nonterminalFixture.layout.manifestURL.path))

    let unfinalizedFixture = try await makeSession(
      sessionID: "session-journal-unfinalized", jobID: "job-journal-unfinalized")
    defer { try? FileManager.default.removeItem(at: unfinalizedFixture.base) }
    let unfinalizedManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: unfinalizedFixture.layout.sessionID,
        jobID: unfinalizedFixture.layout.jobID, status: "failed"))
    let unfinalizedJournal = try FileDurableJournal(url: unfinalizedFixture.layout.journalURL)
    let identity = (
      sessionID: unfinalizedFixture.layout.sessionID,
      jobID: unfinalizedFixture.layout.jobID
    )
    try unfinalizedJournal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "unfinalized-created", sequence: 0,
        sessionID: identity.sessionID, jobID: identity.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))
    let transitions: [(String, Int, JobState, JobState)] = [
      ("unfinalized-preflight", 1, .queued, .preflight),
      ("unfinalized-running", 2, .preflight, .running),
      ("unfinalized-finalizing", 3, .running, .finalizing),
      ("unfinalized-failed", 4, .finalizing, .failed),
    ]
    for (eventID, sequence, from, to) in transitions {
      try unfinalizedJournal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: eventID, sequence: sequence,
          sessionID: identity.sessionID, jobID: identity.jobID,
          timestamp: SessionStorageFixtures.timestamp, from: from, to: to,
          reason: "terminal journal fixture"))
    }

    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: unfinalizedFixture.layout).publish(
        unfinalizedManifest)
    ) { error in
      guard case SessionStorageError.invalidManifest(let message) = error else {
        return XCTFail("unfinalized terminal journal returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("missing finalized record"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: unfinalizedFixture.layout.manifestURL.path))
  }

  func testManifestCommitLocksJournalSnapshotThroughWriteOnceRename() async throws {
    let fixture = try await makeSession(
      sessionID: "session-journal-lock", jobID: "job-journal-lock")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let journal = try FileDurableJournal(url: fixture.layout.journalURL)
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID))
    let publisherPaused = DispatchSemaphore(value: 0)
    let resumePublisher = DispatchSemaphore(value: 0)
    let publisherFinished = DispatchSemaphore(value: 0)
    let appendFinished = DispatchSemaphore(value: 0)
    let publisherResult = ManifestPublicationResultBox()
    let appendResult = JournalAppendResultBox()
    let publisher = AtomicSessionManifestPublisher(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .manifestWrite else { return }
        publisherPaused.signal()
        guard resumePublisher.wait(timeout: .now() + 5) == .success else {
          throw StorageContractFault.operation
        }
      })
    DispatchQueue.global().async {
      defer { publisherFinished.signal() }
      publisherResult.store(Result { try publisher.publish(manifest) })
    }
    XCTAssertEqual(publisherPaused.wait(timeout: .now() + 5), .success)
    DispatchQueue.global().async {
      defer { appendFinished.signal() }
      appendResult.store(
        Result {
          try journal.appendAndSynchronize(
            JournalEvent.jobCreated(
              eventID: "blocked-created", sequence: 0,
              sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID,
              timestamp: SessionStorageFixtures.timestamp, executionMode: "simulated"))
        })
    }
    XCTAssertEqual(appendFinished.wait(timeout: .now() + 0.1), .timedOut)
    resumePublisher.signal()
    XCTAssertEqual(publisherFinished.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(appendFinished.wait(timeout: .now() + 5), .success)
    guard case .success? = publisherResult.load() else {
      return XCTFail("Manifest publisher did not complete while holding the journal boundary")
    }
    guard case .failure(let appendFailure)? = appendResult.load(),
      case DurableFileError.sequenceViolation = appendFailure
    else {
      return XCTFail("journal append was not rejected after Manifest publication")
    }
    XCTAssertEqual(try AtomicSessionManifestPublisher(layout: fixture.layout).load(), manifest)
  }

  func testManifestLockedPolicyTerminalityAndSafeLoading() async throws {
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(coreSpecBaseline: "2.0.0")))
    XCTAssertNoThrow(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(timestamp: "2026-07-17T08:00:00.500Z")))

    let validFinalization = try executionStep(
      id: "step-valid-finalization", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ])
    XCTAssertNoThrow(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(steps: [validFinalization])))

    let flashArguments: [String: JSONValue] = [
      "providerOperationId": .string("provider.flash"),
      "partition": .string("system"),
      "imageArtifactId": .string("image-system"),
      "imageSha256": .string(String(repeating: "d", count: 64)),
      "imageSize": .integer(1),
      "confirmationId": .string("confirmation-flash"),
      "safeBoundaryId": .string("safe-boundary-flash"),
    ]
    let understatedFlash = try executionStep(
      id: "step-flash-understated", kind: "flashPartition", effect: "readOnly",
      cancellation: "immediate", bindingRequirement: "none", arguments: flashArguments)
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(steps: [understatedFlash])))

    let destructiveFlash = try executionStep(
      id: "step-flash-destructive", kind: "flashPartition", effect: "destructive",
      cancellation: "criticalNonInterruptible", bindingRequirement: "confirmedDevice",
      arguments: flashArguments)
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          executionMode: "execute", executionAuthority: "standardAgent",
          steps: [destructiveFlash])))

    let unknownFinalization = try executionStep(
      id: "step-finalization-unknown", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], disposition: "outcomeUnknown", outcomeCertainty: "outcomeUnknown",
      semanticResult: "unknown")
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          status: "planned", executionMode: "planOnly",
          executionAuthority: "interactiveUser", steps: [unknownFinalization])))

    let understatedCompensation = try compensationDescriptor(
      id: "compensation-stop", kind: "stopRemoteCapture", effect: "readOnly",
      cancellation: "immediate", bindingRequirement: "none", trigger: "onFailure",
      arguments: [
        "captureStepId": .string("capture-source"), "stopPolicy": .string("safe-stop"),
      ])
    let stepWithUnderstatedCompensation = try executionStep(
      id: "step-with-compensation", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], compensationDescriptors: [understatedCompensation])
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(steps: [stepWithUnderstatedCompensation])))
    let validCompensation = try compensationDescriptor(
      id: "compensation-stop", kind: "stopRemoteCapture", effect: "deviceMutation",
      cancellation: "atSafeBoundary", bindingRequirement: "confirmedDevice",
      trigger: "onFailure",
      arguments: [
        "captureStepId": .string("capture-source"), "stopPolicy": .string("safe-stop"),
      ])
    let stepWithValidCompensation = try executionStep(
      id: "step-with-compensation", kind: "finalizeSession", effect: "hostOnly",
      cancellation: "atSafeBoundary", bindingRequirement: "none",
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ], compensationDescriptors: [validCompensation])
    let understatedCompensationRecord: JSONValue = .object([
      "descriptor": understatedCompensation,
      "sourceStepId": .string("step-with-compensation"),
      "disposition": .string("notRun"),
      "outcomeCertainty": .string("notApplicable"),
      "result": .string("notRun"),
      "failure": .null,
      "journalEventIds": .array([]),
    ])
    XCTAssertThrowsError(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(
          steps: [stepWithValidCompensation],
          compensations: [understatedCompensationRecord])))

    let terminalFixture = try await makeSession(
      sessionID: "session-terminal-manifest", jobID: "job-terminal-manifest")
    defer { try? FileManager.default.removeItem(at: terminalFixture.base) }
    let failed = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: terminalFixture.layout.sessionID, jobID: terminalFixture.layout.jobID,
        status: "failed"))
    _ = try AtomicSessionManifestPublisher(layout: terminalFixture.layout).publish(failed)
    let succeeded = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: terminalFixture.layout.sessionID, jobID: terminalFixture.layout.jobID))
    XCTAssertThrowsError(
      try AtomicSessionManifestPublisher(layout: terminalFixture.layout).publish(succeeded))
    XCTAssertEqual(
      try AtomicSessionManifestPublisher(layout: terminalFixture.layout).load().status, "failed")

    let symlinkFixture = try await makeSession(
      sessionID: "session-symlink-manifest", jobID: "job-symlink-manifest")
    defer { try? FileManager.default.removeItem(at: symlinkFixture.base) }
    let externalManifest = symlinkFixture.base.appending(path: "external-manifest.json")
    try SessionStorageFixtures.manifest(
      sessionID: symlinkFixture.layout.sessionID, jobID: symlinkFixture.layout.jobID
    ).write(to: externalManifest)
    try FileManager.default.createSymbolicLink(
      at: symlinkFixture.layout.manifestURL, withDestinationURL: externalManifest)
    XCTAssertThrowsError(try AtomicSessionManifestPublisher(layout: symlinkFixture.layout).load())

    let oversizedFixture = try await makeSession(
      sessionID: "session-oversized-manifest", jobID: "job-oversized-manifest")
    defer { try? FileManager.default.removeItem(at: oversizedFixture.base) }
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: oversizedFixture.layout.manifestURL.path, contents: nil))
    let oversizedHandle = try FileHandle(forWritingTo: oversizedFixture.layout.manifestURL)
    try oversizedHandle.truncate(atOffset: 16 * 1_024 * 1_024 + 1)
    try oversizedHandle.close()
    XCTAssertThrowsError(try AtomicSessionManifestPublisher(layout: oversizedFixture.layout).load())
  }

  func testArtifactClaimMustBeBoundToItsExactSessionRoot() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try SessionStore(sessionsRoot: base.appending(path: "Sessions"))
    let identity = try SystemVolumeIdentityResolver().resolve(store.sessionsRoot)
    let coordinator = HostStorageCoordinator()
    let date = Date(timeIntervalSince1970: 1_752_739_200)
    let jobID = "job-cross-session-artifact"
    let claimARequest = try request(
      id: "claim-session-a", job: jobID, volume: identity, writer: .light,
      metadata: 1_024, finalization: 1_024, growth: 1_024)
    let claimBRequest = try request(
      id: "claim-session-b", job: jobID, volume: identity, writer: .light,
      metadata: 1_024, finalization: 1_024, growth: 1_024)
    guard
      case .admitted(let claimA) = await coordinator.admit(
        claimARequest, snapshot: storageSnapshot(identity: identity, available: UInt64.max)),
      case .admitted(let claimB) = await coordinator.admit(
        claimBRequest, snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { return XCTFail("same-volume light Session claims must be admitted") }
    let layoutA = try store.createSession(
      sessionID: "session-artifact-a", jobID: jobID, createdAt: date, claim: claimA)
    _ = try store.createSession(
      sessionID: "session-artifact-b", jobID: jobID, createdAt: date, claim: claimB)
    let source = base.appending(path: "cross-session-source.bin")
    try Data("cross-session-capability".utf8).write(to: source)
    let publication = try ArtifactPublicationRequest(
      artifactID: "cross-session-artifact", role: .raw,
      publicationName: "cross-session.bin", origin: "cross Session binding fixture")
    let rawBefore = try FileManager.default.contentsOfDirectory(
      atPath: layoutA.rawDirectory.path)
    let partialBefore = try FileManager.default.contentsOfDirectory(
      atPath: layoutA.partialDirectory.path)

    XCTAssertThrowsError(
      try SessionArtifactStore(layout: layoutA).publish(
        from: source, request: publication, claim: claimB)
    ) { error in
      guard case SessionStorageError.invalidRecord(let message) = error else {
        return XCTFail("cross-Session claim escaped capability validation: \(error)")
      }
      XCTAssertTrue(message.contains("claim-bound Session root"))
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: layoutA.rawDirectory.path), rawBefore)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: layoutA.partialDirectory.path),
      partialBefore)

    let published = try SessionArtifactStore(layout: layoutA).publish(
      from: source, request: publication, claim: claimA)
    XCTAssertEqual(published.record.sha256, sha256(Data("cross-session-capability".utf8)))
  }

  func testArtifactClaimIsBoundToDestinationVolumeAndInputPathIdentity() async throws {
    let fixture = try await makeSession(
      sessionID: "session-volume-bound", jobID: "job-volume-bound")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let volumeA = fixture.claim.volumeIdentity
    let volumeB = try VolumeIdentity(value: "uuid:volume-b")
    let claim = fixture.claim
    let source = fixture.base.appending(path: "volume-source.bin")
    try Data("volume-bound-source".utf8).write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "volume-bound-artifact", role: .raw,
      publicationName: "volume-bound.bin", origin: "volume binding fixture")

    let descriptorMismatch = SequencedVolumeIdentityResolver(
      pathIdentities: [volumeA], descriptorIdentity: volumeB)
    XCTAssertThrowsError(
      try SessionArtifactStore(
        layout: fixture.layout, volumeIdentityResolver: descriptorMismatch
      ).publish(from: source, request: request, claim: claim)
    ) { error in
      XCTAssertEqual(
        error as? SessionStorageError,
        .volumeIdentityChanged(expected: volumeA, actual: volumeB))
    }

    let remountedBeforeRename = SequencedVolumeIdentityResolver(
      pathIdentities: [volumeA], descriptorIdentities: [volumeA, volumeA, volumeB])
    XCTAssertThrowsError(
      try SessionArtifactStore(
        layout: fixture.layout, volumeIdentityResolver: remountedBeforeRename
      ).publish(
        from: source,
        request: try ArtifactPublicationRequest(
          artifactID: "remounted-artifact", role: .raw,
          publicationName: "remounted.bin", origin: "remount fixture"),
        claim: claim)
    ) { error in
      XCTAssertEqual(
        error as? SessionStorageError,
        .volumeIdentityChanged(expected: volumeA, actual: volumeB))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: "remounted.bin").path))

    let input = fixture.base.appending(path: "replaceable-input.img")
    let movedInput = fixture.base.appending(path: "original-input.img")
    try Data("original-image".utf8).write(to: input)
    let referencer = InputImageReferencer(
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .inputReferencePathValidation else { return }
        try FileManager.default.moveItem(at: input, to: movedInput)
        try Data("replacement-image".utf8).write(to: input)
      })
    XCTAssertThrowsError(try referencer.reference(input)) { error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("path replacement was not rejected: \(error)")
      }
    }
  }

  func testArtifactGrowthBudgetIsSharedAndDirectorySyncFailureIsRecoverable() async throws {
    let fixture = try await makeSession(
      sessionID: "session-growth-budget", jobID: "job-growth-budget",
      claimID: "claim-growth-budget", metadata: 100, finalization: 100, growth: 5)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let identity = try SystemVolumeIdentityResolver().resolve(fixture.layout.root)
    let coordinator = fixture.coordinator
    let claim = fixture.claim
    let store = SessionArtifactStore(layout: fixture.layout)
    let tooLarge = fixture.base.appending(path: "too-large.bin")
    try Data("123456".utf8).write(to: tooLarge)
    XCTAssertThrowsError(
      try store.publish(
        from: tooLarge,
        request: ArtifactPublicationRequest(
          artifactID: "too-large", role: .raw, publicationName: "too-large.bin",
          origin: "growth fixture"),
        claim: claim)
    ) { error in
      XCTAssertEqual(error as? SessionStorageError, .insufficientSpace(required: 6, available: 5))
    }
    XCTAssertEqual(claim.remainingGrowthBytes, 5)

    let first = fixture.base.appending(path: "first-small.bin")
    try Data("1234".utf8).write(to: first)
    _ = try store.publish(
      from: first,
      request: ArtifactPublicationRequest(
        artifactID: "first-small", role: .raw, publicationName: "first-small.bin",
        origin: "growth fixture"),
      claim: claim)
    XCTAssertEqual(claim.remainingGrowthBytes, 1)
    let reservedAfterFirst = await coordinator.reservedBytes(on: identity)
    XCTAssertEqual(reservedAfterFirst, 201)

    let second = fixture.base.appending(path: "second-small.bin")
    try Data("12".utf8).write(to: second)
    XCTAssertThrowsError(
      try store.publish(
        from: second,
        request: ArtifactPublicationRequest(
          artifactID: "second-small", role: .raw, publicationName: "second-small.bin",
          origin: "growth fixture"),
        claim: claim)
    ) { error in
      XCTAssertEqual(error as? SessionStorageError, .insufficientSpace(required: 2, available: 1))
    }
    try await coordinator.updateRemainingGrowth(claimID: claim.claimID, remainingBytes: 0)
    XCTAssertEqual(claim.remainingGrowthBytes, 0)

    let recoveryFixture = try await makeSession(
      sessionID: "session-artifact-retry", jobID: "job-artifact-retry")
    defer { try? FileManager.default.removeItem(at: recoveryFixture.base) }
    let recoveryClaim = recoveryFixture.claim
    let source = recoveryFixture.base.appending(path: "retry-source.bin")
    let bytes = Data("rename-completed".utf8)
    try bytes.write(to: source)
    let publication = try ArtifactPublicationRequest(
      artifactID: "artifact-retry", role: .raw, publicationName: "retry.bin",
      origin: "directory barrier retry")
    var failedTargetSync = false
    let failingStore = SessionArtifactStore(
      layout: recoveryFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactDirectorySync, !failedTargetSync {
          failedTargetSync = true
          throw DurableFileError.syncFailed(path: "retry.bin", errno: ENOSPC)
        }
      })
    XCTAssertThrowsError(
      try failingStore.publish(from: source, request: publication, claim: recoveryClaim))
    let remainingAfterRename = recoveryClaim.remainingGrowthBytes
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recoveryFixture.layout.rawDirectory.appending(path: "retry.bin").path))

    try Data("mismatched recovery source".utf8).write(to: source)
    XCTAssertThrowsError(
      try SessionArtifactStore(layout: recoveryFixture.layout).publish(
        from: source, request: publication, claim: recoveryClaim)
    ) { error in
      guard case SessionStorageError.artifactAlreadyPublished = error else {
        return XCTFail("mismatched recovery returned the wrong error: \(error)")
      }
    }
    let retainedRecoveryEntries = try FileManager.default.contentsOfDirectory(
      atPath: recoveryFixture.layout.partialDirectory.path)
    XCTAssertTrue(
      retainedRecoveryEntries.contains {
        $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
      })
    try bytes.write(to: source)

    var recoveryCheckpoints: Set<SessionStorageFaultPoint> = []
    let recovered = try SessionArtifactStore(
      layout: recoveryFixture.layout,
      faultInjector: SessionStorageFaultInjector { recoveryCheckpoints.insert($0) }
    ).publish(from: source, request: publication, claim: recoveryClaim)
    XCTAssertEqual(recovered.record.size, UInt64(bytes.count))
    XCTAssertEqual(recovered.record.sha256, sha256(bytes))
    XCTAssertEqual(recoveryClaim.remainingGrowthBytes, remainingAfterRename)
    XCTAssertTrue(recoveryCheckpoints.contains(.artifactDirectorySync))
    XCTAssertTrue(recoveryCheckpoints.contains(.artifactSourceDirectorySync))
    let recoveryDirectoryEntries = try FileManager.default.contentsOfDirectory(
      atPath: recoveryFixture.layout.partialDirectory.path)
    XCTAssertTrue(
      recoveryDirectoryEntries.contains {
        $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
      })
    let recoveryManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: recoveryFixture.layout.sessionID,
        jobID: recoveryFixture.layout.jobID,
        status: "failed",
        artifacts: [recovered.record]))
    _ = try AtomicSessionManifestPublisher(layout: recoveryFixture.layout).publish(
      recoveryManifest)
    let committedRecoveryEntries = try FileManager.default.contentsOfDirectory(
      atPath: recoveryFixture.layout.partialDirectory.path)
    XCTAssertFalse(
      committedRecoveryEntries.contains {
        $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
      })
    try Data("different retry bytes".utf8).write(to: source)
    XCTAssertThrowsError(
      try SessionArtifactStore(layout: recoveryFixture.layout).publish(
        from: source, request: publication, claim: recoveryClaim)
    ) { error in
      guard case SessionStorageError.invalidArtifact(let message) = error else {
        return XCTFail("completed publication retry returned the wrong error: \(error)")
      }
      XCTAssertTrue(message.contains("terminal manifest"))
    }
  }

  func testArtifactPreMarkerFailuresRemainRetryableWithoutDoubleChargingGrowth() async throws {
    let fixture = try await makeSession(
      sessionID: "session-pre-marker-retry", jobID: "job-pre-marker-retry")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let claim = fixture.claim
    let retryableFaults: [SessionStorageFaultPoint] = [
      .artifactPartialDirectorySync,
      .artifactWrite,
      .artifactFileSync,
      .artifactValidation,
      .artifactRecoveryRecordWrite,
      .artifactRecoveryRecordSync,
      .artifactRecoveryRecordReplace,
      .artifactRecoveryRecordDirectorySync,
    ]

    for (index, faultPoint) in retryableFaults.enumerated() {
      let source = fixture.base.appending(path: "pre-marker-\(index).bin")
      let bytes = Data("retryable-pre-marker-\(faultPoint.rawValue)".utf8)
      try bytes.write(to: source)
      let request = try ArtifactPublicationRequest(
        artifactID: "pre-marker-\(index)", role: .raw,
        publicationName: "pre-marker-\(index).bin", origin: "pre-marker retry fixture",
        expectedSHA256: sha256(bytes))
      let remainingBeforeAttempt = claim.remainingGrowthBytes
      var injected = false
      let failingStore = SessionArtifactStore(
        layout: fixture.layout,
        faultInjector: SessionStorageFaultInjector { point in
          if point == faultPoint, !injected {
            injected = true
            throw StorageContractFault.injected(point.rawValue)
          }
        })
      XCTAssertThrowsError(
        try failingStore.publish(from: source, request: request, claim: claim))
      XCTAssertTrue(injected)

      let published = try SessionArtifactStore(layout: fixture.layout).publish(
        from: source, request: request, claim: claim)
      XCTAssertEqual(published.record.sha256, sha256(bytes))
      XCTAssertEqual(published.record.size, UInt64(bytes.count))
      XCTAssertEqual(
        remainingBeforeAttempt - claim.remainingGrowthBytes, UInt64(bytes.count),
        "retry after \(faultPoint.rawValue) charged output growth more than once")
      let partialEntries = try FileManager.default.contentsOfDirectory(
        atPath: fixture.layout.partialDirectory.path)
      XCTAssertEqual(
        partialEntries.filter {
          $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
        }.count,
        index + 1)
      XCTAssertLessThanOrEqual(
        partialEntries.filter { $0.hasPrefix(".publication-lock-") }.count, 16)
    }

    let cleanupFixture = try await makeSession(
      sessionID: "session-marker-cleanup", jobID: "job-marker-cleanup")
    defer { try? FileManager.default.removeItem(at: cleanupFixture.base) }
    let cleanupClaim = cleanupFixture.claim
    let cleanupSource = cleanupFixture.base.appending(path: "cleanup-directory-sync.bin")
    let cleanupBytes = Data("cleanup-directory-sync-is-post-publication".utf8)
    try cleanupBytes.write(to: cleanupSource)
    let cleanupRequest = try ArtifactPublicationRequest(
      artifactID: "cleanup-directory-sync", role: .raw,
      publicationName: "cleanup-directory-sync.bin", origin: "marker cleanup fixture",
      expectedSHA256: sha256(cleanupBytes))
    let cleanupPublished = try SessionArtifactStore(layout: cleanupFixture.layout).publish(
      from: cleanupSource, request: cleanupRequest, claim: cleanupClaim)
    let preCleanupEntries = try FileManager.default.contentsOfDirectory(
      atPath: cleanupFixture.layout.partialDirectory.path)
    XCTAssertTrue(
      preCleanupEntries.contains {
        $0.hasPrefix(".publication-") && $0.hasSuffix(".json")
      })
    let cleanupManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: cleanupFixture.layout.sessionID,
        jobID: cleanupFixture.layout.jobID,
        status: "failed",
        artifacts: [cleanupPublished.record]))
    var cleanupDirectorySyncFaultObserved = false
    let failingManifestPublisher = AtomicSessionManifestPublisher(
      layout: cleanupFixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactRecoveryRecordCleanupDirectorySync,
          !cleanupDirectorySyncFaultObserved
        else { return }
        cleanupDirectorySyncFaultObserved = true
        throw DurableFileError.syncFailed(
          path: cleanupFixture.layout.partialDirectory.path, errno: ENOSPC)
      })
    XCTAssertThrowsError(try failingManifestPublisher.publish(cleanupManifest))
    XCTAssertTrue(cleanupDirectorySyncFaultObserved)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: cleanupFixture.layout.manifestURL.path))
    let postCleanupEntries = try FileManager.default.contentsOfDirectory(
      atPath: cleanupFixture.layout.partialDirectory.path)
    XCTAssertFalse(
      postCleanupEntries.contains { $0.hasPrefix(".publication-") && $0.hasSuffix(".json") })
    let repairedManifest = try AtomicSessionManifestPublisher(layout: cleanupFixture.layout)
      .publish(cleanupManifest)
    XCTAssertEqual(repairedManifest.sha256, cleanupManifest.sha256)
    XCTAssertEqual(
      try AtomicSessionManifestPublisher(layout: cleanupFixture.layout).load(),
      cleanupManifest)

    let correctedSource = fixture.base.appending(path: "corrected-checksum.bin")
    let correctedBytes = Data("validated-partial-can-be-adopted".utf8)
    try correctedBytes.write(to: correctedSource)
    let remainingBeforeChecksumAttempt = claim.remainingGrowthBytes
    let wrongChecksumRequest = try ArtifactPublicationRequest(
      artifactID: "corrected-checksum", role: .raw,
      publicationName: "corrected-checksum.bin", origin: "checksum retry fixture",
      expectedSHA256: String(repeating: "0", count: 64))
    XCTAssertThrowsError(
      try SessionArtifactStore(layout: fixture.layout).publish(
        from: correctedSource, request: wrongChecksumRequest, claim: claim)
    ) { error in
      guard case SessionStorageError.checksumMismatch = error else {
        return XCTFail("checksum validation fault was not preserved: \(error)")
      }
    }
    let correctedRequest = try ArtifactPublicationRequest(
      artifactID: "corrected-checksum", role: .raw,
      publicationName: "corrected-checksum.bin", origin: "checksum retry fixture",
      expectedSHA256: sha256(correctedBytes))
    let corrected = try SessionArtifactStore(layout: fixture.layout).publish(
      from: correctedSource, request: correctedRequest, claim: claim)
    XCTAssertEqual(corrected.record.sha256, sha256(correctedBytes))
    XCTAssertEqual(
      remainingBeforeChecksumAttempt - claim.remainingGrowthBytes,
      UInt64(correctedBytes.count))

    let reusableSource = fixture.base.appending(path: "reusable-mode.bin")
    let reusableBytes = Data("complete-writable-residual".utf8)
    try reusableBytes.write(to: reusableSource)
    let reusableRequest = try ArtifactPublicationRequest(
      artifactID: "reusable-mode", role: .raw,
      publicationName: "reusable-mode.bin", origin: "raw chmod retry fixture",
      expectedSHA256: sha256(reusableBytes))
    let publicationKey = sha256(
      Data(
        "\(reusableRequest.artifactID)\u{0}\(reusableRequest.role.rawValue)\u{0}\(reusableRequest.publicationName)"
          .utf8))
    let reusablePartial = fixture.layout.partialDirectory.appending(
      path: "\(publicationKey).part")
    try reusableBytes.write(to: reusablePartial)
    XCTAssertEqual(chmod(reusablePartial.path, 0o600), 0)
    let reusable = try SessionArtifactStore(layout: fixture.layout).publish(
      from: reusableSource, request: reusableRequest, claim: claim)
    var reusableMetadata = stat()
    XCTAssertEqual(lstat(reusable.url.path, &reusableMetadata), 0)
    XCTAssertEqual(reusableMetadata.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH), 0)
    XCTAssertTrue(try SessionArtifactStore(layout: fixture.layout).partialArtifacts().isEmpty)
  }

  func testArtifactPublicationIsSerializedAcrossStoreInstancesAndBindsPartialInode()
    async throws
  {
    let fixture = try await makeSession(
      sessionID: "session-cross-store-publication", jobID: "job-cross-store-publication",
      growth: 1_024 * 1_024)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let winnerSource = fixture.base.appending(path: "winner.bin")
    let contenderSource = fixture.base.appending(path: "contender.bin")
    let winnerBytes = Data("winner-publication-bytes".utf8)
    try winnerBytes.write(to: winnerSource)
    try Data("contender-must-not-replace-partial".utf8).write(to: contenderSource)
    let request = try ArtifactPublicationRequest(
      artifactID: "cross-store-artifact", role: .raw,
      publicationName: "cross-store.bin", origin: "cross-store lock fixture",
      expectedSHA256: sha256(winnerBytes))
    let claim = fixture.claim
    let winnerPaused = DispatchSemaphore(value: 0)
    let contenderAtLock = DispatchSemaphore(value: 0)
    let allowWinner = DispatchSemaphore(value: 0)
    let winnerFinished = DispatchSemaphore(value: 0)
    let contenderFinished = DispatchSemaphore(value: 0)
    let winnerResult = PublicationResultBox()
    let contenderResult = PublicationResultBox()
    let winnerStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactWrite else { return }
        winnerPaused.signal()
        guard allowWinner.wait(timeout: .now() + 5) == .success else {
          throw StorageContractFault.operation
        }
      })
    let contenderStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .artifactPublicationLock { contenderAtLock.signal() }
      })

    DispatchQueue.global().async {
      winnerResult.store(
        Result { try winnerStore.publish(from: winnerSource, request: request, claim: claim) })
      winnerFinished.signal()
    }
    let winnerPauseWait = await waitForSemaphore(winnerPaused)
    guard winnerPauseWait == .success else {
      return XCTFail("winner did not reach the write checkpoint while holding publication lock")
    }
    DispatchQueue.global().async {
      contenderResult.store(
        Result {
          try contenderStore.publish(from: contenderSource, request: request, claim: claim)
        })
      contenderFinished.signal()
    }
    let contenderLockWait = await waitForSemaphore(contenderAtLock)
    guard contenderLockWait == .success else {
      allowWinner.signal()
      return XCTFail("contender did not attempt the shared publication lock")
    }
    allowWinner.signal()
    let winnerWait = await waitForSemaphore(winnerFinished)
    let contenderWait = await waitForSemaphore(contenderFinished)
    XCTAssertEqual(winnerWait, .success)
    XCTAssertEqual(contenderWait, .success)

    let published = try XCTUnwrap(winnerResult.load()).get()
    XCTAssertThrowsError(try XCTUnwrap(contenderResult.load()).get())
    XCTAssertEqual(try Data(contentsOf: published.url), winnerBytes)
    XCTAssertEqual(published.record.size, UInt64(winnerBytes.count))
    XCTAssertEqual(published.record.sha256, sha256(winnerBytes))
    XCTAssertEqual(claim.remainingGrowthBytes, 1_024 * 1_024 - UInt64(winnerBytes.count))
    XCTAssertTrue(try SessionArtifactStore(layout: fixture.layout).partialArtifacts().isEmpty)
  }

  func testArtifactPublicationRejectsIntermediateDirectorySymlinkSubstitution() async throws {
    let fixture = try await makeSession(
      sessionID: "session-artifact-directory-substitution",
      jobID: "job-artifact-directory-substitution")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "directory-substitution-source.bin")
    let bytes = Data("must-remain-inside-session-root".utf8)
    try bytes.write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "directory-substitution-artifact", role: .raw,
      publicationName: "directory-substitution.bin", origin: "directory substitution fixture",
      expectedSHA256: sha256(bytes))
    let artifactsURL = fixture.layout.root.appending(path: "artifacts")
    let displacedURL = fixture.layout.root.appending(path: "artifacts-displaced")
    let externalURL = fixture.base.appending(path: "external-artifacts")
    for component in ["raw", "derived", "partial"] {
      try FileManager.default.createDirectory(
        at: externalURL.appending(path: component), withIntermediateDirectories: true)
    }
    var substituted = false
    defer {
      if substituted {
        try? FileManager.default.removeItem(at: artifactsURL)
        try? FileManager.default.moveItem(at: displacedURL, to: artifactsURL)
      }
    }
    let store = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactReplace, !substituted else { return }
        try FileManager.default.moveItem(at: artifactsURL, to: displacedURL)
        try FileManager.default.createSymbolicLink(
          at: artifactsURL, withDestinationURL: externalURL)
        substituted = true
      })

    XCTAssertThrowsError(
      try store.publish(from: source, request: request, claim: fixture.claim)
    ) { error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("intermediate directory substitution escaped validation: \(error)")
      }
    }
    XCTAssertTrue(substituted)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: externalURL.appending(path: "raw/\(request.publicationName)").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: displacedURL.appending(path: "raw/\(request.publicationName)").path))
  }

  func testArtifactRenameRejectsPartialPathInodeSubstitution() async throws {
    let fixture = try await makeSession(
      sessionID: "session-partial-inode", jobID: "job-partial-inode")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "inode-source.bin")
    let bytes = Data("opened-inode-must-own-publication-path".utf8)
    try bytes.write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "inode-bound-artifact", role: .raw,
      publicationName: "inode-bound.bin", origin: "inode substitution fixture",
      expectedSHA256: sha256(bytes))
    let publicationKey = sha256(
      Data(
        "\(request.artifactID)\u{0}\(request.role.rawValue)\u{0}\(request.publicationName)".utf8))
    let partial = fixture.layout.partialDirectory.appending(path: "\(publicationKey).part")
    let displaced = fixture.layout.partialDirectory.appending(path: ".displaced-inode.part")
    let claim = fixture.claim
    var substituted = false
    let store = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactReplace, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(at: partial, to: displaced)
        guard FileManager.default.createFile(atPath: partial.path, contents: Data()) else {
          throw StorageContractFault.operation
        }
      })

    XCTAssertThrowsError(try store.publish(from: source, request: request, claim: claim)) {
      error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("partial inode substitution escaped Storage error domain: \(error)")
      }
    }
    XCTAssertTrue(substituted)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: request.publicationName).path))
    XCTAssertEqual(try Data(contentsOf: displaced), bytes)
  }

  func testArtifactReusablePartialKeepsFingerprintDescriptorThroughRename() async throws {
    let fixture = try await makeSession(
      sessionID: "session-reusable-inode", jobID: "job-reusable-inode")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "reusable-inode-source.bin")
    let bytes = Data("reusable-partial-descriptor-must-remain-bound".utf8)
    try bytes.write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "reusable-inode-artifact", role: .raw,
      publicationName: "reusable-inode.bin", origin: "reusable inode fixture",
      expectedSHA256: sha256(bytes))
    let publicationKey = sha256(
      Data(
        "\(request.artifactID)\u{0}\(request.role.rawValue)\u{0}\(request.publicationName)".utf8))
    let partial = fixture.layout.partialDirectory.appending(path: "\(publicationKey).part")
    let displaced = fixture.layout.partialDirectory.appending(path: ".reusable-displaced.part")
    try bytes.write(to: partial)
    XCTAssertEqual(chmod(partial.path, 0o600), 0)
    let claim = fixture.claim
    var substituted = false
    let store = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactReplace, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(at: partial, to: displaced)
        guard
          FileManager.default.createFile(
            atPath: partial.path, contents: Data("reusable-impostor".utf8))
        else { throw StorageContractFault.operation }
      })

    XCTAssertThrowsError(try store.publish(from: source, request: request, claim: claim)) {
      error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("reusable partial substitution escaped Storage error domain: \(error)")
      }
    }
    XCTAssertTrue(substituted)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: request.publicationName).path))
    XCTAssertEqual(try Data(contentsOf: displaced), bytes)
    var impostorMetadata = stat()
    XCTAssertEqual(lstat(partial.path, &impostorMetadata), 0)
    XCTAssertNotEqual(impostorMetadata.st_mode & S_IWUSR, 0)
  }

  func testArtifactRecoveryKeepsFingerprintDescriptorThroughRename() async throws {
    let fixture = try await makeSession(
      sessionID: "session-recovery-inode", jobID: "job-recovery-inode")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let source = fixture.base.appending(path: "recovery-inode-source.bin")
    let bytes = Data("recovery-partial-descriptor-must-remain-bound".utf8)
    try bytes.write(to: source)
    let request = try ArtifactPublicationRequest(
      artifactID: "recovery-inode-artifact", role: .raw,
      publicationName: "recovery-inode.bin", origin: "recovery inode fixture",
      expectedSHA256: sha256(bytes))
    let publicationKey = sha256(
      Data(
        "\(request.artifactID)\u{0}\(request.role.rawValue)\u{0}\(request.publicationName)".utf8))
    let partial = fixture.layout.partialDirectory.appending(path: "\(publicationKey).part")
    let displaced = fixture.layout.partialDirectory.appending(path: ".recovery-displaced.part")
    let claim = fixture.claim
    var interrupted = false
    let interruptedStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactReplace, !interrupted else { return }
        interrupted = true
        throw StorageContractFault.operation
      })
    XCTAssertThrowsError(
      try interruptedStore.publish(from: source, request: request, claim: claim))
    XCTAssertTrue(interrupted)
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

    var substituted = false
    let recoveryStore = SessionArtifactStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .artifactReplace, !substituted else { return }
        substituted = true
        try FileManager.default.moveItem(at: partial, to: displaced)
        guard
          FileManager.default.createFile(
            atPath: partial.path, contents: Data("recovery-impostor".utf8))
        else { throw StorageContractFault.operation }
      })
    XCTAssertThrowsError(
      try recoveryStore.publish(from: source, request: request, claim: claim)
    ) { error in
      guard case SessionStorageError.invalidArtifact = error else {
        return XCTFail("recovery partial substitution escaped Storage error domain: \(error)")
      }
    }
    XCTAssertTrue(substituted)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.layout.rawDirectory.appending(path: request.publicationName).path))
    XCTAssertEqual(try Data(contentsOf: displaced), bytes)
  }

  func testTerminalFinalizerBindsSessionRootAndClaimVolume() async throws {
    let auditFixture = try await makeSession(
      sessionID: "session-terminal-location", jobID: "job-terminal-location")
    let manifestFixture = try await makeSession(
      sessionID: "session-terminal-location", jobID: "job-terminal-location")
    defer { try? FileManager.default.removeItem(at: auditFixture.base) }
    defer { try? FileManager.default.removeItem(at: manifestFixture.base) }
    let audit = try FileDurableSessionAuditStore(layout: auditFixture.layout)
    let publisher = AtomicSessionManifestPublisher(layout: manifestFixture.layout)
    let record = try SessionAuditRecord(
      recordID: "terminal-location-record", auditID: "terminal-location-audit",
      correlationID: "terminal-location-correlation", sessionID: auditFixture.layout.sessionID,
      jobID: auditFixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["status": .string("succeeded")])
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: manifestFixture.layout.sessionID, jobID: manifestFixture.layout.jobID))
    let identity = try SystemVolumeIdentityResolver().resolve(auditFixture.layout.root)
    _ = await auditFixture.coordinator.reportWriteFailure(
      claimID: auditFixture.claim.claimID, errno: ENOSPC)
    do {
      _ = try SessionStorageTerminalFinalizer(
        audit: audit, manifestPublisher: publisher
      ).persist(
        claim: auditFixture.claim, disposition: .succeeded,
        auditRecord: record, manifest: manifest)
      XCTFail("different Session roots must not produce a terminal receipt")
    } catch SessionStorageError.invalidRecord(let message) {
      XCTAssertTrue(message.contains("Session root"))
    }
    XCTAssertEqual(try Data(contentsOf: auditFixture.layout.sessionAuditURL).count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestFixture.layout.manifestURL.path))
    let locationClaims = await auditFixture.coordinator.activeClaimCount()
    XCTAssertEqual(locationClaims, 1)

    let foreignAudit = try FileDurableSessionAuditStore(layout: manifestFixture.layout)
    do {
      _ = try SessionStorageTerminalFinalizer(
        audit: foreignAudit, manifestPublisher: publisher
      ).persist(
        claim: auditFixture.claim, disposition: .succeeded,
        auditRecord: record, manifest: manifest)
      XCTFail("one claim must not finalize a second same-Job Session root")
    } catch SessionStorageError.invalidRecord(let message) {
      XCTAssertTrue(message.contains("claim-bound Session root"))
    }
    XCTAssertEqual(try Data(contentsOf: manifestFixture.layout.sessionAuditURL).count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: manifestFixture.layout.manifestURL.path))

    let volumeFixture = try await makeSession(
      sessionID: "session-terminal-volume", jobID: "job-terminal-volume")
    defer { try? FileManager.default.removeItem(at: volumeFixture.base) }
    let volumeAudit = try FileDurableSessionAuditStore(layout: volumeFixture.layout)
    let volumePublisher = AtomicSessionManifestPublisher(layout: volumeFixture.layout)
    let volumeRecord = try SessionAuditRecord(
      recordID: "terminal-volume-record", auditID: "terminal-volume-audit",
      correlationID: "terminal-volume-correlation", sessionID: volumeFixture.layout.sessionID,
      jobID: volumeFixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["status": .string("succeeded")])
    let volumeManifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: volumeFixture.layout.sessionID, jobID: volumeFixture.layout.jobID))
    let replacement = try VolumeIdentity(value: "replacement-terminal-volume")
    _ = await volumeFixture.coordinator.reportWriteFailure(
      claimID: volumeFixture.claim.claimID, errno: ENOSPC)
    do {
      _ = try SessionStorageTerminalFinalizer(
        audit: volumeAudit, manifestPublisher: volumePublisher,
        volumeIdentityResolver: FixedVolumeIdentityResolver(replacement)
      ).persist(
        claim: volumeFixture.claim, disposition: .succeeded,
        auditRecord: volumeRecord, manifest: volumeManifest)
      XCTFail("replacement volume must not produce a terminal receipt")
    } catch let error as SessionStorageError {
      XCTAssertEqual(error, .volumeIdentityChanged(expected: identity, actual: replacement))
    }
    XCTAssertEqual(try Data(contentsOf: volumeFixture.layout.sessionAuditURL).count, 0)
    let volumeClaims = await volumeFixture.coordinator.activeClaimCount()
    XCTAssertEqual(volumeClaims, 1)
  }

  func testLockedRFC3339ValidationRejectsNormalizedInvalidValues() throws {
    let invalid = [
      "2026-02-30T08:00:00Z", "2026-07-17T08:00:00+24:00",
      "2026-07-17T08:00:00+0800",
    ]
    for (index, timestamp) in invalid.enumerated() {
      XCTAssertThrowsError(
        try SessionAuditRecord(
          recordID: "invalid-time-\(index)", auditID: "invalid-time-audit-\(index)",
          correlationID: "invalid-time-correlation-\(index)", sessionID: "invalid-time-session",
          jobID: "invalid-time-job", category: .preview, timestamp: timestamp,
          details: ["test": .bool(true)]))
      XCTAssertThrowsError(
        try SessionManifestDocument(
          data: SessionStorageFixtures.manifest(timestamp: timestamp)))
      XCTAssertThrowsError(
        try RecoveryManifestAbandonConfirmation(
          confirmationID: "invalid-time-confirmation-\(index)", confirmedAt: timestamp))
    }
    let valid = "2024-02-29T23:59:60.123+23:59"
    XCTAssertNoThrow(
      try SessionAuditRecord(
        recordID: "valid-time", auditID: "valid-time-audit",
        correlationID: "valid-time-correlation", sessionID: "valid-time-session",
        jobID: "valid-time-job", category: .preview, timestamp: valid,
        details: ["test": .bool(true)]))
    XCTAssertNoThrow(
      try RecoveryManifestAbandonConfirmation(
        confirmationID: "valid-time-confirmation", confirmedAt: valid))
    XCTAssertNoThrow(
      try SessionManifestDocument(
        data: SessionStorageFixtures.manifest(timestamp: valid)))
  }

  func testManifestWriteOnceIsCrossInstanceDurableAndNonPoisoning() async throws {
    let fixture = try await makeSession(
      sessionID: "session-manifest-write-once", jobID: "job-manifest-write-once")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID))
    var directorySyncAttempts = 0
    let retryingPublisher = AtomicSessionManifestPublisher(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        guard point == .manifestDirectorySync else { return }
        directorySyncAttempts += 1
        if directorySyncAttempts == 1 {
          throw DurableFileError.syncFailed(path: fixture.layout.root.path, errno: ENOSPC)
        }
      })
    XCTAssertThrowsError(try retryingPublisher.publish(document)) { error in
      guard case SessionStorageError.writeFailed(_, let code) = error else {
        return XCTFail("manifest sync escaped Storage error domain: \(error)")
      }
      XCTAssertEqual(code, ENOSPC)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.manifestURL.path))
    XCTAssertNoThrow(try retryingPublisher.publish(document))
    XCTAssertEqual(directorySyncAttempts, 2)

    let conflicting = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID, status: "failed"))
    XCTAssertThrowsError(try retryingPublisher.publish(conflicting))
    XCTAssertEqual(try retryingPublisher.load(), document)

    let raceFixture = try await makeSession(
      sessionID: "session-manifest-race", jobID: "job-manifest-race")
    defer { try? FileManager.default.removeItem(at: raceFixture.base) }
    let succeeded = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: raceFixture.layout.sessionID, jobID: raceFixture.layout.jobID))
    let failed = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: raceFixture.layout.sessionID, jobID: raceFixture.layout.jobID,
        status: "failed"))
    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for candidate in [succeeded, failed] {
        group.addTask {
          do {
            _ = try AtomicSessionManifestPublisher(layout: raceFixture.layout).publish(candidate)
            return true
          } catch {
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }
    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    let winner = try AtomicSessionManifestPublisher(layout: raceFixture.layout).load()
    XCTAssertTrue(winner == succeeded || winner == failed)
  }

  func testAuditIdempotentRetryRepairsFailedDurabilityBarrier() async throws {
    let fixture = try await makeSession(
      sessionID: "session-audit-retry", jobID: "job-audit-retry")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let record = try SessionAuditRecord(
      recordID: "audit-sync-retry", auditID: "audit-retry",
      correlationID: "correlation-retry", sessionID: fixture.layout.sessionID,
      jobID: fixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["result": .string("failed")])
    var firstStore: FileDurableSessionAuditStore? = try FileDurableSessionAuditStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { point in
        if point == .auditFileSync {
          throw DurableFileError.syncFailed(path: fixture.layout.sessionAuditURL.path, errno: EIO)
        }
      })
    XCTAssertThrowsError(try firstStore?.appendAndSynchronize(record)) { error in
      guard case SessionStorageError.writeFailed(_, let code) = error else {
        return XCTFail("audit sync escaped Storage error domain: \(error)")
      }
      XCTAssertEqual(code, EIO)
    }
    firstStore = nil

    var repairedBarriers: Set<SessionStorageFaultPoint> = []
    let reopened = try FileDurableSessionAuditStore(
      layout: fixture.layout,
      faultInjector: SessionStorageFaultInjector { repairedBarriers.insert($0) })
    try reopened.appendAndSynchronize(record)
    XCTAssertTrue(repairedBarriers.contains(.auditFileSync))
    XCTAssertTrue(repairedBarriers.contains(.auditDirectorySync))
    XCTAssertEqual(try reopened.replay(correlationID: record.correlationID), [record])
  }

  func testRecoveryCompensationPolicyAndFractionalConfirmationRemainStrict() throws {
    XCTAssertNoThrow(
      try RecoveryManifestAbandonConfirmation(
        confirmationID: "confirmation-fractional",
        confirmedAt: "2026-07-17T08:00:00.500Z"))
    let arguments: [String: JSONValue] = [
      "captureStepId": .string("capture-source"), "stopPolicy": .string("safe-stop"),
    ]
    let understated = try compensationDescriptor(
      id: "recovery-stop", kind: "stopRemoteCapture", effect: "readOnly",
      cancellation: "immediate", bindingRequirement: "none", trigger: "onFailure",
      arguments: arguments)
    let valid = try compensationDescriptor(
      id: "recovery-stop", kind: "stopRemoteCapture", effect: "deviceMutation",
      cancellation: "atSafeBoundary", bindingRequirement: "confirmedDevice",
      trigger: "onFailure", arguments: arguments)

    func recoveryData(compensation: JSONValue) throws -> Data {
      try canonicalData(
        .object([
          "needsAttention": .bool(true),
          "interruptedReason": .string("host restart"),
          "deviceHazards": .array([]),
          "abandonAuditEventIds": .array([]),
          "lastConfirmedStepId": .null,
          "lastDeviceMode": .object(["state": .string("unknown")]),
          "managedHostProcessState": .string("notApplicable"),
          "recoveryGuide": .object([
            "providerIdentity": .string("fixture-provider"),
            "automaticRecoveryAvailable": .bool(false),
            "summary": .string("manual recovery required"),
            "steps": .array([.string("inspect device")]),
          ]),
          "unexecutedCompensations": .array([compensation]),
          "userConfirmation": .null,
          "recoveryOfSessionId": .null,
          "recoveryOfJobId": .null,
        ]))
    }
    XCTAssertThrowsError(try RecoveryManifestCodec.decode(recoveryData(compensation: understated)))
    XCTAssertNoThrow(try RecoveryManifestCodec.decode(recoveryData(compensation: valid)))
  }
}

private enum StorageContractFault: Error {
  case injected(String)
  case operation
  case finalization
}

private final class SequencedVolumeIdentityResolver: VolumeIdentityResolving, @unchecked Sendable {
  private let lock = NSLock()
  private var pathIdentities: [VolumeIdentity]
  private var descriptorIdentities: [VolumeIdentity]

  init(pathIdentities: [VolumeIdentity], descriptorIdentity: VolumeIdentity) {
    self.pathIdentities = pathIdentities
    self.descriptorIdentities = [descriptorIdentity]
  }

  init(pathIdentities: [VolumeIdentity], descriptorIdentities: [VolumeIdentity]) {
    self.pathIdentities = pathIdentities
    self.descriptorIdentities = descriptorIdentities
  }

  func resolve(_: URL) throws -> VolumeIdentity {
    lock.lock()
    defer { lock.unlock() }
    guard let identity = pathIdentities.first else { return descriptorIdentities.last! }
    if pathIdentities.count > 1 { pathIdentities.removeFirst() }
    return identity
  }

  func resolve(openFileDescriptor _: Int32) throws -> VolumeIdentity {
    lock.lock()
    defer { lock.unlock() }
    let identity = descriptorIdentities.first!
    if descriptorIdentities.count > 1 { descriptorIdentities.removeFirst() }
    return identity
  }
}

private struct FixedVolumeIdentityResolver: VolumeIdentityResolving {
  let identity: VolumeIdentity

  init(_ identity: VolumeIdentity) {
    self.identity = identity
  }

  func resolve(_: URL) throws -> VolumeIdentity { identity }

  func resolve(openFileDescriptor _: Int32) throws -> VolumeIdentity { identity }
}

private final class StorageClaimBox: @unchecked Sendable {
  private let lock = NSLock()
  private var claim: StorageClaim?

  func store(_ claim: StorageClaim) {
    lock.lock()
    self.claim = claim
    lock.unlock()
  }

  func load() -> StorageClaim? {
    lock.lock()
    defer { lock.unlock() }
    return claim
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func incrementAndGet() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}

private final class PublicationResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<PublishedArtifact, Error>?

  func store(_ result: Result<PublishedArtifact, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<PublishedArtifact, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

private final class ManifestPublicationResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<PublishedSessionManifest, Error>?

  func store(_ result: Result<PublishedSessionManifest, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<PublishedSessionManifest, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

private final class JournalAppendResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Void, Error>?

  func store(_ result: Result<Void, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<Void, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

private final class SessionLayoutResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<SessionLayout, Error>?

  func store(_ result: Result<SessionLayout, Error>) {
    lock.lock()
    self.result = result
    lock.unlock()
  }

  func load() -> Result<SessionLayout, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }
}

extension SessionArtifactStorageContractTests {
  fileprivate struct SessionFixture {
    let base: URL
    let layout: SessionLayout
    let coordinator: HostStorageCoordinator
    let claim: StorageClaim
  }

  fileprivate struct SessionFactory: Sendable {
    let base: URL
    let store: SessionStore
    let sessionID: String
    let jobID: String

    func create(
      claim: StorageClaim,
      coordinator: HostStorageCoordinator
    ) throws -> SessionFixture {
      let layout = try store.createSession(
        sessionID: sessionID, jobID: jobID,
        createdAt: Date(timeIntervalSince1970: 1_752_739_200), claim: claim)
      return SessionFixture(
        base: base, layout: layout, coordinator: coordinator, claim: claim)
    }
  }

  fileprivate struct TerminalPersistenceFixture: Sendable {
    let finalizer: SessionStorageTerminalFinalizer
    let auditRecord: SessionAuditRecord
    let manifest: SessionManifestDocument
  }

  fileprivate final class SessionFixtureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture: SessionFixture?

    func store(_ fixture: SessionFixture) {
      lock.lock()
      self.fixture = fixture
      lock.unlock()
    }

    func load() -> SessionFixture? {
      lock.lock()
      defer { lock.unlock() }
      return fixture
    }
  }

  fileprivate final class TerminalPersistenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture: TerminalPersistenceFixture?

    func store(_ fixture: TerminalPersistenceFixture) {
      lock.lock()
      self.fixture = fixture
      lock.unlock()
    }

    func load() -> TerminalPersistenceFixture? {
      lock.lock()
      defer { lock.unlock() }
      return fixture
    }
  }

  fileprivate final class TerminalReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: StorageTerminalPersistenceReceipt?

    func store(_ receipt: StorageTerminalPersistenceReceipt) {
      lock.lock()
      self.receipt = receipt
      lock.unlock()
    }

    func load() -> StorageTerminalPersistenceReceipt? {
      lock.lock()
      defer { lock.unlock() }
      return receipt
    }
  }

  fileprivate func makeSessionFactory(
    sessionID: String,
    jobID: String
  ) throws -> (factory: SessionFactory, identity: VolumeIdentity) {
    let base = try temporaryDirectory()
    let store = try SessionStore(sessionsRoot: base.appending(path: "Sessions"))
    return (
      SessionFactory(base: base, store: store, sessionID: sessionID, jobID: jobID),
      try SystemVolumeIdentityResolver().resolve(store.sessionsRoot)
    )
  }

  fileprivate func makeSession(
    sessionID: String = "session-1",
    jobID: String = "job-1",
    claimID: String? = nil,
    metadata: UInt64 = 1_024,
    finalization: UInt64 = 1_024,
    growth: UInt64 = 16 * 1_024 * 1_024
  ) async throws -> SessionFixture {
    let base = try temporaryDirectory()
    let store = try SessionStore(sessionsRoot: base.appending(path: "Sessions"))
    let identity = try SystemVolumeIdentityResolver().resolve(store.sessionsRoot)
    let coordinator = HostStorageCoordinator()
    let admissionRequest = try request(
      id: claimID ?? "session-create-\(sessionID)", job: jobID, volume: identity, writer: .light,
      metadata: metadata, finalization: finalization, growth: growth)
    guard
      case .admitted(let claim) = await coordinator.admit(
        admissionRequest,
        snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { throw StorageContractFault.operation }
    let layout = try store.createSession(
      sessionID: sessionID,
      jobID: jobID,
      createdAt: Date(timeIntervalSince1970: 1_752_739_200),
      claim: claim)
    return SessionFixture(base: base, layout: layout, coordinator: coordinator, claim: claim)
  }

  fileprivate func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-session-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  fileprivate func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate func artifact(id: String, role: ArtifactRole, path: String) throws -> ArtifactRecord {
    try ArtifactRecord(
      id: id, role: role, origin: "contract fixture", relativePath: path,
      size: 1, sha256: String(repeating: "b", count: 64))
  }

  fileprivate func request(
    id: String,
    job: String,
    volume: VolumeIdentity,
    writer: StorageWriterClass,
    metadata: UInt64 = 100,
    finalization: UInt64 = 100,
    growth: UInt64 = 100
  ) throws -> StorageClaimRequest {
    try StorageClaimRequest(
      claimID: id, jobID: job, volumeIdentity: volume,
      budget: StorageBudget(
        metadataHeadroomBytes: metadata, finalizationHeadroomBytes: finalization,
        remainingGrowthBytes: growth, writerClass: writer))
  }

  fileprivate func storageSnapshot(identity: VolumeIdentity, available: UInt64)
    -> HostStorageSnapshot
  {
    HostStorageSnapshot(
      volumeIdentity: identity, totalBytes: max(available, 1), availableBytes: available,
      isReadOnly: false)
  }

  fileprivate func waitForSemaphore(_ semaphore: DispatchSemaphore) async
    -> DispatchTimeoutResult
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: semaphore.wait(timeout: .now() + 5))
      }
    }
  }

  fileprivate func admittedClaim(
    claimID: String,
    jobID: String,
    layout: SessionLayout? = nil,
    writer: StorageWriterClass = .light,
    volumeIdentity: VolumeIdentity? = nil,
    growth: UInt64 = 16 * 1_024 * 1_024
  ) async throws -> (HostStorageCoordinator, StorageClaim) {
    let identity: VolumeIdentity
    if let volumeIdentity {
      identity = volumeIdentity
    } else if let layout {
      identity = try SystemVolumeIdentityResolver().resolve(layout.root)
    } else {
      identity = try VolumeIdentity(value: "volume-\(claimID)")
    }
    let coordinator = HostStorageCoordinator()
    let claimRequest = try request(
      id: claimID, job: jobID, volume: identity, writer: writer,
      metadata: 1_024, finalization: 1_024, growth: growth)
    guard
      case .admitted(let claim) = await coordinator.admit(
        claimRequest, snapshot: storageSnapshot(identity: identity, available: UInt64.max))
    else { throw StorageContractFault.operation }
    return (coordinator, claim)
  }

  fileprivate static func terminalFinalization(
    fixture: SessionFixture,
    status: String,
    recordID: String,
    manifestFaultInjector: SessionStorageFaultInjector = .none
  ) throws -> TerminalPersistenceFixture {
    let audit = try FileDurableSessionAuditStore(layout: fixture.layout)
    let publisher = AtomicSessionManifestPublisher(
      layout: fixture.layout, faultInjector: manifestFaultInjector)
    let record = try SessionAuditRecord(
      recordID: recordID, auditID: "audit-terminal", correlationID: "correlation-\(recordID)",
      sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID, category: .outcome,
      timestamp: SessionStorageFixtures.timestamp, details: ["status": .string(status)])
    let manifest = try SessionManifestDocument(
      data: SessionStorageFixtures.manifest(
        sessionID: fixture.layout.sessionID, jobID: fixture.layout.jobID, status: status))
    return TerminalPersistenceFixture(
      finalizer: SessionStorageTerminalFinalizer(
        audit: audit, manifestPublisher: publisher),
      auditRecord: record,
      manifest: manifest
    )
  }

  fileprivate func appendTerminalJournal(
    layout: SessionLayout,
    manifest: SessionManifestDocument,
    prefix: String,
    executionMode: String,
    executionAuthority: String = "standardAgent",
    coreBaseline: String = "CORE-2.0.0",
    terminalState: JobState,
    runningEvents: (FileDurableJournal, inout Int) throws -> Void
  ) throws {
    let journal = try FileDurableJournal(url: layout.journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "\(prefix)-created", sequence: 0,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, executionMode: executionMode,
        executionAuthority: executionAuthority, coreBaseline: coreBaseline))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(prefix)-preflight", sequence: 1,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .queued, to: .preflight,
        reason: "Manifest journal binding fixture"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(prefix)-running", sequence: 2,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .preflight, to: .running,
        reason: "Manifest journal binding fixture"))
    var sequence = 3
    try runningEvents(journal, &sequence)
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(prefix)-finalizing", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .running, to: .finalizing,
        reason: "Manifest journal binding fixture"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "\(prefix)-terminal", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, from: .finalizing, to: terminalState,
        reason: "Manifest journal binding fixture"))
    sequence += 1
    try journal.appendAndSynchronize(
      JournalEvent(
        eventID: "\(prefix)-finalized", sequence: sequence,
        sessionID: layout.sessionID, jobID: layout.jobID,
        timestamp: SessionStorageFixtures.timestamp, kind: .finalized,
        payload: [
          "terminalStatus": .string(terminalState.rawValue),
          "manifestSha256": .string(manifest.sha256),
          "outcomeCertainty": .string("confirmed"),
        ]))
  }

  fileprivate func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  fileprivate func executionStep(
    id: String,
    kind: String,
    effect: String,
    cancellation: String,
    bindingRequirement: String,
    arguments: [String: JSONValue],
    compensationDescriptors: [JSONValue] = [],
    disposition: String = "skipped",
    outcomeCertainty: String = "notApplicable",
    semanticResult: String = "notRun"
  ) throws -> JSONValue {
    let argumentsData = try canonicalData(.object(arguments))
    return .object([
      "id": .string(id),
      "kind": .string(kind),
      "effect": .string(effect),
      "cancellation": .string(cancellation),
      "bindingRequirement": .string(bindingRequirement),
      "arguments": .object(arguments),
      "argumentsHash": .string(sha256(argumentsData)),
      "compensationDescriptors": .array(compensationDescriptors),
      "sourceStepId": .null,
      "compensationTrigger": .null,
      "disposition": .string(disposition),
      "outcomeCertainty": .string(outcomeCertainty),
      "bindingRevision": bindingRequirement == "confirmedDevice" ? .integer(1) : .null,
      "semanticResult": .string(semanticResult),
    ])
  }

  fileprivate func compensationDescriptor(
    id: String,
    kind: String,
    effect: String,
    cancellation: String,
    bindingRequirement: String,
    trigger: String,
    arguments: [String: JSONValue]
  ) throws -> JSONValue {
    .object([
      "id": .string(id),
      "kind": .string(kind),
      "effect": .string(effect),
      "cancellation": .string(cancellation),
      "bindingRequirement": .string(bindingRequirement),
      "trigger": .string(trigger),
      "arguments": .object(arguments),
      "argumentsHash": .string(sha256(try canonicalData(.object(arguments)))),
    ])
  }

  fileprivate func canonicalData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  fileprivate func recoveryMarkerCanonicalData(_ record: ArtifactRecord) throws -> Data {
    let recordValue = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(record))
    return try canonicalData(
      .object([
        "schemaVersion": .string("1.0.0"),
        "record": recordValue,
      ]))
  }
}
