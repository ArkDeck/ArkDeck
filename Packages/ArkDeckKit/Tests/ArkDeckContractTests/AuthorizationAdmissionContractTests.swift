import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class AuthorizationAdmissionContractTests: XCTestCase {
  private static let authorizationID = "AUTH-2026-025-DAYU200-001"
  private static let serial = "fixture-serial"
  private static let sessionID = "session-ain006"
  private static let targetID = "dayu200-fixture"
  private static let topology = "2"
  private static let timestamp = "2026-07-22T12:00:00Z"
  private static let codeOwners = Data(
    """
    # ArkDeck CODEOWNERS.
    #
    # Per openspec/governance/enforcement.md, a valid human approval is an
    # approving review by a configured human CODEOWNER on a protected branch/PR
    # (or an equivalent externally verifiable mechanism). @lvye is the human
    # maintainer; automation/agents must never be listed here.
    #
    # All paths require human owner review:
    * @lvye

    """.utf8)

  private struct Overrides {
    var bindingSessionID = AuthorizationAdmissionContractTests.sessionID
    var bindingRevision = 1
    var bindingSerial: String? = AuthorizationAdmissionContractTests.serial
    var bindingTopology: String? = AuthorizationAdmissionContractTests.topology
    var durableTargetID = AuthorizationAdmissionContractTests.targetID
    var toolJobID: String?
    var toolTargetID = AuthorizationAdmissionContractTests.targetID
    var toolMode = RockchipDeviceMode.loader
    var toolLocation: UInt64 = 2
    var toolSequence: UInt64 = 1
    var toolProfile = RockchipDiscoveryIntegrationProfile.pinnedProduction.identifier
    var toolSHA256 = RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    var prerequisiteStatus = RockchipPrerequisiteStatus.satisfied
    var readbackSerialDigest: String?
    var readbackTopology = AuthorizationAdmissionContractTests.topology
    var readbackSequence: UInt64 = 1
    var readbackObserved: UInt64 = 150
    var readbackDeadline: UInt64 = 30_000_000_150
    var readbackVendorID = RockchipProbeEvidence.rockUSBVendorID
    var readbackProductID = RockchipProbeEvidence.dayu200LoaderProductID
    var nowMonotonic: UInt64 = 200
    var factPlanNonce: String?
  }

  private struct Fixture {
    let service: AuthorizationAdmissionService
    let ledger: AuthorizationUsageLedger
    let request: AuthorizationAdmissionRequest
    let plan: RockchipFlashPlan
    let clock: FixedAdmissionClock
    let executableIdentity: ProcessExecutableIdentityReceipt
  }

  private func fixture(
    jobID: String = "job-ain006",
    root: URL? = nil,
    maxRuns: Int = 1,
    overrides: Overrides = Overrides(),
    faultInjector: AuthorizationUsageLedgerFaultInjector = .none
  ) throws -> Fixture {
    let provider = RockchipRockUSBFlashProvider()
    let plan = try provider.makePlan(
      mode: .execute, archiveValidation: .valid)
    let factPlan =
      try overrides.factPlanNonce.map {
        try provider.makePlan(mode: .execute, archiveValidation: .valid, planNonce: $0)
      } ?? plan
    let bytes = try authorizationBytes(plan: plan, maxRuns: maxRuns)
    let blob = Self.gitBlobOID(bytes)
    let snapshot = AuthorizationProvenanceSnapshot(
      repositoryFullName: MaintainerMergedAuthorizationResolver.repositoryFullName,
      branchName: MaintainerMergedAuthorizationResolver.protectedBranchName,
      branchProtected: true,
      mainCommitOID: String(repeating: "c", count: 40),
      registryPath: MaintainerMergedAuthorizationResolver.registryPath(
        for: Self.authorizationID),
      authorizationBytes: bytes,
      authorizationBlobOID: blob,
      reviewedHeadBlobOID: blob,
      mergeCommitBlobOID: blob,
      pullRequestNumber: 296,
      pullRequestMerged: true,
      pullRequestBaseBranch: "main",
      pullRequestAuthorLogin: "github-actions[bot]",
      pullRequestHeadOID: String(repeating: "d", count: 40),
      mergeCommitOID: String(repeating: "e", count: 40),
      mergeCommitIsAncestorOfMain: true,
      mergedByLogin: "lvye",
      reviews: [
        AuthorizationApprovalReview(
          reviewerLogin: "lvye", state: .approved,
          commitOID: String(repeating: "d", count: 40))
      ],
      codeOwnersBytes: Self.codeOwners,
      codeOwnersBlobOID: Self.gitBlobOID(Self.codeOwners))

    var attributes: [String: JSONValue] = [:]
    if let serial = overrides.bindingSerial { attributes["serial"] = .string(serial) }
    if let topology = overrides.bindingTopology { attributes["usbTopology"] = .string(topology) }
    let binding = try CurrentDeviceBinding(
      revision: overrides.bindingRevision,
      connectKey: "usb-fixture",
      transport: .usb,
      identitySnapshot: try DeviceIdentitySnapshot(attributes: attributes),
      evidence: ["fake-control"],
      confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
    let durable = try DurableCurrentDeviceBinding(
      reference: DeviceBindingReference(
        targetID: overrides.durableTargetID, revision: overrides.bindingRevision),
      binding: binding)

    let executableIdentity = ProcessExecutableIdentityReceipt(
      authorizedPath: "/opt/arkdeck/rkdeveloptool",
      inodeLaunchPath: "/.vol/1/2",
      device: 1,
      inode: 2,
      fileSize: 4096,
      mode: 0o100755,
      sha256: overrides.toolSHA256)
    let toolFact = RockchipTrustedToolDeviceFact(
      sessionID: Self.sessionID,
      jobID: overrides.toolJobID ?? jobID,
      targetID: overrides.toolTargetID,
      observationSequence: overrides.toolSequence,
      observedAtMonotonicNanoseconds: 100,
      profileIdentifier: overrides.toolProfile,
      observation: RockchipDeviceObservation(
        deviceNumber: 1,
        usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
        usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
        locationID: overrides.toolLocation,
        mode: overrides.toolMode),
      executableIdentity: executableIdentity)

    let prerequisites = RockchipTrustedPrerequisiteFact(
      sessionID: Self.sessionID, jobID: jobID, targetID: Self.targetID,
      observations: [
        RockchipPrerequisiteObservation(
          identifier: .loader, status: overrides.prerequisiteStatus),
        RockchipPrerequisiteObservation(
          identifier: .recoveryPath, status: overrides.prerequisiteStatus),
        RockchipPrerequisiteObservation(
          identifier: .unlocked, status: overrides.prerequisiteStatus),
      ])
    let readback = RockchipTrustedIdentityReadbackFact(
      sessionID: Self.sessionID,
      jobID: jobID,
      targetID: Self.targetID,
      observationSequence: overrides.readbackSequence,
      observedAtMonotonicNanoseconds: overrides.readbackObserved,
      deadlineMonotonicNanoseconds: overrides.readbackDeadline,
      observedAtTimestamp: Self.timestamp,
      serialDigestSHA256: overrides.readbackSerialDigest ?? Self.sha256(Self.serial),
      usbVendorID: overrides.readbackVendorID,
      usbProductID: overrides.readbackProductID,
      usbTopology: overrides.readbackTopology)
    let clock = FixedAdmissionClock(
      reading: RockchipTrustedClockReading(
        monotonicNanoseconds: overrides.nowMonotonic,
        auditTimestamp: Self.timestamp))
    let collector = RockchipAuthorizationFactCollector(
      planPort: FixedPlanFactPort(plan: factPlan),
      bindingPort: FixedBindingFactPort(
        value: RockchipTrustedDurableBindingFact(
          sessionID: overrides.bindingSessionID,
          jobID: jobID,
          targetID: Self.targetID,
          receipt: durable)),
      toolDevicePort: FixedToolFactPort(value: toolFact),
      prerequisitePort: FixedPrerequisiteFactPort(value: prerequisites),
      identityReadbackPort: FixedReadbackFactPort(value: readback),
      clock: clock)
    let ledgerRoot =
      root
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "arkdeck-ain006-\(UUID().uuidString)", isDirectory: true)
    let ledger = try AuthorizationUsageLedger(root: ledgerRoot, faultInjector: faultInjector)
    let resolver = MaintainerMergedAuthorizationResolver(
      port: FixedAdmissionProvenancePort(snapshot: snapshot))
    let service = AuthorizationAdmissionService(
      resolver: resolver, factCollector: collector, usageLedger: ledger, clock: clock)
    return Fixture(
      service: service,
      ledger: ledger,
      request: AuthorizationAdmissionRequest(
        authorizationID: Self.authorizationID,
        facts: RockchipAuthorizationFactRequest(
          archiveURL: URL(fileURLWithPath: "/tmp/fake-images.tar.gz"),
          sessionID: Self.sessionID,
          jobID: jobID,
          targetID: Self.targetID,
          targetLocationSelector: Self.topology)),
      plan: plan,
      clock: clock,
      executableIdentity: executableIdentity)
  }

  func testTEST_AIN_FACT_001_TrustedFactsMintOneShotAdmissionWithoutDispatch() async throws {
    let value = try fixture()
    let admission = try await value.service.admit(value.request)
    XCTAssertEqual(admission.authorizationReference.authorizationID, Self.authorizationID)
    XCTAssertEqual(admission.usageReservation.ordinal, 1)
    XCTAssertEqual(admission.facts.bindingReference.targetID, Self.targetID)
    XCTAssertEqual(admission.facts.usbTopology, Self.topology)
    XCTAssertEqual(admission.facts.executableIdentity, value.executableIdentity)

    let monitor = RockchipFlashDispatchMonitor()
    let decision = await RockchipFlashAuthorizationGate().authorizeUnattended(
      admission: admission, plan: value.plan, monitor: monitor)
    guard case .authorizedAgentAdmissionAccepted(let reservationID) = decision.outcome else {
      return XCTFail("trusted admission must pass the internal plan-binding gate")
    }
    XCTAssertEqual(reservationID, admission.usageReservation.reservationID)
    XCTAssertEqual(decision.evidenceEligibility, .authorizedAgentAdmissionOnly)
    XCTAssertEqual(decision.authorizationRef, admission.authorizationReference)
    XCTAssertEqual(decision.dispatchSnapshot.totalDispatchCount, 0)

    let consumed = try admission.consume(at: value.clock.now())
    XCTAssertEqual(consumed.usageReservation.reservationID, reservationID)
    XCTAssertEqual(consumed.facts.executableIdentity, value.executableIdentity)
    XCTAssertThrowsError(try admission.consume(at: value.clock.now())) { error in
      XCTAssertEqual(error as? AuthorizationAdmissionError, .capabilityAlreadyConsumed)
    }

    let expiryValue = try fixture(jobID: "job-expiry-consume")
    let expiryAdmission = try await expiryValue.service.admit(expiryValue.request)
    XCTAssertThrowsError(
      try expiryAdmission.consume(
        at: RockchipTrustedClockReading(
          monotonicNanoseconds: 200, auditTimestamp: "2031-01-01T00:00:00Z"))
    ) { error in
      XCTAssertEqual(error as? AuthorizationAdmissionError, .authorizationExpiredAtConsumption)
    }
    print(
      "TEST-AIN-FACT-001 PASS facts=trusted correlation=same-admission "
        + "serial=readback executable-identity=same-receipt capability=one-shot dispatch=0")
  }

  func testFactMismatchesFailBeforeUsageReservation() async throws {
    var cases: [(RockchipAuthorizationFactError, Overrides)] = []
    var wrongCorrelation = Overrides()
    wrongCorrelation.bindingSessionID = "other-session"
    cases.append((.correlationMismatch(field: "binding"), wrongCorrelation))
    var wrongRevision = Overrides()
    wrongRevision.bindingRevision = 2
    cases.append((.bindingMismatch(field: "revision"), wrongRevision))
    var wrongTarget = Overrides()
    wrongTarget.durableTargetID = "other-target"
    cases.append((.bindingMismatch(field: "targetID"), wrongTarget))
    var missingSerial = Overrides()
    missingSerial.bindingSerial = nil
    cases.append((.bindingMismatch(field: "serial"), missingSerial))
    var missingTopology = Overrides()
    missingTopology.bindingTopology = nil
    cases.append((.bindingMismatch(field: "usbTopology"), missingTopology))
    var wrongToolCorrelation = Overrides()
    wrongToolCorrelation.toolJobID = "other-job"
    cases.append((.correlationMismatch(field: "toolDevice"), wrongToolCorrelation))
    var badToolMode = Overrides()
    badToolMode.toolMode = .maskrom
    cases.append((.toolMismatch(field: "deviceObservation"), badToolMode))
    var badTopology = Overrides()
    badTopology.toolLocation = 3
    cases.append((.toolMismatch(field: "usbTopology"), badTopology))
    var badToolProfile = Overrides()
    badToolProfile.toolProfile = "caller-profile"
    cases.append((.toolMismatch(field: "profileIdentifier"), badToolProfile))
    var publicReceipt = Overrides()
    publicReceipt.toolSHA256 = String(repeating: "a", count: 64)
    cases.append((.toolMismatch(field: "executableIdentity"), publicReceipt))
    var replayedToolObservation = Overrides()
    replayedToolObservation.toolSequence = 0
    cases.append((.toolMismatch(field: "observationSequence"), replayedToolObservation))
    var planDrift = Overrides()
    planDrift.factPlanNonce = "drifted"
    cases.append((.planMismatch(field: "planDigestSHA256"), planDrift))
    var badPrerequisite = Overrides()
    badPrerequisite.prerequisiteStatus = .unknown
    cases.append((.prerequisiteMismatch, badPrerequisite))
    var badSerialReadback = Overrides()
    badSerialReadback.readbackSerialDigest = String(repeating: "a", count: 64)
    cases.append((.readbackMismatch(field: "serialDigestSHA256"), badSerialReadback))
    var badUSBReadback = Overrides()
    badUSBReadback.readbackProductID = 1
    cases.append((.readbackMismatch(field: "usbIdentity"), badUSBReadback))
    var badTopologyReadback = Overrides()
    badTopologyReadback.readbackTopology = "3"
    cases.append((.readbackMismatch(field: "usbTopology"), badTopologyReadback))
    var badSequence = Overrides()
    badSequence.readbackSequence = 2
    cases.append((.readbackMismatch(field: "observationSequence"), badSequence))
    var overlongReadback = Overrides()
    overlongReadback.readbackDeadline = 30_000_000_151
    cases.append((.readbackExpiredOrInvalid, overlongReadback))
    var expiredReadback = Overrides()
    expiredReadback.readbackDeadline = 199
    cases.append((.readbackExpiredOrInvalid, expiredReadback))

    for (expected, overrides) in cases {
      let value = try fixture(overrides: overrides)
      do {
        _ = try await value.service.admit(value.request)
        XCTFail("expected fact failure \(expected)")
      } catch let error as AuthorizationAdmissionError {
        XCTAssertEqual(error, .facts(expected))
      }
      XCTAssertTrue(try value.ledger.load().reservations.isEmpty)
    }
  }

  func testTEST_AIN_USAGE_001_ReservationIsAtomicIdempotentAndNeverRefunded()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-ain006-shared-\(UUID().uuidString)", isDirectory: true)
    let first = try fixture(jobID: "job-a", root: root)
    let retryAdmission = try await first.service.admit(first.request)
    let exactRetry = try await first.service.admit(first.request)
    XCTAssertEqual(retryAdmission.usageReservation, exactRetry.usageReservation)
    XCTAssertEqual(try first.ledger.load().reservations.count, 1)

    let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-ain006-race-\(UUID().uuidString)", isDirectory: true)
    let racerA = try fixture(jobID: "job-race-a", root: secondRoot)
    let racerB = try fixture(jobID: "job-race-b", root: secondRoot)
    async let resultA = try? racerA.service.admit(racerA.request)
    async let resultB = try? racerB.service.admit(racerB.request)
    let winners = await [resultA, resultB].compactMap { $0 }
    XCTAssertEqual(winners.count, 1, "maxRuns=1 must have one atomic winner")
    XCTAssertEqual(try racerA.ledger.load().reservations.count, 1)

    let crashRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-ain006-crash-\(UUID().uuidString)", isDirectory: true)
    let fault = OneShotLedgerFault(point: .afterReplace)
    let crashing = try fixture(
      jobID: "job-crash", root: crashRoot,
      faultInjector: AuthorizationUsageLedgerFaultInjector { try fault.check($0) })
    do {
      _ = try await crashing.service.admit(crashing.request)
      XCTFail("injected post-replace crash must surface")
    } catch {
      // The reservation is deliberately not refunded even though the caller saw failure.
    }
    XCTAssertEqual(try crashing.ledger.load().reservations.count, 1)
    let recovered = try fixture(jobID: "job-crash", root: crashRoot)
    let recoveredAdmission = try await recovered.service.admit(recovered.request)
    XCTAssertEqual(recoveredAdmission.usageReservation.ordinal, 1)
    XCTAssertEqual(try recovered.ledger.load().reservations.count, 1)

    print(
      "TEST-AIN-USAGE-001 PASS maxRuns=1 atomic-winner=1 retry=idempotent "
        + "crash-after-replace=consumed no-refund=true")
  }

  func testCallerFacingSurfacesCannotInjectFactsOrObtainCommands() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let workflowSource = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift"), encoding: .utf8)
    let cliSource = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"), encoding: .utf8)

    for forbidden in [
      "RockchipStanding" + "AuthorizationContext", "RockchipUnattended" + "ExecutionIntent",
      "authorizedForUnattended" + "AgentExecution", "runUnattended" + "Execute",
      "CLIUnattended" + "Context",
    ] {
      XCTAssertFalse(workflowSource.contains(forbidden), forbidden)
      XCTAssertFalse(cliSource.contains(forbidden), forbidden)
    }
    XCTAssertFalse(cliSource.contains("-" + "-unattended-context"))
    XCTAssertFalse(cliSource.contains("-" + "-authorization <"))
    XCTAssertTrue(cliSource.contains("--authorization-id"))
    let unavailable = try XCTUnwrap(cliSource.range(of: "executorUnavailable"))
    let planRead = try XCTUnwrap(cliSource.range(of: "let plan = try validateAndPlan"))
    XCTAssertLessThan(unavailable.lowerBound, planRead.lowerBound)
    XCTAssertTrue(workflowSource.contains("func authorizeUnattended("))

    let factsSource = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift"), encoding: .utf8)
    XCTAssertTrue(factsSource.contains("attempt.observations.count == 1"))
    XCTAssertTrue(
      factsSource.contains("plan: plan, executableIdentity: toolDevice.executableIdentity"))
    XCTAssertFalse(factsSource.contains("struct RockchipTrustedAuthorizationFacts: Codable"))
  }

  private func authorizationBytes(plan: RockchipFlashPlan, maxRuns: Int) throws -> Data {
    let path = MaintainerMergedAuthorizationResolver.registryPath(for: Self.authorizationID)
    return try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": "1.0.0",
        "authorizationId": Self.authorizationID,
        "approvedBy": "lvye",
        "carrier": "protected main PR #296 \(path)",
        "target": [
          "model": RockchipFlashProfile.targetDeviceModel,
          "serialSHA256": Self.sha256(Self.serial),
          "bindingRevision": 1,
        ],
        "firmwareArchiveSHA256": plan.archiveSHA256,
        "transport": "usb",
        "toolchainFingerprint": RockchipFlashProfile.pinnedToolchainFingerprint,
        "providerIdentity": RockchipRockUSBFlashProvider.providerIdentity,
        "planDigestSHA256": plan.planDigestSHA256,
        "stepSetDigestSHA256": plan.stepSetDigestSHA256,
        "recoveryPath": "CHG-2026-016 Loader wlx recovery",
        "validUntil": "2030-08-31T00:00:00Z",
        "maxRuns": maxRuns,
      ], options: [.sortedKeys])
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func gitBlobOID(_ data: Data) -> String {
    var bytes = Data("blob \(data.count)\0".utf8)
    bytes.append(data)
    return Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}

