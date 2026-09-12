import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Provider receipts are fixtures. These tests exercise the real Job, Journal,
/// publication and Session storage owners; they are not hardware acceptance.
final class RuntimeDeviceSessionPublicationContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "device-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }

  func testVerifiedDeviceJobPublishesWithoutInventingHDCServerFacts() async throws {
    let harness = try DevicePublicationHarness(root: root)
    let job = try await harness.run()
    XCTAssertEqual(job.state, "succeeded")
    XCTAssertEqual(job.sessionPublication.state, .published)
    XCTAssertEqual(try harness.owner.status().sessionCount, 1)
    try writeSchemaFixture(
      "hdc",
      data: Data(
        contentsOf: harness.sessions.appending(
          path: "2026/07/session-\(job.jobID)/manifest.json")))
  }

  /// Export actual current Swift owner snapshots from the existing isolated
  /// provider fixture. These bytes prove storage/reader parity, not hardware
  /// acceptance, fresh device facts or Runtime execution authority.
  func testRustJobPublicationSnapshotsCurrentFixture() async throws {
    let output = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOB_PUBLICATION_FIXTURE"]
    let destination = output.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let destination {
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      try FileManager.default.createDirectory(
        at: destination, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    for refused in [false, true] {
      let name = refused ? "failed" : "published"
      let harness = try DevicePublicationHarness(
        root: root.appending(path: name), firstPublicationRefused: refused)
      let job = try await harness.run()
      XCTAssertEqual(job.state, "succeeded")
      XCTAssertEqual(job.sessionPublication.state, refused ? .failed : .published)
      let directory = harness.state.appending(path: "jobs/\(job.jobID)")
      guard case .readable(let record) = RuntimeJobRecord.state(in: directory) else {
        return XCTFail("actual Swift Job producer left no readable snapshot")
      }
      XCTAssertNotNil(record.admissionEvidence)
      XCTAssertNotNil(record.evidencePreflight)
      XCTAssertNotNil(record.evidenceObservation)
      XCTAssertNotNil(record.sessionPublicationRecord)
      let bytes = try Data(contentsOf: directory.appending(path: "job-record.json"))
      XCTAssertEqual(try record.durableData(), bytes)
      let show = try RuntimeJobReadProjection.show(record, status: job)
      if let destination {
        let sample = destination.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
          at: sample, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        try bytes.write(to: sample.appending(path: "job-record.json"))
        try PortableCanonicalJSON.canonicalBytes(show).write(to: sample.appending(path: "show.json"))
        let responses: JSONValue = .array([
          .object(["method": .string("job.show"),
            "params": .object(["jobId": .string(job.jobID)]), "result": show]),
          .object(["method": .string("job.status"),
            "params": .object(["jobId": .string(job.jobID)]),
            "result": try RuntimeJobReadProjection.status(job)]),
        ])
        try PortableCanonicalJSON.canonicalBytes(responses).write(
          to: sample.appending(path: "swift-results.json"))
        // All owner transactions above have completed. Copy the complete SQLite
        // family without checkpointing or modifying the producer's bytes.
        try FileManager.default.copyItem(
          at: harness.state, to: sample.appending(path: "jobs-state"))
      }
    }
  }

  func testDefaultExportRedactsDeviceIdentityAndRemainsReadable() async throws {
    let harness = try DevicePublicationHarness(root: root)
    let job = try await harness.run()
    let destination = root.appending(path: "export")
    guard
      case .object(let preview) = try harness.owner.previewSessionExport(
        sessionID: "session-\(job.jobID)", destinationPath: destination.path, allowSensitive: false),
      case .string(let id)? = preview["previewId"],
      case .string(let digest)? = preview["previewDigest"]
    else { return XCTFail("export preview failed") }
    _ = try harness.owner.applySessionExport(previewID: id, previewDigest: digest)
    let data = try Data(contentsOf: destination.appending(path: "manifest.json"))
    _ = try SessionManifestDocument(data: data)
    try writeSchemaFixture("redacted", data: data)
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(text.contains(String(repeating: "a", count: 32)))
    XCTAssertFalse(text.contains("TGT-PUBLICATION"))
  }

  func testMissingOrInconsistentJobLocalFactsRefuseComposition() async throws {
    let harness = try DevicePublicationHarness(root: root, firstPublicationRefused: true)
    let job = try await harness.run()
    let directory = harness.state.appending(path: "jobs/\(job.jobID)")
    guard case .readable(let original) = RuntimeJobRecord.state(in: directory) else {
      return XCTFail("missing durable record")
    }
    let replay = try DurableJournalRecovery.inspect(url: directory.appending(path: "journal.jsonl"))
    _ = try RuntimeSessionManifestComposer.compose(
      record: original, replay: replay, completedAtUTC: Self.now)
    let paths: [[String]] = [
      ["evidenceObservation"], ["admissionEvidence"],
      ["evidenceObservation", "targetID"], ["evidenceObservation", "bindingRevision"],
      ["evidenceObservation", "stableIdentitySHA256"], ["evidenceObservation", "toolSHA256"],
      ["evidenceObservation", "providerID"], ["evidenceObservation", "confirmedAtUTC"],
    ]
    for path in paths {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
      if path.count == 1 {
        object.removeValue(forKey: path[0])
      } else {
        var fields = try XCTUnwrap(object[path[0]] as? [String: Any])
        XCTAssertNotNil(fields.removeValue(forKey: path[1]), "fixture key \(path)")
        object[path[0]] = fields
      }
      do {
        let changed = try JSONDecoder().decode(
          RuntimeJobRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(
          try RuntimeSessionManifestComposer.compose(
            record: changed, replay: replay, completedAtUTC: Self.now), "\(path)")
      } catch { /* A required field may be rejected by the record decoder first. */  }
    }
  }

  func testHistoricalPreSealFailureRetriesOnceAcrossRestartWithoutDispatch() async throws {
    let harness = try DevicePublicationHarness(root: root, firstPublicationRefused: true)
    let job = try await harness.run()
    XCTAssertEqual(job.sessionPublication.state, .failed)
    let before = harness.dispatcher.dispatchCount
    let retried = try await harness.engine.reconcile(jobID: job.jobID)
    XCTAssertEqual(retried.sessionPublication.state, .published)
    XCTAssertEqual(harness.dispatcher.dispatchCount, before)
    let generation = try harness.owner.status().catalogGeneration
    let restarted = try DevicePublicationHarness(root: root)
    let repeated = try await restarted.engine.reconcile(jobID: job.jobID)
    XCTAssertEqual(repeated.sessionPublication, retried.sessionPublication)
    XCTAssertEqual(restarted.dispatcher.dispatchCount, 0)
    XCTAssertEqual(try restarted.owner.status().catalogGeneration, generation)
    XCTAssertEqual(try restarted.owner.status().sessionCount, 1)
  }

  func testArkForgeConsumedAuthorityAuditAndDestructiveManifestStayClosed() async throws {
    let harness = try DevicePublicationHarness(root: root, firstPublicationRefused: true)
    let job = try await harness.run()
    let directory = harness.state.appending(path: "jobs/\(job.jobID)")
    guard case .readable(var record) = RuntimeJobRecord.state(in: directory) else {
      return XCTFail("missing durable record")
    }
    let observation = try XCTUnwrap(record.evidenceObservation)
    var encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    encoded["providerID"] = "arkforge"
    encoded["materializedPlanDigest"] = String(repeating: "d", count: 64)
    record = try JSONDecoder().decode(
      RuntimeJobRecord.self, from: JSONSerialization.data(withJSONObject: encoded))
    record.evidenceObservation = RuntimeEvidenceObservation(
      targetID: observation.targetID, bindingRevision: observation.bindingRevision,
      stableIdentitySHA256: observation.stableIdentitySHA256, model: observation.model,
      firmware: observation.firmware, transport: observation.transport, providerID: "arkforge",
      toolVersion: "1.0.0", toolSHA256: String(repeating: "c", count: 64),
      confirmedAtUTC: observation.confirmedAtUTC, confirmationMethod: "machineReadback",
      preflightSteps: observation.preflightSteps)
    let plan = String(repeating: "d", count: 64)
    record.admissionEvidence = RuntimeAdmissionEvidence(
      kind: .runtimeCapability, reference: "CAP-FIXTURE", admittedAtUTC: Self.now,
      validUntilUTC: "2026-07-29T01:00:00Z", consumptionFingerprintSHA256: plan,
      runtimeCapabilityCorrelation: RuntimeCapabilityEvidenceCorrelation(
        reservationID: "reservation-fixture", useOrdinal: 1, planDigestSHA256: plan,
        stepSetDigestSHA256: plan, targetBindingDigestSHA256: plan, artifactSHA256: nil))
    let replay = try DurableJournalRecovery.inspect(url: directory.appending(path: "journal.jsonl"))
    let document = try RuntimeSessionManifestComposer.compose(
      record: record, replay: replay, completedAtUTC: Self.now)
    var manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: document.canonicalData) as? [String: Any])
    XCTAssertEqual(
      (manifest["toolchain"] as? [String: Any])?["providerIdentity"] as? String, "arkforge")
    let arguments: [String: JSONValue] = [
      "providerOperationId": .string("provider.flash"), "partition": .string("system"),
      "imageArtifactId": .string("image-system"), "imageSha256": .string(plan),
      "imageSize": .integer(1), "confirmationId": .string("runtimeE2Admission"),
      "safeBoundaryId": .string("safe-fixture"),
    ]
    let argumentData = try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments))
    let flash: [String: Any] = [
      "id": "flash-fixture", "kind": "flashPartition", "effect": "destructive",
      "cancellation": "criticalNonInterruptible", "bindingRequirement": "confirmedDevice",
      "arguments": try JSONSerialization.jsonObject(with: argumentData),
      "argumentsHash": SHA256Hex.string(of: argumentData), "compensationDescriptors": [],
      "sourceStepId": NSNull(), "compensationTrigger": NSNull(), "bindingRevision": 7,
      "disposition": "executed", "outcomeCertainty": "confirmed", "semanticResult": "succeeded",
    ]
    manifest["steps"] = [flash]
    _ = try SessionManifestDocument(data: JSONSerialization.data(withJSONObject: manifest))
    try writeSchemaFixture("arkforge", data: JSONSerialization.data(withJSONObject: manifest))
    let valid = manifest
    for key in [
      "kind", "reference", "admittedAtUtc", "validUntilUtc", "consumptionFingerprintSha256",
      "reservationId", "useOrdinal", "planDigest", "stepSetDigest", "targetBindingDigest",
      "artifactDigest",
    ] {
      var audit = try XCTUnwrap(valid["runtimeAuthority"] as? [String: Any])
      audit.removeValue(forKey: key)
      manifest = valid
      manifest["runtimeAuthority"] = audit
      XCTAssertThrowsError(
        try SessionManifestDocument(data: JSONSerialization.data(withJSONObject: manifest)), key)
    }
    encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    encoded["materializedPlanDigest"] = String(repeating: "e", count: 64)
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RuntimeJobRecord.self, from: JSONSerialization.data(withJSONObject: encoded)))
  }

  func testConflictingJournalTargetAndUnknownOutcomeRefusePublication() async throws {
    let harness = try DevicePublicationHarness(root: root, firstPublicationRefused: true)
    let job = try await harness.run()
    let directory = harness.state.appending(path: "jobs/\(job.jobID)")
    guard case .readable(let record) = RuntimeJobRecord.state(in: directory) else {
      return XCTFail("missing fixture record")
    }
    let lines = try String(contentsOf: directory.appending(path: "journal.jsonl"), encoding: .utf8)
      .split(separator: "\n").map {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      }
    let index = try XCTUnwrap(
      lines.firstIndex { row in
        row["kind"] as? String == "stepIntent"
          && ((row["payload"] as? [String: Any])?["target"] as? [String: Any])?["scope"] as? String
            == "device"
      })
    for field in [
      "targetId", "connectKey", "identitySnapshotHash", "bindingRevision", "outcomeCertainty",
    ] {
      var changed = lines
      if field == "bindingRevision" {
        changed[index][field] = 99
      } else if field == "outcomeCertainty" {
        let outcome = try XCTUnwrap(changed.firstIndex { $0["kind"] as? String == "stepOutcome" })
        var payload = try XCTUnwrap(changed[outcome]["payload"] as? [String: Any])
        payload[field] = "outcomeUnknown"
        changed[outcome]["payload"] = payload
      } else {
        var payload = try XCTUnwrap(changed[index]["payload"] as? [String: Any])
        var target = try XCTUnwrap(payload["target"] as? [String: Any])
        target[field] =
          field == "identitySnapshotHash" ? String(repeating: "f", count: 64) : "conflicting-target"
        payload["target"] = target
        changed[index]["payload"] = payload
      }
      let data = try changed.reduce(into: Data()) { output, row in
        output.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
        output.append(0x0a)
      }
      XCTAssertThrowsError(
        try RuntimeSessionManifestComposer.compose(
          record: record, replay: DurableJournalRecovery.inspect(data: data),
          completedAtUTC: Self.now), field)
    }
  }

  func testReconcileDoesNotAdoptMarkerlessPartialOrUnknownPublication() async throws {
    for variant in ["markerless", "checkpoint", "proposalFile", "unknown"] {
      let harness = try DevicePublicationHarness(
        root: root.appending(path: variant), firstPublicationRefused: true)
      let job = try await harness.run()
      let directory = harness.state.appending(path: "jobs/\(job.jobID)")
      guard case .readable(var record) = RuntimeJobRecord.state(in: directory) else {
        return XCTFail("missing fixture record")
      }
      switch variant {
      case "markerless": record.sessionPublicationRecord = nil
      case "checkpoint":
        record.sessionPublicationRecord?.checkpointSeal = RuntimeSessionPublicationSeal(
          sha256: String(repeating: "b", count: 64), byteCount: "1", lastSequence: 0)
      case "proposalFile":
        try Data("{}".utf8).write(to: directory.appending(path: "session-manifest.proposal.json"))
      default:
        record.sessionPublicationRecord?.failure = RuntimeSessionPublicationFailureRecord(
          code: "sourceIntegrityFailed", certainty: "outcomeUnknown", detail: "fixture")
      }
      try RuntimeAdmissionService(stateDirectory: harness.state).persist(record, at: Self.now)
      let before = try Data(contentsOf: directory.appending(path: "journal.jsonl"))
      let count = harness.dispatcher.dispatchCount
      let result = try await harness.engine.reconcile(jobID: job.jobID)
      XCTAssertNotEqual(result.sessionPublication.state, .published, variant)
      XCTAssertEqual(harness.dispatcher.dispatchCount, count, variant)
      XCTAssertEqual(try harness.owner.status().sessionCount, 0, variant)
      XCTAssertEqual(
        try Data(contentsOf: directory.appending(path: "journal.jsonl")), before, variant)
    }
  }

  func testOptInHistoricalDeviceSourceComposesWithoutRuntimeWrites() async throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_HISTORICAL_DEVICE_JOB"] else {
      throw XCTSkip("opt-in read-only historical source check; not hardware acceptance")
    }
    let directory = URL(filePath: path)
    guard case .readable(let record) = RuntimeJobRecord.state(in: directory) else {
      return XCTFail("unreadable historical source")
    }
    let journal = directory.appending(path: "journal.jsonl")
    let before = try Data(contentsOf: journal)
    let replay = try DurableJournalRecovery.inspect(url: journal)
    _ = try RuntimeSessionManifestComposer.compose(
      record: record, replay: replay, completedAtUTC: try XCTUnwrap(record.finishedAtUTC))
    let copy = root.appending(path: "historical-source-copy")
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    try before.write(to: copy.appending(path: "journal.jsonl"))
    let owner = try RuntimeSessionStorageStore(
      ownerRoot: root.appending(path: "offline-owner"),
      defaultSessionsRoot: root.appending(path: "offline-sessions"))
    let result = await RuntimeSessionPublicationWriter(owner: owner).publish(
      RuntimeSessionPublicationRequest(
        record: record, journalURL: copy.appending(path: "journal.jsonl"),
        jobDirectory: copy, nowUTC: try XCTUnwrap(record.finishedAtUTC)))
    XCTAssertEqual(result.record.fact.state, .published)
    XCTAssertEqual(try owner.status().sessionCount, 1)
    XCTAssertEqual(try Data(contentsOf: journal), before)
  }

  private func writeSchemaFixture(_ name: String, data: Data) throws {
    guard
      let directory = ProcessInfo.processInfo.environment["ARKDECK_DEVICE_SESSION_SCHEMA_FIXTURES"]
    else { return }
    try data.write(to: URL(filePath: directory).appending(path: name + ".json"))
  }

  private static let now = DevicePublicationHarness.now

}

