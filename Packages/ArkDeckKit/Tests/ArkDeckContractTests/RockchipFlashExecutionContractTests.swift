import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Compression
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipFlashExecutionContractTests: XCTestCase {
  func testAuthorizedFakeDescriptorExecutesExactClosedSequenceAndPublishesV21Manifest()
    async throws
  {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let powerBackend = RecordingPowerBackend()
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: powerBackend,
        makePersistence: { _, _, _ in persistence },
        profile: fixture.profile,
        makeID: RockchipExecutionTestFixture.deterministicID))
    let request = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
      targetLocationSelector: "42")

    let result = try await host.execute(request)

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(result.evidenceClass, .contractFake)
    XCTAssertEqual(result.manifestURL, persistence.sessionRoot.appending(path: "manifest.json"))
    let arguments = process.arguments
    XCTAssertEqual(arguments.count, 12)
    XCTAssertEqual(arguments[0], ["ld"])
    XCTAssertEqual(arguments[1], ["ppt"])
    XCTAssertEqual(
      arguments[2...10].map { Array($0.prefix(2)) },
      fixture.profile.mappedPartitions.map { ["wlx", $0.partitionName] })
    XCTAssertEqual(arguments[11], ["rd"])
    XCTAssertTrue(
      arguments.flatMap { $0 }.allSatisfy {
        !$0.contains("sudo") && $0 != "sh" && $0 != "bash" && $0 != "wl"
      })
    for row in arguments[2...10] {
      XCTAssertEqual(row.count, 3)
      XCTAssertTrue(row[2].hasPrefix("/.vol/"))
      var metadata = stat()
      XCTAssertEqual(lstat(row[2], &metadata), 0)
      XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    }

    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.events.first?.schemaVersion, "2.1.0")
    XCTAssertEqual(replay.events.first?.kind, .jobCreated)
    XCTAssertEqual(replay.events.first?.payload["executionAuthority"], .string("authorizedAgent"))
    let destructiveIntents = replay.events.filter {
      $0.kind == .stepIntent && $0.stepEffect == .destructive
    }
    XCTAssertEqual(destructiveIntents.count, 9)
    XCTAssertTrue(
      destructiveIntents.allSatisfy {
        $0.authorizationReference?.authorizationID == "AUTH-TEST-AIN-007"
          && $0.usageReservationID == "reservation-ain-007"
      })
    XCTAssertTrue(replay.finalized)
    XCTAssertEqual(replay.currentState, .succeeded)

    let manifest = try SessionManifestDocument(
      data: Data(contentsOf: try XCTUnwrap(result.manifestURL)))
    XCTAssertEqual(manifest.schemaVersion, "2.1.0")
    XCTAssertEqual(manifest.executionMode, "execute")
    XCTAssertEqual(manifest.executionAuthority, "authorizedAgent")
    XCTAssertEqual(manifest.authorization?.destructiveIntentEventIDs.count, 9)
    XCTAssertEqual(manifest.authorization?.usageReservationID, "reservation-ain-007")
    XCTAssertGreaterThanOrEqual(manifest.artifacts.count, 12)
    XCTAssertTrue(manifest.artifacts.allSatisfy { $0.role == .raw })
    let manifestText = String(decoding: manifest.canonicalData, as: UTF8.self)
    XCTAssertFalse(manifestText.contains(fixture.executable.path))
    XCTAssertFalse(manifestText.contains(fixture.archive.path))
    XCTAssertFalse(manifestText.contains("/.vol/"))
    XCTAssertFalse(manifestText.contains("contractFake"))

    let records = try persistence.auditRecordsForTesting(
      correlationID: "rockchip-session-fixed")
    XCTAssertEqual(records.last?.details["evidenceClass"], .string("contractFake"))
    XCTAssertEqual(records.last?.details["hardwareSupportEligible"], .bool(false))
    XCTAssertEqual(powerBackend.activeCount, 0)
    XCTAssertEqual(admission.closedStatus, .succeeded)
    XCTAssertEqual(admission.closedIntentIDs.count, 9)
    print(
      "TEST-AIN-DISPATCH-001 PASS argv=1ld+1ppt+9wlx+1rd schema=2.1.0 "
        + "evidence=contractFake realDevice=0 hdc=0 network=0 shell=0")
  }

  func testPublicRequestRejectsAuthorityAndSelectorInjection() throws {
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "../AUTH", archiveURL: URL(fileURLWithPath: "/tmp/a"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "AUTH-TEST", archiveURL: URL(string: "https://example.invalid/a")!,
        targetLocationSelector: "42"))
    for selector in ["", "042", "42 --tool /tmp/fake", "-1", "４２"] {
      XCTAssertThrowsError(
        try RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST", archiveURL: URL(fileURLWithPath: "/tmp/a"),
          targetLocationSelector: selector))
    }
  }

  func testLoweringRejectsMissingStagedImageAndNeverOffersWLFallback() throws {
    let provider = RockchipRockUSBFlashProvider()
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    XCTAssertThrowsError(
      try RockchipFlashExecutionLowering.commands(plan: plan, stagedImages: [:]))
    XCTAssertFalse(RockchipRockUSBFlashProvider.closedCommandSurface.isEmpty)
  }
}

