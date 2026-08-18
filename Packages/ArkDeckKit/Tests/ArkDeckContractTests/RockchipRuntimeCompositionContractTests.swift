import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckProcess
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RockchipRuntimeCompositionContractTests: XCTestCase {
  private static let reviewedSignedComponentSHA256 =
    String(repeating: "c", count: 64)

  private actor ActionLog {
    private var actions: [RockchipProviderAction] = []
    private var intentWasDurable: [Bool] = []

    func append(_ action: RockchipProviderAction, intentExists: Bool) {
      actions.append(action)
      intentWasDurable.append(intentExists)
    }

    func snapshot() -> ([RockchipProviderAction], [Bool]) {
      (actions, intentWasDurable)
    }
  }

  private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  private final class LockedPercentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }

    var snapshot: [Int] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  private actor ProcessProgressLog {
    private var values: [RuntimeProcessProgress] = []

    func append(_ value: RuntimeProcessProgress) { values.append(value) }
    func snapshot() -> [RuntimeProcessProgress] { values }
  }

  private struct SuccessfulActionExecutor: RockchipRuntimeActionExecuting {
    let log: ActionLog

    func unavailableReason() -> String? { nil }

    func execute(
      action: RockchipProviderAction,
      descriptor _: HostManagedProcessDescriptor,
      rockchipExecutable _: ResolvedExecutable,
      actionDirectory: URL
    ) async throws -> RockchipRuntimeActionExecutionResult {
      await log.append(
        action,
        intentExists: FileManager.default.fileExists(
          atPath: actionDirectory.appending(path: "intent.json").path))
      return RockchipRuntimeActionExecutionResult(
        summary: ["semantic": "verified"],
        stdout: Data("verified\n".utf8),
        stderr: Data(),
        stdoutTruncated: false,
        subprocesses: [
          ProviderSubprocessReceipt(
            exitStatus: 0,
            stdout: Data("verified\n".utf8),
            stderr: Data(),
            stdoutTruncated: false,
            durationSeconds: 0)
        ])
    }
  }

  private struct InterruptedActionExecutor: RockchipRuntimeActionExecuting {
    let log: ActionLog

    func unavailableReason() -> String? { nil }

    func execute(
      action: RockchipProviderAction,
      descriptor _: HostManagedProcessDescriptor,
      rockchipExecutable _: ResolvedExecutable,
      actionDirectory: URL
    ) async throws -> RockchipRuntimeActionExecutionResult {
      await log.append(
        action,
        intentExists: FileManager.default.fileExists(
          atPath: actionDirectory.appending(path: "intent.json").path))
      throw RuntimeDispatchFailure.outcomeUnknown(
        "fixture interrupted after durable host intent")
    }
  }

  private struct PostflightActionExecutor: RockchipRuntimeActionExecuting {
    func unavailableReason() -> String? { nil }

    func execute(
      action _: RockchipProviderAction,
      descriptor _: HostManagedProcessDescriptor,
      rockchipExecutable _: ResolvedExecutable,
      actionDirectory _: URL
    ) async throws -> RockchipRuntimeActionExecutionResult {
      RockchipRuntimeActionExecutionResult(
        summary: [
          "model": RockchipFlashProfile.dayu200.runtimeProductModel,
          "firmware": RockchipFlashProfile.dayu200.runtimeBuildVersion,
          "hdcIdentitySha256": String(repeating: "d", count: 64),
          "usbTopology": "42",
          "verification": "exact-published-profile-and-bound-hdc",
        ],
        stdout: Data("ohos\nOpenHarmony-7.0.0.37\n".utf8),
        stderr: Data(),
        stdoutTruncated: false,
        subprocesses: [
          ProviderSubprocessReceipt(
            exitStatus: 0,
            stdout: Data("ohos\nOpenHarmony-7.0.0.37\n".utf8),
            stderr: Data(),
            stdoutTruncated: false,
            durationSeconds: 0)
        ])
    }
  }

  private actor CommandLog {
    struct Invocation: Sendable, Equatable {
      let executable: String
      let arguments: [String]
      let criticalNonInterruptible: Bool
    }

    private var invocations: [Invocation] = []
    private var listCount = 0
    private let productModel: String
    private let buildVersion: String
    private let connectedTarget: String
    private let emptyFirstTargetList: Bool

    init(
      productModel: String = RockchipFlashProfile.dayu200.runtimeProductModel,
      buildVersion: String = RockchipFlashProfile.dayu200.runtimeBuildVersion,
      connectedTarget: String = "device-1",
      emptyFirstTargetList: Bool = true
    ) {
      self.productModel = productModel
      self.buildVersion = buildVersion
      self.connectedTarget = connectedTarget
      self.emptyFirstTargetList = emptyFirstTargetList
    }

    func run(
      executable: ResolvedExecutable,
      arguments: [String],
      criticalNonInterruptible: Bool
    ) -> ProviderSubprocessReceipt {
      invocations.append(
        Invocation(
          executable: executable.path,
          arguments: arguments,
          criticalNonInterruptible: criticalNonInterruptible))
      let stdout: String
      switch arguments {
      case ["list", "targets", "-v"]:
        listCount += 1
        stdout =
          emptyFirstTargetList && listCount == 1
          ? "[Empty]\n"
          : "\(connectedTarget)\t\tUSB\tConnected\tlocalhost\n"
      case ["ld"]:
        stdout = "DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader\n"
      case ["ppt"]:
        stdout = Self.partitionTable
      case ["rd"]:
        stdout = "Reset Device OK.\n"
      case let value
      where value.suffix(4)
        == ["shell", "param", "get", HDCAllowlistedProperty.productModel.rawValue]:
        stdout = "const.product.model = \(productModel)\n"
      case let value
      where value.suffix(4)
        == ["shell", "param", "get", HDCAllowlistedProperty.fullBuildVersion.rawValue]:
        stdout = "const.ohos.fullname = \(buildVersion)\n"
      case let value where value.count >= 3 && value.suffix(3) == ["shell", "hilog", "-x"]:
        stdout = "post-flash hilog\n"
      case let value where value.first == "wl" || value.first == "wlx":
        stdout = "Write LBA from file (100%)\n"
      default:
        stdout = ""
      }
      return ProviderSubprocessReceipt(
        exitStatus: 0,
        stdout: Data(stdout.utf8),
        stderr: Data(),
        stdoutTruncated: false,
        durationSeconds: 0)
    }

    func snapshot() -> [Invocation] { invocations }

    private static let partitionTable =
      """
      **********Partition Info(GPT)**********
      NO  LBA       Name
      00  00002000  uboot
      01  00004000  misc
      02  00006000  bootctrl
      03  00007000  resource
      04  0000A000  boot_linux
      05  0003A000  ramdisk
      06  0003C000  system
      07  0043C000  vendor
      08  0063C000  sys-prod
      09  00655000  chip-prod
      10  0066E000  updater
      11  0067E000  eng_system
      12  00686000  eng_chipset
      13  0069E000  chip_ckm
      14  01308000  userdata
      """
  }

  private struct ScriptedCommandRunner: RockchipRuntimeCommandRunning {
    let log: CommandLog

    func run(
      executable: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible: Bool
    ) async throws -> ProviderSubprocessReceipt {
      // The pre-write medium probe reads real sectors, so the script has to
      // produce them: the primary header and the backup it names, with the
      // DAYU200 geometry the pinned table describes.
      if arguments.count == 4, arguments[0] == "rl",
        let begin = Int64(arguments[1]), let count = Int64(arguments[2])
      {
        FileManager.default.createFile(
          atPath: arguments[3],
          contents: Self.sectors(begin: begin, count: count))
      }
      return await log.run(
        executable: executable,
        arguments: arguments,
        criticalNonInterruptible: criticalNonInterruptible)
    }

    static func sectors(begin: Int64, count: Int64) -> Data {
      var payload = Data(repeating: 0, count: Int(count) * 512)
      func writeHeader(at offset: Int, myLBA: Int64, alternateLBA: Int64) {
        payload.replaceSubrange(offset..<(offset + 8), with: Array("EFI PART".utf8))
        for (index, value) in [
          (24, myLBA), (32, alternateLBA), (40, Int64(34)), (48, Int64(61_071_326)),
        ] {
          var raw = UInt64(bitPattern: value)
          for byte in 0..<8 {
            payload[offset + index + byte] = UInt8(raw & 0xFF)
            raw >>= 8
          }
        }
      }
      if begin <= 1, begin + count > 1 {
        writeHeader(at: Int(1 - begin) * 512, myLBA: 1, alternateLBA: 61_071_359)
      }
      if begin <= 61_071_359, begin + count > 61_071_359 {
        writeHeader(at: Int(61_071_359 - begin) * 512, myLBA: 61_071_359, alternateLBA: 1)
      }
      return payload
    }
  }

  private struct FixedUSBProbe: RockchipRuntimeUSBProbing {
    let identity: String
    let normalIdentity: String?

    init(identity: String, normalIdentity: String? = nil) {
      self.identity = identity
      self.normalIdentity = normalIdentity
    }

    func singleLoader(
      stableIdentitySHA256: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      guard stableIdentitySHA256 == identity else {
        throw RuntimeDispatchFailure.failed("identity mismatch")
      }
      return RockchipRuntimeLoaderIdentity(
        serialDigestSHA256: identity,
        topology: "42")
    }

    func singleHDCNormal(
      stableIdentitySHA256: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      let expected = normalIdentity ?? identity
      guard stableIdentitySHA256 == expected else {
        throw RuntimeDispatchFailure.failed("identity mismatch")
      }
      return RockchipRuntimeLoaderIdentity(
        serialDigestSHA256: expected,
        topology: "42")
    }
  }

  private struct TopologyBoundUSBProbe: RockchipRuntimeUSBProbing {
    let connectKey: String
    let topology: String
    let reportedTopology: String
    let reportedDigest: String

    init(
      connectKey: String,
      topology: String,
      reportedTopology: String? = nil,
      reportedDigest: String? = nil
    ) {
      self.connectKey = connectKey
      self.topology = topology
      self.reportedTopology = reportedTopology ?? topology
      self.reportedDigest =
        reportedDigest
        ?? SHA256.hash(data: Data(connectKey.utf8))
        .map { String(format: "%02x", $0) }.joined()
    }

    func singleLoader(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture has no Loader")
    }

    func singleHDCNormal(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture uses topology-bound HDC")
    }

    func singleHDCNormal(
      usbTopology: String
    ) throws -> RockchipRuntimeHDCIdentity {
      guard usbTopology == topology else {
        throw RuntimeDispatchFailure.failed("fixture topology mismatch")
      }
      return RockchipRuntimeHDCIdentity(
        connectKey: connectKey,
        serialDigestSHA256: reportedDigest,
        topology: reportedTopology)
    }
  }

  private struct NormalOnlyUSBProbe: RockchipRuntimeUSBProbing {
    let identity: String

    init(connectKey: String) {
      identity = SHA256.hash(data: Data(connectKey.utf8))
        .map { String(format: "%02x", $0) }.joined()
    }

    func singleLoader(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture has no Loader")
    }

    func singleHDCNormal(
      stableIdentitySHA256: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      guard stableIdentitySHA256 == identity else {
        throw RuntimeDispatchFailure.failed("identity mismatch")
      }
      return RockchipRuntimeLoaderIdentity(
        serialDigestSHA256: identity,
        topology: "42")
    }
  }

  /// Models the one-way normal-to-Loader transition without letting a test
  /// fixture falsely claim that the Loader existed before the HDC command.
  private final class LoaderAfterInitialProbe: @unchecked Sendable, RockchipRuntimeUSBProbing {
    private let lock = NSLock()
    private var loaderReads = 0
    private let identity: String

    init(identity: String) {
      self.identity = identity
    }

    func singleLoader(
      stableIdentitySHA256: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      guard stableIdentitySHA256 == identity else {
        throw RuntimeDispatchFailure.failed("identity mismatch")
      }
      lock.lock()
      defer { lock.unlock() }
      loaderReads += 1
      guard loaderReads > 1 else {
        throw RuntimeDispatchFailure.failed("fixture Loader has not appeared yet")
      }
      return RockchipRuntimeLoaderIdentity(
        serialDigestSHA256: identity,
        topology: "42")
    }

    func singleHDCNormal(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture has no HDC-normal readback")
    }
  }

  private struct MissingUSBProbe: RockchipRuntimeUSBProbing {
    func singleLoader(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture has no Loader")
    }

    func singleHDCNormal(
      stableIdentitySHA256 _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      throw RuntimeDispatchFailure.failed("fixture has no HDC-normal device")
    }
  }

  private actor ReadbackLog {
    private var partitions: [String] = []

    func append(_ partition: String) {
      partitions.append(partition)
    }

    func snapshot() -> [String] { partitions }
  }


  private struct MaterializingReadbackRunner: RockchipRuntimeCommandRunning {
    let imageBytes: Data
    let baseSector: Int64

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      guard arguments.count == 4, arguments[0] == "rl",
        let sectorCount = Int(arguments[2])
      else {
        throw RuntimeDispatchFailure.failed("unexpected readback argv")
      }
      let offsetSectors = try XCTUnwrap(Int64(arguments[1]))
      let byteOffset = Int((offsetSectors - baseSector) * 512)
      let byteCount = min(sectorCount * 512, imageBytes.count - byteOffset)
      var materialized = imageBytes.subdata(
        in: byteOffset..<(byteOffset + byteCount))
      materialized.append(
        Data(repeating: 0, count: sectorCount * 512 - byteCount))
      try materialized.write(to: URL(filePath: arguments[3]))
      return ProviderSubprocessReceipt(
        exitStatus: 0,
        stdout: Data("Read LBA from device (100%)\n".utf8),
        stderr: Data(),
        stdoutTruncated: false,
        durationSeconds: 0)
    }
  }

  private struct HDCFacts: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "b", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 1,
        deviceIdentitySHA256: String(repeating: "a", count: 64),
        executionConnectKey: "device-1", deviceMode: "hdc",
        buildFingerprint: nil,
        profileID: "openharmony-standard@1",
        collectedAtUTC: "2026-07-31T00:00:00Z")
    }
  }

  private actor DispatchLog {
    private var providers: [String] = []

    func append(_ provider: String) {
      providers.append(provider)
    }

    func snapshot() -> [String] {
      providers
    }
  }

  private struct RecordingDispatcher: RuntimeProcessDispatching {
    let provider: String
    let log: DispatchLog
    let reason: String?

    func unavailableReason(providerID: String) -> String? { reason }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.append(provider)
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(provider.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0)
    }
  }

  // MARK: a refusal before the first write is not a partial write (TASK-AIN-019)

  /// Serves the DAYU200 geometry the pinned table describes, and can be told
  /// to make the backup GPT sector unreadable (the 2026-08-04 device) or to
  /// fail the first `wl` (the case that must stay unresolved).
  private actor WriteAttemptLog {
    private(set) var writes: [String] = []
    func note(_ argv: [String]) { writes.append(argv.joined(separator: " ")) }
  }

  private struct MediumRunner: RockchipRuntimeCommandRunning {
    let log: WriteAttemptLog
    var backupSectorIsErased = false
    var primarySectorIsErased = false
    var firstWriteFails = false

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      var stdout = ""
      switch arguments.first {
      case "ld":
        stdout = "DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader\n"
      case "ppt":
        stdout = Self.partitionTable
      case "rl":
        guard arguments.count == 4, let begin = Int64(arguments[1]),
          let count = Int64(arguments[2])
        else { throw RuntimeDispatchFailure.failed("unexpected rl argv") }
        let erased =
          (backupSectorIsErased && begin != 1) || primarySectorIsErased
        let payload =
          erased
          ? Data(repeating: 0xCC, count: Int(count) * 512)
          : ScriptedCommandRunner.sectors(begin: begin, count: count)
        FileManager.default.createFile(atPath: arguments[3], contents: payload)
        stdout = "Read LBA from device (100%)\n"
      case "wl", "wlx":
        await log.note(arguments)
        if firstWriteFails {
          throw RuntimeDispatchFailure.failed("write refused by the fixture")
        }
        stdout = "Write LBA from file (100%)\n"
      default:
        stdout = ""
      }
      return ProviderSubprocessReceipt(
        exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0)
    }

    private static let partitionTable =
      """
      **********Partition Info(GPT)**********
      NO  LBA       Name
      00  00002000  uboot
      01  00004000  misc
      02  00006000  bootctrl
      03  00007000  resource
      04  0000A000  boot_linux
      05  0003A000  ramdisk
      06  0003C000  system
      07  0043C000  vendor
      08  0063C000  sys-prod
      09  00655000  chip-prod
      10  0066E000  updater
      11  0067E000  eng_system
      12  00686000  eng_chipset
      13  0069E000  chip_ckm
      14  01308000  userdata
      """
  }


  func testWaitForHDCReconnectSurvivesATransientMalformedTargetList() async throws {
    // One malformed snapshot is a moment in USB enumeration, not a verdict
    // about the target; the deadline is the fail-closed boundary. On
    // 2026-08-04 a single such read failed the wait after a fully verified
    // flash and reboot, and the campaign burned while the device booted.
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = PollCounter()
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: TransientMalformedListRunner(counter: counter))
    let component = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .waitForHDCReconnect(connectKey: "device-1"),
      stepID: "wait-for-hdc", toolSHA256: component.sha256)

    let result = try await executor.execute(
      action: .waitForHDCReconnect(connectKey: "device-1"),
      descriptor: hostDescriptor(plan),
      rockchipExecutable: component, actionDirectory: root)

    XCTAssertEqual(result.summary["hdcState"], "connected")
    let polls = await counter.polls
    XCTAssertEqual(polls, 2, "the malformed first read must be re-polled, not fatal")
  }

  func testPostFlashHDCSerialRotationUsesBoundTopologyAndPublishesOnlyAfterExactBuild()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let previousConnectKey = "device-1"
    let nextConnectKey = "device-2"
    let previousDigest = SHA256.hash(data: Data(previousConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let nextDigest = SHA256.hash(data: Data(nextConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let expectation = RockchipHDCReconnectExpectation(
      previousConnectKey: previousConnectKey,
      previousIdentitySHA256: previousDigest,
      usbTopology: "42")
    let store = RockchipPostFlashHDCBindingStore(
      rootURL: root.appending(path: "binding", directoryHint: .isDirectory))
    let log = CommandLog(
      connectedTarget: nextConnectKey, emptyFirstTargetList: false)
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: ScriptedCommandRunner(log: log),
      usbProbe: TopologyBoundUSBProbe(
        connectKey: nextConnectKey, topology: expectation.usbTopology),
      postFlashHDCBindingStore: store,
      nowUTC: { "2026-08-08T01:02:03Z" })
    let component = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))

    let wait = RockchipProviderAction.waitForBoundHDCReconnect(expectation: expectation)
    let waitPlan = try rockchipPlan(
      action: wait, stepID: "wait-for-hdc", toolSHA256: component.sha256)
    let waitResult = try await executor.execute(
      action: wait, descriptor: hostDescriptor(waitPlan),
      rockchipExecutable: component, actionDirectory: root)
    XCTAssertEqual(waitResult.summary["hdcIdentitySha256"], nextDigest)
    XCTAssertEqual(waitResult.summary["usbTopology"], expectation.usbTopology)
    XCTAssertNil(
      try store.loadIfPresent(),
      "reconnect alone must not rotate a trusted route before build verification")

    let verify = RockchipProviderAction.verifyBoundBuild(
      expectation: expectation,
      expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
      expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion)
    let verifyPlan = try rockchipPlan(
      action: verify, stepID: "rebind-and-verify-build", toolSHA256: component.sha256)
    let verified = try await executor.execute(
      action: verify, descriptor: hostDescriptor(verifyPlan),
      rockchipExecutable: component, actionDirectory: root)
    XCTAssertEqual(verified.summary["verification"], "exact-published-profile-and-bound-hdc")

    let binding = try XCTUnwrap(store.loadIfPresent())
    XCTAssertEqual(binding.targetID, "TGT-HOST")
    XCTAssertEqual(binding.bindingRevision, 7)
    XCTAssertEqual(binding.previousHDCIdentitySHA256, previousDigest)
    XCTAssertEqual(binding.hdcIdentitySHA256, nextDigest)
    XCTAssertEqual(binding.hdcConnectKey, nextConnectKey)
    XCTAssertEqual(binding.usbTopology, expectation.usbTopology)
    XCTAssertEqual(binding.productModel, RockchipFlashProfile.dayu200.runtimeProductModel)
    XCTAssertEqual(binding.buildVersion, RockchipFlashProfile.dayu200.runtimeBuildVersion)
    XCTAssertEqual(binding.jobID, "job-host")
    let invocations = await log.snapshot()
    XCTAssertTrue(
      invocations.contains {
        $0.arguments.starts(with: ["-t", nextConnectKey, "shell", "param", "get"])
      })
    XCTAssertFalse(
      invocations.contains {
        $0.arguments.starts(with: ["-t", previousConnectKey])
      })
  }

  func testPostFlashHDCBindingRejectsInexactBuildAndInconsistentTopology() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let previousConnectKey = "device-1"
    let nextConnectKey = "device-2"
    let expectation = RockchipHDCReconnectExpectation(
      previousConnectKey: previousConnectKey,
      previousIdentitySHA256: SHA256.hash(data: Data(previousConnectKey.utf8))
        .map { String(format: "%02x", $0) }.joined(),
      usbTopology: "42")
    let component = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let action = RockchipProviderAction.verifyBoundBuild(
      expectation: expectation,
      expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
      expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion)
    let plan = try rockchipPlan(
      action: action, stepID: "rebind-and-verify-build", toolSHA256: component.sha256)

    let buildStore = RockchipPostFlashHDCBindingStore(
      rootURL: root.appending(path: "bad-build", directoryHint: .isDirectory))
    let badBuildExecutor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: ScriptedCommandRunner(
        log: CommandLog(
          buildVersion: "OpenHarmony-7.0.0.34", connectedTarget: nextConnectKey,
          emptyFirstTargetList: false)),
      usbProbe: TopologyBoundUSBProbe(connectKey: nextConnectKey, topology: "42"),
      postFlashHDCBindingStore: buildStore)
    // Spelled out rather than routed through XCTAssertThrowsErrorAsync so the
    // refusal has to name the mismatch: a nonempty version that simply differs
    // from the profile pin must fail closed, and say which readback disagreed.
    do {
      _ = try await badBuildExecutor.execute(
        action: action, descriptor: hostDescriptor(plan),
        rockchipExecutable: component, actionDirectory: root)
      XCTFail("a nonempty version that differs from the profile pin must fail closed")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("version mismatch must be a confirmed failure: \(failure)")
      }
      XCTAssertTrue(detail.contains("does not match"), detail)
    }
    XCTAssertNil(try buildStore.loadIfPresent())

    let topologyStore = RockchipPostFlashHDCBindingStore(
      rootURL: root.appending(path: "bad-topology", directoryHint: .isDirectory))
    let badTopologyExecutor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: ScriptedCommandRunner(
        log: CommandLog(
          connectedTarget: nextConnectKey, emptyFirstTargetList: false)),
      usbProbe: TopologyBoundUSBProbe(
        connectKey: nextConnectKey, topology: "42", reportedTopology: "43"),
      postFlashHDCBindingStore: topologyStore)
    await XCTAssertThrowsErrorAsync(
      try await badTopologyExecutor.execute(
        action: action, descriptor: hostDescriptor(plan),
        rockchipExecutable: component, actionDirectory: root))
    XCTAssertNil(try topologyStore.loadIfPresent())
  }

  func testPostFlashHDCBindingPublicationIsCrashRetryIdempotent() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RockchipPostFlashHDCBindingStore(rootURL: root)
    let previousConnectKey = "device-1"
    let nextConnectKey = "device-2"
    let previousDigest = SHA256.hash(data: Data(previousConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let nextDigest = SHA256.hash(data: Data(nextConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    func candidate(at establishedAtUTC: String) -> RockchipPostFlashHDCBinding {
      RockchipPostFlashHDCBinding(
        targetID: "TGT-HOST", bindingRevision: 7,
        stableLoaderIdentitySHA256: String(repeating: "a", count: 64),
        previousHDCIdentitySHA256: previousDigest,
        hdcIdentitySHA256: nextDigest, hdcConnectKey: nextConnectKey,
        usbTopology: "42",
        productModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        buildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion,
        jobID: "job-host", establishedAtUTC: establishedAtUTC)
    }

    let first = try store.publish(
      candidate(at: "2026-08-08T01:02:03Z"),
      expectedPreviousHDCIdentitySHA256: previousDigest)
    let retry = try store.publish(
      candidate(at: "2026-08-08T01:03:04Z"),
      expectedPreviousHDCIdentitySHA256: previousDigest)
    XCTAssertEqual(retry, first)
    XCTAssertEqual(retry.establishedAtUTC, "2026-08-08T01:02:03Z")
  }

  func testPostFlashHDCBindingRevisionAdvanceArchivesTheSupersededEpoch() throws {
    // A rebind opens a new alias epoch. The entry from the earlier revision is
    // superseded evidence — archived beside the store, never blocking — while
    // a stale lower-revision publication is still refused outright. Measured
    // 2026-08-18: a revision-3 relic of 2026-08-14 refused every revision-4
    // publication, failing the postflight after all nine partitions had
    // verifiably written.
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RockchipPostFlashHDCBindingStore(rootURL: root)
    func digest(_ key: String) -> String {
      SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func entry(
      revision: Int, loader: String, key: String, at establishedAtUTC: String
    ) -> RockchipPostFlashHDCBinding {
      RockchipPostFlashHDCBinding(
        targetID: "TGT-HOST", bindingRevision: revision,
        stableLoaderIdentitySHA256: String(repeating: loader, count: 64),
        previousHDCIdentitySHA256: digest(key),
        hdcIdentitySHA256: digest(key), hdcConnectKey: key,
        usbTopology: "42",
        productModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        buildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion,
        jobID: "job-host", establishedAtUTC: establishedAtUTC)
    }

    _ = try store.publish(
      entry(revision: 3, loader: "a", key: "old-key", at: "2026-08-14T08:09:51Z"),
      expectedPreviousHDCIdentitySHA256: digest("old-key"))

    // The revision advance publishes despite the relic, and the relic is
    // preserved as an archive, not deleted.
    let advanced = try store.publish(
      entry(revision: 4, loader: "b", key: "new-key", at: "2026-08-18T04:30:00Z"),
      expectedPreviousHDCIdentitySHA256: digest("new-key"))
    XCTAssertEqual(advanced.bindingRevision, 4)
    let archived = root.appending(path: "post-flash-superseded-20260814T080951Z.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    let archivedEntry = try JSONDecoder().decode(
      RockchipPostFlashHDCBinding.self, from: Data(contentsOf: archived))
    XCTAssertEqual(archivedEntry.bindingRevision, 3)
    XCTAssertEqual(archivedEntry.hdcConnectKey, "old-key")

    // A stale lower-revision job still cannot rotate the newer route.
    XCTAssertThrowsError(
      try store.publish(
        entry(revision: 3, loader: "a", key: "old-key", at: "2026-08-14T09:00:00Z"),
        expectedPreviousHDCIdentitySHA256: digest("old-key")))
  }

  func testGPTHeaderParseAcceptsOnlyARealHeader() throws {
    let primary = try XCTUnwrap(
      RockchipGPTHeader.parse(ScriptedCommandRunner.sectors(begin: 1, count: 1)))
    XCTAssertEqual(primary.myLBA, 1)
    XCTAssertEqual(primary.alternateLBA, 61_071_359)
    XCTAssertEqual(primary.firstUsableLBA, 34)
    XCTAssertEqual(primary.lastUsableLBA, 61_071_326)

    let backup = try XCTUnwrap(
      RockchipGPTHeader.parse(
        ScriptedCommandRunner.sectors(begin: 61_071_359, count: 1)))
    XCTAssertEqual(backup.myLBA, primary.alternateLBA)

    // A sector past the addressable medium came back as uniform 0xCC on
    // 2026-08-04 while the read itself reported success. That is the case the
    // pre-write probe exists for, so it must not parse as a header.
    XCTAssertNil(RockchipGPTHeader.parse(Data(repeating: 0xCC, count: 512)))
    XCTAssertNil(RockchipGPTHeader.parse(Data(repeating: 0, count: 512)))
    XCTAssertNil(RockchipGPTHeader.parse(Data(repeating: 0xFF, count: 512)))
    XCTAssertNil(RockchipGPTHeader.parse(Data("EFI PART".utf8)))
  }

  func testRejectedReceiptExcerptKeepsTheNewestOutputOnOneLine() throws {
    // A truncated capture ends mid-progress, so the useful part is the end.
    let progress = (1...400).map { "Write LBA \($0) 100%\n" }.joined()
    let excerpt = FoundationRockchipRuntimeActionExecutor.outputExcerpt(
      Data(progress.utf8))

    XCTAssertTrue(excerpt.hasSuffix("Write LBA 400 100%"), excerpt)
    XCTAssertFalse(excerpt.contains("Write LBA 1 100%"))
    XCTAssertFalse(excerpt.contains("\n"))
    XCTAssertFalse(excerpt.contains("\r"))
    XCTAssertLessThanOrEqual(excerpt.count, 201)
  }

  func testRejectedReceiptExcerptSurvivesShortAndBinaryOutput() throws {
    XCTAssertEqual(
      FoundationRockchipRuntimeActionExecutor.outputExcerpt(Data("Write LBA failed".utf8)),
      "Write LBA failed")
    XCTAssertEqual(FoundationRockchipRuntimeActionExecutor.outputExcerpt(Data()), "")

    let binary = Data([0xFF, 0xFE, 0x00]) + Data("tail".utf8)
    let excerpt = FoundationRockchipRuntimeActionExecutor.outputExcerpt(binary)
    XCTAssertTrue(excerpt.hasSuffix("tail"), excerpt)
    XCTAssertFalse(excerpt.contains("\n"))
  }

  func testRouterSelectsOnlyFromTypedAction() async throws {
    let log = DispatchLog()
    let router = RuntimeProcessDispatcherRouter(
      hdc: RecordingDispatcher(provider: "hdc", log: log, reason: nil),
      rockchip: RecordingDispatcher(
        provider: "rockchip", log: log, reason: "rockchip unavailable"))
    let hdcProvider = HDCObservationProviderAdapter(factsPort: HDCFacts())
    let context = ProviderExecutionContext(
      jobID: "job-router", stepID: "route", targetID: "TGT-ROUTER",
      bindingRevision: 1, connectKey: "device-1",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      toolSHA256: String(repeating: "b", count: 64),
      nowUTC: "2026-07-31T00:00:00Z")
    let hdcAction = TypedProviderAction.hdc(
      .queryProperty(HDCAllowlistedProperty.productModel))
    let hdcPlan = try hdcProvider.lower(action: hdcAction, context: context)
    _ = try await router.dispatch(hdcPlan)

    let rockchipProvider = RockchipFlashProviderAdapter(availability: .available)
    let rockchipPlan = try rockchipProvider.lower(
      action: .rockchip(.enterLoader(connectKey: "device-1")), context: context)
    _ = try await router.dispatch(rockchipPlan)

    let recordedProviders = await log.snapshot()
    XCTAssertEqual(recordedProviders, ["hdc", "rockchip"])
    XCTAssertNil(router.unavailableReason(providerID: "hdc"))
    XCTAssertEqual(
      router.unavailableReason(providerID: "rockchip"), "rockchip unavailable")
    XCTAssertNotNil(router.unavailableReason(providerID: "adb"))
  }

  func testBundledResolverAcceptsOnlyFixedSiblingAndExactIdentity() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let product = root.appending(path: "arkdeck-agentd")
    let component = root.appending(path: "rkdeveloptool")
    try Data("product".utf8).write(to: product)
    try Data("component".utf8).write(to: component)
    XCTAssertEqual(chmod(component.path, 0o700), 0)
    let componentSHA = SHA256.hash(data: Data("component".utf8))
      .map { String(format: "%02x", $0) }.joined()

    let resolver = BundledRockchipExecutableResolver(
      productExecutableURL: product, expectedSHA256: componentSHA)
    XCTAssertEqual(
      try resolver.resolveExecutable(providerID: "rockchip"),
      ResolvedExecutable(path: component.path, sha256: componentSHA))
    XCTAssertThrowsError(try resolver.resolveExecutable(providerID: "hdc"))

    let wrongIdentity = BundledRockchipExecutableResolver(
      productExecutableURL: product, expectedSHA256: String(repeating: "f", count: 64))
    XCTAssertThrowsError(try wrongIdentity.resolveExecutable(providerID: "rockchip")) { error in
      guard case BundledRockchipComponentError.identityMismatch = error else {
        return XCTFail("expected identityMismatch, got \(error)")
      }
    }

    try FileManager.default.removeItem(at: component)
    try FileManager.default.createSymbolicLink(
      at: component, withDestinationURL: product)
    let symlinkResolver = BundledRockchipExecutableResolver(
      productExecutableURL: product,
      expectedSHA256: SHA256.hash(data: Data("product".utf8))
        .map { String(format: "%02x", $0) }.joined())
    XCTAssertThrowsError(try symlinkResolver.resolveExecutable(providerID: "rockchip")) { error in
      XCTAssertEqual(error as? BundledRockchipComponentError, .nonCanonicalPath)
    }
  }

  func testBundledResolverFindsFixedInstalledProductWithoutCallerPath() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missingSibling = root.appending(path: "missing/rkdeveloptool")
    let installedComponent = root.appending(
      path:
        "Applications/ArkDeck.app/Contents/MacOS/rkdeveloptool")
    try FileManager.default.createDirectory(
      at: installedComponent.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let bytes = Data("reviewed-installed-component".utf8)
    try bytes.write(to: installedComponent)
    XCTAssertEqual(chmod(installedComponent.path, 0o700), 0)
    let sha256 = SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }.joined()

    let resolver = BundledRockchipExecutableResolver(
      componentURLs: [missingSibling, installedComponent],
      expectedSHA256: sha256)
    XCTAssertEqual(
      try resolver.resolveExecutable(providerID: "rockchip"),
      ResolvedExecutable(path: installedComponent.path, sha256: sha256))
  }

  func testBundledResolverRejectsUnsignedInstalledProduct() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let component = root.appending(path: "rkdeveloptool")
    try Data("unsigned-component".utf8).write(to: component)
    XCTAssertEqual(chmod(component.path, 0o700), 0)

    let resolver = BundledRockchipExecutableResolver(
      componentURLs: [component])
    XCTAssertThrowsError(
      try resolver.resolveExecutable(providerID: "rockchip")
    ) { error in
      guard case BundledRockchipComponentError.codeSignatureInvalid = error else {
        return XCTFail("expected codeSignatureInvalid, got \(error)")
      }
    }
  }

  func testBundledResolverRejectsSignedNonProductExecutable() throws {
    let resolver = BundledRockchipExecutableResolver(
      componentURLs: [URL(filePath: "/usr/bin/true")])
    XCTAssertThrowsError(
      try resolver.resolveExecutable(providerID: "rockchip")
    ) { error in
      guard case BundledRockchipComponentError.codeSignatureInvalid = error else {
        return XCTFail("expected product requirement rejection, got \(error)")
      }
    }
  }

  func testFactsUseAdoptedIdentityBindingAndProductComponent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let targetStore = try RuntimeTargetStore(
      directoryURL: root.appending(path: "targets", directoryHint: .isDirectory))
    let identity = String(repeating: "a", count: 64)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: identity, connectKey: "device-1",
      toolVersion: "3.2.0f", nowUTC: "2026-07-31T00:00:00Z"
    ).record
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let factsPort = TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore,
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      nowUTC: { "2026-07-31T01:02:03Z" })

    let facts = try await factsPort.currentFacts(targetID: adopted.targetID)
    XCTAssertEqual(facts.providerID, "rockchip")
    XCTAssertEqual(facts.targetID, adopted.targetID)
    XCTAssertEqual(facts.bindingRevision, adopted.bindingRevision)
    XCTAssertEqual(facts.deviceIdentitySHA256, identity)
    XCTAssertEqual(facts.executionConnectKey, "device-1")
    XCTAssertEqual(facts.toolSHA256, component.sha256)
    XCTAssertEqual(
      facts.serverFacts["componentPackage"], BundledRockchipComponent.packageID)
    XCTAssertEqual(
      facts.serverFacts["componentSigningIdentifier"],
      BundledRockchipComponent.signingIdentifier)
    XCTAssertEqual(
      facts.serverFacts["componentSigningTeam"],
      BundledRockchipComponent.signingTeamIdentifier)
    // Facts the adoption record cannot support are reported unknown, never
    // fabricated: the old "dayu200"/"hdc" literals were guesses flowing
    // into evidence as if measured. With no probe composed nothing measured
    // them, so this stays exactly where #992 left it.
    XCTAssertEqual(facts.profileID, "unknown")
    XCTAssertEqual(facts.deviceMode, "unknown")
    XCTAssertNil(facts.buildFingerprint)
  }

  func testProductionFactsAndPrerequisitesRequireExactCrossModeBinding() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let targetStore = try RuntimeTargetStore(
      directoryURL: root.appending(path: "targets", directoryHint: .isDirectory))
    let boundConnectKey = "device-bound"
    let boundIdentity = SHA256.hash(data: Data(boundConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let bound = try targetStore.adopt(
      stableIdentitySHA256: boundIdentity, connectKey: boundConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let unboundConnectKey = "device-unbound"
    let unboundIdentity = SHA256.hash(data: Data(unboundConnectKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let unbound = try targetStore.adopt(
      stableIdentitySHA256: unboundIdentity, connectKey: unboundConnectKey,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:01Z"
    ).record
    let bindingStore = RockchipProductBindingStore(
      rootURL: root.appending(path: "product-binding", directoryHint: .isDirectory))
    _ = try bindingStore.install(
      RockchipProductBindingSnapshot(
        revision: 1, serial: boundConnectKey, usbTopology: "42",
        evidence: [
          "product:e0-iokit-single-dayu200-readback",
          "usb:vendor=8711,profile=dayu200-cross-mode",
          "identity:serial-sha256=\(boundIdentity)",
        ]))
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let port = TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore,
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      prober: RecordingLiveModeProbe(
        observation: RockchipLiveModeObservation(
          deviceMode: "hdc", buildFingerprint: nil)),
      bindingStore: bindingStore,
      nowUTC: { "2026-08-08T00:01:00Z" })

    let boundFacts = try await port.currentFacts(targetID: bound.targetID)
    XCTAssertEqual(
      boundFacts.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey],
      TargetStoreRockchipRuntimeFactsPort.crossModeBindingSatisfied)
    let ready = try await port.observePrerequisites(targetID: bound.targetID)
    XCTAssertTrue(
      ready.filter { $0.identifier != .stablePower }
        .allSatisfy { $0.status == .satisfied })
    XCTAssertEqual(
      ready.first { $0.identifier == .stablePower }?.status, .unknown)

    let unboundFacts = try await port.currentFacts(targetID: unbound.targetID)
    XCTAssertEqual(
      unboundFacts.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey],
      TargetStoreRockchipRuntimeFactsPort.crossModeBindingUnprepared)
    let blocked = try await port.observePrerequisites(targetID: unbound.targetID)
    XCTAssertEqual(
      blocked.first { $0.identifier == .recoveryPath }?.status,
      .unsatisfied)
    XCTAssertEqual(
      blocked.first { $0.identifier == .loader }?.status,
      .unknown)
  }

  func testFactsRouteTheOriginalTargetThroughItsVerifiedPostFlashHDCAlias() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let targetStore = try RuntimeTargetStore(
      directoryURL: root.appending(path: "targets", directoryHint: .isDirectory))
    let previousHDC = "device-1"
    let loader = "loader-1"
    let nextHDC = "device-2"
    let previousDigest = SHA256.hash(data: Data(previousHDC.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let loaderDigest = SHA256.hash(data: Data(loader.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let nextDigest = SHA256.hash(data: Data(nextHDC.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: previousDigest, connectKey: previousHDC,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let target = try targetStore.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: adopted.stablePhysicalIdentitySHA256,
        previousRevision: adopted.bindingRevision,
        currentStableIdentitySHA256: loaderDigest,
        currentRevision: adopted.bindingRevision + 1)
    ).record
    let bindingRoot = root.appending(path: "binding", directoryHint: .isDirectory)
    let bindingStore = RockchipProductBindingStore(rootURL: bindingRoot)
    let binding = try bindingStore.install(
      RockchipProductBindingSnapshot(
        revision: target.bindingRevision, serial: loader, usbTopology: "43",
        evidence: [
          "product:e0-iokit-single-loader-readback",
          "identity:serial-sha256=\(loaderDigest)",
          "identity:previous-serial-sha256=\(previousDigest)",
          "binding:previous-revision=\(adopted.bindingRevision)",
          "binding:previous-usb-topology=42",
          "identity:hdc-normal-alias-sha256=\(previousDigest)",
          "binding:hdc-normal-alias-usb-topology=42",
          "rebind:user-selection-sha256=\(String(repeating: "c", count: 64))",
        ])
    ).snapshot
    XCTAssertTrue(try binding.coversRuntimeTarget(target))
    let postFlashStore = RockchipPostFlashHDCBindingStore(rootURL: bindingRoot)
    _ = try postFlashStore.publish(
      RockchipPostFlashHDCBinding(
        targetID: target.targetID, bindingRevision: target.bindingRevision,
        stableLoaderIdentitySHA256: loaderDigest,
        previousHDCIdentitySHA256: previousDigest,
        hdcIdentitySHA256: nextDigest, hdcConnectKey: nextHDC,
        usbTopology: "42",
        productModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        buildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion,
        jobID: "job-flash", establishedAtUTC: "2026-08-08T00:10:00Z"),
      expectedPreviousHDCIdentitySHA256: previousDigest)
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let probe = RecordingLiveModeProbe(
      observation: RockchipLiveModeObservation(
        deviceMode: "hdc", buildFingerprint: RockchipFlashProfile.dayu200.runtimeBuildVersion))
    let port = TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore,
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      prober: probe,
      bindingStore: bindingStore,
      postFlashHDCBindingStore: postFlashStore,
      nowUTC: { "2026-08-08T00:11:00Z" })

    let facts = try await port.currentFacts(targetID: target.targetID)
    XCTAssertEqual(facts.executionConnectKey, nextHDC)
    XCTAssertEqual(
      facts.serverFacts[TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey],
      nextDigest)
    XCTAssertEqual(
      facts.serverFacts[TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey],
      "42")
    let observedConnectKeys = await probe.observedConnectKeys()
    let observedStableIdentities = await probe.observedStableIdentities()
    XCTAssertEqual(observedConnectKeys, [nextHDC])
    XCTAssertEqual(observedStableIdentities, [loaderDigest])

    let duplicate = try targetStore.adopt(
      stableIdentitySHA256: nextDigest, connectKey: nextHDC,
      toolVersion: "3.2.0f", nowUTC: "2026-08-08T00:12:00Z"
    ).record
    XCTAssertNotEqual(duplicate.targetID, target.targetID)
    do {
      _ = try await port.currentFacts(targetID: target.targetID)
      XCTFail("a post-flash alias owned by another target must fail closed")
    } catch let error as DeviceProviderError {
      guard case .factsUnavailable(let reason) = error else {
        return XCTFail("unexpected provider failure: \(error)")
      }
      XCTAssertEqual(
        reason,
        "verified post-flash HDC alias is owned by another adopted target")
    }
    let connectKeysAfterConflict = await probe.observedConnectKeys()
    XCTAssertEqual(
      connectKeysAfterConflict, [nextHDC],
      "the conflicting alias must be rejected before another device probe")

    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: duplicate.targetID,
        aliasStableIdentitySHA256: duplicate.stablePhysicalIdentitySHA256,
        aliasBindingRevision: duplicate.bindingRevision,
        canonicalTargetID: target.targetID,
        canonicalStableIdentitySHA256: target.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: target.bindingRevision,
        routedHDCIdentitySHA256: nextDigest, routedUSBTopology: "42",
        establishingFlashJobID: "job-flash",
        establishingFlashPlanDigestSHA256: String(repeating: "f", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [], establishedAtUTC: "2026-08-08T00:10:00Z"))
    let resolvedFacts = try await port.currentFacts(targetID: target.targetID)
    XCTAssertEqual(resolvedFacts.executionConnectKey, nextHDC)
    let connectKeysAfterResolution = await probe.observedConnectKeys()
    XCTAssertEqual(connectKeysAfterResolution, [nextHDC, nextHDC])

    _ = try postFlashStore.publish(
      RockchipPostFlashHDCBinding(
        targetID: target.targetID, bindingRevision: target.bindingRevision,
        stableLoaderIdentitySHA256: loaderDigest,
        previousHDCIdentitySHA256: nextDigest,
        hdcIdentitySHA256: nextDigest, hdcConnectKey: nextHDC,
        usbTopology: "42",
        productModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        buildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion,
        jobID: "job-later-flash", establishedAtUTC: "2026-08-08T00:20:00Z"),
      expectedPreviousHDCIdentitySHA256: nextDigest)
    let laterFlashFacts = try await port.currentFacts(targetID: target.targetID)
    XCTAssertEqual(laterFlashFacts.executionConnectKey, nextHDC)
    XCTAssertEqual(
      laterFlashFacts.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey],
      nextDigest)
    let connectKeysAfterLaterFlash = await probe.observedConnectKeys()
    XCTAssertEqual(connectKeysAfterLaterFlash, [nextHDC, nextHDC, nextHDC])
  }

  func testFactsReportProbedModeBuildAndExactPublishedProfile() async throws {
    let published = try XCTUnwrap(
      RockchipFlashProfile.profile(reference: "dayu200"))
    XCTAssertEqual(
      published.firmwareVersion, "OpenHarmony-7.0.0.35-20260728_180253")

    let hdcOnPublishedBuild = try await probedFacts(
      RecordingLiveModeProbe(
        observation: RockchipLiveModeObservation(
          deviceMode: "hdc", buildFingerprint: published.firmwareVersion)))
    XCTAssertEqual(hdcOnPublishedBuild.facts.deviceMode, "hdc")
    XCTAssertEqual(
      hdcOnPublishedBuild.facts.buildFingerprint, published.firmwareVersion)
    XCTAssertEqual(hdcOnPublishedBuild.facts.profileID, "dayu200")
    // The probe is addressed by the adopted record's connect key, never by a
    // request field.
    let probedKeys = await hdcOnPublishedBuild.probe.observedConnectKeys()
    XCTAssertEqual(probedKeys, ["device-1"])
    let probedIdentities = await hdcOnPublishedBuild.probe.observedStableIdentities()
    XCTAssertEqual(probedIdentities, [String(repeating: "a", count: 64)])

    // An unpublished build names no profile. Reporting the nearest published
    // one would be the same guess #992 removed.
    let hdcOnUnknownBuild = try await probedFacts(
      RecordingLiveModeProbe(
        observation: RockchipLiveModeObservation(
          deviceMode: "hdc",
          buildFingerprint: "OpenHarmony-9.9.9.99-20991231_000000")))
    XCTAssertEqual(hdcOnUnknownBuild.facts.deviceMode, "hdc")
    XCTAssertEqual(
      hdcOnUnknownBuild.facts.buildFingerprint,
      "OpenHarmony-9.9.9.99-20991231_000000")
    XCTAssertEqual(hdcOnUnknownBuild.facts.profileID, "unknown")

    // The RockUSB modes expose no build surface, so they name no profile
    // either — but the mode itself is real and is reported.
    for mode in ["loader", "maskrom"] {
      let rockUSB = try await probedFacts(
        RecordingLiveModeProbe(
          observation: RockchipLiveModeObservation(
            deviceMode: mode, buildFingerprint: nil)))
      XCTAssertEqual(rockUSB.facts.deviceMode, mode)
      XCTAssertNil(rockUSB.facts.buildFingerprint)
      XCTAssertEqual(rockUSB.facts.profileID, "unknown")
    }
  }

  func testFactsEncodeAnUnobservableTargetAsAbsentInsteadOfThrowing()
    async throws
  {
    // A device that is not attached must not break the portrait: planOnly and
    // draft both run with no device on the host. "Cannot see it" is a fact,
    // not an error; the fail-closed gate is the engine's fresh readback at
    // the consume point.
    let probed = try await probedFacts(
      RecordingLiveModeProbe(
        failure: .notObservable("no RockUSB device and no HDC target")))
    XCTAssertEqual(probed.facts.deviceMode, "absent")
    XCTAssertNil(probed.facts.buildFingerprint)
    XCTAssertEqual(probed.facts.profileID, "unknown")
    // The adopted identity half of the portrait is unaffected.
    XCTAssertEqual(probed.facts.executionConnectKey, "device-1")
    XCTAssertEqual(
      probed.facts.deviceIdentitySHA256, String(repeating: "a", count: 64))
  }

  func testLiveProbeReadsModeAndBuildFromReadOnlyCommandsOnly() async throws {
    let hdc = ResolvedExecutable(
      path: "/product/hdc", sha256: String(repeating: "d", count: 64))
    let rockchip = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let resolver = FixedExecutableResolver(
      table: ["hdc": hdc, "rockchip": rockchip])

    // Connected over HDC: the mode is named by the target list and the build
    // by the same allowlisted param the post-flash verifier pins.
    let connected = ProbeCommandRunner(responses: [
      .success("device-1\t\tUSB\tConnected\tlocalhost\n"),
      .success("const.ohos.fullname = OpenHarmony-7.0.0.35-20260728_180253\n"),
    ])
    let hdcObservation = try await FoundationRockchipLiveModeProbe(
      hdcResolver: resolver, rockchipResolver: resolver, runner: connected,
      usbProbe: MissingUSBProbe()
    ).observe(
      connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    XCTAssertEqual(hdcObservation.deviceMode, "hdc")
    XCTAssertEqual(
      hdcObservation.buildFingerprint, "OpenHarmony-7.0.0.35-20260728_180253")
    let hdcCommands = await connected.invocations()
    XCTAssertEqual(
      hdcCommands.map(\.arguments),
      [
        ["list", "targets", "-v"],
        ["-t", "device-1", "shell", "param", "get", "const.ohos.fullname"],
      ])
    XCTAssertEqual(hdcCommands.map(\.executable.path), [hdc.path, hdc.path])
    XCTAssertTrue(hdcCommands.allSatisfy { !$0.criticalNonInterruptible })

    // The mode was observed even though the build readback failed: a known
    // mode with an unknown build, not a fabricated build.
    let buildUnreadable = ProbeCommandRunner(responses: [
      .success("device-1\t\tUSB\tConnected\tlocalhost\n"),
      .exit(1),
    ])
    let partial = try await FoundationRockchipLiveModeProbe(
      hdcResolver: resolver, rockchipResolver: resolver, runner: buildUnreadable,
      usbProbe: MissingUSBProbe()
    ).observe(
      connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    XCTAssertEqual(partial.deviceMode, "hdc")
    XCTAssertNil(partial.buildFingerprint)

    // Not on HDC: the RockUSB surface names loader vs maskrom, and neither
    // carries a build.
    for (reported, expected) in [("Loader", "loader"), ("Maskrom", "maskrom")] {
      let runner = ProbeCommandRunner(responses: [
        .success("[Empty]\n"),
        .success("DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=17\t\(reported)\n"),
      ])
      let observation = try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: runner,
        usbProbe: FixedUSBProbe(identity: String(repeating: "a", count: 64))
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
      XCTAssertEqual(observation.deviceMode, expected)
      XCTAssertNil(observation.buildFingerprint)
      let commands = await runner.invocations()
      XCTAssertEqual(
        commands.map(\.arguments), [["list", "targets", "-v"], ["ld"]])
      XCTAssertEqual(commands.last?.executable.path, rockchip.path)
    }
  }

  func testLiveProbeRefusesToAttributeAnAmbiguousOrMissingObservation()
    async throws
  {
    let resolver = FixedExecutableResolver(
      table: [
        "hdc": ResolvedExecutable(
          path: "/product/hdc", sha256: String(repeating: "d", count: 64)),
        "rockchip": ResolvedExecutable(
          path: "/product/Contents/MacOS/rkdeveloptool",
          sha256: Self.reviewedSignedComponentSHA256),
      ])

    // A single `ld` observation is not enough to assign a Loader to this
    // target. The IOKit identity must match the durable target identity before
    // the tool's mode can become a prerequisite fact.
    let mismatchedIdentity = ProbeCommandRunner(responses: [
      .success("[Empty]\n")
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver,
        runner: mismatchedIdentity,
        usbProbe: FixedUSBProbe(identity: String(repeating: "b", count: 64))
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    }
    let mismatchedCommands = await mismatchedIdentity.invocations()
    XCTAssertEqual(
      mismatchedCommands.map(\.arguments), [["list", "targets", "-v"]])

    // `ld` carries no serial, so a mode read while two RockUSB devices are
    // attached belongs to nobody in particular.
    let ambiguous = ProbeCommandRunner(responses: [
      .success("[Empty]\n"),
      .success(
        "DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=17\tLoader\n"
          + "DevNo=2\tVid=0x2207,Pid=0x350a,LocationID=18\tLoader\n"),
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: ambiguous,
        usbProbe: FixedUSBProbe(identity: String(repeating: "a", count: 64))
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    }

    // Nothing on either surface.
    let nothing = ProbeCommandRunner(responses: [
      .success("[Empty]\n"), .exit(1),
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: nothing,
        usbProbe: MissingUSBProbe()
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    }

    // A target list this parser does not recognize is never downgraded to
    // "the device is not there".
    let malformed = ProbeCommandRunner(responses: [
      .success("device-1\tUSB\tConnected\n")
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: malformed,
        usbProbe: MissingUSBProbe()
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    }

    // No probe executable, no observation — never a PATH search.
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: FixedExecutableResolver(table: [:]),
        rockchipResolver: resolver,
        runner: ProbeCommandRunner(responses: []),
        usbProbe: MissingUSBProbe()
      ).observe(
        connectKey: "device-1", stableIdentitySHA256: String(repeating: "a", count: 64))
    }
  }

  private func assertNotObservable(
    _ body: () async throws -> RockchipLiveModeObservation,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let observation = try await body()
      XCTFail(
        "expected an unobservable target, got \(observation)", file: file,
        line: line)
    } catch is RockchipLiveModeProbeFailure {
      return
    } catch {
      XCTFail(
        "expected RockchipLiveModeProbeFailure, got \(error)", file: file,
        line: line)
    }
  }

  private func probedFacts(
    _ probe: RecordingLiveModeProbe
  ) async throws -> (facts: ProviderFacts, probe: RecordingLiveModeProbe) {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let targetStore = try RuntimeTargetStore(
      directoryURL: root.appending(path: "targets", directoryHint: .isDirectory))
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "device-1", toolVersion: "3.2.0f",
      nowUTC: "2026-08-03T00:00:00Z"
    ).record
    let facts = try await TargetStoreRockchipRuntimeFactsPort(
      targetStore: targetStore,
      resolver: FixedExecutableResolver(
        table: [
          "rockchip": ResolvedExecutable(
            path: "/product/Contents/MacOS/rkdeveloptool",
            sha256: Self.reviewedSignedComponentSHA256)
        ]),
      prober: probe,
      nowUTC: { "2026-08-03T01:02:03Z" }
    ).currentFacts(targetID: adopted.targetID)
    return (facts, probe)
  }

  private actor RecordingLiveModeProbe: RockchipLiveModeProbing {
    private let observation: RockchipLiveModeObservation?
    private let failure: RockchipLiveModeProbeFailure?
    private var observedTargets: [(connectKey: String, stableIdentitySHA256: String)] = []

    init(observation: RockchipLiveModeObservation) {
      self.observation = observation
      failure = nil
    }

    init(failure: RockchipLiveModeProbeFailure) {
      observation = nil
      self.failure = failure
    }

    func observedConnectKeys() -> [String] { observedTargets.map(\.connectKey) }
    func observedStableIdentities() -> [String] {
      observedTargets.map(\.stableIdentitySHA256)
    }

    func observe(
      connectKey: String,
      stableIdentitySHA256: String
    ) async throws -> RockchipLiveModeObservation {
      observedTargets.append((connectKey, stableIdentitySHA256))
      guard let observation else { throw failure! }
      return observation
    }
  }

  private struct ProbeCommand: Sendable {
    let executable: ResolvedExecutable
    let arguments: [String]
    let timeoutSeconds: Int?
    let criticalNonInterruptible: Bool
  }

  private enum ProbeResponse: Sendable {
    case success(String)
    case exit(Int32)
    case exitWithStandardError(Int32, String)
    case outcomeUnknown(String)
  }

  private actor ProbeCommandRunner: RockchipRuntimeCommandRunning {
    private var responses: [ProbeResponse]
    private var recorded: [ProbeCommand] = []

    init(responses: [ProbeResponse]) {
      self.responses = responses
    }

    func invocations() -> [ProbeCommand] { recorded }

    func run(
      executable: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible: Bool
    ) async throws -> ProviderSubprocessReceipt {
      recorded.append(
        ProbeCommand(
          executable: executable, arguments: arguments,
          timeoutSeconds: timeoutSeconds,
          criticalNonInterruptible: criticalNonInterruptible))
      guard !responses.isEmpty else {
        throw RuntimeDispatchFailure.failed("no scripted response remains")
      }
      switch responses.removeFirst() {
      case .success(let stdout):
        return ProviderSubprocessReceipt(
          exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0)
      case .exit(let status):
        return ProviderSubprocessReceipt(
          exitStatus: status, stdout: Data(), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0)
      case .exitWithStandardError(let status, let stderr):
        return ProviderSubprocessReceipt(
          exitStatus: status, stdout: Data(), stderr: Data(stderr.utf8),
          stdoutTruncated: false, durationSeconds: 0)
      case .outcomeUnknown(let detail):
        throw RuntimeDispatchFailure.outcomeUnknown(detail)
      }
    }
  }

  // MARK: Loader transition diagnostics (TASK-AIN-019)

  func testEnterLoaderConfirmedNotExecutedCarriesTheHDCReceiptSummary() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let connectKey = "device-1"
    let runner = ProbeCommandRunner(responses: [
      .exitWithStandardError(1, "[Fail]Not match target and connect key\nretry later")
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: NormalOnlyUSBProbe(connectKey: connectKey),
      enterLoaderReadbackTimeoutSeconds: 0)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: connectKey),
      stepID: "enter-loader-receipt-summary", toolSHA256: rockchip.sha256)

    do {
      _ = try await executor.execute(
        action: .enterLoader(connectKey: connectKey),
        descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
        actionDirectory: root)
      XCTFail("a Loader transition without its postcondition must fail")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecutedWithDiagnostic(let detail, _) = failure else {
        return XCTFail("expected confirmed-not-executed failure, got \(failure)")
      }
      // The one line that used to be missing: what the command actually did.
      XCTAssertTrue(detail.contains("hdcExitStatus=1"), detail)
      XCTAssertTrue(detail.contains("Not match target and connect key"), detail)
      // Bounded and single-line, so it survives a journal and a ledger detail.
      XCTAssertFalse(detail.contains("\n"), detail)
    }
  }

  func testEnterLoaderFailureNamesTheTerminatingSignalAndItsCrashReport() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let connectKey = "device-1"
    let runner = ProbeCommandRunner(responses: [
      .outcomeUnknown(RockchipHostProcessDiagnostics.signalDeath(6))
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: NormalOnlyUSBProbe(connectKey: connectKey),
      enterLoaderReadbackTimeoutSeconds: 0)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: connectKey),
      stepID: "enter-loader-signal", toolSHA256: rockchip.sha256)

    do {
      _ = try await executor.execute(
        action: .enterLoader(connectKey: connectKey),
        descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
        actionDirectory: root)
      XCTFail("a Loader transition without its postcondition must fail")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecutedWithDiagnostic(let detail, _) = failure else {
        return XCTFail("expected confirmed-not-executed failure, got \(failure)")
      }
      XCTAssertTrue(detail.contains("died on signal 6"), detail)
      XCTAssertTrue(detail.contains("DiagnosticReports"), detail)
    }
  }

  func testEnterLoaderUnknownFallbackCarriesTheHDCExitStatus() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let connectKey = "device-1"
    // Clean exit, no Loader, and no HDC-normal readback either: the outcome is
    // genuinely unknown, and now it says what the command reported.
    let runner = ProbeCommandRunner(responses: [.exit(0)])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: MissingUSBProbe(),
      enterLoaderReadbackTimeoutSeconds: 0)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: connectKey),
      stepID: "enter-loader-unknown-summary", toolSHA256: rockchip.sha256)

    do {
      _ = try await executor.execute(
        action: .enterLoader(connectKey: connectKey),
        descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
        actionDirectory: root)
      XCTFail("an unobserved Loader postcondition must stay unknown")
    } catch let failure as RuntimeDispatchFailure {
      guard case .outcomeUnknown(let detail) = failure else {
        return XCTFail("expected an unknown outcome, got \(failure)")
      }
      XCTAssertTrue(detail.contains("hdcExitStatus=0"), detail)
    }
  }

  func testSignalDeathNamesTheSignalAndPointsAtItsCrashReport() {
    let message = RockchipHostProcessDiagnostics.signalDeath(9)
    XCTAssertTrue(message.contains("process died on signal 9"), message)
    XCTAssertTrue(
      message.contains(RockchipHostProcessDiagnostics.diagnosticReportsDirectory), message)
    // The preflight reads its own canonical text back rather than opening a
    // second spawn face, so the round trip is part of the contract.
    XCTAssertEqual(
      RockchipHostProcessDiagnostics.signalNumber(inFailureDescription: message), 9)
    XCTAssertNil(
      RockchipHostProcessDiagnostics.signalNumber(
        inFailureDescription: "process timed out before completion"))
  }

  func testEvidenceSummaryTruncatesStandardErrorAndKeepsItSingleLine() {
    let summary = FoundationRockchipRuntimeActionExecutor.transitionEvidenceSummary(
      receipt: ProviderSubprocessReceipt(
        exitStatus: 2, stdout: Data(),
        stderr: Data(String(repeating: "e", count: 4_000).utf8),
        stdoutTruncated: true, durationSeconds: 0),
      failure: nil)
    XCTAssertTrue(summary.contains("hdcExitStatus=2"), summary)
    XCTAssertTrue(summary.contains("hdcOutputTruncated=true"), summary)
    XCTAssertTrue(summary.contains("…"), summary)
    XCTAssertLessThan(summary.utf8.count, 400)
    XCTAssertFalse(summary.contains("\n"), summary)
  }

  func testEnterLoaderSettlesTimedOutHDCWithExactLoaderReadback() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = String(repeating: "a", count: 64)
    let runner = ProbeCommandRunner(responses: [
      .outcomeUnknown("process timed out before completion"),
      .success("DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader\n"),
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner,
      usbProbe: LoaderAfterInitialProbe(identity: identity))
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: "device-1"),
      stepID: "enter-loader-readback", toolSHA256: rockchip.sha256)

    let result = try await executor.execute(
      action: .enterLoader(connectKey: "device-1"),
      descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
      actionDirectory: root)

    XCTAssertEqual(result.summary["transition"], "normal-to-loader")
    XCTAssertEqual(
      result.summary["transitionEvidence"], "exact-bound-loader-readback")
    XCTAssertEqual(result.subprocesses.count, 1)
    let invocations = await runner.invocations()
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        ["-t", "device-1", "target", "boot", "loader"], ["ld"],
      ])
  }

  func testEnterLoaderUsesOnlyBrokerRecordedCampaignTiming() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = String(repeating: "a", count: 64)
    let tuning = try AgentAuthorityCampaignExecutionTuning(
      loaderDiscoveryTimeoutSeconds: 90,
      loaderPollIntervalMilliseconds: 250,
      hdcCommandTimeoutSeconds: 7,
      readOnlyCommandTimeoutSeconds: 9)
    let runner = ProbeCommandRunner(responses: [
      .success(""),
      .success("DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader\n"),
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner,
      usbProbe: LoaderAfterInitialProbe(identity: identity))
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: "device-1"),
      stepID: "enter-loader-tuned", toolSHA256: rockchip.sha256)
    let descriptor = hostDescriptor(plan, executionTuning: tuning)
    XCTAssertEqual(descriptor.executionTuning, tuning)

    _ = try await executor.execute(
      action: .enterLoader(connectKey: "device-1"), descriptor: descriptor,
      rockchipExecutable: rockchip, actionDirectory: root)

    let invocations = await runner.invocations()
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        ["-t", "device-1", "target", "boot", "loader"], ["ld"],
      ])
    XCTAssertEqual(invocations.map(\.timeoutSeconds), [7, 9])
  }

  func testEnterLoaderAlreadyInExactLoaderSkipsHDCAndRecordsReadback() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = String(repeating: "a", count: 64)
    let runner = ProbeCommandRunner(responses: [
      .success("DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader\n")
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner,
      usbProbe: FixedUSBProbe(identity: identity))
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: "device-1"),
      stepID: "enter-loader-already-loader", toolSHA256: rockchip.sha256)

    let result = try await executor.execute(
      action: .enterLoader(connectKey: "device-1"),
      descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
      actionDirectory: root)

    XCTAssertEqual(result.summary["transition"], "already-loader")
    XCTAssertEqual(
      result.summary["transitionEvidence"], "exact-bound-loader-readback")
    XCTAssertEqual(result.summary["loaderIdentitySha256"], identity)
    XCTAssertEqual(result.summary["usbTopology"], "42")
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.map(\.arguments), [["ld"]])
    XCTAssertEqual(result.subprocesses.count, 1)
  }

  func testEnterLoaderKeepsTimedOutHDCUnknownWithoutExactLoader() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ProbeCommandRunner(responses: [
      .outcomeUnknown("process timed out before completion")
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: MissingUSBProbe(),
      enterLoaderReadbackTimeoutSeconds: 0)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: "device-1"),
      stepID: "enter-loader-unresolved", toolSHA256: rockchip.sha256)

    do {
      _ = try await executor.execute(
        action: .enterLoader(connectKey: "device-1"),
        descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
        actionDirectory: root)
      XCTFail("missing Loader readback must remain unknown")
    } catch let failure as RuntimeDispatchFailure {
      guard case .outcomeUnknown(let detail) = failure else {
        return XCTFail("expected outcomeUnknown, got \(failure)")
      }
      XCTAssertEqual(detail, "process timed out before completion")
    }
  }

  func testEnterLoaderSettlesTimedOutHDCAsConfirmedNotExecutedWhenExactNormalUSBRemains()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let connectKey = "device-1"
    let runner = ProbeCommandRunner(responses: [
      .outcomeUnknown("process timed out before completion")
    ])
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: NormalOnlyUSBProbe(connectKey: connectKey),
      enterLoaderReadbackTimeoutSeconds: 0)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let plan = try rockchipPlan(
      action: .enterLoader(connectKey: connectKey),
      stepID: "enter-loader-normal-readback", toolSHA256: rockchip.sha256)

    do {
      _ = try await executor.execute(
        action: .enterLoader(connectKey: connectKey),
        descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
        actionDirectory: root)
      XCTFail("exact normal USB readback must settle the transition as not completed")
    } catch let failure as RuntimeDispatchFailure {
      guard case .confirmedNotExecutedWithDiagnostic(let detail, let diagnostic) = failure else {
        return XCTFail("expected confirmed-not-executed failure, got \(failure)")
      }
      XCTAssertTrue(detail.contains("did not complete"), detail)
      XCTAssertEqual(diagnostic, .enterLoaderHDCNoCleanReceipt)
    }
    let invocations = await runner.invocations()
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        ["-t", connectKey, "target", "boot", "loader"]
      ])
  }

  func testNormalUSBReadbackUsesExactConnectKeyIdentityWithoutHDCProcess()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let connectKey = "device-1"
    let runner = ProbeCommandRunner(responses: [])
    let probe = NormalOnlyUSBProbe(connectKey: connectKey)
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(
            path: "/product/hdc", sha256: String(repeating: "b", count: 64))
        ]),
      runner: runner, usbProbe: probe)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: String(repeating: "c", count: 64))
    let action = RockchipProviderAction.observeHDCNormalUSB(connectKey: connectKey)
    let plan = try rockchipPlan(
      action: action, stepID: "observe-normal-usb", toolSHA256: rockchip.sha256)

    let result = try await executor.execute(
      action: action, descriptor: hostDescriptor(plan), rockchipExecutable: rockchip,
      actionDirectory: root)

    XCTAssertEqual(result.summary["hdcNormalIdentitySha256"], probe.identity)
    XCTAssertEqual(result.summary["usbState"], "hdc-normal")
    XCTAssertEqual(result.summary["usbTopology"], "42")
    XCTAssertEqual(result.subprocesses, [])
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.count, 0)
  }

  func testProductionRockchipRouteUsesReviewedSignedIdentityAndRejectsLegacyPlan()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let actionLog = ActionLog()
    let resolver = FixedExecutableResolver(
      table: [
        "rockchip": ResolvedExecutable(
          path: "/product/Contents/MacOS/rkdeveloptool",
          sha256: Self.reviewedSignedComponentSHA256)
      ])
    let dispatcher = BundledRockchipRuntimeDispatcher(
      resolver: resolver,
      host: DurableRockchipRuntimeActionHost(
        executor: SuccessfulActionExecutor(log: actionLog),
        records: RockchipRuntimeActionRecordStore(
          rootURL: root.appending(
            path:
              "rockchip-runtime", directoryHint: .isDirectory))))
    XCTAssertNil(dispatcher.unavailableReason(providerID: "rockchip"))

    let signedPlan = try RockchipFlashProviderAdapter(availability: .available).lower(
      action: .rockchip(.enterLoader(connectKey: "device-1")),
      context: ProviderExecutionContext(
        jobID: "job-signed", stepID: "enter-loader", targetID: "TGT-1",
        bindingRevision: 1, connectKey: "device-1",
        expectedIdentitySHA256: String(repeating: "a", count: 64),
        toolSHA256: Self.reviewedSignedComponentSHA256,
        nowUTC: "2026-07-31T00:00:00Z"))
    let receipt = try await dispatcher.dispatch(signedPlan)
    XCTAssertNotNil(receipt.hostManagedRecordID)
    XCTAssertEqual(receipt.hostManagedSummary["semantic"], "verified")
    let signedSnapshot = await actionLog.snapshot()
    XCTAssertEqual(signedSnapshot.0.count, 1)

    let legacyPlan = try RockchipFlashProviderAdapter(availability: .available).lower(
      action: .rockchip(.enterLoader(connectKey: "device-1")),
      context: ProviderExecutionContext(
        jobID: "job-legacy", stepID: "enter-loader", targetID: "TGT-1",
        bindingRevision: 1, connectKey: "device-1",
        expectedIdentitySHA256: String(repeating: "a", count: 64),
        toolSHA256:
          RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
        nowUTC: "2026-07-31T00:00:00Z"))
    do {
      _ = try await dispatcher.dispatch(legacyPlan)
      XCTFail("a legacy external-tool plan must not authorize the bundled component")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("expected definite pre-dispatch failure, got \(failure)")
      }
      XCTAssertTrue(
        detail.contains("identity changed after availability materialization"),
        detail)
    }
    let legacySnapshot = await actionLog.snapshot()
    XCTAssertEqual(legacySnapshot.0.count, 1)
  }

  func testSucceededFlashProjectsPostflightFromCorrelatedDurableReceipt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let recordRoot = root.appending(path: "rockchip-runtime", directoryHint: .isDirectory)
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let expectation = RockchipHDCReconnectExpectation(
      previousConnectKey: "device-1",
      previousIdentitySHA256: SHA256.hash(data: Data("device-1".utf8))
        .map { String(format: "%02x", $0) }.joined(),
      usbTopology: "42")
    let action = RockchipProviderAction.verifyBoundBuild(
      expectation: expectation,
      expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
      expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion)
    let plan = try rockchipPlan(
      action: action,
      stepID: "rebind-and-verify-build",
      toolSHA256: component.sha256)
    let dispatcher = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: PostflightActionExecutor(),
        records: RockchipRuntimeActionRecordStore(rootURL: recordRoot)))

    let receipt = try await dispatcher.dispatch(plan)
    XCTAssertEqual(
      receipt.hostManagedSummary["firmware"],
      RockchipFlashProfile.dayu200.runtimeBuildVersion)

    let request = try RuntimeOperationRequest(
      requestID: "req-postflight-observation",
      idempotencyKey: "idem-postflight-observation",
      target: DurableTargetReference(
        targetID: "TGT-HOST", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: [
        "imageBundleLease": .string(
          "lease-v1:input-flash:ART-0123456789abcdef0123456789abcdef"),
        "deviceProfile": .string("dayu200"),
        "partitionPlan": .array(
          RockchipFlashProfile.dayu200.mappedPartitions.map {
            .string($0.partitionName)
          }),
        "postFlashVerification": .string("full"),
      ],
      authorization: RuntimeCapabilityReference(
        capabilityID: "CAP-RT-POSTFLIGHT-OBSERVATION"))
    var record = RuntimeJobRecord(
      jobID: "job-host",
      request: request,
      operationReference: "flash.dayu200",
      catalogDigest: String(repeating: "f", count: 64),
      providerID: "rockchip",
      createdAtUTC: "2026-08-10T01:21:29Z",
      actualEffect: "destructive",
      admissionEvidence: nil,
      materializedPlanDigest: String(repeating: "b", count: 64),
      materializedStableTargetIdentitySHA256: String(repeating: "a", count: 64),
      materializedBindingRevision: 7)
    record.state = "succeeded"
    record.finishedAtUTC = "2026-08-10T01:27:29Z"

    let store = RockchipRuntimeActionRecordStore(rootURL: recordRoot)
    let observation = try XCTUnwrap(store.flashPostflightObservation(for: record))
    XCTAssertEqual(observation.targetID, "TGT-HOST")
    XCTAssertEqual(observation.bindingRevision, 7)
    XCTAssertEqual(
      observation.firmware,
      RockchipFlashProfile.dayu200.runtimeBuildVersion)
    XCTAssertEqual(observation.model, RockchipFlashProfile.dayu200.runtimeProductModel)
    XCTAssertEqual(observation.transport, "usb")
    XCTAssertEqual(observation.confirmationMethod, "machinePostflightReadback")

    record.state = "failed"
    XCTAssertNil(
      store.flashPostflightObservation(for: record),
      "a durable receipt must not upgrade a non-successful Job")
  }

  func testReviewedProductComponentMakesFlashAvailableWithoutWeakeningE2()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let component = ResolvedExecutable(
      path: "/Applications/ArkDeck.app/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let dispatcher = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: SuccessfulActionExecutor(log: ActionLog()),
        records: RockchipRuntimeActionRecordStore(
          rootURL: root.appending(
            path:
              "rockchip-runtime", directoryHint: .isDirectory))))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(
        providers: [
          RockchipFlashProviderAdapter(availability: .available)
        ]),
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(
          path:
            "capabilities", directoryHint: .isDirectory)),
      artifactStore: try RuntimeArtifactStore(
        rootURL: root.appending(
          path:
            "artifacts", directoryHint: .isDirectory),
        nowUTC: { "2026-07-31T00:00:00Z" }),
      nowUTC: { "2026-07-31T00:00:00Z" })

    let availability = await engine.operationAvailability()
    let flash = try XCTUnwrap(
      availability.first {
        $0.reference == "flash.dayu200"
      })
    XCTAssertEqual(flash.state, .available)
    XCTAssertEqual(flash.reasons, [])

    let capability = try RuntimeCapability(
      capabilityID: "CAP-RT-GJ4-EXACT-PLAN",
      targetScope: .stablePhysicalIdentity(
        sha256: String(repeating: "a", count: 64)),
      operationScope: [
        RuntimeCapabilityOperationScope(
          operationID: "flash.dayu200")
      ],
      effectCeiling: .destructive,
      issuedAtUTC: "2026-07-31T00:00:00Z",
      expiresAtUTC: "2026-08-01T00:00:00Z",
      maximumUses: 1,
      issuer: RuntimeCapabilityIssuer(
        kind: .maintainerMergedPR,
        reference: "merged-pr:exact-gj4-plan"),
      exactPlanDigest: String(repeating: "b", count: 64),
      exactBindingRevision: 7)
    XCTAssertEqual(capability.effectCeiling, .destructive)
    XCTAssertEqual(capability.maximumUses, 1)
    XCTAssertEqual(
      capability.exactPlanDigest, String(repeating: "b", count: 64))
  }

  func testDurableHostIsUnavailableBeforeAdmissionWhenRecordRootCannotMaterialize()
    throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let occupiedRoot = root.appending(path: "occupied")
    try Data("not-a-directory".utf8).write(to: occupiedRoot)
    let host = DurableRockchipRuntimeActionHost(
      executor: SuccessfulActionExecutor(log: ActionLog()),
      records: RockchipRuntimeActionRecordStore(rootURL: occupiedRoot))

    let reason = try XCTUnwrap(host.unavailableReason())
    XCTAssertTrue(reason.contains("record root is unavailable"), reason)
  }

  private func rockchipPlan(
    action: RockchipProviderAction,
    stepID: String,
    toolSHA256: String
  ) throws -> TypedProcessPlan {
    try RockchipFlashProviderAdapter(availability: .available).lower(
      action: .rockchip(action),
      context: ProviderExecutionContext(
        jobID: "job-host",
        stepID: stepID,
        targetID: "TGT-HOST",
        bindingRevision: 7,
        connectKey: "device-1",
        expectedIdentitySHA256: String(repeating: "a", count: 64),
        toolVersion: BundledRockchipComponent.reportedVersion,
        toolSHA256: toolSHA256,
        nowUTC: "2026-07-31T00:00:00Z"))
  }

  // MARK: - Engine-lane spawn working directory

  /// The engine lane is the path a real flash job takes, and its runner used
  /// to spawn with no working directory at all — so rkdeveloptool, which
  /// falls back to cwd-relative `config.ini`/`log/` on macOS, wrote into
  /// whatever directory the daemon was started from (observed as a stray
  /// `Packages/ArkDeckKit/log/`). This spawns a real child and reads back the
  /// directory it actually ran in.
  func testEngineLaneRunnerSpawnsChildrenInProductOwnedToolRuntimeState() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let toolWorkingDirectory = try RockchipProductToolRuntimeDirectory.prepare(root: root)
    let callerDirectory = FileManager.default.currentDirectoryPath
    XCTAssertNotEqual(
      toolWorkingDirectory.path, callerDirectory,
      "the leg is vacuous unless product-owned state differs from the caller's cwd")

    let receipt = try await FoundationRockchipRuntimeCommandRunner(
      workingDirectory: toolWorkingDirectory
    ).run(
      executable: try Self.hashedExecutable(path: "/bin/pwd"),
      arguments: ["-P"],
      timeoutSeconds: 15,
      outputByteBudget: 64 * 1024,
      criticalNonInterruptible: false)

    XCTAssertEqual(receipt.exitStatus, 0)
    // `pwd -P` and Foundation may spell `/private/tmp` differently across OS
    // and toolchain versions. The contract is directory identity, not text.
    let childDirectory = URL(
      filePath: try XCTUnwrap(String(data: receipt.stdout, encoding: .utf8))
        .trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertSameFileSystemItem(
      childDirectory,
      toolWorkingDirectory,
      "every child of this runner must run inside product-owned tool state")
    XCTAssertEqual(
      FileManager.default.currentDirectoryPath, callerDirectory,
      "binding the child must never move the parent's own current directory")
  }

  /// `ProcessExecutor` revalidates the directory at every launch, so the
  /// directory can disappear between composition and dispatch. That is a
  /// definite zero-dispatch refusal, never an unknown outcome: an
  /// `outcomeUnknown` here would park a flashable device as unresolved.
  func testEngineLaneRunnerTreatsALostToolRuntimeDirectoryAsZeroDispatch() async throws {
    let missing = try temporaryDirectory()
      .appending(path: "RockchipToolRuntime", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: missing.deletingLastPathComponent()) }

    do {
      _ = try await FoundationRockchipRuntimeCommandRunner(workingDirectory: missing).run(
        executable: try Self.hashedExecutable(path: "/bin/pwd"),
        arguments: ["-P"],
        timeoutSeconds: 15,
        outputByteBudget: 64 * 1024,
        criticalNonInterruptible: false)
      XCTFail("a working directory the Process port rejects must not dispatch")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let reason) = failure else {
        return XCTFail("expected a definite refusal, got \(failure)")
      }
      XCTAssertTrue(
        reason.hasPrefix("dispatch refused: "), "unexpected refusal text: \(reason)")
      XCTAssertTrue(
        reason.contains(missing.path), "the refusal must name the directory: \(reason)")
    }
  }

  /// A tool runtime directory that cannot be prepared leaves the daemon
  /// composing the refusing host. The refusal has to name the actual cause,
  /// or `operation.list` reports a generic blocker for a fixable one.
  func testRockchipDispatcherRefusalNamesTheToolRuntimeCause() throws {
    let resolver = try FixedExecutableResolver.hashing(
      path: "/bin/pwd", providerID: "rockchip")
    let detail = "Rockchip tool runtime directory cannot be created"

    let named = BundledRockchipRuntimeDispatcher(
      resolver: resolver, unavailableDetail: detail)
    let generic = BundledRockchipRuntimeDispatcher(resolver: resolver)

    let reason = try XCTUnwrap(named.unavailableReason(providerID: "rockchip"))
    XCTAssertTrue(reason.hasSuffix(": \(detail)"), "unexpected refusal text: \(reason)")
    XCTAssertEqual(
      reason, "\(try XCTUnwrap(generic.unavailableReason(providerID: "rockchip"))): \(detail)",
      "the detail must extend the existing refusal, not replace it")
  }

  private static func hashedExecutable(path: String) throws -> ResolvedExecutable {
    let digest = SHA256.hash(data: try Data(contentsOf: URL(filePath: path)))
    return ResolvedExecutable(
      path: path, sha256: digest.map { String(format: "%02x", $0) }.joined())
  }

  private func hostDescriptor(
    _ plan: TypedProcessPlan,
    executionTuning: AgentAuthorityCampaignExecutionTuning? = nil
  ) -> HostManagedProcessDescriptor {
    guard case .hostManaged(let descriptor) = plan.kind else {
      preconditionFailure("expected host-managed plan")
    }
    guard let executionTuning else { return descriptor }
    return HostManagedProcessDescriptor(
      identifier: descriptor.identifier,
      jobID: descriptor.jobID,
      stepID: descriptor.stepID,
      targetID: descriptor.targetID,
      bindingRevision: descriptor.bindingRevision,
      connectKey: descriptor.connectKey,
      expectedIdentitySHA256: descriptor.expectedIdentitySHA256,
      providerExecutableSHA256: descriptor.providerExecutableSHA256,
      actionSHA256: descriptor.actionSHA256,
      executionTuning: executionTuning)
  }

  private func flashBundle() -> RockchipRuntimeFlashBundle {
    RockchipRuntimeFlashBundle(
      artifactLeaseID: "lease:flash-artifact",
      artifactID: "flash-artifact",
      fileURL: URL(filePath: "/private/tmp/images.tar.gz"),
      sha256: RockchipFlashProfile.dayu200.archiveSHA256,
      byteCount: Int(RockchipFlashProfile.dayu200.archiveSizeBytes),
      partitionNames: RockchipFlashProfile.dayu200.mappedPartitions.map(
        \.partitionName))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(
        path:
          "arkdeck-rockchip-runtime-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  // Helpers for the HDC-side waits this change keeps. They were declared
  // between two tests that covered the removed lowering; kept here so the
  // waits they serve stay tested.
  private actor PollCounter {
    private(set) var polls = 0
    func next() -> Int {
      polls += 1
      return polls
    }
  }

  private struct TransientMalformedListRunner: RockchipRuntimeCommandRunning {
    let counter: PollCounter

    func run(
      executable _: ResolvedExecutable,
      arguments: [String],
      timeoutSeconds _: Int?,
      outputByteBudget _: Int,
      criticalNonInterruptible _: Bool
    ) async throws -> ProviderSubprocessReceipt {
      guard arguments == ["list", "targets", "-v"] else {
        throw RuntimeDispatchFailure.failed("unexpected argv \(arguments)")
      }
      let stdout =
        await counter.next() == 1
        ? "device-1\tUSB\tConnected\n"
        : "device-1\t\tUSB\tConnected\tlocalhost\n"
      return ProviderSubprocessReceipt(
        exitStatus: 0, stdout: Data(stdout.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0)
    }
  }

}