private final class DevicePublicationDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var dispatchCount: Int { lock.withLock { count } }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    lock.withLock { count += 1 }
    let output: String
    switch plan.action {
    case .hdc(.observeTool): output = "Ver: 3.2.0f\n"
    case .hdc(.observeServer):
      output = "Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n"
    case .hdc(.observeDevice), .hdc(.listDeviceCandidates):
      output = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n"
    case .hdc(.queryProperty(.productName)): output = "OpenHarmony Reference Device\n"
    case .hdc(.queryProperty(.fullBuildVersion)): output = "OpenHarmony-4.1-release\n"
    default: throw RuntimeDispatchFailure.failed("unexpected fixture action")
    }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(output.utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.001)
  }
}

private struct DevicePublicationFacts: HDCObservationFactsPort {
  func currentFacts(targetID: String) async throws -> ProviderFacts {
    ProviderFacts(
      providerID: "hdc", toolVersion: "3.2.0f", toolSHA256: String(repeating: "b", count: 64),
      serverFacts: [:], targetID: targetID, bindingRevision: 7,
      deviceIdentitySHA256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
      executionConnectKey: String(repeating: "a", count: 32),
      deviceModel: nil, deviceMode: "hdc", buildFingerprint: nil, transport: nil,
      profileID: "openharmony-standard@1", collectedAtUTC: DevicePublicationHarness.now,
      sourceObservedAtUTC: DevicePublicationHarness.now)
  }
}

