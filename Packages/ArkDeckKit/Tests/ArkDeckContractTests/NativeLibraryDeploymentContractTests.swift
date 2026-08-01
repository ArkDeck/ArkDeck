import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

enum NativeLibraryTestFixture {
  static let buildID = "00112233445566778899aabbccddeeff10213243"

  static func arm64ELF(marker: UInt8 = 0xA5) -> Data {
    var bytes = Data(repeating: marker, count: 256)
    bytes[0] = 0x7F
    bytes[1] = 0x45
    bytes[2] = 0x4C
    bytes[3] = 0x46
    bytes[4] = 2  // ELFCLASS64
    bytes[5] = 1  // little endian
    write16(183, to: &bytes, at: 18)  // EM_AARCH64
    write64(64, to: &bytes, at: 40)  // section table
    write16(64, to: &bytes, at: 58)
    write16(1, to: &bytes, at: 60)

    // One SHT_NOTE section containing a GNU build-id note.
    write32(7, to: &bytes, at: 68)
    write64(128, to: &bytes, at: 88)
    write64(36, to: &bytes, at: 96)
    write32(4, to: &bytes, at: 128)
    write32(20, to: &bytes, at: 132)
    write32(3, to: &bytes, at: 136)
    bytes.replaceSubrange(140..<144, with: Data([0x47, 0x4E, 0x55, 0]))
    let buildIDBytes = stride(from: 0, to: buildID.count, by: 2).map { index in
      UInt8(buildID.dropFirst(index).prefix(2), radix: 16)!
    }
    bytes.replaceSubrange(144..<164, with: buildIDBytes)
    appendSyntheticCodeSignBlock(to: &bytes)
    return bytes
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func write16(_ value: UInt16, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8(value >> 8)
  }

  private static func write32(_ value: UInt32, to data: inout Data, at offset: Int) {
    for index in 0..<4 {
      data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xFF)
    }
  }

  private static func write64(_ value: UInt64, to data: inout Data, at offset: Int) {
    for index in 0..<8 {
      data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xFF)
    }
  }

  private static func appendSyntheticCodeSignBlock(to data: inout Data) {
    let signedDataSize = data.count
    let infoOffset = 20
    let signatureSize = 16
    let infoPrefixSize = 264
    let blockSize = infoOffset + infoPrefixSize + signatureSize
    var block = Data(repeating: 0, count: blockSize)
    write16(3, to: &block, at: 0)
    write32(UInt32(infoOffset - 8), to: &block, at: 8)
    write32(2, to: &block, at: 12)
    write32(0, to: &block, at: 16)
    write32(1, to: &block, at: infoOffset)
    write32(
      UInt32(infoPrefixSize - 8 + signatureSize),
      to: &block, at: infoOffset + 4)
    block[infoOffset + 8] = 1
    block[infoOffset + 9] = 1
    block[infoOffset + 10] = 12
    write32(UInt32(signatureSize), to: &block, at: infoOffset + 12)
    write64(UInt64(signedDataSize), to: &block, at: infoOffset + 16)
    block.replaceSubrange(
      (infoOffset + 24)..<(infoOffset + 56),
      with: Data(repeating: 0x42, count: 32))
    block[infoOffset + 263] = 1
    block.replaceSubrange(
      (infoOffset + infoPrefixSize)..<(infoOffset + infoPrefixSize + signatureSize),
      with: Data(repeating: 0x30, count: signatureSize))
    data.append(block)
    data.append(Data("elf sign block  ".utf8))
    data.append(Data("1000".utf8))
    var headerTail = Data(repeating: 0, count: 12)
    write32(UInt32(blockSize), to: &headerTail, at: 0)
    write32(1, to: &headerTail, at: 4)
    data.append(headerTail)
  }
}