final class RecordingRockchipAdmissionPort: @unchecked Sendable, RockchipExecutionAdmissionPort {
  private let lock = NSLock()
  let plan: RockchipFlashPlan
  let receipt: ProcessExecutableIdentityReceipt
  private(set) var closedStatus: AuthorizationUsageTerminalStatus?
  private(set) var closedIntentIDs: [String] = []

  init(plan: RockchipFlashPlan, receipt: ProcessExecutableIdentityReceipt) {
    self.plan = plan
    self.receipt = receipt
  }

  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID _: String,
    jobID _: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission {
    RockchipExecutionAdmission(
      backing: .contractFake, plan: plan,
      authorizationReference: try AuthorizationReference(
        authorizationID: request.authorizationID,
        mainCommitOID: String(repeating: "1", count: 40),
        authorizationBlobOID: String(repeating: "2", count: 40),
        approvalPRNumber: 314),
      usageReservationID: "reservation-ain-007", targetID: targetID,
      bindingRevision: 1, targetDigestSHA256: String(repeating: "b", count: 64),
      serialDigestSHA256: String(repeating: "a", count: 64), usbTopology: "42",
      executableIdentity: receipt, evidenceClass: .contractFake)
  }

  func authorizeAndConsume(_: RockchipExecutionAdmission) async throws {}

  func closeUsage(
    admission _: RockchipExecutionAdmission,
    status: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs: [String]
  ) throws {
    lock.lock()
    closedStatus = status
    closedIntentIDs = destructiveIntentEventIDs
    lock.unlock()
  }
}

final class RecordingRockchipProcessPort: @unchecked Sendable, RockchipExecutionProcessPort {
  private let lock = NSLock()
  private let executable: URL
  private let sha256: String
  private let executor = FoundationProcessExecutor()
  private let semanticOverride:
    @Sendable (RockchipClosedCommand, RockchipCommandSemanticResult)
      -> RockchipCommandSemanticResult
  private var recordedArguments: [[String]] = []
  private var recordedTerminations: [ProcessTermination] = []

  init(
    executable: URL,
    sha256: String,
    semanticOverride:
      @escaping @Sendable (RockchipClosedCommand, RockchipCommandSemanticResult)
      -> RockchipCommandSemanticResult = { _, result in result }
  ) {
    self.executable = executable
    self.sha256 = sha256
    self.semanticOverride = semanticOverride
  }

