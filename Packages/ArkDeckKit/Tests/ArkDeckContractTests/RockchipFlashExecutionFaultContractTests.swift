import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipFlashExecutionFaultContractTests: XCTestCase {
  func testAdmissionFailureHasZeroFakeSpawnAndZeroStorageCreation() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let persistenceCalls = LockedInteger()
    let power = RecordingPowerBackend()
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: RejectingRockchipAdmissionPort(), process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: power,
        makePersistence: { _, _, _ in
          persistenceCalls.increment()
          throw RockchipFlashExecutionError.storageRejected("must not be reached")
        }, profile: fixture.profile,
        makeID: RockchipExecutionTestFixture.deterministicID))
    await assertThrowsErrorAsync(
      try await host.execute(
        RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
          targetLocationSelector: "42")))
    XCTAssertEqual(process.arguments.count, 0)
    XCTAssertEqual(persistenceCalls.value, 0)
    XCTAssertEqual(power.activeCount, 0)
  }

  func testSemanticMatrixRejectsExitZeroWithoutMarkersAndMalformedStreams() throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let root = fixture.base.appending(path: "semantic-session", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let images = try RockchipFlashExecutionStager.stage(
      archiveURL: fixture.archive, sessionRoot: root, profile: fixture.profile)
    let commands = try RockchipFlashExecutionLowering.commands(
      plan: fixture.plan, stagedImages: images)
    let loader = commands[0]
    let ppt = commands[1]
    let write = commands[2]
    let reset = commands[11]

    XCTAssertEqual(
      evaluate(loader, stdout: Data("not-loader\n".utf8)),
      .failed(.loaderObservationMismatch))
    XCTAssertEqual(
      evaluate(ppt, stdout: Data("Partition Info(GPT)\n".utf8)),
      .failed(.partitionTableMismatch))
    XCTAssertEqual(
      evaluate(write, stdout: Data("Write LBA from file (99%)\n".utf8)),
      .failed(.semanticMarkerMissing(RockchipRockUSBFlashProvider.writeSuccessMarker)))
    XCTAssertEqual(
      evaluate(reset, stdout: Data("reset requested\n".utf8)),
      .failed(.semanticMarkerMissing(RockchipRockUSBFlashProvider.resetSuccessMarker)))
    XCTAssertEqual(evaluate(write, stdout: Data([0xff, 0xfe])), .failed(.invalidUTF8))
    XCTAssertEqual(
      evaluate(write, stdout: Data(), stderr: Data("warning\n".utf8)),
      .failed(.unexpectedStandardError))
    XCTAssertEqual(
      evaluate(
        write,
        stdout: Data(repeating: UInt8(ascii: "x"), count: 64 * 1_024 + 2)),
      .failed(.outputTooLarge))
    XCTAssertEqual(
      evaluate(write, stdout: Data(), termination: .exited(7)),
      .failed(.processDidNotExitSuccessfully))
  }

  func testStagingRejectsTraversalDuplicateLinkAndDescriptorReplacement() throws {
    for archiveCase in [ArchiveFault.traversal, .duplicate, .link] {
      let base = FileManager.default.temporaryDirectory.appending(
        path: "arkdeck-ain007-stage-fault-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: base, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: base) }
      let built = try makeFaultArchive(archiveCase)
      let archive = base.appending(path: "images.tar.gz")
      try built.data.write(to: archive)
      let root = base.appending(path: "session")
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      XCTAssertThrowsError(
        try RockchipFlashExecutionStager.stage(
          archiveURL: archive, sessionRoot: root, profile: built.profile))
    }

    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let root = fixture.base.appending(path: "replacement-session")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let images = try RockchipFlashExecutionStager.stage(
      archiveURL: fixture.archive, sessionRoot: root, profile: fixture.profile)
    let image = try XCTUnwrap(images["image0.img"])
    let stagedPath = root.appending(path: "staging/image0.img")
    let displaced = root.appending(path: "staging/image0.displaced")
    try FileManager.default.moveItem(at: stagedPath, to: displaced)
    try Data("replacement".utf8).write(to: stagedPath)
    XCTAssertThrowsError(try image.revalidate())
  }

  func testExecutableReplacementFailsBeforeSpawn() throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let executable = fixture.base.appending(path: "fixture-copy")
    try FileManager.default.copyItem(at: fixture.executable, to: executable)
    XCTAssertEqual(chmod(executable.path, 0o700), 0)
    let original = fixture.base.appending(path: "fixture-opened")
    let launches = LockedInteger()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in
        try FileManager.default.moveItem(at: executable, to: original)
        try FileManager.default.copyItem(at: original, to: executable)
        guard chmod(executable.path, 0o700) == 0 else {
          throw RockchipFlashExecutionError.executableIdentityDrift
        }
      },
      launchObserver: { _ in launches.increment() })
    XCTAssertThrowsError(
      try executor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(executable: executable, arguments: ["ld"]),
          expectedSHA256: RockchipExecutionTestFixture.sha256(try Data(contentsOf: executable)))))
    XCTAssertEqual(launches.value, 0)
  }

  func testIntentDurabilityAndENOSPCFailuresLaunchZeroFakeProcesses() async throws {
    for fault in [FaultingRockchipPersistence.Fault.intent, .stagingENOSPC] {
      let fixture = try RockchipExecutionTestFixture.make()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let durable = try await fixture.makePersistence()
      let persistence = FaultingRockchipPersistence(base: durable, fault: fault)
      let admission = RecordingRockchipAdmissionPort(
        plan: fixture.plan, receipt: fixture.executableReceipt)
      let process = RecordingRockchipProcessPort(
        executable: fixture.executable, sha256: fixture.executableSHA256)
      let power = RecordingPowerBackend()
      let host = RockchipFlashExecutionHost(
        dependencies: RockchipFlashExecutionDependencies(
          admission: admission, process: process,
          postflight: FixedRockchipPostflightPort(
            serialDigest: String(repeating: "a", count: 64), topology: "42"),
          power: power,
          makePersistence: { _, _, _ in persistence },
          stage: { archive, root, profile in
            if fault == .stagingENOSPC { throw POSIXError(.ENOSPC) }
            return try RockchipFlashExecutionStager.stage(
              archiveURL: archive, sessionRoot: root, profile: profile)
          }, profile: fixture.profile,
          makeID: RockchipExecutionTestFixture.deterministicID))
      await assertThrowsErrorAsync(
        try await host.execute(
          RockchipFlashExecutionRequest(
            authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
            targetLocationSelector: "42")))
      XCTAssertEqual(process.arguments.count, 0, "fault: \(fault)")
      XCTAssertEqual(admission.closedStatus, .failed, "fault: \(fault)")
      XCTAssertEqual(power.activeCount, 0, "fault: \(fault)")
    }
  }

  func testUnknownWriteOutcomeStopsFollowingDispatchAndReopensWaitingForRecovery()
    async throws
  {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256,
      semanticOverride: { command, result in
        if case .writePartition(_, let partition, _) = command, partition == "partition2" {
          return .failed(.semanticMarkerMissing("injected-after-child-side-effect"))
        }
        return result
      })
    let power = RecordingPowerBackend()
    let host = makeHost(
      fixture: fixture, persistence: persistence, admission: admission,
      process: process, power: power,
      postflight: FixedRockchipPostflightPort(
        serialDigest: String(repeating: "a", count: 64), topology: "42"))
    do {
      _ = try await host.execute(
        RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
          targetLocationSelector: "42"))
      XCTFail("unknown destructive outcome must not succeed")
    } catch let error as RockchipFlashExecutionError {
      guard case .recoveryRequired(let stepID, _) = error else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertTrue(stepID.contains("partition2"))
    }
    XCTAssertEqual(process.arguments.count, 5)
    XCTAssertEqual(admission.closedStatus, .outcomeUnknown)
    XCTAssertEqual(admission.closedIntentIDs.count, 3)
    XCTAssertEqual(power.activeCount, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: persistence.sessionRoot.appending(path: "manifest.json").path))
    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.currentState, .waitingForRecovery)
    XCTAssertFalse(replay.finalized)
    XCTAssertEqual(replay.unknownOutcomes.count, 1)
  }

  func testPostflightIdentityMismatchCannotPublishSuccess() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let power = RecordingPowerBackend()
    let host = makeHost(
      fixture: fixture, persistence: persistence, admission: admission,
      process: process, power: power,
      postflight: FixedRockchipPostflightPort(
        serialDigest: String(repeating: "c", count: 64), topology: "42"))
    await assertThrowsErrorAsync(
      try await host.execute(
        RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
          targetLocationSelector: "42")))
    XCTAssertEqual(process.arguments.count, 12)
    XCTAssertEqual(admission.closedStatus, .outcomeUnknown)
    XCTAssertEqual(power.activeCount, 0)
    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.currentState, .waitingForRecovery)
    XCTAssertFalse(replay.finalized)
  }

  func testCancellationDuringCriticalWriteWaitsForSafeBoundaryAndBlocksNextStep()
    async throws
  {
    for holdIndex in 0..<9 {
      var names = (0..<9).map { "partition\($0)" }
      names[holdIndex] = "critical_hold"
      let fixture = try RockchipExecutionTestFixture.make(partitionNames: names)
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let persistence = try await fixture.makePersistence()
      let admission = RecordingRockchipAdmissionPort(
        plan: fixture.plan, receipt: fixture.executableReceipt)
      let process = RecordingRockchipProcessPort(
        executable: fixture.executable, sha256: fixture.executableSHA256)
      let power = RecordingPowerBackend()
      let host = makeHost(
        fixture: fixture, persistence: persistence, admission: admission,
        process: process, power: power,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"))
      let clock = ContinuousClock()
      let started = clock.now
      let task = Task {
        try await host.execute(
          RockchipFlashExecutionRequest(
            authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
            targetLocationSelector: "42"))
      }
      let expectedDispatchCount = 3 + holdIndex
      while process.arguments.count < expectedDispatchCount {
        try await Task.sleep(for: .milliseconds(10))
      }
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("cancel must stop after critical write \(holdIndex)")
      } catch let error as RockchipFlashExecutionError {
        XCTAssertEqual(error, .cancelledAtSafeBoundary)
      }
      XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .milliseconds(350))
      XCTAssertEqual(process.arguments.count, expectedDispatchCount)
      XCTAssertEqual(process.terminations.last, .exited(0))
      XCTAssertEqual(admission.closedStatus, .cancelled)
      XCTAssertEqual(power.activeCount, 0)
      let replay = try DurableJournalRecovery.inspect(
        url: persistence.sessionRoot.appending(path: "journal.jsonl"))
      XCTAssertEqual(replay.currentState, .waitingForRecovery)
    }
  }

  func testSleepWakeDuringCriticalWriteIsDurableAndForcesRecoveryBeforeNextStep()
    async throws
  {
    var names = (0..<9).map { "partition\($0)" }
    names[0] = "critical_hold"
    let fixture = try RockchipExecutionTestFixture.make(partitionNames: names)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let power = RecordingPowerBackend()
    let lifecycle = FakeRockchipExecutionLifecyclePort()
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: power,
        makePersistence: { _, _, _ in persistence }, profile: fixture.profile,
        lifecycle: lifecycle, makeID: RockchipExecutionTestFixture.deterministicID))
    let task = Task {
      try await host.execute(
        RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
          targetLocationSelector: "42"))
    }
    while process.arguments.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    lifecycle.emitSleepWake()
    do {
      _ = try await task.value
      XCTFail("sleep/wake must stop after the current critical write")
    } catch let error as RockchipFlashExecutionError {
      guard case .recoveryRequired = error else { return XCTFail("wrong error: \(error)") }
    }
    XCTAssertEqual(process.arguments.count, 3)
    XCTAssertEqual(process.terminations.last, .exited(0))
    XCTAssertEqual(admission.closedStatus, .outcomeUnknown)
    XCTAssertEqual(power.activeCount, 0)
    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.events.filter { $0.kind == .sleep }.count, 1)
    XCTAssertEqual(replay.events.filter { $0.kind == .wake }.count, 1)
    XCTAssertEqual(replay.currentState, .waitingForRecovery)
  }

  private func makeHost(
    fixture: RockchipExecutionTestFixture,
    persistence: RockchipDurableExecutionPersistence,
    admission: RecordingRockchipAdmissionPort,
    process: RecordingRockchipProcessPort,
    power: RecordingPowerBackend,
    postflight: FixedRockchipPostflightPort
  ) -> RockchipFlashExecutionHost {
    RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process, postflight: postflight,
        power: power,
        makePersistence: { _, _, _ in persistence }, profile: fixture.profile,
        makeID: RockchipExecutionTestFixture.deterministicID))
  }

  private func evaluate(
    _ command: RockchipClosedCommand,
    stdout: Data,
    stderr: Data = Data(),
    termination: ProcessTermination = .exited(0)
  ) -> RockchipCommandSemanticResult {
    var evaluator = RockchipCommandSemanticEvaluator(command: command)
    if !stdout.isEmpty { evaluator.consume(ProcessOutputChunk(stream: .stdout, bytes: stdout)) }
    if !stderr.isEmpty { evaluator.consume(ProcessOutputChunk(stream: .stderr, bytes: stderr)) }
    return evaluator.finish(
      execution: ProcessExecutionResult(
        termination: termination,
        stdout: ProcessStreamCapture(
          data: stdout, totalByteCount: Int64(stdout.count), wasTruncated: false),
        stderr: ProcessStreamCapture(
          data: stderr, totalByteCount: Int64(stderr.count), wasTruncated: false)))
  }

  private enum ArchiveFault { case traversal, duplicate, link }

  private func makeFaultArchive(_ fault: ArchiveFault) throws -> (
    data: Data, profile: RockchipFlashProfile
  ) {
    let name = fault == .traversal ? "../escape.img" : "image.img"
    let bytes = Data("payload".utf8)
    let entries: [(String, Data, UInt8)] =
      fault == .duplicate
      ? [(name, bytes, UInt8(ascii: "0")), (name, bytes, UInt8(ascii: "0"))]
      : [(name, bytes, fault == .link ? UInt8(ascii: "2") : UInt8(ascii: "0"))]
    let data = try gzipTar(entries: entries)
    let profile = try RockchipFlashProfile(
      archiveSizeBytes: Int64(data.count),
      archiveSHA256: RockchipExecutionTestFixture.sha256(data),
      members: [
        RockchipImagesArchiveMember(
          name: name, sizeBytes: Int64(bytes.count),
          sha256: RockchipExecutionTestFixture.sha256(bytes),
          classification: .mappedPartitionImage)
      ],
      mappedPartitions: [
        RockchipMappedPartition(
          writeOrder: 1, partitionName: "partition", imageMemberName: name,
          offsetSectors: 8192)
      ],
      membershiplessPartitionsWriteForbidden: [], prerequisites: [:])
    return (data, profile)
  }

  private func gzipTar(entries: [(String, Data, UInt8)]) throws -> Data {
    var tar = Data()
    for entry in entries {
      var header = [UInt8](repeating: 0, count: 512)
      RockchipExecutionTestFixture.write(entry.0, into: &header, offset: 0, length: 100)
      RockchipExecutionTestFixture.writeOctal(0o600, into: &header, offset: 100, length: 8)
      RockchipExecutionTestFixture.writeOctal(entry.1.count, into: &header, offset: 124, length: 12)
      for index in 148..<156 { header[index] = 0x20 }
      header[156] = entry.2
      RockchipExecutionTestFixture.write("ustar", into: &header, offset: 257, length: 6)
      header[263] = UInt8(ascii: "0")
      header[264] = UInt8(ascii: "0")
      let checksum = header.reduce(0) { $0 + Int($1) }
      RockchipExecutionTestFixture.write(
        String(format: "%06o", checksum), into: &header, offset: 148, length: 6)
      header[154] = 0
      header[155] = 0x20
      tar.append(contentsOf: header)
      tar.append(entry.1)
      tar.append(Data(repeating: 0, count: (512 - entry.1.count % 512) % 512))
    }
    tar.append(Data(repeating: 0, count: 1024))
    var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
    gzip.append(try RockchipExecutionTestFixture.deflate(tar))
    gzip.append(Data(repeating: 0, count: 8))
    return gzip
  }
}

