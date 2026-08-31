import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only lifecycle tests. No device transport or production state is used.
final class ImportLifecycleContractTests: XCTestCase {
  private var root: URL!
  private var artifacts: RuntimeArtifactStore!
  private var targets: RuntimeTargetStore!
  private var target: RuntimeTargetRecord!
  private var capabilities: RuntimeCapabilityStore!
  private let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x61, count: 4092)
  private let clock = RuntimeAgentExecutionContractTests.Clock()
  private let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
  private enum Failure: Error { case fixture }

  actor Gate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
  }
  struct HeldFacts: HDCObservationFactsPort {
    let base: RuntimeAgentExecutionContractTests.Facts
    let gate: Gate
    let fails: Bool
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      await gate.hold()
      if fails { throw Failure.fixture }
      return try await base.currentFacts(targetID: targetID)
    }
  }

  override func setUpWithError() throws {
    guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(temporary) }
    root = URL(filePath: String(cString: temporary)).appending(path: "il-\(UUID().uuidString.prefix(8))")
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
    targets = try RuntimeTargetStore(directoryURL: root.appending(path: "targets"))
    let key = "150100424a544e4600"
    target = try targets.adopt(stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: key),
      connectKey: key, toolVersion: "3.2.0f", nowUTC: "2026-09-01T00:00:00Z").record
    capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
  }
  override func tearDownWithError() throws {
    artifacts = nil; targets = nil; capabilities = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw Failure.fixture }; return fields
  }
  private func imported(_ requestID: String = "lifecycle") async throws -> ArtifactImportProjection {
    let intent = try ArtifactImportIntent(["schemaVersion": .string(ArtifactImportIntent.schemaVersion),
      "importRequestId": .string(requestID), "kind": .string("hap"), "targetId": .string(target.targetID),
      "bindingRevision": .string("1"), "deviceProfile": .null, "name": .string("fixture.hap"),
      "byteCount": .string(String(bytes.count)), "sha256": .string(SHA256Hex.string(of: bytes))])
    let record = try ArtifactImportProjection(await artifacts.beginImport(intent,
      binding: .init(targetID: target.targetID, bindingRevision: 1, stableIdentitySHA256: target.stablePhysicalIdentitySHA256)))
    _ = try await artifacts.appendImport(id: record.id, generation: 1, offset: 0, chunk: bytes, sha256: intent.sha256)
    return try ArtifactImportProjection(await artifacts.commitImport(id: record.id, generation: 1) { _, _ in
      ["kind": .string("hap"), "container": .string("zip")]
    })
  }
  private func lease(_ record: ArtifactImportProjection) throws -> String {
    guard case .object(let receipt)? = try object(record.value)["receipt"], case .string(let value)? = receipt["lease"] else { throw Failure.fixture }
    return value
  }
  private func analyzer() throws -> AnalyzerProvider {
    let executable = ResolvedExecutable(path: "/bin/cat", sha256: SHA256Hex.string(of: try Data(contentsOf: URL(filePath: "/bin/cat"))))
    return try AnalyzerProvider(profiles: [XCTUnwrap(HilogSummaryDerivedAnalyzer.profile(executable: executable, currentDaemon: executable))])
  }
  private func engine(facts: (any HDCObservationFactsPort)? = nil, fault: RuntimeAdmissionFaultInjector = .none) throws -> RuntimeJobEngine {
    try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine"), admissionFaultInjector: fault),
      providers: DeviceProviderRegistry(providers: [try analyzer(), HDCObservationProviderAdapter(
        factsPort: facts ?? RuntimeAgentExecutionContractTests.Facts(targets: targets, clock: clock), hostReceiveRoot: root.appending(path: "receive"))]),
      dispatcher: dispatcher, capabilityStore: capabilities, artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
  }
  private func request(_ importRecord: ArtifactImportProjection, id: String = "job-request", hap: Bool = false) throws -> Data {
    let value = try RuntimeOperationRequest(requestID: id, idempotencyKey: "idem-" + id,
      target: DurableTargetReference(targetID: target.targetID, expectedBindingRevision: hap ? 1 : nil),
      operation: RuntimeOperationReference(id: hap ? "debug.hap" : "analyzer.summarize-hilog", version: 1),
      inputs: hap ? ["hapArtifactLease": .string(try lease(importRecord)), "bundleName": .string("com.example.fixture"), "abilityName": .string("EntryAbility")]
        : ["sourceArtifactRef": .string(try lease(importRecord))])
    return try RuntimeOperationCodec.encodeRequest(value)
  }
  private func conflict(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("expected resourceConflict", file: file, line: line) }
    catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "resourceConflict", file: file, line: line) }
    catch { XCTFail("unexpected \(error)", file: file, line: line) }
  }

  func testReleaseKeepsBytesAndOriginalReceiptThenRejectsNewAcquiresAcrossRestart() async throws {
    let record = try await imported(); let engine = try engine()
    let released = try await engine.releaseImport(id: record.id, generation: 2)
    let projection = try ArtifactImportReleaseProjection(released)
    let metadata = try await artifacts.inspect(jobID: record.id, artifactID: projection.artifactID)
    XCTAssertFalse(metadata.retention.pinned); XCTAssertEqual(metadata.retention.retentionClass, .default)
    let content = try await artifacts.read(jobID: record.id, artifactID: projection.artifactID, maximumBytes: bytes.count, allowSensitive: false)
    XCTAssertEqual(content, bytes)
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-02T00:00:00Z" })
    let restarted = try self.engine()
    let repeated = try await restarted.releaseImport(id: record.id, generation: 2)
    XCTAssertEqual(repeated, released)
    let state = try ArtifactImportProjection(await artifacts.inspectImport(id: record.id).projection)
    XCTAssertEqual(state.state, "released"); XCTAssertEqual(state.generation, 3)
    XCTAssertEqual(try object(state.value)["receipt"], try object(record.value)["receipt"])
    await conflict { _ = try await restarted.releaseImport(id: record.id, generation: 3) }
    do { _ = try await restarted.submit(self.request(record)); XCTFail("released input cannot admit a new Job") } catch { }
    let jobs = try await restarted.listJobs(); XCTAssertTrue(jobs.isEmpty); XCTAssertEqual(dispatcher.dispatchCount, 0)
    let reclaimed = try await artifacts.collectGarbage(activeJobIDs: [], nowUTC: "2026-09-09T00:00:00Z")
    XCTAssertEqual(reclaimed, [projection.artifactID])
    let afterGC = try await restarted.releaseImport(id: record.id, generation: 2)
    XCTAssertEqual(afterGC, released, "GC must not erase release idempotency")
  }

  func testAdmittedJobBlocksReleaseAcrossRestartUntilCancelled() async throws {
    let record = try await imported(); var engine = try engine()
    let resolved = try await artifacts.resolveLease(lease(record))
    let readback = try ArkTraceProfileFileReader.read(path: resolved.fileURL.path, maximumByteCount: resolved.byteCount)
    XCTAssertEqual(readback.data, bytes)
    let accepted = try await engine.submit(request(record))
    await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
    artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
    engine = try self.engine()
    await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
    _ = try await engine.recoverActiveJobs()
    try await engine.requestCancel(jobID: accepted.jobID)
    let released = try await engine.releaseImport(id: record.id, generation: 2)
    _ = try ArtifactImportReleaseProjection(released)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testActivePlanBlocksReleaseAndDropsTransientUseOnSuccessAndFailure() async throws {
    for fails in [false, true] {
      let record = try await imported(fails ? "failing-plan" : "plan")
      let gate = Gate()
      let engine = try engine(facts: HeldFacts(base: .init(targets: targets, clock: clock), gate: gate, fails: fails))
      let data = try request(record, id: fails ? "bad-plan" : "plan", hap: true)
      let planning = Task { try await engine.planOnly(data) }
      for _ in 0..<400 {
        if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5))
      }
      let entered = await gate.entered
      guard entered else { await gate.open(); _ = try? await planning.value; return XCTFail("plan did not reach its facts await") }
      await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
      await gate.open()
      do { _ = try await planning.value; XCTAssertFalse(fails) } catch { XCTAssertTrue(fails, "\(error)") }
      _ = try await engine.releaseImport(id: record.id, generation: 2)
      let jobs = try await engine.listJobs(); XCTAssertTrue(jobs.isEmpty)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testUnknownTerminalLookingJobRetainsItsImportReference() async throws {
    let record = try await imported(); let engine = try engine()
    let accepted = try await engine.submit(request(record))
    let repository = try RuntimeJobRepository(stateDirectory: root.appending(path: "engine"))
    let saved = try XCTUnwrap(repository.job(jobID: accepted.jobID))
    var uncertain = try JSONDecoder().decode(RuntimeJobRecord.self, from: XCTUnwrap(saved.initialRecordData))
    uncertain.state = "failed"; uncertain.outcomeUnknown = true
    try repository.updateJobState(jobID: accepted.jobID, state: uncertain.state, updatedAtUTC: "2026-09-01T00:00:01Z", recordData: uncertain.durableData())
    await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
    let still = try await artifacts.inspectImport(id: record.id); XCTAssertEqual(still.state, "committed")
  }

  func testConcurrentReleaseAndSubmitHaveOnlyTheTwoSerializedOutcomes() async throws {
    for index in 0..<8 {
      let record = try await imported("race-\(index)"); let engine = try engine()
      let data = try request(record, id: "race-\(index)")
      async let submitted: Result<RuntimeJobAcceptance, Error> = Self.result { try await engine.submit(data) }
      async let released: Result<JSONValue, Error> = Self.result { try await engine.releaseImport(id: record.id, generation: 2) }
      let pair = await (submitted, released)
      switch pair {
      case (.success(let accepted), .failure):
        await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
        try await engine.requestCancel(jobID: accepted.jobID)
        _ = try await engine.releaseImport(id: record.id, generation: 2)
      case (.failure, .success(let value)): _ = try ArtifactImportReleaseProjection(value)
      default: XCTFail("release and acquire did not linearize: \(pair)")
      }
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
  private static func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }

  func testConcurrentDuplicateAdmissionsReturnOneInitializedJob() async throws {
    for index in 0..<8 {
      let record = try await imported("duplicate-\(index)"); let engine = try engine()
      let data = try request(record, id: "duplicate-\(index)")
      async let first = engine.submit(data)
      async let second = engine.submit(data)
      let accepted = try await (first, second)
      XCTAssertEqual(accepted.0.jobID, accepted.1.jobID)
      XCTAssertNotEqual(accepted.0.deduplicated, accepted.1.deduplicated)
      await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
      try await engine.requestCancel(jobID: accepted.0.jobID)
      _ = try await engine.releaseImport(id: record.id, generation: 2)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testAdmissionFaultsRetainOnlyDurableJobsAndNeverLeakTransientUses() async throws {
    for point in [RuntimeAdmissionFaultPoint.beforeAdmission, .afterAdmission] {
      let record = try await imported("fault-" + point.rawValue)
      let failing = try engine(fault: .init { if $0 == point { throw Failure.fixture } })
      do { _ = try await failing.submit(request(record, id: point.rawValue)); XCTFail("missing admission fault") }
      catch Failure.fixture { }
      artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:01Z" })
      let restarted = try engine()
      if point == .afterAdmission {
        await conflict { _ = try await restarted.releaseImport(id: record.id, generation: 2) }
        let same = try await restarted.submit(request(record, id: point.rawValue))
        XCTAssertTrue(same.deduplicated)
        _ = try await restarted.recoverActiveJobs()
        try await restarted.requestCancel(jobID: same.jobID)
      }
      _ = try await restarted.releaseImport(id: record.id, generation: 2)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testUnreadableOrChangedDurableReferencesCannotPermitRelease() async throws {
    let record = try await imported(); let engine = try engine()
    let accepted = try await engine.submit(request(record))
    let repository = try RuntimeJobRepository(stateDirectory: root.appending(path: "engine"))
    let saved = try XCTUnwrap(repository.job(jobID: accepted.jobID))
    let original = try XCTUnwrap(saved.initialRecordData)
    var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var request = try XCTUnwrap(altered["request"] as? [String: Any])
    request["inputs"] = ["sourceArtifactRef": "lease-v1:job-unrelated:ART-00000000000000000000000000000000"]
    altered["request"] = request
    for bytes in [Data("{".utf8), try JSONSerialization.data(withJSONObject: altered)] {
      try repository.updateJobState(jobID: accepted.jobID, state: saved.state, updatedAtUTC: saved.updatedAtUTC, recordData: bytes)
      do { _ = try await engine.releaseImport(id: record.id, generation: 2); XCTFail("unverifiable references allowed release") }
      catch let error as AgentExecutionControlFailure { XCTAssertEqual(error.code, "recordUnreadable") }
      let state = try await artifacts.inspectImport(id: record.id); XCTAssertEqual(state.state, "committed")
    }
    try repository.updateJobState(jobID: accepted.jobID, state: saved.state, updatedAtUTC: saved.updatedAtUTC, recordData: original)
    await conflict { _ = try await engine.releaseImport(id: record.id, generation: 2) }
  }

  func testSIGKILLBeforeAndAfterUnpinPreservesOriginalReleaseReceipt() async throws {
    for window in ["import-release-intent", "import-unpinned"] {
      let directory = root.appending(path: window)
      let child = Process(); child.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckEngineCrashFixture")
      child.arguments = [window, directory.path]; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let ready = directory.appending(path: "ready"); let end = Date().addingTimeInterval(15)
      while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < end { usleep(10_000) }
      guard FileManager.default.fileExists(atPath: ready.path) else { XCTFail("missing crash window \(window)"); continue }
      kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
      let store = try RuntimeArtifactStore(rootURL: directory.appending(path: "artifacts"), nowUTC: { "2026-09-02T00:00:00Z" })
      let state = try await store.inspectImport(requestID: "crash-upload") // recovery finishes only the old unpin
      XCTAssertEqual(state.state, "released")
      let receipt = try XCTUnwrap(state.releaseReceipt)
      let release = try ArtifactImportReleaseProjection(receipt)
      let metadata = try await store.inspect(jobID: state.importID, artifactID: release.artifactID)
      XCTAssertFalse(metadata.retention.pinned); XCTAssertEqual(metadata.retention.deadlineUTC, release.deadline)
      let repeated = try await store.releaseImport(id: state.importID, generation: 2, requireNoActiveJob: { _ in throw Failure.fixture })
      XCTAssertEqual(repeated, receipt)
      do { _ = try await store.resolveLease(release.lease); XCTFail("released input revived") } catch { }
    }
  }
}