  var arguments: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recordedArguments
  }

  var terminations: [ProcessTermination] {
    lock.withLock { recordedTerminations }
  }

  func prepare(
    command: RockchipClosedCommand,
    admissionIdentity: ProcessExecutableIdentityReceipt
  ) throws -> RockchipPreparedCommand {
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: executable, arguments: command.arguments),
      expectedSHA256: sha256)
    let prepared = try executor.prepareIdentityBoundLaunch(request)
    guard prepared.executableIdentity == admissionIdentity else {
      prepared.close()
      throw RockchipFlashExecutionError.executableIdentityDrift
    }
    return RockchipPreparedCommand(executableIdentity: prepared.executableIdentity) {
      self.lock.withLock { self.recordedArguments.append(command.arguments) }
      let result = try await self.executor.executePreparedIdentityBoundLaunch(
        prepared, evaluating: RockchipCommandSemanticEvaluator(command: command))
      self.lock.withLock { self.recordedTerminations.append(result.execution.termination) }
      return RockchipExecutionAttempt(
        execution: result.execution,
        semantic: self.semanticOverride(command, result.semantic),
        executableIdentity: result.executableIdentity)
    }
  }
}

struct FixedRockchipPostflightPort: RockchipExecutionPostflightPort {
  let serialDigest: String
  let topology: String

  func probe(expectedTopology _: String) async throws -> RockchipPostflightReceipt {
    RockchipPostflightReceipt(
      connected: true, serialDigestSHA256: serialDigest, usbTopology: topology)
  }
}

final class RecordingPowerBackend: @unchecked Sendable, RockchipPowerActivityPort {
  private let lock = NSLock()
  private var count = 0

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func acquire(reason _: String) throws -> any RockchipPowerActivityLease {
    lock.lock()
    count += 1
    lock.unlock()
    return RecordingPowerLease { [weak self] in self?.release() }
  }

  private func release() {
    lock.lock()
    count -= 1
    lock.unlock()
  }
}

private final class RecordingPowerLease: @unchecked Sendable, RockchipPowerActivityLease {
  private let lock = NSLock()
  private var release: (@Sendable () -> Void)?

  init(release: @escaping @Sendable () -> Void) {
    self.release = release
  }

  deinit { end() }

  func end() {
    lock.lock()
    let release = release
    self.release = nil
    lock.unlock()
    release?()
  }
}

struct RockchipExecutionTestFixture {
  let base: URL
  let archive: URL
  let executable: URL
  let executableSHA256: String
  let executableReceipt: ProcessExecutableIdentityReceipt
  let profile: RockchipFlashProfile
  let plan: RockchipFlashPlan
  let sessionsRoot: URL
  let coordinator: HostStorageCoordinator

  static let deterministicID: @Sendable (String) -> String = { prefix in
    switch prefix {
    case "rockchip-session": "rockchip-session-fixed"
    case "rockchip-job": "rockchip-job-fixed"
    default: "rockchip-target-fixed"
    }
  }

