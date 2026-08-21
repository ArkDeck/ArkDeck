import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

final class Dayu20070035RuntimePlanOnlyContractTests: XCTestCase {
  private static let archiveEnvironmentKey = "ARKDECK_DAYU200_70035_IMAGE"
  private static let targetIdentity = String(repeating: "a", count: 64)
  private static let toolIdentity = String(repeating: "b", count: 64)

  private actor DispatchLog {
    private var count = 0

    func record() { count += 1 }
    func snapshot() -> Int { count }
  }

  /// Supplies only the immutable native toolchain identity needed to
  /// materialize delegated StepPermit descriptors. A plan-only request must
  /// never call either execution method.
  private actor NonDispatchingArkForgeLane: RuntimeJobEngine.ArkForgeLane {
    nonisolated let toolchainSHA256: String

    init(toolchainSHA256: String) {
      self.toolchainSHA256 = toolchainSHA256
    }

    func perform(
      stepID: String, jobID _: String, artifact _: ArkForgeLaneArtifact,
      binding _: ArkForgeLaneDeviceBinding, executionPurpose _: String
    ) async throws -> ArkForgeActionReceiptSummary {
      throw RuntimeDispatchFailure.failed(
        "planOnly must never execute delegated ArkForge step \(stepID)")
    }

    func completedPlanReceipt(jobID _: String) async -> ArkForgeActionReceiptSummary? {
      nil
    }
  }

  private struct RefusingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog

