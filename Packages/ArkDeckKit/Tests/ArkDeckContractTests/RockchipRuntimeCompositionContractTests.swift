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
    XCTAssertEqual(facts.profileID, "dayu200@1")
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
        .rockchip(.waitForLoader(
          stableIdentitySHA256: String(repeating: "a", count: 64)))
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
      guard case .confirmedCompleted = outcome else {
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
      usbProbe: FixedUSBProbe(identity: identity),
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
    _ plan: TypedProcessPlan
  ) -> HostManagedProcessDescriptor {
    guard case .hostManaged(let descriptor) = plan.kind else {
      preconditionFailure("expected host-managed plan")
    }
    return descriptor
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