private struct FixedPlanFactPort: RockchipExecutePlanFactPort {
  let plan: RockchipFlashPlan
  func makeValidatedExecutePlan(archiveURL: URL) async throws -> RockchipFlashPlan { plan }
}

private struct FixedBindingFactPort: RockchipDurableBindingFactPort {
  let value: RockchipTrustedDurableBindingFact
  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact { value }
}

private struct FixedToolFactPort: RockchipToolDeviceFactPort {
  let value: RockchipTrustedToolDeviceFact
  func observeToolAndDevice() async throws -> RockchipTrustedToolDeviceFact { value }
}

private struct FixedPrerequisiteFactPort: RockchipPrerequisiteFactPort {
  let value: RockchipTrustedPrerequisiteFact
  func probePrerequisites() async throws -> RockchipTrustedPrerequisiteFact { value }
}

private struct FixedReadbackFactPort: RockchipIdentityReadbackFactPort {
  let value: RockchipTrustedIdentityReadbackFact
  func readIdentity() async throws -> RockchipTrustedIdentityReadbackFact { value }
}

private struct FixedAdmissionClock: RockchipAdmissionClock {
  let reading: RockchipTrustedClockReading
  func now() -> RockchipTrustedClockReading { reading }
}

private struct FixedAdmissionProvenancePort: AuthorizationProvenancePort {
  let snapshot: AuthorizationProvenanceSnapshot
  func fetchFreshSnapshot(authorizationID: String, registryPath: String) async throws
    -> AuthorizationProvenanceSnapshot
  { snapshot }
}

private final class OneShotLedgerFault: @unchecked Sendable {
  private let lock = NSLock()
  private let point: AuthorizationUsageLedgerFaultPoint
  private var fired = false

  init(point: AuthorizationUsageLedgerFaultPoint) { self.point = point }

  func check(_ candidate: AuthorizationUsageLedgerFaultPoint) throws {
    lock.lock()
    defer { lock.unlock() }
    guard candidate == point, !fired else { return }
    fired = true
    throw InjectedLedgerCrash.afterReplace
  }
}

private enum InjectedLedgerCrash: Error { case afterReplace }
