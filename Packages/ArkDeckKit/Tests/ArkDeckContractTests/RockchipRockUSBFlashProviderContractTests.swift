import Compression
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

// TASK-RF-002 contract tests for the DAYU200 Rockchip RockUSB Provider face of
// REQ-FLASH-001/002/004/007/008/012/013/015 (AC ownership: CHG-2026-020 verification.md).

final class RockchipRockUSBFlashProviderContractTests: XCTestCase {
  private let provider = RockchipRockUSBFlashProvider()
  private let timestamp = "2026-07-21T08:00:00Z"

  // MARK: - Single profile seed pin (drift guard)

  func testProfilePinsCurrentDAYU200SeedArchive() {
    let profile = RockchipFlashProfile.dayu200
    XCTAssertEqual(profile.archiveSizeBytes, 730_769_584)
    XCTAssertEqual(
      profile.archiveSHA256,
      "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e")
    XCTAssertEqual(profile.members.count, 17)
    XCTAssertEqual(
      profile.member(named: "system.img")?.sha256,
      "86357e57a183278e1662d55c2d560a35e8e685613bd270f62df42bdf783f0650")
    XCTAssertEqual(profile.member(named: "system.img")?.sizeBytes, 2_147_483_648)
    XCTAssertEqual(
      profile.member(named: "uboot.img")?.sha256,
      "c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d")
    XCTAssertEqual(
      profile.member(named: "userdata.img")?.sha256,
      "ea60e842586208b660b72ae4b507a1f4cabb397e912156f342f30f21907e1255")

    XCTAssertEqual(
      profile.mappedPartitions.map(\.partitionName),
      [
        "uboot", "resource", "boot_linux", "ramdisk", "system", "vendor", "updater",
        "chip_ckm", "userdata",
      ])
    XCTAssertEqual(
      profile.mappedPartitions.map(\.offsetSectors),
      [8192, 28672, 40960, 237_568, 245_760, 4_440_064, 6_742_016, 6_938_624, 19_955_712])
    XCTAssertEqual(profile.writeForbiddenMemberNames.sorted(), ["chip_prod.img", "sys_prod.img"])
    XCTAssertEqual(
      profile.membershiplessPartitionsWriteForbidden,
      ["misc", "bootctrl", "sys-prod", "chip-prod", "eng_system", "eng_chipset"])
    XCTAssertEqual(profile.prerequisites[.loader], .required)
    XCTAssertEqual(profile.prerequisites[.recoveryPath], .required)
    XCTAssertEqual(profile.prerequisites[.unlocked], .required)
    XCTAssertEqual(profile.prerequisites[.stablePower], .optional)
  }

  // MARK: - TEST-AC-FLASH-001-01 unsupported protocol

  func testTEST_AC_FLASH_001_01_UnsupportedDeviceBlocksPreflightWithoutSimilarCommands() throws {
    let fastbootDevice = RockchipProbeEvidence(
      usbVendorID: 0x18d1, usbProductID: 0x4ee0, reportedMode: "Fastboot")
    guard case .blocked(.deviceNotRockUSB) = provider.probe(fastbootDevice) else {
      return XCTFail("non-RockUSB device must block preflight")
    }
    XCTAssertTrue(provider.probe(fastbootDevice).blocksPreflight)

    let maskromDevice = RockchipProbeEvidence(
      usbVendorID: 0x2207, usbProductID: 0x350a, reportedMode: "Maskrom")
    guard case .blocked(.maskromModeNotSupportedByThisProvider) = provider.probe(maskromDevice)
    else {
      return XCTFail("Maskrom mode must block: this Provider only supports the Loader path")
    }

    guard
      case .blocked(.unrecognizedDeviceMode) = provider.probe(
        RockchipProbeEvidence(usbVendorID: 0x2207, usbProductID: 0x350a, reportedMode: "Mystery"))
    else {
      return XCTFail("unrecognized mode must block")
    }

    XCTAssertEqual(
      provider.probe(
        RockchipProbeEvidence(usbVendorID: 0x2207, usbProductID: 0x350a, reportedMode: "Loader")),
      .applicableLoaderMode)

    print("TEST-AC-FLASH-001-01 PASS preflight_blocked=3 backend=arkforge-native")
  }