  static func make(partitionNames: [String]? = nil) throws -> RockchipExecutionTestFixture {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-ain007-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let members = (0..<9).map { index in
      (name: "image\(index).img", bytes: Data("image-\(index)-payload".utf8))
    }
    let archive = base.appending(path: "images.tar.gz")
    try makeGzipTar(members: members).write(to: archive)
    let archiveBytes = try Data(contentsOf: archive)
    let profileMembers = members.map {
      RockchipImagesArchiveMember(
        name: $0.name, sizeBytes: Int64($0.bytes.count), sha256: sha256($0.bytes),
        classification: .mappedPartitionImage)
    }
    let profile = try RockchipFlashProfile(
      archiveSizeBytes: Int64(archiveBytes.count), archiveSHA256: sha256(archiveBytes),
      members: profileMembers,
      mappedPartitions: members.enumerated().map { index, member in
        RockchipMappedPartition(
          writeOrder: index + 1,
          partitionName: partitionNames?[index] ?? "partition\(index)",
          imageMemberName: member.name, offsetSectors: Int64((index + 1) * 8192))
      },
      membershiplessPartitionsWriteForbidden: [],
      prerequisites: [
        .loader: .required, .recoveryPath: .required, .unlocked: .required,
        .stablePower: .optional,
      ])
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = packageRoot.appending(path: ".build/debug/ArkDeckFakeRockchipFixture")
    let executableSHA256 = sha256(try Data(contentsOf: executable))
    let executor = FoundationProcessExecutor()
    let prepared = try executor.prepareIdentityBoundLaunch(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(executable: executable, arguments: ["ld"]),
        expectedSHA256: executableSHA256))
    let receipt = prepared.executableIdentity
    prepared.close()
    let sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sessionsRoot, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return RockchipExecutionTestFixture(
      base: base, archive: archive, executable: executable,
      executableSHA256: executableSHA256, executableReceipt: receipt,
      profile: profile, plan: plan, sessionsRoot: sessionsRoot,
      coordinator: HostStorageCoordinator())
  }

  func makePersistence() async throws -> RockchipDurableExecutionPersistence {
    let probe = SystemHostStorageProbe()
    let snapshot = try probe.snapshot(for: sessionsRoot)
    let request = try StorageClaimRequest(
      claimID: "claim-rockchip-job-fixed", jobID: "rockchip-job-fixed",
      volumeIdentity: snapshot.volumeIdentity,
      budget: StorageBudget(
        metadataHeadroomBytes: 1 << 20, finalizationHeadroomBytes: 1 << 20,
        remainingGrowthBytes: 16 << 20, writerClass: .heavy))
    guard case .admitted(let claim) = await coordinator.admit(request, snapshot: snapshot) else {
      throw RockchipFlashExecutionError.storageRejected("fixture claim")
    }
    let store = try SessionStore(sessionsRoot: sessionsRoot)
    let layout = try store.createSession(
      sessionID: "rockchip-session-fixed", jobID: "rockchip-job-fixed",
      createdAt: Date(timeIntervalSince1970: 1_752_739_200), claim: claim)
    return try RockchipDurableExecutionPersistence(
      layout: layout, claim: claim, coordinator: coordinator)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func makeGzipTar(members: [(name: String, bytes: Data)]) throws -> Data {
    var tar = Data()
    for member in members {
      var header = [UInt8](repeating: 0, count: 512)
      write(member.name, into: &header, offset: 0, length: 100)
      writeOctal(0o600, into: &header, offset: 100, length: 8)
      writeOctal(0, into: &header, offset: 108, length: 8)
      writeOctal(0, into: &header, offset: 116, length: 8)
      writeOctal(member.bytes.count, into: &header, offset: 124, length: 12)
      writeOctal(0, into: &header, offset: 136, length: 12)
      for index in 148..<156 { header[index] = 0x20 }
      header[156] = UInt8(ascii: "0")
      write("ustar", into: &header, offset: 257, length: 6)
      header[262] = 0
      header[263] = UInt8(ascii: "0")
      header[264] = UInt8(ascii: "0")
      let checksum = header.reduce(0) { $0 + Int($1) }
      let checksumText = String(format: "%06o", checksum)
      write(checksumText, into: &header, offset: 148, length: 6)
      header[154] = 0
      header[155] = 0x20
      tar.append(contentsOf: header)
      tar.append(member.bytes)
      tar.append(Data(repeating: 0, count: (512 - member.bytes.count % 512) % 512))
    }
    tar.append(Data(repeating: 0, count: 1024))
    let compressed = try deflate(tar)
    var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
    gzip.append(compressed)
    gzip.append(Data(repeating: 0, count: 8))
    return gzip
  }

  static func deflate(_ data: Data) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count * 2 + 1024)
    defer { destination.deallocate() }
    let count = data.withUnsafeBytes { source in
      compression_encode_buffer(
        destination, data.count * 2 + 1024,
        source.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
        nil, COMPRESSION_ZLIB)
    }
    guard count > 0 else { throw RockchipFlashStagingError.decompressionFailed }
    return Data(bytes: destination, count: count)
  }

  static func write(
    _ string: String, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    for (index, byte) in string.utf8.prefix(length).enumerated() {
      bytes[offset + index] = byte
    }
  }

  static func writeOctal(
    _ value: Int, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    let text = String(format: "%0*o", length - 1, value)
    write(text, into: &bytes, offset: offset, length: length - 1)
    bytes[offset + length - 1] = 0
  }
}
