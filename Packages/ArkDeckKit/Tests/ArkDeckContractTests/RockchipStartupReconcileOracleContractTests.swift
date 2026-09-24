// Shared Swift oracle for the Rust daemon's Rockchip start-up reconciliation
// (CHG-2026-074, TASK-XPA-017, milestone M4).

import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// What Swift's daemon does with the Rockchip state before its engine starts
/// (`main.swift` 404–460), step for step:
///
/// - in the production layout (a state directory `Agentd` below `ArkDeck`),
///   the Target carried along the binding's adjacent lineage edge, the
///   binding's Loader recovery proof taken, and a line when the Target moved;
///   a binding it cannot follow printed as needing Loader onboarding;
/// - in every layout, `ProductRockchipTargetAliasReconciler` proving, from
///   terminal Flash history only, that an HDC address adopted as a second
///   Target is the post-flash face of the Loader-bound one, and appending
///   that relation; any partial proof printed as fail-closed.
///
/// Each scenario builds its own `ArkDeck` root with Swift's own stores and
/// Job writers, records every file of it (`inputs/<scenario>/…`), runs the
/// steps, and records the lines printed, the recovery proof, the error that
/// stops the start (a binding that cannot be read), and the Target document
/// afterwards (`outputs/<scenario>/…`). No device, daemon or engine is
/// involved.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ROCKCHIP_STARTUP_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class RockchipStartupReconcileOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/rockchip-startup", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_ROCKCHIP_STARTUP_RECORD"
  private static let base = URL(
    filePath: "/private/tmp/arkdeck-rockchip-startup-oracle", directoryHint: .isDirectory)

  private static let hdcKey = "original-hdc-address"
  private static let loaderSerial = "loader-serial"
  private static let aliasKey = "post-flash-hdc-address"

  private var files: [String: Data] = [:]
  private var scenarios: [JSONValue] = []

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - The start-up steps, as `main.swift` runs them

  private struct Outcome {
    var lines: [String] = []
    var recovery: JSONValue = .null
    var failure: String?
  }

  private static func startUp(state: URL) -> Outcome {
    var outcome = Outcome()
    do {
      let targetStore = try RuntimeTargetStore(
        directoryURL: state.appending(path: "targets", directoryHint: .isDirectory))
      let rockchipRoot = state.deletingLastPathComponent()
      if state.lastPathComponent == "Agentd",
        rockchipRoot.lastPathComponent == "ArkDeck",
        let binding = try RockchipProductBindingStore(rootURL: rockchipRoot).loadIfPresent()
      {
        do {
          if let advance = try binding.runtimeTargetLineageAdvance() {
            let result = try targetStore.advanceBindingLineage(advance)
            if let proof = try binding.loaderBindingRecoveryProof() {
              outcome.recovery = .object([
                "targetId": .string(result.record.targetID),
                "previousRevision": .integer(Int64(proof.previousRevision)),
                "currentRevision": .integer(Int64(proof.currentRevision)),
                "selectionEvidenceSha256": .string(proof.selectionEvidenceSHA256),
              ])
            }
            if result.updated {
              outcome.lines.append(
                "advanced runtime target \(result.record.targetID) to Rockchip binding revision "
                  + "\(result.record.bindingRevision)")
            }
          }
        } catch {
          outcome.lines.append("Rockchip binding requires Runtime Loader onboarding: \(error)")
        }
      }
      do {
        if let resolution = try ProductRockchipTargetAliasReconciler(
          targetStore: targetStore,
          applicationSupportRoot: rockchipRoot,
          stateDirectory: state
        ).reconcileIfProven() {
          outcome.lines.append(
            "resolved historical target alias \(resolution.aliasTargetID) to "
              + "\(resolution.canonicalTargetID) via \(resolution.resolutionID)")
        }
      } catch {
        outcome.lines.append("Rockchip target alias remains fail-closed: \(error)")
      }
    } catch {
      outcome.failure = "\(error)"
    }
    return outcome
  }

  // MARK: - Recording

  /// Every file below `root`, relative to it, with its mode.
  private static func tree(_ root: URL) throws -> [(String, Data, Int)] {
    var result: [(String, Data, Int)] = []
    let manager = FileManager.default
    for path in try manager.subpathsOfDirectory(atPath: root.path).sorted() {
      let url = root.appending(path: path)
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.EIO) }
      guard metadata.st_mode & S_IFMT == S_IFREG else { continue }
      result.append((path, try Data(contentsOf: url), Int(metadata.st_mode & 0o777)))
    }
    return result
  }

  /// Builds a scenario with `build(root, state)`, records its inputs, starts
  /// up once or `runs` times, and records each run's outcome and Target
  /// document.
  private func scenario(
    _ name: String, state stateName: String = "Agentd", runs: Int = 1,
    _ build: (URL, URL) throws -> Void
  ) throws {
    let root = Self.base.appending(path: name, directoryHint: .isDirectory)
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
    let state = root.appending(path: stateName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: state.appending(path: "targets", directoryHint: .isDirectory),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for directory in [root, state, state.appending(path: "targets")] {
      guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    }
    try build(root, state)
    var inputs: [JSONValue] = []
    for (path, bytes, mode) in try Self.tree(root) {
      files["inputs/\(name)/\(path)"] = bytes
      inputs.append(.object(["path": .string(path), "mode": .string(String(mode, radix: 8))]))
    }
    var outcomes: [JSONValue] = []
    for run in 1...runs {
      let outcome = Self.startUp(state: state)
      let targets = state.appending(path: "targets/targets.json")
      let recorded: JSONValue
      if FileManager.default.fileExists(atPath: targets.path) {
        let path = "outputs/\(name)/run-\(run)/targets.json"
        files[path] = try Data(contentsOf: targets)
        recorded = .string(path)
      } else {
        recorded = .null
      }
      outcomes.append(
        .object([
          "lines": .array(outcome.lines.map(JSONValue.string)),
          "recovery": outcome.recovery,
          "failure": outcome.failure.map(JSONValue.string) ?? .null,
          "targets": recorded,
        ]))
    }
    scenarios.append(
      .object([
        "name": .string(name), "stateDirectory": .string(stateName),
        "inputs": .array(inputs), "runs": .array(outcomes),
      ]))
  }

  // MARK: - Fixtures

  private static func lineageEvidence(
    loader: String = loaderSerial, previous: String = hdcKey, previousRevision: Int = 1
  ) -> [String] {
    [
      "product:e0-iokit-single-loader-readback",
      "identity:serial-sha256=\(digest(loader))",
      "identity:previous-serial-sha256=\(digest(previous))",
      "binding:previous-revision=\(previousRevision)",
      "binding:previous-usb-topology=42",
      "identity:hdc-normal-alias-sha256=\(digest(previous))",
      "binding:hdc-normal-alias-usb-topology=42",
      "rebind:user-selection-sha256=\(String(repeating: "e", count: 64))",
    ]
  }

  private static func installBinding(
    root: URL, revision: Int, serial: String, evidence: [String]
  ) throws {
    _ = try RockchipProductBindingStore(rootURL: root).install(
      RockchipProductBindingSnapshot(
        revision: revision, serial: serial, usbTopology: "42", evidence: evidence))
  }

  private static func adopt(
    _ store: RuntimeTargetStore, key: String, identity: String? = nil, at time: String
  ) throws -> RuntimeTargetRecord {
    try store.adopt(
      stableIdentitySHA256: identity ?? digest(key), connectKey: key,
      toolVersion: "3.2.0f", nowUTC: time
    ).record
  }

  /// Swift's own alias fixture (`RockchipTargetAliasReconciliationContractTests`):
  /// a Target adopted at the board's HDC address and advanced to its Loader,
  /// the binding of that lineage, the post-flash HDC address adopted as a
  /// second Target, a Job left outcome-unknown on it, the complete Flash that
  /// proved the address, and the post-flash route it published.
  private struct AliasOptions {
    var unknownStepID = "enter-loader-mode"
    var aliasAdoptedAt = "2026-08-08T00:01:00Z"
    var aliasIdentity: String? = nil
    var flash = FlashOptions()
  }

  private struct FlashOptions {
    var providerID = "rockchip"
    var capability = true
    var steps = [
      "enter-loader-mode", "flash-partitions", "verify-flash-readback",
      "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
    ]
    var terminal = true
  }

  private func aliasFixture(root: URL, state: URL, _ options: AliasOptions) throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: state.appending(path: "targets", directoryHint: .isDirectory))
    let original = try Self.adopt(targetStore, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
    let canonical = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: original.stablePhysicalIdentitySHA256,
        previousRevision: 1,
        currentStableIdentitySHA256: Self.digest(Self.loaderSerial), currentRevision: 2)
    ).record
    try Self.installBinding(
      root: root, revision: canonical.bindingRevision, serial: Self.loaderSerial,
      evidence: Self.lineageEvidence())
    let alias = try Self.adopt(
      targetStore, key: Self.aliasKey, identity: options.aliasIdentity,
      at: options.aliasAdoptedAt)
    try writeUnknownJob(
      state: state, jobID: "job-22222222222222222222222222222222", target: alias,
      stepID: options.unknownStepID, timestamp: "2026-08-08T00:02:00Z")
    try writeFlashJob(
      state: state, jobID: "job-11111111111111111111111111111111", target: canonical,
      startedAtUTC: "2026-08-08T00:05:00Z", finishedAtUTC: "2026-08-08T00:10:00Z",
      options.flash)
    _ = try RockchipPostFlashHDCBindingStore(rootURL: root).publish(
      RockchipPostFlashHDCBinding(
        targetID: canonical.targetID,
        bindingRevision: canonical.bindingRevision,
        stableLoaderIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        previousHDCIdentitySHA256: original.stablePhysicalIdentitySHA256,
        hdcIdentitySHA256: Self.digest(Self.aliasKey),
        hdcConnectKey: Self.aliasKey,
        usbTopology: "42",
        productModel: "ohos",
        buildVersion: "OpenHarmony-7.0.0.37",
        jobID: "job-11111111111111111111111111111111",
        establishedAtUTC: "2026-08-08T00:09:00Z"),
      expectedPreviousHDCIdentitySHA256: original.stablePhysicalIdentitySHA256)
  }

  private func writeUnknownJob(
    state: URL, jobID: String, target: RuntimeTargetRecord,
    stepID: String, timestamp: String
  ) throws {
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
    let journal = try FileDurableJournal(url: directory.appending(path: "journal.jsonl"))
    var sequence = try appendRunningPrefix(journal: journal, record: record, timestamp: timestamp)
    try journal.appendAndSynchronize(
      try stepIntent(
        record: record, step: try workflowStep(stepID), eventID: "intent-\(stepID)",
        sequence: sequence, timestamp: timestamp))
    sequence += 1
    try journal.appendAndSynchronize(
      try JournalEvent.stateTransition(
        eventID: "waiting-\(jobID)", sequence: sequence,
        sessionID: record.sessionID, jobID: jobID, timestamp: timestamp,
        from: .running, to: .waitingForRecovery, reason: "fixture outcome unknown",
        schemaVersion: JournalEvent.schemaVersion))
  }

  private func writeFlashJob(
    state: URL, jobID: String, target: RuntimeTargetRecord,
    startedAtUTC: String, finishedAtUTC: String, _ options: FlashOptions
  ) throws {
    let request = try flashRequest(jobID: jobID, target: target)
    let planDigest = String(repeating: "a", count: 64)
    let correlation = RuntimeCapabilityEvidenceCorrelation(
      reservationID: request.idempotencyKey, useOrdinal: 1,
      planDigestSHA256: planDigest,
      stepSetDigestSHA256: String(repeating: "b", count: 64),
      targetBindingDigestSHA256: RuntimeJobRecord.sha256Hex(
        Data("\(target.stablePhysicalIdentitySHA256)\n\(target.bindingRevision)".utf8)),
      artifactSHA256: String(repeating: "d", count: 64))
    let evidence = RuntimeAdmissionEvidence(
      kind: .runtimeCapability, reference: "CAP-RT-ALIAS-FIXTURE",
      admittedAtUTC: startedAtUTC, validUntilUTC: "2026-12-31T00:00:00Z",
      consumptionFingerprintSHA256: String(repeating: "e", count: 64),
      runtimeCapabilityCorrelation: correlation)
    var record = RuntimeJobRecord(
      jobID: jobID, request: request, operationReference: "flash.dayu200",
      catalogDigest: RuntimeOperationCatalog.catalogDigest,
      providerID: options.providerID, createdAtUTC: startedAtUTC,
      actualEffect: "destructive", admissionEvidence: options.capability ? evidence : nil,
      materializedPlanDigest: planDigest,
      materializedStableTargetIdentitySHA256: target.stablePhysicalIdentitySHA256,
      materializedBindingRevision: target.bindingRevision)
    record.originalSubmissionRequest = record.request
    record.state = JobState.succeeded.rawValue
    record.startedAtUTC = startedAtUTC
    record.finishedAtUTC = finishedAtUTC
    let directory = try jobDirectory(state: state, jobID: jobID)
    try record.persist(into: directory)
    let journal = try FileDurableJournal(url: directory.appending(path: "journal.jsonl"))
    var sequence = try appendRunningPrefix(
      journal: journal, record: record, timestamp: startedAtUTC)
    for stepID in options.steps {
      let intentID = "intent-\(stepID)"
      try journal.appendAndSynchronize(
        try stepIntent(
          record: record, step: try workflowStep(stepID), eventID: intentID,
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
    guard options.terminal else { return }
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
      throw NSError(domain: "startup-reconcile-fixture", code: 1)
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
    for url in [state.appending(path: "jobs"), directory] {
      guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    }
    return directory
  }

  // MARK: - The oracle

  func testSwiftReconcilesTheRockchipStateAtStartUpAsTheRustDaemonReplays() throws {
    let manager = FileManager.default
    try? manager.removeItem(at: Self.base)
    defer { try? manager.removeItem(at: Self.base) }

    // The binding's lineage, in the production layout.
    try scenario("lineage.noBinding") { _, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
    }
    try scenario("lineage.revisionOne") { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      try Self.installBinding(
        root: root, revision: 1, serial: Self.hdcKey,
        evidence: [
          "product:e0-iokit-single-dayu200-readback",
          "identity:serial-sha256=\(Self.digest(Self.hdcKey))",
        ])
    }
    try scenario("lineage.advanced", runs: 2) { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      try Self.installBinding(
        root: root, revision: 2, serial: Self.loaderSerial, evidence: Self.lineageEvidence())
    }
    try scenario("lineage.customStateDirectory", state: "state") { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      try Self.installBinding(
        root: root, revision: 2, serial: Self.loaderSerial, evidence: Self.lineageEvidence())
    }
    try scenario("lineage.invalid") { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      try Self.installBinding(
        root: root, revision: 2, serial: Self.loaderSerial,
        evidence: Self.lineageEvidence().filter { !$0.hasPrefix("binding:previous-revision=") })
    }
    try scenario("lineage.collides") { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      _ = try Self.adopt(
        store, key: "loader-adopted-key", identity: Self.digest(Self.loaderSerial),
        at: "2026-08-08T00:00:30Z")
      try Self.installBinding(
        root: root, revision: 2, serial: Self.loaderSerial, evidence: Self.lineageEvidence())
    }
    try scenario("lineage.bindingShared") { root, state in
      let store = try RuntimeTargetStore(directoryURL: state.appending(path: "targets"))
      _ = try Self.adopt(store, key: Self.hdcKey, at: "2026-08-08T00:00:00Z")
      try Self.installBinding(
        root: root, revision: 2, serial: Self.loaderSerial, evidence: Self.lineageEvidence())
      guard chmod(root.appending(path: "rockchip-binding.json").path, 0o644) == 0 else {
        throw POSIXError(.EPERM)
      }
    }

    // The post-flash alias, proved only from terminal Flash history.
    try scenario("alias.complete", runs: 2) { root, state in
      try aliasFixture(root: root, state: state, AliasOptions())
    }
    try scenario("alias.noRoute") { root, state in
      try aliasFixture(root: root, state: state, AliasOptions())
      try FileManager.default.removeItem(
        at: root.appending(path: "rockchip-post-flash-hdc-binding.json"))
    }
    try scenario("alias.noAlias") { root, state in
      try aliasFixture(
        root: root, state: state,
        AliasOptions(aliasIdentity: Self.digest("another-identity")))
    }
    try scenario("alias.destructiveUnknown") { root, state in
      try aliasFixture(
        root: root, state: state, AliasOptions(unknownStepID: "flash-partitions"))
    }
    try scenario("alias.unreadableJob") { root, state in
      try aliasFixture(root: root, state: state, AliasOptions())
      let malformed = try jobDirectory(
        state: state, jobID: "job-33333333333333333333333333333333")
      try Data("not-json".utf8).write(to: malformed.appending(path: "job-record.json"))
    }
    try scenario("alias.flashFactsMismatched") { root, state in
      var options = AliasOptions()
      options.flash.providerID = "hdc"
      try aliasFixture(root: root, state: state, options)
    }
    try scenario("alias.noCapability") { root, state in
      var options = AliasOptions()
      options.flash.capability = false
      try aliasFixture(root: root, state: state, options)
    }
    try scenario("alias.unfinishedJournal") { root, state in
      var options = AliasOptions()
      options.flash.terminal = false
      try aliasFixture(root: root, state: state, options)
    }
    try scenario("alias.noReadback") { root, state in
      var options = AliasOptions()
      options.flash.steps.removeAll { $0 == "verify-flash-readback" }
      try aliasFixture(root: root, state: state, options)
    }
    try scenario("alias.chronologyReversed") { root, state in
      try aliasFixture(
        root: root, state: state, AliasOptions(aliasAdoptedAt: "2026-08-08T00:06:00Z"))
    }
    // The relation a first start appended, then a later Flash's route receipt
    // for the very same identities, under a Job this state never recorded:
    // the relation is reused, never proved again from that Job.
    try scenario("alias.republishedRoute") { root, state in
      try aliasFixture(root: root, state: state, AliasOptions())
      _ = try ProductRockchipTargetAliasReconciler(
        targetStore: RuntimeTargetStore(
          directoryURL: state.appending(path: "targets", directoryHint: .isDirectory)),
        applicationSupportRoot: root, stateDirectory: state
      ).reconcileIfProven()
      let routes = RockchipPostFlashHDCBindingStore(rootURL: root)
      let route = try XCTUnwrap(routes.loadIfPresent())
      _ = try routes.publish(
        RockchipPostFlashHDCBinding(
          targetID: route.targetID,
          bindingRevision: route.bindingRevision,
          stableLoaderIdentitySHA256: route.stableLoaderIdentitySHA256,
          previousHDCIdentitySHA256: route.hdcIdentitySHA256,
          hdcIdentitySHA256: route.hdcIdentitySHA256,
          hdcConnectKey: route.hdcConnectKey,
          usbTopology: route.usbTopology,
          productModel: route.productModel,
          buildVersion: route.buildVersion,
          jobID: "job-44444444444444444444444444444444",
          establishedAtUTC: "2026-08-09T00:09:00Z"),
        expectedPreviousHDCIdentitySHA256: route.hdcIdentitySHA256)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["scenarios": .array(scenarios)])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("RockchipStartupReconcileOracleContractTests"),
          "base": .string(Self.base.path),
          "steps": .array([
            .string("RuntimeTargetStore.advanceBindingLineage"),
            .string("RockchipProductBindingSnapshot.loaderBindingRecoveryProof"),
            .string("ProductRockchipTargetAliasReconciler.reconcileIfProven"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