  // MARK: - TEST-AC-FLASH-002-01 prerequisites gate

  func testTEST_AC_FLASH_002_01_RequiredPrerequisiteUnsatisfiedOrUnknownBlocksExecuteBranch()
    async throws
  {
    let satisfiedAll: [RockchipPrerequisiteObservation] = [
      .init(identifier: .loader, status: .satisfied),
      .init(identifier: .recoveryPath, status: .satisfied),
      .init(identifier: .unlocked, status: .satisfied),
    ]
    XCTAssertEqual(provider.evaluatePrerequisites(satisfiedAll), .cleared)

    // Missing observation is unknown, and unknown blocks (fail closed).
    let missingUnlocked = Array(satisfiedAll.prefix(2))
    guard
      case .blockedBeforeDestructiveConfirmation(let violations) = provider.evaluatePrerequisites(
        missingUnlocked)
    else {
      return XCTFail("missing required prerequisite must block")
    }
    XCTAssertEqual(violations.map(\.identifier), [.unlocked])
    XCTAssertEqual(violations.map(\.status), [.unknown])

    let loaderUnknown: [RockchipPrerequisiteObservation] = [
      .init(identifier: .loader, status: .unknown),
      .init(identifier: .recoveryPath, status: .satisfied),
      .init(identifier: .unlocked, status: .satisfied),
    ]
    XCTAssertTrue(provider.evaluatePrerequisites(loaderUnknown).blocksExecuteBranch)

    // A later duplicate observation must not upgrade an unsatisfied status.
    let contradictory =
      loaderUnknown + [
        RockchipPrerequisiteObservation(identifier: .loader, status: .satisfied)
      ]
    XCTAssertTrue(provider.evaluatePrerequisites(contradictory).blocksExecuteBranch)

    print("TEST-AC-FLASH-002-01 PASS blocked_before_destructive_confirmation dispatch=0")
  }

  // MARK: - Archive validation (Swift face supporting AC-FLASH-003-01, owned by TASK-RF-001)