private final class LockedInteger: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0
  var value: Int { lock.withLock { stored } }
  func increment() { lock.withLock { stored += 1 } }
}

private final class FaultingRockchipPersistence: @unchecked Sendable,
  RockchipExecutionPersistence
{
  enum Fault: String, Sendable {
    case intent
    case stagingENOSPC
  }

  let base: RockchipDurableExecutionPersistence
  let fault: Fault
  var sessionRoot: URL { base.sessionRoot }

  init(base: RockchipDurableExecutionPersistence, fault: Fault) {
    self.base = base
    self.fault = fault
  }

  func appendJobCreated(admission: RockchipExecutionAdmission) throws {
    try base.appendJobCreated(admission: admission)
  }

  func appendRunning() throws { try base.appendRunning() }

  func appendIntent(
    step: WorkflowStep,
    admission: RockchipExecutionAdmission,
    isDestructive: Bool
  ) throws -> String {
    if fault == .intent { throw POSIXError(.EIO) }
    return try base.appendIntent(
      step: step, admission: admission, isDestructive: isDestructive)
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
    try base.appendOutcome(
      step: step, intentEventID: intentEventID, admission: admission,
      result: result, certainty: certainty, semanticCode: semanticCode,
      execution: execution)
  }

  func appendWaitingForRecovery(stepID: String, reason: String) throws {
    try base.appendWaitingForRecovery(stepID: stepID, reason: reason)
  }

  func appendLifecycleEvent(_ event: RockchipExecutionLifecycleEvent) throws {
    try base.appendLifecycleEvent(event)
  }

  func finishSucceeded(
    plan: RockchipFlashPlan,
    admission: RockchipExecutionAdmission,
    destructiveIntentEventIDs: [String]
  ) async throws -> URL {
    try await base.finishSucceeded(
      plan: plan, admission: admission,
      destructiveIntentEventIDs: destructiveIntentEventIDs)
  }
}