final class NativeLibraryDeploymentContractTests: XCTestCase {
  private static let identity =
    "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-native-deployment-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let stateDirectory {
      try? FileManager.default.removeItem(at: stateDirectory)
    }
  }

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256: NativeLibraryDeploymentContractTests.identity,
        executionConnectKey: "150100424a544e4600",
        deviceMode: "hdc", buildFingerprint: "fixture-build",
        profileID: "dayu200@1", collectedAtUTC: "2026-07-30T00:00:00Z")
    }
  }

  private final class NativeDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    enum Mode {
      case success
      case loaderFailure
      case publishOutcomeUnknown
      case cleanupFailure
      case cleanupContinuation
    }

    let mode: Mode
    let newHash: String
    let oldHash = String(repeating: "c", count: 64)
    private let lock = NSLock()
    private var actions: [String] = []

    init(mode: Mode, newHash: String) {
      self.mode = mode
      self.newHash = newHash
    }

    func actionNames() -> [String] {
      lock.withLock { actions }
    }

    func unavailableReason(providerID: String) -> String? {
      nil
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      func sub(_ stdout: String = "", exit: Int32 = 0) -> ProviderSubprocessReceipt {
        ProviderSubprocessReceipt(
          exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
      func absent(_ path: String = "owned") -> ProviderSubprocessReceipt {
        sub("ls: \(path): No such file or directory\n")
      }
      func receipt(_ subprocesses: [ProviderSubprocessReceipt]) -> ProviderProcessReceipt {
        ProviderProcessReceipt(
          exitStatus: subprocesses.last?.exitStatus,
          stdout: subprocesses.reduce(into: Data()) { $0.append($1.stdout) },
          stderr: Data(), stdoutTruncated: false,
          durationSeconds: 0.01, subprocesses: subprocesses)
      }
      guard case .hdc(let action) = plan.action else {
        throw RuntimeDispatchFailure.failed("unexpected provider")
      }
      let name: String
      switch action {
      case .sendNativeLibraryToStaging:
        name = "send"
      case .backupNativeLibrary:
        name = "backup"
      case .publishNativeLibrary:
        name = "publish"
      case .stopNativeTarget:
        name = "stop"
      case .startNativeTarget:
        name = "start"
      case .cleanupNativeLibrary:
        name = "cleanup"
      case .rollbackNativeLibrary:
        name = "rollback"
      case .inspectNativeLibrary(_, let expectation):
        name = "inspect:\(expectation.rawValue)"
      default:
        throw RuntimeDispatchFailure.failed("unexpected native test action")
      }
      lock.withLock { actions.append(name) }

      switch action {
      case .sendNativeLibraryToStaging(let deployment):
        return receipt([
          sub(), sub(), sub(), sub(),
          sub("\(deployment.codeSignHelperFacts!.sha256)  helper\n"),
        ])
      case .inspectNativeLibrary(_, .stagingMatchesArtifact):
        return receipt([sub("\(newHash)  staging\n"), sub("-rw------- staging\n")])
      case .backupNativeLibrary:
        return receipt([
          sub("drwx------ native\n"), sub("-rw------- target\n"),
          sub("\(oldHash)  target\n"), sub(), sub(),
          sub("\(oldHash)  backup\n"), sub("-rw------- backup\n"),
          sub("total 4\ndrwx------ libs\n"),
        ])
      case .publishNativeLibrary:
        if mode == .publishOutcomeUnknown {
          throw RuntimeDispatchFailure.outcomeUnknown(
            "publish child completion was lost")
        }
        return receipt([
          sub("-rw------- 1 20010050 20010050 16 old\n"),
          sub("ARKDECK_CODE_SIGN_PUBLISHED sha256:\(oldHash)\n"),
          sub("\(newHash)  target\n"),
          sub("ARKDECK_CODE_SIGN_VERIFIED sha256:\(oldHash)\n"),
          sub("-rw------- 1 20010050 20010050 256 target\n"),
        ])
      case .stopNativeTarget:
        return receipt([sub(), sub("4321\n"), sub(), sub("\r\n")])
      case .startNativeTarget:
        return receipt([sub(), sub(), sub("4321\n")])
      case .inspectNativeLibrary(_, .targetLoaded):
        if mode == .loaderFailure {
          return receipt([
            sub("\(newHash)  target\n"),
            sub("ARKDECK_CODE_SIGN_VERIFIED sha256:\(oldHash)\n"),
            sub(exit: 1),
          ])
        }
        return receipt([
          sub("\(newHash)  target\n"),
          sub("ARKDECK_CODE_SIGN_VERIFIED sha256:\(oldHash)\n"),
          sub("4321\n"),
        ])
      case .inspectNativeLibrary(_, .targetMatchesArtifact):
        return receipt([
          sub("\(newHash)  target\n"),
          sub("ARKDECK_CODE_SIGN_VERIFIED sha256:\(oldHash)\n"),
        ])
      case .inspectNativeLibrary(_, .cleanupComplete):
        if mode == .cleanupContinuation {
          return receipt([
            sub("-rw------- staging\n"), sub("-rwx------ helper\n"),
            sub("drwx------ staging-directory\n"), absent("rollback"),
            absent("backup"),
          ])
        }
        return receipt([
          absent("staging"), absent("helper"),
          absent("staging-directory"), absent("rollback"), absent("backup"),
        ])
      case .rollbackNativeLibrary(let deployment):
        return receipt([
          sub("\(oldHash)  backup\n"), sub(), sub("4321\n"), sub(),
          sub("\r\n"), sub(), sub(), sub(), sub("\(oldHash)  target\n"),
          sub(), sub(), sub("4321\n"),
          sub("/proc/4321/maps:7f000 \(deployment.loaderVisiblePath)\n"),
        ])
      case .cleanupNativeLibrary:
        if mode == .cleanupFailure {
          return receipt([
            sub(), sub(), sub(), sub(), sub(),
            sub("-rw------- staging\n"), sub("-rwx------ helper\n"),
            sub("drwx------ staging-directory\n"), absent("rollback"),
            absent("backup"),
          ])
        }
        return receipt([
          sub(), sub(), sub(), sub(), sub(),
          absent("staging"), absent("helper"), absent("staging-directory"),
          absent("rollback"), absent("backup"),
        ])
      default:
        throw RuntimeDispatchFailure.failed("unexpected inspection")
      }
    }
  }

  func testELFValidatorPinsABIAndBuildID() throws {
    let bytes = NativeLibraryTestFixture.arm64ELF()
    let facts = try NativeLibraryArtifactValidator.validate(
      bytes, expectedABI: .arm64)
    XCTAssertEqual(facts.abi, .arm64)
    XCTAssertEqual(facts.machine, 183)
    XCTAssertEqual(facts.elfClassBits, 64)
    XCTAssertEqual(facts.buildID, NativeLibraryTestFixture.buildID)
    XCTAssertEqual(facts.sha256, NativeLibraryTestFixture.sha256(bytes))
    XCTAssertEqual(facts.codeSign?.formatVersion, 1)
    XCTAssertEqual(facts.codeSign?.signedDataByteCount, 256)
    XCTAssertNoThrow(
      try NativeLibraryArtifactValidator.validate(
        bytes, expectedABI: .arm64,
        requireOpenHarmonyCodeSignature: true))
    XCTAssertThrowsError(
      try NativeLibraryArtifactValidator.validate(
        bytes.dropLast(332), expectedABI: .arm64,
        requireOpenHarmonyCodeSignature: true))
    XCTAssertThrowsError(
      try NativeLibraryArtifactValidator.validate(bytes, expectedABI: .arm32))

    var noBuildID = bytes
    noBuildID[68] = 1
    XCTAssertThrowsError(
      try NativeLibraryArtifactValidator.validate(noBuildID, expectedABI: .arm64))
  }

  func testBundledCodeSignHelperIsAValidatedStaticArm64Executable() throws {
    let helper = try HDCNativeCodeSignHelperArtifact.bundled()
    let contents = try Data(contentsOf: helper.fileURL)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: helper.fileURL.path)
    let permissions = try XCTUnwrap(
      (attributes[.posixPermissions] as? NSNumber)?.intValue)

    XCTAssertEqual(helper.facts.abi, .arm64)
    XCTAssertEqual(helper.facts.byteCount, contents.count)
    XCTAssertEqual(helper.facts.sha256, NativeLibraryTestFixture.sha256(contents))
    XCTAssertEqual(helper.facts.buildID.count, 40)
    XCTAssertEqual(
      permissions & 0o111, 0,
      "the host bundle must carry the device helper as data; "
        + "the typed send plan chmods it remotely")
  }

  func testNativeProviderPlanIsAvailablePathClosedAndDescriptorBound() throws {
    let bytes = NativeLibraryTestFixture.arm64ELF()
    let file = stateDirectory.appendingPathComponent("libarkdeck_gj.so")
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    try bytes.write(to: file)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: "deploy.native-library.app-owned@1"))
    let provider = HDCObservationProviderAdapter(
      factsPort: FactsPort(),
      appOwnedNativeLibraryAvailability: .available)
    XCTAssertEqual(provider.runtimeAvailability(for: descriptor), .available)
    let inputs: [String: JSONValue] = [
      "libraryArtifactLease": .string("lease-v1:input:ART-1"),
      "targetBundle": .string("com.example.nativegj"),
      "libraryLogicalName": .string("libarkdeck_gj.so"),
      "expectedABI": .string("arm64-v8a"),
    ]
    let resolved = ProviderResolvedInputArtifact(
      artifactID: "ART-1", fileURL: file,
      sha256: NativeLibraryTestFixture.sha256(bytes), byteCount: bytes.count)
    let step = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "atomic-publish" })
    let context = ProviderExecutionContext(
      jobID: "job-native-test", stepID: step.stepID,
      targetID: "TGT-001", bindingRevision: 7,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256: Self.identity,
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-30T00:00:00Z",
      resolvedInputArtifact: resolved)
    let action = try provider.action(
      for: step, operation: descriptor, inputs: inputs, context: context)
    guard case .hdc(.publishNativeLibrary(let deployment)) = action else {
      return XCTFail("atomic publish must materialize its native deployment")
    }
    let plan = try provider.lower(action: action, context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      return XCTFail("native publish must lower to an exact sequence")
    }
    XCTAssertFalse(invocations.isEmpty)
    XCTAssertTrue(
      invocations.allSatisfy {
        Array($0.arguments.prefix(2)) == ["-t", "150100424a544e4600"]
      })
    XCTAssertEqual(
      invocations.map { Array($0.arguments.dropFirst(2)) },
      [
        ["shell", "ls", "-ln", deployment.targetPath],
        [
          "shell", deployment.codeSignHelperRemotePath!, "publish",
          deployment.stagingPath, deployment.targetPath,
          deployment.rollbackStagingPath,
        ],
        ["shell", "sha256sum", deployment.targetPath],
        [
          "shell", deployment.codeSignHelperRemotePath!, "verify",
          deployment.targetPath,
        ],
        ["shell", "ls", "-ln", deployment.targetPath],
      ])
    let allArguments = invocations.flatMap(\.arguments).joined(separator: " ")
    XCTAssertFalse(allArguments.contains("/tmp/"))
    XCTAssertFalse(allArguments.contains("caller"))
    XCTAssertTrue(allArguments.contains("com.example.nativegj"))

    XCTAssertEqual(
      deployment.loaderVisiblePath,
      "/data/storage/el1/bundle/libs/arm/libarkdeck_gj.so")
    XCTAssertEqual(
      deployment.directoryPath,
      "/data/app/el1/bundle/public/com.example.nativegj/libs/arm")
    XCTAssertEqual(
      deployment.stagingDirectoryPath,
      "/data/app/el2/100/base/com.example.nativegj/haps/entry/files/"
        + "arkdeck-native/job-native-test")
    let sendAction = TypedProviderAction.hdc(.sendNativeLibraryToStaging(deployment))
    let sendPlan = try provider.lower(action: sendAction, context: context)
    guard case .processSequence(_, let sendInvocations) = sendPlan.kind else {
      return XCTFail("native send must prepare a stable app-owned staging directory")
    }
    XCTAssertEqual(sendInvocations.count, 5)
    XCTAssertEqual(
      sendInvocations[0].arguments,
      [
        "-t", "150100424a544e4600", "shell", "mkdir", "-p",
        deployment.stagingDirectoryPath,
      ])
    XCTAssertEqual(
      sendInvocations[1].arguments,
      [
        "-t", "150100424a544e4600", "file", "send", file.path,
        deployment.stagingPath,
      ])
    XCTAssertEqual(
      sendInvocations[2].arguments.last,
      deployment.codeSignHelperRemotePath!)
    XCTAssertEqual(
      Array(sendInvocations[3].arguments.suffix(3)),
      ["chmod", "700", deployment.codeSignHelperRemotePath!])
    XCTAssertEqual(
      Array(sendInvocations[4].arguments.suffix(2)),
      ["sha256sum", deployment.codeSignHelperRemotePath!])
    let stopAction = TypedProviderAction.hdc(.stopNativeTarget(deployment))
    let stopPlan = try provider.lower(action: stopAction, context: context)
    guard case .processSequence(_, let stopInvocations) = stopPlan.kind else {
      return XCTFail("native stop must lower to a bounded process sequence")
    }
    XCTAssertEqual(stopInvocations.count, 4)
    XCTAssertEqual(
      stopInvocations.map(\.arguments),
      [
        ["-t", "150100424a544e4600", "shell", "aa", "force-stop",
          "com.example.nativegj"],
        ["-t", "150100424a544e4600", "shell", "pidof",
          "com.example.nativegj"],
        ["-t", "150100424a544e4600", "shell", "sleep", "2"],
        ["-t", "150100424a544e4600", "shell", "pidof",
          "com.example.nativegj"],
      ])

    func stopReceipt(
      finalStdout: String, finalStderr: String = "", finalExit: Int32
    ) -> ProviderProcessReceipt {
      let subprocesses = [
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01),
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data("4321\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01),
        ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01),
        ProviderSubprocessReceipt(
          exitStatus: finalExit, stdout: Data(finalStdout.utf8),
          stderr: Data(finalStderr.utf8),
          stdoutTruncated: false, durationSeconds: 0.01),
      ]
      return ProviderProcessReceipt(
        exitStatus: finalExit, stdout: Data(), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.04,
        subprocesses: subprocesses)
    }

    let observedEmpty = try provider.verify(
      receipt: stopReceipt(finalStdout: "\r\n", finalExit: 0),
      action: stopAction, context: context)
    guard case .verified = observedEmpty else {
      return XCTFail("DAYU200 exit-0 empty pidof readback must prove absence")
    }
    let observedPID = try provider.verify(
      receipt: stopReceipt(finalStdout: "4321\n", finalExit: 0),
      action: stopAction, context: context)
    guard case .failed(let code, _) = observedPID else {
      return XCTFail("numeric pidof readback must fail closed")
    }
    XCTAssertEqual(code, "nativeTargetStillRunning")
    let observedStderr = try provider.verify(
      receipt: stopReceipt(
        finalStdout: "", finalStderr: "pidof unavailable\n", finalExit: 1),
      action: stopAction, context: context)
    guard case .failed(let stderrCode, _) = observedStderr else {
      return XCTFail("pidof stderr must not be accepted as process absence")
    }
    XCTAssertEqual(stderrCode, "nativeTargetStillRunning")
  }

  func testProductionNativeOperationIsAvailableAndUnresolvedInputFailsBeforeCapability()
    async throws
  {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: "deploy.native-library.app-owned@1"))
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort())
    XCTAssertEqual(provider.runtimeAvailability(for: descriptor), .available)

    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent(
        "capabilities-unavailable", isDirectory: true))
    let dispatcher = NativeDispatcher(
      mode: .success, newHash: String(repeating: "a", count: 64))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent(
        "artifacts-unavailable", isDirectory: true),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent(
          "engine-unavailable", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let operationAvailability = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      operationAvailability.first {
        $0.reference == descriptor.reference
      })
    XCTAssertEqual(availability.state, .available)
    XCTAssertTrue(availability.reasons.isEmpty)

    let request = try RuntimeOperationRequest(
      requestID: "request-native-unavailable",
      idempotencyKey: "execution-native-unavailable",
      target: DurableTargetReference(
        targetID: "TGT-001", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(
        id: "deploy.native-library.app-owned", version: 1),
      inputs: [
        "libraryArtifactLease": .string("lease-v1:unresolved:ART-unresolved"),
        "targetBundle": .string("com.example.nativegj"),
        "libraryLogicalName": .string("libarkdeck_gj.so"),
        "expectedABI": .string("arm64-v8a"),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      _ = try await engine.submit(try encoder.encode(request))
      XCTFail("unresolved native Artifact must reject")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Artifact"))
    }
    XCTAssertTrue(dispatcher.actionNames().isEmpty)
    let capabilities = try await capabilityStore.list()
    XCTAssertTrue(capabilities.isEmpty)
  }

  func testPersistedNativeActionReusesExactClosedLegacyPaths() throws {
    let jobID = "job-native-legacy-paths"
    let bundleName = "com.example.nativegj"
    let libraryName = "libarkdeck_gj.so"
    let directory =
      "/data/app/el1/bundle/public/\(bundleName)/libs/arm64"
    let stagingDirectory =
      "/data/app/el2/100/base/\(bundleName)/haps/entry/files/"
      + "arkdeck-native/\(jobID)"
    var arguments: [String: Any] = [
      "jobId": jobID,
      "artifactLeaseId": "lease-v1:input:ART-1",
      "artifactId": "ART-1",
      "bundleName": bundleName,
      "libraryLogicalName": libraryName,
      "abi": "arm64-v8a",
      "elfClassBits": 64,
      "machine": 183,
      "buildId": NativeLibraryTestFixture.buildID,
      "sha256": String(repeating: "a", count: 64),
      "byteCount": 256,
      "restartProfile": "restartAbility",
      "verificationProfile": "hashProcessAndMaps",
      "rollbackPolicy": "autoRollback",
      "directoryPath": directory,
      "targetPath": "\(directory)/\(libraryName)",
      "loaderVisiblePath": "/data/storage/el1/bundle/libs/arm64/\(libraryName)",
      "stagingDirectoryPath": stagingDirectory,
      "stagingPath": "\(stagingDirectory)/\(libraryName).staging",
      "backupPath": "\(directory)/.\(libraryName).arkdeck-\(jobID).backup",
      "rollbackStagingPath":
        "\(directory)/.\(libraryName).arkdeck-\(jobID).rollback",
    ]
    func decode(_ actionArguments: [String: Any]) throws -> PersistedTypedProviderAction {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "kind": "hdc.cleanupNativeLibrary",
          "arguments": actionArguments,
        ])
      return try JSONDecoder().decode(PersistedTypedProviderAction.self, from: data)
    }

    guard
      case .hdc(.cleanupNativeLibrary(let recovered)) =
        try decode(arguments).materialize()
    else {
      return XCTFail("persisted native cleanup must materialize its exact typed action")
    }
    XCTAssertEqual(recovered.directoryPath, directory)
    XCTAssertEqual(recovered.stagingDirectoryPath, stagingDirectory)
    XCTAssertEqual(
      recovered.loaderVisiblePath,
      "/data/storage/el1/bundle/libs/arm64/\(libraryName)")

    arguments["backupPath"] = "/data/local/tmp/escaped.backup"
    XCTAssertThrowsError(try decode(arguments).materialize())

    arguments["backupPath"] =
      "\(directory)/.\(libraryName).arkdeck-\(jobID).backup"
    arguments.removeValue(forKey: "stagingDirectoryPath")
    arguments["stagingPath"] =
      "\(directory)/.\(libraryName).arkdeck-\(jobID).staging"
    guard
      case .hdc(.cleanupNativeLibrary(let legacyCleanup)) =
        try decode(arguments).materialize()
    else {
      return XCTFail("legacy exact cleanup action must remain recoverable")
    }
    XCTAssertFalse(legacyCleanup.stagingDirectoryIsJobOwned)
    let provider = HDCObservationProviderAdapter(
      factsPort: FactsPort(),
      appOwnedNativeLibraryAvailability: .available)
    let context = ProviderExecutionContext(
      jobID: jobID, stepID: "cleanup-native-library-compensation",
      targetID: "TGT-001", bindingRevision: 7,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256: Self.identity,
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-30T00:00:00Z")
    let plan = try provider.lower(
      action: .hdc(.cleanupNativeLibrary(legacyCleanup)), context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      return XCTFail("legacy cleanup must lower to its exact bounded sequence")
    }
    XCTAssertFalse(
      invocations.contains {
        Array($0.arguments.suffix(3)) == ["shell", "rmdir", directory]
      },
      "recovery must never remove the shared installed-library directory")
  }

  func testNativeSuccessPublishesReportsAndLoaderFailureRollsBack() async throws {
    let success = try await runNative(mode: .success, suffix: "success")
    XCTAssertEqual(
      success.status.state, "succeeded",
      "timeline: \(success.status.timeline)")
    XCTAssertEqual(
      Set(success.artifacts.map(\.name)),
      Set(["publish-report.json", "verification-report.json"]))
    XCTAssertFalse(success.dispatcher.actionNames().contains("rollback"))

    let failed = try await runNative(mode: .loaderFailure, suffix: "rollback")
    XCTAssertEqual(failed.status.state, "failed")
    XCTAssertTrue(failed.dispatcher.actionNames().contains("rollback"))
    XCTAssertTrue(
      failed.status.timeline.contains {
        $0.contains("restored previous library")
      })
  }

  func testPublishOutcomeUnknownNeverDispatchesRollbackOrResend() async throws {
    let result = try await runNative(
      mode: .publishOutcomeUnknown, suffix: "unknown")
    XCTAssertEqual(
      result.status.state, "waitingForRecovery",
      "timeline: \(result.status.timeline)")
    XCTAssertTrue(result.status.outcomeUnknown)
    XCTAssertEqual(
      result.dispatcher.actionNames().filter { $0 == "publish" }.count, 1)
    XCTAssertFalse(result.dispatcher.actionNames().contains("rollback"))
  }

  func testRestartReconcilesExactPublishIntentWithoutResend() async throws {
    let initial = try await runNative(
      mode: .publishOutcomeUnknown, suffix: "restart-reconcile")
    XCTAssertEqual(initial.status.state, "waitingForRecovery")

    let recoveryDispatcher = NativeDispatcher(
      mode: .success, newHash: initial.newHash)
    let recovered = try makeRecoveredEngine(
      suffix: "restart-reconcile", dispatcher: recoveryDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let reconciled = try await recovered.reconcile(jobID: initial.jobID)
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(
      recoveryDispatcher.actionNames(), ["inspect:targetMatchesArtifact"],
      "restart must reconcile the persisted publish action through its dedicated hash readback")

    let resumed = try await recovered.run(jobID: initial.jobID)
    XCTAssertEqual(resumed.state, "succeeded", resumed.timeline.joined(separator: " | "))
    let actions = recoveryDispatcher.actionNames()
    XCTAssertFalse(actions.contains("send"))
    XCTAssertFalse(actions.contains("backup"))
    XCTAssertFalse(actions.contains("publish"))
  }

  func testNativeCleanupDebtSurvivesRestartAndIsExplicitlyConsumed() async throws {
    let initial = try await runNative(
      mode: .cleanupFailure, suffix: "cleanup-debt")
    XCTAssertEqual(initial.status.state, "succeeded")
    let recordedDebt = try await initial.engine.listCleanupDebt()
    let debt = try XCTUnwrap(recordedDebt.first)
    XCTAssertEqual(debt.jobID, initial.jobID)

    let continuationDispatcher = NativeDispatcher(
      mode: .cleanupContinuation, newHash: initial.newHash)
    let recovered = try makeRecoveredEngine(
      suffix: "cleanup-debt", dispatcher: continuationDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let continuation = try await recovered.continueCleanupDebt(
      jobID: debt.jobID, identity: debt.remotePath)
    XCTAssertEqual(continuation.state, .settled)
    XCTAssertEqual(
      continuationDispatcher.actionNames(),
      ["inspect:cleanupComplete", "cleanup"])
    let remainingDebt = try await recovered.listCleanupDebt()
    XCTAssertTrue(remainingDebt.isEmpty)
  }

  private func runNative(
    mode: NativeDispatcher.Mode,
    suffix: String
  ) async throws -> (
    status: RuntimeJobStatus,
    artifacts: [RuntimeArtifactMetadata],
    dispatcher: NativeDispatcher,
    engine: RuntimeJobEngine,
    jobID: String,
    newHash: String
  ) {
    let bytes = NativeLibraryTestFixture.arm64ELF(
      marker: UInt8(truncatingIfNeeded: suffix.utf8.first ?? 0xA5))
    let hash = NativeLibraryTestFixture.sha256(bytes)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent(
        "artifacts-\(suffix)", isDirectory: true),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let input = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "input-so-\(suffix)", sessionID: "session-input-so-\(suffix)",
        stepID: "import-native-library", name: "libarkdeck_gj.so",
        mediaType: "application/x-elf", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-native-library", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-001", bindingRevision: 7,
          stableIdentitySHA256: Self.identity),
        contents: bytes))
    let lease = try await artifactStore.leaseReference(
      jobID: input.jobID, artifactID: input.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent(
        "capabilities-\(suffix)", isDirectory: true))
    let dispatcher = NativeDispatcher(mode: mode, newHash: hash)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent(
          "engine-\(suffix)", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(
          factsPort: FactsPort(),
          appOwnedNativeLibraryAvailability: .available)
      ]),
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-30T00:00:00Z" })
    let base = try RuntimeOperationRequest(
      requestID: "request-native-\(suffix)",
      idempotencyKey: "execution-native-\(suffix)",
      target: DurableTargetReference(
        targetID: "TGT-001", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(
        id: "deploy.native-library.app-owned", version: 1),
      inputs: [
        "libraryArtifactLease": .string(lease),
        "targetBundle": .string("com.example.nativegj"),
        "libraryLogicalName": .string("libarkdeck_gj.so"),
        "expectedABI": .string("arm64-v8a"),
        "restartProfile": .string("restartAbility"),
        "verificationProfile": .string("hashAndProcess"),
        "rollbackPolicy": .string("autoRollback"),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let acceptance = try await engine.submit(try encoder.encode(base))
    let status = try await engine.run(jobID: acceptance.jobID)
    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    return (status, artifacts, dispatcher, engine, acceptance.jobID, hash)
  }

  private func makeRecoveredEngine(
    suffix: String,
    dispatcher: NativeDispatcher
  ) throws -> RuntimeJobEngine {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent(
        "artifacts-\(suffix)", isDirectory: true),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent(
        "capabilities-\(suffix)", isDirectory: true))
    return try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent(
          "engine-\(suffix)", isDirectory: true)),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(
          factsPort: FactsPort(),
          appOwnedNativeLibraryAvailability: .available)
      ]),
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-30T00:00:00Z" })
  }
}