private struct DevicePublicationHarness {
  static let now = "2026-07-29T00:00:00Z"
  let engine: RuntimeJobEngine
  let owner: RuntimeSessionStorageStore
  let writer: RuntimeSessionPublicationWriter
  let dispatcher = DevicePublicationDispatcher()
  let state: URL
  let sessions: URL

  init(root: URL, firstPublicationRefused: Bool = false) throws {
    state = root.appending(path: "engine", directoryHint: .isDirectory)
    sessions = root.appending(path: "Sessions", directoryHint: .isDirectory)
    owner = try RuntimeSessionStorageStore(
      ownerRoot: root.appending(path: "owner", directoryHint: .isDirectory),
      defaultSessionsRoot: sessions)
    writer = RuntimeSessionPublicationWriter(owner: owner)
    engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state,
        sessionPublicationWriter:
          firstPublicationRefused ? DevicePublicationInitialRefusal(writer: writer) : writer),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: DevicePublicationFacts())
      ]), dispatcher: dispatcher,
      capabilityStore: RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities")),
      artifactStore: RuntimeArtifactStore(
        rootURL: root.appending(path: "artifacts"), nowUTC: { Self.now }),
      nowUTC: { Self.now })
  }

  func run() async throws -> RuntimeJobStatus {
    let request = try RuntimeOperationRequest(
      requestID: "req-device-session", idempotencyKey: "idem-device-session",
      target: DurableTargetReference(targetID: "TGT-PUBLICATION", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "observe.device", version: 1), inputs: [:])
    let accepted = try await engine.submit(JSONEncoder().encode(request))
    return try await engine.run(jobID: accepted.jobID)
  }
}

/// Simulates the previous composer's pre-seal refusal. It changes only the
/// argument copy; the Engine persists its original complete facts and the
/// real writer creates the confirmed failure marker.
private final class DevicePublicationInitialRefusal: RuntimeSessionPublicationWriting,
  @unchecked Sendable
{
  let writer: RuntimeSessionPublicationWriter
  private let lock = NSLock()
  private var first = true
  init(writer: RuntimeSessionPublicationWriter) { self.writer = writer }
  func publish(_ request: RuntimeSessionPublicationRequest) async
    -> RuntimeSessionPublicationOutcome
  {
    let refuse = lock.withLock {
      let value = first
      first = false
      return value
    }
    guard refuse else { return await writer.publish(request) }
    var record = request.record
    record.evidenceObservation = nil
    return await writer.publish(
      RuntimeSessionPublicationRequest(
        record: record, journalURL: request.journalURL,
        jobDirectory: request.jobDirectory, nowUTC: request.nowUTC))
  }
}