private final class FakeRockchipExecutionLifecyclePort: @unchecked Sendable,
  RockchipExecutionLifecyclePort
{
  private let lock = NSLock()
  private var handler: (@Sendable (RockchipExecutionLifecycleEvent) -> Void)?

  func start(
    handler: @escaping @Sendable (RockchipExecutionLifecycleEvent) -> Void
  ) throws {
    lock.withLock { self.handler = handler }
  }

  func stop() { lock.withLock { handler = nil } }

  func emitSleepWake() {
    let callback: (@Sendable (RockchipExecutionLifecycleEvent) -> Void)? = lock.withLock {
      self.handler
    }
    callback?(
      RockchipExecutionLifecycleEvent(
        eventID: "test-sleep", kind: .sleep, sleepEventID: nil,
        elapsedDurationNanoseconds: 1, activeDurationNanoseconds: 1))
    callback?(
      RockchipExecutionLifecycleEvent(
        eventID: "test-wake", kind: .wake, sleepEventID: "test-sleep",
        elapsedDurationNanoseconds: 2, activeDurationNanoseconds: 1))
  }
}

private struct RejectingRockchipAdmissionPort: RockchipExecutionAdmissionPort {
  func admit(
    request _: RockchipFlashExecutionRequest,
    sessionID _: String,
    jobID _: String,
    targetID _: String
  ) async throws -> RockchipExecutionAdmission {
    throw AuthorizationProvenanceError.exactHeadApprovalMissing
  }

  func authorizeAndConsume(_: RockchipExecutionAdmission) async throws {
    throw AuthorizationAdmissionError.capabilityAlreadyConsumed
  }

  func closeUsage(
    admission _: RockchipExecutionAdmission,
    status _: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs _: [String]
  ) throws {}
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected error", file: file, line: line)
  } catch {}
}