  func testArchiveValidationBlocksExecuteAndPlannedSuccessOnAnyMismatch() {
    let profile = RockchipFlashProfile.dayu200
    XCTAssertEqual(profile.validate(matchingObservation(profile)), .valid)

    var tamperedMembers = matchingObservation(profile).members
    tamperedMembers[0] = RockchipArchiveMemberObservation(
      name: tamperedMembers[0].name,
      sizeBytes: tamperedMembers[0].sizeBytes,
      sha256: String(repeating: "0", count: 64))
    let hashMismatch = RockchipImagesArchiveObservation(
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: profile.archiveSHA256,
      members: tamperedMembers)
    guard case .blocked(let violations) = profile.validate(hashMismatch) else {
      return XCTFail("member hash mismatch must block")
    }
    XCTAssertTrue(
      violations.contains {
        if case .memberHashMismatch = $0 { return true }
        return false
      })
    XCTAssertTrue(profile.validate(hashMismatch).blocksExecuteAndPlannedSuccess)

    let undeclared = RockchipImagesArchiveObservation(
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: profile.archiveSHA256,
      members: matchingObservation(profile).members + [
        RockchipArchiveMemberObservation(
          name: "extra.img", sizeBytes: 1, sha256: String(repeating: "a", count: 64))
      ])
    guard case .blocked(let undeclaredViolations) = profile.validate(undeclared) else {
      return XCTFail("undeclared member must block as unknown provenance")
    }
    XCTAssertTrue(
      undeclaredViolations.contains { violation in
        if case .undeclaredMember(let name) = violation { return name == "extra.img" }
        return false
      })

    let missing = RockchipImagesArchiveObservation(
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: profile.archiveSHA256,
      members: Array(matchingObservation(profile).members.dropLast()))
    XCTAssertTrue(profile.validate(missing).blocksExecuteAndPlannedSuccess)

    // A plan cannot even be constructed from a blocked validation: execute and
    // planned-success are both structurally unreachable.
    XCTAssertThrowsError(
      try provider.makePlan(mode: .planOnly, archiveValidation: profile.validate(hashMismatch))
    ) { error in
      guard case RockchipFlashProviderError.archiveNotValidated = error else {
        return XCTFail("expected archiveNotValidated, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try provider.makePlan(mode: .execute, archiveValidation: profile.validate(missing)))
  }

  // MARK: - Plan structure

  func testMakePlanEmitsClosedCommandSurfaceInProfileWriteOrder() throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)

    XCTAssertEqual(plan.steps.first?.kind, .requestConfirmation)
    XCTAssertEqual(
      plan.steps.map(\.kind),
      [.requestConfirmation, .enterUpdater, .verifyRemoteState]
        + Array(repeating: .flashPartition, count: 9)
        + [.verifyRemoteState, .rebootDevice, .verifyRemoteState])
    XCTAssertEqual(plan.postFlashVerification, .full)
    XCTAssertEqual(
      plan.steps.filter {
        $0.arguments["probeId"] == .string("rockusb-partition-readback")
      }.count, 1)

    let flashSteps = plan.steps.filter { $0.kind == .flashPartition }
    XCTAssertEqual(flashSteps.map(\.id), plan.destructiveStepIDs)
    for (index, step) in flashSteps.enumerated() {
      let partition = provider.profile.mappedPartitions[index]
      let member = provider.profile.member(named: partition.imageMemberName)
      XCTAssertEqual(step.arguments["partition"], .string(partition.partitionName))
      XCTAssertEqual(step.arguments["imageArtifactId"], .string(partition.imageMemberName))
      XCTAssertEqual(step.arguments["imageSha256"], .string(member?.sha256 ?? ""))
      XCTAssertEqual(step.effect, .destructive)
      XCTAssertEqual(step.cancellation, .criticalNonInterruptible)
      XCTAssertEqual(step.bindingRequirement, .confirmedDevice)
      XCTAssertEqual(step.arguments["confirmationId"], .string(plan.confirmationID))
    }

    // The write-forbidden surface never appears in a plan.
    let planText = String(
      decoding: try provider.planDocument(for: plan).canonicalData(), as: UTF8.self)
    for forbidden in ["chip_prod", "sys_prod", "MiniLoaderAll", "eng_system", "bootctrl"] {
      XCTAssertFalse(planText.contains(forbidden), "\(forbidden) leaked into the plan")
    }

    // Deterministic digests: same profile and nonce → same digests; a different plan
    // (different nonce → different step identifiers) → different step-set digest.
    let again = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    XCTAssertEqual(plan.planDigestSHA256, again.planDigestSHA256)
    XCTAssertEqual(plan.stepSetDigestSHA256, again.stepSetDigestSHA256)
    let differentPlan = try provider.makePlan(
      mode: .execute, archiveValidation: .valid, planNonce: "other")
    XCTAssertNotEqual(plan.stepSetDigestSHA256, differentPlan.stepSetDigestSHA256)
    let basic = try provider.makePlan(
      mode: .execute, archiveValidation: .valid, postFlashVerification: .basic)
    XCTAssertEqual(basic.postFlashVerification, .basic)
    XCTAssertEqual(plan.stepSetDigestSHA256, basic.stepSetDigestSHA256)
    XCTAssertNotEqual(plan.planDigestSHA256, basic.planDigestSHA256)
  }

  // MARK: - TEST-AC-FLASH-004-01 execution mode identity

  func testTEST_AC_FLASH_004_01_ExecutionModeStaysIdentifiableInPersistedPlanDocument() throws {
    var digests: Set<String> = []
    for mode in RockchipFlashExecutionMode.allCases {
      let plan = try provider.makePlan(mode: mode, archiveValidation: .valid)
      let document = provider.planDocument(for: plan)
      let data = try document.canonicalData()
      let decoded = try JSONDecoder().decode(RockchipFlashPlanDocument.self, from: data)
      XCTAssertEqual(decoded.executionMode, mode)
      XCTAssertEqual(decoded.providerIdentity, RockchipRockUSBFlashProvider.providerIdentity)
      XCTAssertEqual(decoded.profileIdentity, RockchipFlashProfile.profileIdentity)
      XCTAssertEqual(decoded.planDigestSHA256, plan.planDigestSHA256)
      XCTAssertEqual(decoded.postFlashVerification, .full)
      XCTAssertEqual(decoded.steps.map(\.id), plan.steps.map(\.id))
      digests.insert(plan.planDigestSHA256)
      XCTAssertTrue(
        String(decoding: data, as: UTF8.self).contains("\"executionMode\":\"\(mode.rawValue)\""))
    }
    // The three modes are mutually distinguishable, including through the digest.
    XCTAssertEqual(digests.count, RockchipFlashExecutionMode.allCases.count)

    let plan = try provider.makePlan(mode: .simulated, archiveValidation: .valid)
    var tampered =
      try JSONSerialization.jsonObject(
        with: provider.planDocument(for: plan).canonicalData()) as! [String: Any]
    tampered["schemaVersion"] = "9.9.9"
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        RockchipFlashPlanDocument.self,
        from: JSONSerialization.data(withJSONObject: tampered)))
    print("TEST-AC-FLASH-004-01 PASS modes=execute,planOnly,simulated distinct_digests=3")
  }

  // MARK: - TEST-AC-FLASH-008-01 critical write exit deferral

  func testTEST_AC_FLASH_008_01_ExitRequestDuringCriticalWriteIsDurablyDeferredToSafeBoundary()
    async throws
  {
    let container = FileManager.default.temporaryDirectory
      .appending(path: "rockusb-boundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    let layout = try SessionLayout(
      sessionID: "rk-test-session", jobID: "rk-test-job",
      root: container.appending(path: "session"))
    let auditStore = try FileDurableSessionAuditStore(layout: layout)

    let boundary = RockchipCriticalWriteBoundary()
    let criticalStepID = "rk-rf002-wlx-5-system"
    try await boundary.beginCriticalWrite(stepID: criticalStepID)

    let record = await boundary.requestExit(
      reason: "app-quit-requested", timestamp: timestamp)
    XCTAssertEqual(record.disposition, .deferredUntilSafeBoundary)
    XCTAssertEqual(record.activeCriticalStepID, criticalStepID)

    try auditStore.appendAndSynchronize(
      try record.auditRecord(sessionID: layout.sessionID, jobID: layout.jobID))
    let replayed = try auditStore.replay(correlationID: "rockusb-flash-run")
    XCTAssertEqual(replayed.count, 1)
    XCTAssertEqual(replayed.first?.details["disposition"], .string("deferredUntilSafeBoundary"))
    XCTAssertEqual(replayed.first?.details["activeCriticalStepId"], .string(criticalStepID))

    let stillCritical = await boundary.activeCriticalStepID
    XCTAssertEqual(stillCritical, criticalStepID)
    let mayStartDuringCritical = await boundary.mayStartNextStep()
    XCTAssertFalse(mayStartDuringCritical)

    let resolved = try await boundary.reachSafeBoundary(stepID: criticalStepID)
    XCTAssertEqual(resolved, record)
    let blocked = await boundary.subsequentStepsBlocked
    XCTAssertTrue(blocked)
    do {
      try await boundary.beginCriticalWrite(stepID: "rk-rf002-wlx-6-vendor")
      XCTFail("subsequent steps must be blocked after a deferred exit takes effect")
    } catch RockchipCriticalWriteBoundaryError.subsequentStepsBlocked {
    }

    let idleBoundary = RockchipCriticalWriteBoundary()
    let idleRecord = await idleBoundary.requestExit(reason: "app-quit", timestamp: timestamp)
    XCTAssertEqual(idleRecord.disposition, .effectiveImmediately)
    let idleMayStart = await idleBoundary.mayStartNextStep()
    XCTAssertFalse(idleMayStart)
    print("TEST-AC-FLASH-008-01 PASS deferral_durable=1 write_killed=0")
  }

  // MARK: - TEST-AC-FLASH-012-01 typed Runtime outcome

  func testTEST_AC_FLASH_012_01_OnlyTypedConfirmedReceiptsCanSucceed() throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)

    // Sanity: the fully confirmed observation is succeeded.
    let happy = provider.assessOutcome(plan: plan, observation: fullObservation())
    XCTAssertTrue(happy.isSucceeded)
    XCTAssertEqual(happy.certainty, .confirmed)
    XCTAssertNil(happy.recoveryGuide)

    // An unknown native write receipt can never be upgraded to success.
    var writes = fullObservation().partitionWrites
    writes[4] = RockchipPartitionWriteObservation(
      partitionName: "system", outcome: .outcomeUnknown("native receipt is incomplete"))
    let unverifiedWrite = provider.assessOutcome(
      plan: plan,
      observation: RockchipFlashRunObservation(
        partitionWrites: writes,
        resetOutcome: .confirmed,
        postflightOutcome: .confirmed))
    XCTAssertFalse(unverifiedWrite.isSucceeded)
    XCTAssertEqual(unverifiedWrite.jobState, .waitingForRecovery)
    XCTAssertEqual(unverifiedWrite.certainty, .outcomeUnknown)

    // The native plan must carry a confirmed postflight receipt.
    let postflightMismatch = provider.assessOutcome(
      plan: plan,
      observation: RockchipFlashRunObservation(
        partitionWrites: fullObservation().partitionWrites,
        resetOutcome: .confirmed,
        postflightOutcome: .outcomeUnknown("bound device did not reconnect")))
    XCTAssertFalse(postflightMismatch.isSucceeded)
    XCTAssertNotNil(postflightMismatch.recoveryGuide)

    // An explicit native refusal is a confirmed failure, not silent success.
    var rejected = fullObservation().partitionWrites
    rejected[0] = RockchipPartitionWriteObservation(
      partitionName: "uboot", outcome: .failed("native backend refused the write"))
    let subsetRejection = provider.assessOutcome(
      plan: plan,
      observation: RockchipFlashRunObservation(
        partitionWrites: rejected,
        resetOutcome: .outcomeUnknown("not reached"),
        postflightOutcome: .outcomeUnknown("not reached")))
    XCTAssertEqual(subsetRejection.jobState, .failed)
    XCTAssertEqual(subsetRejection.certainty, .confirmed)
    print("TEST-AC-FLASH-012-01 PASS typed_unknown_receipt=not_succeeded")
  }

  // MARK: - TEST-AC-FLASH-013-01 bounded honest recovery

  func testTEST_AC_FLASH_013_01_NoReconnectExposesProviderRecoveryPathAndUnknownState() throws {
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    let assessment = provider.assessOutcome(
      plan: plan,
      observation: RockchipFlashRunObservation(
        partitionWrites: fullObservation().partitionWrites,
        resetOutcome: .confirmed,
        postflightOutcome: .outcomeUnknown("bound device did not reconnect")))

    XCTAssertFalse(assessment.isSucceeded)
    XCTAssertEqual(assessment.jobState, .waitingForRecovery)
    XCTAssertEqual(assessment.certainty, .outcomeUnknown)
    let guide = try XCTUnwrap(assessment.recoveryGuide)
    XCTAssertEqual(guide.deviceMode, "unknown")
    XCTAssertFalse(guide.automaticRecoveryGuaranteed)
    XCTAssertTrue(
      guide.manualRecoverySteps.contains { $0.contains("outcomeUnknown") })
    XCTAssertTrue(
      guide.manualRecoverySteps.contains { $0.contains("ArkForge native discovery") })
    XCTAssertTrue(guide.manualRecoverySteps.contains { $0.contains("Loader") })
    XCTAssertTrue(
      guide.manualRecoverySteps.contains { $0.contains("safeToSupersedeByCompleteOverwrite") })
    XCTAssertTrue(guide.disclosures.contains { $0.contains("destroy user data") })
    XCTAssertTrue(guide.disclosures.contains { $0.contains("Maskrom rescue") })
    XCTAssertEqual(guide.lastConfirmedStepID, plan.destructiveStepIDs.last)
    print("TEST-AC-FLASH-013-01 PASS state=waitingForRecovery certainty=outcomeUnknown")
  }

  // MARK: - CLI authority resolution (REQ-FLASH-015 product face)

  func testExecutionAuthorityResolutionFailsClosed() {
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: true, standardInputIsInteractive: true, environmentOverride: nil),
      .humanOperator)
    // No TTY → never human, no matter what was claimed.
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: true, standardInputIsInteractive: false, environmentOverride: nil),
      .standardAgent)
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: false, standardInputIsInteractive: true, environmentOverride: nil),
      .standardAgent)
    // The environment can only downgrade, never claim human authority.
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: true, standardInputIsInteractive: true, environmentOverride: "ci"),
      .ordinaryCI)
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: true, standardInputIsInteractive: true, environmentOverride: "agent"),
      .standardAgent)
    XCTAssertEqual(
      RockchipExecutionAuthorityResolver.resolve(
        operatorProvided: false, standardInputIsInteractive: false,
        environmentOverride: "humanOperator"),
      .standardAgent)
  }

  // MARK: - Gzip/tar streaming inventory

  func testGzipTarArchiveReaderSummarizesMembersWithExactHashes() throws {
    let memberA = Data("uboot-image-content".utf8)
    let memberB = Data(repeating: 0x5a, count: 600)
    let memberC = Data()
    let tar = Self.tarArchive([
      ("uboot.img", memberA), ("system.img", memberB), ("empty.img", memberC),
    ])
    let gzipped = Self.gzip(tar, fileName: "images.tar")
    let url = FileManager.default.temporaryDirectory
      .appending(path: "rockusb-tar-\(UUID().uuidString).tar.gz")
    defer { try? FileManager.default.removeItem(at: url) }
    try gzipped.write(to: url)

    let summary = try GzipTarArchiveReader.summarize(fileAt: url)
    XCTAssertEqual(summary.archiveSizeBytes, Int64(gzipped.count))
    XCTAssertEqual(summary.archiveSHA256, Self.sha256Hex(gzipped))
    XCTAssertEqual(summary.members.map(\.name), ["uboot.img", "system.img", "empty.img"])
    XCTAssertEqual(summary.members.map(\.sizeBytes), [19, 600, 0])
    XCTAssertEqual(
      summary.members.map(\.sha256),
      [Self.sha256Hex(memberA), Self.sha256Hex(memberB), Self.sha256Hex(memberC)])

    let observation = summary.archiveObservation()
    XCTAssertEqual(observation.members.count, 3)
  }

  func testGzipTarArchiveReaderFailsClosedOnCorruptInput() throws {
    let tar = Self.tarArchive([("a.img", Data("payload".utf8))])
    var notGzip = Self.gzip(tar)
    notGzip[0] = 0x00
    let notGzipURL = try Self.writeTemporary(notGzip)
    defer { try? FileManager.default.removeItem(at: notGzipURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: notGzipURL)) { error in
      XCTAssertEqual(error as? GzipTarArchiveReaderError, .notGzip)
    }

    // A valid gzip stream whose tar payload ends inside a member must not yield a summary.
    let truncatedTar = tar.prefix(tar.count - 700)
    let truncatedURL = try Self.writeTemporary(Self.gzip(Data(truncatedTar)))
    defer { try? FileManager.default.removeItem(at: truncatedURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: truncatedURL)) { error in
      XCTAssertEqual(error as? GzipTarArchiveReaderError, .truncatedArchive)
    }

    // Truncated deflate payload fails as corrupt, never as an empty-but-valid archive.
    let truncatedDeflate = Self.gzip(tar).prefix(40)
    let truncatedDeflateURL = try Self.writeTemporary(Data(truncatedDeflate))
    defer { try? FileManager.default.removeItem(at: truncatedDeflateURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: truncatedDeflateURL))
  }

  /// A flash bundle is parsed before any authorization runs, so a crafted
  /// header must not be able to terminate the host process. The GNU base-256
  /// size field can carry `Int64.max` without tripping the parser's own
  /// per-shift overflow guard; adding the 512-byte alignment to it then traps.
  /// Only a non-regular-file type flag reaches that addition.
  func testAMemberSizeThatCannotHoldItsAlignmentIsRefusedRatherThanTrapping() throws {
    // 0x80 marks base-256; the remaining bytes are chosen so the parser's
    // `value <= Int64.max >> 8` guard passes at every shift and lands on
    // exactly `Int64.max`.
    var sizeField = [UInt8](repeating: 0xFF, count: 12)
    sizeField[0] = 0x80
    sizeField[1] = 0x00
    sizeField[2] = 0x00
    sizeField[3] = 0x00
    sizeField[4] = 0x7F

    var header = [UInt8](repeating: 0, count: 512)
    header.replaceSubrange(0..<9, with: Array("giant.img".utf8))
    header.replaceSubrange(124..<136, with: sizeField)
    header[156] = 0x35  // directory: not 0x30/0x00, so it takes the padding branch
    header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
    header.replaceSubrange(263..<265, with: Array("00".utf8))
    header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    let checksum = header.reduce(0) { $0 + Int($1) }
    header.replaceSubrange(148..<154, with: Array(String(format: "%06o", checksum).utf8))
    header[154] = 0
    header[155] = 0x20

    var archive = Data(header)
    archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    let url = try Self.writeTemporary(Self.gzip(archive))
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: url)) { error in
      guard case .corruptTarHeader(let detail) = error as? GzipTarArchiveReaderError else {
        return XCTFail("expected a corrupt-header refusal, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("alignment"),
        "the refusal must name the unrepresentable size, got: \(detail)")
    }
  }

  // MARK: - helpers

  private func matchingObservation(_ profile: RockchipFlashProfile)
    -> RockchipImagesArchiveObservation
  {
    RockchipImagesArchiveObservation(
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: profile.archiveSHA256,
      members: profile.members.map {
        RockchipArchiveMemberObservation(name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
      })
  }

  private func fullObservation() -> RockchipFlashRunObservation {
    RockchipFlashRunObservation(
      partitionWrites: provider.profile.mappedPartitions.map {
        RockchipPartitionWriteObservation(
          partitionName: $0.partitionName,
          outcome: .confirmed)
      },
      resetOutcome: .confirmed,
      postflightOutcome: .confirmed)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeTemporary(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "rockusb-fixture-\(UUID().uuidString)")
    try data.write(to: url)
    return url
  }

  // Minimal ustar writer for fixtures.
  private static func tarArchive(_ members: [(name: String, content: Data)]) -> Data {
    var archive = Data()
    for member in members {
      var header = [UInt8](repeating: 0, count: 512)
      let nameBytes = Array(member.name.utf8)
      header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
      func writeOctal(_ value: Int, at range: Range<Int>) {
        let text = String(format: "%0\(range.count - 1)o", value)
        header.replaceSubrange(
          range.lowerBound..<range.lowerBound + text.utf8.count, with: Array(text.utf8))
      }
      writeOctal(0o644, at: 100..<108)
      writeOctal(0, at: 108..<116)
      writeOctal(0, at: 116..<124)
      writeOctal(member.content.count, at: 124..<136)
      writeOctal(0, at: 136..<148)
      header[156] = 0x30
      header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
      header.replaceSubrange(263..<265, with: Array("00".utf8))
      header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
      let checksum = header.reduce(0) { $0 + Int($1) }
      let checksumText = String(format: "%06o", checksum)
      header.replaceSubrange(148..<154, with: Array(checksumText.utf8))
      header[154] = 0
      header[155] = 0x20
      archive.append(contentsOf: header)
      archive.append(member.content)
      let padding = (512 - member.content.count % 512) % 512
      archive.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }
    archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    return archive
  }

  private static func gzip(_ payload: Data, fileName: String? = nil) -> Data {
    var output = Data([0x1f, 0x8b, 0x08, fileName == nil ? 0x00 : 0x08, 0, 0, 0, 0, 0x00, 0x03])
    if let fileName {
      output.append(contentsOf: Array(fileName.utf8))
      output.append(0)
    }
    let deflated = payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
      let capacity = payload.count + 4096
      let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
      defer { destination.deallocate() }
      let written = compression_encode_buffer(
        destination, capacity,
        input.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
        nil, COMPRESSION_ZLIB)
      return Data(bytes: destination, count: written)
    }
    output.append(deflated)
    var crc = Self.crc32(payload).littleEndian
    withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
    var size = UInt32(truncatingIfNeeded: payload.count).littleEndian
    withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
    return output
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
      }
      table[index] = value
    }
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }
    return crc ^ 0xffff_ffff
  }
}
