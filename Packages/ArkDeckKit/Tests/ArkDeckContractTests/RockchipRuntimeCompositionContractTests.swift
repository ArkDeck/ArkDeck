import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
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
          atPath: actionDirectory.appendingPathComponent("intent.json").path))
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
          atPath: actionDirectory.appendingPathComponent("intent.json").path))
      throw RuntimeDispatchFailure.outcomeUnknown(
        "fixture interrupted after durable host intent")
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

    init(
      productModel: String = RockchipFlashProfile.dayu200.runtimeProductModel,
      buildVersion: String = RockchipFlashProfile.dayu200.runtimeBuildVersion
    ) {
      self.productModel = productModel
      self.buildVersion = buildVersion
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
          listCount == 1
          ? "[Empty]\n"
          : "device-1\t\tUSB\tConnected\tlocalhost\n"
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
      case let value where value.first == "wlx":
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
      await log.run(
        executable: executable,
        arguments: arguments,
        criticalNonInterruptible: criticalNonInterruptible)
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

  private struct VerifiedPartitionReadback:
    RockchipRuntimePartitionReadbackVerifying
  {
    let log: ReadbackLog

    func verify(
      mapping: RockchipMappedPartition,
      member _: RockchipImagesArchiveMember,
      executable _: ResolvedExecutable,
      outputDirectory _: URL
    ) async throws -> [ProviderSubprocessReceipt] {
      await log.append(mapping.partitionName)
      return [
        ProviderSubprocessReceipt(
          exitStatus: 0,
          stdout: Data("Read LBA from device (100%)\n".utf8),
          stderr: Data(),
          stdoutTruncated: false,
          durationSeconds: 0)
      ]
    }
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
      try materialized.write(to: URL(fileURLWithPath: arguments[3]))
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
    let product = root.appendingPathComponent("arkdeck-agentd")
    let component = root.appendingPathComponent("rkdeveloptool")
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
    let missingSibling = root.appendingPathComponent("missing/rkdeveloptool")
    let installedComponent = root.appendingPathComponent(
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
    let component = root.appendingPathComponent("rkdeveloptool")
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
      componentURLs: [URL(fileURLWithPath: "/usr/bin/true")])
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
      directoryURL: root.appendingPathComponent("targets", isDirectory: true))
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
    // fabricated: the old "dayu200@1"/"hdc" literals were guesses flowing
    // into evidence as if measured. With no probe composed nothing measured
    // them, so this stays exactly where #992 left it.
    XCTAssertEqual(facts.profileID, "unknown")
    XCTAssertEqual(facts.deviceMode, "unknown")
    XCTAssertNil(facts.buildFingerprint)
  }

  func testFactsReportProbedModeBuildAndExactPublishedProfile() async throws {
    let published = try XCTUnwrap(
      RockchipFlashProfile.profile(reference: "dayu200@2"))
    XCTAssertEqual(
      published.firmwareVersion, "OpenHarmony-7.0.0.35-20260728_180253")

    let hdcOnPublishedBuild = try await probedFacts(
      RecordingLiveModeProbe(
        observation: RockchipLiveModeObservation(
          deviceMode: "hdc", buildFingerprint: published.firmwareVersion)))
    XCTAssertEqual(hdcOnPublishedBuild.facts.deviceMode, "hdc")
    XCTAssertEqual(
      hdcOnPublishedBuild.facts.buildFingerprint, published.firmwareVersion)
    XCTAssertEqual(hdcOnPublishedBuild.facts.profileID, "dayu200@2")
    // The probe is addressed by the adopted record's connect key, never by a
    // request field.
    let probedKeys = await hdcOnPublishedBuild.probe.observedConnectKeys()
    XCTAssertEqual(probedKeys, ["device-1"])

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
      hdcResolver: resolver, rockchipResolver: resolver, runner: connected
    ).observe(connectKey: "device-1")
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
      hdcResolver: resolver, rockchipResolver: resolver, runner: buildUnreadable
    ).observe(connectKey: "device-1")
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
        hdcResolver: resolver, rockchipResolver: resolver, runner: runner
      ).observe(connectKey: "device-1")
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
        hdcResolver: resolver, rockchipResolver: resolver, runner: ambiguous
      ).observe(connectKey: "device-1")
    }

    // Nothing on either surface.
    let nothing = ProbeCommandRunner(responses: [
      .success("[Empty]\n"), .exit(1),
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: nothing
      ).observe(connectKey: "device-1")
    }

    // A target list this parser does not recognize is never downgraded to
    // "the device is not there".
    let malformed = ProbeCommandRunner(responses: [
      .success("device-1\tUSB\tConnected\n")
    ])
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: resolver, rockchipResolver: resolver, runner: malformed
      ).observe(connectKey: "device-1")
    }

    // No probe executable, no observation — never a PATH search.
    await assertNotObservable {
      try await FoundationRockchipLiveModeProbe(
        hdcResolver: FixedExecutableResolver(table: [:]),
        rockchipResolver: resolver,
        runner: ProbeCommandRunner(responses: [])
      ).observe(connectKey: "device-1")
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
      directoryURL: root.appendingPathComponent("targets", isDirectory: true))
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
    private var connectKeys: [String] = []

    init(observation: RockchipLiveModeObservation) {
      self.observation = observation
      failure = nil
    }

    init(failure: RockchipLiveModeProbeFailure) {
      observation = nil
      self.failure = failure
    }

    func observedConnectKeys() -> [String] { connectKeys }

    func observe(
      connectKey: String
    ) async throws -> RockchipLiveModeObservation {
      connectKeys.append(connectKey)
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
      case .outcomeUnknown(let detail):
        throw RuntimeDispatchFailure.outcomeUnknown(detail)
      }
    }
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
      usbProbe: FixedUSBProbe(identity: identity))
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
    XCTAssertEqual(invocations.map(\.arguments), [
      ["-t", "device-1", "target", "boot", "-bootloader"], ["ld"],
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
      usbProbe: FixedUSBProbe(identity: identity))
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
    XCTAssertEqual(invocations.map(\.arguments), [
      ["-t", "device-1", "target", "boot", "-bootloader"], ["ld"],
    ])
    XCTAssertEqual(invocations.map(\.timeoutSeconds), [7, 9])
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
    XCTAssertEqual(invocations.map(\.arguments), [
      ["-t", connectKey, "target", "boot", "-bootloader"]
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
          rootURL: root.appendingPathComponent(
            "rockchip-runtime", isDirectory: true))))
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
          rootURL: root.appendingPathComponent(
            "rockchip-runtime", isDirectory: true))))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appendingPathComponent("engine", isDirectory: true)),
      providers: DeviceProviderRegistry(
        providers: [
          RockchipFlashProviderAdapter(availability: .available)
        ]),
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appendingPathComponent(
          "capabilities", isDirectory: true)),
      artifactStore: try RuntimeArtifactStore(
        rootURL: root.appendingPathComponent(
          "artifacts", isDirectory: true),
        nowUTC: { "2026-07-31T00:00:00Z" }),
      nowUTC: { "2026-07-31T00:00:00Z" })

    let availability = await engine.operationAvailability()
    let flash = try XCTUnwrap(
      availability.first {
        $0.reference == "flash.dayu200@1"
      })
    XCTAssertEqual(flash.state, .available)
    XCTAssertEqual(flash.reasons, [])

    let capability = try RuntimeCapability(
      capabilityID: "CAP-RT-GJ4-EXACT-PLAN",
      targetScope: .stablePhysicalIdentity(
        sha256: String(repeating: "a", count: 64)),
      operationScope: [
        RuntimeCapabilityOperationScope(
          operationID: "flash.dayu200", version: 1)
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

  func testDurableHostCoversClosedActionSurfaceAndReplaysDurableReceipt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let componentSHA = Self.reviewedSignedComponentSHA256
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: componentSHA)
    let log = ActionLog()
    let dispatcher = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: SuccessfulActionExecutor(log: log),
        records: RockchipRuntimeActionRecordStore(
          rootURL: root.appendingPathComponent(
            "rockchip-runtime", isDirectory: true))))
    let identity = String(repeating: "a", count: 64)
    let bundle = flashBundle()
    let actions: [RockchipProviderAction] = [
      .enterLoader(connectKey: "device-1"),
      .observeHDCNormalUSB(connectKey: "device-1"),
      .waitForHDCDisconnect(connectKey: "device-1"),
      .waitForLoader(stableIdentitySHA256: identity),
      .rebindLoader(stableIdentitySHA256: identity),
      .flashPartitions(bundle),
      .verifyFlashReadback(bundle),
      .rebootToNormal(stableIdentitySHA256: identity),
      .waitForHDCReconnect(connectKey: "device-1"),
      .verifyBuild(
        connectKey: "device-1",
        expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion),
      .capturePostFlashDiagnostics(
        connectKey: "device-1",
        request: try HDCHilogCaptureRequest(
          durationSeconds: 1, byteBudget: 1024)),
    ]

    var firstPlan: TypedProcessPlan?
    for (index, action) in actions.enumerated() {
      let stepID = "step-\(index)"
      let plan = try rockchipPlan(
        action: action, stepID: stepID, toolSHA256: componentSHA)
      if firstPlan == nil { firstPlan = plan }
      let receipt = try await dispatcher.dispatch(plan)
      XCTAssertEqual(
        receipt.hostManagedRecordID,
        "rockchip-runtime/job-host/\(stepID)/receipt.json")
      let directory =
        root
        .appendingPathComponent("rockchip-runtime/job-host/\(stepID)")
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("intent.json").path))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("receipt.json").path))
      let intent =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf: directory.appendingPathComponent("intent.json")))
        as? [String: Any]
      XCTAssertEqual(intent?["jobID"] as? String, "job-host")
      XCTAssertEqual(intent?["stepID"] as? String, stepID)
      XCTAssertEqual(intent?["bindingRevision"] as? Int, 7)
      XCTAssertEqual(intent?["actionSHA256"] as? String, hostDescriptor(plan).actionSHA256)
    }
    let snapshot = await log.snapshot()
    XCTAssertEqual(snapshot.0, actions)
    XCTAssertEqual(snapshot.1, Array(repeating: true, count: actions.count))

    let replayed = try await dispatcher.dispatch(try XCTUnwrap(firstPlan))
    XCTAssertEqual(
      replayed.hostManagedRecordID,
      "rockchip-runtime/job-host/step-0/receipt.json")
    XCTAssertEqual(replayed.stdout, Data())
    XCTAssertEqual(replayed.subprocesses, [])
    let snapshotAfterDuplicate = await log.snapshot()
    XCTAssertEqual(snapshotAfterDuplicate.0.count, actions.count)

    let original = hostDescriptor(try XCTUnwrap(firstPlan))
    let driftedDescriptor = HostManagedProcessDescriptor(
      identifier: original.identifier,
      jobID: original.jobID,
      stepID: "action-digest-drift",
      targetID: original.targetID,
      bindingRevision: original.bindingRevision,
      connectKey: original.connectKey,
      expectedIdentitySHA256: original.expectedIdentitySHA256,
      providerExecutableSHA256: original.providerExecutableSHA256,
      actionSHA256: String(repeating: "0", count: 64))
    let driftedPlan = TypedProcessPlan(
      action: try XCTUnwrap(firstPlan).action,
      kind: .hostManaged(driftedDescriptor))
    do {
      _ = try await dispatcher.dispatch(driftedPlan)
      XCTFail("an action digest changed after admission must dispatch zero processes")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("action drift refusal must be definite, got \(failure)")
      }
      XCTAssertTrue(detail.contains("action digest drifted"), detail)
    }
    let snapshotAfterDrift = await log.snapshot()
    XCTAssertEqual(snapshotAfterDrift.0.count, actions.count)
  }

  func testDurableHostNeverResendsInterruptedMutationWithoutReceipt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let interruptedLog = ActionLog()
    let recordRoot = root.appendingPathComponent(
      "rockchip-runtime", isDirectory: true)
    let interrupted = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: InterruptedActionExecutor(log: interruptedLog),
        records: RockchipRuntimeActionRecordStore(rootURL: recordRoot)))
    let plan = try rockchipPlan(
      action: .flashPartitions(flashBundle()),
      stepID: "interrupted-flash",
      toolSHA256: component.sha256)

    for dispatcher in [
      interrupted,
      BundledRockchipRuntimeDispatcher(
        resolver: FixedExecutableResolver(table: ["rockchip": component]),
        host: DurableRockchipRuntimeActionHost(
          executor: SuccessfulActionExecutor(log: ActionLog()),
          records: RockchipRuntimeActionRecordStore(rootURL: recordRoot))),
    ] {
      do {
        _ = try await dispatcher.dispatch(plan)
        XCTFail("a mutation intent without a receipt must never be resent")
      } catch let failure as RuntimeDispatchFailure {
        guard case .outcomeUnknown(let detail) = failure else {
          return XCTFail("expected outcomeUnknown, got \(failure)")
        }
        XCTAssertTrue(detail.contains("intent"), detail)
      }
    }
    let snapshot = await interruptedLog.snapshot()
    XCTAssertEqual(snapshot.0, [.flashPartitions(flashBundle())])
    XCTAssertEqual(snapshot.1, [true])
  }

  func testDurableHostResumesInterruptedReadbackAndThenReplaysReceipt() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let component = ResolvedExecutable(
      path: "/product/Contents/MacOS/rkdeveloptool",
      sha256: Self.reviewedSignedComponentSHA256)
    let recordRoot = root.appendingPathComponent(
      "rockchip-runtime", isDirectory: true)
    let readback = RockchipProviderAction.verifyFlashReadback(flashBundle())
    let plan = try rockchipPlan(
      action: readback,
      stepID: "interrupted-readback",
      toolSHA256: component.sha256)
    let interrupted = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: InterruptedActionExecutor(log: ActionLog()),
        records: RockchipRuntimeActionRecordStore(rootURL: recordRoot)))
    do {
      _ = try await interrupted.dispatch(plan)
      XCTFail("fixture must stop after its durable readback intent")
    } catch let failure as RuntimeDispatchFailure {
      guard case .outcomeUnknown = failure else {
        return XCTFail("expected fixture interruption, got \(failure)")
      }
    }

    let resumedLog = ActionLog()
    let resumed = BundledRockchipRuntimeDispatcher(
      resolver: FixedExecutableResolver(table: ["rockchip": component]),
      host: DurableRockchipRuntimeActionHost(
        executor: SuccessfulActionExecutor(log: resumedLog),
        records: RockchipRuntimeActionRecordStore(rootURL: recordRoot)))
    let completed = try await resumed.dispatch(plan)
    let replayed = try await resumed.dispatch(plan)
    XCTAssertEqual(completed.hostManagedRecordID, replayed.hostManagedRecordID)
    let snapshot = await resumedLog.snapshot()
    XCTAssertEqual(snapshot.0, [readback])
    XCTAssertEqual(snapshot.1, [true])
  }

  func testRockchipMutationsMaterializeDedicatedReadOnlyReconciliation() throws {
    let provider = RockchipFlashProviderAdapter(availability: .available)
    let bundle = flashBundle()
    let context = ProviderExecutionContext(
      jobID: "job-reconcile",
      stepID: "reconcile-flash-partitions-attempt",
      targetID: "TGT-HOST",
      bindingRevision: 7,
      connectKey: "device-1",
      expectedIdentitySHA256: String(repeating: "a", count: 64),
      toolVersion: BundledRockchipComponent.reportedVersion,
      toolSHA256: Self.reviewedSignedComponentSHA256,
      nowUTC: "2026-07-31T00:00:00Z")
    let cases: [(TypedProviderAction, TypedProviderAction)] = [
      (
        .rockchip(.enterLoader(connectKey: "device-1")),
        .rockchip(.observeHDCNormalUSB(connectKey: "device-1"))
      ),
      (
        .rockchip(.flashPartitions(bundle)),
        .rockchip(.verifyFlashReadback(bundle))
      ),
      (
        .rockchip(.rebootToNormal(
          stableIdentitySHA256: String(repeating: "a", count: 64))),
        .rockchip(.waitForHDCReconnect(connectKey: "device-1"))
      ),
    ]

    for (index, pair) in cases.enumerated() {
      let reference = ProviderDurableIntentReference(
        jobID: context.jobID,
        stepID: "original-\(index)",
        intentEventID: "intent-\(index)",
        action: pair.0)
      let plan = try XCTUnwrap(
        provider.reconciliationReadback(
          intent: reference, context: context))
      XCTAssertEqual(plan.action, pair.1)
      XCTAssertLessThanOrEqual(plan.action.effect, .readOnly)
      let outcome = try provider.verifyReconciliationReadback(
        receipt: ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data(),
          stderr: Data(),
          stdoutTruncated: false,
          durationSeconds: 0,
          hostManagedRecordID:
            "rockchip-runtime/job-reconcile/\(context.stepID)/receipt.json"),
        intent: reference,
        context: context)
      if index == 0 {
        guard case .confirmedNotExecuted = outcome else {
          return XCTFail(
            "exact HDC-normal readback must settle enter-loader as not completed, got \(outcome)")
        }
      } else if case .confirmedCompleted = outcome {
        // The flash/readback and reboot/normal pairs prove their positive
        // postconditions rather than the negative enter-loader postcondition.
      } else {
        return XCTFail("dedicated readback must confirm completion, got \(outcome)")
      }
    }
  }

  func testDurableHostIsUnavailableBeforeAdmissionWhenRecordRootCannotMaterialize()
    throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let occupiedRoot = root.appendingPathComponent("occupied")
    try Data("not-a-directory".utf8).write(to: occupiedRoot)
    let host = DurableRockchipRuntimeActionHost(
      executor: SuccessfulActionExecutor(log: ActionLog()),
      records: RockchipRuntimeActionRecordStore(rootURL: occupiedRoot))

    let reason = try XCTUnwrap(host.unavailableReason())
    XCTAssertTrue(reason.contains("record root is unavailable"), reason)
  }

  func testProductionExecutorUsesDescriptorBoundHDCAndClosedRockUSBCommands() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let actionDirectory = root.appendingPathComponent(
      "action", isDirectory: true)
    try FileManager.default.createDirectory(
      at: actionDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let identity = String(repeating: "a", count: 64)
    let rockchipSHA = String(repeating: "c", count: 64)
    let hdcSHA = String(repeating: "b", count: 64)
    let rockchip = ResolvedExecutable(
      path: "/product/rkdeveloptool", sha256: rockchipSHA)
    let commandLog = CommandLog()
    let readbackLog = ReadbackLog()
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: [
          "hdc": ResolvedExecutable(path: "/product/hdc", sha256: hdcSHA)
        ]),
      runner: ScriptedCommandRunner(log: commandLog),
      usbProbe: FixedUSBProbe(
        identity: identity,
        normalIdentity: SHA256.hash(data: Data("device-1".utf8))
          .map { String(format: "%02x", $0) }.joined()),
      readback: VerifiedPartitionReadback(log: readbackLog),
      stage: { _, _ in
        Dictionary(
          uniqueKeysWithValues:
            RockchipFlashProfile.dayu200.mappedPartitions.map { mapping in
              let member = RockchipFlashProfile.dayu200.member(
                named: mapping.imageMemberName)!
              return (
                mapping.imageMemberName,
                RockchipRuntimeStagedImageHandle(
                  memberName: member.name,
                  partitionName: mapping.partitionName,
                  sizeBytes: member.sizeBytes,
                  sha256: member.sha256,
                  stableDescriptorPath: "/private/tmp/\(member.name)",
                  validation: {})
              )
            })
      })
    XCTAssertNil(executor.unavailableReason())

    let bundle = flashBundle()
    let actions: [RockchipProviderAction] = [
      .enterLoader(connectKey: "device-1"),
      .observeHDCNormalUSB(connectKey: "device-1"),
      .waitForHDCDisconnect(connectKey: "device-1"),
      .waitForLoader(stableIdentitySHA256: identity),
      .rebindLoader(stableIdentitySHA256: identity),
      .flashPartitions(bundle),
      .verifyFlashReadback(bundle),
      .rebootToNormal(stableIdentitySHA256: identity),
      .waitForHDCReconnect(connectKey: "device-1"),
      .verifyBuild(
        connectKey: "device-1",
        expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion),
      .capturePostFlashDiagnostics(
        connectKey: "device-1",
        request: try HDCHilogCaptureRequest(
          durationSeconds: 1, byteBudget: 1024)),
    ]
    for (index, action) in actions.enumerated() {
      let plan = try rockchipPlan(
        action: action,
        stepID: "production-\(index)",
        toolSHA256: rockchipSHA)
      _ = try await executor.execute(
        action: action,
        descriptor: hostDescriptor(plan),
        rockchipExecutable: rockchip,
        actionDirectory: actionDirectory)
    }

    let invocations = await commandLog.snapshot()
    let hdcDeviceInvocations = invocations.filter {
      $0.executable == "/product/hdc" && $0.arguments.first != "list"
    }
    XCTAssertFalse(hdcDeviceInvocations.isEmpty)
    XCTAssertTrue(
      hdcDeviceInvocations.allSatisfy {
        $0.arguments.starts(with: ["-t", "device-1"])
      })
    XCTAssertTrue(invocations.contains { $0.arguments == ["ld"] })
    XCTAssertTrue(invocations.contains { $0.arguments == ["ppt"] })
    XCTAssertTrue(invocations.contains { $0.arguments == ["rd"] })
    let writes = invocations.filter { $0.arguments.first == "wlx" }
    XCTAssertEqual(
      writes.map { $0.arguments[1] },
      RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName))
    XCTAssertTrue(writes.allSatisfy(\.criticalNonInterruptible))
    let readbackPartitions = await readbackLog.snapshot()
    XCTAssertEqual(
      readbackPartitions,
      RockchipFlashProfile.dayu200.mappedPartitions.map(\.partitionName))
    let firstMapping = try XCTUnwrap(
      RockchipFlashProfile.dayu200.mappedPartitions.first)
    let firstMember = try XCTUnwrap(
      RockchipFlashProfile.dayu200.member(named: firstMapping.imageMemberName))
    XCTAssertEqual(
      FoundationRockchipRuntimePartitionReadback.arguments(
        mapping: firstMapping,
        member: firstMember,
        outputURL: URL(fileURLWithPath: "/private/tmp/readback.img")),
      [
        "rl", String(firstMapping.offsetSectors),
        String((firstMember.sizeBytes + 511) / 512),
        "/private/tmp/readback.img",
      ])
  }

  func testPartitionReadbackHashesExactImagePrefixAndRemovesRawCopy() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = Data(repeating: 0x41, count: 700)
    let member = RockchipImagesArchiveMember(
      name: "exact.img",
      sizeBytes: Int64(image.count),
      sha256: SHA256.hash(data: image).map {
        String(format: "%02x", $0)
      }.joined(),
      classification: .mappedPartitionImage)
    let mapping = RockchipMappedPartition(
      writeOrder: 1,
      partitionName: "exact",
      imageMemberName: member.name,
      offsetSectors: 8192)
    let verifier = FoundationRockchipRuntimePartitionReadback(
      runner: MaterializingReadbackRunner(
        imageBytes: image, baseSector: mapping.offsetSectors),
      maximumChunkSectors: 1)
    let receipts = try await verifier.verify(
      mapping: mapping,
      member: member,
      executable: ResolvedExecutable(
        path: "/product/rkdeveloptool",
        sha256: String(repeating: "c", count: 64)),
      outputDirectory: root)
    XCTAssertEqual(receipts.count, 2)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testPostFlashBuildVerificationRejectsNonemptyButInexactProfileVersion() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let hdcSHA = String(repeating: "d", count: 64)
    let rockchipSHA = String(repeating: "c", count: 64)
    let log = CommandLog(buildVersion: "OpenHarmony-7.0.0.34")
    let executor = FoundationRockchipRuntimeActionExecutor(
      hdcResolver: FixedExecutableResolver(
        table: ["hdc": ResolvedExecutable(path: "/product/hdc", sha256: hdcSHA)]),
      runner: ScriptedCommandRunner(log: log),
      usbProbe: FixedUSBProbe(identity: String(repeating: "a", count: 64)))
    let action = RockchipProviderAction.verifyBuild(
      connectKey: "device-1",
      expectedProductModel: RockchipFlashProfile.dayu200.runtimeProductModel,
      expectedBuildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion)
    let plan = try rockchipPlan(
      action: action, stepID: "verify-exact-build", toolSHA256: rockchipSHA)
    do {
      _ = try await executor.execute(
        action: action, descriptor: hostDescriptor(plan),
        rockchipExecutable: ResolvedExecutable(
          path: "/product/rkdeveloptool", sha256: rockchipSHA),
        actionDirectory: root)
      XCTFail("a nonempty version that differs from the profile pin must fail closed")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("version mismatch must be a confirmed failure: \(failure)")
      }
      XCTAssertTrue(detail.contains("does not match"))
    }
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
      fileURL: URL(fileURLWithPath: "/private/tmp/images.tar.gz"),
      sha256: RockchipFlashProfile.dayu200.archiveSHA256,
      byteCount: Int(RockchipFlashProfile.dayu200.archiveSizeBytes),
      partitionNames: RockchipFlashProfile.dayu200.mappedPartitions.map(
        \.partitionName))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "arkdeck-rockchip-runtime-\(UUID().uuidString.lowercased())",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }
}