    func unavailableReason(providerID _: String) -> String? { nil }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.record()
      throw RuntimeDispatchFailure.failed(
        "planOnly must never call dispatch for \(plan.action.effect.rawValue)")
    }
  }

  private struct FactsPort: RockchipRuntimeFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "rockchip",
        toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
        toolSHA256: Dayu20070035RuntimePlanOnlyContractTests.toolIdentity,
        serverFacts: [:], targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          Dayu20070035RuntimePlanOnlyContractTests.targetIdentity,
        executionConnectKey: "sealed-plan-only-connect-key",
        deviceModel: "DAYU200 (RK3568)", deviceMode: "sealed-facts",
        buildFingerprint: "preflight-only",
        transport: "sealed-fixture",
        profileID: "dayu200", collectedAtUTC: "2026-08-01T00:00:00Z")
    }
  }

  // The archive fail-closed composition under contract: describe -> forBuild
  // -> validate is exactly the shape FlashPlanPresentationBuilder.prepare
  // runs before the review renders. The plan-fabrication tail that used to
  // follow it was dissolved by CHG-2026-066 — the executed plan is the
  // engine's, materialized at submission.
  private enum PlanFactFailure: Error, Equatable { case archiveValidationFailed }

  private func validatedArchiveProfile(
    summary: GzipTarArchiveSummary,
    board: RockchipFlashProfile = .dayu200
  ) throws -> RockchipFlashProfile {
    let profile: RockchipFlashProfile
    do {
      profile = try board.forBuild(
        RockchipImageArchiveIntrospection.describe(summary: summary, board: board))
    } catch {
      throw PlanFactFailure.archiveValidationFailed
    }
    guard profile.validate(summary.archiveObservation()) == .valid else {
      throw PlanFactFailure.archiveValidationFailed
    }
    return profile
  }

  func testOpenHarmony70035ProfilePinsEveryMemberAndExactNinePartitionPlan() throws {
    let profile = RockchipFlashProfile.dayu200
    XCTAssertEqual(profile.catalogReference, "dayu200")
    XCTAssertEqual(profile.firmwareVersion, "OpenHarmony-7.0.0.35-20260728_180253")
    // The booted device answers with the values baked into system.img — model
    // "ohos" and fullname "OpenHarmony-7.0.0.36" — not with values inferred
    // from the archive's file name (real-device readout, 2026-08-04).
    XCTAssertEqual(profile.runtimeProductModel, "ohos")
    XCTAssertEqual(profile.runtimeBuildVersion, "OpenHarmony-7.0.0.36")
    XCTAssertEqual(profile.archiveSizeBytes, 730_769_584)
    XCTAssertEqual(
      profile.archiveSHA256,
      "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e")

    let expectedMembers: [String: (Int64, String)] = [
      "boot_linux.img": (
        67_108_864, "1202a1ba694aaa3d53f104e6374a9aaffd0dba048c3122cf9f4704c4063bd757"
      ),
      "chip_ckm.img": (
        33_554_432, "f99c14c2520f618c721c963307ddc72ec47aefb5a71c7b29b268b1b33edcc0db"
      ),
      "chip_prod.img": (
        52_428_800, "44797e1616481c6211526358c11056862e04a3595dd81f59e41aec03a384ad29"
      ),
      "config.cfg": (10_399, "4d06d303faff1d3e530a9d2c9bb22073427b0b498bb4bb438b5177897d86f33c"),
      "daily_build.log": (
        24_507_809, "8454628003ab59a4edf28c073b39ec3891cad925283244c3bed0b754ecf35503"
      ),
      "manifest_tag.xml": (
        115_118, "71f9293a21d21fb1da67d27b0482b198c62ce042bb80326d62e1a0f35ee12691"
      ),
      "MiniLoaderAll.bin": (
        455_104, "1cdd418032195210f191445ed96e2da5ea83d2cfe880c912ebec635839d76542"
      ),
      "parameter.txt": (788, "35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048"),
      "ramdisk.img": (
        2_366_141, "c7e94434b4624ef70a5b9472d4848212a79c89b7a8cb5a453262e56a72e5dec9"
      ),
      "resource.img": (
        5_652_480, "208ceef6be9ba6d5781033bf00718b15f54d0210ae2f0e8134d4a5e40a9c13e7"
      ),
      "sys_prod.img": (
        52_428_800, "631845214a4ca4da44094165e30509eb2254a601350b56f90197bf78c3aa85d7"
      ),
      "system.img": (
        2_147_483_648, "86357e57a183278e1662d55c2d560a35e8e685613bd270f62df42bdf783f0650"
      ),
      "uboot.img": (4_194_304, "c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d"),
      "updater_binary": (
        3_248_972, "250b6ebc32f33088a328804cc918766aa6ea30f1c0acc8e2d08cf3ec7cf8f23f"
      ),
      "updater.img": (
        20_688_145, "907076f10bc295a3712a911c31c7c8f83bb164cdff4d8d9c1c62d3e91c0f637a"
      ),
      "userdata.img": (
        1_468_006_400, "ea60e842586208b660b72ae4b507a1f4cabb397e912156f342f30f21907e1255"
      ),
      "vendor.img": (
        268_431_360, "b3ffda2b6dbae220361721ee6b78d25e2055ab506e5480b17eacf477ea482360"
      ),
    ]
    XCTAssertEqual(profile.members.count, expectedMembers.count)
    for member in profile.members {
      let expected = try XCTUnwrap(expectedMembers[member.name])
      XCTAssertEqual(member.sizeBytes, expected.0, member.name)
      XCTAssertEqual(member.sha256, expected.1, member.name)
    }

    XCTAssertEqual(
      profile.mappedPartitions.map(\.partitionName),
      [
        "uboot", "resource", "boot_linux", "ramdisk", "system", "vendor",
        "updater", "chip_ckm", "userdata",
      ])
    XCTAssertEqual(profile.writeForbiddenMemberNames.sorted(), ["chip_prod.img", "sys_prod.img"])

    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    XCTAssertEqual(descriptor.profiles, ["dayu200"])
    XCTAssertEqual(
      descriptor.inputs.first { $0.name == "deviceProfile" }?.enumValues,
      ["dayu200"])
  }

  /// Partition order is still the board's and is still enforced. The two old
  /// versioned references are no longer aliases for new destructive requests.
  func testProviderEnforcesPartitionOrderAndRejectsVersionedReferences() throws {
    let profile = RockchipFlashProfile.dayu200
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let step = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "flash-partitions" })
    let context = ProviderExecutionContext(
      jobID: "job-plan-only", stepID: step.stepID,
      targetID: "TGT-DAYU200-70035", bindingRevision: 7,
      connectKey: "sealed-plan-only-connect-key",
      expectedIdentitySHA256: Self.targetIdentity,
      toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
      toolSHA256: Self.toolIdentity,
      nowUTC: "2026-08-01T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-70035",
        fileURL: URL(filePath: "/private/tmp/images.tar.gz"),
        sha256: profile.archiveSHA256,
        byteCount: Int(profile.archiveSizeBytes)))
    let inputs = flashInputs(
      lease: "lease-v1:gj4:ART-70035", profile: profile)
    let provider = ArkForgeFlashProviderAdapter(availability: .available)
    // The flash step no longer lowers to an ArkDeck provider action: the write
    // is arkforged's, reached by StepPermit (CHG-2026-059). The adapter says so
    // rather than producing a different action, because a plan that quietly
    // materialized something else would be a plan nobody authorized.
    XCTAssertThrowsError(
      try provider.action(
        for: step, operation: descriptor, inputs: inputs, context: context)
    ) { error in
      guard case DeviceProviderError.unsupportedAction(let detail) = error else {
        return XCTFail("expected a typed refusal, got \(error)")
      }
      XCTAssertTrue(detail.contains("arkforged"), detail)
      XCTAssertTrue(detail.contains("StepPermit"), detail)
    }

    var reordered = inputs
    reordered["partitionPlan"] = .array(
      profile.mappedPartitions.map(\.partitionName).reversed().map(JSONValue.string))
    XCTAssertThrowsError(
      try provider.action(
        for: step, operation: descriptor, inputs: reordered, context: context))

    for reference in ["dayu200@1", "dayu200@2", "dayu200@99"] {
      var rejected = inputs
      rejected["deviceProfile"] = .string(reference)
      XCTAssertThrowsError(
        try provider.action(
          for: step, operation: descriptor, inputs: rejected, context: context),
        reference)
    }
  }

  /// A summary as a real read produces one: member digests, the captured
  /// partition table and the version scanned out of the system image.
  private func summary(
    for profile: RockchipFlashProfile,
    archiveSHA256: String? = nil,
    members: [GzipTarMemberSummary]? = nil,
    partitionTable: String? = nil,
    version: String? = "OpenHarmony-7.0.0.36"
  ) -> GzipTarArchiveSummary {
    let table =
      partitionTable
      ?? ("CMDLINE:mtdparts=rk29xxnand:"
        + profile.mappedPartitions.enumerated()
          .map { "0x1@0x\(String(($0.offset + 1) * 0x2000, radix: 16))(\($0.element.partitionName))" }
        .joined(separator: ",")
        + ","
        + profile.membershiplessPartitionsWriteForbidden.map { "0x1@0x1(\($0))" }
        .joined(separator: ","))
    return GzipTarArchiveSummary(
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: archiveSHA256 ?? profile.archiveSHA256,
      members: members
        ?? profile.members.map {
          GzipTarMemberSummary(name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
        },
      capturedMembers: [
        RockchipFlashProfile.partitionTableMemberName: Data(table.utf8)
      ],
      scannedValue: version)
  }

  /// Archive validation plans for the archive it is given.
  ///
  /// It used to select a profile by matching the archive's digest against the
  /// builds compiled into the product, so a firmware daily published after the
  /// last release could not be planned at all. "Drift" now means the archive
  /// does not fit the board — a missing image, an unknown partition, an
  /// unreadable version — not that nobody had met it before.
  func testAuthorizedArchiveValidationAcceptsWhateverFitsTheBoard() throws {
    let profile = RockchipFlashProfile.dayu200

    // Admission receives the profile from this one summary. Dispatcher may
    // therefore reuse the invocation-local profile without a second archive
    // description pass, while upload/import still validate the actual file.
    let validated = try validatedArchiveProfile(
      summary: summary(for: profile), board: profile)
    XCTAssertEqual(validated.catalogReference, profile.catalogReference)
    XCTAssertEqual(validated.archiveSizeBytes, profile.archiveSizeBytes)
    XCTAssertEqual(validated.archiveSHA256, profile.archiveSHA256)
    XCTAssertEqual(validated.members, profile.members)
    XCTAssertEqual(validated.mappedPartitions, profile.mappedPartitions)
    XCTAssertEqual(
      validated.membershiplessPartitionsWriteForbidden,
      profile.membershiplessPartitionsWriteForbidden)
    XCTAssertEqual(validated.prerequisites, profile.prerequisites)
    XCTAssertEqual(validated.runtimeBuildVersion, profile.runtimeBuildVersion)
    XCTAssertEqual(validated.firmwareVersion, profile.runtimeBuildVersion)

    // A build nobody enumerated validates, and its profile records its own
    // digest.
    let unknownDigest = String(repeating: "0", count: 64)
    let unknownValidated = try validatedArchiveProfile(
      summary: summary(for: profile, archiveSHA256: unknownDigest), board: profile)
    XCTAssertEqual(unknownValidated.archiveSHA256, unknownDigest)
    XCTAssertEqual(
      unknownValidated.runtimeBuildVersion,
      profile.runtimeBuildVersion)

    // Structural drift still fails closed: an image the board maps is absent.
    let missingImage = profile.members.filter { $0.name != "system.img" }
      .map { GzipTarMemberSummary(name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256) }
    XCTAssertThrowsError(
      try validatedArchiveProfile(summary: summary(for: profile, members: missingImage))
    ) { error in
      XCTAssertEqual(error as? PlanFactFailure, .archiveValidationFailed)
    }

    // So does an archive whose system image declares no version, which would
    // otherwise leave post-flash verification with nothing to compare against.
    XCTAssertThrowsError(
      try validatedArchiveProfile(summary: summary(for: profile, version: nil))
    ) { error in
      XCTAssertEqual(error as? PlanFactFailure, .archiveValidationFailed)
    }

    // And a partition table naming something this board does not know.
    XCTAssertThrowsError(
      try validatedArchiveProfile(
        summary: summary(
          for: profile, partitionTable: "CMDLINE:mtdparts=rk29xxnand:0x1@0x1(vendor-secrets)"))
    ) { error in
      XCTAssertEqual(error as? PlanFactFailure, .archiveValidationFailed)
    }
  }

  /// Manual real-input gate. CI has no 730 MB firmware archive and skips it;
  /// release verification supplies ARKDECK_DAYU200_70035_IMAGE. The test uses
  /// sealed target facts and a dispatcher that fails if called, so it never
  /// probes HDC/USB/RockUSB and cannot dispatch Flash.
  func testRealArchiveMaterializesRuntimePlanOnlyAndNegativeCasesWithZeroDispatch()
    async throws
  {
    guard let archivePath = ProcessInfo.processInfo.environment[Self.archiveEnvironmentKey] else {
      throw XCTSkip("set \(Self.archiveEnvironmentKey) for the 7.0.0.35 real-input gate")
    }
    let archiveURL = URL(filePath: archivePath).standardizedFileURL
    let profile = RockchipFlashProfile.dayu200
    let summary = try GzipTarArchiveReader.summarize(
      fileAt: archiveURL,
      derivation: RockchipImageArchiveIntrospection.derivationRequest(board: profile))
    XCTAssertEqual(profile.validate(summary.archiveObservation()), .valid)
    let validated = try validatedArchiveProfile(summary: summary)
    XCTAssertEqual(validated.archiveSHA256, profile.archiveSHA256)
    XCTAssertEqual(validated.runtimeBuildVersion, profile.runtimeBuildVersion)

    let root = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-dayu200-70035-plan-only-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let artifactStore = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-01T00:00:00Z" })
    let artifact = try await artifactStore.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "input-flash-dayu200-70035", sessionID: "session-input-flash-dayu200-70035",
        stepID: "import-flash-bundle", name: "images.tar.gz",
        mediaType: "application/gzip", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-flash-bundle", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DAYU200-70035", bindingRevision: 7,
          stableIdentitySHA256: Self.targetIdentity),
        sourceFileURL: archiveURL,
        expectedByteCount: Int(profile.archiveSizeBytes),
        expectedSHA256: profile.archiveSHA256))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let dispatchLog = DispatchLog()
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory),
        arkForgeLane: NonDispatchingArkForgeLane(toolchainSHA256: Self.toolIdentity),
        arkForgeDeviceProfileID: "dayu200"),
      providers: DeviceProviderRegistry(providers: [
        ArkForgeFlashProviderAdapter(
          factsPort: FactsPort(), availability: .available)
      ]),
      dispatcher: RefusingDispatcher(log: dispatchLog),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-01T00:00:00Z" })

    let request = try flashRequest(
      requestID: "real-plan-only-positive", lease: lease,
      inputs: flashInputs(lease: lease, profile: profile))
    let preview = try await engine.planOnly(encoded(request))
    XCTAssertEqual(preview.executionMode, "planOnly")
    XCTAssertEqual(preview.operationReference, "flash.dayu200")
    XCTAssertEqual(preview.bindingRevision, 7)
    XCTAssertEqual(preview.stableIdentitySHA256, Self.targetIdentity)
    XCTAssertEqual(preview.inputs["deviceProfile"], .string("dayu200"))
    XCTAssertEqual(
      preview.inputs["partitionPlan"],
      .array(profile.mappedPartitions.map { .string($0.partitionName) }))
    XCTAssertEqual(preview.materializedPlanDigest.count, 64)
    XCTAssertTrue(preview.steps.contains { $0.stepID == "flash-partitions" })
    XCTAssertFalse(preview.jobAdmitted)
    XCTAssertEqual(preview.dispatchDisposition, "notDispatched")
    let positiveDispatchCount = await dispatchLog.snapshot()
    let positiveJobs = try await engine.listJobs()
    let positiveCapabilities = try await capabilityStore.list()
    XCTAssertEqual(positiveDispatchCount, 0)
    XCTAssertTrue(positiveJobs.isEmpty)
    XCTAssertTrue(positiveCapabilities.isEmpty)

    var wrongOrder = flashInputs(lease: lease, profile: profile)
    wrongOrder["partitionPlan"] = .array(
      profile.mappedPartitions.map(\.partitionName).reversed().map(JSONValue.string))
    await XCTAssertThrowsErrorAsync(
      try await engine.planOnly(
        encoded(
          try flashRequest(
            requestID: "real-plan-only-wrong-order", lease: lease,
            inputs: wrongOrder))))

    for (index, reference) in ["dayu200@1", "dayu200@2"].enumerated() {
      var versioned = flashInputs(lease: lease, profile: profile)
      versioned["deviceProfile"] = .string(reference)
      await XCTAssertThrowsErrorAsync(
        try await engine.planOnly(
          encoded(
            try flashRequest(
              requestID: "real-plan-only-versioned-\(index)", lease: lease,
              inputs: versioned))))
    }
    let negativeDispatchCount = await dispatchLog.snapshot()
    let negativeJobs = try await engine.listJobs()
    let negativeCapabilities = try await capabilityStore.list()
    XCTAssertEqual(negativeDispatchCount, 0)
    XCTAssertTrue(negativeJobs.isEmpty)
    XCTAssertTrue(negativeCapabilities.isEmpty)
  }

  private func flashInputs(
    lease: String, profile: RockchipFlashProfile
  ) -> [String: JSONValue] {
    [
      "imageBundleLease": .string(lease),
      "deviceProfile": .string(profile.catalogReference),
      "partitionPlan": .array(
        profile.mappedPartitions.map { .string($0.partitionName) }),
      "postFlashVerification": .string("basic"),
    ]
  }

  private func flashRequest(
    requestID: String, lease _: String, inputs: [String: JSONValue]
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: "idem-\(requestID)",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200-70035", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: inputs)
  }

  private func encoded(_ request: RuntimeOperationRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }
}
